import AVFoundation
import CommonCrypto
import Foundation
import Observation

final class MediaInterceptURLProtocol: URLProtocol, URLSessionDataDelegate {
    private static let handledKey = "MusicPlayerURLProtocolHandled"
    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    private var currentResponse: URLResponse?

    static let sharedCache = URLCache(
        memoryCapacity: 48 * 1024 * 1024,
        diskCapacity: 512 * 1024 * 1024,
        diskPath: "MusicPlayerMediaURLCache"
    )

    private static let interceptExtensions: Set<String> = [
        "mp4", "mov", "m4v", "m3u8", "ts", "mkv", "avi", "webm", "flv", "wmv",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "wma"
    ]

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
        let ext = request.url?.pathExtension.lowercased() ?? ""
        return interceptExtensions.contains(ext)
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
        if receivedData.count < 32 * 1024 * 1024 {
            receivedData.append(data)
        }
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let currentResponse, !receivedData.isEmpty, receivedData.count < 32 * 1024 * 1024 {
            let cached = CachedURLResponse(response: currentResponse, data: receivedData)
            Self.sharedCache.storeCachedResponse(cached, for: request)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct CompletedCacheEvent: Equatable {
    let eventID: UUID
    let item: MediaItem
    let sourceURL: URL

    static func == (lhs: CompletedCacheEvent, rhs: CompletedCacheEvent) -> Bool {
        lhs.eventID == rhs.eventID
    }
}

struct FailedCacheEvent: Equatable {
    let eventID: UUID
    let sourceURL: URL?
    let message: String

    static func == (lhs: FailedCacheEvent, rhs: FailedCacheEvent) -> Bool {
        lhs.eventID == rhs.eventID
    }
}

@MainActor
@Observable
final class WebMediaDownloader {
    private(set) var activeDownloads: [BrowserDownloadItem] = []
    var lastCompletedMediaItem: MediaItem?
    var lastCompletedCacheEvent: CompletedCacheEvent?
    var lastFailedCacheEvent: FailedCacheEvent?

    @ObservationIgnored private var taskToDownloadID: [Int: UUID] = [:]
    @ObservationIgnored private var downloadMeta: [UUID: DownloadMeta] = [:]
    @ObservationIgnored private var activeURLTasks: [UUID: URLSessionTask] = [:]
    @ObservationIgnored private var activeAsyncTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private lazy var delegateProxy = DownloadDelegateProxy(owner: self)

    @ObservationIgnored lazy var browserSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = MediaInterceptURLProtocol.sharedCache
        config.protocolClasses = [MediaInterceptURLProtocol.self] + (config.protocolClasses ?? [])
        config.waitsForConnectivity = true
        config.httpShouldSetCookies = true
        return URLSession(configuration: config, delegate: delegateProxy, delegateQueue: nil)
    }()

    @ObservationIgnored private lazy var ephemeralDataSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = MediaInterceptURLProtocol.sharedCache
        config.protocolClasses = [MediaInterceptURLProtocol.self] + (config.protocolClasses ?? [])
        config.waitsForConnectivity = true
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    @ObservationIgnored private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.personal.musicplayer.hls.bg")
        config.urlCache = MediaInterceptURLProtocol.sharedCache
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegateProxy, delegateQueue: nil)
    }()

    nonisolated static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private struct DownloadMeta {
        let title: String
        let artist: String?
        let sourceURL: URL
        let maxDurationSeconds: Double?
        let maxDurationMinutes: Int
        let isHLS: Bool
        let destinationFolder: String
        let fallbackStreams: [DetectedBrowserMedia]
    }

    private struct ParsedHLSMedia {
        struct Segment {
            let url: URL
            let duration: Double
            let sequence: Int
            let keyMethod: String?
            let keyURI: URL?
            let ivData: Data?
        }

        let isMaster: Bool
        let variants: [HLSQualityVariant]
        let audioGroupURLs: [String: URL]
        let mapURL: URL?
        let segments: [Segment]
        let totalDuration: Double
        let hasUnsupportedEncryption: Bool
        let isLiveWithoutEndList: Bool
    }

    init() {
        URLProtocol.registerClass(MediaInterceptURLProtocol.self)
    }

    // MARK: - Public API

    func fetchHLSVariants(for url: URL, headers: [String: String]? = nil) async -> [HLSQualityVariant] {
        var merged = enrichedHeaders(headers, for: url)

        if let text = await fetchText(from: url, headers: merged) {
            let parsed = parseM3U8(text: text, baseURL: url)
            if parsed.isMaster && !parsed.variants.isEmpty {
                var list = [HLSQualityVariant(id: "auto", label: "Auto (Best Available)", width: 0, height: 0, peakBitrate: 0, variantURL: nil)]
                list.append(contentsOf: parsed.variants)
                return list
            }
        }

        merged["User-Agent"] = merged["User-Agent"] ?? Self.browserUserAgent
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": merged])
        var list = [HLSQualityVariant(id: "auto", label: "Auto (Best Available)", width: 0, height: 0, peakBitrate: 0, variantURL: nil)]
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
                        peakBitrate: bitrate,
                        variantURL: nil
                    )
                )
            }
        }
        return list
    }

    func cacheMediaStream(
        _ media: DetectedBrowserMedia,
        fallbackStreams: [DetectedBrowserMedia] = [],
        maxDurationMinutes: Int = 0,
        destinationFolder: String = ""
    ) {
        var reqHeaders = media.customHeaders ?? [:]
        if let ref = media.referer, !ref.isEmpty, reqHeaders["Referer"] == nil {
            reqHeaders["Referer"] = ref
        }
        if media.isHLS {
            startHLSDownload(
                from: media.url,
                title: media.title,
                artist: media.author,
                headers: reqHeaders,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder,
                fallbackStreams: fallbackStreams
            )
        } else if let pairedAudio = media.pairedAudioURL {
            downloadMuxedVideoAndAudio(
                videoURL: media.url,
                audioURL: pairedAudio,
                title: media.title,
                artist: media.author,
                headers: reqHeaders,
                knownDurationSeconds: media.durationSeconds,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder,
                fallbackStreams: fallbackStreams
            )
        } else {
            downloadDirectMedia(
                from: media.url,
                title: media.title,
                artist: media.author,
                headers: reqHeaders,
                knownDurationSeconds: media.durationSeconds,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder,
                fallbackStreams: fallbackStreams
            )
        }
    }

    func startHLSDownload(
        from url: URL,
        selectedVariantURL: URL? = nil,
        title: String? = nil,
        artist: String? = nil,
        minimumBitrate: Double? = nil,
        headers: [String: String]? = nil,
        maxDurationMinutes: Int = 0,
        destinationFolder: String = "",
        fallbackStreams: [DetectedBrowserMedia] = []
    ) {
        let targetURL = selectedVariantURL ?? url
        guard !activeDownloads.contains(where: { $0.sourceURL == url || $0.sourceURL == targetURL }) else {
            MediaManager.shared.statusMessage = "Download already in progress"
            return
        }

        let downloadID = UUID()
        let cleanTitle = sanitizedTitle(title, fallbackURL: url, defaultTitle: "Stream Video")
        let mergedHeaders = enrichedHeaders(headers, for: targetURL)
        let maxSec = maxDurationMinutes > 0 ? Double(maxDurationMinutes * 60) : nil

        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: url, progress: 0, isHLS: true))
        MediaManager.shared.statusMessage = "Downloading \(cleanTitle)..."

        let asyncTask = Task {
            let handledBySegmentPipeline = await downloadHLSWithSegments(
                downloadID: downloadID,
                playlistURL: targetURL,
                cleanTitle: cleanTitle,
                artist: artist,
                minimumBitrate: minimumBitrate,
                headers: mergedHeaders,
                maxDurationSeconds: maxSec,
                destinationFolder: destinationFolder
            )
            activeAsyncTasks.removeValue(forKey: downloadID)

            if !handledBySegmentPipeline && !Task.isCancelled {
                // Remove placeholder row before delegating to AVAssetDownloadURLSession fallback
                activeDownloads.removeAll { $0.id == downloadID }
                startAppleAVAssetHLSDownload(
                    from: targetURL,
                    cleanTitle: cleanTitle,
                    artist: artist,
                    minimumBitrate: minimumBitrate,
                    headers: mergedHeaders,
                    maxDurationSeconds: maxSec,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder,
                    fallbackStreams: fallbackStreams
                )
            }
        }
        activeAsyncTasks[downloadID] = asyncTask
    }

    func downloadMuxedVideoAndAudio(
        videoURL: URL,
        audioURL: URL,
        title: String? = nil,
        artist: String? = nil,
        headers: [String: String]? = nil,
        knownDurationSeconds: Double? = nil,
        maxDurationMinutes: Int = 0,
        destinationFolder: String = "",
        fallbackStreams: [DetectedBrowserMedia] = []
    ) {
        let cleanVideo = cleanedStreamURLIfRangeFragment(videoURL)
        let cleanAudio = cleanedStreamURLIfRangeFragment(audioURL)
        let cleanTitle = sanitizedTitle(title, fallbackURL: cleanVideo, defaultTitle: "Video")

        if let maxMin = maxDurationMinutes > 0 ? maxDurationMinutes : nil,
           let known = knownDurationSeconds, known.isFinite, known > 0,
           known > Double(maxMin * 60) {
            recordFailedDownload(
                sourceURL: cleanVideo,
                message: "Skipped \"\(cleanTitle)\" (exceeds \(maxMin) min limit)."
            )
            return
        }

        guard !activeDownloads.contains(where: { $0.sourceURL == cleanVideo }) else {
            MediaManager.shared.statusMessage = "Download already in progress"
            return
        }

        let downloadID = UUID()
        let mergedHeaders = enrichedHeaders(headers, for: cleanVideo)
        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: cleanVideo, progress: 0, isHLS: false))
        MediaManager.shared.statusMessage = "Downloading HD \(cleanTitle)..."

        let session = ephemeralDataSession
        let asyncTask = Task {
            defer {
                activeAsyncTasks.removeValue(forKey: downloadID)
                activeDownloads.removeAll { $0.id == downloadID }
            }

            async let videoData = fetchTempFile(from: cleanVideo, ext: "mp4", headers: mergedHeaders, using: session)
            updateProgress(downloadID: downloadID, fraction: 0.25)
            async let audioData = fetchTempFile(from: cleanAudio, ext: "m4a", headers: mergedHeaders, using: session)

            guard let tempVideo = await videoData else {
                if !Task.isCancelled {
                    tryNextFallbackOrFail(
                        fallbacks: fallbackStreams,
                        maxDurationMinutes: maxDurationMinutes,
                        destinationFolder: destinationFolder,
                        sourceURL: cleanVideo,
                        failureMessage: "Could not download HD video track."
                    )
                }
                return
            }
            updateProgress(downloadID: downloadID, fraction: 0.75)
            guard let tempAudio = await audioData else {
                try? FileManager.default.removeItem(at: tempVideo)
                if !Task.isCancelled {
                    tryNextFallbackOrFail(
                        fallbacks: fallbackStreams,
                        maxDurationMinutes: maxDurationMinutes,
                        destinationFolder: destinationFolder,
                        sourceURL: cleanVideo,
                        failureMessage: "Could not download audio track."
                    )
                }
                return
            }
            defer {
                try? FileManager.default.removeItem(at: tempVideo)
                try? FileManager.default.removeItem(at: tempAudio)
            }
            if Task.isCancelled { return }

            let muxedTemp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            let ok = await Task.detached(priority: .userInitiated) {
                FFmpegMediaService.muxVideoAndAudioToMP4(videoURL: tempVideo, audioURL: tempAudio, outputURL: muxedTemp)
            }.value
            updateProgress(downloadID: downloadID, fraction: 0.95)

            if ok {
                if let saved = MediaManager.shared.importTemporaryFile(
                    from: muxedTemp,
                    preferredFileName: "\(cleanTitle).mp4",
                    inFolder: destinationFolder
                ) {
                    let updated = MediaManager.shared.applyDownloadedMetadataAndPlaylist(for: saved, title: title ?? cleanTitle, artist: artist)
                    recordCompletedDownload(updated, sourceURL: cleanVideo)
                } else {
                    tryNextFallbackOrFail(
                        fallbacks: fallbackStreams,
                        maxDurationMinutes: maxDurationMinutes,
                        destinationFolder: destinationFolder,
                        sourceURL: cleanVideo,
                        failureMessage: "Could not save muxed video."
                    )
                }
            } else {
                try? FileManager.default.removeItem(at: muxedTemp)
                tryNextFallbackOrFail(
                    fallbacks: fallbackStreams,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder,
                    sourceURL: cleanVideo,
                    failureMessage: "Could not mux video & audio tracks into MP4."
                )
            }
        }
        activeAsyncTasks[downloadID] = asyncTask
    }

    nonisolated private func fetchTempFile(
        from url: URL,
        ext: String,
        headers: [String: String],
        using session: URLSession
    ) async -> URL? {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.timeoutInterval = 120
        guard let (tempURL, resp) = try? await session.download(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        let mime = resp.mimeType?.lowercased() ?? ""
        if mime.contains("html") {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    func downloadDirectMedia(
        from url: URL,
        title: String? = nil,
        artist: String? = nil,
        headers: [String: String]? = nil,
        knownDurationSeconds: Double? = nil,
        maxDurationMinutes: Int = 0,
        destinationFolder: String = "",
        fallbackStreams: [DetectedBrowserMedia] = []
    ) {
        if let maxMin = maxDurationMinutes > 0 ? maxDurationMinutes : nil,
           let known = knownDurationSeconds, known.isFinite, known > 0,
           known > Double(maxMin * 60) {
            let clean = sanitizedTitle(title, fallbackURL: url, defaultTitle: "Media")
            recordFailedDownload(
                sourceURL: url,
                message: "Skipped \"\(clean)\" (exceeds \(maxMin) min limit)."
            )
            return
        }

        if isHLSURL(url) {
            startHLSDownload(
                from: url,
                title: title,
                artist: artist,
                headers: headers,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder,
                fallbackStreams: fallbackStreams
            )
            return
        }

        let normalizedURL = cleanedStreamURLIfRangeFragment(url)

        guard !activeDownloads.contains(where: { $0.sourceURL == normalizedURL || $0.sourceURL == url }) else {
            MediaManager.shared.statusMessage = "Download already in progress"
            return
        }

        let downloadID = UUID()
        let cleanTitle = sanitizedTitle(title, fallbackURL: normalizedURL, defaultTitle: "Media")
        let maxSec = maxDurationMinutes > 0 ? Double(maxDurationMinutes * 60) : nil
        let mergedHeaders = enrichedHeaders(headers, for: normalizedURL)

        if let maxSec, knownDurationSeconds == nil {
            let probeTask = Task {
                let probedDuration: Double? = await Task.detached(priority: .utility) {
                    if let info = FFmpegMediaService.probeMetadata(for: normalizedURL, headers: mergedHeaders),
                       let dur = info.durationSeconds, dur > 0 {
                        return dur
                    }
                    let asset = AVURLAsset(url: normalizedURL, options: ["AVURLAssetHTTPHeaderFieldsKey": mergedHeaders])
                    if let dur = try? await asset.load(.duration) {
                        let sec = CMTimeGetSeconds(dur)
                        if sec.isFinite, sec > 0 { return sec }
                    }
                    return nil
                }.value

                if Task.isCancelled { return }
                if let probedDuration, probedDuration > maxSec {
                    activeDownloads.removeAll { $0.id == downloadID }
                    activeAsyncTasks.removeValue(forKey: downloadID)
                    recordFailedDownload(
                        sourceURL: normalizedURL,
                        message: "Skipped \"\(cleanTitle)\" (exceeds \(maxDurationMinutes) min limit)."
                    )
                    return
                }
                activeAsyncTasks.removeValue(forKey: downloadID)
                enqueueDirectDownloadTask(
                    downloadID: downloadID,
                    url: normalizedURL,
                    cleanTitle: cleanTitle,
                    artist: artist,
                    headers: mergedHeaders,
                    maxDurationSeconds: maxSec,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder,
                    fallbackStreams: fallbackStreams
                )
            }
            activeAsyncTasks[downloadID] = probeTask
            activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: normalizedURL, progress: 0, isHLS: false))
            MediaManager.shared.statusMessage = "Checking \(cleanTitle)..."
            return
        }

        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: normalizedURL, progress: 0, isHLS: false))
        enqueueDirectDownloadTask(
            downloadID: downloadID,
            url: normalizedURL,
            cleanTitle: cleanTitle,
            artist: artist,
            headers: mergedHeaders,
            maxDurationSeconds: maxSec,
            maxDurationMinutes: maxDurationMinutes,
            destinationFolder: destinationFolder,
            fallbackStreams: fallbackStreams
        )
    }

    func saveBlobData(
        _ data: Data,
        fileName: String,
        mimeType: String,
        maxDurationMinutes: Int = 0,
        destinationFolder: String = ""
    ) {
        guard !data.isEmpty else { return }
        let ext = Self.extensionFor(mimeType: mimeType, fallbackName: fileName)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: tempURL, options: [.atomic])
            Task {
                if maxDurationMinutes > 0 {
                    let dur = await resolveLocalDuration(at: tempURL)
                    if let dur, dur > Double(maxDurationMinutes * 60) {
                        try? FileManager.default.removeItem(at: tempURL)
                        MediaManager.shared.errorMessage = "Skipped \"\(fileName)\" (exceeds \(maxDurationMinutes) min limit)."
                        return
                    }
                }
                let baseName = sanitizedTitle((fileName as NSString).deletingPathExtension, fallbackURL: tempURL, defaultTitle: "WebMedia")
                let preferredName = "\(baseName).\(ext)"
                if let saved = MediaManager.shared.importTemporaryFile(
                    from: tempURL,
                    preferredFileName: preferredName,
                    inFolder: destinationFolder
                ) {
                    let updated = MediaManager.shared.applyDownloadedMetadataAndPlaylist(for: saved, title: baseName, artist: nil)
                    recordCompletedDownload(updated, sourceURL: tempURL)
                }
            }
        } catch {
            recordFailedDownload(sourceURL: tempURL, message: "Could not save media: \(error.localizedDescription)")
        }
    }

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
            recordFailedDownload(sourceURL: nil, message: "Please enter the correct link")
            return
        }

        if YouTubeStreamResolver.isYouTubeURL(url),
           YouTubeStreamResolver.extractVideoID(from: url) != nil {
            MediaManager.shared.statusMessage = "Resolving YouTube stream..."
            if let ytResult = await YouTubeStreamResolver.resolveStreams(
                for: url,
                cookiesHeader: headers?["Cookie"],
                referer: headers?["Referer"]
            ), !ytResult.streams.isEmpty {
                let videoStreams = ytResult.streams.filter { !$0.isAudio }
                let ordered = videoStreams.isEmpty ? ytResult.streams : videoStreams
                if let primary = ordered.first {
                    let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? ytResult.title
                    let patchedPrimary = DetectedBrowserMedia(
                        url: primary.url,
                        pairedAudioURL: primary.pairedAudioURL,
                        isHLS: primary.isHLS,
                        isAudio: primary.isAudio,
                        title: resolvedTitle,
                        author: ytResult.author ?? primary.author,
                        qualityLabel: primary.qualityLabel,
                        referer: primary.referer,
                        customHeaders: primary.customHeaders,
                        durationSeconds: ytResult.durationSeconds ?? primary.durationSeconds,
                        isActivelyPlaying: primary.isActivelyPlaying
                    )
                    cacheMediaStream(
                        patchedPrimary,
                        fallbackStreams: Array(ordered.dropFirst()),
                        maxDurationMinutes: maxDurationMinutes,
                        destinationFolder: destinationFolder
                    )
                    return
                }
            }
        }

        let mergedHeaders = enrichedHeaders(headers, for: url)
        if isHLSURL(url) {
            startHLSDownload(
                from: url,
                title: title,
                headers: mergedHeaders,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder
            )
            return
        }

        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        mergedHeaders.forEach { headReq.setValue($0.value, forHTTPHeaderField: $0.key) }

        if let (_, resp) = try? await ephemeralDataSession.data(for: headReq),
           let mime = resp.mimeType?.lowercased(),
           !mime.contains("html") {
            if mime.contains("mpegurl") {
                startHLSDownload(
                    from: url,
                    title: title,
                    headers: mergedHeaders,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
                return
            }
            if !mime.contains("text/plain") {
                downloadDirectMedia(
                    from: url,
                    title: title,
                    headers: mergedHeaders,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
                return
            }
        }

        var getReq = URLRequest(url: url)
        mergedHeaders.forEach { getReq.setValue($0.value, forHTTPHeaderField: $0.key) }

        guard let (data, resp) = try? await ephemeralDataSession.data(for: getReq),
              let mime = resp.mimeType?.lowercased() else {
            downloadDirectMedia(
                from: url,
                title: title,
                headers: mergedHeaders,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder
            )
            return
        }

        let prefix = String(data: data.prefix(256), encoding: .utf8) ?? ""
        if mime.contains("mpegurl") || prefix.contains("#EXTM3U") {
            startHLSDownload(
                from: url,
                title: title,
                headers: mergedHeaders,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder
            )
            return
        }

        if !mime.contains("html") {
            downloadDirectMedia(
                from: url,
                title: title,
                headers: mergedHeaders,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder
            )
            return
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            MediaManager.shared.errorMessage = "Could not read webpage HTML."
            return
        }

        let base = resp.url ?? url
        if let extracted = extractMediaURL(from: html, baseURL: base) {
            let pageTitle = (title?.isEmpty == false ? title : nil) ?? extractTitle(from: html)
            var nextHeaders = enrichedHeaders(headers, for: extracted)
            nextHeaders["Referer"] = base.absoluteString
            if isHLSURL(extracted) {
                startHLSDownload(
                    from: extracted,
                    title: pageTitle,
                    headers: nextHeaders,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
            } else {
                downloadDirectMedia(
                    from: extracted,
                    title: pageTitle,
                    headers: nextHeaders,
                    maxDurationMinutes: maxDurationMinutes,
                    destinationFolder: destinationFolder
                )
            }
        } else {
            MediaManager.shared.errorMessage = "No direct media URL found in page HTML. Open the page in Browser and press Play so the live stream detector picks it up."
        }
    }

    func cancelDownload(id: UUID) {
        activeAsyncTasks[id]?.cancel()
        activeAsyncTasks.removeValue(forKey: id)
        activeURLTasks[id]?.cancel()
        activeURLTasks.removeValue(forKey: id)
        downloadMeta.removeValue(forKey: id)
        activeDownloads.removeAll { $0.id == id }
    }

    // MARK: - Private HLS Segment Downloader + FFmpeg Remuxer

    private func downloadHLSWithSegments(
        downloadID: UUID,
        playlistURL: URL,
        cleanTitle: String,
        artist: String?,
        minimumBitrate: Double?,
        headers: [String: String],
        maxDurationSeconds: Double?,
        destinationFolder: String
    ) async -> Bool {
        guard let initialText = await fetchText(from: playlistURL, headers: headers) else {
            return false
        }

        let initialParsed = parseM3U8(text: initialText, baseURL: playlistURL)
        var parsedVideo = initialParsed
        var separateAudioURL: URL?

        if initialParsed.isMaster {
            guard !initialParsed.variants.isEmpty else { return false }
            let chosenVariant: HLSQualityVariant?
            if let minimumBitrate, minimumBitrate > 0 {
                chosenVariant = initialParsed.variants.min { abs($0.peakBitrate - minimumBitrate) < abs($1.peakBitrate - minimumBitrate) }
            } else {
                let capped = initialParsed.variants.filter { $0.height == 0 || $0.height <= 1080 }
                chosenVariant = capped.max { $0.peakBitrate < $1.peakBitrate } ?? initialParsed.variants.last
            }
            guard let chosenURL = chosenVariant?.variantURL else { return false }
            guard let subText = await fetchText(from: chosenURL, headers: headers) else { return false }
            parsedVideo = parseM3U8(text: subText, baseURL: chosenURL)
            if let groupID = chosenVariant?.audioGroupID {
                separateAudioURL = initialParsed.audioGroupURLs[groupID]
            } else {
                separateAudioURL = initialParsed.audioGroupURLs.values.first
            }
        }

        if parsedVideo.hasUnsupportedEncryption || parsedVideo.isLiveWithoutEndList || parsedVideo.segments.isEmpty {
            return false
        }

        if let maxDurationSeconds, parsedVideo.totalDuration > maxDurationSeconds {
            activeDownloads.removeAll { $0.id == downloadID }
            recordFailedDownload(
                sourceURL: playlistURL,
                message: "Skipped \"\(cleanTitle)\" (exceeds \(Int(maxDurationSeconds / 60)) min limit)."
            )
            return true
        }

        var parsedAudio: ParsedHLSMedia?
        if let separateAudioURL,
           let audioText = await fetchText(from: separateAudioURL, headers: headers) {
            let candidate = parseM3U8(text: audioText, baseURL: separateAudioURL)
            if !candidate.hasUnsupportedEncryption && !candidate.segments.isEmpty {
                parsedAudio = candidate
            }
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls_\(downloadID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let hasSeparateAudio = parsedAudio != nil
        guard let videoJoined = await downloadHLSSegmentSet(
            parsed: parsedVideo,
            workDir: workDir,
            filePrefix: "video",
            headers: headers,
            downloadID: downloadID,
            progressBase: 0,
            progressSpan: hasSeparateAudio ? 0.72 : 0.95
        ) else {
            return Task.isCancelled
        }

        var audioJoined: (url: URL, ext: String)?
        if let parsedAudio {
            audioJoined = await downloadHLSSegmentSet(
                parsed: parsedAudio,
                workDir: workDir,
                filePrefix: "audio",
                headers: headers,
                downloadID: downloadID,
                progressBase: 0.72,
                progressSpan: 0.23
            )
            if audioJoined == nil && Task.isCancelled {
                return true
            }
        }

        let finalMP4URL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let finalOK: Bool
        if let audioJoined {
            let muxOK = await Task.detached(priority: .userInitiated) {
                FFmpegMediaService.muxVideoAndAudioToMP4(videoURL: videoJoined.url, audioURL: audioJoined.url, outputURL: finalMP4URL)
            }.value
            if muxOK {
                finalOK = true
            } else {
                try? FileManager.default.removeItem(at: finalMP4URL)
                finalOK = await Task.detached(priority: .userInitiated) {
                    FFmpegMediaService.remuxToMP4(inputURL: videoJoined.url, outputURL: finalMP4URL)
                }.value
            }
        } else {
            finalOK = await Task.detached(priority: .userInitiated) {
                FFmpegMediaService.remuxToMP4(inputURL: videoJoined.url, outputURL: finalMP4URL)
            }.value
        }

        activeDownloads.removeAll { $0.id == downloadID }

        let finalTempURL: URL
        let finalExt: String
        if finalOK {
            finalTempURL = finalMP4URL
            finalExt = "mp4"
        } else {
            try? FileManager.default.removeItem(at: finalMP4URL)
            finalTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(videoJoined.ext)")
            try? FileManager.default.moveItem(at: videoJoined.url, to: finalTempURL)
            finalExt = videoJoined.ext
        }

        if let saved = MediaManager.shared.importTemporaryFile(
            from: finalTempURL,
            preferredFileName: "\(cleanTitle).\(finalExt)",
            inFolder: destinationFolder
        ) {
            let updated = MediaManager.shared.applyDownloadedMetadataAndPlaylist(for: saved, title: cleanTitle, artist: artist)
            recordCompletedDownload(updated, sourceURL: playlistURL)
        } else {
            return false
        }
        LocalMediaCacheProxy.shared.refreshCacheSize()
        return true
    }

    private func downloadHLSSegmentSet(
        parsed: ParsedHLSMedia,
        workDir: URL,
        filePrefix: String,
        headers: [String: String],
        downloadID: UUID,
        progressBase: Double,
        progressSpan: Double
    ) async -> (url: URL, ext: String)? {
        var initData: Data?
        if let mapURL = parsed.mapURL {
            initData = await fetchBinary(from: mapURL, headers: headers)
            if initData == nil { return nil }
        }

        var keyCache: [URL: Data] = [:]
        for seg in parsed.segments {
            if Task.isCancelled { return nil }
            if let keyURI = seg.keyURI, seg.keyMethod == "AES-128", keyCache[keyURI] == nil {
                guard let k = await fetchBinary(from: keyURI, headers: headers), k.count == 16 else {
                    return nil
                }
                keyCache[keyURI] = k
            }
        }

        let segments = parsed.segments
        let totalCount = segments.count
        var segmentFiles = Array<URL?>(repeating: nil, count: totalCount)
        var completedCount = 0
        let session = ephemeralDataSession

        let batchSize = 4
        for startIdx in stride(from: 0, to: totalCount, by: batchSize) {
            if Task.isCancelled {
                activeDownloads.removeAll { $0.id == downloadID }
                return nil
            }
            let endIdx = min(startIdx + batchSize, totalCount)
            let ok = await withTaskGroup(of: (Int, URL?).self) { group -> Bool in
                for i in startIdx..<endIdx {
                    let seg = segments[i]
                    let keyData = seg.keyURI.flatMap { keyCache[$0] }
                    group.addTask {
                        for attempt in 0..<2 {
                            var req = URLRequest(url: seg.url)
                            headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
                            req.timeoutInterval = 25
                            guard let (rawData, resp) = try? await session.data(for: req),
                                  let http = resp as? HTTPURLResponse,
                                  (200...299).contains(http.statusCode),
                                  !rawData.isEmpty else {
                                if attempt == 0 {
                                    try? await Task.sleep(for: .milliseconds(250))
                                    continue
                                }
                                return (i, nil)
                            }
                            let plainData: Data
                            if seg.keyMethod == "AES-128", let keyData {
                                let iv = seg.ivData ?? Self.defaultHLSIV(sequence: seg.sequence)
                                guard let decrypted = Self.decryptAES128CBC(rawData, key: keyData, iv: iv) else {
                                    return (i, nil)
                                }
                                plainData = decrypted
                            } else {
                                plainData = rawData
                            }
                            let partURL = workDir.appendingPathComponent(String(format: "%@_seg_%05d.bin", filePrefix, i))
                            do {
                                try plainData.write(to: partURL, options: [.atomic])
                                return (i, partURL)
                            } catch {
                                return (i, nil)
                            }
                        }
                        return (i, nil)
                    }
                }
                var batchOK = true
                for await (idx, fileURL) in group {
                    if let fileURL {
                        segmentFiles[idx] = fileURL
                        completedCount += 1
                    } else {
                        batchOK = false
                    }
                }
                return batchOK
            }

            if !ok {
                return nil
            }
            let frac = progressBase + (Double(completedCount) / Double(max(1, totalCount))) * progressSpan
            updateProgress(downloadID: downloadID, fraction: frac)
        }

        let orderedParts = segmentFiles.compactMap { $0 }
        guard orderedParts.count == totalCount else { return nil }

        let isFMP4 = initData != nil || segments.first?.url.pathExtension.lowercased() == "m4s"
        let joinedExt = isFMP4 ? "mp4" : "ts"
        let joinedURL = workDir.appendingPathComponent("\(filePrefix)_joined.\(joinedExt)")

        FileManager.default.createFile(atPath: joinedURL.path, contents: nil)
        guard let writeHandle = try? FileHandle(forWritingTo: joinedURL) else { return nil }
        if let initData {
            try? writeHandle.write(contentsOf: initData)
        }
        for partURL in orderedParts {
            if let partData = try? Data(contentsOf: partURL, options: [.mappedIfSafe]) {
                try? writeHandle.write(contentsOf: partData)
            }
        }
        try? writeHandle.close()
        return (joinedURL, joinedExt)
    }

    private func startAppleAVAssetHLSDownload(
        from url: URL,
        cleanTitle: String,
        artist: String?,
        minimumBitrate: Double?,
        headers: [String: String],
        maxDurationSeconds: Double?,
        maxDurationMinutes: Int = 0,
        destinationFolder: String,
        fallbackStreams: [DetectedBrowserMedia] = []
    ) {
        let downloadID = UUID()
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
            tryNextFallbackOrFail(
                fallbacks: fallbackStreams,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder,
                sourceURL: url,
                failureMessage: "Could not start HLS download."
            )
            return
        }

        downloadMeta[downloadID] = DownloadMeta(
            title: cleanTitle,
            artist: artist,
            sourceURL: url,
            maxDurationSeconds: maxDurationSeconds,
            maxDurationMinutes: maxDurationMinutes,
            isHLS: true,
            destinationFolder: destinationFolder,
            fallbackStreams: fallbackStreams
        )
        taskToDownloadID[task.taskIdentifier] = downloadID
        activeURLTasks[downloadID] = task
        activeDownloads.append(BrowserDownloadItem(id: downloadID, title: cleanTitle, sourceURL: url, progress: 0, isHLS: true))
        task.resume()
        MediaManager.shared.statusMessage = "Downloading \(cleanTitle)..."
    }

    private func enqueueDirectDownloadTask(
        downloadID: UUID,
        url: URL,
        cleanTitle: String,
        artist: String?,
        headers: [String: String],
        maxDurationSeconds: Double?,
        maxDurationMinutes: Int = 0,
        destinationFolder: String,
        fallbackStreams: [DetectedBrowserMedia] = []
    ) {
        downloadMeta[downloadID] = DownloadMeta(
            title: cleanTitle,
            artist: artist,
            sourceURL: url,
            maxDurationSeconds: maxDurationSeconds,
            maxDurationMinutes: maxDurationMinutes,
            isHLS: false,
            destinationFolder: destinationFolder,
            fallbackStreams: fallbackStreams
        )

        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let task = browserSession.downloadTask(with: request)
        taskToDownloadID[task.taskIdentifier] = downloadID
        activeURLTasks[downloadID] = task
        task.resume()
        MediaManager.shared.statusMessage = "Downloading \(cleanTitle)..."
    }

    // MARK: - M3U8 Parser & Crypto

    private func fetchText(from url: URL, headers: [String: String]) async -> String? {
        guard let data = await fetchBinary(from: url, headers: headers) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func fetchBinary(from url: URL, headers: [String: String]) async -> Data? {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.timeoutInterval = 20
        guard let (data, resp) = try? await ephemeralDataSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private func parseM3U8(text: String, baseURL: URL) -> ParsedHLSMedia {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            var audioGroupURLs: [String: URL] = [:]
            var audioGroupDefaults: Set<String> = []
            for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseM3U8Attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attrs["TYPE"]?.uppercased() == "AUDIO",
                      let groupID = attrs["GROUP-ID"], !groupID.isEmpty,
                      let rawURI = attrs["URI"],
                      let resolvedAudio = URL(string: rawURI, relativeTo: baseURL)?.absoluteURL else {
                    continue
                }
                let isDefault = attrs["DEFAULT"]?.uppercased() == "YES"
                if isDefault && !audioGroupDefaults.contains(groupID) {
                    audioGroupURLs[groupID] = resolvedAudio
                    audioGroupDefaults.insert(groupID)
                } else if audioGroupURLs[groupID] == nil {
                    audioGroupURLs[groupID] = resolvedAudio
                }
            }

            var variants: [HLSQualityVariant] = []
            var seen = Set<String>()
            var idx = 0
            while idx < lines.count {
                let line = lines[idx]
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    let attrs = parseM3U8Attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                    var j = idx + 1
                    while j < lines.count && (lines[j].isEmpty || lines[j].hasPrefix("#")) {
                        j += 1
                    }
                    if j < lines.count, let resolved = URL(string: lines[j], relativeTo: baseURL)?.absoluteURL {
                        let bandwidth = Double(attrs["BANDWIDTH"] ?? attrs["AVERAGE-BANDWIDTH"] ?? "") ?? 0
                        var w = 0
                        var h = 0
                        if let res = attrs["RESOLUTION"] {
                            let dims = res.lowercased().split(separator: "x")
                            if dims.count == 2 {
                                w = Int(dims[0]) ?? 0
                                h = Int(dims[1]) ?? 0
                            }
                        }
                        let mbps = bandwidth > 0 ? String(format: "%.1f Mbps", bandwidth / 1_000_000.0) : ""
                        let resLabel = h > 0 ? "\(h)p" : (attrs["NAME"] ?? "Quality \(variants.count + 1)")
                        let label = mbps.isEmpty ? resLabel : "\(resLabel) • \(mbps)"
                        let audioGroupID = attrs["AUDIO"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if seen.insert(resolved.absoluteString).inserted {
                            variants.append(
                                HLSQualityVariant(
                                    id: "m\(variants.count)",
                                    label: label,
                                    width: w,
                                    height: h,
                                    peakBitrate: bandwidth,
                                    variantURL: resolved,
                                    audioGroupID: audioGroupID?.isEmpty == false ? audioGroupID : nil
                                )
                            )
                        }
                    }
                    idx = j + 1
                    continue
                }
                idx += 1
            }
            variants.sort {
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.peakBitrate > $1.peakBitrate
            }
            return ParsedHLSMedia(
                isMaster: true,
                variants: variants,
                audioGroupURLs: audioGroupURLs,
                mapURL: nil,
                segments: [],
                totalDuration: 0,
                hasUnsupportedEncryption: false,
                isLiveWithoutEndList: false
            )
        }

        var segments: [ParsedHLSMedia.Segment] = []
        var mapURL: URL?
        var mediaSequence = 0
        var hasEndList = false
        var hasUnsupportedEncryption = false
        var currentKeyMethod: String?
        var currentKeyURI: URL?
        var currentIVData: Data?
        var totalDuration = 0.0
        var pendingDuration = 0.0
        var hasPendingSegment = false

        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line == "#EXT-X-ENDLIST" {
                hasEndList = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseM3U8Attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let rawURI = attrs["URI"], let url = URL(string: rawURI, relativeTo: baseURL)?.absoluteURL {
                    mapURL = url
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseM3U8Attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"]?.uppercased() ?? "NONE"
                if method == "NONE" {
                    currentKeyMethod = nil
                    currentKeyURI = nil
                    currentIVData = nil
                } else if method == "AES-128" {
                    currentKeyMethod = method
                    currentKeyURI = attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                    currentIVData = attrs["IV"].flatMap { Self.parseHexData($0) }
                } else {
                    hasUnsupportedEncryption = true
                }
            } else if line.hasPrefix("#EXTINF:") {
                let rawDur = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? "0"
                pendingDuration = Double(rawDur) ?? 0
                hasPendingSegment = true
            } else if line.hasPrefix("#") {
                continue
            } else if hasPendingSegment {
                hasPendingSegment = false
                if let segURL = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    let seq = mediaSequence + segments.count
                    segments.append(
                        ParsedHLSMedia.Segment(
                            url: segURL,
                            duration: pendingDuration,
                            sequence: seq,
                            keyMethod: currentKeyMethod,
                            keyURI: currentKeyURI,
                            ivData: currentIVData
                        )
                    )
                    totalDuration += pendingDuration
                }
            }
        }

        return ParsedHLSMedia(
            isMaster: false,
            variants: [],
            audioGroupURLs: [:],
            mapURL: mapURL,
            segments: segments,
            totalDuration: totalDuration,
            hasUnsupportedEncryption: hasUnsupportedEncryption,
            isLiveWithoutEndList: !hasEndList && totalDuration < 15
        )
    }

    private func parseM3U8Attributes(_ input: String) -> [String: String] {
        var dict: [String: String] = [:]
        let pattern = #"([A-Z0-9-]+)=("[^"]*"|[^,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return dict }
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        for m in matches {
            guard let kRange = Range(m.range(at: 1), in: input),
                  let vRange = Range(m.range(at: 2), in: input) else { continue }
            let key = String(input[kRange]).uppercased()
            var val = String(input[vRange])
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            dict[key] = val
        }
        return dict
    }

    nonisolated private static func defaultHLSIV(sequence: Int) -> Data {
        var iv = Data(count: 16)
        var bigEndianSeq = UInt64(max(0, sequence)).bigEndian
        withUnsafeBytes(of: &bigEndianSeq) { bytes in
            iv.replaceSubrange(8..<16, with: bytes)
        }
        return iv
    }

    private static func parseHexData(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.lowercased().hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        if hex.count < 32 { hex = String(repeating: "0", count: 32 - hex.count) + hex }
        guard hex.count == 32 else { return nil }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    nonisolated private static func decryptAES128CBC(_ encrypted: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        let outLength = encrypted.count + kCCBlockSizeAES128
        var outData = Data(count: outLength)
        var numBytesDecrypted: size_t = 0

        let status = outData.withUnsafeMutableBytes { outPtr in
            encrypted.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            kCCKeySizeAES128,
                            ivPtr.baseAddress,
                            inPtr.baseAddress,
                            encrypted.count,
                            outPtr.baseAddress,
                            outLength,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        outData.removeSubrange(numBytesDecrypted..<outData.count)
        return outData
    }

    // MARK: - Helpers

    private func isHLSURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let lower = url.absoluteString.lowercased()
        return ext == "m3u8" || lower.contains(".m3u8")
    }

    private func cleanedStreamURLIfRangeFragment(_ url: URL) -> URL {
        if url.host?.lowercased().contains("googlevideo.com") == true {
            return YouTubeStreamResolver.cleanGooglevideoURL(url)
        }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else {
            return url
        }
        let filtered = items.filter { item in
            let name = item.name.lowercased()
            return name != "bytestart" && name != "byteend"
        }
        guard filtered.count != items.count else { return url }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.url ?? url
    }

    private func enrichedHeaders(_ headers: [String: String]?, for url: URL) -> [String: String] {
        var merged = headers ?? [:]
        if merged["User-Agent"] == nil {
            merged["User-Agent"] = Self.browserUserAgent
        }
        if merged["Origin"] == nil,
           let refererStr = merged["Referer"],
           let refURL = URL(string: refererStr),
           let scheme = refURL.scheme,
           let host = refURL.host {
            merged["Origin"] = "\(scheme)://\(host)"
        }
        _ = url
        return merged
    }

    private func resolveLocalDuration(at url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        if let dur = try? await asset.load(.duration) {
            let sec = CMTimeGetSeconds(dur)
            if sec.isFinite, sec > 0 { return sec }
        }
        return await Task.detached(priority: .utility) {
            FFmpegMediaService.probeMetadata(for: url)?.durationSeconds
        }.value
    }

    private func updateProgress(downloadID: UUID, fraction: Double) {
        guard let idx = activeDownloads.firstIndex(where: { $0.id == downloadID }) else { return }
        activeDownloads[idx].progress = min(max(fraction, 0), 1)
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
            "\"(?:hlsUrl|hls_url|video_url|videoUrl|stream_url|streamUrl|playUrl|mp4|src|file)\"\\s*:\\s*\"((?:https?:\\\\?/\\\\?/|/)[^\"']+)\"",
            "https?://[^\\s\"'<>\\\\]+\\.(?:m3u8|mp4|mov|m4v|mkv|webm|avi|flv|ts|mp3|m4a|aac|wav|flac|ogg|opus)(?:\\?[^\\s\"'<>\\\\]*)?"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                let groupIdx = match.numberOfRanges > 1 ? 1 : 0
                guard let range = Range(match.range(at: groupIdx), in: html) else { continue }
                let raw = String(html[range])
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
                    .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
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

    private func recordCompletedDownload(_ item: MediaItem, sourceURL: URL) {
        lastCompletedMediaItem = item
        lastCompletedCacheEvent = CompletedCacheEvent(eventID: UUID(), item: item, sourceURL: sourceURL)
    }

    private func recordFailedDownload(sourceURL: URL?, message: String) {
        MediaManager.shared.errorMessage = message
        lastFailedCacheEvent = FailedCacheEvent(eventID: UUID(), sourceURL: sourceURL, message: message)
    }

    private func tryNextFallbackOrFail(
        fallbacks: [DetectedBrowserMedia],
        maxDurationMinutes: Int,
        destinationFolder: String,
        sourceURL: URL?,
        failureMessage: String
    ) {
        if let next = fallbacks.first {
            let rest = Array(fallbacks.dropFirst())
            MediaManager.shared.statusMessage = "Trying alternate stream for \(next.title ?? "video")..."
            cacheMediaStream(
                next,
                fallbackStreams: rest,
                maxDurationMinutes: maxDurationMinutes,
                destinationFolder: destinationFolder
            )
            return
        }
        recordFailedDownload(sourceURL: sourceURL, message: failureMessage)
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
                tryNextFallbackOrFail(
                    fallbacks: meta.fallbackStreams,
                    maxDurationMinutes: meta.maxDurationMinutes,
                    destinationFolder: meta.destinationFolder,
                    sourceURL: meta.sourceURL,
                    failureMessage: "Download blocked (HTTP \(statusCode)). Try playing the video in Browser first."
                )
                return
            }
            if mimeType.contains("html") {
                try? FileManager.default.removeItem(at: tempURLOrFallback(tempFileURL))
                tryNextFallbackOrFail(
                    fallbacks: meta.fallbackStreams,
                    maxDurationMinutes: meta.maxDurationMinutes,
                    destinationFolder: meta.destinationFolder,
                    sourceURL: meta.sourceURL,
                    failureMessage: "Server returned a webpage instead of media. Try playing inside the Browser."
                )
                return
            }
        }

        Task {
            if let limit = meta.maxDurationSeconds, !isHLS {
                if let seconds = await resolveLocalDuration(at: tempFileURL), seconds > limit {
                    try? FileManager.default.removeItem(at: tempFileURL)
                    recordFailedDownload(
                        sourceURL: meta.sourceURL,
                        message: "Skipped \"\(meta.title)\" (exceeds \(Int(limit / 60)) min limit)."
                    )
                    return
                }
            }

            let ext = isHLS ? "movpkg" : suggestedExtension
            let preferredName = ext.isEmpty ? meta.title : "\(meta.title).\(ext)"
            if let saved = MediaManager.shared.importTemporaryFile(
                from: tempFileURL,
                preferredFileName: preferredName,
                inFolder: meta.destinationFolder
            ) {
                let updated = MediaManager.shared.applyDownloadedMetadataAndPlaylist(for: saved, title: meta.title, artist: meta.artist)
                recordCompletedDownload(updated, sourceURL: meta.sourceURL)
            } else {
                tryNextFallbackOrFail(
                    fallbacks: meta.fallbackStreams,
                    maxDurationMinutes: meta.maxDurationMinutes,
                    destinationFolder: meta.destinationFolder,
                    sourceURL: meta.sourceURL,
                    failureMessage: "Could not import cached media file."
                )
            }
            LocalMediaCacheProxy.shared.refreshCacheSize()
        }
    }

    private func tempURLOrFallback(_ url: URL) -> URL { url }

    fileprivate func handleFailedDownload(taskIdentifier: Int, error: Error) {
        let removedMeta: DownloadMeta?
        if let id = taskToDownloadID.removeValue(forKey: taskIdentifier) {
            removedMeta = downloadMeta.removeValue(forKey: id)
            activeURLTasks.removeValue(forKey: id)
            activeDownloads.removeAll { $0.id == id }
        } else {
            removedMeta = nil
        }
        let nsErr = error as NSError
        if nsErr.code != NSURLErrorCancelled {
            tryNextFallbackOrFail(
                fallbacks: removedMeta?.fallbackStreams ?? [],
                maxDurationMinutes: removedMeta?.maxDurationMinutes ?? 0,
                destinationFolder: removedMeta?.destinationFolder ?? "",
                sourceURL: removedMeta?.sourceURL,
                failureMessage: "Download failed: \(error.localizedDescription)"
            )
        }
    }

    nonisolated static func extensionFor(mimeType: String, fallbackName: String) -> String {
        let nameExt = (fallbackName as NSString).pathExtension.lowercased()
        if MediaItem.allSupportedExtensions.contains(nameExt) {
            return nameExt
        }
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "video/webm", "audio/webm": return "webm"
        case "video/x-matroska": return "mkv"
        case "video/x-msvideo": return "avi"
        case "video/x-flv": return "flv"
        case "video/mp2t": return "ts"
        default: return "mp4"
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
        if let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let mimeQuery = comps.queryItems?.first(where: { $0.name.lowercased() == "mime" })?.value {
            return WebMediaDownloader.extensionFor(mimeType: mimeQuery, fallbackName: "")
        }
        return WebMediaDownloader.extensionFor(mimeType: response?.mimeType ?? "", fallbackName: "")
    }
}