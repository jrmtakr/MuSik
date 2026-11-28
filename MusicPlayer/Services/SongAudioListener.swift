import Accelerate
import AVFoundation
import CoreMedia
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

struct VocalBeatGrid: Sendable {
    let bpm: Double
    let periodSeconds: Double
    let phaseSeconds: Double
    let confidence: Double
}

struct VocalEnvelope: Sendable {
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
    let beatGrid: VocalBeatGrid?
    let spectralFrameDuration: Double
    /// Z-normalized 6-band log-energy spectral descriptors (~2.5 Hz) for chorus self-similarity.
    let spectralBands: [[Double]]
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

    struct ListenSummary: Sendable {
        let words: [HeardWord]
        let detectedLanguage: String?
        let isMostlyInstrumental: Bool
    }

    /// Detects obvious non-English script or catalog metadata hints so we don't run English-only Speech on foreign tracks.
    static func detectLanguageContext(title: String?, artist: String?) -> (isNonEnglish: Bool, speechLocaleID: String?, preferredITunesCountries: [String]) {
        let combined = [title ?? "", artist ?? ""].joined(separator: " ")
        var hasHiraganaOrKatakana = false
        var hasHan = false
        var hasHangul = false
        var hasCyrillic = false
        var hasArabic = false
        var hasSpanishOrPortuguese = false
        var hasFrench = false

        for scalar in combined.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0xFF65...0xFF9F).contains(v) {
                hasHiraganaOrKatakana = true
            } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                hasHan = true
            } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
                hasHangul = true
            } else if (0x0400...0x04FF).contains(v) {
                hasCyrillic = true
            } else if (0x0600...0x06FF).contains(v) {
                hasArabic = true
            }
        }
        let lower = combined.lowercased()
        if lower.contains("ñ") || lower.contains("á") || lower.contains("é") || lower.contains("í") || lower.contains("ó") || lower.contains("ú") || lower.contains("ã") || lower.contains("ç") {
            hasSpanishOrPortuguese = true
        }
        if lower.contains("à") || lower.contains("è") || lower.contains("ê") || lower.contains("î") || lower.contains("ô") || lower.contains("û") {
            hasFrench = true
        }

        let catalogGenre = artist.flatMap { ArtistDatabase.genre(forArtist: $0) } ?? ""
        let catalogKPopJPop = catalogGenre.localizedCaseInsensitiveContains("K-Pop") || catalogGenre.localizedCaseInsensitiveContains("J-Pop")
        let artistLower = (artist ?? "").lowercased()
        let knownFrenchArtist = artistLower == "lacrim" || artistLower == "stromae" || artistLower == "aya nakamura" || artistLower == "gims"
        let knownJapaneseName = lower.contains("ikasz") || lower.contains("ikasuze") || lower.contains("kashiwa") ||
            lower.contains("kaiware") || lower.contains("yasuha") || lower.contains("kokubu") ||
            lower.contains("nakashima") || lower.contains("anime") || lower.contains("city pop")

        if hasHiraganaOrKatakana || (hasHan && !hasHangul) || knownJapaneseName {
            return (true, "ja-JP", ["us", "jp"])
        }
        if hasHangul {
            return (true, "ko-KR", ["us", "kr"])
        }
        if catalogKPopJPop {
            let isLikelyKR = artistLower == "hyuna" || artistLower == "ikon" || artistLower == "bts" ||
                artistLower == "blackpink" || artistLower == "twice" || artistLower == "newjeans" ||
                artistLower == "stray kids" || artistLower == "jennie" || artistLower == "rosé"
            return (true, isLikelyKR ? "ko-KR" : "ja-JP", isLikelyKR ? ["us", "kr"] : ["us", "jp"])
        }
        if hasCyrillic {
            return (true, "ru-RU", ["us", "ru"])
        }
        if hasArabic {
            return (true, "ar-SA", ["us", "ae", "eg"])
        }
        if knownFrenchArtist || hasFrench {
            return (true, "fr-FR", ["us", "fr"])
        }
        if hasSpanishOrPortuguese {
            return (true, "es-ES", ["us", "mx", "es", "br"])
        }
        return (false, nil, ["us"])
    }

    static func hasInstrumentalFilenameHint(_ text: String) -> Bool {
        let norm = " \(normalizeTokenText(text)) "
        let keywords = [" instrumental ", " off vocal ", " karaoke ", " type beat ", " bgm ", " soundtrack "]
        return keywords.contains { norm.contains($0) }
    }

    private static func normalizeTokenText(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prepares an AVFoundation-readable audio file URL, remuxing FFmpeg containers (e.g. MKV/TS/WebM) to M4A or decoding Opus/FLAC/OGG to WAV.
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

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_dec_\(UUID().uuidString).wav")
        if FFmpegMediaService.decodeAudioToWAV(inputURL: fileURL, outputURL: wavURL),
           FileManager.default.fileExists(atPath: wavURL.path),
           !AVURLAsset(url: wavURL).tracks(withMediaType: .audio).isEmpty {
            return (wavURL, wavURL)
        }
        try? FileManager.default.removeItem(at: wavURL)
        return nil
    }

    /// Transcribes the whole file (audio or music video) and returns words + detected language + instrumental flag.
    static func listenWithSummary(
        to fileURL: URL,
        titleHint: String? = nil,
        artistHint: String? = nil,
        maxSeconds: Double = 15 * 60,
        allowModelDownload: Bool = true,
        languageHint: String? = nil,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> ListenSummary {
        let langCtx = detectLanguageContext(title: titleHint ?? fileURL.deletingPathExtension().lastPathComponent, artist: artistHint)
        let titleIsInstrumental = hasInstrumentalFilenameHint([titleHint ?? "", fileURL.deletingPathExtension().lastPathComponent].joined(separator: " "))
        let effectiveHint = languageHint ?? (langCtx.isNonEnglish ? nil : nil) // Allow Whisper auto language ID

        if let summary = await WhisperTranscriptionEngine.shared.transcribeWholeFileSummary(
            fileURL: fileURL,
            maxSeconds: maxSeconds,
            allowDownload: allowModelDownload,
            languageHint: effectiveHint,
            onProgress: onProgress
        ) {
            let heardWords = summary.words.map {
                HeardWord(token: $0.token, rawText: $0.rawText, time: $0.startTime, endTime: $0.endTime)
            }
            let meaningfulCount = heardWords.filter { $0.token.count >= 3 && !stopWords.contains($0.token) }.count
            let wpm = Double(heardWords.count) / max(0.5, summary.durationSeconds / 60.0)
            let isInst = titleIsInstrumental
                || heardWords.isEmpty
                || summary.avgNoSpeechProb >= 0.72
                || meaningfulCount < 10
                || (summary.durationSeconds >= 45 && wpm < 7.0)
            return ListenSummary(
                words: heardWords,
                detectedLanguage: summary.detectedLanguage ?? (langCtx.isNonEnglish ? langCtx.speechLocaleID : nil),
                isMostlyInstrumental: isInst
            )
        }

        // If the track title/artist clearly points to a non-English language and Apple Speech doesn't support that locale
        // on-device, never run English Speech to invent phonetic English gibberish!
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return ListenSummary(words: [], detectedLanguage: langCtx.speechLocaleID, isMostlyInstrumental: titleIsInstrumental)
        }

        let recognizer: SFSpeechRecognizer? = {
            if let localeID = langCtx.speechLocaleID {
                let foreignRec = SFSpeechRecognizer(locale: Locale(identifier: localeID))
                return (foreignRec?.isAvailable == true) ? foreignRec : nil
            }
            return SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
                ?? SFSpeechRecognizer()
        }()
        guard let recognizer, recognizer.isAvailable else {
            return ListenSummary(words: [], detectedLanguage: langCtx.speechLocaleID, isMostlyInstrumental: titleIsInstrumental)
        }

        guard let prepared = prepareReadableAudioFile(for: fileURL) else {
            return ListenSummary(words: [], detectedLanguage: langCtx.speechLocaleID, isMostlyInstrumental: titleIsInstrumental)
        }
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        let asset = AVURLAsset(url: prepared.url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 3 else {
            return ListenSummary(words: [], detectedLanguage: langCtx.speechLocaleID, isMostlyInstrumental: titleIsInstrumental)
        }

        let total = min(duration, maxSeconds)
        var windows: [(idx: Int, start: Double, length: Double)] = []
        var cursor: Double = 0
        var idxCounter = 0
        while cursor < total {
            let length = min(chunkSeconds, total - cursor)
            if length < 2 { break }
            idxCounter += 1
            windows.append((idxCounter, cursor, length))
            if cursor + length >= total { break }
            cursor += chunkStepSeconds
        }
        let totalChunks = max(1, windows.count)
        let hasVideoTrack = !asset.tracks(withMediaType: .video).isEmpty
        let preparedAudioURL = prepared.url
        var chunkWords = Array<[HeardWord]>(repeating: [], count: windows.count)
        var completedChunks = 0
        var nextWindowIdx = 0
        let concurrency = min(3, windows.count)

        await withTaskGroup(of: (Int, [HeardWord]).self) { group in
            while nextWindowIdx < concurrency {
                let win = windows[nextWindowIdx]
                nextWindowIdx += 1
                group.addTask {
                    guard !Task.isCancelled else { return (win.idx - 1, []) }
                    guard let chunkURL = await exportAudioChunk(
                        fileURL: preparedAudioURL,
                        start: win.start,
                        length: win.length,
                        preferDirectPCM: hasVideoTrack
                    ) else {
                        return (win.idx - 1, [])
                    }
                    defer { try? FileManager.default.removeItem(at: chunkURL) }
                    let words = await recognize(url: chunkURL, recognizer: recognizer, offset: win.start)
                    return (win.idx - 1, words)
                }
            }
            for await (slotIdx, words) in group {
                chunkWords[slotIdx] = words
                completedChunks += 1
                onProgress?(completedChunks, totalChunks, total)
                if !Task.isCancelled && nextWindowIdx < windows.count {
                    let win = windows[nextWindowIdx]
                    nextWindowIdx += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (win.idx - 1, []) }
                        guard let chunkURL = await exportAudioChunk(
                            fileURL: preparedAudioURL,
                            start: win.start,
                            length: win.length,
                            preferDirectPCM: hasVideoTrack
                        ) else {
                            return (win.idx - 1, [])
                        }
                        defer { try? FileManager.default.removeItem(at: chunkURL) }
                        let words = await recognize(url: chunkURL, recognizer: recognizer, offset: win.start)
                        return (win.idx - 1, words)
                    }
                }
            }
        }

        var heard: [HeardWord] = []
        for words in chunkWords {
            for w in words {
                if let prev = heard.last, abs(w.time - prev.time) < 0.30, w.token == prev.token {
                    continue
                }
                if let prev = heard.last, w.time < prev.time - 0.05 {
                    continue
                }
                heard.append(w)
            }
        }
        let meaningfulCount = heard.filter { $0.token.count >= 3 && !stopWords.contains($0.token) }.count
        let wpm = Double(heard.count) / max(0.5, total / 60.0)
        let isInst = titleIsInstrumental || heard.isEmpty || meaningfulCount < 10 || (total >= 45 && wpm < 7.0)
        return ListenSummary(
            words: heard,
            detectedLanguage: langCtx.speechLocaleID,
            isMostlyInstrumental: isInst
        )
    }

    static func listen(
        to fileURL: URL,
        maxSeconds: Double = 15 * 60,
        languageHint: String? = nil,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> [HeardWord]? {
        let summary = await listenWithSummary(
            to: fileURL,
            maxSeconds: maxSeconds,
            languageHint: languageHint,
            onProgress: onProgress
        )
        return summary.words.isEmpty ? nil : summary.words
    }

    private static func exportAudioChunk(
        fileURL: URL,
        start: Double,
        length: Double,
        preferDirectPCM: Bool = false
    ) async -> URL? {
        if preferDirectPCM {
            if let wav = await Task.detached(priority: .userInitiated, operation: {
                let readerAsset = AVURLAsset(url: fileURL)
                return exportWAVChunkWithAssetReader(asset: readerAsset, start: start, length: length)
            }).value {
                return wav
            }
        }
        let sessionAsset = AVURLAsset(url: fileURL)
        if let session = AVAssetExportSession(asset: sessionAsset, presetName: AVAssetExportPresetAppleM4A) {
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
            let fallbackAsset = AVURLAsset(url: fileURL)
            return exportWAVChunkWithAssetReader(asset: fallbackAsset, start: start, length: length)
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

        final class RecognitionSessionGate: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            private var task: SFSpeechRecognitionTask?
            private var continuation: CheckedContinuation<([HeardWord], Bool), Never>?

            func bind(task: SFSpeechRecognitionTask, cont: CheckedContinuation<([HeardWord], Bool), Never>) {
                lock.lock()
                if finished {
                    lock.unlock()
                    task.cancel()
                    cont.resume(returning: ([], true))
                    return
                }
                self.task = task
                self.continuation = cont
                lock.unlock()
            }

            func finish(words: [HeardWord], hadError: Bool) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                let cont = continuation
                continuation = nil
                task = nil
                lock.unlock()
                cont?.resume(returning: (words, hadError))
            }

            func cancelAndFinish() {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                let activeTask = task
                let cont = continuation
                task = nil
                continuation = nil
                lock.unlock()
                activeTask?.cancel()
                cont?.resume(returning: ([], true))
            }
        }

        let gate = RecognitionSessionGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<([HeardWord], Bool), Never>) in
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
                        gate.finish(words: words, hadError: false)
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
                        gate.finish(words: partialWords, hadError: true)
                    }
                }
                gate.bind(task: task, cont: cont)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 24) {
                    gate.cancelAndFinish()
                }
            }
        } onCancel: {
            gate.cancelAndFinish()
        }
    }

    // MARK: - Confirming the song name & exact version

    struct VersionAlignmentReport: Sendable {
        let globalMatchRatio: Double
        let sungSectionCoverage: Double
        let lyricStanzaCoverage: Double
        let anchorsCount: Int
        let unmatchedActiveWindows: Int
        let totalActiveWindows: Int
        let unheardStanzas: Int
        let totalStanzas: Int
        let verdict: ListeningVerdict

        /// Combined confidence score favoring candidates where sung sections and lyric stanzas agree in both directions.
        var compositeScore: Double {
            (globalMatchRatio * 0.40)
                + (sungSectionCoverage * 0.30)
                + (lyricStanzaCoverage * 0.30)
                + min(0.25, Double(anchorsCount) * 0.025)
                - (Double(unmatchedActiveWindows) * 0.08)
                - (Double(unheardStanzas) * 0.08)
        }
    }

    /// Compares heard audio against lyrics symmetrically: verifies both that active sung sections
    /// match words in the lyrics AND that the lyrics' stanzas actually occur in the audio.
    static func versionAlignmentConfidence(heard: [HeardWord], lyrics: ResolvedTrackLyrics) -> VersionAlignmentReport {
        let meaningfulHeard = heard.filter { $0.token.count >= 3 && !stopWords.contains($0.token) }
        guard meaningfulHeard.count >= 25 else {
            return VersionAlignmentReport(
                globalMatchRatio: 0,
                sungSectionCoverage: 0,
                lyricStanzaCoverage: 0,
                anchorsCount: 0,
                unmatchedActiveWindows: 0,
                totalActiveWindows: 0,
                unheardStanzas: 0,
                totalStanzas: 0,
                verdict: .inconclusive
            )
        }

        var lyricVocabulary = Set<String>()
        for line in lyrics.lines where !line.isInstrumentalBreak && !line.isSpokenDialogue {
            for token in tokens(line.text) where token.count >= 3 && !stopWords.contains(token) {
                lyricVocabulary.insert(token)
            }
        }
        guard lyricVocabulary.count >= 15 else {
            return VersionAlignmentReport(
                globalMatchRatio: 0,
                sungSectionCoverage: 0,
                lyricStanzaCoverage: 0,
                anchorsCount: 0,
                unmatchedActiveWindows: 0,
                totalActiveWindows: 0,
                unheardStanzas: 0,
                totalStanzas: 0,
                verdict: .inconclusive
            )
        }

        let matched = meaningfulHeard.filter { lyricVocabulary.contains($0.token) }.count
        let ratio = Double(matched) / Double(meaningfulHeard.count)
        let anchors = lyrics.isTimeSynced ? alignmentAnchors(heard: heard, lines: lyrics.lines).count : 0

        // 1. Forward check: 30s active vocal windows in the audio must be represented in the candidate lyrics.
        var windowBuckets: [Int: [String]] = [:]
        var maxHeardTime: Double = 0
        for w in meaningfulHeard {
            if w.time > maxHeardTime { maxHeardTime = w.time }
            let bucket = max(0, Int(floor(w.time / 30.0)))
            windowBuckets[bucket, default: []].append(w.token)
        }
        let activeWindows = windowBuckets.keys.sorted().compactMap { key -> [String]? in
            let toks = windowBuckets[key] ?? []
            return toks.count >= 8 ? toks : nil
        }
        var coveredWindows = 0
        for toks in activeWindows {
            let hits = toks.filter { lyricVocabulary.contains($0) }.count
            let distinctHits = Set(toks).intersection(lyricVocabulary).count
            let windowRatio = Double(hits) / Double(toks.count)
            if windowRatio >= 0.16 && distinctHits >= 2 {
                coveredWindows += 1
            }
        }
        let totalActiveWindows = activeWindows.count
        let unmatchedActiveWindows = totalActiveWindows - coveredWindows
        let sungSectionCoverage = totalActiveWindows > 0
            ? Double(coveredWindows) / Double(totalActiveWindows)
            : ratio

        // 2. Reverse check: 4-line vocal stanzas in candidate lyrics must actually appear in the audio.
        let heardVocab = Set(meaningfulHeard.map(\.token))
        let vocalLines = lyrics.lines.filter { !$0.isInstrumentalBreak && !$0.isSpokenDialogue }
        var stanzas: [Set<String>] = []
        var idx = 0
        while idx < vocalLines.count {
            let end = min(vocalLines.count, idx + 4)
            let chunk = Array(vocalLines[idx..<end])
            idx = end
            // Only evaluate stanzas inside the transcribed span when maxSeconds (900s) truncated long audio.
            if maxHeardTime > 850, let firstStart = chunk.first?.startTime, firstStart > maxHeardTime + 15 {
                continue
            }
            var chunkTokens = Set<String>()
            for line in chunk {
                for t in tokens(line.text) where t.count >= 3 && !stopWords.contains(t) {
                    chunkTokens.insert(t)
                }
            }
            if chunkTokens.count >= 6 {
                stanzas.append(chunkTokens)
            }
        }
        var coveredStanzas = 0
        for stanza in stanzas {
            let hits = stanza.intersection(heardVocab).count
            let stanzaRatio = Double(hits) / Double(stanza.count)
            if stanzaRatio >= 0.18 && hits >= 2 {
                coveredStanzas += 1
            }
        }
        let totalStanzas = stanzas.count
        let unheardStanzas = totalStanzas - coveredStanzas
        let lyricStanzaCoverage = totalStanzas > 0
            ? Double(coveredStanzas) / Double(totalStanzas)
            : ratio

        let verdict: ListeningVerdict
        if ratio < 0.10 && anchors == 0 && meaningfulHeard.count >= 60 {
            verdict = .contradicted(matchRatio: ratio)
        } else if totalActiveWindows >= 3 && unmatchedActiveWindows >= 2 && sungSectionCoverage < 0.58 {
            verdict = .contradicted(matchRatio: ratio)
        } else if totalStanzas >= 3 && unheardStanzas >= 2 && lyricStanzaCoverage < 0.58 && meaningfulHeard.count >= 45 {
            verdict = .contradicted(matchRatio: ratio)
        } else if totalActiveWindows >= 3 && unmatchedActiveWindows >= 1 && unheardStanzas >= 1 &&
                    (sungSectionCoverage < 0.72 || lyricStanzaCoverage < 0.72) && ratio < 0.42 {
            verdict = .contradicted(matchRatio: ratio)
        } else if ratio >= 0.3 || anchors >= 4 {
            verdict = .confirmed(matchRatio: ratio)
        } else {
            verdict = .inconclusive
        }

        return VersionAlignmentReport(
            globalMatchRatio: ratio,
            sungSectionCoverage: sungSectionCoverage,
            lyricStanzaCoverage: lyricStanzaCoverage,
            anchorsCount: anchors,
            unmatchedActiveWindows: unmatchedActiveWindows,
            totalActiveWindows: totalActiveWindows,
            unheardStanzas: unheardStanzas,
            totalStanzas: totalStanzas,
            verdict: verdict
        )
    }

    /// Compares what was heard with the lyrics of the proposed song.
    static func verdict(heard: [HeardWord], lyrics: ResolvedTrackLyrics) -> ListeningVerdict {
        versionAlignmentConfidence(heard: heard, lyrics: lyrics).verdict
    }

    /// Returns true when `heard` shares a real ordered phrase or >= 3 monotonic lyric anchors (prevents bag-of-words mislabels).
    static func hasOrderedPhraseMatch(heard: [HeardWord], lyrics: ResolvedTrackLyrics) -> Bool {
        guard heard.count >= 6, !lyrics.lines.isEmpty else { return false }
        if lyrics.isTimeSynced && alignmentAnchors(heard: heard, lines: lyrics.lines).count >= 3 {
            return true
        }
        // Check contiguous 4-word phrases anywhere in heard transcript (for plain lyrics or unsynced drafts).
        let heardNorms = heard.map(\.token)
        for line in lyrics.lines where !line.isInstrumentalBreak {
            let toks = tokens(line.text)
            guard toks.count >= 4 else { continue }
            for k in 0...(toks.count - 4) {
                let target = Array(toks[k..<(k + 4)])
                let contentCount = target.filter { $0.count >= 3 && !stopWords.contains($0) }.count
                guard contentCount >= 2 else { continue }
                for h in 0...(heardNorms.count - 4) {
                    var matched = 0
                    var cursor = h
                    let hEnd = min(heardNorms.count, h + 6)
                    for wt in target {
                        while cursor < hEnd && heardNorms[cursor] != wt { cursor += 1 }
                        if cursor < hEnd {
                            matched += 1
                            cursor += 1
                        }
                    }
                    if matched == 4 { return true }
                }
            }
        }
        return false
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
        curve: VocalEnvelope?,
        preserveUncoveredSections: Bool = false
    ) -> ResolvedTrackLyrics? {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return nil }
        let anchors = alignmentAnchors(heard: heard, lines: lyrics.lines)
        guard anchors.count >= 4 else { return nil }
        let anchorSpan = (anchors.last?.lyricTime ?? 0) - (anchors.first?.lyricTime ?? 0)
        let totalSpan = max(1.0, (lyrics.lines.last?.startTime ?? 0) - (lyrics.lines.first?.startTime ?? 0))
        guard anchorSpan >= 20.0 || anchorSpan >= totalSpan * 0.25 else { return nil }

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
            if t <= anchors[0].lyricTime {
                let firstDelta = anchors[0].fileTime - anchors[0].lyricTime
                if preserveUncoveredSections && abs(firstDelta) > 4.0 {
                    return t
                }
                return t + firstDelta
            }
            if let last = anchors.last, t >= last.lyricTime {
                let lastDelta = last.fileTime - last.lyricTime
                if preserveUncoveredSections && abs(lastDelta) > 4.0 {
                    return t
                }
                return t + lastDelta
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
                LyricWordTiming(
                    id: $0.id,
                    text: $0.text,
                    startTime: max(0, map($0.startTime)),
                    endTime: max(0, map($0.endTime)),
                    hasTrailingSpace: $0.hasTrailingSpace
                )
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

    static func extractVocalCurve(for fileURL: URL) async -> VocalEnvelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return await Task.detached(priority: .utility) {
            Self.extractVocalActivityCurve(from: fileURL)
        }.value
    }

    nonisolated static func isCreditOrHeaderLine(_ text: String, isIntroRegion: Bool = true) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        let cjkCreditPrefixes = [
            "詞:", "詞：", "曲:", "曲：", "歌:", "歌：",
            "作詞", "作曲", "編曲", "作词", "编曲", "制作人", "演唱",
            "tme", "original karaoke", "off vocal"
        ]
        if cjkCreditPrefixes.contains(where: { lower.contains($0) }) {
            return true
        }
        if lower.range(
            of: #"\b(?:produced|written|composed|lyrics|arranged|mixed|mastered)\s+by\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if isIntroRegion && (
            lower.hasPrefix("composer:")
                || lower.hasPrefix("lyricist:")
                || lower.hasPrefix("producer:")
                || lower.hasPrefix("arranger:")
        ) {
            return true
        }
        return false
    }

    private static func stripCreditHeaderLines(from lyrics: ResolvedTrackLyrics) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return lyrics }
        var vocalIdx = 0
        let filtered = lyrics.lines.filter { line in
            if line.isInstrumentalBreak { return true }
            defer { vocalIdx += 1 }
            return !isCreditOrHeaderLine(line.text, isIntroRegion: vocalIdx < 4 || line.startTime < 35.0)
        }
        guard filtered.count != lyrics.lines.count else { return lyrics }
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
            alignmentVersion: lyrics.alignmentVersion,
            lines: filtered
        )
    }

    /// Evaluates how well a candidate's synced timestamps match the file's singing activity and 43 Hz vocal phrase onsets.
    static func acousticTimingScore(for lyrics: ResolvedTrackLyrics, curve: VocalEnvelope) -> Double {
        guard lyrics.isTimeSynced,
              !curve.fastVocalEnvelope.isEmpty,
              !curve.singingEnvelope.isEmpty else {
            return 0
        }
        let fastDt = curve.fastFrameDurationSeconds
        let fastDur = Double(curve.fastVocalEnvelope.count) * fastDt
        let lines = lyrics.lines.filter { !$0.isInstrumentalBreak && !$0.isSpokenDialogue && !isCreditOrHeaderLine($0.text) }
        guard lines.count >= 4 else { return 0 }

        func meanEnv(in env: [Double], dt: Double, from s: Double, to e: Double) -> Double {
            guard e > s, !env.isEmpty else { return 0 }
            let i0 = max(0, min(env.count - 1, Int(s / dt)))
            let i1 = max(i0 + 1, min(env.count, Int(e / dt)))
            let slice = env[i0..<i1]
            return slice.reduce(0, +) / Double(max(1, slice.count))
        }

        func evalZeroShift(_ shift: Double) -> Double {
            var activeSum = 0.0
            var onsetContrastSum = 0.0
            var onsetCount = 0
            for (idx, ln) in lines.enumerated() {
                let s = ln.startTime + shift
                let e = ln.endTime + shift
                guard s >= 0.2, s + 0.35 < fastDur else { continue }
                activeSum += meanEnv(in: curve.singingEnvelope, dt: curve.frameDurationSeconds, from: s, to: min(e, s + 2.5))
                let prevGap = idx > 0 ? (ln.startTime - lines[idx - 1].endTime) : s
                if prevGap >= 0.30 {
                    let after = meanEnv(in: curve.fastVocalEnvelope, dt: fastDt, from: s, to: s + 0.30)
                    let before = meanEnv(in: curve.fastVocalEnvelope, dt: fastDt, from: max(0, s - 0.35), to: max(0.02, s - 0.06))
                    onsetContrastSum += (after - before)
                    onsetCount += 1
                }
            }
            let actScore = activeSum / Double(max(1, lines.count))
            let contrastScore = onsetCount > 0 ? (onsetContrastSum / Double(onsetCount)) : 0
            return actScore + 1.35 * contrastScore
        }

        let atZero = evalZeroShift(0)
        var bestShifted = atZero
        var bestLag = 0.0
        var off = -2.4
        while off <= 2.41 {
            let sc = evalZeroShift(off)
            if sc > bestShifted {
                bestShifted = sc
                bestLag = off
            }
            off += 0.12
        }
        let lagPenalty = abs(bestLag) > 0.25 && (bestShifted - atZero) > 0.04 ? min(0.55, abs(bestLag) * 0.24) : 0.0
        return atZero - lagPenalty
    }

    // MARK: - Hybrid Automatic Whole-Song Aligner (Whisper/STT + Section-DTW + Real-Time Word & Dialogue Timings)

    /// Automatically lines up ANY `lyrics` against `fileURL` into real-time synced line, word, and spoken dialogue timings.
    static func autoAlign(
        lyrics: ResolvedTrackLyrics,
        heard: [HeardWord]?,
        fileURL: URL,
        precomputedCurve: VocalEnvelope? = nil
    ) async -> ResolvedTrackLyrics {
        guard !lyrics.lines.isEmpty else { return lyrics }

        let curve: VocalEnvelope?
        if let precomputedCurve {
            curve = precomputedCurve
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            curve = await Task.detached(priority: .utility) { Self.extractVocalActivityCurve(from: fileURL) }.value
        } else {
            curve = nil
        }

        var working = stripCreditHeaderLines(from: lyrics)
        if working.isTimeSynced {
            // 1. Always run acoustic / Section-DTW alignment first using harmonic singing envelope
            //    so skits/intros/breaks are locked across sections even when ASR missed parts of the song.
            let acousticallyAligned = alignAcousticallyInternal(lyrics: working, curve: curve)
            let hadSectionDTW = acousticallyAligned.attributionText?.contains("section-DTW") == true
            working = acousticallyAligned

            // 2. Refine individual lines using >= 4 ordered multi-section heard anchors without clobbering uncovered sections.
            if let heard, let sttRefined = alignWithAnchors(
                lyrics: working,
                heard: heard,
                curve: curve,
                preserveUncoveredSections: hadSectionDTW
            ) {
                working = sttRefined
            }
        } else {
            working = alignPlainLyricsIntoRealTimeSync(lyrics: working, heard: heard, curve: curve)
        }
        working = reconcileLyricsWithAudio(in: working, heard: heard, curve: curve)
        working = refinePerLineVocalOnsets(in: working, curve: curve)
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
        let nonEmptyLines = lyrics.lines.filter { line in
            guard !line.isInstrumentalBreak else { return false }
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            if t.hasPrefix("[") && t.hasSuffix("]") { return false }
            return true
        }
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
            // Only push `firstVocalSec` later when there isn't already sustained singing between `firstVocalSec`
            // and `heardFirst.time` (so ASR missing a quiet/distorted Verse 1 doesn't shift the whole song late).
            var sustainedBeforeHeard = 0
            if let curve, let singingEnv, singingEnv.count >= 40 {
                let dt = curve.frameDurationSeconds
                let sIdx = max(0, Int((firstVocalSec + 0.3) / dt))
                let eIdx = min(singingEnv.count, Int((heardFirst.time - 0.5) / dt))
                if eIdx > sIdx {
                    sustainedBeforeHeard = singingEnv[sIdx..<eIdx].filter { $0 > 0.08 }.count
                }
            }
            if sustainedBeforeHeard < 8 {
                firstVocalSec = max(0, heardFirst.time - 0.35)
            }
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
        let note = details.isEmpty ? "Vocal-energy real-time sync" : "Audio-synced (\(details.joined(separator: ", ")))"
        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Real-Time Synced Lyrics",
            attributionText: (lyrics.attributionText ?? "Auto Sync") + " · \(note)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: totalDuration,
            lines: syncedLines
        )
    }

    /// Builds synced lyric lines with word-level timings from a sorted slice of transcribed words.
    private static func buildSyncedLines(
        from sortedWords: [HeardWord],
        totalDuration: Double,
        includeLeadingBreak: Bool,
        includeGapBreaks: Bool,
        maxEndTime: Double? = nil
    ) -> [SyncedLyricLine] {
        guard !sortedWords.isEmpty else { return [] }
        let capEnd = maxEndTime ?? totalDuration
        var groups: [[HeardWord]] = []
        var cur: [HeardWord] = []
        for w in sortedWords {
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
        if includeLeadingBreak, let firstTime = groups.first?.first?.time, firstTime > 5.5 {
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
                return min(capEnd, last.time + 2.5)
            }()
            let lineEnd = min(capEnd, max(first.time + 0.35, min(last.time + 0.45, nextStart - 0.08)))
            let wordTimings = group.enumerated().map { wIdx, w in
                let wNext = (wIdx + 1 < group.count) ? group[wIdx + 1].time : lineEnd
                let wEnd = max(w.time + 0.08, min(lineEnd, wNext))
                return LyricWordTiming(text: w.rawText, startTime: w.time, endTime: wEnd)
            }
            lines.append(SyncedLyricLine(
                startTime: first.time,
                endTime: lineEnd,
                text: group.map(\.rawText).joined(separator: " "),
                words: wordTimings,
                isInstrumentalBreak: false,
                hasNativeWordTimings: true
            ))
            let gap = nextStart - lineEnd
            if includeGapBreaks && idx + 1 < groups.count && gap >= 7.0 {
                lines.append(SyncedLyricLine(
                    startTime: lineEnd + 0.35,
                    endTime: max(lineEnd + 1.0, nextStart - 0.35),
                    text: "",
                    words: [],
                    isInstrumentalBreak: true
                ))
            }
        }
        return lines
    }

    /// Reconciles online synced lines against actual heard vocals and the harmonic singing envelope
    /// so phantom alternate-version intros/ad-libs are removed, swapped verses are replaced with
    /// what this audio actually sings, and unambiguous censored masks reflect heard vocals.
    private static func reconcileLyricsWithAudio(
        in lyrics: ResolvedTrackLyrics,
        heard: [HeardWord]?,
        curve: VocalEnvelope?
    ) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return lyrics }

        let sortedHeard = (heard ?? [])
            .filter { !$0.token.isEmpty }
            .sorted { $0.time < $1.time }
        guard !sortedHeard.isEmpty || curve != nil else { return lyrics }

        let curveDuration = curve.map {
            let count = $0.singingEnvelope.isEmpty ? $0.envelope.count : $0.singingEnvelope.count
            return Double(count) * $0.frameDurationSeconds
        } ?? 0
        let maxHeardTime = (sortedHeard.last?.time ?? 0) + 1.0
        let maxAudioTime = max(curveDuration, maxHeardTime)

        func tokensMatch(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            if a.count >= 4 && b.count >= 4 && a.prefix(4) == b.prefix(4) { return true }
            return false
        }

        func heardSlice(from start: Double, to end: Double) -> [HeardWord] {
            sortedHeard.filter { $0.time >= start && $0.time <= end }
        }

        func isQuietInCurve(from start: Double, to end: Double, strict: Bool = false) -> Bool {
            guard let curve else { return false }
            if maxAudioTime > 2.0 && start >= maxAudioTime - 1.5 { return false }
            let env = curve.singingEnvelope.isEmpty ? curve.envelope : curve.singingEnvelope
            guard !env.isEmpty else { return false }
            let dt = curve.frameDurationSeconds
            let i0 = max(0, min(env.count - 1, Int(floor(max(0, start) / dt))))
            let i1 = max(i0 + 1, min(env.count, Int(ceil(max(start + 0.3, end) / dt))))
            guard i1 > i0 else { return false }
            let slice = env[i0..<i1]
            let mean = slice.reduce(0, +) / Double(slice.count)
            let activeCount = slice.filter { $0 > 0.08 }.count
            let activeFrac = Double(activeCount) / Double(slice.count)
            let peak = slice.max() ?? -1.0
            if strict {
                return mean <= -0.14 && activeFrac < 0.14 && peak < 0.18
            }
            return mean <= -0.05 && activeFrac < 0.20 && peak < 0.25
        }

        func hasCoOccurringPhraseAnywhere(_ contentTokens: [String], windowSeconds: Double = 6.0) -> Bool {
            guard !contentTokens.isEmpty, !sortedHeard.isEmpty else { return false }
            let uniqueTargets = Array(Set(contentTokens))
            let needed = uniqueTargets.count <= 1 ? 1 : min(uniqueTargets.count, 2)
            for idx in 0..<sortedHeard.count {
                let winEnd = sortedHeard[idx].time + windowSeconds
                var matchedTargets = 0
                for target in uniqueTargets {
                    var j = idx
                    var hit = false
                    while j < sortedHeard.count && sortedHeard[j].time <= winEnd {
                        if tokensMatch(target, sortedHeard[j].token) {
                            hit = true
                            break
                        }
                        j += 1
                    }
                    if hit { matchedTargets += 1 }
                }
                if matchedTargets >= needed { return true }
            }
            return false
        }

        // Guard against English ASR mis-transcribing non-English tracks.
        let nonBreakTexts = lyrics.lines.filter { !$0.isInstrumentalBreak }.map(\.text)
        let joinedLyrics = nonBreakTexts.joined(separator: " ")
        let hasNonLatin = joinedLyrics.unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(scalar.value) ||
            (0x0600...0x06FF).contains(scalar.value) ||
            (0x0900...0x097F).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
        let foreignStopWords: Set<String> = [
            "que", "para", "como", "pero", "donde", "amor", "corazon", "por", "con", "una", "las", "los",
            "dans", "pour", "avec", "nous", "vous", "est", "pas", "une", "ich", "und", "der", "die", "das", "nicht",
            "che", "non", "per", "sono"
        ]
        let lyricTokensAll = tokens(joinedLyrics)
        let foreignStopHits = lyricTokensAll.filter { foreignStopWords.contains($0) }.count
        let isForeignLyrics = hasNonLatin || foreignStopHits >= 6 || detectLanguageContext(
            title: lyrics.trackTitle,
            artist: lyrics.artistName.isEmpty ? nil : lyrics.artistName
        ).isNonEnglish
        let heardVocab = Set(sortedHeard.map(\.token))
        let meaningfulLyricToks = lyricTokensAll.filter { $0.count >= 3 && !stopWords.contains($0) }
        let globalLyricOverlap: Double = {
            guard !meaningfulLyricToks.isEmpty else { return 0 }
            let hits = meaningfulLyricToks.filter { lt in
                heardVocab.contains(where: { tokensMatch(lt, $0) })
            }.count
            return Double(hits) / Double(meaningfulLyricToks.count)
        }()
        let englishASROnForeign = isForeignLyrics && sortedHeard.count >= 15 && globalLyricOverlap < 0.12
        let canUseWordReconciliation = !englishASROnForeign && sortedHeard.count >= 12

        // Pass 1: Clean phantom parentheticals, drop strictly silent phantom intro/outro/parenthetical lines,
        // and restore unambiguous asterisk-censored words that were actually spoken/sung cleanly.
        let parenRegex = try? NSRegularExpression(pattern: #"\(([^()]+)\)"#)
        let maskRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{1,2}\*{1,}[A-Za-z]*)(?![A-Za-z0-9*])"#)
        let profanityAllowlist: Set<String> = [
            "fuck", "fucking", "fucked", "fucker", "motherfucker", "shit", "shitty",
            "bitch", "bitches", "nigga", "niggas", "nigger", "pussy", "cock", "dick",
            "damn", "ass", "hoe", "hoes", "slut", "whore"
        ]

        let groundedIndices: [Int] = lyrics.lines.enumerated().compactMap { idx, ln in
            guard !ln.isInstrumentalBreak, !(maxAudioTime > 2.0 && ln.startTime >= maxAudioTime - 1.5) else {
                return nil
            }
            let content = tokens(ln.text).filter { $0.count >= 3 && !stopWords.contains($0) }
            guard !content.isEmpty else { return nil }
            let localH = heardSlice(from: ln.startTime - 3.0, to: max(ln.endTime, ln.startTime + 2.0) + 3.0)
            let hitCount = content.filter { lt in localH.contains(where: { tokensMatch(lt, $0.token) }) }.count
            return hitCount >= 1 ? idx : nil
        }
        let firstGroundedIdx = groundedIndices.first ?? lyrics.lines.count
        let lastGroundedIdx = groundedIndices.last ?? -1

        var pass1Lines: [SyncedLyricLine] = []
        for idx in 0..<lyrics.lines.count {
            var line = lyrics.lines[idx]
            if line.isInstrumentalBreak || (maxAudioTime > 2.0 && line.startTime >= maxAudioTime - 1.5) {
                pass1Lines.append(line)
                continue
            }

            let winStart = line.startTime - 2.5
            let winEnd = max(line.endTime, line.startTime + 2.0) + 3.5
            let localHeard = heardSlice(from: winStart, to: winEnd)
            let quietHere = isQuietInCurve(from: line.startTime, to: max(line.startTime + 0.8, line.endTime), strict: false)
            let quietStrict = isQuietInCurve(from: line.startTime, to: max(line.startTime + 0.8, line.endTime), strict: true)

            // Strip any parenthetical ad-lib / sample `( ... )` absent locally and across the track.
            var textAfterParens = line.text
            if let parenRegex {
                let ns = textAfterParens as NSString
                let matches = parenRegex.matches(in: textAfterParens, range: NSRange(location: 0, length: ns.length))
                if !matches.isEmpty {
                    let mutable = NSMutableString(string: textAfterParens)
                    for match in matches.reversed() {
                        guard match.numberOfRanges >= 2 else { continue }
                        let inner = ns.substring(with: match.range(at: 1))
                        let pToks = tokens(inner)
                        let pContent = pToks.filter { $0.count >= 3 && !stopWords.contains($0) }
                        let localHits = pContent.filter { pt in
                            localHeard.contains(where: { tokensMatch(pt, $0.token) })
                        }.count

                        let fullAfterStripping = mutable
                            .replacingCharacters(in: match.range, with: "")
                            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                        let isStandaloneParen = fullAfterStripping.isEmpty && matches.count == 1

                        var shouldStrip = false
                        if !pContent.isEmpty && canUseWordReconciliation {
                            if localHits == 0 && !hasCoOccurringPhraseAnywhere(pContent) {
                                shouldStrip = true
                            } else if localHits == 0 && pContent.count >= 2 && quietHere {
                                shouldStrip = true
                            }
                        } else if isStandaloneParen && localHits == 0 && (quietHere || idx < firstGroundedIdx) {
                            shouldStrip = true
                        }

                        if shouldStrip {
                            mutable.replaceCharacters(in: match.range, with: "")
                        }
                    }
                    textAfterParens = (mutable as String)
                        .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                        .replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if textAfterParens.hasPrefix(",") {
                        textAfterParens = textAfterParens.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if textAfterParens.hasSuffix(",") && !line.text.trimmingCharacters(in: .whitespaces).hasSuffix(",") {
                        textAfterParens = String(textAfterParens.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }

            let bareAfterParens = textAfterParens.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if bareAfterParens.isEmpty {
                // Entire line was an unsung phantom parenthetical -> drop it.
                continue
            }

            // Drop strictly silent edge intro/outro lines outside grounded singing bounds.
            let lineToks = tokens(textAfterParens)
            let lineContent = lineToks.filter { $0.count >= 3 && !stopWords.contains($0) }
            let localContentHits = lineContent.filter { lt in
                localHeard.contains(where: { tokensMatch(lt, $0.token) })
            }.count
            let isOutsideGroundedEdges = (idx < firstGroundedIdx && line.startTime < 20.0) || (idx > lastGroundedIdx)
            if quietStrict && localContentHits == 0 && isOutsideGroundedEdges && (!lineContent.isEmpty || (idx == 0 && line.startTime < 12.0)) {
                continue
            }

            // Uncensor explicit allowlisted masked words (`F***` -> `Fuck`) only when heard directly inside that line's tight span.
            var finalText = textAfterParens
            if canUseWordReconciliation, let maskRegex, finalText.contains("*") {
                let tightHeard = heardSlice(from: line.startTime - 0.5, to: max(line.endTime, line.startTime + 1.0) + 0.5)
                let ns = finalText as NSString
                let maskMatches = maskRegex.matches(in: finalText, range: NSRange(location: 0, length: ns.length))
                if !maskMatches.isEmpty {
                    let mutable = NSMutableString(string: finalText)
                    for match in maskMatches.reversed() {
                        let rawMask = ns.substring(with: match.range(at: 1))
                        let lowerMask = rawMask.lowercased()
                        let maskChars = Array(lowerMask)
                        guard maskChars.count >= 3 else { continue }
                        if let matchedHeard = tightHeard.first(where: { hw in
                            let lowerCand = hw.token.lowercased()
                            guard profanityAllowlist.contains(lowerCand) else { return false }
                            let cand = Array(lowerCand)
                            guard cand.count == maskChars.count else { return false }
                            for (mc, cc) in zip(maskChars, cand) where mc != "*" {
                                if mc != cc { return false }
                            }
                            return true
                        }) {
                            var restored = matchedHeard.token
                            if let firstOrig = rawMask.first, firstOrig.isUppercase {
                                restored = String(restored.prefix(1)).uppercased() + String(restored.dropFirst())
                            }
                            mutable.replaceCharacters(in: match.range(at: 1), with: restored)
                        }
                    }
                    finalText = mutable as String
                }
            }

            if finalText != line.text {
                line = SyncedLyricLine(
                    id: line.id,
                    startTime: line.startTime,
                    endTime: line.endTime,
                    text: finalText,
                    words: [],
                    isInstrumentalBreak: false,
                    hasNativeWordTimings: false,
                    isSpokenDialogue: line.isSpokenDialogue
                )
            }
            pass1Lines.append(line)
        }

        // Pass 2: Replace contiguous mismatched alternate-version verse runs (>= 3 lines with zero/minimal overlap)
        // using what THIS audio actually sings (`sortedHeard`), or mark silent extended runs as instrumental breaks.
        guard canUseWordReconciliation else {
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
                alignmentVersion: lyrics.alignmentVersion,
                lines: pass1Lines
            )
        }

        func isLineLocallyGrounded(_ line: SyncedLyricLine) -> Bool {
            if maxAudioTime > 2.0 && line.startTime >= maxAudioTime - 1.5 { return true }
            let lineToks = tokens(line.text)
            let content = lineToks.filter { $0.count >= 3 && !stopWords.contains($0) }
            guard !content.isEmpty else { return true }
            let localHeard = heardSlice(from: line.startTime - 3.0, to: max(line.endTime, line.startTime + 2.0) + 3.0)
            let hits = content.filter { lt in
                localHeard.contains(where: { tokensMatch(lt, $0.token) })
            }.count
            return hits >= 1 && (Double(hits) / Double(content.count)) >= 0.25
        }

        var reconciledLines: [SyncedLyricLine] = []
        var cursor = 0
        let totalDuration = max(
            lyrics.expectedDurationSeconds ?? 0,
            (sortedHeard.last?.time ?? 0) + 4.0
        )

        while cursor < pass1Lines.count {
            let line = pass1Lines[cursor]
            if line.isInstrumentalBreak || isLineLocallyGrounded(line) {
                reconciledLines.append(line)
                cursor += 1
                continue
            }

            // Collect contiguous ungrounded non-break lines.
            var runEndIdx = cursor
            while runEndIdx < pass1Lines.count,
                  !pass1Lines[runEndIdx].isInstrumentalBreak,
                  !isLineLocallyGrounded(pass1Lines[runEndIdx]) {
                runEndIdx += 1
            }
            let runCount = runEndIdx - cursor
            let run = Array(pass1Lines[cursor..<runEndIdx])
            let meaningfulLineCount = run.filter {
                tokens($0.text).filter { $0.count >= 3 && !stopWords.contains($0) }.count >= 2
            }.count

            if runCount >= 4 && meaningfulLineCount >= 3 {
                let prevBoundEnd = reconciledLines.last?.endTime ?? 0
                let nextBoundStart = (runEndIdx < pass1Lines.count) ? pass1Lines[runEndIdx].startTime : totalDuration
                let spanStart = max(prevBoundEnd + 0.02, (run.first?.startTime ?? prevBoundEnd) - 1.5)
                let spanEnd = min(nextBoundStart - 0.05, max(run.last?.endTime ?? spanStart + 3.0, spanStart + 3.0) + 1.5)
                let spanHeard = heardSlice(from: spanStart, to: spanEnd)
                    .filter { $0.time > prevBoundEnd + 0.01 && $0.time < nextBoundStart - 0.1 }

                let runVocab = Set(run.flatMap { tokens($0.text) }.filter { $0.count >= 3 && !stopWords.contains($0) })
                let spanMeaningful = spanHeard.filter { $0.token.count >= 3 && !stopWords.contains($0.token) }
                let spanOverlap = spanMeaningful.isEmpty ? 0.0 :
                    Double(spanMeaningful.filter { sw in runVocab.contains(where: { tokensMatch($0, sw.token) }) }.count) / Double(spanMeaningful.count)

                if spanHeard.count >= 12 && spanMeaningful.count >= 6 && spanOverlap < 0.12 {
                    let synthesized = buildSyncedLines(
                        from: spanHeard,
                        totalDuration: totalDuration,
                        includeLeadingBreak: false,
                        includeGapBreaks: true,
                        maxEndTime: nextBoundStart - 0.05
                    )
                    if !synthesized.isEmpty {
                        reconciledLines.append(contentsOf: synthesized)
                        cursor = runEndIdx
                        continue
                    }
                } else if spanHeard.count <= 1 && isQuietInCurve(from: spanStart, to: spanEnd) {
                    if spanEnd - spanStart >= 5.0 {
                        reconciledLines.append(SyncedLyricLine(
                            startTime: max(prevBoundEnd + 0.1, run.first?.startTime ?? spanStart),
                            endTime: max((run.first?.startTime ?? spanStart) + 1.0, min(nextBoundStart - 0.1, run.last?.endTime ?? spanEnd)),
                            text: "",
                            words: [],
                            isInstrumentalBreak: true
                        ))
                    }
                    cursor = runEndIdx
                    continue
                }
            }

            reconciledLines.append(contentsOf: run)
            cursor = runEndIdx
        }

        if !reconciledLines.contains(where: { !$0.isInstrumentalBreak }) && sortedHeard.count >= 6 {
            reconciledLines = buildSyncedLines(
                from: sortedHeard,
                totalDuration: totalDuration,
                includeLeadingBreak: true,
                includeGapBreaks: true
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
            alignmentVersion: lyrics.alignmentVersion,
            lines: reconciledLines
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
        let lines = buildSyncedLines(
            from: words,
            totalDuration: totalDur,
            includeLeadingBreak: true,
            includeGapBreaks: true
        )

        guard !lines.isEmpty else { return nil }
        return ResolvedTrackLyrics(
            cacheKey: cacheKey,
            trackTitle: trackTitle,
            artistName: artistName.isEmpty ? "Unknown Artist" : artistName,
            isTimeSynced: true,
            sourceLabel: "Full-Song Lyrics",
            attributionText: "Transcribed full song automatically",
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

    /// Refines per-line phrase boundaries onto sharp 43 Hz vocal attacks (`-0.85s..+0.55s` clamped monotonically)
    /// so community-timed karaoke/LRC lines with per-line reaction lag snap tightly to the singer's real entrance,
    /// and ensures every line's words complete cleanly before the next line starts.
    private static func refinePerLineVocalOnsets(
        in lyrics: ResolvedTrackLyrics,
        curve: VocalEnvelope?
    ) -> ResolvedTrackLyrics {
        guard lyrics.isTimeSynced,
              !lyrics.lines.isEmpty,
              let curve,
              !curve.fastVocalEnvelope.isEmpty else {
            return lyrics
        }

        let dt = curve.fastFrameDurationSeconds
        let fastEnv = curve.fastVocalEnvelope
        let fastOnset = curve.fastVocalOnset
        let maxCurveTime = Double(fastEnv.count) * dt

        func envMean(from s: Double, to e: Double) -> Double {
            guard e > s else { return 0 }
            let i0 = max(0, min(fastEnv.count - 1, Int(s / dt)))
            let i1 = max(i0 + 1, min(fastEnv.count, Int(e / dt)))
            let slice = fastEnv[i0..<i1]
            return slice.reduce(0, +) / Double(max(1, slice.count))
        }

        func onsetPeak(from s: Double, to e: Double) -> Double {
            guard !fastOnset.isEmpty, e > s else { return 0 }
            let i0 = max(0, min(fastOnset.count - 1, Int(s / dt)))
            let i1 = max(i0 + 1, min(fastOnset.count, Int(e / dt)))
            return fastOnset[i0..<i1].max() ?? 0
        }

        func onsetScore(at t: Double, orig: Double) -> Double {
            let after = envMean(from: t, to: t + 0.28)
            let before = envMean(from: max(0, t - 0.28), to: max(0.02, t - 0.04))
            let spike = onsetPeak(from: max(0, t - 0.06), to: t + 0.14)
            return (after - before) + 0.35 * spike - abs(t - orig) * 0.12
        }

        var refined = lyrics.lines
        let count = refined.count

        for idx in 0..<count {
            let line = refined[idx]
            guard !line.isInstrumentalBreak, !line.isSpokenDialogue else { continue }
            guard line.startTime >= 0, line.startTime + 0.4 < maxCurveTime else { continue }

            let prevEnd: Double = (idx > 0) ? (refined[idx - 1].startTime + 0.35) : 0.0
            let prevHardEnd: Double = (idx > 0) ? refined[idx - 1].endTime : 0.0
            let nextStart: Double = (idx + 1 < count) ? refined[idx + 1].startTime : maxCurveTime
            let minGapBefore = idx > 0 ? (line.startTime - prevHardEnd) : line.startTime

            var newStart = line.startTime
            if minGapBefore >= 0.30 || line.hasNativeWordTimings {
                let minAllowed = max(max(0.05, prevEnd), line.startTime - 0.85)
                let maxAllowed = min(nextStart - 0.38, line.startTime + 0.55)
                if maxAllowed > minAllowed + 0.05 {
                    let origScore = onsetScore(at: line.startTime, orig: line.startTime)
                    var bestT = line.startTime
                    var bestSc = origScore
                    var cand = minAllowed
                    while cand <= maxAllowed {
                        let sc = onsetScore(at: cand, orig: line.startTime)
                        if sc > bestSc {
                            bestSc = sc
                            bestT = cand
                        }
                        cand += 0.025
                    }
                    if abs(bestT - line.startTime) >= 0.14 && bestSc > origScore + 0.15 {
                        newStart = bestT
                    }
                }
            }

            let delta = newStart - line.startTime
            let vocalGapAfter = nextStart - newStart
            let boundedEnd: Double = {
                let shiftedEnd = max(newStart + 0.35, line.endTime + delta)
                if vocalGapAfter > 8.5 { return min(maxCurveTime, shiftedEnd) }
                return min(shiftedEnd, max(newStart + 0.35, nextStart - 0.05))
            }()

            let shiftedWords: [LyricWordTiming]
            if line.words.isEmpty {
                shiftedWords = []
            } else {
                let deadline = max(newStart + 0.25, boundedEnd - 0.015)
                let rawShifted = line.words.map { w in
                    (
                        id: w.id,
                        text: w.text,
                        start: max(newStart, w.startTime + delta),
                        end: max(newStart + 0.04, w.endTime + delta),
                        hasSpace: w.hasTrailingSpace
                    )
                }
                let rawLastEnd = rawShifted.last?.end ?? deadline
                if rawLastEnd > deadline {
                    let origSpan = max(0.25, rawLastEnd - newStart)
                    let targetSpan = max(0.20, deadline - newStart)
                    let scale = targetSpan / origSpan
                    shiftedWords = rawShifted.map { rw in
                        let ws = newStart + max(0, rw.start - newStart) * scale
                        let we = newStart + max(0.04, rw.end - newStart) * scale
                        return LyricWordTiming(
                            id: rw.id,
                            text: rw.text,
                            startTime: min(deadline - 0.04, ws),
                            endTime: min(deadline, max(ws + 0.04, we)),
                            hasTrailingSpace: rw.hasSpace
                        )
                    }
                } else {
                    shiftedWords = rawShifted.map { rw in
                        LyricWordTiming(
                            id: rw.id,
                            text: rw.text,
                            startTime: rw.start,
                            endTime: rw.end,
                            hasTrailingSpace: rw.hasSpace
                        )
                    }
                }
            }

            if delta != 0 || boundedEnd != line.endTime || shiftedWords != line.words {
                refined[idx] = SyncedLyricLine(
                    id: line.id,
                    startTime: newStart,
                    endTime: boundedEnd,
                    text: line.text,
                    words: shiftedWords,
                    isInstrumentalBreak: line.isInstrumentalBreak,
                    hasNativeWordTimings: line.hasNativeWordTimings,
                    isSpokenDialogue: line.isSpokenDialogue
                )
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
            alignmentVersion: lyrics.alignmentVersion,
            lines: refined
        )
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

        struct TimingToken {
            let text: String
            let hasTrailingSpace: Bool
        }

        func splitLineIntoTimingTokens(_ text: String) -> [TimingToken] {
            let spaceChunks = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let smallKanaOrPunct: Set<Character> = [
                "ぁ","ぃ","ぅ","ぇ","ぉ","ゃ","ゅ","ょ","っ","ゎ","ゐ","ゑ",
                "ァ","ィ","ゥ","ェ","ォ","ャ","ュ","ョ","ッ","ヮ","ヶ","ヵ","ー",
                "！","？","。","、","・","!", "?", ".", ",", ";", ":", "'", "’", "-", "…", "~"
            ]
            func isCJKScalar(_ s: UnicodeScalar) -> Bool {
                let v = s.value
                return (0x3040...0x30FF).contains(v)
                    || (0x4E00...0x9FFF).contains(v)
                    || (0x3400...0x4DBF).contains(v)
                    || (0xAC00...0xD7AF).contains(v)
            }

            var tokensOut: [TimingToken] = []
            for (cIdx, chunk) in spaceChunks.enumerated() {
                let isLastChunk = (cIdx == spaceChunks.count - 1)
                let hasCJK = chunk.unicodeScalars.contains(where: isCJKScalar)
                let cjkCount = chunk.unicodeScalars.filter(isCJKScalar).count
                guard hasCJK && cjkCount >= 2 else {
                    tokensOut.append(TimingToken(text: chunk, hasTrailingSpace: !isLastChunk))
                    continue
                }
                var subTokens: [String] = []
                var buf = ""
                var bufIsCJK = false
                for ch in chunk {
                    let chCJK = ch.unicodeScalars.contains(where: isCJKScalar)
                    if buf.isEmpty {
                        buf = String(ch)
                        bufIsCJK = chCJK
                    } else if smallKanaOrPunct.contains(ch) {
                        buf.append(ch)
                    } else if !bufIsCJK && !chCJK {
                        buf.append(ch)
                    } else {
                        subTokens.append(buf)
                        buf = String(ch)
                        bufIsCJK = chCJK
                    }
                }
                if !buf.isEmpty { subTokens.append(buf) }
                for (sIdx, st) in subTokens.enumerated() {
                    let isLastSub = (sIdx == subTokens.count - 1)
                    tokensOut.append(TimingToken(text: st, hasTrailingSpace: isLastSub && !isLastChunk))
                }
            }
            return tokensOut
        }

        let updatedLines: [SyncedLyricLine] = lyrics.lines.enumerated().map { idx, line in
            guard !line.isInstrumentalBreak else { return line }
            if line.hasNativeWordTimings && !line.words.isEmpty {
                let nextFloor = (idx + 1 < lyrics.lines.count)
                    ? max(line.startTime + 0.35, lyrics.lines[idx + 1].startTime - 0.05)
                    : max(line.startTime + 0.35, line.endTime)
                let maxWordEnd = max(line.startTime + 0.25, nextFloor - 0.015)
                if let lastEnd = line.words.last?.endTime, lastEnd > maxWordEnd {
                    let origSpan = max(0.25, lastEnd - line.startTime)
                    let newSpan = max(0.20, maxWordEnd - line.startTime)
                    let scale = newSpan / origSpan
                    let scaledWords = line.words.map { w in
                        let ws = line.startTime + max(0, w.startTime - line.startTime) * scale
                        let we = line.startTime + max(0.04, w.endTime - line.startTime) * scale
                        return LyricWordTiming(
                            id: w.id,
                            text: w.text,
                            startTime: min(maxWordEnd - 0.04, ws),
                            endTime: min(maxWordEnd, max(ws + 0.04, we)),
                            hasTrailingSpace: w.hasTrailingSpace
                        )
                    }
                    return SyncedLyricLine(
                        id: line.id,
                        startTime: line.startTime,
                        endTime: min(line.endTime, nextFloor),
                        text: line.text,
                        words: scaledWords,
                        isInstrumentalBreak: false,
                        hasNativeWordTimings: true,
                        isSpokenDialogue: line.isSpokenDialogue
                    )
                }
                return line
            }
            let timingTokens = splitLineIntoTimingTokens(line.text)
            let rawWords = timingTokens.map(\.text)
            guard !rawWords.isEmpty else { return line }

            let nextLineFloor = (idx + 1 < lyrics.lines.count)
                ? max(line.startTime + 0.45, lyrics.lines[idx + 1].startTime - 0.06)
                : max(line.startTime + 3.2, line.endTime)
            let rawStart = max(0, line.startTime)
            let rawEnd = min(nextLineFloor, max(rawStart + 0.45, line.endTime > rawStart + 0.25 ? line.endTime : nextLineFloor))
            let minVocalDur = min(rawEnd - rawStart, max(0.45, Double(rawWords.count) * 0.11))

            // Trim silent leading padding (up to 1.35s) and trailing drum/beat tails via 43 Hz harmonic vocal energy
            // requiring 3 sustained onset frames (~70ms) and 4 sustained release frames (~93ms) so snares can't stretch lines.
            var vocalStart = rawStart
            var vocalEnd = rawEnd
            if let curve, !curve.fastVocalEnvelope.isEmpty {
                let dt = curve.fastFrameDurationSeconds
                let iStart = max(0, min(curve.fastVocalEnvelope.count - 1, Int(rawStart / dt)))
                let iEnd = max(iStart + 1, min(curve.fastVocalEnvelope.count, Int(rawEnd / dt)))

                let maxTrimLeadIdx = min(iEnd, Int((min(rawStart + 1.35, rawEnd - minVocalDur)) / dt))
                if maxTrimLeadIdx > iStart + 2 {
                    var scan = iStart
                    while scan + 2 < maxTrimLeadIdx {
                        let s0 = curve.fastVocalEnvelope[scan]
                        let s1 = curve.fastVocalEnvelope[scan + 1]
                        let s2 = curve.fastVocalEnvelope[scan + 2]
                        if s0 >= -0.14 && s1 >= -0.10 && s2 >= -0.12 {
                            break
                        }
                        scan += 1
                    }
                    if scan + 2 < maxTrimLeadIdx {
                        vocalStart = max(rawStart, min(rawEnd - minVocalDur, Double(scan) * dt - 0.03))
                    }
                }

                let minEndIdx = max(iStart + 3, Int((vocalStart + minVocalDur) / dt))
                if iEnd > minEndIdx + 4 {
                    for rev in stride(from: iEnd - 1, through: minEndIdx + 3, by: -1) {
                        let f0 = curve.fastVocalEnvelope[rev]
                        let f1 = curve.fastVocalEnvelope[rev - 1]
                        let f2 = curve.fastVocalEnvelope[rev - 2]
                        let f3 = curve.fastVocalEnvelope[rev - 3]
                        let mean4 = (f0 + f1 + f2 + f3) * 0.25
                        if f0 > -0.16 && f1 > -0.14 && f2 > -0.14 && f3 > -0.14 && mean4 > -0.05 {
                            vocalEnd = max(vocalStart + minVocalDur, min(rawEnd, Double(rev + 1) * dt + 0.08))
                            break
                        }
                    }
                }
            }

            // Piecewise monotonic Whisper/Speech word anchoring (compensating ~40ms ASR offset).
            let localHeard: [HeardWord] = (heard ?? []).filter {
                $0.time >= rawStart - 0.45 && $0.time <= rawEnd + 0.45
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
                        let adjT = localHeard[h].time - 0.04
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
                    let trailingSpace = k < timingTokens.count ? timingTokens[k].hasTrailingSpace : true
                    generatedWords[k] = LyricWordTiming(
                        text: rawWords[k],
                        startTime: safeStart,
                        endTime: safeEnd,
                        hasTrailingSpace: trailingSpace
                    )
                }
            }

            var finalizedWords = generatedWords.compactMap { $0 }
            // Ensure strictly non-decreasing monotonic boundaries and completion strictly before nextLineFloor.
            let wordMaxEnd = max(vocalStart + 0.25, min(vocalEnd, nextLineFloor - 0.015))
            for k in 0..<finalizedWords.count {
                var s = finalizedWords[k].startTime
                if k > 0 && s < finalizedWords[k - 1].startTime + 0.04 {
                    s = min(wordMaxEnd - 0.04, finalizedWords[k - 1].startTime + 0.04)
                } else {
                    s = min(wordMaxEnd - 0.04, s)
                }
                let e = min(wordMaxEnd, max(s + 0.04, finalizedWords[k].endTime))
                finalizedWords[k] = LyricWordTiming(
                    id: finalizedWords[k].id,
                    text: finalizedWords[k].text,
                    startTime: s,
                    endTime: e,
                    hasTrailingSpace: finalizedWords[k].hasTrailingSpace
                )
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

        // Test natural tempo (1.0) plus stretched/sped-up edits (0.78x..1.32x for slowed+reverb, nightcore, live cuts).
        var candidateScales: [Double] = [1.0]
        if let expectedDur = lyrics.expectedDurationSeconds,
           expectedDur > 20, actualDuration > 20 {
            let ratio = actualDuration / expectedDur
            if ratio >= 0.78 && ratio <= 1.32 && abs(ratio - 1.0) >= 0.015 {
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
        var scale1BestScore = -Double.infinity
        var bestOffset: Double = 0
        var bestScale: Double = 1.0

        let maxSweepOffset = min(210.0, max(110.0, actualDuration * 0.55))

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

            let tempoPrior = abs(scale - 1.0) * 0.08

            let fastDt = curve.fastFrameDurationSeconds
            let hasFastCurve = !curve.fastVocalEnvelope.isEmpty && fastDt > 0.005

            func fastEnvMean(from s: Double, to e: Double) -> Double {
                guard hasFastCurve, e > s else { return 0 }
                let i0 = max(0, min(curve.fastVocalEnvelope.count - 1, Int(s / fastDt)))
                let i1 = max(i0 + 1, min(curve.fastVocalEnvelope.count, Int(e / fastDt)))
                let slice = curve.fastVocalEnvelope[i0..<i1]
                return slice.reduce(0, +) / Double(max(1, slice.count))
            }

            let onsetLines = lyrics.lines.filter { !$0.isInstrumentalBreak && !$0.isSpokenDialogue }

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

                // Reward crisp 43 Hz vocal-phrase onset edges across lines separated by gaps.
                var onsetContrastSum = 0.0
                var onsetCount = 0
                if hasFastCurve {
                    for k in 0..<onsetLines.count {
                        let ln = onsetLines[k]
                        let prevGap = k > 0 ? (ln.startTime - onsetLines[k - 1].endTime) : ln.startTime
                        guard prevGap >= 0.30 else { continue }
                        let s = ln.startTime * scale + offset
                        guard s >= 0.1, s + 0.30 < actualDuration else { continue }
                        let after = fastEnvMean(from: s, to: s + 0.28)
                        let before = fastEnvMean(from: max(0, s - 0.32), to: max(0.02, s - 0.05))
                        onsetContrastSum += (after - before)
                        onsetCount += 1
                    }
                }
                let onsetBonus = onsetCount > 0 ? 0.32 * (onsetContrastSum / Double(onsetCount)) : 0.0

                // Tiny prior preferring smaller shifts and natural 1.0 tempo when scores tie.
                var finalScore = (sum / Double(count)) + onsetBonus - min(0.08, abs(offset) * 0.0010) - tempoPrior
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
            if scale == 1.0 && zScore > scale1BestScore { scale1BestScore = zScore }
            if zScore > bestScore {
                bestScore = zScore
                bestOffset = 0
                bestScale = scale
            }

            // Sweep -45s..+maxSweepOffset (0.25s steps across -35..110s, 0.5s outside for long intros & trimmed edits).
            var scaleBestOff = 0.0
            var scaleBestSc = zScore
            var offset = -45.0
            while offset <= maxSweepOffset {
                let s = scoreShift(offset)
                if s > scaleBestSc {
                    scaleBestSc = s
                    scaleBestOff = offset
                }
                if scale == 1.0 && s > scale1BestScore { scale1BestScore = s }
                if s > bestScore {
                    bestScore = s
                    bestOffset = offset
                    bestScale = scale
                }
                offset += (offset >= -35.0 && offset <= 110.0) ? 0.25 : 0.5
            }

            // Fine 0.04s sweep around peak (-2.2s..+2.2s) to capture exact sub-second karaoke/LRC lag.
            let fineStart = max(-45.0, scaleBestOff - 2.2)
            let fineEnd = min(maxSweepOffset, scaleBestOff + 2.2)
            var fine = fineStart
            while fine <= fineEnd {
                let s = scoreShift(fine)
                if scale == 1.0 && s > scale1BestScore { scale1BestScore = s }
                if s > bestScore {
                    bestScore = s
                    bestOffset = fine
                    bestScale = scale
                }
                fine += 0.04
            }
        }

        // Apply discovered tempo scale before Section-DTW when slowed/sped-up upload beats 1.0 tempo cleanly.
        let useTempoScaling = abs(bestScale - 1.0) >= 0.025 && bestScore > scale1BestScore + 0.05
        let effectiveLyricsForDTW: ResolvedTrackLyrics = {
            guard useTempoScaling else { return lyrics }
            let scaledLines = lyrics.lines.map { line in
                SyncedLyricLine(
                    id: line.id,
                    startTime: line.startTime * bestScale,
                    endTime: line.endTime * bestScale,
                    text: line.text,
                    words: line.words.map {
                        LyricWordTiming(
                            id: $0.id,
                            text: $0.text,
                            startTime: $0.startTime * bestScale,
                            endTime: $0.endTime * bestScale,
                            hasTrailingSpace: $0.hasTrailingSpace
                        )
                    },
                    isInstrumentalBreak: line.isInstrumentalBreak,
                    hasNativeWordTimings: line.hasNativeWordTimings,
                    isSpokenDialogue: line.isSpokenDialogue
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
                alignmentVersion: lyrics.alignmentVersion,
                lines: scaledLines
            )
        }()

        // Also check Piecewise Section-DTW (Viterbi) across >= 4s LRC singing gaps so mid-video skits or extra pauses
        // shift Verse 2 / Chorus 2 independently without disturbing Verse 1 or introducing false jumps on studio songs.
        if let piecewise = alignSectionsWithViterbi(
            lyrics: effectiveLyricsForDTW,
            curve: curve,
            singingEnv: singingEnv,
            lrcNonBreakLines: effectiveLyricsForDTW.lines.filter { !$0.isInstrumentalBreak },
            lrcChorusPairs: lrcChorusPairs
        ) {
            return piecewise
        }

        // Apply sub-second/multi-second global alignment cleanly whenever vocal & onset correlation improves.
        let fineShiftImprove = abs(bestOffset) >= 0.20 && abs(bestOffset) <= 3.0 && bestScore > zeroOffsetScore + 0.022 && bestScore > 0.05
        let largeShiftImprove = abs(bestOffset) > 3.0 && bestScore > zeroOffsetScore + 0.055 && bestScore > 0.08
        let meaningfulImprovement = fineShiftImprove || largeShiftImprove
        guard meaningfulImprovement || useTempoScaling || abs(bestScale - 1.0) >= 0.015 else {
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
                    endTime: max(0, $0.endTime * appliedScale + appliedOffset),
                    hasTrailingSpace: $0.hasTrailingSpace
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

        let maxDtwOffset = min(210.0, max(110.0, actualDuration * 0.55))
        var offsets: [Double] = []
        var oVal = -40.0
        while oVal <= maxDtwOffset {
            offsets.append(oVal)
            oVal += (oVal >= -25.0 && oVal <= 105.0) ? 0.5 : 1.0
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
                    guard abs(delta) < 0.01 || (delta >= -25.0 && delta <= 120.0 && abs(delta) >= 2.0) else { continue }
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
                    endTime: max(0, $0.endTime + off),
                    hasTrailingSpace: $0.hasTrailingSpace
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

    private struct RepeatedChorusBlock: Sendable {
        let firstStartLine: Int
        let repeatStartLine: Int
        let lineCount: Int
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
    private static func estimateSteadyBeatGrid(flux: [Double], frameDt: Double) -> VocalBeatGrid? {
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
        return VocalBeatGrid(
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
            AVNumberOfChannelsKey: 2,
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
        var midSamples: [Float] = []
        var sideSamples: [Float] = []
        midSamples.reserveCapacity(min(maxSamples, Int(sampleRate * 300)))
        sideSamples.reserveCapacity(min(maxSamples, Int(sampleRate * 300)))
        let scale: Float = 1.0 / 32768.0
        var sumMidSq: Double = 0
        var sumSideSq: Double = 0
        while reader.status == .reading, midSamples.count < maxSamples {
            guard let sb = output.copyNextSampleBuffer(),
                  let bb = CMSampleBufferGetDataBuffer(sb) else { break }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
               let ptr = pointer, length >= 4 {
                let frameCount = min(length / (2 * MemoryLayout<Int16>.size), maxSamples - midSamples.count)
                ptr.withMemoryRebound(to: Int16.self, capacity: frameCount * 2) { i16 in
                    for f in 0..<frameCount {
                        let l = Float(i16[f * 2]) * scale
                        let r = Float(i16[f * 2 + 1]) * scale
                        let m = 0.5 * (l + r)
                        let s = 0.5 * (l - r)
                        midSamples.append(m)
                        sideSamples.append(s)
                        sumMidSq += Double(m * m)
                        sumSideSq += Double(s * s)
                    }
                }
            }
            CMSampleBufferInvalidate(sb)
        }

        let fftSize = 1024
        let log2N = vDSP_Length(10)
        let hop = 256 // ~43.07 Hz resolution for crisp beat tracking & multi-rate downsampling
        guard midSamples.count >= fftSize,
              let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let hasStereoSide = sqrt(sumSideSq / Double(midSamples.count)) > 0.05 * sqrt(sumMidSq / Double(midSamples.count) + 1e-12)

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let halfN = fftSize / 2
        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)
        var windowedSide = [Float](repeating: 0, count: fftSize)
        var realSide = [Float](repeating: 0, count: halfN)
        var imagSide = [Float](repeating: 0, count: halfN)
        var magsSide = [Float](repeating: 0, count: halfN)

        let estFrames = (midSamples.count - fftSize) / hop + 1
        var rawVocal43Hz: [Double] = []
        rawVocal43Hz.reserveCapacity(estFrames)
        var rawFlatness43Hz: [Double] = []
        rawFlatness43Hz.reserveCapacity(estFrames)
        var rawFlux43Hz: [Double] = []
        rawFlux43Hz.reserveCapacity(estFrames)
        var rawVocalFlux43Hz: [Double] = []
        rawVocalFlux43Hz.reserveCapacity(estFrames)
        var rawBands43Hz: [[Double]] = []
        rawBands43Hz.reserveCapacity(estFrames)
        var prevLogMags = [Double](repeating: 0, count: 256)
        var hasPrev = false

        var pos = 0
        while pos + fftSize <= midSamples.count {
            midSamples.withUnsafeBufferPointer { sPtr in
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
            if hasStereoSide {
                sideSamples.withUnsafeBufferPointer { ssPtr in
                    vDSP_vmul(ssPtr.baseAddress! + pos, 1, window, 1, &windowedSide, 1, vDSP_Length(fftSize))
                }
                realSide.withUnsafeMutableBufferPointer { rPtr in
                    imagSide.withUnsafeMutableBufferPointer { iPtr in
                        var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                        windowedSide.withUnsafeBufferPointer { wPtr in
                            wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                                vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &magsSide, 1, vDSP_Length(halfN))
                    }
                }
            }

            // 6 perceptual full-mix bands + stereo-center harmonic vocal isolation (250-3450 Hz) with flatness gate.
            var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0
            var centerVocalSum: Float = 0
            var sb0 = 0.0, sb1 = 0.0, sb2 = 0.0, sb3 = 0.0, sb4 = 0.0, sb5 = 0.0
            for b in 2..<min(halfN, 512) {
                let m = mags[b]
                if b < 10 { b0 += m }
                else if b < 28 { b1 += m }
                else if b < 95 { b2 += m }
                else if b < 230 { b3 += m }
                else if b < 350 { b4 += m }
                else { b5 += m }
                if b >= 23 && b < 320 {
                    let cM = hasStereoSide ? max(Float(0), m - 0.80 * magsSide[b]) : m
                    centerVocalSum += cM
                    let sub = (b - 23) / 50
                    let cd = Double(cM)
                    switch sub {
                    case 0: sb0 += cd
                    case 1: sb1 += cd
                    case 2: sb2 += cd
                    case 3: sb3 += cd
                    case 4: sb4 += cd
                    default: sb5 += cd
                    }
                }
            }
            let eps = 1e-6
            let logMean = (log(sb0 + eps) + log(sb1 + eps) + log(sb2 + eps) + log(sb3 + eps) + log(sb4 + eps) + log(sb5 + eps)) / 6.0
            let arithMean = max(eps, (sb0 + sb1 + sb2 + sb3 + sb4 + sb5) / 6.0)
            let flatness = min(1.0, max(0.0, exp(logMean) / arithMean))
            let percRatio = Double(b4 + b5) / max(1e-3, Double(b2 + b3))
            let harmonicFactor = max(0.05, min(1.0, (0.82 - flatness) / 0.32 - 0.35 * max(0.0, percRatio - 0.65)))

            rawVocal43Hz.append(log1p(Double(centerVocalSum)) * harmonicFactor)
            rawFlatness43Hz.append(flatness)
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
                        if b >= 23 {
                            vocalFluxVal += d * harmonicFactor
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

        // Smooth 43 Hz harmonic vocal energy lightly ([0.22, 0.56, 0.22]) so 23ms drum impulses decay cleanly.
        var smoothedVocal43Hz = rawVocal43Hz
        if rawVocal43Hz.count >= 3 {
            for i in 1..<(rawVocal43Hz.count - 1) {
                smoothedVocal43Hz[i] = 0.22 * rawVocal43Hz[i - 1] + 0.56 * rawVocal43Hz[i] + 0.22 * rawVocal43Hz[i + 1]
            }
        }

        // Downsample 43.07 Hz vocal log-energy by 4 (~10.77 Hz / 0.0929s per frame) for smooth phrase curve.
        let dsEnv = 4
        let envCount = smoothedVocal43Hz.count / dsEnv
        guard envCount > 0 else { return nil }
        var rawEnergies = [Double](repeating: 0, count: envCount)
        var meanFlatness = [Double](repeating: 0, count: envCount)
        for i in 0..<envCount {
            let base = i * dsEnv
            var s = 0.0
            var fSum = 0.0
            for k in 0..<dsEnv {
                s += smoothedVocal43Hz[base + k]
                fSum += rawFlatness43Hz[base + k]
            }
            rawEnergies[i] = s / Double(dsEnv)
            meanFlatness[i] = fSum / Double(dsEnv)
        }
        let sorted = rawEnergies.sorted()
        let p20 = sorted[max(0, sorted.count / 5)]
        let p80 = sorted[min(sorted.count - 1, (sorted.count * 4) / 5)]
        let mid = (p20 + p80) * 0.5
        let spread = max(0.25, (p80 - p20) * 0.5)
        let centered = rawEnergies.map { min(1.0, max(-1.0, ($0 - mid) / spread)) }

        // Compute low-frequency musical accompaniment (kick/bass/low-mid: b0 + b1) to separate
        // dry choppy talking skits & percussive breaks from sustained harmonic singing over music.
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
            } else if meanFlatness[i] > 0.68 && duty < 0.72 {
                // Flat broadband percussive burst / noise break (snares, hats, crowd applause) without harmonic voice.
                rawSinging[i] = -0.22
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

        // Keep full 43.07 Hz centered harmonic vocal energy & p95-normalized vocal onset flux for crisp word/syllable warping.
        let fastVocalEnvelope = smoothedVocal43Hz.map { min(1.0, max(-1.0, ($0 - mid) / spread)) }
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
            let needed = Set(lineTokens)
            let isTwoWordDistinctiveHook = lineTokens.count == 2
                && needed.count == 2
                && lineTokens.allSatisfy { $0.count >= 4 && !stopWords.contains($0) }
            guard (lineTokens.count >= 3 && needed.count >= 3) || isTwoWordDistinctiveHook else { continue }
            let window = isTwoWordDistinctiveHook ? 3 : (lineTokens.count + 3)

            var allMatches: [(time: Double, score: Double)] = []
            var i = 0
            while i < heard.count {
                let end = min(heard.count, i + window)
                var hits = Set<String>()
                var nonStopHits = 0
                var lineCursor = 0
                var orderedHits = 0
                var firstHit: Int?
                for j in i..<end {
                    let tok = heard[j].token
                    if needed.contains(tok) {
                        if firstHit == nil { firstHit = j }
                        if !stopWords.contains(tok) && tok.count >= 3 { nonStopHits += 1 }
                        hits.insert(tok)
                        if lineCursor < lineTokens.count,
                           let relIdx = lineTokens[lineCursor...].firstIndex(of: tok) {
                            orderedHits += 1
                            lineCursor = relIdx + 1
                        }
                    }
                }
                let bagScore = Double(hits.count) / Double(needed.count)
                let ordScore = Double(orderedHits) / Double(lineTokens.count)
                let combinedScore = isTwoWordDistinctiveHook ? 0.84 : (0.55 * bagScore + 0.45 * ordScore)
                let passesTwoWord = isTwoWordDistinctiveHook && orderedHits == 2 && nonStopHits == 2
                let passesMultiWord = !isTwoWordDistinctiveHook && bagScore >= minScore && ordScore >= 0.50 && nonStopHits >= 2
                if (passesTwoWord || passesMultiWord), let firstHit {
                    allMatches.append((max(0, heard[firstHit].time - 0.10), combinedScore))
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
