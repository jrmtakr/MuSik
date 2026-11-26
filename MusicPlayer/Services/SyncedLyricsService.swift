import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

struct LyricWordTiming: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let text: String
    let startTime: Double
    let endTime: Double

    init(id: UUID = UUID(), text: String, startTime: Double, endTime: Double) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct SyncedLyricLine: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startTime: Double
    var endTime: Double
    let text: String
    var words: [LyricWordTiming]
    let isInstrumentalBreak: Bool

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        text: String,
        words: [LyricWordTiming] = [],
        isInstrumentalBreak: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
        self.isInstrumentalBreak = isInstrumentalBreak
    }
}

struct ResolvedTrackLyrics: Codable, Sendable {
    let cacheKey: String
    let trackTitle: String
    let artistName: String
    let isTimeSynced: Bool
    let sourceLabel: String
    let attributionText: String?
    var syncedOffsetSeconds: Double
    var tempoScale: Double = 1.0
    var expectedDurationSeconds: Double? = nil
    let lines: [SyncedLyricLine]

    enum CodingKeys: String, CodingKey {
        case cacheKey, trackTitle, artistName, isTimeSynced, sourceLabel, attributionText
        case syncedOffsetSeconds, tempoScale, expectedDurationSeconds, lines
    }

    init(
        cacheKey: String,
        trackTitle: String,
        artistName: String,
        isTimeSynced: Bool,
        sourceLabel: String,
        attributionText: String?,
        syncedOffsetSeconds: Double,
        tempoScale: Double = 1.0,
        expectedDurationSeconds: Double? = nil,
        lines: [SyncedLyricLine]
    ) {
        self.cacheKey = cacheKey
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.isTimeSynced = isTimeSynced
        self.sourceLabel = sourceLabel
        self.attributionText = attributionText
        self.syncedOffsetSeconds = syncedOffsetSeconds
        self.tempoScale = tempoScale
        self.expectedDurationSeconds = expectedDurationSeconds
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cacheKey = try c.decode(String.self, forKey: .cacheKey)
        trackTitle = try c.decode(String.self, forKey: .trackTitle)
        artistName = try c.decode(String.self, forKey: .artistName)
        isTimeSynced = try c.decode(Bool.self, forKey: .isTimeSynced)
        sourceLabel = try c.decode(String.self, forKey: .sourceLabel)
        attributionText = try c.decodeIfPresent(String.self, forKey: .attributionText)
        syncedOffsetSeconds = try c.decode(Double.self, forKey: .syncedOffsetSeconds)
        tempoScale = try c.decodeIfPresent(Double.self, forKey: .tempoScale) ?? 1.0
        expectedDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .expectedDurationSeconds)
        lines = try c.decode([SyncedLyricLine].self, forKey: .lines)
    }
}

struct AIRecognizedTrackInfo: Equatable, Sendable {
    let cacheKey: String
    let relativePath: String
    let songTitle: String
    let artistName: String
    let genre: String?
    let isHighConfidence: Bool
    let isInArtistDatabase: Bool
    let transcriptSnippet: String
    let wasAutoSaved: Bool
}

@MainActor
@Observable
final class SyncedLyricsService {
    static let shared = SyncedLyricsService()

    var currentLyrics: ResolvedTrackLyrics?
    var currentLoadingKey: String?
    var lastError: String?
    var isAIRecognizing: Bool = false
    var aiStatusMessage: String?
    var aiErrorMessage: String?
    var lastRecognizedTrackInfo: AIRecognizedTrackInfo?

    @ObservationIgnored private var memoryCache: [String: ResolvedTrackLyrics] = [:]
    @ObservationIgnored private var activeFetchTask: Task<Void, Never>?
    @ObservationIgnored private var activeAITask: Task<Void, Never>?
    @ObservationIgnored private var activeAITaskKey: String?
    @ObservationIgnored private var autoAttemptedKeys: Set<String> = []

    private static var cacheDirectoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    func cacheKey(for item: MediaItem, artistOverride: String? = nil, titleOverride: String? = nil) -> String {
        let rawTitle = (titleOverride?.isEmpty == false ? titleOverride! : item.displayTitle)
        let rawArtist = (artistOverride?.isEmpty == false ? artistOverride! : (item.artist ?? ""))
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: rawTitle, rawArtistTag: rawArtist)
        let rawBase = "\(cleaned.artistHint ?? rawArtist)|\(cleaned.songOnly)|\(item.fileName)".lowercased()
        let keyBase = rawBase
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let hasNonASCII = rawBase.utf8.contains { $0 > 127 }
        if keyBase.isEmpty || hasNonASCII {
            let hash = Self.stableFNV1aHex(rawBase)
            let prefix = keyBase.isEmpty ? "track" : String(keyBase.prefix(72))
            return "\(prefix)_\(hash)"
        }
        return String(keyBase.prefix(100))
    }

    private static func stableFNV1aHex(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16, uppercase: false)
    }

    func loadLyricsIfNeeded(for item: MediaItem, forceReload: Bool = false, customTitle: String? = nil, customArtist: String? = nil) {
        let key = cacheKey(for: item, artistOverride: customArtist, titleOverride: customTitle)

        if !forceReload {
            if currentLyrics?.cacheKey == key { return }
            aiStatusMessage = nil
            aiErrorMessage = nil
            lastRecognizedTrackInfo = nil
            if let inMem = memoryCache[key] {
                currentLyrics = inMem
                lastError = nil
                return
            }
            if let disk = loadFromDisk(key: key) {
                memoryCache[key] = disk
                currentLyrics = disk
                lastError = nil
                return
            }
        }

        activeFetchTask?.cancel()
        if activeAITaskKey != key {
            activeAITask?.cancel()
            activeAITaskKey = nil
            isAIRecognizing = false
            aiStatusMessage = nil
            aiErrorMessage = nil
            lastRecognizedTrackInfo = nil
        }
        currentLoadingKey = key
        lastError = nil
        if forceReload || currentLyrics?.cacheKey != key {
            currentLyrics = nil
        }

        activeFetchTask = Task {
            if !forceReload,
               customTitle == nil,
               customArtist == nil,
               !item.relativePath.hasPrefix("__remote__/"),
               WholeSongAIService.shared.shouldDeferOnlineLyricsForFirstListen(item) {
                let offline = await loadOfflineEmbeddedOrSidecarLyrics(
                    item: item,
                    cacheKey: key,
                    title: item.displayTitle,
                    artist: item.artist ?? ""
                )
                guard !Task.isCancelled else { return }
                currentLoadingKey = nil
                if let offline {
                    memoryCache[key] = offline
                    saveToDisk(offline)
                    currentLyrics = offline
                    lastError = nil
                } else {
                    WholeSongAIService.shared.triggerIfFirstTimeUnknown(item: item)
                    lastError = "No lyrics for first time listen"
                }
                return
            }

            let resolved = await fetchBestLyrics(
                item: item,
                cacheKey: key,
                customTitle: customTitle,
                customArtist: customArtist
            )
            guard !Task.isCancelled else { return }
            if var resolved {
                // Automatically line synced or plain lyrics up into real-time word-timed lyrics against local audio.
                if !item.relativePath.hasPrefix("__remote__/") && !item.isHLS {
                    resolved = await SongAudioListener.autoAlign(lyrics: resolved, heard: nil, fileURL: item.fileURL)
                    guard !Task.isCancelled else { return }
                }
                currentLoadingKey = nil
                memoryCache[key] = resolved
                saveToDisk(resolved)
                currentLyrics = resolved
                lastError = nil
            } else {
                currentLoadingKey = nil
                lastError = "No lyrics for first time listen"
                if customTitle == nil && customArtist == nil && !item.relativePath.hasPrefix("__remote__/") {
                    WholeSongAIService.shared.triggerIfFirstTimeUnknown(item: item)
                }
            }
        }
    }

    func installLyrics(_ lyrics: ResolvedTrackLyrics, for item: MediaItem) {
        let key = cacheKey(for: item)
        let normalized = ResolvedTrackLyrics(
            cacheKey: key,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: lyrics.isTimeSynced,
            sourceLabel: lyrics.sourceLabel,
            attributionText: lyrics.attributionText,
            syncedOffsetSeconds: lyrics.syncedOffsetSeconds,
            lines: lyrics.lines
        )
        memoryCache[key] = normalized
        saveToDisk(normalized)
        if MediaManager.shared.currentItem?.relativePath == item.relativePath {
            currentLoadingKey = nil
            currentLyrics = normalized
            lastError = nil
        }
    }

    func fetchOfficialLyricsCandidate(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?
    ) async -> ResolvedTrackLyrics? {
        if let lrclib = await fetchFromLRCLIB(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            rawTitle: song,
            duration: duration
        ) {
            return lrclib
        }
        return await fetchFromGenius(cacheKey: cacheKey, song: song, artist: artist)
    }

    func adjustTimingOffset(by delta: Double) {
        guard var lyrics = currentLyrics, lyrics.isTimeSynced else { return }
        lyrics.syncedOffsetSeconds = (delta == 0) ? 0 : (lyrics.syncedOffsetSeconds + delta)
        currentLyrics = lyrics
        memoryCache[lyrics.cacheKey] = lyrics
        saveToDisk(lyrics)
    }

    func resetTimingOffset() {
        guard var lyrics = currentLyrics, lyrics.isTimeSynced else { return }
        lyrics.syncedOffsetSeconds = 0
        lyrics.tempoScale = 1.0
        currentLyrics = lyrics
        memoryCache[lyrics.cacheKey] = lyrics
        saveToDisk(lyrics)
        aiStatusMessage = "Timing reset to default"
    }

    func toggleDurationTempoFit(for item: MediaItem) {
        guard var lyrics = currentLyrics, lyrics.isTimeSynced,
              let trackDur = item.durationSeconds, trackDur > 15,
              let lrcDur = lyrics.expectedDurationSeconds, lrcDur > 15 else {
            return
        }
        if abs(lyrics.tempoScale - 1.0) > 0.02 {
            lyrics.tempoScale = 1.0
            lyrics.syncedOffsetSeconds = 0
            aiStatusMessage = "Reset tempo speed fit (1.0x)"
        } else {
            let ratio = lrcDur / trackDur
            let clampedRatio = min(1.45, max(0.65, ratio))
            lyrics.tempoScale = clampedRatio
            aiStatusMessage = String(format: "Matched speed (%.2fx)", clampedRatio)
        }
        currentLyrics = lyrics
        memoryCache[lyrics.cacheKey] = lyrics
        saveToDisk(lyrics)
    }

    func recognizeAndAlignWithAI(
        for item: MediaItem,
        playbackTime: Double,
        equalizerPlayer: EqualizerAudioPlayer,
        isEQPlaying: Bool,
        playbackRate: Float,
        forceReidentify: Bool = false
    ) {
        guard !isAIRecognizing else { return }
        let key = cacheKey(for: item)
        activeAITask?.cancel()
        activeAITaskKey = key
        isAIRecognizing = true
        aiErrorMessage = nil
        aiStatusMessage = "AI listening across full song..."

        let existingLyrics = (currentLyrics?.cacheKey == key) ? currentLyrics : nil

        activeAITask = Task {
            let outcome = await LiveAudioLyricsAI.recognizeAndAlign(
                item: item,
                cacheKey: key,
                playbackTime: playbackTime,
                currentLyrics: existingLyrics,
                equalizerPlayer: equalizerPlayer,
                isEQPlaying: isEQPlaying,
                playbackRate: playbackRate,
                forceReidentify: forceReidentify
            ) { [weak self] stepText in
                self?.aiStatusMessage = stepText
            }
            guard !Task.isCancelled else {
                if self.activeAITaskKey == key {
                    self.activeAITaskKey = nil
                }
                return
            }
            isAIRecognizing = false
            activeAITaskKey = nil
            aiStatusMessage = outcome.statusMessage
            aiErrorMessage = outcome.errorMessage

            if let updated = outcome.alignedLyrics {
                storeAlignedLyrics(updated, for: item)
                if let saved = memoryCache[key] {
                    currentLyrics = saved
                }
                lastError = nil
            }

            if let rawTitle = outcome.identifiedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawTitle.isEmpty,
               let rawArtist = outcome.identifiedArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawArtist.isEmpty {
                let extracted = ArtistDatabase.extractArtists(
                    rawArtistTag: rawArtist,
                    rawTitle: rawTitle,
                    isArtistVerified: true
                )
                let canonicalArtist = ArtistDatabase.canonicalizeSingle(
                    extracted.primaryArtist.isEmpty ? rawArtist : extracted.primaryArtist
                )
                let cleanTitle = ArtistDatabase.cleanSongTitleForSearch(
                    rawTitle: rawTitle,
                    rawArtistTag: canonicalArtist
                ).songOnly
                let finalTitle = cleanTitle.isEmpty ? rawTitle : cleanTitle
                let inCatalogBefore = ArtistDatabase.lookup(canonicalArtist) != nil
                let resolvedGenre = outcome.identifiedGenre
                    ?? ArtistDatabase.genre(forArtist: canonicalArtist)
                    ?? extracted.genre

                if outcome.isHighConfidence && !inCatalogBefore && !canonicalArtist.isEmpty {
                    ArtistDatabase.registerDynamicArtists([
                        ArtistCatalogEntry(
                            canonicalName: canonicalArtist,
                            genre: resolvedGenre ?? "Pop",
                            aliases: canonicalArtist != rawArtist ? [rawArtist] : [],
                            requiresSeparatedContext: false
                        )
                    ])
                }

                var autoSaved = false
                if outcome.isHighConfidence && !MediaManager.shared.isArtistVerified(for: item) {
                    MediaManager.shared.confirmVerifiedArtist(
                        for: item,
                        artistName: canonicalArtist,
                        updatedTitle: finalTitle,
                        albumName: outcome.identifiedAlbum,
                        genre: resolvedGenre
                    )
                    autoSaved = true
                }

                lastRecognizedTrackInfo = AIRecognizedTrackInfo(
                    cacheKey: key,
                    relativePath: item.relativePath,
                    songTitle: finalTitle,
                    artistName: canonicalArtist,
                    genre: resolvedGenre,
                    isHighConfidence: outcome.isHighConfidence,
                    isInArtistDatabase: ArtistDatabase.lookup(canonicalArtist) != nil,
                    transcriptSnippet: outcome.transcriptSnippet,
                    wasAutoSaved: autoSaved
                )
            }
        }
    }

    func applyRecognizedMetadata(_ info: AIRecognizedTrackInfo, to item: MediaItem) {
        let canonical = ArtistDatabase.canonicalizeSingle(info.artistName)
        if ArtistDatabase.lookup(canonical) == nil && !canonical.isEmpty {
            ArtistDatabase.registerDynamicArtists([
                ArtistCatalogEntry(
                    canonicalName: canonical,
                    genre: info.genre ?? "Pop",
                    aliases: [],
                    requiresSeparatedContext: false
                )
            ])
        }
        MediaManager.shared.confirmVerifiedArtist(
            for: item,
            artistName: canonical,
            updatedTitle: info.songTitle,
            genre: info.genre
        )
        lastRecognizedTrackInfo = AIRecognizedTrackInfo(
            cacheKey: info.cacheKey,
            relativePath: info.relativePath,
            songTitle: info.songTitle,
            artistName: canonical,
            genre: info.genre,
            isHighConfidence: info.isHighConfidence,
            isInArtistDatabase: true,
            transcriptSnippet: info.transcriptSnippet,
            wasAutoSaved: true
        )
        aiStatusMessage = "Saved to Library & Artist Database: \(canonical) — \(info.songTitle)"
    }

    func autoRecognizeIfAuthorizedAndNeeded(
        for item: MediaItem,
        playbackTime: Double,
        equalizerPlayer: EqualizerAudioPlayer,
        isEQPlaying: Bool,
        playbackRate: Float
    ) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              !isAIRecognizing,
              currentLoadingKey == nil else {
            return
        }
        let key = cacheKey(for: item)
        guard !autoAttemptedKeys.contains(key) else { return }

        let shouldAutoRun: Bool = {
            guard let cur = currentLyrics, cur.cacheKey == key else {
                return true // No lyrics found for current track
            }
            if !cur.isTimeSynced { return true }
            if abs(cur.syncedOffsetSeconds) > 0.01 { return false } // Already synced
            if let lrcDur = cur.expectedDurationSeconds,
               let fileDur = item.durationSeconds,
               abs(lrcDur - fileDur) > 15.0 {
                return true // Duration differs strongly (intro skit / wrong edit / remux)
            }
            return false
        }()

        guard shouldAutoRun else { return }
        autoAttemptedKeys.insert(key)
        recognizeAndAlignWithAI(
            for: item,
            playbackTime: playbackTime,
            equalizerPlayer: equalizerPlayer,
            isEQPlaying: isEQPlaying,
            playbackRate: playbackRate,
            forceReidentify: false
        )
    }

    /// Exact lyrics for a known song, used by import-time song ID to confirm the name by listening.
    /// Doesn't touch what's on screen.
    func fetchLyricsForVerification(title: String, artist: String, duration: Double?) async -> ResolvedTrackLyrics? {
        await fetchFromLRCLIB(cacheKey: "verify", song: title, artist: artist, rawTitle: title, duration: duration)
    }

    /// Checks all candidate lyric sources during upload/import against the actual audio (heard words +
    /// acoustic vocal energy), selects the verified matching lyrics, converts even plain lyrics into
    /// real-time synced line & word timings, and saves them offline ready before playback starts.
    @discardableResult
    func fetchAndAlignDuringImport(
        item: MediaItem,
        title: String,
        artist: String,
        duration: Double?,
        heard: [HeardWord]?
    ) async -> Bool {
        let key = cacheKey(for: item, artistOverride: artist, titleOverride: title)
        let split = splitArtistAndSong(rawTitle: title, rawArtist: artist)

        var candidates: [ResolvedTrackLyrics] = []
        if let lrclib = await fetchFromLRCLIB(
            cacheKey: key,
            song: split.song,
            artist: split.artist,
            rawTitle: title,
            duration: duration
        ) {
            candidates.append(lrclib)
        }
        if let genius = await fetchFromGenius(
            cacheKey: key,
            song: split.song,
            artist: split.artist
        ) {
            candidates.append(genius)
        }
        if let ytCaptions = await fetchFromYouTubeCreatorSubtitles(
            item: item,
            cacheKey: key,
            song: split.song,
            artist: split.artist
        ) {
            candidates.append(ytCaptions)
        }

        // Verify candidate lyrics directly against what the AI heard in the actual audio file.
        var bestCandidate: ResolvedTrackLyrics?
        var bestScore = -Double.infinity
        for cand in candidates {
            var score = cand.isTimeSynced ? 0.25 : 0.0
            if let heard, !heard.isEmpty {
                switch SongAudioListener.verdict(heard: heard, lyrics: cand) {
                case .confirmed(let ratio):
                    score += 2.0 + ratio
                case .inconclusive:
                    score += 0.1
                case .contradicted:
                    score -= 2.0
                }
            }
            if score > bestScore {
                bestScore = score
                bestCandidate = cand
            }
        }

        // Don't lock in clearly wrong lyrics if the audio contradicted the candidate.
        guard var selected = bestCandidate, bestScore > -0.5 else { return false }
        if !item.isHLS {
            selected = await SongAudioListener.autoAlign(lyrics: selected, heard: heard, fileURL: item.fileURL)
        }
        storeAlignedLyrics(selected, for: item)
        return true
    }

    /// Saves lyrics that were already re-timed against this exact file, so playback uses them as-is
    /// (and the play-time auto-sync doesn't shift them a second time).
    func storeAlignedLyrics(_ lyrics: ResolvedTrackLyrics, for item: MediaItem) {
        let key = cacheKey(for: item)
        let stored = ResolvedTrackLyrics(
            cacheKey: key,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: lyrics.isTimeSynced,
            sourceLabel: lyrics.sourceLabel,
            attributionText: lyrics.attributionText,
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: item.durationSeconds,
            lines: lyrics.lines
        )
        memoryCache[key] = stored
        saveToDisk(stored)
        autoAttemptedKeys.insert(key)
        if currentLyrics?.cacheKey == key {
            currentLyrics = stored
        }
    }

    @discardableResult
    func saveCustomLyrics(
        for item: MediaItem,
        text: String,
        titleOverride: String? = nil,
        artistOverride: String? = nil
    ) -> Bool {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return false }

        let parsed = Self.parseLRCOrPlain(text: cleanedText, duration: item.durationSeconds)
        guard !parsed.lines.isEmpty else { return false }

        let key = cacheKey(for: item, artistOverride: artistOverride, titleOverride: titleOverride)
        let title = (titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? titleOverride!.trimmingCharacters(in: .whitespacesAndNewlines)
            : item.displayTitle
        let artist = (artistOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? artistOverride!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (item.artist ?? "")

        let custom = ResolvedTrackLyrics(
            cacheKey: key,
            trackTitle: title,
            artistName: artist,
            isTimeSynced: parsed.isSynced,
            sourceLabel: parsed.isSynced ? "Custom .LRC Synced" : "Custom Lyrics",
            attributionText: "Saved manually by you",
            syncedOffsetSeconds: 0,
            lines: parsed.lines
        )
        memoryCache[key] = custom
        saveToDisk(custom)
        currentLyrics = custom
        lastError = nil
        return true
    }

    // MARK: - Multi-Source Fetching

    private func fetchBestLyrics(
        item: MediaItem,
        cacheKey: String,
        customTitle: String?,
        customArtist: String?
    ) async -> ResolvedTrackLyrics? {
        let rawTitle = (customTitle?.isEmpty == false ? customTitle! : item.displayTitle)
        let rawArtist = (customArtist?.isEmpty == false ? customArtist! : (item.artist ?? ""))

        let split = splitArtistAndSong(rawTitle: rawTitle, rawArtist: rawArtist)
        let song = split.song
        let artist = split.artist
        let duration = item.durationSeconds

        // 1. Offline: Sidecar .lrc or Embedded metadata lyrics inside file
        if !item.relativePath.hasPrefix("__remote__/") {
            if let offline = await loadOfflineEmbeddedOrSidecarLyrics(item: item, cacheKey: cacheKey, title: song, artist: artist) {
                return offline
            }
        }

        // 2. Online: LRCLIB Time-Synced & Plain LRC
        if let lrclib = await fetchFromLRCLIB(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            rawTitle: rawTitle,
            duration: duration
        ) {
            return lrclib
        }

        // 3. Fallback: Genius Native HTML Lyrics Extraction
        if let genius = await fetchFromGenius(
            cacheKey: cacheKey,
            song: song,
            artist: artist
        ) {
            return genius
        }

        // 4. Last-Resort Fallback: Creator-Uploaded Timed Captions from Source YouTube Video (non-ASR)
        if let ytCaptions = await fetchFromYouTubeCreatorSubtitles(
            item: item,
            cacheKey: cacheKey,
            song: song,
            artist: artist
        ) {
            return ytCaptions
        }

        return nil
    }

    private func loadOfflineEmbeddedOrSidecarLyrics(
        item: MediaItem,
        cacheKey: String,
        title: String,
        artist: String
    ) async -> ResolvedTrackLyrics? {
        // Check sidecar .lrc file
        let lrcURL = item.fileURL.deletingPathExtension().appendingPathExtension("lrc")
        if let lrcText = try? String(contentsOf: lrcURL, encoding: .utf8),
           !lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: lrcText, duration: item.durationSeconds)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: title,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Local .LRC Synced" : "Local .LRC",
                    attributionText: "Loaded from offline .lrc file",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }

        // Check AVURLAsset embedded lyrics
        let asset = AVURLAsset(url: item.fileURL)
        if let embedded = try? await asset.load(.lyrics),
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: embedded, duration: item.durationSeconds)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: title,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Embedded Synced" : "Embedded Lyrics",
                    attributionText: "Embedded in audio file",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }
        return nil
    }

    // MARK: - LRCLIB Synced Lyrics

    private struct LRCLIBCandidate {
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
        let score: Int
    }

    private func fetchFromLRCLIB(
        cacheKey: String,
        song: String,
        artist: String,
        rawTitle: String,
        duration: Double?
    ) async -> ResolvedTrackLyrics? {
        let querySong = Self.normalizeSmartPunctuation(song)
        let queryArtist = Self.normalizeSmartPunctuation(artist)
        let coreSong = Self.extractCoreSongTitle(querySong)

        // Fast exact match endpoint first
        if !queryArtist.isEmpty, let dur = duration, dur > 5 {
            var comps = URLComponents(string: "https://lrclib.net/api/get")
            comps?.queryItems = [
                URLQueryItem(name: "track_name", value: querySong),
                URLQueryItem(name: "artist_name", value: queryArtist),
                URLQueryItem(name: "duration", value: String(Int(round(dur))))
            ]
            if let url = comps?.url,
               let row = await fetchSingleLRCLIBObject(url: url),
               let built = buildLyricsFromLRCLIBRow(row, cacheKey: cacheKey, duration: duration) {
                return built
            }
        }

        // Primary search queries
        var allCandidates: [LRCLIBCandidate] = []
        var primaryQueries: [URL] = []

        if !queryArtist.isEmpty {
            var c1 = URLComponents(string: "https://lrclib.net/api/search")
            c1?.queryItems = [
                URLQueryItem(name: "track_name", value: querySong),
                URLQueryItem(name: "artist_name", value: queryArtist)
            ]
            if let u = c1?.url { primaryQueries.append(u) }
        }

        let combined = [queryArtist, querySong].filter { !$0.isEmpty }.joined(separator: " ")
        if !combined.isEmpty {
            var c2 = URLComponents(string: "https://lrclib.net/api/search")
            c2?.queryItems = [URLQueryItem(name: "q", value: combined)]
            if let u = c2?.url { primaryQueries.append(u) }
        }

        let cleanedRaw = Self.normalizeSmartPunctuation(Self.stripNoisyTitleTokens(rawTitle))
        if !cleanedRaw.isEmpty && cleanedRaw.lowercased() != combined.lowercased() {
            var c3 = URLComponents(string: "https://lrclib.net/api/search")
            c3?.queryItems = [URLQueryItem(name: "q", value: cleanedRaw)]
            if let u = c3?.url { primaryQueries.append(u) }
        }

        for url in primaryQueries {
            let rows = await fetchLRCLIBSearchArray(url: url)
            for row in rows {
                let candidate = scoreLRCLIBRow(
                    row,
                    targetSong: querySong,
                    coreSong: coreSong,
                    targetArtist: queryArtist,
                    targetDuration: duration,
                    strictArtistlessGuard: false
                )
                if candidate.score > 10 {
                    allCandidates.append(candidate)
                }
            }
            if allCandidates.contains(where: { !($0.syncedLyrics?.isEmpty ?? true) && $0.score >= 70 }) {
                break
            }
        }

        // Obscure-track rescue ladder (only runs when primary queries did not yield a strong synced match)
        let hasStrongMatch = allCandidates.contains(where: { !($0.syncedLyrics?.isEmpty ?? true) && $0.score >= 70 })
        if !hasStrongMatch {
            var fallbackQueries: [(url: URL, artistless: Bool)] = []

            if !coreSong.isEmpty && coreSong.lowercased() != querySong.lowercased() {
                var cCore = URLComponents(string: "https://lrclib.net/api/search")
                if !queryArtist.isEmpty {
                    cCore?.queryItems = [
                        URLQueryItem(name: "track_name", value: coreSong),
                        URLQueryItem(name: "artist_name", value: queryArtist)
                    ]
                } else {
                    cCore?.queryItems = [URLQueryItem(name: "q", value: coreSong)]
                }
                if let u = cCore?.url { fallbackQueries.append((u, queryArtist.isEmpty)) }
            }

            // Title-only fallback in case artist tag was a re-upload channel or mis-tagged
            if !queryArtist.isEmpty && !allCandidates.contains(where: { $0.score >= 45 }) {
                let lookupTitle = coreSong.isEmpty ? querySong : coreSong
                var cTitleOnly = URLComponents(string: "https://lrclib.net/api/search")
                cTitleOnly?.queryItems = [URLQueryItem(name: "track_name", value: lookupTitle)]
                if let u = cTitleOnly?.url { fallbackQueries.append((u, true)) }
            }

            for entry in fallbackQueries {
                let rows = await fetchLRCLIBSearchArray(url: entry.url)
                for row in rows {
                    let candidate = scoreLRCLIBRow(
                        row,
                        targetSong: querySong,
                        coreSong: coreSong,
                        targetArtist: queryArtist,
                        targetDuration: duration,
                        strictArtistlessGuard: entry.artistless
                    )
                    if candidate.score > 15 {
                        allCandidates.append(candidate)
                    }
                }
                if allCandidates.contains(where: { !($0.syncedLyrics?.isEmpty ?? true) && $0.score >= 70 }) {
                    break
                }
            }
        }

        guard let best = allCandidates.max(by: { $0.score < $1.score }) else { return nil }

        if let synced = best.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: synced, duration: duration ?? best.duration)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: best.trackName,
                    artistName: best.artistName,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Synced Lyrics" : "Lyrics",
                    attributionText: "Time-synced via LRCLIB",
                    syncedOffsetSeconds: 0,
                    tempoScale: 1.0,
                    expectedDurationSeconds: best.duration,
                    lines: parsed.lines
                )
            }
        }

        if let plain = best.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: plain, duration: duration ?? best.duration)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: best.trackName,
                    artistName: best.artistName,
                    isTimeSynced: false,
                    sourceLabel: "Plain Lyrics",
                    attributionText: "Lyrics via LRCLIB",
                    syncedOffsetSeconds: 0,
                    tempoScale: 1.0,
                    expectedDurationSeconds: best.duration,
                    lines: parsed.lines
                )
            }
        }

        return nil
    }

    private func fetchSingleLRCLIBObject(url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("MuseJRM/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func fetchLRCLIBSearchArray(url: URL) async -> [[String: Any]] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MuseJRM/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Array(rows.prefix(15))
    }

    private func buildLyricsFromLRCLIBRow(_ row: [String: Any], cacheKey: String, duration: Double?) -> ResolvedTrackLyrics? {
        let track = (row["trackName"] as? String) ?? ""
        let artist = (row["artistName"] as? String) ?? ""
        let dur = row["duration"] as? Double
        if let synced = row["syncedLyrics"] as? String, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: synced, duration: duration ?? dur)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: track,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Synced Lyrics" : "Lyrics",
                    attributionText: "Time-synced via LRCLIB",
                    syncedOffsetSeconds: 0,
                    tempoScale: 1.0,
                    expectedDurationSeconds: dur,
                    lines: parsed.lines
                )
            }
        }
        if let plain = row["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: plain, duration: duration ?? dur)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: track,
                    artistName: artist,
                    isTimeSynced: false,
                    sourceLabel: "Plain Lyrics",
                    attributionText: "Lyrics via LRCLIB",
                    syncedOffsetSeconds: 0,
                    tempoScale: 1.0,
                    expectedDurationSeconds: dur,
                    lines: parsed.lines
                )
            }
        }
        return nil
    }

    private func scoreLRCLIBRow(
        _ row: [String: Any],
        targetSong: String,
        coreSong: String,
        targetArtist: String,
        targetDuration: Double?,
        strictArtistlessGuard: Bool
    ) -> LRCLIBCandidate {
        let trackName = (row["trackName"] as? String) ?? ""
        let artistName = (row["artistName"] as? String) ?? ""
        let synced = row["syncedLyrics"] as? String
        let plain = row["plainLyrics"] as? String
        let dur = row["duration"] as? Double
        let isInstrumental = (row["instrumental"] as? Bool) == true

        var score = 0
        if let synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 65
        } else if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 20
        } else if isInstrumental {
            return LRCLIBCandidate(trackName: trackName, artistName: artistName, albumName: nil, duration: dur, syncedLyrics: nil, plainLyrics: nil, score: -100)
        }

        let normTargetSong = Self.normalizeComparable(targetSong)
        let normCoreSong = Self.normalizeComparable(coreSong)
        let normHitSong = Self.normalizeComparable(trackName)

        let exactTitleMatch = !normHitSong.isEmpty && (
            normHitSong == normTargetSong || (!normCoreSong.isEmpty && normHitSong == normCoreSong)
        )
        if !normHitSong.isEmpty {
            if normHitSong == normTargetSong {
                score += 45
            } else if !normCoreSong.isEmpty && normHitSong == normCoreSong {
                score += 36
            } else if !normTargetSong.isEmpty && (normHitSong.contains(normTargetSong) || normTargetSong.contains(normHitSong)) {
                score += 25
            } else if !normCoreSong.isEmpty && (normHitSong.contains(normCoreSong) || normCoreSong.contains(normHitSong)) {
                score += 18
            }
        }

        let normTargetArtist = Self.normalizeComparable(targetArtist)
        let normHitArtist = Self.normalizeComparable(artistName)
        var artistMatched = false
        if !normTargetArtist.isEmpty && !normHitArtist.isEmpty {
            if normHitArtist == normTargetArtist {
                score += 40
                artistMatched = true
            } else if normHitArtist.contains(normTargetArtist) || normTargetArtist.contains(normHitArtist) {
                score += 22
                artistMatched = true
            } else {
                score -= 15
            }
        }

        var durationClose = false
        if let targetDuration, let dur, targetDuration > 5 {
            let diff = abs(targetDuration - dur)
            if diff <= 2.5 {
                score += 50
                durationClose = true
            } else if diff <= 7.0 {
                score += 25
                durationClose = true
            } else if diff > 15.0 {
                score -= diff > 30.0 ? 50 : 30
            }
        }

        // Penalize alternate edits/versions (remix, slowed, sped up, live, cover, karaoke) when the track isn't one.
        let versionKeywords = [
            "slowed", "sped up", "speed up", "nightcore", "remix",
            "acoustic", "live", "instrumental", "karaoke", "8d", "cover"
        ]
        let hitCombined = (trackName + " " + ((row["albumName"] as? String) ?? "")).lowercased()
        let targetCombined = (targetSong + " " + coreSong).lowercased()
        for kw in versionKeywords {
            if hitCombined.contains(kw) && !targetCombined.contains(kw) {
                score -= 50
                break
            }
        }

        // Prevent false positives when retrying title-only or mismatched uploader channel tags
        if strictArtistlessGuard && !artistMatched {
            let wordCount = normTargetSong.split(separator: " ").count
            guard exactTitleMatch, (durationClose || wordCount >= 2) else {
                return LRCLIBCandidate(trackName: trackName, artistName: artistName, albumName: nil, duration: dur, syncedLyrics: nil, plainLyrics: nil, score: -100)
            }
        }

        return LRCLIBCandidate(
            trackName: trackName,
            artistName: artistName,
            albumName: row["albumName"] as? String,
            duration: dur,
            syncedLyrics: synced,
            plainLyrics: plain,
            score: score
        )
    }

    // MARK: - Genius Clean Plain Lyrics Fallback

    private func fetchFromGenius(
        cacheKey: String,
        song: String,
        artist: String
    ) async -> ResolvedTrackLyrics? {
        let querySong = Self.normalizeSmartPunctuation(song)
        let queryArtist = Self.normalizeSmartPunctuation(artist)
        let coreSong = Self.extractCoreSongTitle(querySong)

        let combined = [queryArtist, querySong].filter { !$0.isEmpty }.joined(separator: " ")
        if let primaryHit = await findBestGeniusHit(query: combined, targetSong: querySong, coreSong: coreSong, targetArtist: queryArtist),
           primaryHit.score >= 35 {
            if let fetched = await loadGeniusPage(hit: primaryHit, cacheKey: cacheKey) {
                return fetched
            }
        }

        // Obscure / YouTube-channel rescue query: search Genius by song title cleanly if combined query missed
        let titleQuery = coreSong.isEmpty ? querySong : coreSong
        if !queryArtist.isEmpty, !titleQuery.isEmpty, titleQuery.lowercased() != combined.lowercased(),
           let rescueHit = await findBestGeniusHit(query: titleQuery, targetSong: querySong, coreSong: coreSong, targetArtist: queryArtist),
           rescueHit.score >= 42 {
            if let fetched = await loadGeniusPage(hit: rescueHit, cacheKey: cacheKey) {
                return fetched
            }
        }

        return nil
    }

    private func findBestGeniusHit(
        query: String,
        targetSong: String,
        coreSong: String,
        targetArtist: String
    ) async -> (url: URL, title: String, artist: String, score: Int)? {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://genius.com/api/search/multi?q=\(encoded)&per_page=5") else {
            return nil
        }

        var req = URLRequest(url: searchURL)
        req.timeoutInterval = 10
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = (json["response"] as? [String: Any])?["sections"] as? [[String: Any]] else {
            return nil
        }

        var bestHit: (url: URL, title: String, artist: String, score: Int)?
        let normSong = Self.normalizeComparable(targetSong)
        let normCore = Self.normalizeComparable(coreSong)
        let normArtist = Self.normalizeComparable(targetArtist)

        for section in sections {
            let sType = (section["type"] as? String) ?? ""
            guard sType == "song" || sType == "top_hit",
                  let hits = section["hits"] as? [[String: Any]] else { continue }
            for hit in hits {
                guard (hit["type"] as? String) == "song",
                      let result = hit["result"] as? [String: Any],
                      let urlStr = result["url"] as? String,
                      let url = URL(string: urlStr) else { continue }
                let hTitle = (result["title"] as? String) ?? ""
                let hArtist = (result["artist_names"] as? String) ?? ""
                let normHitSong = Self.normalizeComparable(hTitle)
                let normHitArtist = Self.normalizeComparable(hArtist)

                var s = 0
                if !normHitSong.isEmpty {
                    if normHitSong == normSong { s += 50 }
                    else if !normCore.isEmpty && normHitSong == normCore { s += 42 }
                    else if !normSong.isEmpty && (normHitSong.contains(normSong) || normSong.contains(normHitSong)) { s += 25 }
                    else if !normCore.isEmpty && (normHitSong.contains(normCore) || normCore.contains(normHitSong)) { s += 18 }
                }
                if !normArtist.isEmpty && !normHitArtist.isEmpty {
                    if normHitArtist == normArtist { s += 40 }
                    else if normHitArtist.contains(normArtist) || normArtist.contains(normHitArtist) { s += 28 }
                }
                if bestHit == nil || s > bestHit!.score {
                    bestHit = (url, hTitle, hArtist, s)
                }
            }
        }

        return bestHit
    }

    private func loadGeniusPage(
        hit: (url: URL, title: String, artist: String, score: Int),
        cacheKey: String
    ) async -> ResolvedTrackLyrics? {
        var pageReq = URLRequest(url: hit.url)
        pageReq.timeoutInterval = 12
        pageReq.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (htmlData, pageResp) = try? await URLSession.shared.data(for: pageReq),
              let pageHTTP = pageResp as? HTTPURLResponse,
              (200...299).contains(pageHTTP.statusCode),
              let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }

        guard let plain = Self.extractGeniusLyricsText(fromHTML: html),
              !plain.isEmpty else {
            return nil
        }

        let parsed = Self.parseLRCOrPlain(text: plain, duration: nil)
        guard !parsed.lines.isEmpty else { return nil }

        return ResolvedTrackLyrics(
            cacheKey: cacheKey,
            trackTitle: hit.title,
            artistName: hit.artist,
            isTimeSynced: false,
            sourceLabel: "Plain Lyrics",
            attributionText: "Lyrics via Genius",
            syncedOffsetSeconds: 0,
            lines: parsed.lines
        )
    }

    // MARK: - YouTube Creator-Uploaded Timed Subtitles Fallback (Non-ASR)

    func fetchFromYouTubeCreatorSubtitles(
        item: MediaItem,
        cacheKey: String,
        song: String,
        artist: String
    ) async -> ResolvedTrackLyrics? {
        guard let videoID = MediaManager.shared.sourceVideoID(for: item),
              !videoID.isEmpty else {
            return nil
        }

        let captionTracks = await YouTubeStreamResolver.fetchCreatorCaptionTracks(videoID: videoID)
        guard !captionTracks.isEmpty else { return nil }

        let preferredLang = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
        let selectedTrack = captionTracks.first(where: { $0.languageCode.lowercased().hasPrefix(preferredLang) })
            ?? captionTracks.first(where: { $0.languageCode.lowercased().hasPrefix("en") })
            ?? captionTracks[0]

        guard var comps = URLComponents(url: selectedTrack.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name.lowercased() == "fmt" }
        items.append(URLQueryItem(name: "fmt", value: "json3"))
        comps.queryItems = items
        guard let jsonURL = comps.url else { return nil }

        var req = URLRequest(url: jsonURL)
        req.timeoutInterval = 10
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = dict["events"] as? [[String: Any]] else {
            return nil
        }

        var timedLines: [(start: Double, end: Double, text: String)] = []
        for evt in events {
            guard let tStartMs = (evt["tStartMs"] as? NSNumber)?.doubleValue,
                  let segs = evt["segs"] as? [[String: Any]] else { continue }
            let joined = segs.compactMap { $0["utf8"] as? String }.joined()
            let clean = joined
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }

            let lower = clean.lowercased()
            if lower == "[music]" || lower == "(music)" || lower == "[applause]" || lower == "♪" {
                continue
            }

            let startSec = max(0, tStartMs / 1000.0)
            let durMs = (evt["dDurationMs"] as? NSNumber)?.doubleValue ?? 3200.0
            let endSec = startSec + max(0.8, durMs / 1000.0)
            timedLines.append((startSec, endSec, Self.decodeHTMLEntities(clean)))
        }

        // Require at least a handful of lines so single title-card annotations aren't treated as full lyrics
        guard timedLines.count >= 4 else { return nil }

        var built: [SyncedLyricLine] = []
        if let first = timedLines.first, first.start > 5.5 {
            built.append(SyncedLyricLine(startTime: 0.4, endTime: first.start - 0.3, text: "", isInstrumentalBreak: true))
        }
        for i in 0..<timedLines.count {
            let cur = timedLines[i]
            let nextStart = (i + 1 < timedLines.count) ? timedLines[i + 1].start : cur.end
            let boundedEnd = min(nextStart, max(cur.start + 0.6, cur.end))
            let words = Self.synthesizeProportionalWordTimings(text: cur.text, lineStart: cur.start, lineEnd: boundedEnd)
            built.append(SyncedLyricLine(startTime: cur.start, endTime: boundedEnd, text: cur.text, words: words))
        }

        return ResolvedTrackLyrics(
            cacheKey: cacheKey,
            trackTitle: song,
            artistName: artist,
            isTimeSynced: true,
            sourceLabel: "YouTube Subtitles Synced",
            attributionText: "Timed captions (\(selectedTrack.name))",
            syncedOffsetSeconds: 0,
            lines: built
        )
    }

    // MARK: - LRC + Word Timing Parser

    nonisolated static func parseLRCOrPlain(text: String, duration: Double?) -> (isSynced: Bool, lines: [SyncedLyricLine]) {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalizedText.components(separatedBy: "\n")

        let timestampRegex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#)
        let enhancedWordRegex = try? NSRegularExpression(pattern: #"<(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?>([^<]*)"#)
        let metaTagRegex = try? NSRegularExpression(pattern: #"^\[(ti|ar|al|au|by|re|ve|length|offset):([^\]]*)\]$"#, options: .caseInsensitive)

        var offsetMs: Double = 0
        var timedEntries: [(time: Double, rawBody: String)] = []

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let metaTagRegex,
               let m = metaTagRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let tagRange = Range(m.range(at: 1), in: trimmed),
               let valRange = Range(m.range(at: 2), in: trimmed) {
                if trimmed[tagRange].lowercased() == "offset",
                   let parsedOffset = Double(trimmed[valRange].trimmingCharacters(in: .whitespaces)) {
                    offsetMs = parsedOffset
                }
                continue
            }

            guard let timestampRegex else { continue }
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = timestampRegex.matches(in: trimmed, range: nsRange)
            guard !matches.isEmpty else { continue }

            let lastEnd = matches.last!.range.upperBound
            let bodyStartIdx = trimmed.index(trimmed.startIndex, offsetBy: lastEnd)
            let bodyText = String(trimmed[bodyStartIdx...]).trimmingCharacters(in: .whitespaces)

            for m in matches {
                if let t = parseTimestampMatch(m, in: trimmed) {
                    timedEntries.append((max(0, t - offsetMs / 1000.0), bodyText))
                }
            }
        }

        if !timedEntries.isEmpty {
            timedEntries.sort { $0.time < $1.time }

            var built: [SyncedLyricLine] = []

            // Optional intro interlude dots when first lyric starts > 5.5s into the song
            if let first = timedEntries.first, first.time > 5.5, !first.rawBody.isEmpty {
                built.append(
                    SyncedLyricLine(
                        startTime: 0.4,
                        endTime: max(1.0, first.time - 0.35),
                        text: "",
                        words: [],
                        isInstrumentalBreak: true
                    )
                )
            }

            for i in 0..<timedEntries.count {
                let entry = timedEntries[i]
                let nextTime: Double = {
                    if i + 1 < timedEntries.count {
                        return max(entry.time + 0.4, timedEntries[i + 1].time)
                    }
                    if let duration, duration > entry.time + 0.5 {
                        return duration
                    }
                    return entry.time + 4.0
                }()

                let cleanPlain = stripEnhancedTimestamps(entry.rawBody)
                if cleanPlain.isEmpty {
                    // Explicit blank instrumental line in LRC if gap >= 3.2s
                    if nextTime - entry.time >= 3.2,
                       !(built.last?.isInstrumentalBreak ?? false) {
                        built.append(
                            SyncedLyricLine(
                                startTime: entry.time,
                                endTime: max(entry.time + 0.6, nextTime - 0.25),
                                text: "",
                                words: [],
                                isInstrumentalBreak: true
                            )
                        )
                    }
                    continue
                }

                let wordTimings: [LyricWordTiming]
                if let enhancedWordRegex,
                   let parsedEnhanced = parseEnhancedWords(
                       in: entry.rawBody,
                       lineStart: entry.time,
                       lineEnd: nextTime,
                       regex: enhancedWordRegex
                   ),
                   !parsedEnhanced.isEmpty {
                    wordTimings = parsedEnhanced
                } else {
                    wordTimings = synthesizeProportionalWordTimings(
                        text: cleanPlain,
                        lineStart: entry.time,
                        lineEnd: min(nextTime, entry.time + max(2.2, Double(cleanPlain.count) * 0.085))
                    )
                }

                // Cap vocal highlight end slightly before long pauses and inject Apple Music instrumental break dots
                let vocalGap = nextTime - entry.time
                let lineEndTime = vocalGap > 8.5 ? entry.time + min(5.5, max(2.8, Double(cleanPlain.count) * 0.08)) : nextTime

                built.append(
                    SyncedLyricLine(
                        startTime: entry.time,
                        endTime: lineEndTime,
                        text: cleanPlain,
                        words: wordTimings,
                        isInstrumentalBreak: false
                    )
                )

                if vocalGap > 8.5 && i + 1 < timedEntries.count {
                    let breakStart = lineEndTime + 0.3
                    let breakEnd = max(breakStart + 1.0, nextTime - 0.35)
                    if breakEnd > breakStart + 1.0 {
                        built.append(
                            SyncedLyricLine(
                                startTime: breakStart,
                                endTime: breakEnd,
                                text: "",
                                words: [],
                                isInstrumentalBreak: true
                            )
                        )
                    }
                }
            }

            return (true, built)
        }

        // Plain / Unsynced fallback
        let plainLines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                SyncedLyricLine(startTime: -1, endTime: -1, text: $0, words: [], isInstrumentalBreak: false)
            }
        return (false, plainLines)
    }

    nonisolated private static func parseTimestampMatch(_ match: NSTextCheckingResult, in text: String) -> Double? {
        guard let minRange = Range(match.range(at: 1), in: text),
              let secRange = Range(match.range(at: 2), in: text),
              let mins = Double(text[minRange]),
              let secs = Double(text[secRange]) else {
            return nil
        }
        var frac = 0.0
        if match.range(at: 3).location != NSNotFound,
           let fracRange = Range(match.range(at: 3), in: text) {
            let digits = String(text[fracRange])
            if let raw = Double(digits) {
                frac = digits.count >= 3 ? raw / 1000.0 : raw / 100.0
            }
        }
        return mins * 60.0 + secs + frac
    }

    nonisolated private static func stripEnhancedTimestamps(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"<\d{1,3}:\d{2}(?:[\.:]\d{1,3})?>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func parseEnhancedWords(
        in raw: String,
        lineStart: Double,
        lineEnd: Double,
        regex: NSRegularExpression
    ) -> [LyricWordTiming]? {
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard !matches.isEmpty else { return nil }

        var rawItems: [(time: Double, word: String)] = []
        for m in matches {
            guard let t = parseTimestampMatch(m, in: raw),
                  let textRange = Range(m.range(at: 4), in: raw) else { continue }
            let token = String(raw[textRange]).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty {
                rawItems.append((max(lineStart, t), token))
            }
        }
        guard !rawItems.isEmpty else { return nil }

        var words: [LyricWordTiming] = []
        for i in 0..<rawItems.count {
            let start = rawItems[i].time
            let end = (i + 1 < rawItems.count) ? max(start + 0.08, rawItems[i + 1].time) : max(start + 0.25, lineEnd)
            words.append(LyricWordTiming(text: rawItems[i].word, startTime: start, endTime: end))
        }
        return words
    }

    nonisolated private static func synthesizeProportionalWordTimings(
        text: String,
        lineStart: Double,
        lineEnd: Double
    ) -> [LyricWordTiming] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(0.35, lineEnd - lineStart)

        let weights: [Double] = tokens.map { token in
            var w = Double(max(2, token.count))
            if token.hasSuffix(",") || token.hasSuffix(";") { w += 1.5 }
            if token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?") { w += 2.2 }
            return w
        }
        let totalWeight = max(1.0, weights.reduce(0, +))
        var cursor = lineStart
        var result: [LyricWordTiming] = []

        for (idx, token) in tokens.enumerated() {
            let dur = span * (weights[idx] / totalWeight)
            let wordEnd = (idx == tokens.count - 1) ? lineEnd : (cursor + dur)
            result.append(LyricWordTiming(text: token, startTime: cursor, endTime: wordEnd))
            cursor = wordEnd
        }
        return result
    }

    // MARK: - Helpers & Genius HTML Extraction

    private func splitArtistAndSong(rawTitle: String, rawArtist: String) -> (song: String, artist: String) {
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: rawTitle, rawArtistTag: rawArtist)
        var song = Self.stripNoisyTitleTokens(cleaned.songOnly)
        var artist = Self.stripNoisyArtistTokens(cleaned.artistHint ?? rawArtist)

        for sep in [" - ", " — ", " – ", " | "] {
            if artist.isEmpty, let range = song.range(of: sep) {
                let left = String(song[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(song[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    artist = Self.stripNoisyArtistTokens(left)
                    song = Self.stripNoisyTitleTokens(right)
                    break
                }
            }
        }
        return (song.isEmpty ? rawTitle : song, artist)
    }

    private static func stripNoisyTitleTokens(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s*[\(\[]\s*(?:official|lyrics?|lyric video|audio|video|visualizer|mv|m/v|hd|4k|explicit|clean|remaster(?:ed)?(?:\s*\d{4})?)[^\)\]]*[\)\]]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"\s*[\(\[]\s*(?:feat|ft|featuring)\.?\s+[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripNoisyArtistTokens(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: " - Topic", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "VEVO", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ","), !s[..<comma].isEmpty {
            s = String(s[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func normalizeSmartPunctuation(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips remix/version/edit modifiers to uncover base song titles when an alternate upload has no dedicated entry.
    private static func extractCoreSongTitle(_ title: String) -> String {
        var s = normalizeSmartPunctuation(title)
        s = s.replacingOccurrences(
            of: #"\s*[\(\[]\s*(?:slowed(?:\s*(?:\+|&|and)?\s*reverb)?|sped\s*up|nightcore|reverb|bass\s*boosted|acoustic(?:\s*version)?|live(?:\s*at\s*[^\)\]]*)?|remix|edit|version|radio\s*edit|clean|explicit|8d(?:\s*audio)?|cover)[^\)\]]*[\)\]]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"\s*[-–—]\s*(?:slowed(?:\s*(?:\+|&|and)?\s*reverb)?|sped\s*up|nightcore|acoustic|live|remix|radio\s*edit)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeComparable(_ text: String) -> String {
        let stripped = normalizeSmartPunctuation(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: " ", options: .regularExpression)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(stripped.unicodeScalars.count)
        var lastWasSpace = true
        for scalar in stripped.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                scalars.append(" ")
                lastWasSpace = true
            }
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func extractGeniusLyricsText(fromHTML html: String) -> String? {
        guard let openTagRegex = try? NSRegularExpression(
            pattern: #"<div\b[^>]*data-lyrics-container\s*=\s*"true"[^>]*>"#,
            options: .caseInsensitive
        ),
              let divTokenRegex = try? NSRegularExpression(
                  pattern: #"<div\b[^>]*>|</div>"#,
                  options: .caseInsensitive
              ) else {
            return nil
        }

        let nsHTML = html as NSString
        let containerMatches = openTagRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var chunks: [String] = []

        for match in containerMatches {
            let contentStart = match.range.upperBound
            var depth = 1
            var contentEnd = nsHTML.length

            let tokens = divTokenRegex.matches(
                in: html,
                range: NSRange(location: contentStart, length: nsHTML.length - contentStart)
            )
            for token in tokens {
                let tokenText = nsHTML.substring(with: token.range)
                if tokenText.lowercased().hasPrefix("</div") {
                    depth -= 1
                    if depth == 0 {
                        contentEnd = token.range.location
                        break
                    }
                } else {
                    depth += 1
                }
            }

            guard contentEnd > contentStart else { continue }
            var snippet = nsHTML.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            // Remove nested Genius non-lyric header/contributor blocks marked data-exclude-from-selection
            snippet = removeExcludedDivs(in: snippet)
            snippet = snippet
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"</(?:div|p|li)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            snippet = decodeHTMLEntities(snippet)
            let cleaned = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                chunks.append(cleaned)
            }
        }

        let joined = chunks.joined(separator: "\n\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    nonisolated private static func removeExcludedDivs(in html: String) -> String {
        guard let exclRegex = try? NSRegularExpression(
            pattern: #"<div\b[^>]*data-exclude-from-selection\s*=\s*"true"[^>]*>"#,
            options: .caseInsensitive
        ),
              let divTokenRegex = try? NSRegularExpression(
                  pattern: #"<div\b[^>]*>|</div>"#,
                  options: .caseInsensitive
              ) else {
            return html
        }

        var working = html
        while let match = exclRegex.firstMatch(in: working, range: NSRange(location: 0, length: (working as NSString).length)) {
            let nsWorking = working as NSString
            var depth = 1
            var closeEnd = nsWorking.length
            let tokens = divTokenRegex.matches(
                in: working,
                range: NSRange(location: match.range.upperBound, length: nsWorking.length - match.range.upperBound)
            )
            for token in tokens {
                let txt = nsWorking.substring(with: token.range)
                if txt.lowercased().hasPrefix("</div") {
                    depth -= 1
                    if depth == 0 {
                        closeEnd = token.range.upperBound
                        break
                    }
                } else {
                    depth += 1
                }
            }
            working = nsWorking.replacingCharacters(
                in: NSRange(location: match.range.location, length: closeEnd - match.range.location),
                with: ""
            )
        }
        return working
    }

    nonisolated private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Disk Persistence

    private func loadFromDisk(key: String) -> ResolvedTrackLyrics? {
        let url = Self.cacheDirectoryURL.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResolvedTrackLyrics.self, from: data)
    }

    private func saveToDisk(_ lyrics: ResolvedTrackLyrics) {
        let url = Self.cacheDirectoryURL.appendingPathComponent("\(lyrics.cacheKey).json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(lyrics) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }
}
