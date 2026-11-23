import SwiftUI
import WebKit

struct GeniusLyricsTarget: Identifiable, Equatable {
    let id = UUID()
    let rawTitle: String
    let rawArtist: String
}

private struct GeniusSongMatch: Identifiable, Hashable {
    let id: Int
    let title: String
    let artistNames: String
    let url: URL
    let score: Int
}

private enum GeniusLyricsResolver {
    static func cleanSongAndArtist(rawTitle: String, rawArtist: String) -> (song: String, artist: String) {
        var song = stripNoisySuffixes(rawTitle)
        var artist = stripArtistJunk(rawArtist)

        // If artist wasn't embedded in ID3 tags (common for downloaded YouTube tracks),
        // split "Artist - Song Title" patterns cleanly.
        for separator in [" - ", " — ", " – ", " | "] {
            if let range = song.range(of: separator) {
                let left = String(song[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(song[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    if artist.isEmpty {
                        artist = stripArtistJunk(left)
                        song = stripNoisySuffixes(right)
                        break
                    } else if left.localizedCaseInsensitiveCompare(artist) == .orderedSame ||
                                artist.localizedCaseInsensitiveContains(left) ||
                                left.localizedCaseInsensitiveContains(artist) {
                        song = stripNoisySuffixes(right)
                        break
                    }
                }
            }
        }

        // Remove featured credits only for search cleaner match while keeping main song title
        song = stripFeaturedClause(song)
        return (song: song.isEmpty ? rawTitle : song, artist: artist)
    }

    static func searchURL(song: String, artist: String) -> URL {
        let query = [artist, song]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://genius.com/search?q=\(encoded)")!
    }

    static func findMatches(rawTitle: String, rawArtist: String, song: String, artist: String) async -> [GeniusSongMatch] {
        let queryParts = [song, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !queryParts.isEmpty else { return [] }

        let query = queryParts.joined(separator: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "https://genius.com/api/search/multi?q=\(encoded)&per_page=5") else {
            return []
        }

        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 12
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let sections = response["sections"] as? [[String: Any]] else {
            return []
        }

        var matchesByID: [Int: GeniusSongMatch] = [:]
        let rawLower = rawTitle.lowercased()

        for section in sections {
            let sectionType = (section["type"] as? String) ?? ""
            guard sectionType == "song" || sectionType == "top_hit",
                  let hits = section["hits"] as? [[String: Any]] else {
                continue
            }

            for hit in hits {
                guard let hitType = hit["type"] as? String, hitType == "song",
                      let result = hit["result"] as? [String: Any],
                      let songID = result["id"] as? Int,
                      let title = result["title"] as? String,
                      let urlStr = result["url"] as? String,
                      let url = URL(string: urlStr) else {
                    continue
                }

                let primaryArtist = (result["primary_artist"] as? [String: Any])?["name"] as? String ?? ""
                let artistNames = (result["artist_names"] as? String) ?? primaryArtist
                let lyricsState = (result["lyrics_state"] as? String)?.lowercased() ?? ""

                let score = scoreMatch(
                    candidateTitle: title,
                    candidateArtists: artistNames,
                    candidatePrimaryArtist: primaryArtist,
                    targetSong: song,
                    targetArtist: artist,
                    rawTitleLower: rawLower,
                    lyricsComplete: lyricsState == "complete"
                )

                if matchesByID[songID] == nil || (matchesByID[songID]?.score ?? Int.min) < score {
                    matchesByID[songID] = GeniusSongMatch(
                        id: songID,
                        title: title,
                        artistNames: artistNames,
                        url: url,
                        score: score
                    )
                }
            }
        }

        return matchesByID.values.sorted { $0.score > $1.score }
    }

    private static func scoreMatch(
        candidateTitle: String,
        candidateArtists: String,
        candidatePrimaryArtist: String,
        targetSong: String,
        targetArtist: String,
        rawTitleLower: String,
        lyricsComplete: Bool
    ) -> Int {
        var score = lyricsComplete ? 5 : 0

        let normCandTitle = normalizedComparable(candidateTitle)
        let normTargetSong = normalizedComparable(targetSong)
        let candTitleTokens = wordTokens(normCandTitle)
        let targetTitleTokens = wordTokens(normTargetSong)

        if !normTargetSong.isEmpty {
            if normCandTitle == normTargetSong {
                score += 45
            } else if normCandTitle.contains(normTargetSong) || normTargetSong.contains(normCandTitle) {
                score += 24
            }
            if !targetTitleTokens.isEmpty && targetTitleTokens.isSubset(of: candTitleTokens) {
                score += 20
            }
            for tok in targetTitleTokens where candTitleTokens.contains(tok) {
                score += 4
            }
        }

        let normCandArtist = normalizedComparable(candidateArtists)
        let normCandPrimary = normalizedComparable(candidatePrimaryArtist)
        let normTargetArtist = normalizedComparable(targetArtist)
        let candArtistTokens = wordTokens(normCandArtist)
        let targetArtistTokens = wordTokens(normTargetArtist)

        if !normTargetArtist.isEmpty {
            if normCandPrimary == normTargetArtist || normCandArtist == normTargetArtist {
                score += 50
            } else if normCandArtist.contains(normTargetArtist) || normTargetArtist.contains(normCandPrimary) {
                score += 32
            } else {
                let overlap = targetArtistTokens.intersection(candArtistTokens)
                if !overlap.isEmpty {
                    score += overlap.count * 14
                } else {
                    score -= 30
                }
            }
        }

        // Penalize mismatched editions (live, remix, sped up, slowed, karaoke) unless requested
        let editionWords = ["remix", "live", "sped up", "slowed", "instrumental", "karaoke", "cover", "acoustic", "traduction", "translation"]
        let candLower = candidateTitle.lowercased()
        for word in editionWords {
            if candLower.contains(word) && !rawTitleLower.contains(word) {
                score -= 14
            }
        }

        return score
    }

    private static func normalizedComparable(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordTokens(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    private static func stripNoisySuffixes(_ text: String) -> String {
        let patterns = [
            #"\s*[\(\[]\s*(official|lyrics?|lyric video|audio|music video|mv|visualizer|hd|4k|explicit|clean|version)[^\)\]]*[\)\]]"#,
            #"\s*-\s*(official\s*(video|audio|music video)|lyrics?)\s*$"#
        ]
        var cleaned = text.replacingOccurrences(of: "_", with: " ")
        for p in patterns {
            cleaned = cleaned.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFeaturedClause(_ text: String) -> String {
        let patterns = [
            #"\s*[\(\[]\s*(feat|ft|featuring)\.?\s+[^\)\]]*[\)\]]"#,
            #"\s+(feat|ft|featuring)\.?\s+.+$"#
        ]
        var cleaned = text
        for p in patterns {
            cleaned = cleaned.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripArtistJunk(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: " - Topic", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "VEVO", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let commaIdx = cleaned.firstIndex(of: ","), !cleaned[..<commaIdx].isEmpty {
            cleaned = String(cleaned[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

struct GeniusLyricsSheetView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let target: GeniusLyricsTarget

    @State private var songQuery = ""
    @State private var artistQuery = ""
    @State private var currentURL: URL?
    @State private var matches: [GeniusSongMatch] = []
    @State private var selectedMatchID: Int?
    @State private var isResolving = true
    @State private var isLoadingPage = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showSearchEditor = false
    @State private var webViewRef: WKWebView?
    @State private var contentBlocker = ContentBlockerManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showSearchEditor {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Song title", text: $songQuery)
                                .textFieldStyle(.roundedBorder)
                            TextField("Artist", text: $artistQuery)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button("Search Genius") {
                                showSearchEditor = false
                                Task {
                                    await resolveAndLoad(
                                        rawTitle: songQuery,
                                        rawArtist: artistQuery,
                                        cleanedSong: songQuery,
                                        cleanedArtist: artistQuery
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Open Web Search Page") {
                                showSearchEditor = false
                                selectedMatchID = nil
                                currentURL = GeniusLyricsResolver.searchURL(song: songQuery, artist: artistQuery)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                }

                if matches.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(matches.prefix(5)) { match in
                                let isSelected = selectedMatchID == match.id
                                Button {
                                    selectedMatchID = match.id
                                    currentURL = match.url
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(match.title)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(match.artistNames)
                                            .font(.caption2)
                                            .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .foregroundStyle(isSelected ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .background(.ultraThinMaterial)
                }

                Divider()

                ZStack {
                    if let currentURL {
                        LyricsWebView(
                            url: currentURL,
                            adBlockEnabled: settings.adBlockEnabled,
                            darkModeEnabled: settings.webDarkModeEnabled,
                            contentBlocker: contentBlocker,
                            webViewRef: $webViewRef,
                            isLoading: $isLoadingPage,
                            canGoBack: $canGoBack,
                            canGoForward: $canGoForward
                        )
                    }

                    if isResolving || isLoadingPage {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(isResolving ? "Matching song & artist on Genius..." : "Loading Genius lyrics...")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .navigationTitle(matchedHeaderTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Button("Done") { dismiss() }
                        if canGoBack {
                            Button {
                                webViewRef?.goBack()
                            } label: {
                                Image(systemName: "chevron.backward")
                            }
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearchEditor.toggle()
                        }
                    } label: {
                        Image(systemName: showSearchEditor ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    }

                    Button {
                        webViewRef?.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    if let currentURL {
                        ShareLink(item: currentURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task {
                let parsed = GeniusLyricsResolver.cleanSongAndArtist(
                    rawTitle: target.rawTitle,
                    rawArtist: target.rawArtist
                )
                songQuery = parsed.song
                artistQuery = parsed.artist
                await resolveAndLoad(
                    rawTitle: target.rawTitle,
                    rawArtist: target.rawArtist,
                    cleanedSong: parsed.song,
                    cleanedArtist: parsed.artist
                )
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var matchedHeaderTitle: String {
        if let selected = matches.first(where: { $0.id == selectedMatchID }) {
            return "\(selected.title) — \(selected.artistNames)"
        }
        if !artistQuery.isEmpty && !songQuery.isEmpty {
            return "\(songQuery) — \(artistQuery)"
        }
        return songQuery.isEmpty ? "Genius Lyrics" : songQuery
    }

    private func resolveAndLoad(
        rawTitle: String,
        rawArtist: String,
        cleanedSong: String,
        cleanedArtist: String
    ) async {
        isResolving = true
        let found = await GeniusLyricsResolver.findMatches(
            rawTitle: rawTitle,
            rawArtist: rawArtist,
            song: cleanedSong,
            artist: cleanedArtist
        )
        matches = found
        if let best = found.first, best.score >= 12 {
            selectedMatchID = best.id
            currentURL = best.url
        } else {
            selectedMatchID = nil
            currentURL = GeniusLyricsResolver.searchURL(song: cleanedSong, artist: cleanedArtist)
        }
        isResolving = false
    }
}

private struct LyricsWebView: UIViewRepresentable {
    let url: URL
    let adBlockEnabled: Bool
    let darkModeEnabled: Bool
    let contentBlocker: ContentBlockerManager
    @Binding var webViewRef: WKWebView?
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    private static let geniusCleanupJS = """
    (function() {
        if (window.__mpGeniusCleanupInstalled) return;
        window.__mpGeniusCleanupInstalled = true;
        var st = document.createElement('style');
        st.textContent = '[class*="Ad__"], [class*="Primis"], [class*="dfp"], [id*="div-gpt-ad"], [class*="BannerSticky"], [class*="StickyBanner"], [class*="SignupPrompt"], [class*="AppleMusic"], .ad_unit { display: none !important; opacity: 0 !important; height: 0 !important; pointer-events: none !important; }';
        (document.head || document.documentElement).appendChild(st);
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        if adBlockEnabled {
            userController.addUserScript(
                WKUserScript(
                    source: ContentBlockerManager.cosmeticAdBlockScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
            userController.addUserScript(
                WKUserScript(
                    source: Self.geniusCleanupJS,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = WebMediaDownloader.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastLoadedURL = url
        context.coordinator.observe(webView)

        if adBlockEnabled {
            contentBlocker.isBlockingEnabled = true
            if let cached = contentBlocker.cachedRuleList {
                userController.add(cached)
            } else {
                Task { @MainActor in
                    await contentBlocker.applyRules(to: webView.configuration)
                }
            }
        }

        DispatchQueue.main.async {
            webViewRef = webView
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LyricsWebView
        var lastLoadedURL: URL?
        private var observations: [NSKeyValueObservation] = []

        init(parent: LyricsWebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                    let val = view.isLoading
                    DispatchQueue.main.async { self?.parent.isLoading = val }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                    let val = view.canGoBack
                    DispatchQueue.main.async { self?.parent.canGoBack = val }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                    let val = view.canGoForward
                    DispatchQueue.main.async { self?.parent.canGoForward = val }
                }
            ]
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if parent.darkModeEnabled {
                webView.evaluateJavaScript(
                    "(function(){if(!document.getElementById('__mp_lyrics_dark')){var s=document.createElement('style');s.id='__mp_lyrics_dark';s.textContent='html{filter:invert(90%) hue-rotate(180deg);background:#111!important;}img,video{filter:invert(100%) hue-rotate(180deg);}';(document.head||document.documentElement).appendChild(s);}})();"
                )
            }
        }
    }
}
