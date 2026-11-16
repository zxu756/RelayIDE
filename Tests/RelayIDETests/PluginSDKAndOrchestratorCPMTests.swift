import Darwin
import Foundation
import RelayModels
import RelayOrchestrator
import RelayPTYCore
import RelayPluginSDK
import RelayWorkspaceStore
import RelayWorktreeGit
import Testing

@Suite("JavaScriptCore Guardrail Plugins, Scratchpad, Policy Packs, DAG Waves, CPM & Failover", .timeLimit(.minutes(1)))
struct PluginSDKAndOrchestratorCPMTests {

    // MARK: - 1. All 4 Built-In Guardrail Plugins Execution & Detection

    @Test("RelayJavaScriptPluginHost evaluates all 4 built-in guardrail plugins and produces findings + commit title")
    func builtInFourGuardrailPluginsExecutionAndFindings() throws {
        let builtIns = BuiltInRelayGuardrailPlugins.all
        #expect(builtIns.count == 4)

        let host = RelayJavaScriptPluginHost(plugins: builtIns)
        let leakedKey = "sk-ant-" + "api03-" + String(repeating: "Z8pQ", count: 24)

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
        let fakeSecret = "sk-ant-" + "api03-" + String(repeating: "m4Nv", count: 24)
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

    // MARK: - 17. M1 `RelayRunIDGenerator` & `RelayPlanValidator` Direct Unit Tests (§3, §4)

    @Test("RelayRunIDGenerator emits UTC YYYYMMDD-HHMMSS-<4hex> and RelayPlanValidator enforces ASCII lane ID rules")
    func relayRunIDGeneratorAndLaneIDRules() {
        let fixedEpoch = Date(timeIntervalSince1970: 1_794_787_205) // 2026-11-16 00:00:05 UTC
        let generated = RelayRunIDGenerator.generate(now: fixedEpoch, randomSuffix: 0x0a3f)
        #expect(generated == "20261116-000005-0a3f")

        let randomRunID = RelayRunIDGenerator.generate(now: fixedEpoch)
        #expect(randomRunID.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)

        // Valid lane IDs: ^[a-z0-9][a-z0-9-]{0,39}$ excluding reserved "integration"
        #expect(RelayPlanValidator.isValidLaneID("a") == true)
        #expect(RelayPlanValidator.isValidLaneID("0-lane-alpha") == true)
        #expect(RelayPlanValidator.isValidLaneID(String(repeating: "z", count: 40)) == true)

        // Invalid lane IDs
        #expect(RelayPlanValidator.isValidLaneID("") == false)
        #expect(RelayPlanValidator.isValidLaneID("integration") == false)
        #expect(RelayPlanValidator.isValidLaneID("a/b") == false)
        #expect(RelayPlanValidator.isValidLaneID("../escape") == false)
        #expect(RelayPlanValidator.isValidLaneID("-leading-dash") == false)
        #expect(RelayPlanValidator.isValidLaneID("Upper") == false)
        #expect(RelayPlanValidator.isValidLaneID("under_score") == false)
        #expect(RelayPlanValidator.isValidLaneID(String(repeating: "z", count: 41)) == false)
    }

    // MARK: - 18. M1 `RelayLogSpendParser` Three Spend Cases (`usd`, `unpriced`, `no_record`, §11)

    @Test("RelayLogSpendParser parses USD cost, comma-formatted unpriced tokens (never 0), and missing/unrecorded entries")
    func relayLogSpendParserThreeSpendCasesAndByteOffset() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-spend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. USD cost (`cost $0.0123`)
        let claudeMD = """
        ## 01-claude: ok, 2s, 2026-11-16 01:10

        - prompt: .relay/01-claude.prompt.md, log: .relay/01-claude.log
        - claude: model claude-sonnet-4-5, cost $0.0123, session s1
        - files changed:
          - a.txt
        - final message:

        > Done.
        > STATUS: success
        """
        let usd = RelayLogSpendParser.parseStepSpend(fromAppendedMarkdown: claudeMD)
        #expect(usd.didAppendStepEntry == true)
        #expect(usd.stepID == "01-claude")
        #expect(usd.costUSD == 0.0123)
        #expect(usd.costSource == "usd")

        // 2. Tokens only (`tokens 12,345`) -> costUSD MUST be nil (never 0), costSource == "unpriced"
        let agyMD = """
        ## 02-agy: ok, 3s, 2026-11-16 01:11

        - prompt: .relay/02-agy.prompt.md, log: .relay/02-agy.log
        - agy: model ? (asked for the settings.json default), tokens 12,345
        - files changed:
          - b.txt
        - final message:

        > Done.
        > STATUS: success
        """
        let unpriced = RelayLogSpendParser.parseStepSpend(fromAppendedMarkdown: agyMD)
        #expect(unpriced.didAppendStepEntry == true)
        #expect(unpriced.stepID == "02-agy")
        #expect(unpriced.costUSD == nil)
        #expect(unpriced.tokens == 12345)
        #expect(unpriced.costSource == "unpriced")

        // 3a. Missing LOG.md -> didAppendStepEntry == false, costUSD == nil, tokens == nil, costSource == "no_record"
        let missingURL = tempDir.appendingPathComponent("nonexistent/LOG.md")
        let missing = RelayLogSpendParser.parseStepSpend(fromLogFileAt: missingURL, initialByteOffset: 0)
        #expect(missing.didAppendStepEntry == false)
        #expect(missing.costUSD == nil)
        #expect(missing.tokens == nil)
        #expect(missing.costSource == "no_record")

        // 3b. Pre-existing LOG.md with no new step appended (e.g. refused or killed by SIGTERM) -> ignores prior step via initialByteOffset
        let logURL = tempDir.appendingPathComponent("LOG.md")
        try Data(claudeMD.utf8).write(to: logURL)
        let priorOffset = try Data(contentsOf: logURL).count
        let noNewStep = RelayLogSpendParser.parseStepSpend(fromLogFileAt: logURL, initialByteOffset: priorOffset)
        #expect(noNewStep.didAppendStepEntry == false)
        #expect(noNewStep.costUSD == nil)
        #expect(noNewStep.tokens == nil)
        #expect(noNewStep.costSource == "no_record")

        // 3c. Step logged after crash (`cost $?`) -> didAppendStepEntry == true, costUSD == nil, tokens == nil, costSource == "no_record"
        let crashedStep = """

        ## 02-claude: failed (exit 2: stub exited), 0s, 2026-11-16 01:12

        - prompt: .relay/02-claude.prompt.md, log: .relay/02-claude.log
        - claude: model ?, cost $?
        - files changed:
          - (none)
        """
        try Data((claudeMD + crashedStep).utf8).write(to: logURL)
        let crashedReading = RelayLogSpendParser.parseStepSpend(fromLogFileAt: logURL, initialByteOffset: priorOffset)
        #expect(crashedReading.didAppendStepEntry == true)
        #expect(crashedReading.stepID == "02-claude")
        #expect(crashedReading.costUSD == nil)
        #expect(crashedReading.tokens == nil)
        #expect(crashedReading.costSource == "no_record")
    }

    // MARK: - 19. M1 `RelayLaneOutcomeClassifier` Exit & Signal Status Rules (§7, R32, R43)

    @Test("RelayLaneOutcomeClassifier maps exit 0/5/124/2/N and signals accurately without treating signal death as success")
    func relayLaneOutcomeClassifierMapsExitsRefusalsAndSignals() {
        // 0 -> succeeded
        let ok = RelayLaneOutcomeClassifier.classify(
            termination: .exited(code: 0),
            ptyTranscript: "relay 01-claude: ok in 1s\r\n",
            didAppendLogStep: true,
            language: .en
        )
        #expect(ok.status == .succeeded)
        #expect(ok.exitCode == 0)
        #expect(ok.signal == nil)

        // 5 -> partial
        let partial = RelayLaneOutcomeClassifier.classify(
            termination: .exited(code: 5),
            ptyTranscript: "relay 01-claude: partial in 1s\r\n",
            didAppendLogStep: true,
            language: .en
        )
        #expect(partial.status == .partial)
        #expect(partial.exitCode == 5)
        #expect(partial.signal == nil)

        // 124 -> timeout
        let timedOut = RelayLaneOutcomeClassifier.classify(
            termination: .exited(code: 124),
            ptyTranscript: "relay 01-claude: timeout after 2s\r\n",
            didAppendLogStep: true,
            language: .en
        )
        #expect(timedOut.status == .timeout)
        #expect(timedOut.exitCode == 124)
        #expect(timedOut.signal == nil)

        // 2 without LOG.md step -> refused, capturing last `relay: ` refusal line (ignoring `relay: warning:`)
        let ptyRefusal = "relay: warning: minor note\r\nrelay: not sent: prompt looks like it contains a credential:\r\n  - OpenAI/Anthropic key (line 1)\r\n"
        let refused = RelayLaneOutcomeClassifier.classify(
            termination: .exited(code: 2),
            ptyTranscript: ptyRefusal,
            didAppendLogStep: false,
            language: .en
        )
        #expect(refused.status == .refused)
        #expect(refused.exitCode == 2)
        #expect(refused.signal == nil)
        #expect(refused.reason == "relay: not sent: prompt looks like it contains a credential:")

        // 2 WITH LOG.md step (agent CLI itself exited 2, Row 9) -> failed (exit 2), NOT refused
        let agentExit2 = RelayLaneOutcomeClassifier.classify(
            termination: .exited(code: 2),
            ptyTranscript: "relay 01-claude: failed (exit 2) in 0s; files changed: 0\r\n",
            didAppendLogStep: true,
            language: .en
        )
        #expect(agentExit2.status == .failed)
        #expect(agentExit2.exitCode == 2)
        #expect(agentExit2.signal == nil)

        // Other non-zero (e.g. 3, 125) -> failed (exit N)
        let exit125 = RelayLaneOutcomeClassifier.classify(
            termination: .exited(code: 125),
            ptyTranscript: "",
            didAppendLogStep: true,
            language: .zhHans
        )
        #expect(exit125.status == .failed)
        #expect(exit125.exitCode == 125)
        #expect(exit125.signal == nil)
        #expect(exit125.reason?.contains("125") == true)

        // Signal death (SIGKILL 9) -> failed (signal 9), exitCode MUST be nil
        let sig9 = RelayLaneOutcomeClassifier.classify(
            termination: .signaled(signal: 9),
            ptyTranscript: "",
            didAppendLogStep: false,
            language: .en
        )
        #expect(sig9.status == .failed)
        #expect(sig9.exitCode == nil)
        #expect(sig9.signal == 9)
        #expect(sig9.reason?.contains("9") == true)
    }

    // MARK: - 20. M2 `RelayIntegrationMergeOrder` Pure Topological + Plan-Index Tie-Break (§4)

    @Test("RelayIntegrationMergeOrder computes topological order breaking ties at every step by earliest plan position, including [b(after a), c, a] -> [c, a, b] (§4)")
    func relayIntegrationMergeOrderTopologicalAndPlanPriority() throws {
        // 1. Canonical spec example: [b (after a), c, a] -> [c, a, b]
        let canonical = try RelayIntegrationMergeOrder.computeMergeOrder([
            RelayMergeOrderItem(laneID: "b", after: ["a"]),
            RelayMergeOrderItem(laneID: "c", after: []),
            RelayMergeOrderItem(laneID: "a", after: [])
        ])
        #expect(canonical == ["c", "a", "b"])

        // 2. Stepwise plan-position priority: [b (after a), a, c] -> `a` runs first (index 1 < index 2),
        // unlocking `b` (index 0) which beats `c` (index 2) -> [a, b, c]
        let stepwisePriority = try RelayIntegrationMergeOrder.computeMergeOrder([
            RelayMergeOrderItem(laneID: "b", after: ["a"]),
            RelayMergeOrderItem(laneID: "a", after: []),
            RelayMergeOrderItem(laneID: "c", after: [])
        ])
        #expect(stepwisePriority == ["a", "b", "c"])

        // 3. Deeper chain + siblings: [d(after c), b(after a), c(after a), a, e] -> [a, b, c, d, e]
        let chainAndSiblings = try RelayIntegrationMergeOrder.computeMergeOrder([
            RelayMergeOrderItem(laneID: "d", after: ["c"]),
            RelayMergeOrderItem(laneID: "b", after: ["a"]),
            RelayMergeOrderItem(laneID: "c", after: ["a"]),
            RelayMergeOrderItem(laneID: "a", after: []),
            RelayMergeOrderItem(laneID: "e", after: [])
        ])
        #expect(chainAndSiblings == ["a", "b", "c", "d", "e"])

        // 4. Overload from RelayRunLaneRecord + planOrder
        let laneRecords: [RelayRunLaneRecord] = [
            RelayRunLaneRecord(runID: "r1", laneID: "a", ordinal: 2, agent: .claude, promptPath: "a.md", after: []),
            RelayRunLaneRecord(runID: "r1", laneID: "b", ordinal: 0, agent: .codex, promptPath: "b.md", after: ["a"]),
            RelayRunLaneRecord(runID: "r1", laneID: "c", ordinal: 1, agent: .agy, promptPath: "c.md", after: [])
        ]
        let fromRecords = try RelayIntegrationMergeOrder.computeMergeOrder(
            lanes: laneRecords,
            planOrder: ["b", "c", "a"]
        )
        #expect(fromRecords == ["c", "a", "b"])

        // 5. Rejects cycles, unknown dependencies, and duplicate IDs
        #expect(throws: RelayIDEError.self) {
            _ = try RelayIntegrationMergeOrder.computeMergeOrder([
                RelayMergeOrderItem(laneID: "a", after: ["b"]),
                RelayMergeOrderItem(laneID: "b", after: ["a"])
            ])
        }
        #expect(throws: RelayIDEError.self) {
            _ = try RelayIntegrationMergeOrder.computeMergeOrder([
                RelayMergeOrderItem(laneID: "a", after: ["nonexistent"])
            ])
        }
        #expect(throws: RelayIDEError.self) {
            _ = try RelayIntegrationMergeOrder.computeMergeOrder([
                RelayMergeOrderItem(laneID: "a", after: []),
                RelayMergeOrderItem(laneID: "a", after: [])
            ])
        }
    }

    // MARK: - 21. M2 `RelayIntegrationStderrFormatter` Bilingual Merge Progress Lines (§10)

    @Test("RelayIntegrationStderrFormatter formats bilingual EN and ZH stderr lines for integration branch creation, per-lane merge steps, and integration summary (§10)")
    func relayIntegrationStderrFormatterBilingualLines() {
        let baseOID = "1111111111112222222222223333333333334444"
        let mergeOID = "aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd"
        let wtPath = "/tmp/proj/runs/20261117-010000-abcd/worktrees/integration"
        let branch = "relay/20261117-010000-abcd/integration"

        // 1. Integration branch creation line
        let branchEN = RelayIntegrationStderrFormatter.formatIntegrationBranchCreatedLine(
            branchName: branch,
            worktreePath: wtPath,
            baseCommitOID: baseOID,
            language: .en
        )
        let branchZH = RelayIntegrationStderrFormatter.formatIntegrationBranchCreatedLine(
            branchName: branch,
            worktreePath: wtPath,
            baseCommitOID: baseOID,
            language: .zhHans
        )
        #expect(branchEN != branchZH)
        #expect(branchEN.contains(branch) && branchEN.contains("111111111111") && branchEN.contains(wtPath))
        #expect(branchZH.contains("集成分支") && branchZH.contains(branch) && branchZH.contains("111111111111"))
        #expect(!branchZH.contains("lane "))

        // 2. Per-lane merge step lines: merged, no-changes, conflict
        let mergedStep = RelayRunMergeRecord(
            ordinal: 0,
            laneID: "api",
            laneCommitOID: "9999999999999999999999999999999999999999",
            status: .merged,
            mergeCommitOID: mergeOID
        )
        let mergedEN = RelayIntegrationStderrFormatter.formatMergeStepLine(step: mergedStep, agent: .claude, language: .en)
        let mergedZH = RelayIntegrationStderrFormatter.formatMergeStepLine(step: mergedStep, agent: .claude, language: .zhHans)
        #expect(mergedEN.contains("merge lane api (claude)") && mergedEN.contains("merged") && mergedEN.contains("aaaaaaaaaaaa"))
        #expect(mergedZH.contains("合并通道 api (claude)") && mergedZH.contains("已合并") && mergedZH.contains("aaaaaaaaaaaa"))
        #expect(!mergedZH.contains("lane "))

        let noChangesStep = RelayRunMergeRecord(
            ordinal: 1,
            laneID: "noop",
            laneCommitOID: nil,
            status: .noChanges,
            mergeCommitOID: nil
        )
        let noChangesEN = RelayIntegrationStderrFormatter.formatMergeStepLine(step: noChangesStep, agent: .codex, language: .en)
        let noChangesZH = RelayIntegrationStderrFormatter.formatMergeStepLine(step: noChangesStep, agent: .codex, language: .zhHans)
        #expect(noChangesEN.contains("noop (codex)") && noChangesEN.contains("no changes") && noChangesEN.contains("commit none"))
        #expect(noChangesZH.contains("noop (codex)") && noChangesZH.contains("无改动") && noChangesZH.contains("合并提交 无"))

        let conflictStep = RelayRunMergeRecord(
            ordinal: 2,
            laneID: "ui",
            laneCommitOID: "8888888888888888888888888888888888888888",
            status: .conflict,
            mergeCommitOID: nil,
            conflicts: [
                RelayMergeConflictItem(path: "src/app.swift", code: "UU"),
                RelayMergeConflictItem(path: "src/new.swift", code: "AA")
            ]
        )
        let conflictEN = RelayIntegrationStderrFormatter.formatMergeStepLine(step: conflictStep, agent: .agy, language: .en)
        let conflictZH = RelayIntegrationStderrFormatter.formatMergeStepLine(step: conflictStep, agent: .agy, language: .zhHans)
        #expect(conflictEN.contains("ui (agy)") && conflictEN.contains("conflict") && conflictEN.contains("src/app.swift (UU), src/new.swift (AA)"))
        #expect(conflictZH.contains("ui (agy)") && conflictZH.contains("冲突") && conflictZH.contains("src/app.swift (UU), src/new.swift (AA)"))

        // 3. Final integration summary line (status + ready yes/no)
        let mergedIntegration = RelayRunIntegrationRecord(
            branch: branch,
            worktreePath: wtPath,
            baseCommitOID: baseOID,
            headCommitOID: mergeOID,
            status: .merged,
            reason: nil,
            ready: false,
            merges: [mergedStep]
        )
        let sumMergedEN = RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(integration: mergedIntegration, language: .en)
        let sumMergedZH = RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(integration: mergedIntegration, language: .zhHans)
        #expect(sumMergedEN.contains("status merged") && sumMergedEN.contains("ready no") && sumMergedEN.contains("aaaaaaaaaaaa"))
        #expect(sumMergedZH.contains("状态 已合并") && sumMergedZH.contains("可合入 否") && sumMergedZH.contains("aaaaaaaaaaaa"))
        #expect(!sumMergedZH.contains("lane "))

        let verifiedIntegration = RelayRunIntegrationRecord(
            branch: branch,
            worktreePath: wtPath,
            baseCommitOID: baseOID,
            headCommitOID: mergeOID,
            status: .verified,
            reason: nil,
            ready: true,
            merges: [mergedStep]
        )
        let sumVerifiedEN = RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(integration: verifiedIntegration, language: .en)
        let sumVerifiedZH = RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(integration: verifiedIntegration, language: .zhHans)
        #expect(sumVerifiedEN.contains("status verified") && sumVerifiedEN.contains("ready yes"))
        #expect(sumVerifiedZH.contains("状态 已验证") && sumVerifiedZH.contains("可合入 是"))
    }

    // MARK: - M2 Isolated `mktemp -d` + `GIT_CONFIG_NOSYSTEM=1` Merge Test Helpers

    private func makeMktempDirectory(prefix: String = "relay-m2-merge") throws -> URL {
        let base = FileManager.default.temporaryDirectory.path
        let templateString = (base as NSString).appendingPathComponent("\(prefix)-XXXXXX")
        var buffer = Array(templateString.utf8CString)
        let createdPtr = buffer.withUnsafeMutableBufferPointer { buf -> UnsafeMutablePointer<CChar>? in
            guard let baseAddress = buf.baseAddress else { return nil }
            return Darwin.mkdtemp(baseAddress)
        }
        guard let createdPtr else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return URL(fileURLWithPath: String(cString: createdPtr), isDirectory: true)
    }

    private func makeIsolatedGitEnvironment(homeDir: URL) -> [String: String] {
        [
            "HOME": homeDir.path,
            "CFFIXED_USER_HOME": homeDir.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]
    }

    // MARK: - 22. M2 Single-Lane Merge (`no-changes`, Hostile-Repo `--no-ff`, Conflict `--abort`, Non-Conflict No-Abort 125, §5, R55–R59)

    @Test("RelayIntegrationMergeRunner.mergeSingleLaneStep handles no-changes without calling git merge, verifies --no-ff parents and exact 4-line message in hostile repos, records conflicts + aborts cleanly, and skips --abort on non-conflict 125 errors (§5, R55–R59)")
    func mergeSingleLaneStepCoversNoChangesCleanMergeConflictAbortAndNonConflict125() throws {
        let tempRoot = try makeMktempDirectory(prefix: "relay-m2-step")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let projectDir = tempRoot.appendingPathComponent("Proj.relayproj", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let gitEnv = makeIsolatedGitEnvironment(homeDir: homeDir)

        // Install a forwarding git wrapper that logs every git invocation so we can assert `merge` / `--abort` calls deterministically.
        let gitLogURL = tempRoot.appendingPathComponent("git-calls.log")
        let gitWrapperURL = tempRoot.appendingPathComponent("git-wrapper.sh")
        let wrapperScript = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(gitLogURL.path)"
        exec /usr/bin/git "$@"
        """
        try wrapperScript.write(to: gitWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitWrapperURL.path)

        let engine = GitWorktreePlumbingEngine(gitExecutablePath: gitWrapperURL.path)
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "Merge Author"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "merge@relay.invalid"], cwd: repoDir.path, environment: gitEnv)

        try "line1\nline2\nline3\n".write(to: repoDir.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "shared.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "base"], cwd: repoDir.path, environment: gitEnv)
        let baseOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Create lane commits:
        // - lane `a`: modifies line2 of shared.txt + adds a.txt
        // - lane `b`: modifies line2 of shared.txt differently + adds new.txt (conflicts with `a` on shared.txt)
        // - lane `c`: adds c.txt cleanly
        _ = try engine.runGit(["checkout", "-b", "prep-a", baseOID], cwd: repoDir.path, environment: gitEnv)
        try "line1\nA-line2\nline3\n".write(to: repoDir.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "from-a\n".write(to: repoDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "-A"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "lane a work"], cwd: repoDir.path, environment: gitEnv)
        let aOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "-b", "prep-b", baseOID], cwd: repoDir.path, environment: gitEnv)
        try "line1\nB-line2\nline3\n".write(to: repoDir.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "-A"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "lane b work"], cwd: repoDir.path, environment: gitEnv)
        let bOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "-b", "prep-c", baseOID], cwd: repoDir.path, environment: gitEnv)
        try "from-c\n".write(to: repoDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "-A"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "lane c work"], cwd: repoDir.path, environment: gitEnv)
        let cOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "main"], cwd: repoDir.path, environment: gitEnv)

        // Configure hostile repo settings + failing hooks (Row 23, R58, R59)
        _ = try engine.runGit(["config", "merge.verifySignatures", "true"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "commit.gpgSign", "true"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "merge.log", "true"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "merge.ff", "only"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "rerere.enabled", "true"], cwd: repoDir.path, environment: gitEnv)

        let hookMarkerURL = tempRoot.appendingPathComponent("hooks.marker")
        let hooksDir = repoDir.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for h in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-merge-commit", "post-merge", "post-checkout"] {
            let hURL = hooksDir.appendingPathComponent(h)
            try "#!/bin/sh\necho \(h) >> \"\(hookMarkerURL.path)\"\nexit 1\n".write(to: hURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hURL.path)
        }

        // Open SQLite DB and create run1
        let db = try RelayProjectDatabase(bundleDirectoryURL: projectDir)
        let run1 = "20261117-030000-0001"
        let laneNoopNil = RelayRunLaneRecord(runID: run1, laneID: "noop-nil", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeededNoChanges, commitOID: nil)
        let laneNoopAnc = RelayRunLaneRecord(runID: run1, laneID: "noop-anc", ordinal: 1, agent: .codex, promptPath: "p.md", status: .succeeded, branch: "relay/\(run1)/noop-anc", commitOID: baseOID)
        let laneA = RelayRunLaneRecord(runID: run1, laneID: "a", ordinal: 2, agent: .claude, promptPath: "p.md", status: .succeeded, branch: "relay/\(run1)/a", commitOID: aOID)
        let laneB = RelayRunLaneRecord(runID: run1, laneID: "b", ordinal: 3, agent: .codex, promptPath: "p.md", status: .succeeded, branch: "relay/\(run1)/b", commitOID: bOID)
        let laneC = RelayRunLaneRecord(runID: run1, laneID: "c", ordinal: 4, agent: .vibe, promptPath: "p.md", status: .succeeded, branch: "relay/\(run1)/c", commitOID: cOID)

        try db.createRun(
            RelayRunRecord(
                runID: run1,
                repoPath: repoDir.path,
                planCopyPath: tempRoot.appendingPathComponent("plan.json").path,
                baseRef: "main",
                baseCommitOID: baseOID,
                verifyCommand: nil,
                relayShPath: "/usr/bin/true",
                relayShSHA256: String(repeating: "0", count: 64),
                startedAt: Date(),
                status: .running,
                relayidePID: getpid(),
                lanes: [laneNoopNil, laneNoopAnc, laneA, laneB, laneC]
            )
        )

        let wt1 = try engine.createIntegrationWorktree(
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            runID: run1,
            baseCommitOID: baseOID,
            environment: gitEnv
        )
        var integration1 = RelayRunIntegrationRecord(
            branch: wt1.branchName,
            worktreePath: wt1.worktreePath,
            baseCommitOID: baseOID,
            headCommitOID: baseOID,
            status: .merging,
            ready: false,
            merges: [
                RelayRunMergeRecord(ordinal: 0, laneID: "noop-nil", laneCommitOID: nil, status: .notAttempted),
                RelayRunMergeRecord(ordinal: 1, laneID: "noop-anc", laneCommitOID: baseOID, status: .notAttempted),
                RelayRunMergeRecord(ordinal: 2, laneID: "a", laneCommitOID: aOID, status: .notAttempted),
                RelayRunMergeRecord(ordinal: 3, laneID: "b", laneCommitOID: bOID, status: .notAttempted),
                RelayRunMergeRecord(ordinal: 4, laneID: "c", laneCommitOID: cOID, status: .notAttempted)
            ]
        )
        try db.upsertRunIntegration(runID: run1, integration1)

        // 1. `commitOID == nil` and `commitOID == ancestor(HEAD)` -> both `no-changes`, zero `merge --no-ff` calls!
        try? FileManager.default.removeItem(at: gitLogURL)
        let outNil = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
            runID: run1,
            stepIndex: 0,
            lane: laneNoopNil,
            integration: &integration1,
            database: db,
            gitEngine: engine,
            environment: gitEnv
        )
        let outAnc = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
            runID: run1,
            stepIndex: 1,
            lane: laneNoopAnc,
            integration: &integration1,
            database: db,
            gitEngine: engine,
            environment: gitEnv
        )
        #expect(outNil == .noChanges)
        #expect(outAnc == .noChanges)
        let logAfterNoop = (try? String(contentsOf: gitLogURL, encoding: .utf8)) ?? ""
        #expect(!logAfterNoop.contains("merge --no-ff"))

        // 2. Clean `--no-ff` merge of lane `a` in hostile repo -> 2 parents (`baseOID`, `aOID`), exact 4-line message, hooks skipped
        let outA = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
            runID: run1,
            stepIndex: 2,
            lane: laneA,
            integration: &integration1,
            database: db,
            gitEngine: engine,
            environment: gitEnv
        )
        guard case .merged(let mergeAOID) = outA else {
            Issue.record("Expected .merged for lane a, got \(outA)")
            return
        }
        #expect(mergeAOID != baseOID && mergeAOID != aOID)
        #expect(!FileManager.default.fileExists(atPath: hookMarkerURL.path))
        let p1 = try engine.runGit(["rev-parse", "\(mergeAOID)^1"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)
        let p2 = try engine.runGit(["rev-parse", "\(mergeAOID)^2"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(p1 == baseOID)
        #expect(p2 == aOID)
        let mergeMsg = try engine.runGit(["log", "-1", "--format=%B", mergeAOID], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedMergeMsg = """
        relay \(run1) merge a (claude)

        Lane branch: relay/\(run1)/a
        Lane commit: \(aOID)
        Merged by RelayIDE; repository hooks skipped.
        """
        #expect(mergeMsg == expectedMergeMsg)
        let mergeAuthor = try engine.runGit(["log", "-1", "--format=%an <%ae>", mergeAOID], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mergeAuthor == "Merge Author <merge@relay.invalid>")

        // 3. Conflicting merge of lane `b` -> records UU on shared.txt + CONFLICT line, runs --abort, worktree 100% clean, `c` stays not-attempted
        let outB = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
            runID: run1,
            stepIndex: 3,
            lane: laneB,
            integration: &integration1,
            database: db,
            gitEngine: engine,
            environment: gitEnv
        )
        guard case .conflict(let bConflicts, let bConflictLines, let headAfterAbort) = outB else {
            Issue.record("Expected .conflict for lane b, got \(outB)")
            return
        }
        #expect(bConflicts == [RelayMergeConflictItem(path: "shared.txt", code: "UU")])
        #expect(bConflictLines.contains { $0.hasPrefix("CONFLICT") && $0.contains("shared.txt") })
        #expect(headAfterAbort == mergeAOID)

        // Verify 3 cleanliness invariants on disk + persisted SQLite state
        let wtHeadAfterAbort = try engine.runGit(["rev-parse", "HEAD"], cwd: wt1.worktreePath, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(wtHeadAfterAbort == mergeAOID)
        let mhCheck = try engine.runGitCommand(["rev-parse", "-q", "--verify", "MERGE_HEAD"], cwd: wt1.worktreePath, environment: gitEnv)
        #expect(mhCheck.exitCode != 0)
        let cleanPorcelain = try engine.runGit(["status", "--porcelain=v1", "-uall", "--ignored"], cwd: wt1.worktreePath, environment: gitEnv)
        #expect(cleanPorcelain.isEmpty)

        let persisted1 = try #require(try db.fetchRun(runID: run1, reconcileWithLock: false)?.integration)
        #expect(persisted1.status == .conflict)
        #expect(persisted1.ready == false)
        #expect(persisted1.headCommitOID == mergeAOID)
        #expect(persisted1.merges.map(\.status) == [.noChanges, .noChanges, .merged, .conflict, .notAttempted])
        #expect(persisted1.merges[3].conflicts == [RelayMergeConflictItem(path: "shared.txt", code: "UU")])
        #expect(!persisted1.merges[3].conflictLines.isEmpty)

        // 4. Non-conflict `git merge` failure (untracked file in integration worktree blocking merge -> NO MERGE_HEAD):
        // MUST NOT call `merge --abort`, MUST set `integration.status == .error` with last stderr line, and throw 125!
        let run2 = "20261117-030001-0002"
        let laneC2 = RelayRunLaneRecord(runID: run2, laneID: "c", ordinal: 0, agent: .vibe, promptPath: "p.md", status: .succeeded, branch: "relay/\(run2)/c", commitOID: cOID)
        try db.createRun(
            RelayRunRecord(
                runID: run2,
                repoPath: repoDir.path,
                planCopyPath: tempRoot.appendingPathComponent("plan.json").path,
                baseRef: "main",
                baseCommitOID: baseOID,
                verifyCommand: nil,
                relayShPath: "/usr/bin/true",
                relayShSHA256: String(repeating: "0", count: 64),
                startedAt: Date(),
                status: .running,
                relayidePID: getpid(),
                lanes: [laneC2]
            )
        )
        let wt2 = try engine.createIntegrationWorktree(
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            runID: run2,
            baseCommitOID: baseOID,
            environment: gitEnv
        )
        // Place untracked `c.txt` inside integration worktree so merging `cOID` fails with exit != 0 and NO MERGE_HEAD
        try "untracked-blocker\n".write(
            to: URL(fileURLWithPath: wt2.worktreePath).appendingPathComponent("c.txt"),
            atomically: true,
            encoding: .utf8
        )
        var integration2 = RelayRunIntegrationRecord(
            branch: wt2.branchName,
            worktreePath: wt2.worktreePath,
            baseCommitOID: baseOID,
            headCommitOID: baseOID,
            status: .merging,
            ready: false,
            merges: [RelayRunMergeRecord(ordinal: 0, laneID: "c", laneCommitOID: cOID, status: .notAttempted)]
        )
        try db.upsertRunIntegration(runID: run2, integration2)

        try? FileManager.default.removeItem(at: gitLogURL)
        do {
            _ = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
                runID: run2,
                stepIndex: 0,
                lane: laneC2,
                integration: &integration2,
                database: db,
                gitEngine: engine,
                environment: gitEnv
            )
            Issue.record("Expected non-conflict merge failure to throw 125 RelayIDEError")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
        let logRun2 = (try? String(contentsOf: gitLogURL, encoding: .utf8)) ?? ""
        #expect(logRun2.contains("merge --no-ff"))
        #expect(!logRun2.contains("--abort"))

        let persisted2 = try #require(try db.fetchRun(runID: run2, reconcileWithLock: false)?.integration)
        #expect(persisted2.status == .error)
        #expect(persisted2.ready == false)
        #expect(persisted2.reason == "Merge with strategy ort failed.")
        #expect(persisted2.reason?.contains("\n") == false)

        // 5. Post-abort cleanliness check failure -> throws 125 and marks integration `.error`
        let dirtyAbortWrapperURL = tempRoot.appendingPathComponent("git-dirty-abort.sh")
        let dirtyAbortScript = """
        #!/bin/sh
        /usr/bin/git "$@"
        rc=$?
        case "$*" in
          *"merge --abort"*)
            echo leftover > leftover-after-abort.tmp
            ;;
        esac
        exit $rc
        """
        try dirtyAbortScript.write(to: dirtyAbortWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirtyAbortWrapperURL.path)
        let dirtyEngine = GitWorktreePlumbingEngine(gitExecutablePath: dirtyAbortWrapperURL.path)

        let run3 = "20261117-030002-0003"
        let laneA3 = RelayRunLaneRecord(runID: run3, laneID: "a", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeeded, branch: "relay/\(run3)/a", commitOID: aOID)
        let laneB3 = RelayRunLaneRecord(runID: run3, laneID: "b", ordinal: 1, agent: .codex, promptPath: "p.md", status: .succeeded, branch: "relay/\(run3)/b", commitOID: bOID)
        try db.createRun(
            RelayRunRecord(
                runID: run3,
                repoPath: repoDir.path,
                planCopyPath: tempRoot.appendingPathComponent("plan.json").path,
                baseRef: "main",
                baseCommitOID: baseOID,
                verifyCommand: nil,
                relayShPath: "/usr/bin/true",
                relayShSHA256: String(repeating: "0", count: 64),
                startedAt: Date(),
                status: .running,
                relayidePID: getpid(),
                lanes: [laneA3, laneB3]
            )
        )
        let wt3 = try dirtyEngine.createIntegrationWorktree(
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            runID: run3,
            baseCommitOID: baseOID,
            environment: gitEnv
        )
        var integration3 = RelayRunIntegrationRecord(
            branch: wt3.branchName,
            worktreePath: wt3.worktreePath,
            baseCommitOID: baseOID,
            headCommitOID: baseOID,
            status: .merging,
            ready: false,
            merges: [
                RelayRunMergeRecord(ordinal: 0, laneID: "a", laneCommitOID: aOID, status: .notAttempted),
                RelayRunMergeRecord(ordinal: 1, laneID: "b", laneCommitOID: bOID, status: .notAttempted)
            ]
        )
        try db.upsertRunIntegration(runID: run3, integration3)
        _ = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
            runID: run3,
            stepIndex: 0,
            lane: laneA3,
            integration: &integration3,
            database: db,
            gitEngine: dirtyEngine,
            environment: gitEnv
        )
        do {
            _ = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
                runID: run3,
                stepIndex: 1,
                lane: laneB3,
                integration: &integration3,
                database: db,
                gitEngine: dirtyEngine,
                environment: gitEnv
            )
            Issue.record("Expected dirty post-abort worktree to throw 125 RelayIDEError")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
        let persisted3 = try #require(try db.fetchRun(runID: run3, reconcileWithLock: false)?.integration)
        #expect(persisted3.status == .error)
    }
}
