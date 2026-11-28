import PhotosUI
import SwiftUI

enum PlaylistSortOrder: String, CaseIterable, Identifiable {
    case date = "Sort by Date"
    case name = "Sort by Name"
    case count = "Sort by Songs"

    var id: String { rawValue }
}

private enum SmartPlaylistKind: String, Identifiable {
    case offline = "Offline Songs"
    case liked = "Liked Songs"
    case lastPlayed = "Last Played"
    case offlineVideos = "Offline Videos"
    case allOffline = "All Offline Media"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .liked: return "heart.fill"
        case .offline: return "music.note"
        case .lastPlayed: return "clock.fill"
        case .offlineVideos: return "film.fill"
        case .allOffline: return "arrow.down.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .liked: return .pink
        case .offline: return .accentColor
        case .lastPlayed: return .blue
        case .offlineVideos: return .purple
        case .allOffline: return .green
        }
    }
}

struct PlaylistsView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
    @Environment(PlaylistTimeMachineService.self) private var timeMachine
    @Environment(PlaylistImportManager.self) private var playlistImportManager
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var searchText = ""
    @State private var sortOrder: PlaylistSortOrder = .date
    @State private var showCreateAlert = false
    @State private var showImportURLSheet = false
    @State private var importIssuesJobID: IdentifiedUUID?
    @State private var showCreateGroupSheet = false
    @State private var showJoinGroupSheet = false
    @State private var selectedGroupID: UUID?
    @State private var showCreatePartySheet = false
    @State private var showJoinPartySheet = false
    @State private var selectedPartyID: UUID?
    @State private var showTimeMachineSheet = false
    @State private var timeMachineTargetPlaylistID: UUID?
    @State private var newPlaylistName = ""
    @State private var createdPlaylistID: UUID?
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var searchItemToRename: MediaItem?
    @State private var searchRenameText = ""
    @State private var searchEditingInfoItem: MediaItem?

    @State private var coverTargetPlaylist: Playlist?
    @State private var showCoverPicker = false
    @State private var selectedCoverPhoto: PhotosPickerItem?

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sortedPlaylists: [Playlist] {
        let base = mediaManager.playlists.filter {
            trimmedSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmedSearch)
        }
        switch sortOrder {
        case .date:
            return base.sorted { $0.dateCreated > $1.dateCreated }
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .count:
            return base.sorted { mediaManager.items(in: $0).count > mediaManager.items(in: $1).count }
        }
    }

    private var matchingTracks: [MediaItem] {
        guard !trimmedSearch.isEmpty else { return [] }
        return mediaManager.items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmedSearch) ||
                ($0.artist?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedSearch.isEmpty && !playlistImportManager.jobs.isEmpty {
                    Section("Background Playlist Imports") {
                        ForEach(playlistImportManager.jobs.prefix(4)) { job in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(job.playlistName)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text(importJobSubtitle(job))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !job.isFinished {
                                        Button(job.isPaused ? "Resume" : "Pause") {
                                            if job.isPaused {
                                                playlistImportManager.resumeJob(id: job.id)
                                            } else {
                                                playlistImportManager.pauseJob(id: job.id)
                                            }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button(role: .destructive) {
                                            playlistImportManager.cancelJob(id: job.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        if job.canRetry {
                                            Button(job.failedCount > 0 ? "Retry (\(job.failedCount))" : "Restart") {
                                                playlistImportManager.retryFailedTracks(inJobID: job.id)
                                            }
                                            .font(.caption.weight(.semibold))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        Button("Clear") {
                                            playlistImportManager.clearFinishedJob(id: job.id)
                                        }
                                        .font(.caption)
                                        .buttonStyle(.borderless)
                                    }
                                }

                                ProgressView(value: job.progressFraction)
                                    .progressViewStyle(.linear)
                                    .tint(job.isFinished && job.failedCount == 0 ? .green : .accentColor)

                                HStack {
                                    Text("\(job.processedCount) / \(job.totalCount)")
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                    Spacer()
                                    Text("\(job.completedCount) downloaded • \(job.skippedCount) already cached\(job.failedCount > 0 ? " • \(job.failedCount) failed" : "")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                ImportJobActiveTracksView(job: job)

                                ImportJobIssuesBar(job: job) {
                                    importIssuesJobID = IdentifiedUUID(id: job.id)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                if trimmedSearch.isEmpty && settings.quickAccessLastPlaylist, let last = mediaManager.lastPlaylist {
                    Section("Quick Access") {
                        let count = mediaManager.items(in: last).count
                        HStack(spacing: 12) {
                            playlistArtwork(for: last, size: 46)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last Playlist: \(last.name)")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(count) \(count == 1 ? "track" : "tracks")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                UIApplication.shared.dismissKeyboard()
                                mediaManager.playPlaylist(last)
                                if mediaManager.currentItem?.isVideo == true {
                                    showPlayerSheet = true
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(count == 0)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if trimmedSearch.isEmpty {
                    Section("Library Collections") {
                        smartPlaylistRow(.offline, count: mediaManager.audioItems.count)
                        smartPlaylistRow(.liked, count: mediaManager.favoriteItems.count)
                        smartPlaylistRow(.lastPlayed, count: mediaManager.recentItems.count)
                        smartPlaylistRow(.offlineVideos, count: mediaManager.videoItems.count)
                        smartPlaylistRow(.allOffline, count: mediaManager.items.count)
                    }

                    Section("Group Playlists (Live)") {
                        HStack(spacing: 10) {
                            Button {
                                showCreateGroupSheet = true
                            } label: {
                                Label("New Group", systemImage: "person.2.wave.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                showJoinGroupSheet = true
                            } label: {
                                Label("Join Code / Link", systemImage: "link.badge.plus")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)

                        if groupService.groups.isEmpty {
                            Text("Create a Group Playlist or enter a friend's code/link to add & listen to songs live together.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(groupService.groups) { group in
                                NavigationLink {
                                    GroupPlaylistDetailView(groupID: group.id, showPlayerSheet: $showPlayerSheet)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.green.opacity(0.16))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "person.2.wave.2.fill")
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(.green)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(group.name)
                                                .font(.body.weight(.semibold))
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text("\(group.tracks.count) \(group.tracks.count == 1 ? "song" : "songs")")
                                                Text("•")
                                                Text(group.formattedCode)
                                                    .font(.caption2.monospaced().weight(.bold))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }

                    Section("Spotify-Style Jam (Live Sync)") {
                        HStack(spacing: 10) {
                            Button {
                                showCreatePartySheet = true
                            } label: {
                                Label("Start a Jam", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                            Button {
                                showJoinPartySheet = true
                            } label: {
                                Label("Join a Jam", systemImage: "person.badge.plus")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)

                        if partyService.parties.isEmpty {
                            Text("Listen and queue songs together with friends in real time. Share a QR code, link, or join nearby over Wi-Fi.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(partyService.parties) { party in
                                NavigationLink {
                                    PartyQueueDetailView(partyID: party.id, showPlayerSheet: $showPlayerSheet)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.orange.opacity(0.16))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "radio.fill")
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(.orange)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(party.name)
                                                .font(.body.weight(.semibold))
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text("\(party.upNext.count) in queue")
                                                Text("•")
                                                Text(party.formattedCode)
                                                    .font(.caption2.monospaced().weight(.bold))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }

                Section("My Playlists") {
                    if trimmedSearch.isEmpty {
                        Button {
                            newPlaylistName = ""
                            showCreateAlert = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.14))
                                        .frame(width: 50, height: 50)
                                    Image(systemName: "plus")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text("New Playlist")
                                    .font(.body.weight(.semibold))
                            }
                        }

                        Button {
                            showImportURLSheet = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.purple.opacity(0.15))
                                        .frame(width: 50, height: 50)
                                    Image(systemName: "link.badge.plus")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.purple)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Import Playlist URL")
                                        .font(.body.weight(.semibold))
                                    Text("Spotify, Apple Music, YouTube & YT Music")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if sortedPlaylists.isEmpty && !trimmedSearch.isEmpty {
                        Text("No playlists matching \"\(searchText)\"")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedPlaylists) { playlist in
                            customPlaylistRow(playlist)
                        }
                        .onDelete { offsets in
                            let victims = offsets.compactMap { sortedPlaylists.indices.contains($0) ? sortedPlaylists[$0] : nil }
                            for playlist in victims {
                                mediaManager.deletePlaylist(playlist)
                            }
                        }
                    }
                }

                if !matchingTracks.isEmpty {
                    Section("Songs in Library") {
                        ForEach(matchingTracks) { item in
                            MediaRowView(
                                item: item,
                                onPlay: {
                                    UIApplication.shared.dismissKeyboard()
                                    if mediaManager.play(item) && item.isVideo { showPlayerSheet = true }
                                },
                                onQuickLook: {
                                    quickLookTarget = QuickLookTarget(title: item.displayTitle, fileURL: item.fileURL)
                                },
                                onRename: {
                                    searchRenameText = item.name
                                    searchItemToRename = item
                                },
                                onEditInfo: {
                                    searchEditingInfoItem = item
                                }
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Playlists")
            .searchable(text: $searchText, prompt: "Search on Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(PlaylistSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        timeMachineTargetPlaylistID = nil
                        showTimeMachineSheet = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }

                    Menu {
                        Button {
                            newPlaylistName = ""
                            showCreateAlert = true
                        } label: {
                            Label("New Playlist", systemImage: "plus.rectangle.on.folder")
                        }

                        Button {
                            showImportURLSheet = true
                        } label: {
                            Label("Import Playlist URL (Spotify / Apple / YT)", systemImage: "link.badge.plus")
                        }

                        Button {
                            timeMachineTargetPlaylistID = nil
                            showTimeMachineSheet = true
                        } label: {
                            Label("Playlist Time-Machine / Snapshots", systemImage: "clock.arrow.circlepath")
                        }

                        Divider()

                        Button {
                            showCreateGroupSheet = true
                        } label: {
                            Label("New Group Playlist (Live)", systemImage: "person.2.wave.2.fill")
                        }

                        Button {
                            showJoinGroupSheet = true
                        } label: {
                            Label("Join Group with Code / Link", systemImage: "person.badge.plus")
                        }

                        Divider()

                        Button {
                            showCreatePartySheet = true
                        } label: {
                            Label("Start Party Queue / Blend (FIFO)", systemImage: "radio.fill")
                        }

                        Button {
                            showJoinPartySheet = true
                        } label: {
                            Label("Join Party with Code / Link", systemImage: "link.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .modifier(
                PlaylistsRoutingModifier(
                    showPlayerSheet: $showPlayerSheet,
                    quickLookTarget: $quickLookTarget,
                    createdPlaylistID: $createdPlaylistID,
                    selectedGroupID: $selectedGroupID,
                    selectedPartyID: $selectedPartyID,
                    showTimeMachineSheet: $showTimeMachineSheet,
                    timeMachineTargetPlaylistID: $timeMachineTargetPlaylistID,
                    showCoverPicker: $showCoverPicker,
                    coverTargetPlaylist: $coverTargetPlaylist,
                    selectedCoverPhoto: $selectedCoverPhoto
                )
            )
            .modifier(
                PlaylistsSheetsAndAlertsModifier(
                    showPlayerSheet: $showPlayerSheet,
                    searchEditingInfoItem: $searchEditingInfoItem,
                    showImportURLSheet: $showImportURLSheet,
                    showCreateGroupSheet: $showCreateGroupSheet,
                    showJoinGroupSheet: $showJoinGroupSheet,
                    showCreatePartySheet: $showCreatePartySheet,
                    showJoinPartySheet: $showJoinPartySheet,
                    showTimeMachineSheet: $showTimeMachineSheet,
                    timeMachineTargetPlaylistID: $timeMachineTargetPlaylistID,
                    createdPlaylistID: $createdPlaylistID,
                    selectedGroupID: $selectedGroupID,
                    selectedPartyID: $selectedPartyID,
                    showCreateAlert: $showCreateAlert,
                    newPlaylistName: $newPlaylistName,
                    playlistToRename: $playlistToRename,
                    renameText: $renameText,
                    searchItemToRename: $searchItemToRename,
                    searchRenameText: $searchRenameText
                )
            )
            .sheet(item: $importIssuesJobID) { wrapped in
                ImportIssuesView(jobID: wrapped.id)
            }
        }
    }

    private func importJobSubtitle(_ job: PlaylistImportJob) -> String {
        if job.isCancelled { return "Stopped • \(job.cancelledCount) not downloaded" }
        if job.isFinished { return "Completed • \(job.completedCount + job.skippedCount) saved" }
        if job.isPaused { return "Paused • \(job.remainingCount) remaining" }
        if job.isDiscoveringPages { return "Discovering pages (\(job.totalCount)+) & caching..." }
        return "Finding & caching via browser in background..."
    }

    private func smartPlaylistRow(_ kind: SmartPlaylistKind, count: Int) -> some View {
        NavigationLink {
            SmartPlaylistDetailView(
                kind: kind,
                showPlayerSheet: $showPlayerSheet,
                quickLookTarget: $quickLookTarget
            )
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(kind.tintColor.opacity(0.16))
                        .frame(width: 50, height: 50)
                    Image(systemName: kind.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(kind.tintColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.rawValue)
                        .font(.body.weight(.semibold))
                    Text("\(count) \(count == 1 ? "Track" : "Tracks")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func customPlaylistRow(_ playlist: Playlist) -> some View {
        let resolvedCount = mediaManager.items(in: playlist).count
        let isActive = mediaManager.activePlaylistID == playlist.id

        return NavigationLink {
            PlaylistDetailView(
                playlistID: playlist.id,
                showPlayerSheet: $showPlayerSheet,
                quickLookTarget: $quickLookTarget
            )
        } label: {
            HStack(spacing: 14) {
                playlistArtwork(for: playlist, size: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isActive ? Color.accentColor : .primary)
                        .lineLimit(1)

                    Text("\(resolvedCount) \(resolvedCount == 1 ? "Track" : "Tracks")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    mediaManager.playPlaylist(playlist)
                    if mediaManager.currentItem?.isVideo == true {
                        showPlayerSheet = true
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(resolvedCount == 0 ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(resolvedCount == 0)
            }
            .padding(.vertical, 3)
        }
        .contextMenu {
            Button {
                mediaManager.playPlaylist(playlist)
                if mediaManager.currentItem?.isVideo == true {
                    showPlayerSheet = true
                }
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .disabled(resolvedCount == 0)

            Button {
                coverTargetPlaylist = playlist
                showCoverPicker = true
            } label: {
                Label("Change Cover", systemImage: "photo")
            }

            if mediaManager.playlistCovers[playlist.id] != nil {
                Button {
                    mediaManager.updatePlaylistCover(for: playlist, image: nil, remove: true)
                } label: {
                    Label("Reset Cover", systemImage: "arrow.uturn.backward")
                }
            }

            Button {
                timeMachineTargetPlaylistID = playlist.id
                showTimeMachineSheet = true
            } label: {
                Label("Time-Machine / History", systemImage: "clock.arrow.circlepath")
            }

            Button {
                let created = timeMachine.createManualSnapshot(
                    for: playlist,
                    items: mediaManager.items,
                    metadataByPath: mediaManager.customMetadataByPath
                )
                mediaManager.statusMessage = "Saved snapshot \"\(created.label)\""
            } label: {
                Label("Save Snapshot Now", systemImage: "bookmark.fill")
            }

            Button {
                renameText = playlist.name
                playlistToRename = playlist
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                mediaManager.deletePlaylist(playlist)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func playlistArtwork(for playlist: Playlist, size: CGFloat) -> some View {
        let isActive = mediaManager.activePlaylistID == playlist.id
        if let cover = mediaManager.playlistCovers[playlist.id] {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.accentColor.opacity(0.15))
                    .frame(width: size, height: size)
                Image(systemName: isActive && mediaManager.isPlaying ? "waveform" : "music.note.list")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isActive ? .white : Color.accentColor)
            }
        }
    }
}

private struct SmartPlaylistDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    let kind: SmartPlaylistKind
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var itemToRename: MediaItem?
    @State private var renameText = ""
    @State private var editingInfoItem: MediaItem?

    private var tracks: [MediaItem] {
        switch kind {
        case .liked: return mediaManager.favoriteItems
        case .offline: return mediaManager.audioItems
        case .offlineVideos: return mediaManager.videoItems
        case .allOffline: return mediaManager.items
        case .lastPlayed: return mediaManager.recentItems
        }
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No \(kind.rawValue)",
                    systemImage: kind.systemImage,
                    description: Text("Tracks matching this collection will appear here.")
                )
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                mediaManager.isShuffleEnabled = false
                                if let first = tracks.first {
                                    if mediaManager.play(first) && first.isVideo { showPlayerSheet = true }
                                }
                            } label: {
                                Label("Play All", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                mediaManager.isShuffleEnabled = true
                                if let picked = tracks.randomElement() {
                                    if mediaManager.play(picked) && picked.isVideo { showPlayerSheet = true }
                                }
                            } label: {
                                Label("Shuffle Play", systemImage: "shuffle")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                        }
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(tracks) { item in
                            MediaRowView(
                                item: item,
                                onPlay: {
                                    if mediaManager.currentItem?.relativePath == item.relativePath {
                                        if item.isVideo {
                                            showPlayerSheet = true
                                            if !mediaManager.isPlaying { mediaManager.resume() }
                                        } else {
                                            mediaManager.togglePlayPause()
                                        }
                                    } else {
                                        if mediaManager.play(item) && item.isVideo { showPlayerSheet = true }
                                    }
                                },
                                onQuickLook: {
                                    quickLookTarget = QuickLookTarget(title: item.displayTitle, fileURL: item.fileURL)
                                },
                                onRename: {
                                    renameText = item.name
                                    itemToRename = item
                                },
                                onEditInfo: {
                                    editingInfoItem = item
                                }
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(kind.rawValue)
        .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
        .sheet(item: $editingInfoItem) { item in
            EditTrackInfoSheet(item: item)
        }
        .alert(
            "Rename Media",
            isPresented: Binding(
                get: { itemToRename != nil },
                set: { if !$0 { itemToRename = nil } }
            )
        ) {
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) { itemToRename = nil }
            Button("Save") {
                if let itemToRename {
                    mediaManager.rename(itemToRename, to: renameText)
                }
                itemToRename = nil
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(PlaylistTimeMachineService.self) private var timeMachine
    @Environment(PlaylistImportManager.self) private var playlistImportManager
    let playlistID: UUID
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var showAddTracksSheet = false
    @State private var showTimeMachineSheet = false
    @State private var itemToRename: MediaItem?
    @State private var editingInfoItem: MediaItem?
    @State private var renameText = ""
    @State private var showCoverPicker = false
    @State private var selectedCoverPhoto: PhotosPickerItem?

    private var playlist: Playlist? {
        mediaManager.playlists.first(where: { $0.id == playlistID })
    }

    var body: some View {
        Group {
            if let playlist {
                let tracks = mediaManager.items(in: playlist)
                let activeImportJob = playlistImportManager.jobs.first(where: { $0.targetPlaylistID == playlist.id && !$0.isFinished })
                let hasNonEmptySnapshots = timeMachine.snapshots(for: playlist.id).contains { !$0.tracks.isEmpty }
                Group {
                    if tracks.isEmpty {
                        if let activeImportJob {
                            List {
                                Section("Downloading Playlist in Background") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(activeImportJob.isDiscoveringPages
                                             ? "Finding videos (\(activeImportJob.totalCount)+ discovered, no limit)..."
                                             : "Resolving via browser & caching (\(activeImportJob.processedCount) / \(activeImportJob.totalCount))...")
                                            .font(.subheadline.weight(.semibold))
                                        ProgressView(value: activeImportJob.progressFraction)
                                            .progressViewStyle(.linear)
                                        HStack {
                                            Text("\(activeImportJob.completedCount) saved • \(activeImportJob.skippedCount) cached")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button(activeImportJob.isPaused ? "Resume" : "Pause") {
                                                if activeImportJob.isPaused {
                                                    playlistImportManager.resumeJob(id: activeImportJob.id)
                                                } else {
                                                    playlistImportManager.pauseJob(id: activeImportJob.id)
                                                }
                                            }
                                            .font(.caption.weight(.semibold))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .listStyle(.insetGrouped)
                        } else {
                            ContentUnavailableView {
                                Label("Playlist Empty", systemImage: "music.note")
                            } description: {
                                Text("Add audio or video files from your library to this playlist.")
                            } actions: {
                                Button {
                                    showAddTracksSheet = true
                                } label: {
                                    Label("Add Media", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)

                                if hasNonEmptySnapshots {
                                    Button {
                                        showTimeMachineSheet = true
                                    } label: {
                                        Label("Restore from Time-Machine", systemImage: "clock.arrow.circlepath")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    } else {
                        List {
                            if let activeImportJob {
                                Section {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(activeImportJob.isPaused
                                                 ? "Paused: \(activeImportJob.processedCount) / \(activeImportJob.totalCount)"
                                                 : "Caching in background: \(activeImportJob.processedCount) / \(activeImportJob.totalCount)")
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            Button(activeImportJob.isPaused ? "Resume" : "Pause") {
                                                if activeImportJob.isPaused {
                                                    playlistImportManager.resumeJob(id: activeImportJob.id)
                                                } else {
                                                    playlistImportManager.pauseJob(id: activeImportJob.id)
                                                }
                                            }
                                            .font(.caption2.weight(.semibold))
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                        }
                                        ProgressView(value: activeImportJob.progressFraction)
                                            .progressViewStyle(.linear)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            Section {
                                HStack(spacing: 12) {
                                    Button {
                                        mediaManager.isShuffleEnabled = false
                                        mediaManager.playPlaylist(playlist)
                                        if mediaManager.currentItem?.isVideo == true {
                                            showPlayerSheet = true
                                        }
                                    } label: {
                                        Label("Play All", systemImage: "play.fill")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        mediaManager.isShuffleEnabled = true
                                        mediaManager.playPlaylist(playlist)
                                        if mediaManager.currentItem?.isVideo == true {
                                            showPlayerSheet = true
                                        }
                                    } label: {
                                        Label("Shuffle Play", systemImage: "shuffle")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.bordered)

                                    Menu {
                                        Button {
                                            mediaManager.addMultipleToQueue(tracks, playNext: true)
                                        } label: {
                                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        Button {
                                            mediaManager.addMultipleToQueue(tracks, playNext: false)
                                        } label: {
                                            Label("Add to Queue", systemImage: "text.append")
                                        }
                                    } label: {
                                        Image(systemName: "text.badge.plus")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 11)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("Queue Playlist")
                                }
                                .listRowSeparator(.hidden)
                            }

                            Section {
                                ForEach(tracks) { item in
                                    MediaRowView(
                                        item: item,
                                        onPlay: {
                                            if mediaManager.currentItem?.relativePath == item.relativePath {
                                                if item.isVideo {
                                                    showPlayerSheet = true
                                                    if !mediaManager.isPlaying {
                                                        mediaManager.resume()
                                                    }
                                                } else {
                                                    mediaManager.togglePlayPause()
                                                }
                                            } else {
                                                if mediaManager.play(item, inPlaylist: playlist.id) && item.isVideo {
                                                    showPlayerSheet = true
                                                }
                                            }
                                        },
                                        onQuickLook: {
                                            quickLookTarget = QuickLookTarget(title: item.displayTitle, fileURL: item.fileURL)
                                        },
                                        onRename: {
                                            renameText = item.name
                                            itemToRename = item
                                        },
                                        onEditInfo: {
                                            editingInfoItem = item
                                        }
                                    )
                                }
                                .onDelete { offsets in
                                    mediaManager.removeItems(at: offsets, from: playlist)
                                }
                                .onMove { source, destination in
                                    mediaManager.moveItems(from: source, to: destination, in: playlist)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .navigationTitle(playlist.name)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showTimeMachineSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Button {
                            showCoverPicker = true
                        } label: {
                            Image(systemName: "photo")
                        }
                        if !tracks.isEmpty {
                            EditButton()
                        }
                        Button {
                            showAddTracksSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                .photosPicker(isPresented: $showCoverPicker, selection: $selectedCoverPhoto, matching: .images)
                .onChange(of: selectedCoverPhoto) { _, picked in
                    guard let picked else { return }
                    selectedCoverPhoto = nil
                    Task {
                        if let data = try? await picked.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await MainActor.run {
                                mediaManager.updatePlaylistCover(for: playlist, image: image)
                            }
                        }
                    }
                }
                .sheet(isPresented: $showAddTracksSheet) {
                    AddToPlaylistSheet(playlist: playlist)
                }
                .sheet(item: $editingInfoItem) { item in
                    EditTrackInfoSheet(item: item)
                }
                .alert(
                    "Rename Media",
                    isPresented: Binding(
                        get: { itemToRename != nil },
                        set: { if !$0 { itemToRename = nil } }
                    )
                ) {
                    TextField("New name", text: $renameText)
                    Button("Cancel", role: .cancel) {
                        itemToRename = nil
                    }
                    Button("Save") {
                        if let itemToRename {
                            mediaManager.rename(itemToRename, to: renameText)
                        }
                        itemToRename = nil
                    }
                }
            } else {
                let recoverable = timeMachine.snapshots(for: playlistID).first(where: { !$0.tracks.isEmpty })
                    ?? timeMachine.latestSnapshot(for: playlistID)
                ContentUnavailableView {
                    Label("Playlist Deleted", systemImage: "trash")
                } description: {
                    Text(
                        recoverable != nil
                            ? "You can recover this playlist from its saved Time-Machine snapshot."
                            : "This playlist is no longer in your library."
                    )
                } actions: {
                    if let recoverable {
                        Button {
                            _ = mediaManager.restoreDeletedPlaylist(from: recoverable)
                        } label: {
                            Label("Recover Deleted Playlist", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .sheet(isPresented: $showTimeMachineSheet) {
            PlaylistTimeMachineSheet(
                initialPlaylistID: playlistID,
                showPlayerSheet: $showPlayerSheet
            )
        }
        .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
    }
}

private struct AddToPlaylistSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist

    @State private var searchText = ""

    private var currentPlaylist: Playlist {
        mediaManager.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [MediaItem] {
        guard !trimmedSearch.isEmpty else { return mediaManager.items }
        return mediaManager.items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmedSearch) ||
                ($0.artist?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                $0.fileExtension.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    private var unaddedFilteredItems: [MediaItem] {
        filteredItems.filter { !mediaManager.playlistContains($0, in: currentPlaylist) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if mediaManager.items.isEmpty {
                    ContentUnavailableView(
                        "No Library Media",
                        systemImage: "music.note",
                        description: Text("Import or download audio and video files first.")
                    )
                } else if filteredItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredItems) { item in
                        let isIncluded = mediaManager.playlistContains(item, in: currentPlaylist)
                        Button {
                            if isIncluded {
                                mediaManager.remove(item, from: currentPlaylist)
                            } else {
                                mediaManager.add(item, to: currentPlaylist)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                MediaArtworkView(
                                    item: item,
                                    image: mediaManager.thumbnails[item.relativePath],
                                    cornerRadius: 8,
                                    iconSize: 16
                                )
                                .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(item.fileExtension.uppercased()) • \(item.formattedFileSize)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: isIncluded ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.title3)
                                    .foregroundStyle(isIncluded ? Color.green : Color.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search library")
            .navigationTitle("Add to \(currentPlaylist.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !unaddedFilteredItems.isEmpty {
                        Button("Add All (\(unaddedFilteredItems.count))") {
                            for item in unaddedFilteredItems {
                                mediaManager.add(item, to: currentPlaylist)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PlaylistsRoutingModifier: ViewModifier {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
    @Environment(PlaylistTimeMachineService.self) private var timeMachine
    @Environment(PlaylistImportManager.self) private var playlistImportManager

    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?
    @Binding var createdPlaylistID: UUID?
    @Binding var selectedGroupID: UUID?
    @Binding var selectedPartyID: UUID?
    @Binding var showTimeMachineSheet: Bool
    @Binding var timeMachineTargetPlaylistID: UUID?
    @Binding var showCoverPicker: Bool
    @Binding var coverTargetPlaylist: Playlist?
    @Binding var selectedCoverPhoto: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $createdPlaylistID) { pid in
                PlaylistDetailView(
                    playlistID: pid,
                    showPlayerSheet: $showPlayerSheet,
                    quickLookTarget: $quickLookTarget
                )
            }
            .navigationDestination(item: $selectedGroupID) { gid in
                GroupPlaylistDetailView(
                    groupID: gid,
                    showPlayerSheet: $showPlayerSheet
                )
            }
            .navigationDestination(item: $selectedPartyID) { pid in
                PartyQueueDetailView(
                    partyID: pid,
                    showPlayerSheet: $showPlayerSheet
                )
            }
            .onAppear {
                if let pending = groupService.pendingOpenGroupID {
                    groupService.pendingOpenGroupID = nil
                    selectedGroupID = pending
                }
                if let pendingParty = partyService.pendingOpenPartyID {
                    partyService.pendingOpenPartyID = nil
                    selectedPartyID = pendingParty
                }
                if timeMachine.pendingOpenGlobalSheet {
                    timeMachine.pendingOpenGlobalSheet = false
                    timeMachineTargetPlaylistID = nil
                    showTimeMachineSheet = true
                }
            }
            .onChange(of: groupService.pendingOpenGroupID) { _, pending in
                if let pending {
                    groupService.pendingOpenGroupID = nil
                    selectedGroupID = pending
                }
            }
            .onChange(of: partyService.pendingOpenPartyID) { _, pendingParty in
                if let pendingParty {
                    partyService.pendingOpenPartyID = nil
                    selectedPartyID = pendingParty
                }
            }
            .onChange(of: timeMachine.pendingOpenGlobalSheet) { _, openSheet in
                if openSheet {
                    timeMachine.pendingOpenGlobalSheet = false
                    timeMachineTargetPlaylistID = nil
                    showTimeMachineSheet = true
                }
            }
            .photosPicker(isPresented: $showCoverPicker, selection: $selectedCoverPhoto, matching: .images)
            .onChange(of: selectedCoverPhoto) { _, picked in
                guard let picked, let target = coverTargetPlaylist else {
                    coverTargetPlaylist = nil
                    return
                }
                selectedCoverPhoto = nil
                Task {
                    let data = try? await picked.loadTransferable(type: Data.self)
                    let image = data.flatMap { UIImage(data: $0) }
                    await MainActor.run {
                        if let image {
                            mediaManager.updatePlaylistCover(for: target, image: image)
                        }
                        coverTargetPlaylist = nil
                    }
                }
            }
    }
}

private struct PlaylistsSheetsAndAlertsModifier: ViewModifier {
    @Environment(MediaManager.self) private var mediaManager

    @Binding var showPlayerSheet: Bool
    @Binding var searchEditingInfoItem: MediaItem?
    @Binding var showImportURLSheet: Bool
    @Binding var showCreateGroupSheet: Bool
    @Binding var showJoinGroupSheet: Bool
    @Binding var showCreatePartySheet: Bool
    @Binding var showJoinPartySheet: Bool
    @Binding var showTimeMachineSheet: Bool
    @Binding var timeMachineTargetPlaylistID: UUID?
    @Binding var createdPlaylistID: UUID?
    @Binding var selectedGroupID: UUID?
    @Binding var selectedPartyID: UUID?
    @Binding var showCreateAlert: Bool
    @Binding var newPlaylistName: String
    @Binding var playlistToRename: Playlist?
    @Binding var renameText: String
    @Binding var searchItemToRename: MediaItem?
    @Binding var searchRenameText: String

    func body(content: Content) -> some View {
        content
            .sheet(item: $searchEditingInfoItem) { item in
                EditTrackInfoSheet(item: item)
            }
            .sheet(isPresented: $showImportURLSheet) {
                ImportPlaylistSheetView { importedID in
                    createdPlaylistID = importedID
                }
            }
            .sheet(isPresented: $showCreateGroupSheet) {
                CreateGroupPlaylistSheet { newGroupID in
                    selectedGroupID = newGroupID
                }
            }
            .sheet(isPresented: $showJoinGroupSheet) {
                JoinGroupPlaylistSheet { joinedID in
                    selectedGroupID = joinedID
                }
            }
            .sheet(isPresented: $showCreatePartySheet) {
                CreatePartyQueueSheet { newPartyID in
                    selectedPartyID = newPartyID
                }
            }
            .sheet(isPresented: $showJoinPartySheet) {
                JoinPartyQueueSheet { joinedPartyID in
                    selectedPartyID = joinedPartyID
                }
            }
            .sheet(isPresented: $showTimeMachineSheet) {
                PlaylistTimeMachineSheet(
                    initialPlaylistID: timeMachineTargetPlaylistID,
                    showPlayerSheet: $showPlayerSheet
                ) { restoredPlaylistID in
                    createdPlaylistID = restoredPlaylistID
                }
            }
            .alert("New Playlist", isPresented: $showCreateAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
                Button("Create") {
                    if let created = mediaManager.createPlaylist(name: newPlaylistName) {
                        createdPlaylistID = created.id
                    }
                    newPlaylistName = ""
                }
            } message: {
                Text("Enter a name for your offline playlist.")
            }
            .alert(
                "Rename Playlist",
                isPresented: Binding(
                    get: { playlistToRename != nil },
                    set: { if !$0 { playlistToRename = nil } }
                )
            ) {
                TextField("Playlist name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    playlistToRename = nil
                }
                Button("Save") {
                    if let playlistToRename {
                        mediaManager.renamePlaylist(playlistToRename, to: renameText)
                    }
                    playlistToRename = nil
                }
            }
            .alert(
                "Rename Media",
                isPresented: Binding(
                    get: { searchItemToRename != nil },
                    set: { if !$0 { searchItemToRename = nil } }
                )
            ) {
                TextField("New name", text: $searchRenameText)
                Button("Cancel", role: .cancel) {
                    searchItemToRename = nil
                }
                Button("Save") {
                    if let item = searchItemToRename {
                        mediaManager.rename(item, to: searchRenameText)
                    }
                    searchItemToRename = nil
                }
            }
    }
}
