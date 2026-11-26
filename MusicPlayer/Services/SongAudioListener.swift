import Accelerate
import AVFoundation
import Foundation
@preconcurrency import Speech

/// One word the on-device speech engine heard, with its time in the file.
struct HeardWord: Sendable, Hashable {
    let token: String
    let time: Double
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
    /// Seconds of audio per recognition request (Apple limits server requests to about a minute).
    private static let chunkSeconds: Double = 55

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

    /// Transcribes the whole file (audio or music video). Returns nil when speech recognition isn't allowed or available.
    static func listen(
        to fileURL: URL,
        maxSeconds: Double = 15 * 60,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> [HeardWord]? {
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
        let totalChunks = max(1, Int(ceil(total / chunkSeconds)))
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
                heard.append(contentsOf: words)
                try? FileManager.default.removeItem(at: chunkURL)
            }
            start += chunkSeconds
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
                        return token.isEmpty ? nil : HeardWord(token: token, time: offset + seg.timestamp)
                    }
                    if gate.claim() { cont.resume(returning: (words, false)) }
                } else if error != nil {
                    let partialWords = result?.bestTranscription.segments.compactMap { seg -> HeardWord? in
                        let token = normalizeToken(seg.substring)
                        return token.isEmpty ? nil : HeardWord(token: token, time: offset + seg.timestamp)
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
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return nil }
        let anchors = alignmentAnchors(heard: heard, lines: lyrics.lines)
        guard !anchors.isEmpty else { return nil }

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
                    // Same tempo: interpolate smoothly.
                    return a.fileTime + (t - a.lyricTime) * slope
                }
                // A skit/break was inserted (or cut) between these two lines: keep each line glued
                // to the nearer anchor instead of stretching everything in between.
                let nearA = (t - a.lyricTime) <= (b.lyricTime - t)
                let ref = nearA ? a : b
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
                isInstrumentalBreak: line.isInstrumentalBreak
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
                isInstrumentalBreak: remapped[i].isInstrumentalBreak
            )
        }

        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Synced Lyrics · aligned to this file",
            attributionText: (lyrics.attributionText ?? "LRCLIB") + " · re-timed by listening (\(anchors.count) anchor lines)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: nil,
            lines: remapped
        )
    }

    // MARK: - Hybrid Automatic Whole-Song Aligner (STT + Acoustic Vocal-Band Cross-Correlation + Real-Time Word Timings)

    /// Automatically lines up ANY `lyrics` (both synced `.lrc` and plain/Genius text) against `fileURL`
    /// into real-time synced line + word timings with zero user input:
    ///   1. If `lyrics` are already time-synced: re-times them via whole-song STT word anchors, or falls back to
    ///      10 Hz vocal-band (300 Hz - 3.4 kHz) energy cross-correlation to remove intro/outro/tempo drift.
    ///   2. If `lyrics` are plain/untimed text: converts them into real-time synced lines (`isTimeSynced = true`)
    ///      using STT heard-word anchors across the song or the 10 Hz acoustic vocal-onset span.
    ///   3. Populates real-time word-by-word `LyricWordTiming` highlights anchored to heard words when available.
    static func autoAlign(lyrics: ResolvedTrackLyrics, heard: [HeardWord]?, fileURL: URL) async -> ResolvedTrackLyrics {
        guard !lyrics.lines.isEmpty else { return lyrics }

        var working = lyrics
        if working.isTimeSynced {
            if let heard, let sttAligned = align(lyrics: working, heard: heard) {
                working = sttAligned
            } else {
                working = await alignAcousticallyIfNeeded(lyrics: working, fileURL: fileURL)
            }
        } else {
            working = await alignPlainLyricsIntoRealTimeSync(lyrics: working, heard: heard, fileURL: fileURL)
        }
        return withRealTimeWordTimings(in: working, heard: heard)
    }

    private static func alignPlainLyricsIntoRealTimeSync(
        lyrics: ResolvedTrackLyrics,
        heard: [HeardWord]?,
        fileURL: URL
    ) async -> ResolvedTrackLyrics {
        let nonEmptyLines = lyrics.lines.filter { !$0.isInstrumentalBreak && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmptyLines.isEmpty else { return lyrics }

        let curve = await Task.detached(priority: .utility) {
            Self.extractVocalActivityCurve(from: fileURL)
        }.value
        let totalDuration = curve.map { Double($0.envelope.count) * $0.frameDurationSeconds } ?? lyrics.expectedDurationSeconds ?? 180.0
        guard totalDuration > 10 else { return lyrics }

        // Detect first & last true vocal entry from acoustic envelope to skip silent intros/outros.
        var firstVocalSec: Double = min(4.0, totalDuration * 0.08)
        var lastVocalSec: Double = max(firstVocalSec + 6.0, totalDuration - min(5.0, totalDuration * 0.05))
        if let curve, curve.envelope.count >= 40 {
            let dt = curve.frameDurationSeconds
            if let firstIdx = curve.envelope.firstIndex(where: { $0 > 0.12 }) {
                firstVocalSec = max(0, Double(firstIdx) * dt - 0.3)
            }
            if let lastIdx = curve.envelope.lastIndex(where: { $0 > 0.12 }) {
                lastVocalSec = min(totalDuration, max(firstVocalSec + 6.0, Double(lastIdx) * dt + 0.8))
            }
        }

        // Find monotonic anchors between line indices and actual heard vocal timestamps.
        var indexAnchors: [(lineIdx: Int, fileTime: Double)] = []
        if let heard, heard.count >= 6 {
            var rawHits: [(lineIdx: Int, fileTime: Double)] = []
            for (lIdx, line) in nonEmptyLines.enumerated() {
                let lineTokens = tokens(line.text)
                guard lineTokens.count >= 3 else { continue }
                let needed = Set(lineTokens)
                let window = lineTokens.count + 3
                var bestScore = 0.0
                var bestStart: Int?
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
                    if sc > bestScore, let firstHit {
                        bestScore = sc
                        bestStart = firstHit
                    }
                    i += 1
                }
                if bestScore >= 0.55, let bestStart {
                    rawHits.append((lIdx, max(0, heard[bestStart].time - 0.15)))
                }
            }

            if !rawHits.isEmpty {
                var len = Array(repeating: 1, count: rawHits.count)
                var prev = Array(repeating: -1, count: rawHits.count)
                for i in 0..<rawHits.count {
                    for j in 0..<i where rawHits[j].lineIdx < rawHits[i].lineIdx && rawHits[j].fileTime < rawHits[i].fileTime {
                        if len[j] + 1 > len[i] {
                            len[i] = len[j] + 1
                            prev[i] = j
                        }
                    }
                }
                if var cursor = len.indices.max(by: { len[$0] < len[$1] }) {
                    while cursor >= 0 {
                        indexAnchors.append(rawHits[cursor])
                        cursor = prev[cursor]
                    }
                    indexAnchors.reverse()
                }
            }
        }

        // Word-weight per line so longer lines get proportionally longer time slots.
        let weights: [Double] = nonEmptyLines.map { Double(max(2, tokens($0.text).count)) }
        var cumWeights = [Double](repeating: 0, count: nonEmptyLines.count + 1)
        for i in 0..<nonEmptyLines.count {
            cumWeights[i + 1] = cumWeights[i] + weights[i]
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
            return startTime + (endTime - startTime) * (relWeight / spanWeight)
        }

        var syncedLines: [SyncedLyricLine] = []
        syncedLines.reserveCapacity(nonEmptyLines.count)
        for idx in 0..<nonEmptyLines.count {
            let line = nonEmptyLines[idx]
            let prevEnd = idx > 0 ? syncedLines[idx - 1].startTime + 0.4 : 0
            let rawStart = max(prevEnd, timeForLine(idx))
            let nextStart = (idx + 1 < nonEmptyLines.count) ? max(rawStart + 0.6, timeForLine(idx + 1)) : min(totalDuration, rawStart + 4.5)
            let lineEnd = min(totalDuration, max(rawStart + 0.6, nextStart - 0.08))
            syncedLines.append(SyncedLyricLine(
                id: line.id,
                startTime: rawStart,
                endTime: lineEnd,
                text: line.text,
                words: [],
                isInstrumentalBreak: false
            ))
        }

        let note = indexAnchors.isEmpty
            ? "AI vocal-span real-time sync"
            : "AI audio-synced (\(indexAnchors.count) vocal anchors)"
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

    private static func withRealTimeWordTimings(in lyrics: ResolvedTrackLyrics, heard: [HeardWord]?) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return lyrics }

        let updatedLines: [SyncedLyricLine] = lyrics.lines.enumerated().map { idx, line in
            guard !line.isInstrumentalBreak, line.words.isEmpty else { return line }
            let rawWords = line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !rawWords.isEmpty else { return line }

            let fallbackNextStart = (idx + 1 < lyrics.lines.count)
                ? max(line.startTime + 0.6, lyrics.lines[idx + 1].startTime - 0.08)
                : max(line.startTime + 3.2, line.endTime)
            let lineEnd = max(line.startTime + 0.5, line.endTime > line.startTime + 0.25 ? line.endTime : fallbackNextStart)
            let span = lineEnd - line.startTime

            // Anchor any recognized words from STT near this line window; distribute others smoothly by character length.
            let localHeard: [HeardWord] = (heard ?? []).filter {
                $0.time >= line.startTime - 0.6 && $0.time <= lineEnd + 0.6
            }
            let totalChars = Double(rawWords.reduce(0) { $0 + max(1, $1.count) })
            var cursorTime = line.startTime
            var generatedWords: [LyricWordTiming] = []
            generatedWords.reserveCapacity(rawWords.count)

            for (wIdx, wordText) in rawWords.enumerated() {
                let normWord = normalizeToken(wordText)
                var wStart = cursorTime
                if !normWord.isEmpty,
                   let heardMatch = localHeard.first(where: { $0.token == normWord && $0.time >= cursorTime - 0.25 && $0.time <= lineEnd }) {
                    wStart = max(cursorTime, min(lineEnd - 0.08, heardMatch.time))
                }
                let share = Double(max(1, wordText.count)) / max(1.0, totalChars)
                let estDur = max(0.08, span * share)
                let wEnd = (wIdx == rawWords.count - 1) ? lineEnd : min(lineEnd, wStart + estDur)
                generatedWords.append(LyricWordTiming(text: wordText, startTime: wStart, endTime: max(wStart + 0.05, wEnd)))
                cursorTime = max(cursorTime, wEnd)
            }

            return SyncedLyricLine(
                id: line.id,
                startTime: line.startTime,
                endTime: lineEnd,
                text: line.text,
                words: generatedWords,
                isInstrumentalBreak: false
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

            func scoreShift(_ offset: Double) -> Double {
                var sum = 0.0
                var count = 0
                for pt in sampleTimes {
                    let t = pt.time + offset
                    guard t >= 0, t < actualDuration else { continue }
                    let idx = Int(t / dt)
                    guard idx >= 0, idx < curve.envelope.count else { continue }
                    let v = curve.envelope[idx] // centered around ~0 (-1 silent, +1 vocal active)
                    sum += pt.isSing ? v : (-v * 0.45)
                    count += 1
                }
                guard count > 0 else { return -Double.infinity }
                // Tiny prior preferring smaller shifts when scores tie.
                return (sum / Double(count)) - min(0.08, abs(offset) * 0.0012)
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
                isInstrumentalBreak: line.isInstrumentalBreak
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
            lines: remapped
        )
    }

    private struct VocalEnvelope {
        let frameDurationSeconds: Double
        /// Normalized centered vocal-band activity in roughly [-1, +1].
        let envelope: [Double]
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
        let hop = 1102 // ~0.10s per frame
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

        // At 11,025 Hz with N=1024 (~10.77 Hz/bin), bins 28..315 cover ~300 Hz - 3.4 kHz vocals.
        let lowBin = 28
        let highBin = min(halfN, 316)
        var rawEnergies: [Double] = []
        rawEnergies.reserveCapacity((samples.count - fftSize) / hop + 1)

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
            var vocalSum: Float = 0
            for b in lowBin..<highBin {
                vocalSum += mags[b]
            }
            rawEnergies.append(log1p(Double(vocalSum)))
            pos += hop
        }

        guard !rawEnergies.isEmpty else { return nil }
        let sorted = rawEnergies.sorted()
        let p20 = sorted[max(0, sorted.count / 5)]
        let p80 = sorted[min(sorted.count - 1, (sorted.count * 4) / 5)]
        let mid = (p20 + p80) * 0.5
        let spread = max(0.25, (p80 - p20) * 0.5)
        let centered = rawEnergies.map { min(1.0, max(-1.0, ($0 - mid) / spread)) }
        return VocalEnvelope(frameDurationSeconds: Double(hop) / sampleRate, envelope: centered)
    }

    /// Finds lyric lines that were clearly heard, and when. Keeps only anchors that move forward in
    /// both lyric time and file time (longest consistent chain), so a misheard word can't scramble timing.
    private static func alignmentAnchors(heard: [HeardWord], lines: [SyncedLyricLine]) -> [Anchor] {
        guard heard.count >= 6 else { return [] }
        var candidates: [Anchor] = []

        for line in lines where !line.isInstrumentalBreak {
            let lineTokens = tokens(line.text).filter { !$0.isEmpty }
            guard lineTokens.count >= 3 else { continue }
            let needed = Set(lineTokens)
            let window = lineTokens.count + 3
            var bestScore = 0.0
            var bestStart: Int?
            var i = 0
            while i < heard.count {
                let end = min(heard.count, i + window)
                var hits = Set<String>()
                var firstHit: Int?
                for j in i..<end where needed.contains(heard[j].token) {
                    if firstHit == nil { firstHit = j }
                    hits.insert(heard[j].token)
                }
                let score = Double(hits.count) / Double(needed.count)
                if score > bestScore, let firstHit {
                    bestScore = score
                    bestStart = firstHit
                }
                i += 1
            }
            if bestScore >= 0.6, let bestStart, Set(lineTokens).count >= 3 {
                candidates.append(Anchor(lyricTime: line.startTime, fileTime: max(0, heard[bestStart].time - 0.15)))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Longest chain increasing in both lyric time and file time.
        let sorted = candidates.sorted { $0.lyricTime < $1.lyricTime }
        var length = Array(repeating: 1, count: sorted.count)
        var previous = Array(repeating: -1, count: sorted.count)
        for i in 0..<sorted.count {
            for j in 0..<i where sorted[j].fileTime < sorted[i].fileTime && sorted[j].lyricTime < sorted[i].lyricTime {
                if length[j] + 1 > length[i] {
                    length[i] = length[j] + 1
                    previous[i] = j
                }
            }
        }
        guard var idx = length.indices.max(by: { length[$0] < length[$1] }) else { return [] }
        var chain: [Anchor] = []
        while idx >= 0 {
            chain.append(sorted[idx])
            idx = previous[idx]
        }
        return chain.reversed()
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
