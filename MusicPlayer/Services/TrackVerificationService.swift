import AVFoundation
import Foundation
@preconcurrency import Speech
import SwiftUI

struct TrackVerificationCandidate: Identifiable, Hashable {
    let id = UUID()
    let artistName: String
    let trackTitle: String
    let albumName: String?
    let genre: String?
    let durationSeconds: Double?
    let lyricsSnippet: String?
    let artworkURL: URL?
    let score: Int
    let matchReasons: [String]
    let sources: [String]

    var confidenceLabel: String {
        if score >= 85 { return "High Match" }
        if score >= 55 { return "Good Match" }
        return "Possible Match"
    }

    var confidenceColor: Color {
        if score >= 85 { return .green }
        if score >= 55 { return .blue }
        return .orange
    }
}

struct TrackVerificationResult {
    let candidates: [TrackVerificationCandidate]
    let youtubeCaptionSnippet: String?
    let youtubeCreditHint: String?
}

enum TrackVerificationService {
    private static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private struct RawHit {
        var artistName: String
        var trackTitle: String
        var albumName: String?
        var genre: String?
        var durationSeconds: Double?
        var lyricsSnippet: String?
        var artworkURL: URL?
        var source: String
        var matchedViaLyrics: Bool = false
    }

    // MARK: - Main Verification Entry

    static func verifyTrack(
        rawTitle: String,
        rawArtist: String?,
        localDuration: Double?,
        sourceVideoID: String?,
        extraLyricSnippet: String? = nil,
        ignoredChannels: Set<String> = []
    ) async -> TrackVerificationResult {
        let cleanedQuery = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: rawTitle,
            rawArtistTag: rawArtist,
            ignoredChannels: ignoredChannels
        )
        let songQuery = cleanedQuery.songOnly.trimmingCharacters(in: .whitespacesAndNewlines)

        async let ytTask = fetchYouTubeCaptionsAndCredits(videoID: sourceVideoID)
        async let itunesTask = fetchITunesCandidates(query: songQuery)
        async let lrclibTask = fetchLRCLIBBySearch(query: songQuery)
        async let geniusTask = fetchGeniusCandidates(query: songQuery, isLyricQuery: false)

        let ytSignals = await ytTask
        var allHits: [RawHit] = []
        allHits.append(contentsOf: await itunesTask)
        allHits.append(contentsOf: await lrclibTask)
        allHits.append(contentsOf: await geniusTask)

        if let creditArtist = ytSignals.creditArtist, !creditArtist.isEmpty {
            let cleanTitle = ytSignals.creditTitle?.isEmpty == false ? ytSignals.creditTitle! : songQuery
            allHits.append(
                RawHit(
                    artistName: creditArtist,
                    trackTitle: cleanTitle,
                    albumName: nil,
                    genre: ArtistDatabase.genre(forArtist: creditArtist),
                    durationSeconds: localDuration,
                    lyricsSnippet: nil,
                    artworkURL: nil,
                    source: "YouTube Credits"
                )
            )
        }

        // If we have YouTube captions or spoken audio transcript, query Genius lyric search too!
        let lyricQueries = [extraLyricSnippet, ytSignals.caption]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for lq in lyricQueries {
            let lyricHits = await fetchGeniusCandidates(query: lq, isLyricQuery: true)
            allHits.append(contentsOf: lyricHits)
        }

        var merged = mergeAndScore(
            hits: allHits,
            songQuery: songQuery,
            artistHint: cleanedQuery.artistHint,
            localDuration: localDuration,
            lyricClueText: lyricQueries.first
        )

        // Enrich top 3 candidates with chorus lyrics from LRCLIB if still missing a snippet
        let topCount = min(3, merged.count)
        for idx in 0..<topCount where (merged[idx].lyricsSnippet?.isEmpty ?? true) {
            let cand = merged[idx]
            if let lrc = await fetchLRCLIBBestLyrics(
                trackName: cand.trackTitle,
                artistName: cand.artistName,
                targetDuration: localDuration ?? cand.durationSeconds
            ) {
                var reasons = cand.matchReasons
                var bonus = 8
                if !reasons.contains("Lyrics Preview") {
                    reasons.append("Lyrics Preview")
                }
                if let lyricClue = lyricQueries.first, lyricsShareWords(lrc.snippet, clue: lyricClue) {
                    bonus += 35
                    if !reasons.contains("Lyrics Words Matched") {
                        reasons.append("Lyrics Words Matched")
                    }
                }
                var sources = cand.sources
                if !sources.contains("LRCLIB") {
                    sources.append("LRCLIB")
                }
                merged[idx] = TrackVerificationCandidate(
                    artistName: cand.artistName,
                    trackTitle: cand.trackTitle,
                    albumName: cand.albumName ?? lrc.albumName,
                    genre: cand.genre,
                    durationSeconds: cand.durationSeconds ?? lrc.durationSeconds,
                    lyricsSnippet: lrc.snippet,
                    artworkURL: cand.artworkURL,
                    score: cand.score + bonus,
                    matchReasons: reasons,
                    sources: sources
                )
            }
        }

        merged.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.trackTitle.localizedCaseInsensitiveCompare(rhs.trackTitle) == .orderedAscending
        }

        return TrackVerificationResult(
            candidates: Array(merged.prefix(10)),
            youtubeCaptionSnippet: ytSignals.caption,
            youtubeCreditHint: ytSignals.creditArtist
        )
    }

    // MARK: - Vocal Chorus Speech Recognition

    static func identifyFromVocalClip(
        audioURL: URL,
        durationSeconds: Double?,
        titleHint: String?,
        rawArtist: String?,
        sourceVideoID: String?,
        ignoredChannels: Set<String> = []
    ) async -> (transcript: String?, verification: TrackVerificationResult?, errorMessage: String?) {
        let authStatus = await requestSpeechPermission()
        guard authStatus == .authorized else {
            return (
                nil,
                nil,
                "Speech Recognition is disabled. Enable it in iPhone Settings -> Music Player -> Speech Recognition."
            )
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            return (nil, nil, "On-device Speech Recognition is currently unavailable.")
        }

        let asset = AVURLAsset(url: audioURL)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            return (
                nil,
                nil,
                "Vocal lyrics scan supports M4A, MP3, WAV, and MP4 tracks. Use Song Title Search instead."
            )
        }

        let loadedDur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
        let totalSec = (loadedDur?.isFinite == true && (loadedDur ?? 0) > 0 ? loadedDur! : (durationSeconds ?? 0))
        let startSec: Double = totalSec > 60 ? min(totalSec * 0.35, totalSec - 25) : 0
        let clipLen: Double = totalSec > 0 ? min(24, max(4, totalSec - startSec)) : 24

        let tempClipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrapped_vocal_sample_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempClipURL) }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return (nil, nil, "Could not prepare audio sample for vocal lyric scan.")
        }
        exportSession.outputURL = tempClipURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, startSec), preferredTimescale: 600),
            duration: CMTime(seconds: clipLen, preferredTimescale: 600)
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exportSession.exportAsynchronously {
                cont.resume()
            }
        }

        guard exportSession.status == .completed, FileManager.default.fileExists(atPath: tempClipURL.path) else {
            return (nil, nil, "Could not sample audio clip from this file format. Try Song Title Search.")
        }

        let transcript = await transcribeClip(at: tempClipURL, recognizer: recognizer)
        let trimmed = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return (
                nil,
                nil,
                "Couldn't catch clear spoken/sung lyrics in this clip (heavy beat or instrumental). Try Song Title Search."
            )
        }

        // Keep up to 14 distinct words around the chorus snippet for Genius lyric lookup
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).prefix(14).map(String.init)
        let querySnippet = words.joined(separator: " ")

        let result = await verifyTrack(
            rawTitle: titleHint ?? "",
            rawArtist: rawArtist,
            localDuration: durationSeconds,
            sourceVideoID: sourceVideoID,
            extraLyricSnippet: querySnippet,
            ignoredChannels: ignoredChannels
        )
        return (querySnippet, result, nil)
    }

    private static func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private static func transcribeClip(at url: URL, recognizer: SFSpeechRecognizer) async -> String? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false
        }

        let box = ContinuationStateBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    box.updateBestText(result.bestTranscription.formattedString)
                    if result.isFinal {
                        if let text = box.finishOnce() {
                            cont.resume(returning: text)
                        }
                    }
                } else if error != nil {
                    if let text = box.finishOnce() {
                        cont.resume(returning: text)
                    }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12.0) {
                task.finish()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if let text = box.finishOnce() {
                        task.cancel()
                        cont.resume(returning: text)
                    }
                }
            }
        }
    }

    // MARK: - Network Sources

    private static func fetchITunesCandidates(query: String) async -> [RawHit] {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=10&term=\(encoded)") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        var hits: [RawHit] = []
        for row in results {
            guard let artist = row["artistName"] as? String,
                  let title = row["trackName"] as? String else { continue }
            let album = row["collectionName"] as? String
            let genre = row["primaryGenreName"] as? String
            let ms = row["trackTimeMillis"] as? Double
            let dur = ms.map { $0 / 1000.0 }
            let artStr = (row["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            let artURL = artStr.flatMap { URL(string: $0) }

            hits.append(
                RawHit(
                    artistName: ArtistDatabase.canonicalizeSingle(artist),
                    trackTitle: title,
                    albumName: album,
                    genre: genre,
                    durationSeconds: dur,
                    lyricsSnippet: nil,
                    artworkURL: artURL,
                    source: "iTunes"
                )
            )
        }
        return hits
    }

    private static func fetchLRCLIBBySearch(query: String) async -> [RawHit] {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?q=\(encoded)") else {
            return []
        }
        return await parseLRCLIBResponse(url: url)
    }

    private static func fetchLRCLIBBestLyrics(
        trackName: String,
        artistName: String,
        targetDuration: Double?
    ) async -> (snippet: String, albumName: String?, durationSeconds: Double?)? {
        let cleanTrack = ArtistDatabase.cleanSongTitleForSearch(rawTitle: trackName).songOnly
        let primaryArtist = ArtistDatabase.extractArtists(
            rawArtistTag: artistName,
            rawTitle: nil,
            isArtistVerified: true
        ).primaryArtist

        let attempts: [(String, String)] = [
            (cleanTrack.isEmpty ? trackName : cleanTrack, artistName),
            (cleanTrack.isEmpty ? trackName : cleanTrack, primaryArtist)
        ]

        for (tQuery, aQuery) in attempts {
            var comps = URLComponents(string: "https://lrclib.net/api/search")
            comps?.queryItems = [
                URLQueryItem(name: "track_name", value: tQuery),
                URLQueryItem(name: "artist_name", value: aQuery)
            ]
            guard let url = comps?.url else { continue }
            let items = await parseLRCLIBResponse(url: url)
            let withLyrics = items.filter { !($0.lyricsSnippet?.isEmpty ?? true) }
            guard !withLyrics.isEmpty else { continue }
            if let targetDuration {
                let best = withLyrics.min { lhs, rhs in
                    abs((lhs.durationSeconds ?? targetDuration) - targetDuration) <
                        abs((rhs.durationSeconds ?? targetDuration) - targetDuration)
                }
                if let best, let snippet = best.lyricsSnippet {
                    return (snippet, best.albumName, best.durationSeconds)
                }
            }
            if let first = withLyrics.first, let snippet = first.lyricsSnippet {
                return (snippet, first.albumName, first.durationSeconds)
            }
        }
        return nil
    }

    private static func parseLRCLIBResponse(url: URL) async -> [RawHit] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var hits: [RawHit] = []
        for row in rows.prefix(12) {
            guard let rawTrack = row["trackName"] as? String,
                  let rawArtist = row["artistName"] as? String else { continue }
            let dur = row["duration"] as? Double
            let album = row["albumName"] as? String
            let plain = (row["plainLyrics"] as? String) ?? ""
            let snippet = cleanLyricsExcerpt(from: plain)

            // Guard against LRCLIB entries where artistName contains "Song - Artist"
            var resolvedArtist = rawArtist
            var resolvedTrack = rawTrack
            if rawArtist.contains(" - ") && ArtistDatabase.lookup(rawArtist) == nil {
                let parsed = ArtistDatabase.extractArtists(rawArtistTag: nil, rawTitle: rawArtist)
                if parsed.matchedFromCatalog {
                    resolvedArtist = parsed.primaryArtist
                    let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: rawTrack, rawArtistTag: resolvedArtist)
                    if !cleaned.songOnly.isEmpty {
                        resolvedTrack = cleaned.songOnly
                    }
                }
            }

            hits.append(
                RawHit(
                    artistName: ArtistDatabase.canonicalizeSingle(resolvedArtist),
                    trackTitle: resolvedTrack,
                    albumName: album,
                    genre: ArtistDatabase.genre(forArtist: resolvedArtist),
                    durationSeconds: dur,
                    lyricsSnippet: snippet,
                    artworkURL: nil,
                    source: "LRCLIB"
                )
            )
        }
        return hits
    }

    private static func fetchGeniusCandidates(query: String, isLyricQuery: Bool) async -> [RawHit] {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://genius.com/api/search/multi?q=\(encoded)&per_page=5") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let sections = response["sections"] as? [[String: Any]] else {
            return []
        }

        var hits: [RawHit] = []
        for section in sections {
            let sectionType = (section["type"] as? String) ?? ""
            guard sectionType == "top_hit" || sectionType == "song" || sectionType == "lyric",
                  let rawHits = section["hits"] as? [[String: Any]] else {
                continue
            }

            for h in rawHits {
                guard let result = h["result"] as? [String: Any],
                      let title = result["title"] as? String,
                      let primaryArtist = result["primary_artist"] as? [String: Any],
                      let artistName = primaryArtist["name"] as? String else {
                    continue
                }
                let lowerArtist = artistName.lowercased()
                if lowerArtist.contains("genius ") || lowerArtist.contains("romanization") || lowerArtist.contains("translation") {
                    continue
                }
                let thumbURL = (result["song_art_image_thumbnail_url"] as? String).flatMap { URL(string: $0) }
                let highlights = (h["highlights"] as? [[String: Any]]) ?? []
                let rawSnippet = (highlights.first?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                hits.append(
                    RawHit(
                        artistName: ArtistDatabase.canonicalizeSingle(artistName),
                        trackTitle: title,
                        albumName: nil,
                        genre: ArtistDatabase.genre(forArtist: artistName),
                        durationSeconds: nil,
                        lyricsSnippet: rawSnippet?.isEmpty == false ? cleanLyricsExcerpt(from: rawSnippet!) : nil,
                        artworkURL: thumbURL,
                        source: "Genius",
                        matchedViaLyrics: isLyricQuery || sectionType == "lyric"
                    )
                )
            }
        }
        return hits
    }

    private static func fetchYouTubeCaptionsAndCredits(
        videoID: String?
    ) async -> (caption: String?, creditArtist: String?, creditTitle: String?) {
        guard let videoID, !videoID.isEmpty,
              let apiURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return (nil, nil, nil)
        }
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": YouTubeStreamResolver.iosClientVersion,
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.3.2",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, nil, nil)
        }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YouTubeStreamResolver.iosClientUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("5", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(YouTubeStreamResolver.iosClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }

        let videoDetails = dict["videoDetails"] as? [String: Any]
        let desc = (videoDetails?["shortDescription"] as? String) ?? ""
        let parsedDesc = parseYouTubeDescriptionCredits(desc)

        var captionSnippet: String?
        if let captions = dict["captions"] as? [String: Any],
           let list = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
           let tracks = list["captionTracks"] as? [[String: Any]] {
            let preferredTrack = tracks.first { ($0["languageCode"] as? String)?.hasPrefix("en") == true } ?? tracks.first
            if let baseStr = preferredTrack?["baseUrl"] as? String {
                let json3Str = baseStr.contains("fmt=") ? baseStr : "\(baseStr)&fmt=json3"
                if let capURL = URL(string: json3Str),
                   let (capData, _) = try? await URLSession.shared.data(from: capURL),
                   let capJSON = try? JSONSerialization.jsonObject(with: capData) as? [String: Any],
                   let events = capJSON["events"] as? [[String: Any]] {
                    var words: [String] = []
                    for ev in events.dropFirst(1).prefix(25) {
                        for seg in (ev["segs"] as? [[String: Any]]) ?? [] {
                            let piece = (seg["utf8"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !piece.isEmpty && !piece.hasPrefix("[") {
                                words.append(piece)
                            }
                        }
                        if words.joined(separator: " ").split(separator: " ").count >= 14 { break }
                    }
                    let joined = words.joined(separator: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if joined.split(separator: " ").count >= 4 {
                        captionSnippet = joined
                    }
                }
            }
        }

        return (captionSnippet, parsedDesc.artist, parsedDesc.title)
    }

    private static func parseYouTubeDescriptionCredits(_ desc: String) -> (artist: String?, title: String?) {
        guard !desc.isEmpty else { return (nil, nil) }
        let lines = desc
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Auto-generated "Provided to YouTube by" lines strictly list "Title · Artist" right below
        if desc.contains("Provided to YouTube by") {
            for line in lines where line.contains(" · ") {
                let parts = line.components(separatedBy: " · ")
                if parts.count >= 2 {
                    let songPart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let artistPart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !artistPart.isEmpty {
                        return (ArtistDatabase.canonicalizeSingle(artistPart), songPart)
                    }
                }
            }
        }

        for line in lines.prefix(10) {
            if line.contains(" - ") && !line.contains("http") && line.count <= 90 {
                let extracted = ArtistDatabase.extractArtists(rawArtistTag: nil, rawTitle: line)
                if extracted.matchedFromCatalog {
                    let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: line, rawArtistTag: extracted.primaryArtist)
                    return (extracted.primaryArtist, cleaned.songOnly)
                }
            }
        }
        return (nil, nil)
    }

    // MARK: - Scoring & Merging

    private static func mergeAndScore(
        hits: [RawHit],
        songQuery: String,
        artistHint: String?,
        localDuration: Double?,
        lyricClueText: String?
    ) -> [TrackVerificationCandidate] {
        struct Bucket {
            var artistName: String
            var trackTitle: String
            var albumName: String?
            var genre: String?
            var durationSeconds: Double?
            var lyricsSnippet: String?
            var artworkURL: URL?
            var sources: [String] = []
            var matchedViaLyrics = false
        }

        var buckets: [String: Bucket] = [:]
        var bucketOrder: [String] = []

        for hit in hits {
            let cleanHitTitle = ArtistDatabase.cleanSongTitleForSearch(rawTitle: hit.trackTitle).songOnly
            let extractedArtist = ArtistDatabase.extractArtists(rawArtistTag: hit.artistName, rawTitle: nil, isArtistVerified: true)
            let aKey = ArtistDatabase.normalizeLookupKey(extractedArtist.primaryArtist)
            let tKey = ArtistDatabase.normalizeLookupKey(cleanHitTitle.isEmpty ? hit.trackTitle : cleanHitTitle)
            guard !aKey.isEmpty, !tKey.isEmpty else { continue }
            let compositeKey = "\(aKey)|\(tKey)"

            if var existing = buckets[compositeKey] {
                if existing.albumName == nil { existing.albumName = hit.albumName }
                if existing.genre == nil { existing.genre = hit.genre }
                if existing.durationSeconds == nil { existing.durationSeconds = hit.durationSeconds }
                if (existing.lyricsSnippet?.isEmpty ?? true) { existing.lyricsSnippet = hit.lyricsSnippet }
                if existing.artworkURL == nil { existing.artworkURL = hit.artworkURL }
                if !existing.sources.contains(hit.source) { existing.sources.append(hit.source) }
                if hit.matchedViaLyrics { existing.matchedViaLyrics = true }
                buckets[compositeKey] = existing
            } else {
                buckets[compositeKey] = Bucket(
                    artistName: hit.artistName,
                    trackTitle: hit.trackTitle,
                    albumName: hit.albumName,
                    genre: hit.genre,
                    durationSeconds: hit.durationSeconds,
                    lyricsSnippet: hit.lyricsSnippet,
                    artworkURL: hit.artworkURL,
                    sources: [hit.source],
                    matchedViaLyrics: hit.matchedViaLyrics
                )
                bucketOrder.append(compositeKey)
            }
        }

        let normSongQuery = ArtistDatabase.normalizeLookupKey(songQuery)
        let normArtistHint = artistHint.map { ArtistDatabase.normalizeLookupKey($0) }

        return bucketOrder.compactMap { key -> TrackVerificationCandidate? in
            guard let b = buckets[key] else { return nil }
            var score = 0
            var reasons: [String] = []

            let normCandTitle = ArtistDatabase.normalizeLookupKey(b.trackTitle)
            let normCandArtist = ArtistDatabase.normalizeLookupKey(b.artistName)

            if !normSongQuery.isEmpty {
                if normCandTitle == normSongQuery {
                    score += 42
                    reasons.append("Exact Title")
                } else if normCandTitle.contains(normSongQuery) || normSongQuery.contains(normCandTitle) {
                    score += 24
                    reasons.append("Close Title")
                } else if !b.matchedViaLyrics {
                    score -= 12
                }
            }

            if let normArtistHint, !normArtistHint.isEmpty {
                if normCandArtist == normArtistHint || normCandArtist.contains(normArtistHint) {
                    score += 20
                }
            }

            if let localDuration, localDuration > 10, let candDur = b.durationSeconds, candDur > 10 {
                let diff = abs(localDuration - candDur)
                if diff <= 3.5 {
                    score += 48
                    reasons.append("Exact Length (±\(Int(diff.rounded()))s)")
                } else if diff <= 9.0 {
                    score += 32
                    reasons.append("Close Length (±\(Int(diff.rounded()))s)")
                } else if diff > 25.0 {
                    score -= 38
                    reasons.append("Length Mismatch")
                }
            }

            if b.matchedViaLyrics {
                score += 46
                reasons.append("Lyrics Match")
            } else if let lyricClueText, let snippet = b.lyricsSnippet, lyricsShareWords(snippet, clue: lyricClueText) {
                score += 42
                reasons.append("Lyrics Verified")
            }

            if b.sources.count >= 2 {
                score += 18
                reasons.append("\(b.sources.count) Sources Agree")
            }

            let catalogCheck = ArtistDatabase.extractArtists(
                rawArtistTag: b.artistName,
                rawTitle: nil,
                isArtistVerified: false
            )
            if catalogCheck.matchedFromCatalog || ArtistDatabase.lookup(b.artistName) != nil {
                score += 14
                reasons.append("Catalog Artist")
            }

            if let snip = b.lyricsSnippet, !snip.isEmpty, !reasons.contains("Lyrics Verified"), !reasons.contains("Lyrics Match") {
                score += 8
                reasons.append("Lyrics Preview")
            }

            return TrackVerificationCandidate(
                artistName: b.artistName,
                trackTitle: b.trackTitle,
                albumName: b.albumName,
                genre: b.genre ?? ArtistDatabase.genre(forArtist: b.artistName),
                durationSeconds: b.durationSeconds,
                lyricsSnippet: b.lyricsSnippet,
                artworkURL: b.artworkURL,
                score: score,
                matchReasons: reasons,
                sources: b.sources
            )
        }
    }

    private static func cleanLyricsExcerpt(from raw: String) -> String? {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty && !(line.hasPrefix("[") && line.hasSuffix("]"))
            }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(4).joined(separator: "\n")
    }

    private static func lyricsShareWords(_ lyrics: String, clue: String) -> Bool {
        let stopWords: Set<String> = ["the", "and", "for", "that", "this", "with", "you", "your", "from", "are", "was"]
        let lyricWords = Set(
            ArtistDatabase.normalizeLookupKey(lyrics)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
        let clueWords = ArtistDatabase.normalizeLookupKey(clue)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        guard clueWords.count >= 2 else { return false }
        let hitCount = clueWords.filter { lyricWords.contains($0) }.count
        return hitCount >= max(2, clueWords.count / 2)
    }

    private final class ContinuationStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hasFinished = false
        private var bestText = ""

        func updateBestText(_ value: String) {
            lock.lock()
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bestText = value
            }
            lock.unlock()
        }

        func finishOnce() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if hasFinished { return nil }
            hasFinished = true
            return bestText
        }
    }
}
