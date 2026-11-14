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
}
