import Foundation
import Network
import Observation
import UIKit

struct PartyQueueEntry: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var artist: String
    var youtubeVideoID: String?
    var durationSeconds: Double?
    var queuedBy: String
    var queuedBySenderID: String
    var localQueuedAt: TimeInterval
    var serverQueuedAt: TimeInterval?

    var effectiveOrderTime: TimeInterval {
        serverQueuedAt ?? localQueuedAt
    }

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return MediaTimeFormatter.format(durationSeconds)
    }
}

struct JamParticipant: Identifiable, Hashable, Codable, Sendable {
    let id: String // senderID
    var name: String
    var isHost: Bool
    var lastSeenAt: TimeInterval
}

struct JamPlaybackState: Hashable, Codable, Sendable {
    var entryID: UUID?
    var title: String
    var artist: String
    var youtubeVideoID: String?
    var durationSeconds: Double?
    var isPlaying: Bool
    var positionSeconds: Double
    var playbackRate: Float
    var updatedAt: TimeInterval
    var updatedBy: String

    func estimatedPosition(at now: Date = .now) -> Double {
        guard isPlaying else { return max(0, positionSeconds) }
        let elapsed = max(0, now.timeIntervalSince1970 - updatedAt)
        let raw = positionSeconds + elapsed * Double(max(0.5, playbackRate))
        if let durationSeconds, durationSeconds > 0 {
            return min(durationSeconds, max(0, raw))
        }
        return max(0, raw)
    }
}

struct NearbyJamSession: Identifiable, Hashable, Sendable {
    let id: String
    let code: String
    let name: String
    let hostName: String

    var formattedCode: String {
        let clean = GroupPlaylistService.normalizeCode(code)
        if clean.count == 8 {
            return "\(clean.prefix(4))-\(clean.suffix(4))"
        }
        return clean
    }
}

struct PartyQueueSession: Identifiable, Hashable, Codable {
    let id: UUID
    let code: String
    var name: String
    var upNext: [PartyQueueEntry] = []
    var nowPlayingEntry: PartyQueueEntry?
    var playedHistory: [PartyQueueEntry] = []
    var removedTimestamps: [UUID: TimeInterval] = [:]
    var consumedEntryIDs: [UUID: TimeInterval] = [:]
    var appliedEventIDs: [UUID] = []
    var knownMembers: [String] = []
    var createdAt: Date = .now
    var lastSyncedAt: Date?

    // 1-to-1 Spotify Jam fields (all optional so older saved sessions still decode cleanly)
    var hostSenderID: String?
    var hostName: String?
    var guestsCanControlPlayback: Bool?
    var participants: [JamParticipant]?
    var kickedSenderIDs: [String]?
    var livePlayback: JamPlaybackState?
    var isEnded: Bool?

    var allowsGuestControls: Bool {
        guestsCanControlPlayback ?? true
    }

    var activeParticipantsList: [JamParticipant] {
        let now = Date().timeIntervalSince1970
        let list = (participants ?? []).filter { p in
            !(kickedSenderIDs ?? []).contains(p.id) && (now - p.lastSeenAt < 180 || p.isHost)
        }
        return list.sorted { lhs, rhs in
            if lhs.isHost != rhs.isHost { return lhs.isHost }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    var formattedCode: String {
        let clean = GroupPlaylistService.normalizeCode(code)
        if clean.count == 8 {
            return "\(clean.prefix(4))-\(clean.suffix(4))"
        }
        return clean
    }

    var inviteLinkString: String {
        var comps = URLComponents()
        comps.scheme = "musicplayer"
        comps.host = "jam"
        comps.queryItems = [
            URLQueryItem(name: "code", value: formattedCode),
            URLQueryItem(name: "name", value: name)
        ]
        return comps.string ?? "musicplayer://jam?code=\(formattedCode)"
    }

    var shareMessage: String {
        "Join my live Spotify-style Jam \"\(name)\"!\n\nJam Code: \(formattedCode)\nLink: \(inviteLinkString)\n\nIn MuseJRM: Playlists -> Jam -> Join Jam."
    }
}

private enum PartyQueueEventKind: String, Codable {
    case createParty
    case joinPresence
    case heartbeat
    case leaveParty
    case renameParty
    case enqueueTrack
    case updateEntryVideoID
    case removeEntry
    case startPlaybackEntry
    case clearPlayedHistory
    case reorderBlendEntries
    case playbackSync
    case remoteCommand
    case setGuestControl
    case kickMember
    case endJam
    case snapshot
}

private enum JamRemoteAction: String, Codable {
    case play
    case pause
    case next
    case seek
}

private struct PartyQueueEventPayload: Codable {
    let id: UUID
    let senderID: String
    let senderName: String
    let timestamp: TimeInterval
    let kind: PartyQueueEventKind
    var partyName: String?
    var entry: PartyQueueEntry?
    var entryID: UUID?
    var youtubeVideoID: String?
    var needsSnapshot: Bool?
    var orderedEntryIDs: [UUID]?
    var upNext: [PartyQueueEntry]?
    var nowPlayingEntry: PartyQueueEntry?
    var playedHistory: [PartyQueueEntry]?
    var removedTimestamps: [UUID: TimeInterval]?
    var consumedEntryIDs: [UUID: TimeInterval]?
    var members: [String]?
    var hostSenderID: String?
    var hostName: String?
    var guestsCanControlPlayback: Bool?
    var playbackState: JamPlaybackState?
    var remoteAction: JamRemoteAction?
    var seekPosition: Double?
    var targetSenderID: String?
}

@MainActor
@Observable
final class PartyQueueService {
    static let shared = PartyQueueService()

    var parties: [PartyQueueSession] = []
    var pendingOpenPartyID: UUID?
    var liveConnectedPartyID: UUID?
    var resolvingEntryID: UUID?
    var activePartyID: UUID?
    var lastSyncError: String?
    var nearbyJams: [NearbyJamSession] = []

    var autoSavePartyTracks: Bool {
        didSet {
            UserDefaults.standard.set(autoSavePartyTracks, forKey: Self.autoSaveDefaultsKey)
        }
    }

    /// True = Spotify "Listen together" on your own phone/earbuds; false = "Control host's speaker only".
    var listenOnThisDevice: Bool {
        didSet {
            UserDefaults.standard.set(listenOnThisDevice, forKey: Self.listenTogetherDefaultsKey)
            if !listenOnThisDevice, let activePartyID, !isHost(of: activePartyID) {
                if MediaManager.shared.isPlaying {
                    MediaManager.shared.pause()
                }
            } else if listenOnThisDevice, let activePartyID,
                      let party = parties.first(where: { $0.id == activePartyID }),
                      let state = party.livePlayback {
                Task { await applyRemotePlaybackToGuestDevice(state, in: party) }
            }
        }
    }

    var localSenderID: String { deviceSenderID }

    @ObservationIgnored private let deviceSenderID: String
    @ObservationIgnored private var observedPartyID: UUID?
    @ObservationIgnored private var wsTask: URLSessionWebSocketTask?
    @ObservationIgnored private var liveListenTask: Task<Void, Never>?
    @ObservationIgnored private var pollLoopTask: Task<Void, Never>?
    @ObservationIgnored private var hostSyncLoopTask: Task<Void, Never>?
    @ObservationIgnored private var participantHeartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshotBroadcastByParty: [UUID: Date] = [:]
    @ObservationIgnored private var lastGuestSyncedSignature: String?
    @ObservationIgnored private var lastGuestSyncedTrackID: UUID?
    @ObservationIgnored private var bonjourListener: NWListener?
    @ObservationIgnored private var bonjourBrowser: NWBrowser?

    private static let senderIDDefaultsKey = "musicplayer.party.senderID"
    private static let autoSaveDefaultsKey = "musicplayer.party.autoSave"
    private static let listenTogetherDefaultsKey = "musicplayer.party.listenTogether"

    private init() {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: Self.senderIDDefaultsKey), !saved.isEmpty {
            self.deviceSenderID = saved
        } else {
            let fresh = UUID().uuidString
            d.set(fresh, forKey: Self.senderIDDefaultsKey)
            self.deviceSenderID = fresh
        }
        self.autoSavePartyTracks = d.bool(forKey: Self.autoSaveDefaultsKey)
        if d.object(forKey: Self.listenTogetherDefaultsKey) == nil {
            d.set(true, forKey: Self.listenTogetherDefaultsKey)
        }
        self.listenOnThisDevice = d.bool(forKey: Self.listenTogetherDefaultsKey)
        loadParties()
    }

    nonisolated static func topicName(forCode code: String) -> String {
        "mppty_\(GroupPlaylistService.normalizeCode(code).lowercased())"
    }

    func isHost(of partyID: UUID) -> Bool {
        guard let party = parties.first(where: { $0.id == partyID }) else { return false }
        return party.hostSenderID == nil || party.hostSenderID == deviceSenderID
    }

    func canControlPlayback(in partyID: UUID) -> Bool {
        guard let party = parties.first(where: { $0.id == partyID }) else { return false }
        return isHost(of: partyID) || party.allowsGuestControls
    }

    func currentJamTitle(for partyID: UUID) -> String {
        parties.first(where: { $0.id == partyID })?.name ?? "Jam"
    }

    var activeJamSession: PartyQueueSession? {
        guard let activePartyID else { return nil }
        return parties.first(where: { $0.id == activePartyID && $0.isEnded != true })
    }

    // MARK: - Create / Join / Leave

    @discardableResult
    func createParty(name: String, guestsCanControl: Bool = true) async -> PartyQueueSession {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "\(currentMemberName)'s Jam" : cleanName
        let code = GroupPlaylistService.normalizeCode(GroupPlaylistService.generateRoomCode())
        let member = currentMemberName
        let now = Date().timeIntervalSince1970

        var seededUpNext: [PartyQueueEntry] = []
        var initialPlayback: JamPlaybackState?
        var seededNowPlaying: PartyQueueEntry?

        // Seed currently playing song into the Jam automatically, just like Spotify Jam!
        if let current = MediaManager.shared.currentItem {
            let currentEntry = PartyQueueEntry(
                id: UUID(),
                title: current.displayTitle,
                artist: (current.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                youtubeVideoID: MediaManager.shared.sourceVideoID(for: current),
                durationSeconds: MediaManager.shared.duration > 0 ? MediaManager.shared.duration : current.durationSeconds,
                queuedBy: member,
                queuedBySenderID: deviceSenderID,
                localQueuedAt: now,
                serverQueuedAt: nil
            )
            seededNowPlaying = currentEntry
            initialPlayback = JamPlaybackState(
                entryID: currentEntry.id,
                title: currentEntry.title,
                artist: currentEntry.artist,
                youtubeVideoID: currentEntry.youtubeVideoID,
                durationSeconds: currentEntry.durationSeconds,
                isPlaying: MediaManager.shared.isPlaying,
                positionSeconds: MediaManager.shared.currentTime,
                playbackRate: MediaManager.shared.playbackRate,
                updatedAt: now,
                updatedBy: member
            )
        } else {
            seededUpNext = []
        }

        let party = PartyQueueSession(
            id: UUID(),
            code: code,
            name: finalName,
            upNext: seededUpNext,
            nowPlayingEntry: seededNowPlaying,
            playedHistory: [],
            removedTimestamps: [:],
            consumedEntryIDs: [:],
            appliedEventIDs: [],
            knownMembers: [member],
            createdAt: .now,
            lastSyncedAt: .now,
            hostSenderID: deviceSenderID,
            hostName: member,
            guestsCanControlPlayback: guestsCanControl,
            participants: [JamParticipant(id: deviceSenderID, name: member, isHost: true, lastSeenAt: now)],
            kickedSenderIDs: [],
            livePlayback: initialPlayback,
            isEnded: false
        )
        parties.insert(party, at: 0)
        activePartyID = party.id
        installJamExternalQueueHandlers(for: party.id)
        saveParties()

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: member,
            timestamp: now,
            kind: .createParty,
            partyName: finalName,
            nowPlayingEntry: seededNowPlaying,
            members: [member],
            hostSenderID: deviceSenderID,
            hostName: member,
            guestsCanControlPlayback: guestsCanControl,
            playbackState: initialPlayback
        )
        applyEvent(evt, serverTime: nil, toPartyID: party.id)
        startBonjourAdvertising(for: party)
        startHostSyncLoopIfNeeded(for: party.id)
        await publishEvent(evt, topic: Self.topicName(forCode: code))
        return parties.first(where: { $0.id == party.id }) ?? party
    }

    @discardableResult
    func joinParty(input: String) async -> PartyQueueSession? {
        lastSyncError = nil
        guard let parsed = GroupPlaylistService.parseInviteInput(input) else {
            lastSyncError = "Enter a valid 8-character Jam Code or Invite Link."
            return nil
        }

        if let existing = parties.first(where: { GroupPlaylistService.normalizeCode($0.code) == parsed.code }) {
            pendingOpenPartyID = existing.id
            activePartyID = existing.id
            await refreshParty(id: existing.id)
            return parties.first(where: { $0.id == existing.id }) ?? existing
        }

        let initialName = parsed.name?.isEmpty == false ? parsed.name! : "Jam \(String(parsed.code.prefix(4)))"
        let member = currentMemberName
        let now = Date().timeIntervalSince1970
        let party = PartyQueueSession(
            id: UUID(),
            code: parsed.code,
            name: initialName,
            upNext: [],
            nowPlayingEntry: nil,
            playedHistory: [],
            removedTimestamps: [:],
            consumedEntryIDs: [:],
            appliedEventIDs: [],
            knownMembers: [member],
            createdAt: .now,
            lastSyncedAt: nil,
            hostSenderID: nil,
            hostName: nil,
            guestsCanControlPlayback: true,
            participants: [JamParticipant(id: deviceSenderID, name: member, isHost: false, lastSeenAt: now)],
            kickedSenderIDs: [],
            livePlayback: nil,
            isEnded: false
        )
        parties.insert(party, at: 0)
        saveParties()
        pendingOpenPartyID = party.id
        activePartyID = party.id

        await refreshParty(id: party.id)

        if let fresh = parties.first(where: { $0.id == party.id }), fresh.kickedSenderIDs?.contains(deviceSenderID) == true {
            parties.removeAll { $0.id == party.id }
            saveParties()
            pendingOpenPartyID = nil
            activePartyID = nil
            lastSyncError = "You were removed from this Jam by the host."
            return nil
        }

        let updated = parties.first(where: { $0.id == party.id })
        let isEmptyRoom = (updated?.upNext.isEmpty ?? true) && (updated?.nowPlayingEntry == nil)
        let joinEvt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: member,
            timestamp: now,
            kind: .joinPresence,
            needsSnapshot: isEmptyRoom
        )
        applyEvent(joinEvt, serverTime: nil, toPartyID: party.id)
        await publishEvent(joinEvt, topic: Self.topicName(forCode: parsed.code))
        return parties.first(where: { $0.id == party.id })
    }

    func leaveParty(id: UUID) {
        if let party = parties.first(where: { $0.id == id }) {
            let evt = PartyQueueEventPayload(
                id: UUID(),
                senderID: deviceSenderID,
                senderName: currentMemberName,
                timestamp: Date().timeIntervalSince1970,
                kind: .leaveParty,
                targetSenderID: deviceSenderID
            )
            let topic = Self.topicName(forCode: party.code)
            Task { await self.publishEvent(evt, topic: topic) }
        }
        if observedPartyID == id {
            stopObservingParty()
        }
        if isHost(of: id) {
            stopBonjourAdvertising()
        }
        parties.removeAll { $0.id == id }
        saveParties()
        if activePartyID == id {
            activePartyID = nil
            hostSyncLoopTask?.cancel()
            hostSyncLoopTask = nil
            MediaManager.shared.externalQueueNextHandler = nil
            MediaManager.shared.externalQueuePreviousHandler = nil
        }
    }

    func endJamForEveryone(id: UUID) {
        guard isHost(of: id), let party = parties.first(where: { $0.id == id }) else {
            leaveParty(id: id)
            return
        }
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .endJam
        )
        let topic = Self.topicName(forCode: party.code)
        Task { await self.publishEvent(evt, topic: topic) }
        leaveParty(id: id)
    }

    func kickParticipant(_ participantID: String, from partyID: UUID) {
        guard isHost(of: partyID), participantID != deviceSenderID,
              let party = parties.first(where: { $0.id == partyID }) else { return }
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .kickMember,
            targetSenderID: participantID
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        Task { await publishEvent(evt, topic: Self.topicName(forCode: party.code)) }
    }

    func setGuestsCanControl(_ enabled: Bool, in partyID: UUID) {
        guard isHost(of: partyID), let party = parties.first(where: { $0.id == partyID }) else { return }
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .setGuestControl,
            guestsCanControlPlayback: enabled
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        Task { await publishEvent(evt, topic: Self.topicName(forCode: party.code)) }
    }

    func renameParty(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let party = parties.first(where: { $0.id == id }) else { return }

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .renameParty,
            partyName: trimmed
        )
        applyEvent(evt, serverTime: nil, toPartyID: id)
        if isHost(of: id), let updated = parties.first(where: { $0.id == id }) {
            startBonjourAdvertising(for: updated)
        }
        Task {
            await publishEvent(evt, topic: Self.topicName(forCode: party.code))
        }
    }

    // MARK: - Queueing, Reordering & Blend Actions

    func queueLocalItem(_ item: MediaItem, to partyID: UUID, silent: Bool = false) {
        guard let party = parties.first(where: { $0.id == partyID }) else { return }
        let existingVID = MediaManager.shared.sourceVideoID(for: item)
        let cleanArtist = (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let entry = PartyQueueEntry(
            id: UUID(),
            title: item.displayTitle,
            artist: cleanArtist,
            youtubeVideoID: existingVID,
            durationSeconds: item.durationSeconds,
            queuedBy: currentMemberName,
            queuedBySenderID: deviceSenderID,
            localQueuedAt: Date().timeIntervalSince1970,
            serverQueuedAt: nil
        )

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: entry.localQueuedAt,
            kind: .enqueueTrack,
            entry: entry
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        if !silent {
            AppHaptics.light()
            MediaManager.shared.statusMessage = "Added \"\(entry.title)\" to \(party.name)"
        }

        let topic = Self.topicName(forCode: party.code)
        Task {
            await publishEvent(evt, topic: topic)
            if existingVID == nil,
               let resolvedVID = await PlaylistURLImporter.findBestYouTubeVideoID(title: entry.title, artist: entry.artist) {
                MediaManager.shared.setSourceVideoID(resolvedVID, for: item)
                let vidEvt = PartyQueueEventPayload(
                    id: UUID(),
                    senderID: deviceSenderID,
                    senderName: currentMemberName,
                    timestamp: Date().timeIntervalSince1970,
                    kind: .updateEntryVideoID,
                    entryID: entry.id,
                    youtubeVideoID: resolvedVID
                )
                applyEvent(vidEvt, serverTime: nil, toPartyID: partyID)
                await publishEvent(vidEvt, topic: topic)
            }
        }
    }

    func queueSearchedSong(
        title: String,
        artist: String,
        youtubeVideoID: String?,
        durationSeconds: Double?,
        to partyID: UUID
    ) {
        guard let party = parties.first(where: { $0.id == partyID }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let entry = PartyQueueEntry(
            id: UUID(),
            title: cleanTitle,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            youtubeVideoID: youtubeVideoID,
            durationSeconds: durationSeconds,
            queuedBy: currentMemberName,
            queuedBySenderID: deviceSenderID,
            localQueuedAt: now,
            serverQueuedAt: nil
        )

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: now,
            kind: .enqueueTrack,
            entry: entry
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        AppHaptics.light()
        MediaManager.shared.statusMessage = "Added \"\(cleanTitle)\" to \(party.name)"

        let topic = Self.topicName(forCode: party.code)
        Task {
            await publishEvent(evt, topic: topic)
        }
    }

    func requeueHistoryEntry(_ oldEntry: PartyQueueEntry, in partyID: UUID) {
        queueSearchedSong(
            title: oldEntry.title,
            artist: oldEntry.artist,
            youtubeVideoID: oldEntry.youtubeVideoID,
            durationSeconds: oldEntry.durationSeconds,
            to: partyID
        )
    }

    func moveUpNext(from source: IndexSet, to destination: Int, in partyID: UUID) {
        guard canControlPlayback(in: partyID),
              let idx = parties.firstIndex(where: { $0.id == partyID }) else { return }
        var reordered = parties[idx].upNext
        reordered.move(fromOffsets: source, toOffset: destination)
        let orderedIDs = reordered.map(\.id)
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .reorderBlendEntries,
            orderedEntryIDs: orderedIDs
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        let topic = Self.topicName(forCode: parties[idx].code)
        Task { await publishEvent(evt, topic: topic) }
    }

    func blendMyFavorites(into partyID: UUID, maxCount: Int = 5) {
        let favs = MediaManager.shared.favoriteItems
        let pool = favs.isEmpty ? Array(MediaManager.shared.audioItems.shuffled().prefix(maxCount)) : Array(favs.shuffled().prefix(maxCount))
        guard !pool.isEmpty else {
            MediaManager.shared.errorMessage = "No songs in your Favorites or Library to blend yet."
            return
        }
        for item in pool {
            queueLocalItem(item, to: partyID, silent: true)
        }
        AppHaptics.success()
        MediaManager.shared.statusMessage = "Added \(pool.count) songs to Jam Blend"
    }

    func interleaveBlendOrder(in partyID: UUID) {
        guard canControlPlayback(in: partyID),
              let party = parties.first(where: { $0.id == partyID }), party.upNext.count > 1 else { return }

        var buckets: [String: [PartyQueueEntry]] = [:]
        var senderOrder: [String] = []
        for entry in party.upNext {
            let key = entry.queuedBySenderID
            if buckets[key] == nil {
                senderOrder.append(key)
            }
            buckets[key, default: []].append(entry)
        }

        var blended: [PartyQueueEntry] = []
        var progressed = true
        while progressed {
            progressed = false
            for key in senderOrder {
                if var list = buckets[key], !list.isEmpty {
                    blended.append(list.removeFirst())
                    buckets[key] = list
                    progressed = true
                }
            }
        }

        let orderedIDs = blended.map(\.id)
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .reorderBlendEntries,
            orderedEntryIDs: orderedIDs
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        Task {
            await publishEvent(evt, topic: Self.topicName(forCode: party.code))
        }
    }

    func removeEntry(_ entryID: UUID, from partyID: UUID) {
        guard let party = parties.first(where: { $0.id == partyID }) else { return }
        // Guests can always remove tracks they queued themselves, or any track if guest control is enabled.
        let isOwn = party.upNext.first(where: { $0.id == entryID })?.queuedBySenderID == deviceSenderID
        guard isOwn || canControlPlayback(in: partyID) else { return }

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .removeEntry,
            entryID: entryID
        )
        applyEvent(evt, serverTime: nil, toPartyID: partyID)
        Task {
            await publishEvent(evt, topic: Self.topicName(forCode: party.code))
        }
    }

    // MARK: - 1-to-1 Spotify Jam Playback & Live Sync

    func toggleJamPlayPause(in partyID: UUID, downloader: WebMediaDownloader) async {
        guard canControlPlayback(in: partyID),
              let party = parties.first(where: { $0.id == partyID }) else { return }

        if isHost(of: partyID) {
            if MediaManager.shared.currentItem != nil {
                MediaManager.shared.togglePlayPause()
                await broadcastHostPlaybackState(for: partyID)
            } else {
                _ = await startOrAdvanceFIFOPlayback(in: partyID, downloader: downloader)
            }
            return
        }

        let currentlyPlaying = party.livePlayback?.isPlaying ?? false
        let action: JamRemoteAction = currentlyPlaying ? .pause : .play
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .remoteCommand,
            remoteAction: action
        )
        await publishEvent(evt, topic: Self.topicName(forCode: party.code))
    }

    func seekJam(to position: Double, in partyID: UUID) async {
        guard canControlPlayback(in: partyID),
              let party = parties.first(where: { $0.id == partyID }) else { return }
        let clamped = max(0, position)
        if isHost(of: partyID) {
            MediaManager.shared.seek(to: clamped)
            await broadcastHostPlaybackState(for: partyID)
            return
        }
        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .remoteCommand,
            remoteAction: .seek,
            seekPosition: clamped
        )
        await publishEvent(evt, topic: Self.topicName(forCode: party.code))
    }

    func startOrAdvanceFIFOPlayback(
        in partyID: UUID,
        downloader: WebMediaDownloader,
        specificEntry: PartyQueueEntry? = nil
    ) async -> Bool {
        guard let party = parties.first(where: { $0.id == partyID }) else { return false }

        // If a guest with permission taps a specific song or Next while controlling the Jam:
        // update & broadcast so the Host jumps to it too!
        guard let targetEntry = specificEntry ?? party.upNext.first ?? party.nowPlayingEntry else {
            MediaManager.shared.errorMessage = "Jam queue is empty. Add a song first!"
            return false
        }

        activePartyID = partyID
        installJamExternalQueueHandlers(for: partyID)

        if isHost(of: partyID) {
            startBonjourAdvertising(for: party)
            startHostSyncLoopIfNeeded(for: partyID)
        }

        let now = Date().timeIntervalSince1970
        let newState = JamPlaybackState(
            entryID: targetEntry.id,
            title: targetEntry.title,
            artist: targetEntry.artist,
            youtubeVideoID: targetEntry.youtubeVideoID,
            durationSeconds: targetEntry.durationSeconds,
            isPlaying: true,
            positionSeconds: 0,
            playbackRate: MediaManager.shared.playbackRate,
            updatedAt: now,
            updatedBy: currentMemberName
        )

        if party.upNext.contains(where: { $0.id == targetEntry.id }) || isHost(of: partyID) {
            let startEvt = PartyQueueEventPayload(
                id: UUID(),
                senderID: deviceSenderID,
                senderName: currentMemberName,
                timestamp: now,
                kind: .startPlaybackEntry,
                entryID: targetEntry.id,
                playbackState: newState
            )
            applyEvent(startEvt, serverTime: nil, toPartyID: partyID)
            let topic = Self.topicName(forCode: party.code)
            Task { await publishEvent(startEvt, topic: topic) }
        } else if canControlPlayback(in: partyID) {
            let startEvt = PartyQueueEventPayload(
                id: UUID(),
                senderID: deviceSenderID,
                senderName: currentMemberName,
                timestamp: now,
                kind: .startPlaybackEntry,
                entryID: targetEntry.id,
                playbackState: newState
            )
            applyEvent(startEvt, serverTime: nil, toPartyID: partyID)
            let topic = Self.topicName(forCode: party.code)
            Task { await publishEvent(startEvt, topic: topic) }
            if !listenOnThisDevice {
                return true
            }
        }

        if !isHost(of: partyID) && !listenOnThisDevice {
            return true
        }

        let ok = await loadAndPlayEntryLocally(targetEntry, in: partyID, downloader: downloader)
        if ok && isHost(of: partyID) {
            await broadcastHostPlaybackState(for: partyID)
        }
        return ok
    }

    private func installJamExternalQueueHandlers(for partyID: UUID) {
        MediaManager.shared.externalQueueNextHandler = { [weak self] in
            guard let self else { return false }
            Task { @MainActor in
                _ = await self.startOrAdvanceFIFOPlayback(in: partyID, downloader: WebMediaDownloader.shared)
            }
            return true
        }
        MediaManager.shared.externalQueuePreviousHandler = {
            MediaManager.shared.seek(to: 0)
            Task { @MainActor in
                await PartyQueueService.shared.broadcastHostPlaybackState(for: partyID)
            }
            return true
        }
    }

    private func loadAndPlayEntryLocally(
        _ targetEntry: PartyQueueEntry,
        in partyID: UUID,
        downloader: WebMediaDownloader
    ) async -> Bool {
        if let localMatch = matchingLocalItem(for: targetEntry) {
            MediaManager.shared.play(localMatch, inPlaylist: nil, keepExternalQueue: true)
            lastGuestSyncedTrackID = targetEntry.id
            return true
        }

        resolvingEntryID = targetEntry.id
        defer {
            if resolvingEntryID == targetEntry.id {
                resolvingEntryID = nil
            }
        }

        var videoID = targetEntry.youtubeVideoID
        if videoID == nil {
            videoID = await PlaylistURLImporter.findBestYouTubeVideoID(title: targetEntry.title, artist: targetEntry.artist)
            if let videoID {
                let updateEvt = PartyQueueEventPayload(
                    id: UUID(),
                    senderID: deviceSenderID,
                    senderName: currentMemberName,
                    timestamp: Date().timeIntervalSince1970,
                    kind: .updateEntryVideoID,
                    entryID: targetEntry.id,
                    youtubeVideoID: videoID
                )
                applyEvent(updateEvt, serverTime: nil, toPartyID: partyID)
                if let currentParty = parties.first(where: { $0.id == partyID }) {
                    await publishEvent(updateEvt, topic: Self.topicName(forCode: currentParty.code))
                }
            }
        }

        guard let vid = videoID,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(vid)"),
              let resolved = await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
                  for: watchURL,
                  videoID: vid,
                  titleHint: targetEntry.title,
                  authorHint: targetEntry.artist,
                  durationHint: targetEntry.durationSeconds
              ),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not load \"\(targetEntry.title)\"."
            return false
        }

        let audioFirst = resolved.streams.filter { $0.isAudio }
        let directFallback = resolved.streams.filter { !$0.isHLS && !$0.isAudio }
        let preferred = audioFirst.isEmpty ? directFallback : (audioFirst + directFallback)
        guard let primary = preferred.first else { return false }

        let taggedPrimary = DetectedBrowserMedia(
            url: primary.url,
            pairedAudioURL: primary.pairedAudioURL,
            isHLS: primary.isHLS,
            isAudio: primary.isAudio,
            title: targetEntry.title,
            author: targetEntry.artist.isEmpty ? resolved.author : targetEntry.artist,
            qualityLabel: primary.qualityLabel,
            referer: primary.referer,
            customHeaders: primary.customHeaders,
            durationSeconds: resolved.durationSeconds ?? primary.durationSeconds,
            isActivelyPlaying: true
        )

        if autoSavePartyTracks,
           let saved = await downloader.downloadGroupTrackOffline(
               taggedPrimary,
               fallbackStreams: Array(preferred.dropFirst()),
               sourceVideoID: vid
           ) {
            MediaManager.shared.play(saved, inPlaylist: nil, keepExternalQueue: true)
            lastGuestSyncedTrackID = targetEntry.id
            return true
        }

        MediaManager.shared.playRemoteStream(
            url: taggedPrimary.url,
            title: targetEntry.title,
            artist: taggedPrimary.author,
            headers: taggedPrimary.customHeaders,
            isVideo: !taggedPrimary.isAudio,
            keepExternalQueue: true
        )
        lastGuestSyncedTrackID = targetEntry.id
        return true
    }

    func matchingLocalItem(for entry: PartyQueueEntry) -> MediaItem? {
        let items = MediaManager.shared.items
        if let vid = entry.youtubeVideoID, !vid.isEmpty,
           let match = items.first(where: { MediaManager.shared.sourceVideoID(for: $0) == vid }) {
            return match
        }
        let target = normalizedComparable(entry.title)
        guard !target.isEmpty else { return nil }
        return items.first { normalizedComparable($0.displayTitle) == target }
    }

    // MARK: - Host Sync Heartbeat & Guest Playback Alignment

    private func startHostSyncLoopIfNeeded(for partyID: UUID) {
        hostSyncLoopTask?.cancel()
        guard isHost(of: partyID) else { return }
        hostSyncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { break }
                guard self.activePartyID == partyID, self.isHost(of: partyID) else { break }
                await self.broadcastHostPlaybackState(for: partyID)
            }
        }
    }

    func broadcastHostPlaybackState(for partyID: UUID) async {
        guard isHost(of: partyID), let idx = parties.firstIndex(where: { $0.id == partyID }) else { return }
        guard let item = MediaManager.shared.currentItem else { return }

        let now = Date().timeIntervalSince1970
        let existingEntry = parties[idx].nowPlayingEntry
        let entryID: UUID
        if let existingEntry, normalizedComparable(existingEntry.title) == normalizedComparable(item.displayTitle) {
            entryID = existingEntry.id
        } else {
            let freshEntry = PartyQueueEntry(
                id: UUID(),
                title: item.displayTitle,
                artist: (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                youtubeVideoID: MediaManager.shared.sourceVideoID(for: item),
                durationSeconds: MediaManager.shared.duration > 0 ? MediaManager.shared.duration : item.durationSeconds,
                queuedBy: currentMemberName,
                queuedBySenderID: deviceSenderID,
                localQueuedAt: now,
                serverQueuedAt: nil
            )
            parties[idx].nowPlayingEntry = freshEntry
            entryID = freshEntry.id
        }

        let state = JamPlaybackState(
            entryID: entryID,
            title: item.displayTitle,
            artist: (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            youtubeVideoID: MediaManager.shared.sourceVideoID(for: item),
            durationSeconds: MediaManager.shared.duration > 0 ? MediaManager.shared.duration : item.durationSeconds,
            isPlaying: MediaManager.shared.isPlaying,
            positionSeconds: MediaManager.shared.currentTime,
            playbackRate: MediaManager.shared.playbackRate,
            updatedAt: now,
            updatedBy: currentMemberName
        )

        // Only broadcast when track/playState changes OR >4s since last network push to keep bandwidth light.
        let prev = parties[idx].livePlayback
        let trackChanged = prev?.title != state.title || prev?.isPlaying != state.isPlaying
        let driftFromExpected = prev.map { abs($0.estimatedPosition() - state.positionSeconds) > 2.2 } ?? true
        let age = now - (prev?.updatedAt ?? 0)
        guard trackChanged || driftFromExpected || age >= 4.0 else { return }

        parties[idx].livePlayback = state
        saveParties()

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: now,
            kind: .playbackSync,
            nowPlayingEntry: parties[idx].nowPlayingEntry,
            playbackState: state
        )
        await publishEvent(evt, topic: Self.topicName(forCode: parties[idx].code))
    }

    private func applyRemotePlaybackToGuestDevice(_ state: JamPlaybackState, in party: PartyQueueSession) async {
        guard !isHost(of: party.id), listenOnThisDevice, party.isEnded != true else { return }

        let sig = "\(state.entryID?.uuidString ?? state.title)|\(state.isPlaying)|\(Int(state.updatedAt))"
        if sig == lastGuestSyncedSignature { return }
        lastGuestSyncedSignature = sig

        let desiredPos = state.estimatedPosition()
        let isSameTrack: Bool = {
            if let eid = state.entryID, eid == lastGuestSyncedTrackID, MediaManager.shared.currentItem != nil {
                return true
            }
            if let cur = MediaManager.shared.currentItem,
               normalizedComparable(cur.displayTitle) == normalizedComparable(state.title) {
                return true
            }
            return false
        }()

        if !isSameTrack {
            let entry = party.nowPlayingEntry ?? PartyQueueEntry(
                id: state.entryID ?? UUID(),
                title: state.title,
                artist: state.artist,
                youtubeVideoID: state.youtubeVideoID,
                durationSeconds: state.durationSeconds,
                queuedBy: party.hostName ?? "Host",
                queuedBySenderID: party.hostSenderID ?? "",
                localQueuedAt: state.updatedAt,
                serverQueuedAt: nil
            )
            let ok = await loadAndPlayEntryLocally(entry, in: party.id, downloader: WebMediaDownloader.shared)
            if ok {
                if desiredPos > 1.5 {
                    MediaManager.shared.seek(to: desiredPos)
                }
                if !state.isPlaying {
                    MediaManager.shared.pause()
                }
            }
            return
        }

        if state.isPlaying && !MediaManager.shared.isPlaying {
            MediaManager.shared.resume()
        } else if !state.isPlaying && MediaManager.shared.isPlaying {
            MediaManager.shared.pause()
        }

        let localPos = MediaManager.shared.currentTime
        if abs(localPos - desiredPos) > 2.0 {
            MediaManager.shared.seek(to: desiredPos)
        }
    }

    // MARK: - Nearby Wi-Fi Jam Discovery (Bonjour _musejrm-jam._tcp)

    func startBonjourDiscovery() {
        guard bonjourBrowser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_musejrm-jam._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var found: [NearbyJamSession] = []
                for res in results {
                    if case .bonjour(let txt) = res.metadata,
                       let code = txt["code"], !code.isEmpty {
                        let norm = GroupPlaylistService.normalizeCode(code)
                        if self.parties.contains(where: { GroupPlaylistService.normalizeCode($0.code) == norm && self.isHost(of: $0.id) }) {
                            continue
                        }
                        let name = txt["name"] ?? "Nearby Jam"
                        let host = txt["host"] ?? "Friend"
                        if !found.contains(where: { $0.code == norm }) {
                            found.append(NearbyJamSession(id: norm, code: norm, name: name, hostName: host))
                        }
                    }
                }
                self.nearbyJams = found
            }
        }
        browser.start(queue: .main)
        bonjourBrowser = browser
    }

    func stopBonjourDiscovery() {
        bonjourBrowser?.cancel()
        bonjourBrowser = nil
        nearbyJams = []
    }

    private func startBonjourAdvertising(for party: PartyQueueSession) {
        stopBonjourAdvertising()
        guard let listener = try? NWListener(using: .tcp) else { return }
        var txt = NWTXTRecord()
        txt["code"] = party.code
        txt["name"] = party.name
        txt["host"] = currentMemberName
        listener.service = NWListener.Service(
            name: "MuseJRM-\(String(party.code.prefix(4)))",
            type: "_musejrm-jam._tcp",
            domain: nil,
            txtRecord: txt
        )
        listener.newConnectionHandler = { conn in
            conn.cancel()
        }
        listener.start(queue: .main)
        bonjourListener = listener
    }

    private func stopBonjourAdvertising() {
        bonjourListener?.cancel()
        bonjourListener = nil
    }

    // MARK: - Live Relay (ntfy.sh WebSocket + Poll)

    func startObservingParty(id: UUID) {
        if observedPartyID == id, wsTask != nil { return }
        stopObservingParty()
        observedPartyID = id
        if isHost(of: id), let party = parties.first(where: { $0.id == id }) {
            startBonjourAdvertising(for: party)
            if activePartyID == id {
                startHostSyncLoopIfNeeded(for: id)
            }
        }

        liveListenTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshParty(id: id)
            await self.maybeWarmSnapshotIfNeeded(partyID: id)

            while !Task.isCancelled && self.observedPartyID == id {
                await self.runWebSocketLoop(for: id)
                if Task.isCancelled || self.observedPartyID != id { break }
                try? await Task.sleep(for: .seconds(2.0))
                await self.refreshParty(id: id)
            }
        }

        pollLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10.0))
                guard let self, !Task.isCancelled, self.observedPartyID == id else { break }
                await self.refreshParty(id: id)
            }
        }

        participantHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25.0))
                guard let self, !Task.isCancelled, self.observedPartyID == id,
                      let party = self.parties.first(where: { $0.id == id }) else { break }
                let hb = PartyQueueEventPayload(
                    id: UUID(),
                    senderID: self.deviceSenderID,
                    senderName: self.currentMemberName,
                    timestamp: Date().timeIntervalSince1970,
                    kind: .heartbeat
                )
                self.applyEvent(hb, serverTime: nil, toPartyID: id)
                await self.publishEvent(hb, topic: Self.topicName(forCode: party.code))
            }
        }
    }

    func stopObservingParty() {
        observedPartyID = nil
        liveConnectedPartyID = nil
        liveListenTask?.cancel()
        liveListenTask = nil
        pollLoopTask?.cancel()
        pollLoopTask = nil
        participantHeartbeatTask?.cancel()
        participantHeartbeatTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    func refreshParty(id: UUID) async {
        guard let party = parties.first(where: { $0.id == id }) else { return }
        let topic = Self.topicName(forCode: party.code)
        guard let url = URL(string: "https://ntfy.sh/\(topic)/json?poll=1&since=all") else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                processNtfyLine(line, partyID: id)
            }
            if let idx = parties.firstIndex(where: { $0.id == id }) {
                parties[idx].lastSyncedAt = .now
                saveParties()
            }
        } catch {
            // Offline or transient network error
        }
    }

    private func runWebSocketLoop(for partyID: UUID) async {
        guard let party = parties.first(where: { $0.id == partyID }) else { return }
        let topic = Self.topicName(forCode: party.code)
        guard let wsURL = URL(string: "wss://ntfy.sh/\(topic)/ws?since=all") else { return }

        let task = URLSession.shared.webSocketTask(with: wsURL)
        wsTask = task
        task.resume()
        liveConnectedPartyID = partyID

        defer {
            task.cancel(with: .goingAway, reason: nil)
            if wsTask === task { wsTask = nil }
            if liveConnectedPartyID == partyID { liveConnectedPartyID = nil }
        }

        while !Task.isCancelled && observedPartyID == partyID {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    processNtfyLine(text, partyID: partyID)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        processNtfyLine(text, partyID: partyID)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
    }

    private func processNtfyLine(_ line: String, partyID: UUID) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["event"] as? String) == "message",
              let msgStr = envelope["message"] as? String,
              let msgData = msgStr.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PartyQueueEventPayload.self, from: msgData) else {
            return
        }

        let serverTime = (envelope["time"] as? NSNumber)?.doubleValue
        applyEvent(payload, serverTime: serverTime, toPartyID: partyID)

        if payload.kind == .joinPresence && payload.needsSnapshot == true && payload.senderID != deviceSenderID {
            if let party = parties.first(where: { $0.id == partyID }),
               !party.upNext.isEmpty || party.nowPlayingEntry != nil || party.livePlayback != nil {
                let last = lastSnapshotBroadcastByParty[partyID] ?? .distantPast
                if Date().timeIntervalSince(last) > 4 {
                    lastSnapshotBroadcastByParty[partyID] = .now
                    let snapshot = PartyQueueEventPayload(
                        id: UUID(),
                        senderID: deviceSenderID,
                        senderName: currentMemberName,
                        timestamp: Date().timeIntervalSince1970,
                        kind: .snapshot,
                        partyName: party.name,
                        upNext: party.upNext,
                        nowPlayingEntry: party.nowPlayingEntry,
                        playedHistory: Array(party.playedHistory.prefix(30)),
                        removedTimestamps: party.removedTimestamps,
                        consumedEntryIDs: party.consumedEntryIDs,
                        members: party.knownMembers,
                        hostSenderID: party.hostSenderID,
                        hostName: party.hostName,
                        guestsCanControlPlayback: party.allowsGuestControls,
                        playbackState: party.livePlayback
                    )
                    let topic = Self.topicName(forCode: party.code)
                    Task { await self.publishEvent(snapshot, topic: topic) }
                }
            }
        }
    }

    private func maybeWarmSnapshotIfNeeded(partyID: UUID) async {
        guard let party = parties.first(where: { $0.id == partyID }),
              !party.upNext.isEmpty || party.nowPlayingEntry != nil else { return }
        let last = lastSnapshotBroadcastByParty[partyID] ?? .distantPast
        guard Date().timeIntervalSince(last) > 3600 else { return }
        lastSnapshotBroadcastByParty[partyID] = .now

        let snapshot = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: currentMemberName,
            timestamp: Date().timeIntervalSince1970,
            kind: .snapshot,
            partyName: party.name,
            upNext: party.upNext,
            nowPlayingEntry: party.nowPlayingEntry,
            playedHistory: Array(party.playedHistory.prefix(30)),
            removedTimestamps: party.removedTimestamps,
            consumedEntryIDs: party.consumedEntryIDs,
            members: party.knownMembers,
            hostSenderID: party.hostSenderID,
            hostName: party.hostName,
            guestsCanControlPlayback: party.allowsGuestControls,
            playbackState: party.livePlayback
        )
        await publishEvent(snapshot, topic: Self.topicName(forCode: party.code))
    }

    private func publishEvent(_ event: PartyQueueEventPayload, topic: String) async {
        guard let url = URL(string: "https://ntfy.sh/\(topic)"),
              let bodyData = try? JSONEncoder().encode(event) else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 12
        req.setValue("yes", forHTTPHeaderField: "Cache")
        _ = try? await URLSession.shared.data(for: req)
    }

    private func applyEvent(
        _ event: PartyQueueEventPayload,
        serverTime: TimeInterval?,
        toPartyID partyID: UUID
    ) {
        guard let idx = parties.firstIndex(where: { $0.id == partyID }) else { return }

        if event.kind == .enqueueTrack,
           let entry = event.entry,
           let serverTime,
           let localIdx = parties[idx].upNext.firstIndex(where: { $0.id == entry.id }),
           parties[idx].upNext[localIdx].serverQueuedAt == nil {
            parties[idx].upNext[localIdx].serverQueuedAt = serverTime
            sortUpNextFIFO(&parties[idx].upNext)
            saveParties()
        }

        if parties[idx].appliedEventIDs.contains(event.id) {
            return
        }
        parties[idx].appliedEventIDs.append(event.id)
        if parties[idx].appliedEventIDs.count > 600 {
            parties[idx].appliedEventIDs.removeFirst(parties[idx].appliedEventIDs.count - 600)
        }

        let cleanMember = event.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMember.isEmpty && !parties[idx].knownMembers.contains(cleanMember) {
            parties[idx].knownMembers.append(cleanMember)
        }

        // Update participant presence list
        if !event.senderID.isEmpty, event.kind != .leaveParty {
            var plist = parties[idx].participants ?? []
            let isEventHost = (event.hostSenderID ?? parties[idx].hostSenderID) == event.senderID
            if let pIdx = plist.firstIndex(where: { $0.id == event.senderID }) {
                if !cleanMember.isEmpty { plist[pIdx].name = cleanMember }
                plist[pIdx].lastSeenAt = max(plist[pIdx].lastSeenAt, event.timestamp)
                plist[pIdx].isHost = plist[pIdx].isHost || isEventHost
            } else if !cleanMember.isEmpty {
                plist.append(JamParticipant(id: event.senderID, name: cleanMember, isHost: isEventHost, lastSeenAt: event.timestamp))
            }
            parties[idx].participants = plist
        }

        switch event.kind {
        case .createParty:
            if let hostID = event.hostSenderID, !hostID.isEmpty {
                parties[idx].hostSenderID = hostID
                parties[idx].hostName = event.hostName
            }
            if let newName = event.partyName?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
                parties[idx].name = newName
            }
            if let allow = event.guestsCanControlPlayback {
                parties[idx].guestsCanControlPlayback = allow
            }
            if let nowPlaying = event.nowPlayingEntry {
                parties[idx].nowPlayingEntry = nowPlaying
            }
            if let state = event.playbackState {
                parties[idx].livePlayback = state
            }

        case .renameParty:
            if let newName = event.partyName?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
                parties[idx].name = newName
            }

        case .joinPresence, .heartbeat:
            break

        case .leaveParty:
            if let leaver = event.targetSenderID ?? (event.senderID.isEmpty ? nil : event.senderID) {
                parties[idx].participants?.removeAll { $0.id == leaver }
            }

        case .setGuestControl:
            if let allow = event.guestsCanControlPlayback {
                parties[idx].guestsCanControlPlayback = allow
            }

        case .kickMember:
            if let victim = event.targetSenderID {
                var kicked = parties[idx].kickedSenderIDs ?? []
                if !kicked.contains(victim) { kicked.append(victim) }
                parties[idx].kickedSenderIDs = kicked
                parties[idx].participants?.removeAll { $0.id == victim }
                if victim == deviceSenderID {
                    parties[idx].isEnded = true
                    if observedPartyID == partyID { stopObservingParty() }
                    if activePartyID == partyID { activePartyID = nil }
                    lastSyncError = "Removed from \"\(parties[idx].name)\" by the host."
                }
            }

        case .endJam:
            parties[idx].isEnded = true
            if observedPartyID == partyID { stopObservingParty() }
            if activePartyID == partyID { activePartyID = nil }

        case .enqueueTrack:
            guard var entry = event.entry else { break }
            if let serverTime {
                entry.serverQueuedAt = serverTime
            }
            if parties[idx].removedTimestamps[entry.id] != nil || parties[idx].consumedEntryIDs[entry.id] != nil {
                break
            }
            if !parties[idx].upNext.contains(where: { $0.id == entry.id }) {
                parties[idx].upNext.append(entry)
                sortUpNextFIFO(&parties[idx].upNext)
            }

        case .updateEntryVideoID:
            guard let entryID = event.entryID, let vid = event.youtubeVideoID, !vid.isEmpty else { break }
            if let upIdx = parties[idx].upNext.firstIndex(where: { $0.id == entryID }) {
                parties[idx].upNext[upIdx].youtubeVideoID = vid
            }
            if parties[idx].nowPlayingEntry?.id == entryID {
                parties[idx].nowPlayingEntry?.youtubeVideoID = vid
            }
            if let hIdx = parties[idx].playedHistory.firstIndex(where: { $0.id == entryID }) {
                parties[idx].playedHistory[hIdx].youtubeVideoID = vid
            }

        case .removeEntry:
            if let entryID = event.entryID {
                parties[idx].removedTimestamps[entryID] = max(
                    parties[idx].removedTimestamps[entryID] ?? 0,
                    event.timestamp
                )
                parties[idx].upNext.removeAll { $0.id == entryID }
                if parties[idx].nowPlayingEntry?.id == entryID {
                    parties[idx].nowPlayingEntry = nil
                }
            }

        case .startPlaybackEntry:
            guard let entryID = event.entryID else { break }
            parties[idx].consumedEntryIDs[entryID] = max(parties[idx].consumedEntryIDs[entryID] ?? 0, event.timestamp)
            if let previousPlaying = parties[idx].nowPlayingEntry, previousPlaying.id != entryID {
                if !parties[idx].playedHistory.contains(where: { $0.id == previousPlaying.id }) {
                    parties[idx].playedHistory.insert(previousPlaying, at: 0)
                    if parties[idx].playedHistory.count > 40 {
                        parties[idx].playedHistory.removeLast(parties[idx].playedHistory.count - 40)
                    }
                }
            }
            if let foundIdx = parties[idx].upNext.firstIndex(where: { $0.id == entryID }) {
                let target = parties[idx].upNext.remove(at: foundIdx)
                parties[idx].nowPlayingEntry = target
            }
            if let state = event.playbackState {
                parties[idx].livePlayback = state
                let updatedParty = parties[idx]
                if event.senderID != deviceSenderID {
                    if isHost(of: partyID) {
                        if let entry = parties[idx].nowPlayingEntry {
                            Task {
                                _ = await self.loadAndPlayEntryLocally(entry, in: partyID, downloader: WebMediaDownloader.shared)
                                await self.broadcastHostPlaybackState(for: partyID)
                            }
                        }
                    } else if activePartyID == partyID {
                        Task { await self.applyRemotePlaybackToGuestDevice(state, in: updatedParty) }
                    }
                }
            }

        case .playbackSync:
            if let nowEntry = event.nowPlayingEntry {
                parties[idx].nowPlayingEntry = nowEntry
            }
            if let state = event.playbackState {
                let currentUpdated = parties[idx].livePlayback?.updatedAt ?? 0
                if state.updatedAt >= currentUpdated - 0.5 {
                    parties[idx].livePlayback = state
                    let updatedParty = parties[idx]
                    if event.senderID != deviceSenderID && activePartyID == partyID && !isHost(of: partyID) {
                        Task { await self.applyRemotePlaybackToGuestDevice(state, in: updatedParty) }
                    }
                }
            }

        case .remoteCommand:
            guard event.senderID != deviceSenderID,
                  isHost(of: partyID),
                  parties[idx].allowsGuestControls,
                  let action = event.remoteAction else { break }
            Task {
                switch action {
                case .play:
                    MediaManager.shared.resume()
                    await self.broadcastHostPlaybackState(for: partyID)
                case .pause:
                    MediaManager.shared.pause()
                    await self.broadcastHostPlaybackState(for: partyID)
                case .next:
                    _ = await self.startOrAdvanceFIFOPlayback(in: partyID, downloader: WebMediaDownloader.shared)
                case .seek:
                    if let pos = event.seekPosition {
                        MediaManager.shared.seek(to: pos)
                        await self.broadcastHostPlaybackState(for: partyID)
                    }
                }
            }

        case .clearPlayedHistory:
            parties[idx].playedHistory.removeAll()

        case .reorderBlendEntries:
            if let orderedIDs = event.orderedEntryIDs, !orderedIDs.isEmpty {
                let orderMap = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
                parties[idx].upNext.sort { lhs, rhs in
                    let li = orderMap[lhs.id] ?? Int.max
                    let ri = orderMap[rhs.id] ?? Int.max
                    if li != ri { return li < ri }
                    return fifoPrecedes(lhs, rhs)
                }
            }

        case .snapshot:
            if let hostID = event.hostSenderID, !hostID.isEmpty, parties[idx].hostSenderID == nil {
                parties[idx].hostSenderID = hostID
                parties[idx].hostName = event.hostName
            }
            if let allow = event.guestsCanControlPlayback {
                parties[idx].guestsCanControlPlayback = allow
            }
            if let title = event.partyName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               parties[idx].upNext.isEmpty && parties[idx].nowPlayingEntry == nil {
                parties[idx].name = title
            }
            if let remoteMembers = event.members {
                for m in remoteMembers where !m.isEmpty && !parties[idx].knownMembers.contains(m) {
                    parties[idx].knownMembers.append(m)
                }
            }
            if let remoteRemoved = event.removedTimestamps {
                for (id, ts) in remoteRemoved {
                    parties[idx].removedTimestamps[id] = max(parties[idx].removedTimestamps[id] ?? 0, ts)
                }
            }
            if let remoteConsumed = event.consumedEntryIDs {
                for (id, ts) in remoteConsumed {
                    parties[idx].consumedEntryIDs[id] = max(parties[idx].consumedEntryIDs[id] ?? 0, ts)
                }
            }
            if parties[idx].nowPlayingEntry == nil, let remoteNow = event.nowPlayingEntry,
               parties[idx].removedTimestamps[remoteNow.id] == nil {
                parties[idx].nowPlayingEntry = remoteNow
            }
            if let remoteState = event.playbackState, parties[idx].livePlayback == nil {
                parties[idx].livePlayback = remoteState
            }
            if let remoteUpNext = event.upNext {
                for e in remoteUpNext {
                    if parties[idx].removedTimestamps[e.id] != nil || parties[idx].consumedEntryIDs[e.id] != nil {
                        continue
                    }
                    if !parties[idx].upNext.contains(where: { $0.id == e.id }) {
                        parties[idx].upNext.append(e)
                    }
                }
                sortUpNextFIFO(&parties[idx].upNext)
            }
            if let remoteHistory = event.playedHistory {
                for h in remoteHistory where !parties[idx].playedHistory.contains(where: { $0.id == h.id }) {
                    parties[idx].playedHistory.append(h)
                }
            }
        }

        parties[idx].upNext.removeAll { entry in
            parties[idx].removedTimestamps[entry.id] != nil || parties[idx].consumedEntryIDs[entry.id] != nil
        }

        parties[idx].lastSyncedAt = .now
        saveParties()
    }

    private func fifoPrecedes(_ lhs: PartyQueueEntry, _ rhs: PartyQueueEntry) -> Bool {
        if let ls = lhs.serverQueuedAt, let rs = rhs.serverQueuedAt, abs(ls - rs) > 1.5 {
            return ls < rs
        }
        if abs(lhs.localQueuedAt - rhs.localQueuedAt) > 0.0005 {
            return lhs.localQueuedAt < rhs.localQueuedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func sortUpNextFIFO(_ list: inout [PartyQueueEntry]) {
        list.sort { fifoPrecedes($0, $1) }
    }

    // MARK: - Persistence & Helpers

    private var currentMemberName: String {
        let trimmed = GroupPlaylistService.shared.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UIDevice.current.name : trimmed
    }

    private func normalizedComparable(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var persistenceFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("party_queues.json")
    }

    private func saveParties() {
        guard let data = try? JSONEncoder().encode(parties) else { return }
        try? data.write(to: persistenceFileURL, options: [.atomic])
    }

    private func loadParties() {
        guard let data = try? Data(contentsOf: persistenceFileURL),
              let decoded = try? JSONDecoder().decode([PartyQueueSession].self, from: data) else {
            return
        }
        parties = decoded
    }
}
