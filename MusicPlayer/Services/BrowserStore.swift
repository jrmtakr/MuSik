import Foundation
import Observation

@MainActor
@Observable
final class BrowserStore {
    var tabs: [BrowserTabItem] = []
    var activeTabID: UUID
    var navigationRequestNonce: Int = 0
    var bookmarks: [BookmarkItem] = []
    var history: [HistoryEntry] = []
    var speedDialSites: [SpeedDialSite] = []

    private static var appSupportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var bookmarksURL: URL {
        appSupportDirectory.appendingPathComponent("browser_bookmarks.json")
    }

    private static var historyURL: URL {
        appSupportDirectory.appendingPathComponent("browser_history.json")
    }

    private static var speedDialURL: URL {
        appSupportDirectory.appendingPathComponent("browser_speed_dial.json")
    }

    private static let defaultSpeedDialSites: [SpeedDialSite] = [
        SpeedDialSite(title: "YouTube", urlString: "https://m.youtube.com", shortLabel: "▶", hexColor: "#FF0000"),
        SpeedDialSite(title: "YT Music", urlString: "https://music.youtube.com", shortLabel: "♫", hexColor: "#FF0033"),
        SpeedDialSite(title: "SoundCloud", urlString: "https://m.soundcloud.com", shortLabel: "SC", hexColor: "#FF5500"),
        SpeedDialSite(title: "Archive", urlString: "https://archive.org", shortLabel: "AR", hexColor: "#2C3E50"),
        SpeedDialSite(title: "Google", urlString: "https://www.google.com", shortLabel: "G", hexColor: "#4285F4"),
        SpeedDialSite(title: "DuckDuckGo", urlString: "https://duckduckgo.com", shortLabel: "DDG", hexColor: "#DE5833"),
        SpeedDialSite(title: "Wikipedia", urlString: "https://en.m.wikipedia.org", shortLabel: "W", hexColor: "#3A3A44")
    ]

    init() {
        let initial = BrowserTabItem()
        self.tabs = [initial]
        self.activeTabID = initial.id
        load()
    }

    var activeTab: BrowserTabItem {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    func addTab(isPrivate: Bool = false, urlString: String = "https://www.google.com") {
        let tab = BrowserTabItem(
            title: isPrivate ? "Private Tab" : "New Tab",
            urlString: urlString,
            isPrivate: isPrivate
        )
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if tabs.isEmpty {
            let fresh = BrowserTabItem()
            tabs = [fresh]
            activeTabID = fresh.id
        } else if activeTabID == id {
            activeTabID = tabs[0].id
        }
    }

    func openInActiveTab(urlString: String, title: String? = nil) {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[idx].urlString = normalizedURLString(urlString)
        if let title, !title.isEmpty {
            tabs[idx].title = title
        }
        navigationRequestNonce &+= 1
    }

    func updateActiveTab(urlString: String, title: String?) {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[idx].urlString = urlString
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabs[idx].title = title
        }
        if !tabs[idx].isPrivate {
            recordHistory(title: title ?? urlString, urlString: urlString)
        }
    }

    // MARK: - Speed Dial Websites

    func addOrUpdateSpeedDial(id: UUID? = nil, title: String, urlString: String) {
        let resolvedURL = normalizedURLString(urlString)
        guard !resolvedURL.isEmpty else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? (URL(string: resolvedURL)?.host ?? resolvedURL) : cleanTitle

        if let id, let idx = speedDialSites.firstIndex(where: { $0.id == id }) {
            speedDialSites[idx].title = resolvedTitle
            speedDialSites[idx].urlString = resolvedURL
            speedDialSites[idx].shortLabel = String(resolvedTitle.prefix(2)).uppercased()
        } else {
            speedDialSites.append(
                SpeedDialSite(title: resolvedTitle, urlString: resolvedURL)
            )
        }
        saveSpeedDial()
    }

    func deleteSpeedDial(_ site: SpeedDialSite) {
        speedDialSites.removeAll { $0.id == site.id }
        saveSpeedDial()
    }

    // MARK: - Bookmarks & History

    func toggleBookmark(title: String, urlString: String) {
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let idx = bookmarks.firstIndex(where: { $0.urlString == cleaned }) {
            bookmarks.remove(at: idx)
        } else {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarks.insert(
                BookmarkItem(title: cleanTitle.isEmpty ? cleaned : cleanTitle, urlString: cleaned),
                at: 0
            )
        }
        saveBookmarks()
    }

    func addOrUpdateBookmark(id: UUID? = nil, title: String, urlString: String) {
        let trimmedURL = normalizedURLString(urlString)
        guard !trimmedURL.isEmpty else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? trimmedURL : trimmedTitle

        if let id, let idx = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[idx].title = resolvedTitle
            bookmarks[idx].urlString = trimmedURL
        } else {
            bookmarks.insert(BookmarkItem(title: resolvedTitle, urlString: trimmedURL), at: 0)
        }
        saveBookmarks()
    }

    func deleteBookmarks(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where bookmarks.indices.contains(index) {
            bookmarks.remove(at: index)
        }
        saveBookmarks()
    }

    func isBookmarked(_ urlString: String) -> Bool {
        bookmarks.contains { $0.urlString == urlString }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func normalizedURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func recordHistory(title: String, urlString: String) {
        guard urlString.hasPrefix("http") else { return }
        if history.first?.urlString == urlString { return }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        history.insert(
            HistoryEntry(title: resolvedTitle.isEmpty ? urlString : resolvedTitle, urlString: urlString),
            at: 0
        )
        if history.count > 150 {
            history = Array(history.prefix(150))
        }
        saveHistory()
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.bookmarksURL),
           let decoded = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            bookmarks = decoded
        }
        if let data = try? Data(contentsOf: Self.historyURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = decoded
        }
        if let data = try? Data(contentsOf: Self.speedDialURL),
           let decoded = try? JSONDecoder().decode([SpeedDialSite].self, from: data),
           !decoded.isEmpty {
            speedDialSites = decoded
        } else {
            speedDialSites = Self.defaultSpeedDialSites
        }
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: Self.bookmarksURL, options: [.atomic])
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: Self.historyURL, options: [.atomic])
    }

    private func saveSpeedDial() {
        guard let data = try? JSONEncoder().encode(speedDialSites) else { return }
        try? data.write(to: Self.speedDialURL, options: [.atomic])
    }
}
