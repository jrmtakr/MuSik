import AVFoundation
import Foundation
import Observation

struct LyricWordTiming: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let text: String
    let startTime: Double
    let endTime: Double

    init(id: UUID = UUID(), text: String, startTime: Double, endTime: Double) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct SyncedLyricLine: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startTime: Double
    var endTime: Double
    let text: String
    var words: [LyricWordTiming]
    let isInstrumentalBreak: Bool

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        text: String,
        words: [LyricWordTiming] = [],
        isInstrumentalBreak: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
        self.isInstrumentalBreak = isInstrumentalBreak
    }
}

struct ResolvedTrackLyrics: Codable, Sendable {
    let cacheKey: String
    let trackTitle: String
    let artistName: String
    let isTimeSynced: Bool
    let sourceLabel: String
    let attributionText: String?
    var syncedOffsetSeconds: Double
    let lines: [SyncedLyricLine]
}

@MainActor
@Observable
final class SyncedLyricsService {
    static let shared = SyncedLyricsService()

    var currentLyrics: ResolvedTrackLyrics?
    var currentLoadingKey: String?
    var lastError: String?

    @ObservationIgnored private var memoryCache: [String: ResolvedTrackLyrics] = [:]
    @ObservationIgnored private var activeFetchTask: Task<Void, Never>?

    private static var cacheDirectoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    func cacheKey(for item: MediaItem, artistOverride: String? = nil, titleOverride: String? = nil) -> String {
        let rawTitle = (titleOverride?.isEmpty == false ? titleOverride! : item.displayTitle)
        let rawArtist = (artistOverride?.isEmpty == false ? artistOverride! : (item.artist ?? ""))
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: rawTitle, rawArtistTag: rawArtist)
        let keyBase = "\(cleaned.artistHint ?? rawArtist)|\(cleaned.songOnly)|\(item.fileName)"
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return keyBase.isEmpty ? UUID().uuidString : String(keyBase.prefix(100))
    }

    func loadLyricsIfNeeded(for item: MediaItem, forceReload: Bool = false, customTitle: String? = nil, customArtist: String? = nil) {
        let key = cacheKey(for: item, artistOverride: customArtist, titleOverride: customTitle)

        if !forceReload {
            if currentLyrics?.cacheKey == key { return }
            if let inMem = memoryCache[key] {
                currentLyrics = inMem
                lastError = nil
                return
            }
            if let disk = loadFromDisk(key: key) {
                memoryCache[key] = disk
                currentLyrics = disk
                lastError = nil
                return
            }
        }

        activeFetchTask?.cancel()
        currentLoadingKey = key
        lastError = nil
        if forceReload || currentLyrics?.cacheKey != key {
            currentLyrics = nil
        }

        activeFetchTask = Task {
            let resolved = await fetchBestLyrics(
                item: item,
                cacheKey: key,
                customTitle: customTitle,
                customArtist: customArtist
            )
            guard !Task.isCancelled else { return }
            currentLoadingKey = nil
            if let resolved {
                memoryCache[key] = resolved
                saveToDisk(resolved)
                currentLyrics = resolved
                lastError = nil
            } else {
                lastError = "No synced or plain lyrics found for this track."
            }
        }
    }

    func adjustTimingOffset(by delta: Double) {
        guard var lyrics = currentLyrics, lyrics.isTimeSynced else { return }
        lyrics.syncedOffsetSeconds = (delta == 0) ? 0 : (lyrics.syncedOffsetSeconds + delta)
        currentLyrics = lyrics
        memoryCache[lyrics.cacheKey] = lyrics
        saveToDisk(lyrics)
    }

    func resetTimingOffset() {
        adjustTimingOffset(by: 0)
    }

    // MARK: - Multi-Source Fetching

    private func fetchBestLyrics(
        item: MediaItem,
        cacheKey: String,
        customTitle: String?,
        customArtist: String?
    ) async -> ResolvedTrackLyrics? {
        let rawTitle = (customTitle?.isEmpty == false ? customTitle! : item.displayTitle)
        let rawArtist = (customArtist?.isEmpty == false ? customArtist! : (item.artist ?? ""))

        let split = splitArtistAndSong(rawTitle: rawTitle, rawArtist: rawArtist)
        let song = split.song
        let artist = split.artist
        let duration = item.durationSeconds

        // 1. Offline: Sidecar .lrc or Embedded metadata lyrics inside file
        if !item.relativePath.hasPrefix("__remote__/") {
            if let offline = await loadOfflineEmbeddedOrSidecarLyrics(item: item, cacheKey: cacheKey, title: song, artist: artist) {
                return offline
            }
        }

        // 2. Online: LRCLIB Time-Synced LRC
        if let lrclib = await fetchFromLRCLIB(
            cacheKey: cacheKey,
            song: song,
            artist: artist,
            rawTitle: rawTitle,
            duration: duration
        ) {
            return lrclib
        }

        // 3. Fallback: Genius Native HTML Lyrics Extraction
        if let genius = await fetchFromGenius(
            cacheKey: cacheKey,
            song: song,
            artist: artist
        ) {
            return genius
        }

        return nil
    }

    private func loadOfflineEmbeddedOrSidecarLyrics(
        item: MediaItem,
        cacheKey: String,
        title: String,
        artist: String
    ) async -> ResolvedTrackLyrics? {
        // Check sidecar .lrc file
        let lrcURL = item.fileURL.deletingPathExtension().appendingPathExtension("lrc")
        if let lrcText = try? String(contentsOf: lrcURL, encoding: .utf8),
           !lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: lrcText, duration: item.durationSeconds)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: title,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Local .LRC Synced" : "Local .LRC",
                    attributionText: "Loaded from offline .lrc file",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }

        // Check AVURLAsset embedded lyrics
        let asset = AVURLAsset(url: item.fileURL)
        if let embedded = try? await asset.load(.lyrics),
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: embedded, duration: item.durationSeconds)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: title,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Embedded Synced" : "Embedded Lyrics",
                    attributionText: "Embedded in audio file",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }
        return nil
    }

    // MARK: - LRCLIB Synced Lyrics

    private struct LRCLIBCandidate {
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
        let score: Int
    }

    private func fetchFromLRCLIB(
        cacheKey: String,
        song: String,
        artist: String,
        rawTitle: String,
        duration: Double?
    ) async -> ResolvedTrackLyrics? {
        // Fast exact match endpoint first
        if !artist.isEmpty, let dur = duration, dur > 5 {
            var comps = URLComponents(string: "https://lrclib.net/api/get")
            comps?.queryItems = [
                URLQueryItem(name: "track_name", value: song),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "duration", value: String(Int(round(dur))))
            ]
            if let url = comps?.url,
               let row = await fetchSingleLRCLIBObject(url: url),
               let built = buildLyricsFromLRCLIBRow(row, cacheKey: cacheKey, duration: duration) {
                return built
            }
        }

        // Search endpoints
        var allCandidates: [LRCLIBCandidate] = []
        var queries: [URL] = []

        if !artist.isEmpty {
            var c1 = URLComponents(string: "https://lrclib.net/api/search")
            c1?.queryItems = [
                URLQueryItem(name: "track_name", value: song),
                URLQueryItem(name: "artist_name", value: artist)
            ]
            if let u = c1?.url { queries.append(u) }
        }

        let combined = [artist, song].filter { !$0.isEmpty }.joined(separator: " ")
        if !combined.isEmpty {
            var c2 = URLComponents(string: "https://lrclib.net/api/search")
            c2?.queryItems = [URLQueryItem(name: "q", value: combined)]
            if let u = c2?.url { queries.append(u) }
        }

        let cleanedRaw = Self.stripNoisyTitleTokens(rawTitle)
        if !cleanedRaw.isEmpty && cleanedRaw.lowercased() != combined.lowercased() {
            var c3 = URLComponents(string: "https://lrclib.net/api/search")
            c3?.queryItems = [URLQueryItem(name: "q", value: cleanedRaw)]
            if let u = c3?.url { queries.append(u) }
        }

        for url in queries {
            let rows = await fetchLRCLIBSearchArray(url: url)
            for row in rows {
                let candidate = scoreLRCLIBRow(row, targetSong: song, targetArtist: artist, targetDuration: duration)
                if candidate.score > 10 {
                    allCandidates.append(candidate)
                }
            }
            if allCandidates.contains(where: { !($0.syncedLyrics?.isEmpty ?? true) && $0.score >= 70 }) {
                break
            }
        }

        guard let best = allCandidates.max(by: { $0.score < $1.score }) else { return nil }

        if let synced = best.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: synced, duration: duration ?? best.duration)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: best.trackName,
                    artistName: best.artistName,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Synced Lyrics" : "Lyrics",
                    attributionText: "Time-synced via LRCLIB",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }

        if let plain = best.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: plain, duration: duration ?? best.duration)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: best.trackName,
                    artistName: best.artistName,
                    isTimeSynced: false,
                    sourceLabel: "Plain Lyrics",
                    attributionText: "Lyrics via LRCLIB",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }

        return nil
    }

    private func fetchSingleLRCLIBObject(url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("MuSeJRM/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func fetchLRCLIBSearchArray(url: URL) async -> [[String: Any]] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MuSeJRM/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Array(rows.prefix(15))
    }

    private func buildLyricsFromLRCLIBRow(_ row: [String: Any], cacheKey: String, duration: Double?) -> ResolvedTrackLyrics? {
        let track = (row["trackName"] as? String) ?? ""
        let artist = (row["artistName"] as? String) ?? ""
        let dur = row["duration"] as? Double
        if let synced = row["syncedLyrics"] as? String, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: synced, duration: duration ?? dur)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: track,
                    artistName: artist,
                    isTimeSynced: parsed.isSynced,
                    sourceLabel: parsed.isSynced ? "Synced Lyrics" : "Lyrics",
                    attributionText: "Time-synced via LRCLIB",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }
        if let plain = row["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = Self.parseLRCOrPlain(text: plain, duration: duration ?? dur)
            if !parsed.lines.isEmpty {
                return ResolvedTrackLyrics(
                    cacheKey: cacheKey,
                    trackTitle: track,
                    artistName: artist,
                    isTimeSynced: false,
                    sourceLabel: "Plain Lyrics",
                    attributionText: "Lyrics via LRCLIB",
                    syncedOffsetSeconds: 0,
                    lines: parsed.lines
                )
            }
        }
        return nil
    }

    private func scoreLRCLIBRow(
        _ row: [String: Any],
        targetSong: String,
        targetArtist: String,
        targetDuration: Double?
    ) -> LRCLIBCandidate {
        let trackName = (row["trackName"] as? String) ?? ""
        let artistName = (row["artistName"] as? String) ?? ""
        let synced = row["syncedLyrics"] as? String
        let plain = row["plainLyrics"] as? String
        let dur = row["duration"] as? Double
        let isInstrumental = (row["instrumental"] as? Bool) == true

        var score = 0
        if let synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 65
        } else if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 20
        } else if isInstrumental {
            return LRCLIBCandidate(trackName: trackName, artistName: artistName, albumName: nil, duration: dur, syncedLyrics: nil, plainLyrics: nil, score: -100)
        }

        let normTargetSong = Self.normalizeComparable(targetSong)
        let normHitSong = Self.normalizeComparable(trackName)
        if normHitSong == normTargetSong { score += 45 }
        else if !normTargetSong.isEmpty && (normHitSong.contains(normTargetSong) || normTargetSong.contains(normHitSong)) { score += 25 }

        let normTargetArtist = Self.normalizeComparable(targetArtist)
        let normHitArtist = Self.normalizeComparable(artistName)
        if !normTargetArtist.isEmpty {
            if normHitArtist == normTargetArtist { score += 40 }
            else if normHitArtist.contains(normTargetArtist) || normTargetArtist.contains(normHitArtist) { score += 22 }
            else { score -= 15 }
        }

        if let targetDuration, let dur, targetDuration > 5 {
            let diff = abs(targetDuration - dur)
            if diff <= 2.5 { score += 35 }
            else if diff <= 6.0 { score += 20 }
            else if diff > 25.0 { score -= 25 }
        }

        return LRCLIBCandidate(
            trackName: trackName,
            artistName: artistName,
            albumName: row["albumName"] as? String,
            duration: dur,
            syncedLyrics: synced,
            plainLyrics: plain,
            score: score
        )
    }

    // MARK: - Genius Clean Plain Lyrics Fallback

    private func fetchFromGenius(
        cacheKey: String,
        song: String,
        artist: String
    ) async -> ResolvedTrackLyrics? {
        let query = [artist, song].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://genius.com/api/search/multi?q=\(encoded)&per_page=5") else {
            return nil
        }

        var req = URLRequest(url: searchURL)
        req.timeoutInterval = 10
        req.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = (json["response"] as? [String: Any])?["sections"] as? [[String: Any]] else {
            return nil
        }

        var bestURL: URL?
        var bestTitle = song
        var bestArtist = artist
        var bestScore = -1

        let normSong = Self.normalizeComparable(song)
        let normArtist = Self.normalizeComparable(artist)

        for section in sections {
            let sType = (section["type"] as? String) ?? ""
            guard sType == "song" || sType == "top_hit",
                  let hits = section["hits"] as? [[String: Any]] else { continue }
            for hit in hits {
                guard (hit["type"] as? String) == "song",
                      let result = hit["result"] as? [String: Any],
                      let urlStr = result["url"] as? String,
                      let url = URL(string: urlStr) else { continue }
                let hTitle = (result["title"] as? String) ?? ""
                let hArtist = (result["artist_names"] as? String) ?? ""
                var s = 0
                if Self.normalizeComparable(hTitle) == normSong { s += 50 }
                else if Self.normalizeComparable(hTitle).contains(normSong) { s += 25 }
                if !normArtist.isEmpty && Self.normalizeComparable(hArtist).contains(normArtist) { s += 40 }
                if s > bestScore {
                    bestScore = s
                    bestURL = url
                    bestTitle = hTitle
                    bestArtist = hArtist
                }
            }
        }

        guard let targetURL = bestURL else { return nil }
        var pageReq = URLRequest(url: targetURL)
        pageReq.timeoutInterval = 12
        pageReq.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (htmlData, pageResp) = try? await URLSession.shared.data(for: pageReq),
              let pageHTTP = pageResp as? HTTPURLResponse,
              (200...299).contains(pageHTTP.statusCode),
              let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }

        guard let plain = Self.extractGeniusLyricsText(fromHTML: html),
              !plain.isEmpty else {
            return nil
        }

        let parsed = Self.parseLRCOrPlain(text: plain, duration: nil)
        guard !parsed.lines.isEmpty else { return nil }

        return ResolvedTrackLyrics(
            cacheKey: cacheKey,
            trackTitle: bestTitle,
            artistName: bestArtist,
            isTimeSynced: false,
            sourceLabel: "Plain Lyrics",
            attributionText: "Lyrics via Genius",
            syncedOffsetSeconds: 0,
            lines: parsed.lines
        )
    }

    // MARK: - LRC + Word Timing Parser

    static func parseLRCOrPlain(text: String, duration: Double?) -> (isSynced: Bool, lines: [SyncedLyricLine]) {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalizedText.components(separatedBy: "\n")

        let timestampRegex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#)
        let enhancedWordRegex = try? NSRegularExpression(pattern: #"<(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?>([^<]*)"#)
        let metaTagRegex = try? NSRegularExpression(pattern: #"^\[(ti|ar|al|au|by|re|ve|length|offset):([^\]]*)\]$"#, options: .caseInsensitive)

        var offsetMs: Double = 0
        var timedEntries: [(time: Double, rawBody: String)] = []

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let metaTagRegex,
               let m = metaTagRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let tagRange = Range(m.range(at: 1), in: trimmed),
               let valRange = Range(m.range(at: 2), in: trimmed) {
                if trimmed[tagRange].lowercased() == "offset",
                   let parsedOffset = Double(trimmed[valRange].trimmingCharacters(in: .whitespaces)) {
                    offsetMs = parsedOffset
                }
                continue
            }

            guard let timestampRegex else { continue }
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = timestampRegex.matches(in: trimmed, range: nsRange)
            guard !matches.isEmpty else { continue }

            let lastEnd = matches.last!.range.upperBound
            let bodyStartIdx = trimmed.index(trimmed.startIndex, offsetBy: lastEnd)
            let bodyText = String(trimmed[bodyStartIdx...]).trimmingCharacters(in: .whitespaces)

            for m in matches {
                if let t = parseTimestampMatch(m, in: trimmed) {
                    timedEntries.append((max(0, t - offsetMs / 1000.0), bodyText))
                }
            }
        }

        if !timedEntries.isEmpty {
            timedEntries.sort { $0.time < $1.time }

            var built: [SyncedLyricLine] = []

            // Optional intro interlude dots when first lyric starts > 5.5s into the song
            if let first = timedEntries.first, first.time > 5.5, !first.rawBody.isEmpty {
                built.append(
                    SyncedLyricLine(
                        startTime: 0.4,
                        endTime: max(1.0, first.time - 0.35),
                        text: "",
                        words: [],
                        isInstrumentalBreak: true
                    )
                )
            }

            for i in 0..<timedEntries.count {
                let entry = timedEntries[i]
                let nextTime: Double = {
                    if i + 1 < timedEntries.count {
                        return max(entry.time + 0.4, timedEntries[i + 1].time)
                    }
                    if let duration, duration > entry.time + 0.5 {
                        return duration
                    }
                    return entry.time + 4.0
                }()

                let cleanPlain = stripEnhancedTimestamps(entry.rawBody)
                if cleanPlain.isEmpty {
                    // Explicit blank instrumental line in LRC if gap >= 3.2s
                    if nextTime - entry.time >= 3.2,
                       !(built.last?.isInstrumentalBreak ?? false) {
                        built.append(
                            SyncedLyricLine(
                                startTime: entry.time,
                                endTime: max(entry.time + 0.6, nextTime - 0.25),
                                text: "",
                                words: [],
                                isInstrumentalBreak: true
                            )
                        )
                    }
                    continue
                }

                let wordTimings: [LyricWordTiming]
                if let enhancedWordRegex,
                   let parsedEnhanced = parseEnhancedWords(
                       in: entry.rawBody,
                       lineStart: entry.time,
                       lineEnd: nextTime,
                       regex: enhancedWordRegex
                   ),
                   !parsedEnhanced.isEmpty {
                    wordTimings = parsedEnhanced
                } else {
                    wordTimings = synthesizeProportionalWordTimings(
                        text: cleanPlain,
                        lineStart: entry.time,
                        lineEnd: min(nextTime, entry.time + max(2.2, Double(cleanPlain.count) * 0.085))
                    )
                }

                // Cap vocal highlight end slightly before long pauses and inject Apple Music instrumental break dots
                let vocalGap = nextTime - entry.time
                let lineEndTime = vocalGap > 8.5 ? entry.time + min(5.5, max(2.8, Double(cleanPlain.count) * 0.08)) : nextTime

                built.append(
                    SyncedLyricLine(
                        startTime: entry.time,
                        endTime: lineEndTime,
                        text: cleanPlain,
                        words: wordTimings,
                        isInstrumentalBreak: false
                    )
                )

                if vocalGap > 8.5 && i + 1 < timedEntries.count {
                    let breakStart = lineEndTime + 0.3
                    let breakEnd = max(breakStart + 1.0, nextTime - 0.35)
                    if breakEnd > breakStart + 1.0 {
                        built.append(
                            SyncedLyricLine(
                                startTime: breakStart,
                                endTime: breakEnd,
                                text: "",
                                words: [],
                                isInstrumentalBreak: true
                            )
                        )
                    }
                }
            }

            return (true, built)
        }

        // Plain / Unsynced fallback
        let plainLines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                SyncedLyricLine(startTime: -1, endTime: -1, text: $0, words: [], isInstrumentalBreak: false)
            }
        return (false, plainLines)
    }

    private static func parseTimestampMatch(_ match: NSTextCheckingResult, in text: String) -> Double? {
        guard let minRange = Range(match.range(at: 1), in: text),
              let secRange = Range(match.range(at: 2), in: text),
              let mins = Double(text[minRange]),
              let secs = Double(text[secRange]) else {
            return nil
        }
        var frac = 0.0
        if match.range(at: 3).location != NSNotFound,
           let fracRange = Range(match.range(at: 3), in: text) {
            let digits = String(text[fracRange])
            if let raw = Double(digits) {
                frac = digits.count >= 3 ? raw / 1000.0 : raw / 100.0
            }
        }
        return mins * 60.0 + secs + frac
    }

    private static func stripEnhancedTimestamps(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"<\d{1,3}:\d{2}(?:[\.:]\d{1,3})?>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseEnhancedWords(
        in raw: String,
        lineStart: Double,
        lineEnd: Double,
        regex: NSRegularExpression
    ) -> [LyricWordTiming]? {
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard !matches.isEmpty else { return nil }

        var rawItems: [(time: Double, word: String)] = []
        for m in matches {
            guard let t = parseTimestampMatch(m, in: raw),
                  let textRange = Range(m.range(at: 4), in: raw) else { continue }
            let token = String(raw[textRange]).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty {
                rawItems.append((max(lineStart, t), token))
            }
        }
        guard !rawItems.isEmpty else { return nil }

        var words: [LyricWordTiming] = []
        for i in 0..<rawItems.count {
            let start = rawItems[i].time
            let end = (i + 1 < rawItems.count) ? max(start + 0.08, rawItems[i + 1].time) : max(start + 0.25, lineEnd)
            words.append(LyricWordTiming(text: rawItems[i].word, startTime: start, endTime: end))
        }
        return words
    }

    private static func synthesizeProportionalWordTimings(
        text: String,
        lineStart: Double,
        lineEnd: Double
    ) -> [LyricWordTiming] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(0.35, lineEnd - lineStart)

        let weights: [Double] = tokens.map { token in
            var w = Double(max(2, token.count))
            if token.hasSuffix(",") || token.hasSuffix(";") { w += 1.5 }
            if token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?") { w += 2.2 }
            return w
        }
        let totalWeight = max(1.0, weights.reduce(0, +))
        var cursor = lineStart
        var result: [LyricWordTiming] = []

        for (idx, token) in tokens.enumerated() {
            let dur = span * (weights[idx] / totalWeight)
            let wordEnd = (idx == tokens.count - 1) ? lineEnd : (cursor + dur)
            result.append(LyricWordTiming(text: token, startTime: cursor, endTime: wordEnd))
            cursor = wordEnd
        }
        return result
    }

    // MARK: - Helpers & Genius HTML Extraction

    private func splitArtistAndSong(rawTitle: String, rawArtist: String) -> (song: String, artist: String) {
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(rawTitle: rawTitle, rawArtistTag: rawArtist)
        var song = Self.stripNoisyTitleTokens(cleaned.songOnly)
        var artist = Self.stripNoisyArtistTokens(cleaned.artistHint ?? rawArtist)

        for sep in [" - ", " — ", " – ", " | "] {
            if artist.isEmpty, let range = song.range(of: sep) {
                let left = String(song[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(song[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    artist = Self.stripNoisyArtistTokens(left)
                    song = Self.stripNoisyTitleTokens(right)
                    break
                }
            }
        }
        return (song.isEmpty ? rawTitle : song, artist)
    }

    private static func stripNoisyTitleTokens(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s*[\(\[]\s*(?:official|lyrics?|lyric video|audio|video|visualizer|mv|m/v|hd|4k|explicit|clean|remaster(?:ed)?(?:\s*\d{4})?)[^\)\]]*[\)\]]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"\s*[\(\[]\s*(?:feat|ft|featuring)\.?\s+[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripNoisyArtistTokens(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: " - Topic", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "VEVO", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ","), !s[..<comma].isEmpty {
            s = String(s[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func normalizeComparable(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractGeniusLyricsText(fromHTML html: String) -> String? {
        guard let containerRegex = try? NSRegularExpression(
            pattern: #"<div[^>]*data-lyrics-container="true"[^>]*>([\s\S]*?)</div>"#,
            options: .caseInsensitive
        ) else {
            return nil
        }
        let matches = containerRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var chunks: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            var snippet = String(html[range])
            snippet = snippet.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            snippet = snippet.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            snippet = decodeHTMLEntities(snippet)
            chunks.append(snippet)
        }
        let joined = chunks.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Disk Persistence

    private func loadFromDisk(key: String) -> ResolvedTrackLyrics? {
        let url = Self.cacheDirectoryURL.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResolvedTrackLyrics.self, from: data)
    }

    private func saveToDisk(_ lyrics: ResolvedTrackLyrics) {
        let url = Self.cacheDirectoryURL.appendingPathComponent("\(lyrics.cacheKey).json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(lyrics) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }
}
