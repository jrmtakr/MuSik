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
    case google = "Google"
    case duckDuckGo = "DuckDuckGo"
    case bing = "Bing"
    case yahoo = "Yahoo"
    case brave = "Brave"

    var id: String { rawValue }

    var shortBadge: String {
        switch self {
        case .google: return "G"
        case .duckDuckGo: return "D"
        case .bing: return "B"
        case .yahoo: return "Y!"
        case .brave: return "Br"
        }
    }

    func searchURL(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=\(encoded)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .yahoo: return URL(string: "https://search.yahoo.com/search?p=\(encoded)")
        case .brave: return URL(string: "https://search.brave.com/search?q=\(encoded)")
        }
    }
}

enum ReadingDirection: String, CaseIterable, Identifiable {
    case scroll = "Scroll"
    case page = "Page"

    var id: String { rawValue }
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
    var inlineVideoPlayback: Bool {
        didSet { UserDefaults.standard.set(inlineVideoPlayback, forKey: Keys.inlineVideoPlayback) }
    }
    var askBeforeCaching: Bool {
        didSet { UserDefaults.standard.set(askBeforeCaching, forKey: Keys.askBeforeCaching) }
    }
    var autoCacheDetectedMedia: Bool {
        didSet { UserDefaults.standard.set(autoCacheDetectedMedia, forKey: Keys.autoCache) }
    }
    var autoOpenPlayerAfterCache: Bool {
        didSet { UserDefaults.standard.set(autoOpenPlayerAfterCache, forKey: Keys.autoOpenPlayerAfterCache) }
    }
    var maxCacheDurationMinutes: Int {
        didSet { UserDefaults.standard.set(maxCacheDurationMinutes, forKey: Keys.maxDuration) }
    }
    var quickAccessLastPlaylist: Bool {
        didSet { UserDefaults.standard.set(quickAccessLastPlaylist, forKey: Keys.quickAccessLastPlaylist) }
    }
    var readingDirection: ReadingDirection {
        didSet { UserDefaults.standard.set(readingDirection.rawValue, forKey: Keys.readingDirection) }
    }
    var readerFontSize: Double {
        didSet { UserDefaults.standard.set(readerFontSize, forKey: Keys.readerFontSize) }
    }
    var readerDarkTheme: Bool {
        didSet { UserDefaults.standard.set(readerDarkTheme, forKey: Keys.readerDarkTheme) }
    }
    var selectedAppIconName: String {
        didSet { UserDefaults.standard.set(selectedAppIconName, forKey: Keys.selectedAppIconName) }
    }
    var suppressedCacheHosts: [String] {
        didSet { UserDefaults.standard.set(suppressedCacheHosts, forKey: Keys.suppressedCacheHosts) }
    }
    var autoAddDownloadsToPlaylist: Bool {
        didSet { UserDefaults.standard.set(autoAddDownloadsToPlaylist, forKey: Keys.autoAddDownloadsToPlaylist) }
    }
    var targetDownloadPlaylistIDString: String {
        didSet { UserDefaults.standard.set(targetDownloadPlaylistIDString, forKey: Keys.targetDownloadPlaylistID) }
    }

    var targetDownloadPlaylistID: UUID? {
        UUID(uuidString: targetDownloadPlaylistIDString)
    }

    static var isAutoAddDownloadsToPlaylistEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.autoAddDownloadsToPlaylist) == nil { return true }
        return d.bool(forKey: Keys.autoAddDownloadsToPlaylist)
    }

    static var storedTargetDownloadPlaylistID: UUID? {
        guard let str = UserDefaults.standard.string(forKey: Keys.targetDownloadPlaylistID) else { return nil }
        return UUID(uuidString: str)
    }

    private enum Keys {
        static let appearance = "musicplayer.appearance"
        static let searchEngine = "musicplayer.searchEngine"
        static let adBlockEnabled = "musicplayer.adblock.enabled"
        static let webDarkMode = "musicplayer.webDarkMode"
        static let inlineVideoPlayback = "musicplayer.inlineVideoPlayback"
        static let askBeforeCaching = "musicplayer.askBeforeCaching"
        static let autoCache = "musicplayer.autoCache"
        static let autoOpenPlayerAfterCache = "musicplayer.autoOpenPlayerAfterCache"
        static let cacheFlowV2Applied = "musicplayer.defaults.cacheFlowV2"
        static let maxDuration = "musicplayer.maxDuration"
        static let quickAccessLastPlaylist = "musicplayer.quickAccessLastPlaylist"
        static let readingDirection = "musicplayer.readingDirection"
        static let readerFontSize = "musicplayer.readerFontSize"
        static let readerDarkTheme = "musicplayer.readerDarkTheme"
        static let selectedAppIconName = "musicplayer.selectedAppIconName"
        static let suppressedCacheHosts = "musicplayer.suppressedCacheHosts"
        static let autoAddDownloadsToPlaylist = "musicplayer.autoAddDownloadsToPlaylist"
        static let targetDownloadPlaylistID = "musicplayer.targetDownloadPlaylistID"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.adBlockEnabled) == nil {
            defaults.set(true, forKey: Keys.adBlockEnabled)
        }
        if !defaults.bool(forKey: Keys.cacheFlowV2Applied) {
            defaults.set(true, forKey: Keys.autoCache)
            defaults.set(false, forKey: Keys.askBeforeCaching)
            defaults.set(false, forKey: Keys.inlineVideoPlayback)
            defaults.set(true, forKey: Keys.autoOpenPlayerAfterCache)
            defaults.set(true, forKey: Keys.cacheFlowV2Applied)
        }
        if defaults.object(forKey: Keys.autoOpenPlayerAfterCache) == nil {
            defaults.set(true, forKey: Keys.autoOpenPlayerAfterCache)
        }
        if defaults.object(forKey: Keys.quickAccessLastPlaylist) == nil {
            defaults.set(true, forKey: Keys.quickAccessLastPlaylist)
        }
        if defaults.object(forKey: Keys.readerFontSize) == nil {
            defaults.set(17.0, forKey: Keys.readerFontSize)
        }
        if defaults.object(forKey: Keys.autoAddDownloadsToPlaylist) == nil {
            defaults.set(true, forKey: Keys.autoAddDownloadsToPlaylist)
        }

        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        self.searchEngine = SearchEngineOption(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .google
        self.adBlockEnabled = defaults.bool(forKey: Keys.adBlockEnabled)
        self.webDarkModeEnabled = defaults.bool(forKey: Keys.webDarkMode)
        self.inlineVideoPlayback = defaults.bool(forKey: Keys.inlineVideoPlayback)
        self.askBeforeCaching = defaults.bool(forKey: Keys.askBeforeCaching)
        self.autoCacheDetectedMedia = defaults.bool(forKey: Keys.autoCache)
        self.autoOpenPlayerAfterCache = defaults.bool(forKey: Keys.autoOpenPlayerAfterCache)
        self.maxCacheDurationMinutes = defaults.integer(forKey: Keys.maxDuration)
        self.quickAccessLastPlaylist = defaults.bool(forKey: Keys.quickAccessLastPlaylist)
        self.readingDirection = ReadingDirection(rawValue: defaults.string(forKey: Keys.readingDirection) ?? "") ?? .scroll
        self.readerFontSize = defaults.double(forKey: Keys.readerFontSize)
        self.readerDarkTheme = defaults.bool(forKey: Keys.readerDarkTheme)
        self.selectedAppIconName = defaults.string(forKey: Keys.selectedAppIconName) ?? ""
        self.suppressedCacheHosts = defaults.stringArray(forKey: Keys.suppressedCacheHosts) ?? []
        self.autoAddDownloadsToPlaylist = defaults.bool(forKey: Keys.autoAddDownloadsToPlaylist)
        self.targetDownloadPlaylistIDString = defaults.string(forKey: Keys.targetDownloadPlaylistID) ?? ""
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

    func suppressCachingPrompts(forHost host: String) {
        let normalized = host.lowercased()
        guard !normalized.isEmpty, !suppressedCacheHosts.contains(normalized) else { return }
        suppressedCacheHosts.append(normalized)
    }

    func isPromptSuppressed(forHost host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return suppressedCacheHosts.contains(host)
    }

    func clearSuppressedCacheHosts() {
        suppressedCacheHosts.removeAll()
    }
}
