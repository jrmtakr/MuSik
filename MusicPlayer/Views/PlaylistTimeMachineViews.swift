import SwiftUI

struct PlaylistTimeMachineSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(PlaylistTimeMachineService.self) private var timeMachine
    @Environment(\.dismiss) private var dismiss

    let initialPlaylistID: UUID?
    @Binding var showPlayerSheet: Bool
    var onOpenPlaylist: ((UUID) -> Void)? = nil

    @State private var selectedPlaylistFilterID: UUID?
    @State private var searchText = ""
    @State private var selectedSnapshotID: UUID?
    @State private var showCreateSnapshotAlert = false
    @State private var manualSnapshotLabel = ""
    @State private var showClearOldConfirm = false

    init(
        initialPlaylistID: UUID? = nil,
        showPlayerSheet: Binding<Bool>,
        onOpenPlaylist: ((UUID) -> Void)? = nil
    ) {
        self.initialPlaylistID = initialPlaylistID
        self._showPlayerSheet = showPlayerSheet
        self.onOpenPlaylist = onOpenPlaylist
        self._selectedPlaylistFilterID = State(initialValue: initialPlaylistID)
    }

    private var focusedActivePlaylist: Playlist? {
        guard let selectedPlaylistFilterID else { return nil }
        return mediaManager.playlists.first(where: { $0.id == selectedPlaylistFilterID })
    }

    private var activePlaylistIDs: Set<UUID> {
        Set(mediaManager.playlists.map(\.id))
    }

    private var archivedDeletedPlaylists: [ArchivedDeletedPlaylistSummary] {
        timeMachine.archivedDeletedPlaylists(activePlaylistIDs: activePlaylistIDs)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSnapshots: [PlaylistSnapshot] {
        timeMachine.snapshots.filter { snap in
            if let selectedPlaylistFilterID, snap.playlistID != selectedPlaylistFilterID {
                return false
            }
            guard !trimmedSearch.isEmpty else { return true }
            if snap.playlistName.localizedCaseInsensitiveContains(trimmedSearch) ||
                snap.label.localizedCaseInsensitiveContains(trimmedSearch) ||
                snap.trigger.displayTitle.localizedCaseInsensitiveContains(trimmedSearch) {
                return true
            }
            return snap.tracks.contains { track in
                track.displayTitle.localizedCaseInsensitiveContains(trimmedSearch) ||
                    (track.artist?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                    track.fileName.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
    }

    private var groupedByMonth: [(title: String, snapshots: [PlaylistSnapshot])] {
        var order: [String] = []
        var buckets: [String: [PlaylistSnapshot]] = [:]
        for snap in filteredSnapshots {
            let key = Self.monthYearFormatter.string(from: snap.createdAt)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(snap)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        @Bindable var timeMachine = timeMachine

        NavigationStack {
            List {
                overviewSection(autoEnabled: $timeMachine.autoSnapshotsEnabled)

                if selectedPlaylistFilterID == nil,
                   !archivedDeletedPlaylists.isEmpty,
                   trimmedSearch.isEmpty {
                    deletedPlaylistsSection
                }

                if groupedByMonth.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Snapshots Yet", systemImage: "clock.arrow.circlepath")
                        } description: {
                            Text(
                                trimmedSearch.isEmpty
                                    ? "Snapshots are automatically saved whenever playlists change, or you can save a checkpoint anytime."
                                    : "No snapshots match \"\(searchText)\"."
                            )
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(groupedByMonth, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.snapshots) { snapshot in
                                snapshotRow(snapshot)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .applyAppTheme()
            .navigationTitle(focusedActivePlaylist?.name ?? "Playlist Time-Machine")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search snapshots or song titles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                if !timeMachine.snapshots.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let playlist = focusedActivePlaylist {
                                Button {
                                    manualSnapshotLabel = ""
                                    showCreateSnapshotAlert = true
                                } label: {
                                    Label("Save Checkpoint for \"\(playlist.name)\"", systemImage: "bookmark.fill")
                                }
                            } else {
                                Button {
                                    let count = timeMachine.captureAllPlaylistsNow(
                                        playlists: mediaManager.playlists,
                                        items: mediaManager.items,
                                        metadataByPath: mediaManager.customMetadataByPath
                                    )
                                    mediaManager.statusMessage = "Saved checkpoints for \(count) \(count == 1 ? "playlist" : "playlists")"
                                } label: {
                                    Label("Snapshot All Playlists Now", systemImage: "square.stack.3d.up.fill")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                showClearOldConfirm = true
                            } label: {
                                Label("Clear Unpinned History (> 30 Days)", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .navigationDestination(item: $selectedSnapshotID) { snapID in
                PlaylistSnapshotDetailView(
                    snapshotID: snapID,
                    showPlayerSheet: $showPlayerSheet,
                    onRestoredPlaylist: { pid in
                        dismiss()
                        onOpenPlaylist?(pid)
                    }
                )
            }
            .alert("Save Playlist Snapshot", isPresented: $showCreateSnapshotAlert) {
                TextField("Checkpoint name (optional)", text: $manualSnapshotLabel)
                Button("Cancel", role: .cancel) { manualSnapshotLabel = "" }
                Button("Save") {
                    if let target = focusedActivePlaylist ?? mediaManager.playlists.first {
                        let created = timeMachine.createManualSnapshot(
                            for: target,
                            items: mediaManager.items,
                            metadataByPath: mediaManager.customMetadataByPath,
                            label: manualSnapshotLabel
                        )
                        mediaManager.statusMessage = "Saved snapshot \"\(created.label)\""
                    }
                    manualSnapshotLabel = ""
                }
            } message: {
                Text("Pinned snapshots are preserved permanently and never auto-pruned.")
            }
            .confirmationDialog(
                "Clear older unpinned snapshots?",
                isPresented: $showClearOldConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove Unpinned Older Than 30 Days", role: .destructive) {
                    let removed = timeMachine.clearUnpinnedHistory(
                        for: selectedPlaylistFilterID,
                        olderThanDays: 30
                    )
                    mediaManager.statusMessage = "Cleared \(removed) older unpinned \(removed == 1 ? "snapshot" : "snapshots")"
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pinned checkpoints and deleted-playlist backups will not be removed.")
            }
        }
    }

    @ViewBuilder
    private func overviewSection(autoEnabled: Binding<Bool>) -> some View {
        Section {
            if initialPlaylistID == nil && (!mediaManager.playlists.isEmpty || !archivedDeletedPlaylists.isEmpty) {
                Picker("Playlist", selection: $selectedPlaylistFilterID) {
                    Text("All Playlists & Archive").tag(UUID?.none)
                    ForEach(mediaManager.playlists) { playlist in
                        Text("\(playlist.name) (\(timeMachine.snapshotCount(for: playlist.id)))")
                            .tag(UUID?.some(playlist.id))
                    }
                    ForEach(archivedDeletedPlaylists) { summary in
                        Text("\(summary.latestName) [Deleted] (\(summary.totalVersions))")
                            .tag(UUID?.some(summary.playlistID))
                    }
                }
            }

            if let playlist = focusedActivePlaylist {
                let currentCount = mediaManager.items(in: playlist).count
                let snapCount = timeMachine.snapshotCount(for: playlist.id)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playlist.name)
                            .font(.headline)
                        Text("\(currentCount) live tracks • \(snapCount) \(snapCount == 1 ? "snapshot" : "snapshots")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        manualSnapshotLabel = ""
                        showCreateSnapshotAlert = true
                    } label: {
                        Label("Save Now", systemImage: "bookmark.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    let count = timeMachine.captureAllPlaylistsNow(
                        playlists: mediaManager.playlists,
                        items: mediaManager.items,
                        metadataByPath: mediaManager.customMetadataByPath
                    )
                    mediaManager.statusMessage = count > 0
                        ? "Saved checkpoints for \(count) \(count == 1 ? "playlist" : "playlists")"
                        : "Create a playlist first to snapshot."
                } label: {
                    Label("Snapshot All Playlists Now", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(mediaManager.playlists.isEmpty)
            }

            Toggle("Auto-Save Playlist History", isOn: autoEnabled)
        } footer: {
            let sizeText = ByteCountFormatter.string(fromByteCount: timeMachine.storageSizeBytes, countStyle: .file)
            Text("\(timeMachine.snapshots.count) total snapshots (\(sizeText)). Automatically saves before deletions, edits, and imports, thinning older auto-history cleanly to daily and weekly backups.")
        }
    }

    private var deletedPlaylistsSection: some View {
        Section("Deleted Playlists Archive") {
            ForEach(archivedDeletedPlaylists) { summary in
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.pink.opacity(0.16))
                            .frame(width: 40, height: 40)
                        Image(systemName: "trash.slash.fill")
                            .foregroundStyle(.pink)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.latestName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(summary.latestSnapshot.tracks.count) tracks • \(summary.latestSnapshot.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Recover") {
                        let res = mediaManager.restoreDeletedPlaylist(from: summary.latestSnapshot)
                        dismiss()
                        onOpenPlaylist?(res.playlist.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedSnapshotID = summary.latestSnapshot.id
                }
            }
        }
    }

    private func snapshotRow(_ snapshot: PlaylistSnapshot) -> some View {
        let currentPlaylist = mediaManager.playlists.first(where: { $0.id == snapshot.playlistID })
        let diff = timeMachine.diff(
            snapshot: snapshot,
            against: currentPlaylist,
            items: mediaManager.items,
            metadataByPath: mediaManager.customMetadataByPath
        )

        return Button {
            selectedSnapshotID = snapshot.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(snapshot.trigger.tintColor.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: snapshot.trigger.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.trigger.tintColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(snapshot.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if snapshot.isPinned {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }

                    HStack(spacing: 5) {
                        if focusedActivePlaylist == nil {
                            Text(snapshot.playlistName)
                                .fontWeight(.medium)
                            Text("•")
                        }
                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("(\(snapshot.createdAt.formatted(.relative(presentation: .named))))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    HStack(spacing: 6) {
                        badge("\(snapshot.tracks.count) tracks", color: .secondary)

                        if currentPlaylist == nil {
                            badge("Deleted Playlist", color: .pink)
                        } else if diff.matchesCurrent {
                            badge("Current", color: .green)
                        } else {
                            if !diff.removedSinceSnapshot.isEmpty {
                                badge("-\(diff.removedSinceSnapshot.count) removed since", color: .red)
                            }
                            if !diff.addedSinceSnapshot.isEmpty {
                                badge("+\(diff.addedSinceSnapshot.count) added", color: .green)
                            }
                            if diff.reordered {
                                badge("Reordered", color: .orange)
                            }
                            if diff.renamedFrom != nil {
                                badge("Renamed", color: .indigo)
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                timeMachine.togglePin(snapshot.id)
            } label: {
                Label(snapshot.isPinned ? "Unpin" : "Pin", systemImage: snapshot.isPinned ? "bookmark.slash" : "bookmark.fill")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                timeMachine.deleteSnapshot(snapshot.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}

// MARK: - Snapshot Detail & Selective Restore View

struct PlaylistSnapshotDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(PlaylistTimeMachineService.self) private var timeMachine
    @Environment(WebMediaDownloader.self) private var downloader

    let snapshotID: UUID
    @Binding var showPlayerSheet: Bool
    var onRestoredPlaylist: ((UUID) -> Void)? = nil

    private enum DetailFilter: String, CaseIterable, Identifiable {
        case all = "All Tracks"
        case deletedSince = "Deleted Since Then"
        case addedSince = "Added After"
        var id: String { rawValue }
    }

    @State private var detailFilter: DetailFilter = .all
    @State private var revertIncludeName = true
    @State private var showRevertConfirm = false
    @State private var showCopyNameAlert = false
    @State private var copyNameText = ""
    @State private var showRenameAlert = false
    @State private var renameLabelText = ""
    @State private var downloadingTrackIDs: Set<String> = []
    @State private var shareFileURL: URL?

    private var snapshot: PlaylistSnapshot? {
        timeMachine.snapshots.first(where: { $0.id == snapshotID })
    }

    private var currentPlaylist: Playlist? {
        guard let snapshot else { return nil }
        return mediaManager.playlists.first(where: { $0.id == snapshot.playlistID })
    }

    var body: some View {
        Group {
            if let snapshot {
                let diff = timeMachine.diff(
                    snapshot: snapshot,
                    against: currentPlaylist,
                    items: mediaManager.items,
                    metadataByPath: mediaManager.customMetadataByPath
                )
                let removedKeys = Set(diff.removedSinceSnapshot.map(\.key))
                let displayedTracks: [PlaylistSnapshotTrack] = {
                    switch detailFilter {
                    case .all:
                        return snapshot.tracks
                    case .deletedSince:
                        return diff.removedSinceSnapshot
                    case .addedSince:
                        return diff.addedSinceSnapshot
                    }
                }()

                List {
                    headerCard(snapshot: snapshot, diff: diff)
                    restoreActionsSection(snapshot: snapshot, diff: diff)

                    Section {
                        if currentPlaylist != nil {
                            Picker("View", selection: $detailFilter) {
                                Text("All (\(snapshot.tracks.count))").tag(DetailFilter.all)
                                if !diff.removedSinceSnapshot.isEmpty {
                                    Text("Deleted (\(diff.removedSinceSnapshot.count))").tag(DetailFilter.deletedSince)
                                }
                                if !diff.addedSinceSnapshot.isEmpty {
                                    Text("Added (\(diff.addedSinceSnapshot.count))").tag(DetailFilter.addedSince)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if displayedTracks.isEmpty {
                            Text("No tracks in this view.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(displayedTracks) { track in
                                trackRow(
                                    track,
                                    snapshot: snapshot,
                                    isRemovedSince: removedKeys.contains(track.key),
                                    isAddedAfter: detailFilter == .addedSince
                                )
                            }
                        }
                    } header: {
                        Text(detailFilter == .addedSince ? "Tracks Added After This Snapshot" : "Snapshot Tracklist")
                    }
                }
                .listStyle(.insetGrouped)
                .applyAppTheme()
                .navigationTitle(snapshot.playlistName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            timeMachine.togglePin(snapshot.id)
                        } label: {
                            Image(systemName: snapshot.isPinned ? "bookmark.fill" : "bookmark")
                        }

                        if let shareFileURL {
                            ShareLink(item: shareFileURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
                .onAppear {
                    shareFileURL = timeMachine.exportSnapshotJSON(snapshot)
                }
                .onChange(of: snapshot) { _, updated in
                    shareFileURL = timeMachine.exportSnapshotJSON(updated)
                }
                .confirmationDialog(
                    "Revert \"\(currentPlaylist?.name ?? snapshot.playlistName)\" to this version?",
                    isPresented: $showRevertConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Revert Playlist", role: .destructive) {
                        if let currentPlaylist {
                            _ = mediaManager.revertPlaylist(
                                currentPlaylist.id,
                                to: snapshot,
                                includeName: revertIncludeName
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your current playlist state will be auto-saved as a Safety Backup first so you can undo anytime.")
                }
                .alert("Save Snapshot as New Copy", isPresented: $showCopyNameAlert) {
                    TextField("Playlist name", text: $copyNameText)
                    Button("Cancel", role: .cancel) {}
                    Button("Create Copy") {
                        let result = mediaManager.restoreSnapshotAsCopy(snapshot, customName: copyNameText)
                        onRestoredPlaylist?(result.playlist.id)
                    }
                } message: {
                    Text("Creates a new playlist without modifying \"\(currentPlaylist?.name ?? snapshot.playlistName)\".")
                }
                .alert("Rename Snapshot", isPresented: $showRenameAlert) {
                    TextField("Snapshot label", text: $renameLabelText)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        timeMachine.renameSnapshot(snapshot.id, label: renameLabelText)
                    }
                }
            } else {
                ContentUnavailableView("Snapshot Deleted", systemImage: "trash")
            }
        }
    }

    private func headerCard(snapshot: PlaylistSnapshot, diff: PlaylistSnapshotDiff) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: snapshot.trigger.systemImage)
                        .foregroundStyle(snapshot.trigger.tintColor)
                    Text(snapshot.label)
                        .font(.headline)
                    Spacer()
                    Button {
                        renameLabelText = snapshot.label
                        showRenameAlert = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                Text("\(snapshot.createdAt.formatted(date: .long, time: .shortened)) • \(snapshot.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let missingCount = diff.missingFilesInSnapshot.count
                let filesStatusText = missingCount == 0
                    ? "All files available offline"
                    : "\(missingCount) missing offline \(missingCount == 1 ? "file" : "files")"
                Text("\(snapshot.tracks.count) \(snapshot.tracks.count == 1 ? "track" : "tracks") recorded • \(filesStatusText)")
                    .font(.caption)
                    .foregroundStyle(missingCount == 0 ? Color.secondary : Color.orange)

                if let currentPlaylist {
                    if diff.matchesCurrent {
                        Label("Matches current playlist exactly", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            if !diff.removedSinceSnapshot.isEmpty {
                                Text("• \(diff.removedSinceSnapshot.count) \(diff.removedSinceSnapshot.count == 1 ? "song" : "songs") removed from \"\(currentPlaylist.name)\" since this snapshot")
                                    .foregroundStyle(.red)
                            }
                            if !diff.addedSinceSnapshot.isEmpty {
                                Text("• \(diff.addedSinceSnapshot.count) \(diff.addedSinceSnapshot.count == 1 ? "song" : "songs") added after this snapshot")
                                    .foregroundStyle(.green)
                            }
                            if diff.reordered {
                                Text("• Track order changed since this snapshot")
                                    .foregroundStyle(.orange)
                            }
                            if let oldName = diff.renamedFrom {
                                Text("• Playlist name was \"\(oldName)\" (now \"\(currentPlaylist.name)\")")
                                    .foregroundStyle(.indigo)
                            }
                        }
                        .font(.caption)
                    }
                } else {
                    Label("This playlist was deleted — ready to recover.", systemImage: "trash.slash.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.pink)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func restoreActionsSection(snapshot: PlaylistSnapshot, diff: PlaylistSnapshotDiff) -> some View {
        Section("Restore Actions") {
            if let currentPlaylist {
                if !diff.restorableRemovedItems.isEmpty {
                    Button {
                        _ = mediaManager.restoreDeletedSongs(
                            tracksToRestore: diff.restorableRemovedItems,
                            snapshotTracks: snapshot.tracks,
                            into: currentPlaylist.id
                        )
                    } label: {
                        Label(
                            "Add Back \(diff.restorableRemovedItems.count) Deleted \(diff.restorableRemovedItems.count == 1 ? "Song" : "Songs")",
                            systemImage: "arrow.uturn.backward.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    }
                }

                if !diff.matchesCurrent {
                    if diff.renamedFrom != nil {
                        Toggle("Also revert name to \"\(snapshot.playlistName)\"", isOn: $revertIncludeName)
                    }

                    Button {
                        showRevertConfirm = true
                    } label: {
                        Label("Revert Entire Playlist to This Snapshot", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    let stamp = PlaylistTimeMachineService.shortDateFormatter.string(from: snapshot.createdAt)
                    copyNameText = "\(snapshot.playlistName) (\(stamp))"
                    showCopyNameAlert = true
                } label: {
                    Label("Restore as New Playlist Copy", systemImage: "plus.rectangle.on.folder")
                }
            } else {
                Button {
                    let result = mediaManager.restoreDeletedPlaylist(from: snapshot)
                    onRestoredPlaylist?(result.playlist.id)
                } label: {
                    Label("Recover Deleted Playlist", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.pink)
                }
            }
        }
    }

    private func trackRow(
        _ track: PlaylistSnapshotTrack,
        snapshot: PlaylistSnapshot,
        isRemovedSince: Bool,
        isAddedAfter: Bool
    ) -> some View {
        let matched = timeMachine.resolveLibraryItem(
            for: track,
            in: mediaManager.items,
            metadataByPath: mediaManager.customMetadataByPath
        )
        let isDownloading = downloadingTrackIDs.contains(track.id)

        return HStack(spacing: 12) {
            Image(systemName: track.isVideo ? "film.fill" : "music.note")
                .font(.body)
                .foregroundStyle(matched == nil ? .orange : (isRemovedSince ? .red : .accentColor))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(track.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if matched == nil {
                    Text("Offline file missing from Files")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else if isRemovedSince {
                    Text("Removed since this snapshot")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                } else if isAddedAfter {
                    Text("Added after this snapshot")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if let matched {
                if isRemovedSince, let currentPlaylist {
                    Button("Restore") {
                        mediaManager.restoreSingleTrackFromTimeMachine(
                            matched,
                            snapshotTrack: track,
                            snapshotTracks: snapshot.tracks,
                            into: currentPlaylist.id
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption.weight(.semibold))
                }

                Button {
                    if mediaManager.play(matched) && matched.isVideo {
                        showPlayerSheet = true
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if isDownloading {
                ProgressView()
                    .scaleEffect(0.85)
            } else {
                Button {
                    downloadingTrackIDs.insert(track.id)
                    let targetPlaylistID = currentPlaylist?.id
                    Task {
                        _ = await timeMachine.reDownloadMissingTrack(
                            track,
                            into: targetPlaylistID,
                            downloader: downloader
                        )
                        downloadingTrackIDs.remove(track.id)
                    }
                } label: {
                    Label("Re-Download", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
