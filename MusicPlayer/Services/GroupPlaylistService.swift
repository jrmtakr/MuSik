import Foundation
import Observation
import UIKit

struct GroupPlaylistTrack: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var artist: String
    var youtubeVideoID: String?
    var durationSeconds: Double?
    var addedBy: String
    var addedAt: TimeInterval
    var note: String? = nil
    var sticker: String? = nil
    var gifURL: String? = nil

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return MediaTimeFormatter.format(durationSeconds)
    }

    var hasMessageOrSticker: Bool {
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanSticker = sticker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanGif = gifURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !cleanNote.isEmpty || !cleanSticker.isEmpty || !cleanGif.isEmpty
    }
}

struct GroupPlaylistMessage: Identifiable, Hashable, Codable {
    let id: UUID
    var senderID: String
    var senderName: String
    var text: String?
    var sticker: String?
    var gifURL: String? = nil
    var trackID: UUID?
    var trackTitle: String?
    var trackArtist: String?
    var timestamp: TimeInterval

    var hasContent: Bool {
        let cleanText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanSticker = sticker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanGif = gifURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !cleanText.isEmpty || !cleanSticker.isEmpty || !cleanGif.isEmpty
    }
}

enum GroupPlaylistStickerPalette {
    /// Curated iconic TikTok comment/DM secret expression stickers (`[shortcode]`).
    static let presets: [(code: String, label: String)] = [
        ("[wronged]", "Wronged"),
        ("[lovely]", "Lovely"),
        ("[proud]", "Proud"),
        ("[laughwithtears]", "LOL Tears"),
        ("[flushed]", "Flushed"),
        ("[cool]", "Cool"),
        ("[cry]", "Cry"),
        ("[scream]", "Scream"),
        ("[rage]", "Rage"),
        ("[yummy]", "Yummy"),
        ("[thinking]", "Thinking"),
        ("[nap]", "Nap"),
        ("[angel]", "Angel"),
        ("[evil]", "Evil"),
        ("[wicked]", "Wicked"),
        ("[wow]", "Wow")
    ]

    static func displayName(for rawSticker: String) -> String {
        let trimmed = rawSticker.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let hit = presets.first(where: { $0.code == lower }) {
            return hit.label
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return "TikTok Sticker"
        }
        return trimmed
    }

    static func isTikTokCode(_ rawSticker: String) -> Bool {
        let lower = rawSticker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return presets.contains(where: { $0.code == lower })
    }
}

struct GroupPlaylist: Identifiable, Hashable, Codable {
    let id: UUID
    let code: String
    var name: String
    var tracks: [GroupPlaylistTrack] = []
    var messages: [GroupPlaylistMessage] = []
    var removedTrackTimestamps: [UUID: TimeInterval] = [:]
    var appliedEventIDs: [UUID] = []
    var knownMembers: [String] = []
    var createdAt: Date = .now
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case name
        case tracks
        case messages
        case removedTrackTimestamps
        case appliedEventIDs
        case knownMembers
        case createdAt
        case lastSyncedAt
    }

    init(
        id: UUID,
        code: String,
        name: String,
        tracks: [GroupPlaylistTrack] = [],
        messages: [GroupPlaylistMessage] = [],
        removedTrackTimestamps: [UUID: TimeInterval] = [:],
        appliedEventIDs: [UUID] = [],
        knownMembers: [String] = [],
        createdAt: Date = .now,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.tracks = tracks
        self.messages = messages
        self.removedTrackTimestamps = removedTrackTimestamps
        self.appliedEventIDs = appliedEventIDs
        self.knownMembers = knownMembers
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        tracks = try c.decodeIfPresent([GroupPlaylistTrack].self, forKey: .tracks) ?? []
        messages = try c.decodeIfPresent([GroupPlaylistMessage].self, forKey: .messages) ?? []
        removedTrackTimestamps = try c.decodeIfPresent([UUID: TimeInterval].self, forKey: .removedTrackTimestamps) ?? [:]
        appliedEventIDs = try c.decodeIfPresent([UUID].self, forKey: .appliedEventIDs) ?? []
        knownMembers = try c.decodeIfPresent([String].self, forKey: .knownMembers) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    var sortedMessages: [GroupPlaylistMessage] {
        messages.sorted { $0.timestamp < $1.timestamp }
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
        comps.host = "group"
        comps.queryItems = [
            URLQueryItem(name: "code", value: formattedCode),
            URLQueryItem(name: "name", value: name)
        ]
        return comps.string ?? "musicplayer://group?code=\(formattedCode)"
    }

    var shareMessage: String {
        "Join my live Group Playlist \"\(name)\"!\n\nCode: \(formattedCode)\nLink: \(inviteLinkString)\n\nIn MuseJRM: Playlists -> Group Playlists -> Join with Code or Link."
    }
}

private enum GroupPlaylistEventKind: String, Codable {
    case createRoom
    case joinPresence
    case renamePlaylist
    case addTrack
    case updateTrackVideoID
    case removeTrack
    case postMessage
    case snapshot
}

private struct GroupPlaylistEventPayload: Codable {
    let id: UUID
    let senderID: String
    let senderName: String
    let timestamp: TimeInterval
    let kind: GroupPlaylistEventKind
    var playlistName: String?
    var track: GroupPlaylistTrack?
    var trackID: UUID?
    var youtubeVideoID: String?
    var needsSnapshot: Bool?
    var tracks: [GroupPlaylistTrack]?
    var message: GroupPlaylistMessage?
    var messages: [GroupPlaylistMessage]?
    var removedTrackTimestamps: [UUID: TimeInterval]?
    var members: [String]?
}

@MainActor
@Observable
final class GroupPlaylistService {
    static let shared = GroupPlaylistService()

    var groups: [GroupPlaylist] = []
    var userDisplayName: String {
        didSet {
            UserDefaults.standard.set(userDisplayName, forKey: Self.memberNameDefaultsKey)
        }
    }
    var autoSaveIncomingTracks: Bool {
        didSet {
            UserDefaults.standard.set(autoSaveIncomingTracks, forKey: Self.autoSaveDefaultsKey)
        }
    }
    var pendingOpenGroupID: UUID?
    var liveConnectedGroupID: UUID?
    var resolvingTrackID: UUID?
    var activeGroupID: UUID?
    var activeGroupTrackID: UUID?
    var lastSyncError: String?

    @ObservationIgnored private let deviceSenderID: String
    @ObservationIgnored private var observedGroupID: UUID?
    @ObservationIgnored private var wsTask: URLSessionWebSocketTask?
    @ObservationIgnored private var liveListenTask: Task<Void, Never>?
    @ObservationIgnored private var pollLoopTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshotBroadcastByGroup: [UUID: Date] = [:]

    private static let memberNameDefaultsKey = "musicplayer.group.memberName"
    private static let senderIDDefaultsKey = "musicplayer.group.senderID"
    private static let autoSaveDefaultsKey = "musicplayer.group.autoSave"
    nonisolated private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private init() {
        let d = UserDefaults.standard
        if let savedSender = d.string(forKey: Self.senderIDDefaultsKey), !savedSender.isEmpty {
            self.deviceSenderID = savedSender
        } else {
            let fresh = UUID().uuidString
            d.set(fresh, forKey: Self.senderIDDefaultsKey)
            self.deviceSenderID = fresh
        }

        let storedName = d.string(forKey: Self.memberNameDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.userDisplayName = storedName.isEmpty ? UIDevice.current.name : storedName
        self.autoSaveIncomingTracks = d.bool(forKey: Self.autoSaveDefaultsKey)
        loadGroups()
    }

    // MARK: - Code / Link Parsing

    nonisolated static func generateRoomCode() -> String {
        let chars = (0..<8).map { _ in alphabet.randomElement()! }
        return "\(String(chars.prefix(4)))-\(String(chars.suffix(4)))"
    }

    nonisolated static func normalizeCode(_ raw: String) -> String {
        let upper = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return upper
    }

    nonisolated static func topicName(forCode code: String) -> String {
        "mpgp_\(normalizeCode(code).lowercased())"
    }

    nonisolated static func parseInviteInput(_ rawInput: String) -> (code: String, name: String?)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Check if input contains a musicplayer://group?... URL
        if let urlRange = trimmed.range(of: "musicplayer://[^\\s]+", options: .regularExpression),
           let url = URL(string: String(trimmed[urlRange])),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let codeParam = comps.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
            let nameParam = comps.queryItems?.first(where: { $0.name == "name" })?.value
            let norm = normalizeCode(codeParam)
            if norm.count >= 6 {
                return (norm, nameParam?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // Check for formatted pattern XXXX-XXXX inside shared invite text
        if let dashedRange = trimmed.range(of: "\\b[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\\b", options: .regularExpression) {
            let norm = normalizeCode(String(trimmed[dashedRange]))
            if norm.count == 8 {
                return (norm, nil)
            }
        }

        // Fallback to raw alphanumeric code
        let norm = normalizeCode(trimmed)
        if norm.count >= 6 && norm.count <= 16 {
            return (norm, nil)
        }
        return nil
    }

    // MARK: - Create / Join / Leave

    @discardableResult
    func createGroupPlaylist(name: String) async -> GroupPlaylist {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Group Vibes" : cleanName
        let rawCode = Self.generateRoomCode()
        let normCode = Self.normalizeCode(rawCode)
        let sender = normalizedSenderName

        let group = GroupPlaylist(
            id: UUID(),
            code: normCode,
            name: finalName,
            tracks: [],
            removedTrackTimestamps: [:],
            appliedEventIDs: [],
            knownMembers: [sender],
            createdAt: .now,
            lastSyncedAt: .now
        )
        groups.insert(group, at: 0)
        saveGroups()

        let evt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: sender,
            timestamp: Date().timeIntervalSince1970,
            kind: .createRoom,
            playlistName: finalName,
            members: [sender]
        )
        applyEvent(evt, toGroupID: group.id)
        await publishEvent(evt, topic: Self.topicName(forCode: normCode))
        return groups.first(where: { $0.id == group.id }) ?? group
    }

    @discardableResult
    func joinGroupPlaylist(input: String) async -> GroupPlaylist? {
        lastSyncError = nil
        guard let parsed = Self.parseInviteInput(input) else {
            lastSyncError = "Enter a valid 8-character Group Code or Invite Link."
            return nil
        }

        if let existing = groups.first(where: { Self.normalizeCode($0.code) == parsed.code }) {
            pendingOpenGroupID = existing.id
            await refreshGroup(id: existing.id)
            return groups.first(where: { $0.id == existing.id }) ?? existing
        }

        let initialName = (parsed.name?.isEmpty == false ? parsed.name! : "Shared Playlist \(String(parsed.code.prefix(4)))")
        let sender = normalizedSenderName
        let newGroup = GroupPlaylist(
            id: UUID(),
            code: parsed.code,
            name: initialName,
            tracks: [],
            removedTrackTimestamps: [:],
            appliedEventIDs: [],
            knownMembers: [sender],
            createdAt: .now,
            lastSyncedAt: nil
        )
        groups.insert(newGroup, at: 0)
        saveGroups()
        pendingOpenGroupID = newGroup.id

        await refreshGroup(id: newGroup.id)

        let updated = groups.first(where: { $0.id == newGroup.id })
        let joinEvt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: sender,
            timestamp: Date().timeIntervalSince1970,
            kind: .joinPresence,
            needsSnapshot: (updated?.tracks.isEmpty ?? true)
        )
        applyEvent(joinEvt, toGroupID: newGroup.id)
        await publishEvent(joinEvt, topic: Self.topicName(forCode: parsed.code))
        return groups.first(where: { $0.id == newGroup.id })
    }

    func leaveGroupPlaylist(id: UUID) {
        if observedGroupID == id {
            stopObservingGroup()
        }
        groups.removeAll { $0.id == id }
        saveGroups()
        if activeGroupID == id {
            activeGroupID = nil
            activeGroupTrackID = nil
        }
    }

    func renameGroupPlaylist(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let group = groups.first(where: { $0.id == id }) else { return }

        let evt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            timestamp: Date().timeIntervalSince1970,
            kind: .renamePlaylist,
            playlistName: trimmed
        )
        applyEvent(evt, toGroupID: id)
        Task {
            await publishEvent(evt, topic: Self.topicName(forCode: group.code))
        }
    }

    // MARK: - Live Song Mutations & Messages

    var defaultMessageGroup: GroupPlaylist? {
        if let activeGroupID, let active = groups.first(where: { $0.id == activeGroupID }) {
            return active
        }
        return groups.first(where: { !$0.messages.isEmpty }) ?? groups.first
    }

    var totalMessagesCount: Int {
        groups.reduce(0) { $0 + $1.messages.count }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func sendLocalItem(
        _ item: MediaItem,
        to groupID: UUID,
        note: String? = nil,
        sticker: String? = nil,
        gifURL: String? = nil
    ) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let existingVID = MediaManager.shared.sourceVideoID(for: item)
        let cleanArtist = (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = normalizedOptional(note)
        let cleanSticker = normalizedOptional(sticker)
        let cleanGif = normalizedOptional(gifURL)
        let nowTS = Date().timeIntervalSince1970

        let track = GroupPlaylistTrack(
            id: UUID(),
            title: item.displayTitle,
            artist: cleanArtist,
            youtubeVideoID: existingVID,
            durationSeconds: item.durationSeconds,
            addedBy: normalizedSenderName,
            addedAt: nowTS,
            note: cleanNote,
            sticker: cleanSticker,
            gifURL: cleanGif
        )

        var attachedMessage: GroupPlaylistMessage?
        if cleanNote != nil || cleanSticker != nil || cleanGif != nil {
            attachedMessage = GroupPlaylistMessage(
                id: UUID(),
                senderID: deviceSenderID,
                senderName: normalizedSenderName,
                text: cleanNote,
                sticker: cleanSticker,
                gifURL: cleanGif,
                trackID: track.id,
                trackTitle: track.title,
                trackArtist: cleanArtist,
                timestamp: nowTS
            )
        }

        let evt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            timestamp: nowTS,
            kind: .addTrack,
            track: track,
            message: attachedMessage
        )
        applyEvent(evt, toGroupID: groupID)
        MediaManager.shared.statusMessage = "Sent \"\(track.title)\" to \(group.name)"

        let topic = Self.topicName(forCode: group.code)
        Task {
            await publishEvent(evt, topic: topic)
            if existingVID == nil {
                if let resolvedVID = await PlaylistURLImporter.findBestYouTubeVideoID(
                    title: track.title,
                    artist: track.artist
                ) {
                    MediaManager.shared.setSourceVideoID(resolvedVID, for: item)
                    let updateEvt = GroupPlaylistEventPayload(
                        id: UUID(),
                        senderID: deviceSenderID,
                        senderName: normalizedSenderName,
                        timestamp: Date().timeIntervalSince1970,
                        kind: .updateTrackVideoID,
                        trackID: track.id,
                        youtubeVideoID: resolvedVID
                    )
                    applyEvent(updateEvt, toGroupID: groupID)
                    await publishEvent(updateEvt, topic: topic)
                }
            }
        }
    }

    func sendSearchedSong(
        title: String,
        artist: String,
        youtubeVideoID: String?,
        durationSeconds: Double?,
        to groupID: UUID,
        note: String? = nil,
        sticker: String? = nil,
        gifURL: String? = nil
    ) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = normalizedOptional(note)
        let cleanSticker = normalizedOptional(sticker)
        let cleanGif = normalizedOptional(gifURL)
        let nowTS = Date().timeIntervalSince1970

        let track = GroupPlaylistTrack(
            id: UUID(),
            title: cleanTitle,
            artist: cleanArtist,
            youtubeVideoID: youtubeVideoID,
            durationSeconds: durationSeconds,
            addedBy: normalizedSenderName,
            addedAt: nowTS,
            note: cleanNote,
            sticker: cleanSticker,
            gifURL: cleanGif
        )

        var attachedMessage: GroupPlaylistMessage?
        if cleanNote != nil || cleanSticker != nil || cleanGif != nil {
            attachedMessage = GroupPlaylistMessage(
                id: UUID(),
                senderID: deviceSenderID,
                senderName: normalizedSenderName,
                text: cleanNote,
                sticker: cleanSticker,
                gifURL: cleanGif,
                trackID: track.id,
                trackTitle: track.title,
                trackArtist: cleanArtist,
                timestamp: nowTS
            )
        }

        let evt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            timestamp: nowTS,
            kind: .addTrack,
            track: track,
            message: attachedMessage
        )
        applyEvent(evt, toGroupID: groupID)
        MediaManager.shared.statusMessage = "Added \"\(cleanTitle)\" to \(group.name)"

        let topic = Self.topicName(forCode: group.code)
        Task {
            await publishEvent(evt, topic: topic)
        }
    }

    func sendMessage(
        text: String?,
        sticker: String?,
        gifURL: String? = nil,
        attachedTrack: GroupPlaylistTrack? = nil,
        to groupID: UUID
    ) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let cleanText = normalizedOptional(text)
        let cleanSticker = normalizedOptional(sticker)
        let cleanGif = normalizedOptional(gifURL)
        guard cleanText != nil || cleanSticker != nil || cleanGif != nil else { return }

        let nowTS = Date().timeIntervalSince1970
        let msg = GroupPlaylistMessage(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            text: cleanText,
            sticker: cleanSticker,
            gifURL: cleanGif,
            trackID: attachedTrack?.id,
            trackTitle: attachedTrack?.title,
            trackArtist: attachedTrack?.artist,
            timestamp: nowTS
        )

        let evt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            timestamp: nowTS,
            kind: .postMessage,
            message: msg
        )
        applyEvent(evt, toGroupID: groupID)

        let topic = Self.topicName(forCode: group.code)
        Task {
            await publishEvent(evt, topic: topic)
        }
    }

    func removeTrack(_ trackID: UUID, from groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let evt = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            timestamp: Date().timeIntervalSince1970,
            kind: .removeTrack,
            trackID: trackID
        )
        applyEvent(evt, toGroupID: groupID)
        Task {
            await publishEvent(evt, topic: Self.topicName(forCode: group.code))
        }
    }

    // MARK: - Live Relay (ntfy.sh WebSocket + Catch-Up Poll)

    func startObservingGroup(id: UUID) {
        if observedGroupID == id, wsTask != nil {
            return
        }
        stopObservingGroup()
        observedGroupID = id

        liveListenTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshGroup(id: id)
            await self.maybeWarmSnapshotIfNeeded(groupID: id)

            while !Task.isCancelled && self.observedGroupID == id {
                await self.runWebSocketLoop(for: id)
                if Task.isCancelled || self.observedGroupID != id { break }
                try? await Task.sleep(for: .seconds(2.0))
                await self.refreshGroup(id: id)
            }
        }

        pollLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10.0))
                guard let self, !Task.isCancelled, self.observedGroupID == id else { break }
                await self.refreshGroup(id: id)
            }
        }
    }

    func stopObservingGroup() {
        observedGroupID = nil
        liveConnectedGroupID = nil
        liveListenTask?.cancel()
        liveListenTask = nil
        pollLoopTask?.cancel()
        pollLoopTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    func refreshGroup(id: UUID) async {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        let topic = Self.topicName(forCode: group.code)
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
                processNtfyLine(line, groupID: id)
            }
            if let idx = groups.firstIndex(where: { $0.id == id }) {
                groups[idx].lastSyncedAt = .now
                saveGroups()
            }
        } catch {
            // Transient network error while offline
        }
    }

    private func runWebSocketLoop(for groupID: UUID) async {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let topic = Self.topicName(forCode: group.code)
        guard let wsURL = URL(string: "wss://ntfy.sh/\(topic)/ws?since=all") else { return }

        let task = URLSession.shared.webSocketTask(with: wsURL)
        wsTask = task
        task.resume()
        liveConnectedGroupID = groupID

        defer {
            task.cancel(with: .goingAway, reason: nil)
            if wsTask === task {
                wsTask = nil
            }
            if liveConnectedGroupID == groupID {
                liveConnectedGroupID = nil
            }
        }

        while !Task.isCancelled && observedGroupID == groupID {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    processNtfyLine(text, groupID: groupID)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        processNtfyLine(text, groupID: groupID)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
    }

    private func processNtfyLine(_ line: String, groupID: UUID) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["event"] as? String) == "message",
              let msgStr = envelope["message"] as? String,
              let msgData = msgStr.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GroupPlaylistEventPayload.self, from: msgData) else {
            return
        }

        applyEvent(payload, toGroupID: groupID)

        if payload.kind == .joinPresence && payload.needsSnapshot == true && payload.senderID != deviceSenderID {
            if let group = groups.first(where: { $0.id == groupID }),
               (!group.tracks.isEmpty || !group.messages.isEmpty) {
                let last = lastSnapshotBroadcastByGroup[groupID] ?? .distantPast
                if Date().timeIntervalSince(last) > 5 {
                    lastSnapshotBroadcastByGroup[groupID] = .now
                    let snapshot = GroupPlaylistEventPayload(
                        id: UUID(),
                        senderID: deviceSenderID,
                        senderName: normalizedSenderName,
                        timestamp: Date().timeIntervalSince1970,
                        kind: .snapshot,
                        playlistName: group.name,
                        tracks: group.tracks,
                        messages: group.messages,
                        removedTrackTimestamps: group.removedTrackTimestamps,
                        members: group.knownMembers
                    )
                    let topic = Self.topicName(forCode: group.code)
                    Task {
                        await self.publishEvent(snapshot, topic: topic)
                    }
                }
            }
        }
    }

    private func maybeWarmSnapshotIfNeeded(groupID: UUID) async {
        guard let group = groups.first(where: { $0.id == groupID }),
              (!group.tracks.isEmpty || !group.messages.isEmpty) else { return }
        let last = lastSnapshotBroadcastByGroup[groupID] ?? .distantPast
        guard Date().timeIntervalSince(last) > 3600 else { return }
        lastSnapshotBroadcastByGroup[groupID] = .now

        let snapshot = GroupPlaylistEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: normalizedSenderName,
            timestamp: Date().timeIntervalSince1970,
            kind: .snapshot,
            playlistName: group.name,
            tracks: group.tracks,
            messages: group.messages,
            removedTrackTimestamps: group.removedTrackTimestamps,
            members: group.knownMembers
        )
        await publishEvent(snapshot, topic: Self.topicName(forCode: group.code))
    }

    private func publishEvent(_ event: GroupPlaylistEventPayload, topic: String) async {
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

    private func applyEvent(_ event: GroupPlaylistEventPayload, toGroupID groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if groups[idx].appliedEventIDs.contains(event.id) {
            return
        }

        groups[idx].appliedEventIDs.append(event.id)
        if groups[idx].appliedEventIDs.count > 600 {
            groups[idx].appliedEventIDs.removeFirst(groups[idx].appliedEventIDs.count - 600)
        }

        let cleanMember = event.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMember.isEmpty && !groups[idx].knownMembers.contains(cleanMember) {
            groups[idx].knownMembers.append(cleanMember)
        }

        switch event.kind {
        case .createRoom, .renamePlaylist:
            if let newName = event.playlistName?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
                groups[idx].name = newName
            }

        case .joinPresence:
            break

        case .addTrack:
            guard let track = event.track else { break }
            if let removedAt = groups[idx].removedTrackTimestamps[track.id], removedAt >= track.addedAt {
                break
            }
            if !groups[idx].tracks.contains(where: { $0.id == track.id }) {
                groups[idx].tracks.append(track)
                groups[idx].tracks.sort { $0.addedAt < $1.addedAt }
            }
            if let msg = event.message, msg.hasContent,
               !groups[idx].messages.contains(where: { $0.id == msg.id }) {
                groups[idx].messages.append(msg)
                groups[idx].messages.sort { $0.timestamp < $1.timestamp }
            }

        case .updateTrackVideoID:
            if let trackID = event.trackID,
               let vid = event.youtubeVideoID, !vid.isEmpty,
               let tIdx = groups[idx].tracks.firstIndex(where: { $0.id == trackID }) {
                groups[idx].tracks[tIdx].youtubeVideoID = vid
            }

        case .removeTrack:
            if let trackID = event.trackID {
                groups[idx].removedTrackTimestamps[trackID] = max(
                    groups[idx].removedTrackTimestamps[trackID] ?? 0,
                    event.timestamp
                )
                groups[idx].tracks.removeAll { $0.id == trackID }
            }

        case .postMessage:
            if let msg = event.message, msg.hasContent,
               !groups[idx].messages.contains(where: { $0.id == msg.id }) {
                groups[idx].messages.append(msg)
                groups[idx].messages.sort { $0.timestamp < $1.timestamp }
            }

        case .snapshot:
            if let title = event.playlistName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               groups[idx].tracks.isEmpty {
                groups[idx].name = title
            }
            if let remoteMembers = event.members {
                for m in remoteMembers where !m.isEmpty && !groups[idx].knownMembers.contains(m) {
                    groups[idx].knownMembers.append(m)
                }
            }
            if let remoteRemoved = event.removedTrackTimestamps {
                for (tid, ts) in remoteRemoved {
                    groups[idx].removedTrackTimestamps[tid] = max(groups[idx].removedTrackTimestamps[tid] ?? 0, ts)
                }
            }
            if let remoteTracks = event.tracks {
                for t in remoteTracks {
                    if let removedAt = groups[idx].removedTrackTimestamps[t.id], removedAt >= t.addedAt {
                        continue
                    }
                    if !groups[idx].tracks.contains(where: { $0.id == t.id }) {
                        groups[idx].tracks.append(t)
                    }
                }
                groups[idx].tracks.sort { $0.addedAt < $1.addedAt }
            }
            if let remoteMessages = event.messages {
                for m in remoteMessages where m.hasContent {
                    if !groups[idx].messages.contains(where: { $0.id == m.id }) {
                        groups[idx].messages.append(m)
                    }
                }
                groups[idx].messages.sort { $0.timestamp < $1.timestamp }
            }
        }

        // Prune removed items consistently after snapshot merge
        groups[idx].tracks.removeAll { track in
            if let removedAt = groups[idx].removedTrackTimestamps[track.id], removedAt >= track.addedAt {
                return true
            }
            return false
        }

        groups[idx].lastSyncedAt = .now
        saveGroups()
    }

    // MARK: - Playback & Local Matching

    func matchingLocalItem(for track: GroupPlaylistTrack) -> MediaItem? {
        let items = MediaManager.shared.items
        if let vid = track.youtubeVideoID, !vid.isEmpty {
            if let exactByVID = items.first(where: { MediaManager.shared.sourceVideoID(for: $0) == vid }) {
                return exactByVID
            }
        }
        let targetTitle = normalizedComparable(track.title)
        guard !targetTitle.isEmpty else { return nil }
        return items.first { item in
            normalizedComparable(item.displayTitle) == targetTitle
        }
    }

    func playTrack(
        _ track: GroupPlaylistTrack,
        in groupID: UUID,
        downloader: WebMediaDownloader,
        saveOfflineOnly: Bool = false
    ) async -> Bool {
        activeGroupID = groupID
        activeGroupTrackID = track.id

        MediaManager.shared.externalQueueNextHandler = { [weak self] in
            guard let self else { return false }
            return self.stepGroupPlayback(offset: 1, downloader: downloader)
        }
        MediaManager.shared.externalQueuePreviousHandler = { [weak self] in
            guard let self else { return false }
            return self.stepGroupPlayback(offset: -1, downloader: downloader)
        }

        if !saveOfflineOnly, let localMatch = matchingLocalItem(for: track) {
            MediaManager.shared.play(localMatch, inPlaylist: nil, keepExternalQueue: true)
            return true
        }

        resolvingTrackID = track.id
        defer {
            if resolvingTrackID == track.id {
                resolvingTrackID = nil
            }
        }

        var videoID = track.youtubeVideoID
        if videoID == nil {
            videoID = await PlaylistURLImporter.findBestYouTubeVideoID(title: track.title, artist: track.artist)
            if let videoID,
               let idx = groups.firstIndex(where: { $0.id == groupID }),
               let tIdx = groups[idx].tracks.firstIndex(where: { $0.id == track.id }) {
                groups[idx].tracks[tIdx].youtubeVideoID = videoID
                saveGroups()
                let updateEvt = GroupPlaylistEventPayload(
                    id: UUID(),
                    senderID: deviceSenderID,
                    senderName: normalizedSenderName,
                    timestamp: Date().timeIntervalSince1970,
                    kind: .updateTrackVideoID,
                    trackID: track.id,
                    youtubeVideoID: videoID
                )
                await publishEvent(updateEvt, topic: Self.topicName(forCode: groups[idx].code))
            }
        }

        guard let vid = videoID,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(vid)"),
              let resolved = await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
                  for: watchURL,
                  videoID: vid,
                  titleHint: track.title,
                  authorHint: track.artist,
                  durationHint: track.durationSeconds
              ),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not load stream for \"\(track.title)\"."
            return false
        }

        let audioFirst = resolved.streams.filter { $0.isAudio }
        let directFallback = resolved.streams.filter { !$0.isHLS && !$0.isAudio }
        let preferred = audioFirst.isEmpty ? directFallback : (audioFirst + directFallback)
        guard let primary = preferred.first else {
            MediaManager.shared.errorMessage = "No playable audio/video stream found for \"\(track.title)\"."
            return false
        }

        let taggedPrimary = DetectedBrowserMedia(
            url: primary.url,
            pairedAudioURL: primary.pairedAudioURL,
            isHLS: primary.isHLS,
            isAudio: primary.isAudio,
            title: track.title,
            author: track.artist.isEmpty ? resolved.author : track.artist,
            qualityLabel: primary.qualityLabel,
            referer: primary.referer,
            customHeaders: primary.customHeaders,
            durationSeconds: resolved.durationSeconds ?? primary.durationSeconds,
            isActivelyPlaying: !saveOfflineOnly
        )

        if saveOfflineOnly || autoSaveIncomingTracks {
            var localOrSaved: MediaItem? = matchingLocalItem(for: track)
            if localOrSaved == nil {
                localOrSaved = await downloader.downloadGroupTrackOffline(
                    taggedPrimary,
                    fallbackStreams: Array(preferred.dropFirst()),
                    sourceVideoID: vid
                )
            }
            if !saveOfflineOnly, let savedItem = localOrSaved {
                MediaManager.shared.play(savedItem, inPlaylist: nil, keepExternalQueue: true)
                return true
            }
            if saveOfflineOnly {
                return localOrSaved != nil
            }
        }

        MediaManager.shared.playRemoteStream(
            url: taggedPrimary.url,
            title: track.title,
            artist: taggedPrimary.author,
            headers: taggedPrimary.customHeaders,
            isVideo: !taggedPrimary.isAudio,
            keepExternalQueue: true
        )
        return true
    }

    private func stepGroupPlayback(offset: Int, downloader: WebMediaDownloader) -> Bool {
        guard let gid = activeGroupID,
              let group = groups.first(where: { $0.id == gid }),
              !group.tracks.isEmpty else {
            return false
        }

        let currentIdx = activeGroupTrackID.flatMap { tid in group.tracks.firstIndex(where: { $0.id == tid }) } ?? 0
        let count = group.tracks.count
        let nextIdx = ((currentIdx + offset) % count + count) % count
        let nextTrack = group.tracks[nextIdx]

        Task { @MainActor in
            _ = await self.playTrack(nextTrack, in: gid, downloader: downloader, saveOfflineOnly: false)
        }
        return true
    }

    // MARK: - Persistence & Helpers

    private var normalizedSenderName: String {
        let trimmed = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return base.appendingPathComponent("group_playlists.json")
    }

    private func saveGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: persistenceFileURL, options: [.atomic])
    }

    private func loadGroups() {
        guard let data = try? Data(contentsOf: persistenceFileURL),
              let decoded = try? JSONDecoder().decode([GroupPlaylist].self, from: data) else {
            return
        }
        groups = decoded
    }
}
