import AVFoundation
import Foundation
import Observation

final class MediaInterceptURLProtocol: URLProtocol, URLSessionDataDelegate {
    private static let handledKey = "MusicPlayerURLProtocolHandled"
    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    private var currentResponse: URLResponse?

    static let sharedCache = URLCache(
        memoryCapacity: 32 * 1024 * 1024,
        diskCapacity: 256 * 1024 * 1024,
        diskPath: "MusicPlayerMediaURLCache"
    )

    private lazy var internalSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = Self.sharedCache
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil,
              let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let path = request.url?.path.lowercased() ?? ""
        return path.hasSuffix(".mp4")
            || path.hasSuffix(".mov")
            || path.hasSuffix(".m4v")
            || path.hasSuffix(".m3u8")
            || path.hasSuffix(".mp3")
            || path.hasSuffix(".m4a")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let cached = Self.sharedCache.cachedResponse(for: request) {
            client?.urlProtocol(self, didReceive: cached.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: cached.data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        dataTask = internalSession.dataTask(with: mutable as URLRequest)
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        currentResponse = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if receivedData.count < 4 * 1024 * 1024 {
            receivedData.append(data)
        }
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let currentResponse, !receivedData.isEmpty, receivedData.count < 4 * 1024 * 1024 {
            let cached = CachedURLResponse(response: currentResponse, data: receivedData)
            Self.sharedCache.storeCachedResponse(cached, for: request)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

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
        config.urlCache = MediaInterceptURLProtocol.sharedCache
        config.protocolClasses = [MediaInterceptURLProtocol.self] + (config.protocolClasses ?? [])
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: delegateProxy, delegateQueue: nil)
    }()

    @ObservationIgnored private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.personal.musicplayer.hls.bg")
        config.urlCache = MediaInterceptURLProtocol.sharedCache
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegateProxy, delegateQueue: nil)
    }()

    private static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private struct DownloadMeta {
        let title: String
        let sourceURL: URL
        let maxDurationSeconds: Double?
        let isHLS: Bool
        let destinationFolder: String
    }

    func fetchHLSVariants(for url: URL, headers: [String: String]? = nil) async -> [HLSQualityVariant] {
        var mergedHeaders = headers ?? [:]
        if mergedHeaders["User-Agent"] == nil {
            mergedHeaders["User-Agent"] = Self.browserUserAgent
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": mergedHeaders])
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
        guard !activeDownloads.contains(where: { $0.sourceURL == url }) else {
            MediaManager.shared.statusMessage = "Download already in progress"
            return
        }

        let downloadID = UUID()
        let cleanTitle = sanitizedTitle(title, fallbackURL: url, defaultTitle: "Stream Video")

        var mergedHeaders = headers ?? [:]
        if mergedHeaders["User-Agent"] == nil {
            mergedHeaders["User-Agent"] = Self.browserUserAgent
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": mergedHeaders])

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
        if url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8") {
            startHLSDownload(
                from: url,
                title: title,
                headers: headers,
                destinationFolder: destinationFolder
            )
            return
        }

        guard !activeDownloads.contains(where: { $0.sourceURL == url }) else {
            MediaManager.shared.statusMessage = "Download already in progress"
            return
        }

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
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let task = directSession.downloadTask(with: request)
        taskToDownloadID[task.taskIdentifier] = downloadID
        activeURLTasks[downloadID] = task
        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: url, progress: 0, isHLS: false))
        task.resume()
        MediaManager.shared.statusMessage = "Downloading \(cleanTitle)..."
    }

    /// Resolves either a direct media link or an HTML webpage into a downloadable media stream.
    func resolveAndDownload(
        inputURLString: String,
        title: String? = nil,
        headers: [String: String]? = nil,
        maxDurationMinutes: Int = 0,
        destinationFolder: String = ""
    ) async {
        var normalized = inputURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }
        guard let url = URL(string: normalized), url.scheme?.hasPrefix("http") == true else {
            MediaManager.shared.errorMessage = "Please enter the correct link"
            return
        }

        let lower = url.absoluteString.lowercased()
        if url.pathExtension.lowercased() == "m3u8" || lower.contains(".m3u8") {
            startHLSDownload(from: url, title: title, headers: headers, destinationFolder: destinationFolder)
            return
        }

        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        headReq.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { headReq.setValue($0.value, forHTTPHeaderField: $0.key) }

        if let (_, resp) = try? await URLSession.shared.data(for: headReq),
           let mime = resp.mimeType?.lowercased(),
           !mime.contains("html") {
            if mime.contains("mpegurl") {
                startHLSDownload(from: url, title: title, headers: headers, destinationFolder: destinationFolder)
            } else {
                downloadDirectMedia(
                    from: url,
                    title: title,
                    headers: headers,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
            }
            return
        }

        var getReq = URLRequest(url: url)
        getReq.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { getReq.setValue($0.value, forHTTPHeaderField: $0.key) }

        guard let (data, resp) = try? await URLSession.shared.data(for: getReq),
              let mime = resp.mimeType?.lowercased() else {
            downloadDirectMedia(
                from: url,
                title: title,
                headers: headers,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder
            )
            return
        }

        if !mime.contains("html") {
            if mime.contains("mpegurl") {
                startHLSDownload(from: url, title: title, headers: headers, destinationFolder: destinationFolder)
            } else {
                downloadDirectMedia(
                    from: url,
                    title: title,
                    headers: headers,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
            }
            return
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            MediaManager.shared.errorMessage = "Could not read webpage HTML."
            return
        }

        let base = resp.url ?? url
        if let extracted = extractMediaURL(from: html, baseURL: base) {
            let pageTitle = (title?.isEmpty == false ? title : nil) ?? extractTitle(from: html)
            var mergedHeaders = headers ?? [:]
            mergedHeaders["Referer"] = base.absoluteString
            if extracted.pathExtension.lowercased() == "m3u8" || extracted.absoluteString.lowercased().contains(".m3u8") {
                startHLSDownload(from: extracted, title: pageTitle, headers: mergedHeaders, destinationFolder: destinationFolder)
            } else {
                downloadDirectMedia(
                    from: extracted,
                    title: pageTitle,
                    headers: mergedHeaders,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
            }
        } else {
            MediaManager.shared.errorMessage = "No direct media URL found in page HTML. Open the page in Browser and press Play so the live stream detector picks it up."
        }
    }

    func cancelDownload(id: UUID) {
        activeURLTasks[id]?.cancel()
        activeURLTasks.removeValue(forKey: id)
        downloadMeta.removeValue(forKey: id)
        activeDownloads.removeAll { $0.id == id }
    }

    private func extractTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return html[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractMediaURL(from html: String, baseURL: URL) -> URL? {
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"'](?:og:video(?::secure_url|:url)?|og:audio(?::url)?|twitter:player:stream)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<(?:video|audio|source)[^>]+(?:src|data-src)=[\"']([^\"']+)[\"']",
            "https?://[^\\s\"'<>\\\\]+\\.(?:mp4|mov|m4v|m3u8|mp3|m4a|aac|wav|flac)(?:\\?[^\\s\"'<>\\\\]*)?"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                let groupIdx = match.numberOfRanges > 1 ? 1 : 0
                guard let range = Range(match.range(at: groupIdx), in: html) else { continue }
                let raw = String(html[range]).replacingOccurrences(of: "\\/", with: "/")
                if raw.hasPrefix("blob:") || raw.hasPrefix("data:") { continue }
                if let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
                    return resolved
                }
            }
        }
        return nil
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

    fileprivate func handleFinishedDownload(
        taskIdentifier: Int,
        tempFileURL: URL,
        suggestedExtension: String,
        mimeType: String,
        statusCode: Int,
        isHLS: Bool
    ) {
        guard let id = taskToDownloadID.removeValue(forKey: taskIdentifier),
              let meta = downloadMeta.removeValue(forKey: id) else {
            try? FileManager.default.removeItem(at: tempFileURL)
            return
        }
        activeURLTasks.removeValue(forKey: id)
        activeDownloads.removeAll { $0.id == id }

        if !isHLS {
            if !(200...299).contains(statusCode) && statusCode != 0 {
                try? FileManager.default.removeItem(at: tempFileURL)
                MediaManager.shared.errorMessage = "Download blocked (HTTP \(statusCode)). Try playing the video in Browser first."
                return
            }
            if mimeType.contains("html") {
                try? FileManager.default.removeItem(at: tempFileURL)
                MediaManager.shared.errorMessage = "Server returned a webpage instead of media. Try playing inside the Browser."
                return
            }
        }

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
            LocalMediaCacheProxy.shared.refreshCacheSize()
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
                owner?.handleFinishedDownload(
                    taskIdentifier: tid,
                    tempFileURL: staged,
                    suggestedExtension: "movpkg",
                    mimeType: "application/vnd.apple.mpegurl",
                    statusCode: 200,
                    isHLS: true
                )
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
        let mime = downloadTask.response?.mimeType?.lowercased() ?? ""
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(responseExt)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor [weak owner] in
                owner?.handleFinishedDownload(
                    taskIdentifier: tid,
                    tempFileURL: staged,
                    suggestedExtension: responseExt,
                    mimeType: mime,
                    statusCode: statusCode,
                    isHLS: false
                )
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
        if let suggested = response?.suggestedFilename as NSString? {
            let ext = suggested.pathExtension.lowercased()
            if !ext.isEmpty && ext.count <= 6 && ext != "html" && ext != "php" {
                return ext
            }
        }
        if let urlExt = url?.pathExtension.lowercased(), !urlExt.isEmpty, urlExt.count <= 6, urlExt != "html", urlExt != "php" {
            return urlExt
        }
        switch response?.mimeType?.lowercased() ?? "" {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg": return "ogg"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default: return "mp4"
        }
    }
}
