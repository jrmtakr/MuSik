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
    let identifiedGenre: String?
    let isHighConfidence: Bool
    let transcriptSnippet: String
    let alignedLyrics: ResolvedTrackLyrics?
    let computedOffsetSeconds: Double?
    let alignedLineText: String?
    let statusMessage: String
    let errorMessage: String?
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
        let authStatus = await requestSpeechPermission()
        guard authStatus == .authorized else {
            return LiveLyricsSyncOutcome(
                identifiedTitle: nil,
                identifiedArtist: nil,
                identifiedGenre: nil,
                isHighConfidence: false,
                transcriptSnippet: "",
                alignedLyrics: nil,
                computedOffsetSeconds: nil,
                alignedLineText: nil,
                statusMessage: "Speech Recognition required",
                errorMessage: "Enable Speech Recognition in iPhone Settings -> MuseJRM -> Speech Recognition so the AI can hear the song."
            )
        }

        let recognizer = SFSpeechRecognizer(locale: .current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            return LiveLyricsSyncOutcome(
                identifiedTitle: nil,
                identifiedArtist: nil,
                identifiedGenre: nil,
                isHighConfidence: false,
                transcriptSnippet: "",
                alignedLyrics: nil,
                computedOffsetSeconds: nil,
                alignedLineText: nil,
                statusMessage: "Speech AI unavailable",
                errorMessage: "On-device Speech Recognition is temporarily unavailable."
            )
        }

        await onProgress("Listening to playing audio...")

        var capture = await captureSpokenWords(
            item: item,
            playbackTime: playbackTime,
            recognizer: recognizer,
            equalizerPlayer: equalizerPlayer,
            isEQPlaying: isEQPlaying,
            playbackRate: playbackRate
        )

        // If the user opened at 0:00 during a long instrumental/music-video intro, sample deeper into the song too.
        let totalDur = item.durationSeconds ?? 0
        if capture.words.count < 4, playbackTime < 12.0, totalDur > 36.0 {
            await onProgress("Intro quiet — sampling chorus vocals...")
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

        let heardWords = capture.words
        let cleanSnippet = heardWords.prefix(16).map(\.rawWord).joined(separator: " ")

        guard heardWords.count >= 3 else {
            return LiveLyricsSyncOutcome(
                identifiedTitle: nil,
                identifiedArtist: nil,
                identifiedGenre: nil,
                isHighConfidence: false,
                transcriptSnippet: cleanSnippet,
                alignedLyrics: nil,
                computedOffsetSeconds: nil,
                alignedLineText: nil,
                statusMessage: "Couldn't catch clear vocals",
                errorMessage: "No clear sung words detected around this timestamp. Scrub to where vocals are singing and tap AI Sync."
            )
        }

        // 1. Check whether the currently loaded synced lyrics already match what is singing right now.
        if !forceReidentify,
           let currentLyrics,
           currentLyrics.isTimeSynced,
           let anchor = computeBestOffsetAnchor(
               heardWords: heardWords,
               in: currentLyrics.lines,
               tempoScale: currentLyrics.tempoScale
           ),
           anchor.matchedCount >= 3 && anchor.score >= 0.42 {
            var updated = currentLyrics
            updated.syncedOffsetSeconds = anchor.offsetSeconds
            let canonicalArtist = ArtistDatabase.canonicalizeSingle(currentLyrics.artistName)
            let genre = ArtistDatabase.genre(forArtist: canonicalArtist)
            let isStrongCatalogArtist = ArtistDatabase.lookup(canonicalArtist) != nil
            let signStr = String(format: "%+.1fs", anchor.offsetSeconds)
            return LiveLyricsSyncOutcome(
                identifiedTitle: currentLyrics.trackTitle,
                identifiedArtist: canonicalArtist.isEmpty ? currentLyrics.artistName : canonicalArtist,
                identifiedGenre: genre,
                isHighConfidence: anchor.matchedCount >= 4 && (!canonicalArtist.isEmpty && isStrongCatalogArtist),
                transcriptSnippet: cleanSnippet,
                alignedLyrics: updated,
                computedOffsetSeconds: anchor.offsetSeconds,
                alignedLineText: anchor.lineText,
                statusMessage: "AI Synced (\(signStr)) to \"\(anchor.lineText)\"",
                errorMessage: nil
            )
        }

        // 2. Lyrics are missing, plain, or didn't match the playing vocals — identify the real song & canonical artist!
        await onProgress("Heard \"\(heardWords.prefix(6).map(\.rawWord).joined(separator: " "))\" — identifying song & artist...")

        if let recognized = await identifyBestSong(
            heardWords: heardWords,
            duration: item.durationSeconds,
            rawTitleHint: item.displayTitle,
            rawArtistHint: item.artist
        ) {
            let highConfidence = recognized.textOverlapCount >= 3 && recognized.score >= 70

            if let synced = recognized.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parsed = SyncedLyricsService.parseLRCOrPlain(text: synced, duration: item.durationSeconds ?? recognized.durationSeconds)
                if !parsed.lines.isEmpty {
                    let anchor = computeBestOffsetAnchor(
                        heardWords: heardWords,
                        in: parsed.lines,
                        tempoScale: 1.0
                    )
                    let offset = anchor?.offsetSeconds ?? 0
                    let built = ResolvedTrackLyrics(
                        cacheKey: cacheKey,
                        trackTitle: recognized.trackName,
                        artistName: recognized.artistName,
                        isTimeSynced: parsed.isSynced,
                        sourceLabel: "AI Matched Synced",
                        attributionText: "AI heard vocals • \(recognized.source)",
                        syncedOffsetSeconds: offset,
                        tempoScale: 1.0,
                        expectedDurationSeconds: recognized.durationSeconds,
                        lines: parsed.lines
                    )
                    let offsetSummary = anchor != nil ? String(format: " (%+.1fs)", offset) : ""
                    return LiveLyricsSyncOutcome(
                        identifiedTitle: recognized.trackName,
                        identifiedArtist: recognized.artistName,
                        identifiedGenre: recognized.genre,
                        isHighConfidence: highConfidence,
                        transcriptSnippet: cleanSnippet,
                        alignedLyrics: built,
                        computedOffsetSeconds: anchor?.offsetSeconds,
                        alignedLineText: anchor?.lineText,
                        statusMessage: "AI Identified \"\(recognized.trackName)\" by \(recognized.artistName)\(offsetSummary)",
                        errorMessage: nil
                    )
                }
            }

            if let plain = recognized.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parsed = SyncedLyricsService.parseLRCOrPlain(text: plain, duration: item.durationSeconds ?? recognized.durationSeconds)
                if !parsed.lines.isEmpty {
                    let built = ResolvedTrackLyrics(
                        cacheKey: cacheKey,
                        trackTitle: recognized.trackName,
                        artistName: recognized.artistName,
                        isTimeSynced: false,
                        sourceLabel: "AI Matched Lyrics",
                        attributionText: "AI heard vocals • \(recognized.source)",
                        syncedOffsetSeconds: 0,
                        tempoScale: 1.0,
                        expectedDurationSeconds: recognized.durationSeconds,
                        lines: parsed.lines
                    )
                    return LiveLyricsSyncOutcome(
                        identifiedTitle: recognized.trackName,
                        identifiedArtist: recognized.artistName,
                        identifiedGenre: recognized.genre,
                        isHighConfidence: highConfidence,
                        transcriptSnippet: cleanSnippet,
                        alignedLyrics: built,
                        computedOffsetSeconds: nil,
                        alignedLineText: nil,
                        statusMessage: "AI Identified \"\(recognized.trackName)\" by \(recognized.artistName)",
                        errorMessage: nil
                    )
                }
            }
        }

        // Last resort: align existing lyrics even with looser match if identification had no better synced candidate
        if let currentLyrics,
           currentLyrics.isTimeSynced,
           let anchor = computeBestOffsetAnchor(
               heardWords: heardWords,
               in: currentLyrics.lines,
               tempoScale: currentLyrics.tempoScale
           ),
           anchor.matchedCount >= 2 {
            var updated = currentLyrics
            updated.syncedOffsetSeconds = anchor.offsetSeconds
            let signStr = String(format: "%+.1fs", anchor.offsetSeconds)
            return LiveLyricsSyncOutcome(
                identifiedTitle: currentLyrics.trackTitle,
                identifiedArtist: currentLyrics.artistName,
                identifiedGenre: ArtistDatabase.genre(forArtist: currentLyrics.artistName),
                isHighConfidence: false,
                transcriptSnippet: cleanSnippet,
                alignedLyrics: updated,
                computedOffsetSeconds: anchor.offsetSeconds,
                alignedLineText: anchor.lineText,
                statusMessage: "AI Aligned (\(signStr))",
                errorMessage: nil
            )
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
            statusMessage: "No matching song found",
            errorMessage: "Heard \"\(cleanSnippet)\" — couldn't find a synced match automatically. Try searching by title."
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

        // Build 2 overlapping lyric phrases (center chorus + leading phrase) to avoid noise at clip edges.
        let phraseA = sourceWords.prefix(12).map(\.rawWord).joined(separator: " ")
        let midStart = max(0, (sourceWords.count / 2) - 4)
        let midEnd = min(sourceWords.count, midStart + 10)
        let phraseB = sourceWords[midStart..<midEnd].map(\.rawWord).joined(separator: " ")

        var queries = [phraseA]
        if phraseB != phraseA && phraseB.split(separator: " ").count >= 4 {
            queries.append(phraseB)
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
