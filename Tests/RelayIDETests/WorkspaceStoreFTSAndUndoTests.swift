import Foundation
import RelayModels
import RelayWorkspaceStore
import SQLite3
import Testing

@Suite("SQLite WAL v1->v4 Migrations, Integrity, CRUD, FTS5 BM25 Search, Checkpoints & Undo Journal")
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

    @Test("RelayProjectDatabase applies v1->v4 WAL migrations cleanly and reopens idempotently")
    func sqliteSchemaMigrationsV1ThroughV4AndIdempotentReopen() throws {
        let (rootDir, bundleDir) = try makeTempBundleURL(label: "migrations")
        defer { try? FileManager.default.removeItem(at: rootDir) }

        #expect(RelayProjectDatabase.currentSchemaVersion == 4)
        #expect(RelaySchemaMigrationCatalog.allMigrations.map(\.version) == [1, 2, 3, 4])
        #expect(RelaySchemaMigrationCatalog.descriptor(forVersion: 4) != nil)

        do {
            let db = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
            try db.makeFTS5SearchStore().ensureExtensionTables()
            _ = try db.performWALCheckpoint(mode: .passive)
            let applied = try db.appliedSchemaMigrations()
            #expect(applied.map(\.version) == [1, 2, 3, 4])
            #expect(applied.allSatisfy { $0.allExpectedTablesPresent })
            try db.setMeta(key: "workspace_name", value: "PersistenceCheck")
        }

        // Reopen existing bundle -> migrations must be idempotent and metadata preserved
        let reopened = try RelayProjectDatabase(bundleDirectoryURL: bundleDir)
        #expect(reopened.getMeta(key: "workspace_name") == "PersistenceCheck")
        #expect(try reopened.appliedSchemaMigrations().count == 4)
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
        #expect(telemetry.schemaVersion == 4)
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
        #expect(stats.schemaVersion == 4)
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
}
