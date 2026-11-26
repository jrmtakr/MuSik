import AVFoundation
import Foundation
@preconcurrency import Speech

struct SpokenLyricWord: Hashable, Sendable {
    let rawWord: String
    let normalized: String
    let songTime: Double
    let confidence: Float
}

struct LiveLyricsSyncOutcome: Sendable {
    let identifiedTitle: String?
    let identifiedArtist: String?
    let identifiedAlbum: String?
    let identifiedGenre: String?
    let isHighConfidence: Bool
    let transcriptSnippet: String
    let alignedLyrics: ResolvedTrackLyrics?
    let computedOffsetSeconds: Double?
    let alignedLineText: String?
    let statusMessage: String
    let errorMessage: String?

    init(
        identifiedTitle: String?,
        identifiedArtist: String?,
        identifiedAlbum: String? = nil,
        identifiedGenre: String?,
        isHighConfidence: Bool,
        transcriptSnippet: String,
        alignedLyrics: ResolvedTrackLyrics?,
        computedOffsetSeconds: Double?,
        alignedLineText: String?,
        statusMessage: String,
        errorMessage: String?
    ) {
        self.identifiedTitle = identifiedTitle
        self.identifiedArtist = identifiedArtist
        self.identifiedAlbum = identifiedAlbum
        self.identifiedGenre = identifiedGenre
        self.isHighConfidence = isHighConfidence
        self.transcriptSnippet = transcriptSnippet
        self.alignedLyrics = alignedLyrics
        self.computedOffsetSeconds = computedOffsetSeconds
        self.alignedLineText = alignedLineText
        self.statusMessage = statusMessage
        self.errorMessage = errorMessage
    }
}

private struct RecognizedLyricsCandidate {
    let trackName: String
    let artistName: String
    let genre: String?
    let durationSeconds: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
    let source: String
    let isInCatalog: Bool
    let textOverlapCount: Int
    let score: Int
}

private struct AlignmentAnchor {
    let lineIndex: Int
    let lineText: String
    let matchedCount: Int
    let score: Double
    let offsetSeconds: Double
}

private final class SpeechCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var latestSegments: [SpokenLyricWord] = []
    private var latestTranscript = ""

    func update(transcript: String, words: [SpokenLyricWord]) {
        lock.lock()
        if !words.isEmpty {
            latestSegments = words
            latestTranscript = transcript
        }
        lock.unlock()
    }

    func finishOnce() -> (transcript: String, words: [SpokenLyricWord])? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        finished = true
        return (latestTranscript, latestSegments)
    }
}

enum LiveAudioLyricsAI {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "from", "are",
        "was", "but", "not", "all", "can", "had", "her", "him", "his", "she", "our"
    ]

    static func recognizeAndAlign(
        item: MediaItem,
        cacheKey: String,
        playbackTime: Double,
        currentLyrics: ResolvedTrackLyrics?,
        equalizerPlayer: EqualizerAudioPlayer,
        isEQPlaying: Bool,
        playbackRate: Float,
        forceReidentify: Bool = false,
        onProgress: @escaping @MainActor (String) -> Void
    ) async -> LiveLyricsSyncOutcome {
        let isLocalPlayableFile = !item.relativePath.hasPrefix("__remote__/")
            && !item.isHLS
            && FileManager.default.fileExists(atPath: item.fileURL.path)

        let authStatus = await requestSpeechPermission()
        let recognizer = (authStatus == .authorized)
            ? (SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")))
            : nil

        // 1. Listen across the ENTIRE song or music video (not a single 18s clip that can fail in 1s).
        var fullHeard: [HeardWord] = []
        var heardWords: [SpokenLyricWord] = []

        if isLocalPlayableFile {
            if let recognizer, recognizer.isAvailable {
                await onProgress("AI listening to full track...")
                let listened = await SongAudioListener.listen(to: item.fileURL, maxSeconds: 15 * 60) { chunkIdx, totalChunks, totalSeconds in
                    Task { @MainActor in
                        let mins = Int(totalSeconds) / 60
                        let secs = Int(totalSeconds) % 60
                        onProgress("AI listening across full song (\(chunkIdx)/\(totalChunks) • \(mins):\(String(format: "%02d", secs)))...")
                    }
                }
                if let listened, !listened.isEmpty {
                    fullHeard = listened
                    heardWords = listened.map {
                        SpokenLyricWord(
                            rawWord: $0.token,
                            normalized: normalizeWord($0.token),
                            songTime: $0.time,
                            confidence: 1.0
                        )
                    }.filter { !$0.normalized.isEmpty }
                }
            }

            // Fallback live tap if file Speech failed while EQ audio happens to be playing
            if heardWords.count < 3, isEQPlaying, let recognizer, recognizer.isAvailable {
                await onProgress("Sampling playing audio tap...")
                let tapCapture = await captureLiveAudioTapWords(
                    playbackTime: playbackTime,
                    recognizer: recognizer,
                    equalizerPlayer: equalizerPlayer,
                    playbackRate: playbackRate
                )
                if tapCapture.words.count > heardWords.count {
                    heardWords = tapCapture.words
                    fullHeard = tapCapture.words.map { HeardWord(token: $0.normalized, time: $0.songTime) }
                }
            }
        } else if let recognizer, recognizer.isAvailable {
            await onProgress("Listening to playing stream...")
            let capture = await captureSpokenWords(
                item: item,
                playbackTime: playbackTime,
                recognizer: recognizer,
                equalizerPlayer: equalizerPlayer,
                isEQPlaying: isEQPlaying,
                playbackRate: playbackRate
            )
            heardWords = capture.words
            fullHeard = capture.words.map { HeardWord(token: $0.normalized, time: $0.songTime) }
        }

        if Task.isCancelled {
            return LiveLyricsSyncOutcome(
                identifiedTitle: nil,
                identifiedArtist: nil,
                identifiedGenre: nil,
                isHighConfidence: false,
                transcriptSnippet: "",
                alignedLyrics: nil,
                computedOffsetSeconds: nil,
                alignedLineText: nil,
                statusMessage: "Cancelled",
                errorMessage: nil
            )
        }

        let cleanSnippet = heardWords.prefix(16).map(\.rawWord).joined(separator: " ")

        // 2. Check existing lyrics if not forcing full re-identification (supports both spoken + acoustic alignment).
        if !forceReidentify,
           let currentLyrics,
           !currentLyrics.lines.isEmpty {
            let verdict = SongAudioListener.verdict(heard: fullHeard, lyrics: currentLyrics)
            let isContradicted: Bool = {
                if case .contradicted = verdict { return true }
                return false
            }()

            if !isContradicted {
                await onProgress("Lining lyrics up across whole song...")
                let aligned: ResolvedTrackLyrics
                if isLocalPlayableFile {
                    aligned = await SongAudioListener.autoAlign(
                        lyrics: currentLyrics,
                        heard: fullHeard.isEmpty ? nil : fullHeard,
                        fileURL: item.fileURL
                    )
                } else {
                    var copy = currentLyrics
                    if let anchor = computeBestOffsetAnchor(
                        heardWords: heardWords,
                        in: currentLyrics.lines,
                        tempoScale: currentLyrics.tempoScale
                    ) {
                        copy.syncedOffsetSeconds = anchor.offsetSeconds
                    }
                    aligned = copy
                }

                let anchor = heardWords.isEmpty ? nil : computeBestOffsetAnchor(
                    heardWords: heardWords,
                    in: aligned.lines,
                    tempoScale: 1.0
                )
                let canonicalArtist = ArtistDatabase.canonicalizeSingle(currentLyrics.artistName)
                let genre = ArtistDatabase.genre(forArtist: canonicalArtist)
                let isStrongCatalogArtist = ArtistDatabase.lookup(canonicalArtist) != nil
                let isConfirmed = !isContradicted && (
                    {
                        if case .confirmed = verdict { return true }
                        return false
                    }() || (anchor?.matchedCount ?? 0) >= 3
                )
                let summaryNote: String = {
                    if let attr = aligned.attributionText, attr.contains("aligned") {
                        return "AI Synced across song (\(aligned.lines.count) lines)"
                    }
                    if let anchor {
                        let signStr = String(format: "%+.1fs", anchor.offsetSeconds)
                        return "AI Synced (\(signStr)) to \"\(anchor.lineText)\""
                    }
                    return "AI Synced \(aligned.lines.count) lyric lines"
                }()

                return LiveLyricsSyncOutcome(
                    identifiedTitle: currentLyrics.trackTitle,
                    identifiedArtist: canonicalArtist.isEmpty ? currentLyrics.artistName : canonicalArtist,
                    identifiedGenre: genre,
                    isHighConfidence: isConfirmed && !canonicalArtist.isEmpty && isStrongCatalogArtist,
                    transcriptSnippet: cleanSnippet,
                    alignedLyrics: aligned,
                    computedOffsetSeconds: anchor?.offsetSeconds,
                    alignedLineText: anchor?.lineText,
                    statusMessage: summaryNote,
                    errorMessage: nil
                )
            }
        }

        // 3. Identify song across whole song via Lyrics AI + Custom Shazam Acoustic Fingerprint AI (works even if Speech missed words).
        await onProgress("Identifying song & matching lyrics across track...")

        var shazamMatch: IdentifiedSong?
        if isLocalPlayableFile {
            let cleanArtistHint = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shazamOutcome = await ShazamFingerprintEngine.shared.recognize(
                fileURL: item.fileURL,
                durationHint: item.durationSeconds,
                seedHintTitle: item.displayTitle,
                seedHintArtist: cleanArtistHint,
                heardWords: fullHeard.isEmpty ? nil : fullHeard
            )
            if case .match(let hit) = shazamOutcome {
                shazamMatch = hit
            }
        }

        var recognized: RecognizedLyricsCandidate?
        if heardWords.count >= 3 {
            recognized = await identifyBestSong(
                heardWords: heardWords,
                duration: item.durationSeconds,
                rawTitleHint: shazamMatch?.title ?? item.displayTitle,
                rawArtistHint: shazamMatch?.artist ?? item.artist
            )
        }

        // If Shazam matched acoustically (e.g. heavy beat, autotune, or non-English video), fetch official lyrics for the Shazam track.
        var candidateLyrics: ResolvedTrackLyrics?
        var resolvedTitle = recognized?.trackName ?? shazamMatch?.title ?? item.displayTitle
        var resolvedArtist = recognized?.artistName ?? shazamMatch?.artist ?? (item.artist ?? "")
        let resolvedAlbum = shazamMatch?.album
        var resolvedGenre = recognized?.genre ?? shazamMatch?.genre

        if let synced = recognized?.syncedLyrics,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = SyncedLyricsService.parseLRCOrPlain(text: synced, duration: item.durationSeconds ?? recognized?.durationSeconds)
            if !parsed.lines.isEmpty {
                candidateLyrics = ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: resolvedTitle,
                    artistName: resolvedArtist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: "AI Matched Synced",
                    attributionText: "AI full-song match • \(recognized?.source ?? "LRCLIB")",
                    syncedOffsetSeconds: 0,
                    tempoScale: 1.0,
                    expectedDurationSeconds: recognized?.durationSeconds,
                    lines: parsed.lines
                )
            }
        }

        if candidateLyrics == nil || !(candidateLyrics?.isTimeSynced ?? false),
           let shazam = shazamMatch {
            let shazamLyrics = await SyncedLyricsService.shared.fetchOfficialLyricsCandidate(
                cacheKey: cacheKey,
                song: shazam.title,
                artist: shazam.artist,
                duration: item.durationSeconds ?? shazam.durationSeconds
            )
            if let shazamLyrics, shazamLyrics.isTimeSynced || candidateLyrics == nil {
                candidateLyrics = shazamLyrics
                resolvedTitle = shazam.title
                resolvedArtist = shazam.artist
                resolvedGenre = shazam.genre ?? resolvedGenre
            }
        }

        if candidateLyrics == nil,
           let plain = recognized?.plainLyrics,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = SyncedLyricsService.parseLRCOrPlain(text: plain, duration: item.durationSeconds ?? recognized?.durationSeconds)
            if !parsed.lines.isEmpty {
                candidateLyrics = ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: resolvedTitle,
                    artistName: resolvedArtist,
                    isTimeSynced: false,
                    sourceLabel: "AI Matched Lyrics",
                    attributionText: "AI full-song match • \(recognized?.source ?? "Genius")",
                    syncedOffsetSeconds: 0,
                    tempoScale: 1.0,
                    expectedDurationSeconds: recognized?.durationSeconds,
                    lines: parsed.lines
                )
            }
        }

        // Last lyrics source: YouTube Creator Timed Captions (already video-timeline aligned for music videos!).
        if candidateLyrics == nil {
            let ytLyrics = await SyncedLyricsService.shared.fetchFromYouTubeCreatorSubtitles(
                item: item,
                cacheKey: cacheKey,
                song: resolvedTitle,
                artist: resolvedArtist
            )
            if let ytLyrics {
                candidateLyrics = ytLyrics
            }
        }

        if let rawLyrics = candidateLyrics, !rawLyrics.lines.isEmpty {
            await onProgress("Aligning lyrics piecewise to song audio...")
            let aligned: ResolvedTrackLyrics
            if isLocalPlayableFile {
                aligned = await SongAudioListener.autoAlign(
                    lyrics: rawLyrics,
                    heard: fullHeard.isEmpty ? nil : fullHeard,
                    fileURL: item.fileURL
                )
            } else {
                var copy = rawLyrics
                if let anchor = computeBestOffsetAnchor(
                    heardWords: heardWords,
                    in: rawLyrics.lines,
                    tempoScale: 1.0
                ) {
                    copy.syncedOffsetSeconds = anchor.offsetSeconds
                }
                aligned = copy
            }

            let highConfidence = (recognized?.textOverlapCount ?? 0) >= 3 && (recognized?.score ?? 0) >= 70
                || shazamMatch != nil
            let anchor = heardWords.isEmpty ? nil : computeBestOffsetAnchor(
                heardWords: heardWords,
                in: aligned.lines,
                tempoScale: 1.0
            )
            let methodTag = shazamMatch != nil ? "Shazam AI + Whole-Song Audio" : "Whole-Song AI"
            return LiveLyricsSyncOutcome(
                identifiedTitle: resolvedTitle,
                identifiedArtist: resolvedArtist,
                identifiedAlbum: resolvedAlbum,
                identifiedGenre: resolvedGenre,
                isHighConfidence: highConfidence,
                transcriptSnippet: cleanSnippet,
                alignedLyrics: aligned,
                computedOffsetSeconds: anchor?.offsetSeconds,
                alignedLineText: anchor?.lineText,
                statusMessage: "Synced \"\(resolvedTitle)\" by \(resolvedArtist) (\(methodTag))",
                errorMessage: nil
            )
        }

        // If Shazam at least identified the song metadata even with no LRCLIB entry, return metadata cleanly
        if let shazamMatch {
            return LiveLyricsSyncOutcome(
                identifiedTitle: shazamMatch.title,
                identifiedArtist: shazamMatch.artist,
                identifiedAlbum: shazamMatch.album,
                identifiedGenre: shazamMatch.genre,
                isHighConfidence: true,
                transcriptSnippet: cleanSnippet,
                alignedLyrics: nil,
                computedOffsetSeconds: nil,
                alignedLineText: nil,
                statusMessage: "Identified \"\(shazamMatch.title)\" by \(shazamMatch.artist) (no lyrics found online)",
                errorMessage: nil
            )
        }

        let noMatchReason: String
        if authStatus != .authorized && isLocalPlayableFile {
            noMatchReason = "Enable Speech Recognition in Settings -> MuseJRM, or let Shazam AI analyze when online."
        } else if heardWords.count < 3 {
            noMatchReason = "No clear vocals or Shazam match detected across the audio track."
        } else {
            noMatchReason = "Heard \"\(cleanSnippet)\" — couldn't find matching lyrics online."
        }

        return LiveLyricsSyncOutcome(
            identifiedTitle: nil,
            identifiedArtist: nil,
            identifiedGenre: nil,
            isHighConfidence: false,
            transcriptSnippet: cleanSnippet,
            alignedLyrics: nil,
            computedOffsetSeconds: nil,
            alignedLineText: nil,
            statusMessage: "Couldn't match lyrics automatically",
            errorMessage: noMatchReason
        )
    }

    static func capturePlaybackTranscript(
        for item: MediaItem,
        playbackTime: Double,
        equalizerPlayer: EqualizerAudioPlayer,
        isEQPlaying: Bool,
        playbackRate: Float
    ) async -> (transcript: String, errorMessage: String?) {
        let authStatus = await requestSpeechPermission()
        guard authStatus == .authorized else {
            return ("", "Enable Speech Recognition in iPhone Settings -> MuseJRM -> Speech Recognition.")
        }
        let recognizer = SFSpeechRecognizer(locale: .current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            return ("", "On-device Speech Recognition is currently unavailable.")
        }

        var capture = await captureSpokenWords(
            item: item,
            playbackTime: playbackTime,
            recognizer: recognizer,
            equalizerPlayer: equalizerPlayer,
            isEQPlaying: isEQPlaying,
            playbackRate: playbackRate
        )

        let totalDur = item.durationSeconds ?? 0
        if capture.words.count < 4, playbackTime < 12.0, totalDur > 36.0 {
            let fallbackStart = min(max(18.0, totalDur * 0.28), max(18.0, totalDur - 20.0))
            let secondTry = await captureAudioClipWords(
                at: item.fileURL,
                clipStart: fallbackStart,
                clipDuration: min(20.0, max(6.0, totalDur - fallbackStart)),
                recognizer: recognizer
            )
            if secondTry.words.count > capture.words.count {
                capture = secondTry
            }
        }

        let words = capture.words.prefix(16).map(\.rawWord).joined(separator: " ")
        guard capture.words.count >= 3 else {
            return ("", "Couldn't catch clear vocals around this position. Scrub to singing and retry.")
        }
        return (words, nil)
    }

    // MARK: - Audio Clip & Live Graph Capture

    private static func captureSpokenWords(
        item: MediaItem,
        playbackTime: Double,
        recognizer: SFSpeechRecognizer,
        equalizerPlayer: EqualizerAudioPlayer,
        isEQPlaying: Bool,
        playbackRate: Float
    ) async -> (transcript: String, words: [SpokenLyricWord]) {
        if !item.relativePath.hasPrefix("__remote__/") && FileManager.default.fileExists(atPath: item.fileURL.path) {
            let totalDur = item.durationSeconds ?? 0
            let clipStart: Double = {
                if playbackTime >= 4.0 {
                    return max(0, playbackTime - 3.5)
                }
                if totalDur > 26.0 {
                    return min(6.0, totalDur * 0.1)
                }
                return 0
            }()
            let clipDur = totalDur > 0 ? min(18.0, max(5.0, totalDur - clipStart)) : 18.0

            let assetResult = await captureAudioClipWords(
                at: item.fileURL,
                clipStart: clipStart,
                clipDuration: clipDur,
                recognizer: recognizer
            )
            if !assetResult.words.isEmpty {
                return assetResult
            }
        }

        if isEQPlaying {
            return await captureLiveAudioTapWords(
                startPlaybackTime: playbackTime,
                playbackRate: playbackRate,
                equalizerPlayer: equalizerPlayer,
                recognizer: recognizer
            )
        }

        return ("", [])
    }

    private static func captureAudioClipWords(
        at url: URL,
        clipStart: Double,
        clipDuration: Double,
        recognizer: SFSpeechRecognizer
    ) async -> (transcript: String, words: [SpokenLyricWord]) {
        let asset = AVURLAsset(url: url)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { return ("", []) }

        let tempClipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai_lyrics_clip_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempClipURL) }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return ("", [])
        }
        exportSession.outputURL = tempClipURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, clipStart), preferredTimescale: 600),
            duration: CMTime(seconds: max(3.0, clipDuration), preferredTimescale: 600)
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exportSession.exportAsynchronously {
                cont.resume()
            }
        }

        guard exportSession.status == .completed, FileManager.default.fileExists(atPath: tempClipURL.path) else {
            return ("", [])
        }

        let request = SFSpeechURLRecognitionRequest(url: tempClipURL)
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false
        }

        return await runRecognition(
            request: request,
            recognizer: recognizer,
            clipStart: clipStart,
            timeRate: 1.0,
            timeoutSeconds: 11.0
        )
    }

    private static func captureLiveAudioTapWords(
        startPlaybackTime: Double,
        playbackRate: Float,
        equalizerPlayer: EqualizerAudioPlayer,
        recognizer: SFSpeechRecognizer
    ) async -> (transcript: String, words: [SpokenLyricWord]) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false
        }

        equalizerPlayer.installAudioCaptureTap { buffer, _ in
            request.append(buffer)
        }
        defer {
            equalizerPlayer.removeAudioCaptureTap()
            request.endAudio()
        }

        return await runRecognition(
            request: request,
            recognizer: recognizer,
            clipStart: startPlaybackTime,
            timeRate: Double(max(0.25, playbackRate)),
            timeoutSeconds: 8.5,
            endAudioAction: { request.endAudio() }
        )
    }

    private static func runRecognition(
        request: SFSpeechRecognitionRequest,
        recognizer: SFSpeechRecognizer,
        clipStart: Double,
        timeRate: Double,
        timeoutSeconds: Double,
        endAudioAction: (() -> Void)? = nil
    ) async -> (transcript: String, words: [SpokenLyricWord]) {
        let collector = SpeechCollectorBox()

        return await withCheckedContinuation { cont in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let segments = result.bestTranscription.segments.compactMap { seg -> SpokenLyricWord? in
                        let clean = normalizeWord(seg.substring)
                        guard !clean.isEmpty else { return nil }
                        return SpokenLyricWord(
                            rawWord: seg.substring,
                            normalized: clean,
                            songTime: clipStart + seg.timestamp * timeRate,
                            confidence: seg.confidence
                        )
                    }
                    collector.update(
                        transcript: result.bestTranscription.formattedString,
                        words: segments
                    )
                    if result.isFinal {
                        if let out = collector.finishOnce() {
                            cont.resume(returning: out)
                        }
                    }
                } else if error != nil {
                    if let out = collector.finishOnce() {
                        cont.resume(returning: out)
                    }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                endAudioAction?()
                task.finish()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if let out = collector.finishOnce() {
                        task.cancel()
                        cont.resume(returning: out)
                    }
                }
            }
        }
    }

    // MARK: - Song Identification from Sung Transcript

    private static func identifyBestSong(
        heardWords: [SpokenLyricWord],
        duration: Double?,
        rawTitleHint: String?,
        rawArtistHint: String?
    ) async -> RecognizedLyricsCandidate? {
        let meaningful = heardWords.filter { $0.normalized.count >= 2 }
        let sourceWords = meaningful.count >= 4 ? meaningful : heardWords
        guard sourceWords.count >= 3 else { return nil }

        // Build distinctive phrases distributed across the whole song (skips intro dialogue/skits in music videos).
        var queries: [String] = []
        if sourceWords.count >= 24 {
            let anchors = [sourceWords.count / 5, sourceWords.count / 2, (sourceWords.count * 4) / 5]
            for start in anchors {
                let slice = sourceWords[start..<min(sourceWords.count, start + 10)]
                let phrase = slice.map(\.rawWord).joined(separator: " ")
                if !phrase.isEmpty && !queries.contains(phrase) {
                    queries.append(phrase)
                }
            }
        }
        if queries.isEmpty {
            let phraseA = sourceWords.prefix(12).map(\.rawWord).joined(separator: " ")
            queries.append(phraseA)
        }

        async let geniusTask = searchGeniusByLyrics(queries: queries)
        async let lrclibTask = searchLRCLIBByTranscript(queries: queries)

        let geniusHits = await geniusTask
        var lrclibCandidates = await lrclibTask

        // For top Genius lyric matches, fetch their LRCLIB synced `.lrc` entries directly.
        for gHit in geniusHits.prefix(3) {
            let fetched = await fetchLRCLIBForSong(
                title: gHit.title,
                artist: gHit.artist,
                heardWords: heardWords,
                duration: duration,
                source: "Genius + LRCLIB"
            )
            lrclibCandidates.append(contentsOf: fetched)
        }

        // Cross-check the top identified song name against iTunes/Apple Music catalog for canonical artist, title & genre.
        let topSeed = lrclibCandidates.max(by: { $0.score < $1.score })
        let itunesTitle = topSeed?.trackName ?? geniusHits.first?.title ?? ""
        let itunesArtist = topSeed?.artistName ?? geniusHits.first?.artist ?? ""
        let itunesMatch = await fetchITunesVerification(title: itunesTitle, artist: itunesArtist, localDuration: duration)

        let cleanTitle = (rawTitleHint ?? "").lowercased()
        let cleanArtist = (rawArtistHint ?? "").lowercased()

        let rescored = lrclibCandidates.map { cand -> RecognizedLyricsCandidate in
            var s = cand.score
            var finalTitle = cand.trackName
            var finalArtist = cand.artistName
            var resolvedGenre = cand.genre

            if cand.isInCatalog {
                s += 18
            }

            if let dur = cand.durationSeconds, let localDur = duration, localDur > 10 {
                let diff = abs(localDur - dur)
                if diff <= 4.0 { s += 28 }
                else if diff <= 12.0 { s += 14 }
                else if diff > 35.0 { s -= 15 }
            }

            if let itunes = itunesMatch {
                let normCandA = ArtistDatabase.normalizeLookupKey(finalArtist)
                let normItunesA = ArtistDatabase.normalizeLookupKey(itunes.artistName)
                let normCandT = ArtistDatabase.normalizeLookupKey(finalTitle)
                let normItunesT = ArtistDatabase.normalizeLookupKey(itunes.trackName)
                if !normItunesA.isEmpty && !normItunesT.isEmpty &&
                    (normCandA == normItunesA || normCandA.contains(normItunesA) || normItunesA.contains(normCandA)) &&
                    (normCandT == normItunesT || normCandT.contains(normItunesT) || normItunesT.contains(normCandT)) {
                    s += 25
                    finalTitle = itunes.trackName
                    finalArtist = ArtistDatabase.canonicalizeSingle(itunes.artistName)
                    if let g = itunes.genre, !g.isEmpty {
                        resolvedGenre = g
                    }
                }
            }

            if !cleanTitle.isEmpty && finalTitle.lowercased().contains(cleanTitle) {
                s += 10
            }
            if !cleanArtist.isEmpty && finalArtist.lowercased().contains(cleanArtist) {
                s += 10
            }

            return RecognizedLyricsCandidate(
                trackName: finalTitle,
                artistName: finalArtist,
                genre: resolvedGenre ?? ArtistDatabase.genre(forArtist: finalArtist),
                durationSeconds: cand.durationSeconds,
                syncedLyrics: cand.syncedLyrics,
                plainLyrics: cand.plainLyrics,
                source: itunesMatch != nil ? "\(cand.source) + Apple Catalog" : cand.source,
                isInCatalog: cand.isInCatalog || ArtistDatabase.lookup(finalArtist) != nil,
                textOverlapCount: cand.textOverlapCount,
                score: s
            )
        }

        if let bestLRCLIB = rescored.max(by: { $0.score < $1.score }),
           bestLRCLIB.textOverlapCount >= 2 || bestLRCLIB.score >= 45 {
            return bestLRCLIB
        }

        // Fallback: fetch Genius plain lyrics for top Genius lyric hit if LRCLIB had no entry at all
        if let topGenius = geniusHits.first {
            if let plain = await fetchGeniusPlainLyrics(url: topGenius.url) {
                let extracted = ArtistDatabase.extractArtists(rawArtistTag: topGenius.artist, rawTitle: topGenius.title, isArtistVerified: true)
                let canonicalArtist = ArtistDatabase.canonicalizeSingle(extracted.primaryArtist.isEmpty ? topGenius.artist : extracted.primaryArtist)
                return RecognizedLyricsCandidate(
                    trackName: itunesMatch?.trackName ?? topGenius.title,
                    artistName: itunesMatch?.artistName ?? canonicalArtist,
                    genre: itunesMatch?.genre ?? ArtistDatabase.genre(forArtist: canonicalArtist) ?? extracted.genre,
                    durationSeconds: duration ?? itunesMatch?.durationSeconds,
                    syncedLyrics: nil,
                    plainLyrics: plain,
                    source: "Genius",
                    isInCatalog: ArtistDatabase.lookup(canonicalArtist) != nil,
                    textOverlapCount: 3,
                    score: 50
                )
            }
        }

        return nil
    }

    private static func fetchITunesVerification(
        title: String,
        artist: String,
        localDuration: Double?
    ) async -> (trackName: String, artistName: String, genre: String?, durationSeconds: Double?)? {
        let query = [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=5&term=\(encoded)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["results"] as? [[String: Any]], !rows.isEmpty else {
            return nil
        }

        let normTitle = ArtistDatabase.normalizeLookupKey(title)
        let normArtist = ArtistDatabase.normalizeLookupKey(artist)

        let best = rows.max { lhs, rhs in
            let lT = ArtistDatabase.normalizeLookupKey((lhs["trackName"] as? String) ?? "")
            let rT = ArtistDatabase.normalizeLookupKey((rhs["trackName"] as? String) ?? "")
            let lA = ArtistDatabase.normalizeLookupKey((lhs["artistName"] as? String) ?? "")
            let rA = ArtistDatabase.normalizeLookupKey((rhs["artistName"] as? String) ?? "")

            var lScore = (lT == normTitle ? 20 : 0) + (lA.contains(normArtist) ? 15 : 0)
            var rScore = (rT == normTitle ? 20 : 0) + (rA.contains(normArtist) ? 15 : 0)
            if let localDuration, localDuration > 10 {
                if let lm = (lhs["trackTimeMillis"] as? Double).map({ $0 / 1000 }), abs(lm - localDuration) <= 5 { lScore += 15 }
                if let rm = (rhs["trackTimeMillis"] as? Double).map({ $0 / 1000 }), abs(rm - localDuration) <= 5 { rScore += 15 }
            }
            return lScore < rScore
        }

        guard let best,
              let track = best["trackName"] as? String,
              let rawArt = best["artistName"] as? String else {
            return nil
        }
        let canonical = ArtistDatabase.canonicalizeSingle(rawArt)
        let genre = best["primaryGenreName"] as? String
        let dur = (best["trackTimeMillis"] as? Double).map { $0 / 1000.0 }
        return (track, canonical, genre, dur)
    }

    private static func searchGeniusByLyrics(queries: [String]) async -> [(title: String, artist: String, url: URL)] {
        var out: [(title: String, artist: String, url: URL)] = []
        var seen = Set<String>()

        for q in queries {
            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://genius.com/api/search/multi?q=\(encoded)&per_page=6") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sections = (json["response"] as? [String: Any])?["sections"] as? [[String: Any]] else { continue }

            // Prioritize `lyric` sections first with strict weak ordering
            let sortedSections = sections.sorted { lhs, rhs in
                let lhsIsLyric = ((lhs["type"] as? String) ?? "") == "lyric"
                let rhsIsLyric = ((rhs["type"] as? String) ?? "") == "lyric"
                return lhsIsLyric && !rhsIsLyric
            }

            for section in sortedSections {
                let sType = (section["type"] as? String) ?? ""
                guard sType == "lyric" || sType == "top_hit" || sType == "song",
                      let hits = section["hits"] as? [[String: Any]] else { continue }
                for hit in hits {
                    guard let res = hit["result"] as? [String: Any],
                          let title = res["title"] as? String,
                          let primary = res["primary_artist"] as? [String: Any],
                          let artist = primary["name"] as? String,
                          let urlStr = res["url"] as? String,
                          let songURL = URL(string: urlStr) else { continue }
                    let lowerArtist = artist.lowercased()
                    if lowerArtist.contains("genius ") || lowerArtist.contains("romanization") || lowerArtist.contains("translation") {
                        continue
                    }
                    let dedup = "\(artist.lowercased())|\(title.lowercased())"
                    if seen.insert(dedup).inserted {
                        out.append((title, artist, songURL))
                    }
                }
            }
        }
        return out
    }

    private static func searchLRCLIBByTranscript(queries: [String]) async -> [RecognizedLyricsCandidate] {
        var candidates: [RecognizedLyricsCandidate] = []
        for q in queries {
            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://lrclib.net/api/search?q=\(encoded)") else { continue }
            let rows = await fetchLRCLIBArray(url: url)
            for row in rows {
                if let cand = buildCandidate(from: row, heardWords: [], source: "LRCLIB Lyrics Search", overrideWordsCheck: q) {
                    candidates.append(cand)
                }
            }
        }
        return candidates
    }

    private static func fetchLRCLIBForSong(
        title: String,
        artist: String,
        heardWords: [SpokenLyricWord],
        duration: Double?,
        source: String
    ) async -> [RecognizedLyricsCandidate] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps?.url else { return [] }
        let rows = await fetchLRCLIBArray(url: url)
        return rows.compactMap { row in
            buildCandidate(from: row, heardWords: heardWords, source: source, overrideWordsCheck: nil)
        }
    }

    private static func fetchLRCLIBArray(url: URL) async -> [[String: Any]] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MuseJRM/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Array(rows.prefix(10))
    }

    private static func buildCandidate(
        from row: [String: Any],
        heardWords: [SpokenLyricWord],
        source: String,
        overrideWordsCheck: String?
    ) -> RecognizedLyricsCandidate? {
        guard let track = row["trackName"] as? String,
              let artist = row["artistName"] as? String else { return nil }
        let dur = row["duration"] as? Double
        let synced = row["syncedLyrics"] as? String
        let plain = row["plainLyrics"] as? String
        let lyricBody = (synced?.isEmpty == false ? synced : plain) ?? ""
        guard !lyricBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let bodyTokens = Set(normalizeTokens(from: lyricBody))
        let checkTokens: [String] = {
            if !heardWords.isEmpty {
                return heardWords.map(\.normalized)
            }
            return normalizeTokens(from: overrideWordsCheck ?? "")
        }()
        let overlap = Set(checkTokens.filter { $0.count >= 3 && !stopWords.contains($0) && bodyTokens.contains($0) }).count

        var score = overlap * 18
        if let synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 40
        } else {
            score += 12
        }

        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: artist,
            rawTitle: track,
            isArtistVerified: true
        )
        let canonicalArtist = ArtistDatabase.canonicalizeSingle(
            extracted.primaryArtist.isEmpty ? artist : extracted.primaryArtist
        )
        let cleanTitle = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: track,
            rawArtistTag: canonicalArtist
        ).songOnly
        let resolvedTitle = cleanTitle.isEmpty ? track : cleanTitle
        let catalogHit = ArtistDatabase.lookup(canonicalArtist)

        return RecognizedLyricsCandidate(
            trackName: resolvedTitle,
            artistName: canonicalArtist,
            genre: catalogHit?.genre ?? extracted.genre,
            durationSeconds: dur,
            syncedLyrics: synced,
            plainLyrics: plain,
            source: source,
            isInCatalog: catalogHit != nil,
            textOverlapCount: overlap,
            score: score
        )
    }

    private static func fetchGeniusPlainLyrics(url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SyncedLyricsService.extractGeniusLyricsText(fromHTML: html)
    }

    // MARK: - Timestamp Alignment Solver

    private static func computeBestOffsetAnchor(
        heardWords: [SpokenLyricWord],
        in lines: [SyncedLyricLine],
        tempoScale: Double
    ) -> AlignmentAnchor? {
        let validLines = lines.enumerated().compactMap { idx, line -> (idx: Int, line: SyncedLyricLine, tokens: [(word: String, time: Double)])? in
            guard !line.isInstrumentalBreak, line.startTime >= 0 else { return nil }
            let timedWords: [(word: String, time: Double)]
            if !line.words.isEmpty {
                timedWords = line.words.compactMap { w in
                    let norm = normalizeWord(w.text)
                    return norm.isEmpty ? nil : (norm, w.startTime)
                }
            } else {
                let rawTokens = normalizeTokens(from: line.text)
                let span = max(0.8, line.endTime - line.startTime)
                timedWords = rawTokens.enumerated().map { wIdx, tok in
                    let frac = Double(wIdx) / Double(max(1, rawTokens.count))
                    return (tok, line.startTime + span * frac)
                }
            }
            guard !timedWords.isEmpty else { return nil }
            return (idx, line, timedWords)
        }

        guard !validLines.isEmpty, heardWords.count >= 2 else { return nil }

        var allAnchors: [AlignmentAnchor] = []
        let minWin = min(3, heardWords.count)
        let maxWin = min(8, heardWords.count)

        for entry in validLines {
            let lineWordSet = Set(entry.tokens.map(\.word))
            let lineBigrams = makeBigrams(entry.tokens.map(\.word))

            var bestForLine: AlignmentAnchor?

            for wLen in minWin...maxWin {
                for startIdx in 0...(heardWords.count - wLen) {
                    let window = Array(heardWords[startIdx..<(startIdx + wLen)])
                    let windowNorms = window.map(\.normalized)

                    var hits = 0
                    var firstMatchedSpoken: SpokenLyricWord?
                    var firstMatchedLineTime: Double?

                    for spoken in window {
                        if lineWordSet.contains(spoken.normalized) {
                            hits += 1
                            if firstMatchedSpoken == nil {
                                firstMatchedSpoken = spoken
                                firstMatchedLineTime = entry.tokens.first(where: { $0.word == spoken.normalized })?.time
                            }
                        }
                    }

                    guard hits >= 2, let fSpoken = firstMatchedSpoken, let fLineTime = firstMatchedLineTime else {
                        continue
                    }

                    let winBigrams = makeBigrams(windowNorms)
                    let bigramHits = winBigrams.filter { lineBigrams.contains($0) }.count

                    let overlapRatio = Double(hits) / Double(max(windowNorms.count, min(entry.tokens.count, windowNorms.count + 2)))
                    let bonus = Double(bigramHits) * 0.14
                    let candidateOffset = fLineTime - (fSpoken.songTime * tempoScale)
                    // Gentle tie-breaker prefers the repetition nearest the current playback position.
                    let proximityPenalty = min(0.24, abs(candidateOffset) * 0.0035)
                    let totalScore = overlapRatio + bonus - proximityPenalty

                    if bestForLine == nil || totalScore > bestForLine!.score {
                        bestForLine = AlignmentAnchor(
                            lineIndex: entry.idx,
                            lineText: entry.line.text,
                            matchedCount: hits,
                            score: totalScore,
                            offsetSeconds: candidateOffset
                        )
                    }
                }
            }

            if let bestForLine, bestForLine.score >= 0.35 {
                allAnchors.append(bestForLine)
            }
        }

        guard let top = allAnchors.max(by: { $0.score < $1.score }) else {
            return nil
        }

        // Smooth out single-word Speech AI jitter using the median offset of neighboring consistent anchors.
        let nearbyConsistent = allAnchors
            .filter { abs($0.offsetSeconds - top.offsetSeconds) <= 2.2 }
            .map(\.offsetSeconds)
            .sorted()

        let medianOffset: Double
        if !nearbyConsistent.isEmpty {
            medianOffset = nearbyConsistent[nearbyConsistent.count / 2]
        } else {
            medianOffset = top.offsetSeconds
        }

        return AlignmentAnchor(
            lineIndex: top.lineIndex,
            lineText: top.lineText,
            matchedCount: top.matchedCount,
            score: top.score,
            offsetSeconds: medianOffset
        )
    }

    private static func makeBigrams(_ words: [String]) -> Set<String> {
        guard words.count >= 2 else { return [] }
        var set = Set<String>()
        for i in 0..<(words.count - 1) {
            set.insert("\(words[i])_\(words[i + 1])")
        }
        return set
    }

    private static func normalizeWord(_ raw: String) -> String {
        let stripped = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression)
            .lowercased()
        switch stripped {
        case "gonna": return "going"
        case "wanna": return "want"
        case "gotta": return "got"
        case "cause", "cuz": return "because"
        default: return stripped
        }
    }

    private static func normalizeTokens(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalizeWord(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }
}
