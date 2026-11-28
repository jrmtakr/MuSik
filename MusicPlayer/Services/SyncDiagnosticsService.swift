import Foundation

/// Lightweight, thread-safe ring buffer of per-track Song ID, Lyrics selection, and Timing Alignment
/// diagnostics stored in Application Support (invisible in Files) for one-tap export in Settings.
final class SyncDiagnosticsService: @unchecked Sendable {
    static let shared = SyncDiagnosticsService()

    struct TrackEntry: Codable, Sendable {
        var relativePath: String
        var updatedAtISO: String
        var fileName: String
        var durationSeconds: Double?

        // Song ID
        var hintTitle: String?
        var hintArtist: String?
        var sourceVideoID: String?
        var sourcePlatform: String?
        var parsedSong: String?
        var parsedArtist: String?
        var parsedAlbum: String?
        var ytCaptionLanguage: String?
        var ytCards: [String] = []
        var catalogEvents: [String] = []
        var fastPathTaken: Bool?
        var finalTitle: String?
        var finalArtist: String?
        var finalAlbum: String?
        var finalSource: String?

        // Lyrics lookup & selection
        var lyricsCandidates: [String] = []
        var rejectedLyricsReasons: [String] = []
        var selectedLyricsSource: String?
        var selectedLyricsTitle: String?
        var selectedLyricsArtist: String?
        var selectedLyricsDuration: Double?
        var alignmentVersion: Int?
        var heardWordCount: Int?
        var lyricsFallback: String?
        var transcriptionRescue: String?

        // Sync accuracy: displayed lyric times vs where the speech model heard each line
        var syncMatchedLines: String?
        var syncMedianOffsetSeconds: Double?
        var syncP90OffsetSeconds: Double?
        var syncScoreSource: String?

        // Audio alignment & playback route
        var alignmentNote: String?
        var lineCount: Int?
        var sampleTimingLines: [String] = []
        var audioOutputRoute: String?
        var isUsingEqualizerBackend: Bool?
        var outputLatencySeconds: Double?
        var playbackBackend: String?
        var latencyCompensationSeconds: Double?
    }

    private struct ExportEnvelope: Codable {
        let exportedAtISO: String
        let appVersion: String
        let alignmentVersion: Int
        let trackCount: Int
        let tracks: [TrackEntry]
    }

    private let lock = NSLock()
    private let maxEntries = 50
    private var entries: [TrackEntry] = []

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync_diagnostics.json")
    }()

    private init() {
        loadFromDisk()
    }

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    func updateTrack(relativePath: String, fileName: String? = nil, mutate: (inout TrackEntry) -> Void) {
        lock.lock()
        let idx = entries.firstIndex(where: { $0.relativePath == relativePath })
        var entry = idx.map { entries.remove(at: $0) } ?? TrackEntry(
            relativePath: relativePath,
            updatedAtISO: Self.nowISO(),
            fileName: fileName ?? (relativePath as NSString).lastPathComponent
        )
        if let fileName, !fileName.isEmpty {
            entry.fileName = fileName
        }
        entry.updatedAtISO = Self.nowISO()
        mutate(&entry)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        let snapshot = entries
        lock.unlock()
        saveSnapshot(snapshot)
    }

    func entry(for relativePath: String) -> TrackEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first(where: { $0.relativePath == relativePath })
    }

    func recordCount() -> Int {
        lock.lock()
        let c = entries.count
        lock.unlock()
        return c
    }

    func clearAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: storageURL)
    }

    func exportDiagnosticsFileURL() -> URL? {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        let envelope = ExportEnvelope(
            exportedAtISO: Self.nowISO(),
            appVersion: version,
            alignmentVersion: SyncedLyricsService.currentAlignmentVersion,
            trackCount: snapshot.count,
            tracks: snapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return nil }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("musejrm-sync-diagnostics.json")
        do {
            try data.write(to: outURL, options: [.atomic])
            return outURL
        } catch {
            return nil
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TrackEntry].self, from: data) else { return }
        entries = Array(decoded.prefix(maxEntries))
    }

    private func saveSnapshot(_ snapshot: [TrackEntry]) {
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}
