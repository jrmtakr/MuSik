import CryptoKit
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
    static let iosClientVersion = "20.11.6"
    static let iosClientUserAgent =
        "com.google.ios.youtube/\(iosClientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X; en_US)"
    static let androidClientVersion = "20.12.4"
    static let androidClientUserAgent =
        "com.google.android.youtube/\(androidClientVersion) (Linux; U; Android 14; en_US) gzip"
    static let androidVRClientVersion = "1.65.10"
    static let androidVRUserAgent =
        "com.google.android.apps.youtube.vr.oculus/\(androidVRClientVersion) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    private enum ProbeBucket: Hashable {
        case progressive(String)
        case adaptiveMux(String)
        case hls(String)
        case audio(String)

        init(media: DetectedBrowserMedia) {
            let ua = media.customHeaders?["User-Agent"] ?? ""
            if media.isHLS {
                self = .hls(ua)
            } else if media.isAudio {
                self = .audio(ua)
            } else if media.pairedAudioURL != nil {
                self = .adaptiveMux(ua)
            } else {
                self = .progressive(ua)
            }
        }
    }

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
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
               !v.isEmpty {
                return sanitizedVideoID(v)
            }
            if let uParam = comps.queryItems?.first(where: { $0.name == "u" })?.value,
               let innerURL = URL(string: uParam, relativeTo: url)?.absoluteURL,
               let innerComps = URLComponents(url: innerURL, resolvingAgainstBaseURL: false),
               let v = innerComps.queryItems?.first(where: { $0.name == "v" })?.value,
               !v.isEmpty {
                return sanitizedVideoID(v)
            }
        }
        if pathParts.count >= 2, ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
            return sanitizedVideoID(pathParts[1])
        }
        return nil
    }

    static func unwrapGoogleRedirectIfNeeded(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com") || host.contains(".google."),
              url.path == "/url",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        for name in ["q", "url", "u"] {
            if let raw = comps.queryItems?.first(where: { $0.name == name })?.value,
               let target = URL(string: raw),
               isYouTubeURL(target) {
                return target
            }
        }
        return url
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

    private actor VisitorDataCache {
        private var cached: (value: String, date: Date)?

        func current() -> String? {
            guard let cached, Date().timeIntervalSince(cached.date) < 900 else { return nil }
            return cached.value
        }

        func store(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            cached = (trimmed, Date())
        }
    }

    private static let visitorCache = VisitorDataCache()

    static func cacheVisitorData(_ value: String?) async {
        guard let value, !value.isEmpty else { return }
        await visitorCache.store(value)
    }

    static func resolveStreams(
        for url: URL,
        cookiesHeader: String? = nil,
        referer: String? = nil,
        visitorData: String? = nil,
        skipReachabilityProbe: Bool = false
    ) async -> YouTubeResolvedResult? {
        guard let videoID = extractVideoID(from: url) else { return nil }

        enum ResolveRaceOutcome {
            case resolved(YouTubeResolvedResult?)
            case timedOut
        }

        return await withTaskGroup(of: ResolveRaceOutcome.self) { group in
            group.addTask {
                let result = await performResolveStreams(
                    videoID: videoID,
                    url: url,
                    cookiesHeader: cookiesHeader,
                    referer: referer,
                    visitorData: visitorData,
                    skipReachabilityProbe: skipReachabilityProbe
                )
                return .resolved(result)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                return .timedOut
            }
            while let outcome = await group.next() {
                switch outcome {
                case .resolved(let res):
                    group.cancelAll()
                    return res
                case .timedOut:
                    group.cancelAll()
                    return YouTubeResolvedResult(
                        videoID: videoID,
                        title: "YouTube Video",
                        author: nil,
                        durationSeconds: nil,
                        streams: [],
                        errorReason: "Timed out resolving YouTube stream."
                    )
                }
            }
            return nil
        }
    }

    private static func performResolveStreams(
        videoID: String,
        url: URL,
        cookiesHeader: String?,
        referer: String?,
        visitorData: String?,
        skipReachabilityProbe: Bool
    ) async -> YouTubeResolvedResult? {
        var resolvedVisitorData: String?
        if let visitorData, !visitorData.isEmpty {
            resolvedVisitorData = visitorData
            await visitorCache.store(visitorData)
        } else {
            resolvedVisitorData = await visitorCache.current()
        }

        let visitorDataForRequests = resolvedVisitorData
        var workingResults: [YouTubeResolvedResult] = []
        var fallbackResults: [YouTubeResolvedResult] = []
        var lastErrorReason: String?
        var fallbackMeta: YouTubeResolvedResult?

        @Sendable
        func evaluateCandidate(_ candidate: YouTubeResolvedResult?) async -> Bool {
            guard !Task.isCancelled, let candidate else { return false }
            if fallbackMeta == nil { fallbackMeta = candidate }
            if let reason = candidate.errorReason, !reason.isEmpty { lastErrorReason = reason }
            guard !candidate.streams.isEmpty else { return false }

            if skipReachabilityProbe {
                workingResults.append(candidate)
                return true
            }
            let reachable = await filterReachableStreams(candidate.streams)
            if !reachable.isEmpty {
                workingResults.append(
                    YouTubeResolvedResult(
                        videoID: candidate.videoID,
                        title: candidate.title,
                        author: candidate.author,
                        durationSeconds: candidate.durationSeconds,
                        streams: reachable,
                        errorReason: candidate.errorReason
                    )
                )
                return true
            }
            fallbackResults.append(candidate)
            return false
        }

        // 1. ANDROID client first (fast without blocking upfront HTML fetch or cookies).
        let androidResult = await fetchInnerTube(
            videoID: videoID,
            sourcePageURL: url,
            clientName: "ANDROID",
            clientHeaderID: "3",
            clientVersion: androidClientVersion,
            userAgent: androidClientUserAgent,
            extraClientFields: [
                "osName": "Android",
                "osVersion": "14",
                "androidSdkVersion": 34
            ],
            visitorData: visitorDataForRequests,
            cookiesHeader: nil
        )
        _ = await evaluateCandidate(androidResult)

        // If Web visitorData caused ANDROID to fail/require login, retry cleanly without visitorData.
        if workingResults.isEmpty, !Task.isCancelled, visitorDataForRequests != nil {
            let cleanAndroid = await fetchInnerTube(
                videoID: videoID,
                sourcePageURL: url,
                clientName: "ANDROID",
                clientHeaderID: "3",
                clientVersion: androidClientVersion,
                userAgent: androidClientUserAgent,
                extraClientFields: [
                    "osName": "Android",
                    "osVersion": "14",
                    "androidSdkVersion": 34
                ],
                visitorData: nil,
                cookiesHeader: nil
            )
            _ = await evaluateCandidate(cleanAndroid)
        }

        // 2. IOS + authenticated WEB/MWEB/TVHTML5 fallbacks concurrently when ANDROID yields no reachable streams.
        if workingResults.isEmpty, !Task.isCancelled {
            let resolvedCookies: String?
            if let cookiesHeader, !cookiesHeader.isEmpty {
                resolvedCookies = cookiesHeader
            } else {
                resolvedCookies = await BrowserYouTubeResolver.youtubeCookieHeader(timeoutSeconds: 0.7)
            }
            let signedIn = hasSignedInCookies(resolvedCookies)
            let sts: Int?
            if signedIn {
                sts = await currentSignatureTimestamp()
            } else {
                sts = nil
            }

            async let iosTask = fetchInnerTube(
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
                visitorData: visitorDataForRequests,
                cookiesHeader: nil
            )
            async let mwebTask = fetchInnerTube(
                videoID: videoID,
                sourcePageURL: url,
                clientName: "MWEB",
                clientHeaderID: "2",
                clientVersion: "2.20250311.00.00",
                userAgent: WebMediaDownloader.browserUserAgent,
                extraClientFields: [
                    "platform": "MOBILE"
                ],
                visitorData: visitorDataForRequests,
                cookiesHeader: resolvedCookies,
                signatureTimestamp: sts
            )
            async let webAuthTask = fetchInnerTubeIfEnabled(
                signedIn,
                videoID: videoID,
                sourcePageURL: url,
                clientName: "WEB",
                clientHeaderID: "1",
                clientVersion: "2.20250311.00.00",
                userAgent: desktopBrowserUserAgent,
                extraClientFields: [:],
                visitorData: visitorDataForRequests,
                cookiesHeader: resolvedCookies,
                signatureTimestamp: sts
            )
            async let tvAuthTask = fetchInnerTubeIfEnabled(
                signedIn,
                videoID: videoID,
                sourcePageURL: url,
                clientName: "TVHTML5",
                clientHeaderID: "7",
                clientVersion: "7.20250311.13.00",
                userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
                extraClientFields: [:],
                visitorData: visitorDataForRequests,
                cookiesHeader: resolvedCookies,
                signatureTimestamp: sts
            )

            let (iosResult, mwebResult, webAuthResult, tvAuthResult) = await (iosTask, mwebTask, webAuthTask, tvAuthTask)
            if !(await evaluateCandidate(iosResult)) {
                if !(await evaluateCandidate(mwebResult)) {
                    if !(await evaluateCandidate(webAuthResult)) {
                        _ = await evaluateCandidate(tvAuthResult)
                    }
                }
            }

            // 3. Mobile web watch HTML fallback (also seeds visitorData cache & extracts age-gated metadata).
            if workingResults.isEmpty, !Task.isCancelled {
                let mobileHTML = await fetchMobileWebHTML(
                    videoID: videoID,
                    sourcePageURL: url,
                    cookiesHeader: resolvedCookies,
                    referer: referer
                )
                if let vd = mobileHTML.visitorData, !vd.isEmpty {
                    await visitorCache.store(vd)
                }
                _ = await evaluateCandidate(mobileHTML.result)
            }
        }

        let chosen = !workingResults.isEmpty ? workingResults : (skipReachabilityProbe ? fallbackResults : [])
        if !chosen.isEmpty {
            let mergedStreams = orderedMergedStreams(from: chosen)
            let primaryMeta = chosen[0]
            return YouTubeResolvedResult(
                videoID: videoID,
                title: primaryMeta.title,
                author: primaryMeta.author ?? chosen.compactMap(\.author).first,
                durationSeconds: primaryMeta.durationSeconds ?? chosen.compactMap(\.durationSeconds).first,
                streams: mergedStreams,
                errorReason: nil
            )
        }

        return YouTubeResolvedResult(
            videoID: videoID,
            title: fallbackMeta?.title ?? "YouTube Video",
            author: fallbackMeta?.author,
            durationSeconds: fallbackMeta?.durationSeconds,
            streams: [],
            errorReason: lastErrorReason ?? "Could not resolve direct YouTube stream for this video."
        )
    }

    static func filterReachableStreams(_ streams: [DetectedBrowserMedia]) async -> [DetectedBrowserMedia] {
        guard !streams.isEmpty else { return [] }

        var representativeByBucket: [ProbeBucket: DetectedBrowserMedia] = [:]
        for s in streams {
            let bucket = ProbeBucket(media: s)
            if representativeByBucket[bucket] == nil {
                representativeByBucket[bucket] = s
            }
        }

        let probes = Array(representativeByBucket)
        var allowedBuckets = Set<ProbeBucket>()
        await withTaskGroup(of: (ProbeBucket, Bool)?.self) { group in
            for (bucket, sample) in probes {
                group.addTask {
                    if let paired = sample.pairedAudioURL {
                        async let mainTask = isURLReachable(sample.url, headers: sample.customHeaders)
                        async let audioTask = isURLReachable(paired, headers: sample.customHeaders)
                        let mainOK = await mainTask
                        let audioOK = await audioTask
                        return (bucket, mainOK && audioOK)
                    }
                    let mainOK = await isURLReachable(sample.url, headers: sample.customHeaders)
                    return (bucket, mainOK)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_500_000_000)
                return nil
            }
            for await probeResult in group {
                guard let (bucket, ok) = probeResult else {
                    group.cancelAll()
                    break
                }
                if ok {
                    allowedBuckets.insert(bucket)
                }
            }
        }

        guard !allowedBuckets.isEmpty else { return [] }
        return streams.filter { allowedBuckets.contains(ProbeBucket(media: $0)) }
    }

    private static func orderedMergedStreams(from results: [YouTubeResolvedResult]) -> [DetectedBrowserMedia] {
        var progressiveHD: [DetectedBrowserMedia] = []
        var adaptiveMux: [DetectedBrowserMedia] = []
        var hls: [DetectedBrowserMedia] = []
        var progressiveSD: [DetectedBrowserMedia] = []
        var audioOnly: [DetectedBrowserMedia] = []
        var seenKeys = Set<String>()

        for res in results {
            for s in res.streams {
                let key = "\(s.url.absoluteString)|\(s.pairedAudioURL?.absoluteString ?? "")|\(s.customHeaders?["User-Agent"] ?? "")"
                guard seenKeys.insert(key).inserted else { continue }
                if s.isAudio {
                    audioOnly.append(s)
                } else if s.isHLS {
                    hls.append(s)
                } else if s.pairedAudioURL != nil {
                    adaptiveMux.append(s)
                } else if (s.qualityLabel?.contains("720p") == true) || (s.qualityLabel?.contains("1080p") == true) {
                    progressiveHD.append(s)
                } else {
                    progressiveSD.append(s)
                }
            }
        }

        return progressiveHD + adaptiveMux + hls + progressiveSD + audioOnly
    }

    private static let ephemeralProbeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.5
        config.timeoutIntervalForResource = 5.5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static func isURLReachable(_ url: URL, headers: [String: String]?) async -> Bool {
        // Probe both byte 0 and a mid-stream offset (1.8 MB when clen allows) with bounded 1 KB Range requests:
        // YouTube CDN lets un-tokened adaptive streams read the first ~500-800 KB (206) then blocks later chunks (403),
        // while progressive MP4s (e.g. itag=18) and valid streams stay 206 through EOF.
        let lower = url.absoluteString.lowercased()
        let isPlaylist = url.pathExtension.lowercased() == "m3u8" || lower.contains(".m3u8")

        @Sendable
        func probeRange(_ rangeHeader: String?) async -> Bool {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 4.5
            headers?.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            if let rangeHeader {
                req.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }
            do {
                let (data, resp) = try await ephemeralProbeSession.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return false
                }
                return !data.isEmpty
            } catch {
                return false
            }
        }

        let initialRange: String? = isPlaylist ? nil : "bytes=0-1023"
        if !isPlaylist,
           url.host?.lowercased().contains("googlevideo.com") == true,
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let clenStr = comps.queryItems?.first(where: { $0.name.lowercased() == "clen" })?.value,
           let clen = Int64(clenStr),
           clen > 1_500_000 {
            let midOffset = min(1_800_000, max(900_000, clen / 2))
            if midOffset + 1023 < clen {
                async let firstOK = probeRange(initialRange)
                async let midOK = probeRange("bytes=\(midOffset)-\(midOffset + 1023)")
                let head = await firstOK
                let mid = await midOK
                return head && mid
            }
        }

        return await probeRange(initialRange)
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

    private static let desktopBrowserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static func hasSignedInCookies(_ cookiesHeader: String?) -> Bool {
        guard let cookiesHeader, !cookiesHeader.isEmpty else { return false }
        return cookiesHeader.contains("SAPISID=")
            || cookiesHeader.contains("__Secure-3PAPISID=")
            || cookiesHeader.contains("__Secure-1PAPISID=")
    }

    static func isLoginOrAgeGateReason(_ reason: String?) -> Bool {
        guard let lower = reason?.lowercased(), !lower.isEmpty else { return false }
        return lower.contains("sign in")
            || lower.contains("inappropriate")
            || lower.contains("confirm your age")
            || lower.contains("age")
            || lower.contains("login")
    }

    private static func sapisidAuthHeaders(cookiesHeader: String?, origin: String) -> [String: String] {
        guard let cookiesHeader, !cookiesHeader.isEmpty else { return [:] }
        var cookiesByName: [String: String] = [:]
        for pair in cookiesHeader.split(separator: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !val.isEmpty {
                cookiesByName[name] = val
            }
        }

        let ts = Int(Date().timeIntervalSince1970)
        var tokens: [String] = []
        let mappings: [(cookie: String, scheme: String)] = [
            ("SAPISID", "SAPISIDHASH"),
            ("__Secure-1PAPISID", "SAPISID1PHASH"),
            ("__Secure-3PAPISID", "SAPISID3PHASH")
        ]
        for entry in mappings {
            guard let secret = cookiesByName[entry.cookie], !secret.isEmpty else { continue }
            let input = "\(ts) \(secret) \(origin)"
            let digest = Insecure.SHA1.hash(data: Data(input.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            tokens.append("\(entry.scheme) \(ts)_\(hex)")
        }
        if tokens.isEmpty, let fallback = cookiesByName["__Secure-3PAPISID"] ?? cookiesByName["SAPISID"] {
            let input = "\(ts) \(fallback) \(origin)"
            let digest = Insecure.SHA1.hash(data: Data(input.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            tokens.append("SAPISIDHASH \(ts)_\(hex)")
        }
        guard !tokens.isEmpty else { return [:] }
        return [
            "Authorization": tokens.joined(separator: " "),
            "X-Origin": origin,
            "X-Goog-AuthUser": "0"
        ]
    }

    private actor SignatureTimestampCache {
        private var cached: (sts: Int, fetchedAt: Date)?

        func current() -> Int? {
            guard let cached, Date().timeIntervalSince(cached.fetchedAt) < 1800 else { return nil }
            return cached.sts
        }

        func store(_ sts: Int) {
            cached = (sts, Date())
        }
    }

    private static let stsCache = SignatureTimestampCache()

    private static func currentSignatureTimestamp() async -> Int? {
        if let existing = await stsCache.current() {
            return existing
        }
        guard let embedURL = URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ") else { return nil }
        var req = URLRequest(url: embedURL)
        req.timeoutInterval = 4.0
        req.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (htmlData, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: htmlData, encoding: .utf8),
              let jsMatch = html.range(of: #""jsUrl"\s*:\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let quoted = String(html[jsMatch])
        guard let lastQuote = quoted.dropLast().lastIndex(of: "\"") else { return nil }
        let rawPath = String(quoted[quoted.index(after: lastQuote)..<quoted.index(before: quoted.endIndex)])
            .replacingOccurrences(of: "\\/", with: "/")
        let jsURLString = rawPath.hasPrefix("http") ? rawPath : "https://www.youtube.com\(rawPath)"
        guard let jsURL = URL(string: jsURLString) else { return nil }
        var jsReq = URLRequest(url: jsURL)
        jsReq.timeoutInterval = 5.0
        jsReq.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (jsData, _) = try? await URLSession.shared.data(for: jsReq),
              let jsText = String(data: jsData, encoding: .utf8),
              let stsRange = jsText.range(of: #"signatureTimestamp\s*:\s*(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = jsText[stsRange].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let val = Int(digits), val > 10000 {
            await stsCache.store(val)
            return val
        }
        return nil
    }

    private static func fetchInnerTubeIfEnabled(
        _ enabled: Bool,
        videoID: String,
        sourcePageURL: URL,
        clientName: String,
        clientHeaderID: String,
        clientVersion: String,
        userAgent: String,
        extraClientFields: [String: Any],
        visitorData: String?,
        cookiesHeader: String?,
        signatureTimestamp: Int? = nil
    ) async -> YouTubeResolvedResult? {
        guard enabled else { return nil }
        return await fetchInnerTube(
            videoID: videoID,
            sourcePageURL: sourcePageURL,
            clientName: clientName,
            clientHeaderID: clientHeaderID,
            clientVersion: clientVersion,
            userAgent: userAgent,
            extraClientFields: extraClientFields,
            visitorData: visitorData,
            cookiesHeader: cookiesHeader,
            signatureTimestamp: signatureTimestamp
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
        cookiesHeader: String?,
        signatureTimestamp: Int? = nil
    ) async -> YouTubeResolvedResult? {
        guard let dict = await fetchInnerTubePlayerDict(
            videoID: videoID,
            clientName: clientName,
            clientHeaderID: clientHeaderID,
            clientVersion: clientVersion,
            userAgent: userAgent,
            extraClientFields: extraClientFields,
            visitorData: visitorData,
            cookiesHeader: cookiesHeader,
            signatureTimestamp: signatureTimestamp
        ) else {
            return nil
        }

        let isWebClient = clientName == "WEB" || clientName == "MWEB" || clientName == "WEB_REMIX" || clientName == "TVHTML5"
        var headers = ["User-Agent": userAgent]
        if isWebClient, let cookiesHeader, !cookiesHeader.isEmpty {
            headers["Cookie"] = cookiesHeader
        }
        return parsePlayerResponse(
            dict: dict,
            videoID: videoID,
            sourcePageURL: sourcePageURL,
            headers: headers,
            includeReferer: isWebClient
        )
    }

    private static func fetchInnerTubePlayerDict(
        videoID: String,
        clientName: String,
        clientHeaderID: String,
        clientVersion: String,
        userAgent: String,
        extraClientFields: [String: Any],
        visitorData: String?,
        cookiesHeader: String?,
        signatureTimestamp: Int? = nil
    ) async -> [String: Any]? {
        let baseHost = clientName == "MWEB" ? "https://m.youtube.com" : (clientName == "WEB_REMIX" ? "https://music.youtube.com" : "https://www.youtube.com")
        guard let apiURL = URL(string: "\(baseHost)/youtubei/v1/player?prettyPrint=false") else {
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

        var bodyDict: [String: Any] = [
            "videoId": videoID,
            "context": ["client": clientObj],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        if let signatureTimestamp {
            bodyDict["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": signatureTimestamp
                ]
            ]
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            return nil
        }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(baseHost, forHTTPHeaderField: "Origin")
        req.setValue("\(baseHost)/", forHTTPHeaderField: "Referer")
        req.setValue(clientHeaderID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData, !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let cookiesHeader, !cookiesHeader.isEmpty {
            req.setValue(cookiesHeader, forHTTPHeaderField: "Cookie")
            let authHeaders = sapisidAuthHeaders(cookiesHeader: cookiesHeader, origin: baseHost)
            authHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    struct CaptionTrack {
        let baseURL: URL
        let languageCode: String
        let name: String
    }

    /// Fetches creator-uploaded (non-ASR) timed subtitle tracks from YouTube player metadata.
    static func fetchCreatorCaptionTracks(videoID: String) async -> [CaptionTrack] {
        let trimmedID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return [] }

        let visitorData = await visitorCache.current()
        let iosDict = await fetchInnerTubePlayerDict(
            videoID: trimmedID,
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
        )
        let dict: [String: Any]?
        if let iosDict,
           ((iosDict["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]) != nil {
            dict = iosDict
        } else {
            dict = await fetchInnerTubePlayerDict(
                videoID: trimmedID,
                clientName: "ANDROID",
                clientHeaderID: "3",
                clientVersion: androidClientVersion,
                userAgent: androidClientUserAgent,
                extraClientFields: ["androidSdkVersion": 34],
                visitorData: visitorData,
                cookiesHeader: nil
            )
        }

        let captions = (dict?["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        guard let rawTracks = captions?["captionTracks"] as? [[String: Any]] else {
            return []
        }

        return rawTracks.compactMap { entry in
            // Skip auto-generated speech recognition ("asr") to avoid misheard lyrics
            if (entry["kind"] as? String)?.lowercased() == "asr" {
                return nil
            }
            guard let urlStr = entry["baseUrl"] as? String,
                  let url = URL(string: urlStr) else {
                return nil
            }
            let lang = (entry["languageCode"] as? String) ?? ""
            let nameDict = entry["name"] as? [String: Any]
            let runs = nameDict?["runs"] as? [[String: Any]]
            let name = (nameDict?["simpleText"] as? String)
                ?? (runs?.first?["text"] as? String)
                ?? lang
            return CaptionTrack(baseURL: url, languageCode: lang, name: name)
        }
    }

    private static func fetchMobileWebHTML(
        videoID: String,
        sourcePageURL: URL,
        cookiesHeader: String?,
        referer: String?
    ) async -> (result: YouTubeResolvedResult?, visitorData: String?) {
        guard let watchURL = URL(string: "https://m.youtube.com/watch?v=\(videoID)") else {
            return (nil, nil)
        }
        var req = URLRequest(url: watchURL)
        req.timeoutInterval = 8
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let effectiveCookies: String
        if let cookiesHeader, !cookiesHeader.isEmpty {
            effectiveCookies = cookiesHeader
        } else {
            effectiveCookies = "CONSENT=YES+cb.20210328-17-p0.en+FX+299; SOCS=CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg"
        }
        req.setValue(effectiveCookies, forHTTPHeaderField: "Cookie")
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return (nil, nil)
        }

        let extractedVD = extractVisitorData(fromHTML: html)
        guard let playerDict = extractPlayerResponseFromHTML(html) else {
            return (nil, extractedVD)
        }

        var headers = ["User-Agent": WebMediaDownloader.browserUserAgent, "Referer": watchURL.absoluteString]
        if let cookiesHeader, !cookiesHeader.isEmpty {
            headers["Cookie"] = cookiesHeader
        }
        let parsed = parsePlayerResponse(
            dict: playerDict,
            videoID: videoID,
            sourcePageURL: sourcePageURL,
            headers: headers
        )
        let responseVD = ((playerDict["responseContext"] as? [String: Any])?["visitorData"] as? String) ?? extractedVD
        return (parsed, responseVD)
    }

    private static func extractVisitorData(fromHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""visitorData"\s*:\s*"([^"]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
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
        headers: [String: String]?,
        includeReferer: Bool = true
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
        let refererStr: String? = includeReferer ? (sourcePageURL?.absoluteString ?? "https://m.youtube.com/watch?v=\(videoID)") : nil

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
                // Pair top H.264/MP4 adaptive streams with best M4A audio (including 360p/240p videos)
                for v in adaptiveVideos.prefix(3) {
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

    // MARK: - Age-Restricted / Confirm-Age Resilient Alternate Resolution

    static func isAgeOrLoginRestrictedReason(_ reason: String?) -> Bool {
        guard let lower = reason?.lowercased(), !lower.isEmpty else { return false }
        return lower.contains("confirm your age")
            || lower.contains("sign in")
            || lower.contains("inappropriate")
            || lower.contains("age")
            || lower.contains("login_required")
    }

    private actor SoundCloudClientIDCache {
        private var cached: (id: String, fetchedAt: Date)?

        func current() -> String? {
            guard let cached, Date().timeIntervalSince(cached.fetchedAt) < 3600 else { return nil }
            return cached.id
        }

        func store(_ id: String) {
            cached = (id, Date())
        }
    }

    private static let scClientCache = SoundCloudClientIDCache()

    /// Resolves a verified equivalent public stream (alternate non-restricted upload or SoundCloud match)
    /// when YouTube blocks a track behind an age-restriction / age-confirmation wall even after sign-in attempts.
    static func resolveAgeRestrictedFallback(
        videoID: String,
        title: String?,
        author: String?,
        durationSeconds: Double?
    ) async -> YouTubeResolvedResult? {
        let publicMeta = await fetchPublicVideoMetadata(videoID: videoID)
        let effectiveTitle: String = {
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty,
               t.caseInsensitiveCompare("YouTube Video") != .orderedSame {
                return t
            }
            return publicMeta.title ?? "YouTube Video"
        }()
        let effectiveAuthor = author ?? publicMeta.author
        let effectiveDuration = durationSeconds ?? publicMeta.durationSeconds

        guard effectiveTitle.caseInsensitiveCompare("YouTube Video") != .orderedSame,
              !effectiveTitle.isEmpty else {
            return nil
        }

        // Clean title & query for accurate matching (strip parenthetical edition noise while keeping song core).
        let searchQuery = cleanSearchText(effectiveTitle, author: effectiveAuthor)
        guard !searchQuery.isEmpty else { return nil }

        // 1. Check non-age-restricted YouTube reuploads with matching title + duration first.
        if let altYT = await resolveNonRestrictedYouTubeAlternative(
            excludingVideoID: videoID,
            query: searchQuery,
            targetTitle: effectiveTitle,
            targetDuration: effectiveDuration
        ) {
            return YouTubeResolvedResult(
                videoID: videoID,
                title: effectiveTitle,
                author: effectiveAuthor ?? altYT.author,
                durationSeconds: effectiveDuration ?? altYT.durationSeconds,
                streams: altYT.streams,
                errorReason: nil
            )
        }

        // 2. Check SoundCloud public catalog with strict title + duration verification.
        if let scStreams = await resolveSoundCloudAlternateStream(
            query: searchQuery,
            targetTitle: effectiveTitle,
            targetAuthor: effectiveAuthor,
            targetDuration: effectiveDuration
        ), !scStreams.isEmpty {
            return YouTubeResolvedResult(
                videoID: videoID,
                title: effectiveTitle,
                author: effectiveAuthor,
                durationSeconds: effectiveDuration ?? scStreams.first?.durationSeconds,
                streams: scStreams,
                errorReason: nil
            )
        }

        return nil
    }

    private static func fetchPublicVideoMetadata(videoID: String) async -> (title: String?, author: String?, durationSeconds: Double?) {
        var resolvedTitle: String?
        var resolvedAuthor: String?
        var resolvedDuration: Double?

        if let oembedURL = URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoID)&format=json") {
            var req = URLRequest(url: oembedURL)
            req.timeoutInterval = 4.0
            req.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resolvedTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                resolvedAuthor = (obj["author_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if resolvedDuration == nil,
           let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
            var req = URLRequest(url: watchURL)
            req.timeoutInterval = 4.5
            req.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("CONSENT=YES+cb.20210328-17-p0.en+FX+299", forHTTPHeaderField: "Cookie")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let html = String(data: data, encoding: .utf8) {
                if let match = html.range(of: #""lengthSeconds"\s*:\s*"(\d+)""#, options: .regularExpression) {
                    let digits = html[match].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    if let sec = Double(digits), sec > 0 {
                        resolvedDuration = sec
                    }
                }
                if (resolvedTitle == nil || resolvedTitle?.isEmpty == true),
                   let tRange = html.range(of: #""title"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                    let raw = String(html[tRange])
                    if let firstQ = raw.lastIndex(of: "\"") {
                        let sub = raw[..<firstQ]
                        if let prevQ = sub.lastIndex(of: "\"") {
                            resolvedTitle = String(sub[sub.index(after: prevQ)...])
                        }
                    }
                }
            }
        }

        return (resolvedTitle, resolvedAuthor, resolvedDuration)
    }

    private static func normalizedWordTokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let replaced = folded.replacingOccurrences(of: "$", with: "s")
        let stopWords: Set<String> = [
            "the", "and", "with", "feat", "ft", "featuring", "official", "video", "audio",
            "music", "lyrics", "lyric", "visualizer", "hd", "hq", "prod", "by", "full", "stream"
        ]
        let rawTokens = replaced.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return rawTokens.filter { !$0.isEmpty && !stopWords.contains($0) && $0.count >= 2 }
    }

    private static func titleTokenOverlap(_ a: String, _ b: String) -> Double {
        let ta = Set(normalizedWordTokens(a))
        let tb = Set(normalizedWordTokens(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = Double(ta.intersection(tb).count)
        let denom = Double(min(ta.count, tb.count))
        return denom > 0 ? inter / denom : 0
    }

    private static func cleanSearchText(_ rawTitle: String, author: String?) -> String {
        var cleaned = rawTitle
            .replacingOccurrences(of: #"\s*[\(\[]\s*(?:official\s*(?:music\s*)?(?:video|audio)|lyrics?|hd|hq|4k|explicit)[^\)\]]*[\)\]]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*(?:ft\.?|feat\.?)\s+"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "$", with: "s")
        cleaned = cleaned.replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if let author, !author.isEmpty {
            let authorTokens = Set(normalizedWordTokens(author))
            let titleTokens = Set(normalizedWordTokens(cleaned))
            if !authorTokens.isEmpty && authorTokens.isDisjoint(with: titleTokens) && !author.lowercased().contains("topic") {
                return "\(author) \(cleaned)"
            }
        }
        return cleaned
    }

    private static func resolveNonRestrictedYouTubeAlternative(
        excludingVideoID: String,
        query: String,
        targetTitle: String,
        targetDuration: Double?
    ) async -> YouTubeResolvedResult? {
        let hits = await PlaylistURLImporter.searchYouTubeTracks(query: query, limit: 6)
        for hit in hits {
            guard hit.videoID != excludingVideoID else { continue }
            if let targetDuration, targetDuration > 15,
               let hitDur = hit.durationSeconds, hitDur > 0 {
                let tol = max(8.0, targetDuration * 0.05)
                guard abs(hitDur - targetDuration) <= tol else { continue }
            }
            let overlap = titleTokenOverlap(targetTitle, hit.title)
            guard overlap >= 0.72 else { continue }
            guard let altURL = URL(string: "https://www.youtube.com/watch?v=\(hit.videoID)") else { continue }

            let android = await fetchInnerTube(
                videoID: hit.videoID,
                sourcePageURL: altURL,
                clientName: "ANDROID",
                clientHeaderID: "3",
                clientVersion: androidClientVersion,
                userAgent: androidClientUserAgent,
                extraClientFields: ["osName": "Android", "osVersion": "14", "androidSdkVersion": 34],
                visitorData: nil,
                cookiesHeader: nil
            )
            if let streams = android?.streams, !streams.isEmpty {
                let reachable = await filterReachableStreams(streams)
                if !reachable.isEmpty {
                    return YouTubeResolvedResult(
                        videoID: hit.videoID,
                        title: hit.title,
                        author: android?.author ?? hit.artist,
                        durationSeconds: android?.durationSeconds ?? hit.durationSeconds,
                        streams: reachable,
                        errorReason: nil
                    )
                }
            }
        }
        return nil
    }

    private static func resolveSoundCloudAlternateStream(
        query: String,
        targetTitle: String,
        targetAuthor: String?,
        targetDuration: Double?
    ) async -> [DetectedBrowserMedia]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://soundcloud.com/search/sounds?q=\(encoded)") else {
            return nil
        }

        var sReq = URLRequest(url: searchURL)
        sReq.timeoutInterval = 5.0
        sReq.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (sData, sResp) = try? await URLSession.shared.data(for: sReq),
              let sHTTP = sResp as? HTTPURLResponse,
              (200...299).contains(sHTTP.statusCode),
              let searchHTML = String(data: sData, encoding: .utf8) else {
            return nil
        }

        let bannedRoots: Set<String> = [
            "search", "discover", "you", "settings", "terms-of-use", "pages", "charts",
            "popular", "upload", "jobs", "people", "pro", "go", "signin", "signup",
            "stream", "stations", "mobile", "imprint", "messages", "notifications", "sets"
        ]
        guard let pathRegex = try? NSRegularExpression(pattern: #"href="(/[a-zA-Z0-9_-]{2,60}/[a-zA-Z0-9_-]{2,80})""#) else {
            return nil
        }
        let matches = pathRegex.matches(in: searchHTML, range: NSRange(searchHTML.startIndex..., in: searchHTML))
        var seenPaths = Set<String>()
        var candidateURLs: [(url: URL, slugScore: Double)] = []
        let targetTokens = Set(normalizedWordTokens(targetTitle))
        for m in matches {
            guard let r = Range(m.range(at: 1), in: searchHTML) else { continue }
            let path = String(searchHTML[r])
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2,
                  !bannedRoots.contains(parts[0].lowercased()),
                  !bannedRoots.contains(parts[1].lowercased()),
                  seenPaths.insert(path).inserted,
                  let fullURL = URL(string: "https://soundcloud.com\(path)") else {
                continue
            }
            let slugOverlap = titleTokenOverlap(targetTitle, parts[1].replacingOccurrences(of: "-", with: " "))
            candidateURLs.append((fullURL, slugOverlap))
        }
        candidateURLs.sort { $0.slugScore > $1.slugScore }

        for entry in candidateURLs.prefix(4) {
            if Task.isCancelled { return nil }
            var tReq = URLRequest(url: entry.url)
            tReq.timeoutInterval = 5.0
            tReq.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (tData, tResp) = try? await URLSession.shared.data(for: tReq),
                  let tHTTP = tResp as? HTTPURLResponse,
                  (200...299).contains(tHTTP.statusCode),
                  let html = String(data: tData, encoding: .utf8) else {
                continue
            }

            // Extract track duration & title to guard strictly against wrong clips.
            var trackDur: Double?
            if let dRange = html.range(of: #""full_duration"\s*:\s*(\d+)"#, options: .regularExpression) {
                let digits = html[dRange].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if let ms = Double(digits), ms > 0 {
                    trackDur = ms / 1000.0
                }
            }
            if let targetDuration, targetDuration > 15 {
                guard let td = trackDur, td > 15 else { continue }
                let tol = max(6.0, targetDuration * 0.04)
                guard abs(td - targetDuration) <= tol else { continue }
            }

            var pageTitle = ""
            if let titleRange = html.range(of: #"<title>([^<]+)</title>"#, options: .regularExpression) {
                pageTitle = String(html[titleRange])
                    .replacingOccurrences(of: "<title>", with: "")
                    .replacingOccurrences(of: "</title>", with: "")
                    .replacingOccurrences(of: "Stream ", with: "")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&#x27;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
            }
            let overlap = max(entry.slugScore, titleTokenOverlap(targetTitle, pageTitle))
            guard overlap >= 0.50 || targetTokens.isSubset(of: Set(normalizedWordTokens(pageTitle))) else {
                continue
            }

            var trackAuth = ""
            if let taRange = html.range(of: #""track_authorization"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                let slice = String(html[taRange])
                if let q = slice.dropLast().lastIndex(of: "\"") {
                    trackAuth = String(slice[slice.index(after: q)..<slice.index(before: slice.endIndex)])
                }
            }

            // Prefer progressive HTTP audio first, then HLS playlist.
            var transcodings: [String] = []
            if let transRegex = try? NSRegularExpression(pattern: #""url"\s*:\s*"(https://api-v2\.soundcloud\.com/media/[^"]+)""#) {
                let tm = transRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for m in tm {
                    if let rr = Range(m.range(at: 1), in: html) {
                        transcodings.append(String(html[rr]))
                    }
                }
            }
            guard !transcodings.isEmpty else { continue }
            let orderedTrans = transcodings.filter { $0.contains("/progressive") } + transcodings.filter { !$0.contains("/progressive") }

            guard let clientID = await resolveSoundCloudClientID(fromHTML: html) else { continue }

            for transURLStr in orderedTrans {
                let sep = transURLStr.contains("?") ? "&" : "?"
                var resolveStr = "\(transURLStr)\(sep)client_id=\(clientID)"
                if !trackAuth.isEmpty,
                   let encAuth = trackAuth.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    resolveStr += "&track_authorization=\(encAuth)"
                }
                guard let resolveURL = URL(string: resolveStr) else { continue }
                var apiReq = URLRequest(url: resolveURL)
                apiReq.timeoutInterval = 4.5
                apiReq.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
                guard let (aData, aResp) = try? await URLSession.shared.data(for: apiReq),
                      let aHTTP = aResp as? HTTPURLResponse,
                      (200...299).contains(aHTTP.statusCode),
                      let json = try? JSONSerialization.jsonObject(with: aData) as? [String: Any],
                      let streamStr = json["url"] as? String,
                      let streamURL = URL(string: streamStr) else {
                    continue
                }
                let hdrs = ["User-Agent": desktopBrowserUserAgent]
                let lowerStream = streamStr.lowercased()
                if lowerStream.contains("/opus") {
                    continue
                }
                guard await isURLReachable(streamURL, headers: hdrs) else {
                    continue
                }
                let isHLS = transURLStr.contains("/hls") || lowerStream.contains(".m3u8")
                let candidate = DetectedBrowserMedia(
                    url: streamURL,
                    pairedAudioURL: nil,
                    isHLS: isHLS,
                    isAudio: true,
                    title: targetTitle,
                    author: targetAuthor,
                    qualityLabel: isHLS ? "HLS Audio" : "MP3 Audio",
                    referer: entry.url.absoluteString,
                    customHeaders: hdrs,
                    durationSeconds: trackDur ?? targetDuration,
                    isActivelyPlaying: true
                )
                return [candidate]
            }
        }
        return nil
    }

    private static func resolveSoundCloudClientID(fromHTML html: String) async -> String? {
        if let cached = await scClientCache.current() {
            return cached
        }
        guard let jsRegex = try? NSRegularExpression(pattern: #"src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#) else {
            return nil
        }
        let matches = jsRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var urls: [URL] = []
        for m in matches {
            if let r = Range(m.range(at: 1), in: html), let u = URL(string: String(html[r])) {
                urls.append(u)
            }
        }
        for jsURL in urls.reversed().prefix(4) {
            var req = URLRequest(url: jsURL)
            req.timeoutInterval = 4.0
            req.setValue(desktopBrowserUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let jsText = String(data: data, encoding: .utf8),
                  let cidRegex = try? NSRegularExpression(pattern: #"client_id\s*[:=]\s*"([A-Za-z0-9]{20,40})""#),
                  let match = cidRegex.firstMatch(in: jsText, range: NSRange(jsText.startIndex..., in: jsText)),
                  let idRange = Range(match.range(at: 1), in: jsText) else {
                continue
            }
            let cid = String(jsText[idRange])
            await scClientCache.store(cid)
            return cid
        }
        return nil
    }
}
