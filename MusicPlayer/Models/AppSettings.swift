import Foundation
import Observation
import SwiftUI
import UIKit

extension Color {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        } else {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHexString() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return "#12131A"
        }
        let ri = Int(round(min(max(r, 0), 1) * 255))
        let gi = Int(round(min(max(g, 0), 1) * 255))
        let bi = Int(round(min(max(b, 0), 1) * 255))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

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
    case mangaRTL = "Manga (Right-to-Left)"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .scroll: return "Vertical Scroll (Webtoon)"
        case .page: return "Page (Left-to-Right)"
        case .mangaRTL: return "Manga (Right-to-Left)"
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
    var useCustomAppIcon: Bool {
        didSet { UserDefaults.standard.set(useCustomAppIcon, forKey: Keys.useCustomAppIcon) }
    }
    var customAppIconImage: UIImage?
    var customBackgroundImage: UIImage?
    var backgroundDimOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundDimOpacity, forKey: Keys.backgroundDimOpacity) }
    }
    var backgroundBlurEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundBlurEnabled, forKey: Keys.backgroundBlurEnabled) }
    }
    var useCustomBackgroundColor: Bool {
        didSet { UserDefaults.standard.set(useCustomBackgroundColor, forKey: Keys.useCustomBackgroundColor) }
    }
    var customBackgroundHex: String {
        didSet { UserDefaults.standard.set(customBackgroundHex, forKey: Keys.customBackgroundHex) }
    }
    var useCustomTextColor: Bool {
        didSet { UserDefaults.standard.set(useCustomTextColor, forKey: Keys.useCustomTextColor) }
    }
    var customTextHex: String {
        didSet { UserDefaults.standard.set(customTextHex, forKey: Keys.customTextHex) }
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
    var crossfadeEnabled: Bool {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: Keys.crossfadeEnabled) }
    }
    var crossfadeDurationSeconds: Double {
        didSet { UserDefaults.standard.set(crossfadeDurationSeconds, forKey: Keys.crossfadeDuration) }
    }

    static var isCrossfadeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.crossfadeEnabled)
    }

    static var storedCrossfadeDuration: Double {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.crossfadeDuration) != nil else { return 4.0 }
        return min(12.0, max(0.5, d.double(forKey: Keys.crossfadeDuration)))
    }

    var targetDownloadPlaylistID: UUID? {
        UUID(uuidString: targetDownloadPlaylistIDString)
    }

    var customBackgroundColor: Color {
        get { Color(hexString: customBackgroundHex) ?? Color(red: 0.07, green: 0.08, blue: 0.11) }
        set { customBackgroundHex = newValue.toHexString() }
    }

    var customTextColor: Color {
        get { Color(hexString: customTextHex) ?? Color.white }
        set { customTextHex = newValue.toHexString() }
    }

    var hasCustomBackground: Bool {
        customBackgroundImage != nil || useCustomBackgroundColor
    }

    var hasCustomTextColor: Bool {
        useCustomTextColor
    }

    var themedRowBackgroundColor: Color {
        if useCustomBackgroundColor {
            return customBackgroundColor.opacity(customBackgroundImage != nil ? 0.62 : 0.85)
        }
        return Color(.secondarySystemBackground).opacity(0.68)
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
        static let useCustomAppIcon = "musicplayer.useCustomAppIcon"
        static let backgroundDimOpacity = "musicplayer.backgroundDimOpacity"
        static let backgroundBlurEnabled = "musicplayer.backgroundBlurEnabled"
        static let useCustomBackgroundColor = "musicplayer.useCustomBackgroundColor"
        static let customBackgroundHex = "musicplayer.customBackgroundHex"
        static let useCustomTextColor = "musicplayer.useCustomTextColor"
        static let customTextHex = "musicplayer.customTextHex"
        static let suppressedCacheHosts = "musicplayer.suppressedCacheHosts"
        static let autoAddDownloadsToPlaylist = "musicplayer.autoAddDownloadsToPlaylist"
        static let targetDownloadPlaylistID = "musicplayer.targetDownloadPlaylistID"
        static let crossfadeEnabled = "musicplayer.crossfade.enabled"
        static let crossfadeDuration = "musicplayer.crossfade.seconds"
    }

    private static var themeAssetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ThemeAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var customIconFileURL: URL {
        themeAssetsDirectory.appendingPathComponent("custom_app_icon.png")
    }

    private static var customBackgroundFileURL: URL {
        themeAssetsDirectory.appendingPathComponent("custom_app_background.jpg")
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
        if defaults.object(forKey: Keys.backgroundDimOpacity) == nil {
            defaults.set(0.35, forKey: Keys.backgroundDimOpacity)
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
        self.useCustomAppIcon = defaults.bool(forKey: Keys.useCustomAppIcon)
        self.backgroundDimOpacity = defaults.double(forKey: Keys.backgroundDimOpacity)
        self.backgroundBlurEnabled = defaults.bool(forKey: Keys.backgroundBlurEnabled)
        self.useCustomBackgroundColor = defaults.bool(forKey: Keys.useCustomBackgroundColor)
        self.customBackgroundHex = defaults.string(forKey: Keys.customBackgroundHex) ?? "#12131A"
        self.useCustomTextColor = defaults.bool(forKey: Keys.useCustomTextColor)
        self.customTextHex = defaults.string(forKey: Keys.customTextHex) ?? "#F5F7FF"
        self.suppressedCacheHosts = defaults.stringArray(forKey: Keys.suppressedCacheHosts) ?? []
        self.autoAddDownloadsToPlaylist = defaults.bool(forKey: Keys.autoAddDownloadsToPlaylist)
        self.targetDownloadPlaylistIDString = defaults.string(forKey: Keys.targetDownloadPlaylistID) ?? ""
        self.crossfadeEnabled = defaults.bool(forKey: Keys.crossfadeEnabled)
        if defaults.object(forKey: Keys.crossfadeDuration) != nil {
            self.crossfadeDurationSeconds = min(12.0, max(0.5, defaults.double(forKey: Keys.crossfadeDuration)))
        } else {
            self.crossfadeDurationSeconds = 4.0
        }

        if FileManager.default.fileExists(atPath: Self.customIconFileURL.path),
           let img = UIImage(contentsOfFile: Self.customIconFileURL.path) {
            self.customAppIconImage = img
        } else {
            self.customAppIconImage = nil
            self.useCustomAppIcon = false
        }

        if FileManager.default.fileExists(atPath: Self.customBackgroundFileURL.path),
           let bg = UIImage(contentsOfFile: Self.customBackgroundFileURL.path) {
            self.customBackgroundImage = bg
        } else {
            self.customBackgroundImage = nil
        }
    }

    func saveCustomAppIcon(_ image: UIImage) {
        let targetSize = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let squared = renderer.image { _ in
            let aspect = max(targetSize.width / max(image.size.width, 1), targetSize.height / max(image.size.height, 1))
            let drawWidth = image.size.width * aspect
            let drawHeight = image.size.height * aspect
            let rect = CGRect(
                x: (targetSize.width - drawWidth) / 2,
                y: (targetSize.height - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            image.draw(in: rect)
        }
        if let data = squared.pngData() {
            try? data.write(to: Self.customIconFileURL, options: .atomic)
            customAppIconImage = squared
            useCustomAppIcon = true
        }
    }

    func clearCustomAppIcon() {
        try? FileManager.default.removeItem(at: Self.customIconFileURL)
        customAppIconImage = nil
        useCustomAppIcon = false
    }

    func saveCustomBackgroundImage(_ image: UIImage) {
        if let data = image.jpegData(compressionQuality: 0.86) {
            try? data.write(to: Self.customBackgroundFileURL, options: .atomic)
            customBackgroundImage = UIImage(data: data) ?? image
        }
    }

    func clearCustomBackgroundImage() {
        try? FileManager.default.removeItem(at: Self.customBackgroundFileURL)
        customBackgroundImage = nil
    }

    func resetCustomTheme() {
        clearCustomBackgroundImage()
        useCustomBackgroundColor = false
        useCustomTextColor = false
        backgroundDimOpacity = 0.35
        backgroundBlurEnabled = false
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
