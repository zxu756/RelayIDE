import Darwin
import Foundation
import RelayModels
import RelayPTYCore
import Testing

@Suite("PTY Multiplexer, VT100 Parser, Palette, Keystrokes & Scrollback", .timeLimit(.minutes(1)))
struct PTYAndTerminalMultiplexerTests {

    // MARK: - 1. VT100 CSI Cursor Addressing, Alternate Screen & Mode Flags

    @Test("VT100 CSI cursor motion, OSC window title, bracketed paste, and alternate screen restore")
    func vt100CursorAddressingModesAndAlternateScreen() {
        let buffer = VT100TerminalScreenBuffer(laneID: "lane-claude", rows: 10, columns: 40, maxScrollbackLines: 200)

        buffer.feed("\u{1B}]0;Claude Code · BillingEngine\u{07}")
        buffer.feed("\u{1B}[?2004h")
        buffer.feed("Header Line\r\nSecond Row")
        buffer.feed("\u{1B}[4;6HPlanted")
        buffer.feed("\u{1B}[4 q")

        let primarySnap = buffer.snapshot()
        #expect(primarySnap.windowTitle == "Claude Code · BillingEngine")
        #expect(primarySnap.bracketedPasteEnabled == true)
        #expect(primarySnap.isAlternateScreen == false)
        #expect(primarySnap.cursor.shape == .underline)
        #expect(primarySnap.plainTextLines[0].hasPrefix("Header Line"))
        #expect(primarySnap.plainTextLines[1].hasPrefix("Second Row"))
        #expect(primarySnap.visibleGrid[3][5].grapheme == "P")
        #expect(primarySnap.visibleGrid[3][11].grapheme == "d")

        // Enter alternate screen (?1049h), draw fullscreen TUI content, then exit (?1049l)
        buffer.feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1HALT-TUI-VIEW\u{1B}[?25l")
        let altSnap = buffer.snapshot()
        #expect(altSnap.isAlternateScreen == true)
        #expect(altSnap.cursor.isVisible == false)
        #expect(altSnap.plainTextLines[0].hasPrefix("ALT-TUI-VIEW"))

        buffer.feed("\u{1B}[?1049l\u{1B}[?25h\u{1B}[6 q\u{1B}[?2004l")
        let restoredSnap = buffer.snapshot()
        #expect(restoredSnap.isAlternateScreen == false)
        #expect(restoredSnap.cursor.isVisible == true)
        #expect(restoredSnap.cursor.shape == .bar)
        #expect(restoredSnap.bracketedPasteEnabled == false)
        #expect(restoredSnap.plainTextLines[0].hasPrefix("Header Line"))
        #expect(restoredSnap.visibleGrid[3][5].grapheme == "P")
    }

    // MARK: - 2. VT100 SGR 16-Color, 256-Color, TrueColor & Text Attributes

    @Test("VT100 SGR parses ANSI-16, 256-palette, 24-bit TrueColor, and cell attribute bitmasks")
    func vt100SGRColorsAndCellAttributes() {
        let buffer = VT100TerminalScreenBuffer(laneID: "lane-codex", rows: 6, columns: 48)

        // Bold + Red (31) on Bright Black bg (100)
        buffer.feed("\u{1B}[1;3;4;9;31;100mE")
        // 256-color fg (208 orange) + bg (236 dark gray), reset italic/underline via 23;24
        buffer.feed("\u{1B}[23;24;38;5;208;48;5;236mW")
        // TrueColor fg (32,93,209) + bg (24,24,27) + dim + inverse
        buffer.feed("\u{1B}[2;7;38;2;32;93;209;48;2;24;24;27mT")
        // Full SGR reset
        buffer.feed("\u{1B}[0mN")

        let grid = buffer.snapshot().visibleGrid
        let cellE = grid[0][0]
        #expect(cellE.grapheme == "E")
        #expect(cellE.foreground == .ansi16(1))
        #expect(cellE.background == .ansi16(8))
        #expect(cellE.attributes.contains(.bold))
        #expect(cellE.attributes.contains(.italic))
        #expect(cellE.attributes.contains(.underline))
        #expect(cellE.attributes.contains(.strikethrough))

        let cellW = grid[0][1]
        #expect(cellW.grapheme == "W")
        #expect(cellW.foreground == .palette256(208))
        #expect(cellW.background == .palette256(236))
        #expect(!cellW.attributes.contains(.italic))
        #expect(!cellW.attributes.contains(.underline))

        let cellT = grid[0][2]
        #expect(cellT.grapheme == "T")
        #expect(cellT.foreground == .trueColor(r: 32, g: 93, b: 209))
        #expect(cellT.background == .trueColor(r: 24, g: 24, b: 27))
        #expect(cellT.attributes.contains(.dim))
        #expect(cellT.attributes.contains(.inverse))

        let cellN = grid[0][3]
        #expect(cellN.grapheme == "N")
        #expect(cellN.foreground == .defaultForeground)
        #expect(cellN.background == .defaultBackground)
        #expect(cellN.attributes.isEmpty)
    }

    // MARK: - 3. VT100 Scroll Regions, Erase Commands & Scrollback Retention

    @Test("VT100 DECSTBM scroll region, ED/EL erase sequences, and scrollback ring retention")
    func vt100ScrollRegionEraseAndScrollback() {
        let buffer = VT100TerminalScreenBuffer(laneID: "lane-agy", rows: 5, columns: 24, maxScrollbackLines: 12)

        for idx in 1...9 {
            buffer.feed("Line-\(idx)" + (idx < 9 ? "\r\n" : ""))
        }
        let afterOverflow = buffer.snapshot()
        #expect(afterOverflow.scrollbackLineCount == 4)
        let scrollback = buffer.recentScrollbackLines(limit: 10)
        #expect(scrollback.count == 4)
        let oldestText = scrollback[0].map(\.grapheme).joined().trimmingCharacters(in: .whitespaces)
        #expect(oldestText == "Line-1")

        // Reset screen, populate pinned top/bottom banners, and set scroll region rows 2..4
        buffer.feed("\u{1B}[2J\u{1B}[1;1HTOP-PINNED-BANNER")
        buffer.feed("\u{1B}[2;1HRegion-A")
        buffer.feed("\u{1B}[3;1HRegion-B")
        buffer.feed("\u{1B}[4;1HRegion-C")
        buffer.feed("\u{1B}[5;1HBOTTOM-STATUS-BAR")
        buffer.feed("\u{1B}[2;4r") // DECSTBM rows 2..4
        buffer.feed("\u{1B}[4;1H\r\nRegion-D")
        buffer.feed("\u{1B}[r") // Reset scroll margins

        let lines = buffer.snapshot().plainTextLines
        #expect(lines[0] == "TOP-PINNED-BANNER")
        #expect(lines[1] == "Region-B")
        #expect(lines[2] == "Region-C")
        #expect(lines[3] == "Region-D")
        #expect(lines[4] == "BOTTOM-STATUS-BAR")

        // Erase from cursor to end of line (\e[K) on row 2 col 7 -> "Region"
        buffer.feed("\u{1B}[2;7H\u{1B}[K")
        #expect(buffer.snapshot().plainTextLines[1] == "Region")

        // Resize terminal and confirm cursor stays clamped inside new bounds
        buffer.resize(rows: 4, columns: 16)
        let resized = buffer.snapshot()
        #expect(resized.rows == 4)
        #expect(resized.columns == 16)
        #expect(resized.cursor.row < 4)
        #expect(resized.cursor.column < 16)
    }

    // MARK: - 4. Real POSIX Pseudo-Terminal Execution (`posix_openpt` + `/bin/echo`)

    @Test("POSIXPseudoTerminalSession executes real /bin/echo over posix_openpt and captures output")
    func posixPseudoTerminalEchoExecution() async throws {
        let session = POSIXPseudoTerminalSession(laneID: "lane-pty-echo", rows: 24, columns: 80)
        defer { session.terminate() }

        final class SnapshotCounter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
        let callbackCounter = SnapshotCounter()
        session.onOutputUpdate = { _ in
            callbackCounter.increment()
        }

        let marker = "RELAY_PTY_ECHO_\(UUID().uuidString.prefix(8))"
        try session.spawn(
            executablePath: "/bin/echo",
            arguments: [marker],
            environmentOverrides: ["RELAY_TEST_MARKER": marker]
        )

        var observedMarker = false
        for _ in 0..<80 {
            let text = session.screenBuffer.snapshot().plainTextLines.joined(separator: "\n")
            if text.contains(marker) {
                observedMarker = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(observedMarker == true)
        #expect(callbackCounter.count >= 1)
        let metrics = session.metrics()
        #expect(metrics.laneID == "lane-pty-echo")
        #expect(metrics.pid > 0)
        #expect(metrics.bytesReadFromPTY >= UInt64(marker.utf8.count))
    }

    // MARK: - 5. Interactive POSIX PTY Stdin Round-Trip & `PTYMultiplexerGrid`

    @Test("POSIXPseudoTerminalSession bidirectional stdin/stdout shell round-trip and PTYMultiplexerGrid lifecycle")
    func posixBidirectionalShellAndMultiplexerGrid() async throws {
        let grid = PTYMultiplexerGrid()
        defer { grid.terminateAll() }

        let session = grid.getOrCreateSession(laneID: "lane-interactive", rows: 24, columns: 90)
        #expect(grid.session(forLane: "lane-interactive") === session)
        #expect(grid.session(forLane: "non-existent") == nil)

        try session.spawn(
            executablePath: "/bin/sh",
            arguments: ["-c", "read line && printf 'ACK:%s\\n' \"$line\""]
        )
        session.resizeTerminal(rows: 30, columns: 100)
        session.sendText("bauhaus-relay\n", asPaste: false)

        var sawAck = false
        for _ in 0..<80 {
            let joined = session.screenBuffer.snapshot().plainTextLines.joined(separator: "\n")
            if joined.contains("ACK:bauhaus-relay") {
                sawAck = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(sawAck == true)
        #expect(session.metrics().bytesWrittenToPTY > 0)
        let allSnaps = grid.allSnapshots()
        #expect(allSnaps.count == 1)
        #expect(allSnaps[0].rows == 30)
        #expect(allSnaps[0].columns == 100)
    }

    // MARK: - 6. Xterm 256-Color Cube, HSL Round-Trip & TrueColor Quantization

    @Test("Xterm256ColorPalette builds 256-entry table, round-trips 6x6x6 cube indices, and quantizes TrueColor")
    func xterm256CubeHSLAndQuantization() {
        let palette = Xterm256ColorPalette(theme: .relayBauhausDark, minimumContrast: .normalTextAA)
        #expect(palette.all256Colors.count == 256)

        // Verify 6x6x6 color cube indices 16..231 round-trip cleanly
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    let idx = Xterm256ColorPalette.encodeCubeIndex(r: r, g: g, b: b)
                    #expect(idx >= 16 && idx <= 231)
                    let decoded = Xterm256ColorPalette.decodeCubeCoordinates(index: idx)
                    #expect(decoded?.r == r)
                    #expect(decoded?.g == g)
                    #expect(decoded?.b == b)
                }
            }
        }
        #expect(Xterm256ColorPalette.decodeCubeCoordinates(index: 7) == nil)
        #expect(Xterm256ColorPalette.decodeCubeCoordinates(index: 240) == nil)

        // Verify grayscale ramp 232..255 strictly increases in luminance
        let darkestGray = palette.color(atPaletteIndex: 232)
        let brightestGray = palette.color(atPaletteIndex: 255)
        #expect(darkestGray.relativeLuminance < brightestGray.relativeLuminance)

        // Hex & HSL round-trip
        let vermilion = RGBATerminalColor(hexString: "#DA3C2A")
        #expect(vermilion != nil)
        if let vermilion {
            #expect(vermilion.hexRGB == "#DA3C2A")
            let hsl = vermilion.toHSL()
            let reconstructed = RGBATerminalColor.fromHSL(
                hue: hsl.hue,
                saturation: hsl.saturation,
                lightness: hsl.lightness
            )
            #expect(abs(Int(reconstructed.r) - Int(vermilion.r)) <= 2)
            #expect(abs(Int(reconstructed.g) - Int(vermilion.g)) <= 2)
            #expect(abs(Int(reconstructed.b) - Int(vermilion.b)) <= 2)

            let q256 = palette.quantizeTrueColorTo256(vermilion, includeSystemANSI16: false)
            #expect(q256 >= 16)
            let q16 = palette.quantizeToANSI16(vermilion)
            #expect(q16 < 16)
        }
    }

    // MARK: - 7. WCAG 2.1 Contrast Clamping & Inverse/Cursor Cell Resolution

    @Test("Xterm256ColorPalette clamps unreadable dark-on-dark foregrounds to WCAG AA (4.5:1) and AAA (7.0:1)")
    func xterm256WCAGContrastClamping() {
        let darkWell = RGBATerminalColor.bauhausDarkWell // #18181B
        let unreadableNavy = RGBATerminalColor(r: 0x1A, g: 0x1E, b: 0x3A)
        let rawContrast = unreadableNavy.contrastRatio(against: darkWell)
        #expect(rawContrast < 2.0)

        let clampedAA = Xterm256ColorPalette.clampForegroundContrast(
            foreground: unreadableNavy,
            againstBackground: darkWell,
            minimumRatio: WCAGContrastTarget.normalTextAA.rawValue
        )
        #expect(clampedAA.contrastRatio(against: darkWell) >= 4.49)

        let clampedAAA = Xterm256ColorPalette.clampForegroundContrast(
            foreground: unreadableNavy,
            againstBackground: darkWell,
            minimumRatio: WCAGContrastTarget.enhancedAAA.rawValue
        )
        #expect(clampedAAA.contrastRatio(against: darkWell) >= 6.98)

        // Resolve cell with low-contrast TrueColor foreground on dark terminal well
        let palette = Xterm256ColorPalette(theme: .relayBauhausDark, minimumContrast: .normalTextAA)
        let lowContrastCell = TerminalCell(
            grapheme: "x",
            foreground: .trueColor(r: 0x1F, g: 0x20, b: 0x26),
            background: .defaultBackground
        )
        let resolved = palette.resolveCellColors(for: lowContrastCell)
        #expect(resolved.wasContrastClamped == true)
        #expect(resolved.contrastRatio >= 4.49)

        // Bold ANSI-8 brightening (index 1 -> index 9)
        let normalRed = palette.resolveRawColor(.ansi16(1), isForeground: true, isBold: false)
        let boldRed = palette.resolveRawColor(.ansi16(1), isForeground: true, isBold: true)
        #expect(normalRed != boldRed)
    }

    // MARK: - 8. `TerminalKeystrokeCodec` Special Keys, Modifiers & DECCKM Mode

    @Test("TerminalKeystrokeCodec encodes special keys, xterm modifier parameters, and DECCKM cursor keys")
    func terminalKeystrokeSpecialKeysAndModifiers() {
        let codec = TerminalKeystrokeCodec()

        // Normal cursor mode vs Application cursor mode (DECCKM)
        let normalUp = codec.encodeSpecialKey(.up, mode: TerminalEncoderModeState(applicationCursorKeys: false))
        let appUp = codec.encodeSpecialKey(.up, mode: TerminalEncoderModeState(applicationCursorKeys: true))
        #expect(String(decoding: normalUp, as: UTF8.self) == "\u{1B}[A")
        #expect(String(decoding: appUp, as: UTF8.self) == "\u{1B}OA")

        // Modified arrow: Shift+Control+Right -> \e[1;6C (1 + shift(1) + ctrl(4) = 6)
        let ctrlShiftRight = codec.encodeSpecialKey(.right, modifiers: [.shift, .control])
        #expect(String(decoding: ctrlShiftRight, as: UTF8.self) == "\u{1B}[1;6C")

        // Function keys F1 (SS3 P) and F5 (CSI 15~)
        #expect(String(decoding: codec.encodeSpecialKey(.f1), as: UTF8.self) == "\u{1B}OP")
        #expect(String(decoding: codec.encodeSpecialKey(.f5), as: UTF8.self) == "\u{1B}[15~")

        // Control+C -> 0x03 (^C)
        let ctrlC = codec.encodeTextKeystroke("c", modifiers: [.control])
        #expect(Array(ctrlC) == [0x03])
        #expect(TerminalKeystrokeCodec.caretNotation(forControlByte: 0x03) == "^C")
    }

    // MARK: - 9. `TerminalKeystrokeCodec` Bracketed Paste Sanitization & SGR 1006 Mouse Round-Trip

    @Test("TerminalKeystrokeCodec sanitizes nested bracketed paste end-markers and round-trips SGR 1006 mouse events")
    func terminalKeystrokeBracketedPasteAndSGRMouseRoundTrip() {
        let codec = TerminalKeystrokeCodec()

        // Malicious/accidental nested \e[201~ inside pasted text must be stripped so paste cannot escape early
        let rawPaste = "line1\r\ninjected\u{1B}[201~escape"
        let encodedPaste = codec.encodeBracketedPaste(
            rawPaste,
            bracketedPasteEnabled: true,
            normalizeCRLFToCR: true,
            sanitizeNestedEndMarkers: true
        )
        let wirePaste = String(decoding: encodedPaste, as: UTF8.self)
        #expect(wirePaste.hasPrefix("\u{1B}[200~"))
        #expect(wirePaste.hasSuffix("\u{1B}[201~"))
        // Only the trailing closing bracket should exist
        let closingOccurrences = wirePaste.components(separatedBy: "\u{1B}[201~").count - 1
        #expect(closingOccurrences == 1)

        // Encode SGR 1006 mouse press, drag, release, and scroll wheel, then decode stream back
        let press = TerminalMouseEvent(button: .left, kind: .press, column: 14, row: 7, modifiers: [.shift])
        let release = TerminalMouseEvent(button: .left, kind: .release, column: 14, row: 7, modifiers: [.shift])
        let wheel = TerminalMouseEvent(button: .wheelUp, kind: .scroll, column: 20, row: 9)

        var combinedStream = Data()
        combinedStream.append(codec.encodeMouseEvent(press))
        combinedStream.append(codec.encodeMouseEvent(release))
        combinedStream.append(codec.encodeMouseEvent(wheel))
        combinedStream.append(codec.encodeFocusEvent(isFocused: true))
        combinedStream.append(encodedPaste)

        let decoded = codec.decodeInputStream(combinedStream)
        #expect(decoded.count == 5)
        #expect(decoded[0] == .mouse(press))
        #expect(decoded[1] == .mouse(release))
        #expect(decoded[2] == .mouse(wheel))
        #expect(decoded[3] == .focusChanged(isFocused: true))
        if case .bracketedPaste(let pastedBody) = decoded[4] {
            #expect(pastedBody.contains("line1"))
            #expect(!pastedBody.contains("\u{1B}[201~"))
        } else {
            Issue.record("Expected .bracketedPaste event at index 4")
        }
    }

    // MARK: - 10. Boyer-Moore Scrollback Search, Regex Captures & Cell Style Filtering

    @Test("TerminalScrollbackSearchEngine executes Boyer-Moore, regex capture, style-filtered search, and cursor cycling")
    func scrollbackSearchBoyerMooreRegexAndStyleFilter() {
        let buffer = VT100TerminalScreenBuffer(laneID: "lane-search", rows: 4, columns: 64, maxScrollbackLines: 50)
        buffer.feed("Booting RelayIDE multiplexer v1.0\r\n")
        buffer.feed("Compiling module RelaySemanticMerge...\r\n")
        buffer.feed("\u{1B}[1;31mERROR[E0425]: unresolved symbol `settleInvoice`\u{1B}[0m\r\n")
        buffer.feed("Warning: retry scheduled in 250ms\r\n")
        buffer.feed("ERROR[E0308]: mismatched types in BillingEngine\r\n")
        buffer.feed("All checks finished.\r\n")
        buffer.feed("Summary: 2 diagnostics emitted")

        let engine = TerminalScrollbackSearchEngine(excerptContextRadius: 24)

        // 1. Case-insensitive Boyer-Moore substring search across scrollback + viewport
        let errorMatches = engine.search(in: buffer, query: "error[e0", mode: .caseInsensitiveSubstring)
        #expect(errorMatches.count == 2)
        #expect(errorMatches[0].origin == .scrollback(offsetFromOldest: 2))

        // 2. Style-filtered search: ONLY bold + ANSI red (index 1) cells
        let boldRedFilter = TerminalCellStyleFilter(
            requiredAttributes: [.bold],
            foregroundANSI16Indices: [1]
        )
        let styledMatches = engine.search(
            in: buffer,
            query: "ERROR",
            mode: .substring,
            styleFilter: boldRedFilter
        )
        #expect(styledMatches.count == 1)
        #expect(styledMatches[0].excerpt.contains("E0425"))

        // 3. Regular expression search with capture groups
        let regexMatches = engine.search(
            in: buffer,
            query: #"ERROR\[(E\d+)\]"#,
            mode: .regularExpression(caseSensitive: true)
        )
        #expect(regexMatches.count == 2)
        #expect(regexMatches[0].captureGroups == ["E0425"])
        #expect(regexMatches[1].captureGroups == ["E0308"])

        // 4. Incremental search cursor wrap-around navigation
        var cursor = TerminalIncrementalSearchCursor(matches: regexMatches)
        #expect(cursor.currentMatch != nil)
        let first = cursor.selectNext()
        let second = cursor.selectNext()
        let back = cursor.selectPrevious()
        #expect(first != second)
        #expect(back == first)
    }

    // MARK: - 11. Clickable URL, Localhost Port & Compiler `file:line:col` Link Detection

    @Test("TerminalClickableLinkDetector extracts web URLs, localhost dev servers, and file:line:col diagnostics")
    func terminalClickableLinkDetectorPatterns() {
        let buffer = VT100TerminalScreenBuffer(laneID: "lane-links", rows: 8, columns: 100)
        buffer.feed("Preview ready at http://localhost:5173/dashboard?lane=codex\r\n")
        buffer.feed("Docs: https://docs.relayide.dev/wiretap/dlp\r\n")
        buffer.feed("Sources/RelaySemanticMerge/BillingEngine.swift:142:19: error: cannot convert value\r\n")
        buffer.feed("src/router/session.ts(88,7): warning TS2322: Type mismatch\r\n")

        let detector = TerminalClickableLinkDetector()
        let links = detector.detectLinks(in: buffer, includeScrollback: true)
        #expect(links.count >= 4)

        let hasLocalhost = links.contains { link in
            if case .localhostPort(_, let host, let port, let path) = link.target {
                return host == "localhost" && port == 5173 && path.hasPrefix("/dashboard")
            }
            return false
        }
        #expect(hasLocalhost == true)

        let hasWebURL = links.contains { link in
            if case .webURL(let url) = link.target {
                return url == "https://docs.relayide.dev/wiretap/dlp"
            }
            return false
        }
        #expect(hasWebURL == true)

        let hasSwiftDiag = links.contains { link in
            if case .workspaceFile(let path, let line, let col, _) = link.target {
                return path.hasSuffix("BillingEngine.swift") && line == 142 && col == 19
            }
            return false
        }
        #expect(hasSwiftDiag == true)
    }

    // MARK: - 12. Asciicast v2 NDJSON Round-Trip, Player Replay & SVG/HTML Transcript Export

    @Test("AsciicastV2Codec round-trips NDJSON recordings, replays keyframes, and exports SVG/HTML transcripts")
    func asciicastV2RoundTripReplayAndTranscriptExport() throws {
        let recorder = AsciicastV2Recorder(
            width: 80,
            height: 24,
            title: "Codex Verification Run",
            command: "swift test",
            idleTimeLimit: 1.5,
            theme: .relayBauhausDark
        )
        recorder.recordOutput("\u{1B}[32m$ swift test\u{1B}[0m\r\n", explicitElapsed: 0.10)
        recorder.recordInput(Data("y\n".utf8), explicitElapsed: 0.35)
        recorder.recordMarker("checkpoint-tests-green", explicitElapsed: 0.80)
        recorder.recordResize(columns: 100, rows: 30, explicitElapsed: 4.50)
        recorder.recordOutput("Test Suite 'All' passed at 21:00\r\n", explicitElapsed: 4.75)

        let recording = recorder.finalizeRecording()
        #expect(recording.events.count == 5)
        #expect(recording.markers.count == 1)
        #expect(recording.markers[0].label == "checkpoint-tests-green")

        let codec = AsciicastV2Codec()
        let ndjson = try codec.encodeNDJSON(recording)
        let decoded = try codec.decodeNDJSON(ndjson)
        #expect(decoded.header.version == 2)
        #expect(decoded.header.width == 80)
        #expect(decoded.header.height == 24)
        #expect(decoded.events == recording.events)

        // Replay up to t=1.0s (before resize & final line) and full replay
        let player = AsciicastV2Player(recording: decoded, laneID: "replay-lane")
        let midReplay = player.replayState(upToSeconds: 1.0)
        #expect(midReplay.activeMarker == "checkpoint-tests-green")
        #expect(midReplay.buffer.snapshot().plainTextLines[0].contains("$ swift test"))

        let schedule = player.buildVariableSpeedSchedule(
            speedMultiplier: 2.0,
            maxIdlePauseSeconds: 1.0,
            keyframeIntervalSeconds: 0.20
        )
        #expect(!schedule.isEmpty)
        // Idle gap between 0.80s and 4.50s (3.70s) clamped to 1.0s then halved at 2x speed -> total playback < 2.0s
        #expect(schedule.last!.scaledPlaybackTime < 2.5)

        // Export SVG and self-contained HTML
        let finalSnap = player.replayState().buffer.snapshot()
        let exporter = TerminalTranscriptExporter()
        let svg = exporter.exportSVG(snapshot: finalSnap)
        let html = exporter.exportHTML(
            snapshot: finalSnap,
            recording: decoded,
            options: TerminalTranscriptExportOptions(title: "Codex Audit", vendorBadge: .codex)
        )
        #expect(svg.contains("<svg"))
        #expect(svg.contains(">swift</tspan>") && svg.contains(">test</tspan>"))
        #expect(html.contains("<!DOCTYPE html>") || html.contains("<html"))
        #expect(html.contains("Codex Audit"))
    }

    // MARK: - 13. `PTYBinarySplitTree` 2x2 Quad & 3x2 Matrix Layout Solving

    @Test("PTYBinarySplitTree constructs 2x2 Quad and 3x2 Matrix presets with non-overlapping pane geometry")
    func ptyBinarySplitTreeQuad2x2AndMatrix3x2Layouts() {
        let quadPanes = [
            PTYPaneDescriptor(paneID: "p-claude", laneID: "lane-claude", vendor: .claudeCode, title: "Claude"),
            PTYPaneDescriptor(paneID: "p-codex", laneID: "lane-codex", vendor: .codex, title: "Codex"),
            PTYPaneDescriptor(paneID: "p-agy", laneID: "lane-agy", vendor: .antigravity, title: "AGY"),
            PTYPaneDescriptor(paneID: "p-vibe", laneID: "lane-vibe", vendor: .mistralVibe, title: "Vibe", isReadOnlyVerifier: true),
        ]
        let viewport = PTYMultiplexerRect(x: 0, y: 0, width: 1600, height: 900)

        let quadTree = PTYBinarySplitTree.makePreset(.quadGrid2x2, panes: quadPanes)
        #expect(quadTree.paneCount == 4)
        let quadSolved = quadTree.solveLayout(in: viewport)
        #expect(quadSolved.panes.count == 4)
        #expect(quadSolved.dividers.count == 3)

        // Verify all 4 panes have positive cols/rows and zero pairwise overlap
        for i in 0..<quadSolved.panes.count {
            #expect(quadSolved.panes[i].columns >= 20)
            #expect(quadSolved.panes[i].rows >= 5)
            for j in (i + 1)..<quadSolved.panes.count {
                let a = quadSolved.panes[i].outerFrame
                let b = quadSolved.panes[j].outerFrame
                let overlapsX = a.minX < b.maxX - 0.01 && b.minX < a.maxX - 0.01
                let overlapsY = a.minY < b.maxY - 0.01 && b.minY < a.maxY - 0.01
                #expect(!(overlapsX && overlapsY))
            }
        }

        // 3x2 Agent Matrix preset -> 6 panes, 5 binary split dividers
        var sixPanes = quadPanes
        sixPanes.append(PTYPaneDescriptor(paneID: "p-shell-1", laneID: "lane-sh1", vendor: .customShell))
        sixPanes.append(PTYPaneDescriptor(paneID: "p-shell-2", laneID: "lane-sh2", vendor: .customShell))

        let matrixTree = PTYBinarySplitTree.makePreset(.matrix3x2, panes: sixPanes)
        #expect(matrixTree.paneCount == 6)
        let matrixSolved = matrixTree.solveLayout(in: viewport)
        #expect(matrixSolved.panes.count == 6)
        #expect(matrixSolved.dividers.count == 5)
    }

    // MARK: - 14. `PTYBinarySplitTree` Divider Drag Resizing, Zoom & Directional Focus

    @Test("PTYBinarySplitTree divider drag resizing, ratio clamping, pane zoom, swap, and neighbor focus")
    func ptyBinarySplitTreeResizingZoomAndNeighborFocus() {
        let panes = [
            PTYPaneDescriptor(paneID: "tl", laneID: "l1", vendor: .claudeCode),
            PTYPaneDescriptor(paneID: "tr", laneID: "l2", vendor: .codex),
            PTYPaneDescriptor(paneID: "bl", laneID: "l3", vendor: .antigravity),
            PTYPaneDescriptor(paneID: "br", laneID: "l4", vendor: .mistralVibe),
        ]
        var tree = PTYBinarySplitTree.makePreset(.quadGrid2x2, panes: panes)
        let viewport = PTYMultiplexerRect(x: 0, y: 0, width: 1200, height: 800)

        let initialLayout = tree.solveLayout(in: viewport)
        let rootDivider = initialLayout.dividers[0]
        let draggedRatio = rootDivider.ratioAfterDragging(deltaPixels: 180.0)
        #expect(draggedRatio > rootDivider.ratio)

        #expect(tree.setSplitRatio(splitID: rootDivider.splitID, ratio: draggedRatio) == true)
        // Extreme ratio (0.99) must clamp to <= PTYBinarySplitTree.maxSplitRatio (0.90)
        #expect(tree.setSplitRatio(splitID: rootDivider.splitID, ratio: 0.99) == true)
        let clampedDivider = tree.solveLayout(in: viewport).dividers.first { $0.splitID == rootDivider.splitID }!
        #expect(clampedDivider.ratio <= PTYBinarySplitTree.maxSplitRatio + 0.001)

        tree.equalizeSplitRatios()
        #expect(abs(tree.solveLayout(in: viewport).dividers[0].ratio - 0.50) < 0.001)

        // Focus top-left, navigate right and down
        #expect(tree.focusPane("tl") == true)
        let rightNeighbor = tree.focusNeighbor(in: .right, viewport: viewport)
        #expect(rightNeighbor == "tr")
        let downNeighbor = tree.focusNeighbor(in: .down, viewport: viewport)
        #expect(downNeighbor == "br")

        // Zoom single pane -> visiblePanes count becomes 1
        let zoomed = tree.toggleZoom(forPane: "br")
        #expect(zoomed == "br")
        let zoomedLayout = tree.solveLayout(in: viewport)
        #expect(zoomedLayout.visiblePanes.count == 1)
        #expect(zoomedLayout.visiblePanes[0].pane.paneID == "br")
        tree.unzoom()
        #expect(tree.solveLayout(in: viewport).visiblePanes.count == 4)

        // Swap panes and close pane
        #expect(tree.swapPanes("tl", "br") == true)
        #expect(tree.closePane("tr") == true)
        #expect(tree.paneCount == 3)
    }

    // MARK: - 15. `PTYBroadcastInputFilter` Read-Only Exclusion & Destructive Command Guard

    @Test("PTYBroadcastInputFilter blocks destructive shell commands and skips read-only verifier lanes")
    func ptyBroadcastSafetyFilterAndReadOnlyExclusion() {
        let panes = [
            PTYPaneDescriptor(paneID: "p1", laneID: "lane-claude", vendor: .claudeCode, isReadOnlyVerifier: false),
            PTYPaneDescriptor(paneID: "p2", laneID: "lane-codex", vendor: .codex, isReadOnlyVerifier: false),
            PTYPaneDescriptor(paneID: "p3", laneID: "lane-agy", vendor: .antigravity, isReadOnlyVerifier: false),
            PTYPaneDescriptor(paneID: "p4", laneID: "lane-vibe-ro", vendor: .mistralVibe, isReadOnlyVerifier: true),
        ]
        let tree = PTYBinarySplitTree.makePreset(.quadGrid2x2, panes: panes)

        let allWritableFilter = PTYBroadcastInputFilter(scope: .allWritableAgentPanes)
        let safeReceipt = allWritableFilter.evaluateAndDispatch(
            inputData: Data("git status --short\n".utf8),
            in: tree
        )
        #expect(safeReceipt.wasBlocked == false)
        #expect(Set(safeReceipt.deliveredLaneIDs) == Set(["lane-claude", "lane-codex", "lane-agy"]))
        #expect(safeReceipt.skippedReadOnlyLaneIDs == ["lane-vibe-ro"])

        // Destructive payload must be vetoed across all lanes
        let blockedReceipt = allWritableFilter.evaluateAndDispatch(
            inputData: Data("sudo rm -rf / --no-preserve-root\n".utf8),
            in: tree
        )
        #expect(blockedReceipt.wasBlocked == true)
        #expect(blockedReceipt.deliveredLaneIDs.isEmpty)
        #expect(blockedReceipt.blockedByPolicyReason != nil)
    }

    // MARK: - 16. `PTYByteRingBuffer` Watermarks, Overflow Drop-Oldest & Frame Coalescer

    @Test("PTYByteRingBuffer enforces watermarks, drops oldest bytes on overflow, and coalesces 60Hz ticks")
    func ptyByteRingBufferAndOutputFrameCoalescer() {
        var ring = PTYByteRingBuffer(minimumCapacity: 1024)
        let chunkA = Data(repeating: 0x41, count: 900)
        let chunkB = Data(repeating: 0x42, count: 500)

        _ = ring.enqueue(chunkA)
        let afterATelemetry = ring.telemetry()
        #expect(afterATelemetry.readableBytes == 900)
        #expect(afterATelemetry.isBackpressured == true)

        // Overflow past capacity with dropOldestOnOverflow: true
        _ = ring.enqueue(chunkB, dropOldestOnOverflow: true)
        let overflowTelemetry = ring.telemetry()
        #expect(overflowTelemetry.readableBytes <= overflowTelemetry.capacityBytes)
        #expect(overflowTelemetry.totalBytesDropped > 0)

        let drained = ring.dequeue(maxBytes: 2048)
        #expect(drained.suffix(500) == chunkB)
        #expect(ring.telemetry().readableBytes == 0)

        // Verify PTYOutputFrameCoalescer batches multiple burst writes into a single VT100 snapshot frame
        let coalescer = PTYOutputFrameCoalescer(
            targetFramesPerSecond: 60,
            maxBytesPerLanePerFrame: 4096,
            ringBufferCapacityPerLane: 16_384
        )
        let screen = VT100TerminalScreenBuffer(laneID: "lane-burst", rows: 10, columns: 60)
        coalescer.registerLane(laneID: "lane-burst", screenBuffer: screen)
        coalescer.enqueueOutput(laneID: "lane-burst", data: Data("\u{1B}[32mPart-1 ".utf8))
        coalescer.enqueueOutput(laneID: "lane-burst", data: Data("Part-2 ".utf8))
        coalescer.enqueueOutput(laneID: "lane-burst", data: Data("Part-3\u{1B}[0m".utf8))

        let updates = coalescer.flushFrameTick()
        #expect(updates.count == 1)
        #expect(updates[0].laneID == "lane-burst")
        #expect(updates[0].coalescedWriteCount == 3)
        #expect(updates[0].snapshot.plainTextLines[0].contains("Part-1 Part-2 Part-3"))
    }

    // MARK: - 17. Wide CJK Grapheme Cells & VT100 Cursor Column Advancement

    @Test("VT100TerminalScreenBuffer handles multi-byte UTF-8 and wide CJK characters without corrupting grid")
    func vt100UTF8AndWideGraphemeHandling() {
        let buffer = VT100TerminalScreenBuffer(laneID: "lane-utf8", rows: 6, columns: 40)
        // Feed split UTF-8 byte slices across chunk boundaries
        let fullText = "Relay 构建审计 ✓ OK"
        let bytes = Array(fullText.utf8)
        for idx in stride(from: 0, to: bytes.count, by: 2) {
            let slice = Data(bytes[idx..<min(idx + 2, bytes.count)])
            buffer.feed(slice)
        }

        let line = buffer.snapshot().plainTextLines[0]
        #expect(line.contains("Relay"))
        #expect(line.contains("OK"))
    }

    // MARK: - 18. `TerminalSearchMode` Whole-Word Case Sensitivity & Edge Boundaries

    @Test("TerminalScrollbackSearchEngine enforces whole-word boundaries and case-sensitivity options")
    func scrollbackWholeWordAndCaseSensitivity() {
        let lines = [
            TerminalSearchableLine(lineIndex: 0, origin: .activeViewport(row: 0), rawString: "lane laneID Sublane LANE"),
            TerminalSearchableLine(lineIndex: 1, origin: .activeViewport(row: 1), rawString: "merge_lane and lane-codex"),
        ]
        let engine = TerminalScrollbackSearchEngine()

        let exactWordCS = engine.search(lines: lines, query: "lane", mode: .wholeWord(caseSensitive: true))
        // Matches standalone `lane` on line 0 and `lane` before `-codex` on line 1, excluding `laneID`, `Sublane`, `LANE`, `merge_lane`
        #expect(exactWordCS.count == 2)

        let exactWordCI = engine.search(lines: lines, query: "lane", mode: .wholeWord(caseSensitive: false))
        #expect(exactWordCI.count == 3)
    }

    // MARK: - 19. `PTYMultiplexerLayoutCoordinator` End-to-End Sync

    @Test("PTYMultiplexerLayoutCoordinator synchronizes preset geometry with live multiplexer grid dimensions")
    func multiplexerLayoutCoordinatorSyncsGrid() {
        let panes = [
            PTYPaneDescriptor(paneID: "a", laneID: "lane-a", vendor: .claudeCode),
            PTYPaneDescriptor(paneID: "b", laneID: "lane-b", vendor: .codex),
        ]
        let coordinator = PTYMultiplexerLayoutCoordinator(preset: .sideBySide, initialPanes: panes)
        defer { coordinator.grid.terminateAll() }

        let layout = coordinator.relayoutAndSyncTerminalSizes(
            in: PTYMultiplexerRect(x: 0, y: 0, width: 1000, height: 600),
            cellWidth: 8.0,
            cellHeight: 18.0
        )
        #expect(layout.panes.count == 2)
        let snapA = coordinator.grid.session(forLane: "lane-a")?.screenBuffer.snapshot()
        #expect(snapA?.columns == layout.panes[0].columns)
        #expect(snapA?.rows == layout.panes[0].rows)

        coordinator.mutateTree { tree in
            _ = tree.splitPane(
                targetPaneID: "b",
                axis: .vertical,
                newPane: PTYPaneDescriptor(paneID: "c", laneID: "lane-c", vendor: .antigravity)
            )
        }
        let updated = coordinator.relayoutAndSyncTerminalSizes(
            in: PTYMultiplexerRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(updated.panes.count == 3)
    }

    // MARK: - 20. Palette Themes & RGBA Alpha Compositing Invariants

    @Test("TerminalPaletteTheme built-in presets satisfy contrast invariants and RGBA alpha compositing")
    func paletteThemePresetsAndAlphaCompositing() {
        let themes: [TerminalPaletteTheme] = [.relayBauhausDark, .classicXtermDark, .highContrastAAA]
        for theme in themes {
            #expect(theme.ansi16.count == 16)
            let fgBgContrast = theme.defaultForeground.contrastRatio(against: theme.defaultBackground)
            #expect(fgBgContrast >= 7.0)
        }

        let overlay = RGBATerminalColor.bauhausSelection // semi-transparent cobalt
        let composited = overlay.composited(over: .bauhausDarkWell)
        #expect(composited.a == 255)
        #expect(composited.b > RGBATerminalColor.bauhausDarkWell.b)

        let midpoint = RGBATerminalColor(r: 0, g: 0, b: 0).interpolated(
            toward: RGBATerminalColor(r: 200, g: 100, b: 50),
            fraction: 0.5
        )
        #expect(abs(Int(midpoint.r) - 100) <= 1)
        #expect(abs(Int(midpoint.g) - 50) <= 1)
    }

    // MARK: - M0 Rework (R31): Error Text Names the PTY Call That Is Actually Used

    @Test("ptyAllocationFailed error text names posix_openpt, the call the implementation uses, not forkpty (R31)")
    func ptyAllocationErrorNamesPosixOpenpt() throws {
        let err = RelayIDEError.ptyAllocationFailed(errnoCode: 24, message: "Too many open files")
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let text = err.localizedDescription(in: lang)
            #expect(!text.contains("forkpty"), "\(lang.rawValue): \(text)")
            #expect(text.contains("posix_openpt"), "\(lang.rawValue): \(text)")
            #expect(text.contains("errno 24"))
            #expect(text.contains("Too many open files"))
        }
        #expect(err.errorDescription?.contains("posix_openpt") == true)

        // The implementation really is posix_openpt + posix_spawn, and nothing shipped in the repository says forkpty.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let session = try String(contentsOf: root.appendingPathComponent("Sources/RelayPTYCore/POSIXPseudoTerminalSession.swift"), encoding: .utf8)
        #expect(session.contains("Darwin.posix_openpt("))
        #expect(!session.contains("forkpty("))

        var mentions: [String] = []
        var candidates = [root.appendingPathComponent("README.md"), root.appendingPathComponent("README.zh-CN.md")]
        let sources = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        for case let url as URL in sources where url.pathExtension == "swift" {
            candidates.append(url)
        }
        for url in candidates {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("fork" + "pty") {
                mentions.append(url.lastPathComponent)
            }
        }
        #expect(mentions.isEmpty, "these files still say forkpty: \(mentions)")
    }

    // MARK: - M1 Stage 01: PTY Exit Status, Process-Group Termination, Re-Spawn Guard & Raw Transcript (R32-R35)

    private static var fakeRelayPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Support/fake-relay.sh")
            .path
    }

    @Test("POSIXPseudoTerminalSession decodes exit codes vs termination signals without recording signal death as 0 (R32)")
    func ptyDecodesExitStatusAndSignalDeath() async throws {
        // 1. Normal exits: exit 7 and exit 124 are preserved verbatim.
        for expectedCode: Int32 in [7, 124] {
            let session = POSIXPseudoTerminalSession(laneID: "lane-exit-\(expectedCode)")
            defer { session.terminate() }
            try session.spawn(
                executablePath: Self.fakeRelayPath,
                arguments: ["--relay-message", "step finished with \(expectedCode)", "--exit", "\(expectedCode)"]
            )
            for _ in 0..<200 {
                if !session.metrics().isRunning { break }
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            let m = session.metrics()
            #expect(m.isRunning == false)
            #expect(m.exitStatus == expectedCode)
            #expect(m.terminationSignal == nil)
            #expect(m.exitReason == .exited(code: expectedCode))
            #expect(m.terminationDescription == nil)
        }

        // 2. Signal deaths: SIGKILL (9), SIGTERM (15), SIGINT (2) must NEVER record exitStatus == 0 (exitStatus must be nil).
        for (sigName, sigNum) in [("KILL", SIGKILL), ("TERM", SIGTERM), ("INT", SIGINT)] {
            let session = POSIXPseudoTerminalSession(laneID: "lane-sig-\(sigName)")
            defer { session.terminate() }
            try session.spawn(
                executablePath: Self.fakeRelayPath,
                arguments: ["--kill-self", sigName]
            )
            for _ in 0..<200 {
                if !session.metrics().isRunning { break }
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            let m = session.metrics()
            #expect(m.isRunning == false, "Expected session killed by SIG\(sigName) (\(sigNum)) to stop running")
            #expect(m.exitStatus == nil, "Process killed by SIG\(sigName) (\(sigNum)) must have nil exitStatus, got \(String(describing: m.exitStatus))")
            #expect(m.terminationSignal == sigNum)
            #expect(m.exitReason == .signaled(signal: sigNum))
            #expect(m.terminationDescription == "被信号 \(sigNum) 终止")
            #expect(m.exitReason?.localizedDescription(in: .zhHans) == "被信号 \(sigNum) 终止")
            #expect(m.exitReason?.localizedDescription(in: .en) == "terminated by signal \(sigNum)")
        }
    }

    @Test("POSIXWaitStatus bit decoders match <sys/wait.h> and waitForChildExit retries EINTR (R32)")
    func posixWaitStatusMacrosAndEINTRRetry() {
        // Normal exit statuses 0..255: (code << 8)
        for code: Int32 in [0, 1, 2, 7, 124, 125, 130, 137, 255] {
            let raw = code << 8
            #expect(POSIXWaitStatus.wifExited(raw) == true)
            #expect(POSIXWaitStatus.wExitStatus(raw) == code)
            #expect(POSIXWaitStatus.wifSignaled(raw) == false)
            #expect(POSIXWaitStatus.wifStopped(raw) == false)
            #expect(POSIXWaitStatus.decode(raw) == .exited(code: code))
        }

        // Signal deaths with and without WCOREFLAG (0x80)
        for sig: Int32 in [SIGHUP, SIGINT, SIGKILL, SIGTERM, SIGALRM] {
            for coreFlag: Int32 in [0, 0x80] {
                let raw = sig | coreFlag
                #expect(POSIXWaitStatus.wifExited(raw) == false)
                #expect(POSIXWaitStatus.wifSignaled(raw) == true)
                #expect(POSIXWaitStatus.wTermSig(raw) == sig)
                #expect(POSIXWaitStatus.wifStopped(raw) == false)
                #expect(POSIXWaitStatus.decode(raw) == .signaled(signal: sig))
                #expect(POSIXWaitStatus.decode(raw).exitCode == nil)
            }
        }

        // _WSTOPPED (0x7F) must not be misclassified as WIFSIGNALED or WIFEXITED
        let stoppedRaw: Int32 = (SIGSTOP << 8) | 0x7F
        #expect(POSIXWaitStatus.wifExited(stoppedRaw) == false)
        #expect(POSIXWaitStatus.wifSignaled(stoppedRaw) == false)
        #expect(POSIXWaitStatus.wifStopped(stoppedRaw) == true)

        // waitForChildExit retries on EINTR (even when status stays 0) and ignores transient WIFSTOPPED
        var attempts = 0
        let outcome = POSIXPseudoTerminalSession.waitForChildExit(pid: 4242) { pid, statusPtr, _ in
            attempts += 1
            switch attempts {
            case 1, 2:
                return (-1, EINTR)
            case 3:
                statusPtr?.pointee = (SIGSTOP << 8) | 0x7F
                return (pid, 0)
            default:
                statusPtr?.pointee = SIGKILL // raw status 9 -> WIFSIGNALED, WTERMSIG=9
                return (pid, 0)
            }
        }
        #expect(attempts == 4)
        #expect(outcome == .signaled(signal: SIGKILL))
        #expect(outcome.exitCode == nil)

        // Non-EINTR failure (e.g. ECHILD) never masquerades as exit 0
        let failedOutcome = POSIXPseudoTerminalSession.waitForChildExit(pid: 9999) { _, _, _ in
            (-1, ECHILD)
        }
        #expect(failedOutcome == .waitFailed(errnoCode: ECHILD))
        #expect(failedOutcome.exitCode == nil)
    }

    @Test("POSIXPseudoTerminalSession.terminate signals the process group and waits for real exit before reporting not running (R33)")
    func ptyTerminateSignalsProcessGroupAndWaitsForRealExit() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-pty-r33-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let readyFile = tmpDir.appendingPathComponent("ready")
        let childPIDFile = tmpDir.appendingPathComponent("group-child.pid")

        let session = POSIXPseudoTerminalSession(laneID: "lane-r33-term")
        var trackedGroupChildPID: pid_t = -1
        var trackedLeaderPID: pid_t = -1
        defer {
            if trackedGroupChildPID > 0 { _ = Darwin.kill(trackedGroupChildPID, SIGKILL) }
            if trackedLeaderPID > 0 { _ = Darwin.kill(-trackedLeaderPID, SIGKILL) }
            session.terminate(signal: SIGKILL)
        }

        try session.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: [
                "--child-pid-file", childPIDFile.path,
                "--slow-term", "0.18",
                "--ready-file", readyFile.path,
                "--sleep", "30"
            ]
        )

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: readyFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: readyFile.path))

        let leaderPID = session.metrics().pid
        trackedLeaderPID = leaderPID
        let rawGroupPID = try String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let groupChildPID = try #require(pid_t(rawGroupPID))
        trackedGroupChildPID = groupChildPID

        #expect(Darwin.kill(leaderPID, 0) == 0)
        #expect(Darwin.kill(groupChildPID, 0) == 0)
        #expect(session.metrics().isRunning == true)

        session.terminate(signal: SIGTERM)

        let leaderAliveAfterTerminate = (Darwin.kill(leaderPID, 0) == 0)
        let groupChildAliveAfterTerminate = (Darwin.kill(groupChildPID, 0) == 0)
        let afterMetrics = session.metrics()

        #expect(afterMetrics.isRunning == false)
        #expect(leaderAliveAfterTerminate == false, "Leader process \(leaderPID) was still alive after terminate() returned")
        #expect(groupChildAliveAfterTerminate == false, "Process-group child \(groupChildPID) survived terminate() because signal was not sent to -pgid")
        #expect(afterMetrics.exitStatus == nil)
        #expect(afterMetrics.terminationSignal == SIGTERM)
        #expect(afterMetrics.terminationDescription == "被信号 \(SIGTERM) 终止")
    }

    @Test("POSIXPseudoTerminalSession.spawn throws when called on an already-running session instead of silently returning (R34)")
    func ptySecondSpawnWhileRunningThrows() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-pty-r34-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let readyFile = tmpDir.appendingPathComponent("ready")
        let session = POSIXPseudoTerminalSession(laneID: "lane-r34-respawn")
        defer { session.terminate() }

        try session.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--ready-file", readyFile.path, "--sleep", "10"]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: readyFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstPID = session.metrics().pid
        #expect(firstPID > 0)
        #expect(session.metrics().isRunning == true)

        #expect(throws: RelayIDEError.ptySessionAlreadyRunning(laneID: "lane-r34-respawn", pid: firstPID)) {
            try session.spawn(
                executablePath: Self.fakeRelayPath,
                arguments: ["--exit", "0"]
            )
        }

        // First child must remain running and undisturbed until terminated.
        #expect(session.metrics().pid == firstPID)
        #expect(session.metrics().isRunning == true)
        #expect(Darwin.kill(firstPID, 0) == 0)

        // Once terminated, spawning a fresh process on the stopped session succeeds cleanly.
        session.terminate()
        #expect(session.metrics().isRunning == false)
        try session.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--exit", "7"]
        )
        #expect(session.waitForExit(timeout: 5.0) == true)
        #expect(session.metrics().exitStatus == 7)
    }

    @Test("POSIXPseudoTerminalSession appends every byte read from master FD verbatim to rawOutputFilePath while preserving screenBuffer (R35)")
    func ptyAppendsVerbatimBytesToRawTranscriptAndPreservesScreenBuffer() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-pty-r35-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let rawTranscriptURL = tmpDir.appendingPathComponent("lanes/api.pty")
        let args = [
            "--relay-message", "not sent: prompt contains secret (line 1)",
            "--stdout", "Hello-PTY-Line-1",
            "--repeat-bytes", "65536",
            "--exit", "2"
        ]

        // Control session without rawOutputFilePath
        let controlSession = POSIXPseudoTerminalSession(laneID: "lane-r35-control", rows: 24, columns: 80)
        defer { controlSession.terminate() }
        try controlSession.spawn(executablePath: Self.fakeRelayPath, arguments: args)
        #expect(controlSession.waitForExit(timeout: 10.0) == true)

        // Recorded session with rawOutputFilePath
        let recordedSession = POSIXPseudoTerminalSession(laneID: "lane-r35-recorded", rows: 24, columns: 80)
        defer { recordedSession.terminate() }
        try recordedSession.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: args,
            rawOutputFilePath: rawTranscriptURL.path
        )
        #expect(recordedSession.waitForExit(timeout: 10.0) == true)

        let metrics = recordedSession.metrics()
        #expect(metrics.exitStatus == 2)
        #expect(metrics.bytesReadFromPTY > 65_536)
        #expect(FileManager.default.fileExists(atPath: rawTranscriptURL.path) == true)

        let rawData = try Data(contentsOf: rawTranscriptURL)
        #expect(rawData.count == Int(metrics.bytesReadFromPTY))

        let rawText = String(decoding: rawData, as: UTF8.self)
        #expect(rawText.contains("relay: not sent: prompt contains secret (line 1)\r\n"))
        #expect(rawText.contains("Hello-PTY-Line-1\r\n"))

        // ScreenBuffer snapshot and scrollback must match the control session identically.
        #expect(recordedSession.screenBuffer.snapshot().plainTextLines == controlSession.screenBuffer.snapshot().plainTextLines)
        #expect(recordedSession.screenBuffer.snapshot().scrollbackLineCount == controlSession.screenBuffer.snapshot().scrollbackLineCount)

        // Appending mode: running another session pointing to the same raw file appends bytes verbatim.
        let secondSession = POSIXPseudoTerminalSession(laneID: "lane-r35-append", rows: 24, columns: 80)
        defer { secondSession.terminate() }
        try secondSession.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--relay-message", "second-pass", "--exit", "0"],
            rawOutputFilePath: rawTranscriptURL.path
        )
        #expect(secondSession.waitForExit(timeout: 10.0) == true)
        let secondMetrics = secondSession.metrics()
        let combinedData = try Data(contentsOf: rawTranscriptURL)
        #expect(combinedData.count == Int(metrics.bytesReadFromPTY + secondMetrics.bytesReadFromPTY))
        #expect(combinedData.starts(with: rawData))
    }

    // MARK: - M1 Stage 02: Stub Agent Test Double (`Tests/Support/stub-agent.sh`)

    private static var stubAgentPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Support/stub-agent.sh")
            .path
    }

    private struct StubInvocationResult {
        let exitCode: Int32
        let terminationReason: Process.TerminationReason
        let stdout: String
        let stderr: String
        let pid: Int32
    }

    private static func makeIsolatedDecoyEnvironment(in rootDir: URL, extraEnv: [String: String] = [:]) throws -> (env: [String: String], decoyMarker: URL) {
        let homeDir = rootDir.appendingPathComponent("isolated-home", isDirectory: true)
        let decoyBinDir = rootDir.appendingPathComponent("decoy-bin", isDirectory: true)
        let decoyMarker = rootDir.appendingPathComponent("decoy-invoked.marker")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyBinDir, withIntermediateDirectories: true)

        for name in ["claude", "codex", "agy", "vibe"] {
            let scriptURL = decoyBinDir.appendingPathComponent(name)
            let script = """
            #!/bin/sh
            printf '%s\\n' "\(name)" >> "\(decoyMarker.path)"
            exit 99
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = homeDir.path
        env["CFFIXED_USER_HOME"] = homeDir.path
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(decoyBinDir.path):\(basePath)"
        for (k, v) in extraEnv {
            env[k] = v
        }
        return (env, decoyMarker)
    }

    private static func runStubProcess(
        arguments: [String],
        stdinString: String? = nil,
        workingDirectory: URL,
        environment: [String: String],
        scratchDir: URL
    ) throws -> StubInvocationResult {
        let id = UUID().uuidString
        let outURL = scratchDir.appendingPathComponent("stdout-\(id).txt")
        let errURL = scratchDir.appendingPathComponent("stderr-\(id).txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.stubAgentPath)
        proc.arguments = arguments
        proc.currentDirectoryURL = workingDirectory
        proc.environment = environment
        proc.standardOutput = outHandle
        proc.standardError = errHandle

        var inPipe: Pipe?
        if stdinString != nil {
            let pipe = Pipe()
            proc.standardInput = pipe
            inPipe = pipe
        } else {
            proc.standardInput = FileHandle.nullDevice
        }

        try proc.run()
        let childPID = proc.processIdentifier
        if let stdinString, let pipe = inPipe {
            try pipe.fileHandleForWriting.write(contentsOf: Data(stdinString.utf8))
            try pipe.fileHandleForWriting.close()
        }
        proc.waitUntilExit()

        let outText = try String(contentsOf: outURL, encoding: .utf8)
        let errText = try String(contentsOf: errURL, encoding: .utf8)
        return StubInvocationResult(
            exitCode: proc.terminationStatus,
            terminationReason: proc.terminationReason,
            stdout: outText,
            stderr: errText,
            pid: childPID
        )
    }

    @Test("stub-agent.sh recognizes all four vendor argv shapes and emits each vendor's expected structured output")
    func stubAgentRecognizesFourVendorArgvShapesAndFormatsOutput() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-stub-vendors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(FileManager.default.isExecutableFile(atPath: Self.stubAgentPath) == true, "Missing executable stub-agent.sh")

        let (env, decoyMarker) = try Self.makeIsolatedDecoyEnvironment(in: tmpDir)

        // 1. claude: `-p --permission-mode acceptEdits --output-format json --model ...` with prompt on stdin
        let claudeWorkdir = tmpDir.appendingPathComponent("worktrees/lane-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeWorkdir, withIntermediateDirectories: true)
        let claudeRes = try Self.runStubProcess(
            arguments: ["-p", "--permission-mode", "acceptEdits", "--output-format", "json", "--model", "claude-opus-5-5"],
            stdinString: "Implement API handler.\nSTUB COST 0.0123\n",
            workingDirectory: claudeWorkdir,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(claudeRes.terminationReason == .exit)
        #expect(claudeRes.exitCode == 0)
        let claudeJSON = try #require(JSONSerialization.jsonObject(with: Data(claudeRes.stdout.utf8)) as? [String: Any])
        let claudeResultText = try #require(claudeJSON["result"] as? String)
        let claudeCost = try #require(claudeJSON["total_cost_usd"] as? Double)
        #expect(claudeResultText.contains("STATUS: success"))
        #expect(abs(claudeCost - 0.0123) < 0.000001)
        #expect((claudeJSON["is_error"] as? Bool) == false)

        // 2. codex: `exec -C <dir> -s workspace-write --skip-git-repo-check -o <out> -` with prompt on stdin
        let codexWorkdir = tmpDir.appendingPathComponent("worktrees/lane-codex", isDirectory: true)
        let callerCwd = tmpDir.appendingPathComponent("caller-cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: codexWorkdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: callerCwd, withIntermediateDirectories: true)
        let codexOutFile = tmpDir.appendingPathComponent("codex-final.out.md")
        let codexRes = try Self.runStubProcess(
            arguments: [
                "exec", "-C", codexWorkdir.path,
                "-s", "workspace-write", "--skip-git-repo-check",
                "-o", codexOutFile.path, "-"
            ],
            stdinString: "Implement codex step.\nSTUB TOKENS 2345\n",
            workingDirectory: callerCwd,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(codexRes.terminationReason == .exit)
        #expect(codexRes.exitCode == 0)
        let codexFinalMsg = try String(contentsOf: codexOutFile, encoding: .utf8)
        #expect(codexFinalMsg.contains("STATUS: success"))
        #expect(codexRes.stdout.contains("session id: "))
        #expect(codexRes.stdout.contains("tokens used\n2,345"))

        // 3. agy: `-p <prompt-string> --mode accept-edits --output-format json --model ... --settings ...` (even if prompt begins with `-`)
        let agyWorkdir = tmpDir.appendingPathComponent("worktrees/lane-agy", isDirectory: true)
        try FileManager.default.createDirectory(at: agyWorkdir, withIntermediateDirectories: true)
        let agyPrompt = "-- bullet heading prompt\nSTUB TOKENS 3456\n"
        let agyRes = try Self.runStubProcess(
            arguments: [
                "-p", agyPrompt,
                "--mode", "accept-edits",
                "--output-format", "json",
                "--model", "gemini-4-carbon-high",
                "--settings", "{\"permissions\":{\"allow\":[\"command(ls)\"]}}"
            ],
            stdinString: nil,
            workingDirectory: agyWorkdir,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(agyRes.terminationReason == .exit)
        #expect(agyRes.exitCode == 0)
        let agyJSON = try #require(JSONSerialization.jsonObject(with: Data(agyRes.stdout.utf8)) as? [String: Any])
        #expect((agyJSON["status"] as? String) == "SUCCESS")
        let agyResponse = try #require(agyJSON["response"] as? String)
        #expect(agyResponse.contains("STATUS: success"))
        let agyUsage = try #require(agyJSON["usage"] as? [String: Any])
        #expect((agyUsage["total_tokens"] as? Int) == 3456)
        #expect((agyJSON["denied_actions"] as? [Any])?.isEmpty == true)

        // 4. vibe: `--workdir <dir> --trust --prompt-file <prompt> --output json --output-dir <vd> --max-price 2 --time-limit 1770`
        let vibeWorkdir = tmpDir.appendingPathComponent("worktrees/lane-vibe", isDirectory: true)
        let vibeOutputDir = tmpDir.appendingPathComponent("vibe-out", isDirectory: true)
        try FileManager.default.createDirectory(at: vibeWorkdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vibeOutputDir, withIntermediateDirectories: true)
        let vibePromptFile = tmpDir.appendingPathComponent("vibe-prompt.md")
        try "Write unit tests.\nSTUB COST 0.0456\n".write(to: vibePromptFile, atomically: true, encoding: .utf8)
        let vibeRes = try Self.runStubProcess(
            arguments: [
                "--workdir", vibeWorkdir.path,
                "--trust",
                "--prompt-file", vibePromptFile.path,
                "--output", "json",
                "--output-dir", vibeOutputDir.path,
                "--max-price", "2",
                "--time-limit", "1770"
            ],
            stdinString: nil,
            workingDirectory: callerCwd,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(vibeRes.terminationReason == .exit)
        #expect(vibeRes.exitCode == 0)
        let vibeMessages = try #require(JSONSerialization.jsonObject(with: Data(vibeRes.stdout.utf8)) as? [[String: Any]])
        let lastAssistant = try #require(vibeMessages.last { ($0["type"] as? String) == "message" && ($0["role"] as? String) == "assistant" })
        let vibeContent = try #require(lastAssistant["content"] as? String)
        #expect(vibeContent.contains("STATUS: success"))

        let exportData = try Data(contentsOf: vibeOutputDir.appendingPathComponent("export.json"))
        let exportJSON = try #require(JSONSerialization.jsonObject(with: exportData) as? [String: Any])
        #expect((exportJSON["outcome"] as? String) == "finished")
        let vibeCost = try #require(exportJSON["cost_usd"] as? Double)
        #expect(abs(vibeCost - 0.0456) < 0.000001)
        let vibeConfig = try #require(exportJSON["config"] as? [String: Any])
        #expect(((vibeConfig["active_model"] as? String) ?? "").isEmpty == false)

        #expect(FileManager.default.fileExists(atPath: decoyMarker.path) == false)
    }

    private static func listProcessesMatching(_ needle: String) throws -> [(pid: Int32, ppid: Int32, command: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        var results: [(pid: Int32, ppid: Int32, command: String)] = []
        for rawLine in output.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(needle) else { continue }
            let parts = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            results.append((pid: pid, ppid: ppid, command: String(parts[2])))
        }
        return results
    }

    @Test("stub-agent.sh executes WRITE, APPEND, WRITE_BLOCK, SLEEP, WAIT barrier, EXIT, KILL_SELF, COST, STATUS, and NO_JSON directives")
    func stubAgentExecutesAllDirectivesAndTagsLongRunningChildren() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-stub-directives-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let traceDir = tmpDir.appendingPathComponent("traces-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let (env, decoyMarker) = try Self.makeIsolatedDecoyEnvironment(
            in: tmpDir,
            extraEnv: ["STUB_TRACE_DIR": traceDir.path]
        )

        // 1. WRITE / APPEND / WRITE_BLOCK + literal preservation + STATUS: partial & STATUS: failed
        let workdirWrite = tmpDir.appendingPathComponent("worktrees/lane-write", isDirectory: true)
        try FileManager.default.createDirectory(at: workdirWrite, withIntermediateDirectories: true)
        let writePrompt = """
        Regular prose line ignored by stub parser.
        STUB WRITE nested/dir/single.txt hello $NOT_EXPANDED world
        STUB WRITE nested/dir/multi.txt line-1
        STUB APPEND nested/dir/multi.txt line-2
        STUB WRITE_BLOCK Sources/Generated.swift END_SWIFT
        public struct Generated {
            public static let value = 42
        }
        END_SWIFT
        STUB COST 0.0789
        STUB STATUS partial
        """
        let partialRes = try Self.runStubProcess(
            arguments: ["-p", "--permission-mode", "acceptEdits", "--output-format", "json"],
            stdinString: writePrompt,
            workingDirectory: workdirWrite,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(partialRes.exitCode == 0)
        #expect(try String(contentsOf: workdirWrite.appendingPathComponent("nested/dir/single.txt"), encoding: .utf8) == "hello $NOT_EXPANDED world\n")
        #expect(try String(contentsOf: workdirWrite.appendingPathComponent("nested/dir/multi.txt"), encoding: .utf8) == "line-1\nline-2\n")
        let blockText = try String(contentsOf: workdirWrite.appendingPathComponent("Sources/Generated.swift"), encoding: .utf8)
        #expect(blockText.contains("public static let value = 42"))
        let partialJSON = try #require(JSONSerialization.jsonObject(with: Data(partialRes.stdout.utf8)) as? [String: Any])
        #expect((partialJSON["result"] as? String)?.hasSuffix("STATUS: partial") == true)
        #expect(abs(((partialJSON["total_cost_usd"] as? Double) ?? 0) - 0.0789) < 0.000001)

        // Also verify `STUB STATUS: failed` (colon variant) on agy
        let failedRes = try Self.runStubProcess(
            arguments: ["-p", "STUB STATUS: failed\n", "--mode", "accept-edits", "--output-format", "json"],
            stdinString: nil,
            workingDirectory: workdirWrite,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(failedRes.exitCode == 0)
        let failedJSON = try #require(JSONSerialization.jsonObject(with: Data(failedRes.stdout.utf8)) as? [String: Any])
        #expect((failedJSON["response"] as? String)?.hasSuffix("STATUS: failed") == true)

        // 2. NO_JSON across all 4 vendors: exits 0 without structured output / -o file / export.json
        let noJsonCodexOut = tmpDir.appendingPathComponent("nojson-codex.out.md")
        FileManager.default.createFile(atPath: noJsonCodexOut.path, contents: Data())
        let noJsonVibeDir = tmpDir.appendingPathComponent("nojson-vibe", isDirectory: true)
        try FileManager.default.createDirectory(at: noJsonVibeDir, withIntermediateDirectories: true)
        let noJsonPromptFile = tmpDir.appendingPathComponent("nojson-prompt.md")
        try "STUB NO_JSON\n".write(to: noJsonPromptFile, atomically: true, encoding: .utf8)

        let noJsonClaude = try Self.runStubProcess(
            arguments: ["-p", "--permission-mode", "acceptEdits", "--output-format", "json"],
            stdinString: "STUB NO_JSON\n",
            workingDirectory: workdirWrite,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(noJsonClaude.exitCode == 0)
        #expect(noJsonClaude.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let noJsonCodex = try Self.runStubProcess(
            arguments: ["exec", "-C", workdirWrite.path, "-s", "workspace-write", "--skip-git-repo-check", "-o", noJsonCodexOut.path, "-"],
            stdinString: "STUB NO_JSON\n",
            workingDirectory: tmpDir,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(noJsonCodex.exitCode == 0)
        #expect((try Data(contentsOf: noJsonCodexOut)).isEmpty)

        let noJsonAgy = try Self.runStubProcess(
            arguments: ["-p", "STUB NO_JSON\n", "--mode", "accept-edits", "--output-format", "json"],
            stdinString: nil,
            workingDirectory: workdirWrite,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(noJsonAgy.exitCode == 0)
        #expect(noJsonAgy.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let noJsonVibe = try Self.runStubProcess(
            arguments: ["--workdir", workdirWrite.path, "--trust", "--prompt-file", noJsonPromptFile.path, "--output", "json", "--output-dir", noJsonVibeDir.path],
            stdinString: nil,
            workingDirectory: tmpDir,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(noJsonVibe.exitCode == 0)
        #expect(noJsonVibe.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(FileManager.default.fileExists(atPath: noJsonVibeDir.appendingPathComponent("export.json").path) == false)

        // 3. EXIT <code>: writes preceding files, stops before later directives, and exits with exact code
        let workdirExit = tmpDir.appendingPathComponent("worktrees/lane-exit", isDirectory: true)
        try FileManager.default.createDirectory(at: workdirExit, withIntermediateDirectories: true)
        for code: Int32 in [3, 125, 2] {
            let exitPrompt = """
            STUB WRITE before-\(code).txt recorded
            STUB EXIT \(code)
            STUB WRITE after-\(code).txt unreachable
            """
            let exitRes = try Self.runStubProcess(
                arguments: ["-p", exitPrompt, "--mode", "accept-edits", "--output-format", "json"],
                stdinString: nil,
                workingDirectory: workdirExit,
                environment: env,
                scratchDir: tmpDir
            )
            #expect(exitRes.terminationReason == .exit)
            #expect(exitRes.exitCode == code)
            #expect(FileManager.default.fileExists(atPath: workdirExit.appendingPathComponent("before-\(code).txt").path) == true)
            #expect(FileManager.default.fileExists(atPath: workdirExit.appendingPathComponent("after-\(code).txt").path) == false)
        }

        // 4. KILL_SELF <signal>: genuinely dies from the requested signal when run inside POSIXPseudoTerminalSession
        for (sigToken, expectedSig) in [("9", SIGKILL), ("TERM", SIGTERM)] {
            let pty = POSIXPseudoTerminalSession(laneID: "lane-stub-sig-\(sigToken)")
            defer { pty.terminate(signal: SIGKILL) }
            try pty.spawn(
                executablePath: Self.stubAgentPath,
                arguments: ["-p", "STUB KILL_SELF \(sigToken)\n", "--mode", "accept-edits", "--output-format", "json"],
                workingDirectory: workdirExit.path,
                environmentOverrides: ["STUB_TRACE_DIR": traceDir.path]
            )
            #expect(pty.waitForExit(timeout: 5.0) == true)
            let m = pty.metrics()
            #expect(m.exitStatus == nil)
            #expect(m.terminationSignal == expectedSig)
        }

        // 5. WAIT (barrier) + child command line carries $STUB_TRACE_DIR
        let workdirBarrier = tmpDir.appendingPathComponent("worktrees/lane-barrier", isDirectory: true)
        try FileManager.default.createDirectory(at: workdirBarrier, withIntermediateDirectories: true)
        let armedFile = workdirBarrier.appendingPathComponent("armed.flag")
        let gateFile = tmpDir.appendingPathComponent("release.barrier")
        let afterGateFile = workdirBarrier.appendingPathComponent("after-gate.txt")
        let waitPty = POSIXPseudoTerminalSession(laneID: "lane-barrier")
        defer { waitPty.terminate(signal: SIGKILL) }
        try waitPty.spawn(
            executablePath: Self.stubAgentPath,
            arguments: [
                "-p",
                """
                STUB WRITE armed.flag ready
                STUB WAIT \(gateFile.path)
                STUB WRITE after-gate.txt passed-barrier
                """,
                "--mode", "accept-edits",
                "--output-format", "json"
            ],
            workingDirectory: workdirBarrier.path,
            environmentOverrides: ["STUB_TRACE_DIR": traceDir.path]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: armedFile.path) { break }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: armedFile.path) == true)
        // Give the WAIT child process a brief moment to spawn after writing armed.flag
        var waitChildMatched = false
        let waitLeaderPID = waitPty.metrics().pid
        for _ in 0..<50 {
            let procs = try Self.listProcessesMatching(traceDir.path)
            if procs.contains(where: { $0.ppid == waitLeaderPID && $0.pid != waitLeaderPID }) {
                waitChildMatched = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(waitChildMatched == true, "Expected long-running WAIT child process argv to include STUB_TRACE_DIR")
        #expect(FileManager.default.fileExists(atPath: afterGateFile.path) == false)
        #expect(waitPty.metrics().isRunning == true)

        // Release the barrier and verify clean completion
        try "go\n".write(to: gateFile, atomically: true, encoding: .utf8)
        #expect(waitPty.waitForExit(timeout: 5.0) == true)
        #expect(waitPty.metrics().exitStatus == 0)
        #expect(try String(contentsOf: afterGateFile, encoding: .utf8) == "passed-barrier\n")

        // 6. SLEEP: fractional sleep completes accurately, and long SLEEP child carries $STUB_TRACE_DIR & cleans up on terminate
        let t0 = ContinuousClock.now
        let shortSleepRes = try Self.runStubProcess(
            arguments: ["-p", "STUB SLEEP 0.22\n", "--mode", "accept-edits", "--output-format", "json"],
            stdinString: nil,
            workingDirectory: workdirBarrier,
            environment: env,
            scratchDir: tmpDir
        )
        let elapsed = t0.duration(to: ContinuousClock.now)
        #expect(shortSleepRes.exitCode == 0)
        #expect(elapsed >= .milliseconds(180))

        let sleepArmedFile = workdirBarrier.appendingPathComponent("sleep-armed.flag")
        let sleepPty = POSIXPseudoTerminalSession(laneID: "lane-sleep-tag")
        defer { sleepPty.terminate(signal: SIGKILL) }
        try sleepPty.spawn(
            executablePath: Self.stubAgentPath,
            arguments: [
                "-p",
                """
                STUB WRITE sleep-armed.flag 1
                STUB SLEEP 30
                """,
                "--mode", "accept-edits",
                "--output-format", "json"
            ],
            workingDirectory: workdirBarrier.path,
            environmentOverrides: ["STUB_TRACE_DIR": traceDir.path]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: sleepArmedFile.path) { break }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        let sleepLeaderPID = sleepPty.metrics().pid
        var sleepChildPID: Int32?
        for _ in 0..<50 {
            let procs = try Self.listProcessesMatching(traceDir.path)
            if let hit = procs.first(where: { $0.ppid == sleepLeaderPID && $0.pid != sleepLeaderPID }) {
                sleepChildPID = hit.pid
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sleepChildPID != nil, "Expected long-running SLEEP child process argv to include STUB_TRACE_DIR")
        sleepPty.terminate(signal: SIGTERM)
        #expect(Darwin.kill(sleepLeaderPID, 0) != 0)
        if let sleepChildPID {
            #expect(Darwin.kill(sleepChildPID, 0) != 0)
        }

        #expect(FileManager.default.fileExists(atPath: decoyMarker.path) == false)
    }

    @Test("stub-agent.sh writes start/end timestamps and PIDs to STUB_TRACE_DIR/<lane>.trace with overlapping parallel intervals")
    func stubAgentWritesTraceFilesWithLivePIDsAndOverlappingIntervals() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-stub-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let traceDir = tmpDir.appendingPathComponent("trace-out", isDirectory: true)
        let (env, decoyMarker) = try Self.makeIsolatedDecoyEnvironment(
            in: tmpDir,
            extraEnv: ["STUB_TRACE_DIR": traceDir.path]
        )

        let workdirA = tmpDir.appendingPathComponent("runs/r1/worktrees/a", isDirectory: true)
        let workdirB = tmpDir.appendingPathComponent("runs/r1/worktrees/b", isDirectory: true)
        try FileManager.default.createDirectory(at: workdirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workdirB, withIntermediateDirectories: true)

        let gateURL = tmpDir.appendingPathComponent("parallel.barrier")
        let vibePromptB = tmpDir.appendingPathComponent("prompt-b.md")
        let vibeOutB = tmpDir.appendingPathComponent("vibe-b", isDirectory: true)
        try FileManager.default.createDirectory(at: vibeOutB, withIntermediateDirectories: true)
        try """
        STUB WRITE file_b.txt from-b
        STUB WAIT \(gateURL.path)
        STUB COST 0.0200
        """.write(to: vibePromptB, atomically: true, encoding: .utf8)

        let ptyA = POSIXPseudoTerminalSession(laneID: "a")
        let ptyB = POSIXPseudoTerminalSession(laneID: "b")
        defer {
            ptyA.terminate(signal: SIGKILL)
            ptyB.terminate(signal: SIGKILL)
        }

        try ptyA.spawn(
            executablePath: Self.stubAgentPath,
            arguments: [
                "-p",
                """
                STUB WRITE file_a.txt from-a
                STUB WAIT \(gateURL.path)
                STUB TOKENS 1800
                """,
                "--mode", "accept-edits",
                "--output-format", "json"
            ],
            workingDirectory: workdirA.path,
            environmentOverrides: env
        )
        try ptyB.spawn(
            executablePath: Self.stubAgentPath,
            arguments: [
                "--workdir", workdirB.path,
                "--trust",
                "--prompt-file", vibePromptB.path,
                "--output", "json",
                "--output-dir", vibeOutB.path
            ],
            workingDirectory: tmpDir.path,
            environmentOverrides: env
        )

        let traceA = traceDir.appendingPathComponent("a.trace")
        let traceB = traceDir.appendingPathComponent("b.trace")
        for _ in 0..<200 {
            let aReady = (try? String(contentsOf: traceA, encoding: .utf8).contains("start ")) == true
            let bReady = (try? String(contentsOf: traceB, encoding: .utf8).contains("start ")) == true
            if aReady && bReady { break }
            try await Task.sleep(nanoseconds: 15_000_000)
        }

        #expect(FileManager.default.fileExists(atPath: traceA.path) == true, "Expected a.trace to exist while paused on barrier")
        #expect(FileManager.default.fileExists(atPath: traceB.path) == true, "Expected b.trace to exist while paused on barrier")

        // Preceding WRITE files must already be materialized when start trace appears
        #expect(FileManager.default.fileExists(atPath: workdirA.appendingPathComponent("file_a.txt").path) == true)
        #expect(FileManager.default.fileExists(atPath: workdirB.appendingPathComponent("file_b.txt").path) == true)

        let midLinesA = try String(contentsOf: traceA, encoding: .utf8).split(separator: "\n")
        let midLinesB = try String(contentsOf: traceB, encoding: .utf8).split(separator: "\n")
        #expect(midLinesA.count == 1)
        #expect(midLinesB.count == 1)

        let startColsA = midLinesA[0].split(separator: " ")
        let startColsB = midLinesB[0].split(separator: " ")
        #expect(startColsA.count >= 5)
        #expect(startColsB.count >= 5)
        let pidA = try #require(Int32(startColsA[2]))
        let pidB = try #require(Int32(startColsB[2]))
        #expect(pidA > 0 && pidB > 0 && pidA != pidB)
        #expect(Darwin.kill(pidA, 0) == 0, "Expected recorded PID in a.trace to be alive while waiting on barrier")
        #expect(Darwin.kill(pidB, 0) == 0, "Expected recorded PID in b.trace to be alive while waiting on barrier")

        // Keep barrier held briefly so overlap window is unambiguous, then release
        try await Task.sleep(nanoseconds: 50_000_000)
        try "release\n".write(to: gateURL, atomically: true, encoding: .utf8)

        #expect(ptyA.waitForExit(timeout: 5.0) == true)
        #expect(ptyB.waitForExit(timeout: 5.0) == true)
        #expect(ptyA.metrics().exitStatus == 0)
        #expect(ptyB.metrics().exitStatus == 0)

        let finalLinesA = try String(contentsOf: traceA, encoding: .utf8).split(separator: "\n")
        let finalLinesB = try String(contentsOf: traceB, encoding: .utf8).split(separator: "\n")
        #expect(finalLinesA.count == 2)
        #expect(finalLinesB.count == 2)

        let endColsA = finalLinesA[1].split(separator: " ")
        let endColsB = finalLinesB[1].split(separator: " ")
        #expect(endColsA[0] == "end")
        #expect(endColsB[0] == "end")
        #expect(Int32(endColsA[2]) == pidA)
        #expect(Int32(endColsB[2]) == pidB)
        #expect(endColsA[3] == "agy")
        #expect(endColsB[3] == "vibe")
        #expect(endColsA[4] == "a")
        #expect(endColsB[4] == "b")
        #expect(endColsA[5] == "0")
        #expect(endColsB[5] == "0")

        let startTsA = try #require(Double(startColsA[1]))
        let endTsA = try #require(Double(endColsA[1]))
        let startTsB = try #require(Double(startColsB[1]))
        let endTsB = try #require(Double(endColsB[1]))
        #expect(endTsA >= startTsA)
        #expect(endTsB >= startTsB)
        #expect(startTsA < endTsB && startTsB < endTsA, "Expected parallel lane trace intervals [\(startTsA), \(endTsA)] and [\(startTsB), \(endTsB)] to overlap")

        // Explicit STUB LANE override + non-zero exit code recorded in trace
        let failRes = try Self.runStubProcess(
            arguments: ["-p", "--permission-mode", "acceptEdits", "--output-format", "json"],
            stdinString: "STUB LANE custom-fail\nSTUB EXIT 3\n",
            workingDirectory: workdirA,
            environment: env,
            scratchDir: tmpDir
        )
        #expect(failRes.exitCode == 3)
        let failTraceLines = try String(contentsOf: traceDir.appendingPathComponent("custom-fail.trace"), encoding: .utf8).split(separator: "\n")
        #expect(failTraceLines.count == 2)
        let failEndCols = failTraceLines[1].split(separator: " ")
        #expect(failEndCols[0] == "end")
        #expect(failEndCols[3] == "claude")
        #expect(failEndCols[4] == "custom-fail")
        #expect(failEndCols[5] == "3")

        // Verify stub-agent.sh contains no forbidden skill directory references or home paths
        let stubSource = try String(contentsOfFile: Self.stubAgentPath, encoding: .utf8)
        let forbiddenSkillToken = "agents" + "/" + "skills"
        #expect(!stubSource.contains(forbiddenSkillToken))
        #expect(!stubSource.contains("/" + "Users" + "/"))
        #expect(FileManager.default.fileExists(atPath: decoyMarker.path) == false)
    }

    // MARK: - M1 Stage 05: Multi-Lane PTY FD Isolation on Crash & Escalating Cancellation Ladder (R42)

    @Test("Closing one PTY session's master FD delivers SIGHUP even while sibling PTY sessions remain open (crash FD isolation)")
    func ptyMultiSessionMasterHangupDoesNotLeakAcrossSiblingSessions() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-pty-s05-cloexec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let readyA = tmpDir.appendingPathComponent("ready-a")
        let readyB = tmpDir.appendingPathComponent("ready-b")

        let ptyA = POSIXPseudoTerminalSession(laneID: "lane-crash-a")
        let ptyB = POSIXPseudoTerminalSession(laneID: "lane-crash-b")
        var pidA: pid_t = -1
        var pidB: pid_t = -1
        defer {
            if pidA > 0 { _ = Darwin.kill(-pidA, SIGKILL); _ = Darwin.kill(pidA, SIGKILL) }
            if pidB > 0 { _ = Darwin.kill(-pidB, SIGKILL); _ = Darwin.kill(pidB, SIGKILL) }
            ptyA.terminate(signal: SIGKILL)
            ptyB.terminate(signal: SIGKILL)
        }

        try ptyA.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--ready-file", readyA.path, "--sleep", "30"]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: readyA.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        pidA = ptyA.metrics().pid
        #expect(pidA > 0)

        // Spawn sibling session B AFTER session A's master FD is open in parent.
        try ptyB.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--ready-file", readyB.path, "--sleep", "30"]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: readyB.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        pidB = ptyB.metrics().pid
        #expect(pidB > 0)

        // Simulate RelayIDE crashing/closing A's master FD without sending kill(), while B stays running.
        ptyA.closeMasterFDSimulatingCrash()

        let aExited = ptyA.waitForExit(timeout: 1.5)
        #expect(aExited == true, "Session A failed to receive SIGHUP on master FD close because sibling session B leaked A's master FD")
        let metricsA = ptyA.metrics()
        #expect(metricsA.isRunning == false)
        #expect(metricsA.exitStatus == nil)
        #expect(metricsA.terminationSignal == SIGHUP)
        #expect(ptyB.metrics().isRunning == true)
    }

    @Test("terminateWithEscalation enforces INT -> TERM -> KILL order and kills separate-process-group descendants (R42)")
    func ptyEscalatingTerminationOrderAndDescendantProcessGroupKill() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-pty-s05-ladder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Cooperative child exits on initial SIGINT without escalating to SIGTERM or SIGKILL.
        let ready1 = tmpDir.appendingPathComponent("ready-1")
        let sigLog1 = tmpDir.appendingPathComponent("sig-1.log")
        let pty1 = POSIXPseudoTerminalSession(laneID: "lane-ladder-1")
        var pid1: pid_t = -1
        defer {
            if pid1 > 0 { _ = Darwin.kill(-pid1, SIGKILL); _ = Darwin.kill(pid1, SIGKILL) }
            pty1.terminate(signal: SIGKILL)
        }
        try pty1.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--signal-log", sigLog1.path, "--ready-file", ready1.path, "--sleep", "30"]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready1.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        pid1 = pty1.metrics().pid
        let steps1 = pty1.terminateWithEscalation(sigintGraceSeconds: 1.0, sigtermGraceSeconds: 1.0)
        #expect(steps1 == [.sentSIGINT(pid: pid1)])
        #expect(pty1.metrics().isRunning == false)
        let logged1 = (try? String(contentsOf: sigLog1, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(logged1 == ["INT"])

        // 2. Child ignoring SIGINT survives grace window, then exits on SIGTERM without SIGKILL.
        let ready2 = tmpDir.appendingPathComponent("ready-2")
        let sigLog2 = tmpDir.appendingPathComponent("sig-2.log")
        let pty2 = POSIXPseudoTerminalSession(laneID: "lane-ladder-2")
        var pid2: pid_t = -1
        defer {
            if pid2 > 0 { _ = Darwin.kill(-pid2, SIGKILL); _ = Darwin.kill(pid2, SIGKILL) }
            pty2.terminate(signal: SIGKILL)
        }
        try pty2.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: ["--ignore-int", "--signal-log", sigLog2.path, "--ready-file", ready2.path, "--sleep", "30"]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready2.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        pid2 = pty2.metrics().pid
        let steps2 = pty2.terminateWithEscalation(sigintGraceSeconds: 0.15, sigtermGraceSeconds: 1.0)
        #expect(steps2 == [.sentSIGINT(pid: pid2), .sentSIGTERM(pid: pid2)])
        #expect(pty2.metrics().isRunning == false)
        let logged2 = (try? String(contentsOf: sigLog2, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(logged2 == ["INT", "TERM"])

        // 3. Child ignoring SIGINT and SIGTERM + spawning a separate-pgid descendant (setpgid(0,0))
        //    enumerates descendants BEFORE SIGKILL and kills both process groups.
        let ready3 = tmpDir.appendingPathComponent("ready-3")
        let sigLog3 = tmpDir.appendingPathComponent("sig-3.log")
        let subPIDFile3 = tmpDir.appendingPathComponent("sub-3.pid")
        let pty3 = POSIXPseudoTerminalSession(laneID: "lane-ladder-3")
        var pid3: pid_t = -1
        var subgroupPID: pid_t = -1
        defer {
            if subgroupPID > 0 { _ = Darwin.kill(-subgroupPID, SIGKILL); _ = Darwin.kill(subgroupPID, SIGKILL) }
            if pid3 > 0 { _ = Darwin.kill(-pid3, SIGKILL); _ = Darwin.kill(pid3, SIGKILL) }
            pty3.terminate(signal: SIGKILL)
        }
        try pty3.spawn(
            executablePath: Self.fakeRelayPath,
            arguments: [
                "--ignore-int",
                "--ignore-term",
                "--signal-log", sigLog3.path,
                "--subgroup-pid-file", subPIDFile3.path,
                "--ready-file", ready3.path,
                "--sleep", "30"
            ]
        )
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready3.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        pid3 = pty3.metrics().pid
        let rawSubPID = try String(contentsOf: subPIDFile3, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        subgroupPID = try #require(pid_t(rawSubPID))
        let subgroupPGID = Darwin.getpgid(subgroupPID)
        #expect(subgroupPID > 0 && subgroupPID != pid3)
        #expect(subgroupPGID == subgroupPID)

        let discoveredDescendants = POSIXProcessTree.allDescendants(of: pid3)
        #expect(discoveredDescendants.contains(subgroupPID))
        let discoveredPGIDs = POSIXProcessTree.processGroupIDs(for: [pid3] + discoveredDescendants)
        #expect(discoveredPGIDs.contains(subgroupPGID))

        let steps3 = pty3.terminateWithEscalation(sigintGraceSeconds: 0.15, sigtermGraceSeconds: 0.15)
        #expect(steps3.count == 3)
        if steps3.count == 3 {
            #expect(steps3[0] == .sentSIGINT(pid: pid3))
            #expect(steps3[1] == .sentSIGTERM(pid: pid3))
            if case .sentSIGKILL(let killedLeader, let descPIDs, let pgids) = steps3[2] {
                #expect(killedLeader == pid3)
                #expect(descPIDs.contains(subgroupPID))
                #expect(pgids.contains(subgroupPGID))
            } else {
                Issue.record("Expected third escalation step to be .sentSIGKILL")
            }
        }
        let logged3 = (try? String(contentsOf: sigLog3, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(logged3 == ["INT", "TERM"])
        #expect(pty3.metrics().isRunning == false)
        #expect(pty3.metrics().terminationSignal == SIGKILL)
        #expect(Darwin.kill(pid3, 0) != 0, "Leader PID \(pid3) still alive after SIGKILL escalation")

        // Poll briefly for kernel reap of reparented separate-pgid child after SIGKILL
        for _ in 0..<50 {
            if Darwin.kill(subgroupPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Darwin.kill(subgroupPID, 0) != 0, "Separate-process-group descendant \(subgroupPID) survived SIGKILL escalation")
    }
}
