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
    var hasNativeWordTimings: Bool = false
    var isSpokenDialogue: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, text, words, isInstrumentalBreak, hasNativeWordTimings, isSpokenDialogue
    }

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        text: String,
        words: [LyricWordTiming] = [],
        isInstrumentalBreak: Bool = false,
        hasNativeWordTimings: Bool = false,
        isSpokenDialogue: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
        self.isInstrumentalBreak = isInstrumentalBreak
        self.hasNativeWordTimings = hasNativeWordTimings
        self.isSpokenDialogue = isSpokenDialogue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
        text = try c.decode(String.self, forKey: .text)
        words = try c.decodeIfPresent([LyricWordTiming].self, forKey: .words) ?? []
        isInstrumentalBreak = try c.decodeIfPresent(Bool.self, forKey: .isInstrumentalBreak) ?? false
        hasNativeWordTimings = try c.decodeIfPresent(Bool.self, forKey: .hasNativeWordTimings) ?? false
        isSpokenDialogue = try c.decodeIfPresent(Bool.self, forKey: .isSpokenDialogue) ?? false
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
    var alignmentVersion: Int = 1
    let lines: [SyncedLyricLine]

    enum CodingKeys: String, CodingKey {
        case cacheKey, trackTitle, artistName, isTimeSynced, sourceLabel, attributionText
        case syncedOffsetSeconds, tempoScale, expectedDurationSeconds, alignmentVersion, lines
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
        alignmentVersion: Int = 1,
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
        self.alignmentVersion = alignmentVersion
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
        alignmentVersion = try c.decodeIfPresent(Int.self, forKey: .alignmentVersion) ?? 1
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
    nonisolated static let currentAlignmentVersion = 8

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
        let versionTag = Self.canonicalVersionGroups(in: rawTitle).sorted().joined(separator: ",")
        let durTag = item.durationSeconds.map { String(Int(round($0))) } ?? "0"
        let scopeTag = (titleOverride == nil && artistOverride == nil) ? item.relativePath : item.fileName
        let rawBase = "\(cleaned.artistHint ?? rawArtist)|\(cleaned.songOnly)|v:\(versionTag)|d:\(durTag)|\(scopeTag)".lowercased()
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
                if disk.alignmentVersion < Self.currentAlignmentVersion,
                   !item.relativePath.hasPrefix("__remote__/"),
                   !item.isHLS,
                   !disk.sourceLabel.localizedCaseInsensitiveContains("Custom") {
                    activeFetchTask?.cancel()
                    activeFetchTask = Task {
                        let summary = await SongAudioListener.listenWithSummary(
                            to: item.fileURL,
                            titleHint: item.displayTitle,
                            artistHint: item.artist
                        )
                        guard !Task.isCancelled else { return }
                        let heard: [HeardWord]? = summary.words.isEmpty ? nil : summary.words
                        let langCtx = SongAudioListener.detectLanguageContext(title: item.displayTitle, artist: item.artist)
                        let isNonEnglish = langCtx.isNonEnglish || {
                            guard let lang = summary.detectedLanguage?.lowercased(), !lang.isEmpty else { return false }
                            return !lang.hasPrefix("en")
                        }()
                        let isContradicted: Bool = {
                            guard let heard, !disk.sourceLabel.contains("Transcribed"), !isNonEnglish else { return false }
                            if case .contradicted = SongAudioListener.verdict(heard: heard, lyrics: disk) {
                                return true
                            }
                            return false
                        }()
                        if !isContradicted && (disk.isTimeSynced || disk.lines.count >= 4) {
                            let reAligned = await SongAudioListener.autoAlign(lyrics: disk, heard: heard, fileURL: item.fileURL)
                            storeAlignedLyrics(reAligned, for: item)
                        } else {
                            _ = await fetchAndAlignDuringImport(
                                item: item,
                                title: item.displayTitle,
                                artist: item.artist ?? "",
                                duration: item.durationSeconds,
                                heard: heard
                            )
                        }
                    }
                }
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
            let importAnalysisPending = SongIdentificationService.shared.isIdentifying(item)
            if !forceReload,
               customTitle == nil,
               customArtist == nil,
               !item.relativePath.hasPrefix("__remote__/"),
               (WholeSongAIService.shared.shouldDeferOnlineLyricsForFirstListen(item) || importAnalysisPending) {
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
                    if !importAnalysisPending {
                        WholeSongAIService.shared.triggerIfFirstTimeUnknown(item: item)
                    }
                    lastError = importAnalysisPending ? nil : "No lyrics for first time listen"
                }
                return
            }

            let rawTitle = (customTitle?.isEmpty == false ? customTitle! : item.displayTitle)
            let rawArtist = (customArtist?.isEmpty == false ? customArtist! : (item.artist ?? ""))

            if !item.relativePath.hasPrefix("__remote__/") {
                let split = splitArtistAndSong(rawTitle: rawTitle, rawArtist: rawArtist)
                if let offline = await loadOfflineEmbeddedOrSidecarLyrics(item: item, cacheKey: key, title: split.song, artist: split.artist) {
                    guard !Task.isCancelled else { return }
                    var alignedOffline = offline
                    if !item.isHLS {
                        let artistHintOrNil: String? = rawArtist.isEmpty ? nil : rawArtist
                        let preSummary = await SongAudioListener.listenWithSummary(
                            to: item.fileURL,
                            titleHint: rawTitle,
                            artistHint: artistHintOrNil
                        )
                        guard !Task.isCancelled else { return }
                        alignedOffline = await SongAudioListener.autoAlign(lyrics: offline, heard: preSummary.words, fileURL: item.fileURL)
                        guard !Task.isCancelled else { return }
                    }
                    alignedOffline.alignmentVersion = Self.currentAlignmentVersion
                    currentLoadingKey = nil
                    memoryCache[key] = alignedOffline
                    saveToDisk(alignedOffline)
                    currentLyrics = alignedOffline
                    lastError = nil
                    return
                }
            }

            let resolved: ResolvedTrackLyrics?
            if !item.relativePath.hasPrefix("__remote__/") && !item.isHLS {
                // Fetch all version candidates and listen to audio simultaneously for fast, version-safe alignment.
                async let candidatesTask = collectAllCandidateLyrics(
                    item: item,
                    cacheKey: key,
                    title: rawTitle,
                    artist: rawArtist,
                    duration: item.durationSeconds,
                    rawTitleOverride: customTitle
                )
                async let listenTask = SongAudioListener.listenWithSummary(
                    to: item.fileURL,
                    titleHint: rawTitle,
                    artistHint: rawArtist.isEmpty ? nil : rawArtist
                )
                let (candidates, summary) = await (candidatesTask, listenTask)
                guard !Task.isCancelled else { return }

                let heard: [HeardWord]? = summary.words.isEmpty ? nil : summary.words
                let langCtx = SongAudioListener.detectLanguageContext(
                    title: rawTitle,
                    artist: rawArtist.isEmpty ? nil : rawArtist
                )
                let isNonEnglish = langCtx.isNonEnglish || {
                    guard let lang = summary.detectedLanguage?.lowercased(), !lang.isEmpty else { return false }
                    return !lang.hasPrefix("en")
                }()
                let englishASROnForeignTrack = isNonEnglish && (summary.detectedLanguage?.lowercased().hasPrefix("en") ?? false)

                var chosen = selectVerifiedLyrics(
                    from: candidates,
                    targetTitle: rawTitle,
                    targetArtist: rawArtist,
                    targetDuration: item.durationSeconds,
                    heard: heard,
                    isNonEnglish: isNonEnglish,
                    englishASROnForeignTrack: englishASROnForeignTrack
                )
                if var matched = chosen {
                    matched = await SongAudioListener.autoAlign(lyrics: matched, heard: heard, fileURL: item.fileURL)
                    guard !Task.isCancelled else { return }
                    chosen = matched
                } else if let heard, heard.count >= 4, !englishASROnForeignTrack {
                    let split = splitArtistAndSong(rawTitle: rawTitle, rawArtist: rawArtist)
                    chosen = SongAudioListener.buildSyncedLyricsFromHeard(
                        heard,
                        trackTitle: split.song.isEmpty ? item.displayTitle : split.song,
                        artistName: split.artist.isEmpty ? (item.artist ?? "Unknown Artist") : split.artist,
                        cacheKey: key,
                        duration: item.durationSeconds
                    )
                }
                resolved = chosen
            } else {
                resolved = await fetchBestLyrics(
                    item: item,
                    cacheKey: key,
                    customTitle: customTitle,
                    customArtist: customArtist
                )
            }

            guard !Task.isCancelled else { return }
            if var resolved {
                resolved.alignmentVersion = Self.currentAlignmentVersion
                currentLoadingKey = nil
                memoryCache[key] = resolved
                saveToDisk(resolved)
                currentLyrics = resolved
                lastError = nil
            } else {
                currentLoadingKey = nil
                lastError = "No lyrics for first time listen"
                if customTitle == nil && customArtist == nil && !item.relativePath.hasPrefix("__remote__/") && !importAnalysisPending {
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
            tempoScale: lyrics.tempoScale,
            expectedDurationSeconds: lyrics.expectedDurationSeconds,
            alignmentVersion: Self.currentAlignmentVersion,
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

    /// Collects candidates from all lyrics sources and picks the version-verified match for this audio.
    func fetchVerifiedLyricsCandidate(
        item: MediaItem,
        title: String,
        artist: String,
        duration: Double?,
        heard: [HeardWord]?,
        isNonEnglish: Bool = false,
        englishASROnForeignTrack: Bool = false
    ) async -> (lyrics: ResolvedTrackLyrics, confirmedByAudio: Bool)? {
        let candidates = await prefetchCandidatesForImport(
            item: item,
            title: title,
            artist: artist,
            duration: duration
        )
        guard !candidates.isEmpty else { return nil }
        return selectVerifiedCandidateWithConfidence(
            from: candidates,
            targetTitle: title,
            targetArtist: artist,
            targetDuration: duration,
            heard: heard,
            isNonEnglish: isNonEnglish,
            englishASROnForeignTrack: englishASROnForeignTrack
        )
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
        aiStatusMessage = "Listening across full song..."

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
                let existingArtist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let needsArtistFill = existingArtist.isEmpty || existingArtist == "Unknown Artist"
                if outcome.isHighConfidence && (forceReidentify || (!MediaManager.shared.isArtistVerified(for: item) && needsArtistFill)) {
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
        let candidates = await fetchTopLRCLIBCandidates(
            cacheKey: "verify",
            song: title,
            artist: artist,
            rawTitle: title,
            duration: duration,
            maxResults: 3
        )
        let targetText = "\(title) \(artist)"
        return candidates.first { cand in
            Self.versionCompatibilityScore(
                targetText: targetText,
                candidateText: "\(cand.trackTitle) \(cand.artistName)",
                targetDuration: duration,
                candidateDuration: cand.expectedDurationSeconds
            ) >= 0
        } ?? candidates.first
    }

    /// Starts fetching version candidates from all lyrics providers simultaneously while audio analysis runs.
    func prefetchCandidatesForImport(
        item: MediaItem,
        title: String,
        artist: String,
        duration: Double?
    ) async -> [ResolvedTrackLyrics] {
        let key = cacheKey(for: item, artistOverride: artist, titleOverride: title)
        return await collectAllCandidateLyrics(
            item: item,
            cacheKey: key,
            title: title,
            artist: artist,
            duration: duration,
            rawTitleOverride: title
        )
    }

    /// Concurrently collects candidate lyrics from Studio Karaoke, LRCLIB, Genius, and YouTube captions.
    private func collectAllCandidateLyrics(
        item: MediaItem,
        cacheKey key: String,
        title: String,
        artist: String,
        duration: Double?,
        rawTitleOverride: String? = nil
    ) async -> [ResolvedTrackLyrics] {
        let split = splitArtistAndSong(rawTitle: title, rawArtist: artist)
        let rawTitle = (rawTitleOverride?.isEmpty == false ? rawTitleOverride! : title)

        async let studioTask = fetchStudioKaraokeCandidates(
            cacheKey: key,
            song: split.song,
            artist: split.artist,
            duration: duration
        )
        async let lrclibTask = fetchTopLRCLIBCandidates(
            cacheKey: key,
            song: split.song,
            artist: split.artist,
            rawTitle: rawTitle,
            duration: duration,
            maxResults: 4
        )
        async let geniusTask = fetchTopGeniusCandidates(
            cacheKey: key,
            song: split.song,
            artist: split.artist,
            maxResults: 2
        )
        async let ytTask = fetchFromYouTubeCreatorSubtitles(
            item: item,
            cacheKey: key,
            song: split.song,
            artist: split.artist
        )

        let (studio, lrclib, genius, ytCaptions) = await (studioTask, lrclibTask, geniusTask, ytTask)
        var combined = studio + lrclib + genius
        if let ytCaptions {
            combined.append(ytCaptions)
        }

        var deduped: [ResolvedTrackLyrics] = []
        var seen = Set<String>()
        for cand in combined {
            let sig = "\(Self.normalizeComparable(cand.trackTitle))|\(Self.normalizeComparable(cand.artistName))|\(cand.sourceLabel)|\(cand.lines.count)"
            if seen.insert(sig).inserted {
                deduped.append(cand)
                if deduped.count >= 8 { break }
            }
        }
        return deduped
    }

    nonisolated private static func containsNonLatinScript(_ lyrics: ResolvedTrackLyrics) -> Bool {
        for line in lyrics.lines.prefix(12) {
            for scalar in line.text.unicodeScalars {
                let v = scalar.value
                if (0x0400...0x04FF).contains(v) ||
                    (0x0600...0x06FF).contains(v) ||
                    (0x3040...0x30FF).contains(v) ||
                    (0x4E00...0x9FFF).contains(v) ||
                    (0xAC00...0xD7AF).contains(v) {
                    return true
                }
            }
        }
        return false
    }

    /// Evaluates candidate versions against metadata compatibility AND symmetric heard-audio verification.
    func selectVerifiedCandidateWithConfidence(
        from candidates: [ResolvedTrackLyrics],
        targetTitle: String,
        targetArtist: String,
        targetDuration: Double?,
        heard: [HeardWord]?,
        isNonEnglish: Bool,
        englishASROnForeignTrack: Bool
    ) -> (lyrics: ResolvedTrackLyrics, confirmedByAudio: Bool)? {
        guard !candidates.isEmpty else { return nil }
        let targetText = "\(targetTitle) \(targetArtist)"

        var bestCandidate: ResolvedTrackLyrics?
        var bestConfirmed = false
        var bestScore = -Double.infinity

        for cand in candidates {
            let hasNativeWords = cand.lines.contains { $0.hasNativeWordTimings && !$0.words.isEmpty }
            var score = hasNativeWords ? 0.45 : (cand.isTimeSynced ? 0.25 : 0.0)
            let compat = Self.versionCompatibilityScore(
                targetText: targetText,
                candidateText: "\(cand.trackTitle) \(cand.artistName)",
                targetDuration: targetDuration,
                candidateDuration: cand.expectedDurationSeconds
            )
            score += Double(compat) * 0.015

            var confirmed = false
            var rejected = false

            if let heard, !heard.isEmpty {
                let report = SongAudioListener.versionAlignmentConfidence(heard: heard, lyrics: cand)
                let foreignMismatch = englishASROnForeignTrack || (isNonEnglish && Self.containsNonLatinScript(cand))
                switch report.verdict {
                case .confirmed:
                    confirmed = true
                    score += 2.2 + report.compositeScore * 1.8
                case .inconclusive:
                    score += 0.1 + (foreignMismatch ? 0 : report.globalMatchRatio * 0.5)
                case .contradicted:
                    if foreignMismatch && compat >= 0 {
                        score -= 0.1
                    } else {
                        rejected = true
                        score -= 4.5
                    }
                }
            }

            if !rejected && score > bestScore {
                bestScore = score
                bestCandidate = cand
                bestConfirmed = confirmed
            }
        }

        guard let selected = bestCandidate, bestScore > -0.65 else { return nil }
        return (selected, bestConfirmed)
    }

    private func selectVerifiedLyrics(
        from candidates: [ResolvedTrackLyrics],
        targetTitle: String,
        targetArtist: String,
        targetDuration: Double?,
        heard: [HeardWord]?,
        isNonEnglish: Bool,
        englishASROnForeignTrack: Bool
    ) -> ResolvedTrackLyrics? {
        selectVerifiedCandidateWithConfidence(
            from: candidates,
            targetTitle: targetTitle,
            targetArtist: targetArtist,
            targetDuration: targetDuration,
            heard: heard,
            isNonEnglish: isNonEnglish,
            englishASROnForeignTrack: englishASROnForeignTrack
        )?.lyrics
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
        heard: [HeardWord]?,
        prefetchedCandidates: [ResolvedTrackLyrics]? = nil,
        isNonEnglish: Bool = false,
        englishASROnForeignTrack: Bool = false
    ) async -> Bool {
        let key = cacheKey(for: item, artistOverride: artist, titleOverride: title)
        let split = splitArtistAndSong(rawTitle: title, rawArtist: artist)

        let candidates: [ResolvedTrackLyrics]
        if let prefetchedCandidates {
            candidates = prefetchedCandidates.map { cand in
                ResolvedTrackLyrics(
                    cacheKey: key,
                    trackTitle: cand.trackTitle,
                    artistName: cand.artistName,
                    isTimeSynced: cand.isTimeSynced,
                    sourceLabel: cand.sourceLabel,
                    attributionText: cand.attributionText,
                    syncedOffsetSeconds: cand.syncedOffsetSeconds,
                    tempoScale: cand.tempoScale,
                    expectedDurationSeconds: cand.expectedDurationSeconds,
                    alignmentVersion: cand.alignmentVersion,
                    lines: cand.lines
                )
            }
        } else {
            candidates = await collectAllCandidateLyrics(
                item: item,
                cacheKey: key,
                title: title,
                artist: artist,
                duration: duration,
                rawTitleOverride: title
            )
        }

        let langHintNonEnglish = isNonEnglish || SongAudioListener.detectLanguageContext(title: title, artist: artist.isEmpty ? nil : artist).isNonEnglish

        // Don't lock in clearly wrong version lyrics if the audio contradicted all candidates.
        if var selected = selectVerifiedLyrics(
            from: candidates,
            targetTitle: title,
            targetArtist: artist,
            targetDuration: duration,
            heard: heard,
            isNonEnglish: langHintNonEnglish,
            englishASROnForeignTrack: englishASROnForeignTrack
        ) {
            if !item.isHLS {
                selected = await SongAudioListener.autoAlign(lyrics: selected, heard: heard, fileURL: item.fileURL)
            }
            storeAlignedLyrics(selected, for: item)
            return true
        }

        // Unreleased / offline-only / alternate-version song fallback: build synced lyrics from speech transcription.
        if let heard, heard.count >= 4, !englishASROnForeignTrack {
            let finalTitle = split.song.isEmpty ? item.displayTitle : split.song
            let finalArtist = split.artist.isEmpty ? (item.artist ?? "Unknown Artist") : split.artist
            if let transcribed = SongAudioListener.buildSyncedLyricsFromHeard(
                heard,
                trackTitle: finalTitle,
                artistName: finalArtist,
                cacheKey: cacheKey(for: item),
                duration: duration ?? item.durationSeconds
            ) {
                storeAlignedLyrics(transcribed, for: item)
                return true
            }
        }
        return false
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
            syncedOffsetSeconds: lyrics.syncedOffsetSeconds,
            tempoScale: lyrics.tempoScale,
            expectedDurationSeconds: item.durationSeconds,
            alignmentVersion: Self.currentAlignmentVersion,
            lines: lyrics.lines
        )
        memoryCache[key] = stored
        saveToDisk(stored)
        autoAttemptedKeys.insert(key)
        let isCurrentlyPlayingItem = MediaManager.shared.currentItem?.relativePath == item.relativePath
        if currentLyrics?.cacheKey == key || isCurrentlyPlayingItem {
            currentLyrics = stored
            if currentLoadingKey == key {
                currentLoadingKey = nil
            }
            lastError = nil
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

        // 2. Fetch Studio Karaoke, LRCLIB, Genius, and YouTube captions concurrently and rank by version/duration match.
        let candidates = await collectAllCandidateLyrics(
            item: item,
            cacheKey: cacheKey,
            title: rawTitle,
            artist: rawArtist,
            duration: duration,
            rawTitleOverride: customTitle
        )
        return selectVerifiedLyrics(
            from: candidates,
            targetTitle: rawTitle,
            targetArtist: rawArtist,
            targetDuration: duration,
            heard: nil,
            isNonEnglish: false,
            englishASROnForeignTrack: false
        )
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
        await fetchTopLRCLIBCandidates(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            rawTitle: rawTitle,
            duration: duration,
            maxResults: 1
        ).first
    }

    private func fetchTopLRCLIBCandidates(
        cacheKey: String,
        song: String,
        artist: String,
        rawTitle: String,
        duration: Double?,
        maxResults: Int = 4
    ) async -> [ResolvedTrackLyrics] {
        let querySong = Self.normalizeSmartPunctuation(song)
        let queryArtist = Self.normalizeSmartPunctuation(artist)
        let coreSong = Self.extractCoreSongTitle(querySong)

        var allCandidates: [LRCLIBCandidate] = []
        var exactQuickMatch: ResolvedTrackLyrics?

        // Run fast /api/get and primary /api/search queries concurrently instead of sequentially.
        var getURL: URL?
        if !queryArtist.isEmpty, let dur = duration, dur > 5 {
            var comps = URLComponents(string: "https://lrclib.net/api/get")
            comps?.queryItems = [
                URLQueryItem(name: "track_name", value: querySong),
                URLQueryItem(name: "artist_name", value: queryArtist),
                URLQueryItem(name: "duration", value: String(Int(round(dur))))
            ]
            getURL = comps?.url
        }

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

        let capturedGetURL = getURL
        async let getRowTask: [String: Any]? = {
            guard let capturedGetURL else { return nil }
            return await fetchSingleLRCLIBObject(url: capturedGetURL)
        }()
        let capturedPrimary = primaryQueries
        async let searchRowsTask: [[String: Any]] = withTaskGroup(of: [[String: Any]].self) { group in
            for url in capturedPrimary {
                group.addTask {
                    await self.fetchLRCLIBSearchArray(url: url)
                }
            }
            var collected: [[String: Any]] = []
            for await rows in group {
                collected.append(contentsOf: rows)
            }
            return collected
        }

        let (getRow, searchRows) = await (getRowTask, searchRowsTask)

        if let getRow {
            let scoredGet = scoreLRCLIBRow(
                getRow,
                targetSong: querySong,
                coreSong: coreSong,
                targetArtist: queryArtist,
                targetDuration: duration,
                strictArtistlessGuard: false
            )
            let compat = Self.versionCompatibilityScore(
                targetText: "\(rawTitle) \(querySong)",
                candidateText: "\(scoredGet.trackName) \(scoredGet.albumName ?? "")",
                targetDuration: duration,
                candidateDuration: scoredGet.duration,
                includeDurationScore: false
            )
            let durOK: Bool = {
                guard let dur = duration, let cDur = scoredGet.duration, dur > 5 else { return true }
                return abs(dur - cDur) <= 12.0
            }()
            if scoredGet.score >= 45 && compat >= 0 && durOK {
                if maxResults == 1, scoredGet.score >= 85,
                   let built = buildLyricsFromLRCLIBCandidate(scoredGet, cacheKey: cacheKey, duration: duration) {
                    exactQuickMatch = built
                } else {
                    allCandidates.append(scoredGet)
                }
            } else if scoredGet.score > 10 {
                allCandidates.append(scoredGet)
            }
        }
        if let exactQuickMatch {
            return [exactQuickMatch]
        }

        for row in searchRows {
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

            let capturedFallback = fallbackQueries
            let fallbackBatches: [(artistless: Bool, rows: [[String: Any]])] = await withTaskGroup(
                of: (Bool, [[String: Any]]).self
            ) { group in
                for entry in capturedFallback {
                    group.addTask {
                        let rows = await self.fetchLRCLIBSearchArray(url: entry.url)
                        return (entry.artistless, rows)
                    }
                }
                var out: [(Bool, [[String: Any]])] = []
                for await pair in group {
                    out.append(pair)
                }
                return out
            }
            for batch in fallbackBatches {
                for row in batch.rows {
                    let candidate = scoreLRCLIBRow(
                        row,
                        targetSong: querySong,
                        coreSong: coreSong,
                        targetArtist: queryArtist,
                        targetDuration: duration,
                        strictArtistlessGuard: batch.artistless
                    )
                    if candidate.score > 15 {
                        allCandidates.append(candidate)
                    }
                }
            }
        }

        let sorted = allCandidates.sorted { $0.score > $1.score }
        var builtResults: [ResolvedTrackLyrics] = []
        var seenSignatures = Set<String>()
        for cand in sorted {
            let sig = "\(Self.normalizeComparable(cand.trackName))|\(Self.normalizeComparable(cand.artistName))|\(cand.duration.map { Int(round($0)) } ?? 0)|\(!(cand.syncedLyrics?.isEmpty ?? true))"
            guard seenSignatures.insert(sig).inserted else { continue }
            if let built = buildLyricsFromLRCLIBCandidate(cand, cacheKey: cacheKey, duration: duration) {
                builtResults.append(built)
                if builtResults.count >= maxResults { break }
            }
        }
        return builtResults
    }

    private func buildLyricsFromLRCLIBCandidate(
        _ best: LRCLIBCandidate,
        cacheKey: String,
        duration: Double?
    ) -> ResolvedTrackLyrics? {
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
            } else if diff > 12.0 {
                score -= diff > 22.0 ? 60 : 35
            }
        }

        // Score bidirectional version compatibility (clean vs explicit, remix, live, slowed, demo, v1/v2, pt2, etc.)
        let hitCombined = "\(trackName) \((row["albumName"] as? String) ?? "")"
        score += Self.versionCompatibilityScore(
            targetText: targetSong,
            candidateText: hitCombined,
            targetDuration: targetDuration,
            candidateDuration: dur,
            includeDurationScore: false
        )

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

    // MARK: - Studio Word-Level Karaoke Lyrics (NetEase YRC + Kugou KRC)

    private func fetchFromStudioKaraoke(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?
    ) async -> ResolvedTrackLyrics? {
        await fetchStudioKaraokeCandidates(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            duration: duration
        ).first
    }

    private func fetchStudioKaraokeCandidates(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?
    ) async -> [ResolvedTrackLyrics] {
        let querySong = Self.normalizeSmartPunctuation(song).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !querySong.isEmpty else { return [] }
        let rawArtist = Self.normalizeSmartPunctuation(artist)
        let canonArtist = ArtistDatabase.canonicalizeSingle(rawArtist)
        let queryArtist = canonArtist.isEmpty ? rawArtist : canonArtist

        async let neteaseTask = fetchTopNetEaseKaraokeCandidates(
            cacheKey: cacheKey,
            song: querySong,
            artist: queryArtist,
            duration: duration,
            maxResults: 2
        )
        async let kugouTask = fetchTopKugouKaraokeCandidates(
            cacheKey: cacheKey,
            song: querySong,
            artist: queryArtist,
            duration: duration,
            maxResults: 2
        )
        let (netease, kugou) = await (neteaseTask, kugouTask)
        return netease + kugou
    }

    private func fetchFromNetEaseKaraoke(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?
    ) async -> ResolvedTrackLyrics? {
        await fetchTopNetEaseKaraokeCandidates(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            duration: duration,
            maxResults: 1
        ).first
    }

    private func fetchTopNetEaseKaraokeCandidates(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?,
        maxResults: Int = 2
    ) async -> [ResolvedTrackLyrics] {
        guard let searchURL = URL(string: "https://music.163.com/api/search/get") else { return [] }
        let fullQuery = [artist, song].filter { !$0.isEmpty }.joined(separator: " ")
        let coreSong = Self.extractCoreSongTitle(song)
        let coreQuery = [artist, coreSong].filter { !$0.isEmpty }.joined(separator: " ")

        func searchSongs(query: String) async -> [[String: Any]] {
            guard !query.isEmpty else { return [] }
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._* ")
            let encodedQuery = (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query)
                .replacingOccurrences(of: " ", with: "+")
            var req = URLRequest(url: searchURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.httpBody = "s=\(encodedQuery)&type=1&limit=6".data(using: .utf8)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultObj = json["result"] as? [String: Any],
                  let songs = resultObj["songs"] as? [[String: Any]] else {
                return []
            }
            return songs
        }

        var songs = await searchSongs(query: fullQuery)
        if songs.isEmpty && !coreQuery.isEmpty && coreQuery.lowercased() != fullQuery.lowercased() {
            songs = await searchSongs(query: coreQuery)
        }
        guard !songs.isEmpty else { return [] }

        var scoredHits: [(id: Int, title: String, artist: String, durationSec: Double?, score: Int)] = []
        let normSong = Self.normalizeComparable(song)
        let normCore = Self.normalizeComparable(coreSong)
        let normArtist = Self.normalizeComparable(artist)
        let targetText = "\(song) \(artist)"

        for row in songs {
            guard let sid = row["id"] as? Int,
                  let rTitle = row["name"] as? String else { continue }
            let rArtists = ((row["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            let rArtist = rArtists.first ?? ""
            let rDur = (row["duration"] as? Double).map { $0 / 1000.0 } ?? (row["duration"] as? Int).map { Double($0) / 1000.0 }

            let nTitle = Self.normalizeComparable(rTitle)
            let nArtist = Self.normalizeComparable(rArtist)
            var score = 0
            if nTitle == normSong || (!normCore.isEmpty && nTitle == normCore) { score += 50 }
            else if nTitle.contains(normCore) || (!nTitle.isEmpty && normCore.contains(nTitle)) { score += 26 }
            else { continue }

            if !normArtist.isEmpty {
                if nArtist == normArtist || rArtists.contains(where: { Self.normalizeComparable($0) == normArtist }) {
                    score += 40
                } else if !nArtist.isEmpty && (nArtist.contains(normArtist) || normArtist.contains(nArtist)) {
                    score += 24
                } else {
                    score -= 20
                }
            }

            if let duration, let rDur, duration > 5 {
                let diff = abs(duration - rDur)
                if diff <= 3.0 { score += 35 }
                else if diff <= 9.0 { score += 18 }
                else if diff > 18.0 { score -= 45 }
            }

            score += Self.versionCompatibilityScore(
                targetText: targetText,
                candidateText: "\(rTitle) \(rArtist)",
                targetDuration: duration,
                candidateDuration: rDur,
                includeDurationScore: false
            )

            if score >= 50 {
                scoredHits.append((sid, rTitle, rArtist, rDur, score))
            }
        }

        let topHits = Array(scoredHits.sorted { $0.score > $1.score }.prefix(maxResults))
        guard !topHits.isEmpty else { return [] }

        return await withTaskGroup(of: ResolvedTrackLyrics?.self) { group in
            for chosen in topHits {
                group.addTask {
                    guard let lyrURL = URL(string: "https://music.163.com/api/song/lyric/v1?id=\(chosen.id)&lv=1&kv=1&tv=-1&yv=1") else {
                        return nil
                    }
                    var lyrReq = URLRequest(url: lyrURL)
                    lyrReq.timeoutInterval = 10
                    lyrReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                    lyrReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

                    guard let (lData, lResp) = try? await URLSession.shared.data(for: lyrReq),
                          let lHttp = lResp as? HTTPURLResponse, (200...299).contains(lHttp.statusCode),
                          let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
                          let yrcObj = lJson["yrc"] as? [String: Any],
                          let yrcText = yrcObj["lyric"] as? String, !yrcText.isEmpty else {
                        return nil
                    }

                    let lines = Self.parseKaraokeTimedLines(
                        text: yrcText,
                        isKugouKRC: false,
                        song: chosen.title,
                        artist: chosen.artist,
                        duration: duration ?? chosen.durationSec
                    )
                    guard lines.filter({ !$0.isInstrumentalBreak }).count >= 6 else { return nil }
                    return ResolvedTrackLyrics(
                        cacheKey: cacheKey,
                        trackTitle: chosen.title,
                        artistName: chosen.artist,
                        isTimeSynced: true,
                        sourceLabel: "Word-Synced Lyrics · Studio",
                        attributionText: "Word-by-word karaoke sync via NetEase",
                        syncedOffsetSeconds: 0,
                        expectedDurationSeconds: chosen.durationSec ?? duration,
                        lines: lines
                    )
                }
            }
            var out: [ResolvedTrackLyrics] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }
    }

    private func fetchFromKugouKaraoke(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?
    ) async -> ResolvedTrackLyrics? {
        await fetchTopKugouKaraokeCandidates(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            duration: duration,
            maxResults: 1
        ).first
    }

    private func fetchTopKugouKaraokeCandidates(
        cacheKey: String,
        song: String,
        artist: String,
        duration: Double?,
        maxResults: Int = 2
    ) async -> [ResolvedTrackLyrics] {
        let fullKeyword = [artist, song].filter { !$0.isEmpty }.joined(separator: " - ")
        let coreSong = Self.extractCoreSongTitle(song)
        let coreKeyword = [artist, coreSong].filter { !$0.isEmpty }.joined(separator: " - ")
        guard !fullKeyword.isEmpty else { return [] }

        func searchKugou(keyword: String) async -> [[String: Any]] {
            guard !keyword.isEmpty else { return [] }
            var comps = URLComponents(string: "https://lyrics.kugou.com/search")
            var items = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "man", value: "yes"),
                URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "keyword", value: keyword)
            ]
            if let duration, duration > 5 {
                items.append(URLQueryItem(name: "duration", value: String(Int((duration * 1000.0).rounded()))))
            }
            comps?.queryItems = items
            guard let searchURL = comps?.url else { return [] }

            var req = URLRequest(url: searchURL)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)", forHTTPHeaderField: "User-Agent")

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]] else {
                return []
            }
            return candidates
        }

        var candidates = await searchKugou(keyword: fullKeyword)
        if candidates.isEmpty && !coreKeyword.isEmpty && coreKeyword.lowercased() != fullKeyword.lowercased() {
            candidates = await searchKugou(keyword: coreKeyword)
        }
        guard !candidates.isEmpty else { return [] }

        let normSong = Self.normalizeComparable(song)
        let normCore = Self.normalizeComparable(coreSong)
        let normArtist = Self.normalizeComparable(artist)
        let targetText = "\(song) \(artist)"

        var scored: [(id: String, accesskey: String, song: String, singer: String, durSec: Double?, score: Int)] = []
        for cand in candidates.prefix(8) {
            guard let cid = cand["id"] as? String,
                  let key = cand["accesskey"] as? String,
                  let cSong = cand["song"] as? String else { continue }
            let cSinger = (cand["singer"] as? String) ?? ""
            let cDur = (cand["duration"] as? Double).map { $0 / 1000.0 } ?? (cand["duration"] as? Int).map { Double($0) / 1000.0 }
            let nTitle = Self.normalizeComparable(cSong)
            let nSinger = Self.normalizeComparable(cSinger)

            var score = 0
            if nTitle == normSong || (!normCore.isEmpty && nTitle == normCore) { score += 50 }
            else if nTitle.contains(normCore) || (!nTitle.isEmpty && normCore.contains(nTitle)) { score += 26 }
            else { continue }

            if !normArtist.isEmpty {
                if nSinger == normArtist { score += 40 }
                else if !nSinger.isEmpty && (nSinger.contains(normArtist) || normArtist.contains(nSinger)) { score += 25 }
                else { score -= 20 }
            }
            if let duration, let cDur, duration > 5 {
                let diff = abs(duration - cDur)
                if diff <= 3.0 { score += 35 }
                else if diff <= 9.0 { score += 18 }
                else if diff > 18.0 { score -= 45 }
            }

            score += Self.versionCompatibilityScore(
                targetText: targetText,
                candidateText: "\(cSong) \(cSinger)",
                targetDuration: duration,
                candidateDuration: cDur,
                includeDurationScore: false
            )

            if score >= 50 {
                scored.append((cid, key, cSong, cSinger, cDur, score))
            }
        }

        let topHits = Array(scored.sorted { $0.score > $1.score }.prefix(maxResults))
        guard !topHits.isEmpty else { return [] }

        return await withTaskGroup(of: ResolvedTrackLyrics?.self) { group in
            for chosen in topHits {
                group.addTask {
                    var dlComps = URLComponents(string: "https://lyrics.kugou.com/download")
                    dlComps?.queryItems = [
                        URLQueryItem(name: "ver", value: "1"),
                        URLQueryItem(name: "client", value: "pc"),
                        URLQueryItem(name: "id", value: chosen.id),
                        URLQueryItem(name: "accesskey", value: chosen.accesskey),
                        URLQueryItem(name: "fmt", value: "krc"),
                        URLQueryItem(name: "charset", value: "utf8")
                    ]
                    guard let dlURL = dlComps?.url else { return nil }

                    var dlReq = URLRequest(url: dlURL)
                    dlReq.timeoutInterval = 10
                    dlReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)", forHTTPHeaderField: "User-Agent")

                    guard let (dlData, dlResp) = try? await URLSession.shared.data(for: dlReq),
                          let dlHttp = dlResp as? HTTPURLResponse, (200...299).contains(dlHttp.statusCode),
                          let dlJson = try? JSONSerialization.jsonObject(with: dlData) as? [String: Any],
                          let b64 = dlJson["content"] as? String,
                          let rawData = Data(base64Encoded: b64),
                          let krcText = Self.decodeKugouKRC(rawData), !krcText.isEmpty else {
                        return nil
                    }

                    let lines = Self.parseKaraokeTimedLines(
                        text: krcText,
                        isKugouKRC: true,
                        song: chosen.song,
                        artist: chosen.singer,
                        duration: duration ?? chosen.durSec
                    )
                    guard lines.filter({ !$0.isInstrumentalBreak }).count >= 6 else { return nil }
                    return ResolvedTrackLyrics(
                        cacheKey: cacheKey,
                        trackTitle: chosen.song,
                        artistName: chosen.singer,
                        isTimeSynced: true,
                        sourceLabel: "Word-Synced Lyrics · Studio",
                        attributionText: "Word-by-word karaoke sync via Kugou",
                        syncedOffsetSeconds: 0,
                        expectedDurationSeconds: chosen.durSec ?? duration,
                        lines: lines
                    )
                }
            }
            var out: [ResolvedTrackLyrics] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }
    }

    nonisolated private static func decodeKugouKRC(_ data: Data) -> String? {
        guard data.count > 10, data.prefix(4) == Data([0x6B, 0x72, 0x63, 0x31]) else {
            return nil
        }
        let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]
        var xorBytes = Data(capacity: data.count - 4)
        for (i, byte) in data.dropFirst(4).enumerated() {
            xorBytes.append(byte ^ key[i % 16])
        }
        // Zlib RFC 1950 header (2 bytes, e.g. 0x78 0x9c) + raw deflate payload + 4-byte adler32 trailer
        guard xorBytes.count > 6 else { return nil }
        let rawDeflate = Data(xorBytes.dropFirst(2).dropLast(4))
        guard let decompressed = try? (rawDeflate as NSData).decompressed(using: .zlib) as Data else {
            return nil
        }
        return String(data: decompressed, encoding: .utf8)
    }

    nonisolated private static func parseKaraokeTimedLines(
        text: String,
        isKugouKRC: Bool,
        song: String,
        artist: String,
        duration: Double?
    ) -> [SyncedLyricLine] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let rawLines = normalized.components(separatedBy: "\n")

        guard let lineRegex = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#),
              let tokenRegex = try? NSRegularExpression(
                  pattern: isKugouKRC ? #"<(\d+),(\d+),\d+>([^<]*)"# : #"\((\d+),(\d+),\d+\)([^\(]*)"#
              ) else {
            return []
        }

        let normSongArtist = normalizeComparable("\(song) \(artist)")
        var rawBuilt: [(start: Double, end: Double, text: String, words: [LyricWordTiming])] = []

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("{"),
                  trimmed.hasPrefix("[") else { continue }
            let nsLine = trimmed as NSString
            guard let lm = lineRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsLine.length)),
                  lm.numberOfRanges > 3,
                  let startMs = Double(nsLine.substring(with: lm.range(at: 1))),
                  let durMs = Double(nsLine.substring(with: lm.range(at: 2))) else {
                continue
            }
            let body = nsLine.substring(with: lm.range(at: 3))
            let lineStart = startMs / 1000.0
            let lineEnd = max(lineStart + 0.35, (startMs + max(durMs, 350.0)) / 1000.0)

            let nsBody = body as NSString
            let matches = tokenRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            var segments: [(text: String, start: Double, end: Double)] = []
            for m in matches where m.numberOfRanges > 3 {
                guard let tRaw = Double(nsBody.substring(with: m.range(at: 1))),
                      let dRaw = Double(nsBody.substring(with: m.range(at: 2))) else { continue }
                let tok = nsBody.substring(with: m.range(at: 3))
                let wStart = isKugouKRC ? (lineStart + tRaw / 1000.0) : (tRaw / 1000.0)
                let wEnd = max(wStart + 0.05, wStart + (dRaw / 1000.0))
                segments.append((tok, max(lineStart, wStart), min(lineEnd + 0.5, wEnd)))
            }

            // Merge sub-syllable runs into space-separated words preserving exact start..end timing.
            var mergedWords: [LyricWordTiming] = []
            var curText = ""
            var curStart: Double?
            var curEnd: Double = lineStart

            func flushWord() {
                let clean = curText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty, let s = curStart {
                    mergedWords.append(LyricWordTiming(text: clean, startTime: s, endTime: max(s + 0.05, curEnd)))
                }
                curText = ""
                curStart = nil
            }

            for seg in segments {
                let rawTok = seg.text
                if rawTok.first?.isWhitespace == true {
                    flushWord()
                }
                let trimmedLeading = rawTok.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                let hasTrailingSpace = rawTok.last?.isWhitespace == true
                if !trimmedLeading.isEmpty {
                    if curStart == nil { curStart = seg.start }
                    curText += trimmedLeading
                    curEnd = max(curEnd, seg.end)
                }
                if hasTrailingSpace {
                    flushWord()
                }
            }
            flushWord()

            let plainText = mergedWords.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plainText.isEmpty else { continue }

            let lowerPlain = plainText.lowercased()
            if lowerPlain.contains("作词") || lowerPlain.contains("作曲") || lowerPlain.contains("编曲")
                || lowerPlain.contains("制作人") || lowerPlain.contains("tme")
                || lowerPlain.range(
                    of: #"\b(?:produced|written|composed|lyrics|arranged|mixed|mastered)\s+by\b"#,
                    options: .regularExpression
                ) != nil
                || (rawBuilt.count < 4 && (lowerPlain.hasPrefix("composer:") || lowerPlain.hasPrefix("lyricist:") || lowerPlain.hasPrefix("producer:"))) {
                continue
            }
            if rawBuilt.isEmpty, !normSongArtist.isEmpty, normalizeComparable(plainText) == normSongArtist {
                continue
            }

            rawBuilt.append((lineStart, max(lineEnd, mergedWords.last?.endTime ?? lineEnd), plainText, mergedWords))
        }

        var output: [SyncedLyricLine] = []
        for i in 0..<rawBuilt.count {
            let cur = rawBuilt[i]
            let nextStart = (i + 1 < rawBuilt.count) ? rawBuilt[i + 1].start : max(cur.end + 1.0, duration ?? (cur.end + 4.0))
            if i == 0 && cur.start > 5.0 {
                output.append(SyncedLyricLine(
                    startTime: 0.4,
                    endTime: max(1.0, cur.start - 0.35),
                    text: "",
                    words: [],
                    isInstrumentalBreak: true,
                    hasNativeWordTimings: false
                ))
            }
            let vocalGap = nextStart - cur.start
            let boundedEnd = vocalGap > 8.5 ? cur.end : min(cur.end, max(cur.start + 0.35, nextStart - 0.04))
            output.append(SyncedLyricLine(
                startTime: cur.start,
                endTime: boundedEnd,
                text: cur.text,
                words: cur.words,
                isInstrumentalBreak: false,
                hasNativeWordTimings: true
            ))
            if vocalGap > 8.5 && i + 1 < rawBuilt.count {
                let breakStart = cur.end + 0.3
                let breakEnd = max(breakStart + 1.0, nextStart - 0.35)
                if breakEnd > breakStart + 1.0 {
                    output.append(SyncedLyricLine(
                        startTime: breakStart,
                        endTime: breakEnd,
                        text: "",
                        words: [],
                        isInstrumentalBreak: true,
                        hasNativeWordTimings: false
                    ))
                }
            }
        }
        return output
    }

    // MARK: - Genius Clean Plain Lyrics Fallback

    private func fetchFromGenius(
        cacheKey: String,
        song: String,
        artist: String
    ) async -> ResolvedTrackLyrics? {
        await fetchGeniusTrackDetails(cacheKey: cacheKey, song: song, artist: artist)?.lyrics
    }

    private func fetchTopGeniusCandidates(
        cacheKey: String,
        song: String,
        artist: String,
        maxResults: Int = 2
    ) async -> [ResolvedTrackLyrics] {
        let querySong = Self.normalizeSmartPunctuation(song)
        let rawArtist = Self.normalizeSmartPunctuation(artist)
        let canonicalArtist = ArtistDatabase.canonicalizeSingle(rawArtist)
        let queryArtist = canonicalArtist.isEmpty ? rawArtist : canonicalArtist
        let coreSong = Self.extractCoreSongTitle(querySong)

        let combined = [queryArtist, querySong].filter { !$0.isEmpty }.joined(separator: " ")
        var hits = await findTopGeniusHits(
            query: combined,
            targetSong: querySong,
            coreSong: coreSong,
            targetArtist: queryArtist,
            maxResults: maxResults
        ).filter { $0.score >= 35 }

        if hits.isEmpty {
            let titleQuery = coreSong.isEmpty ? querySong : coreSong
            if !queryArtist.isEmpty, !titleQuery.isEmpty, titleQuery.lowercased() != combined.lowercased() {
                hits = await findTopGeniusHits(
                    query: titleQuery,
                    targetSong: querySong,
                    coreSong: coreSong,
                    targetArtist: queryArtist,
                    maxResults: maxResults
                ).filter { $0.score >= 42 }
            }
        }
        guard !hits.isEmpty else { return [] }

        return await withTaskGroup(of: ResolvedTrackLyrics?.self) { group in
            for hit in hits {
                group.addTask {
                    await self.loadGeniusPage(hit: hit, cacheKey: cacheKey)
                }
            }
            var out: [ResolvedTrackLyrics] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }
    }

    func fetchGeniusTrackDetails(
        cacheKey: String = "genius_lookup",
        song: String,
        artist: String
    ) async -> (title: String, artist: String, album: String?, lyrics: ResolvedTrackLyrics)? {
        let querySong = Self.normalizeSmartPunctuation(song)
        let rawArtist = Self.normalizeSmartPunctuation(artist)
        let canonicalArtist = ArtistDatabase.canonicalizeSingle(rawArtist)
        let queryArtist = canonicalArtist.isEmpty ? rawArtist : canonicalArtist
        let coreSong = Self.extractCoreSongTitle(querySong)

        let combined = [queryArtist, querySong].filter { !$0.isEmpty }.joined(separator: " ")
        if let primaryHit = await findBestGeniusHit(query: combined, targetSong: querySong, coreSong: coreSong, targetArtist: queryArtist),
           primaryHit.score >= 35 {
            if let loaded = await loadGeniusPageWithAlbum(hit: primaryHit, cacheKey: cacheKey) {
                return loaded
            }
        }

        // Obscure / YouTube-channel rescue query: search Genius by song title cleanly if combined query missed
        let titleQuery = coreSong.isEmpty ? querySong : coreSong
        if !queryArtist.isEmpty, !titleQuery.isEmpty, titleQuery.lowercased() != combined.lowercased(),
           let rescueHit = await findBestGeniusHit(query: titleQuery, targetSong: querySong, coreSong: coreSong, targetArtist: queryArtist),
           rescueHit.score >= 42 {
            if let loaded = await loadGeniusPageWithAlbum(hit: rescueHit, cacheKey: cacheKey) {
                return loaded
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
        await findTopGeniusHits(
            query: query,
            targetSong: targetSong,
            coreSong: coreSong,
            targetArtist: targetArtist,
            maxResults: 1
        ).first
    }

    private func findTopGeniusHits(
        query: String,
        targetSong: String,
        coreSong: String,
        targetArtist: String,
        maxResults: Int = 2
    ) async -> [(url: URL, title: String, artist: String, score: Int)] {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://genius.com/api/search/multi?q=\(encoded)&per_page=6") else {
            return []
        }

        var req = URLRequest(url: searchURL)
        req.timeoutInterval = 10
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = (json["response"] as? [String: Any])?["sections"] as? [[String: Any]] else {
            return []
        }

        var scoredHits: [(url: URL, title: String, artist: String, score: Int)] = []
        var seenURLs = Set<URL>()
        let normSong = Self.normalizeComparable(targetSong)
        let normCore = Self.normalizeComparable(coreSong)
        let normArtist = Self.normalizeComparable(targetArtist)
        let targetText = "\(targetSong) \(targetArtist)"

        for section in sections {
            let sType = (section["type"] as? String) ?? ""
            guard sType == "song" || sType == "top_hit",
                  let hits = section["hits"] as? [[String: Any]] else { continue }
            for hit in hits {
                guard (hit["type"] as? String) == "song",
                      let result = hit["result"] as? [String: Any],
                      let urlStr = result["url"] as? String,
                      let url = URL(string: urlStr),
                      seenURLs.insert(url).inserted else { continue }
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
                s += Self.versionCompatibilityScore(
                    targetText: targetText,
                    candidateText: "\(hTitle) \(hArtist)",
                    includeDurationScore: false
                )
                scoredHits.append((url, hTitle, hArtist, s))
            }
        }

        return Array(scoredHits.sorted { $0.score > $1.score }.prefix(maxResults))
    }

    private func loadGeniusPage(
        hit: (url: URL, title: String, artist: String, score: Int),
        cacheKey: String
    ) async -> ResolvedTrackLyrics? {
        await loadGeniusPageWithAlbum(hit: hit, cacheKey: cacheKey)?.lyrics
    }

    private func loadGeniusPageWithAlbum(
        hit: (url: URL, title: String, artist: String, score: Int),
        cacheKey: String
    ) async -> (title: String, artist: String, album: String?, lyrics: ResolvedTrackLyrics)? {
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

        let extractedAlbum: String? = {
            let patterns = [
                #"\\"(?:primaryAlbum|album)\\"\s*:\s*\{[^}]*\\"name\\"\s*:\s*\\"([^"\\]+)\\""#,
                #""(?:primaryAlbum|album)"\s*:\s*\{[^}]*"name"\s*:\s*"([^"]+)""#
            ]
            let fullRange = NSRange(location: 0, length: (html as NSString).length)
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat),
                   let m = regex.firstMatch(in: html, range: fullRange),
                   m.numberOfRanges > 1 {
                    let raw = (html as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty {
                        return Self.decodeHTMLEntities(raw)
                    }
                }
            }
            return nil
        }()

        let cleanTitle = hit.title.replacingOccurrences(of: #"\*+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = ArtistDatabase.canonicalizeSingle(hit.artist)

        let resolved = ResolvedTrackLyrics(
            cacheKey: cacheKey,
            trackTitle: cleanTitle.isEmpty ? hit.title : cleanTitle,
            artistName: cleanArtist.isEmpty ? hit.artist : cleanArtist,
            isTimeSynced: false,
            sourceLabel: "Plain Lyrics",
            attributionText: "Lyrics via Genius",
            syncedOffsetSeconds: 0,
            lines: parsed.lines
        )
        return (resolved.trackTitle, resolved.artistName, extractedAlbum, resolved)
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
                let hasNativeWords: Bool
                if let enhancedWordRegex,
                   let parsedEnhanced = parseEnhancedWords(
                       in: entry.rawBody,
                       lineStart: entry.time,
                       lineEnd: nextTime,
                       regex: enhancedWordRegex
                   ),
                   !parsedEnhanced.isEmpty {
                    wordTimings = parsedEnhanced
                    hasNativeWords = true
                } else {
                    wordTimings = synthesizeProportionalWordTimings(
                        text: cleanPlain,
                        lineStart: entry.time,
                        lineEnd: min(nextTime, entry.time + max(2.2, Double(cleanPlain.count) * 0.085))
                    )
                    hasNativeWords = false
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
                        isInstrumentalBreak: false,
                        hasNativeWordTimings: hasNativeWords
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

    nonisolated private static func normalizeSmartPunctuation(_ text: String) -> String {
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
            of: #"\s*[\(\[]\s*(?:slowed(?:\s*(?:\+|&|and)?\s*reverb)?|sped\s*up|speed\s*up|nightcore|reverb|bass\s*boosted|acoustic(?:\s*version)?|unplugged|live(?:\s*at\s*[^\)\]]*)?|remix|rework|vip|edit|version|radio\s*edit|clean|explicit|dirty|uncensored|demo|og|extended|alternate|alt\.?\s*version|v\d+|part\s*\w+|pt\.?\s*\w+|8d(?:\s*audio)?|cover)[^\)\]]*[\)\]]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"\s*[-–—]\s*(?:slowed(?:\s*(?:\+|&|and)?\s*reverb)?|sped\s*up|speed\s*up|nightcore|acoustic|unplugged|live|remix|radio\s*edit|clean|explicit|demo|extended)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static let versionTagRegexes: [(regex: NSRegularExpression, tag: String)] = {
        let specs: [(String, String)] = [
            (#"\b(?:clean(?:\s+version)?|edited\s+version)\b|(?:[\(\[\-–—]\s*edited\b)"#, "clean"),
            (#"\b(?:explicit|dirty|uncensored)\b"#, "explicit"),
            (#"\b(?:remix|rework|bootleg|flip)\b"#, "remix"),
            (#"\bvip\b"#, "vip"),
            (#"\b(?:radio\s+edit|studio\s+edit)\b|(?:[\(\[\-–—]\s*edit\b)"#, "edit"),
            (#"\blive\s+(?:at|in|from|version|session|performance|recording)\b|(?:[\(\[\-–—]\s*live\b)"#, "live"),
            (#"\b(?:acoustic|unplugged)\b"#, "acoustic"),
            (#"\bslowed\b"#, "slowed"),
            (#"\b(?:sped\s*up|speed\s*up|nightcore)\b"#, "sped_up"),
            (#"\b(?:instrumental|karaoke|8d(?:\s*audio)?)\b|伴奏"#, "instrumental"),
            (#"\bdemo\b"#, "demo"),
            (#"(?:[\(\[\-–—]\s*(?:og|original)\b)|\b(?:og\s+version|original\s+version)\b"#, "og"),
            (#"\bextended\b"#, "extended"),
            (#"\b(?:alternate|alt\.?\s+version)\b"#, "alternate"),
            (#"\bcover\s+version\b|(?:[\(\[\-–—]\s*cover\b)"#, "cover")
        ]
        return specs.compactMap { pattern, tag in
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (rx, tag)
        }
    }()

    private nonisolated static let numberedVersionRegex = try? NSRegularExpression(
        pattern: #"\bv(?:er(?:sion)?)?[\s._-]*([1-9])\b"#,
        options: [.caseInsensitive]
    )

    private nonisolated static let numberedPartRegex = try? NSRegularExpression(
        pattern: #"\b(?:part|pt\.?)[\s._-]*([1-9]|ii|iii|iv)\b"#,
        options: [.caseInsensitive]
    )

    /// Extracts canonical version tags (clean, explicit, remix, live, acoustic, slowed, sped_up, demo, v1/v2, pt2, etc.)
    /// so different editions/versions of the same song title never silently substitute for one another.
    nonisolated static func canonicalVersionGroups(in text: String) -> Set<String> {
        let normalized = normalizeSmartPunctuation(text).lowercased()
        guard !normalized.isEmpty else { return [] }
        let range = NSRange(normalized.startIndex..., in: normalized)
        var tags = Set<String>()

        for entry in versionTagRegexes {
            if entry.regex.firstMatch(in: normalized, options: [], range: range) != nil {
                tags.insert(entry.tag)
            }
        }
        if let numberedVersionRegex {
            for match in numberedVersionRegex.matches(in: normalized, options: [], range: range) {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: normalized) {
                    tags.insert("v\(normalized[r])")
                }
            }
        }
        if let numberedPartRegex {
            for match in numberedPartRegex.matches(in: normalized, options: [], range: range) {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: normalized) {
                    let raw = String(normalized[r])
                    let mapped: String
                    switch raw {
                    case "ii": mapped = "2"
                    case "iii": mapped = "3"
                    case "iv": mapped = "4"
                    default: mapped = raw
                    }
                    tags.insert("pt\(mapped)")
                }
            }
        }
        return tags
    }

    /// Computes bidirectional version & duration compatibility between the target track metadata and a lyric candidate.
    nonisolated static func versionCompatibilityScore(
        targetText: String,
        candidateText: String,
        targetDuration: Double? = nil,
        candidateDuration: Double? = nil,
        includeDurationScore: Bool = true
    ) -> Int {
        let targetTags = canonicalVersionGroups(in: targetText)
        let candTags = canonicalVersionGroups(in: candidateText)
        var score = 0

        if (targetTags.contains("clean") && candTags.contains("explicit")) ||
            (targetTags.contains("explicit") && candTags.contains("clean")) {
            score -= 75
        }

        let matched = targetTags.intersection(candTags)
        score += min(60, matched.count * 35)

        // Penalize alternate version tags present on the candidate that the target track doesn't have
        // (normal unmarked tracks allow `[Explicit]` metadata on album entries).
        for tag in candTags where !targetTags.contains(tag) {
            if tag == "explicit" && !targetTags.contains("clean") { continue }
            score -= 55
        }

        // Penalize missing required version modifiers when the target track specifically asks for one.
        for tag in targetTags where !candTags.contains(tag) {
            if tag == "explicit" && !candTags.contains("clean") { continue }
            score -= 50
        }

        if includeDurationScore, let targetDuration, let candidateDuration, targetDuration > 5, candidateDuration > 5 {
            let diff = abs(targetDuration - candidateDuration)
            if diff <= 3.0 {
                score += 35
            } else if diff <= 7.0 {
                score += 18
            } else if diff > 22.0 {
                score -= 60
            } else if diff > 12.0 {
                score -= 35
            }
        }

        return score
    }

    nonisolated private static func normalizeComparable(_ text: String) -> String {
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
            let cleaned = snippet
                .replacingOccurrences(of: #"(?im)^\s*\d+\s+Contributors?.*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?im)^\s*\[(?:intro|verse|chorus|pre-?chorus|post-?chorus|bridge|outro|hook|refrain|interlude|skit|instrumental|break|part\s+\w+)[^\]]*\]\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
