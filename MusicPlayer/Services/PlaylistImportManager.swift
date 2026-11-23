import BackgroundTasks
import Foundation
import Observation
import UIKit
import UserNotifications

enum PlaylistImportPreferredFormat: String, Codable, CaseIterable, Identifiable {
    case audioOnly
    case videoWithAudio

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .audioOnly: return "Audio (.m4a)"
        case .videoWithAudio: return "Video (.mp4)"
        }
    }

    var shortSubtitle: String {
        switch self {
        case .audioOnly: return "Best for huge music playlists & fast background downloads"
        case .videoWithAudio: return "Downloads & caches full video + audio tracks"
        }
    }
}

enum PlaylistImportTrackStatus: String, Codable {
    case pending
    case resolving
    case downloading
    case completed
    case skippedAlreadyCached
    case failed
    case cancelled
}

struct PlaylistImportTrackJob: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let index: Int
    let title: String
    let artist: String
    var youtubeVideoID: String?
    let durationText: String?
    var status: PlaylistImportTrackStatus
    var errorMessage: String?
    var resolvedViaBrowser: Bool
    var retryCount: Int
}

struct PlaylistImportJob: Identifiable, Codable, Sendable {
    let id: UUID
    let sourceURLString: String
    var playlistName: String
    var targetPlaylistID: UUID
    var preferredFormat: PlaylistImportPreferredFormat
    var alwaysUseBrowserResolver: Bool
    var respectMaxDurationLimit: Bool
    var isDiscoveringPages: Bool
    var discoveryError: String?
    var isPaused: Bool
    var isCancelled: Bool
    var createdAt: Date
    var updatedAt: Date
    var tracks: [PlaylistImportTrackJob]

    // Cached counters for O(1) UI updates on 5,000+ track queues
    var completedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0

    var totalCount: Int { tracks.count }
    var processedCount: Int { completedCount + skippedCount + failedCount }
    var remainingCount: Int { max(0, totalCount - processedCount) }
    var isFinished: Bool { !isDiscoveringPages && (isCancelled || remainingCount == 0) }
    var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1.0, max(0.0, Double(processedCount) / Double(totalCount)))
    }
}

private struct BackgroundDownloadTaskMetadata: Codable, Sendable {
    enum Stage: String, Codable {
        case singleDirect
        case audioExtractFromMP4
        case pairedAudio
        case pairedVideo
    }

    let jobID: UUID
    let trackID: UUID
    let videoID: String
    let title: String
    let artist: String
    let durationSeconds: Double?
    let fileExtension: String
    let stage: Stage
    let pairedAudioStagingFileName: String?
    let resolvedViaBrowser: Bool
}

@MainActor
@Observable
final class PlaylistImportManager {
    static let shared = PlaylistImportManager()

    static let backgroundSessionIdentifier = "com.personal.musicplayer.playlist.bg"
    static let backgroundTaskIdentifier = "com.personal.musicplayer.playlist.sync"

    var jobs: [PlaylistImportJob] = []
    var activeDownloadProgressByTrackID: [UUID: Double] = [:]
    var currentStatusMessage: String?

    var activeJobs: [PlaylistImportJob] {
        jobs.filter { !$0.isFinished }
    }

    var primaryActiveJob: PlaylistImportJob? {
        activeJobs.first(where: { !$0.isPaused }) ?? activeJobs.first
    }

    @ObservationIgnored private var backgroundSession: URLSession!
    @ObservationIgnored private var sessionDelegate: BackgroundSessionDelegateProxy!
    @ObservationIgnored private var backgroundEventsCompletionHandler: (() -> Void)?
    @ObservationIgnored private var activeDownloadTasksByTrackID: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var activeResolvingTrackIDs = Set<UUID>()
    @ObservationIgnored private var discoveryTasksByJobID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var bgExecutionTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var saveDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var importedSinceLastLibraryFlush = 0
    @ObservationIgnored private var cachedMediaByVideoID: [String: MediaItem] = [:]
    @ObservationIgnored private var didRegisterBGTask = false
    @ObservationIgnored private var pendingBGProcessingTask: BGProcessingTask?

    private static let maxConcurrentForegroundResolvers = 2
    private static let maxConcurrentDownloadsForeground = 3
    private static let maxConcurrentDownloadsBackground = 6

    private static var jobsFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlist_import_jobs.json")
    }

    nonisolated static var stagingDirectoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaylistImportStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let proxy = BackgroundSessionDelegateProxy(manager: self)
        self.sessionDelegate = proxy

        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4

        self.backgroundSession = URLSession(configuration: config, delegate: proxy, delegateQueue: nil)

        loadPersistedJobs()
        observeAppLifecycle()
        Task {
            await reconcileExistingBackgroundTasks()
        }
    }

    // MARK: - Background Session & BGTaskScheduler Wiring

    func registerBackgroundTasks() {
        guard !didRegisterBGTask else { return }
        didRegisterBGTask = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleBGProcessingTask(processingTask)
            }
        }
    }

    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        backgroundEventsCompletionHandler = completionHandler
        ensurePumping()
    }

    private func handleBGProcessingTask(_ task: BGProcessingTask) {
        pendingBGProcessingTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.persistJobsNow()
                MediaManager.shared.flushBatchPlaylistImport(playlistID: nil, summary: nil, reloadLibrary: false)
                self?.pendingBGProcessingTask?.setTaskCompleted(success: false)
                self?.pendingBGProcessingTask = nil
            }
        }
        resumeAllPausedOrInterruptedJobsIfNeeded(autoResumeOnlyNonPaused: true)
        ensurePumping()
    }

    private func scheduleNextBGProcessingTaskIfNeeded() {
        guard activeJobs.contains(where: { !$0.isPaused && !$0.isCancelled }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidEnterBackground()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillEnterForeground()
            }
        }
    }

    private func handleDidEnterBackground() {
        persistJobsNow()
        if let active = primaryActiveJob {
            MediaManager.shared.flushBatchPlaylistImport(
                playlistID: active.targetPlaylistID,
                summary: "Background sync checkpoint (\(active.completedCount + active.skippedCount) cached)",
                reloadLibrary: false
            )
        }
        guard activeJobs.contains(where: { !$0.isPaused && !$0.isCancelled }) else { return }

        scheduleNextBGProcessingTaskIfNeeded()
        if bgExecutionTaskID == .invalid {
            bgExecutionTaskID = UIApplication.shared.beginBackgroundTask(withName: "MuSeJRM.PlaylistBgQueue") { [weak self] in
                Task { @MainActor in
                    self?.persistJobsNow()
                    if let self, self.bgExecutionTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(self.bgExecutionTaskID)
                        self.bgExecutionTaskID = .invalid
                    }
                }
            }
        }
        ensurePumping()
    }

    private func handleWillEnterForeground() {
        if bgExecutionTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgExecutionTaskID)
            bgExecutionTaskID = .invalid
        }
        ensurePumping()
    }

    // MARK: - Enqueue APIs

    /// Starts or adopts a playlist import job immediately and continues discovery & downloading in background.
    @discardableResult
    func enqueueURLImport(
        sourceURLString: String,
        playlistName: String,
        targetPlaylistID: UUID,
        preferredFormat: PlaylistImportPreferredFormat,
        alwaysUseBrowserResolver: Bool,
        respectMaxDurationLimit: Bool,
        alreadyDiscoveredTracks: [ExternalPlaylistTrack] = [],
        initialInitialDataJSON: [String: Any]? = nil,
        listIDForInitialData: String? = nil,
        skipDiscoveryIfComplete: Bool = false
    ) -> UUID {
        refreshCachedVideoMap()

        let jobID = UUID()
        let job = PlaylistImportJob(
            id: jobID,
            sourceURLString: sourceURLString,
            playlistName: playlistName,
            targetPlaylistID: targetPlaylistID,
            preferredFormat: preferredFormat,
            alwaysUseBrowserResolver: alwaysUseBrowserResolver,
            respectMaxDurationLimit: respectMaxDurationLimit,
            isDiscoveringPages: !skipDiscoveryIfComplete,
            discoveryError: nil,
            isPaused: false,
            isCancelled: false,
            createdAt: .now,
            updatedAt: .now,
            tracks: []
        )
        jobs.insert(job, at: 0)

        if !alreadyDiscoveredTracks.isEmpty {
            appendTracks(alreadyDiscoveredTracks, toJobID: jobID)
        }

        if !skipDiscoveryIfComplete {
            let capturedInitialJSON = initialInitialDataJSON
            let capturedListID = listIDForInitialData
            discoveryTasksByJobID[jobID] = Task { [weak self] in
                await self?.runDiscoveryStream(
                    jobID: jobID,
                    urlString: sourceURLString,
                    initialJSON: capturedInitialJSON,
                    listID: capturedListID
                )
            }
        }

        scheduleDebouncedSave()
        ensurePumping()
        return jobID
    }

    /// Appends newly streamed tracks from an external discovery task (e.g. ImportPlaylistSheetView live stream).
    func appendDiscoveredTracks(_ tracks: [ExternalPlaylistTrack], toJobID jobID: UUID, isComplete: Bool) {
        appendTracks(tracks, toJobID: jobID)
        if isComplete, let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].isDiscoveringPages = false
            jobs[idx].updatedAt = .now
        }
        scheduleDebouncedSave()
        ensurePumping()
    }

    func markDiscoveryFailed(jobID: UUID, message: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[idx].isDiscoveringPages = false
        jobs[idx].discoveryError = message
        jobs[idx].updatedAt = .now
        scheduleDebouncedSave()
    }

    // MARK: - Job Controls

    func pauseJob(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].isPaused = true
        jobs[idx].updatedAt = .now
        for track in jobs[idx].tracks {
            if let task = activeDownloadTasksByTrackID.removeValue(forKey: track.id) {
                task.cancel()
            }
            activeResolvingTrackIDs.remove(track.id)
            activeDownloadProgressByTrackID.removeValue(forKey: track.id)
        }
        for i in jobs[idx].tracks.indices {
            if jobs[idx].tracks[i].status == .resolving || jobs[idx].tracks[i].status == .downloading {
                jobs[idx].tracks[i].status = .pending
            }
        }
        MediaManager.shared.flushBatchPlaylistImport(
            playlistID: jobs[idx].targetPlaylistID,
            summary: "Paused \"\(jobs[idx].playlistName)\" (\(jobs[idx].completedCount + jobs[idx].skippedCount) saved)",
            reloadLibrary: true
        )
        persistJobsNow()
    }

    func resumeJob(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }), !jobs[idx].isCancelled else { return }
        jobs[idx].isPaused = false
        jobs[idx].updatedAt = .now
        refreshCachedVideoMap()
        persistJobsNow()
        ensurePumping()
    }

    func retryFailedTracks(inJobID id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var resetCount = 0
        for tIdx in jobs[idx].tracks.indices where jobs[idx].tracks[tIdx].status == .failed {
            jobs[idx].tracks[tIdx].status = .pending
            jobs[idx].tracks[tIdx].errorMessage = nil
            jobs[idx].tracks[tIdx].retryCount = 0
            resetCount += 1
        }
        if resetCount > 0 {
            jobs[idx].failedCount = max(0, jobs[idx].failedCount - resetCount)
            jobs[idx].isPaused = false
            jobs[idx].isCancelled = false
            jobs[idx].updatedAt = .now
            persistJobsNow()
            ensurePumping()
        }
    }

    func cancelJob(id: UUID) {
        discoveryTasksByJobID.removeValue(forKey: id)?.cancel()
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].isCancelled = true
        jobs[idx].isDiscoveringPages = false
        jobs[idx].isPaused = false
        jobs[idx].updatedAt = .now

        for i in jobs[idx].tracks.indices {
            let tid = jobs[idx].tracks[i].id
            if let task = activeDownloadTasksByTrackID.removeValue(forKey: tid) {
                task.cancel()
            }
            activeResolvingTrackIDs.remove(tid)
            activeDownloadProgressByTrackID.removeValue(forKey: tid)
            let st = jobs[idx].tracks[i].status
            if st == .pending || st == .resolving || st == .downloading {
                jobs[idx].tracks[i].status = .cancelled
            }
        }
        MediaManager.shared.flushBatchPlaylistImport(
            playlistID: jobs[idx].targetPlaylistID,
            summary: "Stopped import \"\(jobs[idx].playlistName)\"",
            reloadLibrary: true
        )
        BrowserYouTubeResolver.shared.releaseIdleWebView()
        persistJobsNow()
    }

    func clearFinishedJob(id: UUID) {
        jobs.removeAll { $0.id == id && $0.isFinished }
        persistJobsNow()
    }

    // MARK: - Discovery Inside Manager

    private func runDiscoveryStream(
        jobID: UUID,
        urlString: String,
        initialJSON: [String: Any]?,
        listID: String?
    ) async {
        do {
            let cookies = await BrowserYouTubeResolver.youtubeCookieHeader()

            if let initialJSON, let listID, !listID.isEmpty {
                _ = try await PlaylistURLImporter.continueYouTubePlaylist(
                    fromInitialJSON: initialJSON,
                    listID: listID,
                    cookiesHeader: cookies
                ) { page in
                    await MainActor.run {
                        self.handleDiscoveryPage(jobID: jobID, page: page)
                    }
                }
            } else {
                do {
                    _ = try await PlaylistURLImporter.streamPlaylist(from: urlString, cookiesHeader: cookies) { page in
                        await MainActor.run {
                            self.handleDiscoveryPage(jobID: jobID, page: page)
                        }
                    }
                } catch {
                    // Fallback: extract playlist inside built-in WKWebView browser (handles signed-in/private Watch Later/Liked lists)
                    if let url = URL(string: urlString),
                       let parsed = PlaylistURLImporter.parsePlaylistURL(urlString),
                       parsed.platform == .youtubeMusic,
                       let browserLoaded = await BrowserYouTubeResolver.shared.extractPlaylistInitialDataInBrowser(url: url) {
                        _ = try await PlaylistURLImporter.continueYouTubePlaylist(
                            fromInitialJSON: browserLoaded.json,
                            listID: parsed.playlistID,
                            cookiesHeader: browserLoaded.cookiesHeader ?? cookies
                        ) { page in
                            await MainActor.run {
                                self.handleDiscoveryPage(jobID: jobID, page: page)
                            }
                        }
                    } else {
                        throw error
                    }
                }
            }

            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].isDiscoveringPages = false
                jobs[idx].updatedAt = .now
                scheduleDebouncedSave()
                ensurePumping()
            }
        } catch is CancellationError {
            // Ignored
        } catch {
            markDiscoveryFailed(jobID: jobID, message: error.localizedDescription)
        }
        discoveryTasksByJobID.removeValue(forKey: jobID)
    }

    private func handleDiscoveryPage(
        jobID: UUID,
        page: PlaylistURLImporter.PlaylistStreamPage
    ) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }), !jobs[idx].isCancelled else { return }
        if jobs[idx].playlistName.isEmpty || jobs[idx].playlistName == "YouTube Playlist" {
            jobs[idx].playlistName = page.playlistTitle
        }
        if !page.newTracks.isEmpty {
            appendTracks(page.newTracks, toJobID: jobID)
        }
        if page.isComplete {
            jobs[idx].isDiscoveringPages = false
        }
        jobs[idx].updatedAt = .now
        scheduleDebouncedSave()
        ensurePumping()
    }

    private func appendTracks(_ newTracks: [ExternalPlaylistTrack], toJobID jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }), !jobs[idx].isCancelled else { return }

        var existingVideoIDs = Set(jobs[idx].tracks.compactMap(\.youtubeVideoID))
        var existingCacheItemsToAdd: [MediaItem] = []
        var itemsToAppend: [PlaylistImportTrackJob] = []
        let baseIndex = jobs[idx].tracks.count

        for (offset, track) in newTracks.enumerated() {
            let cleanVID = track.youtubeVideoID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanVID, !cleanVID.isEmpty {
                guard existingVideoIDs.insert(cleanVID).inserted else { continue }
                if let cached = cachedMediaByVideoID[cleanVID] {
                    existingCacheItemsToAdd.append(cached)
                    itemsToAppend.append(
                        PlaylistImportTrackJob(
                            id: UUID(),
                            index: baseIndex + offset,
                            title: track.title,
                            artist: track.artist,
                            youtubeVideoID: cleanVID,
                            durationText: track.durationText,
                            status: .skippedAlreadyCached,
                            errorMessage: nil,
                            resolvedViaBrowser: false,
                            retryCount: 0
                        )
                    )
                    jobs[idx].skippedCount += 1
                    continue
                }
            }

            itemsToAppend.append(
                PlaylistImportTrackJob(
                    id: UUID(),
                    index: baseIndex + offset,
                    title: track.title,
                    artist: track.artist,
                    youtubeVideoID: cleanVID,
                    durationText: track.durationText,
                    status: .pending,
                    errorMessage: nil,
                    resolvedViaBrowser: false,
                    retryCount: 0
                )
            )
        }

        if !existingCacheItemsToAdd.isEmpty {
            MediaManager.shared.addExistingItemsToPlaylistFast(
                existingCacheItemsToAdd,
                playlistID: jobs[idx].targetPlaylistID,
                flushState: false
            )
        }
        if !itemsToAppend.isEmpty {
            jobs[idx].tracks.append(contentsOf: itemsToAppend)
        }
    }

    // MARK: - Worker Scheduler & Execution Loop

    private func ensurePumping() {
        guard pumpTask == nil else { return }
        guard activeJobs.contains(where: { !$0.isPaused && !$0.isCancelled }) else { return }
        pumpTask = Task { [weak self] in
            await self?.runPumpLoop()
        }
    }

    private func runPumpLoop() async {
        defer { pumpTask = nil }

        while true {
            guard let nextPair = nextResolvableTrack() else {
                // Check if all jobs finished downloading too
                finalizeCompletedJobsIfNeeded()
                if activeDownloadTasksByTrackID.isEmpty && activeResolvingTrackIDs.isEmpty {
                    BrowserYouTubeResolver.shared.releaseIdleWebView()
                    if let bgTask = pendingBGProcessingTask {
                        bgTask.setTaskCompleted(success: true)
                        pendingBGProcessingTask = nil
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
                continue
            }

            let isBackground = UIApplication.shared.applicationState == .background
            let maxDownloads = isBackground ? Self.maxConcurrentDownloadsBackground : Self.maxConcurrentDownloadsForeground
            let totalInFlight = activeResolvingTrackIDs.count + activeDownloadTasksByTrackID.count
            if totalInFlight >= maxDownloads || activeResolvingTrackIDs.count >= Self.maxConcurrentForegroundResolvers {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }

            let (jobID, trackID) = nextPair
            setTrackStatus(jobID: jobID, trackID: trackID, status: .resolving)
            activeResolvingTrackIDs.insert(trackID)

            Task { [weak self] in
                await self?.resolveAndScheduleTrack(jobID: jobID, trackID: trackID)
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func nextResolvableTrack() -> (jobID: UUID, trackID: UUID)? {
        for job in jobs where !job.isPaused && !job.isCancelled {
            if let track = job.tracks.first(where: { $0.status == .pending }) {
                return (job.id, track.id)
            }
        }
        return nil
    }

    private func resolveAndScheduleTrack(jobID: UUID, trackID: UUID) async {
        defer { activeResolvingTrackIDs.remove(trackID) }

        guard let (job, track) = lookup(jobID: jobID, trackID: trackID),
              !job.isPaused, !job.isCancelled else {
            return
        }

        currentStatusMessage = "Finding \"\(track.title)\"..."

        // Step 1: Ensure YouTube Video ID
        var videoID = track.youtubeVideoID
        var usedBrowser = false

        if videoID == nil || videoID?.isEmpty == true {
            if !job.alwaysUseBrowserResolver {
                videoID = await PlaylistURLImporter.findBestYouTubeVideoID(title: track.title, artist: track.artist)
            }
            if videoID == nil || videoID?.isEmpty == true {
                usedBrowser = true
                videoID = await BrowserYouTubeResolver.shared.findVideoIDInBrowser(title: track.title, artist: track.artist)
            }
            if let foundID = videoID, !foundID.isEmpty {
                updateTrackVideoID(jobID: jobID, trackID: trackID, videoID: foundID)
            }
        }

        guard let resolvedVideoID = videoID, !resolvedVideoID.isEmpty else {
            markTrackFailed(jobID: jobID, trackID: trackID, error: "Video not found on YouTube", retryable: true)
            return
        }

        // Step 2: Re-check offline cache deduplication after finding video ID
        if let cached = cachedMediaByVideoID[resolvedVideoID] ?? MediaManager.shared.existingMediaItem(forVideoID: resolvedVideoID) {
            cachedMediaByVideoID[resolvedVideoID] = cached
            MediaManager.shared.addExistingItemToPlaylistFast(cached, playlistID: job.targetPlaylistID, flushState: false)
            markTrackSkippedAlreadyCached(jobID: jobID, trackID: trackID)
            return
        }

        // Check cancellation/pause before resolution
        guard let freshJob = jobs.first(where: { $0.id == jobID }), !freshJob.isPaused, !freshJob.isCancelled else {
            setTrackStatus(jobID: jobID, trackID: trackID, status: .pending)
            return
        }

        // Step 3: Resolve streams (fast InnerTube with browser cookies -> Built-in Browser WKWebView fallback)
        var resolvedResult: YouTubeResolvedResult?
        var cookiesHeader = await BrowserYouTubeResolver.youtubeCookieHeader()

        if !job.alwaysUseBrowserResolver,
           track.retryCount == 0,
           let watchURL = URL(string: "https://www.youtube.com/watch?v=\(resolvedVideoID)") {
            resolvedResult = await YouTubeStreamResolver.resolveStreams(
                for: watchURL,
                cookiesHeader: cookiesHeader,
                referer: watchURL.absoluteString,
                visitorData: nil
            )
        }

        if resolvedResult == nil || (resolvedResult?.streams.isEmpty ?? true) {
            usedBrowser = true
            if let browserResolved = await BrowserYouTubeResolver.shared.resolveStreamsInBrowser(videoID: resolvedVideoID) {
                resolvedResult = browserResolved.result
                cookiesHeader = browserResolved.cookiesHeader ?? cookiesHeader
            }
        }

        guard let resolvedResult, !resolvedResult.streams.isEmpty else {
            markTrackFailed(
                jobID: jobID,
                trackID: trackID,
                error: resolvedResult?.errorReason ?? "Could not find playable stream in browser",
                retryable: track.retryCount == 0
            )
            return
        }

        // Respect optional duration guard only when user kept it enabled
        if job.respectMaxDurationLimit {
            let maxMins = UserDefaults.standard.integer(forKey: "musicplayer.maxDuration")
            if maxMins > 0, let dur = resolvedResult.durationSeconds, dur > Double(maxMins) * 60 {
                markTrackFailed(jobID: jobID, trackID: trackID, error: "Exceeds max cache duration (\(maxMins)m)", retryable: false)
                return
            }
        }

        // Step 4: Select best stream & enqueue into background URLSession
        guard let picked = selectBestStream(from: resolvedResult.streams, format: job.preferredFormat) else {
            // HLS-only fallback via foreground WebMediaDownloader if available
            if let hlsStream = resolvedResult.streams.first(where: { $0.isHLS }) {
                setTrackStatus(jobID: jobID, trackID: trackID, status: .downloading)
                if let downloaded = await WebMediaDownloader.shared.downloadTrackIntoPlaylist(
                    hlsStream,
                    targetPlaylistID: job.targetPlaylistID,
                    maxDurationMinutes: 0,
                    sourceVideoID: resolvedVideoID
                ) {
                    cachedMediaByVideoID[resolvedVideoID] = downloaded
                    markTrackCompleted(jobID: jobID, trackID: trackID, viaBrowser: usedBrowser)
                    return
                }
            }
            markTrackFailed(jobID: jobID, trackID: trackID, error: "No downloadable stream available", retryable: track.retryCount == 0)
            return
        }

        enqueueBackgroundDownload(
            jobID: jobID,
            track: track,
            videoID: resolvedVideoID,
            resolvedTitle: track.title.isEmpty ? resolvedResult.title : track.title,
            resolvedArtist: track.artist.isEmpty ? (resolvedResult.author ?? "") : track.artist,
            durationSeconds: resolvedResult.durationSeconds,
            primaryURL: picked.primaryURL,
            pairedAudioURL: picked.pairedAudioURL,
            headers: mergeHeaders(picked.headers, cookiesHeader: cookiesHeader),
            stage: picked.stage,
            fileExtension: picked.fileExtension,
            usedBrowser: usedBrowser
        )
    }

    private func selectBestStream(
        from streams: [DetectedBrowserMedia],
        format: PlaylistImportPreferredFormat
    ) -> (primaryURL: URL, pairedAudioURL: URL?, headers: [String: String]?, stage: BackgroundDownloadTaskMetadata.Stage, fileExtension: String)? {
        switch format {
        case .audioOnly:
            if let audio = streams.first(where: { $0.isAudio && !$0.isHLS && $0.pairedAudioURL == nil }) {
                let ext = validExtension(for: audio.url, fallback: "m4a")
                return (audio.url, nil, audio.customHeaders, .singleDirect, ext)
            }
            if let mp4 = streams.first(where: { !$0.isHLS && $0.pairedAudioURL == nil }) {
                return (mp4.url, nil, mp4.customHeaders, .audioExtractFromMP4, "mp4")
            }
            return nil

        case .videoWithAudio:
            // Prefer progressive MP4 first when available for single-task native background efficiency,
            // or paired HD video+audio for full 720p/1080p quality.
            if let hdProg = streams.first(where: { !$0.isHLS && !$0.isAudio && $0.pairedAudioURL == nil && ($0.qualityLabel?.contains("720") == true || $0.qualityLabel?.contains("1080") == true) }) {
                return (hdProg.url, nil, hdProg.customHeaders, .singleDirect, "mp4")
            }
            if let adaptiveHD = streams.first(where: { !$0.isHLS && $0.pairedAudioURL != nil }) {
                return (adaptiveHD.url, adaptiveHD.pairedAudioURL, adaptiveHD.customHeaders, .pairedAudio, "m4a")
            }
            if let prog = streams.first(where: { !$0.isHLS && !$0.isAudio && $0.pairedAudioURL == nil }) {
                return (prog.url, nil, prog.customHeaders, .singleDirect, "mp4")
            }
            if let audio = streams.first(where: { $0.isAudio && !$0.isHLS }) {
                let ext = validExtension(for: audio.url, fallback: "m4a")
                return (audio.url, nil, audio.customHeaders, .singleDirect, ext)
            }
            return nil
        }
    }

    private func enqueueBackgroundDownload(
        jobID: UUID,
        track: PlaylistImportTrackJob,
        videoID: String,
        resolvedTitle: String,
        resolvedArtist: String,
        durationSeconds: Double?,
        primaryURL: URL,
        pairedAudioURL: URL?,
        headers: [String: String],
        stage: BackgroundDownloadTaskMetadata.Stage,
        fileExtension: String,
        usedBrowser: Bool,
        existingPairedAudioStagingName: String? = nil
    ) {
        // For pairedAudio stage, start by downloading the audio stream first;
        // once done, didFinishDownloadingTo enqueues pairedVideo referencing the staged audio file!
        let targetDownloadURL = (stage == .pairedAudio ? (pairedAudioURL ?? primaryURL) : primaryURL)
        let meta = BackgroundDownloadTaskMetadata(
            jobID: jobID,
            trackID: track.id,
            videoID: videoID,
            title: resolvedTitle,
            artist: resolvedArtist,
            durationSeconds: durationSeconds,
            fileExtension: stage == .pairedAudio ? "m4a" : fileExtension,
            stage: stage,
            pairedAudioStagingFileName: stage == .pairedAudio
                ? primaryURL.absoluteString // temporarily store paired video URL only if needed; better stored in separate task
                : existingPairedAudioStagingName,
            resolvedViaBrowser: usedBrowser
        )
        // Store paired video URL safely when stage == .pairedAudio so background wakeup can enqueue video!
        if stage == .pairedAudio {
            savePairedVideoURL(primaryURL, headers: headers, forTrackID: track.id)
        }

        var request = URLRequest(url: targetDownloadURL)
        request.timeoutInterval = 120
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        guard let metaData = try? JSONEncoder().encode(meta),
              let metaString = String(data: metaData, encoding: .utf8) else {
            markTrackFailed(jobID: jobID, trackID: track.id, error: "Could not serialize task", retryable: false)
            return
        }

        setTrackStatus(jobID: jobID, trackID: track.id, status: .downloading)
        activeDownloadProgressByTrackID[track.id] = 0

        let task = backgroundSession.downloadTask(with: request)
        task.taskDescription = metaString
        activeDownloadTasksByTrackID[track.id] = task
        task.resume()
    }

    // MARK: - Background Delegate Callbacks

    private func handleBackgroundDownloadFinished(
        stagedFileURL: URL,
        metadata: BackgroundDownloadTaskMetadata,
        httpStatusCode: Int?
    ) async {
        activeDownloadTasksByTrackID.removeValue(forKey: metadata.trackID)
        activeDownloadProgressByTrackID.removeValue(forKey: metadata.trackID)

        let fileSize = (try? stagedFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let hasBadHTTPStatus = httpStatusCode.map { !(200...299).contains($0) } ?? false
        if hasBadHTTPStatus || fileSize < 2048 {
            try? FileManager.default.removeItem(at: stagedFileURL)
            removePairedVideoURL(forTrackID: metadata.trackID)
            let reason = httpStatusCode.map { "Stream returned HTTP \($0)" } ?? "Downloaded stream was empty (\(fileSize) bytes)"
            handleDownloadFailureOrRetry(metadata: metadata, message: reason)
            return
        }

        guard let job = jobs.first(where: { $0.id == metadata.jobID }), !job.isCancelled else {
            try? FileManager.default.removeItem(at: stagedFileURL)
            removePairedVideoURL(forTrackID: metadata.trackID)
            return
        }

        switch metadata.stage {
        case .pairedAudio:
            if let paired = loadPairedVideoURL(forTrackID: metadata.trackID),
               let track = job.tracks.first(where: { $0.id == metadata.trackID }) {
                removePairedVideoURL(forTrackID: metadata.trackID)
                enqueueBackgroundDownload(
                    jobID: metadata.jobID,
                    track: track,
                    videoID: metadata.videoID,
                    resolvedTitle: metadata.title,
                    resolvedArtist: metadata.artist,
                    durationSeconds: metadata.durationSeconds,
                    primaryURL: paired.url,
                    pairedAudioURL: nil,
                    headers: paired.headers,
                    stage: .pairedVideo,
                    fileExtension: "mp4",
                    usedBrowser: metadata.resolvedViaBrowser,
                    existingPairedAudioStagingName: stagedFileURL.lastPathComponent
                )
            } else {
                try? FileManager.default.removeItem(at: stagedFileURL)
                markTrackFailed(jobID: metadata.jobID, trackID: metadata.trackID, error: "Paired video missing", retryable: true)
            }

        case .pairedVideo:
            let finalURL = Self.stagingDirectoryURL.appendingPathComponent("\(UUID().uuidString)_mux.mp4")
            let audioName = metadata.pairedAudioStagingFileName ?? ""
            let audioURL = Self.stagingDirectoryURL.appendingPathComponent(audioName)

            let muxSuccess: Bool
            if !audioName.isEmpty, FileManager.default.fileExists(atPath: audioURL.path) {
                muxSuccess = await Task.detached(priority: .utility) {
                    FFmpegMediaService.muxVideoAndAudioToMP4(videoURL: stagedFileURL, audioURL: audioURL, outputURL: finalURL)
                }.value
                try? FileManager.default.removeItem(at: audioURL)
            } else {
                muxSuccess = false
            }

            let importSource = muxSuccess ? finalURL : stagedFileURL
            if muxSuccess {
                try? FileManager.default.removeItem(at: stagedFileURL)
            }
            importStagedMediaAndAdvance(importSource, ext: "mp4", metadata: metadata)

        case .audioExtractFromMP4:
            let m4aURL = Self.stagingDirectoryURL.appendingPathComponent("\(UUID().uuidString)_audio.m4a")
            let remuxed = await Task.detached(priority: .utility) {
                FFmpegMediaService.remuxAudioTrackToM4A(inputURL: stagedFileURL, outputURL: m4aURL)
            }.value
            if remuxed {
                try? FileManager.default.removeItem(at: stagedFileURL)
                importStagedMediaAndAdvance(m4aURL, ext: "m4a", metadata: metadata)
            } else {
                try? FileManager.default.removeItem(at: m4aURL)
                importStagedMediaAndAdvance(stagedFileURL, ext: "mp4", metadata: metadata)
            }

        case .singleDirect:
            importStagedMediaAndAdvance(stagedFileURL, ext: metadata.fileExtension, metadata: metadata)
        }
    }

    private func importStagedMediaAndAdvance(
        _ fileURL: URL,
        ext: String,
        metadata: BackgroundDownloadTaskMetadata
    ) {
        let baseTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = (baseTitle.isEmpty ? metadata.videoID : baseTitle) + ".\(ext)"

        let imported = MediaManager.shared.fastImportDownloadedFile(
            from: fileURL,
            preferredFileName: preferredName,
            title: metadata.title,
            artist: metadata.artist.isEmpty ? nil : metadata.artist,
            durationSeconds: metadata.durationSeconds,
            sourceVideoID: metadata.videoID,
            playlistID: jobs.first(where: { $0.id == metadata.jobID })?.targetPlaylistID,
            flushState: false
        )

        if let imported {
            cachedMediaByVideoID[metadata.videoID] = imported
            markTrackCompleted(jobID: metadata.jobID, trackID: metadata.trackID, viaBrowser: metadata.resolvedViaBrowser)
            importedSinceLastLibraryFlush += 1
            if importedSinceLastLibraryFlush >= 10 {
                importedSinceLastLibraryFlush = 0
                MediaManager.shared.flushBatchPlaylistImport(
                    playlistID: jobs.first(where: { $0.id == metadata.jobID })?.targetPlaylistID,
                    summary: nil,
                    reloadLibrary: false
                )
            }
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            markTrackFailed(jobID: metadata.jobID, trackID: metadata.trackID, error: "Could not save file to library", retryable: false)
        }

        finalizeCompletedJobsIfNeeded()
        ensurePumping()
    }

    private func handleBackgroundTaskError(
        metadata: BackgroundDownloadTaskMetadata,
        error: Error
    ) {
        activeDownloadTasksByTrackID.removeValue(forKey: metadata.trackID)
        activeDownloadProgressByTrackID.removeValue(forKey: metadata.trackID)

        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        handleDownloadFailureOrRetry(metadata: metadata, message: error.localizedDescription)
    }

    private func handleDownloadFailureOrRetry(metadata: BackgroundDownloadTaskMetadata, message: String) {
        if let audioName = metadata.pairedAudioStagingFileName,
           metadata.stage == .pairedVideo {
            try? FileManager.default.removeItem(at: Self.stagingDirectoryURL.appendingPathComponent(audioName))
        }
        if let pair = lookup(jobID: metadata.jobID, trackID: metadata.trackID),
           pair.track.retryCount < 1,
           !pair.job.isPaused, !pair.job.isCancelled {
            incrementRetryAndRequeue(jobID: metadata.jobID, trackID: metadata.trackID)
            ensurePumping()
        } else {
            markTrackFailed(jobID: metadata.jobID, trackID: metadata.trackID, error: message, retryable: false)
            finalizeCompletedJobsIfNeeded()
            ensurePumping()
        }
    }

    private func handleBackgroundSessionFinishedAllEvents() {
        MediaManager.shared.flushBatchPlaylistImport(playlistID: nil, summary: nil, reloadLibrary: false)
        persistJobsNow()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        handler?()
    }

    // MARK: - Reconcile & Persistence

    private func reconcileExistingBackgroundTasks() async {
        let tasks = await backgroundSession.allTasks
        var activeIDs = Set<UUID>()
        for case let dlTask as URLSessionDownloadTask in tasks {
            guard let desc = dlTask.taskDescription,
                  let data = desc.data(using: .utf8),
                  let meta = try? JSONDecoder().decode(BackgroundDownloadTaskMetadata.self, from: data) else {
                dlTask.cancel()
                continue
            }
            if dlTask.state == .running || dlTask.state == .suspended {
                activeDownloadTasksByTrackID[meta.trackID] = dlTask
                activeIDs.insert(meta.trackID)
            }
        }

        var changed = false
        for jIdx in jobs.indices {
            if jobs[jIdx].isDiscoveringPages && discoveryTasksByJobID[jobs[jIdx].id] == nil && !jobs[jIdx].isCancelled {
                // Resume interrupted discovery seamlessly from the URL
                jobs[jIdx].isPaused = true
                jobs[jIdx].isDiscoveringPages = false
                changed = true
            }
            for tIdx in jobs[jIdx].tracks.indices {
                let track = jobs[jIdx].tracks[tIdx]
                if track.status == .resolving || (track.status == .downloading && !activeIDs.contains(track.id)) {
                    jobs[jIdx].tracks[tIdx].status = .pending
                    changed = true
                }
            }
        }
        if changed {
            scheduleDebouncedSave()
        }
        if !activeJobs.isEmpty {
            ensurePumping()
        }
    }

    func resumeAllPausedOrInterruptedJobsIfNeeded(autoResumeOnlyNonPaused: Bool = false) {
        refreshCachedVideoMap()
        for jIdx in jobs.indices where !jobs[jIdx].isFinished && !jobs[jIdx].isCancelled {
            if autoResumeOnlyNonPaused && jobs[jIdx].isPaused { continue }
            jobs[jIdx].isPaused = false
        }
        ensurePumping()
    }

    private func refreshCachedVideoMap() {
        cachedMediaByVideoID = MediaManager.shared.existingMediaMapByVideoID()
    }

    private func finalizeCompletedJobsIfNeeded() {
        for jIdx in jobs.indices {
            let job = jobs[jIdx]
            if job.isFinished && !job.isCancelled && importedSinceLastLibraryFlush > 0 {
                importedSinceLastLibraryFlush = 0
                MediaManager.shared.flushBatchPlaylistImport(
                    playlistID: job.targetPlaylistID,
                    summary: "Imported \"\(job.playlistName)\" (\(job.completedCount + job.skippedCount) tracks)",
                    reloadLibrary: true
                )
                postCompletionNotificationIfBackgrounded(for: job)
            } else if job.isFinished && !job.isCancelled && job.processedCount > 0 && currentStatusMessage != nil {
                MediaManager.shared.flushBatchPlaylistImport(
                    playlistID: job.targetPlaylistID,
                    summary: "Imported \"\(job.playlistName)\" (\(job.completedCount + job.skippedCount) tracks)",
                    reloadLibrary: true
                )
                currentStatusMessage = nil
                postCompletionNotificationIfBackgrounded(for: job)
            }
        }
    }

    private func postCompletionNotificationIfBackgrounded(for job: PlaylistImportJob) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Playlist Import Complete"
        content.body = "\(job.playlistName): \(job.completedCount + job.skippedCount) cached offline."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "playlist-done-\(job.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Paired Stream Sidecar Helper (Safe Across Background Relaunch)

    private struct PairedVideoRef: Codable {
        let url: URL
        let headers: [String: String]
    }

    private func pairedRefURL(forTrackID id: UUID) -> URL {
        Self.stagingDirectoryURL.appendingPathComponent("paired_\(id.uuidString).json")
    }

    private func savePairedVideoURL(_ url: URL, headers: [String: String], forTrackID id: UUID) {
        if let data = try? JSONEncoder().encode(PairedVideoRef(url: url, headers: headers)) {
            try? data.write(to: pairedRefURL(forTrackID: id), options: [.atomic])
        }
    }

    private func loadPairedVideoURL(forTrackID id: UUID) -> PairedVideoRef? {
        guard let data = try? Data(contentsOf: pairedRefURL(forTrackID: id)) else { return nil }
        return try? JSONDecoder().decode(PairedVideoRef.self, from: data)
    }

    private func removePairedVideoURL(forTrackID id: UUID) {
        try? FileManager.default.removeItem(at: pairedRefURL(forTrackID: id))
    }

    // MARK: - Job State Mutations & Persistence

    private func lookup(jobID: UUID, trackID: UUID) -> (job: PlaylistImportJob, track: PlaylistImportTrackJob)? {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let track = job.tracks.first(where: { $0.id == trackID }) else {
            return nil
        }
        return (job, track)
    }

    private func updateTrackVideoID(jobID: UUID, trackID: UUID, videoID: String) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        jobs[jIdx].tracks[tIdx].youtubeVideoID = videoID
    }

    private func setTrackStatus(jobID: UUID, trackID: UUID, status: PlaylistImportTrackStatus) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        jobs[jIdx].tracks[tIdx].status = status
        jobs[jIdx].updatedAt = .now
    }

    private func incrementRetryAndRequeue(jobID: UUID, trackID: UUID) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        jobs[jIdx].tracks[tIdx].retryCount += 1
        jobs[jIdx].tracks[tIdx].status = .pending
        jobs[jIdx].tracks[tIdx].errorMessage = nil
        jobs[jIdx].updatedAt = .now
        scheduleDebouncedSave()
    }

    private func markTrackCompleted(jobID: UUID, trackID: UUID, viaBrowser: Bool) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let prev = jobs[jIdx].tracks[tIdx].status
        guard prev != .completed else { return }
        if prev == .failed { jobs[jIdx].failedCount = max(0, jobs[jIdx].failedCount - 1) }
        jobs[jIdx].tracks[tIdx].status = .completed
        jobs[jIdx].tracks[tIdx].errorMessage = nil
        jobs[jIdx].tracks[tIdx].resolvedViaBrowser = viaBrowser
        jobs[jIdx].completedCount += 1
        jobs[jIdx].updatedAt = .now
        scheduleDebouncedSave()
    }

    private func markTrackSkippedAlreadyCached(jobID: UUID, trackID: UUID) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let prev = jobs[jIdx].tracks[tIdx].status
        guard prev != .skippedAlreadyCached else { return }
        jobs[jIdx].tracks[tIdx].status = .skippedAlreadyCached
        jobs[jIdx].skippedCount += 1
        jobs[jIdx].updatedAt = .now
        scheduleDebouncedSave()
    }

    private func markTrackFailed(jobID: UUID, trackID: UUID, error: String, retryable: Bool) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if retryable && jobs[jIdx].tracks[tIdx].retryCount < 1 && !jobs[jIdx].isPaused && !jobs[jIdx].isCancelled {
            jobs[jIdx].tracks[tIdx].retryCount += 1
            jobs[jIdx].tracks[tIdx].status = .pending
            scheduleDebouncedSave()
            return
        }
        let prev = jobs[jIdx].tracks[tIdx].status
        if prev != .failed {
            jobs[jIdx].failedCount += 1
        }
        jobs[jIdx].tracks[tIdx].status = .failed
        jobs[jIdx].tracks[tIdx].errorMessage = error
        jobs[jIdx].updatedAt = .now
        scheduleDebouncedSave()
    }

    private func loadPersistedJobs() {
        guard let data = try? Data(contentsOf: Self.jobsFileURL),
              let decoded = try? JSONDecoder().decode([PlaylistImportJob].self, from: data) else {
            return
        }
        self.jobs = decoded
    }

    private func scheduleDebouncedSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistJobsNow()
        }
    }

    private func persistJobsNow() {
        saveDebounceTask?.cancel()
        let snapshot = jobs.prefix(20).map { $0 }
        let targetURL = Self.jobsFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetURL, options: [.atomic])
            }
        }
    }

    private func validExtension(for url: URL, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && ext.count <= 5 { return ext }
        return fallback
    }

    private func mergeHeaders(_ base: [String: String]?, cookiesHeader: String?) -> [String: String] {
        var headers = base ?? [:]
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = WebMediaDownloader.browserUserAgent
        }
        if let cookiesHeader, !cookiesHeader.isEmpty, headers["Cookie"] == nil {
            headers["Cookie"] = cookiesHeader
        }
        return headers
    }

    // MARK: - Background URLSession Delegate Proxy

    private final class BackgroundSessionDelegateProxy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var manager: PlaylistImportManager?

        init(manager: PlaylistImportManager) {
            self.manager = manager
        }

        private func decodeMetadata(from task: URLSessionTask) -> BackgroundDownloadTaskMetadata? {
            guard let desc = task.taskDescription,
                  let data = desc.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(BackgroundDownloadTaskMetadata.self, from: data)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0,
                  let meta = decodeMetadata(from: downloadTask) else { return }
            let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            Task { @MainActor [weak self] in
                self?.manager?.activeDownloadProgressByTrackID[meta.trackID] = fraction
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard let meta = decodeMetadata(from: downloadTask) else {
                try? FileManager.default.removeItem(at: location)
                return
            }

            // CRITICAL on iOS: move file synchronously out of OS tmp before this method returns.
            let stagedURL = PlaylistImportManager.stagingDirectoryURL
                .appendingPathComponent("\(UUID().uuidString)_\(meta.trackID.uuidString).\(meta.fileExtension)")
            do {
                try FileManager.default.createDirectory(
                    at: PlaylistImportManager.stagingDirectoryURL,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try? FileManager.default.removeItem(at: stagedURL)
                }
                try FileManager.default.moveItem(at: location, to: stagedURL)
            } catch {
                Task { @MainActor [weak self] in
                    self?.manager?.handleDownloadFailureOrRetry(
                        metadata: meta,
                        message: "Staging error: \(error.localizedDescription)"
                    )
                }
                return
            }

            let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor [weak self] in
                await self?.manager?.handleBackgroundDownloadFinished(
                    stagedFileURL: stagedURL,
                    metadata: meta,
                    httpStatusCode: httpStatus
                )
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let meta = decodeMetadata(from: task) else { return }
            Task { @MainActor [weak self] in
                self?.manager?.handleBackgroundTaskError(metadata: meta, error: error)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor [weak self] in
                self?.manager?.handleBackgroundSessionFinishedAllEvents()
            }
        }
    }
}
