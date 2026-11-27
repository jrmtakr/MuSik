import Accelerate
import AVFoundation
import Foundation
import UIKit

/// Built-in custom Shazam acoustic fingerprinting + full-song vocal recognition engine.
///
/// Uses `Accelerate` (`vDSP`) STFT spectral-peak constellation hashing to fingerprint audio across
/// the entire song (no Apple ShazamKit entitlement required) and cross-matches against:
///   1. The local persistent Shazam landmark database (`shazam_fingerprints.json`)
///   2. Sung-lyric / catalog candidates verified acoustically by aligning each candidate's official
///      30-second iTunes `previewUrl` constellation against the entire local song.
final class ShazamFingerprintEngine: SongRecognitionEngine, @unchecked Sendable {
    static let shared = ShazamFingerprintEngine()

    let name = "Shazam AI"

    // MARK: - Signal Processing Constants

    private static let targetSampleRate: Double = 11_025
    private static let fftSize = 1024
    private static let log2N = vDSP_Length(10) // 2^10 = 1024
    private static let hopSize = 256
    private static let bandRanges: [Range<Int>] = [4..<12, 12..<28, 28..<64, 64..<160, 160..<380]
    private static let minDeltaFrames = 2
    private static let maxDeltaFrames = 40
    private static let fanOut = 5

    // MARK: - Persistence Models

    struct IndexedTrackRecord: Codable, Sendable {
        let trackKey: String
        let title: String
        let artist: String
        let album: String?
        let genre: String?
        let artworkURLString: String?
        let durationSeconds: Double?
        let updatedAt: Date
    }

    private struct Posting: Codable, Sendable {
        let trackIndex: UInt32
        let anchorFrame: UInt16
    }

    private struct DatabaseSnapshot: Codable, Sendable {
        var tracks: [IndexedTrackRecord] = []
        /// Hex hash strings so JSONEncoder handles keys cleanly across iOS versions.
        var postings: [String: [Posting]] = [:]
    }

    private struct Landmark {
        let hash: UInt32
        let anchorFrame: UInt16
    }

    private struct ITunesPreviewCandidate: Sendable {
        let title: String
        let artist: String
        let album: String?
        let genre: String?
        let artworkURL: URL?
        let durationSeconds: Double?
        let previewURL: URL
    }

    private let lock = NSLock()
    private var snapshot: DatabaseSnapshot
    private let dbURL: URL

    private init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.dbURL = supportDir.appendingPathComponent("shazam_fingerprints.json")
        if let data = try? Data(contentsOf: dbURL),
           let decoded = try? JSONDecoder().decode(DatabaseSnapshot.self, from: data) {
            self.snapshot = decoded
        } else {
            self.snapshot = DatabaseSnapshot()
        }
    }

    // MARK: - SongRecognitionEngine

    func recognize(fileURL: URL, durationHint: Double?) async -> SongRecognitionOutcome {
        await recognize(
            fileURL: fileURL,
            durationHint: durationHint,
            seedHintTitle: nil,
            seedHintArtist: nil,
            heardWords: nil,
            allowLyricSearch: true
        )
    }

    /// Recognizes an audio/video file across its whole duration using Shazam acoustic landmarks
    /// and (when available) heard lyrics + official iTunes/Deezer 30-second preview acoustic verification.
    func recognize(
        fileURL: URL,
        durationHint: Double?,
        seedHintTitle: String?,
        seedHintArtist: String?,
        heardWords: [HeardWord]?,
        allowLyricSearch: Bool = true
    ) async -> SongRecognitionOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .noMatch
        }

        // Extract spectral-peak constellation across the whole song (background utility work).
        let songLandmarks = await Task.detached(priority: .utility) {
            Self.extractConstellation(from: fileURL, maxLandmarks: 6_500)
        }.value

        guard !songLandmarks.isEmpty else {
            return .noMatch
        }

        // 1. Check our local persistent Shazam index first (instant, works offline).
        if let localHit = matchAgainstLocalIndex(queryLandmarks: songLandmarks, durationHint: durationHint) {
            return .match(localHit)
        }

        // 2. Gather candidate songs (from non-generic filename hints + Deezer/iTunes, plus LRCLIB only on vocal tracks).
        let candidates = await gatherITunesPreviewCandidates(
            fileURL: fileURL,
            seedTitle: seedHintTitle,
            seedArtist: seedHintArtist,
            heardWords: heardWords,
            allowLyricSearch: allowLyricSearch
        )

        guard !candidates.isEmpty else {
            return .noMatch
        }

        // 3. Build fast lookup map of the full song's landmarks for preview cross-correlation.
        let songMap = buildLookupMap(landmarks: songLandmarks)
        var bestCandidate: ITunesPreviewCandidate?
        var bestAlignedCount = 0
        var bestSecondPeak = 0

        for candidate in candidates.prefix(10) {
            if let durationHint, let candDur = candidate.durationSeconds,
               durationHint > 10, abs(durationHint - candDur) > 12 {
                continue
            }
            guard let previewLandmarks = await extractPreviewLandmarks(from: candidate.previewURL),
                  !previewLandmarks.isEmpty else {
                continue
            }
            let (peakVotes, secondVotes) = bestTimeOffsetMatchPeaks(songMap: songMap, previewLandmarks: previewLandmarks)
            // Guard against repetitive 4-bar chord/drum loops causing low-prominence hash collisions.
            let prominent = peakVotes >= 26 && (secondVotes == 0 || Double(peakVotes) >= Double(secondVotes) * 1.65)
            if prominent && peakVotes > bestAlignedCount {
                bestAlignedCount = peakVotes
                bestSecondPeak = secondVotes
                bestCandidate = candidate
            }
            // Early exit on an unmistakable acoustic lock.
            if prominent && peakVotes >= 48 { break }
        }

        guard let matched = bestCandidate, bestAlignedCount >= 26 else {
            return .noMatch
        }
        _ = bestSecondPeak

        let identified = IdentifiedSong(
            title: matched.title,
            artist: matched.artist,
            album: matched.album,
            genre: matched.genre,
            isrc: nil,
            artworkURL: matched.artworkURL,
            durationSeconds: matched.durationSeconds ?? durationHint,
            source: "Shazam AI (acoustic match)"
        )

        storeRecord(
            trackKey: fileURL.lastPathComponent,
            song: identified,
            landmarks: songLandmarks
        )
        return .match(identified)
    }

    /// Indexes a confirmed track's acoustic constellation into `shazam_fingerprints.json` so future
    /// uploads or duplicate songs recognize offline instantaneously.
    func indexConfirmedTrack(fileURL: URL, trackKey: String, song: IdentifiedSong) async {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let landmarks = await Task.detached(priority: .background) {
            Self.extractConstellation(from: fileURL, maxLandmarks: 650)
        }.value
        guard !landmarks.isEmpty else { return }
        storeRecord(trackKey: trackKey, song: song, landmarks: landmarks)
    }

    // MARK: - Local Shazam Index Matching

    private func matchAgainstLocalIndex(
        queryLandmarks: [Landmark],
        durationHint: Double?
    ) -> IdentifiedSong? {
        lock.lock()
        let current = snapshot
        lock.unlock()
        guard !current.tracks.isEmpty, !current.postings.isEmpty else { return nil }

        // Key: (trackIndex, quantized time delta) -> vote count
        var votesByTrackAndDelta: [UInt32: [Int: Int]] = [:]
        for lm in queryLandmarks {
            guard let postings = current.postings[Self.hexKey(lm.hash)] else { continue }
            for posting in postings {
                let delta = Int(lm.anchorFrame) - Int(posting.anchorFrame)
                let quantizedDelta = delta / 2
                var trackMap = votesByTrackAndDelta[posting.trackIndex] ?? [:]
                trackMap[quantizedDelta, default: 0] += 1
                votesByTrackAndDelta[posting.trackIndex] = trackMap
            }
        }

        var ranked: [(trackIdx: Int, peakVotes: Int)] = []
        for (trackIdxU32, deltaMap) in votesByTrackAndDelta {
            let idx = Int(trackIdxU32)
            guard idx >= 0, idx < current.tracks.count else { continue }
            if let durationHint, let recDur = current.tracks[idx].durationSeconds,
               durationHint > 10, abs(durationHint - recDur) > 15 {
                continue
            }
            if let peak = deltaMap.values.max(), peak >= 26 {
                ranked.append((idx, peak))
            }
        }
        ranked.sort { $0.peakVotes > $1.peakVotes }
        guard let top = ranked.first else { return nil }
        if ranked.count >= 2 && Double(top.peakVotes) < Double(ranked[1].peakVotes) * 1.60 && top.peakVotes < 48 {
            return nil
        }

        let rec = current.tracks[top.trackIdx]
        return IdentifiedSong(
            title: rec.title,
            artist: rec.artist,
            album: rec.album,
            genre: rec.genre,
            isrc: nil,
            artworkURL: rec.artworkURLString.flatMap { URL(string: $0) },
            durationSeconds: rec.durationSeconds,
            source: "Shazam AI (local fingerprint)"
        )
    }

    private func storeRecord(trackKey: String, song: IdentifiedSong, landmarks: [Landmark]) {
        // Keep a representative evenly-spaced subset (max 650 landmarks per track) so disk storage stays compact.
        let strideStep = max(1, landmarks.count / 650)
        var sampled: [Landmark] = []
        sampled.reserveCapacity(min(landmarks.count, 650))
        var i = 0
        while i < landmarks.count && sampled.count < 650 {
            sampled.append(landmarks[i])
            i += strideStep
        }

        lock.lock()
        defer { lock.unlock() }

        let trackIdx: UInt32
        let record = IndexedTrackRecord(
            trackKey: trackKey,
            title: song.title,
            artist: song.artist,
            album: song.album,
            genre: song.genre,
            artworkURLString: song.artworkURL?.absoluteString,
            durationSeconds: song.durationSeconds,
            updatedAt: .now
        )
        if let existingIdx = snapshot.tracks.firstIndex(where: { $0.trackKey == trackKey }) {
            snapshot.tracks[existingIdx] = record
            trackIdx = UInt32(existingIdx)
        } else {
            trackIdx = UInt32(snapshot.tracks.count)
            snapshot.tracks.append(record)
        }

        for lm in sampled {
            let key = Self.hexKey(lm.hash)
            var list = snapshot.postings[key] ?? []
            if list.count < 64 {
                list.append(Posting(trackIndex: trackIdx, anchorFrame: lm.anchorFrame))
                snapshot.postings[key] = list
            }
        }

        let copy = snapshot
        let url = dbURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(copy) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }

    private static func hexKey(_ hash: UInt32) -> String {
        String(hash, radix: 36)
    }

    // MARK: - Candidate Gathering & Official 30s Preview Matching

    private func gatherITunesPreviewCandidates(
        fileURL: URL,
        seedTitle: String?,
        seedArtist: String?,
        heardWords: [HeardWord]?,
        allowLyricSearch: Bool
    ) async -> [ITunesPreviewCandidate] {
        var searchQueries: [String] = []
        let langCtx = SongAudioListener.detectLanguageContext(title: seedTitle, artist: seedArtist)

        if let seedTitle, !seedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = ArtistDatabase.parseTrackHints(
                rawTitle: seedTitle,
                rawArtistTag: seedArtist,
                fileName: fileURL.lastPathComponent
            )
            let combined = [parsed.artistHint ?? seedArtist ?? "", parsed.songTitle]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !Self.looksGenericUploadName(combined) {
                searchQueries.append(combined)
            }
            if let alt = parsed.alternatePair {
                let altCombined = [alt.artist, alt.song]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !altCombined.isEmpty && !Self.looksGenericUploadName(altCombined) {
                    searchQueries.append(altCombined)
                }
            }
        }

        // Only query LRCLIB by heard words when the track actually has vocal lyrics in a transcribable language.
        var words = heardWords
        if words == nil && allowLyricSearch {
            words = await SongAudioListener.listen(to: fileURL)
        }
        if allowLyricSearch, let words, words.count >= 8 {
            let phrases = SongAudioListener.searchPhrases(from: words)
            for phrase in phrases.prefix(3) {
                if let lrcTitles = await fetchLRCLIBCandidateTerms(phrase: phrase) {
                    searchQueries.append(contentsOf: lrcTitles)
                }
                searchQueries.append(phrase)
            }
        }

        // Deduplicate queries and fetch iTunes (plus regional storefronts & global Deezer) previewable tracks.
        var seenQuery = Set<String>()
        var results: [ITunesPreviewCandidate] = []
        var seenTrackKeys = Set<String>()

        for q in searchQueries {
            let norm = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty, seenQuery.insert(norm).inserted else { continue }
            for country in langCtx.preferredITunesCountries {
                let fetched = await searchITunesWithPreviews(term: q, country: country)
                for item in fetched {
                    let tk = "\(item.title.lowercased())|\(item.artist.lowercased())"
                    if seenTrackKeys.insert(tk).inserted {
                        results.append(item)
                    }
                }
            }
            let deezerFetched = await searchDeezerWithPreviews(term: q)
            for item in deezerFetched {
                let tk = "\(item.title.lowercased())|\(item.artist.lowercased())"
                if seenTrackKeys.insert(tk).inserted {
                    results.append(item)
                }
            }
            if results.count >= 10 { break }
        }

        return results
    }

    private func fetchLRCLIBCandidateTerms(phrase: String) async -> [String]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: phrase)]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MuseJRM/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return rows.prefix(4).compactMap { row in
            guard let t = row["trackName"] as? String,
                  let a = row["artistName"] as? String else { return nil }
            return "\(a) \(t)"
        }
    }

    private func searchITunesWithPreviews(term: String, country: String = "us") async -> [ITunesPreviewCandidate] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "6")
        ]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["results"] as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let title = row["trackName"] as? String,
                  let artist = row["artistName"] as? String,
                  let previewStr = row["previewUrl"] as? String,
                  let previewURL = URL(string: previewStr) else {
                return nil
            }
            let album = row["collectionName"] as? String
            let genre = row["primaryGenreName"] as? String
            let durMs = row["trackTimeMillis"] as? Double
            let artStr = (row["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
            return ITunesPreviewCandidate(
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                artworkURL: artStr.flatMap { URL(string: $0) },
                durationSeconds: durMs.map { $0 / 1000.0 },
                previewURL: previewURL
            )
        }
    }

    private func searchDeezerWithPreviews(term: String) async -> [ITunesPreviewCandidate] {
        var comps = URLComponents(string: "https://api.deezer.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let title = row["title"] as? String,
                  let artistObj = row["artist"] as? [String: Any],
                  let artist = artistObj["name"] as? String,
                  let previewStr = row["preview"] as? String,
                  !previewStr.isEmpty,
                  let previewURL = URL(string: previewStr) else {
                return nil
            }
            let albumObj = row["album"] as? [String: Any]
            let album = albumObj?["title"] as? String
            let artStr = (albumObj?["cover_xl"] as? String) ?? (albumObj?["cover_big"] as? String) ?? (albumObj?["cover_medium"] as? String)
            let dur = row["duration"] as? Double
            return ITunesPreviewCandidate(
                title: title,
                artist: artist,
                album: album,
                genre: ArtistDatabase.genre(forArtist: artist),
                artworkURL: artStr.flatMap { URL(string: $0) },
                durationSeconds: dur,
                previewURL: previewURL
            )
        }
    }

    private func extractPreviewLandmarks(from previewURL: URL) async -> [Landmark]? {
        var req = URLRequest(url: previewURL)
        req.timeoutInterval = 12
        guard let (tmpURL, resp) = try? await URLSession.shared.download(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shazam_preview_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: m4aURL) }
        do {
            if FileManager.default.fileExists(atPath: m4aURL.path) {
                try FileManager.default.removeItem(at: m4aURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: m4aURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }

        return await Task.detached(priority: .utility) {
            Self.extractConstellation(from: m4aURL, maxLandmarks: 2_500)
        }.value
    }

    private func buildLookupMap(landmarks: [Landmark]) -> [UInt32: [UInt16]] {
        var map: [UInt32: [UInt16]] = [:]
        map.reserveCapacity(landmarks.count)
        for lm in landmarks {
            map[lm.hash, default: []].append(lm.anchorFrame)
        }
        return map
    }

    private func bestTimeOffsetMatchPeaks(songMap: [UInt32: [UInt16]], previewLandmarks: [Landmark]) -> (peakVotes: Int, secondVotes: Int) {
        var offsetHistogram: [Int: Int] = [:]
        for lm in previewLandmarks {
            guard let songFrames = songMap[lm.hash] else { continue }
            for frame in songFrames {
                let delta = (Int(frame) - Int(lm.anchorFrame)) / 2
                offsetHistogram[delta, default: 0] += 1
            }
        }
        guard let top = offsetHistogram.max(by: { $0.value < $1.value }) else { return (0, 0) }
        let second = offsetHistogram
            .filter { abs($0.key - top.key) >= 4 }
            .values
            .max() ?? 0
        return (top.value, second)
    }

    private static func looksGenericUploadName(_ text: String) -> Bool {
        let lower = text.lowercased()
        let generics = ["audio_", "img_", "track", "recording", "voice", "untitled", "unknown", "upload_"]
        return generics.contains { lower.hasPrefix($0) } && lower.count < 24
    }

    // MARK: - Accelerate STFT Constellation Extractor

    private static func extractConstellation(from url: URL, maxLandmarks: Int) -> [Landmark] {
        guard let samples = decodeMono11kSamples(from: url), samples.count >= fftSize else {
            return []
        }

        guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let halfN = fftSize / 2
        var windowed = [Float](repeating: 0, count: fftSize)
        var realBuf = [Float](repeating: 0, count: halfN)
        var imagBuf = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        struct Peak {
            let frame: Int
            let bin: Int
        }

        var peaksByFrame: [[Peak]] = []
        let totalFrames = (samples.count - fftSize) / hopSize
        peaksByFrame.reserveCapacity(max(1, totalFrames))

        // Stride lightly only for multi-hour recordings; typical full songs (<12 min) scan every frame.
        let frameHopMultiplier = totalFrames > 32_000 ? 2 : 1
        var frameIdx = 0
        var offset = 0

        while offset + fftSize <= samples.count && frameIdx < 65_000 {
            samples.withUnsafeBufferPointer { srcPtr in
                vDSP_vmul(srcPtr.baseAddress! + offset, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))
            }

            realBuf.withUnsafeMutableBufferPointer { rPtr in
                imagBuf.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
                }
            }

            var framePeaks: [Peak] = []
            framePeaks.reserveCapacity(bandRanges.count)

            var avgEnergy: Float = 0
            vDSP_meanv(&magnitudes, 1, &avgEnergy, vDSP_Length(halfN))
            let minEnergyThreshold = max(avgEnergy * 1.4, 1e-4)

            for band in bandRanges {
                var bestBin = band.lowerBound
                var bestMag: Float = 0
                for b in band where magnitudes[b] > bestMag {
                    bestMag = magnitudes[b]
                    bestBin = b
                }
                if bestMag > minEnergyThreshold {
                    framePeaks.append(Peak(frame: frameIdx, bin: bestBin))
                }
            }

            peaksByFrame.append(framePeaks)
            frameIdx += 1
            offset += hopSize * frameHopMultiplier
        }

        // Pair anchor peaks with future target peaks in the constellation window.
        var landmarks: [Landmark] = []
        landmarks.reserveCapacity(min(maxLandmarks, peaksByFrame.count * 4))

        for t1 in 0..<peaksByFrame.count {
            let anchors = peaksByFrame[t1]
            guard !anchors.isEmpty else { continue }
            let endFrame = min(peaksByFrame.count - 1, t1 + maxDeltaFrames)
            let startFrame = t1 + minDeltaFrames
            if startFrame > endFrame { continue }

            for anchor in anchors {
                var paired = 0
                for t2 in startFrame...endFrame {
                    for target in peaksByFrame[t2] {
                        let dt = t2 - t1
                        let hash = (UInt32(anchor.bin & 0x1FF) << 18)
                            | (UInt32(target.bin & 0x1FF) << 9)
                            | UInt32(dt & 0x1FF)
                        landmarks.append(Landmark(hash: hash, anchorFrame: UInt16(min(65_535, t1))))
                        paired += 1
                        if paired >= fanOut || landmarks.count >= maxLandmarks { break }
                    }
                    if paired >= fanOut || landmarks.count >= maxLandmarks { break }
                }
                if landmarks.count >= maxLandmarks { break }
            }
            if landmarks.count >= maxLandmarks { break }
        }

        return landmarks
    }

    private static func decodeMono11kSamples(from url: URL) -> [Float]? {
        guard let prepared = SongAudioListener.prepareReadableAudioFile(for: url) else { return nil }
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        let asset = AVURLAsset(url: prepared.url)
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let tracks = asset.tracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // Cap decoded PCM at ~15 minutes (~9.9M floats) so even massive files stay responsive.
        let maxSamples = Int(targetSampleRate * 900)
        var samples: [Float] = []
        var scale: Float = 1.0 / 32768.0

        while reader.status == .reading, samples.count < maxSamples {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                break
            }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            if status == noErr, let ptr = pointer, length >= 2 {
                let count = min(length / MemoryLayout<Int16>.size, maxSamples - samples.count)
                var rawFloats = [Float](repeating: 0, count: count)
                var scaledFloats = [Float](repeating: 0, count: count)
                ptr.withMemoryRebound(to: Int16.self, capacity: count) { int16Ptr in
                    vDSP_vflt16(int16Ptr, 1, &rawFloats, 1, vDSP_Length(count))
                }
                vDSP_vsmul(rawFloats, 1, &scale, &scaledFloats, 1, vDSP_Length(count))
                samples.append(contentsOf: scaledFloats)
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        return samples.isEmpty ? nil : samples
    }
}
