import AVKit
import SwiftUI

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}

private enum NowPlayingDisplayMode {
    case player
    case lyrics
    case messages
    case queue
}

struct NowPlayingView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(SleepTimerManager.self) private var sleepTimer
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(SyncedLyricsService.self) private var lyricsService
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(\.dismiss) private var dismiss

    @State private var displayMode: NowPlayingDisplayMode = .player
    @State private var scrubPosition: Double = 0
    @State private var isEditingScrubber = false
    @State private var showCustomSleepAlert = false
    @State private var customSleepMinutes = ""
    @State private var showEqualizerSheet = false
    @State private var showQueueSheet = false
    @State private var showAddToQueuePicker = false
    @State private var isEditingQueueOrder = false
    @State private var showFullscreenFFmpegVideo = false
    @State private var editingInfoItem: MediaItem?
    @State private var verifyArtistItem: MediaItem?
    @State private var lyricsTarget: GeniusLyricsTarget?
    @State private var collabSendTarget: CollabSongNoteTarget?
    @State private var collabAddSongsGroupID: IdentifiableUUID?
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var partyService = PartyQueueService.shared
    @State private var showJamSheet = false

    private let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let sleepPresets = [5, 10, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Group {
                if let item = mediaManager.currentItem {
                    if displayMode == .player {
                        ScrollView {
                            VStack(spacing: 24) {
                                if item.isVideo {
                                    videoPlayerSection
                                } else {
                                    audioArtworkSection(item: item)
                                }

                                titleAndMetadata(item: item)

                                if sleepTimer.isActive {
                                    activeSleepTimerBadge
                                }

                                if mediaManager.convertingItemID == item.id {
                                    conversionBanner
                                }

                                if !item.isVideo || mediaManager.isUsingFFmpegBackend {
                                    scrubberSection
                                }

                                transportControls(item: item)

                                appleMusicBottomDock(item: item, darkGlass: false)

                                secondaryActions(item: item)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                        }
                        .applyAppTheme()
                    } else {
                        appleMusicFocusedModeView(item: item)
                    }
                } else {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "play.slash",
                        description: Text("Select an audio or video file from your library.")
                    )
                    .applyAppTheme()
                }
            }
            .onChange(of: mediaManager.currentTime) { _, newTime in
                if !isEditingScrubber {
                    scrubPosition = newTime
                }
            }
            .onChange(of: mediaManager.currentItem?.relativePath) { _, _ in
                if let current = mediaManager.currentItem {
                    lyricsService.loadLyricsIfNeeded(for: current)
                }
            }
            .onAppear {
                scrubPosition = mediaManager.currentTime
                if let current = mediaManager.currentItem {
                    lyricsService.loadLyricsIfNeeded(for: current)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(displayMode == .player ? .visible : .hidden, for: .navigationBar)
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
                Button("Create & Add") {
                    if let current = mediaManager.currentItem, !current.relativePath.hasPrefix("__remote__/") {
                        mediaManager.createPlaylist(name: newPlaylistName, initialPaths: [current.relativePath])
                    }
                    newPlaylistName = ""
                }
            } message: {
                Text("Enter a name for your new offline playlist.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text(mediaManager.currentItem?.isVideo == true ? "Video Player" : "Now Playing")
                        .font(.subheadline.weight(.semibold))
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let item = mediaManager.currentItem {
                        Button {
                            AppHaptics.selection()
                            lyricsService.loadLyricsIfNeeded(for: item)
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                displayMode = .lyrics
                            }
                        } label: {
                            Image(systemName: displayMode == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                        }
                        .accessibilityLabel("Synced Lyrics")
                    }

                    Button {
                        AppHaptics.selection()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            displayMode = .messages
                        }
                    } label: {
                        Image(systemName: displayMode == .messages ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                            .foregroundStyle(groupService.totalMessagesCount > 0 ? Color.accentColor : .primary)
                    }
                    .accessibilityLabel("Collab Playlist Messages")

                    Button {
                        AppHaptics.selection()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            displayMode = .queue
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(mediaManager.upNextItems.isEmpty ? .primary : Color.accentColor)
                    }
                    .accessibilityLabel("Playing Next Queue")

                    Button {
                        AppHaptics.selection()
                        showJamSheet = true
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(partyService.activeJamSession != nil ? Color.green : .primary)
                    }
                    .accessibilityLabel("Live Jam")

                    sleepTimerMenu

                    if let item = mediaManager.currentItem {
                        AirPlayRoutePickerView(prioritizesVideoDevices: item.isVideo)
                            .frame(width: 28, height: 28)
                    }
                }
            }
            .sheet(isPresented: $showEqualizerSheet) {
                EqualizerView()
            }
            .sheet(isPresented: $showJamSheet) {
                JamSessionSheet(showPlayerSheet: .constant(true))
            }
            .sheet(isPresented: $showQueueSheet) {
                UserQueueSheetView()
            }
            .sheet(isPresented: $showAddToQueuePicker) {
                QueueSongPickerSheet()
            }
            .sheet(item: $editingInfoItem) { item in
                EditTrackInfoSheet(item: item)
            }
            .sheet(item: $verifyArtistItem) { item in
                VerifyTrackArtistSheet(item: item)
            }
            .sheet(item: $lyricsTarget) { target in
                GeniusLyricsSheetView(target: target)
            }
            .sheet(item: $collabSendTarget) { target in
                CollabSongNoteComposerSheet(target: target)
            }
            .sheet(item: $collabAddSongsGroupID) { selection in
                GroupAddSongsSheet(groupID: selection.id)
            }
            .fullScreenCover(isPresented: $showFullscreenFFmpegVideo) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    FFmpegVideoPlayerView(renderView: mediaManager.ffmpegPlayer?.view)
                        .ignoresSafeArea()
                    Button {
                        showFullscreenFFmpegVideo = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding()
                    }
                }
            }
            .alert("Custom Sleep Timer", isPresented: $showCustomSleepAlert) {
                TextField("Minutes (e.g. 20)", text: $customSleepMinutes)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {
                    customSleepMinutes = ""
                }
                Button("Start") {
                    let trimmed = customSleepMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let mins = Int(trimmed), mins > 0 {
                        startSleepTimer(minutes: mins)
                    }
                    customSleepMinutes = ""
                }
            } message: {
                Text("Pause playback automatically after how many minutes?")
            }
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            ForEach(sleepPresets, id: \.self) { minutes in
                Button {
                    startSleepTimer(minutes: minutes)
                } label: {
                    Label("\(minutes) minutes", systemImage: "moon")
                }
            }

            Button {
                customSleepMinutes = ""
                showCustomSleepAlert = true
            } label: {
                Label("Custom...", systemImage: "slider.horizontal.3")
            }

            if sleepTimer.isActive {
                Divider()
                Button(role: .destructive) {
                    sleepTimer.cancelTimer()
                } label: {
                    Label("Turn Off Timer (\(sleepTimer.formattedRemaining))", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(sleepTimer.isActive ? Color.accentColor : .primary)
        }
    }

    private var activeSleepTimerBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(Color.accentColor)
            Text("Sleep timer: \(sleepTimer.formattedRemaining)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Button {
                sleepTimer.cancelTimer()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    private func startSleepTimer(minutes: Int) {
        sleepTimer.startTimer(minutes: minutes) {
            mediaManager.pause()
            mediaManager.statusMessage = "Sleep timer paused playback"
        }
        mediaManager.statusMessage = "Sleep timer set for \(minutes)m"
    }

    @ViewBuilder
    private var videoPlayerSection: some View {
        if mediaManager.isUsingFFmpegBackend {
            ZStack(alignment: .bottomTrailing) {
                FFmpegVideoPlayerView(renderView: mediaManager.ffmpegPlayer?.view)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)

                HStack(spacing: 8) {
                    if let pip = mediaManager.ffmpegPlayer?.pipController,
                       AVPictureInPictureController.isPictureInPictureSupported() {
                        Button {
                            if pip.isPictureInPictureActive {
                                pip.stopPictureInPicture()
                            } else {
                                pip.startPictureInPicture()
                            }
                        } label: {
                            Image(systemName: "pip.enter")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }

                    Button {
                        showFullscreenFFmpegVideo = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                }
                .padding(10)
            }
        } else if let player = mediaManager.player {
            PiPVideoPlayer(player: player)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(height: 240)
        }
    }

    private func audioArtworkSection(item: MediaItem) -> some View {
        MediaArtworkView(
            item: item,
            image: mediaManager.thumbnails[item.relativePath],
            cornerRadius: 24,
            iconSize: 72
        )
        .frame(width: 260, height: 260)
        .scaleEffect(mediaManager.isPlaying ? 1.0 : 0.94)
        .shadow(color: .black.opacity(mediaManager.isPlaying ? 0.25 : 0.12), radius: 20, y: 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: mediaManager.isPlaying)
        .padding(.top, 8)
    }

    private func titleAndMetadata(item: MediaItem) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(item.displayTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Button {
                    mediaManager.toggleFavorite(item)
                } label: {
                    Image(systemName: mediaManager.isFavorite(item) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(mediaManager.isFavorite(item) ? .pink : .secondary)
                }
                .buttonStyle(.plain)
            }

            if !item.relativePath.hasPrefix("__remote__/") {
                let verified = mediaManager.isArtistVerified(for: item)
                let artistLabel = item.artist ?? "Confirm Artist for Wrapped"
                Button {
                    verifyArtistItem = item
                } label: {
                    HStack(spacing: 5) {
                        Text(artistLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: verified ? "checkmark.seal.fill" : "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(verified ? .green : .orange)
                    }
                }
                .buttonStyle(.plain)
            } else if let artist = item.artist, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let album = item.album, !album.isEmpty {
                Text(album)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(item.isHLS ? "HLS" : item.fileExtension.uppercased())
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))

                Text(item.formattedFileSize)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if mediaManager.duration > 0 {
                    Text("• \(MediaTimeFormatter.format(mediaManager.duration))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var conversionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Converting to MP4...", systemImage: "film.stack")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(mediaManager.conversionProgress * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: mediaManager.conversionProgress)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var scrubberSection: some View {
        let total = max(mediaManager.duration, 1)
        let displayedTime = isEditingScrubber ? scrubPosition : mediaManager.currentTime
        let remaining = max(mediaManager.duration - displayedTime, 0)

        return VStack(spacing: 6) {
            Slider(
                value: $scrubPosition,
                in: 0...total
            ) { editing in
                isEditingScrubber = editing
                if editing {
                    mediaManager.beginScrubbing()
                } else {
                    mediaManager.endScrubbing(at: scrubPosition)
                }
            }
            .tint(.accentColor)

            HStack {
                Text(MediaTimeFormatter.format(displayedTime))
                Spacer()
                Text("-\(MediaTimeFormatter.format(remaining))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func transportControls(item: MediaItem) -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 26) {
                Button {
                    mediaManager.isShuffleEnabled.toggle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(mediaManager.isShuffleEnabled ? Color.accentColor : .secondary)
                }

                Button {
                    mediaManager.playPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }

                Button {
                    mediaManager.togglePlayPause()
                } label: {
                    Image(systemName: mediaManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(Color.accentColor)
                }

                Button {
                    mediaManager.playNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }

                Button {
                    mediaManager.cycleRepeatMode()
                } label: {
                    Image(systemName: mediaManager.repeatMode.systemImage)
                        .font(.title3)
                        .foregroundStyle(mediaManager.repeatMode == .off ? .secondary : Color.accentColor)
                }
                .accessibilityLabel(mediaManager.repeatMode.label)
            }
            .foregroundStyle(.primary)

            HStack(spacing: 18) {
                Button {
                    mediaManager.skip(by: -30)
                } label: {
                    Label("30s", systemImage: "gobackward.30")
                        .font(.subheadline.weight(.medium))
                }

                Menu {
                    ForEach(speedOptions, id: \.self) { rate in
                        Button {
                            mediaManager.setPlaybackRate(rate)
                        } label: {
                            HStack {
                                Text(rate == 1.0 ? "1x (Normal)" : "\(rate.formatted())x")
                                if abs(mediaManager.playbackRate - rate) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(mediaManager.playbackRate.formatted())x")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }

                Button {
                    showEqualizerSheet = true
                } label: {
                    Label("EQ", systemImage: "slider.vertical.3")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(mediaManager.equalizerPlayer.isEnabled && mediaManager.equalizerPlayer.selectedPreset != .flat
                                      ? Color.accentColor.opacity(0.18)
                                      : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(mediaManager.equalizerPlayer.isEnabled && mediaManager.equalizerPlayer.selectedPreset != .flat
                                         ? Color.accentColor
                                         : .primary)
                }

                Button {
                    mediaManager.skip(by: 30)
                } label: {
                    Label("30s", systemImage: "goforward.30")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private func secondaryActions(item: MediaItem) -> some View {
        let isRemote = item.relativePath.hasPrefix("__remote__/")
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    AppHaptics.selection()
                    lyricsService.loadLyricsIfNeeded(for: item)
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        displayMode = .lyrics
                    }
                } label: {
                    Label("Apple-Style Lyrics", systemImage: "quote.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                }

                Button {
                    showAddToQueuePicker = true
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if isRemote {
                Button {
                    mediaManager.saveCurrentRemoteStreamOffline(using: downloader)
                } label: {
                    Label("Cache Stream Offline to Files", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                }
            }

            if item.isVideo {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await mediaManager.saveVideoScreenshot(from: item, at: mediaManager.currentTime)
                        }
                    } label: {
                        Label("Screenshot", systemImage: "camera.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if !item.isHLS && !isRemote {
                        Button {
                            Task {
                                await mediaManager.extractAudioToM4A(item: item)
                            }
                        } label: {
                            Label("Extract Audio", systemImage: "music.note")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(mediaManager.convertingItemID != nil)
                    }
                }
            }

            if !isRemote {
                HStack(spacing: 10) {
                    Button {
                        editingInfoItem = item
                    } label: {
                        Label("Edit Info", systemImage: "pencil.and.outline")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if !item.isHLS {
                        Button {
                            Task {
                                await mediaManager.convertToMP4(item: item)
                            }
                        } label: {
                            Label("To MP4", systemImage: "film.stack")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(mediaManager.convertingItemID != nil)
                    }

                    ShareLink(item: item.fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                Menu {
                    Button {
                        newPlaylistName = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Label("New Playlist...", systemImage: "plus")
                    }

                    if !mediaManager.playlists.isEmpty {
                        Divider()
                        ForEach(mediaManager.playlists) { playlist in
                            let isInPlaylist = mediaManager.playlistContains(item, in: playlist)
                            Button {
                                if isInPlaylist {
                                    mediaManager.remove(item, from: playlist)
                                } else {
                                    mediaManager.add(item, to: playlist)
                                }
                            } label: {
                                Label(
                                    playlist.name,
                                    systemImage: isInPlaylist ? "checkmark" : "plus"
                                )
                            }
                        }
                    }

                    if !GroupPlaylistService.shared.groups.isEmpty {
                        Divider()
                        ForEach(GroupPlaylistService.shared.groups) { group in
                            Button {
                                collabSendTarget = CollabSongNoteTarget(
                                    groupID: group.id,
                                    songTitle: item.displayTitle,
                                    songArtist: item.artist ?? "",
                                    localItem: item,
                                    youtubeVideoID: MediaManager.shared.sourceVideoID(for: item),
                                    durationSeconds: item.durationSeconds
                                )
                            } label: {
                                Label("Send to Group: \(group.name)", systemImage: "person.2.wave.2")
                            }
                        }
                    }

                    if !PartyQueueService.shared.parties.isEmpty {
                        Divider()
                        ForEach(PartyQueueService.shared.parties) { party in
                            Button {
                                PartyQueueService.shared.queueLocalItem(item, to: party.id)
                            } label: {
                                Label("Queue in Party: \(party.name)", systemImage: "radio")
                            }
                        }
                    }
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.top, 4)
    }

    // MARK: - 1:1 Apple Music Focused Lyrics, Collab Messages & Playing Next Surface

    @ViewBuilder
    private func appleMusicFocusedModeView(item: MediaItem) -> some View {
        ZStack {
            AppleMusicLivingBackground(
                artwork: mediaManager.thumbnails[item.relativePath],
                artworkKey: item.relativePath,
                isPlaying: mediaManager.isPlaying
            )

            VStack(spacing: 0) {
                compactAppleMusicHeader(item: item)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                switch displayMode {
                case .lyrics:
                    AppleMusicLyricsView(
                        item: item,
                        onOpenGeniusWeb: { t, a in
                            lyricsTarget = GeniusLyricsTarget(rawTitle: t, rawArtist: a)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .messages:
                    CollabMessagesView(
                        isEmbeddedDarkGlass: true,
                        onAddSongRequested: { groupID in
                            collabAddSongsGroupID = IdentifiableUUID(id: groupID)
                        },
                        onDismissParentForVideo: {
                            dismiss()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .queue:
                    UserQueueContentView(
                        isEmbeddedDarkGlass: true,
                        onAddSongs: { showAddToQueuePicker = true }
                    )
                    .environment(\.editMode, .constant(isEditingQueueOrder ? .active : .inactive))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .player:
                    EmptyView()
                }

                compactAppleMusicFooter(item: item)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func compactAppleMusicHeader(item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    displayMode = .player
                }
            } label: {
                MediaArtworkView(
                    item: item,
                    image: mediaManager.thumbnails[item.relativePath],
                    cornerRadius: 10,
                    iconSize: 20
                )
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                let subtitle = [item.artist ?? "Unknown Artist", item.album]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                mediaManager.toggleFavorite(item)
            } label: {
                Image(systemName: mediaManager.isFavorite(item) ? "heart.circle.fill" : "heart.circle")
                    .font(.title2)
                    .foregroundStyle(mediaManager.isFavorite(item) ? .pink : .white.opacity(0.75))
            }
            .buttonStyle(.plain)

            if displayMode == .queue {
                Button {
                    isEditingQueueOrder.toggle()
                } label: {
                    Text(isEditingQueueOrder ? "Done" : "Edit")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    Button {
                        lyricsTarget = GeniusLyricsTarget(
                            rawTitle: item.displayTitle,
                            rawArtist: item.artist ?? ""
                        )
                    } label: {
                        Label("Open on Genius Web", systemImage: "safari")
                    }

                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                            displayMode = .player
                        }
                    } label: {
                        Label("Back to Artwork", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
    }

    private func compactAppleMusicFooter(item: MediaItem) -> some View {
        let total = max(mediaManager.duration, 1)
        let displayedTime = isEditingScrubber ? scrubPosition : mediaManager.currentTime
        let remaining = max(mediaManager.duration - displayedTime, 0)

        return VStack(spacing: 14) {
            VStack(spacing: 4) {
                Slider(
                    value: $scrubPosition,
                    in: 0...total
                ) { editing in
                    isEditingScrubber = editing
                    if editing {
                        mediaManager.beginScrubbing()
                    } else {
                        mediaManager.endScrubbing(at: scrubPosition)
                    }
                }
                .tint(.white)

                HStack {
                    Text(MediaTimeFormatter.format(displayedTime))
                    Spacer()
                    Text("-\(MediaTimeFormatter.format(remaining))")
                }
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
            }

            HStack(spacing: 42) {
                Button {
                    mediaManager.playPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button {
                    mediaManager.togglePlayPause()
                } label: {
                    Image(systemName: mediaManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }

                Button {
                    mediaManager.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
            }
            .foregroundStyle(.white)

            appleMusicBottomDock(item: item, darkGlass: true)
        }
    }

    private func appleMusicBottomDock(item: MediaItem, darkGlass: Bool) -> some View {
        let inactiveFill = darkGlass ? Color.white.opacity(0.12) : Color.secondary.opacity(0.14)
        let activeFill = darkGlass ? Color.white : Color.accentColor
        let inactiveText = darkGlass ? Color.white.opacity(0.84) : Color.primary
        let activeText = darkGlass ? Color.black : Color.white
        let messageCount = groupService.defaultMessageGroup?.messages.count ?? groupService.totalMessagesCount

        return HStack {
            Button {
                AppHaptics.selection()
                lyricsService.loadLyricsIfNeeded(for: item)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    displayMode = (displayMode == .lyrics) ? .player : .lyrics
                }
            } label: {
                let active = displayMode == .lyrics
                Image(systemName: active ? "quote.bubble.fill" : "quote.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(active ? activeText : inactiveText)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(active ? activeFill : inactiveFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Synced Lyrics")

            Spacer()

            Button {
                AppHaptics.selection()
                showJamSheet = true
            } label: {
                let jamActive = partyService.activeJamSession != nil
                let listenerCount = partyService.activeJamSession?.activeParticipantsList.count ?? 0
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                    Text(jamActive ? (listenerCount > 1 ? "\(listenerCount)" : "Jam") : "Jam")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                }
                .foregroundStyle(jamActive ? .white : inactiveText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(jamActive ? Color.green : inactiveFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start or Open Jam")

            Spacer()

            AirPlayRoutePickerView(prioritizesVideoDevices: item.isVideo)
                .frame(width: 24, height: 24)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(inactiveFill))

            Spacer()

            Button {
                AppHaptics.selection()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    displayMode = (displayMode == .messages) ? .player : .messages
                }
            } label: {
                let active = displayMode == .messages
                HStack(spacing: 5) {
                    Image(systemName: active ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.subheadline.weight(.semibold))
                    if messageCount > 0 {
                        Text("\(messageCount)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(active ? activeText : inactiveText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(active ? activeFill : inactiveFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collab Playlist Messages")

            Spacer()

            Button {
                AppHaptics.selection()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    displayMode = (displayMode == .queue) ? .player : .queue
                }
            } label: {
                let active = displayMode == .queue
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                    if !mediaManager.upNextPaths.isEmpty {
                        Text("\(mediaManager.upNextPaths.count)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(active ? activeText : inactiveText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(active ? activeFill : inactiveFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playing Next Queue")
        }
    }
}
