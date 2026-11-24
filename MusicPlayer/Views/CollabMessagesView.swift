import SwiftUI

private enum CollabComposerMediaTab: String, CaseIterable {
    case stickers = "TikTok Stickers"
    case gifs = "TikTok GIFs"
}

struct CollabMessagesView: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(MediaManager.self) private var mediaManager
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(TikTokMediaService.self) private var tiktokMedia

    let isEmbeddedDarkGlass: Bool
    var initialGroupID: UUID? = nil
    var onAddSongRequested: ((UUID) -> Void)? = nil
    var onDismissParentForVideo: (() -> Void)? = nil

    @State private var selectedGroupID: UUID?
    @State private var draftNote: String = ""
    @State private var selectedSticker: String? = nil
    @State private var selectedGifURL: String? = nil
    @State private var mediaTab: CollabComposerMediaTab = .stickers
    @State private var showTikTokSearch: Bool = false
    @State private var tiktokSearchQuery: String = ""
    @State private var attachCurrentTrack: Bool = false
    @State private var showCreateSheet = false
    @State private var showJoinSheet = false

    private var activeGroup: GroupPlaylist? {
        if let selectedGroupID, let match = groupService.groups.first(where: { $0.id == selectedGroupID }) {
            return match
        }
        if let initialGroupID, let match = groupService.groups.first(where: { $0.id == initialGroupID }) {
            return match
        }
        return groupService.defaultMessageGroup
    }

    var body: some View {
        VStack(spacing: 0) {
            if groupService.groups.isEmpty {
                emptyNoGroupsView
            } else {
                groupSelectorBar
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                if let group = activeGroup {
                    messagesFeed(for: group)
                    Divider()
                        .overlay(isEmbeddedDarkGlass ? Color.white.opacity(0.14) : Color.secondary.opacity(0.2))
                    quickMessageComposer(for: group)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                }
            }
        }
        .onAppear {
            if selectedGroupID == nil {
                selectedGroupID = initialGroupID ?? groupService.defaultMessageGroup?.id
            }
            if let gid = selectedGroupID {
                groupService.startObservingGroup(id: gid)
            }
            tiktokMedia.refreshIfDue()
        }
        .onChange(of: selectedGroupID) { _, newID in
            if let newID {
                groupService.startObservingGroup(id: newID)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateGroupPlaylistSheet { newID in
                selectedGroupID = newID
            }
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinGroupPlaylistSheet { joinedID in
                selectedGroupID = joinedID
            }
        }
    }

    private var emptyNoGroupsView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 42))
                .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.75) : Color.accentColor)

            Text("Collab Playlist Messages")
                .font(.title3.weight(.bold))
                .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)

            Text("Create or join a Collab Playlist to share songs with custom notes, messages, and stickers.")
                .font(.subheadline)
                .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.68) : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Collab", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            isEmbeddedDarkGlass ? Color.white : Color.accentColor,
                            in: Capsule()
                        )
                        .foregroundStyle(isEmbeddedDarkGlass ? .black : .white)
                }
                .buttonStyle(.plain)

                Button {
                    showJoinSheet = true
                } label: {
                    Label("Join with Code", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            isEmbeddedDarkGlass ? Color.white.opacity(0.16) : Color.secondary.opacity(0.16),
                            in: Capsule()
                        )
                        .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupSelectorBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groupService.groups) { group in
                        let isSelected = activeGroup?.id == group.id
                        Button {
                            AppHaptics.selection()
                            selectedGroupID = group.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(groupService.liveConnectedGroupID == group.id ? Color.green : Color.orange.opacity(0.8))
                                    .frame(width: 7, height: 7)
                                Text(group.name)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                if !group.messages.isEmpty {
                                    Text("\(group.messages.count)")
                                        .font(.caption2.weight(.bold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            (isSelected
                                             ? (isEmbeddedDarkGlass ? Color.black.opacity(0.16) : Color.white.opacity(0.24))
                                             : (isEmbeddedDarkGlass ? Color.white.opacity(0.16) : Color.secondary.opacity(0.18))),
                                            in: Capsule()
                                        )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? (isEmbeddedDarkGlass ? Color.white : Color.accentColor)
                                        : (isEmbeddedDarkGlass ? Color.white.opacity(0.12) : Color.secondary.opacity(0.14))
                                )
                            )
                            .foregroundStyle(
                                isSelected
                                    ? (isEmbeddedDarkGlass ? Color.black : Color.white)
                                    : (isEmbeddedDarkGlass ? Color.white.opacity(0.88) : Color.primary)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let group = activeGroup, let onAddSongRequested {
                Button {
                    onAddSongRequested(group.id)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Song with Note or Sticker")
            }
        }
    }

    private func messagesFeed(for group: GroupPlaylist) -> some View {
        let msgs = group.sortedMessages
        return Group {
            if msgs.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text("No Notes or Stickers Yet")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                    Text("When you add a song to \"\(group.name)\", you can attach an optional note, message, or sticker—or drop one below.")
                        .font(.caption)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.66) : .secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(msgs) { msg in
                                messageCard(msg, in: group)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        if let lastID = msgs.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                    .onChange(of: msgs.count) { _, _ in
                        if let lastID = msgs.last?.id {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func messageCard(_ msg: GroupPlaylistMessage, in group: GroupPlaylist) -> some View {
        let matchedTrack = msg.trackID.flatMap { tid in group.tracks.first(where: { $0.id == tid }) }
        let songTitle = matchedTrack?.title ?? msg.trackTitle
        let songArtist = matchedTrack?.artist ?? msg.trackArtist
        let relativeTime = Date(timeIntervalSince1970: msg.timestamp)
            .formatted(.relative(presentation: .named))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(msg.senderName.prefix(1)).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isEmbeddedDarkGlass ? .black : .white)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(isEmbeddedDarkGlass ? Color.white.opacity(0.88) : Color.accentColor)
                    )

                Text(msg.senderName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)

                Spacer()

                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.55) : .secondary)
            }

            if let songTitle, !songTitle.isEmpty {
                Button {
                    if let matchedTrack {
                        Task {
                            let ok = await groupService.playTrack(
                                matchedTrack,
                                in: group.id,
                                downloader: downloader,
                                saveOfflineOnly: false
                            )
                            if ok && mediaManager.currentItem?.isVideo == true {
                                onDismissParentForVideo?()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: matchedTrack != nil ? "play.circle.fill" : "music.note")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isEmbeddedDarkGlass ? .white : Color.accentColor)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(songTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                                .lineLimit(1)
                            if let songArtist, !songArtist.isEmpty {
                                Text(songArtist)
                                    .font(.caption2)
                                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.68) : .secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isEmbeddedDarkGlass ? Color.white.opacity(0.10) : Color.secondary.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
                .disabled(matchedTrack == nil)
            }

            if let gifStr = msg.gifURL, !gifStr.isEmpty, let gifURL = URL(string: gifStr) {
                AnimatedTikTokImageView(url: gifURL, contentMode: .scaleAspectFill)
                    .frame(maxWidth: 230, minHeight: 118, maxHeight: 164)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isEmbeddedDarkGlass ? Color.white.opacity(0.16) : Color.secondary.opacity(0.16), lineWidth: 1)
                    )
            }

            HStack(alignment: .center, spacing: 10) {
                if let sticker = msg.sticker, !sticker.isEmpty {
                    TikTokStickerView(rawSticker: sticker, size: 48, showCodeBadge: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isEmbeddedDarkGlass ? Color.white.opacity(0.08) : Color.secondary.opacity(0.08))
                        )
                }

                if let text = msg.text, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.95) : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isEmbeddedDarkGlass ? Color.white.opacity(0.11) : Color.secondary.opacity(0.10))
        )
    }

    private func quickMessageComposer(for group: GroupPlaylist) -> some View {
        VStack(spacing: 8) {
            // TikTok Stickers / GIFs switcher + live refresh bar
            HStack(spacing: 7) {
                ForEach(CollabComposerMediaTab.allCases, id: \.rawValue) { tab in
                    let isTab = mediaTab == tab
                    Button {
                        AppHaptics.selection()
                        mediaTab = tab
                    } label: {
                        Text(tab == .stickers ? "TikTok Stickers" : "TikTok GIFs")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    isTab
                                        ? (isEmbeddedDarkGlass ? Color.white : Color.accentColor)
                                        : (isEmbeddedDarkGlass ? Color.white.opacity(0.10) : Color.secondary.opacity(0.12))
                                )
                            )
                            .foregroundStyle(
                                isTab
                                    ? (isEmbeddedDarkGlass ? Color.black : Color.white)
                                    : (isEmbeddedDarkGlass ? Color.white.opacity(0.82) : Color.primary)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if let status = tiktokMedia.statusText, !tiktokMedia.isRefreshing {
                    Text(status)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.55) : .secondary)
                        .lineLimit(1)
                }

                Button {
                    AppHaptics.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTikTokSearch.toggle()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.85) : .primary)
                        .padding(6)
                        .background(
                            Circle().fill(isEmbeddedDarkGlass ? Color.white.opacity(0.12) : Color.secondary.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search TikTok Stickers and GIFs")

                Button {
                    AppHaptics.selection()
                    tiktokMedia.refreshCatalog(query: tiktokSearchQuery, force: true)
                } label: {
                    Group {
                        if tiktokMedia.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(isEmbeddedDarkGlass ? .white : Color.accentColor)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(0.9) : Color.accentColor)
                    .padding(6)
                    .background(
                        Circle().fill(isEmbeddedDarkGlass ? Color.white.opacity(0.12) : Color.secondary.opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
                .disabled(tiktokMedia.isRefreshing)
                .accessibilityLabel("Refresh TikTok Stickers and GIFs")
            }

            if showTikTokSearch {
                HStack(spacing: 6) {
                    TextField("Search TikTok moods (e.g. dance, vibe, hype)...", text: $tiktokSearchQuery)
                        .font(.caption)
                        .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isEmbeddedDarkGlass ? Color.white.opacity(0.12) : Color.secondary.opacity(0.12))
                        )
                        .submitLabel(.search)
                        .onSubmit {
                            tiktokMedia.refreshCatalog(query: tiktokSearchQuery, force: true)
                        }

                    Button("Fetch") {
                        tiktokMedia.refreshCatalog(query: tiktokSearchQuery, force: true)
                    }
                    .font(.caption.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    if mediaTab == .stickers {
                        ForEach(tiktokMedia.stickers) { asset in
                            let isSelected = selectedSticker == asset.urlString
                            Button {
                                AppHaptics.selection()
                                selectedSticker = (selectedSticker == asset.urlString) ? nil : asset.urlString
                            } label: {
                                ZStack {
                                    TikTokStickerView(rawSticker: asset.urlString, size: 38)
                                }
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white.opacity(0.28) : Color.accentColor.opacity(0.22))
                                            : (isEmbeddedDarkGlass ? Color.white.opacity(0.08) : Color.secondary.opacity(0.09))
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white.opacity(0.88) : Color.accentColor)
                                            : .clear,
                                        lineWidth: 1.4
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(GroupPlaylistStickerPalette.presets, id: \.code) { preset in
                            let isSelected = selectedSticker == preset.code
                            Button {
                                AppHaptics.selection()
                                selectedSticker = (selectedSticker == preset.code) ? nil : preset.code
                            } label: {
                                VStack(spacing: 2) {
                                    TikTokStickerView(rawSticker: preset.code, size: 30)
                                    Text(preset.label)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(isEmbeddedDarkGlass ? .white.opacity(isSelected ? 1 : 0.72) : .secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white.opacity(0.28) : Color.accentColor.opacity(0.22))
                                            : (isEmbeddedDarkGlass ? Color.white.opacity(0.08) : Color.secondary.opacity(0.09))
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white.opacity(0.88) : Color.accentColor)
                                            : .clear,
                                        lineWidth: 1.3
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(tiktokMedia.gifs) { asset in
                            let isSelected = selectedGifURL == asset.urlString
                            Button {
                                AppHaptics.selection()
                                selectedGifURL = (selectedGifURL == asset.urlString) ? nil : asset.urlString
                            } label: {
                                Group {
                                    if let url = asset.mediaURL {
                                        AnimatedTikTokImageView(url: url, contentMode: .scaleAspectFill)
                                    } else {
                                        Color.secondary.opacity(0.2)
                                    }
                                }
                                .frame(width: 74, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white : Color.accentColor)
                                            : Color.white.opacity(0.14),
                                        lineWidth: isSelected ? 2.2 : 0.8
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                if let current = mediaManager.currentItem {
                    Button {
                        AppHaptics.selection()
                        attachCurrentTrack.toggle()
                    } label: {
                        Image(systemName: attachCurrentTrack ? "music.note.list" : "music.note")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                attachCurrentTrack
                                    ? (isEmbeddedDarkGlass ? .black : .white)
                                    : (isEmbeddedDarkGlass ? .white.opacity(0.72) : .secondary)
                            )
                            .frame(width: 32, height: 32)
                            .background(
                                Circle().fill(
                                    attachCurrentTrack
                                        ? (isEmbeddedDarkGlass ? Color.white : Color.accentColor)
                                        : (isEmbeddedDarkGlass ? Color.white.opacity(0.12) : Color.secondary.opacity(0.14))
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tag current song: \(current.displayTitle)")
                }

                TextField(
                    attachCurrentTrack && mediaManager.currentItem != nil
                        ? "Note for \(mediaManager.currentItem!.displayTitle)..."
                        : "Write a message or pick TikTok sticker/GIF...",
                    text: $draftNote
                )
                .font(.subheadline)
                .foregroundStyle(isEmbeddedDarkGlass ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isEmbeddedDarkGlass ? Color.white.opacity(0.13) : Color.secondary.opacity(0.12))
                )
                .submitLabel(.send)
                .onSubmit {
                    submitComposerMessage(to: group)
                }

                let canSend = !draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || selectedSticker != nil
                    || selectedGifURL != nil
                Button {
                    submitComposerMessage(to: group)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            canSend
                                ? (isEmbeddedDarkGlass ? Color.white : Color.accentColor)
                                : (isEmbeddedDarkGlass ? Color.white.opacity(0.28) : Color.secondary.opacity(0.35))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
    }

    private func submitComposerMessage(to group: GroupPlaylist) {
        let attached: GroupPlaylistTrack?
        if attachCurrentTrack, let current = mediaManager.currentItem {
            attached = group.tracks.first(where: {
                $0.title.localizedCaseInsensitiveCompare(current.displayTitle) == .orderedSame
            }) ?? GroupPlaylistTrack(
                id: UUID(),
                title: current.displayTitle,
                artist: current.artist ?? "",
                youtubeVideoID: MediaManager.shared.sourceVideoID(for: current),
                durationSeconds: current.durationSeconds,
                addedBy: groupService.userDisplayName,
                addedAt: Date().timeIntervalSince1970
            )
        } else {
            attached = nil
        }

        groupService.sendMessage(
            text: draftNote,
            sticker: selectedSticker,
            gifURL: selectedGifURL,
            attachedTrack: attached,
            to: group.id
        )
        draftNote = ""
        selectedSticker = nil
        selectedGifURL = nil
        attachCurrentTrack = false
        AppHaptics.selection()
    }
}

struct CollabMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID
    var onAddSongRequested: ((UUID) -> Void)? = nil

    var body: some View {
        NavigationStack {
            CollabMessagesView(
                isEmbeddedDarkGlass: false,
                initialGroupID: groupID,
                onAddSongRequested: { gid in
                    dismiss()
                    onAddSongRequested?(gid)
                }
            )
            .applyAppTheme()
            .navigationTitle("Collab Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct CollabSongNoteTarget: Identifiable {
    let id = UUID()
    let groupID: UUID?
    let songTitle: String
    let songArtist: String
    let localItem: MediaItem?
    let youtubeVideoID: String?
    let durationSeconds: Double?
}

struct CollabSongNoteComposerSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(TikTokMediaService.self) private var tiktokMedia
    @Environment(\.dismiss) private var dismiss

    let target: CollabSongNoteTarget
    var onCompleted: ((UUID) -> Void)? = nil

    @State private var chosenGroupID: UUID?
    @State private var noteText: String = ""
    @State private var selectedSticker: String? = nil
    @State private var selectedGifURL: String? = nil

    private var effectiveGroupID: UUID? {
        chosenGroupID ?? target.groupID ?? groupService.defaultMessageGroup?.id
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Song") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.songTitle)
                            .font(.headline)
                        if !target.songArtist.isEmpty {
                            Text(target.songArtist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if target.groupID == nil && groupService.groups.count > 1 {
                    Section("Collab Playlist") {
                        Picker("Send To", selection: Binding(
                            get: { effectiveGroupID ?? groupService.groups.first?.id ?? UUID() },
                            set: { chosenGroupID = $0 }
                        )) {
                            ForEach(groupService.groups) { group in
                                Text(group.name).tag(group.id)
                            }
                        }
                    }
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tiktokMedia.stickers.prefix(12)) { asset in
                                let selected = selectedSticker == asset.urlString
                                Button {
                                    AppHaptics.selection()
                                    selectedSticker = (selectedSticker == asset.urlString) ? nil : asset.urlString
                                } label: {
                                    TikTokStickerView(rawSticker: asset.urlString, size: 42)
                                        .padding(6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(GroupPlaylistStickerPalette.presets, id: \.code) { preset in
                                let selected = selectedSticker == preset.code
                                Button {
                                    AppHaptics.selection()
                                    selectedSticker = (selectedSticker == preset.code) ? nil : preset.code
                                } label: {
                                    VStack(spacing: 3) {
                                        TikTokStickerView(rawSticker: preset.code, size: 32)
                                        Text(preset.label)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(selected ? .white : .secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("Optional TikTok Sticker")
                        Spacer()
                        Button {
                            tiktokMedia.refreshCatalog(force: true)
                        } label: {
                            Label(tiktokMedia.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                        }
                        .disabled(tiktokMedia.isRefreshing)
                    }
                }

                Section("Optional TikTok GIF") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tiktokMedia.gifs.prefix(15)) { gifAsset in
                                let selected = selectedGifURL == gifAsset.urlString
                                Button {
                                    AppHaptics.selection()
                                    selectedGifURL = (selectedGifURL == gifAsset.urlString) ? nil : gifAsset.urlString
                                } label: {
                                    Group {
                                        if let url = gifAsset.mediaURL {
                                            AnimatedTikTokImageView(url: url, contentMode: .scaleAspectFill)
                                        }
                                    }
                                    .frame(width: 84, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Optional Note / Message") {
                    TextField("Say why you're adding this song...", text: $noteText, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    let hasExtras = !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || selectedSticker != nil
                        || selectedGifURL != nil
                    Button {
                        sendAndDismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text(hasExtras ? "Add Song with Note / Sticker / GIF" : "Add Song (No Note)")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(effectiveGroupID == nil)
                }
            }
            .applyAppTheme()
            .navigationTitle("Add to Collab Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { sendAndDismiss() }
                        .disabled(effectiveGroupID == nil)
                }
            }
            .onAppear {
                chosenGroupID = target.groupID ?? groupService.defaultMessageGroup?.id
                tiktokMedia.refreshIfDue()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendAndDismiss() {
        guard let gid = effectiveGroupID else { return }
        if let local = target.localItem {
            groupService.sendLocalItem(local, to: gid, note: noteText, sticker: selectedSticker, gifURL: selectedGifURL)
        } else {
            groupService.sendSearchedSong(
                title: target.songTitle,
                artist: target.songArtist,
                youtubeVideoID: target.youtubeVideoID,
                durationSeconds: target.durationSeconds,
                to: gid,
                note: noteText,
                sticker: selectedSticker,
                gifURL: selectedGifURL
            )
        }
        onCompleted?(gid)
        dismiss()
    }
}
