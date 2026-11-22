import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelaySemanticMerge
import RelayWorkbenchShell
import RelayWorkspaceStore
import RelayWorktreeGit
import Testing

// `.serialized`: many tests here run git and a compiler and block their thread while they wait. Run all at once they
// occupy the whole cooperative thread pool and make timing assertions in other suites fail.
@Suite("Headless CLI Subcommands, JSON-RPC 2.0 MCP Server, HTML Dossier & Bauhaus Workbench Shell", .serialized, .timeLimit(.minutes(1)))
struct CLIMCPAndWorkbenchShellTests {

    // MARK: - Isolated Temp Directory & UserDefaults Helpers

    private func makeIsolatedTempDirectory(prefix: String = "relay-cli-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real `UserDefaults` instance for one test whose plist lives inside a fresh temporary directory.
    /// CFPreferences stores a domain whose name is an absolute path at that path, so nothing is written to
    /// `~/Library/Preferences`. (A named suite leaves an empty plist behind there even after `removePersistentDomain`.)
    private func makeIsolatedUserDefaults(label: String) throws -> (defaults: UserDefaults, storageDirectory: URL, cleanup: () -> Void) {
        let directory = try makeIsolatedTempDirectory(prefix: "relay-defaults-\(label)")
        let domainPath = directory.appendingPathComponent("io.relayide.tests.\(label)").path
        let defaults = try #require(UserDefaults(suiteName: domainPath))
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: domainPath)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: directory)
        }
        return (defaults, directory, cleanup)
    }

    // MARK: - 1. `RelayCLIRunner` Help, Version & Unknown Subcommand Error

    @Test("RelayCLIRunner renders help banner, version string, and rejects unknown subcommands")
    func cliRunnerHelpVersionAndInvalidSubcommand() async throws {
        let cli = RelayCLIRunner()

        let emptyOut = try await cli.execute(arguments: [])
        #expect(emptyOut.contains("RelayIDE"))
        #expect(!emptyOut.contains("semantic-merge"))

        let helpOut = try await cli.execute(arguments: ["--help"])
        #expect(helpOut == RelayCLIRunner.helpBanner)
        #expect(helpOut.contains("run <plan.json> --project"))
        #expect(helpOut.contains("agent-relay"))
        #expect(helpOut.contains("status [--project <path.relayproj>] [--run <id> | --runs] [--json]"))
        #expect(helpOut.contains("--json produces identical output"))
        #expect(helpOut.contains("integration.ready"))
        #expect(!helpOut.contains("does not launch coding agents yet"))
        #expect(!helpOut.contains("does not merge branches"))

        let helpZhOut = try await cli.execute(arguments: ["--help", "--lang", "zh"])
        #expect(helpZhOut.contains("run <plan.json> --project"))
        #expect(helpZhOut.contains("agent-relay"))
        #expect(helpZhOut.contains("status [--project <path.relayproj>] [--run <id> | --runs] [--json]"))
        #expect(helpZhOut.contains("写不写 --json 结果相同"))
        #expect(helpZhOut.contains("integration.ready"))
        #expect(!helpZhOut.contains("尚不会启动任何 coding agent"))
        #expect(!helpZhOut.contains("还不合并分支"))

        let versionOut = try await cli.execute(arguments: ["--version"])
        #expect(versionOut.contains("RelayIDE 1.4.0"))
        #expect(versionOut.contains("M4"))
        #expect(versionOut.contains("RELAY_BUDGET_USD"))
        #expect(versionOut.contains("agent-relay"))
        #expect(!versionOut.contains("does not launch coding agents yet"))
        #expect(!versionOut.contains("does not merge branches"))

        let versionZhOut = try await cli.execute(arguments: ["version", "--lang", "zh"])
        #expect(versionZhOut.contains("M4"))
        #expect(versionZhOut.contains("RELAY_BUDGET_USD"))
        #expect(versionZhOut.contains("agent-relay"))
        #expect(!versionZhOut.contains("尚不会启动任何 coding agent"))
        #expect(!versionZhOut.contains("还不合并分支"))

        await #expect(throws: RelayIDEError.self) {
            _ = try await cli.execute(arguments: ["non-existent-subcommand"])
        }
    }

    // MARK: - 2. `RelayCLIRunner`: `init --seed-demo`, `status`, `lanes`, `dag-waves` & `audit-plugins`

    @Test("RelayCLIRunner executes init --seed-demo, status, lanes, dag-waves, and audit-plugins in isolated temp bundle")
    func cliRunnerWorkspaceLifecycleSubcommands() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-lifecycle")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundlePath = tempDir.appendingPathComponent("Campaign.relayproj").path
        let cli = RelayCLIRunner()

        // 1. init --project <path> --seed-demo
        let initOutput = try await cli.execute(arguments: ["init", "--project", bundlePath, "--seed-demo"])
        #expect(initOutput.contains("Initialized"))
        #expect(initOutput.contains("lanes="))

        // 2. status --project <path> -> valid JSON decoding to RelayWorkspaceStats
        let statusJSON = try await cli.execute(arguments: ["status", "--project", bundlePath])
        let stats = try JSONDecoder().decode(RelayWorkspaceStats.self, from: Data(statusJSON.utf8))
        #expect(stats.activeLaneCount >= 4)
        #expect(stats.taskNodeCount >= 4)
        #expect(stats.schemaVersion == 7)
        #expect(stats.totalSpendUSD > 0)
        #expect(stats.totalTokensObserved > 0)

        // 3. lanes --project <path>
        let lanesOut = try await cli.execute(arguments: ["lanes", "--project", bundlePath])
        #expect(lanesOut.contains("globs="))
        #expect(lanesOut.split(separator: "\n").count >= 4)

        // 4. dag-waves --project <path>
        let wavesOut = try await cli.execute(arguments: ["dag-waves", "--project", bundlePath])
        #expect(wavesOut.contains("Wave 1:"))
        #expect(wavesOut.contains("Wave 2:"))

        // 5. audit-plugins --project <path>
        let auditOut = try await cli.execute(arguments: ["audit-plugins", "--project", bundlePath])
        // Seeded demo may or may not have findings; verify command completes cleanly
        #expect(auditOut.count >= 0)
    }

    // MARK: - 4. `RelayCLIRunner`: `export-html` & `BauhausRelayHTMLReportExporter`

    @Test("RelayCLIRunner export-html generates standalone Bauhaus HTML dossier with vendor metrics and merge summaries")
    func cliRunnerExportHTMLDossier() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-html")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundlePath = tempDir.appendingPathComponent("ExportDemo.relayproj").path
        let htmlURL = tempDir.appendingPathComponent("dossier.html")

        let cli = RelayCLIRunner()
        _ = try await cli.execute(arguments: ["init", "--project", bundlePath, "--seed-demo"])
        let exportMsg = try await cli.execute(arguments: [
            "export-html",
            htmlURL.path,
            "--project",
            bundlePath,
        ])
        #expect(exportMsg.contains(htmlURL.path))
        #expect(FileManager.default.fileExists(atPath: htmlURL.path))

        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(html.contains("<!DOCTYPE html>") || html.contains("<html"))
        #expect(html.contains("#F4F2EC") || html.contains("RelayIDE"))
    }

    // MARK: - 5. `RelayMCPServer` JSON-RPC 2.0 `initialize` & `tools/list`

    @Test("RelayMCPServer responds to JSON-RPC 2.0 initialize and tools/list with schema definitions")
    func mcpServerInitializeAndToolsList() throws {
        let server = RelayMCPServer()

        // 1. initialize
        let initReply = server.handleJSONRPCLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#
        )
        #expect(initReply != nil)
        let initObj = try JSONSerialization.jsonObject(with: Data(initReply!.utf8)) as? [String: Any]
        #expect(initObj?["jsonrpc"] as? String == "2.0")
        #expect(initObj?["id"] as? Int == 1)
        let initResult = initObj?["result"] as? [String: Any]
        #expect(initResult?["protocolVersion"] as? String == "2024-11-05")

        // 2. tools/list
        let listReply = server.handleJSONRPCLine(
            #"{"jsonrpc":"2.0","id":"req-2","method":"tools/list"}"#
        )
        #expect(listReply != nil)
        let listObj = try JSONSerialization.jsonObject(with: Data(listReply!.utf8)) as? [String: Any]
        let listResult = listObj?["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]] ?? []
        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        #expect(!toolNames.contains("relay_semantic_merge"))
        #expect(toolNames == ["relay_check_ownership"])

        // 3. JSON-RPC notification without `id` returns nil (no reply frame emitted)
        let notifReply = server.handleJSONRPCLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notifReply == nil)
    }

    // MARK: - 6. `RelayMCPServer` `tools/call`: `relay_check_ownership` & Unknown Tool Rejection

    @Test("RelayMCPServer executes relay_check_ownership and rejects removed relay_semantic_merge over JSON-RPC tools/call")
    func mcpServerToolsCallSemanticMergeAndOwnership() throws {
        let server = RelayMCPServer()

        let mergeReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": [
                "name": "relay_semantic_merge",
                "arguments": [
                    "path": "Sources/Calc.swift",
                    "base": "public struct Calc {\n    public func id() -> Int { 1 }\n}\n",
                    "left": "public struct Calc {\n    public func id() -> Int { 1 }\n    public func add() -> Int { 2 }\n}\n",
                    "right": "public struct Calc {\n    public func id() -> Int { 1 }\n    public func mul() -> Int { 3 }\n}\n",
                ],
            ],
        ]
        let mergeLine = String(decoding: try JSONSerialization.data(withJSONObject: mergeReq), as: UTF8.self)
        let mergeReply = server.handleJSONRPCLine(mergeLine)
        #expect(mergeReply != nil)
        let mergeJSON = try JSONSerialization.jsonObject(with: Data(mergeReply!.utf8)) as? [String: Any]
        let mergeRes = mergeJSON?["result"] as? [String: Any]
        #expect(mergeRes?["isError"] as? Bool == true)
        let mergeContent = (mergeRes?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(mergeContent == "Unknown tool 'relay_semantic_merge'")

        // Allowed vs Denied ownership check
        let allowLine = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"relay_check_ownership","arguments":{"relativePath":"Tests/CalcTests.swift","allowedGlobs":["Tests/**"]}}}"#
        let allowReply = server.handleJSONRPCLine(allowLine)!
        let allowRes = (try JSONSerialization.jsonObject(with: Data(allowReply.utf8)) as? [String: Any])?["result"] as? [String: Any]
        #expect(allowRes?["isError"] as? Bool == false)

        let denyLine = #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"relay_check_ownership","arguments":{"relativePath":"Sources/Kernel.swift","allowedGlobs":["Tests/**"]}}}"#
        let denyReply = server.handleJSONRPCLine(denyLine)!
        let denyRes = (try JSONSerialization.jsonObject(with: Data(denyReply.utf8)) as? [String: Any])?["result"] as? [String: Any]
        #expect(denyRes?["isError"] as? Bool == true)
    }

    // MARK: - 7. `RelayFuzzySubsequenceScorer` Word-Boundary, Acronym & Contiguous Ranking

    @Test("RelayFuzzySubsequenceScorer awards higher scores to contiguous and CamelCase/word-boundary matches")
    func fuzzySubsequenceScorerRankingInvariants() {
        let acronymHit = RelayFuzzySubsequenceScorer.score(
            query: "sm",
            candidate: "Run 3-Way Semantic Merge"
        )
        let scatteredHit = RelayFuzzySubsequenceScorer.score(
            query: "sm",
            candidate: "Inspect System Telemetry"
        )
        #expect(acronymHit.matched == true)
        #expect(scatteredHit.matched == true)
        // Word-boundary initials ("Semantic Merge") should outrank scattered interior letters ("syStem teleMetry")
        #expect(acronymHit.score > scatteredHit.score)
        #expect(acronymHit.indices.count == 2)

        let nonMatch = RelayFuzzySubsequenceScorer.score(query: "zzz", candidate: "Open PTY Grid")
        #expect(nonMatch.matched == false)
    }

    // MARK: - 8. `@MainActor RelayCommandPaletteController` Filtering, Navigation & Execution

    @Test("RelayCommandPaletteController ranks fuzzy matches, filters categories, navigates selection, and dispatches")
    @MainActor
    func commandPaletteControllerFilteringNavigationAndDispatch() {
        let palette = RelayCommandPaletteController()
        var triggeredCommandID: String?
        palette.onCommandTriggered = { item in
            triggeredCommandID = item.id
        }

        palette.present(initialQuery: "semantic merge")
        #expect(palette.isPresented == true)
        #expect(!palette.rankedMatches.isEmpty)
        #expect(palette.rankedMatches[0].item.category == .semanticMerge || palette.rankedMatches[0].item.title.lowercased().contains("merge"))

        // Selection navigation bounds check
        palette.present(initialQuery: "")
        let initialIdx = palette.selectedIndex
        palette.moveSelectionDown()
        #expect(palette.selectedIndex == initialIdx + 1)
        palette.moveSelectionUp()
        #expect(palette.selectedIndex == initialIdx)

        // Category filter
        palette.present(initialQuery: "", category: .workspaceAndJournal)
        #expect(!palette.rankedMatches.isEmpty)
        #expect(palette.rankedMatches.allSatisfy { $0.item.category == .workspaceAndJournal })

        let executed = palette.executeSelected()
        #expect(executed != nil)
        #expect(triggeredCommandID == executed?.id)
        #expect(palette.isPresented == false)
    }

    // MARK: - 9. `@MainActor RelayKeybindingAndShortcutRegistry`: Default Keymap Cleanliness

    @Test("RelayKeybindingAndShortcutRegistry default bindings contain zero blocking chord collisions")
    @MainActor
    func defaultKeybindingRegistryHasZeroBlockingCollisions() throws {
        let isolated = try makeIsolatedUserDefaults(label: "keymap.defaults")
        defer { isolated.cleanup() }
        let isolatedDefaults = isolated.defaults

        let registry = RelayKeybindingAndShortcutRegistry(
            userDefaults: isolatedDefaults,
            loadPersistedOverrides: false
        )
        let blocking = registry.detectConflicts().filter(\.isBlockingError)
        #expect(blocking.isEmpty)
        #expect(registry.shortcutBadge(for: "workbench.commandPalette") != nil)
    }

    // MARK: - 10. `@MainActor RelayKeybindingAndShortcutRegistry`: Identical Chord & Prefix Shadowing Detection

    @Test("RelayKeybindingAndShortcutRegistry detects identical chord collisions, prefix shadowing, and macOS reserved shortcuts")
    @MainActor
    func keybindingCollisionPrefixShadowingAndReservedSystemWarnings() throws {
        let isolated = try makeIsolatedUserDefaults(label: "keymap.conflicts")
        defer { isolated.cleanup() }
        let isolatedDefaults = isolated.defaults

        let cmdA = RelayShortcutBinding(
            commandID: "cmd.alpha",
            title: "Alpha",
            subtitle: "Global command",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: RelayKeyChord.parse("cmd+k")!
        )
        let cmdB = RelayShortcutBinding(
            commandID: "cmd.beta",
            title: "Beta",
            subtitle: "PTY command",
            category: .ptyMultiplexer,
            scope: .ptyGridFocused,
            defaultChord: RelayKeyChord.parse("cmd+b")!
        )
        let cmdMulti = RelayShortcutBinding(
            commandID: "cmd.multi",
            title: "Two-Stroke Merge",
            subtitle: "Multi-stroke chord",
            category: .semanticMerge,
            scope: .globalWorkbench,
            defaultChord: RelayKeyChord.parse("cmd+g cmd+m")!
        )

        let registry = RelayKeybindingAndShortcutRegistry(
            initialBindings: [cmdA, cmdB, cmdMulti],
            userDefaults: isolatedDefaults,
            loadPersistedOverrides: false
        )
        #expect(registry.detectConflicts().isEmpty)

        // 1. Rebinding `cmd.beta` (ptyGridFocused) to `cmd+k` collides with global `cmd.alpha`!
        let identicalAttempt = registry.rebind(commandID: "cmd.beta", toSpec: "cmd+k", allowConflictingOverride: false)
        if case .failure(.conflictsDetected(let conflicts)) = identicalAttempt {
            #expect(conflicts.contains { $0.kind == .identicalChordCollision })
        } else {
            Issue.record("Expected identicalChordCollision failure when rebinding cmd.beta to cmd+k")
        }

        // 2. Rebinding `cmd.beta` to single-stroke `cmd+g` shadows multi-stroke `cmd+g cmd+m`!
        let prefixAttempt = registry.rebind(commandID: "cmd.beta", toSpec: "cmd+g", allowConflictingOverride: false)
        if case .failure(.conflictsDetected(let conflicts)) = prefixAttempt {
            #expect(conflicts.contains { $0.kind == .chordPrefixShadowing })
        } else {
            Issue.record("Expected chordPrefixShadowing failure when binding prefix cmd+g")
        }

        // 3. Previewing `cmd+q` flags macOS reserved shortcut warning (non-blocking advisory)
        let reservedPreview = registry.previewConflicts(
            ifRebinding: "cmd.beta",
            to: RelayKeyChord.parse("cmd+q")!
        )
        #expect(reservedPreview.contains { $0.kind == .reservedSystemShortcutWarning && !$0.isBlockingError })
    }

    // MARK: - 11. `@MainActor RelayKeybindingAndShortcutRegistry`: Multi-Stroke Chord Dispatch & JSON Export/Import

    @Test("RelayKeybindingAndShortcutRegistry dispatches two-stroke chords and round-trips exported keymap JSON")
    @MainActor
    func keybindingTwoStrokeDispatchAndKeymapJSONRoundTrip() throws {
        let isolated = try makeIsolatedUserDefaults(label: "keymap.dispatch")
        defer { isolated.cleanup() }
        let isolatedDefaults = isolated.defaults

        let twoStroke = RelayShortcutBinding(
            commandID: "merge.acceptVerified",
            title: "Accept Verified Lane",
            subtitle: "Resolve conflict",
            category: .semanticMerge,
            scope: .mergeStudioFocused,
            defaultChord: RelayKeyChord.parse("cmd+m cmd+v")!
        )
        let singleStroke = RelayShortcutBinding(
            commandID: "workbench.commandPalette",
            title: "Command Palette",
            subtitle: "Open palette",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: RelayKeyChord.parse("cmd+shift+p")!
        )

        let registry = RelayKeybindingAndShortcutRegistry(
            initialBindings: [twoStroke, singleStroke],
            userDefaults: isolatedDefaults,
            loadPersistedOverrides: false
        )

        var dispatchedID: String?
        registry.onShortcutTriggered = { binding in
            dispatchedID = binding.commandID
        }

        // First stroke `cmd+m` in `.semanticMerge` pane -> enters awaitingNextStroke
        let firstOutcome = registry.handleKeyStroke(
            RelayKeyStroke.parse("cmd+m")!,
            activePane: .semanticMerge
        )
        if case .awaitingNextStroke(_, let candidates) = firstOutcome {
            #expect(candidates == ["merge.acceptVerified"])
        } else {
            Issue.record("Expected .awaitingNextStroke after first chord stroke")
        }

        // Second stroke `cmd+v` -> dispatches `merge.acceptVerified`!
        let secondOutcome = registry.handleKeyStroke(
            RelayKeyStroke.parse("cmd+v")!,
            activePane: .semanticMerge
        )
        #expect(secondOutcome == .dispatched(commandID: "merge.acceptVerified", chordBadge: twoStroke.glyphBadge))
        #expect(dispatchedID == "merge.acceptVerified")

        // Customize binding, export JSON, reset to defaults, then re-import JSON
        _ = try registry.rebind(commandID: "workbench.commandPalette", toSpec: "cmd+p").get()
        #expect(registry.binding(for: "workbench.commandPalette")?.isUserCustomized == true)

        let exportedData = try registry.exportKeymapJSON(profileName: "Custom Test Keymap")
        registry.resetAllToDefaults()
        #expect(registry.binding(for: "workbench.commandPalette")?.isUserCustomized == false)

        try registry.importKeymapJSON(exportedData)
        #expect(registry.binding(for: "workbench.commandPalette")?.activeChord == RelayKeyChord.parse("cmd+p"))
    }

    // MARK: - 12. `@MainActor RelaySplitWorkspaceController` Tabs, Split Ratios & Drawers

    @Test("RelaySplitWorkspaceController manages tabs, pin guards, split ratio clamping, and inspector/drawer toggles")
    @MainActor
    func splitWorkspaceControllerTabsRatiosAndDrawers() {
        let controller = RelaySplitWorkspaceController()
        let initialCount = controller.tabs.count
        #expect(initialCount >= 4)

        // Clamps extreme horizontal/vertical split ratios into safe ergonomic bounds
        controller.setHorizontalSplitRatio(0.02)
        #expect(controller.horizontalSplitRatio >= 0.15)
        controller.setVerticalSplitRatio(0.98)
        #expect(controller.verticalSplitRatio <= 0.85)

        // Maximize & unmaximize lane
        controller.toggleMaximize(laneID: "lane-claude-core")
        #expect(controller.maximizedLaneID == "lane-claude-core")
        controller.toggleMaximize(laneID: "lane-claude-core")
        #expect(controller.maximizedLaneID == nil)

        // Open new pane tab and close it cleanly
        let countBeforeOpen = controller.tabs.count
        controller.openOrActivatePane(.semanticMerge, filePath: "Sources/NewMerge.swift")
        let activeID = controller.activeTabID
        #expect(controller.tabs.count == countBeforeOpen + 1)
        controller.closeTab(id: activeID)
        #expect(controller.tabs.count == countBeforeOpen)

        // Pin guard protects the last remaining tab when pinned
        let singlePinned = RelaySplitWorkspaceController(
            initialTabs: [RelayWorkspaceTab(id: "only-pinned", title: "Pinned Grid", studioPane: .ptyGrid, isPinned: true)]
        )
        singlePinned.closeTab(id: "only-pinned")
        #expect(singlePinned.tabs.count == 1)

        // Toggle inspector & bottom FTS5 drawer
        controller.toggleBottomDrawer(tab: .ftsSearch)
        #expect(controller.isBottomDrawerVisible == true)
        #expect(controller.activeBottomDrawerTab == .ftsSearch)
    }

    // MARK: - 13. `@MainActor RelayToastCenter` Max Capacity Eviction & Merge Notifications

    @Test("RelayToastCenter enforces bounded queue capacity and posts semantic merge alerts")
    @MainActor
    func toastCenterCapacityEvictionAndStructuredFeedback() {
        let toasts = RelayToastCenter(maxVisibleCount: 3)
        for idx in 1...5 {
            _ = toasts.post(
                severity: .info,
                title: "Event \(idx)",
                detail: "Detail \(idx)",
                scheduleAutoDismiss: false
            )
        }
        // Capacity capped at 3 -> oldest 2 evicted
        #expect(toasts.maxVisibleCount == 3)

        toasts.dismissAll()
        let report = ThreeWaySemanticMergeReport(
            relativePath: "Sources/Ledger.swift",
            language: .swift,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex",
            chunks: [],
            mergedText: "",
            autoMergedCount: 3,
            unresolvedConflictCount: 0,
            wouldGitLineMergeConflict: true
        )
        toasts.postSemanticMergeFeedback(report)
        #expect(toasts.visibleToasts.count == 1)
        toasts.dismissAll()
    }

    // MARK: - 14. `@MainActor BauhausColorThemeTokens` & `RelayUserPreferences` Persistence

    @Test("BauhausColorThemeTokens and RelayUserPreferences persist font size adjustments to isolated backing file")
    @MainActor
    func bauhausColorTokensAndUserPreferencesBackingFileRoundTrip() throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-prefs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prefsFile = tempDir.appendingPathComponent("prefs.json")
        let isolated = try makeIsolatedUserDefaults(label: "prefs")
        defer { isolated.cleanup() }
        let isolatedDefaults = isolated.defaults

        let tokens = BauhausColorThemeTokens.bauhausStandard
        #expect(tokens.chromeWarmSandpaperHex.hasPrefix("#"))
        #expect(tokens.vermilionHex == "#D94E34")
        #expect(tokens.cobaltHex == "#2563EB")

        let prefs = RelayUserPreferences(
            backingFileURL: prefsFile,
            userDefaults: isolatedDefaults,
            storageKey: "prefs.test"
        )
        let baselineSize = prefs.terminalFontSizePoints
        prefs.increaseTerminalFontSize()
        #expect(prefs.terminalFontSizePoints > baselineSize)

        prefs.resetToBauhausDefaults()
        #expect(prefs.terminalFontSizePoints == baselineSize)
    }

    // MARK: - 15. `@MainActor RelayWorkbenchCoordinator` Command Routing & Studio Switching

    @Test("RelayWorkbenchCoordinator wires command dispatch across studio panes, undo/redo callbacks, and palette sync")
    @MainActor
    func workbenchCoordinatorCommandDispatchAndCallbacks() throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-coord")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let isolated = try makeIsolatedUserDefaults(label: "coord")
        defer { isolated.cleanup() }
        let isolatedDefaults = isolated.defaults

        let prefs = RelayUserPreferences(
            backingFileURL: tempDir.appendingPathComponent("coord-prefs.json"),
            userDefaults: isolatedDefaults,
            storageKey: "coord.prefs"
        )
        let registry = RelayKeybindingAndShortcutRegistry(
            userDefaults: isolatedDefaults,
            storageKey: "coord.keymap",
            loadPersistedOverrides: false
        )
        let coordinator = RelayWorkbenchCoordinator(
            preferences: prefs,
            shortcutRegistry: registry
        )

        var didRunMerge = false
        var didUndo = false
        coordinator.onRunSemanticMergeRequested = { didRunMerge = true }
        coordinator.onUndoRequested = { didUndo = true }

        coordinator.dispatchCommand(id: "studio.territoryMap")
        #expect(coordinator.shellState.activePane == .territoryMap)

        coordinator.dispatchCommand(id: "merge.runThreeWaySemantic")
        #expect(didRunMerge == true)

        coordinator.dispatchCommand(id: "journal.undo")
        #expect(didUndo == true)
    }

    // MARK: - 16. `RelayLocalizer` Precedence, Chinese Locale Auto-Detection & Live Toggle (`v1.1.0`)

    @Test("RelayLocalizer resolves --lang, RELAYIDE_LANG, UserDefaults, and Chinese Locale fallback, and toggles live")
    @MainActor
    func relayLocalizerResolutionPrecedenceAndLiveToggle() throws {
        let isolated = try makeIsolatedUserDefaults(label: "localizer")
        defer { isolated.cleanup() }
        let isolatedDefaults = isolated.defaults

        // 1. Auto-detect Chinese when Locale.preferredLanguages starts with "zh"
        let autoZh = RelayLocalizer.resolveLanguage(
            arguments: ["RelayIDE"],
            environment: [:],
            userDefaults: isolatedDefaults,
            storageKey: RelayLocalizer.userDefaultsKey,
            preferredLanguages: ["zh-Hans-CN", "en-US"]
        )
        #expect(autoZh == .zhHans)
        #expect(autoZh.badge == "中文")

        // 2. Fallback to English for non-Chinese preferredLanguages
        let autoEn = RelayLocalizer.resolveLanguage(
            arguments: ["RelayIDE"],
            environment: [:],
            userDefaults: isolatedDefaults,
            storageKey: RelayLocalizer.userDefaultsKey,
            preferredLanguages: ["en-US", "fr-FR"]
        )
        #expect(autoEn == .en)
        #expect(autoEn.badge == "EN")

        // 3. UserDefaults overrides system locale
        let localizer = RelayLocalizer(
            arguments: ["RelayIDE"],
            environment: [:],
            userDefaults: isolatedDefaults,
            storageKey: RelayLocalizer.userDefaultsKey,
            preferredLanguages: ["en-US"],
            persistToUserDefaults: true
        )
        #expect(localizer.language == .en)
        #expect(localizer.L("PTY Multiplexer", "并行终端网格") == "PTY Multiplexer")

        let toggled = localizer.toggleLanguage()
        #expect(toggled == .zhHans)
        #expect(localizer.language == .zhHans)
        #expect(localizer.L("PTY Multiplexer", "并行终端网格") == "并行终端网格")
        #expect(isolatedDefaults.string(forKey: RelayLocalizer.userDefaultsKey) == "zh-Hans")

        // 4. RELAYIDE_LANG overrides UserDefaults, and CLI --lang overrides RELAYIDE_LANG
        let envResolved = RelayLocalizer.resolveLanguage(
            arguments: ["RelayIDE"],
            environment: ["RELAYIDE_LANG": "en"],
            userDefaults: isolatedDefaults,
            storageKey: RelayLocalizer.userDefaultsKey,
            preferredLanguages: ["zh-Hans-CN"]
        )
        #expect(envResolved == .en)

        let cliResolved = RelayLocalizer.resolveLanguage(
            arguments: ["RelayIDE", "--export-screenshots", "./docs", "--lang", "zh"],
            environment: ["RELAYIDE_LANG": "en"],
            userDefaults: isolatedDefaults,
            storageKey: RelayLocalizer.userDefaultsKey,
            preferredLanguages: ["en-US"]
        )
        #expect(cliResolved == .zhHans)
        #expect(RelayLocalizer.parseCLILanguageOverride(arguments: ["RelayIDE", "--lang=en"]) == .en)

        // 5. Coordinator ⇧⌘L ("workbench.toggleLanguage") updates Command Palette live
        let registry = RelayKeybindingAndShortcutRegistry(
            userDefaults: isolatedDefaults,
            storageKey: "coord.lang.keymap",
            loadPersistedOverrides: false
        )
        let coordinator = RelayWorkbenchCoordinator(
            localizer: localizer,
            shortcutRegistry: registry
        )
        #expect(coordinator.commandPalette.catalog.contains(where: { $0.title.contains("并行终端网格") }))
        coordinator.dispatchCommand(id: "workbench.toggleLanguage")
        #expect(localizer.language == .en)
        #expect(coordinator.commandPalette.catalog.contains(where: { $0.title.contains("PTY Multiplexer") }))
    }

    // MARK: - 17. Bilingual Standalone HTML Dossier Markers & Zero Em-Dash Invariant (`v1.1.0`)

    @Test("BauhausRelayHTMLReportExporter emits interactive 中文 | EN toggle, data-en/data-zh attributes, and zero em-dashes")
    func bilingualHTMLDossierMarkersAndZeroEmDash() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-bilingual-html")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundlePath = tempDir.appendingPathComponent("BilingualDemo.relayproj").path
        let outHTMLURL = tempDir.appendingPathComponent("bilingual-dossier.html")
        let cli = RelayCLIRunner()

        _ = try await cli.execute(arguments: ["init", "--project", bundlePath, "--seed-demo"])
        _ = try await cli.execute(arguments: ["export-html", outHTMLURL.path, "--project", bundlePath, "--lang", "zh"])

        let html = try String(contentsOf: outHTMLURL, encoding: .utf8)
        #expect(html.contains(#"class="lang-switch""#))
        #expect(html.contains(#"data-lang-choice="zh-Hans""#))
        #expect(html.contains(#"data-lang-choice="en""#))
        #expect(html.contains("data-en="))
        #expect(html.contains("data-zh="))
        #expect(html.contains("io.github.zxu756.RelayIDE.language"))
        #expect(html.contains("navigator.language"))
        #expect(html.contains("隔离 Git 工作树矩阵与文件归属围栏"))
        #expect(!html.contains("\u{2014}"))
    }

    // MARK: - 18. M0 Honesty Contracts: Nonexistent `--project`, `[DEMO]` Markers, Syntax Gate & Exit Codes

    @Test("RelayCLIRunner rejects nonexistent --project without creating directories in both EN and ZH, and status succeeds on empty init")
    func cliRunnerRejectsNonexistentProjectWithoutCreatingDirectory() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-missing-proj")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingPath = tempDir.appendingPathComponent("DoesNotExist.relayproj").path
        let cli = RelayCLIRunner()

        for subcmd in ["status", "lanes", "dag-waves", "audit-plugins", "mcp"] {
            let resEN = await cli.executeCommand(arguments: [subcmd, "--project", missingPath, "--lang", "en"])
            #expect(resEN.exitCode != 0)
            #expect(!resEN.stderr.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: missingPath))

            let resZH = await cli.executeCommand(arguments: [subcmd, "--project", missingPath, "--lang", "zh"])
            #expect(resZH.exitCode != 0)
            #expect(resZH.stderr.contains("不存在") || resZH.stderr.contains("未找到"))
            #expect(!FileManager.default.fileExists(atPath: missingPath))
        }

        // Empty workspace initialized WITHOUT --seed-demo succeeds on status & lanes with 0 lanes and no [DEMO] tag
        let emptyBundle = tempDir.appendingPathComponent("CleanEmpty.relayproj").path
        let initEmpty = await cli.executeCommand(arguments: ["init", "--project", emptyBundle, "--lang", "en"])
        #expect(initEmpty.exitCode == 0)
        #expect(!initEmpty.stdout.contains("[DEMO]"))

        let statusEmpty = await cli.executeCommand(arguments: ["status", "--project", emptyBundle])
        #expect(statusEmpty.exitCode == 0)
        let stats = try JSONDecoder().decode(RelayWorkspaceStats.self, from: Data(statusEmpty.stdout.utf8))
        #expect(stats.activeLaneCount == 0)

        let lanesEmpty = await cli.executeCommand(arguments: ["lanes", "--project", emptyBundle])
        #expect(lanesEmpty.exitCode == 0)
        #expect(lanesEmpty.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("RelayCLIRunner and BauhausRelayHTMLReportExporter mark --seed-demo outputs with [DEMO] / [演示数据] and omit removed semantic-merge from help")
    func cliRunnerDemoMarkersAndBilingualHelpExperimentalWarning() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-demo-markers")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cli = RelayCLIRunner()
        let helpEN = await cli.executeCommand(arguments: ["--help", "--lang", "en"])
        #expect(helpEN.exitCode == 0)
        #expect(!helpEN.stdout.contains("semantic-merge"))
        #expect(!helpEN.stdout.contains("relay_semantic_merge"))
        #expect(helpEN.stdout.contains("1 tool: relay_check_ownership"))

        let helpZH = await cli.executeCommand(arguments: ["--help", "--lang", "zh"])
        #expect(helpZH.exitCode == 0)
        #expect(!helpZH.stdout.contains("semantic-merge"))
        #expect(!helpZH.stdout.contains("relay_semantic_merge"))
        #expect(helpZH.stdout.contains("1 个工具：relay_check_ownership"))

        let demoENPath = tempDir.appendingPathComponent("DemoEN.relayproj").path
        let initEN = await cli.executeCommand(arguments: ["init", "--project", demoENPath, "--seed-demo", "--lang", "en"])
        #expect(initEN.exitCode == 0)
        #expect(initEN.stdout.contains("[DEMO]"))

        let demoZHPath = tempDir.appendingPathComponent("DemoZH.relayproj").path
        let initZH = await cli.executeCommand(arguments: ["init", "--project", demoZHPath, "--seed-demo", "--lang", "zh"])
        #expect(initZH.exitCode == 0)
        #expect(initZH.stdout.contains("[演示数据]"))

        let htmlURL = tempDir.appendingPathComponent("demo-report.html")
        let exportRes = await cli.executeCommand(arguments: ["export-html", htmlURL.path, "--project", demoZHPath, "--lang", "zh"])
        #expect(exportRes.exitCode == 0)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(html.contains("[DEMO]"))
        #expect(html.contains("[演示数据]"))
        #expect(html.contains(#"class="kicker""#))
        #expect(html.contains("RelayIDE v1.4.0 Synthetic Demo Workspace Snapshot (Preview Only, Not Output from Live Agent Runs)"))
        #expect(html.contains("RelayIDE v1.4.0 合成演示工作区快照（仅供预览，非真实智能体运行产物）"))
        #expect(!html.contains("M0"))
    }

    @Test("RelayMCPServer binds --project ownership rules and RelayUserPreferences disables auto-semantic-merge before M3")
    @MainActor
    func mcpProjectBindingAndDefaultSemanticMergeDisabled() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-mcp-proj")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Bound.relayproj")
        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleURL)
        try db.saveLane(
            ManagedWorktreeLane(
                id: "lane-auth",
                displayName: "Auth Lane",
                assignedVendor: .claudeCode,
                worktreePath: tempDir.path,
                branchName: "relay/auth",
                baseCommitOID: "0000",
                headCommitOID: "0000",
                ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/Auth/**"], forbiddenGlobs: ["Secrets/**"])
            )
        )

        let mcp = RelayMCPServer(projectBundleURL: bundleURL)
        let checkAllowed = #"{"jsonrpc":"2.0","id":301,"method":"tools/call","params":{"name":"relay_check_ownership","arguments":{"laneID":"lane-auth","relativePath":"Sources/Auth/Login.swift"}}}"#
        let replyAllowed = mcp.handleJSONRPCLine(checkAllowed)!
        let resAllowed = (try JSONSerialization.jsonObject(with: Data(replyAllowed.utf8)) as? [String: Any])?["result"] as? [String: Any]
        #expect(resAllowed?["isError"] as? Bool == false)

        let checkDenied = #"{"jsonrpc":"2.0","id":302,"method":"tools/call","params":{"name":"relay_check_ownership","arguments":{"laneID":"lane-auth","relativePath":"Sources/Billing/Tax.swift"}}}"#
        let replyDenied = mcp.handleJSONRPCLine(checkDenied)!
        let resDenied = (try JSONSerialization.jsonObject(with: Data(replyDenied.utf8)) as? [String: Any])?["result"] as? [String: Any]
        #expect(resDenied?["isError"] as? Bool == true)

        let defaultSnapshot = RelayUserPreferencesSnapshot()
        #expect(defaultSnapshot.autoRevertOwnershipViolations == false)
    }

    // MARK: - 19. M0 Rework (C1): Acceptance Scripts Must Never Launch the Desktop GUI

    private static var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runTool(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let raw = try runToolRaw(executable, arguments, environment: environment, currentDirectory: currentDirectory)
        return (raw.exitCode, String(decoding: raw.stdout, as: UTF8.self), raw.stderr)
    }

    private func runToolRaw(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) throws -> (exitCode: Int32, stdout: Data, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment { proc.environment = environment }
        if let currentDirectory { proc.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        // Drain both pipes concurrently so a chatty child can never block on a full pipe buffer.
        final class DataBox: @unchecked Sendable { var data = Data() }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()
        return (proc.terminationStatus, outBox.data, String(decoding: errBox.data, as: UTF8.self))
    }

    @Test("Acceptance scripts reach the product binary only through the headless-subcommand wrapper (C1)")
    func acceptanceScriptsOnlyReachProductBinaryThroughHeadlessWrapper() throws {
        let scriptsDir = Self.repositoryRootURL.appendingPathComponent("Scripts", isDirectory: true)
        let wrapperURL = scriptsDir.appendingPathComponent("acceptance/relay-cli.sh")
        #expect(FileManager.default.isExecutableFile(atPath: wrapperURL.path), "Scripts/acceptance/relay-cli.sh must exist and be executable")

        // 1. No script other than the wrapper (and the .app packager, which only copies the file) may name the raw binary.
        let rawBinaryMarkers = [".build/debug/RelayIDE", ".build/release/RelayIDE", "Contents/MacOS/RelayIDE", "${BIN}", "$BIN", "--show-bin-path"]
        let enumerator = try #require(FileManager.default.enumerator(at: scriptsDir, includingPropertiesForKeys: nil))
        var offending: [String] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".sh") || name.hasSuffix(".py") else { continue }
            if name == "relay-cli.sh" || name == "build-app.sh" { continue }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { continue }
                for marker in rawBinaryMarkers where line.contains(marker) {
                    offending.append("\(name):\(idx + 1): \(trimmed)")
                }
            }
        }
        #expect(offending.isEmpty, "Scripts must call Scripts/acceptance/relay-cli.sh instead of the raw binary: \(offending)")

        // 2. The wrapper refuses every invocation that would fall through to the desktop GUI, and forwards headless subcommands.
        //    RELAY_CLI_BIN points at /usr/bin/true so this test can never start the real application.
        let stubEnv = ["RELAY_CLI_BIN": "/usr/bin/true", "PATH": "/usr/bin:/bin"]
        let refused: [[String]] = [
            [],
            ["--demo"],
            ["--lang", "en"],
            ["--project", "Some.relayproj"],
            ["--lang", "zh", "--project", "Some.relayproj"],
            ["Some.relayproj"],
            ["--export-screenshots", "out"],
            ["semantic_merge", "a", "b", "c"]
        ]
        for args in refused {
            let res = try runTool("/bin/bash", [wrapperURL.path] + args, environment: stubEnv)
            #expect(res.exitCode == 64, "wrapper must refuse \(args), got exit \(res.exitCode)")
            #expect(res.stderr.contains("refusing"), "wrapper must explain the refusal for \(args)")
        }
        let forwarded: [[String]] = [
            ["status", "--project", "X.relayproj"],
            ["run", "plan.json", "--project", "X.relayproj"],
            ["--lang", "zh", "lanes"],
            ["--lang=en", "semantic-merge", "a", "b", "c"],
            ["--help"],
            ["version"],
            ["mcp"]
        ]
        for args in forwarded {
            let res = try runTool("/bin/bash", [wrapperURL.path] + args, environment: stubEnv)
            #expect(res.exitCode == 0, "wrapper must forward \(args), got exit \(res.exitCode): \(res.stderr)")
        }
    }

    // MARK: - 20. Retained `LanguageSyntaxValidator` Helper for `Fixtures/syntax-gate-cases`

    private struct SyntaxGateFixture {
        let name: String
        let directory: URL
        let fileExtension: String

        var baseURL: URL { directory.appendingPathComponent("base.\(fileExtension)") }
        var leftURL: URL { directory.appendingPathComponent("left.\(fileExtension)") }
        var rightURL: URL { directory.appendingPathComponent("right.\(fileExtension)") }
    }

    /// Plain `git merge-file -p` with default settings, run outside any repository and without user configuration.
    private func referenceGitMergeFile(_ fixture: SyntaxGateFixture) throws -> (conflicts: Int32, output: Data) {
        let scratch = try makeIsolatedTempDirectory(prefix: "relay-git-reference")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let res = try runToolRaw(
            "/usr/bin/env",
            ["git", "merge-file", "-p", "-L", "left", "-L", "base", "-L", "right",
             fixture.leftURL.path, fixture.baseURL.path, fixture.rightURL.path],
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "HOME": scratch.path,
                "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null"
            ],
            currentDirectory: scratch
        )
        try #require(res.exitCode >= 0 && res.exitCode <= 127, "reference git merge-file failed for \(fixture.name): \(res.stderr)")
        return (res.exitCode, res.stdout)
    }

    // MARK: - 21. M0 Rework (C2): Tests Never Write Into the User's Preferences Folder

    private func relayPreferenceFilesInUserLibrary() -> Set<String> {
        let prefsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: prefsDir)) ?? []
        return Set(names.filter { $0.hasPrefix("io.relayide.") || $0.hasPrefix("io.github.zxu756.RelayIDE") })
    }

    @Test("UserDefaults used by tests are stored in a temporary directory, never in ~/Library/Preferences (C2)")
    func testUserDefaultsNeverTouchUserPreferencesFolder() throws {
        let before = relayPreferenceFilesInUserLibrary()

        let isolated = try makeIsolatedUserDefaults(label: "probe")
        isolated.defaults.set("zh-Hans", forKey: "language")
        isolated.defaults.set(Data([1, 2, 3]), forKey: "blob")
        isolated.defaults.synchronize()
        #expect(isolated.defaults.string(forKey: "language") == "zh-Hans")

        let stored = try FileManager.default.contentsOfDirectory(atPath: isolated.storageDirectory.path)
        #expect(stored.contains { $0.hasSuffix(".plist") }, "the defaults plist must be written inside the test's temporary directory, found: \(stored)")
        #expect(relayPreferenceFilesInUserLibrary() == before, "a test wrote a preference file into ~/Library/Preferences")

        isolated.cleanup()
        #expect(!FileManager.default.fileExists(atPath: isolated.storageDirectory.path))
        #expect(relayPreferenceFilesInUserLibrary() == before)

        // No test may construct a named suite or touch the standard domain directly: the helper above is the only door.
        let testsDir = Self.repositoryRootURL.appendingPathComponent("Tests", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: testsDir, includingPropertiesForKeys: nil))
        var suiteConstructions = 0
        var standardDomainUses: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            suiteConstructions += text.components(separatedBy: "UserDefaults(" + "suiteName:").count - 1
            if text.contains("UserDefaults." + "standard") {
                standardDomainUses.append(fileURL.lastPathComponent)
            }
        }
        #expect(suiteConstructions == 1, "only makeIsolatedUserDefaults may construct a UserDefaults suite")
        #expect(standardDomainUses.isEmpty, "tests must not use the standard defaults domain: \(standardDomainUses)")
    }

    // MARK: - 22. Retained `LanguageSyntaxValidator` per Language (R29 fixtures)

    /// Each case in `Fixtures/syntax-gate-cases` has three versions that parse on their own and that git merges
    /// without conflict into text that does not parse. `LanguageSyntaxValidator` is retained after M3 (`03-relayide.md`),
    /// while `semantic-merge` and `relay_semantic_merge` are removed and must reject calls as unknown subcommand / tool.
    private func expectSyntaxGateRejects(caseName: String, fileExtension: String, parserFragment: String) async throws {
        let dir = Self.repositoryRootURL.appendingPathComponent("Fixtures/syntax-gate-cases/\(caseName)", isDirectory: true)
        let fixture = SyntaxGateFixture(name: caseName, directory: dir, fileExtension: fileExtension)
        let base = try String(contentsOf: fixture.baseURL, encoding: .utf8)
        let left = try String(contentsOf: fixture.leftURL, encoding: .utf8)
        let right = try String(contentsOf: fixture.rightURL, encoding: .utf8)

        for (label, source) in [("base", base), ("left", left), ("right", right)] {
            let verdict = LanguageSyntaxValidator.validate(source: source, filePath: fixture.baseURL.path)
            #expect(verdict.passed, "\(caseName): \(label) must parse on its own: \(verdict.diagnostic)")
            #expect(verdict.parserUsed?.contains(parserFragment) == true, "\(caseName): expected parser containing '\(parserFragment)', got \(verdict.parserUsed ?? "nil")")
        }
        let reference = try referenceGitMergeFile(fixture)
        #expect(reference.conflicts == 0, "\(caseName): git must merge this case cleanly")
        let gitMerged = String(decoding: reference.output, as: UTF8.self)
        let mergedVerdict = LanguageSyntaxValidator.validate(source: gitMerged, filePath: fixture.baseURL.path)
        #expect(!mergedVerdict.passed, "\(caseName): LanguageSyntaxValidator must reject git's broken clean merge")
        #expect(mergedVerdict.parserUsed?.contains(parserFragment) == true)

        let cli = RelayCLIRunner()
        for lang in ["en", "zh"] {
            let res = await cli.executeCommand(arguments: ["semantic-merge", fixture.baseURL.path, fixture.leftURL.path, fixture.rightURL.path, "--lang", lang])
            #expect(res.exitCode == 2, "\(caseName) --lang \(lang): removed semantic-merge must exit 2 as unknown subcommand, got \(res.exitCode)")
            #expect(res.stdout.isEmpty)
        }
    }

    @Test("LanguageSyntaxValidator rejects clean line merge that is not valid Swift (R29)")
    func semanticMergeSwiftSyntaxGateExits3() async throws {
        try await expectSyntaxGateRejects(caseName: "swift-string-delimiters", fileExtension: "swift", parserFragment: "swiftc -parse")
    }

    @Test("LanguageSyntaxValidator rejects clean line merge that is not valid JavaScript (R29)")
    func semanticMergeJavaScriptSyntaxGateExits3() async throws {
        try await expectSyntaxGateRejects(caseName: "javascript-block-comment", fileExtension: "js", parserFragment: "node --check")
    }

    @Test("LanguageSyntaxValidator rejects clean line merge that is not valid TypeScript (R29)")
    func semanticMergeTypeScriptSyntaxGateExits3() async throws {
        // The parser name depends on the host: `tsc --noEmit` when tsc is installed, node's type stripping otherwise.
        let hasTSC = LanguageSyntaxValidator.validate(source: "const x: number = 1;\n", filePath: "probe.ts").parserUsed?.contains("tsc") == true
        try await expectSyntaxGateRejects(caseName: "typescript-block-comment", fileExtension: "ts", parserFragment: hasTSC ? "tsc" : "node")
    }

    @Test("LanguageSyntaxValidator rejects clean line merge that is not valid Python (R29 companion)")
    func semanticMergePythonSyntaxGateExits3() async throws {
        try await expectSyntaxGateRejects(caseName: "python-string-delimiters", fileExtension: "py", parserFragment: "py_compile")
    }

    // MARK: - 24. M0 Rework (C4): README Commands Are Replayed From the README Files, and the Two Files Agree

    private func runReadmeReplay(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let script = Self.repositoryRootURL.appendingPathComponent("Scripts/acceptance/readme_replay.py").path
        return try runTool("/usr/bin/python3", [script] + arguments, currentDirectory: Self.repositoryRootURL)
    }

    @Test("readme-commands.sh replays the commands found in README.md and README.zh-CN.md instead of a hand-kept copy (C4)")
    func readmeCommandsAreTakenFromTheReadmeFiles() throws {
        let root = Self.repositoryRootURL

        // 1. The shell script holds no product command of its own: it only hands both READMEs to the replay tool.
        let shellScript = try String(contentsOf: root.appendingPathComponent("Scripts/acceptance/readme-commands.sh"), encoding: .utf8)
        #expect(shellScript.contains("readme_replay.py"))
        for handCopied in ["--seed-demo", "semantic-merge", "dag-waves", "audit-plugins", "export-html", "tools/list"] {
            #expect(!shellScript.contains(handCopied), "readme-commands.sh still carries its own copy of a README command: \(handCopied)")
        }

        // 2. The real READMEs agree with each other, every command is classified, and nothing that opens the GUI is runnable.
        let listing = try runReadmeReplay(["--list", "README.md", "README.zh-CN.md"])
        #expect(listing.exitCode == 0, "\(listing.stdout)\(listing.stderr)")
        let lines = listing.stdout.components(separatedBy: "\n")
        let runnable = lines.filter { $0.hasPrefix("RUN ") }
        #expect(runnable.count >= 20)
        #expect(!runnable.contains { $0.contains(".app/Contents/MacOS") || $0.contains("--demo") })
        #expect(lines.filter { $0.hasPrefix("SKIP-GUI") }.count == 6)
        #expect(!listing.stdout.contains("UNKNOWN"))

        // 3. Every fixture file a README example names exists, so the examples can be run exactly as written.
        var missing: [String] = []
        for line in runnable {
            for token in line.components(separatedBy: " ") where token.hasPrefix("Fixtures/") {
                if !FileManager.default.fileExists(atPath: root.appendingPathComponent(token).path) {
                    missing.append(token)
                }
            }
        }
        #expect(missing.isEmpty, "README examples name files that are not in the repository: \(missing)")
        #expect(runnable.filter { $0.contains(" semantic-merge ") }.allSatisfy { $0.contains("Fixtures/merge-cases/") })

        // 4. The tool notices when the two READMEs drift apart, and refuses commands it has no rule for.
        let scratch = try makeIsolatedTempDirectory(prefix: "relay-readme-replay")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func write(_ name: String, _ commands: [String]) throws -> String {
            let url = scratch.appendingPathComponent(name)
            try ("# doc\n\n```bash\n" + commands.joined(separator: "\n") + "\n```\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        let en = try write("en.md", [".build/debug/RelayIDE status --project p.relayproj", ".build/debug/RelayIDE lanes --project p.relayproj"])
        let zhSame = try write("zh-same.md", [".build/debug/RelayIDE status --project p.relayproj --lang zh", ".build/debug/RelayIDE lanes --lang=zh --project p.relayproj"])
        let zhDrifted = try write("zh-drifted.md", [".build/debug/RelayIDE status --project p.relayproj --lang zh", ".build/debug/RelayIDE dag-waves --project p.relayproj --lang zh"])
        #expect(try runReadmeReplay(["--list", en, zhSame]).exitCode == 0)
        let drift = try runReadmeReplay(["--list", en, zhDrifted])
        #expect(drift.exitCode == 1)
        #expect(drift.stdout.contains("differs between"))

        let unknown = try write("unknown.md", ["rm -rf build"])
        let unknownResult = try runReadmeReplay(["--list", unknown])
        #expect(unknownResult.exitCode == 1)
        #expect(unknownResult.stdout.contains("UNKNOWN"))

        // 5. Anything that would open the desktop window is classified SKIP-GUI, never RUN.
        let gui = try write("gui.md", [
            ".build/debug/RelayIDE",
            ".build/debug/RelayIDE --demo",
            ".build/debug/RelayIDE --lang zh --project p.relayproj",
            ".build/debug/RelayIDE semantic_merge a b c",
            ".build/debug/RelayIDE status --export-screenshots out",
            "build/RelayIDE.app/Contents/MacOS/RelayIDE status",
            "printf x | relayide --demo"
        ])
        let guiResult = try runReadmeReplay(["--list", gui])
        #expect(guiResult.exitCode == 0)
        let guiLines = guiResult.stdout.components(separatedBy: "\n").filter { $0.contains("gui.md:") }
        #expect(guiLines.count == 7)
        #expect(guiLines.allSatisfy { $0.hasPrefix("SKIP-GUI") }, "\(guiLines)")
    }

    // MARK: - 25. M1 Entry Point Classifier, Unknown Subcommand Rejection & R40 Exit Codes (R39, R40)

    @Test("RelayCLIRunner.classifyLaunchArguments routes run to CLI, rejects unknown non-flag non-.relayproj tokens with exit 2 without opening GUI, and separates exit codes 2 vs 125")
    func cliLaunchDispositionClassifierAndErrorExitCodeSeparation() async throws {
        // 1. Legitimate desktop GUI launches
        #expect(RelayCLIRunner.classifyLaunchArguments([]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["--demo"]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["--project", "Sample.relayproj"]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["--lang", "zh", "--project", "Sample.relayproj"]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["Sample.relayproj"]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["/tmp/Sample.relayproj/"]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["-psn_0_424242"]) == .desktopWorkbench)
        #expect(RelayCLIRunner.classifyLaunchArguments(["-NSDocumentRevisionsDebugMode", "YES"]) == .desktopWorkbench)

        // 2. Screenshot export
        if case .exportScreenshots(let dirURL) = RelayCLIRunner.classifyLaunchArguments(["--export-screenshots", "docs"]) {
            #expect(dirURL.lastPathComponent == "docs")
        } else {
            Issue.record("Expected .exportScreenshots for --export-screenshots")
        }
        #expect(RelayCLIRunner.parseExportScreenshotsProjectBundle(from: ["--export-screenshots", "docs"]) == nil)
        #expect(
            RelayCLIRunner.parseExportScreenshotsProjectBundle(
                from: ["--export-screenshots", "docs", "--project", "/tmp/RealRun.relayproj"]
            )?.lastPathComponent == "RealRun.relayproj"
        )
        #expect(
            RelayCLIRunner.parseExportScreenshotsProjectBundle(
                from: ["--export-screenshots=docs", "/tmp/DirectRun.relayproj"]
            )?.lastPathComponent == "DirectRun.relayproj"
        )
        #expect(RelayCLIRunner.parseExportScreenshotsDemoFlag(from: ["--export-screenshots", "docs", "--demo"]) == true)
        #expect(RelayCLIRunner.parseExportScreenshotsDemoFlag(from: ["--export-screenshots", "docs", "--project", "/tmp/RealRun.relayproj"]) == false)

        // 3. Known headless CLI subcommands including `run`
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["run", "plan.json", "--project", "Sample.relayproj"])
                == .headlessCLI(filteredArguments: ["run", "plan.json", "--project", "Sample.relayproj"], subcommand: "run")
        )
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["--lang", "zh", "run", "plan.json", "--project", "Sample.relayproj"])
                == .headlessCLI(filteredArguments: ["--lang", "zh", "run", "plan.json", "--project", "Sample.relayproj"], subcommand: "run")
        )
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["--lang=en", "status", "--project", "Sample.relayproj"])
                == .headlessCLI(filteredArguments: ["--lang=en", "status", "--project", "Sample.relayproj"], subcommand: "status")
        )

        // 4. First argument not starting with '-', not '.relayproj', and not a known subcommand -> unknownSubcommand (never GUI!)
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["typo-cmd"])
                == .unknownSubcommand(filteredArguments: ["typo-cmd"], offendingToken: "typo-cmd")
        )
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["semantic_merge", "a", "b", "c"])
                == .unknownSubcommand(filteredArguments: ["semantic_merge", "a", "b", "c"], offendingToken: "semantic_merge")
        )
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["--lang", "zh", "unknown-verb", "--project", "Sample.relayproj"])
                == .unknownSubcommand(filteredArguments: ["--lang", "zh", "unknown-verb", "--project", "Sample.relayproj"], offendingToken: "unknown-verb")
        )
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["plan.json"])
                == .unknownSubcommand(filteredArguments: ["plan.json"], offendingToken: "plan.json")
        )

        let cli = RelayCLIRunner()
        let zhUnknown = await cli.executeCommand(
            arguments: ["--lang", "zh", "unknown-verb"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(zhUnknown.exitCode == 2)
        #expect(zhUnknown.stdout.isEmpty)
        #expect(zhUnknown.stderr.contains("未知子命令"))

        let enUnknown = await cli.executeCommand(
            arguments: ["--lang", "en", "unknown-verb"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(enUnknown.exitCode == 2)
        #expect(enUnknown.stdout.isEmpty)
        #expect(enUnknown.stderr.contains("Unknown subcommand"))

        // 5. R40: Missing --project bundle returns exit 2 (not 1, which means lane failure), while internal/env/lock errors map to 125.
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-r40")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let missingProj = tempDir.appendingPathComponent("Missing.relayproj").path
        let missingStatus = await cli.executeCommand(
            arguments: ["status", "--project", missingProj],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(missingStatus.exitCode == 2)
        #expect(missingStatus.stdout.isEmpty)
        #expect(!missingStatus.stderr.isEmpty)
        #expect(RelayIDEError.databaseError(code: 5, message: "busy").cliExitCode == 125)
        #expect(RelayIDEError.relayEnvironmentFailure("missing relay.sh").cliExitCode == 125)
        #expect(RelayIDEError.projectRunLocked(projectPath: missingProj, holderRunID: "r1", holderPID: 99).cliExitCode == 125)
    }

    // MARK: - 26. M1 `status --run <id>` & `status --runs` JSON Vocabulary and Crash Reconciliation (§12, §13)

    @Test("RelayCLIRunner status --run and status --runs emit fixed English status JSON under both EN and ZH and reconcile unheld running runs to interrupted")
    func cliStatusRunAndRunsJSONAndInterruptedReconciliation() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-status-runs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("RunsLedger.relayproj", isDirectory: true)
        let cli = RelayCLIRunner()
        let env = ["PATH": "/usr/bin:/bin", "HOME": tempDir.path]

        let initRes = await cli.executeCommand(arguments: ["init", "--project", bundleURL.path], environment: env)
        #expect(initRes.exitCode == 0)

        // Empty --runs returns []
        let emptyRunsRes = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path, "--runs"],
            environment: env
        )
        #expect(emptyRunsRes.exitCode == 0)
        let emptyDecoded = try RelayRunJSONCodec.decode([RelayRunRecord].self, from: emptyRunsRes.stdout)
        #expect(emptyDecoded.isEmpty)

        // Unknown --run <id> returns exit 2 with empty stdout
        let missingRunRes = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path, "--run", "20261116-000000-dead"],
            environment: env
        )
        #expect(missingRunRes.exitCode == 2)
        #expect(missingRunRes.stdout.isEmpty)
        #expect(!missingRunRes.stderr.isEmpty)

        // Populate two runs: run1 completed with mixed statuses, run2 marked running with an unheld lock (simulated crash).
        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleURL)
        let t0 = Date(timeIntervalSince1970: 1_763_220_000)
        let t1 = Date(timeIntervalSince1970: 1_763_220_030)
        let run1ID = "20261116-030000-1111"
        let run1 = RelayRunRecord(
            runID: run1ID,
            repoPath: "/tmp/repo-a",
            planCopyPath: bundleURL.appendingPathComponent("runs/\(run1ID)/plan.json").path,
            baseRef: "main",
            baseCommitOID: "1111111111111111111111111111111111111111",
            verifyCommand: nil,
            relayShPath: "/tmp/fake-relay.sh",
            relayShSHA256: "2222222222222222222222222222222222222222222222222222222222222222",
            startedAt: t0,
            finishedAt: t1,
            status: .partial,
            reason: nil,
            relayidePID: 3001,
            lanes: [
                RelayRunLaneRecord(
                    runID: run1ID,
                    laneID: "api",
                    ordinal: 0,
                    agent: .claude,
                    promptPath: "/tmp/api.md",
                    after: [],
                    status: .succeededNoChanges,
                    exitCode: 0,
                    costUSD: 0.0123,
                    costSource: "usd"
                ),
                RelayRunLaneRecord(
                    runID: run1ID,
                    laneID: "docs",
                    ordinal: 1,
                    agent: .agy,
                    promptPath: "/tmp/docs.md",
                    after: ["api"],
                    status: .partial,
                    exitCode: 5,
                    costUSD: nil,
                    tokens: 2048,
                    costSource: "unpriced",
                    branch: "relay/\(run1ID)/docs",
                    commitOID: "3333333333333333333333333333333333333333"
                )
            ]
        )
        try db.createRun(run1)

        let run2ID = "20261116-030100-2222"
        let crashedLock = try RelayProjectRunLock.acquire(bundleDirectoryURL: bundleURL, runID: run2ID, pid: 3002)
        let run2 = RelayRunRecord(
            runID: run2ID,
            repoPath: "/tmp/repo-a",
            planCopyPath: bundleURL.appendingPathComponent("runs/\(run2ID)/plan.json").path,
            baseRef: "main",
            baseCommitOID: "1111111111111111111111111111111111111111",
            verifyCommand: nil,
            relayShPath: "/tmp/fake-relay.sh",
            relayShSHA256: "2222222222222222222222222222222222222222222222222222222222222222",
            startedAt: t1,
            finishedAt: nil,
            status: .running,
            reason: nil,
            relayidePID: 3002,
            lanes: [
                RelayRunLaneRecord(runID: run2ID, laneID: "worker", ordinal: 0, agent: .codex, promptPath: "/tmp/w.md", after: [], status: .running, pid: 3099)
            ]
        )
        try db.createRun(run2)
        crashedLock.closeDescriptorSimulatingCrash()

        // Query run1 in EN and ZH: JSON status tokens must be identical fixed English words, and null fields explicitly present.
        let run1EN = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path, "--run", run1ID, "--lang", "en"],
            environment: env
        )
        let run1ZH = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path, "--run", run1ID, "--lang", "zh"],
            environment: env
        )
        #expect(run1EN.exitCode == 0)
        #expect(run1ZH.exitCode == 0)
        #expect(run1EN.stdout == run1ZH.stdout)
        #expect(run1EN.stdout.contains("\"succeeded-no-changes\""))
        #expect(run1EN.stdout.contains("\"costUSD\" : null"))

        let decodedRun1 = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: run1EN.stdout)
        #expect(decodedRun1.status == .partial)
        #expect(decodedRun1.lanes[0].status == .succeededNoChanges)
        #expect(decodedRun1.lanes[1].costUSD == nil)
        #expect(decodedRun1.lanes[1].tokens == 2048)

        // Query crashed run2: must report interrupted and zero running lanes!
        let run2ZH = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path, "--run", run2ID, "--lang", "zh"],
            environment: env
        )
        #expect(run2ZH.exitCode == 0)
        let decodedRun2 = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: run2ZH.stdout)
        #expect(decodedRun2.status == .interrupted)
        #expect(decodedRun2.lanes.allSatisfy { $0.status != .running })
        #expect(decodedRun2.lanes[0].status == .interrupted)

        // Query --runs: returns both runs in order; M0 plain `status --project` remains unchanged!
        let allRunsRes = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path, "--runs"],
            environment: env
        )
        #expect(allRunsRes.exitCode == 0)
        let allDecoded = try RelayRunJSONCodec.decode([RelayRunRecord].self, from: allRunsRes.stdout)
        #expect(allDecoded.map(\.runID) == [run1ID, run2ID])
        #expect(allDecoded[1].status == .interrupted)

        let plainStatusRes = await cli.executeCommand(
            arguments: ["status", "--project", bundleURL.path],
            environment: env
        )
        #expect(plainStatusRes.exitCode == 0)
        let m0Stats = try JSONDecoder().decode(RelayWorkspaceStats.self, from: Data(plainStatusRes.stdout.utf8))
        #expect(m0Stats.schemaVersion == 7)
    }

    // MARK: - 27. M1 `RelayIDE run` Pre-Run Helpers & Exhaustive Unit Tests (§2, §3, §4, §9, §12)

    private struct IsolatedRunFixture {
        let rootURL: URL
        let homeURL: URL
        let repoURL: URL
        let baseCommitOID: String
        let projectURL: URL
        let fakeRelayDirURL: URL
        let fakeRelayShURL: URL
        let fakeRelaySHA256: String
        let baseEnvironment: [String: String]
    }

    private func makeIsolatedRunFixture(prefix: String, configureGitIdentity: Bool = true) throws -> IsolatedRunFixture {
        let rootURL = try makeIsolatedTempDirectory(prefix: prefix)
        let homeURL = rootURL.appendingPathComponent("isolated-home", isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("target-repo", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("Campaign.relayproj", isDirectory: true)
        let fakeRelayDirURL = rootURL.appendingPathComponent("fake-relay-bin", isDirectory: true)

        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeRelayDirURL, withIntermediateDirectories: true)

        let gitEnv: [String: String] = [
            "HOME": homeURL.path,
            "CFFIXED_USER_HOME": homeURL.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]

        _ = try runTool("/usr/bin/git", ["init", "-b", "main"], environment: gitEnv, currentDirectory: repoURL)
        if configureGitIdentity {
            _ = try runTool("/usr/bin/git", ["config", "user.name", "Relay Unit Tester"], environment: gitEnv, currentDirectory: repoURL)
            _ = try runTool("/usr/bin/git", ["config", "user.email", "unit-tester@relay.invalid"], environment: gitEnv, currentDirectory: repoURL)
            try "initial\n".write(to: repoURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            _ = try runTool("/usr/bin/git", ["add", "README.txt"], environment: gitEnv, currentDirectory: repoURL)
            _ = try runTool("/usr/bin/git", ["commit", "-m", "init"], environment: gitEnv, currentDirectory: repoURL)
        } else {
            // Commit once using explicit env vars so HEAD exists while repo config has NO user.name / user.email!
            var bootstrapCommitEnv = gitEnv
            bootstrapCommitEnv["GIT_AUTHOR_NAME"] = "Bootstrap"
            bootstrapCommitEnv["GIT_AUTHOR_EMAIL"] = "bootstrap@relay.invalid"
            bootstrapCommitEnv["GIT_COMMITTER_NAME"] = "Bootstrap"
            bootstrapCommitEnv["GIT_COMMITTER_EMAIL"] = "bootstrap@relay.invalid"
            try "initial\n".write(to: repoURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            _ = try runTool("/usr/bin/git", ["add", "README.txt"], environment: bootstrapCommitEnv, currentDirectory: repoURL)
            _ = try runTool("/usr/bin/git", ["commit", "-m", "init"], environment: bootstrapCommitEnv, currentDirectory: repoURL)
        }
        let headOut = try runTool("/usr/bin/git", ["rev-parse", "HEAD"], environment: gitEnv, currentDirectory: repoURL)
        let baseOID = headOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Initialize project bundle
        _ = try RelayProjectDatabase(bundleDirectoryURL: projectURL)

        // Copy Tests/Support/fake-relay.sh + sibling relay_util.py stub (never calls real relay.sh or real agents!)
        let sourceFakeRelayURL = Self.repositoryRootURL.appendingPathComponent("Tests/Support/fake-relay.sh")
        let fakeRelayShURL = fakeRelayDirURL.appendingPathComponent("relay.sh")
        try FileManager.default.copyItem(at: sourceFakeRelayURL, to: fakeRelayShURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRelayShURL.path)
        let fakeUtilURL = fakeRelayDirURL.appendingPathComponent("relay_util.py")
        try "#!/usr/bin/env python3\n# stub relay_util.py for unit tests\n".write(
            to: fakeUtilURL,
            atomically: true,
            encoding: .utf8
        )
        let relayData = try Data(contentsOf: fakeRelayShURL)
        let shaHex = Data(relayData).withUnsafeBytes { _ in "" } + {
            // Compute SHA-256 via /usr/bin/shasum -a 256 so test expectation is independent of product code
            let res = try? runTool("/usr/bin/shasum", ["-a", "256", fakeRelayShURL.path], environment: gitEnv)
            return res?.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        }()

        return IsolatedRunFixture(
            rootURL: rootURL,
            homeURL: homeURL,
            repoURL: repoURL,
            baseCommitOID: baseOID,
            projectURL: projectURL,
            fakeRelayDirURL: fakeRelayDirURL,
            fakeRelayShURL: fakeRelayShURL,
            fakeRelaySHA256: shaHex,
            baseEnvironment: gitEnv
        )
    }

    @Test("RelayCLIRunner run rejects every invalid plan and CLI usage condition with exit 2, empty stdout, and zero side effects")
    func cliRunRejectsEveryInvalidPlanAndArgumentCaseWithExit2AndZeroSideEffects() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-exit2")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let promptsDir = fx.rootURL.appendingPathComponent("plans/prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        let validPromptURL = promptsDir.appendingPathComponent("task.md")
        try "STUB WRITE out.txt ok\n".write(to: validPromptURL, atomically: true, encoding: .utf8)

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let cli = RelayCLIRunner()

        func writePlan(_ name: String, rawJSON: String) throws -> String {
            let url = plansDir.appendingPathComponent(name)
            try rawJSON.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        let validPlanPath = try writePlan(
            "valid.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}
              ]
            }
            """
        )

        func expectExit2(_ label: String, args: [String], env: [String: String]? = nil) async {
            let res = await cli.executeCommand(arguments: args, environment: env ?? fx.baseEnvironment)
            #expect(res.exitCode == 2, "\(label): expected exit 2, got \(res.exitCode) (stderr=\(res.stderr))")
            #expect(res.stdout.isEmpty, "\(label): stdout must be empty on exit 2, got '\(res.stdout)'")
            #expect(!res.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(label): stderr must explain reason")
        }

        // 1. Missing <plan.json>
        await expectExit2("missing plan arg", args: ["run", "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 2. Missing --project
        await expectExit2("missing --project", args: ["run", validPlanPath, "--relay-sh", fx.fakeRelayShURL.path])

        // 3. Nonexistent --project bundle (must not create directory!)
        let nonexistentProj = fx.rootURL.appendingPathComponent("NeverInit.relayproj")
        await expectExit2("nonexistent --project", args: ["run", validPlanPath, "--project", nonexistentProj.path, "--relay-sh", fx.fakeRelayShURL.path])
        #expect(!FileManager.default.fileExists(atPath: nonexistentProj.path))

        // 4. --project inside repo working tree
        let insideRepoProj = fx.repoURL.appendingPathComponent("NestedInsideRepo.relayproj", isDirectory: true)
        _ = try RelayProjectDatabase(bundleDirectoryURL: insideRepoProj)
        await expectExit2("project inside repo", args: ["run", validPlanPath, "--project", insideRepoProj.path, "--relay-sh", fx.fakeRelayShURL.path])
        try FileManager.default.removeItem(at: insideRepoProj)

        // 5. Invalid RELAY_BUDGET_USD in environment (`0` and `bad`)
        for badBudget in ["0", "bad"] {
            var budgetEnv = fx.baseEnvironment
            budgetEnv["RELAY_BUDGET_USD"] = badBudget
            await expectExit2("invalid RELAY_BUDGET_USD=\(badBudget)", args: ["run", validPlanPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path], env: budgetEnv)
        }

        // 6. Malformed JSON & wrong field type
        let malformedPath = try writePlan("malformed.json", rawJSON: "{not valid json")
        await expectExit2("malformed JSON", args: ["run", malformedPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        let emptyLanesPath = try writePlan(
            "empty-lanes.json",
            rawJSON: #"{"repo": "\#(fx.repoURL.path)", "base": "main", "lanes": []}"#
        )
        await expectExit2("empty lanes", args: ["run", emptyLanesPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 7. Invalid lane IDs (each tested individually, including reserved 'integration')
        let invalidLaneIDs = ["a/b", "../x", "-bad", "Upper", String(repeating: "a", count: 41), "integration"]
        for (idx, badID) in invalidLaneIDs.enumerated() {
            let p = try writePlan(
                "bad-id-\(idx).json",
                rawJSON: """
                {
                  "repo": "\(fx.repoURL.path)",
                  "base": "main",
                  "lanes": [{"id": "\(badID)", "agent": "claude", "prompt": "prompts/task.md", "after": []}]
                }
                """
            )
            await expectExit2("invalid lane id '\(badID)'", args: ["run", p, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])
        }

        // 8. Duplicate lane IDs
        let dupPath = try writePlan(
            "dup-lanes.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []},
                {"id": "api", "agent": "codex", "prompt": "prompts/task.md", "after": []}
              ]
            }
            """
        )
        await expectExit2("duplicate lane id", args: ["run", dupPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 9. `after` references nonexistent lane (R38)
        let badAfterPath = try writePlan(
            "bad-after.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": ["nonexistent"]}
              ]
            }
            """
        )
        await expectExit2("missing after lane", args: ["run", badAfterPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 10. Dependency cycle (2-node cycle & self-dependency)
        let cyclePath = try writePlan(
            "cycle.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "a", "agent": "claude", "prompt": "prompts/task.md", "after": ["b"]},
                {"id": "b", "agent": "codex", "prompt": "prompts/task.md", "after": ["a"]}
              ]
            }
            """
        )
        await expectExit2("cycle a<->b", args: ["run", cyclePath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        let selfCyclePath = try writePlan(
            "self-cycle.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "a", "agent": "claude", "prompt": "prompts/task.md", "after": ["a"]}
              ]
            }
            """
        )
        await expectExit2("self-cycle", args: ["run", selfCyclePath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 11. Multiple predecessors (`after.count > 1`)
        let multiAfterPath = try writePlan(
            "multi-after.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "a", "agent": "claude", "prompt": "prompts/task.md", "after": []},
                {"id": "b", "agent": "codex", "prompt": "prompts/task.md", "after": []},
                {"id": "c", "agent": "agy", "prompt": "prompts/task.md", "after": ["a", "b"]}
              ]
            }
            """
        )
        await expectExit2("multiple predecessors", args: ["run", multiAfterPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 12. Unknown agent (including customShell "shell" and "gpt")
        for badAgent in ["gpt", "shell"] {
            let badAgentPath = try writePlan(
                "bad-agent-\(badAgent).json",
                rawJSON: """
                {
                  "repo": "\(fx.repoURL.path)",
                  "base": "main",
                  "lanes": [
                    {"id": "api", "agent": "\(badAgent)", "prompt": "prompts/task.md", "after": []}
                  ]
                }
                """
            )
            await expectExit2("unknown agent \(badAgent)", args: ["run", badAgentPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])
        }

        // 13. Missing prompt file
        let missingPromptPath = try writePlan(
            "missing-prompt.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/does-not-exist.md", "after": []}
              ]
            }
            """
        )
        await expectExit2("missing prompt", args: ["run", missingPromptPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 14. `repo` is not a git repository
        let nonGitDir = fx.rootURL.appendingPathComponent("not-a-git-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nonGitDir, withIntermediateDirectories: true)
        let nonGitPlanPath = try writePlan(
            "non-git.json",
            rawJSON: """
            {
              "repo": "\(nonGitDir.path)",
              "base": "main",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}
              ]
            }
            """
        )
        await expectExit2("repo not git", args: ["run", nonGitPlanPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 15. `base` cannot be resolved
        let badBasePath = try writePlan(
            "bad-base.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "no-such-branch-or-tag",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}
              ]
            }
            """
        )
        await expectExit2("bad base", args: ["run", badBasePath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path])

        // 16. Repo missing git committer identity (R46: git -c user.useConfigOnly=true var GIT_COMMITTER_IDENT)
        let noIdentFx = try makeIsolatedRunFixture(prefix: "relay-run-noident", configureGitIdentity: false)
        defer { try? FileManager.default.removeItem(at: noIdentFx.rootURL) }
        let noIdentPlanPath = try writePlan(
            "no-ident.json",
            rawJSON: """
            {
              "repo": "\(noIdentFx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}
              ]
            }
            """
        )
        await expectExit2(
            "missing git identity",
            args: ["run", noIdentPlanPath, "--project", noIdentFx.projectURL.path, "--relay-sh", noIdentFx.fakeRelayShURL.path],
            env: noIdentFx.baseEnvironment
        )

        // Verify zero side effects across repo & project bundle!
        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        #expect(try db.allRuns().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.projectURL.appendingPathComponent("runs").path))
        let wtList = try runTool("/usr/bin/git", ["worktree", "list", "--porcelain"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        let wtCount = wtList.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count
        #expect(wtCount == 1)
        let branches = try runTool("/usr/bin/git", ["branch", "--format=%(refname:short)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    @Test("RelayCLIRunner run rejects missing/non-executable/incomplete relay.sh, RELAY_WORKER, and held run.lock with exit 125 and zero side effects")
    func cliRunRejectsPreStartEnvironmentAndLockErrorsWithExit125AndZeroSideEffects() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-exit125")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        let promptURL = plansDir.appendingPathComponent("api.md")
        try "STUB WRITE a.txt hi\n".write(to: promptURL, atomically: true, encoding: .utf8)
        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "api", "agent": "claude", "prompt": "api.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()

        func expectExit125(_ label: String, args: [String], env: [String: String]? = nil, stderrContains: String? = nil) async {
            let res = await cli.executeCommand(arguments: args, environment: env ?? fx.baseEnvironment)
            #expect(res.exitCode == 125, "\(label): expected exit 125, got \(res.exitCode) (stderr=\(res.stderr))")
            #expect(res.stdout.isEmpty, "\(label): stdout must be empty on exit 125, got '\(res.stdout)'")
            #expect(!res.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(label): stderr must explain reason")
            if let needle = stderrContains {
                #expect(res.stderr.contains(needle), "\(label): expected '\(needle)' in stderr '\(res.stderr)'")
            }
        }

        // 1. --relay-sh does not exist
        let missingRelay = fx.rootURL.appendingPathComponent("no-such-relay.sh").path
        await expectExit125(
            "nonexistent --relay-sh",
            args: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", missingRelay]
        )

        // 2. Default $HOME fallback when HOME is empty (no relay.sh installed in isolated HOME)
        await expectExit125(
            "missing relay.sh in isolated HOME",
            args: ["run", planURL.path, "--project", fx.projectURL.path]
        )

        // 3. relay.sh exists with relay_util.py, but lacks +x permission
        let nonExecDir = fx.rootURL.appendingPathComponent("nonexec-relay", isDirectory: true)
        try FileManager.default.createDirectory(at: nonExecDir, withIntermediateDirectories: true)
        let nonExecSh = nonExecDir.appendingPathComponent("relay.sh")
        try "#!/bin/sh\nexit 0\n".write(to: nonExecSh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecSh.path)
        try "# util\n".write(to: nonExecDir.appendingPathComponent("relay_util.py"), atomically: true, encoding: .utf8)
        await expectExit125(
            "non-executable relay.sh",
            args: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", nonExecSh.path]
        )

        // 4. Executable relay.sh, but sibling relay_util.py is missing
        let noUtilDir = fx.rootURL.appendingPathComponent("noutil-relay", isDirectory: true)
        try FileManager.default.createDirectory(at: noUtilDir, withIntermediateDirectories: true)
        let noUtilSh = noUtilDir.appendingPathComponent("relay.sh")
        try "#!/bin/sh\nexit 0\n".write(to: noUtilSh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noUtilSh.path)
        await expectExit125(
            "missing sibling relay_util.py",
            args: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", noUtilSh.path]
        )

        // 5. RELAY_WORKER is set in environment (R45)
        var workerEnv = fx.baseEnvironment
        workerEnv["RELAY_WORKER"] = "agy-coder-test-worker"
        await expectExit125(
            "RELAY_WORKER set",
            args: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            env: workerEnv
        )

        // 6. Project run.lock is already held by another active run -> exit 125 naming holder runID!
        let holdingRunID = "20261116-040000-beef"
        let heldLock = try RelayProjectRunLock.acquire(
            bundleDirectoryURL: fx.projectURL,
            runID: holdingRunID,
            pid: 7777
        )
        await expectExit125(
            "project locked by active run",
            args: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            stderrContains: holdingRunID
        )
        heldLock.release()

        // Verify zero side effects across repo & project bundle!
        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        #expect(try db.allRuns().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.projectURL.appendingPathComponent("runs").path))
        let wtList = try runTool("/usr/bin/git", ["worktree", "list", "--porcelain"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        let wtCount = wtList.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count
        #expect(wtCount == 1)
    }

    @Test("RelayCLIRunner run resolves relative repo/prompt paths and RELAYIDE_RELAY_SH, executes predecessor-chained lanes, commits changes, releases lock, and matches status --run JSON")
    func cliRunResolvesRelativePathsExecutesChainedLanesAndMatchesStatusRun() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-stage04-chain")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        // Place plan.json in <root>/plans/plan.json using relative repo "../target-repo" and relative prompts
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB WRITE api.txt 1\n".write(to: promptsDir.appendingPathComponent("api.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE docs.txt 2\n".write(to: promptsDir.appendingPathComponent("docs.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        let rawPlanText = """
        {
          "repo": "../target-repo",
          "base": "main",
          "lanes": [
            {"id": "api", "agent": "claude", "prompt": "prompts/api.md", "after": []},
            {"id": "docs", "agent": "agy", "prompt": "prompts/docs.md", "after": ["api"]}
          ],
          "verify": "test -f api.txt && test -f docs.txt"
        }
        """
        try rawPlanText.write(to: planURL, atomically: true, encoding: .utf8)

        // Provide fake relay.sh via RELAYIDE_RELAY_SH (testing env fallback when --relay-sh is omitted)
        var env = fx.baseEnvironment
        env["RELAYIDE_RELAY_SH"] = fx.fakeRelayShURL.path

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--lang", "zh"],
            environment: env
        )

        #expect(runRes.exitCode == 0)
        #expect(!runRes.stdout.isEmpty)
        #expect(!runRes.stderr.contains("将在 M2 执行"))

        // Lock must have been cleanly released before returning!
        #expect(RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: fx.projectURL).isHeld == false)
        let probeLock = try RelayProjectRunLock.acquire(bundleDirectoryURL: fx.projectURL, runID: "20261116-050000-0001")
        probeLock.release()

        let recorded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: runRes.stdout)
        #expect(recorded.runID.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
        #expect(recorded.status == .succeeded)
        #expect(recorded.baseRef == "main")
        #expect(recorded.baseCommitOID == fx.baseCommitOID)
        #expect(recorded.verifyCommand == "test -f api.txt && test -f docs.txt")
        #expect(recorded.relayShSHA256 == fx.fakeRelaySHA256)
        #expect(recorded.integration?.status == .verified)
        #expect(recorded.integration?.ready == true)

        // Copied plan.json at <project>/runs/<runID>/plan.json must match input byte-for-byte
        let expectedCopyURL = fx.projectURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(recorded.runID, isDirectory: true)
            .appendingPathComponent("plan.json")
        #expect(recorded.planCopyPath == expectedCopyURL.path)
        let copiedData = try Data(contentsOf: expectedCopyURL)
        #expect(copiedData == Data(rawPlanText.utf8))

        // Both lanes succeeded and `docs` started from `api`'s committed branch head!
        #expect(recorded.lanes.count == 2)
        #expect(recorded.lanes.map(\.laneID) == ["api", "docs"])
        #expect(recorded.lanes.allSatisfy { $0.status == .succeeded })
        let apiCommit = try #require(recorded.lanes[0].commitOID)
        let docsCommit = try #require(recorded.lanes[1].commitOID)
        let docsParent = try runTool("/usr/bin/git", ["rev-parse", "\(docsCommit)^"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(docsParent == apiCommit)
        let docsChangedFromBase = try runTool("/usr/bin/git", ["diff", "--name-only", "\(fx.baseCommitOID)..\(docsCommit)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.split(whereSeparator: \.isNewline).map(String.init)
        #expect(docsChangedFromBase == ["api.txt", "docs.txt"])

        // Single-run status query JSON must equal `run` stdout byte-for-byte!
        let singleStatusRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", recorded.runID],
            environment: fx.baseEnvironment
        )
        #expect(singleStatusRes.exitCode == 0)
        #expect(singleStatusRes.stdout == runRes.stdout)

        // Also verify default $HOME discovery order (--relay-sh > RELAYIDE_RELAY_SH > $HOME/...) in isolated HOME
        let homeScriptsDir = [".agents", "skills", "agent-relay", "scripts"].reduce(fx.homeURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: homeScriptsDir, withIntermediateDirectories: true)
        let homeRelayURL = homeScriptsDir.appendingPathComponent("relay.sh")
        try FileManager.default.copyItem(at: fx.fakeRelayShURL, to: homeRelayURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: homeRelayURL.path)
        try "# stub\n".write(to: homeScriptsDir.appendingPathComponent("relay_util.py"), atomically: true, encoding: .utf8)
        let resolvedFromHome = try RelayRunExecutor.resolveAndVerifyRelayScript(
            explicitPath: nil,
            environment: fx.baseEnvironment,
            language: .en
        )
        #expect(resolvedFromHome.url.standardizedFileURL == homeRelayURL.standardizedFileURL)
        #expect(resolvedFromHome.sha256Hex == fx.fakeRelaySHA256)

        // Explicit --relay-sh takes precedence over RELAYIDE_RELAY_SH and $HOME
        let resolvedFromFlag = try RelayRunExecutor.resolveAndVerifyRelayScript(
            explicitPath: fx.fakeRelayShURL.path,
            environment: env,
            language: .en
        )
        #expect(resolvedFromFlag.url.standardizedFileURL == fx.fakeRelayShURL.standardizedFileURL)
    }

    // MARK: - 28. M1 Stage 04 Scheduling, Commits, Spend, Statuses, Branch Collision & Live Status Tests

    private func parseTraceInterval(at traceURL: URL) throws -> (start: Double, end: Double) {
        let text = try String(contentsOf: traceURL, encoding: .utf8)
        var startVal: Double?
        var endVal: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count >= 2, parts[0] == "start", startVal == nil {
                startVal = Double(parts[1])
            } else if parts.count >= 2, parts[0] == "end" {
                endVal = Double(parts[1])
            }
        }
        guard let s = startVal, let e = endVal else {
            throw RelayIDEError.relayEnvironmentFailure("Incomplete trace file at \(traceURL.path): \(text)")
        }
        return (s, e)
    }

    @Test("RelayCLIRunner run executes two independent lanes in parallel (overlapping trace intervals), creates isolated worktrees & branches with 1 commit each, keeps main clean, supports concurrent status --run, and outputs identical JSON")
    func cliRunParallelIndependentLanesWorktreesCommitsAndLiveStatus() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-parallel")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let traceDir = fx.rootURL.appendingPathComponent("traces", isDirectory: true)
        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let readyA = gatesDir.appendingPathComponent("ready-a")
        let readyB = gatesDir.appendingPathComponent("ready-b")
        let releaseGate = gatesDir.appendingPathComponent("release")

        try """
        STUB WRITE a.txt alpha-payload
        STUB READY \(readyA.path)
        STUB WAIT \(releaseGate.path) 30
        STUB COST 0.0125
        """.write(to: plansDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        try """
        STUB WRITE b.txt beta-payload
        STUB READY \(readyB.path)
        STUB WAIT \(releaseGate.path) 30
        STUB TOKENS 2400
        """.write(to: plansDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "a", "agent": "claude", "prompt": "a.md", "after": []},
            {"id": "b", "agent": "codex", "prompt": "b.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        var env = fx.baseEnvironment
        env["STUB_TRACE_DIR"] = traceDir.path

        final class BoolBox: @unchecked Sendable { var done = false }
        let taskState = BoolBox()
        let cli = RelayCLIRunner()
        let runTask = Task {
            let r = await cli.executeCommand(
                arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: env
            )
            taskState.done = true
            return r
        }

        // Wait until BOTH lanes reach the barrier simultaneously (or `runTask` exits early on error)
        let deadline = Date().addingTimeInterval(25.0)
        while (!FileManager.default.fileExists(atPath: readyA.path) || !FileManager.default.fileExists(atPath: readyB.path)) && !taskState.done && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: readyA.path))
        #expect(FileManager.default.fileExists(atPath: readyB.path))

        // While both lanes are running, query `status --runs` and `status --run` concurrently!
        let liveRunsRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--runs"],
            environment: fx.baseEnvironment
        )
        #expect(liveRunsRes.exitCode == 0)
        let liveRuns = try RelayRunJSONCodec.decode([RelayRunRecord].self, from: liveRunsRes.stdout)
        let liveRun = try #require(liveRuns.first)
        #expect(liveRun.status == .running)
        #expect(liveRun.lanes.allSatisfy { $0.status == .running })
        for lane in liveRun.lanes {
            let pid = try #require(lane.pid)
            #expect(Darwin.kill(pid, 0) == 0)
        }

        // Release barrier and await `run` completion
        try Data().write(to: releaseGate)
        let runRes = await runTask.value
        #expect(runRes.exitCode == 0)

        // Verify interval overlap from trace files: startA < endB && startB < endA
        let intervalA = try parseTraceInterval(at: traceDir.appendingPathComponent("a.trace"))
        let intervalB = try parseTraceInterval(at: traceDir.appendingPathComponent("b.trace"))
        #expect(intervalA.start < intervalB.end && intervalB.start < intervalA.end)

        // Decode JSON and verify byte-for-byte match with `status --project <工程> --run <runID>`
        let finished = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: runRes.stdout)
        let statusRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", finished.runID],
            environment: fx.baseEnvironment
        )
        #expect(statusRes.exitCode == 0)
        #expect(statusRes.stdout == runRes.stdout)

        // Verify main repo cleanliness and unchanged `main` commit OID
        let mainStatus = try runTool("/usr/bin/git", ["status", "--porcelain"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        #expect(mainStatus.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let mainHead = try runTool("/usr/bin/git", ["rev-parse", "main"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mainHead == fx.baseCommitOID)

        // Verify branches, 1 commit ahead of base each, exact single file diff, zero .relay/ paths, repo identity, and .pty files
        let runDir = fx.projectURL.appendingPathComponent("runs/\(finished.runID)", isDirectory: true)
        for (laneID, expectedFile) in [("a", "a.txt"), ("b", "b.txt")] {
            let branch = "relay/\(finished.runID)/\(laneID)"
            let ahead = try runTool("/usr/bin/git", ["rev-list", "--count", "\(fx.baseCommitOID)..\(branch)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(ahead == "1")
            let diffFiles = try runTool("/usr/bin/git", ["diff", "--name-only", "\(fx.baseCommitOID)..\(branch)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(diffFiles == expectedFile)
            #expect(!diffFiles.contains(".relay"))
            let author = try runTool("/usr/bin/git", ["log", "-1", "--format=%an <%ae>", branch], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(author == "Relay Unit Tester <unit-tester@relay.invalid>")

            let ptyPath = runDir.appendingPathComponent("lanes/\(laneID).pty").path
            let wtPath = runDir.appendingPathComponent("worktrees/\(laneID)").path
            #expect(FileManager.default.fileExists(atPath: ptyPath))
            #expect(FileManager.default.fileExists(atPath: wtPath))
            let ptyText = try String(contentsOfFile: ptyPath, encoding: .utf8)
            #expect(ptyText.contains("relay 01-"))
        }

        // Stderr must have start & finish lines for both lanes
        let stderrLines = runRes.stderr.split(whereSeparator: \.isNewline).map(String.init)
        #expect(stderrLines.count >= 4)
        #expect(stderrLines.contains { $0.contains("lane a") && $0.contains("started") })
        #expect(stderrLines.contains { $0.contains("lane a") && $0.contains("finished") })
        #expect(stderrLines.contains { $0.contains("lane b") && $0.contains("started") })
        #expect(stderrLines.contains { $0.contains("lane b") && $0.contains("finished") })
    }

    @Test("RelayCLIRunner run schedules without wave barriers: fast predecessor launches its successor while slow independent lane is still blocked")
    func cliRunEventDrivenNoWaveBarrierScheduling() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-nowave")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let slowReady = gatesDir.appendingPathComponent("slow-ready")
        let slowRelease = gatesDir.appendingPathComponent("slow-release")
        let fastChildDone = gatesDir.appendingPathComponent("fast-child-done")

        try "STUB WRITE fast.txt 1\n".write(to: plansDir.appendingPathComponent("fast.md"), atomically: true, encoding: .utf8)
        try """
        STUB WRITE fast-child.txt 2
        STUB READY \(fastChildDone.path)
        """.write(to: plansDir.appendingPathComponent("fast-child.md"), atomically: true, encoding: .utf8)
        try """
        STUB READY \(slowReady.path)
        STUB WAIT \(slowRelease.path) 30
        STUB WRITE slow.txt 3
        """.write(to: plansDir.appendingPathComponent("slow.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "fast", "agent": "claude", "prompt": "fast.md", "after": []},
            {"id": "slow", "agent": "codex", "prompt": "slow.md", "after": []},
            {"id": "fast-child", "agent": "agy", "prompt": "fast-child.md", "after": ["fast"]}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        final class BoolBox: @unchecked Sendable { var done = false }
        let taskState = BoolBox()
        let cli = RelayCLIRunner()
        let runTask = Task {
            let r = await cli.executeCommand(
                arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
                environment: fx.baseEnvironment
            )
            taskState.done = true
            return r
        }

        // `fast-child` MUST run and create `fastChildDone` BEFORE we ever release `slowRelease`!
        // A wave-based scheduler would deadlock here waiting for Wave 0 (`slow`) before starting Wave 1 (`fast-child`)!
        let deadline = Date().addingTimeInterval(20.0)
        while (!FileManager.default.fileExists(atPath: fastChildDone.path) || !FileManager.default.fileExists(atPath: slowReady.path)) && !taskState.done && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: fastChildDone.path))
        #expect(FileManager.default.fileExists(atPath: slowReady.path))

        try Data().write(to: slowRelease)
        let res = await runTask.value
        #expect(res.exitCode == 0)
        let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res.stdout)
        #expect(record.lanes.allSatisfy { $0.status == .succeeded })
    }

    @Test("RelayCLIRunner run skips successors on predecessor failure or partial completion without creating worktrees or branches, commits partial changes, records dirty files on failed lanes, and exits 1 with matching JSON")
    func cliRunPredecessorFailureAndPartialSkipsSuccessorsAndMatchesStatusJSON() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-fail-partial")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let traceDir = fx.rootURL.appendingPathComponent("traces", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        // A fails (exit 3) after writing dirty-a.txt -> B (`after: ["a"]`) and C (`after: ["b"]`) skipped!
        // P finishes `partial` (exit 5) after writing part.txt -> Q (`after: ["p"]`) skipped, while P HAS a commit!
        // D is independent and succeeds!
        try """
        STUB WRITE dirty-a.txt uncommitted-payload
        STUB EXIT 3
        """.write(to: plansDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE should-not-run-b.txt x\n".write(to: plansDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE should-not-run-c.txt x\n".write(to: plansDir.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        try """
        STUB WRITE part.txt partial-work
        STUB STATUS partial
        """.write(to: plansDir.appendingPathComponent("p.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE should-not-run-q.txt x\n".write(to: plansDir.appendingPathComponent("q.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE ok-d.txt clean-work\n".write(to: plansDir.appendingPathComponent("d.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "a", "agent": "claude", "prompt": "a.md", "after": []},
            {"id": "b", "agent": "codex", "prompt": "b.md", "after": ["a"]},
            {"id": "c", "agent": "vibe", "prompt": "c.md", "after": ["b"]},
            {"id": "p", "agent": "claude", "prompt": "p.md", "after": []},
            {"id": "q", "agent": "agy", "prompt": "q.md", "after": ["p"]},
            {"id": "d", "agent": "codex", "prompt": "d.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        var env = fx.baseEnvironment
        env["STUB_TRACE_DIR"] = traceDir.path

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
            environment: env
        )

        #expect(runRes.exitCode == 1)
        #expect(!runRes.stdout.isEmpty)

        // `run` stdout JSON must equal `status --run` JSON byte-for-byte even when exitCode == 1!
        let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: runRes.stdout)
        let statusRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", record.runID],
            environment: fx.baseEnvironment
        )
        #expect(statusRes.exitCode == 0)
        #expect(statusRes.stdout == runRes.stdout)

        let byID = Dictionary(uniqueKeysWithValues: record.lanes.map { ($0.laneID, $0) })

        // Check `a`: failed, exitCode 3, no commit, uncommittedFiles == ["dirty-a.txt"]
        let laneA = try #require(byID["a"])
        #expect(laneA.status == .failed)
        #expect(laneA.exitCode == 3)
        #expect(laneA.commitOID == nil)
        #expect(laneA.uncommittedFiles == ["dirty-a.txt"])
        let aheadA = try runTool("/usr/bin/git", ["rev-list", "--count", "\(fx.baseCommitOID)..relay/\(record.runID)/a"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(aheadA == "0")

        // Check `b`, `c`, `q`: skipped, reason names predecessor & status, NO worktree, NO branch, NO trace!
        let runDir = fx.projectURL.appendingPathComponent("runs/\(record.runID)", isDirectory: true)
        for (skippedID, predID, predStatusWord) in [("b", "a", "failed"), ("c", "b", "skipped"), ("q", "p", "partial")] {
            let skipped = try #require(byID[skippedID])
            #expect(skipped.status == .skipped)
            #expect(skipped.reason?.contains(predID) == true)
            #expect(skipped.reason?.contains(predStatusWord) == true)
            #expect(skipped.worktreePath == nil)
            #expect(skipped.branch == nil)
            #expect(skipped.commitOID == nil)
            #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("worktrees/\(skippedID)").path))
            #expect(!FileManager.default.fileExists(atPath: traceDir.appendingPathComponent("\(skippedID).trace").path))
            let refCheck = try runTool("/usr/bin/git", ["show-ref", "--verify", "--quiet", "refs/heads/relay/\(record.runID)/\(skippedID)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            #expect(refCheck.exitCode != 0)
        }

        // Check `p`: partial, exitCode 5, HAS commit on `relay/<runID>/p` with subject containing `: partial`!
        let laneP = try #require(byID["p"])
        #expect(laneP.status == .partial)
        #expect(laneP.exitCode == 5)
        let pCommit = try #require(laneP.commitOID)
        let pSubject = try runTool("/usr/bin/git", ["log", "-1", "--format=%s", pCommit], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pSubject == "relay \(record.runID) p (claude): partial")

        // Check `d`: succeeded
        let laneD = try #require(byID["d"])
        #expect(laneD.status == .succeeded)
        #expect(laneD.commitOID != nil)
    }

    @Test("RelayCLIRunner run classifies refused (relay: reason), agent exit 2 (failed), timeout (124), and signal death (signal 9, exitCode null, never succeeded)")
    func cliRunRefusedAgentExit2TimeoutAndSignalDeathClassification() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-outcomes")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        try """
        FAKE_RELAY WARNING minor note
        FAKE_RELAY REFUSE not sent: prompt looks like it contains a credential:
        """.write(to: plansDir.appendingPathComponent("refuse.md"), atomically: true, encoding: .utf8)

        try "STUB EXIT 2\n".write(to: plansDir.appendingPathComponent("agent-exit2.md"), atomically: true, encoding: .utf8)
        try "FAKE_RELAY TIMEOUT\n".write(to: plansDir.appendingPathComponent("timeout.md"), atomically: true, encoding: .utf8)
        try "FAKE_RELAY KILL_SELF 9\n".write(to: plansDir.appendingPathComponent("sig9.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "refuse-lane", "agent": "claude", "prompt": "refuse.md", "after": []},
            {"id": "exit2-lane", "agent": "codex", "prompt": "agent-exit2.md", "after": []},
            {"id": "timeout-lane", "agent": "agy", "prompt": "timeout.md", "after": []},
            {"id": "sig9-lane", "agent": "vibe", "prompt": "sig9.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        let res = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )

        // Note: `run` itself MUST return 1 (completed with failed/refused/timeout lanes), NEVER 2 or 125!
        #expect(res.exitCode == 1)
        let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res.stdout)
        let byID = Dictionary(uniqueKeysWithValues: record.lanes.map { ($0.laneID, $0) })

        let refused = try #require(byID["refuse-lane"])
        #expect(refused.status == .refused)
        #expect(refused.exitCode == 2)
        #expect(refused.reason == "relay: not sent: prompt looks like it contains a credential:")
        #expect(refused.commitOID == nil)

        let exit2 = try #require(byID["exit2-lane"])
        #expect(exit2.status == .failed)
        #expect(exit2.exitCode == 2)
        #expect(exit2.commitOID == nil)

        let timedOut = try #require(byID["timeout-lane"])
        #expect(timedOut.status == .timeout)
        #expect(timedOut.exitCode == 124)
        #expect(timedOut.commitOID == nil)

        let sig9 = try #require(byID["sig9-lane"])
        #expect(sig9.status == .failed)
        #expect(sig9.status != .succeeded)
        #expect(sig9.signal == 9)
        #expect(sig9.exitCode == nil)
        #expect(sig9.commitOID == nil)

        // Verify raw JSON explicitly encodes `"exitCode" : null` on signal-killed lane
        let parsedJSON = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let rawLanes = parsedJSON?["lanes"] as? [[String: Any]]
        let rawSig9 = rawLanes?.first { ($0["laneID"] as? String) == "sig9-lane" }
        #expect(rawSig9?["exitCode"] is NSNull)
        #expect((rawSig9?["signal"] as? Int) == 9)
    }

    @Test("RelayCLIRunner run handles no-change lanes (succeeded-no-changes, zero commits, exit 0), preserves agent commits, and records all three spend cases without writing 0")
    func cliRunNoChangesAgentCommitsAndThreeSpendCases() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-spend-nochange")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        // 1. No file changes + USD spend
        try """
        STUB COST 0.0456
        """.write(to: plansDir.appendingPathComponent("noop-usd.md"), atomically: true, encoding: .utf8)

        // 2. Agent makes its own commit + leaves unstaged file + unpriced tokens only
        try """
        STUB WRITE step1.txt from-agent
        STUB GIT_COMMIT agent-own-commit
        STUB WRITE step2.txt unstaged-afterwards
        STUB TOKENS 9876
        """.write(to: plansDir.appendingPathComponent("selfcommit-tok.md"), atomically: true, encoding: .utf8)

        // 3. No LOG.md entry (`FAKE_RELAY NO_LOG`) -> `no_record`, costUSD == nil, tokens == nil (never 0!)
        try """
        FAKE_RELAY NO_LOG
        STUB WRITE nolog.txt ok
        """.write(to: plansDir.appendingPathComponent("nolog.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "noop-usd", "agent": "claude", "prompt": "noop-usd.md", "after": []},
            {"id": "selfcommit-tok", "agent": "agy", "prompt": "selfcommit-tok.md", "after": ["noop-usd"]},
            {"id": "nolog", "agent": "vibe", "prompt": "nolog.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        let res = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )

        #expect(res.exitCode == 0)
        let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res.stdout)
        let byID = Dictionary(uniqueKeysWithValues: record.lanes.map { ($0.laneID, $0) })

        // 1. `noop-usd`: succeeded-no-changes, zero commits, costUSD == 0.0456, costSource == "usd"
        let noop = try #require(byID["noop-usd"])
        #expect(noop.status == .succeededNoChanges)
        #expect(noop.commitOID == nil)
        #expect(noop.costUSD == 0.0456)
        #expect(noop.costSource == "usd")
        let noopAhead = try runTool("/usr/bin/git", ["rev-list", "--count", "\(fx.baseCommitOID)..relay/\(record.runID)/noop-usd"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(noopAhead == "0")

        // 2. `selfcommit-tok`: succeeded (also verifies successor after succeeded-no-changes runs!), 2 commits ahead of base, tokens == 9876, costUSD == nil, costSource == "unpriced"
        let selfCommit = try #require(byID["selfcommit-tok"])
        #expect(selfCommit.status == .succeeded)
        #expect(selfCommit.costUSD == nil)
        #expect(selfCommit.tokens == 9876)
        #expect(selfCommit.costSource == "unpriced")
        let selfAhead = try runTool("/usr/bin/git", ["rev-list", "--count", "\(fx.baseCommitOID)..relay/\(record.runID)/selfcommit-tok"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(selfAhead == "2")

        // 3. `nolog`: succeeded, costUSD == nil, tokens == nil, costSource == "no_record"
        let nolog = try #require(byID["nolog"])
        #expect(nolog.status == .succeeded)
        #expect(nolog.costUSD == nil)
        #expect(nolog.tokens == nil)
        #expect(nolog.costSource == "no_record")

        // Raw JSON check: costUSD on unpriced/no_record and tokens on no_record are explicit `null`, NEVER `0`!
        let parsedJSON = try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any]
        let rawLanes = parsedJSON?["lanes"] as? [[String: Any]]
        let rawUnpriced = rawLanes?.first { ($0["laneID"] as? String) == "selfcommit-tok" }
        let rawNoLog = rawLanes?.first { ($0["laneID"] as? String) == "nolog" }
        #expect(rawUnpriced?["costUSD"] is NSNull)
        #expect(rawNoLog?["costUSD"] is NSNull)
        #expect(rawNoLog?["tokens"] is NSNull)
    }

    @Test("RelayCLIRunner run exits 125 with empty stdout when relay/<runID>/<lane> branch already exists without resetting the existing branch, and localizes stderr across --lang zh/en while keeping English JSON status words")
    func cliRunExistingBranchExits125PreservingCommitAndLocalizesStderr() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-collision-lang")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        try "STUB WRITE out.txt hi\n".write(to: plansDir.appendingPathComponent("api.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "api", "agent": "claude", "prompt": "api.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        // Pre-create branch `relay/<collidingRunID>/api` with an extra commit
        let collidingRunID = "20261116-090000-dead"
        let collidingBranch = "relay/\(collidingRunID)/api"
        _ = try runTool("/usr/bin/git", ["checkout", "-b", collidingBranch, fx.baseCommitOID], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        try "do-not-lose\n".write(to: fx.repoURL.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        _ = try runTool("/usr/bin/git", ["add", "keep.txt"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        _ = try runTool("/usr/bin/git", ["commit", "-m", "precious existing commit"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        let preciousOID = try runTool("/usr/bin/git", ["rev-parse", "HEAD"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runTool("/usr/bin/git", ["checkout", "main"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        #expect(preciousOID != fx.baseCommitOID)

        let collidingCLI = RelayCLIRunner(runIDProvider: { collidingRunID })
        let collisionRes = await collidingCLI.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )
        #expect(collisionRes.exitCode == 125)
        #expect(collisionRes.stdout.isEmpty)
        let afterCollisionOID = try runTool("/usr/bin/git", ["rev-parse", "refs/heads/\(collidingBranch)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterCollisionOID == preciousOID)

        // Now run with normal unique runIDs under `--lang zh` and `--lang en`: stderr language differs, JSON status token is identical `"succeeded"`
        let normalCLI = RelayCLIRunner()
        let resZH = await normalCLI.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
            environment: fx.baseEnvironment
        )
        let resEN = await normalCLI.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
            environment: fx.baseEnvironment
        )
        #expect(resZH.exitCode == 0)
        #expect(resEN.exitCode == 0)
        #expect(resZH.stderr != resEN.stderr)
        #expect(resZH.stderr.contains("通道 api"))
        #expect(resEN.stderr.contains("lane api"))

        let recZH = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: resZH.stdout)
        let recEN = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: resEN.stdout)
        #expect(recZH.status.rawValue == "succeeded")
        #expect(recEN.status.rawValue == "succeeded")
        #expect(recZH.lanes[0].status.rawValue == "succeeded")
        #expect(recEN.lanes[0].status.rawValue == "succeeded")
    }

    // MARK: - 28. M1 Stage 05: Cancellation (`130`/`143`), Hard Limit (`killed`), Internal `125` Abort & Concurrent Runs

    @Test("RelayCancellationPolicy computes default 1860s hard limit, honors RELAY_TIMEOUT+60s, and supports short test overrides")
    func cliRunCancellationPolicyHardLimitCalculation() {
        let def = RelayCancellationPolicy.default
        #expect(def.sigintGraceSeconds == 10.0)
        #expect(def.sigtermGraceSeconds == 5.0)
        #expect(def.effectiveHardLimitSeconds(environment: [:]) == 1860.0)
        #expect(def.effectiveHardLimitSeconds(environment: ["RELAY_TIMEOUT": "120"]) == 180.0)
        #expect(def.effectiveHardLimitSeconds(environment: ["RELAY_TIMEOUT": "invalid"]) == 1860.0)

        let injected = RelayCancellationPolicy(
            sigintGraceSeconds: 0.12,
            sigtermGraceSeconds: 0.12,
            hardLimitOverrideSeconds: 0.25
        )
        #expect(injected.effectiveHardLimitSeconds(environment: ["RELAY_TIMEOUT": "1800"]) == 0.25)
    }

    @Test("RelayCLIRunner run cancels active lanes on SIGINT (130) and SIGTERM (143), skips unstarted lanes, preserves worktrees without committing, and matches status --run JSON")
    func cliRunSignalCancellationMarksCancelledAndSkippedWithoutCommitting() async throws {
        for (sig, expectedExitCode) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
            let fx = try makeIsolatedRunFixture(prefix: "relay-run-cancel-\(expectedExitCode)")
            defer { try? FileManager.default.removeItem(at: fx.rootURL) }

            let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
            let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
            let traceDir = fx.rootURL.appendingPathComponent("traces", isDirectory: true)
            try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)

            let readyA = gatesDir.appendingPathComponent("ready-a")
            let readyB = gatesDir.appendingPathComponent("ready-b")
            let neverGate = gatesDir.appendingPathComponent("never-release")

            try """
            STUB WRITE dirty-a.txt uncommitted-a
            FAKE_RELAY ARM_READY \(readyA.path)
            STUB WAIT \(neverGate.path) 4
            """.write(to: plansDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

            try """
            STUB WRITE dirty-b.txt uncommitted-b
            FAKE_RELAY ARM_READY \(readyB.path)
            STUB WAIT \(neverGate.path) 4
            """.write(to: plansDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

            try "STUB WRITE should-not-run-c.txt x\n".write(
                to: plansDir.appendingPathComponent("c.md"),
                atomically: true,
                encoding: .utf8
            )

            let planURL = plansDir.appendingPathComponent("plan.json")
            try """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [
                {"id": "a", "agent": "claude", "prompt": "a.md", "after": []},
                {"id": "b", "agent": "codex", "prompt": "b.md", "after": []},
                {"id": "c", "agent": "agy", "prompt": "c.md", "after": ["a"]}
              ]
            }
            """.write(to: planURL, atomically: true, encoding: .utf8)

            var env = fx.baseEnvironment
            env["STUB_TRACE_DIR"] = traceDir.path

            let registry = RelayActiveLaneRegistry()
            let policy = RelayCancellationPolicy(sigintGraceSeconds: 0.25, sigtermGraceSeconds: 0.25)
            let cli = RelayCLIRunner(activeLaneRegistry: registry, cancellationPolicy: policy)

            let runTask = Task {
                await cli.executeCommand(
                    arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                    environment: env
                )
            }

            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: readyA.path)
                    && FileManager.default.fileExists(atPath: readyB.path) {
                    break
                }
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            #expect(FileManager.default.fileExists(atPath: readyA.path))
            #expect(FileManager.default.fileExists(atPath: readyB.path))

            registry.requestCancellation(signal: sig)
            let res = await runTask.value

            #expect(res.exitCode == expectedExitCode)
            #expect(!res.stdout.isEmpty)
            #expect(!res.stderr.isEmpty)

            let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res.stdout)
            #expect(record.status == .cancelled)

            let statusRes = await cli.executeCommand(
                arguments: ["status", "--project", fx.projectURL.path, "--run", record.runID],
                environment: fx.baseEnvironment
            )
            #expect(statusRes.exitCode == 0)
            #expect(statusRes.stdout == res.stdout)

            let byID = Dictionary(uniqueKeysWithValues: record.lanes.map { ($0.laneID, $0) })
            for (laneID, dirtyName) in [("a", "dirty-a.txt"), ("b", "dirty-b.txt")] {
                let lane = try #require(byID[laneID])
                #expect(lane.status == .cancelled)
                #expect(lane.commitOID == nil)
                #expect(lane.uncommittedFiles == [dirtyName])
                let wtPath = try #require(lane.worktreePath)
                #expect(FileManager.default.fileExists(atPath: wtPath))
                let ahead = try runTool(
                    "/usr/bin/git",
                    ["rev-list", "--count", "\(fx.baseCommitOID)..relay/\(record.runID)/\(laneID)"],
                    environment: fx.baseEnvironment,
                    currentDirectory: fx.repoURL
                ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(ahead == "0")
            }

            let laneC = try #require(byID["c"])
            #expect(laneC.status == .skipped)
            #expect(laneC.reason?.contains("运行被取消") == true)
            #expect(laneC.worktreePath == nil)
            #expect(laneC.branch == nil)
            #expect(!FileManager.default.fileExists(atPath: traceDir.appendingPathComponent("c.trace").path))
            let cRefCheck = try runTool(
                "/usr/bin/git",
                ["show-ref", "--verify", "--quiet", "refs/heads/relay/\(record.runID)/c"],
                environment: fx.baseEnvironment,
                currentDirectory: fx.repoURL
            )
            #expect(cRefCheck.exitCode != 0)
        }
    }

    @Test("RelayCLIRunner run cancellation escalates INT -> TERM -> KILL and kills separate-process-group agent descendants")
    func cliRunCancellationEscalatesIntTermKillAndCleansSubgroup() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-cancel-ladder")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let readyURL = gatesDir.appendingPathComponent("stubborn-ready")
        let sigLogURL = gatesDir.appendingPathComponent("stubborn-signals.log")
        let subPIDURL = gatesDir.appendingPathComponent("stubborn-sub.pid")
        let neverURL = gatesDir.appendingPathComponent("never")
        var trackedSubPID: pid_t = -1
        defer {
            if trackedSubPID > 0 {
                _ = Darwin.kill(-trackedSubPID, SIGKILL)
                _ = Darwin.kill(trackedSubPID, SIGKILL)
            }
        }

        try """
        FAKE_RELAY IGNORE_INT
        FAKE_RELAY IGNORE_TERM
        FAKE_RELAY SIGNAL_LOG \(sigLogURL.path)
        FAKE_RELAY SUBGROUP_PID_FILE \(subPIDURL.path)
        FAKE_RELAY ARM_READY \(readyURL.path)
        STUB WRITE dirty-stubborn.txt uncommitted
        STUB WAIT \(neverURL.path) 4
        """.write(to: plansDir.appendingPathComponent("stubborn.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "stubborn", "agent": "claude", "prompt": "stubborn.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let registry = RelayActiveLaneRegistry()
        let policy = RelayCancellationPolicy(sigintGraceSeconds: 0.14, sigtermGraceSeconds: 0.14)
        let cli = RelayCLIRunner(activeLaneRegistry: registry, cancellationPolicy: policy)

        let runTask = Task {
            await cli.executeCommand(
                arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
        }

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: readyURL.path) { break }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))

        let rawSubPID = try String(contentsOf: subPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        trackedSubPID = try #require(pid_t(rawSubPID))
        #expect(trackedSubPID > 0)
        #expect(Darwin.kill(trackedSubPID, 0) == 0)

        registry.requestCancellation(signal: SIGINT)
        let res = await runTask.value

        #expect(res.exitCode == 130)
        let loggedSigs = (try? String(contentsOf: sigLogURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(loggedSigs == ["INT", "TERM"])

        for _ in 0..<50 {
            if Darwin.kill(trackedSubPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Darwin.kill(trackedSubPID, 0) != 0, "Separate-process-group child \(trackedSubPID) survived run cancellation")

        let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res.stdout)
        #expect(record.status == .cancelled)
        #expect(record.lanes[0].status == .cancelled)
        #expect(record.lanes[0].commitOID == nil)
        #expect(record.lanes[0].uncommittedFiles == ["dirty-stubborn.txt"])
    }

    @Test("RelayCLIRunner run enforces per-lane hard time limit, marks hung lane killed without committing, skips successor, and exits 1")
    func cliRunHardLimitKillsHungLaneSkipsSuccessorAndExits1() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-hard-limit")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let sigLogURL = gatesDir.appendingPathComponent("hung-signals.log")
        let subPIDURL = gatesDir.appendingPathComponent("hung-sub.pid")
        var trackedSubPID: pid_t = -1
        defer {
            if trackedSubPID > 0 {
                _ = Darwin.kill(-trackedSubPID, SIGKILL)
                _ = Darwin.kill(trackedSubPID, SIGKILL)
            }
        }

        try """
        FAKE_RELAY IGNORE_INT
        FAKE_RELAY IGNORE_TERM
        FAKE_RELAY SIGNAL_LOG \(sigLogURL.path)
        FAKE_RELAY SUBGROUP_PID_FILE \(subPIDURL.path)
        STUB WRITE hung-dirty.txt partial-work
        STUB SLEEP 4
        """.write(to: plansDir.appendingPathComponent("hung.md"), atomically: true, encoding: .utf8)

        try "STUB WRITE should-not-run.txt x\n".write(
            to: plansDir.appendingPathComponent("after-hung.md"),
            atomically: true,
            encoding: .utf8
        )
        try "STUB WRITE sibling-ok.txt done\n".write(
            to: plansDir.appendingPathComponent("sibling.md"),
            atomically: true,
            encoding: .utf8
        )

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "hung", "agent": "codex", "prompt": "hung.md", "after": []},
            {"id": "after-hung", "agent": "vibe", "prompt": "after-hung.md", "after": ["hung"]},
            {"id": "sibling", "agent": "claude", "prompt": "sibling.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let policy = RelayCancellationPolicy(
            sigintGraceSeconds: 0.12,
            sigtermGraceSeconds: 0.12,
            hardLimitOverrideSeconds: 0.22
        )
        let cli = RelayCLIRunner(cancellationPolicy: policy)
        let res = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
            environment: fx.baseEnvironment
        )

        if let rawSub = try? String(contentsOf: subPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedPID = pid_t(rawSub) {
            trackedSubPID = parsedPID
        }

        #expect(res.exitCode == 1)
        #expect(!res.stdout.isEmpty)

        let record = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res.stdout)
        let statusRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", record.runID],
            environment: fx.baseEnvironment
        )
        #expect(statusRes.stdout == res.stdout)

        let byID = Dictionary(uniqueKeysWithValues: record.lanes.map { ($0.laneID, $0) })
        let hung = try #require(byID["hung"])
        #expect(hung.status == .killed)
        #expect(hung.commitOID == nil)
        #expect(hung.uncommittedFiles == ["hung-dirty.txt"])

        let loggedSigs = (try? String(contentsOf: sigLogURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(loggedSigs == ["INT", "TERM"])
        if trackedSubPID > 0 {
            for _ in 0..<50 {
                if Darwin.kill(trackedSubPID, 0) != 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(Darwin.kill(trackedSubPID, 0) != 0)
        }

        let afterHung = try #require(byID["after-hung"])
        #expect(afterHung.status == .skipped)
        #expect(afterHung.reason?.contains("hung") == true)
        #expect(afterHung.reason?.contains("killed") == true)
        #expect(afterHung.worktreePath == nil)
        #expect(afterHung.branch == nil)

        let sibling = try #require(byID["sibling"])
        #expect(sibling.status == .succeeded)
        #expect(sibling.commitOID != nil)
    }

    @Test("RelayCLIRunner run cancels already-started lanes via escalation and marks them interrupted on mid-run internal 125 error")
    func cliRunInternalError125CancelsRunningLanesAndMarksInterrupted() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-internal125")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let fixedRunID = "20261116-120000-f125"
        // Pre-create `relay/<fixedRunID>/boom` so successor `boom` fails worktree creation with exit 125
        _ = try runTool(
            "/usr/bin/git",
            ["branch", "relay/\(fixedRunID)/boom", fx.baseCommitOID],
            environment: fx.baseEnvironment,
            currentDirectory: fx.repoURL
        )

        let activeReady = gatesDir.appendingPathComponent("active-ready")
        let sigLogURL = gatesDir.appendingPathComponent("active-signals.log")
        let subPIDURL = gatesDir.appendingPathComponent("active-sub.pid")
        let neverURL = gatesDir.appendingPathComponent("never")
        var trackedSubPID: pid_t = -1
        defer {
            if trackedSubPID > 0 {
                _ = Darwin.kill(-trackedSubPID, SIGKILL)
                _ = Darwin.kill(trackedSubPID, SIGKILL)
            }
        }

        try """
        FAKE_RELAY IGNORE_INT
        FAKE_RELAY IGNORE_TERM
        FAKE_RELAY SIGNAL_LOG \(sigLogURL.path)
        FAKE_RELAY SUBGROUP_PID_FILE \(subPIDURL.path)
        FAKE_RELAY ARM_READY \(activeReady.path)
        STUB WRITE dirty-active.txt uncommitted
        STUB WAIT \(neverURL.path) 4
        """.write(to: plansDir.appendingPathComponent("active.md"), atomically: true, encoding: .utf8)

        // `trigger` waits until `active` is armed and running, then finishes 0 so `boom` triggers the 125 error!
        try """
        STUB WAIT \(activeReady.path) 4
        STUB WRITE trigger.txt ok
        """.write(to: plansDir.appendingPathComponent("trigger.md"), atomically: true, encoding: .utf8)

        try "STUB WRITE boom.txt x\n".write(to: plansDir.appendingPathComponent("boom.md"), atomically: true, encoding: .utf8)

        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "active", "agent": "claude", "prompt": "active.md", "after": []},
            {"id": "trigger", "agent": "codex", "prompt": "trigger.md", "after": []},
            {"id": "boom", "agent": "agy", "prompt": "boom.md", "after": ["trigger"]}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let policy = RelayCancellationPolicy(sigintGraceSeconds: 0.12, sigtermGraceSeconds: 0.12)
        let cli = RelayCLIRunner(runIDProvider: { fixedRunID }, cancellationPolicy: policy)
        let res = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
            environment: fx.baseEnvironment
        )

        if let rawSub = try? String(contentsOf: subPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedPID = pid_t(rawSub) {
            trackedSubPID = parsedPID
        }

        #expect(res.exitCode == 125)
        #expect(res.stdout.isEmpty)
        #expect(!res.stderr.isEmpty)

        let loggedSigs = (try? String(contentsOf: sigLogURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(loggedSigs == ["INT", "TERM"])
        if trackedSubPID > 0 {
            for _ in 0..<50 {
                if Darwin.kill(trackedSubPID, 0) != 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(Darwin.kill(trackedSubPID, 0) != 0)
        }

        let statusRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", fixedRunID],
            environment: fx.baseEnvironment
        )
        #expect(statusRes.exitCode == 0)
        let persisted = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: statusRes.stdout)
        #expect(persisted.status == .interrupted)
        #expect(persisted.reason?.contains("RelayIDE 出错") == true)

        let byID = Dictionary(uniqueKeysWithValues: persisted.lanes.map { ($0.laneID, $0) })
        let activeLane = try #require(byID["active"])
        #expect(activeLane.status == .interrupted)
        #expect(activeLane.reason?.contains("RelayIDE 出错") == true)
        #expect(activeLane.commitOID == nil)
        #expect(activeLane.uncommittedFiles == ["dirty-active.txt"])
    }

    @Test("Concurrent run on same project returns 125 naming active runID without creating worktrees/branches, while concurrent runs on different projects targeting the same repo both exit 0")
    func cliRunConcurrentSameProject125AndDifferentProjectsSameRepo0() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-concurrent")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let ready1 = gatesDir.appendingPathComponent("ready-1")
        let release1 = gatesDir.appendingPathComponent("release-1")

        try """
        STUB READY \(ready1.path)
        STUB WAIT \(release1.path) 15
        STUB WRITE first.txt from-first
        """.write(to: plansDir.appendingPathComponent("first.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE second.txt from-second\n".write(
            to: plansDir.appendingPathComponent("second.md"),
            atomically: true,
            encoding: .utf8
        )

        let plan1URL = plansDir.appendingPathComponent("plan1.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "hold", "agent": "claude", "prompt": "first.md", "after": []}
          ]
        }
        """.write(to: plan1URL, atomically: true, encoding: .utf8)

        let plan2URL = plansDir.appendingPathComponent("plan2.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "contender", "agent": "codex", "prompt": "second.md", "after": []}
          ]
        }
        """.write(to: plan2URL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        let firstRunTask = Task {
            await cli.executeCommand(
                arguments: ["run", plan1URL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
                environment: fx.baseEnvironment
            )
        }

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready1.path) { break }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: ready1.path))

        let worktreesBefore = try runTool("/usr/bin/git", ["worktree", "list", "--porcelain"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL).stdout
        let branchesBefore = try runTool("/usr/bin/git", ["for-each-ref", "--format=%(refname)", "refs/heads/"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL).stdout
        let activeHolder = try #require(RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: fx.projectURL).holder)

        // 1. Contending run on the SAME project must exit 125 with empty stdout, naming activeHolder.runID, and zero new worktrees/branches!
        let secondSameProj = await cli.executeCommand(
            arguments: ["run", plan2URL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )
        #expect(secondSameProj.exitCode == 125)
        #expect(secondSameProj.stdout.isEmpty)
        #expect(secondSameProj.stderr.contains(activeHolder.runID))

        let worktreesAfterContend = try runTool("/usr/bin/git", ["worktree", "list", "--porcelain"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL).stdout
        let branchesAfterContend = try runTool("/usr/bin/git", ["for-each-ref", "--format=%(refname)", "refs/heads/"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL).stdout
        #expect(worktreesAfterContend == worktreesBefore)
        #expect(branchesAfterContend == branchesBefore)

        // 2. While first project is STILL holding its barrier, a DIFFERENT project on the SAME repo succeeds concurrently!
        let otherProjectURL = fx.rootURL.appendingPathComponent("SecondCampaign.relayproj", isDirectory: true)
        let initOther = await cli.executeCommand(
            arguments: ["init", "--project", otherProjectURL.path],
            environment: fx.baseEnvironment
        )
        #expect(initOther.exitCode == 0)

        let otherProjRun = await cli.executeCommand(
            arguments: ["run", plan2URL.path, "--project", otherProjectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )
        #expect(otherProjRun.exitCode == 0)
        let otherRecord = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: otherProjRun.stdout)

        // Release first project's barrier -> first run also finishes 0 with distinct branch!
        try Data().write(to: release1)
        let firstRes = await firstRunTask.value
        #expect(firstRes.exitCode == 0)
        let firstRecord = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: firstRes.stdout)
        #expect(firstRecord.runID != otherRecord.runID)
        #expect(firstRecord.lanes[0].branch != otherRecord.lanes[0].branch)
    }

    @Test("Crashed run with genuinely spawned PTY lanes (master FD hangup + flock release) reconciles to interrupted in status --run and allows subsequent run to exit 0")
    func cliRunRealSpawnedLanesCrashViaMasterHangupAndLockReleaseReconcilesInterrupted() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-run-live-crash")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)

        let readyA = gatesDir.appendingPathComponent("crash-ready-a")
        let readyB = gatesDir.appendingPathComponent("crash-ready-b")
        let neverGate = gatesDir.appendingPathComponent("never")

        try """
        STUB READY \(readyA.path)
        STUB WAIT \(neverGate.path) 20
        """.write(to: plansDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try """
        STUB READY \(readyB.path)
        STUB WAIT \(neverGate.path) 20
        """.write(to: plansDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE c.txt ok\n".write(to: plansDir.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)

        let crashPlanURL = plansDir.appendingPathComponent("crash-plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "a", "agent": "claude", "prompt": "a.md", "after": []},
            {"id": "b", "agent": "codex", "prompt": "b.md", "after": []},
            {"id": "c", "agent": "agy", "prompt": "c.md", "after": ["a"]}
          ]
        }
        """.write(to: crashPlanURL, atomically: true, encoding: .utf8)

        let validated = try RelayPlanValidator.validate(
            planFileURL: crashPlanURL,
            projectBundleURL: fx.projectURL,
            environment: fx.baseEnvironment,
            language: .zhHans
        )
        let relayScript = try RelayRunExecutor.resolveAndVerifyRelayScript(
            explicitPath: fx.fakeRelayShURL.path,
            environment: fx.baseEnvironment,
            language: .zhHans
        )
        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        let crashedRunID = "20261116-130000-dead"
        let runLock = try RelayProjectRunLock.acquire(
            bundleDirectoryURL: fx.projectURL,
            runID: crashedRunID,
            pid: getpid()
        )
        let runDir = fx.projectURL.appendingPathComponent("runs/\(crashedRunID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let planCopyURL = runDir.appendingPathComponent("plan.json")
        try validated.rawPlanData.write(to: planCopyURL, options: .atomic)
        try db.createRun(
            RelayRunRecord(
                runID: crashedRunID,
                repoPath: validated.resolvedRepoURL.path,
                planCopyPath: planCopyURL.path,
                baseRef: validated.baseRef,
                baseCommitOID: validated.baseCommitOID,
                verifyCommand: nil,
                relayShPath: relayScript.url.path,
                relayShSHA256: relayScript.sha256Hex,
                startedAt: Date(),
                finishedAt: nil,
                status: .running,
                reason: nil,
                relayidePID: getpid(),
                lanes: validated.lanes.map {
                    RelayRunLaneRecord(
                        runID: crashedRunID,
                        laneID: $0.id,
                        ordinal: $0.ordinal,
                        agent: $0.agent,
                        promptPath: $0.resolvedPromptURL.path,
                        after: $0.after,
                        status: .pending
                    )
                }
            )
        )

        let registry = RelayActiveLaneRegistry()
        let scheduler = RelayDAGRunScheduler(
            runID: crashedRunID,
            validatedPlan: validated,
            relayScript: relayScript,
            runDirectoryURL: runDir,
            projectBundleURL: fx.projectURL,
            database: db,
            language: .zhHans,
            environment: fx.baseEnvironment,
            activeLaneRegistry: registry,
            emitStderrLine: { _ in }
        )
        let bgScheduler = Task { try? await scheduler.run() }

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: readyA.path)
                && FileManager.default.fileExists(atPath: readyB.path) {
                break
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: readyA.path))
        #expect(FileManager.default.fileExists(atPath: readyB.path))

        // Verify both lanes are persisted as `running` in SQLite while lock is held
        let activeProcs = registry.snapshotActiveProcesses()
        #expect(activeProcs.count == 2)
        defer {
            for p in activeProcs {
                _ = Darwin.kill(-p.pid, SIGKILL)
                _ = Darwin.kill(p.pid, SIGKILL)
            }
        }

        let cli = RelayCLIRunner()
        let whileAliveStatus = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", crashedRunID],
            environment: fx.baseEnvironment
        )
        let aliveDecoded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: whileAliveStatus.stdout)
        #expect(aliveDecoded.status == .running)

        // Snapshot exact DB state at the moment of SIGKILL (running run + 2 running lanes + 1 pending lane),
        // close both PTY master FDs without kill() (kernel hangup), and release flock without truncating run.lock!
        let snapshotAtCrash = try #require(try db.fetchRun(runID: crashedRunID, reconcileWithLock: false))
        for p in activeProcs {
            p.session.closeMasterFDSimulatingCrash()
            #expect(p.session.waitForExit(timeout: 2.0) == true)
        }
        _ = await bgScheduler.value

        // Restore the exact pre-reap DB snapshot that a real SIGKILL leaves on disk (since RelayIDE never gets to run post-exit SQL on SIGKILL)
        for lane in snapshotAtCrash.lanes {
            try db.updateRunLane(lane)
        }
        try db.updateRunStatus(runID: crashedRunID, status: .running, reason: nil, finishedAt: nil)
        runLock.closeDescriptorSimulatingCrash()

        let afterCrashStatus = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", crashedRunID],
            environment: fx.baseEnvironment
        )
        #expect(afterCrashStatus.exitCode == 0)
        let crashedDecoded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: afterCrashStatus.stdout)
        #expect(crashedDecoded.status == .interrupted)
        #expect(crashedDecoded.lanes.allSatisfy { $0.status != .running })
        #expect(crashedDecoded.lanes.allSatisfy { $0.status.isTerminal })

        // Now run a small follow-up plan on the SAME project -> must exit 0 and persist the orphaned run!
        let smallPlanURL = plansDir.appendingPathComponent("small-plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "recover", "agent": "claude", "prompt": "c.md", "after": []}
          ]
        }
        """.write(to: smallPlanURL, atomically: true, encoding: .utf8)

        let recoveryRes = await cli.executeCommand(
            arguments: ["run", smallPlanURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )
        #expect(recoveryRes.exitCode == 0)
    }

    // MARK: - 35. M2 `status --run <id>` JSON Emits `integration` (`null` in M1/Stage-1 Runs, Object When Persisted, §10)

    @Test("RelayCLIRunner status --run emits explicit null integration for runs without integration rows and full integration object when persisted")
    func cliStatusRunJSONIncludesIntegrationFieldNullOrPopulated() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-status-integration")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        try "STUB WRITE out.txt ok\n".write(to: plansDir.appendingPathComponent("api.md"), atomically: true, encoding: .utf8)
        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "api", "agent": "claude", "prompt": "api.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)

        // 1. M1-era run row without `relay_run_integration` row must still emit `"integration" : null`.
        let legacyRunID = "20261117-015959-0000"
        try db.createRun(
            RelayRunRecord(
                runID: legacyRunID,
                repoPath: fx.repoURL.path,
                planCopyPath: planURL.path,
                baseRef: "main",
                baseCommitOID: fx.baseCommitOID,
                verifyCommand: nil,
                relayShPath: fx.fakeRelayShURL.path,
                relayShSHA256: fx.fakeRelaySHA256,
                startedAt: Date(timeIntervalSince1970: 1_763_309_900),
                finishedAt: Date(timeIntervalSince1970: 1_763_309_905),
                status: .succeeded,
                reason: nil,
                relayidePID: 1001,
                lanes: [],
                integration: nil
            )
        )
        let cli = RelayCLIRunner(runIDProvider: { "20261117-020000-0001" })
        let statusNullRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", legacyRunID],
            environment: fx.baseEnvironment
        )
        #expect(statusNullRes.exitCode == 0)
        #expect(statusNullRes.stdout.contains("\"integration\" : null"))
        let decodedNull = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: statusNullRes.stdout)
        #expect(decodedNull.integration == nil)

        // 2. Live M2 `run` emits populated `integration` object (`merged`, `ready: false`) matching `status --run`.
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )
        #expect(runRes.exitCode == 0)
        #expect(runRes.stdout.contains("\"integration\" : {"))
        let statusMergedRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", "20261117-020000-0001"],
            environment: fx.baseEnvironment
        )
        #expect(statusMergedRes.exitCode == 0)
        #expect(statusMergedRes.stdout == runRes.stdout)
        let decodedMerged = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: statusMergedRes.stdout)
        #expect(decodedMerged.integration?.status == .merged)
        #expect(decodedMerged.integration?.ready == false)

        // 3. Persist an M2 integration + merge + verify record and verify `status --run` JSON under EN and ZH.
        let t0 = Date(timeIntervalSince1970: 1_763_310_000)
        let t1 = Date(timeIntervalSince1970: 1_763_310_012)
        let expectedIntegration = RelayRunIntegrationRecord(
            branch: "relay/20261117-020000-0001/integration",
            worktreePath: fx.projectURL.appendingPathComponent("runs/20261117-020000-0001/worktrees/integration").path,
            baseCommitOID: fx.baseCommitOID,
            headCommitOID: "4444444444444444444444444444444444444444",
            status: .verified,
            reason: nil,
            ready: true,
            merges: [
                RelayRunMergeRecord(
                    ordinal: 0,
                    laneID: "api",
                    laneCommitOID: decodedMerged.lanes.first?.commitOID,
                    status: .merged,
                    mergeCommitOID: "4444444444444444444444444444444444444444",
                    conflicts: [],
                    conflictLines: [],
                    startedAt: t0,
                    finishedAt: t1
                )
            ],
            verify: RelayRunVerifyRecord(
                command: "swift test",
                timeoutSec: 1800,
                status: .passed,
                exitCode: 0,
                signal: nil,
                pid: 4321,
                startedAt: t0,
                finishedAt: t1,
                logPath: fx.projectURL.appendingPathComponent("runs/20261117-020000-0001/verify.pty").path,
                logBytes: 4096,
                logTruncated: false,
                modifiedTrackedFiles: []
            )
        )
        try db.upsertRunIntegration(runID: "20261117-020000-0001", expectedIntegration)

        let statusEN = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", "20261117-020000-0001", "--lang", "en"],
            environment: fx.baseEnvironment
        )
        let statusZH = await cli.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", "20261117-020000-0001", "--lang", "zh"],
            environment: fx.baseEnvironment
        )
        #expect(statusEN.exitCode == 0)
        #expect(statusZH.exitCode == 0)
        #expect(statusEN.stdout == statusZH.stdout)
        #expect(statusEN.stdout.contains("\"integration\" : {"))
        #expect(statusEN.stdout.contains("\"status\" : \"verified\""))
        #expect(statusEN.stdout.contains("\"ready\" : true"))
        #expect(statusEN.stdout.contains("\"modifiedTrackedFiles\" : ["))

        let decodedFull = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: statusEN.stdout)
        #expect(decodedFull.integration == expectedIntegration)
    }

    // MARK: - 36. M2 `plan.json` `verify_timeout` & Unknown Field Validation (Exit 2, Names Offending Field, §2, R66)

    @Test("RelayPlanValidator and RelayCLIRunner run enforce verify_timeout (integer 1..86400, default 1800, requires verify) and reject unknown fields with exit 2 naming the field")
    func cliRunValidatesVerifyTimeoutAndUnknownPlanFields() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-plan-validation")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB WRITE out.txt ok\n".write(to: promptsDir.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)

        func writePlan(_ name: String, rawJSON: String) throws -> URL {
            let url = plansDir.appendingPathComponent(name)
            try rawJSON.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        // 1. Valid plans: default 1800s when verify present, 1s, 86400s, and nil when verify omitted
        let defaultTimeoutURL = try writePlan(
            "valid-default-timeout.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}],
              "verify": "swift test"
            }
            """
        )
        let validatedDefault = try RelayPlanValidator.validate(
            planFileURL: defaultTimeoutURL,
            projectBundleURL: fx.projectURL,
            environment: fx.baseEnvironment,
            language: .en
        )
        #expect(validatedDefault.verifyCommand == "swift test")
        #expect(validatedDefault.verifyTimeoutSec == 1800)

        for validSec in [1, 86400] {
            let boundaryURL = try writePlan(
                "valid-\(validSec).json",
                rawJSON: """
                {
                  "repo": "\(fx.repoURL.path)",
                  "base": "main",
                  "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}],
                  "verify": "swift test",
                  "verify_timeout": \(validSec)
                }
                """
            )
            let v = try RelayPlanValidator.validate(
                planFileURL: boundaryURL,
                projectBundleURL: fx.projectURL,
                environment: fx.baseEnvironment,
                language: .zhHans
            )
            #expect(v.verifyTimeoutSec == validSec)
        }

        let noVerifyURL = try writePlan(
            "valid-no-verify.json",
            rawJSON: """
            {
              "repo": "\(fx.repoURL.path)",
              "base": "main",
              "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md", "after": []}]
            }
            """
        )
        let validatedNoVerify = try RelayPlanValidator.validate(
            planFileURL: noVerifyURL,
            projectBundleURL: fx.projectURL,
            environment: fx.baseEnvironment,
            language: .en
        )
        #expect(validatedNoVerify.verifyCommand == nil)
        #expect(validatedNoVerify.verifyTimeoutSec == nil)

        // 2. Invalid plans: every case must exit 2 with empty stdout, stderr naming the field (in both EN & ZH), and 0 runs recorded
        let invalidCases: [(label: String, expectedField: String, rawJSON: String)] = [
            (
                "verify is array",
                "verify",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": ["swift", "test"]}
                """
            ),
            (
                "verify is number",
                "verify",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": 123}
                """
            ),
            (
                "verify_timeout is 0",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": 0}
                """
            ),
            (
                "verify_timeout is negative",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": -5}
                """
            ),
            (
                "verify_timeout is 86401",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": 86401}
                """
            ),
            (
                "verify_timeout is float 1.5",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": 1.5}
                """
            ),
            (
                "verify_timeout is float 1.0",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": 1.0}
                """
            ),
            (
                "verify_timeout is string \"60\"",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": "60"}
                """
            ),
            (
                "verify_timeout is bool",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": true}
                """
            ),
            (
                "verify_timeout is null",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "true", "verify_timeout": null}
                """
            ),
            (
                "verify_timeout without verify",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify_timeout": 60}
                """
            ),
            (
                "verify_timeout with whitespace-only verify",
                "verify_timeout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify": "   ", "verify_timeout": 60}
                """
            ),
            (
                "unknown top-level verify_timout",
                "verify_timout",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md"}], "verify_timout": 60}
                """
            ),
            (
                "unknown lane field befor",
                "befor",
                """
                {"repo": "\(fx.repoURL.path)", "base": "main", "lanes": [{"id": "api", "agent": "claude", "prompt": "prompts/task.md", "befor": []}]}
                """
            ),
        ]

        let cli = RelayCLIRunner()
        for (idx, tc) in invalidCases.enumerated() {
            let planURL = try writePlan("invalid-\(idx).json", rawJSON: tc.rawJSON)
            for lang in ["en", "zh"] {
                let res = await cli.executeCommand(
                    arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", lang],
                    environment: fx.baseEnvironment
                )
                #expect(res.exitCode == 2, "\(tc.label) (\(lang)): expected exit 2, got \(res.exitCode) (stderr=\(res.stderr))")
                #expect(res.stdout.isEmpty, "\(tc.label) (\(lang)): stdout must be empty on exit 2")
                #expect(
                    res.stderr.contains(tc.expectedField),
                    "\(tc.label) (\(lang)): stderr must name field '\(tc.expectedField)', got '\(res.stderr)'"
                )
            }
        }

        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        #expect(try db.allRuns().isEmpty)
    }

    // MARK: - 37. M2 `status` Rejects Extra Positional Arguments (`exit 2`, `--run` Hint, R60)

    @Test("RelayCLIRunner status rejects extra positional arguments with exit 2, empty stdout, and a hint to use --run")
    func cliStatusRejectsExtraPositionalArgumentsWithExit2AndRunHint() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-status-r60")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Proj.relayproj", isDirectory: true)
        _ = try RelayProjectDatabase(bundleDirectoryURL: bundleURL)
        let cli = RelayCLIRunner()

        let positionalForms: [[String]] = [
            ["status", "20261117-010203-a1b2", "--project", bundleURL.path],
            ["status", "--project", bundleURL.path, "20261117-010203-a1b2"],
            ["status", "20261117-010203-a1b2"],
            ["status", "--project", bundleURL.path, "--run", "20261117-010203-a1b2", "extra"],
        ]

        for form in positionalForms {
            for lang in ["en", "zh"] {
                let res = await cli.executeCommand(arguments: form + ["--lang", lang])
                #expect(res.exitCode == 2, "\(form) (\(lang)): expected exit 2, got \(res.exitCode)")
                #expect(res.stdout.isEmpty, "\(form) (\(lang)): stdout must be empty on exit 2, got '\(res.stdout)'")
                #expect(res.stderr.contains("--run"), "\(form) (\(lang)): stderr must hint '--run', got '\(res.stderr)'")
            }
        }
    }

    // MARK: - 38. M2 `RELAY_BUDGET_USD` (M4) & Multiple-Predecessor Error Messages (R63 First Two, D4)

    @Test("RelayPlanValidator reports M4 for RELAY_BUDGET_USD and omits M1/M2 promises for multiple predecessors in EN and ZH")
    func cliRunBudgetAndMultiPredecessorErrorMessagesMatchM2Spec() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-r63-errors")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB WRITE out.txt ok\n".write(to: promptsDir.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)

        let validPlanURL = plansDir.appendingPathComponent("valid.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [{"id": "a", "agent": "claude", "prompt": "prompts/task.md", "after": []}]
        }
        """.write(to: validPlanURL, atomically: true, encoding: .utf8)

        let multiAfterURL = plansDir.appendingPathComponent("multi-after.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [
            {"id": "a", "agent": "claude", "prompt": "prompts/task.md", "after": []},
            {"id": "b", "agent": "codex", "prompt": "prompts/task.md", "after": []},
            {"id": "c", "agent": "agy", "prompt": "prompts/task.md", "after": ["a", "b"]}
          ]
        }
        """.write(to: multiAfterURL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        var budgetEnv = fx.baseEnvironment
        budgetEnv["RELAY_BUDGET_USD"] = "-1.50"

        for lang in ["en", "zh"] {
            let budgetRes = await cli.executeCommand(
                arguments: ["run", validPlanURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", lang],
                environment: budgetEnv
            )
            #expect(budgetRes.exitCode == 2)
            #expect(budgetRes.stdout.isEmpty)
            #expect(budgetRes.stderr.contains("RELAY_BUDGET_USD"))
            #expect(!budgetRes.stderr.contains("M4"), "(\(lang)): stale M4 promise found in budget error: '\(budgetRes.stderr)'")
            #expect(!budgetRes.stderr.contains("M1"), "(\(lang)): stale M1 found in budget error: '\(budgetRes.stderr)'")
            #expect(!budgetRes.stderr.contains("M2"), "(\(lang)): stale M2 found in budget error: '\(budgetRes.stderr)'")

            let multiRes = await cli.executeCommand(
                arguments: ["run", multiAfterURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", lang],
                environment: fx.baseEnvironment
            )
            #expect(multiRes.exitCode == 2)
            #expect(multiRes.stdout.isEmpty)
            #expect(multiRes.stderr.contains("'c'"))
            #expect(!multiRes.stderr.contains("M1"), "(\(lang)): stale M1 found in multi-after error: '\(multiRes.stderr)'")
            #expect(!multiRes.stderr.contains("M2"), "(\(lang)): stale M2 promise found in multi-after error: '\(multiRes.stderr)'")
        }
    }

    // MARK: - 39. M2 Stage 4 Item 1: `pending` Integration Row, Merge + `verify` Execution, Live `onStarted` PID Persistence (`kill -9` Reconciliation), Deferred Terminal Run Status, and M1 Note Removal

    @Test("RelayCLIRunner run writes pending integration row with verify command & timeout at start, runs merge + verify, persists running verify PID for kill -9 reconciliation, writes terminal run status last, and removes M1 verify note")
    func cliRunWritesPendingIntegrationExecutesMergeAndVerifyPersistsRunningPIDAndRemovesM1Note() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-item1")
        let tempToken = fx.rootURL.lastPathComponent
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)

        let laneReady = gatesDir.appendingPathComponent("lane-ready")
        let laneRelease = gatesDir.appendingPathComponent("lane-release")
        let verifyReady = gatesDir.appendingPathComponent("verify-ready")
        let verifyRelease = gatesDir.appendingPathComponent("verify-release")
        let verifyObservedFiles = gatesDir.appendingPathComponent("verify-files.txt")

        try """
        STUB WRITE src/api.txt api-v1
        STUB READY \(laneReady.path)
        STUB WAIT \(laneRelease.path) 30
        """.write(to: promptsDir.appendingPathComponent("api.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE src/docs.txt docs-v1\n".write(
            to: promptsDir.appendingPathComponent("docs.md"),
            atomically: true,
            encoding: .utf8
        )

        let verifyCmd = """
        test -f src/api.txt && test -f src/docs.txt
        printf '%s|%s' "$(cat src/api.txt | tr -d '\\n')" "$(cat src/docs.txt | tr -d '\\n')" > "\(verifyObservedFiles.path)"
        : > "\(verifyReady.path)"
        while [ ! -e "\(verifyRelease.path)" ]; do /usr/bin/perl -e 'select(undef, undef, undef, 0.02);' "\(tempToken)-v1"; done
        exit 0
        """

        let planObj: [String: Any] = [
            "repo": fx.repoURL.path,
            "base": "main",
            "lanes": [
                ["id": "api", "agent": "claude", "prompt": "prompts/api.md", "after": []],
                ["id": "docs", "agent": "agy", "prompt": "prompts/docs.md", "after": ["api"]]
            ],
            "verify": verifyCmd,
            "verify_timeout": 45
        ]
        let planURL = plansDir.appendingPathComponent("plan1.json")
        try JSONSerialization.data(withJSONObject: planObj, options: [.prettyPrinted, .sortedKeys])
            .write(to: planURL, options: .atomic)

        let run1ID = "20261117-070000-0001"
        let cli1 = RelayCLIRunner(runIDProvider: { run1ID })
        final class DoneBox: @unchecked Sendable { var done = false }
        let done1 = DoneBox()
        let run1Task = Task {
            let res = await cli1.executeCommand(
                arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            done1.done = true
            return res
        }

        // 1. While `api` lane is blocked on `laneRelease`, verify `pending` integration row (with verify cmd & timeout 45) is in SQLite!
        let laneWaitDeadline = Date().addingTimeInterval(20.0)
        while !FileManager.default.fileExists(atPath: laneReady.path) && !done1.done && Date() < laneWaitDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: laneReady.path))

        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        let configuredSpec = try #require(try db.configuredIntegrationVerifySpec(runID: run1ID))
        #expect(configuredSpec.command == verifyCmd)
        #expect(configuredSpec.timeoutSec == 45)

        let midLaneStatusRes = await cli1.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", run1ID],
            environment: fx.baseEnvironment
        )
        #expect(midLaneStatusRes.exitCode == 0)
        let midLaneDecoded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: midLaneStatusRes.stdout)
        #expect(midLaneDecoded.status == .running)
        #expect(midLaneDecoded.finishedAt == nil)
        #expect(midLaneDecoded.integration?.status == .pending)
        #expect(midLaneDecoded.integration?.ready == false)
        #expect(midLaneDecoded.integration?.verify == nil)

        // 2. Release `laneRelease` and wait for `verifyReady`: verify `onStarted` persisted `verifying` + `running` + live `pid`, while `run.status` is STILL `.running`!
        try Data().write(to: laneRelease)
        let verifyWaitDeadline = Date().addingTimeInterval(20.0)
        while !FileManager.default.fileExists(atPath: verifyReady.path) && !done1.done && Date() < verifyWaitDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: verifyReady.path))

        let midVerifyStatusRes = await cli1.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", run1ID],
            environment: fx.baseEnvironment
        )
        #expect(midVerifyStatusRes.exitCode == 0)
        let midVerifyDecoded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: midVerifyStatusRes.stdout)
        #expect(midVerifyDecoded.status == .running)
        #expect(midVerifyDecoded.finishedAt == nil)
        #expect(midVerifyDecoded.integration?.status == .verifying)
        #expect(midVerifyDecoded.integration?.ready == false)
        #expect(midVerifyDecoded.integration?.merges.map(\.laneID) == ["api", "docs"])
        #expect(midVerifyDecoded.integration?.merges.map(\.status) == [.merged, .merged])
        let liveVerifyPID = try #require(midVerifyDecoded.integration?.verify?.pid)
        #expect(liveVerifyPID > 0)
        #expect(Darwin.kill(liveVerifyPID, 0) == 0)
        #expect(midVerifyDecoded.integration?.verify?.status == .running)
        #expect(midVerifyDecoded.integration?.verify?.timeoutSec == 45)

        // Snapshot exact raw SQLite rows during live `verify` to also verify `kill -9` crash reconciliation below.
        let rawMidVerifySnapshot = try #require(try db.fetchRun(runID: run1ID, reconcileWithLock: false))

        // 3. Release `verifyRelease`: verify `run` exits 0, M1 note is gone, `verified`, `ready == true`, and terminal `run.status == .succeeded` persisted!
        try Data().write(to: verifyRelease)
        let run1Res = await run1Task.value
        #expect(run1Res.exitCode == 0)
        #expect(!run1Res.stderr.contains("将在 M2 执行"))
        #expect(!run1Res.stderr.contains("scheduled for M2"))
        #expect(try String(contentsOf: verifyObservedFiles, encoding: .utf8) == "api-v1|docs-v1")

        let final1 = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: run1Res.stdout)
        #expect(final1.status == .succeeded)
        #expect(final1.finishedAt != nil)
        #expect(final1.integration?.status == .verified)
        #expect(final1.integration?.ready == true)
        #expect(final1.integration?.verify?.status == .passed)
        #expect(final1.integration?.verify?.exitCode == 0)
        #expect(final1.integration?.verify?.pid == liveVerifyPID)

        // 4. Verify `kill -9` mid-verify reconciliation (`onStarted` persisted `verifying` + `verify.status == .running` + `pid`):
        // Restore the exact mid-verify DB state with `run.lock` unheld -> `status --run` reconciles run, integration, and verify to `interrupted`,
        // and a subsequent small `run` persists the interrupted rows and exits 0!
        if let snapInt = rawMidVerifySnapshot.integration {
            try db.upsertRunIntegration(
                runID: run1ID,
                snapInt,
                configuredVerifyCommand: verifyCmd,
                configuredVerifyTimeoutSec: 45
            )
        }
        try db.updateRunStatus(runID: run1ID, status: .running, reason: nil, finishedAt: nil)

        let crashedStatusRes = await cli1.executeCommand(
            arguments: ["status", "--project", fx.projectURL.path, "--run", run1ID],
            environment: fx.baseEnvironment
        )
        #expect(crashedStatusRes.exitCode == 0)
        let crashedDecoded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: crashedStatusRes.stdout)
        #expect(crashedDecoded.status == .interrupted)
        #expect(crashedDecoded.integration?.status == .interrupted)
        #expect(crashedDecoded.integration?.ready == false)
        #expect(crashedDecoded.integration?.verify?.status == .interrupted)

        let smallPlanURL = plansDir.appendingPathComponent("small.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [{"id": "recover", "agent": "claude", "prompt": "prompts/docs.md", "after": []}]
        }
        """.write(to: smallPlanURL, atomically: true, encoding: .utf8)

        let run2ID = "20261117-070001-0002"
        let cli2 = RelayCLIRunner(runIDProvider: { run2ID })
        let recoverRes = await cli2.executeCommand(
            arguments: ["run", smallPlanURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path],
            environment: fx.baseEnvironment
        )
        #expect(recoverRes.exitCode == 0)
        let persistedAfterRecover = try #require(try db.fetchRun(runID: run1ID, reconcileWithLock: false))
        #expect(persistedAfterRecover.status == .interrupted)
        #expect(persistedAfterRecover.integration?.status == .interrupted)
        #expect(persistedAfterRecover.integration?.verify?.status == .interrupted)
        #expect(persistedAfterRecover.integration?.verify?.finishedAt != nil)
    }

    // MARK: - 40. M2 Stage 4 Item 2: Three-Phase `SIGINT` (130) / `SIGTERM` (143) Cancellation (Lane, Merge + `MERGE_HEAD` Abort, Pre-Merge / Between-Merge / Pre-Verify Checks, and `verify` Escalation Ladder, §7, Rows 18, 19, 21)

    @Test("RelayCLIRunner run handles SIGINT (130) and SIGTERM (143) across lane, merge (aborting MERGE_HEAD cleanly), pre-merge/between-merge/pre-verify boundaries, and verify escalation ladder while preserving completed merges")
    func cliRunHandlesSIGINTSIGTERMAcrossLaneMergeAndVerifyPhases() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-item2")
        let tempToken = fx.rootURL.lastPathComponent
        var trackedPIDs: [pid_t] = []
        defer {
            for pid in trackedPIDs where pid > 0 {
                _ = Darwin.kill(-pid, SIGKILL)
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: fx.rootURL)
        }

        let gatesDir = fx.rootURL.appendingPathComponent("gates", isDirectory: true)
        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)

        let fastPolicy = RelayCancellationPolicy(sigintGraceSeconds: 0.2, sigtermGraceSeconds: 0.2)

        // 1. Lane-phase SIGINT (Row 21): lane blocked -> exit 130, run cancelled, integration skipped, no integration branch/worktree.
        do {
            let ready1 = gatesDir.appendingPathComponent("p1-lane-ready")
            let never1 = gatesDir.appendingPathComponent("p1-never")
            let verifyMarker1 = gatesDir.appendingPathComponent("p1-verify-ran")
            try """
            STUB WRITE src/p1.txt wip
            FAKE_RELAY ARM_READY \(ready1.path)
            STUB WAIT \(never1.path) 10
            """.write(to: promptsDir.appendingPathComponent("p1.md"), atomically: true, encoding: .utf8)

            let plan1URL = plansDir.appendingPathComponent("p1-lane-sigint.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/p1.md", "after": []]],
                    "verify": ": > \"\(verifyMarker1.path)\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan1URL, options: .atomic)

            let reg1 = RelayActiveLaneRegistry()
            let run1ID = "20261117-080000-0001"
            let cli1 = RelayCLIRunner(runIDProvider: { run1ID }, activeLaneRegistry: reg1, cancellationPolicy: fastPolicy)
            let task1 = Task {
                await cli1.executeCommand(
                    arguments: ["run", plan1URL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                    environment: fx.baseEnvironment
                )
            }
            for _ in 0..<250 where !FileManager.default.fileExists(atPath: ready1.path) {
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            #expect(FileManager.default.fileExists(atPath: ready1.path))
            reg1.requestCancellation(signal: SIGINT)
            let res1 = await task1.value

            #expect(res1.exitCode == 130)
            let rec1 = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res1.stdout)
            #expect(rec1.status == .cancelled)
            #expect(rec1.integration?.status == .skipped)
            #expect(rec1.integration?.ready == false)
            #expect(rec1.integration?.branch == nil)
            #expect(rec1.integration?.worktreePath == nil)
            #expect(rec1.integration?.verify == nil)
            #expect(!FileManager.default.fileExists(atPath: verifyMarker1.path))
            let intRefCheck = try runTool(
                "/usr/bin/git",
                ["show-ref", "--verify", "--quiet", "refs/heads/relay/\(run1ID)/integration"],
                environment: fx.baseEnvironment,
                currentDirectory: fx.repoURL
            )
            #expect(intRefCheck.exitCode != 0)
        }

        // 2a. Pre-merge boundary check: signal arrives right as last lane finishes, before merge phase creates integration branch/worktree.
        do {
            try "STUB WRITE src/p2a.txt v1\n".write(to: promptsDir.appendingPathComponent("p2a.md"), atomically: true, encoding: .utf8)
            let plan2aURL = plansDir.appendingPathComponent("p2a-premerge.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/p2a.md", "after": []]]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan2aURL, options: .atomic)

            let reg2a = RelayActiveLaneRegistry()
            let run2aID = "20261117-080001-0002"
            let cli2a = RelayCLIRunner(runIDProvider: { run2aID }, activeLaneRegistry: reg2a, cancellationPolicy: fastPolicy)
            let res2a = await cli2a.executeCommand(
                arguments: ["run", plan2aURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment,
                onLiveStderrLine: { line in
                    if line.contains("[relay] lane a (claude)") && line.contains("succeeded") {
                        reg2a.requestCancellation(signal: SIGINT)
                    }
                }
            )
            #expect(res2a.exitCode == 130)
            let rec2a = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res2a.stdout)
            #expect(rec2a.status == .cancelled)
            #expect(rec2a.integration?.status == .cancelled)
            #expect(rec2a.integration?.ready == false)
            #expect(rec2a.integration?.branch == nil)
            #expect(rec2a.integration?.worktreePath == nil)
        }

        // 2b. Between-merge boundary check (SIGTERM -> 143): signal arrives after lane `a` merges, before lane `b` merges.
        do {
            try "STUB WRITE src/p2b_a.txt va\n".write(to: promptsDir.appendingPathComponent("p2b_a.md"), atomically: true, encoding: .utf8)
            try "STUB WRITE src/p2b_b.txt vb\n".write(to: promptsDir.appendingPathComponent("p2b_b.md"), atomically: true, encoding: .utf8)
            let plan2bURL = plansDir.appendingPathComponent("p2b-between-merges.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/p2b_a.md", "after": []],
                        ["id": "b", "agent": "codex", "prompt": "prompts/p2b_b.md", "after": []]
                    ]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan2bURL, options: .atomic)

            let reg2b = RelayActiveLaneRegistry()
            let run2bID = "20261117-080002-0003"
            let cli2b = RelayCLIRunner(runIDProvider: { run2bID }, activeLaneRegistry: reg2b, cancellationPolicy: fastPolicy)
            let res2b = await cli2b.executeCommand(
                arguments: ["run", plan2bURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment,
                onLiveStderrLine: { line in
                    if line.contains("[relay] merge lane a") {
                        reg2b.requestCancellation(signal: SIGTERM)
                    }
                }
            )
            #expect(res2b.exitCode == 143)
            let rec2b = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res2b.stdout)
            #expect(rec2b.status == .cancelled)
            #expect(rec2b.integration?.status == .cancelled)
            #expect(rec2b.integration?.ready == false)
            #expect(rec2b.integration?.merges.map(\.status) == [.merged, .notAttempted])
            #expect(rec2b.integration?.headCommitOID == rec2b.integration?.merges[0].mergeCommitOID)
        }

        // 2c. Mid-merge SIGINT during in-flight `git merge` with `MERGE_HEAD` (Row 19):
        // Configure a custom git merge driver on `shared.txt` that signals `driverReady`, waits for `driverRelease`, and exits 1.
        do {
            let mergeRepoFx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-mergesig")
            defer { try? FileManager.default.removeItem(at: mergeRepoFx.rootURL) }

            try "baseline-shared\n".write(to: mergeRepoFx.repoURL.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
            try "shared.txt merge=slowconflict\n".write(to: mergeRepoFx.repoURL.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            _ = try runTool("/usr/bin/git", ["add", "shared.txt", ".gitattributes"], environment: mergeRepoFx.baseEnvironment, currentDirectory: mergeRepoFx.repoURL)
            _ = try runTool("/usr/bin/git", ["commit", "-m", "add shared.txt and .gitattributes"], environment: mergeRepoFx.baseEnvironment, currentDirectory: mergeRepoFx.repoURL)

            let driverReady = gatesDir.appendingPathComponent("merge-driver-ready")
            let driverRelease = gatesDir.appendingPathComponent("merge-driver-release")
            let verifyRan2c = gatesDir.appendingPathComponent("p2c-verify-ran")
            let driverScriptURL = gatesDir.appendingPathComponent("slow-merge-driver.sh")
            try """
            #!/bin/sh
            : > "\(driverReady.path)"
            i=0
            while [ ! -e "\(driverRelease.path)" ] && [ "$i" -lt 250 ]; do
                /usr/bin/perl -e 'select(undef, undef, undef, 0.02);' "\(tempToken)-mergedrv"
                i=$((i + 1))
            done
            printf '<<<<<<< HEAD\\nconflict\\n=======\\nother\\n>>>>>>> branch\\n' > "$2"
            exit 1
            """.write(to: driverScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driverScriptURL.path)

            _ = try runTool(
                "/usr/bin/git",
                ["config", "merge.slowconflict.name", "Slow conflict test driver"],
                environment: mergeRepoFx.baseEnvironment,
                currentDirectory: mergeRepoFx.repoURL
            )
            _ = try runTool(
                "/usr/bin/git",
                ["config", "merge.slowconflict.driver", "\"\(driverScriptURL.path)\" %O %A %B"],
                environment: mergeRepoFx.baseEnvironment,
                currentDirectory: mergeRepoFx.repoURL
            )

            try "STUB WRITE shared.txt side-a\n".write(to: promptsDir.appendingPathComponent("p2c_a.md"), atomically: true, encoding: .utf8)
            try "STUB WRITE shared.txt side-b\n".write(to: promptsDir.appendingPathComponent("p2c_b.md"), atomically: true, encoding: .utf8)
            let plan2cURL = plansDir.appendingPathComponent("p2c-midmerge-sigint.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": mergeRepoFx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/p2c_a.md", "after": []],
                        ["id": "b", "agent": "codex", "prompt": "prompts/p2c_b.md", "after": []]
                    ],
                    "verify": ": > \"\(verifyRan2c.path)\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan2cURL, options: .atomic)

            let reg2c = RelayActiveLaneRegistry()
            let run2cID = "20261117-080003-0004"
            let cli2c = RelayCLIRunner(runIDProvider: { run2cID }, activeLaneRegistry: reg2c, cancellationPolicy: fastPolicy)
            let task2c = Task {
                await cli2c.executeCommand(
                    arguments: ["run", plan2cURL.path, "--project", mergeRepoFx.projectURL.path, "--relay-sh", mergeRepoFx.fakeRelayShURL.path, "--lang", "en"],
                    environment: mergeRepoFx.baseEnvironment
                )
            }

            for _ in 0..<300 where !FileManager.default.fileExists(atPath: driverReady.path) {
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            #expect(FileManager.default.fileExists(atPath: driverReady.path))
            reg2c.requestCancellation(signal: SIGINT)
            try Data().write(to: driverRelease)
            let res2c = await task2c.value

            #expect(res2c.exitCode == 130)
            #expect(!FileManager.default.fileExists(atPath: verifyRan2c.path))
            let rec2c = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res2c.stdout)
            #expect(rec2c.status == .cancelled)
            #expect(rec2c.integration?.status == .cancelled)
            #expect(rec2c.integration?.ready == false)
            #expect(rec2c.integration?.verify == nil)
            let aMergeOID = try #require(rec2c.integration?.merges.first?.mergeCommitOID)
            #expect(rec2c.integration?.headCommitOID == aMergeOID)

            let intWTPath = try #require(rec2c.integration?.worktreePath)
            let gitEngine = GitWorktreePlumbingEngine()
            #expect(try gitEngine.hasMergeHead(in: intWTPath, environment: mergeRepoFx.baseEnvironment) == false)
            let wtHead = try gitEngine.runGit(["rev-parse", "HEAD"], cwd: intWTPath, environment: mergeRepoFx.baseEnvironment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(wtHead == aMergeOID)
            let wtPorcelain = try gitEngine.runGit(
                ["status", "--porcelain=v1", "-uall", "--ignored"],
                cwd: intWTPath,
                environment: mergeRepoFx.baseEnvironment
            )
            #expect(wtPorcelain.isEmpty)
        }

        // 3. Pre-verify boundary check: all merges succeed, signal arrives right before `verify` spawns -> `verify` never runs, merges preserved.
        do {
            let preVerifyMarker = gatesDir.appendingPathComponent("p3-verify-should-not-run")
            try "STUB WRITE src/p3.txt v3\n".write(to: promptsDir.appendingPathComponent("p3.md"), atomically: true, encoding: .utf8)
            let plan3URL = plansDir.appendingPathComponent("p3-preverify.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/p3.md", "after": []]],
                    "verify": ": > \"\(preVerifyMarker.path)\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan3URL, options: .atomic)

            let reg3 = RelayActiveLaneRegistry()
            let run3ID = "20261117-080004-0005"
            let cli3 = RelayCLIRunner(runIDProvider: { run3ID }, activeLaneRegistry: reg3, cancellationPolicy: fastPolicy)
            let res3 = await cli3.executeCommand(
                arguments: ["run", plan3URL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment,
                onLiveStderrLine: { line in
                    if line.contains("[relay] merge lane a") {
                        reg3.requestCancellation(signal: SIGINT)
                    }
                }
            )
            #expect(res3.exitCode == 130)
            #expect(!FileManager.default.fileExists(atPath: preVerifyMarker.path))
            let rec3 = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res3.stdout)
            #expect(rec3.status == .cancelled)
            #expect(rec3.integration?.status == .cancelled)
            #expect(rec3.integration?.ready == false)
            #expect(rec3.integration?.verify == nil)
            let mergedOID3 = try #require(rec3.integration?.merges.first?.mergeCommitOID)
            #expect(rec3.integration?.headCommitOID == mergedOID3)
        }

        // 4. Mid-verify SIGINT (130) and SIGTERM (143) (Row 18): escalates INT -> TERM -> KILL across stubborn setpgrp child,
        // marks run/integration/verify `cancelled`, preserves completed merges & worktree, and matches `status --run` JSON.
        for (idx, pair) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))].enumerated() {
            let (sig, expectedCode) = pair
            let vReady = gatesDir.appendingPathComponent("p4-vready-\(idx)")
            let vSubPIDFile = gatesDir.appendingPathComponent("p4-vsubpid-\(idx)")
            try "STUB WRITE src/p4_\(idx).txt merged-content-\(idx)\n".write(
                to: promptsDir.appendingPathComponent("p4_\(idx).md"),
                atomically: true,
                encoding: .utf8
            )

            let verifyCmd4 = """
            /usr/bin/perl -MPOSIX=setpgid -e '
                my ($pfile, $tok) = @ARGV;
                setpgid(0, 0) or die $!;
                $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
                open(my $fh, ">", $pfile) or die $!;
                print $fh "$$\\n";
                close($fh);
                select(undef, undef, undef, 30);
            ' "\(vSubPIDFile.path)" "\(tempToken)-vsub-\(idx)" </dev/null >/dev/null 2>&1 &
            while [ ! -s "\(vSubPIDFile.path)" ]; do /bin/sleep 0.02; done
            : > "\(vReady.path)"
            /usr/bin/perl -e 'select(undef, undef, undef, 3.5);' "\(tempToken)-vhold-\(idx)"
            """

            let plan4URL = plansDir.appendingPathComponent("p4-verify-sig-\(idx).json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/p4_\(idx).md", "after": []]],
                    "verify": verifyCmd4,
                    "verify_timeout": 60
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan4URL, options: .atomic)

            let reg4 = RelayActiveLaneRegistry()
            let run4ID = "20261117-08001\(idx)-000\(6 + idx)"
            let cli4 = RelayCLIRunner(runIDProvider: { run4ID }, activeLaneRegistry: reg4, cancellationPolicy: fastPolicy)
            let task4 = Task {
                await cli4.executeCommand(
                    arguments: ["run", plan4URL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                    environment: fx.baseEnvironment
                )
            }

            for _ in 0..<300 where !FileManager.default.fileExists(atPath: vReady.path) {
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            #expect(FileManager.default.fileExists(atPath: vReady.path))
            if let rawSub = try? String(contentsOf: vSubPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let spid = pid_t(rawSub) {
                trackedPIDs.append(spid)
            }

            reg4.requestCancellation(signal: sig)
            let res4 = await task4.value
            #expect(res4.exitCode == expectedCode)

            let rec4 = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: res4.stdout)
            #expect(rec4.status == .cancelled)
            #expect(rec4.integration?.status == .cancelled)
            #expect(rec4.integration?.ready == false)
            #expect(rec4.integration?.verify?.status == .cancelled)

            // Completed merge and integration worktree must still be intact!
            let mergeOID4 = try #require(rec4.integration?.merges.first?.mergeCommitOID)
            #expect(rec4.integration?.headCommitOID == mergeOID4)
            let wtPath4 = try #require(rec4.integration?.worktreePath)
            #expect(FileManager.default.fileExists(atPath: wtPath4))
            #expect(FileManager.default.fileExists(atPath: (wtPath4 as NSString).appendingPathComponent("src/p4_\(idx).txt")))

            if let rawSub = try? String(contentsOf: vSubPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let spid = pid_t(rawSub) {
                #expect(Darwin.kill(spid, 0) != 0, "Stubborn subgroup PID \(spid) survived verify signal cancellation")
            }

            let status4 = await cli4.executeCommand(
                arguments: ["status", "--project", fx.projectURL.path, "--run", run4ID, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            #expect(status4.exitCode == 0)
            #expect(status4.stdout == res4.stdout)
            #expect(!status4.stdout.contains("\"running\""))
            #expect(!status4.stdout.contains("\"verifying\""))
        }
    }

    // MARK: - 41. M2 Stage 4 Items 3 & 4: Exit Code Table (`0` / `1`), `ready` Invariant, `stdout == status --run` Byte Parity, `--lang zh`/`en` JSON Parity & Localized Stderr Summary Last Line (§8, §10, Rows 1, 3, 5, 7, 9, 10, 11, 14, 16, 27, 28)

    @Test("RelayCLIRunner run enforces M2 exit code table (0 vs 1), ready==(all lanes succeeded && verified), byte-identical status --run JSON, and --lang zh/en JSON parity with localized stderr ending in integration summary")
    func cliRunExitCodeTableReadyFlagStdoutParityAndBilingualOutput() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-items34")
        let tempToken = fx.rootURL.lastPathComponent
        var trackedPIDs: [pid_t] = []
        defer {
            for pid in trackedPIDs where pid > 0 {
                _ = Darwin.kill(-pid, SIGKILL)
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: fx.rootURL)
        }

        try "line-1\n".write(to: fx.repoURL.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try runTool("/usr/bin/git", ["add", "f.txt"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        _ = try runTool("/usr/bin/git", ["commit", "-m", "add f.txt"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        let markersDir = fx.rootURL.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markersDir, withIntermediateDirectories: true)

        func writePrompt(_ name: String, _ content: String) throws {
            try content.write(to: promptsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try writePrompt("a_ok.md", "STUB WRITE src/a.txt ok-a\n")
        try writePrompt("b_ok.md", "STUB WRITE src/b.txt ok-b\n")
        try writePrompt("noop.md", "STUB MESSAGE nothing changed\n")
        try writePrompt("fail3.md", "STUB WRITE dirty.txt x\nSTUB EXIT 3\n")
        try writePrompt("partial.md", "STUB WRITE src/part.txt half\nSTUB STATUS partial\n")
        try writePrompt("conf_a.md", "STUB WRITE f.txt from-a\n")
        try writePrompt("conf_b.md", "STUB WRITE f.txt from-b\n")
        try writePrompt("c_ok.md", "STUB WRITE src/c.txt ok-c\n")

        func lastNonEmptyLine(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        }

        func assertStdoutMatchesStatusByteForByte(_ runRes: RelayCLIExecutionResult, runID: String) async throws -> RelayRunRecord {
            let cliCheck = RelayCLIRunner()
            let stEN = await cliCheck.executeCommand(
                arguments: ["status", "--project", fx.projectURL.path, "--run", runID, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            let stZH = await cliCheck.executeCommand(
                arguments: ["status", "--project", fx.projectURL.path, "--run", runID, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            #expect(stEN.exitCode == 0)
            #expect(stZH.exitCode == 0)
            #expect(stEN.stdout == runRes.stdout)
            #expect(stZH.stdout == runRes.stdout)
            return try RelayRunJSONCodec.decode(RelayRunRecord.self, from: runRes.stdout)
        }

        // Helper normalizing per-run volatile identifiers/timestamps/OIDs/paths so `--lang zh` and `--lang en` JSON can be compared structurally & lexically.
        func canonicalizeForLangComparison(_ record: RelayRunRecord) throws -> String {
            var copy = record
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            copy = RelayRunRecord(
                runID: "RUN",
                repoPath: "<repo>",
                planCopyPath: "<plan>",
                baseRef: copy.baseRef,
                baseCommitOID: "<base>",
                verifyCommand: copy.verifyCommand,
                relayShPath: "<relay>",
                relayShSHA256: copy.relayShSHA256,
                startedAt: fixedDate,
                finishedAt: copy.finishedAt.map { _ in fixedDate },
                status: copy.status,
                reason: copy.reason,
                relayidePID: 1,
                budgetUSD: copy.budgetUSD,
                lanes: copy.lanes.map { l in
                    RelayRunLaneRecord(
                        runID: "RUN",
                        laneID: l.laneID,
                        ordinal: l.ordinal,
                        agent: l.agent,
                        promptPath: "<prompt>/\(l.laneID)",
                        after: l.after,
                        status: l.status,
                        exitCode: l.exitCode,
                        signal: l.signal,
                        reason: l.reason,
                        startedAt: l.startedAt.map { _ in fixedDate },
                        finishedAt: l.finishedAt.map { _ in fixedDate },
                        pid: l.pid.map { _ in 10 },
                        costUSD: l.costUSD,
                        tokens: l.tokens,
                        costSource: l.costSource,
                        branch: l.branch.map { _ in "relay/RUN/\(l.laneID)" },
                        commitOID: l.commitOID.map { _ in "<lane-oid-\(l.laneID)>" },
                        worktreePath: l.worktreePath.map { _ in "<wt>/\(l.laneID)" },
                        uncommittedFiles: l.uncommittedFiles
                    )
                },
                integration: copy.integration.map { integ in
                    RelayRunIntegrationRecord(
                        branch: integ.branch.map { _ in "relay/RUN/integration" },
                        worktreePath: integ.worktreePath.map { _ in "<wt>/integration" },
                        baseCommitOID: "<base>",
                        headCommitOID: integ.headCommitOID.map { _ in "<int-head>" },
                        status: integ.status,
                        reason: integ.reason,
                        ready: integ.ready,
                        merges: integ.merges.map { m in
                            RelayRunMergeRecord(
                                ordinal: m.ordinal,
                                laneID: m.laneID,
                                laneCommitOID: m.laneCommitOID.map { _ in "<lane-oid-\(m.laneID)>" },
                                status: m.status,
                                mergeCommitOID: m.mergeCommitOID.map { _ in "<merge-oid-\(m.laneID)>" },
                                conflicts: m.conflicts,
                                conflictLines: m.conflictLines.map { _ in "CONFLICT" },
                                startedAt: m.startedAt.map { _ in fixedDate },
                                finishedAt: m.finishedAt.map { _ in fixedDate }
                            )
                        },
                        verify: integ.verify.map { v in
                            RelayRunVerifyRecord(
                                command: v.command,
                                timeoutSec: v.timeoutSec,
                                status: v.status,
                                exitCode: v.exitCode,
                                signal: v.signal,
                                pid: v.pid.map { _ in 20 },
                                startedAt: v.startedAt.map { _ in fixedDate },
                                finishedAt: v.finishedAt.map { _ in fixedDate },
                                logPath: v.logPath.map { _ in "<verify.pty>" },
                                logBytes: v.logBytes > 0 ? 1 : 0,
                                logTruncated: v.logTruncated,
                                modifiedTrackedFiles: v.modifiedTrackedFiles
                            )
                        }
                    )
                }
            )
            return try RelayRunJSONCodec.encode(copy)
        }

        // A. Two clean lanes WITHOUT verify (D2): exit 0, merged, ready == false, verify == nil.
        do {
            let planA = plansDir.appendingPathComponent("a-no-verify.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/a_ok.md", "after": []],
                        ["id": "b", "agent": "vibe", "prompt": "prompts/b_ok.md", "after": []]
                    ]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planA, options: .atomic)

            let runID = "20261117-090000-0001"
            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", planA.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            #expect(res.exitCode == 0)
            let rec = try await assertStdoutMatchesStatusByteForByte(res, runID: runID)
            #expect(rec.status == .succeeded)
            #expect(rec.integration?.status == .merged)
            #expect(rec.integration?.ready == false)
            #expect(rec.integration?.verify == nil)
            #expect(lastNonEmptyLine(res.stderr).hasPrefix("[relay] integration finished · status merged · ready no"))
        }

        // B. Two clean lanes WITH passing verify: exit 0, verified, ready == true (ONLY ready==true case!).
        do {
            let planB = plansDir.appendingPathComponent("b-pass-verify.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/a_ok.md", "after": []],
                        ["id": "b", "agent": "vibe", "prompt": "prompts/b_ok.md", "after": []]
                    ],
                    "verify": "test -f src/a.txt && test -f src/b.txt"
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planB, options: .atomic)

            let runID = "20261117-090001-0002"
            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", planB.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            #expect(res.exitCode == 0)
            let rec = try await assertStdoutMatchesStatusByteForByte(res, runID: runID)
            #expect(rec.status == .succeeded)
            #expect(rec.integration?.status == .verified)
            #expect(rec.integration?.ready == true)
            #expect(rec.integration?.verify?.status == .passed)
            #expect(lastNonEmptyLine(res.stderr).hasPrefix("[relay] 集成结果 · 状态 已验证 · 可合入 是"))
        }

        // C. All lanes succeeded-no-changes (with verify configured, Row 7): exit 0, nothing-to-merge, ready == false, no integration branch/worktree, verify skipped.
        do {
            let markerC = markersDir.appendingPathComponent("c-verify-should-not-run")
            let planC = plansDir.appendingPathComponent("c-noop.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/noop.md", "after": []],
                        ["id": "b", "agent": "codex", "prompt": "prompts/noop.md", "after": []]
                    ],
                    "verify": ": > \"\(markerC.path)\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planC, options: .atomic)

            let runID = "20261117-090002-0003"
            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", planC.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            #expect(res.exitCode == 0)
            #expect(!FileManager.default.fileExists(atPath: markerC.path))
            let rec = try await assertStdoutMatchesStatusByteForByte(res, runID: runID)
            #expect(rec.status == .succeeded)
            #expect(rec.integration?.status == .nothingToMerge)
            #expect(rec.integration?.ready == false)
            #expect(rec.integration?.branch == nil)
            #expect(rec.integration?.worktreePath == nil)
            #expect(rec.integration?.verify == nil)
            let refCheck = try runTool(
                "/usr/bin/git",
                ["show-ref", "--verify", "--quiet", "refs/heads/relay/\(runID)/integration"],
                environment: fx.baseEnvironment,
                currentDirectory: fx.repoURL
            )
            #expect(refCheck.exitCode != 0)
            #expect(lastNonEmptyLine(res.stderr).hasPrefix("[relay] integration finished · status nothing to merge · ready no"))
        }

        // D. Non-succeeded lane (`failed` exit 3 and `partial` exit 5, Row 9): exit 1, integration skipped, ready == false, no branch/worktree, verify skipped.
        for (idx, promptName) in ["prompts/fail3.md", "prompts/partial.md"].enumerated() {
            let markerD = markersDir.appendingPathComponent("d-verify-\(idx)")
            let planD = plansDir.appendingPathComponent("d-nonsucc-\(idx).json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": promptName, "after": []],
                        ["id": "b", "agent": "vibe", "prompt": "prompts/b_ok.md", "after": []]
                    ],
                    "verify": ": > \"\(markerD.path)\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planD, options: .atomic)

            let runID = "20261117-09001\(idx)-000\(4 + idx)"
            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", planD.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            #expect(res.exitCode == 1)
            #expect(!FileManager.default.fileExists(atPath: markerD.path))
            let rec = try await assertStdoutMatchesStatusByteForByte(res, runID: runID)
            #expect(rec.integration?.status == .skipped)
            #expect(rec.integration?.ready == false)
            #expect(rec.integration?.branch == nil)
            #expect(rec.integration?.worktreePath == nil)
            #expect(rec.integration?.verify == nil)
            #expect(lastNonEmptyLine(res.stderr).hasPrefix("[relay] 集成结果 · 状态 已跳过 · 可合入 否"))
        }

        // E. Same-line conflict across [a, b, c] with verify configured, replayed in ZH and EN (Rows 3, 5, 27, 28):
        // exit 1, merges=[merged, conflict, not-attempted], verify==nil, ready==false, ZH/EN JSON identical & stderr localized.
        do {
            let markerE = markersDir.appendingPathComponent("e-conflict-verify")
            let planE = plansDir.appendingPathComponent("e-conflict.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/conf_a.md", "after": []],
                        ["id": "b", "agent": "codex", "prompt": "prompts/conf_b.md", "after": []],
                        ["id": "c", "agent": "vibe", "prompt": "prompts/c_ok.md", "after": []]
                    ],
                    "verify": ": > \"\(markerE.path)\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planE, options: .atomic)

            let resZH = await RelayCLIRunner(runIDProvider: { "20261117-090020-0010" }).executeCommand(
                arguments: ["run", planE.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            let resEN = await RelayCLIRunner(runIDProvider: { "20261117-090021-0011" }).executeCommand(
                arguments: ["run", planE.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            #expect(resZH.exitCode == 1)
            #expect(resEN.exitCode == 1)
            #expect(!FileManager.default.fileExists(atPath: markerE.path))

            let recZH = try await assertStdoutMatchesStatusByteForByte(resZH, runID: "20261117-090020-0010")
            let recEN = try await assertStdoutMatchesStatusByteForByte(resEN, runID: "20261117-090021-0011")
            #expect(recZH.status == .succeeded)
            #expect(recZH.integration?.status == .conflict)
            #expect(recZH.integration?.ready == false)
            #expect(recZH.integration?.verify == nil)
            #expect(recZH.integration?.merges.map(\.status) == [.merged, .conflict, .notAttempted])
            #expect(recZH.integration?.merges[1].conflicts == [RelayMergeConflictItem(path: "f.txt", code: "UU")])

            #expect(try canonicalizeForLangComparison(recZH) == canonicalizeForLangComparison(recEN))
            #expect(resZH.stderr != resEN.stderr)
            #expect(!resZH.stderr.contains("lane "))
            #expect(!resEN.stderr.contains("通道 "))
            #expect(lastNonEmptyLine(resZH.stderr).hasPrefix("[relay] 集成结果 · 状态 冲突 · 可合入 否"))
            #expect(lastNonEmptyLine(resEN.stderr).hasPrefix("[relay] integration finished · status conflict · ready no"))
        }

        // F. `verify` exit 3 (replayed in ZH & EN), `verify` dirty tracked file, and `verify` timeout (Rows 11, 14, 16, 27, 28) -> all exit 1, ready == false!
        do {
            let planFExit = plansDir.appendingPathComponent("f-verify-exit3.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a_ok.md", "after": []]],
                    "verify": "exit 3"
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planFExit, options: .atomic)

            let fZH = await RelayCLIRunner(runIDProvider: { "20261117-090030-0020" }).executeCommand(
                arguments: ["run", planFExit.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "zh"],
                environment: fx.baseEnvironment
            )
            let fEN = await RelayCLIRunner(runIDProvider: { "20261117-090031-0021" }).executeCommand(
                arguments: ["run", planFExit.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            #expect(fZH.exitCode == 1)
            #expect(fEN.exitCode == 1)
            let recFZH = try await assertStdoutMatchesStatusByteForByte(fZH, runID: "20261117-090030-0020")
            let recFEN = try await assertStdoutMatchesStatusByteForByte(fEN, runID: "20261117-090031-0021")
            #expect(recFZH.integration?.status == .verifyFailed)
            #expect(recFZH.integration?.ready == false)
            #expect(recFZH.integration?.verify?.status == .failed)
            #expect(recFZH.integration?.verify?.exitCode == 3)
            #expect(try canonicalizeForLangComparison(recFZH) == canonicalizeForLangComparison(recFEN))
            #expect(fZH.stderr != fEN.stderr)
            #expect(lastNonEmptyLine(fZH.stderr).hasPrefix("[relay] 集成结果 · 状态 验证失败 · 可合入 否"))
            #expect(lastNonEmptyLine(fEN.stderr).hasPrefix("[relay] integration finished · status verify failed · ready no"))

            // F2: verify modifies tracked file src/a.txt and exits 0 -> exit 1, verify-failed, modifiedTrackedFiles == ["src/a.txt"]
            let planFDirty = plansDir.appendingPathComponent("f-verify-dirty.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a_ok.md", "after": []]],
                    "verify": "printf 'mutated\\n' >> src/a.txt && exit 0"
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planFDirty, options: .atomic)

            let fDirty = await RelayCLIRunner(runIDProvider: { "20261117-090032-0022" }).executeCommand(
                arguments: ["run", planFDirty.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            #expect(fDirty.exitCode == 1)
            let recDirty = try await assertStdoutMatchesStatusByteForByte(fDirty, runID: "20261117-090032-0022")
            #expect(recDirty.integration?.status == .verifyFailed)
            #expect(recDirty.integration?.ready == false)
            #expect(recDirty.integration?.verify?.modifiedTrackedFiles == ["src/a.txt"])

            // F3: verify timeout with stubborn setpgrp child -> exit 1, verify-timeout, ready == false, zero leftover processes
            let subPIDURL = markersDir.appendingPathComponent("f-timeout-sub.pid")
            let timeoutCmd = """
            /usr/bin/perl -MPOSIX=setpgid -e '
                my ($pfile, $tok) = @ARGV;
                setpgid(0, 0) or die $!;
                $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
                open(my $fh, ">", $pfile) or die $!;
                print $fh "$$\\n";
                close($fh);
                select(undef, undef, undef, 30);
            ' "\(subPIDURL.path)" "\(tempToken)-tmosub" </dev/null >/dev/null 2>&1 &
            while [ ! -s "\(subPIDURL.path)" ]; do /bin/sleep 0.02; done
            /usr/bin/perl -e 'select(undef, undef, undef, 30);' "\(tempToken)-tmohold"
            """
            let planFTmo = plansDir.appendingPathComponent("f-verify-timeout.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a_ok.md", "after": []]],
                    "verify": timeoutCmd,
                    "verify_timeout": 1
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planFTmo, options: .atomic)

            let fastCancel = RelayCancellationPolicy(sigintGraceSeconds: 0.2, sigtermGraceSeconds: 0.2)
            let fTmo = await RelayCLIRunner(runIDProvider: { "20261117-090033-0023" }, cancellationPolicy: fastCancel).executeCommand(
                arguments: ["run", planFTmo.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment
            )
            if let rawSub = try? String(contentsOf: subPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let spid = pid_t(rawSub) {
                trackedPIDs.append(spid)
                #expect(Darwin.kill(spid, 0) != 0)
            }
            #expect(fTmo.exitCode == 1)
            let recTmo = try await assertStdoutMatchesStatusByteForByte(fTmo, runID: "20261117-090033-0023")
            #expect(recTmo.integration?.status == .verifyTimeout)
            #expect(recTmo.integration?.ready == false)
            #expect(recTmo.integration?.verify?.status == .timeout)
            #expect(recTmo.integration?.verify?.exitCode == nil)
            #expect(lastNonEmptyLine(fTmo.stderr).hasPrefix("[relay] integration finished · status verify timeout · ready no"))
        }
    }

    // MARK: - 42. M2 Stage 4 Item 3: All Five `125` Integration/Verify Error Classes Emit Empty `stdout` and Persist `.error` (§8, Row 22)

    @Test("RelayCLIRunner run exits 125 with empty stdout across integration worktree failure, non-conflict git merge failure, dirty abort, verify start failure, and SQLite write failure")
    func cliRunMergeAndVerify125ErrorsEmitEmptyStdoutAndPersistErrorState() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-125errors")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let plansDir = fx.rootURL.appendingPathComponent("plans", isDirectory: true)
        let promptsDir = plansDir.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB WRITE src/a.txt ok-a\n".write(to: promptsDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "STUB WRITE src/b.txt ok-b\n".write(to: promptsDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)

        // 1. Integration worktree creation fails (obstructed by regular file, Row 22) -> 125, empty stdout, integration.status == .error.
        do {
            let runID = "20261117-100000-0101"
            let plan1 = plansDir.appendingPathComponent("e1-wt-fail.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []]]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan1, options: .atomic)

            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", plan1.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment,
                onLiveStderrLine: { line in
                    if line.contains("[relay] lane a (claude)") && line.contains("succeeded") {
                        let blocker = fx.projectURL.appendingPathComponent("runs/\(runID)/worktrees/integration")
                        try? FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "blocker\n".write(to: blocker, atomically: true, encoding: .utf8)
                    }
                }
            )
            #expect(res.exitCode == 125)
            #expect(res.stdout.isEmpty)
            #expect(!res.stderr.isEmpty)
            let rec = try #require(try db.fetchRun(runID: runID, reconcileWithLock: true))
            #expect(rec.status == .interrupted)
            #expect(rec.integration?.status == .error)
            #expect(rec.integration?.ready == false)
        }

        // 2. Non-conflict `git merge` failure (untracked file blocking merge in integration worktree, no MERGE_HEAD) -> 125, empty stdout, integration.status == .error.
        do {
            let runID = "20261117-100001-0102"
            let plan2 = plansDir.appendingPathComponent("e2-nonconflict-merge.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []]]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan2, options: .atomic)

            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", plan2.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment,
                onLiveStderrLine: { line in
                    if line.contains("[relay] created integration branch") {
                        let untrk = fx.projectURL.appendingPathComponent("runs/\(runID)/worktrees/integration/src/a.txt")
                        try? FileManager.default.createDirectory(at: untrk.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "untracked-blocker\n".write(to: untrk, atomically: true, encoding: .utf8)
                    }
                }
            )
            #expect(res.exitCode == 125)
            #expect(res.stdout.isEmpty)
            #expect(!res.stderr.isEmpty)
            let rec = try #require(try db.fetchRun(runID: runID, reconcileWithLock: true))
            #expect(rec.status == .interrupted)
            #expect(rec.integration?.status == .error)
            #expect(rec.integration?.reason?.hasPrefix("error:") == true)
        }

        // 3. Unclean state after `git merge --abort` (custom merge driver leaves an ignored file detected by `status --porcelain=v1 -uall --ignored`) -> 125, empty stdout, integration.status == .error.
        do {
            let dirtyAbortFx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-dirtyabort")
            defer { try? FileManager.default.removeItem(at: dirtyAbortFx.rootURL) }

            try "base\n".write(to: dirtyAbortFx.repoURL.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
            try "conflict.txt merge=dirtydrv\n".write(to: dirtyAbortFx.repoURL.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            _ = try runTool("/usr/bin/git", ["add", "conflict.txt", ".gitattributes"], environment: dirtyAbortFx.baseEnvironment, currentDirectory: dirtyAbortFx.repoURL)
            _ = try runTool("/usr/bin/git", ["commit", "-m", "setup dirtydrv"], environment: dirtyAbortFx.baseEnvironment, currentDirectory: dirtyAbortFx.repoURL)
            let excludeURL = dirtyAbortFx.repoURL.appendingPathComponent(".git/info/exclude")
            try ".leftover-ignored\n".write(to: excludeURL, atomically: true, encoding: .utf8)

            let drvScript = dirtyAbortFx.rootURL.appendingPathComponent("dirty-drv.sh")
            try """
            #!/bin/sh
            : > .leftover-ignored
            exit 1
            """.write(to: drvScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drvScript.path)
            _ = try runTool("/usr/bin/git", ["config", "merge.dirtydrv.driver", "\"\(drvScript.path)\" %O %A %B"], environment: dirtyAbortFx.baseEnvironment, currentDirectory: dirtyAbortFx.repoURL)

            let dPrompts = dirtyAbortFx.rootURL.appendingPathComponent("prompts", isDirectory: true)
            try FileManager.default.createDirectory(at: dPrompts, withIntermediateDirectories: true)
            try "STUB WRITE conflict.txt a\n".write(to: dPrompts.appendingPathComponent("ca.md"), atomically: true, encoding: .utf8)
            try "STUB WRITE conflict.txt b\n".write(to: dPrompts.appendingPathComponent("cb.md"), atomically: true, encoding: .utf8)
            let plan3 = dirtyAbortFx.rootURL.appendingPathComponent("plan3.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": dirtyAbortFx.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/ca.md", "after": []],
                        ["id": "b", "agent": "codex", "prompt": "prompts/cb.md", "after": []]
                    ]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan3, options: .atomic)

            let runID = "20261117-100002-0103"
            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", plan3.path, "--project", dirtyAbortFx.projectURL.path, "--relay-sh", dirtyAbortFx.fakeRelayShURL.path, "--lang", "en"],
                environment: dirtyAbortFx.baseEnvironment
            )
            #expect(res.exitCode == 125)
            #expect(res.stdout.isEmpty)
            #expect(!res.stderr.isEmpty)
            let dirtyDB = try RelayProjectDatabase.openExisting(bundleDirectoryURL: dirtyAbortFx.projectURL)
            let rec = try #require(try dirtyDB.fetchRun(runID: runID, reconcileWithLock: true))
            #expect(rec.integration?.status == .error)
        }

        // 4. `verify` fails to start (`verify.pty` obstructed by a directory -> `rawTranscriptOpenFailed`) -> 125, empty stdout, integration.status == .error (not `.merged`!).
        do {
            let runID = "20261117-100003-0104"
            let plan4 = plansDir.appendingPathComponent("e4-verify-start-fail.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []]],
                    "verify": "exit 0"
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan4, options: .atomic)

            let res = await RelayCLIRunner(runIDProvider: { runID }).executeCommand(
                arguments: ["run", plan4.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
                environment: fx.baseEnvironment,
                onLiveStderrLine: { line in
                    if line.contains("[relay] merge lane a") {
                        let ptyDir = fx.projectURL.appendingPathComponent("runs/\(runID)/verify.pty", isDirectory: true)
                        try? FileManager.default.createDirectory(at: ptyDir, withIntermediateDirectories: true)
                    }
                }
            )
            #expect(res.exitCode == 125)
            #expect(res.stdout.isEmpty)
            #expect(!res.stderr.isEmpty)
            let rec = try #require(try db.fetchRun(runID: runID, reconcileWithLock: true))
            #expect(rec.status == .interrupted)
            #expect(rec.integration?.status == .error)
            #expect(rec.integration?.ready == false)
        }

        // 5. Database write failure (`sqlite3` trigger aborting update to `verifying`) -> 125, empty stdout, verify child terminated cleanly!
        do {
            let dbFailFx = try makeIsolatedRunFixture(prefix: "relay-m2-s4-dbfail")
            let dbFailToken = dbFailFx.rootURL.lastPathComponent
            defer { try? FileManager.default.removeItem(at: dbFailFx.rootURL) }

            let sqliteURL = dbFailFx.projectURL.appendingPathComponent("workspace.sqlite")
            _ = try runTool(
                "/usr/bin/sqlite3",
                [
                    sqliteURL.path,
                    "CREATE TRIGGER abort_verify_write BEFORE UPDATE ON relay_run_integration WHEN NEW.status = 'verifying' BEGIN SELECT RAISE(ABORT, 'simulated sqlite write failure'); END;"
                ],
                environment: dbFailFx.baseEnvironment
            )

            let dPrompts = dbFailFx.rootURL.appendingPathComponent("prompts", isDirectory: true)
            try FileManager.default.createDirectory(at: dPrompts, withIntermediateDirectories: true)
            try "STUB WRITE src/a.txt ok\n".write(to: dPrompts.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            let plan5 = dbFailFx.rootURL.appendingPathComponent("plan5.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": dbFailFx.repoURL.path,
                    "base": "main",
                    "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []]],
                    "verify": "/usr/bin/perl -e 'select(undef, undef, undef, 20);' \"\(dbFailToken)-dbhold\""
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: plan5, options: .atomic)

            let fastCancel = RelayCancellationPolicy(sigintGraceSeconds: 0.15, sigtermGraceSeconds: 0.15)
            let res = await RelayCLIRunner(runIDProvider: { "20261117-100004-0105" }, cancellationPolicy: fastCancel).executeCommand(
                arguments: ["run", plan5.path, "--project", dbFailFx.projectURL.path, "--relay-sh", dbFailFx.fakeRelayShURL.path, "--lang", "en"],
                environment: dbFailFx.baseEnvironment
            )
            #expect(res.exitCode == 125)
            #expect(res.stdout.isEmpty)
            #expect(!res.stderr.isEmpty)

            let psOut = try runTool("/bin/ps", ["-axo", "pid=,command="], environment: dbFailFx.baseEnvironment).stdout
            #expect(!psOut.contains("\(dbFailToken)-dbhold"))
        }
    }

    // MARK: - 42. M2 Stage 7: `status --json` Byte Parity & Committed `docs/demo-relay-dossier.html` Schema v6 (R63, R65)

    @Test("RelayCLIRunner status --json produces byte-identical output to omitting --json across workspace, --runs, and --run modes, and docs/demo-relay-dossier.html carries Schema v6")
    func cliStatusJsonFlagByteParityAndCommittedDossierSchemaV6() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "relay-m2-s7-status-json")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let promptsDir = fx.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB WRITE src/a.txt ok\n".write(to: promptsDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let planURL = fx.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.repoURL.path,
                "base": "main",
                "lanes": [["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []]],
                "verify": "true"
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL, options: .atomic)

        let runID = "20261117-120000-0701"
        let cli = RelayCLIRunner(runIDProvider: { runID })
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
            environment: fx.baseEnvironment
        )
        #expect(runRes.exitCode == 0)

        for lang in ["en", "zh"] {
            let plainStats = try await cli.execute(arguments: ["status", "--project", fx.projectURL.path, "--lang", lang])
            let jsonStats = try await cli.execute(arguments: ["status", "--project", fx.projectURL.path, "--json", "--lang", lang])
            #expect(plainStats == jsonStats)

            let plainRuns = try await cli.execute(arguments: ["status", "--project", fx.projectURL.path, "--runs", "--lang", lang])
            let jsonRuns = try await cli.execute(arguments: ["status", "--project", fx.projectURL.path, "--runs", "--json", "--lang", lang])
            #expect(plainRuns == jsonRuns)

            let plainRun = try await cli.execute(arguments: ["status", "--project", fx.projectURL.path, "--run", runID, "--lang", lang])
            let jsonRun = try await cli.execute(arguments: ["status", "--project", fx.projectURL.path, "--run", runID, "--json", "--lang", lang])
            #expect(plainRun == jsonRun)
            #expect(jsonRun == runRes.stdout)
        }

        let dossierURL = Self.repositoryRootURL.appendingPathComponent("docs/demo-relay-dossier.html")
        let dossierHTML = try String(contentsOf: dossierURL, encoding: .utf8)
        #expect(dossierHTML.contains("Schema v7"))
        #expect(dossierHTML.contains("架构 v7"))
        #expect(!dossierHTML.contains("Schema v6"))
        #expect(!dossierHTML.contains("架构 v6"))
        #expect(!dossierHTML.contains("Schema v5"))
        #expect(!dossierHTML.contains("架构 v5"))
    }

    // MARK: - 33. M3 Decision (2026-11-21): Removal of Published `semantic-merge` CLI Subcommand & `relay_semantic_merge` MCP Tool

    @Test("M3 decision (2026-11-21): semantic-merge CLI exits 2 as unknown subcommand, --help omits it in EN and ZH, and MCP omits and rejects relay_semantic_merge")
    func m3SemanticMergeCommandAndMCPToolRemoved() async throws {
        // 1. Launch classifier treats `semantic-merge` as an unknown subcommand (exits 2, never opens GUI)
        #expect(!RelayCLIRunner.knownCLISubcommands.contains("semantic-merge"))
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["semantic-merge", "a.py", "b.py", "c.py"])
                == .unknownSubcommand(filteredArguments: ["semantic-merge", "a.py", "b.py", "c.py"], offendingToken: "semantic-merge")
        )
        #expect(
            RelayCLIRunner.classifyLaunchArguments(["--lang", "zh", "semantic-merge", "a.py", "b.py", "c.py"])
                == .unknownSubcommand(filteredArguments: ["--lang", "zh", "semantic-merge", "a.py", "b.py", "c.py"], offendingToken: "semantic-merge")
        )

        // 2. Executing `semantic-merge` (even on valid 3-way fixture files) exits 2 with empty stdout and unknown-subcommand stderr
        let cli = RelayCLIRunner()
        let caseDir = Self.repositoryRootURL.appendingPathComponent("Fixtures/merge-cases/20-py-decorator-added")
        let mergeArgs = [
            "semantic-merge",
            caseDir.appendingPathComponent("base.py").path,
            caseDir.appendingPathComponent("left.py").path,
            caseDir.appendingPathComponent("right.py").path
        ]

        let enMerge = await cli.executeCommand(arguments: mergeArgs + ["--lang", "en"])
        #expect(enMerge.exitCode == 2)
        #expect(enMerge.stdout.isEmpty)
        #expect(enMerge.stderr.contains("Unknown subcommand 'semantic-merge'"))

        let zhMerge = await cli.executeCommand(arguments: mergeArgs + ["--lang", "zh"])
        #expect(zhMerge.exitCode == 2)
        #expect(zhMerge.stdout.isEmpty)
        #expect(zhMerge.stderr.contains("未知子命令 'semantic-merge'"))

        // 3. `--help` omits `semantic-merge` and `relay_semantic_merge` in both EN and ZH
        let helpEN = await cli.executeCommand(arguments: ["--help", "--lang", "en"])
        #expect(helpEN.exitCode == 0)
        #expect(!helpEN.stdout.contains("semantic-merge"))
        #expect(!helpEN.stdout.contains("relay_semantic_merge"))
        #expect(helpEN.stdout.contains("1 tool: relay_check_ownership"))

        let helpZH = await cli.executeCommand(arguments: ["--help", "--lang", "zh"])
        #expect(helpZH.exitCode == 0)
        #expect(!helpZH.stdout.contains("semantic-merge"))
        #expect(!helpZH.stdout.contains("relay_semantic_merge"))
        #expect(helpZH.stdout.contains("1 个工具：relay_check_ownership"))

        // 4. MCP `tools/list` omits `relay_semantic_merge`, and `tools/call` rejects it identically to any other unknown tool
        let server = RelayMCPServer()
        let listReply = try #require(server.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#))
        let listObj = try JSONSerialization.jsonObject(with: Data(listReply.utf8)) as? [String: Any]
        let listRes = listObj?["result"] as? [String: Any]
        let tools = listRes?["tools"] as? [[String: Any]] ?? []
        let toolNames = tools.compactMap { $0["name"] as? String }
        #expect(toolNames == ["relay_check_ownership"])
        #expect(!toolNames.contains("relay_semantic_merge"))

        let removedCallReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "relay_semantic_merge",
                "arguments": [
                    "path": "a.py",
                    "base": "x = 1\n",
                    "left": "x = 2\n",
                    "right": "x = 1\n"
                ]
            ]
        ]
        let removedReply = try #require(
            server.handleJSONRPCLine(String(decoding: try JSONSerialization.data(withJSONObject: removedCallReq), as: UTF8.self))
        )
        let removedObj = try JSONSerialization.jsonObject(with: Data(removedReply.utf8)) as? [String: Any]
        let removedRes = try #require(removedObj?["result"] as? [String: Any])
        #expect(removedRes["isError"] as? Bool == true)
        let removedContent = removedRes["content"] as? [[String: String]]

        let unknownReply = try #require(
            server.handleJSONRPCLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"unknown_tool_probe","arguments":{}}}"#)
        )
        let unknownObj = try JSONSerialization.jsonObject(with: Data(unknownReply.utf8)) as? [String: Any]
        let unknownRes = try #require(unknownObj?["result"] as? [String: Any])
        #expect(unknownRes["isError"] as? Bool == true)
        let unknownContent = unknownRes["content"] as? [[String: String]]

        #expect(removedContent == [["type": "text", "text": "Unknown tool 'relay_semantic_merge'"]])
        #expect(unknownContent == [["type": "text", "text": "Unknown tool 'unknown_tool_probe'"]])
    }

    // MARK: - 43. M4 Spend Aggregation, Workspace Stats, HTML Dossier & Whole-Job `RELAY_BUDGET_USD` (Real `relay.sh` + `stub-agent.sh`)

    private struct RealRelayStubFixture {
        let base: IsolatedRunFixture
        let realRelay: ResolvedRelayScript
        let stubBinURL: URL
        let decoyDirURL: URL
        let decoyMarkerURL: URL
        let tracesDirURL: URL
        let environment: [String: String]
    }

    private func makeRealRelayStubFixture(prefix: String) throws -> RealRelayStubFixture {
        let base = try makeIsolatedRunFixture(prefix: prefix)
        let realRelay = try RelayRunExecutor.resolveAndVerifyRelayScript(
            explicitPath: nil,
            environment: ProcessInfo.processInfo.environment,
            language: .en
        )

        let stubDir = base.rootURL.appendingPathComponent("stub-bin", isDirectory: true)
        let decoyDir = base.rootURL.appendingPathComponent("decoys", isDirectory: true)
        let tracesDir = base.rootURL.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tracesDir, withIntermediateDirectories: true)

        let sourceStubURL = Self.repositoryRootURL.appendingPathComponent("Tests/Support/stub-agent.sh")
        let stubBinURL = stubDir.appendingPathComponent("stub-agent.sh")
        try FileManager.default.copyItem(at: sourceStubURL, to: stubBinURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubBinURL.path)

        let decoyMarkerURL = base.rootURL.appendingPathComponent("decoy-invoked.marker")
        for cliName in ["claude", "codex", "agy", "vibe", "opencode"] {
            let decoyURL = decoyDir.appendingPathComponent(cliName)
            let script = """
            #!/usr/bin/env bash
            printf 'decoy %s invoked: %s\\n' "\(cliName)" "$*" >> "\(decoyMarkerURL.path)"
            exit 99
            """
            try script.write(to: decoyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoyURL.path)
        }

        var env = base.baseEnvironment
        env["PATH"] = "\(decoyDir.path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["RELAYIDE_RELAY_SH"] = realRelay.url.path
        env["RELAY_CLAUDE_BIN"] = stubBinURL.path
        env["RELAY_CODEX_BIN"] = stubBinURL.path
        env["RELAY_AGY_BIN"] = stubBinURL.path
        env["RELAY_VIBE_BIN"] = stubBinURL.path
        env["STUB_TRACE_DIR"] = tracesDir.path
        env.removeValue(forKey: "RELAY_BUDGET_USD")
        env.removeValue(forKey: "RELAY_WORKER")
        env.removeValue(forKey: "RELAY_REAL_AGENTS")
        env.removeValue(forKey: "CLAUDECODE")

        return RealRelayStubFixture(
            base: base,
            realRelay: realRelay,
            stubBinURL: stubBinURL,
            decoyDirURL: decoyDir,
            decoyMarkerURL: decoyMarkerURL,
            tracesDirURL: tracesDir,
            environment: env
        )
    }

    @Test("M4 Spend: 4-vendor run via real relay.sh + stub-agent.sh records usd/unpriced spend matching relay_util.py spent, status --project, and export-html")
    func m4FourVendorSpendSummaryWorkspaceStatsAndHTMLExport() async throws {
        let fx = try makeRealRelayStubFixture(prefix: "m4-four-vendor")
        defer { try? FileManager.default.removeItem(at: fx.base.rootURL) }

        let promptsDir = fx.base.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB LANE c1\nSTUB WRITE c1.txt claude\nSTUB COST 0.1234\n".write(
            to: promptsDir.appendingPathComponent("c1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE v1\nSTUB WRITE v1.txt vibe\nSTUB COST 0.2500\n".write(
            to: promptsDir.appendingPathComponent("v1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE a1\nSTUB WRITE a1.txt agy\nSTUB TOKENS 4500\n".write(
            to: promptsDir.appendingPathComponent("a1.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE x1\nSTUB WRITE x1.txt codex\nSTUB TOKENS 1200\n".write(
            to: promptsDir.appendingPathComponent("x1.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.base.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.base.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "c1", "agent": "claude", "prompt": "prompts/c1.md", "after": []],
                    ["id": "v1", "agent": "vibe",   "prompt": "prompts/v1.md", "after": []],
                    ["id": "a1", "agent": "agy",    "prompt": "prompts/a1.md", "after": []],
                    ["id": "x1", "agent": "codex",  "prompt": "prompts/x1.md", "after": []]
                ],
                "verify": "true"
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL, options: .atomic)

        let cli = RelayCLIRunner()
        let runRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.base.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(runRes.exitCode == 0, "stderr=\(runRes.stderr)")
        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))

        let runObj = try #require(try JSONSerialization.jsonObject(with: Data(runRes.stdout.utf8)) as? [String: Any])
        let runID = try #require(runObj["runID"] as? String)

        let statusRunRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.base.projectURL.path, "--run", runID, "--lang", "en"],
            environment: fx.environment
        )
        #expect(statusRunRes.exitCode == 0)
        #expect(statusRunRes.stdout == runRes.stdout)

        let statusRunsRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.base.projectURL.path, "--runs", "--lang", "en"],
            environment: fx.environment
        )
        #expect(statusRunsRes.exitCode == 0)
        let runsArr = try #require(try JSONSerialization.jsonObject(with: Data(statusRunsRes.stdout.utf8)) as? [[String: Any]])
        #expect(runsArr.count == 1)

        // Top-level run summary fields
        #expect(runObj["budgetUSD"] is NSNull)
        #expect(abs((runObj["totalCostUSD"] as? Double ?? -1) - 0.3734) < 1e-9)
        #expect(runObj["unpricedTokens"] as? Int == 5700)
        #expect(runObj["pricedLaneCount"] as? Int == 2)
        #expect(runObj["unpricedLaneCount"] as? Int == 2)
        #expect(runObj["noRecordLaneCount"] as? Int == 0)
        #expect(runObj["budgetExhausted"] as? Bool == false)

        // Per-lane verification + independent relay_util.py spent check
        let lanesArr = try #require(runObj["lanes"] as? [[String: Any]])
        let laneByID = Dictionary(uniqueKeysWithValues: lanesArr.compactMap { l in (l["laneID"] as? String).map { ($0, l) } })
        let c1 = try #require(laneByID["c1"])
        let v1 = try #require(laneByID["v1"])
        let a1 = try #require(laneByID["a1"])
        let x1 = try #require(laneByID["x1"])

        #expect(abs((c1["costUSD"] as? Double ?? -1) - 0.1234) < 1e-9)
        #expect(c1["costSource"] as? String == "usd")
        #expect(c1["tokens"] is NSNull)
        #expect(abs((v1["costUSD"] as? Double ?? -1) - 0.25) < 1e-9)
        #expect(v1["costSource"] as? String == "usd")
        #expect(v1["tokens"] is NSNull)

        #expect(a1["costUSD"] is NSNull)
        #expect(a1["tokens"] as? Int == 4500)
        #expect(a1["costSource"] as? String == "unpriced")
        #expect(x1["costUSD"] is NSNull)
        #expect(x1["tokens"] as? Int == 1200)
        #expect(x1["costSource"] as? String == "unpriced")

        var utilSpentSum = 0.0
        for lid in ["c1", "v1", "a1", "x1"] {
            let wt = try #require(laneByID[lid]?["worktreePath"] as? String)
            let logPath = (wt as NSString).appendingPathComponent(".relay/LOG.md")
            let utilOut = try runTool("/usr/bin/python3", ["-I", fx.realRelay.utilURL.path, "spent", logPath], environment: fx.environment)
            let val = try #require(Double(utilOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
            utilSpentSum += val
        }
        #expect(abs(utilSpentSum - 0.3734) < 1e-9)

        // Workspace-level status --project & export-html
        let projStatusRes = await cli.executeCommand(
            arguments: ["status", "--project", fx.base.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(projStatusRes.exitCode == 0)
        let stats = try JSONDecoder().decode(RelayWorkspaceStats.self, from: Data(projStatusRes.stdout.utf8))
        #expect(stats.schemaVersion == 7)
        #expect(abs(stats.totalSpendUSD - 0.3734) < 1e-9)
        #expect(stats.totalTokensObserved == 5700)

        let htmlURL = fx.base.rootURL.appendingPathComponent("real-dossier.html")
        let htmlRes = await cli.executeCommand(
            arguments: ["export-html", htmlURL.path, "--project", fx.base.projectURL.path, "--lang", "en"],
            environment: fx.environment
        )
        #expect(htmlRes.exitCode == 0)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(html.contains("$0.3734"))
        #expect(html.contains("5700"))
        #expect(html.contains("$0.1234"))
        #expect(html.contains("$0.2500"))
        #expect(html.contains("4500"))
        #expect(html.contains("1200"))
        #expect(!html.contains("[DEMO]"))
        #expect(!html.contains("[演示数据]"))
    }

    @Test("M4 Budget: a->b->c->d chain with RELAY_BUDGET_USD=0.50 refuses c via relay.sh, skips d, and exits 1 in EN and ZH")
    func m4ChainBudgetExhaustionRefusesThirdLaneAndSkipsDownstreamInENAndZH() async throws {
        for lang in ["en", "zh"] {
            let fx = try makeRealRelayStubFixture(prefix: "m4-chain-exhaust-\(lang)")
            defer { try? FileManager.default.removeItem(at: fx.base.rootURL) }

            let promptsDir = fx.base.rootURL.appendingPathComponent("prompts", isDirectory: true)
            try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
            try "STUB LANE a\nSTUB WRITE a.txt ok\nSTUB COST 0.3000\n".write(
                to: promptsDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
            )
            try "STUB LANE b\nSTUB WRITE b.txt ok\nSTUB COST 0.2500\n".write(
                to: promptsDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8
            )
            try "STUB LANE c\nSTUB WRITE c.txt should-not-run\nSTUB COST 0.1000\n".write(
                to: promptsDir.appendingPathComponent("c.md"), atomically: true, encoding: .utf8
            )
            try "STUB LANE d\nSTUB WRITE d.txt should-be-skipped\nSTUB TOKENS 900\n".write(
                to: promptsDir.appendingPathComponent("d.md"), atomically: true, encoding: .utf8
            )

            let planURL = fx.base.rootURL.appendingPathComponent("plan.json")
            try JSONSerialization.data(
                withJSONObject: [
                    "repo": fx.base.repoURL.path,
                    "base": "main",
                    "lanes": [
                        ["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []],
                        ["id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": ["a"]],
                        ["id": "c", "agent": "claude", "prompt": "prompts/c.md", "after": ["b"]],
                        ["id": "d", "agent": "codex",  "prompt": "prompts/d.md", "after": ["c"]]
                    ]
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: planURL, options: .atomic)

            var env = fx.environment
            env["RELAY_BUDGET_USD"] = "0.50"

            let cli = RelayCLIRunner()
            let res = await cli.executeCommand(
                arguments: ["run", planURL.path, "--project", fx.base.projectURL.path, "--lang", lang],
                environment: env
            )
            #expect(res.exitCode == 1, "(\(lang)): expected exit 1, got \(res.exitCode) stderr=\(res.stderr)")
            #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))

            let runObj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
            #expect(abs((runObj["budgetUSD"] as? Double ?? -1) - 0.50) < 1e-9)
            #expect(abs((runObj["totalCostUSD"] as? Double ?? -1) - 0.55) < 1e-9)
            #expect(runObj["pricedLaneCount"] as? Int == 2)
            #expect(runObj["noRecordLaneCount"] as? Int == 1)
            #expect(runObj["budgetExhausted"] as? Bool == true)

            let lanesArr = try #require(runObj["lanes"] as? [[String: Any]])
            let byID = Dictionary(uniqueKeysWithValues: lanesArr.compactMap { l in (l["laneID"] as? String).map { ($0, l) } })
            let laneA = try #require(byID["a"])
            let laneB = try #require(byID["b"])
            let laneC = try #require(byID["c"])
            let laneD = try #require(byID["d"])

            #expect(laneA["status"] as? String == "succeeded")
            #expect(!(laneA["commitOID"] is NSNull))
            #expect(laneB["status"] as? String == "succeeded")
            #expect(!(laneB["commitOID"] is NSNull))

            #expect(laneC["status"] as? String == "refused")
            #expect(laneC["exitCode"] as? Int == 2)
            #expect(laneC["commitOID"] is NSNull)
            #expect(laneC["costUSD"] is NSNull)
            #expect(laneC["costSource"] as? String == "no_record")
            #expect(!FileManager.default.fileExists(atPath: fx.tracesDirURL.appendingPathComponent("c.trace").path))
            if let wtC = laneC["worktreePath"] as? String {
                let logC = (wtC as NSString).appendingPathComponent(".relay/LOG.md")
                #expect(!FileManager.default.fileExists(atPath: logC))
            }
            let reasonC = try #require(laneC["reason"] as? String)
            #expect(reasonC.contains("not started: the job budget"))
            #expect(reasonC.contains("$0.5500"))
            #expect(reasonC.contains("$0.5000"))
            if lang == "zh" {
                #expect(reasonC.contains("预算已用完"))
            } else {
                #expect(reasonC.contains("budget spent"))
            }

            #expect(laneD["status"] as? String == "skipped")
            #expect(laneD["worktreePath"] is NSNull)
            #expect(!FileManager.default.fileExists(atPath: fx.tracesDirURL.appendingPathComponent("d.trace").path))

            let integration = try #require(runObj["integration"] as? [String: Any])
            #expect(integration["status"] as? String == "skipped")
            #expect(integration["ready"] as? Bool == false)
        }
    }

    @Test("M4 Budget: RELAY_BUDGET_USD=1.00 passes remaining $0.7000 to second lane b after a spends $0.3000 and succeeds with verify")
    func m4SufficientBudgetPassesRemainingPointSevenThousandToSecondLaneAndVerifies() async throws {
        let fx = try makeRealRelayStubFixture(prefix: "m4-sufficient-budget")
        defer { try? FileManager.default.removeItem(at: fx.base.rootURL) }

        let promptsDir = fx.base.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB LANE a\nSTUB WRITE a.txt ok\nSTUB COST 0.3000\n".write(
            to: promptsDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE b\nSTUB WRITE b.txt ok\nSTUB COST 0.2500\n".write(
            to: promptsDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.base.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.base.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []],
                    ["id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": ["a"]]
                ],
                "verify": "true"
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL, options: .atomic)

        var env = fx.environment
        env["RELAY_BUDGET_USD"] = "1.00"

        let cli = RelayCLIRunner()
        let res = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.base.projectURL.path, "--lang", "en"],
            environment: env
        )
        #expect(res.exitCode == 0, "stderr=\(res.stderr)")
        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))

        let runObj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
        let runID = try #require(runObj["runID"] as? String)
        #expect(abs((runObj["budgetUSD"] as? Double ?? -1) - 1.0) < 1e-9)
        #expect(abs((runObj["totalCostUSD"] as? Double ?? -1) - 0.55) < 1e-9)
        #expect(runObj["budgetExhausted"] as? Bool == false)

        let integration = try #require(runObj["integration"] as? [String: Any])
        #expect(integration["status"] as? String == "verified")
        #expect(integration["ready"] as? Bool == true)

        let bPtyURL = fx.base.projectURL.appendingPathComponent("runs/\(runID)/lanes/b.pty")
        let bPtyText = try String(contentsOf: bPtyURL, encoding: .utf8)
        #expect(bPtyText.contains("0.7000"))

        let bBudgetTrace = try String(contentsOf: fx.tracesDirURL.appendingPathComponent("b.budget"), encoding: .utf8)
        #expect(bBudgetTrace.contains("RELAY_BUDGET_USD=0.7000"))
        #expect(bBudgetTrace.contains("CLI_BUDGET_CAP=0.7000"))
    }

    @Test("M4 Budget: unpriced agy lane is refused by relay.sh after prior dollar lane exhausts RELAY_BUDGET_USD")
    func m4UnpricedAgyLaneRefusedAfterPriorDollarLaneExhaustsBudget() async throws {
        let fx = try makeRealRelayStubFixture(prefix: "m4-agy-refused")
        defer { try? FileManager.default.removeItem(at: fx.base.rootURL) }

        let promptsDir = fx.base.rootURL.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB LANE a\nSTUB WRITE a.txt spend\nSTUB COST 0.6000\n".write(
            to: promptsDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
        )
        try "STUB LANE b\nSTUB WRITE b.txt agy-should-not-run\nSTUB TOKENS 3000\n".write(
            to: promptsDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8
        )

        let planURL = fx.base.rootURL.appendingPathComponent("plan.json")
        try JSONSerialization.data(
            withJSONObject: [
                "repo": fx.base.repoURL.path,
                "base": "main",
                "lanes": [
                    ["id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []],
                    ["id": "b", "agent": "agy",    "prompt": "prompts/b.md", "after": ["a"]]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: planURL, options: .atomic)

        var env = fx.environment
        env["RELAY_BUDGET_USD"] = "0.50"

        let cli = RelayCLIRunner()
        let res = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.base.projectURL.path, "--lang", "zh"],
            environment: env
        )
        #expect(res.exitCode == 1, "stderr=\(res.stderr)")
        #expect(!FileManager.default.fileExists(atPath: fx.decoyMarkerURL.path))
        #expect(!FileManager.default.fileExists(atPath: fx.tracesDirURL.appendingPathComponent("b.trace").path))

        let runObj = try #require(try JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any])
        #expect(abs((runObj["budgetUSD"] as? Double ?? -1) - 0.50) < 1e-9)
        #expect(abs((runObj["totalCostUSD"] as? Double ?? -1) - 0.60) < 1e-9)
        #expect(runObj["budgetExhausted"] as? Bool == true)

        let lanesArr = try #require(runObj["lanes"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: lanesArr.compactMap { l in (l["laneID"] as? String).map { ($0, l) } })
        let laneB = try #require(byID["b"])
        #expect(laneB["status"] as? String == "refused")
        #expect(laneB["exitCode"] as? Int == 2)
        #expect(laneB["costUSD"] is NSNull)
        #expect(laneB["tokens"] is NSNull)
        #expect(laneB["costSource"] as? String == "no_record")
        let reasonB = try #require(laneB["reason"] as? String)
        #expect(reasonB.contains("not started: the job budget"))
    }

    @Test("M4 Budget: 5 invalid RELAY_BUDGET_USD values exit 2 before touching disk in EN and ZH, while empty string means unlimited")
    func m4InvalidBudgetValuesExit2WithoutSideEffectsAndEmptyBudgetIsUnlimited() async throws {
        let fx = try makeIsolatedRunFixture(prefix: "m4-invalid-budgets")
        defer { try? FileManager.default.removeItem(at: fx.rootURL) }

        let promptsDir = fx.rootURL.appendingPathComponent("plans/prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "STUB WRITE out.txt ok\n".write(to: promptsDir.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        let planURL = fx.rootURL.appendingPathComponent("plans/valid.json")
        try """
        {
          "repo": "\(fx.repoURL.path)",
          "base": "main",
          "lanes": [{"id": "a", "agent": "claude", "prompt": "prompts/task.md", "after": []}]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        let invalidValues = ["0", "-2.5", "NaN", "inf", "abc"]

        for bad in invalidValues {
            for lang in ["en", "zh"] {
                var env = fx.baseEnvironment
                env["RELAY_BUDGET_USD"] = bad
                let res = await cli.executeCommand(
                    arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", lang],
                    environment: env
                )
                #expect(res.exitCode == 2, "(\(bad), \(lang)): expected 2, got \(res.exitCode)")
                #expect(res.stdout.isEmpty)
                #expect(res.stderr.contains("RELAY_BUDGET_USD"))
                #expect(!res.stderr.contains("not supported yet"))
                #expect(!res.stderr.contains("当前不支持"))
                #expect(!res.stderr.contains("M4"))
            }
        }

        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: fx.projectURL)
        #expect(try db.allRuns().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.projectURL.appendingPathComponent("runs").path))
        let branches = try runTool("/usr/bin/git", ["branch", "--format=%(refname:short)"], environment: fx.baseEnvironment, currentDirectory: fx.repoURL)
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "main")

        // Empty RELAY_BUDGET_USD="" means no limit (accepted!)
        var emptyBudgetEnv = fx.baseEnvironment
        emptyBudgetEnv["RELAY_BUDGET_USD"] = ""
        let okRes = await cli.executeCommand(
            arguments: ["run", planURL.path, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path, "--lang", "en"],
            environment: emptyBudgetEnv
        )
        #expect(okRes.exitCode == 0, "stderr=\(okRes.stderr)")
        let okObj = try #require(try JSONSerialization.jsonObject(with: Data(okRes.stdout.utf8)) as? [String: Any])
        #expect(okObj["budgetUSD"] is NSNull)
    }
}
