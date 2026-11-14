import Foundation
import RelayModels

// MARK: - Unified Scrollback + Active Viewport Coordinate & Search Models

public enum TerminalLineOrigin: Sendable, Codable, Hashable {
    case scrollback(offsetFromOldest: Int)
    case activeViewport(row: Int)
}

public enum TerminalSearchMode: Sendable, Codable, Hashable {
    case substring
    case caseInsensitiveSubstring
    case wholeWord(caseSensitive: Bool)
    case regularExpression(caseSensitive: Bool)
}

public struct TerminalCellStyleFilter: Sendable, Codable, Hashable {
    public var requiredAttributes: TerminalCellAttributes
    public var excludedAttributes: TerminalCellAttributes
    public var foregroundANSI16Indices: Set<UInt8>?

    public init(
        requiredAttributes: TerminalCellAttributes = [],
        excludedAttributes: TerminalCellAttributes = [],
        foregroundANSI16Indices: Set<UInt8>? = nil
    ) {
        self.requiredAttributes = requiredAttributes
        self.excludedAttributes = excludedAttributes
        self.foregroundANSI16Indices = foregroundANSI16Indices
    }

    public func matches(_ cell: TerminalCell) -> Bool {
        if !cell.attributes.isSuperset(of: requiredAttributes) {
            return false
        }
        if !cell.attributes.intersection(excludedAttributes).isEmpty {
            return false
        }
        if let allowedIndices = foregroundANSI16Indices {
            switch cell.foreground {
            case .ansi16(let idx):
                return allowedIndices.contains(idx)
            case .palette256(let idx) where idx < 16:
                return allowedIndices.contains(idx)
            default:
                return false
            }
        }
        return true
    }
}

public struct TerminalScrollbackMatch: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(lineIndex):\(columnRange.lowerBound)-\(columnRange.upperBound)" }
    /// 0-based index across `scrollback + activeViewport`.
    public let lineIndex: Int
    public let origin: TerminalLineOrigin
    /// 0-based terminal cell column range `[startCol..<endCol)`.
    public let columnRange: Range<Int>
    public let matchedText: String
    public let excerpt: String
    /// Character offset range of `matchedText` inside `excerpt`.
    public let excerptHighlightRange: Range<Int>
    public let captureGroups: [String]

    public init(
        lineIndex: Int,
        origin: TerminalLineOrigin,
        columnRange: Range<Int>,
        matchedText: String,
        excerpt: String,
        excerptHighlightRange: Range<Int>,
        captureGroups: [String] = []
    ) {
        self.lineIndex = lineIndex
        self.origin = origin
        self.columnRange = columnRange
        self.matchedText = matchedText
        self.excerpt = excerpt
        self.excerptHighlightRange = excerptHighlightRange
        self.captureGroups = captureGroups
    }
}

public struct TerminalSearchableLine: Sendable, Hashable {
    public let lineIndex: Int
    public let origin: TerminalLineOrigin
    public let cells: [TerminalCell]
    public let plainText: String
    /// Maps each `Character` index in `plainText` (plus sentinel `plainText.count`) to its 0-based grid column.
    public let charIndexToColumn: [Int]

    public init(lineIndex: Int, origin: TerminalLineOrigin, cells: [TerminalCell]) {
        self.lineIndex = lineIndex
        self.origin = origin
        self.cells = cells

        // Trim trailing blank space cells for fast scanning while preserving exact column mapping
        var lastNonBlank = cells.count - 1
        while lastNonBlank >= 0 {
            let cell = cells[lastNonBlank]
            if cell.grapheme != " " || cell.background != .defaultBackground || !cell.attributes.isEmpty {
                break
            }
            lastNonBlank -= 1
        }

        if lastNonBlank < 0 {
            self.plainText = ""
            self.charIndexToColumn = [0]
            return
        }

        var builtChars = ""
        builtChars.reserveCapacity(lastNonBlank + 1)
        var colMap: [Int] = []
        colMap.reserveCapacity(lastNonBlank + 2)

        var visualCol = 0
        for colIdx in 0...lastNonBlank {
            let cell = cells[colIdx]
            let span = max(1, Int(cell.columnSpan))
            for _ in cell.grapheme {
                colMap.append(visualCol)
            }
            builtChars.append(cell.grapheme)
            visualCol += span
        }
        colMap.append(visualCol)

        self.plainText = builtChars
        self.charIndexToColumn = colMap
    }

    public init(lineIndex: Int, origin: TerminalLineOrigin, rawString: String) {
        let synthesizedCells = rawString.map { ch in
            TerminalCell(character: ch)
        }
        self.init(lineIndex: lineIndex, origin: origin, cells: synthesizedCells)
    }
}

// MARK: - Fast Scrollback Search Engine (Boyer-Moore-Horspool + Regex)

public struct TerminalScrollbackSearchEngine: Sendable {
    public var excerptContextRadius: Int

    public init(excerptContextRadius: Int = 36) {
        self.excerptContextRadius = max(8, excerptContextRadius)
    }

    /// Builds unified searchable lines across `scrollback + activeViewport` from a live `VT100TerminalScreenBuffer`.
    public func extractSearchableLines(
        from screenBuffer: VT100TerminalScreenBuffer,
        maxScrollbackLines: Int = 5_000
    ) -> [TerminalSearchableLine] {
        let scrollbackRows = screenBuffer.recentScrollbackLines(limit: maxScrollbackLines)
        let snapshot = screenBuffer.snapshot()
        return buildSearchableLines(scrollbackGrid: scrollbackRows, viewportGrid: snapshot.visibleGrid)
    }

    public func buildSearchableLines(
        scrollbackGrid: [[TerminalCell]],
        viewportGrid: [[TerminalCell]]
    ) -> [TerminalSearchableLine] {
        var result: [TerminalSearchableLine] = []
        result.reserveCapacity(scrollbackGrid.count + viewportGrid.count)

        for (sbIdx, rowCells) in scrollbackGrid.enumerated() {
            result.append(
                TerminalSearchableLine(
                    lineIndex: result.count,
                    origin: .scrollback(offsetFromOldest: sbIdx),
                    cells: rowCells
                )
            )
        }
        for (vpRow, rowCells) in viewportGrid.enumerated() {
            result.append(
                TerminalSearchableLine(
                    lineIndex: result.count,
                    origin: .activeViewport(row: vpRow),
                    cells: rowCells
                )
            )
        }
        return result
    }

    /// Searches a `VT100TerminalScreenBuffer` and returns structured `(lineIndex, columnRange, excerpt)` matches.
    public func search(
        in screenBuffer: VT100TerminalScreenBuffer,
        query: String,
        mode: TerminalSearchMode = .caseInsensitiveSubstring,
        styleFilter: TerminalCellStyleFilter? = nil,
        maxResults: Int = 1_000
    ) -> [TerminalScrollbackMatch] {
        let lines = extractSearchableLines(from: screenBuffer)
        return search(lines: lines, query: query, mode: mode, styleFilter: styleFilter, maxResults: maxResults)
    }

    /// Searches pre-extracted `TerminalSearchableLine` rows.
    public func search(
        lines: [TerminalSearchableLine],
        query: String,
        mode: TerminalSearchMode = .caseInsensitiveSubstring,
        styleFilter: TerminalCellStyleFilter? = nil,
        maxResults: Int = 1_000
    ) -> [TerminalScrollbackMatch] {
        guard !query.isEmpty, maxResults > 0 else { return [] }

        switch mode {
        case .substring:
            return searchLiteralBMH(
                lines: lines,
                needle: query,
                caseInsensitive: false,
                styleFilter: styleFilter,
                maxResults: maxResults
            )
        case .caseInsensitiveSubstring:
            return searchLiteralBMH(
                lines: lines,
                needle: query,
                caseInsensitive: true,
                styleFilter: styleFilter,
                maxResults: maxResults
            )
        case .wholeWord(let caseSensitive):
            let escaped = NSRegularExpression.escapedPattern(for: query)
            return searchRegex(
                lines: lines,
                pattern: "\\b\(escaped)\\b",
                caseSensitive: caseSensitive,
                styleFilter: styleFilter,
                maxResults: maxResults
            )
        case .regularExpression(let caseSensitive):
            return searchRegex(
                lines: lines,
                pattern: query,
                caseSensitive: caseSensitive,
                styleFilter: styleFilter,
                maxResults: maxResults
            )
        }
    }

    // MARK: - Boyer-Moore-Horspool Substring Scanner

    private func searchLiteralBMH(
        lines: [TerminalSearchableLine],
        needle: String,
        caseInsensitive: Bool,
        styleFilter: TerminalCellStyleFilter?,
        maxResults: Int
    ) -> [TerminalScrollbackMatch] {
        let effectiveNeedle = caseInsensitive ? needle.lowercased() : needle
        let needleBytes = Array(effectiveNeedle.utf8)
        guard !needleBytes.isEmpty else { return [] }

        // Precompute 256-entry Boyer-Moore-Horspool skip table over UTF-8 code units
        let m = needleBytes.count
        var skipTable = [Int](repeating: m, count: 256)
        if m > 1 {
            for idx in 0..<(m - 1) {
                skipTable[Int(needleBytes[idx])] = m - 1 - idx
            }
        }

        var matches: [TerminalScrollbackMatch] = []

        for line in lines where !line.plainText.isEmpty {
            let haystackStr = caseInsensitive ? line.plainText.lowercased() : line.plainText
            // Fast path when UTF-8 length < needle UTF-8 length
            if haystackStr.utf8.count < m { continue }

            let hayBytes = Array(haystackStr.utf8)
            var bytePos = 0
            let lastStart = hayBytes.count - m

            while bytePos <= lastStart {
                let lastNeedleByte = needleBytes[m - 1]
                let candidateTailByte = hayBytes[bytePos + m - 1]

                if candidateTailByte == lastNeedleByte {
                    var matchedAll = true
                    if m > 1 {
                        for j in 0..<(m - 1) where hayBytes[bytePos + j] != needleBytes[j] {
                            matchedAll = false
                            break
                        }
                    }

                    if matchedAll {
                        if let matchRecord = buildMatchFromByteOffsets(
                            in: line,
                            normalizedHaystack: haystackStr,
                            byteStart: bytePos,
                            byteLength: m,
                            styleFilter: styleFilter
                        ) {
                            matches.append(matchRecord)
                            if matches.count >= maxResults {
                                return matches
                            }
                        }
                        bytePos += max(1, m)
                        continue
                    }
                }

                bytePos += skipTable[Int(candidateTailByte)]
            }
        }

        return matches
    }

    private func buildMatchFromByteOffsets(
        in line: TerminalSearchableLine,
        normalizedHaystack: String,
        byteStart: Int,
        byteLength: Int,
        styleFilter: TerminalCellStyleFilter?
    ) -> TerminalScrollbackMatch? {
        let utf8View = normalizedHaystack.utf8
        guard byteStart >= 0, byteStart + byteLength <= utf8View.count else { return nil }
        let startUTF8Idx = utf8View.index(utf8View.startIndex, offsetBy: byteStart)
        let endUTF8Idx = utf8View.index(startUTF8Idx, offsetBy: byteLength)
        guard let normStart = startUTF8Idx.samePosition(in: normalizedHaystack),
              let normEnd = endUTF8Idx.samePosition(in: normalizedHaystack) else {
            return nil
        }

        let charStart = normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: normStart)
        let charEnd = normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: normEnd)

        let origChars = Array(line.plainText)
        guard charStart >= 0, charEnd <= origChars.count, charStart < charEnd else {
            return nil
        }

        let startCol = line.charIndexToColumn[min(charStart, line.charIndexToColumn.count - 1)]
        let endCol = line.charIndexToColumn[min(charEnd, line.charIndexToColumn.count - 1)]
        let colRange = startCol..<max(startCol + 1, endCol)

        if let filter = styleFilter {
            let clampedStart = min(max(0, colRange.lowerBound), max(0, line.cells.count - 1))
            let clampedEnd = min(line.cells.count, colRange.upperBound)
            if clampedStart < clampedEnd {
                let anyCellMatches = line.cells[clampedStart..<clampedEnd].contains { filter.matches($0) }
                if !anyCellMatches { return nil }
            } else {
                return nil
            }
        }

        let matchedText = String(origChars[charStart..<charEnd])
        let (excerpt, highlightRange) = makeExcerpt(chars: origChars, matchStart: charStart, matchEnd: charEnd)

        return TerminalScrollbackMatch(
            lineIndex: line.lineIndex,
            origin: line.origin,
            columnRange: colRange,
            matchedText: matchedText,
            excerpt: excerpt,
            excerptHighlightRange: highlightRange
        )
    }

    private func searchRegex(
        lines: [TerminalSearchableLine],
        pattern: String,
        caseSensitive: Bool,
        styleFilter: TerminalCellStyleFilter?,
        maxResults: Int
    ) -> [TerminalScrollbackMatch] {
        var opts: NSRegularExpression.Options = []
        if !caseSensitive {
            opts.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else {
            return []
        }

        var results: [TerminalScrollbackMatch] = []
        for line in lines where !line.plainText.isEmpty {
            let ns = line.plainText as NSString
            let nsMatches = regex.matches(in: line.plainText, range: NSRange(location: 0, length: ns.length))
            if nsMatches.isEmpty { continue }

            let origChars = Array(line.plainText)
            for m in nsMatches where m.range.length > 0 {
                guard let swiftRange = Range(m.range, in: line.plainText) else { continue }
                let charStart = line.plainText.distance(from: line.plainText.startIndex, to: swiftRange.lowerBound)
                let charEnd = line.plainText.distance(from: line.plainText.startIndex, to: swiftRange.upperBound)
                guard charStart >= 0, charEnd <= origChars.count, charStart < charEnd else { continue }

                let startCol = line.charIndexToColumn[min(charStart, line.charIndexToColumn.count - 1)]
                let endCol = line.charIndexToColumn[min(charEnd, line.charIndexToColumn.count - 1)]
                let colRange = startCol..<max(startCol + 1, endCol)

                if let filter = styleFilter {
                    let cs = min(max(0, colRange.lowerBound), max(0, line.cells.count - 1))
                    let ce = min(line.cells.count, colRange.upperBound)
                    guard cs < ce, line.cells[cs..<ce].contains(where: { filter.matches($0) }) else {
                        continue
                    }
                }

                var captures: [String] = []
                if m.numberOfRanges > 1 {
                    for gIdx in 1..<m.numberOfRanges {
                        let gr = m.range(at: gIdx)
                        if gr.location != NSNotFound, let sr = Range(gr, in: line.plainText) {
                            captures.append(String(line.plainText[sr]))
                        } else {
                            captures.append("")
                        }
                    }
                }

                let matchedText = String(origChars[charStart..<charEnd])
                let (excerpt, hlRange) = makeExcerpt(chars: origChars, matchStart: charStart, matchEnd: charEnd)
                results.append(
                    TerminalScrollbackMatch(
                        lineIndex: line.lineIndex,
                        origin: line.origin,
                        columnRange: colRange,
                        matchedText: matchedText,
                        excerpt: excerpt,
                        excerptHighlightRange: hlRange,
                        captureGroups: captures
                    )
                )
                if results.count >= maxResults {
                    return results
                }
            }
        }
        return results
    }

    private func makeExcerpt(
        chars: [Character],
        matchStart: Int,
        matchEnd: Int
    ) -> (excerpt: String, highlightRange: Range<Int>) {
        let winStart = max(0, matchStart - excerptContextRadius)
        let winEnd = min(chars.count, matchEnd + excerptContextRadius)

        let prefixEllipsis = winStart > 0 ? "…" : ""
        let suffixEllipsis = winEnd < chars.count ? "…" : ""
        let prefixOffset = winStart > 0 ? 1 : 0

        let slice = String(chars[winStart..<winEnd])
        let fullExcerpt = prefixEllipsis + slice + suffixEllipsis
        let hlStart = prefixOffset + (matchStart - winStart)
        let hlEnd = hlStart + (matchEnd - matchStart)
        return (fullExcerpt, hlStart..<hlEnd)
    }
}

// MARK: - Stateful Find-Bar Incremental Search Cursor

public struct TerminalIncrementalSearchCursor: Sendable, Codable, Hashable {
    public private(set) var matches: [TerminalScrollbackMatch]
    public private(set) var activeMatchIndex: Int?

    public init(matches: [TerminalScrollbackMatch] = []) {
        self.matches = matches
        self.activeMatchIndex = matches.isEmpty ? nil : matches.count - 1
    }

    public var currentMatch: TerminalScrollbackMatch? {
        guard let idx = activeMatchIndex, idx >= 0, idx < matches.count else { return nil }
        return matches[idx]
    }

    @discardableResult
    public mutating func selectNext() -> TerminalScrollbackMatch? {
        guard !matches.isEmpty else {
            activeMatchIndex = nil
            return nil
        }
        let next = ((activeMatchIndex ?? -1) + 1) % matches.count
        activeMatchIndex = next
        return matches[next]
    }

    @discardableResult
    public mutating func selectPrevious() -> TerminalScrollbackMatch? {
        guard !matches.isEmpty else {
            activeMatchIndex = nil
            return nil
        }
        let cur = activeMatchIndex ?? 0
        let prev = (cur - 1 + matches.count) % matches.count
        activeMatchIndex = prev
        return matches[prev]
    }

    public mutating func updateMatches(_ updated: [TerminalScrollbackMatch], preferBottomMost: Bool = true) {
        self.matches = updated
        if updated.isEmpty {
            self.activeMatchIndex = nil
        } else {
            self.activeMatchIndex = preferBottomMost ? (updated.count - 1) : 0
        }
    }
}

// MARK: - Clickable URL, Localhost Port & File-Path:Line:Col Compiler Diagnostic Detector

public enum TerminalClickableLinkTarget: Sendable, Codable, Hashable {
    case webURL(url: String)
    case localhostPort(url: String, host: String, port: UInt16, path: String)
    case workspaceFile(path: String, line: Int?, column: Int?, severity: String?)
}

public struct TerminalDetectedLink: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(lineIndex):\(columnRange.lowerBound)-\(columnRange.upperBound):\(rawMatchedText)" }
    public let lineIndex: Int
    public let origin: TerminalLineOrigin
    public let columnRange: Range<Int>
    public let rawMatchedText: String
    public let target: TerminalClickableLinkTarget

    public init(
        lineIndex: Int,
        origin: TerminalLineOrigin,
        columnRange: Range<Int>,
        rawMatchedText: String,
        target: TerminalClickableLinkTarget
    ) {
        self.lineIndex = lineIndex
        self.origin = origin
        self.columnRange = columnRange
        self.rawMatchedText = rawMatchedText
        self.target = target
    }
}

public struct TerminalClickableLinkDetector: Sendable {
    public static let recognizedSourceExtensions: Set<String> = [
        "swift", "py", "pyi", "ts", "tsx", "js", "jsx", "mjs", "cjs", "rs", "go",
        "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "java", "kt", "rb", "php",
        "sh", "zsh", "bash", "json", "yaml", "yml", "toml", "md", "sql", "html", "css", "proto"
    ]

    public init() {}

    public func detectLinks(in screenBuffer: VT100TerminalScreenBuffer, includeScrollback: Bool = true) -> [TerminalDetectedLink] {
        let engine = TerminalScrollbackSearchEngine()
        let scrollback = includeScrollback ? screenBuffer.recentScrollbackLines(limit: 1_000) : []
        let lines = engine.buildSearchableLines(
            scrollbackGrid: scrollback,
            viewportGrid: screenBuffer.snapshot().visibleGrid
        )
        return detectLinks(in: lines)
    }

    public func detectLinks(in lines: [TerminalSearchableLine]) -> [TerminalDetectedLink] {
        var detected: [TerminalDetectedLink] = []

        for line in lines where !line.plainText.isEmpty {
            var occupiedCharRanges: [Range<Int>] = []
            let chars = Array(line.plainText)

            // 1. Explicit Web/File/WS URLs (`https://...`, `http://...`, `ws://...`, `file://...`)
            for urlLink in scanExplicitURLs(in: line, chars: chars) {
                detected.append(urlLink.link)
                occupiedCharRanges.append(urlLink.charRange)
            }

            // 2. Bare localhost / loopback endpoints (`localhost:3000/api`, `127.0.0.1:8080`, `[::1]:5173`)
            for localLink in scanBareLocalhostPorts(in: line, chars: chars, excluding: occupiedCharRanges) {
                detected.append(localLink.link)
                occupiedCharRanges.append(localLink.charRange)
            }

            // 3. Python Traceback (`File "path/to/script.py", line 142`)
            for pyLink in scanPythonTracebackLocations(in: line, chars: chars, excluding: occupiedCharRanges) {
                detected.append(pyLink.link)
                occupiedCharRanges.append(pyLink.charRange)
            }

            // 4. File paths with `:line:col`, `:line`, `(line,col)` and optional compiler diagnostic severity
            //    e.g. `Sources/Auth/Session.swift:142:9: error: ...`, `--> src/lib.rs:44:5`, `src/app.ts(18,4)`
            for fileLink in scanFilePathDiagnostics(in: line, chars: chars, excluding: occupiedCharRanges) {
                detected.append(fileLink.link)
                occupiedCharRanges.append(fileLink.charRange)
            }
        }

        return detected.sorted {
            if $0.lineIndex != $1.lineIndex { return $0.lineIndex < $1.lineIndex }
            return $0.columnRange.lowerBound < $1.columnRange.lowerBound
        }
    }

    // MARK: - Link Scanners

    private func scanExplicitURLs(
        in line: TerminalSearchableLine,
        chars: [Character]
    ) -> [(link: TerminalDetectedLink, charRange: Range<Int>)] {
        let pattern = #"\b(?:https?|wss?|file|ssh)://[^\s<>\"\x00-\x1F]+"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = line.plainText as NSString
        let matches = rx.matches(in: line.plainText, range: NSRange(location: 0, length: ns.length))
        var out: [(TerminalDetectedLink, Range<Int>)] = []

        for m in matches {
            guard let swiftRange = Range(m.range, in: line.plainText) else { continue }
            let startChar = line.plainText.distance(from: line.plainText.startIndex, to: swiftRange.lowerBound)
            var endChar = line.plainText.distance(from: line.plainText.startIndex, to: swiftRange.upperBound)

            // Strip unbalanced trailing punctuation (`.`, `,`, `;`, `:`, `)`, `]`, `'`)
            endChar = trimTrailingURLPunctuation(chars: chars, start: startChar, end: endChar)
            guard startChar < endChar else { continue }

            let rawURL = String(chars[startChar..<endChar])
            let colRange = columnRange(forCharRange: startChar..<endChar, in: line)

            if let localTarget = parseLocalhostURLIfApplicable(rawURL) {
                out.append((
                    TerminalDetectedLink(
                        lineIndex: line.lineIndex,
                        origin: line.origin,
                        columnRange: colRange,
                        rawMatchedText: rawURL,
                        target: localTarget
                    ),
                    startChar..<endChar
                ))
            } else {
                out.append((
                    TerminalDetectedLink(
                        lineIndex: line.lineIndex,
                        origin: line.origin,
                        columnRange: colRange,
                        rawMatchedText: rawURL,
                        target: .webURL(url: rawURL)
                    ),
                    startChar..<endChar
                ))
            }
        }
        return out
    }

    private func scanBareLocalhostPorts(
        in line: TerminalSearchableLine,
        chars: [Character],
        excluding occupied: [Range<Int>]
    ) -> [(link: TerminalDetectedLink, charRange: Range<Int>)] {
        let pattern = #"(?<![A-Za-z0-9/])(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):([0-9]{2,5})(/[^\s<>\"\)\]]*)?"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = line.plainText as NSString
        let matches = rx.matches(in: line.plainText, range: NSRange(location: 0, length: ns.length))
        var out: [(TerminalDetectedLink, Range<Int>)] = []

        for m in matches where m.numberOfRanges >= 3 {
            guard let fullRange = Range(m.range, in: line.plainText) else { continue }
            let startChar = line.plainText.distance(from: line.plainText.startIndex, to: fullRange.lowerBound)
            let endChar = trimTrailingURLPunctuation(
                chars: chars,
                start: startChar,
                end: line.plainText.distance(from: line.plainText.startIndex, to: fullRange.upperBound)
            )
            let candidateRange = startChar..<endChar
            guard !overlapsAny(candidateRange, occupied: occupied) else { continue }

            let host = ns.substring(with: m.range(at: 1))
            let portStr = ns.substring(with: m.range(at: 2))
            guard let portVal = UInt16(portStr), portVal > 0 else { continue }

            let rawMatched = String(chars[candidateRange])
            let suffixStart = host.count + 1 + portStr.count
            let pathPart = rawMatched.count > suffixStart ? String(rawMatched.dropFirst(suffixStart)) : "/"
            let normalizedHost = (host == "0.0.0.0") ? "localhost" : host
            let fullURL = "http://\(normalizedHost):\(portVal)\(pathPart.hasPrefix("/") ? pathPart : "/\(pathPart)")"

            out.append((
                TerminalDetectedLink(
                    lineIndex: line.lineIndex,
                    origin: line.origin,
                    columnRange: columnRange(forCharRange: candidateRange, in: line),
                    rawMatchedText: rawMatched,
                    target: .localhostPort(url: fullURL, host: host, port: portVal, path: pathPart)
                ),
                candidateRange
            ))
        }
        return out
    }

    private func scanPythonTracebackLocations(
        in line: TerminalSearchableLine,
        chars: [Character],
        excluding occupied: [Range<Int>]
    ) -> [(link: TerminalDetectedLink, charRange: Range<Int>)] {
        let pattern = #"File \"([^\"]+\.pyi?)\",\s*line\s+([0-9]+)"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line.plainText as NSString
        let matches = rx.matches(in: line.plainText, range: NSRange(location: 0, length: ns.length))
        var out: [(TerminalDetectedLink, Range<Int>)] = []

        for m in matches where m.numberOfRanges >= 3 {
            guard let fullRange = Range(m.range, in: line.plainText) else { continue }
            let sc = line.plainText.distance(from: line.plainText.startIndex, to: fullRange.lowerBound)
            let ec = line.plainText.distance(from: line.plainText.startIndex, to: fullRange.upperBound)
            let cRange = sc..<ec
            guard !overlapsAny(cRange, occupied: occupied) else { continue }

            let filePath = ns.substring(with: m.range(at: 1))
            let lineNum = Int(ns.substring(with: m.range(at: 2)))
            let rawText = String(chars[cRange])

            out.append((
                TerminalDetectedLink(
                    lineIndex: line.lineIndex,
                    origin: line.origin,
                    columnRange: columnRange(forCharRange: cRange, in: line),
                    rawMatchedText: rawText,
                    target: .workspaceFile(path: filePath, line: lineNum, column: nil, severity: "traceback")
                ),
                cRange
            ))
        }
        return out
    }

    private func scanFilePathDiagnostics(
        in line: TerminalSearchableLine,
        chars: [Character],
        excluding occupied: [Range<Int>]
    ) -> [(link: TerminalDetectedLink, charRange: Range<Int>)] {
        // Matches:
        //   `Sources/Auth/Session.swift:142:9` (+ optional `: error:` / `: warning:` / `: note:`)
        //   `./Tests/AppTests.ts(42,10)`
        //   an absolute path such as `/opt/project/Package.swift`
        let pattern = #"(?<![A-Za-z0-9_])((?:\.{1,2}/|/)?(?:[A-Za-z0-9_.\-]+/)+[A-Za-z0-9_.\-]+\.([A-Za-z0-9]+)|[A-Za-z0-9_.\-]+\.([A-Za-z0-9]+))(?::([0-9]+)(?::([0-9]+))?|\(([0-9]+),\s*([0-9]+)\))?(?:\s*:\s*(error|warning|note|fatal error))?"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line.plainText as NSString
        let matches = rx.matches(in: line.plainText, range: NSRange(location: 0, length: ns.length))
        var out: [(TerminalDetectedLink, Range<Int>)] = []

        for m in matches where m.numberOfRanges >= 9 {
            let filePath = ns.substring(with: m.range(at: 1))
            let ext1 = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            let ext2 = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            let ext = (ext1.isEmpty ? ext2 : ext1).lowercased()

            guard Self.recognizedSourceExtensions.contains(ext) else { continue }

            let colonLine = m.range(at: 4).location != NSNotFound ? Int(ns.substring(with: m.range(at: 4))) : nil
            let colonCol  = m.range(at: 5).location != NSNotFound ? Int(ns.substring(with: m.range(at: 5))) : nil
            let parenLine = m.range(at: 6).location != NSNotFound ? Int(ns.substring(with: m.range(at: 6))) : nil
            let parenCol  = m.range(at: 7).location != NSNotFound ? Int(ns.substring(with: m.range(at: 7))) : nil
            let severity  = m.range(at: 8).location != NSNotFound ? ns.substring(with: m.range(at: 8)).lowercased() : nil

            let resolvedLine = colonLine ?? parenLine
            let resolvedCol = colonCol ?? parenCol

            // Bare filenames without directory slash must carry `:line` or `(line,col)` to avoid false positives on prose like `Node.js`
            if !filePath.contains("/") && resolvedLine == nil && filePath != "Package.swift" {
                continue
            }

            // Compute exact span covering `path` + `:line:col` / `(line,col)` (excluding `: error:` suffix so the clickable region is crisp)
            var endUTF16 = m.range(at: 1).location + m.range(at: 1).length
            for groupIdx in [4, 5, 6, 7] {
                let r = m.range(at: groupIdx)
                if r.location != NSNotFound {
                    endUTF16 = max(endUTF16, r.location + r.length)
                }
            }
            if parenCol != nil, endUTF16 < ns.length, ns.character(at: endUTF16) == 0x29 { // closing `)`
                endUTF16 += 1
            }

            let linkNSRange = NSRange(location: m.range(at: 1).location, length: endUTF16 - m.range(at: 1).location)
            guard let swiftRange = Range(linkNSRange, in: line.plainText) else { continue }
            let sc = line.plainText.distance(from: line.plainText.startIndex, to: swiftRange.lowerBound)
            let ec = line.plainText.distance(from: line.plainText.startIndex, to: swiftRange.upperBound)
            let cRange = sc..<ec
            guard !overlapsAny(cRange, occupied: occupied) else { continue }

            out.append((
                TerminalDetectedLink(
                    lineIndex: line.lineIndex,
                    origin: line.origin,
                    columnRange: columnRange(forCharRange: cRange, in: line),
                    rawMatchedText: String(chars[cRange]),
                    target: .workspaceFile(
                        path: filePath,
                        line: resolvedLine,
                        column: resolvedCol,
                        severity: severity
                    )
                ),
                cRange
            ))
        }
        return out
    }

    private func trimTrailingURLPunctuation(chars: [Character], start: Int, end: Int) -> Int {
        var curEnd = end
        while curEnd > start {
            let tail = chars[curEnd - 1]
            if ".,;:!?'\"`".contains(tail) {
                curEnd -= 1
                continue
            }
            if tail == ")" {
                let slice = chars[start..<curEnd]
                let opens = slice.filter { $0 == "(" }.count
                let closes = slice.filter { $0 == ")" }.count
                if closes > opens {
                    curEnd -= 1
                    continue
                }
            }
            if tail == "]" {
                let slice = chars[start..<curEnd]
                let opens = slice.filter { $0 == "[" }.count
                let closes = slice.filter { $0 == "]" }.count
                if closes > opens {
                    curEnd -= 1
                    continue
                }
            }
            break
        }
        return curEnd
    }

    private func parseLocalhostURLIfApplicable(_ rawURL: String) -> TerminalClickableLinkTarget? {
        guard let comps = URLComponents(string: rawURL),
              let host = comps.host?.lowercased(),
              (host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1"),
              let portInt = comps.port,
              let port = UInt16(exactly: portInt) else {
            return nil
        }
        let path = comps.path.isEmpty ? "/" : comps.path
        return .localhostPort(url: rawURL, host: host, port: port, path: path)
    }

    private func columnRange(forCharRange charRange: Range<Int>, in line: TerminalSearchableLine) -> Range<Int> {
        let maxIdx = line.charIndexToColumn.count - 1
        let c0 = line.charIndexToColumn[min(max(0, charRange.lowerBound), maxIdx)]
        let c1 = line.charIndexToColumn[min(max(0, charRange.upperBound), maxIdx)]
        return c0..<max(c0 + 1, c1)
    }

    private func overlapsAny(_ candidate: Range<Int>, occupied: [Range<Int>]) -> Bool {
        occupied.contains { $0.overlaps(candidate) }
    }
}

// MARK: - Asciinema v2 (`.cast`) NDJSON Recorder, Player & SVG/HTML Transcript Exporter

public struct AsciicastV2ThemeMetadata: Sendable, Codable, Hashable {
    public let fg: String
    public let bg: String
    public let palette: String

    public init(fg: String, bg: String, palette: String) {
        self.fg = fg
        self.bg = bg
        self.palette = palette
    }

    public static func fromTheme(_ theme: TerminalPaletteTheme) -> AsciicastV2ThemeMetadata {
        let joined = theme.ansi16.map(\.hexRGB).joined(separator: ":")
        return AsciicastV2ThemeMetadata(
            fg: theme.defaultForeground.hexRGB,
            bg: theme.defaultBackground.hexRGB,
            palette: joined
        )
    }
}

public struct AsciicastV2Header: Sendable, Codable, Hashable {
    public var version: Int
    public var width: Int
    public var height: Int
    public var timestamp: Int?
    public var duration: Double?
    public var idleTimeLimit: Double?
    public var command: String?
    public var title: String?
    public var env: [String: String]?
    public var theme: AsciicastV2ThemeMetadata?

    enum CodingKeys: String, CodingKey {
        case version
        case width
        case height
        case timestamp
        case duration
        case idleTimeLimit = "idle_time_limit"
        case command
        case title
        case env
        case theme
    }

    public init(
        version: Int = 2,
        width: Int = 100,
        height: Int = 28,
        timestamp: Int? = nil,
        duration: Double? = nil,
        idleTimeLimit: Double? = nil,
        command: String? = nil,
        title: String? = nil,
        env: [String: String]? = ["TERM": "xterm-256color", "SHELL": "/bin/zsh"],
        theme: AsciicastV2ThemeMetadata? = nil
    ) {
        self.version = version
        self.width = max(12, width)
        self.height = max(4, height)
        self.timestamp = timestamp
        self.duration = duration
        self.idleTimeLimit = idleTimeLimit
        self.command = command
        self.title = title
        self.env = env
        self.theme = theme
    }
}

public enum AsciicastV2EventCode: String, Sendable, Codable, Hashable {
    case output = "o"
    case input = "i"
    case marker = "m"
    case resize = "r"
}

public struct AsciicastV2Event: Sendable, Codable, Hashable {
    public let elapsed: Double
    public let code: AsciicastV2EventCode
    public let payload: String

    public init(elapsed: Double, code: AsciicastV2EventCode, payload: String) {
        self.elapsed = max(0.0, elapsed)
        self.code = code
        self.payload = payload
    }
}

public struct AsciicastV2Recording: Sendable, Codable, Hashable {
    public var header: AsciicastV2Header
    public var events: [AsciicastV2Event]

    public init(header: AsciicastV2Header, events: [AsciicastV2Event] = []) {
        self.header = header
        self.events = events.sorted { $0.elapsed < $1.elapsed }
    }

    public var totalDuration: Double {
        if let d = header.duration { return d }
        return events.last?.elapsed ?? 0.0
    }

    public var markers: [(elapsed: Double, label: String)] {
        events.compactMap { ev in
            ev.code == .marker ? (ev.elapsed, ev.payload) : nil
        }
    }
}

public struct AsciicastV2Codec: Sendable {
    public init() {}

    /// Encodes an `AsciicastV2Recording` into specification-compliant `.cast` NDJSON text.
    public func encodeNDJSON(_ recording: AsciicastV2Recording) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var updatedHeader = recording.header
        updatedHeader.version = 2
        if updatedHeader.duration == nil, let last = recording.events.last {
            updatedHeader.duration = (last.elapsed * 1_000_000).rounded() / 1_000_000
        }

        let headerData = try encoder.encode(updatedHeader)
        var lines: [String] = [String(decoding: headerData, as: UTF8.self)]
        lines.reserveCapacity(recording.events.count + 1)

        for ev in recording.events {
            let formattedTime = String(format: "%.6f", ev.elapsed)
            let codeEscaped = Self.escapeJSONString(ev.code.rawValue)
            let dataEscaped = Self.escapeJSONString(ev.payload)
            lines.append("[\(formattedTime), \(codeEscaped), \(dataEscaped)]")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses `.cast` NDJSON content into a structured `AsciicastV2Recording`.
    public func decodeNDJSON(_ ndjson: String) throws -> AsciicastV2Recording {
        let rawLines = ndjson
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstLine = rawLines.first else {
            throw RelayIDEError.invalidCLIUsage("Empty asciicast v2 stream: missing JSON header line")
        }

        let decoder = JSONDecoder()
        let header: AsciicastV2Header
        do {
            header = try decoder.decode(AsciicastV2Header.self, from: Data(firstLine.utf8))
        } catch {
            throw RelayIDEError.invalidCLIUsage("Malformed asciicast v2 header: \(error.localizedDescription)")
        }

        guard header.version == 2 else {
            throw RelayIDEError.invalidCLIUsage("Unsupported asciicast version \(header.version) (expected v2)")
        }

        var events: [AsciicastV2Event] = []
        events.reserveCapacity(max(0, rawLines.count - 1))

        for lineIdx in 1..<rawLines.count {
            let lineText = rawLines[lineIdx]
            guard let jsonObj = try? JSONSerialization.jsonObject(with: Data(lineText.utf8)),
                  let tuple = jsonObj as? [Any],
                  tuple.count >= 3 else {
                continue
            }

            let elapsedVal: Double
            if let num = tuple[0] as? NSNumber {
                elapsedVal = num.doubleValue
            } else if let dbl = tuple[0] as? Double {
                elapsedVal = dbl
            } else {
                continue
            }

            guard let codeStr = tuple[1] as? String,
                  let code = AsciicastV2EventCode(rawValue: codeStr),
                  let payloadStr = tuple[2] as? String else {
                continue
            }

            events.append(AsciicastV2Event(elapsed: elapsedVal, code: code, payload: payloadStr))
        }

        return AsciicastV2Recording(header: header, events: events)
    }

    private static func escapeJSONString(_ value: String) -> String {
        var out = "\""
        out.reserveCapacity(value.utf8.count + 4)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
    }
}

// MARK: - Live Thread-Safe Asciicast v2 Session Recorder & Deterministic Player

public final class AsciicastV2Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var header: AsciicastV2Header
    private var events: [AsciicastV2Event] = []
    private var startedNanoseconds: UInt64
    private var lastRawElapsed: Double = 0.0
    private var accumulatedEffectiveElapsed: Double = 0.0

    public init(
        width: Int,
        height: Int,
        title: String? = nil,
        command: String? = nil,
        idleTimeLimit: Double? = 2.5,
        theme: TerminalPaletteTheme = .relayBauhausDark
    ) {
        self.header = AsciicastV2Header(
            version: 2,
            width: width,
            height: height,
            timestamp: Int(Date().timeIntervalSince1970),
            idleTimeLimit: idleTimeLimit,
            command: command,
            title: title,
            theme: .fromTheme(theme)
        )
        self.startedNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    public func recordOutput(_ data: Data, explicitElapsed: Double? = nil) {
        guard !data.isEmpty else { return }
        let str = String(decoding: data, as: UTF8.self)
        appendEvent(code: .output, payload: str, explicitElapsed: explicitElapsed)
    }

    public func recordOutput(_ text: String, explicitElapsed: Double? = nil) {
        guard !text.isEmpty else { return }
        appendEvent(code: .output, payload: text, explicitElapsed: explicitElapsed)
    }

    public func recordInput(_ data: Data, explicitElapsed: Double? = nil) {
        guard !data.isEmpty else { return }
        let str = String(decoding: data, as: UTF8.self)
        appendEvent(code: .input, payload: str, explicitElapsed: explicitElapsed)
    }

    public func recordMarker(_ label: String, explicitElapsed: Double? = nil) {
        appendEvent(code: .marker, payload: label, explicitElapsed: explicitElapsed)
    }

    public func recordResize(columns: Int, rows: Int, explicitElapsed: Double? = nil) {
        appendEvent(code: .resize, payload: "\(max(12, columns))x\(max(4, rows))", explicitElapsed: explicitElapsed)
    }

    public func finalizeRecording() -> AsciicastV2Recording {
        lock.lock()
        defer { lock.unlock() }
        var hdr = header
        hdr.duration = events.last?.elapsed ?? 0.0
        return AsciicastV2Recording(header: hdr, events: events)
    }

    private func appendEvent(code: AsciicastV2EventCode, payload: String, explicitElapsed: Double?) {
        lock.lock()
        defer { lock.unlock() }

        let effective: Double
        if let exp = explicitElapsed {
            effective = max(accumulatedEffectiveElapsed, exp)
            lastRawElapsed = exp
            accumulatedEffectiveElapsed = effective
        } else {
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            let rawElapsed = Double(nowNanos &- startedNanoseconds) / 1_000_000_000.0
            var delta = max(0.0, rawElapsed - lastRawElapsed)
            if let limit = header.idleTimeLimit, limit > 0 {
                delta = min(delta, limit)
            }
            lastRawElapsed = rawElapsed
            accumulatedEffectiveElapsed += delta
            effective = accumulatedEffectiveElapsed
        }

        events.append(AsciicastV2Event(elapsed: effective, code: code, payload: payload))
    }
}

public struct AsciicastReplayFrame: Sendable, Codable, Hashable {
    public let eventIndex: Int
    public let originalElapsed: Double
    public let scaledPlaybackTime: Double
    public let snapshot: TerminalViewportSnapshot
    public let activeMarker: String?

    public init(
        eventIndex: Int,
        originalElapsed: Double,
        scaledPlaybackTime: Double,
        snapshot: TerminalViewportSnapshot,
        activeMarker: String?
    ) {
        self.eventIndex = eventIndex
        self.originalElapsed = originalElapsed
        self.scaledPlaybackTime = scaledPlaybackTime
        self.snapshot = snapshot
        self.activeMarker = activeMarker
    }
}

public struct AsciicastV2Player: Sendable {
    public let recording: AsciicastV2Recording
    public let laneID: String

    public init(recording: AsciicastV2Recording, laneID: String = "asciicast-replay") {
        self.recording = recording
        self.laneID = laneID
    }

    /// Deterministically replays all `"o"` and `"r"` events up to `targetTimeSeconds` and returns the exact `VT100TerminalScreenBuffer` state.
    public func replayState(upToSeconds targetTimeSeconds: Double? = nil) -> (buffer: VT100TerminalScreenBuffer, activeMarker: String?) {
        let buffer = VT100TerminalScreenBuffer(
            laneID: laneID,
            rows: recording.header.height,
            columns: recording.header.width
        )
        let cutoff = targetTimeSeconds ?? Double.greatestFiniteMagnitude
        var currentMarker: String?

        for event in recording.events {
            if event.elapsed > cutoff {
                break
            }
            switch event.code {
            case .output:
                buffer.feed(event.payload)
            case .resize:
                let dims = event.payload.lowercased().split(separator: "x").compactMap { Int($0) }
                if dims.count == 2 {
                    buffer.resize(rows: dims[1], columns: dims[0])
                }
            case .marker:
                currentMarker = event.payload
            case .input:
                break
            }
        }
        return (buffer, currentMarker)
    }

    /// Generates time-scaled playback frames at variable `speedMultiplier` (`0.25x` .. `16x`) with optional idle-gap clamping.
    public func buildVariableSpeedSchedule(
        speedMultiplier: Double = 1.0,
        maxIdlePauseSeconds: Double? = 1.5,
        keyframeIntervalSeconds: Double = 0.25
    ) -> [AsciicastReplayFrame] {
        let speed = min(32.0, max(0.1, speedMultiplier))
        let buffer = VT100TerminalScreenBuffer(
            laneID: laneID,
            rows: recording.header.height,
            columns: recording.header.width
        )

        var frames: [AsciicastReplayFrame] = []
        var prevOriginal = 0.0
        var scaledClock = 0.0
        var lastEmittedClock = -Double.greatestFiniteMagnitude
        var latestMarker: String?

        for (idx, event) in recording.events.enumerated() {
            var rawGap = max(0.0, event.elapsed - prevOriginal)
            if let cap = maxIdlePauseSeconds, cap > 0 {
                rawGap = min(rawGap, cap)
            }
            prevOriginal = event.elapsed
            scaledClock += rawGap / speed

            switch event.code {
            case .output:
                buffer.feed(event.payload)
            case .resize:
                let dims = event.payload.lowercased().split(separator: "x").compactMap { Int($0) }
                if dims.count == 2 {
                    buffer.resize(rows: dims[1], columns: dims[0])
                }
            case .marker:
                latestMarker = event.payload
            case .input:
                continue
            }

            let isLast = (idx == recording.events.count - 1)
            if isLast || event.code == .marker || (scaledClock - lastEmittedClock) >= keyframeIntervalSeconds {
                frames.append(
                    AsciicastReplayFrame(
                        eventIndex: idx,
                        originalElapsed: event.elapsed,
                        scaledPlaybackTime: scaledClock,
                        snapshot: buffer.snapshot(),
                        activeMarker: latestMarker
                    )
                )
                lastEmittedClock = scaledClock
            }
        }

        if frames.isEmpty {
            frames.append(
                AsciicastReplayFrame(
                    eventIndex: 0,
                    originalElapsed: 0.0,
                    scaledPlaybackTime: 0.0,
                    snapshot: buffer.snapshot(),
                    activeMarker: nil
                )
            )
        }
        return frames
    }
}

// MARK: - Self-Contained Crisp SVG & HTML ANSI Terminal Transcript Exporter

public struct TerminalTranscriptExportOptions: Sendable, Codable, Hashable {
    public var title: String
    public var vendorBadge: AgentVendor?
    public var fontFamily: String
    public var fontSizePx: Double
    public var cellWidthPx: Double
    public var cellHeightPx: Double
    public var paddingPx: Double
    public var includeChromeHeader: Bool
    public var includeLineNumbersInHTML: Bool
    public var renderCursor: Bool

    public init(
        title: String = "RelayIDE Terminal Transcript",
        vendorBadge: AgentVendor? = nil,
        fontFamily: String = "'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace",
        fontSizePx: Double = 13.0,
        cellWidthPx: Double = 8.0,
        cellHeightPx: Double = 18.0,
        paddingPx: Double = 16.0,
        includeChromeHeader: Bool = true,
        includeLineNumbersInHTML: Bool = true,
        renderCursor: Bool = true
    ) {
        self.title = title
        self.vendorBadge = vendorBadge
        self.fontFamily = fontFamily
        self.fontSizePx = fontSizePx
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.paddingPx = paddingPx
        self.includeChromeHeader = includeChromeHeader
        self.includeLineNumbersInHTML = includeLineNumbersInHTML
        self.renderCursor = renderCursor
    }
}

public struct TerminalTranscriptExporter: Sendable {
    public let palette: Xterm256ColorPalette

    public init(palette: Xterm256ColorPalette = Xterm256ColorPalette(theme: .relayBauhausDark)) {
        self.palette = palette
    }

    /// Exports a crisp, self-contained vector SVG terminal transcript with run-length coalesced background & foreground spans.
    public func exportSVG(
        snapshot: TerminalViewportSnapshot,
        scrollbackRows: [[TerminalCell]] = [],
        options: TerminalTranscriptExportOptions = TerminalTranscriptExportOptions()
    ) -> String {
        let allRows = scrollbackRows + snapshot.visibleGrid
        let scrollbackOffset = scrollbackRows.count
        let totalRows = max(1, allRows.count)
        let cols = max(1, snapshot.columns)

        let headerHeight = options.includeChromeHeader ? 38.0 : 0.0
        let totalWidth = options.paddingPx * 2.0 + Double(cols) * options.cellWidthPx
        let totalHeight = headerHeight + options.paddingPx * 2.0 + Double(totalRows) * options.cellHeightPx
        let bgHex = palette.theme.defaultBackground.hexRGB
        let fgHex = palette.theme.defaultForeground.hexRGB

        var svg: [String] = []
        svg.reserveCapacity(totalRows * 4 + 24)

        svg.append(String(
            format: #"<svg xmlns="http://www.w3.org/2000/svg" width="%.1f" height="%.1f" viewBox="0 0 %.1f %.1f" role="img" aria-label="%@">"#,
            totalWidth, totalHeight, totalWidth, totalHeight,
            Self.escapeXML(options.title.isEmpty ? snapshot.windowTitle : options.title)
        ))
        svg.append(#"  <defs><style>.term-row { font-variant-ligatures: none; white-space: pre; }</style></defs>"#)
        svg.append(String(
            format: ##"  <rect x="0" y="0" width="%.1f" height="%.1f" rx="8" fill="%@" stroke="#27272A" stroke-width="1"/>"##,
            totalWidth, totalHeight, bgHex
        ))

        if options.includeChromeHeader {
            svg.append(String(
                format: ##"  <rect x="0.5" y="0.5" width="%.1f" height="37" rx="7.5" fill="#111113"/>"##,
                totalWidth - 1.0
            ))
            svg.append(String(
                format: ##"  <line x1="0" y1="38" x2="%.1f" y2="38" stroke="#27272A" stroke-width="1"/>"##,
                totalWidth
            ))
            // Industrial Bauhaus traffic dots
            svg.append(##"  <circle cx="18" cy="19" r="5.5" fill="#DA3C2A"/>"##)
            svg.append(##"  <circle cx="36" cy="19" r="5.5" fill="#DC8F14"/>"##)
            svg.append(##"  <circle cx="54" cy="19" r="5.5" fill="#188B5D"/>"##)

            let displayTitle = snapshot.windowTitle.isEmpty ? options.title : snapshot.windowTitle
            svg.append(String(
                format: ##"  <text x="%.1f" y="23.5" text-anchor="middle" fill="#A1A1AA" font-family=%@ font-size="12" font-weight="600">%@</text>"##,
                totalWidth * 0.5,
                Self.quoteXMLAttr(options.fontFamily),
                Self.escapeXML(displayTitle)
            ))

            if let vendor = options.vendorBadge {
                let badgeX = totalWidth - 68.0
                svg.append(String(
                    format: ##"  <rect x="%.1f" y="9" width="54" height="20" rx="4" fill="%@"/>"##,
                    badgeX, vendor.signalHexColor
                ))
                svg.append(String(
                    format: ##"  <text x="%.1f" y="22.5" text-anchor="middle" fill="#FFFFFF" font-family=%@ font-size="10" font-weight="700">%@</text>"##,
                    badgeX + 27.0,
                    Self.quoteXMLAttr(options.fontFamily),
                    Self.escapeXML(vendor.shortBadge)
                ))
            }
        }

        // Render background spans and foreground text runs row-by-row
        let originX = options.paddingPx
        let originY = headerHeight + options.paddingPx
        let baselineOffset = options.cellHeightPx * 0.76

        for (rowIdx, rowCells) in allRows.enumerated() {
            let rowTopY = originY + Double(rowIdx) * options.cellHeightPx
            let viewportRow = rowIdx - scrollbackOffset
            let cursorColInRow: Int? = (options.renderCursor && snapshot.cursor.isVisible && viewportRow == snapshot.cursor.row)
                ? snapshot.cursor.column
                : nil

            // Resolve colors for each column in this row
            var resolvedRow: [(cell: TerminalCell, colors: ResolvedCellColorPair, isCursor: Bool)] = []
            resolvedRow.reserveCapacity(rowCells.count)
            for (colIdx, cell) in rowCells.enumerated() {
                let isCur = (cursorColInRow == colIdx)
                let pair = palette.resolveCellColors(
                    for: cell,
                    isCursorCell: isCur,
                    cursorShape: snapshot.cursor.shape
                )
                resolvedRow.append((cell, pair, isCur))
            }

            // 1. Coalesce non-default background `<rect>` runs
            var col = 0
            while col < resolvedRow.count {
                let bg = resolvedRow[col].colors.background
                if bg == palette.theme.defaultBackground {
                    col += 1
                    continue
                }
                var runEnd = col + 1
                while runEnd < resolvedRow.count && resolvedRow[runEnd].colors.background == bg {
                    runEnd += 1
                }
                let rectX = originX + Double(col) * options.cellWidthPx
                let rectW = Double(runEnd - col) * options.cellWidthPx
                svg.append(String(
                    format: #"  <rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%@"/>"#,
                    rectX, rowTopY, rectW, options.cellHeightPx, bg.hexRGB
                ))
                col = runEnd
            }

            // 2. Render non-block cursor shapes (bar or underline) if active on this row
            if let curCol = cursorColInRow, curCol >= 0, curCol < cols {
                let curX = originX + Double(curCol) * options.cellWidthPx
                let curHex = palette.theme.cursorColor.hexRGB
                switch snapshot.cursor.shape {
                case .bar:
                    svg.append(String(
                        format: #"  <rect x="%.1f" y="%.1f" width="2.0" height="%.1f" fill="%@"/>"#,
                        curX, rowTopY, options.cellHeightPx, curHex
                    ))
                case .underline:
                    svg.append(String(
                        format: #"  <rect x="%.1f" y="%.1f" width="%.1f" height="2.2" fill="%@"/>"#,
                        curX, rowTopY + options.cellHeightPx - 2.5, options.cellWidthPx, curHex
                    ))
                case .block:
                    break
                }
            }

            // 3. Coalesce foreground styled text runs (skipping trailing blank spaces)
            var lastPrintable = resolvedRow.count - 1
            while lastPrintable >= 0 {
                let item = resolvedRow[lastPrintable]
                if item.cell.grapheme != " " || item.cell.attributes.contains(.underline) || item.cell.attributes.contains(.strikethrough) || item.isCursor {
                    break
                }
                lastPrintable -= 1
            }
            if lastPrintable < 0 { continue }

            var textSpans: [String] = []
            var cIdx = 0
            while cIdx <= lastPrintable {
                let first = resolvedRow[cIdx]
                let fg = first.colors.foreground
                let attrs = first.cell.attributes
                var runText = first.cell.grapheme
                var nextIdx = cIdx + 1

                while nextIdx <= lastPrintable {
                    let cand = resolvedRow[nextIdx]
                    if cand.colors.foreground == fg && cand.cell.attributes == attrs {
                        runText.append(cand.cell.grapheme)
                        nextIdx += 1
                    } else {
                        break
                    }
                }

                // Skip invisible space-only unstyled spans
                if runText.allSatisfy({ $0 == " " }) && !attrs.contains(.underline) && !attrs.contains(.strikethrough) {
                    cIdx = nextIdx
                    continue
                }

                let spanX = originX + Double(cIdx) * options.cellWidthPx
                var attrParts: [String] = [String(format: #"x="%.1f""#, spanX)]
                if fg.hexRGB != fgHex {
                    attrParts.append(#"fill="\#(fg.hexRGB)""#)
                }
                if attrs.contains(.bold) {
                    attrParts.append(#"font-weight="700""#)
                }
                if attrs.contains(.italic) {
                    attrParts.append(#"font-style="italic""#)
                }
                var decorations: [String] = []
                if attrs.contains(.underline) { decorations.append("underline") }
                if attrs.contains(.strikethrough) { decorations.append("line-through") }
                if !decorations.isEmpty {
                    attrParts.append(#"text-decoration="\#(decorations.joined(separator: " "))""#)
                }

                textSpans.append("<tspan \(attrParts.joined(separator: " "))>\(Self.escapeXML(runText))</tspan>")
                cIdx = nextIdx
            }

            if !textSpans.isEmpty {
                svg.append(String(
                    format: #"  <text y="%.1f" fill="%@" font-family=%@ font-size="%.1f" class="term-row" xml:space="preserve">%@</text>"#,
                    rowTopY + baselineOffset,
                    fgHex,
                    Self.quoteXMLAttr(options.fontFamily),
                    options.fontSizePx,
                    textSpans.joined()
                ))
            }
        }

        svg.append("</svg>")
        return svg.joined(separator: "\n")
    }

    /// Exports a self-contained HTML5 ANSI terminal transcript document with WCAG-clamped inline colors and optional asciicast chapter metadata.
    public func exportHTML(
        snapshot: TerminalViewportSnapshot,
        scrollbackRows: [[TerminalCell]] = [],
        recording: AsciicastV2Recording? = nil,
        options: TerminalTranscriptExportOptions = TerminalTranscriptExportOptions()
    ) -> String {
        let allRows = scrollbackRows + snapshot.visibleGrid
        let scrollbackOffset = scrollbackRows.count
        let bgHex = palette.theme.defaultBackground.hexRGB
        let fgHex = palette.theme.defaultForeground.hexRGB
        let docTitle = options.title.isEmpty ? (snapshot.windowTitle.isEmpty ? snapshot.laneID : snapshot.windowTitle) : options.title

        var htmlLines: [String] = []
        htmlLines.reserveCapacity(allRows.count + 48)

        for (rowIdx, rowCells) in allRows.enumerated() {
            let viewportRow = rowIdx - scrollbackOffset
            let cursorCol: Int? = (options.renderCursor && snapshot.cursor.isVisible && viewportRow == snapshot.cursor.row)
                ? snapshot.cursor.column
                : nil

            var lastNonSpace = rowCells.count - 1
            while lastNonSpace >= 0 {
                let c = rowCells[lastNonSpace]
                if c.grapheme != " " || c.background != .defaultBackground || !c.attributes.isEmpty || cursorCol == lastNonSpace {
                    break
                }
                lastNonSpace -= 1
            }

            var rowFragments: [String] = []
            if options.includeLineNumbersInHTML {
                rowFragments.append(String(format: #"<span class="ln">%4d</span>"#, rowIdx + 1))
            }

            if lastNonSpace >= 0 {
                var col = 0
                while col <= lastNonSpace {
                    let firstCell = rowCells[col]
                    let firstCur = (cursorCol == col)
                    let firstColors = palette.resolveCellColors(
                        for: firstCell,
                        isCursorCell: firstCur,
                        cursorShape: snapshot.cursor.shape
                    )
                    let firstAttrs = firstCell.attributes

                    var runText = firstCell.grapheme
                    var nextCol = col + 1
                    while nextCol <= lastNonSpace {
                        let candCell = rowCells[nextCol]
                        let candCur = (cursorCol == nextCol)
                        let candColors = palette.resolveCellColors(
                            for: candCell,
                            isCursorCell: candCur,
                            cursorShape: snapshot.cursor.shape
                        )
                        if candColors.foreground == firstColors.foreground
                            && candColors.background == firstColors.background
                            && candCell.attributes == firstAttrs
                            && candCur == firstCur {
                            runText.append(candCell.grapheme)
                            nextCol += 1
                        } else {
                            break
                        }
                    }

                    var styles: [String] = []
                    if firstColors.foreground.hexRGB != fgHex {
                        styles.append("color:\(firstColors.foreground.hexRGB)")
                    }
                    if firstColors.background.hexRGB != bgHex {
                        styles.append("background-color:\(firstColors.background.hexRGB)")
                    }
                    if firstAttrs.contains(.bold) { styles.append("font-weight:700") }
                    if firstAttrs.contains(.italic) { styles.append("font-style:italic") }
                    var decos: [String] = []
                    if firstAttrs.contains(.underline) { decos.append("underline") }
                    if firstAttrs.contains(.strikethrough) { decos.append("line-through") }
                    if !decos.isEmpty { styles.append("text-decoration:\(decos.joined(separator: " "))") }

                    let escaped = Self.escapeXML(runText)
                    if styles.isEmpty {
                        rowFragments.append(escaped)
                    } else {
                        rowFragments.append(#"<span style="\#(styles.joined(separator: ";"))">\#(escaped)</span>"#)
                    }
                    col = nextCol
                }
            }

            htmlLines.append(#"<div class="term-line">\#(rowFragments.joined())</div>"#)
        }

        var markerSummaryHTML = ""
        if let rec = recording, !rec.markers.isEmpty {
            let items = rec.markers.map { m in
                String(format: #"<li><code>%06.2fs</code> — %@</li>"#, m.elapsed, Self.escapeXML(m.label))
            }.joined()
            markerSummaryHTML = #"<section class="markers"><h2>Session Markers</h2><ul>\#(items)</ul></section>"#
        }

        let badgeHTML: String
        if let v = options.vendorBadge {
            badgeHTML = #"<span class="badge" style="background:\#(v.signalHexColor)">\#(Self.escapeXML(v.displayName))</span>"#
        } else {
            badgeHTML = ""
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8"/>
          <title>\(Self.escapeXML(docTitle))</title>
          <style>
            :root { color-scheme: dark; }
            body { margin: 24px; background: #09090B; color: \(fgHex); font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            .window { max-width: 1120px; margin: 0 auto; background: \(bgHex); border: 1px solid #27272A; border-radius: 8px; overflow: hidden; }
            .chrome { display: flex; align-items: center; justify-content: space-between; padding: 10px 14px; background: #111113; border-bottom: 1px solid #27272A; font-size: 12px; color: #A1A1AA; }
            .dots { display: flex; gap: 7px; }
            .dot { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
            .badge { color: #FFF; font-weight: 700; padding: 2px 8px; border-radius: 4px; font-size: 11px; }
            .viewport { padding: \(Int(options.paddingPx))px; font-family: \(options.fontFamily); font-size: \(Int(options.fontSizePx))px; line-height: \(Int(options.cellHeightPx))px; overflow-x: auto; }
            .term-line { white-space: pre; min-height: \(Int(options.cellHeightPx))px; }
            .ln { display: inline-block; width: 4ch; margin-right: 14px; color: #52525B; user-select: none; }
            .markers { max-width: 1120px; margin: 16px auto 0; padding: 12px 16px; background: #111113; border: 1px solid #27272A; border-radius: 8px; font-size: 13px; }
            .markers h2 { margin: 0 0 8px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: #A1A1AA; }
            .markers ul { margin: 0; padding-left: 20px; }
          </style>
        </head>
        <body>
          <main class="window">
            <header class="chrome">
              <span class="dots"><i class="dot" style="background:#DA3C2A"></i><i class="dot" style="background:#DC8F14"></i><i class="dot" style="background:#188B5D"></i></span>
              <strong>\(Self.escapeXML(docTitle)) (\(snapshot.columns)&times;\(snapshot.rows))</strong>
              \(badgeHTML)
            </header>
            <div class="viewport">
        \(htmlLines.joined(separator: "\n"))
            </div>
          </main>
          \(markerSummaryHTML)
        </body>
        </html>
        """
    }

    private static func escapeXML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func quoteXMLAttr(_ raw: String) -> String {
        "\"\(escapeXML(raw))\""
    }
}
