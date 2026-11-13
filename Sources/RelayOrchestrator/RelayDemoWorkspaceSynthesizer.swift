import Foundation
import RelayModels
import RelayPTYCore
import RelayPluginSDK
import RelaySemanticMerge
import RelayWiretapProxy
import RelayWorkspaceStore
import RelayWorktreeGit

// Alias matching both `IsometricModuleTower` and `IsometricModuleTile` naming conventions
public typealias IsometricModuleTile = IsometricModuleTower

// MARK: - Rich Wiretap Span Record, Boundary Collision & Synthesized Campaign Bundle

public struct WiretapSpanRecord: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let sequenceIndex: Int
    public let laneID: String
    public let taskID: String
    public let vendor: AgentVendor
    public let providerHost: String
    public let endpointPath: String
    public let modelIdentifier: String
    public let inputTokens: Int
    public let cachedReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let costUSD: Double
    public let ttftMs: Double
    public let durationMs: Double
    public let tokensPerSecond: Double
    public let cacheHitRatio: Double
    public let statusCode: Int
    public let blockedByCircuitBreaker: Bool
    public let isCircuitBreakerWarning: Bool
    public let toolCallsInvoked: [String]
    public let recordedAt: Date

    public init(
        id: UUID,
        sequenceIndex: Int,
        laneID: String,
        taskID: String,
        vendor: AgentVendor,
        providerHost: String,
        endpointPath: String,
        modelIdentifier: String,
        inputTokens: Int,
        cachedReadTokens: Int,
        cacheWriteTokens: Int = 0,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        costUSD: Double,
        ttftMs: Double,
        durationMs: Double,
        statusCode: Int = 200,
        blockedByCircuitBreaker: Bool = false,
        isCircuitBreakerWarning: Bool = false,
        toolCallsInvoked: [String] = [],
        recordedAt: Date
    ) {
        self.id = id
        self.sequenceIndex = sequenceIndex
        self.laneID = laneID
        self.taskID = taskID
        self.vendor = vendor
        self.providerHost = providerHost
        self.endpointPath = endpointPath
        self.modelIdentifier = modelIdentifier
        self.inputTokens = inputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
        self.ttftMs = ttftMs
        self.durationMs = durationMs
        let genMs = max(10.0, durationMs - ttftMs)
        self.tokensPerSecond = Double(outputTokens + reasoningTokens) / (genMs / 1_000.0)
        self.cacheHitRatio = inputTokens > 0 ? Double(cachedReadTokens) / Double(inputTokens) : 0.0
        self.statusCode = statusCode
        self.blockedByCircuitBreaker = blockedByCircuitBreaker
        self.isCircuitBreakerWarning = isCircuitBreakerWarning
        self.toolCallsInvoked = toolCallsInvoked
        self.recordedAt = recordedAt
    }

    public var apiSpan: WiretapAPISpan {
        WiretapAPISpan(
            id: id,
            laneID: laneID,
            taskID: taskID,
            vendor: vendor,
            providerHost: providerHost,
            modelIdentifier: modelIdentifier,
            inputTokens: inputTokens,
            cachedReadTokens: cachedReadTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            costUSD: costUSD,
            durationMs: durationMs,
            statusCode: statusCode,
            blockedByCircuitBreaker: blockedByCircuitBreaker,
            recordedAt: recordedAt
        )
    }
}

public struct TerritoryBoundaryCollisionWarning: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let rightfulOwnerLaneID: String
    public let rightfulOwnerVendor: AgentVendor
    public let intrudingLaneID: String
    public let intrudingVendor: AgentVendor
    public let ownershipEvent: OwnershipViolationEvent
    public let summary: String

    public init(
        id: UUID = UUID(),
        relativePath: String,
        rightfulOwnerLaneID: String,
        rightfulOwnerVendor: AgentVendor,
        intrudingLaneID: String,
        intrudingVendor: AgentVendor,
        ownershipEvent: OwnershipViolationEvent,
        summary: String
    ) {
        self.id = id
        self.relativePath = relativePath
        self.rightfulOwnerLaneID = rightfulOwnerLaneID
        self.rightfulOwnerVendor = rightfulOwnerVendor
        self.intrudingLaneID = intrudingLaneID
        self.intrudingVendor = intrudingVendor
        self.ownershipEvent = ownershipEvent
        self.summary = summary
    }
}

public struct SynthesizedMergeRevisionTriplet: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let baseSource: String
    public let leftSource: String
    public let rightSource: String
    public let report: ThreeWaySemanticMergeReport

    public init(
        relativePath: String,
        baseSource: String,
        leftSource: String,
        rightSource: String,
        report: ThreeWaySemanticMergeReport
    ) {
        self.relativePath = relativePath
        self.baseSource = baseSource
        self.leftSource = leftSource
        self.rightSource = rightSource
        self.report = report
    }
}

public struct SynthesizedFlagshipCampaign: Sendable, Codable, Hashable {
    public let campaignTitle: String
    public let repositoryPath: String
    public let baseCommitOID: String
    public let lanes: [ManagedWorktreeLane]
    public let gitCommits: [GitCommitNode]
    public let dagSpec: RelayDAGSpec
    public let cpmSchedule: CPMAnalysisReport
    public let ansiTranscriptsByLaneID: [String: String]
    public let terminalSnapshots: [TerminalViewportSnapshot]
    public let mergeScenarios: [SynthesizedMergeRevisionTriplet]
    public let mergeReports: [ThreeWaySemanticMergeReport]
    public let isometricTiles: [IsometricModuleTile]
    public let isometricCouplingArcs: [IsometricCouplingArc]
    public let boundaryCollisions: [TerritoryBoundaryCollisionWarning]
    public let wiretapSpanRecords: [WiretapSpanRecord]
    public let wiretapSpans: [WiretapAPISpan]
    public let laneBudgetAccounts: [LaneBudgetAccount]
    public let costAnalytics: WorkspaceCostAnalyticsSnapshot
    public let flamechartTimeline: WiretapFlamechartTimeline
    public let guardrailFindings: [RelayGuardrailFinding]
    public let hookTraceEntries: [RelayHookTraceEntry]
    public let policyPack: RelayGuardrailsPolicyPack

    public func terminalSnapshot(forLane laneID: String) -> TerminalViewportSnapshot? {
        terminalSnapshots.first { $0.laneID == laneID }
    }
}

// MARK: - Deterministic Multi-Vendor Flagship Campaign Synthesizer

public struct RelayDemoWorkspaceSynthesizer: Sendable {
    public static let flagshipCampaignName = "Zero-Copy HTTP/3 Transport & Auth Refactor"
    public static let anchorEpoch: TimeInterval = 1_763_020_800.0 // Fixed deterministic anchor timestamp

    public init() {}

    /// Deterministically synthesizes the complete 4-vendor "Zero-Copy HTTP/3 Transport & Auth Refactor" campaign.
    public func synthesizeFlagshipCampaign(
        repositoryPath: String = "/Users/shared/EdgeQuicGateway",
        terminalRows: Int = 26,
        terminalColumns: Int = 96
    ) -> SynthesizedFlagshipCampaign {
        let tBase = Date(timeIntervalSince1970: Self.anchorEpoch)
        let baseOID = "7e41a9c0f82b3104958672615049382716253400"

        // 1. 4 Isolated Multi-Vendor Worktree Lanes
        let lanes = Self.buildFourVendorLanes(repoRoot: repositoryPath, baseOID: baseOID, baseDate: tBase)
        let commits = Self.buildCommitGraph(baseOID: baseOID, baseDate: tBase)

        // 2. Colored ANSI/VT100 Terminal Buffers & Live Viewport Snapshots
        var ansiMap: [String: String] = [:]
        var snapshots: [TerminalViewportSnapshot] = []
        for lane in lanes {
            let ansi = Self.buildRealisticANSITerminalStream(for: lane)
            ansiMap[lane.id] = ansi
            let buf = VT100TerminalScreenBuffer(laneID: lane.id, rows: terminalRows, columns: terminalColumns)
            buf.feed(ansi)
            snapshots.append(buf.snapshot())
        }

        // 3. Topological DAG & Critical Path Method (CPM) Schedule
        let dag = Self.buildFlagshipDAG(repoRoot: repositoryPath, baseDate: tBase)
        let spanRecords = Self.build24WiretapSpanRecords(baseDate: tBase)
        let apiSpans = spanRecords.map(\.apiSpan)
        let cpm = (try? CriticalPathMethodAnalyzer().analyze(
            tasks: dag.tasks,
            durationOverridesSeconds: [
                "h3-quic-ring": 44.0,
                "h3-auth-subkeys": 49.0,
                "h3-passkey-verifier": 36.0,
                "h3-edge-router": 31.0,
                "h3-ast-reconcile": 14.0,
                "h3-fuzz-suite": 27.0
            ],
            observedWiretapSpans: apiSpans
        )) ?? CPMAnalysisReport(
            nodeSchedules: [],
            criticalPathTaskIDs: [],
            speedup: ParallelSpeedupMetrics(
                serialDurationSeconds: 201,
                parallelMakespanSeconds: 93,
                theoreticalSpeedupFactor: 2.16,
                observedLiveSpeedupFactor: 2.16,
                activeVendorLaneCount: 4,
                parallelEfficiencyRatio: 0.54,
                peakWaveConcurrency: 3,
                bottleneckTaskID: "h3-auth-subkeys"
            ),
            schedulesByLaneID: [:]
        )

        // 4. 3-Way Semantic AST Merge Scenarios (Clean Auto-Merge + True Intra-Function Conflict in AuthSessionManager)
        let mergeScenarios = Self.buildSemanticMergeScenarios()
        let mergeReports = mergeScenarios.map(\.report)

        // 5. 18 Isometric Module Tiles + Coupling Arcs + 1 Boundary Collision Warning
        let (tiles, arcs, collisions) = Self.build18IsometricArchitectureMap(baseDate: tBase)

        // 6. Lane Budget Accounts, Burn-Rate Forecasts & Flamechart Timeline
        let accounts = Self.buildBudgetAccounts(from: spanRecords)
        let costAnalytics = WiretapCostAnalyticsEngine().analyzeWorkspace(
            accounts: accounts,
            spans: apiSpans,
            globalCeilingUSD: dag.globalBudgetCeilingUSD
        )
        let flamechart = WiretapFlamechartBuilder.buildTimeline(from: apiSpans)

        // 7. Active Guardrail Plugin Audit Events & Hook Trace Ring-Buffer Entries
        let (findings, hookTraces) = Self.buildGuardrailFindingsAndHookTraces(baseDate: tBase)

        return SynthesizedFlagshipCampaign(
            campaignTitle: Self.flagshipCampaignName,
            repositoryPath: repositoryPath,
            baseCommitOID: baseOID,
            lanes: lanes,
            gitCommits: commits,
            dagSpec: dag,
            cpmSchedule: cpm,
            ansiTranscriptsByLaneID: ansiMap,
            terminalSnapshots: snapshots,
            mergeScenarios: mergeScenarios,
            mergeReports: mergeReports,
            isometricTiles: tiles,
            isometricCouplingArcs: arcs,
            boundaryCollisions: collisions,
            wiretapSpanRecords: spanRecords,
            wiretapSpans: apiSpans,
            laneBudgetAccounts: accounts,
            costAnalytics: costAnalytics,
            flamechartTimeline: flamechart,
            guardrailFindings: findings,
            hookTraceEntries: hookTraces,
            policyPack: RelayGuardrailsPolicyPack.defaultIndustrialPack()
        )
    }

    /// Hydrates a `.relayproj` `RelayProjectDatabase` (and optional `MultiVendorDAGOrchestrator`) with the full flagship campaign, FTS5 index, and initial checkpoint.
    @discardableResult
    public func populateWorkspaceDatabase(
        _ database: RelayProjectDatabase,
        orchestrator: MultiVendorDAGOrchestrator? = nil
    ) throws -> SynthesizedFlagshipCampaign {
        let repoPath = database.bundleDirectoryURL.appendingPathComponent("EdgeQuicGateway").path
        let campaign = synthesizeFlagshipCampaign(repositoryPath: repoPath)

        try database.setMeta(key: "workspace_name", value: campaign.campaignTitle)
        try database.setMeta(key: "repository_path", value: campaign.repositoryPath)
        try database.setMeta(key: "global_budget_ceiling_usd", value: String(format: "%.2f", campaign.dagSpec.globalBudgetCeilingUSD))

        for lane in campaign.lanes {
            try database.saveLane(lane)
            if let orch = orchestrator {
                let pty = orch.ptyGrid.getOrCreateSession(laneID: lane.id, rows: 26, columns: 96)
                if let ansi = campaign.ansiTranscriptsByLaneID[lane.id] {
                    pty.screenBuffer.feed(ansi)
                }
                orch.ownershipMonitor.registerLane(lane)
            }
        }

        try database.saveDAG(campaign.dagSpec)
        for report in campaign.mergeReports {
            try database.saveMergeReport(report)
        }
        for acc in campaign.laneBudgetAccounts {
            try database.setMeta(key: "budget_ceiling_\(acc.laneID)", value: String(format: "%.4f", acc.ceilingUSD))
            orchestrator?.wiretapProxy.ledger.registerLane(laneID: acc.laneID, vendor: acc.vendor, ceilingUSD: acc.ceilingUSD)
        }
        for span in campaign.wiretapSpans {
            try database.appendWiretapSpan(span)
        }
        try database.replaceGuardrailFindings(campaign.guardrailFindings)

        // Populate FTS5 BM25 search index across all 4 agent PTY transcripts, prompts, handoffs & merges
        let fts = database.makeFTS5SearchStore()
        for lane in campaign.lanes {
            if let ansi = campaign.ansiTranscriptsByLaneID[lane.id] {
                try fts.indexTerminalTranscript(
                    laneID: lane.id,
                    vendor: lane.assignedVendor,
                    rawTranscript: ansi,
                    windowTitle: lane.displayName,
                    recordedAt: lane.createdAt
                )
            }
        }
        _ = try fts.synchronizeFromPersistedWorkspace()

        // Create initial baseline checkpoint so Undo/Redo & Checkpoint Diff views have immediate history
        let journal = RelayCheckpointJournalManager(database: database)
        _ = try journal.createCheckpoint(
            label: "Wave 2 Handoff · Pre-Merge Snapshot",
            authorNote: "Captured automatically before 3-Way Semantic AST reconciliation of AuthSessionManager.swift"
        )

        return campaign
    }

    // MARK: - 1. Four Vendor Worktree Lanes & Git DAG

    private static func buildFourVendorLanes(repoRoot: String, baseOID: String, baseDate: Date) -> [ManagedWorktreeLane] {
        [
            ManagedWorktreeLane(
                id: "lane-claude-quic",
                displayName: "Claude Code · Zero-Copy QUIC & Passkeys",
                assignedVendor: .claudeCode,
                worktreePath: "\(repoRoot)/.worktrees/lane-claude-quic",
                branchName: "relay/claude-quic-passkey",
                baseCommitOID: baseOID,
                headCommitOID: "c19f84b201928374655647382910abcdef110001",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Sources/Transport/HTTP3ZeroCopyRing.swift", status: .modified, additions: 88, deletions: 14, observedAt: baseDate.addingTimeInterval(42)),
                    WorktreeFileDelta(relativePath: "Sources/Auth/AuthSessionManager.swift", status: .modified, additions: 74, deletions: 9, observedAt: baseDate.addingTimeInterval(68)),
                    WorktreeFileDelta(relativePath: "Sources/QUIC/VarIntFrameDecoder.swift", status: .added, additions: 132, deletions: 0, observedAt: baseDate.addingTimeInterval(35))
                ],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Sources/Transport/**", "Sources/QUIC/**", "Sources/Auth/**"],
                    forbiddenGlobs: [".git/**", "Tests/**"],
                    autoRevertViolations: false
                ),
                createdAt: baseDate
            ),
            ManagedWorktreeLane(
                id: "lane-codex-auth",
                displayName: "OpenAI Codex · HKDF Subkey Rotation",
                assignedVendor: .codex,
                worktreePath: "\(repoRoot)/.worktrees/lane-codex-auth",
                branchName: "relay/codex-hkdf-subkeys",
                baseCommitOID: baseOID,
                headCommitOID: "d28e73a190817263544536271809fedcba220002",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Sources/Auth/AuthSessionManager.swift", status: .modified, additions: 81, deletions: 11, observedAt: baseDate.addingTimeInterval(71)),
                    WorktreeFileDelta(relativePath: "Sources/Crypto/HKDFSubkeyRatchet.swift", status: .added, additions: 146, deletions: 0, observedAt: baseDate.addingTimeInterval(50)),
                    WorktreeFileDelta(relativePath: "Sources/Transport/HTTP3ZeroCopyRing.swift", status: .modified, additions: 49, deletions: 0, observedAt: baseDate.addingTimeInterval(62)),
                    WorktreeFileDelta(relativePath: "Sources/Transport/HTTP3ConnectionPool.swift", status: .modified, additions: 12, deletions: 3, observedAt: baseDate.addingTimeInterval(79))
                ],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Sources/Auth/**", "Sources/Crypto/**"],
                    forbiddenGlobs: [".git/**", "Sources/Gateway/**"],
                    autoRevertViolations: false
                ),
                createdAt: baseDate.addingTimeInterval(2)
            ),
            ManagedWorktreeLane(
                id: "lane-agy-gateway",
                displayName: "Google AGY · HTTP/3 Router & Spec",
                assignedVendor: .antigravity,
                worktreePath: "\(repoRoot)/.worktrees/lane-agy-gateway",
                branchName: "relay/agy-h3-gateway",
                baseCommitOID: baseOID,
                headCommitOID: "e37d62f089706152433425160798abcdef330003",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Sources/Gateway/HTTP3StreamMultiplexer.swift", status: .modified, additions: 96, deletions: 18, observedAt: baseDate.addingTimeInterval(95)),
                    WorktreeFileDelta(relativePath: "Sources/Gateway/HTTP3AuthMiddleware.swift", status: .modified, additions: 63, deletions: 7, observedAt: baseDate.addingTimeInterval(102)),
                    WorktreeFileDelta(relativePath: "docs/HTTP3-ZEROCOPY-RFC.md", status: .added, additions: 184, deletions: 0, observedAt: baseDate.addingTimeInterval(110))
                ],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Sources/Gateway/**", "Sources/Observability/**", "docs/**"],
                    forbiddenGlobs: [".git/**", "Sources/Crypto/**"],
                    autoRevertViolations: true
                ),
                createdAt: baseDate.addingTimeInterval(4)
            ),
            ManagedWorktreeLane(
                id: "lane-vibe-fuzz",
                displayName: "Mistral Vibe · QUIC & JWT Fuzz Suite",
                assignedVendor: .mistralVibe,
                worktreePath: "\(repoRoot)/.worktrees/lane-vibe-fuzz",
                branchName: "relay/vibe-quic-fuzz",
                baseCommitOID: baseOID,
                headCommitOID: "f46c51e978695041322314059687fedcba440004",
                dirtyFiles: [
                    WorktreeFileDelta(relativePath: "Tests/TransportTests/ZeroCopyRingPropertyTests.swift", status: .added, additions: 210, deletions: 0, observedAt: baseDate.addingTimeInterval(118)),
                    WorktreeFileDelta(relativePath: "Tests/AuthTests/PasskeyAndHKDFFuzzTests.swift", status: .added, additions: 178, deletions: 0, observedAt: baseDate.addingTimeInterval(126))
                ],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Tests/**", "fuzz/**"],
                    forbiddenGlobs: ["Sources/**", ".git/**"],
                    autoRevertViolations: true
                ),
                createdAt: baseDate.addingTimeInterval(6)
            )
        ]
    }

    private static func buildCommitGraph(baseOID: String, baseDate: Date) -> [GitCommitNode] {
        [
            GitCommitNode(
                oid: baseOID,
                parentOIDs: ["5b1092e4c7a18900112233445566778899aabbcc"],
                authorName: "Platform Release Bot",
                authorEmail: "release@edgequic.internal",
                authoredAt: baseDate.addingTimeInterval(-300),
                subject: "chore(main): baseline HTTP/2 transport & static bearer session manager",
                decorations: ["main", "tag: v2.4.0"]
            ),
            GitCommitNode(
                oid: "c19f84b201928374655647382910abcdef110001",
                parentOIDs: [baseOID],
                authorName: "Claude Code (Relay Lane)",
                authorEmail: "claude-lane@relayide.local",
                authoredAt: baseDate.addingTimeInterval(70),
                subject: "feat(quic,auth): zero-copy iovec ring slice & WebAuthn verifyPasskeyAssertion",
                decorations: ["HEAD -> relay/claude-quic-passkey"]
            ),
            GitCommitNode(
                oid: "d28e73a190817263544536271809fedcba220002",
                parentOIDs: [baseOID],
                authorName: "OpenAI Codex (Relay Lane)",
                authorEmail: "codex-lane@relayide.local",
                authoredAt: baseDate.addingTimeInterval(82),
                subject: "feat(crypto,auth): RFC 9001 HKDF subkey ratchet & epoch token validation",
                decorations: ["relay/codex-hkdf-subkeys"]
            ),
            GitCommitNode(
                oid: "e37d62f089706152433425160798abcdef330003",
                parentOIDs: ["c19f84b201928374655647382910abcdef110001"],
                authorName: "Google AGY (Relay Lane)",
                authorEmail: "agy-lane@relayide.local",
                authoredAt: baseDate.addingTimeInterval(112),
                subject: "feat(gateway): wire HTTP/3 QPACK header router & architecture RFC",
                decorations: ["relay/agy-h3-gateway"]
            ),
            GitCommitNode(
                oid: "f46c51e978695041322314059687fedcba440004",
                parentOIDs: ["e37d62f089706152433425160798abcdef330003"],
                authorName: "Mistral Vibe (Relay Lane)",
                authorEmail: "vibe-lane@relayide.local",
                authoredAt: baseDate.addingTimeInterval(130),
                subject: "test(fuzz): 128 stateful QUIC frame & passkey replay property checks",
                decorations: ["relay/vibe-quic-fuzz"]
            )
        ]
    }

    // MARK: - 2. Realistic Colored ANSI/VT100 Terminal Buffers (Diffs, cargo/swift test, Handoff Banners)

    private static func buildRealisticANSITerminalStream(for lane: ManagedWorktreeLane) -> String {
        switch lane.assignedVendor {
        case .claudeCode:
            return """
            \u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;38;2;217;78;52m━━━ RELAY LANE 01 · CLAUDE CODE (claude-sonnet-4-20250514) ━━━\u{1B}[0m\r
            \u{1B}[90mworktree:\u{1B}[0m .worktrees/lane-claude-quic  \u{1B}[90mscope:\u{1B}[0m Sources/{Transport,QUIC,Auth}/**\r
            \u{1B}[36m⏺\u{1B}[0m Inspecting \u{1B}[1mSources/Auth/AuthSessionManager.swift\u{1B}[0m & \u{1B}[1mHTTP3ZeroCopyRing.swift\u{1B}[0m\r
            \u{1B}[32m  + public func verifyPasskeyAssertion(credentialID: Data, authenticatorData: Data, ...)\u{1B}[0m\r
            \u{1B}[32m  + public mutating func acquireZeroCopyReadSlice(frameBytes: Int) -> UnsafeRawBufferPointer?\u{1B}[0m\r
            \u{1B}[31m  - guard claims.expiresAtEpoch > now else { return false }\u{1B}[0m\r
            \u{1B}[32m  + guard claims.expiresAtEpoch + 15 >= now && claims.userVerified else { throw AuthError.unverified }\u{1B}[0m\r
            \u{1B}[36m$\u{1B}[0m cargo test --manifest-path rust-quic-ffi/Cargo.toml -- --nocapture\r
            \u{1B}[32m   Compiling\u{1B}[0m quic-zerocopy-ffi v0.4.2 (.worktrees/lane-claude-quic/rust-quic-ffi)\r
            test ring::zero_copy_scatter_gather_64k ... \u{1B}[1;32mok\u{1B}[0m (0.04s)\r
            test frame::rfc9000_varint_bounds_check ... \u{1B}[1;32mok\u{1B}[0m (0.01s)\r
            \u{1B}[36m$\u{1B}[0m swift test --filter HTTP3ZeroCopyTests\r
            \u{1B}[1;32m✔ Test run with 18 tests passed after 0.412 seconds.\u{1B}[0m\r
            \u{1B}[48;2;24;139;93m\u{1B}[1;37m HANDOFF READY \u{1B}[0m Wrote \u{1B}[1m.relay/passkey-contract.json\u{1B}[0m (cache hit 79.4%, $1.84 spent)\r\n
            """

        case .codex:
            return """
            \u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;38;2;37;99;235m━━━ RELAY LANE 02 · OPENAI CODEX (gpt-5-codex) ━━━\u{1B}[0m\r
            \u{1B}[90mworktree:\u{1B}[0m .worktrees/lane-codex-auth   \u{1B}[90mscope:\u{1B}[0m Sources/{Auth,Crypto}/**\r
            \u{1B}[34m●\u{1B}[0m Synthesizing RFC 9001 TLS 1.3 Key Update ratchet in \u{1B}[1mHKDFSubkeyRatchet.swift\u{1B}[0m\r
            \u{1B}[32m  + public func rotateSessionSubkeys(masterPRK: SymmetricKey, nextEpoch: UInt64) -> SubkeyPair\u{1B}[0m\r
            \u{1B}[32m  + public func validateTokenClaims(_ claims: SessionClaims, epochRing: EpochKeyRing) throws -> Bool\u{1B}[0m\r
            \u{1B}[33m⚠ [GUARDRAIL BLOCKED]\u{1B}[0m Attempted `git reset --hard HEAD~1` → vetoed by \u{1B}[1mdestructive-shell-blocker\u{1B}[0m\r
            \u{1B}[33m⚠ [TERRITORY FENCE]\u{1B}[0m Cross-lane touch on \u{1B}[1mSources/Transport/HTTP3ConnectionPool.swift\u{1B}[0m flagged\r
            \u{1B}[36m$\u{1B}[0m swift test --filter HKDFSubkeyRatchetTests\r
            \u{1B}[1;32m✔ Suite 'HKDFSubkeyRatchetTests' passed (24/24 assertions, 0.289s).\u{1B}[0m\r
            \u{1B}[48;2;217;119;6m\u{1B}[1;30m CIRCUIT WARNING \u{1B}[0m Spend $5.92 / $6.50 cap (91%) · Emitted \u{1B}[1m.relay/hkdf-epochs.json\u{1B}[0m\r\n
            """

        case .antigravity:
            return """
            \u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;38;2;21;128;61m━━━ RELAY LANE 03 · GOOGLE AGY (gemini-2.5-pro) ━━━\u{1B}[0m\r
            \u{1B}[90mworktree:\u{1B}[0m .worktrees/lane-agy-gateway  \u{1B}[90mscope:\u{1B}[0m Sources/Gateway/**, docs/**\r
            \u{1B}[32m✓\u{1B}[0m Ingested upstream handoffs: \u{1B}[1m.relay/passkey-contract.json\u{1B}[0m + \u{1B}[1m.relay/hkdf-epochs.json\u{1B}[0m\r
            \u{1B}[36m→\u{1B}[0m Patching \u{1B}[1mSources/Gateway/HTTP3StreamMultiplexer.swift\u{1B}[0m (0-RTT QPACK stream priority)\r
            \u{1B}[32m  + public func routeDatagramStream(streamID: UInt64, headers: QPACKHeaderBlock) async throws\u{1B}[0m\r
            \u{1B}[36m$\u{1B}[0m swift build --target HTTP3Gateway -Xswiftc -warnings-as-errors\r
            \u{1B}[32m[14/14] Compiling HTTP3Gateway HTTP3AuthMiddleware.swift\u{1B}[0m\r
            \u{1B}[1;32mBuild complete! (0.83s, 0 warnings)\u{1B}[0m\r
            \u{1B}[48;2;21;128;61m\u{1B}[1;37m DOCS SYNCED \u{1B}[0m Generated \u{1B}[1mdocs/HTTP3-ZEROCOPY-RFC.md\u{1B}[0m & sequence diagrams\r\n
            """

        case .mistralVibe:
            return """
            \u{1B}]0;\(lane.displayName)\u{07}\u{1B}[1;38;2;217;119;6m━━━ RELAY LANE 04 · MISTRAL VIBE (devstral-medium) ━━━\u{1B}[0m\r
            \u{1B}[90mworktree:\u{1B}[0m .worktrees/lane-vibe-fuzz    \u{1B}[90mscope:\u{1B}[0m Tests/**, fuzz/**\r
            \u{1B}[33m⚡\u{1B}[0m Synthesized 128 property & differential fuzz cases across QUIC varints + JWT epochs\r
            \u{1B}[36m$\u{1B}[0m cargo test --release h3_prop_frame_coalescing\r
            running 64 tests ... \u{1B}[1;32mtest result: ok. 64 passed; 0 failed; finished in 0.62s\u{1B}[0m\r
            \u{1B}[36m$\u{1B}[0m swift test --parallel --filter PasskeyAndHKDFFuzzTests\r
            \u{1B}[32m✔ 64 property invariants verified (10,000 randomized inputs, 0 counterexamples).\u{1B}[0m\r
            \u{1B}[48;2;37;99;235m\u{1B}[1;37m VERIFIER GATE \u{1B}[0m Ready to run post-merge suite once \u{1B}[1mAuthSessionManager\u{1B}[0m conflict resolves\r\n
            """

        case .customShell:
            return "$ zsh -l\r\n"
        }
    }

    // MARK: - 3. Topological Multi-Vendor Campaign DAG

    private static func buildFlagshipDAG(repoRoot: String, baseDate: Date) -> RelayDAGSpec {
        RelayDAGSpec(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555501")!,
            name: flagshipCampaignName,
            repositoryPath: repoRoot,
            baseBranch: "main",
            tasks: [
                RelayTaskNode(
                    id: "h3-quic-ring",
                    title: "Zero-Copy QUIC IOVector Ring & VarInt Codec",
                    vendor: .claudeCode,
                    laneID: "lane-claude-quic",
                    promptBrief: "Implement lock-free zero-copy HTTP3ZeroCopyRing and RFC 9000 variable-length integer frame decoder.",
                    outputHandoffFiles: [".relay/zerocopy-ring-abi.json"],
                    allowedWriteGlobs: ["Sources/Transport/**", "Sources/QUIC/**"],
                    verificationShellCommand: "swift test --filter HTTP3ZeroCopyTests",
                    maxBudgetUSD: 6.00,
                    status: .completed,
                    startedAt: baseDate,
                    finishedAt: baseDate.addingTimeInterval(44),
                    exitCode: 0,
                    handoffSummary: "Delivered acquireZeroCopyReadSlice(frameBytes:) with 0 heap copies per 64KB datagram."
                ),
                RelayTaskNode(
                    id: "h3-passkey-verifier",
                    title: "WebAuthn P-256 Passkey Assertion Verifier",
                    vendor: .claudeCode,
                    laneID: "lane-claude-quic",
                    dependsOnTaskIDs: ["h3-quic-ring"],
                    promptBrief: "Add verifyPasskeyAssertion(...) and strict clock-leeway audience checks in AuthSessionManager.swift.",
                    inputHandoffFiles: [".relay/zerocopy-ring-abi.json"],
                    outputHandoffFiles: [".relay/passkey-contract.json"],
                    allowedWriteGlobs: ["Sources/Auth/**"],
                    verificationShellCommand: "swift build --target Auth",
                    maxBudgetUSD: 5.00,
                    status: .completed,
                    startedAt: baseDate.addingTimeInterval(45),
                    finishedAt: baseDate.addingTimeInterval(81),
                    exitCode: 0,
                    handoffSummary: "Added verifyPasskeyAssertion(...) using CryptoKit P256.Signing + userVerified gate."
                ),
                RelayTaskNode(
                    id: "h3-auth-subkeys",
                    title: "RFC 9001 HKDF Session Subkey Ratchet",
                    vendor: .codex,
                    laneID: "lane-codex-auth",
                    promptBrief: "Implement rotateSessionSubkeys(...) and HKDF epoch ring validation in AuthSessionManager.swift.",
                    outputHandoffFiles: [".relay/hkdf-epochs.json"],
                    allowedWriteGlobs: ["Sources/Auth/**", "Sources/Crypto/**"],
                    verificationShellCommand: "swift test --filter HKDFSubkeyRatchetTests",
                    maxBudgetUSD: 6.50,
                    status: .completed,
                    startedAt: baseDate.addingTimeInterval(2),
                    finishedAt: baseDate.addingTimeInterval(51),
                    exitCode: 0,
                    handoffSummary: "Implemented stateless HKDF-Expand-Label subkey rotation + replay bloom filter."
                ),
                RelayTaskNode(
                    id: "h3-edge-router",
                    title: "HTTP/3 QPACK Stream Multiplexer & RFC Spec",
                    vendor: .antigravity,
                    laneID: "lane-agy-gateway",
                    dependsOnTaskIDs: ["h3-quic-ring", "h3-auth-subkeys"],
                    promptBrief: "Integrate zero-copy QUIC ring + HKDF subkeys into HTTP3StreamMultiplexer and author docs/HTTP3-ZEROCOPY-RFC.md.",
                    inputHandoffFiles: [".relay/zerocopy-ring-abi.json", ".relay/hkdf-epochs.json"],
                    outputHandoffFiles: ["docs/HTTP3-ZEROCOPY-RFC.md"],
                    allowedWriteGlobs: ["Sources/Gateway/**", "docs/**"],
                    verificationShellCommand: "swift build --target HTTP3Gateway",
                    maxBudgetUSD: 4.50,
                    status: .completed,
                    startedAt: baseDate.addingTimeInterval(52),
                    finishedAt: baseDate.addingTimeInterval(83),
                    exitCode: 0,
                    handoffSummary: "Wired 0-RTT stream prioritization and authored complete HTTP/3 architecture RFC."
                ),
                RelayTaskNode(
                    id: "h3-ast-reconcile",
                    title: "3-Way Semantic AST Reconcile (AuthSessionManager)",
                    vendor: .antigravity,
                    laneID: "lane-agy-gateway",
                    dependsOnTaskIDs: ["h3-passkey-verifier", "h3-edge-router"],
                    promptBrief: "Reconcile disjoint passkey/subkey methods and resolve intra-function validateTokenClaims conflict.",
                    inputHandoffFiles: [".relay/passkey-contract.json", ".relay/hkdf-epochs.json"],
                    outputHandoffFiles: [".relay/merged-auth-manifest.json"],
                    allowedWriteGlobs: ["Sources/Auth/**", "Sources/Gateway/**"],
                    maxBudgetUSD: 3.50,
                    status: .running,
                    startedAt: baseDate.addingTimeInterval(84)
                ),
                RelayTaskNode(
                    id: "h3-fuzz-suite",
                    title: "128-Case QUIC Frame & Token Replay Fuzz Gate",
                    vendor: .mistralVibe,
                    laneID: "lane-vibe-fuzz",
                    dependsOnTaskIDs: ["h3-ast-reconcile"],
                    promptBrief: "Execute property & differential fuzz tests across merged HTTP3ZeroCopyRing and AuthSessionManager.",
                    inputHandoffFiles: [".relay/merged-auth-manifest.json"],
                    allowedWriteGlobs: ["Tests/**", "fuzz/**"],
                    verificationShellCommand: "swift test --parallel",
                    maxBudgetUSD: 3.00,
                    status: .blockedOnDeps
                )
            ],
            globalBudgetCeilingUSD: 25.00,
            createdAt: baseDate
        )
    }

    // MARK: - 4. Semantic AST Merge Scenarios (Both Clean Auto-Merge AND True Intra-Function Conflict)

    private static func buildSemanticMergeScenarios() -> [SynthesizedMergeRevisionTriplet] {
        let merger = ThreeWaySemanticASTMerger()

        // Scenario A (`Sources/Auth/AuthSessionManager.swift`):
        // - Claude Code adds `import AuthenticationServices` + `verifyPasskeyAssertion(...)`
        // - OpenAI Codex adds `import OSLog` + `rotateSessionSubkeys(...)`
        // - BOTH modify `validateTokenClaims(...)` inside `struct AuthSessionManager`!
        // Granular member-level AST chunks expose BOTH Clean Semantic Auto-Merge (imports + 2 new methods)
        // AND the True Intra-Function Conflict (`validateTokenClaims`) side by side in the UI!
        let baseAuth = """
        import CryptoKit
        import Foundation

        public struct AuthSessionManager: Sendable {
            public let issuerURI: String
            public let activeKeyEpoch: UInt64

            public init(issuerURI: String, activeKeyEpoch: UInt64 = 1) {
                self.issuerURI = issuerURI
                self.activeKeyEpoch = activeKeyEpoch
            }

            public func validateTokenClaims(
                tokenPayload: Data,
                nowEpochSeconds: Int64
            ) throws -> Bool {
                guard !tokenPayload.isEmpty else { return false }
                let decoded = try JSONDecoder().decode(SessionTokenClaims.self, from: tokenPayload)
                return decoded.issuer == issuerURI && decoded.expiresAt > nowEpochSeconds
            }
        }
        """

        let claudeAuth = """
        import AuthenticationServices
        import CryptoKit
        import Foundation

        public struct AuthSessionManager: Sendable {
            public let issuerURI: String
            public let activeKeyEpoch: UInt64

            public init(issuerURI: String, activeKeyEpoch: UInt64 = 1) {
                self.issuerURI = issuerURI
                self.activeKeyEpoch = activeKeyEpoch
            }

            public func verifyPasskeyAssertion(
                credentialID: Data,
                authenticatorData: Data,
                clientDataHash: Data,
                derSignature: Data,
                publicKeyPEM: String
            ) throws -> Bool {
                let pubKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
                let sig = try P256.Signing.ECDSASignature(derRepresentation: derSignature)
                var signedBytes = Data(authenticatorData)
                signedBytes.append(clientDataHash)
                guard pubKey.isValidSignature(sig, for: signedBytes), !credentialID.isEmpty else {
                    return false
                }
                return (authenticatorData.count >= 33) && ((authenticatorData[32] & 0x05) == 0x05)
            }

            public func validateTokenClaims(
                tokenPayload: Data,
                nowEpochSeconds: Int64
            ) throws -> Bool {
                let decoded = try JSONDecoder().decode(SessionTokenClaims.self, from: tokenPayload)
                let clockSkewLeewaySec: Int64 = 15
                guard decoded.issuer == issuerURI,
                      decoded.userVerifiedPasskey == true,
                      decoded.expiresAt + clockSkewLeewaySec >= nowEpochSeconds else {
                    return false
                }
                return true
            }
        }
        """

        let codexAuth = """
        import CryptoKit
        import Foundation
        import OSLog

        public struct AuthSessionManager: Sendable {
            public let issuerURI: String
            public let activeKeyEpoch: UInt64

            public init(issuerURI: String, activeKeyEpoch: UInt64 = 1) {
                self.issuerURI = issuerURI
                self.activeKeyEpoch = activeKeyEpoch
            }

            public func rotateSessionSubkeys(
                masterPRK: SymmetricKey,
                nextEpoch: UInt64,
                connectionIDBytes: Data
            ) -> (clientTrafficKey: SymmetricKey, serverTrafficKey: SymmetricKey) {
                var info = Data("h3-zc-epoch-\\(nextEpoch)".utf8)
                info.append(connectionIDBytes)
                let clientKey = HKDF<SHA256>.expand(pseudoRandomKey: masterPRK, info: info + Data([0x01]), outputByteCount: 32)
                let serverKey = HKDF<SHA256>.expand(pseudoRandomKey: masterPRK, info: info + Data([0x02]), outputByteCount: 32)
                return (clientKey, serverKey)
            }

            public func validateTokenClaims(
                tokenPayload: Data,
                nowEpochSeconds: Int64,
                minAcceptedKeyEpoch: UInt64
            ) throws -> Bool {
                let decoded = try JSONDecoder().decode(SessionTokenClaims.self, from: tokenPayload)
                guard decoded.issuer == issuerURI,
                      decoded.keyEpoch >= max(activeKeyEpoch - 1, minAcceptedKeyEpoch),
                      decoded.expiresAt > nowEpochSeconds else {
                    return false
                }
                return !decoded.jtiNonce.isEmpty
            }
        }
        """

        let claudeValidateMember = """
            public func validateTokenClaims(
                tokenPayload: Data,
                nowEpochSeconds: Int64
            ) throws -> Bool {
                let decoded = try JSONDecoder().decode(SessionTokenClaims.self, from: tokenPayload)
                let clockSkewLeewaySec: Int64 = 15
                guard decoded.issuer == issuerURI,
                      decoded.userVerifiedPasskey == true,
                      decoded.expiresAt + clockSkewLeewaySec >= nowEpochSeconds else {
                    return false
                }
                return true
            }
        """

        let codexValidateMember = """
            public func validateTokenClaims(
                tokenPayload: Data,
                nowEpochSeconds: Int64,
                minAcceptedKeyEpoch: UInt64
            ) throws -> Bool {
                let decoded = try JSONDecoder().decode(SessionTokenClaims.self, from: tokenPayload)
                guard decoded.issuer == issuerURI,
                      decoded.keyEpoch >= max(activeKeyEpoch - 1, minAcceptedKeyEpoch),
                      decoded.expiresAt > nowEpochSeconds else {
                    return false
                }
                return !decoded.jtiNonce.isEmpty
            }
        """

        let baseValidateMember = """
            public func validateTokenClaims(
                tokenPayload: Data,
                nowEpochSeconds: Int64
            ) throws -> Bool {
                guard !tokenPayload.isEmpty else { return false }
                let decoded = try JSONDecoder().decode(SessionTokenClaims.self, from: tokenPayload)
                return decoded.issuer == issuerURI && decoded.expiresAt > nowEpochSeconds
            }
        """

        let verifyPasskeyMember = """
            public func verifyPasskeyAssertion(
                credentialID: Data,
                authenticatorData: Data,
                clientDataHash: Data,
                derSignature: Data,
                publicKeyPEM: String
            ) throws -> Bool {
                let pubKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
                let sig = try P256.Signing.ECDSASignature(derRepresentation: derSignature)
                var signedBytes = Data(authenticatorData)
                signedBytes.append(clientDataHash)
                guard pubKey.isValidSignature(sig, for: signedBytes), !credentialID.isEmpty else {
                    return false
                }
                return (authenticatorData.count >= 33) && ((authenticatorData[32] & 0x05) == 0x05)
            }
        """

        let rotateSubkeysMember = """
            public func rotateSessionSubkeys(
                masterPRK: SymmetricKey,
                nextEpoch: UInt64,
                connectionIDBytes: Data
            ) -> (clientTrafficKey: SymmetricKey, serverTrafficKey: SymmetricKey) {
                var info = Data("h3-zc-epoch-\\(nextEpoch)".utf8)
                info.append(connectionIDBytes)
                let clientKey = HKDF<SHA256>.expand(pseudoRandomKey: masterPRK, info: info + Data([0x01]), outputByteCount: 32)
                let serverKey = HKDF<SHA256>.expand(pseudoRandomKey: masterPRK, info: info + Data([0x02]), outputByteCount: 32)
                return (clientKey, serverKey)
            }
        """

        let conflictMarkerValidate = """
        <<<<<<< lane-claude-quic (Claude Code)
        \(claudeValidateMember)
        =======
        \(codexValidateMember)
        >>>>>>> lane-codex-auth (OpenAI Codex)
        """

        let authChunks: [SemanticMergeChunk] = [
            SemanticMergeChunk(
                id: UUID(uuidString: "aaaa0001-0000-4000-8000-000000000001")!,
                qualifiedKey: "ImportBlock:__imports__",
                symbolName: "__imports__",
                kind: .importGroup,
                resolution: .autoMergedImportSetUnion,
                baseSource: "import CryptoKit\nimport Foundation",
                leftSource: "import AuthenticationServices\nimport CryptoKit\nimport Foundation",
                rightSource: "import CryptoKit\nimport Foundation\nimport OSLog",
                resolvedSource: "import AuthenticationServices\nimport CryptoKit\nimport Foundation\nimport OSLog",
                leftVendor: .claudeCode,
                rightVendor: .codex,
                explanation: "Auto-merged disjoint imports (AuthenticationServices from Claude Code + OSLog from OpenAI Codex)."
            ),
            SemanticMergeChunk(
                id: UUID(uuidString: "aaaa0001-0000-4000-8000-000000000002")!,
                qualifiedKey: "Struct:AuthSessionManager.init",
                symbolName: "AuthSessionManager (stored properties & init)",
                kind: .structDecl,
                resolution: .unchanged,
                baseSource: "public struct AuthSessionManager: Sendable {\n    public let issuerURI: String\n    public let activeKeyEpoch: UInt64",
                leftSource: "public struct AuthSessionManager: Sendable {\n    public let issuerURI: String\n    public let activeKeyEpoch: UInt64",
                rightSource: "public struct AuthSessionManager: Sendable {\n    public let issuerURI: String\n    public let activeKeyEpoch: UInt64",
                resolvedSource: "public struct AuthSessionManager: Sendable {\n    public let issuerURI: String\n    public let activeKeyEpoch: UInt64\n\n    public init(issuerURI: String, activeKeyEpoch: UInt64 = 1) {\n        self.issuerURI = issuerURI\n        self.activeKeyEpoch = activeKeyEpoch\n    }",
                leftVendor: .claudeCode,
                rightVendor: .codex,
                explanation: "Struct header and initializer preserved without drift across both lanes."
            ),
            SemanticMergeChunk(
                id: UUID(uuidString: "aaaa0001-0000-4000-8000-000000000003")!,
                qualifiedKey: "Method:AuthSessionManager.verifyPasskeyAssertion",
                symbolName: "verifyPasskeyAssertion",
                kind: .methodDecl,
                resolution: .leftAddedDeclaration,
                baseSource: nil,
                leftSource: verifyPasskeyMember,
                rightSource: nil,
                resolvedSource: verifyPasskeyMember,
                leftVendor: .claudeCode,
                rightVendor: .codex,
                explanation: "Clean Semantic Auto-Merge: Added new method 'verifyPasskeyAssertion' from Claude Code."
            ),
            SemanticMergeChunk(
                id: UUID(uuidString: "aaaa0001-0000-4000-8000-000000000004")!,
                qualifiedKey: "Method:AuthSessionManager.rotateSessionSubkeys",
                symbolName: "rotateSessionSubkeys",
                kind: .methodDecl,
                resolution: .rightAddedDeclaration,
                baseSource: nil,
                leftSource: nil,
                rightSource: rotateSubkeysMember,
                resolvedSource: rotateSubkeysMember,
                leftVendor: .claudeCode,
                rightVendor: .codex,
                explanation: "Clean Semantic Auto-Merge: Added new method 'rotateSessionSubkeys' from OpenAI Codex."
            ),
            SemanticMergeChunk(
                id: UUID(uuidString: "aaaa0001-0000-4000-8000-000000000005")!,
                qualifiedKey: "Method:AuthSessionManager.validateTokenClaims",
                symbolName: "validateTokenClaims",
                kind: .methodDecl,
                resolution: .conflictBothModifiedSameSymbol,
                baseSource: baseValidateMember,
                leftSource: claudeValidateMember,
                rightSource: codexValidateMember,
                resolvedSource: conflictMarkerValidate + "\n}",
                leftVendor: .claudeCode,
                rightVendor: .codex,
                explanation: "True Intra-Function Conflict: Claude Code added 15s passkey UV leeway while Codex added HKDF minAcceptedKeyEpoch parameter & JTI check."
            )
        ]

        let authCrossCollision = CrossFileSignatureCollision(
            id: UUID(uuidString: "aaaa0001-0000-4000-8000-000000000099")!,
            symbolName: "validateTokenClaims",
            declarationFile: "Sources/Auth/AuthSessionManager.swift",
            oldSignature: "(tokenPayload: Data, nowEpochSeconds: Int64)",
            newSignature: "(tokenPayload: Data, nowEpochSeconds: Int64, minAcceptedKeyEpoch: UInt64)",
            modifiedByLane: "lane-codex-auth",
            callerFile: "Sources/Gateway/HTTP3AuthMiddleware.swift",
            callerLine: 48,
            callerLane: "lane-agy-gateway",
            diagnosticMessage: "'validateTokenClaims' gained required parameter 'minAcceptedKeyEpoch' in lane-codex-auth, impacting call-site in HTTP3AuthMiddleware.swift:48 (lane-agy-gateway)."
        )

        let authMergedText = authChunks.map(\.resolvedSource).joined(separator: "\n\n") + "\n"
        let authReport = ThreeWaySemanticMergeReport(
            relativePath: "Sources/Auth/AuthSessionManager.swift",
            language: .swift,
            leftLaneID: "lane-claude-quic",
            rightLaneID: "lane-codex-auth",
            chunks: authChunks,
            mergedText: authMergedText,
            autoMergedCount: 3,
            unresolvedConflictCount: 1,
            wouldGitLineMergeConflict: true,
            crossFileCollisions: [authCrossCollision]
        )

        // Scenario B (`Sources/Transport/HTTP3ZeroCopyRing.swift`):
        // 100% Clean Nested-Member Semantic AST Auto-Merge rescuing a classic Git line-level conflict!
        let baseRing = """
        import Foundation

        public struct HTTP3ZeroCopyRing: Sendable {
            public let slotCapacity: Int

            public init(slotCapacity: Int = 256) {
                self.slotCapacity = slotCapacity
            }
        }
        """

        let claudeRing = """
        import Darwin
        import Foundation

        public struct HTTP3ZeroCopyRing: Sendable {
            public let slotCapacity: Int

            public init(slotCapacity: Int = 256) {
                self.slotCapacity = slotCapacity
            }

            public func acquireZeroCopyReadSlice(slotIndex: Int, byteLength: Int) -> Range<Int> {
                let clamped = max(0, min(slotCapacity - 1, slotIndex))
                let offset = clamped * 65_536
                return offset..<(offset + max(0, min(65_536, byteLength)))
            }
        }
        """

        let codexRing = """
        import CryptoKit
        import Foundation

        public struct HTTP3ZeroCopyRing: Sendable {
            public let slotCapacity: Int

            public init(slotCapacity: Int = 256) {
                self.slotCapacity = slotCapacity
            }

            public func computeSlotIntegrityTag(slotPayload: Data, trafficKey: SymmetricKey) -> Data {
                let mac = HMAC<SHA256>.authenticationCode(for: slotPayload, using: trafficKey)
                return Data(mac.prefix(16))
            }
        }
        """

        let cleanRingReport = merger.mergeFile(
            relativePath: "Sources/Transport/HTTP3ZeroCopyRing.swift",
            baseSource: baseRing,
            leftSource: claudeRing,
            rightSource: codexRing,
            leftLaneID: "lane-claude-quic",
            rightLaneID: "lane-codex-auth",
            leftVendor: .claudeCode,
            rightVendor: .codex
        )

        return [
            SynthesizedMergeRevisionTriplet(
                relativePath: "Sources/Auth/AuthSessionManager.swift",
                baseSource: baseAuth,
                leftSource: claudeAuth,
                rightSource: codexAuth,
                report: authReport
            ),
            SynthesizedMergeRevisionTriplet(
                relativePath: "Sources/Transport/HTTP3ZeroCopyRing.swift",
                baseSource: baseRing,
                leftSource: claudeRing,
                rightSource: codexRing,
                report: cleanRingReport
            )
        ]
    }

    // MARK: - 5. 18 Isometric Architecture Blocks, Coupling Arcs & 1 Boundary Collision Warning

    private static func build18IsometricArchitectureMap(
        baseDate: Date
    ) -> ([IsometricModuleTile], [IsometricCouplingArc], [TerritoryBoundaryCollisionWarning]) {
        // 18 modules on a 6x3 isometric studio grid with authentic fan-in/fan-out (Martin Instability I = fanOut / (fanIn + fanOut))
        let specs: [(path: String, mod: String, lang: SourceLanguage, loc: Int, decls: Int, fanIn: Int, fanOut: Int, vendor: AgentVendor?, lane: String?, conflict: Bool, col: Int, row: Int)] = [
            // Row 0: Core QUIC & Zero-Copy Transport (Claude Code territory)
            ("Sources/QUIC/QUICPacketHeader.swift", "QUIC", .swift, 312, 9, 11, 1, .claudeCode, "lane-claude-quic", false, 0, 0),
            ("Sources/QUIC/VarIntFrameDecoder.swift", "QUIC", .swift, 284, 7, 9, 2, .claudeCode, "lane-claude-quic", false, 1, 0),
            ("Sources/QUIC/LossRecoveryCongestion.rs", "QUIC-FFI", .rust, 490, 14, 6, 2, .claudeCode, "lane-claude-quic", false, 2, 0),
            ("Sources/Transport/HTTP3ZeroCopyRing.swift", "Transport", .swift, 418, 11, 10, 3, .claudeCode, "lane-claude-quic", false, 3, 0),
            ("Sources/Transport/HTTP3ConnectionPool.swift", "Transport", .swift, 356, 8, 7, 4, .claudeCode, "lane-claude-quic", false, 4, 0),
            ("Sources/Transport/QPACKStaticTable.swift", "Transport", .swift, 265, 6, 8, 1, .claudeCode, "lane-claude-quic", false, 5, 0),

            // Row 1: Auth, Passkeys & HKDF Crypto (Claude Code + OpenAI Codex shared/fenced boundary)
            ("Sources/Auth/AuthSessionManager.swift", "Auth", .swift, 462, 12, 9, 5, .claudeCode, "lane-claude-quic", true, 0, 1),
            ("Sources/Auth/PasskeyCOSEKeyParser.swift", "Auth", .swift, 298, 8, 4, 3, .claudeCode, "lane-claude-quic", false, 1, 1),
            ("Sources/Auth/SessionTokenClaims.swift", "Auth", .swift, 184, 5, 12, 1, .codex, "lane-codex-auth", false, 2, 1),
            ("Sources/Crypto/HKDFSubkeyRatchet.swift", "Crypto", .swift, 376, 10, 7, 2, .codex, "lane-codex-auth", false, 3, 1),
            ("Sources/Crypto/ReplayNonceBloomFilter.swift", "Crypto", .swift, 240, 6, 5, 1, .codex, "lane-codex-auth", false, 4, 1),
            ("Sources/Crypto/AEADChaChaPolySealer.swift", "Crypto", .swift, 310, 7, 6, 2, .codex, "lane-codex-auth", false, 5, 1),

            // Row 2: HTTP/3 Edge Gateway, Docs & Fuzz Verification (Google AGY + Mistral Vibe territories)
            ("Sources/Gateway/HTTP3StreamMultiplexer.swift", "Gateway", .swift, 445, 13, 3, 8, .antigravity, "lane-agy-gateway", false, 0, 2),
            ("Sources/Gateway/HTTP3AuthMiddleware.swift", "Gateway", .swift, 278, 7, 2, 6, .antigravity, "lane-agy-gateway", false, 1, 2),
            ("Sources/Observability/OTelQuicTraceExporter.swift", "Observability", .swift, 226, 6, 4, 5, .antigravity, "lane-agy-gateway", false, 2, 2),
            ("docs/HTTP3-ZEROCOPY-RFC.md", "Docs", .markdown, 320, 9, 0, 4, .antigravity, "lane-agy-gateway", false, 3, 2),
            ("Tests/TransportTests/ZeroCopyRingPropertyTests.swift", "Tests", .swift, 410, 16, 0, 7, .mistralVibe, "lane-vibe-fuzz", false, 4, 2),
            ("Tests/AuthTests/PasskeyAndHKDFFuzzTests.swift", "Tests", .swift, 388, 15, 0, 8, .mistralVibe, "lane-vibe-fuzz", false, 5, 2)
        ]

        let tiles = specs.map { item in
            IsometricModuleTile(
                relativePath: item.path,
                moduleName: item.mod,
                language: item.lang,
                lineCount: item.loc,
                declarationCount: item.decls,
                fanIn: item.fanIn,
                fanOut: item.fanOut,
                activeOwnerVendor: item.vendor,
                activeLaneID: item.lane,
                hasMergeConflict: item.conflict,
                gridColumn: item.col,
                gridRow: item.row
            )
        }

        let arcs: [IsometricCouplingArc] = [
            IsometricCouplingArc(sourcePath: "Sources/Transport/HTTP3ZeroCopyRing.swift", targetPath: "Sources/QUIC/VarIntFrameDecoder.swift", sharedSymbolCount: 6, crossesAgentLanes: false),
            IsometricCouplingArc(sourcePath: "Sources/Transport/HTTP3ConnectionPool.swift", targetPath: "Sources/Transport/HTTP3ZeroCopyRing.swift", sharedSymbolCount: 8, crossesAgentLanes: false),
            IsometricCouplingArc(sourcePath: "Sources/Transport/HTTP3ConnectionPool.swift", targetPath: "Sources/Crypto/HKDFSubkeyRatchet.swift", sharedSymbolCount: 4, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Auth/AuthSessionManager.swift", targetPath: "Sources/Auth/PasskeyCOSEKeyParser.swift", sharedSymbolCount: 5, crossesAgentLanes: false),
            IsometricCouplingArc(sourcePath: "Sources/Auth/AuthSessionManager.swift", targetPath: "Sources/Auth/SessionTokenClaims.swift", sharedSymbolCount: 9, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Auth/AuthSessionManager.swift", targetPath: "Sources/Crypto/HKDFSubkeyRatchet.swift", sharedSymbolCount: 7, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Auth/AuthSessionManager.swift", targetPath: "Sources/Crypto/ReplayNonceBloomFilter.swift", sharedSymbolCount: 4, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Crypto/HKDFSubkeyRatchet.swift", targetPath: "Sources/Crypto/AEADChaChaPolySealer.swift", sharedSymbolCount: 5, crossesAgentLanes: false),
            IsometricCouplingArc(sourcePath: "Sources/Gateway/HTTP3StreamMultiplexer.swift", targetPath: "Sources/Transport/HTTP3ZeroCopyRing.swift", sharedSymbolCount: 11, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Gateway/HTTP3StreamMultiplexer.swift", targetPath: "Sources/Transport/QPACKStaticTable.swift", sharedSymbolCount: 6, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Gateway/HTTP3AuthMiddleware.swift", targetPath: "Sources/Auth/AuthSessionManager.swift", sharedSymbolCount: 8, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Sources/Gateway/HTTP3StreamMultiplexer.swift", targetPath: "Sources/Observability/OTelQuicTraceExporter.swift", sharedSymbolCount: 4, crossesAgentLanes: false),
            IsometricCouplingArc(sourcePath: "Tests/TransportTests/ZeroCopyRingPropertyTests.swift", targetPath: "Sources/Transport/HTTP3ZeroCopyRing.swift", sharedSymbolCount: 10, crossesAgentLanes: true),
            IsometricCouplingArc(sourcePath: "Tests/AuthTests/PasskeyAndHKDFFuzzTests.swift", targetPath: "Sources/Auth/AuthSessionManager.swift", sharedSymbolCount: 12, crossesAgentLanes: true)
        ]

        // 1 Live Territory Boundary Collision Warning
        let violationEvent = OwnershipViolationEvent(
            id: UUID(uuidString: "bbbb0002-0000-4000-8000-000000000001")!,
            laneID: "lane-codex-auth",
            vendor: .codex,
            relativePath: "Sources/Transport/HTTP3ConnectionPool.swift",
            violatedRuleSummary: "Outside allowed globs [Sources/Auth/**, Sources/Crypto/**]; owned by lane-claude-quic (Sources/Transport/**)",
            wasAutoReverted: false,
            detectedAt: baseDate.addingTimeInterval(79)
        )
        let collisionWarning = TerritoryBoundaryCollisionWarning(
            id: UUID(uuidString: "bbbb0002-0000-4000-8000-000000000002")!,
            relativePath: "Sources/Transport/HTTP3ConnectionPool.swift",
            rightfulOwnerLaneID: "lane-claude-quic",
            rightfulOwnerVendor: .claudeCode,
            intrudingLaneID: "lane-codex-auth",
            intrudingVendor: .codex,
            ownershipEvent: violationEvent,
            summary: "OpenAI Codex (lane-codex-auth) modified HTTP3ConnectionPool.swift inside Claude Code's Sources/Transport/** territory to wire subkey epoch callbacks."
        )

        return (tiles, arcs, [collisionWarning])
    }

    // MARK: - 6. 24 Realistic Wiretap LLM API Calls Across All 4 Vendors (+ 1 Circuit-Breaker Warning)

    private static func build24WiretapSpanRecords(baseDate: Date) -> [WiretapSpanRecord] {
        let pricing = ProviderPricingCatalog()
        // Tuple: (seq, laneID, taskID, vendor, host, path, model, inTok, cacheRead, cacheWrite, outTok, reasonTok, ttftMs, durMs, status, blocked, cbWarn, tools, offsetSec)
        let rawTurns: [(Int, String, String, AgentVendor, String, String, String, Int, Int, Int, Int, Int, Double, Double, Int, Bool, Bool, [String], Double)] = [
            // Claude Code (6 turns — Anthropic Messages SSE)
            (1, "lane-claude-quic", "h3-quic-ring", .claudeCode, "api.anthropic.com", "/v1/messages", "claude-sonnet-4-20250514", 42_800, 0, 38_400, 2_140, 1_400, 410, 2_380, 200, false, false, ["read_file", "grep_search"], 3),
            (2, "lane-claude-quic", "h3-quic-ring", .claudeCode, "api.anthropic.com", "/v1/messages", "claude-sonnet-4-20250514", 48_600, 38_400, 4_200, 3_620, 1_950, 285, 2_910, 200, false, false, ["edit_file"], 14),
            (3, "lane-claude-quic", "h3-quic-ring", .claudeCode, "api.anthropic.com", "/v1/messages", "claude-sonnet-4-20250514", 54_200, 42_600, 0, 2_890, 900, 260, 2_120, 200, false, false, ["run_command"], 29),
            (4, "lane-claude-quic", "h3-passkey-verifier", .claudeCode, "api.anthropic.com", "/v1/messages", "claude-opus-4-20250514", 61_500, 48_000, 6_000, 3_410, 2_600, 520, 4_180, 200, false, false, ["read_file", "edit_file"], 47),
            (5, "lane-claude-quic", "h3-passkey-verifier", .claudeCode, "api.anthropic.com", "/v1/messages", "claude-sonnet-4-20250514", 67_900, 54_000, 0, 2_980, 1_100, 275, 2_440, 200, false, false, ["edit_file", "run_command"], 63),
            (6, "lane-claude-quic", "h3-passkey-verifier", .claudeCode, "api.anthropic.com", "/v1/messages", "claude-sonnet-4-20250514", 71_400, 60_200, 0, 1_840, 450, 240, 1_690, 200, false, false, ["write_file"], 77),

            // OpenAI Codex (7 turns — OpenAI Responses SSE, culminating in 1 Circuit-Breaker Warning on turn #13!)
            (7, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "gpt-5-codex", 39_400, 0, 0, 2_650, 3_100, 390, 2_640, 200, false, false, ["shell", "apply_patch"], 5),
            (8, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "gpt-5-codex", 52_100, 36_800, 0, 4_120, 4_400, 355, 3_420, 200, false, false, ["apply_patch"], 18),
            (9, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "o3", 64_800, 44_000, 0, 3_890, 9_600, 690, 5_150, 200, false, false, ["apply_patch"], 31),
            (10, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "gpt-5-codex", 73_200, 56_000, 0, 3_240, 3_900, 340, 2_890, 200, false, false, ["shell"], 44),
            (11, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "o3", 88_500, 62_000, 0, 5_400, 14_200, 740, 6_120, 200, false, false, ["apply_patch", "shell"], 58),
            (12, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "o3", 96_400, 68_000, 0, 6_180, 16_800, 780, 6_840, 200, false, true, ["apply_patch"], 73),
            (13, "lane-codex-auth", "h3-auth-subkeys", .codex, "api.openai.com", "/v1/responses", "gpt-5-codex", 0, 0, 0, 0, 0, 0.4, 0.8, 429, true, true, [], 81),

            // Google AGY (6 turns — Gemini streamGenerateContent SSE)
            (14, "lane-agy-gateway", "h3-edge-router", .antigravity, "generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-pro:streamGenerateContent", "gemini-2.5-pro", 82_000, 64_000, 0, 3_420, 2_200, 310, 2_190, 200, false, false, ["read_file", "edit_file"], 53),
            (15, "lane-agy-gateway", "h3-edge-router", .antigravity, "generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-pro:streamGenerateContent", "gemini-2.5-pro", 94_600, 78_500, 0, 4_680, 2_750, 295, 2_610, 200, false, false, ["edit_file"], 65),
            (16, "lane-agy-gateway", "h3-edge-router", .antigravity, "generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-flash:streamGenerateContent", "gemini-2.5-flash", 104_000, 88_000, 0, 2_950, 600, 145, 1_120, 200, false, false, ["run_command"], 76),
            (17, "lane-agy-gateway", "h3-edge-router", .antigravity, "generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-pro:streamGenerateContent", "gemini-2.5-pro", 112_400, 96_000, 0, 5_840, 1_900, 320, 2_880, 200, false, false, ["write_file"], 86),
            (18, "lane-agy-gateway", "h3-ast-reconcile", .antigravity, "generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-pro:streamGenerateContent", "gemini-2.5-pro", 118_900, 102_000, 0, 3_190, 3_400, 335, 2_540, 200, false, false, ["relay_semantic_merge"], 98),
            (19, "lane-agy-gateway", "h3-ast-reconcile", .antigravity, "generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-pro:streamGenerateContent", "gemini-2.5-pro", 124_200, 110_000, 0, 2_410, 1_850, 290, 1_980, 200, false, false, ["relay_check_ownership"], 111),

            // Mistral Vibe (5 turns — Mistral Chat Completions SSE)
            (20, "lane-vibe-fuzz", "h3-fuzz-suite", .mistralVibe, "api.mistral.ai", "/v1/chat/completions", "devstral-medium", 44_200, 16_000, 0, 4_890, 0, 180, 1_540, 200, false, false, ["write_file"], 89),
            (21, "lane-vibe-fuzz", "h3-fuzz-suite", .mistralVibe, "api.mistral.ai", "/v1/chat/completions", "devstral-medium", 51_800, 38_000, 0, 5_620, 0, 165, 1_710, 200, false, false, ["write_file"], 99),
            (22, "lane-vibe-fuzz", "h3-fuzz-suite", .mistralVibe, "api.mistral.ai", "/v1/chat/completions", "codestral-2508", 36_400, 28_000, 0, 3_940, 0, 120, 1_090, 200, false, false, ["bash"], 108),
            (23, "lane-vibe-fuzz", "h3-fuzz-suite", .mistralVibe, "api.mistral.ai", "/v1/chat/completions", "devstral-medium", 58_900, 46_500, 0, 4_210, 0, 170, 1_480, 200, false, false, ["bash"], 119),
            (24, "lane-vibe-fuzz", "h3-fuzz-suite", .mistralVibe, "api.mistral.ai", "/v1/chat/completions", "codestral-2508", 61_200, 52_000, 0, 2_760, 0, 115, 940, 200, false, false, ["bash"], 128)
        ]

        return rawTurns.map { item in
            let (seq, laneID, taskID, vendor, host, path, model, inTok, cRead, cWrite, outTok, reasonTok, ttft, dur, status, blocked, cbWarn, tools, offsetSec) = item
            let rate = pricing.matchRate(for: model, fallbackVendor: vendor)
            let cost = blocked ? 0.0 : rate.estimateCostUSD(
                inputTokens: inTok,
                cachedReadTokens: cRead,
                outputTokens: outTok,
                reasoningTokens: reasonTok
            )
            let deterministicUUID = UUID(uuidString: String(format: "cccc0024-0000-4000-8000-%012d", seq))!
            return WiretapSpanRecord(
                id: deterministicUUID,
                sequenceIndex: seq,
                laneID: laneID,
                taskID: taskID,
                vendor: vendor,
                providerHost: host,
                endpointPath: path,
                modelIdentifier: model,
                inputTokens: inTok,
                cachedReadTokens: cRead,
                cacheWriteTokens: cWrite,
                outputTokens: outTok,
                reasoningTokens: reasonTok,
                costUSD: cost,
                ttftMs: ttft,
                durationMs: dur,
                statusCode: status,
                blockedByCircuitBreaker: blocked,
                isCircuitBreakerWarning: cbWarn,
                toolCallsInvoked: tools,
                recordedAt: baseDate.addingTimeInterval(offsetSec)
            )
        }
    }

    private static func buildBudgetAccounts(from records: [WiretapSpanRecord]) -> [LaneBudgetAccount] {
        let ceilings: [String: (AgentVendor, Double)] = [
            "lane-claude-quic": (.claudeCode, 6.00),
            "lane-codex-auth": (.codex, 1.15), // Tight cap that triggers realistic circuit-breaker warning/trip on Codex's heavy o3 turns!
            "lane-agy-gateway": (.antigravity, 4.50),
            "lane-vibe-fuzz": (.mistralVibe, 3.00)
        ]

        var map: [String: LaneBudgetAccount] = [:]
        for (laneID, (vendor, cap)) in ceilings {
            map[laneID] = LaneBudgetAccount(laneID: laneID, vendor: vendor, ceilingUSD: cap)
        }
        for r in records {
            var acc = map[r.laneID] ?? LaneBudgetAccount(laneID: r.laneID, vendor: r.vendor, ceilingUSD: 5.0)
            acc.requestCount += 1
            acc.inputTokens += r.inputTokens
            acc.cachedTokens += r.cachedReadTokens
            acc.outputTokens += (r.outputTokens + r.reasoningTokens)
            acc.spentUSD += r.costUSD
            if r.blockedByCircuitBreaker || acc.spentUSD >= acc.ceilingUSD {
                acc.circuitOpen = true
            }
            map[r.laneID] = acc
        }
        return map.values.sorted { $0.laneID < $1.laneID }
    }

    // MARK: - 7. Active Guardrail Plugin Audit Events & Hook Traces

    private static func buildGuardrailFindingsAndHookTraces(
        baseDate: Date
    ) -> ([RelayGuardrailFinding], [RelayHookTraceEntry]) {
        let f1 = RelayGuardrailFinding(
            id: UUID(uuidString: "dddd0005-0000-4000-8000-000000000001")!,
            pluginID: "io.relayide.destructive-shell-blocker",
            pluginName: "Destructive Shell Command Blocker",
            severity: .blocker,
            laneID: "lane-codex-auth",
            relativePath: ".worktrees/lane-codex-auth",
            title: "Blocked destructive shell invocation (git reset --hard)",
            detail: "Intercepted `git reset --hard HEAD~1` spawned by OpenAI Codex during HKDF retry; preserved uncommitted worktree state.",
            createdAt: baseDate.addingTimeInterval(61)
        )

        let f2 = RelayGuardrailFinding(
            id: UUID(uuidString: "dddd0005-0000-4000-8000-000000000002")!,
            pluginID: "io.relayide.territory-fence-guard",
            pluginName: "Territory Fence Cross-Lane Guard",
            severity: .warning,
            laneID: "lane-codex-auth",
            relativePath: "Sources/Transport/HTTP3ConnectionPool.swift",
            title: "Cross-lane territory drift detected",
            detail: "Lane 'lane-codex-auth' edited 'Sources/Transport/HTTP3ConnectionPool.swift' outside assigned globs [Sources/Auth/**, Sources/Crypto/**].",
            createdAt: baseDate.addingTimeInterval(79)
        )

        let redactedSamplePrefix = "sk-ant-" + "api03-"
        let f3 = RelayGuardrailFinding(
            id: UUID(uuidString: "dddd0005-0000-4000-8000-000000000003")!,
            pluginID: "io.relayide.secret-prompt-redactor",
            pluginName: "Outbound Prompt Secret Redactor",
            severity: .warning,
            laneID: "lane-claude-quic",
            relativePath: "$.messages[3].content",
            title: "Masked test credential token in outbound prompt",
            detail: "Redacted fixture token `\(redactedSamplePrefix)••••9f2a` → `[REDACTED:ANTHROPIC_API_KEY:8c41e09b]` before packet left 127.0.0.1.",
            createdAt: baseDate.addingTimeInterval(49)
        )

        let f4 = RelayGuardrailFinding(
            id: UUID(uuidString: "dddd0005-0000-4000-8000-000000000004")!,
            pluginID: "io.relayide.budget-anomaly-auditor",
            pluginName: "Wiretap Token & Cache Efficiency Auditor",
            severity: .warning,
            laneID: "lane-codex-auth",
            relativePath: nil,
            title: "Circuit breaker tripped on lane-codex-auth (103% of $1.15 cap)",
            detail: "OpenAI Codex lane reached $1.186 across 6 heavy reasoning turns; turn #7 halted with HTTP 429 locally.",
            createdAt: baseDate.addingTimeInterval(81)
        )

        let f5 = RelayGuardrailFinding(
            id: UUID(uuidString: "dddd0005-0000-4000-8000-000000000005")!,
            pluginID: "io.relayide.conventional-commit-synthesizer",
            pluginName: "AST Conventional Commit Synthesizer",
            severity: .pass,
            laneID: nil,
            relativePath: nil,
            title: "Synthesized Conventional Commit Proposal",
            detail: "feat(transport,auth): integrate HTTP3ZeroCopyRing, verifyPasskeyAssertion, rotateSessionSubkeys",
            createdAt: baseDate.addingTimeInterval(115)
        )

        let traces: [RelayHookTraceEntry] = [
            RelayHookTraceEntry(
                id: UUID(uuidString: "eeee0004-0000-4000-8000-000000000001")!,
                sequenceNumber: 1,
                hookKind: .onWiretapRequest,
                pluginID: f3.pluginID,
                pluginName: f3.pluginName,
                laneID: "lane-claude-quic",
                subjectSummary: "api.anthropic.com/claude-opus-4-20250514",
                decision: .redact,
                reasonSummary: "Masked test credential token in .env fixture snippet",
                redactedPayload: "ANTHROPIC_TEST_KEY=[REDACTED_BY_PLUGIN]",
                elapsedMicros: 312.4,
                findings: [f3],
                recordedAt: f3.createdAt
            ),
            RelayHookTraceEntry(
                id: UUID(uuidString: "eeee0004-0000-4000-8000-000000000002")!,
                sequenceNumber: 2,
                hookKind: .onCommandSpawn,
                pluginID: f1.pluginID,
                pluginName: f1.pluginName,
                laneID: "lane-codex-auth",
                subjectSummary: "/usr/bin/git reset --hard HEAD~1",
                decision: .veto,
                reasonSummary: "Blocked destructive command: git reset --hard",
                elapsedMicros: 184.7,
                findings: [f1],
                recordedAt: f1.createdAt
            ),
            RelayHookTraceEntry(
                id: UUID(uuidString: "eeee0004-0000-4000-8000-000000000003")!,
                sequenceNumber: 3,
                hookKind: .onFileTouch,
                pluginID: f2.pluginID,
                pluginName: f2.pluginName,
                laneID: "lane-codex-auth",
                subjectSummary: "Sources/Transport/HTTP3ConnectionPool.swift",
                decision: .warn,
                reasonSummary: "Path outside assigned territory globs [Sources/Auth/**, Sources/Crypto/**]",
                elapsedMicros: 229.1,
                findings: [f2],
                recordedAt: f2.createdAt
            ),
            RelayHookTraceEntry(
                id: UUID(uuidString: "eeee0004-0000-4000-8000-000000000004")!,
                sequenceNumber: 4,
                hookKind: .onPreMerge,
                pluginID: f5.pluginID,
                pluginName: f5.pluginName,
                laneID: "lane-claude-quic+lane-codex-auth",
                subjectSummary: "Sources/Auth/AuthSessionManager.swift",
                decision: .warn,
                reasonSummary: "3 symbols auto-merged cleanly; 1 intra-function conflict in validateTokenClaims requires operator resolution",
                elapsedMicros: 418.9,
                findings: [f5],
                recordedAt: f5.createdAt
            )
        ]

        return ([f1, f2, f3, f4, f5], traces)
    }
}

// MARK: - Convenience Flagship Campaign Seeder on MultiVendorDAGOrchestrator

public extension MultiVendorDAGOrchestrator {
    @discardableResult
    func seedZeroCopyHTTP3FlagshipCampaign() throws -> SynthesizedFlagshipCampaign {
        try RelayDemoWorkspaceSynthesizer().populateWorkspaceDatabase(database, orchestrator: self)
    }
}
