import SwiftUI

enum AppTab: Hashable {
    case discovery
    case playlists
    case files
    case setting
}

struct ContentView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var selectedTab: AppTab = .discovery

    var body: some View {
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
        .sheet(isPresented: $showPlayerSheet) {
            NowPlayingView()
        }
        .sheet(item: $quickLookTarget) { target in
            QuickLookSheetView(target: target)
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
}
