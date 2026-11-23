import SwiftUI

struct ContentView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    var body: some View {
        TabView {
            LibraryView(showPlayerSheet: $showPlayerSheet, quickLookTarget: $quickLookTarget)
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            PlaylistsView(showPlayerSheet: $showPlayerSheet, quickLookTarget: $quickLookTarget)
                .tabItem {
                    Label("Playlists", systemImage: "rectangle.stack.badge.play")
                }

            BrowserTabView(showPlayerSheet: $showPlayerSheet)
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }

            SettingsView(showPlayerSheet: $showPlayerSheet)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
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
