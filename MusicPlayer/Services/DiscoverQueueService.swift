import Foundation
import Observation
import UIKit

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

    private static let autoPlayDefaultsKey = "musicplayer.discoverQueueAutoPlay"
    private static let remixClientVersion = "1.20250311.01.00"
    private static let webUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    var items: [DiscoverQueueItem] = []
    var seedKey: String = ""
    var seedTitle: String = ""
    var seedArtist: String = ""
    var isLoading: Bool = false
    var isResolvingPlayback: Bool = false
    var activePlayingID: String?
    var statusMessage: String?

    var isAutoPlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoPlayEnabled, forKey: Self.autoPlayDefaultsKey)
        }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var playedHistoryIDs: [String] = []
    @ObservationIgnored private var playedNormKeys: Set<String> = []
    @ObservationIgnored private var videoIDCacheByNormKey: [String: String] = [:]

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoPlayDefaultsKey) == nil {
            self.isAutoPlayEnabled = true
        } else {
            self.isAutoPlayEnabled = UserDefaults.standard.bool(forKey: Self.autoPlayDefaultsKey)
        }
    }

    // MARK: - Playback Tracking & Auto-Refresh

    func handleNowPlayingChanged(to item: MediaItem, fromDiscoverQueue: Bool = false) {
        let key = trackKey(for: item)
        recordPlayedTrack(item)

        if !fromDiscoverQueue && key != seedKey {
            refreshIfNeeded(for: item, force: true)
        } else if fromDiscoverQueue {
            let activeID = activePlayingID
            items.removeAll { candidate in
                if let activeID, candidate.id == activeID { return true }
                return matches(candidate, item: item)
            }
            if items.count < 5 {
                refreshIfNeeded(for: item, force: true)
            }
        } else if items.isEmpty {
            refreshIfNeeded(for: item, force: true)
        }
    }

    func refreshIfNeeded(for item: MediaItem, force: Bool = false) {
        let key = trackKey(for: item)
        if !force && seedKey == key && (!items.isEmpty || isLoading) {
            return
        }

        refreshTask?.cancel()
        seedKey = key
        let cleanMeta = cleanedMetadata(for: item)
        seedTitle = cleanMeta.song
        seedArtist = cleanMeta.artist
        statusMessage = nil

        // Populate instant offline related tracks right away so UI & end-of-track transitions work immediately.
        let offlineMatches = buildLocalRelatedItems(for: item, cleanArtist: cleanMeta.artist, cleanTitle: cleanMeta.song)
        items = offlineMatches
        isLoading = true

        let itemID = MediaManager.shared.sourceVideoID(for: item)
        let capturedItem = item
        let snapshotHistory = Set(playedHistoryIDs)
        let snapshotNorms = playedNormKeys

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let fetched = await Self.fetchOnlineRelatedItems(
                for: capturedItem,
                seedVideoID: itemID,
                cleanSong: cleanMeta.song,
                cleanArtist: cleanMeta.artist,
                videoCache: self.videoIDCacheByNormKey,
                excludedIDs: snapshotHistory,
                excludedNorms: snapshotNorms
            )
            guard !Task.isCancelled, self.seedKey == key else { return }

            if let resolvedSeed = fetched.resolvedSeedVideoID, !resolvedSeed.isEmpty {
                let normKey = Self.normalizedTrackKey(title: cleanMeta.song, artist: cleanMeta.artist)
                self.videoIDCacheByNormKey[normKey] = resolvedSeed
                if !capturedItem.relativePath.hasPrefix("__remote__/") {
                    MediaManager.shared.setSourceVideoID(resolvedSeed, for: capturedItem)
                }
            }

            let merged = self.mergeOnline(fetched.items, withOffline: offlineMatches, seedItem: capturedItem)
            self.items = merged
            self.isLoading = false
        }
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
        if let localMatch = findCachedLocalMatch(for: discoverItem, in: mm.items) {
            _ = mm.play(localMatch, inPlaylist: nil, fromDiscoverQueue: true)
            return true
        }

        guard let videoID = discoverItem.videoID,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            return false
        }

        let resolved = await YouTubeStreamResolver.resolveStreams(for: watchURL)
        let candidateStreams: [DetectedBrowserMedia]
        if let streams = resolved?.streams, !streams.isEmpty {
            candidateStreams = streams
        } else if let browserResolved = await BrowserYouTubeResolver.shared.resolveStreamsInBrowser(
            videoID: videoID,
            priorityLockTimeout: 2.5
        ), !browserResolved.result.streams.isEmpty {
            candidateStreams = browserResolved.result.streams
        } else {
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
    func playNextAutoDiscover(after item: MediaItem?) async -> Bool {
        if items.isEmpty, let item {
            let clean = cleanedMetadata(for: item)
            let localSeed = buildLocalRelatedItems(for: item, cleanArtist: clean.artist, cleanTitle: clean.song)
            items = localSeed
            if isLoading {
                let deadline = Date().addingTimeInterval(3.5)
                while isLoading && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            } else {
                let fetched = await Self.fetchOnlineRelatedItems(
                    for: item,
                    seedVideoID: MediaManager.shared.sourceVideoID(for: item),
                    cleanSong: clean.song,
                    cleanArtist: clean.artist,
                    videoCache: videoIDCacheByNormKey,
                    excludedIDs: Set(playedHistoryIDs),
                    excludedNorms: playedNormKeys
                )
                items = mergeOnline(fetched.items, withOffline: localSeed, seedItem: item)
            }
        }

        for candidate in Array(items.prefix(4)) {
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
            guard let resolved = await YouTubeStreamResolver.resolveStreams(for: watchURL),
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

    private func recordPlayedTrack(_ item: MediaItem) {
        if let vid = MediaManager.shared.sourceVideoID(for: item), !vid.isEmpty {
            appendHistoryID(vid)
        }
        let clean = cleanedMetadata(for: item)
        let norm = Self.normalizedTrackKey(title: clean.song, artist: clean.artist)
        if !norm.isEmpty {
            playedNormKeys.insert(norm)
            if playedNormKeys.count > 120 {
                playedNormKeys = Set(playedNormKeys.prefix(60))
            }
        }
    }

    private func recordPlayedDiscoverItem(_ discoverItem: DiscoverQueueItem) {
        appendHistoryID(discoverItem.id)
        if let vid = discoverItem.videoID {
            appendHistoryID(vid)
        }
        let norm = Self.normalizedTrackKey(title: discoverItem.title, artist: discoverItem.artist)
        if !norm.isEmpty {
            playedNormKeys.insert(norm)
        }
    }

    private func appendHistoryID(_ id: String) {
        playedHistoryIDs.removeAll { $0 == id }
        playedHistoryIDs.append(id)
        if playedHistoryIDs.count > 60 {
            playedHistoryIDs.removeFirst(playedHistoryIDs.count - 60)
        }
    }

    private func matches(_ discoverItem: DiscoverQueueItem, item: MediaItem) -> Bool {
        if let vid = discoverItem.videoID,
           let itemVid = MediaManager.shared.sourceVideoID(for: item),
           vid == itemVid {
            return true
        }
        if let local = discoverItem.localRelativePath, local == item.relativePath {
            return true
        }
        let dNorm = Self.normalizedTrackKey(title: discoverItem.title, artist: discoverItem.artist)
        let clean = cleanedMetadata(for: item)
        let iNorm = Self.normalizedTrackKey(title: clean.song, artist: clean.artist)
        return !dNorm.isEmpty && dNorm == iNorm
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
        for cand in mm.items where cand.relativePath != seed.relativePath {
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
        let library = MediaManager.shared.items
        var seenIDs = Set<String>()
        var seenNorms = Set<String>()
        let seedClean = cleanedMetadata(for: seedItem)
        seenNorms.insert(Self.normalizedTrackKey(title: seedClean.song, artist: seedClean.artist))
        if let seedVid = MediaManager.shared.sourceVideoID(for: seedItem) {
            seenIDs.insert(seedVid)
        }

        var result: [DiscoverQueueItem] = []

        func appendIfUnique(_ candidate: DiscoverQueueItem) {
            if let vid = candidate.videoID, !vid.isEmpty {
                guard seenIDs.insert(vid).inserted else { return }
            }
            let norm = Self.normalizedTrackKey(title: candidate.title, artist: candidate.artist)
            if !norm.isEmpty {
                guard seenNorms.insert(norm).inserted else { return }
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

    nonisolated private static func normalizedTrackKey(title: String, artist: String) -> String {
        let t = ArtistDatabase.normalizeLookupKey(title)
        let a = ArtistDatabase.normalizeLookupKey(artist)
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
