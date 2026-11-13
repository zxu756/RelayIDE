import Foundation
import RelayModels

// MARK: - Structured Git Diff Metadata, Intraline Spans, Unified & Side-by-Side Split Models

public enum GitDiffChangeKind: String, Sendable, Codable, Hashable, CaseIterable {
    case modified = "MODIFIED"
    case added = "ADDED"
    case deleted = "DELETED"
    case renamed = "RENAMED"
    case copied = "COPIED"
    case modeChanged = "MODE_CHANGED"
    case binaryModified = "BINARY"
}

public enum DiffHighlightEmphasis: String, Sendable, Codable, Hashable {
    case unchanged
    case deletedToken
    case insertedToken
}

/// Character-offset highlight span `[startCharOffset..<endCharOffset)` within a single diff line.
public struct DiffIntralineHighlightSpan: Sendable, Codable, Hashable {
    public let startCharOffset: Int
    public let endCharOffset: Int
    public let emphasis: DiffHighlightEmphasis

    public init(startCharOffset: Int, endCharOffset: Int, emphasis: DiffHighlightEmphasis) {
        self.startCharOffset = max(0, startCharOffset)
        self.endCharOffset = max(self.startCharOffset, endCharOffset)
        self.emphasis = emphasis
    }

    public var charRange: Range<Int> {
        startCharOffset..<endCharOffset
    }

    public var length: Int {
        endCharOffset - startCharOffset
    }
}

public enum UnifiedDiffRowKind: String, Sendable, Codable, Hashable {
    case hunkHeader
    case context
    case deletion
    case addition
    case noNewlineNotice
}

public struct UnifiedDiffRow: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(hunkIndex):\(rowIndexInHunk)" }
    public let hunkIndex: Int
    public let rowIndexInHunk: Int
    public let kind: UnifiedDiffRowKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let content: String
    public let intralineSpans: [DiffIntralineHighlightSpan]
    public let missingTrailingNewline: Bool

    public init(
        hunkIndex: Int,
        rowIndexInHunk: Int,
        kind: UnifiedDiffRowKind,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil,
        content: String,
        intralineSpans: [DiffIntralineHighlightSpan] = [],
        missingTrailingNewline: Bool = false
    ) {
        self.hunkIndex = hunkIndex
        self.rowIndexInHunk = rowIndexInHunk
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.content = content
        self.intralineSpans = intralineSpans
        self.missingTrailingNewline = missingTrailingNewline
    }
}

public enum SplitDiffCellKind: String, Sendable, Codable, Hashable {
    case context
    case pureDeletion
    case pureAddition
    case pairedDeletion
    case pairedAddition
}

public struct SplitDiffPaneCell: Sendable, Codable, Hashable {
    public let lineNumber: Int
    public let kind: SplitDiffCellKind
    public let content: String
    public let intralineSpans: [DiffIntralineHighlightSpan]
    public let missingTrailingNewline: Bool

    public init(
        lineNumber: Int,
        kind: SplitDiffCellKind,
        content: String,
        intralineSpans: [DiffIntralineHighlightSpan] = [],
        missingTrailingNewline: Bool = false
    ) {
        self.lineNumber = lineNumber
        self.kind = kind
        self.content = content
        self.intralineSpans = intralineSpans
        self.missingTrailingNewline = missingTrailingNewline
    }
}

public struct SplitDiffExpandableGap: Sendable, Codable, Hashable {
    public let hiddenLineCount: Int
    public let oldLineRange: ClosedRange<Int>
    public let newLineRange: ClosedRange<Int>

    public init(hiddenLineCount: Int, oldLineRange: ClosedRange<Int>, newLineRange: ClosedRange<Int>) {
        self.hiddenLineCount = hiddenLineCount
        self.oldLineRange = oldLineRange
        self.newLineRange = newLineRange
    }
}

public enum SplitDiffRowKind: String, Sendable, Codable, Hashable {
    case hunkHeader
    case contextPair
    case modifiedPair
    case deletionOnly
    case additionOnly
}

public struct SplitDiffRow: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(hunkIndex):\(splitRowIndex)" }
    public let hunkIndex: Int
    public let splitRowIndex: Int
    public let kind: SplitDiffRowKind
    public let hunkHeaderSummary: String?
    public let expandableGap: SplitDiffExpandableGap?
    public let leftCell: SplitDiffPaneCell?
    public let rightCell: SplitDiffPaneCell?
    public let pairSimilarityScore: Double?

    public init(
        hunkIndex: Int,
        splitRowIndex: Int,
        kind: SplitDiffRowKind,
        hunkHeaderSummary: String? = nil,
        expandableGap: SplitDiffExpandableGap? = nil,
        leftCell: SplitDiffPaneCell? = nil,
        rightCell: SplitDiffPaneCell? = nil,
        pairSimilarityScore: Double? = nil
    ) {
        self.hunkIndex = hunkIndex
        self.splitRowIndex = splitRowIndex
        self.kind = kind
        self.hunkHeaderSummary = hunkHeaderSummary
        self.expandableGap = expandableGap
        self.leftCell = leftCell
        self.rightCell = rightCell
        self.pairSimilarityScore = pairSimilarityScore
    }
}

public struct ParsedDiffHunk: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(hunkIndex):-\(oldStart),\(oldCount)+\(newStart),\(newCount)" }
    public let hunkIndex: Int
    public let rawHeaderLine: String
    public let sectionHeading: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let additionsCount: Int
    public let deletionsCount: Int
    public let unifiedRows: [UnifiedDiffRow]
    public let splitRows: [SplitDiffRow]

    public init(
        hunkIndex: Int,
        rawHeaderLine: String,
        sectionHeading: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        additionsCount: Int,
        deletionsCount: Int,
        unifiedRows: [UnifiedDiffRow],
        splitRows: [SplitDiffRow]
    ) {
        self.hunkIndex = hunkIndex
        self.rawHeaderLine = rawHeaderLine
        self.sectionHeading = sectionHeading
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.additionsCount = additionsCount
        self.deletionsCount = deletionsCount
        self.unifiedRows = unifiedRows
        self.splitRows = splitRows
    }
}

public struct ParsedGitFileDiff: Sendable, Codable, Hashable, Identifiable {
    public var id: String { displayPath }
    public let oldPath: String?
    public let newPath: String?
    public let changeKind: GitDiffChangeKind
    public let oldMode: String?
    public let newMode: String?
    public let oldBlobShortOID: String?
    public let newBlobShortOID: String?
    public let similarityPercent: Int?
    public let isBinary: Bool
    public let binaryNotice: String?
    public let additionsCount: Int
    public let deletionsCount: Int
    public let hunks: [ParsedDiffHunk]

    public init(
        oldPath: String?,
        newPath: String?,
        changeKind: GitDiffChangeKind,
        oldMode: String? = nil,
        newMode: String? = nil,
        oldBlobShortOID: String? = nil,
        newBlobShortOID: String? = nil,
        similarityPercent: Int? = nil,
        isBinary: Bool = false,
        binaryNotice: String? = nil,
        additionsCount: Int = 0,
        deletionsCount: Int = 0,
        hunks: [ParsedDiffHunk] = []
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.changeKind = changeKind
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldBlobShortOID = oldBlobShortOID
        self.newBlobShortOID = newBlobShortOID
        self.similarityPercent = similarityPercent
        self.isBinary = isBinary
        self.binaryNotice = binaryNotice
        self.additionsCount = additionsCount
        self.deletionsCount = deletionsCount
        self.hunks = hunks
    }

    public var displayPath: String {
        newPath ?? oldPath ?? "<unknown>"
    }

    public var allUnifiedRows: [UnifiedDiffRow] {
        hunks.flatMap(\.unifiedRows)
    }

    public var allSplitRows: [SplitDiffRow] {
        hunks.flatMap(\.splitRows)
    }
}

public struct ParsedGitPatchSet: Sendable, Codable, Hashable {
    public let files: [ParsedGitFileDiff]
    public let totalAdditions: Int
    public let totalDeletions: Int
    public let binaryFileCount: Int
    public let renamedFileCount: Int

    public init(files: [ParsedGitFileDiff]) {
        self.files = files
        self.totalAdditions = files.reduce(0) { $0 + $1.additionsCount }
        self.totalDeletions = files.reduce(0) { $0 + $1.deletionsCount }
        self.binaryFileCount = files.filter(\.isBinary).count
        self.renamedFileCount = files.filter { $0.changeKind == .renamed }.count
    }
}

// MARK: - Intraline Character & Lexical Token Highlight Engine

public struct DiffIntralineHighlighter: Sendable {
    public var maxTokensForExactLCS: Int
    public var minimumSimilarityForPairing: Double

    public init(maxTokensForExactLCS: Int = 512, minimumSimilarityForPairing: Double = 0.20) {
        self.maxTokensForExactLCS = max(64, maxTokensForExactLCS)
        self.minimumSimilarityForPairing = min(0.95, max(0.0, minimumSimilarityForPairing))
    }

    /// Computes intraline deletion & insertion highlight spans for a paired `(oldLine, newLine)` edit.
    public func computeHighlightSpans(
        oldLine: String,
        newLine: String
    ) -> (oldSpans: [DiffIntralineHighlightSpan], newSpans: [DiffIntralineHighlightSpan], similarity: Double) {
        if oldLine == newLine {
            return ([], [], 1.0)
        }
        if oldLine.isEmpty && !newLine.isEmpty {
            return ([], [DiffIntralineHighlightSpan(startCharOffset: 0, endCharOffset: newLine.count, emphasis: .insertedToken)], 0.0)
        }
        if !oldLine.isEmpty && newLine.isEmpty {
            return ([DiffIntralineHighlightSpan(startCharOffset: 0, endCharOffset: oldLine.count, emphasis: .deletedToken)], [], 0.0)
        }

        let oldTokens = Self.tokenizeWithCharOffsets(oldLine)
        let newTokens = Self.tokenizeWithCharOffsets(newLine)

        // Fast prefix/suffix trim when token count exceeds quadratic LCS cap
        if oldTokens.count > maxTokensForExactLCS || newTokens.count > maxTokensForExactLCS {
            return computePrefixSuffixFallback(oldLine: oldLine, newLine: newLine)
        }

        let m = oldTokens.count
        let n = newTokens.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in stride(from: m - 1, through: 0, by: -1) {
            let lhsText = oldTokens[i].text
            for j in stride(from: n - 1, through: 0, by: -1) {
                if lhsText == newTokens[j].text {
                    dp[i][j] = 1 + dp[i + 1][j + 1]
                } else {
                    let down = dp[i + 1][j]
                    let right = dp[i][j + 1]
                    dp[i][j] = down >= right ? down : right
                }
            }
        }

        var matchedOldIndices = Set<Int>()
        var matchedNewIndices = Set<Int>()
        var matchedChars = 0
        var i = 0
        var j = 0
        while i < m && j < n {
            if oldTokens[i].text == newTokens[j].text {
                matchedOldIndices.insert(i)
                matchedNewIndices.insert(j)
                matchedChars += oldTokens[i].length
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        let totalChars = max(1, oldLine.count + newLine.count)
        let similarity = Double(2 * matchedChars) / Double(totalChars)

        // When lines are almost completely unrelated, avoid peppering random single-space matches
        if similarity < minimumSimilarityForPairing {
            return (
                [DiffIntralineHighlightSpan(startCharOffset: 0, endCharOffset: oldLine.count, emphasis: .deletedToken)],
                [DiffIntralineHighlightSpan(startCharOffset: 0, endCharOffset: newLine.count, emphasis: .insertedToken)],
                similarity
            )
        }

        let rawOldSpans = buildCoalescedSpans(
            tokens: oldTokens,
            matchedIndices: matchedOldIndices,
            emphasis: .deletedToken
        )
        let rawNewSpans = buildCoalescedSpans(
            tokens: newTokens,
            matchedIndices: matchedNewIndices,
            emphasis: .insertedToken
        )

        return (rawOldSpans, rawNewSpans, similarity)
    }

    // MARK: - Tokenization & Span Coalescing

    private struct OffsetToken {
        let text: String
        let startChar: Int
        let endChar: Int
        let isWhitespace: Bool

        var length: Int { endChar - startChar }
    }

    private enum TokenClass {
        case identifierOrNumber
        case whitespace
        case punctuation
    }

    private static func classifyCharacter(_ ch: Character) -> TokenClass {
        if ch.isWhitespace { return .whitespace }
        if ch.isLetter || ch.isNumber || ch == "_" { return .identifierOrNumber }
        return .punctuation
    }

    private static func tokenizeWithCharOffsets(_ line: String) -> [OffsetToken] {
        guard !line.isEmpty else { return [] }
        let chars = Array(line)
        var tokens: [OffsetToken] = []
        tokens.reserveCapacity(chars.count / 2 + 1)

        var idx = 0
        while idx < chars.count {
            let start = idx
            let cls = classifyCharacter(chars[idx])
            switch cls {
            case .identifierOrNumber, .whitespace:
                idx += 1
                while idx < chars.count && classifyCharacter(chars[idx]) == cls {
                    idx += 1
                }
            case .punctuation:
                // Keep punctuation characters granular so `foo(a)` -> `foo(a, b)` highlights `, b` cleanly
                idx += 1
            }
            let slice = String(chars[start..<idx])
            tokens.append(
                OffsetToken(
                    text: slice,
                    startChar: start,
                    endChar: idx,
                    isWhitespace: cls == .whitespace
                )
            )
        }
        return tokens
    }

    private func buildCoalescedSpans(
        tokens: [OffsetToken],
        matchedIndices: Set<Int>,
        emphasis: DiffHighlightEmphasis
    ) -> [DiffIntralineHighlightSpan] {
        var raw: [DiffIntralineHighlightSpan] = []
        var idx = 0
        while idx < tokens.count {
            if matchedIndices.contains(idx) {
                idx += 1
                continue
            }
            let startChar = tokens[idx].startChar
            var endChar = tokens[idx].endChar
            idx += 1
            while idx < tokens.count {
                if !matchedIndices.contains(idx) {
                    endChar = tokens[idx].endChar
                    idx += 1
                } else if tokens[idx].isWhitespace && idx + 1 < tokens.count && !matchedIndices.contains(idx + 1) && tokens[idx].length <= 2 {
                    // Bridge tiny single-space gaps between two adjacent modified tokens
                    endChar = tokens[idx + 1].endChar
                    idx += 2
                } else {
                    break
                }
            }
            raw.append(DiffIntralineHighlightSpan(startCharOffset: startChar, endCharOffset: endChar, emphasis: emphasis))
        }
        return raw
    }

    private func computePrefixSuffixFallback(
        oldLine: String,
        newLine: String
    ) -> (oldSpans: [DiffIntralineHighlightSpan], newSpans: [DiffIntralineHighlightSpan], similarity: Double) {
        let oldChars = Array(oldLine)
        let newChars = Array(newLine)
        let minLen = min(oldChars.count, newChars.count)

        var prefix = 0
        while prefix < minLen && oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < (minLen - prefix)
            && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let oldEnd = oldChars.count - suffix
        let newEnd = newChars.count - suffix
        let oldSpans = prefix < oldEnd
            ? [DiffIntralineHighlightSpan(startCharOffset: prefix, endCharOffset: oldEnd, emphasis: .deletedToken)]
            : []
        let newSpans = prefix < newEnd
            ? [DiffIntralineHighlightSpan(startCharOffset: prefix, endCharOffset: newEnd, emphasis: .insertedToken)]
            : []
        let sim = Double(2 * (prefix + suffix)) / Double(max(1, oldChars.count + newChars.count))
        return (oldSpans, newSpans, sim)
    }
}

// MARK: - Complete Git Unified & Side-by-Side Split Diff Parser

public struct UnifiedAndSplitDiffParser: Sendable {
    public let intralineHighlighter: DiffIntralineHighlighter

    public init(intralineHighlighter: DiffIntralineHighlighter = DiffIntralineHighlighter()) {
        self.intralineHighlighter = intralineHighlighter
    }

    /// Parses full `git diff` / `git show` unified patch text into structured Unified + Side-by-Side Split diffs.
    public func parsePatch(_ rawPatch: String) -> ParsedGitPatchSet {
        guard !rawPatch.isEmpty else {
            return ParsedGitPatchSet(files: [])
        }

        let normalized = rawPatch.replacingOccurrences(of: "\r\n", with: "\n")
        var rawLines = normalized.components(separatedBy: "\n")
        if rawLines.last == "" {
            rawLines.removeLast()
        }

        var files: [ParsedGitFileDiff] = []
        var idx = 0

        // Skip optional commit preamble before first `diff --git` or `--- `
        while idx < rawLines.count && !rawLines[idx].hasPrefix("diff --git ") && !rawLines[idx].hasPrefix("--- ") {
            idx += 1
        }

        while idx < rawLines.count {
            let (parsedFile, nextIdx) = parseSingleFileSection(lines: rawLines, startIndex: idx)
            if let fileDiff = parsedFile {
                files.append(fileDiff)
            }
            if nextIdx <= idx {
                idx += 1
            } else {
                idx = nextIdx
            }
        }

        return ParsedGitPatchSet(files: files)
    }

    /// Extracts a valid standalone `git apply` unified patch containing only the specified `hunkIndices` of `fileDiff`.
    public func extractStageableSubPatch(
        from fileDiff: ParsedGitFileDiff,
        hunkIndices: Set<Int>
    ) -> String? {
        let selectedHunks = fileDiff.hunks.filter { hunkIndices.contains($0.hunkIndex) }
        guard !selectedHunks.isEmpty, !fileDiff.isBinary else { return nil }

        let oldP = fileDiff.oldPath ?? fileDiff.displayPath
        let newP = fileDiff.newPath ?? fileDiff.displayPath
        var patchLines: [String] = []
        patchLines.append("diff --git a/\(oldP) b/\(newP)")
        patchLines.append("--- \(fileDiff.oldPath == nil ? "/dev/null" : "a/\(oldP)")")
        patchLines.append("+++ \(fileDiff.newPath == nil ? "/dev/null" : "b/\(newP)")")

        for hunk in selectedHunks {
            patchLines.append(hunk.rawHeaderLine)
            for row in hunk.unifiedRows where row.kind != .hunkHeader {
                switch row.kind {
                case .context:
                    patchLines.append(" \(row.content)")
                case .deletion:
                    patchLines.append("-\(row.content)")
                case .addition:
                    patchLines.append("+\(row.content)")
                case .noNewlineNotice:
                    patchLines.append("\\ No newline at end of file")
                case .hunkHeader:
                    break
                }
            }
        }
        return patchLines.joined(separator: "\n") + "\n"
    }

    // MARK: - File Header & Hunk State Machine

    private func parseSingleFileSection(
        lines: [String],
        startIndex: Int
    ) -> (ParsedGitFileDiff?, Int) {
        var idx = startIndex
        var oldPath: String?
        var newPath: String?
        var oldMode: String?
        var newMode: String?
        var oldBlob: String?
        var newBlob: String?
        var similarity: Int?
        var explicitKind: GitDiffChangeKind?
        var isBinary = false
        var binaryNotice: String?

        if lines[idx].hasPrefix("diff --git ") {
            let (pOld, pNew) = Self.parseDiffGitHeaderPaths(lines[idx])
            oldPath = pOld
            newPath = pNew
            idx += 1
        }

        // Parse extended header lines up to first `@@ ` or next `diff --git `
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@ ") {
                break
            }

            if line.hasPrefix("old mode ") {
                oldMode = String(line.dropFirst("old mode ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("new mode ") {
                newMode = String(line.dropFirst("new mode ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("new file mode ") {
                newMode = String(line.dropFirst("new file mode ".count)).trimmingCharacters(in: .whitespaces)
                explicitKind = .added
            } else if line.hasPrefix("deleted file mode ") {
                oldMode = String(line.dropFirst("deleted file mode ".count)).trimmingCharacters(in: .whitespaces)
                explicitKind = .deleted
            } else if line.hasPrefix("similarity index ") {
                let digits = line.dropFirst("similarity index ".count).trimmingCharacters(in: CharacterSet(charactersIn: "% "))
                similarity = Int(digits)
            } else if line.hasPrefix("rename from ") {
                oldPath = Self.unquoteGitPath(String(line.dropFirst("rename from ".count)))
                explicitKind = .renamed
            } else if line.hasPrefix("rename to ") {
                newPath = Self.unquoteGitPath(String(line.dropFirst("rename to ".count)))
                explicitKind = .renamed
            } else if line.hasPrefix("copy from ") {
                oldPath = Self.unquoteGitPath(String(line.dropFirst("copy from ".count)))
                explicitKind = .copied
            } else if line.hasPrefix("copy to ") {
                newPath = Self.unquoteGitPath(String(line.dropFirst("copy to ".count)))
                explicitKind = .copied
            } else if line.hasPrefix("index ") {
                let rest = String(line.dropFirst("index ".count))
                let parts = rest.split(separator: " ")
                if let rangeToken = parts.first, let dots = rangeToken.range(of: "..") {
                    oldBlob = String(rangeToken[..<dots.lowerBound])
                    newBlob = String(rangeToken[dots.upperBound...])
                }
                if parts.count >= 2 && newMode == nil {
                    let modeCandidate = String(parts[1])
                    oldMode = oldMode ?? modeCandidate
                    newMode = modeCandidate
                }
            } else if line.hasPrefix("Binary files ") {
                isBinary = true
                binaryNotice = line
                explicitKind = .binaryModified
            } else if line == "GIT binary patch" {
                isBinary = true
                binaryNotice = "GIT binary patch"
                explicitKind = .binaryModified
                idx += 1
                // Advance past base85 binary payload lines until next `diff --git `
                while idx < lines.count && !lines[idx].hasPrefix("diff --git ") {
                    idx += 1
                }
                break
            } else if line.hasPrefix("--- ") {
                let parsed = Self.parseMinusPlusMarkerPath(String(line.dropFirst(4)), prefixToStrip: "a/")
                if parsed == nil {
                    oldPath = nil
                    if explicitKind == nil { explicitKind = .added }
                } else {
                    oldPath = parsed
                }
            } else if line.hasPrefix("+++ ") {
                let parsed = Self.parseMinusPlusMarkerPath(String(line.dropFirst(4)), prefixToStrip: "b/")
                if parsed == nil {
                    newPath = nil
                    if explicitKind == nil { explicitKind = .deleted }
                } else {
                    newPath = parsed
                }
            }

            idx += 1
        }

        // Parse all `@@ ... @@` hunks belonging to this file
        var hunks: [ParsedDiffHunk] = []
        var prevOldEndExclusive = 1
        var prevNewEndExclusive = 1

        while idx < lines.count && lines[idx].hasPrefix("@@ ") {
            let hunkIdx = hunks.count
            let (parsedHunk, nextLineIdx) = parseSingleHunk(
                lines: lines,
                startIndex: idx,
                hunkIndex: hunkIdx,
                previousOldEndLine: prevOldEndExclusive,
                previousNewEndLine: prevNewEndExclusive
            )
            if let h = parsedHunk {
                prevOldEndExclusive = h.oldStart + max(0, h.oldCount)
                prevNewEndExclusive = h.newStart + max(0, h.newCount)
                hunks.append(h)
            }
            idx = nextLineIdx
        }

        let totalAdds = hunks.reduce(0) { $0 + $1.additionsCount }
        let totalDels = hunks.reduce(0) { $0 + $1.deletionsCount }

        let resolvedKind: GitDiffChangeKind
        if let ek = explicitKind {
            resolvedKind = ek
        } else if isBinary {
            resolvedKind = .binaryModified
        } else if oldMode != newMode && hunks.isEmpty {
            resolvedKind = .modeChanged
        } else {
            resolvedKind = .modified
        }

        if oldPath == nil && newPath == nil && hunks.isEmpty && !isBinary {
            return (nil, idx)
        }

        let fileDiff = ParsedGitFileDiff(
            oldPath: oldPath,
            newPath: newPath,
            changeKind: resolvedKind,
            oldMode: oldMode,
            newMode: newMode,
            oldBlobShortOID: oldBlob,
            newBlobShortOID: newBlob,
            similarityPercent: similarity,
            isBinary: isBinary,
            binaryNotice: binaryNotice,
            additionsCount: totalAdds,
            deletionsCount: totalDels,
            hunks: hunks
        )
        return (fileDiff, idx)
    }

    private enum RawHunkEntryKind {
        case context
        case deletion
        case addition
        case noNewlineNotice
    }

    private struct RawHunkEntry {
        let kind: RawHunkEntryKind
        let oldLine: Int?
        let newLine: Int?
        let text: String
        var missingNewline: Bool = false
    }

    private func parseSingleHunk(
        lines: [String],
        startIndex: Int,
        hunkIndex: Int,
        previousOldEndLine: Int,
        previousNewEndLine: Int
    ) -> (ParsedDiffHunk?, Int) {
        let headerLine = lines[startIndex]
        guard let hdr = Self.parseHunkHeader(headerLine) else {
            return (nil, startIndex + 1)
        }

        var rawEntries: [RawHunkEntry] = []
        var curOld = hdr.oldStart
        var curNew = hdr.newStart
        var adds = 0
        var dels = 0
        var lastSide: RawHunkEntryKind?

        var idx = startIndex + 1
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@ ") {
                break
            }

            if line.hasPrefix("\\ ") {
                // `\ No newline at end of file` applies to the immediately preceding side(s)
                if !rawEntries.isEmpty {
                    if lastSide == .context {
                        rawEntries[rawEntries.count - 1].missingNewline = true
                    } else if let side = lastSide {
                        // Walk back to mark the last entry of `side`
                        for back in stride(from: rawEntries.count - 1, through: 0, by: -1) {
                            if rawEntries[back].kind == side {
                                rawEntries[back].missingNewline = true
                                break
                            }
                        }
                    }
                }
                rawEntries.append(
                    RawHunkEntry(kind: .noNewlineNotice, oldLine: nil, newLine: nil, text: String(line.dropFirst(2)))
                )
                idx += 1
                continue
            }

            guard let prefixChar = line.first else {
                // Treat completely empty line inside hunk as blank context line (common when editors strip trailing space)
                rawEntries.append(RawHunkEntry(kind: .context, oldLine: curOld, newLine: curNew, text: ""))
                curOld += 1
                curNew += 1
                lastSide = .context
                idx += 1
                continue
            }

            let body = String(line.dropFirst())
            switch prefixChar {
            case " ":
                rawEntries.append(RawHunkEntry(kind: .context, oldLine: curOld, newLine: curNew, text: body))
                curOld += 1
                curNew += 1
                lastSide = .context
            case "-":
                rawEntries.append(RawHunkEntry(kind: .deletion, oldLine: curOld, newLine: nil, text: body))
                curOld += 1
                dels += 1
                lastSide = .deletion
            case "+":
                rawEntries.append(RawHunkEntry(kind: .addition, oldLine: nil, newLine: curNew, text: body))
                curNew += 1
                adds += 1
                lastSide = .addition
            default:
                // Unexpected non-diff line terminates hunk
                return finalizeHunk(
                    hunkIndex: hunkIndex,
                    rawHeaderLine: headerLine,
                    header: hdr,
                    entries: rawEntries,
                    adds: adds,
                    dels: dels,
                    previousOldEndLine: previousOldEndLine,
                    previousNewEndLine: previousNewEndLine,
                    nextIndex: idx
                )
            }

            idx += 1
        }

        return finalizeHunk(
            hunkIndex: hunkIndex,
            rawHeaderLine: headerLine,
            header: hdr,
            entries: rawEntries,
            adds: adds,
            dels: dels,
            previousOldEndLine: previousOldEndLine,
            previousNewEndLine: previousNewEndLine,
            nextIndex: idx
        )
    }

    private func finalizeHunk(
        hunkIndex: Int,
        rawHeaderLine: String,
        header: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String),
        entries: [RawHunkEntry],
        adds: Int,
        dels: Int,
        previousOldEndLine: Int,
        previousNewEndLine: Int,
        nextIndex: Int
    ) -> (ParsedDiffHunk?, Int) {
        // Compute expandable gap above this hunk if hidden context lines exist
        let expandableGap: SplitDiffExpandableGap?
        let hiddenOld = header.oldStart - previousOldEndLine
        let hiddenNew = header.newStart - previousNewEndLine
        if hiddenOld > 0 && hiddenNew > 0 {
            expandableGap = SplitDiffExpandableGap(
                hiddenLineCount: min(hiddenOld, hiddenNew),
                oldLineRange: previousOldEndLine...(header.oldStart - 1),
                newLineRange: previousNewEndLine...(header.newStart - 1)
            )
        } else {
            expandableGap = nil
        }

        var unifiedRows: [UnifiedDiffRow] = [
            UnifiedDiffRow(
                hunkIndex: hunkIndex,
                rowIndexInHunk: 0,
                kind: .hunkHeader,
                content: rawHeaderLine
            )
        ]
        var splitRows: [SplitDiffRow] = [
            SplitDiffRow(
                hunkIndex: hunkIndex,
                splitRowIndex: 0,
                kind: .hunkHeader,
                hunkHeaderSummary: rawHeaderLine,
                expandableGap: expandableGap
            )
        ]

        // Walk `entries`, pairing contiguous `deletion*` + `addition*` blocks for intraline highlighting & side-by-side layout!
        var pos = 0
        while pos < entries.count {
            let entry = entries[pos]
            switch entry.kind {
            case .context:
                unifiedRows.append(
                    UnifiedDiffRow(
                        hunkIndex: hunkIndex,
                        rowIndexInHunk: unifiedRows.count,
                        kind: .context,
                        oldLineNumber: entry.oldLine,
                        newLineNumber: entry.newLine,
                        content: entry.text,
                        missingTrailingNewline: entry.missingNewline
                    )
                )
                splitRows.append(
                    SplitDiffRow(
                        hunkIndex: hunkIndex,
                        splitRowIndex: splitRows.count,
                        kind: .contextPair,
                        leftCell: SplitDiffPaneCell(
                            lineNumber: entry.oldLine ?? 0,
                            kind: .context,
                            content: entry.text,
                            missingTrailingNewline: entry.missingNewline
                        ),
                        rightCell: SplitDiffPaneCell(
                            lineNumber: entry.newLine ?? 0,
                            kind: .context,
                            content: entry.text,
                            missingTrailingNewline: entry.missingNewline
                        ),
                        pairSimilarityScore: 1.0
                    )
                )
                pos += 1

            case .noNewlineNotice:
                unifiedRows.append(
                    UnifiedDiffRow(
                        hunkIndex: hunkIndex,
                        rowIndexInHunk: unifiedRows.count,
                        kind: .noNewlineNotice,
                        content: entry.text
                    )
                )
                pos += 1

            case .deletion, .addition:
                // Collect contiguous run of deletions and additions (skipping embedded `\ No newline` notices while preserving them for unified output)
                var delRun: [RawHunkEntry] = []
                var addRun: [RawHunkEntry] = []
                var delNotices: [RawHunkEntry] = []
                var addNotices: [RawHunkEntry] = []

                while pos < entries.count && (entries[pos].kind == .deletion || (entries[pos].kind == .noNewlineNotice && addRun.isEmpty)) {
                    if entries[pos].kind == .deletion {
                        delRun.append(entries[pos])
                    } else {
                        delNotices.append(entries[pos])
                    }
                    pos += 1
                }
                while pos < entries.count && (entries[pos].kind == .addition || entries[pos].kind == .noNewlineNotice) {
                    if entries[pos].kind == .addition {
                        addRun.append(entries[pos])
                    } else {
                        addNotices.append(entries[pos])
                    }
                    pos += 1
                }

                let pairCount = min(delRun.count, addRun.count)
                var delSpansByIdx: [[DiffIntralineHighlightSpan]] = Array(repeating: [], count: delRun.count)
                var addSpansByIdx: [[DiffIntralineHighlightSpan]] = Array(repeating: [], count: addRun.count)
                var simByIdx: [Double] = Array(repeating: 0.0, count: pairCount)

                for pIdx in 0..<pairCount {
                    let (oSpans, nSpans, sim) = intralineHighlighter.computeHighlightSpans(
                        oldLine: delRun[pIdx].text,
                        newLine: addRun[pIdx].text
                    )
                    delSpansByIdx[pIdx] = oSpans
                    addSpansByIdx[pIdx] = nSpans
                    simByIdx[pIdx] = sim
                }

                // Append Unified Rows (`-` block then `+` block, matching standard unified order, enriched with intraline spans!)
                for (dIdx, dEntry) in delRun.enumerated() {
                    unifiedRows.append(
                        UnifiedDiffRow(
                            hunkIndex: hunkIndex,
                            rowIndexInHunk: unifiedRows.count,
                            kind: .deletion,
                            oldLineNumber: dEntry.oldLine,
                            content: dEntry.text,
                            intralineSpans: delSpansByIdx[dIdx],
                            missingTrailingNewline: dEntry.missingNewline
                        )
                    )
                }
                for notice in delNotices {
                    unifiedRows.append(
                        UnifiedDiffRow(
                            hunkIndex: hunkIndex,
                            rowIndexInHunk: unifiedRows.count,
                            kind: .noNewlineNotice,
                            content: notice.text
                        )
                    )
                }
                for (aIdx, aEntry) in addRun.enumerated() {
                    unifiedRows.append(
                        UnifiedDiffRow(
                            hunkIndex: hunkIndex,
                            rowIndexInHunk: unifiedRows.count,
                            kind: .addition,
                            newLineNumber: aEntry.newLine,
                            content: aEntry.text,
                            intralineSpans: addSpansByIdx[aIdx],
                            missingTrailingNewline: aEntry.missingNewline
                        )
                    )
                }
                for notice in addNotices {
                    unifiedRows.append(
                        UnifiedDiffRow(
                            hunkIndex: hunkIndex,
                            rowIndexInHunk: unifiedRows.count,
                            kind: .noNewlineNotice,
                            content: notice.text
                        )
                    )
                }

                // Append Side-by-Side Split Rows
                let maxRows = max(delRun.count, addRun.count)
                for rIdx in 0..<maxRows {
                    let hasDel = rIdx < delRun.count
                    let hasAdd = rIdx < addRun.count

                    if hasDel && hasAdd {
                        let d = delRun[rIdx]
                        let a = addRun[rIdx]
                        splitRows.append(
                            SplitDiffRow(
                                hunkIndex: hunkIndex,
                                splitRowIndex: splitRows.count,
                                kind: .modifiedPair,
                                leftCell: SplitDiffPaneCell(
                                    lineNumber: d.oldLine ?? 0,
                                    kind: .pairedDeletion,
                                    content: d.text,
                                    intralineSpans: delSpansByIdx[rIdx],
                                    missingTrailingNewline: d.missingNewline
                                ),
                                rightCell: SplitDiffPaneCell(
                                    lineNumber: a.newLine ?? 0,
                                    kind: .pairedAddition,
                                    content: a.text,
                                    intralineSpans: addSpansByIdx[rIdx],
                                    missingTrailingNewline: a.missingNewline
                                ),
                                pairSimilarityScore: simByIdx[rIdx]
                            )
                        )
                    } else if hasDel {
                        let d = delRun[rIdx]
                        splitRows.append(
                            SplitDiffRow(
                                hunkIndex: hunkIndex,
                                splitRowIndex: splitRows.count,
                                kind: .deletionOnly,
                                leftCell: SplitDiffPaneCell(
                                    lineNumber: d.oldLine ?? 0,
                                    kind: .pureDeletion,
                                    content: d.text,
                                    missingTrailingNewline: d.missingNewline
                                ),
                                rightCell: nil
                            )
                        )
                    } else if hasAdd {
                        let a = addRun[rIdx]
                        splitRows.append(
                            SplitDiffRow(
                                hunkIndex: hunkIndex,
                                splitRowIndex: splitRows.count,
                                kind: .additionOnly,
                                leftCell: nil,
                                rightCell: SplitDiffPaneCell(
                                    lineNumber: a.newLine ?? 0,
                                    kind: .pureAddition,
                                    content: a.text,
                                    missingTrailingNewline: a.missingNewline
                                )
                            )
                        )
                    }
                }
            }
        }

        let hunk = ParsedDiffHunk(
            hunkIndex: hunkIndex,
            rawHeaderLine: rawHeaderLine,
            sectionHeading: header.heading,
            oldStart: header.oldStart,
            oldCount: header.oldCount,
            newStart: header.newStart,
            newCount: header.newCount,
            additionsCount: adds,
            deletionsCount: dels,
            unifiedRows: unifiedRows,
            splitRows: splitRows
        )
        return (hunk, nextIndex)
    }

    // MARK: - Header & C-Quoted Path Decoders

    private static func parseHunkHeader(
        _ line: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)? {
        let pattern = #"^@@\s+-([0-9]+)(?:,([0-9]+))?\s+\+([0-9]+)(?:,([0-9]+))?\s+@@(?:\s?(.*))?$"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 5 else {
            return nil
        }

        let oldStart = Int(ns.substring(with: m.range(at: 1))) ?? 1
        let oldCount = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 1) : 1
        let newStart = Int(ns.substring(with: m.range(at: 3))) ?? 1
        let newCount = m.range(at: 4).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 4))) ?? 1) : 1
        let heading: String
        if m.numberOfRanges >= 6 && m.range(at: 5).location != NSNotFound {
            heading = ns.substring(with: m.range(at: 5))
        } else {
            heading = ""
        }
        return (oldStart, oldCount, newStart, newCount, heading)
    }

    private static func parseDiffGitHeaderPaths(_ line: String) -> (String?, String?) {
        let body = String(line.dropFirst("diff --git ".count)).trimmingCharacters(in: .whitespaces)
        // Quoted paths: `"a/..." "b/..."`
        if body.hasPrefix("\"") {
            let tokens = splitQuotedPair(body)
            if tokens.count == 2 {
                let p0 = stripPrefixIfPresent(unquoteGitPath(tokens[0]), prefix: "a/")
                let p1 = stripPrefixIfPresent(unquoteGitPath(tokens[1]), prefix: "b/")
                return (p0, p1)
            }
        }

        // Unquoted `a/foo/bar b/foo/bar` (handle spaces inside path by locating ` b/`)
        if body.hasPrefix("a/"), let bMarker = body.range(of: " b/", options: .backwards) {
            let left = String(body[..<bMarker.lowerBound].dropFirst(2))
            let right = String(body[bMarker.upperBound...])
            return (left, right)
        }

        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (nil, nil) }
        return (
            stripPrefixIfPresent(parts[0], prefix: "a/"),
            stripPrefixIfPresent(parts[1], prefix: "b/")
        )
    }

    private static func parseMinusPlusMarkerPath(_ raw: String, prefixToStrip: String) -> String? {
        // Strip optional trailing tab timestamp e.g. `a/file.swift\t2026-11-13 08:00:00`
        let withoutTab: String
        if !raw.hasPrefix("\""), let tabIdx = raw.firstIndex(of: "\t") {
            withoutTab = String(raw[..<tabIdx])
        } else {
            withoutTab = raw
        }
        let unquoted = unquoteGitPath(withoutTab.trimmingCharacters(in: .whitespaces))
        if unquoted == "/dev/null" {
            return nil
        }
        return stripPrefixIfPresent(unquoted, prefix: prefixToStrip)
    }

    private static func stripPrefixIfPresent(_ text: String, prefix: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    private static func splitQuotedPair(_ input: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            if chars[i] == "\"" {
                let start = i
                i += 1
                var escaped = false
                while i < chars.count {
                    if escaped {
                        escaped = false
                    } else if chars[i] == "\\" {
                        escaped = true
                    } else if chars[i] == "\"" {
                        i += 1
                        break
                    }
                    i += 1
                }
                tokens.append(String(chars[start..<i]))
            } else {
                let start = i
                while i < chars.count && !chars[i].isWhitespace { i += 1 }
                tokens.append(String(chars[start..<i]))
            }
        }
        return tokens
    }

    /// Decodes Git C-escaped quoted filenames (`"a/Docs/\344\270\255\346\226\207.md"` -> `a/Docs/中文.md`).
    public static func unquoteGitPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") else {
            return trimmed
        }
        let inner = Array(trimmed.dropFirst().dropLast())
        var bytes: [UInt8] = []
        bytes.reserveCapacity(inner.count)

        var i = 0
        while i < inner.count {
            let ch = inner[i]
            if ch != "\\" || i + 1 >= inner.count {
                bytes.append(contentsOf: String(ch).utf8)
                i += 1
                continue
            }

            let next = inner[i + 1]
            // 3-digit octal UTF-8 byte escape (`\000`..`\377`)
            if next >= "0" && next <= "7" {
                var octDigits = String(next)
                var advance = 2
                if i + 2 < inner.count && inner[i + 2] >= "0" && inner[i + 2] <= "7" {
                    octDigits.append(inner[i + 2])
                    advance = 3
                    if i + 3 < inner.count && inner[i + 3] >= "0" && inner[i + 3] <= "7" {
                        octDigits.append(inner[i + 3])
                        advance = 4
                    }
                }
                if let byteVal = UInt8(octDigits, radix: 8) {
                    bytes.append(byteVal)
                    i += advance
                    continue
                }
            }

            switch next {
            case "n":  bytes.append(0x0A)
            case "r":  bytes.append(0x0D)
            case "t":  bytes.append(0x09)
            case "b":  bytes.append(0x08)
            case "f":  bytes.append(0x0C)
            case "\"": bytes.append(0x22)
            case "\\": bytes.append(0x5C)
            default:   bytes.append(contentsOf: String(next).utf8)
            }
            i += 2
        }

        return String(decoding: bytes, as: UTF8.self)
    }
}
