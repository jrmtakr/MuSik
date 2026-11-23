import SwiftUI

struct MediaRowView: View {
    @Environment(MediaManager.self) private var mediaManager

    let item: MediaItem
    let onPlay: () -> Void
    let onQuickLook: () -> Void
    let onRename: () -> Void
    var onEditInfo: (() -> Void)? = nil
    var onMove: (() -> Void)? = nil

    private var isCurrent: Bool {
        mediaManager.currentItem?.relativePath == item.relativePath
    }

    private var isConvertingThis: Bool {
        mediaManager.convertingItemID == item.id
    }

    private var isFavorite: Bool {
        mediaManager.isFavorite(item)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    ZStack {
                        MediaArtworkView(
                            item: item,
                            image: mediaManager.thumbnails[item.relativePath],
                            cornerRadius: 10,
                            iconSize: 20
                        )
                        .frame(width: 54, height: 54)

                        if isCurrent {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.black.opacity(0.42))
                                .frame(width: 54, height: 54)
                            Image(systemName: mediaManager.isPlaying ? "waveform" : "pause.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: mediaManager.isPlaying)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(item.displayTitle)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                .lineLimit(1)

                            if isFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                            }
                        }

                        if let artist = item.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            Text(item.isHLS ? "HLS" : item.fileExtension.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(item.isVideo ? Color.purple.opacity(0.16) : Color.accentColor.opacity(0.16))
                                )
                                .foregroundStyle(item.isVideo ? .purple : Color.accentColor)

                            if let durationText = item.formattedDuration {
                                Text(durationText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            Text("• \(item.formattedFileSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if isConvertingThis {
                            HStack(spacing: 8) {
                                ProgressView(value: mediaManager.conversionProgress)
                                    .progressViewStyle(.linear)
                                Text("\(Int(mediaManager.conversionProgress * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    onPlay()
                } label: {
                    Label(isCurrent && mediaManager.isPlaying ? "Pause" : "Play",
                          systemImage: isCurrent && mediaManager.isPlaying ? "pause.fill" : "play.fill")
                }

                Button {
                    mediaManager.addToNextPlay(item)
                } label: {
                    Label("Add to Next Play", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    mediaManager.addToQueue(item)
                } label: {
                    Label("Add to Up Next", systemImage: "text.append")
                }

                Button {
                    mediaManager.toggleFavorite(item)
                } label: {
                    Label(isFavorite ? "Remove Favorite" : "Favorite",
                          systemImage: isFavorite ? "heart.slash" : "heart")
                }

                Menu {
                    Button {
                        mediaManager.newPlaylistTargetItem = item
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
                                GroupPlaylistService.shared.sendLocalItem(item, to: group.id)
                            } label: {
                                Label("Send to Group: \(group.name)", systemImage: "person.2.wave.2")
                            }
                        }
                    }
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }

                Divider()

                if let onEditInfo {
                    Button(action: onEditInfo) {
                        Label("Edit Info & Cover", systemImage: "music.note.list")
                    }
                }

                if let onMove {
                    Button(action: onMove) {
                        Label("Move to Folder", systemImage: "folder")
                    }
                }

                if !item.isHLS {
                    if item.isVideo {
                        Button {
                            Task {
                                await mediaManager.extractAudioToM4A(item: item)
                            }
                        } label: {
                            Label("Extract Audio (.m4a)", systemImage: "music.note")
                        }
                        .disabled(mediaManager.convertingItemID != nil)
                    }

                    Button {
                        Task {
                            await mediaManager.convertToMP4(item: item)
                        }
                    } label: {
                        Label("Convert to MP4", systemImage: "film.stack")
                    }
                    .disabled(mediaManager.convertingItemID != nil)
                }

                Button {
                    onQuickLook()
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }

                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                ShareLink(item: item.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive) {
                    mediaManager.delete(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
    }
}

struct LocalFileRowView: View {
    @Environment(MediaManager.self) private var mediaManager

    let file: LocalFile
    let onPreview: () -> Void
    let onRename: () -> Void
    var onMove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onPreview) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.teal.opacity(0.16))
                            .frame(width: 54, height: 54)
                        Image(systemName: file.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.teal)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(file.fileExtension.isEmpty ? "FILE" : file.fileExtension.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.teal.opacity(0.16)))
                                .foregroundStyle(.teal)

                            Text("• \(file.formattedFileSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    onPreview()
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }

                if let onMove {
                    Button(action: onMove) {
                        Label("Move to Folder", systemImage: "folder")
                    }
                }

                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                ShareLink(item: file.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive) {
                    mediaManager.deleteOtherFile(file)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
    }
}
