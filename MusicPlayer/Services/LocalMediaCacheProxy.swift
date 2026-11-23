import CryptoKit
import Foundation
import Network
import Observation

@MainActor
@Observable
final class LocalMediaCacheProxy {
    static let shared = LocalMediaCacheProxy()

    private(set) var port: UInt16?
    private(set) var cachedBytes: Int64 = 0

    @ObservationIgnored private var listener: NWListener?

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
                    Task { @MainActor in self?.port = actualPort }
                }
            }
            newListener.start(queue: DispatchQueue.global(qos: .userInitiated))
            listener = newListener
        } catch {
            print("Proxy listener error: \(error)")
        }
    }

    func proxiedURL(for remoteURL: URL) -> URL {
        guard let port,
              let encoded = remoteURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let local = URL(string: "http://127.0.0.1:\(port)/proxy?url=\(encoded)") else {
            return remoteURL
        }
        return local
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
        cachedBytes = 0
    }

    nonisolated private static func cacheKey(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func handle(connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            guard let data, let reqText = String(data: data, encoding: .utf8),
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

            let rangeHeader = reqText
                .components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") })?
                .dropFirst(6)
                .trimmingCharacters(in: .whitespaces)

            let cacheFile = proxyCacheDirectory.appendingPathComponent(cacheKey(for: targetURL.absoluteString))
            if rangeHeader == nil, FileManager.default.fileExists(atPath: cacheFile.path),
               let cachedData = try? Data(contentsOf: cacheFile) {
                let mime = targetURL.pathExtension.lowercased() == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp4"
                sendHTTP(connection: connection, status: "200 OK", contentType: mime, body: cachedData)
                return
            }

            var request = URLRequest(url: targetURL)
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }

            URLSession.shared.dataTask(with: request) { bodyData, response, error in
                guard let bodyData, let httpResp = response as? HTTPURLResponse, error == nil else {
                    sendSimpleResponse(connection: connection, status: "502 Bad Gateway", body: Data())
                    return
                }
                if rangeHeader == nil && httpResp.statusCode == 200 && bodyData.count < 64 * 1024 * 1024 {
                    try? bodyData.write(to: cacheFile, options: [.atomic])
                    Task { @MainActor in LocalMediaCacheProxy.shared.refreshCacheSize() }
                }
                let mime = httpResp.mimeType ?? "application/octet-stream"
                let statusStr = httpResp.statusCode == 206 ? "206 Partial Content" : "200 OK"
                var extraHeaders: [String: String] = [:]
                if let cr = httpResp.value(forHTTPHeaderField: "Content-Range") {
                    extraHeaders["Content-Range"] = cr
                }
                extraHeaders["Accept-Ranges"] = "bytes"
                sendHTTP(connection: connection, status: statusStr, contentType: mime, body: bodyData, extraHeaders: extraHeaders)
            }.resume()
        }
    }

    nonisolated private static func sendSimpleResponse(connection: NWConnection, status: String, body: Data) {
        sendHTTP(connection: connection, status: status, contentType: "text/plain", body: body)
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
