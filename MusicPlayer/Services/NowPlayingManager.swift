import MediaPlayer
import UIKit

final class NowPlayingManager {
    static func setupRemoteCommands(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPrev: @escaping () -> Void,
        onTogglePlayPause: (() -> Void)? = nil,
        onSeek: ((TimeInterval) -> Void)? = nil,
        onLikeToggle: (() -> Void)? = nil,
        onChangeRate: ((Float) -> Void)? = nil
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

        commandCenter.likeCommand.removeTarget(nil)
        if let onLikeToggle {
            commandCenter.likeCommand.isEnabled = true
            commandCenter.likeCommand.localizedTitle = "Favorite"
            commandCenter.likeCommand.addTarget { _ in
                DispatchQueue.main.async { onLikeToggle() }
                return .success
            }
        } else {
            commandCenter.likeCommand.isEnabled = false
        }

        commandCenter.changePlaybackRateCommand.removeTarget(nil)
        if let onChangeRate {
            commandCenter.changePlaybackRateCommand.isEnabled = true
            commandCenter.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
            commandCenter.changePlaybackRateCommand.addTarget { event in
                guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
                    return .commandFailed
                }
                DispatchQueue.main.async { onChangeRate(rateEvent.playbackRate) }
                return .success
            }
        } else {
            commandCenter.changePlaybackRateCommand.isEnabled = false
        }
    }

    static func updateNowPlayingInfo(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        artworkImage: UIImage?,
        playbackRate: Double = 1.0,
        mediaType: MPMediaType = .music,
        isFavorite: Bool = false,
        queueIndex: Int? = nil,
        queueCount: Int? = nil
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyMediaType: mediaType.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let queueIndex, let queueCount, queueCount > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }

        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().likeCommand.isActive = isFavorite
    }

    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
    }
}
