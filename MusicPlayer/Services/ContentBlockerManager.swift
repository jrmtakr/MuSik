import Foundation
import Observation
import WebKit

@Observable
final class ContentBlockerManager {
    private static let enabledDefaultsKey = "musicplayer.adblock.enabled"
    private let ruleListIdentifier = "MusicPlayerAdBlockRulesV3"

    var isBlockingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBlockingEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    private(set) var cachedRuleList: WKContentRuleList?

    private static let blockedAdDomains: [String] = [
        "*247realmedia.com", "*2mdn.net", "*adblade.com", "*adcolony.com",
        "*adform.net", "*adition.com", "*adkengage.com", "*admagnet.net",
        "*admob.com", "*adnxs.com", "*adobetag.com", "*adroll.com",
        "*adsafeprotected.com", "*adscale.de", "*adserver.yahoo.com",
        "*adskeeper.co.uk", "*adsterra.com", "*advertising.com",
        "*amazon-adsystem.com", "*amobee.com", "*appnexus.com",
        "*atdmt.com", "*bidswitch.net", "*bidvertiser.com",
        "*bluekai.com", "*casalemedia.com", "*chartbeat.com",
        "*clickadu.com", "*criteo.com", "*criteo.net",
        "*demdex.net", "*dotomi.com", "*doubleclick.net",
        "*doubleverify.com", "*exoclick.com", "*exosrv.com",
        "*fastclick.net", "*flurry.com", "*google-analytics.com",
        "*googleadservices.com", "*googlesyndication.com", "*googletagmanager.com",
        "*hilltopads.net", "*imrworldwide.com", "*infolinks.com",
        "*juicyads.com", "*krxd.net", "*lijit.com",
        "*mathtag.com", "*mc.yandex.ru", "*mediaplex.com",
        "*mgid.com", "*moatads.com", "*mookie1.com",
        "*onclickads.net", "*openx.net", "*outbrain.com",
        "*popads.net", "*popcash.net", "*propellerads.com",
        "*pubmatic.com", "*quantcount.com", "*quantserve.com",
        "*revcontent.com", "*richaudience.com", "*rlcdn.com",
        "*rubiconproject.com", "*scorecardresearch.com", "*serving-sys.com",
        "*sharethrough.com", "*smartadserver.com", "*sonobi.com",
        "*spotxchange.com", "*taboola.com", "*tapad.com",
        "*teads.tv", "*trafficfactory.biz", "*trafficjunky.net",
        "*tribalfusion.com", "*turn.com", "*undertone.com",
        "*unityads.unity3d.com", "*vungle.com", "*yieldmo.com",
        "*zedo.com"
    ]

    private var blockRulesJSON: String {
        let domainEntries = Self.blockedAdDomains.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        [
            {
                "trigger": {
                    "url-filter": ".*",
                    "if-domain": [\(domainEntries)]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": ".*",
                    "resource-type": ["popup"]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": "^https?://[^/]+/(ads|adserver|popunder|banner_ads)/",
                    "load-type": ["third-party"]
                },
                "action": { "type": "block" }
            }
        ]
        """
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
