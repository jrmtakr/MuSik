import Foundation
import Observation
import UIKit

struct OnlineMangaSeries: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let coverURL: URL?
    let thumbnailURL: URL?
    let authorName: String?
    let status: String?
    let year: Int?
    let tags: [String]
}

struct OnlineMangaChapter: Identifiable, Hashable, Sendable {
    let id: String
    let mangaID: String
    let volume: String?
    let chapterNumber: String?
    let title: String
    let pagesCount: Int
    let scanlationGroup: String?
    let externalURL: URL?

    var isReadableInApp: Bool {
        pagesCount > 0 && externalURL == nil
    }

    var displayLabel: String {
        let chPart: String = {
            if let chapterNumber, !chapterNumber.isEmpty {
                return "Ch. \(chapterNumber)"
            }
            return "Oneshot"
        }()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            return chPart
        }
        return "\(chPart) • \(cleanTitle)"
    }

    var numericSortValue: Double {
        chapterNumber.flatMap(Double.init) ?? 0
    }
}

/// Free online Manga server integration backed by MangaDex's public REST API (`api.mangadex.org`).
/// Provides catalog browsing, search, English chapter listing, page streaming in `ImageReaderView`,
/// and offline chapter saving into the local Documents manga library.
@MainActor
@Observable
final class MangaDexService {
    static let shared = MangaDexService()

    private static let apiBase = "https://api.mangadex.org"
    private static let uploadsBase = "https://uploads.mangadex.org"
    private static let userAgent = "MuseJRM/1.0 (https://github.com/jrmtakr/MuSik)"

    var popularManga: [OnlineMangaSeries] = []
    var recentManga: [OnlineMangaSeries] = []
    var searchResults: [OnlineMangaSeries] = []
    var isLoadingCatalog = false
    var isSearching = false
    var catalogError: String?

    @ObservationIgnored private var chaptersCache: [String: [OnlineMangaChapter]] = [:]
    @ObservationIgnored private var chapterPagesCache: [String: [URL]] = [:]

    private init() {}

    func loadCatalogIfNeeded(force: Bool = false) async {
        if !force && !popularManga.isEmpty && !recentManga.isEmpty {
            return
        }
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }

        async let popularTask = fetchMangaList(orderKey: "followedCount", query: nil, limit: 24)
        async let recentTask = fetchMangaList(orderKey: "latestUploadedChapter", query: nil, limit: 24)

        let (pop, rec) = await (popularTask, recentTask)
        if !pop.isEmpty {
            popularManga = pop
        }
        if !rec.isEmpty {
            recentManga = rec
        }
        if popularManga.isEmpty && recentManga.isEmpty {
            catalogError = "Could not connect to free Manga server. Pull to refresh or try again."
        }
    }

    func searchManga(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        searchResults = await fetchMangaList(orderKey: "relevance", query: trimmed, limit: 24)
    }

    func fetchChapters(for mangaID: String, forceRefresh: Bool = false) async -> [OnlineMangaChapter] {
        if !forceRefresh, let cached = chaptersCache[mangaID], !cached.isEmpty {
            return cached
        }

        var allChapters: [OnlineMangaChapter] = []
        var offset = 0
        let pageSize = 100

        while offset < 400 {
            var comps = URLComponents(string: "\(Self.apiBase)/manga/\(mangaID)/feed")
            comps?.queryItems = [
                URLQueryItem(name: "translatedLanguage[]", value: "en"),
                URLQueryItem(name: "order[chapter]", value: "asc"),
                URLQueryItem(name: "includes[]", value: "scanlation_group"),
                URLQueryItem(name: "contentRating[]", value: "safe"),
                URLQueryItem(name: "contentRating[]", value: "suggestive"),
                URLQueryItem(name: "contentRating[]", value: "erotica"),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            guard let url = comps?.url,
                  let root = await requestJSON(url: url),
                  let dataArr = root["data"] as? [[String: Any]],
                  !dataArr.isEmpty else {
                break
            }

            for item in dataArr {
                if let chapter = parseChapter(item, mangaID: mangaID) {
                    allChapters.append(chapter)
                }
            }

            if dataArr.count < pageSize {
                break
            }
            offset += pageSize
        }

        // Deduplicate multiple scanlations of the same chapter number while preferring hosted readable releases.
        let grouped = Dictionary(grouping: allChapters) { ch in
            ch.chapterNumber ?? ch.id
        }
        var picked: [OnlineMangaChapter] = []
        for (_, group) in grouped {
            if let hosted = group.first(where: \.isReadableInApp) {
                picked.append(hosted)
            } else if let first = group.first {
                picked.append(first)
            }
        }
        picked.sort {
            if $0.numericSortValue != $1.numericSortValue {
                return $0.numericSortValue < $1.numericSortValue
            }
            return $0.id < $1.id
        }

        chaptersCache[mangaID] = picked
        return picked
    }

    func fetchChapterPageURLs(chapterID: String, preferDataSaver: Bool = false) async -> [URL] {
        if let cached = chapterPagesCache[chapterID], !cached.isEmpty {
            return cached
        }
        guard let url = URL(string: "\(Self.apiBase)/at-home/server/\(chapterID)"),
              let root = await requestJSON(url: url),
              let baseURLStr = root["baseUrl"] as? String,
              let chapterObj = root["chapter"] as? [String: Any],
              let hash = chapterObj["hash"] as? String else {
            return []
        }

        let dataSaver = (chapterObj["dataSaver"] as? [String]) ?? []
        let fullData = (chapterObj["data"] as? [String]) ?? []

        let useSaver = preferDataSaver ? !dataSaver.isEmpty : fullData.isEmpty
        let folder = useSaver ? "data-saver" : "data"
        let files = useSaver ? dataSaver : fullData

        let cleanBase = baseURLStr.hasSuffix("/") ? String(baseURLStr.dropLast()) : baseURLStr
        let pageURLs = files.compactMap { fileName -> URL? in
            let encodedFile = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
            return URL(string: "\(cleanBase)/\(folder)/\(hash)/\(encodedFile)")
        }

        if !pageURLs.isEmpty {
            chapterPagesCache[chapterID] = pageURLs
        }
        return pageURLs
    }

    /// Downloads an online MangaDex chapter's pages into `<Documents>/Manga/<Title>/<Chapter>/`
    /// so the user can read it offline inside the existing Manga library anytime.
    func downloadChapterOffline(
        manga: OnlineMangaSeries,
        chapter: OnlineMangaChapter,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> [LocalFile] {
        let pageURLs = await fetchChapterPageURLs(chapterID: chapter.id, preferDataSaver: false)
        guard !pageURLs.isEmpty else { return [] }

        let safeSeries = sanitizePathComponent(manga.title)
        let chSuffix = chapter.chapterNumber.map { "Chapter \($0)" } ?? "Oneshot"
        let safeChapter = sanitizePathComponent(chSuffix)

        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let targetDir = docsDir
            .appendingPathComponent("Manga", isDirectory: true)
            .appendingPathComponent(safeSeries, isDirectory: true)
            .appendingPathComponent(safeChapter, isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        var completed = 0
        let total = pageURLs.count
        for (idx, pageURL) in pageURLs.enumerated() {
            if Task.isCancelled { break }
            let ext = pageURL.pathExtension.isEmpty ? "jpg" : pageURL.pathExtension.lowercased()
            let fileName = String(format: "page_%03d.%@", idx + 1, ext)
            let dest = targetDir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: dest.path) {
                var req = URLRequest(url: pageURL)
                req.timeoutInterval = 20
                req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("https://mangadex.org/", forHTTPHeaderField: "Referer")
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   !data.isEmpty {
                    try? data.write(to: dest, options: [.atomic])
                }
            }
            completed += 1
            onProgress(Double(completed) / Double(max(1, total)))
        }

        MediaManager.shared.loadLocalFiles()
        let folderRel = "Manga/\(safeSeries)/\(safeChapter)"
        return MediaManager.shared.imagesRecursive(inFolder: folderRel)
    }

    // MARK: - Networking & Parsing

    private func fetchMangaList(orderKey: String, query: String?, limit: Int) async -> [OnlineMangaSeries] {
        var comps = URLComponents(string: "\(Self.apiBase)/manga")
        var items = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "availableTranslatedLanguage[]", value: "en"),
            URLQueryItem(name: "hasAvailableChapters", value: "true"),
            URLQueryItem(name: "includes[]", value: "cover_art"),
            URLQueryItem(name: "includes[]", value: "author"),
            URLQueryItem(name: "contentRating[]", value: "safe"),
            URLQueryItem(name: "contentRating[]", value: "suggestive")
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "title", value: query))
            items.append(URLQueryItem(name: "order[relevance]", value: "desc"))
        } else {
            items.append(URLQueryItem(name: "order[\(orderKey)]", value: "desc"))
        }
        comps?.queryItems = items

        guard let url = comps?.url,
              let root = await requestJSON(url: url),
              let dataArr = root["data"] as? [[String: Any]] else {
            return []
        }

        return dataArr.compactMap(parseManga)
    }

    private func requestJSON(url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func parseManga(_ raw: [String: Any]) -> OnlineMangaSeries? {
        guard let id = raw["id"] as? String,
              let attrs = raw["attributes"] as? [String: Any] else {
            return nil
        }

        let titleDict = attrs["title"] as? [String: String] ?? [:]
        let altTitles = attrs["altTitles"] as? [[String: String]] ?? []
        let pickedTitle = titleDict["en"]
            ?? altTitles.first(where: { $0["en"] != nil })?["en"]
            ?? titleDict.values.first
            ?? ""
        let cleanTitle = pickedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        let descDict = attrs["description"] as? [String: String] ?? [:]
        let cleanDesc = (descDict["en"] ?? descDict.values.first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rels = raw["relationships"] as? [[String: Any]] ?? []
        var coverFileName: String?
        var authorName: String?
        for rel in rels {
            let type = rel["type"] as? String
            let relAttrs = rel["attributes"] as? [String: Any]
            if type == "cover_art", let fn = relAttrs?["fileName"] as? String, !fn.isEmpty {
                coverFileName = fn
            } else if type == "author", let name = relAttrs?["name"] as? String, !name.isEmpty {
                authorName = name
            }
        }

        let thumbURL = coverFileName.flatMap { URL(string: "\(Self.uploadsBase)/covers/\(id)/\($0).256.jpg") }
        let fullCoverURL = coverFileName.flatMap { URL(string: "\(Self.uploadsBase)/covers/\(id)/\($0).512.jpg") }

        let tagObjs = attrs["tags"] as? [[String: Any]] ?? []
        let tags: [String] = tagObjs.prefix(5).compactMap { obj in
            let tagAttrs = obj["attributes"] as? [String: Any]
            let names = tagAttrs?["name"] as? [String: String]
            return names?["en"] ?? names?.values.first
        }

        return OnlineMangaSeries(
            id: id,
            title: cleanTitle,
            description: cleanDesc,
            coverURL: fullCoverURL,
            thumbnailURL: thumbURL,
            authorName: authorName,
            status: (attrs["status"] as? String)?.capitalized,
            year: attrs["year"] as? Int,
            tags: tags
        )
    }

    private func parseChapter(_ raw: [String: Any], mangaID: String) -> OnlineMangaChapter? {
        guard let id = raw["id"] as? String,
              let attrs = raw["attributes"] as? [String: Any] else {
            return nil
        }
        let chNum = attrs["chapter"] as? String
        let vol = attrs["volume"] as? String
        let title = (attrs["title"] as? String) ?? ""
        let pages = (attrs["pages"] as? NSNumber)?.intValue ?? 0
        let extURL = (attrs["externalUrl"] as? String).flatMap(URL.init(string:))

        let rels = raw["relationships"] as? [[String: Any]] ?? []
        let groupName = rels.first(where: { ($0["type"] as? String) == "scanlation_group" })
            .flatMap { ($0["attributes"] as? [String: Any])?["name"] as? String }

        return OnlineMangaChapter(
            id: id,
            mangaID: mangaID,
            volume: vol,
            chapterNumber: chNum,
            title: title,
            pagesCount: pages,
            scanlationGroup: groupName,
            externalURL: extURL
        )
    }

    private func sanitizePathComponent(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = raw.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Manga" : String(clean.prefix(64))
    }
}
