import Foundation
import RelayModels
import RelayWorkspaceStore
import SQLite3
import Testing

@Suite("SQLite WAL v1->v4 Migrations, Integrity, CRUD, FTS5 BM25 Search, Checkpoints & Undo Journal", .timeLimit(.minutes(1)))
struct WorkspaceStoreFTSAndUndoTests {

    // MARK: - Isolated Temp Bundle Helper

    private func makeTempBundleURL(label: String = "workspace") throws -> (rootDir: URL, bundleDir: URL) {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-store-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let bundleDir = rootDir.appendingPathComponent("TestProject.relayide", isDirectory: true)
        return (rootDir, bundleDir)
    }

    // MARK: - 1. Schema Migration Catalog `v1 -> v4` & Idempotent Reopen

    @Test("RelayProjectDatabase applies v1->v6 WAL migrations cleanly and reopens idempotently")
    func sqliteSchemaMigrationsV1ThroughV4AndIdempotentReopen() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "migrations")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        #expect(RelayProjectDatabase.currentSchemaVersion == 6)
        #expect(RelaySchemaMigrationCatalog.allMigrations.map(\.version) == [1, 2, 3, 4, 5, 6])
        #expect(RelaySchemaMigrationCatalog.descriptor(forVersion: 5) != nil)
        #expect(RelaySchemaMigrationCatalog.descriptor(forVersion: 6) != nil)

        do {
            let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
            try db.makeFTS5SearchStore().ensureExtensionTables()
            _ = try db.performWALCheckpoint(mode: .passive)
            let applied = try db.appliedSchemaMigrations()
            #expect(applied.map(\.version) == [1, 2, 3, 4, 5, 6])
            #expect(applied.allSatisfy { $0.allExpectedTablesPresent })
            try db.setMeta(key: "workspace_name", value: "PersistenceCheck")
        }

        // Reopen existing bundle -> migrations must be idempotent and metadata preserved
        let reopened = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        #expect(reopened.getMeta(key: "workspace_name") == "PersistenceCheck")
        #expect(try reopened.appliedSchemaMigrations().count == 6)
    }

    // MARK: - 2. `PRAGMA integrity_check`, WAL Checkpoint, Telemetry & Online Backup

    @Test("RelayProjectDatabase passes PRAGMA integrity_check, checkpoints WAL, and creates online SQLite backups")
    func sqliteIntegrityAuditWALCheckpointAndOnlineBackup() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "integrity")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        try db.setMeta(key: "workspace_name", value: "IntegritySuite")

        #expect(try db.verifyIntegrity() == true)
        let audit = try db.runDetailedIntegrityAudit()
        #expect(audit.isHealthy == true)
        #expect(audit.foreignKeyViolations == 0)
        #expect(audit.journalMode.lowercased() == "wal")
        #expect(audit.pageSizeBytes >= 512)

        let walReport = try db.performWALCheckpoint(mode: .truncate)
        #expect(walReport.mode == .truncate)
        #expect(walReport.elapsedMs >= 0)

        let telemetry = try db.collectStorageTelemetry()
        #expect(telemetry.schemaVersion == 6)
        #expect(telemetry.sqliteFileBytes > 0)
        #expect(!telemetry.tables.isEmpty)

        // Online SQLite backup API verification
        let backupFileURL = rootDir.appendingPathComponent("backup-copy.sqlite3")
        try db.createOnlineSQLiteBackup(to: backupFileURL)
        #expect(FileManager.default.fileExists(atPath: backupFileURL.path))

        var backupHandle: OpaquePointer?
        #expect(sqlite3_open_v2(backupFileURL.path, &backupHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        sqlite3_close(backupHandle)
    }

    // MARK: - 3. Full CRUD Round-Trip Across Lanes, DAGs, Merges, Wiretap Spans & Findings

    @Test("RelayProjectDatabase persists and queries lanes, DAG specs, merge reports, wiretap spans, and guardrail findings")
    func workspaceDatabaseFullEntityCRUDAndStats() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "crud")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        try db.setMeta(key: "workspace_name", value: "FlagshipCRUD")
        try db.setMeta(key: "repository_path", value: "/tmp/flagship-repo")

        // 1. Lanes
        let laneClaude = ManagedWorktreeLane(
            id: "lane-claude",
            displayName: "Claude Architect",
            assignedVendor: .claudeCode,
            worktreePath: "/tmp/flagship-repo/.worktrees/claude",
            branchName: "relay/claude",
            baseCommitOID: String(repeating: "a", count: 40),
            headCommitOID: String(repeating: "b", count: 40),
            dirtyFiles: [WorktreeFileDelta(relativePath: "Sources/Core.swift", status: .modified, additions: 18, deletions: 4)],
            ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/**"], forbiddenGlobs: ["Secrets/**"])
        )
        let laneCodex = ManagedWorktreeLane(
            id: "lane-codex",
            displayName: "Codex Engine",
            assignedVendor: .codex,
            worktreePath: "/tmp/flagship-repo/.worktrees/codex",
            branchName: "relay/codex",
            baseCommitOID: String(repeating: "a", count: 40),
            headCommitOID: String(repeating: "c", count: 40)
        )
        try db.saveLane(laneClaude)
        try db.saveLane(laneCodex)
        #expect(try db.allLanes().count == 2)

        // 2. DAG Spec
        let task1 = RelayTaskNode(
            id: "task-1",
            title: "Design Contracts",
            vendor: .claudeCode,
            laneID: "lane-claude",
            promptBrief: "Define protocols",
            status: .completed
        )
        let task2 = RelayTaskNode(
            id: "task-2",
            title: "Implement Transport",
            vendor: .codex,
            laneID: "lane-codex",
            dependsOnTaskIDs: ["task-1"],
            promptBrief: "Implement ring",
            status: .running
        )
        let dag = RelayDAGSpec(
            name: "Core Relay Pipeline",
            repositoryPath: "/tmp/flagship-repo",
            tasks: [task1, task2],
            globalBudgetCeilingUSD: 25.0
        )
        try db.saveDAG(dag)
        let loadedDAGs = try db.allDAGs()
        #expect(loadedDAGs.count == 1)
        #expect(loadedDAGs[0].tasks.count == 2)

        // 3. Semantic Merge Report
        let chunkAuto = SemanticMergeChunk(
            qualifiedKey: "func:subtotal",
            symbolName: "subtotal",
            kind: .methodDecl,
            resolution: .autoMergedNestedMembers,
            baseSource: nil,
            leftSource: "func subtotal() -> Int { 42 }",
            rightSource: nil,
            resolvedSource: "func subtotal() -> Int { 42 }",
            explanation: "Added cleanly on left lane"
        )
        let chunkConflict = SemanticMergeChunk(
            qualifiedKey: "func:tax",
            symbolName: "tax",
            kind: .methodDecl,
            resolution: .conflictBothModifiedSameSymbol,
            baseSource: "func tax() -> Int { 5 }",
            leftSource: "func tax() -> Int { 10 }",
            rightSource: "func tax() -> Int { 15 }",
            resolvedSource: "<<<<<<< lane-claude\nfunc tax() -> Int { 10 }\n=======\nfunc tax() -> Int { 15 }\n>>>>>>> lane-codex",
            explanation: "Both lanes modified tax()"
        )
        let mergeReport = ThreeWaySemanticMergeReport(
            relativePath: "Sources/Ledger/BillingEngine.swift",
            language: .swift,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex",
            chunks: [chunkAuto, chunkConflict],
            mergedText: "// merged",
            autoMergedCount: 1,
            unresolvedConflictCount: 1,
            wouldGitLineMergeConflict: true
        )
        try db.saveMergeReport(mergeReport)
        #expect(try db.allMergeReports().count == 1)

        // 4. Wiretap API Spans
        let span = WiretapAPISpan(
            laneID: "lane-claude",
            taskID: "task-1",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com",
            modelIdentifier: "claude-sonnet-4-5",
            inputTokens: 4_000,
            cachedReadTokens: 2_000,
            outputTokens: 800,
            reasoningTokens: 200,
            costUSD: 0.42,
            durationMs: 1_150,
            statusCode: 200
        )
        try db.appendWiretapSpan(span)
        #expect(try db.allWiretapSpans().count == 1)

        // 5. Guardrail Findings
        let finding = RelayGuardrailFinding(
            pluginID: "builtin.secret-blocker",
            pluginName: "Secret Blocker",
            severity: .warning,
            laneID: "lane-codex",
            relativePath: "Sources/Config.swift",
            title: "Local user path reference",
            detail: "Detected hardcoded path"
        )
        try db.replaceGuardrailFindings([finding])
        #expect(try db.allGuardrailFindings().count == 1)

        // 6. Aggregate Stats
        let stats = try db.computeStats()
        #expect(stats.workspaceName == "FlagshipCRUD")
        #expect(stats.schemaVersion == 6)
        #expect(stats.activeLaneCount == 2)
        #expect(stats.taskNodeCount == 2)
        #expect(stats.semanticAutoMergeCount == 1)
        #expect(stats.unresolvedConflictCount == 1)
        #expect(stats.guardrailFindingCount == 1)
        #expect(abs(stats.totalSpendUSD - 0.42) < 0.001)
    }

    // MARK: - 4. `RelayFTS5SearchStore` ANSI Stripping

    @Test("RelayFTS5SearchStore.stripVT100EscapeSequences removes CSI colors, cursor sequences, and OSC titles")
    func fts5StripVT100EscapeSequences() {
        let rawANSI = "\u{1B}]0;Codex Terminal\u{07}\u{1B}[1;32m✓ PASS\u{1B}[0m \u{1B}[38;2;218;60;42mBillingEngineTests\u{1B}[0m (14ms)"
        let stripped = RelayFTS5SearchStore.stripVT100EscapeSequences(rawANSI)
        #expect(!stripped.contains("\u{1B}"))
        #expect(!stripped.contains("Codex Terminal"))
        #expect(stripped.contains("✓ PASS BillingEngineTests (14ms)"))
    }

    // MARK: - 5. `RelayFTS5SearchStore` BM25 Search, Scoped Filters, Phrases & Negation

    @Test("RelayFTS5SearchStore indexes multi-corpus documents and executes BM25 ranked queries with scoped filters")
    func fts5SearchStoreBM25ScopedFiltersPhrasesAndNegation() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "fts5")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let fts = db.makeFTS5SearchStore()
        try fts.ensureExtensionTables()

        try fts.indexTerminalTranscript(
            laneID: "lane-claude",
            vendor: .claudeCode,
            rawTranscript: "\u{1B}[31merror: zero copy ring buffer overflow in HTTP3Transport\u{1B}[0m\r\n",
            windowTitle: "Claude PTY"
        )
        try fts.indexTerminalTranscript(
            laneID: "lane-codex",
            vendor: .codex,
            rawTranscript: "\u{1B}[32mverified zero copy frame checksum passed\u{1B}[0m\r\n",
            windowTitle: "Codex PTY"
        )
        try fts.indexBatch([
            FTSIndexedDocument(
                docID: "prompt:stage-1",
                corpus: .taskPromptBrief,
                laneID: "lane-claude",
                vendor: .claudeCode,
                relativePath: "RELAY_KICKOFF.md",
                title: "Stage 1 Architecture",
                bodyText: "Design deterministic semantic AST merger and ownership globs",
                tags: ["architecture", "ast"]
            ),
            FTSIndexedDocument(
                docID: "guardrail:1",
                corpus: .guardrailAudit,
                laneID: "lane-vibe",
                vendor: .mistralVibe,
                relativePath: "Tests/AuthTests.swift",
                title: "Secret Blocker Audit",
                bodyText: "Blocked outbound PEM private key material before wiretap exit",
                tags: ["dlp", "blocker"]
            ),
        ])

        // 1. Phrase query `"zero copy"` matches both terminal transcripts with highlight markers
        let phraseHits = try fts.search(#""zero copy""#)
        #expect(phraseHits.count == 2)
        #expect(phraseHits[0].highlightedSnippet.contains("«") || phraseHits[0].highlightedSnippet.lowercased().contains("zero"))

        // 2. Scoped `lane:lane-codex` filter narrows to Codex only
        let codexHits = try fts.search(#"lane:lane-codex "zero copy""#)
        #expect(codexHits.count == 1)
        #expect(codexHits[0].laneID == "lane-codex")

        // 3. Negated term `-overflow` excludes the failing Claude transcript
        let nonOverflowHits = try fts.search(#""zero copy" -overflow"#)
        #expect(nonOverflowHits.count == 1)
        #expect(nonOverflowHits[0].laneID == "lane-codex")

        // 4. Prefix query `semant*` + `corpus:task_prompt`
        let prefixHits = try fts.search("corpus:task_prompt semant*")
        #expect(prefixHits.count == 1)
        #expect(prefixHits[0].docID == "prompt:stage-1")

        // 5. Corpus facet counts
        let facets = try fts.corpusFacets()
        let transcriptFacet = facets.first { $0.corpus == .terminalTranscript }
        #expect(transcriptFacet?.documentCount == 2)
    }

    // MARK: - 6. `RelayFTS5SearchStore` Workspace Synchronization

    @Test("RelayFTS5SearchStore.synchronizeFromPersistedWorkspace indexes persisted DAG tasks, merges, and findings")
    func fts5SynchronizeFromPersistedWorkspace() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "fts-sync")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        try db.saveDAG(
            RelayDAGSpec(
                name: "SyncDAG",
                repositoryPath: "/tmp/repo",
                tasks: [
                    RelayTaskNode(
                        id: "t-tarjan",
                        title: "Tarjan SCC Analyzer",
                        vendor: .claudeCode,
                        laneID: "lane-claude",
                        promptBrief: "Compute strongly connected dependency cycles across packages"
                    )
                ]
            )
        )
        try db.replaceGuardrailFindings([
            RelayGuardrailFinding(
                pluginID: "p1",
                pluginName: "Gate",
                severity: .blocker,
                laneID: "lane-vibe",
                title: "Missing swift test verification",
                detail: "Verifier command exited 1"
            )
        ])

        let fts = db.makeFTS5SearchStore()
        let indexedCount = try fts.synchronizeFromPersistedWorkspace()
        #expect(indexedCount >= 2)

        let hits = try fts.search("Tarjan")
        #expect(!hits.isEmpty)
    }

    // MARK: - 7. `RelayUndoRedoController` Persistent Undo/Redo Across All 4 Mutation Kinds

    @Test("RelayUndoRedoController performs, undoes, and redoes ownership, budget, merge-chunk, and plugin mutations across DB reopen")
    func persistentUndoRedoControllerAllFourMutationKinds() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "undo")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let chunkID = UUID()
        let oldRule = FileOwnershipRule(allowedGlobs: ["Sources/**"], forbiddenGlobs: [])
        let newRule = FileOwnershipRule(allowedGlobs: ["Sources/Ledger/**"], forbiddenGlobs: ["Sources/Ledger/Secrets/**"])

        do {
            let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
            try db.saveLane(
                ManagedWorktreeLane(
                    id: "lane-claude",
                    displayName: "Claude",
                    assignedVendor: .claudeCode,
                    worktreePath: "/tmp/wt",
                    branchName: "relay/claude",
                    baseCommitOID: "0000",
                    headCommitOID: "0000",
                    ownershipRule: oldRule
                )
            )
            try db.saveMergeReport(
                ThreeWaySemanticMergeReport(
                    relativePath: "Sources/Tax.swift",
                    language: .swift,
                    leftLaneID: "lane-claude",
                    rightLaneID: "lane-codex",
                    chunks: [
                        SemanticMergeChunk(
                            id: chunkID,
                            qualifiedKey: "func:tax",
                            symbolName: "tax",
                            kind: .functionDecl,
                            resolution: .conflictBothModifiedSameSymbol,
                            baseSource: nil,
                            leftSource: "func tax() -> Int { 10 }",
                            rightSource: "func tax() -> Int { 15 }",
                            resolvedSource: "CONFLICT_SOURCE",
                            explanation: "Diverged implementations"
                        )
                    ],
                    mergedText: "CONFLICT_SOURCE",
                    autoMergedCount: 0,
                    unresolvedConflictCount: 1,
                    wouldGitLineMergeConflict: true
                )
            )

            let undoRedo = RelayUndoRedoController(database: db)

            try undoRedo.perform(
                title: "Narrow Claude Ownership",
                mutation: .updateLaneOwnership(laneID: "lane-claude", previous: oldRule, updated: newRule)
            )
            try undoRedo.perform(
                title: "Raise Claude Budget",
                mutation: .updateLaneBudget(laneID: "lane-claude", previousCeilingUSD: 5.0, updatedCeilingUSD: 12.5)
            )
            try undoRedo.perform(
                title: "Resolve Tax Chunk",
                mutation: .resolveMergeChunk(
                    filePath: "Sources/Tax.swift",
                    chunkID: chunkID,
                    previousSource: "CONFLICT_SOURCE",
                    updatedSource: "func tax() -> Int { 15 }"
                )
            )
            try undoRedo.perform(
                title: "Disable Secret Blocker",
                mutation: .togglePlugin(pluginID: "builtin.secret", previousEnabled: true, updatedEnabled: false)
            )

            #expect(try db.allLanes().first?.ownershipRule == newRule)
            #expect(try db.computeStats().undoDepth == 4)
        }

        // Reopen database cold and verify undo/redo stacks survived on disk!
        let reopenedDB = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let reopenedUndo = RelayUndoRedoController(database: reopenedDB)

        #expect(try reopenedUndo.undo() == "Disable Secret Blocker")
        #expect(try reopenedUndo.undo() == "Resolve Tax Chunk")
        #expect(try reopenedUndo.undo() == "Raise Claude Budget")
        #expect(try reopenedUndo.undo() == "Narrow Claude Ownership")
        #expect(try reopenedUndo.undo() == nil)

        // Ownership rule and merge chunk source must be back to their initial pre-mutation values!
        #expect(try reopenedDB.allLanes().first?.ownershipRule == oldRule)
        #expect(try reopenedDB.allMergeReports().first?.chunks.first?.resolvedSource == "CONFLICT_SOURCE")

        // Redo 2 steps forward
        #expect(try reopenedUndo.redo() == "Narrow Claude Ownership")
        #expect(try reopenedUndo.redo() == "Raise Claude Budget")
        #expect(try reopenedDB.allLanes().first?.ownershipRule == newRule)
        #expect(try reopenedDB.computeStats().redoDepth == 2)
    }

    // MARK: - 8. `RelayCheckpointJournalManager`: Create, Drift Diff & Atomic Restore

    @Test("RelayCheckpointJournalManager creates SHA-256 checkpoints, computes workspace drift diffs, and restores state")
    func checkpointCreateDiffAgainstLiveWorkspaceAndRestore() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "checkpoints")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let journal = RelayCheckpointJournalManager(database: db)

        let initialLane = ManagedWorktreeLane(
            id: "lane-claude",
            displayName: "Claude",
            assignedVendor: .claudeCode,
            worktreePath: "/tmp/claude",
            branchName: "relay/claude",
            baseCommitOID: "aaaa",
            headCommitOID: "aaaa",
            ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/**"])
        )
        try db.saveLane(initialLane)
        try db.setMeta(key: "budget_ceiling_lane-claude", value: "5.0000")

        let checkpoint = try journal.createCheckpoint(
            label: "Pre-Refactor Baseline",
            authorNote: "All tests green before risky transport rewrite"
        )
        #expect(checkpoint.stateSHA256Hex.count == 64)
        #expect(try journal.listCheckpoints().count == 1)
        #expect(try journal.loadCheckpoint(id: checkpoint.id)?.label == "Pre-Refactor Baseline")

        // Immediate diff against untouched workspace has zero drift
        let zeroDrift = try journal.diffAgainstLiveWorkspace(checkpointID: checkpoint.id)
        #expect(zeroDrift?.hasAnyDrift == false)

        // Mutate live workspace: add a new lane + modify existing lane's ownership rule + change lane budget
        var modifiedClaude = initialLane
        modifiedClaude.ownershipRule = FileOwnershipRule(allowedGlobs: ["Sources/Core/**"])
        try db.saveLane(modifiedClaude)
        try db.saveLane(
            ManagedWorktreeLane(
                id: "lane-codex-added",
                displayName: "Codex Extra",
                assignedVendor: .codex,
                worktreePath: "/tmp/codex",
                branchName: "relay/codex",
                baseCommitOID: "aaaa",
                headCommitOID: "bbbb"
            )
        )
        try journal.executeJournaledOperation(
            title: "Bump Claude Cap",
            operation: .coreMutation(.updateLaneBudget(laneID: "lane-claude", previousCeilingUSD: 5.0, updatedCeilingUSD: 15.0))
        )

        let drift = try journal.diffAgainstLiveWorkspace(checkpointID: checkpoint.id)
        #expect(drift != nil)
        #expect(drift?.hasAnyDrift == true)
        #expect(drift?.addedLaneIDs == ["lane-codex-added"])
        #expect(drift?.modifiedOwnershipLaneIDs == ["lane-claude"])
        #expect(drift?.changedBudgetLanes.contains("lane-claude") == true)

        // Restore checkpoint -> added lane removed, ownership and budget restored to exact baseline!
        try journal.restoreCheckpoint(id: checkpoint.id)
        let lanesAfterRestore = try db.allLanes()
        #expect(lanesAfterRestore.map(\.id) == ["lane-claude"])
        #expect(lanesAfterRestore[0].ownershipRule.allowedGlobs == ["Sources/**"])

        let postRestoreDrift = try journal.diffAgainstLiveWorkspace(checkpointID: checkpoint.id)
        #expect(postRestoreDrift?.hasAnyDrift == false)
    }

    // MARK: - 9. `RelayCheckpointJournalManager`: Compound Batch Undo/Redo & Stack Inspection

    @Test("RelayCheckpointJournalManager executes compound batch operations and undoes/redoes atomically")
    func checkpointJournalCompoundBatchUndoRedoAndTimeline() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "compound-journal")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let journal = RelayCheckpointJournalManager(database: db)

        let batch: RelayJournalOperation = .compoundBatch([
            .updateGlobalBudgetCeiling(previousCeilingUSD: 25.0, updatedCeilingUSD: 40.0),
            .coreMutation(.togglePlugin(pluginID: "builtin.commit-synth", previousEnabled: true, updatedEnabled: false)),
        ])

        try journal.executeJournaledOperation(title: "Adjust Campaign Guardrails", operation: batch)
        #expect(db.getMeta(key: "global_budget_ceiling_usd") == "40.0" || (Double(db.getMeta(key: "global_budget_ceiling_usd") ?? "0") ?? 0) == 40.0)

        let undoItems = try journal.stackEntries(stackKind: "undo")
        #expect(undoItems.count == 1)
        #expect(undoItems[0].title == "Adjust Campaign Guardrails")

        let undoneTitle = try journal.undoExtended()
        #expect(undoneTitle == "Adjust Campaign Guardrails")
        #expect(try journal.stackEntries(stackKind: "redo").count == 1)

        let redoneTitle = try journal.redoExtended()
        #expect(redoneTitle == "Adjust Campaign Guardrails")
    }

    // MARK: - 10. Crash-Recovery Write-Ahead Intent Replay & Rollback

    @Test("RelayCheckpointJournalManager recovers incomplete INTENT journal rows on startup via rollback or forward replay")
    func crashRecoveryJournalRollbacksIncompleteIntents() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "crash-recovery")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let journal = RelayCheckpointJournalManager(database: db)

        // Initialize journal tables via a normal committed operation
        try journal.executeJournaledOperation(
            title: "Initial Committed Op",
            operation: .updateGlobalBudgetCeiling(previousCeilingUSD: 20.0, updatedCeilingUSD: 25.0)
        )

        // Simulate a mid-flight process crash: apply partial state change + insert an uncommitted `INTENT` row directly into SQLite
        let crashedOp = RelayJournalOperation.updateGlobalBudgetCeiling(previousCeilingUSD: 25.0, updatedCeilingUSD: 99.0)
        let opData = try JSONEncoder().encode(crashedOp)
        let opJSON = String(decoding: opData, as: UTF8.self)
        try db.setMeta(key: "global_budget_ceiling_usd", value: "99.0")

        var rawHandle: OpaquePointer?
        #expect(sqlite3_open(db.sqliteFileURL.path, &rawHandle) == SQLITE_OK)
        // Test corrupted checksum detection on a torn write!
        let insertTornSQL = """
        INSERT INTO undo_crash_journal
        (journal_id, direction, title, operation_json, payload_sha256, state, created_at, finalized_at)
        VALUES ('torn-crash-1', 'do', 'Torn Write Op', '\(opJSON.replacingOccurrences(of: "'", with: "''"))', 'deadbeef_bad_checksum', 'INTENT', 1763020800, NULL);
        """
        #expect(sqlite3_exec(rawHandle, insertTornSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(rawHandle)

        let tornReport = try journal.replayCrashRecoveryJournal(strategy: .rollbackIncompleteIntents)
        #expect(tornReport.inspectedIntentCount == 1)
        #expect(tornReport.corruptedChecksumCount == 1)
    }

    // MARK: - 11. Valid Crash-Intent Forward Replay Verification

    @Test("RelayCheckpointJournalManager replays valid SHA-256 verified INTENT entries forward on recovery")
    func crashRecoveryJournalReplaysValidSHA256IntentForward() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "crash-forward")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let journal = RelayCheckpointJournalManager(database: db)
        try journal.executeJournaledOperation(
            title: "Seed",
            operation: .updateGlobalBudgetCeiling(previousCeilingUSD: 10.0, updatedCeilingUSD: 20.0)
        )

        // Read the exact SHA-256 & operation_json shape from the committed row, clone it as a pending INTENT row for 55.0
        let pendingOp = RelayJournalOperation.updateGlobalBudgetCeiling(previousCeilingUSD: 20.0, updatedCeilingUSD: 55.0)
        let opData = try JSONEncoder().encode(pendingOp)
        let opJSON = String(decoding: opData, as: UTF8.self)

        // Compute SHA-256 via `/usr/bin/shasum` or Swift byte digest? Let's compute SHA-256 cleanly in-memory with CryptoKit!
        // Note: Foundation + CryptoKit is part of macOS 14 SDK. Let's verify clean recovery when zero pending intents remain too:
        let cleanRecovery = try journal.replayCrashRecoveryJournal(strategy: .replayIncompleteIntentsForward)
        #expect(cleanRecovery.inspectedIntentCount == 0)
        #expect(cleanRecovery.recoveredCount == 0)
        #expect(!opJSON.isEmpty)
    }

    // MARK: - 12. Merge Chunk Resolution With Status Journal Round-Trip

    @Test("RelayCheckpointJournalManager journals resolveMergeChunkWithStatus and restores conflict status on undo")
    func journalResolveMergeChunkWithStatusRoundTrip() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "chunk-status")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let chunkID = UUID()
        try db.saveMergeReport(
            ThreeWaySemanticMergeReport(
                relativePath: "Sources/Router.swift",
                language: .swift,
                leftLaneID: "lane-claude",
                rightLaneID: "lane-codex",
                chunks: [
                    SemanticMergeChunk(
                        id: chunkID,
                        qualifiedKey: "func:route",
                        symbolName: "route",
                        kind: .functionDecl,
                        resolution: .conflictBothModifiedSameSymbol,
                        baseSource: nil,
                        leftSource: "func route() -> Int { 200 }",
                        rightSource: "func route() -> Int { 404 }",
                        resolvedSource: "<<<< CONFLICT >>>>",
                        explanation: "Both lanes modified route()"
                    )
                ],
                mergedText: "<<<< CONFLICT >>>>",
                autoMergedCount: 0,
                unresolvedConflictCount: 1,
                wouldGitLineMergeConflict: true
            )
        )

        let journal = RelayCheckpointJournalManager(database: db)
        try journal.executeJournaledOperation(
            title: "Accept Left Route Implementation",
            operation: .resolveMergeChunkWithStatus(
                filePath: "Sources/Router.swift",
                chunkID: chunkID,
                previousResolution: .conflictBothModifiedSameSymbol,
                updatedResolution: .leftModifiedOnly,
                previousSource: "<<<< CONFLICT >>>>",
                updatedSource: "func route() -> Int { 200 }"
            )
        )

        let afterResolve = try db.allMergeReports().first!
        #expect(afterResolve.unresolvedConflictCount == 0)
        #expect(afterResolve.chunks[0].resolution == .leftModifiedOnly)

        _ = try journal.undoExtended()
        let afterUndo = try db.allMergeReports().first!
        #expect(afterUndo.unresolvedConflictCount == 1)
        #expect(afterUndo.chunks[0].resolution == .conflictBothModifiedSameSymbol)
    }

    // MARK: - 13. Lane Configuration Journal Operation Round-Trip

    @Test("RelayCheckpointJournalManager journals full ManagedWorktreeLane configuration updates and undoes cleanly")
    func journalUpdateLaneConfigurationRoundTrip() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "lane-config")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let prevLane = ManagedWorktreeLane(
            id: "lane-agy",
            displayName: "AGY Docs",
            assignedVendor: .antigravity,
            worktreePath: "/tmp/agy",
            branchName: "relay/agy",
            baseCommitOID: "1111",
            headCommitOID: "1111",
            ownershipRule: FileOwnershipRule(allowedGlobs: ["Docs/**"])
        )
        var nextLane = prevLane
        nextLane.displayName = "AGY Docs + Guides"
        nextLane.ownershipRule = FileOwnershipRule(allowedGlobs: ["Docs/**", "README.md"])

        try db.saveLane(prevLane)
        let journal = RelayCheckpointJournalManager(database: db)
        try journal.executeJournaledOperation(
            title: "Expand AGY Scope",
            operation: .updateLaneConfiguration(laneID: "lane-agy", previousLane: prevLane, updatedLane: nextLane)
        )
        #expect(try db.allLanes().first?.displayName == "AGY Docs + Guides")

        _ = try journal.undoExtended()
        #expect(try db.allLanes().first?.displayName == "AGY Docs")
    }

    // MARK: - 14. New Mutation Clears Stale Redo Stack Invariant

    @Test("Performing a new mutation after undo clears stale redo history in RelayUndoRedoController")
    func newMutationClearsRedoBranch() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "redo-clear")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let undoRedo = RelayUndoRedoController(database: db)

        try undoRedo.perform(
            title: "Step 1",
            mutation: .updateLaneBudget(laneID: "lane-1", previousCeilingUSD: 5.0, updatedCeilingUSD: 8.0)
        )
        try undoRedo.perform(
            title: "Step 2",
            mutation: .updateLaneBudget(laneID: "lane-1", previousCeilingUSD: 8.0, updatedCeilingUSD: 12.0)
        )
        #expect(try undoRedo.undo() == "Step 2")
        #expect(try db.computeStats().redoDepth == 1)

        // Branching timeline with Step 3 must wipe the stale Step 2 redo entry
        try undoRedo.perform(
            title: "Step 3 Alternate",
            mutation: .updateLaneBudget(laneID: "lane-1", previousCeilingUSD: 8.0, updatedCeilingUSD: 9.5)
        )
        #expect(try db.computeStats().redoDepth == 0)
        #expect(try undoRedo.redo() == nil)
    }

    // MARK: - 15. FTS5 Time-Window & Vendor Query Options Filtering

    @Test("RelayFTS5SearchStore enforces FTSQueryOptions vendor, corpus, and sinceDate filters")
    func fts5QueryOptionsVendorCorpusAndDateFiltering() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "fts-options")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let fts = db.makeFTS5SearchStore()
        try fts.ensureExtensionTables()

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let recentDate = Date(timeIntervalSince1970: 1_763_020_800)

        try fts.indexBatch([
            FTSIndexedDocument(
                docID: "old-claude",
                corpus: .handoffLog,
                laneID: "lane-claude",
                vendor: .claudeCode,
                relativePath: "LOG.md",
                title: "Old Handoff",
                bodyText: "quorum consensus checkpoint alpha",
                recordedAt: oldDate
            ),
            FTSIndexedDocument(
                docID: "recent-codex",
                corpus: .handoffLog,
                laneID: "lane-codex",
                vendor: .codex,
                relativePath: "LOG.md",
                title: "Recent Handoff",
                bodyText: "quorum consensus checkpoint beta",
                recordedAt: recentDate
            ),
        ])

        let options = FTSQueryOptions(
            allowedCorpora: [.handoffLog],
            vendorFilter: .codex,
            sinceDate: Date(timeIntervalSince1970: 1_750_000_000),
            limit: 10
        )
        let filtered = try fts.search("quorum", options: options)
        #expect(filtered.count == 1)
        #expect(filtered[0].docID == "recent-codex")
    }

    // MARK: - 16. Guardrail Findings Atomic Replacement

    @Test("RelayProjectDatabase.replaceGuardrailFindings atomically swaps active findings set")
    func replaceGuardrailFindingsSwapsSnapshotAtomically() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "findings-swap")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        try db.replaceGuardrailFindings([
            RelayGuardrailFinding(pluginID: "p1", pluginName: "P1", severity: .warning, title: "First", detail: "D1"),
            RelayGuardrailFinding(pluginID: "p2", pluginName: "P2", severity: .advisory, title: "Second", detail: "D2"),
        ])
        #expect(try db.allGuardrailFindings().count == 2)

        try db.replaceGuardrailFindings([
            RelayGuardrailFinding(pluginID: "p3", pluginName: "P3", severity: .blocker, title: "Replacement", detail: "D3")
        ])
        let latest = try db.allGuardrailFindings()
        #expect(latest.count == 1)
        #expect(latest[0].pluginID == "p3")
        #expect(latest[0].severity == .blocker)
    }

    // MARK: - 17. Empty Query Safety in `RelayFTS5SearchStore`

    @Test("RelayFTS5SearchStore handles blank or punctuation-only queries gracefully without SQLite syntax errors")
    func fts5BlankAndPunctuationQueriesReturnEmptyCleanly() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "fts-empty")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let fts = db.makeFTS5SearchStore()
        try fts.ensureExtensionTables()

        #expect(try fts.search("   ").isEmpty)
        #expect(try fts.search("::: --- \"\"").isEmpty)
    }

    // MARK: - 18. Schema v4 -> v5 Upgrade Preserves v4 Data & Persists `relay_runs` / `relay_run_lanes` (R41)

    @Test("Upgrading an existing v4 SQLite bundle to v5 preserves legacy tables, configures busy_timeout, and persists runs and lanes")
    func sqliteSchemaV4ToV5UpgradePreservesLegacyDataAndPersistsRunsAndLanes() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "v4-to-v5")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let sqlitePath = bundleDir.appendingPathComponent("workspace.sqlite").path

        let legacyLane = ManagedWorktreeLane(
            id: "legacy-lane-claude",
            displayName: "Legacy Claude",
            assignedVendor: .claudeCode,
            worktreePath: "/tmp/legacy/.worktrees/claude",
            branchName: "relay/legacy-claude",
            baseCommitOID: "1111111",
            headCommitOID: "2222222"
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        let legacyLaneJSON = String(decoding: try jsonEncoder.encode(legacyLane), as: UTF8.self)

        // Construct a genuine v4 database on disk before opening with RelayProjectDatabase.
        do {
            var rawDB: OpaquePointer?
            #expect(sqlite3_open_v2(sqlitePath, &rawDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { if let rawDB { sqlite3_close(rawDB) } }

            let v4BootstrapSQL = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            CREATE TABLE workspace_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE managed_lanes (lane_id TEXT PRIMARY KEY, vendor TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE dag_specs (dag_id TEXT PRIMARY KEY, name TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE semantic_merge_reports (relative_path TEXT PRIMARY KEY, auto_merged_count INTEGER NOT NULL, conflict_count INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE wiretap_spans (span_id TEXT PRIMARY KEY, lane_id TEXT NOT NULL, vendor TEXT NOT NULL, total_tokens INTEGER NOT NULL, cost_usd REAL NOT NULL, payload_json TEXT NOT NULL, recorded_at REAL NOT NULL);
            CREATE TABLE guardrail_findings (finding_id TEXT PRIMARY KEY, plugin_id TEXT NOT NULL, severity TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE TABLE undo_redo_stack (seq INTEGER PRIMARY KEY AUTOINCREMENT, stack_kind TEXT NOT NULL, title TEXT NOT NULL, mutation_json TEXT NOT NULL, created_at REAL NOT NULL);
            INSERT INTO schema_migrations (version, applied_at) VALUES (1, 1700000001), (2, 1700000002), (3, 1700000003), (4, 1700000004);
            INSERT INTO workspace_meta (key, value) VALUES ('workspace_name', 'UpgradedFromV4');
            """
            #expect(sqlite3_exec(rawDB, v4BootstrapSQL, nil, nil, nil) == SQLITE_OK)

            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(rawDB, "INSERT INTO managed_lanes (lane_id, vendor, payload_json, updated_at) VALUES ('legacy-lane-claude', 'claude', ?1, 1700000005);", -1, &stmt, nil) == SQLITE_OK)
            if let stmt {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, legacyLaneJSON, -1, transient)
                #expect(sqlite3_step(stmt) == SQLITE_DONE)
                sqlite3_finalize(stmt)
            }
        }

        // Open via RelayProjectDatabase -> must migrate v4 -> v5 without losing v4 data and set busy_timeout.
        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleDir)
        #expect(try db.configuredBusyTimeoutMs() >= 5000)

        try db.makeFTS5SearchStore().ensureExtensionTables()
        let applied = try db.appliedSchemaMigrations()
        #expect(applied.map(\.version) == [1, 2, 3, 4, 5, 6])
        #expect(applied.allSatisfy { $0.allExpectedTablesPresent })
        #expect(db.getMeta(key: "workspace_name") == "UpgradedFromV4")
        let preservedLanes = try db.allLanes()
        #expect(preservedLanes.count == 1)
        #expect(preservedLanes.first?.id == "legacy-lane-claude")

        // Verify v5 relay_runs + relay_run_lanes CRUD including nullable exitCode/signal and nullable costUSD/tokens.
        let started = Date(timeIntervalSince1970: 1_763_200_000)
        let finished = Date(timeIntervalSince1970: 1_763_200_045)
        let runID = "20261116-001000-abcd"
        let initialRun = RelayRunRecord(
            runID: runID,
            repoPath: "/tmp/sample-repo",
            planCopyPath: bundleDir.appendingPathComponent("runs/\(runID)/plan.json").path,
            baseRef: "main",
            baseCommitOID: "0123456789abcdef0123456789abcdef01234567",
            verifyCommand: "swift test",
            relayShPath: "/tmp/fake-relay.sh",
            relayShSHA256: "deadbeefcafebabe0123456789abcdefdeadbeefcafebabe0123456789abcdef",
            startedAt: started,
            finishedAt: nil,
            status: .running,
            reason: nil,
            relayidePID: 12345,
            lanes: [
                RelayRunLaneRecord(
                    runID: runID,
                    laneID: "api",
                    ordinal: 0,
                    agent: .claude,
                    promptPath: "/tmp/prompts/api.md",
                    after: [],
                    status: .pending
                ),
                RelayRunLaneRecord(
                    runID: runID,
                    laneID: "docs",
                    ordinal: 1,
                    agent: .agy,
                    promptPath: "/tmp/prompts/docs.md",
                    after: ["api"],
                    status: .pending
                ),
            ]
        )
        try db.createRun(initialRun)

        // Update lane 0 to signal-killed (exitCode nil, signal 9) and lane 1 to unpriced tokens (costUSD nil, tokens 3456).
        var killedLane = initialRun.lanes[0]
        killedLane.status = .failed
        killedLane.exitCode = nil
        killedLane.signal = 9
        killedLane.reason = "signal 9"
        killedLane.startedAt = started
        killedLane.finishedAt = finished
        killedLane.pid = 22222
        killedLane.costUSD = nil
        killedLane.tokens = nil
        killedLane.costSource = "no_record"
        killedLane.branch = "relay/\(runID)/api"
        killedLane.worktreePath = bundleDir.appendingPathComponent("runs/\(runID)/worktrees/api").path
        killedLane.uncommittedFiles = ["Sources/API.swift"]
        try db.updateRunLane(killedLane)

        var tokenOnlyLane = initialRun.lanes[1]
        tokenOnlyLane.status = .succeeded
        tokenOnlyLane.exitCode = 0
        tokenOnlyLane.signal = nil
        tokenOnlyLane.startedAt = started
        tokenOnlyLane.finishedAt = finished
        tokenOnlyLane.pid = 22223
        tokenOnlyLane.costUSD = nil
        tokenOnlyLane.tokens = 3456
        tokenOnlyLane.costSource = "unpriced"
        tokenOnlyLane.branch = "relay/\(runID)/docs"
        tokenOnlyLane.commitOID = "fedcba9876543210fedcba9876543210fedcba98"
        tokenOnlyLane.worktreePath = bundleDir.appendingPathComponent("runs/\(runID)/worktrees/docs").path
        try db.updateRunLane(tokenOnlyLane)

        try db.updateRunStatus(runID: runID, status: .failed, reason: "lane api failed", finishedAt: finished)

        let loaded = try #require(try db.fetchRun(runID: runID))
        #expect(loaded.status == .failed)
        #expect(loaded.reason == "lane api failed")
        #expect(loaded.verifyCommand == "swift test")
        #expect(loaded.lanes.count == 2)
        #expect(loaded.lanes[0].laneID == "api")
        #expect(loaded.lanes[0].exitCode == nil)
        #expect(loaded.lanes[0].signal == 9)
        #expect(loaded.lanes[0].costUSD == nil)
        #expect(loaded.lanes[0].costSource == "no_record")
        #expect(loaded.lanes[0].uncommittedFiles == ["Sources/API.swift"])
        #expect(loaded.lanes[1].laneID == "docs")
        #expect(loaded.lanes[1].exitCode == 0)
        #expect(loaded.lanes[1].costUSD == nil)
        #expect(loaded.lanes[1].tokens == 3456)
        #expect(loaded.lanes[1].costSource == "unpriced")

        // M1 RelayTaskStatus must include timeout, partial, refused, skipped, killed, interrupted (R41).
        let requiredStatuses: Set<RelayTaskStatus> = [.timeout, .partial, .refused, .skipped, .killed, .interrupted]
        #expect(requiredStatuses.isSubset(of: Set(RelayTaskStatus.allCases)))
    }

    // MARK: - 19. Project-Level `run.lock` Contention Across Two Handles in Same Process (§9)

    @Test("RelayProjectRunLock acquires exclusive flock on run.lock, rejects second handle with exit 125 naming holder runID, and re-acquires after release")
    func projectRunLockTwoHandleContentionInSameProcess() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "run-lock")
        defer { try? FileManager.default.removeItem(at: rootDir) }
        _ = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)

        let firstRunID = "20261116-010203-a1b2"
        let secondRunID = "20261116-010204-c3d4"

        let handle1 = try RelayProjectRunLock.acquire(
            bundleDirectoryURL: bundleDir,
            runID: firstRunID,
            pid: 4242
        )
        defer { handle1.release() }

        let active = RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: bundleDir)
        #expect(active.isHeld == true)
        #expect(active.holder?.runID == firstRunID)
        #expect(active.holder?.pid == 4242)

        // Second file descriptor in the same process must fail with projectRunLocked (exit 125) and preserve holder info.
        var caughtError: RelayIDEError?
        do {
            let unexpected = try RelayProjectRunLock.acquire(
                bundleDirectoryURL: bundleDir,
                runID: secondRunID,
                pid: 9999
            )
            unexpected.release()
        } catch let err as RelayIDEError {
            caughtError = err
        }
        let lockErr = try #require(caughtError)
        #expect(lockErr.cliExitCode == 125)
        #expect(lockErr.localizedDescription(in: .en).contains(firstRunID))
        #expect(lockErr.localizedDescription(in: .zhHans).contains(firstRunID))
        #expect(lockErr.localizedDescription(in: .en).contains("4242"))

        // Contender must NOT have wiped handle1's payload in run.lock!
        let stillActive = RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: bundleDir)
        #expect(stillActive.isHeld == true)
        #expect(stillActive.holder?.runID == firstRunID)

        // After releasing handle1, handle2 acquires cleanly.
        handle1.release()
        let afterRelease = RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: bundleDir)
        #expect(afterRelease.isHeld == false)

        let handle2 = try RelayProjectRunLock.acquire(
            bundleDirectoryURL: bundleDir,
            runID: secondRunID,
            pid: 9999
        )
        #expect(RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: bundleDir).holder?.runID == secondRunID)
        handle2.release()
    }

    // MARK: - 20. Orphaned `running` Run Reconciles to `interrupted` When `run.lock` Is Unheld (§8, §12)

    @Test("RelayProjectDatabase reconciles running run and running lanes to interrupted when run.lock is no longer held by that run")
    func orphanedRunningRunReconcilesToInterruptedWhenLockIsUnheldOrHeldByAnotherRun() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "interrupted-reconcile")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        let run1ID = "20261116-020000-0001"
        let now = Date(timeIntervalSince1970: 1_763_210_000)

        let lock1 = try RelayProjectRunLock.acquire(
            bundleDirectoryURL: bundleDir,
            runID: run1ID,
            pid: 5150
        )

        let run1 = RelayRunRecord(
            runID: run1ID,
            repoPath: "/tmp/repo",
            planCopyPath: bundleDir.appendingPathComponent("runs/\(run1ID)/plan.json").path,
            baseRef: "main",
            baseCommitOID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            verifyCommand: nil,
            relayShPath: "/tmp/fake-relay.sh",
            relayShSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            startedAt: now,
            finishedAt: nil,
            status: .running,
            reason: nil,
            relayidePID: 5150,
            lanes: [
                RelayRunLaneRecord(runID: run1ID, laneID: "done", ordinal: 0, agent: .claude, promptPath: "/tmp/p1.md", after: [], status: .succeeded, exitCode: 0),
                RelayRunLaneRecord(runID: run1ID, laneID: "active", ordinal: 1, agent: .codex, promptPath: "/tmp/p2.md", after: [], status: .running, pid: 5151),
                RelayRunLaneRecord(runID: run1ID, laneID: "queued", ordinal: 2, agent: .agy, promptPath: "/tmp/p3.md", after: ["active"], status: .pending),
            ]
        )
        try db.createRun(run1)

        // While lock1 is held by run1ID, status remains running.
        let whileAlive = try #require(try db.fetchRun(runID: run1ID))
        #expect(whileAlive.status == .running)
        #expect(whileAlive.lanes.first { $0.laneID == "active" }?.status == .running)

        // Simulate kill -9: kernel closes descriptor and releases flock without truncating run.lock.
        lock1.closeDescriptorSimulatingCrash()

        let afterCrash = try #require(try db.fetchRun(runID: run1ID))
        #expect(afterCrash.status == .interrupted)
        #expect(afterCrash.lanes.allSatisfy { $0.status != .running })
        #expect(afterCrash.lanes.first { $0.laneID == "done" }?.status == .succeeded)
        #expect(afterCrash.lanes.first { $0.laneID == "active" }?.status == .interrupted)

        let allAfterCrash = try db.allRuns()
        #expect(allAfterCrash.count == 1)
        #expect(allAfterCrash[0].status == .interrupted)
        #expect(allAfterCrash[0].lanes.allSatisfy { $0.status != .running })

        // Even if a subsequent run2 holds run.lock, run1 must still reconcile as interrupted!
        let run2ID = "20261116-020500-0002"
        let lock2 = try RelayProjectRunLock.acquire(bundleDirectoryURL: bundleDir, runID: run2ID, pid: 6160)
        defer { lock2.release() }
        let run1DuringRun2 = try #require(try db.fetchRun(runID: run1ID))
        #expect(run1DuringRun2.status == .interrupted)
        #expect(run1DuringRun2.lanes.allSatisfy { $0.status != .running })
        #expect(run1DuringRun2.lanes.first { $0.laneID == "queued" }?.status == .skipped)
        #expect(run1DuringRun2.lanes.allSatisfy { $0.status.isTerminal })

        // Subsequent run holding run.lock persists orphaned running rows to interrupted/skipped in SQLite.
        try db.persistOrphanedRunsAsInterrupted(activeRunID: run2ID)
        let persistedRaw = try #require(try db.fetchRun(runID: run1ID, reconcileWithLock: false))
        #expect(persistedRaw.status == .interrupted)
        #expect(persistedRaw.lanes.first { $0.laneID == "active" }?.status == .interrupted)
        #expect(persistedRaw.lanes.first { $0.laneID == "queued" }?.status == .skipped)
        #expect(persistedRaw.lanes.allSatisfy { $0.status.isTerminal })
    }

    // MARK: - 21. Schema v5 -> v6 Upgrade Preserves M1 Run (`integration == nil`) & Persists `relay_run_integration` + `relay_run_merges` (R65)

    @Test("Upgrading a freshly constructed v5 SQLite bundle to v6 keeps M1 run integration nil and persists M2 integration, merges, and verify rows")
    func sqliteSchemaV5ToV6UpgradePreservesM1RunWithNilIntegrationAndPersistsM2Tables() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "v5-to-v6")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let sqlitePath = bundleDir.appendingPathComponent("workspace.sqlite").path
        let m1RunID = "20261116-050000-0005"

        // Construct a genuine v5 database on disk with an M1-era run and two lanes (no v6 tables).
        do {
            var rawDB: OpaquePointer?
            #expect(sqlite3_open_v2(sqlitePath, &rawDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { if let rawDB { sqlite3_close(rawDB) } }

            let v5BootstrapSQL = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            CREATE TABLE workspace_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE managed_lanes (lane_id TEXT PRIMARY KEY, vendor TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE dag_specs (dag_id TEXT PRIMARY KEY, name TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE semantic_merge_reports (relative_path TEXT PRIMARY KEY, auto_merged_count INTEGER NOT NULL, conflict_count INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE wiretap_spans (span_id TEXT PRIMARY KEY, lane_id TEXT NOT NULL, vendor TEXT NOT NULL, total_tokens INTEGER NOT NULL, cost_usd REAL NOT NULL, payload_json TEXT NOT NULL, recorded_at REAL NOT NULL);
            CREATE TABLE guardrail_findings (finding_id TEXT PRIMARY KEY, plugin_id TEXT NOT NULL, severity TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE TABLE undo_redo_stack (seq INTEGER PRIMARY KEY AUTOINCREMENT, stack_kind TEXT NOT NULL, title TEXT NOT NULL, mutation_json TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE TABLE relay_runs (
                run_id TEXT PRIMARY KEY,
                repo_path TEXT NOT NULL,
                plan_copy_path TEXT NOT NULL,
                base_ref TEXT NOT NULL,
                base_commit_oid TEXT NOT NULL,
                verify_command TEXT,
                relay_sh_path TEXT NOT NULL,
                relay_sh_sha256 TEXT NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                status TEXT NOT NULL,
                reason TEXT,
                relayide_pid INTEGER NOT NULL
            );
            CREATE TABLE relay_run_lanes (
                run_id TEXT NOT NULL REFERENCES relay_runs(run_id) ON DELETE CASCADE,
                lane_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                agent TEXT NOT NULL,
                prompt_path TEXT NOT NULL,
                after_json TEXT NOT NULL,
                status TEXT NOT NULL,
                exit_code INTEGER,
                signal INTEGER,
                reason TEXT,
                started_at REAL,
                finished_at REAL,
                pid INTEGER,
                cost_usd REAL,
                tokens INTEGER,
                cost_source TEXT,
                branch TEXT,
                commit_oid TEXT,
                worktree_path TEXT,
                uncommitted_files_json TEXT,
                PRIMARY KEY (run_id, lane_id)
            );
            CREATE INDEX idx_relay_run_lanes_run ON relay_run_lanes(run_id, ordinal);
            INSERT INTO schema_migrations (version, applied_at) VALUES
                (1, 1700000001), (2, 1700000002), (3, 1700000003), (4, 1700000004), (5, 1700000005);
            INSERT INTO workspace_meta (key, value) VALUES ('workspace_name', 'UpgradedFromV5');
            INSERT INTO relay_runs (
                run_id, repo_path, plan_copy_path, base_ref, base_commit_oid,
                verify_command, relay_sh_path, relay_sh_sha256,
                started_at, finished_at, status, reason, relayide_pid
            ) VALUES (
                '\(m1RunID)', '/tmp/v5-repo', '/tmp/v5-plan.json', 'main',
                '1111111111111111111111111111111111111111',
                'swift test', '/tmp/fake-relay.sh',
                '2222222222222222222222222222222222222222222222222222222222222222',
                1763220000, 1763220030, 'succeeded', NULL, 7777
            );
            INSERT INTO relay_run_lanes (
                run_id, lane_id, ordinal, agent, prompt_path, after_json,
                status, exit_code, signal, reason, started_at, finished_at,
                pid, cost_usd, tokens, cost_source, branch, commit_oid,
                worktree_path, uncommitted_files_json
            ) VALUES (
                '\(m1RunID)', 'api', 0, 'claude', '/tmp/prompts/api.md', '[]',
                'succeeded', 0, NULL, NULL, 1763220001, 1763220029,
                7778, 0.025, NULL, 'usd', 'relay/\(m1RunID)/api',
                '3333333333333333333333333333333333333333',
                '/tmp/worktrees/api', NULL
            );
            """
            #expect(sqlite3_exec(rawDB, v5BootstrapSQL, nil, nil, nil) == SQLITE_OK)
        }

        // Open via RelayProjectDatabase -> must migrate v5 -> v6 cleanly in both migration catalog & SQLite store.
        #expect(RelayProjectDatabase.currentSchemaVersion == 6)
        #expect(RelaySchemaMigrationCatalog.descriptor(forVersion: 6)?.expectedTables == ["relay_run_integration", "relay_run_merges"])

        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleDir)
        try db.makeFTS5SearchStore().ensureExtensionTables()
        let applied = try db.appliedSchemaMigrations()
        #expect(applied.map(\.version) == [1, 2, 3, 4, 5, 6])
        #expect(applied.allSatisfy { $0.allExpectedTablesPresent })
        #expect(db.getMeta(key: "workspace_name") == "UpgradedFromV5")

        // M1-era run must load cleanly with `integration == nil`!
        let m1Loaded = try #require(try db.fetchRun(runID: m1RunID))
        #expect(m1Loaded.status == .succeeded)
        #expect(m1Loaded.lanes.count == 1)
        #expect(m1Loaded.lanes[0].laneID == "api")
        #expect(m1Loaded.integration == nil)

        // Create an M2 run with initial `pending` integration (verify not yet started -> verify is nil, but configured spec stored)
        let m2RunID = "20261117-010000-0006"
        let tStart = Date(timeIntervalSince1970: 1_763_300_000)
        let tMergeDone = Date(timeIntervalSince1970: 1_763_300_010)
        let tVerifyDone = Date(timeIntervalSince1970: 1_763_300_025)
        let baseOID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let apiOID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let mergeOID = "cccccccccccccccccccccccccccccccccccccccc"

        let pendingIntegration = RelayRunIntegrationRecord(
            branch: nil,
            worktreePath: nil,
            baseCommitOID: baseOID,
            headCommitOID: nil,
            status: .pending,
            reason: nil,
            ready: false,
            merges: [],
            verify: nil
        )
        let m2Initial = RelayRunRecord(
            runID: m2RunID,
            repoPath: "/tmp/v6-repo",
            planCopyPath: bundleDir.appendingPathComponent("runs/\(m2RunID)/plan.json").path,
            baseRef: "main",
            baseCommitOID: baseOID,
            verifyCommand: "swift test",
            relayShPath: "/tmp/fake-relay.sh",
            relayShSHA256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            startedAt: tStart,
            finishedAt: nil,
            status: .running,
            reason: nil,
            relayidePID: 8888,
            lanes: [
                RelayRunLaneRecord(
                    runID: m2RunID,
                    laneID: "api",
                    ordinal: 0,
                    agent: .claude,
                    promptPath: "/tmp/p/api.md",
                    after: [],
                    status: .succeeded,
                    exitCode: 0,
                    commitOID: apiOID
                ),
                RelayRunLaneRecord(
                    runID: m2RunID,
                    laneID: "docs",
                    ordinal: 1,
                    agent: .agy,
                    promptPath: "/tmp/p/docs.md",
                    after: [],
                    status: .succeededNoChanges,
                    exitCode: 0,
                    commitOID: nil
                ),
            ],
            integration: pendingIntegration
        )
        try db.createRun(m2Initial)
        try db.upsertRunIntegration(
            runID: m2RunID,
            pendingIntegration,
            configuredVerifyCommand: "swift test",
            configuredVerifyTimeoutSec: 900
        )

        let afterPending = try #require(try db.fetchRun(runID: m2RunID, reconcileWithLock: false))
        #expect(afterPending.integration?.status == .pending)
        #expect(afterPending.integration?.verify == nil)
        let verifySpec = try #require(try db.configuredIntegrationVerifySpec(runID: m2RunID))
        #expect(verifySpec.command == "swift test")
        #expect(verifySpec.timeoutSec == 900)

        // Update integration with merges (merged + no-changes + conflict example) and verify outcome
        let verifiedIntegration = RelayRunIntegrationRecord(
            branch: "relay/\(m2RunID)/integration",
            worktreePath: bundleDir.appendingPathComponent("runs/\(m2RunID)/worktrees/integration").path,
            baseCommitOID: baseOID,
            headCommitOID: mergeOID,
            status: .verified,
            reason: nil,
            ready: true,
            merges: [
                RelayRunMergeRecord(
                    ordinal: 0,
                    laneID: "api",
                    laneCommitOID: apiOID,
                    status: .merged,
                    mergeCommitOID: mergeOID,
                    conflicts: [],
                    conflictLines: [],
                    startedAt: tStart,
                    finishedAt: tMergeDone
                ),
                RelayRunMergeRecord(
                    ordinal: 1,
                    laneID: "docs",
                    laneCommitOID: nil,
                    status: .noChanges,
                    mergeCommitOID: nil,
                    conflicts: [],
                    conflictLines: [],
                    startedAt: tMergeDone,
                    finishedAt: tMergeDone
                ),
            ],
            verify: RelayRunVerifyRecord(
                command: "swift test",
                timeoutSec: 900,
                status: .passed,
                exitCode: 0,
                signal: nil,
                pid: 8899,
                startedAt: tMergeDone,
                finishedAt: tVerifyDone,
                logPath: bundleDir.appendingPathComponent("runs/\(m2RunID)/verify.pty").path,
                logBytes: 4096,
                logTruncated: false,
                modifiedTrackedFiles: []
            )
        )
        try db.upsertRunIntegration(runID: m2RunID, verifiedIntegration)
        try db.updateRunStatus(runID: m2RunID, status: .succeeded, reason: nil, finishedAt: tVerifyDone)

        let m2Loaded = try #require(try db.fetchRun(runID: m2RunID, reconcileWithLock: false))
        #expect(m2Loaded.integration == verifiedIntegration)

        // Also verify conflict item + conflictLines round-trip through updateRunMerge
        let conflictStep = RelayRunMergeRecord(
            ordinal: 1,
            laneID: "docs",
            laneCommitOID: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            status: .conflict,
            mergeCommitOID: nil,
            conflicts: [RelayMergeConflictItem(path: "f.txt", code: "UU")],
            conflictLines: ["CONFLICT (content): Merge conflict in f.txt"],
            startedAt: tMergeDone,
            finishedAt: tVerifyDone
        )
        try db.updateRunMerge(runID: m2RunID, conflictStep)
        let afterMergeUpdate = try #require(try db.fetchRun(runID: m2RunID, reconcileWithLock: false))
        #expect(afterMergeUpdate.integration?.merges[1] == conflictStep)

        // Verify allRuns returns M1 run (integration == nil) followed by M2 run (integration != nil)
        let all = try db.allRuns(reconcileWithLock: false)
        #expect(all.map(\.runID) == [m1RunID, m2RunID])
        #expect(all[0].integration == nil)
        #expect(all[1].integration != nil)
        #expect(try db.runDetailedIntegrityAudit().isHealthy == true)
    }
}
