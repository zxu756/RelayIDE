import Foundation
import RelayModels
import RelayPTYCore
import RelayPluginSDK
import RelaySemanticMerge
import RelayWorkspaceStore
import RelayWorktreeGit

// MARK: - Topological Multi-Vendor Agent DAG Scheduler & Workspace Coordinator

public final class MultiVendorDAGOrchestrator: @unchecked Sendable {
    public let database: RelayProjectDatabase
    public let undoRedo: RelayUndoRedoController
    public let ptyGrid: PTYMultiplexerGrid
    public let gitEngine: GitWorktreePlumbingEngine
    public let ownershipMonitor: FSEventsOwnershipMonitor
    public let semanticMerger: ThreeWaySemanticASTMerger
    public let pluginHost: RelayJavaScriptPluginHost

    public init(database: RelayProjectDatabase) {
        self.database = database
        self.undoRedo = RelayUndoRedoController(database: database)
        self.ptyGrid = PTYMultiplexerGrid()
        let git = GitWorktreePlumbingEngine()
        self.gitEngine = git
        self.ownershipMonitor = FSEventsOwnershipMonitor(gitEngine: git)
        self.semanticMerger = ThreeWaySemanticASTMerger()
        self.pluginHost = RelayJavaScriptPluginHost()
    }

    /// Computes topological execution waves (parallelizable stages) via Kahn's algorithm, or throws `.cyclicTaskDependency`.
    public func computeTopologicalWaves(for dag: RelayDAGSpec) throws -> [[RelayTaskNode]] {
        var nodeByID: [String: RelayTaskNode] = [:]
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]

        for task in dag.tasks {
            nodeByID[task.id] = task
            inDegree[task.id] = 0
        }

        for task in dag.tasks {
            for dep in task.dependsOnTaskIDs where nodeByID[dep] != nil {
                inDegree[task.id, default: 0] += 1
                dependents[dep, default: []].append(task.id)
            }
        }

        var currentWaveIDs = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var waves: [[RelayTaskNode]] = []
        var visitedCount = 0

        while !currentWaveIDs.isEmpty {
            let waveNodes = currentWaveIDs.compactMap { nodeByID[$0] }
            waves.append(waveNodes)
            visitedCount += waveNodes.count

            var nextWave: [String] = []
            for finishedID in currentWaveIDs {
                for childID in (dependents[finishedID] ?? []) {
                    let updated = (inDegree[childID] ?? 1) - 1
                    inDegree[childID] = updated
                    if updated == 0 {
                        nextWave.append(childID)
                    }
                }
            }
            currentWaveIDs = nextWave.sorted()
        }

        if visitedCount < dag.tasks.count {
            let cycleIDs = inDegree.filter { $0.value > 0 }.map(\.key).sorted()
            throw RelayIDEError.cyclicTaskDependency(cycleIDs)
        }
        return waves
    }

    /// Seeds a complete, deterministic multi-vendor workspace with real Git commits, PTY transcripts, 3-Way AST Merges, and Guardrail findings.
    public func seedIndustrialDemoWorkspace(workspaceName: String = "PaymentsCore-Relay") throws {
        let demoRepoDir = database.bundleDirectoryURL.appendingPathComponent("demo-repo").path
        if !FileManager.default.fileExists(atPath: (demoRepoDir as NSString).appendingPathComponent(".git")) {
            _ = try gitEngine.initializeDemoRepository(at: demoRepoDir)
        }
        let headOID = (try? gitEngine.headCommitOID(at: demoRepoDir)) ?? "a4f901c8e2b70019384756102938475610293847"

        try database.setMeta(key: "workspace_name", value: workspaceName)
        try database.setMeta(key: "repository_path", value: demoRepoDir)
        try database.setMeta(key: "is_demo_workspace", value: "1")

        // 1. Register 4 Vendor Worktree Lanes (Claude Code, Codex, Antigravity, Mistral Vibe)
        let lanes: [ManagedWorktreeLane] = [
            ManagedWorktreeLane(
                id: "lane-claude-core",
                displayName: "Claude Code · Ledger Core",
                assignedVendor: .claudeCode,
                worktreePath: "\(demoRepoDir)/.worktrees/lane-claude-core",
                branchName: "relay/lane-claude-core",
                baseCommitOID: headOID,
                headCommitOID: "c91b42e0a8173920184726354819203948571625",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Sources/Ledger/BillingEngine.swift", status: .modified, additions: 42, deletions: 6),
                    WorktreeFileDelta(relativePath: "Sources/Ledger/InvoiceSettlement.swift", status: .added, additions: 118, deletions: 0)
                ],
                ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/Ledger/**"], forbiddenGlobs: [".git/**", "Tests/**"])
            ),
            ManagedWorktreeLane(
                id: "lane-codex-tax",
                displayName: "OpenAI Codex · Tax &FX Rules",
                assignedVendor: .codex,
                worktreePath: "\(demoRepoDir)/.worktrees/lane-codex-tax",
                branchName: "relay/lane-codex-tax",
                baseCommitOID: headOID,
                headCommitOID: "d83f19c4b0029384756102938475610293847111",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Sources/Ledger/BillingEngine.swift", status: .modified, additions: 38, deletions: 4),
                    WorktreeFileDelta(relativePath: "Sources/Tax/VATJurisdictionTable.swift", status: .added, additions: 94, deletions: 0)
                ],
                ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/Ledger/**", "Sources/Tax/**"], forbiddenGlobs: [".git/**"])
            ),
            ManagedWorktreeLane(
                id: "lane-agy-docs",
                displayName: "Antigravity · API Gateway & Spec",
                assignedVendor: .antigravity,
                worktreePath: "\(demoRepoDir)/.worktrees/lane-agy-docs",
                branchName: "relay/lane-agy-docs",
                baseCommitOID: headOID,
                headCommitOID: "e72a88b1c9928374650192837465019283746222",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Sources/Gateway/CheckoutRouter.swift", status: .modified, additions: 64, deletions: 11),
                    WorktreeFileDelta(relativePath: "docs/ARCHITECTURE.md", status: .modified, additions: 85, deletions: 8)
                ],
                ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/Gateway/**", "docs/**"], forbiddenGlobs: [".git/**"])
            ),
            ManagedWorktreeLane(
                id: "lane-vibe-tests",
                displayName: "Mistral Vibe · Property Tests",
                assignedVendor: .mistralVibe,
                worktreePath: "\(demoRepoDir)/.worktrees/lane-vibe-tests",
                branchName: "relay/lane-vibe-tests",
                baseCommitOID: headOID,
                headCommitOID: "f10d77e3d4455667788990011223344556677333",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Tests/LedgerTests/BillingPropertyTests.swift", status: .added, additions: 156, deletions: 0)
                ],
                ownershipRule: FileOwnershipRule(allowedGlobs: ["Tests/**"], forbiddenGlobs: ["Sources/**"])
            )
        ]

        for lane in lanes {
            try database.saveLane(lane)
            let pty = ptyGrid.getOrCreateSession(laneID: lane.id, rows: 22, columns: 88)
            pty.screenBuffer.feed(Self.sampleANSIOutput(for: lane))
        }

        // 2. Seed Topological Relay DAG
        let dag = RelayDAGSpec(
            name: "Multi-Vendor Checkout & VAT Settlement Pipeline",
            repositoryPath: demoRepoDir,
            baseBranch: "main",
            tasks: [
                RelayTaskNode(
                    id: "stage-1-ledger",
                    title: "Idempotent Ledger & Rebate Discounts",
                    vendor: .claudeCode,
                    laneID: "lane-claude-core",
                    promptBrief: "Implement applyVolumeRebate and idempotency keys in BillingEngine.swift",
                    outputHandoffFiles: [".relay/ledger-schema.json"],
                    allowedWriteGlobs: ["Sources/Ledger/**"],
                    verificationShellCommand: "swift build --target Ledger",
                    maxBudgetUSD: 6.00,
                    status: .completed,
                    exitCode: 0,
                    handoffSummary: "Added applyVolumeRebate(cents:tierBps:) + InvoiceSettlement actor"
                ),
                RelayTaskNode(
                    id: "stage-1-tax",
                    title: "Multi-Region GST/VAT Calculation",
                    vendor: .codex,
                    laneID: "lane-codex-tax",
                    promptBrief: "Add computeRegionalVAT and CryptoKit audit digest in BillingEngine.swift",
                    outputHandoffFiles: [".relay/vat-matrix.json"],
                    allowedWriteGlobs: ["Sources/Ledger/**", "Sources/Tax/**"],
                    verificationShellCommand: "swift build --target Tax",
                    maxBudgetUSD: 5.00,
                    status: .completed,
                    exitCode: 0,
                    handoffSummary: "Added computeRegionalVAT(subtotal:countryCode:) + VATJurisdictionTable"
                ),
                RelayTaskNode(
                    id: "stage-2-gateway",
                    title: "HTTP Checkout Router & OpenAPI Spec",
                    vendor: .antigravity,
                    laneID: "lane-agy-docs",
                    dependsOnTaskIDs: ["stage-1-ledger", "stage-1-tax"],
                    promptBrief: "Wire CheckoutRouter to BillingEngine and document settlement flow",
                    inputHandoffFiles: [".relay/ledger-schema.json", ".relay/vat-matrix.json"],
                    outputHandoffFiles: ["docs/ARCHITECTURE.md"],
                    allowedWriteGlobs: ["Sources/Gateway/**", "docs/**"],
                    maxBudgetUSD: 4.00,
                    status: .running
                ),
                RelayTaskNode(
                    id: "stage-3-verify",
                    title: "Exhaustive Property & Fuzz Suite",
                    vendor: .mistralVibe,
                    laneID: "lane-vibe-tests",
                    dependsOnTaskIDs: ["stage-2-gateway"],
                    promptBrief: "Write 60 property tests verifying rounding invariants across currencies",
                    allowedWriteGlobs: ["Tests/**"],
                    verificationShellCommand: "swift test",
                    maxBudgetUSD: 3.00,
                    status: .blockedOnDeps
                )
            ],
            globalBudgetCeilingUSD: 18.00
        )
        try database.saveDAG(dag)

        // 3. Run real 3-Way Semantic AST Merges:
        //    File A (`Sources/Ledger/BillingEngine.swift`): Disjoint imports + disjoint struct methods -> 100% CLEAN AUTO-MERGE (rescues Git conflict!)
        let baseBilling = """
        import Foundation

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }
        }
        """
        let claudeBilling = """
        import Foundation
        import Dispatch

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }

            public func applyVolumeRebate(subtotalCents: Int, rebateBps: Int) -> Int {
                let discount = (subtotalCents * max(0, min(5000, rebateBps))) / 10_000
                return subtotalCents - discount
            }
        }
        """
        let codexBilling = """
        import Foundation
        import CryptoKit

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }

            public func computeRegionalVAT(netCents: Int, ratePermille: Int) -> Int {
                return (netCents * max(0, ratePermille) + 500) / 1_000
            }
        }
        """
        let cleanReport = semanticMerger.mergeFile(
            relativePath: "Sources/Ledger/BillingEngine.swift",
            baseSource: baseBilling,
            leftSource: claudeBilling,
            rightSource: codexBilling,
            leftLaneID: "lane-claude-core",
            rightLaneID: "lane-codex-tax",
            leftVendor: .claudeCode,
            rightVendor: .codex
        )
        try database.saveMergeReport(cleanReport)

        //    File B (`Sources/Gateway/FeeRoundingPolicy.swift`): Deliberate divergent edit on `roundHalfEven` for interactive 3-Pane Conflict Resolution!
        let baseRounding = """
        import Foundation

        public enum FeeRoundingPolicy {
            public static func settleMinorUnits(_ rawUnits: Double) -> Int {
                return Int(rawUnits.rounded())
            }
        }
        """
        let claudeRounding = """
        import Foundation

        public enum FeeRoundingPolicy {
            public static func settleMinorUnits(_ rawUnits: Double) -> Int {
                return Int(rawUnits.rounded(.toNearestOrEven))
            }
        }
        """
        let codexRounding = """
        import Foundation

        public enum FeeRoundingPolicy {
            public static func settleMinorUnits(_ rawUnits: Double) -> Int {
                return Int(Foundation.ceil(rawUnits - 1e-9))
            }
        }
        """
        let conflictReport = semanticMerger.mergeFile(
            relativePath: "Sources/Gateway/FeeRoundingPolicy.swift",
            baseSource: baseRounding,
            leftSource: claudeRounding,
            rightSource: codexRounding,
            leftLaneID: "lane-claude-core",
            rightLaneID: "lane-codex-tax",
            leftVendor: .claudeCode,
            rightVendor: .codex
        )
        try database.saveMergeReport(conflictReport)

        // 4. Run Built-In JavaScriptCore Guardrail Plugins
        let pluginOutputs = try pluginHost.evaluateEnabledPlugins(
            modifiedFilesByLane: [
                "lane-claude-core": ["Sources/Ledger/BillingEngine.swift": claudeBilling],
                "lane-codex-tax": ["Sources/Ledger/BillingEngine.swift": codexBilling],
                "lane-vibe-tests": ["Tests/LedgerTests/BillingPropertyTests.swift": "import Testing\n@Test func vatInvariant() {}"]
            ],
            budgetAccounts: []
        )
        let allFindings = pluginOutputs.flatMap(\.findings)
        try database.replaceGuardrailFindings(allFindings)
    }

    private static func sampleANSIOutput(for lane: ManagedWorktreeLane) -> String {
        switch lane.assignedVendor {
        case .claudeCode:
            return "\u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;31m● claude-code\u{1B}[0m worktree=\(lane.branchName)\r\n\u{1B}[32m✓\u{1B}[0m Read Sources/Ledger/BillingEngine.swift (28 lines)\r\n\u{1B}[32m✓\u{1B}[0m Wrote applyVolumeRebate(subtotalCents:rebateBps:)\r\n\u{1B}[36m→\u{1B}[0m swift build --target Ledger ... \u{1B}[1;32mBuild complete! (0.64s)\u{1B}[0m\r\n"
        case .codex:
            return "\u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;34m● codex exec\u{1B}[0m --cd .worktrees/\(lane.id)\r\n\u{1B}[32m✓\u{1B}[0m Synthesized VATJurisdictionTable (27 EU + APAC regions)\r\n\u{1B}[32m✓\u{1B}[0m Added computeRegionalVAT(netCents:ratePermille:)\r\n\u{1B}[36m→\u{1B}[0m Emitted handoff .relay/vat-matrix.json (0 ownership violations)\r\n"
        case .antigravity:
            return "\u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;32m● agy chat --mode agent\u{1B}[0m branch=\(lane.branchName)\r\n\u{1B}[32m✓\u{1B}[0m Loaded .relay/ledger-schema.json & .relay/vat-matrix.json\r\n\u{1B}[33m⚡\u{1B}[0m Wiring CheckoutRouter POST /v1/checkout/settle ...\r\n"
        case .mistralVibe:
            return "\u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;33m● vibe --workdir\u{1B}[0m \(lane.branchName)\r\n\u{1B}[90m⏸\u{1B}[0m Waiting on upstream stage 'stage-2-gateway' before running 60 property checks.\r\n"
        case .customShell:
            return "$ zsh -l\r\n"
        }
    }
}
