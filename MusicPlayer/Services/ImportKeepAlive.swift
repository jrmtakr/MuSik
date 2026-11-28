import AVFoundation
import BackgroundTasks
import Foundation
import UIKit

/// Keeps MuseJRM running while a playlist import is in progress and the screen is locked or the app
/// is in the background.
///
/// iOS suspends a backgrounded app after ~30 seconds unless it is playing audio. Downloads themselves
/// continue in the background URLSession, but *finding* each song's stream (YouTube lookups, the
/// built-in browser resolver) needs the app awake. While imports are running and nothing else is
/// playing, this plays silence (mixed with other apps, so it never interrupts your music or shows on
/// the lock screen). It stops as soon as imports finish, you return to the app, or you start playback.
///
/// iOS does not let any app keep working after you swipe it away in the app switcher — that is handled
/// separately: the queue is saved and resumes automatically the next time MuseJRM opens.
@MainActor
final class ImportKeepAlive {
    static let shared = ImportKeepAlive()
    static let enabledDefaultsKey = "musicplayer.import.keepAliveWhenLocked"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool) ?? true
    }

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var isRunning: Bool { player != nil }

    private init() {}

    func start() {
        guard Self.isEnabled, player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let silent = try AVAudioPlayer(data: Self.silentWAV(seconds: 2))
            silent.numberOfLoops = -1
            silent.volume = 1 // the samples are all zero, so this is silent
            silent.prepareToPlay()
            silent.play()
            player = silent
        } catch {
            player = nil
        }

        // If a phone call etc. interrupts us, pick back up afterwards.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in
                self?.player?.play()
            }
        }
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        // Restore the normal (non-mixing) music category so lock-screen controls keep working
        // for real playback. Only touch the session if the music player isn't using it right now.
        if !MediaManager.shared.isPlaying {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        }
    }

    /// A tiny in-memory 16-bit mono PCM WAV file full of zeros.
    private static func silentWAV(seconds: Double) -> Data {
        let sampleRate: UInt32 = 8000
        let sampleCount = UInt32(Double(sampleRate) * seconds)
        let dataSize = sampleCount * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))          // PCM header size
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(sampleRate)
        append(sampleRate * 2)      // byte rate
        append(UInt16(2))           // block align
        append(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

/// Coordinates silent audio keep-alive, `UIApplication.beginBackgroundTask`, and `BGProcessingTask`
/// whenever ANY caching, download, conversion, playlist import, or song analysis is active while the
/// user swipes out of MuseJRM or locks the screen.
@MainActor
final class BackgroundWorkCoordinator {
    static let shared = BackgroundWorkCoordinator()
    static let cacheAnalysisBGTaskIdentifier = "com.personal.musicplayer.cache.analysis"

    private var didRegisterBGTask = false
    private var didStartObserving = false
    private var isSceneBackgrounded = false
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeBGProcessingTask: BGProcessingTask?
    private var hasScheduledBGProcessingThisBackgroundSession = false

    private init() {}

    var hasActiveCacheOrAnalysis: Bool {
        PlaylistImportManager.shared.hasActiveBackgroundWork
            || WebMediaDownloader.shared.hasPendingWork
            || SongIdentificationService.shared.hasPendingWork
            || WholeSongAIService.shared.activeTrackPath != nil
            || MediaManager.shared.convertingItemID != nil
    }

    func registerBackgroundTasks() {
        guard !didRegisterBGTask else { return }
        didRegisterBGTask = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.cacheAnalysisBGTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleBGProcessingTask(processingTask)
            }
        }
    }

    func startObserving() {
        guard !didStartObserving else { return }
        didStartObserving = true

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteScenePhase(isBackground: true)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteScenePhase(isBackground: false)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteScenePhase(isBackground: false)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MediaManager.shared.flushStateBeforeTermination()
                DiscoverQueueService.shared.flushPlayedHistoryToDisk()
                ImportKeepAlive.shared.stop()
            }
        }
    }

    func noteScenePhase(isBackground: Bool) {
        isSceneBackgrounded = isBackground
        if !isBackground {
            hasScheduledBGProcessingThisBackgroundSession = false
            endBackgroundAssertion()
            ImportKeepAlive.shared.stop()
            SongIdentificationService.shared.resumePendingIfNeeded()
        } else {
            refreshBackgroundState()
        }
    }

    func refreshBackgroundState() {
        let inBackground = isSceneBackgrounded || (UIApplication.shared.applicationState == .background)
        let active = hasActiveCacheOrAnalysis

        guard active else {
            ImportKeepAlive.shared.stop()
            endBackgroundAssertion()
            completeBGProcessingTaskIfIdle()
            return
        }

        guard inBackground else {
            ImportKeepAlive.shared.stop()
            endBackgroundAssertion()
            return
        }

        beginBackgroundAssertionIfNeeded()
        if !MediaManager.shared.isPlaying {
            ImportKeepAlive.shared.start()
        } else {
            ImportKeepAlive.shared.stop()
        }
        scheduleBGProcessingTaskIfNeeded()
    }

    private func beginBackgroundAssertionIfNeeded() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "MuseJRM.CacheAndAnalysis") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleBGProcessingTaskIfNeeded()
                self.endBackgroundAssertion()
            }
        }
    }

    private func endBackgroundAssertion() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    private func scheduleBGProcessingTaskIfNeeded() {
        guard !hasScheduledBGProcessingThisBackgroundSession else { return }
        hasScheduledBGProcessingThisBackgroundSession = true
        let request = BGProcessingTaskRequest(identifier: Self.cacheAnalysisBGTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBGProcessingTask(_ task: BGProcessingTask) {
        activeBGProcessingTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                MediaManager.shared.flushStateBeforeTermination()
                self?.activeBGProcessingTask?.setTaskCompleted(success: false)
                self?.activeBGProcessingTask = nil
            }
        }
        SongIdentificationService.shared.resumePendingIfNeeded()
        if !hasActiveCacheOrAnalysis {
            completeBGProcessingTaskIfIdle()
        }
    }

    private func completeBGProcessingTaskIfIdle() {
        guard let task = activeBGProcessingTask else { return }
        task.setTaskCompleted(success: true)
        activeBGProcessingTask = nil
    }
}
