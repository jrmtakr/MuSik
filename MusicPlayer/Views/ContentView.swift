import SwiftUI
import UIKit

enum AppTab: Hashable {
    case discovery
    case playlists
    case browser
    case files
    case setting
}

struct ContentView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
    @Environment(SystemActionRouter.self) private var actionRouter
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var selectedTab: AppTab = .discovery
    @State private var quickPlaylistName = ""
    @State private var shortcutImportURLItem: ShortcutImportItem?

    var body: some View {
        Group {
            TabView(selection: $selectedTab) {
                DiscoveryView(showPlayerSheet: $showPlayerSheet, selectedTab: $selectedTab)
                    .tabItem {
                        Label("Discovery", systemImage: "safari")
                    }
                    .tag(AppTab.discovery)

                PlaylistsView(showPlayerSheet: $showPlayerSheet, quickLookTarget: $quickLookTarget)
                    .tabItem {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                    .tag(AppTab.playlists)

                BrowserTabView(showPlayerSheet: $showPlayerSheet)
                    .tabItem {
                        Label("Browser", systemImage: "globe")
                    }
                    .tag(AppTab.browser)

                LibraryView(showPlayerSheet: $showPlayerSheet, quickLookTarget: $quickLookTarget)
                    .tabItem {
                        Label("Files", systemImage: "folder")
                    }
                    .tag(AppTab.files)

                SettingsView(showPlayerSheet: $showPlayerSheet)
                    .tabItem {
                        Label("Setting", systemImage: "gearshape")
                    }
                    .tag(AppTab.setting)
            }
            .preferredColorScheme(settings.appearanceMode.colorScheme)
            .applyCustomTextStyle()
            .onAppear {
                updateNavigationBarAppearance()
                if groupService.pendingOpenGroupID != nil || partyService.pendingOpenPartyID != nil {
                    selectedTab = .playlists
                }
                consumePendingSystemActions()
            }
            .onChange(of: groupService.pendingOpenGroupID) { _, newID in
                if newID != nil {
                    selectedTab = .playlists
                }
            }
            .onChange(of: partyService.pendingOpenPartyID) { _, newID in
                if newID != nil {
                    selectedTab = .playlists
                }
            }
            .onChange(of: actionRouter.requestedTab) { _, _ in
                consumePendingSystemActions()
            }
            .onChange(of: actionRouter.pendingQuickActionType) { _, _ in
                consumePendingSystemActions()
            }
            .onChange(of: actionRouter.pendingDownloadURLString) { _, _ in
                consumePendingSystemActions()
            }
            .onChange(of: actionRouter.pendingPlaylistImportURL) { _, _ in
                consumePendingSystemActions()
            }
            .onChange(of: actionRouter.pendingBrowserURLString) { _, _ in
                consumePendingSystemActions()
            }
            .onChange(of: actionRouter.shouldPresentPlayerSheet) { _, shouldShow in
                if shouldShow {
                    actionRouter.shouldPresentPlayerSheet = false
                    showPlayerSheet = true
                }
            }
            .onChange(of: settings.useCustomTextColor) { _, _ in
                updateNavigationBarAppearance()
            }
            .onChange(of: settings.customTextHex) { _, _ in
                updateNavigationBarAppearance()
            }
            .sheet(isPresented: $showPlayerSheet) {
                NowPlayingView()
            }
            .sheet(item: $quickLookTarget) { target in
                QuickLookSheetView(target: target)
            }
            .sheet(item: $shortcutImportURLItem) { item in
                ImportPlaylistSheetView(initialURL: item.urlString)
            }
            .alert(
                "Notice",
                isPresented: Binding(
                    get: { mediaManager.errorMessage != nil },
                    set: { if !$0 { mediaManager.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    mediaManager.errorMessage = nil
                }
            } message: {
                Text(mediaManager.errorMessage ?? "")
            }
            .task(id: mediaManager.statusMessage) {
                guard mediaManager.statusMessage != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled {
                    mediaManager.statusMessage = nil
                }
            }
        }
        .alert(
            "New Playlist",
            isPresented: Binding(
                get: { mediaManager.newPlaylistTargetItem != nil },
                set: {
                    if !$0 {
                        mediaManager.newPlaylistTargetItem = nil
                        quickPlaylistName = ""
                    }
                }
            )
        ) {
            TextField("Playlist name", text: $quickPlaylistName)
            Button("Cancel", role: .cancel) {
                mediaManager.newPlaylistTargetItem = nil
                quickPlaylistName = ""
            }
            Button("Create & Add") {
                if let target = mediaManager.newPlaylistTargetItem {
                    mediaManager.createPlaylist(name: quickPlaylistName, initialPaths: [target.relativePath])
                }
                mediaManager.newPlaylistTargetItem = nil
                quickPlaylistName = ""
            }
        } message: {
            Text("Enter a name for your new offline playlist.")
        }
    }

    private func updateNavigationBarAppearance() {
        if settings.useCustomTextColor {
            let uiColor = UIColor(settings.customTextColor)
            UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: uiColor]
            UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: uiColor]
        } else {
            UINavigationBar.appearance().titleTextAttributes = nil
            UINavigationBar.appearance().largeTitleTextAttributes = nil
        }
    }

    private func consumePendingSystemActions() {
        if let quickType = actionRouter.pendingQuickActionType {
            actionRouter.pendingQuickActionType = nil
            actionRouter.executeQuickAction(
                quickType,
                downloader: downloader,
                maxDurationMinutes: settings.maxCacheDurationMinutes
            )
        }
        if let tab = actionRouter.requestedTab {
            actionRouter.requestedTab = nil
            selectedTab = tab
        }
        if actionRouter.shouldPresentPlayerSheet {
            actionRouter.shouldPresentPlayerSheet = false
            showPlayerSheet = true
        }
        if let browserURL = actionRouter.pendingBrowserURLString {
            actionRouter.pendingBrowserURLString = nil
            browserStore.openInActiveTab(urlString: browserURL, title: nil)
            selectedTab = .browser
        }
        if let playlistURL = actionRouter.pendingPlaylistImportURL {
            actionRouter.pendingPlaylistImportURL = nil
            shortcutImportURLItem = ShortcutImportItem(urlString: playlistURL)
        }
        if let downloadURL = actionRouter.pendingDownloadURLString {
            actionRouter.pendingDownloadURLString = nil
            Task {
                await downloader.resolveAndDownload(
                    inputURLString: downloadURL,
                    maxDurationMinutes: settings.maxCacheDurationMinutes
                )
            }
        }
    }
}

private struct ShortcutImportItem: Identifiable {
    let id = UUID()
    let urlString: String
}
