import Foundation

struct BrowserTabItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    var isPrivate: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        urlString: String = "https://www.google.com",
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isPrivate = isPrivate
    }
}

struct SpeedDialSite: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    var shortLabel: String
    var hexColor: String

    init(
        id: UUID = UUID(),
        title: String,
        urlString: String,
        shortLabel: String? = nil,
        hexColor: String = "#5B7CFA"
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        let trimmed = (shortLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            self.shortLabel = String(trimmed.prefix(3))
        } else {
            self.shortLabel = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
        }
        self.hexColor = hexColor
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
    let pairedAudioURL: URL?
    let isHLS: Bool
    let isAudio: Bool
    let title: String?
    let author: String?
    let qualityLabel: String?
    let referer: String?
    let customHeaders: [String: String]?
    let durationSeconds: Double?
    let isActivelyPlaying: Bool

    init(
        url: URL,
        pairedAudioURL: URL? = nil,
        isHLS: Bool,
        isAudio: Bool,
        title: String? = nil,
        author: String? = nil,
        qualityLabel: String? = nil,
        referer: String? = nil,
        customHeaders: [String: String]? = nil,
        durationSeconds: Double? = nil,
        isActivelyPlaying: Bool = false
    ) {
        self.url = url
        self.pairedAudioURL = pairedAudioURL
        self.isHLS = isHLS
        self.isAudio = isAudio
        self.title = title
        self.author = author
        self.qualityLabel = qualityLabel
        self.referer = referer
        self.customHeaders = customHeaders
        self.durationSeconds = durationSeconds
        self.isActivelyPlaying = isActivelyPlaying
    }

    var kindLabel: String {
        if let qualityLabel, !qualityLabel.isEmpty { return qualityLabel }
        if isHLS { return "HLS Stream" }
        return isAudio ? "Audio" : "Video"
    }

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return MediaTimeFormatter.format(durationSeconds)
    }

    var fileExtensionHint: String {
        if pairedAudioURL != nil { return "MP4 HD" }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && ext.count <= 6 {
            return ext.uppercased()
        }
        return isHLS ? "M3U8" : (isAudio ? "M4A" : "MP4")
    }
}

struct HLSQualityVariant: Identifiable, Hashable {
    let id: String
    let label: String
    let width: Int
    let height: Int
    let peakBitrate: Double
    let variantURL: URL?
    let audioGroupID: String?

    init(
        id: String,
        label: String,
        width: Int,
        height: Int,
        peakBitrate: Double,
        variantURL: URL? = nil,
        audioGroupID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.width = width
        self.height = height
        self.peakBitrate = peakBitrate
        self.variantURL = variantURL
        self.audioGroupID = audioGroupID
    }
}

struct BrowserDownloadItem: Identifiable {
    let id: UUID
    let title: String
    let sourceURL: URL
    var progress: Double
    let isHLS: Bool
}
