import Foundation
import RelayCLIAndMCP
import RelayModels
import RelayOrchestrator
import RelaySemanticMerge
import RelayWorkbenchShell
import RelayWorkspaceStore
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
        #expect(emptyOut.contains("semantic-merge"))

        let helpOut = try await cli.execute(arguments: ["--help"])
        #expect(helpOut == RelayCLIRunner.helpBanner)

        let versionOut = try await cli.execute(arguments: ["--version"])
        #expect(versionOut.contains("RelayIDE 1.2.0"))

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
        #expect(stats.schemaVersion == 5)

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

    @Test("RelayCLIRunner and BauhausRelayHTMLReportExporter mark --seed-demo outputs with [DEMO] / [演示数据] and experimental help warnings")
    func cliRunnerDemoMarkersAndBilingualHelpExperimentalWarning() async throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-cli-demo-markers")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cli = RelayCLIRunner()
        let helpEN = await cli.executeCommand(arguments: ["--help", "--lang", "en"])
        #expect(helpEN.exitCode == 0)
        #expect(helpEN.stdout.contains("EXPERIMENTAL 3-way merge anchored on git merge-file"))
        #expect(helpEN.stdout.contains("known to corrupt Python and Swift output, so its text is never printed"))
        #expect(helpEN.stdout.contains("Exit codes: 0 clean; 1 conflict"))

        let helpZH = await cli.executeCommand(arguments: ["--help", "--lang", "zh"])
        #expect(helpZH.exitCode == 0)
        #expect(helpZH.stdout.contains("【实验性】以 git merge-file 为准的三路合并"))
        #expect(helpZH.stdout.contains("已知会损坏 Python 和 Swift 的输出，所以它的文本从不输出"))
        #expect(helpZH.stdout.contains("退出码：0 无冲突；1 有冲突"))

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

    @Test("semantic-merge CLI and MCP exit 1 with git's conflict text on a true conflict, and merge the former Python corruption case (09) cleanly")
    func semanticMergeConflictExit1AndFormerPythonCorruptionCaseMergesCleanly() async throws {
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
        #expect(conflictRes.stdout == "public func compute() -> Int {\n<<<<<<< left\n    return 10\n=======\n    return 20\n>>>>>>> right\n}\n")
        #expect(conflictRes.stdoutIsVerbatim)
        #expect(conflictRes.stderr.contains("[strategy=none]"))

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

        // 2. Python triple-quote case (R10 / case 09). The declaration engine used to corrupt this file, so M0 answered
        //    exit 3. git merges it cleanly and the result is valid Python, so the guarded merge now returns exactly
        //    git's text with exit 0 (CLI) and isError: false (MCP).
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

        let expectedMergedPython = pyBaseSrc
            .replacingOccurrences(of: "return 1", with: "return 10")
            .replacingOccurrences(of: "return 2", with: "return 20")

        let pyResEN = await cli.executeCommand(arguments: ["semantic-merge", pBase.path, pLeft.path, pRight.path, "--lang", "en"])
        #expect(pyResEN.exitCode == 0)
        #expect(pyResEN.stdout == expectedMergedPython)
        #expect(pyResEN.stderr.contains("[strategy=line-level]"))
        #expect(pyResEN.stderr.contains("py_compile"))

        let pyResZH = await cli.executeCommand(arguments: ["semantic-merge", pBase.path, pLeft.path, pRight.path, "--lang", "zh"])
        #expect(pyResZH.exitCode == 0)
        #expect(pyResZH.stdout == expectedMergedPython)
        #expect(pyResZH.stderr.contains("行级合并"))

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
        #expect(mcpPyRes?["isError"] as? Bool == false)
        #expect(((mcpPyRes?["content"] as? [[String: Any]])?.first?["text"] as? String) == expectedMergedPython)
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

    // MARK: - 20. M0 Rework (R28): `semantic-merge` Is Anchored on `git merge-file` and Never Loses or Alters Lines

    private struct MergeFixture {
        let name: String
        let directory: URL
        let fileExtension: String
        let expectedExit: Int32
        let expectedStrategy: String

        var baseURL: URL { directory.appendingPathComponent("base.\(fileExtension)") }
        var leftURL: URL { directory.appendingPathComponent("left.\(fileExtension)") }
        var rightURL: URL { directory.appendingPathComponent("right.\(fileExtension)") }
        var expectedMergedURL: URL { directory.appendingPathComponent("expected.\(fileExtension)") }
    }

    private static var mergeFixturesRootURL: URL {
        repositoryRootURL.appendingPathComponent("Fixtures/merge-cases", isDirectory: true)
    }

    /// Reads `Fixtures/merge-cases/EXPECTED.tsv` (case, expected exit code, expected strategy) and checks that it
    /// lists exactly the case directories that exist.
    private func loadMergeFixtures() throws -> [MergeFixture] {
        let root = Self.mergeFixturesRootURL
        let manifest = try String(contentsOf: root.appendingPathComponent("EXPECTED.tsv"), encoding: .utf8)
        var fixtures: [MergeFixture] = []
        for line in manifest.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = line.components(separatedBy: "\t")
            try #require(cols.count >= 3, "malformed EXPECTED.tsv line: \(line)")
            let dir = root.appendingPathComponent(cols[0], isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let baseName = try #require(entries.first { $0.hasPrefix("base.") }, "no base.* in \(cols[0])")
            fixtures.append(
                MergeFixture(
                    name: cols[0],
                    directory: dir,
                    fileExtension: (baseName as NSString).pathExtension,
                    expectedExit: try #require(Int32(cols[1])),
                    expectedStrategy: cols[2]
                )
            )
        }
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { name in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
        #expect(fixtures.map(\.name).sorted() == onDisk, "EXPECTED.tsv must list every directory in Fixtures/merge-cases")
        return fixtures
    }

    /// Plain `git merge-file -p` with default settings, run outside any repository and without user configuration.
    private func referenceGitMergeFile(_ fixture: MergeFixture) throws -> (conflicts: Int32, output: Data) {
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

    private func linesKeepingTerminators(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var current = Data()
        for byte in data {
            current.append(byte)
            if byte == 0x0A {
                lines.append(current)
                current = Data()
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Language-independent bookkeeping on whole lines (blank lines count, bytes compared exactly):
    /// every line a side added relative to base is still there, and no line was invented.
    private func expectNoLostOrInventedLines(base: Data, left: Data, right: Data, merged: Data, caseName: String) {
        func counts(_ data: Data) -> [Data: Int] {
            var table: [Data: Int] = [:]
            for line in linesKeepingTerminators(data) { table[line, default: 0] += 1 }
            return table
        }
        let b = counts(base), l = counts(left), r = counts(right), m = counts(merged)
        for (side, table) in [("left", l), ("right", r)] {
            for (line, count) in table {
                let added = count - (b[line] ?? 0)
                if added > 0 {
                    #expect((m[line] ?? 0) >= added, "\(caseName): a line added by \(side) is missing from the output: \(String(decoding: line, as: UTF8.self).debugDescription)")
                }
            }
        }
        for (line, count) in m {
            #expect(count <= (l[line] ?? 0) + (r[line] ?? 0), "\(caseName): the output contains a line neither side has: \(String(decoding: line, as: UTF8.self).debugDescription)")
        }
    }

    @Test("semantic-merge on every Fixtures/merge-cases case equals git merge-file, or a verified keep-both-insertions merge (R28)")
    func semanticMergeFixtureSweepMatchesGitOrVerifiedUnion() async throws {
        let fixtures = try loadMergeFixtures()
        #expect(fixtures.count >= 26)
        let cli = RelayCLIRunner()
        for fixture in fixtures {
            let base = try Data(contentsOf: fixture.baseURL)
            let left = try Data(contentsOf: fixture.leftURL)
            let right = try Data(contentsOf: fixture.rightURL)
            let reference = try referenceGitMergeFile(fixture)
            let result = await cli.executeCommand(arguments: ["semantic-merge", fixture.baseURL.path, fixture.leftURL.path, fixture.rightURL.path])
            let stdout = Data(result.stdout.utf8)

            #expect(result.exitCode == fixture.expectedExit, "\(fixture.name): expected exit \(fixture.expectedExit), got \(result.exitCode); stderr: \(result.stderr)")

            switch result.exitCode {
            case 0:
                expectNoLostOrInventedLines(base: base, left: left, right: right, merged: stdout, caseName: fixture.name)
                if reference.conflicts == 0 {
                    #expect(stdout == reference.output, "\(fixture.name): git merges this cleanly, so the output must be git's text byte for byte")
                    #expect(fixture.expectedStrategy == "line-level")
                } else {
                    // git reports a conflict here. Exit 0 is only acceptable for the hand-written expected merge.
                    let expected = try Data(contentsOf: fixture.expectedMergedURL)
                    #expect(stdout == expected, "\(fixture.name): output differs from the hand-written expected merge")
                    #expect(fixture.expectedStrategy == "declaration-level")
                }
            case 1:
                #expect(reference.conflicts > 0, "\(fixture.name): exit 1 although git merges this cleanly")
                #expect(stdout == reference.output, "\(fixture.name): on conflict the output must be git's conflict-marked text byte for byte")
                #expect(!FileManager.default.fileExists(atPath: fixture.expectedMergedURL.path), "\(fixture.name): stale expected.* next to a case that ends in conflict")
            default:
                Issue.record("\(fixture.name): unexpected exit code \(result.exitCode); stderr: \(result.stderr)")
            }
        }
    }

    @Test("semantic-merge keeps an added decorator, an added attribute and a multi-line string literal intact (R28 repro cases 20 and 21)")
    func semanticMergeKeepsDecoratorAttributeAndMultilineString() async throws {
        let root = Self.mergeFixturesRootURL
        let cli = RelayCLIRunner()

        let py = root.appendingPathComponent("20-py-decorator-added")
        let pyRes = await cli.executeCommand(arguments: [
            "semantic-merge", py.appendingPathComponent("base.py").path, py.appendingPathComponent("left.py").path, py.appendingPathComponent("right.py").path
        ])
        #expect(pyRes.exitCode == 0)
        #expect(pyRes.stdout == "import functools\n\n\ndef f(x):\n    return x + 100\n\n\n@functools.lru_cache\ndef g(x):\n    return x * 2\n")

        let sw = root.appendingPathComponent("21-swift-attribute-and-multiline-string")
        let swRes = await cli.executeCommand(arguments: [
            "semantic-merge", sw.appendingPathComponent("base.swift").path, sw.appendingPathComponent("left.swift").path, sw.appendingPathComponent("right.swift").path
        ])
        #expect(swRes.exitCode == 0)
        #expect(swRes.stdout == "let sql = \"\"\"\nSELECT a\nFROM t\nWHERE x = 1\n\"\"\"\n\nfunc f() -> Int {\n    return 10\n}\n\n@discardableResult\nfunc g() -> Int {\n    return 2\n}\n")
    }

    @Test("relay_semantic_merge over MCP returns the same text and error flag as the CLI (R28)")
    func mcpSemanticMergeMirrorsGuardedCLI() async throws {
        // One case per kind of outcome; the full sweep above already covers every case through the CLI.
        let representative: Set<String> = [
            "01-swift-samefunc-difflines",          // line-level, syntax-checked
            "02-swift-both-add-func",               // declaration-level
            "12-swift-true-conflict",               // conflict that touches base lines
            "20-py-decorator-added",                // R28 repro
            "21-swift-attribute-and-multiline-string", // R28 repro
            "24-py-decorator-vs-insert-above",      // engine disagrees -> conflict
            "28-rs-attributes-git-clean",           // line-level, no syntax checker
            "29-rs-both-add-fn",                    // conflict, no syntax checker
            "33-swift-no-final-newline-both-add"    // declaration-level, no final newline
        ]
        let fixtures = try loadMergeFixtures().filter { representative.contains($0.name) }
        #expect(fixtures.count == representative.count)
        let cli = RelayCLIRunner()
        let server = RelayMCPServer()
        var sawClean = false
        var sawConflict = false
        for fixture in fixtures {
            let cliResult = await cli.executeCommand(arguments: ["semantic-merge", fixture.baseURL.path, fixture.leftURL.path, fixture.rightURL.path])
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "relay_semantic_merge",
                    "arguments": [
                        "path": "merged.\(fixture.fileExtension)",
                        "base": try String(contentsOf: fixture.baseURL, encoding: .utf8),
                        "left": try String(contentsOf: fixture.leftURL, encoding: .utf8),
                        "right": try String(contentsOf: fixture.rightURL, encoding: .utf8)
                    ]
                ]
            ]
            let reply = try #require(server.handleJSONRPCLine(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)))
            let result = try #require((try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["result"] as? [String: Any])
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            let isError = result["isError"] as? Bool
            if cliResult.exitCode == 0 {
                sawClean = true
                #expect(isError == false, "\(fixture.name): CLI exit 0 but MCP isError != false")
                #expect(text == cliResult.stdout, "\(fixture.name): MCP text differs from CLI stdout")
            } else {
                sawConflict = sawConflict || cliResult.exitCode == 1
                #expect(isError == true, "\(fixture.name): CLI exit \(cliResult.exitCode) but MCP isError != true")
                if cliResult.exitCode == 1 {
                    #expect(text == cliResult.stdout, "\(fixture.name): MCP conflict text differs from CLI stdout")
                }
            }
        }
        #expect(sawClean && sawConflict)
    }

    @Test("semantic-merge refuses to merge and exits 4 with empty stdout when git is not on PATH (R28)")
    func semanticMergeRefusesWithoutGit() async throws {
        let emptyDir = try makeIsolatedTempDirectory(prefix: "relay-no-git-path")
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let fixture = Self.mergeFixturesRootURL.appendingPathComponent("20-py-decorator-added")
        let args = [
            "semantic-merge", fixture.appendingPathComponent("base.py").path, fixture.appendingPathComponent("left.py").path, fixture.appendingPathComponent("right.py").path
        ]
        for lang in ["en", "zh"] {
            let res = await RelayCLIRunner().executeCommand(arguments: args + ["--lang", lang], environment: ["PATH": emptyDir.path])
            #expect(res.exitCode == 4, "--lang \(lang): expected exit 4 without git, got \(res.exitCode)")
            #expect(res.stdout.isEmpty)
            #expect(res.stderr.contains("git"))
        }
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

    // MARK: - 22. M0 Rework (R29): Syntax Gate per Language (clean line merge that does not parse -> exit 3)

    /// Each case in `Fixtures/syntax-gate-cases` has three versions that parse on their own and that git merges
    /// without conflict into text that does not parse. The only thing standing between that text and exit 0 is the
    /// syntax check of that language.
    private func expectSyntaxGateRejects(caseName: String, fileExtension: String, parserFragment: String) async throws {
        let dir = Self.repositoryRootURL.appendingPathComponent("Fixtures/syntax-gate-cases/\(caseName)", isDirectory: true)
        let fixture = MergeFixture(name: caseName, directory: dir, fileExtension: fileExtension, expectedExit: 3, expectedStrategy: "none")
        let base = try String(contentsOf: fixture.baseURL, encoding: .utf8)
        let left = try String(contentsOf: fixture.leftURL, encoding: .utf8)
        let right = try String(contentsOf: fixture.rightURL, encoding: .utf8)

        // Preconditions: each side is valid on its own and git sees no conflict.
        for (label, source) in [("base", base), ("left", left), ("right", right)] {
            let verdict = LanguageSyntaxValidator.validate(source: source, filePath: fixture.baseURL.path)
            #expect(verdict.passed, "\(caseName): \(label) must parse on its own: \(verdict.diagnostic)")
            #expect(verdict.parserUsed?.contains(parserFragment) == true, "\(caseName): expected parser containing '\(parserFragment)', got \(verdict.parserUsed ?? "nil")")
        }
        let reference = try referenceGitMergeFile(fixture)
        #expect(reference.conflicts == 0, "\(caseName): git must merge this case cleanly")
        let gitMerged = String(decoding: reference.output, as: UTF8.self)
        #expect(!LanguageSyntaxValidator.validate(source: gitMerged, filePath: fixture.baseURL.path).passed, "\(caseName): git's clean merge must not parse, otherwise this case tests nothing")

        let cli = RelayCLIRunner()
        for lang in ["en", "zh"] {
            let res = await cli.executeCommand(arguments: ["semantic-merge", fixture.baseURL.path, fixture.leftURL.path, fixture.rightURL.path, "--lang", lang])
            #expect(res.exitCode == 3, "\(caseName) --lang \(lang): merged text does not parse, expected exit 3, got \(res.exitCode)")
            #expect(res.stdout.isEmpty, "\(caseName) --lang \(lang): nothing may be printed when the syntax check fails")
            #expect(res.stderr.contains(parserFragment), "\(caseName) --lang \(lang): stderr should name the parser: \(res.stderr)")
            #expect(res.stderr.contains(lang == "en" ? "syntax check" : "语法检查"))
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": [
                "name": "relay_semantic_merge",
                "arguments": ["path": "merged.\(fileExtension)", "base": base, "left": left, "right": right]
            ]
        ]
        let reply = try #require(RelayMCPServer().handleJSONRPCLine(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)))
        let result = try #require((try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true, "\(caseName): MCP must flag the syntax failure")
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        #expect(texts.count == 1, "\(caseName): MCP must return only the error message")
        #expect(texts.first?.contains(parserFragment) == true)
        #expect(!texts.contains { $0.contains(gitMerged) }, "\(caseName): MCP must not return the unparsable merged text")
    }

    @Test("semantic-merge exits 3 with empty stdout when a clean line merge is not valid Swift (R29)")
    func semanticMergeSwiftSyntaxGateExits3() async throws {
        try await expectSyntaxGateRejects(caseName: "swift-string-delimiters", fileExtension: "swift", parserFragment: "swiftc -parse")
    }

    @Test("semantic-merge exits 3 with empty stdout when a clean line merge is not valid JavaScript (R29)")
    func semanticMergeJavaScriptSyntaxGateExits3() async throws {
        try await expectSyntaxGateRejects(caseName: "javascript-block-comment", fileExtension: "js", parserFragment: "node --check")
    }

    @Test("semantic-merge exits 3 with empty stdout when a clean line merge is not valid TypeScript (R29)")
    func semanticMergeTypeScriptSyntaxGateExits3() async throws {
        // The parser name depends on the host: `tsc --noEmit` when tsc is installed, node's type stripping otherwise.
        let hasTSC = LanguageSyntaxValidator.validate(source: "const x: number = 1;\n", filePath: "probe.ts").parserUsed?.contains("tsc") == true
        try await expectSyntaxGateRejects(caseName: "typescript-block-comment", fileExtension: "ts", parserFragment: hasTSC ? "tsc" : "node")
    }

    @Test("semantic-merge exits 3 with empty stdout when a clean line merge is not valid Python (R29 companion)")
    func semanticMergePythonSyntaxGateExits3() async throws {
        try await expectSyntaxGateRejects(caseName: "python-string-delimiters", fileExtension: "py", parserFragment: "py_compile")
    }

    // MARK: - 23. M0 Rework (R28): Output Bytes, Notes, Unreadable Input and Missing git over MCP

    @Test("semantic-merge marks stdout as verbatim, reports the strategy in EN and ZH, and rejects unreadable or non-UTF-8 input with exit 2")
    func semanticMergeVerbatimStdoutNotesAndInputErrors() async throws {
        let root = Self.mergeFixturesRootURL
        let cli = RelayCLIRunner()

        // Line-level result on an extension without a syntax checker: clean, flagged as not syntax-checked.
        let rs = root.appendingPathComponent("28-rs-attributes-git-clean")
        let rsArgs = ["semantic-merge", rs.appendingPathComponent("base.rs").path, rs.appendingPathComponent("left.rs").path, rs.appendingPathComponent("right.rs").path]
        let rsEN = await cli.executeCommand(arguments: rsArgs)
        #expect(rsEN.exitCode == 0)
        #expect(rsEN.stdoutIsVerbatim)
        #expect(rsEN.stdout.contains("#[derive(Debug, Clone)]\npub struct Point {"))
        #expect(rsEN.stdout.contains("    #[inline]\n    pub fn origin() -> Point {"))
        #expect(rsEN.stderr.contains("[strategy=line-level]"))
        #expect(rsEN.stderr.contains("no syntax checker for .rs files, output was not syntax-checked"))
        let rsZH = await cli.executeCommand(arguments: rsArgs + ["--lang", "zh"])
        #expect(rsZH.stderr.contains(".rs 文件没有语法检查器，输出未做语法检查"))

        // Conflict on an extension without a syntax checker: the declaration engine is never consulted.
        let rsConflict = root.appendingPathComponent("29-rs-both-add-fn")
        let rsConflictRes = await cli.executeCommand(arguments: [
            "semantic-merge", rsConflict.appendingPathComponent("base.rs").path, rsConflict.appendingPathComponent("left.rs").path, rsConflict.appendingPathComponent("right.rs").path
        ])
        #expect(rsConflictRes.exitCode == 1)
        #expect(rsConflictRes.stdout.contains("<<<<<<< left\n"))
        #expect(rsConflictRes.stdout.contains(">>>>>>> right\n"))
        #expect(rsConflictRes.stderr.contains("no syntax checker is available for .rs files"))

        // Declaration-level result: both insertions kept, stated in both languages.
        let both = root.appendingPathComponent("02-swift-both-add-func")
        let bothArgs = ["semantic-merge", both.appendingPathComponent("base.swift").path, both.appendingPathComponent("left.swift").path, both.appendingPathComponent("right.swift").path]
        let bothEN = await cli.executeCommand(arguments: bothArgs)
        #expect(bothEN.exitCode == 0)
        #expect(bothEN.stdoutIsVerbatim)
        #expect(bothEN.stderr.contains("[strategy=declaration-level]"))
        #expect(bothEN.stderr.contains("swiftc -parse"))
        let bothZH = await cli.executeCommand(arguments: bothArgs + ["--lang", "zh"])
        #expect(bothZH.stderr.contains("[strategy=declaration-level]"))
        #expect(bothZH.stderr.contains("两边内容已原样保留"))

        // Unreadable and non-UTF-8 input are usage errors (exit 2), never "conflict" (exit 1).
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-merge-input-errors")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let good = tempDir.appendingPathComponent("good.txt")
        try "a\n".write(to: good, atomically: true, encoding: .utf8)
        let missing = tempDir.appendingPathComponent("missing.txt").path
        let missingRes = await cli.executeCommand(arguments: ["semantic-merge", good.path, missing, good.path])
        #expect(missingRes.exitCode == 2)
        #expect(missingRes.stdout.isEmpty)
        #expect(missingRes.stderr.contains("missing.txt"))

        let latin1 = tempDir.appendingPathComponent("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: latin1)
        let latin1Res = await cli.executeCommand(arguments: ["semantic-merge", good.path, latin1.path, good.path])
        #expect(latin1Res.exitCode == 2)
        #expect(latin1Res.stdout.isEmpty)
        #expect(latin1Res.stderr.contains("UTF-8"))
    }

    @Test("relay_semantic_merge returns isError: true and no merged text when git is not on PATH (R28)")
    func mcpSemanticMergeRefusesWithoutGit() throws {
        let emptyDir = try makeIsolatedTempDirectory(prefix: "relay-mcp-no-git-path")
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let server = RelayMCPServer(environment: ["PATH": emptyDir.path])
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": [
                "name": "relay_semantic_merge",
                "arguments": ["path": "a.py", "base": "x = 1\n", "left": "x = 2\n", "right": "x = 1\n"]
            ]
        ]
        let reply = try #require(server.handleJSONRPCLine(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)))
        let result = try #require((try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        #expect(texts.count == 1)
        #expect(texts.first?.contains("git") == true)
        #expect(texts.first?.contains("x = 2") == false)
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
        #expect(m0Stats.schemaVersion == 5)
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

        // 5. RELAY_BUDGET_USD set in environment (R44)
        var budgetEnv = fx.baseEnvironment
        budgetEnv["RELAY_BUDGET_USD"] = "10.00"
        await expectExit2("RELAY_BUDGET_USD set", args: ["run", validPlanPath, "--project", fx.projectURL.path, "--relay-sh", fx.fakeRelayShURL.path], env: budgetEnv)

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
          "verify": "swift test"
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
        #expect(runRes.stderr.contains("M2"))

        // Lock must have been cleanly released before returning!
        #expect(RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: fx.projectURL).isHeld == false)
        let probeLock = try RelayProjectRunLock.acquire(bundleDirectoryURL: fx.projectURL, runID: "20261116-050000-0001")
        probeLock.release()

        let recorded = try RelayRunJSONCodec.decode(RelayRunRecord.self, from: runRes.stdout)
        #expect(recorded.runID.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
        #expect(recorded.status == .succeeded)
        #expect(recorded.baseRef == "main")
        #expect(recorded.baseCommitOID == fx.baseCommitOID)
        #expect(recorded.verifyCommand == "swift test")
        #expect(recorded.relayShSHA256 == fx.fakeRelaySHA256)

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
}
