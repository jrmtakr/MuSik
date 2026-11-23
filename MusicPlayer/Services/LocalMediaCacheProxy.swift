import CryptoKit
import Foundation
import Network
import Observation

private final class ProxyRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    var port: UInt16?
    var storedHeadersByKey: [String: [String: String]] = [:]

    func setPort(_ port: UInt16?) {
        lock.lock()
        self.port = port
        lock.unlock()
    }

    func getPort() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    func setHeaders(_ headers: [String: String], forKey key: String) {
        lock.lock()
        storedHeadersByKey[key] = headers
        lock.unlock()
    }

    func headers(forKey key: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storedHeadersByKey[key] ?? [:]
    }

    func clearHeaders() {
        lock.lock()
        storedHeadersByKey.removeAll()
        lock.unlock()
    }
}

@MainActor
@Observable
final class LocalMediaCacheProxy {
    static let shared = LocalMediaCacheProxy()

    private(set) var port: UInt16?
    private(set) var cachedBytes: Int64 = 0

    @ObservationIgnored private var listener: NWListener?
    private static let runtimeState = ProxyRuntimeState()

    nonisolated static var proxyCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("ProxyMediaCache", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.proxyCacheDirectory, withIntermediateDirectories: true)
        refreshCacheSize()
    }

    func start() {
        guard listener == nil else { return }
        do {
            let newListener = try NWListener(using: .tcp)
            newListener.newConnectionHandler = { connection in
                Self.handle(connection: connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let actualPort = newListener.port?.rawValue {
                    Self.runtimeState.setPort(actualPort)
                    Task { @MainActor in self?.port = actualPort }
                }
            }
            newListener.start(queue: DispatchQueue.global(qos: .userInitiated))
            listener = newListener
        } catch {
            print("Proxy listener error: \(error)")
        }
    }

    nonisolated static func proxiedURL(for remoteURL: URL, headers: [String: String]? = nil) -> URL {
        if let headers, !headers.isEmpty {
            let key = cacheKey(for: remoteURL.absoluteString)
            runtimeState.setHeaders(headers, forKey: key)
        }
        guard let port = runtimeState.getPort(),
              var comps = URLComponents(string: "http://127.0.0.1:\(port)/proxy") else {
            return remoteURL
        }
        comps.queryItems = [URLQueryItem(name: "url", value: remoteURL.absoluteString)]
        return comps.url ?? remoteURL
    }

    nonisolated func proxiedURL(for remoteURL: URL, headers: [String: String]? = nil) -> URL {
        Self.proxiedURL(for: remoteURL, headers: headers)
    }

    nonisolated static func cachedDataURL(for remoteURL: URL) -> URL? {
        let bin = proxyCacheDirectory.appendingPathComponent(cacheKey(for: remoteURL.absoluteString) + ".bin")
        return FileManager.default.fileExists(atPath: bin.path) ? bin : nil
    }

    func refreshCacheSize() {
        let dir = Self.proxyCacheDirectory
        var total: Int64 = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        cachedBytes = total
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: Self.proxyCacheDirectory)
        try? FileManager.default.createDirectory(at: Self.proxyCacheDirectory, withIntermediateDirectories: true)
        Self.runtimeState.clearHeaders()
        cachedBytes = 0
    }

    nonisolated private static func cacheKey(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func storedHeaders(for key: String) -> [String: String] {
        runtimeState.headers(forKey: key)
    }

    nonisolated private static func readHTTPRequestHeader(
        from connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping (String?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, isComplete, error in
            if let error {
                _ = error
                completion(nil)
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            if let sep = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: buffer[..<sep.lowerBound], encoding: .utf8)
                completion(headerText)
                return
            }
            if isComplete || buffer.count > 128_000 {
                completion(String(data: buffer, encoding: .utf8))
                return
            }
            readHTTPRequestHeader(from: connection, accumulated: buffer, completion: completion)
        }
    }

    nonisolated private static func handle(connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        readHTTPRequestHeader(from: connection) { reqText in
            guard let reqText,
                  let firstLine = reqText.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2,
                  let comps = URLComponents(string: "http://localhost\(parts[1])"),
                  let targetStr = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let targetURL = URL(string: targetStr) else {
                sendSimpleResponse(connection: connection, status: "400 Bad Request", body: Data("Invalid proxy request".utf8))
                return
            }

            let method = String(parts[0]).uppercased()
            let key = cacheKey(for: targetURL.absoluteString)
            let cacheBin = proxyCacheDirectory.appendingPathComponent("\(key).bin")
            let cacheMeta = proxyCacheDirectory.appendingPathComponent("\(key).meta")

            let rangeHeader = reqText
                .components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") })?
                .dropFirst(6)
                .trimmingCharacters(in: .whitespaces)

            // Serve from complete disk cache (supports both full and byte-range requests offline!)
            if FileManager.default.fileExists(atPath: cacheBin.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: cacheBin.path),
               let totalSize = (attrs[.size] as? NSNumber)?.int64Value,
               totalSize > 0 {
                let savedMime = (try? String(contentsOf: cacheMeta, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                let mime = (savedMime?.isEmpty == false ? savedMime! : inferredMIME(for: targetURL))

                if method == "HEAD" {
                    sendHeaderOnly(
                        connection: connection,
                        status: "200 OK",
                        contentType: mime,
                        contentLength: totalSize,
                        extraHeaders: ["Accept-Ranges": "bytes"]
                    )
                    return
                }

                if let rangeHeader, let slice = parseByteRange(rangeHeader, totalLength: totalSize) {
                    if let fh = try? FileHandle(forReadingFrom: cacheBin) {
                        defer { try? fh.close() }
                        try? fh.seek(toOffset: UInt64(slice.start))
                        let count = Int(slice.end - slice.start + 1)
                        let bodyData = (try? fh.read(upToCount: count)) ?? Data()
                        sendHTTP(
                            connection: connection,
                            status: "206 Partial Content",
                            contentType: mime,
                            body: bodyData,
                            extraHeaders: [
                                "Content-Range": "bytes \(slice.start)-\(slice.start + Int64(bodyData.count) - 1)/\(totalSize)",
                                "Accept-Ranges": "bytes"
                            ]
                        )
                        return
                    }
                }

                if let fullData = try? Data(contentsOf: cacheBin, options: [.mappedIfSafe]) {
                    sendHTTP(
                        connection: connection,
                        status: "200 OK",
                        contentType: mime,
                        body: fullData,
                        extraHeaders: ["Accept-Ranges": "bytes"]
                    )
                    return
                }
            }

            var request = URLRequest(url: targetURL)
            request.httpMethod = method == "HEAD" ? "HEAD" : "GET"
            let extra = storedHeaders(for: key)
            request.setValue(WebMediaDownloader.browserUserAgent, forHTTPHeaderField: "User-Agent")
            for (hKey, hVal) in extra {
                request.setValue(hVal, forHTTPHeaderField: hKey)
            }
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }

            let downloadSession = URLSession(configuration: .ephemeral)
            if method == "HEAD" {
                downloadSession.dataTask(with: request) { _, response, error in
                    guard let httpResp = response as? HTTPURLResponse, error == nil else {
                        sendSimpleResponse(connection: connection, status: "502 Bad Gateway", body: Data())
                        return
                    }
                    let mime = httpResp.mimeType ?? inferredMIME(for: targetURL)
                    sendHeaderOnly(
                        connection: connection,
                        status: "\(httpResp.statusCode) OK",
                        contentType: mime,
                        contentLength: max(httpResp.expectedContentLength, 0),
                        extraHeaders: ["Accept-Ranges": httpResp.value(forHTTPHeaderField: "Accept-Ranges") ?? "bytes"]
                    )
                }.resume()
                return
            }

            downloadSession.downloadTask(with: request) { tempURL, response, error in
                guard let tempURL, let httpResp = response as? HTTPURLResponse, error == nil else {
                    sendSimpleResponse(connection: connection, status: "502 Bad Gateway", body: Data())
                    return
                }
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let mime = httpResp.mimeType ?? inferredMIME(for: targetURL)
                let bodySize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0

                let isFullResponse = (httpResp.statusCode == 200)
                    || (httpResp.statusCode == 206 && rangeHeader?.lowercased() == "bytes=0-" && !httpResp.allHeaderFields.isEmpty)
                let contentRange = httpResp.value(forHTTPHeaderField: "Content-Range")
                let isCompleteRangeFromZero: Bool = {
                    guard httpResp.statusCode == 206, let contentRange else { return false }
                    // e.g. "bytes 0-1234/1235"
                    let cleaned = contentRange.replacingOccurrences(of: "bytes ", with: "")
                    let splitSlash = cleaned.split(separator: "/")
                    guard splitSlash.count == 2,
                          let total = Int64(splitSlash[1]),
                          let rangePart = splitSlash.first?.split(separator: "-"),
                          rangePart.count == 2,
                          let start = Int64(rangePart[0]),
                          let end = Int64(rangePart[1]) else {
                        return false
                    }
                    return start == 0 && (end + 1) == total
                }()

                if (httpResp.statusCode == 200 || isCompleteRangeFromZero) && bodySize > 0 && bodySize <= 250 * 1024 * 1024 {
                    try? FileManager.default.createDirectory(at: proxyCacheDirectory, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: cacheBin.path) {
                        try? FileManager.default.copyItem(at: tempURL, to: cacheBin)
                        try? mime.write(to: cacheMeta, atomically: true, encoding: .utf8)
                        Task { @MainActor in LocalMediaCacheProxy.shared.refreshCacheSize() }
                    }
                } else if isFullResponse == false {
                    _ = isCompleteRangeFromZero
                }

                guard let mapped = try? Data(contentsOf: tempURL, options: [.mappedIfSafe]) else {
                    sendSimpleResponse(connection: connection, status: "500 Internal Server Error", body: Data())
                    return
                }

                let statusStr = httpResp.statusCode == 206 ? "206 Partial Content" : "200 OK"
                var respHeaders: [String: String] = ["Accept-Ranges": "bytes"]
                if let cr = contentRange {
                    respHeaders["Content-Range"] = cr
                }
                sendHTTP(connection: connection, status: statusStr, contentType: mime, body: mapped, extraHeaders: respHeaders)
            }.resume()
        }
    }

    nonisolated private static func parseByteRange(_ header: String, totalLength: Int64) -> (start: Int64, end: Int64)? {
        let lower = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasPrefix("bytes=") else { return nil }
        let spec = String(lower.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty, let suffixLen = Int64(parts[1]), suffixLen > 0 {
            let start = max(0, totalLength - suffixLen)
            return (start, totalLength - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < totalLength else { return nil }
        if parts[1].isEmpty {
            return (start, totalLength - 1)
        }
        guard let reqEnd = Int64(parts[1]) else { return nil }
        let end = min(reqEnd, totalLength - 1)
        guard end >= start else { return nil }
        return (start, end)
    }

    nonisolated private static func inferredMIME(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        default: return "video/mp4"
        }
    }

    nonisolated private static func sendSimpleResponse(connection: NWConnection, status: String, body: Data) {
        sendHTTP(connection: connection, status: status, contentType: "text/plain", body: body)
    }

    nonisolated private static func sendHeaderOnly(
        connection: NWConnection,
        status: String,
        contentType: String,
        contentLength: Int64,
        extraHeaders: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    nonisolated private static func sendHTTP(
        connection: NWConnection,
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}