import SwiftUI

struct MiniPlayerBar: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(SleepTimerManager.self) private var sleepTimer
    let onExpand: () -> Void
    var onQueueTap: (() -> Void)? = nil

    private var progress: Double {
        guard mediaManager.duration > 0 else { return 0 }
        return min(max(mediaManager.currentTime / mediaManager.duration, 0), 1)
    }

    var body: some View {
        if let item = mediaManager.currentItem {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)

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
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(item.artist ?? (item.isVideo ? "Video" : "Audio"))
                                .lineLimit(1)
                            Text("•")
                            Text("\(MediaTimeFormatter.format(mediaManager.currentTime)) / \(MediaTimeFormatter.format(mediaManager.duration))")
                                .monospacedDigit()
                            if sleepTimer.isActive {
                                Text("•")
                                Image(systemName: "moon.zzz.fill")
                                Text(sleepTimer.formattedRemaining)
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        mediaManager.togglePlayPause()
                    } label: {
                        Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 34, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        mediaManager.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .frame(width: 30, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if let onQueueTap {
                        Button {
                            onQueueTap()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "list.bullet")
                                    .font(.body)
                                    .foregroundStyle(mediaManager.upNextPaths.isEmpty ? Color.primary : Color.accentColor)
                                    .frame(width: 32, height: 38)
                                if !mediaManager.upNextPaths.isEmpty {
                                    Text("\(min(mediaManager.upNextPaths.count, 99))")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor, in: Capsule())
                                        .offset(x: 4, y: 2)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Playing Next Queue")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
        } else if !mediaManager.upNextItems.isEmpty, let onQueueTap {
            let queued = mediaManager.upNextItems
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(queued.count) \(queued.count == 1 ? "Song" : "Songs") in Queue")
                        .font(.subheadline.weight(.semibold))
                    if let first = queued.first {
                        Text("Next: \(first.displayTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    mediaManager.playQueuedItem(at: 0)
                    if mediaManager.currentItem?.isVideo == true {
                        onExpand()
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.body)
                        .padding(8)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    onQueueTap()
                } label: {
                    Text("Queue")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onTapGesture(perform: onQueueTap)
        }
    }
}
