import Foundation

struct BrowserTabItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    var isPrivate: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        urlString: String = "https://duckduckgo.com",
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isPrivate = isPrivate
    }
}

struct BookmarkItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, urlString: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.createdAt = createdAt
    }
}

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    var visitedAt: Date

    init(id: UUID = UUID(), title: String, urlString: String, visitedAt: Date = .now) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.visitedAt = visitedAt
    }
}

struct DetectedBrowserMedia: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isHLS: Bool
    let isAudio: Bool
    let title: String?
    let referer: String?

    var kindLabel: String {
        if isHLS { return "HLS Stream" }
        return isAudio ? "Audio" : "Video"
    }
}

struct HLSQualityVariant: Identifiable, Hashable {
    let id: String
    let label: String
    let width: Int
    let height: Int
    let peakBitrate: Double
}

struct BrowserDownloadItem: Identifiable {
    let id: UUID
    let title: String
    let sourceURL: URL
    var progress: Double
    let isHLS: Bool
}
