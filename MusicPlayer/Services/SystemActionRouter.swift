import Foundation
import Observation
import UIKit

enum AppHaptics {
    static func light() {
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    static func selection() {
        DispatchQueue.main.async {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    static func success() {
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

enum HomeQuickActionType: String {
    case resume = "com.personal.musicplayer.quick.resume"
    case shuffle = "com.personal.musicplayer.quick.shuffle"
    case clipboardDownload = "com.personal.musicplayer.quick.clipboard"
    case openBrowser = "com.personal.musicplayer.quick.browser"
}

@MainActor
@Observable
final class SystemActionRouter {
    static let shared = SystemActionRouter()

    var requestedTab: AppTab?
    var pendingDownloadURLString: String?
    var pendingPlaylistImportURL: String?
    var pendingBrowserURLString: String?
    var shouldPresentPlayerSheet = false
    var pendingQuickActionType: HomeQuickActionType?

    private init() {}

    static func registerHomeQuickActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: HomeQuickActionType.resume.rawValue,
                localizedTitle: "Resume Last Played",
                localizedSubtitle: "Continue listening",
                icon: UIApplicationShortcutIcon(systemImageName: "play.circle.fill")
            ),
            UIApplicationShortcutItem(
                type: HomeQuickActionType.shuffle.rawValue,
                localizedTitle: "Shuffle Offline Songs",
                localizedSubtitle: "Mix all offline music",
                icon: UIApplicationShortcutIcon(systemImageName: "shuffle")
            ),
            UIApplicationShortcutItem(
                type: HomeQuickActionType.clipboardDownload.rawValue,
                localizedTitle: "Download Clipboard Link",
                localizedSubtitle: "Save URL or playlist offline",
                icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.circle.fill")
            ),
            UIApplicationShortcutItem(
                type: HomeQuickActionType.openBrowser.rawValue,
                localizedTitle: "Open Browser",
                localizedSubtitle: "Ad-free web & YouTube",
                icon: UIApplicationShortcutIcon(systemImageName: "globe")
            )
        ]
    }

    func executeQuickAction(
        _ type: HomeQuickActionType,
        downloader: WebMediaDownloader,
        maxDurationMinutes: Int
    ) {
        AppHaptics.light()
        switch type {
        case .resume:
            MediaManager.shared.resumeOrPlayMostRecent()
            shouldPresentPlayerSheet = MediaManager.shared.currentItem != nil
        case .shuffle:
            MediaManager.shared.shuffleAllOfflineMusic()
            shouldPresentPlayerSheet = MediaManager.shared.currentItem != nil
        case .clipboardDownload:
            guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                MediaManager.shared.errorMessage = "No URL found on your clipboard."
                requestedTab = .discovery
                return
            }
            if PlaylistURLImporter.parsePlaylistURL(raw) != nil {
                pendingPlaylistImportURL = raw
                requestedTab = .playlists
            } else {
                requestedTab = .files
                Task {
                    await downloader.resolveAndDownload(inputURLString: raw, maxDurationMinutes: maxDurationMinutes)
                }
            }
        case .openBrowser:
            requestedTab = .browser
        }
    }

    func handleDeepLink(
        _ url: URL,
        downloader: WebMediaDownloader,
        groupService: GroupPlaylistService,
        maxDurationMinutes: Int
    ) -> Bool {
        guard url.scheme?.lowercased() == "musicplayer" else { return false }
        let host = url.host?.lowercased() ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryValue: (String) -> String? = { key in
            comps?.queryItems?.first(where: { $0.name.lowercased() == key })?.value
        }

        switch host {
        case "group":
            Task { @MainActor in
                await groupService.joinGroupPlaylist(input: url.absoluteString)
            }
            return true

        case "party":
            Task { @MainActor in
                await PartyQueueService.shared.joinParty(input: url.absoluteString)
            }
            return true

        case "timemachine":
            PlaylistTimeMachineService.shared.pendingOpenGlobalSheet = true
            requestedTab = .playlists
            return true

        case "shuffle":
            MediaManager.shared.shuffleAllOfflineMusic()
            shouldPresentPlayerSheet = MediaManager.shared.currentItem != nil
            return true

        case "resume":
            MediaManager.shared.resumeOrPlayMostRecent()
            shouldPresentPlayerSheet = MediaManager.shared.currentItem != nil
            return true

        case "play":
            if let songQuery = queryValue("song") ?? queryValue("q"), !songQuery.isEmpty {
                let played = MediaManager.shared.playSong(named: songQuery)
                if played {
                    shouldPresentPlayerSheet = true
                } else {
                    MediaManager.shared.errorMessage = "No offline song matching \"\(songQuery)\"."
                }
            } else {
                MediaManager.shared.resumeOrPlayMostRecent()
                shouldPresentPlayerSheet = MediaManager.shared.currentItem != nil
            }
            return true

        case "playlist":
            if let name = queryValue("name"), !name.isEmpty {
                _ = MediaManager.shared.playPlaylist(named: name)
                requestedTab = .playlists
            }
            return true

        case "download":
            if let target = queryValue("url"), !target.isEmpty {
                if PlaylistURLImporter.parsePlaylistURL(target) != nil {
                    pendingPlaylistImportURL = target
                    requestedTab = .playlists
                } else {
                    requestedTab = .files
                    Task {
                        await downloader.resolveAndDownload(inputURLString: target, maxDurationMinutes: maxDurationMinutes)
                    }
                }
            } else {
                executeQuickAction(.clipboardDownload, downloader: downloader, maxDurationMinutes: maxDurationMinutes)
            }
            return true

        case "browser":
            if let target = queryValue("url"), !target.isEmpty {
                pendingBrowserURLString = target
            }
            requestedTab = .browser
            return true

        case "files", "library":
            requestedTab = .files
            return true

        case "settings":
            requestedTab = .setting
            return true

        default:
            return false
        }
    }
}
