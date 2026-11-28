import Accelerate
import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// On-device CoreML Whisper transcription engine backed by `WhisperKit`.
/// Keeps the `.ipa` small by downloading the quantized `openai_whisper-base` CoreML bundle once into
/// `Application Support/WhisperModels` and running locally on the Neural Engine afterwards.
actor WhisperTranscriptionEngine {
    static let shared = WhisperTranscriptionEngine()

    struct TranscribedWord: Sendable {
        let rawText: String
        let token: String
        let startTime: Double
        let endTime: Double
    }

    struct TranscriptionSummary: Sendable {
        let words: [TranscribedWord]
        let detectedLanguage: String?
        let avgNoSpeechProb: Double
        let durationSeconds: Double
    }

    private static let primaryVariantName = "openai_whisper-small"
    private static let fallbackVariantName = "openai_whisper-base"
    private static let savedFolderDefaultsKey = "musejrm.whisper.modelFolder.v2"
    static let downloadLoadTimeoutSeconds: Double = 300
    private static let backgroundSafeComputeOptions = ModelComputeOptions(
        melCompute: .cpuAndNeuralEngine,
        audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine
    )

    private var whisperKit: WhisperKit?
    private var initTask: Task<WhisperKit?, Never>?
    private var initTaskIsNetworkDownload = false
    private var lastFailureAt: Date?

    var isModelReadyInMemory: Bool {
        whisperKit != nil
    }

    private static var modelsBaseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    /// Warms up or downloads the local Whisper CoreML model silently in background after app launch.
    func warmUpInBackground() async {
        Self.relocateLegacyDocumentsHuggingFaceFolder()
        _ = await ensureLoaded(allowDownload: true)
    }

    /// Moves any legacy `Documents/huggingface` cache created by older WhisperKit defaults out of user Documents
    /// into `Application Support/WhisperModels` so users never see an internal cache folder in Files.
    nonisolated static func relocateLegacyDocumentsHuggingFaceFolder() {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let legacyHF = docsURL.appendingPathComponent("huggingface", isDirectory: true)
        guard fm.fileExists(atPath: legacyHF.path) else { return }

        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let modelsBase = appSupport.appendingPathComponent("WhisperModels", isDirectory: true)
        try? fm.createDirectory(at: modelsBase, withIntermediateDirectories: true)
        let destHF = modelsBase.appendingPathComponent("huggingface", isDirectory: true)

        if !fm.fileExists(atPath: destHF.path) {
            if (try? fm.moveItem(at: legacyHF, to: destHF)) != nil {
                return
            }
        }

        if let enumerator = fm.enumerator(at: legacyHF, includingPropertiesForKeys: [.isDirectoryKey]) {
            let basePath = legacyHF.standardizedFileURL.path
            while let src = enumerator.nextObject() as? URL {
                let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let rel = String(src.standardizedFileURL.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !rel.isEmpty else { continue }
                let target = destHF.appendingPathComponent(rel, isDirectory: isDir)
                if isDir {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else if !fm.fileExists(atPath: target.path) {
                    try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: src, to: target)
                }
            }
        }
        try? fm.removeItem(at: legacyHF)
    }

    var isModelCachedLocally: Bool {
        guard let saved = UserDefaults.standard.string(forKey: Self.savedFolderDefaultsKey),
              !saved.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: saved)
    }

    /// Transcribes an entire audio/video file (up to `maxSeconds`) into word-level timestamps using Whisper.
    /// Returns `nil` when the model isn't ready/available so the caller falls back cleanly to `SFSpeechRecognizer`.
    func transcribeWholeFile(
        fileURL: URL,
        maxSeconds: Double = 15 * 60,
        allowDownload: Bool = false,
        languageHint: String? = nil,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> [TranscribedWord]? {
        guard let summary = await transcribeWholeFileSummary(
            fileURL: fileURL,
            maxSeconds: maxSeconds,
            allowDownload: allowDownload,
            languageHint: languageHint,
            onProgress: onProgress
        ), !summary.words.isEmpty else {
            return nil
        }
        return summary.words
    }

    func transcribeWholeFileSummary(
        fileURL: URL,
        maxSeconds: Double = 15 * 60,
        allowDownload: Bool = false,
        languageHint: String? = nil,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> TranscriptionSummary? {
        guard let prepared = SongAudioListener.prepareReadableAudioFile(for: fileURL) else {
            return nil
        }
        defer {
            if let cleanup = prepared.cleanupURL {
                try? FileManager.default.removeItem(at: cleanup)
            }
        }

        guard let kit = await ensureLoaded(allowDownload: allowDownload) else {
            return nil
        }
        guard let pcm = await Self.extract16kVocalEnhancedPCM(from: prepared.url, maxSeconds: maxSeconds),
              !pcm.samples.isEmpty else {
            return nil
        }

        let totalSec = pcm.durationSeconds
        let totalChunks = max(1, Int(ceil(totalSec / 30.0)))
        let useAutoLang = (languageHint?.isEmpty ?? true)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: useAutoLang ? nil : languageHint,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.25,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: useAutoLang,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            suppressBlank: true,
            noSpeechThreshold: 0.92,
            chunkingStrategy: nil
        )

        onProgress?(1, totalChunks, totalSec)
        guard let results = try? await kit.transcribe(
            audioArray: pcm.samples,
            decodeOptions: options,
            callback: { progress in
                let step = max(1, min(totalChunks, progress.windowId + 1))
                onProgress?(step, totalChunks, totalSec)
                return !Task.isCancelled
            }
        ) else {
            return nil
        }

        onProgress?(totalChunks, totalChunks, totalSec)
        var words: [TranscribedWord] = []
        var langCounts: [String: Int] = [:]
        var noSpeechSum = 0.0
        var noSpeechWeight = 0.0

        func extractWords(from segResults: [TranscriptionResult], timeUpperBound: Double? = nil) -> (words: [TranscribedWord], langs: [String: Int], nsSum: Double, nsWeight: Double) {
            var localWords: [TranscribedWord] = []
            var localLangs: [String: Int] = [:]
            var localSum = 0.0
            var localWeight = 0.0
            let captionNoisePhrases = [
                "thanks for watching", "thank you for watching", "subscribe to",
                "subtitles by", "amara.org", "구독과 좋아요", "[music]", "(music)"
            ]
            for result in segResults {
                let lang = result.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !lang.isEmpty {
                    localLangs[lang, default: 0] += max(1, result.segments.count)
                }
                for seg in result.segments {
                    let segDur = max(0.1, Double(seg.end - seg.start))
                    localSum += Double(seg.noSpeechProb) * segDur
                    localWeight += segDur
                    // Hip-hop / beat-backed & sparse vaporwave vocal adlibs often sit in noSpeechProb 0.72..0.97;
                    // only discard near-certain silence or silence noise hallucinations.
                    if seg.noSpeechProb > 0.98 { continue }
                    let lowerSeg = seg.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if seg.noSpeechProb > 0.50 && captionNoisePhrases.contains(where: { lowerSeg.contains($0) }) {
                        continue
                    }
                    if seg.noSpeechProb > 0.72 && (lowerSeg == "thank you" || lowerSeg == "thank you." || lowerSeg == "you") {
                        continue
                    }
                    if let segWords = seg.words, !segWords.isEmpty {
                        for w in segWords {
                            let cleanedRaw = w.word
                                .replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let parts = cleanedRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                            guard !parts.isEmpty else { continue }
                            let s0 = max(0, Double(w.start))
                            if let timeUpperBound, s0 >= timeUpperBound { continue }
                            let e0 = max(s0 + 0.05, Double(w.end))
                            let stepDur = (e0 - s0) / Double(parts.count)
                            for (idx, p) in parts.enumerated() {
                                let tok = SongAudioListener.normalizeToken(p)
                                guard !tok.isEmpty else { continue }
                                let ws = s0 + Double(idx) * stepDur
                                let we = max(ws + 0.05, s0 + Double(idx + 1) * stepDur)
                                localWords.append(TranscribedWord(rawText: p, token: tok, startTime: ws, endTime: we))
                            }
                        }
                    } else {
                        let cleanSeg = seg.text
                            .replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let parts = cleanSeg.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                        guard !parts.isEmpty else { continue }
                        let s0 = max(0, Double(seg.start))
                        if let timeUpperBound, s0 >= timeUpperBound { continue }
                        let e0 = max(s0 + 0.2, Double(seg.end))
                        let stepDur = (e0 - s0) / Double(parts.count)
                        for (idx, p) in parts.enumerated() {
                            let tok = SongAudioListener.normalizeToken(p)
                            guard !tok.isEmpty else { continue }
                            let ws = s0 + Double(idx) * stepDur
                            let we = max(ws + 0.05, s0 + Double(idx + 1) * stepDur)
                            localWords.append(TranscribedWord(rawText: p, token: tok, startTime: ws, endTime: we))
                        }
                    }
                }
            }
            return (localWords, localLangs, localSum, localWeight)
        }

        let mainPass = extractWords(from: results)
        words = mainPass.words
        langCounts = mainPass.langs
        noSpeechSum = mainPass.nsSum
        noSpeechWeight = mainPass.nsWeight
        let dominantLang = langCounts.max(by: { $0.value < $1.value })?.key

        // Opening blind-spot rescue: when loud opening vocals (e.g. heavy vocoder/autotune hooks) precede a loud rap verse
        // in window 0, decode just the opening slice once with the resolved song language.
        let firstWordTime = words.first?.startTime ?? totalSec
        if totalSec >= 20.0 && firstWordTime >= 9.0 {
            let checkEnd = min(pcm.samples.count, Int(12.0 * Double(WhisperKit.sampleRate)))
            if checkEnd > WhisperKit.sampleRate * 2 {
                let sumSq = pcm.samples[0..<checkEnd].reduce(0.0) { $0 + Double($1 * $1) }
                let openingRMS = sqrt(sumSq / Double(checkEnd))
                if openingRMS > 0.03 {
                    let rescueSamples = Array(pcm.samples[0..<min(pcm.samples.count, Int(16.0 * Double(WhisperKit.sampleRate)))])
                    let rescueLang = dominantLang ?? languageHint ?? "en"
                    let rescueOpts = DecodingOptions(
                        verbose: false,
                        task: .transcribe,
                        language: rescueLang,
                        temperature: 0.0,
                        temperatureIncrementOnFallback: 0.25,
                        temperatureFallbackCount: 1,
                        usePrefillPrompt: true,
                        detectLanguage: false,
                        skipSpecialTokens: true,
                        withoutTimestamps: false,
                        wordTimestamps: true,
                        suppressBlank: true,
                        noSpeechThreshold: 0.96,
                        chunkingStrategy: nil
                    )
                    if let rescueResults = try? await kit.transcribe(audioArray: rescueSamples, decodeOptions: rescueOpts) {
                        let rescued = extractWords(from: rescueResults, timeUpperBound: firstWordTime - 0.15).words
                        if !rescued.isEmpty {
                            words = rescued + words
                        }
                    }
                }
            }
        }

        let avgNoSpeech = noSpeechWeight > 0 ? (noSpeechSum / noSpeechWeight) : 0.0
        guard !words.isEmpty || avgNoSpeech >= 0.90 else { return nil }
        return TranscriptionSummary(
            words: words,
            detectedLanguage: dominantLang,
            avgNoSpeechProb: avgNoSpeech,
            durationSeconds: totalSec
        )
    }

    private func ensureLoaded(allowDownload: Bool) async -> WhisperKit? {
        if let whisperKit { return whisperKit }
        if let existingTask = initTask {
            if !allowDownload && initTaskIsNetworkDownload {
                return nil
            }
            return await existingTask.value
        }
        if let lastFailureAt, Date().timeIntervalSince(lastFailureAt) < 120 {
            return nil
        }

        let cachedPath: String? = {
            guard let saved = UserDefaults.standard.string(forKey: Self.savedFolderDefaultsKey),
                  !saved.isEmpty,
                  FileManager.default.fileExists(atPath: saved) else {
                return nil
            }
            return saved
        }()

        if cachedPath == nil && !allowDownload {
            return nil
        }

        let task = Task<WhisperKit?, Never> {
            Self.relocateLegacyDocumentsHuggingFaceFolder()
            var loadedKit: WhisperKit?
            if let cachedPath {
                let cachedConfig = WhisperKitConfig(
                    downloadBase: Self.modelsBaseURL,
                    modelFolder: cachedPath,
                    tokenizerFolder: Self.modelsBaseURL,
                    computeOptions: Self.backgroundSafeComputeOptions,
                    verbose: false,
                    logLevel: .none,
                    prewarm: false,
                    load: true,
                    download: false
                )
                loadedKit = await Self.loadKitWithTimeout(config: cachedConfig, timeoutSeconds: 18.0)
                if loadedKit == nil {
                    UserDefaults.standard.removeObject(forKey: Self.savedFolderDefaultsKey)
                }
            }
            if loadedKit == nil, allowDownload {
                let primaryConfig = WhisperKitConfig(
                    model: Self.primaryVariantName,
                    downloadBase: Self.modelsBaseURL,
                    tokenizerFolder: Self.modelsBaseURL,
                    computeOptions: Self.backgroundSafeComputeOptions,
                    verbose: false,
                    logLevel: .none,
                    prewarm: false,
                    load: true,
                    download: true
                )
                // First-time download + CoreML compile of the model can take minutes on a phone; a 45s cap could cancel
                // it on every launch, leaving adlib/vocal transcription on the weaker fallback recognizer.
                loadedKit = await Self.loadKitWithTimeout(config: primaryConfig, timeoutSeconds: Self.downloadLoadTimeoutSeconds)
                if loadedKit == nil {
                    let fallbackConfig = WhisperKitConfig(
                        model: Self.fallbackVariantName,
                        downloadBase: Self.modelsBaseURL,
                        tokenizerFolder: Self.modelsBaseURL,
                        computeOptions: Self.backgroundSafeComputeOptions,
                        verbose: false,
                        logLevel: .none,
                        prewarm: false,
                        load: true,
                        download: true
                    )
                    loadedKit = await Self.loadKitWithTimeout(config: fallbackConfig, timeoutSeconds: Self.downloadLoadTimeoutSeconds)
                }
            }
            guard let kit = loadedKit else {
                return nil
            }
            if let folderPath = kit.modelFolder?.path, !folderPath.isEmpty {
                UserDefaults.standard.set(folderPath, forKey: Self.savedFolderDefaultsKey)
            }
            return kit
        }

        initTask = task
        initTaskIsNetworkDownload = (cachedPath == nil && allowDownload)
        let loaded = await task.value
        initTask = nil
        initTaskIsNetworkDownload = false
        if let loaded {
            self.whisperKit = loaded
            self.lastFailureAt = nil
        } else {
            self.lastFailureAt = Date()
        }
        return loaded
    }

    private final class KitTimeoutGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var result: WhisperKit?
        private var continuation: CheckedContinuation<WhisperKit?, Never>?

        func wait(_ cont: CheckedContinuation<WhisperKit?, Never>) {
            lock.lock()
            if finished {
                let value = result
                result = nil
                lock.unlock()
                cont.resume(returning: value)
                return
            }
            continuation = cont
            lock.unlock()
        }

        func finish(_ kit: WhisperKit?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            if cont == nil {
                result = kit
            }
            lock.unlock()
            cont?.resume(returning: kit)
        }
    }

    private static func loadKitWithTimeout(config: WhisperKitConfig, timeoutSeconds: Double) async -> WhisperKit? {
        let gate = KitTimeoutGate()
        let loadTask = Task {
            let kit = try? await WhisperKit(config)
            gate.finish(kit)
        }
        let timerTask = Task {
            let ns = UInt64(max(1.0, timeoutSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            loadTask.cancel()
            gate.finish(nil)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<WhisperKit?, Never>) in
                gate.wait(cont)
            }
        } onCancel: {
            timerTask.cancel()
            loadTask.cancel()
            gate.finish(nil)
        }
    }

    /// Extracts 16 kHz PCM and applies stereo Mid-Side Wiener center-vocal enhancement + sub-120 Hz attenuation
    /// so drums, wide guitars, and synths disturb Whisper far less while keeping exact sample timestamps.
    private static func extract16kVocalEnhancedPCM(
        from url: URL,
        maxSeconds: Double
    ) async -> (samples: [Float], durationSeconds: Double)? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 2 else {
            return nil
        }
        let targetSec = min(duration, maxSeconds)
        return await Task.detached(priority: .utility) {
            guard let reader = try? AVAssetReader(asset: asset),
                  let track = asset.tracks(withMediaType: .audio).first else {
                return nil
            }
            let sampleRate: Double = Double(WhisperKit.sampleRate)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            let maxFrames = Int(sampleRate * targetSec)
            var midSamples: [Float] = []
            var sideSamples: [Float] = []
            midSamples.reserveCapacity(min(maxFrames, Int(sampleRate * 300)))
            sideSamples.reserveCapacity(min(maxFrames, Int(sampleRate * 300)))

            var sumMidSq: Double = 0
            var sumSideSq: Double = 0
            while reader.status == .reading, midSamples.count < maxFrames {
                guard let sb = output.copyNextSampleBuffer(),
                      let bb = CMSampleBufferGetDataBuffer(sb) else {
                    break
                }
                var totalLen = 0
                var pointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(
                    bb,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLen,
                    dataPointerOut: &pointer
                ) == noErr, let ptr = pointer, totalLen >= 8 {
                    let frameCount = min(totalLen / (2 * MemoryLayout<Float>.size), maxFrames - midSamples.count)
                    ptr.withMemoryRebound(to: Float.self, capacity: frameCount * 2) { fPtr in
                        for idx in 0..<frameCount {
                            let l = fPtr[idx * 2]
                            let r = fPtr[idx * 2 + 1]
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
            guard !midSamples.isEmpty else { return nil }
            let actualDur = Double(midSamples.count) / sampleRate

            // If effectively mono or very small, return clean mid channel directly.
            let n = midSamples.count
            let fftSize = 1024
            let log2N = vDSP_Length(10)
            let hop = 256
            let hasStereoSide = sqrt(sumSideSq / Double(n)) > 0.05 * sqrt(sumMidSq / Double(n) + 1e-12)
            guard n >= fftSize, let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
                return (midSamples, actualDur)
            }
            defer { vDSP_destroy_fftsetup(setup) }

            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            let halfN = fftSize / 2

            // Empirical calibration so FFT + IFFT round-trip is guaranteed unit-gain across Accelerate versions.
            var calReal = [Float](repeating: 0, count: halfN)
            var calImag = [Float](repeating: 0, count: halfN)
            calReal[16] = 1.0
            calReal.withUnsafeMutableBufferPointer { rp in
                calImag.withUnsafeMutableBufferPointer { ip in
                    var cs = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &cs, 1, log2N, FFTDirection(FFT_FORWARD))
                    vDSP_fft_zrip(setup, &cs, 1, log2N, FFTDirection(FFT_INVERSE))
                }
            }
            let roundTripScale: Float = abs(calReal[16]) > 1e-3 ? (1.0 / calReal[16]) : (1.0 / Float(2 * fftSize))

            var out = [Float](repeating: 0, count: n)
            var normW = [Float](repeating: 0, count: n)

            var wMid = [Float](repeating: 0, count: fftSize)
            var wSide = [Float](repeating: 0, count: fftSize)
            var realM = [Float](repeating: 0, count: halfN)
            var imagM = [Float](repeating: 0, count: halfN)
            var realS = [Float](repeating: 0, count: halfN)
            var imagS = [Float](repeating: 0, count: halfN)
            var recon = [Float](repeating: 0, count: fftSize)

            var pos = 0
            while pos + fftSize <= n {
                midSamples.withUnsafeBufferPointer { mPtr in
                    vDSP_vmul(mPtr.baseAddress! + pos, 1, window, 1, &wMid, 1, vDSP_Length(fftSize))
                }
                if hasStereoSide {
                    sideSamples.withUnsafeBufferPointer { sPtr in
                        vDSP_vmul(sPtr.baseAddress! + pos, 1, window, 1, &wSide, 1, vDSP_Length(fftSize))
                    }
                }

                realM.withUnsafeMutableBufferPointer { rMp in
                    imagM.withUnsafeMutableBufferPointer { iMp in
                        var sM = DSPSplitComplex(realp: rMp.baseAddress!, imagp: iMp.baseAddress!)
                        wMid.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                vDSP_ctoz(cp, 2, &sM, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(setup, &sM, 1, log2N, FFTDirection(FFT_FORWARD))

                        if hasStereoSide {
                            realS.withUnsafeMutableBufferPointer { rSp in
                                imagS.withUnsafeMutableBufferPointer { iSp in
                                    var sS = DSPSplitComplex(realp: rSp.baseAddress!, imagp: iSp.baseAddress!)
                                    wSide.withUnsafeBufferPointer { wsp in
                                        wsp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                            vDSP_ctoz(cp, 2, &sS, 1, vDSP_Length(halfN))
                                        }
                                    }
                                    vDSP_fft_zrip(setup, &sS, 1, log2N, FFTDirection(FFT_FORWARD))

                                    rMp[0] = 0; iMp[0] = 0
                                    for b in 1..<halfN {
                                        let pm = rMp[b] * rMp[b] + iMp[b] * iMp[b]
                                        let ps = rSp[b] * rSp[b] + iSp[b] * iSp[b]
                                        var g = (pm - 0.72 * ps) / (pm + 1e-6)
                                        g = max(0.16, min(1.0, g))
                                        if b < 8 { g *= 0.25 } // attenuate < 125 Hz sub-bass/kick
                                        rMp[b] *= g
                                        iMp[b] *= g
                                    }
                                }
                            }
                        } else {
                            rMp[0] = 0; iMp[0] = 0
                            for b in 1..<8 {
                                rMp[b] *= 0.25
                                iMp[b] *= 0.25
                            }
                        }

                        vDSP_fft_zrip(setup, &sM, 1, log2N, FFTDirection(FFT_INVERSE))
                        recon.withUnsafeMutableBufferPointer { recPtr in
                            recPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                vDSP_ztoc(&sM, 1, cp, 2, vDSP_Length(halfN))
                            }
                        }
                    }
                }

                for k in 0..<fftSize {
                    let w = window[k]
                    out[pos + k] += recon[k] * roundTripScale * w
                    normW[pos + k] += w * w
                }
                pos += hop
            }

            for i in 0..<n {
                if normW[i] > 1e-5 {
                    out[i] = max(-1.0, min(1.0, out[i] / normW[i]))
                } else {
                    out[i] = midSamples[i]
                }
            }
            return (out, actualDur)
        }.value
    }
}
