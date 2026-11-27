import Accelerate
import AVFoundation
import Foundation
@preconcurrency import Speech

/// One word heard in the file by Whisper / on-device speech, with raw display text and timing span.
struct HeardWord: Sendable, Hashable {
    let token: String
    let rawText: String
    let time: Double
    let endTime: Double

    init(token: String, rawText: String? = nil, time: Double, endTime: Double? = nil) {
        self.token = token
        self.rawText = (rawText?.isEmpty == false) ? rawText! : token
        self.time = time
        self.endTime = max(time + 0.05, endTime ?? (time + 0.25))
    }
}

/// What listening to the whole song concluded about a proposed song name.
enum ListeningVerdict: Sendable, Equatable {
    /// The sung words match that song's lyrics.
    case confirmed(matchRatio: Double)
    /// Plenty of clear vocals, but they don't match that song's lyrics: it's a different song.
    case contradicted(matchRatio: Double)
    /// Too few clear words (instrumental, heavy mix, other language): can't tell either way.
    case inconclusive
}

/// "Listens" to an entire imported song with Apple's on-device speech recognition, then
///   1. checks the words it heard against the lyrics of the song we think it is (confirm / reject the name), and
///   2. lines the synced lyrics up with THIS file — music videos have intros, skits and outros, so lyrics
///      timed for the album version drift. Every lyric line is re-timed against where it was actually heard,
///      piece by piece, so a skit in the middle of a video doesn't throw off the rest of the song.
/// Runs fully on the phone (no account, no key). Needs the Speech Recognition permission the app already asks for.
enum SongAudioListener {
    /// Seconds of audio per Speech fallback chunk & overlap step to avoid cutting words on chunk edges.
    private static let chunkSeconds: Double = 55
    private static let chunkStepSeconds: Double = 50

    // MARK: - Listening

    /// Prepares an AVFoundation-readable audio file URL, remuxing FFmpeg containers (e.g. MKV/TS/WebM) to M4A if needed.
    static func prepareReadableAudioFile(for fileURL: URL) -> (url: URL, cleanupURL: URL?)? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let directAsset = AVURLAsset(url: fileURL)
        if !directAsset.tracks(withMediaType: .audio).isEmpty {
            return (fileURL, nil)
        }
        let remuxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_remux_\(UUID().uuidString).m4a")
        if FFmpegMediaService.remuxAudioTrackToM4A(inputURL: fileURL, outputURL: remuxURL),
           FileManager.default.fileExists(atPath: remuxURL.path),
           !AVURLAsset(url: remuxURL).tracks(withMediaType: .audio).isEmpty {
            return (remuxURL, remuxURL)
        }
        try? FileManager.default.removeItem(at: remuxURL)
        return nil
    }

    /// Transcribes the whole file (audio or music video).
    /// Prefers on-demand CoreML Whisper (`wordTimestamps: true`), falling back cleanly to 5s-overlapping
    /// Apple `SFSpeechRecognizer` chunks when Whisper hasn't finished downloading or is offline.
    static func listen(
        to fileURL: URL,
        maxSeconds: Double = 15 * 60,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> [HeardWord]? {
        if let whisperWords = await WhisperTranscriptionEngine.shared.transcribeWholeFile(
            fileURL: fileURL,
            maxSeconds: maxSeconds,
            allowDownload: true,
            onProgress: onProgress
        ), !whisperWords.isEmpty {
            return whisperWords.map {
                HeardWord(
                    token: $0.token,
                    rawText: $0.rawText,
                    time: $0.startTime,
                    endTime: $0.endTime
                )
            }
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
                ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return nil }

        guard let prepared = prepareReadableAudioFile(for: fileURL) else { return nil }
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        let asset = AVURLAsset(url: prepared.url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 3 else {
            return nil
        }

        let total = min(duration, maxSeconds)
        let totalChunks = max(1, Int(ceil(total / chunkStepSeconds)))
        var heard: [HeardWord] = []
        var start: Double = 0
        var chunkIdx = 0
        while start < total {
            if Task.isCancelled { break }
            let length = min(chunkSeconds, total - start)
            if length < 2 { break }
            chunkIdx += 1
            onProgress?(chunkIdx, totalChunks, total)
            if let chunkURL = await exportAudioChunk(asset: asset, start: start, length: length) {
                let words = await recognize(url: chunkURL, recognizer: recognizer, offset: start)
                for w in words {
                    if let prev = heard.last, abs(w.time - prev.time) < 0.30, w.token == prev.token {
                        continue
                    }
                    if let prev = heard.last, w.time < prev.time - 0.05 {
                        continue
                    }
                    heard.append(w)
                }
                try? FileManager.default.removeItem(at: chunkURL)
            }
            if start + length >= total { break }
            start += chunkStepSeconds
        }
        return heard
    }

    private static func exportAudioChunk(asset: AVAsset, start: Double, length: Double) async -> URL? {
        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("listen_\(UUID().uuidString).m4a")
            session.outputURL = out
            session.outputFileType = .m4a
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed,
               FileManager.default.fileExists(atPath: out.path),
               ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0) > 512 {
                return out
            }
            try? FileManager.default.removeItem(at: out)
        }

        // Video containers (.mp4/.mov) and non-standard audio tracks frequently fail AVAssetExportPresetAppleM4A;
        // fall back to direct AVAssetReader 16 kHz mono PCM WAV decoding which SFSpeechURLRecognitionRequest accepts natively.
        return await Task.detached(priority: .utility) {
            exportWAVChunkWithAssetReader(asset: asset, start: start, length: length)
        }.value
    }

    private static func exportWAVChunkWithAssetReader(asset: AVAsset, start: Double, length: Double) -> URL? {
        guard let reader = try? AVAssetReader(asset: asset),
              let audioTrack = asset.tracks(withMediaType: .audio).first else {
            return nil
        }

        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )

        let sampleRate = 16_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
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

        var pcmData = Data()
        while reader.status == .reading {
            guard let sb = output.copyNextSampleBuffer(),
                  let bb = CMSampleBufferGetDataBuffer(sb) else {
                break
            }
            var totalLen = 0
            var ptr: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &ptr) == noErr,
               let ptr, totalLen > 0 {
                pcmData.append(Data(bytes: ptr, count: totalLen))
            }
            CMSampleBufferInvalidate(sb)
        }

        guard pcmData.count >= sampleRate * 2 else { return nil }
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("listen_\(UUID().uuidString).wav")
        var header = Data(capacity: 44)
        let dataBytes = UInt32(pcmData.count)
        let riffSize = dataBytes &+ 36
        let byteRate = UInt32(sampleRate * 2)
        func appendLE32(_ v: UInt32) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 4))
        }
        func appendLE16(_ v: UInt16) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 2))
        }
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE32(riffSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE32(16)
        appendLE16(1) // PCM
        appendLE16(1) // Mono
        appendLE32(UInt32(sampleRate))
        appendLE32(byteRate)
        appendLE16(2) // Block align
        appendLE16(16) // Bits per sample
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE32(dataBytes)

        var wavFile = header
        wavFile.append(pcmData)
        do {
            try wavFile.write(to: wavURL, options: .atomic)
            return wavURL
        } catch {
            try? FileManager.default.removeItem(at: wavURL)
            return nil
        }
    }

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer, offset: Double) async -> [HeardWord] {
        if recognizer.supportsOnDeviceRecognition {
            let (words, hadError) = await recognizeOnce(url: url, recognizer: recognizer, offset: offset, requireOnDevice: true)
            if !words.isEmpty || !hadError || Task.isCancelled {
                return words
            }
        }
        let (fallbackWords, _) = await recognizeOnce(url: url, recognizer: recognizer, offset: offset, requireOnDevice: false)
        return fallbackWords
    }

    private static func recognizeOnce(
        url: URL,
        recognizer: SFSpeechRecognizer,
        offset: Double,
        requireOnDevice: Bool
    ) async -> ([HeardWord], Bool) {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = requireOnDevice

        let gate = ResumeOnceGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<([HeardWord], Bool), Never>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.compactMap { seg -> HeardWord? in
                        let token = normalizeToken(seg.substring)
                        return token.isEmpty ? nil : HeardWord(
                            token: token,
                            rawText: seg.substring,
                            time: offset + seg.timestamp,
                            endTime: offset + seg.timestamp + max(0.08, seg.duration)
                        )
                    }
                    if gate.claim() { cont.resume(returning: (words, false)) }
                } else if error != nil {
                    let partialWords = result?.bestTranscription.segments.compactMap { seg -> HeardWord? in
                        let token = normalizeToken(seg.substring)
                        return token.isEmpty ? nil : HeardWord(
                            token: token,
                            rawText: seg.substring,
                            time: offset + seg.timestamp,
                            endTime: offset + seg.timestamp + max(0.08, seg.duration)
                        )
                    } ?? []
                    if gate.claim() { cont.resume(returning: (partialWords, true)) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90) {
                task.cancel()
                if gate.claim() { cont.resume(returning: ([], true)) }
            }
        }
    }

    // MARK: - Confirming the song name

    /// Compares what was heard with the lyrics of the proposed song.
    static func verdict(heard: [HeardWord], lyrics: ResolvedTrackLyrics) -> ListeningVerdict {
        let meaningfulHeard = heard.filter { $0.token.count >= 3 && !stopWords.contains($0.token) }
        guard meaningfulHeard.count >= 25 else { return .inconclusive }

        var lyricVocabulary = Set<String>()
        for line in lyrics.lines {
            for token in tokens(line.text) where token.count >= 3 && !stopWords.contains(token) {
                lyricVocabulary.insert(token)
            }
        }
        guard lyricVocabulary.count >= 15 else { return .inconclusive }

        let matched = meaningfulHeard.filter { lyricVocabulary.contains($0.token) }.count
        let ratio = Double(matched) / Double(meaningfulHeard.count)
        let anchors = lyrics.isTimeSynced ? alignmentAnchors(heard: heard, lines: lyrics.lines).count : 0

        if ratio >= 0.3 || anchors >= 4 { return .confirmed(matchRatio: ratio) }
        if ratio < 0.1 && anchors == 0 && meaningfulHeard.count >= 60 { return .contradicted(matchRatio: ratio) }
        return .inconclusive
    }

    /// A distinctive run of heard words, for looking a song up by its lyrics when nothing else knows it.
    static func searchPhrases(from heard: [HeardWord], count: Int = 3) -> [String] {
        let words = heard.map(\.token)
        guard words.count >= 8 else { return [] }
        var phrases: [String] = []
        let step = max(8, words.count / (count + 1))
        var i = step / 2
        while i + 8 <= words.count && phrases.count < count {
            phrases.append(words[i..<(i + 8)].joined(separator: " "))
            i += step
        }
        return phrases
    }

    // MARK: - Lining lyrics up with this file

    private struct Anchor {
        let lyricTime: Double
        let fileTime: Double
    }

    /// Re-times every synced lyric line (and word) to where it was actually heard in this file.
    /// Returns nil when too little was heard to align safely.
    static func align(lyrics: ResolvedTrackLyrics, heard: [HeardWord]) -> ResolvedTrackLyrics? {
        alignWithAnchors(lyrics: lyrics, heard: heard, curve: nil)
    }

    private static func alignWithAnchors(
        lyrics: ResolvedTrackLyrics,
        heard: [HeardWord],
        curve: VocalEnvelope?
    ) -> ResolvedTrackLyrics? {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return nil }
        let anchors = alignmentAnchors(heard: heard, lines: lyrics.lines)
        guard !anchors.isEmpty else { return nil }

        // Precompute split point inside each irregular gap [a, b] using largest lyric pause or deepest singing valley.
        let nonBreakLines = lyrics.lines.filter { !$0.isInstrumentalBreak }
        var intervalSplits: [Double] = []
        intervalSplits.reserveCapacity(max(0, anchors.count - 1))
        for k in 0..<(max(0, anchors.count - 1)) {
            let a = anchors[k], b = anchors[k + 1]
            var splitLyricTime = (a.lyricTime + b.lyricTime) * 0.5
            // Prefer largest natural break in the LRC between a and b.
            var maxLyricGap = 1.2
            for idx in 0..<max(0, nonBreakLines.count - 1) {
                let s0 = nonBreakLines[idx].endTime
                let s1 = nonBreakLines[idx + 1].startTime
                let mid = (s0 + s1) * 0.5
                if s0 >= a.lyricTime && s1 <= b.lyricTime && (s1 - s0) > maxLyricGap {
                    maxLyricGap = s1 - s0
                    splitLyricTime = mid
                }
            }
            // Refine split if the file itself has a distinct silent/talking valley between a.fileTime and b.fileTime.
            if maxLyricGap <= 1.2, let curve, !curve.singingEnvelope.isEmpty, b.fileTime - a.fileTime > 4.0 {
                let dt = curve.frameDurationSeconds
                let i0 = max(0, min(curve.singingEnvelope.count - 1, Int((a.fileTime + 0.6) / dt)))
                let i1 = max(i0 + 1, min(curve.singingEnvelope.count, Int((b.fileTime - 0.6) / dt)))
                if i1 > i0 + 4 {
                    var bestValleyIdx = (i0 + i1) / 2
                    var bestAvg = Double.infinity
                    for idx in i0..<(i1 - 3) {
                        let avg = (curve.singingEnvelope[idx] + curve.singingEnvelope[idx + 1] + curve.singingEnvelope[idx + 2]) / 3.0
                        if avg < bestAvg {
                            bestAvg = avg
                            bestValleyIdx = idx + 1
                        }
                    }
                    let valleyFileTime = Double(bestValleyIdx) * dt
                    let frac = min(0.85, max(0.15, (valleyFileTime - a.fileTime) / max(0.5, b.fileTime - a.fileTime)))
                    splitLyricTime = a.lyricTime + (b.lyricTime - a.lyricTime) * frac
                }
            }
            intervalSplits.append(splitLyricTime)
        }

        func map(_ t: Double) -> Double {
            if anchors.count == 1 || t <= anchors[0].lyricTime {
                return t + (anchors[0].fileTime - anchors[0].lyricTime)
            }
            if let last = anchors.last, t >= last.lyricTime {
                return t + (last.fileTime - last.lyricTime)
            }
            for k in 0..<(anchors.count - 1) {
                let a = anchors[k], b = anchors[k + 1]
                guard t >= a.lyricTime && t <= b.lyricTime else { continue }
                let lyricGap = b.lyricTime - a.lyricTime
                let fileGap = b.fileTime - a.fileTime
                let slope = lyricGap > 0.01 ? fileGap / lyricGap : 1
                if slope > 0.9 && slope < 1.12 {
                    return a.fileTime + (t - a.lyricTime) * slope
                }
                // Split across the deepest gap/valley so pre-skit lines glue to `a` and post-skit lines glue to `b`.
                let splitT = k < intervalSplits.count ? intervalSplits[k] : (a.lyricTime + b.lyricTime) * 0.5
                let ref = (t <= splitT) ? a : b
                return t + (ref.fileTime - ref.lyricTime)
            }
            return t
        }

        var remapped: [SyncedLyricLine] = []
        for line in lyrics.lines {
            let newStart = max(0, map(line.startTime))
            let newEnd = max(newStart, map(line.endTime))
            let newWords = line.words.map {
                LyricWordTiming(id: $0.id, text: $0.text, startTime: max(0, map($0.startTime)), endTime: max(0, map($0.endTime)))
            }
            remapped.append(SyncedLyricLine(
                id: line.id,
                startTime: newStart,
                endTime: newEnd,
                text: line.text,
                words: newWords,
                isInstrumentalBreak: line.isInstrumentalBreak,
                hasNativeWordTimings: line.hasNativeWordTimings,
                isSpokenDialogue: line.isSpokenDialogue
            ))
        }
        // Keep lines in order even if two anchors disagreed slightly.
        for i in 1..<max(1, remapped.count) where remapped[i].startTime < remapped[i - 1].startTime {
            let fixed = remapped[i - 1].startTime + 0.05
            remapped[i] = SyncedLyricLine(
                id: remapped[i].id,
                startTime: fixed,
                endTime: max(fixed, remapped[i].endTime),
                text: remapped[i].text,
                words: remapped[i].words,
                isInstrumentalBreak: remapped[i].isInstrumentalBreak,
                hasNativeWordTimings: remapped[i].hasNativeWordTimings,
                isSpokenDialogue: remapped[i].isSpokenDialogue
            )
        }

        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Synced Lyrics · aligned to this file",
            attributionText: (lyrics.attributionText ?? "LRCLIB") + " · re-timed across gaps (\(anchors.count) anchors)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: nil,
            alignmentVersion: SyncedLyricsService.currentAlignmentVersion,
            lines: remapped
        )
    }

    // MARK: - Hybrid Automatic Whole-Song Aligner (Whisper/STT + Section-DTW + Real-Time Word & Dialogue Timings)

    /// Automatically lines up ANY `lyrics` against `fileURL` into real-time synced line, word, and spoken dialogue timings.
    static func autoAlign(lyrics: ResolvedTrackLyrics, heard: [HeardWord]?, fileURL: URL) async -> ResolvedTrackLyrics {
        guard !lyrics.lines.isEmpty else { return lyrics }

        let curve: VocalEnvelope? = FileManager.default.fileExists(atPath: fileURL.path)
            ? await Task.detached(priority: .utility) { Self.extractVocalActivityCurve(from: fileURL) }.value
            : nil

        var working = lyrics
        if working.isTimeSynced {
            if let heard, let sttAligned = alignWithAnchors(lyrics: working, heard: heard, curve: curve) {
                working = sttAligned
            } else {
                working = alignAcousticallyInternal(lyrics: working, curve: curve)
            }
        } else {
            working = alignPlainLyricsIntoRealTimeSync(lyrics: working, heard: heard, curve: curve)
        }
        working = withRealTimeWordTimings(in: working, heard: heard, curve: curve)
        working = insertSpokenDialogueAndBreaks(in: working, heard: heard, curve: curve)
        working.alignmentVersion = SyncedLyricsService.currentAlignmentVersion
        return working
    }

    /// Populates misc spoken talking/skits (intro, mid-song gaps, outro) from Whisper/Speech transcripts
    /// and preserves clean Apple-Music-style instrumental break dots (`•••`) across long non-talking pauses.
    private static func insertSpokenDialogueAndBreaks(
        in lyrics: ResolvedTrackLyrics,
        heard: [HeardWord]?,
        curve: VocalEnvelope?
    ) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return lyrics }
        let songLines = lyrics.lines.filter { !$0.isInstrumentalBreak && !$0.isSpokenDialogue }
        guard !songLines.isEmpty else { return lyrics }

        let sortedHeard = (heard ?? []).sorted { $0.time < $1.time }
        let curveDur = curve.map { Double($0.envelope.count) * $0.frameDurationSeconds } ?? 0
        let totalDuration = max(curveDur, lyrics.expectedDurationSeconds ?? 0, songLines.last?.endTime ?? 0)

        func spokenLinesForGap(
            start gapStart: Double,
            end gapEnd: Double,
            adjacentLines: [SyncedLyricLine]
        ) -> [SyncedLyricLine] {
            guard gapEnd - gapStart >= 2.8 else { return [] }
            let adjTokens = Set(adjacentLines.flatMap { tokens($0.text) })
            let gapWords = sortedHeard.filter { w in
                guard w.time >= gapStart + 0.15, w.endTime <= gapEnd - 0.15 else { return false }
                // Avoid copying boundary words that actually belong to the first/last instant of neighboring lyric lines.
                if (w.time < gapStart + 0.55 || w.endTime > gapEnd - 0.55) && adjTokens.contains(w.token) {
                    return false
                }
                return true
            }
            guard gapWords.count >= 3 else { return [] }

            // Require at least some non-stopped meaningful words or clear multi-word phrase.
            var groups: [[HeardWord]] = []
            var cur: [HeardWord] = []
            for w in gapWords {
                if let prev = cur.last {
                    if (w.time - prev.endTime) >= 0.85 || cur.count >= 7 {
                        groups.append(cur)
                        cur = [w]
                    } else {
                        cur.append(w)
                    }
                } else {
                    cur.append(w)
                }
            }
            if !cur.isEmpty { groups.append(cur) }

            return groups.compactMap { grp -> SyncedLyricLine? in
                guard let first = grp.first, let last = grp.last else { return nil }
                let s = max(gapStart, first.time)
                let e = min(gapEnd, max(s + 0.45, last.endTime))
                let wordTimings = grp.map {
                    LyricWordTiming(text: $0.rawText, startTime: max(s, $0.time), endTime: min(e, max($0.time + 0.06, $0.endTime)))
                }
                let text = grp.map(\.rawText).joined(separator: " ")
                return SyncedLyricLine(
                    startTime: s,
                    endTime: e,
                    text: text,
                    words: wordTimings,
                    isInstrumentalBreak: false,
                    hasNativeWordTimings: true,
                    isSpokenDialogue: true
                )
            }
        }

        var result: [SyncedLyricLine] = []
        // 1. Intro gap before first song line (skits / spoken intros).
        if let firstSong = songLines.first, firstSong.startTime >= 3.0 {
            let introSpoken = spokenLinesForGap(start: 0.1, end: firstSong.startTime - 0.25, adjacentLines: [firstSong])
            if !introSpoken.isEmpty {
                result.append(contentsOf: introSpoken)
            } else if firstSong.startTime >= 5.0 {
                result.append(SyncedLyricLine(
                    startTime: 0.4,
                    endTime: max(1.0, firstSong.startTime - 0.35),
                    text: "",
                    words: [],
                    isInstrumentalBreak: true
                ))
            }
        }

        // 2. Song lines + mid-song gaps/skits/instrumental solos.
        for i in 0..<songLines.count {
            let cur = songLines[i]
            result.append(cur)
            if i + 1 < songLines.count {
                let next = songLines[i + 1]
                let gapStart = cur.endTime + 0.20
                let gapEnd = next.startTime - 0.20
                let gapSpan = gapEnd - gapStart
                if gapSpan >= 2.8 {
                    let midSpoken = spokenLinesForGap(start: gapStart, end: gapEnd, adjacentLines: [cur, next])
                    if !midSpoken.isEmpty {
                        result.append(contentsOf: midSpoken)
                    } else if gapSpan >= 4.2 {
                        result.append(SyncedLyricLine(
                            startTime: gapStart + 0.15,
                            endTime: max(gapStart + 0.85, gapEnd - 0.15),
                            text: "",
                            words: [],
                            isInstrumentalBreak: true
                        ))
                    }
                }
            }
        }

        // 3. Outro spoken dialogue / skit after the last song line.
        if let lastSong = songLines.last, totalDuration - lastSong.endTime >= 3.0 {
            let outroEnd = min(totalDuration, max(lastSong.endTime + 3.0, (sortedHeard.last?.endTime ?? lastSong.endTime) + 1.0))
            let outroSpoken = spokenLinesForGap(start: lastSong.endTime + 0.30, end: outroEnd, adjacentLines: [lastSong])
            if !outroSpoken.isEmpty {
                result.append(contentsOf: outroSpoken)
            }
        }

        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: lyrics.isTimeSynced,
            sourceLabel: lyrics.sourceLabel,
            attributionText: lyrics.attributionText,
            syncedOffsetSeconds: lyrics.syncedOffsetSeconds,
            tempoScale: lyrics.tempoScale,
            expectedDurationSeconds: lyrics.expectedDurationSeconds,
            alignmentVersion: SyncedLyricsService.currentAlignmentVersion,
            lines: result
        )
    }

    private static func alignPlainLyricsIntoRealTimeSync(
        lyrics: ResolvedTrackLyrics,
        heard: [HeardWord]?,
        curve: VocalEnvelope?
    ) -> ResolvedTrackLyrics {
        let nonEmptyLines = lyrics.lines.filter { !$0.isInstrumentalBreak && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmptyLines.isEmpty else { return lyrics }

        let totalDuration = curve.map { Double($0.envelope.count) * $0.frameDurationSeconds } ?? lyrics.expectedDurationSeconds ?? 180.0
        guard totalDuration > 10 else { return lyrics }

        // Detect sustained singing onset & release (suppressing dry choppy intro/outro spoken skits).
        var firstVocalSec: Double = min(4.0, totalDuration * 0.08)
        var lastVocalSec: Double = max(firstVocalSec + 6.0, totalDuration - min(5.0, totalDuration * 0.05))
        let singingEnv = curve.map { $0.singingEnvelope.isEmpty ? $0.envelope : $0.singingEnvelope }
        if let curve, let singingEnv, singingEnv.count >= 40 {
            let dt = curve.frameDurationSeconds
            let winFrames = 12 // 1.2s sustained singing window
            var sustainedStartIdx: Int?
            if singingEnv.count > winFrames {
                for i in 0...(singingEnv.count - winFrames) {
                    let slice = singingEnv[i..<(i + winFrames)]
                    let mean = slice.reduce(0, +) / Double(winFrames)
                    let activeCount = slice.filter { $0 > 0.06 }.count
                    if mean > -0.02 && activeCount >= 5 {
                        sustainedStartIdx = i
                        break
                    }
                }
            }
            if let sustainedStartIdx {
                firstVocalSec = max(0, Double(sustainedStartIdx) * dt - 0.3)
            } else if let firstIdx = singingEnv.firstIndex(where: { $0 > 0.12 }) {
                firstVocalSec = max(0, Double(firstIdx) * dt - 0.3)
            }

            if singingEnv.count > winFrames {
                for i in stride(from: singingEnv.count - winFrames, through: 0, by: -1) {
                    let slice = singingEnv[i..<(i + winFrames)]
                    let mean = slice.reduce(0, +) / Double(winFrames)
                    let activeCount = slice.filter { $0 > 0.05 }.count
                    if mean > -0.05 && activeCount >= 4 {
                        lastVocalSec = min(totalDuration, max(firstVocalSec + 6.0, Double(i + winFrames) * dt + 0.5))
                        break
                    }
                }
            }
        }
        if let heardFirst = heard?.first(where: { $0.time > 0.4 }),
           heardFirst.time < totalDuration * 0.45,
           heardFirst.time > firstVocalSec {
            firstVocalSec = max(0, heardFirst.time - 0.35)
        }

        // Find monotonic anchors between line indices and multi-peak heard vocal timestamps (supporting repeated choruses).
        var indexAnchors: [(lineIdx: Int, fileTime: Double)] = []
        if let heard, heard.count >= 6 {
            let items = nonEmptyLines.enumerated().map { (pos: Double($0.offset), text: $0.element.text, origIndex: $0.offset) }
            let peaks = collectMultiPeakAnchors(heard: heard, items: items, minScore: 0.55)
            indexAnchors = peaks.map { (lineIdx: $0.origIndex, fileTime: $0.fileTime) }
        }

        // Word-weight per line so longer lines get proportionally longer time slots.
        let weights: [Double] = nonEmptyLines.map { Double(max(2, tokens($0.text).count)) }
        var cumWeights = [Double](repeating: 0, count: nonEmptyLines.count + 1)
        for i in 0..<nonEmptyLines.count {
            cumWeights[i + 1] = cumWeights[i] + weights[i]
        }

        // Map normalized progress [0, 1] onto acoustic singing-band energy curve between anchors
        // so lines naturally linger/pause across skits/instrumental bridges instead of gliding through them.
        func energyWarpedTime(between startTime: Double, and endTime: Double, fraction: Double) -> Double {
            let f = min(1.0, max(0.0, fraction))
            guard f > 0, f < 1, endTime - startTime > 3.0, let curve,
                  let activeEnv = singingEnv, !activeEnv.isEmpty else {
                return startTime + (endTime - startTime) * f
            }
            let dt = curve.frameDurationSeconds
            let i0 = max(0, min(activeEnv.count - 1, Int(startTime / dt)))
            let i1 = max(i0 + 1, min(activeEnv.count, Int(endTime / dt)))
            guard i1 > i0 + 1 else {
                return startTime + (endTime - startTime) * f
            }
            var cumEnergy = [Double](repeating: 0, count: i1 - i0 + 1)
            for k in 0..<(i1 - i0) {
                let v = activeEnv[i0 + k] // [-1, +1]
                let vocalWeight: Double
                if v > -0.05 {
                    vocalWeight = 0.35 + max(0, v)
                } else if v > -0.10 {
                    vocalWeight = 0.08
                } else {
                    vocalWeight = 0.015
                }
                cumEnergy[k + 1] = cumEnergy[k] + vocalWeight
            }
            let totalEnergy = cumEnergy.last ?? 0
            guard totalEnergy > 0.1 else {
                return startTime + (endTime - startTime) * f
            }
            let targetEnergy = totalEnergy * f
            for k in 0..<(cumEnergy.count - 1) where cumEnergy[k + 1] >= targetEnergy {
                let segSpan = max(1e-6, cumEnergy[k + 1] - cumEnergy[k])
                let sub = (targetEnergy - cumEnergy[k]) / segSpan
                let t = (Double(i0 + k) + sub) * dt
                return min(endTime, max(startTime, t))
            }
            return endTime
        }

        func timeForLine(_ idx: Int) -> Double {
            if let exact = indexAnchors.first(where: { $0.lineIdx == idx }) {
                return exact.fileTime
            }
            let prevAnchor = indexAnchors.last(where: { $0.lineIdx < idx })
            let nextAnchor = indexAnchors.first(where: { $0.lineIdx > idx })

            let startLine = prevAnchor?.lineIdx ?? 0
            let endLine = nextAnchor?.lineIdx ?? nonEmptyLines.count
            let startTime = prevAnchor?.fileTime ?? firstVocalSec
            let endTime = nextAnchor?.fileTime ?? lastVocalSec

            let spanWeight = max(1.0, cumWeights[endLine] - cumWeights[startLine])
            let relWeight = max(0, cumWeights[idx] - cumWeights[startLine])
            return energyWarpedTime(between: startTime, and: endTime, fraction: relWeight / spanWeight)
        }

        let sttAnchoredLines = Set(indexAnchors.map(\.lineIdx))
        var chorusAnchorCount = 0
        if let curve, !curve.spectralBands.isEmpty, nonEmptyLines.count >= 12 {
            let promoted = promoteRepeatedChorusAnchors(
                lines: nonEmptyLines.map(\.text),
                cumWeights: cumWeights,
                existingAnchors: indexAnchors,
                firstVocalSec: firstVocalSec,
                lastVocalSec: lastVocalSec,
                totalDuration: totalDuration,
                curve: curve,
                energyWarp: energyWarpedTime
            )
            if promoted.count > indexAnchors.count {
                chorusAnchorCount = promoted.count - indexAnchors.count
                indexAnchors = promoted
            }
        }

        var syncedLines: [SyncedLyricLine] = []
        syncedLines.reserveCapacity(nonEmptyLines.count)
        for idx in 0..<nonEmptyLines.count {
            let line = nonEmptyLines[idx]
            let prevEnd = idx > 0 ? syncedLines[idx - 1].startTime + 0.45 : 0
            let rawStart = max(prevEnd, timeForLine(idx))
            let nextStart = (idx + 1 < nonEmptyLines.count) ? max(rawStart + 0.45, timeForLine(idx + 1)) : min(totalDuration, rawStart + 4.5)
            let lineEnd = min(totalDuration, max(rawStart + 0.35, nextStart - 0.08))
            syncedLines.append(SyncedLyricLine(
                id: line.id,
                startTime: rawStart,
                endTime: lineEnd,
                text: line.text,
                words: [],
                isInstrumentalBreak: false
            ))
        }

        // Guarded Beat-Grid / Vocal-Onset Micro-Quantizer (±0.14s max, active only when tempo periodicity
        // passed the split-half steadiness gate and vocal energy rises at the candidate beat).
        var didBeatSnap = false
        if let curve {
            let snapped = refineWithBeatAndVocalOnset(
                lines: syncedLines,
                lockedLineIndices: sttAnchoredLines,
                curve: curve,
                totalDuration: totalDuration
            )
            didBeatSnap = snapped.didSnapBeat
            syncedLines = snapped.lines
        }

        if syncedLines.count > 1 {
            for i in 0..<(syncedLines.count - 1) {
                let nextStart = syncedLines[i + 1].startTime
                if syncedLines[i].endTime > nextStart - 0.04 {
                    let clampedEnd = max(syncedLines[i].startTime + 0.25, nextStart - 0.05)
                    syncedLines[i] = SyncedLyricLine(
                        id: syncedLines[i].id,
                        startTime: syncedLines[i].startTime,
                        endTime: clampedEnd,
                        text: syncedLines[i].text,
                        words: syncedLines[i].words,
                        isInstrumentalBreak: syncedLines[i].isInstrumentalBreak
                    )
                }
            }
        }

        var details: [String] = []
        if !sttAnchoredLines.isEmpty { details.append("\(sttAnchoredLines.count) vocal anchors") }
        if chorusAnchorCount > 0 { details.append("\(chorusAnchorCount) chorus anchors") }
        if didBeatSnap, let bpm = curve?.beatGrid?.bpm {
            details.append(String(format: "%.0f BPM beat-snapped", bpm))
        }
        let note = details.isEmpty ? "AI vocal-energy real-time sync" : "AI audio-synced (\(details.joined(separator: ", ")))"
        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Real-Time Synced Lyrics · AI",
            attributionText: (lyrics.attributionText ?? "AI Sync") + " · \(note)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: totalDuration,
            lines: syncedLines
        )
    }

    /// Generates time-synced lyrics directly from the whole-song AI Speech transcription when
    /// an unreleased or local song does not exist in any online lyrics database.
    static func buildSyncedLyricsFromHeard(
        _ heard: [HeardWord],
        trackTitle: String,
        artistName: String,
        cacheKey: String,
        duration: Double?
    ) -> ResolvedTrackLyrics? {
        let words = heard
            .filter { !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time < $1.time }
        guard words.count >= 4 else { return nil }

        let totalDur = max(duration ?? 0, (words.last?.time ?? 0) + 4.0)
        var groups: [[HeardWord]] = []
        var cur: [HeardWord] = []
        for w in words {
            if let prev = cur.last {
                let gap = w.time - prev.time
                if gap >= 0.95 || cur.count >= 8 {
                    groups.append(cur)
                    cur = [w]
                } else {
                    cur.append(w)
                }
            } else {
                cur.append(w)
            }
        }
        if !cur.isEmpty { groups.append(cur) }

        var lines: [SyncedLyricLine] = []
        if let firstTime = groups.first?.first?.time, firstTime > 5.5 {
            lines.append(SyncedLyricLine(
                startTime: 0.4,
                endTime: max(1.0, firstTime - 0.35),
                text: "",
                words: [],
                isInstrumentalBreak: true
            ))
        }

        for (idx, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let nextStart: Double = {
                if idx + 1 < groups.count, let nf = groups[idx + 1].first {
                    return nf.time
                }
                return min(totalDur, last.time + 2.5)
            }()
            let lineEnd = min(totalDur, max(first.time + 0.35, min(last.time + 0.45, nextStart - 0.08)))
            let wordTimings = group.enumerated().map { wIdx, w in
                let wNext = (wIdx + 1 < group.count) ? group[wIdx + 1].time : lineEnd
                let wEnd = max(w.time + 0.08, min(lineEnd, wNext))
                return LyricWordTiming(text: w.token, startTime: w.time, endTime: wEnd)
            }
            lines.append(SyncedLyricLine(
                startTime: first.time,
                endTime: lineEnd,
                text: group.map(\.token).joined(separator: " "),
                words: wordTimings,
                isInstrumentalBreak: false,
                hasNativeWordTimings: true
            ))
            let gap = nextStart - lineEnd
            if idx + 1 < groups.count && gap >= 7.0 {
                lines.append(SyncedLyricLine(
                    startTime: lineEnd + 0.35,
                    endTime: max(lineEnd + 1.0, nextStart - 0.35),
                    text: "",
                    words: [],
                    isInstrumentalBreak: true
                ))
            }
        }

        guard !lines.isEmpty else { return nil }
        return ResolvedTrackLyrics(
            cacheKey: cacheKey,
            trackTitle: trackTitle,
            artistName: artistName.isEmpty ? "Unknown Artist" : artistName,
            isTimeSynced: true,
            sourceLabel: "AI Whole-Song Lyrics",
            attributionText: "AI transcribed whole song automatically",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: totalDur,
            lines: lines
        )
    }

    private static func approximateSyllableCount(_ word: String) -> Int {
        let lower = word.lowercased().filter { $0.isLetter }
        guard !lower.isEmpty else { return 1 }
        let vowels = Set("aeiouy")
        var groups = 0
        var prevVowel = false
        for ch in lower {
            let isV = vowels.contains(ch)
            if isV && !prevVowel { groups += 1 }
            prevVowel = isV
        }
        if lower.hasSuffix("e") && groups > 1 { groups -= 1 }
        return max(1, groups)
    }

    private static func withRealTimeWordTimings(
        in lyrics: ResolvedTrackLyrics,
        heard: [HeardWord]?,
        curve: VocalEnvelope? = nil
    ) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return lyrics }

        func acousticWordWarp(between startTime: Double, and endTime: Double, fraction: Double) -> Double {
            let f = min(1.0, max(0.0, fraction))
            guard f > 0, f < 1, endTime - startTime > 0.25,
                  let curve, !curve.fastVocalEnvelope.isEmpty else {
                return startTime + (endTime - startTime) * f
            }
            let dt = curve.fastFrameDurationSeconds
            let i0 = max(0, min(curve.fastVocalEnvelope.count - 1, Int(startTime / dt)))
            let i1 = max(i0 + 1, min(curve.fastVocalEnvelope.count, Int(ceil(endTime / dt))))
            guard i1 > i0 + 1 else {
                return startTime + (endTime - startTime) * f
            }

            var cum = [Double](repeating: 0, count: i1 - i0 + 1)
            for k in 0..<(i1 - i0) {
                let v = curve.fastVocalEnvelope[i0 + k]
                let o = (i0 + k < curve.fastVocalOnset.count) ? curve.fastVocalOnset[i0 + k] : 0.0
                let w = v > -0.10 ? (0.28 + max(0, v) * 0.42 + 0.72 * o) : 0.04
                cum[k + 1] = cum[k] + w
            }
            let total = cum.last ?? 0
            guard total > 0.05 else {
                return startTime + (endTime - startTime) * f
            }
            let target = total * f
            for k in 0..<(cum.count - 1) where cum[k + 1] >= target {
                let segSpan = max(1e-6, cum[k + 1] - cum[k])
                let sub = (target - cum[k]) / segSpan
                let t = (Double(i0 + k) + sub) * dt
                return min(endTime, max(startTime, t))
            }
            return endTime
        }

        let updatedLines: [SyncedLyricLine] = lyrics.lines.enumerated().map { idx, line in
            guard !line.isInstrumentalBreak, (!line.hasNativeWordTimings || line.words.isEmpty) else { return line }
            let rawWords = line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !rawWords.isEmpty else { return line }

            let nextLineFloor = (idx + 1 < lyrics.lines.count)
                ? max(line.startTime + 0.45, lyrics.lines[idx + 1].startTime - 0.05)
                : max(line.startTime + 3.2, line.endTime)
            let rawStart = max(0, line.startTime)
            let rawEnd = min(nextLineFloor, max(rawStart + 0.45, line.endTime > rawStart + 0.25 ? line.endTime : nextLineFloor))
            let minVocalDur = min(rawEnd - rawStart, max(0.50, Double(rawWords.count) * 0.14))

            // Trim silent leading padding and trailing beat tails via 43 Hz vocal energy so words track actual vocals.
            var vocalStart = rawStart
            var vocalEnd = rawEnd
            if let curve, !curve.fastVocalEnvelope.isEmpty {
                let dt = curve.fastFrameDurationSeconds
                let iStart = max(0, min(curve.fastVocalEnvelope.count - 1, Int(rawStart / dt)))
                let iEnd = max(iStart + 1, min(curve.fastVocalEnvelope.count, Int(rawEnd / dt)))

                let maxTrimLeadIdx = min(iEnd, Int((min(rawStart + 0.50, rawEnd - minVocalDur)) / dt))
                if maxTrimLeadIdx > iStart {
                    var scan = iStart
                    while scan < maxTrimLeadIdx && curve.fastVocalEnvelope[scan] < -0.22 {
                        scan += 1
                    }
                    if scan < maxTrimLeadIdx && curve.fastVocalEnvelope[scan] >= -0.10 {
                        vocalStart = max(rawStart, min(rawEnd - minVocalDur, Double(scan) * dt - 0.03))
                    }
                }

                let minEndIdx = max(iStart + 2, Int((vocalStart + minVocalDur) / dt))
                if iEnd > minEndIdx + 2 {
                    for rev in stride(from: iEnd - 1, through: minEndIdx + 1, by: -1) {
                        if curve.fastVocalEnvelope[rev] > -0.15 && curve.fastVocalEnvelope[rev - 1] > -0.18 {
                            vocalEnd = max(vocalStart + minVocalDur, min(rawEnd, Double(rev + 1) * dt + 0.10))
                            break
                        }
                    }
                }
            }

            // Piecewise monotonic SFSpeechRecognizer word anchoring (compensating ~80ms dictation emission lag).
            let localHeard: [HeardWord] = (heard ?? []).filter {
                $0.time >= rawStart - 0.35 && $0.time <= rawEnd + 0.35
            }
            var wordAnchors: [(wIdx: Int, time: Double)] = []
            if !localHeard.isEmpty {
                var hCursor = 0
                for (wIdx, wordText) in rawWords.enumerated() {
                    let normW = normalizeToken(wordText)
                    guard normW.count >= 2 else { continue }
                    let prevAnchorT = wordAnchors.last?.time ?? (vocalStart - 0.05)
                    let minAllowed = max(vocalStart, prevAnchorT + 0.06)
                    let maxAllowed = vocalEnd - max(0.06, Double(rawWords.count - wIdx - 1) * 0.06)
                    guard maxAllowed > minAllowed else { break }

                    var foundIdx: Int?
                    for h in hCursor..<localHeard.count {
                        let ht = localHeard[h].token
                        let match = (ht == normW) || (normW.count >= 4 && ht.count >= 4 && ht.prefix(4) == normW.prefix(4))
                        guard match else { continue }
                        let adjT = localHeard[h].time - 0.08
                        if adjT >= minAllowed - 0.05 && adjT <= maxAllowed + 0.05 {
                            foundIdx = h
                            break
                        }
                    }
                    if let h = foundIdx {
                        let clampedT = min(maxAllowed, max(minAllowed, localHeard[h].time - 0.08))
                        wordAnchors.append((wIdx, clampedT))
                        hCursor = h + 1
                    }
                }
            }

            // Build boundary anchors covering every un-anchored sub-span [wA, tA] -> [wB, tB].
            var boundaries: [(wIdx: Int, time: Double)] = []
            if let first = wordAnchors.first, first.wIdx == 0 {
                boundaries.append(first)
                boundaries.append(contentsOf: wordAnchors.dropFirst())
            } else {
                boundaries.append((0, vocalStart))
                boundaries.append(contentsOf: wordAnchors)
            }
            boundaries.append((rawWords.count, vocalEnd))

            let wordWeights: [Double] = rawWords.map { word in
                let syl = Double(approximateSyllableCount(word))
                let chars = Double(max(2, normalizeToken(word).count))
                var w = syl * 1.15 + chars * 0.22
                if word.hasSuffix(",") || word.hasSuffix(";") { w += 0.55 }
                if word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") { w += 0.85 }
                return max(0.6, w)
            }

            var generatedWords = [LyricWordTiming?](repeating: nil, count: rawWords.count)
            for b in 0..<(boundaries.count - 1) {
                let (w0, t0) = boundaries[b]
                let (w1, t1) = boundaries[b + 1]
                guard w1 > w0 else { continue }
                let segWeights = wordWeights[w0..<w1]
                let segTotal = max(0.1, segWeights.reduce(0, +))
                var cumW = 0.0
                for k in w0..<w1 {
                    let fracStart = cumW / segTotal
                    cumW += wordWeights[k]
                    let fracEnd = min(1.0, cumW / segTotal)
                    let ws = (k == w0) ? t0 : acousticWordWarp(between: t0, and: t1, fraction: fracStart)
                    let we = (k == w1 - 1) ? t1 : acousticWordWarp(between: t0, and: t1, fraction: fracEnd)
                    let safeStart = max(t0, min(t1 - 0.04, ws))
                    let safeEnd = min(t1, max(safeStart + 0.05, we))
                    generatedWords[k] = LyricWordTiming(text: rawWords[k], startTime: safeStart, endTime: safeEnd)
                }
            }

            var finalizedWords = generatedWords.compactMap { $0 }
            // Ensure strictly non-decreasing monotonic boundaries across consecutive words.
            for k in 0..<finalizedWords.count {
                if k > 0 && finalizedWords[k].startTime < finalizedWords[k - 1].startTime + 0.04 {
                    let s = min(vocalEnd - 0.04, finalizedWords[k - 1].startTime + 0.04)
                    finalizedWords[k] = LyricWordTiming(
                        id: finalizedWords[k].id,
                        text: finalizedWords[k].text,
                        startTime: s,
                        endTime: max(s + 0.05, finalizedWords[k].endTime)
                    )
                }
            }

            return SyncedLyricLine(
                id: line.id,
                startTime: vocalStart,
                endTime: vocalEnd,
                text: line.text,
                words: finalizedWords,
                isInstrumentalBreak: false,
                hasNativeWordTimings: false
            )
        }

        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: lyrics.isTimeSynced,
            sourceLabel: lyrics.sourceLabel,
            attributionText: lyrics.attributionText,
            syncedOffsetSeconds: lyrics.syncedOffsetSeconds,
            tempoScale: lyrics.tempoScale,
            expectedDurationSeconds: lyrics.expectedDurationSeconds,
            lines: updatedLines
        )
    }

    static func alignAcousticallyIfNeeded(lyrics: ResolvedTrackLyrics, fileURL: URL) async -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced,
              !lyrics.lines.isEmpty,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return lyrics
        }
        let curve = await Task.detached(priority: .utility) {
            Self.extractVocalActivityCurve(from: fileURL)
        }.value
        return alignAcousticallyInternal(lyrics: lyrics, curve: curve)
    }

    private static func alignAcousticallyInternal(lyrics: ResolvedTrackLyrics, curve: VocalEnvelope?) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return lyrics }
        guard let curve, curve.envelope.count >= 80 else {
            return lyrics
        }

        let dt = curve.frameDurationSeconds // 0.1s per frame
        let actualDuration = Double(curve.envelope.count) * dt
        let lastLyricTime = lyrics.lines.map { max($0.endTime, $0.startTime) }.max() ?? 0
        guard lastLyricTime > 12 else { return lyrics }

        // Test natural tempo (1.0) and mild stretch ratio if official LRC length differs by 1.5%-7%.
        var candidateScales: [Double] = [1.0]
        if let expectedDur = lyrics.expectedDurationSeconds,
           expectedDur > 20, actualDuration > 20 {
            let ratio = actualDuration / expectedDur
            if ratio >= 0.93 && ratio <= 1.07 && abs(ratio - 1.0) >= 0.015 {
                candidateScales.append(ratio)
            }
        }

        let lrcNonBreakLines = lyrics.lines.filter { !$0.isInstrumentalBreak }
        let lrcChorusPairs = curve.spectralBands.isEmpty
            ? []
            : Array(detectRepeatedChorusBlocks(in: lrcNonBreakLines.map(\.text)).prefix(3))

        let singingEnv = curve.singingEnvelope.isEmpty ? curve.envelope : curve.singingEnvelope

        // Convert LRC vocal intervals into expected activity markers once per scale.
        var bestScore = -Double.infinity
        var zeroOffsetScore = -Double.infinity
        var bestOffset: Double = 0
        var bestScale: Double = 1.0

        for scale in candidateScales {
            let sampleTimes: [(time: Double, isSing: Bool)] = lyrics.lines.flatMap { line -> [(Double, Bool)] in
                if line.isInstrumentalBreak {
                    return [(line.startTime * scale, false)]
                }
                let start = line.startTime * scale
                let mid = ((line.startTime + line.endTime) * 0.5) * scale
                let gapBefore = start - 0.8
                var pts: [(Double, Bool)] = [(start, true), (mid, true)]
                if gapBefore > 0.5 { pts.append((gapBefore, false)) }
                return pts
            }

            let chorusTimePairs: [(t1: Double, t2: Double, frames: Int)] = lrcChorusPairs.compactMap { pair in
                guard pair.firstStartLine + pair.lineCount <= lrcNonBreakLines.count,
                      pair.repeatStartLine + pair.lineCount <= lrcNonBreakLines.count,
                      curve.spectralFrameDuration > 0.05 else { return nil }
                let t1 = lrcNonBreakLines[pair.firstStartLine].startTime * scale
                let end1 = lrcNonBreakLines[pair.firstStartLine + pair.lineCount - 1].endTime * scale
                let t2 = lrcNonBreakLines[pair.repeatStartLine].startTime * scale
                let span = max(6.0, min(28.0, end1 - t1))
                let fCount = max(12, Int(span / curve.spectralFrameDuration))
                return (t1, t2, fCount)
            }

            func scoreShift(_ offset: Double) -> Double {
                var sum = 0.0
                var count = 0
                for pt in sampleTimes {
                    let t = pt.time + offset
                    guard t >= 0, t < actualDuration else { continue }
                    let idx = Int(t / dt)
                    guard idx >= 0, idx < singingEnv.count else { continue }
                    let v = singingEnv[idx] // centered around ~0 (-1 silent/skit, +1 singing active)
                    sum += pt.isSing ? v : (-v * 0.45)
                    count += 1
                }
                guard count > 0 else { return -Double.infinity }
                // Tiny prior preferring smaller shifts when scores tie.
                var finalScore = (sum / Double(count)) - min(0.08, abs(offset) * 0.0012)
                if !chorusTimePairs.isEmpty, !curve.spectralBands.isEmpty, curve.spectralFrameDuration > 0.05 {
                    var cSum = 0.0
                    var cCnt = 0
                    for cp in chorusTimePairs {
                        let s1 = Int((cp.t1 + offset) / curve.spectralFrameDuration)
                        let s2 = Int((cp.t2 + offset) / curve.spectralFrameDuration)
                        if s1 >= 0, s2 >= 0,
                           s1 + cp.frames <= curve.spectralBands.count,
                           s2 + cp.frames <= curve.spectralBands.count {
                            cSum += spectralCosineSimilarity(bands: curve.spectralBands, startA: s1, startB: s2, length: cp.frames)
                            cCnt += 1
                        }
                    }
                    if cCnt > 0 {
                        finalScore += 0.14 * (cSum / Double(cCnt))
                    }
                }
                return finalScore
            }

            let zScore = scoreShift(0)
            if scale == 1.0 { zeroOffsetScore = zScore }
            if zScore > bestScore {
                bestScore = zScore
                bestOffset = 0
                bestScale = scale
            }

            // Sweep -30s...+95s in 0.25s steps (covers long music-video intros, skits, and trimmed starts).
            var offset = -30.0
            while offset <= 95.0 {
                let s = scoreShift(offset)
                if s > bestScore {
                    bestScore = s
                    bestOffset = offset
                    bestScale = scale
                }
                offset += 0.25
            }
        }

        // Also check Piecewise Section-DTW (Viterbi) across >= 4s LRC singing gaps so mid-video skits or extra pauses
        // shift Verse 2 / Chorus 2 independently without disturbing Verse 1 or introducing false jumps on studio songs.
        if let piecewise = alignSectionsWithViterbi(
            lyrics: lyrics,
            curve: curve,
            singingEnv: singingEnv,
            lrcNonBreakLines: lrcNonBreakLines,
            lrcChorusPairs: lrcChorusPairs
        ) {
            return piecewise
        }

        // Require a genuine correlation improvement before shifting timestamps away from 0.
        let meaningfulImprovement = abs(bestOffset) >= 0.4 && bestScore > zeroOffsetScore + 0.06 && bestScore > 0.08
        guard meaningfulImprovement || abs(bestScale - 1.0) >= 0.015 else {
            return lyrics
        }

        let appliedOffset = meaningfulImprovement ? bestOffset : 0
        let appliedScale = bestScale
        let remapped = lyrics.lines.map { line in
            let s = max(0, line.startTime * appliedScale + appliedOffset)
            let e = max(s, line.endTime * appliedScale + appliedOffset)
            let words = line.words.map {
                LyricWordTiming(
                    id: $0.id,
                    text: $0.text,
                    startTime: max(0, $0.startTime * appliedScale + appliedOffset),
                    endTime: max(0, $0.endTime * appliedScale + appliedOffset)
                )
            }
            return SyncedLyricLine(
                id: line.id,
                startTime: s,
                endTime: e,
                text: line.text,
                words: words,
                isInstrumentalBreak: line.isInstrumentalBreak,
                hasNativeWordTimings: line.hasNativeWordTimings,
                isSpokenDialogue: line.isSpokenDialogue
            )
        }

        let note = String(format: "auto-aligned (%+.1fs)", appliedOffset)
        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Synced Lyrics · auto-aligned",
            attributionText: (lyrics.attributionText ?? "LRCLIB") + " · \(note)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: actualDuration,
            alignmentVersion: lyrics.alignmentVersion,
            lines: remapped
        )
    }

    /// Piecewise Section-DTW (Viterbi) aligner: splits synced lyrics at >= 4s singing gaps into sections and finds
    /// the optimal monotonically increasing offset per section (-12s..+95s) when a music video inserts skits or breaks.
    private static func alignSectionsWithViterbi(
        lyrics: ResolvedTrackLyrics,
        curve: VocalEnvelope,
        singingEnv: [Double],
        lrcNonBreakLines: [SyncedLyricLine],
        lrcChorusPairs: [RepeatedChorusBlock]
    ) -> ResolvedTrackLyrics? {
        let dt = curve.frameDurationSeconds
        let actualDuration = Double(singingEnv.count) * dt

        struct VocalSection {
            var lineIndices: [Int]
            var startTime: Double
            var endTime: Double
            var samples: [(time: Double, weight: Double, isSing: Bool)]
        }

        var rawSections: [[Int]] = []
        var current: [Int] = []
        var hadBreakSinceLast = false
        for (idx, line) in lyrics.lines.enumerated() {
            if line.isInstrumentalBreak || line.isSpokenDialogue {
                hadBreakSinceLast = true
                continue
            }
            if current.isEmpty {
                current.append(idx)
                hadBreakSinceLast = false
                continue
            }
            let prevEnd = lyrics.lines[current.last!].endTime
            let firstStart = lyrics.lines[current.first!].startTime
            let gap = line.startTime - prevEnd
            let span = prevEnd - firstStart
            if (hadBreakSinceLast || gap >= 4.0) && (current.count >= 2 || span >= 4.0 || gap >= 8.0) {
                rawSections.append(current)
                current = [idx]
            } else {
                current.append(idx)
            }
            hadBreakSinceLast = false
        }
        if !current.isEmpty { rawSections.append(current) }

        // Cap section count at <= 10 by merging smallest intra-section gaps first.
        while rawSections.count > 10 {
            var bestMerge = 0
            var minGap = Double.infinity
            for s in 0..<(rawSections.count - 1) {
                let g = lyrics.lines[rawSections[s + 1].first!].startTime - lyrics.lines[rawSections[s].last!].endTime
                if g < minGap {
                    minGap = g
                    bestMerge = s
                }
            }
            rawSections[bestMerge].append(contentsOf: rawSections[bestMerge + 1])
            rawSections.remove(at: bestMerge + 1)
        }
        guard rawSections.count >= 2 else { return nil }

        var sections: [VocalSection] = rawSections.map { indices in
            let s0 = lyrics.lines[indices.first!].startTime
            let e0 = lyrics.lines[indices.last!].endTime
            var pts: [(time: Double, weight: Double, isSing: Bool)] = []
            for k in 0..<indices.count {
                let ln = lyrics.lines[indices[k]]
                pts.append((ln.startTime, 1.0, true))
                pts.append(((ln.startTime + ln.endTime) * 0.5, 1.0, true))
                if k > 0 {
                    let prevLn = lyrics.lines[indices[k - 1]]
                    if ln.startTime - prevLn.endTime >= 0.8 {
                        pts.append((ln.startTime - 0.55, 0.7, false))
                    }
                }
            }
            // Contrast edges around section onset/release so sections lock right onto singing entrances after skits.
            pts.append((s0 - 1.1, 1.1, false))
            pts.append((s0 - 0.5, 1.1, false))
            pts.append((s0 + 0.35, 1.3, true))
            pts.append((s0 + 1.0, 1.2, true))
            pts.append((e0 + 0.7, 0.8, false))
            return VocalSection(lineIndices: indices, startTime: s0, endTime: e0, samples: pts)
        }

        // Map original vocal line indices -> section index for chorus self-similarity verification.
        var lineToSection: [Int: Int] = [:]
        for (sIdx, sec) in sections.enumerated() {
            for li in sec.lineIndices { lineToSection[li] = sIdx }
        }
        let nonBreakOrigIndices = lyrics.lines.enumerated()
            .filter { !$0.element.isInstrumentalBreak && !$0.element.isSpokenDialogue }
            .map(\.offset)

        func sectionForNonBreakIdx(_ nbIdx: Int) -> Int {
            guard nbIdx >= 0, nbIdx < nonBreakOrigIndices.count else { return 0 }
            return lineToSection[nonBreakOrigIndices[nbIdx]] ?? 0
        }

        func scoreSection(_ sec: VocalSection, offset: Double) -> Double {
            let totalWeight = sec.samples.reduce(0.0) { $0 + $1.weight }
            var sum = 0.0
            var usedWeight = 0.0
            for pt in sec.samples {
                let t = pt.time + offset
                guard t >= 0, t < actualDuration else { continue }
                let idx = Int(t / dt)
                guard idx >= 0, idx < singingEnv.count else { continue }
                let v = singingEnv[idx]
                sum += pt.weight * (pt.isSing ? v : (-v * 0.45))
                usedWeight += pt.weight
            }
            guard usedWeight > totalWeight * 0.35 else { return -2.0 }
            return (sum / usedWeight) - min(0.05, abs(offset) * 0.0005)
        }

        var offsets: [Double] = []
        var oVal = -12.0
        while oVal <= 95.0 {
            offsets.append(oVal)
            oVal += 0.5
        }
        guard let zeroIdx = offsets.firstIndex(where: { abs($0) < 0.01 }) else { return nil }
        let kCount = sections.count
        let oCount = offsets.count

        var emit = Array(repeating: Array(repeating: -2.0, count: oCount), count: kCount)
        for s in 0..<kCount {
            for oi in 0..<oCount {
                emit[s][oi] = scoreSection(sections[s], offset: offsets[oi])
            }
        }

        func chorusBonus(sectionOffsets: [Double]) -> Double {
            guard !lrcChorusPairs.isEmpty, !curve.spectralBands.isEmpty, curve.spectralFrameDuration > 0.05 else {
                return 0
            }
            var cSum = 0.0
            var cCnt = 0
            for pair in lrcChorusPairs {
                guard pair.firstStartLine + pair.lineCount <= lrcNonBreakLines.count,
                      pair.repeatStartLine + pair.lineCount <= lrcNonBreakLines.count else { continue }
                let o1 = sectionOffsets[sectionForNonBreakIdx(pair.firstStartLine)]
                let o2 = sectionOffsets[sectionForNonBreakIdx(pair.repeatStartLine)]
                let t1 = lrcNonBreakLines[pair.firstStartLine].startTime + o1
                let end1 = lrcNonBreakLines[pair.firstStartLine + pair.lineCount - 1].endTime + o1
                let t2 = lrcNonBreakLines[pair.repeatStartLine].startTime + o2
                let fCount = max(12, Int(max(6.0, min(28.0, end1 - t1)) / curve.spectralFrameDuration))
                let s1 = Int(t1 / curve.spectralFrameDuration)
                let s2 = Int(t2 / curve.spectralFrameDuration)
                if s1 >= 0, s2 >= 0,
                   s1 + fCount <= curve.spectralBands.count,
                   s2 + fCount <= curve.spectralBands.count {
                    cSum += spectralCosineSimilarity(bands: curve.spectralBands, startA: s1, startB: s2, length: fCount)
                    cCnt += 1
                }
            }
            return cCnt > 0 ? 0.14 * (cSum / Double(cCnt)) : 0
        }

        let uniform0Total = (0..<kCount).reduce(0.0) { $0 + emit[$1][zeroIdx] } + chorusBonus(sectionOffsets: Array(repeating: 0, count: kCount))
        var uniformBestTotal = -Double.infinity
        for oi in 0..<oCount {
            let total = (0..<kCount).reduce(0.0) { $0 + emit[$1][oi] } + chorusBonus(sectionOffsets: Array(repeating: offsets[oi], count: kCount))
            if total > uniformBestTotal { uniformBestTotal = total }
        }

        var dp = Array(repeating: Array(repeating: -Double.infinity, count: oCount), count: kCount)
        var back = Array(repeating: Array(repeating: -1, count: oCount), count: kCount)
        for oi in 0..<oCount {
            if sections[0].startTime + offsets[oi] >= -0.5 {
                dp[0][oi] = emit[0][oi]
            }
        }
        for s in 1..<kCount {
            for ci in 0..<oCount {
                let currOff = offsets[ci]
                let currEmit = emit[s][ci]
                guard currEmit > -1.5 else { continue }
                var bestVal = -Double.infinity
                var bestPrev = -1
                for pi in 0..<oCount {
                    let prevDp = dp[s - 1][pi]
                    guard prevDp > -Double.infinity else { continue }
                    let prevOff = offsets[pi]
                    let delta = currOff - prevOff
                    guard abs(delta) < 0.01 || (delta >= -12.0 && delta <= 75.0 && abs(delta) >= 2.0) else { continue }
                    guard sections[s].startTime + currOff >= sections[s - 1].endTime + prevOff - 0.6 else { continue }
                    let penalty = abs(delta) < 0.01 ? 0.0 : (0.085 + 0.0015 * abs(delta))
                    let cand = prevDp + currEmit - penalty
                    if cand > bestVal {
                        bestVal = cand
                        bestPrev = pi
                    }
                }
                dp[s][ci] = bestVal
                back[s][ci] = bestPrev
            }
        }

        guard let bestLastIdx = (0..<oCount).max(by: { dp[kCount - 1][$0] < dp[kCount - 1][$1] }),
              dp[kCount - 1][bestLastIdx] > -Double.infinity else {
            return nil
        }

        var chosenOffsets = [Double](repeating: 0, count: kCount)
        var cursor = bestLastIdx
        for s in stride(from: kCount - 1, through: 0, by: -1) {
            chosenOffsets[s] = offsets[cursor]
            cursor = back[s][cursor]
        }

        // Local +-0.5s fine polish (0.1s step) per section while keeping monotonic boundaries.
        for s in 0..<kCount {
            let base = chosenOffsets[s]
            var bestLocalOff = base
            var bestLocalScore = scoreSection(sections[s], offset: base)
            var delta = -0.5
            while delta <= 0.51 {
                let cand = base + delta
                let lowerOk = (s == 0)
                    ? (sections[0].startTime + cand >= 0)
                    : (sections[s].startTime + cand >= sections[s - 1].endTime + chosenOffsets[s - 1] - 0.4)
                let upperOk = (s == kCount - 1) || (sections[s].endTime + cand <= sections[s + 1].startTime + chosenOffsets[s + 1] + 0.4)
                if lowerOk && upperOk {
                    let sc = scoreSection(sections[s], offset: cand)
                    if sc > bestLocalScore {
                        bestLocalScore = sc
                        bestLocalOff = cand
                    }
                }
                delta += 0.1
            }
            chosenOffsets[s] = bestLocalOff
        }

        let minOff = chosenOffsets.min() ?? 0
        let maxOff = chosenOffsets.max() ?? 0
        guard maxOff - minOff >= 2.0 else { return nil }

        var dpTotal = 0.0
        for s in 0..<kCount {
            dpTotal += scoreSection(sections[s], offset: chosenOffsets[s])
            if s > 0 {
                let delta = abs(chosenOffsets[s] - chosenOffsets[s - 1])
                if delta >= 0.01 {
                    dpTotal -= (0.085 + 0.0015 * delta)
                }
            }
        }
        dpTotal += chorusBonus(sectionOffsets: chosenOffsets)

        let margin = min(0.28, 0.06 * Double(kCount))
        guard dpTotal > uniform0Total + margin, dpTotal > uniformBestTotal + margin else {
            return nil
        }

        var remapped = lyrics.lines
        for (idx, line) in lyrics.lines.enumerated() {
            let sIdx = lineToSection[idx] ?? {
                // Fallback for instrumental break / interlude markers: match preceding section offset.
                let prev = lineToSection.keys.filter { $0 < idx }.max()
                return prev.flatMap { lineToSection[$0] } ?? 0
            }()
            let off = chosenOffsets[sIdx]
            let s = max(0, line.startTime + off)
            let e = max(s, line.endTime + off)
            let words = line.words.map {
                LyricWordTiming(
                    id: $0.id,
                    text: $0.text,
                    startTime: max(0, $0.startTime + off),
                    endTime: max(0, $0.endTime + off)
                )
            }
            remapped[idx] = SyncedLyricLine(
                id: line.id,
                startTime: s,
                endTime: e,
                text: line.text,
                words: words,
                isInstrumentalBreak: line.isInstrumentalBreak,
                hasNativeWordTimings: line.hasNativeWordTimings,
                isSpokenDialogue: line.isSpokenDialogue
            )
        }

        let note = String(format: "section-DTW (%+.1fs..%+.1fs)", minOff, maxOff)
        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Synced Lyrics · auto-aligned",
            attributionText: (lyrics.attributionText ?? "LRCLIB") + " · \(note)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: actualDuration,
            alignmentVersion: lyrics.alignmentVersion,
            lines: remapped
        )
    }

    // MARK: - Beat-Grid Quantizer & Repeated-Chorus Detector

    private struct BeatGrid: Sendable {
        let bpm: Double
        let periodSeconds: Double
        let phaseSeconds: Double
        let confidence: Double
    }

    private struct RepeatedChorusBlock: Sendable {
        let firstStartLine: Int
        let repeatStartLine: Int
        let lineCount: Int
    }

    private struct VocalEnvelope: Sendable {
        let frameDurationSeconds: Double
        /// Normalized centered vocal-band activity in roughly [-1, +1] (~10.8 Hz).
        let envelope: [Double]
        /// Singing-weighted envelope (~10.8 Hz) suppressing dry choppy dialogue skits without musical backing.
        let singingEnvelope: [Double]
        /// High-resolution 43.07 Hz (~23ms) centered vocal-band energy for syllable & pause word alignment.
        let fastFrameDurationSeconds: Double
        let fastVocalEnvelope: [Double]
        /// High-resolution 43.07 Hz positive vocal-band spectral-flux spikes normalized [0, 1].
        let fastVocalOnset: [Double]
        /// Present only when tempo periodicity is crisp and consistent across both halves of the track.
        let beatGrid: BeatGrid?
        let spectralFrameDuration: Double
        /// Z-normalized 6-band log-energy spectral descriptors (~2.5 Hz) for chorus self-similarity.
        let spectralBands: [[Double]]
    }

    /// Strips parenthetical ad-libs like `(Yeah, uh)` so chorus blocks still match despite minor ad-lib tweaks.
    private static func normalizedChorusLine(_ text: String) -> String {
        let noParens = text.replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)
        return tokens(noParens).joined(separator: " ")
    }

    /// Finds pairs of repeated >=3-line blocks separated by >=5 lines for chorus self-similarity checks.
    private static func detectRepeatedChorusBlocks(in lines: [String]) -> [RepeatedChorusBlock] {
        let tokenSets = lines.map { Set(normalizedChorusLine($0).split(separator: " ").map(String.init)) }
        let n = lines.count
        guard n >= 10 else { return [] }

        func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            let inter = a.intersection(b).count
            return Double(inter) / Double(max(a.count, b.count))
        }

        var blocks: [RepeatedChorusBlock] = []
        var usedPairs = Set<Int>()
        for i in 0..<(n - 3) {
            guard (0..<3).allSatisfy({ tokenSets[i + $0].count >= 2 }) else { continue }
            var j = i + 5
            while j < n - 2 {
                let key = i * 10000 + j
                if !usedPairs.contains(key),
                   (0..<3).allSatisfy({ jaccard(tokenSets[i + $0], tokenSets[j + $0]) >= 0.72 }) {
                    var len = 3
                    while i + len < j, j + len < n, len < 8,
                          tokenSets[i + len].count >= 2,
                          jaccard(tokenSets[i + len], tokenSets[j + len]) >= 0.70 {
                        len += 1
                    }
                    blocks.append(RepeatedChorusBlock(firstStartLine: i, repeatStartLine: j, lineCount: len))
                    for di in 0..<len {
                        for dj in 0..<len {
                            usedPairs.insert((i + di) * 10000 + (j + dj))
                        }
                    }
                    break
                }
                j += 1
            }
        }
        return blocks
    }

    /// Computes normalized cosine similarity between two multi-band spectral blocks `[startA ..< startA + length]` and `startB`.
    private static func spectralCosineSimilarity(
        bands: [[Double]],
        startA: Int,
        startB: Int,
        length: Int
    ) -> Double {
        guard length > 0,
              startA >= 0, startB >= 0,
              startA + length <= bands.count,
              startB + length <= bands.count else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for k in 0..<length {
            let va = bands[startA + k]
            let vb = bands[startB + k]
            for c in 0..<min(va.count, vb.count) {
                dot += va[c] * vb[c]
                normA += va[c] * va[c]
                normB += vb[c] * vb[c]
            }
        }
        let denom = sqrt(normA * normB)
        return denom > 1e-8 ? (dot / denom) : 0
    }

    /// Cross-matches repeated chorus blocks against 6-band acoustic similarity within strict structural & density guards
    /// so later verses/choruses never drift even when Speech missed words.
    private static func promoteRepeatedChorusAnchors(
        lines: [String],
        cumWeights: [Double],
        existingAnchors: [(lineIdx: Int, fileTime: Double)],
        firstVocalSec: Double,
        lastVocalSec: Double,
        totalDuration: Double,
        curve: VocalEnvelope,
        energyWarp: (Double, Double, Double) -> Double
    ) -> [(lineIdx: Int, fileTime: Double)] {
        let blocks = detectRepeatedChorusBlocks(in: lines)
        guard !blocks.isEmpty, curve.spectralFrameDuration > 0.05, !curve.spectralBands.isEmpty else {
            return existingAnchors
        }

        var anchors = existingAnchors.sorted { $0.lineIdx < $1.lineIdx }
        let dtF = curve.spectralFrameDuration
        let totalBands = curve.spectralBands.count

        func estimateAt(_ idx: Int) -> Double {
            if let exact = anchors.first(where: { $0.lineIdx == idx }) { return exact.fileTime }
            let prev = anchors.last(where: { $0.lineIdx < idx })
            let next = anchors.first(where: { $0.lineIdx > idx })
            let sLine = prev?.lineIdx ?? 0
            let eLine = next?.lineIdx ?? lines.count
            let sTime = prev?.fileTime ?? firstVocalSec
            let eTime = next?.fileTime ?? lastVocalSec
            let spanW = max(1.0, cumWeights[eLine] - cumWeights[sLine])
            let relW = max(0, cumWeights[idx] - cumWeights[sLine])
            return energyWarp(sTime, eTime, relW / spanW)
        }

        for block in blocks {
            // Skip if repeat already sits near an existing anchor (nothing to rescue).
            if anchors.contains(where: { abs($0.lineIdx - block.repeatStartLine) <= 4 }) { continue }

            let tAStart = estimateAt(block.firstStartLine)
            let lastInFirst = min(lines.count - 1, block.firstStartLine + block.lineCount - 1)
            let tAEnd = estimateAt(lastInFirst + 1 < lines.count ? lastInFirst + 1 : lastInFirst)
            let estDur = max(8.0, min(28.0, tAEnd - tAStart))

            let idxA = max(0, min(totalBands - 1, Int(tAStart / dtF)))
            let blkLen = max(14, Int(estDur / dtF))
            guard idxA + blkLen <= totalBands else { continue }

            let prevAnchor = anchors.last(where: { $0.lineIdx < block.repeatStartLine })
            let nextAnchor = anchors.first(where: { $0.lineIdx > block.repeatStartLine })
            let prevLine = prevAnchor?.lineIdx ?? 0
            let prevTime = prevAnchor?.fileTime ?? firstVocalSec
            let nextLine = nextAnchor?.lineIdx ?? lines.count
            let nextTime = nextAnchor?.fileTime ?? lastVocalSec

            let fracJ = Double(block.repeatStartLine) / Double(max(1, lines.count))
            let winMinT = max(prevTime + 1.5, max(tAStart + estDur + 4.0, (fracJ - 0.22) * totalDuration))
            let winMaxT = min(nextTime - 1.5, (fracJ + 0.22) * totalDuration)
            let minIdxB = max(idxA + blkLen + 6, Int(winMinT / dtF))
            let maxIdxB = min(totalBands - blkLen, Int(winMaxT / dtF))
            guard maxIdxB > minIdxB else { continue }

            var candidates: [(idx: Int, sim: Double)] = []
            candidates.reserveCapacity(maxIdxB - minIdxB + 1)
            for idxB in minIdxB...maxIdxB {
                let s = spectralCosineSimilarity(bands: curve.spectralBands, startA: idxA, startB: idxB, length: blkLen)
                candidates.append((idxB, s))
            }
            guard let top = candidates.max(by: { $0.sim < $1.sim }) else { continue }
            let runnerSim = candidates
                .filter { abs(Double($0.idx - top.idx) * dtF) > 10.0 }
                .map(\.sim)
                .max() ?? 0.0
            let margin = top.sim - runnerSim
            let acceptableSim = (top.sim >= 0.62 && margin >= 0.08) || (top.sim >= 0.56 && margin >= 0.20)
            guard acceptableSim else { continue }

            let candidateTime = Double(top.idx) * dtF
            // Guard word density so no verse gets crushed or stretched implausibly.
            let leftWords = max(2.0, cumWeights[block.repeatStartLine] - cumWeights[prevLine])
            let leftRate = leftWords / max(0.5, candidateTime - prevTime)
            guard leftRate >= 0.35 && leftRate <= 6.5 else { continue }

            if nextLine > block.repeatStartLine + 1 {
                let rightWords = max(2.0, cumWeights[nextLine] - cumWeights[block.repeatStartLine])
                let rightRate = rightWords / max(0.5, nextTime - candidateTime)
                guard rightRate >= 0.35 && rightRate <= 6.5 else { continue }
            }

            anchors.append((block.repeatStartLine, candidateTime))
            anchors.sort { $0.lineIdx < $1.lineIdx }
        }
        return anchors
    }

    /// Softly snaps un-anchored plain lines (`<= 0.14s`) onto active beats or vocal phrase rises while
    /// strictly preserving ordering, minimum line duration, and rubato safety (no-op if no steady beat).
    private static func refineWithBeatAndVocalOnset(
        lines: [SyncedLyricLine],
        lockedLineIndices: Set<Int>,
        curve: VocalEnvelope,
        totalDuration: Double
    ) -> (lines: [SyncedLyricLine], didSnapBeat: Bool) {
        guard let grid = curve.beatGrid, !lines.isEmpty else {
            return (lines, false)
        }
        let step = grid.periodSeconds > 0.62 ? grid.periodSeconds * 0.5 : grid.periodSeconds
        let envDt = curve.frameDurationSeconds
        guard step >= 0.25, envDt > 0.02, !curve.envelope.isEmpty else {
            return (lines, false)
        }

        func vocalLevel(at time: Double, span: Double) -> Double {
            let i0 = max(0, min(curve.envelope.count - 1, Int(time / envDt)))
            let i1 = max(i0 + 1, min(curve.envelope.count, Int((time + span) / envDt)))
            let slice = curve.envelope[i0..<i1]
            return slice.reduce(0, +) / Double(max(1, slice.count))
        }

        var refined = lines
        var didSnapAny = false
        for i in 0..<refined.count {
            if lockedLineIndices.contains(i) { continue }
            let orig = refined[i].startTime
            let minBound = i > 0 ? refined[i - 1].startTime + 0.42 : 0.0
            let maxBound = (i + 1 < refined.count) ? refined[i + 1].startTime - 0.42 : max(orig, totalDuration - 0.6)
            guard maxBound > minBound + 0.05 else { continue }

            // Nearest beat/half-beat relative to steady grid phase.
            let k = ((orig - grid.phaseSeconds) / step).rounded()
            let beatTime = grid.phaseSeconds + k * step
            let shift = beatTime - orig
            guard abs(shift) <= 0.14, abs(shift) >= 0.02,
                  beatTime >= minBound, beatTime <= maxBound else {
                continue
            }

            // Never snap a line onto silence: confirm active vocals at the candidate beat.
            let activeAfter = vocalLevel(at: max(0, beatTime - 0.04), span: 0.26)
            let before = vocalLevel(at: max(0, beatTime - 0.22), span: 0.16)
            guard activeAfter > -0.08 && (activeAfter - before) >= -0.05 else {
                continue
            }

            let newEnd = min(totalDuration, max(beatTime + 0.45, refined[i].endTime))
            if i > 0, refined[i - 1].endTime > beatTime - 0.04 {
                let prevClampedEnd = max(refined[i - 1].startTime + 0.35, beatTime - 0.05)
                refined[i - 1] = SyncedLyricLine(
                    id: refined[i - 1].id,
                    startTime: refined[i - 1].startTime,
                    endTime: prevClampedEnd,
                    text: refined[i - 1].text,
                    words: refined[i - 1].words,
                    isInstrumentalBreak: refined[i - 1].isInstrumentalBreak
                )
            }
            refined[i] = SyncedLyricLine(
                id: refined[i].id,
                startTime: beatTime,
                endTime: newEnd,
                text: refined[i].text,
                words: refined[i].words,
                isInstrumentalBreak: refined[i].isInstrumentalBreak
            )
            didSnapAny = true
        }
        return (refined, didSnapAny)
    }

    /// Detects steady tempo periodicity (`68-162 BPM`) from 43 Hz spectral flux onset envelopes.
    /// Returns nil whenever the beat is weak, rubato, or shifts tempo between the first and second halves.
    private static func estimateSteadyBeatGrid(flux: [Double], frameDt: Double) -> BeatGrid? {
        guard flux.count >= 256, frameDt > 0 else { return nil }
        // Adaptive local mean subtraction via prefix sums (window = 17 frames ~ 0.40s).
        var prefix = [Double](repeating: 0, count: flux.count + 1)
        for i in 0..<flux.count { prefix[i + 1] = prefix[i] + flux[i] }
        let halfWin = 8
        var onset = [Double](repeating: 0, count: flux.count)
        for i in 0..<flux.count {
            let a = max(0, i - halfWin)
            let b = min(flux.count, i + halfWin + 1)
            let localMean = (prefix[b] - prefix[a]) / Double(max(1, b - a))
            onset[i] = max(0, flux[i] - localMean)
        }

        let minLag = max(8, Int((60.0 / (162.0 * frameDt)).rounded()))
        let maxLag = max(minLag + 2, Int((60.0 / (68.0 * frameDt)).rounded()))

        func peakPeriod(start: Int, end: Int) -> (lag: Int, corr: Double, median: Double)? {
            let len = end - start
            guard len > maxLag * 2 else { return nil }
            var corrs: [(lag: Int, c: Double)] = []
            corrs.reserveCapacity(maxLag - minLag + 1)
            for lag in minLag...maxLag {
                var dot = 0.0
                var na = 0.0
                var nb = 0.0
                for i in start..<(end - lag) {
                    let va = onset[i]
                    let vb = onset[i + lag]
                    dot += va * vb
                    na += va * va
                    nb += vb * vb
                }
                let denom = sqrt(na * nb)
                let c = denom > 1e-8 ? (dot / denom) : 0
                corrs.append((lag, c))
            }
            guard let best = corrs.max(by: { $0.c < $1.c }) else { return nil }
            let sortedVals = corrs.map(\.c).sorted()
            let med = sortedVals[sortedVals.count / 2]
            return (best.lag, best.c, med)
        }

        guard let allPeak = peakPeriod(start: 0, end: onset.count),
              (allPeak.corr - allPeak.median) >= 0.18,
              allPeak.corr >= 0.30 else {
            return nil
        }

        let mid = onset.count / 2
        guard let h1 = peakPeriod(start: 0, end: mid),
              let h2 = peakPeriod(start: mid, end: onset.count) else {
            return nil
        }
        let bpmAll = 60.0 / (Double(allPeak.lag) * frameDt)
        let bpm1 = 60.0 / (Double(h1.lag) * frameDt)
        let bpm2 = 60.0 / (Double(h2.lag) * frameDt)
        let sameTempo = abs(bpm1 - bpm2) / max(bpm1, bpm2) <= 0.05
        let harmonicHalf = abs((min(bpm1, bpm2) / max(bpm1, bpm2)) - 0.5) <= 0.04
        guard sameTempo || harmonicHalf else {
            return nil
        }

        var phaseBins = [Double](repeating: 0, count: allPeak.lag)
        for i in 0..<onset.count {
            phaseBins[i % allPeak.lag] += onset[i]
        }
        guard let bestPhaseBin = phaseBins.indices.max(by: { phaseBins[$0] < phaseBins[$1] }) else {
            return nil
        }
        let meanPhase = phaseBins.reduce(0, +) / Double(allPeak.lag)
        let sharpness = phaseBins[bestPhaseBin] / max(1e-8, meanPhase)
        guard sharpness >= 1.12 else {
            return nil
        }

        let prom = allPeak.corr - allPeak.median
        return BeatGrid(
            bpm: bpmAll,
            periodSeconds: Double(allPeak.lag) * frameDt,
            phaseSeconds: Double(bestPhaseBin) * frameDt,
            confidence: min(1.0, prom / 0.35)
        )
    }

    private static func extractVocalActivityCurve(from url: URL) -> VocalEnvelope? {
        guard let prepared = prepareReadableAudioFile(for: url) else { return nil }
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        let asset = AVURLAsset(url: prepared.url)
        guard let reader = try? AVAssetReader(asset: asset),
              let audioTrack = asset.tracks(withMediaType: .audio).first else {
            return nil
        }

        let sampleRate: Double = 11_025
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
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

        let maxSamples = Int(sampleRate * 900)
        var samples: [Float] = []
        var scale: Float = 1.0 / 32768.0
        while reader.status == .reading, samples.count < maxSamples {
            guard let sb = output.copyNextSampleBuffer(),
                  let bb = CMSampleBufferGetDataBuffer(sb) else { break }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
               let ptr = pointer, length >= 2 {
                let count = min(length / MemoryLayout<Int16>.size, maxSamples - samples.count)
                var raw = [Float](repeating: 0, count: count)
                var scaled = [Float](repeating: 0, count: count)
                ptr.withMemoryRebound(to: Int16.self, capacity: count) { i16 in
                    vDSP_vflt16(i16, 1, &raw, 1, vDSP_Length(count))
                }
                vDSP_vsmul(raw, 1, &scale, &scaled, 1, vDSP_Length(count))
                samples.append(contentsOf: scaled)
            }
            CMSampleBufferInvalidate(sb)
        }

        let fftSize = 1024
        let log2N = vDSP_Length(10)
        let hop = 256 // ~43.07 Hz resolution for crisp beat tracking & multi-rate downsampling
        guard samples.count >= fftSize,
              let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let halfN = fftSize / 2
        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        let estFrames = (samples.count - fftSize) / hop + 1
        var rawVocal43Hz: [Double] = []
        rawVocal43Hz.reserveCapacity(estFrames)
        var rawFlux43Hz: [Double] = []
        rawFlux43Hz.reserveCapacity(estFrames)
        var rawVocalFlux43Hz: [Double] = []
        rawVocalFlux43Hz.reserveCapacity(estFrames)
        var rawBands43Hz: [[Double]] = []
        rawBands43Hz.reserveCapacity(estFrames)
        var prevLogMags = [Double](repeating: 0, count: 256)
        var hasPrev = false

        var pos = 0
        while pos + fftSize <= samples.count {
            samples.withUnsafeBufferPointer { sPtr in
                vDSP_vmul(sPtr.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            real.withUnsafeMutableBufferPointer { rPtr in
                imag.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
                }
            }

            // 6 perceptual bands (sub/kick, low-mid, vocal-low, vocal-mid, vocal-hi, air) + 300-3400 Hz vocal sum.
            var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, vocalSum: Float = 0
            for b in 2..<min(halfN, 512) {
                let m = mags[b]
                if b < 10 { b0 += m }
                else if b < 28 { b1 += m }
                else if b < 95 { b2 += m }
                else if b < 230 { b3 += m }
                else if b < 350 { b4 += m }
                else { b5 += m }
                if b >= 28 && b < 316 { vocalSum += m }
            }
            rawVocal43Hz.append(log1p(Double(vocalSum)))
            rawBands43Hz.append([
                log1p(Double(b0)), log1p(Double(b1)), log1p(Double(b2)),
                log1p(Double(b3)), log1p(Double(b4)), log1p(Double(b5))
            ])

            var fluxVal = 0.0
            var vocalFluxVal = 0.0
            for b in 2..<min(halfN, 256) {
                let lm = log1p(Double(sqrtf(max(0, mags[b]))))
                if hasPrev {
                    let d = lm - prevLogMags[b]
                    if d > 0 {
                        fluxVal += d
                        if b >= 28 {
                            vocalFluxVal += d
                        }
                    }
                }
                prevLogMags[b] = lm
            }
            rawFlux43Hz.append(fluxVal)
            rawVocalFlux43Hz.append(vocalFluxVal)
            hasPrev = true
            pos += hop
        }

        // Downsample 43.07 Hz vocal log-energy by 4 (~10.77 Hz / 0.0929s per frame) for smooth phrase curve.
        let dsEnv = 4
        let envCount = rawVocal43Hz.count / dsEnv
        guard envCount > 0 else { return nil }
        var rawEnergies = [Double](repeating: 0, count: envCount)
        for i in 0..<envCount {
            let base = i * dsEnv
            var s = 0.0
            for k in 0..<dsEnv { s += rawVocal43Hz[base + k] }
            rawEnergies[i] = s / Double(dsEnv)
        }
        let sorted = rawEnergies.sorted()
        let p20 = sorted[max(0, sorted.count / 5)]
        let p80 = sorted[min(sorted.count - 1, (sorted.count * 4) / 5)]
        let mid = (p20 + p80) * 0.5
        let spread = max(0.25, (p80 - p20) * 0.5)
        let centered = rawEnergies.map { min(1.0, max(-1.0, ($0 - mid) / spread)) }

        // Compute low-frequency musical accompaniment (kick/bass/low-mid: b0 + b1) to separate
        // dry choppy talking skits from sustained singing over music.
        var rawMusicLow = [Double](repeating: 0, count: envCount)
        for i in 0..<envCount {
            let base = i * dsEnv
            var s = 0.0
            for k in 0..<dsEnv {
                s += (rawBands43Hz[base + k][0] + rawBands43Hz[base + k][1]) * 0.5
            }
            rawMusicLow[i] = s / Double(dsEnv)
        }
        let sortedLow = rawMusicLow.sorted()
        let lowP20 = sortedLow[max(0, sortedLow.count / 5)]
        let lowP80 = sortedLow[min(sortedLow.count - 1, (sortedLow.count * 4) / 5)]
        let lowMid = (lowP20 + lowP80) * 0.5
        let lowSpread = max(0.25, (lowP80 - lowP20) * 0.5)
        let lowNorm = rawMusicLow.map { min(1.0, max(-1.0, ($0 - lowMid) / lowSpread)) }

        var rawSinging = [Double](repeating: 0, count: envCount)
        for i in 0..<envCount {
            let v = centered[i]
            guard v > 0 else {
                rawSinging[i] = v
                continue
            }
            let w0 = max(0, i - 7)
            let w1 = min(envCount - 1, i + 7)
            let spanCount = max(1, w1 - w0 + 1)
            var active = 0
            for j in w0...w1 where centered[j] > 0.05 { active += 1 }
            let duty = Double(active) / Double(spanCount)
            if lowNorm[i] < -0.60 {
                // Essentially no musical bed (e.g., dry spoken skit): suppress unless ultra-sustained a cappella.
                rawSinging[i] = duty >= 0.85 ? (v * 0.25) : -0.28
            } else if lowNorm[i] < -0.40 && duty < 0.58 {
                rawSinging[i] = -0.28
            } else if lowNorm[i] < -0.25 && duty < 0.48 {
                rawSinging[i] = v * 0.35
            } else {
                rawSinging[i] = v
            }
        }
        var singingEnvelope = [Double](repeating: 0, count: envCount)
        for i in 0..<envCount {
            let a = max(0, i - 2)
            let b = min(envCount - 1, i + 2)
            var sum = 0.0
            for j in a...b { sum += rawSinging[j] }
            singingEnvelope[i] = min(1.0, max(-1.0, sum / Double(b - a + 1)))
        }

        // Keep full 43.07 Hz centered vocal energy & p95-normalized vocal onset flux for crisp word/syllable warping.
        let fastVocalEnvelope = rawVocal43Hz.map { min(1.0, max(-1.0, ($0 - mid) / spread)) }
        let sortedFlux = rawVocalFlux43Hz.sorted()
        let fluxP95 = sortedFlux.isEmpty ? 1.0 : max(0.25, sortedFlux[min(sortedFlux.count - 1, (sortedFlux.count * 19) / 20)])
        let fastVocalOnset = rawVocalFlux43Hz.map { min(1.0, max(0.0, $0 / fluxP95)) }

        // Downsample 43.07 Hz 6-band descriptors by 17 (~2.53 Hz / 0.395s per frame) & z-normalize each band.
        let dsSpec = 17
        let specCount = rawBands43Hz.count / dsSpec
        var spectralBands: [[Double]] = []
        if specCount >= 8 {
            spectralBands = Array(repeating: [Double](repeating: 0, count: 6), count: specCount)
            for i in 0..<specCount {
                let base = i * dsSpec
                for c in 0..<6 {
                    var s = 0.0
                    for k in 0..<dsSpec { s += rawBands43Hz[base + k][c] }
                    spectralBands[i][c] = s / Double(dsSpec)
                }
            }
            for c in 0..<6 {
                var mean = 0.0
                for i in 0..<specCount { mean += spectralBands[i][c] }
                mean /= Double(specCount)
                var variance = 0.0
                for i in 0..<specCount {
                    let d = spectralBands[i][c] - mean
                    variance += d * d
                }
                let std = max(0.25, sqrt(variance / Double(specCount)))
                for i in 0..<specCount {
                    spectralBands[i][c] = (spectralBands[i][c] - mean) / std
                }
            }
        }

        let fastDt = Double(hop) / sampleRate
        let beatGrid = estimateSteadyBeatGrid(flux: rawFlux43Hz, frameDt: fastDt)
        return VocalEnvelope(
            frameDurationSeconds: fastDt * Double(dsEnv),
            envelope: centered,
            singingEnvelope: singingEnvelope,
            fastFrameDurationSeconds: fastDt,
            fastVocalEnvelope: fastVocalEnvelope,
            fastVocalOnset: fastVocalOnset,
            beatGrid: beatGrid,
            spectralFrameDuration: fastDt * Double(dsSpec),
            spectralBands: spectralBands
        )
    }

    /// Finds up to `maxPeaksPerItem` well-separated occurrences (>= 12s apart) per lyric line in `heard` so
    /// repeated choruses don't collapse onto the first match, then selects the best monotonic chain (weighted LIS).
    private static func collectMultiPeakAnchors(
        heard: [HeardWord],
        items: [(pos: Double, text: String, origIndex: Int)],
        minScore: Double,
        maxPeaksPerItem: Int = 3,
        minPeakSeparationSeconds: Double = 12.0
    ) -> [(pos: Double, fileTime: Double, origIndex: Int)] {
        guard heard.count >= 6 else { return [] }
        struct CandidatePeak {
            let pos: Double
            let fileTime: Double
            let origIndex: Int
            let score: Double
        }

        var candidates: [CandidatePeak] = []
        for item in items {
            let lineTokens = tokens(item.text).filter { !$0.isEmpty }
            guard lineTokens.count >= 3 else { continue }
            let needed = Set(lineTokens)
            guard needed.count >= 3 else { continue }
            let window = lineTokens.count + 3

            var allMatches: [(time: Double, score: Double)] = []
            var i = 0
            while i < heard.count {
                let end = min(heard.count, i + window)
                var hits = Set<String>()
                var firstHit: Int?
                for j in i..<end where needed.contains(heard[j].token) {
                    if firstHit == nil { firstHit = j }
                    hits.insert(heard[j].token)
                }
                let sc = Double(hits.count) / Double(needed.count)
                if sc >= minScore, let firstHit {
                    allMatches.append((max(0, heard[firstHit].time - 0.15), sc))
                }
                i += 1
            }

            let ranked = allMatches.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.time < $1.time
            }
            var chosenTimes: [Double] = []
            for m in ranked {
                if chosenTimes.allSatisfy({ abs($0 - m.time) >= minPeakSeparationSeconds }) {
                    chosenTimes.append(m.time)
                    candidates.append(CandidatePeak(pos: item.pos, fileTime: m.time, origIndex: item.origIndex, score: m.score))
                    if chosenTimes.count >= maxPeaksPerItem { break }
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        let sorted = candidates.sorted {
            if $0.pos != $1.pos { return $0.pos < $1.pos }
            return $0.fileTime < $1.fileTime
        }
        var dpWeight = sorted.map { 1.0 + 0.1 * $0.score }
        var previous = Array(repeating: -1, count: sorted.count)
        for i in 0..<sorted.count {
            for j in 0..<i where sorted[j].pos < sorted[i].pos && sorted[j].fileTime + 0.35 <= sorted[i].fileTime {
                let cand = dpWeight[j] + 1.0 + 0.1 * sorted[i].score
                if cand > dpWeight[i] {
                    dpWeight[i] = cand
                    previous[i] = j
                }
            }
        }
        guard var idx = dpWeight.indices.max(by: { dpWeight[$0] < dpWeight[$1] }) else { return [] }
        var chain: [(pos: Double, fileTime: Double, origIndex: Int)] = []
        while idx >= 0 {
            let item = sorted[idx]
            chain.append((pos: item.pos, fileTime: item.fileTime, origIndex: item.origIndex))
            idx = previous[idx]
        }
        return chain.reversed()
    }

    /// Finds lyric lines that were clearly heard, and when. Supports repeated choruses via multi-peak matching and
    /// keeps the highest-scoring monotonic chain moving forward in both lyric time and file time.
    private static func alignmentAnchors(heard: [HeardWord], lines: [SyncedLyricLine]) -> [Anchor] {
        let items = lines.enumerated()
            .filter { !$0.element.isInstrumentalBreak && !$0.element.isSpokenDialogue }
            .map { (pos: $0.element.startTime, text: $0.element.text, origIndex: $0.offset) }
        return collectMultiPeakAnchors(heard: heard, items: items, minScore: 0.6)
            .map { Anchor(lyricTime: $0.pos, fileTime: $0.fileTime) }
    }

    // MARK: - Text helpers

    static func normalizeToken(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "you", "your", "for", "but", "not", "are", "was", "with", "that", "this", "its",
        "yeah", "ooh", "ohh", "oh", "na", "la", "hey", "uh", "huh", "baby", "got", "get", "all", "just",
        "can", "cant", "dont", "now", "one", "out", "what", "when", "who", "how", "she", "him", "her", "his"
    ]
}
