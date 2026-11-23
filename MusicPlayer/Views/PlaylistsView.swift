import SwiftUI

struct PlaylistsView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var showCreateAlert = false
    @State private var newPlaylistName = ""
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if mediaManager.playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No Playlists Yet", systemImage: "music.note.list")
                    } description: {
                        Text("Create offline playlists to organize tracks and launch them hands-free with Siri or Shortcuts.")
                    } actions: {
                        Button {
                            newPlaylistName = ""
                            showCreateAlert = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if settings.quickAccessLastPlaylist, let last = mediaManager.lastPlaylist {
                            Section("Quick Access") {
                                let count = mediaManager.items(in: last).count
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.18))
                                            .frame(width: 46, height: 46)
                                        Image(systemName: "bolt.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(Color.accentColor)
                                    }

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
                                        mediaManager.playPlaylist(last)
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

                        Section("All Playlists") {
                            ForEach(mediaManager.playlists) { playlist in
                                let resolvedCount = mediaManager.items(in: playlist).count
                                let isActive = mediaManager.activePlaylistID == playlist.id

                                NavigationLink {
                                    PlaylistDetailView(
                                        playlistID: playlist.id,
                                        showPlayerSheet: $showPlayerSheet,
                                        quickLookTarget: $quickLookTarget
                                    )
                                } label: {
                                    HStack(spacing: 14) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(isActive ? Color.accentColor : Color.accentColor.opacity(0.15))
                                                .frame(width: 50, height: 50)
                                            Image(systemName: isActive && mediaManager.isPlaying ? "waveform" : "music.note.list")
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(isActive ? .white : Color.accentColor)
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(isActive ? Color.accentColor : .primary)
                                                .lineLimit(1)

                                            Text("\(resolvedCount) \(resolvedCount == 1 ? "item" : "items")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Button {
                                            mediaManager.playPlaylist(playlist)
                                        } label: {
                                            Image(systemName: "play.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(resolvedCount == 0 ? Color.secondary.opacity(0.4) : Color.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(resolvedCount == 0)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .contextMenu {
                                    Button {
                                        mediaManager.playPlaylist(playlist)
                                    } label: {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                    .disabled(resolvedCount == 0)

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
                            .onDelete { offsets in
                                for index in offsets {
                                    if mediaManager.playlists.indices.contains(index) {
                                        mediaManager.deletePlaylist(mediaManager.playlists[index])
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showCreateAlert = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .alert("New Playlist", isPresented: $showCreateAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
                Button("Create") {
                    mediaManager.createPlaylist(name: newPlaylistName)
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
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    let playlistID: UUID
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var showAddTracksSheet = false
    @State private var itemToRename: MediaItem?
    @State private var editingInfoItem: MediaItem?
    @State private var renameText = ""

    private var playlist: Playlist? {
        mediaManager.playlists.first(where: { $0.id == playlistID })
    }

    var body: some View {
        Group {
            if let playlist {
                let tracks = mediaManager.items(in: playlist)
                Group {
                    if tracks.isEmpty {
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
                        }
                    } else {
                        List {
                            Section {
                                HStack(spacing: 12) {
                                    Button {
                                        mediaManager.isShuffleEnabled = false
                                        mediaManager.playPlaylist(playlist)
                                    } label: {
                                        Label("Play", systemImage: "play.fill")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        mediaManager.isShuffleEnabled = true
                                        mediaManager.playPlaylist(playlist)
                                    } label: {
                                        Label("Shuffle", systemImage: "shuffle")
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
                                                    if !mediaManager.isPlaying {
                                                        mediaManager.resume()
                                                    }
                                                } else {
                                                    mediaManager.togglePlayPause()
                                                }
                                            } else {
                                                mediaManager.play(item, inPlaylist: playlist.id)
                                                if item.isVideo {
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
                ContentUnavailableView("Playlist Deleted", systemImage: "trash")
            }
        }
        .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
    }
}

private struct AddToPlaylistSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist

    private var currentPlaylist: Playlist {
        mediaManager.playlists.first(where: { $0.id == playlist.id }) ?? playlist
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
                } else {
                    List(mediaManager.items) { item in
                        let isIncluded = mediaManager.playlistContains(item, in: currentPlaylist)
                        Button {
                            if !isIncluded {
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add to \(currentPlaylist.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
