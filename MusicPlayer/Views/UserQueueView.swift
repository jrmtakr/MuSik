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

    private enum QueuePanelTab: String, CaseIterable {
        case upNext
        case discover
    }

    @State private var showAddSongsInline = false
    @State private var selectedTab: QueuePanelTab = .upNext
    @State private var discoverQueue = DiscoverQueueService.shared
    @State private var downloader = WebMediaDownloader.shared

    private struct QueuedRow: Identifiable {
        let index: Int
        let item: MediaItem
        var id: String { "\(index):\(item.relativePath)" }
    }

    private var queuedRows: [QueuedRow] {
        mediaManager.upNextItems.enumerated().map { QueuedRow(index: $0.offset, item: $0.element) }
    }

    private var continueItems: [MediaItem] {
        if mediaManager.activePlaylistID == nil && queuedRows.isEmpty && discoverQueue.isAutoPlayEnabled {
            return []
        }
        return mediaManager.continuePlayingItems
    }

    var body: some View {
        List {
            controlsAndNowPlayingSection
            if selectedTab == .upNext {
                userQueueSection
                if !continueItems.isEmpty {
                    continuePlayingSection
                }
            } else {
                discoverQueueSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(isEmbeddedDarkGlass ? .hidden : .automatic)
        .sheet(isPresented: $showAddSongsInline) {
            QueueSongPickerSheet()
        }
        .onAppear {
            if let current = mediaManager.currentItem {
                discoverQueue.refreshIfNeeded(for: current)
            }
        }
        .onChange(of: mediaManager.currentItem?.relativePath) { _, _ in
            if let current = mediaManager.currentItem {
                discoverQueue.refreshIfNeeded(for: current)
            }
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

            HStack(spacing: 8) {
                queueTabPill(.upNext, title: "Playing Next (\(queuedRows.count))", systemImage: "list.bullet")
                queueTabPill(.discover, title: "Discover Queue (\(discoverQueue.items.count))", systemImage: "sparkles")
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func queueTabPill(_ tab: QueuePanelTab, title: String, systemImage: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            AppHaptics.selection()
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
            }
            if tab == .discover, let current = mediaManager.currentItem {
                discoverQueue.refreshIfNeeded(for: current, force: discoverQueue.items.isEmpty)
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(
            isSelected
            ? (tab == .discover ? Color.purple : Color.accentColor)
            : (isEmbeddedDarkGlass ? Color.white.opacity(0.14) : Color.secondary.opacity(0.22))
        )
        .foregroundStyle(isSelected ? .white : (isEmbeddedDarkGlass ? .white.opacity(0.85) : .primary))
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
                    HStack(spacing: 6) {
                        Button {
                            if isEmbeddedDarkGlass {
                                showAddSongsInline = true
                            } else {
                                onAddSongs()
                            }
                        } label: {
                            Label("Browse Songs", systemImage: "plus.circle.fill")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            mediaManager.reshuffleQueueWithAllCachedMedia()
                        } label: {
                            Label("Reshuffle All", systemImage: "shuffle")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            AppHaptics.selection()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTab = .discover
                            }
                            if let current = mediaManager.currentItem {
                                discoverQueue.refreshIfNeeded(for: current, force: discoverQueue.items.isEmpty)
                            }
                        } label: {
                            Label("Discover Queue", systemImage: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
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

    private var discoverQueueSection: some View {
        Section {
            if let status = discoverQueue.statusMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.85) : .secondary)
                }
                .listRowBackground(Color.clear)
            }

            if discoverQueue.items.isEmpty && discoverQueue.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finding related songs & videos...")
                        .font(.caption)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.7) : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            } else if discoverQueue.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.7) : .secondary)
                    Text("No Related Tracks Yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                    Text("Play a song or video to populate related tracks automatically.")
                        .font(.caption)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.65) : .secondary)
                        .multilineTextAlignment(.center)
                    if let current = mediaManager.currentItem {
                        Button("Try Refresh") {
                            discoverQueue.refreshIfNeeded(for: current, force: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            } else {
                ForEach(discoverQueue.items) { item in
                    discoverQueueRow(item)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(
                        discoverQueue.seedTitle.isEmpty
                        ? "Discover Queue"
                        : "Discover Queue • Related to \(discoverQueue.seedTitle)"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)

                    Spacer()

                    Button {
                        AppHaptics.selection()
                        discoverQueue.isAutoPlayEnabled.toggle()
                    } label: {
                        Label(
                            discoverQueue.isAutoPlayEnabled ? "Auto-Play On" : "Auto-Play Off",
                            systemImage: discoverQueue.isAutoPlayEnabled ? "infinity.circle.fill" : "infinity.circle"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .tint(discoverQueue.isAutoPlayEnabled ? .purple : .secondary)

                    if let current = mediaManager.currentItem {
                        Button {
                            discoverQueue.refreshIfNeeded(for: current, force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .tint(isEmbeddedDarkGlass ? .white.opacity(0.8) : .accentColor)
                    }
                }
            }
        }
    }

    private func discoverQueueRow(_ item: DiscoverQueueItem) -> some View {
        let localMatch = item.localRelativePath.flatMap { path in
            mediaManager.items.first(where: { $0.relativePath == path })
        }
        return HStack(spacing: 12) {
            Button {
                Task {
                    await discoverQueue.playItem(item)
                }
            } label: {
                HStack(spacing: 12) {
                    if let localMatch {
                        MediaArtworkView(
                            item: localMatch,
                            image: mediaManager.thumbnails[localMatch.relativePath],
                            cornerRadius: 8,
                            iconSize: 15
                        )
                        .frame(width: 44, height: 44)
                    } else if let artURL = item.artworkURL {
                        AsyncImage(url: artURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.secondary.opacity(0.22))
                                    Image(systemName: item.kind == .video ? "film" : "music.note")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.22))
                            Image(systemName: item.kind == .video ? "film" : "music.note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text(item.kind.rawValue)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    (item.kind == .video ? Color.blue : Color.purple).opacity(0.22),
                                    in: Capsule()
                                )
                                .foregroundStyle(item.kind == .video ? Color.cyan : Color.purple)

                            if localMatch != nil {
                                Text("Offline")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.green)
                            }

                            Text(item.artist)
                                .font(.caption)
                                .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.68) : .secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let dur = item.durationText {
                        Text(dur)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.55) : .secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    Task { await discoverQueue.playItem(item) }
                } label: {
                    Label("Play Now", systemImage: "play.fill")
                }
                Button {
                    discoverQueue.enqueueNext(item, downloader: downloader)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    discoverQueue.addToPersonalQueue(item, downloader: downloader)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                if localMatch == nil && item.videoID != nil {
                    Button {
                        discoverQueue.cacheOffline(item, downloader: downloader)
                    } label: {
                        Label("Save Offline", systemImage: "arrow.down.circle")
                    }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.subheadline)
                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.75) : .secondary)
            }
        }
        .listRowBackground(Color.clear)
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
