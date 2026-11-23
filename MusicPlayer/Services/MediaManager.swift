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
    }

    private struct LibraryPersistedState: Codable {
        var likedPaths: [String] = []
        var recentPaths: [String] = []
        var upNextPaths: [String] = []
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
    var customMetadataByPath: [String: CustomTrackMetadata] = [:]

    var currentItem: MediaItem?
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var repeatMode: RepeatMode = .off
    var isShuffleEnabled = false

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

    private let docsURL = MediaItem.documentsDirectory
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

        items = loadedItems
        otherFiles = loadedOthers
        folders = loadedFolders

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

    func play(_ item: MediaItem, inPlaylist playlistID: UUID? = nil) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            errorMessage = "File not found: \(item.fileName)"
            loadLocalFiles()
            return
        }

        stopCurrentEngines()
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
    }

    func playRemoteStream(url: URL, title: String, headers: [String: String]? = nil, isVideo: Bool) {
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
            artist: url.host
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
            errorMessage = "Playback error: \(error.localizedDescription)"
            return
        }
        handlePlaybackEnded()
    }

    func togglePlayPause() {
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
            return
        }

        if isUsingEqualizerBackend {
            equalizerPlayer.resume()
            isPlaying = equalizerPlayer.isPlaying
            updateNowPlayingInfo(for: currentItem)
            return
        }

        guard let player else { return }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo(for: currentItem)
    }

    func pause() {
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
        stopCurrentEngines()
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
        if likedPaths.contains(item.relativePath) {
            likedPaths.remove(item.relativePath)
            statusMessage = "Removed from Favorites"
        } else {
            likedPaths.insert(item.relativePath)
            statusMessage = "Added to Favorites"
        }
        saveLibraryState()
    }

    func addToNextPlay(_ item: MediaItem) {
        upNextPaths.removeAll { $0 == item.relativePath }
        upNextPaths.insert(item.relativePath, at: 0)
        saveLibraryState()
        statusMessage = "Added to Next Play"
    }

    func addToQueue(_ item: MediaItem) {
        upNextPaths.append(item.relativePath)
        saveLibraryState()
        statusMessage = "Added to Up Next"
    }

    func removeFromUpNext(at offsets: IndexSet) {
        for idx in offsets.sorted(by: >) where upNextPaths.indices.contains(idx) {
            upNextPaths.remove(at: idx)
        }
        saveLibraryState()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNextPaths.move(fromOffsets: source, toOffset: destination)
        saveLibraryState()
    }

    func clearUpNext() {
        upNextPaths.removeAll()
        saveLibraryState()
    }

    private func popNextQueuedItem() -> MediaItem? {
        let byPath = Dictionary(items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        while !upNextPaths.isEmpty {
            let nextPath = upNextPaths.removeFirst()
            if let match = byPath[nextPath] {
                saveLibraryState()
                return match
            }
        }
        saveLibraryState()
        return nil
    }

    func playNext(fromQueueOnly: Bool = false) {
        if let queued = popNextQueuedItem() {
            play(queued, inPlaylist: activePlaylistID)
            return
        }

        let queue = activeQueue
        guard !queue.isEmpty else { return }

        if isShuffleEnabled, queue.count > 1 {
            let candidates = queue.filter { $0.id != currentItem?.id }
            if let randomNext = candidates.randomElement() {
                play(randomNext, inPlaylist: activePlaylistID)
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
        let queue = activeQueue
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
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
        removeCustomCover: Bool = false
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = customMetadataByPath[item.relativePath] ?? CustomTrackMetadata()

        entry.title = cleanTitle.isEmpty ? nil : cleanTitle
        entry.artist = cleanArtist.isEmpty ? nil : cleanArtist

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

        if entry.title == nil && entry.artist == nil && entry.coverFileName == nil {
            customMetadataByPath.removeValue(forKey: item.relativePath)
        } else {
            customMetadataByPath[item.relativePath] = entry
        }

        saveLibraryState()
        loadLocalFiles()
        if currentItem?.relativePath == item.relativePath,
           let updated = items.first(where: { $0.relativePath == item.relativePath }) {
            currentItem = updated
            updateNowPlayingInfo(for: updated)
        }
        statusMessage = "Updated track info"
    }

    @discardableResult
    func applyDownloadedMetadataAndPlaylist(
        for item: MediaItem,
        title: String? = nil,
        artist: String? = nil
    ) -> MediaItem {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleanTitle?.isEmpty == false) || (cleanArtist?.isEmpty == false) {
            var entry = customMetadataByPath[item.relativePath] ?? CustomTrackMetadata()
            if let cleanTitle, !cleanTitle.isEmpty { entry.title = cleanTitle }
            if let cleanArtist, !cleanArtist.isEmpty { entry.artist = cleanArtist }
            customMetadataByPath[item.relativePath] = entry
            saveLibraryState()
            loadLocalFiles()
        }

        let refreshedItem = items.first(where: { $0.relativePath == item.relativePath }) ?? item
        recordRecent(refreshedItem.relativePath)

        if AppSettings.isAutoAddDownloadsToPlaylistEnabled,
           let configuredID = AppSettings.storedTargetDownloadPlaylistID,
           let idx = playlists.firstIndex(where: { $0.id == configuredID }) {
            if !playlistContains(refreshedItem, in: playlists[idx]) {
                playlists[idx].itemFileNames.insert(refreshedItem.relativePath, at: 0)
                savePlaylists()
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
        statusMessage = "Created playlist \"\(trimmed)\""
        return playlist
    }

    func deletePlaylist(_ playlist: Playlist) {
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
        playlists[index].name = trimmed
        savePlaylists()
        statusMessage = "Renamed playlist to \"\(trimmed)\""
    }

    func playlistContains(_ item: MediaItem, in playlist: Playlist) -> Bool {
        let duplicateNames = duplicateLibraryFileNames()
        return playlist.itemFileNames.contains { playlistKeyMatches($0, item: item, duplicateNames: duplicateNames) }
    }

    func add(_ item: MediaItem, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if !playlistContains(item, in: playlists[index]) {
            playlists[index].itemFileNames.append(item.relativePath)
            savePlaylists()
            statusMessage = "Added to \"\(playlist.name)\""
        } else {
            statusMessage = "Already in \"\(playlist.name)\""
        }
    }

    func remove(_ item: MediaItem, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let duplicateNames = duplicateLibraryFileNames()
        let before = playlists[index].itemFileNames.count
        playlists[index].itemFileNames.removeAll { playlistKeyMatches($0, item: item, duplicateNames: duplicateNames) }
        if playlists[index].itemFileNames.count != before {
            savePlaylists()
            statusMessage = "Removed from \"\(playlist.name)\""
        }
    }

    func removeItems(at offsets: IndexSet, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let resolved = items(in: playlists[index])
        let duplicateNames = duplicateLibraryFileNames()
        let victims = offsets.compactMap { resolved.indices.contains($0) ? resolved[$0] : nil }
        playlists[index].itemFileNames.removeAll { key in
            victims.contains { playlistKeyMatches(key, item: $0, duplicateNames: duplicateNames) }
        }
        savePlaylists()
    }

    func moveItems(from source: IndexSet, to destination: Int, in playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        var resolvedPaths = items(in: playlists[index]).map(\.relativePath)
        resolvedPaths.move(fromOffsets: source, toOffset: destination)
        playlists[index].itemFileNames = resolvedPaths
        savePlaylists()
    }

    func playPlaylist(_ playlist: Playlist, startingAt startItem: MediaItem? = nil) {
        let playlistItems = items(in: playlist)
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

    func extractArchive(_ file: LocalFile) {
        let baseName = sanitizeName(file.name)
        let folderTitle = baseName.isEmpty ? "Extracted" : baseName
        let destURL = uniqueDestinationURL(for: folderTitle, inFolder: file.folderRelativePath)

        do {
            let count = try ZipExtractor.extract(archiveURL: file.fileURL, to: destURL)
            loadLocalFiles()
            statusMessage = "Extracted \(count) \(count == 1 ? "file" : "files") to \(destURL.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func images(inFolder folderPath: String) -> [LocalFile] {
        otherFiles
            .filter { $0.isImage && $0.folderRelativePath == folderPath }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    @MainActor
    func saveImagesFromWeb(_ imageURLs: [URL], folderName: String, referer: String? = nil) async {
        guard !imageURLs.isEmpty else {
            errorMessage = "No downloadable images found on this page."
            return
        }

        let cleanFolder = sanitizeName(folderName)
        let targetName = cleanFolder.isEmpty ? "Web Images" : String(cleanFolder.prefix(60))
        let folderURL = uniqueDestinationURL(for: targetName, inFolder: "")
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create images folder: \(error.localizedDescription)"
            return
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
        } else {
            try? FileManager.default.removeItem(at: folderURL)
            errorMessage = "Could not download images from this page."
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
    }

    private func loadLibraryState() {
        guard let data = try? Data(contentsOf: libraryStateFileURL),
              let state = try? JSONDecoder().decode(LibraryPersistedState.self, from: data) else {
            return
        }
        likedPaths = Set(state.likedPaths)
        recentPaths = state.recentPaths
        upNextPaths = state.upNextPaths
        customMetadataByPath = state.customMetadataByPath
        lastPlaylistID = state.lastPlaylistID
        repeatMode = state.repeatMode
    }

    private func saveLibraryState() {
        let state = LibraryPersistedState(
            likedPaths: Array(likedPaths),
            recentPaths: recentPaths,
            upNextPaths: upNextPaths,
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

        var playlistsChanged = false
        for idx in playlists.indices {
            let before = playlists[idx].itemFileNames.count
            playlists[idx].itemFileNames.removeAll(where: predicate)
            if playlists[idx].itemFileNames.count != before {
                playlistsChanged = true
            }
        }
        if playlistsChanged { savePlaylists() }
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
        if repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }

        if let queued = popNextQueuedItem() {
            play(queued, inPlaylist: activePlaylistID)
            return
        }

        if let currentItem, (!currentItem.isVideo || activePlaylistID != nil), activeQueue.count > 1 {
            playNext(fromQueueOnly: repeatMode == .off)
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
        let resolvedArtist = custom?.artist ?? item.artist ?? artistsByPath[item.relativePath] ?? (item.isVideo ? "Music Player Video" : "Unknown Artist")
        NowPlayingManager.updateNowPlayingInfo(
            title: resolvedTitle,
            artist: resolvedArtist,
            duration: duration,
            elapsed: currentTime,
            artworkImage: thumbnails[item.relativePath],
            playbackRate: isPlaying ? Double(playbackRate) : 0.0,
            mediaType: item.isVideo ? .movie : .music
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
        }

        equalizerPlayer.onPlaybackEnded = { [weak self] in
            guard let self, self.isUsingEqualizerBackend else { return }
            self.handlePlaybackEnded()
        }
    }

    private func setupRemoteCommands() {
        NowPlayingManager.setupRemoteCommands(
            onPlay: { [weak self] in self?.resume() },
            onPause: { [weak self] in self?.pause() },
            onNext: { [weak self] in self?.playNext() },
            onPrev: { [weak self] in self?.playPrevious() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSeek: { [weak self] time in self?.seek(to: time) }
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
