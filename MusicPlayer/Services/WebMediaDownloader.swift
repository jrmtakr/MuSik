import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class WebMediaDownloader {
    private(set) var activeDownloads: [BrowserDownloadItem] = []

    @ObservationIgnored private var taskToDownloadID: [Int: UUID] = [:]
    @ObservationIgnored private var downloadMeta: [UUID: DownloadMeta] = [:]
    @ObservationIgnored private var activeURLTasks: [UUID: URLSessionTask] = [:]

    @ObservationIgnored private lazy var delegateProxy = DownloadDelegateProxy(owner: self)

    @ObservationIgnored private lazy var directSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: delegateProxy, delegateQueue: nil)
    }()

    @ObservationIgnored private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.personal.musicplayer.hls.bg")
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegateProxy, delegateQueue: nil)
    }()

    private struct DownloadMeta {
        let title: String
        let sourceURL: URL
        let maxDurationSeconds: Double?
        let isHLS: Bool
        let destinationFolder: String
    }

    func fetchHLSVariants(for url: URL, headers: [String: String]? = nil) async -> [HLSQualityVariant] {
        var options: [String: Any] = [:]
        if let headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        var list = [HLSQualityVariant(id: "auto", label: "Auto (Best Available)", width: 0, height: 0, peakBitrate: 0)]
        guard let variants = try? await asset.load(.variants) else { return list }

        var seen = Set<String>()
        for (idx, variant) in variants.enumerated() {
            let bitrate = variant.peakBitRate ?? variant.averageBitRate ?? 0
            let size = variant.videoAttributes?.presentationSize ?? .zero
            let width = Int(size.width)
            let height = Int(size.height)
            let mbps = bitrate > 0 ? String(format: "%.1f Mbps", bitrate / 1_000_000.0) : ""
            let res = height > 0 ? "\(height)p" : "Quality \(idx + 1)"
            let label = mbps.isEmpty ? res : "\(res) • \(mbps)"
            let key = "\(width)x\(height)-\(Int(bitrate))"
            if seen.insert(key).inserted {
                list.append(
                    HLSQualityVariant(
                        id: "v\(idx)",
                        label: label,
                        width: width,
                        height: height,
                        peakBitrate: bitrate
                    )
                )
            }
        }
        return list
    }

    func startHLSDownload(
        from url: URL,
        title: String? = nil,
        minimumBitrate: Double? = nil,
        headers: [String: String]? = nil,
        destinationFolder: String = ""
    ) {
        guard !activeDownloads.contains(where: { $0.sourceURL == url }) else { return }

        let downloadID = UUID()
        let cleanTitle = sanitizedTitle(title, fallbackURL: url, defaultTitle: "Stream Video")

        var assetOptions: [String: Any] = [:]
        if let headers, !headers.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: assetOptions)

        var taskOptions: [String: Any] = [:]
        if let minimumBitrate, minimumBitrate > 0 {
            taskOptions[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = NSNumber(value: minimumBitrate)
        }

        guard let task = hlsSession.makeAssetDownloadTask(
            asset: asset,
            assetTitle: cleanTitle,
            assetArtworkData: nil,
            options: taskOptions.isEmpty ? nil : taskOptions
        ) else {
            MediaManager.shared.errorMessage = "Could not start HLS download."
            return
        }

        downloadMeta[downloadID] = DownloadMeta(
            title: cleanTitle,
            sourceURL: url,
            maxDurationSeconds: nil,
            isHLS: true,
            destinationFolder: destinationFolder
        )
        taskToDownloadID[task.taskIdentifier] = downloadID
        activeURLTasks[downloadID] = task
        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: url, progress: 0, isHLS: true))
        task.resume()
        MediaManager.shared.statusMessage = "Downloading \(cleanTitle)..."
    }

    func downloadDirectMedia(
        from url: URL,
        title: String? = nil,
        headers: [String: String]? = nil,
        maxDurationMinutes: Int = 0,
        destinationFolder: String = ""
    ) {
        if url.pathExtension.lowercased() == "m3u8" {
            startHLSDownload(
                from: url,
                title: title,
                headers: headers,
                destinationFolder: destinationFolder
            )
            return
        }

        guard !activeDownloads.contains(where: { $0.sourceURL == url }) else { return }

        let downloadID = UUID()
        let cleanTitle = sanitizedTitle(title, fallbackURL: url, defaultTitle: "Media")
        let maxSec = maxDurationMinutes > 0 ? Double(maxDurationMinutes * 60) : nil

        downloadMeta[downloadID] = DownloadMeta(
            title: cleanTitle,
            sourceURL: url,
            maxDurationSeconds: maxSec,
            isHLS: false,
            destinationFolder: destinationFolder
        )

        var request = URLRequest(url: url)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let task = directSession.downloadTask(with: request)
        taskToDownloadID[task.taskIdentifier] = downloadID
        activeURLTasks[downloadID] = task
        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: url, progress: 0, isHLS: false))
        task.resume()
        MediaManager.shared.statusMessage = "Downloading \(cleanTitle)..."
    }

    func cancelDownload(id: UUID) {
        activeURLTasks[id]?.cancel()
        activeURLTasks.removeValue(forKey: id)
        downloadMeta.removeValue(forKey: id)
        activeDownloads.removeAll { $0.id == id }
    }

    private func sanitizedTitle(_ raw: String?, fallbackURL: URL, defaultTitle: String) -> String {
        let candidate = (raw?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (fallbackURL.deletingPathExtension().lastPathComponent.isEmpty
                ? defaultTitle
                : fallbackURL.deletingPathExtension().lastPathComponent)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = candidate.components(separatedBy: invalid).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? defaultTitle : String(cleaned.prefix(80))
    }

    fileprivate func updateProgress(taskIdentifier: Int, fraction: Double) {
        guard let id = taskToDownloadID[taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[idx].progress = min(max(fraction, 0), 1)
    }

    fileprivate func handleFinishedDownload(taskIdentifier: Int, tempFileURL: URL, suggestedExtension: String, isHLS: Bool) {
        guard let id = taskToDownloadID.removeValue(forKey: taskIdentifier),
              let meta = downloadMeta.removeValue(forKey: id) else {
            try? FileManager.default.removeItem(at: tempFileURL)
            return
        }
        activeURLTasks.removeValue(forKey: id)
        activeDownloads.removeAll { $0.id == id }

        Task {
            if let limit = meta.maxDurationSeconds, !isHLS {
                let asset = AVURLAsset(url: tempFileURL)
                if let dur = try? await asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(dur)
                    if seconds.isFinite, seconds > limit {
                        try? FileManager.default.removeItem(at: tempFileURL)
                        MediaManager.shared.errorMessage = "Skipped \"\(meta.title)\" (exceeds \(Int(limit / 60)) min limit)."
                        return
                    }
                }
            }

            let ext = isHLS ? "movpkg" : suggestedExtension
            let preferredName = ext.isEmpty ? meta.title : "\(meta.title).\(ext)"
            MediaManager.shared.importTemporaryFile(
                from: tempFileURL,
                preferredFileName: preferredName,
                inFolder: meta.destinationFolder
            )
        }
    }

    fileprivate func handleFailedDownload(taskIdentifier: Int, error: Error) {
        if let id = taskToDownloadID.removeValue(forKey: taskIdentifier) {
            downloadMeta.removeValue(forKey: id)
            activeURLTasks.removeValue(forKey: id)
            activeDownloads.removeAll { $0.id == id }
        }
        let nsErr = error as NSError
        if nsErr.code != NSURLErrorCancelled {
            MediaManager.shared.errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}

private final class DownloadDelegateProxy: NSObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate {
    weak var owner: WebMediaDownloader?

    init(owner: WebMediaDownloader) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard total.isFinite, total > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.timeRangeValue.duration) }
        let fraction = min(max(loaded / total, 0), 1)
        let tid = assetDownloadTask.taskIdentifier
        Task { @MainActor [weak owner] in
            owner?.updateProgress(taskIdentifier: tid, fraction: fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tid = assetDownloadTask.taskIdentifier
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).movpkg")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor [weak owner] in
                owner?.handleFinishedDownload(taskIdentifier: tid, tempFileURL: staged, suggestedExtension: "movpkg", isHLS: true)
            }
        } catch {
            Task { @MainActor [weak owner] in
                owner?.handleFailedDownload(taskIdentifier: tid, error: error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let tid = downloadTask.taskIdentifier
        Task { @MainActor [weak owner] in
            owner?.updateProgress(taskIdentifier: tid, fraction: fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tid = downloadTask.taskIdentifier
        let responseExt = Self.extensionFrom(response: downloadTask.response, url: downloadTask.originalRequest?.url)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(responseExt)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor [weak owner] in
                owner?.handleFinishedDownload(taskIdentifier: tid, tempFileURL: staged, suggestedExtension: responseExt, isHLS: false)
            }
        } catch {
            Task { @MainActor [weak owner] in
                owner?.handleFailedDownload(taskIdentifier: tid, error: error)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let tid = task.taskIdentifier
        Task { @MainActor [weak owner] in
            owner?.handleFailedDownload(taskIdentifier: tid, error: error)
        }
    }

    private static func extensionFrom(response: URLResponse?, url: URL?) -> String {
        if let urlExt = url?.pathExtension.lowercased(), !urlExt.isEmpty, urlExt.count <= 6 {
            return urlExt
        }
        switch response?.mimeType?.lowercased() ?? "" {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default: return "mp4"
        }
    }
}
