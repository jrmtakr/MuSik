import SwiftUI

/// Full Apple Music-style Queue management view ("Playing Next" + Continue Playing + Song Picker).
/// Can be presented standalone as a sheet (from MiniPlayerBar, Library, Playlists, or NowPlaying)
/// or embedded directly inside NowPlayingView.
struct UserQueueSheetView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSongsSheet = false

    var body: some View {
        NavigationStack {
            UserQueueContentView(
                isEmbeddedDarkGlass: false,
                onAddSongs: { showAddSongsSheet = true }
            )
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !mediaManager.upNextItems.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showAddSongsSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add Songs to Queue")

                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showAddSongsSheet) {
                QueueSongPickerSheet()
            }
        }
    }
}

struct UserQueueContentView: View {
    @Environment(MediaManager.self) private var mediaManager

    var isEmbeddedDarkGlass: Bool = false
    let onAddSongs: () -> Void

    @State private var showAddSongsInline = false

    private struct QueuedRow: Identifiable {
        let index: Int
        let item: MediaItem
        var id: String { "\(index):\(item.relativePath)" }
    }

    private var queuedRows: [QueuedRow] {
        mediaManager.upNextItems.enumerated().map { QueuedRow(index: $0.offset, item: $0.element) }
    }

    private var continueItems: [MediaItem] {
        mediaManager.continuePlayingItems
    }

    var body: some View {
        List {
            controlsAndNowPlayingSection
            userQueueSection
            if !continueItems.isEmpty {
                continuePlayingSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(isEmbeddedDarkGlass ? .hidden : .automatic)
        .sheet(isPresented: $showAddSongsInline) {
            QueueSongPickerSheet()
        }
    }

    private var controlsAndNowPlayingSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    AppHaptics.selection()
                    mediaManager.isShuffleEnabled.toggle()
                } label: {
                    Label(mediaManager.isShuffleEnabled ? "Shuffle On" : "Shuffle", systemImage: "shuffle")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(mediaManager.isShuffleEnabled ? .accentColor : .secondary.opacity(0.28))

                Button {
                    AppHaptics.selection()
                    mediaManager.cycleRepeatMode()
                } label: {
                    Label(mediaManager.repeatMode.label, systemImage: mediaManager.repeatMode.systemImage)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(mediaManager.repeatMode != .off ? .accentColor : .secondary.opacity(0.28))

                Button {
                    if isEmbeddedDarkGlass {
                        showAddSongsInline = true
                    } else {
                        onAddSongs()
                    }
                } label: {
                    Label("Add Songs", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let current = mediaManager.currentItem {
                HStack(spacing: 12) {
                    MediaArtworkView(
                        item: current,
                        image: mediaManager.thumbnails[current.relativePath],
                        cornerRadius: 8,
                        iconSize: 16
                    )
                    .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("NOW PLAYING")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text(current.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                            .lineLimit(1)
                        if let artist = current.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.68) : .secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        mediaManager.togglePlayPause()
                    } label: {
                        Image(systemName: mediaManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isEmbeddedDarkGlass ? .white : .accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                .listRowBackground(isEmbeddedDarkGlass ? Color.white.opacity(0.08) : Color.secondary.opacity(0.08))
            }
        }
    }

    private var userQueueSection: some View {
        Section {
            if queuedRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.plus")
                        .font(.title2)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.7) : .secondary)
                    Text("Your Queue is Empty")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                    Text("Queue any song from your library or playlists to listen next in order.")
                        .font(.caption)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.65) : .secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Button {
                            if isEmbeddedDarkGlass {
                                showAddSongsInline = true
                            } else {
                                onAddSongs()
                            }
                        } label: {
                            Label("Browse Songs", systemImage: "plus.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            mediaManager.reshuffleQueueWithAllCachedMedia()
                        } label: {
                            Label("Reshuffle All", systemImage: "shuffle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            } else {
                ForEach(queuedRows) { row in
                    Button {
                        mediaManager.playQueuedItem(at: row.index)
                    } label: {
                        HStack(spacing: 12) {
                            MediaArtworkView(
                                item: row.item,
                                image: mediaManager.thumbnails[row.item.relativePath],
                                cornerRadius: 8,
                                iconSize: 15
                            )
                            .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.item.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                                    .lineLimit(1)
                                Text(row.item.artist ?? row.item.fileExtension.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.68) : .secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if let dur = row.item.formattedDuration {
                                Text(dur)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.55) : .secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            mediaManager.playQueuedItem(at: row.index)
                        } label: {
                            Label("Play Now", systemImage: "play.fill")
                        }
                        if row.index > 0 {
                            Button {
                                mediaManager.moveQueuedItemToTop(at: row.index)
                            } label: {
                                Label("Move to Top (Play Next)", systemImage: "arrow.up.to.line")
                            }
                        }
                        Button(role: .destructive) {
                            mediaManager.removeFromUpNext(at: IndexSet(integer: row.index))
                        } label: {
                            Label("Remove from Queue", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    mediaManager.removeFromUpNext(at: offsets)
                }
                .onMove { source, destination in
                    mediaManager.moveUpNext(from: source, to: destination)
                }
            }
        } header: {
            HStack {
                Text("Playing Next (\(queuedRows.count))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.82) : .secondary)
                Spacer()
                if !mediaManager.items.isEmpty {
                    Button {
                        mediaManager.reshuffleQueueWithAllCachedMedia()
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(isEmbeddedDarkGlass ? .white : .accentColor)
                }
                if !queuedRows.isEmpty {
                    Button("Clear", role: .destructive) {
                        mediaManager.clearUpNext()
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private var continuePlayingSection: some View {
        Section {
            ForEach(continueItems.prefix(80)) { item in
                HStack(spacing: 12) {
                    Button {
                        mediaManager.play(item, inPlaylist: mediaManager.activePlaylistID)
                    } label: {
                        HStack(spacing: 12) {
                            MediaArtworkView(
                                item: item,
                                image: mediaManager.thumbnails[item.relativePath],
                                cornerRadius: 8,
                                iconSize: 15
                            )
                            .frame(width: 42, height: 42)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.92) : .primary)
                                    .lineLimit(1)
                                Text(item.artist ?? item.fileExtension.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.6) : .secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button {
                            mediaManager.addToNextPlay(item)
                        } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            mediaManager.addToQueue(item)
                        } label: {
                            Label("Add to Queue", systemImage: "text.append")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.subheadline)
                            .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.7) : .secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Continue Playing • \(mediaManager.upcomingContextTitle)")
                .font(.caption.weight(.bold))
                .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.75) : .secondary)
        }
    }
}

/// Fast song & playlist picker so users can build their own Up Next queue in seconds.
struct QueueSongPickerSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var feedbackMessage: String?

    private var filteredSongs: [MediaItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = mediaManager.items
        guard !q.isEmpty else { return Array(base.prefix(250)) }
        return base.filter {
            $0.displayTitle.lowercased().contains(q)
                || ($0.artist?.lowercased().contains(q) ?? false)
                || $0.fileName.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let feedbackMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(feedbackMessage)
                            .font(.caption.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.12))
                }

                List {
                    if searchText.isEmpty && !mediaManager.playlists.isEmpty {
                        Section("Queue Entire Playlist") {
                            ForEach(mediaManager.playlists) { playlist in
                                let plItems = mediaManager.items(in: playlist)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(plItems.count) \(plItems.count == 1 ? "song" : "songs")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Play Next") {
                                        mediaManager.addMultipleToQueue(plItems, playNext: true)
                                        feedbackMessage = "Queued \"\(playlist.name)\" to Play Next"
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(plItems.isEmpty)

                                    Button("Queue") {
                                        mediaManager.addMultipleToQueue(plItems, playNext: false)
                                        feedbackMessage = "Added \"\(playlist.name)\" to Queue"
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(plItems.isEmpty)
                                }
                            }
                        }
                    }

                    Section("Songs (\(filteredSongs.count))") {
                        ForEach(filteredSongs) { item in
                            HStack(spacing: 10) {
                                MediaArtworkView(
                                    item: item,
                                    image: mediaManager.thumbnails[item.relativePath],
                                    cornerRadius: 8,
                                    iconSize: 15
                                )
                                .frame(width: 42, height: 42)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(item.artist ?? item.fileExtension.uppercased())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button {
                                    mediaManager.addToNextPlay(item)
                                    feedbackMessage = "Play Next: \(item.displayTitle)"
                                } label: {
                                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("Play Next")

                                Button {
                                    mediaManager.addToQueue(item)
                                    feedbackMessage = "Queued: \(item.displayTitle)"
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.subheadline.weight(.bold))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityLabel("Add to Queue")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Add Songs to Queue")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search songs, artists, or filenames")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(mediaManager.upNextItems.count) queued")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
