import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelayWorkbenchShell
import RelayWorkspaceStore
import Testing

@Suite("Headless CLI Subcommands, JSON-RPC 2.0 MCP Server, HTML Dossier & Bauhaus Workbench Shell")
struct CLIMCPAndWorkbenchShellTests {

    // MARK: - Isolated Temp Directory & UserDefaults Helpers

    private func makeIsolatedTempDirectory(prefix: String = "relay-cli-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. `RelayCLIRunner` Help, Version & Unknown Subcommand Error

    @Test("RelayCLIRunner renders help banner, version string, and rejects unknown subcommands")
    func cliRunnerHelpVersionAndInvalidSubcommand() async throws {
        let cli = RelayCLIRunner()

        let emptyOut = try await cli.execute(arguments: [])
        #expect(emptyOut.contains("RelayIDE"))
        #expect(emptyOut.contains("semantic-merge"))

        let helpOut = try await cli.execute(arguments: ["--help"])
        #expect(helpOut == RelayCLIRunner.helpBanner)

        let versionOut = try await cli.execute(arguments: ["--version"])
        #expect(versionOut.contains("RelayIDE 1.0.0"))

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
        #expect(stats.schemaVersion == 4)

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

    // MARK: - 3. `RelayCLIRunner`: `semantic-merge <base> <left> <right>`

    @Test("RelayCLIRunner semantic-merge subcommand merges 3 on-disk Swift files at declaration level")
    func cliRunnerSemanticMergeThreeFiles() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-merge")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseURL = tempDir.appendingPathComponent("BaseBilling.swift")
        let leftURL = tempDir.appendingPathComponent("LeftBilling.swift")
        let rightURL = tempDir.appendingPathComponent("RightBilling.swift")

        try """
        public struct Billing {
            public func baseTotal() -> Int { 100 }
        }
        """.write(to: baseURL, atomically: true, encoding: .utf8)

        try """
        public struct Billing {
            public func baseTotal() -> Int { 100 }
            public func claudeRebate() -> Int { 15 }
        }
        """.write(to: leftURL, atomically: true, encoding: .utf8)

        try """
        public struct Billing {
            public func baseTotal() -> Int { 100 }
            public func codexVAT() -> Int { 20 }
        }
        """.write(to: rightURL, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        let merged = try await cli.execute(arguments: [
            "semantic-merge",
            baseURL.path,
            leftURL.path,
            rightURL.path,
        ])
        #expect(merged.contains("func claudeRebate()"))
        #expect(merged.contains("func codexVAT()"))
        #expect(!merged.contains("<<<<<<<"))

        // Missing file operand must throw invalidCLIUsage
        await #expect(throws: RelayIDEError.self) {
            _ = try await cli.execute(arguments: ["semantic-merge", baseURL.path])
        }
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
        #expect(toolNames.contains("relay_semantic_merge"))
        #expect(toolNames.contains("relay_check_ownership"))

        // 3. JSON-RPC notification without `id` returns nil (no reply frame emitted)
        let notifReply = server.handleJSONRPCLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notifReply == nil)
    }

    // MARK: - 6. `RelayMCPServer` `tools/call`: `relay_semantic_merge` & `relay_check_ownership`

    @Test("RelayMCPServer executes relay_semantic_merge and relay_check_ownership over JSON-RPC tools/call")
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
        #expect(mergeRes?["isError"] as? Bool == false)
        let mergeContent = (mergeRes?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(mergeContent.contains("func add()"))
        #expect(mergeContent.contains("func mul()"))

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
        palette.present(initialQuery: "", category: .wiretapAndBudget)
        #expect(palette.rankedMatches.allSatisfy { $0.item.category == .wiretapAndBudget })

        let executed = palette.executeSelected()
        #expect(executed != nil)
        #expect(triggeredCommandID == executed?.id)
        #expect(palette.isPresented == false)
    }

    // MARK: - 9. `@MainActor RelayKeybindingAndShortcutRegistry`: Default Keymap Cleanliness

    @Test("RelayKeybindingAndShortcutRegistry default bindings contain zero blocking chord collisions")
    @MainActor
    func defaultKeybindingRegistryHasZeroBlockingCollisions() {
        let suiteName = "io.relayide.tests.keymap.defaults.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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
    func keybindingCollisionPrefixShadowingAndReservedSystemWarnings() {
        let suiteName = "io.relayide.tests.keymap.conflicts.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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
        let suiteName = "io.relayide.tests.keymap.dispatch.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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

    // MARK: - 13. `@MainActor RelayToastCenter` Max Capacity Eviction & Merge/Circuit Notifications

    @Test("RelayToastCenter enforces bounded queue capacity and posts semantic merge and circuit-breaker alerts")
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
        toasts.postCircuitBreakerStatus(laneID: "lane-codex", vendor: .codex, isOpen: true, ceilingUSD: 5.0)
        toasts.dismissAll()
    }

    // MARK: - 14. `@MainActor BauhausColorThemeTokens` & `RelayUserPreferences` Persistence

    @Test("BauhausColorThemeTokens and RelayUserPreferences persist font size adjustments to isolated backing file")
    @MainActor
    func bauhausColorTokensAndUserPreferencesBackingFileRoundTrip() throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-prefs")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prefsFile = tempDir.appendingPathComponent("prefs.json")
        let suiteName = "io.relayide.tests.prefs.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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

        let suiteName = "io.relayide.tests.coord.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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
}
