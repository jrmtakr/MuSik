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

/// Why a single playlist item could not be saved. Shown in the "Import Issues" report.
enum PlaylistImportFailureReason: String, Codable, CaseIterable, Sendable {
    case notFoundOnYouTube
    case videoUnavailable
    case noPlayableStream
    case blockedByYouTube
    case tooLong
    case networkError
    case downloadStalled
    case timedOut
    case emptyDownload
    case conversionFailed
    case saveFailed
    case other

    var title: String {
        switch self {
        case .notFoundOnYouTube: return "Couldn't find a matching video"
        case .videoUnavailable: return "Video unavailable"
        case .noPlayableStream: return "No downloadable stream"
        case .blockedByYouTube: return "Blocked by YouTube"
        case .tooLong: return "Longer than max duration"
        case .networkError: return "Network error"
        case .downloadStalled: return "Download stalled"
        case .timedOut: return "Timed out"
        case .emptyDownload: return "Empty or broken file"
        case .conversionFailed: return "Audio/video conversion failed"
        case .saveFailed: return "Couldn't save to library"
        case .other: return "Other error"
        }
    }

    var systemImage: String {
        switch self {
        case .notFoundOnYouTube: return "magnifyingglass"
        case .videoUnavailable: return "eye.slash"
        case .noPlayableStream: return "play.slash"
        case .blockedByYouTube: return "hand.raised"
        case .tooLong: return "clock.badge.exclamationmark"
        case .networkError: return "wifi.exclamationmark"
        case .downloadStalled: return "pause.circle"
        case .timedOut: return "hourglass"
        case .emptyDownload: return "doc.badge.ellipsis"
        case .conversionFailed: return "waveform.badge.exclamationmark"
        case .saveFailed: return "externaldrive.badge.xmark"
        case .other: return "exclamationmark.triangle"
        }
    }

    /// Plain-language hint about what the user can do.
    var suggestion: String {
        switch self {
        case .notFoundOnYouTube: return "The title/artist search found no video. Try retrying, or search it manually in the Browser tab."
        case .videoUnavailable: return "The video is private, removed, region-locked or age-restricted. Signing into YouTube in the Browser tab can help."
        case .noPlayableStream: return "YouTube returned no stream the app can save. Retrying with \"Always Resolve via Built-in Browser\" often fixes this."
        case .blockedByYouTube: return "YouTube rejected the request (HTTP 403/429). Wait a few minutes, then retry."
        case .tooLong: return "Turn off \"Skip Tracks Longer Than Max Duration\" or raise the limit in Settings."
        case .networkError: return "Check your connection and retry."
        case .downloadStalled: return "The download stopped receiving data. Retry to start it fresh."
        case .timedOut: return "Finding the stream took too long. Retry."
        case .emptyDownload: return "The server sent an empty file. Retry."
        case .conversionFailed: return "The file downloaded but couldn't be converted. Try the other format (Audio/Video)."
        case .saveFailed: return "Check free storage space on your device."
        case .other: return "Retry. If it keeps failing, check the details below."
        }
    }

    /// Best-effort classification of a raw error string coming from resolvers / URLSession.
    static func classify(_ message: String) -> PlaylistImportFailureReason {
        let m = message.lowercased()
        if m.contains("403") || m.contains("429") || m.contains("sign in to confirm") || m.contains("bot") {
            return .blockedByYouTube
        }
        if m.contains("unavailable") || m.contains("private") || m.contains("removed") || m.contains("age")
            || m.contains("copyright") || m.contains("not available in your country") || m.contains("login_required") {
            return .videoUnavailable
        }
        if m.contains("timed out") || m.contains("timeout") { return .timedOut }
        if m.contains("offline") || m.contains("network") || m.contains("internet") || m.contains("connection") || m.contains("host") {
            return .networkError
        }
        if m.contains("empty") || m.contains("bytes") { return .emptyDownload }
        if m.contains("stream") { return .noPlayableStream }
        return .other
    }
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
    // Optional so older saved queues still decode.
    var failureReason: PlaylistImportFailureReason?
    /// Which part failed, e.g. "Finding video", "Audio track download", "Video track download", "Saving".
    var failureStage: String?
    var lastAttemptAt: Date?
    var totalAttempts: Int?
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

    // Optional so older saved queues still decode.
    /// True once every page of the source playlist has been discovered.
    var discoveryCompleted: Bool?
    /// False when the user hand-picked a subset of tracks, so re-discovering would re-add songs they deselected.
    var allowsRediscovery: Bool?
    /// Number of imported songs the song-ID AI corrected (title/artist/album/cover).
    var identifiedCount: Int?

    var totalCount: Int { tracks.count }
    var cancelledCount: Int { tracks.reduce(0) { $0 + ($1.status == .cancelled ? 1 : 0) } }
    var failedTracks: [PlaylistImportTrackJob] { tracks.filter { $0.status == .failed } }
    /// Stopped jobs (or jobs with failures) can be retried/restarted.
    var canRetry: Bool { failedCount > 0 || (isCancelled && cancelledCount > 0) || (isCancelled && discoveryCompleted != true) }
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

    /// Songs being worked on right now (found on YouTube / downloading), for the "Now caching" list.
    func inFlightTracks(in job: PlaylistImportJob) -> [PlaylistImportTrackJob] {
        job.tracks.filter { $0.status == .resolving || $0.status == .downloading }
    }

    /// The next few songs waiting in line.
    func upNextTracks(in job: PlaylistImportJob, limit: Int = 3) -> [PlaylistImportTrackJob] {
        Array(job.tracks.lazy.filter { $0.status == .pending }.prefix(limit))
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
    @ObservationIgnored private var discoveryTokenByJobID: [UUID: UUID] = [:]
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var pumpWakeupContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var bgExecutionTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var saveDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var importedSinceLastLibraryFlush = 0
    @ObservationIgnored private var cachedMediaByVideoID: [String: MediaItem] = [:]
    @ObservationIgnored private var didRegisterBGTask = false
    @ObservationIgnored private var pendingBGProcessingTask: BGProcessingTask?

    /// Each resolve attempt gets a token. Pause/stop/watchdog invalidate it, so a late result from an
    /// old attempt can never overwrite state or steal a concurrency slot from a newer attempt.
    @ObservationIgnored private var resolveAttemptByTrackID: [UUID: UUID] = [:]
    @ObservationIgnored private var resolveStartedAtByTrackID: [UUID: Date] = [:]
    @ObservationIgnored private var lastDownloadProgressAtByTrackID: [UUID: Date] = [:]
    @ObservationIgnored private var downloadStageByTrackID: [UUID: BackgroundDownloadTaskMetadata.Stage] = [:]
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    /// A resolve (finding video + stream) taking longer than this is treated as hung.
    private static let resolveHardTimeout: TimeInterval = 150
    /// A foreground download receiving no bytes for this long is treated as stalled.
    private static let downloadStallTimeout: TimeInterval = 75

    private static let maxConcurrentForegroundResolvers = 3
    private static let maxConcurrentDownloadsForeground = 4
    private static let maxConcurrentDownloadsBackground = 6
    private static let lookaheadResolveBuffer = 2

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
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 6

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
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillTerminate()
            }
        }
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

        // Stay awake while locked/backgrounded so songs keep being found, not just downloaded.
        if !MediaManager.shared.isPlaying {
            ImportKeepAlive.shared.start()
        }
        scheduleNextBGProcessingTaskIfNeeded()
        if bgExecutionTaskID == .invalid {
            bgExecutionTaskID = UIApplication.shared.beginBackgroundTask(withName: "MuseJRM.PlaylistBgQueue") { [weak self] in
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

    /// Swiping MuseJRM away in the app switcher makes iOS stop it (and cancel its downloads) — no app
    /// can keep running after that. Save the queue right now, synchronously, and leave a notification
    /// so it's one tap to continue. The import resumes automatically on the next launch.
    private func handleWillTerminate() {
        ImportKeepAlive.shared.stop()
        let snapshot = Array(jobs.prefix(20))
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.jobsFileURL, options: [.atomic])
        }
        MediaManager.shared.flushBatchPlaylistImport(playlistID: nil, summary: nil, reloadLibrary: false)

        let unfinished = activeJobs.filter { !$0.isCancelled }
        guard let first = unfinished.first else { return }
        let remaining = unfinished.reduce(0) { $0 + $1.remainingCount }
        let content = UNMutableNotificationContent()
        content.title = "Playlist import paused"
        content.body = "\(remaining) songs left in \"\(first.playlistName)\". Open MuseJRM to keep importing — it picks up where it left off."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "playlist-import-paused",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func handleWillEnterForeground() {
        // Time spent suspended isn't a stall: restart the watchdog clocks.
        let now = Date()
        for key in lastDownloadProgressAtByTrackID.keys { lastDownloadProgressAtByTrackID[key] = now }
        for key in resolveStartedAtByTrackID.keys { resolveStartedAtByTrackID[key] = now }
        ImportKeepAlive.shared.stop()
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
        skipDiscoveryIfComplete: Bool = false,
        allowsRediscovery: Bool = true
    ) -> UUID {
        refreshCachedVideoMap()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let jobID = UUID()
        var job = PlaylistImportJob(
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
        job.discoveryCompleted = skipDiscoveryIfComplete ? true : false
        job.allowsRediscovery = allowsRediscovery
        jobs.insert(job, at: 0)

        if !alreadyDiscoveredTracks.isEmpty {
            appendTracks(alreadyDiscoveredTracks, toJobID: jobID)
        }

        if !skipDiscoveryIfComplete {
            startDiscovery(
                jobID: jobID,
                urlString: sourceURLString,
                initialJSON: initialInitialDataJSON,
                listID: listIDForInitialData
            )
        }

        scheduleDebouncedSave()
        ensurePumping()
        return jobID
    }

    private func startDiscovery(jobID: UUID, urlString: String, initialJSON: [String: Any]? = nil, listID: String? = nil) {
        discoveryTasksByJobID[jobID]?.cancel()
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].isDiscoveringPages = true
            jobs[idx].discoveryError = nil
        }
        let capturedInitialJSON = initialJSON
        let token = UUID()
        discoveryTokenByJobID[jobID] = token
        discoveryTasksByJobID[jobID] = Task { [weak self] in
            await self?.runDiscoveryStream(
                jobID: jobID,
                urlString: urlString,
                initialJSON: capturedInitialJSON,
                listID: listID
            )
            guard let self, self.discoveryTokenByJobID[jobID] == token else { return }
            self.discoveryTokenByJobID.removeValue(forKey: jobID)
            self.discoveryTasksByJobID.removeValue(forKey: jobID)
        }
    }

    /// Appends newly streamed tracks from an external discovery task (e.g. ImportPlaylistSheetView live stream).
    func appendDiscoveredTracks(_ tracks: [ExternalPlaylistTrack], toJobID jobID: UUID, isComplete: Bool) {
        appendTracks(tracks, toJobID: jobID)
        if isComplete, let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].isDiscoveringPages = false
            if !jobs[idx].isCancelled {
                jobs[idx].discoveryCompleted = true
            }
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
        // Discovery may have been the only thing keeping the job "unfinished".
        finalizeCompletedJobsIfNeeded()
    }

    // MARK: - Job Controls

    /// Cancels in-flight network work for a track and invalidates any resolver still running for it.
    private func abortInFlightWork(forTrackID trackID: UUID) {
        if let task = activeDownloadTasksByTrackID.removeValue(forKey: trackID) {
            task.cancel()
        }
        activeResolvingTrackIDs.remove(trackID)
        resolveAttemptByTrackID.removeValue(forKey: trackID)
        resolveStartedAtByTrackID.removeValue(forKey: trackID)
        lastDownloadProgressAtByTrackID.removeValue(forKey: trackID)
        downloadStageByTrackID.removeValue(forKey: trackID)
        activeDownloadProgressByTrackID.removeValue(forKey: trackID)
        removePairedVideoURL(forTrackID: trackID)
    }

    func pauseJob(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].isPaused = true
        jobs[idx].updatedAt = .now
        for track in jobs[idx].tracks {
            abortInFlightWork(forTrackID: track.id)
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
        if let wakeup = pumpWakeupContinuation {
            pumpWakeupContinuation = nil
            wakeup.resume()
        }
    }

    func resumeJob(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }), !jobs[idx].isCancelled else { return }
        jobs[idx].isPaused = false
        jobs[idx].discoveryError = nil
        jobs[idx].updatedAt = .now
        resetStuckInFlightTracks(jobIndex: idx)
        restartDiscoveryIfInterrupted(jobIndex: idx)
        refreshCachedVideoMap()
        persistJobsNow()
        ensurePumping()
    }

    /// Retries everything that didn't make it: failed tracks AND tracks that were stopped mid-import.
    ///
    /// Bug this fixes: Stop marked every unfinished track `.cancelled`, but Retry only reset `.failed`
    /// tracks. The job was un-cancelled with tracks that could never be picked up again, so the pump
    /// loop found nothing to do while the job still showed "remaining" — the import sat stalled forever.
    /// Tracks discovered after Stop were also dropped, and discovery was never restarted.
    func retryFailedTracks(inJobID id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var resetFailed = 0
        var resetCancelled = 0
        for tIdx in jobs[idx].tracks.indices {
            let status = jobs[idx].tracks[tIdx].status
            guard status == .failed || status == .cancelled else { continue }
            abortInFlightWork(forTrackID: jobs[idx].tracks[tIdx].id)
            if status == .failed { resetFailed += 1 } else { resetCancelled += 1 }
            jobs[idx].tracks[tIdx].status = .pending
            jobs[idx].tracks[tIdx].errorMessage = nil
            jobs[idx].tracks[tIdx].failureReason = nil
            jobs[idx].tracks[tIdx].failureStage = nil
            jobs[idx].tracks[tIdx].retryCount = 0
        }
        // Anything still flagged resolving/downloading without live work behind it is stuck too.
        resetStuckInFlightTracks(jobIndex: idx)

        let wasCancelled = jobs[idx].isCancelled
        jobs[idx].failedCount = max(0, jobs[idx].failedCount - resetFailed)
        jobs[idx].isPaused = false
        jobs[idx].isCancelled = false
        jobs[idx].updatedAt = .now
        if wasCancelled {
            restartDiscoveryIfInterrupted(jobIndex: idx)
        }
        // Refresh cookies (a stale sign-in is a common reason for the first failure).
        Task { _ = await BrowserYouTubeResolver.youtubeCookieHeader(forceRefresh: true) }
        refreshCachedVideoMap()
        currentStatusMessage = resetFailed + resetCancelled > 0
            ? "Retrying \(resetFailed + resetCancelled) tracks in \"\(jobs[idx].playlistName)\"..."
            : currentStatusMessage
        persistJobsNow()
        ensurePumping()
    }

    /// Retries one specific failed/stopped track.
    func retryTrack(jobID: UUID, trackID: UUID) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let status = jobs[jIdx].tracks[tIdx].status
        guard status == .failed || status == .cancelled else { return }
        abortInFlightWork(forTrackID: trackID)
        if status == .failed {
            jobs[jIdx].failedCount = max(0, jobs[jIdx].failedCount - 1)
        }
        jobs[jIdx].tracks[tIdx].status = .pending
        jobs[jIdx].tracks[tIdx].errorMessage = nil
        jobs[jIdx].tracks[tIdx].failureReason = nil
        jobs[jIdx].tracks[tIdx].failureStage = nil
        jobs[jIdx].tracks[tIdx].retryCount = 0
        jobs[jIdx].isCancelled = false
        jobs[jIdx].isPaused = false
        jobs[jIdx].updatedAt = .now
        persistJobsNow()
        ensurePumping()
    }

    /// Tracks marked resolving/downloading with no live resolver or URLSession task behind them
    /// would never be picked up again. Put them back in the queue.
    private func resetStuckInFlightTracks(jobIndex idx: Int) {
        for tIdx in jobs[idx].tracks.indices {
            let track = jobs[idx].tracks[tIdx]
            let isLive = activeDownloadTasksByTrackID[track.id] != nil || resolveAttemptByTrackID[track.id] != nil
            if (track.status == .resolving || track.status == .downloading) && !isLive {
                jobs[idx].tracks[tIdx].status = .pending
            }
        }
    }

    private func restartDiscoveryIfInterrupted(jobIndex idx: Int) {
        let job = jobs[idx]
        guard job.discoveryCompleted == false,
              job.allowsRediscovery != false,
              discoveryTasksByJobID[job.id] == nil,
              !job.sourceURLString.isEmpty else { return }
        startDiscovery(jobID: job.id, urlString: job.sourceURLString)
    }

    func cancelJob(id: UUID) {
        discoveryTasksByJobID.removeValue(forKey: id)?.cancel()
        discoveryTokenByJobID.removeValue(forKey: id)
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].isCancelled = true
        jobs[idx].isDiscoveringPages = false
        jobs[idx].isPaused = false
        jobs[idx].updatedAt = .now

        for i in jobs[idx].tracks.indices {
            let tid = jobs[idx].tracks[i].id
            abortInFlightWork(forTrackID: tid)
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
        if let wakeup = pumpWakeupContinuation {
            pumpWakeupContinuation = nil
            wakeup.resume()
        }
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
                do {
                    _ = try await PlaylistURLImporter.continueYouTubePlaylist(
                        fromInitialJSON: initialJSON,
                        listID: listID,
                        cookiesHeader: cookies
                    ) { page in
                        await MainActor.run {
                            self.handleDiscoveryPage(jobID: jobID, page: page)
                        }
                    }
                } catch {
                    _ = try await PlaylistURLImporter.streamPlaylist(from: urlString, cookiesHeader: cookies) { page in
                        await MainActor.run {
                            self.handleDiscoveryPage(jobID: jobID, page: page)
                        }
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

            if let idx = jobs.firstIndex(where: { $0.id == jobID }), !Task.isCancelled {
                jobs[idx].isDiscoveringPages = false
                if !jobs[idx].isCancelled {
                    jobs[idx].discoveryCompleted = true
                }
                jobs[idx].updatedAt = .now
                scheduleDebouncedSave()
                ensurePumping()
            }
        } catch is CancellationError {
            // Ignored
        } catch {
            if !Task.isCancelled {
                markDiscoveryFailed(jobID: jobID, message: error.localizedDescription)
            }
        }
    }

    private func handleDiscoveryPage(
        jobID: UUID,
        page: PlaylistURLImporter.PlaylistStreamPage
    ) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }), !jobs[idx].isCancelled else { return }
        let currentName = jobs[idx].playlistName
        let isPlaceholderName = currentName.isEmpty
            || currentName == "YouTube Playlist"
            || currentName == "YouTube Music Playlist"
            || currentName == "Spotify Playlist"
            || currentName == "Apple Music Playlist"
        if isPlaceholderName,
           !page.playlistTitle.isEmpty,
           page.playlistTitle != "YouTube Playlist" {
            jobs[idx].playlistName = page.playlistTitle
            MediaManager.shared.renamePlaylistSilently(id: jobs[idx].targetPlaylistID, to: page.playlistTitle)
        }
        if !page.newTracks.isEmpty {
            appendTracks(page.newTracks, toJobID: jobID)
        }
        if page.isComplete {
            jobs[idx].isDiscoveringPages = false
            jobs[idx].discoveryCompleted = true
        }
        jobs[idx].updatedAt = .now
        scheduleDebouncedSave()
        ensurePumping()
    }

    private func appendTracks(_ newTracks: [ExternalPlaylistTrack], toJobID jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }), !jobs[idx].isCancelled else { return }

        var existingVideoIDs = Set(jobs[idx].tracks.compactMap(\.youtubeVideoID))
        // Title+artist keys de-duplicate tracks without a video ID (Spotify/Apple Music) when discovery
        // is restarted after Stop/relaunch, or when two discovery streams feed the same job.
        var existingTitleKeys = Set(jobs[idx].tracks.map { Self.dedupKey(title: $0.title, artist: $0.artist) })
        var existingCacheItemsToAdd: [MediaItem] = []
        var itemsToAppend: [PlaylistImportTrackJob] = []
        let baseIndex = jobs[idx].tracks.count

        for (offset, track) in newTracks.enumerated() {
            let cleanVID = track.youtubeVideoID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleKey = Self.dedupKey(title: track.title, artist: track.artist)
            if cleanVID == nil || cleanVID?.isEmpty == true {
                guard existingTitleKeys.insert(titleKey).inserted else { continue }
            } else {
                existingTitleKeys.insert(titleKey)
            }
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

    private static func dedupKey(title: String, artist: String) -> String {
        let t = title.lowercased().filter { $0.isLetter || $0.isNumber }
        let a = artist.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(t)|\(a)"
    }

    // MARK: - Worker Scheduler & Execution Loop

    private func ensurePumping() {
        if let wakeup = pumpWakeupContinuation {
            pumpWakeupContinuation = nil
            wakeup.resume()
        }
        guard pumpTask == nil else { return }
        guard activeJobs.contains(where: { !$0.isPaused && !$0.isCancelled }) else { return }
        pumpTask = Task { [weak self] in
            await self?.runPumpLoop()
        }
        startWatchdogIfNeeded()
    }

    // MARK: - Stall Watchdog

    /// Safety net so the queue can never sit frozen: a resolve that hangs (e.g. WKWebView JS never
    /// answering) or a foreground download that stops receiving bytes is failed with a clear reason
    /// (and auto-retried once), freeing its slot for the next track.
    private func startWatchdogIfNeeded() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                let stillBusy = self.runWatchdogPass()
                if !stillBusy {
                    self.watchdogTask = nil
                    return
                }
            }
        }
    }

    /// Returns false when there is nothing left to watch.
    private func runWatchdogPass() -> Bool {
        let now = Date()

        for (trackID, startedAt) in resolveStartedAtByTrackID
        where now.timeIntervalSince(startedAt) > Self.resolveHardTimeout {
            guard let jobID = jobs.first(where: { job in job.tracks.contains(where: { $0.id == trackID }) })?.id,
                  let pair = lookup(jobID: jobID, trackID: trackID),
                  pair.track.status == .resolving else {
                resolveStartedAtByTrackID.removeValue(forKey: trackID)
                continue
            }
            // Invalidate the hung attempt; whatever it returns later is ignored.
            resolveAttemptByTrackID.removeValue(forKey: trackID)
            resolveStartedAtByTrackID.removeValue(forKey: trackID)
            activeResolvingTrackIDs.remove(trackID)
            markTrackFailed(
                jobID: jobID,
                trackID: trackID,
                error: "Finding a stream took longer than \(Int(Self.resolveHardTimeout))s",
                retryable: true,
                reason: .timedOut,
                stage: "Finding video & stream"
            )
        }

        // Background URLSession transfers are scheduled by iOS and can legitimately pause while the
        // app is suspended, so stall detection only applies in the foreground.
        if UIApplication.shared.applicationState == .active {
            for (trackID, task) in activeDownloadTasksByTrackID {
                let last = lastDownloadProgressAtByTrackID[trackID] ?? now
                guard now.timeIntervalSince(last) > Self.downloadStallTimeout else { continue }
                guard let jobID = jobs.first(where: { job in job.tracks.contains(where: { $0.id == trackID }) })?.id else { continue }
                let stage = downloadStageByTrackID[trackID]
                abortInFlightWork(forTrackID: trackID)
                task.cancel()
                let bytes = task.countOfBytesReceived
                markTrackFailed(
                    jobID: jobID,
                    trackID: trackID,
                    error: "No data received for \(Int(Self.downloadStallTimeout))s (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) downloaded)",
                    retryable: true,
                    reason: .downloadStalled,
                    stage: Self.stageLabel(stage)
                )
            }
        }

        // Background keep-alive: not needed while music is playing (that keeps the app awake), but
        // needed again if the music stops while an import is still running.
        let hasRunnableJobs = activeJobs.contains(where: { !$0.isPaused && !$0.isCancelled })
        if UIApplication.shared.applicationState == .background {
            if hasRunnableJobs && !MediaManager.shared.isPlaying {
                ImportKeepAlive.shared.start()
            } else if !hasRunnableJobs || MediaManager.shared.isPlaying {
                ImportKeepAlive.shared.stop()
            }
        }

        finalizeCompletedJobsIfNeeded()
        ensurePumping()
        return !resolveStartedAtByTrackID.isEmpty || !activeDownloadTasksByTrackID.isEmpty || pumpTask != nil
    }

    private static func stageLabel(_ stage: BackgroundDownloadTaskMetadata.Stage?) -> String {
        switch stage {
        case .pairedAudio: return "Audio track download"
        case .pairedVideo: return "Video track download"
        case .audioExtractFromMP4: return "Audio download (from MP4)"
        case .singleDirect: return "Download"
        case nil: return "Download"
        }
    }

    private func isCurrentAttempt(_ attempt: UUID, trackID: UUID) -> Bool {
        resolveAttemptByTrackID[trackID] == attempt
    }

    private func markAttemptStarted(jobID: UUID, trackID: UUID) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        jobs[jIdx].tracks[tIdx].lastAttemptAt = .now
        jobs[jIdx].tracks[tIdx].totalAttempts = (jobs[jIdx].tracks[tIdx].totalAttempts ?? 0) + 1
    }

    private func waitForQueueEvent() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.pumpWakeupContinuation = continuation
        }
    }

    private func runPumpLoop() async {
        defer {
            pumpTask = nil
            if let wakeup = pumpWakeupContinuation {
                pumpWakeupContinuation = nil
                wakeup.resume()
            }
        }

        while true {
            let isBackground = UIApplication.shared.applicationState == .background
            let maxDownloads = isBackground ? Self.maxConcurrentDownloadsBackground : Self.maxConcurrentDownloadsForeground
            let maxResolvers = isBackground ? 2 : Self.maxConcurrentForegroundResolvers

            var startedWork = false
            while activeResolvingTrackIDs.count < maxResolvers,
                  activeResolvingTrackIDs.count + activeDownloadTasksByTrackID.count < maxDownloads + Self.lookaheadResolveBuffer,
                  let nextPair = nextResolvableTrack() {
                let (jobID, trackID) = nextPair
                setTrackStatus(jobID: jobID, trackID: trackID, status: .resolving)
                markAttemptStarted(jobID: jobID, trackID: trackID)
                activeResolvingTrackIDs.insert(trackID)
                let attempt = UUID()
                resolveAttemptByTrackID[trackID] = attempt
                resolveStartedAtByTrackID[trackID] = .now
                startedWork = true

                Task { [weak self] in
                    await self?.resolveAndScheduleTrack(jobID: jobID, trackID: trackID, attempt: attempt)
                }
            }

            if nextResolvableTrack() == nil {
                finalizeCompletedJobsIfNeeded()
                if activeDownloadTasksByTrackID.isEmpty && activeResolvingTrackIDs.isEmpty {
                    BrowserYouTubeResolver.shared.releaseIdleWebView()
                    ImportKeepAlive.shared.stop()
                    if let bgTask = pendingBGProcessingTask {
                        bgTask.setTaskCompleted(success: true)
                        pendingBGProcessingTask = nil
                    }
                    break
                }
            }

            if !startedWork || activeResolvingTrackIDs.count >= maxResolvers {
                await waitForQueueEvent()
            } else {
                await Task.yield()
            }
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

    private func resolveAndScheduleTrack(jobID: UUID, trackID: UUID, attempt: UUID) async {
        defer {
            // Only release the slot if this attempt still owns it (pause/stop/watchdog may have
            // handed the track to a newer attempt already).
            if isCurrentAttempt(attempt, trackID: trackID) {
                resolveAttemptByTrackID.removeValue(forKey: trackID)
                resolveStartedAtByTrackID.removeValue(forKey: trackID)
                activeResolvingTrackIDs.remove(trackID)
            }
            ensurePumping()
        }

        guard let (job, track) = lookup(jobID: jobID, trackID: trackID),
              !job.isPaused, !job.isCancelled else {
            return
        }

        /// After every `await`, make sure the job wasn't paused/stopped and this attempt wasn't timed out.
        func stillValid() -> Bool {
            guard isCurrentAttempt(attempt, trackID: trackID),
                  let fresh = jobs.first(where: { $0.id == jobID }),
                  !fresh.isPaused, !fresh.isCancelled else { return false }
            return true
        }

        currentStatusMessage = "Finding \"\(track.title)\"..."

        // Step 1: Ensure YouTube Video ID
        var videoID = track.youtubeVideoID
        var usedBrowser = false

        if videoID == nil || videoID?.isEmpty == true {
            if !job.alwaysUseBrowserResolver {
                videoID = await PlaylistURLImporter.findBestYouTubeVideoID(title: track.title, artist: track.artist)
                guard stillValid() else { return }
            }
            if videoID == nil || videoID?.isEmpty == true {
                usedBrowser = true
                videoID = await BrowserYouTubeResolver.shared.findVideoIDInBrowser(title: track.title, artist: track.artist)
                guard stillValid() else { return }
            }
            if let foundID = videoID, !foundID.isEmpty {
                updateTrackVideoID(jobID: jobID, trackID: trackID, videoID: foundID)
            }
        }

        guard let resolvedVideoID = videoID, !resolvedVideoID.isEmpty else {
            markTrackFailed(
                jobID: jobID,
                trackID: trackID,
                error: "No YouTube video matched \"\(track.artist.isEmpty ? "" : track.artist + " - ")\(track.title)\" (searched API\(usedBrowser ? " + built-in browser" : ""))",
                retryable: true,
                reason: .notFoundOnYouTube,
                stage: "Finding video"
            )
            return
        }

        // Step 2: Re-check offline cache deduplication after finding video ID
        if let cached = cachedMediaByVideoID[resolvedVideoID] ?? MediaManager.shared.existingMediaItem(forVideoID: resolvedVideoID) {
            cachedMediaByVideoID[resolvedVideoID] = cached
            MediaManager.shared.addExistingItemToPlaylistFast(cached, playlistID: job.targetPlaylistID, flushState: false)
            markTrackSkippedAlreadyCached(jobID: jobID, trackID: trackID)
            return
        }

        // Step 3: Resolve streams (fast InnerTube with reachability check -> Built-in Browser WKWebView fallback)
        var resolvedResult: YouTubeResolvedResult?
        var apiErrorReason: String?
        var cookiesHeader = await BrowserYouTubeResolver.youtubeCookieHeader()
        guard stillValid() else { return }

        if !job.alwaysUseBrowserResolver,
           (track.retryCount == 0 || track.retryCount >= 2),
           let watchURL = URL(string: "https://www.youtube.com/watch?v=\(resolvedVideoID)") {
            resolvedResult = await YouTubeStreamResolver.resolveStreams(
                for: watchURL,
                cookiesHeader: cookiesHeader,
                referer: watchURL.absoluteString,
                visitorData: nil,
                skipReachabilityProbe: false
            )
            guard stillValid() else { return }
            apiErrorReason = resolvedResult?.errorReason
        }

        if resolvedResult == nil || (resolvedResult?.streams.isEmpty ?? true) {
            usedBrowser = true
            if let browserResolved = await BrowserYouTubeResolver.shared.resolveStreamsInBrowser(videoID: resolvedVideoID) {
                resolvedResult = browserResolved.result
                cookiesHeader = browserResolved.cookiesHeader ?? cookiesHeader
            }
            guard stillValid() else { return }
        }

        guard let resolvedResult, !resolvedResult.streams.isEmpty else {
            let raw = resolvedResult?.errorReason ?? apiErrorReason
            let reason: PlaylistImportFailureReason = raw.map { PlaylistImportFailureReason.classify($0) } ?? .noPlayableStream
            markTrackFailed(
                jobID: jobID,
                trackID: trackID,
                error: (raw.map { "YouTube said: \($0)" } ?? "No playable stream found via API or built-in browser")
                    + " [video \(resolvedVideoID)]",
                retryable: track.retryCount < 2,
                reason: reason == .other ? .noPlayableStream : reason,
                stage: "Getting stream"
            )
            return
        }

        // Respect optional duration guard only when user kept it enabled
        if job.respectMaxDurationLimit {
            let maxMins = UserDefaults.standard.integer(forKey: "musicplayer.maxDuration")
            if maxMins > 0, let dur = resolvedResult.durationSeconds, dur > Double(maxMins) * 60 {
                markTrackFailed(
                    jobID: jobID,
                    trackID: trackID,
                    error: "Video is \(MediaTimeFormatter.format(dur)), limit is \(maxMins)m",
                    retryable: false,
                    reason: .tooLong,
                    stage: "Checking length"
                )
                return
            }
        }

        // Step 4: Select best stream & enqueue into background URLSession
        guard let picked = selectBestStream(from: resolvedResult.streams, format: job.preferredFormat) else {
            // HLS-only fallback via foreground WebMediaDownloader if available
            if let rawHLS = resolvedResult.streams.first(where: { $0.isHLS }) {
                setTrackStatus(jobID: jobID, trackID: trackID, status: .downloading)
                // Long HLS downloads are exempt from the resolve timeout.
                resolveStartedAtByTrackID.removeValue(forKey: trackID)
                let fallbackTitle = track.title.isEmpty ? resolvedResult.title : track.title
                let fallbackArtist = track.artist.isEmpty ? resolvedResult.author : track.artist
                let labeledHLS = DetectedBrowserMedia(
                    url: rawHLS.url,
                    pairedAudioURL: rawHLS.pairedAudioURL,
                    isHLS: rawHLS.isHLS,
                    isAudio: rawHLS.isAudio,
                    title: rawHLS.title ?? fallbackTitle,
                    author: rawHLS.author ?? fallbackArtist,
                    qualityLabel: rawHLS.qualityLabel,
                    referer: rawHLS.referer,
                    customHeaders: rawHLS.customHeaders,
                    durationSeconds: rawHLS.durationSeconds ?? resolvedResult.durationSeconds,
                    isActivelyPlaying: false
                )
                if let downloaded = await WebMediaDownloader.shared.downloadTrackIntoPlaylist(
                    labeledHLS,
                    fallbackStreams: resolvedResult.streams,
                    targetPlaylistID: job.targetPlaylistID,
                    maxDurationMinutes: 0,
                    sourceVideoID: resolvedVideoID,
                    preferAudioOnly: job.preferredFormat == .audioOnly
                ) {
                    cachedMediaByVideoID[resolvedVideoID] = downloaded
                    markTrackCompleted(jobID: jobID, trackID: trackID, viaBrowser: usedBrowser)
                    SongIdentificationService.shared.enqueue(
                        downloaded,
                        hintTitle: track.title,
                        hintArtist: track.artist,
                        sourceVideoID: resolvedVideoID,
                        sourcePlatform: sourcePlatform(forJobID: jobID),
                        jobID: jobID
                    )
                    return
                }
                guard stillValid() else { return }
                markTrackFailed(
                    jobID: jobID,
                    trackID: trackID,
                    error: "HLS (segmented) stream download failed",
                    retryable: track.retryCount == 0,
                    reason: .noPlayableStream,
                    stage: "HLS download"
                )
                return
            }
            let kinds = Set(resolvedResult.streams.map { $0.isHLS ? "HLS" : ($0.isAudio ? "audio" : "video") }).sorted().joined(separator: ", ")
            markTrackFailed(
                jobID: jobID,
                trackID: trackID,
                error: "No \(job.preferredFormat == .audioOnly ? "audio" : "video") stream the app can save (found: \(kinds.isEmpty ? "none" : kinds))",
                retryable: track.retryCount < 2,
                reason: .noPlayableStream,
                stage: "Picking stream"
            )
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
            if let paired = streams.first(where: { !$0.isHLS && $0.pairedAudioURL != nil }),
               let audioURL = paired.pairedAudioURL {
                let ext = validExtension(for: audioURL, fallback: "m4a")
                return (audioURL, nil, paired.customHeaders, .singleDirect, ext)
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
            markTrackFailed(jobID: jobID, trackID: track.id, error: "Could not serialize task", retryable: false, reason: .other, stage: "Starting download")
            return
        }

        setTrackStatus(jobID: jobID, trackID: track.id, status: .downloading)
        activeDownloadProgressByTrackID[track.id] = 0
        lastDownloadProgressAtByTrackID[track.id] = .now
        downloadStageByTrackID[track.id] = stage
        resolveStartedAtByTrackID.removeValue(forKey: track.id)

        let task = backgroundSession.downloadTask(with: request)
        task.taskDescription = metaString
        activeDownloadTasksByTrackID[track.id] = task
        task.resume()
    }

    // MARK: - Background Delegate Callbacks

    fileprivate func recordDownloadProgress(trackID: UUID, fraction: Double?) {
        // Ignore late callbacks from tasks that were already cancelled/aborted.
        guard activeDownloadTasksByTrackID[trackID] != nil else { return }
        lastDownloadProgressAtByTrackID[trackID] = .now
        if let fraction {
            activeDownloadProgressByTrackID[trackID] = fraction
        }
    }

    /// True when a URLSession callback belongs to the download we're currently tracking for this track
    /// (and not a stale task from before a pause/stop/retry).
    private func isCurrentDownload(trackID: UUID, jobID: UUID, taskIdentifier: Int) -> Bool {
        if let active = activeDownloadTasksByTrackID[trackID] {
            return active.taskIdentifier == taskIdentifier
        }
        // App relaunched before reconcile finished: trust the persisted status.
        return lookup(jobID: jobID, trackID: trackID)?.track.status == .downloading
    }

    private func handleBackgroundDownloadFinished(
        stagedFileURL: URL,
        metadata: BackgroundDownloadTaskMetadata,
        httpStatusCode: Int?,
        taskIdentifier: Int
    ) async {
        guard isCurrentDownload(trackID: metadata.trackID, jobID: metadata.jobID, taskIdentifier: taskIdentifier) else {
            try? FileManager.default.removeItem(at: stagedFileURL)
            return
        }
        activeDownloadTasksByTrackID.removeValue(forKey: metadata.trackID)
        activeDownloadProgressByTrackID.removeValue(forKey: metadata.trackID)
        lastDownloadProgressAtByTrackID.removeValue(forKey: metadata.trackID)
        downloadStageByTrackID.removeValue(forKey: metadata.trackID)

        let fileSize = (try? stagedFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let hasBadHTTPStatus = httpStatusCode.map { !(200...299).contains($0) } ?? false
        if hasBadHTTPStatus || fileSize < 2048 {
            try? FileManager.default.removeItem(at: stagedFileURL)
            removePairedVideoURL(forTrackID: metadata.trackID)
            let reason: PlaylistImportFailureReason
            let message: String
            if let code = httpStatusCode, hasBadHTTPStatus {
                reason = (code == 403 || code == 429) ? .blockedByYouTube : (code == 404 || code == 410 ? .videoUnavailable : .other)
                message = "Server returned HTTP \(code)\(code == 403 ? " (forbidden — stream link expired or blocked)" : code == 429 ? " (too many requests)" : "")"
            } else {
                reason = .emptyDownload
                message = "Downloaded file was empty (\(fileSize) bytes)"
            }
            handleDownloadFailureOrRetry(metadata: metadata, message: message, reason: reason)
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
                markTrackFailed(
                    jobID: metadata.jobID,
                    trackID: metadata.trackID,
                    error: "Audio track downloaded, but the matching video link was lost",
                    retryable: true,
                    reason: .other,
                    stage: "Video track download"
                )
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
            SongIdentificationService.shared.enqueue(
                imported,
                hintTitle: metadata.title,
                hintArtist: metadata.artist,
                sourceVideoID: metadata.videoID,
                sourcePlatform: sourcePlatform(forJobID: metadata.jobID),
                jobID: metadata.jobID
            )
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
            markTrackFailed(
                jobID: metadata.jobID,
                trackID: metadata.trackID,
                error: "Could not move the downloaded file into your library (storage full?)",
                retryable: false,
                reason: .saveFailed,
                stage: "Saving"
            )
        }

        finalizeCompletedJobsIfNeeded()
        ensurePumping()
    }

    /// Where the playlist came from. Spotify/Apple Music playlists carry exact song titles & artists,
    /// which the song-ID step trusts more than a YouTube video title.
    private func sourcePlatform(forJobID jobID: UUID) -> ExternalPlaylistPlatform? {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return nil }
        return PlaylistURLImporter.parsePlaylistURL(job.sourceURLString)?.platform
    }

    /// Called by the song-ID service when it corrected an imported track's metadata.
    func noteTrackIdentified(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[idx].identifiedCount = (jobs[idx].identifiedCount ?? 0) + 1
        scheduleDebouncedSave()
    }

    private func handleBackgroundTaskError(
        metadata: BackgroundDownloadTaskMetadata,
        error: Error,
        taskIdentifier: Int
    ) {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            // We cancelled it ourselves (pause/stop/watchdog). Don't touch newer attempts' state.
            if activeDownloadTasksByTrackID[metadata.trackID]?.taskIdentifier == taskIdentifier {
                activeDownloadTasksByTrackID.removeValue(forKey: metadata.trackID)
                activeDownloadProgressByTrackID.removeValue(forKey: metadata.trackID)
            }
            return
        }
        guard isCurrentDownload(trackID: metadata.trackID, jobID: metadata.jobID, taskIdentifier: taskIdentifier) else { return }
        activeDownloadTasksByTrackID.removeValue(forKey: metadata.trackID)
        activeDownloadProgressByTrackID.removeValue(forKey: metadata.trackID)
        lastDownloadProgressAtByTrackID.removeValue(forKey: metadata.trackID)
        downloadStageByTrackID.removeValue(forKey: metadata.trackID)

        let reason: PlaylistImportFailureReason
        switch nsErr.code {
        case NSURLErrorTimedOut: reason = .timedOut
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed:
            reason = .networkError
        default: reason = PlaylistImportFailureReason.classify(error.localizedDescription)
        }
        handleDownloadFailureOrRetry(
            metadata: metadata,
            message: "\(error.localizedDescription) (code \(nsErr.code))",
            reason: reason
        )
    }

    private func handleDownloadFailureOrRetry(
        metadata: BackgroundDownloadTaskMetadata,
        message: String,
        reason: PlaylistImportFailureReason
    ) {
        if let audioName = metadata.pairedAudioStagingFileName,
           metadata.stage == .pairedVideo {
            try? FileManager.default.removeItem(at: Self.stagingDirectoryURL.appendingPathComponent(audioName))
        }
        if let pair = lookup(jobID: metadata.jobID, trackID: metadata.trackID),
           pair.track.retryCount < 2,
           !pair.job.isPaused, !pair.job.isCancelled {
            incrementRetryAndRequeue(jobID: metadata.jobID, trackID: metadata.trackID)
            ensurePumping()
        } else {
            markTrackFailed(
                jobID: metadata.jobID,
                trackID: metadata.trackID,
                error: message,
                retryable: false,
                reason: reason,
                stage: Self.stageLabel(metadata.stage)
            )
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
                lastDownloadProgressAtByTrackID[meta.trackID] = .now
                downloadStageByTrackID[meta.trackID] = meta.stage
                activeIDs.insert(meta.trackID)
            }
        }

        var changed = false
        for jIdx in jobs.indices {
            if jobs[jIdx].isDiscoveringPages && discoveryTasksByJobID[jobs[jIdx].id] == nil && !jobs[jIdx].isCancelled && !jobs[jIdx].isPaused {
                // Discovery was interrupted (app was swiped away / killed). Restart it from the source URL
                // automatically; already-queued tracks are de-duplicated.
                jobs[jIdx].isDiscoveringPages = false
                jobs[jIdx].discoveryCompleted = false
                restartDiscoveryIfInterrupted(jobIndex: jIdx)
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
        content.body = job.failedCount > 0
            ? "\(job.playlistName): \(job.completedCount + job.skippedCount) cached offline, \(job.failedCount) failed. Open Import Issues to see why."
            : "\(job.playlistName): \(job.completedCount + job.skippedCount) cached offline."
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
        jobs[jIdx].tracks[tIdx].failureReason = nil
        jobs[jIdx].tracks[tIdx].failureStage = nil
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
        if prev == .failed { jobs[jIdx].failedCount = max(0, jobs[jIdx].failedCount - 1) }
        jobs[jIdx].tracks[tIdx].status = .skippedAlreadyCached
        jobs[jIdx].tracks[tIdx].failureReason = nil
        jobs[jIdx].tracks[tIdx].errorMessage = nil
        jobs[jIdx].skippedCount += 1
        jobs[jIdx].updatedAt = .now
        scheduleDebouncedSave()
    }

    private func markTrackFailed(
        jobID: UUID,
        trackID: UUID,
        error: String,
        retryable: Bool,
        reason: PlaylistImportFailureReason? = nil,
        stage: String? = nil
    ) {
        guard let jIdx = jobs.firstIndex(where: { $0.id == jobID }),
              let tIdx = jobs[jIdx].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        // Never resurrect a track the user stopped.
        guard jobs[jIdx].tracks[tIdx].status != .cancelled else { return }
        if retryable && jobs[jIdx].tracks[tIdx].retryCount < 2 && !jobs[jIdx].isPaused && !jobs[jIdx].isCancelled {
            jobs[jIdx].tracks[tIdx].retryCount += 1
            jobs[jIdx].tracks[tIdx].status = .pending
            // Keep the first error around so the report can show it if the retry fails differently.
            jobs[jIdx].tracks[tIdx].errorMessage = error
            jobs[jIdx].tracks[tIdx].failureReason = reason ?? PlaylistImportFailureReason.classify(error)
            jobs[jIdx].tracks[tIdx].failureStage = stage
            scheduleDebouncedSave()
            return
        }
        let prev = jobs[jIdx].tracks[tIdx].status
        if prev != .failed {
            jobs[jIdx].failedCount += 1
        }
        jobs[jIdx].tracks[tIdx].status = .failed
        jobs[jIdx].tracks[tIdx].errorMessage = error
        jobs[jIdx].tracks[tIdx].failureReason = reason ?? PlaylistImportFailureReason.classify(error)
        jobs[jIdx].tracks[tIdx].failureStage = stage
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
        let ua = headers["User-Agent"] ?? ""
        let isNativeYouTubeClient = ua.hasPrefix("com.google.")
        if isNativeYouTubeClient {
            headers.removeValue(forKey: "Cookie")
            headers.removeValue(forKey: "Referer")
            headers.removeValue(forKey: "Origin")
        } else if let cookiesHeader, !cookiesHeader.isEmpty, headers["Cookie"] == nil {
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
            guard let meta = decodeMetadata(from: downloadTask) else { return }
            let fraction: Double? = totalBytesExpectedToWrite > 0
                ? min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
                : nil
            Task { @MainActor [weak self] in
                self?.manager?.recordDownloadProgress(trackID: meta.trackID, fraction: fraction)
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
                        message: "Couldn't move downloaded file: \(error.localizedDescription)",
                        reason: .saveFailed
                    )
                }
                return
            }

            let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode
            let taskID = downloadTask.taskIdentifier
            Task { @MainActor [weak self] in
                await self?.manager?.handleBackgroundDownloadFinished(
                    stagedFileURL: stagedURL,
                    metadata: meta,
                    httpStatusCode: httpStatus,
                    taskIdentifier: taskID
                )
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let meta = decodeMetadata(from: task) else { return }
            let taskID = task.taskIdentifier
            Task { @MainActor [weak self] in
                self?.manager?.handleBackgroundTaskError(metadata: meta, error: error, taskIdentifier: taskID)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor [weak self] in
                self?.manager?.handleBackgroundSessionFinishedAllEvents()
            }
        }
    }
}
