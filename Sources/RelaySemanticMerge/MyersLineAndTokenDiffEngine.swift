import Foundation
import RelayModels

// MARK: - Eugene Myers O(ND) Shortest-Edit-Script & Patience Diff Primitives

public enum MyersEditKind: String, Sendable, Codable, Hashable {
    case equal
    case delete
    case insert
}

public struct MyersEditStep<Element: Sendable & Equatable>: Sendable, Equatable {
    public let kind: MyersEditKind
    public let oldIndex: Int?
    public let newIndex: Int?
    public let element: Element

    public init(kind: MyersEditKind, oldIndex: Int?, newIndex: Int?, element: Element) {
        self.kind = kind
        self.oldIndex = oldIndex
        self.newIndex = newIndex
        self.element = element
    }
}

extension MyersEditStep: Codable where Element: Codable {}
extension MyersEditStep: Hashable where Element: Hashable {}

public struct MyersHunkLine: Sendable, Codable, Hashable {
    public let kind: MyersEditKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(kind: MyersEditKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct MyersCoalescedHunk: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "@@ -\(oldStartLine),\(oldLineCount) +\(newStartLine),\(newLineCount) @@" }
    public let oldStartLine: Int
    public let oldLineCount: Int
    public let newStartLine: Int
    public let newLineCount: Int
    public let lines: [MyersHunkLine]

    public init(
        oldStartLine: Int,
        oldLineCount: Int,
        newStartLine: Int,
        newLineCount: Int,
        lines: [MyersHunkLine]
    ) {
        self.oldStartLine = oldStartLine
        self.oldLineCount = oldLineCount
        self.newStartLine = newStartLine
        self.newLineCount = newLineCount
        self.lines = lines
    }

    public var unifiedHeader: String {
        "@@ -\(oldStartLine),\(oldLineCount) +\(newStartLine),\(newLineCount) @@"
    }

    public func formatUnifiedText() -> String {
        var out: [String] = [unifiedHeader]
        out.reserveCapacity(lines.count + 1)
        for line in lines {
            switch line.kind {
            case .equal:  out.append(" \(line.text)")
            case .delete: out.append("-\(line.text)")
            case .insert: out.append("+\(line.text)")
            }
        }
        return out.joined(separator: "\n")
    }
}

public enum SourceTokenKind: String, Sendable, Codable, Hashable {
    case identifier
    case numberLiteral
    case stringLiteral
    case comment
    case punctuationOrOperator
    case whitespace
    case newline
}

public struct SourceLexicalToken: Sendable, Codable, Hashable {
    public let kind: SourceTokenKind
    public let text: String
    public let line: Int
    public let column: Int

    public init(kind: SourceTokenKind, text: String, line: Int = 1, column: Int = 1) {
        self.kind = kind
        self.text = text
        self.line = line
        self.column = column
    }

    /// Equality ignores line/column coordinates so Myers token diff compares pure token kind + lexeme!
    public static func == (lhs: SourceLexicalToken, rhs: SourceLexicalToken) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(text)
    }
}

// MARK: - Handwritten Eugene Myers O(ND) + Patience Unique-Anchor Diff Engine

public struct MyersLineAndTokenDiffEngine: Sendable {
    /// Safety cap on edit distance `D` before falling back to prefix/suffix + middle replacement on massive binary-like inputs.
    public var maxExactMyersEditDistance: Int

    public init(maxExactMyersEditDistance: Int = 4_096) {
        self.maxExactMyersEditDistance = max(128, maxExactMyersEditDistance)
    }

    // MARK: - Line Diffing (Myers O(ND) & Patience Unique-Line Anchoring)

    public func diffLines(
        oldText: String,
        newText: String,
        usePatienceAnchoring: Bool = true
    ) -> [MyersEditStep<String>] {
        let oldLines = Self.splitLines(oldText)
        let newLines = Self.splitLines(newText)
        if usePatienceAnchoring {
            return diffElementsPatience(oldLines, newLines)
        }
        return diffElementsMyers(oldLines, newLines)
    }

    public func computeCoalescedHunks(
        oldText: String,
        newText: String,
        contextLines: Int = 3,
        usePatienceAnchoring: Bool = true
    ) -> [MyersCoalescedHunk] {
        let steps = diffLines(oldText: oldText, newText: newText, usePatienceAnchoring: usePatienceAnchoring)
        return coalesceStepsIntoHunks(steps: steps, contextLines: contextLines)
    }

    public func formatUnifiedDiff(
        oldPath: String = "a/file",
        newPath: String = "b/file",
        oldText: String,
        newText: String,
        contextLines: Int = 3,
        usePatienceAnchoring: Bool = true
    ) -> String {
        let hunks = computeCoalescedHunks(
            oldText: oldText,
            newText: newText,
            contextLines: contextLines,
            usePatienceAnchoring: usePatienceAnchoring
        )
        guard !hunks.isEmpty else { return "" }
        var sections: [String] = [
            "--- \(oldPath)",
            "+++ \(newPath)"
        ]
        for h in hunks {
            sections.append(h.formatUnifiedText())
        }
        return sections.joined(separator: "\n") + "\n"
    }

    // MARK: - Lexical Token Diffing

    public func tokenizeSource(_ source: String) -> [SourceLexicalToken] {
        let chars = Array(source)
        var tokens: [SourceLexicalToken] = []
        tokens.reserveCapacity(chars.count / 3 + 1)

        var i = 0
        var line = 1
        var col = 1

        while i < chars.count {
            let startIdx = i
            let startLine = line
            let startCol = col
            let ch = chars[i]

            if ch == "\n" {
                tokens.append(SourceLexicalToken(kind: .newline, text: "\n", line: startLine, column: startCol))
                i += 1
                line += 1
                col = 1
                continue
            }

            if ch == " " || ch == "\t" || ch == "\r" {
                while i < chars.count && (chars[i] == " " || chars[i] == "\t" || chars[i] == "\r") {
                    i += 1
                    col += 1
                }
                tokens.append(SourceLexicalToken(kind: .whitespace, text: String(chars[startIdx..<i]), line: startLine, column: startCol))
                continue
            }

            // Line comments `//` or `#` (when `#` is followed by space or comment text)
            if ch == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" {
                    i += 1
                    col += 1
                }
                tokens.append(SourceLexicalToken(kind: .comment, text: String(chars[startIdx..<i]), line: startLine, column: startCol))
                continue
            }

            // Block comments `/* ... */`
            if ch == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                col += 2
                while i < chars.count {
                    if chars[i] == "\n" {
                        line += 1
                        col = 1
                        i += 1
                    } else if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                        i += 2
                        col += 2
                        break
                    } else {
                        i += 1
                        col += 1
                    }
                }
                tokens.append(SourceLexicalToken(kind: .comment, text: String(chars[startIdx..<i]), line: startLine, column: startCol))
                continue
            }

            // String literals `"..."` or `'...'`
            if ch == "\"" || ch == "'" {
                let quote = ch
                i += 1
                col += 1
                var escaped = false
                while i < chars.count {
                    let cur = chars[i]
                    if cur == "\n" {
                        line += 1
                        col = 1
                        i += 1
                        if !escaped { break }
                        escaped = false
                    } else if escaped {
                        escaped = false
                        i += 1
                        col += 1
                    } else if cur == "\\" {
                        escaped = true
                        i += 1
                        col += 1
                    } else if cur == quote {
                        i += 1
                        col += 1
                        break
                    } else {
                        i += 1
                        col += 1
                    }
                }
                tokens.append(SourceLexicalToken(kind: .stringLiteral, text: String(chars[startIdx..<i]), line: startLine, column: startCol))
                continue
            }

            // Identifiers & keywords
            if ch.isLetter || ch == "_" || ch == "$" {
                i += 1
                col += 1
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                    col += 1
                }
                tokens.append(SourceLexicalToken(kind: .identifier, text: String(chars[startIdx..<i]), line: startLine, column: startCol))
                continue
            }

            // Numeric literals (`42`, `0xFF`, `3.14_15`)
            if ch.isNumber {
                i += 1
                col += 1
                while i < chars.count && (chars[i].isNumber || chars[i].isHexDigit || chars[i] == "." || chars[i] == "_") {
                    i += 1
                    col += 1
                }
                tokens.append(SourceLexicalToken(kind: .numberLiteral, text: String(chars[startIdx..<i]), line: startLine, column: startCol))
                continue
            }

            // Multi-char operators (`==`, `!=`, `->`, `=>`, `<=`, `>=`, `&&`, `||`, `::`)
            if i + 1 < chars.count {
                let two = String([ch, chars[i + 1]])
                let compoundOps: Set<String> = ["==", "!=", "->", "=>", "<=", ">=", "&&", "||", "::", "+=", "-=", "??"]
                if compoundOps.contains(two) {
                    i += 2
                    col += 2
                    tokens.append(SourceLexicalToken(kind: .punctuationOrOperator, text: two, line: startLine, column: startCol))
                    continue
                }
            }

            i += 1
            col += 1
            tokens.append(SourceLexicalToken(kind: .punctuationOrOperator, text: String(ch), line: startLine, column: startCol))
        }

        return tokens
    }

    public func diffTokens(oldSource: String, newSource: String) -> [MyersEditStep<SourceLexicalToken>] {
        let oldTokens = tokenizeSource(oldSource)
        let newTokens = tokenizeSource(newSource)
        return diffElementsPatience(oldTokens, newTokens)
    }

    // MARK: - Core Generic Myers O(ND) Shortest-Edit-Script Algorithm

    public func diffElementsMyers<Element: Sendable & Equatable>(
        _ oldArray: [Element],
        _ newArray: [Element]
    ) -> [MyersEditStep<Element>] {
        diffSliceMyers(
            oldArray: oldArray,
            oldRange: 0..<oldArray.count,
            newArray: newArray,
            newRange: 0..<newArray.count
        )
    }

    // MARK: - Patience Unique-Element Anchored Diff (`O(U log U)` LIS + Recursive Myers)

    public func diffElementsPatience<Element: Sendable & Hashable>(
        _ oldArray: [Element],
        _ newArray: [Element]
    ) -> [MyersEditStep<Element>] {
        diffSlicePatience(
            oldArray: oldArray,
            oldRange: 0..<oldArray.count,
            newArray: newArray,
            newRange: 0..<newArray.count,
            recursionDepth: 0
        )
    }

    private func diffSlicePatience<Element: Sendable & Hashable>(
        oldArray: [Element],
        oldRange: Range<Int>,
        newArray: [Element],
        newRange: Range<Int>,
        recursionDepth: Int
    ) -> [MyersEditStep<Element>] {
        var oStart = oldRange.lowerBound
        var oEnd = oldRange.upperBound
        var nStart = newRange.lowerBound
        var nEnd = newRange.upperBound

        // 1. Trim identical leading elements
        var prefixSteps: [MyersEditStep<Element>] = []
        while oStart < oEnd && nStart < nEnd && oldArray[oStart] == newArray[nStart] {
            prefixSteps.append(MyersEditStep(kind: .equal, oldIndex: oStart, newIndex: nStart, element: oldArray[oStart]))
            oStart += 1
            nStart += 1
        }

        // 2. Trim identical trailing elements
        var suffixStepsReversed: [MyersEditStep<Element>] = []
        while oStart < oEnd && nStart < nEnd && oldArray[oEnd - 1] == newArray[nEnd - 1] {
            oEnd -= 1
            nEnd -= 1
            suffixStepsReversed.append(MyersEditStep(kind: .equal, oldIndex: oEnd, newIndex: nEnd, element: oldArray[oEnd]))
        }

        if oStart == oEnd {
            var res = prefixSteps
            for nIdx in nStart..<nEnd {
                res.append(MyersEditStep(kind: .insert, oldIndex: nil, newIndex: nIdx, element: newArray[nIdx]))
            }
            res.append(contentsOf: suffixStepsReversed.reversed())
            return res
        }
        if nStart == nEnd {
            var res = prefixSteps
            for oIdx in oStart..<oEnd {
                res.append(MyersEditStep(kind: .delete, oldIndex: oIdx, newIndex: nil, element: oldArray[oIdx]))
            }
            res.append(contentsOf: suffixStepsReversed.reversed())
            return res
        }

        // 3. Find unique anchors appearing EXACTLY once in `oldArray[oStart..<oEnd]` AND once in `newArray[nStart..<nEnd]`
        if recursionDepth < 10 {
            let anchors = findPatienceLISAnchors(
                oldArray: oldArray,
                oldRange: oStart..<oEnd,
                newArray: newArray,
                newRange: nStart..<nEnd
            )
            if !anchors.isEmpty {
                var result = prefixSteps
                var curO = oStart
                var curN = nStart

                for (anchorO, anchorN) in anchors {
                    if curO < anchorO || curN < anchorN {
                        let subSteps = diffSlicePatience(
                            oldArray: oldArray,
                            oldRange: curO..<anchorO,
                            newArray: newArray,
                            newRange: curN..<anchorN,
                            recursionDepth: recursionDepth + 1
                        )
                        result.append(contentsOf: subSteps)
                    }
                    result.append(MyersEditStep(kind: .equal, oldIndex: anchorO, newIndex: anchorN, element: oldArray[anchorO]))
                    curO = anchorO + 1
                    curN = anchorN + 1
                }

                if curO < oEnd || curN < nEnd {
                    let tailSteps = diffSlicePatience(
                        oldArray: oldArray,
                        oldRange: curO..<oEnd,
                        newArray: newArray,
                        newRange: curN..<nEnd,
                        recursionDepth: recursionDepth + 1
                    )
                    result.append(contentsOf: tailSteps)
                }

                result.append(contentsOf: suffixStepsReversed.reversed())
                return result
            }
        }

        // 4. Base case: run exact Eugene Myers O(ND) on the unanchored interior
        var result = prefixSteps
        result.append(contentsOf: diffSliceMyers(
            oldArray: oldArray,
            oldRange: oStart..<oEnd,
            newArray: newArray,
            newRange: nStart..<nEnd
        ))
        result.append(contentsOf: suffixStepsReversed.reversed())
        return result
    }

    /// Finds the Longest Increasing Subsequence (LIS) of elements unique in both slices in `O(U log U)` time.
    private func findPatienceLISAnchors<Element: Hashable>(
        oldArray: [Element],
        oldRange: Range<Int>,
        newArray: [Element],
        newRange: Range<Int>
    ) -> [(oldIndex: Int, newIndex: Int)] {
        // Record `-1` if seen more than once, or exact index if seen once
        var oldUniqueIdx: [Element: Int] = [:]
        for idx in oldRange {
            let el = oldArray[idx]
            if oldUniqueIdx[el] == nil {
                oldUniqueIdx[el] = idx
            } else {
                oldUniqueIdx[el] = -1
            }
        }

        var newUniqueIdx: [Element: Int] = [:]
        for idx in newRange {
            let el = newArray[idx]
            if newUniqueIdx[el] == nil {
                newUniqueIdx[el] = idx
            } else {
                newUniqueIdx[el] = -1
            }
        }

        var candidatePairs: [(oldIdx: Int, newIdx: Int)] = []
        for idx in oldRange {
            let el = oldArray[idx]
            if oldUniqueIdx[el] == idx, let nIdx = newUniqueIdx[el], nIdx >= 0 {
                candidatePairs.append((idx, nIdx))
            }
        }
        guard !candidatePairs.isEmpty else { return [] }

        // Patience sorting piles + binary search to extract Longest Increasing Subsequence over `newIdx`
        var pileTopPairIndices: [Int] = [] // stores index into `candidatePairs`
        var predecessor = [Int](repeating: -1, count: candidatePairs.count)

        for pIdx in 0..<candidatePairs.count {
            let targetNew = candidatePairs[pIdx].newIdx
            var lo = 0
            var hi = pileTopPairIndices.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidatePairs[pileTopPairIndices[mid]].newIdx < targetNew {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            if lo > 0 {
                predecessor[pIdx] = pileTopPairIndices[lo - 1]
            }
            if lo == pileTopPairIndices.count {
                pileTopPairIndices.append(pIdx)
            } else {
                pileTopPairIndices[lo] = pIdx
            }
        }

        var lisReversed: [(Int, Int)] = []
        lisReversed.reserveCapacity(pileTopPairIndices.count)
        var walk = pileTopPairIndices.last ?? -1
        while walk >= 0 {
            let pair = candidatePairs[walk]
            lisReversed.append((pair.oldIdx, pair.newIdx))
            walk = predecessor[walk]
        }
        return lisReversed.reversed()
    }

    private func diffSliceMyers<Element: Sendable & Equatable>(
        oldArray: [Element],
        oldRange: Range<Int>,
        newArray: [Element],
        newRange: Range<Int>
    ) -> [MyersEditStep<Element>] {
        var oStart = oldRange.lowerBound
        var oEnd = oldRange.upperBound
        var nStart = newRange.lowerBound
        var nEnd = newRange.upperBound

        var prefix: [MyersEditStep<Element>] = []
        while oStart < oEnd && nStart < nEnd && oldArray[oStart] == newArray[nStart] {
            prefix.append(MyersEditStep(kind: .equal, oldIndex: oStart, newIndex: nStart, element: oldArray[oStart]))
            oStart += 1
            nStart += 1
        }

        var suffixReversed: [MyersEditStep<Element>] = []
        while oStart < oEnd && nStart < nEnd && oldArray[oEnd - 1] == newArray[nEnd - 1] {
            oEnd -= 1
            nEnd -= 1
            suffixReversed.append(MyersEditStep(kind: .equal, oldIndex: oEnd, newIndex: nEnd, element: oldArray[oEnd]))
        }

        let n = oEnd - oStart
        let m = nEnd - nStart

        if n == 0 && m == 0 {
            return prefix + suffixReversed.reversed()
        }
        if n == 0 {
            var out = prefix
            for j in 0..<m {
                let idx = nStart + j
                out.append(MyersEditStep(kind: .insert, oldIndex: nil, newIndex: idx, element: newArray[idx]))
            }
            out.append(contentsOf: suffixReversed.reversed())
            return out
        }
        if m == 0 {
            var out = prefix
            for i in 0..<n {
                let idx = oStart + i
                out.append(MyersEditStep(kind: .delete, oldIndex: idx, newIndex: nil, element: oldArray[idx]))
            }
            out.append(contentsOf: suffixReversed.reversed())
            return out
        }

        let maxD = n + m
        if maxD > maxExactMyersEditDistance {
            // Bounded fallback for gigantic completely divergent blobs
            var out = prefix
            for i in oStart..<oEnd {
                out.append(MyersEditStep(kind: .delete, oldIndex: i, newIndex: nil, element: oldArray[i]))
            }
            for j in nStart..<nEnd {
                out.append(MyersEditStep(kind: .insert, oldIndex: nil, newIndex: j, element: newArray[j]))
            }
            out.append(contentsOf: suffixReversed.reversed())
            return out
        }

        // Myers forward greedy search over diagonal `k = x - y`
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []

        var reachedGoal = false
        for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]       // Downward move (insertion in `newArray`)
                } else {
                    x = v[k - 1 + offset] + 1   // Rightward move (deletion from `oldArray`)
                }
                var y = x - k

                while x < n && y < m && oldArray[oStart + x] == newArray[nStart + y] {
                    x += 1
                    y += 1
                }
                v[k + offset] = x

                if x >= n && y >= m {
                    reachedGoal = true
                    break
                }
                k += 2
            }
            if reachedGoal { break }
        }

        // Backtrack through `trace` from `(n, m)` down to `(0, 0)`
        var middleReversed: [MyersEditStep<Element>] = []
        middleReversed.reserveCapacity(n + m)
        var curX = n
        var curY = m

        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let vSnap = trace[d]
            let k = curX - curY
            let prevK: Int
            if d == 0 {
                prevK = 0
            } else if k == -d || (k != d && vSnap[k - 1 + offset] < vSnap[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }

            let prevX = (d == 0) ? 0 : vSnap[prevK + offset]
            let prevY = prevX - prevK

            // Diagonal equal snake back to `(xMid, yMid)`
            while curX > prevX && curY > prevY {
                curX -= 1
                curY -= 1
                middleReversed.append(
                    MyersEditStep(
                        kind: .equal,
                        oldIndex: oStart + curX,
                        newIndex: nStart + curY,
                        element: oldArray[oStart + curX]
                    )
                )
            }

            if d > 0 {
                if curX == prevX {
                    // Insertion step `(prevX, prevY) -> (prevX, prevY + 1)`
                    curY -= 1
                    middleReversed.append(
                        MyersEditStep(
                            kind: .insert,
                            oldIndex: nil,
                            newIndex: nStart + curY,
                            element: newArray[nStart + curY]
                        )
                    )
                } else {
                    // Deletion step `(prevX, prevY) -> (prevX + 1, prevY)`
                    curX -= 1
                    middleReversed.append(
                        MyersEditStep(
                            kind: .delete,
                            oldIndex: oStart + curX,
                            newIndex: nil,
                            element: oldArray[oStart + curX]
                        )
                    )
                }
            }
        }

        var full = prefix
        full.append(contentsOf: middleReversed.reversed())
        full.append(contentsOf: suffixReversed.reversed())
        return full
    }

    // MARK: - Hunk Coalescing

    public func coalesceStepsIntoHunks(
        steps: [MyersEditStep<String>],
        contextLines: Int = 3
    ) -> [MyersCoalescedHunk] {
        let ctx = max(0, contextLines)
        let changedIndices = steps.indices.filter { steps[$0].kind != .equal }
        guard !changedIndices.isEmpty else { return [] }

        // Build raw `[winStart...winEnd]` step index windows and merge overlapping/adjacent windows
        var windows: [ClosedRange<Int>] = []
        for idx in changedIndices {
            let start = max(0, idx - ctx)
            let end = min(steps.count - 1, idx + ctx)
            if let last = windows.last, start <= last.upperBound + 1 {
                windows[windows.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                windows.append(start...end)
            }
        }

        // Compute 1-based line numbers for every step once so empty/pure-insert hunks get exact coordinates
        var oldLineBeforeStep = [Int](repeating: 1, count: steps.count + 1)
        var newLineBeforeStep = [Int](repeating: 1, count: steps.count + 1)
        var curOld = 1
        var curNew = 1
        for (sIdx, step) in steps.enumerated() {
            oldLineBeforeStep[sIdx] = curOld
            newLineBeforeStep[sIdx] = curNew
            switch step.kind {
            case .equal:
                curOld += 1
                curNew += 1
            case .delete:
                curOld += 1
            case .insert:
                curNew += 1
            }
        }

        var hunks: [MyersCoalescedHunk] = []
        hunks.reserveCapacity(windows.count)

        for win in windows {
            var hunkLines: [MyersHunkLine] = []
            var oldCount = 0
            var newCount = 0

            for sIdx in win {
                let st = steps[sIdx]
                switch st.kind {
                case .equal:
                    oldCount += 1
                    newCount += 1
                    hunkLines.append(MyersHunkLine(
                        kind: .equal,
                        oldLineNumber: (st.oldIndex ?? 0) + 1,
                        newLineNumber: (st.newIndex ?? 0) + 1,
                        text: st.element
                    ))
                case .delete:
                    oldCount += 1
                    hunkLines.append(MyersHunkLine(
                        kind: .delete,
                        oldLineNumber: (st.oldIndex ?? 0) + 1,
                        newLineNumber: nil,
                        text: st.element
                    ))
                case .insert:
                    newCount += 1
                    hunkLines.append(MyersHunkLine(
                        kind: .insert,
                        oldLineNumber: nil,
                        newLineNumber: (st.newIndex ?? 0) + 1,
                        text: st.element
                    ))
                }
            }

            let rawOldStart = oldLineBeforeStep[win.lowerBound]
            let rawNewStart = newLineBeforeStep[win.lowerBound]
            let finalOldStart = (oldCount == 0) ? max(0, rawOldStart - 1) : rawOldStart
            let finalNewStart = (newCount == 0) ? max(0, rawNewStart - 1) : rawNewStart

            hunks.append(
                MyersCoalescedHunk(
                    oldStartLine: finalOldStart,
                    oldLineCount: oldCount,
                    newStartLine: finalNewStart,
                    newLineCount: newCount,
                    lines: hunkLines
                )
            )
        }
        return hunks
    }

    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") && !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }
}

// MARK: - Three-Way Diff3 (`base`, `ours`, `theirs`) Text Merger

public enum Diff3CleanProvenance: String, Sendable, Codable, Hashable {
    case unchangedBase
    case tookOurs
    case tookTheirs
    case identicalBothSides
}

public struct Diff3ConflictBlock: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let baseLineRange: Range<Int>
    public let oursLabel: String
    public let baseLabel: String
    public let theirsLabel: String
    public let oursLines: [String]
    public let baseLines: [String]
    public let theirsLines: [String]

    public init(
        id: UUID = UUID(),
        baseLineRange: Range<Int>,
        oursLabel: String = "ours",
        baseLabel: String = "base",
        theirsLabel: String = "theirs",
        oursLines: [String],
        baseLines: [String],
        theirsLines: [String]
    ) {
        self.id = id
        self.baseLineRange = baseLineRange
        self.oursLabel = oursLabel
        self.baseLabel = baseLabel
        self.theirsLabel = theirsLabel
        self.oursLines = oursLines
        self.baseLines = baseLines
        self.theirsLines = theirsLines
    }
}

public enum Diff3MergedRegion: Sendable, Codable, Hashable {
    case clean(lines: [String], provenance: Diff3CleanProvenance)
    case conflict(Diff3ConflictBlock)
}

public struct Diff3MergeOutcome: Sendable, Codable, Hashable {
    public let regions: [Diff3MergedRegion]
    public let hasConflicts: Bool
    public let conflictCount: Int
    public let renderedText: String

    public init(regions: [Diff3MergedRegion], markerStyle: ConflictMarkerStyle = .diff3WithBase, appendTrailingNewline: Bool = true) {
        self.regions = regions
        let conflicts = regions.reduce(0) { acc, reg in
            if case .conflict = reg { return acc + 1 }
            return acc
        }
        self.conflictCount = conflicts
        self.hasConflicts = conflicts > 0
        self.renderedText = ConflictMarkerDocumentCodec().serializeDiff3Regions(
            regions,
            style: markerStyle,
            appendTrailingNewline: appendTrailingNewline
        )
    }
}

public struct Diff3TextMergeEngine: Sendable {
    public let diffEngine: MyersLineAndTokenDiffEngine
    public var zealousTrimCommonConflictEdges: Bool

    public init(
        diffEngine: MyersLineAndTokenDiffEngine = MyersLineAndTokenDiffEngine(),
        zealousTrimCommonConflictEdges: Bool = true
    ) {
        self.diffEngine = diffEngine
        self.zealousTrimCommonConflictEdges = zealousTrimCommonConflictEdges
    }

    /// Performs a Patience-anchored 3-way `diff3` text merge across `base`, `ours`, and `theirs`.
    public func mergeThreeWay(
        base: String,
        ours: String,
        theirs: String,
        oursLabel: String = "ours",
        baseLabel: String = "base",
        theirsLabel: String = "theirs",
        markerStyle: ConflictMarkerStyle = .diff3WithBase
    ) -> Diff3MergeOutcome {
        let baseLines = MyersLineAndTokenDiffEngine.splitLines(base)
        let oursLines = MyersLineAndTokenDiffEngine.splitLines(ours)
        let theirsLines = MyersLineAndTokenDiffEngine.splitLines(theirs)

        let oursEdits = extractBaseChangeSpans(baseLines: baseLines, sideLines: oursLines)
        let theirsEdits = extractBaseChangeSpans(baseLines: baseLines, sideLines: theirsLines)

        var regions: [Diff3MergedRegion] = []
        var bCursor = 0
        var oIdx = 0
        var tIdx = 0

        while oIdx < oursEdits.count || tIdx < theirsEdits.count {
            let nextO = oIdx < oursEdits.count ? oursEdits[oIdx] : nil
            let nextT = tIdx < theirsEdits.count ? theirsEdits[tIdx] : nil

            // Case A: Only `ours` has remaining edits, or `ours` edit finishes strictly before `theirs` starts (and isn't a zero-length tie at the exact same insertion point!)
            if let o = nextO, (nextT == nil || (o.baseEnd < nextT!.baseStart) || (o.baseEnd == nextT!.baseStart && o.baseStart < o.baseEnd && nextT!.baseStart < nextT!.baseEnd && false)) {
                // Note: adjacent touching edits `o.baseEnd == nextT.baseStart` are coalesced into the overlap loop below only if they touch at an insertion point; non-empty disjoint base spans only conflict if desired, here `o.baseEnd < nextT!.baseStart` is strictly separated by >=1 unchanged base line, OR `o.baseEnd == nextT!.baseStart` with non-zero spans can be checked carefully!
                if bCursor < o.baseStart {
                    regions.append(.clean(lines: Array(baseLines[bCursor..<o.baseStart]), provenance: .unchangedBase))
                }
                regions.append(.clean(lines: o.replacementLines, provenance: .tookOurs))
                bCursor = o.baseEnd
                oIdx += 1
                continue
            }

            if let t = nextT, (nextO == nil || t.baseEnd < nextO!.baseStart) {
                if bCursor < t.baseStart {
                    regions.append(.clean(lines: Array(baseLines[bCursor..<t.baseStart]), provenance: .unchangedBase))
                }
                regions.append(.clean(lines: t.replacementLines, provenance: .tookTheirs))
                bCursor = t.baseEnd
                tIdx += 1
                continue
            }

            // Case B: `nextO` and `nextT` overlap or touch on `base` coordinates — expand transitive overlap cluster!
            var clusterStart = min(nextO!.baseStart, nextT!.baseStart)
            var clusterEnd = max(nextO!.baseEnd, nextT!.baseEnd)
            clusterStart = max(bCursor, clusterStart)

            let groupOStart = oIdx
            let groupTStart = tIdx

            // Advance `oIdx` and `tIdx` to include any span overlapping `[clusterStart...clusterEnd]`
            var grew = true
            while grew {
                grew = false
                while oIdx < oursEdits.count {
                    let cand = oursEdits[oIdx]
                    if cand.baseStart < clusterEnd || (cand.baseStart == clusterEnd && (oIdx == groupOStart || cand.baseStart == cand.baseEnd || clusterStart == clusterEnd)) {
                        clusterEnd = max(clusterEnd, cand.baseEnd)
                        oIdx += 1
                        grew = true
                    } else {
                        break
                    }
                }
                while tIdx < theirsEdits.count {
                    let cand = theirsEdits[tIdx]
                    if cand.baseStart < clusterEnd || (cand.baseStart == clusterEnd && (tIdx == groupTStart || cand.baseStart == cand.baseEnd || clusterStart == clusterEnd)) {
                        clusterEnd = max(clusterEnd, cand.baseEnd)
                        tIdx += 1
                        grew = true
                    } else {
                        break
                    }
                }
            }

            if bCursor < clusterStart {
                regions.append(.clean(lines: Array(baseLines[bCursor..<clusterStart]), provenance: .unchangedBase))
            }

            let oursGroup = Array(oursEdits[groupOStart..<oIdx])
            let theirsGroup = Array(theirsEdits[groupTStart..<tIdx])

            let reconstructedOurs = reconstructSideSlice(
                baseLines: baseLines,
                clusterStart: clusterStart,
                clusterEnd: clusterEnd,
                edits: oursGroup
            )
            let reconstructedTheirs = reconstructSideSlice(
                baseLines: baseLines,
                clusterStart: clusterStart,
                clusterEnd: clusterEnd,
                edits: theirsGroup
            )
            let baseSlice = Array(baseLines[clusterStart..<clusterEnd])

            if oursGroup.isEmpty {
                regions.append(.clean(lines: reconstructedTheirs, provenance: .tookTheirs))
            } else if theirsGroup.isEmpty {
                regions.append(.clean(lines: reconstructedOurs, provenance: .tookOurs))
            } else if reconstructedOurs == reconstructedTheirs {
                regions.append(.clean(lines: reconstructedOurs, provenance: .identicalBothSides))
            } else {
                appendConflictWithOptionalZealousTrim(
                    into: &regions,
                    baseRange: clusterStart..<clusterEnd,
                    oursLabel: oursLabel,
                    baseLabel: baseLabel,
                    theirsLabel: theirsLabel,
                    oursLines: reconstructedOurs,
                    baseLines: baseSlice,
                    theirsLines: reconstructedTheirs
                )
            }

            bCursor = clusterEnd
        }

        if bCursor < baseLines.count {
            regions.append(.clean(lines: Array(baseLines[bCursor..<baseLines.count]), provenance: .unchangedBase))
        }

        let trailingNL = ours.hasSuffix("\n") || theirs.hasSuffix("\n") || base.hasSuffix("\n")
        return Diff3MergeOutcome(
            regions: coalesceAdjacentCleanRegions(regions),
            markerStyle: markerStyle,
            appendTrailingNewline: trailingNL
        )
    }

    // MARK: - Diff3 Internal Helpers

    private struct BaseChangeSpan {
        let baseStart: Int
        let baseEnd: Int
        let replacementLines: [String]
    }

    private func extractBaseChangeSpans(baseLines: [String], sideLines: [String]) -> [BaseChangeSpan] {
        let steps = diffEngine.diffElementsPatience(baseLines, sideLines)
        var spans: [BaseChangeSpan] = []

        var sIdx = 0
        var curBaseIdx = 0

        while sIdx < steps.count {
            if steps[sIdx].kind == .equal {
                curBaseIdx += 1
                sIdx += 1
                continue
            }

            let spanBaseStart = curBaseIdx
            var deletedCount = 0
            var inserted: [String] = []

            while sIdx < steps.count && steps[sIdx].kind != .equal {
                switch steps[sIdx].kind {
                case .delete:
                    deletedCount += 1
                    curBaseIdx += 1
                case .insert:
                    inserted.append(steps[sIdx].element)
                case .equal:
                    break
                }
                sIdx += 1
            }

            spans.append(
                BaseChangeSpan(
                    baseStart: spanBaseStart,
                    baseEnd: spanBaseStart + deletedCount,
                    replacementLines: inserted
                )
            )
        }
        return spans
    }

    private func reconstructSideSlice(
        baseLines: [String],
        clusterStart: Int,
        clusterEnd: Int,
        edits: [BaseChangeSpan]
    ) -> [String] {
        var out: [String] = []
        var bPos = clusterStart
        for ed in edits {
            if bPos < ed.baseStart {
                out.append(contentsOf: baseLines[bPos..<ed.baseStart])
            }
            out.append(contentsOf: ed.replacementLines)
            bPos = ed.baseEnd
        }
        if bPos < clusterEnd {
            out.append(contentsOf: baseLines[bPos..<clusterEnd])
        }
        return out
    }

    private func appendConflictWithOptionalZealousTrim(
        into regions: inout [Diff3MergedRegion],
        baseRange: Range<Int>,
        oursLabel: String,
        baseLabel: String,
        theirsLabel: String,
        oursLines: [String],
        baseLines: [String],
        theirsLines: [String]
    ) {
        guard zealousTrimCommonConflictEdges else {
            regions.append(.conflict(Diff3ConflictBlock(
                baseLineRange: baseRange,
                oursLabel: oursLabel,
                baseLabel: baseLabel,
                theirsLabel: theirsLabel,
                oursLines: oursLines,
                baseLines: baseLines,
                theirsLines: theirsLines
            )))
            return
        }

        // Hoist identical leading lines shared between `oursLines` and `theirsLines`
        var prefixCount = 0
        let minOT = min(oursLines.count, theirsLines.count)
        while prefixCount < minOT && oursLines[prefixCount] == theirsLines[prefixCount] {
            prefixCount += 1
        }

        // Hoist identical trailing lines shared between `oursLines` and `theirsLines`
        var suffixCount = 0
        while suffixCount < (minOT - prefixCount)
            && oursLines[oursLines.count - 1 - suffixCount] == theirsLines[theirsLines.count - 1 - suffixCount] {
            suffixCount += 1
        }

        if prefixCount > 0 {
            regions.append(.clean(lines: Array(oursLines[0..<prefixCount]), provenance: .identicalBothSides))
        }

        let midOurs = Array(oursLines[prefixCount..<(oursLines.count - suffixCount)])
        let midTheirs = Array(theirsLines[prefixCount..<(theirsLines.count - suffixCount)])
        // Trim matching prefix/suffix from `baseLines` when aligned
        var baseStartTrim = 0
        while baseStartTrim < min(prefixCount, baseLines.count) && baseLines[baseStartTrim] == oursLines[baseStartTrim] {
            baseStartTrim += 1
        }
        var baseEndTrim = 0
        while baseEndTrim < min(suffixCount, baseLines.count - baseStartTrim)
            && baseLines[baseLines.count - 1 - baseEndTrim] == oursLines[oursLines.count - 1 - baseEndTrim] {
            baseEndTrim += 1
        }
        let midBase = Array(baseLines[baseStartTrim..<(baseLines.count - baseEndTrim)])

        if midOurs != midTheirs {
            regions.append(.conflict(Diff3ConflictBlock(
                baseLineRange: baseRange,
                oursLabel: oursLabel,
                baseLabel: baseLabel,
                theirsLabel: theirsLabel,
                oursLines: midOurs,
                baseLines: midBase,
                theirsLines: midTheirs
            )))
        }

        if suffixCount > 0 {
            regions.append(.clean(
                lines: Array(oursLines[(oursLines.count - suffixCount)..<oursLines.count]),
                provenance: .identicalBothSides
            ))
        }
    }

    private func coalesceAdjacentCleanRegions(_ input: [Diff3MergedRegion]) -> [Diff3MergedRegion] {
        var out: [Diff3MergedRegion] = []
        for reg in input {
            switch reg {
            case .clean(let lines, let prov):
                if lines.isEmpty { continue }
                if let last = out.last, case .clean(let prevLines, let prevProv) = last, prevProv == prov {
                    out[out.count - 1] = .clean(lines: prevLines + lines, provenance: prov)
                } else {
                    out.append(reg)
                }
            case .conflict:
                out.append(reg)
            }
        }
        return out
    }
}

// MARK: - Conflict Marker (`<<<<<<<` / `|||||||` / `=======` / `>>>>>>>`) Parser & Serializer

public enum ConflictMarkerStyle: String, Sendable, Codable, Hashable, CaseIterable {
    case standardTwoWay
    case diff3WithBase
}

public struct ParsedConflictMarkerBlock: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let startLineNumber: Int
    public let endLineNumber: Int
    public let markerWidth: Int
    public let oursLabel: String
    public let baseLabel: String?
    public let theirsLabel: String
    public let oursLines: [String]
    public let baseLines: [String]?
    public let theirsLines: [String]

    public init(
        id: UUID = UUID(),
        startLineNumber: Int,
        endLineNumber: Int,
        markerWidth: Int = 7,
        oursLabel: String,
        baseLabel: String? = nil,
        theirsLabel: String,
        oursLines: [String],
        baseLines: [String]? = nil,
        theirsLines: [String]
    ) {
        self.id = id
        self.startLineNumber = startLineNumber
        self.endLineNumber = endLineNumber
        self.markerWidth = max(7, markerWidth)
        self.oursLabel = oursLabel
        self.baseLabel = baseLabel
        self.theirsLabel = theirsLabel
        self.oursLines = oursLines
        self.baseLines = baseLines
        self.theirsLines = theirsLines
    }
}

public enum ConflictDocumentSegment: Sendable, Codable, Hashable {
    case cleanLines([String])
    case conflictBlock(ParsedConflictMarkerBlock)
}

public struct ConflictMarkerDocumentCodec: Sendable {
    public init() {}

    /// Parses source text into alternating `.cleanLines` and `.conflictBlock` segments, handling both 2-way (`<<<<<<<`/`=======`/`>>>>>>>`) and diff3 (`|||||||`) conflict blocks as well as nested conflict markers.
    public func parseDocument(_ text: String) -> [ConflictDocumentSegment] {
        let allLines = MyersLineAndTokenDiffEngine.splitLines(text)
        guard !allLines.isEmpty else { return [] }

        var segments: [ConflictDocumentSegment] = []
        var cleanAccum: [String] = []
        var idx = 0

        while idx < allLines.count {
            if let openMarker = Self.matchMarkerPrefix(allLines[idx], char: "<") {
                if let (parsedBlock, nextIdx) = parseSingleConflictBlock(
                    lines: allLines,
                    startIdx: idx,
                    outerWidth: openMarker.width,
                    oursLabel: openMarker.label
                ) {
                    if !cleanAccum.isEmpty {
                        segments.append(.cleanLines(cleanAccum))
                        cleanAccum.removeAll(keepingCapacity: true)
                    }
                    segments.append(.conflictBlock(parsedBlock))
                    idx = nextIdx
                    continue
                }
            }
            cleanAccum.append(allLines[idx])
            idx += 1
        }

        if !cleanAccum.isEmpty {
            segments.append(.cleanLines(cleanAccum))
        }
        return segments
    }

    public func serializeDocument(
        _ segments: [ConflictDocumentSegment],
        style: ConflictMarkerStyle = .diff3WithBase,
        appendTrailingNewline: Bool = true
    ) -> String {
        var outLines: [String] = []
        for seg in segments {
            switch seg {
            case .cleanLines(let lines):
                outLines.append(contentsOf: lines)
            case .conflictBlock(let block):
                let w = max(7, block.markerWidth)
                let openStr = String(repeating: "<", count: w)
                let baseStr = String(repeating: "|", count: w)
                let sepStr  = String(repeating: "=", count: w)
                let closeStr = String(repeating: ">", count: w)

                outLines.append(block.oursLabel.isEmpty ? openStr : "\(openStr) \(block.oursLabel)")
                outLines.append(contentsOf: block.oursLines)
                if style == .diff3WithBase, let baseLines = block.baseLines {
                    let bLbl = block.baseLabel ?? "base"
                    outLines.append(bLbl.isEmpty ? baseStr : "\(baseStr) \(bLbl)")
                    outLines.append(contentsOf: baseLines)
                }
                outLines.append(sepStr)
                outLines.append(contentsOf: block.theirsLines)
                outLines.append(block.theirsLabel.isEmpty ? closeStr : "\(closeStr) \(block.theirsLabel)")
            }
        }
        if outLines.isEmpty { return "" }
        return outLines.joined(separator: "\n") + (appendTrailingNewline ? "\n" : "")
    }

    public func serializeDiff3Regions(
        _ regions: [Diff3MergedRegion],
        style: ConflictMarkerStyle = .diff3WithBase,
        appendTrailingNewline: Bool = true
    ) -> String {
        let segments: [ConflictDocumentSegment] = regions.map { region in
            switch region {
            case .clean(let lines, _):
                return .cleanLines(lines)
            case .conflict(let c):
                return .conflictBlock(
                    ParsedConflictMarkerBlock(
                        id: c.id,
                        startLineNumber: c.baseLineRange.lowerBound + 1,
                        endLineNumber: max(c.baseLineRange.lowerBound + 1, c.baseLineRange.upperBound),
                        markerWidth: 7,
                        oursLabel: c.oursLabel,
                        baseLabel: c.baseLabel,
                        theirsLabel: c.theirsLabel,
                        oursLines: c.oursLines,
                        baseLines: c.baseLines,
                        theirsLines: c.theirsLines
                    )
                )
            }
        }
        return serializeDocument(segments, style: style, appendTrailingNewline: appendTrailingNewline)
    }

    private enum ConflictSectionPhase {
        case ours
        case base
        case theirs
    }

    private func parseSingleConflictBlock(
        lines: [String],
        startIdx: Int,
        outerWidth: Int,
        oursLabel: String
    ) -> (ParsedConflictMarkerBlock, Int)? {
        var phase: ConflictSectionPhase = .ours
        var oursBuf: [String] = []
        var baseBuf: [String]?
        var baseLabel: String?
        var theirsBuf: [String] = []
        var nestedDepth = 0

        var scan = startIdx + 1
        while scan < lines.count {
            let line = lines[scan]

            if Self.matchMarkerPrefix(line, char: "<") != nil {
                nestedDepth += 1
            } else if nestedDepth > 0, Self.matchMarkerPrefix(line, char: ">") != nil {
                nestedDepth -= 1
            } else if nestedDepth == 0 {
                if phase == .ours,
                   let baseM = Self.matchMarkerPrefix(line, char: "|"),
                   baseM.width == outerWidth {
                    phase = .base
                    baseLabel = baseM.label
                    baseBuf = []
                    scan += 1
                    continue
                }
                if (phase == .ours || phase == .base),
                   let eqM = Self.matchMarkerPrefix(line, char: "="),
                   eqM.width == outerWidth && eqM.label.isEmpty {
                    phase = .theirs
                    scan += 1
                    continue
                }
                if phase == .theirs,
                   let closeM = Self.matchMarkerPrefix(line, char: ">"),
                   closeM.width == outerWidth {
                    let block = ParsedConflictMarkerBlock(
                        startLineNumber: startIdx + 1,
                        endLineNumber: scan + 1,
                        markerWidth: outerWidth,
                        oursLabel: oursLabel,
                        baseLabel: baseLabel,
                        theirsLabel: closeM.label,
                        oursLines: oursBuf,
                        baseLines: baseBuf,
                        theirsLines: theirsBuf
                    )
                    return (block, scan + 1)
                }
            }

            switch phase {
            case .ours:
                oursBuf.append(line)
            case .base:
                baseBuf?.append(line)
            case .theirs:
                theirsBuf.append(line)
            }
            scan += 1
        }
        return nil
    }

    private static func matchMarkerPrefix(_ line: String, char: Character) -> (width: Int, label: String)? {
        let chars = Array(line)
        var count = 0
        while count < chars.count && chars[count] == char {
            count += 1
        }
        guard count >= 7 else { return nil }
        if count == chars.count {
            return (count, "")
        }
        guard chars[count] == " " else { return nil }
        let label = String(chars[(count + 1)...]).trimmingCharacters(in: .whitespaces)
        return (count, label)
    }
}
