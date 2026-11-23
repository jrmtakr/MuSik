import AppIntents
import Foundation

struct PlaylistNameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run {
            MediaManager.shared.playlists.map(\.name)
        }
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Offline Playlist"
    static var description = IntentDescription("Loads and plays a saved offline playlist in Music Player.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist Name", optionsProvider: PlaylistNameOptionsProvider())
    var playlistName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await MediaManager.shared.playPlaylist(named: playlistName)
        switch outcome {
        case .playing(let resolvedName, let count):
            return .result(dialog: "Playing \(resolvedName) (\(count) \(count == 1 ? "item" : "items")).")
        case .empty(let resolvedName):
            return .result(dialog: "Playlist \"\(resolvedName)\" is empty. Add media in Music Player first.")
        case .notFound:
            return .result(dialog: "No playlist named \"\(playlistName)\" was found.")
        }
    }
}

struct MusicPlayerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play offline playlist in \(.applicationName)",
                "Start playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
    }
}
