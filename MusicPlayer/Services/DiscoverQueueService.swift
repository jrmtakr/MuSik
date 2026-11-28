import Foundation
import Observation
import UIKit

struct DiscoverPlayedEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let videoID: String?
    let normKey: String
    let title: String
    let artist: String
    var playedAt: Date
}

struct DiscoverQueueItem: Identifiable, Hashable, Sendable {
    enum MediaKind: String, Sendable {
        case song = "Song"
        case video = "Video"
    }

    let id: String
    let videoID: String?
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let durationSeconds: Double?
    let durationText: String?
    let kind: MediaKind
    let localRelativePath: String?
    let relationReason: String
}

/// Curates & auto-plays related songs and music videos for whatever track is currently playing.
/// Powers the `Discover Queue` tab inside `UserQueueContentView` and automatically takes over
/// when `MediaManager.upNextItems` (the user's personal Playing Next queue) is empty.
@MainActor
@Observable
final class DiscoverQueueService {
    static let shared = DiscoverQueueService()

    nonisolated private static let autoPlayDefaultsKey = "musicplayer.discoverQueueAutoPlay"
    private static let remixClientVersion = "1.20250311.01.00"
    private static let webUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private final class PlaybackModeSyncBox: @unchecked Sendable {
        private let lock = NSLock()
        private var playingFromDiscoverQueue = false
        private var autoPlayEnabled: Bool
        private var savedPlaylistID: UUID?

        init(autoPlayEnabled: Bool) {
            self.autoPlayEnabled = autoPlayEnabled
        }

        func snapshotPlayingFromDiscoverQueue() -> Bool {
            lock.lock()
            let val = playingFromDiscoverQueue
            lock.unlock()
            return val
        }

        func setPlayingFromDiscoverQueue(_ value: Bool) {
            lock.lock()
            playingFromDiscoverQueue = value
            if !value {
                savedPlaylistID = nil
            }
            lock.unlock()
        }

        func snapshotAutoPlayEnabled() -> Bool {
            lock.lock()
            let val = autoPlayEnabled
            lock.unlock()
            return val
        }

        func setAutoPlayEnabled(_ value: Bool) {
            lock.lock()
            autoPlayEnabled = value
            lock.unlock()
        }

        func setSavedPlaylistID(_ id: UUID?) {
            lock.lock()
            savedPlaylistID = id
            lock.unlock()
        }

        func exitDiscoverAndConsumeSavedPlaylist() -> UUID? {
            lock.lock()
            playingFromDiscoverQueue = false
            let id = savedPlaylistID
            savedPlaylistID = nil
            lock.unlock()
            return id
        }
    }

    nonisolated private static let syncModeBox = PlaybackModeSyncBox(
        autoPlayEnabled: UserDefaults.standard.object(forKey: autoPlayDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: autoPlayDefaultsKey)
    )

    nonisolated static var isPlayingFromDiscoverQueueSync: Bool {
        syncModeBox.snapshotPlayingFromDiscoverQueue()
    }

    nonisolated static var isAutoPlayEnabledSync: Bool {
        syncModeBox.snapshotAutoPlayEnabled()
    }

    nonisolated static func syncModeForNewTrack(fromDiscoverQueue: Bool) {
        syncModeBox.setPlayingFromDiscoverQueue(fromDiscoverQueue)
    }

    nonisolated static func exitDiscoverModeSync() -> UUID? {
        syncModeBox.exitDiscoverAndConsumeSavedPlaylist()
    }

    var items: [DiscoverQueueItem] = []
    var seedKey: String = ""
    var seedTitle: String = ""
    var seedArtist: String = ""
    var isLoading: Bool = false
    var isResolvingPlayback: Bool = false
    var activePlayingID: String?
    var statusMessage: String?

    /// True whenever playback is actively advancing through Discover Queue instead of the user's
    /// personal Playing Next / playlist queue (preserved intact until the user switches back).
    var isPlayingFromDiscoverQueue: Bool = false {
        didSet {
            Self.syncModeBox.setPlayingFromDiscoverQueue(isPlayingFromDiscoverQueue)
        }
    }
    @ObservationIgnored var savedPlaylistIDBeforeDiscover: UUID? {
        didSet {
            Self.syncModeBox.setSavedPlaylistID(savedPlaylistIDBeforeDiscover)
        }
    }

    var isAutoPlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoPlayEnabled, forKey: Self.autoPlayDefaultsKey)
            Self.syncModeBox.setAutoPlayEnabled(isAutoPlayEnabled)
        }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private(set) var playedEntries: [DiscoverPlayedEntry] = []
    @ObservationIgnored private var playedHistoryIDs: [String] = []
    @ObservationIgnored private var playedNormKeys: Set<String> = []
    @ObservationIgnored private var playedDiscoverStack: [DiscoverQueueItem] = []
    @ObservationIgnored private var usedSeedVideoIDs: Set<String> = []
    @ObservationIgnored private var lastSeedItem: MediaItem?
    @ObservationIgnored private var videoIDCacheByNormKey: [String: String] = [:]
    @ObservationIgnored private var pendingHistorySaveTask: Task<Void, Never>?

    private static var historyFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("discover_played_history.json")
    }

    private static let maxPersistedHistoryCount = 1000

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoPlayDefaultsKey) == nil {
            self.isAutoPlayEnabled = true
        } else {
            self.isAutoPlayEnabled = UserDefaults.standard.bool(forKey: Self.autoPlayDefaultsKey)
        }
        loadPlayedHistoryFromDisk()
    }

    // MARK: - Queue Source Switching (Personal Queue / Playlist <-> Discover Queue)

    func enterDiscoverPlaybackMode(preservingPlaylistID playlistID: UUID?) {
        if !isPlayingFromDiscoverQueue {
            savedPlaylistIDBeforeDiscover = playlistID
        }
        isPlayingFromDiscoverQueue = true
    }

    func switchToPersonalQueue(playNextNow: Bool = false, restorePlaylistID: Bool = true) {
        let mm = MediaManager.shared
        isPlayingFromDiscoverQueue = false
        if restorePlaylistID, let saved = savedPlaylistIDBeforeDiscover {
            mm.activePlaylistID = saved
        }
        savedPlaylistIDBeforeDiscover = nil
        if playNextNow {
            mm.playNext(fromQueueOnly: false)
        }
    }

    func switchToDiscoverQueue(playNextNow: Bool = false) {
        enterDiscoverPlaybackMode(preservingPlaylistID: MediaManager.shared.activePlaylistID)
        if let current = MediaManager.shared.currentItem, items.isEmpty && !isLoading {
            refreshIfNeeded(for: current, force: true)
        }
        if playNextNow {
            let seed = MediaManager.shared.currentItem
            Task { @MainActor in
                _ = await playNextAutoDiscover(after: seed)
            }
        }
    }

    // MARK: - Playback Tracking & Auto-Refresh

    var visibleItems: [DiscoverQueueItem] {
        items.filter { !isCurrentOrPlayed($0) }
    }

    func isCurrentOrPlayed(_ candidate: DiscoverQueueItem) -> Bool {
        let exclusionIDs = currentExclusionIDs(including: lastSeedItem)
        if exclusionIDs.contains(candidate.id) { return true }
        if let vid = candidate.videoID, !vid.isEmpty, exclusionIDs.contains(vid) { return true }
        if let rel = candidate.localRelativePath, !rel.isEmpty, exclusionIDs.contains("local:\(rel)") { return true }
        if let current = MediaManager.shared.currentItem, matches(candidate, item: current) {
            return true
        }
        let norm = Self.normalizedTrackKey(title: candidate.title, artist: candidate.artist)
        if !norm.isEmpty && playedNormKeys.contains(norm) {
            return true
        }
        return false
    }

    func handleNowPlayingChanged(to item: MediaItem, fromDiscoverQueue: Bool = false) {
        let key = trackKey(for: item)
        recordPlayedTrack(item)
        if !fromDiscoverQueue {
            lastSeedItem = item
        }

        let activeID = fromDiscoverQueue ? activePlayingID : nil
        items.removeAll { candidate in
            if let activeID, candidate.id == activeID { return true }
            return matches(candidate, item: item)
        }

        if fromDiscoverQueue {
            isPlayingFromDiscoverQueue = true
            if items.isEmpty {
                Task { @MainActor [weak self] in
                    await self?.discoverMore()
                }
            }
        } else {
            isPlayingFromDiscoverQueue = false
            savedPlaylistIDBeforeDiscover = nil
            if key != seedKey {
                refreshIfNeeded(for: item, force: true)
            } else if items.isEmpty {
                refreshIfNeeded(for: item, force: true)
            }
        }
    }

    func refreshIfNeeded(for item: MediaItem, force: Bool = false) {
        let key = trackKey(for: item)
        if !force && seedKey == key && (!items.isEmpty || isLoading) {
            return
        }

        refreshTask?.cancel()
        seedKey = key
        lastSeedItem = item
        let cleanMeta = cleanedMetadata(for: item)
        seedTitle = cleanMeta.song
        seedArtist = cleanMeta.artist
        statusMessage = nil

        // Populate instant offline related tracks right away so UI & end-of-track transitions work immediately.
        let offlineMatches = buildLocalRelatedItems(for: item, cleanArtist: cleanMeta.artist, cleanTitle: cleanMeta.song)
        items = offlineMatches
        isLoading = true

        let itemID = MediaManager.shared.sourceVideoID(for: item)
        if let itemID, !itemID.isEmpty {
            usedSeedVideoIDs.insert(itemID)
        }
        let capturedItem = item
        let exclusionIDs = currentExclusionIDs(including: item)
        let exclusionNorms = currentExclusionNorms(including: item)

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let fetched = await Self.fetchOnlineRelatedItems(
                for: capturedItem,
                seedVideoID: itemID,
                cleanSong: cleanMeta.song,
                cleanArtist: cleanMeta.artist,
                videoCache: self.videoIDCacheByNormKey,
                excludedIDs: exclusionIDs,
                excludedNorms: exclusionNorms
            )
            guard !Task.isCancelled, self.seedKey == key else { return }

            if let resolvedSeed = fetched.resolvedSeedVideoID, !resolvedSeed.isEmpty {
                let normKey = Self.normalizedTrackKey(title: cleanMeta.song, artist: cleanMeta.artist)
                self.videoIDCacheByNormKey[normKey] = resolvedSeed
                self.usedSeedVideoIDs.insert(resolvedSeed)
                self.appendHistoryID(resolvedSeed)
                if !capturedItem.relativePath.hasPrefix("__remote__/") {
                    MediaManager.shared.setSourceVideoID(resolvedSeed, for: capturedItem)
                }
            }

            let merged = self.mergeOnline(fetched.items, withOffline: offlineMatches, seedItem: capturedItem)
            self.items = merged
            self.isLoading = false
        }
    }

    /// Reloads fresh related songs and music videos while strictly excluding everything that played prior.
    func discoverMore() async {
        let anchorItem = MediaManager.shared.currentItem ?? lastSeedItem
        guard let anchorItem else { return }

        refreshTask?.cancel()
        isLoading = true
        statusMessage = "Discovering more related tracks..."

        // Pick a related un-seeded videoID from the tail of current Discover items (or latest played)
        // so YouTube Music returns a fresh wave instead of repeating the first 50 items.
        let unusedFromQueue = items.reversed().compactMap(\.videoID).first { !usedSeedVideoIDs.contains($0) }
        let unusedFromPlayed = playedDiscoverStack.reversed().compactMap(\.videoID).first { !usedSeedVideoIDs.contains($0) }
        let fallbackVid = MediaManager.shared.sourceVideoID(for: anchorItem)
        let chosenSeedVid = unusedFromQueue ?? unusedFromPlayed ?? fallbackVid

        if let chosenSeedVid, !chosenSeedVid.isEmpty {
            usedSeedVideoIDs.insert(chosenSeedVid)
        }

        let clean = cleanedMetadata(for: anchorItem)
        let offlineMatches = buildLocalRelatedItems(for: anchorItem, cleanArtist: clean.artist, cleanTitle: clean.song)
        let priorShownIDs = Set(items.map(\.id)).union(items.compactMap(\.videoID))
        let baseExcludedIDs = currentExclusionIDs(including: anchorItem)
        let baseExcludedNorms = currentExclusionNorms(including: anchorItem)
        let snapshotHistory = baseExcludedIDs.union(priorShownIDs)

        var fetched = await Self.fetchOnlineRelatedItems(
            for: anchorItem,
            seedVideoID: chosenSeedVid,
            cleanSong: clean.song,
            cleanArtist: clean.artist,
            videoCache: videoIDCacheByNormKey,
            excludedIDs: snapshotHistory,
            excludedNorms: baseExcludedNorms
        )

        // If rotating from the previous wave excluded too many, widen once while still strictly keeping
        // the currently playing song AND all played songs excluded.
        if fetched.items.count < 5 {
            fetched = await Self.fetchOnlineRelatedItems(
                for: anchorItem,
                seedVideoID: unusedFromQueue ?? fallbackVid ?? chosenSeedVid,
                cleanSong: clean.song,
                cleanArtist: clean.artist,
                videoCache: videoIDCacheByNormKey,
                excludedIDs: baseExcludedIDs,
                excludedNorms: baseExcludedNorms
            )
        }

        let merged = mergeOnline(fetched.items, withOffline: offlineMatches, seedItem: anchorItem)
        items = merged
        isLoading = false
        statusMessage = nil
    }

    // MARK: - Playback & Auto-Play

    @discardableResult
    func playItem(_ discoverItem: DiscoverQueueItem) async -> Bool {
        guard !isResolvingPlayback else { return false }
        isResolvingPlayback = true
        activePlayingID = discoverItem.id
        statusMessage = "Starting \(discoverItem.title)..."
        defer {
            isResolvingPlayback = false
            statusMessage = nil
        }

        recordPlayedDiscoverItem(discoverItem)
        items.removeAll { $0.id == discoverItem.id }

        let mm = MediaManager.shared
        enterDiscoverPlaybackMode(preservingPlaylistID: mm.activePlaylistID)
        playedDiscoverStack.append(discoverItem)
        if playedDiscoverStack.count > 40 {
            playedDiscoverStack.removeFirst(playedDiscoverStack.count - 40)
        }

        if let localMatch = findCachedLocalMatch(for: discoverItem, in: mm.items) {
            _ = mm.play(localMatch, inPlaylist: nil, fromDiscoverQueue: true)
            return true
        }

        guard let videoID = discoverItem.videoID,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            return false
        }

        let resolved = await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
            for: watchURL,
            videoID: videoID,
            titleHint: discoverItem.title,
            authorHint: discoverItem.artist,
            durationHint: discoverItem.durationSeconds
        )
        guard let candidateStreams = resolved?.streams, !candidateStreams.isEmpty else {
            return false
        }

        let preferVideo = discoverItem.kind == .video || (mm.currentItem?.isVideo == true)
        let videoProgressive = candidateStreams.filter { !$0.isHLS && !$0.isAudio && $0.pairedAudioURL == nil }
        let hlsStreams = candidateStreams.filter { $0.isHLS }
        let audioStreams = candidateStreams.filter { $0.isAudio && !$0.isHLS }
        let directAny = candidateStreams.filter { !$0.isHLS && $0.pairedAudioURL == nil }

        let chosenStream: DetectedBrowserMedia?
        if preferVideo {
            chosenStream = videoProgressive.first ?? hlsStreams.first ?? directAny.first ?? candidateStreams.first
        } else {
            chosenStream = audioStreams.first ?? videoProgressive.first ?? hlsStreams.first ?? directAny.first ?? candidateStreams.first
        }

        guard let stream = chosenStream else { return false }

        mm.playRemoteStream(
            url: stream.url,
            title: discoverItem.title,
            artist: discoverItem.artist,
            headers: stream.customHeaders,
            isVideo: discoverItem.kind == .video || !stream.isAudio,
            sourceVideoID: videoID,
            artworkURL: discoverItem.artworkURL,
            durationSeconds: discoverItem.durationSeconds ?? resolved?.durationSeconds,
            fromDiscoverQueue: true
        )
        return true
    }

    @discardableResult
    func playPreviousDiscoverItem() async -> Bool {
        guard playedDiscoverStack.count >= 2 else { return false }
        _ = playedDiscoverStack.popLast()
        guard let prev = playedDiscoverStack.popLast() else { return false }
        return await playItem(prev)
    }

    @discardableResult
    func playNextAutoDiscover(after item: MediaItem?) async -> Bool {
        enterDiscoverPlaybackMode(preservingPlaylistID: MediaManager.shared.activePlaylistID)
        if visibleItems.isEmpty {
            if isLoading {
                let deadline = Date().addingTimeInterval(3.5)
                while isLoading && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            if visibleItems.isEmpty {
                await discoverMore()
            }
        }

        for candidate in Array(visibleItems.prefix(4)) {
            if await playItem(candidate) {
                return true
            }
        }
        return false
    }

    func enqueueNext(_ discoverItem: DiscoverQueueItem, downloader: WebMediaDownloader) {
        let mm = MediaManager.shared
        if let local = findCachedLocalMatch(for: discoverItem, in: mm.items) {
            mm.addToNextPlay(local)
            return
        }
        cacheOffline(discoverItem, downloader: downloader, playNextWhenSaved: true)
    }

    func addToPersonalQueue(_ discoverItem: DiscoverQueueItem, downloader: WebMediaDownloader) {
        let mm = MediaManager.shared
        if let local = findCachedLocalMatch(for: discoverItem, in: mm.items) {
            mm.addToQueue(local)
            return
        }
        cacheOffline(discoverItem, downloader: downloader, addToQueueWhenSaved: true)
    }

    func cacheOffline(
        _ discoverItem: DiscoverQueueItem,
        downloader: WebMediaDownloader,
        playNextWhenSaved: Bool = false,
        addToQueueWhenSaved: Bool = false
    ) {
        guard let videoID = discoverItem.videoID,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            return
        }
        statusMessage = "Caching \(discoverItem.title)..."
        Task { @MainActor in
            let resolved = await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
                for: watchURL,
                videoID: videoID,
                titleHint: discoverItem.title,
                authorHint: discoverItem.artist,
                durationHint: discoverItem.durationSeconds
            )
            guard let resolved, !resolved.streams.isEmpty,
                  let primary = (discoverItem.kind == .video
                    ? resolved.streams.first(where: { !$0.isAudio })
                    : resolved.streams.first(where: { $0.isAudio })) ?? resolved.streams.first else {
                MediaManager.shared.errorMessage = "Could not cache \"\(discoverItem.title)\"."
                statusMessage = nil
                return
            }
            let saved = await downloader.downloadGroupTrackOffline(
                primary,
                fallbackStreams: resolved.streams.filter { $0.url != primary.url },
                sourceVideoID: videoID
            )
            statusMessage = nil
            if let saved {
                if playNextWhenSaved {
                    MediaManager.shared.addToNextPlay(saved)
                } else if addToQueueWhenSaved {
                    MediaManager.shared.addToQueue(saved)
                } else {
                    MediaManager.shared.statusMessage = "Saved offline: \(saved.displayTitle)"
                }
            }
        }
    }

    // MARK: - Discovery & Matching Helpers

    private func trackKey(for item: MediaItem) -> String {
        if let vid = MediaManager.shared.sourceVideoID(for: item), !vid.isEmpty {
            return "vid:\(vid)"
        }
        return item.relativePath
    }

    private func cleanedMetadata(for item: MediaItem) -> (song: String, artist: String) {
        let mm = MediaManager.shared
        let rawTitle = item.displayTitle
        let rawArtist = item.artist ?? ""
        let isVerified = mm.isArtistVerified(for: item)
        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: rawArtist.isEmpty ? nil : rawArtist,
            rawTitle: rawTitle,
            fileName: item.fileName,
            ignoredChannels: ListeningWrappedService.shared.ignoredChannels,
            isArtistVerified: isVerified
        )
        let cleanMeta = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: rawTitle,
            rawArtistTag: extracted.primaryArtist.isEmpty ? rawArtist : extracted.primaryArtist
        )
        let song = cleanMeta.songOnly.isEmpty ? rawTitle : cleanMeta.songOnly
        let artist = extracted.primaryArtist.isEmpty ? rawArtist : extracted.primaryArtist
        return (song, artist)
    }

    private func loadPlayedHistoryFromDisk() {
        guard let data = try? Data(contentsOf: Self.historyFileURL),
              let decoded = try? JSONDecoder().decode([DiscoverPlayedEntry].self, from: data) else {
            return
        }
        playedEntries = Array(decoded.prefix(Self.maxPersistedHistoryCount))
        rebuildPlayedLookupTables()
    }

    func flushPlayedHistoryToDisk() {
        pendingHistorySaveTask?.cancel()
        pendingHistorySaveTask = nil
        if let data = try? JSONEncoder().encode(playedEntries) {
            try? data.write(to: Self.historyFileURL, options: [.atomic])
        }
    }

    private func schedulePlayedHistorySave() {
        pendingHistorySaveTask?.cancel()
        let snapshot = playedEntries
        pendingHistorySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.historyFileURL, options: [.atomic])
            }
        }
    }

    private func rebuildPlayedLookupTables() {
        var ids: [String] = []
        var seenIDs = Set<String>()
        var norms = Set<String>()
        for entry in playedEntries {
            if let vid = entry.videoID, !vid.isEmpty, seenIDs.insert(vid).inserted {
                ids.append(vid)
            }
            if seenIDs.insert(entry.id).inserted {
                ids.append(entry.id)
            }
            if !entry.normKey.isEmpty {
                norms.insert(entry.normKey)
            }
        }
        playedHistoryIDs = ids
        playedNormKeys = norms
    }

    func clearPlayedHistory() {
        playedEntries.removeAll()
        playedHistoryIDs.removeAll()
        playedNormKeys.removeAll()
        playedDiscoverStack.removeAll()
        usedSeedVideoIDs.removeAll()
        if let current = MediaManager.shared.currentItem {
            recordPlayedTrack(current)
            refreshIfNeeded(for: current, force: true)
        } else {
            flushPlayedHistoryToDisk()
        }
    }

    private func appendPlayedEntry(
        id: String,
        videoID: String?,
        normKey: String,
        title: String,
        artist: String
    ) {
        let entryID = !id.isEmpty ? id : (!normKey.isEmpty ? "key:\(normKey)" : UUID().uuidString)
        playedEntries.removeAll { existing in
            existing.id == entryID
                || (videoID != nil && !videoID!.isEmpty && existing.videoID == videoID)
                || (!normKey.isEmpty && existing.normKey == normKey)
        }
        playedEntries.insert(
            DiscoverPlayedEntry(
                id: entryID,
                videoID: videoID,
                normKey: normKey,
                title: title,
                artist: artist,
                playedAt: .now
            ),
            at: 0
        )
        if playedEntries.count > Self.maxPersistedHistoryCount {
            playedEntries = Array(playedEntries.prefix(Self.maxPersistedHistoryCount))
        }
        rebuildPlayedLookupTables()
        schedulePlayedHistorySave()
    }

    private func currentExclusionIDs(including seedItem: MediaItem?) -> Set<String> {
        var ids = Set(playedHistoryIDs)
        let mm = MediaManager.shared
        let itemsToExclude = [seedItem, mm.currentItem].compactMap { $0 }
        for track in itemsToExclude {
            if let vid = mm.sourceVideoID(for: track), !vid.isEmpty {
                ids.insert(vid)
            }
            if track.relativePath.hasPrefix("__remote__/") {
                let raw = String(track.relativePath.dropFirst("__remote__/".count))
                if let first = raw.split(separator: "/").first, !first.isEmpty {
                    ids.insert(String(first))
                }
            }
            ids.insert("local:\(track.relativePath)")
        }
        return ids
    }

    private func currentExclusionNorms(including seedItem: MediaItem?) -> Set<String> {
        var norms = playedNormKeys
        let mm = MediaManager.shared
        let itemsToExclude = [seedItem, mm.currentItem].compactMap { $0 }
        for track in itemsToExclude {
            for k in canonicalKeys(for: track) {
                norms.insert(k)
            }
        }
        return norms
    }

    private func canonicalKeys(for item: MediaItem) -> Set<String> {
        var keys = Set<String>()
        let clean = cleanedMetadata(for: item)
        let cleanKey = Self.normalizedTrackKey(title: clean.song, artist: clean.artist)
        if !cleanKey.isEmpty { keys.insert(cleanKey) }
        let rawKey = Self.normalizedTrackKey(title: item.displayTitle, artist: item.artist ?? "")
        if !rawKey.isEmpty { keys.insert(rawKey) }
        return keys
    }

    private func recordPlayedTrack(_ item: MediaItem) {
        let vid = MediaManager.shared.sourceVideoID(for: item)
        if let vid, !vid.isEmpty {
            appendHistoryID(vid)
        }
        let clean = cleanedMetadata(for: item)
        let norm = Self.normalizedTrackKey(title: clean.song, artist: clean.artist)
        let entryID = (vid?.isEmpty == false) ? vid! : (!norm.isEmpty ? "key:\(norm)" : "local:\(item.relativePath)")
        appendPlayedEntry(
            id: entryID,
            videoID: vid,
            normKey: norm,
            title: clean.song.isEmpty ? item.displayTitle : clean.song,
            artist: clean.artist
        )
    }

    private func recordPlayedDiscoverItem(_ discoverItem: DiscoverQueueItem) {
        appendHistoryID(discoverItem.id)
        if let vid = discoverItem.videoID {
            appendHistoryID(vid)
        }
        let norm = Self.normalizedTrackKey(title: discoverItem.title, artist: discoverItem.artist)
        appendPlayedEntry(
            id: discoverItem.id,
            videoID: discoverItem.videoID,
            normKey: norm,
            title: discoverItem.title,
            artist: discoverItem.artist
        )
    }

    private func appendHistoryID(_ id: String) {
        guard !id.isEmpty else { return }
        playedHistoryIDs.removeAll { $0 == id }
        playedHistoryIDs.insert(id, at: 0)
        if playedHistoryIDs.count > Self.maxPersistedHistoryCount {
            playedHistoryIDs = Array(playedHistoryIDs.prefix(Self.maxPersistedHistoryCount))
        }
    }

    private func matches(_ discoverItem: DiscoverQueueItem, item: MediaItem) -> Bool {
        if let vid = discoverItem.videoID,
           !vid.isEmpty,
           let itemVid = MediaManager.shared.sourceVideoID(for: item),
           vid == itemVid {
            return true
        }
        if item.relativePath.hasPrefix("__remote__/"),
           let vid = discoverItem.videoID, !vid.isEmpty,
           item.relativePath.contains(vid) {
            return true
        }
        if let local = discoverItem.localRelativePath, local == item.relativePath {
            return true
        }
        let dNorm = Self.normalizedTrackKey(title: discoverItem.title, artist: discoverItem.artist)
        guard !dNorm.isEmpty else { return false }
        if canonicalKeys(for: item).contains(dNorm) {
            return true
        }
        let dSongOnly = Self.normalizedSongOnlyKey(title: discoverItem.title, artist: discoverItem.artist)
        let iClean = cleanedMetadata(for: item)
        let iSongOnly = Self.normalizedSongOnlyKey(title: iClean.song, artist: iClean.artist)
        let dArtistEmpty = Self.isPlaceholderArtist(discoverItem.artist)
        let iArtistEmpty = Self.isPlaceholderArtist(iClean.artist)
        return !dSongOnly.isEmpty && dSongOnly == iSongOnly && (dArtistEmpty || iArtistEmpty)
    }

    private func findCachedLocalMatch(for discoverItem: DiscoverQueueItem, in library: [MediaItem]) -> MediaItem? {
        if let rel = discoverItem.localRelativePath,
           let direct = library.first(where: { $0.relativePath == rel }) {
            return direct
        }
        if let vid = discoverItem.videoID,
           let byVid = MediaManager.shared.existingMediaItem(forVideoID: vid) {
            return byVid
        }
        let targetKey = Self.normalizedTrackKey(title: discoverItem.title, artist: discoverItem.artist)
        guard !targetKey.isEmpty else { return nil }
        return library.first { cand in
            let clean = cleanedMetadata(for: cand)
            return Self.normalizedTrackKey(title: clean.song, artist: clean.artist) == targetKey
        }
    }

    private func buildLocalRelatedItems(for seed: MediaItem, cleanArtist: String, cleanTitle: String) -> [DiscoverQueueItem] {
        let mm = MediaManager.shared
        let seedGenre = ArtistDatabase.genre(forArtist: cleanArtist)
        let seedArtistKey = ArtistDatabase.normalizeLookupKey(cleanArtist)
        let seedTitleKey = ArtistDatabase.normalizeLookupKey(cleanTitle)

        var scored: [(score: Int, item: MediaItem)] = []
        let exclusionIDs = currentExclusionIDs(including: seed)
        let exclusionNorms = currentExclusionNorms(including: seed)
        let activeCurrent = mm.currentItem
        for cand in mm.items where cand.relativePath != seed.relativePath && cand.relativePath != activeCurrent?.relativePath {
            if let candVid = mm.sourceVideoID(for: cand), exclusionIDs.contains(candVid) { continue }
            if exclusionIDs.contains("local:\(cand.relativePath)") { continue }
            if !canonicalKeys(for: cand).isDisjoint(with: exclusionNorms) { continue }
            let meta = cleanedMetadata(for: cand)
            let candArtistKey = ArtistDatabase.normalizeLookupKey(meta.artist)
            let candTitleKey = ArtistDatabase.normalizeLookupKey(meta.song)
            if candTitleKey == seedTitleKey && candArtistKey == seedArtistKey { continue }

            var score = 0
            if !seedArtistKey.isEmpty && candArtistKey == seedArtistKey {
                score += 100
            } else if let sg = seedGenre,
                      let cg = ArtistDatabase.genre(forArtist: meta.artist),
                      sg.caseInsensitiveCompare(cg) == .orderedSame {
                score += 45
            }
            if cand.isVideo == seed.isVideo { score += 10 }
            if mm.isFavorite(cand) { score += 15 }
            if score > 0 {
                scored.append((score, cand))
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.item.dateAdded > $1.item.dateAdded
        }

        return scored.prefix(12).map { entry in
            let meta = cleanedMetadata(for: entry.item)
            let reason = entry.score >= 100 ? "In Your Library • \(meta.artist)" : "In Your Library • Related"
            return DiscoverQueueItem(
                id: "local:\(entry.item.relativePath)",
                videoID: mm.sourceVideoID(for: entry.item),
                title: meta.song,
                artist: meta.artist.isEmpty ? "Unknown Artist" : meta.artist,
                album: entry.item.album,
                artworkURL: nil,
                durationSeconds: entry.item.durationSeconds,
                durationText: entry.item.formattedDuration,
                kind: entry.item.isVideo ? .video : .song,
                localRelativePath: entry.item.relativePath,
                relationReason: reason
            )
        }
    }

    private func mergeOnline(
        _ online: [DiscoverQueueItem],
        withOffline offline: [DiscoverQueueItem],
        seedItem: MediaItem
    ) -> [DiscoverQueueItem] {
        let mm = MediaManager.shared
        let library = mm.items
        var seenIDs = currentExclusionIDs(including: seedItem)
        var seenNorms = currentExclusionNorms(including: seedItem)
        let activeItems = [seedItem, mm.currentItem].compactMap { $0 }
        let activeSongOnlyKeys = Set(activeItems.map { track in
            let clean = cleanedMetadata(for: track)
            return Self.normalizedSongOnlyKey(title: clean.song, artist: clean.artist)
        }.filter { !$0.isEmpty })

        var result: [DiscoverQueueItem] = []

        func appendIfUnique(_ candidate: DiscoverQueueItem) {
            if seenIDs.contains(candidate.id) { return }
            if let vid = candidate.videoID, !vid.isEmpty {
                guard seenIDs.insert(vid).inserted else { return }
            }
            if let rel = candidate.localRelativePath, !rel.isEmpty {
                if seenIDs.contains("local:\(rel)") { return }
            }
            for active in activeItems where matches(candidate, item: active) {
                return
            }
            let norm = Self.normalizedTrackKey(title: candidate.title, artist: candidate.artist)
            if !norm.isEmpty {
                guard seenNorms.insert(norm).inserted else { return }
            }
            if Self.isPlaceholderArtist(candidate.artist) {
                let songOnly = Self.normalizedSongOnlyKey(title: candidate.title, artist: candidate.artist)
                if !songOnly.isEmpty && activeSongOnlyKeys.contains(songOnly) {
                    return
                }
            }
            if let local = findCachedLocalMatch(for: candidate, in: library),
               candidate.localRelativePath == nil {
                result.append(DiscoverQueueItem(
                    id: candidate.id,
                    videoID: candidate.videoID ?? MediaManager.shared.sourceVideoID(for: local),
                    title: candidate.title,
                    artist: candidate.artist,
                    album: candidate.album ?? local.album,
                    artworkURL: candidate.artworkURL,
                    durationSeconds: candidate.durationSeconds ?? local.durationSeconds,
                    durationText: candidate.durationText ?? local.formattedDuration,
                    kind: local.isVideo ? .video : candidate.kind,
                    localRelativePath: local.relativePath,
                    relationReason: candidate.relationReason
                ))
            } else {
                result.append(candidate)
            }
        }

        for item in online {
            appendIfUnique(item)
        }
        for item in offline where result.count < 35 {
            appendIfUnique(item)
        }
        return result
    }

    // MARK: - Non-Isolated Online YouTube Music Related Mix + Videos

    nonisolated private static func isPlaceholderArtist(_ artist: String) -> Bool {
        let norm = ArtistDatabase.normalizeLookupKey(artist)
        return norm.isEmpty
            || norm == "unknown artist"
            || norm == "youtube music"
            || norm == "youtube video"
            || norm == "various artists"
    }

    nonisolated private static func normalizedSongOnlyKey(title: String, artist: String) -> String {
        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: isPlaceholderArtist(artist) ? nil : artist,
            rawTitle: title,
            isArtistVerified: false
        )
        let effectiveArtist = extracted.primaryArtist.isEmpty ? (isPlaceholderArtist(artist) ? nil : artist) : extracted.primaryArtist
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: title, rawArtistTag: effectiveArtist)
        let song = cleaned.songOnly.isEmpty ? title : cleaned.songOnly
        return ArtistDatabase.normalizeLookupKey(song)
    }

    nonisolated static func normalizedTrackKey(title: String, artist: String) -> String {
        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: isPlaceholderArtist(artist) ? nil : artist,
            rawTitle: title,
            isArtistVerified: false
        )
        let effectiveArtist = extracted.primaryArtist.isEmpty
            ? (isPlaceholderArtist(artist) ? "" : artist)
            : extracted.primaryArtist
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: title,
            rawArtistTag: effectiveArtist.isEmpty ? nil : effectiveArtist
        )
        let resolvedSong = cleaned.songOnly.isEmpty ? title : cleaned.songOnly
        let resolvedArtist = isPlaceholderArtist(effectiveArtist) ? "" : ArtistDatabase.canonicalizeSingle(effectiveArtist)
        let t = ArtistDatabase.normalizeLookupKey(resolvedSong)
        let a = ArtistDatabase.normalizeLookupKey(resolvedArtist)
        if t.isEmpty && a.isEmpty { return "" }
        return "\(t)|\(a)"
    }

    nonisolated private static func fetchOnlineRelatedItems(
        for seedItem: MediaItem,
        seedVideoID: String?,
        cleanSong: String,
        cleanArtist: String,
        videoCache: [String: String],
        excludedIDs: Set<String>,
        excludedNorms: Set<String>
    ) async -> (resolvedSeedVideoID: String?, items: [DiscoverQueueItem]) {
        let cacheKey = normalizedTrackKey(title: cleanSong, artist: cleanArtist)
        var workingVideoID = seedVideoID ?? videoCache[cacheKey]

        if workingVideoID == nil || workingVideoID?.isEmpty == true {
            let query = [cleanArtist, cleanSong]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !query.isEmpty {
                let hits = await PlaylistURLImporter.searchYouTubeTracks(query: query, limit: 3)
                workingVideoID = hits.first?.videoID
            }
        }

        guard let activeVideoID = workingVideoID, !activeVideoID.isEmpty else {
            return (nil, [])
        }

        async let mixTask = fetchYouTubeMusicRadioMix(
            videoID: activeVideoID,
            fallbackArtist: cleanArtist,
            excludedIDs: excludedIDs,
            excludedNorms: excludedNorms
        )
        async let mvTask: [DiscoverQueueItem] = {
            guard !cleanArtist.isEmpty || !cleanSong.isEmpty else { return [] }
            let mvQuery = cleanArtist.isEmpty ? "\(cleanSong) official video" : "\(cleanArtist) \(cleanSong) music video"
            return await fetchRelatedMusicVideos(
                query: mvQuery,
                defaultArtist: cleanArtist,
                excludedIDs: Array(excludedIDs.union([activeVideoID])),
                excludedNorms: excludedNorms
            )
        }()

        let mixItems = await mixTask
        let mvItems = await mvTask

        // Interleave related Music Videos early if the user is watching a video, or mix cleanly after top related tracks.
        var combined: [DiscoverQueueItem] = []
        if seedItem.isVideo {
            combined.append(contentsOf: mvItems.prefix(4))
            combined.append(contentsOf: mixItems)
            combined.append(contentsOf: mvItems.dropFirst(4))
        } else {
            combined.append(contentsOf: mixItems.prefix(3))
            combined.append(contentsOf: mvItems.prefix(3))
            combined.append(contentsOf: mixItems.dropFirst(3))
            combined.append(contentsOf: mvItems.dropFirst(3))
        }

        return (activeVideoID, combined)
    }

    nonisolated private static func fetchYouTubeMusicRadioMix(
        videoID: String,
        fallbackArtist: String,
        excludedIDs: Set<String>,
        excludedNorms: Set<String>
    ) async -> [DiscoverQueueItem] {
        guard let apiURL = URL(string: "https://music.youtube.com/youtubei/v1/next?prettyPrint=false") else {
            return []
        }
        let body: [String: Any] = [
            "videoId": videoID,
            "playlistId": "RDAMVM\(videoID)",
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": remixClientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(webUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(remixClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        var rawPanels: [[String: Any]] = []
        collectPanelRenderers(in: json, into: &rawPanels)

        var out: [DiscoverQueueItem] = []
        for panel in rawPanels {
            guard let vid = panel["videoId"] as? String, !vid.isEmpty else { continue }
            if vid == videoID || excludedIDs.contains(vid) { continue }

            let title = extractText(from: panel["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let shortByline = extractText(from: panel["shortBylineText"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let longByline = extractText(from: panel["longBylineText"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = longByline.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let artist = shortByline.isEmpty ? (parts.first ?? fallbackArtist) : shortByline
            let album = (parts.count >= 2 && !parts[1].isEmpty && parts[1].count > 1) ? parts[1] : nil

            let norm = normalizedTrackKey(title: title, artist: artist)
            if excludedNorms.contains(norm) { continue }

            let durText = extractText(from: panel["lengthText"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let durSec = parseDurationText(durText)
            if let durSec, (durSec < 45 || durSec > 900) { continue }

            let nav = panel["navigationEndpoint"] as? [String: Any]
            let watch = nav?["watchEndpoint"] as? [String: Any]
            let configs = watch?["watchEndpointMusicSupportedConfigs"] as? [String: Any]
            let musicCfg = configs?["watchEndpointMusicConfig"] as? [String: Any]
            let mvType = (musicCfg?["musicVideoType"] as? String) ?? ""
            let isVideo = mvType == "MUSIC_VIDEO_TYPE_OMV" || mvType == "MUSIC_VIDEO_TYPE_UGC"

            let thumbArr = (panel["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let artURL = (thumbArr?.last?["url"] as? String).flatMap(URL.init(string:))

            let reason = isVideo ? "Related Music Video" : "Related • \(artist.isEmpty ? "Up Next" : artist)"
            out.append(DiscoverQueueItem(
                id: vid,
                videoID: vid,
                title: title,
                artist: artist.isEmpty ? "YouTube Music" : artist,
                album: album,
                artworkURL: artURL,
                durationSeconds: durSec,
                durationText: durText.isEmpty ? nil : durText,
                kind: isVideo ? .video : .song,
                localRelativePath: nil,
                relationReason: reason
            ))
        }
        return out
    }

    nonisolated private static func fetchRelatedMusicVideos(
        query: String,
        defaultArtist: String,
        excludedIDs: [String],
        excludedNorms: Set<String>
    ) async -> [DiscoverQueueItem] {
        let hits = await PlaylistURLImporter.searchYouTubeTracks(query: query, limit: 8)
        let excludedSet = Set(excludedIDs)
        var out: [DiscoverQueueItem] = []
        for hit in hits {
            let vid = hit.videoID
            guard !vid.isEmpty else { continue }
            if excludedSet.contains(vid) { continue }
            let durSec = hit.durationSeconds
            if let durSec, (durSec < 50 || durSec > 720) { continue }

            let artist = hit.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultArtist : hit.artist
            let norm = normalizedTrackKey(title: hit.title, artist: artist)
            if excludedNorms.contains(norm) { continue }

            let artURL = URL(string: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")
            let durText = durSec.map { formatDurationText($0) }
            out.append(DiscoverQueueItem(
                id: vid,
                videoID: vid,
                title: hit.title,
                artist: artist.isEmpty ? "YouTube Video" : artist,
                album: nil,
                artworkURL: artURL,
                durationSeconds: durSec,
                durationText: durText,
                kind: .video,
                localRelativePath: nil,
                relationReason: "Related Music Video"
            ))
        }
        return out
    }

    nonisolated private static func collectPanelRenderers(in obj: Any, into out: inout [[String: Any]]) {
        if let dict = obj as? [String: Any] {
            if let panel = dict["playlistPanelVideoRenderer"] as? [String: Any] {
                out.append(panel)
            }
            for (_, val) in dict {
                collectPanelRenderers(in: val, into: &out)
            }
        } else if let arr = obj as? [Any] {
            for item in arr {
                collectPanelRenderers(in: item, into: &out)
            }
        }
    }

    nonisolated private static func extractText(from obj: Any?) -> String {
        guard let dict = obj as? [String: Any] else { return "" }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    nonisolated private static func formatDurationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    nonisolated private static func parseDurationText(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty else { return nil }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return nil
    }
}
