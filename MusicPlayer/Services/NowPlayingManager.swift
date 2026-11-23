import MediaPlayer
import UIKit

final class NowPlayingManager {
    static func setupRemoteCommands(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPrev: @escaping () -> Void,
        onTogglePlayPause: (() -> Void)? = nil,
        onSeek: ((TimeInterval) -> Void)? = nil
    ) {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            DispatchQueue.main.async { onPlay() }
            return .success
        }

        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            DispatchQueue.main.async { onPause() }
            return .success
        }

        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            DispatchQueue.main.async { onNext() }
            return .success
        }

        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            DispatchQueue.main.async { onPrev() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        if let onTogglePlayPause {
            commandCenter.togglePlayPauseCommand.isEnabled = true
            commandCenter.togglePlayPauseCommand.addTarget { _ in
                DispatchQueue.main.async { onTogglePlayPause() }
                return .success
            }
        } else {
            commandCenter.togglePlayPauseCommand.isEnabled = false
        }

        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        if let onSeek {
            commandCenter.changePlaybackPositionCommand.isEnabled = true
            commandCenter.changePlaybackPositionCommand.addTarget { event in
                guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                DispatchQueue.main.async { onSeek(positionEvent.positionTime) }
                return .success
            }
        } else {
            commandCenter.changePlaybackPositionCommand.isEnabled = false
        }
    }

    static func updateNowPlayingInfo(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        artworkImage: UIImage?,
        playbackRate: Double = 1.0,
        mediaType: MPMediaType = .music
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyMediaType: mediaType.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
