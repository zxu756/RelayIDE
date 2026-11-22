import AppKit
import Combine
import CoreGraphics
import Foundation
import PDFKit
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelayPTYCore
import RelayStudioViews
import RelayWorkspaceStore
import SQLite3
import SwiftUI
import Testing

@Suite("M5-01 Headless Workbench UI Streaming, 4-Lane Spend/Status, & PDF Number Grounding Tests", .serialized, .timeLimit(.minutes(2)))
struct M5StudioViewsHeadlessTests {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    /// Explicitly named static UI chrome tokens allowed to contain digits in non-demo mode.
    /// Every item here is a fixed keyboard shortcut, technical standard identifier, or layout/view label — never business data.
    private static let explicitNamedStaticChromeTokens: [(name: String, literal: String)] = [
        (name: "leftRailPaneShortcutRange", literal: "⌘1–5"),
        (name: "pane1ShortcutPTYGrid", literal: "⌘1"),
        (name: "pane2ShortcutDAGPipeline", literal: "⌘2"),
        (name: "pane3ShortcutMergeView", literal: "⌘3"),
        (name: "pane4ShortcutTerritoryMap", literal: "⌘4"),
        (name: "pane5ShortcutGuardrailPlugins", literal: "⌘5"),
        (name: "sqliteFullTextSearchEngineName", literal: "FTS5"),
        (name: "terminalEmulationStandardName", literal: "VT100"),
        (name: "quadGridPresetLabel", literal: "2×2"),
        (name: "conductorGridPresetLabel", literal: "1+3"),
        (name: "mergePaneLegacyAlgorithmName", literal: "3-Way"),
        (name: "isometricProjectionDimensionLabel", literal: "2.5D")
    ]

    /// Explicitly named terminal line-number gutter labels (`01`..`26`) rendered only when terminal rows exist.
    private static let explicitTerminalGutterRowNumbers: Set<String> = Set(
        (1...26).map { String(format: "%02d", $0) }
    )

    private struct UIHeadlessFixture {
        let rootURL: URL
        let homeURL: URL
        let repoURL: URL
        let projectURL: URL
        let decoyMarkerURL: URL
        let tracesDirURL: URL
        let stubURL: URL
        let environment: [String: String]
    }

    @MainActor
    private func enforceHeadlessZeroWindows() {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        #expect(NSApplication.shared.windows.isEmpty)
    }

    private func runGit(_ args: [String], cwd: URL, env: [String: String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "M5StudioViewsHeadlessTests", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out])
        }
    }

    private func makeFixture(prefix: String) throws -> UIHeadlessFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("iso-home", isDirectory: true)
        let prefsURL = homeURL.appendingPathComponent("Library/Preferences", isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("Workbench.relayproj", isDirectory: true)
        let stubDirURL = rootURL.appendingPathComponent("stubs", isDirectory: true)
        let decoyDirURL = rootURL.appendingPathComponent("decoys", isDirectory: true)
        let tracesDirURL = rootURL.appendingPathComponent("traces", isDirectory: true)

        for dir in [homeURL, prefsURL, repoURL, stubDirURL, decoyDirURL, tracesDirURL] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let gitEnv: [String: String] = [
            "HOME": homeURL.path,
            "CFFIXED_USER_HOME": homeURL.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]
        try runGit(["init", "-b", "main"], cwd: repoURL, env: gitEnv)
        try runGit(["config", "user.name", "Relay M5 UI Tester"], cwd: repoURL, env: gitEnv)
        try runGit(["config", "user.email", "m5-ui-tester@relay.invalid"], cwd: repoURL, env: gitEnv)
        try "seed\n".write(to: repoURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.txt"], cwd: repoURL, env: gitEnv)
        try runGit(["commit", "-m", "initial"], cwd: repoURL, env: gitEnv)

        _ = try RelayProjectDatabase(bundleDirectoryURL: projectURL)

        let realRelay = try RelayRunExecutor.resolveAndVerifyRelayScript(
            explicitPath: nil,
            environment: ProcessInfo.processInfo.environment,
            language: .en
        )

        let decoyMarkerURL = rootURL.appendingPathComponent("decoy-invoked.marker")
        for cli in ["claude", "codex", "agy", "vibe", "opencode"] {
            let decoyURL = decoyDirURL.appendingPathComponent(cli)
            let script = """
            #!/usr/bin/env bash
            printf 'decoy %s %s\\n' "\(cli)" "$*" >> "\(decoyMarkerURL.path)"
            exit 99
            """
            try script.write(to: decoyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoyURL.path)
        }

        let stubURL = stubDirURL.appendingPathComponent("m5-stub-agent.py")
        let stubScript = #"""
        #!/usr/bin/env python3
        import json, os, sys, time

        args = sys.argv[1:]
        if args[:1] in (["--version"], ["-V"]):
            print("m5-stub-agent 1.0.0")
            sys.exit(0)
        if args[:2] == ["login", "status"]:
            print("Logged in (m5-stub)")
            sys.exit(0)
        if args[:2] == ["features", "list"]:
            sys.exit(0)

        vendor = None
        workdir = os.getcwd()
        prompt_file = None
        prompt_inline = None
        vibe_dir = None
        codex_out = None
        i = 0
        while i < len(args):
            a = args[i]
            if a.startswith("--prompt-file"):
                prompt_file = a.split("=", 1)[1] if "=" in a else args[i + 1]
                if "=" not in a:
                    i += 1
            elif a.startswith("--output-dir"):
                vibe_dir = a.split("=", 1)[1] if "=" in a else args[i + 1]
                if "=" not in a:
                    i += 1
            elif a.startswith("--workdir"):
                workdir = a.split("=", 1)[1] if "=" in a else args[i + 1]
                if "=" not in a:
                    i += 1
            elif a in ("-o", "--output-last-message") and i + 1 < len(args):
                codex_out = args[i + 1]
                i += 1
            elif a == "-C" and i + 1 < len(args):
                workdir = args[i + 1]
                i += 1
            elif a == "-p" and i + 1 < len(args) and not args[i + 1].startswith("--"):
                prompt_inline = args[i + 1]
                i += 1
            i += 1

        if any(a.startswith("--permission-mode") or a.startswith("--max-budget-usd") for a in args):
            vendor = "claude"
        elif any(a.startswith("--prompt-file") or a.startswith("--output-dir") or a.startswith("--workdir") for a in args):
            vendor = "vibe"
        elif (args and args[0] == "exec") or any(a in ("--skip-git-repo-check", "-o", "--output-last-message") for a in args):
            vendor = "codex"
        elif any(a.startswith("--mode") for a in args) or prompt_inline is not None:
            vendor = "agy"

        if vendor in ("claude", "codex"):
            prompt_text = sys.stdin.read()
        elif vendor == "agy":
            prompt_text = prompt_inline or ""
        elif vendor == "vibe" and prompt_file:
            with open(prompt_file, "r", encoding="utf-8") as fh:
                prompt_text = fh.read()
        else:
            prompt_text = ""

        lane = os.path.basename(os.path.realpath(workdir))
        cost_usd = 0.05
        tokens = 1200
        ticks = 0
        interval = 1.0
        sleep_sec = 0.0
        exit_code = 0
        write_rel = None

        for raw in prompt_text.splitlines():
            line = raw.strip()
            if line.startswith("LANE="):
                lane = line.split("=", 1)[1].strip()
            elif line.startswith("COST="):
                cost_usd = float(line.split("=", 1)[1].strip())
            elif line.startswith("TOKENS="):
                tokens = int(line.split("=", 1)[1].strip())
            elif line.startswith("TICKS="):
                ticks = int(line.split("=", 1)[1].strip())
            elif line.startswith("SLEEP="):
                sleep_sec = float(line.split("=", 1)[1].strip())
            elif line.startswith("EXIT="):
                exit_code = int(line.split("=", 1)[1].strip())
            elif line.startswith("WRITE="):
                write_rel = line.split("=", 1)[1].strip()

        trace_dir = os.environ.get("STUB_TRACE_DIR", "")
        if trace_dir:
            os.makedirs(trace_dir, exist_ok=True)
            with open(os.path.join(trace_dir, f"{lane}.trace"), "a", encoding="utf-8") as tf:
                tf.write(f"start {time.time():.6f} {os.getpid()} {vendor} {lane}\n")

        emitted = []
        if ticks > 0:
            for seq in range(1, ticks + 1):
                if seq > 1:
                    time.sleep(interval)
                ts = time.time()
                msg = f"STREAM lane={lane} seq={seq} emit={ts:.6f}"
                emitted.append(msg)
                stream = sys.stderr if vendor == "vibe" else sys.stdout
                stream.write(msg + "\n")
                stream.flush()
        elif sleep_sec > 0:
            time.sleep(sleep_sec)

        if write_rel and exit_code == 0:
            with open(os.path.join(workdir, write_rel), "w", encoding="utf-8") as wf:
                wf.write(f"ok {lane}\n")

        status_word = "success" if exit_code == 0 else "failed"
        summary = ("\n".join(emitted) + "\n" if emitted else "") + f"Completed {lane}\nSTATUS: {status_word}"
        in_tok = (tokens * 2) // 3
        out_tok = tokens - in_tok

        if vendor == "claude":
            payload = {
                "type": "result",
                "subtype": "success" if exit_code == 0 else "error",
                "is_error": (exit_code != 0),
                "result": summary,
                "total_cost_usd": cost_usd,
                "session_id": f"stub-claude-{lane}",
                "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
            }
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()
        elif vendor == "codex":
            if codex_out:
                os.makedirs(os.path.dirname(codex_out) or ".", exist_ok=True)
                with open(codex_out, "w", encoding="utf-8") as cf:
                    cf.write(summary + "\n")
            sys.stdout.write(f"session id: stub-codex-{lane}\n{summary}\ntokens used\n{tokens:,}\n")
            sys.stdout.flush()
        elif vendor == "agy":
            payload = {
                "response": summary,
                "status": "SUCCESS" if exit_code == 0 else "FAILED",
                "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
                "denied_actions": [],
            }
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()
        elif vendor == "vibe":
            sys.stdout.write(json.dumps([{"type": "message", "role": "assistant", "content": summary}]) + "\n")
            sys.stdout.flush()
            if vibe_dir:
                os.makedirs(vibe_dir, exist_ok=True)
                exp = {
                    "outcome": "finished" if exit_code == 0 else "stopped",
                    "stop_reason": "end_turn" if exit_code == 0 else "error",
                    "cost_usd": cost_usd,
                    "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
                    "config": {"active_model": "stub-vibe"},
                }
                with open(os.path.join(vibe_dir, "export.json"), "w", encoding="utf-8") as ef:
                    json.dump(exp, ef)
                    ef.write("\n")

        if trace_dir:
            with open(os.path.join(trace_dir, f"{lane}.trace"), "a", encoding="utf-8") as tf:
                tf.write(f"end {time.time():.6f} {os.getpid()} {vendor} {lane} {exit_code}\n")

        sys.exit(exit_code)
        """#
        try stubScript.write(to: stubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubURL.path)

        let env: [String: String] = [
            "HOME": homeURL.path,
            "CFFIXED_USER_HOME": homeURL.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "\(decoyDirURL.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "RELAYIDE_RELAY_SH": realRelay.url.path,
            "RELAY_CLAUDE_BIN": stubURL.path,
            "RELAY_CODEX_BIN": stubURL.path,
            "RELAY_AGY_BIN": stubURL.path,
            "RELAY_VIBE_BIN": stubURL.path,
            "STUB_TRACE_DIR": tracesDirURL.path
        ]

        return UIHeadlessFixture(
            rootURL: rootURL,
            homeURL: homeURL,
            repoURL: repoURL,
            projectURL: projectURL,
            decoyMarkerURL: decoyMarkerURL,
            tracesDirURL: tracesDirURL,
            stubURL: stubURL,
            environment: env
        )
    }

    @MainActor
    private func renderWorkbenchPDFText(vm: RelayStudioViewModel) throws -> String {
        let viewport = CGSize(width: 1360, height: 840)
        let rootView = RelayStudioRootWorkbenchView(viewModel: vm)
            .frame(width: viewport.width, height: viewport.height)
            .environment(\.colorScheme, .light)
            .environment(\.relaySnapshotRenderMode, true)
        let renderer = ImageRenderer(content: rootView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(viewport)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: viewport)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "M5StudioViewsHeadlessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF CGContext"])
        }
        renderer.render { _, renderInContext in
            pdfCtx.beginPDFPage(nil)
            renderInContext(pdfCtx)
            pdfCtx.endPDFPage()
            pdfCtx.closePDF()
        }
        return PDFDocument(data: pdfData as Data)?.string ?? ""
    }

    @MainActor
    private func renderWorkbenchBitmapAndVerifyNonBlank(vm: RelayStudioViewModel) throws -> CGImage {
        let viewport = CGSize(width: 1360, height: 840)
        let rootView = RelayStudioRootWorkbenchView(viewModel: vm)
            .frame(width: viewport.width, height: viewport.height)
            .environment(\.colorScheme, .light)
            .environment(\.relaySnapshotRenderMode, true)
        let renderer = ImageRenderer(content: rootView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(viewport)
        let cgImage = try #require(renderer.cgImage)
        #expect(cgImage.width == 2720)
        #expect(cgImage.height == 1680)

        let w = cgImage.width
        let h = cgImage.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var distinctRGB = Set<UInt32>()
        for y in stride(from: 0, to: h, by: 40) {
            for x in stride(from: 0, to: w, by: 40) {
                let idx = (y * w + x) * 4
                let a = buf[idx + 3]
                if a > 0 {
                    let packed = (UInt32(buf[idx]) << 16) | (UInt32(buf[idx + 1]) << 8) | UInt32(buf[idx + 2])
                    distinctRGB.insert(packed)
                }
            }
        }
        #expect(distinctRGB.count >= 8, "Bitmap must contain real non-blank rendered pixels")
        return cgImage
    }

    private func extractNumberTokens(from text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    private func collectGroundTruthNumbers(bundleURL: URL) throws -> (numbers: Set<String>, logPlainText: String) {
        var truth = Set<String>()
        var combinedTerminalLogs = ""
        let sqliteURL = bundleURL.appendingPathComponent("workspace.sqlite")

        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            var rawDB: OpaquePointer?
            if sqlite3_open_v2(sqliteURL.path, &rawDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = rawDB {
                defer { sqlite3_close(db) }
                func queryInt(_ sql: String) -> Int? {
                    var st: OpaquePointer?
                    defer { sqlite3_finalize(st) }
                    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK,
                          sqlite3_step(st) == SQLITE_ROW else { return nil }
                    return Int(sqlite3_column_int64(st, 0))
                }
                if let schemaVer = queryInt("SELECT MAX(version) FROM schema_migrations;") {
                    truth.insert("\(schemaVer)")
                }
                for tbl in ["checkpoints", "managed_lanes", "dag_specs", "semantic_merge_reports", "guardrail_findings", "relay_runs", "relay_run_lanes"] {
                    if let cnt = queryInt("SELECT COUNT(*) FROM \(tbl);") {
                        truth.insert("\(cnt)")
                    }
                }
            }

            let projDB = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleURL)
            let runs = try projDB.allRuns(reconcileWithLock: true)
            if let run = runs.last {
                for tok in try extractNumberTokens(from: run.runID) {
                    truth.insert(tok)
                }
                truth.insert("\(run.lanes.count)")
                let termCount = run.lanes.filter(\.status.isTerminal).count
                truth.insert("\(termCount)")
                let succCount = run.lanes.filter { $0.status == .succeeded || $0.status == .succeededNoChanges }.count
                truth.insert("\(succCount)")

                if run.pricedLaneCount > 0 {
                    truth.insert(String(format: "%.4f", run.totalCostUSD))
                }
                if run.unpricedTokens > 0 {
                    truth.insert("\(run.unpricedTokens)")
                }
                if let cap = run.budgetUSD {
                    truth.insert(String(format: "%.4f", cap))
                }

                for lane in run.lanes {
                    for tok in try extractNumberTokens(from: lane.laneID) {
                        truth.insert(tok)
                    }
                    if let branch = lane.branch {
                        for tok in try extractNumberTokens(from: branch) {
                            truth.insert(tok)
                        }
                    }
                    if let ec = lane.exitCode {
                        truth.insert("\(ec)")
                    }
                    if let tokCount = lane.tokens {
                        truth.insert("\(tokCount)")
                    }
                    if lane.costSource == "usd", let usd = lane.costUSD {
                        truth.insert(String(format: "%.4f", usd))
                    }
                    if let s = lane.startedAt, let f = lane.finishedAt {
                        let dur = max(0.0, f.timeIntervalSince(s))
                        truth.insert(String(format: "%.2f", dur))
                    }

                    // Read `<worktree>/.relay/LOG.md` and `<worktree>/.relay/*.log`
                    let wtDir = bundleURL
                        .appendingPathComponent("runs", isDirectory: true)
                        .appendingPathComponent(run.runID, isDirectory: true)
                        .appendingPathComponent("worktrees", isDirectory: true)
                        .appendingPathComponent(lane.laneID, isDirectory: true)
                    let relayDir = wtDir.appendingPathComponent(".relay", isDirectory: true)
                    let logMD = relayDir.appendingPathComponent("LOG.md")
                    if let mdText = try? String(contentsOf: logMD, encoding: .utf8) {
                        for tok in try extractNumberTokens(from: mdText) {
                            truth.insert(tok)
                        }
                    }

                    var hadStepLog = false
                    if let items = try? FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil) {
                        for f in items.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                            if let txt = try? String(contentsOf: f, encoding: .utf8), !txt.isEmpty {
                                hadStepLog = true
                                combinedTerminalLogs += "\n" + txt
                                for tok in try extractNumberTokens(from: txt) {
                                    truth.insert(tok)
                                }
                            }
                        }
                    }
                    if !hadStepLog {
                        let ptyURL = bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("lanes", isDirectory: true)
                            .appendingPathComponent("\(lane.laneID).pty")
                        if let ptyText = try? String(contentsOf: ptyURL, encoding: .utf8), !ptyText.isEmpty {
                            combinedTerminalLogs += "\n" + ptyText
                            for tok in try extractNumberTokens(from: ptyText) {
                                truth.insert(tok)
                            }
                        }
                    }
                }
            }
        }
        return (truth, combinedTerminalLogs)
    }

    private func unmatchedNumbersInPDF(
        pdfText: String,
        groundTruth: Set<String>,
        terminalLogText: String,
        hasActiveTerminalRows: Bool
    ) throws -> [String] {
        var scrubbed = pdfText
        for entry in Self.explicitNamedStaticChromeTokens {
            scrubbed = scrubbed.replacingOccurrences(of: entry.literal, with: " ")
        }
        let extracted = try extractNumberTokens(from: scrubbed)
        let compactTerminalLog = terminalLogText.replacingOccurrences(of: "\n", with: " ")
        return extracted.filter { token in
            if groundTruth.contains(token) {
                return false
            }
            if hasActiveTerminalRows && Self.explicitTerminalGutterRowNumbers.contains(token) {
                return false
            }
            // Account for narrow terminal column line-wrapping inside a number that came verbatim from the terminal log.
            if token.count >= 2 && compactTerminalLog.contains(token) {
                return false
            }
            return true
        }
    }

    @Test("RelayStudioViewModel + PTYMultiplexerGridView stream 2 stub lanes line-by-line within <1s and match .relay logs without opening windows")
    @MainActor
    func viewModelAndGridStreamTwoLanesLineByLineWithinOneSecond() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-ui-stream")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "LANE=lane-claude\nCOST=0.1234\nTOKENS=1500\nTICKS=4\nWRITE=c.txt\n".write(
            to: promptsDir.appendingPathComponent("c.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-vibe\nCOST=0.2500\nTOKENS=900\nTICKS=4\nWRITE=v.txt\n".write(
            to: promptsDir.appendingPathComponent("v.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "lane-claude", "agent": "claude", "prompt": "prompts/c.md", "after": []],
                    ["id": "lane-vibe", "agent": "vibe", "prompt": "prompts/v.md", "after": []]
                ],
                "verify": "true"
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let localizer = RelayLocalizer(language: .en, persistToUserDefaults: false)
        let vm = RelayStudioViewModel(
            projectBundleURL: fx.projectURL,
            initialPane: .ptyGrid,
            localizer: localizer,
            loadDemoWorkspace: false
        )
        #expect(vm.isDemoMode == false)
        #expect(vm.isBroadcastBarExpanded == false)

        // Warm up CoreGraphics/PDF font pipeline once before starting timed 1s/line streaming
        _ = try renderWorkbenchPDFText(vm: vm)

        let tickRegex = try NSRegularExpression(pattern: #"STREAM lane=(lane-[a-z]+) seq=([1-4]) emit=(\d+\.\d+)"#)
        var arrivalLagByTick: [String: Double] = [:]
        var distinctVisibleCountsByLane: [String: Set<Int>] = ["lane-claude": [], "lane-vibe": []]

        let streamCancellable = vm.$terminalSnapshotsByLane.sink { snapsByLane in
            let now = Date().timeIntervalSince1970
            for laneID in ["lane-claude", "lane-vibe"] {
                guard let snap = snapsByLane[laneID] else { continue }
                let joined = snap.visibleGrid.map { $0.map(\.grapheme).joined() }.joined(separator: "\n")
                let ns = joined as NSString
                let matches = tickRegex.matches(in: joined, range: NSRange(location: 0, length: ns.length))
                if !matches.isEmpty {
                    distinctVisibleCountsByLane[laneID, default: []].insert(matches.count)
                }
                for m in matches {
                    let mLane = ns.substring(with: m.range(at: 1))
                    let seq = ns.substring(with: m.range(at: 2))
                    let emitStr = ns.substring(with: m.range(at: 3))
                    let key = "\(mLane)#\(seq)"
                    if arrivalLagByTick[key] == nil, let emitEpoch = Double(emitStr) {
                        arrivalLagByTick[key] = now - emitEpoch
                    }
                }
            }
        }
        defer { streamCancellable.cancel() }

        let cli = RelayCLIRunner()
        let env = fx.environment
        let projectPath = fx.projectURL.path
        let planPath = planURL.path
        let runTask = Task.detached {
            await cli.executeCommand(
                arguments: ["run", planPath, "--project", projectPath, "--lang", "en"],
                environment: env
            )
        }

        var midRunPDFVerified = false
        let pollDeadline = Date().addingTimeInterval(15.0)
        while Date() < pollDeadline {
            if !midRunPDFVerified && arrivalLagByTick.count >= 2 && arrivalLagByTick.count < 8 {
                let midPDF = try renderWorkbenchPDFText(vm: vm)
                if midPDF.contains("STREAM lane=lane-claude seq=1") && midPDF.contains("STREAM lane=lane-vibe seq=1") {
                    midRunPDFVerified = true
                }
            }
            if arrivalLagByTick.count == 8 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let runRes = await runTask.value
        #expect(runRes.exitCode == 0, "stderr=\(runRes.stderr)")
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(arrivalLagByTick.count == 8)
        for (key, lag) in arrivalLagByTick {
            #expect(lag >= 0.0 && lag <= 1.0, "Tick \(key) UI buffer lag \(lag)s exceeded 1.0s")
        }
        for laneID in ["lane-claude", "lane-vibe"] {
            let counts = distinctVisibleCountsByLane[laneID] ?? []
            #expect(counts.count >= 3, "Expected incremental line-by-line updates for \(laneID), saw counts \(counts)")
        }
        #expect(midRunPDFVerified, "Expected PDF render during live execution to show streamed lines before run completion")

        let finalPDF = try renderWorkbenchPDFText(vm: vm)
        _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: vm)
        for laneID in ["lane-claude", "lane-vibe"] {
            for seq in 1...4 {
                #expect(finalPDF.contains("STREAM lane=\(laneID) seq=\(seq)"))
            }
        }

        // Verify ViewModel terminal content matches `.relay/*.log` on disk
        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        let run = try #require(try db.allRuns(reconcileWithLock: true).last)
        for laneRec in run.lanes {
            let wt = try #require(laneRec.worktreePath)
            let relayDir = URL(fileURLWithPath: wt).appendingPathComponent(".relay", isDirectory: true)
            let logs = try FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let diskText = try logs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            let snap = try #require(vm.terminalSnapshotsByLane[laneRec.laneID])
            let vpLines = snap.visibleGrid.map {
                $0.map(\.grapheme).joined().replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            }.filter { !$0.isEmpty }
            for seq in 1...4 {
                #expect(diskText.contains("STREAM lane=\(laneRec.laneID) seq=\(seq)"))
                #expect(vpLines.contains(where: { $0.contains("STREAM lane=\(laneRec.laneID) seq=\(seq)") }))
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }

    @Test("Four-lane run (2 priced, 2 unpriced token-only, 1 failed exit 3) updates UI within <2s with 4-decimal USD, no fake $0.00 ceiling, and grounded PDF numbers")
    @MainActor
    func fourLanesUpdateUIWithinTwoSecondsAndPassPDFNumberGroundingAudit() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-ui-four-lanes")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        // First verify empty initialized non-demo workspace has ZERO ungrounded numbers across all 5 panes in EN & ZH
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let loc = RelayLocalizer(language: lang, persistToUserDefaults: false)
            let emptyVM = RelayStudioViewModel(
                projectBundleURL: fx.projectURL,
                initialPane: .ptyGrid,
                localizer: loc,
                loadDemoWorkspace: false
            )
            #expect(emptyVM.isBroadcastBarExpanded == false)
            emptyVM.coordinator.onBroadcastInputRequested?()
            #expect(emptyVM.isBroadcastBarExpanded == false)

            let (emptyTruth, emptyTermLog) = try collectGroundTruthNumbers(bundleURL: fx.projectURL)
            for pane in RelayStudioPane.allCases {
                emptyVM.selectPane(pane)
                let pdfText = try renderWorkbenchPDFText(vm: emptyVM)
                _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: emptyVM)

                #expect(!pdfText.contains("1.00×"))
                #expect(!pdfText.contains("15000"))
                #expect(!pdfText.contains("96×26"))
                #expect(!pdfText.contains("/ $0.00"))

                let unmatched = try unmatchedNumbersInPDF(
                    pdfText: pdfText,
                    groundTruth: emptyTruth,
                    terminalLogText: emptyTermLog,
                    hasActiveTerminalRows: false
                )
                #expect(unmatched.isEmpty, "Empty non-demo pane \(pane.rawValue) (\(lang.rawValue)) rendered ungrounded numbers: \(unmatched)\nPDF:\n\(pdfText)")
            }
        }

        // Now run 4 lanes: c1 (claude $0.1234 exit 0), v1 (vibe $0.2500 exit 3!), a1 (agy 4500 tok unpriced), x1 (codex 1200 tok unpriced), no budget ceiling
        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "LANE=c1\nSLEEP=0.25\nCOST=0.1234\nTOKENS=1500\nWRITE=c1.txt\n".write(
            to: promptsDir.appendingPathComponent("c1.md"), atomically: true, encoding: .utf8
        )
        try "LANE=v1\nSLEEP=0.30\nCOST=0.2500\nTOKENS=900\nEXIT=3\n".write(
            to: promptsDir.appendingPathComponent("v1.md"), atomically: true, encoding: .utf8
        )
        try "LANE=a1\nSLEEP=0.25\nTOKENS=4500\nWRITE=a1.txt\n".write(
            to: promptsDir.appendingPathComponent("a1.md"), atomically: true, encoding: .utf8
        )
        try "LANE=x1\nSLEEP=0.25\nTOKENS=1200\nWRITE=x1.txt\n".write(
            to: promptsDir.appendingPathComponent("x1.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "c1", "agent": "claude", "prompt": "prompts/c1.md", "after": []],
                    ["id": "v1", "agent": "vibe",   "prompt": "prompts/v1.md", "after": []],
                    ["id": "a1", "agent": "agy",    "prompt": "prompts/a1.md", "after": []],
                    ["id": "x1", "agent": "codex",  "prompt": "prompts/x1.md", "after": []]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let locEN = RelayLocalizer(language: .en, persistToUserDefaults: false)
        let liveVM = RelayStudioViewModel(
            projectBundleURL: fx.projectURL,
            initialPane: .ptyGrid,
            localizer: locEN,
            loadDemoWorkspace: false
        )

        var laneTerminalObservedEpoch: [String: Double] = [:]
        let laneCancellable = liveVM.$liveRunLanesByID.sink { lanesMap in
            let now = Date().timeIntervalSince1970
            for (laneID, rec) in lanesMap where rec.status.isTerminal && rec.exitCode != nil && rec.finishedAt != nil {
                if laneTerminalObservedEpoch[laneID] == nil {
                    laneTerminalObservedEpoch[laneID] = now
                }
            }
        }
        defer { laneCancellable.cancel() }

        let cli = RelayCLIRunner()
        let env = fx.environment
        let projectPath = fx.projectURL.path
        let planPath = planURL.path
        let runTask = Task.detached {
            await cli.executeCommand(
                arguments: ["run", planPath, "--project", projectPath, "--lang", "en"],
                environment: env
            )
        }

        var uiRenderedAllFourEpoch: Double?
        let waitDeadline = Date().addingTimeInterval(15.0)
        while Date() < waitDeadline {
            if laneTerminalObservedEpoch.count == 4 && abs(liveVM.totalWorkspaceSpendUSD - 0.3734) < 1e-6 {
                let pdf = try renderWorkbenchPDFText(vm: liveVM)
                if pdf.contains("$0.3734")
                    && pdf.contains("$0.1234")
                    && pdf.contains("$0.2500")
                    && pdf.contains("4500")
                    && pdf.contains("1200")
                    && pdf.contains("unpriced")
                    && pdf.contains("failed")
                    && pdf.contains("exit 3") {
                    uiRenderedAllFourEpoch = Date().timeIntervalSince1970
                    break
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let runRes = await runTask.value
        #expect(runRes.exitCode != 0, "Expected non-zero exit because v1 exited 3")

        let observedAllFourEpoch = try #require(
            uiRenderedAllFourEpoch,
            "UI did not render all 4 lanes' status, exit code 3, 4-decimal USD ($0.1234/$0.2500/$0.3734), and unpriced tokens (4500/1200)"
        )

        // Verify <= 2.0s latency from EVERY lane's child exit timestamp to its UI ViewModel update, and from last lane exit to full PDF render
        var latestStubExitEpoch: Double = 0.0
        for laneID in ["c1", "v1", "a1", "x1"] {
            let traceURL = fx.tracesDirURL.appendingPathComponent("\(laneID).trace")
            let lines = try String(contentsOf: traceURL, encoding: .utf8).components(separatedBy: .newlines)
            let endLine = try #require(lines.last(where: { $0.hasPrefix("end ") }))
            let stubExitEpoch = try #require(Double(endLine.split(separator: " ")[1]))
            latestStubExitEpoch = max(latestStubExitEpoch, stubExitEpoch)
            let laneObsEpoch = try #require(laneTerminalObservedEpoch[laneID], "Missing UI terminal state for \(laneID)")
            let lag = laneObsEpoch - stubExitEpoch
            #expect(lag >= 0.0 && lag <= 2.0, "Lane \(laneID) UI update lag \(lag)s exceeded 2.0s")
        }
        #expect(observedAllFourEpoch - latestStubExitEpoch <= 2.0, "Full PDF render lag \(observedAllFourEpoch - latestStubExitEpoch)s exceeded 2.0s")

        // Verify exact formatting rules & PDF number grounding across ALL 5 panes in both EN and ZH
        let (popTruth, popTermLog) = try collectGroundTruthNumbers(bundleURL: fx.projectURL)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            liveVM.setLanguage(lang, postToast: false)
            liveVM.selectPane(.ptyGrid)
            let ptyPDF = try renderWorkbenchPDFText(vm: liveVM)
            #expect(ptyPDF.contains("$0.1234"))
            #expect(ptyPDF.contains("$0.2500"))
            #expect(ptyPDF.contains("$0.3734"))
            #expect(ptyPDF.contains("4500"))
            #expect(ptyPDF.contains("1200"))
            #expect(!ptyPDF.contains("/ $0.00"))
            #expect(!ptyPDF.contains("$0.00"))
            if lang == .en {
                #expect(ptyPDF.contains("unpriced"))
                #expect(ptyPDF.contains("exit 3"))
                #expect(ptyPDF.contains("failed"))
            } else {
                #expect(ptyPDF.contains("未计价"))
                #expect(ptyPDF.contains("退出码 3"))
                #expect(ptyPDF.contains("失败"))
            }

            for pane in RelayStudioPane.allCases {
                liveVM.selectPane(pane)
                let pdfText = try renderWorkbenchPDFText(vm: liveVM)
                _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: liveVM)
                let unmatched = try unmatchedNumbersInPDF(
                    pdfText: pdfText,
                    groundTruth: popTruth,
                    terminalLogText: popTermLog,
                    hasActiveTerminalRows: (pane == .ptyGrid)
                )
                #expect(unmatched.isEmpty, "Populated non-demo pane \(pane.rawValue) (\(lang.rawValue)) rendered ungrounded numbers: \(unmatched)\nPDF:\n\(pdfText)")
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }
}
