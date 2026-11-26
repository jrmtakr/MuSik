import Compression
import Foundation
import Observation

struct LibraryBackupSummary: Sendable {
    var mediaCount: Int
    var audioCount: Int
    var videoCount: Int
    var playlistCount: Int
    var otherFileCount: Int
    var totalBytes: Int64

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

struct LibraryBackupManifest: Codable, Sendable {
    let formatVersion: Int
    let appName: String
    let createdAt: Date
    let mediaCount: Int
    let playlistCount: Int
    let totalBytes: Int64
}

enum BackupRestoreMode: String, CaseIterable, Identifiable {
    case merge = "Merge (Keep Existing)"
    case replace = "Replace Library"

    var id: String { rawValue }
}

@MainActor
@Observable
final class LibraryBackupService {
    static let shared = LibraryBackupService()

    var isWorking = false
    var isBackingUp = false
    var isRestoring = false
    var progress: Double = 0
    var statusText: String = ""
    var completedFiles = 0
    var totalFiles = 0
    var processedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var lastError: String?
    var latestBackupURL: URL?

    var lastBackupDate: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: Self.lastBackupDateKey)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.lastBackupDateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastBackupDateKey)
            }
        }
    }

    var lastBackupDetails: String? {
        get { UserDefaults.standard.string(forKey: Self.lastBackupDetailsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastBackupDetailsKey) }
    }

    @ObservationIgnored private var activeTask: Task<Void, Never>?

    private static let lastBackupDateKey = "musicplayer.backup.lastDate"
    private static let lastBackupDetailsKey = "musicplayer.backup.lastDetails"

    private init() {}

    // MARK: - Current Library Stats

    func currentSummary() -> LibraryBackupSummary {
        let mm = MediaManager.shared
        let total = mm.items.reduce(Int64(0)) { $0 + $1.fileSize }
            + mm.otherFiles.reduce(Int64(0)) { $0 + $1.fileSize }
        let videos = mm.items.filter(\.isVideo).count
        let audios = mm.items.count - videos
        return LibraryBackupSummary(
            mediaCount: mm.items.count,
            audioCount: audios,
            videoCount: videos,
            playlistCount: mm.playlists.count,
            otherFileCount: mm.otherFiles.count,
            totalBytes: total
        )
    }

    func cancelActiveOperation() {
        activeTask?.cancel()
        activeTask = nil
        isWorking = false
        isBackingUp = false
        isRestoring = false
        statusText = "Cancelled"
    }

    // MARK: - Backup Creation (Streaming STORE ZIP — low memory for large video libraries)

    /// Creates a complete `.zip` backup containing every song, video, folder, playlist, cover art,
    /// synced lyrics, and Shazam AI index in a temporary file safe to share or save to Files/USB/Drive.
    @discardableResult
    func createFullBackup() async -> URL? {
        guard !isWorking else { return nil }
        isWorking = true
        isBackingUp = true
        isRestoring = false
        progress = 0
        completedFiles = 0
        totalFiles = 0
        processedBytes = 0
        totalBytes = 0
        lastError = nil
        statusText = "Scanning songs, videos & metadata..."

        let task = Task<URL?, Never> {
            do {
                let archiveURL = try await Self.buildArchiveOnBackground(progressHandler: { [weak self] done, total, bytesDone, bytesAll, label in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.completedFiles = done
                        self.totalFiles = total
                        self.processedBytes = bytesDone
                        self.totalBytes = bytesAll
                        self.statusText = label
                        if bytesAll > 0 {
                            self.progress = min(1.0, max(0.0, Double(bytesDone) / Double(bytesAll)))
                        } else if total > 0 {
                            self.progress = min(1.0, max(0.0, Double(done) / Double(total)))
                        }
                    }
                })
                return archiveURL
            } catch is CancellationError {
                return nil
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
                return nil
            }
        }

        let created = await task.value
        isWorking = false
        isBackingUp = false
        if let created {
            latestBackupURL = created
            lastBackupDate = .now
            let sizeStr = (try? created.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            lastBackupDetails = "\(completedFiles) files • \(sizeStr)"
            progress = 1.0
            statusText = "Backup ready (\(lastBackupDetails ?? ""))"
            AppHaptics.success()
        }
        return created
    }

    // MARK: - Backup Restore (Streaming ZIP Reader — Merge or Replace)

    func restoreBackup(from archiveURL: URL, mode: BackupRestoreMode) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        isBackingUp = false
        isRestoring = true
        progress = 0
        completedFiles = 0
        totalFiles = 0
        processedBytes = 0
        totalBytes = 0
        lastError = nil
        statusText = "Reading backup archive..."

        let didAccess = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { archiveURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let docsURL = MediaItem.documentsDirectory
            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

            let restoredCount = try await Task.detached(priority: .userInitiated) {
                try Self.extractBackupStreaming(
                    archiveURL: archiveURL,
                    documentsURL: docsURL,
                    appSupportURL: appSupportURL,
                    replaceExisting: mode == .replace,
                    progressHandler: { [weak self] done, total, label in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.completedFiles = done
                            self.totalFiles = total
                            self.statusText = label
                            self.progress = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
                        }
                    }
                )
            }.value

            MediaManager.shared.reloadAllFromDisk()
            isWorking = false
            isRestoring = false
            progress = 1.0
            statusText = "Restored \(restoredCount) files"
            MediaManager.shared.statusMessage = "Restored \(restoredCount) backup files"
            AppHaptics.success()
            return true
        } catch {
            isWorking = false
            isRestoring = false
            lastError = error.localizedDescription
            statusText = "Restore failed"
            return false
        }
    }

    // MARK: - Background ZIP Construction

    private struct SourceEntry {
        let diskURL: URL
        let archivePath: String
        let byteSize: Int64
    }

    private nonisolated static func buildArchiveOnBackground(
        progressHandler: @escaping @Sendable (Int, Int, Int64, Int64, String) -> Void
    ) async throws -> URL {
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let docsURL = MediaItem.documentsDirectory
            let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

            var entries: [SourceEntry] = []

            func collectDirectory(_ dirURL: URL, prefix: String) {
                guard fm.fileExists(atPath: dirURL.path),
                      let enumerator = fm.enumerator(
                          at: dirURL,
                          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                          options: [.skipsHiddenFiles]
                      ) else { return }
                let basePath = dirURL.standardizedFileURL.path
                while let fileURL = enumerator.nextObject() as? URL {
                    let std = fileURL.standardizedFileURL
                    guard (try? std.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let rel = String(std.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !rel.isEmpty else { continue }
                    let size = Int64((try? std.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    entries.append(SourceEntry(diskURL: std, archivePath: "\(prefix)/\(rel)", byteSize: size))
                }
            }

            collectDirectory(docsURL, prefix: "media")

            let metaFiles = [
                "playlists.json",
                "library_state.json",
                "shazam_fingerprints.json",
                "whole_song_ai_state.json"
            ]
            for name in metaFiles {
                let u = appSupportURL.appendingPathComponent(name)
                if fm.fileExists(atPath: u.path) {
                    let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    entries.append(SourceEntry(diskURL: u, archivePath: "metadata/\(name)", byteSize: size))
                }
            }
            collectDirectory(appSupportURL.appendingPathComponent("Covers", isDirectory: true), prefix: "metadata/Covers")
            collectDirectory(appSupportURL.appendingPathComponent("LyricsCache", isDirectory: true), prefix: "metadata/LyricsCache")

            // Write manifest into temp and include it
            let totalSizeBytes = entries.reduce(Int64(0)) { $0 + $1.byteSize }
            let manifestURL = fm.temporaryDirectory.appendingPathComponent("musejrm_manifest_\(UUID().uuidString).json")
            let manifest = LibraryBackupManifest(
                formatVersion: 1,
                appName: "MuseJRM",
                createdAt: .now,
                mediaCount: entries.filter { $0.archivePath.hasPrefix("media/") }.count,
                playlistCount: 0,
                totalBytes: totalSizeBytes
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let manifestData = try? encoder.encode(manifest) {
                try? manifestData.write(to: manifestURL)
                entries.append(SourceEntry(diskURL: manifestURL, archivePath: "metadata/manifest.json", byteSize: Int64(manifestData.count)))
            }
            defer { try? fm.removeItem(at: manifestURL) }

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HHmm"
            let backupDir = fm.temporaryDirectory.appendingPathComponent("MuseJRMBackups", isDirectory: true)
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            // Remove older temp backup bundles so repeated exports don't fill phone storage
            if let oldFiles = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil) {
                for old in oldFiles { try? fm.removeItem(at: old) }
            }
            let outURL = backupDir.appendingPathComponent("MuseJRM-Backup-\(df.string(from: .now)).zip")

            try StreamingZipArchive.writeStoreZip(entries: entries, to: outURL) { done, total, bytesDone, bytesAll, label in
                progressHandler(done, total, bytesDone, bytesAll, label)
            }
            return outURL
        }.value
    }

    // MARK: - Streaming Restore

    private nonisolated static func extractBackupStreaming(
        archiveURL: URL,
        documentsURL: URL,
        appSupportURL: URL,
        replaceExisting: Bool,
        progressHandler: @escaping @Sendable (Int, Int, String) -> Void
    ) throws -> Int {
        let fm = FileManager.default
        if replaceExisting {
            let docsContents = (try? fm.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)) ?? []
            for item in docsContents { try? fm.removeItem(at: item) }
            try? fm.removeItem(at: appSupportURL.appendingPathComponent("Covers", isDirectory: true))
            try? fm.removeItem(at: appSupportURL.appendingPathComponent("LyricsCache", isDirectory: true))
        }

        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let attrs = try fm.attributesOfItem(atPath: archiveURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize >= 22 else {
            throw ZipExtractorError.invalidArchive
        }

        let tailSize = min(fileSize, 66_000)
        try handle.seek(toOffset: fileSize - tailSize)
        let tailData = try handle.readToEnd() ?? Data()
        guard let eocdLocalOffset = findEOCD(in: tailData) else {
            throw ZipExtractorError.invalidArchive
        }

        let totalEntries = Int(readU16(tailData, eocdLocalOffset + 10))
        let cdSize = Int(readU32(tailData, eocdLocalOffset + 12))
        let cdOffset = UInt64(readU32(tailData, eocdLocalOffset + 16))
        guard cdOffset + UInt64(cdSize) <= fileSize else {
            throw ZipExtractorError.invalidArchive
        }

        try handle.seek(toOffset: cdOffset)
        let cdData = try handle.read(upToCount: cdSize) ?? Data()

        struct CentralEntry {
            let path: String
            let method: UInt16
            let compressedSize: UInt32
            let uncompressedSize: UInt32
            let localHeaderOffset: UInt64
        }

        var parsed: [CentralEntry] = []
        var cursor = 0
        for _ in 0..<totalEntries {
            guard cursor + 46 <= cdData.count, readU32(cdData, cursor) == 0x02014b50 else { break }
            let method = readU16(cdData, cursor + 10)
            let compSize = readU32(cdData, cursor + 20)
            let uncompSize = readU32(cdData, cursor + 24)
            let nameLen = Int(readU16(cdData, cursor + 28))
            let extraLen = Int(readU16(cdData, cursor + 30))
            let commentLen = Int(readU16(cdData, cursor + 32))
            let localOff = UInt64(readU32(cdData, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cdData.count else { break }
            let name = String(data: cdData[nameStart..<nameEnd], encoding: .utf8) ?? ""
            cursor = nameEnd + extraLen + commentLen
            if name.isEmpty || name.hasSuffix("/") || name.hasPrefix("__MACOSX/") || name.contains("..") {
                continue
            }
            parsed.append(CentralEntry(
                path: name,
                method: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOff
            ))
        }

        var restored = 0
        let docsRoot = documentsURL.standardizedFileURL.path
        let appRoot = appSupportURL.standardizedFileURL.path

        for (idx, item) in parsed.enumerated() {
            try Task.checkCancellation()
            progressHandler(idx, parsed.count, "Restoring \(URL(fileURLWithPath: item.path).lastPathComponent)...")

            let destURL: URL?
            if item.path.hasPrefix("media/") {
                let rel = String(item.path.dropFirst("media/".count))
                let parts = rel.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                guard !parts.isEmpty else { continue }
                let candidate = parts.reduce(documentsURL) { $0.appendingPathComponent($1) }.standardizedFileURL
                destURL = candidate.path.hasPrefix(docsRoot + "/") ? candidate : nil
            } else if item.path.hasPrefix("metadata/") {
                let rel = String(item.path.dropFirst("metadata/".count))
                if rel == "manifest.json" { continue }
                let parts = rel.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                guard !parts.isEmpty else { continue }
                let candidate = parts.reduce(appSupportURL) { $0.appendingPathComponent($1) }.standardizedFileURL
                destURL = candidate.path.hasPrefix(appRoot + "/") ? candidate : nil
            } else {
                // Plain ZIP of songs/videos dropped into Documents
                let parts = item.path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                guard !parts.isEmpty else { continue }
                let candidate = parts.reduce(documentsURL) { $0.appendingPathComponent($1) }.standardizedFileURL
                destURL = candidate.path.hasPrefix(docsRoot + "/") ? candidate : nil
            }

            guard let targetURL = destURL else { continue }
            if !replaceExisting && fm.fileExists(atPath: targetURL.path) {
                continue
            }

            try handle.seek(toOffset: item.localHeaderOffset)
            let localHeader = try handle.read(upToCount: 30) ?? Data()
            guard localHeader.count == 30, readU32(localHeader, 0) == 0x04034b50 else { continue }
            let localNameLen = Int(readU16(localHeader, 26))
            let localExtraLen = Int(readU16(localHeader, 28))
            let payloadOffset = item.localHeaderOffset + 30 + UInt64(localNameLen + localExtraLen)

            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: targetURL.path) {
                try fm.removeItem(at: targetURL)
            }

            try handle.seek(toOffset: payloadOffset)

            if item.method == 0 {
                // Stream payload in 256 KB chunks directly to disk
                fm.createFile(atPath: targetURL.path, contents: nil)
                let outHandle = try FileHandle(forWritingTo: targetURL)
                defer { try? outHandle.close() }
                var remaining = Int64(item.uncompressedSize)
                while remaining > 0 {
                    let chunkCount = Int(min(remaining, 262_144))
                    guard let chunk = try handle.read(upToCount: chunkCount), !chunk.isEmpty else { break }
                    try outHandle.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                }
                restored += 1
            } else if item.method == 8 {
                let compData = try handle.read(upToCount: Int(item.compressedSize)) ?? Data()
                let cap = max(Int(item.uncompressedSize), 1024)
                var outData = Data(count: cap)
                let decoded = compData.withUnsafeBytes { srcRaw -> Int in
                    guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return outData.withUnsafeMutableBytes { dstRaw -> Int in
                        guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(dst, cap, src, compData.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard decoded > 0 || item.uncompressedSize == 0 else {
                    throw ZipExtractorError.decompressionFailed
                }
                outData.count = item.uncompressedSize == 0 ? 0 : decoded
                try outData.write(to: targetURL, options: [.atomic])
                restored += 1
            }
        }
        return restored
    }

    // MARK: - Streaming STORE ZIP Writer

    private enum StreamingZipArchive {
        private struct CentralDirectoryEntry {
            let nameData: Data
            let crc32: UInt32
            let byteSize: UInt32
            let localHeaderOffset: UInt32
        }

        static func writeStoreZip(
            entries: [SourceEntry],
            to destinationURL: URL,
            progress: (Int, Int, Int64, Int64, String) -> Void
        ) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            fm.createFile(atPath: destinationURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: destinationURL)
            defer { try? out.close() }

            let allBytes = entries.reduce(Int64(0)) { $0 + $1.byteSize }
            var writtenBytes: Int64 = 0
            var currentOffset: UInt64 = 0
            var centralDir: [CentralDirectoryEntry] = []

            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                let nameData = Data(entry.archivePath.utf8)
                guard currentOffset <= UInt64(UInt32.max - 1024),
                      entry.byteSize <= Int64(UInt32.max) else {
                    continue
                }
                let localHeaderOffset = UInt32(currentOffset)
                let size32 = UInt32(entry.byteSize)

                progress(index, entries.count, writtenBytes, allBytes, "Packing \(entry.diskURL.lastPathComponent)...")

                // Compute CRC32 in chunks without loading video into memory
                let crc = try computeCRC32Streaming(of: entry.diskURL)

                var localHeader = Data()
                appendU32(&localHeader, 0x04034b50) // Local file header signature
                appendU16(&localHeader, 20)         // Version needed
                appendU16(&localHeader, 0x0800)     // UTF-8 filename flag
                appendU16(&localHeader, 0)          // Method: 0 (STORE)
                appendU16(&localHeader, 0)          // Mod time
                appendU16(&localHeader, 0)          // Mod date
                appendU32(&localHeader, crc)
                appendU32(&localHeader, size32)
                appendU32(&localHeader, size32)
                appendU16(&localHeader, UInt16(nameData.count))
                appendU16(&localHeader, 0)          // Extra length
                localHeader.append(nameData)

                try out.write(contentsOf: localHeader)
                currentOffset += UInt64(localHeader.count)

                let inHandle = try FileHandle(forReadingFrom: entry.diskURL)
                defer { try? inHandle.close() }
                while let chunk = try inHandle.read(upToCount: 262_144), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try out.write(contentsOf: chunk)
                    currentOffset += UInt64(chunk.count)
                    writtenBytes += Int64(chunk.count)
                    progress(index, entries.count, writtenBytes, allBytes, "Backing up \(entry.diskURL.lastPathComponent)...")
                }

                centralDir.append(CentralDirectoryEntry(
                    nameData: nameData,
                    crc32: crc,
                    byteSize: size32,
                    localHeaderOffset: localHeaderOffset
                ))
            }

            let centralDirOffset = UInt32(min(currentOffset, UInt64(UInt32.max)))
            var centralDirData = Data()
            for item in centralDir {
                appendU32(&centralDirData, 0x02014b50)
                appendU16(&centralDirData, 20)
                appendU16(&centralDirData, 20)
                appendU16(&centralDirData, 0x0800)
                appendU16(&centralDirData, 0)
                appendU16(&centralDirData, 0)
                appendU16(&centralDirData, 0)
                appendU32(&centralDirData, item.crc32)
                appendU32(&centralDirData, item.byteSize)
                appendU32(&centralDirData, item.byteSize)
                appendU16(&centralDirData, UInt16(item.nameData.count))
                appendU16(&centralDirData, 0)
                appendU16(&centralDirData, 0)
                appendU16(&centralDirData, 0)
                appendU16(&centralDirData, 0)
                appendU32(&centralDirData, 0)
                appendU32(&centralDirData, item.localHeaderOffset)
                centralDirData.append(item.nameData)
            }
            try out.write(contentsOf: centralDirData)

            var eocd = Data()
            appendU32(&eocd, 0x06054b50)
            appendU16(&eocd, 0)
            appendU16(&eocd, 0)
            appendU16(&eocd, UInt16(min(centralDir.count, Int(UInt16.max))))
            appendU16(&eocd, UInt16(min(centralDir.count, Int(UInt16.max))))
            appendU32(&eocd, UInt32(centralDirData.count))
            appendU32(&eocd, centralDirOffset)
            appendU16(&eocd, 0)
            try out.write(contentsOf: eocd)
        }

        private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }

        private static func computeCRC32Streaming(of url: URL) throws -> UInt32 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var crc: UInt32 = 0xFFFFFFFF
            while let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty {
                for byte in chunk {
                    let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                    crc = (crc >> 8) ^ crcTable[idx]
                }
            }
            return crc ^ 0xFFFFFFFF
        }

        private static func appendU16(_ data: inout Data, _ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        private static func appendU32(_ data: inout Data, _ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
    }

    private nonisolated static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for i in stride(from: data.count - 22, through: 0, by: -1) {
            if readU32(data, i) == 0x06054b50 { return i }
        }
        return nil
    }

    private nonisolated static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private nonisolated static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
