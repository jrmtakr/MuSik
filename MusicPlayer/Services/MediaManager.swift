import AVFoundation
import KSPlayer
import MediaPlayer
import Observation
import SwiftUI
import UIKit

@Observable
final class MediaManager {
    static let shared = MediaManager()

    static let supportedExtensions: Set<String> = MediaItem.allSupportedExtensions

    struct CustomTrackMetadata: Codable, Hashable {
        var title: String?
        var artist: String?
        var coverFileName: String?
        var sourceVideoID: String?
        var isArtistVerified: Bool?
        var verifiedArtist: String?
        var genre: String?
        var album: String?
        /// Set when the song-ID AI filled in the metadata, e.g. "Shazam" or "iTunes match".
        var autoIdentifiedSource: String?
        var isrc: String?
    }

    private struct LibraryPersistedState: Codable {
        var likedPaths: [String] = []
        var recentPaths: [String] = []
        var upNextPaths: [String] = []
        var manualQueuePaths: [String]? = nil
        var customMetadataByPath: [String: CustomTrackMetadata] = [:]
        var lastPlaylistID: UUID?
        var repeatMode: RepeatMode = .off
    }

    var items: [MediaItem] = []
    var otherFiles: [LocalFile] = []
    var folders: [LocalFolder] = []
    var playlists: [Playlist] = []
    var activePlaylistID: UUID?
    var lastPlaylistID: UUID?

    var likedPaths: Set<String> = []
    var recentPaths: [String] = []
    var upNextPaths: [String] = []
    var manualQueuePaths: [String] = []
    var customMetadataByPath: [String: CustomTrackMetadata] = [:]
    @ObservationIgnored private var didUserClearQueueThisSession = false

    var currentItem: MediaItem?
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var repeatMode: RepeatMode = .off
    var isShuffleEnabled = false {
        // Turning shuffle on (or tapping "Shuffle Play" again) starts a brand-new no-repeat cycle.
        didSet { if isShuffleEnabled || isShuffleEnabled != oldValue { shuffleBag.reset() } }
    }
    @ObservationIgnored private var shuffleBag = ShuffleBag()

    private var shuffleContextKey: String {
        activePlaylistID?.uuidString ?? "library"
    }

    /// Next song from the no-repeat shuffle bag. `consume: false` only peeks.
    private func nextShuffledItem(from queue: [MediaItem], consume: Bool) -> MediaItem? {
        let path = shuffleBag.next(
            queue: queue.map(\.relativePath),
            current: currentItem?.relativePath,
            contextKey: shuffleContextKey,
            consume: consume
        )
        guard let path else { return nil }
        return queue.first(where: { $0.relativePath == path })
    }

    var convertingItemID: UUID?
    var conversionProgress: Double = 0
    var statusMessage: String?
    var errorMessage: String?
    var newPlaylistTargetItem: MediaItem?
    var thumbnails: [String: UIImage] = [:]
    var playlistCovers: [UUID: UIImage] = [:]

    let equalizerPlayer = EqualizerAudioPlayer()
    private(set) var player: AVPlayer?
    private(set) var ffmpegPlayer: KSMEPlayer?
    private(set) var isUsingFFmpegBackend = false
    private var isUsingEqualizerBackend = false
    @ObservationIgnored private var crossfadeTriggeredForCurrentTrack = false

    @ObservationIgnored var externalQueueNextHandler: (() -> Bool)?
    @ObservationIgnored var externalQueuePreviousHandler: (() -> Bool)?
    @ObservationIgnored private let docsURL = MediaItem.documentsDirectory
    private var timeObserverToken: Any?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var ffmpegTimeTimer: Timer?
    private var ksBridge: KSMEPlayerBridge?
    private var isScrubbing = false
    private(set) var remoteStreamSourceURL: URL?

    private var existingIDsByPath: [String: UUID] = [:]
    private var existingOtherIDsByPath: [String: UUID] = [:]
    private var existingFolderIDsByPath: [String: UUID] = [:]
    private var durationsByPath: [String: Double] = [:]
    private var titlesByPath: [String: String] = [:]
    private var artistsByPath: [String: String] = [:]
    private var metadataLoadedPaths: Set<String> = []
    private var metadataLoadTask: Task<Void, Never>?
    @ObservationIgnored private var spotlightIndexTask: Task<Void, Never>?

    init() {
        KSOptions.canBackgroundPlay = true
        KSOptions.secondPlayerType = KSMEPlayer.self
        setupAudioSession()
        setupAudioNotifications()
        setupRemoteCommands()
        setupEqualizerCallbacks()
        loadPlaylists()
        loadPlaylistCovers()
        loadLibraryState()
        loadLocalFiles()
        populateLaunchRandomizedQueue()
        PlaylistTimeMachineService.shared.ensureBaselinesIfNeeded(
            for: playlists,
            items: items,
            metadataByPath: customMetadataByPath
        )
    }

    deinit {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        metadataLoadTask?.cancel()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session error: \(error.localizedDescription)"
        }
    }

    private func setupAudioNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                self.pause()
            case .ended:
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    self.resume()
                }
            @unknown default:
                break
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            if reason == .oldDeviceUnavailable {
                self.pause()
            }
        }
    }

    // MARK: - Scanning & Importing

    func loadLocalFiles() {
        drainInboxIfNeeded()

        var loadedItems: [MediaItem] = []
        var loadedOthers: [LocalFile] = []
        var loadedFolders: [LocalFolder] = []

        _ = scanDirectory(
            at: docsURL,
            relativePrefix: "",
            loadedItems: &loadedItems,
            loadedOthers: &loadedOthers,
            loadedFolders: &loadedFolders
        )

        loadedItems.sort { $0.dateAdded > $1.dateAdded }
        loadedOthers.sort { $0.dateAdded > $1.dateAdded }
        loadedFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let previousPathSet = Set(items.map(\.relativePath))
        items = loadedItems
        otherFiles = loadedOthers
        folders = loadedFolders

        if !previousPathSet.isEmpty, !didUserClearQueueThisSession {
            let existingQueueSet = Set(upNextPaths)
            let newlyAdded = loadedItems
                .filter { !previousPathSet.contains($0.relativePath) && !existingQueueSet.contains($0.relativePath) && currentItem?.relativePath != $0.relativePath }
                .map(\.relativePath)
            if !newlyAdded.isEmpty {
                upNextPaths.append(contentsOf: newlyAdded.shuffled())
            }
        }

        if let currentItem, !currentItem.relativePath.hasPrefix("__remote__/") {
            if let refreshed = loadedItems.first(where: { $0.relativePath == currentItem.relativePath }) {
                self.currentItem = refreshed
            } else {
                stop()
            }
        }

        metadataLoadTask?.cancel()
        metadataLoadTask = Task {
            await loadMetadataAndThumbnails(for: loadedItems)
            await MainActor.run {
                self.scheduleSpotlightReindex()
            }
        }
        scheduleSpotlightReindex()
    }

    private func scheduleSpotlightReindex() {
        spotlightIndexTask?.cancel()
        spotlightIndexTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            SpotlightIndexer.reindex(
                items: self.items,
                playlists: self.playlists,
                otherFiles: self.otherFiles,
                thumbnails: self.thumbnails,
                customMetadata: self.customMetadataByPath
            )
        }
    }

    private func drainInboxIfNeeded() {
        let inboxURL = docsURL.appendingPathComponent("Inbox", isDirectory: true)
        guard FileManager.default.fileExists(atPath: inboxURL.path),
              let contents = try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            let dest = uniqueDestinationURL(for: url.lastPathComponent, inFolder: "")
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    @discardableResult
    private func scanDirectory(
        at directoryURL: URL,
        relativePrefix: String,
        loadedItems: inout [MediaItem],
        loadedOthers: inout [LocalFile],
        loadedFolders: inout [LocalFolder]
    ) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var directCount = 0

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory == true
            let fileName = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let relPath = relativePrefix.isEmpty ? fileName : "\(relativePrefix)/\(fileName)"
            let dateAdded = values?.contentModificationDate ?? values?.creationDate ?? .now

            if isDir {
                if relativePrefix.isEmpty && fileName == "Inbox" {
                    continue
                }
                if ext == "movpkg" {
                    directCount += 1
                    let id = existingIDsByPath[relPath] ?? UUID()
                    existingIDsByPath[relPath] = id
                    let size = Self.diskSize(at: url)
                    let custom = customMetadataByPath[relPath]
                    loadedItems.append(
                        MediaItem(
                            id: id,
                            name: url.deletingPathExtension().lastPathComponent,
                            fileName: fileName,
                            relativePath: relPath,
                            fileSize: size,
                            dateAdded: dateAdded,
                            durationSeconds: durationsByPath[relPath],
                            metadataTitle: custom?.title ?? titlesByPath[relPath],
                            artist: custom?.artist ?? artistsByPath[relPath]
                        )
                    )
                } else {
                    directCount += 1
                    let subCount = scanDirectory(
                        at: url,
                        relativePrefix: relPath,
                        loadedItems: &loadedItems,
                        loadedOthers: &loadedOthers,
                        loadedFolders: &loadedFolders
                    )
                    let folderID = existingFolderIDsByPath[relPath] ?? UUID()
                    existingFolderIDsByPath[relPath] = folderID
                    loadedFolders.append(
                        LocalFolder(
                            id: folderID,
                            name: fileName,
                            relativePath: relPath,
                            itemCount: subCount,
                            dateModified: dateAdded
                        )
                    )
                }
                continue
            }

            directCount += 1
            let fileSize = Int64(values?.fileSize ?? 0)
            let displayName = url.deletingPathExtension().lastPathComponent

            if Self.supportedExtensions.contains(ext) {
                let id = existingIDsByPath[relPath] ?? UUID()
                existingIDsByPath[relPath] = id
                let custom = customMetadataByPath[relPath]
                loadedItems.append(
                    MediaItem(
                        id: id,
                        name: displayName,
                        fileName: fileName,
                        relativePath: relPath,
                        fileSize: fileSize,
                        dateAdded: dateAdded,
                        durationSeconds: durationsByPath[relPath],
                        metadataTitle: custom?.title ?? titlesByPath[relPath],
                        artist: custom?.artist ?? artistsByPath[relPath]
                    )
                )
            } else {
                let id = existingOtherIDsByPath[relPath] ?? UUID()
                existingOtherIDsByPath[relPath] = id
                loadedOthers.append(
                    LocalFile(
                        id: id,
                        name: displayName,
                        fileName: fileName,
                        relativePath: relPath,
                        fileSize: fileSize,
                        dateAdded: dateAdded
                    )
                )
            }
        }

        return directCount
    }

    enum ImportedOutcome {
        case media(MediaItem)
        case document(LocalFile)
        case folder(name: String, fileCount: Int)
    }

    func fileExists(named fileName: String, inFolder folderPath: String = "") -> Bool {
        let targetURL = folderURL(for: folderPath).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: targetURL.path)
    }

    @discardableResult
    func importAnyFile(
        from sourceURL: URL,
        inFolder folderPath: String = "",
        conflictAction: DuplicateConflictAction = .keepBoth
    ) -> ImportedOutcome? {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let targetDir = folderURL(for: folderPath)
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = (resourceValues?.isDirectory == true) && sourceURL.pathExtension.lowercased() != "movpkg"

        if sourceURL.standardizedFileURL.deletingLastPathComponent() == targetDir.standardizedFileURL {
            loadLocalFiles()
            if isDirectory {
                return nil
            }
            let rel = folderPath.isEmpty ? sourceURL.lastPathComponent : "\(folderPath)/\(sourceURL.lastPathComponent)"
            return outcomeForRelativePath(rel)
        }

        let destURL: URL
        if conflictAction == .overwrite {
            destURL = targetDir.appendingPathComponent(sourceURL.lastPathComponent)
        } else {
            destURL = uniqueDestinationURL(for: sourceURL.lastPathComponent, inFolder: folderPath)
        }

        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            if isDirectory {
                let sourceBase = sourceURL.resolvingSymlinksInPath().standardizedFileURL
                let destBase = destURL.resolvingSymlinksInPath().standardizedFileURL
                guard destBase != sourceBase,
                      !destBase.path.hasPrefix(sourceBase.path + "/") else {
                    errorMessage = "Cannot import a folder into itself."
                    return nil
                }

                let relFolder = folderPath.isEmpty ? destURL.lastPathComponent : "\(folderPath)/\(destURL.lastPathComponent)"
                if conflictAction == .overwrite, FileManager.default.fileExists(atPath: destURL.path) {
                    clearCachedMetadata(underRelativePrefix: relFolder)
                    try FileManager.default.removeItem(at: destURL)
                }

                let copiedCount = try copyDirectoryContents(from: sourceURL, to: destURL)
                loadLocalFiles()
                statusMessage = "Saved folder \"\(destURL.lastPathComponent)\" (\(copiedCount) \(copiedCount == 1 ? "file" : "files"))"
                return .folder(name: destURL.lastPathComponent, fileCount: copiedCount)
            }

            if conflictAction == .overwrite, FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            let rel = folderPath.isEmpty ? destURL.lastPathComponent : "\(folderPath)/\(destURL.lastPathComponent)"
            if conflictAction == .overwrite {
                durationsByPath.removeValue(forKey: rel)
                metadataLoadedPaths.remove(rel)
                thumbnails.removeValue(forKey: rel)
            }
            loadLocalFiles()
            statusMessage = "Saved \(destURL.lastPathComponent)"
            return outcomeForRelativePath(rel)
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func clearCachedMetadata(underRelativePrefix relativePrefix: String) {
        let prefixWithSlash = relativePrefix + "/"
        for key in Array(durationsByPath.keys) where key == relativePrefix || key.hasPrefix(prefixWithSlash) {
            durationsByPath.removeValue(forKey: key)
        }
        for key in metadataLoadedPaths where key == relativePrefix || key.hasPrefix(prefixWithSlash) {
            metadataLoadedPaths.remove(key)
        }
        for key in Array(thumbnails.keys) where key == relativePrefix || key.hasPrefix(prefixWithSlash) {
            thumbnails.removeValue(forKey: key)
        }
    }

    private func copyDirectoryContents(from sourceFolderURL: URL, to destFolderURL: URL) throws -> Int {
        try FileManager.default.createDirectory(at: destFolderURL, withIntermediateDirectories: true)

        let baseComponents = sourceFolderURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let enumerator = FileManager.default.enumerator(
            at: sourceFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var copiedCount = 0
        while let childURL = enumerator.nextObject() as? URL {
            if childURL.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }

            let childComponents = childURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard childComponents.count > baseComponents.count,
                  Array(childComponents.prefix(baseComponents.count)) == baseComponents else {
                continue
            }

            let relComponents = childComponents.dropFirst(baseComponents.count)
            let targetChildURL = relComponents.reduce(destFolderURL) { $0.appendingPathComponent($1) }
            let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey])
            let isChildDir = values?.isDirectory == true

            if isChildDir && childURL.pathExtension.lowercased() != "movpkg" {
                try FileManager.default.createDirectory(at: targetChildURL, withIntermediateDirectories: true)
            } else {
                let childDidAccess = childURL.startAccessingSecurityScopedResource()
                defer {
                    if childDidAccess {
                        childURL.stopAccessingSecurityScopedResource()
                    }
                }
                try FileManager.default.createDirectory(
                    at: targetChildURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: targetChildURL.path) {
                    try FileManager.default.removeItem(at: targetChildURL)
                }
                try FileManager.default.copyItem(at: childURL, to: targetChildURL)
                copiedCount += 1
                if childURL.pathExtension.lowercased() == "movpkg" {
                    enumerator.skipDescendants()
                }
            }
        }

        return copiedCount
    }

    @discardableResult
    func importFile(from sourceURL: URL, inFolder folderPath: String = "") -> MediaItem? {
        if case .media(let item) = importAnyFile(from: sourceURL, inFolder: folderPath) {
            return item
        }
        return nil
    }

    @discardableResult
    func importTemporaryFile(
        from tempURL: URL,
        preferredFileName: String? = nil,
        inFolder folderPath: String = "",
        conflictAction: DuplicateConflictAction = .keepBoth
    ) -> MediaItem? {
        let targetName = preferredFileName ?? tempURL.lastPathComponent
        let targetDir = folderURL(for: folderPath)
        let destURL = conflictAction == .overwrite
            ? targetDir.appendingPathComponent(targetName)
            : uniqueDestinationURL(for: targetName, inFolder: folderPath)

        do {
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if conflictAction == .overwrite, FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            let rel = folderPath.isEmpty ? destURL.lastPathComponent : "\(folderPath)/\(destURL.lastPathComponent)"
            if conflictAction == .overwrite {
                durationsByPath.removeValue(forKey: rel)
                metadataLoadedPaths.remove(rel)
                thumbnails.removeValue(forKey: rel)
            }
            loadLocalFiles()
            statusMessage = "Saved \(destURL.lastPathComponent)"
            return items.first(where: { $0.relativePath == rel })
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            errorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func outcomeForRelativePath(_ relativePath: String) -> ImportedOutcome? {
        if let media = items.first(where: { $0.relativePath == relativePath }) {
            return .media(media)
        }
        if let doc = otherFiles.first(where: { $0.relativePath == relativePath }) {
            return .document(doc)
        }
        return nil
    }

    // MARK: - Playback, Repeat, Favorites, Recents, & Up Next

    private func activatePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    func play(_ item: MediaItem, inPlaylist playlistID: UUID? = nil, keepExternalQueue: Bool = false) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            errorMessage = "File not found: \(item.fileName)"
            loadLocalFiles()
            return
        }

        if !keepExternalQueue {
            externalQueueNextHandler = nil
            externalQueuePreviousHandler = nil
        }

        stopCurrentEngines()
        crossfadeTriggeredForCurrentTrack = false
        remoteStreamSourceURL = nil
        activePlaylistID = playlistID
        if let playlistID {
            lastPlaylistID = playlistID
        }
        recordRecent(item.relativePath)
        activatePlaybackAudioSession()

        if item.prefersFFmpegEngine {
            playWithFFmpegEngine(url: item.fileURL, item: item, headers: nil)
            return
        }

        if !item.isVideo {
            do {
                equalizerPlayer.setPlaybackRate(playbackRate)
                try equalizerPlayer.play(url: item.fileURL)
                isUsingEqualizerBackend = true
                currentItem = item
                currentTime = 0
                duration = equalizerPlayer.duration > 0 ? equalizerPlayer.duration : (item.durationSeconds ?? 0)
                isPlaying = true
                updateNowPlayingInfo(for: item)
                syncWrappedSessionStart(for: item)
                return
            } catch {
                equalizerPlayer.stop()
                isUsingEqualizerBackend = false
            }
        }

        let playerItem = AVPlayerItem(url: item.fileURL)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.actionAtItemEnd = .pause

        player = newPlayer
        currentItem = item
        currentTime = 0
        duration = item.durationSeconds ?? 0

        attachTimeObserver(to: newPlayer, playerItem: playerItem)
        attachEndObserver(to: playerItem)
        attachFailureFallbackObserver(to: playerItem, item: item)

        newPlayer.play()
        newPlayer.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo(for: item)
        syncWrappedSessionStart(for: item)
    }

    func playRemoteStream(
        url: URL,
        title: String,
        artist: String? = nil,
        headers: [String: String]? = nil,
        isVideo: Bool,
        keepExternalQueue: Bool = false
    ) {
        if !keepExternalQueue {
            externalQueueNextHandler = nil
            externalQueuePreviousHandler = nil
        }

        stopCurrentEngines()
        activePlaylistID = nil
        remoteStreamSourceURL = url
        activatePlaybackAudioSession()

        let ext = url.pathExtension.lowercased()
        let syntheticExt = MediaItem.allSupportedExtensions.contains(ext) ? ext : (isVideo ? "mp4" : "m4a")
        let virtualItem = MediaItem(
            id: UUID(),
            name: title,
            fileName: "\(title).\(syntheticExt)",
            relativePath: "__remote__/\(url.absoluteString)",
            fileSize: 0,
            dateAdded: .now,
            durationSeconds: nil,
            metadataTitle: title,
            artist: artist ?? url.host
        )

        let isHLS = ext == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
        if isHLS || !MediaItem.ffmpegVideoExtensions.contains(ext) {
            let playURL = isHLS ? url : LocalMediaCacheProxy.proxiedURL(for: url, headers: headers)
            let asset = AVURLAsset(
                url: playURL,
                options: headers.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] }
            )
            let playerItem = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.actionAtItemEnd = .pause

            player = newPlayer
            currentItem = virtualItem
            currentTime = 0
            duration = 0

            attachTimeObserver(to: newPlayer, playerItem: playerItem)
            attachEndObserver(to: playerItem)
            playerItemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] itemObj, _ in
                if itemObj.status == .failed {
                    DispatchQueue.main.async {
                        self?.playWithFFmpegEngine(url: url, item: virtualItem, headers: headers)
                    }
                }
            }

            newPlayer.play()
            newPlayer.rate = playbackRate
            isPlaying = true
            updateNowPlayingInfo(for: virtualItem)
            syncWrappedSessionStart(for: virtualItem)
        } else {
            playWithFFmpegEngine(url: url, item: virtualItem, headers: headers)
        }
    }

    private func playWithFFmpegEngine(url: URL, item: MediaItem, headers: [String: String]?) {
        cleanupObservers()
        player?.pause()
        player = nil
        equalizerPlayer.stop()
        isUsingEqualizerBackend = false

        let options = KSOptions()
        options.registerRemoteControll = false
        options.isLoopPlay = false
        options.userAgent = WebMediaDownloader.browserUserAgent
        if let headers, !headers.isEmpty {
            options.appendHeader(headers)
        }
        options.videoDisable = !item.isVideo

        let bridge = KSMEPlayerBridge(manager: self)
        let ksPlayer = KSMEPlayer(url: url, options: options)
        ksPlayer.delegate = bridge
        ksPlayer.playbackRate = playbackRate

        self.ksBridge = bridge
        self.ffmpegPlayer = ksPlayer
        self.isUsingFFmpegBackend = true
        self.currentItem = item
        self.currentTime = 0
        self.duration = item.durationSeconds ?? 0
        self.isPlaying = true

        ksPlayer.prepareToPlay()
        startFFmpegTimer()
        updateNowPlayingInfo(for: item)
    }

    private func stopCurrentEngines() {
        cleanupObservers()
        ffmpegTimeTimer?.invalidate()
        ffmpegTimeTimer = nil
        ffmpegPlayer?.shutdown()
        ffmpegPlayer = nil
        ksBridge = nil
        isUsingFFmpegBackend = false

        player?.pause()
        player = nil
        equalizerPlayer.stop()
        isUsingEqualizerBackend = false
    }

    private func attachFailureFallbackObserver(to playerItem: AVPlayerItem, item: MediaItem) {
        playerItemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] itemObj, _ in
            if itemObj.status == .failed {
                DispatchQueue.main.async {
                    guard let self, self.currentItem?.relativePath == item.relativePath else { return }
                    self.playWithFFmpegEngine(url: item.fileURL, item: item, headers: nil)
                }
            }
        }
    }

    private func startFFmpegTimer() {
        ffmpegTimeTimer?.invalidate()
        ffmpegTimeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isUsingFFmpegBackend, let ks = self.ffmpegPlayer else { return }
            if !self.isScrubbing {
                let elapsed = ks.currentPlaybackTime
                if elapsed.isFinite && elapsed >= 0 {
                    self.currentTime = elapsed
                }
            }
            let dur = ks.duration
            if dur.isFinite, dur > 0, abs(self.duration - dur) > 0.2 {
                self.duration = dur
                if let path = self.currentItem?.relativePath, !path.hasPrefix("__remote__/") {
                    self.durationsByPath[path] = dur
                }
                if let currentItem = self.currentItem {
                    self.updateNowPlayingInfo(for: currentItem)
                }
            }
            self.syncWrappedHeartbeat()
        }
    }

    fileprivate func handleFFmpegReady(player: any MediaPlayerProtocol) {
        guard isUsingFFmpegBackend else { return }
        if player.duration.isFinite, player.duration > 0 {
            duration = player.duration
            if let path = currentItem?.relativePath, !path.hasPrefix("__remote__/") {
                durationsByPath[path] = player.duration
            }
        }
        if #available(iOS 14.2, *) {
            player.pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        player.playbackRate = playbackRate
        player.play()
        isPlaying = true
        if let currentItem {
            updateNowPlayingInfo(for: currentItem)
            syncWrappedSessionStart(for: currentItem)
        }
    }

    @MainActor
    func saveCurrentRemoteStreamOffline(using downloader: WebMediaDownloader) {
        guard let sourceURL = remoteStreamSourceURL else { return }
        let title = currentItem?.displayTitle ?? "Stream Media"
        if let cachedBin = LocalMediaCacheProxy.cachedDataURL(for: sourceURL) {
            let tempCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)_\(currentItem?.fileName ?? "stream.mp4")")
            if (try? FileManager.default.copyItem(at: cachedBin, to: tempCopy)) != nil {
                _ = importTemporaryFile(from: tempCopy, preferredFileName: currentItem?.fileName)
                return
            }
        }
        downloader.downloadDirectMedia(from: sourceURL, title: title)
    }

    fileprivate func handleFFmpegFinish(error: Error?) {
        guard isUsingFFmpegBackend else { return }
        if let error {
            isPlaying = false
            ListeningWrappedService.shared.pauseSession()
            errorMessage = "Playback error: \(error.localizedDescription)"
            return
        }
        handlePlaybackEnded()
    }

    func togglePlayPause() {
        AppHaptics.light()
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard let currentItem else { return }
        activatePlaybackAudioSession()

        if isUsingFFmpegBackend, let ks = ffmpegPlayer {
            ks.playbackRate = playbackRate
            ks.play()
            isPlaying = true
            updateNowPlayingInfo(for: currentItem)
            syncWrappedSessionStart(for: currentItem)
            return
        }

        if isUsingEqualizerBackend {
            equalizerPlayer.resume()
            isPlaying = equalizerPlayer.isPlaying
            updateNowPlayingInfo(for: currentItem)
            if isPlaying {
                syncWrappedSessionStart(for: currentItem)
            }
            return
        }

        guard let player else { return }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo(for: currentItem)
        syncWrappedSessionStart(for: currentItem)
    }

    func pause() {
        ListeningWrappedService.shared.pauseSession()
        if isUsingFFmpegBackend, let ks = ffmpegPlayer {
            ks.pause()
            currentTime = ks.currentPlaybackTime
            isPlaying = false
            if let currentItem {
                updateNowPlayingInfo(for: currentItem)
            }
            return
        }

        if isUsingEqualizerBackend {
            equalizerPlayer.pause()
            currentTime = equalizerPlayer.currentTime
            isPlaying = false
            if let currentItem {
                updateNowPlayingInfo(for: currentItem)
            }
            return
        }

        guard let player else { return }
        player.pause()
        isPlaying = false
        if let currentItem {
            updateNowPlayingInfo(for: currentItem)
        }
    }

    func stop() {
        ListeningWrappedService.shared.endSession(didFinishTrack: false)
        stopCurrentEngines()
        crossfadeTriggeredForCurrentTrack = false
        remoteStreamSourceURL = nil
        activePlaylistID = nil
        currentItem = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        NowPlayingManager.clear()
    }

    func beginScrubbing() {
        isScrubbing = true
    }

    func endScrubbing(at seconds: Double) {
        isScrubbing = false
        seek(to: seconds)
    }

    func seek(to seconds: Double) {
        crossfadeTriggeredForCurrentTrack = false
        let upperBound = max(duration, 0)
        let clamped = min(max(seconds, 0), upperBound > 0 ? upperBound : max(seconds, 0))

        if isUsingFFmpegBackend, let ks = ffmpegPlayer {
            let wasPlaying = isPlaying
            currentTime = clamped
            ks.seek(time: clamped) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if wasPlaying {
                        ks.play()
                    }
                    if let currentItem = self.currentItem {
                        self.updateNowPlayingInfo(for: currentItem)
                    }
                }
            }
            return
        }

        if isUsingEqualizerBackend {
            equalizerPlayer.seek(to: clamped)
            currentTime = equalizerPlayer.currentTime
            if let currentItem {
                updateNowPlayingInfo(for: currentItem)
            }
            return
        }

        guard let player else { return }
        currentTime = clamped
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let item = self.currentItem else { return }
                self.updateNowPlayingInfo(for: item)
            }
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isUsingFFmpegBackend {
            ffmpegPlayer?.playbackRate = rate
        } else if isUsingEqualizerBackend {
            equalizerPlayer.setPlaybackRate(rate)
        } else if isPlaying {
            player?.rate = rate
        }
        if let currentItem {
            updateNowPlayingInfo(for: currentItem)
        }
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        saveLibraryState()
        statusMessage = repeatMode.label
    }

    var activeQueue: [MediaItem] {
        if let activePlaylistID,
           let playlist = playlists.first(where: { $0.id == activePlaylistID }) {
            let playlistItems = items(in: playlist)
            if !playlistItems.isEmpty {
                return playlistItems
            }
        }
        return items
    }

    var upNextItems: [MediaItem] {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return upNextPaths.compactMap { byPath[$0] }
    }

    var favoriteItems: [MediaItem] {
        items.filter { likedPaths.contains($0.relativePath) }
    }

    var videoItems: [MediaItem] {
        items.filter { $0.isVideo }
    }

    var audioItems: [MediaItem] {
        items.filter { !$0.isVideo }
    }

    var recentItems: [MediaItem] {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return recentPaths.compactMap { byPath[$0] }
    }

    var lastPlaylist: Playlist? {
        guard let lastPlaylistID else { return nil }
        return playlists.first(where: { $0.id == lastPlaylistID })
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        likedPaths.contains(item.relativePath)
    }

    func toggleFavorite(_ item: MediaItem) {
        AppHaptics.selection()
        if likedPaths.contains(item.relativePath) {
            likedPaths.remove(item.relativePath)
            statusMessage = "Removed from Favorites"
        } else {
            likedPaths.insert(item.relativePath)
            statusMessage = "Added to Favorites"
        }
        saveLibraryState()
        if currentItem?.relativePath == item.relativePath {
            updateNowPlayingInfo(for: item)
        }
    }

    var upcomingContextTitle: String {
        if let activePlaylistID,
           let playlist = playlists.first(where: { $0.id == activePlaylistID }) {
            return playlist.name
        }
        return "Library"
    }

    var continuePlayingItems: [MediaItem] {
        let queue = activeQueue
        guard !queue.isEmpty else { return [] }
        if isShuffleEnabled {
            let order = shuffleBag.upcomingPreview(
                queue: queue.map(\.relativePath),
                current: currentItem?.relativePath,
                contextKey: shuffleContextKey
            )
            let byPath = Dictionary(queue.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
            return order.compactMap { byPath[$0] }
        }
        guard let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            return queue
        }
        let nextIndex = index + 1
        guard nextIndex < queue.count else {
            return repeatMode == .all ? Array(queue[..<index]) : []
        }
        return Array(queue[nextIndex...])
    }

    /// Builds a freshly randomized launch queue containing all cached audios & videos,
    /// keeping any manually pinned queue items at the very front.
    func populateLaunchRandomizedQueue() {
        let validSet = Set(items.map(\.relativePath))
        guard !validSet.isEmpty else {
            upNextPaths = []
            manualQueuePaths = []
            return
        }
        let pinned = manualQueuePaths.filter { validSet.contains($0) && $0 != currentItem?.relativePath }
        let pinnedSet = Set(pinned)
        let remainingShuffled = items
            .map(\.relativePath)
            .filter { !pinnedSet.contains($0) && $0 != currentItem?.relativePath }
            .shuffled()
        manualQueuePaths = pinned
        upNextPaths = pinned + remainingShuffled
        saveLibraryState()
    }

    func reshuffleQueueWithAllCachedMedia() {
        let currentRel = currentItem?.relativePath
        let pool = items.map(\.relativePath).filter { $0 != currentRel }.shuffled()
        manualQueuePaths = []
        didUserClearQueueThisSession = false
        upNextPaths = pool
        saveLibraryState()
        statusMessage = "Randomized queue (\(pool.count) items)"
    }

    func addToNextPlay(_ item: MediaItem) {
        didUserClearQueueThisSession = false
        upNextPaths.removeAll { $0 == item.relativePath }
        upNextPaths.insert(item.relativePath, at: 0)
        manualQueuePaths.removeAll { $0 == item.relativePath }
        manualQueuePaths.insert(item.relativePath, at: 0)
        saveLibraryState()
        statusMessage = "Playing Next: \(item.displayTitle)"
    }

    func addToQueue(_ item: MediaItem) {
        didUserClearQueueThisSession = false
        upNextPaths.removeAll { $0 == item.relativePath }
        let insertAt = manualQueuePaths.count
        let safeIdx = min(insertAt, upNextPaths.count)
        upNextPaths.insert(item.relativePath, at: safeIdx)
        manualQueuePaths.removeAll { $0 == item.relativePath }
        manualQueuePaths.append(item.relativePath)
        saveLibraryState()
        statusMessage = "Added to Queue: \(item.displayTitle)"
    }

    func addMultipleToQueue(_ newItems: [MediaItem], playNext: Bool = false) {
        let paths = newItems.map(\.relativePath).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        didUserClearQueueThisSession = false
        let set = Set(paths)
        if playNext {
            upNextPaths.removeAll { set.contains($0) }
            upNextPaths.insert(contentsOf: paths, at: 0)
            manualQueuePaths.removeAll { set.contains($0) }
            manualQueuePaths.insert(contentsOf: paths, at: 0)
            statusMessage = "Added \(paths.count) \(paths.count == 1 ? "song" : "songs") to Play Next"
        } else {
            upNextPaths.removeAll { set.contains($0) }
            let safeIdx = min(manualQueuePaths.count, upNextPaths.count)
            upNextPaths.insert(contentsOf: paths, at: safeIdx)
            manualQueuePaths.removeAll { set.contains($0) }
            manualQueuePaths.append(contentsOf: paths)
            statusMessage = "Added \(paths.count) \(paths.count == 1 ? "song" : "songs") to Queue"
        }
        saveLibraryState()
    }

    func playQueuedItem(at queueIndex: Int) {
        let currentUpNext = upNextItems
        guard currentUpNext.indices.contains(queueIndex) else { return }
        let selected = currentUpNext[queueIndex]
        let remainingPaths = Array(currentUpNext.dropFirst(queueIndex + 1)).map(\.relativePath)
        upNextPaths = remainingPaths
        let remainingSet = Set(remainingPaths)
        manualQueuePaths.removeAll { $0 == selected.relativePath || !remainingSet.contains($0) }
        saveLibraryState()
        play(selected, inPlaylist: activePlaylistID)
    }

    func moveQueuedItemToTop(at queueIndex: Int) {
        guard upNextPaths.indices.contains(queueIndex), queueIndex > 0 else { return }
        let path = upNextPaths.remove(at: queueIndex)
        upNextPaths.insert(path, at: 0)
        manualQueuePaths.removeAll { $0 == path }
        manualQueuePaths.insert(path, at: 0)
        saveLibraryState()
    }

    func removeFromUpNext(at offsets: IndexSet) {
        for idx in offsets.sorted(by: >) where upNextPaths.indices.contains(idx) {
            let removed = upNextPaths.remove(at: idx)
            manualQueuePaths.removeAll { $0 == removed }
        }
        saveLibraryState()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNextPaths.move(fromOffsets: source, toOffset: destination)
        saveLibraryState()
    }

    func clearUpNext() {
        didUserClearQueueThisSession = true
        upNextPaths.removeAll()
        manualQueuePaths.removeAll()
        saveLibraryState()
    }

    private func popNextQueuedItem() -> MediaItem? {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        while !upNextPaths.isEmpty {
            let nextPath = upNextPaths.removeFirst()
            manualQueuePaths.removeAll { $0 == nextPath }
            if let match = byPath[nextPath] {
                saveLibraryState()
                return match
            }
        }
        saveLibraryState()
        return nil
    }

    func playNext(fromQueueOnly: Bool = false) {
        AppHaptics.light()
        if let queued = popNextQueuedItem() {
            play(queued, inPlaylist: activePlaylistID)
            return
        }

        if let nextHandler = externalQueueNextHandler, nextHandler() {
            return
        }

        let queue = activeQueue
        guard !queue.isEmpty else { return }

        if isShuffleEnabled, queue.count > 1 {
            // No-repeat shuffle: every song plays once before any song repeats.
            if let shuffledNext = nextShuffledItem(from: queue, consume: true) {
                play(shuffledNext, inPlaylist: activePlaylistID)
            }
            return
        }

        guard let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            if let first = queue.first { play(first, inPlaylist: activePlaylistID) }
            return
        }

        let nextIndex = index + 1
        if nextIndex < queue.count {
            play(queue[nextIndex], inPlaylist: activePlaylistID)
        } else if !fromQueueOnly, let first = queue.first {
            play(first, inPlaylist: activePlaylistID)
        } else {
            pause()
            seek(to: 0)
        }
    }

    func playPrevious() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if let prevHandler = externalQueuePreviousHandler, prevHandler() {
            return
        }

        let queue = activeQueue
        guard !queue.isEmpty else { return }

        if isShuffleEnabled, queue.count > 1 {
            // Go back to what actually played before, not the neighbour in playlist order.
            if let previousPath = shuffleBag.previous(
                queue: queue.map(\.relativePath),
                current: currentItem?.relativePath,
                contextKey: shuffleContextKey
            ), let previousItem = queue.first(where: { $0.relativePath == previousPath }) {
                play(previousItem, inPlaylist: activePlaylistID)
            } else {
                seek(to: 0)
            }
            return
        }

        guard let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            if let first = queue.first { play(first, inPlaylist: activePlaylistID) }
            return
        }

        let previousIndex = (index - 1 + queue.count) % queue.count
        play(queue[previousIndex], inPlaylist: activePlaylistID)
    }

    // MARK: - Track Info & Custom Cover Art

    func updateTrackInfo(
        for item: MediaItem,
        title: String,
        artist: String,
        coverImage: UIImage? = nil,
        removeCustomCover: Bool = false,
        markArtistVerified: Bool = true,
        genre: String? = nil
    ) {
        let previousMeta = resolvedTitleAndRawArtist(for: item)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = customMetadataByPath[item.relativePath] ?? CustomTrackMetadata()
        // A manual edit wins over AI song ID from now on.
        entry.autoIdentifiedSource = nil

        entry.title = cleanTitle.isEmpty ? nil : cleanTitle
        if cleanArtist.isEmpty {
            entry.artist = nil
            entry.verifiedArtist = nil
            entry.isArtistVerified = false
        } else {
            let canonical = ArtistDatabase.canonicalizeSingle(cleanArtist)
            entry.artist = canonical
            if markArtistVerified {
                entry.verifiedArtist = canonical
                entry.isArtistVerified = true
            }
        }
        if let genre, !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry.genre = genre
        }

        if removeCustomCover {
            if let oldCover = entry.coverFileName {
                try? FileManager.default.removeItem(at: coversDirectoryURL.appendingPathComponent(oldCover))
            }
            entry.coverFileName = nil
            thumbnails.removeValue(forKey: item.relativePath)
            metadataLoadedPaths.remove(item.relativePath)
        } else if let coverImage, let jpeg = coverImage.jpegData(compressionQuality: 0.85) {
            if let oldCover = entry.coverFileName {
                try? FileManager.default.removeItem(at: coversDirectoryURL.appendingPathComponent(oldCover))
            }
            let coverName = "\(UUID().uuidString).jpg"
            try? FileManager.default.createDirectory(at: coversDirectoryURL, withIntermediateDirectories: true)
            try? jpeg.write(to: coversDirectoryURL.appendingPathComponent(coverName), options: [.atomic])
            entry.coverFileName = coverName
            thumbnails[item.relativePath] = coverImage
        }

        if entry.title == nil && entry.artist == nil && entry.coverFileName == nil && entry.sourceVideoID == nil {
            customMetadataByPath.removeValue(forKey: item.relativePath)
        } else {
            customMetadataByPath[item.relativePath] = entry
        }

        saveLibraryState()
        loadLocalFiles()

        if let verified = entry.artist, !verified.isEmpty {
            ListeningWrappedService.shared.reattributeTrack(
                relativePath: item.relativePath,
                oldTrackTitle: previousMeta.title,
                newTrackTitle: entry.title ?? previousMeta.title,
                toVerifiedArtist: verified,
                genre: entry.genre
            )
        }

        if currentItem?.relativePath == item.relativePath,
           let updated = items.first(where: { $0.relativePath == item.relativePath }) {
            currentItem = updated
            updateNowPlayingInfo(for: updated)
            if isPlaying {
                syncWrappedSessionStart(for: updated)
            }
        }
        statusMessage = "Updated track info"
    }

    func isArtistVerified(for item: MediaItem) -> Bool {
        let custom = customMetadataByPath[item.relativePath]
        return custom?.isArtistVerified == true && !(custom?.artist?.isEmpty ?? true)
    }

    func confirmVerifiedArtist(
        for item: MediaItem,
        artistName: String,
        updatedTitle: String? = nil,
        genre: String? = nil
    ) {
        let cleanTitle = updatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToKeep = (cleanTitle?.isEmpty == false ? cleanTitle! : (customMetadataByPath[item.relativePath]?.title ?? item.displayTitle))
        updateTrackInfo(
            for: item,
            title: titleToKeep,
            artist: artistName,
            markArtistVerified: true,
            genre: genre
        )
        let canonical = ArtistDatabase.canonicalizeSingle(artistName)
        statusMessage = "Verified \"\(titleToKeep)\" by \(canonical)"
    }

    /// Applies metadata found by `SongIdentificationService` without a full library reload, so it is
    /// cheap enough to run after every imported song. Never overwrites an artist the user verified by hand.
    @discardableResult
    func applyAutoIdentifiedMetadata(
        relativePath: String,
        title: String,
        artist: String,
        album: String?,
        genre: String?,
        isrc: String?,
        coverImage: UIImage?,
        source: String
    ) -> Bool {
        var entry = customMetadataByPath[relativePath] ?? CustomTrackMetadata()
        if entry.isArtistVerified == true && entry.autoIdentifiedSource == nil {
            return false
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = ArtistDatabase.canonicalizeSingle(artist.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanTitle.isEmpty, !cleanArtist.isEmpty else { return false }

        entry.title = cleanTitle
        entry.artist = cleanArtist
        entry.verifiedArtist = cleanArtist
        entry.isArtistVerified = true
        if let album, !album.isEmpty { entry.album = album }
        if let genre, !genre.isEmpty { entry.genre = genre }
        if let isrc, !isrc.isEmpty { entry.isrc = isrc }
        entry.autoIdentifiedSource = source

        if let coverImage, let jpeg = coverImage.jpegData(compressionQuality: 0.85) {
            if let oldCover = entry.coverFileName {
                try? FileManager.default.removeItem(at: coversDirectoryURL.appendingPathComponent(oldCover))
            }
            let coverName = "\(UUID().uuidString).jpg"
            try? FileManager.default.createDirectory(at: coversDirectoryURL, withIntermediateDirectories: true)
            try? jpeg.write(to: coversDirectoryURL.appendingPathComponent(coverName), options: [.atomic])
            entry.coverFileName = coverName
            thumbnails[relativePath] = coverImage
        }
        customMetadataByPath[relativePath] = entry

        if let idx = items.firstIndex(where: { $0.relativePath == relativePath }) {
            items[idx].metadataTitle = cleanTitle
            items[idx].artist = cleanArtist
            if currentItem?.relativePath == relativePath {
                currentItem = items[idx]
                updateNowPlayingInfo(for: items[idx])
            }
        }
        saveLibraryState()
        return true
    }

    func customMetadata(forRelativePath path: String) -> CustomTrackMetadata? {
        customMetadataByPath[path]
    }

    func setSourceVideoID(_ videoID: String?, for item: MediaItem) {
        guard let videoID, !videoID.isEmpty else { return }
        var entry = customMetadataByPath[item.relativePath] ?? CustomTrackMetadata()
        guard entry.sourceVideoID != videoID else { return }
        entry.sourceVideoID = videoID
        customMetadataByPath[item.relativePath] = entry
        saveLibraryState()
    }

    func sourceVideoID(for item: MediaItem) -> String? {
        customMetadataByPath[item.relativePath]?.sourceVideoID
    }

    @discardableResult
    func applyDownloadedMetadataAndPlaylist(
        for item: MediaItem,
        title: String? = nil,
        artist: String? = nil,
        explicitPlaylistID: UUID? = nil,
        appendOrder: Bool = false,
        sourceVideoID: String? = nil
    ) -> MediaItem {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVID = sourceVideoID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleanTitle?.isEmpty == false) || (cleanArtist?.isEmpty == false) || (cleanVID?.isEmpty == false) {
            var entry = customMetadataByPath[item.relativePath] ?? CustomTrackMetadata()
            if let cleanTitle, !cleanTitle.isEmpty { entry.title = cleanTitle }
            if let cleanArtist, !cleanArtist.isEmpty { entry.artist = cleanArtist }
            if let cleanVID, !cleanVID.isEmpty { entry.sourceVideoID = cleanVID }
            customMetadataByPath[item.relativePath] = entry
            saveLibraryState()
            loadLocalFiles()
        }

        let refreshedItem = items.first(where: { $0.relativePath == item.relativePath }) ?? item

        if let explicitPlaylistID,
           let idx = playlists.firstIndex(where: { $0.id == explicitPlaylistID }) {
            if !playlistContains(refreshedItem, in: playlists[idx]) {
                PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
                    for: playlists[idx],
                    items: items,
                    metadataByPath: customMetadataByPath
                )
                if appendOrder {
                    playlists[idx].itemFileNames.append(refreshedItem.relativePath)
                } else {
                    playlists[idx].itemFileNames.insert(refreshedItem.relativePath, at: 0)
                }
                savePlaylists()
                PlaylistTimeMachineService.shared.recordSnapshot(
                    for: playlists[idx],
                    items: items,
                    metadataByPath: customMetadataByPath,
                    trigger: .imported,
                    summary: "Downloaded \"\(refreshedItem.displayTitle)\""
                )
            }
            statusMessage = "Saved to \(playlists[idx].name): \(refreshedItem.displayTitle)"
            return refreshedItem
        }

        recordRecent(refreshedItem.relativePath)

        if AppSettings.isAutoAddDownloadsToPlaylistEnabled,
           let configuredID = AppSettings.storedTargetDownloadPlaylistID,
           let idx = playlists.firstIndex(where: { $0.id == configuredID }) {
            if !playlistContains(refreshedItem, in: playlists[idx]) {
                PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
                    for: playlists[idx],
                    items: items,
                    metadataByPath: customMetadataByPath
                )
                playlists[idx].itemFileNames.insert(refreshedItem.relativePath, at: 0)
                savePlaylists()
                PlaylistTimeMachineService.shared.recordSnapshot(
                    for: playlists[idx],
                    items: items,
                    metadataByPath: customMetadataByPath,
                    trigger: .imported,
                    summary: "Downloaded \"\(refreshedItem.displayTitle)\""
                )
            }
            statusMessage = "Saved to Files & \(playlists[idx].name): \(refreshedItem.displayTitle)"
        } else {
            statusMessage = "Saved to Files & Last Played: \(refreshedItem.displayTitle)"
        }
        return refreshedItem
    }

    // MARK: - Folders & Moving

    @discardableResult
    func createFolder(named rawName: String, inParentFolder parentPath: String = "") -> LocalFolder? {
        let sanitized = sanitizeName(rawName)
        guard !sanitized.isEmpty else {
            errorMessage = "Please enter a valid folder name."
            return nil
        }

        let relPath = parentPath.isEmpty ? sanitized : "\(parentPath)/\(sanitized)"
        let targetURL = docsURL.appendingPathComponent(relPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            errorMessage = "A folder named \"\(sanitized)\" already exists."
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            loadLocalFiles()
            statusMessage = "Created folder \"\(sanitized)\""
            return folders.first(where: { $0.relativePath == relPath })
        } catch {
            errorMessage = "Could not create folder: \(error.localizedDescription)"
            return nil
        }
    }

    func renameFolder(_ folder: LocalFolder, to rawName: String) {
        let sanitized = sanitizeName(rawName)
        guard !sanitized.isEmpty else {
            errorMessage = "Please enter a valid folder name."
            return
        }
        guard sanitized != folder.name else { return }

        let parent = folder.parentRelativePath
        let newRelPath = parent.isEmpty ? sanitized : "\(parent)/\(sanitized)"
        let destURL = docsURL.appendingPathComponent(newRelPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            errorMessage = "A folder named \"\(sanitized)\" already exists."
            return
        }

        do {
            try FileManager.default.moveItem(at: folder.folderURL, to: destURL)
            rekeyTrackedFolder(from: folder.relativePath, to: newRelPath)
            let playingPrefix = "\(folder.relativePath)/"
            let wasPlayingInside = currentItem?.relativePath.hasPrefix(playingPrefix) == true
            loadLocalFiles()
            if wasPlayingInside, let oldRel = currentItem?.relativePath {
                let suffix = String(oldRel.dropFirst(playingPrefix.count))
                let updatedRel = "\(newRelPath)/\(suffix)"
                if let refreshed = items.first(where: { $0.relativePath == updatedRel }) {
                    currentItem = refreshed
                    updateNowPlayingInfo(for: refreshed)
                }
            }
            statusMessage = "Renamed folder to \"\(sanitized)\""
        } catch {
            errorMessage = "Rename folder failed: \(error.localizedDescription)"
        }
    }

    func deleteFolder(_ folder: LocalFolder) {
        let prefix = "\(folder.relativePath)/"
        if currentItem?.relativePath.hasPrefix(prefix) == true {
            stop()
        }
        do {
            try FileManager.default.removeItem(at: folder.folderURL)
            removeTrackedPaths { $0 == folder.relativePath || $0.hasPrefix(prefix) }
            loadLocalFiles()
            statusMessage = "Deleted folder \"\(folder.name)\""
        } catch {
            errorMessage = "Could not delete folder: \(error.localizedDescription)"
        }
    }

    func moveItem(_ item: MediaItem, toFolder targetFolderPath: String) {
        guard item.folderRelativePath != targetFolderPath else { return }
        let destURL = uniqueDestinationURL(for: item.fileName, inFolder: targetFolderPath)
        let newRelPath = targetFolderPath.isEmpty ? destURL.lastPathComponent : "\(targetFolderPath)/\(destURL.lastPathComponent)"

        do {
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item.fileURL, to: destURL)
            rekeyTrackedPath(from: item.relativePath, to: newRelPath)
            let wasPlaying = currentItem?.relativePath == item.relativePath
            loadLocalFiles()
            if wasPlaying, let refreshed = items.first(where: { $0.relativePath == newRelPath }) {
                currentItem = refreshed
                updateNowPlayingInfo(for: refreshed)
            }
            statusMessage = targetFolderPath.isEmpty ? "Moved to Root" : "Moved to \(targetFolderPath)"
        } catch {
            errorMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    func moveOtherFile(_ file: LocalFile, toFolder targetFolderPath: String) {
        guard file.folderRelativePath != targetFolderPath else { return }
        let destURL = uniqueDestinationURL(for: file.fileName, inFolder: targetFolderPath)
        let newRelPath = targetFolderPath.isEmpty ? destURL.lastPathComponent : "\(targetFolderPath)/\(destURL.lastPathComponent)"

        do {
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.fileURL, to: destURL)
            if let oldID = existingOtherIDsByPath.removeValue(forKey: file.relativePath) {
                existingOtherIDsByPath[newRelPath] = oldID
            }
            loadLocalFiles()
            statusMessage = targetFolderPath.isEmpty ? "Moved to Root" : "Moved to \(targetFolderPath)"
        } catch {
            errorMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Playlists

    enum PlaylistIntentOutcome {
        case playing(name: String, count: Int)
        case empty(name: String)
        case notFound
    }

    private func duplicateLibraryFileNames() -> Set<String> {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.fileName, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private func playlistKeyMatches(_ storedKey: String, item: MediaItem, duplicateNames: Set<String>) -> Bool {
        if storedKey == item.relativePath {
            return true
        }
        if !storedKey.contains("/") && !duplicateNames.contains(item.fileName) && storedKey == item.fileName {
            return true
        }
        return false
    }

    func items(in playlist: Playlist) -> [MediaItem] {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let duplicateNames = duplicateLibraryFileNames()
        let uniqueByName = Dictionary(
            items.filter { !duplicateNames.contains($0.fileName) }.map { ($0.fileName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenPaths = Set<String>()
        return playlist.itemFileNames.compactMap { key in
            guard let match = byPath[key] ?? (!key.contains("/") ? uniqueByName[key] : nil) else {
                return nil
            }
            guard seenPaths.insert(match.relativePath).inserted else { return nil }
            return match
        }
    }

    @discardableResult
    func createPlaylist(name: String, initialPaths: [String] = []) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a playlist name."
            return nil
        }

        var seen = Set<String>()
        let uniqueInitial = initialPaths.filter { seen.insert($0).inserted }
        let playlist = Playlist(id: UUID(), name: trimmed, itemFileNames: uniqueInitial)
        playlists.insert(playlist, at: 0)
        savePlaylists()
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlist,
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .baseline,
            summary: "Created playlist (\(playlist.itemFileNames.count) \(playlist.itemFileNames.count == 1 ? "track" : "tracks"))"
        )
        statusMessage = "Created playlist \"\(trimmed)\""
        return playlist
    }

    func deletePlaylist(_ playlist: Playlist) {
        let livePlaylist = playlists.first(where: { $0.id == playlist.id }) ?? playlist
        let liveCount = items(in: livePlaylist).count
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: livePlaylist,
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .beforeDelete,
            summary: "Before deleting \"\(livePlaylist.name)\" (\(liveCount) \(liveCount == 1 ? "track" : "tracks"))",
            isPinned: true
        )
        if activePlaylistID == playlist.id {
            activePlaylistID = nil
        }
        if lastPlaylistID == playlist.id {
            lastPlaylistID = nil
            saveLibraryState()
        }
        let targetKey = "musicplayer.targetDownloadPlaylistID"
        if UserDefaults.standard.string(forKey: targetKey) == playlist.id.uuidString {
            UserDefaults.standard.removeObject(forKey: targetKey)
        }
        if let coverFile = playlist.customCoverFileName {
            try? FileManager.default.removeItem(at: coversDirectoryURL.appendingPathComponent(coverFile))
        }
        playlistCovers.removeValue(forKey: playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
        statusMessage = "Deleted playlist \"\(playlist.name)\""
    }

    private static func scaledCoverImage(_ image: UIImage, maxDimension: CGFloat = 800) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let ratio = maxDimension / longest
        let targetSize = CGSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func updatePlaylistCover(for playlist: Playlist, image: UIImage?, remove: Bool = false) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        if let oldCover = playlists[index].customCoverFileName {
            try? FileManager.default.removeItem(at: coversDirectoryURL.appendingPathComponent(oldCover))
        }

        if remove || image == nil {
            playlists[index].customCoverFileName = nil
            playlistCovers.removeValue(forKey: playlist.id)
        } else if let image {
            let scaled = Self.scaledCoverImage(image)
            if let jpeg = scaled.jpegData(compressionQuality: 0.85) {
                let fileName = "playlist_\(playlist.id.uuidString).jpg"
                try? FileManager.default.createDirectory(at: coversDirectoryURL, withIntermediateDirectories: true)
                try? jpeg.write(to: coversDirectoryURL.appendingPathComponent(fileName), options: [.atomic])
                playlists[index].customCoverFileName = fileName
                playlistCovers[playlist.id] = scaled
            }
        }

        savePlaylists()
        statusMessage = remove ? "Reset playlist cover" : "Updated playlist cover"
    }

    private func loadPlaylistCovers() {
        for playlist in playlists {
            guard let coverName = playlist.customCoverFileName,
                  let data = try? Data(contentsOf: coversDirectoryURL.appendingPathComponent(coverName)),
                  let image = UIImage(data: data) else {
                continue
            }
            playlistCovers[playlist.id] = Self.scaledCoverImage(image)
        }
    }

    func renamePlaylist(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a valid playlist name."
            return
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath
        )
        playlists[index].name = trimmed
        savePlaylists()
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .renamed,
            summary: "Renamed to \"\(trimmed)\""
        )
        statusMessage = "Renamed playlist to \"\(trimmed)\""
    }

    func playlistContains(_ item: MediaItem, in playlist: Playlist) -> Bool {
        let duplicateNames = duplicateLibraryFileNames()
        return playlist.itemFileNames.contains { playlistKeyMatches($0, item: item, duplicateNames: duplicateNames) }
    }

    func add(_ item: MediaItem, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if !playlistContains(item, in: playlists[index]) {
            PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
                for: playlists[index],
                items: items,
                metadataByPath: customMetadataByPath
            )
            playlists[index].itemFileNames.append(item.relativePath)
            savePlaylists()
            PlaylistTimeMachineService.shared.recordSnapshot(
                for: playlists[index],
                items: items,
                metadataByPath: customMetadataByPath,
                trigger: .tracksAdded,
                summary: "Added \"\(item.displayTitle)\""
            )
            statusMessage = "Added to \"\(playlist.name)\""
        } else {
            statusMessage = "Already in \"\(playlist.name)\""
        }
    }

    func remove(_ item: MediaItem, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let duplicateNames = duplicateLibraryFileNames()
        guard playlists[index].itemFileNames.contains(where: { playlistKeyMatches($0, item: item, duplicateNames: duplicateNames) }) else {
            return
        }
        PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath
        )
        let before = playlists[index].itemFileNames.count
        playlists[index].itemFileNames.removeAll { playlistKeyMatches($0, item: item, duplicateNames: duplicateNames) }
        if playlists[index].itemFileNames.count != before {
            savePlaylists()
            PlaylistTimeMachineService.shared.recordSnapshot(
                for: playlists[index],
                items: items,
                metadataByPath: customMetadataByPath,
                trigger: .tracksRemoved,
                summary: "Removed \"\(item.displayTitle)\""
            )
            statusMessage = "Removed from \"\(playlist.name)\""
        }
    }

    func removeItems(at offsets: IndexSet, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let resolved = items(in: playlists[index])
        let duplicateNames = duplicateLibraryFileNames()
        let victims = offsets.compactMap { resolved.indices.contains($0) ? resolved[$0] : nil }
        guard !victims.isEmpty else { return }
        PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath
        )
        playlists[index].itemFileNames.removeAll { key in
            victims.contains { playlistKeyMatches(key, item: $0, duplicateNames: duplicateNames) }
        }
        savePlaylists()
        let victimSummary = victims.count == 1 ? "\"\(victims[0].displayTitle)\"" : "\(victims.count) tracks"
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .tracksRemoved,
            summary: "Removed \(victimSummary)"
        )
    }

    func moveItems(from source: IndexSet, to destination: Int, in playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath
        )
        var resolvedPaths = items(in: playlists[index]).map(\.relativePath)
        resolvedPaths.move(fromOffsets: source, toOffset: destination)
        playlists[index].itemFileNames = resolvedPaths
        savePlaylists()
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .reordered,
            summary: "Reordered \(resolvedPaths.count) tracks"
        )
    }

    // MARK: - Fast Batch Playlist Import (No O(N^2) Scans on 5,000+ Tracks)

    func existingMediaMapByVideoID() -> [String: MediaItem] {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var map: [String: MediaItem] = [:]
        map.reserveCapacity(customMetadataByPath.count)
        for (relPath, meta) in customMetadataByPath {
            guard let vid = meta.sourceVideoID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !vid.isEmpty,
                  let item = byPath[relPath] else {
                continue
            }
            if map[vid] == nil {
                map[vid] = item
            }
        }
        return map
    }

    func existingMediaItem(forVideoID videoID: String) -> MediaItem? {
        let cleanID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { return nil }
        for (relPath, meta) in customMetadataByPath {
            if meta.sourceVideoID == cleanID,
               let match = items.first(where: { $0.relativePath == relPath }) {
                return match
            }
        }
        return nil
    }

    @discardableResult
    func fastImportDownloadedFile(
        from tempURL: URL,
        preferredFileName: String,
        title: String?,
        artist: String?,
        durationSeconds: Double?,
        sourceVideoID: String?,
        playlistID: UUID?,
        flushState: Bool = false
    ) -> MediaItem? {
        let cleanBase = sanitizeName((preferredFileName as NSString).deletingPathExtension)
        let ext = (preferredFileName as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = cleanBase.isEmpty ? "Track_\(Int(Date().timeIntervalSince1970))" : String(cleanBase.prefix(120))
        let targetName = ext.isEmpty ? "\(resolvedBase).m4a" : "\(resolvedBase).\(ext)"
        let destURL = uniqueDestinationURL(for: targetName, inFolder: "")

        do {
            try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        let relPath = destURL.lastPathComponent
        let fileSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVID = sourceVideoID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var entry = customMetadataByPath[relPath] ?? CustomTrackMetadata()
        if let cleanTitle, !cleanTitle.isEmpty { entry.title = cleanTitle }
        if let cleanArtist, !cleanArtist.isEmpty { entry.artist = cleanArtist }
        if let cleanVID, !cleanVID.isEmpty { entry.sourceVideoID = cleanVID }
        customMetadataByPath[relPath] = entry

        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            durationsByPath[relPath] = durationSeconds
        }

        let newItem = MediaItem(
            id: UUID(),
            name: (relPath as NSString).deletingPathExtension,
            fileName: relPath,
            relativePath: relPath,
            fileSize: fileSize,
            dateAdded: .now,
            durationSeconds: (durationSeconds?.isFinite == true && (durationSeconds ?? 0) > 0) ? durationSeconds : nil,
            metadataTitle: (cleanTitle?.isEmpty == false ? cleanTitle : nil),
            artist: (cleanArtist?.isEmpty == false ? cleanArtist : nil)
        )
        items.insert(newItem, at: 0)

        if let playlistID, let pIdx = playlists.firstIndex(where: { $0.id == playlistID }) {
            if !playlists[pIdx].itemFileNames.contains(relPath) {
                playlists[pIdx].itemFileNames.append(relPath)
            }
        }

        if flushState {
            saveLibraryState()
            savePlaylists()
        }
        return newItem
    }

    @discardableResult
    func addExistingItemsToPlaylistFast(
        _ itemsToAdd: [MediaItem],
        playlistID: UUID,
        flushState: Bool = false
    ) -> Int {
        guard !itemsToAdd.isEmpty,
              let pIdx = playlists.firstIndex(where: { $0.id == playlistID }) else { return 0 }
        let duplicateNames = duplicateLibraryFileNames()
        var existingKeys = Set(playlists[pIdx].itemFileNames)
        var added = 0
        for item in itemsToAdd {
            if existingKeys.contains(item.relativePath) { continue }
            if !duplicateNames.contains(item.fileName), existingKeys.contains(item.fileName) {
                continue
            }
            playlists[pIdx].itemFileNames.append(item.relativePath)
            existingKeys.insert(item.relativePath)
            added += 1
        }
        if added > 0 && flushState {
            savePlaylists()
        }
        return added
    }

    @discardableResult
    func addExistingItemToPlaylistFast(
        _ item: MediaItem,
        playlistID: UUID,
        flushState: Bool = false
    ) -> Bool {
        addExistingItemsToPlaylistFast([item], playlistID: playlistID, flushState: flushState) > 0
    }

    func flushBatchPlaylistImport(
        playlistID: UUID?,
        summary: String?,
        reloadLibrary: Bool = false
    ) {
        saveLibraryState()
        savePlaylists()
        if reloadLibrary {
            loadLocalFiles()
        }
        if let playlistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            let label = (summary?.isEmpty == false)
                ? summary!
                : "Imported tracks (\(playlist.itemFileNames.count) total)"
            PlaylistTimeMachineService.shared.recordSnapshot(
                for: playlist,
                items: items,
                metadataByPath: customMetadataByPath,
                trigger: .imported,
                summary: label
            )
        }
    }

    // MARK: - Playlist Time-Machine Restore

    @discardableResult
    func restoreDeletedSongs(
        tracksToRestore: [(track: PlaylistSnapshotTrack, item: MediaItem)],
        snapshotTracks: [PlaylistSnapshotTrack],
        into playlistID: UUID,
        summary: String? = nil
    ) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return 0 }
        let newAdditions = tracksToRestore.filter { !playlistContains($0.item, in: playlists[index]) }
        guard !newAdditions.isEmpty else {
            statusMessage = "All selected tracks are already in \"\(playlists[index].name)\""
            return 0
        }

        let backupLabel = "Before restoring \(newAdditions.count) \(newAdditions.count == 1 ? "song" : "songs")"
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .beforeRestore,
            summary: backupLabel
        )

        var paths = playlists[index].itemFileNames
        var addedCount = 0
        for (snapTrack, item) in newAdditions {
            if paths.contains(item.relativePath) { continue }
            insertPathPreservingOrder(
                item.relativePath,
                snapshotKey: snapTrack.key,
                snapshotTracks: snapshotTracks,
                into: &paths
            )
            addedCount += 1
        }

        playlists[index].itemFileNames = paths
        savePlaylists()

        let finalSummary = summary ?? "Restored \(addedCount) \(addedCount == 1 ? "song" : "songs") from Time-Machine"
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .restored,
            summary: finalSummary
        )
        statusMessage = "Restored \(addedCount) \(addedCount == 1 ? "song" : "songs") to \"\(playlists[index].name)\""
        return addedCount
    }

    @discardableResult
    func restoreSingleTrackFromTimeMachine(
        _ item: MediaItem,
        snapshotTrack: PlaylistSnapshotTrack?,
        snapshotTracks: [PlaylistSnapshotTrack],
        into playlistID: UUID,
        summary: String? = nil
    ) -> Bool {
        let track = snapshotTrack ?? PlaylistSnapshotTrack(
            key: item.relativePath,
            fileName: item.fileName,
            displayTitle: item.displayTitle,
            artist: item.artist,
            durationSeconds: item.durationSeconds,
            sourceVideoID: customMetadataByPath[item.relativePath]?.sourceVideoID,
            isVideo: item.isVideo
        )
        return restoreDeletedSongs(
            tracksToRestore: [(track, item)],
            snapshotTracks: snapshotTracks,
            into: playlistID,
            summary: summary ?? "Restored \"\(item.displayTitle)\""
        ) > 0
    }

    @discardableResult
    func revertPlaylist(
        _ playlistID: UUID,
        to snapshot: PlaylistSnapshot,
        includeName: Bool = true
    ) -> (restoredCount: Int, missingCount: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return (0, snapshot.tracks.count)
        }
        let stamp = PlaylistTimeMachineService.shortDateFormatter.string(from: snapshot.createdAt)
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .beforeRestore,
            summary: "Before reverting to \(stamp)"
        )

        var resolvedPaths: [String] = []
        var seen = Set<String>()
        var missingCount = 0
        for track in snapshot.tracks {
            if let matched = PlaylistTimeMachineService.shared.resolveLibraryItem(
                for: track,
                in: items,
                metadataByPath: customMetadataByPath
            ) {
                if seen.insert(matched.relativePath).inserted {
                    resolvedPaths.append(matched.relativePath)
                }
            } else {
                missingCount += 1
            }
        }

        playlists[index].itemFileNames = resolvedPaths
        if includeName, !snapshot.playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            playlists[index].name = snapshot.playlistName
        }
        savePlaylists()

        PlaylistTimeMachineService.shared.recordSnapshot(
            for: playlists[index],
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .restored,
            summary: "Reverted to \(stamp) (\(resolvedPaths.count) tracks)"
        )

        if missingCount > 0 {
            statusMessage = "Reverted \"\(playlists[index].name)\" (\(resolvedPaths.count) tracks; \(missingCount) files missing from Library)"
        } else {
            statusMessage = "Reverted \"\(playlists[index].name)\" to \(stamp) (\(resolvedPaths.count) tracks)"
        }
        return (resolvedPaths.count, missingCount)
    }

    @discardableResult
    func restoreSnapshotAsCopy(
        _ snapshot: PlaylistSnapshot,
        customName: String? = nil
    ) -> (playlist: Playlist, missingCount: Int) {
        var resolvedPaths: [String] = []
        var seen = Set<String>()
        var missingCount = 0
        for track in snapshot.tracks {
            if let matched = PlaylistTimeMachineService.shared.resolveLibraryItem(
                for: track,
                in: items,
                metadataByPath: customMetadataByPath
            ) {
                if seen.insert(matched.relativePath).inserted {
                    resolvedPaths.append(matched.relativePath)
                }
            } else {
                missingCount += 1
            }
        }

        let stamp = PlaylistTimeMachineService.shortDateFormatter.string(from: snapshot.createdAt)
        let trimmedCustom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetName = trimmedCustom.isEmpty ? "\(snapshot.playlistName) (\(stamp))" : trimmedCustom
        let created = Playlist(id: UUID(), name: targetName, itemFileNames: resolvedPaths, dateCreated: .now)
        playlists.insert(created, at: 0)
        savePlaylists()
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: created,
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .restored,
            summary: "Created from snapshot (\(resolvedPaths.count) tracks)"
        )
        statusMessage = "Created copy \"\(targetName)\" (\(resolvedPaths.count) tracks)"
        return (created, missingCount)
    }

    @discardableResult
    func restoreDeletedPlaylist(from snapshot: PlaylistSnapshot) -> (playlist: Playlist, missingCount: Int) {
        if playlists.contains(where: { $0.id == snapshot.playlistID }) {
            return restoreSnapshotAsCopy(snapshot, customName: "\(snapshot.playlistName) (Recovered)")
        }

        var resolvedPaths: [String] = []
        var seen = Set<String>()
        var missingCount = 0
        for track in snapshot.tracks {
            if let matched = PlaylistTimeMachineService.shared.resolveLibraryItem(
                for: track,
                in: items,
                metadataByPath: customMetadataByPath
            ) {
                if seen.insert(matched.relativePath).inserted {
                    resolvedPaths.append(matched.relativePath)
                }
            } else {
                missingCount += 1
            }
        }

        let restored = Playlist(
            id: snapshot.playlistID,
            name: snapshot.playlistName,
            itemFileNames: resolvedPaths,
            dateCreated: .now
        )
        playlists.insert(restored, at: 0)
        savePlaylists()
        PlaylistTimeMachineService.shared.recordSnapshot(
            for: restored,
            items: items,
            metadataByPath: customMetadataByPath,
            trigger: .restored,
            summary: "Recovered deleted playlist (\(resolvedPaths.count) tracks)"
        )
        statusMessage = missingCount > 0
            ? "Recovered \"\(restored.name)\" (\(resolvedPaths.count) tracks; \(missingCount) files missing)"
            : "Recovered deleted playlist \"\(restored.name)\" (\(resolvedPaths.count) tracks)"
        return (restored, missingCount)
    }

    private func insertPathPreservingOrder(
        _ newPath: String,
        snapshotKey: String?,
        snapshotTracks: [PlaylistSnapshotTrack],
        into currentPaths: inout [String]
    ) {
        guard let snapshotKey,
              !snapshotTracks.isEmpty,
              let snapIdx = snapshotTracks.firstIndex(where: { $0.key == snapshotKey }) else {
            currentPaths.append(newPath)
            return
        }

        let duplicateNames = duplicateLibraryFileNames()
        func currentIndex(for snapTrack: PlaylistSnapshotTrack) -> Int? {
            if let direct = currentPaths.firstIndex(of: snapTrack.key) {
                return direct
            }
            if let matched = PlaylistTimeMachineService.shared.resolveLibraryItem(
                for: snapTrack,
                in: items,
                metadataByPath: customMetadataByPath
            ) {
                return currentPaths.firstIndex { playlistKeyMatches($0, item: matched, duplicateNames: duplicateNames) }
            }
            return nil
        }

        if snapIdx > 0 {
            for prevIdx in stride(from: snapIdx - 1, through: 0, by: -1) {
                if let currIdx = currentIndex(for: snapshotTracks[prevIdx]) {
                    currentPaths.insert(newPath, at: min(currIdx + 1, currentPaths.count))
                    return
                }
            }
        }

        if snapIdx + 1 < snapshotTracks.count {
            for nextIdx in (snapIdx + 1)..<snapshotTracks.count {
                if let currIdx = currentIndex(for: snapshotTracks[nextIdx]) {
                    currentPaths.insert(newPath, at: currIdx)
                    return
                }
            }
        }

        currentPaths.append(newPath)
    }

    func playPlaylist(_ playlist: Playlist, startingAt startItem: MediaItem? = nil) {
        let playlistItems = items(in: playlist)
        if isShuffleEnabled && startItem == nil {
            shuffleBag.reset()
        }
        guard let first = startItem ?? (isShuffleEnabled ? playlistItems.randomElement() : playlistItems.first) else {
            errorMessage = "Playlist \"\(playlist.name)\" has no playable files."
            return
        }
        play(first, inPlaylist: playlist.id)
    }

    @MainActor
    @discardableResult
    func playPlaylist(named name: String) -> PlaylistIntentOutcome {
        loadPlaylists()
        loadLocalFiles()

        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .notFound }

        let matched = playlists.first { $0.name.compare(query, options: .caseInsensitive) == .orderedSame }
            ?? playlists.first { $0.name.localizedCaseInsensitiveContains(query) }

        guard let playlist = matched else {
            return .notFound
        }

        let playlistItems = items(in: playlist)
        guard !playlistItems.isEmpty else {
            return .empty(name: playlist.name)
        }

        playPlaylist(playlist)
        return .playing(name: playlist.name, count: playlistItems.count)
    }

    @discardableResult
    func playSong(named query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let matched = items.first {
            $0.displayTitle.compare(trimmed, options: .caseInsensitive) == .orderedSame
        } ?? items.first {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
                ($0.artist?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
        guard let matched else { return false }
        play(matched)
        return true
    }

    func shuffleAllOfflineMusic() {
        let pool = audioItems.isEmpty ? items : audioItems
        guard let pick = pool.randomElement() else {
            errorMessage = "No offline tracks available to shuffle."
            return
        }
        isShuffleEnabled = true
        play(pick)
        statusMessage = "Shuffling: \(pick.displayTitle)"
    }

    func resumeOrPlayMostRecent() {
        if currentItem != nil {
            if !isPlaying {
                resume()
            }
            return
        }
        if let queued = popNextQueuedItem() {
            play(queued)
            return
        }
        if let recent = recentItems.first ?? items.first {
            play(recent)
        } else {
            errorMessage = "No offline media in library yet."
        }
    }

    // MARK: - Delete, Rename, & MP4 Conversion

    func delete(_ item: MediaItem) {
        if currentItem?.relativePath == item.relativePath {
            stop()
        }
        guard removeFileAtURL(item.fileURL, displayName: item.name) else { return }
        removeTrackedPaths { $0 == item.relativePath }
        loadLocalFiles()
    }

    func deleteOtherFile(_ file: LocalFile) {
        guard removeFileAtURL(file.fileURL, displayName: file.name) else { return }
        existingOtherIDsByPath.removeValue(forKey: file.relativePath)
        loadLocalFiles()
    }

    func rename(_ item: MediaItem, to rawName: String) {
        guard let result = moveRenamedFile(
            from: item.fileURL,
            folderPath: item.folderRelativePath,
            currentFileName: item.fileName,
            ext: item.fileExtension,
            to: rawName
        ) else { return }

        rekeyTrackedPath(from: item.relativePath, to: result.newRelativePath)

        let wasPlayingCurrent = currentItem?.relativePath == item.relativePath
        loadLocalFiles()
        if wasPlayingCurrent, let updated = items.first(where: { $0.relativePath == result.newRelativePath }) {
            currentItem = updated
            updateNowPlayingInfo(for: updated)
        }
        statusMessage = "Renamed to \(result.displayName)"
    }

    func renameOtherFile(_ file: LocalFile, to rawName: String) {
        guard let result = moveRenamedFile(
            from: file.fileURL,
            folderPath: file.folderRelativePath,
            currentFileName: file.fileName,
            ext: file.fileExtension,
            to: rawName
        ) else { return }

        existingOtherIDsByPath[result.newRelativePath] = file.id
        existingOtherIDsByPath.removeValue(forKey: file.relativePath)
        loadLocalFiles()
        statusMessage = "Renamed to \(result.displayName)"
    }

    @MainActor
    func convertToMP4(item: MediaItem) async {
        guard !item.isHLS else {
            errorMessage = "HLS (.movpkg) streams are already packaged for offline playback."
            return
        }
        guard convertingItemID == nil else {
            errorMessage = "An MP4 conversion is already in progress."
            return
        }

        convertingItemID = item.id
        conversionProgress = 0
        defer {
            convertingItemID = nil
            conversionProgress = 0
        }

        let asset = AVURLAsset(url: item.fileURL)
        let candidatePresets = [
            AVAssetExportPresetHighestQuality,
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPresetMediumQuality
        ]

        var selectedSession: AVAssetExportSession?
        for preset in candidatePresets {
            if let session = AVAssetExportSession(asset: asset, presetName: preset),
               session.supportedFileTypes.contains(.mp4) {
                selectedSession = session
                break
            }
        }

        guard let session = selectedSession else {
            let baseOutputName = item.name.hasSuffix("_converted") ? "\(item.name)_new.mp4" : "\(item.name)_converted.mp4"
            let outputURL = uniqueDestinationURL(for: baseOutputName, inFolder: item.folderRelativePath)
            try? FileManager.default.removeItem(at: outputURL)
            conversionProgress = 0.5
            let remuxed = await Task.detached(priority: .userInitiated) {
                FFmpegMediaService.remuxToMP4(inputURL: item.fileURL, outputURL: outputURL)
            }.value
            if remuxed {
                loadLocalFiles()
                statusMessage = "Exported \(outputURL.lastPathComponent)"
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                errorMessage = "This container's codecs cannot be losslessly remuxed to MP4, but it plays directly with the built-in FFmpeg player."
            }
            return
        }

        let baseOutputName = item.name.hasSuffix("_converted") ? "\(item.name)_new.mp4" : "\(item.name)_converted.mp4"
        let outputURL = uniqueDestinationURL(for: baseOutputName, inFolder: item.folderRelativePath)
        try? FileManager.default.removeItem(at: outputURL)

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                self.conversionProgress = Double(session.progress)
                if session.status != .exporting && session.status != .waiting {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        await session.export()
        progressTask.cancel()

        switch session.status {
        case .completed:
            loadLocalFiles()
            statusMessage = "Exported \(outputURL.lastPathComponent)"
        case .failed:
            try? FileManager.default.removeItem(at: outputURL)
            errorMessage = session.error?.localizedDescription ?? "MP4 conversion failed."
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            statusMessage = "MP4 conversion cancelled."
        default:
            break
        }
    }

    @MainActor
    func extractAudioToM4A(item: MediaItem) async {
        guard !item.isHLS else {
            errorMessage = "Cannot extract audio directly from an offline HLS (.movpkg) stream."
            return
        }
        guard convertingItemID == nil else {
            errorMessage = "A media conversion is already in progress."
            return
        }

        convertingItemID = item.id
        conversionProgress = 0
        defer {
            convertingItemID = nil
            conversionProgress = 0
        }

        let asset = AVURLAsset(url: item.fileURL)
        let outputURL = uniqueDestinationURL(for: "\(item.name).m4a", inFolder: item.folderRelativePath)
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            conversionProgress = 0.5
            let remuxed = await Task.detached(priority: .userInitiated) {
                FFmpegMediaService.remuxAudioTrackToM4A(inputURL: item.fileURL, outputURL: outputURL)
            }.value
            if remuxed {
                loadLocalFiles()
                statusMessage = "Extracted \(outputURL.lastPathComponent)"
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                errorMessage = "Audio extraction is only available for AAC/ALAC tracks in this container."
            }
            return
        }

        session.outputURL = outputURL
        session.outputFileType = .m4a

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                self.conversionProgress = Double(session.progress)
                if session.status != .exporting && session.status != .waiting {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        await session.export()
        progressTask.cancel()

        switch session.status {
        case .completed:
            loadLocalFiles()
            statusMessage = "Extracted \(outputURL.lastPathComponent)"
        case .failed:
            try? FileManager.default.removeItem(at: outputURL)
            errorMessage = session.error?.localizedDescription ?? "Audio extraction failed."
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            statusMessage = "Audio extraction cancelled."
        default:
            break
        }
    }

    @MainActor
    func saveVideoScreenshot(from item: MediaItem, at seconds: Double) async {
        let saveFolder = item.relativePath.hasPrefix("__remote__/") ? "" : item.folderRelativePath

        if isUsingFFmpegBackend,
           currentItem?.relativePath == item.relativePath,
           let cgImage = await ffmpegPlayer?.thumbnailImageAtCurrentTime(),
           let pngData = UIImage(cgImage: cgImage).pngData() {
            let destURL = uniqueDestinationURL(for: "\(item.name)_frame.png", inFolder: saveFolder)
            try? pngData.write(to: destURL, options: [.atomic])
            loadLocalFiles()
            statusMessage = "Saved screenshot: \(destURL.lastPathComponent)"
            return
        }

        if item.prefersFFmpegEngine {
            let captured = await Task.detached(priority: .userInitiated) {
                FFmpegMediaService.extractArtworkOrFrame(from: item.fileURL, at: max(seconds, 0), maxDimension: 1920)
            }.value
            if let captured, let pngData = captured.pngData() {
                let destURL = uniqueDestinationURL(for: "\(item.name)_frame.png", inFolder: saveFolder)
                try? pngData.write(to: destURL, options: [.atomic])
                loadLocalFiles()
                statusMessage = "Saved screenshot: \(destURL.lastPathComponent)"
                return
            }
        }

        let assetURL = item.relativePath.hasPrefix("__remote__/") ? (remoteStreamSourceURL ?? item.fileURL) : item.fileURL
        let asset = AVURLAsset(url: assetURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cmTime = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: cmTime)
            let uiImage = UIImage(cgImage: cgImage)
            guard let pngData = uiImage.pngData() else { return }
            let destURL = uniqueDestinationURL(for: "\(item.name)_frame.png", inFolder: saveFolder)
            try pngData.write(to: destURL, options: [.atomic])
            loadLocalFiles()
            statusMessage = "Saved screenshot: \(destURL.lastPathComponent)"
        } catch {
            errorMessage = "Could not capture screenshot: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func extractArchive(_ file: LocalFile) -> String? {
        let baseName = sanitizeName(file.name)
        let folderTitle = baseName.isEmpty ? "Extracted" : baseName
        let destURL = uniqueDestinationURL(for: folderTitle, inFolder: file.folderRelativePath)
        let relFolder = file.folderRelativePath.isEmpty
            ? destURL.lastPathComponent
            : "\(file.folderRelativePath)/\(destURL.lastPathComponent)"

        do {
            let count = try ZipExtractor.extract(archiveURL: file.fileURL, to: destURL)
            loadLocalFiles()
            statusMessage = "Extracted \(count) \(count == 1 ? "file" : "files") to \(destURL.lastPathComponent)"
            return relFolder
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func images(inFolder folderPath: String) -> [LocalFile] {
        otherFiles
            .filter { $0.isImage && $0.folderRelativePath == folderPath }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    func imagesRecursive(inFolder folderPath: String) -> [LocalFile] {
        let prefix = folderPath + "/"
        return otherFiles
            .filter { file in
                guard file.isImage else { return false }
                if folderPath.isEmpty { return true }
                return file.folderRelativePath == folderPath || file.folderRelativePath.hasPrefix(prefix)
            }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func mangaImageChapters() -> [(title: String, folderPath: String, files: [LocalFile])] {
        var grouped: [String: [LocalFile]] = [:]
        for file in otherFiles where file.isImage {
            grouped[file.folderRelativePath, default: []].append(file)
        }
        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { folderPath in
                let sortedFiles = (grouped[folderPath] ?? []).sorted {
                    $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }
                guard !sortedFiles.isEmpty else { return nil }
                let title = folderPath.isEmpty ? "Library Pictures" : (folderPath as NSString).lastPathComponent
                return (title: title, folderPath: folderPath, files: sortedFiles)
            }
    }

    @MainActor
    @discardableResult
    func saveImagesFromWeb(_ imageURLs: [URL], folderName: String, referer: String? = nil) async -> [LocalFile] {
        guard !imageURLs.isEmpty else {
            errorMessage = "No downloadable images found on this page."
            return []
        }

        let cleanFolder = sanitizeName(folderName)
        let targetName = cleanFolder.isEmpty ? "Web Images" : String(cleanFolder.prefix(60))
        let folderURL = uniqueDestinationURL(for: targetName, inFolder: "")
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create images folder: \(error.localizedDescription)"
            return []
        }

        let folderRel = folderURL.lastPathComponent
        var saved = 0
        for (idx, url) in imageURLs.prefix(100).enumerated() {
            var request = URLRequest(url: url)
            if let referer {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            guard let (tempURL, resp) = try? await URLSession.shared.download(for: request) else { continue }
            let mime = resp.mimeType?.lowercased() ?? ""
            let ext: String
            switch mime {
            case "image/png": ext = "png"
            case "image/webp": ext = "webp"
            case "image/gif": ext = "gif"
            default:
                let urlExt = url.pathExtension.lowercased()
                ext = ["png", "jpg", "jpeg", "webp", "gif"].contains(urlExt) ? urlExt : "jpg"
            }
            let fileName = String(format: "%03d.%@", idx + 1, ext)
            let dest = folderURL.appendingPathComponent(fileName)
            if (try? FileManager.default.moveItem(at: tempURL, to: dest)) != nil {
                saved += 1
            } else {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        loadLocalFiles()
        if saved > 0 {
            statusMessage = "Saved \(saved) images into \"\(folderRel)\""
            return images(inFolder: folderRel)
        } else {
            try? FileManager.default.removeItem(at: folderURL)
            errorMessage = "Could not download images from this page."
            return []
        }
    }

    var totalStorageBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSize } + otherFiles.reduce(0) { $0 + $1.fileSize }
    }

    var formattedTotalStorage: String {
        ByteCountFormatter.string(fromByteCount: totalStorageBytes, countStyle: .file)
    }

    // MARK: - Persistence & Path Bookkeeping

    private var appSupportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var coversDirectoryURL: URL {
        appSupportDirectory.appendingPathComponent("Covers", isDirectory: true)
    }

    private var playlistsFileURL: URL {
        appSupportDirectory.appendingPathComponent("playlists.json")
    }

    private var libraryStateFileURL: URL {
        appSupportDirectory.appendingPathComponent("library_state.json")
    }

    private func loadPlaylists() {
        guard let data = try? Data(contentsOf: playlistsFileURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else {
            return
        }
        playlists = decoded
    }

    private func savePlaylists() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: playlistsFileURL, options: [.atomic])
        scheduleSpotlightReindex()
    }

    private func loadLibraryState() {
        guard let data = try? Data(contentsOf: libraryStateFileURL),
              let state = try? JSONDecoder().decode(LibraryPersistedState.self, from: data) else {
            return
        }
        likedPaths = Set(state.likedPaths)
        recentPaths = state.recentPaths
        upNextPaths = state.upNextPaths
        manualQueuePaths = state.manualQueuePaths ?? []
        customMetadataByPath = state.customMetadataByPath
        lastPlaylistID = state.lastPlaylistID
        repeatMode = state.repeatMode
    }

    private func saveLibraryState() {
        let state = LibraryPersistedState(
            likedPaths: Array(likedPaths),
            recentPaths: recentPaths,
            upNextPaths: upNextPaths,
            manualQueuePaths: manualQueuePaths,
            customMetadataByPath: customMetadataByPath,
            lastPlaylistID: lastPlaylistID,
            repeatMode: repeatMode
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: libraryStateFileURL, options: [.atomic])
    }

    private func recordRecent(_ relativePath: String) {
        recentPaths.removeAll { $0 == relativePath }
        recentPaths.insert(relativePath, at: 0)
        if recentPaths.count > 2000 {
            recentPaths = Array(recentPaths.prefix(2000))
        }
        saveLibraryState()
    }

    private func rekeyTrackedPath(from oldPath: String, to newPath: String) {
        if let id = existingIDsByPath.removeValue(forKey: oldPath) {
            existingIDsByPath[newPath] = id
        }
        if let dur = durationsByPath.removeValue(forKey: oldPath) {
            durationsByPath[newPath] = dur
        }
        if let title = titlesByPath.removeValue(forKey: oldPath) {
            titlesByPath[newPath] = title
        }
        if let artist = artistsByPath.removeValue(forKey: oldPath) {
            artistsByPath[newPath] = artist
        }
        if metadataLoadedPaths.remove(oldPath) != nil {
            metadataLoadedPaths.insert(newPath)
        }
        if let thumb = thumbnails.removeValue(forKey: oldPath) {
            thumbnails[newPath] = thumb
        }
        if let custom = customMetadataByPath.removeValue(forKey: oldPath) {
            customMetadataByPath[newPath] = custom
        }
        if likedPaths.remove(oldPath) != nil {
            likedPaths.insert(newPath)
        }
        recentPaths = recentPaths.map { $0 == oldPath ? newPath : $0 }
        upNextPaths = upNextPaths.map { $0 == oldPath ? newPath : $0 }

        var playlistsChanged = false
        for idx in playlists.indices {
            for itemIdx in playlists[idx].itemFileNames.indices {
                if playlists[idx].itemFileNames[itemIdx] == oldPath {
                    playlists[idx].itemFileNames[itemIdx] = newPath
                    playlistsChanged = true
                }
            }
        }
        if playlistsChanged { savePlaylists() }
        PlaylistTimeMachineService.shared.updatePathReferences(from: oldPath, to: newPath)
        saveLibraryState()
    }

    private func rekeyTrackedFolder(from oldFolderPath: String, to newFolderPath: String) {
        let oldPrefix = "\(oldFolderPath)/"
        let newPrefix = "\(newFolderPath)/"
        let affected = Array(existingIDsByPath.keys.filter { $0.hasPrefix(oldPrefix) })
        for oldPath in affected {
            let suffix = String(oldPath.dropFirst(oldPrefix.count))
            rekeyTrackedPath(from: oldPath, to: "\(newPrefix)\(suffix)")
        }
    }

    private func removeTrackedPaths(matching predicate: (String) -> Bool) {
        for key in existingIDsByPath.keys where predicate(key) { existingIDsByPath.removeValue(forKey: key) }
        for key in existingOtherIDsByPath.keys where predicate(key) { existingOtherIDsByPath.removeValue(forKey: key) }
        for key in existingFolderIDsByPath.keys where predicate(key) { existingFolderIDsByPath.removeValue(forKey: key) }
        for key in durationsByPath.keys where predicate(key) { durationsByPath.removeValue(forKey: key) }
        for key in titlesByPath.keys where predicate(key) { titlesByPath.removeValue(forKey: key) }
        for key in artistsByPath.keys where predicate(key) { artistsByPath.removeValue(forKey: key) }
        for key in thumbnails.keys where predicate(key) { thumbnails.removeValue(forKey: key) }
        metadataLoadedPaths = metadataLoadedPaths.filter { !predicate($0) }

        for key in customMetadataByPath.keys where predicate(key) {
            if let cover = customMetadataByPath.removeValue(forKey: key)?.coverFileName {
                try? FileManager.default.removeItem(at: coversDirectoryURL.appendingPathComponent(cover))
            }
        }

        likedPaths = likedPaths.filter { !predicate($0) }
        recentPaths.removeAll(where: predicate)
        upNextPaths.removeAll(where: predicate)

        var affectedPlaylistIDs: [UUID] = []
        for idx in playlists.indices {
            if playlists[idx].itemFileNames.contains(where: predicate) {
                PlaylistTimeMachineService.shared.ensurePreChangeCaptured(
                    for: playlists[idx],
                    items: items,
                    metadataByPath: customMetadataByPath
                )
                playlists[idx].itemFileNames.removeAll(where: predicate)
                affectedPlaylistIDs.append(playlists[idx].id)
            }
        }
        if !affectedPlaylistIDs.isEmpty {
            savePlaylists()
            for pid in affectedPlaylistIDs {
                if let live = playlists.first(where: { $0.id == pid }) {
                    PlaylistTimeMachineService.shared.recordSnapshot(
                        for: live,
                        items: items,
                        metadataByPath: customMetadataByPath,
                        trigger: .tracksRemoved,
                        summary: "Library file deleted"
                    )
                }
            }
        }
        saveLibraryState()
    }

    // MARK: - Private Helpers

    private func sanitizeName(_ raw: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalidChars)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func folderURL(for folderPath: String) -> URL {
        folderPath.isEmpty ? docsURL : docsURL.appendingPathComponent(folderPath, isDirectory: true)
    }

    private func removeFileAtURL(_ fileURL: URL, displayName: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            statusMessage = "Deleted \(displayName)"
            return true
        } catch {
            errorMessage = "Could not delete file: \(error.localizedDescription)"
            return false
        }
    }

    private func moveRenamedFile(
        from sourceURL: URL,
        folderPath: String,
        currentFileName: String,
        ext: String,
        to rawName: String
    ) -> (newRelativePath: String, displayName: String)? {
        let sanitized = sanitizeName(rawName)
        guard !sanitized.isEmpty else {
            errorMessage = "Please enter a valid file name."
            return nil
        }

        let newFileName = ext.isEmpty ? sanitized : "\(sanitized).\(ext)"
        guard newFileName != currentFileName else { return nil }

        let parentURL = folderURL(for: folderPath)
        let destinationURL = parentURL.appendingPathComponent(newFileName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            errorMessage = "A file named \"\(newFileName)\" already exists."
            return nil
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            let newRel = folderPath.isEmpty ? newFileName : "\(folderPath)/\(newFileName)"
            return (newRel, sanitized)
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func cleanupObservers() {
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func attachTimeObserver(to player: AVPlayer, playerItem: AVPlayerItem) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let elapsed = CMTimeGetSeconds(time)
            if elapsed.isFinite, elapsed >= 0, !self.isScrubbing {
                self.currentTime = elapsed
            }

            let itemDuration = CMTimeGetSeconds(playerItem.duration)
            if itemDuration.isFinite, itemDuration > 0, abs(self.duration - itemDuration) > 0.1 {
                self.duration = itemDuration
                if let path = self.currentItem?.relativePath {
                    self.durationsByPath[path] = itemDuration
                }
                if let currentItem = self.currentItem {
                    self.updateNowPlayingInfo(for: currentItem)
                }
            }
            self.syncWrappedHeartbeat()
        }
    }

    private func attachEndObserver(to playerItem: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
    }

    private func handlePlaybackEnded() {
        ListeningWrappedService.shared.endSession(didFinishTrack: true)
        if repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }

        if let queued = popNextQueuedItem() {
            play(queued, inPlaylist: activePlaylistID)
            return
        }

        if let nextHandler = externalQueueNextHandler, nextHandler() {
            return
        }

        if activeQueue.count > 1 {
            playNext(fromQueueOnly: false)
            return
        }

        if repeatMode == .all {
            seek(to: 0)
            resume()
        } else {
            isPlaying = false
            seek(to: 0)
            if let currentItem {
                updateNowPlayingInfo(for: currentItem)
            }
        }
    }

    private func uniqueDestinationURL(for fileName: String, inFolder folderPath: String) -> URL {
        let baseFolder = folderURL(for: folderPath)
        let nsName = fileName as NSString
        let baseName = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var candidate = baseFolder.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = baseFolder.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }

    private func updateNowPlayingInfo(for item: MediaItem) {
        let custom = customMetadataByPath[item.relativePath]
        let resolvedTitle = custom?.title ?? item.metadataTitle ?? titlesByPath[item.relativePath] ?? item.name
        let resolvedArtist = custom?.artist ?? item.artist ?? artistsByPath[item.relativePath] ?? (item.isVideo ? "MuseJRM Video" : "Unknown Artist")
        let queue = activeQueue
        let queueIdx = queue.firstIndex(where: { $0.relativePath == item.relativePath })
        NowPlayingManager.updateNowPlayingInfo(
            title: resolvedTitle,
            artist: resolvedArtist,
            duration: duration,
            elapsed: currentTime,
            artworkImage: thumbnails[item.relativePath],
            playbackRate: isPlaying ? Double(playbackRate) : 0.0,
            mediaType: item.isVideo ? .movie : .music,
            isFavorite: isFavorite(item),
            queueIndex: queueIdx,
            queueCount: queue.isEmpty ? nil : queue.count
        )
    }

    private func setupEqualizerCallbacks() {
        equalizerPlayer.onProgressUpdate = { [weak self] elapsed, totalDuration in
            guard let self, self.isUsingEqualizerBackend, !self.isScrubbing else { return }
            self.currentTime = elapsed
            if totalDuration > 0, abs(self.duration - totalDuration) > 0.1 {
                self.duration = totalDuration
                if let path = self.currentItem?.relativePath {
                    self.durationsByPath[path] = totalDuration
                }
                if let currentItem = self.currentItem {
                    self.updateNowPlayingInfo(for: currentItem)
                }
            }
            self.syncWrappedHeartbeat()

            if !self.crossfadeTriggeredForCurrentTrack,
               self.isPlaying,
               AppSettings.isCrossfadeEnabled,
               self.repeatMode != .one,
               self.externalQueueNextHandler == nil {
                let fadeSec = AppSettings.storedCrossfadeDuration
                if totalDuration > fadeSec + 1.5,
                   elapsed > 0.5,
                   (totalDuration - elapsed) <= fadeSec {
                    self.performAutomaticCrossfade(duration: fadeSec)
                }
            }
        }

        equalizerPlayer.onPlaybackEnded = { [weak self] in
            guard let self, self.isUsingEqualizerBackend else { return }
            self.handlePlaybackEnded()
        }
    }

    private func peekNextCrossfadeCandidate() -> (item: MediaItem, fromUserQueue: Bool)? {
        if let queued = upNextItems.first {
            return (queued, true)
        }
        let queue = activeQueue
        guard !queue.isEmpty else { return nil }
        if isShuffleEnabled, queue.count > 1 {
            // Peek only: the bag syncs once the crossfaded song becomes current, so the choice stays consistent.
            if let shuffledNext = nextShuffledItem(from: queue, consume: false) {
                return (shuffledNext, false)
            }
            return nil
        }
        guard let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else {
            return queue.first.map { ($0, false) }
        }
        let nextIndex = index + 1
        if nextIndex < queue.count {
            return (queue[nextIndex], false)
        }
        if repeatMode == .all, let first = queue.first, queue.count > 1 {
            return (first, false)
        }
        return nil
    }

    private func performAutomaticCrossfade(duration fadeSec: Double) {
        crossfadeTriggeredForCurrentTrack = true
        guard let candidate = peekNextCrossfadeCandidate() else { return }
        let nextItem = candidate.item
        guard !nextItem.isVideo,
              !nextItem.prefersFFmpegEngine,
              FileManager.default.fileExists(atPath: nextItem.fileURL.path) else {
            return
        }

        if candidate.fromUserQueue {
            _ = popNextQueuedItem()
        }

        do {
            equalizerPlayer.setPlaybackRate(playbackRate)
            try equalizerPlayer.crossfadeTo(url: nextItem.fileURL, duration: fadeSec)
            ListeningWrappedService.shared.endSession(didFinishTrack: true)
            isUsingEqualizerBackend = true
            remoteStreamSourceURL = nil
            currentItem = nextItem
            currentTime = 0
            duration = equalizerPlayer.duration > 0 ? equalizerPlayer.duration : (nextItem.durationSeconds ?? 0)
            isPlaying = true
            crossfadeTriggeredForCurrentTrack = false
            recordRecent(nextItem.relativePath)
            updateNowPlayingInfo(for: nextItem)
            syncWrappedSessionStart(for: nextItem)
        } catch {
            crossfadeTriggeredForCurrentTrack = true
        }
    }

    private func resolvedTitleAndRawArtist(for item: MediaItem) -> (title: String, rawArtist: String?) {
        let custom = customMetadataByPath[item.relativePath]
        let title = custom?.title ?? item.metadataTitle ?? titlesByPath[item.relativePath] ?? item.name
        let artist = custom?.artist ?? item.artist ?? artistsByPath[item.relativePath]
        return (title, artist)
    }

    private func syncWrappedSessionStart(for item: MediaItem) {
        let meta = resolvedTitleAndRawArtist(for: item)
        ListeningWrappedService.shared.beginOrResumeSession(
            for: item,
            resolvedTitle: meta.title,
            resolvedArtistTag: meta.rawArtist,
            isArtistVerified: isArtistVerified(for: item)
        )
    }

    private func syncWrappedHeartbeat() {
        guard isPlaying, let item = currentItem else { return }
        let meta = resolvedTitleAndRawArtist(for: item)
        ListeningWrappedService.shared.recordPlaybackHeartbeat(
            for: item,
            resolvedTitle: meta.title,
            resolvedArtistTag: meta.rawArtist,
            isArtistVerified: isArtistVerified(for: item),
            isPlaying: true
        )
    }

    private func setupRemoteCommands() {
        NowPlayingManager.setupRemoteCommands(
            onPlay: { [weak self] in self?.resume() },
            onPause: { [weak self] in self?.pause() },
            onNext: { [weak self] in self?.playNext() },
            onPrev: { [weak self] in self?.playPrevious() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSeek: { [weak self] time in self?.seek(to: time) },
            onLikeToggle: { [weak self] in
                guard let self, let item = self.currentItem, !item.relativePath.hasPrefix("__remote__/") else { return }
                self.toggleFavorite(item)
            },
            onChangeRate: { [weak self] rate in
                self?.setPlaybackRate(rate)
            }
        )
    }

    @MainActor
    private func loadMetadataAndThumbnails(for snapshot: [MediaItem]) async {
        for item in snapshot {
            if Task.isCancelled { return }
            let path = item.relativePath

            if let coverFile = customMetadataByPath[path]?.coverFileName,
               thumbnails[path] == nil,
               let data = try? Data(contentsOf: coversDirectoryURL.appendingPathComponent(coverFile)),
               let customImage = UIImage(data: data) {
                thumbnails[path] = customImage
            }

            let asset = AVURLAsset(url: item.fileURL)

            if durationsByPath[path] == nil {
                var resolvedSec: Double?
                if !item.prefersFFmpegEngine, let loadedDuration = try? await asset.load(.duration) {
                    let sec = CMTimeGetSeconds(loadedDuration)
                    if sec.isFinite, sec > 0 { resolvedSec = sec }
                }
                if resolvedSec == nil {
                    resolvedSec = await Task.detached(priority: .utility) {
                        FFmpegMediaService.probeMetadata(for: item.fileURL)?.durationSeconds
                    }.value
                }
                if let seconds = resolvedSec, seconds > 0 {
                    durationsByPath[path] = seconds
                    if let idx = items.firstIndex(where: { $0.relativePath == path }) {
                        items[idx].durationSeconds = seconds
                    }
                    if currentItem?.relativePath == path {
                        duration = seconds
                        updateNowPlayingInfo(for: items.first(where: { $0.relativePath == path }) ?? item)
                    }
                }
            }

            if !metadataLoadedPaths.contains(path) {
                let metadata = await extractMetadata(from: item.fileURL)
                metadataLoadedPaths.insert(path)
                var shouldRefreshNowPlaying = false

                if let image = metadata.artwork, thumbnails[path] == nil {
                    thumbnails[path] = image
                    shouldRefreshNowPlaying = true
                }

                if customMetadataByPath[path]?.title == nil,
                   titlesByPath[path] == nil,
                   metadata.title != item.name {
                    titlesByPath[path] = metadata.title
                    if let idx = items.firstIndex(where: { $0.relativePath == path }) {
                        items[idx].metadataTitle = metadata.title
                    }
                    if currentItem?.relativePath == path {
                        currentItem?.metadataTitle = metadata.title
                        shouldRefreshNowPlaying = true
                    }
                }

                if !item.isVideo,
                   customMetadataByPath[path]?.artist == nil,
                   metadata.artist != "Unknown Artist",
                   artistsByPath[path] == nil {
                    artistsByPath[path] = metadata.artist
                    if let idx = items.firstIndex(where: { $0.relativePath == path }) {
                        items[idx].artist = metadata.artist
                    }
                    if currentItem?.relativePath == path {
                        currentItem?.artist = metadata.artist
                        shouldRefreshNowPlaying = true
                    }
                }

                if shouldRefreshNowPlaying, currentItem?.relativePath == path {
                    updateNowPlayingInfo(for: currentItem ?? item)
                }
            }
        }
    }

    private static func diskSize(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in enumerator {
                let sz = (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(sz)
            }
        }
        return total
    }
}

private final class WeakManagerBox: @unchecked Sendable {
    weak var value: MediaManager?
    init(_ value: MediaManager) {
        self.value = value
    }
}

@MainActor
private final class KSMEPlayerBridge: MediaPlayerDelegate {
    private let managerBox: WeakManagerBox

    nonisolated init(manager: MediaManager) {
        self.managerBox = WeakManagerBox(manager)
    }

    func readyToPlay(player: some MediaPlayerProtocol) {
        managerBox.value?.handleFFmpegReady(player: player)
    }

    func changeLoadState(player: some MediaPlayerProtocol) {
        _ = player
    }

    func changeBuffering(player _: some MediaPlayerProtocol, progress: Int) {
        _ = progress
    }

    func playBack(player _: some MediaPlayerProtocol, loopCount: Int) {
        _ = loopCount
    }

    func finish(player: some MediaPlayerProtocol, error: Error?) {
        _ = player
        managerBox.value?.handleFFmpegFinish(error: error)
    }
}
