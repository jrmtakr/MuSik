import AVKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(SleepTimerManager.self) private var sleepTimer
    @Environment(\.dismiss) private var dismiss

    @State private var scrubPosition: Double = 0
    @State private var isEditingScrubber = false
    @State private var showCustomSleepAlert = false
    @State private var customSleepMinutes = ""
    @State private var showEqualizerSheet = false
    @State private var showQueueSheet = false
    @State private var editingInfoItem: MediaItem?

    private let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let sleepPresets = [5, 10, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Group {
                if let item = mediaManager.currentItem {
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

                            if !item.isVideo {
                                scrubberSection
                            }

                            transportControls(item: item)

                            secondaryActions(item: item)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: mediaManager.currentTime) { _, newTime in
                        if !isEditingScrubber {
                            scrubPosition = newTime
                        }
                    }
                    .onAppear {
                        scrubPosition = mediaManager.currentTime
                    }
                } else {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "play.slash",
                        description: Text("Select an audio or video file from your library.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
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
                    Button {
                        showQueueSheet = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(mediaManager.upNextItems.isEmpty ? .primary : Color.accentColor)
                    }

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
            .sheet(isPresented: $showQueueSheet) {
                UpNextQueueSheet()
            }
            .sheet(item: $editingInfoItem) { item in
                EditTrackInfoSheet(item: item)
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
        if let player = mediaManager.player {
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

            if let artist = item.artist, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
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
                    mediaManager.skip(by: -15)
                } label: {
                    Label("15s", systemImage: "gobackward.15")
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
                    mediaManager.skip(by: 15)
                } label: {
                    Label("15s", systemImage: "goforward.15")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private func secondaryActions(item: MediaItem) -> some View {
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
        .foregroundStyle(.primary)
        .padding(.top, 4)
    }
}

private struct UpNextQueueSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if mediaManager.upNextItems.isEmpty {
                    ContentUnavailableView(
                        "Up Next is Empty",
                        systemImage: "list.bullet",
                        description: Text("Use \"Add to Next Play\" or \"Add to Up Next\" from any track menu to queue songs.")
                    )
                } else {
                    List {
                        ForEach(Array(mediaManager.upNextItems.enumerated()), id: \.offset) { idx, item in
                            Button {
                                mediaManager.removeFromUpNext(at: IndexSet(integer: idx))
                                mediaManager.play(item, inPlaylist: mediaManager.activePlaylistID)
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
                                        Text(item.artist ?? item.fileExtension.uppercased())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            mediaManager.removeFromUpNext(at: offsets)
                        }
                        .onMove { source, destination in
                            mediaManager.moveUpNext(from: source, to: destination)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !mediaManager.upNextItems.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !mediaManager.upNextItems.isEmpty {
                        Button("Clear", role: .destructive) {
                            mediaManager.clearUpNext()
                        }
                    }
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
