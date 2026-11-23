import Foundation

enum ExternalPlaylistPlatform: String, Identifiable {
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

struct ExternalPlaylistTrack: Identifiable {
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
    private static let webClientVersion = "2.20250220.01.00"
    private static let remixClientVersion = "1.20250220.01.00"

    static func parsePlaylistURL(_ rawString: String) -> ParsedExternalPlaylistURL? {
        var trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let listID = comps.queryItems?.first(where: { $0.name == "list" })?.value,
               !listID.isEmpty {
                return ParsedExternalPlaylistURL(platform: .youtubeMusic, playlistID: listID, originalURL: url)
            }
        }

        return nil
    }

    static func fetchPlaylist(from rawString: String) async throws -> LoadedExternalPlaylist {
        guard let parsed = parsePlaylistURL(rawString) else {
            throw PlaylistImportError.invalidURL
        }

        switch parsed.platform {
        case .youtubeMusic:
            return try await fetchYouTubePlaylist(listID: parsed.playlistID)
        case .spotify:
            return try await fetchSpotifyPlaylist(id: parsed.playlistID, originalURL: parsed.originalURL)
        case .appleMusic:
            guard let url = parsed.originalURL else { throw PlaylistImportError.invalidURL }
            return try await fetchAppleMusicPlaylist(url: url, id: parsed.playlistID)
        }
    }

    // MARK: - YouTube & YouTube Music Playlist (InnerTube + HTML fallback, no API key)

    private static func fetchYouTubePlaylist(listID: String) async throws -> LoadedExternalPlaylist {
        let browseID = listID.hasPrefix("VL") ? listID : "VL\(listID)"
        var playlistTitle = "YouTube Playlist"
        var tracks: [ExternalPlaylistTrack] = []
        var seenVideoIDs = Set<String>()

        if let initialJSON = await fetchYouTubeBrowse(
            browseID: browseID,
            continuation: nil,
            useMusicRemix: listID.hasPrefix("OLAK") || listID.hasPrefix("RDCLAK")
        ) ?? (await fetchYouTubePlaylistHTMLInitialData(listID: listID)) {
            if let parsedTitle = extractYouTubePlaylistTitle(from: initialJSON), !parsedTitle.isEmpty {
                playlistTitle = parsedTitle
            }
            let firstPage = extractYouTubePlaylistItems(from: initialJSON, seenIDs: &seenVideoIDs)
            tracks.append(contentsOf: firstPage.tracks)

            var continuation = firstPage.continuation
            var pageCount = 1
            while let token = continuation, !token.isEmpty, pageCount < 5, tracks.count < 400 {
                pageCount += 1
                guard let nextJSON = await fetchYouTubeBrowse(
                    browseID: nil,
                    continuation: token,
                    useMusicRemix: listID.hasPrefix("OLAK") || listID.hasPrefix("RDCLAK")
                ) else {
                    break
                }
                let nextPage = extractYouTubePlaylistItems(from: nextJSON, seenIDs: &seenVideoIDs)
                if nextPage.tracks.isEmpty { break }
                tracks.append(contentsOf: nextPage.tracks)
                continuation = nextPage.continuation
            }
        }

        if tracks.isEmpty,
           let standardJSON = await fetchYouTubeBrowse(browseID: browseID, continuation: nil, useMusicRemix: false) {
            if let parsedTitle = extractYouTubePlaylistTitle(from: standardJSON), !parsedTitle.isEmpty {
                playlistTitle = parsedTitle
            }
            let page = extractYouTubePlaylistItems(from: standardJSON, seenIDs: &seenVideoIDs)
            tracks.append(contentsOf: page.tracks)
        }

        guard !tracks.isEmpty else {
            throw PlaylistImportError.emptyPlaylist
        }

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
        useMusicRemix: Bool
    ) async -> [String: Any]? {
        guard let apiURL = URL(string: useMusicRemix
            ? "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false"
            : "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false") else {
            return nil
        }

        let origin = useMusicRemix ? "https://music.youtube.com" : "https://www.youtube.com"
        let clientName = useMusicRemix ? "WEB_REMIX" : "WEB"
        let clientVersion = useMusicRemix ? remixClientVersion : webClientVersion
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
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        req.setValue(clientHeaderID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func fetchYouTubePlaylistHTMLInitialData(listID: String) async -> [String: Any]? {
        guard let encoded = listID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/playlist?list=\(encoded)") else {
            return nil
        }
        guard let html = await fetchHTMLText(from: url) else { return nil }
        for marker in ["var ytInitialData = ", "ytInitialData = "] {
            if let range = html.range(of: marker),
               let jsonStart = html[range.upperBound...].firstIndex(of: "{"),
               let slice = balancedJSONObject(in: html, startingAt: jsonStart),
               let data = slice.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    private static func extractYouTubePlaylistTitle(from json: [String: Any]) -> String? {
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
               let t = ytText(pg["pageTitle"]) {
                return cleanTitle(t)
            }
        }
        return nil
    }

    private static func extractYouTubePlaylistItems(
        from root: Any,
        seenIDs: inout Set<String>
    ) -> (tracks: [ExternalPlaylistTrack], continuation: String?) {
        var tracks: [ExternalPlaylistTrack] = []
        var continuationToken: String?

        func walk(_ node: Any, depth: Int) {
            guard depth < 24 else { return }
            if let arr = node as? [Any] {
                for item in arr {
                    walk(item, depth: depth + 1)
                }
                return
            }
            guard let dict = node as? [String: Any] else { return }

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

            if let mli = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                let playlistData = mli["playlistItemData"] as? [String: Any]
                let overlay = mli["overlay"] as? [String: Any]
                let overlayVid = ((overlay?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any]
                let navVid = ((overlayVid?["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
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
            }

            if continuationToken == nil,
               let contRenderer = dict["continuationItemRenderer"] as? [String: Any],
               let ep = contRenderer["continuationEndpoint"] as? [String: Any],
               let cmd = ep["continuationCommand"] as? [String: Any],
               let token = cmd["token"] as? String,
               !token.isEmpty {
                continuationToken = token
                return
            }

            for (_, val) in dict {
                if val is [String: Any] || val is [Any] {
                    walk(val, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        return (tracks, continuationToken)
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
