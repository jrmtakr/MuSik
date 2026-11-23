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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var activeVideoID: String?
    private var activeWatchURL: URL?
    private var activeResolveContinuation: CheckedContinuation<YouTubeResolvedResult?, Never>?
    private var activeTimeoutTask: Task<Void, Never>?
    private var fallbackStreamURLs: [DetectedBrowserMedia] = []

    private var activePageFinishContinuation: CheckedContinuation<Void, Never>?

    private override init() {
        super.init()
    }

    private static var cachedCookieState: (value: String?, fetchedAt: Date)?

    /// Reads current YouTube & Google session cookies from the shared built-in browser data store,
    /// caching in memory for 60s to avoid thousands of WebKit IPC round-trips during large batch imports.
    static func youtubeCookieHeader(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh,
           let cached = cachedCookieState,
           Date().timeIntervalSince(cached.fetchedAt) < 60 {
            return cached.value
        }
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
        let result = pairs.isEmpty ? nil : pairs.joined(separator: "; ")
        cachedCookieState = (result, now)
        return result
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

        await acquireLock()
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
        if let raw = try? await wv.evaluateJavaScript(js) as? String, !raw.isEmpty {
            return raw
        }
        return nil
    }

    /// Resolves playable streams for a YouTube video inside the built-in browser WKWebView,
    /// capturing `ytInitialPlayerResponse`, `/youtubei/v1/player`, and `#movie_player.getPlayerResponse()`.
    func resolveStreamsInBrowser(videoID: String) async -> (result: YouTubeResolvedResult, cookiesHeader: String?)? {
        let cleanID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty,
              let watchURL = URL(string: "https://m.youtube.com/watch?v=\(cleanID)") else {
            return nil
        }

        await acquireLock()
        defer { releaseLock() }

        guard let wv = ensureWebView() else { return nil }
        let cookiesHeader = await Self.youtubeCookieHeader()

        activeVideoID = cleanID
        activeWatchURL = watchURL
        fallbackStreamURLs = []

        let result: YouTubeResolvedResult? = await withCheckedContinuation { continuation in
            self.activeResolveContinuation = continuation
            let isBackground = UIApplication.shared.applicationState == .background
            let maxWaitMs = isBackground ? 6_500 : 10_500
            let stepMs = 250
            let steps = max(1, maxWaitMs / stepMs)

            self.activeTimeoutTask = Task { [weak self] in
                for _ in 0..<steps {
                    try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    if self?.activeResolveContinuation == nil { return }
                    await self?.pollPlayerResponseFromDOM()
                    if self?.activeResolveContinuation == nil { return }
                }
                guard !Task.isCancelled else { return }
                await self?.finishActiveResolveWithFallback()
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
        let updatedCookies = await Self.youtubeCookieHeader(forceRefresh: true) ?? cookiesHeader
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
        await acquireLock()
        defer { releaseLock() }

        guard let wv = ensureWebView() else { return nil }
        await loadAndWait(url: url, in: wv, timeoutSeconds: 10)
        try? await Task.sleep(nanoseconds: 900_000_000)

        let js = """
        (function() {
            try {
                if (window.ytInitialData && typeof window.ytInitialData === 'object') {
                    return JSON.stringify(window.ytInitialData);
                }
            } catch (e) {}
            return '';
        })();
        """
        let raw = try? await wv.evaluateJavaScript(js) as? String
        let cookies = await Self.youtubeCookieHeader(forceRefresh: true)
        wv.stopLoading()
        wv.loadHTMLString("", baseURL: nil)

        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json, cookies)
    }

    // MARK: - Lock & WebView Setup

    private func acquireLock() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        isBusy = true
    }

    private func releaseLock() {
        isBusy = false
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
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
        config.mediaTypesRequiringUserActionForPlayback = [.all]

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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.activePageFinishContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.resumePageFinishIfPending()
            }
            wv.load(URLRequest(url: url))
        }
    }

    private func resumePageFinishIfPending() {
        guard let cont = activePageFinishContinuation else { return }
        activePageFinishContinuation = nil
        cont.resume()
    }

    private func pollPlayerResponseFromDOM() async {
        guard let wv = webView, activeResolveContinuation != nil else { return }
        let js = """
        (function() {
            try {
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
        guard let raw = try? await wv.evaluateJavaScript(js) as? String, !raw.isEmpty else { return }
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
            let fallback = YouTubeResolvedResult(
                videoID: vid,
                title: webView?.title?.replacingOccurrences(of: " - YouTube", with: "") ?? "YouTube Video",
                author: nil,
                durationSeconds: nil,
                streams: fallbackStreamURLs,
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
                  let streamURL = URL(string: urlStr),
                  let watchURL = self.activeWatchURL else { return }
            let lower = urlStr.lowercased()
            let isHLS = lower.contains(".m3u8") || lower.contains("/manifest/hls")
            let isAudio = lower.contains("mime=audio") || lower.contains("mime%3daudio")
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
                this.pause();
                if (this.currentSrc || this.src) postMediaURL(this.currentSrc || this.src);
            } catch (e) {}
            return Promise.resolve();
        };

        if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function(input) {
                var urlStr = '';
                try { urlStr = typeof input === 'string' ? input : (input && input.url ? input.url : ''); } catch (e) {}
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
