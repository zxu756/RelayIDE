import Foundation
import RelayModels

// MARK: - Typed Sendable JSON Value for Tool Arguments & Wire Metadata

public enum WireJSONValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([WireJSONValue])
    case object([String: WireJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let intVal = try? container.decode(Int64.self) {
            self = .integer(intVal)
        } else if let dblVal = try? container.decode(Double.self) {
            self = .number(dblVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arrVal = try? container.decode([WireJSONValue].self) {
            self = .array(arrVal)
        } else if let objVal = try? container.decode([String: WireJSONValue].self) {
            self = .object(objVal)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .integer(let v):
            try container.encode(v)
        case .number(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

    public static func fromAny(_ raw: Any) -> WireJSONValue {
        if raw is NSNull {
            return .null
        }
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            let dbl = num.doubleValue
            if dbl.rounded(.towardZero) == dbl, dbl >= Double(Int64.min), dbl <= Double(Int64.max) {
                return .integer(num.int64Value)
            }
            return .number(dbl)
        }
        if let str = raw as? String {
            return .string(str)
        }
        if let arr = raw as? [Any] {
            return .array(arr.map { fromAny($0) })
        }
        if let dict = raw as? [String: Any] {
            var mapped: [String: WireJSONValue] = [:]
            mapped.reserveCapacity(dict.count)
            for (k, v) in dict {
                mapped[k] = fromAny(v)
            }
            return .object(mapped)
        }
        return .string(String(describing: raw))
    }

    public var compactPreview: String {
        switch self {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .integer(let i):
            return String(i)
        case .number(let d):
            return String(format: "%.4g", d)
        case .string(let s):
            if s.count > 48 {
                return "\"\(s.prefix(45))...\""
            }
            return "\"\(s)\""
        case .array(let items):
            let inner = items.prefix(4).map(\.compactPreview).joined(separator: ", ")
            return items.count > 4 ? "[\(inner), +\(items.count - 4) more]" : "[\(inner)]"
        case .object(let dict):
            let sortedKeys = dict.keys.sorted()
            let inner = sortedKeys.prefix(4).compactMap { k -> String? in
                guard let v = dict[k] else { return nil }
                return "\(k): \(v.compactPreview)"
            }.joined(separator: ", ")
            return sortedKeys.count > 4 ? "{\(inner), +\(sortedKeys.count - 4) keys}" : "{\(inner)}"
        }
    }
}

// MARK: - Case-Insensitive Ordered HTTP/1.1 Header Map

public struct HTTPHeaderField: Sendable, Codable, Hashable {
    public let wireName: String
    public let normalizedName: String
    public var value: String

    public init(name: String, value: String) {
        self.wireName = name
        self.normalizedName = name.lowercased()
        self.value = value
    }
}

public struct HTTPHeaderMap: Sendable, Codable, Hashable, Sequence {
    public private(set) var fields: [HTTPHeaderField] = []
    private var indicesByLowerName: [String: [Int]] = [:]

    public init(fields: [HTTPHeaderField] = []) {
        for field in fields {
            append(name: field.wireName, value: field.value)
        }
    }

    public init(dictionary: [String: String]) {
        for key in dictionary.keys.sorted() {
            if let value = dictionary[key] {
                append(name: key, value: value)
            }
        }
    }

    public mutating func append(name: String, value: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        let field = HTTPHeaderField(name: trimmedName, value: trimmedValue)
        let idx = fields.count
        fields.append(field)
        indicesByLowerName[field.normalizedName, default: []].append(idx)
    }

    public mutating func set(name: String, value: String) {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let existingIndices = indicesByLowerName[lower], let first = existingIndices.first {
            fields[first].value = value.trimmingCharacters(in: .whitespaces)
            if existingIndices.count > 1 {
                for removeIdx in existingIndices.dropFirst().reversed() {
                    fields.remove(at: removeIdx)
                }
                rebuildIndex()
            }
        } else {
            append(name: name, value: value)
        }
    }

    public mutating func appendFoldedContinuation(_ continuationLine: String) -> Bool {
        guard !fields.isEmpty else { return false }
        let extra = continuationLine.trimmingCharacters(in: .whitespaces)
        guard !extra.isEmpty else { return true }
        let lastIdx = fields.count - 1
        fields[lastIdx].value += " " + extra
        return true
    }

    public func value(for name: String) -> String? {
        let lower = name.lowercased()
        guard let indices = indicesByLowerName[lower], let first = indices.first else {
            return nil
        }
        return fields[first].value
    }

    public func values(for name: String) -> [String] {
        let lower = name.lowercased()
        guard let indices = indicesByLowerName[lower] else { return [] }
        return indices.map { fields[$0].value }
    }

    public var count: Int { fields.count }
    public var isEmpty: Bool { fields.isEmpty }

    public func makeIterator() -> IndexingIterator<[HTTPHeaderField]> {
        fields.makeIterator()
    }

    public var contentLength: Int? {
        guard let raw = value(for: "content-length")?.trimmingCharacters(in: .whitespaces),
              let parsed = Int(raw), parsed >= 0 else {
            return nil
        }
        return parsed
    }

    public var isChunkedTransferEncoding: Bool {
        let encodings = values(for: "transfer-encoding")
        for headerVal in encodings {
            for token in headerVal.split(separator: ",") {
                if token.trimmingCharacters(in: .whitespaces).lowercased() == "chunked" {
                    return true
                }
            }
        }
        return false
    }

    public var isEventStreamContentType: Bool {
        guard let ct = value(for: "content-type")?.lowercased() else { return false }
        return ct.contains("text/event-stream")
    }

    public var isNDJSONOrStreamJSON: Bool {
        guard let ct = value(for: "content-type")?.lowercased() else { return false }
        return ct.contains("application/x-ndjson") || ct.contains("application/stream+json")
    }

    public var requestID: String? {
        value(for: "request-id")
            ?? value(for: "x-request-id")
            ?? value(for: "anthropic-request-id")
            ?? value(for: "x-goog-request-id")
    }

    public func toDictionary() -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            if let prev = result[field.wireName] {
                result[field.wireName] = "\(prev), \(field.value)"
            } else {
                result[field.wireName] = field.value
            }
        }
        return result
    }

    private mutating func rebuildIndex() {
        indicesByLowerName.removeAll(keepingCapacity: true)
        for (idx, field) in fields.enumerated() {
            indicesByLowerName[field.normalizedName, default: []].append(idx)
        }
    }
}

// MARK: - Handwritten HTTP/1.1 Request/Response & Chunked State Machine

public enum HTTP11MessageRole: String, Sendable, Codable, Hashable {
    case request
    case response
}

public enum HTTP11StartLine: Sendable, Codable, Hashable {
    case request(method: String, rawTarget: String, path: String, query: String?, version: String)
    case response(version: String, statusCode: Int, reasonPhrase: String)

    public var role: HTTP11MessageRole {
        switch self {
        case .request: return .request
        case .response: return .response
        }
    }

    public var statusCode: Int? {
        if case .response(_, let code, _) = self {
            return code
        }
        return nil
    }

    public var requestMethod: String? {
        if case .request(let method, _, _, _, _) = self {
            return method
        }
        return nil
    }

    public var requestPath: String? {
        if case .request(_, _, let path, _, _) = self {
            return path
        }
        return nil
    }
}

public enum HTTP11DissectorError: Error, LocalizedError, Sendable, Equatable {
    case emptyOrMalformedStartLine(String)
    case headerSectionExceedsLimit(maxBytes: Int)
    case malformedHeaderLine(String)
    case conflictingFramingHeaders
    case invalidContentLength(String)
    case invalidChunkSizeHex(String)
    case chunkSizeExceedsLimit(chunkBytes: Int, maxBytes: Int)
    case missingChunkTerminatingCRLF
    case bodyExceedsLimit(maxBytes: Int)
    case truncatedMessageAtEOF(stateDescription: String)

    public var errorDescription: String? {
        switch self {
        case .emptyOrMalformedStartLine(let line):
            return "Malformed HTTP/1.1 start line: '\(line)'"
        case .headerSectionExceedsLimit(let maxBytes):
            return "HTTP/1.1 header block exceeded \(maxBytes) bytes"
        case .malformedHeaderLine(let line):
            return "Malformed HTTP/1.1 header line: '\(line)'"
        case .conflictingFramingHeaders:
            return "Conflicting Transfer-Encoding: chunked and Content-Length headers"
        case .invalidContentLength(let val):
            return "Invalid HTTP/1.1 Content-Length value: '\(val)'"
        case .invalidChunkSizeHex(let hex):
            return "Invalid Transfer-Encoding chunk size hex token: '\(hex)'"
        case .chunkSizeExceedsLimit(let chunkBytes, let maxBytes):
            return "HTTP chunk size \(chunkBytes) exceeds safety ceiling \(maxBytes)"
        case .missingChunkTerminatingCRLF:
            return "Missing CRLF delimiter after chunk payload"
        case .bodyExceedsLimit(let maxBytes):
            return "HTTP/1.1 payload exceeded \(maxBytes) bytes"
        case .truncatedMessageAtEOF(let desc):
            return "Unexpected EOF in HTTP/1.1 state '\(desc)'"
        }
    }
}

public struct HTTP11ChunkExtension: Sendable, Codable, Hashable {
    public let name: String
    public let value: String?

    public init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }
}

public struct HTTP11ChunkFrameMetadata: Sendable, Codable, Hashable {
    public let chunkIndex: Int
    public let declaredSize: Int
    public let extensions: [HTTP11ChunkExtension]
    public let wireOffset: Int

    public init(chunkIndex: Int, declaredSize: Int, extensions: [HTTP11ChunkExtension] = [], wireOffset: Int) {
        self.chunkIndex = chunkIndex
        self.declaredSize = declaredSize
        self.extensions = extensions
        self.wireOffset = wireOffset
    }
}

public struct HTTP11DissectedMessage: Sendable, Codable, Hashable {
    public let startLine: HTTP11StartLine
    public let headers: HTTPHeaderMap
    public let body: Data
    public let trailers: HTTPHeaderMap
    public let wireHeaderBytes: Int
    public let wireBodyBytes: Int
    public let wasChunked: Bool
    public let chunkFrames: [HTTP11ChunkFrameMetadata]

    public init(
        startLine: HTTP11StartLine,
        headers: HTTPHeaderMap,
        body: Data,
        trailers: HTTPHeaderMap = HTTPHeaderMap(),
        wireHeaderBytes: Int,
        wireBodyBytes: Int,
        wasChunked: Bool,
        chunkFrames: [HTTP11ChunkFrameMetadata] = []
    ) {
        self.startLine = startLine
        self.headers = headers
        self.body = body
        self.trailers = trailers
        self.wireHeaderBytes = wireHeaderBytes
        self.wireBodyBytes = wireBodyBytes
        self.wasChunked = wasChunked
        self.chunkFrames = chunkFrames
    }
}

/// Incremental byte-exact HTTP/1.1 request/response & `Transfer-Encoding: chunked` state machine.
public struct HTTP11WireStateMachine: Sendable {
    private enum Phase: Sendable {
        case awaitingStartLine
        case readingHeaders
        case readingFixedBody(remaining: Int)
        case readingChunkSizeLine
        case readingChunkData(remaining: Int)
        case readingChunkDataCRLF
        case readingChunkTrailers
        case readingUntilEOFBody
    }

    public let expectedRole: HTTP11MessageRole?
    public let requestMethodHint: String?
    public let maxHeaderBytes: Int
    public let maxBodyBytes: Int
    public let allowLenientLF: Bool

    private var phase: Phase = .awaitingStartLine
    private var buffer = Data()
    private var readCursor: Int = 0
    private var totalConsumedBytes: Int = 0

    private var currentStartLine: HTTP11StartLine?
    private var currentHeaders = HTTPHeaderMap()
    private var currentTrailers = HTTPHeaderMap()
    private var assembledBody = Data()
    private var headerBytesCount: Int = 0
    private var bodyWireStartOffset: Int = 0
    private var wasChunkedFlag: Bool = false
    private var chunkFrames: [HTTP11ChunkFrameMetadata] = []

    /// Callback hook invoked synchronously on incremental body slices (ideal for live TTFT & SSE streaming).
    public var onBodySliceDecoded: (@Sendable (Data) -> Void)?

    public init(
        expectedRole: HTTP11MessageRole? = nil,
        requestMethodHint: String? = nil,
        maxHeaderBytes: Int = 131_072,
        maxBodyBytes: Int = 33_554_432,
        allowLenientLF: Bool = true
    ) {
        self.expectedRole = expectedRole
        self.requestMethodHint = requestMethodHint
        self.maxHeaderBytes = max(4_096, maxHeaderBytes)
        self.maxBodyBytes = max(65_536, maxBodyBytes)
        self.allowLenientLF = allowLenientLF
    }

    public var bufferedUnreadByteCount: Int {
        max(0, buffer.count - readCursor)
    }

    public var isIdleAtBoundary: Bool {
        if case .awaitingStartLine = phase {
            return bufferedUnreadByteCount == 0
        }
        return false
    }

    /// Feeds arbitrary network chunks into the state machine and returns zero or more fully dissected HTTP/1.1 messages.
    public mutating func feed(_ incoming: Data) throws -> [HTTP11DissectedMessage] {
        guard !incoming.isEmpty else { return [] }
        buffer.append(incoming)
        var completed: [HTTP11DissectedMessage] = []

        loop: while true {
            switch phase {
            case .awaitingStartLine:
                // Skip RFC 9112 §2.2 leading empty CRLF lines prior to start-line for robustness
                while let peekLine = tryReadLine() {
                    let trimmed = peekLine.line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        headerBytesCount += peekLine.wireLength
                        continue
                    }
                    let parsed = try Self.parseStartLine(trimmed, expectedRole: expectedRole)
                    currentStartLine = parsed
                    headerBytesCount += peekLine.wireLength
                    phase = .readingHeaders
                    continue loop
                }
                if bufferedUnreadByteCount > maxHeaderBytes {
                    throw HTTP11DissectorError.headerSectionExceedsLimit(maxBytes: maxHeaderBytes)
                }
                break loop

            case .readingHeaders:
                guard let headerLine = tryReadLine() else {
                    if headerBytesCount + bufferedUnreadByteCount > maxHeaderBytes {
                        throw HTTP11DissectorError.headerSectionExceedsLimit(maxBytes: maxHeaderBytes)
                    }
                    break loop
                }
                headerBytesCount += headerLine.wireLength
                if headerBytesCount > maxHeaderBytes {
                    throw HTTP11DissectorError.headerSectionExceedsLimit(maxBytes: maxHeaderBytes)
                }

                if headerLine.line.isEmpty {
                    // End of HTTP header section
                    bodyWireStartOffset = totalConsumedBytes
                    if let msg = try transitionAfterHeaders() {
                        completed.append(msg)
                    }
                    continue loop
                }

                // Check obs-fold continuation line (leading SP or HTAB)
                if let first = headerLine.line.first, (first == " " || first == "\t") {
                    guard currentHeaders.appendFoldedContinuation(headerLine.line) else {
                        throw HTTP11DissectorError.malformedHeaderLine(headerLine.line)
                    }
                    continue loop
                }

                guard let colon = headerLine.line.firstIndex(of: ":") else {
                    throw HTTP11DissectorError.malformedHeaderLine(headerLine.line)
                }
                let name = String(headerLine.line[..<colon])
                let value = String(headerLine.line[headerLine.line.index(after: colon)...])
                if name.isEmpty || name.contains(where: \.isWhitespace) {
                    throw HTTP11DissectorError.malformedHeaderLine(headerLine.line)
                }
                currentHeaders.append(name: name, value: value)

            case .readingFixedBody(let remaining):
                if remaining == 0 {
                    completed.append(emitCurrentMessage())
                    continue loop
                }
                let avail = bufferedUnreadByteCount
                guard avail > 0 else { break loop }
                let take = min(remaining, avail)
                let slice = consumeBytes(count: take)
                try appendDecodedBodySlice(slice)
                let left = remaining - take
                if left == 0 {
                    completed.append(emitCurrentMessage())
                } else {
                    phase = .readingFixedBody(remaining: left)
                }

            case .readingChunkSizeLine:
                let chunkWirePos = totalConsumedBytes
                guard let sizeLine = tryReadLine() else {
                    if bufferedUnreadByteCount > 4_096 {
                        throw HTTP11DissectorError.invalidChunkSizeHex("<oversized-chunk-header>")
                    }
                    break loop
                }
                let (chunkLen, exts) = try Self.parseChunkSizeLine(sizeLine.line)
                if chunkLen > maxBodyBytes || (assembledBody.count + chunkLen) > maxBodyBytes {
                    throw HTTP11DissectorError.chunkSizeExceedsLimit(chunkBytes: chunkLen, maxBytes: maxBodyBytes)
                }
                chunkFrames.append(
                    HTTP11ChunkFrameMetadata(
                        chunkIndex: chunkFrames.count,
                        declaredSize: chunkLen,
                        extensions: exts,
                        wireOffset: chunkWirePos
                    )
                )
                if chunkLen == 0 {
                    phase = .readingChunkTrailers
                } else {
                    phase = .readingChunkData(remaining: chunkLen)
                }

            case .readingChunkData(let remaining):
                let avail = bufferedUnreadByteCount
                guard avail > 0 else { break loop }
                let take = min(remaining, avail)
                let slice = consumeBytes(count: take)
                try appendDecodedBodySlice(slice)
                let left = remaining - take
                if left == 0 {
                    phase = .readingChunkDataCRLF
                } else {
                    phase = .readingChunkData(remaining: left)
                }

            case .readingChunkDataCRLF:
                let avail = bufferedUnreadByteCount
                if avail < 1 { break loop }
                let firstByte = buffer[readCursor]
                if firstByte == 13 { // '\r'
                    guard avail >= 2 else { break loop }
                    let secondByte = buffer[readCursor + 1]
                    guard secondByte == 10 else {
                        throw HTTP11DissectorError.missingChunkTerminatingCRLF
                    }
                    _ = consumeBytes(count: 2)
                    phase = .readingChunkSizeLine
                } else if allowLenientLF && firstByte == 10 { // '\n'
                    _ = consumeBytes(count: 1)
                    phase = .readingChunkSizeLine
                } else {
                    throw HTTP11DissectorError.missingChunkTerminatingCRLF
                }

            case .readingChunkTrailers:
                guard let trailerLine = tryReadLine() else { break loop }
                if trailerLine.line.isEmpty {
                    completed.append(emitCurrentMessage())
                    continue loop
                }
                guard let colon = trailerLine.line.firstIndex(of: ":") else {
                    throw HTTP11DissectorError.malformedHeaderLine(trailerLine.line)
                }
                let name = String(trailerLine.line[..<colon])
                let value = String(trailerLine.line[trailerLine.line.index(after: colon)...])
                currentTrailers.append(name: name, value: value)

            case .readingUntilEOFBody:
                let avail = bufferedUnreadByteCount
                if avail > 0 {
                    let slice = consumeBytes(count: avail)
                    try appendDecodedBodySlice(slice)
                }
                break loop
            }
        }

        compactBufferIfNeeded()
        return completed
    }

    /// Signals upstream socket EOF so `Connection: close` responses without Content-Length can finalize cleanly.
    public mutating func finishEOF() throws -> HTTP11DissectedMessage? {
        switch phase {
        case .awaitingStartLine:
            if bufferedUnreadByteCount == 0 {
                return nil
            }
            throw HTTP11DissectorError.truncatedMessageAtEOF(stateDescription: "awaitingStartLine")
        case .readingUntilEOFBody:
            if bufferedUnreadByteCount > 0 {
                let rem = consumeBytes(count: bufferedUnreadByteCount)
                try appendDecodedBodySlice(rem)
            }
            return emitCurrentMessage()
        case .readingHeaders:
            throw HTTP11DissectorError.truncatedMessageAtEOF(stateDescription: "readingHeaders")
        case .readingFixedBody(let rem):
            throw HTTP11DissectorError.truncatedMessageAtEOF(stateDescription: "readingFixedBody(remaining=\(rem))")
        case .readingChunkSizeLine, .readingChunkData, .readingChunkDataCRLF, .readingChunkTrailers:
            throw HTTP11DissectorError.truncatedMessageAtEOF(stateDescription: "chunkedTransferIncomplete")
        }
    }

    /// Encodes a payload using HTTP/1.1 `Transfer-Encoding: chunked` framing for proxy forwarding or synthetic tests.
    public static func encodeChunkedBody(_ payload: Data, maxChunkSize: Int = 4_096, trailers: HTTPHeaderMap = HTTPHeaderMap()) -> Data {
        let step = max(1, maxChunkSize)
        var encoded = Data()
        var offset = 0
        while offset < payload.count {
            let len = min(step, payload.count - offset)
            let hexPrefix = String(len, radix: 16, uppercase: false) + "\r\n"
            encoded.append(Data(hexPrefix.utf8))
            encoded.append(payload.subdata(in: offset..<(offset + len)))
            encoded.append(Data([13, 10]))
            offset += len
        }
        encoded.append(Data("0\r\n".utf8))
        for field in trailers {
            encoded.append(Data("\(field.wireName): \(field.value)\r\n".utf8))
        }
        encoded.append(Data([13, 10]))
        return encoded
    }

    // MARK: - Private Framing Transitions

    private mutating func transitionAfterHeaders() throws -> HTTP11DissectedMessage? {
        guard let startLine = currentStartLine else { return nil }
        let isChunked = currentHeaders.isChunkedTransferEncoding
        let rawCLValues = currentHeaders.values(for: "content-length")

        if isChunked && !rawCLValues.isEmpty {
            throw HTTP11DissectorError.conflictingFramingHeaders
        }

        // RFC 9112 §6.3: Responses to HEAD, 1xx, 204, and 304 never contain a message body.
        if case .response(_, let status, _) = startLine {
            let headHint = (requestMethodHint?.uppercased() == "HEAD")
            if headHint || (100..<200).contains(status) || status == 204 || status == 304 {
                return emitCurrentMessage()
            }
        }

        if isChunked {
            wasChunkedFlag = true
            phase = .readingChunkSizeLine
            return nil
        }

        if !rawCLValues.isEmpty {
            let firstRaw = rawCLValues[0].trimmingCharacters(in: .whitespaces)
            for other in rawCLValues.dropFirst() where other.trimmingCharacters(in: .whitespaces) != firstRaw {
                throw HTTP11DissectorError.invalidContentLength(rawCLValues.joined(separator: ","))
            }
            guard let contentLen = Int(firstRaw), contentLen >= 0 else {
                throw HTTP11DissectorError.invalidContentLength(firstRaw)
            }
            if contentLen > maxBodyBytes {
                throw HTTP11DissectorError.bodyExceedsLimit(maxBytes: maxBodyBytes)
            }
            if contentLen == 0 {
                return emitCurrentMessage()
            }
            phase = .readingFixedBody(remaining: contentLen)
            return nil
        }

        // Requests without Content-Length or Transfer-Encoding default to zero-length body
        if case .request = startLine {
            return emitCurrentMessage()
        }

        // Response without Content-Length or chunked framing runs until upstream closes socket
        phase = .readingUntilEOFBody
        return nil
    }

    private mutating func appendDecodedBodySlice(_ slice: Data) throws {
        guard !slice.isEmpty else { return }
        if assembledBody.count + slice.count > maxBodyBytes {
            throw HTTP11DissectorError.bodyExceedsLimit(maxBytes: maxBodyBytes)
        }
        assembledBody.append(slice)
        onBodySliceDecoded?(slice)
    }

    private mutating func emitCurrentMessage() -> HTTP11DissectedMessage {
        let wireBody = max(0, totalConsumedBytes - bodyWireStartOffset)
        let msg = HTTP11DissectedMessage(
            startLine: currentStartLine ?? .response(version: "HTTP/1.1", statusCode: 200, reasonPhrase: "OK"),
            headers: currentHeaders,
            body: assembledBody,
            trailers: currentTrailers,
            wireHeaderBytes: headerBytesCount,
            wireBodyBytes: wireBody,
            wasChunked: wasChunkedFlag,
            chunkFrames: chunkFrames
        )
        // Reset state for keep-alive / pipelined next message
        phase = .awaitingStartLine
        currentStartLine = nil
        currentHeaders = HTTPHeaderMap()
        currentTrailers = HTTPHeaderMap()
        assembledBody = Data()
        headerBytesCount = 0
        bodyWireStartOffset = totalConsumedBytes
        wasChunkedFlag = false
        chunkFrames.removeAll(keepingCapacity: true)
        return msg
    }

    private mutating func tryReadLine() -> (line: String, wireLength: Int)? {
        guard readCursor < buffer.count else { return nil }
        guard let lfIndex = buffer[readCursor..<buffer.count].firstIndex(of: 10) else {
            return nil
        }
        let lineEndExclusive: Int
        if lfIndex > readCursor && buffer[lfIndex - 1] == 13 {
            lineEndExclusive = lfIndex - 1
        } else if allowLenientLF {
            lineEndExclusive = lfIndex
        } else {
            return nil
        }
        let lineBytes = buffer[readCursor..<lineEndExclusive]
        let wireLen = (lfIndex - readCursor) + 1
        readCursor = lfIndex + 1
        totalConsumedBytes += wireLen
        let decoded = String(decoding: lineBytes, as: UTF8.self)
        return (decoded, wireLen)
    }

    private mutating func consumeBytes(count: Int) -> Data {
        let end = readCursor + count
        let sub = Data(buffer[readCursor..<end])
        readCursor = end
        totalConsumedBytes += count
        return sub
    }

    private mutating func compactBufferIfNeeded() {
        if readCursor > 0 && (readCursor >= 16_384 || readCursor == buffer.count) {
            if readCursor == buffer.count {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.removeSubrange(0..<readCursor)
            }
            readCursor = 0
        }
    }

    private static func parseStartLine(_ line: String, expectedRole: HTTP11MessageRole?) throws -> HTTP11StartLine {
        if line.uppercased().hasPrefix("HTTP/") {
            if expectedRole == .request {
                throw HTTP11DissectorError.emptyOrMalformedStartLine(line)
            }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let code = Int(parts[1]), (100...599).contains(code) else {
                throw HTTP11DissectorError.emptyOrMalformedStartLine(line)
            }
            let version = String(parts[0])
            let reason = parts.count >= 3 ? String(parts[2]) : ""
            return .response(version: version, statusCode: code, reasonPhrase: reason)
        } else {
            if expectedRole == .response {
                throw HTTP11DissectorError.emptyOrMalformedStartLine(line)
            }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else {
                throw HTTP11DissectorError.emptyOrMalformedStartLine(line)
            }
            let method = String(parts[0])
            let rawTarget = String(parts[1])
            let version = String(parts[2])
            guard version.uppercased().hasPrefix("HTTP/") else {
                throw HTTP11DissectorError.emptyOrMalformedStartLine(line)
            }
            let querySplit = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let path = String(querySplit[0])
            let query = querySplit.count > 1 ? String(querySplit[1]) : nil
            return .request(method: method, rawTarget: rawTarget, path: path, query: query, version: version)
        }
    }

    private static func parseChunkSizeLine(_ rawLine: String) throws -> (Int, [HTTP11ChunkExtension]) {
        let segments = rawLine.split(separator: ";", omittingEmptySubsequences: false)
        guard let hexPartRaw = segments.first else {
            throw HTTP11DissectorError.invalidChunkSizeHex(rawLine)
        }
        let hexToken = hexPartRaw.trimmingCharacters(in: .whitespaces)
        guard !hexToken.isEmpty, hexToken.allSatisfy(\.isHexDigit), let size = Int(hexToken, radix: 16), size >= 0 else {
            throw HTTP11DissectorError.invalidChunkSizeHex(hexToken)
        }

        var extensions: [HTTP11ChunkExtension] = []
        for extSegment in segments.dropFirst() {
            let trimmed = extSegment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                var v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                extensions.append(HTTP11ChunkExtension(name: k, value: v))
            } else {
                extensions.append(HTTP11ChunkExtension(name: trimmed, value: nil))
            }
        }
        return (size, extensions)
    }
}

// MARK: - Server-Sent Events (SSE) Spec-Compliant Stream Reassembler

public struct SSEWireEvent: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let eventIDHeader: String?
    public let eventType: String
    public let data: String
    public let retryMilliseconds: Int?
    public let comments: [String]
    public let sequenceIndex: Int
    public let wireByteOffset: Int
    public let receivedUptimeNs: UInt64

    public init(
        id: UUID = UUID(),
        eventIDHeader: String? = nil,
        eventType: String = "message",
        data: String,
        retryMilliseconds: Int? = nil,
        comments: [String] = [],
        sequenceIndex: Int,
        wireByteOffset: Int = 0,
        receivedUptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.id = id
        self.eventIDHeader = eventIDHeader
        self.eventType = eventType
        self.data = data
        self.retryMilliseconds = retryMilliseconds
        self.comments = comments
        self.sequenceIndex = sequenceIndex
        self.wireByteOffset = wireByteOffset
        self.receivedUptimeNs = receivedUptimeNs
    }

    public var isDoneSentinel: Bool {
        data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]"
    }
}

/// Reassembles fragmented byte chunks into WHATWG Server-Sent Events (`event:`, `data:`, `id:`, `retry:`, `[DONE]`).
public struct SSEEventStreamReassembler: Sendable {
    private var rawBuffer = Data()
    private var cursor: Int = 0
    private var totalWireBytesConsumed: Int = 0
    private var currentEventStartOffset: Int = 0
    private var sawPendingCR: Bool = false

    private var pendingEventType: String?
    private var pendingDataLines: [String] = []
    private var pendingComments: [String] = []
    private var pendingRetryMs: Int?
    private var lastEventID: String?
    private var emittedCount: Int = 0

    public init() {}

    public mutating func feed(_ chunk: Data, timestampNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [SSEWireEvent] {
        guard !chunk.isEmpty else { return [] }
        rawBuffer.append(chunk)
        var out: [SSEWireEvent] = []

        while let lineInfo = readNextSSELine(allowFinalUnterminated: false) {
            if let evt = processLine(lineInfo.line, lineWireLength: lineInfo.wireBytes, timestampNs: timestampNs) {
                out.append(evt)
            }
        }
        compactBuffer()
        return out
    }

    public mutating func flushEOF(timestampNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [SSEWireEvent] {
        var out: [SSEWireEvent] = []
        if sawPendingCR {
            sawPendingCR = false
            if let evt = processLine("", lineWireLength: 0, timestampNs: timestampNs) {
                out.append(evt)
            }
        }
        while let lineInfo = readNextSSELine(allowFinalUnterminated: true) {
            if let evt = processLine(lineInfo.line, lineWireLength: lineInfo.wireBytes, timestampNs: timestampNs) {
                out.append(evt)
            }
        }
        if !pendingDataLines.isEmpty || pendingEventType != nil {
            if let finalEvent = dispatchPendingEvent(timestampNs: timestampNs) {
                out.append(finalEvent)
            }
        }
        compactBuffer()
        return out
    }

    private mutating func processLine(_ line: String, lineWireLength: Int, timestampNs: UInt64) -> SSEWireEvent? {
        if pendingDataLines.isEmpty && pendingEventType == nil && pendingComments.isEmpty {
            currentEventStartOffset = max(0, totalWireBytesConsumed - lineWireLength)
        }

        // Blank line dispatches accumulated SSE event
        if line.isEmpty {
            return dispatchPendingEvent(timestampNs: timestampNs)
        }

        // Leading colon indicates comment / keep-alive heartbeat
        if line.hasPrefix(":") {
            let commentBody = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            pendingComments.append(commentBody)
            return nil
        }

        let fieldName: String
        var fieldValue: String
        if let colonIdx = line.firstIndex(of: ":") {
            fieldName = String(line[..<colonIdx])
            let afterColon = line.index(after: colonIdx)
            fieldValue = String(line[afterColon...])
            // Per WHATWG SSE spec: strip at most ONE leading U+0020 SPACE after colon
            if fieldValue.hasPrefix(" ") {
                fieldValue.removeFirst()
            }
        } else {
            fieldName = line
            fieldValue = ""
        }

        switch fieldName {
        case "event":
            pendingEventType = fieldValue
        case "data":
            pendingDataLines.append(fieldValue)
        case "id":
            if !fieldValue.contains("\0") {
                lastEventID = fieldValue
            }
        case "retry":
            if !fieldValue.isEmpty, fieldValue.allSatisfy(\.isNumber), let ms = Int(fieldValue) {
                pendingRetryMs = ms
            }
        default:
            break
        }
        return nil
    }

    private mutating func dispatchPendingEvent(timestampNs: UInt64) -> SSEWireEvent? {
        defer {
            pendingEventType = nil
            pendingDataLines.removeAll(keepingCapacity: true)
            pendingComments.removeAll(keepingCapacity: true)
            pendingRetryMs = nil
        }
        guard !pendingDataLines.isEmpty else {
            return nil
        }
        let joinedData = pendingDataLines.joined(separator: "\n")
        let resolvedType = (pendingEventType?.isEmpty == false) ? pendingEventType! : "message"
        let idx = emittedCount
        emittedCount += 1
        return SSEWireEvent(
            eventIDHeader: lastEventID,
            eventType: resolvedType,
            data: joinedData,
            retryMilliseconds: pendingRetryMs,
            comments: pendingComments,
            sequenceIndex: idx,
            wireByteOffset: currentEventStartOffset,
            receivedUptimeNs: timestampNs
        )
    }

    private mutating func readNextSSELine(allowFinalUnterminated: Bool) -> (line: String, wireBytes: Int)? {
        if sawPendingCR {
            if cursor < rawBuffer.count {
                sawPendingCR = false
                if rawBuffer[cursor] == 10 {
                    cursor += 1
                    totalWireBytesConsumed += 1
                }
            } else if !allowFinalUnterminated {
                return nil
            } else {
                sawPendingCR = false
            }
        }

        guard cursor < rawBuffer.count else { return nil }
        var i = cursor
        while i < rawBuffer.count {
            let b = rawBuffer[i]
            if b == 13 { // '\r'
                let lineSlice = rawBuffer[cursor..<i]
                if i + 1 < rawBuffer.count {
                    let wireLen: Int
                    if rawBuffer[i + 1] == 10 {
                        wireLen = (i - cursor) + 2
                        cursor = i + 2
                    } else {
                        wireLen = (i - cursor) + 1
                        cursor = i + 1
                    }
                    totalWireBytesConsumed += wireLen
                    return (String(decoding: lineSlice, as: UTF8.self), wireLen)
                } else if allowFinalUnterminated {
                    let wireLen = (i - cursor) + 1
                    cursor = i + 1
                    totalWireBytesConsumed += wireLen
                    return (String(decoding: lineSlice, as: UTF8.self), wireLen)
                } else {
                    // Wait for next byte to see if \r\n or standalone \r, OR emit line and defer LF swallow
                    let wireLen = (i - cursor) + 1
                    cursor = i + 1
                    totalWireBytesConsumed += wireLen
                    sawPendingCR = true
                    return (String(decoding: lineSlice, as: UTF8.self), wireLen)
                }
            } else if b == 10 { // '\n'
                let lineSlice = rawBuffer[cursor..<i]
                let wireLen = (i - cursor) + 1
                cursor = i + 1
                totalWireBytesConsumed += wireLen
                return (String(decoding: lineSlice, as: UTF8.self), wireLen)
            }
            i += 1
        }

        if allowFinalUnterminated && cursor < rawBuffer.count {
            let lineSlice = rawBuffer[cursor..<rawBuffer.count]
            let wireLen = rawBuffer.count - cursor
            cursor = rawBuffer.count
            totalWireBytesConsumed += wireLen
            return (String(decoding: lineSlice, as: UTF8.self), wireLen)
        }
        return nil
    }

    private mutating func compactBuffer() {
        if cursor > 0 && (cursor >= 8_192 || cursor == rawBuffer.count) {
            if cursor == rawBuffer.count {
                rawBuffer.removeAll(keepingCapacity: true)
            } else {
                rawBuffer.removeSubrange(0..<cursor)
            }
            cursor = 0
        }
    }
}

// MARK: - Multi-Vendor LLM Streaming Dialect & Reconstructed Artifacts

public enum LLMStreamDialect: String, Sendable, Codable, Hashable, CaseIterable {
    case anthropicMessages = "Anthropic Messages SSE"
    case openAIResponses = "OpenAI Responses SSE"
    case openAIChatCompletions = "OpenAI Chat Completions SSE"
    case googleGeminiStream = "Google Gemini streamGenerateContent"
    case mistralChatSSE = "Mistral Chat Completions SSE"
    case nonStreamingJSON = "Non-Streaming JSON"

    public static func infer(
        vendor: AgentVendor,
        providerHost: String,
        requestPath: String,
        isEventStream: Bool
    ) -> LLMStreamDialect {
        let host = providerHost.lowercased()
        let path = requestPath.lowercased()
        if !isEventStream && !path.contains("streamgeneratecontent") && !path.contains("alt=sse") {
            if host.contains("anthropic") { return .anthropicMessages }
            if host.contains("googleapis") || host.contains("gemini") { return .googleGeminiStream }
            if host.contains("mistral") { return .mistralChatSSE }
            if path.contains("/responses") { return .openAIResponses }
            return .openAIChatCompletions
        }
        if host.contains("anthropic") || path.contains("/v1/messages") || vendor == .claudeCode {
            return .anthropicMessages
        }
        if host.contains("googleapis") || path.contains("streamgeneratecontent") || vendor == .antigravity {
            return .googleGeminiStream
        }
        if host.contains("mistral") || vendor == .mistralVibe {
            return .mistralChatSSE
        }
        if path.contains("/responses") {
            return .openAIResponses
        }
        return .openAIChatCompletions
    }
}

public struct ReconstructedThinkingBlock: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let blockIndex: Int
    public var thinkingText: String
    public var cryptographicSignature: String?
    public var startedOffsetMs: Double
    public var completedOffsetMs: Double

    public init(
        id: UUID = UUID(),
        blockIndex: Int,
        thinkingText: String,
        cryptographicSignature: String? = nil,
        startedOffsetMs: Double,
        completedOffsetMs: Double
    ) {
        self.id = id
        self.blockIndex = blockIndex
        self.thinkingText = thinkingText
        self.cryptographicSignature = cryptographicSignature
        self.startedOffsetMs = startedOffsetMs
        self.completedOffsetMs = completedOffsetMs
    }

    public var durationMs: Double {
        max(0.0, completedOffsetMs - startedOffsetMs)
    }
}

public struct ReconstructedToolCall: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let callIndex: Int
    public var toolName: String
    public var rawArgumentsJSON: String
    public var parsedArguments: WireJSONValue
    public var isComplete: Bool
    public var startedOffsetMs: Double
    public var completedOffsetMs: Double

    public init(
        id: String,
        callIndex: Int,
        toolName: String,
        rawArgumentsJSON: String,
        parsedArguments: WireJSONValue = .null,
        isComplete: Bool = true,
        startedOffsetMs: Double = 0,
        completedOffsetMs: Double = 0
    ) {
        self.id = id
        self.callIndex = callIndex
        self.toolName = toolName
        self.rawArgumentsJSON = rawArgumentsJSON
        self.parsedArguments = parsedArguments
        self.isComplete = isComplete
        self.startedOffsetMs = startedOffsetMs
        self.completedOffsetMs = completedOffsetMs
    }

    public var durationMs: Double {
        max(0.0, completedOffsetMs - startedOffsetMs)
    }
}

public struct PromptCacheEfficiencyMetrics: Sendable, Codable, Hashable {
    public let totalInputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let uncachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheReadRatio: Double
    public let cacheWriteRatio: Double
    public let estimatedCacheSavingsUSD: Double

    public init(
        totalInputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        pricingRate: ModelPricingRate? = nil
    ) {
        let safeRead = max(0, cacheReadTokens)
        let safeWrite = max(0, cacheWriteTokens)
        let effectiveTotalIn = max(totalInputTokens, safeRead + safeWrite)
        let uncached = max(0, effectiveTotalIn - safeRead - safeWrite)

        self.totalInputTokens = effectiveTotalIn
        self.cacheReadTokens = safeRead
        self.cacheWriteTokens = safeWrite
        self.uncachedInputTokens = uncached
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.cacheReadRatio = effectiveTotalIn > 0 ? Double(safeRead) / Double(effectiveTotalIn) : 0.0
        self.cacheWriteRatio = effectiveTotalIn > 0 ? Double(safeWrite) / Double(effectiveTotalIn) : 0.0

        if let rate = pricingRate {
            let perTokenSaved = max(0.0, rate.inputUSDPerMillion - rate.cachedInputUSDPerMillion) / 1_000_000.0
            self.estimatedCacheSavingsUSD = Double(safeRead) * perTokenSaved
        } else {
            self.estimatedCacheSavingsUSD = 0.0
        }
    }
}

public struct StreamingLatencyAndThroughput: Sendable, Codable, Hashable {
    public let ttftMs: Double
    public let totalDurationMs: Double
    public let generationWindowMs: Double
    public let sseFrameCount: Int
    public let p50InterTokenMs: Double
    public let p95InterTokenMs: Double
    public let outputTokensPerSecond: Double
    public let effectiveTotalTokensPerSecond: Double

    public init(
        ttftMs: Double,
        totalDurationMs: Double,
        sseFrameCount: Int,
        interTokenDeltasMs: [Double],
        outputAndReasoningTokens: Int,
        totalProcessedTokens: Int
    ) {
        let clampedTotal = max(0.1, totalDurationMs)
        let clampedTTFT = min(clampedTotal, max(0.0, ttftMs))
        let genWindow = max(0.1, clampedTotal - clampedTTFT)

        self.ttftMs = clampedTTFT
        self.totalDurationMs = clampedTotal
        self.generationWindowMs = genWindow
        self.sseFrameCount = max(0, sseFrameCount)

        if interTokenDeltasMs.isEmpty {
            self.p50InterTokenMs = 0.0
            self.p95InterTokenMs = 0.0
        } else {
            let sorted = interTokenDeltasMs.sorted()
            let idx50 = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.50))
            let idx95 = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
            self.p50InterTokenMs = sorted[idx50]
            self.p95InterTokenMs = sorted[idx95]
        }

        self.outputTokensPerSecond = Double(max(0, outputAndReasoningTokens)) / (genWindow / 1_000.0)
        self.effectiveTotalTokensPerSecond = Double(max(0, totalProcessedTokens)) / (clampedTotal / 1_000.0)
    }
}

// MARK: - Flamechart Timeline Span Primitives

public enum WiretapFlameSpanKind: String, Sendable, Codable, Hashable, CaseIterable {
    case requestTurnRoot = "LLM Turn"
    case outboundDLPScan = "Outbound DLP Scan"
    case requestUpload = "Request Payload Upload"
    case providerQueueTTFT = "Provider Queue & Prefill (TTFT)"
    case extendedThinking = "Reasoning / Extended Thinking"
    case assistantTextStream = "Assistant Text Streaming"
    case toolCallArguments = "Tool Call JSON Streaming"
    case circuitBreakerGate = "Budget Circuit Breaker"
}

public struct WiretapFlameSpan: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let parentSpanID: UUID?
    public let laneID: String
    public let taskID: String?
    public let vendor: AgentVendor
    public let modelIdentifier: String
    public let kind: WiretapFlameSpanKind
    public let label: String
    public let startOffsetMs: Double
    public let durationMs: Double
    public let depth: Int
    public let tokenCount: Int
    public let costUSD: Double
    public let annotations: [String: String]

    public init(
        id: UUID = UUID(),
        parentSpanID: UUID? = nil,
        laneID: String,
        taskID: String? = nil,
        vendor: AgentVendor,
        modelIdentifier: String,
        kind: WiretapFlameSpanKind,
        label: String,
        startOffsetMs: Double,
        durationMs: Double,
        depth: Int = 0,
        tokenCount: Int = 0,
        costUSD: Double = 0.0,
        annotations: [String: String] = [:]
    ) {
        self.id = id
        self.parentSpanID = parentSpanID
        self.laneID = laneID
        self.taskID = taskID
        self.vendor = vendor
        self.modelIdentifier = modelIdentifier
        self.kind = kind
        self.label = label
        self.startOffsetMs = max(0.0, startOffsetMs)
        self.durationMs = max(0.05, durationMs)
        self.depth = max(0, depth)
        self.tokenCount = max(0, tokenCount)
        self.costUSD = max(0.0, costUSD)
        self.annotations = annotations
    }

    public var endOffsetMs: Double {
        startOffsetMs + durationMs
    }
}

public struct DissectedLLMStreamReport: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let laneID: String
    public let taskID: String?
    public let vendor: AgentVendor
    public let providerHost: String
    public let dialect: LLMStreamDialect
    public let modelIdentifier: String
    public let responseMessageID: String?
    public let stopReason: String?
    public let statusCode: Int
    public let assistantText: String
    public let thinkingBlocks: [ReconstructedThinkingBlock]
    public let toolCalls: [ReconstructedToolCall]
    public let cacheMetrics: PromptCacheEfficiencyMetrics
    public let latencyAndThroughput: StreamingLatencyAndThroughput
    public let estimatedCostUSD: Double
    public let flameSpans: [WiretapFlameSpan]
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        laneID: String,
        taskID: String? = nil,
        vendor: AgentVendor,
        providerHost: String,
        dialect: LLMStreamDialect,
        modelIdentifier: String,
        responseMessageID: String? = nil,
        stopReason: String? = nil,
        statusCode: Int = 200,
        assistantText: String,
        thinkingBlocks: [ReconstructedThinkingBlock],
        toolCalls: [ReconstructedToolCall],
        cacheMetrics: PromptCacheEfficiencyMetrics,
        latencyAndThroughput: StreamingLatencyAndThroughput,
        estimatedCostUSD: Double,
        flameSpans: [WiretapFlameSpan],
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.laneID = laneID
        self.taskID = taskID
        self.vendor = vendor
        self.providerHost = providerHost
        self.dialect = dialect
        self.modelIdentifier = modelIdentifier
        self.responseMessageID = responseMessageID
        self.stopReason = stopReason
        self.statusCode = statusCode
        self.assistantText = assistantText
        self.thinkingBlocks = thinkingBlocks
        self.toolCalls = toolCalls
        self.cacheMetrics = cacheMetrics
        self.latencyAndThroughput = latencyAndThroughput
        self.estimatedCostUSD = estimatedCostUSD
        self.flameSpans = flameSpans
        self.recordedAt = recordedAt
    }

    public func toWiretapAPISpan(blockedByCircuitBreaker: Bool = false) -> WiretapAPISpan {
        WiretapAPISpan(
            id: id,
            laneID: laneID,
            taskID: taskID,
            vendor: vendor,
            providerHost: providerHost,
            modelIdentifier: modelIdentifier,
            inputTokens: cacheMetrics.totalInputTokens,
            cachedReadTokens: cacheMetrics.cacheReadTokens,
            outputTokens: cacheMetrics.outputTokens,
            reasoningTokens: cacheMetrics.reasoningTokens,
            costUSD: estimatedCostUSD,
            durationMs: latencyAndThroughput.totalDurationMs,
            statusCode: statusCode,
            blockedByCircuitBreaker: blockedByCircuitBreaker,
            recordedAt: recordedAt
        )
    }
}

// MARK: - Multi-Vendor SSE & JSON Protocol Dissector Engine

public struct MultiVendorSSEDissector: Sendable {
    public let pricingCatalog: ProviderPricingCatalog

    public init(pricingCatalog: ProviderPricingCatalog = ProviderPricingCatalog()) {
        self.pricingCatalog = pricingCatalog
    }

    /// Dissects raw SSE event streams OR non-streaming JSON responses across Anthropic, OpenAI/Codex, Gemini, and Mistral.
    public func dissectInteraction(
        laneID: String,
        taskID: String? = nil,
        vendor: AgentVendor,
        providerHost: String,
        requestPath: String = "/v1/messages",
        requestBody: Data? = nil,
        responseStatusCode: Int = 200,
        responseHeaders: HTTPHeaderMap = HTTPHeaderMap(),
        responseBody: Data,
        requestStartNs: UInt64,
        firstTokenObservedNs: UInt64? = nil,
        responseEndNs: UInt64,
        dlpScanDurationMs: Double = 0.0
    ) -> DissectedLLMStreamReport {
        var modelID = extractRequestModel(from: requestBody) ?? "unknown-model"
        let looksLikeSSE = responseHeaders.isEventStreamContentType || Self.bodyLooksLikeSSE(responseBody)
        let dialect = LLMStreamDialect.infer(
            vendor: vendor,
            providerHost: providerHost,
            requestPath: requestPath,
            isEventStream: looksLikeSSE
        )

        var accumulator = StreamSemanticAccumulator(requestStartNs: requestStartNs)
        accumulator.modelIdentifier = modelID

        if looksLikeSSE {
            var sse = SSEEventStreamReassembler()
            let chunkEvents = sse.feed(responseBody, timestampNs: firstTokenObservedNs ?? responseEndNs)
            let trailingEvents = sse.flushEOF(timestampNs: responseEndNs)
            let allEvents = chunkEvents + trailingEvents

            // Synthesize evenly-spaced frame timestamps if captured post-hoc from buffered transport
            let totalNsSpan = responseEndNs > requestStartNs ? (responseEndNs - requestStartNs) : 1_000_000
            let estimatedTTFTNs = firstTokenObservedNs ?? (requestStartNs + UInt64(Double(totalNsSpan) * 0.22))

            for (idx, event) in allEvents.enumerated() {
                if event.isDoneSentinel { continue }
                let progress = allEvents.count > 1 ? Double(idx) / Double(allEvents.count - 1) : 1.0
                let syntheticFrameNs: UInt64
                if firstTokenObservedNs == nil {
                    let genSpan = responseEndNs > estimatedTTFTNs ? (responseEndNs - estimatedTTFTNs) : 0
                    syntheticFrameNs = estimatedTTFTNs + UInt64(Double(genSpan) * progress)
                } else {
                    syntheticFrameNs = event.receivedUptimeNs
                }
                ingestSSEEvent(event, frameNs: syntheticFrameNs, dialect: dialect, into: &accumulator)
            }
        } else {
            // Non-streaming JSON or Gemini JSON array response
            let fallbackTTFTNs = firstTokenObservedNs ?? responseEndNs
            ingestNonStreamingJSON(responseBody, frameNs: fallbackTTFTNs, dialect: dialect, into: &accumulator)
        }

        if accumulator.modelIdentifier != "unknown-model" {
            modelID = accumulator.modelIdentifier
        }
        accumulator.finalizeOpenBlocks(endOffsetMs: Double(responseEndNs > requestStartNs ? (responseEndNs - requestStartNs) : 1_000_000) / 1_000_000.0)

        let rate = pricingCatalog.matchRate(for: modelID, fallbackVendor: vendor)
        let cacheMetrics = PromptCacheEfficiencyMetrics(
            totalInputTokens: accumulator.inputTokens,
            cacheReadTokens: accumulator.cacheReadTokens,
            cacheWriteTokens: accumulator.cacheWriteTokens,
            outputTokens: accumulator.outputTokens,
            reasoningTokens: accumulator.reasoningTokens,
            pricingRate: rate
        )
        let totalCost = rate.estimateCostUSD(
            inputTokens: cacheMetrics.totalInputTokens,
            cachedReadTokens: cacheMetrics.cacheReadTokens,
            outputTokens: cacheMetrics.outputTokens,
            reasoningTokens: cacheMetrics.reasoningTokens
        )

        let totalDurationMs = max(0.2, Double(responseEndNs > requestStartNs ? (responseEndNs - requestStartNs) : 200_000) / 1_000_000.0)
        let resolvedTTFTMs = accumulator.firstContentOffsetMs ?? min(totalDurationMs, totalDurationMs * 0.25)

        let latencyMetrics = StreamingLatencyAndThroughput(
            ttftMs: resolvedTTFTMs,
            totalDurationMs: totalDurationMs,
            sseFrameCount: accumulator.sseFrameCount,
            interTokenDeltasMs: accumulator.interTokenDeltasMs,
            outputAndReasoningTokens: cacheMetrics.outputTokens + cacheMetrics.reasoningTokens,
            totalProcessedTokens: cacheMetrics.totalInputTokens + cacheMetrics.outputTokens + cacheMetrics.reasoningTokens
        )

        let rootSpanID = UUID()
        let flameSpans = buildTurnFlameSpans(
            rootID: rootSpanID,
            laneID: laneID,
            taskID: taskID,
            vendor: vendor,
            modelIdentifier: modelID,
            dlpScanDurationMs: dlpScanDurationMs,
            ttftMs: latencyMetrics.ttftMs,
            totalDurationMs: latencyMetrics.totalDurationMs,
            thinkingBlocks: accumulator.thinkingBlocks,
            toolCalls: accumulator.finalizedToolCalls(),
            textFirstOffsetMs: accumulator.textFirstOffsetMs,
            textLastOffsetMs: accumulator.textLastOffsetMs,
            cacheMetrics: cacheMetrics,
            totalCostUSD: totalCost
        )

        return DissectedLLMStreamReport(
            id: rootSpanID,
            laneID: laneID,
            taskID: taskID,
            vendor: vendor,
            providerHost: providerHost,
            dialect: dialect,
            modelIdentifier: modelID,
            responseMessageID: accumulator.messageID,
            stopReason: accumulator.stopReason,
            statusCode: responseStatusCode,
            assistantText: accumulator.assistantText,
            thinkingBlocks: accumulator.thinkingBlocks,
            toolCalls: accumulator.finalizedToolCalls(),
            cacheMetrics: cacheMetrics,
            latencyAndThroughput: latencyMetrics,
            estimatedCostUSD: totalCost,
            flameSpans: flameSpans
        )
    }

    // MARK: - Dialect-Specific Event Dissection

    private struct PartialToolCallState {
        var id: String
        var callIndex: Int
        var name: String
        var jsonBuffer: String
        var startedOffsetMs: Double
        var lastUpdatedOffsetMs: Double
        var isClosed: Bool
    }

    private struct StreamSemanticAccumulator {
        let requestStartNs: UInt64
        var modelIdentifier: String = "unknown-model"
        var messageID: String?
        var stopReason: String?

        var inputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
        var outputTokens: Int = 0
        var reasoningTokens: Int = 0

        var assistantText: String = ""
        var thinkingBlocks: [ReconstructedThinkingBlock] = []
        private var openThinkingByIndex: [Int: Int] = [:]
        var partialToolsByKey: [String: PartialToolCallState] = [:]
        var orderedToolKeys: [String] = []

        var sseFrameCount: Int = 0
        var firstContentOffsetMs: Double?
        var lastTokenTimestampMs: Double?
        var interTokenDeltasMs: [Double] = []
        var textFirstOffsetMs: Double?
        var textLastOffsetMs: Double?

        init(requestStartNs: UInt64) {
            self.requestStartNs = requestStartNs
        }

        func offsetMs(for frameNs: UInt64) -> Double {
            guard frameNs >= requestStartNs else { return 0.0 }
            return Double(frameNs - requestStartNs) / 1_000_000.0
        }

        mutating func markContentToken(at offsetMs: Double) {
            if firstContentOffsetMs == nil {
                firstContentOffsetMs = offsetMs
            }
            if let prev = lastTokenTimestampMs, offsetMs >= prev {
                let delta = offsetMs - prev
                if delta > 0.01 {
                    interTokenDeltasMs.append(delta)
                }
            }
            lastTokenTimestampMs = offsetMs
        }

        mutating func appendAssistantText(_ delta: String, at offsetMs: Double) {
            guard !delta.isEmpty else { return }
            markContentToken(at: offsetMs)
            if textFirstOffsetMs == nil {
                textFirstOffsetMs = offsetMs
            }
            textLastOffsetMs = offsetMs
            assistantText += delta
        }

        mutating func appendThinkingDelta(blockIndex: Int, delta: String, signature: String? = nil, at offsetMs: Double) {
            if !delta.isEmpty {
                markContentToken(at: offsetMs)
            }
            if let arrIdx = openThinkingByIndex[blockIndex] {
                thinkingBlocks[arrIdx].thinkingText += delta
                if let sig = signature, !sig.isEmpty {
                    thinkingBlocks[arrIdx].cryptographicSignature = (thinkingBlocks[arrIdx].cryptographicSignature ?? "") + sig
                }
                thinkingBlocks[arrIdx].completedOffsetMs = max(thinkingBlocks[arrIdx].completedOffsetMs, offsetMs)
            } else {
                let created = ReconstructedThinkingBlock(
                    blockIndex: blockIndex,
                    thinkingText: delta,
                    cryptographicSignature: signature,
                    startedOffsetMs: offsetMs,
                    completedOffsetMs: offsetMs
                )
                openThinkingByIndex[blockIndex] = thinkingBlocks.count
                thinkingBlocks.append(created)
            }
        }

        mutating func upsertToolCallDelta(
            key: String,
            id: String?,
            callIndex: Int,
            name: String?,
            jsonFragment: String?,
            at offsetMs: Double,
            markComplete: Bool = false
        ) {
            if let frag = jsonFragment, !frag.isEmpty {
                markContentToken(at: offsetMs)
            }
            if var existing = partialToolsByKey[key] {
                if let id, !id.isEmpty { existing.id = id }
                if let name, !name.isEmpty { existing.name = name }
                if let jsonFragment { existing.jsonBuffer += jsonFragment }
                existing.lastUpdatedOffsetMs = max(existing.lastUpdatedOffsetMs, offsetMs)
                if markComplete { existing.isClosed = true }
                partialToolsByKey[key] = existing
            } else {
                orderedToolKeys.append(key)
                partialToolsByKey[key] = PartialToolCallState(
                    id: id ?? "call_\(callIndex)",
                    callIndex: callIndex,
                    name: name ?? "unknown_tool",
                    jsonBuffer: jsonFragment ?? "",
                    startedOffsetMs: offsetMs,
                    lastUpdatedOffsetMs: offsetMs,
                    isClosed: markComplete
                )
            }
        }

        mutating func finalizeOpenBlocks(endOffsetMs: Double) {
            for idx in thinkingBlocks.indices {
                if thinkingBlocks[idx].completedOffsetMs <= thinkingBlocks[idx].startedOffsetMs {
                    thinkingBlocks[idx].completedOffsetMs = max(thinkingBlocks[idx].startedOffsetMs + 0.5, endOffsetMs)
                }
            }
            for key in orderedToolKeys {
                if var st = partialToolsByKey[key], !st.isClosed {
                    st.isClosed = true
                    if st.lastUpdatedOffsetMs <= st.startedOffsetMs {
                        st.lastUpdatedOffsetMs = max(st.startedOffsetMs + 0.5, endOffsetMs)
                    }
                    partialToolsByKey[key] = st
                }
            }
        }

        func finalizedToolCalls() -> [ReconstructedToolCall] {
            orderedToolKeys.compactMap { key in
                guard let st = partialToolsByKey[key] else { return nil }
                let parsed: WireJSONValue
                if let data = st.jsonBuffer.data(using: .utf8),
                   let rawObj = try? JSONSerialization.jsonObject(with: data) {
                    parsed = WireJSONValue.fromAny(rawObj)
                } else {
                    parsed = st.jsonBuffer.isEmpty ? .object([:]) : .string(st.jsonBuffer)
                }
                return ReconstructedToolCall(
                    id: st.id,
                    callIndex: st.callIndex,
                    toolName: st.name,
                    rawArgumentsJSON: st.jsonBuffer,
                    parsedArguments: parsed,
                    isComplete: st.isClosed,
                    startedOffsetMs: st.startedOffsetMs,
                    completedOffsetMs: st.lastUpdatedOffsetMs
                )
            }
        }
    }

    private func ingestSSEEvent(
        _ event: SSEWireEvent,
        frameNs: UInt64,
        dialect: LLMStreamDialect,
        into acc: inout StreamSemanticAccumulator
    ) {
        acc.sseFrameCount += 1
        guard let payloadData = event.data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return
        }
        let nowMs = acc.offsetMs(for: frameNs)
        ingestUsageFields(from: dict, into: &acc)

        let eventName = (dict["type"] as? String) ?? event.eventType

        // 1. Anthropic Messages SSE (`message_start`, `content_block_start`, `content_block_delta`, `message_delta`)
        if dialect == .anthropicMessages || eventName.hasPrefix("content_block_") || eventName == "message_start" || eventName == "message_delta" {
            switch eventName {
            case "message_start":
                if let msg = dict["message"] as? [String: Any] {
                    if let m = msg["model"] as? String, !m.isEmpty { acc.modelIdentifier = m }
                    if let id = msg["id"] as? String { acc.messageID = id }
                    ingestUsageFields(from: msg, into: &acc)
                }
            case "content_block_start":
                let blockIdx = dict["index"] as? Int ?? 0
                if let cb = dict["content_block"] as? [String: Any], let cbType = cb["type"] as? String {
                    if cbType == "thinking" {
                        let initial = cb["thinking"] as? String ?? ""
                        acc.appendThinkingDelta(blockIndex: blockIdx, delta: initial, at: nowMs)
                    } else if cbType == "tool_use" {
                        let tid = cb["id"] as? String ?? "toolu_\(blockIdx)"
                        let tname = cb["name"] as? String ?? "tool"
                        acc.upsertToolCallDelta(key: "anth_\(blockIdx)", id: tid, callIndex: blockIdx, name: tname, jsonFragment: "", at: nowMs)
                    } else if cbType == "text", let initialText = cb["text"] as? String, !initialText.isEmpty {
                        acc.appendAssistantText(initialText, at: nowMs)
                    }
                }
            case "content_block_delta":
                let blockIdx = dict["index"] as? Int ?? 0
                if let delta = dict["delta"] as? [String: Any], let dType = delta["type"] as? String {
                    switch dType {
                    case "text_delta":
                        acc.appendAssistantText(delta["text"] as? String ?? "", at: nowMs)
                    case "thinking_delta":
                        acc.appendThinkingDelta(blockIndex: blockIdx, delta: delta["thinking"] as? String ?? "", at: nowMs)
                    case "signature_delta":
                        acc.appendThinkingDelta(blockIndex: blockIdx, delta: "", signature: delta["signature"] as? String, at: nowMs)
                    case "input_json_delta":
                        let partial = delta["partial_json"] as? String ?? ""
                        acc.upsertToolCallDelta(key: "anth_\(blockIdx)", id: nil, callIndex: blockIdx, name: nil, jsonFragment: partial, at: nowMs)
                    default:
                        break
                    }
                }
            case "content_block_stop":
                let blockIdx = dict["index"] as? Int ?? 0
                if acc.partialToolsByKey["anth_\(blockIdx)"] != nil {
                    acc.upsertToolCallDelta(key: "anth_\(blockIdx)", id: nil, callIndex: blockIdx, name: nil, jsonFragment: nil, at: nowMs, markComplete: true)
                }
            case "message_delta":
                if let delta = dict["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                    acc.stopReason = stop
                }
            default:
                break
            }
            return
        }

        // 2. OpenAI Responses API SSE (`response.output_text.delta`, `response.function_call_arguments.delta`, `response.reasoning_summary_text.delta`)
        if dialect == .openAIResponses || eventName.hasPrefix("response.") {
            if let resp = dict["response"] as? [String: Any] {
                if let m = resp["model"] as? String, !m.isEmpty { acc.modelIdentifier = m }
                if let id = resp["id"] as? String { acc.messageID = id }
                if let status = resp["status"] as? String { acc.stopReason = status }
                ingestUsageFields(from: resp, into: &acc)
            }
            switch eventName {
            case "response.output_text.delta":
                acc.appendAssistantText(dict["delta"] as? String ?? "", at: nowMs)
            case "response.reasoning_summary_text.delta", "response.reasoning.delta":
                let idx = dict["output_index"] as? Int ?? 0
                acc.appendThinkingDelta(blockIndex: idx, delta: dict["delta"] as? String ?? "", at: nowMs)
            case "response.output_item.added":
                let outIdx = dict["output_index"] as? Int ?? 0
                if let item = dict["item"] as? [String: Any], (item["type"] as? String) == "function_call" {
                    let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "fc_\(outIdx)"
                    let fnName = item["name"] as? String ?? "function"
                    let itemID = item["id"] as? String ?? "item_\(outIdx)"
                    acc.upsertToolCallDelta(key: itemID, id: callID, callIndex: outIdx, name: fnName, jsonFragment: "", at: nowMs)
                }
            case "response.function_call_arguments.delta":
                let outIdx = dict["output_index"] as? Int ?? 0
                let itemID = dict["item_id"] as? String ?? "item_\(outIdx)"
                acc.upsertToolCallDelta(key: itemID, id: nil, callIndex: outIdx, name: nil, jsonFragment: dict["delta"] as? String ?? "", at: nowMs)
            case "response.function_call_arguments.done":
                let outIdx = dict["output_index"] as? Int ?? 0
                let itemID = dict["item_id"] as? String ?? "item_\(outIdx)"
                acc.upsertToolCallDelta(key: itemID, id: nil, callIndex: outIdx, name: nil, jsonFragment: nil, at: nowMs, markComplete: true)
            default:
                break
            }
            return
        }

        // 3. Google Gemini `streamGenerateContent` SSE (`candidates[].content.parts[]`)
        if dialect == .googleGeminiStream || dict["candidates"] != nil {
            if let modelVer = dict["modelVersion"] as? String, !modelVer.isEmpty {
                acc.modelIdentifier = modelVer
            }
            ingestGeminiCandidates(dict, at: nowMs, into: &acc)
            return
        }

        // 4. OpenAI Chat Completions & Mistral Chat SSE (`choices[].delta`)
        if let m = dict["model"] as? String, !m.isEmpty {
            acc.modelIdentifier = m
        }
        if let id = dict["id"] as? String {
            acc.messageID = id
        }
        if let choices = dict["choices"] as? [[String: Any]] {
            for choice in choices {
                if let finish = choice["finish_reason"] as? String, !finish.isEmpty {
                    acc.stopReason = finish
                }
                if let delta = choice["delta"] as? [String: Any] {
                    if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["thinking"] as? String) {
                        acc.appendThinkingDelta(blockIndex: 0, delta: reasoning, at: nowMs)
                    }
                    if let contentStr = delta["content"] as? String {
                        acc.appendAssistantText(contentStr, at: nowMs)
                    } else if let contentChunks = delta["content"] as? [[String: Any]] {
                        // Mistral Magistral / structured thinking content chunks
                        for part in contentChunks {
                            let pType = part["type"] as? String ?? "text"
                            if pType == "thinking", let thoughts = part["thinking"] as? [[String: Any]] {
                                for th in thoughts {
                                    acc.appendThinkingDelta(blockIndex: 0, delta: th["text"] as? String ?? "", at: nowMs)
                                }
                            } else if let txt = part["text"] as? String {
                                acc.appendAssistantText(txt, at: nowMs)
                            }
                        }
                    }
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            let tcIdx = tc["index"] as? Int ?? 0
                            let tcID = tc["id"] as? String
                            let fnDict = tc["function"] as? [String: Any]
                            let fnName = fnDict?["name"] as? String
                            let fnArgs = fnDict?["arguments"] as? String
                            acc.upsertToolCallDelta(
                                key: "chat_tc_\(tcIdx)",
                                id: tcID,
                                callIndex: tcIdx,
                                name: fnName,
                                jsonFragment: fnArgs,
                                at: nowMs
                            )
                        }
                    }
                }
            }
        }
    }

    private func ingestNonStreamingJSON(
        _ body: Data,
        frameNs: UInt64,
        dialect: LLMStreamDialect,
        into acc: inout StreamSemanticAccumulator
    ) {
        let nowMs = acc.offsetMs(for: frameNs)
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else { return }

        if let array = parsed as? [[String: Any]] {
            for elem in array {
                ingestSingleJSONDocument(elem, at: nowMs, into: &acc)
            }
        } else if let dict = parsed as? [String: Any] {
            ingestSingleJSONDocument(dict, at: nowMs, into: &acc)
        }
    }

    private func ingestSingleJSONDocument(
        _ dict: [String: Any],
        at nowMs: Double,
        into acc: inout StreamSemanticAccumulator
    ) {
        ingestUsageFields(from: dict, into: &acc)
        if let m = (dict["model"] as? String) ?? (dict["modelVersion"] as? String), !m.isEmpty {
            acc.modelIdentifier = m
        }
        if let id = dict["id"] as? String {
            acc.messageID = id
        }
        if let stop = dict["stop_reason"] as? String {
            acc.stopReason = stop
        }

        // Anthropic non-streaming `content` array
        if let contentArr = dict["content"] as? [[String: Any]] {
            for (idx, block) in contentArr.enumerated() {
                let bType = block["type"] as? String ?? ""
                if bType == "text", let txt = block["text"] as? String {
                    acc.appendAssistantText(txt, at: nowMs)
                } else if bType == "thinking", let th = block["thinking"] as? String {
                    acc.appendThinkingDelta(blockIndex: idx, delta: th, signature: block["signature"] as? String, at: nowMs)
                } else if bType == "tool_use" {
                    let tid = block["id"] as? String ?? "toolu_\(idx)"
                    let name = block["name"] as? String ?? "tool"
                    let inputJSON: String
                    if let inputObj = block["input"], JSONSerialization.isValidJSONObject(inputObj),
                       let d = try? JSONSerialization.data(withJSONObject: inputObj) {
                        inputJSON = String(decoding: d, as: UTF8.self)
                    } else {
                        inputJSON = "{}"
                    }
                    acc.upsertToolCallDelta(key: tid, id: tid, callIndex: idx, name: name, jsonFragment: inputJSON, at: nowMs, markComplete: true)
                }
            }
        }

        // OpenAI / Mistral non-streaming `choices[].message`
        if let choices = dict["choices"] as? [[String: Any]] {
            for choice in choices {
                if let finish = choice["finish_reason"] as? String {
                    acc.stopReason = finish
                }
                if let msg = choice["message"] as? [String: Any] {
                    if let txt = msg["content"] as? String {
                        acc.appendAssistantText(txt, at: nowMs)
                    }
                    if let reasoning = msg["reasoning_content"] as? String {
                        acc.appendThinkingDelta(blockIndex: 0, delta: reasoning, at: nowMs)
                    }
                    if let tcs = msg["tool_calls"] as? [[String: Any]] {
                        for (idx, tc) in tcs.enumerated() {
                            let tid = tc["id"] as? String ?? "call_\(idx)"
                            let fn = tc["function"] as? [String: Any]
                            let name = fn?["name"] as? String ?? "tool"
                            let args = fn?["arguments"] as? String ?? "{}"
                            acc.upsertToolCallDelta(key: tid, id: tid, callIndex: idx, name: name, jsonFragment: args, at: nowMs, markComplete: true)
                        }
                    }
                }
            }
        }

        // Gemini `candidates`
        if dict["candidates"] != nil {
            ingestGeminiCandidates(dict, at: nowMs, into: &acc)
        }
    }

    private func ingestGeminiCandidates(
        _ dict: [String: Any],
        at nowMs: Double,
        into acc: inout StreamSemanticAccumulator
    ) {
        guard let candidates = dict["candidates"] as? [[String: Any]] else { return }
        for cand in candidates {
            if let finish = cand["finishReason"] as? String {
                acc.stopReason = finish
            }
            guard let content = cand["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for (idx, part) in parts.enumerated() {
                let isThought = (part["thought"] as? Bool) ?? false
                if isThought, let thText = part["text"] as? String {
                    acc.appendThinkingDelta(blockIndex: idx, delta: thText, signature: part["thoughtSignature"] as? String, at: nowMs)
                } else if let txt = part["text"] as? String {
                    acc.appendAssistantText(txt, at: nowMs)
                }
                if let fnCall = part["functionCall"] as? [String: Any] {
                    let name = fnCall["name"] as? String ?? "gemini_fn"
                    let callID = (fnCall["id"] as? String) ?? "gem_call_\(acc.orderedToolKeys.count)"
                    let argsJSON: String
                    if let argsObj = fnCall["args"], JSONSerialization.isValidJSONObject(argsObj),
                       let d = try? JSONSerialization.data(withJSONObject: argsObj) {
                        argsJSON = String(decoding: d, as: UTF8.self)
                    } else {
                        argsJSON = "{}"
                    }
                    acc.upsertToolCallDelta(
                        key: callID,
                        id: callID,
                        callIndex: acc.orderedToolKeys.count,
                        name: name,
                        jsonFragment: argsJSON,
                        at: nowMs,
                        markComplete: true
                    )
                }
            }
        }
    }

    private func ingestUsageFields(from dict: [String: Any], into acc: inout StreamSemanticAccumulator) {
        if let usage = dict["usage"] as? [String: Any] {
            let directIn = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int)
                ?? ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                ?? ((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0

            // Anthropic reports `input_tokens` as uncached tokens alongside `cache_read_input_tokens` + `cache_creation_input_tokens`
            if usage["cache_read_input_tokens"] != nil || usage["cache_creation_input_tokens"] != nil {
                acc.inputTokens = max(acc.inputTokens, directIn + cacheRead + cacheWrite)
            } else {
                acc.inputTokens = max(acc.inputTokens, directIn)
            }
            acc.cacheReadTokens = max(acc.cacheReadTokens, cacheRead)
            acc.cacheWriteTokens = max(acc.cacheWriteTokens, cacheWrite)

            if let outTok = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int) {
                acc.outputTokens = max(acc.outputTokens, outTok)
            }
            if let reasonTok = ((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)
                ?? ((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int) {
                acc.reasoningTokens = max(acc.reasoningTokens, reasonTok)
            }
        }

        if let gem = dict["usageMetadata"] as? [String: Any] {
            if let p = gem["promptTokenCount"] as? Int {
                acc.inputTokens = max(acc.inputTokens, p)
            }
            if let c = gem["cachedContentTokenCount"] as? Int {
                acc.cacheReadTokens = max(acc.cacheReadTokens, c)
            }
            if let o = gem["candidatesTokenCount"] as? Int {
                acc.outputTokens = max(acc.outputTokens, o)
            }
            if let t = gem["thoughtsTokenCount"] as? Int {
                acc.reasoningTokens = max(acc.reasoningTokens, t)
            }
        }
    }

    private func buildTurnFlameSpans(
        rootID: UUID,
        laneID: String,
        taskID: String?,
        vendor: AgentVendor,
        modelIdentifier: String,
        dlpScanDurationMs: Double,
        ttftMs: Double,
        totalDurationMs: Double,
        thinkingBlocks: [ReconstructedThinkingBlock],
        toolCalls: [ReconstructedToolCall],
        textFirstOffsetMs: Double?,
        textLastOffsetMs: Double?,
        cacheMetrics: PromptCacheEfficiencyMetrics,
        totalCostUSD: Double
    ) -> [WiretapFlameSpan] {
        var spans: [WiretapFlameSpan] = []
        let totalTok = cacheMetrics.totalInputTokens + cacheMetrics.outputTokens + cacheMetrics.reasoningTokens

        spans.append(
            WiretapFlameSpan(
                id: rootID,
                parentSpanID: nil,
                laneID: laneID,
                taskID: taskID,
                vendor: vendor,
                modelIdentifier: modelIdentifier,
                kind: .requestTurnRoot,
                label: "\(vendor.shortBadge) · \(modelIdentifier)",
                startOffsetMs: 0.0,
                durationMs: totalDurationMs,
                depth: 0,
                tokenCount: totalTok,
                costUSD: totalCostUSD,
                annotations: [
                    "cacheReadRatio": String(format: "%.1f%%", cacheMetrics.cacheReadRatio * 100.0),
                    "ttftMs": String(format: "%.1f", ttftMs)
                ]
            )
        )

        if dlpScanDurationMs > 0 {
            spans.append(
                WiretapFlameSpan(
                    parentSpanID: rootID,
                    laneID: laneID,
                    taskID: taskID,
                    vendor: vendor,
                    modelIdentifier: modelIdentifier,
                    kind: .outboundDLPScan,
                    label: "Outbound Secret DLP Gate",
                    startOffsetMs: 0.0,
                    durationMs: min(dlpScanDurationMs, ttftMs),
                    depth: 1
                )
            )
        }

        spans.append(
            WiretapFlameSpan(
                parentSpanID: rootID,
                laneID: laneID,
                taskID: taskID,
                vendor: vendor,
                modelIdentifier: modelIdentifier,
                kind: .providerQueueTTFT,
                label: "Prefill & Cache Lookup (\(cacheMetrics.cacheReadTokens)/\(cacheMetrics.totalInputTokens) cached)",
                startOffsetMs: dlpScanDurationMs,
                durationMs: max(0.2, ttftMs - dlpScanDurationMs),
                depth: 1,
                tokenCount: cacheMetrics.totalInputTokens
            )
        )

        for tb in thinkingBlocks {
            spans.append(
                WiretapFlameSpan(
                    parentSpanID: rootID,
                    laneID: laneID,
                    taskID: taskID,
                    vendor: vendor,
                    modelIdentifier: modelIdentifier,
                    kind: .extendedThinking,
                    label: "Extended Thinking #\(tb.blockIndex + 1)",
                    startOffsetMs: tb.startedOffsetMs,
                    durationMs: max(0.5, tb.durationMs),
                    depth: 1,
                    tokenCount: cacheMetrics.reasoningTokens
                )
            )
        }

        if let tStart = textFirstOffsetMs {
            let tEnd = max(tStart + 0.5, textLastOffsetMs ?? totalDurationMs)
            spans.append(
                WiretapFlameSpan(
                    parentSpanID: rootID,
                    laneID: laneID,
                    taskID: taskID,
                    vendor: vendor,
                    modelIdentifier: modelIdentifier,
                    kind: .assistantTextStream,
                    label: "Token Stream (\(cacheMetrics.outputTokens) tok)",
                    startOffsetMs: tStart,
                    durationMs: tEnd - tStart,
                    depth: 1,
                    tokenCount: cacheMetrics.outputTokens
                )
            )
        }

        for tc in toolCalls {
            spans.append(
                WiretapFlameSpan(
                    parentSpanID: rootID,
                    laneID: laneID,
                    taskID: taskID,
                    vendor: vendor,
                    modelIdentifier: modelIdentifier,
                    kind: .toolCallArguments,
                    label: "Tool Call: \(tc.toolName)(\(tc.parsedArguments.compactPreview))",
                    startOffsetMs: tc.startedOffsetMs,
                    durationMs: max(0.5, tc.durationMs),
                    depth: 1,
                    annotations: ["toolID": tc.id, "toolName": tc.toolName]
                )
            )
        }

        return spans
    }

    private func extractRequestModel(from requestBody: Data?) -> String? {
        guard let data = requestBody,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = obj["model"] as? String, !m.isEmpty else {
            return nil
        }
        return m
    }

    private static func bodyLooksLikeSSE(_ body: Data) -> Bool {
        let prefixCount = min(body.count, 512)
        let head = String(decoding: body.prefix(prefixCount), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("event:") || head.hasPrefix("data:") || head.hasPrefix(": ")
    }
}

// MARK: - Campaign-Wide Flamechart Track & Concurrency Builder

public struct WiretapFlameTrack: Sendable, Codable, Hashable, Identifiable {
    public var id: String { laneID }
    public let laneID: String
    public let vendor: AgentVendor
    public let spans: [WiretapFlameSpan]
    public let totalLaneSpendUSD: Double
    public let averageTTFTMs: Double
    public let cacheHitPercentage: Double

    public init(
        laneID: String,
        vendor: AgentVendor,
        spans: [WiretapFlameSpan],
        totalLaneSpendUSD: Double,
        averageTTFTMs: Double,
        cacheHitPercentage: Double
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.spans = spans
        self.totalLaneSpendUSD = totalLaneSpendUSD
        self.averageTTFTMs = averageTTFTMs
        self.cacheHitPercentage = cacheHitPercentage
    }
}

public struct WiretapFlamechartTimeline: Sendable, Codable, Hashable {
    public let tracks: [WiretapFlameTrack]
    public let horizonDurationMs: Double
    public let maxConcurrentActiveLanes: Int
    public let globalSpendUSD: Double

    public init(
        tracks: [WiretapFlameTrack],
        horizonDurationMs: Double,
        maxConcurrentActiveLanes: Int,
        globalSpendUSD: Double
    ) {
        self.tracks = tracks
        self.horizonDurationMs = max(1.0, horizonDurationMs)
        self.maxConcurrentActiveLanes = maxConcurrentActiveLanes
        self.globalSpendUSD = globalSpendUSD
    }
}

public enum WiretapFlamechartBuilder {
    /// Synthesizes normalized multi-lane flamechart tracks directly from recorded `[WiretapAPISpan]` spans.
    public static func buildTimeline(from apiSpans: [WiretapAPISpan]) -> WiretapFlamechartTimeline {
        guard !apiSpans.isEmpty else {
            return WiretapFlamechartTimeline(tracks: [], horizonDurationMs: 1_000, maxConcurrentActiveLanes: 0, globalSpendUSD: 0)
        }

        let sorted = apiSpans.sorted { $0.recordedAt < $1.recordedAt }
        let earliestEpoch = sorted.first!.recordedAt.timeIntervalSince1970
        var byLane: [String: [WiretapAPISpan]] = [:]
        for span in sorted {
            byLane[span.laneID, default: []].append(span)
        }

        var tracks: [WiretapFlameTrack] = []
        var rootIntervals: [(start: Double, end: Double)] = []
        var maxHorizon: Double = 100.0
        var totalSpend = 0.0

        for laneID in byLane.keys.sorted() {
            guard let laneSpans = byLane[laneID], let first = laneSpans.first else { continue }
            var cursorOffsetMs = max(0.0, (first.recordedAt.timeIntervalSince1970 - earliestEpoch) * 1_000.0)
            var trackFlameSpans: [WiretapFlameSpan] = []
            var laneSpend = 0.0
            var ttftSum = 0.0
            var inTokSum = 0
            var cacheTokSum = 0

            for apiSpan in laneSpans {
                let naturalOffsetMs = max(0.0, (apiSpan.recordedAt.timeIntervalSince1970 - earliestEpoch) * 1_000.0)
                let startMs = max(cursorOffsetMs, naturalOffsetMs)
                let durMs = max(5.0, apiSpan.durationMs)
                let ttft = apiSpan.blockedByCircuitBreaker ? durMs : min(durMs * 0.24, 950.0)
                ttftSum += ttft
                laneSpend += apiSpan.costUSD
                totalSpend += apiSpan.costUSD
                inTokSum += apiSpan.inputTokens
                cacheTokSum += apiSpan.cachedReadTokens

                let rootKind: WiretapFlameSpanKind = apiSpan.blockedByCircuitBreaker ? .circuitBreakerGate : .requestTurnRoot
                let rootID = apiSpan.id
                let root = WiretapFlameSpan(
                    id: rootID,
                    parentSpanID: nil,
                    laneID: laneID,
                    taskID: apiSpan.taskID,
                    vendor: apiSpan.vendor,
                    modelIdentifier: apiSpan.modelIdentifier,
                    kind: rootKind,
                    label: apiSpan.blockedByCircuitBreaker
                        ? "CIRCUIT HALT (\(apiSpan.statusCode))"
                        : "\(apiSpan.modelIdentifier) ($\(String(format: "%.3f", apiSpan.costUSD)))",
                    startOffsetMs: startMs,
                    durationMs: durMs,
                    depth: 0,
                    tokenCount: apiSpan.inputTokens + apiSpan.outputTokens + apiSpan.reasoningTokens,
                    costUSD: apiSpan.costUSD
                )
                trackFlameSpans.append(root)
                rootIntervals.append((startMs, startMs + durMs))

                if !apiSpan.blockedByCircuitBreaker {
                    trackFlameSpans.append(
                        WiretapFlameSpan(
                            parentSpanID: rootID,
                            laneID: laneID,
                            taskID: apiSpan.taskID,
                            vendor: apiSpan.vendor,
                            modelIdentifier: apiSpan.modelIdentifier,
                            kind: .providerQueueTTFT,
                            label: "TTFT Prefill",
                            startOffsetMs: startMs,
                            durationMs: ttft,
                            depth: 1,
                            tokenCount: apiSpan.inputTokens
                        )
                    )
                    let remMs = max(1.0, durMs - ttft)
                    if apiSpan.reasoningTokens > 0 {
                        let thinkShare = Double(apiSpan.reasoningTokens) / Double(max(1, apiSpan.reasoningTokens + apiSpan.outputTokens))
                        let thinkDur = max(1.0, remMs * thinkShare)
                        trackFlameSpans.append(
                            WiretapFlameSpan(
                                parentSpanID: rootID,
                                laneID: laneID,
                                taskID: apiSpan.taskID,
                                vendor: apiSpan.vendor,
                                modelIdentifier: apiSpan.modelIdentifier,
                                kind: .extendedThinking,
                                label: "Reasoning (\(apiSpan.reasoningTokens) tok)",
                                startOffsetMs: startMs + ttft,
                                durationMs: thinkDur,
                                depth: 1,
                                tokenCount: apiSpan.reasoningTokens
                            )
                        )
                        trackFlameSpans.append(
                            WiretapFlameSpan(
                                parentSpanID: rootID,
                                laneID: laneID,
                                taskID: apiSpan.taskID,
                                vendor: apiSpan.vendor,
                                modelIdentifier: apiSpan.modelIdentifier,
                                kind: .assistantTextStream,
                                label: "Output (\(apiSpan.outputTokens) tok)",
                                startOffsetMs: startMs + ttft + thinkDur,
                                durationMs: max(1.0, remMs - thinkDur),
                                depth: 1,
                                tokenCount: apiSpan.outputTokens
                            )
                        )
                    } else {
                        trackFlameSpans.append(
                            WiretapFlameSpan(
                                parentSpanID: rootID,
                                laneID: laneID,
                                taskID: apiSpan.taskID,
                                vendor: apiSpan.vendor,
                                modelIdentifier: apiSpan.modelIdentifier,
                                kind: .assistantTextStream,
                                label: "Output (\(apiSpan.outputTokens) tok)",
                                startOffsetMs: startMs + ttft,
                                durationMs: remMs,
                                depth: 1,
                                tokenCount: apiSpan.outputTokens
                            )
                        )
                    }
                }

                cursorOffsetMs = startMs + durMs + 25.0
                maxHorizon = max(maxHorizon, startMs + durMs)
            }

            let avgTTFT = ttftSum / Double(max(1, laneSpans.count))
            let cachePct = inTokSum > 0 ? (Double(cacheTokSum) / Double(inTokSum)) * 100.0 : 0.0
            tracks.append(
                WiretapFlameTrack(
                    laneID: laneID,
                    vendor: first.vendor,
                    spans: trackFlameSpans,
                    totalLaneSpendUSD: laneSpend,
                    averageTTFTMs: avgTTFT,
                    cacheHitPercentage: cachePct
                )
            )
        }

        // Sweep-line peak concurrency across lanes
        var sweepEvents: [(time: Double, delta: Int)] = []
        sweepEvents.reserveCapacity(rootIntervals.count * 2)
        for iv in rootIntervals {
            sweepEvents.append((iv.start, 1))
            sweepEvents.append((iv.end, -1))
        }
        sweepEvents.sort { lhs, rhs in
            if lhs.time == rhs.time { return lhs.delta < rhs.delta }
            return lhs.time < rhs.time
        }
        var active = 0
        var peak = 0
        for ev in sweepEvents {
            active += ev.delta
            peak = max(peak, active)
        }

        return WiretapFlamechartTimeline(
            tracks: tracks,
            horizonDurationMs: maxHorizon,
            maxConcurrentActiveLanes: peak,
            globalSpendUSD: totalSpend
        )
    }
}
