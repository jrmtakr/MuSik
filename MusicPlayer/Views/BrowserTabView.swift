import Observation
import SwiftUI
import UIKit
import WebKit

@Observable
final class BrowserController {
    weak var webView: WKWebView?
    var currentURL: URL?
    var pageTitle: String = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var estimatedProgress: Double = 0
    var detectedStreams: [DetectedBrowserMedia] = []

    var detectedMedia: DetectedBrowserMedia? {
        detectedStreams.last
    }

    func addDetectedStream(_ media: DetectedBrowserMedia) {
        if !detectedStreams.contains(where: { $0.url == media.url }) {
            detectedStreams.append(media)
        }
    }

    func clearDetectedStreams() {
        detectedStreams.removeAll()
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reloadOrStop() {
        if isLoading {
            webView?.stopLoading()
        } else {
            webView?.reload()
        }
    }

    func load(_ url: URL) {
        clearDetectedStreams()
        webView?.load(URLRequest(url: url))
    }
}

struct WebViewWrapper: UIViewRepresentable {
    let url: URL
    let isPrivate: Bool
    let darkModeEnabled: Bool
    let adBlockEnabled: Bool
    let inlineVideoPlayback: Bool
    var controller: BrowserController? = nil
    var contentBlocker: ContentBlockerManager? = nil
    var onURLChange: (URL, String?) -> Void = { _, _ in }
    var onMediaDetected: (DetectedBrowserMedia) -> Void = { _ in }
    var onWKDownloadImported: (URL, String) -> Void = { _, _ in }
    var onWKDownloadFailed: (Error) -> Void = { _ in }
    var onDownloadTriggered: (URL) -> Void = { _ in }

    private static let mobileSafariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private static let documentStartMediaJS = """
    (function() {
        if (window.__musicPlayerHookInstalled) return;
        window.__musicPlayerHookInstalled = true;
        var seen = new Set();

        function classify(src, forcedKind) {
            if (!src || !/^https?:\\/\\//i.test(src)) return null;
            var lower = src.toLowerCase();
            if (forcedKind) return forcedKind;
            if (/\\.m3u8(\\?|#|$|&)/i.test(lower) || /\\/(hls|manifest)\\/.*m3u8/i.test(lower) || /type=m3u8/i.test(lower)) return 'hls';
            if (/\\.(mp3|m4a|wav|aac|flac|ogg)(\\?|#|$)/i.test(lower) || /mime=audio(%2f|\\/)?/i.test(lower)) return 'audio';
            if (/\\.(mp4|mov|m4v)(\\?|#|$)/i.test(lower) || /mime=video(%2f|\\/)?(mp4|quicktime|x-m4v)/i.test(lower)) return 'video';
            return null;
        }

        function report(src, forcedKind) {
            var kind = classify(src, forcedKind);
            if (!kind || seen.has(src)) return;
            seen.add(src);
            try {
                window.webkit.messageHandlers.mediaDetected.postMessage({
                    url: src,
                    kind: kind,
                    title: document.title || ''
                });
            } catch (e) {}
        }

        if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function(input) {
                var reqUrl = '';
                try {
                    reqUrl = typeof input === 'string' ? input : (input && input.url) || '';
                    if (reqUrl) report(new URL(reqUrl, window.location.href).toString(), null);
                } catch (e) {}
                var p = origFetch.apply(this, arguments);
                if (p && typeof p.then === 'function') {
                    p.then(function(resp) {
                        try {
                            var ct = (resp.headers && resp.headers.get('content-type') || '').toLowerCase();
                            var finalUrl = resp.url || reqUrl;
                            if (!finalUrl) return;
                            var abs = new URL(finalUrl, window.location.href).toString();
                            if (ct.indexOf('mpegurl') !== -1) report(abs, 'hls');
                            else if (ct.indexOf('audio/') === 0) report(abs, 'audio');
                            else if (ct.indexOf('video/') === 0) report(abs, 'video');
                        } catch (e) {}
                    }).catch(function() {});
                }
                return p;
            };
        }

        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            try {
                this.__mpReqUrl = url ? new URL(url, window.location.href).toString() : '';
                if (this.__mpReqUrl) report(this.__mpReqUrl, null);
                if (!this.__mpLoadHooked) {
                    this.__mpLoadHooked = true;
                    this.addEventListener('loadend', function() {
                        try {
                            var ct = (this.getResponseHeader('Content-Type') || '').toLowerCase();
                            var finalUrl = this.responseURL || this.__mpReqUrl;
                            if (!finalUrl) return;
                            var abs = new URL(finalUrl, window.location.href).toString();
                            if (ct.indexOf('mpegurl') !== -1) report(abs, 'hls');
                            else if (ct.indexOf('audio/') === 0) report(abs, 'audio');
                            else if (ct.indexOf('video/') === 0) report(abs, 'video');
                        } catch (e) {}
                    });
                }
            } catch (e) {}
            return origOpen.apply(this, arguments);
        };

        function inspectMediaElement(el) {
            if (!el) return;
            try {
                var src = el.currentSrc || el.src;
                if (!src) return;
                var abs = new URL(src, window.location.href).toString();
                var isAudioTag = (el.tagName && el.tagName.toLowerCase() === 'audio') ||
                    (el.parentElement && el.parentElement.tagName && el.parentElement.tagName.toLowerCase() === 'audio');
                var kind = /\\.m3u8/i.test(abs) ? 'hls' : (isAudioTag ? 'audio' : 'video');
                report(abs, kind);
            } catch (e) {}
        }

        var origPlay = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function() {
            inspectMediaElement(this);
            return origPlay.apply(this, arguments);
        };

        var origLoad = HTMLMediaElement.prototype.load;
        HTMLMediaElement.prototype.load = function() {
            inspectMediaElement(this);
            return origLoad.apply(this, arguments);
        };

        document.addEventListener('loadedmetadata', function(e) { inspectMediaElement(e.target); }, true);
        document.addEventListener('canplay', function(e) { inspectMediaElement(e.target); }, true);
        document.addEventListener('play', function(e) { inspectMediaElement(e.target); }, true);

        function scan() {
            document.querySelectorAll('video, video source, audio, audio source').forEach(inspectMediaElement);
        }

        window.addEventListener('DOMContentLoaded', function() {
            scan();
            if (document.documentElement) {
                new MutationObserver(scan).observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src']
                });
            }
            setInterval(scan, 1500);
        });
    })();
    """

    private static let darkModeCSSScript = """
    (function() {
        var style = document.getElementById('__musicplayer_dark_css');
        if (!style) {
            style = document.createElement('style');
            style.id = '__musicplayer_dark_css';
            style.textContent = 'html { filter: invert(90%) hue-rotate(180deg); background: #111 !important; } img, video, picture, canvas, svg { filter: invert(100%) hue-rotate(180deg); }';
            (document.head || document.documentElement).appendChild(style);
        }
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            contentBlocker: contentBlocker,
            onURLChange: onURLChange,
            onMediaDetected: onMediaDetected,
            onWKDownloadImported: onWKDownloadImported,
            onWKDownloadFailed: onWKDownloadFailed,
            onDownloadTriggered: onDownloadTriggered
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "mediaDetected")
        userController.addUserScript(
            WKUserScript(
                source: Self.documentStartMediaJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        if adBlockEnabled {
            userController.addUserScript(
                WKUserScript(
                    source: ContentBlockerManager.cosmeticAdBlockScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        config.allowsInlineMediaPlayback = inlineVideoPlayback
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.mobileSafariUA
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.controller = controller
        context.coordinator.contentBlocker = contentBlocker
        context.coordinator.darkModeEnabled = darkModeEnabled
        context.coordinator.lastBlockingState = adBlockEnabled
        context.coordinator.observe(webView)
        context.coordinator.lastRequestedURL = url
        controller?.webView = webView

        if let contentBlocker {
            contentBlocker.isBlockingEnabled = adBlockEnabled
            if adBlockEnabled, let cached = contentBlocker.cachedRuleList {
                webView.configuration.userContentController.add(cached)
            } else if adBlockEnabled {
                Task { @MainActor in
                    await contentBlocker.applyRules(to: webView.configuration)
                }
            }
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.contentBlocker = contentBlocker
        context.coordinator.onURLChange = onURLChange
        context.coordinator.onMediaDetected = onMediaDetected
        context.coordinator.onWKDownloadImported = onWKDownloadImported
        context.coordinator.onWKDownloadFailed = onWKDownloadFailed
        context.coordinator.onDownloadTriggered = onDownloadTriggered

        if controller?.webView !== webView {
            controller?.webView = webView
        }

        if let contentBlocker, context.coordinator.lastBlockingState != adBlockEnabled {
            context.coordinator.lastBlockingState = adBlockEnabled
            contentBlocker.isBlockingEnabled = adBlockEnabled
            Task { @MainActor in
                await contentBlocker.applyRules(to: webView.configuration)
                webView.reload()
            }
        }

        if context.coordinator.darkModeEnabled != darkModeEnabled {
            context.coordinator.darkModeEnabled = darkModeEnabled
            if darkModeEnabled {
                webView.evaluateJavaScript(Self.darkModeCSSScript)
            } else {
                webView.evaluateJavaScript("document.getElementById('__musicplayer_dark_css')?.remove();")
            }
        }

        if context.coordinator.lastRequestedURL != url {
            context.coordinator.lastRequestedURL = url
            controller?.clearDetectedStreams()
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        static let downloadableExtensions: Set<String> = [
            "mp3", "m4a", "wav", "aac", "flac", "aiff", "caf",
            "mp4", "mov", "m4v",
            "pdf", "zip", "cbz", "png", "jpg", "jpeg", "webp", "gif", "txt"
        ]

        var controller: BrowserController?
        var contentBlocker: ContentBlockerManager?
        var onURLChange: (URL, String?) -> Void
        var onMediaDetected: (DetectedBrowserMedia) -> Void
        var onWKDownloadImported: (URL, String) -> Void
        var onWKDownloadFailed: (Error) -> Void
        var onDownloadTriggered: (URL) -> Void
        var lastRequestedURL: URL?
        var lastBlockingState: Bool?
        var darkModeEnabled = false

        private var observations: [NSKeyValueObservation] = []
        private var activeDownloads: [ObjectIdentifier: (tempURL: URL, fileName: String)] = [:]

        init(
            controller: BrowserController?,
            contentBlocker: ContentBlockerManager?,
            onURLChange: @escaping (URL, String?) -> Void,
            onMediaDetected: @escaping (DetectedBrowserMedia) -> Void,
            onWKDownloadImported: @escaping (URL, String) -> Void,
            onWKDownloadFailed: @escaping (Error) -> Void,
            onDownloadTriggered: @escaping (URL) -> Void
        ) {
            self.controller = controller
            self.contentBlocker = contentBlocker
            self.onURLChange = onURLChange
            self.onMediaDetected = onMediaDetected
            self.onWKDownloadImported = onWKDownloadImported
            self.onWKDownloadFailed = onWKDownloadFailed
            self.onDownloadTriggered = onDownloadTriggered
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                    guard let current = view.url else { return }
                    let currentTitle = view.title
                    DispatchQueue.main.async {
                        self?.controller?.currentURL = current
                        self?.onURLChange(current, currentTitle)
                    }
                },
                webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                    let title = view.title ?? ""
                    let current = view.url
                    DispatchQueue.main.async {
                        self?.controller?.pageTitle = title
                        if let current {
                            self?.onURLChange(current, title)
                        }
                    }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                    let value = view.canGoBack
                    DispatchQueue.main.async {
                        self?.controller?.canGoBack = value
                    }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                    let value = view.canGoForward
                    DispatchQueue.main.async {
                        self?.controller?.canGoForward = value
                    }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                    let value = view.isLoading
                    DispatchQueue.main.async {
                        self?.controller?.isLoading = value
                    }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                    let value = view.estimatedProgress
                    DispatchQueue.main.async {
                        self?.controller?.estimatedProgress = value
                    }
                }
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.controller?.clearDetectedStreams()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if darkModeEnabled {
                webView.evaluateJavaScript(WebViewWrapper.darkModeCSSScript)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mediaDetected",
                  let dict = message.body as? [String: Any],
                  let urlString = dict["url"] as? String,
                  let url = URL(string: urlString) else {
                return
            }

            let kind = dict["kind"] as? String ?? "video"
            let title = dict["title"] as? String
            let referer = controller?.currentURL?.absoluteString

            DispatchQueue.main.async {
                let media = DetectedBrowserMedia(
                    url: url,
                    isHLS: kind == "hls",
                    isAudio: kind == "audio",
                    title: title,
                    referer: referer
                )
                let wasNew = !(self.controller?.detectedStreams.contains(where: { $0.url == media.url }) ?? false)
                self.controller?.addDetectedStream(media)
                if wasNew {
                    self.onMediaDetected(media)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                let blocking = lastBlockingState ?? true
                if navigationAction.navigationType == .linkActivated || !blocking {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMainOrBlank = navigationAction.targetFrame?.isMainFrame ?? true
            if isMainOrBlank,
               let targetURL = navigationAction.request.url,
               Self.downloadableExtensions.contains(targetURL.pathExtension.lowercased()) {
                DispatchQueue.main.async {
                    self.onDownloadTriggered(targetURL)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
            if let httpResponse = navigationResponse.response as? HTTPURLResponse,
               let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
               disposition.contains("attachment") {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let resolvedName = BrowserTabView.resolvedMediaFileName(
                suggestedName: suggestedFilename,
                sourceURL: response.url,
                mimeType: response.mimeType?.lowercased() ?? ""
            )
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)_\(resolvedName)")
            activeDownloads[ObjectIdentifier(download)] = (tempURL, resolvedName)
            completionHandler(tempURL)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let info = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            DispatchQueue.main.async {
                self.onWKDownloadImported(info.tempURL, info.fileName)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let info = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
                try? FileManager.default.removeItem(at: info.tempURL)
            }
            DispatchQueue.main.async {
                self.onWKDownloadFailed(error)
            }
        }
    }
}

struct BrowserTabView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(\.dismiss) private var dismiss

    @Binding var showPlayerSheet: Bool
    var isModal: Bool = false

    @State private var urlString = ""
    @State private var activeURL = URL(string: "https://www.google.com")!
    @State private var browser = BrowserController()
    @State private var contentBlocker = ContentBlockerManager()
    @State private var isDownloading = false
    @State private var downloadStatus: String?
    @FocusState private var isAddressFieldFocused: Bool

    @State private var pendingMediaPrompt: DetectedBrowserMedia?
    @State private var hlsQualityRequest: DetectedBrowserMedia?
    @State private var hlsVariants: [HLSQualityVariant] = []
    @State private var loadingVariants = false

    @State private var showingTabsSheet = false
    @State private var showingBookmarksSheet = false
    @State private var showingStreamsSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar

                if browser.isLoading {
                    ProgressView(value: max(browser.estimatedProgress, 0.05))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                if let status = downloadStatus {
                    statusBanner(status)
                }

                if !downloader.activeDownloads.isEmpty {
                    activeDownloadsStrip
                }

                if let detected = browser.detectedMedia {
                    detectedMediaBanner(detected)
                }

                WebViewWrapper(
                    url: activeURL,
                    isPrivate: browserStore.activeTab.isPrivate,
                    darkModeEnabled: settings.webDarkModeEnabled,
                    adBlockEnabled: settings.adBlockEnabled,
                    inlineVideoPlayback: settings.inlineVideoPlayback,
                    controller: browser,
                    contentBlocker: contentBlocker,
                    onURLChange: { newURL, newTitle in
                        if !isAddressFieldFocused {
                            urlString = newURL.absoluteString
                        }
                        browserStore.updateActiveTab(urlString: newURL.absoluteString, title: newTitle)
                    },
                    onMediaDetected: { media in
                        if settings.autoCacheDetectedMedia {
                            handleDetectedMedia(media, autoMode: true)
                        } else if settings.askBeforeCaching && pendingMediaPrompt == nil {
                            pendingMediaPrompt = media
                        }
                    },
                    onWKDownloadImported: { tempURL, fileName in
                        mediaManager.importTemporaryFile(from: tempURL, preferredFileName: fileName)
                        downloadStatus = "Saved: \(fileName)"
                    },
                    onWKDownloadFailed: { error in
                        downloadStatus = "Download failed."
                        mediaManager.errorMessage = "Download failed: \(error.localizedDescription)"
                    },
                    onDownloadTriggered: { fileURL in
                        Task { await downloadFile(from: fileURL) }
                    }
                )
                .id("\(browserStore.activeTab.id.uuidString)-\(settings.inlineVideoPlayback)")
            }
            .onAppear {
                syncTabState()
            }
            .onChange(of: browserStore.activeTabID) { _, _ in
                syncTabState()
            }
            .onChange(of: browserStore.navigationRequestNonce) { _, _ in
                syncTabState()
            }
            .task(id: downloadStatus) {
                guard downloadStatus != nil, !isDownloading else { return }
                try? await Task.sleep(for: .seconds(3.0))
                if !Task.isCancelled && !isDownloading {
                    downloadStatus = nil
                }
            }
            .navigationTitle(browserStore.activeTab.isPrivate ? "Private Tab" : (browser.pageTitle.isEmpty ? "Browser" : browser.pageTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if isModal {
                        Button("Done") {
                            dismiss()
                        }
                    }

                    Button {
                        browser.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!browser.canGoBack)

                    Button {
                        browser.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!browser.canGoForward)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if browser.detectedStreams.count > 1 {
                            showingStreamsSheet = true
                        } else if let latest = browser.detectedMedia {
                            handleDetectedMedia(latest, autoMode: false)
                        } else {
                            let target = targetDownloadURL
                            Task { await downloadFile(from: target) }
                        }
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Image(systemName: browser.detectedStreams.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                                .foregroundStyle(browser.detectedStreams.isEmpty ? .primary : Color.accentColor)
                        }
                    }

                    Button {
                        let current = browser.currentURL?.absoluteString ?? activeURL.absoluteString
                        browserStore.toggleBookmark(title: browser.pageTitle, urlString: current)
                    } label: {
                        let current = browser.currentURL?.absoluteString ?? activeURL.absoluteString
                        Image(systemName: browserStore.isBookmarked(current) ? "bookmark.fill" : "bookmark")
                    }

                    Button {
                        showingTabsSheet = true
                    } label: {
                        Image(systemName: "square.on.square")
                    }

                    Menu {
                        Button {
                            browser.reloadOrStop()
                        } label: {
                            Label(browser.isLoading ? "Stop" : "Reload",
                                  systemImage: browser.isLoading ? "xmark" : "arrow.clockwise")
                        }

                        Button {
                            showingBookmarksSheet = true
                        } label: {
                            Label("Bookmarks & History", systemImage: "book")
                        }

                        if !browser.detectedStreams.isEmpty {
                            Button {
                                showingStreamsSheet = true
                            } label: {
                                Label("Detected Media (\(browser.detectedStreams.count))", systemImage: "waveform.path.ecg")
                            }
                        }

                        Divider()

                        Button {
                            settings.adBlockEnabled.toggle()
                            mediaManager.statusMessage = settings.adBlockEnabled
                                ? "Ad & popup blocker enabled"
                                : "Ad & popup blocker paused"
                        } label: {
                            Label(
                                settings.adBlockEnabled ? "Ad-Block: On" : "Ad-Block: Off",
                                systemImage: settings.adBlockEnabled ? "shield.checkered" : "shield.slash"
                            )
                        }

                        Button {
                            settings.webDarkModeEnabled.toggle()
                        } label: {
                            Label(
                                settings.webDarkModeEnabled ? "Web Dark Mode: On" : "Web Dark Mode: Off",
                                systemImage: settings.webDarkModeEnabled ? "moon.fill" : "moon"
                            )
                        }

                        Button {
                            settings.inlineVideoPlayback.toggle()
                            mediaManager.statusMessage = settings.inlineVideoPlayback
                                ? "Inline video player enabled"
                                : "Inline video player disabled"
                        } label: {
                            Label(
                                settings.inlineVideoPlayback ? "Inline Player: On" : "Inline Player: Off",
                                systemImage: "play.rectangle"
                            )
                        }

                        Divider()

                        Button {
                            extractAndSavePageImages()
                        } label: {
                            Label("Download Images", systemImage: "photo.stack")
                        }

                        Button {
                            let target = targetDownloadURL
                            Task { await downloadFile(from: target) }
                        } label: {
                            Label("Save Page / Media Link", systemImage: "arrow.down.circle")
                        }
                        .disabled(isDownloading)

                        Button {
                            if let pasted = UIPasteboard.general.string,
                               let pastedURL = resolvedURL(from: pasted) {
                                urlString = pastedURL.absoluteString
                                activeURL = pastedURL
                                Task { await downloadFile(from: pastedURL) }
                            } else {
                                mediaManager.errorMessage = "No valid URL found on your clipboard."
                            }
                        } label: {
                            Label("Paste & Save URL", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            UIApplication.shared.open(browser.currentURL ?? activeURL)
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                        }
                    } label: {
                        Image(systemName: settings.adBlockEnabled ? "shield.checkered" : "ellipsis.circle")
                            .foregroundStyle(settings.adBlockEnabled ? Color.accentColor : .primary)
                    }
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .confirmationDialog(
                "\(pendingMediaPrompt?.kindLabel ?? "Media") Detected",
                isPresented: Binding(
                    get: { pendingMediaPrompt != nil },
                    set: { if !$0 { pendingMediaPrompt = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let media = pendingMediaPrompt {
                    Button(media.isHLS ? "Select Video Quality" : "Cache Offline") {
                        pendingMediaPrompt = nil
                        handleDetectedMedia(media, autoMode: false)
                    }
                }
                Button("Ignore", role: .cancel) {
                    pendingMediaPrompt = nil
                }
            } message: {
                Text(pendingMediaPrompt?.url.absoluteString ?? "")
            }
            .sheet(isPresented: $showingStreamsSheet) {
                NavigationStack {
                    List(browser.detectedStreams) { stream in
                        Button {
                            showingStreamsSheet = false
                            handleDetectedMedia(stream, autoMode: false)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: stream.isAudio ? "music.note" : "film")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stream.kindLabel)
                                        .font(.subheadline.weight(.semibold))
                                    Text(stream.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                    }
                    .navigationTitle("Detected Streams")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingStreamsSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $hlsQualityRequest) { media in
                NavigationStack {
                    List {
                        if loadingVariants {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Loading stream qualities...")
                            }
                        } else {
                            ForEach(hlsVariants) { variant in
                                Button {
                                    hlsQualityRequest = nil
                                    Task {
                                        let headers = await buildRequestHeaders(for: media.url, referer: media.referer)
                                        downloader.startHLSDownload(
                                            from: media.url,
                                            title: media.title ?? browser.pageTitle,
                                            minimumBitrate: variant.peakBitrate > 0 ? variant.peakBitrate : nil,
                                            headers: headers
                                        )
                                    }
                                } label: {
                                    HStack {
                                        Text(variant.label)
                                        Spacer()
                                        Image(systemName: "arrow.down.circle")
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Select Quality")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { hlsQualityRequest = nil }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingTabsSheet) {
                BrowserTabsSheet(
                    onSelectTab: { tabID in
                        browserStore.activeTabID = tabID
                        showingTabsSheet = false
                    },
                    onAddTab: { isPrivate in
                        browserStore.addTab(isPrivate: isPrivate)
                        showingTabsSheet = false
                    }
                )
            }
            .sheet(isPresented: $showingBookmarksSheet) {
                BookmarksAndHistorySheet { selectedURLString in
                    showingBookmarksSheet = false
                    if let resolved = resolvedURL(from: selectedURLString) {
                        urlString = resolved.absoluteString
                        activeURL = resolved
                        browser.load(resolved)
                    }
                }
            }
        }
    }

    private func syncTabState() {
        let tab = browserStore.activeTab
        urlString = tab.urlString
        if let parsed = resolvedURL(from: tab.urlString) {
            if activeURL == parsed {
                browser.load(parsed)
            } else {
                activeURL = parsed
            }
        }
        browser.clearDetectedStreams()
    }

    private func statusBanner(_ status: String) -> some View {
        HStack(spacing: 8) {
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(status)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button {
                downloadStatus = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.14))
    }

    private var activeDownloadsStrip: some View {
        VStack(spacing: 4) {
            ForEach(downloader.activeDownloads) { dl in
                HStack(spacing: 8) {
                    ProgressView(value: dl.progress)
                        .progressViewStyle(.linear)
                    Text("\(dl.title) \(Int(dl.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                    Button {
                        downloader.cancelDownload(id: dl.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private func detectedMediaBanner(_ media: DetectedBrowserMedia) -> some View {
        HStack(spacing: 10) {
            Image(systemName: media.isAudio ? "music.note" : "film")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(media.kindLabel) Detected")
                    .font(.caption.weight(.semibold))
                Text(media.title?.isEmpty == false ? (media.title ?? "") : media.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if browser.detectedStreams.count > 1 {
                Button("All (\(browser.detectedStreams.count))") {
                    showingStreamsSheet = true
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(media.isHLS ? "Select Quality" : "Save Offline") {
                handleDetectedMedia(media, autoMode: false)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12))
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: browserStore.activeTab.isPrivate ? "eye.slash.fill" : "globe")
                    .font(.footnote)
                    .foregroundStyle(browserStore.activeTab.isPrivate ? .purple : .secondary)

                TextField("Search or enter web address", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($isAddressFieldFocused)
                    .onSubmit(navigateToInput)

                if !urlString.isEmpty && isAddressFieldFocused {
                    Button {
                        urlString = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Go", action: navigateToInput)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var targetDownloadURL: URL {
        if isAddressFieldFocused, let typed = resolvedURL(from: urlString) {
            return typed
        }
        return browser.currentURL ?? activeURL
    }

    private func navigateToInput() {
        isAddressFieldFocused = false
        guard let validURL = resolvedURL(from: urlString) else {
            mediaManager.errorMessage = "Please enter a valid website address."
            return
        }
        urlString = validURL.absoluteString
        if activeURL == validURL {
            browser.load(validURL)
        } else {
            activeURL = validURL
        }
    }

    private func resolvedURL(from rawInput: String) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        if trimmed.contains("."), !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        return settings.searchEngine.searchURL(for: trimmed)
    }

    private func buildRequestHeaders(for url: URL, referer: String?) async -> [String: String] {
        var headers: [String: String] = [:]
        if let referer, !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let store = browser.webView?.configuration.websiteDataStore.httpCookieStore {
            let cookies = await store.allCookies()
            let host = url.host?.lowercased() ?? ""
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            if !matching.isEmpty {
                headers["Cookie"] = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return headers
    }

    private func extractAndSavePageImages() {
        guard let webView = browser.webView else { return }
        let script = """
        Array.from(document.images || [])
          .filter(img => (img.naturalWidth || 0) >= 80 && (img.naturalHeight || 0) >= 80)
          .map(img => img.currentSrc || img.src)
          .filter(u => /^https?:\\/\\//i.test(u));
        """
        let pageTitle = browser.pageTitle.isEmpty ? (browser.currentURL?.host ?? "Web Images") : browser.pageTitle
        let referer = browser.currentURL?.absoluteString

        webView.evaluateJavaScript(script) { result, _ in
            let rawStrings = (result as? [String]) ?? []
            var seen = Set<String>()
            let urls = rawStrings.compactMap { s -> URL? in
                guard seen.insert(s).inserted else { return nil }
                return URL(string: s)
            }
            Task { @MainActor in
                await mediaManager.saveImagesFromWeb(urls, folderName: pageTitle, referer: referer)
            }
        }
    }

    private func handleDetectedMedia(_ media: DetectedBrowserMedia, autoMode: Bool) {
        if media.isHLS {
            if autoMode {
                Task {
                    let headers = await buildRequestHeaders(for: media.url, referer: media.referer)
                    downloader.startHLSDownload(
                        from: media.url,
                        title: media.title ?? browser.pageTitle,
                        headers: headers
                    )
                }
            } else {
                hlsQualityRequest = media
                loadingVariants = true
                hlsVariants = []
                Task {
                    let headers = await buildRequestHeaders(for: media.url, referer: media.referer)
                    hlsVariants = await downloader.fetchHLSVariants(
                        for: media.url,
                        headers: headers
                    )
                    loadingVariants = false
                }
            }
        } else {
            Task {
                let headers = await buildRequestHeaders(for: media.url, referer: media.referer)
                downloader.downloadDirectMedia(
                    from: media.url,
                    title: media.title ?? browser.pageTitle,
                    headers: headers,
                    maxDurationMinutes: settings.maxCacheDurationMinutes
                )
            }
        }
    }

    @MainActor
    private func downloadFile(from url: URL) async {
        let headers = await buildRequestHeaders(for: url, referer: browser.currentURL?.absoluteString)

        if url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8") {
            let media = DetectedBrowserMedia(
                url: url,
                isHLS: true,
                isAudio: false,
                title: browser.pageTitle,
                referer: browser.currentURL?.absoluteString
            )
            handleDetectedMedia(media, autoMode: false)
            return
        }

        let ext = url.pathExtension.lowercased()
        let isKnownDocumentOrMedia = Self.isDirectDownloadExtension(ext)
        if !isKnownDocumentOrMedia {
            downloadStatus = "Checking page for media..."
            isDownloading = true
            await downloader.resolveAndDownload(
                inputURLString: url.absoluteString,
                title: browser.pageTitle,
                headers: headers,
                maxDurationMinutes: settings.maxCacheDurationMinutes
            )
            isDownloading = false
            downloadStatus = nil
            return
        }

        let displayName = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        downloadStatus = "Downloading \(displayName)..."
        isDownloading = true
        defer {
            isDownloading = false
        }

        do {
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (tempURL, response) = try await URLSession.shared.download(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                try? FileManager.default.removeItem(at: tempURL)
                downloadStatus = "Download failed."
                mediaManager.errorMessage = "Download failed with HTTP status \(httpResponse.statusCode)."
                return
            }

            let mimeType = response.mimeType?.lowercased() ?? ""
            if mimeType.contains("mpegurl") {
                try? FileManager.default.removeItem(at: tempURL)
                downloadStatus = nil
                let media = DetectedBrowserMedia(
                    url: url,
                    isHLS: true,
                    isAudio: false,
                    title: browser.pageTitle,
                    referer: browser.currentURL?.absoluteString
                )
                handleDetectedMedia(media, autoMode: false)
                return
            }

            if mimeType == "text/html" || mimeType == "application/xhtml+xml" {
                try? FileManager.default.removeItem(at: tempURL)
                downloadStatus = nil
                await downloader.resolveAndDownload(
                    inputURLString: url.absoluteString,
                    title: browser.pageTitle,
                    headers: headers,
                    maxDurationMinutes: settings.maxCacheDurationMinutes
                )
                return
            }

            let resolvedFileName = Self.resolvedMediaFileName(
                suggestedName: response.suggestedFilename,
                sourceURL: url,
                mimeType: mimeType
            )

            mediaManager.importTemporaryFile(from: tempURL, preferredFileName: resolvedFileName)
            downloadStatus = "Saved: \(resolvedFileName)"
        } catch {
            downloadStatus = "Download failed."
            mediaManager.errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    private static func isDirectDownloadExtension(_ ext: String) -> Bool {
        MediaManager.supportedExtensions.contains(ext)
            || WebViewWrapper.Coordinator.downloadableExtensions.contains(ext)
    }

    fileprivate static func resolvedMediaFileName(
        suggestedName: String?,
        sourceURL: URL?,
        mimeType: String
    ) -> String {
        let rawCandidate: String
        if let suggestedName, !suggestedName.isEmpty, suggestedName != "Unknown" {
            rawCandidate = suggestedName
        } else if let sourceURL, !sourceURL.lastPathComponent.isEmpty, sourceURL.lastPathComponent != "/" {
            rawCandidate = sourceURL.lastPathComponent
        } else {
            rawCandidate = "media_\(Int(Date().timeIntervalSince1970))"
        }

        let nsCandidate = rawCandidate as NSString
        let currentExt = nsCandidate.pathExtension.lowercased()
        if MediaManager.supportedExtensions.contains(currentExt) ||
            WebViewWrapper.Coordinator.downloadableExtensions.contains(currentExt) {
            return rawCandidate
        }

        if let inferredExt = extensionForMIMEType(mimeType) {
            let base = nsCandidate.deletingPathExtension
            let cleanBase = base.isEmpty ? rawCandidate : base
            return "\(cleanBase).\(inferredExt)"
        }

        return rawCandidate
    }

    private static func extensionForMIMEType(_ mimeType: String) -> String? {
        switch mimeType {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/x-caf": return "caf"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "text/plain": return "txt"
        case "application/zip": return "zip"
        case "application/json": return "json"
        default: return nil
        }
    }
}

private struct BrowserTabsSheet: View {
    @Environment(BrowserStore.self) private var browserStore
    @Environment(\.dismiss) private var dismiss

    let onSelectTab: (UUID) -> Void
    let onAddTab: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(browserStore.tabs) { tab in
                    Button {
                        onSelectTab(tab.id)
                    } label: {
                        HStack(spacing: 10) {
                            if tab.isPrivate {
                                Image(systemName: "eye.slash.fill")
                                    .foregroundStyle(.purple)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(tab.urlString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if tab.id == browserStore.activeTabID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            browserStore.closeTab(tab.id)
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        onAddTab(true)
                    } label: {
                        Label("Private Tab", systemImage: "eye.slash")
                    }
                    Button {
                        onAddTab(false)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}

private struct BookmarksAndHistorySheet: View {
    @Environment(BrowserStore.self) private var browserStore
    @Environment(\.dismiss) private var dismiss

    let onOpenURL: (String) -> Void

    @State private var showAddBookmark = false
    @State private var editingBookmark: BookmarkItem?
    @State private var siteTitle = ""
    @State private var siteURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Bookmarks") {
                    if browserStore.bookmarks.isEmpty {
                        Text("No bookmarks yet. Tap + to add a website or tap the bookmark icon while browsing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(browserStore.bookmarks) { bm in
                            Button {
                                onOpenURL(bm.urlString)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bm.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(bm.urlString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .contextMenu {
                                Button {
                                    editingBookmark = bm
                                    siteTitle = bm.title
                                    siteURL = bm.urlString
                                } label: {
                                    Label("Modify Website", systemImage: "pencil")
                                }
                            }
                        }
                        .onDelete { offsets in
                            browserStore.deleteBookmarks(at: offsets)
                        }
                    }
                }

                Section("History") {
                    if browserStore.history.isEmpty {
                        Text("No browsing history.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(browserStore.history) { entry in
                            Button {
                                onOpenURL(entry.urlString)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .lineLimit(1)
                                    Text(entry.urlString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks & History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !browserStore.history.isEmpty {
                        Button("Clear History") {
                            browserStore.clearHistory()
                        }
                    }
                    Button {
                        siteTitle = ""
                        siteURL = ""
                        showAddBookmark = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Website", isPresented: $showAddBookmark) {
                TextField("Website title", text: $siteTitle)
                TextField("Website address (https://...)", text: $siteURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    browserStore.addOrUpdateBookmark(title: siteTitle, urlString: siteURL)
                }
            }
            .alert(
                "Modify Website",
                isPresented: Binding(
                    get: { editingBookmark != nil },
                    set: { if !$0 { editingBookmark = nil } }
                )
            ) {
                TextField("Website title", text: $siteTitle)
                TextField("Website address", text: $siteURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { editingBookmark = nil }
                Button("Save") {
                    if let bm = editingBookmark {
                        browserStore.addOrUpdateBookmark(id: bm.id, title: siteTitle, urlString: siteURL)
                    }
                    editingBookmark = nil
                }
            }
        }
    }
}
