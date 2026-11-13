import Foundation
import RelayModels

// MARK: - Handwritten VT100 / xterm-256color / 24-bit TrueColor Terminal Emulator

public final class VT100TerminalScreenBuffer: @unchecked Sendable {
    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
    }

    private let lock = NSLock()
    public let laneID: String
    public private(set) var rows: Int
    public private(set) var columns: Int
    public let maxScrollbackLines: Int

    private var primaryGrid: [[TerminalCell]]
    private var alternateGrid: [[TerminalCell]]
    private var scrollback: [[TerminalCell]] = []
    private var isAlternateActive: Bool = false

    private var cursorRow: Int = 0
    private var cursorCol: Int = 0
    private var savedPrimaryCursor: (row: Int, col: Int) = (0, 0)
    private var savedAltCursor: (row: Int, col: Int) = (0, 0)
    private var pendingWrapNextPrint: Bool = false
    private var autoWrapEnabled: Bool = true
    private var cursorVisible: Bool = true
    private var cursorShape: TerminalCursorShape = .block
    private var bracketedPaste: Bool = false
    private var windowTitle: String = ""

    private var scrollTop: Int = 0
    private var scrollBottom: Int

    // Current SGR brush
    private var currentFG: TerminalColor = .defaultForeground
    private var currentBG: TerminalColor = .defaultBackground
    private var currentAttrs: TerminalCellAttributes = []

    // State machine accumulators
    private var state: ParserState = .ground
    private var csiPrivateMarker: UInt8?
    private var csiIntermediates: [UInt8] = []
    private var csiParamBuffer: String = ""
    private var oscBuffer: [UInt8] = []
    private var oscSawEscape: Bool = false
    private var utf8PendingBytes: [UInt8] = []
    private var utf8ExpectedCount: Int = 0

    public init(laneID: String, rows: Int = 28, columns: Int = 100, maxScrollbackLines: Int = 5_000) {
        let r = max(4, rows)
        let c = max(12, columns)
        self.laneID = laneID
        self.rows = r
        self.columns = c
        self.maxScrollbackLines = max(100, maxScrollbackLines)
        self.scrollBottom = r - 1
        self.primaryGrid = Array(repeating: Array(repeating: .blank, count: c), count: r)
        self.alternateGrid = Array(repeating: Array(repeating: .blank, count: c), count: r)
    }

    public func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        for byte in data {
            processByte(byte)
        }
    }

    public func feed(_ string: String) {
        feed(Data(string.utf8))
    }

    public func resize(rows newRows: Int, columns newCols: Int) {
        lock.lock()
        defer { lock.unlock() }
        let r = max(4, newRows)
        let c = max(12, newCols)
        guard r != rows || c != columns else { return }

        primaryGrid = Self.resizeGrid(primaryGrid, oldRows: rows, oldCols: columns, newRows: r, newCols: c)
        alternateGrid = Self.resizeGrid(alternateGrid, oldRows: rows, oldCols: columns, newRows: r, newCols: c)
        rows = r
        columns = c
        scrollTop = 0
        scrollBottom = r - 1
        cursorRow = min(max(0, cursorRow), r - 1)
        cursorCol = min(max(0, cursorCol), c - 1)
        pendingWrapNextPrint = false
    }

    public func snapshot() -> TerminalViewportSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let active = isAlternateActive ? alternateGrid : primaryGrid
        return TerminalViewportSnapshot(
            laneID: laneID,
            rows: rows,
            columns: columns,
            visibleGrid: active,
            scrollbackLineCount: scrollback.count,
            cursor: TerminalCursorState(
                row: cursorRow,
                column: cursorCol,
                isVisible: cursorVisible,
                shape: cursorShape
            ),
            windowTitle: windowTitle,
            isAlternateScreen: isAlternateActive,
            bracketedPasteEnabled: bracketedPaste
        )
    }

    public func recentScrollbackLines(limit: Int = 200) -> [[TerminalCell]] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(max(0, limit), scrollback.count)
        return Array(scrollback.suffix(count))
    }

    // MARK: - Byte-Level VT100 State Machine

    private static func resizeGrid(_ grid: [[TerminalCell]], oldRows: Int, oldCols: Int, newRows: Int, newCols: Int) -> [[TerminalCell]] {
        var out = Array(repeating: Array(repeating: TerminalCell.blank, count: newCols), count: newRows)
        let copyRows = min(oldRows, newRows)
        let copyCols = min(oldCols, newCols)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                out[r][c] = grid[r][c]
            }
        }
        return out
    }

    private func processByte(_ b: UInt8) {
        // Handle OSC string accumulation first
        if state == .osc {
            if oscSawEscape {
                oscSawEscape = false
                if b == 0x5C { // ST (`ESC \`)
                    commitOSC()
                    state = .ground
                    return
                }
            }
            if b == 0x07 { // BEL terminates OSC
                commitOSC()
                state = .ground
                return
            } else if b == 0x1B {
                oscSawEscape = true
                return
            } else {
                if oscBuffer.count < 4096 {
                    oscBuffer.append(b)
                }
                return
            }
        }

        // C0 controls execute immediately even mid-CSI
        switch b {
        case 0x07: // BEL
            return
        case 0x08: // BS
            pendingWrapNextPrint = false
            cursorCol = max(0, cursorCol - 1)
            return
        case 0x09: // HT (Tab to next 8-col stop)
            pendingWrapNextPrint = false
            let nextTab = ((cursorCol / 8) + 1) * 8
            cursorCol = min(columns - 1, nextTab)
            return
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            pendingWrapNextPrint = false
            lineFeed()
            return
        case 0x0D: // CR
            pendingWrapNextPrint = false
            cursorCol = 0
            return
        case 0x1B: // ESC
            utf8PendingBytes.removeAll(keepingCapacity: true)
            utf8ExpectedCount = 0
            state = .escape
            return
        default:
            break
        }

        switch state {
        case .ground:
            processGroundByte(b)
        case .escape:
            processEscapeByte(b)
        case .escapeIntermediate:
            if b >= 0x20 && b <= 0x2F {
                return
            }
            state = .ground
        case .csi:
            processCSIByte(b)
        case .osc:
            break
        }
    }

    private func processGroundByte(_ b: UInt8) {
        if b < 0x20 || b == 0x7F { return }

        if utf8ExpectedCount > 0 {
            if (b & 0xC0) == 0x80 {
                utf8PendingBytes.append(b)
                if utf8PendingBytes.count == utf8ExpectedCount {
                    let str = String(decoding: utf8PendingBytes, as: UTF8.self)
                    utf8PendingBytes.removeAll(keepingCapacity: true)
                    utf8ExpectedCount = 0
                    putGrapheme(str)
                }
                return
            } else {
                utf8PendingBytes.removeAll(keepingCapacity: true)
                utf8ExpectedCount = 0
            }
        }

        if b < 0x80 {
            putGrapheme(String(UnicodeScalar(b)))
        } else if (b & 0xE0) == 0xC0 {
            utf8PendingBytes = [b]
            utf8ExpectedCount = 2
        } else if (b & 0xF0) == 0xE0 {
            utf8PendingBytes = [b]
            utf8ExpectedCount = 3
        } else if (b & 0xF8) == 0xF0 {
            utf8PendingBytes = [b]
            utf8ExpectedCount = 4
        }
    }

    private func processEscapeByte(_ b: UInt8) {
        switch b {
        case 0x5B: // `[` -> CSI
            csiPrivateMarker = nil
            csiIntermediates.removeAll(keepingCapacity: true)
            csiParamBuffer = ""
            state = .csi
        case 0x5D: // `]` -> OSC
            oscBuffer.removeAll(keepingCapacity: true)
            oscSawEscape = false
            state = .osc
        case 0x37: // `7` DECSC save cursor
            if isAlternateActive {
                savedAltCursor = (cursorRow, cursorCol)
            } else {
                savedPrimaryCursor = (cursorRow, cursorCol)
            }
            state = .ground
        case 0x38: // `8` DECRC restore cursor
            let saved = isAlternateActive ? savedAltCursor : savedPrimaryCursor
            cursorRow = min(max(0, saved.row), rows - 1)
            cursorCol = min(max(0, saved.col), columns - 1)
            pendingWrapNextPrint = false
            state = .ground
        case 0x44: // `D` IND index (move down/scroll)
            lineFeed()
            state = .ground
        case 0x45: // `E` NEL next line
            cursorCol = 0
            lineFeed()
            state = .ground
        case 0x4D: // `M` RI reverse index
            reverseIndex()
            state = .ground
        case 0x63: // `c` RIS full reset
            resetTerminal()
            state = .ground
        case 0x20...0x2F: // Character set designation `ESC ( B` etc.
            state = .escapeIntermediate
        default:
            state = .ground
        }
    }

    private func processCSIByte(_ b: UInt8) {
        if csiParamBuffer.isEmpty && csiPrivateMarker == nil && (b == 0x3F || b == 0x3E || b == 0x3D) {
            csiPrivateMarker = b
            return
        }
        if (b >= 0x30 && b <= 0x39) || b == 0x3B || b == 0x3A {
            if csiParamBuffer.count < 128 {
                csiParamBuffer.append(Character(UnicodeScalar(b)))
            }
            return
        }
        if b >= 0x20 && b <= 0x2F {
            csiIntermediates.append(b)
            return
        }
        if b >= 0x40 && b <= 0x7E {
            dispatchCSI(finalByte: b)
            state = .ground
            return
        }
        state = .ground
    }

    private func parseCSIParams(defaultValue: Int = 1) -> [Int] {
        if csiParamBuffer.isEmpty {
            return []
        }
        // Normalize sub-parameter colons (`38:2:r:g:b`) into semicolons for SGR handling
        let normalized = csiParamBuffer.replacingOccurrences(of: ":", with: ";")
        return normalized.split(separator: ";", omittingEmptySubsequences: false).map { part in
            Int(part) ?? defaultValue
        }
    }

    private func dispatchCSI(finalByte: UInt8) {
        let params = parseCSIParams(defaultValue: 0)
        let p0 = max(1, params.first ?? 1)

        if csiPrivateMarker == 0x3F { // `?` DEC Private Modes
            let enable = (finalByte == 0x68) // `h` set, `l` reset
            if finalByte == 0x68 || finalByte == 0x6C {
                for mode in params {
                    switch mode {
                    case 7:
                        autoWrapEnabled = enable
                    case 25:
                        cursorVisible = enable
                    case 47, 1047, 1049:
                        switchAlternateScreen(enable: enable, saveCursor: mode == 1049)
                    case 2004:
                        bracketedPaste = enable
                    default:
                        break
                    }
                }
            }
            return
        }

        if csiIntermediates == [0x20] && finalByte == 0x71 { // `CSI Ps SP q` DECSCUSR cursor shape
            let style = params.first ?? 1
            switch style {
            case 3, 4: cursorShape = .underline
            case 5, 6: cursorShape = .bar
            default: cursorShape = .block
            }
            return
        }

        switch finalByte {
        case 0x41: // `A` CUU up
            pendingWrapNextPrint = false
            cursorRow = max(scrollTop, cursorRow - p0)
        case 0x42: // `B` CUD down
            pendingWrapNextPrint = false
            cursorRow = min(scrollBottom, cursorRow + p0)
        case 0x43: // `C` CUF forward
            pendingWrapNextPrint = false
            cursorCol = min(columns - 1, cursorCol + p0)
        case 0x44: // `D` CUB back
            pendingWrapNextPrint = false
            cursorCol = max(0, cursorCol - p0)
        case 0x45: // `E` CNL next line
            pendingWrapNextPrint = false
            cursorCol = 0
            cursorRow = min(scrollBottom, cursorRow + p0)
        case 0x46: // `F` CPL prev line
            pendingWrapNextPrint = false
            cursorCol = 0
            cursorRow = max(scrollTop, cursorRow - p0)
        case 0x47: // `G` CHA cursor horizontal absolute (1-based)
            pendingWrapNextPrint = false
            cursorCol = min(columns - 1, max(0, p0 - 1))
        case 0x48, 0x66: // `H` / `f` CUP cursor position (1-based row;col)
            pendingWrapNextPrint = false
            let targetRow = max(1, params.count >= 1 ? params[0] : 1) - 1
            let targetCol = max(1, params.count >= 2 ? params[1] : 1) - 1
            cursorRow = min(rows - 1, max(0, targetRow))
            cursorCol = min(columns - 1, max(0, targetCol))
        case 0x4A: // `J` ED erase in display
            eraseInDisplay(mode: params.first ?? 0)
        case 0x4B: // `K` EL erase in line
            eraseInLine(mode: params.first ?? 0)
        case 0x4C: // `L` IL insert lines
            insertBlankLines(count: p0)
        case 0x4D: // `M` DL delete lines
            deleteLines(count: p0)
        case 0x50: // `P` DCH delete chars
            deleteCharacters(count: p0)
        case 0x40: // `@` ICH insert blank chars
            insertBlankCharacters(count: p0)
        case 0x58: // `X` ECH erase chars
            eraseCharacters(count: p0)
        case 0x53: // `S` SU scroll up
            for _ in 0..<p0 { scrollRegionUp() }
        case 0x54: // `T` SD scroll down
            for _ in 0..<p0 { scrollRegionDown() }
        case 0x64: // `d` VPA vertical line position absolute
            pendingWrapNextPrint = false
            cursorRow = min(rows - 1, max(0, p0 - 1))
        case 0x6D: // `m` SGR select graphic rendition
            applySGR(params.isEmpty ? [0] : params)
        case 0x72: // `r` DECSTBM set top and bottom margins
            let top = max(1, params.count >= 1 ? params[0] : 1) - 1
            let bot = (params.count >= 2 && params[1] > 0 ? params[1] : rows) - 1
            if top < bot && bot < rows {
                scrollTop = top
                scrollBottom = bot
                cursorRow = 0
                cursorCol = 0
            }
        case 0x73: // `s` save cursor
            savedPrimaryCursor = (cursorRow, cursorCol)
        case 0x75: // `u` restore cursor
            cursorRow = min(rows - 1, max(0, savedPrimaryCursor.row))
            cursorCol = min(columns - 1, max(0, savedPrimaryCursor.col))
        default:
            break
        }
    }

    // MARK: - Grid Operations & SGR

    private func putGrapheme(_ grapheme: String) {
        if pendingWrapNextPrint && autoWrapEnabled {
            pendingWrapNextPrint = false
            cursorCol = 0
            lineFeed()
        }

        let cell = TerminalCell(
            grapheme: grapheme,
            foreground: currentFG,
            background: currentBG,
            attributes: currentAttrs,
            columnSpan: 1
        )
        setCell(row: cursorRow, col: cursorCol, cell: cell)

        if cursorCol + 1 >= columns {
            if autoWrapEnabled {
                pendingWrapNextPrint = true
            }
        } else {
            cursorCol += 1
        }
    }

    private func setCell(row: Int, col: Int, cell: TerminalCell) {
        guard row >= 0, row < rows, col >= 0, col < columns else { return }
        if isAlternateActive {
            alternateGrid[row][col] = cell
        } else {
            primaryGrid[row][col] = cell
        }
    }

    private func blankRow() -> [TerminalCell] {
        let cell = TerminalCell(grapheme: " ", foreground: .defaultForeground, background: currentBG)
        return Array(repeating: cell, count: columns)
    }

    private func lineFeed() {
        if cursorRow == scrollBottom {
            scrollRegionUp()
        } else if cursorRow + 1 < rows {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollRegionDown()
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollRegionUp() {
        guard scrollTop >= 0, scrollBottom < rows, scrollTop <= scrollBottom else { return }
        if isAlternateActive {
            alternateGrid.remove(at: scrollTop)
            alternateGrid.insert(blankRow(), at: scrollBottom)
        } else {
            let evicted = primaryGrid.remove(at: scrollTop)
            if scrollTop == 0 {
                scrollback.append(evicted)
                if scrollback.count > maxScrollbackLines {
                    scrollback.removeFirst(scrollback.count - maxScrollbackLines)
                }
            }
            primaryGrid.insert(blankRow(), at: scrollBottom)
        }
    }

    private func scrollRegionDown() {
        guard scrollTop >= 0, scrollBottom < rows, scrollTop <= scrollBottom else { return }
        if isAlternateActive {
            alternateGrid.remove(at: scrollBottom)
            alternateGrid.insert(blankRow(), at: scrollTop)
        } else {
            primaryGrid.remove(at: scrollBottom)
            primaryGrid.insert(blankRow(), at: scrollTop)
        }
    }

    private func eraseInDisplay(mode: Int) {
        let blank = TerminalCell(grapheme: " ", foreground: .defaultForeground, background: currentBG)
        switch mode {
        case 0: // Cursor to end of screen
            eraseInLine(mode: 0)
            for r in (cursorRow + 1)..<rows {
                for c in 0..<columns { setCell(row: r, col: c, cell: blank) }
            }
        case 1: // Start of screen to cursor
            for r in 0..<cursorRow {
                for c in 0..<columns { setCell(row: r, col: c, cell: blank) }
            }
            eraseInLine(mode: 1)
        case 2, 3: // Entire screen (+ scrollback if 3)
            for r in 0..<rows {
                for c in 0..<columns { setCell(row: r, col: c, cell: blank) }
            }
            if mode == 3 {
                scrollback.removeAll(keepingCapacity: true)
            }
        default:
            break
        }
    }

    private func eraseInLine(mode: Int) {
        let blank = TerminalCell(grapheme: " ", foreground: .defaultForeground, background: currentBG)
        switch mode {
        case 0:
            for c in cursorCol..<columns { setCell(row: cursorRow, col: c, cell: blank) }
        case 1:
            for c in 0...min(columns - 1, cursorCol) { setCell(row: cursorRow, col: c, cell: blank) }
        case 2:
            for c in 0..<columns { setCell(row: cursorRow, col: c, cell: blank) }
        default:
            break
        }
    }

    private func insertBlankLines(count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<n {
            if isAlternateActive {
                alternateGrid.remove(at: scrollBottom)
                alternateGrid.insert(blankRow(), at: cursorRow)
            } else {
                primaryGrid.remove(at: scrollBottom)
                primaryGrid.insert(blankRow(), at: cursorRow)
            }
        }
    }

    private func deleteLines(count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        for _ in 0..<n {
            if isAlternateActive {
                alternateGrid.remove(at: cursorRow)
                alternateGrid.insert(blankRow(), at: scrollBottom)
            } else {
                primaryGrid.remove(at: cursorRow)
                primaryGrid.insert(blankRow(), at: scrollBottom)
            }
        }
    }

    private func deleteCharacters(count: Int) {
        let n = min(count, columns - cursorCol)
        let blank = TerminalCell(grapheme: " ", foreground: .defaultForeground, background: currentBG)
        for _ in 0..<n {
            if isAlternateActive {
                alternateGrid[cursorRow].remove(at: cursorCol)
                alternateGrid[cursorRow].append(blank)
            } else {
                primaryGrid[cursorRow].remove(at: cursorCol)
                primaryGrid[cursorRow].append(blank)
            }
        }
    }

    private func insertBlankCharacters(count: Int) {
        let n = min(count, columns - cursorCol)
        let blank = TerminalCell(grapheme: " ", foreground: .defaultForeground, background: currentBG)
        for _ in 0..<n {
            if isAlternateActive {
                alternateGrid[cursorRow].insert(blank, at: cursorCol)
                alternateGrid[cursorRow].removeLast()
            } else {
                primaryGrid[cursorRow].insert(blank, at: cursorCol)
                primaryGrid[cursorRow].removeLast()
            }
        }
    }

    private func eraseCharacters(count: Int) {
        let end = min(columns, cursorCol + count)
        let blank = TerminalCell(grapheme: " ", foreground: .defaultForeground, background: currentBG)
        for c in cursorCol..<end {
            setCell(row: cursorRow, col: c, cell: blank)
        }
    }

    private func switchAlternateScreen(enable: Bool, saveCursor: Bool) {
        if enable && !isAlternateActive {
            if saveCursor { savedPrimaryCursor = (cursorRow, cursorCol) }
            isAlternateActive = true
            alternateGrid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
            cursorRow = 0
            cursorCol = 0
            pendingWrapNextPrint = false
        } else if !enable && isAlternateActive {
            isAlternateActive = false
            if saveCursor {
                cursorRow = min(rows - 1, max(0, savedPrimaryCursor.row))
                cursorCol = min(columns - 1, max(0, savedPrimaryCursor.col))
            }
            pendingWrapNextPrint = false
        }
    }

    private func applySGR(_ codes: [Int]) {
        var idx = 0
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case 0:
                currentFG = .defaultForeground
                currentBG = .defaultBackground
                currentAttrs = []
            case 1: currentAttrs.insert(.bold)
            case 2: currentAttrs.insert(.dim)
            case 3: currentAttrs.insert(.italic)
            case 4: currentAttrs.insert(.underline)
            case 5, 6: currentAttrs.insert(.blink)
            case 7: currentAttrs.insert(.inverse)
            case 8: currentAttrs.insert(.hidden)
            case 9: currentAttrs.insert(.strikethrough)
            case 22: currentAttrs.remove([.bold, .dim])
            case 23: currentAttrs.remove(.italic)
            case 24: currentAttrs.remove(.underline)
            case 25: currentAttrs.remove(.blink)
            case 27: currentAttrs.remove(.inverse)
            case 28: currentAttrs.remove(.hidden)
            case 29: currentAttrs.remove(.strikethrough)
            case 30...37:
                currentFG = .ansi16(UInt8(code - 30))
            case 39:
                currentFG = .defaultForeground
            case 40...47:
                currentBG = .ansi16(UInt8(code - 40))
            case 49:
                currentBG = .defaultBackground
            case 90...97:
                currentFG = .ansi16(UInt8(code - 90 + 8))
            case 100...107:
                currentBG = .ansi16(UInt8(code - 100 + 8))
            case 38, 48:
                let isFG = (code == 38)
                if idx + 2 < codes.count && codes[idx + 1] == 5 {
                    let pal = UInt8(clamping: codes[idx + 2])
                    if isFG { currentFG = .palette256(pal) } else { currentBG = .palette256(pal) }
                    idx += 2
                } else if idx + 4 < codes.count && codes[idx + 1] == 2 {
                    let r = UInt8(clamping: codes[idx + 2])
                    let g = UInt8(clamping: codes[idx + 3])
                    let b = UInt8(clamping: codes[idx + 4])
                    if isFG { currentFG = .trueColor(r: r, g: g, b: b) } else { currentBG = .trueColor(r: r, g: g, b: b) }
                    idx += 4
                }
            default:
                break
            }
            idx += 1
        }
    }

    private func commitOSC() {
        let str = String(decoding: oscBuffer, as: UTF8.self)
        guard let semi = str.firstIndex(of: ";") else { return }
        let code = str[..<semi]
        let payload = String(str[str.index(after: semi)...])
        if code == "0" || code == "2" {
            windowTitle = payload
        }
    }

    private func resetTerminal() {
        isAlternateActive = false
        primaryGrid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        alternateGrid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        currentFG = .defaultForeground
        currentBG = .defaultBackground
        currentAttrs = []
        cursorVisible = true
        bracketedPaste = false
        pendingWrapNextPrint = false
    }
}
