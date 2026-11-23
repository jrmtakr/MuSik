import Foundation

struct YouTubeResolvedResult {
    let videoID: String
    let title: String
    let author: String?
    let durationSeconds: Double?
    let streams: [DetectedBrowserMedia]
    let errorReason: String?
}

enum YouTubeStreamResolver {
    static let iosClientVersion = "20.10.4"
    static let iosClientUserAgent =
        "com.google.ios.youtube/\(iosClientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X; en_US)"
    static let androidVRUserAgent =
        "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
    }

    static func extractVideoID(from url: URL) -> String? {
        guard isYouTubeURL(url) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let pathParts = url.pathComponents.filter { $0 != "/" }

        if host == "youtu.be", let first = pathParts.first, !first.isEmpty {
            return sanitizedVideoID(first)
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return sanitizedVideoID(v)
        }
        if pathParts.count >= 2, ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
            return sanitizedVideoID(pathParts[1])
        }
        return nil
    }

    private static func sanitizedVideoID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        return String(trimmed.prefix(16))
    }

    static func cleanGooglevideoURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.contains("googlevideo.com"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else {
            return url
        }
        let dropParams: Set<String> = ["range", "rn", "rbuf", "ump", "srfvp"]
        let filtered = items.filter { !dropParams.contains($0.name.lowercased()) }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.url ?? url
    }

    static func resolveStreams(
        for url: URL,
        cookiesHeader: String? = nil,
        referer: String? = nil,
        visitorData: String? = nil
    ) async -> YouTubeResolvedResult? {
        guard let videoID = extractVideoID(from: url) else { return nil }

        // 1. iOS InnerTube client often yields clean HLS + progressive MP4 + unencrypted adaptive URLs.
        if let iosResult = await fetchInnerTube(
            videoID: videoID,
            sourcePageURL: url,
            clientName: "IOS",
            clientHeaderID: "5",
            clientVersion: iosClientVersion,
            userAgent: iosClientUserAgent,
            extraClientFields: [
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2"
            ],
            visitorData: visitorData,
            cookiesHeader: nil
        ), !iosResult.streams.isEmpty {
            return iosResult
        }

        // 2. Android VR client fallback.
        if let vrResult = await fetchInnerTube(
            videoID: videoID,
            sourcePageURL: url,
            clientName: "ANDROID_VR",
            clientHeaderID: "28",
            clientVersion: "1.60.19",
            userAgent: androidVRUserAgent,
            extraClientFields: [
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "osName": "Android",
                "osVersion": "12L",
                "androidSdkVersion": 32
            ],
            visitorData: visitorData,
            cookiesHeader: nil
        ), !vrResult.streams.isEmpty {
            return vrResult
        }

        // 3. Mobile web watch page HTML ytInitialPlayerResponse fallback (passes cookies if provided).
        if let htmlResult = await fetchMobileWebHTML(
            videoID: videoID,
            sourcePageURL: url,
            cookiesHeader: cookiesHeader,
            referer: referer
        ) {
            return htmlResult
        }

        return YouTubeResolvedResult(
            videoID: videoID,
            title: "YouTube Video",
            author: nil,
            durationSeconds: nil,
            streams: [],
            errorReason: "Could not resolve direct YouTube stream for this video."
        )
    }

    static func parsePlayerResponseJSON(
        _ data: Data,
        videoID: String,
        sourcePageURL: URL?,
        headers: [String: String]?
    ) -> YouTubeResolvedResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsePlayerResponse(
            dict: json,
            videoID: videoID,
            sourcePageURL: sourcePageURL,
            headers: headers
        )
    }

    private static func fetchInnerTube(
        videoID: String,
        sourcePageURL: URL,
        clientName: String,
        clientHeaderID: String,
        clientVersion: String,
        userAgent: String,
        extraClientFields: [String: Any],
        visitorData: String?,
        cookiesHeader: String?
    ) async -> YouTubeResolvedResult? {
        guard let apiURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return nil
        }

        var clientObj: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": "en",
            "gl": "US"
        ]
        if let visitorData, !visitorData.isEmpty {
            clientObj["visitorData"] = visitorData
        }
        extraClientFields.forEach { clientObj[$0.key] = $0.value }

        let bodyDict: [String: Any] = [
            "videoId": videoID,
            "context": ["client": clientObj],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            return nil
        }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(clientHeaderID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData, !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let cookiesHeader, !cookiesHeader.isEmpty {
            req.setValue(cookiesHeader, forHTTPHeaderField: "Cookie")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let headers = ["User-Agent": userAgent]
        return parsePlayerResponse(
            dict: dict,
            videoID: videoID,
            sourcePageURL: sourcePageURL,
            headers: headers
        )
    }

    private static func fetchMobileWebHTML(
        videoID: String,
        sourcePageURL: URL,
        cookiesHeader: String?,
        referer: String?
    ) async -> YouTubeResolvedResult? {
        guard let watchURL = URL(string: "https://m.youtube.com/watch?v=\(videoID)") else {
            return nil
        }
        var req = URLRequest(url: watchURL)
        req.timeoutInterval = 15
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let cookiesHeader, !cookiesHeader.isEmpty {
            req.setValue(cookiesHeader, forHTTPHeaderField: "Cookie")
        }
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let playerDict = extractPlayerResponseFromHTML(html) else {
            return nil
        }

        var headers = ["User-Agent": WebMediaDownloader.browserUserAgent, "Referer": watchURL.absoluteString]
        if let cookiesHeader, !cookiesHeader.isEmpty {
            headers["Cookie"] = cookiesHeader
        }
        return parsePlayerResponse(
            dict: playerDict,
            videoID: videoID,
            sourcePageURL: sourcePageURL,
            headers: headers
        )
    }

    private static func extractPlayerResponseFromHTML(_ html: String) -> [String: Any]? {
        let markers = ["ytInitialPlayerResponse = ", "var ytInitialPlayerResponse = "]
        for marker in markers {
            guard let range = html.range(of: marker) else { continue }
            guard let jsonStart = html[range.upperBound...].firstIndex(of: "{") else { continue }
            if let slice = balancedJSONObject(in: html, startingAt: jsonStart),
               let data = slice.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    private static func balancedJSONObject(in text: String, startingAt start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func parsePlayerResponse(
        dict: [String: Any],
        videoID: String,
        sourcePageURL: URL?,
        headers: [String: String]?
    ) -> YouTubeResolvedResult {
        let videoDetails = dict["videoDetails"] as? [String: Any]
        let rawTitle = (videoDetails?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false ? rawTitle! : "YouTube Video")
        let author = (videoDetails?["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let durStr = videoDetails?["lengthSeconds"] as? String
        let durNum = videoDetails?["lengthSeconds"] as? NSNumber
        let durationSeconds = durNum?.doubleValue ?? durStr.flatMap(Double.init)

        let playability = dict["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String
        let reason = playability?["reason"] as? String

        guard let streamingData = dict["streamingData"] as? [String: Any] else {
            return YouTubeResolvedResult(
                videoID: videoID,
                title: title,
                author: author,
                durationSeconds: durationSeconds,
                streams: [],
                errorReason: (status != "OK" ? reason : nil) ?? "No playable streams exposed for this video."
            )
        }

        var progressiveHD: [DetectedBrowserMedia] = []
        var progressiveSD: [DetectedBrowserMedia] = []
        var adaptiveHD: [DetectedBrowserMedia] = []
        var hlsStreams: [DetectedBrowserMedia] = []
        var audioOnlyStreams: [DetectedBrowserMedia] = []
        let refererStr = sourcePageURL?.absoluteString ?? "https://m.youtube.com/watch?v=\(videoID)"

        // Progressive muxed MP4s (Video + Audio together: e.g. 720p, 360p)
        if let formats = streamingData["formats"] as? [[String: Any]] {
            let parsed = formats.compactMap { fmt -> (height: Int, bitrate: Int, url: URL, label: String)? in
                guard let urlStr = fmt["url"] as? String,
                      let streamURL = URL(string: urlStr) else {
                    return nil
                }
                let height = (fmt["height"] as? NSNumber)?.intValue ?? 0
                let bitrate = (fmt["bitrate"] as? NSNumber)?.intValue ?? 0
                let qLabel = (fmt["qualityLabel"] as? String) ?? (height > 0 ? "\(height)p" : "MP4")
                return (height, bitrate, streamURL, "\(qLabel) MP4")
            }.sorted {
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.bitrate > $1.bitrate
            }

            for item in parsed {
                let media = DetectedBrowserMedia(
                    url: item.url,
                    pairedAudioURL: nil,
                    isHLS: false,
                    isAudio: false,
                    title: title,
                    author: author,
                    qualityLabel: item.label,
                    referer: refererStr,
                    customHeaders: headers,
                    durationSeconds: durationSeconds,
                    isActivelyPlaying: true
                )
                if item.height >= 720 {
                    progressiveHD.append(media)
                } else {
                    progressiveSD.append(media)
                }
            }
        }

        // HLS multi-quality manifest (may include separate #EXT-X-MEDIA audio groups)
        if let hlsStr = streamingData["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            hlsStreams.append(
                DetectedBrowserMedia(
                    url: hlsURL,
                    pairedAudioURL: nil,
                    isHLS: true,
                    isAudio: false,
                    title: title,
                    author: author,
                    qualityLabel: "HLS Multi-Quality",
                    referer: refererStr,
                    customHeaders: headers,
                    durationSeconds: durationSeconds,
                    isActivelyPlaying: true
                )
            )
        }

        // Adaptive H.264/HEVC Video + Best AAC M4A Audio
        if let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] {
            let bestAudio = adaptive.compactMap { fmt -> (bitrate: Int, url: URL, ext: String, label: String)? in
                guard let mime = (fmt["mimeType"] as? String)?.lowercased(),
                      mime.contains("audio/mp4"),
                      let urlStr = fmt["url"] as? String,
                      let audioURL = URL(string: urlStr) else {
                    return nil
                }
                let bitrate = (fmt["bitrate"] as? NSNumber)?.intValue ?? 0
                let kbps = bitrate > 0 ? "\(bitrate / 1000)kbps" : ""
                let label = kbps.isEmpty ? "Audio (.m4a)" : "Audio .m4a (\(kbps))"
                return (bitrate, audioURL, "m4a", label)
            }.sorted { $0.bitrate > $1.bitrate }.first

            let adaptiveVideos = adaptive.compactMap { fmt -> (height: Int, isAVC: Bool, bitrate: Int, url: URL, label: String)? in
                guard let mime = (fmt["mimeType"] as? String)?.lowercased(),
                      mime.contains("video/mp4"),
                      let urlStr = fmt["url"] as? String,
                      let videoURL = URL(string: urlStr) else {
                    return nil
                }
                let height = (fmt["height"] as? NSNumber)?.intValue ?? 0
                let bitrate = (fmt["bitrate"] as? NSNumber)?.intValue ?? 0
                let isAVC = mime.contains("avc1")
                let qLabel = (fmt["qualityLabel"] as? String) ?? (height > 0 ? "\(height)p" : "HD")
                return (height, isAVC, bitrate, videoURL, "\(qLabel) MP4 (Muxed HD)")
            }.sorted {
                if $0.height != $1.height {
                    // Prefer resolutions <= 1080p first (hardware H.264 & fast offline cache), highest first
                    let lhsCap = $0.height <= 1080 ? $0.height : (1080 - ($0.height / 100))
                    let rhsCap = $1.height <= 1080 ? $1.height : (1080 - ($1.height / 100))
                    if lhsCap != rhsCap { return lhsCap > rhsCap }
                }
                if $0.isAVC != $1.isAVC { return $0.isAVC && !$1.isAVC }
                return $0.bitrate > $1.bitrate
            }

            if let bestAudio {
                // Pair top H.264/MP4 adaptive streams (>= 480p) with best M4A audio
                for v in adaptiveVideos.filter({ $0.height >= 480 }).prefix(3) {
                    adaptiveHD.append(
                        DetectedBrowserMedia(
                            url: v.url,
                            pairedAudioURL: bestAudio.url,
                            isHLS: false,
                            isAudio: false,
                            title: title,
                            author: author,
                            qualityLabel: v.label,
                            referer: refererStr,
                            customHeaders: headers,
                            durationSeconds: durationSeconds,
                            isActivelyPlaying: true
                        )
                    )
                }

                // Standalone M4A audio option (downloads directly into Offline Songs + Playlists)
                audioOnlyStreams.append(
                    DetectedBrowserMedia(
                        url: bestAudio.url,
                        pairedAudioURL: nil,
                        isHLS: false,
                        isAudio: true,
                        title: title,
                        author: author,
                        qualityLabel: bestAudio.label,
                        referer: refererStr,
                        customHeaders: headers,
                        durationSeconds: durationSeconds,
                        isActivelyPlaying: false
                    )
                )
            }
        }

        let streams = progressiveHD + adaptiveHD + hlsStreams + progressiveSD + audioOnlyStreams

        return YouTubeResolvedResult(
            videoID: videoID,
            title: title,
            author: author,
            durationSeconds: durationSeconds,
            streams: streams,
            errorReason: streams.isEmpty ? reason : nil
        )
    }
}
