import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelayWorkspaceStore
import Testing

@Suite("JavaScriptCore Guardrail Plugins, Scratchpad, Policy Packs, DAG Waves, CPM & Failover")
struct PluginSDKAndOrchestratorCPMTests {

    // MARK: - 1. All 4 Built-In Guardrail Plugins Execution & Detection

    @Test("RelayJavaScriptPluginHost evaluates all 4 built-in guardrail plugins and produces findings + commit title")
    func builtInFourGuardrailPluginsExecutionAndFindings() throws {
        let builtIns = BuiltInRelayGuardrailPlugins.all
        #expect(builtIns.count == 4)

        let host = RelayJavaScriptPluginHost(plugins: builtIns)
        let leakedKey = "sk-ant-api03-" + String(repeating: "Z8pQ", count: 24)

        // Provide dirty files that trigger:
        // 1) secretAndPathLeakBlocker (API key + /Users/ hardcoded path)
        // 2) verificationTestGateEnforcer (Sources modified in lane-codex with ZERO Tests/* touched)
        // 3) conventionalCommitSynthesizer (synthesizes conventional commit title)
        // 4) tokenBudgetAnomalyAuditor (lane-claude at 95% budget utilization)
        let modifiedFilesByLane: [String: [String: String]] = [
            "lane-claude": [
                "Sources/Auth/KeyLoader.swift": """
                public let devPath = "/Users/developer/secret.env"
                public let apiKey = "\(leakedKey)"
                """,
                "Tests/AuthTests.swift": "import Testing\n",
            ],
            "lane-codex": [
                "Sources/Transport/HTTP3Ring.swift": "public struct HTTP3Ring {}\n"
            ],
        ]

        let accounts = [
            LaneBudgetAccount(
                laneID: "lane-claude",
                vendor: .claudeCode,
                requestCount: 14,
                inputTokens: 90_000,
                cachedTokens: 0,
                outputTokens: 25_000,
                spentUSD: 4.85,
                ceilingUSD: 5.00,
                circuitOpen: false
            ),
            LaneBudgetAccount(
                laneID: "lane-codex",
                vendor: .codex,
                requestCount: 3,
                spentUSD: 0.90,
                ceilingUSD: 5.00,
                circuitOpen: false
            ),
        ]

        let outputs = try host.evaluateEnabledPlugins(
            modifiedFilesByLane: modifiedFilesByLane,
            budgetAccounts: accounts
        )
        #expect(outputs.count == 4)

        let allFindings = outputs.flatMap(\.findings)
        #expect(allFindings.contains { $0.severity == .blocker })
        #expect(allFindings.contains { $0.severity == .warning || $0.severity == .advisory })

        let commitTitle = outputs.compactMap(\.synthesizedCommitTitle).first
        #expect(commitTitle != nil)
        #expect(commitTitle?.contains(":") == true)
    }

    // MARK: - 2. `RelayJavaScriptPluginHost` Capability Sandboxing & Veto Rejection

    @Test("RelayJavaScriptPluginHost enforces capability sandboxing and rejects BLOCKER findings without vetoMergeGate")
    func jsPluginHostCapabilitySandboxingAndVetoGateEnforcement() throws {
        let host = RelayJavaScriptPluginHost(plugins: [])

        // Plugin 1: Has NO capabilities, tries to read diffs & budgets -> receives empty arrays `[]`
        let zeroCapManifest = RelayPluginManifest(
            id: "test.zero-caps",
            name: "Zero Caps Inspector",
            version: "1.0.0",
            summary: "Verifies empty host bridges without capabilities",
            capabilities: [],
            isBuiltIn: false,
            isEnabled: true,
            scriptSource: """
            function runRelayGuardrail() {
                var diffs = RelayHost.getDiffs();
                var budgets = RelayHost.getBudgets();
                RelayHost.log("diffs=" + diffs.length + ",budgets=" + budgets.length);
            }
            """
        )

        let outZero = try host.executeSinglePlugin(
            manifest: zeroCapManifest,
            modifiedFilesByLane: ["lane-claude": ["Sources/A.swift": "let a = 1"]],
            budgetAccounts: [LaneBudgetAccount(laneID: "lane-claude", vendor: .claudeCode, spentUSD: 1.0, ceilingUSD: 5.0)]
        )
        #expect(outZero.logs.contains("diffs=0,budgets=0"))

        // Plugin 2: Has `.inspectDiffs` ONLY, attempts to emit a `"BLOCKER"` finding without `.vetoMergeGate` -> MUST throw!
        let unauthorizedVetoManifest = RelayPluginManifest(
            id: "test.unauthorized-blocker",
            name: "Unauthorized Blocker",
            version: "1.0.0",
            summary: "Tries to veto merge without merge.veto capability",
            capabilities: [.inspectDiffs],
            isBuiltIn: false,
            isEnabled: true,
            scriptSource: """
            function runRelayGuardrail() {
                RelayHost.emitFinding("BLOCKER", "lane-claude", "Sources/A.swift", "Illegal Veto", "Should fail capability gate");
            }
            """
        )

        #expect(throws: RelayIDEError.self) {
            _ = try host.executeSinglePlugin(
                manifest: unauthorizedVetoManifest,
                modifiedFilesByLane: [:],
                budgetAccounts: []
            )
        }
    }

    // MARK: - 3. Plugin Enablement Toggle in `RelayJavaScriptPluginHost`

    @Test("RelayJavaScriptPluginHost skips disabled plugins when setPluginEnabled(false) is applied")
    func jsPluginHostEnableDisableToggle() throws {
        let host = RelayJavaScriptPluginHost()
        let firstID = host.listPlugins()[0].id
        host.setPluginEnabled(id: firstID, isEnabled: false)

        let outputs = try host.evaluateEnabledPlugins(modifiedFilesByLane: [:], budgetAccounts: [])
        #expect(outputs.count == 3)
        #expect(!outputs.contains { $0.pluginID == firstID })
    }

    // MARK: - 4. `RelayJSScratchpadEvaluator` Console Capture, Capability Denials & Microsecond Profiler

    @Test("RelayJSScratchpadEvaluator captures console output, logs capability denials, downgrades BLOCKER, and records latency percentiles")
    func jsScratchpadEvaluatorConsoleDenialsAndMicroProfiler() {
        let profiler = RelayPluginMicrosecondProfiler(maxSamplesPerPlugin: 64, latencyBudgetMicros: 50_000.0)
        let traceRing = RelayPluginHookTraceRingBuffer(capacity: 64)
        let evaluator = RelayJSScratchpadEvaluator(profiler: profiler, traceBuffer: traceRing)

        let script = """
        function runRelayGuardrail() {
            console.log("Inspecting workspace from scratchpad");
            var unauthorizedDiffs = RelayHost.getDiffs(); // denied: not in grantedCapabilities
            RelayHost.emitFinding(
                "BLOCKER",
                "lane-1",
                "Sources/X.swift",
                "Draft Rule Hit",
                "Downgraded to WARNING without vetoMergeGate"
            );
        }
        """

        // Run 5 times to populate p50/p95/p99 latency percentile samples
        var lastResult: RelayScratchpadEvaluationResult?
        for _ in 0..<5 {
            lastResult = evaluator.evaluateScratchpad(
                pluginID: "scratchpad.demo",
                pluginName: "Scratchpad Demo",
                scriptSource: script,
                grantedCapabilities: [], // Neither inspectDiffs nor vetoMergeGate granted
                modifiedFilesByLane: ["lane-1": ["Sources/X.swift": "let x = 1"]]
            )
        }

        #expect(lastResult?.succeeded == true)
        #expect(lastResult?.consoleOutput.contains { $0.message.contains("Inspecting workspace") } == true)
        #expect(!(lastResult?.capabilityDenials.isEmpty ?? true))
        // BLOCKER must be downgraded to .warning in scratchpad when .vetoMergeGate is absent!
        #expect(lastResult?.findings.first?.severity == .warning)

        let summary = profiler.summary(forPlugin: "scratchpad.demo")
        #expect(summary != nil)
        #expect(summary?.sampleCount == 5)
        #expect((summary?.p95Micros ?? 0) >= (summary?.p50Micros ?? 0))
    }

    // MARK: - 5. `BuiltInLifecycleHookGuardrails` Dispatch (`onCommandSpawn`, `onFileTouch`, `onWiretapRequest`)

    @Test("BuiltInLifecycleHookGuardrails veto destructive shell commands, fence territory touches, and redact wiretap secrets")
    func builtInLifecycleHooksCommandFenceAndWiretapRedaction() {
        let traceRing = RelayPluginHookTraceRingBuffer(capacity: 64)
        let evaluator = RelayJSScratchpadEvaluator(traceBuffer: traceRing)
        let lifecyclePlugins = BuiltInLifecycleHookGuardrails.allLifecyclePlugins
        #expect(lifecyclePlugins.count >= 3)

        // 1. Destructive command spawn (`git reset --hard`) -> VETO
        let spawnEvent = RelayLifecycleHookEvent.commandSpawn(
            RelayCommandSpawnContext(
                laneID: "lane-codex",
                vendor: .codex,
                executablePath: "/usr/bin/git",
                arguments: ["reset", "--hard", "HEAD~3"],
                workingDirectory: "/tmp/wt"
            )
        )
        let spawnResults = evaluator.dispatchLifecycleHook(spawnEvent, across: lifecyclePlugins)
        #expect(spawnResults.contains { $0.hookDecision == .veto })

        // 2. Out-of-bounds file touch (`Secrets/prod.pem` when forbiddenGlobs contains `Secrets/**`) -> VETO
        let touchEvent = RelayLifecycleHookEvent.fileTouch(
            RelayFileTouchContext(
                laneID: "lane-vibe",
                vendor: .mistralVibe,
                relativePath: "Secrets/prod.pem",
                operation: .modified,
                allowedGlobs: ["Tests/**"],
                forbiddenGlobs: ["Secrets/**"]
            )
        )
        let touchResults = evaluator.dispatchLifecycleHook(touchEvent, across: lifecyclePlugins)
        #expect(touchResults.contains { $0.hookDecision == .veto })

        // 3. Wiretap outbound prompt containing synthetic API key -> REDACT or VETO
        let fakeSecret = "sk-ant-api03-" + String(repeating: "m4Nv", count: 24)
        let wiretapEvent = RelayLifecycleHookEvent.wiretapRequest(
            RelayWiretapRequestContext(
                laneID: "lane-claude",
                vendor: .claudeCode,
                providerHost: "api.anthropic.com",
                modelIdentifier: "claude-sonnet-4-5",
                promptSnippet: "Authorization key is \(fakeSecret)",
                spentUSD: 0.40,
                ceilingUSD: 5.00
            )
        )
        let wiretapResults = evaluator.dispatchLifecycleHook(wiretapEvent, across: lifecyclePlugins)
        #expect(wiretapResults.contains { $0.hookDecision == .redact || $0.hookDecision == .veto || $0.hookDecision == .warn })
        #expect(traceRing.count >= 3)
    }

    // MARK: - 6. `RelayPluginConfigSchemaValidator` Defaults & Constraint Diagnostics

    @Test("RelayPluginConfigSchemaValidator materializes defaults and reports numeric/enum/regex violations")
    func pluginConfigSchemaValidationAndDefaults() {
        let schema = PluginConfigSchema(
            pluginID: "custom.budget-guard",
            fields: [
                PluginConfigFieldSpec(
                    key: "warnRatio",
                    fieldType: .number,
                    isRequired: true,
                    summary: "Warning ratio",
                    defaultValue: .number(0.80),
                    minimumNumeric: 0.10,
                    maximumNumeric: 1.00
                ),
                PluginConfigFieldSpec(
                    key: "mode",
                    fieldType: .string,
                    isRequired: true,
                    summary: "Enforcement mode",
                    defaultValue: .string("warn"),
                    allowedEnumValues: ["warn", "block"]
                ),
                PluginConfigFieldSpec(
                    key: "ticketPrefix",
                    fieldType: .string,
                    isRequired: false,
                    summary: "JIRA prefix",
                    defaultValue: .string("RELAY-"),
                    regexPattern: #"^[A-Z]+-$"#
                ),
            ],
            allowUnknownKeys: false
        )

        let validator = RelayPluginConfigSchemaValidator()

        // Empty raw config materializes valid defaults with zero diagnostics
        let validDefaults = validator.validateAndMaterializeDefaults(rawConfig: [:], against: schema)
        #expect(validDefaults.diagnostics.isEmpty)
        #expect(validDefaults.resolvedConfig["warnRatio"] == .number(0.80))
        #expect(validDefaults.resolvedConfig["mode"] == .string("warn"))

        // Out-of-range number + invalid enum + bad regex + unknown key -> diagnostics reported
        let invalid = validator.validateAndMaterializeDefaults(
            rawConfig: [
                "warnRatio": .number(2.50),
                "mode": .string("yolo"),
                "ticketPrefix": .string("bad_123"),
                "unexpectedKey": .boolean(true),
            ],
            against: schema
        )
        #expect(invalid.diagnostics.count >= 3)
    }

    // MARK: - 7. `.relay-guardrails.json` Policy Pack File Round-Trip, SHA-256 Digest & Diff

    @Test("RelayGuardrailsPolicyPackCodec exports and imports .relay-guardrails.json with SHA-256 script verification and diffing")
    func guardrailsPolicyPackFileRoundTripDigestAndDiff() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-policypack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baselinePack = RelayGuardrailsPolicyPack.defaultIndustrialPack()
        #expect(!baselinePack.entries.isEmpty)
        #expect(baselinePack.entries.allSatisfy { $0.isScriptDigestValid })

        let codec = RelayGuardrailsPolicyPackCodec()
        let packURL = tempDir.appendingPathComponent(".relay-guardrails.json")
        try codec.exportToFile(baselinePack, fileURL: packURL)

        let imported = try codec.importFromFile(fileURL: packURL, verifyScriptDigests: true)
        #expect(imported.pack.packID == baselinePack.packID)
        #expect(imported.pack.entries.count == baselinePack.entries.count)

        // Apply pack to a fresh host
        let host = RelayJavaScriptPluginHost(plugins: [])
        codec.apply(imported.pack, to: host)
        #expect(!host.listPlugins().isEmpty)

        // Mutate candidate pack (toggle first plugin + append custom plugin) and verify PolicyPackDiffSummary
        var modifiedEntries = baselinePack.entries
        var toggledFirst = modifiedEntries[0].manifest
        toggledFirst.isEnabled.toggle()
        modifiedEntries[0] = RelayPolicyPackPluginEntry(
            manifest: toggledFirst,
            configSchema: modifiedEntries[0].configSchema,
            configuration: modifiedEntries[0].configuration
        )
        let extraManifest = RelayPluginManifest(
            id: "org.custom.extra",
            name: "Extra Check",
            version: "1.0.0",
            summary: "Custom policy rule",
            capabilities: [.inspectDiffs],
            isBuiltIn: false,
            isEnabled: true,
            scriptSource: "function evaluate(ctx) { return { findings: [] }; }"
        )
        modifiedEntries.append(RelayPolicyPackPluginEntry(manifest: extraManifest))

        let candidatePack = RelayGuardrailsPolicyPack(
            packID: baselinePack.packID,
            packName: baselinePack.packName,
            summary: baselinePack.summary,
            entries: modifiedEntries
        )
        let diff = codec.diff(baseline: baselinePack, candidate: candidatePack)
        #expect(diff.addedPluginIDs == ["org.custom.extra"])
        #expect(diff.toggledEnablementPluginIDs == [toggledFirst.id])

        // Tampering with exported JSON scriptSource without updating scriptSHA256Hex must fail strict import!
        var rawString = try String(contentsOf: packURL, encoding: .utf8)
        rawString = rawString.replacingOccurrences(of: "RelayHost", with: "RelayHost /*TAMPERED*/")
        let tamperedData = Data(rawString.utf8)
        #expect(throws: (any Error).self) {
            _ = try codec.importData(tamperedData, verifyScriptDigests: true)
        }
    }

    // MARK: - 8. `MultiVendorDAGOrchestrator` Kahn Topological Waves & Cycle Rejection

    @Test("MultiVendorDAGOrchestrator computes Kahn parallel waves and rejects cyclic task dependencies")
    func dagOrchestratorTopologicalWavesAndCycleRejection() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-dag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: tempDir.appendingPathComponent("DAG.relayide"))
        let orchestrator = MultiVendorDAGOrchestrator(database: db)

        // Diamond DAG:
        // Wave 0: [t-arch]
        // Wave 1: [t-codex, t-agy] (run in parallel!)
        // Wave 2: [t-vibe] (depends on both t-codex and t-agy)
        let diamondDAG = RelayDAGSpec(
            name: "Diamond Campaign",
            repositoryPath: tempDir.path,
            tasks: [
                RelayTaskNode(id: "t-arch", title: "Arch", vendor: .claudeCode, laneID: "l-claude", promptBrief: "Spec"),
                RelayTaskNode(id: "t-codex", title: "Impl", vendor: .codex, laneID: "l-codex", dependsOnTaskIDs: ["t-arch"], promptBrief: "Code"),
                RelayTaskNode(id: "t-agy", title: "Docs", vendor: .antigravity, laneID: "l-agy", dependsOnTaskIDs: ["t-arch"], promptBrief: "Docs"),
                RelayTaskNode(id: "t-vibe", title: "Verify", vendor: .mistralVibe, laneID: "l-vibe", dependsOnTaskIDs: ["t-codex", "t-agy"], promptBrief: "Tests"),
            ]
        )

        let waves = try orchestrator.computeTopologicalWaves(for: diamondDAG)
        #expect(waves.count == 3)
        #expect(waves[0].map(\.id) == ["t-arch"])
        #expect(Set(waves[1].map(\.id)) == Set(["t-codex", "t-agy"]))
        #expect(waves[2].map(\.id) == ["t-vibe"])

        // Cyclic DAG: A -> B -> C -> A must throw RelayIDEError.cyclicTaskDependency!
        let cyclicDAG = RelayDAGSpec(
            name: "Broken Cycle",
            repositoryPath: tempDir.path,
            tasks: [
                RelayTaskNode(id: "A", title: "A", vendor: .claudeCode, laneID: "l1", dependsOnTaskIDs: ["C"], promptBrief: ""),
                RelayTaskNode(id: "B", title: "B", vendor: .codex, laneID: "l2", dependsOnTaskIDs: ["A"], promptBrief: ""),
                RelayTaskNode(id: "C", title: "C", vendor: .mistralVibe, laneID: "l3", dependsOnTaskIDs: ["B"], promptBrief: ""),
            ]
        )
        #expect(throws: RelayIDEError.self) {
            _ = try orchestrator.computeTopologicalWaves(for: cyclicDAG)
        }
    }

    // MARK: - 9. `MultiVendorDAGOrchestrator` Headless Vendor CLI Invocation Construction

    @Test("MultiVendorDAGOrchestrator builds headless CLI argument vectors for Claude, Codex, Antigravity, and Vibe")
    func dagOrchestratorVendorHeadlessInvocations() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-invoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: tempDir.appendingPathComponent("Invoc.relayide"))
        let orchestrator = MultiVendorDAGOrchestrator(database: db)

        for vendor in [AgentVendor.claudeCode, .codex, .antigravity, .mistralVibe] {
            let task = RelayTaskNode(
                id: "t-\(vendor.rawValue)",
                title: "Run \(vendor.displayName)",
                vendor: vendor,
                laneID: "lane-\(vendor.rawValue)",
                promptBrief: "Execute zero-copy verification"
            )
            let invocation = orchestrator.buildHeadlessInvocation(for: task, worktreePath: tempDir.path)
            #expect(!invocation.executable.isEmpty)
            #expect(invocation.arguments.joined(separator: " ").contains("Execute zero-copy verification"))
        }
    }

    // MARK: - 10. `CriticalPathMethodAnalyzer` Slack, Critical Path & Parallel Speedup

    @Test("CriticalPathMethodAnalyzer calculates ES/EF/LS/LF, slack, critical path, and parallel speedup factor")
    func criticalPathMethodAnalyzerSlackAndSpeedupMath() throws {
        // Diamond DAG with known durations:
        // t1 (10s) -> t2 (40s, heavy Codex impl) -> t4 (15s)  ==> Path 1-2-4 = 65s (CRITICAL PATH, slack = 0)
        //          \> t3 (12s, fast AGY docs)    -/           ==> Path 1-3-4 = 37s (slack = 28s!)
        // Serial sum = 10 + 40 + 12 + 15 = 77s; Parallel makespan = 65s; Speedup = 77 / 65 = 1.1846x
        let tasks = [
            RelayTaskNode(id: "t1", title: "Spec", vendor: .claudeCode, laneID: "l-claude", promptBrief: ""),
            RelayTaskNode(id: "t2", title: "Heavy Impl", vendor: .codex, laneID: "l-codex", dependsOnTaskIDs: ["t1"], promptBrief: ""),
            RelayTaskNode(id: "t3", title: "Fast Docs", vendor: .antigravity, laneID: "l-agy", dependsOnTaskIDs: ["t1"], promptBrief: ""),
            RelayTaskNode(id: "t4", title: "Verify Gate", vendor: .mistralVibe, laneID: "l-vibe", dependsOnTaskIDs: ["t2", "t3"], promptBrief: ""),
        ]
        let durations: [String: Double] = [
            "t1": 10.0,
            "t2": 40.0,
            "t3": 12.0,
            "t4": 15.0,
        ]

        let analyzer = CriticalPathMethodAnalyzer()
        let report = try analyzer.analyze(tasks: tasks, durationOverridesSeconds: durations)

        #expect(report.criticalPathTaskIDs == ["t1", "t2", "t4"])
        #expect(abs(report.speedup.serialDurationSeconds - 77.0) < 0.001)
        #expect(abs(report.speedup.parallelMakespanSeconds - 65.0) < 0.001)
        #expect(report.speedup.theoreticalSpeedupFactor > 1.18)
        #expect(report.speedup.peakWaveConcurrency == 2)
        #expect(report.speedup.bottleneckTaskID == "t2")

        let schedT3 = report.nodeSchedules.first { $0.taskID == "t3" }!
        #expect(schedT3.isOnCriticalPath == false)
        #expect(abs(schedT3.earliestStartSeconds - 10.0) < 0.001)
        #expect(abs(schedT3.earliestFinishSeconds - 22.0) < 0.001)
        #expect(abs(schedT3.latestFinishSeconds - 50.0) < 0.001)
        #expect(abs(schedT3.totalSlackSeconds - 28.0) < 0.001)
    }

    // MARK: - 11. `VendorFailoverAndRetryController`: Quota Failover Handoff Routing

    @Test("VendorFailoverAndRetryController routes HTTP 429 quota exhaustion to standby vendor lane with handoff markdown")
    func vendorFailoverControllerRoutesQuotaExhaustionToStandbyVendor() {
        let controller = VendorFailoverAndRetryController(
            policy: VendorFailoverPolicyConfig(
                maxSameVendorRetries: 2,
                initialBackoffSeconds: 1.5,
                autoFailoverOnQuotaExhaustion: true
            )
        )

        let claudeTask = RelayTaskNode(
            id: "task-auth-refactor",
            title: "Refactor AuthSessionManager",
            vendor: .claudeCode,
            laneID: "lane-claude",
            promptBrief: "Implement HKDF subkey rotation"
        )

        let availableLanes = [
            ManagedWorktreeLane(
                id: "lane-claude",
                displayName: "Claude Primary",
                assignedVendor: .claudeCode,
                worktreePath: "/tmp/wt/claude",
                branchName: "relay/claude",
                baseCommitOID: "aaaa",
                headCommitOID: "aaaa"
            ),
            ManagedWorktreeLane(
                id: "lane-codex-standby",
                displayName: "Codex Standby",
                assignedVendor: .codex,
                worktreePath: "/tmp/wt/codex",
                branchName: "relay/codex",
                baseCommitOID: "aaaa",
                headCommitOID: "aaaa"
            ),
        ]

        // First HTTP 429 performs one exponential-backoff retry on the primary lane; persistent HTTP 429 triggers standby failover!
        let firstAttempt = controller.evaluateFailure(
            task: claudeTask,
            trigger: .vendorQuotaOrRateLimited(httpStatus: 429, providerMessage: "Anthropic tier rate limit exceeded"),
            availableLanes: availableLanes,
            budgetAccounts: [
                LaneBudgetAccount(laneID: "lane-codex-standby", vendor: .codex, spentUSD: 0.20, ceilingUSD: 10.0, circuitOpen: false)
            ],
            partialDirtyFiles: ["Sources/Auth/AuthSessionManager.swift"],
            terminalTailLines: ["Error 429: rate_limit_error"]
        )
        if case .retrySameLane(let attempt, _, _) = firstAttempt {
            #expect(attempt == 1)
        } else {
            Issue.record("Expected initial HTTP 429 retry before failover, got \(firstAttempt)")
        }

        let decision = controller.evaluateFailure(
            task: claudeTask,
            trigger: .vendorQuotaOrRateLimited(httpStatus: 429, providerMessage: "Anthropic tier rate limit exceeded"),
            availableLanes: availableLanes,
            budgetAccounts: [
                LaneBudgetAccount(laneID: "lane-codex-standby", vendor: .codex, spentUSD: 0.20, ceilingUSD: 10.0, circuitOpen: false)
            ],
            partialDirtyFiles: ["Sources/Auth/AuthSessionManager.swift"],
            terminalTailLines: ["Error 429: rate_limit_error"]
        )

        if case .failoverHandoff(let newVendor, let standbyLaneID, _, let handoffMarkdown) = decision {
            #expect(newVendor == .codex)
            #expect(standbyLaneID == "lane-codex-standby")
            #expect(handoffMarkdown.contains("AuthSessionManager.swift"))
        } else {
            Issue.record("Expected .failoverHandoff decision on persistent HTTP 429 quota exhaustion, got \(decision)")
        }
        #expect(controller.allAuditRecords().count == 2)
    }

    // MARK: - 12. `VendorFailoverAndRetryController`: Backoff Retry & Budget Pause/Resume

    @Test("VendorFailoverAndRetryController retries verification failures with diagnostics and pauses lane on budget trip")
    func vendorFailoverRetryBackoffAndBudgetPauseResume() {
        let controller = VendorFailoverAndRetryController(
            policy: VendorFailoverPolicyConfig(
                maxSameVendorRetries: 2,
                initialBackoffSeconds: 2.0,
                maxBackoffSeconds: 16.0,
                pauseLaneOnBudgetTripUnlessStandbyAllowed: true
            )
        )

        let task = RelayTaskNode(
            id: "task-ring",
            title: "Build Ring",
            vendor: .codex,
            laneID: "lane-codex",
            promptBrief: "Write ring"
        )
        let lanes = [
            ManagedWorktreeLane(
                id: "lane-codex",
                displayName: "Codex",
                assignedVendor: .codex,
                worktreePath: "/tmp/codex",
                branchName: "relay/codex",
                baseCommitOID: "0000",
                headCommitOID: "0000"
            )
        ]

        // 1. First verification failure -> retrySameLane(attempt: 1) with compiler diagnostic suffix
        let retry1 = controller.evaluateFailure(
            task: task,
            trigger: .verificationGateRejected(exitCode: 1, diagnosticSummary: "Ring.swift:42:8: error: missing return"),
            availableLanes: lanes
        )
        if case .retrySameLane(let attempt, let delay, let suffix) = retry1 {
            #expect(attempt == 1)
            #expect(delay >= 1.0)
            #expect(suffix?.contains("Ring.swift:42:8") == true)
        } else {
            Issue.record("Expected .retrySameLane on first verification gate failure")
        }

        // 2. Lane budget circuit tripped -> pauses lane awaiting operator approval
        let budgetDecision = controller.evaluateFailure(
            task: task,
            trigger: .laneBudgetCircuitTripped(spentUSD: 5.12, ceilingUSD: 5.00),
            availableLanes: lanes
        )
        if case .pauseLaneAwaitingOperator(let pausedLane, _) = budgetDecision {
            #expect(pausedLane == "lane-codex")
        } else {
            Issue.record("Expected .pauseLaneAwaitingOperator when budget trips")
        }
        #expect(controller.isLanePaused("lane-codex") == true)
        controller.resumePausedLane("lane-codex")
        #expect(controller.isLanePaused("lane-codex") == false)
    }

    // MARK: - 13. `VerificationCommandGateEvaluator` Live Shell Gate & Diagnostic Parser

    @Test("VerificationCommandGateEvaluator runs verification shell commands and parses compiler file:line:col errors")
    func verificationCommandGateEvaluatorExecutionAndDiagnosticParsing() async {
        let evaluator = VerificationCommandGateEvaluator(defaultTimeoutSeconds: 10.0)

        let greenGate = await evaluator.runGateCommand(
            taskID: "t-green",
            shellCommand: "echo 'Test Suite Passed (42 assertions)'",
            workingDirectory: "/tmp"
        )
        #expect(greenGate.passed == true)
        #expect(greenGate.exitCode == 0)
        #expect(greenGate.stdoutSnippet.contains("42 assertions"))

        let redOutput = """
        Sources/Ledger/BillingEngine.swift:88:15: error: cannot find 'rebateBps' in scope
        Sources/Ledger/BillingEngine.swift:91:9: warning: immutable value 'tmp' was never used
        """
        let parsedDiags = VerificationCommandGateEvaluator.parseCompilerDiagnostics(from: redOutput)
        #expect(parsedDiags.count == 2)
        #expect(parsedDiags[0].filePath.hasSuffix("BillingEngine.swift"))
        #expect(parsedDiags[0].line == 88)
        #expect(parsedDiags[0].column == 15)
        #expect(parsedDiags[0].severity.lowercased() == "error")
    }

    // MARK: - 14. `RelayDemoWorkspaceSynthesizer` Full Flagship Campaign Hydration

    @Test("RelayDemoWorkspaceSynthesizer synthesizes complete 4-vendor flagship campaign and hydrates SQLite workspace")
    func relayDemoWorkspaceSynthesizerFullCampaignHydration() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-synth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: tempDir.appendingPathComponent("Flagship.relayide"))
        let orchestrator = MultiVendorDAGOrchestrator(database: db)
        let synthesizer = RelayDemoWorkspaceSynthesizer()

        let campaign = try synthesizer.populateWorkspaceDatabase(db, orchestrator: orchestrator)

        #expect(campaign.campaignTitle == RelayDemoWorkspaceSynthesizer.flagshipCampaignName)
        #expect(campaign.lanes.count == 4)
        #expect(Set(campaign.lanes.map(\.assignedVendor)) == Set([.claudeCode, .codex, .antigravity, .mistralVibe]))
        #expect(!campaign.dagSpec.tasks.isEmpty)
        #expect(!campaign.cpmSchedule.criticalPathTaskIDs.isEmpty)
        #expect(campaign.terminalSnapshots.count == 4)
        #expect(!campaign.mergeReports.isEmpty)
        #expect(!campaign.isometricTiles.isEmpty)
        #expect(!campaign.wiretapSpans.isEmpty)
        #expect(!campaign.guardrailFindings.isEmpty)
        #expect(campaign.costAnalytics.totalSpentUSD > 0)

        // Verify persisted SQLite database matches synthesized campaign
        let stats = try db.computeStats()
        #expect(stats.activeLaneCount == 4)
        #expect(stats.taskNodeCount == campaign.dagSpec.tasks.count)
        #expect(stats.totalSpendUSD > 0)
    }

    // MARK: - 15. `MultiVendorDAGOrchestrator.seedIndustrialDemoWorkspace` End-to-End

    @Test("MultiVendorDAGOrchestrator.seedIndustrialDemoWorkspace populates lanes, DAG, semantic merge, and wiretap spans")
    func orchestratorSeedIndustrialDemoWorkspace() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: tempDir.appendingPathComponent("Demo.relayide"))
        let orchestrator = MultiVendorDAGOrchestrator(database: db)
        try orchestrator.seedIndustrialDemoWorkspace(workspaceName: "UnitSeedWorkspace")

        let stats = try db.computeStats()
        #expect(stats.workspaceName == "UnitSeedWorkspace")
        #expect(stats.activeLaneCount >= 4)
        #expect(stats.taskNodeCount >= 4)
        #expect(stats.semanticAutoMergeCount >= 1)
    }

    // MARK: - 16. JavaScript Runtime Exception Resilience in `RelayJSScratchpadEvaluator`

    @Test("RelayJSScratchpadEvaluator isolates uncaught JavaScript exceptions without crashing host process")
    func jsScratchpadEvaluatorIsolatesUncaughtJSExceptions() {
        let evaluator = RelayJSScratchpadEvaluator()
        let brokenScript = """
        function runRelayGuardrail() {
            throw new Error("Intentional sandbox fault");
        }
        """
        let result = evaluator.evaluateScratchpad(
            scriptSource: brokenScript,
            grantedCapabilities: [.inspectDiffs]
        )
        #expect(result.succeeded == false)
        #expect(result.exceptionMessage?.contains("Intentional sandbox fault") == true)
    }
}
