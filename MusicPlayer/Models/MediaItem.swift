import Foundation

struct MediaItem: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let fileName: String
    let relativePath: String
    var fileSize: Int64 = 0
    var dateAdded: Date = .now
    var durationSeconds: Double?
    var metadataTitle: String?
    var artist: String?

    var displayTitle: String {
        if let metadataTitle, !metadataTitle.isEmpty {
            return metadataTitle
        }
        return name
    }

    static let appleNativeAudioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "caf", "alac", "m4b", "m4r"
    ]

    static let appleNativeVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "movpkg"
    ]

    static let ffmpegVideoExtensions: Set<String> = [
        "mkv", "avi", "webm", "flv", "wmv", "rmvb", "ts", "m2ts",
        "vob", "ogv", "divx", "3gp", "mpg", "mpeg", "f4v", "asf"
    ]

    static let ffmpegAudioExtensions: Set<String> = [
        "ogg", "opus", "wma", "ape", "ac3", "dts", "amr"
    ]

    static let allVideoExtensions: Set<String> = appleNativeVideoExtensions.union(ffmpegVideoExtensions)
    static let allAudioExtensions: Set<String> = appleNativeAudioExtensions.union(ffmpegAudioExtensions)
    static let allSupportedExtensions: Set<String> = allVideoExtensions.union(allAudioExtensions)

    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    var isHLS: Bool {
        fileExtension == "movpkg"
    }

    var isVideo: Bool {
        Self.allVideoExtensions.contains(fileExtension)
    }

    var prefersFFmpegEngine: Bool {
        Self.ffmpegVideoExtensions.contains(fileExtension) || Self.ffmpegAudioExtensions.contains(fileExtension)
    }

    var folderRelativePath: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    var fileURL: URL {
        Self.documentsDirectory.appendingPathComponent(relativePath)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return MediaTimeFormatter.format(durationSeconds)
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

struct LocalFile: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let fileName: String
    let relativePath: String
    var fileSize: Int64 = 0
    var dateAdded: Date = .now

    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    var folderRelativePath: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    var fileURL: URL {
        MediaItem.documentsDirectory.appendingPathComponent(relativePath)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp"].contains(fileExtension)
    }

    var isArchive: Bool {
        ["zip", "cbz"].contains(fileExtension)
    }

    var isReadableText: Bool {
        ["txt", "md", "rtf", "html", "htm", "log", "json", "xml", "csv"].contains(fileExtension)
    }

    var systemImage: String {
        switch fileExtension {
        case "pdf": return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp": return "photo.fill"
        case "txt", "md", "rtf", "log": return "doc.text.fill"
        case "zip", "cbz", "tar", "gz", "7z": return "archivebox.fill"
        case "csv", "xls", "xlsx", "numbers": return "tablecells.fill"
        case "doc", "docx", "pages": return "doc.fill"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle.angled"
        case "json", "xml", "swift", "py", "js", "html", "htm": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }
}

struct LocalFolder: Identifiable, Hashable {
    let id: UUID
    let name: String
    let relativePath: String
    var itemCount: Int = 0
    var dateModified: Date = .now

    var parentRelativePath: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    var folderURL: URL {
        MediaItem.documentsDirectory.appendingPathComponent(relativePath, isDirectory: true)
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var itemFileNames: [String]
    var dateCreated: Date = .now
    var customCoverFileName: String?
}

enum RepeatMode: String, CaseIterable, Codable {
    case off = "off"
    case all = "all"
    case one = "one"

    var label: String {
        switch self {
        case .off: return "Pause After All"
        case .all: return "Loop All"
        case .one: return "Single Loop"
        }
    }

    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

enum DuplicateConflictAction {
    case overwrite
    case keepBoth
}

enum MediaTimeFormatter {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
