import AVFoundation
import Foundation
import Observation

enum EqualizerPreset: String, CaseIterable, Identifiable, Codable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case vocal = "Vocal"
    case treble = "Treble"
    case electronic = "Electronic"
    case rock = "Rock"
    case acoustic = "Acoustic"
    case custom = "Custom"

    var id: String { rawValue }

    var gains: [Float] {
        switch self {
        case .flat:       return [0, 0, 0, 0, 0]
        case .bassBoost:  return [7, 4.5, 0, -1, 0]
        case .vocal:      return [-2, 1, 4.5, 3.5, 1]
        case .treble:     return [0, 0, 1.5, 4.5, 6.5]
        case .electronic: return [5.5, 3, -1, 2.5, 5]
        case .rock:       return [4.5, 2, -1.5, 2.5, 4]
        case .acoustic:   return [3, 1.5, 1, 2.5, 3.5]
        case .custom:     return [0, 0, 0, 0, 0]
        }
    }

    static var selectablePresets: [EqualizerPreset] {
        allCases.filter { $0 != .custom }
    }
}

@Observable
final class EqualizerAudioPlayer {
    private let engine = AVAudioEngine()
    private let deckA = AVAudioPlayerNode()
    private let deckB = AVAudioPlayerNode()
    private let deckMixerNode = AVAudioMixerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 5)
    private let timePitchNode = AVAudioUnitTimePitch()

    private var activeDeckIsA = true
    private var activeNode: AVAudioPlayerNode { activeDeckIsA ? deckA : deckB }
    private var outgoingNode: AVAudioPlayerNode { activeDeckIsA ? deckB : deckA }
    private var activeBus: AVAudioNodeBus { activeDeckIsA ? 0 : 1 }

    let frequencies: [Float] = [60, 230, 910, 3600, 14000] // Hz
    let frequencyLabels = ["60Hz", "230Hz", "910Hz", "3.6kHz", "14kHz"]

    var bandGains: [Float] = [0, 0, 0, 0, 0]
    var isEnabled = true
    var selectedPreset: EqualizerPreset = .flat

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0

    var onPlaybackEnded: (() -> Void)?
    var onProgressUpdate: ((Double, Double) -> Void)?

    private var currentFile: AVAudioFile?
    private var deckAFormat: AVAudioFormat?
    private var deckBFormat: AVAudioFormat?
    private var seekOffsetSeconds: Double = 0
    private var scheduleGeneration: UInt64 = 0
    private var progressTimer: Timer?
    private var crossfadeTimer: Timer?
    private var configChangeObserver: NSObjectProtocol?

    private static let gainsDefaultsKey = "pocketmedia.eq.gains"
    private static let enabledDefaultsKey = "pocketmedia.eq.enabled"
    private static let presetDefaultsKey = "pocketmedia.eq.preset"

    init() {
        setupEQ()
        loadSavedSettings()

        engine.attach(deckA)
        engine.attach(deckB)
        engine.attach(deckMixerNode)
        engine.attach(eqNode)
        engine.attach(timePitchNode)

        engine.connect(deckA, to: deckMixerNode, fromBus: 0, toBus: 0, format: nil)
        engine.connect(deckB, to: deckMixerNode, fromBus: 0, toBus: 1, format: nil)
        engine.connect(deckMixerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: timePitchNode, format: nil)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.deckAFormat = nil
            self.deckBFormat = nil
            self.abortCrossfade()
            if self.isPlaying {
                self.pause()
            }
        }
    }

    deinit {
        progressTimer?.invalidate()
        crossfadeTimer?.invalidate()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        deckA.stop()
        deckB.stop()
        engine.stop()
    }

    private func setupEQ() {
        for (index, freq) in frequencies.enumerated() {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1.0
            band.gain = 0.0 // Range: -12.0 dB to +12.0 dB
            band.bypass = false
        }
    }

    func setBandGain(bandIndex: Int, gain: Float) {
        guard bandIndex >= 0, bandIndex < eqNode.bands.count else { return }
        let clamped = max(-12, min(12, gain))
        eqNode.bands[bandIndex].gain = clamped
        bandGains[bandIndex] = clamped
        selectedPreset = .custom
        saveSettings()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        for band in eqNode.bands {
            band.bypass = !enabled
        }
        saveSettings()
    }

    func applyPreset(_ preset: EqualizerPreset) {
        let gains = preset.gains
        for (index, gain) in gains.enumerated() where index < eqNode.bands.count {
            let clamped = max(-12, min(12, gain))
            eqNode.bands[index].gain = clamped
            bandGains[index] = clamped
        }
        selectedPreset = preset
        if !isEnabled {
            setEnabled(true)
        } else {
            saveSettings()
        }
    }

    func reset() {
        applyPreset(.flat)
    }

    private var activeFormat: AVAudioFormat? {
        get { activeDeckIsA ? deckAFormat : deckBFormat }
        set {
            if activeDeckIsA { deckAFormat = newValue } else { deckBFormat = newValue }
        }
    }

    private func connectActiveDeck(format: AVAudioFormat, forceReconnect: Bool = false) {
        if activeFormat == format && !forceReconnect { return }
        engine.connect(activeNode, to: deckMixerNode, fromBus: 0, toBus: activeBus, format: format)
        activeFormat = format
    }

    private func abortCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        outgoingNode.stop()
        outgoingNode.volume = 1.0
        activeNode.volume = 1.0
    }

    func play(url: URL, fadeInDuration: Double = 0) throws {
        abortCrossfade()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate

        currentFile = file
        duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        currentTime = 0
        seekOffsetSeconds = 0

        scheduleGeneration &+= 1
        deckA.stop()
        deckB.stop()
        deckA.volume = 1.0
        deckB.volume = 1.0

        connectActiveDeck(format: format)

        timePitchNode.rate = playbackRate
        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }

        scheduleSegment(fromSeconds: 0)

        if fadeInDuration > 0.1 {
            activeNode.volume = 0.0
            activeNode.play()
            startLinearVolumeFade(node: activeNode, duration: min(fadeInDuration, 3.0))
        } else {
            activeNode.volume = 1.0
            activeNode.play()
        }
        isPlaying = true
        startProgressTimer()
    }

    /// Seamlessly crossfades out the outgoing song while fading in the next song on the alternate deck
    /// using an equal-power S-curve over `crossfadeDuration` seconds.
    func crossfadeTo(url: URL, duration crossfadeDuration: Double) throws {
        let clampedFade = max(0.5, crossfadeDuration)
        let newFile = try AVAudioFile(forReading: url)
        let format = newFile.processingFormat
        let sampleRate = format.sampleRate

        // Increment generation first so the outgoing deck's previous completion callback is cleanly ignored.
        scheduleGeneration &+= 1

        crossfadeTimer?.invalidate()
        crossfadeTimer = nil

        // Ensure any earlier stale third track is stopped cleanly before flipping decks.
        outgoingNode.stop()
        outgoingNode.volume = 1.0

        let fadingOutNode = activeNode
        let initialOutVolume = fadingOutNode.volume
        activeDeckIsA.toggle()
        let fadingInNode = activeNode

        fadingInNode.stop()
        fadingInNode.volume = 0.0
        connectActiveDeck(format: format, forceReconnect: activeFormat != format)

        currentFile = newFile
        duration = sampleRate > 0 ? Double(newFile.length) / sampleRate : 0
        currentTime = 0
        seekOffsetSeconds = 0

        timePitchNode.rate = playbackRate
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        scheduleSegment(fromSeconds: 0)
        fadingInNode.play()
        isPlaying = true
        startProgressTimer()

        let startDate = Date()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak fadingOutNode, weak fadingInNode] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(startDate)
            let t = min(1.0, max(0.0, elapsed / clampedFade))
            let angle = t * (.pi / 2.0)

            fadingOutNode?.volume = initialOutVolume * Float(cos(angle))
            fadingInNode?.volume = Float(sin(angle))

            if t >= 1.0 {
                timer.invalidate()
                self.crossfadeTimer = nil
                fadingOutNode?.stop()
                fadingOutNode?.volume = 1.0
                fadingInNode?.volume = 1.0
            }
        }
    }

    private func startLinearVolumeFade(node: AVAudioPlayerNode, duration: Double) {
        crossfadeTimer?.invalidate()
        let startDate = Date()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak node] timer in
            let elapsed = Date().timeIntervalSince(startDate)
            let t = min(1.0, max(0.0, elapsed / max(0.1, duration)))
            node?.volume = Float(sin(t * .pi / 2.0))
            if t >= 1.0 {
                timer.invalidate()
                node?.volume = 1.0
                self?.crossfadeTimer = nil
            }
        }
    }

    func pause() {
        guard currentFile != nil else { return }
        abortCrossfade()
        updateElapsedTime()
        seekOffsetSeconds = currentTime
        activeNode.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() {
        guard let file = currentFile else { return }
        do {
            if activeFormat == nil {
                let format = file.processingFormat
                let resumeFrom = currentTime
                connectActiveDeck(format: format, forceReconnect: true)
                timePitchNode.rate = playbackRate
                engine.prepare()
                try engine.start()
                scheduleSegment(fromSeconds: resumeFrom)
                activeNode.volume = 1.0
                activeNode.play()
            } else {
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                if !activeNode.isPlaying {
                    if currentTime >= duration && duration > 0 {
                        scheduleSegment(fromSeconds: 0)
                    }
                    activeNode.volume = 1.0
                    activeNode.play()
                }
            }
            isPlaying = true
            startProgressTimer()
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        scheduleGeneration &+= 1
        stopProgressTimer()
        abortCrossfade()
        deckA.stop()
        deckB.stop()
        deckA.volume = 1.0
        deckB.volume = 1.0
        currentFile = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        seekOffsetSeconds = 0
    }

    func seek(to seconds: Double) {
        guard currentFile != nil else { return }
        abortCrossfade()
        let clamped = min(max(seconds, 0), max(duration, 0))
        let wasPlaying = isPlaying

        scheduleSegment(fromSeconds: clamped)
        if wasPlaying {
            do {
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                activeNode.volume = 1.0
                activeNode.play()
                isPlaying = true
                startProgressTimer()
            } catch {
                isPlaying = false
            }
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        timePitchNode.rate = rate
    }

    func installAudioCaptureTap(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        engine.mainMixerNode.removeTap(onBus: 0)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            handler(buffer, time)
        }
    }

    func removeAudioCaptureTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    // MARK: - Private Helpers

    private func scheduleSegment(fromSeconds seconds: Double) {
        guard let file = currentFile else { return }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return }

        let totalFrames = file.length
        let startFrame = min(max(AVAudioFramePosition((seconds * sampleRate).rounded()), 0), totalFrames)
        let remainingFrames = totalFrames - startFrame

        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let targetNode = activeNode
        targetNode.stop()

        seekOffsetSeconds = Double(startFrame) / sampleRate
        currentTime = seekOffsetSeconds

        guard remainingFrames > 0 else {
            isPlaying = false
            stopProgressTimer()
            onPlaybackEnded?()
            return
        }

        let frameCount = AVAudioFrameCount(min(remainingFrames, Int64(UInt32.max)))
        targetNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.isPlaying = false
                self.stopProgressTimer()
                self.currentTime = self.duration
                self.onPlaybackEnded?()
            }
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateElapsedTime()
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateElapsedTime() {
        guard let file = currentFile else { return }
        let sampleRate = file.processingFormat.sampleRate
        let targetNode = activeNode
        guard sampleRate > 0,
              let nodeTime = targetNode.lastRenderTime,
              let playerTime = targetNode.playerTime(forNodeTime: nodeTime) else {
            return
        }

        let playedSeconds = max(0, Double(playerTime.sampleTime) / sampleRate)
        let updated = max(0, seekOffsetSeconds + playedSeconds)
        currentTime = duration > 0 ? min(updated, duration) : updated
        onProgressUpdate?(currentTime, duration)
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(bandGains, forKey: Self.gainsDefaultsKey)
        defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
        defaults.set(selectedPreset.rawValue, forKey: Self.presetDefaultsKey)
    }

    private func loadSavedSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledDefaultsKey) != nil {
            isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        }
        if let savedRaw = defaults.string(forKey: Self.presetDefaultsKey),
           let preset = EqualizerPreset(rawValue: savedRaw) {
            selectedPreset = preset
        }
        if let savedGains = defaults.array(forKey: Self.gainsDefaultsKey) as? [NSNumber],
           savedGains.count == frequencies.count {
            for (index, number) in savedGains.enumerated() {
                let clamped = max(-12, min(12, number.floatValue))
                bandGains[index] = clamped
                eqNode.bands[index].gain = clamped
            }
        }
        for band in eqNode.bands {
            band.bypass = !isEnabled
        }
    }
}
