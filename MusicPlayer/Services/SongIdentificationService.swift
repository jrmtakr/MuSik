import Foundation
import Observation
@preconcurrency import Speech
import UIKit

// MARK: - Public model

/// A confident answer to "what song is this?".
struct IdentifiedSong: Sendable, Hashable {
    var title: String
    var artist: String
    var album: String?
    var genre: String?
    var isrc: String?
    var artworkURL: URL?
    var durationSeconds: Double?
    /// Which sources agreed, e.g. "Spotify playlist + iTunes". Shown in the UI.
    var source: String
}

enum SongRecognitionOutcome: Sendable {
    case match(IdentifiedSong)
    case noMatch
    /// The engine can't run at all right now (so stop trying it for a while).
    case unavailable(String)
}

/// Anything that can listen to an audio file and say which song it is.
///
/// No engine is registered by default — the metadata pipeline below needs no audio recognition and
/// no Apple service. An audio fingerprint engine (our own, or AcoustID/Chromaprint) can be added
/// later by conforming to this protocol and appending it to `SongIdentificationService.shared.engines`;
/// it is only consulted when the metadata sources can't agree.
protocol SongRecognitionEngine: Sendable {
    var name: String { get }
    func recognize(fileURL: URL, durationHint: Double?) async -> SongRecognitionOutcome
}

// MARK: - Service

/// Runs after each song is imported from a playlist link and fixes its title, artist, album and cover
/// art with no user input, so the lyrics lookup (which matches on title + artist + length) finds the
/// right lyrics.
///
/// How it decides, strongest evidence first — it only renames a song when two independent sources agree:
///   1. The playlist itself: Spotify / Apple Music list the exact title and artist.
///   2. YouTube's own "Music" box on the video (YouTube's Content ID recognition: song, artist, album).
///   3. Music catalogs: iTunes and MusicBrainz, with the song length required to match within a few
///      seconds so remixes, live, sped-up or cover versions aren't renamed to the original.
///   4. LRCLIB: an exact title + artist + length lyrics hit also counts as agreement.
///   5. Last resort: the existing `TrackVerificationService` scoring (cleaned YouTube title, iTunes,
///      LRCLIB, Genius, YouTube credits), accepted only for a high score and matching length.
@MainActor
@Observable
final class SongIdentificationService {
    static let shared = SongIdentificationService()

    static let enabledDefaultsKey = "musicplayer.import.autoIdentify"

    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool) ?? true
    }

    private(set) var pendingCount = 0
    private(set) var identifiedThisSession = 0
    private(set) var activePath: String?
    private(set) var lastStatus: String?
    /// Per-track live analysis progress (`0.0 ... 1.0`) and step label for imported songs/videos.
    private(set) var progressByPath: [String: Double] = [:]
    private(set) var stepLabelByPath: [String: String] = [:]
    /// Incremented whenever any track finishes AI analysis so waiting views (like Browser player auto-open) wake up cleanly.
    private(set) var completedRevision: Int = 0
    /// Set when an optional audio engine can't run; shown in Settings.
    private(set) var engineUnavailableReason: String?

    @ObservationIgnored var engines: [any SongRecognitionEngine] = [ShazamFingerprintEngine.shared]
    @ObservationIgnored private var disabledEngineNames = Set<String>()
    @ObservationIgnored private var queue: [Request] = []
    @ObservationIgnored private var queuedPaths = Set<String>()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var lastMusicBrainzRequestAt = Date.distantPast

    private final class SyncStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingPaths = Set<String>()
        private var stepLabels: [String: String] = [:]

        func setPending(_ path: String, pending: Bool) {
            lock.lock()
            if pending {
                pendingPaths.insert(path)
            } else {
                pendingPaths.remove(path)
                stepLabels.removeValue(forKey: path)
            }
            lock.unlock()
        }

        func setLabel(_ path: String, label: String) {
            lock.lock()
            stepLabels[path] = label
            lock.unlock()
        }

        func isPending(_ path: String) -> Bool {
            lock.lock()
            let result = pendingPaths.contains(path)
            lock.unlock()
            return result
        }

        func label(for path: String) -> String? {
            lock.lock()
            let val = stepLabels[path]
            lock.unlock()
            return val
        }

        func rekey(from oldPath: String, to newPath: String) {
            lock.lock()
            if pendingPaths.remove(oldPath) != nil {
                pendingPaths.insert(newPath)
            }
            if let oldLabel = stepLabels.removeValue(forKey: oldPath) {
                stepLabels[newPath] = oldLabel
            }
            lock.unlock()
        }
    }

    nonisolated private static let syncStateBox = SyncStateBox()

    nonisolated static func isIdentifyingSync(relativePath: String) -> Bool {
        syncStateBox.isPending(relativePath)
    }

    nonisolated static func stepLabelSync(forRelativePath path: String) -> String? {
        syncStateBox.label(for: path)
    }

    private struct Request {
        let relativePath: String
        let fileURL: URL
        let hintTitle: String
        let hintArtist: String
        let durationSeconds: Double?
        let sourceVideoID: String?
        let sourcePlatform: ExternalPlaylistPlatform?
        let jobID: UUID?
    }

    private struct Candidate {
        var title: String
        var artist: String
        var album: String?
        var genre: String?
        var isrc: String?
        var artworkURL: URL?
        var durationSeconds: Double?
        var sourceName: String
    }

    private static let userAgent = "MuseJRM/1.0 (https://github.com/jrmtakr/music-player)"
    /// Max length difference (seconds) for two sources to count as the same recording.
    private static let durationTolerance: Double = 4

    private init() {}

    // MARK: Queueing

    func enqueue(
        _ item: MediaItem,
        hintTitle: String,
        hintArtist: String,
        sourceVideoID: String?,
        sourcePlatform: ExternalPlaylistPlatform? = nil,
        jobID: UUID?
    ) {
        guard isEnabled, !item.isHLS else {
            MediaManager.shared.markAIAnalysisCompleted(relativePath: item.relativePath)
            return
        }
        // Never fight metadata the user confirmed or edited by hand.
        if let meta = MediaManager.shared.customMetadata(forRelativePath: item.relativePath),
           meta.isArtistVerified == true, meta.autoIdentifiedSource == nil {
            MediaManager.shared.markAIAnalysisCompleted(relativePath: item.relativePath)
            return
        }
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            MediaManager.shared.markAIAnalysisCompleted(relativePath: item.relativePath)
            return
        }

        // If still waiting in the queue, merge any richer hints (e.g. sourceVideoID/title applied right after import).
        if let qIdx = queue.firstIndex(where: { $0.relativePath == item.relativePath }) {
            let prev = queue[qIdx]
            queue[qIdx] = Request(
                relativePath: item.relativePath,
                fileURL: item.fileURL,
                hintTitle: (!hintTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hintTitle != item.fileName) ? hintTitle : prev.hintTitle,
                hintArtist: !hintArtist.isEmpty ? hintArtist : prev.hintArtist,
                durationSeconds: item.durationSeconds ?? prev.durationSeconds,
                sourceVideoID: sourceVideoID ?? prev.sourceVideoID,
                sourcePlatform: sourcePlatform ?? prev.sourcePlatform,
                jobID: jobID ?? prev.jobID
            )
            return
        }

        guard !queuedPaths.contains(item.relativePath) else { return }
        queuedPaths.insert(item.relativePath)
        progressByPath[item.relativePath] = 0.02
        let queuedLabel = "Queued for AI whole-song analysis..."
        stepLabelByPath[item.relativePath] = queuedLabel
        Self.syncStateBox.setPending(item.relativePath, pending: true)
        Self.syncStateBox.setLabel(item.relativePath, label: queuedLabel)
        queue.append(Request(
            relativePath: item.relativePath,
            fileURL: item.fileURL,
            hintTitle: hintTitle,
            hintArtist: hintArtist,
            durationSeconds: item.durationSeconds,
            sourceVideoID: sourceVideoID,
            sourcePlatform: sourcePlatform,
            jobID: jobID
        ))
        pendingCount = queue.count
        startWorkerIfNeeded()
    }

    private func updateTrackStep(path: String, progress: Double? = nil, label: String? = nil) {
        if let progress {
            progressByPath[path] = progress
        }
        if let label {
            stepLabelByPath[path] = label
            Self.syncStateBox.setLabel(path, label: label)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while true {
                guard let self else { return }
                guard !self.queue.isEmpty else {
                    self.worker = nil
                    self.pendingCount = 0
                    return
                }
                let request = self.queue.removeFirst()
                self.pendingCount = self.queue.count
                self.activePath = request.relativePath
                Self.syncStateBox.setPending(request.relativePath, pending: true)
                await self.process(request)
                self.progressByPath.removeValue(forKey: request.relativePath)
                self.stepLabelByPath.removeValue(forKey: request.relativePath)
                Self.syncStateBox.setPending(request.relativePath, pending: false)
                self.activePath = nil
                self.queuedPaths.remove(request.relativePath)
                self.completedRevision &+= 1
            }
        }
    }

    func isIdentifying(_ item: MediaItem) -> Bool {
        activePath == item.relativePath || queuedPaths.contains(item.relativePath)
    }

    func isBlockedPendingAI(_ item: MediaItem) -> Bool {
        guard !item.relativePath.hasPrefix("__remote__/"), !item.isHLS else { return false }
        if isIdentifying(item) { return true }
        return MediaManager.shared.customMetadata(forRelativePath: item.relativePath)?.aiAnalysisCompleted == false
    }

    func analysisProgress(for item: MediaItem) -> Double? {
        progressByPath[item.relativePath]
    }

    func analysisStatusText(for item: MediaItem) -> String? {
        if let step = stepLabelByPath[item.relativePath], !step.isEmpty {
            return step
        }
        if isBlockedPendingAI(item) {
            return "Queued for AI whole-song analysis..."
        }
        return nil
    }

    /// Moves a queued track to the front of the queue so a user-tapped song finishes analysis first.
    func prioritize(_ item: MediaItem) {
        if let idx = queue.firstIndex(where: { $0.relativePath == item.relativePath }), idx > 0 {
            let target = queue.remove(at: idx)
            queue.insert(target, at: 0)
            updateTrackStep(path: item.relativePath, label: "Prioritized for AI whole-song analysis...")
        } else if activePath != item.relativePath && !queuedPaths.contains(item.relativePath)
                    && MediaManager.shared.customMetadata(forRelativePath: item.relativePath)?.aiAnalysisCompleted == false {
            enqueue(
                item,
                hintTitle: item.displayTitle,
                hintArtist: item.artist ?? "",
                sourceVideoID: MediaManager.shared.customMetadata(forRelativePath: item.relativePath)?.sourceVideoID,
                sourcePlatform: nil,
                jobID: nil
            )
        }
    }

    func rekeyPath(from oldPath: String, to newPath: String) {
        Self.syncStateBox.rekey(from: oldPath, to: newPath)
        if let prog = progressByPath.removeValue(forKey: oldPath) {
            progressByPath[newPath] = prog
        }
        if let label = stepLabelByPath.removeValue(forKey: oldPath) {
            stepLabelByPath[newPath] = label
        }
        if activePath == oldPath {
            activePath = newPath
        }
        if queuedPaths.remove(oldPath) != nil {
            queuedPaths.insert(newPath)
        }
        if let newURL = MediaManager.shared.items.first(where: { $0.relativePath == newPath })?.fileURL {
            queue = queue.map { req in
                guard req.relativePath == oldPath else { return req }
                return Request(
                    relativePath: newPath,
                    fileURL: newURL,
                    hintTitle: req.hintTitle,
                    hintArtist: req.hintArtist,
                    durationSeconds: req.durationSeconds,
                    sourceVideoID: req.sourceVideoID,
                    sourcePlatform: req.sourcePlatform,
                    jobID: req.jobID
                )
            }
        }
    }

    /// Runs whole-song Shazam AI + vocal lyric identification immediately on demand for an item.
    @discardableResult
    func identifyNow(_ item: MediaItem) async -> IdentifiedSong? {
        guard !item.isHLS, FileManager.default.fileExists(atPath: item.fileURL.path) else { return nil }
        activePath = item.relativePath
        defer { if activePath == item.relativePath { activePath = nil } }

        let req = Request(
            relativePath: item.relativePath,
            fileURL: item.fileURL,
            hintTitle: item.displayTitle,
            hintArtist: item.artist ?? "",
            durationSeconds: item.durationSeconds,
            sourceVideoID: MediaManager.shared.customMetadata(forRelativePath: item.relativePath)?.sourceVideoID,
            sourcePlatform: nil,
            jobID: nil
        )
        return await runFullIdentification(req, allowOverwriteVerified: true)
    }

    // MARK: Processing

    private func process(_ request: Request) async {
        _ = await runFullIdentification(request, allowOverwriteVerified: false)
    }

    @discardableResult
    private func runFullIdentification(_ request: Request, allowOverwriteVerified: Bool) async -> IdentifiedSong? {
        defer {
            MediaManager.shared.markAIAnalysisCompleted(relativePath: request.relativePath)
        }
        guard FileManager.default.fileExists(atPath: request.fileURL.path) else { return nil }
        progressByPath[request.relativePath] = 0.08
        stepLabelByPath[request.relativePath] = "Checking track metadata..."
        lastStatus = "Shazam AI analyzing \"\(request.hintTitle)\"..."

        var song = await identify(
            fileURL: request.fileURL,
            hintTitle: request.hintTitle,
            hintArtist: request.hintArtist,
            durationSeconds: request.durationSeconds,
            sourceVideoID: request.sourceVideoID,
            sourcePlatform: request.sourcePlatform
        )

        // Listen to the whole song: confirm the name from the sung lyrics, identify unknown uploads
        // with Shazam acoustic matching, and align lyrics with this exact recording before playback.
        await Self.ensureSpeechPermissionIfPossible()
        progressByPath[request.relativePath] = 0.15
        stepLabelByPath[request.relativePath] = "AI listening to whole song..."
        lastStatus = "Listening to whole song: \"\(song?.title ?? request.hintTitle)\"..."

        let capturedPath = request.relativePath
        let capturedLabelTitle = song?.title ?? request.hintTitle
        let heard = await SongAudioListener.listen(to: request.fileURL) { [weak self] chunkIdx, totalChunks, totalSeconds in
            Task { @MainActor in
                let frac = 0.15 + 0.52 * (Double(chunkIdx) / Double(max(1, totalChunks)))
                let mins = Int(totalSeconds) / 60
                let secs = Int(totalSeconds) % 60
                let label = "AI listening to song (\(chunkIdx)/\(totalChunks) • \(mins):\(String(format: "%02d", secs)))..."
                self?.updateTrackStep(path: capturedPath, progress: frac, label: label)
                self?.lastStatus = "Listening to whole song (\(chunkIdx)/\(totalChunks)): \"\(capturedLabelTitle)\""
            }
        }
        var lyricsToAlign: ResolvedTrackLyrics?

        if var candidate = song, let heard {
            if let lyrics = await SyncedLyricsService.shared.fetchLyricsForVerification(
                title: candidate.title,
                artist: candidate.artist,
                duration: candidate.durationSeconds ?? request.durationSeconds
            ), Self.similarity(Self.stripVersionNoise(lyrics.trackTitle, keepVersionTags: false),
                                Self.stripVersionNoise(candidate.title, keepVersionTags: false)) >= 0.8 {
                switch SongAudioListener.verdict(heard: heard, lyrics: lyrics) {
                case .confirmed:
                    candidate.source += " + heard lyrics match"
                    lyricsToAlign = lyrics
                    song = candidate
                case .contradicted:
                    song = nil
                case .inconclusive:
                    lyricsToAlign = lyrics
                }
            }
        }

        if song == nil, let heard {
            progressByPath[request.relativePath] = 0.72
            stepLabelByPath[request.relativePath] = "Matching heard lyrics..."
            if let byLyrics = await identifyFromHeardLyrics(heard, localDuration: request.durationSeconds) {
                song = byLyrics.song
                lyricsToAlign = byLyrics.lyrics
            }
        }

        // Shazam acoustic constellation + heard-lyric + iTunes official preview matcher across the whole song.
        if song == nil {
            progressByPath[request.relativePath] = 0.78
            stepLabelByPath[request.relativePath] = "Running Shazam AI acoustic match..."
            lastStatus = "Running Shazam AI acoustic fingerprint..."
            if case .match(let shazamSong) = await ShazamFingerprintEngine.shared.recognize(
                fileURL: request.fileURL,
                durationHint: request.durationSeconds,
                seedHintTitle: request.hintTitle,
                seedHintArtist: request.hintArtist,
                heardWords: heard
            ) {
                song = shazamSong
            }
        }

        let heardExcerpt = heard.map { $0.prefix(16).map(\.token).joined(separator: " ") }
        let heardCount = heard?.count ?? 0

        guard let finalSong = song else {
            // Even when metadata doesn't warrant renaming the track, still check the audio & align
            // real-time lyrics if a real title/hint is known and matches what was heard.
            progressByPath[request.relativePath] = 0.88
            stepLabelByPath[request.relativePath] = "Syncing & aligning lyrics..."
            var alignedDuringImport = false
            if let item = MediaManager.shared.items.first(where: { $0.relativePath == request.relativePath }),
               !request.hintTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                alignedDuringImport = await SyncedLyricsService.shared.fetchAndAlignDuringImport(
                    item: item,
                    title: request.hintTitle,
                    artist: request.hintArtist,
                    duration: request.durationSeconds,
                    heard: heard
                )
            }
            WholeSongAIService.shared.markCompletedFromImport(
                relativePath: request.relativePath,
                title: request.hintTitle,
                album: nil,
                artist: request.hintArtist.isEmpty ? nil : request.hintArtist,
                genre: nil,
                heardWordCount: heardCount,
                heardExcerpt: heardExcerpt,
                hasLyrics: alignedDuringImport
            )
            progressByPath[request.relativePath] = 1.0
            lastStatus = "Kept \"\(request.hintTitle)\" and finished whole-song AI analysis"
            return nil
        }

        progressByPath[request.relativePath] = 0.84
        stepLabelByPath[request.relativePath] = "Saving verified title, artist & cover..."
        var cover: UIImage?
        if let artURL = finalSong.artworkURL {
            cover = await Self.downloadImage(artURL)
        }

        let applied = MediaManager.shared.applyAutoIdentifiedMetadata(
            relativePath: request.relativePath,
            title: finalSong.title,
            artist: finalSong.artist,
            album: finalSong.album,
            genre: finalSong.genre,
            isrc: finalSong.isrc,
            coverImage: cover,
            source: finalSong.source,
            forceOverwriteVerified: allowOverwriteVerified
        )
        if applied {
            identifiedThisSession += 1
            lastStatus = "Identified \"\(finalSong.title)\" by \(finalSong.artist) (\(finalSong.source))"
            if let jobID = request.jobID {
                PlaylistImportManager.shared.noteTrackIdentified(jobID: jobID)
            }
        }

        // Index this confirmed track into our local Shazam acoustic fingerprint DB.
        let indexFileURL = request.fileURL
        let indexPath = request.relativePath
        Task.detached(priority: .background) {
            await ShazamFingerprintEngine.shared.indexConfirmedTrack(
                fileURL: indexFileURL,
                trackKey: indexPath,
                song: finalSong
            )
        }

        // Pre-fetch & auto-align lyrics to this exact file during import (Speech anchors + Acoustic vocal alignment)
        // so lyrics always line up immediately on first playback with zero user input.
        progressByPath[request.relativePath] = 0.92
        stepLabelByPath[request.relativePath] = "Aligning lyrics across whole song..."
        if let item = MediaManager.shared.items.first(where: { $0.relativePath == request.relativePath }) {
            if let lyrics = lyricsToAlign {
                let aligned = await SongAudioListener.autoAlign(lyrics: lyrics, heard: heard, fileURL: item.fileURL)
                SyncedLyricsService.shared.storeAlignedLyrics(aligned, for: item)
            } else {
                await SyncedLyricsService.shared.fetchAndAlignDuringImport(
                    item: item,
                    title: finalSong.title,
                    artist: finalSong.artist,
                    duration: finalSong.durationSeconds ?? request.durationSeconds,
                    heard: heard
                )
            }
        }
        WholeSongAIService.shared.markCompletedFromImport(
            relativePath: request.relativePath,
            title: finalSong.title,
            album: finalSong.album,
            artist: finalSong.artist,
            genre: finalSong.genre,
            heardWordCount: heardCount,
            heardExcerpt: heardExcerpt,
            hasLyrics: true
        )
        progressByPath[request.relativePath] = 1.0
        return applied ? finalSong : nil
    }

    private static func ensureSpeechPermissionIfPossible() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined,
              UIApplication.shared.applicationState == .active else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
        }
    }

    /// Last resort when no name source agrees: search lyrics sites for phrases actually sung in the file,
    /// and accept a song only if its full lyrics match what was heard.
    private func identifyFromHeardLyrics(
        _ heard: [HeardWord],
        localDuration: Double?
    ) async -> (song: IdentifiedSong, lyrics: ResolvedTrackLyrics)? {
        for phrase in SongAudioListener.searchPhrases(from: heard) {
            var comps = URLComponents(string: "https://lrclib.net/api/search")
            comps?.queryItems = [URLQueryItem(name: "q", value: phrase)]
            guard let url = comps?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }

            for row in rows.prefix(8) {
                guard let title = row["trackName"] as? String,
                      let artist = row["artistName"] as? String else { continue }
                let text = (row["syncedLyrics"] as? String) ?? (row["plainLyrics"] as? String) ?? ""
                guard !text.isEmpty else { continue }
                let duration = row["duration"] as? Double
                let parsed = SyncedLyricsService.parseLRCOrPlain(text: text, duration: duration)
                let lyrics = ResolvedTrackLyrics(
                    cacheKey: "heard",
                    trackTitle: title,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Synced Lyrics" : "Lyrics",
                    attributionText: "Time-synced via LRCLIB",
                    syncedOffsetSeconds: 0,
                    expectedDurationSeconds: duration,
                    lines: parsed.lines
                )
                guard case .confirmed(let ratio) = SongAudioListener.verdict(heard: heard, lyrics: lyrics), ratio >= 0.35 else {
                    continue
                }
                // Lyrics match strongly. Pull album/cover from a catalog when one agrees.
                let claim = Candidate(title: title, artist: artist, album: row["albumName"] as? String,
                                      durationSeconds: duration, sourceName: "Heard lyrics")
                if let confirmed = await confirm(claim, localDuration: localDuration) {
                    return (confirmed, lyrics)
                }
                return (IdentifiedSong(
                    title: title,
                    artist: artist,
                    album: row["albumName"] as? String,
                    durationSeconds: duration,
                    source: "Heard lyrics (LRCLIB)"
                ), lyrics)
            }
        }
        return nil
    }

    /// Works out the real title/artist/album/cover for a file. Returns nil when the sources don't agree
    /// (the caller then keeps the original title rather than guessing).
    func identify(
        fileURL: URL,
        hintTitle: String,
        hintArtist: String,
        durationSeconds: Double?,
        sourceVideoID: String?,
        sourcePlatform: ExternalPlaylistPlatform?
    ) async -> IdentifiedSong? {
        // --- Gather "what it claims to be" ---------------------------------------------------
        var claims: [Candidate] = []

        // 1) Spotify / Apple Music playlists carry exact catalog titles & artists.
        if sourcePlatform == .spotify || sourcePlatform == .appleMusic,
           !hintTitle.isEmpty, !hintArtist.isEmpty {
            claims.append(Candidate(
                title: Self.stripVersionNoise(hintTitle, keepVersionTags: true),
                artist: hintArtist,
                sourceName: "\(sourcePlatform?.rawValue ?? "Playlist") playlist"
            ))
        }

        // 2) YouTube's own "Music" box for this video.
        if let videoID = sourceVideoID, !videoID.isEmpty,
           let ytMusic = await Self.youtubeMusicInVideo(videoID: videoID) {
            claims.append(ytMusic)
        }

        // 3) Cleaned-up YouTube video title ("Artist - Song (Official Video)" → "Song" / "Artist").
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: hintTitle,
            rawArtistTag: hintArtist.isEmpty ? nil : hintArtist
        )
        let cleanedTitle = cleaned.songOnly.trimmingCharacters(in: .whitespacesAndNewlines)
        // A channel name like "SomeUploader" or "ArtistVEVO" / "Artist - Topic" isn't a reliable artist.
        let channel = hintArtist
            .replacingOccurrences(of: #"(?i)\s*-\s*topic$|vevo$|\s+official$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channelIsUploader = ArtistDatabase.looksLikeUploaderChannel(hintArtist)
        let cleanedArtist = (cleaned.artistHint ?? (channelIsUploader ? "" : channel))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            claims.append(Candidate(title: cleanedTitle, artist: cleanedArtist, sourceName: "Video title"))
        }

        // --- Confirm each claim against catalogs, strongest claim first -----------------------
        for claim in claims {
            if let confirmed = await confirm(claim, localDuration: durationSeconds) {
                return confirmed
            }
        }

        // A trusted claim that no catalog knows (indie/unreleased) is still better than a video title,
        // but only if it came from the playlist or YouTube's Music box, never from a cleaned-up title.
        if let trusted = claims.first(where: { $0.sourceName != "Video title" }) {
            return IdentifiedSong(
                title: trusted.title,
                artist: trusted.artist,
                album: trusted.album,
                genre: trusted.genre,
                isrc: trusted.isrc,
                artworkURL: trusted.artworkURL,
                durationSeconds: trusted.durationSeconds,
                source: trusted.sourceName
            )
        }

        // --- Optional audio engines (none by default) -------------------------------------------
        for engine in engines where !disabledEngineNames.contains(engine.name) {
            switch await engine.recognize(fileURL: fileURL, durationHint: durationSeconds) {
            case .match(let song):
                return song
            case .noMatch:
                continue
            case .unavailable(let reason):
                disabledEngineNames.insert(engine.name)
                engineUnavailableReason = "\(engine.name): \(reason)"
            }
        }

        // --- Last resort: existing multi-source scorer, strict thresholds -------------------------
        let verification = await TrackVerificationService.verifyTrack(
            rawTitle: hintTitle,
            rawArtist: hintArtist.isEmpty ? nil : hintArtist,
            localDuration: durationSeconds,
            sourceVideoID: sourceVideoID
        )
        guard let best = verification.candidates.first, best.score >= 85 else { return nil }
        if let local = durationSeconds, let remote = best.durationSeconds, abs(local - remote) > Self.durationTolerance + 2 {
            return nil
        }
        return IdentifiedSong(
            title: best.trackTitle,
            artist: best.artistName,
            album: best.albumName,
            genre: best.genre,
            isrc: nil,
            artworkURL: best.artworkURL.map(Self.upscaledArtworkURL),
            durationSeconds: best.durationSeconds,
            source: best.sources.joined(separator: " + ")
        )
    }

    /// A claim is confirmed when a catalog (iTunes, then MusicBrainz) or an exact LRCLIB lyrics entry
    /// has the same title + artist and — when we know the file length — the same length.
    private func confirm(_ claim: Candidate, localDuration: Double?) async -> IdentifiedSong? {
        if let hit = await Self.itunesMatch(for: claim, localDuration: localDuration) {
            return Self.merge(claim: claim, catalog: hit, catalogName: "iTunes")
        }
        if let hit = await musicBrainzMatch(for: claim, localDuration: localDuration) {
            return Self.merge(claim: claim, catalog: hit, catalogName: "MusicBrainz")
        }
        if let duration = localDuration, !claim.artist.isEmpty,
           let lrc = await Self.lrclibExact(title: claim.title, artist: claim.artist, duration: duration) {
            return Self.merge(claim: claim, catalog: lrc, catalogName: "LRCLIB")
        }
        return nil
    }

    private static func merge(claim: Candidate, catalog: Candidate, catalogName: String) -> IdentifiedSong {
        IdentifiedSong(
            // Catalog spelling/capitalisation wins (it's what lyrics sites index).
            title: catalog.title,
            artist: catalog.artist,
            album: catalog.album ?? claim.album,
            genre: catalog.genre ?? claim.genre,
            isrc: catalog.isrc ?? claim.isrc,
            artworkURL: (catalog.artworkURL ?? claim.artworkURL).map(upscaledArtworkURL),
            durationSeconds: catalog.durationSeconds ?? claim.durationSeconds,
            source: "\(claim.sourceName) + \(catalogName)"
        )
    }

    // MARK: - Source: YouTube "Music" box

    /// Reads the "Music" section YouTube shows under many videos (song / artist / album). YouTube fills it
    /// with its own audio recognition, so it is accurate and needs no key.
    private static func youtubeMusicInVideo(videoID: String) async -> Candidate? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false") else { return nil }
        let body: [String: Any] = [
            "videoId": videoID,
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250220.01.00", "hl": "en", "gl": "US"]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20250220.01.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        if let cookies = await BrowserYouTubeResolver.youtubeCookieHeader() {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parseYouTubeMusicSection(json)
    }

    /// Handles both layouts YouTube has used: `videoAttributeViewModel` cards (title = song,
    /// subtitle = artist, secondarySubtitle = album) and older `infoRowRenderer` rows (SONG / ARTIST / ALBUM).
    nonisolated private static func parseYouTubeMusicSection(_ json: Any) -> Candidate? {
        var attributeCards: [[String: Any]] = []
        var infoRows: [(label: String, value: String)] = []

        func text(_ any: Any?) -> String? {
            if let s = any as? String { return s }
            guard let d = any as? [String: Any] else { return nil }
            if let s = d["simpleText"] as? String { return s }
            if let s = d["content"] as? String { return s }
            if let runs = d["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                return joined.isEmpty ? nil : joined
            }
            return nil
        }

        func walk(_ node: Any, depth: Int) {
            guard depth < 60 else { return }
            if let dict = node as? [String: Any] {
                if let card = dict["videoAttributeViewModel"] as? [String: Any] {
                    attributeCards.append(card)
                }
                if let row = dict["infoRowRenderer"] as? [String: Any],
                   let label = text(row["title"]),
                   let value = text(row["defaultMetadata"]) ?? text(row["expandedMetadata"]) {
                    infoRows.append((label.uppercased(), value))
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let array = node as? [Any] {
                for value in array { walk(value, depth: depth + 1) }
            }
        }
        walk(json, depth: 0)

        if let card = attributeCards.first,
           let title = text(card["title"]), !title.isEmpty,
           let artist = text(card["subtitle"]), !artist.isEmpty {
            var artURL: URL?
            if let image = card["image"] as? [String: Any],
               let sources = (image["sources"] as? [[String: Any]]) ?? ((image["image"] as? [String: Any])?["sources"] as? [[String: Any]]),
               let urlString = sources.last?["url"] as? String {
                artURL = URL(string: urlString)
            }
            return Candidate(
                title: title,
                artist: artist,
                album: text(card["secondarySubtitle"]),
                artworkURL: artURL,
                sourceName: "YouTube Music info"
            )
        }

        let song = infoRows.first(where: { $0.label == "SONG" })?.value
        let artist = infoRows.first(where: { $0.label == "ARTIST" || $0.label == "ARTISTS" })?.value
        if let song, let artist, !song.isEmpty, !artist.isEmpty {
            return Candidate(
                title: song,
                artist: artist,
                album: infoRows.first(where: { $0.label == "ALBUM" })?.value,
                sourceName: "YouTube Music info"
            )
        }
        return nil
    }

    // MARK: - Catalog: iTunes

    private static func itunesMatch(for claim: Candidate, localDuration: Double?) async -> Candidate? {
        let term = [claim.artist, stripVersionNoise(claim.title, keepVersionTags: false)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15")
        ]
        guard let url = comps?.url,
              let json = await fetchJSON(url),
              let rows = json["results"] as? [[String: Any]] else { return nil }

        var best: (score: Double, hit: Candidate)?
        for row in rows {
            guard let title = row["trackName"] as? String,
                  let artist = row["artistName"] as? String else { continue }
            let duration = (row["trackTimeMillis"] as? Double).map { $0 / 1000 }
            guard let score = matchScore(claim: claim, title: title, artist: artist, duration: duration, localDuration: localDuration) else {
                continue
            }
            let hit = Candidate(
                title: title,
                artist: artist,
                album: row["collectionName"] as? String,
                genre: row["primaryGenreName"] as? String,
                artworkURL: (row["artworkUrl100"] as? String).flatMap { URL(string: $0) },
                durationSeconds: duration,
                sourceName: "iTunes"
            )
            if best == nil || score > best!.score { best = (score, hit) }
        }
        return best?.hit
    }

    // MARK: - Catalog: MusicBrainz (+ Cover Art Archive)

    private func musicBrainzMatch(for claim: Candidate, localDuration: Double?) async -> Candidate? {
        guard !claim.artist.isEmpty else { return nil }
        // MusicBrainz allows ~1 request/second per app.
        let wait = 1.1 - Date().timeIntervalSince(lastMusicBrainzRequestAt)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastMusicBrainzRequestAt = Date()

        let safeTitle = Self.stripVersionNoise(claim.title, keepVersionTags: false).replacingOccurrences(of: "\"", with: "")
        let safeArtist = claim.artist.replacingOccurrences(of: "\"", with: "")
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording")
        comps?.queryItems = [
            URLQueryItem(name: "query", value: "recording:\"\(safeTitle)\" AND artist:\"\(safeArtist)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = comps?.url,
              let json = await Self.fetchJSON(url),
              let recordings = json["recordings"] as? [[String: Any]] else { return nil }

        var best: (score: Double, hit: Candidate)?
        for rec in recordings {
            guard let title = rec["title"] as? String else { continue }
            let credits = (rec["artist-credit"] as? [[String: Any]]) ?? []
            let artist = credits.map { (($0["name"] as? String) ?? "") + (($0["joinphrase"] as? String) ?? "") }.joined()
            let duration = (rec["length"] as? Double).map { $0 / 1000 }
            guard !artist.isEmpty,
                  let score = Self.matchScore(claim: claim, title: title, artist: artist, duration: duration, localDuration: localDuration) else {
                continue
            }
            let releases = (rec["releases"] as? [[String: Any]]) ?? []
            let release = releases.first(where: { ($0["status"] as? String) == "Official" }) ?? releases.first
            let cover = (release?["id"] as? String).flatMap { URL(string: "https://coverartarchive.org/release/\($0)/front-500") }
            let isrc = (rec["isrcs"] as? [String])?.first
            let hit = Candidate(
                title: title,
                artist: artist,
                album: release?["title"] as? String,
                isrc: isrc,
                artworkURL: cover,
                durationSeconds: duration,
                sourceName: "MusicBrainz"
            )
            if best == nil || score > best!.score { best = (score, hit) }
        }
        return best?.hit
    }

    // MARK: - Lyrics: LRCLIB exact match

    private static func lrclibExact(title: String, artist: String, duration: Double) async -> Candidate? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: stripVersionNoise(title, keepVersionTags: false)),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = comps?.url,
              let row = await fetchJSON(url),
              let name = row["trackName"] as? String,
              let rowArtist = row["artistName"] as? String else { return nil }
        let rowDuration = row["duration"] as? Double
        if let rowDuration, abs(rowDuration - duration) > durationTolerance { return nil }
        return Candidate(
            title: name,
            artist: rowArtist,
            album: row["albumName"] as? String,
            durationSeconds: rowDuration,
            sourceName: "LRCLIB"
        )
    }

    // MARK: - Matching

    /// nil = not the same song. Otherwise a 0...1 score (higher is better).
    nonisolated private static func matchScore(
        claim: Candidate,
        title: String,
        artist: String,
        duration: Double?,
        localDuration: Double?
    ) -> Double? {
        let titleSim = similarity(stripVersionNoise(claim.title, keepVersionTags: false), stripVersionNoise(title, keepVersionTags: false))
        guard titleSim >= 0.8 else { return nil }
        // A remix/live/acoustic tag on only one side means a different recording.
        if versionTags(stripVersionNoise(claim.title, keepVersionTags: true)) != versionTags(stripVersionNoise(title, keepVersionTags: true)) {
            return nil
        }

        var artistSim = 1.0
        if !claim.artist.isEmpty {
            artistSim = max(similarity(claim.artist, artist), containsArtist(artist, claim.artist) ? 0.9 : 0)
            guard artistSim >= 0.6 else { return nil }
        }

        var durationScore = 0.5
        if let localDuration, localDuration > 0, let duration, duration > 0 {
            let diff = abs(localDuration - duration)
            // Music videos often run longer than the song (intros, skits, outros). When the song name came
            // from a trusted source (the playlist or YouTube's Music box) and title+artist match exactly,
            // a longer video is still the same song. A guess from a cleaned-up video title must match tightly.
            let exact = titleSim >= 0.99 && artistSim >= 0.9
            let trusted = claim.sourceName != "Video title"
            let tolerance = exact ? (trusted ? 150 : durationTolerance * 3) : durationTolerance
            guard diff <= tolerance else { return nil }
            durationScore = 1 - diff / (tolerance + 1)
        }
        return titleSim * 0.5 + artistSim * 0.3 + durationScore * 0.2
    }

    nonisolated static func normalize(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: " and ")
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").map(String.init).filter { $0 != "the" && $0 != "a" }
    }

    /// Token-set similarity in 0...1.
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let ta = Set(normalize(a)), tb = Set(normalize(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta == tb { return 1 }
        let inter = Double(ta.intersection(tb).count)
        return (2 * inter) / Double(ta.count + tb.count)
    }

    nonisolated static func containsArtist(_ full: String, _ part: String) -> Bool {
        let f = Set(normalize(full)), p = Set(normalize(part))
        return !p.isEmpty && p.isSubset(of: f)
    }

    nonisolated private static let versionWords: Set<String> = [
        "remix", "live", "acoustic", "instrumental", "karaoke", "cover", "slowed", "reverb",
        "sped", "nightcore", "edit", "demo", "unplugged", "orchestral", "8d"
    ]

    nonisolated static func versionTags(_ title: String) -> Set<String> {
        Set(normalize(title)).intersection(versionWords)
    }

    /// Removes video/marketing noise ("Official Video", "[HD]", "(Lyrics)", "feat. X", "- Remastered 2011").
    /// With `keepVersionTags`, parenthesised version info like "(Live)" or "(Remix)" is kept.
    nonisolated static func stripVersionNoise(_ title: String, keepVersionTags: Bool) -> String {
        var result = title
        let noisePatterns = [
            #"(?i)[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|hd|4k|mv|m/v|music video|explicit|clean)[^\)\]]*[\)\]]"#,
            #"(?i)\s+-\s+(remaster(ed)?( \d{4})?|\d{4} remaster(ed)?|single version|radio edit|mono|stereo)\s*$"#,
            #"(?i)[\(\[](feat\.?|ft\.?|featuring|with) [^\)\]]*[\)\]]"#,
            #"(?i)\s+(feat\.?|ft\.?|featuring) .+$"#
        ]
        for pattern in noisePatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if !keepVersionTags {
            result = result.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        }
        return result
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|")))
    }

    // MARK: - Networking

    nonisolated static func upscaledArtworkURL(_ url: URL) -> URL {
        let s = url.absoluteString
        for small in ["100x100bb", "200x200bb", "300x300bb", "600x600bb"] where s.contains(small) {
            return URL(string: s.replacingOccurrences(of: small, with: "1000x1000bb")) ?? url
        }
        return url
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func downloadImage(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return UIImage(data: data)
    }
}
