import SwiftUI

struct MiniPlayerBar: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(SleepTimerManager.self) private var sleepTimer
    let onExpand: () -> Void

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
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        mediaManager.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .frame(width: 34, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        }
    }
}
