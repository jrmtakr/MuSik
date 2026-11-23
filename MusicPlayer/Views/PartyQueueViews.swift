import SwiftUI
import UIKit

struct CreatePartyQueueSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((UUID) -> Void)? = nil

    @State private var partyName = ""
    @State private var isCreating = false

    var body: some View {
        @Bindable var groupService = groupService

        NavigationStack {
            Form {
                Section("Party Queue & Blend Info") {
                    TextField("Party name (e.g. Friday Mix / Car Ride)", text: $partyName)
                    TextField("Your name (shown to friends)", text: $groupService.userDisplayName)
                }

                Section {
                    Button {
                        isCreating = true
                        Task {
                            let created = await partyService.createParty(name: partyName)
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
                            Label("Start Live Party Queue", systemImage: "radio.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isCreating)
                } footer: {
                    Text("Everyone with the Party Code or Invite Link can queue songs live. Songs play strictly First-Come, First-Served unless you tap Blend Rotation.")
                }
            }
            .applyAppTheme()
            .navigationTitle("Start Party Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct JoinPartyQueueSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
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
                    TextField("Paste Code (XXXX-XXXX) or Party Link", text: $inviteInput)
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
                                .background(Color.orange.opacity(0.16), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }

                    TextField("Your name (shown when you queue songs)", text: $groupService.userDisplayName)
                } header: {
                    Text("Party Code or Invite Link")
                } footer: {
                    Text("Paste the 8-character Party Code, musicplayer://party link, or invite message from a friend.")
                }

                if let err = partyService.lastSyncError {
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
                            let joined = await partyService.joinParty(input: inviteInput)
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
                                Label("Join Party Queue", systemImage: "person.2.wave.2.fill")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(parsedPreview == nil || isJoining)
                }
            }
            .applyAppTheme()
            .navigationTitle("Join Party Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct PartyQueueDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(\.dismiss) private var dismiss

    let partyID: UUID
    @Binding var showPlayerSheet: Bool

    @State private var showQueueSongsSheet = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showEditNicknameAlert = false
    @State private var nicknameInput = ""
    @State private var showLeaveConfirm = false
    @State private var copiedFeedback: String?

    private var party: PartyQueueSession? {
        partyService.parties.first(where: { $0.id == partyID })
    }

    private var isLiveConnected: Bool {
        partyService.liveConnectedPartyID == partyID
    }

    var body: some View {
        @Bindable var groupService = groupService
        @Bindable var partyService = partyService

        Group {
            if let party {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isLiveConnected ? Color.green : Color.orange)
                                        .frame(width: 9, height: 9)
                                    Text(isLiveConnected ? "Live FIFO Queue Synced" : "Syncing...")
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
                                Text("Party Code & Link (First Come, First Served)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text(party.formattedCode)
                                        .font(.title2.monospaced().weight(.bold))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = party.formattedCode
                                        copiedFeedback = "Copied code \(party.formattedCode)"
                                    } label: {
                                        Label("Copy Code", systemImage: "doc.on.doc")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    UIPasteboard.general.string = party.inviteLinkString
                                    copiedFeedback = "Copied party invite link"
                                } label: {
                                    Label("Copy Link", systemImage: "link")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                ShareLink(item: party.shareMessage) {
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

                            if !party.knownMembers.isEmpty {
                                Text("Friends in Party: \(party.knownMembers.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Toggle("Auto-Save Friends' Songs Offline", isOn: $partyService.autoSavePartyTracks)
                                .font(.caption)

                            HStack(spacing: 10) {
                                Button {
                                    Task {
                                        let ok = await partyService.startOrAdvanceFIFOPlayback(
                                            in: party.id,
                                            downloader: downloader
                                        )
                                        if ok && mediaManager.currentItem?.isVideo == true {
                                            showPlayerSheet = true
                                        }
                                    }
                                } label: {
                                    Label(
                                        party.nowPlayingEntry != nil && partyService.activePartyID == party.id
                                            ? "Play Next in Queue"
                                            : "Play Queue (FIFO)",
                                        systemImage: "play.fill"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(party.upNext.isEmpty && party.nowPlayingEntry == nil)

                                Button {
                                    showQueueSongsSheet = true
                                } label: {
                                    Label("Queue Song", systemImage: "text.badge.plus")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }

                            HStack(spacing: 10) {
                                Button {
                                    partyService.blendMyFavorites(into: party.id)
                                } label: {
                                    Label("Blend My Favorites", systemImage: "sparkles")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                if party.upNext.count > 2 {
                                    Button {
                                        partyService.interleaveBlendOrder(in: party.id)
                                    } label: {
                                        Label("Fair Friend Turn Mix", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    if let spinning = party.nowPlayingEntry {
                        Section("Now Playing in Party") {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.orange.opacity(0.2))
                                        .frame(width: 46, height: 46)
                                    if partyService.resolvingEntryID == spinning.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "waveform")
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(spinning.title)
                                        .font(.subheadline.weight(.bold))
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        if !spinning.artist.isEmpty {
                                            Text(spinning.artist)
                                                .lineLimit(1)
                                            Text("•")
                                        }
                                        Text("Queued by \(spinning.queuedBy)")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Listen") {
                                    Task {
                                        let ok = await partyService.startOrAdvanceFIFOPlayback(
                                            in: party.id,
                                            downloader: downloader,
                                            specificEntry: spinning
                                        )
                                        if ok && mediaManager.currentItem?.isVideo == true {
                                            showPlayerSheet = true
                                        }
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Section("Up Next • First Come, First Served (\(party.upNext.count))") {
                        if party.upNext.isEmpty {
                            VStack(spacing: 8) {
                                Text("Queue is empty.")
                                    .font(.subheadline.weight(.semibold))
                                Text("Tap \"Queue Song\" or \"Blend My Favorites\" to add songs. Whoever queues first plays #1!")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        } else {
                            ForEach(Array(party.upNext.enumerated()), id: \.element.id) { idx, entry in
                                partyEntryRow(entry, position: idx + 1, party: party)
                            }
                            .onDelete { offsets in
                                let victims = offsets.compactMap { party.upNext.indices.contains($0) ? party.upNext[$0] : nil }
                                for entry in victims {
                                    partyService.removeEntry(entry.id, from: party.id)
                                }
                            }
                        }
                    }

                    if !party.playedHistory.isEmpty {
                        Section("Recently Played (\(party.playedHistory.count))") {
                            ForEach(party.playedHistory) { oldEntry in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(oldEntry.title)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text("Queued by \(oldEntry.queuedBy)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button("Re-Queue") {
                                        partyService.requeueHistoryEntry(oldEntry, in: party.id)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await partyService.refreshParty(id: party.id)
                }
                .navigationTitle(party.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showQueueSongsSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }

                        Menu {
                            Button {
                                Task { await partyService.refreshParty(id: party.id) }
                            } label: {
                                Label("Sync Now", systemImage: "arrow.clockwise")
                            }

                            Button {
                                renameText = party.name
                                showRenameAlert = true
                            } label: {
                                Label("Rename Party", systemImage: "pencil")
                            }

                            Button {
                                UIPasteboard.general.string = party.inviteLinkString
                                copiedFeedback = "Copied party invite link"
                            } label: {
                                Label("Copy Party Link", systemImage: "link")
                            }

                            Divider()

                            Button(role: .destructive) {
                                showLeaveConfirm = true
                            } label: {
                                Label("Leave Party Queue", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
                .sheet(isPresented: $showQueueSongsSheet) {
                    CollaborativeAddSongsSheet(
                        navigationTitle: "Queue Song (FIFO)",
                        actionTitle: "Queue",
                        onSendLocal: { item in
                            partyService.queueLocalItem(item, to: party.id)
                        },
                        onSendSearched: { title, artist, videoID, durationSeconds in
                            partyService.queueSearchedSong(
                                title: title,
                                artist: artist,
                                youtubeVideoID: videoID,
                                durationSeconds: durationSeconds,
                                to: party.id
                            )
                        }
                    )
                }
                .alert("Rename Party Queue", isPresented: $showRenameAlert) {
                    TextField("Party name", text: $renameText)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        partyService.renameParty(id: party.id, to: renameText)
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
                    "Leave \"\(party.name)\"?",
                    isPresented: $showLeaveConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Leave Party Queue", role: .destructive) {
                        partyService.leaveParty(id: party.id)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You can rejoin anytime with code \(party.formattedCode).")
                }
            } else {
                ContentUnavailableView("Party Ended", systemImage: "radio")
            }
        }
        .onAppear {
            partyService.startObservingParty(id: partyID)
        }
        .onDisappear {
            partyService.stopObservingParty()
        }
        .task(id: copiedFeedback) {
            guard copiedFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                copiedFeedback = nil
            }
        }
    }

    private func partyEntryRow(
        _ entry: PartyQueueEntry,
        position: Int,
        party: PartyQueueSession
    ) -> some View {
        let localMatch = partyService.matchingLocalItem(for: entry)
        let isResolving = partyService.resolvingEntryID == entry.id

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(position == 1 ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.14))
                    .frame(width: 40, height: 40)
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("#\(position)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(position == 1 ? .orange : .primary)
                }
            }

            Button {
                Task {
                    let ok = await partyService.startOrAdvanceFIFOPlayback(
                        in: party.id,
                        downloader: downloader,
                        specificEntry: entry
                    )
                    if ok && mediaManager.currentItem?.isVideo == true {
                        showPlayerSheet = true
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if !entry.artist.isEmpty {
                            Text(entry.artist)
                                .lineLimit(1)
                            Text("•")
                        }
                        Text("Queued by \(entry.queuedBy)")
                            .lineLimit(1)
                        if let dur = entry.formattedDuration {
                            Text("• \(dur)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if localMatch != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
        .contextMenu {
            Button {
                Task {
                    let ok = await partyService.startOrAdvanceFIFOPlayback(
                        in: party.id,
                        downloader: downloader,
                        specificEntry: entry
                    )
                    if ok && mediaManager.currentItem?.isVideo == true {
                        showPlayerSheet = true
                    }
                }
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }

            Button(role: .destructive) {
                partyService.removeEntry(entry.id, from: party.id)
            } label: {
                Label("Remove from Queue", systemImage: "trash")
            }
        }
    }
}
