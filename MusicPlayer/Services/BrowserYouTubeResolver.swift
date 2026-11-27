import Foundation
import UIKit
import WebKit

/// Built-in WKWebView-backed YouTube finder & player resolver.
/// Shares `.default()` cookies with `BrowserTabView` so playlists and videos resolve inside
/// the user's real browser session when unauthenticated InnerTube requests fail or return bots/403,
/// and supports locating exact track videos inside the built-in browser.
@MainActor
final class BrowserYouTubeResolver: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = BrowserYouTubeResolver()

    @MainActor
    private final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    private var webView: WKWebView?
    private weak var hostContainerView: UIView?
    private var isBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    private var activeVideoID: String?
    private var activeWatchURL: URL?
    private var activeResolveContinuation: CheckedContinuation<YouTubeResolvedResult?, Never>?
    private var activeTimeoutTask: Task<Void, Never>?
    private var fallbackStreamURLs: [DetectedBrowserMedia] = []

    private var activePageFinishContinuation: CheckedContinuation<Void, Never>?
    private var activePageFinishToken: UUID?

    private override init() {
        super.init()
    }

    private static var cachedCookieState: (value: String?, fetchedAt: Date)?

    static func cachedYouTubeCookieHeader() -> String? {
        cachedCookieState?.value
    }

    /// Reads current YouTube & Google session cookies from the shared built-in browser data store,
    /// caching in memory for 60s and bounding WebKit IPC wait so interactive taps never hang.
    static func youtubeCookieHeader(forceRefresh: Bool = false, timeoutSeconds: Double = 1.0) async -> String? {
        if !forceRefresh,
           let cached = cachedCookieState,
           Date().timeIntervalSince(cached.fetchedAt) < 60 {
            return cached.value
        }
        let fallback = cachedCookieState?.value
        let gate = ResumeOnceGate()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                let now = Date()
                let pairs = cookies.compactMap { cookie -> String? in
                    let domain = cookie.domain.lowercased()
                    let matchesYouTube = domain.hasSuffix("youtube.com")
                        || domain.hasSuffix("youtu.be")
                        || domain.hasSuffix("google.com")
                        || domain == "youtube.com"
                    guard matchesYouTube else { return nil }
                    if let exp = cookie.expiresDate, exp <= now { return nil }
                    return "\(cookie.name)=\(cookie.value)"
                }
                let header = pairs.isEmpty ? nil : pairs.joined(separator: "; ")
                cachedCookieState = (header, now)
                if gate.claim() {
                    continuation.resume(returning: header)
                }
            }
            Task { @MainActor in
                let ns = UInt64(max(0.2, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if gate.claim() {
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    /// Releases the internal offscreen WKWebView once a batch queue finishes to reclaim memory.
    func releaseIdleWebView() {
        guard !isBusy else { return }
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        hostContainerView = nil
    }

    /// Cancels any currently running browser resolve/page load so Stop -> Retry starts immediately.
    func cancelPendingOperations() {
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        resumePageFinishIfPending()
        resumeActiveResolve(with: nil)
        webView?.stopLoading()
    }

    /// Finds an exact YouTube video ID inside the built-in browser search page when InnerTube search fails.
    func findVideoIDInBrowser(title: String, artist: String) async -> String? {
        let query = [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://m.youtube.com/results?search_query=\(encoded)") else {
            return nil
        }

        guard await acquireLock(timeoutSeconds: 15.0) else { return nil }
        defer { releaseLock() }

        guard let wv = ensureWebView() else { return nil }
        await loadAndWait(url: searchURL, in: wv, timeoutSeconds: 8)
        try? await Task.sleep(nanoseconds: 700_000_000)

        let js = """
        (function() {
            var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/watch?v="]'));
            for (var i = 0; i < links.length; i++) {
                var href = links[i].getAttribute('href') || '';
                var m = href.match(/[?&]v=([A-Za-z0-9_-]{11})/);
                if (m && m[1]) return m[1];
            }
            return '';
        })();
        """
        if let raw = await evaluateJS(js, in: wv), !raw.isEmpty {
            return raw
        }
        return nil
    }

    /// Resolves playable streams for a YouTube video inside the built-in browser WKWebView,
    /// capturing `ytInitialPlayerResponse`, `/youtubei/v1/player`, and `#movie_player.getPlayerResponse()`.
    func resolveStreamsInBrowser(
        videoID: String,
        priorityLockTimeout: Double = 3.0
    ) async -> (result: YouTubeResolvedResult, cookiesHeader: String?)? {
        let cleanID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty,
              let watchURL = URL(string: "https://m.youtube.com/watch?v=\(cleanID)") else {
            return nil
        }

        guard await acquireLock(timeoutSeconds: priorityLockTimeout) else { return nil }
        defer { releaseLock() }

        guard let wv = ensureWebView() else { return nil }
        let cookiesHeader = await Self.youtubeCookieHeader(timeoutSeconds: 0.8)

        activeVideoID = cleanID
        activeWatchURL = watchURL
        fallbackStreamURLs = []

        let result: YouTubeResolvedResult? = await withCheckedContinuation { continuation in
            self.activeResolveContinuation = continuation
            let isBackground = UIApplication.shared.applicationState == .background
            let maxWaitMs = isBackground ? 5_500 : 8_000
            let stepMs = 250
            let steps = max(1, maxWaitMs / stepMs)

            let deadline = Date().addingTimeInterval(Double(maxWaitMs) / 1000)
            self.activeTimeoutTask = Task { [weak self] in
                for _ in 0..<steps {
                    try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    if self?.activeResolveContinuation == nil { return }
                    // Hard wall-clock deadline: slow/unanswered DOM polls must not stretch the wait.
                    if Date() >= deadline { break }
                    await self?.pollPlayerResponseFromDOM()
                    if self?.activeResolveContinuation == nil { return }
                }
                guard !Task.isCancelled else { return }
                await self?.finishActiveResolveWithFallback()
            }

            // Outer failsafe if evaluateJS in pollPlayerResponseFromDOM stalls past the deadline.
            Task { @MainActor [weak self] in
                let failsafeNs = UInt64(maxWaitMs + 1_500) * 1_000_000
                try? await Task.sleep(nanoseconds: failsafeNs)
                guard let self, self.activeResolveContinuation != nil else { return }
                self.resumeActiveResolve(with: nil)
            }

            wv.load(URLRequest(url: watchURL))
        }

        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        activeVideoID = nil
        activeWatchURL = nil
        fallbackStreamURLs = []

        // Blank out the heavy YouTube watch DOM immediately so multi-thousand track queues don't retain SPA memory.
        wv.stopLoading()
        wv.loadHTMLString("", baseURL: nil)

        guard let result, !result.streams.isEmpty else { return nil }
        let updatedCookies = await Self.youtubeCookieHeader(forceRefresh: true, timeoutSeconds: 0.6) ?? cookiesHeader
        let patchedStreams = result.streams.map { stream -> DetectedBrowserMedia in
            var mergedHeaders = stream.customHeaders ?? [:]
            if let updatedCookies, !updatedCookies.isEmpty, mergedHeaders["Cookie"] == nil {
                mergedHeaders["Cookie"] = updatedCookies
            }
            if mergedHeaders["User-Agent"] == nil {
                mergedHeaders["User-Agent"] = WebMediaDownloader.browserUserAgent
            }
            if mergedHeaders["Referer"] == nil {
                mergedHeaders["Referer"] = watchURL.absoluteString
            }
            return DetectedBrowserMedia(
                url: stream.url,
                pairedAudioURL: stream.pairedAudioURL,
                isHLS: stream.isHLS,
                isAudio: stream.isAudio,
                title: stream.title,
                author: stream.author,
                qualityLabel: stream.qualityLabel,
                referer: stream.referer ?? watchURL.absoluteString,
                customHeaders: mergedHeaders,
                durationSeconds: stream.durationSeconds,
                isActivelyPlaying: false
            )
        }
        let patched = YouTubeResolvedResult(
            videoID: result.videoID,
            title: result.title,
            author: result.author,
            durationSeconds: result.durationSeconds,
            streams: patchedStreams,
            errorReason: result.errorReason
        )
        return (patched, updatedCookies)
    }

    /// Loads a YouTube playlist URL in the built-in browser and extracts `window.ytInitialData`
    /// (supports private / Watch Later / Liked Music / age-restricted playlists when logged into the browser).
    func extractPlaylistInitialDataInBrowser(url: URL) async -> (json: [String: Any], cookiesHeader: String?)? {
        guard await acquireLock(timeoutSeconds: 15.0) else { return nil }
        defer { releaseLock() }

        guard let wv = ensureWebView() else { return nil }
        await loadAndWait(url: url, in: wv, timeoutSeconds: 12)

        let pollJS = """
        (function() {
            try {
                var docTitle = (document.title || '')
                    .replace(/\\s*-\\s*YouTube Music\\s*$/i, '')
                    .replace(/\\s*-\\s*YouTube\\s*$/i, '')
                    .trim();

                var data = (window.ytInitialData && typeof window.ytInitialData === 'object')
                    ? window.ytInitialData : null;
                if (data) {
                    var serialized = JSON.stringify(data);
                    if (serialized.indexOf('playlistVideoRenderer') !== -1 ||
                        serialized.indexOf('playlistPanelVideoRenderer') !== -1 ||
                        serialized.indexOf('musicResponsiveListItemRenderer') !== -1 ||
                        serialized.indexOf('lockupViewModel') !== -1) {
                        return serialized;
                    }
                }

                var items = [];
                var seen = {};
                var selectors = [
                    'ytm-playlist-video-renderer',
                    'ytd-playlist-video-renderer',
                    'ytm-compact-video-renderer',
                    'ytmusic-responsive-list-item-renderer',
                    'yt-lockup-view-model'
                ];
                var nodes = document.querySelectorAll(selectors.join(','));
                for (var i = 0; i < nodes.length; i++) {
                    var node = nodes[i];
                    var link = node.querySelector('a[href*="watch?v="], a[href*="v="]');
                    if (!link) continue;
                    var href = link.getAttribute('href') || '';
                    var m = href.match(/[?&]v=([A-Za-z0-9_-]{11})/);
                    if (!m) continue;
                    var vid = m[1];
                    if (seen[vid]) continue;
                    seen[vid] = true;

                    var titleEl = node.querySelector('#video-title, h3, h4, .media-item-headline, .title, yt-formatted-string');
                    var title = (titleEl ? titleEl.textContent : link.textContent) || '';
                    title = title.replace(/\\s+/g, ' ').trim();
                    if (!title || title === '[Deleted video]' || title === '[Private video]') continue;

                    var bylineEl = node.querySelector('#byline, .media-item-byline, .secondary-flex-columns, ytd-channel-name, .subtitle');
                    var artist = bylineEl ? (bylineEl.textContent || '').replace(/\\s+/g, ' ').trim() : '';

                    var durEl = node.querySelector('ytd-thumbnail-overlay-time-status-renderer, ytm-thumbnail-overlay-time-status-renderer, .badge-shape-wiz__text');
                    var duration = durEl ? (durEl.textContent || '').trim() : '';

                    items.push({ videoId: vid, title: title, artist: artist, duration: duration });
                }

                if (items.length === 0) {
                    var listMatch = (window.location.href || '').match(/[?&]list=([^&]+)/);
                    var links = document.querySelectorAll('a[href*="/watch?v="]');
                    for (var j = 0; j < links.length; j++) {
                        var a = links[j];
                        var h = a.getAttribute('href') || '';
                        if (listMatch && h.indexOf('list=') === -1 &&
                            !a.closest('ytm-playlist-video-list-renderer, ytd-playlist-video-list-renderer, ytm-section-list-renderer, ytmusic-playlist-shelf-renderer')) {
                            continue;
                        }
                        var vm = h.match(/[?&]v=([A-Za-z0-9_-]{11})/);
                        if (!vm || seen[vm[1]]) continue;
                        var label = (a.getAttribute('aria-label') || a.textContent || '').replace(/\\s+/g, ' ').trim();
                        if (!label || label.length < 2) continue;
                        seen[vm[1]] = true;
                        items.push({ videoId: vm[1], title: label, artist: '', duration: '' });
                    }
                }

                if (items.length > 0) {
                    return JSON.stringify({
                        '__domFallback': items,
                        '__domTitle': docTitle
                    });
                }
            } catch (e) {}
            return '';
        })();
        """
        var capturedJSON: [String: Any]?
        var domCandidate: [String: Any]?
        for attempt in 0..<18 {
            if attempt == 3 || attempt == 8 {
                _ = try? await wv.evaluateJavaScript("window.scrollBy(0, 600);")
            }
            if let raw = try? await wv.evaluateJavaScript(pollJS) as? String,
               !raw.isEmpty,
               let data = raw.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if dict["__domFallback"] != nil {
                    domCandidate = dict
                    if attempt >= 5 { break }
                } else {
                    capturedJSON = dict
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        let finalJSON = capturedJSON ?? domCandidate
        let cookies = await Self.youtubeCookieHeader(forceRefresh: true)
        wv.stopLoading()
        wv.loadHTMLString("", baseURL: nil)

        guard let finalJSON else { return nil }
        return (finalJSON, cookies)
    }

    // MARK: - Lock & WebView Setup

    @discardableResult
    private func acquireLock(timeoutSeconds: Double? = nil) async -> Bool {
        if !isBusy {
            isBusy = true
            return true
        }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append((id: waiterID, continuation: continuation))
            if let timeoutSeconds {
                Task { @MainActor [weak self] in
                    let ns = UInt64(max(0.2, timeoutSeconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: ns)
                    guard let self else { return }
                    if let idx = self.waiters.firstIndex(where: { $0.id == waiterID }) {
                        let expired = self.waiters.remove(at: idx)
                        expired.continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func releaseLock() {
        isBusy = false
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            isBusy = true
            next.continuation.resume(returning: true)
        }
    }

    private func ensureWebView() -> WKWebView? {
        if let existing = webView {
            attachToKeyWindowIfNeeded(existing)
            return existing
        }

        let ucc = WKUserContentController()
        let proxy = WeakScriptProxy(self)
        ucc.add(proxy, name: "ytResolverPlayerJSON")
        ucc.add(proxy, name: "ytResolverMediaURL")
        ucc.addUserScript(WKUserScript(
            source: Self.resolverBootstrapJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = ucc
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: CGRect(x: -400, y: -400, width: 320, height: 180), configuration: config)
        wv.customUserAgent = WebMediaDownloader.browserUserAgent
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        wv.isHidden = false
        wv.navigationDelegate = self
        attachToKeyWindowIfNeeded(wv)
        self.webView = wv
        return wv
    }

    private func attachToKeyWindowIfNeeded(_ wv: WKWebView) {
        if wv.superview != nil { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        if let keyWindow {
            keyWindow.insertSubview(wv, at: 0)
            hostContainerView = keyWindow
        }
    }

    private func loadAndWait(url: URL, in wv: WKWebView, timeoutSeconds: Double) async {
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.activePageFinishContinuation = continuation
            self.activePageFinishToken = token
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                // Only time out the load that scheduled this timer, not a later one.
                guard let self, self.activePageFinishToken == token else { return }
                self.resumePageFinishIfPending()
            }
            wv.load(URLRequest(url: url))
        }
    }

    private func resumePageFinishIfPending() {
        guard let cont = activePageFinishContinuation else { return }
        activePageFinishContinuation = nil
        activePageFinishToken = nil
        cont.resume()
    }

    /// `evaluateJavaScript` can stay unanswered forever when WebKit suspends the web content process
    /// (app in background, memory pressure). Because every browser operation holds `isBusy`, one hung
    /// call used to block ALL later browser resolves — after Stop → Retry nothing would ever download.
    /// This bounds every JS call with a timeout.
    private func evaluateJS(_ js: String, in wv: WKWebView, timeoutSeconds: Double = 4) async -> String? {
        let gate = ResumeOnceGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            wv.evaluateJavaScript(js) { result, _ in
                let text = result as? String
                if gate.claim() { continuation.resume(returning: text) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// WebKit's content process can be killed by iOS. Drop the dead web view and unblock any waiter.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.resumePageFinishIfPending()
            self.resumeActiveResolve(with: nil)
            if self.webView === webView {
                self.webView?.removeFromSuperview()
                self.webView = nil
                self.hostContainerView = nil
            }
        }
    }

    private func pollPlayerResponseFromDOM() async {
        guard let wv = webView, activeResolveContinuation != nil else { return }
        let js = """
        (function() {
            try {
                var v = document.querySelector('video');
                if (v && v.paused) {
                    v.muted = true;
                    v.volume = 0;
                    var pPromise = v.play();
                    if (pPromise && typeof pPromise.catch === 'function') pPromise.catch(function(){});
                }
                if (v && (v.currentSrc || v.src)) {
                    var src = v.currentSrc || v.src;
                    if (src.indexOf('googlevideo.com/videoplayback') !== -1 || src.indexOf('.m3u8') !== -1) {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ytResolverMediaURL) {
                            window.webkit.messageHandlers.ytResolverMediaURL.postMessage({ url: src });
                        }
                    }
                }
                var p = document.getElementById('movie_player') || document.querySelector('#movie_player');
                if (p && typeof p.getPlayerResponse === 'function') {
                    var pr = p.getPlayerResponse();
                    if (pr && pr.streamingData) return JSON.stringify(pr);
                }
                if (window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.streamingData) {
                    return JSON.stringify(window.ytInitialPlayerResponse);
                }
            } catch (e) {}
            return '';
        })();
        """
        guard let raw = await evaluateJS(js, in: wv), !raw.isEmpty else { return }
        handleCapturedPlayerJSON(raw, visitorData: nil)
    }

    private func handleCapturedPlayerJSON(_ rawJSON: String, visitorData: String?) {
        guard let videoID = activeVideoID,
              let watchURL = activeWatchURL,
              let data = rawJSON.data(using: .utf8) else {
            return
        }
        if let visitorData, !visitorData.isEmpty {
            Task { await YouTubeStreamResolver.cacheVisitorData(visitorData) }
        }
        let headers = [
            "User-Agent": WebMediaDownloader.browserUserAgent,
            "Referer": watchURL.absoluteString
        ]
        guard let parsed = YouTubeStreamResolver.parsePlayerResponseJSON(
            data,
            videoID: videoID,
            sourcePageURL: watchURL,
            headers: headers
        ), !parsed.streams.isEmpty else {
            return
        }
        if let vd = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["responseContext"] as? [String: Any],
           let respVD = vd["visitorData"] as? String {
            Task { await YouTubeStreamResolver.cacheVisitorData(respVD) }
        }
        resumeActiveResolve(with: parsed)
    }

    private func resumeActiveResolve(with result: YouTubeResolvedResult?) {
        guard let cont = activeResolveContinuation else { return }
        activeResolveContinuation = nil
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        cont.resume(returning: result)
    }

    private func finishActiveResolveWithFallback() async {
        await pollPlayerResponseFromDOM()
        guard activeResolveContinuation != nil else { return }
        if !fallbackStreamURLs.isEmpty, let vid = activeVideoID {
            var enriched = fallbackStreamURLs
            if let audioCandidate = fallbackStreamURLs.first(where: { $0.isAudio && !$0.isHLS }),
               let videoCandidate = fallbackStreamURLs.first(where: { !$0.isAudio && !$0.isHLS }) {
                let paired = DetectedBrowserMedia(
                    url: videoCandidate.url,
                    pairedAudioURL: audioCandidate.url,
                    isHLS: false,
                    isAudio: false,
                    title: videoCandidate.title,
                    author: videoCandidate.author,
                    qualityLabel: videoCandidate.qualityLabel,
                    referer: videoCandidate.referer,
                    customHeaders: videoCandidate.customHeaders,
                    durationSeconds: videoCandidate.durationSeconds,
                    isActivelyPlaying: false
                )
                enriched.insert(paired, at: 0)
            }
            let rawTitle = webView?.title?
                .replacingOccurrences(of: " - YouTube", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty == false) ? rawTitle! : "YouTube Video"
            let fallback = YouTubeResolvedResult(
                videoID: vid,
                title: title,
                author: nil,
                durationSeconds: nil,
                streams: enriched,
                errorReason: nil
            )
            resumeActiveResolve(with: fallback)
        } else {
            resumeActiveResolve(with: nil)
        }
    }

    // MARK: - WKNavigationDelegate & WKScriptMessageHandler

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.resumePageFinishIfPending()
            if self.activeResolveContinuation != nil {
                await self.pollPlayerResponseFromDOM()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.resumePageFinishIfPending()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.resumePageFinishIfPending()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "ytResolverPlayerJSON" {
            let raw = body["json"] as? String ?? ""
            let vd = body["visitorData"] as? String
            if !raw.isEmpty {
                self.handleCapturedPlayerJSON(raw, visitorData: vd)
            }
        } else if message.name == "ytResolverMediaURL" {
            guard let urlStr = body["url"] as? String,
                  let rawStreamURL = URL(string: urlStr),
                  let watchURL = self.activeWatchURL else { return }
            let lower = urlStr.lowercased()
            let isHLS = lower.contains(".m3u8") || lower.contains("/manifest/hls")
            let isAudio = lower.contains("mime=audio") || lower.contains("mime%3daudio")
            let streamURL = isHLS ? rawStreamURL : YouTubeStreamResolver.cleanGooglevideoURL(rawStreamURL)
            let media = DetectedBrowserMedia(
                url: streamURL,
                isHLS: isHLS,
                isAudio: isAudio,
                title: nil,
                author: nil,
                qualityLabel: isHLS ? "HLS Stream" : (isAudio ? "Audio" : "Video"),
                referer: watchURL.absoluteString,
                customHeaders: [
                    "User-Agent": WebMediaDownloader.browserUserAgent,
                    "Referer": watchURL.absoluteString
                ],
                durationSeconds: nil,
                isActivelyPlaying: false
            )
            if !self.fallbackStreamURLs.contains(where: { $0.url == streamURL }) {
                self.fallbackStreamURLs.append(media)
            }
        }
    }

    // MARK: - Silent Bootstrap JS

    private static let resolverBootstrapJS = #"""
    (function() {
        if (window.__mpResolverInstalled) return;
        window.__mpResolverInstalled = true;

        function postPlayerJSON(jsonStr, visitorData) {
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ytResolverPlayerJSON) {
                    window.webkit.messageHandlers.ytResolverPlayerJSON.postMessage({
                        json: jsonStr,
                        visitorData: visitorData || ''
                    });
                }
            } catch (e) {}
        }

        function postMediaURL(url) {
            try {
                if (!url || typeof url !== 'string') return;
                if (url.indexOf('googlevideo.com/videoplayback') === -1 && url.indexOf('.m3u8') === -1) return;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ytResolverMediaURL) {
                    window.webkit.messageHandlers.ytResolverMediaURL.postMessage({ url: url });
                }
            } catch (e) {}
        }

        var origPlay = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function() {
            try {
                this.muted = true;
                this.volume = 0;
                if (this.currentSrc || this.src) postMediaURL(this.currentSrc || this.src);
            } catch (e) {}
            try {
                return origPlay.apply(this, arguments);
            } catch (e) {
                return Promise.resolve();
            }
        };

        try {
            var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            if (srcDesc && srcDesc.set) {
                Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                    configurable: true,
                    enumerable: srcDesc.enumerable,
                    get: srcDesc.get,
                    set: function(val) {
                        this.muted = true;
                        this.volume = 0;
                        if (val) postMediaURL(String(val));
                        return srcDesc.set.call(this, val);
                    }
                });
            }
        } catch (e) {}

        if (window.PerformanceObserver) {
            try {
                var perfObs = new PerformanceObserver(function(list) {
                    var entries = list.getEntries();
                    for (var i = 0; i < entries.length; i++) {
                        if (entries[i] && entries[i].name) postMediaURL(entries[i].name);
                    }
                });
                perfObs.observe({ entryTypes: ['resource'] });
            } catch (e) {}
        }

        if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function(input) {
                var urlStr = '';
                try { urlStr = typeof input === 'string' ? input : (input && input.url ? input.url : ''); } catch (e) {}
                if (urlStr) postMediaURL(urlStr);
                return origFetch.apply(this, arguments).then(function(resp) {
                    try {
                        if (urlStr.indexOf('/youtubei/v1/player') !== -1 && resp && resp.clone) {
                            resp.clone().text().then(function(txt) {
                                if (txt && txt.indexOf('streamingData') !== -1) postPlayerJSON(txt, '');
                            });
                        }
                    } catch (e) {}
                    return resp;
                });
            };
        }

        if (window.XMLHttpRequest) {
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__mpUrl = url ? String(url) : '';
                if (this.__mpUrl) postMediaURL(this.__mpUrl);
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var xhr = this;
                if (xhr.__mpUrl && xhr.__mpUrl.indexOf('/youtubei/v1/player') !== -1) {
                    xhr.addEventListener('load', function() {
                        try {
                            if (xhr.responseText && xhr.responseText.indexOf('streamingData') !== -1) {
                                postPlayerJSON(xhr.responseText, '');
                            }
                        } catch (e) {}
                    });
                }
                return origSend.apply(this, arguments);
            };
        }

        document.addEventListener('DOMContentLoaded', function() {
            try {
                if (window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.streamingData) {
                    var vd = '';
                    try { vd = window.ytInitialPlayerResponse.responseContext.visitorData || ''; } catch (e) {}
                    postPlayerJSON(JSON.stringify(window.ytInitialPlayerResponse), vd);
                }
            } catch (e) {}
        });
    })();
    """#
}

/// Thread-safe "first caller wins" flag so a continuation is resumed exactly once
/// when racing a completion handler against a timeout.
final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
