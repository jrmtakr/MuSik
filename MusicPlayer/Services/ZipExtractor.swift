import Compression
import Foundation

enum ZipExtractorError: LocalizedError {
    case unreadableFile
    case invalidArchive
    case unsupportedCompression(UInt16)
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "Could not read archive file."
        case .invalidArchive:
            return "This file is not a valid ZIP archive."
        case .unsupportedCompression(let method):
            return "Unsupported ZIP compression method (\(method))."
        case .decompressionFailed:
            return "Failed to decompress entry inside ZIP archive."
        }
    }
}

enum ZipExtractor {
    static func extract(archiveURL: URL, to destinationFolder: URL) throws -> Int {
        guard let data = try? Data(contentsOf: archiveURL) else {
            throw ZipExtractorError.unreadableFile
        }
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else {
            throw ZipExtractorError.invalidArchive
        }

        let totalEntries = Int(readUInt16(data, at: eocdOffset + 10))
        let centralDirOffset = Int(readUInt32(data, at: eocdOffset + 16))
        guard centralDirOffset >= 0, centralDirOffset < data.count else {
            throw ZipExtractorError.invalidArchive
        }

        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let rootPath = destinationFolder.standardizedFileURL.path

        var cursor = centralDirOffset
        var extractedCount = 0

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count, readUInt32(data, at: cursor) == 0x02014b50 else {
                break
            }

            let method = readUInt16(data, at: cursor + 10)
            let compressedSize = Int(readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int(readUInt32(data, at: cursor + 24))
            let nameLen = Int(readUInt16(data, at: cursor + 28))
            let extraLen = Int(readUInt16(data, at: cursor + 30))
            let commentLen = Int(readUInt16(data, at: cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { break }

            let rawName = String(data: data[nameStart..<nameEnd], encoding: .utf8)
                ?? String(data: data[nameStart..<nameEnd], encoding: .isoLatin1)
                ?? ""

            cursor = nameEnd + extraLen + commentLen

            if rawName.isEmpty || rawName.hasSuffix("/") || rawName.hasPrefix("__MACOSX/") || rawName.contains("..") {
                continue
            }

            let sanitizedParts = rawName
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

            guard !sanitizedParts.isEmpty else { continue }
            let targetURL = sanitizedParts.reduce(destinationFolder) { partial, part in
                partial.appendingPathComponent(part)
            }.standardizedFileURL

            guard targetURL.path.hasPrefix(rootPath + "/") else { continue }

            guard localHeaderOffset + 30 <= data.count,
                  readUInt32(data, at: localHeaderOffset) == 0x04034b50 else {
                continue
            }

            let localNameLen = Int(readUInt16(data, at: localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(data, at: localHeaderOffset + 28))
            let payloadStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + compressedSize
            guard payloadStart >= 0, payloadEnd <= data.count else { continue }

            let payload = data[payloadStart..<payloadEnd]
            let outputData: Data

            switch method {
            case 0:
                outputData = Data(payload)
            case 8:
                if uncompressedSize == 0 {
                    outputData = Data()
                } else {
                    outputData = try inflateRawDeflate(Data(payload), expectedSize: uncompressedSize)
                }
            default:
                throw ZipExtractorError.unsupportedCompression(method)
            }

            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try outputData.write(to: targetURL, options: [.atomic])
            extractedCount += 1
        }

        return extractedCount
    }

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        let capacity = max(expectedSize, 1024)
        var output = Data(count: capacity)

        let decodedSize = compressed.withUnsafeBytes { srcRaw -> Int in
            guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { dstRaw -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr,
                    capacity,
                    srcPtr,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize > 0 else {
            throw ZipExtractorError.decompressionFailed
        }
        output.count = decodedSize
        return output
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minOffset = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: minOffset, by: -1) {
            if readUInt32(data, at: offset) == 0x06054b50 {
                return offset
            }
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
