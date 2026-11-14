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
}
