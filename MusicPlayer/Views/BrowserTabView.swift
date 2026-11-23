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
        detectedStreams.first(where: { $0.qualityLabel != nil && !$0.isAudio })
            ?? detectedStreams.last(where: { $0.isActivelyPlaying })
            ?? detectedStreams.last
    }

    func addDetectedStream(_ media: DetectedBrowserMedia) {
        if let idx = detectedStreams.firstIndex(where: { $0.url == media.url }) {
            let existing = detectedStreams[idx]
            let mergedActive = existing.isActivelyPlaying || media.isActivelyPlaying
            let mergedDur = media.durationSeconds ?? existing.durationSeconds
            let mergedTitle = (media.title?.isEmpty == false ? media.title : existing.title)
            detectedStreams[idx] = DetectedBrowserMedia(
                url: media.url,
                pairedAudioURL: media.pairedAudioURL ?? existing.pairedAudioURL,
                isHLS: media.isHLS || existing.isHLS,
                isAudio: media.isAudio || existing.isAudio,
                title: mergedTitle,
                author: media.author ?? existing.author,
                qualityLabel: media.qualityLabel ?? existing.qualityLabel,
                referer: media.referer ?? existing.referer,
                customHeaders: media.customHeaders ?? existing.customHeaders,
                durationSeconds: mergedDur,
                isActivelyPlaying: mergedActive
            )
            return
        }
        detectedStreams.append(media)
    }

    func mergeResolvedYouTubeStreams(_ resolved: [DetectedBrowserMedia]) {
        guard !resolved.isEmpty else { return }
        detectedStreams.removeAll { item in
            let host = item.url.host?.lowercased() ?? ""
            return host.contains("googlevideo.com") && item.qualityLabel == nil
        }
        for stream in resolved {
            addDetectedStream(stream)
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

    func pausePageMedia() {
        webView?.evaluateJavaScript(
            "window.__mpAllowWebVideoID = null; window.__mpPauseWebVideo = true; document.querySelectorAll('video,audio').forEach(function(m){try{m.muted=true;m.pause();}catch(e){}});"
        )
    }

    func resumePageMediaControl(startPlayback: Bool = false, allowVideoID: String? = nil) {
        let allowPart: String
        if let allowVideoID, !allowVideoID.isEmpty {
            let escaped = allowVideoID.replacingOccurrences(of: "'", with: "\\'")
            allowPart = "window.__mpAllowWebVideoID = '\(escaped)';"
        } else {
            allowPart = "window.__mpAllowWebVideoID = null;"
        }
        let playPart = startPlayback
            ? "document.querySelectorAll('video').forEach(function(m){try{m.muted=false;m.play();}catch(e){}});"
            : "document.querySelectorAll('video,audio').forEach(function(m){try{m.muted=false;}catch(e){}});"
        webView?.evaluateJavaScript("\(allowPart) window.__mpPauseWebVideo = false; \(playPart)")
    }
}

struct WebViewWrapper: UIViewRepresentable {
    let url: URL
    let tabID: UUID
    let isPrivate: Bool
    let darkModeEnabled: Bool
    let adBlockEnabled: Bool
    let interceptYouTubePlayback: Bool
    var controller: BrowserController? = nil
    var contentBlocker: ContentBlockerManager? = nil
    var onURLChange: (URL, String?) -> Void = { _, _ in }
    var onMediaDetected: (DetectedBrowserMedia) -> Void = { _ in }
    var onYouTubeVideoChanged: (String, URL, String?) -> Void = { _, _, _ in }
    var onYouTubePlayRequested: (String, URL, String?) -> Void = { _, _, _ in }
    var onYouTubePlayerJSON: (String, Data, URL?, String?) -> Void = { _, _, _, _ in }
    var onBlobCaptured: (Data, String, String) -> Void = { _, _, _ in }
    var onWKDownloadImported: (URL, String) -> Void = { _, _ in }
    var onWKDownloadFailed: (Error) -> Void = { _ in }
    var onDownloadTriggered: (URL) -> Void = { _ in }

    private static let documentStartMediaJS = """
    (function() {
        if (window.__musicPlayerHookInstalled) return;
        window.__musicPlayerHookInstalled = true;
        var seen = new Map();
        var blobMap = new Map();
        window.__mpBlobMap = blobMap;

        var adHostPattern = /(doubleclick\\.net|googlesyndication|googleadservices|adnxs|exoclick|popads|popcash|propellerads|juicyads|trafficjunky|adsterra|taboola|outbrain)/i;

        function isSegmentChunk(lower) {
            if (/\\.m3u8(\\?|#|$|&)/i.test(lower)) return false;
            if (/\\/(seg|chunk|frag|part)[-_]?\\d+\\.(ts|m4s|mp4)(\\?|$)/i.test(lower)) return true;
            if (/\\.ts(\\?|$)/i.test(lower) && (seenHasHLS())) return true;
            if (/\\.m4s(\\?|$)/i.test(lower)) return true;
            return false;
        }

        function seenHasHLS() {
            var found = false;
            seen.forEach(function(kind) { if (kind === 'hls') found = true; });
            return found;
        }

        function normalizeMediaURL(src) {
            if (!src || /^blob:/i.test(src)) return src;
            try {
                var u = new URL(src, window.location.href);
                if (u.hostname.indexOf('googlevideo.com') !== -1) {
                    if (u.searchParams.get('ump') === '1') return null;
                    u.searchParams.delete('range');
                    u.searchParams.delete('rn');
                    u.searchParams.delete('rbuf');
                    u.searchParams.delete('ump');
                    u.searchParams.delete('srfvp');
                }
                return u.toString();
            } catch (e) {
                return src;
            }
        }

        function isYTHost() {
            try {
                var h = window.location.hostname.toLowerCase();
                return h === 'youtu.be' || h === 'youtube.com' || h.endsWith('.youtube.com');
            } catch (e) { return false; }
        }

        function getYTVisitorData() {
            try {
                if (window.ytcfg && typeof window.ytcfg.get === 'function') {
                    return window.ytcfg.get('VISITOR_DATA') || '';
                }
                if (window.ytcfg && window.ytcfg.data_ && window.ytcfg.data_.VISITOR_DATA) {
                    return window.ytcfg.data_.VISITOR_DATA || '';
                }
            } catch (e) {}
            return '';
        }

        function currentYTVideoId() {
            try {
                if (!isYTHost()) return null;
                var u = new URL(window.location.href);
                var v = u.searchParams.get('v');
                if (v) return v;
                var m = u.pathname.match(/\\/(shorts|embed|live)\\/([a-zA-Z0-9_-]{8,16})/);
                if (m) return m[2];
                return null;
            } catch (e) { return null; }
        }

        var lastYTVideoId = null;
        var lastYTPlayRequestAt = 0;
        var sentYTPayloads = new Set();

        function shouldBlockYTWebPlayback() {
            var vid = currentYTVideoId();
            if (!vid) return false;
            if (window.__mpAllowWebVideoID && window.__mpAllowWebVideoID === vid) return false;
            return !!(window.__mpPauseWebVideo || window.__mpInterceptYouTubePlayback);
        }

        function notifyYTPlayRequest(force) {
            try {
                var vid = currentYTVideoId();
                if (!vid) return;
                var now = Date.now();
                if (!force && now - lastYTPlayRequestAt < 800) return;
                lastYTPlayRequestAt = now;
                window.webkit.messageHandlers.ytDetected.postMessage({
                    type: 'playRequested',
                    videoId: vid,
                    pageURL: window.location.href,
                    visitorData: getYTVisitorData()
                });
            } catch (e) {}
        }

        function emitYTPayload(obj) {
            try {
                if (!obj || !obj.videoDetails || !obj.streamingData) return;
                var vid = obj.videoDetails.videoId || currentYTVideoId();
                if (!vid || sentYTPayloads.has(vid + '_' + !!obj.streamingData.hlsManifestUrl)) return;
                sentYTPayloads.add(vid + '_' + !!obj.streamingData.hlsManifestUrl);
                window.webkit.messageHandlers.ytDetected.postMessage({
                    type: 'playerJSON',
                    videoId: vid,
                    pageURL: window.location.href,
                    visitorData: getYTVisitorData(),
                    json: JSON.stringify({
                        videoDetails: obj.videoDetails,
                        streamingData: obj.streamingData,
                        playabilityStatus: obj.playabilityStatus || null
                    })
                });
            } catch (e) {}
        }

        function checkYouTubeState() {
            try {
                var vid = currentYTVideoId();
                if (!vid && lastYTVideoId !== null) {
                    lastYTVideoId = null;
                    lastYTPlayRequestAt = 0;
                    window.__mpPauseWebVideo = false;
                    window.__mpAllowWebVideoID = null;
                }
                if (vid && vid !== lastYTVideoId) {
                    lastYTVideoId = vid;
                    lastYTPlayRequestAt = 0;
                    window.__mpAllowWebVideoID = null;
                    seen.clear();
                    window.webkit.messageHandlers.ytDetected.postMessage({
                        type: 'videoChanged',
                        videoId: vid,
                        pageURL: window.location.href,
                        visitorData: getYTVisitorData()
                    });
                }
                if (vid) {
                    if (window.ytInitialPlayerResponse) emitYTPayload(window.ytInitialPlayerResponse);
                    var mp = document.getElementById('movie_player');
                    if (mp && typeof mp.getPlayerResponse === 'function') {
                        emitYTPayload(mp.getPlayerResponse());
                    }
                }
            } catch (e) {}
        }

        function classify(src, forcedKind) {
            if (!src) return null;
            if (/^blob:/i.test(src)) {
                return blobMap.has(src) ? (forcedKind || 'video') : null;
            }
            if (!/^https?:\\/\\//i.test(src)) return null;
            var lower = src.toLowerCase();
            if (adHostPattern.test(lower)) return null;
            if (isSegmentChunk(lower)) return null;
            if (forcedKind) return forcedKind;
            if (/\\.m3u8(\\?|#|$|&)/i.test(lower) || /\\/(hls|manifest)\\/.*m3u8/i.test(lower) || /type=m3u8/i.test(lower)) return 'hls';
            if (/\\.(mp3|m4a|wav|aac|flac|ogg|opus|wma|ape|ac3|dts|amr|alac)(\\?|#|$)/i.test(lower) || /mime=audio(%2f|\\/)?/i.test(lower)) return 'audio';
            if (/\\.(mp4|mov|m4v|mkv|avi|webm|flv|wmv|ts|m2ts|3gp|ogv|mpg|mpeg)(\\?|#|$)/i.test(lower) || /mime=video(%2f|\\/)?/i.test(lower)) return 'video';
            return null;
        }

        function report(rawSrc, forcedKind, dur, active) {
            var src = normalizeMediaURL(rawSrc);
            if (!src) return;
            if (isYTHost() && (/googlevideo\\.com/i.test(src) || /^blob:/i.test(src))) return;
            var kind = classify(src, forcedKind);
            if (!kind) return;
            var prev = seen.get(src);
            if (prev === kind && !active && !(dur > 0)) return;
            if (seen.has(src) && prev === kind + '|1' && !active) return;
            seen.set(src, kind + (active ? '|1' : ''));
            try {
                window.webkit.messageHandlers.mediaDetected.postMessage({
                    url: src,
                    kind: kind,
                    title: (window.top && window.top !== window ? '' : document.title) || document.title || '',
                    duration: (typeof dur === 'number' && isFinite(dur) && dur > 0) ? dur : 0,
                    active: !!active
                });
            } catch (e) {}
        }

        try {
            var origCreateObjectURL = URL.createObjectURL;
            URL.createObjectURL = function(obj) {
                var u = origCreateObjectURL.apply(URL, arguments);
                try {
                    if (obj && typeof Blob !== 'undefined' && obj instanceof Blob) {
                        var t = (obj.type || '').toLowerCase();
                        if (t.indexOf('video/') === 0 || t.indexOf('audio/') === 0 || obj.size > 262144) {
                            blobMap.set(u, obj);
                        }
                    }
                } catch (e) {}
                return u;
            };
        } catch (e) {}

        if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function(input) {
                var reqUrl = '';
                try {
                    reqUrl = typeof input === 'string' ? input : (input && input.url) || '';
                    if (reqUrl) report(new URL(reqUrl, window.location.href).toString(), null, 0, false);
                } catch (e) {}
                var p = origFetch.apply(this, arguments);
                if (p && typeof p.then === 'function') {
                    p.then(function(resp) {
                        try {
                            var ct = (resp.headers && resp.headers.get('content-type') || '').toLowerCase();
                            var finalUrl = resp.url || reqUrl;
                            if (!finalUrl) return;
                            var abs = new URL(finalUrl, window.location.href).toString();
                            if (abs.indexOf('/youtubei/v1/player') !== -1 && resp.clone) {
                                resp.clone().json().then(emitYTPayload).catch(function() {});
                            }
                            if (ct.indexOf('mpegurl') !== -1) report(abs, 'hls', 0, false);
                            else if (ct.indexOf('audio/') === 0) report(abs, 'audio', 0, false);
                            else if (ct.indexOf('video/') === 0 || ct.indexOf('matroska') !== -1) report(abs, 'video', 0, false);
                            else if ((ct.indexOf('text/plain') === 0 || ct.indexOf('octet-stream') !== -1) && resp.clone) {
                                var cl = parseInt((resp.headers && resp.headers.get('content-length')) || '0', 10);
                                if (!cl || cl < 2097152) {
                                    resp.clone().text().then(function(txt) {
                                        if (txt && txt.slice(0, 32).indexOf('#EXTM3U') !== -1) {
                                            report(abs, 'hls', 0, false);
                                        }
                                    }).catch(function() {});
                                }
                            }
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
                if (this.__mpReqUrl) report(this.__mpReqUrl, null, 0, false);
                if (!this.__mpLoadHooked) {
                    this.__mpLoadHooked = true;
                    this.addEventListener('loadend', function() {
                        try {
                            var ct = (this.getResponseHeader('Content-Type') || '').toLowerCase();
                            var finalUrl = this.responseURL || this.__mpReqUrl;
                            if (!finalUrl) return;
                            var abs = new URL(finalUrl, window.location.href).toString();
                            if (abs.indexOf('/youtubei/v1/player') !== -1 && typeof this.responseText === 'string') {
                                try { emitYTPayload(JSON.parse(this.responseText)); } catch (e) {}
                            }
                            if (ct.indexOf('mpegurl') !== -1) report(abs, 'hls', 0, false);
                            else if (ct.indexOf('audio/') === 0) report(abs, 'audio', 0, false);
                            else if (ct.indexOf('video/') === 0 || ct.indexOf('matroska') !== -1) report(abs, 'video', 0, false);
                            else if ((ct.indexOf('text/plain') === 0 || ct.indexOf('octet-stream') !== -1) &&
                                     (!this.responseType || this.responseType === 'text') &&
                                     typeof this.responseText === 'string' &&
                                     this.responseText.slice(0, 32).indexOf('#EXTM3U') !== -1) {
                                report(abs, 'hls', 0, false);
                            }
                        } catch (e) {}
                    });
                }
            } catch (e) {}
            return origOpen.apply(this, arguments);
        };

        try {
            var origAudio = window.Audio;
            window.Audio = function(src) {
                var a = new origAudio(src);
                if (src) {
                    try { report(new URL(src, window.location.href).toString(), 'audio', 0, true); } catch (e) {}
                }
                return a;
            };
            window.Audio.prototype = origAudio.prototype;
        } catch (e) {}

        function inspectMediaElement(el, isActivePlay) {
            if (!el) return;
            try {
                var src = el.currentSrc || el.src || (el.getAttribute && (el.getAttribute('src') || el.getAttribute('data-src')));
                if (src) {
                    if (!(el.muted && el.loop && el.duration > 0 && el.duration < 3 && !isActivePlay)) {
                        var abs = /^blob:/i.test(src) ? src : new URL(src, window.location.href).toString();
                        var isAudioTag = (el.tagName && el.tagName.toLowerCase() === 'audio') ||
                            (el.parentElement && el.parentElement.tagName && el.parentElement.tagName.toLowerCase() === 'audio');
                        var kind = /\\.m3u8/i.test(abs) ? 'hls' : (isAudioTag ? 'audio' : 'video');
                        report(abs, kind, el.duration, !!isActivePlay);
                    }
                }
                if (shouldBlockYTWebPlayback()) {
                    try { el.autoplay = false; el.removeAttribute('autoplay'); } catch (err) {}
                    if (typeof el.pause === 'function' && !el.paused) {
                        el.muted = true;
                        el.pause();
                    }
                }
            } catch (e) {}
        }

        try {
            var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            if (desc && desc.set) {
                Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                    configurable: true,
                    enumerable: desc.enumerable,
                    get: desc.get,
                    set: function(val) {
                        desc.set.call(this, val);
                        inspectMediaElement(this, !this.paused);
                    }
                });
            }
        } catch (e) {}

        var origPlay = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function() {
            inspectMediaElement(this, true);
            if (shouldBlockYTWebPlayback()) {
                try {
                    this.autoplay = false;
                    this.removeAttribute('autoplay');
                    this.muted = true;
                    this.pause();
                } catch (e) {}
                notifyYTPlayRequest(false);
                return Promise.resolve();
            }
            return origPlay.apply(this, arguments);
        };

        var origLoad = HTMLMediaElement.prototype.load;
        HTMLMediaElement.prototype.load = function() {
            inspectMediaElement(this, !this.paused);
            return origLoad.apply(this, arguments);
        };

        document.addEventListener('loadedmetadata', function(e) { inspectMediaElement(e.target, false); }, true);
        document.addEventListener('durationchange', function(e) { inspectMediaElement(e.target, false); }, true);
        document.addEventListener('canplay', function(e) { inspectMediaElement(e.target, !e.target.paused); }, true);
        document.addEventListener('play', function(e) {
            inspectMediaElement(e.target, true);
            if (shouldBlockYTWebPlayback()) {
                try { e.target.muted = true; e.target.pause(); } catch (err) {}
                notifyYTPlayRequest(false);
            }
        }, true);
        document.addEventListener('playing', function(e) {
            inspectMediaElement(e.target, true);
            if (shouldBlockYTWebPlayback()) {
                try { e.target.muted = true; e.target.pause(); } catch (err) {}
                notifyYTPlayRequest(false);
            }
        }, true);

        document.addEventListener('click', function(e) {
            try {
                if (!shouldBlockYTWebPlayback()) return;
                var t = e.target;
                if (!t || !t.closest) return;
                if (t.closest('a[href]')) return;
                if (t.closest('#movie_player, ytm-player, .html5-video-player, video, .ytp-cued-thumbnail-overlay, .ytp-large-play-button, .ytp-play-button, .player-controls-content, .player-control-play-pause-icon, .ytm-custom-control-play-button, button[aria-label*="Play" i]')) {
                    e.preventDefault();
                    e.stopPropagation();
                    document.querySelectorAll('video,audio').forEach(function(m) {
                        try { m.muted = true; m.pause(); } catch (err) {}
                    });
                    notifyYTPlayRequest(true);
                }
            } catch (err) {}
        }, true);

        function scanNodeTree(root) {
            if (!root || !root.querySelectorAll) return;
            root.querySelectorAll('video, video source, audio, audio source').forEach(function(el) {
                inspectMediaElement(el, !el.paused);
            });
            root.querySelectorAll('*').forEach(function(el) {
                if (el.shadowRoot) scanNodeTree(el.shadowRoot);
            });
        }

        function scanPerformance() {
            try {
                if (!window.performance || !performance.getEntriesByType) return;
                performance.getEntriesByType('resource').forEach(function(entry) {
                    if (!entry || !entry.name) return;
                    if (entry.initiatorType === 'video' || entry.initiatorType === 'audio') {
                        report(entry.name, entry.initiatorType, 0, false);
                    } else {
                        report(entry.name, null, 0, false);
                    }
                });
            } catch (e) {}
        }

        try {
            if (window.PerformanceObserver) {
                var po = new PerformanceObserver(function(list) {
                    list.getEntries().forEach(function(entry) {
                        if (!entry || !entry.name) return;
                        if (entry.initiatorType === 'video' || entry.initiatorType === 'audio') {
                            report(entry.name, entry.initiatorType, 0, false);
                        } else {
                            report(entry.name, null, 0, false);
                        }
                    });
                });
                po.observe({ entryTypes: ['resource'] });
            }
        } catch (e) {}

        function scan() {
            checkYouTubeState();
            scanNodeTree(document);
            scanPerformance();
        }

        function hookHistoryMethod(name) {
            try {
                var orig = history[name];
                if (typeof orig === 'function') {
                    history[name] = function() {
                        var res = orig.apply(this, arguments);
                        setTimeout(scan, 0);
                        return res;
                    };
                }
            } catch (e) {}
        }
        hookHistoryMethod('pushState');
        hookHistoryMethod('replaceState');

        window.addEventListener('yt-navigate-finish', function() {
            setTimeout(scan, 50);
        });
        window.addEventListener('popstate', function() {
            setTimeout(scan, 50);
        });

        window.addEventListener('DOMContentLoaded', function() {
            scan();
            if (document.documentElement) {
                new MutationObserver(function() { scanNodeTree(document); }).observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src', 'data-src']
                });
            }
            setInterval(scan, 1000);
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
            onYouTubeVideoChanged: onYouTubeVideoChanged,
            onYouTubePlayRequested: onYouTubePlayRequested,
            onYouTubePlayerJSON: onYouTubePlayerJSON,
            onBlobCaptured: onBlobCaptured,
            onWKDownloadImported: onWKDownloadImported,
            onWKDownloadFailed: onWKDownloadFailed,
            onDownloadTriggered: onDownloadTriggered
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "mediaDetected")
        userController.add(context.coordinator, name: "ytDetected")
        userController.add(context.coordinator, name: "blobCaptured")
        Self.installUserScripts(
            on: userController,
            interceptYouTubePlayback: interceptYouTubePlayback,
            adBlockEnabled: adBlockEnabled
        )

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        // Always allow inline HTML5 playback so WebKit never steals the screen with Safari's fullscreen AVPlayerViewController;
        // when auto-caching or Inline Player is off, we pause webpage media cleanly and open NowPlayingView instead.
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = WebMediaDownloader.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.controller = controller
        context.coordinator.contentBlocker = contentBlocker
        context.coordinator.darkModeEnabled = darkModeEnabled
        context.coordinator.lastBlockingState = adBlockEnabled
        context.coordinator.lastInterceptYouTubePlayback = interceptYouTubePlayback
        context.coordinator.lastRequestedURL = url
        context.coordinator.lastTabID = tabID
        context.coordinator.observe(webView)
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

    private static func installUserScripts(
        on userController: WKUserContentController,
        interceptYouTubePlayback: Bool,
        adBlockEnabled: Bool
    ) {
        userController.removeAllUserScripts()
        let configJS = "window.__mpInterceptYouTubePlayback = \(interceptYouTubePlayback ? "true" : "false");"
        userController.addUserScript(
            WKUserScript(source: configJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        userController.addUserScript(
            WKUserScript(source: documentStartMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        if adBlockEnabled {
            userController.addUserScript(
                WKUserScript(source: ContentBlockerManager.cosmeticAdBlockScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.contentBlocker = contentBlocker
        context.coordinator.onURLChange = onURLChange
        context.coordinator.onMediaDetected = onMediaDetected
        context.coordinator.onYouTubeVideoChanged = onYouTubeVideoChanged
        context.coordinator.onYouTubePlayRequested = onYouTubePlayRequested
        context.coordinator.onYouTubePlayerJSON = onYouTubePlayerJSON
        context.coordinator.onBlobCaptured = onBlobCaptured
        context.coordinator.onWKDownloadImported = onWKDownloadImported
        context.coordinator.onWKDownloadFailed = onWKDownloadFailed
        context.coordinator.onDownloadTriggered = onDownloadTriggered

        if controller?.webView !== webView {
            controller?.webView = webView
        }

        if context.coordinator.lastInterceptYouTubePlayback != interceptYouTubePlayback {
            context.coordinator.lastInterceptYouTubePlayback = interceptYouTubePlayback
            Self.installUserScripts(
                on: webView.configuration.userContentController,
                interceptYouTubePlayback: interceptYouTubePlayback,
                adBlockEnabled: adBlockEnabled
            )
            let jsFlag = interceptYouTubePlayback ? "true" : "false"
            let pauseIfBlocked = interceptYouTubePlayback
                ? "document.querySelectorAll('video,audio').forEach(function(m){try{m.muted=true;m.pause();}catch(e){}});"
                : ""
            webView.evaluateJavaScript("window.__mpInterceptYouTubePlayback = \(jsFlag); \(pauseIfBlocked)")
        }

        if let contentBlocker, context.coordinator.lastBlockingState != adBlockEnabled {
            context.coordinator.lastBlockingState = adBlockEnabled
            contentBlocker.isBlockingEnabled = adBlockEnabled
            Self.installUserScripts(
                on: webView.configuration.userContentController,
                interceptYouTubePlayback: interceptYouTubePlayback,
                adBlockEnabled: adBlockEnabled
            )
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

        if context.coordinator.lastTabID != tabID || context.coordinator.lastRequestedURL != url {
            context.coordinator.lastTabID = tabID
            context.coordinator.lastRequestedURL = url
            controller?.clearDetectedStreams()
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        static let directDocumentExtensions: Set<String> = [
            "pdf", "zip", "cbz", "png", "jpg", "jpeg", "webp", "gif", "txt", "md", "rtf"
        ]

        var controller: BrowserController?
        var contentBlocker: ContentBlockerManager?
        var onURLChange: (URL, String?) -> Void
        var onMediaDetected: (DetectedBrowserMedia) -> Void
        var onYouTubeVideoChanged: (String, URL, String?) -> Void
        var onYouTubePlayRequested: (String, URL, String?) -> Void
        var onYouTubePlayerJSON: (String, Data, URL?, String?) -> Void
        var onBlobCaptured: (Data, String, String) -> Void
        var onWKDownloadImported: (URL, String) -> Void
        var onWKDownloadFailed: (Error) -> Void
        var onDownloadTriggered: (URL) -> Void
        var lastRequestedURL: URL?
        var lastTabID: UUID?
        var lastBlockingState: Bool?
        var lastInterceptYouTubePlayback = true
        var darkModeEnabled = false

        private var observations: [NSKeyValueObservation] = []
        private var activeDownloads: [ObjectIdentifier: (tempURL: URL, fileName: String)] = [:]

        init(
            controller: BrowserController?,
            contentBlocker: ContentBlockerManager?,
            onURLChange: @escaping (URL, String?) -> Void,
            onMediaDetected: @escaping (DetectedBrowserMedia) -> Void,
            onYouTubeVideoChanged: @escaping (String, URL, String?) -> Void,
            onYouTubePlayRequested: @escaping (String, URL, String?) -> Void,
            onYouTubePlayerJSON: @escaping (String, Data, URL?, String?) -> Void,
            onBlobCaptured: @escaping (Data, String, String) -> Void,
            onWKDownloadImported: @escaping (URL, String) -> Void,
            onWKDownloadFailed: @escaping (Error) -> Void,
            onDownloadTriggered: @escaping (URL) -> Void
        ) {
            self.controller = controller
            self.contentBlocker = contentBlocker
            self.onURLChange = onURLChange
            self.onMediaDetected = onMediaDetected
            self.onYouTubeVideoChanged = onYouTubeVideoChanged
            self.onYouTubePlayRequested = onYouTubePlayRequested
            self.onYouTubePlayerJSON = onYouTubePlayerJSON
            self.onBlobCaptured = onBlobCaptured
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
                        self?.lastRequestedURL = current
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
                if let navURL = webView.url {
                    self.lastRequestedURL = navURL
                }
                self.controller?.clearDetectedStreams()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let jsFlag = lastInterceptYouTubePlayback ? "true" : "false"
            webView.evaluateJavaScript("window.__mpInterceptYouTubePlayback = \(jsFlag);")
            if darkModeEnabled {
                webView.evaluateJavaScript(WebViewWrapper.darkModeCSSScript)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ytDetected",
               let dict = message.body as? [String: Any],
               let msgType = dict["type"] as? String {
                let videoID = (dict["videoId"] as? String) ?? ""
                let pageURLStr = (dict["pageURL"] as? String) ?? ""
                let pageURL = URL(string: pageURLStr)
                let visitorData = dict["visitorData"] as? String
                if msgType == "videoChanged", let pageURL, !videoID.isEmpty {
                    DispatchQueue.main.async {
                        self.onYouTubeVideoChanged(videoID, pageURL, visitorData)
                    }
                } else if msgType == "playRequested", let pageURL, !videoID.isEmpty {
                    DispatchQueue.main.async {
                        self.onYouTubePlayRequested(videoID, pageURL, visitorData)
                    }
                } else if msgType == "playerJSON",
                          let jsonStr = dict["json"] as? String,
                          let data = jsonStr.data(using: .utf8),
                          !videoID.isEmpty {
                    DispatchQueue.main.async {
                        self.onYouTubePlayerJSON(videoID, data, pageURL, visitorData)
                    }
                }
                return
            }

            if message.name == "blobCaptured",
               let dict = message.body as? [String: Any],
               let base64 = dict["data"] as? String,
               let data = Data(base64Encoded: base64) {
                let fileName = (dict["name"] as? String) ?? "WebMedia"
                let mime = (dict["mime"] as? String) ?? "video/mp4"
                DispatchQueue.main.async {
                    self.onBlobCaptured(data, fileName, mime)
                }
                return
            }

            guard message.name == "mediaDetected",
                  let dict = message.body as? [String: Any],
                  let urlString = dict["url"] as? String,
                  let url = URL(string: urlString) else {
                return
            }

            let kind = dict["kind"] as? String ?? "video"
            let title = dict["title"] as? String
            let rawDur = dict["duration"] as? Double
            let durationSeconds = (rawDur != nil && rawDur!.isFinite && rawDur! > 0) ? rawDur : nil
            let isActivelyPlaying = (dict["active"] as? Bool) ?? false
            let referer = controller?.currentURL?.absoluteString

            DispatchQueue.main.async {
                let media = DetectedBrowserMedia(
                    url: url,
                    isHLS: kind == "hls",
                    isAudio: kind == "audio",
                    title: title,
                    referer: referer,
                    durationSeconds: durationSeconds,
                    isActivelyPlaying: isActivelyPlaying
                )
                let wasKnown = self.controller?.detectedStreams.contains(where: { $0.url == media.url }) ?? false
                self.controller?.addDetectedStream(media)
                if !wasKnown || isActivelyPlaying {
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
            if isMainOrBlank, let targetURL = navigationAction.request.url {
                let ext = targetURL.pathExtension.lowercased()
                if Self.directDocumentExtensions.contains(ext) {
                    DispatchQueue.main.async {
                        self.onDownloadTriggered(targetURL)
                    }
                    decisionHandler(.cancel)
                    return
                }
                if MediaItem.allSupportedExtensions.contains(ext) || ext == "m3u8" {
                    let isHLS = ext == "m3u8"
                    let isAudio = MediaItem.allAudioExtensions.contains(ext)
                    let media = DetectedBrowserMedia(
                        url: targetURL,
                        isHLS: isHLS,
                        isAudio: isAudio,
                        title: controller?.pageTitle,
                        referer: controller?.currentURL?.absoluteString,
                        isActivelyPlaying: true
                    )
                    DispatchQueue.main.async {
                        self.controller?.addDetectedStream(media)
                        self.onMediaDetected(media)
                    }
                    // Allow apple-native media to play inside WebView too if link-tapped; FFmpeg containers prompt/download
                    if MediaItem.ffmpegVideoExtensions.contains(ext) || MediaItem.ffmpegAudioExtensions.contains(ext) {
                        decisionHandler(.cancel)
                        return
                    }
                }
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
            if let respURL = navigationResponse.response.url {
                if mime.contains("mpegurl") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
                    let isHLS = mime.contains("mpegurl")
                    let isAudio = mime.hasPrefix("audio/")
                    let media = DetectedBrowserMedia(
                        url: respURL,
                        isHLS: isHLS,
                        isAudio: isAudio,
                        title: controller?.pageTitle,
                        referer: controller?.currentURL?.absoluteString,
                        isActivelyPlaying: true
                    )
                    DispatchQueue.main.async {
                        self.controller?.addDetectedStream(media)
                        self.onMediaDetected(media)
                    }
                }
            }
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
    @State private var loadedTabID: UUID?
    @State private var browser = BrowserController()
    @State private var contentBlocker = ContentBlockerManager()
    @State private var isDownloading = false
    @State private var downloadStatus: String?
    @State private var autoCachedURLs: Set<String> = []
    @State private var promptedURLsThisPage: Set<String> = []
    @State private var currentYouTubeVideoID: String?
    @State private var inFlightYouTubeResolveID: String?
    @State private var startedYouTubeCacheIDs: Set<String> = []
    @State private var autoStreamedYouTubeIDs: Set<String> = []
    @State private var cachedMediaByYouTubeID: [String: UUID] = [:]

    private var shouldInterceptYouTubePlayback: Bool {
        (settings.autoCacheDetectedMedia && settings.autoOpenPlayerAfterCache) || !settings.inlineVideoPlayback
    }
    @State private var latestYouTubeVisitorData: String?
    @State private var activeCacheVideoID: String?
    @State private var isResolvingYouTubeCache = false
    @State private var cachingOverlayTitle: String?
    @State private var awaitingAutoOpenPlayer = false
    @State private var offlineReadyItem: MediaItem?
    @FocusState private var isAddressFieldFocused: Bool

    @State private var pendingMediaPrompt: DetectedBrowserMedia?
    @State private var hlsQualityRequest: DetectedBrowserMedia?
    @State private var hlsVariants: [HLSQualityVariant] = []
    @State private var loadingVariants = false
    @State private var browserMangaReaderTarget: ImageReaderTarget?

    @State private var showingTabsSheet = false
    @State private var showingBookmarksSheet = false
    @State private var showingStreamsSheet = false

    private var showCachingOverlay: Bool {
        isResolvingYouTubeCache || (cachingOverlayTitle != nil && !downloader.activeDownloads.isEmpty)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar

                if browser.isLoading {
                    ProgressView(value: max(browser.estimatedProgress, 0.05))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                if let offlineReadyItem {
                    offlineReadyBanner(offlineReadyItem)
                }

                if let status = downloadStatus {
                    statusBanner(status)
                }

                if !downloader.activeDownloads.isEmpty && !showCachingOverlay {
                    activeDownloadsStrip
                }

                if let detected = browser.detectedMedia, !showCachingOverlay {
                    detectedMediaBanner(detected)
                }

                ZStack {
                    WebViewWrapper(
                        url: activeURL,
                        tabID: browserStore.activeTab.id,
                        isPrivate: browserStore.activeTab.isPrivate,
                        darkModeEnabled: settings.webDarkModeEnabled,
                        adBlockEnabled: settings.adBlockEnabled,
                        interceptYouTubePlayback: shouldInterceptYouTubePlayback,
                        controller: browser,
                        contentBlocker: contentBlocker,
                        onURLChange: { newURL, newTitle in
                            activeURL = newURL
                            if !isAddressFieldFocused {
                                urlString = newURL.absoluteString
                            }
                            browserStore.updateActiveTab(urlString: newURL.absoluteString, title: newTitle)
                            if let vid = YouTubeStreamResolver.extractVideoID(from: newURL) {
                                if vid != currentYouTubeVideoID {
                                    handleYouTubeVideoNavigation(
                                        videoID: vid,
                                        url: newURL,
                                        visitorData: latestYouTubeVisitorData
                                    )
                                }
                            } else if currentYouTubeVideoID != nil, YouTubeStreamResolver.isYouTubeURL(newURL) {
                                clearActiveYouTubeWatchSession()
                            }
                        },
                        onMediaDetected: { media in
                            handleIncomingDetectedMedia(media)
                        },
                        onYouTubeVideoChanged: { videoID, pageURL, visitorData in
                            handleYouTubeVideoNavigation(videoID: videoID, url: pageURL, visitorData: visitorData)
                        },
                        onYouTubePlayRequested: { videoID, pageURL, visitorData in
                            handleYouTubePlayRequest(videoID: videoID, url: pageURL, visitorData: visitorData)
                        },
                        onYouTubePlayerJSON: { videoID, jsonData, pageURL, visitorData in
                            handleYouTubePlayerJSON(videoID: videoID, jsonData: jsonData, pageURL: pageURL, visitorData: visitorData)
                        },
                        onBlobCaptured: { data, fileName, mimeType in
                            downloader.saveBlobData(
                                data,
                                fileName: fileName,
                                mimeType: mimeType,
                                maxDurationMinutes: settings.maxCacheDurationMinutes
                            )
                        },
                        onWKDownloadImported: { tempURL, fileName in
                            if let imported = mediaManager.importTemporaryFile(from: tempURL, preferredFileName: fileName) {
                                let updated = mediaManager.applyDownloadedMetadataAndPlaylist(for: imported, title: nil, artist: nil)
                                offlineReadyItem = updated
                            }
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
                    .id(browserStore.activeTab.id.uuidString)

                    if showCachingOverlay {
                        Color.black.opacity(0.24)
                            .ignoresSafeArea()
                        cachingOverlayView(title: cachingOverlayTitle ?? "Loading Video...")
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
            }
            .onAppear {
                if loadedTabID != browserStore.activeTabID {
                    syncTabState()
                }
            }
            .onChange(of: browserStore.activeTabID) { _, _ in
                syncTabState()
            }
            .onChange(of: browserStore.navigationRequestNonce) { _, _ in
                syncTabState(forceReload: true)
            }
            .onChange(of: downloader.lastCompletedCacheEvent) { _, event in
                guard let event else { return }
                let cachedItem = event.item
                offlineReadyItem = cachedItem
                isResolvingYouTubeCache = false
                cachingOverlayTitle = nil
                if let vid = activeCacheVideoID ?? currentYouTubeVideoID {
                    cachedMediaByYouTubeID[vid] = cachedItem.id
                    mediaManager.setSourceVideoID(vid, for: cachedItem)
                }
                activeCacheVideoID = nil
                if awaitingAutoOpenPlayer && settings.autoOpenPlayerAfterCache {
                    awaitingAutoOpenPlayer = false
                    offlineReadyItem = nil
                    browser.pausePageMedia()
                    mediaManager.play(cachedItem)
                    showPlayerSheet = true
                }
            }
            .onChange(of: downloader.lastFailedCacheEvent) { _, event in
                guard event != nil else { return }
                if downloader.activeDownloads.isEmpty {
                    let failedVideoID = activeCacheVideoID ?? currentYouTubeVideoID
                    if let failedVideoID {
                        startedYouTubeCacheIDs.remove(failedVideoID)
                    }
                    isResolvingYouTubeCache = false
                    cachingOverlayTitle = nil
                    awaitingAutoOpenPlayer = false
                    activeCacheVideoID = nil
                    if shouldInterceptYouTubePlayback {
                        browser.pausePageMedia()
                    } else {
                        browser.resumePageMediaControl()
                    }
                }
            }
            .task(id: offlineReadyItem?.id) {
                guard offlineReadyItem != nil else { return }
                try? await Task.sleep(for: .seconds(8.0))
                if !Task.isCancelled {
                    offlineReadyItem = nil
                }
            }
            .task(id: downloadStatus) {
                guard downloadStatus != nil, !isDownloading else { return }
                try? await Task.sleep(for: .seconds(3.5))
                if !Task.isCancelled && !isDownloading {
                    downloadStatus = nil
                }
            }
            .navigationTitle(browserStore.activeTab.isPrivate ? "Private Tab" : (browser.pageTitle.isEmpty ? "Browser" : browser.pageTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if isModal {
                        Button("Done") { dismiss() }
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

                        Menu {
                            Button {
                                settings.autoAddDownloadsToPlaylist = true
                                settings.targetDownloadPlaylistIDString = ""
                            } label: {
                                Label(
                                    "Auto (\"Last Played\")",
                                    systemImage: (settings.autoAddDownloadsToPlaylist && settings.targetDownloadPlaylistIDString.isEmpty) ? "checkmark" : "arrow.down.circle"
                                )
                            }

                            ForEach(mediaManager.playlists) { pl in
                                Button {
                                    settings.autoAddDownloadsToPlaylist = true
                                    settings.targetDownloadPlaylistIDString = pl.id.uuidString
                                } label: {
                                    Label(
                                        pl.name,
                                        systemImage: (settings.autoAddDownloadsToPlaylist && settings.targetDownloadPlaylistID == pl.id) ? "checkmark" : "music.note.list"
                                    )
                                }
                            }

                            Divider()

                            Button {
                                settings.autoAddDownloadsToPlaylist = false
                            } label: {
                                Label(
                                    "Don't Add to Playlist",
                                    systemImage: !settings.autoAddDownloadsToPlaylist ? "checkmark" : "xmark.circle"
                                )
                            }
                        } label: {
                            Label("Save Downloads to Playlist", systemImage: "text.badge.plus")
                        }

                        Divider()

                        Button {
                            extractAndSavePageImages(openInReader: true)
                        } label: {
                            Label("Read Page in Manga Reader", systemImage: "book.pages")
                        }

                        Button {
                            extractAndSavePageImages(openInReader: false)
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
            .fullScreenCover(item: $browserMangaReaderTarget) { target in
                ImageReaderView(target: target)
            }
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
                    if !media.isAudio,
                       let audioTrack = browser.detectedStreams.first(where: { $0.isAudio }) {
                        Button("Cache Audio Only (.m4a)") {
                            pendingMediaPrompt = nil
                            handleDetectedMedia(audioTrack, autoMode: false)
                        }
                    }
                    Button("Stream Online (Cached)") {
                        pendingMediaPrompt = nil
                        streamDetectedMedia(media)
                    }
                    Button("Always Auto-Cache") {
                        settings.setAutoCacheDetectedMedia(true)
                        pendingMediaPrompt = nil
                        handleDetectedMedia(media, autoMode: true)
                    }
                    if let host = browser.currentURL?.host ?? media.url.host {
                        Button("Don't Remind for \(host)") {
                            settings.suppressCachingPrompts(forHost: host)
                            pendingMediaPrompt = nil
                        }
                    }
                }
                Button("Ignore", role: .cancel) {
                    pendingMediaPrompt = nil
                }
            } message: {
                let durText = pendingMediaPrompt?.formattedDuration.map { " (\($0))" } ?? ""
                Text("\(pendingMediaPrompt?.title ?? pendingMediaPrompt?.url.lastPathComponent ?? "")\(durText)\n\(pendingMediaPrompt?.url.absoluteString ?? "")")
            }
            .sheet(isPresented: $showingStreamsSheet) {
                NavigationStack {
                    List(browser.detectedStreams) { stream in
                        HStack(spacing: 12) {
                            Image(systemName: stream.isAudio ? "music.note" : "film")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(stream.kindLabel)
                                        .font(.subheadline.weight(.semibold))
                                    Text(stream.fileExtensionHint)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    if let dur = stream.formattedDuration {
                                        Text(dur)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let title = stream.title, !title.isEmpty {
                                    Text(title)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                Text(stream.url.absoluteString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if stream.url.scheme?.lowercased() != "blob" {
                                Button {
                                    showingStreamsSheet = false
                                    streamDetectedMedia(stream)
                                } label: {
                                    Image(systemName: "play.circle")
                                        .font(.title3)
                                }
                                .buttonStyle(.borderless)
                            }
                            Button {
                                showingStreamsSheet = false
                                handleDetectedMedia(stream, autoMode: false)
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
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
                                        let headers = await resolvedHeaders(for: media)
                                        downloader.startHLSDownload(
                                            from: media.url,
                                            selectedVariantURL: variant.variantURL,
                                            title: media.title ?? browser.pageTitle,
                                            artist: media.author,
                                            minimumBitrate: variant.peakBitrate > 0 ? variant.peakBitrate : nil,
                                            headers: headers,
                                            maxDurationMinutes: settings.maxCacheDurationMinutes
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

    private func syncTabState(forceReload: Bool = false) {
        let tab = browserStore.activeTab
        loadedTabID = tab.id
        promptedURLsThisPage.removeAll()
        autoStreamedYouTubeIDs.removeAll()
        currentYouTubeVideoID = nil
        inFlightYouTubeResolveID = nil
        isResolvingYouTubeCache = false
        cachingOverlayTitle = nil
        awaitingAutoOpenPlayer = false
        activeCacheVideoID = nil
        urlString = tab.urlString
        if let parsed = resolvedURL(from: tab.urlString) {
            if activeURL == parsed {
                if forceReload {
                    browser.load(parsed)
                }
            } else {
                activeURL = parsed
            }
        }
    }

    private func cachingOverlayView(title: String) -> some View {
        let currentDownload = downloader.activeDownloads.first
        return VStack(spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentDownload != nil ? "Caching Video for Offline..." : "Loading Video Stream...")
                        .font(.subheadline.weight(.semibold))
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if let dl = currentDownload {
                VStack(spacing: 6) {
                    ProgressView(value: dl.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    HStack {
                        Text(dl.isHLS ? "Downloading & muxing HD stream" : "Caching offline media")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(dl.progress * 100))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Will open player automatically when ready")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button("Play in Web") {
                    cancelBrowserCaching(resumeWebPlayback: true)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)

                Button("Cancel", role: .destructive) {
                    cancelBrowserCaching(resumeWebPlayback: false)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.horizontal, 20)
    }

    private func offlineReadyBanner(_ item: MediaItem) -> some View {
        Button {
            offlineReadyItem = nil
            mediaManager.play(item)
            showPlayerSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("👉 Tap to playback offline!")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(item.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Play")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.14))
        }
        .buttonStyle(.plain)
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
                HStack(spacing: 5) {
                    Text("\(media.kindLabel) Detected")
                        .font(.caption.weight(.semibold))
                    if let dur = media.formattedDuration {
                        Text("• \(dur)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
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
            Button(media.isHLS ? "Quality" : "Cache") {
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
        promptedURLsThisPage.removeAll()
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
        var headers: [String: String] = [
            "User-Agent": WebMediaDownloader.browserUserAgent
        ]
        if let referer, !referer.isEmpty {
            headers["Referer"] = referer
            if let refURL = URL(string: referer), let scheme = refURL.scheme, let host = refURL.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
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

    private func handleIncomingDetectedMedia(_ media: DetectedBrowserMedia) {
        let key = media.url.absoluteString
        let currentHost = browser.currentURL?.host ?? media.url.host

        if settings.autoCacheDetectedMedia {
            guard !autoCachedURLs.contains(key) else { return }
            if let dur = media.durationSeconds, dur > 0, dur < 3, !media.isActivelyPlaying {
                return
            }
            if !media.isAudio && media.isActivelyPlaying && settings.autoOpenPlayerAfterCache {
                awaitingAutoOpenPlayer = true
                cachingOverlayTitle = media.title ?? (browser.pageTitle.isEmpty ? "Caching Video..." : browser.pageTitle)
                browser.pausePageMedia()
            }
            autoCachedURLs.insert(key)
            handleDetectedMedia(media, autoMode: true)
            return
        }

        if settings.askBeforeCaching,
           !settings.isPromptSuppressed(forHost: currentHost),
           pendingMediaPrompt == nil,
           !promptedURLsThisPage.contains(key) {
            if let dur = media.durationSeconds, dur > 0, dur < 3, !media.isActivelyPlaying {
                return
            }
            promptedURLsThisPage.insert(key)
            pendingMediaPrompt = media
        }
    }

    private func extractAndSavePageImages(openInReader: Bool = false) {
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
                let savedFiles = await mediaManager.saveImagesFromWeb(urls, folderName: pageTitle, referer: referer)
                if openInReader && !savedFiles.isEmpty {
                    browserMangaReaderTarget = ImageReaderTarget(
                        title: pageTitle,
                        files: savedFiles,
                        initialIndex: 0
                    )
                }
            }
        }
    }

    private func captureBlobFromWebView(blobURLString: String, title: String?) {
        guard let webView = browser.webView else { return }
        let escaped = blobURLString.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var b = window.__mpBlobMap && window.__mpBlobMap.get('\(escaped)');
            if (!b || b.size > 33554432) return;
            var r = new FileReader();
            r.onloadend = function() {
                try {
                    var res = r.result || '';
                    var comma = res.indexOf(',');
                    if (comma !== -1) {
                        window.webkit.messageHandlers.blobCaptured.postMessage({
                            data: res.slice(comma + 1),
                            name: document.title || 'WebMedia',
                            mime: b.type || 'video/mp4'
                        });
                    }
                } catch (e) {}
            };
            r.readAsDataURL(b);
        })();
        """
        _ = title
        webView.evaluateJavaScript(js)
    }

    private func clearActiveYouTubeWatchSession() {
        currentYouTubeVideoID = nil
        inFlightYouTubeResolveID = nil
        isResolvingYouTubeCache = false
        cachingOverlayTitle = nil
        awaitingAutoOpenPlayer = false
        activeCacheVideoID = nil
        promptedURLsThisPage.removeAll()
        browser.clearDetectedStreams()
        browser.resumePageMediaControl()
    }

    private func cancelBrowserCaching(resumeWebPlayback: Bool) {
        let targetVideoID = activeCacheVideoID ?? currentYouTubeVideoID
        for dl in downloader.activeDownloads {
            downloader.cancelDownload(id: dl.id)
        }
        isResolvingYouTubeCache = false
        cachingOverlayTitle = nil
        awaitingAutoOpenPlayer = false
        activeCacheVideoID = nil
        inFlightYouTubeResolveID = nil
        if resumeWebPlayback {
            browser.resumePageMediaControl(startPlayback: true, allowVideoID: targetVideoID)
        } else {
            if let targetVideoID {
                startedYouTubeCacheIDs.remove(targetVideoID)
                autoStreamedYouTubeIDs.remove(targetVideoID)
            }
            if shouldInterceptYouTubePlayback {
                browser.pausePageMedia()
            } else {
                browser.resumePageMediaControl(startPlayback: false)
            }
        }
    }

    private func handleYouTubePlayRequest(videoID: String, url: URL, visitorData: String?) {
        if let visitorData, !visitorData.isEmpty {
            latestYouTubeVisitorData = visitorData
        }
        browser.pausePageMedia()

        if let cachedID = cachedMediaByYouTubeID[videoID],
           let existingItem = mediaManager.items.first(where: { $0.id == cachedID }) {
            isResolvingYouTubeCache = false
            cachingOverlayTitle = nil
            awaitingAutoOpenPlayer = false
            offlineReadyItem = existingItem
            mediaManager.play(existingItem)
            showPlayerSheet = true
            return
        }

        if activeCacheVideoID == videoID && (!downloader.activeDownloads.isEmpty || inFlightYouTubeResolveID == videoID) {
            awaitingAutoOpenPlayer = true
            if inFlightYouTubeResolveID == videoID {
                isResolvingYouTubeCache = true
            }
            if cachingOverlayTitle == nil {
                cachingOverlayTitle = browser.pageTitle.isEmpty ? "Loading YouTube video..." : browser.pageTitle
            }
            return
        }

        startedYouTubeCacheIDs.remove(videoID)
        autoStreamedYouTubeIDs.remove(videoID)
        handleYouTubeVideoNavigation(
            videoID: videoID,
            url: url,
            visitorData: visitorData,
            forcePlayerOpen: true
        )
    }

    private func handleYouTubeVideoNavigation(
        videoID: String,
        url: URL,
        visitorData: String?,
        forcePlayerOpen: Bool = false
    ) {
        if let visitorData, !visitorData.isEmpty {
            latestYouTubeVisitorData = visitorData
        }
        if currentYouTubeVideoID != videoID {
            currentYouTubeVideoID = videoID
            browser.clearDetectedStreams()
            promptedURLsThisPage.removeAll()
            startedYouTubeCacheIDs.remove(videoID)
            autoStreamedYouTubeIDs.remove(videoID)
        }

        if settings.autoCacheDetectedMedia,
           let cachedID = cachedMediaByYouTubeID[videoID],
           let existingItem = mediaManager.items.first(where: { $0.id == cachedID }) {
            isResolvingYouTubeCache = false
            cachingOverlayTitle = nil
            awaitingAutoOpenPlayer = false
            offlineReadyItem = existingItem
            if forcePlayerOpen || settings.autoOpenPlayerAfterCache {
                browser.pausePageMedia()
                mediaManager.play(existingItem)
                showPlayerSheet = true
            }
            return
        }

        if shouldInterceptYouTubePlayback || forcePlayerOpen {
            browser.pausePageMedia()
        }

        if settings.autoCacheDetectedMedia && !startedYouTubeCacheIDs.contains(videoID) {
            activeCacheVideoID = videoID
            if forcePlayerOpen || settings.autoOpenPlayerAfterCache {
                isResolvingYouTubeCache = true
                awaitingAutoOpenPlayer = true
                cachingOverlayTitle = browser.pageTitle.isEmpty ? "Loading YouTube video..." : browser.pageTitle
                browser.pausePageMedia()
            } else {
                awaitingAutoOpenPlayer = false
            }
        }

        guard inFlightYouTubeResolveID != videoID else { return }
        inFlightYouTubeResolveID = videoID

        Task {
            let reqHeaders = await buildRequestHeaders(for: url, referer: url.absoluteString)
            let result = await YouTubeStreamResolver.resolveStreams(
                for: url,
                cookiesHeader: reqHeaders["Cookie"],
                referer: url.absoluteString,
                visitorData: latestYouTubeVisitorData
            )

            if inFlightYouTubeResolveID == videoID {
                inFlightYouTubeResolveID = nil
            }
            guard currentYouTubeVideoID == videoID else { return }

            if let result, !result.streams.isEmpty {
                browser.mergeResolvedYouTubeStreams(result.streams)
                beginYouTubeCacheIfNeeded(videoID: videoID, result: result, forcePlayerOpen: forcePlayerOpen)
            } else if !startedYouTubeCacheIDs.contains(videoID) {
                isResolvingYouTubeCache = false
                cachingOverlayTitle = nil
                awaitingAutoOpenPlayer = false
                activeCacheVideoID = nil
                if shouldInterceptYouTubePlayback {
                    browser.pausePageMedia()
                } else {
                    browser.resumePageMediaControl()
                }
                if settings.autoCacheDetectedMedia || forcePlayerOpen {
                    downloadStatus = result?.errorReason ?? "Could not resolve downloadable stream"
                }
            }
        }
    }

    private func handleYouTubePlayerJSON(videoID: String, jsonData: Data, pageURL: URL?, visitorData: String?) {
        if let visitorData, !visitorData.isEmpty {
            latestYouTubeVisitorData = visitorData
        }
        let rawTargetURL = pageURL ?? activeURL
        let targetURL = YouTubeStreamResolver.extractVideoID(from: rawTargetURL) != nil
            ? rawTargetURL
            : (URL(string: "https://m.youtube.com/watch?v=\(videoID)") ?? rawTargetURL)
        if (currentYouTubeVideoID == nil || currentYouTubeVideoID == videoID)
            && inFlightYouTubeResolveID != videoID
            && !startedYouTubeCacheIDs.contains(videoID) {
            handleYouTubeVideoNavigation(videoID: videoID, url: targetURL, visitorData: visitorData)
        }

        Task {
            var baseHeaders = await buildRequestHeaders(for: targetURL, referer: targetURL.absoluteString)
            baseHeaders["Referer"] = pageURL?.absoluteString ?? "https://m.youtube.com/"
            guard let parsed = YouTubeStreamResolver.parsePlayerResponseJSON(
                jsonData,
                videoID: videoID,
                sourcePageURL: pageURL,
                headers: baseHeaders
            ), !parsed.streams.isEmpty else {
                return
            }

            let reachableStreams = await YouTubeStreamResolver.filterReachableStreams(parsed.streams)
            guard !reachableStreams.isEmpty else { return }
            let verifiedResult = YouTubeResolvedResult(
                videoID: parsed.videoID,
                title: parsed.title,
                author: parsed.author,
                durationSeconds: parsed.durationSeconds,
                streams: reachableStreams,
                errorReason: nil
            )
            if currentYouTubeVideoID == nil || currentYouTubeVideoID == videoID {
                currentYouTubeVideoID = videoID
                browser.mergeResolvedYouTubeStreams(verifiedResult.streams)
                if inFlightYouTubeResolveID != videoID && !startedYouTubeCacheIDs.contains(videoID) {
                    beginYouTubeCacheIfNeeded(videoID: videoID, result: verifiedResult)
                }
            }
        }
    }

    private func beginYouTubeCacheIfNeeded(
        videoID: String,
        result: YouTubeResolvedResult,
        forcePlayerOpen: Bool = false
    ) {
        let videoStreams = result.streams.filter { !$0.isAudio }
        let ordered = videoStreams.isEmpty ? result.streams : videoStreams
        guard let primary = ordered.first else { return }

        if settings.autoCacheDetectedMedia {
            guard !startedYouTubeCacheIDs.contains(videoID) else { return }
            if settings.maxCacheDurationMinutes > 0,
               let dur = result.durationSeconds, dur.isFinite, dur > 0,
               dur > Double(settings.maxCacheDurationMinutes * 60) {
                isResolvingYouTubeCache = false
                cachingOverlayTitle = nil
                awaitingAutoOpenPlayer = false
                activeCacheVideoID = nil
                if shouldInterceptYouTubePlayback {
                    browser.pausePageMedia()
                } else {
                    browser.resumePageMediaControl()
                }
                mediaManager.errorMessage = "Skipped \"\(result.title)\" (exceeds \(settings.maxCacheDurationMinutes) min limit)."
                return
            }

            startedYouTubeCacheIDs.insert(videoID)
            autoCachedURLs.insert(primary.url.absoluteString)
            activeCacheVideoID = videoID
            isResolvingYouTubeCache = false
            if forcePlayerOpen || awaitingAutoOpenPlayer || settings.autoOpenPlayerAfterCache {
                cachingOverlayTitle = result.title
                awaitingAutoOpenPlayer = true
                browser.pausePageMedia()
            } else {
                cachingOverlayTitle = nil
                awaitingAutoOpenPlayer = false
            }

            downloader.cacheMediaStream(
                primary,
                fallbackStreams: Array(ordered.dropFirst()),
                maxDurationMinutes: settings.maxCacheDurationMinutes
            )
            return
        }

        if !settings.inlineVideoPlayback || forcePlayerOpen {
            guard autoStreamedYouTubeIDs.insert(videoID).inserted else { return }
            isResolvingYouTubeCache = false
            cachingOverlayTitle = nil
            awaitingAutoOpenPlayer = false
            browser.pausePageMedia()
            streamDetectedMedia(primary)
            return
        }

        handleIncomingDetectedMedia(primary)
    }

    private func resolvedHeaders(for media: DetectedBrowserMedia) async -> [String: String] {
        if let custom = media.customHeaders {
            return custom
        }
        return await buildRequestHeaders(for: media.url, referer: media.referer)
    }

    private func streamDetectedMedia(_ media: DetectedBrowserMedia) {
        Task {
            let headers = await resolvedHeaders(for: media)
            mediaManager.playRemoteStream(
                url: media.url,
                title: media.title ?? (browser.pageTitle.isEmpty ? media.url.lastPathComponent : browser.pageTitle),
                headers: headers,
                isVideo: !media.isAudio
            )
            showPlayerSheet = true
        }
    }

    private func handleDetectedMedia(_ media: DetectedBrowserMedia, autoMode: Bool) {
        if media.url.scheme?.lowercased() == "blob" {
            captureBlobFromWebView(blobURLString: media.url.absoluteString, title: media.title ?? browser.pageTitle)
            return
        }

        if media.isHLS && !autoMode {
            hlsQualityRequest = media
            loadingVariants = true
            hlsVariants = []
            Task {
                let headers = await resolvedHeaders(for: media)
                hlsVariants = await downloader.fetchHLSVariants(
                    for: media.url,
                    headers: headers
                )
                loadingVariants = false
            }
            return
        }

        Task {
            let headers = await resolvedHeaders(for: media)
            let resolvedMedia = DetectedBrowserMedia(
                url: media.url,
                pairedAudioURL: media.pairedAudioURL,
                isHLS: media.isHLS,
                isAudio: media.isAudio,
                title: media.title ?? (browser.pageTitle.isEmpty ? nil : browser.pageTitle),
                author: media.author,
                qualityLabel: media.qualityLabel,
                referer: media.referer,
                customHeaders: headers,
                durationSeconds: media.durationSeconds,
                isActivelyPlaying: media.isActivelyPlaying
            )
            downloader.cacheMediaStream(
                resolvedMedia,
                maxDurationMinutes: settings.maxCacheDurationMinutes
            )
        }
    }

    @MainActor
    private func downloadFile(from url: URL) async {
        let headers = await buildRequestHeaders(for: url, referer: browser.currentURL?.absoluteString)

        if YouTubeStreamResolver.isYouTubeURL(url),
           YouTubeStreamResolver.extractVideoID(from: url) != nil {
            downloadStatus = "Resolving YouTube stream..."
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
        if MediaItem.allSupportedExtensions.contains(ext) {
            downloader.downloadDirectMedia(
                from: url,
                title: browser.pageTitle,
                headers: headers,
                maxDurationMinutes: settings.maxCacheDurationMinutes
            )
            return
        }

        if !Self.isDirectDownloadExtension(ext) {
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
        defer { isDownloading = false }

        do {
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (tempURL, response) = try await downloader.browserSession.download(for: request)

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

            if let saved = mediaManager.importTemporaryFile(from: tempURL, preferredFileName: resolvedFileName) {
                offlineReadyItem = saved
            }
            downloadStatus = "Saved: \(resolvedFileName)"
        } catch {
            downloadStatus = "Download failed."
            mediaManager.errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    private static func isDirectDownloadExtension(_ ext: String) -> Bool {
        MediaItem.allSupportedExtensions.contains(ext)
            || WebViewWrapper.Coordinator.directDocumentExtensions.contains(ext)
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
        if MediaItem.allSupportedExtensions.contains(currentExt) ||
            WebViewWrapper.Coordinator.directDocumentExtensions.contains(currentExt) {
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
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "video/x-matroska": return "mkv"
        case "video/webm", "audio/webm": return "webm"
        case "video/x-msvideo": return "avi"
        case "video/x-flv": return "flv"
        case "video/mp2t": return "ts"
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