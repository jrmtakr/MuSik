import CoreSpotlight
import Network
import Photos
import Speech
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SystemActionRouter.registerHomeQuickActions()
        PlaylistImportManager.shared.registerBackgroundTasks()
        TrendingArtistsService.shared.registerBackgroundRefresh()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == PlaylistImportManager.backgroundSessionIdentifier {
            PlaylistImportManager.shared.handleBackgroundSessionEvents(completionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["wrappedDeepLink"] != nil {
            Task { @MainActor in
                ListeningWrappedService.shared.pendingOpenWrappedSheet = true
            }
        }
        completionHandler()
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
    @Environment(\.scenePhase) private var scenePhase

    @State private var mediaManager = MediaManager.shared
    @State private var wifiServer = WiFiTransferServer()
    @State private var sleepTimer = SleepTimerManager.shared
    @State private var settings = AppSettings()
    @State private var browserStore = BrowserStore()
    @State private var playlistImportManager = PlaylistImportManager.shared
    @State private var downloader = WebMediaDownloader.shared
    @State private var groupService = GroupPlaylistService.shared
    @State private var partyService = PartyQueueService.shared
    @State private var timeMachine = PlaylistTimeMachineService.shared
    @State private var wrappedService = ListeningWrappedService.shared
    @State private var trendingService = TrendingArtistsService.shared
    @State private var actionRouter = SystemActionRouter.shared
    @State private var syncedLyricsService = SyncedLyricsService.shared
    @State private var tiktokMediaService = TikTokMediaService.shared
    @State private var wholeSongAIService = WholeSongAIService.shared

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
                .environment(playlistImportManager)
                .environment(groupService)
                .environment(partyService)
                .environment(timeMachine)
                .environment(wrappedService)
                .environment(trendingService)
                .environment(actionRouter)
                .environment(syncedLyricsService)
                .environment(tiktokMediaService)
                .environment(wholeSongAIService)
                .task {
                    LocalMediaCacheProxy.shared.start()
                    SystemActionRouter.registerHomeQuickActions()
                    await requestAllStartupPermissionsIfNeeded()
                    await trendingService.refreshIfDue()
                    Task.detached(priority: .utility) {
                        await WhisperTranscriptionEngine.shared.warmUpInBackground()
                    }
                    wifiServer.onFileReceived = { tempURL, fileName, folderPath in
                        mediaManager.importTemporaryFile(from: tempURL, preferredFileName: fileName, inFolder: folderPath)
                    }
                    wifiServer.onLibraryChanged = {
                        mediaManager.loadLocalFiles()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await trendingService.refreshIfDue()
                            trendingService.scheduleDailyMidnightRefresh()
                        }
                    } else if phase == .background || phase == .inactive {
                        wrappedService.flushDiskSave()
                        timeMachine.flushDiskSave()
                        trendingService.scheduleDailyMidnightRefresh()
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
                        SongIdentificationService.shared.prioritize(item)
                        Task { @MainActor in
                            while mediaManager.isAIAnalysisPending(for: item) {
                                try? await Task.sleep(for: .milliseconds(350))
                            }
                            let refreshed = mediaManager.items.first(where: { $0.relativePath == item.relativePath }) ?? item
                            if mediaManager.play(refreshed) {
                                showPlayerSheet = true
                            }
                        }
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

    @MainActor
    private func requestAllStartupPermissionsIfNeeded() async {
        // 1. Notifications (Wrapped Dec 1 reminder & background import completion)
        await wrappedService.requestPermissionAndScheduleDecemberDrop()

        // 2. Speech Recognition (on-device audio lyrics & track identification)
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    cont.resume()
                }
            }
        }

        // 3. Photo Library (video import & custom cover art selection)
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if photoStatus == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }

        // 4. Local Network (Wi-Fi transfer & nearby MuseJRM Jam discovery) on first launch
        let localNetKey = "musicplayer.didRequestLocalNetworkStartup"
        if !UserDefaults.standard.bool(forKey: localNetKey) {
            UserDefaults.standard.set(true, forKey: localNetKey)
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: "_musejrm-jam._tcp", domain: nil), using: params)
            browser.start(queue: .global(qos: .utility))
            try? await Task.sleep(for: .milliseconds(1200))
            browser.cancel()
        }
    }
}
