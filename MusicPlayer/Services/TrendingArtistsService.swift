import BackgroundTasks
import Foundation
import Observation
import SwiftUI

enum TrendSourceTag: String, Codable, CaseIterable, Hashable {
    case tiktok = "TikTok Viral"
    case instagram = "Instagram Reels"
    case appleCharts = "Apple Charts"
    case deezerCharts = "Top Charts"
    case indieUnderground = "Indie & Rising"

    var badgeColor: Color {
        switch self {
        case .tiktok: return .pink
        case .instagram: return .purple
        case .appleCharts: return .red
        case .deezerCharts: return .blue
        case .indieUnderground: return .indigo
        }
    }

    var systemImage: String {
        switch self {
        case .tiktok: return "music.quarternote.3"
        case .instagram: return "sparkles.tv.fill"
        case .appleCharts: return "chart.line.uptrend.xyaxis"
        case .deezerCharts: return "flame.fill"
        case .indieUnderground: return "waveform.badge.magnifyingglass"
        }
    }
}

struct DiscoveredArtistRecord: Identifiable, Hashable, Codable {
    var id: String { normalizedKey }
    let normalizedKey: String
    var canonicalName: String
    var genre: String
    var trendSources: [TrendSourceTag]
    var viralTrackTitle: String?
    var imageURLString: String?
    var iTunesArtistID: Int?
    var deezerArtistID: Int?
    var discoveredAt: Date
    var lastSeenTrendingAt: Date
    var isNewSinceStaticCatalog: Bool

    var imageURL: URL? {
        imageURLString.flatMap { URL(string: $0) }
    }
}

enum TrendingSongPlatform: String, Codable, Hashable, Sendable {
    case youtube = "YouTube"
    case tiktok = "TikTok"
    case combined = "TikTok • YouTube"

    var badgeColor: Color {
        switch self {
        case .youtube: return .red
        case .tiktok: return .pink
        case .combined: return .purple
        }
    }
}

struct TrendingSongItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let artist: String
    let videoID: String?
    let artworkURLString: String?
    let platform: TrendingSongPlatform
    let durationSeconds: Double?

    var artworkURL: URL? {
        if let artworkURLString, let url = URL(string: artworkURLString) {
            return url
        }
        if let videoID, !videoID.isEmpty {
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        }
        return nil
    }
}

private struct TrendingArtistsPersistedState: Codable {
    var artists: [DiscoveredArtistRecord] = []
    var lastRefreshedAt: Date?
    var autoMonthlyRefresh: Bool = true
    var autoDailyRefresh: Bool? = nil
    var artistImageURLByKey: [String: String]? = [:]
    var trendingSongs: [TrendingSongItem]? = nil
    var lastSongsRefreshedAt: Date? = nil
}

struct ArtistReleaseItem: Identifiable, Hashable {
    var id: Int { collectionId }
    let collectionId: Int
    let title: String
    let artistName: String
    let releaseDate: Date?
    let releaseYearText: String
    let artworkURL: URL?
    let trackCount: Int
    let genre: String?
    let isSingleOrEP: Bool
}

struct ArtistTopSongItem: Identifiable, Hashable {
    var id: String { "\(ArtistDatabase.normalizeLookupKey(title))|\(ArtistDatabase.normalizeLookupKey(artistName))" }
    let title: String
    let artistName: String
    let albumTitle: String?
    let durationSeconds: Double?
    let artworkURL: URL?
    let previewURL: URL?
}

struct ArtistMusicVideoItem: Identifiable, Hashable {
    var id: Int { trackId }
    let trackId: Int
    let title: String
    let artistName: String
    let durationSeconds: Double?
    let artworkURL: URL?
    let releaseDate: Date?
}

struct ArtistReleaseTrackItem: Identifiable, Hashable {
    var id: String { "\(trackNumber)-\(title)" }
    let trackNumber: Int
    let title: String
    let artistName: String
    let durationSeconds: Double?
}

struct SimilarArtistItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let imageURL: URL?
    let deezerArtistID: Int?
}

struct ArtistProfileBundle {
    let canonicalName: String
    let genre: String?
    let heroImageURL: URL?
    let fanCount: Int?
    let appleMusicURL: URL?
    let iTunesArtistID: Int?
    let deezerArtistID: Int?
    let trendSources: [TrendSourceTag]
    let discoveredAt: Date?
    let latestRelease: ArtistReleaseItem?
    let topSongs: [ArtistTopSongItem]
    let albums: [ArtistReleaseItem]
    let singlesAndEPs: [ArtistReleaseItem]
    let musicVideos: [ArtistMusicVideoItem]
    let similarArtists: [SimilarArtistItem]
}

@Observable
final class TrendingArtistsService {
    static let shared = TrendingArtistsService()
    static let dailyRefreshTaskIdentifier = "com.personal.musicplayer.artistdb.daily"

    private static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private var state = TrendingArtistsPersistedState()
    var isRefreshing = false
    var isLoadingSongs = false
    var resolvingSongID: String?
    var lastStatusMessage: String?
    var artistPhotoVersion: Int = 0

    @ObservationIgnored private var midnightRefreshTimer: Timer?
    @ObservationIgnored private var didRegisterBGTask = false
    @ObservationIgnored private var inFlightPhotoKeys: Set<String> = []

    var trendingSongs: [TrendingSongItem] {
        state.trendingSongs ?? []
    }

    private var storageFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trending_artists.json")
    }

    var artists: [DiscoveredArtistRecord] {
        state.artists
    }

    var newlyAddedArtists: [DiscoveredArtistRecord] {
        state.artists.filter(\.isNewSinceStaticCatalog)
    }

    var lastRefreshedAt: Date? {
        state.lastRefreshedAt
    }

    var autoDailyRefresh: Bool {
        get { state.autoDailyRefresh ?? state.autoMonthlyRefresh }
        set {
            state.autoDailyRefresh = newValue
            state.autoMonthlyRefresh = newValue
            saveToDisk()
            Task { @MainActor [weak self] in
                if newValue {
                    self?.scheduleDailyMidnightRefresh()
                } else {
                    self?.midnightRefreshTimer?.invalidate()
                    self?.midnightRefreshTimer = nil
                }
            }
        }
    }

    var autoMonthlyRefresh: Bool {
        get { autoDailyRefresh }
        set { autoDailyRefresh = newValue }
    }

    /// True once each calendar day has passed 12:00 AM local time since the previous catalog refresh.
    var needsDailyRefresh: Bool {
        guard autoDailyRefresh else { return false }
        guard let last = state.lastRefreshedAt else { return true }
        let todayMidnight = Calendar.current.startOfDay(for: .now)
        return last < todayMidnight
    }

    var needsMonthlyRefresh: Bool {
        needsDailyRefresh
    }

    var nextScheduledRefreshDate: Date? {
        guard autoDailyRefresh else { return nil }
        let todayMidnight = Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(byAdding: .day, value: 1, to: todayMidnight)
    }

    private init() {
        loadFromDisk()
        registerDiscoveredIntoDatabase()
        Task { @MainActor [weak self] in
            self?.scheduleDailyMidnightRefresh()
        }
    }

    func registerBackgroundRefresh() {
        guard !didRegisterBGTask else { return }
        didRegisterBGTask = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.dailyRefreshTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let bgWorker = Task {
                await TrendingArtistsService.shared.refreshIfDue()
                await MainActor.run {
                    TrendingArtistsService.shared.scheduleDailyMidnightRefresh()
                    refreshTask.setTaskCompleted(success: true)
                }
            }
            refreshTask.expirationHandler = {
                bgWorker.cancel()
                refreshTask.setTaskCompleted(success: false)
            }
        }
        Task { @MainActor [weak self] in
            self?.scheduleDailyMidnightRefresh()
        }
    }

    @MainActor
    func scheduleDailyMidnightRefresh() {
        midnightRefreshTimer?.invalidate()
        midnightRefreshTimer = nil
        guard autoDailyRefresh else { return }

        let todayMidnight = Calendar.current.startOfDay(for: .now)
        guard let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: todayMidnight) else { return }
        let delay = max(15.0, nextMidnight.timeIntervalSinceNow + 2.0)

        midnightRefreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshIfDue()
                self?.scheduleDailyMidnightRefresh()
            }
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.dailyRefreshTaskIdentifier)
        request.earliestBeginDate = nextMidnight
        try? BGTaskScheduler.shared.submit(request)
    }

    func record(forArtistName name: String) -> DiscoveredArtistRecord? {
        let key = ArtistDatabase.normalizeLookupKey(name)
        guard !key.isEmpty else { return nil }
        return state.artists.first(where: { $0.normalizedKey == key })
    }

    // MARK: - Wrapped & Catalog Artist Artwork Cache

    func cachedArtistImageURL(for artistName: String) -> URL? {
        let key = ArtistDatabase.normalizeLookupKey(artistName)
        guard !key.isEmpty, key != "unknown artist" else { return nil }
        if let str = state.artistImageURLByKey?[key], let url = URL(string: str) {
            return url
        }
        return record(forArtistName: artistName)?.imageURL
    }

    func ensureArtistPhotos(for artistNames: [String]) async {
        var pending: [(key: String, name: String)] = []
        var seenKeys = Set<String>()

        for raw in artistNames {
            let trimmed = ArtistDatabase.canonicalizeSingle(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ArtistDatabase.normalizeLookupKey(trimmed)
            guard !key.isEmpty,
                  key != "unknown artist",
                  seenKeys.insert(key).inserted,
                  cachedArtistImageURL(for: trimmed) == nil,
                  !inFlightPhotoKeys.contains(key) else {
                continue
            }
            inFlightPhotoKeys.insert(key)
            pending.append((key, trimmed))
        }
        guard !pending.isEmpty else { return }

        var resolvedAny = false
        var map = state.artistImageURLByKey ?? [:]

        // Process in batches of up to 4 concurrent lookups so Wrapped cards fill quickly.
        for batchStart in stride(from: 0, to: pending.count, by: 4) {
            let slice = Array(pending[batchStart..<min(pending.count, batchStart + 4)])
            await withTaskGroup(of: (key: String, urlStr: String?).self) { group in
                for target in slice {
                    group.addTask {
                        let dz = await Self.fetchDeezerArtistInfo(name: target.name, knownID: nil)
                        if let urlStr = dz.imageURL?.absoluteString, !urlStr.isEmpty {
                            return (target.key, urlStr)
                        }
                        // Fallback for small / independent artists not yet on Deezer: iTunes top track artwork.
                        let it = await Self.fetchITunesArtistInfo(name: target.name, knownID: nil)
                        let songs = await Self.fetchITunesArtistTopSongs(artistId: it.artistId, fallbackName: target.name)
                        if let artURL = songs.first?.artworkURL?.absoluteString {
                            return (target.key, artURL)
                        }
                        return (target.key, nil)
                    }
                }
                for await res in group {
                    inFlightPhotoKeys.remove(res.key)
                    if let urlStr = res.urlStr, !urlStr.isEmpty {
                        map[res.key] = urlStr
                        resolvedAny = true
                    }
                }
            }
        }

        if resolvedAny {
            state.artistImageURLByKey = map
            artistPhotoVersion &+= 1
            saveToDisk()
        }
    }

    // MARK: - Daily 12:00 AM Social, Underground & Chart Refresh

    func refreshIfDue() async {
        guard needsDailyRefresh else { return }
        await refreshTrendingArtists(force: false)
    }

    @discardableResult
    func refreshTrendingArtists(force: Bool = false) async -> Int {
        guard !isRefreshing else { return 0 }
        if !force && !needsDailyRefresh {
            return 0
        }

        await MainActor.run {
            self.isRefreshing = true
            self.lastStatusMessage = "Scanning viral hits, charts & emerging indie artists..."
        }

        let cal = Calendar.current
        let year = cal.component(.year, from: .now)
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: .now) ?? 1

        // Daily rotating pockets discover small, indie, SoundCloud, and underground scenes alongside major charts.
        let risingQueries = [
            "Underground Rap", "Bedroom Pop", "Hyperpop", "SoundCloud Rap",
            "Phonk Viral", "Fresh Finds Indie", "Alt R&B Rising", "Afrobeats Rising",
            "Latin Urbana", "UK Underground", "PluggnB", "Indie Pop",
            "Electronic Rising", "J-Pop Indie", "K-R&B", "Shoegaze & Dream Pop"
        ]
        let qRising1 = risingQueries[dayOfYear % risingQueries.count]
        let qRising2 = risingQueries[(dayOfYear + 5) % risingQueries.count]
        let qRising3 = risingQueries[(dayOfYear + 11) % risingQueries.count]

        let chartCountries = ["us", "gb", "ca", "au", "jp", "kr", "br", "fr", "de", "ng"]
        let altCountry = chartCountries[dayOfYear % chartCountries.count]

        async let tiktokTask1 = fetchDeezerViralPlaylistArtists(query: "TikTok Trending \(year)", tag: .tiktok)
        async let tiktokTask2 = fetchDeezerViralPlaylistArtists(query: "Viral TikTok Hits \(year)", tag: .tiktok)
        async let reelsTask1 = fetchDeezerViralPlaylistArtists(query: "Instagram Reels \(year)", tag: .instagram)
        async let risingTask1 = fetchDeezerViralPlaylistArtists(query: qRising1, tag: .indieUnderground)
        async let risingTask2 = fetchDeezerViralPlaylistArtists(query: qRising2, tag: .indieUnderground)
        async let risingTask3 = fetchDeezerViralPlaylistArtists(query: qRising3, tag: .indieUnderground)
        async let appleUSTask = fetchAppleTopSongsArtists(country: "us", limit: 100)
        async let appleAltTask = fetchAppleTopSongsArtists(country: altCountry, limit: 50)
        async let deezerChartTask = fetchDeezerTopChartArtists()

        var rawDiscoveries: [RawDiscoveredCandidate] = []
        rawDiscoveries.append(contentsOf: await tiktokTask1)
        rawDiscoveries.append(contentsOf: await tiktokTask2)
        rawDiscoveries.append(contentsOf: await reelsTask1)
        rawDiscoveries.append(contentsOf: await risingTask1)
        rawDiscoveries.append(contentsOf: await risingTask2)
        rawDiscoveries.append(contentsOf: await risingTask3)
        rawDiscoveries.append(contentsOf: await appleUSTask)
        rawDiscoveries.append(contentsOf: await appleAltTask)
        rawDiscoveries.append(contentsOf: await deezerChartTask)

        // Also include verified & library artists (especially niche/small artists imported by the user).
        let libraryItems = await MainActor.run { MediaManager.shared.items }
        let ignoredChannels = await MainActor.run { ListeningWrappedService.shared.ignoredChannels }
        for item in libraryItems {
            let extracted = ArtistDatabase.extractArtists(
                rawArtistTag: item.artist,
                rawTitle: item.displayTitle,
                fileName: item.fileName,
                ignoredChannels: ignoredChannels
            )
            for name in extracted.allArtists where !ArtistDatabase.looksLikeUploaderChannel(name, customIgnoredChannels: ignoredChannels) {
                rawDiscoveries.append(
                    RawDiscoveredCandidate(
                        artistName: name,
                        trackTitle: item.displayTitle,
                        source: .indieUnderground,
                        imageURLString: nil,
                        iTunesArtistID: nil,
                        deezerArtistID: nil
                    )
                )
            }
        }

        var existingByKey: [String: DiscoveredArtistRecord] = Dictionary(
            state.artists.map { ($0.normalizedKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previouslyKnownKeys = Set(existingByKey.keys)

        var mergedByKey: [String: DiscoveredArtistRecord] = existingByKey
        var orderedKeys: [String] = []
        var newDiscoveryCount = 0

        for cand in rawDiscoveries {
            let splitNames = ArtistDatabase.splitAndCanonicalize(cand.artistName)
            for singleRaw in splitNames {
                let canonical = ArtistDatabase.canonicalizeSingle(singleRaw)
                let key = ArtistDatabase.normalizeLookupKey(canonical)
                guard !key.isEmpty,
                      key.count >= 2,
                      !ArtistDatabase.looksLikeUploaderChannel(canonical) else {
                    continue
                }

                if var existing = mergedByKey[key] {
                    if !existing.trendSources.contains(cand.source) {
                        existing.trendSources.append(cand.source)
                    }
                    if (existing.viralTrackTitle?.isEmpty ?? true), let vt = cand.trackTitle {
                        existing.viralTrackTitle = vt
                    }
                    if existing.imageURLString == nil, let img = cand.imageURLString {
                        existing.imageURLString = img
                    }
                    if existing.iTunesArtistID == nil, let aid = cand.iTunesArtistID {
                        existing.iTunesArtistID = aid
                    }
                    if existing.deezerArtistID == nil, let did = cand.deezerArtistID {
                        existing.deezerArtistID = did
                    }
                    existing.lastSeenTrendingAt = .now
                    mergedByKey[key] = existing
                } else {
                    let isNewArtist = !ArtistDatabase.isInStaticCatalog(canonical)
                    let record = DiscoveredArtistRecord(
                        normalizedKey: key,
                        canonicalName: canonical,
                        genre: ArtistDatabase.genre(forArtist: canonical) ?? "Pop & Viral",
                        trendSources: [cand.source],
                        viralTrackTitle: cand.trackTitle,
                        imageURLString: cand.imageURLString,
                        iTunesArtistID: cand.iTunesArtistID,
                        deezerArtistID: cand.deezerArtistID,
                        discoveredAt: .now,
                        lastSeenTrendingAt: .now,
                        isNewSinceStaticCatalog: isNewArtist
                    )
                    mergedByKey[key] = record
                    if !previouslyKnownKeys.contains(key) {
                        newDiscoveryCount += 1
                    }
                }
                if !orderedKeys.contains(key) {
                    orderedKeys.append(key)
                }
            }
        }

        // Prioritize new emerging artists and entries missing artwork/IDs for quick metadata hydration
        let hydrationTargets = orderedKeys
            .compactMap { mergedByKey[$0] }
            .filter { $0.imageURLString == nil || $0.iTunesArtistID == nil }
            .sorted { lhs, rhs in
                if lhs.isNewSinceStaticCatalog != rhs.isNewSinceStaticCatalog {
                    return lhs.isNewSinceStaticCatalog
                }
                return lhs.trendSources.count > rhs.trendSources.count
            }
            .prefix(60)

        await withTaskGroup(of: (key: String, genre: String?, imageURL: String?, iTunesID: Int?, deezerID: Int?).self) { group in
            for item in hydrationTargets {
                group.addTask {
                    let enriched = await Self.fetchQuickArtistMetadata(
                        name: item.canonicalName,
                        needsImage: item.imageURLString == nil,
                        needsITunes: item.iTunesArtistID == nil
                    )
                    return (item.normalizedKey, enriched.genre, enriched.imageURL, enriched.iTunesID, enriched.deezerID)
                }
            }
            for await patch in group {
                guard var rec = mergedByKey[patch.key] else { continue }
                if let g = patch.genre, !g.isEmpty { rec.genre = g }
                if let img = patch.imageURL, rec.imageURLString == nil { rec.imageURLString = img }
                if let iid = patch.iTunesID, rec.iTunesArtistID == nil { rec.iTunesArtistID = iid }
                if let did = patch.deezerID, rec.deezerArtistID == nil { rec.deezerArtistID = did }
                mergedByKey[patch.key] = rec
            }
        }

        let sortedFinal = mergedByKey.values.sorted { lhs, rhs in
            if lhs.isNewSinceStaticCatalog != rhs.isNewSinceStaticCatalog {
                return lhs.isNewSinceStaticCatalog
            }
            if lhs.lastSeenTrendingAt != rhs.lastSeenTrendingAt {
                return lhs.lastSeenTrendingAt > rhs.lastSeenTrendingAt
            }
            if lhs.trendSources.count != rhs.trendSources.count {
                return lhs.trendSources.count > rhs.trendSources.count
            }
            return lhs.canonicalName.localizedCaseInsensitiveCompare(rhs.canonicalName) == .orderedAscending
        }

        await MainActor.run {
            self.state.artists = Array(sortedFinal.prefix(2500))
            var imgMap = self.state.artistImageURLByKey ?? [:]
            for rec in self.state.artists {
                if let img = rec.imageURLString, !img.isEmpty, imgMap[rec.normalizedKey] == nil {
                    imgMap[rec.normalizedKey] = img
                }
            }
            self.state.artistImageURLByKey = imgMap
            self.artistPhotoVersion &+= 1
            self.state.lastRefreshedAt = .now
            self.isRefreshing = false
            self.lastStatusMessage = newDiscoveryCount > 0
                ? "Added \(newDiscoveryCount) new \(newDiscoveryCount == 1 ? "artist" : "artists") (big charts & indie/rising)"
                : "Artist database refreshed (\(ArtistDatabase.totalCatalogCount) total artists)"
            self.saveToDisk()
            self.registerDiscoveredIntoDatabase()
            self.scheduleDailyMidnightRefresh()
        }

        return newDiscoveryCount
    }

    private func registerDiscoveredIntoDatabase() {
        let entries = state.artists.map { rec in
            ArtistCatalogEntry(
                canonicalName: rec.canonicalName,
                genre: rec.genre,
                aliases: [],
                requiresSeparatedContext: rec.canonicalName.count <= 4
            )
        }
        ArtistDatabase.registerDynamicArtists(entries)
    }

    // MARK: - Apple Music-Style Artist Profile & Releases

    func loadArtistProfile(
        artistName: String,
        seedITunesID: Int? = nil,
        seedDeezerID: Int? = nil,
        seedImageURL: URL? = nil
    ) async -> ArtistProfileBundle {
        let cachedRec = record(forArtistName: artistName)
        let queryName = cachedRec?.canonicalName ?? ArtistDatabase.canonicalizeSingle(artistName)

        async let iTunesArtTask = Self.fetchITunesArtistInfo(name: queryName, knownID: seedITunesID ?? cachedRec?.iTunesArtistID)
        async let deezerArtTask = Self.fetchDeezerArtistInfo(name: queryName, knownID: seedDeezerID ?? cachedRec?.deezerArtistID)

        let itArtist = await iTunesArtTask
        let dzArtist = await deezerArtTask

        let resolvedITunesID = itArtist.artistId ?? seedITunesID ?? cachedRec?.iTunesArtistID
        let resolvedDeezerID = dzArtist.id ?? seedDeezerID ?? cachedRec?.deezerArtistID

        async let albumsTask = Self.fetchITunesArtistReleases(artistId: resolvedITunesID, fallbackName: queryName)
        async let iTunesSongsTask = Self.fetchITunesArtistTopSongs(artistId: resolvedITunesID, fallbackName: queryName)
        async let musicVideosTask = Self.fetchITunesArtistMusicVideos(artistId: resolvedITunesID)
        async let dzTopTask = Self.fetchDeezerArtistTopTracks(deezerId: resolvedDeezerID)
        async let dzRelatedTask = Self.fetchDeezerSimilarArtists(deezerId: resolvedDeezerID)

        let allReleases = await albumsTask
        let iTunesSongs = await iTunesSongsTask
        let musicVideos = await musicVideosTask
        let dzTopSongs = await dzTopTask
        let similarArtists = await dzRelatedTask

        let canonical = itArtist.name ?? dzArtist.name ?? queryName
        let genre = itArtist.genre ?? cachedRec?.genre ?? ArtistDatabase.genre(forArtist: canonical)
        let heroURL = dzArtist.imageURL ?? seedImageURL ?? cachedRec?.imageURL ?? allReleases.first?.artworkURL

        let topSongs = Self.mergeTopSongs(deezerSongs: dzTopSongs, iTunesSongs: iTunesSongs, defaultArtist: canonical)
        let albums = allReleases.filter { !$0.isSingleOrEP }
        let singlesAndEPs = allReleases.filter { $0.isSingleOrEP }
        let latestRelease = allReleases.first

        // Cache enriched IDs & artwork locally if this artist is in our trending catalog
        if var rec = cachedRec {
            if rec.iTunesArtistID == nil { rec.iTunesArtistID = resolvedITunesID }
            if rec.deezerArtistID == nil { rec.deezerArtistID = resolvedDeezerID }
            if rec.imageURLString == nil, let heroURL { rec.imageURLString = heroURL.absoluteString }
            if let g = genre, !g.isEmpty { rec.genre = g }
            if let idx = state.artists.firstIndex(where: { $0.normalizedKey == rec.normalizedKey }) {
                state.artists[idx] = rec
                saveToDisk()
            }
        }

        return ArtistProfileBundle(
            canonicalName: canonical,
            genre: genre,
            heroImageURL: heroURL,
            fanCount: dzArtist.fanCount,
            appleMusicURL: itArtist.linkURL,
            iTunesArtistID: resolvedITunesID,
            deezerArtistID: resolvedDeezerID,
            trendSources: cachedRec?.trendSources ?? [],
            discoveredAt: cachedRec?.discoveredAt,
            latestRelease: latestRelease,
            topSongs: topSongs,
            albums: albums,
            singlesAndEPs: singlesAndEPs,
            musicVideos: musicVideos,
            similarArtists: similarArtists
        )
    }

    func fetchReleaseTracks(collectionId: Int) async -> [ArtistReleaseTrackItem] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(collectionId)&entity=song&limit=100"),
              let dict = await Self.getJSON(url: url) as? [String: Any],
              let results = dict["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { row in
            guard (row["wrapperType"] as? String) == "track",
                  let title = row["trackName"] as? String else {
                return nil
            }
            let artist = (row["artistName"] as? String) ?? ""
            let trackNum = (row["trackNumber"] as? Int) ?? 0
            let ms = row["trackTimeMillis"] as? Double
            return ArtistReleaseTrackItem(
                trackNumber: trackNum,
                title: title,
                artistName: artist,
                durationSeconds: ms.map { $0 / 1000.0 }
            )
        }
        .sorted { $0.trackNumber < $1.trackNumber }
    }

    // MARK: - Play & Save Offline Helpers

    @MainActor
    func playArtistTrackAdFree(title: String, artist: String, isVideo: Bool = false) async -> Bool {
        let query = isVideo ? "\(artist) \(title) official music video" : "\(artist) \(title)"
        let hits = await PlaylistURLImporter.searchYouTubeTracks(query: query, limit: 5)
        guard let best = hits.first,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(best.videoID)"),
              let resolved = await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
                  for: watchURL,
                  videoID: best.videoID,
                  titleHint: title,
                  authorHint: artist,
                  durationHint: best.durationSeconds
              ),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not find an ad-free stream for \"\(title)\"."
            return false
        }

        let audioOnly = resolved.streams.filter { $0.isAudio }
        let videoDirect = resolved.streams.filter { !$0.isHLS && !$0.isAudio }
        let preferred: [DetectedBrowserMedia] = isVideo
            ? (videoDirect.isEmpty ? resolved.streams : (videoDirect + resolved.streams.filter(\.isHLS)))
            : (audioOnly.isEmpty ? videoDirect : (audioOnly + videoDirect))

        guard let stream = preferred.first else { return false }
        MediaManager.shared.playRemoteStream(
            url: stream.url,
            title: title,
            artist: artist,
            headers: stream.customHeaders,
            isVideo: isVideo || !stream.isAudio
        )
        return true
    }

    @MainActor
    func downloadArtistTrackOffline(
        title: String,
        artist: String,
        downloader: WebMediaDownloader,
        targetPlaylistID: UUID? = nil
    ) async -> MediaItem? {
        let hits = await PlaylistURLImporter.searchYouTubeTracks(query: "\(artist) \(title)", limit: 5)
        guard let best = hits.first,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(best.videoID)"),
              let resolved = await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
                  for: watchURL,
                  videoID: best.videoID,
                  titleHint: title,
                  authorHint: artist,
                  durationHint: best.durationSeconds
              ),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not download \"\(title)\"."
            return nil
        }

        let audioOnly = resolved.streams.filter { $0.isAudio }
        let videoDirect = resolved.streams.filter { !$0.isHLS && !$0.isAudio }
        let ordered = audioOnly.isEmpty ? videoDirect : (audioOnly + videoDirect)
        guard let primary = ordered.first else { return nil }

        let media = DetectedBrowserMedia(
            url: primary.url,
            pairedAudioURL: primary.pairedAudioURL,
            isHLS: primary.isHLS,
            isAudio: primary.isAudio,
            title: title,
            author: artist,
            qualityLabel: primary.qualityLabel,
            referer: primary.referer,
            customHeaders: primary.customHeaders,
            durationSeconds: resolved.durationSeconds ?? primary.durationSeconds,
            isActivelyPlaying: false
        )

        if let targetPlaylistID {
            return await downloader.downloadTrackIntoPlaylist(
                media,
                fallbackStreams: Array(ordered.dropFirst()),
                targetPlaylistID: targetPlaylistID,
                sourceVideoID: best.videoID
            )
        } else {
            return await downloader.downloadGroupTrackOffline(
                media,
                fallbackStreams: Array(ordered.dropFirst()),
                sourceVideoID: best.videoID
            )
        }
    }

    // MARK: - Feed Parsers

    private struct RawDiscoveredCandidate {
        let artistName: String
        let trackTitle: String?
        let source: TrendSourceTag
        let imageURLString: String?
        let iTunesArtistID: Int?
        let deezerArtistID: Int?
    }

    private func fetchDeezerViralPlaylistArtists(query: String, tag: TrendSourceTag) async -> [RawDiscoveredCandidate] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://api.deezer.com/search/playlist?q=\(encoded)&limit=8"),
              let json = await Self.getJSON(url: searchURL) as? [String: Any],
              let playlists = json["data"] as? [[String: Any]] else {
            return []
        }

        let yearStr = String(Calendar.current.component(.year, from: .now))
        let sorted = playlists
            .filter { ($0["nb_tracks"] as? Int ?? 0) >= 15 }
            .sorted { lhs, rhs in
                let lt = (lhs["title"] as? String ?? "").lowercased()
                let rt = (rhs["title"] as? String ?? "").lowercased()
                let lHasCurYear = lt.contains(yearStr)
                let rHasCurYear = rt.contains(yearStr)
                if lHasCurYear != rHasCurYear { return lHasCurYear }
                return (lhs["nb_tracks"] as? Int ?? 0) > (rhs["nb_tracks"] as? Int ?? 0)
            }

        var collected: [RawDiscoveredCandidate] = []
        for pl in sorted.prefix(3) {
            guard let pid = pl["id"] as? Int,
                  let tracksURL = URL(string: "https://api.deezer.com/playlist/\(pid)/tracks?limit=50"),
                  let tJSON = await Self.getJSON(url: tracksURL) as? [String: Any],
                  let rows = tJSON["data"] as? [[String: Any]] else {
                continue
            }
            for row in rows {
                guard let art = row["artist"] as? [String: Any],
                      let artistName = art["name"] as? String else {
                    continue
                }
                let dzID = art["id"] as? Int
                let title = row["title"] as? String
                let img = (art["picture_big"] as? String) ?? (art["picture_medium"] as? String)
                collected.append(
                    RawDiscoveredCandidate(
                        artistName: artistName,
                        trackTitle: title,
                        source: tag,
                        imageURLString: img,
                        iTunesArtistID: nil,
                        deezerArtistID: dzID
                    )
                )
            }
        }
        return collected
    }

    private func fetchAppleTopSongsArtists(country: String = "us", limit: Int = 100) async -> [RawDiscoveredCandidate] {
        guard let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/music/most-played/\(limit)/songs.json"),
              let json = await Self.getJSON(url: url) as? [String: Any],
              let feed = json["feed"] as? [String: Any],
              let results = feed["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { row in
            guard let name = row["artistName"] as? String else { return nil }
            let aid = (row["artistId"] as? String).flatMap { Int($0) }
            let songTitle = row["name"] as? String
            let art = (row["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return RawDiscoveredCandidate(
                artistName: name,
                trackTitle: songTitle,
                source: .appleCharts,
                imageURLString: art,
                iTunesArtistID: aid,
                deezerArtistID: nil
            )
        }
    }

    private func fetchDeezerTopChartArtists() async -> [RawDiscoveredCandidate] {
        guard let url = URL(string: "https://api.deezer.com/chart/0?limit=100"),
              let json = await Self.getJSON(url: url) as? [String: Any] else {
            return []
        }

        var items: [RawDiscoveredCandidate] = []
        if let artistsDict = json["artists"] as? [String: Any],
           let rows = artistsDict["data"] as? [[String: Any]] {
            for row in rows {
                guard let name = row["name"] as? String else { continue }
                let did = row["id"] as? Int
                let img = (row["picture_xl"] as? String) ?? (row["picture_big"] as? String)
                items.append(
                    RawDiscoveredCandidate(
                        artistName: name,
                        trackTitle: nil,
                        source: .deezerCharts,
                        imageURLString: img,
                        iTunesArtistID: nil,
                        deezerArtistID: did
                    )
                )
            }
        }
        if let tracksDict = json["tracks"] as? [String: Any],
           let tRows = tracksDict["data"] as? [[String: Any]] {
            for row in tRows {
                guard let art = row["artist"] as? [String: Any],
                      let name = art["name"] as? String else { continue }
                let did = art["id"] as? Int
                let img = (art["picture_big"] as? String)
                items.append(
                    RawDiscoveredCandidate(
                        artistName: name,
                        trackTitle: row["title"] as? String,
                        source: .deezerCharts,
                        imageURLString: img,
                        iTunesArtistID: nil,
                        deezerArtistID: did
                    )
                )
            }
        }
        return items
    }

    private static func fetchQuickArtistMetadata(
        name: String,
        needsImage: Bool,
        needsITunes: Bool
    ) async -> (genre: String?, imageURL: String?, iTunesID: Int?, deezerID: Int?) {
        async let itTask: (name: String?, artistId: Int?, genre: String?, linkURL: URL?) =
            needsITunes ? fetchITunesArtistInfo(name: name, knownID: nil) : (nil, nil, nil, nil)
        async let dzTask: (id: Int?, name: String?, imageURL: URL?, fanCount: Int?) =
            needsImage ? fetchDeezerArtistInfo(name: name, knownID: nil) : (nil, nil, nil, nil)

        let it = await itTask
        let dz = await dzTask
        var imageStr = dz.imageURL?.absoluteString
        if needsImage && (imageStr?.isEmpty ?? true) {
            let songs = await fetchITunesArtistTopSongs(artistId: it.artistId, fallbackName: name)
            imageStr = songs.first?.artworkURL?.absoluteString
        }
        return (it.genre, imageStr, it.artistId, dz.id)
    }

    // MARK: - Artist Profile Network Helpers

    private static func fetchITunesArtistInfo(
        name: String,
        knownID: Int?
    ) async -> (name: String?, artistId: Int?, genre: String?, linkURL: URL?) {
        if let knownID,
           let url = URL(string: "https://itunes.apple.com/lookup?id=\(knownID)"),
           let dict = await getJSON(url: url) as? [String: Any],
           let first = (dict["results"] as? [[String: Any]])?.first,
           let artName = first["artistName"] as? String {
            return (
                artName,
                knownID,
                first["primaryGenreName"] as? String,
                (first["artistLinkUrl"] as? String).flatMap { URL(string: $0) }
            )
        }

        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=musicArtist&limit=5&term=\(encoded)"),
              let dict = await getJSON(url: url) as? [String: Any],
              let rows = dict["results"] as? [[String: Any]],
              !rows.isEmpty else {
            return (nil, knownID, nil, nil)
        }

        let targetNorm = ArtistDatabase.normalizeLookupKey(name)
        let match = rows.first {
            ArtistDatabase.normalizeLookupKey(($0["artistName"] as? String) ?? "") == targetNorm
        } ?? rows[0]

        return (
            match["artistName"] as? String,
            match["artistId"] as? Int,
            match["primaryGenreName"] as? String,
            (match["artistLinkUrl"] as? String).flatMap { URL(string: $0) }
        )
    }

    private static func fetchDeezerArtistInfo(
        name: String,
        knownID: Int?
    ) async -> (id: Int?, name: String?, imageURL: URL?, fanCount: Int?) {
        if let knownID,
           let url = URL(string: "https://api.deezer.com/artist/\(knownID)"),
           let dict = await getJSON(url: url) as? [String: Any],
           let artName = dict["name"] as? String {
            let imgStr = (dict["picture_xl"] as? String) ?? (dict["picture_big"] as? String)
            return (knownID, artName, imgStr.flatMap { URL(string: $0) }, dict["nb_fan"] as? Int)
        }

        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?limit=5&q=\(encoded)"),
              let dict = await getJSON(url: url) as? [String: Any],
              let rows = dict["data"] as? [[String: Any]],
              !rows.isEmpty else {
            return (knownID, nil, nil, nil)
        }

        let targetNorm = ArtistDatabase.normalizeLookupKey(name)
        let match = rows.first {
            ArtistDatabase.normalizeLookupKey(($0["name"] as? String) ?? "") == targetNorm
        } ?? rows[0]
        let imgStr = (match["picture_xl"] as? String) ?? (match["picture_big"] as? String)
        return (
            match["id"] as? Int,
            match["name"] as? String,
            imgStr.flatMap { URL(string: $0) },
            match["nb_fan"] as? Int
        )
    }

    private static func fetchITunesArtistReleases(artistId: Int?, fallbackName: String) async -> [ArtistReleaseItem] {
        var rows: [[String: Any]] = []
        if let artistId,
           let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=80"),
           let dict = await getJSON(url: url) as? [String: Any],
           let results = dict["results"] as? [[String: Any]] {
            rows = results.filter { ($0["wrapperType"] as? String) == "collection" }
        } else if let encoded = fallbackName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/search?media=music&entity=album&attribute=artistTerm&limit=40&term=\(encoded)"),
                  let dict = await getJSON(url: url) as? [String: Any],
                  let results = dict["results"] as? [[String: Any]] {
            let normTarget = ArtistDatabase.normalizeLookupKey(fallbackName)
            rows = results.filter {
                ArtistDatabase.normalizeLookupKey(($0["artistName"] as? String) ?? "").contains(normTarget)
            }
        }

        var items: [ArtistReleaseItem] = []
        var seenNormTitleYear = Set<String>()

        for row in rows {
            guard let cid = row["collectionId"] as? Int,
                  let title = row["collectionName"] as? String else {
                continue
            }
            let art = (row["artistName"] as? String) ?? fallbackName
            let relStr = (row["releaseDate"] as? String) ?? ""
            let relDate = parseISODate(relStr)
            let yearText = relStr.count >= 4 ? String(relStr.prefix(4)) : ""
            let trackCount = (row["trackCount"] as? Int) ?? 0
            let genre = row["primaryGenreName"] as? String
            let artURL = ((row["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100bb", with: "600x600bb"))
                .flatMap { URL(string: $0) }
            let lowerTitle = title.lowercased()
            let isSingleOrEP = trackCount <= 6 || lowerTitle.hasSuffix("- single") || lowerTitle.hasSuffix("- ep")

            // Clean duplicate explicit/clean releases sharing exact normalized title + year
            let dedupKey = "\(ArtistDatabase.normalizeLookupKey(title))|\(yearText)|\(trackCount)"
            guard seenNormTitleYear.insert(dedupKey).inserted else { continue }

            items.append(
                ArtistReleaseItem(
                    collectionId: cid,
                    title: title,
                    artistName: art,
                    releaseDate: relDate,
                    releaseYearText: yearText,
                    artworkURL: artURL,
                    trackCount: trackCount,
                    genre: genre,
                    isSingleOrEP: isSingleOrEP
                )
            )
        }

        return items.sorted { lhs, rhs in
            (lhs.releaseDate ?? .distantPast) > (rhs.releaseDate ?? .distantPast)
        }
    }

    private static func fetchITunesArtistTopSongs(artistId: Int?, fallbackName: String) async -> [ArtistTopSongItem] {
        var rows: [[String: Any]] = []
        if let artistId,
           let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=song&limit=25"),
           let dict = await getJSON(url: url) as? [String: Any],
           let results = dict["results"] as? [[String: Any]] {
            rows = results.filter { ($0["wrapperType"] as? String) == "track" }
        } else if let encoded = fallbackName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=15&term=\(encoded)"),
                  let dict = await getJSON(url: url) as? [String: Any],
                  let results = dict["results"] as? [[String: Any]] {
            rows = results
        }

        return rows.compactMap { row in
            guard let title = row["trackName"] as? String else { return nil }
            let art = (row["artistName"] as? String) ?? fallbackName
            let album = row["collectionName"] as? String
            let ms = row["trackTimeMillis"] as? Double
            let artURL = ((row["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100bb", with: "600x600bb"))
                .flatMap { URL(string: $0) }
            let prev = (row["previewUrl"] as? String).flatMap { URL(string: $0) }
            return ArtistTopSongItem(
                title: title,
                artistName: art,
                albumTitle: album,
                durationSeconds: ms.map { $0 / 1000.0 },
                artworkURL: artURL,
                previewURL: prev
            )
        }
    }

    private static func fetchITunesArtistMusicVideos(artistId: Int?) async -> [ArtistMusicVideoItem] {
        guard let artistId,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=musicVideo&limit=15"),
              let dict = await getJSON(url: url) as? [String: Any],
              let results = dict["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { row in
            guard (row["wrapperType"] as? String) == "track",
                  let tid = row["trackId"] as? Int,
                  let title = row["trackName"] as? String else {
                return nil
            }
            let artist = (row["artistName"] as? String) ?? ""
            let ms = row["trackTimeMillis"] as? Double
            let rel = (row["releaseDate"] as? String).flatMap { parseISODate($0) }
            let artURL = ((row["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100bb", with: "600x600bb"))
                .flatMap { URL(string: $0) }
            return ArtistMusicVideoItem(
                trackId: tid,
                title: title,
                artistName: artist,
                durationSeconds: ms.map { $0 / 1000.0 },
                artworkURL: artURL,
                releaseDate: rel
            )
        }
        .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
    }

    private static func fetchDeezerArtistTopTracks(deezerId: Int?) async -> [ArtistTopSongItem] {
        guard let deezerId,
              let url = URL(string: "https://api.deezer.com/artist/\(deezerId)/top?limit=15"),
              let dict = await getJSON(url: url) as? [String: Any],
              let rows = dict["data"] as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let title = row["title"] as? String else { return nil }
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            let albumDict = row["album"] as? [String: Any]
            let albumTitle = albumDict?["title"] as? String
            let artURL = ((albumDict?["cover_big"] as? String) ?? (albumDict?["cover_medium"] as? String))
                .flatMap { URL(string: $0) }
            let dur = row["duration"] as? Double
            let prev = (row["preview"] as? String).flatMap { URL(string: $0) }
            return ArtistTopSongItem(
                title: title,
                artistName: artist,
                albumTitle: albumTitle,
                durationSeconds: dur,
                artworkURL: artURL,
                previewURL: prev
            )
        }
    }

    private static func fetchDeezerSimilarArtists(deezerId: Int?) async -> [SimilarArtistItem] {
        guard let deezerId,
              let url = URL(string: "https://api.deezer.com/artist/\(deezerId)/related?limit=12"),
              let dict = await getJSON(url: url) as? [String: Any],
              let rows = dict["data"] as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let imgURL = ((row["picture_big"] as? String) ?? (row["picture_medium"] as? String))
                .flatMap { URL(string: $0) }
            return SimilarArtistItem(
                name: name,
                imageURL: imgURL,
                deezerArtistID: row["id"] as? Int
            )
        }
    }

    private static func mergeTopSongs(
        deezerSongs: [ArtistTopSongItem],
        iTunesSongs: [ArtistTopSongItem],
        defaultArtist: String
    ) -> [ArtistTopSongItem] {
        var out: [ArtistTopSongItem] = []
        var seen = Set<String>()
        for song in deezerSongs + iTunesSongs {
            let key = ArtistDatabase.normalizeLookupKey(ArtistDatabase.cleanSongTitleForSearch(rawTitle: song.title).songOnly)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(
                ArtistTopSongItem(
                    title: song.title,
                    artistName: song.artistName.isEmpty ? defaultArtist : song.artistName,
                    albumTitle: song.albumTitle,
                    durationSeconds: song.durationSeconds,
                    artworkURL: song.artworkURL,
                    previewURL: song.previewURL
                )
            )
            if out.count >= 20 { break }
        }
        return out
    }

    private static func getJSON(url: URL) async -> Any? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Combined TikTok + YouTube Trending Songs Feed

    func refreshTrendingSongsIfNeeded(force: Bool = false) async {
        if !force, let songs = state.trendingSongs, !songs.isEmpty,
           let refreshed = state.lastSongsRefreshedAt,
           Date().timeIntervalSince(refreshed) < 4 * 3600 {
            return
        }
        guard !isLoadingSongs else { return }
        await MainActor.run {
            self.isLoadingSongs = true
        }

        let year = Calendar.current.component(.year, from: .now)
        async let ytExploreTask = Self.fetchYouTubeExploreTrendingSongs()
        async let ytSearchTask = Self.fetchYouTubeOfficialMVTrending(year: year)
        async let ttPlaylistsTask = Self.fetchTikTokTrendingSongTracks(year: year)
        async let deezerChartTask = Self.fetchDeezerTopTrendingSongs()

        let ytExplore = await ytExploreTask
        let ytSearch = await ytSearchTask
        let ttSongs = await ttPlaylistsTask
        let dzCharts = await deezerChartTask

        let combined = Self.mergeTrendingSongs(
            youtubeExplore: ytExplore,
            youtubeSearch: ytSearch,
            tiktokTracks: ttSongs,
            chartTracks: dzCharts
        )

        await MainActor.run {
            if !combined.isEmpty {
                self.state.trendingSongs = combined
                self.state.lastSongsRefreshedAt = .now
                self.saveToDisk()
            }
            self.isLoadingSongs = false
        }
    }

    @MainActor
    @discardableResult
    func playTrendingSong(_ song: TrendingSongItem, isVideo: Bool = true) async -> Bool {
        let mm = MediaManager.shared
        if let vid = song.videoID,
           let local = mm.existingMediaItem(forVideoID: vid) {
            _ = mm.play(local)
            return true
        }
        let normTarget = ArtistDatabase.normalizeLookupKey(ArtistDatabase.cleanSongTitleForSearch(rawTitle: song.title).songOnly)
        if !normTarget.isEmpty,
           let localMatch = mm.items.first(where: { item in
               let itemTitle = ArtistDatabase.normalizeLookupKey(ArtistDatabase.cleanSongTitleForSearch(rawTitle: item.displayTitle).songOnly)
               return itemTitle == normTarget
           }) {
            _ = mm.play(localMatch)
            return true
        }

        resolvingSongID = song.id
        defer {
            if resolvingSongID == song.id {
                resolvingSongID = nil
            }
        }

        guard let resolved = await resolvePlayableTrendingStream(for: song) else {
            MediaManager.shared.errorMessage = "Could not load stream for \"\(song.title)\"."
            return false
        }

        let candidateStreams = resolved.streams
        let videoProgressive = candidateStreams.filter { !$0.isHLS && !$0.isAudio && $0.pairedAudioURL == nil }
        let hlsStreams = candidateStreams.filter { $0.isHLS }
        let audioStreams = candidateStreams.filter { $0.isAudio && !$0.isHLS }
        let directAny = candidateStreams.filter { !$0.isHLS && $0.pairedAudioURL == nil }

        let chosenStream: DetectedBrowserMedia?
        if isVideo && song.videoID != nil {
            chosenStream = videoProgressive.first ?? hlsStreams.first ?? directAny.first ?? audioStreams.first ?? candidateStreams.first
        } else {
            chosenStream = audioStreams.first ?? videoProgressive.first ?? hlsStreams.first ?? directAny.first ?? candidateStreams.first
        }
        guard let stream = chosenStream else { return false }

        mm.playRemoteStream(
            url: stream.url,
            title: song.title,
            artist: song.artist,
            headers: stream.customHeaders,
            isVideo: (song.videoID != nil && !stream.isAudio),
            sourceVideoID: resolved.videoID,
            artworkURL: song.artworkURL,
            durationSeconds: song.durationSeconds ?? resolved.durationSeconds
        )
        return true
    }

    @MainActor
    func cacheTrendingSongOffline(_ song: TrendingSongItem, downloader: WebMediaDownloader) async -> MediaItem? {
        resolvingSongID = song.id
        defer {
            if resolvingSongID == song.id {
                resolvingSongID = nil
            }
        }
        guard let resolved = await resolvePlayableTrendingStream(for: song),
              !resolved.streams.isEmpty else {
            MediaManager.shared.errorMessage = "Could not cache \"\(song.title)\"."
            return nil
        }
        let videoStreams = resolved.streams.filter { !$0.isAudio }
        let ordered = (song.videoID != nil && !videoStreams.isEmpty)
            ? videoStreams + resolved.streams.filter(\.isAudio)
            : resolved.streams
        guard let primary = ordered.first else { return nil }
        let media = DetectedBrowserMedia(
            url: primary.url,
            pairedAudioURL: primary.pairedAudioURL,
            isHLS: primary.isHLS,
            isAudio: primary.isAudio,
            title: song.title,
            author: song.artist,
            qualityLabel: primary.qualityLabel,
            referer: primary.referer,
            customHeaders: primary.customHeaders,
            durationSeconds: song.durationSeconds ?? resolved.durationSeconds ?? primary.durationSeconds,
            isActivelyPlaying: false
        )
        return await downloader.downloadGroupTrackOffline(
            media,
            fallbackStreams: Array(ordered.dropFirst()),
            sourceVideoID: resolved.videoID
        )
    }

    private func resolvePlayableTrendingStream(for song: TrendingSongItem) async -> YouTubeResolvedResult? {
        var targetVideoID = song.videoID
        if targetVideoID == nil || targetVideoID?.isEmpty == true {
            let clean = ArtistDatabase.cleanSongTitleForSearch(rawTitle: song.title)
            let q = [song.artist, clean.songOnly]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let hits = await PlaylistURLImporter.searchYouTubeTracks(query: q, limit: 5)
            targetVideoID = hits.first?.videoID
        }

        guard let vid = targetVideoID,
              !vid.isEmpty,
              let watchURL = URL(string: "https://www.youtube.com/watch?v=\(vid)") else {
            return nil
        }

        return await YouTubeStreamResolver.resolveStreamsWithUnrestrictedFallback(
            for: watchURL,
            videoID: vid,
            titleHint: song.title,
            authorHint: song.artist,
            durationHint: song.durationSeconds
        )
    }

    // MARK: - Combined TikTok & YouTube Feed Fetchers

    private static let ytRemixClientVersion = "1.20250311.01.00"
    private static let ytWebClientVersion = "2.20250311.00.00"

    private static func isBlockedCompilationTitle(_ rawTitle: String) -> Bool {
        let lower = rawTitle.lowercased()
        let banned = ["playlist", "mashup", "megamix", "nonstop", "1 hour", "1hr", "compilation", "mix 202"]
        return banned.contains(where: { lower.contains($0) })
    }

    private static func fetchYouTubeExploreTrendingSongs() async -> [TrendingSongItem] {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false") else {
            return []
        }
        let bodyObj: [String: Any] = [
            "browseId": "FEmusic_explore",
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": ytRemixClientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj) else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(ytRemixClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        func runsText(_ obj: Any?) -> String {
            guard let dict = obj as? [String: Any] else { return "" }
            if let s = dict["simpleText"] as? String { return s }
            if let runs = dict["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
            return ""
        }

        var out: [TrendingSongItem] = []
        var seenVID = Set<String>()

        func walk(_ node: Any, depth: Int) {
            guard depth < 24, out.count < 55 else { return }
            if let arr = node as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
                return
            }
            guard let dict = node as? [String: Any] else { return }
            if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                var vid = ((item["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
                if vid == nil,
                   let ov = item["overlay"] as? [String: Any],
                   let mt = ov["musicItemThumbnailOverlayRenderer"] as? [String: Any],
                   let cnt = mt["content"] as? [String: Any],
                   let btn = cnt["musicPlayButtonRenderer"] as? [String: Any],
                   let nav = btn["playNavigationEndpoint"] as? [String: Any] {
                    vid = (nav["watchEndpoint"] as? [String: Any])?["videoId"] as? String
                }
                let flexCols = item["flexColumns"] as? [[String: Any]] ?? []
                if vid == nil {
                    for col in flexCols {
                        let runs = ((col["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                        for r in runs {
                            if let v2 = ((r["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String, !v2.isEmpty {
                                vid = v2
                                break
                            }
                        }
                        if vid != nil { break }
                    }
                }
                if let vid, !vid.isEmpty, seenVID.insert(vid).inserted {
                    let cols = flexCols.map { runsText(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]) }
                    let rawTitle = (cols.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let artistPart = cols.count > 1
                        ? cols[1].components(separatedBy: " • ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        : ""
                    if !rawTitle.isEmpty, !isBlockedCompilationTitle(rawTitle) {
                        out.append(TrendingSongItem(
                            id: "yt:\(vid)",
                            title: rawTitle,
                            artist: artistPart.isEmpty ? "YouTube Music" : artistPart,
                            videoID: vid,
                            artworkURLString: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg",
                            platform: .youtube,
                            durationSeconds: nil
                        ))
                    }
                }
                return
            }
            if let two = dict["musicTwoRowItemRenderer"] as? [String: Any] {
                var vid = ((two["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
                if vid == nil,
                   let ov = two["thumbnailOverlay"] as? [String: Any],
                   let mt = ov["musicItemThumbnailOverlayRenderer"] as? [String: Any],
                   let cnt = mt["content"] as? [String: Any],
                   let btn = cnt["musicPlayButtonRenderer"] as? [String: Any],
                   let nav = btn["playNavigationEndpoint"] as? [String: Any] {
                    vid = (nav["watchEndpoint"] as? [String: Any])?["videoId"] as? String
                }
                if let vid, !vid.isEmpty, seenVID.insert(vid).inserted {
                    let rawTitle = runsText(two["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let artistPart = runsText(two["subtitle"]).components(separatedBy: " • ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !rawTitle.isEmpty, !isBlockedCompilationTitle(rawTitle) {
                        out.append(TrendingSongItem(
                            id: "yt:\(vid)",
                            title: rawTitle,
                            artist: artistPart.isEmpty ? "YouTube Music" : artistPart,
                            videoID: vid,
                            artworkURLString: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg",
                            platform: .youtube,
                            durationSeconds: nil
                        ))
                    }
                }
                return
            }
            for (_, v) in dict {
                if v is [String: Any] || v is [Any] {
                    walk(v, depth: depth + 1)
                }
            }
        }

        walk(json, depth: 0)
        return out
    }

    private static func fetchYouTubeOfficialMVTrending(year: Int) async -> [TrendingSongItem] {
        let hits = await PlaylistURLImporter.searchYouTubeTracks(query: "Official Music Video \(year)", limit: 25)
        return hits.compactMap { hit -> TrendingSongItem? in
            guard !hit.title.isEmpty, !isBlockedCompilationTitle(hit.title) else { return nil }
            if let dur = hit.durationSeconds, dur > 600 || dur < 30 { return nil }
            return TrendingSongItem(
                id: "yt:\(hit.videoID)",
                title: hit.title,
                artist: hit.artist.isEmpty ? "YouTube" : hit.artist,
                videoID: hit.videoID,
                artworkURLString: "https://i.ytimg.com/vi/\(hit.videoID)/hqdefault.jpg",
                platform: .youtube,
                durationSeconds: hit.durationSeconds
            )
        }
    }

    private static func fetchTikTokTrendingSongTracks(year: Int) async -> [TrendingSongItem] {
        var collected: [TrendingSongItem] = []
        var seenKeys = Set<String>()
        for query in ["TikTok Viral Hits \(year)", "TikTok Trending Songs"] {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let searchURL = URL(string: "https://api.deezer.com/search/playlist?q=\(encoded)&limit=5"),
                  let json = await getJSON(url: searchURL) as? [String: Any],
                  let playlists = json["data"] as? [[String: Any]] else {
                continue
            }
            for pl in playlists.filter({ ($0["nb_tracks"] as? Int ?? 0) >= 15 }).prefix(2) {
                guard let pid = pl["id"] as? Int,
                      let tracksURL = URL(string: "https://api.deezer.com/playlist/\(pid)/tracks?limit=35"),
                      let tJson = await getJSON(url: tracksURL) as? [String: Any],
                      let rows = tJson["data"] as? [[String: Any]] else {
                    continue
                }
                for row in rows {
                    guard let title = row["title"] as? String, !title.isEmpty else { continue }
                    let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
                    guard !artist.isEmpty else { continue }
                    let key = "\(ArtistDatabase.normalizeLookupKey(title))|\(ArtistDatabase.normalizeLookupKey(artist))"
                    guard seenKeys.insert(key).inserted else { continue }
                    let albumDict = row["album"] as? [String: Any]
                    let artStr = (albumDict?["cover_big"] as? String) ?? (albumDict?["cover_medium"] as? String)
                    let dur = row["duration"] as? Double
                    let idNum = (row["id"] as? Int).map(String.init) ?? key
                    collected.append(TrendingSongItem(
                        id: "tt:\(idNum)",
                        title: title,
                        artist: artist,
                        videoID: nil,
                        artworkURLString: artStr,
                        platform: .tiktok,
                        durationSeconds: dur
                    ))
                }
            }
        }
        return collected
    }

    private static func fetchDeezerTopTrendingSongs() async -> [TrendingSongItem] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/tracks?limit=35"),
              let dict = await getJSON(url: url) as? [String: Any],
              let rows = dict["data"] as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row -> TrendingSongItem? in
            guard let title = row["title"] as? String, !title.isEmpty else { return nil }
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            guard !artist.isEmpty else { return nil }
            let albumDict = row["album"] as? [String: Any]
            let artStr = (albumDict?["cover_big"] as? String) ?? (albumDict?["cover_medium"] as? String)
            let dur = row["duration"] as? Double
            let idNum = (row["id"] as? Int).map(String.init) ?? title
            return TrendingSongItem(
                id: "ttchart:\(idNum)",
                title: title,
                artist: artist,
                videoID: nil,
                artworkURLString: artStr,
                platform: .tiktok,
                durationSeconds: dur
            )
        }
    }

    private static func mergeTrendingSongs(
        youtubeExplore: [TrendingSongItem],
        youtubeSearch: [TrendingSongItem],
        tiktokTracks: [TrendingSongItem],
        chartTracks: [TrendingSongItem]
    ) -> [TrendingSongItem] {
        func songKey(_ item: TrendingSongItem) -> String {
            let clean = ArtistDatabase.cleanSongTitleForSearch(rawTitle: item.title)
            let songNorm = ArtistDatabase.normalizeLookupKey(clean.songOnly)
            let artistNorm = ArtistDatabase.normalizeLookupKey(item.artist)
            return "\(songNorm)|\(artistNorm)"
        }

        let ytPool = youtubeExplore + youtubeSearch
        let ttPool = tiktokTracks + chartTracks
        let ttKeys = Set(ttPool.map(songKey))

        var out: [TrendingSongItem] = []
        var seen = Set<String>()
        var seenVID = Set<String>()

        func appendIfNew(_ item: TrendingSongItem) {
            if let vid = item.videoID, !seenVID.insert(vid).inserted { return }
            let k = songKey(item)
            guard !k.isEmpty, seen.insert(k).inserted else { return }
            if item.platform == .youtube && ttKeys.contains(k) {
                out.append(TrendingSongItem(
                    id: item.id,
                    title: item.title,
                    artist: item.artist,
                    videoID: item.videoID,
                    artworkURLString: item.artworkURLString,
                    platform: .combined,
                    durationSeconds: item.durationSeconds
                ))
            } else {
                out.append(item)
            }
        }

        // Interleave YouTube Trending and TikTok Viral evenly down a long 80-item Discovery scroll.
        var yi = 0
        var ti = 0
        while out.count < 85 && (yi < ytPool.count || ti < ttPool.count) {
            for _ in 0..<2 where yi < ytPool.count && out.count < 85 {
                appendIfNew(ytPool[yi])
                yi += 1
            }
            for _ in 0..<2 where ti < ttPool.count && out.count < 85 {
                appendIfNew(ttPool[ti])
                ti += 1
            }
        }
        return out
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: storageFileURL, options: [.atomic])
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(TrendingArtistsPersistedState.self, from: data) {
            state = decoded
        }
    }
}
