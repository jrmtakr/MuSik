import Foundation
import ImageIO
import Observation
import SwiftUI
import UIKit

enum TikTokAssetKind: String, Codable, Hashable {
    case sticker
    case gif
}

struct TikTokMediaAsset: Identifiable, Hashable, Codable {
    let id: String
    let kind: TikTokAssetKind
    let title: String
    let urlString: String
    let sourceName: String
    let discoveredAt: TimeInterval

    var mediaURL: URL? {
        URL(string: urlString)
    }
}

private struct TikTokCatalogCacheFile: Codable {
    var stickers: [TikTokMediaAsset]
    var gifs: [TikTokMediaAsset]
    var lastRefreshedAt: TimeInterval
}

@MainActor
@Observable
final class TikTokMediaService {
    static let shared = TikTokMediaService()

    private static let desktopUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private static let refreshIntervalSeconds: TimeInterval = 4 * 3600

    var stickers: [TikTokMediaAsset] = []
    var gifs: [TikTokMediaAsset] = []
    var isRefreshing: Bool = false
    var lastRefreshedAt: Date?
    var lastAddedCount: Int = 0
    var activeSearchQuery: String = ""
    var statusText: String?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private var catalogFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tiktok_media_catalog.json")
    }

    private init() {
        loadFromDiskOrSeed()
    }

    func refreshIfDue() {
        let now = Date()
        if let lastRefreshedAt,
           now.timeIntervalSince(lastRefreshedAt) < Self.refreshIntervalSeconds,
           !stickers.isEmpty,
           !gifs.isEmpty {
            return
        }
        refreshCatalog(query: activeSearchQuery, force: false)
    }

    func refreshCatalog(query: String? = nil, force: Bool = true) {
        let trimmedQuery = (query ?? activeSearchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = trimmedQuery

        if !force, isRefreshing { return }
        refreshTask?.cancel()
        isRefreshing = true
        lastAddedCount = 0

        refreshTask = Task {
            let fetched = await Self.fetchLiveFeeds(query: trimmedQuery)
            guard !Task.isCancelled else { return }

            let mergedStickers = Self.mergeUnique(
                incoming: fetched.stickers,
                existing: trimmedQuery.isEmpty ? stickers : Self.seededStickers
            )
            let mergedGifs = Self.mergeUnique(
                incoming: fetched.gifs,
                existing: trimmedQuery.isEmpty ? gifs : Self.seededGifs
            )

            let existingIDs = Set(stickers.map(\.id) + gifs.map(\.id))
            let newDiscoveries = (fetched.stickers + fetched.gifs).filter { !existingIDs.contains($0.id) }.count

            stickers = mergedStickers
            gifs = mergedGifs
            lastAddedCount = newDiscoveries
            lastRefreshedAt = .now
            isRefreshing = false

            if newDiscoveries > 0 {
                statusText = "Refreshed • +\(newDiscoveries) new from TikTok"
            } else if !fetched.stickers.isEmpty || !fetched.gifs.isEmpty {
                statusText = "Up to date • \(mergedStickers.count) stickers, \(mergedGifs.count) GIFs"
            } else {
                statusText = "Showing cached TikTok stickers & GIFs"
            }

            if trimmedQuery.isEmpty {
                saveToDisk()
            }
        }
    }

    // MARK: - Live TikTok Feed Scraping (Official @TikTok Channel + GIPHY + Tenor)

    nonisolated private static func fetchLiveFeeds(query: String) async -> (stickers: [TikTokMediaAsset], gifs: [TikTokMediaAsset]) {
        let slug = query
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        var targetTasks: [(urlString: String, defaultKind: TikTokAssetKind, source: String, parser: FeedSourceKind)] = []

        if slug.isEmpty {
            targetTasks = [
                ("https://giphy.com/tiktok", .sticker, "@TikTok Official", .giphyHTML),
                ("https://giphy.com/tiktok/stickers", .sticker, "@TikTok Official", .giphyHTML),
                ("https://giphy.com/search/tiktok-stickers", .sticker, "GIPHY TikTok", .giphyHTML),
                ("https://giphy.com/search/tiktok-gifs", .gif, "GIPHY TikTok", .giphyHTML),
                ("https://tenor.com/search/tiktok-gifs", .gif, "Tenor TikTok", .tenorHTML)
            ]
        } else {
            targetTasks = [
                ("https://giphy.com/search/tiktok-\(slug)-stickers", .sticker, "GIPHY TikTok", .giphyHTML),
                ("https://giphy.com/search/tiktok-\(slug)-gifs", .gif, "GIPHY TikTok", .giphyHTML),
                ("https://giphy.com/search/\(slug)-tiktok", .gif, "GIPHY TikTok", .giphyHTML),
                ("https://tenor.com/search/tiktok-\(slug)-gifs", .gif, "Tenor TikTok", .tenorHTML)
            ]
        }

        var allStickers: [TikTokMediaAsset] = []
        var allGifs: [TikTokMediaAsset] = []

        await withTaskGroup(of: (stickers: [TikTokMediaAsset], gifs: [TikTokMediaAsset]).self) { group in
            for spec in targetTasks {
                group.addTask {
                    guard let url = URL(string: spec.urlString) else { return ([], []) }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 12
                    req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
                    req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse,
                          (200...299).contains(http.statusCode),
                          let html = String(data: data, encoding: .utf8) else {
                        return ([], [])
                    }

                    switch spec.parser {
                    case .giphyHTML:
                        return parseGiphyHTML(html, defaultKind: spec.defaultKind, sourceName: spec.source)
                    case .tenorHTML:
                        return ([], parseTenorHTML(html, sourceName: spec.source))
                    }
                }
            }

            for await batch in group {
                allStickers.append(contentsOf: batch.stickers)
                allGifs.append(contentsOf: batch.gifs)
            }
        }

        return (deduplicate(allStickers), deduplicate(allGifs))
    }

    private enum FeedSourceKind {
        case giphyHTML
        case tenorHTML
    }

    nonisolated private static func parseGiphyHTML(
        _ html: String,
        defaultKind: TikTokAssetKind,
        sourceName: String
    ) -> (stickers: [TikTokMediaAsset], gifs: [TikTokMediaAsset]) {
        var stickers: [TikTokMediaAsset] = []
        var gifs: [TikTokMediaAsset] = []
        let nowTS = Date().timeIntervalSince1970

        // 1. Parse structured anchor cards (<a href=".../stickers/..." data-giphy-id="ID" ...><img alt="TITLE">)
        if let anchorRegex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*href="([^"]*giphy\.com/(stickers|gifs)/[^"]*)"[^>]*data-giphy-id="([A-Za-z0-9]+)"[^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let altRegex = try? NSRegularExpression(pattern: #"alt="([^"]*)""#, options: [.caseInsensitive])
            let nsHTML = html as NSString
            for m in anchorRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
                guard m.numberOfRanges >= 5 else { continue }
                let hrefType = nsHTML.substring(with: m.range(at: 2)).lowercased()
                let giphyID = nsHTML.substring(with: m.range(at: 3))
                let inner = nsHTML.substring(with: m.range(at: 4))
                var title = "TikTok \(hrefType == "stickers" ? "Sticker" : "GIF")"
                if let altRegex,
                   let altMatch = altRegex.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)),
                   altMatch.numberOfRanges >= 2 {
                    let parsedTitle = (inner as NSString).substring(with: altMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !parsedTitle.isEmpty {
                        title = parsedTitle
                    }
                }
                let kind: TikTokAssetKind = (hrefType == "stickers") ? .sticker : .gif
                let asset = TikTokMediaAsset(
                    id: "giphy_\(giphyID)",
                    kind: kind,
                    title: title,
                    urlString: "https://media0.giphy.com/media/\(giphyID)/200w.gif",
                    sourceName: sourceName,
                    discoveredAt: nowTS
                )
                if kind == .sticker { stickers.append(asset) } else { gifs.append(asset) }
            }
        }

        // 2. Also pick up remaining media URLs embedded in Next Flight scripts
        if let mediaRegex = try? NSRegularExpression(
            pattern: #"https://media[0-9]*\.giphy\.com/media/(?:(v1\.[^/"']+)/)?([A-Za-z0-9]{10,24})/(?:200w|giphy)\.gif"#,
            options: []
        ) {
            let nsHTML = html as NSString
            for m in mediaRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
                guard m.numberOfRanges >= 3 else { continue }
                let tokenPart = m.range(at: 1).location != NSNotFound ? nsHTML.substring(with: m.range(at: 1)) : ""
                let giphyID = nsHTML.substring(with: m.range(at: 2))
                // Base64 "ct=cw" encodes as Y3Q9cw inside GIPHY v1 paths for transparent stickers
                let kind: TikTokAssetKind = tokenPart.contains("Y3Q9cw") ? .sticker : defaultKind
                let asset = TikTokMediaAsset(
                    id: "giphy_\(giphyID)",
                    kind: kind,
                    title: kind == .sticker ? "TikTok Sticker" : "TikTok GIF",
                    urlString: "https://media0.giphy.com/media/\(giphyID)/200w.gif",
                    sourceName: sourceName,
                    discoveredAt: nowTS
                )
                if kind == .sticker { stickers.append(asset) } else { gifs.append(asset) }
            }
        }

        return (stickers, gifs)
    }

    nonisolated private static func parseTenorHTML(_ html: String, sourceName: String) -> [TikTokMediaAsset] {
        guard let regex = try? NSRegularExpression(
            pattern: #"https://media\.tenor\.com/([A-Za-z0-9_-]+)AAAAM/([A-Za-z0-9_-]+)\.gif"#,
            options: []
        ) else {
            return []
        }

        let nsHTML = html as NSString
        let nowTS = Date().timeIntervalSince1970
        var results: [TikTokMediaAsset] = []

        for m in regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let urlStr = nsHTML.substring(with: m.range(at: 0))
            let tenorID = nsHTML.substring(with: m.range(at: 1))
            let rawSlug = nsHTML.substring(with: m.range(at: 2))
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            results.append(
                TikTokMediaAsset(
                    id: "tenor_\(tenorID)",
                    kind: .gif,
                    title: rawSlug.isEmpty ? "TikTok Reaction" : rawSlug,
                    urlString: urlStr,
                    sourceName: sourceName,
                    discoveredAt: nowTS
                )
            )
        }
        return Array(deduplicate(results).prefix(30))
    }

    nonisolated private static func deduplicate(_ list: [TikTokMediaAsset]) -> [TikTokMediaAsset] {
        var seen: Set<String> = []
        var out: [TikTokMediaAsset] = []
        for item in list {
            if seen.insert(item.id).inserted {
                out.append(item)
            }
        }
        return out
    }

    nonisolated private static func mergeUnique(incoming: [TikTokMediaAsset], existing: [TikTokMediaAsset]) -> [TikTokMediaAsset] {
        var seen: Set<String> = []
        var merged: [TikTokMediaAsset] = []
        for item in incoming + existing {
            if seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return Array(merged.prefix(60))
    }

    // MARK: - Persistence & Instant Seed

    private func loadFromDiskOrSeed() {
        if let data = try? Data(contentsOf: catalogFileURL),
           let decoded = try? JSONDecoder().decode(TikTokCatalogCacheFile.self, from: data),
           (!decoded.stickers.isEmpty || !decoded.gifs.isEmpty) {
            stickers = decoded.stickers
            gifs = decoded.gifs
            lastRefreshedAt = Date(timeIntervalSince1970: decoded.lastRefreshedAt)
            return
        }
        stickers = Self.seededStickers
        gifs = Self.seededGifs
    }

    private func saveToDisk() {
        let payload = TikTokCatalogCacheFile(
            stickers: stickers,
            gifs: gifs,
            lastRefreshedAt: (lastRefreshedAt ?? .now).timeIntervalSince1970
        )
        let url = catalogFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }

    private static let seededStickers: [TikTokMediaAsset] = [
        TikTokMediaAsset(id: "giphy_YkXIgPhR444jKUxbdl", kind: .sticker, title: "Arizona Baddie by TikTok", urlString: "https://media0.giphy.com/media/YkXIgPhR444jKUxbdl/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_elmOKf1oDu0H8RXYiP", kind: .sticker, title: "Thank You by TikTok", urlString: "https://media0.giphy.com/media/elmOKf1oDu0H8RXYiP/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_bGI74WsJNKkGc1zBcr", kind: .sticker, title: "Summer Sunglasses by TikTok", urlString: "https://media0.giphy.com/media/bGI74WsJNKkGc1zBcr/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_grpz5guG22hDKQPR3Z", kind: .sticker, title: "Singer by TikTok", urlString: "https://media0.giphy.com/media/grpz5guG22hDKQPR3Z/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_9pNOI8kvFQjLVzZyVc", kind: .sticker, title: "Spanish Chile by TikTok", urlString: "https://media0.giphy.com/media/9pNOI8kvFQjLVzZyVc/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_qZFMpMWTZMzIroHc69", kind: .sticker, title: "Free To Be Rainbow by TikTok", urlString: "https://media0.giphy.com/media/qZFMpMWTZMzIroHc69/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_l7ebWVz4mINbriGuCe", kind: .sticker, title: "TikTok Spark Sticker", urlString: "https://media0.giphy.com/media/l7ebWVz4mINbriGuCe/200w.gif", sourceName: "GIPHY TikTok", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_2xDatoOo8UIFOqRlOw", kind: .sticker, title: "Game On by TikTok", urlString: "https://media0.giphy.com/media/2xDatoOo8UIFOqRlOw/200w.gif", sourceName: "@TikTok Official", discoveredAt: 0)
    ]

    private static let seededGifs: [TikTokMediaAsset] = [
        TikTokMediaAsset(id: "giphy_LzpTazDmfT9IvGTZOf", kind: .gif, title: "TikTok Vibe Reaction", urlString: "https://media0.giphy.com/media/LzpTazDmfT9IvGTZOf/200w.gif", sourceName: "GIPHY TikTok", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_jS2pgTIhhTuAqneaF0", kind: .gif, title: "TikTok Dance Mood", urlString: "https://media0.giphy.com/media/jS2pgTIhhTuAqneaF0/200w.gif", sourceName: "GIPHY TikTok", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_sZrIqPw81LHEyCyn2q", kind: .gif, title: "TikTok Hype Moment", urlString: "https://media0.giphy.com/media/sZrIqPw81LHEyCyn2q/200w.gif", sourceName: "GIPHY TikTok", discoveredAt: 0),
        TikTokMediaAsset(id: "giphy_43wR1f8QU9KApWKjYt", kind: .gif, title: "Please / Pleading Reaction", urlString: "https://media0.giphy.com/media/43wR1f8QU9KApWKjYt/200w.gif", sourceName: "GIPHY TikTok", discoveredAt: 0),
        TikTokMediaAsset(id: "tenor_jm1-sKpAykQ", kind: .gif, title: "Bruh Really", urlString: "https://media.tenor.com/jm1-sKpAykQAAAAM/bruh-really.gif", sourceName: "Tenor TikTok", discoveredAt: 0),
        TikTokMediaAsset(id: "tenor_Y_LH4fKgpqA", kind: .gif, title: "TikTok Dance Meme", urlString: "https://media.tenor.com/Y_LH4fKgpqAAAAAM/tiktok-meme-tiktok.gif", sourceName: "Tenor TikTok", discoveredAt: 0)
    ]
}

// MARK: - Native 60fps Animated GIF/WebP Disk + Memory Cache View

private final class AnimatedImageCache {
    static let shared = AnimatedImageCache()
    let memory = NSCache<NSString, UIImage>()

    private var diskDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TikTokAnimatedMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func diskFileURL(for urlString: String) -> URL {
        let safe = urlString
            .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        return diskDir.appendingPathComponent(String(safe.suffix(80)) + ".dat")
    }

    func decodeAnimatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        if count == 1, let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cg)
        }

        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for idx in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, idx, nil) else { continue }
            let delay = frameDelay(source: source, index: idx)
            totalDuration += delay
            frames.append(UIImage(cgImage: cg))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(0.3, totalDuration))
    }

    private func frameDelay(source: CGImageSource, index: Int) -> Double {
        let defaultDelay = 0.08
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return defaultDelay
        }
        if let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            let val = (gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gifDict[kCGImagePropertyGIFDelayTime] as? Double)
            if let val, val > 0.015 { return val }
        }
        if let webpDict = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            let val = (webpDict[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? (webpDict[kCGImagePropertyWebPDelayTime] as? Double)
            if let val, val > 0.015 { return val }
        }
        return defaultDelay
    }
}

struct AnimatedTikTokImageView: View {
    let url: URL
    var contentMode: UIView.ContentMode = .scaleAspectFit

    @State private var animatedImage: UIImage?

    var body: some View {
        Group {
            if let animatedImage {
                UIKitAnimatedImageRepresentable(image: animatedImage, contentMode: contentMode)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.75))
            }
        }
        .task(id: url.absoluteString) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        let key = url.absoluteString as NSString
        if let cached = AnimatedImageCache.shared.memory.object(forKey: key) {
            animatedImage = cached
            return
        }

        let diskURL = AnimatedImageCache.shared.diskFileURL(for: url.absoluteString)
        if let diskData = try? Data(contentsOf: diskURL),
           let decoded = AnimatedImageCache.shared.decodeAnimatedImage(from: diskData) {
            AnimatedImageCache.shared.memory.setObject(decoded, forKey: key)
            animatedImage = decoded
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return
        }
        try? data.write(to: diskURL, options: [.atomic])
        let decoded = await Task.detached(priority: .userInitiated) {
            AnimatedImageCache.shared.decodeAnimatedImage(from: data)
        }.value
        if let decoded {
            AnimatedImageCache.shared.memory.setObject(decoded, forKey: key)
            animatedImage = decoded
        }
    }
}

private struct UIKitAnimatedImageRepresentable: UIViewRepresentable {
    let image: UIImage
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.clipsToBounds = true
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        iv.contentMode = contentMode
        iv.image = image
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode
        if uiView.image !== image {
            uiView.image = image
        }
    }
}
