import Foundation

enum ExternalPlaylistPlatform: String, Identifiable, Sendable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"
    case youtubeMusic = "YouTube Music"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .spotify: return "dot.radiowaves.left.and.right"
        case .appleMusic: return "music.note.list"
        case .youtubeMusic: return "play.rectangle.fill"
        }
    }
}

struct ParsedExternalPlaylistURL {
    let platform: ExternalPlaylistPlatform
    let playlistID: String
    let originalURL: URL?
}

enum PlaylistTrackImportState: Equatable {
    case pending
    case matching
    case downloading
    case saved
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "Queued"
        case .matching: return "Finding..."
        case .downloading: return "Saving..."
        case .saved: return "Saved"
        case .failed(let reason): return reason
        }
    }
}

struct ExternalPlaylistTrack: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let artist: String
    let youtubeVideoID: String?
    let durationText: String?
    var isSelected: Bool = true
    var state: PlaylistTrackImportState = .pending
}

struct LoadedExternalPlaylist {
    let platform: ExternalPlaylistPlatform
    let sourceID: String
    let title: String
    let tracks: [ExternalPlaylistTrack]
}

enum PlaylistImportError: LocalizedError {
    case invalidURL
    case fetchFailed(String)
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Paste a valid Spotify, Apple Music, YouTube, or YouTube Music playlist URL."
        case .fetchFailed(let msg):
            return msg
        case .emptyPlaylist:
            return "No tracks could be extracted from that playlist link. Make sure the playlist is public or unlisted."
        }
    }
}

enum PlaylistURLImporter {
    private static let webClientVersion = "2.20260301.01.00"
    private static let remixClientVersion = "1.20260301.01.00"
    private static let consentCookies = "CONSENT=YES+cb.20210328-17-p0.en+FX+299; SOCS=CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg"

    private static func extractFirstHTTPURL(in raw: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\)\]]+"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
            let matched = (raw as NSString).substring(with: match.range)
            return matched.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
        }
        return raw
    }

    static func parsePlaylistURL(_ rawString: String) -> ParsedExternalPlaylistURL? {
        var trimmed = extractFirstHTTPURL(in: rawString.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("spotify:playlist:") {
            let id = String(trimmed.dropFirst("spotify:playlist:".count))
                .components(separatedBy: CharacterSet(charactersIn: "?#&"))
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return nil }
            let url = URL(string: "https://open.spotify.com/playlist/\(id)")
            return ParsedExternalPlaylistURL(platform: .spotify, playlistID: id, originalURL: url)
        }

        if !trimmed.contains("://"), trimmed.contains(".") {
            trimmed = "https://\(trimmed)"
        }

        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            return nil
        }

        if host == "spotify.link" || host == "spoti.fi" {
            return ParsedExternalPlaylistURL(platform: .spotify, playlistID: "__shortlink__", originalURL: url)
        }

        if host.contains("spotify.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let idx = parts.firstIndex(of: "playlist"), idx + 1 < parts.count {
                let id = parts[idx + 1]
                if !id.isEmpty {
                    return ParsedExternalPlaylistURL(platform: .spotify, playlistID: id, originalURL: url)
                }
            }
        }

        if host.contains("music.apple.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.contains("playlist") || parts.last?.hasPrefix("pl.") == true {
                if let plID = parts.last(where: { $0.hasPrefix("pl.") || $0.hasPrefix("p.") }), !plID.isEmpty {
                    return ParsedExternalPlaylistURL(platform: .appleMusic, playlistID: plID, originalURL: url)
                }
                if let last = parts.last, parts.contains("playlist"), !last.isEmpty {
                    return ParsedExternalPlaylistURL(platform: .appleMusic, playlistID: last, originalURL: url)
                }
            }
        }

        if host.contains("youtube.com") || host.contains("youtu.be") {
            if url.path == "/attribution_link",
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let innerPath = comps.queryItems?.first(where: { $0.name == "u" })?.value {
                let innerFull = innerPath.hasPrefix("http") ? innerPath : "https://www.youtube.com\(innerPath.hasPrefix("/") ? innerPath : "/\(innerPath)")"
                if let unwrapped = parsePlaylistURL(innerFull) {
                    return unwrapped
                }
            }

            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let listID = comps.queryItems?.first(where: { $0.name == "list" })?.value,
               !listID.isEmpty {
                return ParsedExternalPlaylistURL(platform: .youtubeMusic, playlistID: listID, originalURL: url)
            }

            let parts = url.pathComponents.filter { $0 != "/" }
            if let idx = parts.firstIndex(of: "browse"), idx + 1 < parts.count {
                let rawBrowse = parts[idx + 1]
                if rawBrowse.hasPrefix("VL") || rawBrowse.hasPrefix("PL") || rawBrowse.hasPrefix("OLAK") || rawBrowse.hasPrefix("RDCLAK") || rawBrowse.hasPrefix("MPREb_") {
                    return ParsedExternalPlaylistURL(platform: .youtubeMusic, playlistID: rawBrowse, originalURL: url)
                }
            }

            if let regex = try? NSRegularExpression(pattern: #"[?&#]list=([A-Za-z0-9_-]+)"#),
               let m = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
               m.numberOfRanges >= 2 {
                let listID = (trimmed as NSString).substring(with: m.range(at: 1))
                if !listID.isEmpty {
                    return ParsedExternalPlaylistURL(platform: .youtubeMusic, playlistID: listID, originalURL: url)
                }
            }
        }

        return nil
    }

    // MARK: - YouTube & YouTube Music Playlist (InnerTube + HTML fallback, no API key)

    struct PlaylistStreamPage: Sendable {
        let playlistTitle: String
        let platform: ExternalPlaylistPlatform
        let playlistID: String
        let newTracks: [ExternalPlaylistTrack]
        let totalFetchedCount: Int
        let pageNumber: Int
        let isComplete: Bool
    }

    static func fetchPlaylist(from rawString: String) async throws -> LoadedExternalPlaylist {
        try await streamPlaylist(from: rawString, cookiesHeader: nil) { _ in }
    }

    static func streamPlaylist(
        from rawString: String,
        cookiesHeader: String? = nil,
        onPage: @escaping @Sendable (PlaylistStreamPage) async -> Void
    ) async throws -> LoadedExternalPlaylist {
        guard let parsed = parsePlaylistURL(rawString) else {
            throw PlaylistImportError.invalidURL
        }

        switch parsed.platform {
        case .youtubeMusic:
            let seedVideoID = parsed.originalURL.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "v" })?
                    .value
            }
            return try await streamYouTubePlaylist(
                listID: parsed.playlistID,
                seedVideoID: seedVideoID,
                cookiesHeader: cookiesHeader,
                onPage: onPage
            )
        case .spotify:
            let loaded = try await fetchSpotifyPlaylist(id: parsed.playlistID, originalURL: parsed.originalURL)
            await onPage(PlaylistStreamPage(
                playlistTitle: loaded.title,
                platform: loaded.platform,
                playlistID: loaded.sourceID,
                newTracks: loaded.tracks,
                totalFetchedCount: loaded.tracks.count,
                pageNumber: 1,
                isComplete: true
            ))
            return loaded
        case .appleMusic:
            guard let url = parsed.originalURL else { throw PlaylistImportError.invalidURL }
            let loaded = try await fetchAppleMusicPlaylist(url: url, id: parsed.playlistID)
            await onPage(PlaylistStreamPage(
                playlistTitle: loaded.title,
                platform: loaded.platform,
                playlistID: loaded.sourceID,
                newTracks: loaded.tracks,
                totalFetchedCount: loaded.tracks.count,
                pageNumber: 1,
                isComplete: true
            ))
            return loaded
        }
    }

    private static func fetchYouTubePlaylist(listID: String) async throws -> LoadedExternalPlaylist {
        try await streamYouTubePlaylist(listID: listID, seedVideoID: nil, cookiesHeader: nil) { _ in }
    }

    private static func mergedYouTubeCookies(_ cookiesHeader: String?) async -> String {
        var parts: [String] = []
        if let cookiesHeader, !cookiesHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(cookiesHeader)
        } else if let browserCookies = await BrowserYouTubeResolver.youtubeCookieHeader(), !browserCookies.isEmpty {
            parts.append(browserCookies)
        }
        let joined = parts.joined(separator: "; ")
        var extras: [String] = []
        if !joined.contains("CONSENT=") {
            extras.append("CONSENT=YES+cb.20210328-17-p0.en+FX+299")
        }
        if !joined.contains("SOCS=") {
            extras.append("SOCS=CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg")
        }
        if extras.isEmpty { return joined }
        if joined.isEmpty { return extras.joined(separator: "; ") }
        return "\(joined); \(extras.joined(separator: "; "))"
    }

    private static func streamYouTubePlaylist(
        listID: String,
        seedVideoID: String?,
        cookiesHeader: String?,
        onPage: @escaping @Sendable (PlaylistStreamPage) async -> Void
    ) async throws -> LoadedExternalPlaylist {
        let browseID: String
        if listID.hasPrefix("VL") || listID.hasPrefix("MPREb_") {
            browseID = listID
        } else {
            browseID = "VL\(listID)"
        }
        let queryPlaylistID = listID.hasPrefix("VL") ? String(listID.dropFirst(2)) : listID
        let preferRemix = listID.hasPrefix("OLAK") || listID.hasPrefix("RDCLAK") || listID.hasPrefix("MPREb_") || listID.hasPrefix("VLOLAK") || listID.hasPrefix("VLRDCLAK")
        var effectiveCookies = await mergedYouTubeCookies(cookiesHeader)

        var playlistTitle = "YouTube Playlist"
        var tracks: [ExternalPlaylistTrack] = []
        var seenVideoIDs = Set<String>()
        var pendingTokens: [String] = []
        var usedRemixForPagination = preferRemix
        var paginationUsesNext = false
        var liveAPIKey: String?
        var liveClientVersion: String?
        var liveVisitorData: String?

        func absorbPage(from json: [String: Any]) -> Bool {
            if let parsedTitle = extractYouTubePlaylistTitle(from: json),
               !parsedTitle.isEmpty,
               (playlistTitle == "YouTube Playlist" || parsedTitle != "YouTube") {
                playlistTitle = parsedTitle
            }
            let page = extractYouTubePlaylistPage(from: json, seenIDs: &seenVideoIDs)
            tracks.append(contentsOf: page.tracks)
            for token in page.continuations where !pendingTokens.contains(token) {
                pendingTokens.append(token)
            }
            return !page.tracks.isEmpty
        }

        // Stage 1: Primary InnerTube browse (WEB_REMIX for albums/music, WEB for standard playlists)
        if let json1 = await fetchYouTubeBrowse(
            browseID: browseID,
            continuation: nil,
            useMusicRemix: preferRemix,
            cookiesHeader: effectiveCookies
        ) {
            _ = absorbPage(from: json1)
        }

        // Stage 2: Alternate InnerTube client whenever tracks are still empty (even if JSON wasn't nil)
        if tracks.isEmpty {
            if let json2 = await fetchYouTubeBrowse(
                browseID: browseID,
                continuation: nil,
                useMusicRemix: !preferRemix,
                cookiesHeader: effectiveCookies
            ), absorbPage(from: json2) {
                usedRemixForPagination = !preferRemix
            }
        }

        // Stage 3: Desktop / Music / Mobile HTML scraping (+ extracting live InnerTube key/version/visitorData)
        if tracks.isEmpty, let encoded = queryPlaylistID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            let htmlTargets: [(url: String, ua: String, isRemix: Bool)] = listID.hasPrefix("MPREb_")
                ? [("https://music.youtube.com/browse/\(encoded)", desktopYouTubeUserAgent, true)]
                : [
                    ("https://www.youtube.com/playlist?list=\(encoded)&hl=en", desktopYouTubeUserAgent, false),
                    ("https://music.youtube.com/playlist?list=\(encoded)&hl=en", desktopYouTubeUserAgent, true),
                    ("https://m.youtube.com/playlist?list=\(encoded)&hl=en", WebMediaDownloader.browserUserAgent, false)
                ]
            for target in htmlTargets where tracks.isEmpty {
                let bootstrap = await fetchYouTubePlaylistHTMLBootstrap(
                    urlString: target.url,
                    cookiesHeader: effectiveCookies,
                    userAgent: target.ua
                )
                if liveAPIKey == nil { liveAPIKey = bootstrap.apiKey }
                if liveClientVersion == nil, !target.isRemix { liveClientVersion = bootstrap.clientVersion }
                if liveVisitorData == nil { liveVisitorData = bootstrap.visitorData }
                if let initialData = bootstrap.initialData, absorbPage(from: initialData) {
                    usedRemixForPagination = target.isRemix
                    break
                }
            }
        }

        // Retry InnerTube browse with freshly scraped live API key & visitorData if HTML yielded metadata without rows
        if tracks.isEmpty && (liveAPIKey != nil || liveVisitorData != nil) {
            if let jsonKeyed = await fetchYouTubeBrowse(
                browseID: browseID,
                continuation: nil,
                useMusicRemix: false,
                cookiesHeader: effectiveCookies,
                apiKey: liveAPIKey,
                clientVersionOverride: liveClientVersion,
                visitorData: liveVisitorData
            ), absorbPage(from: jsonKeyed) {
                usedRemixForPagination = false
            }
        }

        // Stage 4: InnerTube `next` endpoint (Mixes RD*, watch?v=...&list=..., Watch Later, Radio)
        if tracks.isEmpty && !listID.hasPrefix("MPREb_"),
           let nextJSON = await fetchYouTubeNext(
               videoID: seedVideoID,
               playlistID: queryPlaylistID,
               continuation: nil,
               cookiesHeader: effectiveCookies,
               apiKey: liveAPIKey,
               clientVersionOverride: liveClientVersion,
               visitorData: liveVisitorData
           ),
           absorbPage(from: nextJSON) {
            paginationUsesNext = true
        }

        // Stage 5: Built-in WKWebView browser fallback (executes YouTube JS, uses logged-in cookies, scrapes DOM)
        if tracks.isEmpty, let encoded = queryPlaylistID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            let browserCandidates: [String]
            if listID.hasPrefix("MPREb_") {
                browserCandidates = ["https://music.youtube.com/browse/\(encoded)"]
            } else if preferRemix {
                browserCandidates = ["https://music.youtube.com/playlist?list=\(encoded)", "https://www.youtube.com/playlist?list=\(encoded)"]
            } else {
                browserCandidates = ["https://www.youtube.com/playlist?list=\(encoded)"]
            }
            for candidate in browserCandidates where tracks.isEmpty {
                guard let url = URL(string: candidate) else { continue }
                if let browserRes = await BrowserYouTubeResolver.shared.extractPlaylistInitialDataInBrowser(url: url) {
                    if let updatedCookies = browserRes.cookiesHeader, !updatedCookies.isEmpty {
                        effectiveCookies = await mergedYouTubeCookies(updatedCookies)
                    }
                    if absorbPage(from: browserRes.json) {
                        usedRemixForPagination = candidate.contains("music.youtube.com")
                        break
                    }
                }
            }
        }

        if !tracks.isEmpty {
            await onPage(PlaylistStreamPage(
                playlistTitle: playlistTitle,
                platform: .youtubeMusic,
                playlistID: listID,
                newTracks: tracks,
                totalFetchedCount: tracks.count,
                pageNumber: 1,
                isComplete: pendingTokens.isEmpty
            ))
        }

        var visitedTokens = Set<String>()
        var pageCount = 1
        var cursor = 0

        // No page or track cap — supports 5,000+ track playlists cleanly with cycle protection and retries.
        while cursor < pendingTokens.count {
            try Task.checkCancellation()
            let token = pendingTokens[cursor]
            cursor += 1
            guard !token.isEmpty, visitedTokens.insert(token).inserted else { continue }

            var pageJSON: [String: Any]?
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if paginationUsesNext {
                    pageJSON = await fetchYouTubeNext(
                        videoID: seedVideoID,
                        playlistID: listID,
                        continuation: token,
                        cookiesHeader: effectiveCookies,
                        apiKey: liveAPIKey,
                        clientVersionOverride: liveClientVersion,
                        visitorData: liveVisitorData
                    )
                } else {
                    pageJSON = await fetchYouTubeBrowse(
                        browseID: nil,
                        continuation: token,
                        useMusicRemix: usedRemixForPagination,
                        cookiesHeader: effectiveCookies,
                        apiKey: liveAPIKey,
                        clientVersionOverride: usedRemixForPagination ? nil : liveClientVersion,
                        visitorData: liveVisitorData
                    )
                    if pageJSON == nil && attempt == 0 {
                        pageJSON = await fetchYouTubeBrowse(
                            browseID: nil,
                            continuation: token,
                            useMusicRemix: !usedRemixForPagination,
                            cookiesHeader: effectiveCookies,
                            apiKey: liveAPIKey,
                            visitorData: liveVisitorData
                        )
                    }
                }
                if pageJSON != nil { break }
                try? await Task.sleep(nanoseconds: UInt64(350_000_000 * (attempt + 1)))
            }

            guard let pageJSON else { continue }
            let nextPage = extractYouTubePlaylistPage(from: pageJSON, seenIDs: &seenVideoIDs)
            for newTok in nextPage.continuations where !visitedTokens.contains(newTok) && !pendingTokens.contains(newTok) {
                pendingTokens.append(newTok)
            }
            if nextPage.tracks.isEmpty {
                continue
            }

            pageCount += 1
            tracks.append(contentsOf: nextPage.tracks)

            await onPage(PlaylistStreamPage(
                playlistTitle: playlistTitle,
                platform: .youtubeMusic,
                playlistID: listID,
                newTracks: nextPage.tracks,
                totalFetchedCount: tracks.count,
                pageNumber: pageCount,
                isComplete: cursor >= pendingTokens.count
            ))
        }

        guard !tracks.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        await onPage(PlaylistStreamPage(
            playlistTitle: playlistTitle,
            platform: .youtubeMusic,
            playlistID: listID,
            newTracks: [],
            totalFetchedCount: tracks.count,
            pageNumber: pageCount,
            isComplete: true
        ))

        return LoadedExternalPlaylist(
            platform: .youtubeMusic,
            sourceID: listID,
            title: playlistTitle,
            tracks: tracks
        )
    }

    private static let desktopYouTubeUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Public helper so BrowserTabView's logged-in WKWebView can hand over live `window.ytInitialData`
    /// (for private/Watch-Later/age-restricted playlists) and continue paginating via InnerTube.
    static func continueYouTubePlaylist(
        fromInitialJSON initialJSON: [String: Any],
        listID: String,
        cookiesHeader: String?,
        onPage: @escaping @Sendable (PlaylistStreamPage) async -> Void
    ) async throws -> LoadedExternalPlaylist {
        let effectiveCookies = await mergedYouTubeCookies(cookiesHeader)
        let playlistTitle = extractYouTubePlaylistTitle(from: initialJSON) ?? "YouTube Playlist"
        var seenVideoIDs = Set<String>()
        var tracks: [ExternalPlaylistTrack] = []
        let firstPage = extractYouTubePlaylistPage(from: initialJSON, seenIDs: &seenVideoIDs)
        tracks.append(contentsOf: firstPage.tracks)

        var pendingTokens = firstPage.continuations
        var visitedTokens = Set<String>()
        var pageCount = 1
        var cursor = 0

        if !tracks.isEmpty {
            await onPage(PlaylistStreamPage(
                playlistTitle: playlistTitle,
                platform: .youtubeMusic,
                playlistID: listID,
                newTracks: tracks,
                totalFetchedCount: tracks.count,
                pageNumber: 1,
                isComplete: pendingTokens.isEmpty
            ))
        }

        while cursor < pendingTokens.count {
            try Task.checkCancellation()
            let token = pendingTokens[cursor]
            cursor += 1
            guard !token.isEmpty, visitedTokens.insert(token).inserted else { continue }

            var pageJSON: [String: Any]?
            for attempt in 0..<3 {
                try Task.checkCancellation()
                pageJSON = await fetchYouTubeBrowse(
                    browseID: nil,
                    continuation: token,
                    useMusicRemix: listID.hasPrefix("OLAK") || listID.hasPrefix("RDCLAK"),
                    cookiesHeader: effectiveCookies
                )
                if pageJSON == nil && attempt == 0 {
                    pageJSON = await fetchYouTubeBrowse(
                        browseID: nil,
                        continuation: token,
                        useMusicRemix: !(listID.hasPrefix("OLAK") || listID.hasPrefix("RDCLAK")),
                        cookiesHeader: effectiveCookies
                    )
                }
                if pageJSON != nil { break }
                try? await Task.sleep(nanoseconds: UInt64(350_000_000 * (attempt + 1)))
            }
            guard let pageJSON else { continue }
            let nextPage = extractYouTubePlaylistPage(from: pageJSON, seenIDs: &seenVideoIDs)
            for newTok in nextPage.continuations where !visitedTokens.contains(newTok) && !pendingTokens.contains(newTok) {
                pendingTokens.append(newTok)
            }
            if nextPage.tracks.isEmpty { continue }

            pageCount += 1
            tracks.append(contentsOf: nextPage.tracks)

            await onPage(PlaylistStreamPage(
                playlistTitle: playlistTitle,
                platform: .youtubeMusic,
                playlistID: listID,
                newTracks: nextPage.tracks,
                totalFetchedCount: tracks.count,
                pageNumber: pageCount,
                isComplete: cursor >= pendingTokens.count
            ))
        }

        guard !tracks.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        await onPage(PlaylistStreamPage(
            playlistTitle: playlistTitle,
            platform: .youtubeMusic,
            playlistID: listID,
            newTracks: [],
            totalFetchedCount: tracks.count,
            pageNumber: pageCount,
            isComplete: true
        ))

        return LoadedExternalPlaylist(
            platform: .youtubeMusic,
            sourceID: listID,
            title: playlistTitle,
            tracks: tracks
        )
    }

    private static func fetchYouTubeBrowse(
        browseID: String?,
        continuation: String?,
        useMusicRemix: Bool,
        cookiesHeader: String? = nil,
        apiKey: String? = nil,
        clientVersionOverride: String? = nil,
        visitorData: String? = nil
    ) async -> [String: Any]? {
        let baseEndpoint = useMusicRemix
            ? "https://music.youtube.com/youtubei/v1/browse"
            : "https://www.youtube.com/youtubei/v1/browse"
        let query = (apiKey?.isEmpty == false) ? "?key=\(apiKey!)&prettyPrint=false" : "?prettyPrint=false"
        guard let apiURL = URL(string: "\(baseEndpoint)\(query)") else {
            return nil
        }

        let origin = useMusicRemix ? "https://music.youtube.com" : "https://www.youtube.com"
        let clientName = useMusicRemix ? "WEB_REMIX" : "WEB"
        let clientVersion = clientVersionOverride ?? (useMusicRemix ? remixClientVersion : webClientVersion)
        let clientHeaderID = useMusicRemix ? "67" : "1"

        var body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]
        if let continuation {
            body["continuation"] = continuation
        } else if let browseID {
            body["browseId"] = browseID
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(desktopYouTubeUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func fetchYouTubeNext(
        videoID: String?,
        playlistID: String,
        continuation: String?,
        cookiesHeader: String? = nil,
        apiKey: String? = nil,
        clientVersionOverride: String? = nil,
        visitorData: String? = nil
    ) async -> [String: Any]? {
        let query = (apiKey?.isEmpty == false) ? "?key=\(apiKey!)&prettyPrint=false" : "?prettyPrint=false"
        guard let apiURL = URL(string: "https://www.youtube.com/youtubei/v1/next\(query)") else {
            return nil
        }

        let clientVersion = clientVersionOverride ?? webClientVersion
        var body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]
        if let continuation {
            body["continuation"] = continuation
        } else {
            body["playlistId"] = playlistID
            if let videoID, !videoID.isEmpty {
                body["videoId"] = videoID
            }
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(desktopYouTubeUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private struct YouTubeHTMLBootstrap {
        let initialData: [String: Any]?
        let apiKey: String?
        let clientVersion: String?
        let visitorData: String?
    }

    private static func fetchYouTubePlaylistHTMLBootstrap(
        urlString: String,
        cookiesHeader: String?,
        userAgent: String
    ) async -> YouTubeHTMLBootstrap {
        guard let url = URL(string: urlString) else {
            return YouTubeHTMLBootstrap(initialData: nil, apiKey: nil, clientVersion: nil, visitorData: nil)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let cookiesHeader, !cookiesHeader.isEmpty {
            req.setValue(cookiesHeader, forHTTPHeaderField: "Cookie")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return YouTubeHTMLBootstrap(initialData: nil, apiKey: nil, clientVersion: nil, visitorData: nil)
        }

        let apiKey = extractFirstRegexGroup(in: html, pattern: #""INNERTUBE_API_KEY"\s*:\s*"([^"]+)""#)
        let clientVersion = extractFirstRegexGroup(in: html, pattern: #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#)
        let visitorData = extractFirstRegexGroup(in: html, pattern: #""VISITOR_DATA"\s*:\s*"([^"]+)""#)

        var parsedDict: [String: Any]?
        for marker in ["var ytInitialData = ", "window[\"ytInitialData\"] = ", "ytInitialData = "] {
            if let range = html.range(of: marker) {
                let tail = html[range.upperBound...].drop(while: { $0.isWhitespace })
                if tail.first == "{",
                   let slice = balancedJSONObject(in: html, startingAt: tail.startIndex),
                   let sliceData = slice.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: sliceData) as? [String: Any] {
                    parsedDict = dict
                    break
                } else if tail.hasPrefix("JSON.parse(") || tail.first == "'" || tail.first == "\"",
                          let decoded = decodeQuotedJSStringJSON(in: String(tail.prefix(2_500_000))) {
                    parsedDict = decoded
                    break
                }
            }
        }

        // YouTube Music sometimes embeds initialData via `initialData.push({path: '/browse', data: '...'});`
        if parsedDict == nil,
           let pushRegex = try? NSRegularExpression(
               pattern: #"initialData\.push\(\{[^}]*?data\s*:\s*'((?:\\'|[^'])+)'"#,
               options: [.dotMatchesLineSeparators]
           ) {
            let nsHTML = html as NSString
            for match in pushRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) where match.numberOfRanges >= 2 {
                let escaped = nsHTML.substring(with: match.range(at: 1))
                if let dict = unescapeJSStringToJSON(escaped),
                   dict["contents"] != nil || dict["header"] != nil {
                    parsedDict = dict
                    break
                }
            }
        }

        return YouTubeHTMLBootstrap(
            initialData: parsedDict,
            apiKey: apiKey,
            clientVersion: clientVersion,
            visitorData: visitorData
        )
    }

    private static func extractFirstRegexGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges >= 2 else {
            return nil
        }
        return (text as NSString).substring(with: m.range(at: 1))
    }

    private static func decodeQuotedJSStringJSON(in tail: String) -> [String: Any]? {
        guard let quoteIdx = tail.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        let quoteChar = tail[quoteIdx]
        var idx = tail.index(after: quoteIdx)
        var escaped = ""
        var isEscaped = false
        while idx < tail.endIndex {
            let ch = tail[idx]
            if isEscaped {
                escaped.append(ch)
                isEscaped = false
            } else if ch == "\\" {
                escaped.append(ch)
                isEscaped = true
            } else if ch == quoteChar {
                break
            } else {
                escaped.append(ch)
            }
            idx = tail.index(after: idx)
        }
        return unescapeJSStringToJSON(escaped)
    }

    private static func unescapeJSStringToJSON(_ escaped: String) -> [String: Any]? {
        var result = ""
        result.reserveCapacity(escaped.count)
        var i = escaped.startIndex
        while i < escaped.endIndex {
            let ch = escaped[i]
            if ch == "\\" {
                let next = escaped.index(after: i)
                guard next < escaped.endIndex else { break }
                let esc = escaped[next]
                if esc == "x", let end = escaped.index(next, offsetBy: 3, limitedBy: escaped.endIndex) {
                    let hex = String(escaped[escaped.index(after: next)..<end])
                    if let byte = UInt8(hex, radix: 16) {
                        result.append(Character(UnicodeScalar(byte)))
                        i = end
                        continue
                    }
                } else if esc == "u", let end = escaped.index(next, offsetBy: 5, limitedBy: escaped.endIndex) {
                    let hex = String(escaped[escaped.index(after: next)..<end])
                    if let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) {
                        result.append(Character(scalar))
                        i = end
                        continue
                    }
                } else if esc == "'" {
                    result.append("'")
                    i = escaped.index(after: next)
                    continue
                } else if esc == "\"" {
                    result.append("\"")
                    i = escaped.index(after: next)
                    continue
                } else if esc == "\\" {
                    result.append("\\")
                    i = escaped.index(after: next)
                    continue
                }
            }
            result.append(ch)
            i = escaped.index(after: i)
        }
        guard let data = result.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func extractYouTubePlaylistTitle(from json: [String: Any]) -> String? {
        if let domTitle = json["__domTitle"] as? String, !domTitle.isEmpty {
            return cleanTitle(domTitle)
        }
        if let metadata = json["metadata"] as? [String: Any],
           let metaRenderer = metadata["playlistMetadataRenderer"] as? [String: Any],
           let title = metaRenderer["title"] as? String {
            return cleanTitle(title)
        }
        if let header = json["header"] as? [String: Any] {
            if let ph = header["playlistHeaderRenderer"] as? [String: Any],
               let t = ytText(ph["title"]) {
                return cleanTitle(t)
            }
            if let mh = header["musicDetailHeaderRenderer"] as? [String: Any],
               let t = ytText(mh["title"]) {
                return cleanTitle(t)
            }
            if let rmh = header["musicResponsiveHeaderRenderer"] as? [String: Any],
               let t = ytText(rmh["title"]) {
                return cleanTitle(t)
            }
            if let pg = header["pageHeaderRenderer"] as? [String: Any],
               let t = ytText(pg["pageTitle"]) ?? (pg["pageTitle"] as? String) {
                return cleanTitle(t)
            }
        }
        if let microformat = (json["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any],
           let title = microformat["title"] as? String {
            return cleanTitle(title)
        }
        return nil
    }

    private static func extractLockupVideoTrack(from lockup: [String: Any]) -> ExternalPlaylistTrack? {
        let contentType = lockup["contentType"] as? String ?? ""
        if contentType == "LOCKUP_CONTENT_TYPE_PLAYLIST" || contentType == "LOCKUP_CONTENT_TYPE_CHANNEL" {
            return nil
        }

        let onTap = ((lockup["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any])?["onTap"] as? [String: Any]
        let watchEndpoint = (onTap?["innertubeCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any]
            ?? (onTap?["watchEndpoint"] as? [String: Any])
        let watchVideoID = watchEndpoint?["videoId"] as? String
        let contentID = lockup["contentId"] as? String
        let looksLikeVideoID = contentID.map { id in
            id.count == 11 && id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
        } ?? false

        guard contentType == "LOCKUP_CONTENT_TYPE_VIDEO"
                || (watchVideoID != nil && !(watchVideoID?.isEmpty ?? true))
                || (contentType.isEmpty && looksLikeVideoID),
              let vid = (watchVideoID?.isEmpty == false ? watchVideoID : contentID),
              !vid.isEmpty else {
            return nil
        }

        let metaVM = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let titleContent = (metaVM?["title"] as? [String: Any])?["content"] as? String
        let a11yLabel = ((lockup["rendererContext"] as? [String: Any])?["accessibilityContext"] as? [String: Any])?["label"] as? String
        guard let rawTitle = titleContent ?? a11yLabel,
              !rawTitle.isEmpty,
              rawTitle != "[Deleted video]",
              rawTitle != "[Private video]" else {
            return nil
        }

        var rawArtist = ""
        if let rows = ((metaVM?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]] {
            rowLoop: for row in rows {
                guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
                for part in parts {
                    if let text = (part["text"] as? [String: Any])?["content"] as? String {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty,
                           !cleaned.lowercased().contains("views"),
                           !cleaned.lowercased().contains(" ago") {
                            rawArtist = cleaned.replacingOccurrences(of: " - Topic", with: "")
                            break rowLoop
                        }
                    }
                }
            }
        }
        if rawArtist.isEmpty,
           let a11yAvatar = (metaVM?["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any],
           let channelLabel = a11yAvatar["a11yLabel"] as? String {
            rawArtist = channelLabel
                .replacingOccurrences(of: "Go to channel ", with: "")
                .replacingOccurrences(of: " - Topic", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var duration: String?
        if let overlays = ((lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any])?["overlays"] as? [[String: Any]] {
            outer: for overlay in overlays {
                if let bottom = overlay["thumbnailBottomOverlayViewModel"] as? [String: Any],
                   let badges = bottom["badges"] as? [[String: Any]] {
                    for badge in badges {
                        if let text = (badge["thumbnailBadgeViewModel"] as? [String: Any])?["text"] as? String,
                           !text.isEmpty {
                            duration = text
                            break outer
                        }
                    }
                }
            }
        }

        return ExternalPlaylistTrack(
            title: cleanTitle(rawTitle),
            artist: rawArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            youtubeVideoID: vid,
            durationText: duration
        )
    }

    private static func extractContinuationToken(fromEndpoint ep: [String: Any]) -> String? {
        if let cmd = ep["continuationCommand"] as? [String: Any],
           let token = cmd["token"] as? String,
           !token.isEmpty {
            return token
        }
        if let executor = ep["commandExecutorCommand"] as? [String: Any],
           let commands = executor["commands"] as? [[String: Any]] {
            for c in commands {
                if let cmd = c["continuationCommand"] as? [String: Any],
                   let token = cmd["token"] as? String,
                   !token.isEmpty {
                    return token
                }
            }
        }
        return nil
    }

    private static func extractYouTubePlaylistPage(
        from root: Any,
        seenIDs: inout Set<String>
    ) -> (tracks: [ExternalPlaylistTrack], continuations: [String]) {
        var tracks: [ExternalPlaylistTrack] = []
        var primaryContinuations: [String] = []
        var secondaryContinuations: [String] = []
        var seenTokens = Set<String>()

        if let rootDict = root as? [String: Any],
           let domItems = rootDict["__domFallback"] as? [[String: Any]] {
            for item in domItems {
                guard let vid = item["videoId"] as? String,
                      !vid.isEmpty,
                      let rawTitle = item["title"] as? String,
                      !rawTitle.isEmpty,
                      rawTitle != "[Deleted video]",
                      rawTitle != "[Private video]",
                      seenIDs.insert(vid).inserted else {
                    continue
                }
                let rawArtist = ((item["artist"] as? String) ?? "")
                    .replacingOccurrences(of: " - Topic", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let duration = (item["duration"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                tracks.append(ExternalPlaylistTrack(
                    title: cleanTitle(rawTitle),
                    artist: rawArtist,
                    youtubeVideoID: vid,
                    durationText: (duration?.isEmpty == false) ? duration : nil
                ))
            }
        }

        func appendToken(_ token: String?, inPrimaryPlaylistSection: Bool) {
            guard let token, !token.isEmpty, seenTokens.insert(token).inserted else { return }
            if inPrimaryPlaylistSection {
                primaryContinuations.append(token)
            } else {
                secondaryContinuations.append(token)
            }
        }

        func walk(_ node: Any, depth: Int, inPlaylistSection: Bool, inRecommendations: Bool) {
            guard depth < 44 else { return }
            if let arr = node as? [Any] {
                for item in arr {
                    walk(item, depth: depth + 1, inPlaylistSection: inPlaylistSection, inRecommendations: inRecommendations)
                }
                return
            }
            guard let dict = node as? [String: Any] else { return }

            if !inRecommendations, let lockup = dict["lockupViewModel"] as? [String: Any] {
                if let track = extractLockupVideoTrack(from: lockup),
                   let vid = track.youtubeVideoID,
                   seenIDs.insert(vid).inserted {
                    tracks.append(track)
                }
                return
            }

            if let pv = dict["playlistVideoRenderer"] as? [String: Any],
               let vid = pv["videoId"] as? String,
               !vid.isEmpty,
               let rawTitle = ytText(pv["title"]),
               rawTitle != "[Deleted video]",
               rawTitle != "[Private video]",
               seenIDs.insert(vid).inserted {
                let rawArtist = (ytText(pv["shortBylineText"]) ?? ytText(pv["longBylineText"]) ?? "")
                    .replacingOccurrences(of: " - Topic", with: "")
                let duration = ytText(pv["lengthText"])
                tracks.append(
                    ExternalPlaylistTrack(
                        title: cleanTitle(rawTitle),
                        artist: rawArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                        youtubeVideoID: vid,
                        durationText: duration
                    )
                )
                return
            }

            if let ppv = dict["playlistPanelVideoRenderer"] as? [String: Any],
               let vid = ppv["videoId"] as? String,
               !vid.isEmpty,
               let rawTitle = ytText(ppv["title"]),
               rawTitle != "[Deleted video]",
               rawTitle != "[Private video]",
               seenIDs.insert(vid).inserted {
                let rawArtist = (ytText(ppv["shortBylineText"]) ?? ytText(ppv["longBylineText"]) ?? "")
                    .replacingOccurrences(of: " - Topic", with: "")
                let duration = ytText(ppv["lengthText"])
                tracks.append(
                    ExternalPlaylistTrack(
                        title: cleanTitle(rawTitle),
                        artist: rawArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                        youtubeVideoID: vid,
                        durationText: duration
                    )
                )
                return
            }

            if let mli = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                let playlistData = mli["playlistItemData"] as? [String: Any]
                let overlay = mli["overlay"] as? [String: Any]
                let overlayVid = ((overlay?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any]
                let navVid = ((overlayVid?["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
                    ?? ((mli["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
                    ?? (((mli["doubleTapCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String)
                if let vid = (playlistData?["videoId"] as? String) ?? navVid,
                   !vid.isEmpty,
                   let flexColumns = mli["flexColumns"] as? [[String: Any]],
                   !flexColumns.isEmpty,
                   seenIDs.insert(vid).inserted {
                    let col0 = (flexColumns[0]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]
                    let rawTitle = ytText(col0) ?? "Track"
                    var rawArtist = ""
                    if flexColumns.count > 1 {
                        let col1 = (flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]
                        rawArtist = ytArtistFromRuns(col1)
                    }
                    var duration: String?
                    if let fixedColumns = mli["fixedColumns"] as? [[String: Any]],
                       let fixed0 = (fixedColumns.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"] {
                        duration = ytText(fixed0)
                    }
                    tracks.append(
                        ExternalPlaylistTrack(
                            title: cleanTitle(rawTitle),
                            artist: rawArtist,
                            youtubeVideoID: vid,
                            durationText: duration
                        )
                    )
                    return
                }
            }

            if !inRecommendations,
               let mtri = dict["musicTwoRowItemRenderer"] as? [String: Any],
               let vid = ((mtri["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String,
               !vid.isEmpty,
               let rawTitle = ytText(mtri["title"]),
               seenIDs.insert(vid).inserted {
                let rawArtist = ytArtistFromRuns(mtri["subtitle"])
                tracks.append(
                    ExternalPlaylistTrack(
                        title: cleanTitle(rawTitle),
                        artist: rawArtist,
                        youtubeVideoID: vid,
                        durationText: nil
                    )
                )
                return
            }

            if inPlaylistSection && !inRecommendations {
                if let vr = (dict["gridVideoRenderer"] as? [String: Any])
                    ?? (dict["compactVideoRenderer"] as? [String: Any])
                    ?? (dict["videoRenderer"] as? [String: Any]),
                   let vid = vr["videoId"] as? String,
                   !vid.isEmpty,
                   let rawTitle = ytText(vr["title"]),
                   rawTitle != "[Deleted video]",
                   rawTitle != "[Private video]",
                   seenIDs.insert(vid).inserted {
                    let rawArtist = (ytText(vr["shortBylineText"]) ?? ytText(vr["longBylineText"]) ?? ytText(vr["ownerText"]) ?? "")
                        .replacingOccurrences(of: " - Topic", with: "")
                    let duration = ytText(vr["lengthText"])
                    tracks.append(
                        ExternalPlaylistTrack(
                            title: cleanTitle(rawTitle),
                            artist: rawArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                            youtubeVideoID: vid,
                            durationText: duration
                        )
                    )
                    return
                }
            }

            if let contVM = dict["continuationItemViewModel"] as? [String: Any],
               let contCmd = contVM["continuationCommand"] as? [String: Any],
               let ep = contCmd["innertubeCommand"] as? [String: Any] {
                appendToken(extractContinuationToken(fromEndpoint: ep), inPrimaryPlaylistSection: inPlaylistSection && !inRecommendations)
                return
            }

            if let contRenderer = dict["continuationItemRenderer"] as? [String: Any],
               let ep = contRenderer["continuationEndpoint"] as? [String: Any] {
                appendToken(extractContinuationToken(fromEndpoint: ep), inPrimaryPlaylistSection: inPlaylistSection && !inRecommendations)
                return
            }

            if let nextCont = dict["nextContinuationData"] as? [String: Any],
               let tok = nextCont["continuation"] as? String {
                appendToken(tok, inPrimaryPlaylistSection: inPlaylistSection && !inRecommendations)
            }

            for (key, val) in dict {
                if val is [String: Any] || val is [Any] {
                    let nextRecommendations = inRecommendations
                        || key == "secondaryResults"
                        || key == "watchNextSecondaryResultsRenderer"
                        || key == "relatedItems"
                        || key == "sidebar"
                        || key == "musicCarouselShelfRenderer"
                        || key == "horizontalCardListRenderer"
                    let enteringPrimary = !nextRecommendations && (
                        inPlaylistSection
                        || key == "itemSectionRenderer"
                        || key == "playlistVideoListRenderer"
                        || key == "playlistVideoListContinuation"
                        || key == "musicPlaylistShelfRenderer"
                        || key == "musicPlaylistShelfContinuation"
                        || key == "musicShelfContinuation"
                        || key == "sectionListContinuation"
                        || key == "appendContinuationItemsAction"
                        || key == "reloadContinuationItemsCommand"
                        || key == "playlist"
                    )
                    walk(val, depth: depth + 1, inPlaylistSection: enteringPrimary, inRecommendations: nextRecommendations)
                }
            }
        }

        walk(root, depth: 0, inPlaylistSection: false, inRecommendations: false)
        let selectedContinuations = primaryContinuations.isEmpty && tracks.isEmpty
            ? secondaryContinuations
            : primaryContinuations
        return (tracks, selectedContinuations)
    }

    // MARK: - Spotify Playlist (Public Embed JSON, no API token needed)

    private static func fetchSpotifyPlaylist(id: String, originalURL: URL?) async throws -> LoadedExternalPlaylist {
        var resolvedID = id

        if resolvedID == "__shortlink__", let originalURL {
            var req = URLRequest(url: originalURL)
            req.timeoutInterval = 15
            req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let finalURL = resp.url,
               let reparsed = parsePlaylistURL(finalURL.absoluteString),
               reparsed.platform == .spotify,
               reparsed.playlistID != "__shortlink__" {
                resolvedID = reparsed.playlistID
            } else {
                throw PlaylistImportError.fetchFailed("Could not resolve Spotify share shortlink.")
            }
        }

        if let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(resolvedID)"),
           let html = await fetchHTMLText(from: embedURL),
           let nextJSON = extractScriptJSON(in: html, idAttribute: "__NEXT_DATA__"),
           let parsed = parseSpotifyEmbedJSON(nextJSON, playlistID: resolvedID) {
            return parsed
        }

        if let webURL = URL(string: "https://open.spotify.com/playlist/\(resolvedID)"),
           let html = await fetchHTMLText(from: webURL) {
            let pageTitle = extractMetaContent(in: html, property: "og:title") ?? "Spotify Playlist"
            let metaTracks = extractSpotifyMetaTracks(in: html)
            if !metaTracks.isEmpty {
                return LoadedExternalPlaylist(
                    platform: .spotify,
                    sourceID: resolvedID,
                    title: cleanTitle(pageTitle),
                    tracks: metaTracks
                )
            }
        }

        throw PlaylistImportError.fetchFailed("Could not read Spotify playlist. Make sure the playlist is public (not private or empty).")
    }

    private static func parseSpotifyEmbedJSON(_ json: [String: Any], playlistID: String) -> LoadedExternalPlaylist? {
        guard let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let data = state["data"] as? [String: Any],
              let entity = data["entity"] as? [String: Any] else {
            return nil
        }

        let title = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify Playlist"
        guard let rawTracks = entity["trackList"] as? [[String: Any]], !rawTracks.isEmpty else {
            return nil
        }

        var tracks: [ExternalPlaylistTrack] = []
        for entry in rawTracks {
            guard let tTitle = entry["title"] as? String, !tTitle.isEmpty else { continue }
            let artist = (entry["subtitle"] as? String) ?? ""
            let durMs = (entry["duration"] as? NSNumber)?.intValue
            let durText = durMs.map { formatMilliseconds($0) }
            tracks.append(
                ExternalPlaylistTrack(
                    title: cleanTitle(tTitle),
                    artist: artist.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                    youtubeVideoID: nil,
                    durationText: durText
                )
            )
        }

        guard !tracks.isEmpty else { return nil }
        return LoadedExternalPlaylist(
            platform: .spotify,
            sourceID: playlistID,
            title: cleanTitle(title),
            tracks: tracks
        )
    }

    private static func extractSpotifyMetaTracks(in html: String) -> [ExternalPlaylistTrack] {
        // Fallback when Spotify serves lightweight HTML meta tags
        var tracks: [ExternalPlaylistTrack] = []
        let pattern = "<meta[^>]+(?:name|property)=[\"']music:song[\"'][^>]+content=[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let songURL = String(html[r])
            if let slug = URL(string: songURL)?.lastPathComponent, !slug.isEmpty {
                tracks.append(ExternalPlaylistTrack(title: slug, artist: "", youtubeVideoID: nil, durationText: nil))
            }
        }
        return tracks
    }

    // MARK: - Apple Music Playlist (Public Web Metadata, no MusicKit entitlement needed)

    private static func fetchAppleMusicPlaylist(url: URL, id: String) async throws -> LoadedExternalPlaylist {
        guard let html = await fetchHTMLText(from: url) else {
            throw PlaylistImportError.fetchFailed("Could not load Apple Music playlist page.")
        }

        var playlistTitle = extractMetaContent(in: html, property: "og:title")
            ?? extractMetaContent(in: html, name: "apple:title")
            ?? "Apple Music Playlist"
        playlistTitle = cleanAppleMusicPlaylistTitle(playlistTitle)

        var tracks: [ExternalPlaylistTrack] = []
        var seenKeys = Set<String>()

        if let serializedRoot = extractScriptAnyJSON(in: html, idAttribute: "serialized-server-data") {
            let found = extractAppleSerializedTracks(from: serializedRoot, seenKeys: &seenKeys)
            if let foundTitle = found.playlistTitle, !foundTitle.isEmpty {
                playlistTitle = cleanAppleMusicPlaylistTitle(foundTitle)
            }
            tracks.append(contentsOf: found.tracks)
        }

        if tracks.isEmpty {
            let ldBlocks = extractJSONLDBlocks(in: html)
            for block in ldBlocks {
                if let name = block["name"] as? String, !name.isEmpty {
                    playlistTitle = cleanAppleMusicPlaylistTitle(name)
                }
                if let rawTracks = block["track"] as? [[String: Any]] {
                    for entry in rawTracks {
                        guard let name = entry["name"] as? String, !name.isEmpty else { continue }
                        let artist = extractLDArtist(entry["byArtist"])
                        let key = "\(name.lowercased())|\(artist.lowercased())"
                        if seenKeys.insert(key).inserted {
                            tracks.append(
                                ExternalPlaylistTrack(
                                    title: cleanTitle(decodeHTMLEntities(name)),
                                    artist: decodeHTMLEntities(artist),
                                    youtubeVideoID: nil,
                                    durationText: nil
                                )
                            )
                        }
                    }
                }
            }
        }

        guard !tracks.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

        return LoadedExternalPlaylist(
            platform: .appleMusic,
            sourceID: id,
            title: playlistTitle,
            tracks: tracks
        )
    }

    private static func extractAppleSerializedTracks(
        from root: Any,
        seenKeys: inout Set<String>
    ) -> (playlistTitle: String?, tracks: [ExternalPlaylistTrack]) {
        var playlistTitle: String?
        var tracks: [ExternalPlaylistTrack] = []

        func walk(_ node: Any, depth: Int) {
            guard depth < 26 else { return }
            if let arr = node as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
                return
            }
            guard let dict = node as? [String: Any] else { return }

            if playlistTitle == nil,
               let seo = dict["seoData"] as? [String: Any],
               let ogTitle = seo["ogTitle"] as? String, !ogTitle.isEmpty {
                playlistTitle = ogTitle
            }

            // Apple Music web item shape: headerTitle/title + artistName / subtitleLinks
            let kind = (dict["kind"] as? String)?.lowercased() ?? (dict["type"] as? String)?.lowercased()
            let descriptor = (dict["contentDescriptor"] as? [String: Any])?["kind"] as? String
            if kind == "song" || kind == "songs" || kind == "music-video" || descriptor?.lowercased() == "song" {
                let rawTitle = (dict["title"] as? String)
                    ?? (dict["name"] as? String)
                    ?? ((dict["attributes"] as? [String: Any])?["name"] as? String)
                if let rawTitle, !rawTitle.isEmpty {
                    let rawArtist = (dict["artistName"] as? String)
                        ?? ((dict["attributes"] as? [String: Any])?["artistName"] as? String)
                        ?? ((dict["subtitleLinks"] as? [[String: Any]])?.compactMap { $0["title"] as? String }.joined(separator: ", "))
                        ?? ""
                    let cleanT = cleanTitle(rawTitle)
                    let cleanA = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = "\(cleanT.lowercased())|\(cleanA.lowercased())"
                    if seenKeys.insert(key).inserted {
                        let durMs = (dict["duration"] as? NSNumber)?.intValue
                            ?? ((dict["attributes"] as? [String: Any])?["durationInMillis"] as? NSNumber)?.intValue
                        tracks.append(
                            ExternalPlaylistTrack(
                                title: cleanT,
                                artist: cleanA,
                                youtubeVideoID: nil,
                                durationText: durMs.map { formatMilliseconds($0) }
                            )
                        )
                        return
                    }
                }
            }

            for (_, val) in dict {
                if val is [String: Any] || val is [Any] {
                    walk(val, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        return (playlistTitle, tracks)
    }

    // MARK: - YouTube InnerTube Track Search (Zero API Key)

    static func findBestYouTubeVideoID(title: String, artist: String) async -> String? {
        guard let searchURL = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            return nil
        }

        let cleanedT = cleanSearchTerm(title)
        let cleanedA = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryString = cleanedA.isEmpty ? cleanedT : "\(cleanedT) \(cleanedA) audio"

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": webClientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "query": queryString
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: searchURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(webClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var candidates: [(videoID: String, score: Int)] = []
        let targetTitleTokens = Set(cleanedT.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let targetArtistTokens = Set(cleanedA.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))

        func walkSearch(_ node: Any, depth: Int) {
            guard depth < 22, candidates.count < 16 else { return }
            if let arr = node as? [Any] {
                for item in arr { walkSearch(item, depth: depth + 1) }
                return
            }
            guard let dict = node as? [String: Any] else { return }

            if let vr = dict["videoRenderer"] as? [String: Any],
               let vid = vr["videoId"] as? String,
               !vid.isEmpty {
                let vTitle = (ytText(vr["title"]) ?? "").lowercased()
                let owner = (ytText(vr["ownerText"]) ?? ytText(vr["longBylineText"]) ?? "").lowercased()
                let durStr = ytText(vr["lengthText"]) ?? ""
                let seconds = parseDurationSeconds(durStr)

                var score = 0
                if owner.contains("topic") { score += 4 }
                if vTitle.contains("official audio") || vTitle.contains("audio") { score += 3 }
                if vTitle.contains("lyrics") { score += 1 }
                if vTitle.contains("#shorts") { score -= 4 }
                if let seconds, seconds > 1100 { score -= 5 } // Avoid hour-long compilations for single songs
                for tok in targetTitleTokens where tok.count >= 2 && vTitle.contains(tok) {
                    score += 3
                }
                for tok in targetArtistTokens where tok.count >= 2 && (owner.contains(tok) || vTitle.contains(tok)) {
                    score += 2
                }
                candidates.append((vid, score))
                return
            }

            for (_, val) in dict {
                if val is [String: Any] || val is [Any] {
                    walkSearch(val, depth: depth + 1)
                }
            }
        }

        walkSearch(root, depth: 0)
        return candidates.max(by: { $0.score < $1.score })?.videoID
    }

    static func searchYouTubeTracks(
        query: String,
        limit: Int = 12
    ) async -> [(videoID: String, title: String, artist: String, durationSeconds: Double?)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let searchURL = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            return []
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": webClientVersion,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "query": trimmed
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var req = URLRequest(url: searchURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(webClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [(videoID: String, title: String, artist: String, durationSeconds: Double?)] = []
        var seen = Set<String>()

        func walk(_ node: Any, depth: Int) {
            guard depth < 22, results.count < limit else { return }
            if let arr = node as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
                return
            }
            guard let dict = node as? [String: Any] else { return }
            if let vr = dict["videoRenderer"] as? [String: Any],
               let vid = vr["videoId"] as? String,
               !vid.isEmpty,
               let rawTitle = ytText(vr["title"]),
               seen.insert(vid).inserted {
                let owner = (ytText(vr["ownerText"]) ?? ytText(vr["longBylineText"]) ?? "")
                    .replacingOccurrences(of: " - Topic", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let durSec = parseDurationSeconds(ytText(vr["lengthText"]) ?? "").map { Double($0) }
                results.append((vid, cleanTitle(rawTitle), owner, durSec))
                return
            }
            for (_, val) in dict {
                if val is [String: Any] || val is [Any] {
                    walk(val, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        return results
    }

    // MARK: - Helpers

    private static func fetchHTMLText(from url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 18
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func ytText(_ obj: Any?) -> String? {
        if let str = obj as? String { return str }
        guard let dict = obj as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func ytArtistFromRuns(_ obj: Any?) -> String {
        guard let dict = obj as? [String: Any],
              let runs = dict["runs"] as? [[String: Any]] else {
            return ytText(obj) ?? ""
        }
        let firstPart = runs.first?["text"] as? String ?? ""
        return firstPart.replacingOccurrences(of: " - Topic", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractScriptJSON(in html: String, idAttribute: String) -> [String: Any]? {
        extractScriptAnyJSON(in: html, idAttribute: idAttribute) as? [String: Any]
    }

    private static func extractScriptAnyJSON(in html: String, idAttribute: String) -> Any? {
        let patterns = [
            "id=\"\(idAttribute)\"[^>]*>([\\s\\S]*?)</script>",
            "id='\(idAttribute)'[^>]*>([\\s\\S]*?)</script>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let data = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            return json
        }
        return nil
    }

    private static func extractJSONLDBlocks(in html: String) -> [[String: Any]] {
        let pattern = "<script[^>]+type=[\"']application/ld\\+json[\"'][^>]*>([\\s\\S]*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var blocks: [[String: Any]] = []
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches {
            guard let r = Range(m.range(at: 1), in: html),
                  let data = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            if let dict = obj as? [String: Any] {
                blocks.append(dict)
            } else if let arr = obj as? [[String: Any]] {
                blocks.append(contentsOf: arr)
            }
        }
        return blocks
    }

    private static func extractLDArtist(_ raw: Any?) -> String {
        if let dict = raw as? [String: Any], let name = dict["name"] as? String {
            return name
        }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { $0["name"] as? String }.joined(separator: ", ")
        }
        return ""
    }

    private static func extractMetaContent(in html: String, property: String? = nil, name: String? = nil) -> String? {
        let keyAttr = property != nil ? "property" : "name"
        let keyVal = NSRegularExpression.escapedPattern(for: property ?? name ?? "")
        let patterns = [
            "<meta[^>]+\\b\(keyAttr)=[\"']\(keyVal)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+\\b\(keyAttr)=[\"']\(keyVal)[\"']"
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else {
                continue
            }
            let val = decodeHTMLEntities(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { return val }
        }
        return nil
    }

    private static func cleanAppleMusicPlaylistTitle(_ raw: String) -> String {
        var title = cleanTitle(raw)
        for suffix in [" - Apple Music", " on Apple Music", " — Apple Music"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count))
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(_ raw: String) -> String {
        var cleaned = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube Music", " - YouTube", " | Spotify"] {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSearchTerm(_ title: String) -> String {
        let patterns = [
            #"\s*\(Official[^)]*\)"#,
            #"\s*\[Official[^\]]*\]"#,
            #"\s*\(Lyrics[^)]*\)"#,
            #"\s*\[Lyrics[^\]]*\]"#,
            #"\s*\(Music Video\)"#,
            #"\s*\(feat\.[^)]*\)"#,
            #"\s*\[feat\.[^\]]*\]"#
        ]
        var cleaned = title
        for p in patterns {
            cleaned = cleaned.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func formatMilliseconds(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func parseDurationSeconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
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
}
