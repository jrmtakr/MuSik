import Foundation
import Observation
import SwiftUI
import UserNotifications

struct WrappedTrackSummary: Codable, Hashable {
    var title: String
    var primaryArtist: String
    var relativePath: String?
}

struct WrappedArtistRecord: Codable, Hashable {
    var canonicalName: String
    var genre: String?
    var totalSeconds: Double = 0
    var playCount: Int = 0
    var tracksSeconds: [String: Double] = [:]
    var tracksPlayCount: [String: Int] = [:]
    var trackPaths: [String: String] = [:]
}

struct WrappedYearStats: Codable, Hashable {
    let year: Int
    var totalSeconds: Double = 0
    var totalPlays: Int = 0
    var artists: [String: WrappedArtistRecord] = [:]
    var secondsByMonth: [Int: Double] = [:]
    var secondsByHour: [Int: Double] = [:]
    var activeDayStrings: Set<String> = []
    var tracksGlobalSeconds: [String: Double] = [:]
    var tracksGlobalPlays: [String: Int] = [:]
    var tracksMeta: [String: WrappedTrackSummary] = [:]
}

private struct WrappedPersistedDatabase: Codable {
    var years: [Int: WrappedYearStats] = [:]
    var customArtistAliases: [String: String] = [:]
    var ignoredChannelNames: [String]? = nil
    var revealedYears: Set<Int> = []
    var reminderNotificationsEnabled: Bool = true
    var countConfirmedFilesOnly: Bool? = false
}

enum WrappedAuditReason: String, Hashable {
    case unknownArtist = "Unknown Artist"
    case suspectedChannel = "Uploader / Channel Tag"
    case uncataloguedArtist = "Unconfirmed Artist"
}

struct WrappedAuditItem: Identifiable, Hashable {
    var id: String { item.relativePath }
    let item: MediaItem
    let detectedArtist: String
    let detectedGenre: String?
    let trackedSeconds: Double
    let trackedPlays: Int
    let reason: WrappedAuditReason
}

struct WrappedArtistRanking: Identifiable, Hashable {
    var id: String { normalizedKey }
    let normalizedKey: String
    let canonicalName: String
    let genre: String?
    let totalSeconds: Double
    let playCount: Int
    let sharePercentage: Double
    let topTrackTitle: String?
    let trackEntries: [(title: String, seconds: Double, plays: Int, relativePath: String?)]

    static func == (lhs: WrappedArtistRanking, rhs: WrappedArtistRanking) -> Bool {
        lhs.normalizedKey == rhs.normalizedKey &&
            lhs.canonicalName == rhs.canonicalName &&
            lhs.totalSeconds == rhs.totalSeconds &&
            lhs.playCount == rhs.playCount
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedKey)
        hasher.combine(canonicalName)
        hasher.combine(totalSeconds)
        hasher.combine(playCount)
    }
}

struct WrappedTrackRanking: Identifiable, Hashable {
    var id: String { normalizedKey }
    let normalizedKey: String
    let title: String
    let primaryArtist: String
    let relativePath: String?
    let totalSeconds: Double
    let playCount: Int
}

struct WrappedSummaryReport {
    let scopeLabel: String
    let year: Int?
    let totalSeconds: Double
    let totalPlays: Int
    let namedArtists: [WrappedArtistRanking]
    let allArtists: [WrappedArtistRanking]
    let topSongs: [WrappedTrackRanking]
    let topGenres: [(genre: String, seconds: Double, percentage: Double)]
    let monthlyBreakdown: [(month: Int, label: String, seconds: Double)]
    let peakMonth: (month: Int, name: String, seconds: Double)?
    let peakHourLabel: String
    let activeDaysCount: Int
    let longestStreakDays: Int
    let personaTitle: String
    let personaSubtitle: String
    let personaSystemImage: String
    let strictConfirmedOnly: Bool
    let excludedUnconfirmedSeconds: Double

    var heroTopArtist: WrappedArtistRanking? {
        namedArtists.first ?? allArtists.first
    }

    var totalMinutes: Int {
        Int((totalSeconds / 60.0).rounded())
    }

    var formattedDurationHero: String {
        if totalSeconds >= 3600 {
            let hrs = totalSeconds / 3600.0
            return String(format: "%.1f hrs", hrs)
        }
        let mins = max(1, Int((totalSeconds / 60.0).rounded()))
        return totalSeconds < 60 ? "\(Int(totalSeconds.rounded())) sec" : "\(mins) min"
    }
}

@Observable
final class ListeningWrappedService {
    static let shared = ListeningWrappedService()

    private static let dec1NotificationID = "musicplayer.wrapped.december1"

    private var db = WrappedPersistedDatabase()
    var pendingOpenWrappedSheet = false
    var shouldPresentDecemberPremiere = false
    private(set) var lastUpdatedTick: Date = .now

    // Active playback tracking state (wall-clock uptime heartbeat so seeks never inflate stats)
    @ObservationIgnored private var activeTrackKey: String?
    @ObservationIgnored private var activeTrackTitle: String = ""
    @ObservationIgnored private var activeArtistName: String = ""
    @ObservationIgnored private var activeArtistGenre: String?
    @ObservationIgnored private var activeRelativePath: String?
    @ObservationIgnored private var lastHeartbeatUptime: TimeInterval?
    @ObservationIgnored private var activeSessionAccumulatedSeconds: Double = 0
    @ObservationIgnored private var didCountPlayForCurrentSession = false
    @ObservationIgnored private var pendingDiskSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastNotificationRefreshAt: Date?

    private var storageFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("listening_wrapped.json")
    }

    var ignoredChannels: Set<String> {
        Set(db.ignoredChannelNames ?? [])
    }

    var countConfirmedFilesOnly: Bool {
        get { db.countConfirmedFilesOnly ?? false }
        set {
            db.countConfirmedFilesOnly = newValue
            lastUpdatedTick = .now
            scheduleDiskSave(immediate: true)
        }
    }

    var notificationsEnabled: Bool {
        get { db.reminderNotificationsEnabled }
        set {
            db.reminderNotificationsEnabled = newValue
            scheduleDiskSave(immediate: true)
            if newValue {
                Task { await requestPermissionAndScheduleDecemberDrop() }
            } else {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.dec1NotificationID])
            }
        }
    }

    private init() {
        loadFromDisk()
        evaluateDecemberPremiereIfNeeded()
    }

    // MARK: - Playback Tracking

    func beginOrResumeSession(
        for item: MediaItem,
        resolvedTitle: String,
        resolvedArtistTag: String?,
        isArtistVerified: Bool = false
    ) {
        let sessionKey = "\(item.relativePath)|\(resolvedTitle)|\(resolvedArtistTag ?? "")|\(isArtistVerified ? "1" : "0")"
        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: resolvedArtistTag,
            rawTitle: resolvedTitle,
            fileName: item.fileName,
            customAliases: db.customArtistAliases,
            ignoredChannels: ignoredChannels,
            isArtistVerified: isArtistVerified
        )

        if activeTrackKey == sessionKey {
            // Same track resuming from pause
            lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
            return
        }

        // Switching tracks cleanly commits any accumulated delta first
        commitPendingDelta(isFinal: true)

        activeTrackKey = sessionKey
        activeTrackTitle = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.displayTitle : resolvedTitle
        activeArtistName = extracted.primaryArtist
        activeArtistGenre = extracted.genre
        activeRelativePath = item.relativePath.hasPrefix("__remote__/") ? nil : item.relativePath
        activeSessionAccumulatedSeconds = 0
        didCountPlayForCurrentSession = false
        lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
    }

    func recordPlaybackHeartbeat(
        for item: MediaItem?,
        resolvedTitle: String?,
        resolvedArtistTag: String?,
        isArtistVerified: Bool = false,
        isPlaying: Bool
    ) {
        guard isPlaying, let item else {
            pauseSession()
            return
        }

        let title = (resolvedTitle?.isEmpty == false ? resolvedTitle : nil) ?? item.displayTitle
        let sessionKey = "\(item.relativePath)|\(title)|\(resolvedArtistTag ?? "")|\(isArtistVerified ? "1" : "0")"

        if activeTrackKey != sessionKey {
            beginOrResumeSession(
                for: item,
                resolvedTitle: title,
                resolvedArtistTag: resolvedArtistTag,
                isArtistVerified: isArtistVerified
            )
            return
        }

        let nowUptime = ProcessInfo.processInfo.systemUptime
        if let prev = lastHeartbeatUptime {
            let delta = nowUptime - prev
            if delta >= 0.8 {
                lastHeartbeatUptime = nowUptime
                let boundedDelta = min(delta, 5.0)
                if boundedDelta > 0 {
                    applyListeningDelta(seconds: boundedDelta, date: .now)
                }
            }
        } else {
            lastHeartbeatUptime = nowUptime
        }
    }

    func pauseSession() {
        commitPendingDelta(isFinal: false)
        lastHeartbeatUptime = nil
    }

    func endSession(didFinishTrack: Bool = false) {
        commitPendingDelta(isFinal: true, didFinishTrack: didFinishTrack)
        activeTrackKey = nil
        lastHeartbeatUptime = nil
        activeSessionAccumulatedSeconds = 0
        didCountPlayForCurrentSession = false
    }

    private func commitPendingDelta(isFinal: Bool, didFinishTrack: Bool = false) {
        if let prev = lastHeartbeatUptime {
            let nowUptime = ProcessInfo.processInfo.systemUptime
            let delta = max(0, min(nowUptime - prev, 5.0))
            if delta > 0.15 {
                applyListeningDelta(seconds: delta, date: .now, forcePlayIfFinished: didFinishTrack && activeSessionAccumulatedSeconds + delta >= 3.0)
            } else if didFinishTrack && !didCountPlayForCurrentSession && activeSessionAccumulatedSeconds >= 3.0 {
                incrementPlayCounts(date: .now)
            }
        } else if didFinishTrack && !didCountPlayForCurrentSession && activeSessionAccumulatedSeconds >= 3.0 {
            incrementPlayCounts(date: .now)
        }
        if isFinal {
            scheduleDiskSave(immediate: false)
        }
    }

    private func applyListeningDelta(
        seconds: Double,
        date: Date,
        forcePlayIfFinished: Bool = false
    ) {
        guard activeTrackKey != nil else { return }
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let hour = cal.component(.hour, from: date)
        let dayStr = Self.dayKeyFormatter.string(from: date)

        var yStats = db.years[year] ?? WrappedYearStats(year: year)
        yStats.totalSeconds += seconds
        yStats.secondsByMonth[month, default: 0] += seconds
        yStats.secondsByHour[hour, default: 0] += seconds
        yStats.activeDayStrings.insert(dayStr)

        let artistKey = ArtistDatabase.normalizeLookupKey(activeArtistName)
        let safeArtistKey = artistKey.isEmpty ? "unknown artist" : artistKey
        var artistRec = yStats.artists[safeArtistKey] ?? WrappedArtistRecord(
            canonicalName: activeArtistName,
            genre: activeArtistGenre ?? ArtistDatabase.genre(forArtist: activeArtistName)
        )
        artistRec.totalSeconds += seconds
        artistRec.tracksSeconds[activeTrackTitle, default: 0] += seconds
        if let rel = activeRelativePath {
            artistRec.trackPaths[activeTrackTitle] = rel
        }
        yStats.artists[safeArtistKey] = artistRec

        let trackNorm = ArtistDatabase.normalizeLookupKey(activeTrackTitle)
        let safeTrackKey = trackNorm.isEmpty ? activeTrackTitle.lowercased() : trackNorm
        yStats.tracksGlobalSeconds[safeTrackKey, default: 0] += seconds
        yStats.tracksMeta[safeTrackKey] = WrappedTrackSummary(
            title: activeTrackTitle,
            primaryArtist: activeArtistName,
            relativePath: activeRelativePath ?? yStats.tracksMeta[safeTrackKey]?.relativePath
        )

        db.years[year] = yStats
        activeSessionAccumulatedSeconds += seconds

        if !didCountPlayForCurrentSession && (activeSessionAccumulatedSeconds >= 8.0 || forcePlayIfFinished) {
            incrementPlayCounts(date: date)
        }

        lastUpdatedTick = .now
        scheduleDiskSave(immediate: false)
    }

    private func incrementPlayCounts(date: Date) {
        guard !didCountPlayForCurrentSession else { return }
        didCountPlayForCurrentSession = true

        let year = Calendar.current.component(.year, from: date)
        var yStats = db.years[year] ?? WrappedYearStats(year: year)
        yStats.totalPlays += 1

        let artistKey = ArtistDatabase.normalizeLookupKey(activeArtistName)
        let safeArtistKey = artistKey.isEmpty ? "unknown artist" : artistKey
        var artistRec = yStats.artists[safeArtistKey] ?? WrappedArtistRecord(
            canonicalName: activeArtistName,
            genre: activeArtistGenre ?? ArtistDatabase.genre(forArtist: activeArtistName)
        )
        artistRec.playCount += 1
        artistRec.tracksPlayCount[activeTrackTitle, default: 0] += 1
        yStats.artists[safeArtistKey] = artistRec

        let trackNorm = ArtistDatabase.normalizeLookupKey(activeTrackTitle)
        let safeTrackKey = trackNorm.isEmpty ? activeTrackTitle.lowercased() : trackNorm
        yStats.tracksGlobalPlays[safeTrackKey, default: 0] += 1

        db.years[year] = yStats
        evaluateDecemberPremiereIfNeeded()
        refreshDecemberNotificationIfDue()
    }

    // MARK: - December 1st Annual Drop & Notifications

    static func isDecemberRevealActive(date: Date = .now) -> Bool {
        Calendar.current.component(.month, from: date) == 12
    }

    static func daysUntilDecemberFirst(from date: Date = .now) -> Int {
        let cal = Calendar.current
        let month = cal.component(.month, from: date)
        if month == 12 { return 0 }
        let year = cal.component(.year, from: date)
        guard let target = cal.date(from: DateComponents(year: year, month: 12, day: 1)) else {
            return 0
        }
        let startToday = cal.startOfDay(for: date)
        let startTarget = cal.startOfDay(for: target)
        return max(0, cal.dateComponents([.day], from: startToday, to: startTarget).day ?? 0)
    }

    func evaluateDecemberPremiereIfNeeded() {
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        guard Self.isDecemberRevealActive(date: now),
              !db.revealedYears.contains(year),
              let yearStats = db.years[year],
              yearStats.totalSeconds >= 5 else {
            return
        }
        shouldPresentDecemberPremiere = true
    }

    func markPremiereViewed(for year: Int) {
        db.revealedYears.insert(year)
        shouldPresentDecemberPremiere = false
        scheduleDiskSave(immediate: true)
    }

    func triggerPreviewPremiere() {
        shouldPresentDecemberPremiere = true
    }

    func requestPermissionAndScheduleDecemberDrop() async {
        guard db.reminderNotificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        scheduleDecemberFirstNotification()
    }

    func scheduleDecemberFirstNotification() {
        guard db.reminderNotificationsEnabled else { return }
        let currentYear = Calendar.current.component(.year, from: .now)
        let report = report(forYear: currentYear)

        let content = UNMutableNotificationContent()
        content.title = "\(currentYear) MuSeJRM Wrapped Is Ready!"
        if let hero = report.heroTopArtist {
            let formatted = Self.formatHoursMinutes(hero.totalSeconds)
            content.body = "Your #1 artist of the year is \(hero.canonicalName) (\(formatted), \(hero.playCount) streams). Tap to reveal your Wrapped!"
        } else {
            content.body = "December 1st is here! Tap to see your top listened artists of the year."
        }
        content.sound = .default
        content.userInfo = ["wrappedDeepLink": "musicplayer://wrapped"]

        var components = DateComponents()
        components.month = 12
        components.day = 1
        components.hour = 9
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.dec1NotificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func refreshDecemberNotificationIfDue() {
        guard db.reminderNotificationsEnabled else { return }
        if let last = lastNotificationRefreshAt, Date().timeIntervalSince(last) < 60 {
            return
        }
        lastNotificationRefreshAt = .now
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            Task { @MainActor [weak self] in
                self?.scheduleDecemberFirstNotification()
            }
        }
    }

    // MARK: - Custom Alias & Merging & Re-Scan

    func renameOrMergeArtist(oldKey: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let catalogCanon = ArtistDatabase.canonicalizeSingle(trimmed)
        let newKey = ArtistDatabase.normalizeLookupKey(catalogCanon)
        guard !newKey.isEmpty, oldKey != newKey else { return }

        if oldKey != "unknown artist" {
            db.customArtistAliases[oldKey] = catalogCanon
        }

        for year in db.years.keys {
            guard var stats = db.years[year],
                  let oldRec = stats.artists.removeValue(forKey: oldKey) else {
                continue
            }
            var target = stats.artists[newKey] ?? WrappedArtistRecord(
                canonicalName: catalogCanon,
                genre: ArtistDatabase.genre(forArtist: catalogCanon) ?? oldRec.genre
            )
            target.totalSeconds += oldRec.totalSeconds
            target.playCount += oldRec.playCount
            for (tTitle, secs) in oldRec.tracksSeconds {
                target.tracksSeconds[tTitle, default: 0] += secs
            }
            for (tTitle, pCount) in oldRec.tracksPlayCount {
                target.tracksPlayCount[tTitle, default: 0] += pCount
            }
            for (tTitle, relPath) in oldRec.trackPaths {
                target.trackPaths[tTitle] = relPath
            }
            stats.artists[newKey] = target

            for (trackKey, meta) in stats.tracksMeta {
                if ArtistDatabase.normalizeLookupKey(meta.primaryArtist) == oldKey {
                    stats.tracksMeta[trackKey]?.primaryArtist = catalogCanon
                }
            }
            db.years[year] = stats
        }

        lastUpdatedTick = .now
        scheduleDiskSave(immediate: true)
    }

    func reattributeTrack(
        relativePath: String?,
        oldTrackTitle: String?,
        newTrackTitle: String? = nil,
        toVerifiedArtist rawArtist: String,
        genre: String? = nil
    ) {
        let trimmedArtist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return }
        let canonical = ArtistDatabase.canonicalizeSingle(trimmedArtist, customAliases: db.customArtistAliases)
        let newKey = ArtistDatabase.normalizeLookupKey(canonical)
        guard !newKey.isEmpty else { return }

        let resolvedGenre = genre ?? ArtistDatabase.genre(forArtist: canonical)
        let normOldTitle = oldTrackTitle.map { ArtistDatabase.normalizeLookupKey($0) }
        let normNewTitle = newTrackTitle.map { ArtistDatabase.normalizeLookupKey($0) }
        let preferredTitle = newTrackTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        var didModify = false
        for year in Array(db.years.keys) {
            guard var stats = db.years[year] else { continue }

            for oldArtistKey in Array(stats.artists.keys) {
                guard var oldRec = stats.artists[oldArtistKey] else { continue }
                let matchingTitles = oldRec.tracksSeconds.keys.filter { tTitle in
                    if let relativePath, oldRec.trackPaths[tTitle] == relativePath {
                        return true
                    }
                    let tNorm = ArtistDatabase.normalizeLookupKey(tTitle)
                    if let normOldTitle, !normOldTitle.isEmpty, tNorm == normOldTitle {
                        return true
                    }
                    if let normNewTitle, !normNewTitle.isEmpty, tNorm == normNewTitle {
                        return true
                    }
                    return false
                }
                guard !matchingTitles.isEmpty else { continue }

                if oldArtistKey == newKey {
                    // Same canonical artist: still consolidate noisy track titles & ensure genre/path stay current
                    var changedInsideSameArtist = false
                    for oldT in matchingTitles {
                        let destTitle = (preferredTitle?.isEmpty == false ? preferredTitle! : oldT)
                        if let relativePath, oldRec.trackPaths[destTitle] != relativePath {
                            oldRec.trackPaths[destTitle] = relativePath
                            changedInsideSameArtist = true
                        }
                        if oldT != destTitle {
                            let secs = oldRec.tracksSeconds.removeValue(forKey: oldT) ?? 0
                            let plays = oldRec.tracksPlayCount.removeValue(forKey: oldT) ?? 0
                            let savedPath = oldRec.trackPaths.removeValue(forKey: oldT) ?? relativePath
                            oldRec.tracksSeconds[destTitle, default: 0] += secs
                            oldRec.tracksPlayCount[destTitle, default: 0] += plays
                            if let savedPath {
                                oldRec.trackPaths[destTitle] = savedPath
                            }
                            changedInsideSameArtist = true
                        }
                    }
                    if oldRec.genre == nil, let resolvedGenre {
                        oldRec.genre = resolvedGenre
                        changedInsideSameArtist = true
                    }
                    if changedInsideSameArtist {
                        stats.artists[newKey] = oldRec
                        didModify = true
                    }
                    continue
                }

                var target = stats.artists[newKey] ?? WrappedArtistRecord(
                    canonicalName: canonical,
                    genre: resolvedGenre
                )
                if target.genre == nil { target.genre = resolvedGenre }

                var movedSecs = 0.0
                var movedPlays = 0
                for oldT in matchingTitles {
                    let secs = oldRec.tracksSeconds.removeValue(forKey: oldT) ?? 0
                    let plays = oldRec.tracksPlayCount.removeValue(forKey: oldT) ?? 0
                    let savedPath = oldRec.trackPaths.removeValue(forKey: oldT) ?? relativePath
                    let destTitle = (preferredTitle?.isEmpty == false ? preferredTitle! : oldT)

                    target.totalSeconds += secs
                    target.playCount += plays
                    target.tracksSeconds[destTitle, default: 0] += secs
                    target.tracksPlayCount[destTitle, default: 0] += plays
                    if let savedPath {
                        target.trackPaths[destTitle] = savedPath
                    }
                    movedSecs += secs
                    movedPlays += plays
                }

                oldRec.totalSeconds = max(0, oldRec.totalSeconds - movedSecs)
                oldRec.playCount = max(0, oldRec.playCount - movedPlays)
                if oldRec.tracksSeconds.isEmpty || oldRec.totalSeconds < 0.05 {
                    stats.artists.removeValue(forKey: oldArtistKey)
                } else {
                    stats.artists[oldArtistKey] = oldRec
                }
                stats.artists[newKey] = target
                didModify = true
            }

            // Merge/update global top songs entry when title or artist changed
            var mergedTrackSecs = 0.0
            var mergedTrackPlays = 0
            var destGlobalKey: String?
            if let preferredTitle, !preferredTitle.isEmpty {
                let normPref = ArtistDatabase.normalizeLookupKey(preferredTitle)
                destGlobalKey = normPref.isEmpty ? preferredTitle.lowercased() : normPref
            }

            for trackKey in Array(stats.tracksMeta.keys) {
                guard let meta = stats.tracksMeta[trackKey] else { continue }
                let matchesPath = relativePath != nil && meta.relativePath == relativePath
                let matchesOld = normOldTitle != nil && !normOldTitle!.isEmpty && ArtistDatabase.normalizeLookupKey(meta.title) == normOldTitle
                guard matchesPath || matchesOld else { continue }

                if let destGlobalKey, destGlobalKey != trackKey {
                    mergedTrackSecs += stats.tracksGlobalSeconds.removeValue(forKey: trackKey) ?? 0
                    mergedTrackPlays += stats.tracksGlobalPlays.removeValue(forKey: trackKey) ?? 0
                    stats.tracksMeta.removeValue(forKey: trackKey)
                } else {
                    stats.tracksMeta[trackKey]?.primaryArtist = canonical
                    if let preferredTitle, !preferredTitle.isEmpty {
                        stats.tracksMeta[trackKey]?.title = preferredTitle
                    }
                }
                didModify = true
            }

            if let destGlobalKey, mergedTrackSecs > 0 || mergedTrackPlays > 0 {
                stats.tracksGlobalSeconds[destGlobalKey, default: 0] += mergedTrackSecs
                stats.tracksGlobalPlays[destGlobalKey, default: 0] += mergedTrackPlays
                stats.tracksMeta[destGlobalKey] = WrappedTrackSummary(
                    title: preferredTitle!,
                    primaryArtist: canonical,
                    relativePath: relativePath ?? stats.tracksMeta[destGlobalKey]?.relativePath
                )
            }

            db.years[year] = stats
        }

        if didModify {
            lastUpdatedTick = .now
            scheduleDiskSave(immediate: true)
            refreshDecemberNotificationIfDue()
        }
    }

    @discardableResult
    func markAsUploaderChannel(
        _ rawNameOrKey: String,
        libraryItems: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> Int {
        let channelKey = ArtistDatabase.normalizeLookupKey(rawNameOrKey)
        guard !channelKey.isEmpty, channelKey != "unknown artist" else { return 0 }

        var existing = db.ignoredChannelNames ?? []
        if !existing.contains(channelKey) {
            existing.append(channelKey)
            db.ignoredChannelNames = existing
        }

        var reassignedCount = 0
        let updatedIgnored = Set(existing)

        for year in Array(db.years.keys) {
            guard let stats = db.years[year],
                  let channelRec = stats.artists[channelKey] else {
                continue
            }
            for tTitle in Array(channelRec.tracksSeconds.keys) {
                let relPath = channelRec.trackPaths[tTitle]
                let item = relPath.flatMap { p in libraryItems.first(where: { $0.relativePath == p }) }
                let custom = relPath.flatMap { metadataByPath[$0] }
                let isVerified = custom?.isArtistVerified == true
                let rawTag = isVerified ? custom?.artist : nil
                let extracted = ArtistDatabase.extractArtists(
                    rawArtistTag: rawTag,
                    rawTitle: tTitle,
                    fileName: item?.fileName,
                    customAliases: db.customArtistAliases,
                    ignoredChannels: updatedIgnored,
                    isArtistVerified: isVerified
                )
                reattributeTrack(
                    relativePath: relPath,
                    oldTrackTitle: tTitle,
                    newTrackTitle: nil,
                    toVerifiedArtist: extracted.primaryArtist,
                    genre: extracted.genre
                )
                reassignedCount += 1
            }
        }

        lastUpdatedTick = .now
        scheduleDiskSave(immediate: true)
        return reassignedCount
    }

    func removeIgnoredChannel(_ key: String) {
        let norm = ArtistDatabase.normalizeLookupKey(key)
        guard var list = db.ignoredChannelNames else { return }
        list.removeAll { $0 == norm }
        db.ignoredChannelNames = list
        lastUpdatedTick = .now
        scheduleDiskSave(immediate: true)
    }

    func trackedStatsForTrack(relativePath: String, title: String) -> (seconds: Double, plays: Int) {
        let normTitle = ArtistDatabase.normalizeLookupKey(title)
        var totalSecs = 0.0
        var totalPlays = 0
        for yearStats in db.years.values {
            for rec in yearStats.artists.values {
                for (tTitle, secs) in rec.tracksSeconds {
                    if rec.trackPaths[tTitle] == relativePath ||
                        (!normTitle.isEmpty && ArtistDatabase.normalizeLookupKey(tTitle) == normTitle) {
                        totalSecs += secs
                        totalPlays += rec.tracksPlayCount[tTitle] ?? 0
                    }
                }
            }
        }
        return (totalSecs, totalPlays)
    }

    func assessItem(
        _ item: MediaItem,
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> (artist: String, genre: String?, reason: WrappedAuditReason?, isVerified: Bool) {
        let custom = metadataByPath[item.relativePath]
        let isVerified = custom?.isArtistVerified == true && !(custom?.artist?.isEmpty ?? true)
        let title = custom?.title ?? item.displayTitle
        let rawTag = custom?.artist ?? item.artist

        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: rawTag,
            rawTitle: title,
            fileName: item.fileName,
            customAliases: db.customArtistAliases,
            ignoredChannels: ignoredChannels,
            isArtistVerified: isVerified
        )

        if isVerified {
            return (extracted.primaryArtist, custom?.genre ?? extracted.genre, nil, true)
        }
        let norm = ArtistDatabase.normalizeLookupKey(extracted.primaryArtist)
        if norm.isEmpty || norm == "unknown artist" {
            return (extracted.primaryArtist, nil, .unknownArtist, false)
        }
        if ArtistDatabase.looksLikeUploaderChannel(extracted.primaryArtist, customIgnoredChannels: ignoredChannels) {
            return (extracted.primaryArtist, nil, .suspectedChannel, false)
        }
        if !extracted.matchedFromCatalog {
            return (extracted.primaryArtist, extracted.genre, .uncataloguedArtist, false)
        }
        return (extracted.primaryArtist, extracted.genre, nil, false)
    }

    func auditItems(
        libraryItems: [MediaItem],
        metadataByPath: [String: MediaManager.CustomTrackMetadata]
    ) -> [WrappedAuditItem] {
        var list: [WrappedAuditItem] = []
        for item in libraryItems where !item.isVideo {
            let assessment = assessItem(item, metadataByPath: metadataByPath)
            guard !assessment.isVerified, let reason = assessment.reason else {
                continue
            }
            let stats = trackedStatsForTrack(relativePath: item.relativePath, title: item.displayTitle)
            list.append(
                WrappedAuditItem(
                    item: item,
                    detectedArtist: assessment.artist,
                    detectedGenre: assessment.genre,
                    trackedSeconds: stats.seconds,
                    trackedPlays: stats.plays,
                    reason: reason
                )
            )
        }
        return list.sorted { lhs, rhs in
            if lhs.trackedSeconds != rhs.trackedSeconds {
                return lhs.trackedSeconds > rhs.trackedSeconds
            }
            if lhs.reason != rhs.reason {
                let rank: (WrappedAuditReason) -> Int = {
                    switch $0 {
                    case .suspectedChannel: return 0
                    case .unknownArtist: return 1
                    case .uncataloguedArtist: return 2
                    }
                }
                return rank(lhs.reason) < rank(rhs.reason)
            }
            return lhs.item.displayTitle.localizedCaseInsensitiveCompare(rhs.item.displayTitle) == .orderedAscending
        }
    }

    // MARK: - Wrapped Reporting

    var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: .now)
        var all = Set(db.years.keys)
        all.insert(currentYear)
        return all.sorted(by: >)
    }

    func report(
        forYear year: Int?,
        verifiedPaths: Set<String>? = nil,
        onlyConfirmed: Bool? = nil
    ) -> WrappedSummaryReport {
        let scopeStats: WrappedYearStats
        let scopeLabel: String

        if let year {
            scopeStats = db.years[year] ?? WrappedYearStats(year: year)
            scopeLabel = "\(year) Wrapped"
        } else {
            scopeLabel = "All-Time Wrapped"
            var combined = WrappedYearStats(year: 0)
            for y in db.years.values {
                combined.totalSeconds += y.totalSeconds
                combined.totalPlays += y.totalPlays
                for (m, s) in y.secondsByMonth { combined.secondsByMonth[m, default: 0] += s }
                for (h, s) in y.secondsByHour { combined.secondsByHour[h, default: 0] += s }
                combined.activeDayStrings.formUnion(y.activeDayStrings)
                for (tk, s) in y.tracksGlobalSeconds { combined.tracksGlobalSeconds[tk, default: 0] += s }
                for (tk, p) in y.tracksGlobalPlays { combined.tracksGlobalPlays[tk, default: 0] += p }
                for (tk, meta) in y.tracksMeta { combined.tracksMeta[tk] = meta }
                for (ak, rec) in y.artists {
                    var target = combined.artists[ak] ?? WrappedArtistRecord(canonicalName: rec.canonicalName, genre: rec.genre)
                    target.totalSeconds += rec.totalSeconds
                    target.playCount += rec.playCount
                    for (t, s) in rec.tracksSeconds { target.tracksSeconds[t, default: 0] += s }
                    for (t, p) in rec.tracksPlayCount { target.tracksPlayCount[t, default: 0] += p }
                    for (t, path) in rec.trackPaths { target.trackPaths[t] = path }
                    combined.artists[ak] = target
                }
            }
            scopeStats = combined
        }

        let strictMode = (onlyConfirmed ?? countConfirmedFilesOnly) && (verifiedPaths != nil)
        let activeVerified = verifiedPaths ?? []
        var excludedUnconfirmedSecs = 0.0

        var filteredArtistEntries: [(key: String, rec: WrappedArtistRecord, totalSecs: Double, totalPlays: Int, filteredTracks: [(title: String, seconds: Double, plays: Int, relativePath: String?)])] = []

        for (key, rec) in scopeStats.artists {
            let tracks = rec.tracksSeconds.keys.compactMap { tTitle -> (title: String, seconds: Double, plays: Int, relativePath: String?)? in
                let secs = rec.tracksSeconds[tTitle] ?? 0
                let plays = rec.tracksPlayCount[tTitle] ?? 0
                let relPath = rec.trackPaths[tTitle]
                if let verifiedPaths {
                    let isConfirmed = relPath.map { verifiedPaths.contains($0) } ?? false
                    if !isConfirmed {
                        excludedUnconfirmedSecs += secs
                    }
                    if strictMode && !isConfirmed {
                        return nil
                    }
                }
                return (title: tTitle, seconds: secs, plays: plays, relativePath: relPath)
            }
            .sorted { $0.seconds > $1.seconds }

            if strictMode && tracks.isEmpty {
                continue
            }
            let artistSecs = strictMode ? tracks.reduce(0) { $0 + $1.seconds } : rec.totalSeconds
            let artistPlays = strictMode ? tracks.reduce(0) { $0 + $1.plays } : rec.playCount
            filteredArtistEntries.append((key, rec, artistSecs, artistPlays, tracks))
        }

        let totalSec = strictMode
            ? max(0, filteredArtistEntries.reduce(0) { $0 + $1.totalSecs })
            : max(0, scopeStats.totalSeconds)
        let totalPlaysCount = strictMode
            ? filteredArtistEntries.reduce(0) { $0 + $1.totalPlays }
            : scopeStats.totalPlays

        let sortedArtistEntries = filteredArtistEntries.sorted { lhs, rhs in
            if lhs.totalSecs != rhs.totalSecs {
                return lhs.totalSecs > rhs.totalSecs
            }
            return lhs.totalPlays > rhs.totalPlays
        }

        let allRankings: [WrappedArtistRanking] = sortedArtistEntries.map { entry in
            let share = totalSec > 0 ? (entry.totalSecs / totalSec) * 100.0 : 0
            return WrappedArtistRanking(
                normalizedKey: entry.key,
                canonicalName: entry.rec.canonicalName,
                genre: entry.rec.genre ?? ArtistDatabase.genre(forArtist: entry.rec.canonicalName),
                totalSeconds: entry.totalSecs,
                playCount: entry.totalPlays,
                sharePercentage: share,
                topTrackTitle: entry.filteredTracks.first?.title,
                trackEntries: entry.filteredTracks
            )
        }

        let namedArtists = allRankings.filter { $0.normalizedKey != "unknown artist" }

        let topSongs: [WrappedTrackRanking] = scopeStats.tracksGlobalSeconds.compactMap { tk, secs in
            let meta = scopeStats.tracksMeta[tk]
            if strictMode {
                guard let rel = meta?.relativePath, activeVerified.contains(rel) else { return nil }
            }
            return WrappedTrackRanking(
                normalizedKey: tk,
                title: meta?.title ?? tk,
                primaryArtist: meta?.primaryArtist ?? "Unknown Artist",
                relativePath: meta?.relativePath,
                totalSeconds: secs,
                playCount: scopeStats.tracksGlobalPlays[tk] ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalSeconds != rhs.totalSeconds { return lhs.totalSeconds > rhs.totalSeconds }
            return lhs.playCount > rhs.playCount
        }

        var genreBuckets: [String: Double] = [:]
        var categorizedTotal = 0.0
        for artist in namedArtists {
            let g = artist.genre ?? "Independent / Other"
            genreBuckets[g, default: 0] += artist.totalSeconds
            categorizedTotal += artist.totalSeconds
        }
        let topGenres = genreBuckets
            .sorted { $0.value > $1.value }
            .map { (genre: $0.key, seconds: $0.value, percentage: categorizedTotal > 0 ? ($0.value / categorizedTotal) * 100.0 : 0) }

        let monthSymbols = Calendar.current.shortMonthSymbols
        let fullMonthSymbols = Calendar.current.monthSymbols
        let monthlyBreakdown: [(month: Int, label: String, seconds: Double)] = (1...12).map { m in
            let label = (m - 1) < monthSymbols.count ? monthSymbols[m - 1] : "\(m)"
            return (m, label, scopeStats.secondsByMonth[m] ?? 0)
        }
        let peakMonthEntry = monthlyBreakdown.max(by: { $0.seconds < $1.seconds })
        let peakMonth: (month: Int, name: String, seconds: Double)? = {
            guard let p = peakMonthEntry, p.seconds > 0 else { return nil }
            let full = (p.month - 1) < fullMonthSymbols.count ? fullMonthSymbols[p.month - 1] : p.label
            return (p.month, full, p.seconds)
        }()

        let peakHour = scopeStats.secondsByHour.max(by: { $0.value < $1.value })?.key
        let peakHourLabel: String = {
            guard let h = peakHour else { return "Anytime Listener" }
            switch h {
            case 5..<11: return "Early Morning (\(formattedHour(h)))"
            case 11..<17: return "Afternoon (\(formattedHour(h)))"
            case 17..<22: return "Evening Prime (\(formattedHour(h)))"
            default: return "Night Owl (\(formattedHour(h)))"
            }
        }()

        let streak = computeLongestStreak(from: scopeStats.activeDayStrings)
        let persona = computePersona(
            hero: namedArtists.first,
            uniqueNamedCount: namedArtists.count,
            genreCount: topGenres.count,
            peakHour: peakHour,
            streak: streak,
            totalMinutes: Int((totalSec / 60.0).rounded())
        )

        return WrappedSummaryReport(
            scopeLabel: scopeLabel,
            year: year,
            totalSeconds: totalSec,
            totalPlays: totalPlaysCount,
            namedArtists: namedArtists,
            allArtists: allRankings,
            topSongs: topSongs,
            topGenres: topGenres,
            monthlyBreakdown: monthlyBreakdown,
            peakMonth: peakMonth,
            peakHourLabel: peakHourLabel,
            activeDaysCount: scopeStats.activeDayStrings.count,
            longestStreakDays: streak,
            personaTitle: persona.title,
            personaSubtitle: persona.subtitle,
            personaSystemImage: persona.icon,
            strictConfirmedOnly: strictMode,
            excludedUnconfirmedSeconds: excludedUnconfirmedSecs
        )
    }

    static func formatHoursMinutes(_ seconds: Double) -> String {
        let totalMins = Int((seconds / 60.0).rounded())
        if totalMins >= 60 {
            let h = totalMins / 60
            let m = totalMins % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        if totalMins >= 1 {
            return "\(totalMins) min"
        }
        return "\(max(0, Int(seconds.rounded())))s"
    }

    // MARK: - Helpers & Persistence

    private func computePersona(
        hero: WrappedArtistRanking?,
        uniqueNamedCount: Int,
        genreCount: Int,
        peakHour: Int?,
        streak: Int,
        totalMinutes: Int
    ) -> (title: String, subtitle: String, icon: String) {
        if let hero, hero.sharePercentage >= 45, totalMinutes >= 5 {
            return (
                "The Devoted Superfan",
                "\(Int(hero.sharePercentage.rounded()))% of your listening belonged to \(hero.canonicalName).",
                "crown.fill"
            )
        }
        if let h = peakHour, (h >= 22 || h <= 4) {
            return (
                "The Midnight Curator",
                "Your soundtrack comes alive late at night.",
                "moon.stars.fill"
            )
        }
        if uniqueNamedCount >= 18 || genreCount >= 5 {
            return (
                "The Sonic Explorer",
                "You ventured across \(uniqueNamedCount) artists and \(max(1, genreCount)) genres.",
                "sparkles"
            )
        }
        if streak >= 5 {
            return (
                "The Daily Ritualist",
                "\(streak)-day listening streak — music is part of your routine.",
                "flame.fill"
            )
        }
        if hero != nil {
            return (
                "The Focused Listener",
                "Keep pressing play — your year-end story grows with every track.",
                "headphones"
            )
        }
        return (
            "Ready to Press Play",
            "Play your songs or videos offline to build your \(Calendar.current.component(.year, from: .now)) Wrapped.",
            "waveform"
        )
    }

    private func computeLongestStreak(from dayStrings: Set<String>) -> Int {
        guard !dayStrings.isEmpty else { return 0 }
        let dates = dayStrings.compactMap { Self.dayKeyFormatter.date(from: $0) }.sorted()
        guard !dates.isEmpty else { return 0 }
        let cal = Calendar.current
        var best = 1
        var current = 1
        for idx in 1..<dates.count {
            let diff = cal.dateComponents([.day], from: dates[idx - 1], to: dates[idx]).day ?? 0
            if diff == 1 {
                current += 1
                best = max(best, current)
            } else if diff > 1 {
                current = 1
            }
        }
        return best
    }

    private func formattedHour(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(h12) \(ampm)"
    }

    private func scheduleDiskSave(immediate: Bool) {
        pendingDiskSaveTask?.cancel()
        if immediate {
            writeToDisk()
            return
        }
        pendingDiskSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
        }
    }

    func flushDiskSave() {
        pendingDiskSaveTask?.cancel()
        pendingDiskSaveTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(db) else { return }
        try? data.write(to: storageFileURL, options: [.atomic])
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageFileURL),
              let decoded = try? JSONDecoder().decode(WrappedPersistedDatabase.self, from: data) else {
            return
        }
        db = decoded
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
