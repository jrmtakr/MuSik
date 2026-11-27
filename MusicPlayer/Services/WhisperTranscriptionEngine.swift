import AVFoundation
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

    private static let variantName = "openai_whisper-base"
    private static let savedFolderDefaultsKey = "musejrm.whisper.modelFolder.v1"

    private var whisperKit: WhisperKit?
    private var initTask: Task<WhisperKit?, Never>?
    private var lastFailureAt: Date?

    private static var modelsBaseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    /// Warms up or downloads the local Whisper CoreML model silently in background after app launch.
    func warmUpInBackground() async {
        _ = await ensureLoaded(allowDownload: true)
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
        allowDownload: Bool = true,
        onProgress: (@Sendable (Int, Int, Double) -> Void)? = nil
    ) async -> [TranscribedWord]? {
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
        guard let pcm = await Self.extract16kMonoPCM(from: prepared.url, maxSeconds: maxSeconds),
              !pcm.samples.isEmpty else {
            return nil
        }

        let totalSec = pcm.durationSeconds
        let totalChunks = max(1, Int(ceil(totalSec / 30.0)))
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            suppressBlank: true,
            noSpeechThreshold: 0.65,
            chunkingStrategy: .vad
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
        for result in results {
            for seg in result.segments {
                if seg.noSpeechProb > 0.85 { continue }
                if let segWords = seg.words, !segWords.isEmpty {
                    for w in segWords {
                        let cleanedRaw = w.word
                            .replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let parts = cleanedRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                        guard !parts.isEmpty else { continue }
                        let s0 = max(0, Double(w.start))
                        let e0 = max(s0 + 0.05, Double(w.end))
                        let stepDur = (e0 - s0) / Double(parts.count)
                        for (idx, p) in parts.enumerated() {
                            let tok = SongAudioListener.normalizeToken(p)
                            guard !tok.isEmpty else { continue }
                            let ws = s0 + Double(idx) * stepDur
                            let we = max(ws + 0.05, s0 + Double(idx + 1) * stepDur)
                            words.append(TranscribedWord(rawText: p, token: tok, startTime: ws, endTime: we))
                        }
                    }
                } else {
                    let cleanSeg = seg.text
                        .replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = cleanSeg.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    guard !parts.isEmpty else { continue }
                    let s0 = max(0, Double(seg.start))
                    let e0 = max(s0 + 0.2, Double(seg.end))
                    let stepDur = (e0 - s0) / Double(parts.count)
                    for (idx, p) in parts.enumerated() {
                        let tok = SongAudioListener.normalizeToken(p)
                        guard !tok.isEmpty else { continue }
                        let ws = s0 + Double(idx) * stepDur
                        let we = max(ws + 0.05, s0 + Double(idx + 1) * stepDur)
                        words.append(TranscribedWord(rawText: p, token: tok, startTime: ws, endTime: we))
                    }
                }
            }
        }
        return words.isEmpty ? nil : words
    }

    private func ensureLoaded(allowDownload: Bool) async -> WhisperKit? {
        if let whisperKit { return whisperKit }
        if let existingTask = initTask {
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
            let config: WhisperKitConfig
            if let cachedPath {
                config = WhisperKitConfig(
                    modelFolder: cachedPath,
                    verbose: false,
                    logLevel: .none,
                    prewarm: false,
                    load: true,
                    download: false
                )
            } else {
                config = WhisperKitConfig(
                    model: Self.variantName,
                    downloadBase: Self.modelsBaseURL,
                    verbose: false,
                    logLevel: .none,
                    prewarm: false,
                    load: true,
                    download: true
                )
            }
            guard let kit = try? await WhisperKit(config) else {
                return nil
            }
            if let folderPath = kit.modelFolder?.path, !folderPath.isEmpty {
                UserDefaults.standard.set(folderPath, forKey: Self.savedFolderDefaultsKey)
            }
            return kit
        }

        initTask = task
        let loaded = await task.value
        initTask = nil
        if let loaded {
            self.whisperKit = loaded
            self.lastFailureAt = nil
        } else {
            self.lastFailureAt = Date()
        }
        return loaded
    }

    private static func extract16kMonoPCM(
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
                AVNumberOfChannelsKey: 1,
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

            let maxSamples = Int(sampleRate * targetSec)
            var floats: [Float] = []
            floats.reserveCapacity(min(maxSamples, Int(sampleRate * 300)))
            while reader.status == .reading, floats.count < maxSamples {
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
                ) == noErr, let ptr = pointer, totalLen >= 4 {
                    let count = min(totalLen / MemoryLayout<Float>.size, maxSamples - floats.count)
                    ptr.withMemoryRebound(to: Float.self, capacity: count) { fPtr in
                        floats.append(contentsOf: UnsafeBufferPointer(start: fPtr, count: count))
                    }
                }
                CMSampleBufferInvalidate(sb)
            }
            let actualDur = Double(floats.count) / sampleRate
            return floats.isEmpty ? nil : (floats, actualDur)
        }.value
    }
}
