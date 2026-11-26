import AppIntents
import Foundation

struct PlaylistNameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run {
            MediaManager.shared.playlists.map(\.name)
        }
    }
}

struct SongTitleOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run {
            var seen = Set<String>()
            return MediaManager.shared.items
                .map(\.displayTitle)
                .filter { seen.insert($0.lowercased()).inserted }
        }
    }
}

enum SkipTrackDirection: String, AppEnum {
    case next
    case previous

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Track Direction"
    static var caseDisplayRepresentations: [SkipTrackDirection: DisplayRepresentation] = [
        .next: "Next Track",
        .previous: "Previous Track"
    ]
}

enum EqualizerPresetAppOption: String, AppEnum {
    case flat
    case bassBoost
    case vocal
    case treble
    case electronic
    case rock
    case acoustic

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Equalizer Preset"
    static var caseDisplayRepresentations: [EqualizerPresetAppOption: DisplayRepresentation] = [
        .flat: "Flat",
        .bassBoost: "Bass Boost",
        .vocal: "Vocal",
        .treble: "Treble",
        .electronic: "Electronic",
        .rock: "Rock",
        .acoustic: "Acoustic"
    ]

    var preset: EqualizerPreset {
        switch self {
        case .flat: return .flat
        case .bassBoost: return .bassBoost
        case .vocal: return .vocal
        case .treble: return .treble
        case .electronic: return .electronic
        case .rock: return .rock
        case .acoustic: return .acoustic
        }
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Offline Playlist"
    static var description = IntentDescription("Loads and plays a saved offline playlist in MuseJRM.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist Name", optionsProvider: PlaylistNameOptionsProvider())
    var playlistName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await MediaManager.shared.playPlaylist(named: playlistName)
        switch outcome {
        case .playing(let resolvedName, let count):
            return .result(dialog: "Playing \(resolvedName) (\(count) \(count == 1 ? "item" : "items")).")
        case .empty(let resolvedName):
            return .result(dialog: "Playlist \"\(resolvedName)\" is empty. Add media in MuseJRM first.")
        case .notFound:
            return .result(dialog: "No playlist named \"\(playlistName)\" was found.")
        }
    }
}

struct PlaySongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Offline Song"
    static var description = IntentDescription("Plays a matching offline song or video in MuseJRM.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Song or Video Name", optionsProvider: SongTitleOptionsProvider())
    var songTitle: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playedTitle: String? = await MainActor.run {
            MediaManager.shared.loadLocalFiles()
            if MediaManager.shared.playSong(named: songTitle) {
                return MediaManager.shared.currentItem?.displayTitle ?? songTitle
            }
            return nil
        }

        if let playedTitle {
            return .result(dialog: "Playing \(playedTitle).")
        }
        return .result(dialog: "Could not find \"\(songTitle)\" in your offline library.")
    }
}

struct ShuffleOfflineMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Offline Music"
    static var description = IntentDescription("Shuffles and plays your offline music library.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let startedTitle: String? = await MainActor.run {
            MediaManager.shared.shuffleAllOfflineMusic()
            return MediaManager.shared.currentItem?.displayTitle
        }
        if let startedTitle {
            return .result(dialog: "Shuffling offline music, starting with \(startedTitle).")
        }
        return .result(dialog: "Your offline library has no playable audio tracks yet.")
    }
}

struct ResumeLastPlayedIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Last Played"
    static var description = IntentDescription("Resumes the current track or your most recently played song.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playingTitle: String? = await MainActor.run {
            MediaManager.shared.resumeOrPlayMostRecent()
            return MediaManager.shared.currentItem?.displayTitle
        }
        if let playingTitle {
            return .result(dialog: "Playing \(playingTitle).")
        }
        return .result(dialog: "No recently played track found.")
    }
}

struct LikeCurrentSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Favorite Current Song"
    static var description = IntentDescription("Toggles favorite on the currently playing track in MuseJRM.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message: String = await MainActor.run {
            guard let item = MediaManager.shared.currentItem,
                  !item.relativePath.hasPrefix("__remote__/") else {
                return "No offline track is currently playing."
            }
            MediaManager.shared.toggleFavorite(item)
            let liked = MediaManager.shared.isFavorite(item)
            return liked ? "Added \(item.displayTitle) to Favorites." : "Removed \(item.displayTitle) from Favorites."
        }
        return .result(dialog: "\(message)")
    }
}

struct SkipTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Track"
    static var description = IntentDescription("Skips to the next or previous track in MuseJRM.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Direction", default: .next)
    var direction: SkipTrackDirection

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title: String? = await MainActor.run {
            switch direction {
            case .next:
                MediaManager.shared.playNext()
            case .previous:
                MediaManager.shared.playPrevious()
            }
            return MediaManager.shared.currentItem?.displayTitle
        }
        if let title {
            return .result(dialog: "Now playing \(title).")
        }
        return .result(dialog: "Nothing is currently queued.")
    }
}

struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Pauses MuseJRM automatically after the chosen number of minutes (0 turns it off).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes", default: 30)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clampedMinutes = min(max(minutes, 0), 240)
        let dialogText: String = await MainActor.run {
            if clampedMinutes <= 0 {
                SleepTimerManager.shared.cancelTimer()
                return "Turned off sleep timer."
            }
            SleepTimerManager.shared.startTimer(minutes: clampedMinutes) {
                MediaManager.shared.pause()
                MediaManager.shared.statusMessage = "Sleep timer paused playback"
            }
            return "Sleep timer set for \(clampedMinutes) \(clampedMinutes == 1 ? "minute" : "minutes")."
        }
        return .result(dialog: "\(dialogText)")
    }
}

struct SetEqualizerPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Equalizer Preset"
    static var description = IntentDescription("Applies an audio equalizer preset in MuseJRM.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Preset", default: .bassBoost)
    var presetOption: EqualizerPresetAppOption

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            MediaManager.shared.equalizerPlayer.setEnabled(true)
            MediaManager.shared.equalizerPlayer.applyPreset(presetOption.preset)
        }
        return .result(dialog: "Applied \(presetOption.preset.rawValue) equalizer preset.")
    }
}

struct SaveMediaLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Save URL in MuseJRM"
    static var description = IntentDescription("Downloads a direct video/audio/YouTube URL or opens the Playlist Importer for Spotify/Apple Music links.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Media or Playlist URL")
    var urlString: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Provide a valid URL.")
        }
        await MainActor.run {
            if PlaylistURLImporter.parsePlaylistURL(trimmed) != nil {
                SystemActionRouter.shared.pendingPlaylistImportURL = trimmed
                SystemActionRouter.shared.requestedTab = .playlists
            } else {
                SystemActionRouter.shared.pendingDownloadURLString = trimmed
                SystemActionRouter.shared.requestedTab = .files
            }
        }
        return .result(dialog: "Opening link in MuseJRM.")
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

        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play song in \(.applicationName)",
                "Play track in \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: ShuffleOfflineMusicIntent(),
            phrases: [
                "Shuffle my music in \(.applicationName)",
                "Shuffle offline songs in \(.applicationName)"
            ],
            shortTitle: "Shuffle Music",
            systemImageName: "shuffle"
        )

        AppShortcut(
            intent: ResumeLastPlayedIntent(),
            phrases: [
                "Resume music in \(.applicationName)",
                "Continue playing in \(.applicationName)"
            ],
            shortTitle: "Resume Music",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: LikeCurrentSongIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Favorite current track in \(.applicationName)"
            ],
            shortTitle: "Favorite Song",
            systemImageName: "heart.fill"
        )

        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set sleep timer in \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
    }
}
