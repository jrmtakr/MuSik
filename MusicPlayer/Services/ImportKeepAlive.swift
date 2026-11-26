import AVFoundation
import Foundation

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
