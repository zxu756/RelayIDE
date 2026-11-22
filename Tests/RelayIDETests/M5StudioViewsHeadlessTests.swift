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
import RelayWorktreeGit
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
        write_body = None

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
            elif line.startswith("WRITE_CONTENT="):
                rest = line.split("=", 1)[1]
                rel, _, body = rest.partition("|")
                write_rel = rel.strip()
                write_body = body.replace("\\n", "\n")
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
            dst_path = os.path.join(workdir, write_rel)
            os.makedirs(os.path.dirname(dst_path) or workdir, exist_ok=True)
            with open(dst_path, "w", encoding="utf-8") as wf:
                if write_body is not None:
                    wf.write(write_body)
                else:
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
                for tbl in ["checkpoints", "managed_lanes", "dag_specs", "semantic_merge_reports", "guardrail_findings", "relay_runs", "relay_run_lanes", "relay_run_integration", "relay_run_merges"] {
                    if let cnt = queryInt("SELECT COUNT(*) FROM \(tbl);") {
                        truth.insert("\(cnt)")
                    }
                }
            }

            let projDB = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleURL)
            let gitInspector = RelayReadOnlyGitRunInspector()

            // Also include persisted `managed_lanes` git ownership numbers if `relay_runs` is empty
            let persistedManagedLanes = (try? projDB.allLanes()) ?? []
            var totalManagedOwnedFiles = 0
            for mLane in persistedManagedLanes {
                let snap = gitInspector.inspectLaneFileOwnership(
                    laneID: mLane.id,
                    worktreePath: mLane.worktreePath,
                    startCommitOID: mLane.baseCommitOID
                )
                totalManagedOwnedFiles += snap.files.count
                truth.insert("\(snap.files.count)")
                truth.insert("\(snap.totalAdditions)")
                truth.insert("\(snap.totalDeletions)")
                truth.insert("\(snap.committedFileCount)")
                truth.insert("\(snap.uncommittedFileCount)")
                for f in snap.files {
                    truth.insert("\(f.additions)")
                    truth.insert("\(f.deletions)")
                }
            }
            if !persistedManagedLanes.isEmpty {
                truth.insert("\(totalManagedOwnedFiles)")
            }

            let runs = try projDB.allRuns(reconcileWithLock: true)
            if let run = runs.last {
                truth.insert("\(run.lanes.count)")
                let termCount = run.lanes.filter(\.status.isTerminal).count
                truth.insert("\(termCount)")
                let succCount = run.lanes.filter { $0.status == .succeeded || $0.status == .succeededNoChanges }.count
                truth.insert("\(succCount)")
                if let runEnd = run.finishedAt {
                    truth.insert(String(format: "%.2f", max(0.0, runEnd.timeIntervalSince(run.startedAt))))
                }

                if run.pricedLaneCount > 0 {
                    truth.insert(String(format: "%.4f", run.totalCostUSD))
                }
                if run.unpricedTokens > 0 {
                    truth.insert("\(run.unpricedTokens)")
                }
                if let cap = run.budgetUSD {
                    truth.insert(String(format: "%.4f", cap))
                }

                if let integ = run.integration {
                    truth.insert("\(integ.merges.count)")
                    let totalConflicts = integ.merges.reduce(0) { $0 + $1.conflicts.count }
                    truth.insert("\(totalConflicts)")
                    let mergedCount = integ.merges.filter { $0.status == .merged }.count
                    truth.insert("\(mergedCount)")

                    for step in integ.merges {
                        truth.insert("\(step.ordinal)")
                        truth.insert("\(step.conflicts.count)")
                    }

                    let reconstructed = gitInspector.reconstructIntegrationConflictBlocks(
                        repositoryPath: run.repoPath,
                        integration: integ
                    )
                    for blk in reconstructed {
                        if let text = blk.conflictText {
                            combinedTerminalLogs += "\n" + text
                            truth.formUnion(try M5NumberProvenanceAndFieldAuditor.extractSafeLogNumbers(from: text, strippingIdentifiers: []))
                        }
                    }

                    if let verify = integ.verify {
                        truth.insert("\(verify.timeoutSec)")
                        truth.insert("\(verify.logBytes)")
                        if let vec = verify.exitCode {
                            truth.insert("\(vec)")
                        }
                        if let vs = verify.startedAt, let vf = verify.finishedAt {
                            truth.insert(String(format: "%.2f", max(0.0, vf.timeIntervalSince(vs))))
                        }
                        truth.formUnion(try M5NumberProvenanceAndFieldAuditor.extractSafeLogNumbers(from: verify.command, strippingIdentifiers: []))
                        let vPath = verify.logPath ?? bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("verify.pty")
                            .path
                        if let vText = try? String(contentsOfFile: vPath, encoding: .utf8), !vText.isEmpty {
                            combinedTerminalLogs += "\n" + vText
                            truth.formUnion(try M5NumberProvenanceAndFieldAuditor.extractSafeLogNumbers(from: vText, strippingIdentifiers: []))
                        }
                    }
                }

                var totalRunOwnedFiles = 0
                var totalRunCommittedFiles = 0
                var totalRunUncommittedFiles = 0
                var totalRunAdditions = 0
                var totalRunDeletions = 0

                for lane in run.lanes {
                    truth.insert("\(lane.ordinal)")
                    if let ec = lane.exitCode {
                        truth.insert("\(ec)")
                    }
                    if let tokCount = lane.tokens {
                        truth.insert("\(tokCount)")
                    }
                    if lane.costSource == "usd", let usd = lane.costUSD {
                        truth.insert(String(format: "%.4f", usd))
                    }
                    if let s = lane.startedAt {
                        truth.insert(String(format: "%.2f", max(0.0, s.timeIntervalSince(run.startedAt))))
                    }
                    if let f = lane.finishedAt {
                        truth.insert(String(format: "%.2f", max(0.0, f.timeIntervalSince(run.startedAt))))
                    }
                    if let s = lane.startedAt, let f = lane.finishedAt {
                        let dur = max(0.0, f.timeIntervalSince(s))
                        truth.insert(String(format: "%.2f", dur))
                    }

                    let wtDir = lane.worktreePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("worktrees", isDirectory: true)
                            .appendingPathComponent(lane.laneID, isDirectory: true)
                    let startOID = RelayReadOnlyGitRunInspector.resolveLaneStartCommitOID(for: lane, in: run)
                    let ownSnap = gitInspector.inspectLaneFileOwnership(
                        laneID: lane.laneID,
                        worktreePath: wtDir.path,
                        startCommitOID: startOID
                    )
                    totalRunOwnedFiles += ownSnap.files.count
                    totalRunCommittedFiles += ownSnap.committedFileCount
                    totalRunUncommittedFiles += ownSnap.uncommittedFileCount
                    totalRunAdditions += ownSnap.totalAdditions
                    totalRunDeletions += ownSnap.totalDeletions
                    truth.insert("\(ownSnap.files.count)")
                    truth.insert("\(ownSnap.totalAdditions)")
                    truth.insert("\(ownSnap.totalDeletions)")
                    truth.insert("\(ownSnap.committedFileCount)")
                    truth.insert("\(ownSnap.uncommittedFileCount)")
                    for f in ownSnap.files {
                        truth.insert("\(f.additions)")
                        truth.insert("\(f.deletions)")
                    }
                    let relayDir = wtDir.appendingPathComponent(".relay", isDirectory: true)
                    let logSpend = M5NumberProvenanceAndFieldAuditor.parseIndependentLaneLogSpend(worktreeURL: wtDir)
                    if logSpend.costSource == "usd", let usd = logSpend.costUSD {
                        truth.insert(String(format: "%.4f", usd))
                    } else if logSpend.costSource == "unpriced", let tok = logSpend.tokens {
                        truth.insert("\(tok)")
                    }

                    var hadStepLog = false
                    let refVT = VT100TerminalScreenBuffer(laneID: lane.laneID, rows: 26, columns: 96)
                    if let items = try? FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil) {
                        for f in items.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                            if let txt = try? String(contentsOf: f, encoding: .utf8), !txt.isEmpty {
                                hadStepLog = true
                                combinedTerminalLogs += "\n" + txt
                                truth.formUnion(try M5NumberProvenanceAndFieldAuditor.extractSafeLogNumbers(from: txt, strippingIdentifiers: []))
                                let crlf = txt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
                                refVT.feed(Data(crlf.utf8))
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
                            truth.formUnion(try M5NumberProvenanceAndFieldAuditor.extractSafeLogNumbers(from: ptyText, strippingIdentifiers: []))
                            refVT.feed(Data(ptyText.utf8))
                        }
                    }
                    let vtWrapped = refVT.snapshot().visibleGrid.map { row in
                        row.map { $0.grapheme }.joined().trimmingCharacters(in: .whitespaces)
                    }.joined(separator: "\n")
                    if !vtWrapped.isEmpty {
                        truth.formUnion(try M5NumberProvenanceAndFieldAuditor.extractSafeLogNumbers(from: vtWrapped, strippingIdentifiers: []))
                    }
                }
                truth.insert("\(totalRunOwnedFiles)")
                truth.insert("\(totalRunCommittedFiles)")
                truth.insert("\(totalRunUncommittedFiles)")
                truth.insert("\(totalRunAdditions)")
                truth.insert("\(totalRunDeletions)")
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
        // Scrub rendered hex OIDs, runIDs (YYYYMMDD-HHMMSS-xxxx), and alphanumeric identifiers as whole tokens only
        let identRegex = try NSRegularExpression(pattern: #"\b(?:\d{8}-\d{6}-[0-9a-fA-F]{4}|(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{7,64}|[A-Za-z][A-Za-z0-9_.-]*\d[A-Za-z0-9_.-]*)\b"#)
        scrubbed = identRegex.stringByReplacingMatches(
            in: scrubbed,
            range: NSRange(location: 0, length: (scrubbed as NSString).length),
            withTemplate: " "
        )
        let extracted = try M5NumberProvenanceAndFieldAuditor.extractCompleteNumberTokens(from: scrubbed)
        return extracted.filter { token in
            if groundTruth.contains(token) {
                return false
            }
            if hasActiveTerminalRows && Self.explicitTerminalGutterRowNumbers.contains(token) {
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

    @Test("File ownership pane (⌘4) refreshes tracked edit and untracked file within <2s in ViewModel and PDF, excludes .relay/.git, and retains committed files")
    @MainActor
    func liveFileOwnershipPaneRefreshesTrackedAndUntrackedWithinTwoSecondsAndRetainsCommittedFiles() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-02-ownership-live")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gitEnv: [String: String] = [
            "HOME": fx.homeURL.path,
            "CFFIXED_USER_HOME": fx.homeURL.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]
        try "public struct TrackedEngine {\n    public static let level = 1\n}\n".write(
            to: fx.repoURL.appendingPathComponent("TrackedEngine.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "TrackedEngine.swift"], cwd: fx.repoURL, env: gitEnv)
        try runGit(["commit", "-m", "add TrackedEngine"], cwd: fx.repoURL, env: gitEnv)

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "LANE=lane-one\nCOST=0.0400\nTOKENS=800\nWRITE=InitialCommitted.swift\n".write(
            to: promptsDir.appendingPathComponent("one.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-two\nCOST=0.0500\nTOKENS=900\nWRITE=LaneTwoFile.swift\n".write(
            to: promptsDir.appendingPathComponent("two.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "lane-one", "agent": "claude", "prompt": promptsDir.appendingPathComponent("one.md").path],
                    ["id": "lane-two", "agent": "vibe", "prompt": promptsDir.appendingPathComponent("two.md").path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(runRes.exitCode == 0, "Setup 2-lane run failed: \(runRes.stderr)")

        let loc = RelayLocalizer(language: .en, persistToUserDefaults: false)
        let vm = RelayStudioViewModel(
            projectBundleURL: fx.projectURL,
            initialPane: .territoryMap,
            localizer: loc,
            loadDemoWorkspace: false
        )
        vm.selectPane(.territoryMap)

        let run = try #require(vm.activeRun)
        let laneOneRec = try #require(run.lanes.first(where: { $0.laneID == "lane-one" }))
        let wtOnePath = try #require(laneOneRec.worktreePath)
        let wtOneURL = URL(fileURLWithPath: wtOnePath, isDirectory: true)
        let startOID = RelayReadOnlyGitRunInspector.resolveLaneStartCommitOID(for: laneOneRec, in: run)

        // Wait briefly for initial live worktree watcher startup & initial baseline scan to settle before timing edits
        let initDeadline = Date().addingTimeInterval(2.0)
        while Date() < initDeadline {
            if vm.liveFileOwnershipByLane["lane-one"]?.files.contains(where: { $0.relativePath == "InitialCommitted.swift" }) == true {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        // Write internal .relay noise and ensure neither .relay nor 2.5D demo towers appear
        try "internal relay log\n".write(
            to: wtOneURL.appendingPathComponent(".relay/noise-check.log"),
            atomically: true,
            encoding: .utf8
        )

        // (1) Modify tracked file TrackedEngine.swift -> < 2.0s in ViewModel AND rendered PDF
        let trackedStartEpoch = Date().timeIntervalSince1970
        try "public struct TrackedEngine {\n    public static let level = 2\n    public static let active = true\n}\n".write(
            to: wtOneURL.appendingPathComponent("TrackedEngine.swift"),
            atomically: true,
            encoding: .utf8
        )
        var trackedVMEpoch: Double?
        var trackedPDFEpoch: Double?
        let trackedDeadline = Date().addingTimeInterval(3.0)
        while Date() < trackedDeadline {
            if let snap = vm.liveFileOwnershipByLane["lane-one"],
               snap.files.contains(where: { $0.relativePath == "TrackedEngine.swift" && $0.worktreeState == .uncommittedInWorktree }) {
                if trackedVMEpoch == nil {
                    trackedVMEpoch = Date().timeIntervalSince1970
                }
                let pdf = try renderWorkbenchPDFText(vm: vm)
                if pdf.contains("TrackedEngine.swift") {
                    trackedPDFEpoch = Date().timeIntervalSince1970
                    break
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let obsTrackedVM = try #require(trackedVMEpoch, "TrackedEngine.swift did not appear in vm.liveFileOwnershipByLane")
        let obsTrackedPDF = try #require(trackedPDFEpoch, "TrackedEngine.swift did not appear in ⌘4 PDF render")
        let trackedVMLatency = obsTrackedVM - trackedStartEpoch
        let trackedPDFLatency = obsTrackedPDF - trackedStartEpoch
        #expect(trackedVMLatency >= 0.0 && trackedVMLatency <= 2.0, "Tracked file VM latency \(trackedVMLatency)s > 2.0s")
        #expect(trackedPDFLatency >= 0.0 && trackedPDFLatency <= 2.0, "Tracked file PDF latency \(trackedPDFLatency)s > 2.0s")

        // (2) Create untracked file FreshUntracked.swift -> < 2.0s in ViewModel AND rendered PDF
        let untrackedStartEpoch = Date().timeIntervalSince1970
        try "public enum FreshUntracked {\n    public static let ok = true\n}\n".write(
            to: wtOneURL.appendingPathComponent("FreshUntracked.swift"),
            atomically: true,
            encoding: .utf8
        )
        var untrackedVMEpoch: Double?
        var untrackedPDFEpoch: Double?
        let untrackedDeadline = Date().addingTimeInterval(3.0)
        while Date() < untrackedDeadline {
            if let snap = vm.liveFileOwnershipByLane["lane-one"],
               snap.files.contains(where: { $0.relativePath == "FreshUntracked.swift" && $0.worktreeState == .uncommittedInWorktree }) {
                if untrackedVMEpoch == nil {
                    untrackedVMEpoch = Date().timeIntervalSince1970
                }
                let pdf = try renderWorkbenchPDFText(vm: vm)
                if pdf.contains("FreshUntracked.swift") {
                    untrackedPDFEpoch = Date().timeIntervalSince1970
                    break
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let obsUntrackedVM = try #require(untrackedVMEpoch, "FreshUntracked.swift did not appear in vm.liveFileOwnershipByLane")
        let obsUntrackedPDF = try #require(untrackedPDFEpoch, "FreshUntracked.swift did not appear in ⌘4 PDF render")
        let untrackedVMLatency = obsUntrackedVM - untrackedStartEpoch
        let untrackedPDFLatency = obsUntrackedPDF - untrackedStartEpoch
        #expect(untrackedVMLatency >= 0.0 && untrackedVMLatency <= 2.0, "Untracked file VM latency \(untrackedVMLatency)s > 2.0s")
        #expect(untrackedPDFLatency >= 0.0 && untrackedPDFLatency <= 2.0, "Untracked file PDF latency \(untrackedPDFLatency)s > 2.0s")
        print(
            String(
                format: "[M5-02-METRIC] tracked_vm_s=%.4f tracked_pdf_s=%.4f untracked_vm_s=%.4f untracked_pdf_s=%.4f",
                trackedVMLatency,
                trackedPDFLatency,
                untrackedVMLatency,
                untrackedPDFLatency
            )
        )

        // Verify .relay/ and .git/ never leak into ownership data or PDF
        for (_, snap) in vm.liveFileOwnershipByLane {
            #expect(!snap.files.contains(where: { $0.relativePath.contains(".relay") || $0.relativePath.contains(".git") }))
        }
        let preCommitPDF = try renderWorkbenchPDFText(vm: vm)
        #expect(!preCommitPDF.contains("noise-check.log"))
        #expect(!preCommitPDF.contains("AuthSessionManager.swift"))
        #expect(preCommitPDF.contains("uncommitted"))

        // (3) Commit on lane-one branch -> files MUST remain in ownership list & PDF as committed (compared against startCommitOID)
        let engine = GitWorktreePlumbingEngine()
        _ = try engine.commitLaneChangesIfNeeded(
            worktreePath: wtOnePath,
            startCommitOID: startOID,
            runID: run.runID,
            laneID: "lane-one",
            agent: .claude,
            status: .succeeded,
            environment: gitEnv
        )
        var committedObserved = false
        let commitDeadline = Date().addingTimeInterval(2.0)
        while Date() < commitDeadline {
            if let snap = vm.liveFileOwnershipByLane["lane-one"],
               snap.files.count == 3,
               snap.files.allSatisfy({ $0.worktreeState == .committedToLane }) {
                committedObserved = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(committedObserved, "Files disappeared or failed to update to committedToLane after lane commit")

        let (truth, termLogs) = try collectGroundTruthNumbers(bundleURL: fx.projectURL)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            vm.setLanguage(lang, postToast: false)
            vm.selectPane(.territoryMap)
            let pdf = try renderWorkbenchPDFText(vm: vm)
            _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: vm)
            #expect(pdf.contains("TrackedEngine.swift"))
            #expect(pdf.contains("FreshUntracked.swift"))
            #expect(pdf.contains("InitialCommitted.swift"))
            #expect(pdf.contains("LaneTwoFile.swift"))
            #expect(!pdf.contains("noise-check.log"))
            if lang == .en {
                #expect(pdf.contains("committed"))
            } else {
                #expect(pdf.contains("已提交"))
            }
            let unmatched = try unmatchedNumbersInPDF(
                pdfText: pdf,
                groundTruth: truth,
                terminalLogText: termLogs,
                hasActiveTerminalRows: false
            )
            #expect(unmatched.isEmpty, "⌘4 ownership pane (\(lang.rawValue)) rendered ungrounded numbers: \(unmatched)\nPDF:\n\(pdf)")
        }

        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }

    private static func collectAllSwiftFilesUnderSources() -> [URL] {
        let sourcesURL = repositoryRootURL.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var urls: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            if next.pathExtension == "swift" {
                urls.append(next)
            }
        }
        return urls
    }

    @Test("Merge pane (⌘3) renders M2 verified integration + verify.pty and conflicted integration + git merge-file -p blocks in EN & ZH, and fixes R74")
    @MainActor
    func mergePaneRendersCleanVerifiedAndConflictedRunsWithGitMergeFileBlocksAndFixesR74() async throws {
        enforceHeadlessZeroWindows()

        // R74 repo-wide Sources/ static audit: dead preference toggle and hardcoded 18/24 conflict evidence must not exist in Sources/
        let forbiddenNeedles: [String] = [
            "autoRunSemanticMerge" + "OnHandoff",
            "Disabled before " + "M3",
            "M3 " + "前默认关闭",
            "passedTestCount: " + "18",
            "passedTestCount: " + "24",
            "18/" + "18 Tests",
            "18/" + "18 测试"
        ]
        for fileURL in Self.collectAllSwiftFilesUnderSources() {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            for needle in forbiddenNeedles {
                #expect(!text.contains(needle), "R74 violation: \(fileURL.lastPathComponent) still contains '\(needle)'")
            }
        }

        // Case ①: Clean 2-lane merge + verify passed
        let cleanFX = try makeFixture(prefix: "m5-02-merge-clean")
        defer { try? FileManager.default.removeItem(at: cleanFX.rootURL) }

        let cleanPrompts = cleanFX.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanPrompts, withIntermediateDirectories: true)
        try "LANE=lane-alpha\nCOST=0.0500\nTOKENS=700\nWRITE_CONTENT=Alpha.swift|public enum Alpha { public static let ok = true }\\n\n".write(
            to: cleanPrompts.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-beta\nCOST=0.0600\nTOKENS=850\nWRITE_CONTENT=Beta.swift|public enum Beta { public static let ok = true }\\n\n".write(
            to: cleanPrompts.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8
        )
        let cleanPlanURL = cleanFX.rootURL.appendingPathComponent("plan_clean.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": cleanFX.repoURL.path,
                "base": "main",
                "verify": "printf 'VERIFY_PTY_SUCCESS_BANNER_OK\\n' && test -f Alpha.swift && test -f Beta.swift",
                "lanes": [
                    ["id": "lane-alpha", "agent": "claude", "prompt": cleanPrompts.appendingPathComponent("alpha.md").path],
                    ["id": "lane-beta", "agent": "vibe", "prompt": cleanPrompts.appendingPathComponent("beta.md").path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: cleanPlanURL)

        let cli = RelayCLIRunner()
        let cleanRunRes = await cli.executeCommand(
            arguments: ["run", cleanPlanURL.path, "--project", cleanFX.projectURL.path, "--lang", "en"],
            environment: cleanFX.environment
        )
        #expect(cleanRunRes.exitCode == 0, "Clean merge + verify run failed: \(cleanRunRes.stderr)")

        let cleanVM = RelayStudioViewModel(
            projectBundleURL: cleanFX.projectURL,
            initialPane: .semanticMerge,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )
        let cleanInteg = try #require(cleanVM.activeRun?.integration)
        #expect(cleanInteg.status == .verified)
        #expect(cleanInteg.ready == true)
        #expect(cleanInteg.merges.count == 2)

        let (cleanTruth, cleanTermLogs) = try collectGroundTruthNumbers(bundleURL: cleanFX.projectURL)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            cleanVM.setLanguage(lang, postToast: false)
            cleanVM.selectPane(.semanticMerge)
            let pdf = try renderWorkbenchPDFText(vm: cleanVM)
            _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: cleanVM)

            #expect(pdf.contains("verified"))
            #expect(pdf.contains("ready: true"))
            if lang == .zhHans {
                #expect(pdf.contains("已验证"))
                #expect(pdf.contains("已就绪"))
            }
            for step in cleanInteg.merges {
                let mergeOID = try #require(step.mergeCommitOID)
                #expect(pdf.contains(mergeOID), "⌘3 PDF (\(lang.rawValue)) missing mergeCommitOID \(mergeOID)")
            }
            #expect(pdf.contains("VERIFY_PTY_SUCCESS_BANNER_OK"))
            #expect(!pdf.contains("Resolve All via Verified Lane"))
            #expect(!pdf.contains("Accept Left"))
            #expect(!pdf.contains("采纳左侧"))

            for pane in [RelayStudioPane.dagPipeline, .semanticMerge, .territoryMap] {
                cleanVM.selectPane(pane)
                let panePDF = try renderWorkbenchPDFText(vm: cleanVM)
                _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: cleanVM)
                let unmatched = try unmatchedNumbersInPDF(
                    pdfText: panePDF,
                    groundTruth: cleanTruth,
                    terminalLogText: cleanTermLogs,
                    hasActiveTerminalRows: false
                )
                #expect(unmatched.isEmpty, "Clean run pane \(pane.rawValue) (\(lang.rawValue)) rendered ungrounded numbers: \(unmatched)\nPDF:\n\(panePDF)")
            }

            // Also verify ⌘, Preferences modal has zero dead R74 toggle and zero ungrounded numbers
            cleanVM.isPreferencesModalPresented = true
            let prefsPDF = try renderWorkbenchPDFText(vm: cleanVM)
            #expect(!prefsPDF.contains("Auto-Run 3-Way"))
            #expect(!prefsPDF.contains("自动执行三路 AST"))
            cleanVM.isPreferencesModalPresented = false
        }

        // Case ②: Two lanes modify the same line -> Git conflict reconstructed via `git merge-file -p`
        let confFX = try makeFixture(prefix: "m5-02-merge-conflict")
        defer { try? FileManager.default.removeItem(at: confFX.rootURL) }

        let gitEnv: [String: String] = [
            "HOME": confFX.homeURL.path,
            "CFFIXED_USER_HOME": confFX.homeURL.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]
        let baseSource = "public enum SharedConfig {\n    public static let mode = \"baseline\"\n}\n"
        let leftSource = "public enum SharedConfig {\n    public static let mode = \"left-lane-choice\"\n}\n"
        let rightSource = "public enum SharedConfig {\n    public static let mode = \"right-lane-choice\"\n}\n"
        try baseSource.write(
            to: confFX.repoURL.appendingPathComponent("SharedConfig.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "SharedConfig.swift"], cwd: confFX.repoURL, env: gitEnv)
        try runGit(["commit", "-m", "add SharedConfig"], cwd: confFX.repoURL, env: gitEnv)

        let confPrompts = confFX.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: confPrompts, withIntermediateDirectories: true)
        try "LANE=lane-left\nCOST=0.0500\nTOKENS=600\nWRITE_CONTENT=SharedConfig.swift|public enum SharedConfig {\\n    public static let mode = \"left-lane-choice\"\\n}\\n\n".write(
            to: confPrompts.appendingPathComponent("left.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-right\nCOST=0.0600\nTOKENS=650\nWRITE_CONTENT=SharedConfig.swift|public enum SharedConfig {\\n    public static let mode = \"right-lane-choice\"\\n}\\n\n".write(
            to: confPrompts.appendingPathComponent("right.md"), atomically: true, encoding: .utf8
        )
        let confPlanURL = confFX.rootURL.appendingPathComponent("plan_conflict.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": confFX.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "lane-left", "agent": "claude", "prompt": confPrompts.appendingPathComponent("left.md").path],
                    ["id": "lane-right", "agent": "vibe", "prompt": confPrompts.appendingPathComponent("right.md").path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: confPlanURL)

        let confRunRes = await cli.executeCommand(
            arguments: ["run", confPlanURL.path, "--project", confFX.projectURL.path, "--lang", "en"],
            environment: confFX.environment
        )
        #expect(confRunRes.exitCode != 0, "Conflict run must exit non-zero")

        // Independently run `git merge-file -p` in test temp directory to obtain ground-truth conflict block
        let refMergeDir = confFX.rootURL.appendingPathComponent("ref-merge-file", isDirectory: true)
        try FileManager.default.createDirectory(at: refMergeDir, withIntermediateDirectories: true)
        let oursPath = refMergeDir.appendingPathComponent("ours").path
        let basePath = refMergeDir.appendingPathComponent("base").path
        let theirsPath = refMergeDir.appendingPathComponent("theirs").path
        try leftSource.write(toFile: oursPath, atomically: true, encoding: .utf8)
        try baseSource.write(toFile: basePath, atomically: true, encoding: .utf8)
        try rightSource.write(toFile: theirsPath, atomically: true, encoding: .utf8)
        let refGit = try GitWorktreePlumbingEngine().runGitCommand(
            ["merge-file", "-p", "-L", "integration", "-L", "base", "-L", "lane-right", oursPath, basePath, theirsPath],
            cwd: refMergeDir.path,
            environment: gitEnv
        )
        #expect(refGit.exitCode > 0 && refGit.exitCode < 128)
        let expectedConflictText = refGit.stdout

        let confVM = RelayStudioViewModel(
            projectBundleURL: confFX.projectURL,
            initialPane: .semanticMerge,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )
        let confInteg = try #require(confVM.activeRun?.integration)
        #expect(confInteg.status == .conflict)
        #expect(confInteg.ready == false)
        #expect(confVM.liveConflictBlocks.count == 1)
        #expect(confVM.liveConflictBlocks.first?.path == "SharedConfig.swift")
        #expect(confVM.liveConflictBlocks.first?.conflictText == expectedConflictText)

        let (confTruth, confTermLogs) = try collectGroundTruthNumbers(bundleURL: confFX.projectURL)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            confVM.setLanguage(lang, postToast: false)
            confVM.selectPane(.semanticMerge)
            let pdf = try renderWorkbenchPDFText(vm: confVM)
            _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: confVM)

            #expect(pdf.contains("conflict"))
            #expect(pdf.contains("ready: false"))
            if lang == .zhHans {
                #expect(pdf.contains("冲突"))
                #expect(pdf.contains("未就绪"))
            }
            #expect(pdf.contains("SharedConfig.swift"))
            #expect(pdf.contains("UU"))
            for expectedLine in expectedConflictText.split(whereSeparator: \.isNewline).map(String.init) {
                let trimmed = expectedLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    #expect(pdf.contains(trimmed), "⌘3 conflict PDF (\(lang.rawValue)) missing git merge-file -p line: '\(trimmed)'\nPDF:\n\(pdf)")
                }
            }
            #expect(!pdf.contains("Resolve All via Verified Lane"))
            #expect(!pdf.contains("Accept Left"))

            for pane in [RelayStudioPane.dagPipeline, .semanticMerge, .territoryMap] {
                confVM.selectPane(pane)
                let panePDF = try renderWorkbenchPDFText(vm: confVM)
                _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: confVM)
                let unmatched = try unmatchedNumbersInPDF(
                    pdfText: panePDF,
                    groundTruth: confTruth,
                    terminalLogText: confTermLogs,
                    hasActiveTerminalRows: false
                )
                #expect(unmatched.isEmpty, "Conflict run pane \(pane.rawValue) (\(lang.rawValue)) rendered ungrounded numbers: \(unmatched)\nPDF:\n\(panePDF)")
            }
        }

        // Demo mode still retains interactive AST resolution controls
        let demoVM = RelayStudioViewModel(
            initialPane: .semanticMerge,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: true
        )
        let demoPDF = try renderWorkbenchPDFText(vm: demoVM)
        #expect(demoPDF.contains("Accept Left"))

        #expect(!FileManager.default.fileExists(atPath: cleanFX.decoyMarkerURL.path))
        #expect(!FileManager.default.fileExists(atPath: confFX.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }

    @Test("DAG pane (⌘2) renders empty state when no run exists and draws real RelayRunRecord.lanes after-dependencies and measured timings without ungrounded numbers")
    @MainActor
    func dagPaneRendersLiveRunDependenciesAndMeasuredTimingsOrEmptyStateWithoutUngroundedNumbers() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-02-dag-live")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        // 1. Empty workspace: must show empty state explanation, NO synthetic 4-node graph, NO 1.00×
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let emptyVM = RelayStudioViewModel(
                projectBundleURL: fx.projectURL,
                initialPane: .dagPipeline,
                localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                loadDemoWorkspace: false
            )
            emptyVM.selectPane(.dagPipeline)
            let emptyPDF = try renderWorkbenchPDFText(vm: emptyVM)
            _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: emptyVM)
            #expect(!emptyPDF.contains("1.00×"))
            #expect(!emptyPDF.contains("h3-quic-transport"))
            #expect(!emptyPDF.contains("Parallel Speedup"))
            #expect(!emptyPDF.contains("并行加速比"))
        }

        // 2. Real 3-lane run with `after` dependency (`lane-root` -> `lane-child`, plus parallel `lane-peer`)
        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "LANE=lane-root\nSLEEP=0.15\nCOST=0.0300\nTOKENS=500\nWRITE=root.txt\n".write(
            to: promptsDir.appendingPathComponent("root.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-child\nSLEEP=0.15\nCOST=0.0400\nTOKENS=600\nWRITE=child.txt\n".write(
            to: promptsDir.appendingPathComponent("child.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-peer\nSLEEP=0.20\nTOKENS=1100\nWRITE=peer.txt\n".write(
            to: promptsDir.appendingPathComponent("peer.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.rootURL.appendingPathComponent("plan_dag.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "lane-root", "agent": "claude", "prompt": promptsDir.appendingPathComponent("root.md").path],
                    ["id": "lane-child", "agent": "vibe", "prompt": promptsDir.appendingPathComponent("child.md").path, "after": ["lane-root"]],
                    ["id": "lane-peer", "agent": "codex", "prompt": promptsDir.appendingPathComponent("peer.md").path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(runRes.exitCode == 0, "3-lane DAG run failed: \(runRes.stderr)")

        let dagVM = RelayStudioViewModel(
            projectBundleURL: fx.projectURL,
            initialPane: .dagPipeline,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )
        let run = try #require(dagVM.activeRun)
        #expect(run.lanes.count == 3)

        let (truth, termLogs) = try collectGroundTruthNumbers(bundleURL: fx.projectURL)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            dagVM.setLanguage(lang, postToast: false)
            dagVM.selectPane(.dagPipeline)
            let pdf = try renderWorkbenchPDFText(vm: dagVM)
            _ = try renderWorkbenchBitmapAndVerifyNonBlank(vm: dagVM)

            #expect(pdf.contains("lane-root"))
            #expect(pdf.contains("lane-child"))
            #expect(pdf.contains("lane-peer"))
            #expect(!pdf.contains("1.00×"))
            #expect(!pdf.contains("Parallel Speedup"))
            #expect(!pdf.contains("并行加速比"))
            if lang == .en {
                #expect(pdf.contains("after: lane-root"))
            } else {
                #expect(pdf.contains("依赖: lane-root"))
            }
            for lane in run.lanes {
                if let dur = dagVM.formattedLiveLaneDuration(forLane: lane.laneID) {
                    #expect(pdf.contains(dur), "⌘2 DAG PDF (\(lang.rawValue)) missing measured duration \(dur) for \(lane.laneID)")
                }
            }

            let unmatched = try unmatchedNumbersInPDF(
                pdfText: pdf,
                groundTruth: truth,
                terminalLogText: termLogs,
                hasActiveTerminalRows: false
            )
            #expect(unmatched.isEmpty, "⌘2 DAG pane (\(lang.rawValue)) rendered ungrounded numbers: \(unmatched)\nPDF:\n\(pdf)")
        }

        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }

    @Test("RelayRetinaScreenshotExporter prepares ViewModel from real .relayproj without demo overrides or opening windows")
    @MainActor
    func screenshotExporterSupportsRealProjectBundleLoadingWithoutOpeningWindows() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-02-exporter-prep")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "LANE=lane-exp\nCOST=0.0700\nTOKENS=950\nWRITE=Exp.swift\n".write(
            to: promptsDir.appendingPathComponent("exp.md"), atomically: true, encoding: .utf8
        )
        let planURL = fx.rootURL.appendingPathComponent("plan_exp.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "lane-exp", "agent": "claude", "prompt": promptsDir.appendingPathComponent("exp.md").path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(runRes.exitCode == 0)

        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let preparedVM = try RelayRetinaScreenshotExporter.prepareWorkbenchViewModel(
                projectBundleURL: fx.projectURL,
                initialPane: .semanticMerge,
                language: lang
            )
            #expect(preparedVM.isDemoMode == false)
            #expect(preparedVM.activePane == .semanticMerge)
            #expect(preparedVM.lanes.map(\.id) == ["lane-exp"])
            #expect(preparedVM.activeRun?.lanes.count == 1)
            #expect(preparedVM.isBroadcastBarExpanded == false)
            #expect(preparedVM.coordinator.toastCenter.visibleToasts.isEmpty)
        }

        // Missing bundle path must throw without creating a fake directory on disk
        let missingURL = fx.rootURL.appendingPathComponent("DoesNotExist.relayproj", isDirectory: true)
        #expect(throws: (any Error).self) {
            _ = try RelayRetinaScreenshotExporter.prepareWorkbenchViewModel(projectBundleURL: missingURL)
        }
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))

        enforceHeadlessZeroWindows()
    }
}
