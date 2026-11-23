import Foundation
import Observation
import WebKit

@Observable
final class ContentBlockerManager {
    private static let enabledDefaultsKey = "musicplayer.adblock.enabled"
    private let ruleListIdentifier = "MusicPlayerAdBlockRulesV5"

    var isBlockingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBlockingEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    private(set) var cachedRuleList: WKContentRuleList?

    static let cosmeticAdBlockScript = """
    (function() {
        if (window.__musicPlayerAdBlockInstalled) return;
        window.__musicPlayerAdBlockInstalled = true;
        window.open = function() { return null; };

        var adCSS = [
            '.ytp-ad-module', '.ytp-ad-overlay-container', '.ytp-ad-player-overlay',
            '.ytp-ad-image-overlay', '.ytp-ad-text-overlay', '.ytp-ad-message-container',
            'ytm-promoted-sparkles-web-renderer', 'ytm-promoted-sparkles-text-search-renderer',
            'ytm-promoted-video-renderer', 'ytm-ad-slot-renderer', 'ad-slot-renderer',
            'ytm-companion-slot-renderer', 'ytm-statement-banner-renderer', 'ytm-primetime-promo-renderer',
            'ytm-brand-video-singleton-renderer',
            'ytm-rich-item-renderer:has(ytm-ad-slot-renderer, ad-slot-renderer, ytm-promoted-sparkles-web-renderer, ytm-promoted-video-renderer)',
            'ytm-item-section-renderer:has(> ytm-ad-slot-renderer, > ad-slot-renderer, > ytm-promoted-sparkles-web-renderer)',
            'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer',
            'ytd-statement-banner-renderer', 'ytd-promoted-sparkles-web-renderer',
            'ytd-promoted-video-renderer', 'ytd-compact-promoted-video-renderer',
            'ytd-action-companion-ad-renderer', 'ytd-display-ad-renderer',
            '#masthead-ad', '#player-ads', '#offer-module',
            '.ad-showing .video-ads', '[id*="google_ads"]', '[class*="ad-banner"]',
            '[class*="popunder"]', 'ins.adsbygoogle'
        ].join(',') + ' { display: none !important; opacity: 0 !important; pointer-events: none !important; }';

        function ensureStyle() {
            var parent = document.head || document.documentElement;
            if (!parent) return;
            var style = document.getElementById('__musicplayer_adblock_css');
            if (!style) {
                style = document.createElement('style');
                style.id = '__musicplayer_adblock_css';
                style.textContent = adCSS;
                parent.appendChild(style);
            }
        }
        ensureStyle();

        function isYTHost() {
            try {
                var h = window.location.hostname.toLowerCase();
                return h === 'youtu.be' || h === 'youtube.com' || h.endsWith('.youtube.com');
            } catch (e) { return false; }
        }

        function pruneYTAdRenderers(node, depth) {
            if (!node || typeof node !== 'object' || depth > 10) return;
            if (Array.isArray(node)) {
                for (var i = node.length - 1; i >= 0; i--) {
                    var item = node[i];
                    if (item && typeof item === 'object' &&
                        (item.adSlotRenderer || item.promotedSparklesWebRenderer || item.promotedSparklesTextSearchRenderer)) {
                        node.splice(i, 1);
                    } else {
                        pruneYTAdRenderers(item, depth + 1);
                    }
                }
                return;
            }
            if (node.adPlacements) delete node.adPlacements;
            if (node.playerAds) delete node.playerAds;
            if (node.adSlots) delete node.adSlots;
            if (node.adBreakHeartbeatParams) delete node.adBreakHeartbeatParams;
            if (node.adSlotRenderer) delete node.adSlotRenderer;
            var keys = Object.keys(node);
            for (var k = 0; k < keys.length; k++) {
                var key = keys[k];
                if (key === 'contents' || key === 'items' || key === 'onResponseReceivedActions' ||
                    key === 'continuationItems' || key === 'richGridRenderer' ||
                    key === 'sectionListRenderer' || key === 'itemSectionRenderer' ||
                    key === 'richItemRenderer' || key === 'content') {
                    pruneYTAdRenderers(node[key], depth + 1);
                }
            }
        }

        function cleanYTPlayerObject(obj) {
            if (!obj || typeof obj !== 'object') return obj;
            try {
                delete obj.adPlacements;
                delete obj.playerAds;
                delete obj.adSlots;
                delete obj.adBreakHeartbeatParams;
            } catch (e) {}
            return obj;
        }

        if (isYTHost()) {
            try {
                if (!('ytInitialPlayerResponse' in window)) {
                    var _ytIPR;
                    Object.defineProperty(window, 'ytInitialPlayerResponse', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return _ytIPR; },
                        set: function(v) { _ytIPR = cleanYTPlayerObject(v); }
                    });
                } else if (window.ytInitialPlayerResponse) {
                    cleanYTPlayerObject(window.ytInitialPlayerResponse);
                }
            } catch (e) {}

            try {
                if (!('ytInitialData' in window)) {
                    var _ytData;
                    Object.defineProperty(window, 'ytInitialData', {
                        configurable: true,
                        enumerable: true,
                        get: function() { return _ytData; },
                        set: function(v) {
                            pruneYTAdRenderers(v, 0);
                            _ytData = v;
                        }
                    });
                } else if (window.ytInitialData) {
                    pruneYTAdRenderers(window.ytInitialData, 0);
                }
            } catch (e) {}

            if (window.fetch) {
                var prevFetch = window.fetch;
                window.fetch = function(input) {
                    var reqUrl = typeof input === 'string' ? input : (input && input.url) || '';
                    var p = prevFetch.apply(this, arguments);
                    if (typeof reqUrl === 'string' &&
                        /\\/youtubei\\/v1\\/(player|next|browse|search|get_watch)/.test(reqUrl) &&
                        p && typeof p.then === 'function') {
                        return p.then(function(resp) {
                            try {
                                if (!resp || !resp.ok || !resp.clone) return resp;
                                var ct = (resp.headers && resp.headers.get('content-type') || '').toLowerCase();
                                if (ct.indexOf('json') === -1) return resp;
                                return resp.clone().text().then(function(txt) {
                                    try {
                                        var json = JSON.parse(txt);
                                        cleanYTPlayerObject(json);
                                        if (reqUrl.indexOf('/youtubei/v1/player') === -1) {
                                            pruneYTAdRenderers(json, 0);
                                        }
                                        return new Response(JSON.stringify(json), {
                                            status: resp.status,
                                            statusText: resp.statusText,
                                            headers: { 'Content-Type': 'application/json; charset=UTF-8' }
                                        });
                                    } catch (e) {
                                        return resp;
                                    }
                                }).catch(function() { return resp; });
                            } catch (e) {
                                return resp;
                            }
                        });
                    }
                    return p;
                };
            }
        }

        function tickAdCleanup() {
            ensureStyle();
            var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-overlay-close-button');
            if (skip && typeof skip.click === 'function') skip.click();
            if (isYTHost()) {
                var adPlayer = document.querySelector('.ad-showing video, .ad-interrupting video');
                if (adPlayer) {
                    try {
                        adPlayer.muted = true;
                        if (isFinite(adPlayer.duration) && adPlayer.duration > 0) {
                            adPlayer.currentTime = adPlayer.duration;
                        }
                    } catch (e) {}
                }
            }
        }

        window.addEventListener('DOMContentLoaded', tickAdCleanup);
        setInterval(tickAdCleanup, 400);
    })();
    """

    private static let blockedAdDomains: [String] = [
        "*247realmedia.com", "*2mdn.net", "*acxiom-online.com", "*adadviser.net",
        "*ad.doubleclick.net", "*adblade.com", "*adcolony.com", "*adform.net", "*adition.com",
        "*adkengage.com", "*admagnet.net", "*admob.com", "*adnxs.com",
        "*adobetag.com", "*adroll.com", "*ads.youtube.com", "*adsafeprotected.com", "*adscale.de",
        "*adserver.yahoo.com", "*adskeeper.co.uk", "*adsonar.com", "*adsterra.com",
        "*advertising.com", "*amobee.com", "*appnexus.com", "*atdmt.com",
        "*audience2media.com", "*betrad.com", "*bidswitch.net", "*bidvertiser.com",
        "*bluekai.com", "*burstnet.com", "*casalemedia.com", "*chartbeat.com",
        "*chitika.net", "*clickadu.com", "*cm.g.doubleclick.net", "*collective-media.net", "*connextra.com",
        "*contextweb.com", "*criteo.com", "*criteo.net", "*crwdcntrl.net",
        "*demdex.net", "*dotomi.com", "*doubleclick.net", "*doubleverify.com",
        "*evidon.com", "*exoclick.com", "*exosrv.com", "*fastclick.net",
        "*flurry.com", "*fundingchoicesmessages.google.com",
        "*google-analytics.com", "*googleads.g.doubleclick.net", "*googleadservices.com",
        "*googlesyndication.com", "*googletagmanager.com", "*hilltopads.net",
        "*imrworldwide.com", "*infolinks.com", "*innovid.com", "*intellitxt.com", "*invitemedia.com",
        "*juicyads.com", "*kontera.com", "*krxd.net", "*legolas-media.com",
        "*lijit.com", "*mathtag.com", "*mc.yandex.ru", "*mediaplex.com",
        "*mgid.com", "*moatads.com", "*mookie1.com", "*mythings.com",
        "*onclickads.net", "*openx.net", "*outbrain.com", "*pagead2.googlesyndication.com",
        "*popads.net", "*popcash.net", "*propellerads.com", "*pubmatic.com", "*quantcount.com",
        "*quantserve.com", "*questionmarket.com", "*revcontent.com", "*richaudience.com",
        "*rlcdn.com", "*rubiconproject.com", "*s0.2mdn.net", "*scorecardresearch.com", "*serving-sys.com",
        "*sharethrough.com", "*skimresources.com", "*smartadserver.com", "*sonobi.com",
        "*specificmedia.com", "*spotxchange.com", "*static.doubleclick.net", "*stats.g.doubleclick.net",
        "*steelhousemedia.com", "*taboola.com", "*tapad.com", "*teads.tv", "*tpc.googlesyndication.com",
        "*trafficfactory.biz", "*trafficjunky.net",
        "*tribalfusion.com", "*turn.com", "*undertone.com", "*unityads.unity3d.com",
        "*vibrantmedia.com", "*viglink.com", "*vungle.com", "*yieldmanager.com",
        "*yieldmo.com", "*zedo.com"
    ]

    private var blockRulesJSON: String {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": Self.blockedAdDomains
                ],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": ".*",
                    "resource-type": ["popup"]
                ],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": "^https?://[^/]+/(ads|adserver|popunder|banner_ads)/",
                    "load-type": ["third-party"]
                ],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?(youtube\\.com|youtu\\.be)/(pagead/|ptracking|api/stats/ads|get_midroll_info)"
                ],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?google\\.com/pagead/"
                ],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": "^https?://[^/]*googlevideo\\.com/.*[?&]adformat="
                ],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": ["*youtube.com", "*youtu.be"]
                ],
                "action": [
                    "type": "css-display-none",
                    "selector": ".ytp-ad-module, .ytp-ad-overlay-container, .ytp-ad-player-overlay, ytm-ad-slot-renderer, ad-slot-renderer, ytm-promoted-sparkles-web-renderer, ytm-promoted-video-renderer, ytm-companion-slot-renderer, ytm-statement-banner-renderer, ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-banner-promo-renderer, #masthead-ad, #player-ads"
                ]
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: rules),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) != nil {
            self.isBlockingEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        } else {
            self.isBlockingEnabled = true
        }

        Task {
            _ = await loadOrCompileRuleList()
        }
    }

    func applyRules(to configuration: WKWebViewConfiguration) async {
        guard isBlockingEnabled else {
            await MainActor.run {
                configuration.userContentController.removeAllContentRuleLists()
            }
            return
        }

        if let ruleList = await loadOrCompileRuleList() {
            await MainActor.run {
                configuration.userContentController.removeAllContentRuleLists()
                configuration.userContentController.add(ruleList)
            }
        }
    }

    @MainActor
    private func loadOrCompileRuleList() async -> WKContentRuleList? {
        if let cachedRuleList {
            return cachedRuleList
        }
        guard let store = WKContentRuleListStore.default() else {
            return nil
        }

        let ruleList: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { [weak self] existingList, _ in
                if let existingList {
                    continuation.resume(returning: existingList)
                    return
                }
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                store.compileContentRuleList(
                    forIdentifier: self.ruleListIdentifier,
                    encodedContentRuleList: self.blockRulesJSON
                ) { compiledList, error in
                    if let error {
                        print("Content blocker compile error: \(error)")
                    }
                    continuation.resume(returning: compiledList)
                }
            }
        }

        if let ruleList {
            self.cachedRuleList = ruleList
        }
        return ruleList
    }
}
