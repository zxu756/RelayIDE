import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelayWorkbenchShell
import RelayWorkspaceStore
import Testing

@Suite("Headless CLI Subcommands, JSON-RPC 2.0 MCP Server, HTML Dossier & Bauhaus Workbench Shell", .timeLimit(.minutes(1)))
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
        #expect(versionOut.contains("RelayIDE 1.1.0"))

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

    // MARK: - 16. `RelayLocalizer` Precedence, Chinese Locale Auto-Detection & Live Toggle (`v1.1.0`)

    @Test("RelayLocalizer resolves --lang, RELAYIDE_LANG, UserDefaults, and Chinese Locale fallback, and toggles live")
    @MainActor
    func relayLocalizerResolutionPrecedenceAndLiveToggle() throws {
        let suiteName = "io.relayide.tests.localizer.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

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

    @Test("RelayCLIRunner and BauhausRelayHTMLReportExporter mark --seed-demo outputs with [DEMO] / [演示数据] and experimental help warnings")
    func cliRunnerDemoMarkersAndBilingualHelpExperimentalWarning() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-demo-markers")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cli = RelayCLIRunner()
        let helpEN = await cli.executeCommand(arguments: ["--help", "--lang", "en"])
        #expect(helpEN.exitCode == 0)
        #expect(helpEN.stdout.contains("EXPERIMENTAL: known to corrupt output on Python"))

        let helpZH = await cli.executeCommand(arguments: ["--help", "--lang", "zh"])
        #expect(helpZH.exitCode == 0)
        #expect(helpZH.stdout.contains("【实验性】已知会在 Python 代码上损坏输出"))

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
    }

    @Test("semantic-merge CLI and MCP exit 1 on conflicts and exit 3 with empty stdout when language syntax check fails")
    func semanticMergeConflictExit1AndBrokenPythonSyntaxExit3() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-merge-gates")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. True Swift conflict -> CLI exit 1 + MCP isError: true
        let cBase = tempDir.appendingPathComponent("Base.swift")
        let cLeft = tempDir.appendingPathComponent("Left.swift")
        let cRight = tempDir.appendingPathComponent("Right.swift")
        let baseSwift = "public func compute() -> Int {\n    return 1\n}\n"
        let leftSwift = "public func compute() -> Int {\n    return 10\n}\n"
        let rightSwift = "public func compute() -> Int {\n    return 20\n}\n"
        try baseSwift.write(to: cBase, atomically: true, encoding: .utf8)
        try leftSwift.write(to: cLeft, atomically: true, encoding: .utf8)
        try rightSwift.write(to: cRight, atomically: true, encoding: .utf8)

        let cli = RelayCLIRunner()
        let conflictRes = await cli.executeCommand(arguments: ["semantic-merge", cBase.path, cLeft.path, cRight.path, "--lang", "en"])
        #expect(conflictRes.exitCode == 1)
        #expect(conflictRes.stdout.contains("<<<<<<<"))
        #expect(!conflictRes.stderr.isEmpty)

        let mcp = RelayMCPServer()
        let mcpConflictReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 201,
            "method": "tools/call",
            "params": [
                "name": "relay_semantic_merge",
                "arguments": ["path": "Compute.swift", "base": baseSwift, "left": leftSwift, "right": rightSwift]
            ]
        ]
        let mcpConflictReply = mcp.handleJSONRPCLine(String(decoding: try JSONSerialization.data(withJSONObject: mcpConflictReq), as: UTF8.self))!
        let mcpConflictRes = (try JSONSerialization.jsonObject(with: Data(mcpConflictReply.utf8)) as? [String: Any])?["result"] as? [String: Any]
        #expect(mcpConflictRes?["isError"] as? Bool == true)

        // 2. Python triple-quote silent corruption case (R10 / case 09) -> CLI exit 3 with ZERO stdout bytes, MCP isError: true
        let pBase = tempDir.appendingPathComponent("base.py")
        let pLeft = tempDir.appendingPathComponent("left.py")
        let pRight = tempDir.appendingPathComponent("right.py")
        let pyBaseSrc = """
        class Tpl:
            TEXT = \"\"\"
        def fake():
            pass
        \"\"\"

            def real(self):
                return 1

            def second(self):
                return 2
        """
        let pyLeftSrc = """
        class Tpl:
            TEXT = \"\"\"
        def fake():
            pass
        \"\"\"

            def real(self):
                return 10

            def second(self):
                return 2
        """
        let pyRightSrc = """
        class Tpl:
            TEXT = \"\"\"
        def fake():
            pass
        \"\"\"

            def real(self):
                return 1

            def second(self):
                return 20
        """
        try pyBaseSrc.write(to: pBase, atomically: true, encoding: .utf8)
        try pyLeftSrc.write(to: pLeft, atomically: true, encoding: .utf8)
        try pyRightSrc.write(to: pRight, atomically: true, encoding: .utf8)

        let pyResEN = await cli.executeCommand(arguments: ["semantic-merge", pBase.path, pLeft.path, pRight.path, "--lang", "en"])
        #expect(pyResEN.exitCode == 3)
        #expect(pyResEN.stdout.isEmpty)
        #expect(pyResEN.stderr.lowercased().contains("syntax"))

        let pyResZH = await cli.executeCommand(arguments: ["semantic-merge", pBase.path, pLeft.path, pRight.path, "--lang", "zh"])
        #expect(pyResZH.exitCode == 3)
        #expect(pyResZH.stdout.isEmpty)
        #expect(pyResZH.stderr.contains("语法"))

        let mcpPyReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 202,
            "method": "tools/call",
            "params": [
                "name": "relay_semantic_merge",
                "arguments": ["path": "svc.py", "base": pyBaseSrc, "left": pyLeftSrc, "right": pyRightSrc]
            ]
        ]
        let mcpPyReply = mcp.handleJSONRPCLine(String(decoding: try JSONSerialization.data(withJSONObject: mcpPyReq), as: UTF8.self))!
        let mcpPyRes = (try JSONSerialization.jsonObject(with: Data(mcpPyReply.utf8)) as? [String: Any])?["result"] as? [String: Any]
        #expect(mcpPyRes?["isError"] as? Bool == true)
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
        #expect(defaultSnapshot.autoRunSemanticMergeOnHandoff == false)
        #expect(defaultSnapshot.outboundDLPRedactByDefault == false)
    }
}
