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

    var onFileReceived: ((URL, String) -> Void)?

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
            onUploadComplete: { [weak self] tempURL, fileName in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.recentUploads.insert(UploadedEntry(fileName: fileName), at: 0)
                    if self.recentUploads.count > 20 {
                        self.recentUploads.removeLast(self.recentUploads.count - 20)
                    }
                    self.onFileReceived?(tempURL, fileName)
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

    // Helper to retrieve local Wi-Fi (or hotspot) IPv4 address
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
    private let onUploadComplete: (URL, String) -> Void
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
        onUploadComplete: @escaping (URL, String) -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.connection = connection
        self.docsURL = docsURL
        self.onUploadComplete = onUploadComplete
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
                    self.finalizeUpload()
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
                beginReceivingUpload(initialRemainder: remainder)
            default:
                sendResponse(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Method not allowed".utf8))
            }
            return
        }

        writeBodyChunk(chunk)
        if expectedBodyLength > 0 && receivedBodyBytes >= expectedBodyLength {
            finalizeUpload()
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

    private func handleGetRequest() {
        let cleanPath = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        if cleanPath == "/" {
            sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(Self.uploaderHTML.utf8))
            return
        }

        if cleanPath == "/api/files" {
            let filesPayload = buildFilesJSON()
            sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: filesPayload)
            return
        }

        if cleanPath.hasPrefix("/files/") {
            let encodedName = String(cleanPath.dropFirst("/files/".count))
            let decodedPath = (encodedName.removingPercentEncoding ?? encodedName)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !decodedPath.isEmpty,
                  !decodedPath.contains("..") else {
                sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("File not found".utf8))
                return
            }
            let targetURL = docsURL.appendingPathComponent(decodedPath).standardizedFileURL
            let rootPath = docsURL.standardizedFileURL.path
            guard targetURL.path.hasPrefix(rootPath + "/"),
                  !targetURL.lastPathComponent.hasPrefix("."),
                  FileManager.default.fileExists(atPath: targetURL.path) else {
                sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("File not found".utf8))
                return
            }
            streamFileDownload(at: targetURL, fileName: targetURL.lastPathComponent)
            return
        }

        sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
    }

    private func beginReceivingUpload(initialRemainder: Data) {
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
            finalizeUpload()
        } else if expectedBodyLength == 0 && !initialRemainder.isEmpty {
            finalizeUpload()
        } else {
            receiveNextChunk()
        }
    }

    private func writeBodyChunk(_ chunk: Data) {
        guard let handle = tempFileHandle else { return }
        let sliceToWrite: Data
        if expectedBodyLength > 0 {
            let remaining = max(Int64(0), expectedBodyLength - receivedBodyBytes)
            if Int64(chunk.count) > remaining {
                sliceToWrite = chunk.prefix(Int(remaining))
            } else {
                sliceToWrite = chunk
            }
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

    private func finalizeUpload() {
        guard !hasFinished else { return }
        try? tempFileHandle?.close()
        tempFileHandle = nil

        guard let rawURL = tempBodyURL else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("No upload data".utf8))
            return
        }
        tempBodyURL = nil

        let contentType = headers["content-type"] ?? ""
        if contentType.lowercased().contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            if let extracted = extractMultipartFile(from: rawURL, boundary: boundary) {
                try? FileManager.default.removeItem(at: rawURL)
                onUploadComplete(extracted.tempURL, extracted.fileName)
                let html = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="1;url=/"></head>
                <body style="font-family:-apple-system,sans-serif;padding:32px;background:#111;color:#fff;">
                <h2>Uploaded \(Self.escapeHTML(extracted.fileName))</h2>
                <p>Returning to uploader...</p><p><a href="/" style="color:#6c8cff;">Back</a></p>
                </body></html>
                """
                sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
            } else {
                try? FileManager.default.removeItem(at: rawURL)
                sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Could not parse uploaded file".utf8))
            }
            return
        }

        let headerName = headers["x-file-name"]?.removingPercentEncoding
        let pathName: String? = {
            let clean = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            if clean.hasPrefix("/upload/") {
                let raw = String(clean.dropFirst("/upload/".count))
                return raw.removingPercentEncoding ?? raw
            }
            return nil
        }()

        let rawCandidate = (headerName?.isEmpty == false ? headerName : pathName) ?? "upload_\(Int(Date().timeIntervalSince1970)).bin"
        let safeFileName = sanitizeFileName(rawCandidate)
        onUploadComplete(rawURL, safeFileName)

        let json = "{\"ok\":true,\"fileName\":\"\(safeFileName.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: Data(json.utf8))
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

    private func buildFilesJSON() -> Data {
        struct FileEntry: Encodable {
            let name: String
            let size: String
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        let rootPath = docsURL.standardizedFileURL.path
        var entries: [FileEntry] = []

        if let enumerator = FileManager.default.enumerator(
            at: docsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if url.pathExtension.lowercased() == "movpkg" || url.lastPathComponent == "Inbox" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let fullPath = url.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPath + "/") else { continue }
                let relPath = String(fullPath.dropFirst(rootPath.count + 1))
                let bytes = Int64(values?.fileSize ?? 0)
                entries.append(
                    FileEntry(
                        name: relPath,
                        size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    )
                )
            }
        }

        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
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

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
        .wrap { width: 100%; max-width: 680px; }
        .card { background: #181c26; border: 1px solid #2a3040; border-radius: 16px; padding: 24px; margin-bottom: 20px; }
        h1 { margin: 0 0 6px; font-size: 22px; }
        p.sub { margin: 0 0 18px; color: #9aa3b2; font-size: 14px; }
        .drop { border: 2px dashed #4a556e; border-radius: 14px; padding: 34px 20px; text-align: center; cursor: pointer; transition: border-color .15s, background .15s; }
        .drop.over { border-color: #637ef5; background: rgba(99,126,245,.12); }
        .btn { display: inline-block; margin-top: 12px; padding: 10px 18px; border-radius: 10px; background: #637ef5; color: #fff; font-weight: 600; border: 0; cursor: pointer; font-size: 14px; }
        .status { margin-top: 16px; font-size: 14px; color: #b7c0d1; }
        progress { width: 100%; height: 10px; margin-top: 8px; accent-color: #637ef5; }
        ul { list-style: none; padding: 0; margin: 12px 0 0; }
        li { display: flex; justify-content: space-between; align-items: center; padding: 10px 0; border-bottom: 1px solid #252b3a; font-size: 14px; gap: 12px; }
        li:last-child { border-bottom: 0; }
        a.dl { color: #8ea4ff; text-decoration: none; font-weight: 600; white-space: nowrap; }
        .meta { color: #8b94a7; font-size: 12px; white-space: nowrap; }
      </style>
    </head>
    <body>
      <div class="wrap">
        <div class="card">
          <h1>Music Player Wi-Fi Transfer</h1>
          <p class="sub">Upload audio, video, PDFs, or documents directly to your iPhone.</p>
          <div id="dropZone" class="drop">
            <div>Drop files here or choose from your computer</div>
            <button type="button" class="btn" onclick="document.getElementById('fileInput').click()">Select Files</button>
            <input id="fileInput" type="file" multiple style="display:none" />
          </div>
          <div id="uploadStatus" class="status" style="display:none">
            <div id="uploadLabel">Uploading...</div>
            <progress id="uploadBar" value="0" max="100"></progress>
          </div>
          <noscript>
            <form method="POST" enctype="multipart/form-data" style="margin-top:16px">
              <input type="file" name="file" />
              <input type="submit" value="Upload to iPhone" />
            </form>
          </noscript>
        </div>

        <div class="card">
          <h2 style="margin:0 0 6px;font-size:17px;">Files on iPhone</h2>
          <ul id="fileList"><li class="meta">Loading...</li></ul>
        </div>
      </div>

      <script>
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
            xhr.open('POST', '/upload', true);
            xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name));
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

        async function loadFiles() {
          const list = document.getElementById('fileList');
          try {
            const res = await fetch('/api/files');
            const files = await res.json();
            if (!files.length) {
              list.innerHTML = '<li class="meta">No files saved yet.</li>';
              return;
            }
            list.innerHTML = files.map(f =>
              `<li><span style="overflow:hidden;text-overflow:ellipsis;">${esc(f.name)}</span><span><span class="meta">${esc(f.size)}</span> &nbsp; <a class="dl" href="/files/${encodeURIComponent(f.name)}">Download</a></span></li>`
            ).join('');
          } catch {
            list.innerHTML = '<li class="meta">Could not load files.</li>';
          }
        }

        function esc(s) {
          return s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        }

        loadFiles();
      </script>
    </body>
    </html>
    """
}
