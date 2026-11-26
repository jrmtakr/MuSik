import Foundation
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
        comps.host = "party"
        comps.queryItems = [
            URLQueryItem(name: "code", value: formattedCode),
            URLQueryItem(name: "name", value: name)
        ]
        return comps.string ?? "musicplayer://party?code=\(formattedCode)"
    }

    var shareMessage: String {
        "Join my live Party Queue / Blend \"\(name)\"!\n\nCode: \(formattedCode)\nLink: \(inviteLinkString)\n\nIn MuseJRM: Playlists -> Party Queue -> Join Code or Link."
    }
}

private enum PartyQueueEventKind: String, Codable {
    case createParty
    case joinPresence
    case renameParty
    case enqueueTrack
    case updateEntryVideoID
    case removeEntry
    case startPlaybackEntry
    case clearPlayedHistory
    case reorderBlendEntries
    case snapshot
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
    var autoSavePartyTracks: Bool {
        didSet {
            UserDefaults.standard.set(autoSavePartyTracks, forKey: Self.autoSaveDefaultsKey)
        }
    }

    @ObservationIgnored private let deviceSenderID: String
    @ObservationIgnored private var observedPartyID: UUID?
    @ObservationIgnored private var wsTask: URLSessionWebSocketTask?
    @ObservationIgnored private var liveListenTask: Task<Void, Never>?
    @ObservationIgnored private var pollLoopTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshotBroadcastByParty: [UUID: Date] = [:]

    private static let senderIDDefaultsKey = "musicplayer.party.senderID"
    private static let autoSaveDefaultsKey = "musicplayer.party.autoSave"

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
        loadParties()
    }

    nonisolated static func topicName(forCode code: String) -> String {
        "mppty_\(GroupPlaylistService.normalizeCode(code).lowercased())"
    }

    // MARK: - Create / Join / Leave

    @discardableResult
    func createParty(name: String) async -> PartyQueueSession {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Party Queue" : cleanName
        let code = GroupPlaylistService.normalizeCode(GroupPlaylistService.generateRoomCode())
        let member = currentMemberName

        let party = PartyQueueSession(
            id: UUID(),
            code: code,
            name: finalName,
            upNext: [],
            nowPlayingEntry: nil,
            playedHistory: [],
            removedTimestamps: [:],
            consumedEntryIDs: [:],
            appliedEventIDs: [],
            knownMembers: [member],
            createdAt: .now,
            lastSyncedAt: .now
        )
        parties.insert(party, at: 0)
        saveParties()

        let evt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: member,
            timestamp: Date().timeIntervalSince1970,
            kind: .createParty,
            partyName: finalName,
            members: [member]
        )
        applyEvent(evt, serverTime: nil, toPartyID: party.id)
        await publishEvent(evt, topic: Self.topicName(forCode: code))
        return parties.first(where: { $0.id == party.id }) ?? party
    }

    @discardableResult
    func joinParty(input: String) async -> PartyQueueSession? {
        lastSyncError = nil
        guard let parsed = GroupPlaylistService.parseInviteInput(input) else {
            lastSyncError = "Enter a valid 8-character Party Code or Invite Link."
            return nil
        }

        if let existing = parties.first(where: { GroupPlaylistService.normalizeCode($0.code) == parsed.code }) {
            pendingOpenPartyID = existing.id
            await refreshParty(id: existing.id)
            return parties.first(where: { $0.id == existing.id }) ?? existing
        }

        let initialName = parsed.name?.isEmpty == false ? parsed.name! : "Party \(String(parsed.code.prefix(4)))"
        let member = currentMemberName
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
            lastSyncedAt: nil
        )
        parties.insert(party, at: 0)
        saveParties()
        pendingOpenPartyID = party.id

        await refreshParty(id: party.id)

        let updated = parties.first(where: { $0.id == party.id })
        let isEmptyRoom = (updated?.upNext.isEmpty ?? true) && (updated?.nowPlayingEntry == nil)
        let joinEvt = PartyQueueEventPayload(
            id: UUID(),
            senderID: deviceSenderID,
            senderName: member,
            timestamp: Date().timeIntervalSince1970,
            kind: .joinPresence,
            needsSnapshot: isEmptyRoom
        )
        applyEvent(joinEvt, serverTime: nil, toPartyID: party.id)
        await publishEvent(joinEvt, topic: Self.topicName(forCode: parsed.code))
        return parties.first(where: { $0.id == party.id })
    }

    func leaveParty(id: UUID) {
        if observedPartyID == id {
            stopObservingParty()
        }
        parties.removeAll { $0.id == id }
        saveParties()
        if activePartyID == id {
            activePartyID = nil
        }
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
        Task {
            await publishEvent(evt, topic: Self.topicName(forCode: party.code))
        }
    }

    // MARK: - First-Come First-Serve Queuing & Blend Actions

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
            MediaManager.shared.statusMessage = "Queued \"\(entry.title)\" in \(party.name)"
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
        MediaManager.shared.statusMessage = "Queued \"\(cleanTitle)\" in \(party.name)"

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
        MediaManager.shared.statusMessage = "Added \(pool.count) songs to Party Blend"
    }

    func interleaveBlendOrder(in partyID: UUID) {
        guard let party = parties.first(where: { $0.id == partyID }), party.upNext.count > 1 else { return }

        // Group currently queued items by sender, then round-robin interleave for a balanced Blend
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

    // MARK: - FIFO Playback

    func startOrAdvanceFIFOPlayback(
        in partyID: UUID,
        downloader: WebMediaDownloader,
        specificEntry: PartyQueueEntry? = nil
    ) async -> Bool {
        guard let party = parties.first(where: { $0.id == partyID }) else { return false }
        guard let targetEntry = specificEntry ?? party.upNext.first ?? party.nowPlayingEntry else {
            MediaManager.shared.errorMessage = "Party queue is empty. Queue a song first!"
            return false
        }

        activePartyID = partyID
        MediaManager.shared.externalQueueNextHandler = { [weak self] in
            guard let self else { return false }
            Task { @MainActor in
                _ = await self.startOrAdvanceFIFOPlayback(in: partyID, downloader: downloader)
            }
            return true
        }
        MediaManager.shared.externalQueuePreviousHandler = {
            MediaManager.shared.seek(to: 0)
            return true
        }

        // Only advance/consume queue when starting an item in upNext
        if party.upNext.contains(where: { $0.id == targetEntry.id }) {
            let startEvt = PartyQueueEventPayload(
                id: UUID(),
                senderID: deviceSenderID,
                senderName: currentMemberName,
                timestamp: Date().timeIntervalSince1970,
                kind: .startPlaybackEntry,
                entryID: targetEntry.id
            )
            applyEvent(startEvt, serverTime: nil, toPartyID: partyID)
            let topic = Self.topicName(forCode: party.code)
            Task {
                await publishEvent(startEvt, topic: topic)
            }
        }

        if let localMatch = matchingLocalItem(for: targetEntry) {
            MediaManager.shared.play(localMatch, inPlaylist: nil, keepExternalQueue: true)
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
              let resolved = await YouTubeStreamResolver.resolveStreams(for: watchURL),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not load \"\(targetEntry.title)\". Advancing queue..."
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

    // MARK: - Live Relay (ntfy.sh WebSocket + Poll)

    func startObservingParty(id: UUID) {
        if observedPartyID == id, wsTask != nil { return }
        stopObservingParty()
        observedPartyID = id

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
    }

    func stopObservingParty() {
        observedPartyID = nil
        liveConnectedPartyID = nil
        liveListenTask?.cancel()
        liveListenTask = nil
        pollLoopTask?.cancel()
        pollLoopTask = nil
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
               !party.upNext.isEmpty || party.nowPlayingEntry != nil {
                let last = lastSnapshotBroadcastByParty[partyID] ?? .distantPast
                if Date().timeIntervalSince(last) > 5 {
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
                        members: party.knownMembers
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
            members: party.knownMembers
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

        // Allow serverTime backfill for own queued track echoed back by ntfy
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

        switch event.kind {
        case .createParty, .renameParty:
            if let newName = event.partyName?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
                parties[idx].name = newName
            }

        case .joinPresence:
            break

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

        // Consistently strip removed or already-consumed tracks after any merge
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
