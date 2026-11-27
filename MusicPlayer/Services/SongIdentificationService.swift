import AVFoundation
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

    nonisolated private static let userAgent = "MuseJRM/1.0 (https://github.com/jrmtakr/music-player)"
    /// Max length difference (seconds) for two sources to count as the same recording.
    nonisolated private static let durationTolerance: Double = 4

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
        guard !item.isHLS else {
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
        updateTrackStep(path: request.relativePath, progress: 0.08, label: "Reading track tags & metadata...")
        lastStatus = "AI analyzing \"\(request.hintTitle)\"..."

        let embedded = await Self.readEmbeddedMetadata(from: request.fileURL)
        let seedTitle = (embedded.title?.isEmpty == false ? embedded.title! : request.hintTitle)
        let seedArtist = (embedded.artist?.isEmpty == false ? embedded.artist! : request.hintArtist)
        let ytCards = (request.sourceVideoID?.isEmpty == false)
            ? await Self.youtubeMusicCardsInVideo(videoID: request.sourceVideoID!)
            : []

        if let earlyComp = ArtistDatabase.detectCompilation(
            rawTitle: seedTitle,
            rawArtistTag: seedArtist.isEmpty ? nil : seedArtist,
            fileName: request.fileURL.lastPathComponent,
            embeddedAlbum: embedded.album,
            durationSeconds: request.durationSeconds,
            youtubeSongs: ytCards.map { ($0.title, $0.artist, $0.genre) },
            allowLongDurationFallback: false
        ) {
            return await finalizeCompilation(
                earlyComp,
                ytCards: ytCards,
                request: request,
                allowOverwriteVerified: allowOverwriteVerified
            )
        }

        let bareFileTitle = request.fileURL.deletingPathExtension().lastPathComponent
        let fileHintParsed = ArtistDatabase.parseTrackHints(
            rawTitle: bareFileTitle,
            rawArtistTag: nil,
            fileName: request.fileURL.lastPathComponent,
            ignoredChannels: ListeningWrappedService.shared.ignoredChannels
        )
        let fileParsed = ArtistDatabase.parseTrackHints(
            rawTitle: seedTitle,
            rawArtistTag: seedArtist.isEmpty ? nil : seedArtist,
            fileName: request.fileURL.lastPathComponent,
            ignoredChannels: ListeningWrappedService.shared.ignoredChannels
        )
        let preferFileHint = !fileHintParsed.songTitle.isEmpty && (
            fileParsed.songTitle.isEmpty ||
            Self.isGenericTitleHint(fileParsed.songTitle) ||
            (fileParsed.artistHint == nil && fileHintParsed.artistHint != nil)
        )
        let effectiveParsed = preferFileHint ? fileHintParsed : fileParsed
        let bestSeedTitle = effectiveParsed.songTitle.isEmpty ? seedTitle : effectiveParsed.songTitle
        let bestSeedArtist = (effectiveParsed.artistHint ?? (seedArtist.isEmpty ? nil : ArtistDatabase.canonicalizeSingle(seedArtist))) ?? ""
        let fileAlbumOrProject = (embedded.album?.isEmpty == false ? embedded.album : nil) ?? effectiveParsed.albumHint ?? fileHintParsed.albumHint

        var song = await identify(
            fileURL: request.fileURL,
            hintTitle: bestSeedTitle,
            hintArtist: bestSeedArtist,
            durationSeconds: request.durationSeconds,
            sourceVideoID: request.sourceVideoID,
            sourcePlatform: request.sourcePlatform,
            fileParsed: effectiveParsed,
            alternateFileParsed: fileHintParsed
        )
        if let candidate = song,
           !acceptCandidateSong(
               candidate,
               seedTitle: bestSeedTitle,
               seedArtist: bestSeedArtist,
               relativePath: request.relativePath,
               bareFileTitle: bareFileTitle
           ) {
            song = nil
        }

        // Listen to the whole song: confirm the name from the sung lyrics, identify unknown uploads
        // with Shazam acoustic matching, and align lyrics with this exact recording before playback.
        await Self.ensureSpeechPermissionIfPossible()
        updateTrackStep(path: request.relativePath, progress: 0.15, label: "AI listening to whole song...")
        lastStatus = "Listening to whole song: \"\(song?.title ?? bestSeedTitle)\"..."

        let capturedPath = request.relativePath
        let capturedLabelTitle = song?.title ?? bestSeedTitle
        let listenSummary = await SongAudioListener.listenWithSummary(
            to: request.fileURL,
            titleHint: bestSeedTitle,
            artistHint: bestSeedArtist.isEmpty ? nil : bestSeedArtist
        ) { [weak self] chunkIdx, totalChunks, totalSeconds in
            Task { @MainActor in
                let frac = 0.15 + 0.52 * (Double(chunkIdx) / Double(max(1, totalChunks)))
                let mins = Int(totalSeconds) / 60
                let secs = Int(totalSeconds) % 60
                let label = "AI listening to song (\(chunkIdx)/\(totalChunks) • \(mins):\(String(format: "%02d", secs)))..."
                self?.updateTrackStep(path: capturedPath, progress: frac, label: label)
                self?.lastStatus = "Listening to whole song (\(chunkIdx)/\(totalChunks)): \"\(capturedLabelTitle)\""
            }
        }
        let heard: [HeardWord]? = listenSummary.words.isEmpty ? nil : listenSummary.words
        let langCtx = SongAudioListener.detectLanguageContext(
            title: bestSeedTitle,
            artist: bestSeedArtist.isEmpty ? nil : bestSeedArtist
        )
        let isNonEnglishTrack = langCtx.isNonEnglish || {
            guard let lang = listenSummary.detectedLanguage?.lowercased(), !lang.isEmpty else { return false }
            return !lang.hasPrefix("en")
        }()
        let titleHasInstrumentalHint = SongAudioListener.hasInstrumentalFilenameHint(bestSeedTitle)
            || SongAudioListener.hasInstrumentalFilenameHint(seedTitle)
            || SongAudioListener.hasInstrumentalFilenameHint(bareFileTitle)
        let blockEnglishAudioGuess = listenSummary.isMostlyInstrumental || titleHasInstrumentalHint || isNonEnglishTrack
        var lyricsToAlign: ResolvedTrackLyrics?

        if var candidate = song, let heard, !listenSummary.isMostlyInstrumental, !titleHasInstrumentalHint {
            if let lyrics = await SyncedLyricsService.shared.fetchLyricsForVerification(
                title: candidate.title,
                artist: candidate.artist,
                duration: candidate.durationSeconds ?? request.durationSeconds
            ), Self.similarity(Self.stripVersionNoise(lyrics.trackTitle, keepVersionTags: false),
                                Self.stripVersionNoise(candidate.title, keepVersionTags: false)) >= 0.8 {
                let englishASROnForeignTrack = isNonEnglishTrack
                    && (listenSummary.detectedLanguage?.lowercased().hasPrefix("en") ?? false)
                switch SongAudioListener.verdict(heard: heard, lyrics: lyrics) {
                case .confirmed:
                    candidate.source += " + heard lyrics match"
                    lyricsToAlign = lyrics
                    song = candidate
                case .contradicted:
                    // Keep verified catalog/playlist/title metadata (noisy ASR on beats/skits must never
                    // wipe out a real match); if foreign vocals were transcribed in English, don't block valid foreign lyrics.
                    lyricsToAlign = englishASROnForeignTrack ? lyrics : nil
                case .inconclusive:
                    lyricsToAlign = lyrics
                }
            }
        }

        if song == nil, let heard, !blockEnglishAudioGuess {
            updateTrackStep(path: request.relativePath, progress: 0.72, label: "Matching heard lyrics...")
            if let byLyrics = await identifyFromHeardLyrics(heard, localDuration: request.durationSeconds),
               acceptCandidateSong(
                   byLyrics.song,
                   seedTitle: bestSeedTitle,
                   seedArtist: bestSeedArtist,
                   relativePath: request.relativePath,
                   bareFileTitle: bareFileTitle
               ) {
                song = byLyrics.song
                lyricsToAlign = byLyrics.lyrics
            }
        }

        // Shazam acoustic constellation + preview matcher across the whole song (lyric guessing disabled for foreign/instrumental tracks).
        if song == nil {
            updateTrackStep(path: request.relativePath, progress: 0.77, label: "Running Shazam AI acoustic match...")
            lastStatus = "Running Shazam AI acoustic fingerprint..."
            let splitSeed = bestSeedArtist.isEmpty ? Self.splitTrailingCatalogArtist(bestSeedTitle) : nil
            let shazamSeedTitle = splitSeed?.title ?? bestSeedTitle
            let shazamSeedArtist = splitSeed?.artist ?? bestSeedArtist
            if case .match(let shazamSong) = await ShazamFingerprintEngine.shared.recognize(
                fileURL: request.fileURL,
                durationHint: request.durationSeconds,
                seedHintTitle: shazamSeedTitle,
                seedHintArtist: shazamSeedArtist,
                heardWords: heard,
                allowLyricSearch: !blockEnglishAudioGuess
            ), acceptCandidateSong(
                shazamSong,
                seedTitle: bestSeedTitle,
                seedArtist: bestSeedArtist,
                relativePath: request.relativePath,
                bareFileTitle: bareFileTitle
            ) {
                song = shazamSong
            }
        }

        // Unreleased / leak song rescue via Genius (matches unreleased catalog such as Kanye West / Ye leaks).
        if song == nil, !bestSeedTitle.isEmpty, !Self.isGenericTitleHint(bestSeedTitle) {
            updateTrackStep(path: request.relativePath, progress: 0.81, label: "Checking unreleased catalog & lyrics...")
            if let geniusHit = await SyncedLyricsService.shared.fetchGeniusTrackDetails(
                song: bestSeedTitle,
                artist: bestSeedArtist
            ) {
                var acceptable = true
                if !blockEnglishAudioGuess, let heard, !heard.isEmpty {
                    if case .contradicted = SongAudioListener.verdict(heard: heard, lyrics: geniusHit.lyrics) {
                        acceptable = false
                    }
                }
                if acceptable {
                    let releaseAlbum = Self.normalizeReleaseLabel(
                        geniusHit.album ?? fileAlbumOrProject,
                        fallbackWhenNoAlbum: effectiveParsed.isExplicitSingle ? "Single" : "Unknown Single"
                    )
                    let geniusSong = IdentifiedSong(
                        title: geniusHit.title,
                        artist: geniusHit.artist,
                        album: releaseAlbum,
                        genre: ArtistDatabase.genre(forArtist: geniusHit.artist),
                        isrc: nil,
                        artworkURL: nil,
                        durationSeconds: request.durationSeconds,
                        source: "Genius Unreleased Match"
                    )
                    if acceptCandidateSong(
                        geniusSong,
                        seedTitle: bestSeedTitle,
                        seedArtist: bestSeedArtist,
                        relativePath: request.relativePath,
                        bareFileTitle: bareFileTitle
                    ) {
                        song = geniusSong
                        lyricsToAlign = geniusHit.lyrics
                    }
                }
            }
        }

        let heardExcerpt = heard.map { $0.prefix(16).map(\.token).joined(separator: " ") }
        let heardCount = heard?.count ?? 0

        guard var finalSong = song else {
            if let lateComp = ArtistDatabase.detectCompilation(
                rawTitle: seedTitle,
                rawArtistTag: seedArtist.isEmpty ? nil : seedArtist,
                fileName: request.fileURL.lastPathComponent,
                embeddedAlbum: embedded.album,
                durationSeconds: request.durationSeconds,
                youtubeSongs: ytCards.map { ($0.title, $0.artist, $0.genre) },
                allowLongDurationFallback: true
            ) {
                return await finalizeCompilation(
                    lateComp,
                    ytCards: ytCards,
                    request: request,
                    allowOverwriteVerified: allowOverwriteVerified
                )
            }

            // Even when a song isn't in any database, preserve/apply on-file song name & artist,
            // classify album vs Unknown Single cleanly, extract local artwork/frame, and sync/transcribe lyrics.
            updateTrackStep(path: request.relativePath, progress: 0.88, label: "Saving file metadata & syncing lyrics...")
            let fallbackTitle = bestSeedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (request.fileURL.deletingPathExtension().lastPathComponent)
                : bestSeedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackArtist = bestSeedArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Unknown Artist"
                : bestSeedArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackAlbum: String = {
                if let explicitProj = fileAlbumOrProject, !explicitProj.isEmpty {
                    return explicitProj
                }
                return effectiveParsed.isExplicitSingle ? "Single" : "Unknown Single"
            }()
            let fallbackGenre = (fallbackArtist != "Unknown Artist") ? ArtistDatabase.genre(forArtist: fallbackArtist) : nil
            let existingThumb = MediaManager.shared.thumbnails[request.relativePath]
            let frameCover: UIImage? = (existingThumb == nil)
                ? await Task.detached(priority: .utility) { FFmpegMediaService.extractArtworkOrFrame(from: request.fileURL, at: 2.0, maxDimension: 640) }.value
                : nil

            if fallbackArtist != "Unknown Artist" || fallbackTitle != request.hintTitle || frameCover != nil || !fallbackAlbum.isEmpty {
                _ = MediaManager.shared.applyAutoIdentifiedMetadata(
                    relativePath: request.relativePath,
                    title: fallbackTitle,
                    artist: fallbackArtist,
                    album: fallbackAlbum,
                    genre: fallbackGenre,
                    isrc: nil,
                    coverImage: frameCover,
                    source: "On-File AI Analysis",
                    forceOverwriteVerified: allowOverwriteVerified
                )
            }

            var alignedDuringImport = false
            if !titleHasInstrumentalHint,
               let item = MediaManager.shared.items.first(where: { $0.relativePath == request.relativePath }) {
                alignedDuringImport = await SyncedLyricsService.shared.fetchAndAlignDuringImport(
                    item: item,
                    title: fallbackTitle,
                    artist: fallbackArtist == "Unknown Artist" ? "" : fallbackArtist,
                    duration: request.durationSeconds,
                    heard: heard
                )
            }
            WholeSongAIService.shared.markCompletedFromImport(
                relativePath: request.relativePath,
                title: fallbackTitle,
                album: fallbackAlbum,
                artist: fallbackArtist,
                genre: fallbackGenre,
                heardWordCount: heardCount,
                heardExcerpt: heardExcerpt,
                hasLyrics: alignedDuringImport
            )
            progressByPath[request.relativePath] = 1.0
            lastStatus = "AI analyzed: \"\(fallbackTitle)\" by \(fallbackArtist) (\(fallbackAlbum))"
            return nil
        }

        // Prefer explicit on-file project/album tag (e.g. "Bully") when catalog returned nil or generic empty release;
        // otherwise classify release cleanly as Album vs "Single" vs "Unknown Single".
        if finalSong.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            finalSong.album = fileAlbumOrProject ?? (effectiveParsed.isExplicitSingle ? "Single" : "Single")
        } else {
            finalSong.album = Self.normalizeReleaseLabel(finalSong.album, fallbackWhenNoAlbum: fileAlbumOrProject ?? "Single")
        }

        updateTrackStep(path: request.relativePath, progress: 0.85, label: "Saving verified title, artist & cover...")
        var cover: UIImage?
        if let artURL = finalSong.artworkURL {
            cover = await Self.downloadImage(artURL)
        }
        if cover == nil && MediaManager.shared.thumbnails[request.relativePath] == nil {
            cover = await Task.detached(priority: .utility) {
                FFmpegMediaService.extractArtworkOrFrame(from: request.fileURL, at: 2.0, maxDimension: 640)
            }.value
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
            lastStatus = "Identified \"\(finalSong.title)\" by \(finalSong.artist) (\(finalSong.album ?? "Single"))"
            if let jobID = request.jobID {
                PlaylistImportManager.shared.noteTrackIdentified(jobID: jobID)
            }
        }

        // Index this confirmed track into our local Shazam acoustic fingerprint DB.
        if Self.normalize(finalSong.title) != Self.normalize(finalSong.artist) {
            let indexFileURL = request.fileURL
            let indexPath = request.relativePath
            let confirmedSnapshot = finalSong
            Task.detached(priority: .background) {
                await ShazamFingerprintEngine.shared.indexConfirmedTrack(
                    fileURL: indexFileURL,
                    trackKey: indexPath,
                    song: confirmedSnapshot
                )
            }
        }

        // Pre-fetch & auto-align lyrics to this exact file during import (Speech anchors + Acoustic vocal alignment)
        // so lyrics always line up immediately on first playback with zero user input.
        updateTrackStep(path: request.relativePath, progress: 0.92, label: "Aligning lyrics across whole song...")
        var hasFinalLyrics = false
        if !titleHasInstrumentalHint,
           let item = MediaManager.shared.items.first(where: { $0.relativePath == request.relativePath }) {
            if let lyrics = lyricsToAlign {
                let aligned = await SongAudioListener.autoAlign(lyrics: lyrics, heard: heard, fileURL: item.fileURL)
                SyncedLyricsService.shared.storeAlignedLyrics(aligned, for: item)
                hasFinalLyrics = true
            } else {
                hasFinalLyrics = await SyncedLyricsService.shared.fetchAndAlignDuringImport(
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
            hasLyrics: hasFinalLyrics
        )
        progressByPath[request.relativePath] = 1.0
        return applied ? finalSong : nil
    }

    private func finalizeCompilation(
        _ comp: ArtistDatabase.CompilationDetection,
        ytCards: [Candidate],
        request: Request,
        allowOverwriteVerified: Bool
    ) async -> IdentifiedSong {
        updateTrackStep(path: request.relativePath, progress: 0.65, label: "Detected compilation — resolving genre & cover...")
        var resolvedGenre = comp.genre
        if resolvedGenre == "Music" {
            for card in ytCards.prefix(3) {
                if let hit = await Self.itunesMatch(for: card, localDuration: nil),
                   let norm = ArtistDatabase.normalizeGenreLabel(hit.genre) {
                    resolvedGenre = norm
                    break
                }
            }
        }
        if resolvedGenre == "Music",
           comp.artistLabel != "Various Artists",
           let artistGenre = ArtistDatabase.normalizeGenreLabel(ArtistDatabase.genre(forArtist: comp.artistLabel)) {
            resolvedGenre = artistGenre
        }
        let albumLabel = "\(resolvedGenre) Compilation"

        var cover: UIImage?
        if let artURL = ytCards.compactMap(\.artworkURL).first {
            cover = await Self.downloadImage(Self.upscaledArtworkURL(artURL))
        }
        if cover == nil && MediaManager.shared.thumbnails[request.relativePath] == nil {
            cover = await Task.detached(priority: .utility) {
                FFmpegMediaService.extractArtworkOrFrame(from: request.fileURL, at: 4.0, maxDimension: 640)
            }.value
        }

        _ = MediaManager.shared.applyAutoIdentifiedMetadata(
            relativePath: request.relativePath,
            title: comp.cleanTitle,
            artist: comp.artistLabel,
            album: albumLabel,
            genre: resolvedGenre,
            isrc: nil,
            coverImage: cover,
            source: "AI Compilation Analysis",
            forceOverwriteVerified: allowOverwriteVerified
        )
        WholeSongAIService.shared.markCompletedFromImport(
            relativePath: request.relativePath,
            title: comp.cleanTitle,
            album: albumLabel,
            artist: comp.artistLabel,
            genre: resolvedGenre,
            heardWordCount: 0,
            heardExcerpt: nil,
            hasLyrics: false
        )
        progressByPath[request.relativePath] = 1.0
        lastStatus = "Identified \(albumLabel): \"\(comp.cleanTitle)\""
        return IdentifiedSong(
            title: comp.cleanTitle,
            artist: comp.artistLabel,
            album: albumLabel,
            genre: resolvedGenre,
            isrc: nil,
            artworkURL: ytCards.compactMap(\.artworkURL).first,
            durationSeconds: request.durationSeconds,
            source: "AI Compilation Analysis"
        )
    }

    private static func readEmbeddedMetadata(from url: URL) async -> (title: String?, artist: String?, album: String?) {
        let ffInfo = await Task.detached(priority: .utility) {
            FFmpegMediaService.probeMetadata(for: url)
        }.value
        var title = ffInfo?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var artist = ffInfo?.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        var album = ffInfo?.album?.trimmingCharacters(in: .whitespacesAndNewlines)

        if (title?.isEmpty != false) || (artist?.isEmpty != false) || (album?.isEmpty != false) {
            let asset = AVURLAsset(url: url)
            if let commonMeta = try? await asset.load(.commonMetadata) {
                for meta in commonMeta {
                    let key = meta.commonKey
                    let strVal = try? await meta.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let val = strVal, !val.isEmpty else { continue }
                    if key == .commonKeyTitle && (title?.isEmpty != false) { title = val }
                    else if key == .commonKeyArtist && (artist?.isEmpty != false) { artist = val }
                    else if key == .commonKeyAlbumName && (album?.isEmpty != false) { album = val }
                }
            }
        }
        return (
            (title?.isEmpty == false) ? title : nil,
            (artist?.isEmpty == false) ? artist : nil,
            (album?.isEmpty == false) ? album : nil
        )
    }

    private static func normalizeReleaseLabel(_ raw: String?, fallbackWhenNoAlbum: String) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return fallbackWhenNoAlbum
        }
        let lower = trimmed.lowercased()
        if lower == "single" || lower.hasSuffix(" - single") || lower.hasSuffix(" [single]") || lower.hasSuffix(" (single)") {
            return "Single"
        }
        return trimmed
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
                if let localDuration, localDuration > 10, let duration, abs(localDuration - duration) > 25 {
                    continue
                }
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
                guard case .confirmed(let ratio) = SongAudioListener.verdict(heard: heard, lyrics: lyrics),
                      ratio >= 0.45,
                      SongAudioListener.hasOrderedPhraseMatch(heard: heard, lyrics: lyrics) else {
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

    nonisolated private static func splitTrailingCatalogArtist(_ rawTitle: String) -> (title: String, artist: String)? {
        let noParen = stripVersionNoise(rawTitle, keepVersionTags: false)
        let tokens = noParen.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        for splitLen in [2, 1] where tokens.count > splitLen {
            let suffix = tokens.suffix(splitLen).joined(separator: " ")
            if ArtistDatabase.lookup(suffix) != nil {
                let prefix = tokens.dropLast(splitLen).joined(separator: " ")
                if !prefix.isEmpty {
                    return (prefix, ArtistDatabase.canonicalizeSingle(suffix))
                }
            }
        }
        return nil
    }

    nonisolated private static func isGenericTitleHint(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        let genericExact: Set<String> = [
            "audio", "track", "song", "music", "video", "untitled", "unknown",
            "recording", "voice memo", "videoplayback", "download", "clip", "sound"
        ]
        if genericExact.contains(lower) { return true }
        if lower.range(of: #"^(track|audio|song|video|recording|img|dsc|vid|aud|download|copy)[\s_\-#()]*\d*$"#, options: .regularExpression) != nil {
            return true
        }
        // Pure digits or YouTube-style 11-char opaque IDs with no spaces
        if lower.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil { return true }
        if trimmed.count == 11, !trimmed.contains(" "),
           trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
           trimmed.range(of: #"[A-Z]"#, options: .regularExpression) != nil,
           trimmed.range(of: #"[0-9]"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func acceptCandidateSong(
        _ candidate: IdentifiedSong,
        seedTitle: String,
        seedArtist: String,
        relativePath: String,
        bareFileTitle: String
    ) -> Bool {
        let cleanCand = Self.stripVersionNoise(candidate.title, keepVersionTags: false)
        let candTitleNorm = Self.normalize(cleanCand)
        let candArtistNorm = Self.normalize(candidate.artist)
        guard !candTitleNorm.isEmpty else { return false }

        let cleanSeed = Self.stripVersionNoise(seedTitle, keepVersionTags: false)
        let seedTitleNorm = Self.normalize(cleanSeed)
        let seedArtistNorm = Self.normalize(seedArtist)

        // Never accept a song whose title is identical to its own artist unless the source file literally said that.
        if candTitleNorm == candArtistNorm, seedTitleNorm != seedArtistNorm {
            return false
        }

        let seedLooksReal = !cleanSeed.isEmpty && !Self.isGenericTitleHint(cleanSeed) && !Self.isGenericTitleHint(bareFileTitle)
        if seedLooksReal {
            let titleMatch = Self.similarity(cleanSeed, cleanCand)
            // Never allow the artist name from "Song - Artist" to replace the actual song title.
            if !seedArtist.isEmpty, Self.similarity(seedArtist, cleanCand) >= 0.85, titleMatch < 0.35 {
                return false
            }

            let lowerSrc = candidate.source.lowercased()
            let isWeakTextGuess = lowerSrc.contains("heard lyrics")
                || lowerSrc.contains("genius")
                || lowerSrc.contains("lyrics search")
                || (lowerSrc.contains("shazam") && !lowerSrc.contains("acoustic"))
            if isWeakTextGuess && titleMatch < 0.45 {
                return false
            }

            // Anti-duplicate guard: refuse to copy an existing library track's song title onto a differently-named file.
            for other in MediaManager.shared.items where other.relativePath != relativePath {
                let custom = MediaManager.shared.customMetadata(forRelativePath: other.relativePath)
                let otherTitle = custom?.title ?? other.displayTitle
                let cleanOther = Self.stripVersionNoise(otherTitle, keepVersionTags: false)
                guard !cleanOther.isEmpty else { continue }
                if Self.similarity(cleanOther, cleanCand) >= 0.90, titleMatch < 0.50 {
                    return false
                }
            }
        }
        return true
    }

    /// Works out the real title/artist/album/cover for a file. Returns nil when the sources don't agree
    /// (the caller then keeps the original title rather than guessing).
    func identify(
        fileURL: URL,
        hintTitle: String,
        hintArtist: String,
        durationSeconds: Double?,
        sourceVideoID: String?,
        sourcePlatform: ExternalPlaylistPlatform?,
        fileParsed: ArtistDatabase.ParsedTrackHints? = nil,
        alternateFileParsed: ArtistDatabase.ParsedTrackHints? = nil
    ) async -> IdentifiedSong? {
        // --- Gather "what it claims to be" ---------------------------------------------------
        var claims: [Candidate] = []
        var seenClaimKeys = Set<String>()
        func appendUniqueClaim(_ c: Candidate) {
            let cleanT = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanA = c.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanT.isEmpty else { return }
            let key = Self.normalize(cleanT).joined(separator: " ") + "::" + Self.normalize(cleanA).joined(separator: " ") + "::" + c.sourceName
            guard seenClaimKeys.insert(key).inserted else { return }
            claims.append(Candidate(
                title: cleanT,
                artist: cleanA,
                album: c.album,
                genre: c.genre,
                isrc: c.isrc,
                artworkURL: c.artworkURL,
                durationSeconds: c.durationSeconds,
                sourceName: c.sourceName
            ))
        }

        // 1) Spotify / Apple Music playlists carry exact catalog titles & artists.
        if sourcePlatform == .spotify || sourcePlatform == .appleMusic,
           !hintTitle.isEmpty, !hintArtist.isEmpty {
            appendUniqueClaim(Candidate(
                title: Self.stripVersionNoise(hintTitle, keepVersionTags: true),
                artist: hintArtist,
                sourceName: "\(sourcePlatform?.rawValue ?? "Playlist") playlist"
            ))
        }

        // 2) YouTube's own "Music" box for this video.
        if let videoID = sourceVideoID, !videoID.isEmpty,
           let ytMusic = await Self.youtubeMusicCardsInVideo(videoID: videoID).first {
            appendUniqueClaim(ytMusic)
        }

        // 3) Cleaned-up song title + artist ("Song - Artist (Official Video)" → "Song" / "Artist").
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: hintTitle,
            rawArtistTag: hintArtist.isEmpty ? nil : hintArtist
        )
        let cleanedTitle = Self.stripVersionNoise(cleaned.songOnly, keepVersionTags: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A channel name like "SomeUploader" or "ArtistVEVO" / "Artist - Topic" isn't a reliable artist.
        let channel = hintArtist
            .replacingOccurrences(of: #"(?i)\s*-\s*topic$|vevo$|\s+official$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channelIsUploader = ArtistDatabase.looksLikeUploaderChannel(hintArtist)
        let cleanedArtist = (cleaned.artistHint ?? (channelIsUploader ? "" : channel))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            appendUniqueClaim(Candidate(title: cleanedTitle, artist: cleanedArtist, sourceName: "Video title"))
        }

        // 3b) Direct bare-filename claim if it differs from video metadata (helps when embedded/import tags are generic or wrong).
        if let altFile = alternateFileParsed, !altFile.songTitle.isEmpty {
            let bareClean = Self.stripVersionNoise(altFile.songTitle, keepVersionTags: true)
            appendUniqueClaim(Candidate(
                title: bareClean,
                artist: altFile.artistHint ?? cleanedArtist,
                sourceName: "File name"
            ))
        }

        // 3c) Concatenated catalog artist at the end of a title without a separator (e.g. "Puzzle Roundtable (feat. Ning)" → "Puzzle" + "ROUND TABLE").
        if cleanedArtist.isEmpty, let split = Self.splitTrailingCatalogArtist(cleanedTitle) {
            appendUniqueClaim(Candidate(title: split.title, artist: split.artist, sourceName: "Catalog artist split"))
        }

        // 3d) Alternate orientation fallback ("Artist - Song" ↔ "Song - Artist", or "Song (Artist)").
        if let pair = fileParsed?.alternatePair ?? alternateFileParsed?.alternatePair {
            let cleanAltSong = Self.stripVersionNoise(pair.song, keepVersionTags: true)
            appendUniqueClaim(Candidate(title: cleanAltSong, artist: pair.artist, sourceName: "Alternate orientation"))
        }

        // --- Confirm each claim against catalogs, strongest claim first -----------------------
        for claim in claims {
            if let confirmed = await confirm(claim, localDuration: durationSeconds) {
                return confirmed
            }
        }

        // A trusted claim that no catalog knows (indie/unreleased) is still better than a video title,
        // but only if it came from the playlist or YouTube's Music box, never from a cleaned-up title.
        if let trusted = claims.first(where: {
            $0.sourceName != "Video title"
                && $0.sourceName != "File name"
                && $0.sourceName != "Alternate orientation"
                && $0.sourceName != "Catalog artist split"
        }) {
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
        if cleanedArtist.isEmpty && best.durationSeconds == nil {
            return nil
        }
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

    /// A claim is confirmed when a catalog (iTunes, Deezer, or MusicBrainz) or an exact LRCLIB lyrics entry
    /// has the same title + artist and — when we know the file length — the same length.
    private func confirm(_ claim: Candidate, localDuration: Double?) async -> IdentifiedSong? {
        if let hit = await Self.itunesMatch(for: claim, localDuration: localDuration) {
            return Self.merge(claim: claim, catalog: hit, catalogName: "iTunes")
        }
        if let hit = await Self.deezerMatch(for: claim, localDuration: localDuration) {
            return Self.merge(claim: claim, catalog: hit, catalogName: "Deezer")
        }
        if let hit = await musicBrainzMatch(for: claim, localDuration: localDuration) {
            return Self.merge(claim: claim, catalog: hit, catalogName: "MusicBrainz")
        }
        if let duration = localDuration {
            if !claim.artist.isEmpty,
               let lrc = await Self.lrclibExact(title: claim.title, artist: claim.artist, duration: duration) {
                return Self.merge(claim: claim, catalog: lrc, catalogName: "LRCLIB")
            }
            if claim.artist.isEmpty,
               claim.sourceName != "Alternate orientation",
               !Self.isGenericTitleHint(claim.title),
               let lrc = await Self.lrclibTitleMatch(title: claim.title, duration: duration) {
                let enriched = Candidate(title: lrc.title, artist: lrc.artist, sourceName: claim.sourceName)
                if let hit = await Self.itunesMatch(for: enriched, localDuration: localDuration) {
                    return Self.merge(claim: claim, catalog: hit, catalogName: "LRCLIB + iTunes")
                }
                if let hit = await Self.deezerMatch(for: enriched, localDuration: localDuration) {
                    return Self.merge(claim: claim, catalog: hit, catalogName: "LRCLIB + Deezer")
                }
                return Self.merge(claim: claim, catalog: lrc, catalogName: "LRCLIB")
            }
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

    /// Reads all tracks listed in YouTube's "Music" section under a video (single track or multi-track compilation).
    private static func youtubeMusicCardsInVideo(videoID: String) async -> [Candidate] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false") else { return [] }
        let body: [String: Any] = [
            "videoId": videoID,
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250220.01.00", "hl": "en", "gl": "US"]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }
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
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return parseYouTubeMusicCards(json)
    }

    /// Handles both layouts YouTube has used: `videoAttributeViewModel` cards (title = song,
    /// subtitle = artist, secondarySubtitle = album) and older `infoRowRenderer` rows (SONG / ARTIST / ALBUM).
    nonisolated private static func parseYouTubeMusicCards(_ json: Any) -> [Candidate] {
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

        var results: [Candidate] = []
        for card in attributeCards {
            guard let title = text(card["title"]), !title.isEmpty,
                  let artist = text(card["subtitle"]), !artist.isEmpty else { continue }
            var artURL: URL?
            if let image = card["image"] as? [String: Any],
               let sources = (image["sources"] as? [[String: Any]]) ?? ((image["image"] as? [String: Any])?["sources"] as? [[String: Any]]),
               let urlString = sources.last?["url"] as? String {
                artURL = URL(string: urlString)
            }
            results.append(Candidate(
                title: title,
                artist: artist,
                album: text(card["secondarySubtitle"]),
                artworkURL: artURL,
                sourceName: "YouTube Music info"
            ))
        }
        if !results.isEmpty {
            return results
        }

        let song = infoRows.first(where: { $0.label == "SONG" })?.value
        let artist = infoRows.first(where: { $0.label == "ARTIST" || $0.label == "ARTISTS" })?.value
        if let song, let artist, !song.isEmpty, !artist.isEmpty {
            return [Candidate(
                title: song,
                artist: artist,
                album: infoRows.first(where: { $0.label == "ALBUM" })?.value,
                sourceName: "YouTube Music info"
            )]
        }
        return []
    }

    // MARK: - Catalog: iTunes

    private static func itunesMatch(for claim: Candidate, localDuration: Double?) async -> Candidate? {
        let term = [claim.artist, stripVersionNoise(claim.title, keepVersionTags: false)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let langCtx = SongAudioListener.detectLanguageContext(title: claim.title, artist: claim.artist)
        var countries: [String] = []
        if langCtx.isNonEnglish {
            countries = Array(langCtx.preferredITunesCountries.prefix(3))
            if !countries.contains(where: { $0.uppercased() == "US" }) {
                countries.append("US")
            }
        } else {
            countries = ["US"]
            for c in langCtx.preferredITunesCountries where !countries.contains(c) && countries.count < 3 {
                countries.append(c)
            }
        }
        let resultLimit = claim.artist.isEmpty ? "25" : "15"

        var best: (score: Double, hit: Candidate)?
        for country in countries.prefix(3) {
            var comps = URLComponents(string: "https://itunes.apple.com/search")
            comps?.queryItems = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "media", value: "music"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: resultLimit)
            ]
            guard let url = comps?.url,
                  let json = await fetchJSON(url),
                  let rows = json["results"] as? [[String: Any]] else { continue }

            for row in rows {
                guard let title = row["trackName"] as? String,
                      let artist = row["artistName"] as? String else { continue }
                let duration = (row["trackTimeMillis"] as? NSNumber).map { $0.doubleValue / 1000.0 }
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
            if best != nil { break }
        }
        return best?.hit
    }

    // MARK: - Catalog: Deezer (global & indie tracks, no key required)

    private static func deezerMatch(for claim: Candidate, localDuration: Double?) async -> Candidate? {
        let term = [claim.artist, stripVersionNoise(claim.title, keepVersionTags: false)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var comps = URLComponents(string: "https://api.deezer.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "limit", value: claim.artist.isEmpty ? "20" : "15")
        ]
        guard let url = comps?.url,
              let json = await fetchJSON(url),
              let rows = json["data"] as? [[String: Any]] else { return nil }

        var best: (score: Double, hit: Candidate)?
        for row in rows {
            guard let title = row["title"] as? String,
                  let artistObj = row["artist"] as? [String: Any],
                  let artist = artistObj["name"] as? String else { continue }
            let duration = (row["duration"] as? NSNumber)?.doubleValue
            guard let score = matchScore(claim: claim, title: title, artist: artist, duration: duration, localDuration: localDuration) else {
                continue
            }
            let albumObj = row["album"] as? [String: Any]
            let coverStr = (albumObj?["cover_xl"] as? String)
                ?? (albumObj?["cover_big"] as? String)
                ?? (albumObj?["cover_medium"] as? String)
            let hit = Candidate(
                title: title,
                artist: artist,
                album: albumObj?["title"] as? String,
                isrc: row["isrc"] as? String,
                artworkURL: coverStr.flatMap { URL(string: $0) },
                durationSeconds: duration,
                sourceName: "Deezer"
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
            let duration = (rec["length"] as? NSNumber).map { $0.doubleValue / 1000.0 }
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
        let rowDuration = (row["duration"] as? NSNumber)?.doubleValue
        if let rowDuration, abs(rowDuration - duration) > durationTolerance { return nil }
        return Candidate(
            title: name,
            artist: rowArtist,
            album: row["albumName"] as? String,
            durationSeconds: rowDuration,
            sourceName: "LRCLIB"
        )
    }

    /// Resolves a title-only file (e.g. "STARS.mp4" @ 115.2s) via LRCLIB only when exact title + tight duration uniquely identifies one artist.
    private static func lrclibTitleMatch(title: String, duration: Double) async -> Candidate? {
        let stripped = stripVersionNoise(title, keepVersionTags: false)
        guard !stripped.isEmpty else { return nil }
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: stripped)
        ]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        var matches: [(diff: Double, artistKey: String, hit: Candidate)] = []
        for row in rows {
            guard let name = row["trackName"] as? String,
                  let rowArtist = row["artistName"] as? String,
                  !rowArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rowDuration = (row["duration"] as? NSNumber)?.doubleValue else { continue }
            let diff = abs(rowDuration - duration)
            guard diff <= 3.0 else { continue }
            guard similarity(stripped, stripVersionNoise(name, keepVersionTags: false)) >= 0.92,
                  versionTags(stripVersionNoise(title, keepVersionTags: true)) == versionTags(stripVersionNoise(name, keepVersionTags: true)) else {
                continue
            }
            let artistKey = normalize(rowArtist).joined(separator: " ")
            guard !artistKey.isEmpty else { continue }
            matches.append((
                diff,
                artistKey,
                Candidate(
                    title: name,
                    artist: rowArtist,
                    album: row["albumName"] as? String,
                    durationSeconds: rowDuration,
                    sourceName: "LRCLIB"
                )
            ))
        }
        guard !matches.isEmpty else { return nil }
        let sorted = matches.sorted { $0.diff < $1.diff }
        let uniqueArtists = Set(sorted.map(\.artistKey))
        if uniqueArtists.count == 1 {
            return sorted.first?.hit
        }
        if let best = sorted.first, best.diff <= 1.2 {
            let runnerUpOtherArtist = sorted.first(where: { $0.artistKey != best.artistKey })
            if runnerUpOtherArtist == nil || runnerUpOtherArtist!.diff > 2.8 {
                return best.hit
            }
        }
        return nil
    }

    // MARK: - Matching

    nonisolated private static func hasAlternateEditionTag(_ rawTitle: String) -> Bool {
        let lower = rawTitle.lowercased()
        let explicitBlockers = [
            "jp ver", "japanese ver", "kr ver", "korean ver", "cn ver", "chinese ver",
            "english ver", "spanish ver", "french ver", "rough mix", "australian release"
        ]
        return explicitBlockers.contains { lower.contains($0) }
    }

    nonisolated private static func hasExtraEditionParenthetical(_ rawTitle: String) -> Bool {
        let kept = stripVersionNoise(rawTitle, keepVersionTags: true)
        return kept.range(of: #"[\(\[][^\)\]]+[\)\]]"#, options: .regularExpression) != nil
    }

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
        // A remix/live/acoustic/instrumental tag on only one side means a different recording.
        if versionTags(stripVersionNoise(claim.title, keepVersionTags: true)) != versionTags(stripVersionNoise(title, keepVersionTags: true)) {
            return nil
        }
        if !hasAlternateEditionTag(claim.title) && hasAlternateEditionTag(title) {
            return nil
        }

        var artistSim = 1.0
        if !claim.artist.isEmpty {
            let artistContained = containsArtist(artist, claim.artist) ? 0.9 : 0
            let claimContainsCatalogArtist = (normalize(artist).count >= 2 && containsArtist(claim.artist, artist)) ? 0.85 : 0
            artistSim = max(similarity(claim.artist, artist), artistContained, claimContainsCatalogArtist)
            guard artistSim >= 0.6 else { return nil }
        }

        var durationScore = 0.5
        if let localDuration, localDuration > 0, let duration, duration > 0 {
            let diff = abs(localDuration - duration)
            // Never match a normal-length song/clip to a 12+ minute mix/sermon/compilation.
            if localDuration < 480 && duration > 720 && diff > durationTolerance * 3 {
                return nil
            }
            let strongExplicitTitleAndArtist = !claim.artist.isEmpty
                && titleSim >= 0.90
                && artistSim >= 0.85
                && claim.sourceName != "Alternate orientation"
                && claim.sourceName != "Heard lyrics"
            let exact = titleSim >= 0.99 && artistSim >= 0.9
            let trusted = claim.sourceName != "Video title" && claim.sourceName != "File name"
            let tolerance: Double
            if strongExplicitTitleAndArtist {
                tolerance = max(150.0, 600.0)
            } else {
                tolerance = exact ? (trusted ? 150 : durationTolerance * 3) : durationTolerance
            }
            guard diff <= tolerance else { return nil }
            durationScore = max(0.05, 1.0 - diff / (tolerance + 1.0))
        }
        let editionPenalty = (!hasExtraEditionParenthetical(claim.title) && hasExtraEditionParenthetical(title)) ? 0.14 : 0.0
        return titleSim * 0.5 + artistSim * 0.3 + durationScore * 0.2 - editionPenalty
    }

    nonisolated static func normalize(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: " and ")
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").map(String.init).filter { $0 != "the" && $0 != "a" }
    }

    nonisolated private static func containsCJKOrKanaOrHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3040...0x30FF).contains(v)
                || (0x3400...0x9FFF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
                || (0xFF66...0xFF9F).contains(v)
        }
    }

    nonisolated private static func cjkBigramSimilarity(_ a: String, _ b: String) -> Double {
        let fa = Array(a.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        let fb = Array(b.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        guard !fa.isEmpty, !fb.isEmpty else { return 0 }
        if fa == fb { return 1 }
        guard fa.count >= 2, fb.count >= 2 else {
            return Set(fa) == Set(fb) ? 1.0 : 0.0
        }
        var ba = Set<String>()
        for i in 0..<(fa.count - 1) { ba.insert(String([fa[i], fa[i + 1]])) }
        var bb = Set<String>()
        for i in 0..<(fb.count - 1) { bb.insert(String([fb[i], fb[i + 1]])) }
        let inter = Double(ba.intersection(bb).count)
        return (2.0 * inter) / Double(ba.count + bb.count)
    }

    /// Token-set similarity in 0...1 (with character-bigram support for unspaced CJK/Kana/Hangul names).
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let rawTa = normalize(a), rawTb = normalize(b)
        let ta = Set(rawTa), tb = Set(rawTb)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta == tb { return 1 }
        let inter = Double(ta.intersection(tb).count)
        var score = (2 * inter) / Double(ta.count + tb.count)
        if (rawTa.count <= 3 || rawTb.count <= 3), (containsCJKOrKanaOrHangul(a) || containsCJKOrKanaOrHangul(b)) {
            score = max(score, cjkBigramSimilarity(a, b))
        }
        return score
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
