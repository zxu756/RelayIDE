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
        #expect(campaign.laneBudgetAccounts.count == 4)
        #expect(campaign.laneBudgetAccounts.reduce(0.0) { $0 + $1.spentUSD } > 0)
        #expect(!campaign.guardrailFindings.isEmpty)

        // Verify persisted SQLite database aggregates [DEMO] spend from relay_run_lanes (wiretap_spans stays empty)
        let stats = try db.computeStats()
        #expect(stats.activeLaneCount == 4)
        #expect(stats.taskNodeCount == campaign.dagSpec.tasks.count)
        #expect(try db.allWiretapSpans().isEmpty)
        let demoRuns = try db.allRuns(reconcileWithLock: false)
        #expect(demoRuns.count == 1)
        let firstDemoRun = try #require(demoRuns.first)
        #expect(firstDemoRun.reason?.contains("[DEMO]") == true)
        let laneSpendSum = demoRuns.flatMap(\.lanes).reduce(0.0) { $0 + ($1.costUSD ?? 0.0) }
        let laneTokenSum = demoRuns.flatMap(\.lanes).reduce(0) { $0 + ($1.tokens ?? 0) }
        #expect(stats.totalSpendUSD > 0)
        #expect(abs(stats.totalSpendUSD - laneSpendSum) < 1e-9)
        #expect(stats.totalTokensObserved == laneTokenSum)
        #expect(stats.totalTokensObserved > 0)
    }

    // MARK: - 15. `MultiVendorDAGOrchestrator.seedIndustrialDemoWorkspace` End-to-End

    @Test("MultiVendorDAGOrchestrator.seedIndustrialDemoWorkspace populates lanes, DAG, and semantic merge without writing wiretap_spans")
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
        #expect(try db.allWiretapSpans().isEmpty)
        let seededRuns = try db.allRuns(reconcileWithLock: false)
        #expect(seededRuns.count == 1)
        let firstSeededRun = try #require(seededRuns.first)
        #expect(firstSeededRun.reason?.contains("[DEMO]") == true)
        let seededSpendSum = seededRuns.flatMap(\.lanes).reduce(0.0) { $0 + ($1.costUSD ?? 0.0) }
        let seededTokenSum = seededRuns.flatMap(\.lanes).reduce(0) { $0 + ($1.tokens ?? 0) }
        #expect(stats.totalSpendUSD > 0)
        #expect(abs(stats.totalSpendUSD - seededSpendSum) < 1e-9)
        #expect(stats.totalTokensObserved == seededTokenSum)
        #expect(stats.totalTokensObserved > 0)
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
        #expect(persisted2.reason == "error: The following untracked working tree files would be overwritten by merge:")
        #expect(persisted2.reason != "Merge with strategy ort failed.")
        #expect(persisted2.reason?.contains("\n") == false)

        // 4b. Non-conflict `git merge` failure reason selection: first `fatal:` line when present, else last non-empty stderr line.
        let fatalWrapperURL = tempRoot.appendingPathComponent("git-fatal-no-mh.sh")
        let fatalWrapperScript = """
        #!/bin/sh
        case "$*" in
          *"merge --no-ff"*)
            printf 'warning: preliminary note\\nfatal: refusing to merge unrelated histories\\nMerge with strategy ort failed.\\n' >&2
            exit 128
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try fatalWrapperScript.write(to: fatalWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fatalWrapperURL.path)
        let fatalEngine = GitWorktreePlumbingEngine(gitExecutablePath: fatalWrapperURL.path)

        let run2Fatal = "20261117-030001-002f"
        let laneCFatal = RelayRunLaneRecord(runID: run2Fatal, laneID: "c", ordinal: 0, agent: .vibe, promptPath: "p.md", status: .succeeded, branch: "relay/\(run2Fatal)/c", commitOID: cOID)
        try db.createRun(
            RelayRunRecord(
                runID: run2Fatal,
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
                lanes: [laneCFatal]
            )
        )
        let wt2Fatal = try fatalEngine.createIntegrationWorktree(
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            runID: run2Fatal,
            baseCommitOID: baseOID,
            environment: gitEnv
        )
        var integration2Fatal = RelayRunIntegrationRecord(
            branch: wt2Fatal.branchName,
            worktreePath: wt2Fatal.worktreePath,
            baseCommitOID: baseOID,
            headCommitOID: baseOID,
            status: .merging,
            ready: false,
            merges: [RelayRunMergeRecord(ordinal: 0, laneID: "c", laneCommitOID: cOID, status: .notAttempted)]
        )
        try db.upsertRunIntegration(runID: run2Fatal, integration2Fatal)
        do {
            _ = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
                runID: run2Fatal,
                stepIndex: 0,
                lane: laneCFatal,
                integration: &integration2Fatal,
                database: db,
                gitEngine: fatalEngine,
                environment: gitEnv
            )
            Issue.record("Expected non-conflict fatal merge failure to throw 125")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
        let persisted2Fatal = try #require(try db.fetchRun(runID: run2Fatal, reconcileWithLock: false)?.integration)
        #expect(persisted2Fatal.status == .error)
        #expect(persisted2Fatal.reason == "fatal: refusing to merge unrelated histories")

        let fallbackWrapperURL = tempRoot.appendingPathComponent("git-fallback-no-mh.sh")
        let fallbackWrapperScript = """
        #!/bin/sh
        case "$*" in
          *"merge --no-ff"*)
            printf 'preliminary diagnostic line\\ncustom final failure line\\n' >&2
            exit 2
            ;;
        esac
        exec /usr/bin/git "$@"
        """
        try fallbackWrapperScript.write(to: fallbackWrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallbackWrapperURL.path)
        let fallbackEngine = GitWorktreePlumbingEngine(gitExecutablePath: fallbackWrapperURL.path)

        let run2Fallback = "20261117-030001-002b"
        let laneCFallback = RelayRunLaneRecord(runID: run2Fallback, laneID: "c", ordinal: 0, agent: .vibe, promptPath: "p.md", status: .succeeded, branch: "relay/\(run2Fallback)/c", commitOID: cOID)
        try db.createRun(
            RelayRunRecord(
                runID: run2Fallback,
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
                lanes: [laneCFallback]
            )
        )
        let wt2Fallback = try fallbackEngine.createIntegrationWorktree(
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            runID: run2Fallback,
            baseCommitOID: baseOID,
            environment: gitEnv
        )
        var integration2Fallback = RelayRunIntegrationRecord(
            branch: wt2Fallback.branchName,
            worktreePath: wt2Fallback.worktreePath,
            baseCommitOID: baseOID,
            headCommitOID: baseOID,
            status: .merging,
            ready: false,
            merges: [RelayRunMergeRecord(ordinal: 0, laneID: "c", laneCommitOID: cOID, status: .notAttempted)]
        )
        try db.upsertRunIntegration(runID: run2Fallback, integration2Fallback)
        do {
            _ = try RelayIntegrationMergeRunner.mergeSingleLaneStep(
                runID: run2Fallback,
                stepIndex: 0,
                lane: laneCFallback,
                integration: &integration2Fallback,
                database: db,
                gitEngine: fallbackEngine,
                environment: gitEnv
            )
            Issue.record("Expected non-conflict fallback merge failure to throw 125")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
        let persisted2Fallback = try #require(try db.fetchRun(runID: run2Fallback, reconcileWithLock: false)?.integration)
        #expect(persisted2Fallback.status == .error)
        #expect(persisted2Fallback.reason == "custom final failure line")

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

    // MARK: - 23. M2 Overall `runIntegrationMergePhase` (`skipped`, `nothing-to-merge`, Topological Merge, Conflict Stop, `cancelled`, 125 `error`, §1, §7, D1, D3)

    @Test("RelayIntegrationMergeRunner.runIntegrationMergePhase enforces D1 skipped, nothing-to-merge, topological merge to merged (ready=false), conflict stop (D3), pre/between-step cancellation, and 125 obstruction error persistence (§1, §7)")
    func runIntegrationMergePhaseCoversAllBranchesAndCancellation() throws {
        let tempRoot = try makeMktempDirectory(prefix: "relay-m2-phase")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let projectDir = tempRoot.appendingPathComponent("Proj.relayproj", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let gitEnv = makeIsolatedGitEnvironment(homeDir: homeDir)

        let engine = GitWorktreePlumbingEngine()
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "Phase Tester"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "phase@relay.invalid"], cwd: repoDir.path, environment: gitEnv)
        try "line1\nline2\nline3\n".write(to: repoDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "f.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "base"], cwd: repoDir.path, environment: gitEnv)
        let baseOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Prepare commits for c, a, b (where b is on top of a), plus bConflict (conflicts with a on f.txt)
        _ = try engine.runGit(["checkout", "-b", "src-c", baseOID], cwd: repoDir.path, environment: gitEnv)
        try "c-data\n".write(to: repoDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "c.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "c"], cwd: repoDir.path, environment: gitEnv)
        let cOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "-b", "src-a", baseOID], cwd: repoDir.path, environment: gitEnv)
        try "line1\nA-edit\nline3\n".write(to: repoDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "a-data\n".write(to: repoDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "-A"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "a"], cwd: repoDir.path, environment: gitEnv)
        let aOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "-b", "src-b", aOID], cwd: repoDir.path, environment: gitEnv)
        try "b-data\n".write(to: repoDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "b.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "b"], cwd: repoDir.path, environment: gitEnv)
        let bOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "-b", "src-b-conflict", baseOID], cwd: repoDir.path, environment: gitEnv)
        try "line1\nB-CONFLICT\nline3\n".write(to: repoDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "f.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "b-conflict"], cwd: repoDir.path, environment: gitEnv)
        let bConflictOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try engine.runGit(["checkout", "main"], cwd: repoDir.path, environment: gitEnv)

        let db = try RelayProjectDatabase(bundleDirectoryURL: projectDir)
        func seedRun(_ runID: String, lanes: [RelayRunLaneRecord]) throws {
            try db.createRun(
                RelayRunRecord(
                    runID: runID,
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
                    lanes: lanes
                )
            )
        }

        // Case 1: D1 `skipped` when a lane is `failed` or `partial` -> no branch, no worktree, reason names lane + status
        for (idx, badStatus) in [RelayRunStatus.failed, RelayRunStatus.partial].enumerated() {
            let rID = "20261117-040000-skip\(idx)"
            let lanes = [
                RelayRunLaneRecord(runID: rID, laneID: "a", ordinal: 0, agent: .claude, promptPath: "p.md", status: badStatus, commitOID: badStatus == .partial ? aOID : nil),
                RelayRunLaneRecord(runID: rID, laneID: "c", ordinal: 1, agent: .codex, promptPath: "p.md", status: .succeeded, commitOID: cOID)
            ]
            try seedRun(rID, lanes: lanes)
            let res = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
                runID: rID,
                repositoryPath: repoDir.path,
                projectBundlePath: projectDir.path,
                baseCommitOID: baseOID,
                lanes: lanes,
                planOrder: ["a", "c"],
                database: db,
                gitEngine: engine,
                language: .zhHans,
                environment: gitEnv
            )
            #expect(res.status == .skipped)
            #expect(res.ready == false)
            #expect(res.branch == nil && res.worktreePath == nil)
            #expect(res.reason?.contains("a") == true && res.reason?.contains(badStatus.rawValue) == true)
            #expect(!FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("runs/\(rID)/worktrees/integration").path))
            let branchProbe = try engine.runGitCommand(["show-ref", "--verify", "--quiet", "refs/heads/relay/\(rID)/integration"], cwd: repoDir.path, environment: gitEnv)
            #expect(branchProbe.exitCode != 0)
        }

        // Case 2: `nothing-to-merge` when all lanes are `succeeded-no-changes`
        let rNoop = "20261117-040001-noop"
        let noopLanes = [
            RelayRunLaneRecord(runID: rNoop, laneID: "x", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeededNoChanges, commitOID: nil),
            RelayRunLaneRecord(runID: rNoop, laneID: "y", ordinal: 1, agent: .codex, promptPath: "p.md", status: .succeededNoChanges, commitOID: nil)
        ]
        try seedRun(rNoop, lanes: noopLanes)
        let noopRes = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
            runID: rNoop,
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            baseCommitOID: baseOID,
            lanes: noopLanes,
            planOrder: ["x", "y"],
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv
        )
        #expect(noopRes.status == .nothingToMerge)
        #expect(noopRes.ready == false)
        #expect(noopRes.branch == nil && noopRes.worktreePath == nil)
        #expect(!FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("runs/\(rNoop)/worktrees/integration").path))

        // Case 3: Full topological + plan-order merge `[b (after a), c, a]` -> `c, a, b`, stops at `merged` with `ready == false`
        let rTopo = "20261117-040002-topo"
        let topoLanes = [
            RelayRunLaneRecord(runID: rTopo, laneID: "b", ordinal: 0, agent: .codex, promptPath: "p.md", after: ["a"], status: .succeeded, branch: "relay/\(rTopo)/b", commitOID: bOID),
            RelayRunLaneRecord(runID: rTopo, laneID: "c", ordinal: 1, agent: .agy, promptPath: "p.md", after: [], status: .succeeded, branch: "relay/\(rTopo)/c", commitOID: cOID),
            RelayRunLaneRecord(runID: rTopo, laneID: "a", ordinal: 2, agent: .claude, promptPath: "p.md", after: [], status: .succeeded, branch: "relay/\(rTopo)/a", commitOID: aOID)
        ]
        try seedRun(rTopo, lanes: topoLanes)
        final class LineBox: @unchecked Sendable { var lines: [String] = [] }
        let stderrBox = LineBox()
        let topoRes = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
            runID: rTopo,
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            baseCommitOID: baseOID,
            lanes: topoLanes,
            planOrder: ["b", "c", "a"],
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv,
            onStderrLine: { stderrBox.lines.append($0) }
        )
        #expect(topoRes.status == .merged)
        #expect(topoRes.ready == false)
        #expect(topoRes.merges.map(\.laneID) == ["c", "a", "b"])
        #expect(topoRes.merges.map(\.status) == [.merged, .merged, .merged])
        // 1 branch created line + 3 merge lines + 1 summary line = 5 stderr lines
        #expect(stderrBox.lines.count == 5)
        let firstParentCommits = try engine.runGit(
            ["rev-list", "--reverse", "--first-parent", "\(baseOID)..refs/heads/relay/\(rTopo)/integration"],
            cwd: repoDir.path,
            environment: gitEnv
        ).split(whereSeparator: \.isNewline).map(String.init)
        #expect(firstParentCommits.count == 3)
        let secondParents = try firstParentCommits.map {
            try engine.runGit(["rev-parse", "\($0)^2"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(secondParents == [cOID, aOID, bOID])
        let mainAfterTopo = try engine.runGit(["rev-parse", "main"], cwd: repoDir.path, environment: gitEnv).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mainAfterTopo == baseOID)

        // Case 4: Conflict stop (D3: a merges, b conflicts, c is not-attempted)
        let rConf = "20261117-040003-conf"
        let confLanes = [
            RelayRunLaneRecord(runID: rConf, laneID: "a", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeeded, branch: "relay/\(rConf)/a", commitOID: aOID),
            RelayRunLaneRecord(runID: rConf, laneID: "b", ordinal: 1, agent: .codex, promptPath: "p.md", status: .succeeded, branch: "relay/\(rConf)/b", commitOID: bConflictOID),
            RelayRunLaneRecord(runID: rConf, laneID: "c", ordinal: 2, agent: .vibe, promptPath: "p.md", status: .succeeded, branch: "relay/\(rConf)/c", commitOID: cOID)
        ]
        try seedRun(rConf, lanes: confLanes)
        let confRes = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
            runID: rConf,
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            baseCommitOID: baseOID,
            lanes: confLanes,
            planOrder: ["a", "b", "c"],
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv
        )
        #expect(confRes.status == .conflict)
        #expect(confRes.ready == false)
        #expect(confRes.merges.map(\.status) == [.merged, .conflict, .notAttempted])

        // Case 5: Pre-merge cancellation (`isCancelled` true at entry) -> `cancelled`, no branch/worktree
        let rPreCancel = "20261117-040004-precancel"
        let preCancelLanes = [
            RelayRunLaneRecord(runID: rPreCancel, laneID: "a", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeeded, branch: "relay/\(rPreCancel)/a", commitOID: aOID)
        ]
        try seedRun(rPreCancel, lanes: preCancelLanes)
        let preCancelRes = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
            runID: rPreCancel,
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            baseCommitOID: baseOID,
            lanes: preCancelLanes,
            planOrder: ["a"],
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv,
            isCancelled: { true }
        )
        #expect(preCancelRes.status == .cancelled)
        #expect(preCancelRes.branch == nil && preCancelRes.worktreePath == nil)

        // Case 6: Between-step cancellation (`isCancelled` turns true after first lane `a` merges, before `c` starts)
        let rMidCancel = "20261117-040005-midcancel"
        let midCancelLanes = [
            RelayRunLaneRecord(runID: rMidCancel, laneID: "a", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeeded, branch: "relay/\(rMidCancel)/a", commitOID: aOID),
            RelayRunLaneRecord(runID: rMidCancel, laneID: "c", ordinal: 1, agent: .vibe, promptPath: "p.md", status: .succeeded, branch: "relay/\(rMidCancel)/c", commitOID: cOID)
        ]
        try seedRun(rMidCancel, lanes: midCancelLanes)
        final class CancelToggle: @unchecked Sendable { var cancelled = false }
        let toggle = CancelToggle()
        let midCancelRes = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
            runID: rMidCancel,
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            baseCommitOID: baseOID,
            lanes: midCancelLanes,
            planOrder: ["a", "c"],
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv,
            isCancelled: { toggle.cancelled },
            onStderrLine: { line in
                if line.contains("merge lane a") {
                    toggle.cancelled = true
                }
            }
        )
        #expect(midCancelRes.status == .cancelled)
        #expect(midCancelRes.ready == false)
        #expect(midCancelRes.merges.map(\.status) == [.merged, .notAttempted])
        #expect(midCancelRes.headCommitOID == midCancelRes.merges[0].mergeCommitOID)

        // Case 7: 125 error when integration worktree path is obstructed by a regular file (Row 22) -> persists `.error` in SQLite
        let rErr125 = "20261117-040006-err125"
        let errLanes = [
            RelayRunLaneRecord(runID: rErr125, laneID: "a", ordinal: 0, agent: .claude, promptPath: "p.md", status: .succeeded, branch: "relay/\(rErr125)/a", commitOID: aOID)
        ]
        try seedRun(rErr125, lanes: errLanes)
        let obstructedURL = projectDir.appendingPathComponent("runs/\(rErr125)/worktrees/integration")
        try FileManager.default.createDirectory(at: obstructedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "blocker-file\n".write(to: obstructedURL, atomically: true, encoding: .utf8)
        do {
            _ = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
                runID: rErr125,
                repositoryPath: repoDir.path,
                projectBundlePath: projectDir.path,
                baseCommitOID: baseOID,
                lanes: errLanes,
                planOrder: ["a"],
                database: db,
                gitEngine: engine,
                language: .en,
                environment: gitEnv
            )
            Issue.record("Expected 125 error when integration worktree path is obstructed")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
        let persistedErr = try #require(try db.fetchRun(runID: rErr125, reconcileWithLock: false)?.integration)
        #expect(persistedErr.status == .error)
        #expect(persistedErr.ready == false)
    }

    // MARK: - 24. M2 Deferred Terminal Run Status Write After Post-Lane Integration Slot (R61)

    @Test("RelayDAGRunScheduler keeps relay_runs.status == .running after all lanes complete so integration/verify execute before terminal run status is persisted (R61)")
    func schedulerDefersTerminalRunStatusUntilAfterPostLaneIntegrationSlot() async throws {
        let tempRoot = try makeMktempDirectory(prefix: "relay-m2-r61")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let projectDir = tempRoot.appendingPathComponent("Proj.relayproj", isDirectory: true)
        let plansDir = tempRoot.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        let gitEnv = makeIsolatedGitEnvironment(homeDir: homeDir)

        let engine = GitWorktreePlumbingEngine()
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "R61 Tester"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "r61@relay.invalid"], cwd: repoDir.path, environment: gitEnv)
        try "seed\n".write(to: repoDir.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "seed.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "seed"], cwd: repoDir.path, environment: gitEnv)

        // Minimal local runner script inside mktemp (never invokes relay.sh)
        let stubRunnerURL = tempRoot.appendingPathComponent("mini-runner.sh")
        let stubUtilURL = tempRoot.appendingPathComponent("relay_util.py")
        try "#!/bin/sh\nprintf 'lane-output\\n' > \"$2/lane_out.txt\"\nexit 0\n".write(
            to: stubRunnerURL,
            atomically: true,
            encoding: .utf8
        )
        try "# stub\n".write(to: stubUtilURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubRunnerURL.path)

        let promptURL = plansDir.appendingPathComponent("api.md")
        try "Write lane_out.txt\n".write(to: promptURL, atomically: true, encoding: .utf8)
        let planURL = plansDir.appendingPathComponent("plan.json")
        try """
        {
          "repo": "\(repoDir.path)",
          "base": "main",
          "lanes": [
            {"id": "api", "agent": "claude", "prompt": "api.md", "after": []}
          ]
        }
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let db = try RelayProjectDatabase(bundleDirectoryURL: projectDir)
        let validated = try RelayPlanValidator.validate(
            planFileURL: planURL,
            projectBundleURL: projectDir,
            environment: gitEnv,
            language: .en
        )
        let resolvedRunner = try RelayRunExecutor.resolveAndVerifyRelayScript(
            explicitPath: stubRunnerURL.path,
            environment: gitEnv,
            language: .en
        )

        let runID = "20261117-050000-r61a"
        let runDir = projectDir.appendingPathComponent("runs/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let planCopyURL = runDir.appendingPathComponent("plan.json")
        try validated.rawPlanData.write(to: planCopyURL, options: .atomic)

        try db.createRun(
            RelayRunRecord(
                runID: runID,
                repoPath: validated.resolvedRepoURL.path,
                planCopyPath: planCopyURL.path,
                baseRef: validated.baseRef,
                baseCommitOID: validated.baseCommitOID,
                verifyCommand: nil,
                relayShPath: resolvedRunner.url.path,
                relayShSHA256: resolvedRunner.sha256Hex,
                startedAt: Date(),
                finishedAt: nil,
                status: .running,
                reason: nil,
                relayidePID: getpid(),
                lanes: validated.lanes.map {
                    RelayRunLaneRecord(
                        runID: runID,
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

        let scheduler = RelayDAGRunScheduler(
            runID: runID,
            validatedPlan: validated,
            relayScript: resolvedRunner,
            runDirectoryURL: runDir,
            projectBundleURL: projectDir,
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv,
            emitStderrLine: { _ in }
        )

        // 1. Execute lanes phase ONLY: all lanes MUST be committed & terminal in SQLite,
        // while `relay_runs.status` MUST STILL BE `.running` (`finishedAt == nil`)!
        let laneSummary = try await scheduler.executeLanesPhase()
        #expect(laneSummary.runStatus == .succeeded)
        #expect(laneSummary.orderedLanes.count == 1)
        #expect(laneSummary.orderedLanes[0].status == .succeeded)
        #expect(laneSummary.orderedLanes[0].commitOID != nil)

        let midRunRecord = try #require(try db.fetchRun(runID: runID, reconcileWithLock: false))
        #expect(midRunRecord.status == .running)
        #expect(midRunRecord.finishedAt == nil)
        #expect(midRunRecord.lanes[0].status == .succeeded)

        // 2. Run `runIntegrationMergePhase` inside this post-lane slot while `relay_runs.status` is still `.running`
        let integrationResult = try RelayIntegrationMergeRunner.runIntegrationMergePhase(
            runID: runID,
            repositoryPath: validated.resolvedRepoURL.path,
            projectBundlePath: projectDir.path,
            baseCommitOID: validated.baseCommitOID,
            lanes: laneSummary.orderedLanes,
            planOrder: validated.lanes.map(\.id),
            database: db,
            gitEngine: engine,
            language: .en,
            environment: gitEnv
        )
        #expect(integrationResult.status == .merged)
        let stillRunningDuringIntegration = try #require(try db.fetchRun(runID: runID, reconcileWithLock: false))
        #expect(stillRunningDuringIntegration.status == .running)
        #expect(stillRunningDuringIntegration.integration?.status == .merged)

        // 3. Persist terminal run status AFTER the integration slot -> now `relay_runs.status` transitions to `.succeeded`
        let finalized = try scheduler.persistTerminalRunStatus(afterIntegration: laneSummary)
        #expect(finalized.cliExitCode == 0)
        #expect(finalized.runRecord.status == .succeeded)
        #expect(finalized.runRecord.finishedAt != nil)
        #expect(finalized.runRecord.integration?.status == .merged)
    }

    // MARK: - 25. M2 `RelayVerifyRunner` & Verify Stderr Formatter Direct Unit Tests (§6, §7, §10; R51–R54)

    private struct VerifyTestFixture {
        let tempRoot: URL
        let tempToken: String
        let homeDir: URL
        let repoDir: URL
        let projectDir: URL
        let runID: String
        let baseOID: String
        let integrationWorktreePath: String
        let gitEnv: [String: String]
        let engine: GitWorktreePlumbingEngine
    }

    private func makeVerifyIntegrationFixture(prefix: String = "relay-m2-verify") throws -> VerifyTestFixture {
        let tempRoot = try makeMktempDirectory(prefix: prefix)
        let tempToken = tempRoot.lastPathComponent
        let homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let projectDir = tempRoot.appendingPathComponent("Proj.relayproj", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let gitEnv = makeIsolatedGitEnvironment(homeDir: homeDir)

        let engine = GitWorktreePlumbingEngine()
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "Verify Runner Tester"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "verify@relay.invalid"], cwd: repoDir.path, environment: gitEnv)

        let srcDir = repoDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "initial-a\n".write(to: srcDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "src/a.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "base"], cwd: repoDir.path, environment: gitEnv)
        let baseOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let runID = "20261117-060000-vf01"
        let wt = try engine.createIntegrationWorktree(
            repositoryPath: repoDir.path,
            projectBundlePath: projectDir.path,
            runID: runID,
            baseCommitOID: baseOID,
            environment: gitEnv
        )
        return VerifyTestFixture(
            tempRoot: tempRoot,
            tempToken: tempToken,
            homeDir: homeDir,
            repoDir: repoDir,
            projectDir: projectDir,
            runID: runID,
            baseOID: baseOID,
            integrationWorktreePath: wt.worktreePath,
            gitEnv: gitEnv,
            engine: engine
        )
    }

    private static func listProcessesMatchingToken(_ needle: String) throws -> [(pid: Int32, ppid: Int32, command: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        var results: [(pid: Int32, ppid: Int32, command: String)] = []
        for rawLine in output.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(needle) else { continue }
            let parts = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            results.append((pid: pid, ppid: ppid, command: String(parts[2])))
        }
        return results
    }

    @Test("RelayVerifyRunner handles 300 KB output + exit 1 without hanging or false timeout, recording failed, exitCode 1, and exact logBytes (§6, Item 6.1, R23)")
    func verifyRunner300KBOutputAndExit1() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vf300k")
        defer { try? FileManager.default.removeItem(at: fx.tempRoot) }

        let cmd = """
        /usr/bin/python3 -I -c 'import sys; sys.stdout.buffer.write(b"x" * 307200); sys.stdout.buffer.flush(); sys.stderr.write("VERIFY_STDERR_300K_MARKER\\n"); sys.stderr.flush()'
        exit 1
        """

        let outcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: cmd,
            timeoutSec: 30,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv
        )
        let record = outcome.verifyRecord
        #expect(record.status == .failed)
        #expect(record.exitCode == 1)
        #expect(record.signal == nil)
        #expect(record.logTruncated == false)
        #expect(outcome.integrationStatus == .verifyFailed)
        #expect(outcome.ready == false)

        let expectedLogPath = RelayVerifyRunner.defaultVerifyLogPath(
            projectBundlePath: fx.projectDir.path,
            runID: fx.runID
        )
        #expect(record.logPath == expectedLogPath)
        let logData = try Data(contentsOf: URL(fileURLWithPath: expectedLogPath))
        #expect(record.logBytes == logData.count)
        #expect(record.logBytes >= 307_200)
        let logText = String(decoding: logData, as: UTF8.self)
        #expect(logText.contains(String(repeating: "x", count: 1024)))
        #expect(logText.contains("VERIFY_STDERR_300K_MARKER"))
    }

    @Test("RelayVerifyRunner escalates INT -> TERM -> KILL on timeout and cancellation, cleaning up stubborn setpgrp child + grandchild with zero leftover processes (§6, Item 6.2, R52, R54)")
    func verifyRunnerTimeoutWithStubbornDescendantsAndCancellation() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vftmo")
        let tempToken = fx.tempToken
        var trackedChildPID: pid_t = -1
        var trackedGrandchildPID: pid_t = -1
        defer {
            if trackedGrandchildPID > 0 { _ = Darwin.kill(-trackedGrandchildPID, SIGKILL); _ = Darwin.kill(trackedGrandchildPID, SIGKILL) }
            if trackedChildPID > 0 { _ = Darwin.kill(-trackedChildPID, SIGKILL); _ = Darwin.kill(trackedChildPID, SIGKILL) }
            if let leftovers = try? Self.listProcessesMatchingToken(tempToken) {
                for p in leftovers { _ = Darwin.kill(p.pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: fx.tempRoot)
        }

        let childPIDURL = fx.tempRoot.appendingPathComponent("stubborn-child.pid")
        let grandchildPIDURL = fx.tempRoot.appendingPathComponent("stubborn-grandchild.pid")
        let readyURL = fx.tempRoot.appendingPathComponent("stubborn-ready")

        let stubbornCmd = """
        /usr/bin/perl -MPOSIX=setpgid -e '
            my ($cfile, $gcfile, $rfile, $tok) = @ARGV;
            setpgid(0, 0) or die "setpgid: $!";
            $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
            my $gc = fork();
            die "fork: $!" unless defined $gc;
            if ($gc == 0) {
                $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
                open(my $gfh, ">", $gcfile) or die $!;
                print $gfh "$$\\n";
                close($gfh);
                select(undef, undef, undef, 30);
                exit 0;
            }
            for (1..200) { last if -s $gcfile; select(undef, undef, undef, 0.01); }
            open(my $cfh, ">", $cfile) or die $!;
            print $cfh "$$\\n";
            close($cfh);
            open(my $rfh, ">", $rfile) or die $!;
            print $rfh "ready\\n";
            close($rfh);
            select(undef, undef, undef, 30);
        ' "\(childPIDURL.path)" "\(grandchildPIDURL.path)" "\(readyURL.path)" "\(tempToken)" </dev/null >/dev/null 2>&1 &
        while [ ! -s "\(readyURL.path)" ]; do /bin/sleep 0.02; done
        /usr/bin/perl -e 'select(undef, undef, undef, 30);' "\(tempToken)-verify-leader"
        """

        let timeoutOutcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: stubbornCmd,
            timeoutSec: 1,
            sigintGraceSeconds: 0.2,
            sigtermGraceSeconds: 0.2,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv
        )

        if let rawC = try? String(contentsOf: childPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pidC = pid_t(rawC) {
            trackedChildPID = pidC
        }
        if let rawGC = try? String(contentsOf: grandchildPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pidGC = pid_t(rawGC) {
            trackedGrandchildPID = pidGC
        }

        #expect(trackedChildPID > 0 && trackedGrandchildPID > 0)
        #expect(timeoutOutcome.verifyRecord.status == .timeout)
        #expect(timeoutOutcome.verifyRecord.exitCode == nil)
        #expect(timeoutOutcome.integrationStatus == .verifyTimeout)
        #expect(timeoutOutcome.ready == false)
        #expect(timeoutOutcome.survivingPIDs.isEmpty)
        #expect(Darwin.kill(trackedChildPID, 0) != 0, "Stubborn setpgrp child survived verify timeout escalation")
        #expect(Darwin.kill(trackedGrandchildPID, 0) != 0, "Stubborn grandchild survived verify timeout escalation")
        let remainingAfterTimeout = try Self.listProcessesMatchingToken(tempToken)
        #expect(remainingAfterTimeout.isEmpty)

        // 2. Cancellation via `isCancelled()` closure also runs escalation ladder and records `.cancelled`.
        let cancelRunID = "20261117-060001-vfcn"
        let cancelReadyURL = fx.tempRoot.appendingPathComponent("cancel-ready")
        final class CancelBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
            func cancel() { lock.lock(); value = true; lock.unlock() }
        }
        let cancelBox = CancelBox()
        let cancelCmd = """
        : > "\(cancelReadyURL.path)"
        /usr/bin/perl -e 'select(undef, undef, undef, 30);' "\(tempToken)-cancel-wait"
        """
        let cancelTriggerTask = Task {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: cancelReadyURL.path) {
                    cancelBox.cancel()
                    break
                }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        let cancelOutcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: cancelRunID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: cancelCmd,
            timeoutSec: 30,
            sigintGraceSeconds: 0.2,
            sigtermGraceSeconds: 0.2,
            gitEngine: fx.engine,
            language: .zhHans,
            environment: fx.gitEnv,
            isCancelled: { cancelBox.isCancelled }
        )
        await cancelTriggerTask.value
        #expect(cancelOutcome.verifyRecord.status == .cancelled)
        #expect(cancelOutcome.integrationStatus == .cancelled)
        #expect(cancelOutcome.ready == false)
        let remainingAfterCancel = try Self.listProcessesMatchingToken(tempToken)
        #expect(remainingAfterCancel.isEmpty)

        // 3. When both descendant enumeration methods fail, reason reports potentially leftover PIDs instead of claiming clean exit.
        let enumFailRunID = "20261117-060002-vfef"
        let enumFailOutcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: enumFailRunID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: "/usr/bin/perl -e 'select(undef, undef, undef, 30);' \"\(tempToken)-enum-fail\"",
            timeoutSec: 1,
            sigintGraceSeconds: 0.2,
            sigtermGraceSeconds: 0.2,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv,
            descendantEnumerator: { _ in ([], false) }
        )
        #expect(enumFailOutcome.enumerationSucceeded == false)
        if let failPID = enumFailOutcome.verifyRecord.pid {
            #expect(enumFailOutcome.integrationReason?.contains("\(failPID)") == true)
        } else {
            Issue.record("Expected verify PID to be recorded")
        }
        let remainingFinal = try Self.listProcessesMatchingToken(tempToken)
        #expect(remainingFinal.isEmpty)
    }

    @Test("RelayVerifyRunner decodes signal death (`kill -9 $$`) via POSIXWaitStatus as failed with signal 9 and nil exitCode (§6, Item 6.3, R53)")
    func verifyRunnerKilledBySignal9() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vfsig9")
        defer { try? FileManager.default.removeItem(at: fx.tempRoot) }

        let outcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: "kill -9 $$",
            timeoutSec: 20,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv
        )
        let record = outcome.verifyRecord
        #expect(record.status == .failed)
        #expect(record.signal == 9)
        #expect(record.exitCode == nil)
        #expect(outcome.integrationStatus == .verifyFailed)
        #expect(outcome.ready == false)
        #expect(outcome.integrationReason?.contains("signal 9") == true)
    }

    @Test("RelayVerifyRunner throws cliExitCode == 125 when integration worktree directory does not exist instead of running in caller cwd (§6, Item 6.4, R53)")
    func verifyRunnerMissingWorkingDirectoryThrows125() async throws {
        let tempRoot = try makeMktempDirectory(prefix: "relay-m2-vfmissing")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projectDir = tempRoot.appendingPathComponent("Proj.relayproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let missingWorktree = tempRoot.appendingPathComponent("nonexistent-worktree")
        let fallbackMarker = tempRoot.appendingPathComponent("must-not-run.marker")

        do {
            _ = try await RelayVerifyRunner.runVerify(
                runID: "20261117-060003-vfms",
                projectBundlePath: projectDir.path,
                integrationWorktreePath: missingWorktree.path,
                command: "echo leaked > \"\(fallbackMarker.path)\"",
                timeoutSec: 10
            )
            Issue.record("Expected RelayVerifyRunner.runVerify to throw 125 when working directory is missing")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
        #expect(!FileManager.default.fileExists(atPath: fallbackMarker.path))

        // Regular file at integrationWorktreePath must also fail with 125
        let regularFileURL = tempRoot.appendingPathComponent("not-a-dir.txt")
        try "file\n".write(to: regularFileURL, atomically: true, encoding: .utf8)
        do {
            _ = try await RelayVerifyRunner.runVerify(
                runID: "20261117-060004-vffl",
                projectBundlePath: projectDir.path,
                integrationWorktreePath: regularFileURL.path,
                command: "true",
                timeoutSec: 10
            )
            Issue.record("Expected RelayVerifyRunner.runVerify to throw 125 when working directory path is a regular file")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }
    }

    @Test("RelayVerifyRunner marks verify failed and lists modifiedTrackedFiles when exit 0 dirtied tracked files (§6, Item 6.5, Row 16)")
    func verifyRunnerDetectsModifiedTrackedFilesAfterExit0() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vfdirty")
        defer { try? FileManager.default.removeItem(at: fx.tempRoot) }

        // Modify tracked `src/a.txt` AND write an untracked `scratch.tmp` (`--untracked-files=no` ignores untracked files).
        let cmd = """
        printf 'mutated-by-verify\\n' >> src/a.txt
        printf 'untracked\\n' > scratch.tmp
        exit 0
        """
        let outcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: cmd,
            timeoutSec: 20,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv
        )
        let record = outcome.verifyRecord
        #expect(record.status == .failed)
        #expect(record.exitCode == 0)
        #expect(record.signal == nil)
        #expect(record.modifiedTrackedFiles == ["src/a.txt"])
        #expect(outcome.integrationStatus == .verifyFailed)
        #expect(outcome.ready == false)
        #expect(outcome.integrationReason?.contains("src/a.txt") == true)
    }

    @Test("RelayVerifyRunner redirects stdin from /dev/null so `cat` finishes immediately with EOF while keeping controlling TTY and git pager suppression (§6, Item 6.6, Row 10)")
    func verifyRunnerCatStdinImmediatelyReceivesEOF() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vfcat")
        defer { try? FileManager.default.removeItem(at: fx.tempRoot) }

        let stdinDumpURL = fx.tempRoot.appendingPathComponent("cat-stdin.bin")
        let probeURL = fx.tempRoot.appendingPathComponent("tty-probe.txt")
        let cmd = """
        if test -t 0; then s0=1; else s0=0; fi
        if test -t 1; then s1=1; else s1=0; fi
        /usr/bin/git log -1 >/dev/null
        /bin/cat > "\(stdinDumpURL.path)"
        printf '%s|%s' "$s0" "$s1" > "\(probeURL.path)"
        exit 0
        """

        let outcome = try await RelayVerifyRunner.runVerifyWithOutcome(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: cmd,
            timeoutSec: 10,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv
        )
        #expect(outcome.verifyRecord.status == .passed)
        #expect(outcome.verifyRecord.exitCode == 0)
        #expect(outcome.verifyRecord.signal == nil)
        #expect(outcome.verifyRecord.modifiedTrackedFiles.isEmpty)
        #expect(outcome.integrationStatus == .verified)
        #expect(outcome.ready == true)

        let catBytes = try Data(contentsOf: stdinDumpURL)
        #expect(catBytes.isEmpty)
        let probeText = try String(contentsOf: probeURL, encoding: .utf8)
        #expect(probeText == "0|1")
    }

    @Test("RelayVerifyRunner preserves caller PATH verbatim without login-shell reordering, sets PAGER=cat & GIT_PAGER=cat, delivers PID/startedAt via onStarted, and emits bilingual stderr lines (§6, §10, Item 6.7, R51)")
    func verifyRunnerPreservesCallerPathVerbatimAndInvokesStartCallback() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vfpath")
        defer { try? FileManager.default.removeItem(at: fx.tempRoot) }

        let decoyDir = fx.tempRoot.appendingPathComponent("first-decoy-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        let expectedPath = "\(decoyDir.path):/usr/bin:/bin"

        var customEnv = fx.gitEnv
        customEnv["PATH"] = expectedPath

        let pathOutURL = fx.tempRoot.appendingPathComponent("observed-path.txt")
        let pagerOutURL = fx.tempRoot.appendingPathComponent("observed-pagers.txt")
        let cwdOutURL = fx.tempRoot.appendingPathComponent("observed-cwd.txt")

        final class CallbackCapture: @unchecked Sendable {
            var startedPID: Int32?
            var startedAt: Date?
            var runningRecord: RelayRunVerifyRecord?
            var stderrLinesEN: [String] = []
            var stderrLinesZH: [String] = []
        }
        let capture = CallbackCapture()

        let cmd = """
        printf '%s' "$PATH" > "\(pathOutURL.path)"
        printf '%s|%s' "$PAGER" "$GIT_PAGER" > "\(pagerOutURL.path)"
        pwd -P > "\(cwdOutURL.path)"
        """

        let recordEN = try await RelayVerifyRunner.runVerify(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: cmd,
            timeoutSec: 45,
            gitEngine: fx.engine,
            language: .en,
            environment: customEnv,
            onStarted: { pid, startedAt, runningRec in
                capture.startedPID = pid
                capture.startedAt = startedAt
                capture.runningRecord = runningRec
            },
            onStderrLine: { capture.stderrLinesEN.append($0) }
        )

        #expect(recordEN.status == .passed)
        #expect(recordEN.exitCode == 0)
        #expect(try String(contentsOf: pathOutURL, encoding: .utf8) == expectedPath)
        #expect(try String(contentsOf: pagerOutURL, encoding: .utf8) == "cat|cat")
        let expectedRealPtr = Darwin.realpath(fx.integrationWorktreePath, nil)
        defer { if let p = expectedRealPtr { free(p) } }
        let realExpectedWT = expectedRealPtr.map { String(cString: $0) } ?? fx.integrationWorktreePath
        let realObservedWT = try String(contentsOf: cwdOutURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(realObservedWT == realExpectedWT)

        let startedPID = try #require(capture.startedPID)
        #expect(startedPID > 0)
        #expect(recordEN.pid == startedPID)
        #expect(capture.runningRecord?.status == .running)
        #expect(capture.runningRecord?.pid == startedPID)
        if let sAt = capture.startedAt, let fAt = recordEN.finishedAt {
            #expect(fAt >= sAt)
        } else {
            Issue.record("Expected startedAt and finishedAt to be populated")
        }

        // Also run in ZH to verify bilingual verify start & finish stderr lines
        let runZH = "20261117-060005-vfzh"
        let wtZH = try fx.engine.createIntegrationWorktree(
            repositoryPath: fx.repoDir.path,
            projectBundlePath: fx.projectDir.path,
            runID: runZH,
            baseCommitOID: fx.baseOID,
            environment: customEnv
        )
        _ = try await RelayVerifyRunner.runVerify(
            runID: runZH,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: wtZH.worktreePath,
            command: "true",
            timeoutSec: 45,
            gitEngine: fx.engine,
            language: .zhHans,
            environment: customEnv,
            onStderrLine: { capture.stderrLinesZH.append($0) }
        )

        #expect(capture.stderrLinesEN.count == 2)
        #expect(capture.stderrLinesZH.count == 2)
        #expect(capture.stderrLinesEN[0] != capture.stderrLinesZH[0])
        #expect(capture.stderrLinesEN[1] != capture.stderrLinesZH[1])
        #expect(capture.stderrLinesEN[0].contains("\(startedPID)") && capture.stderrLinesEN[0].contains("45s"))
        #expect(capture.stderrLinesEN[1].contains("passed") && capture.stderrLinesEN[1].contains("exit 0") && capture.stderrLinesEN[1].contains("verify.pty"))
        #expect(capture.stderrLinesZH[0].contains("PID") && capture.stderrLinesZH[0].contains("45s"))
        #expect(capture.stderrLinesZH[1].contains("通过") && capture.stderrLinesZH[1].contains("退出码 0") && capture.stderrLinesZH[1].contains("verify.pty"))
        #expect(!capture.stderrLinesZH[0].contains("lane ") && !capture.stderrLinesZH[1].contains("lane "))
    }

    @Test("RelayVerifyRunner caps verify.pty at 16 MiB (16777216 bytes), continues reading 20 MiB output without blocking, and sets logTruncated == true (§6, Item 6.8, Row 13)")
    func verifyRunnerTruncatesLogAtMaxBytesAndContinuesDraining() async throws {
        let fx = try makeVerifyIntegrationFixture(prefix: "relay-m2-vf16m")
        defer { try? FileManager.default.removeItem(at: fx.tempRoot) }

        // Emit 20 MiB (320 * 65536 = 20,971,520 bytes) against the default 16 MiB (16,777,216 bytes) cap.
        let cmd = """
        /usr/bin/python3 -I -c '
        import sys
        chunk = b"v" * 65536
        out = sys.stdout.buffer
        for _ in range(320):
            out.write(chunk)
        out.flush()
        '
        exit 0
        """

        let record = try await RelayVerifyRunner.runVerify(
            runID: fx.runID,
            projectBundlePath: fx.projectDir.path,
            integrationWorktreePath: fx.integrationWorktreePath,
            command: cmd,
            timeoutSec: 60,
            gitEngine: fx.engine,
            language: .en,
            environment: fx.gitEnv
        )

        let expectedCap = Int(RelayVerifyRunner.defaultMaxLogBytes)
        #expect(expectedCap == 16_777_216)
        #expect(record.status == .passed)
        #expect(record.exitCode == 0)
        #expect(record.logTruncated == true)
        #expect(record.logBytes == expectedCap)

        let logPath = try #require(record.logPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: logPath)
        let onDiskSize = (attrs[.size] as? NSNumber)?.intValue
        #expect(onDiskSize == expectedCap)
    }
}
