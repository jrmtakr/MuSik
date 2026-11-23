import Foundation
import Observation
import WebKit

@Observable
final class ContentBlockerManager {
    private static let enabledDefaultsKey = "musicplayer.adblock.enabled"
    private let ruleListIdentifier = "MusicPlayerAdBlockRulesV2"

    var isBlockingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBlockingEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    private(set) var cachedRuleList: WKContentRuleList?

    private let blockRulesJSON = """
    [
        {
            "trigger": {
                "url-filter": ".*",
                "if-domain": [
                    "*doubleclick.net",
                    "*googlesyndication.com",
                    "*googleadservices.com",
                    "*google-analytics.com",
                    "*googletagmanager.com",
                    "*adnxs.com",
                    "*taboola.com",
                    "*outbrain.com",
                    "*popads.net",
                    "*popcash.net",
                    "*propellerads.com",
                    "*adsterra.com",
                    "*exoclick.com",
                    "*juicyads.com",
                    "*trafficjunky.net",
                    "*revcontent.com",
                    "*criteo.com",
                    "*rubiconproject.com",
                    "*pubmatic.com",
                    "*openx.net",
                    "*casalemedia.com",
                    "*amazon-adsystem.com",
                    "*scorecardresearch.com",
                    "*quantserve.com",
                    "*moatads.com",
                    "*adsafeprotected.com",
                    "*mc.yandex.ru"
                ]
            },
            "action": {
                "type": "block"
            }
        },
        {
            "trigger": {
                "url-filter": ".*",
                "resource-type": ["popup"]
            },
            "action": {
                "type": "block"
            }
        }
    ]
    """

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
            await MainActor.run {
                self.cachedRuleList = ruleList
            }
        }
        return ruleList
    }
}
