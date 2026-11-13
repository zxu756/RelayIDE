import Darwin
import Foundation
import RelayModels

// MARK: - Loopback BSD Socket HTTP Telemetry & Circuit-Breaker Proxy (127.0.0.1)

public final class LoopbackWiretapProxyServer: @unchecked Sendable {
    public let ledger: BudgetCircuitBreakerLedger
    private let parser = ProviderTokenStreamParser()
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPortValue: UInt16 = 0
    private var acceptQueue: DispatchQueue?
    private var isRunningFlag: Bool = false
    private let upstreamTransport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?

    public init(
        ledger: BudgetCircuitBreakerLedger = BudgetCircuitBreakerLedger(),
        upstreamTransport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.ledger = ledger
        self.upstreamTransport = upstreamTransport
    }

    deinit {
        stop()
    }

    public var boundPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPortValue
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningFlag
    }

    /// Starts the loopback proxy on `127.0.0.1` (`port == 0` picks an ephemeral kernel port).
    @discardableResult
    public func start(port: UInt16 = 0) throws -> UInt16 {
        lock.lock()
        if isRunningFlag {
            let p = boundPortValue
            lock.unlock()
            return p
        }
        lock.unlock()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw RelayIDEError.proxyBindFailure(port: port, reason: String(cString: strerror(errno)))
        }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw RelayIDEError.proxyBindFailure(port: port, reason: msg)
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw RelayIDEError.proxyBindFailure(port: port, reason: msg)
        }

        var assignedAddr = sockaddr_in()
        var assignedLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assignedAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &assignedLen)
            }
        }
        let actualPort = UInt16(bigEndian: assignedAddr.sin_port)

        let queue = DispatchQueue(label: "io.github.zxu756.RelayIDE.wiretap-accept", qos: .userInitiated)
        lock.lock()
        self.listenFD = fd
        self.boundPortValue = actualPort
        self.acceptQueue = queue
        self.isRunningFlag = true
        lock.unlock()

        queue.async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }
        return actualPort
    }

    public func stop() {
        lock.lock()
        guard isRunningFlag else {
            lock.unlock()
            return
        }
        isRunningFlag = false
        let fd = listenFD
        listenFD = -1
        boundPortValue = 0
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
    }

    /// Generates environment variables (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, etc.) routing an agent lane through this proxy.
    public func proxyEnvironmentVariables(forLane laneID: String, vendor: AgentVendor) -> [String: String] {
        let port = boundPort
        guard port > 0 else { return [:] }
        let base = "http://127.0.0.1:\(port)/lane/\(laneID)/\(vendor.rawValue)"
        return [
            "RELAY_WIRETAP_LANE": laneID,
            "RELAY_WIRETAP_VENDOR": vendor.rawValue,
            "ANTHROPIC_BASE_URL": "\(base)/https/api.anthropic.com",
            "OPENAI_BASE_URL": "\(base)/https/api.openai.com/v1",
            "MISTRAL_API_BASE": "\(base)/https/api.mistral.ai"
        ]
    }

    private func acceptLoop(serverFD: Int32) {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                if !isRunning { break }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    Darwin.close(clientFD)
                    return
                }
                Task {
                    await self.handleClientConnection(fd: clientFD)
                }
            }
        }
    }

    private func handleClientConnection(fd: Int32) async {
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        guard let rawRequest = readHTTPRequest(from: fd) else { return }

        // Health check endpoint: GET /healthz
        if rawRequest.path == "/healthz" {
            let payload = Data(#"{"status":"ok","totalSpendUSD":\#(String(format: "%.6f", ledger.totalSpendUSD()))}"#.utf8)
            writeHTTPResponse(to: fd, statusCode: 200, statusText: "OK", contentType: "application/json", body: payload)
            return
        }

        // Route format: /lane/<laneID>/<vendor>/https/<upstreamHost>/<rest...>
        let parts = rawRequest.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 5, parts[0] == "lane" else {
            let errBody = Data(#"{"error":"Invalid wiretap route"}"#.utf8)
            writeHTTPResponse(to: fd, statusCode: 400, statusText: "Bad Request", contentType: "application/json", body: errBody)
            return
        }

        let laneID = parts[1]
        let vendor = AgentVendor(rawValue: parts[2]) ?? .customShell
        let scheme = parts[3]
        let upstreamHost = parts[4]
        let tailPath = parts.dropFirst(5).joined(separator: "/")
        let targetURLString = "\(scheme)://\(upstreamHost)/\(tailPath)" + (rawRequest.query.map { "?\($0)" } ?? "")

        do {
            try ledger.checkAdmission(forLane: laneID)
        } catch {
            _ = ledger.recordBlockedAttempt(laneID: laneID, vendor: vendor, providerHost: upstreamHost)
            let blockedJSON = Data(#"{"error":{"type":"relay_budget_exceeded","message":"\#(error.localizedDescription)"}}"#.utf8)
            writeHTTPResponse(to: fd, statusCode: 429, statusText: "Too Many Requests", contentType: "application/json", body: blockedJSON)
            return
        }

        guard let targetURL = URL(string: targetURLString) else {
            writeHTTPResponse(to: fd, statusCode: 400, statusText: "Bad Request", contentType: "application/json", body: Data(#"{"error":"Invalid upstream URL"}"#.utf8))
            return
        }

        var urlReq = URLRequest(url: targetURL)
        urlReq.httpMethod = rawRequest.method
        urlReq.httpBody = rawRequest.body
        for (k, v) in rawRequest.headers {
            let lower = k.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            urlReq.setValue(v, forHTTPHeaderField: k)
        }

        let startNs = DispatchTime.now().uptimeNanoseconds
        do {
            let (respData, httpResp): (Data, HTTPURLResponse)
            if let customTransport = upstreamTransport {
                (respData, httpResp) = try await customTransport(urlReq)
            } else {
                let (d, r) = try await URLSession.shared.data(for: urlReq)
                guard let hr = r as? HTTPURLResponse else {
                    throw RelayIDEError.proxyBindFailure(port: boundPort, reason: "Non-HTTP upstream response")
                }
                (respData, httpResp) = (d, hr)
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            let usage = parser.parsePayload(responseBody: respData, requestBody: rawRequest.body)
            _ = ledger.recordUsage(
                laneID: laneID,
                vendor: vendor,
                providerHost: upstreamHost,
                usage: usage,
                durationMs: elapsedMs,
                statusCode: httpResp.statusCode
            )
            let ctype = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            writeHTTPResponse(to: fd, statusCode: httpResp.statusCode, statusText: "OK", contentType: ctype, body: respData)
        } catch {
            let errJSON = Data(#"{"error":"Upstream request failed: \#(error.localizedDescription)"}"#.utf8)
            writeHTTPResponse(to: fd, statusCode: 502, statusText: "Bad Gateway", contentType: "application/json", body: errJSON)
        }
    }

    private struct ParsedRawHTTP {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: Data
    }

    private func readHTTPRequest(from fd: Int32) -> ParsedRawHTTP? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let separator = Data([13, 10, 13, 10])
        var headerEndIndex: Int?

        while headerEndIndex == nil && buffer.count < 262_144 {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = buffer.range(of: separator) {
                headerEndIndex = range.upperBound
            }
        }

        guard let bodyStart = headerEndIndex else { return nil }
        let headerString = String(decoding: buffer[0..<(bodyStart - 4)], as: UTF8.self)
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let reqTokens = requestLine.split(separator: " ")
        guard reqTokens.count >= 2 else { return nil }
        let method = String(reqTokens[0])
        let rawTarget = String(reqTokens[1])
        let targetSplit = rawTarget.split(separator: "?", maxSplits: 1)
        let path = String(targetSplit[0])
        let query = targetSplit.count > 1 ? String(targetSplit[1]) : nil

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
            if key.lowercased() == "content-length", let len = Int(val) {
                contentLength = max(0, len)
            }
        }

        while (buffer.count - bodyStart) < contentLength && buffer.count < 8_388_608 {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }

        let bodyEnd = min(buffer.count, bodyStart + contentLength)
        let body = bodyStart < bodyEnd ? Data(buffer[bodyStart..<bodyEnd]) : Data()
        return ParsedRawHTTP(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func writeHTTPResponse(
        to fd: Int32,
        statusCode: Int,
        statusText: String,
        contentType: String,
        body: Data
    ) {
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < out.count {
                let n = Darwin.write(fd, base.advanced(by: sent), out.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
