import SwiftUI
import UIKit

struct CreateGroupPlaylistSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((UUID) -> Void)? = nil

    @State private var groupName = ""
    @State private var isCreating = false

    var body: some View {
        @Bindable var groupService = groupService

        NavigationStack {
            Form {
                Section("Playlist Info") {
                    TextField("Playlist name (e.g. Late Night Vibes)", text: $groupName)
                    TextField("Your name (shown to friends)", text: $groupService.userDisplayName)
                }

                Section {
                    Button {
                        isCreating = true
                        Task {
                            let created = await groupService.createGroupPlaylist(name: groupName)
                            isCreating = false
                            dismiss()
                            onCreated?(created.id)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isCreating {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Label("Create Live Group Playlist", systemImage: "person.2.wave.2.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isCreating)
                } footer: {
                    Text("You will receive an easy 8-character Group Code and Invite Link to share with friends. Anyone in the group can add or remove songs live.")
                }
            }
            .applyAppTheme()
            .navigationTitle("New Group Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct JoinGroupPlaylistSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(\.dismiss) private var dismiss

    var onJoined: ((UUID) -> Void)? = nil

    @State private var inviteInput = ""
    @State private var isJoining = false

    private var parsedPreview: (code: String, name: String?)? {
        GroupPlaylistService.parseInviteInput(inviteInput)
    }

    var body: some View {
        @Bindable var groupService = groupService

        NavigationStack {
            Form {
                Section {
                    TextField("Paste Code (XXXX-XXXX) or Invite Link", text: $inviteInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            if let clip = UIPasteboard.general.string {
                                inviteInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if let parsed = parsedPreview {
                            let display = parsed.code.count == 8
                                ? "\(parsed.code.prefix(4))-\(parsed.code.suffix(4))"
                                : parsed.code
                            Text("Code: \(display)")
                                .font(.caption.monospaced().weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    TextField("Your name (shown to friends)", text: $groupService.userDisplayName)
                } header: {
                    Text("Group Code or Link")
                } footer: {
                    Text("Paste the 8-character code, musicplayer:// invite link, or the full invite text shared by your friend.")
                }

                if let err = groupService.lastSyncError {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        isJoining = true
                        Task {
                            let joined = await groupService.joinGroupPlaylist(input: inviteInput)
                            isJoining = false
                            if let joined {
                                dismiss()
                                onJoined?(joined.id)
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isJoining {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("Joining...")
                            } else {
                                Label("Join Live Playlist", systemImage: "person.badge.plus")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(parsedPreview == nil || isJoining)
                }
            }
            .applyAppTheme()
            .navigationTitle("Join Group Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct GroupPlaylistDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID
    @Binding var showPlayerSheet: Bool

    @State private var showAddSongsSheet = false
    @State private var showMessagesSheet = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showEditNicknameAlert = false
    @State private var nicknameInput = ""
    @State private var showLeaveConfirm = false
    @State private var copiedFeedback: String?

    private var group: GroupPlaylist? {
        groupService.groups.first(where: { $0.id == groupID })
    }

    private var isLiveConnected: Bool {
        groupService.liveConnectedGroupID == groupID
    }

    var body: some View {
        @Bindable var groupService = groupService

        Group {
            if let group {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isLiveConnected ? Color.green : Color.orange)
                                        .frame(width: 9, height: 9)
                                    Text(isLiveConnected ? "Live Sync Active" : "Syncing...")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(isLiveConnected ? .green : .orange)
                                }
                                Spacer()
                                Button {
                                    nicknameInput = groupService.userDisplayName
                                    showEditNicknameAlert = true
                                } label: {
                                    Label(groupService.userDisplayName, systemImage: "person.circle")
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Share Code with Friends")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text(group.formattedCode)
                                        .font(.title2.monospaced().weight(.bold))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = group.formattedCode
                                        copiedFeedback = "Copied code \(group.formattedCode)"
                                    } label: {
                                        Label("Copy Code", systemImage: "doc.on.doc")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = group.inviteLinkString
                                    copiedFeedback = "Copied invite link"
                                } label: {
                                    Label("Copy Link", systemImage: "link")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                ShareLink(item: group.shareMessage) {
                                    Label("Share Invite", systemImage: "square.and.arrow.up")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if let copiedFeedback {
                                Text(copiedFeedback)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            }

                            if !group.knownMembers.isEmpty {
                                Text("Members: \(group.knownMembers.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Toggle("Auto-Save Friends' Songs Offline", isOn: $groupService.autoSaveIncomingTracks)
                                .font(.caption)

                            HStack(spacing: 10) {
                                Button {
                                    if let first = group.tracks.first {
                                        Task {
                                            let played = await groupService.playTrack(
                                                first,
                                                in: group.id,
                                                downloader: downloader,
                                                saveOfflineOnly: false
                                            )
                                            if played && mediaManager.currentItem?.isVideo == true {
                                                showPlayerSheet = true
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Play Group", systemImage: "play.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(group.tracks.isEmpty)

                                Button {
                                    showAddSongsSheet = true
                                } label: {
                                    Label("Add Songs", systemImage: "plus.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }

                            Button {
                                showMessagesSheet = true
                            } label: {
                                HStack {
                                    Label("Collab Messages & Stickers", systemImage: "bubble.left.and.bubble.right.fill")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if !group.messages.isEmpty {
                                        Text("\(group.messages.count)")
                                            .font(.caption.weight(.bold))
                                            .monospacedDigit()
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    }

                    Section("Shared Queue (\(group.tracks.count))") {
                        if group.tracks.isEmpty {
                            VStack(spacing: 8) {
                                Text("No songs added yet.")
                                    .font(.subheadline.weight(.semibold))
                                Text("Tap \"Add Songs\" above to send a song from your library or search online. Friends with this code/link will see it live!")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        } else {
                            ForEach(group.tracks) { track in
                                groupTrackRow(track, in: group)
                            }
                            .onDelete { offsets in
                                let victims = offsets.compactMap { group.tracks.indices.contains($0) ? group.tracks[$0] : nil }
                                for track in victims {
                                    groupService.removeTrack(track.id, from: group.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await groupService.refreshGroup(id: group.id)
                }
                .navigationTitle(group.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showMessagesSheet = true
                        } label: {
                            Image(systemName: group.messages.isEmpty ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill")
                        }
                        .accessibilityLabel("Collab Messages")

                        Button {
                            showAddSongsSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }

                        Menu {
                            Button {
                                Task { await groupService.refreshGroup(id: group.id) }
                            } label: {
                                Label("Sync Now", systemImage: "arrow.clockwise")
                            }

                            Button {
                                renameText = group.name
                                showRenameAlert = true
                            } label: {
                                Label("Rename Group", systemImage: "pencil")
                            }

                            Button {
                                UIPasteboard.general.string = group.inviteLinkString
                                copiedFeedback = "Copied invite link"
                            } label: {
                                Label("Copy Invite Link", systemImage: "link")
                            }

                            Divider()

                            Button(role: .destructive) {
                                showLeaveConfirm = true
                            } label: {
                                Label("Leave Group Playlist", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
                .sheet(isPresented: $showAddSongsSheet) {
                    GroupAddSongsSheet(groupID: group.id)
                }
                .sheet(isPresented: $showMessagesSheet) {
                    CollabMessagesSheet(groupID: group.id) { _ in
                        showAddSongsSheet = true
                    }
                }
                .alert("Rename Group Playlist", isPresented: $showRenameAlert) {
                    TextField("Playlist name", text: $renameText)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        groupService.renameGroupPlaylist(id: group.id, to: renameText)
                    }
                }
                .alert("Your Display Name", isPresented: $showEditNicknameAlert) {
                    TextField("Your name", text: $nicknameInput)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        let cleaned = nicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            groupService.userDisplayName = cleaned
                        }
                    }
                }
                .confirmationDialog(
                    "Leave \"\(group.name)\"?",
                    isPresented: $showLeaveConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Leave Group Playlist", role: .destructive) {
                        groupService.leaveGroupPlaylist(id: group.id)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You can rejoin anytime with code \(group.formattedCode).")
                }
            } else {
                ContentUnavailableView("Group Not Found", systemImage: "person.2.slash")
            }
        }
        .onAppear {
            groupService.startObservingGroup(id: groupID)
        }
        .onDisappear {
            groupService.stopObservingGroup()
        }
        .task(id: copiedFeedback) {
            guard copiedFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                copiedFeedback = nil
            }
        }
    }

    private func groupTrackRow(_ track: GroupPlaylistTrack, in group: GroupPlaylist) -> some View {
        let localMatch = groupService.matchingLocalItem(for: track)
        let isActive = groupService.activeGroupID == group.id && groupService.activeGroupTrackID == track.id
        let isResolving = groupService.resolvingTrackID == track.id

        return HStack(spacing: 12) {
            Button {
                Task {
                    let ok = await groupService.playTrack(
                        track,
                        in: group.id,
                        downloader: downloader,
                        saveOfflineOnly: false
                    )
                    if ok && mediaManager.currentItem?.isVideo == true {
                        showPlayerSheet = true
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isActive ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14))
                            .frame(width: 44, height: 44)
                        if isResolving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: isActive && mediaManager.isPlaying ? "waveform" : "music.note")
                                .foregroundStyle(isActive ? Color.accentColor : .primary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(isActive ? .bold : .semibold))
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            if !track.artist.isEmpty {
                                Text(track.artist)
                                    .lineLimit(1)
                                Text("•")
                            }
                            Text("Added by \(track.addedBy)")
                                .lineLimit(1)
                            if let dur = track.formattedDuration {
                                Text("• \(dur)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        if track.hasMessageOrSticker {
                            HStack(spacing: 5) {
                                if let sticker = track.sticker, !sticker.isEmpty {
                                    TikTokStickerView(rawSticker: sticker, size: 20)
                                }
                                if let note = track.note, !note.isEmpty {
                                    Text("\"\(note)\"")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                        .lineLimit(2)
                                } else {
                                    Text(GroupPlaylistStickerPalette.displayName(for: track.sticker ?? ""))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if localMatch != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task {
                        _ = await groupService.playTrack(
                            track,
                            in: group.id,
                            downloader: downloader,
                            saveOfflineOnly: true
                        )
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button {
                Task {
                    let ok = await groupService.playTrack(track, in: group.id, downloader: downloader, saveOfflineOnly: false)
                    if ok && mediaManager.currentItem?.isVideo == true {
                        showPlayerSheet = true
                    }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            if localMatch == nil {
                Button {
                    Task {
                        _ = await groupService.playTrack(track, in: group.id, downloader: downloader, saveOfflineOnly: true)
                    }
                } label: {
                    Label("Save Song Offline", systemImage: "arrow.down.circle")
                }
            }

            Button(role: .destructive) {
                groupService.removeTrack(track.id, from: group.id)
            } label: {
                Label("Remove from Group Playlist", systemImage: "trash")
            }
        }
    }
}

private enum GroupAddSourceTab: String, CaseIterable, Identifiable {
    case library = "My Library"
    case search = "Search Songs"

    var id: String { rawValue }
}

struct GroupAddSongsSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    let groupID: UUID

    var body: some View {
        CollaborativeAddSongsSheet(
            navigationTitle: "Add Songs to Group",
            actionTitle: "Send",
            onSendLocal: { item in
                groupService.sendLocalItem(item, to: groupID)
            },
            onSendSearched: { title, artist, videoID, durationSeconds in
                groupService.sendSearchedSong(
                    title: title,
                    artist: artist,
                    youtubeVideoID: videoID,
                    durationSeconds: durationSeconds,
                    to: groupID
                )
            },
            allowOptionalNoteComposer: true,
            targetGroupID: groupID
        )
    }
}

struct CollaborativeAddSongsSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    let navigationTitle: String
    let actionTitle: String
    let onSendLocal: (MediaItem) -> Void
    let onSendSearched: (String, String, String?, Double?) -> Void
    var allowOptionalNoteComposer: Bool = false
    var targetGroupID: UUID? = nil

    @State private var sourceTab: GroupAddSourceTab = .library
    @State private var libraryFilter = ""
    @State private var searchQuery = ""
    @State private var searchResults: [(videoID: String, title: String, artist: String, durationSeconds: Double?)] = []
    @State private var isSearching = false
    @State private var sentKeys: Set<String> = []
    @State private var composerTarget: CollabSongNoteTarget?
    @State private var pendingComposerSentKey: String?

    private var filteredLibraryItems: [MediaItem] {
        let trimmed = libraryFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return mediaManager.items }
        return mediaManager.items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
                ($0.artist?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $sourceTab) {
                    ForEach(GroupAddSourceTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if sourceTab == .library {
                    List {
                        if filteredLibraryItems.isEmpty {
                            ContentUnavailableView(
                                "No Offline Media",
                                systemImage: "music.note",
                                description: Text("Switch to \"Search Songs\" above to find and send any song directly.")
                            )
                        } else {
                            ForEach(filteredLibraryItems) { item in
                                let alreadySent = sentKeys.contains(item.relativePath)
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
                                        Text(item.artist ?? item.fileExtension.uppercased())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if allowOptionalNoteComposer {
                                        Button {
                                            pendingComposerSentKey = item.relativePath
                                            composerTarget = CollabSongNoteTarget(
                                                groupID: targetGroupID,
                                                songTitle: item.displayTitle,
                                                songArtist: item.artist ?? "",
                                                localItem: item,
                                                youtubeVideoID: mediaManager.sourceVideoID(for: item),
                                                durationSeconds: item.durationSeconds
                                            )
                                        } label: {
                                            Image(systemName: "bubble.and.pencil")
                                                .font(.caption.weight(.bold))
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 6)
                                                .background(Color.secondary.opacity(0.14), in: Capsule())
                                                .foregroundStyle(.primary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Add with Note or Sticker")
                                    }

                                    Button {
                                        sentKeys.insert(item.relativePath)
                                        onSendLocal(item)
                                    } label: {
                                        Text(alreadySent ? "Sent" : actionTitle)
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                (alreadySent ? Color.green : Color.accentColor).opacity(0.16),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(alreadySent ? .green : Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $libraryFilter, prompt: "Filter your library")
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            TextField("Search song or artist...", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.search)
                                .onSubmit { performSearch() }

                            Button("Search") {
                                performSearch()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                        if isSearching {
                            Spacer()
                            ProgressView("Searching songs...")
                            Spacer()
                        } else if searchResults.isEmpty {
                            ContentUnavailableView(
                                "Search Any Song",
                                systemImage: "magnifyingglass",
                                description: Text("Find a song by name or artist and send it live.")
                            )
                        } else {
                            List(searchResults, id: \.videoID) { hit in
                                let alreadySent = sentKeys.contains(hit.videoID)
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                        HStack(spacing: 6) {
                                            if !hit.artist.isEmpty {
                                                Text(hit.artist)
                                            }
                                            if let sec = hit.durationSeconds {
                                                Text("• \(MediaTimeFormatter.format(sec))")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    }

                                    Spacer()

                                    if allowOptionalNoteComposer {
                                        Button {
                                            pendingComposerSentKey = hit.videoID
                                            composerTarget = CollabSongNoteTarget(
                                                groupID: targetGroupID,
                                                songTitle: hit.title,
                                                songArtist: hit.artist,
                                                localItem: nil,
                                                youtubeVideoID: hit.videoID,
                                                durationSeconds: hit.durationSeconds
                                            )
                                        } label: {
                                            Image(systemName: "bubble.and.pencil")
                                                .font(.caption.weight(.bold))
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 6)
                                                .background(Color.secondary.opacity(0.14), in: Capsule())
                                                .foregroundStyle(.primary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Add with Note or Sticker")
                                    }

                                    Button {
                                        sentKeys.insert(hit.videoID)
                                        onSendSearched(hit.title, hit.artist, hit.videoID, hit.durationSeconds)
                                    } label: {
                                        Text(alreadySent ? "Sent" : actionTitle)
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                (alreadySent ? Color.green : Color.accentColor).opacity(0.16),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(alreadySent ? .green : Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                }
            }
            .applyAppTheme()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $composerTarget) { target in
                CollabSongNoteComposerSheet(target: target) { _ in
                    if let key = pendingComposerSentKey {
                        sentKeys.insert(key)
                    }
                    pendingComposerSentKey = nil
                }
            }
        }
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        Task {
            searchResults = await PlaylistURLImporter.searchYouTubeTracks(query: query, limit: 15)
            isSearching = false
        }
    }
}
