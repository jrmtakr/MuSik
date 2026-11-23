import SwiftUI

struct CollabMessagesView: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(MediaManager.self) private var mediaManager
    @Environment(WebMediaDownloader.self) private var downloader

    let isEmbeddedDarkGlass: Bool
    var initialGroupID: UUID? = nil
    var onAddSongRequested: ((UUID) -> Void)? = nil
    var onDismissParentForVideo: (() -> Void)? = nil

    @State private var selectedGroupID: UUID?
    @State private var draftNote: String = ""
    @State private var selectedSticker: String? = nil
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

            HStack(alignment: .center, spacing: 10) {
                if let sticker = msg.sticker, !sticker.isEmpty {
                    Text(sticker)
                        .font(.system(size: 36))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GroupPlaylistStickerPalette.presets, id: \.emoji) { preset in
                        let isSelected = selectedSticker == preset.emoji
                        Button {
                            AppHaptics.selection()
                            selectedSticker = (selectedSticker == preset.emoji) ? nil : preset.emoji
                        } label: {
                            Text(preset.emoji)
                                .font(.title3)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white.opacity(0.32) : Color.accentColor.opacity(0.24))
                                            : (isEmbeddedDarkGlass ? Color.white.opacity(0.09) : Color.secondary.opacity(0.10))
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected
                                            ? (isEmbeddedDarkGlass ? Color.white.opacity(0.85) : Color.accentColor)
                                            : .clear,
                                        lineWidth: 1.2
                                    )
                                )
                        }
                        .buttonStyle(.plain)
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
                        : "Write a message or pick a sticker...",
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

                let canSend = !draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSticker != nil
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
            attachedTrack: attached,
            to: group.id
        )
        draftNote = ""
        selectedSticker = nil
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
    @Environment(\.dismiss) private var dismiss

    let target: CollabSongNoteTarget
    var onCompleted: ((UUID) -> Void)? = nil

    @State private var chosenGroupID: UUID?
    @State private var noteText: String = ""
    @State private var selectedSticker: String? = nil

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

                Section("Optional Sticker") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 10)], spacing: 10) {
                        ForEach(GroupPlaylistStickerPalette.presets, id: \.emoji) { preset in
                            let selected = selectedSticker == preset.emoji
                            Button {
                                AppHaptics.selection()
                                selectedSticker = (selectedSticker == preset.emoji) ? nil : preset.emoji
                            } label: {
                                VStack(spacing: 3) {
                                    Text(preset.emoji)
                                        .font(.title2)
                                    Text(preset.label)
                                        .font(.caption2)
                                        .foregroundStyle(selected ? .white : .secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
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

                Section("Optional Note / Message") {
                    TextField("Say why you're adding this song...", text: $noteText, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    let hasExtras = !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSticker != nil
                    Button {
                        sendAndDismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text(hasExtras ? "Add Song with Note/Sticker" : "Add Song (No Note)")
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
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendAndDismiss() {
        guard let gid = effectiveGroupID else { return }
        if let local = target.localItem {
            groupService.sendLocalItem(local, to: gid, note: noteText, sticker: selectedSticker)
        } else {
            groupService.sendSearchedSong(
                title: target.songTitle,
                artist: target.songArtist,
                youtubeVideoID: target.youtubeVideoID,
                durationSeconds: target.durationSeconds,
                to: gid,
                note: noteText,
                sticker: selectedSticker
            )
        }
        onCompleted?(gid)
        dismiss()
    }
}
