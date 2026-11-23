import CoreSpotlight
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SystemActionRouter.registerHomeQuickActions()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem,
           let type = HomeQuickActionType(rawValue: shortcutItem.type) {
            Task { @MainActor in
                SystemActionRouter.shared.pendingQuickActionType = type
            }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if let type = HomeQuickActionType(rawValue: shortcutItem.type) {
            Task { @MainActor in
                SystemActionRouter.shared.pendingQuickActionType = type
            }
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }
}

@main
struct MusicPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var mediaManager = MediaManager.shared
    @State private var wifiServer = WiFiTransferServer()
    @State private var sleepTimer = SleepTimerManager.shared
    @State private var settings = AppSettings()
    @State private var browserStore = BrowserStore()
    @State private var downloader = WebMediaDownloader()
    @State private var groupService = GroupPlaylistService.shared
    @State private var partyService = PartyQueueService.shared
    @State private var actionRouter = SystemActionRouter.shared

    @State private var showPlayerSheet = false
    @State private var quickLookTarget: QuickLookTarget?

    var body: some Scene {
        WindowGroup {
            ContentView(showPlayerSheet: $showPlayerSheet, quickLookTarget: $quickLookTarget)
                .environment(mediaManager)
                .environment(wifiServer)
                .environment(sleepTimer)
                .environment(settings)
                .environment(browserStore)
                .environment(downloader)
                .environment(groupService)
                .environment(partyService)
                .environment(actionRouter)
                .task {
                    LocalMediaCacheProxy.shared.start()
                    SystemActionRouter.registerHomeQuickActions()
                    wifiServer.onFileReceived = { tempURL, fileName, folderPath in
                        mediaManager.importTemporaryFile(from: tempURL, preferredFileName: fileName, inFolder: folderPath)
                    }
                    wifiServer.onLibraryChanged = {
                        mediaManager.loadLocalFiles()
                    }
                }
                .onOpenURL { url in
                    if actionRouter.handleDeepLink(
                        url,
                        downloader: downloader,
                        groupService: groupService,
                        maxDurationMinutes: settings.maxCacheDurationMinutes
                    ) {
                        return
                    }
                    switch mediaManager.importAnyFile(from: url) {
                    case .media(let item):
                        mediaManager.play(item)
                        showPlayerSheet = true
                    case .document(let file):
                        quickLookTarget = QuickLookTarget(title: file.name, fileURL: file.fileURL)
                    case .folder:
                        break
                    case nil:
                        break
                    }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    var nextTab: AppTab = .playlists
                    SpotlightIndexer.handleSpotlightActivity(
                        activity,
                        showPlayerSheet: &showPlayerSheet,
                        quickLookTarget: &quickLookTarget,
                        requestedTab: &nextTab
                    )
                    actionRouter.requestedTab = nextTab
                }
        }
    }
}
