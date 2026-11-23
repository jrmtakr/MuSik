import Foundation
import Observation
import SwiftUI

enum PlaylistSnapshotTrigger: String, Codable, CaseIterable {
    case baseline
    case manual
    case tracksAdded
    case tracksRemoved
    case reordered
    case renamed
    case imported
    case beforeDelete
    case beforeRestore
    case restored

    var displayTitle: String {
        switch self {
        case .baseline: return "Baseline"
        case .manual: return "Manual Snapshot"
        case .tracksAdded: return "Added Tracks"
        case .tracksRemoved: return "Removed Tracks"
        case .reordered: return "Reordered"
        case .renamed: return "Renamed"
        case .imported: return "Imported / Downloaded"
        case .beforeDelete: return "Deleted Playlist"
        case .beforeRestore: return "Safety Backup"
        case .restored: return "Restored"
        }
    }

    var systemImage: String {
        switch self {
        case .baseline: return "flag.fill"
        case .manual: return "bookmark.fill"
        case .tracksAdded: return "plus.circle.fill"
        case .tracksRemoved: return "minus.circle.fill"
        case .reordered: return "arrow.up.arrow.down"
        case .renamed: return "pencil"
        case .imported: return "arrow.down.circle.fill"
        case .beforeDelete: return "trash.slash.fill"
        case .beforeRestore: return "arrow.uturn.backward.circle.fill"
        case .restored: return "clock.arrow.circlepath"
        }
    }

    var tintColor: Color {
        switch self {
        case .baseline: return .secondary
        case .manual: return .blue
        case .tracksAdded, .imported: return .green
        case .tracksRemoved: return .red
        case .reordered: return .orange
        case .renamed: return .indigo
        case .beforeDelete: return .pink
        case .beforeRestore, .restored: return .purple
        }
    }

    var coalesceWindow: TimeInterval {
        switch self {
        case .tracksAdded, .reordered, .renamed:
            return 20
        case .imported:
            return 45
        default:
            return 0
        }
    }
}

struct PlaylistSnapshotTrack: Identifiable, Hashable, Codable {
    var id: String { key }
    var key: String
    var fileName: String
    var displayTitle: String
    var artist: String?
    var durationSeconds: Double?
    var sourceVideoID: String?
    var isVideo: Bool

    var displaySubtitle: String {
        var parts: [String] = []
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(artist)
        }
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            parts.append(MediaTimeFormatter.format(durationSeconds))
        }
        return parts.isEmpty ? fileName : parts.joined(separator: " • ")
    }
}

struct PlaylistSnapshot: Identifiable, Hashable, Codable {
    let id: UUID
    let playlistID: UUID
    var playlistName: String
    var createdAt: Date
    var label: String
    let trigger: PlaylistSnapshotTrigger
    var tracks: [PlaylistSnapshotTrack]
    var isPinned: Bool
    var note: String?

    var fingerprint: String {
        "\(playlistName)\u{1F}\(tracks.map(\.key).joined(separator: "\n"))"
    }
}

struct PlaylistSnapshotDiff {
    let addedSinceSnapshot: [PlaylistSnapshotTrack]
    let removedSinceSnapshot: [PlaylistSnapshotTrack]
    let commonTracks: [PlaylistSnapshotTrack]
    let reordered: Bool
    let renamedFrom: String?
    let restorableRemovedItems: [(track: PlaylistSnapshotTrack, item: MediaItem)]
    let missingFilesInSnapshot: [PlaylistSnapshotTrack]

    var matchesCurrent: Bool {
        addedSinceSnapshot.isEmpty && removedSinceSnapshot.isEmpty && !reordered && renamedFrom == nil
    }
}

struct ArchivedDeletedPlaylistSummary: Identifiable {
    var id: UUID { playlistID }
    let playlistID: UUID
    let latestName: String
    let latestSnapshot: PlaylistSnapshot
    let totalVersions: Int
}

@Observable
final class PlaylistTimeMachineService {
    static let shared = PlaylistTimeMachineService()

    private static let autoEnabledKey = "musicplayer.playlistSnapshots.autoEnabled"

    var snapshots: [PlaylistSnapshot] = []
    var autoSnapshotsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSnapshotsEnabled, forKey: Self.autoEnabledKey)
        }
    }
    var pendingOpenGlobalSheet = false
    private(set) var storageSizeBytes: Int64 = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var storageFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlist_snapshots.json")
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoEnabledKey) == nil {
            self.autoSnapshotsEnabled = true
        } else {
            self.autoSnapshotsEnabled = UserDefaults.standard.bool(forKey: Self.autoEnabledKey)
        }
        loadFromDisk()
    }

    // MARK: - Queries

    func snapshots(for playlistID: UUID) -> [PlaylistSnapshot] {
        snapshots
            .filter { $0.playlistID == playlistID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func latestSnapshot(for playlistID: UUID) -> PlaylistSnapshot? {
        snapshots(for: playlistID).first
    }

    func snapshotCount(for playlistID: UUID) -> Int {
        snapshots.reduce(0) { $0 + ($1.playlistID == playlistID ? 1 : 0) }
    }

    func archivedDeletedPlaylists(activePlaylistIDs: Set<UUID>) -> [ArchivedDeletedPlaylistSummary] {
        let grouped = Dictionary(grouping: snapshots.filter { !activePlaylistIDs.contains($0.playlistID) }, by: \.playlistID)
        return grouped.compactMap { playlistID, versions in
            let sorted = versions.sorted { $0.createdAt > $1.createdAt }
            guard let newest = sorted.first else { return nil }
            let preferred = sorted.first { !$0.tracks.isEmpty } ?? newest
            return ArchivedDeletedPlaylistSummary(
                playlistID: playlistID,
                latestName: preferred.playlistName,
                latestSnapshot: preferred,
                totalVersions: sorted.count
            )
        }
        .sorted { $0.latestSnapshot.createdAt > $1.latestSnapshot.createdAt }
    }

    // MARK: - Capture & Auto-Versioning

    func ensureBaselinesIfNeeded(
        for playlists: [Playlist],
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) {
        var didAddAny = false
        for playlist in playlists {
            if snapshots.contains(where: { $0.playlistID == playlist.id }) {
                continue
            }
            let tracks = buildSnapshotTracks(for: playlist, items: items, metadataByPath: metadataByPath)
            let snap = PlaylistSnapshot(
                id: UUID(),
                playlistID: playlist.id,
                playlistName: playlist.name,
                createdAt: .now,
                label: "Initial Baseline (\(tracks.count) \(tracks.count == 1 ? "track" : "tracks"))",
                trigger: .baseline,
                tracks: tracks,
                isPinned: false,
                note: nil
            )
            snapshots.insert(snap, at: 0)
            didAddAny = true
        }
        if didAddAny {
            snapshots.sort { $0.createdAt > $1.createdAt }
            scheduleDiskSave()
        }
    }

    func ensurePreChangeCaptured(
        for playlist: Playlist,
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata],
        label: String = "Before Edit"
    ) {
        guard autoSnapshotsEnabled else { return }
        let tracks = buildSnapshotTracks(for: playlist, items: items, metadataByPath: metadataByPath)
        let candidateFingerprint = "\(playlist.name)\u{1F}\(tracks.map(\.key).joined(separator: "\n"))"
        if let latest = latestSnapshot(for: playlist.id), latest.fingerprint == candidateFingerprint {
            return
        }
        let preSnap = PlaylistSnapshot(
            id: UUID(),
            playlistID: playlist.id,
            playlistName: playlist.name,
            createdAt: .now,
            label: label,
            trigger: .baseline,
            tracks: tracks,
            isPinned: false,
            note: nil
        )
        snapshots.insert(preSnap, at: 0)
        applyRetentionPolicy(for: playlist.id)
        scheduleDiskSave()
    }

    @discardableResult
    func recordSnapshot(
        for playlist: Playlist,
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata],
        trigger: PlaylistSnapshotTrigger,
        summary: String,
        isPinned: Bool = false,
        note: String? = nil
    ) -> PlaylistSnapshot? {
        let mustSave = isPinned || trigger == .manual || trigger == .beforeDelete || trigger == .beforeRestore || trigger == .restored
        if !autoSnapshotsEnabled && !mustSave {
            return nil
        }

        let tracks = buildSnapshotTracks(for: playlist, items: items, metadataByPath: metadataByPath)
        let newFingerprint = "\(playlist.name)\u{1F}\(tracks.map(\.key).joined(separator: "\n"))"

        if let latest = latestSnapshot(for: playlist.id) {
            if latest.fingerprint == newFingerprint && !mustSave {
                return latest
            }

            let age = Date().timeIntervalSince(latest.createdAt)
            if trigger.coalesceWindow > 0,
               !latest.isPinned,
               latest.trigger == trigger,
               age >= 0,
               age < trigger.coalesceWindow,
               let globalIdx = snapshots.firstIndex(where: { $0.id == latest.id }) {
                snapshots[globalIdx].playlistName = playlist.name
                snapshots[globalIdx].tracks = tracks
                snapshots[globalIdx].createdAt = .now
                snapshots[globalIdx].label = "\(trigger.displayTitle) (\(tracks.count) \(tracks.count == 1 ? "track" : "tracks"))"
                let updatedSnapshot = snapshots[globalIdx]
                snapshots.sort { $0.createdAt > $1.createdAt }
                scheduleDiskSave()
                return updatedSnapshot
            }
        }

        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = cleanSummary.isEmpty
            ? "\(trigger.displayTitle) (\(tracks.count) \(tracks.count == 1 ? "track" : "tracks"))"
            : cleanSummary

        let created = PlaylistSnapshot(
            id: UUID(),
            playlistID: playlist.id,
            playlistName: playlist.name,
            createdAt: .now,
            label: resolvedLabel,
            trigger: trigger,
            tracks: tracks,
            isPinned: isPinned,
            note: note
        )
        snapshots.insert(created, at: 0)
        applyRetentionPolicy(for: playlist.id)
        if mustSave {
            flushDiskSave()
        } else {
            scheduleDiskSave()
        }
        return created
    }

    @discardableResult
    func createManualSnapshot(
        for playlist: Playlist,
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata],
        label: String = "",
        note: String? = nil
    ) -> PlaylistSnapshot {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracks = buildSnapshotTracks(for: playlist, items: items, metadataByPath: metadataByPath)
        let finalLabel = trimmedLabel.isEmpty
            ? "Checkpoint (\(tracks.count) \(tracks.count == 1 ? "track" : "tracks"))"
            : trimmedLabel

        let created = PlaylistSnapshot(
            id: UUID(),
            playlistID: playlist.id,
            playlistName: playlist.name,
            createdAt: .now,
            label: finalLabel,
            trigger: .manual,
            tracks: tracks,
            isPinned: true,
            note: note
        )
        snapshots.insert(created, at: 0)
        flushDiskSave()
        return created
    }

    @discardableResult
    func captureAllPlaylistsNow(
        playlists: [Playlist],
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata],
        labelPrefix: String = "Manual Full Backup"
    ) -> Int {
        guard !playlists.isEmpty else { return 0 }
        let stamp = Self.shortDateFormatter.string(from: .now)
        for playlist in playlists {
            _ = createManualSnapshot(
                for: playlist,
                items: items,
                metadataByPath: metadataByPath,
                label: "\(labelPrefix) (\(stamp))"
            )
        }
        return playlists.count
    }

    // MARK: - Manage Snapshots

    func togglePin(_ snapshotID: UUID) {
        guard let idx = snapshots.firstIndex(where: { $0.id == snapshotID }) else { return }
        snapshots[idx].isPinned.toggle()
        flushDiskSave()
    }

    func renameSnapshot(_ snapshotID: UUID, label: String, note: String? = nil) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = snapshots.firstIndex(where: { $0.id == snapshotID }) else { return }
        snapshots[idx].label = trimmed
        if let note {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshots[idx].note = trimmedNote.isEmpty ? nil : trimmedNote
        }
        flushDiskSave()
    }

    func deleteSnapshot(_ snapshotID: UUID) {
        snapshots.removeAll { $0.id == snapshotID }
        flushDiskSave()
    }

    @discardableResult
    func clearUnpinnedHistory(for playlistID: UUID? = nil, olderThanDays: Int? = nil) -> Int {
        let cutoff = olderThanDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let before = snapshots.count
        snapshots.removeAll { snap in
            if snap.isPinned { return false }
            if let playlistID, snap.playlistID != playlistID { return false }
            if let cutoff, snap.createdAt >= cutoff { return false }
            return true
        }
        let removed = before - snapshots.count
        if removed > 0 {
            flushDiskSave()
        }
        return removed
    }

    func updatePathReferences(from oldPath: String, to newPath: String) {
        let newFileName = (newPath as NSString).lastPathComponent
        var changed = false
        for sIdx in snapshots.indices {
            for tIdx in snapshots[sIdx].tracks.indices {
                if snapshots[sIdx].tracks[tIdx].key == oldPath {
                    snapshots[sIdx].tracks[tIdx].key = newPath
                    snapshots[sIdx].tracks[tIdx].fileName = newFileName
                    changed = true
                }
            }
        }
        if changed {
            scheduleDiskSave()
        }
    }

    // MARK: - Resolution & Diffing

    func resolveLibraryItem(
        for track: PlaylistSnapshotTrack,
        in items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> MediaItem? {
        if let exact = items.first(where: { $0.relativePath == track.key }) {
            return exact
        }

        let nameMatches = items.filter {
            $0.fileName.compare(track.fileName, options: .caseInsensitive) == .orderedSame
        }
        if nameMatches.count == 1 {
            return nameMatches[0]
        }
        if let first = nameMatches.first {
            return first
        }

        if let vid = track.sourceVideoID, !vid.isEmpty {
            if let byVideoID = items.first(where: { metadataByPath[$0.relativePath]?.sourceVideoID == vid }) {
                return byVideoID
            }
        }

        let targetTitle = track.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetTitle.isEmpty else { return nil }
        let targetArtist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !targetArtist.isEmpty {
            if let exactMeta = items.first(where: {
                $0.displayTitle.compare(targetTitle, options: .caseInsensitive) == .orderedSame &&
                    ($0.artist ?? "").compare(targetArtist, options: .caseInsensitive) == .orderedSame
            }) {
                return exactMeta
            }
        }

        return items.first {
            $0.displayTitle.compare(targetTitle, options: .caseInsensitive) == .orderedSame
        }
    }

    func diff(
        snapshot: PlaylistSnapshot,
        against currentPlaylist: Playlist?,
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> PlaylistSnapshotDiff {
        var missingFiles: [PlaylistSnapshotTrack] = []
        for track in snapshot.tracks {
            if resolveLibraryItem(for: track, in: items, metadataByPath: metadataByPath) == nil {
                missingFiles.append(track)
            }
        }

        guard let currentPlaylist else {
            let restorable: [(track: PlaylistSnapshotTrack, item: MediaItem)] = snapshot.tracks.compactMap { track in
                guard let resolved = resolveLibraryItem(for: track, in: items, metadataByPath: metadataByPath) else {
                    return nil
                }
                return (track, resolved)
            }
            return PlaylistSnapshotDiff(
                addedSinceSnapshot: [],
                removedSinceSnapshot: snapshot.tracks,
                commonTracks: [],
                reordered: false,
                renamedFrom: nil,
                restorableRemovedItems: restorable,
                missingFilesInSnapshot: missingFiles
            )
        }

        let currentTracks = buildSnapshotTracks(for: currentPlaylist, items: items, metadataByPath: metadataByPath)
        let currentIdentities = currentTracks.map { canonicalIdentity(for: $0, items: items, metadataByPath: metadataByPath) }
        let snapshotIdentities = snapshot.tracks.map { canonicalIdentity(for: $0, items: items, metadataByPath: metadataByPath) }

        let currentSet = Set(currentIdentities)
        let snapshotSet = Set(snapshotIdentities)

        var added: [PlaylistSnapshotTrack] = []
        for (idx, track) in currentTracks.enumerated() where !snapshotSet.contains(currentIdentities[idx]) {
            added.append(track)
        }

        var removed: [PlaylistSnapshotTrack] = []
        var common: [PlaylistSnapshotTrack] = []
        var restorable: [(track: PlaylistSnapshotTrack, item: MediaItem)] = []

        for (idx, track) in snapshot.tracks.enumerated() {
            if currentSet.contains(snapshotIdentities[idx]) {
                common.append(track)
            } else {
                removed.append(track)
                if let resolved = resolveLibraryItem(for: track, in: items, metadataByPath: metadataByPath) {
                    restorable.append((track, resolved))
                }
            }
        }

        let currentCommonOrder = currentIdentities.filter { snapshotSet.contains($0) }
        let snapshotCommonOrder = snapshotIdentities.filter { currentSet.contains($0) }
        let isReordered = currentCommonOrder != snapshotCommonOrder
        let renamedFrom = snapshot.playlistName != currentPlaylist.name ? snapshot.playlistName : nil

        return PlaylistSnapshotDiff(
            addedSinceSnapshot: added,
            removedSinceSnapshot: removed,
            commonTracks: common,
            reordered: isReordered,
            renamedFrom: renamedFrom,
            restorableRemovedItems: restorable,
            missingFilesInSnapshot: missingFiles
        )
    }

    // MARK: - Missing Track Re-Download & Export

    @MainActor
    func reDownloadMissingTrack(
        _ track: PlaylistSnapshotTrack,
        into playlistID: UUID?,
        downloader: WebMediaDownloader
    ) async -> MediaItem? {
        var videoID = track.sourceVideoID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if videoID == nil || videoID?.isEmpty == true {
            let queryParts = [track.artist ?? "", track.displayTitle]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let query = queryParts.isEmpty ? track.fileName : queryParts.joined(separator: " ")
            let results = await PlaylistURLImporter.searchYouTubeTracks(query: query, limit: 6)
            videoID = results.first?.videoID
        }

        guard let vid = videoID, !vid.isEmpty,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(vid)"),
              let resolved = await YouTubeStreamResolver.resolveStreams(for: watchURL),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not find a downloadable source for \"\(track.displayTitle)\"."
            return nil
        }

        let audioStreams = resolved.streams.filter { $0.isAudio }
        let videoStreams = resolved.streams.filter { !$0.isHLS && !$0.isAudio }
        let preferred = track.isVideo
            ? (videoStreams.isEmpty ? audioStreams : (videoStreams + audioStreams))
            : (audioStreams.isEmpty ? videoStreams : (audioStreams + videoStreams))

        guard let primary = preferred.first else {
            MediaManager.shared.errorMessage = "No playable download stream found for \"\(track.displayTitle)\"."
            return nil
        }

        let taggedPrimary = DetectedBrowserMedia(
            url: primary.url,
            pairedAudioURL: primary.pairedAudioURL,
            isHLS: primary.isHLS,
            isAudio: primary.isAudio,
            title: track.displayTitle,
            author: (track.artist?.isEmpty == false ? track.artist : resolved.author) ?? "",
            qualityLabel: primary.qualityLabel,
            referer: primary.referer,
            customHeaders: primary.customHeaders,
            durationSeconds: resolved.durationSeconds ?? track.durationSeconds ?? primary.durationSeconds,
            isActivelyPlaying: false
        )

        let savedItem = await downloader.downloadGroupTrackOffline(
            taggedPrimary,
            fallbackStreams: Array(preferred.dropFirst()),
            sourceVideoID: vid
        )

        if let savedItem, let playlistID {
            MediaManager.shared.restoreSingleTrackFromTimeMachine(
                savedItem,
                snapshotTrack: track,
                snapshotTracks: [],
                into: playlistID,
                summary: "Re-downloaded \"\(savedItem.displayTitle)\""
            )
        }
        return savedItem
    }

    func exportSnapshotJSON(_ snapshot: PlaylistSnapshot) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return nil }
        let safeName = snapshot.playlistName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = safeName.isEmpty ? "Playlist" : safeName
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-Snapshot-\(Self.fileDateFormatter.string(from: snapshot.createdAt)).json")
        do {
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - Private Builders & Retention

    private func canonicalIdentity(
        for track: PlaylistSnapshotTrack,
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> String {
        if let resolved = resolveLibraryItem(for: track, in: items, metadataByPath: metadataByPath) {
            return "item:\(resolved.relativePath)"
        }
        return "key:\(track.key)"
    }

    private func buildSnapshotTracks(
        for playlist: Playlist,
        items: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> [PlaylistSnapshotTrack] {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let duplicateNames = Set(
            Dictionary(grouping: items, by: \.fileName)
                .filter { $0.value.count > 1 }
                .keys
        )
        let uniqueByName = Dictionary(
            items.filter { !duplicateNames.contains($0.fileName) }.map { ($0.fileName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var previousByKey: [String: PlaylistSnapshotTrack] = [:]
        for snap in snapshots where snap.playlistID == playlist.id {
            for t in snap.tracks where previousByKey[t.key] == nil {
                previousByKey[t.key] = t
            }
        }

        var result: [PlaylistSnapshotTrack] = []
        var seenKeys = Set<String>()

        for rawKey in playlist.itemFileNames {
            if let matched = byPath[rawKey] ?? (!rawKey.contains("/") ? uniqueByName[rawKey] : nil) {
                guard seenKeys.insert(matched.relativePath).inserted else { continue }
                let meta = metadataByPath[matched.relativePath]
                result.append(
                    PlaylistSnapshotTrack(
                        key: matched.relativePath,
                        fileName: matched.fileName,
                        displayTitle: matched.displayTitle,
                        artist: matched.artist,
                        durationSeconds: matched.durationSeconds,
                        sourceVideoID: meta?.sourceVideoID,
                        isVideo: matched.isVideo
                    )
                )
            } else {
                guard seenKeys.insert(rawKey).inserted else { continue }
                if let cached = previousByKey[rawKey] {
                    result.append(cached)
                } else {
                    let ns = rawKey as NSString
                    let fileName = ns.lastPathComponent
                    let ext = ns.pathExtension.lowercased()
                    let title = ns.deletingPathExtension
                    let lastPart = (title as NSString).lastPathComponent
                    result.append(
                        PlaylistSnapshotTrack(
                            key: rawKey,
                            fileName: fileName,
                            displayTitle: lastPart.isEmpty ? fileName : lastPart,
                            artist: nil,
                            durationSeconds: nil,
                            sourceVideoID: nil,
                            isVideo: MediaItem.allVideoExtensions.contains(ext)
                        )
                    )
                }
            }
        }
        return result
    }

    private func applyRetentionPolicy(for playlistID: UUID) {
        let forThis = snapshots
            .filter { $0.playlistID == playlistID }
            .sorted { $0.createdAt > $1.createdAt }
        guard forThis.count > 20 else { return }

        let others = snapshots.filter { $0.playlistID != playlistID }
        let now = Date()
        let cal = Calendar.current

        var kept: [PlaylistSnapshot] = []
        var recentUnpinnedCount = 0
        var keptDayBuckets = Set<Date>()
        var keptWeekBuckets = Set<String>()
        var unpinnedCount = 0

        for snap in forThis {
            if snap.isPinned || snap.trigger == .beforeDelete {
                kept.append(snap)
                continue
            }

            guard unpinnedCount < 120 else { continue }
            let age = now.timeIntervalSince(snap.createdAt)

            if age < 86_400 {
                if recentUnpinnedCount < 20 {
                    kept.append(snap)
                    recentUnpinnedCount += 1
                    unpinnedCount += 1
                }
            } else if age <= 30 * 86_400 {
                let day = cal.startOfDay(for: snap.createdAt)
                if keptDayBuckets.insert(day).inserted {
                    kept.append(snap)
                    unpinnedCount += 1
                }
            } else {
                let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: snap.createdAt)
                let weekKey = "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
                if keptWeekBuckets.insert(weekKey).inserted {
                    kept.append(snap)
                    unpinnedCount += 1
                }
            }
        }

        snapshots = (others + kept).sorted { $0.createdAt > $1.createdAt }
    }

    private func scheduleDiskSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    func flushDiskSave() {
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        try? data.write(to: storageFileURL, options: [.atomic])
        storageSizeBytes = Int64(data.count)
    }

    private func loadFromDisk() {
        let url = storageFileURL
        guard let data = try? Data(contentsOf: url) else {
            storageSizeBytes = 0
            return
        }
        storageSizeBytes = Int64(data.count)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([PlaylistSnapshot].self, from: data) {
            snapshots = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f
    }()
}
