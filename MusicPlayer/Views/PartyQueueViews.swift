import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct CreatePartyQueueSheet: View {
    @Environment(GroupPlaylistService.self) private var groupService
    @Environment(PartyQueueService.self) private var partyService
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((UUID) -> Void)? = nil

    @State private var partyName = ""
    @State private var guestsCanControl = true
    @State private var isCreating = false

    var body: some View {
        @Bindable var groupService = groupService

        NavigationStack {
            Form {
                Section("Jam Session Details") {
                    TextField("Jam name (e.g. Friday Mix / Car Ride)", text: $partyName)
                    TextField("Your name (shown to friends)", text: $groupService.userDisplayName)
                    Toggle("Let guests control what's playing", isOn: $guestsCanControl)
                }

                Section {
                    Button {
                        isCreating = true
                        Task {
                            let created = await partyService.createParty(
                                name: partyName,
                                guestsCanControl: guestsCanControl
                            )
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
                            Label("Start Live Jam", systemImage: "dot.radiowaves.left.and.right")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isCreating)
                } footer: {
                    Text("Share the QR code, Jam Code, or Link. Nearby friends on the same Wi-Fi also see your Jam automatically.")
                }
            }
            .applyAppTheme()
            .navigationTitle("Start a Jam")
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
                if !partyService.nearbyJams.isEmpty {
                    Section("Nearby Jams on Wi-Fi") {
                        ForEach(partyService.nearbyJams) { nearby in
                            Button {
                                isJoining = true
                                Task {
                                    let joined = await partyService.joinParty(input: nearby.code)
                                    isJoining = false
                                    if let joined {
                                        dismiss()
                                        onJoined?(joined.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.green.opacity(0.18))
                                            .frame(width: 40, height: 40)
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .foregroundStyle(.green)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(nearby.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text("Hosted by \(nearby.hostName) • \(nearby.formattedCode)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Join")
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                            .disabled(isJoining)
                        }
                    }
                }

                Section {
                    TextField("Paste Code (XXXX-XXXX) or Jam Link", text: $inviteInput)
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
                                .background(Color.green.opacity(0.16), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }

                    TextField("Your name (shown in the Jam)", text: $groupService.userDisplayName)
                } header: {
                    Text("Jam Code or Invite Link")
                } footer: {
                    Text("Paste an 8-character Jam Code, musicplayer://jam link, or tap a nearby Wi-Fi Jam above.")
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
                                Text("Joining Jam...")
                            } else {
                                Label("Join Live Jam", systemImage: "person.2.wave.2.fill")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(parsedPreview == nil || isJoining)
                }
            }
            .applyAppTheme()
            .navigationTitle("Join a Jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                partyService.startBonjourDiscovery()
            }
            .onDisappear {
                partyService.stopBonjourDiscovery()
            }
        }
    }
}

/// Quick-launch / active Jam sheet opened right from the Now Playing pill.
struct JamSessionSheet: View {
    @Environment(PartyQueueService.self) private var partyService
    @Environment(\.dismiss) private var dismiss

    @Binding var showPlayerSheet: Bool

    @State private var showJoinSheet = false
    @State private var showCreateSheet = false

    var body: some View {
        NavigationStack {
            if let active = partyService.activeJamSession ?? partyService.parties.first(where: { $0.isEnded != true }) {
                PartyQueueDetailView(partyID: active.id, showPlayerSheet: $showPlayerSheet)
            } else {
                List {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(.green)
                            Text("Listen & Queue Together in Real Time")
                                .font(.headline)
                            Text("Start a Jam to share a QR code & link with friends. Everyone hears the same track synced to the second, or queues songs onto your speaker.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            HStack(spacing: 10) {
                                Button {
                                    showCreateSheet = true
                                } label: {
                                    Label("Start a Jam", systemImage: "dot.radiowaves.left.and.right")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Button {
                                    showJoinSheet = true
                                } label: {
                                    Label("Join Jam", systemImage: "person.badge.plus")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }

                    if !partyService.nearbyJams.isEmpty {
                        Section("Nearby on Wi-Fi") {
                            ForEach(partyService.nearbyJams) { nearby in
                                Button {
                                    Task {
                                        _ = await partyService.joinParty(input: nearby.code)
                                    }
                                } label: {
                                    HStack {
                                        Label(nearby.name, systemImage: "wifi")
                                        Spacer()
                                        Text("Join")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .applyAppTheme()
                .navigationTitle("Jam")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .onAppear { partyService.startBonjourDiscovery() }
                .onDisappear { partyService.stopBonjourDiscovery() }
                .sheet(isPresented: $showCreateSheet) {
                    CreatePartyQueueSheet()
                }
                .sheet(isPresented: $showJoinSheet) {
                    JoinPartyQueueSheet()
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
    @State private var showQRInviteSheet = false
    @State private var copiedFeedback: String?

    private var party: PartyQueueSession? {
        partyService.parties.first(where: { $0.id == partyID })
    }

    private var isLiveConnected: Bool {
        partyService.liveConnectedPartyID == partyID
    }

    private var isHost: Bool {
        partyService.isHost(of: partyID)
    }

    private var canControl: Bool {
        partyService.canControlPlayback(in: partyID)
    }

    var body: some View {
        @Bindable var groupService = groupService
        @Bindable var partyService = partyService

        Group {
            if let party, party.isEnded != true {
                List {
                    jamHeaderSection(party)
                    participantsSection(party)
                    if party.nowPlayingEntry != nil || party.livePlayback != nil {
                        nowPlayingJamSection(party)
                    }
                    upNextSection(party)
                    if !party.playedHistory.isEmpty {
                        historySection(party)
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
                                showQRInviteSheet = true
                            } label: {
                                Label("Show Invite QR Code", systemImage: "qrcode")
                            }

                            Button {
                                Task { await partyService.refreshParty(id: party.id) }
                            } label: {
                                Label("Sync Now", systemImage: "arrow.clockwise")
                            }

                            Button {
                                renameText = party.name
                                showRenameAlert = true
                            } label: {
                                Label("Rename Jam", systemImage: "pencil")
                            }

                            Button {
                                UIPasteboard.general.string = party.inviteLinkString
                                copiedFeedback = "Copied Jam invite link"
                            } label: {
                                Label("Copy Jam Link", systemImage: "link")
                            }

                            Divider()

                            Button(role: .destructive) {
                                showLeaveConfirm = true
                            } label: {
                                Label(isHost ? "End Jam" : "Leave Jam", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
                .sheet(isPresented: $showQueueSongsSheet) {
                    CollaborativeAddSongsSheet(
                        navigationTitle: "Add to Jam Queue",
                        actionTitle: "Add to Jam",
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
                .sheet(isPresented: $showQRInviteSheet) {
                    jamQRInviteSheet(party)
                }
                .alert("Rename Jam", isPresented: $showRenameAlert) {
                    TextField("Jam name", text: $renameText)
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
                    isHost ? "End Jam \"\(party.name)\"?" : "Leave \"\(party.name)\"?",
                    isPresented: $showLeaveConfirm,
                    titleVisibility: .visible
                ) {
                    if isHost {
                        Button("End Jam for Everyone", role: .destructive) {
                            partyService.endJamForEveryone(id: party.id)
                            dismiss()
                        }
                    }
                    Button("Leave Only My Device", role: .destructive) {
                        partyService.leaveParty(id: party.id)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Code: \(party.formattedCode)")
                }
            } else {
                ContentUnavailableView(
                    "Jam Ended",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(partyService.lastSyncError ?? "The host ended this Jam session.")
                )
            }
        }
        .onAppear {
            partyService.activePartyID = partyID
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

    // MARK: - Sections

    private func jamHeaderSection(_ party: PartyQueueSession) -> some View {
        @Bindable var partyService = partyService

        return Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isLiveConnected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(isLiveConnected ? (isHost ? "Hosting Live Jam" : "Joined Live Jam") : "Connecting...")
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

                HStack(spacing: 14) {
                    if let qrImage = Self.qrCodeImage(for: party.inviteLinkString) {
                        Button {
                            showQRInviteSheet = true
                        } label: {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 68, height: 68)
                                .padding(6)
                                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Jam Code")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(party.formattedCode)
                            .font(.title2.monospaced().weight(.bold))
                            .textSelection(.enabled)
                        Text(isHost ? "Tap QR or share link to invite friends" : "Hosted by \(party.hostName ?? "Host")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = party.formattedCode
                        copiedFeedback = "Copied code \(party.formattedCode)"
                    } label: {
                        Label("Code", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showQRInviteSheet = true
                    } label: {
                        Label("QR", systemImage: "qrcode")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    ShareLink(item: party.shareMessage) {
                        Label("Invite", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                if let copiedFeedback {
                    Text(copiedFeedback)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }

                if isHost {
                    Toggle(
                        "Let guests control what's playing",
                        isOn: Binding(
                            get: { party.allowsGuestControls },
                            set: { partyService.setGuestsCanControl($0, in: party.id) }
                        )
                    )
                    .font(.caption)
                    .tint(.green)
                } else {
                    Toggle("Listen on this device (synced audio)", isOn: $partyService.listenOnThisDevice)
                        .font(.caption)
                        .tint(.green)
                }

                Toggle("Auto-save Jam tracks offline", isOn: $partyService.autoSavePartyTracks)
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
                            party.nowPlayingEntry != nil ? "Next Track" : "Start Jam",
                            systemImage: "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled((party.upNext.isEmpty && party.nowPlayingEntry == nil) || !canControl)

                    Button {
                        showQueueSongsSheet = true
                    } label: {
                        Label("Add Songs", systemImage: "text.badge.plus")
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

                    if party.upNext.count > 2 && canControl {
                        Button {
                            partyService.interleaveBlendOrder(in: party.id)
                        } label: {
                            Label("Fair Turn Mix", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func participantsSection(_ party: PartyQueueSession) -> some View {
        let members = party.activeParticipantsList
        return Section("In this Jam (\(max(1, members.count)))") {
            if members.isEmpty {
                Label("\(groupService.userDisplayName) (Host)", systemImage: "crown.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(members) { participant in
                            HStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(participant.isHost ? Color.green.opacity(0.22) : Color.secondary.opacity(0.16))
                                        .frame(width: 28, height: 28)
                                    Text(String(participant.name.prefix(1)).uppercased())
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(participant.isHost ? .green : .primary)
                                }
                                Text(participant.isHost ? "\(participant.name) (Host)" : participant.name)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .contextMenu {
                                if isHost && !participant.isHost && participant.id != partyService.localSenderID {
                                    Button(role: .destructive) {
                                        partyService.kickParticipant(participant.id, from: party.id)
                                    } label: {
                                        Label("Remove from Jam", systemImage: "person.fill.xmark")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func nowPlayingJamSection(_ party: PartyQueueSession) -> some View {
        let state = party.livePlayback
        let entry = party.nowPlayingEntry
        let title = state?.title ?? entry?.title ?? "Ready"
        let artist = state?.artist ?? entry?.artist ?? ""
        let queuedBy = entry?.queuedBy ?? state?.updatedBy ?? "Host"
        let isResolving = entry.map { partyService.resolvingEntryID == $0.id } ?? false
        let isPlaying = state?.isPlaying ?? (isHost && mediaManager.isPlaying)

        return Section("Now Playing in Jam") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.green.opacity(0.2))
                            .frame(width: 48, height: 48)
                        if isResolving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if !artist.isEmpty {
                                Text(artist)
                                    .lineLimit(1)
                                Text("•")
                            }
                            Text("Added by \(queuedBy)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if canControl {
                        HStack(spacing: 12) {
                            Button {
                                Task { await partyService.toggleJamPlayPause(in: party.id, downloader: downloader) }
                            } label: {
                                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)

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
                                Image(systemName: "forward.end.fill")
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .disabled(party.upNext.isEmpty)
                        }
                    } else if let entry {
                        Button("Sync") {
                            Task {
                                _ = await partyService.startOrAdvanceFIFOPlayback(
                                    in: party.id,
                                    downloader: downloader,
                                    specificEntry: entry
                                )
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let state {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        let dur = max(1.0, state.durationSeconds ?? (isHost ? mediaManager.duration : 180))
                        let pos = isHost ? mediaManager.currentTime : state.estimatedPosition(at: context.date)
                        VStack(spacing: 3) {
                            ProgressView(value: min(1.0, max(0.0, pos / dur)))
                                .progressViewStyle(.linear)
                                .tint(.green)
                            HStack {
                                Text(MediaTimeFormatter.format(pos))
                                Spacer()
                                Text(MediaTimeFormatter.format(dur))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func upNextSection(_ party: PartyQueueSession) -> some View {
        Section("Up Next in Jam (\(party.upNext.count))") {
            if party.upNext.isEmpty {
                VStack(spacing: 8) {
                    Text("Queue is empty.")
                        .font(.subheadline.weight(.semibold))
                    Text("Tap \"Add Songs\" or \"Blend My Favorites\" to add tracks to the Jam.")
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
                .onMove { source, destination in
                    guard canControl else { return }
                    partyService.moveUpNext(from: source, to: destination, in: party.id)
                }
                .onDelete { offsets in
                    let victims = offsets.compactMap { party.upNext.indices.contains($0) ? party.upNext[$0] : nil }
                    for entry in victims {
                        partyService.removeEntry(entry.id, from: party.id)
                    }
                }
            }
        }
    }

    private func historySection(_ party: PartyQueueSession) -> some View {
        Section("Recently Played (\(party.playedHistory.count))") {
            ForEach(party.playedHistory) { oldEntry in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(oldEntry.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("Added by \(oldEntry.queuedBy)")
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

    private func jamQRInviteSheet(_ party: PartyQueueSession) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let qr = Self.qrCodeImage(for: party.inviteLinkString) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 12)
                }

                VStack(spacing: 4) {
                    Text(party.name)
                        .font(.title3.weight(.bold))
                    Text("Code: \(party.formattedCode)")
                        .font(.headline.monospaced())
                        .foregroundStyle(.green)
                }

                Text("Friends can point their camera or paste the Jam Code inside MuseJRM to join immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                ShareLink(item: party.shareMessage) {
                    Label("Share Invite Link", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding()
            .navigationTitle("Invite to Jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showQRInviteSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
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
                    .fill(position == 1 ? Color.green.opacity(0.22) : Color.secondary.opacity(0.14))
                    .frame(width: 40, height: 40)
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("#\(position)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(position == 1 ? .green : .primary)
                }
            }

            Button {
                guard canControl else { return }
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
                        Text("Added by \(entry.queuedBy)")
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
            if canControl {
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
            }

            Button(role: .destructive) {
                partyService.removeEntry(entry.id, from: party.id)
            } label: {
                Label("Remove from Queue", systemImage: "trash")
            }
        }
    }

    private static func qrCodeImage(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
