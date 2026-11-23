import Darwin
import Foundation
import Network
import Observation

@Observable
final class WiFiTransferServer {
    struct UploadedEntry: Identifiable, Hashable {
        let id = UUID()
        let fileName: String
        let uploadedAt = Date()
    }

    private var listener: NWListener?
    private let docsURL = MediaItem.documentsDirectory
    private let sessionsLock = NSLock()
    private var activeSessions: [ObjectIdentifier: HTTPConnectionSession] = [:]

    var isRunning = false
    var serverAddress = ""
    var port: UInt16 = 8080
    var errorMessage: String?
    var recentUploads: [UploadedEntry] = []

    var onFileReceived: ((URL, String, String) -> Void)?
    var onLibraryChanged: (() -> Void)?

    func start(port: UInt16 = 8080) {
        stop()
        errorMessage = nil
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            errorMessage = "Invalid port number: \(port)"
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: parameters, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let activePort = newListener.port?.rawValue ?? port
                        self.port = activePort
                        self.isRunning = true
                        self.serverAddress = "http://\(self.getWiFiIPAddress() ?? "localhost"):\(activePort)"
                    case .failed(let error):
                        self.isRunning = false
                        self.serverAddress = ""
                        self.errorMessage = "Server failed: \(error.localizedDescription)"
                        newListener.cancel()
                        if self.listener === newListener {
                            self.listener = nil
                        }
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener = newListener
            newListener.start(queue: .global(qos: .userInitiated))
        } catch {
            isRunning = false
            errorMessage = "Failed to start server: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil

        sessionsLock.lock()
        let sessions = Array(activeSessions.values)
        activeSessions.removeAll()
        sessionsLock.unlock()

        for session in sessions {
            session.forceClose()
        }

        isRunning = false
        serverAddress = ""
    }

    private func handleConnection(_ connection: NWConnection) {
        var sessionRef: HTTPConnectionSession?
        let session = HTTPConnectionSession(
            connection: connection,
            docsURL: docsURL,
            onUploadComplete: { [weak self] tempURL, fileName, folderPath in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let display = folderPath.isEmpty ? fileName : "\(folderPath)/\(fileName)"
                    self.recentUploads.insert(UploadedEntry(fileName: display), at: 0)
                    if self.recentUploads.count > 20 {
                        self.recentUploads.removeLast(self.recentUploads.count - 20)
                    }
                    self.onFileReceived?(tempURL, fileName, folderPath)
                }
            },
            onLibraryChanged: { [weak self] in
                DispatchQueue.main.async {
                    self?.onLibraryChanged?()
                }
            },
            onFinished: { [weak self] in
                guard let self, let session = sessionRef else { return }
                self.sessionsLock.lock()
                self.activeSessions.removeValue(forKey: ObjectIdentifier(session))
                self.sessionsLock.unlock()
            }
        )
        sessionRef = session
        sessionsLock.lock()
        activeSessions[ObjectIdentifier(session)] = session
        sessionsLock.unlock()
        session.start()
    }

    func refreshAddress() {
        guard isRunning else { return }
        serverAddress = "http://\(getWiFiIPAddress() ?? "localhost"):\(port)"
    }

    private func getWiFiIPAddress() -> String? {
        var fallbackAddress: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = ptr?.pointee {
            defer { ptr = interface.ifa_next }

            let isUp = (interface.ifa_flags & UInt32(IFF_UP)) != 0
            let isLoopback = (interface.ifa_flags & UInt32(IFF_LOOPBACK)) != 0
            guard isUp, !isLoopback, let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)

            if name == "en0" {
                return ip
            }
            if fallbackAddress == nil && (name.hasPrefix("en") || name.hasPrefix("bridge")) {
                fallbackAddress = ip
            }
        }
        return fallbackAddress
    }
}

// MARK: - Streaming HTTP Connection Handler

private final class HTTPConnectionSession {
    private let connection: NWConnection
    private let docsURL: URL
    private let onUploadComplete: (URL, String, String) -> Void
    private let onLibraryChanged: () -> Void
    private let onFinished: () -> Void

    private var headerBuffer = Data()
    private var headersParsed = false
    private var method = ""
    private var rawPath = "/"
    private var headers: [String: String] = [:]

    private var expectedBodyLength: Int64 = 0
    private var receivedBodyBytes: Int64 = 0
    private var tempBodyURL: URL?
    private var tempFileHandle: FileHandle?
    private var hasFinished = false

    private let maxHeaderSize = 65_536
    private let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    init(
        connection: NWConnection,
        docsURL: URL,
        onUploadComplete: @escaping (URL, String, String) -> Void,
        onLibraryChanged: @escaping () -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.connection = connection
        self.docsURL = docsURL
        self.onUploadComplete = onUploadComplete
        self.onLibraryChanged = onLibraryChanged
        self.onFinished = onFinished
    }

    func forceClose() {
        cleanupAndCancel()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cleanupAndCancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        guard !hasFinished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.hasFinished else { return }

            if error != nil {
                self.cleanupAndCancel()
                return
            }

            if let data, !data.isEmpty {
                self.processIncomingData(data)
            }

            if isComplete && !self.hasFinished {
                if self.headersParsed && (self.method == "POST" || self.method == "PUT") {
                    self.finalizePostOrPut()
                } else {
                    self.cleanupAndCancel()
                }
            }
        }
    }

    private func processIncomingData(_ chunk: Data) {
        if !headersParsed {
            headerBuffer.append(chunk)

            guard let delimiterRange = headerBuffer.range(of: headerDelimiter) else {
                if headerBuffer.count > maxHeaderSize {
                    sendResponse(status: "431 Request Header Fields Too Large", contentType: "text/plain", body: Data("Headers too large".utf8))
                } else {
                    receiveNextChunk()
                }
                return
            }

            let headerData = headerBuffer[..<delimiterRange.lowerBound]
            let remainder = Data(headerBuffer[delimiterRange.upperBound...])
            headerBuffer.removeAll(keepingCapacity: false)

            guard parseHTTPHeaders(headerData) else {
                sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Invalid HTTP request".utf8))
                return
            }

            headersParsed = true

            if headers["expect"]?.lowercased() == "100-continue" {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }

            switch method {
            case "GET":
                handleGetRequest()
            case "POST", "PUT":
                beginReceivingBody(initialRemainder: remainder)
            default:
                sendResponse(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Method not allowed".utf8))
            }
            return
        }

        writeBodyChunk(chunk)
        if expectedBodyLength > 0 && receivedBodyBytes >= expectedBodyLength {
            finalizePostOrPut()
        } else {
            receiveNextChunk()
        }
    }

    private func parseHTTPHeaders(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return false
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return false }

        method = String(parts[0]).uppercased()
        rawPath = String(parts[1])

        headers.removeAll(keepingCapacity: true)
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        expectedBodyLength = Int64(headers["content-length"] ?? "") ?? 0
        return true
    }

    private var cleanPath: String {
        rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
    }

    private func queryParam(_ name: String) -> String? {
        guard let comps = URLComponents(string: "http://localhost\(rawPath)") else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }

    private func safeRelativePath(_ raw: String?) -> String? {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.isEmpty { return "" }
        let parts = trimmed.split(separator: "/").map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." || part.hasPrefix(".") {
                return nil
            }
        }
        return parts.joined(separator: "/")
    }

    private func resolvedURL(forRelativePath relPath: String) -> URL? {
        let rootPath = docsURL.standardizedFileURL.path
        if relPath.isEmpty { return docsURL.standardizedFileURL }
        let candidate = docsURL.appendingPathComponent(relPath).standardizedFileURL
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    private func handleGetRequest() {
        let path = cleanPath

        if path == "/" {
            sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(Self.uploaderHTML.utf8))
            return
        }

        if path == "/api/files" {
            let requestedDir = safeRelativePath(queryParam("dir")) ?? ""
            let payload = buildDirectoryJSON(dirRelPath: requestedDir)
            sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: payload)
            return
        }

        if path.hasPrefix("/files/") {
            let encoded = String(path.dropFirst("/files/".count))
            let decoded = encoded.removingPercentEncoding ?? encoded
            guard let relPath = safeRelativePath(decoded),
                  !relPath.isEmpty,
                  let targetURL = resolvedURL(forRelativePath: relPath),
                  FileManager.default.fileExists(atPath: targetURL.path) else {
                sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("File not found".utf8))
                return
            }
            streamFileDownload(at: targetURL, fileName: targetURL.lastPathComponent)
            return
        }

        sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
    }

    private func beginReceivingBody(initialRemainder: Data) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wifi_raw_\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            sendResponse(status: "500 Internal Server Error", contentType: "text/plain", body: Data("Could not create temporary file".utf8))
            return
        }

        tempBodyURL = tempURL
        tempFileHandle = handle

        if !initialRemainder.isEmpty {
            writeBodyChunk(initialRemainder)
        }

        if expectedBodyLength > 0 && receivedBodyBytes >= expectedBodyLength {
            finalizePostOrPut()
        } else if expectedBodyLength == 0 && !initialRemainder.isEmpty {
            finalizePostOrPut()
        } else if expectedBodyLength == 0 && cleanPath.hasPrefix("/api/") {
            finalizePostOrPut()
        } else {
            receiveNextChunk()
        }
    }

    private func writeBodyChunk(_ chunk: Data) {
        guard let handle = tempFileHandle else { return }
        let sliceToWrite: Data
        if expectedBodyLength > 0 {
            let remaining = max(Int64(0), expectedBodyLength - receivedBodyBytes)
            sliceToWrite = Int64(chunk.count) > remaining ? chunk.prefix(Int(remaining)) : chunk
        } else {
            sliceToWrite = chunk
        }

        guard !sliceToWrite.isEmpty else { return }
        do {
            try handle.write(contentsOf: sliceToWrite)
            receivedBodyBytes += Int64(sliceToWrite.count)
        } catch {
            cleanupAndCancel()
        }
    }

    private func finalizePostOrPut() {
        guard !hasFinished else { return }
        try? tempFileHandle?.close()
        tempFileHandle = nil

        guard let rawURL = tempBodyURL else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("No request data".utf8))
            return
        }
        tempBodyURL = nil

        let path = cleanPath
        if path == "/api/mkdir" || path == "/api/rename" || path == "/api/delete" {
            handleJSONAction(path: path, bodyURL: rawURL)
            try? FileManager.default.removeItem(at: rawURL)
            return
        }

        let targetDir = safeRelativePath(headers["x-target-dir"]?.removingPercentEncoding ?? queryParam("dir")) ?? ""
        let contentType = headers["content-type"] ?? ""

        if contentType.lowercased().contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            if let extracted = extractMultipartFile(from: rawURL, boundary: boundary) {
                try? FileManager.default.removeItem(at: rawURL)
                onUploadComplete(extracted.tempURL, extracted.fileName, targetDir)
                sendJSON(["ok": true, "fileName": extracted.fileName])
            } else {
                try? FileManager.default.removeItem(at: rawURL)
                sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Could not parse uploaded file".utf8))
            }
            return
        }

        let headerName = headers["x-file-name"]?.removingPercentEncoding
        let pathName: String? = {
            if path.hasPrefix("/upload/") {
                let raw = String(path.dropFirst("/upload/".count))
                return raw.removingPercentEncoding ?? raw
            }
            return nil
        }()

        let rawCandidate = (headerName?.isEmpty == false ? headerName : pathName) ?? "upload_\(Int(Date().timeIntervalSince1970)).bin"
        let safeFileName = sanitizeFileName(rawCandidate)
        onUploadComplete(rawURL, safeFileName, targetDir)
        sendJSON(["ok": true, "fileName": safeFileName])
    }

    private func handleJSONAction(path: String, bodyURL: URL) {
        guard let data = try? Data(contentsOf: bodyURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            sendResponse(status: "400 Bad Request", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
            return
        }

        switch path {
        case "/api/mkdir":
            let dir = safeRelativePath(json["dir"] as? String) ?? ""
            let name = sanitizeFileName(json["name"] as? String ?? "")
            guard !name.isEmpty,
                  let parentURL = resolvedURL(forRelativePath: dir) else {
                sendResponse(status: "400 Bad Request", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
                return
            }
            let target = parentURL.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            onLibraryChanged()
            sendJSON(["ok": true])

        case "/api/rename":
            guard let fromRel = safeRelativePath(json["from"] as? String),
                  !fromRel.isEmpty,
                  let fromURL = resolvedURL(forRelativePath: fromRel),
                  FileManager.default.fileExists(atPath: fromURL.path) else {
                sendResponse(status: "404 Not Found", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
                return
            }
            let newName = sanitizeFileName(json["name"] as? String ?? "")
            guard !newName.isEmpty else {
                sendResponse(status: "400 Bad Request", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
                return
            }
            let destURL = fromURL.deletingLastPathComponent().appendingPathComponent(newName)
            guard !FileManager.default.fileExists(atPath: destURL.path) else {
                sendResponse(status: "409 Conflict", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
                return
            }
            try? FileManager.default.moveItem(at: fromURL, to: destURL)
            onLibraryChanged()
            sendJSON(["ok": true])

        case "/api/delete":
            guard let rel = safeRelativePath(json["path"] as? String),
                  !rel.isEmpty,
                  let targetURL = resolvedURL(forRelativePath: rel),
                  FileManager.default.fileExists(atPath: targetURL.path) else {
                sendResponse(status: "404 Not Found", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
                return
            }
            try? FileManager.default.removeItem(at: targetURL)
            onLibraryChanged()
            sendJSON(["ok": true])

        default:
            sendResponse(status: "404 Not Found", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":true}".utf8)
        sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
    }

    private func extractBoundary(from contentType: String) -> String? {
        for component in contentType.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var value = String(trimmed.dropFirst("boundary=".count))
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func extractMultipartFile(from rawURL: URL, boundary: String) -> (tempURL: URL, fileName: String)? {
        guard let input = try? FileHandle(forReadingFrom: rawURL),
              let headData = try? input.read(upToCount: 32_768) else {
            return nil
        }
        defer { try? input.close() }

        let openingBoundary = Data("--\(boundary)".utf8)
        guard let boundaryRange = headData.range(of: openingBoundary) else { return nil }

        let searchRange = boundaryRange.upperBound..<headData.count
        guard let partHeaderEndRange = headData.range(of: headerDelimiter, in: searchRange) else { return nil }

        let partHeaderData = headData[boundaryRange.upperBound..<partHeaderEndRange.lowerBound]
        let partHeaderString = String(data: partHeaderData, encoding: .utf8) ?? ""
        let parsedFileName = parseMultipartFileName(from: partHeaderString) ?? "upload_\(Int(Date().timeIntervalSince1970)).bin"
        let safeFileName = sanitizeFileName(parsedFileName)

        let payloadStartOffset = UInt64(partHeaderEndRange.upperBound)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wifi_part_\(UUID().uuidString)_\(safeFileName)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        guard let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? output.close() }

        do {
            try input.seek(toOffset: payloadStartOffset)
            let closingMarker = Data("\r\n--\(boundary)".utf8)
            let overlap = max(closingMarker.count - 1, 0)
            var carry = Data()

            while true {
                let chunk = try input.read(upToCount: 65_536) ?? Data()
                var window = carry
                window.append(chunk)

                if let match = window.range(of: closingMarker) {
                    if match.lowerBound > 0 {
                        try output.write(contentsOf: window[..<match.lowerBound])
                    }
                    break
                }

                if chunk.isEmpty {
                    if !window.isEmpty {
                        try output.write(contentsOf: window)
                    }
                    break
                }

                let safeCount = max(0, window.count - overlap)
                if safeCount > 0 {
                    try output.write(contentsOf: window.prefix(safeCount))
                }
                carry = Data(window.suffix(window.count - safeCount))
            }
            return (outputURL, safeFileName)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    private func parseMultipartFileName(from partHeaders: String) -> String? {
        guard let start = partHeaders.range(of: "filename=\"") else { return nil }
        let rest = partHeaders[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let name = String(rest[..<end])
        return name.isEmpty ? nil : name
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = base.components(separatedBy: invalid).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "upload_\(Int(Date().timeIntervalSince1970)).bin" : cleaned
    }

    private func buildDirectoryJSON(dirRelPath: String) -> Data {
        struct Entry: Encodable {
            let name: String
            let path: String
            let isDir: Bool
            let size: String
        }
        struct Response: Encodable {
            let dir: String
            let entries: [Entry]
        }

        let targetURL = resolvedURL(forRelativePath: dirRelPath) ?? docsURL
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        var entries: [Entry] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if dirRelPath.isEmpty && name == "Inbox" { continue }
            let isDir = (values?.isDirectory == true) && url.pathExtension.lowercased() != "movpkg"
            let relPath = dirRelPath.isEmpty ? name : "\(dirRelPath)/\(name)"
            let sizeText = isDir ? "Folder" : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            entries.append(Entry(name: name, path: relPath, isDir: isDir, size: sizeText))
        }

        entries.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return (try? JSONEncoder().encode(Response(dir: dirRelPath, entries: entries))) ?? Data("{\"dir\":\"\",\"entries\":[]}".utf8)
    }

    private func streamFileDownload(at fileURL: URL, fileName: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("File not found".utf8))
            return
        }

        hasFinished = true
        let escapedName = fileName.replacingOccurrences(of: "\"", with: "")
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(escapedName)\"\r\nContent-Length: \(fileSize.int64Value)\r\nConnection: close\r\n\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                self?.cleanupAndCancel()
                return
            }
            self?.sendNextFileChunk(handle: handle)
        })
    }

    private func sendNextFileChunk(handle: FileHandle) {
        guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.finishConnection()
            })
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                self?.cleanupAndCancel()
                return
            }
            self?.sendNextFileChunk(handle: handle)
        })
    }

    private func sendResponse(status: String, contentType: String, body: Data) {
        guard !hasFinished else { return }
        hasFinished = true
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.finishConnection()
        })
    }

    private func finishConnection() {
        connection.cancel()
        onFinished()
    }

    private func cleanupAndCancel() {
        let alreadyFinished = hasFinished
        hasFinished = true
        try? tempFileHandle?.close()
        tempFileHandle = nil
        if let tempBodyURL {
            try? FileManager.default.removeItem(at: tempBodyURL)
            self.tempBodyURL = nil
        }
        if !alreadyFinished {
            connection.cancel()
        }
        onFinished()
    }

    private static let uploaderHTML = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Music Player Wi-Fi Transfer</title>
      <style>
        :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        body { margin: 0; padding: 24px; background: #0f1117; color: #f5f7fb; display: flex; justify-content: center; }
        .wrap { width: 100%; max-width: 760px; }
        .card { background: #181c26; border: 1px solid #2a3040; border-radius: 16px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 6px; font-size: 22px; }
        p.sub { margin: 0 0 16px; color: #9aa3b2; font-size: 14px; }
        .drop { border: 2px dashed #4a556e; border-radius: 14px; padding: 28px 20px; text-align: center; cursor: pointer; }
        .drop.over { border-color: #637ef5; background: rgba(99,126,245,.12); }
        .toolbar { display: flex; gap: 10px; flex-wrap: wrap; justify-content: center; margin-top: 12px; }
        .btn { padding: 9px 16px; border-radius: 10px; background: #637ef5; color: #fff; font-weight: 600; border: 0; cursor: pointer; font-size: 13px; }
        .btn.sec { background: #272e3f; }
        .btn.sm { padding: 5px 10px; font-size: 12px; border-radius: 7px; }
        .btn.del { background: #7f2930; }
        .status { margin-top: 14px; font-size: 13px; color: #b7c0d1; }
        progress { width: 100%; height: 10px; margin-top: 8px; accent-color: #637ef5; }
        .crumbs { display: flex; gap: 6px; flex-wrap: wrap; align-items: center; margin-bottom: 12px; font-size: 13px; }
        .crumbs a { color: #8ea4ff; cursor: pointer; text-decoration: none; font-weight: 600; }
        ul { list-style: none; padding: 0; margin: 0; }
        li { display: flex; justify-content: space-between; align-items: center; padding: 10px 0; border-bottom: 1px solid #252b3a; font-size: 14px; gap: 12px; }
        li:last-child { border-bottom: 0; }
        .item-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .folder-link { color: #8ea4ff; cursor: pointer; font-weight: 600; }
        .actions { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
        .meta { color: #8b94a7; font-size: 12px; }
      </style>
    </head>
    <body>
      <div class="wrap">
        <div class="card">
          <h1>Music Player Wi-Fi Transfer</h1>
          <p class="sub">Upload songs, videos, ZIPs, or documents directly into the selected folder on your iPhone.</p>
          <div id="dropZone" class="drop">
            <div>Drop files here or use the controls below</div>
            <div class="toolbar">
              <button type="button" class="btn" onclick="document.getElementById('fileInput').click()">Upload Files</button>
              <button type="button" class="btn sec" onclick="createFolder()">New Folder</button>
              <button type="button" class="btn sec" onclick="loadFiles()">Refresh</button>
            </div>
            <input id="fileInput" type="file" multiple style="display:none" />
          </div>
          <div id="uploadStatus" class="status" style="display:none">
            <div id="uploadLabel">Uploading...</div>
            <progress id="uploadBar" value="0" max="100"></progress>
          </div>
        </div>

        <div class="card">
          <div class="crumbs" id="breadcrumbs"></div>
          <ul id="fileList"><li class="meta">Loading...</li></ul>
        </div>
      </div>

      <script>
        let currentDir = '';
        const dropZone = document.getElementById('dropZone');
        const fileInput = document.getElementById('fileInput');
        const statusBox = document.getElementById('uploadStatus');
        const uploadLabel = document.getElementById('uploadLabel');
        const uploadBar = document.getElementById('uploadBar');

        dropZone.addEventListener('dragover', e => { e.preventDefault(); dropZone.classList.add('over'); });
        dropZone.addEventListener('dragleave', () => dropZone.classList.remove('over'));
        dropZone.addEventListener('drop', e => {
          e.preventDefault();
          dropZone.classList.remove('over');
          if (e.dataTransfer.files.length) uploadQueue(Array.from(e.dataTransfer.files));
        });
        fileInput.addEventListener('change', () => {
          if (fileInput.files.length) uploadQueue(Array.from(fileInput.files));
          fileInput.value = '';
        });

        async function uploadQueue(files) {
          statusBox.style.display = 'block';
          try {
            for (let i = 0; i < files.length; i++) {
              const file = files[i];
              uploadLabel.textContent = `Uploading (${i + 1}/${files.length}): ${file.name}`;
              uploadBar.value = 0;
              await uploadSingle(file);
            }
            uploadLabel.textContent = `Uploaded ${files.length} file(s)!`;
            loadFiles();
          } catch (err) {
            uploadLabel.textContent = `Upload failed: ${err && err.message ? err.message : 'Network error'}`;
          }
        }

        function uploadSingle(file) {
          return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('POST', '/upload?dir=' + encodeURIComponent(currentDir), true);
            xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name));
            xhr.setRequestHeader('X-Target-Dir', encodeURIComponent(currentDir));
            xhr.upload.onprogress = e => {
              if (e.lengthComputable) uploadBar.value = Math.round((e.loaded / e.total) * 100);
            };
            xhr.onload = () => {
              if (xhr.status >= 200 && xhr.status < 300) resolve();
              else reject(new Error(xhr.responseText || xhr.statusText));
            };
            xhr.onerror = () => reject(new Error('Connection error'));
            xhr.send(file);
          });
        }

        async function createFolder() {
          const name = prompt('New folder name:');
          if (!name || !name.trim()) return;
          await fetch('/api/mkdir', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ dir: currentDir, name: name.trim() })
          });
          loadFiles();
        }

        async function renameEntry(path, oldName) {
          const name = prompt('Rename to:', oldName);
          if (!name || !name.trim() || name.trim() === oldName) return;
          await fetch('/api/rename', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ from: path, name: name.trim() })
          });
          loadFiles();
        }

        async function deleteEntry(path, name) {
          if (!confirm(`Delete "${name}"?`)) return;
          await fetch('/api/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path })
          });
          loadFiles();
        }

        function openFolder(dir) {
          currentDir = dir;
          loadFiles();
        }

        function renderBreadcrumbs() {
          const el = document.getElementById('breadcrumbs');
          const parts = currentDir ? currentDir.split('/') : [];
          let html = `<a onclick="openFolder('')">This iPhone</a>`;
          let running = '';
          for (const part of parts) {
            running = running ? `${running}/${part}` : part;
            const target = running;
            html += ` <span>/</span> <a onclick="openFolder('${escAttr(target)}')">${esc(part)}</a>`;
          }
          el.innerHTML = html;
        }

        async function loadFiles() {
          renderBreadcrumbs();
          const list = document.getElementById('fileList');
          try {
            const res = await fetch('/api/files?dir=' + encodeURIComponent(currentDir));
            const data = await res.json();
            const entries = data.entries || [];
            if (!entries.length) {
              list.innerHTML = '<li class="meta">This folder is empty.</li>';
              return;
            }
            list.innerHTML = entries.map(e => {
              const titleHtml = e.isDir
                ? `<span class="item-name folder-link" onclick="openFolder('${escAttr(e.path)}')">&#128193; ${esc(e.name)}</span>`
                : `<span class="item-name">${esc(e.name)}</span>`;
              const dlBtn = e.isDir
                ? `<button class="btn sec sm" onclick="openFolder('${escAttr(e.path)}')">Open</button>`
                : `<a class="btn sm" style="text-decoration:none" href="/files/${encodeURIComponent(e.path)}">Download</a>`;
              return `<li>
                ${titleHtml}
                <div class="actions">
                  <span class="meta">${esc(e.size)}</span>
                  ${dlBtn}
                  <button class="btn sec sm" onclick="renameEntry('${escAttr(e.path)}','${escAttr(e.name)}')">Rename</button>
                  <button class="btn del sm" onclick="deleteEntry('${escAttr(e.path)}','${escAttr(e.name)}')">Delete</button>
                </div>
              </li>`;
            }).join('');
          } catch {
            list.innerHTML = '<li class="meta">Could not load files.</li>';
          }
        }

        function esc(s) {
          return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        }
        function escAttr(s) {
          return String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
        }

        loadFiles();
      </script>
    </body>
    </html>
    """
}
