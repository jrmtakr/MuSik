import Foundation
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SearchEngineOption: String, CaseIterable, Identifiable {
    case duckDuckGo = "DuckDuckGo"
    case google = "Google"
    case bing = "Bing"
    case brave = "Brave"

    var id: String { rawValue }

    func searchURL(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        switch self {
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=\(encoded)")
        case .google: return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .brave: return URL(string: "https://search.brave.com/search?q=\(encoded)")
        }
    }
}

@Observable
final class AppSettings {
    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearance) }
    }
    var searchEngine: SearchEngineOption {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }
    var adBlockEnabled: Bool {
        didSet { UserDefaults.standard.set(adBlockEnabled, forKey: Keys.adBlockEnabled) }
    }
    var webDarkModeEnabled: Bool {
        didSet { UserDefaults.standard.set(webDarkModeEnabled, forKey: Keys.webDarkMode) }
    }
    var askBeforeCaching: Bool {
        didSet { UserDefaults.standard.set(askBeforeCaching, forKey: Keys.askBeforeCaching) }
    }
    var autoCacheDetectedMedia: Bool {
        didSet { UserDefaults.standard.set(autoCacheDetectedMedia, forKey: Keys.autoCache) }
    }
    var maxCacheDurationMinutes: Int {
        didSet { UserDefaults.standard.set(maxCacheDurationMinutes, forKey: Keys.maxDuration) }
    }
    var quickAccessLastPlaylist: Bool {
        didSet { UserDefaults.standard.set(quickAccessLastPlaylist, forKey: Keys.quickAccessLastPlaylist) }
    }
    var lastPlaylistIDString: String {
        didSet { UserDefaults.standard.set(lastPlaylistIDString, forKey: Keys.lastPlaylistID) }
    }

    private enum Keys {
        static let appearance = "musicplayer.appearance"
        static let searchEngine = "musicplayer.searchEngine"
        static let adBlockEnabled = "musicplayer.adblock.enabled"
        static let webDarkMode = "musicplayer.webDarkMode"
        static let askBeforeCaching = "musicplayer.askBeforeCaching"
        static let autoCache = "musicplayer.autoCache"
        static let maxDuration = "musicplayer.maxDuration"
        static let quickAccessLastPlaylist = "musicplayer.quickAccessLastPlaylist"
        static let lastPlaylistID = "musicplayer.lastPlaylistID"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.adBlockEnabled) == nil {
            defaults.set(true, forKey: Keys.adBlockEnabled)
        }
        if defaults.object(forKey: Keys.askBeforeCaching) == nil {
            defaults.set(true, forKey: Keys.askBeforeCaching)
        }
        if defaults.object(forKey: Keys.quickAccessLastPlaylist) == nil {
            defaults.set(true, forKey: Keys.quickAccessLastPlaylist)
        }

        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        self.searchEngine = SearchEngineOption(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .duckDuckGo
        self.adBlockEnabled = defaults.bool(forKey: Keys.adBlockEnabled)
        self.webDarkModeEnabled = defaults.bool(forKey: Keys.webDarkMode)
        self.askBeforeCaching = defaults.bool(forKey: Keys.askBeforeCaching)
        self.autoCacheDetectedMedia = defaults.bool(forKey: Keys.autoCache)
        self.maxCacheDurationMinutes = defaults.integer(forKey: Keys.maxDuration)
        self.quickAccessLastPlaylist = defaults.bool(forKey: Keys.quickAccessLastPlaylist)
        self.lastPlaylistIDString = defaults.string(forKey: Keys.lastPlaylistID) ?? ""
    }

    func setAskBeforeCaching(_ enabled: Bool) {
        askBeforeCaching = enabled
        if enabled {
            autoCacheDetectedMedia = false
        }
    }

    func setAutoCacheDetectedMedia(_ enabled: Bool) {
        autoCacheDetectedMedia = enabled
        if enabled {
            askBeforeCaching = false
        }
    }
}
