import AppKit
import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelayPTYCore
import RelayStudioViews
import RelayWorkspaceStore
import Testing

@Suite("M5-01 Read-Only Live Workspace Observer & Streaming Terminal Buffer Tests", .serialized, .timeLimit(.minutes(2)))
struct M5LiveWorkspaceObserverTests {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private struct ObserverTestFixture {
        let rootURL: URL
        let homeURL: URL
        let repoURL: URL
        let projectURL: URL
        let decoyMarkerURL: URL
        let tracesDirURL: URL
        let tickStubURL: URL
        let supportStubURL: URL
        let environment: [String: String]
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ initial: T) { self.value = initial }
        func withValue<R>(_ body: (inout T) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
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
            throw NSError(domain: "M5LiveWorkspaceObserverTests", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out])
        }
    }

    private func makeFixture(prefix: String) throws -> ObserverTestFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("iso-home", isDirectory: true)
        let prefsURL = homeURL.appendingPathComponent("Library/Preferences", isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("LiveObs.relayproj", isDirectory: true)
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
        try runGit(["config", "user.name", "Relay M5 Tester"], cwd: repoURL, env: gitEnv)
        try runGit(["config", "user.email", "m5-tester@relay.invalid"], cwd: repoURL, env: gitEnv)
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

        let sourceSupportStub = Self.repositoryRootURL.appendingPathComponent("Tests/Support/stub-agent.sh")
        let supportStubURL = stubDirURL.appendingPathComponent("stub-agent.sh")
        try FileManager.default.copyItem(at: sourceSupportStub, to: supportStubURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportStubURL.path)

        let tickStubURL = stubDirURL.appendingPathComponent("tick-stub.py")
        let tickScript = #"""
        #!/usr/bin/env python3
        import json, os, sys, time

        args = sys.argv[1:]
        if args[:1] in (["--version"], ["-V"]):
            print("tick-stub 1.0.0")
            sys.exit(0)

        vendor = None
        workdir = os.getcwd()
        prompt_file = None
        vibe_dir = None
        codex_out = None
        i = 0
        while i < len(args):
            a = args[i]
            if a.startswith("--permission-mode") or a.startswith("--max-budget-usd"):
                vendor = "claude"
            elif a.startswith("--prompt-file"):
                vendor = "vibe"
                prompt_file = a.split("=", 1)[1] if "=" in a else args[i + 1]
                if "=" not in a:
                    i += 1
            elif a.startswith("--output-dir"):
                vendor = "vibe"
                vibe_dir = a.split("=", 1)[1] if "=" in a else args[i + 1]
                if "=" not in a:
                    i += 1
            elif a.startswith("--workdir"):
                vendor = "vibe"
                workdir = a.split("=", 1)[1] if "=" in a else args[i + 1]
                if "=" not in a:
                    i += 1
            elif a == "exec":
                vendor = "codex"
            elif a in ("-o", "--output-last-message") and i + 1 < len(args):
                codex_out = args[i + 1]
                i += 1
            elif a == "-C" and i + 1 < len(args):
                workdir = args[i + 1]
                i += 1
            i += 1

        if vendor in ("claude", "codex"):
            prompt_text = sys.stdin.read()
        elif vendor == "vibe" and prompt_file:
            with open(prompt_file, "r", encoding="utf-8") as fh:
                prompt_text = fh.read()
        else:
            prompt_text = ""

        lane = os.path.basename(os.path.realpath(workdir))
        cost_usd = 0.05
        tokens = 1200
        ticks = 4
        interval = 1.0
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
            elif line.startswith("WRITE="):
                write_rel = line.split("=", 1)[1].strip()

        emitted = []
        for seq in range(1, ticks + 1):
            if seq > 1:
                time.sleep(interval)
            ts = time.time()
            msg = f"TICK lane={lane} seq={seq} emit={ts:.6f}"
            emitted.append(msg)
            stream = sys.stderr if vendor == "vibe" else sys.stdout
            stream.write(msg + "\n")
            stream.flush()

        if write_rel:
            with open(os.path.join(workdir, write_rel), "w", encoding="utf-8") as wf:
                wf.write(f"updated by {lane}\n")

        summary = "\n".join(emitted) + f"\nDone {lane}\nSTATUS: success"
        in_tok = (tokens * 2) // 3
        out_tok = tokens - in_tok
        if vendor == "claude":
            payload = {
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "result": summary,
                "total_cost_usd": cost_usd,
                "session_id": f"stub-claude-{lane}",
                "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
            }
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()
        elif vendor == "vibe":
            sys.stdout.write(json.dumps([{"type": "message", "role": "assistant", "content": summary}]) + "\n")
            sys.stdout.flush()
            if vibe_dir:
                os.makedirs(vibe_dir, exist_ok=True)
                exp = {
                    "outcome": "finished",
                    "stop_reason": "end_turn",
                    "cost_usd": cost_usd,
                    "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
                    "config": {"active_model": "stub-vibe"},
                }
                with open(os.path.join(vibe_dir, "export.json"), "w", encoding="utf-8") as ef:
                    json.dump(exp, ef)
                    ef.write("\n")
        """#
        try tickScript.write(to: tickStubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tickStubURL.path)

        let env: [String: String] = [
            "HOME": homeURL.path,
            "CFFIXED_USER_HOME": homeURL.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "\(decoyDirURL.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "RELAYIDE_RELAY_SH": realRelay.url.path,
            "RELAY_CLAUDE_BIN": supportStubURL.path,
            "RELAY_CODEX_BIN": supportStubURL.path,
            "RELAY_AGY_BIN": supportStubURL.path,
            "RELAY_VIBE_BIN": supportStubURL.path,
            "STUB_TRACE_DIR": tracesDirURL.path
        ]

        return ObserverTestFixture(
            rootURL: rootURL,
            homeURL: homeURL,
            repoURL: repoURL,
            projectURL: projectURL,
            decoyMarkerURL: decoyMarkerURL,
            tracesDirURL: tracesDirURL,
            tickStubURL: tickStubURL,
            supportStubURL: supportStubURL,
            environment: env
        )
    }

    private func extractViewportLines(_ snapshot: TerminalViewportSnapshot) -> [String] {
        snapshot.visibleGrid.map { row in
            row.map(\.grapheme).joined().replacingOccurrences(
                of: #"\s+$"#,
                with: "",
                options: .regularExpression
            )
        }.filter { !$0.isEmpty }
    }

    @Test("Two parallel stub lanes printing 1 line/sec stream into VT100 buffers within <1.0s per line and match .relay logs (R7)")
    @MainActor
    func twoParallelLanesStreamLineByLineWithinOneSecondAndMatchRelayLogs() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-obs-stream")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        var env = fx.environment
        env["RELAY_CLAUDE_BIN"] = fx.tickStubURL.path
        env["RELAY_VIBE_BIN"] = fx.tickStubURL.path

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "LANE=lane-claude\nCOST=0.1234\nTOKENS=1500\nTICKS=4\nWRITE=claude.txt\n".write(
            to: promptsDir.appendingPathComponent("claude.md"), atomically: true, encoding: .utf8
        )
        try "LANE=lane-vibe\nCOST=0.2500\nTOKENS=900\nTICKS=4\nWRITE=vibe.txt\n".write(
            to: promptsDir.appendingPathComponent("vibe.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "lane-claude", "agent": "claude", "prompt": "prompts/claude.md", "after": []],
                    ["id": "lane-vibe", "agent": "vibe", "prompt": "prompts/vibe.md", "after": []]
                ],
                "verify": "true"
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        struct LineArrival {
            let emitEpoch: Double
            let observedEpoch: Double
            let visibleTickCountAtArrival: Int
        }
        let arrivals = LockedBox<[String: LineArrival]>([:])
        let latestSnapshotBox = LockedBox<RelayLiveWorkspaceSnapshot?>(nil)
        let tickRegex = try NSRegularExpression(pattern: #"TICK lane=(lane-[a-z]+) seq=([1-4]) emit=(\d+\.\d+)"#)

        let observer = RelayLiveWorkspaceObserver(projectBundleURL: fx.projectURL) { snap in
            let now = Date().timeIntervalSince1970
            latestSnapshotBox.withValue { $0 = snap }
            for laneID in ["lane-claude", "lane-vibe"] {
                guard let vp = snap.terminalSnapshotsByLane[laneID] else { continue }
                let lines = vp.visibleGrid.map { $0.map(\.grapheme).joined() }
                let joined = lines.joined(separator: "\n")
                let ns = joined as NSString
                let matches = tickRegex.matches(in: joined, range: NSRange(location: 0, length: ns.length))
                arrivals.withValue { dict in
                    for m in matches {
                        let mLane = ns.substring(with: m.range(at: 1))
                        let seq = ns.substring(with: m.range(at: 2))
                        let emitStr = ns.substring(with: m.range(at: 3))
                        let key = "\(mLane)#\(seq)"
                        if dict[key] == nil, let emitVal = Double(emitStr) {
                            dict[key] = LineArrival(
                                emitEpoch: emitVal,
                                observedEpoch: now,
                                visibleTickCountAtArrival: matches.count
                            )
                        }
                    }
                }
            }
        }
        observer.start()
        defer { observer.stop() }

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "en"],
            environment: env
        )
        #expect(runRes.exitCode == 0, "stderr=\(runRes.stderr)")

        // Allow up to 500ms after CLI return for final FSEvent/kqueue delivery if needed
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if let r = latestSnapshotBox.get()?.latestRun, r.status.isTerminal, arrivals.get().count == 8 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let recorded = arrivals.get()
        #expect(recorded.count == 8)

        for laneID in ["lane-claude", "lane-vibe"] {
            var distinctCounts = Set<Int>()
            for seq in 1...4 {
                let key = "\(laneID)#\(seq)"
                let item = try #require(recorded[key], "Missing streamed tick \(key)")
                let latency = item.observedEpoch - item.emitEpoch
                #expect(latency >= 0.0 && latency <= 1.0, "Tick \(key) latency \(latency)s exceeded 1.0s")
                distinctCounts.insert(item.visibleTickCountAtArrival)
            }
            // Must appear incrementally (not all 4 lines in a single end-of-run dump)
            #expect(distinctCounts.contains(1) || distinctCounts.contains(2))
            #expect(distinctCounts.count >= 3)
        }

        let finalSnap = try #require(latestSnapshotBox.get())
        let finalRun = try #require(finalSnap.latestRun)
        for laneRec in finalRun.lanes {
            let wtPath = try #require(laneRec.worktreePath)
            let relayDir = URL(fileURLWithPath: wtPath).appendingPathComponent(".relay", isDirectory: true)
            let logFiles = try FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            #expect(!logFiles.isEmpty)
            let rawLog = try logFiles.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let plainFromObserver = (finalSnap.terminalPlainTextByLane[laneRec.laneID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(plainFromObserver == rawLog)

            let vp = try #require(finalSnap.terminalSnapshotsByLane[laneRec.laneID])
            let vpJoined = extractViewportLines(vp).joined(separator: "\n")
            for seq in 1...4 {
                #expect(vpJoined.contains("TICK lane=\(laneRec.laneID) seq=\(seq) emit="))
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }

    @Test("Budget-refused lane without .relay/*.log displays refusal output from runs/<runID>/lanes/<lane>.pty")
    @MainActor
    func budgetRefusedLaneWithoutRelayLogDisplaysLanePTYOutput() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-obs-refused")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        var env = fx.environment
        env["RELAY_BUDGET_USD"] = "0.05"

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB LANE a\nSTUB WRITE a.txt first\nSTUB COST 0.0800\n".write(
            to: promptsDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE b\nSTUB WRITE b.txt second\nSTUB COST 0.0200\n".write(
            to: promptsDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []],
                    ["id": "b", "agent": "claude", "prompt": "prompts/b.md", "after": ["a"]]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let latestSnapshotBox = LockedBox<RelayLiveWorkspaceSnapshot?>(nil)
        let observer = RelayLiveWorkspaceObserver(projectBundleURL: fx.projectURL) { snap in
            latestSnapshotBox.withValue { $0 = snap }
        }
        observer.start()
        defer { observer.stop() }

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "en"],
            environment: env
        )
        #expect(runRes.exitCode != 0, "Expected non-zero exit when lane b is refused by budget; stderr=\(runRes.stderr)")

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let r = latestSnapshotBox.get()?.latestRun,
               r.status.isTerminal,
               let bText = latestSnapshotBox.get()?.terminalPlainTextByLane["b"],
               !bText.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let snap = try #require(latestSnapshotBox.get())
        let run = try #require(snap.latestRun)
        let laneB = try #require(run.lanes.first(where: { $0.laneID == "b" }))
        #expect(laneB.status == .refused)
        #expect(laneB.exitCode == 2)

        let bVP = try #require(snap.terminalSnapshotsByLane["b"])
        let bRendered = extractViewportLines(bVP).joined(separator: "\n")
        #expect(bRendered.contains("not started: the job budget"))
        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }

    @Test("Five-lane run (2 priced, 2 unpriced token-only, 1 failed exit 3) updates status, exitCode, duration, and spend within <2s plus 1s running tick")
    @MainActor
    func multiVendorAndFailedLanesUpdateWithinTwoSecondsWithRunningHeartbeat() async throws {
        enforceHeadlessZeroWindows()
        let fx = try makeFixture(prefix: "m5-obs-lanes")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB LANE c1\nSTUB SLEEP 1.3\nSTUB WRITE c1.txt ok\nSTUB COST 0.1234\n".write(
            to: promptsDir.appendingPathComponent("c1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE v1\nSTUB SLEEP 0.3\nSTUB WRITE v1.txt ok\nSTUB COST 0.2500\n".write(
            to: promptsDir.appendingPathComponent("v1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE a1\nSTUB SLEEP 0.3\nSTUB WRITE a1.txt ok\nSTUB TOKENS 4500\n".write(
            to: promptsDir.appendingPathComponent("a1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE x1\nSTUB SLEEP 0.3\nSTUB WRITE x1.txt ok\nSTUB TOKENS 1200\n".write(
            to: promptsDir.appendingPathComponent("x1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE f1\nSTUB SLEEP 0.4\nSTUB EXIT 3\n".write(
            to: promptsDir.appendingPathComponent("f1.md"), atomically: true, encoding: .utf8
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
                    ["id": "x1", "agent": "codex",  "prompt": "prompts/x1.md", "after": []],
                    ["id": "f1", "agent": "claude", "prompt": "prompts/f1.md", "after": []]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL)

        let terminalDetectedEpoch = LockedBox<[String: Double]>([:])
        let runningTickDates = LockedBox<[Date]>([])
        let latestSnapshotBox = LockedBox<RelayLiveWorkspaceSnapshot?>(nil)

        let observer = RelayLiveWorkspaceObserver(projectBundleURL: fx.projectURL) { snap in
            let now = Date()
            latestSnapshotBox.withValue { $0 = snap }
            if let run = snap.latestRun {
                if !run.status.isTerminal {
                    runningTickDates.withValue { $0.append(now) }
                }
                for lane in run.lanes where lane.status.isTerminal {
                    terminalDetectedEpoch.withValue { dict in
                        if dict[lane.laneID] == nil {
                            dict[lane.laneID] = now.timeIntervalSince1970
                        }
                    }
                }
            }
        }
        observer.start()
        defer { observer.stop() }

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(runRes.exitCode != 0, "Expected non-zero exit due to f1 exiting 3; stderr=\(runRes.stderr)")

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let r = latestSnapshotBox.get()?.latestRun, r.status.isTerminal, terminalDetectedEpoch.get().count == 5 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let snap = try #require(latestSnapshotBox.get())
        let run = try #require(snap.latestRun)
        #expect(abs(run.totalCostUSD - 0.3734) < 1e-6)
        #expect(run.unpricedTokens == 5700)

        let runningTicks = runningTickDates.get()
        #expect(runningTicks.count >= 2)
        if let firstTick = runningTicks.first, let lastTick = runningTicks.last {
            #expect(lastTick.timeIntervalSince(firstTick) >= 0.8)
        }

        let detected = terminalDetectedEpoch.get()
        for lane in run.lanes {
            let obsEpoch = try #require(detected[lane.laneID], "Lane \(lane.laneID) never observed terminal")
            let finAt = try #require(lane.finishedAt)
            let startAt = try #require(lane.startedAt)
            #expect(finAt.timeIntervalSince(startAt) > 0.1)

            // Compare against stub end trace timestamp (actual child exit time)
            let traceURL = fx.tracesDirURL.appendingPathComponent("\(lane.laneID).trace")
            let traceLines = try String(contentsOf: traceURL, encoding: .utf8).components(separatedBy: .newlines)
            let endLine = try #require(traceLines.last(where: { $0.hasPrefix("end ") }))
            let parts = endLine.split(separator: " ")
            let stubExitEpoch = try #require(Double(parts[1]))
            let lagFromExit = obsEpoch - stubExitEpoch
            #expect(lagFromExit >= 0.0 && lagFromExit <= 2.0, "Lane \(lane.laneID) update lag \(lagFromExit)s exceeded 2.0s")
        }

        let byID = Dictionary(uniqueKeysWithValues: run.lanes.map { ($0.laneID, $0) })
        #expect(byID["c1"]?.status == .succeeded)
        #expect(byID["c1"]?.exitCode == 0)
        #expect(byID["c1"]?.costSource == "usd")
        #expect(abs((byID["c1"]?.costUSD ?? 0) - 0.1234) < 1e-6)

        #expect(byID["v1"]?.status == .succeeded)
        #expect(byID["v1"]?.exitCode == 0)
        #expect(byID["v1"]?.costSource == "usd")
        #expect(abs((byID["v1"]?.costUSD ?? 0) - 0.2500) < 1e-6)

        #expect(byID["a1"]?.status == .succeeded)
        #expect(byID["a1"]?.exitCode == 0)
        #expect(byID["a1"]?.costSource == "unpriced")
        #expect(byID["a1"]?.costUSD == nil)
        #expect(byID["a1"]?.tokens == 4500)

        #expect(byID["x1"]?.status == .succeeded)
        #expect(byID["x1"]?.exitCode == 0)
        #expect(byID["x1"]?.costSource == "unpriced")
        #expect(byID["x1"]?.costUSD == nil)
        #expect(byID["x1"]?.tokens == 1200)

        #expect(byID["f1"]?.status == .failed)
        #expect(byID["f1"]?.exitCode == 3)

        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        enforceHeadlessZeroWindows()
    }
}
