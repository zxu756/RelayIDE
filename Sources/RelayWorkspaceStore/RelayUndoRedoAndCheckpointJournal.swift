import CryptoKit
import Foundation
import RelayModels
import SQLite3

private let RELAY_JOURNAL_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Extended Transactional Journal Operations & Stack Inspection Models

public indirect enum RelayJournalOperation: Sendable, Codable, Hashable {
    case coreMutation(RelayUndoMutation)
    case updateLaneConfiguration(laneID: String, previousLane: ManagedWorktreeLane, updatedLane: ManagedWorktreeLane)
    case updateGlobalBudgetCeiling(previousCeilingUSD: Double, updatedCeilingUSD: Double)
    case resolveMergeChunkWithStatus(
        filePath: String,
        chunkID: UUID,
        previousResolution: SemanticMergeResolution,
        updatedResolution: SemanticMergeResolution,
        previousSource: String,
        updatedSource: String
    )
    case compoundBatch([RelayJournalOperation])

    public var inverted: RelayJournalOperation {
        switch self {
        case .coreMutation(let m):
            return .coreMutation(m.inverted)
        case .updateLaneConfiguration(let id, let prev, let next):
            return .updateLaneConfiguration(laneID: id, previousLane: next, updatedLane: prev)
        case .updateGlobalBudgetCeiling(let prev, let next):
            return .updateGlobalBudgetCeiling(previousCeilingUSD: next, updatedCeilingUSD: prev)
        case .resolveMergeChunkWithStatus(let path, let cid, let prevRes, let nextRes, let prevSrc, let nextSrc):
            return .resolveMergeChunkWithStatus(
                filePath: path,
                chunkID: cid,
                previousResolution: nextRes,
                updatedResolution: prevRes,
                previousSource: nextSrc,
                updatedSource: prevSrc
            )
        case .compoundBatch(let ops):
            return .compoundBatch(ops.reversed().map(\.inverted))
        }
    }

    public var categoryLabel: String {
        switch self {
        case .coreMutation(let m):
            switch m {
            case .updateLaneOwnership: return "Territory Ownership"
            case .updateLaneBudget: return "Lane Budget Cap"
            case .resolveMergeChunk: return "AST Merge Resolution"
            case .togglePlugin: return "Guardrail Plugin Toggle"
            }
        case .updateLaneConfiguration:
            return "Lane Configuration"
        case .updateGlobalBudgetCeiling:
            return "Global Budget Ceiling"
        case .resolveMergeChunkWithStatus:
            return "AST Merge Resolution"
        case .compoundBatch(let items):
            return "Batch Transaction (\(items.count) ops)"
        }
    }
}

public enum RelayJournalEntryState: String, Sendable, Codable, Hashable {
    case intentPending = "INTENT"
    case committed = "COMMITTED"
    case rolledBackOnRecovery = "ROLLED_BACK"
    case replayedOnRecovery = "REPLAYED"
}

public struct RelayUndoStackItem: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64 { sequenceNumber }
    public let sequenceNumber: Int64
    public let stackKind: String
    public let title: String
    public let categoryLabel: String
    public let createdAt: Date

    public init(
        sequenceNumber: Int64,
        stackKind: String,
        title: String,
        categoryLabel: String,
        createdAt: Date
    ) {
        self.sequenceNumber = sequenceNumber
        self.stackKind = stackKind
        self.title = title
        self.categoryLabel = categoryLabel
        self.createdAt = createdAt
    }
}

public enum JournalCrashRecoveryStrategy: String, Sendable, Codable, Hashable {
    case rollbackIncompleteIntents
    case replayIncompleteIntentsForward
}

public struct JournalCrashRecoveryReport: Sendable, Codable, Hashable {
    public let inspectedIntentCount: Int
    public let recoveredCount: Int
    public let corruptedChecksumCount: Int
    public let recoveredTitles: [String]
    public let strategyUsed: JournalCrashRecoveryStrategy
    public let replayedAt: Date

    public init(
        inspectedIntentCount: Int,
        recoveredCount: Int,
        corruptedChecksumCount: Int,
        recoveredTitles: [String],
        strategyUsed: JournalCrashRecoveryStrategy,
        replayedAt: Date = Date()
    ) {
        self.inspectedIntentCount = inspectedIntentCount
        self.recoveredCount = recoveredCount
        self.corruptedChecksumCount = corruptedChecksumCount
        self.recoveredTitles = recoveredTitles
        self.strategyUsed = strategyUsed
        self.replayedAt = replayedAt
    }
}

// MARK: - Workspace Checkpoint Snapshot & Diff Models

public struct RelayWorkspaceCheckpoint: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let label: String
    public let authorNote: String
    public let lanes: [ManagedWorktreeLane]
    public let dags: [RelayDAGSpec]
    public let mergeReports: [ThreeWaySemanticMergeReport]
    public let laneBudgetCeilings: [String: Double]
    public let pluginEnabledFlags: [String: Bool]
    public let globalBudgetCeilingUSD: Double
    public let stateSHA256Hex: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        authorNote: String = "",
        lanes: [ManagedWorktreeLane],
        dags: [RelayDAGSpec],
        mergeReports: [ThreeWaySemanticMergeReport],
        laneBudgetCeilings: [String: Double],
        pluginEnabledFlags: [String: Bool],
        globalBudgetCeilingUSD: Double,
        stateSHA256Hex: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.authorNote = authorNote
        self.lanes = lanes
        self.dags = dags
        self.mergeReports = mergeReports
        self.laneBudgetCeilings = laneBudgetCeilings
        self.pluginEnabledFlags = pluginEnabledFlags
        self.globalBudgetCeilingUSD = globalBudgetCeilingUSD
        self.stateSHA256Hex = stateSHA256Hex
        self.createdAt = createdAt
    }
}

public struct RelayWorkspaceCheckpointSummary: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let label: String
    public let authorNote: String
    public let laneCount: Int
    public let mergeReportCount: Int
    public let unresolvedConflictCount: Int
    public let stateSHA256Hex: String
    public let payloadBytes: Int
    public let createdAt: Date

    public init(
        id: UUID,
        label: String,
        authorNote: String,
        laneCount: Int,
        mergeReportCount: Int,
        unresolvedConflictCount: Int,
        stateSHA256Hex: String,
        payloadBytes: Int,
        createdAt: Date
    ) {
        self.id = id
        self.label = label
        self.authorNote = authorNote
        self.laneCount = laneCount
        self.mergeReportCount = mergeReportCount
        self.unresolvedConflictCount = unresolvedConflictCount
        self.stateSHA256Hex = stateSHA256Hex
        self.payloadBytes = payloadBytes
        self.createdAt = createdAt
    }
}

public struct RelayCheckpointDiffReport: Sendable, Codable, Hashable {
    public let checkpointID: UUID
    public let checkpointLabel: String
    public let addedLaneIDs: [String]
    public let removedLaneIDs: [String]
    public let modifiedOwnershipLaneIDs: [String]
    public let modifiedConfigurationLaneIDs: [String]
    public let resolvedConflictDelta: Int
    public let changedBudgetLanes: [String]
    public let toggledPluginIDs: [String]
    public let hasAnyDrift: Bool

    public init(
        checkpointID: UUID,
        checkpointLabel: String,
        addedLaneIDs: [String],
        removedLaneIDs: [String],
        modifiedOwnershipLaneIDs: [String],
        modifiedConfigurationLaneIDs: [String],
        resolvedConflictDelta: Int,
        changedBudgetLanes: [String],
        toggledPluginIDs: [String]
    ) {
        self.checkpointID = checkpointID
        self.checkpointLabel = checkpointLabel
        self.addedLaneIDs = addedLaneIDs
        self.removedLaneIDs = removedLaneIDs
        self.modifiedOwnershipLaneIDs = modifiedOwnershipLaneIDs
        self.modifiedConfigurationLaneIDs = modifiedConfigurationLaneIDs
        self.resolvedConflictDelta = resolvedConflictDelta
        self.changedBudgetLanes = changedBudgetLanes
        self.toggledPluginIDs = toggledPluginIDs
        self.hasAnyDrift = !(
            addedLaneIDs.isEmpty &&
            removedLaneIDs.isEmpty &&
            modifiedOwnershipLaneIDs.isEmpty &&
            modifiedConfigurationLaneIDs.isEmpty &&
            resolvedConflictDelta == 0 &&
            changedBudgetLanes.isEmpty &&
            toggledPluginIDs.isEmpty
        )
    }
}

// MARK: - Crash-Safe SQLite Checkpoint & Write-Ahead Mutation Journal Manager

public final class RelayCheckpointJournalManager: @unchecked Sendable {
    public let database: RelayProjectDatabase
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public init(database: RelayProjectDatabase) {
        self.database = database
        try? ensureJournalTables()
    }

    public func ensureJournalTables() throws {
        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.execSQL(db, sql: """
            CREATE TABLE IF NOT EXISTS undo_crash_journal (
                journal_id TEXT PRIMARY KEY,
                direction TEXT NOT NULL, -- 'do', 'undo', 'redo'
                title TEXT NOT NULL,
                operation_json TEXT NOT NULL,
                payload_sha256 TEXT NOT NULL,
                state TEXT NOT NULL, -- 'INTENT', 'COMMITTED', 'ROLLED_BACK', 'REPLAYED'
                created_at REAL NOT NULL,
                finalized_at REAL
            );
            CREATE INDEX IF NOT EXISTS idx_crash_journal_state ON undo_crash_journal(state, created_at);

            CREATE TABLE IF NOT EXISTS extended_undo_redo_stack (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                stack_kind TEXT NOT NULL, -- 'undo' or 'redo'
                title TEXT NOT NULL,
                category_label TEXT NOT NULL,
                operation_json TEXT NOT NULL,
                payload_sha256 TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspace_checkpoints (
                checkpoint_id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                author_note TEXT NOT NULL,
                lane_count INTEGER NOT NULL,
                merge_count INTEGER NOT NULL,
                conflict_count INTEGER NOT NULL,
                state_sha256 TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_workspace_checkpoints_time ON workspace_checkpoints(created_at DESC);
            """)
        }
    }

    /// Executes an extended operation with write-ahead `INTENT -> COMMITTED` crash journaling.
    public func executeJournaledOperation(
        title: String,
        operation: RelayJournalOperation
    ) throws {
        try ensureJournalTables()
        let opData = try encoder.encode(operation)
        let opJSON = String(decoding: opData, as: UTF8.self)
        let digest = Self.sha256Hex(opData)
        let journalID = UUID().uuidString
        let now = Date().timeIntervalSince1970

        // Step 1: Write durable INTENT record before touching workspace state
        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.runPrepared(
                db,
                sql: """
                INSERT INTO undo_crash_journal
                (journal_id, direction, title, operation_json, payload_sha256, state, created_at, finalized_at)
                VALUES (?1, 'do', ?2, ?3, ?4, ?5, ?6, NULL);
                """
            ) { stmt in
                sqlite3_bind_text(stmt, 1, journalID, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, title, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, opJSON, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, digest, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, RelayJournalEntryState.intentPending.rawValue, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 6, now)
            }
        }

        // Step 2: Apply operation to database state
        try applyOperationToWorkspace(operation)

        // Step 3: Record on extended stack, mirror core mutation to v4 undo_redo_stack if applicable, clear redo, mark COMMITTED
        if case .coreMutation(let coreMut) = operation {
            try database.pushStackEntry(kind: "undo", title: title, mutation: coreMut)
            try database.clearRedoStack()
        }

        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.execSQL(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try RelayFTS5SearchStore.runPrepared(
                    db,
                    sql: """
                    INSERT INTO extended_undo_redo_stack
                    (stack_kind, title, category_label, operation_json, payload_sha256, created_at)
                    VALUES ('undo', ?1, ?2, ?3, ?4, ?5);
                    """
                ) { stmt in
                    sqlite3_bind_text(stmt, 1, title, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, operation.categoryLabel, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, opJSON, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, digest, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
                }

                try RelayFTS5SearchStore.execSQL(db, sql: "DELETE FROM extended_undo_redo_stack WHERE stack_kind = 'redo';")

                try RelayFTS5SearchStore.runPrepared(
                    db,
                    sql: "UPDATE undo_crash_journal SET state = ?1, finalized_at = ?2 WHERE journal_id = ?3;"
                ) { stmt in
                    sqlite3_bind_text(stmt, 1, RelayJournalEntryState.committed.rawValue, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                    sqlite3_bind_text(stmt, 3, journalID, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                }
                try RelayFTS5SearchStore.execSQL(db, sql: "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    @discardableResult
    public func undoExtended() throws -> String? {
        try ensureJournalTables()
        guard let popped = try popExtendedEntry(stackKind: "undo") else {
            // Fall back to base v4 `undo_redo_stack` if populated directly via `RelayUndoRedoController.perform`
            guard let legacy = try database.popStackEntry(kind: "undo") else { return nil }
            try applyOperationToWorkspace(.coreMutation(legacy.mutation.inverted))
            try database.pushStackEntry(kind: "redo", title: legacy.title, mutation: legacy.mutation)
            return legacy.title
        }

        if case .coreMutation = popped.operation {
            _ = try? database.popStackEntry(kind: "undo")
        }

        try applyOperationToWorkspace(popped.operation.inverted)
        try pushExtendedEntry(stackKind: "redo", title: popped.title, operation: popped.operation)
        if case .coreMutation(let coreMut) = popped.operation {
            try database.pushStackEntry(kind: "redo", title: popped.title, mutation: coreMut)
        }
        return popped.title
    }

    @discardableResult
    public func redoExtended() throws -> String? {
        try ensureJournalTables()
        guard let popped = try popExtendedEntry(stackKind: "redo") else {
            guard let legacy = try database.popStackEntry(kind: "redo") else { return nil }
            try applyOperationToWorkspace(.coreMutation(legacy.mutation))
            try database.pushStackEntry(kind: "undo", title: legacy.title, mutation: legacy.mutation)
            return legacy.title
        }

        if case .coreMutation = popped.operation {
            _ = try? database.popStackEntry(kind: "redo")
        }

        try applyOperationToWorkspace(popped.operation)
        try pushExtendedEntry(stackKind: "undo", title: popped.title, operation: popped.operation)
        if case .coreMutation(let coreMut) = popped.operation {
            try database.pushStackEntry(kind: "undo", title: popped.title, mutation: coreMut)
        }
        return popped.title
    }

    /// Scans `undo_crash_journal` for orphaned `INTENT` records interrupted mid-flight and deterministically recovers them.
    public func replayCrashRecoveryJournal(
        strategy: JournalCrashRecoveryStrategy = .rollbackIncompleteIntents
    ) throws -> JournalCrashRecoveryReport {
        try ensureJournalTables()

        let pendingRows: [(id: String, title: String, json: String, digest: String)] = try database.withLockedHandle { db in
            let sql = """
            SELECT journal_id, title, operation_json, payload_sha256
            FROM undo_crash_journal
            WHERE state = 'INTENT'
            ORDER BY created_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return [] }
            defer { sqlite3_finalize(p) }
            var list: [(String, String, String, String)] = []
            while sqlite3_step(p) == SQLITE_ROW {
                list.append((
                    RelayFTS5SearchStore.colString(p, 0),
                    RelayFTS5SearchStore.colString(p, 1),
                    RelayFTS5SearchStore.colString(p, 2),
                    RelayFTS5SearchStore.colString(p, 3)
                ))
            }
            return list
        }

        var recoveredCount = 0
        var corruptedCount = 0
        var titles: [String] = []

        for row in pendingRows {
            let rawData = Data(row.json.utf8)
            let computedDigest = Self.sha256Hex(rawData)
            guard computedDigest == row.digest,
                  let decodedOp = try? decoder.decode(RelayJournalOperation.self, from: rawData) else {
                corruptedCount += 1
                try markJournalEntryState(id: row.id, state: .rolledBackOnRecovery)
                continue
            }

            switch strategy {
            case .rollbackIncompleteIntents:
                try applyOperationToWorkspace(decodedOp.inverted)
                try markJournalEntryState(id: row.id, state: .rolledBackOnRecovery)
            case .replayIncompleteIntentsForward:
                try applyOperationToWorkspace(decodedOp)
                try pushExtendedEntry(stackKind: "undo", title: row.title, operation: decodedOp)
                try markJournalEntryState(id: row.id, state: .replayedOnRecovery)
            }
            recoveredCount += 1
            titles.append(row.title)
        }

        return JournalCrashRecoveryReport(
            inspectedIntentCount: pendingRows.count,
            recoveredCount: recoveredCount,
            corruptedChecksumCount: corruptedCount,
            recoveredTitles: titles,
            strategyUsed: strategy
        )
    }

    // MARK: - Named Workspace Checkpoints

    @discardableResult
    public func createCheckpoint(label: String, authorNote: String = "") throws -> RelayWorkspaceCheckpoint {
        try ensureJournalTables()
        let lanes = try database.allLanes()
        let dags = try database.allDAGs()
        let merges = try database.allMergeReports()
        let budgetCeilings = try readMetaPrefixMap(prefix: "budget_ceiling_") { Double($0) }
        let pluginFlags = try readMetaPrefixMap(prefix: "plugin_enabled_") { $0 == "1" || $0.lowercased() == "true" }
        let globalCap = Double(database.getMeta(key: "global_budget_ceiling_usd") ?? "") ?? 25.0

        struct DigestPayload: Encodable {
            let lanes: [ManagedWorktreeLane]
            let dags: [RelayDAGSpec]
            let merges: [ThreeWaySemanticMergeReport]
            let budgetCeilings: [String: Double]
            let pluginFlags: [String: Bool]
            let globalCap: Double
        }
        let digestBytes = try encoder.encode(
            DigestPayload(
                lanes: lanes,
                dags: dags,
                merges: merges,
                budgetCeilings: budgetCeilings,
                pluginFlags: pluginFlags,
                globalCap: globalCap
            )
        )
        let shaHex = Self.sha256Hex(digestBytes)

        let checkpoint = RelayWorkspaceCheckpoint(
            label: label,
            authorNote: authorNote,
            lanes: lanes,
            dags: dags,
            mergeReports: merges,
            laneBudgetCeilings: budgetCeilings,
            pluginEnabledFlags: pluginFlags,
            globalBudgetCeilingUSD: globalCap,
            stateSHA256Hex: shaHex
        )

        let payloadData = try encoder.encode(checkpoint)
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)
        let totalConflicts = merges.reduce(0) { $0 + $1.unresolvedConflictCount }

        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.runPrepared(
                db,
                sql: """
                INSERT OR REPLACE INTO workspace_checkpoints
                (checkpoint_id, label, author_note, lane_count, merge_count, conflict_count, state_sha256, payload_json, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                """
            ) { stmt in
                sqlite3_bind_text(stmt, 1, checkpoint.id.uuidString, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, checkpoint.label, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, checkpoint.authorNote, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 4, Int32(lanes.count))
                sqlite3_bind_int(stmt, 5, Int32(merges.count))
                sqlite3_bind_int(stmt, 6, Int32(totalConflicts))
                sqlite3_bind_text(stmt, 7, shaHex, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, payloadJSON, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 9, checkpoint.createdAt.timeIntervalSince1970)
            }
        }
        return checkpoint
    }

    public func listCheckpoints(limit: Int = 50) throws -> [RelayWorkspaceCheckpointSummary] {
        try ensureJournalTables()
        return try database.withLockedHandle { db in
            let sql = """
            SELECT checkpoint_id, label, author_note, lane_count, merge_count, conflict_count,
                   state_sha256, LENGTH(CAST(payload_json AS BLOB)), created_at
            FROM workspace_checkpoints
            ORDER BY created_at DESC
            LIMIT ?1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return [] }
            defer { sqlite3_finalize(p) }
            sqlite3_bind_int(p, 1, Int32(max(1, limit)))

            var list: [RelayWorkspaceCheckpointSummary] = []
            while sqlite3_step(p) == SQLITE_ROW {
                guard let id = UUID(uuidString: RelayFTS5SearchStore.colString(p, 0)) else { continue }
                list.append(
                    RelayWorkspaceCheckpointSummary(
                        id: id,
                        label: RelayFTS5SearchStore.colString(p, 1),
                        authorNote: RelayFTS5SearchStore.colString(p, 2),
                        laneCount: Int(sqlite3_column_int64(p, 3)),
                        mergeReportCount: Int(sqlite3_column_int64(p, 4)),
                        unresolvedConflictCount: Int(sqlite3_column_int64(p, 5)),
                        stateSHA256Hex: RelayFTS5SearchStore.colString(p, 6),
                        payloadBytes: Int(sqlite3_column_int64(p, 7)),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(p, 8))
                    )
                )
            }
            return list
        }
    }

    public func loadCheckpoint(id: UUID) throws -> RelayWorkspaceCheckpoint? {
        try ensureJournalTables()
        let rawJSON: String? = try database.withLockedHandle { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload_json FROM workspace_checkpoints WHERE checkpoint_id = ?1;", -1, &stmt, nil) == SQLITE_OK,
                  let p = stmt else { return nil }
            defer { sqlite3_finalize(p) }
            sqlite3_bind_text(p, 1, id.uuidString, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
            guard sqlite3_step(p) == SQLITE_ROW else { return nil }
            return RelayFTS5SearchStore.colString(p, 0)
        }
        guard let json = rawJSON else { return nil }
        return try decoder.decode(RelayWorkspaceCheckpoint.self, from: Data(json.utf8))
    }

    public func diffAgainstLiveWorkspace(checkpointID: UUID) throws -> RelayCheckpointDiffReport? {
        guard let cp = try loadCheckpoint(id: checkpointID) else { return nil }
        let liveLanes = try database.allLanes()
        let liveMerges = try database.allMergeReports()
        let liveBudgets = try readMetaPrefixMap(prefix: "budget_ceiling_") { Double($0) }
        let livePlugins = try readMetaPrefixMap(prefix: "plugin_enabled_") { $0 == "1" || $0.lowercased() == "true" }

        let cpLaneMap = Dictionary(uniqueKeysWithValues: cp.lanes.map { ($0.id, $0) })
        let liveLaneMap = Dictionary(uniqueKeysWithValues: liveLanes.map { ($0.id, $0) })

        let addedLanes = Set(liveLaneMap.keys).subtracting(cpLaneMap.keys).sorted()
        let removedLanes = Set(cpLaneMap.keys).subtracting(liveLaneMap.keys).sorted()

        var ownershipChanged: [String] = []
        var configChanged: [String] = []
        for id in Set(cpLaneMap.keys).intersection(liveLaneMap.keys).sorted() {
            guard let oldL = cpLaneMap[id], let newL = liveLaneMap[id] else { continue }
            if oldL.ownershipRule != newL.ownershipRule {
                ownershipChanged.append(id)
            }
            if oldL.displayName != newL.displayName || oldL.assignedVendor != newL.assignedVendor || oldL.headCommitOID != newL.headCommitOID {
                configChanged.append(id)
            }
        }

        let cpConflicts = cp.mergeReports.reduce(0) { $0 + $1.unresolvedConflictCount }
        let liveConflicts = liveMerges.reduce(0) { $0 + $1.unresolvedConflictCount }
        let conflictDelta = cpConflicts - liveConflicts

        var budgetDiffs: [String] = []
        for k in Set(cp.laneBudgetCeilings.keys).union(liveBudgets.keys).sorted() {
            if abs((cp.laneBudgetCeilings[k] ?? -1) - (liveBudgets[k] ?? -1)) > 0.0001 {
                budgetDiffs.append(k)
            }
        }

        var pluginDiffs: [String] = []
        for k in Set(cp.pluginEnabledFlags.keys).union(livePlugins.keys).sorted() {
            if cp.pluginEnabledFlags[k] != livePlugins[k] {
                pluginDiffs.append(k)
            }
        }

        return RelayCheckpointDiffReport(
            checkpointID: cp.id,
            checkpointLabel: cp.label,
            addedLaneIDs: addedLanes,
            removedLaneIDs: removedLanes,
            modifiedOwnershipLaneIDs: ownershipChanged,
            modifiedConfigurationLaneIDs: configChanged,
            resolvedConflictDelta: conflictDelta,
            changedBudgetLanes: budgetDiffs,
            toggledPluginIDs: pluginDiffs
        )
    }

    public func restoreCheckpoint(id: UUID) throws {
        guard let cp = try loadCheckpoint(id: id) else {
            throw RelayIDEError.databaseError(code: SQLITE_NOTFOUND, message: "Checkpoint \(id.uuidString) not found")
        }
        // Save automatic pre-restore safety checkpoint
        _ = try createCheckpoint(
            label: "Auto-Backup Before Restore (\(cp.label))",
            authorNote: "Automatic pre-restore snapshot"
        )

        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.execSQL(db, sql: """
            DELETE FROM managed_lanes;
            DELETE FROM dag_specs;
            DELETE FROM semantic_merge_reports;
            """)
        }
        for lane in cp.lanes {
            try database.saveLane(lane)
        }
        for dag in cp.dags {
            try database.saveDAG(dag)
        }
        for report in cp.mergeReports {
            try database.saveMergeReport(report)
        }
        for (laneID, cap) in cp.laneBudgetCeilings {
            try database.setMeta(key: "budget_ceiling_\(laneID)", value: String(format: "%.4f", cap))
        }
        for (pluginID, flag) in cp.pluginEnabledFlags {
            try database.setMeta(key: "plugin_enabled_\(pluginID)", value: flag ? "1" : "0")
        }
        try database.setMeta(key: "global_budget_ceiling_usd", value: String(format: "%.4f", cp.globalBudgetCeilingUSD))
    }

    public func stackEntries(stackKind: String, limit: Int = 50) throws -> [RelayUndoStackItem] {
        try ensureJournalTables()
        return try database.withLockedHandle { db in
            let sql = """
            SELECT seq, stack_kind, title, category_label, created_at
            FROM extended_undo_redo_stack
            WHERE stack_kind = ?1
            ORDER BY seq DESC
            LIMIT ?2;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return [] }
            defer { sqlite3_finalize(p) }
            sqlite3_bind_text(p, 1, stackKind, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
            sqlite3_bind_int(p, 2, Int32(max(1, limit)))

            var items: [RelayUndoStackItem] = []
            while sqlite3_step(p) == SQLITE_ROW {
                items.append(
                    RelayUndoStackItem(
                        sequenceNumber: sqlite3_column_int64(p, 0),
                        stackKind: RelayFTS5SearchStore.colString(p, 1),
                        title: RelayFTS5SearchStore.colString(p, 2),
                        categoryLabel: RelayFTS5SearchStore.colString(p, 3),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(p, 4))
                    )
                )
            }
            return items
        }
    }

    // MARK: - Internal Workspace State Applier

    internal func applyOperationToWorkspace(_ operation: RelayJournalOperation) throws {
        switch operation {
        case .coreMutation(let mutation):
            switch mutation {
            case .updateLaneOwnership(let laneID, _, let updatedRule):
                var lanes = try database.allLanes()
                if let idx = lanes.firstIndex(where: { $0.id == laneID }) {
                    lanes[idx].ownershipRule = updatedRule
                    try database.saveLane(lanes[idx])
                }
            case .updateLaneBudget(let laneID, _, let ceiling):
                try database.setMeta(key: "budget_ceiling_\(laneID)", value: String(format: "%.4f", ceiling))
            case .resolveMergeChunk(let filePath, let chunkID, _, let updatedSource):
                try updateMergeChunkInDatabase(
                    filePath: filePath,
                    chunkID: chunkID,
                    updatedResolution: .leftModifiedOnly,
                    updatedSource: updatedSource
                )
            case .togglePlugin(let pluginID, _, let enabled):
                try database.setMeta(key: "plugin_enabled_\(pluginID)", value: enabled ? "1" : "0")
            }

        case .updateLaneConfiguration(_, _, let updatedLane):
            try database.saveLane(updatedLane)

        case .updateGlobalBudgetCeiling(_, let updatedUSD):
            try database.setMeta(key: "global_budget_ceiling_usd", value: String(format: "%.4f", updatedUSD))

        case .resolveMergeChunkWithStatus(let filePath, let chunkID, _, let updatedResolution, _, let updatedSource):
            try updateMergeChunkInDatabase(
                filePath: filePath,
                chunkID: chunkID,
                updatedResolution: updatedResolution,
                updatedSource: updatedSource
            )

        case .compoundBatch(let operations):
            for op in operations {
                try applyOperationToWorkspace(op)
            }
        }
    }

    private func updateMergeChunkInDatabase(
        filePath: String,
        chunkID: UUID,
        updatedResolution: SemanticMergeResolution,
        updatedSource: String
    ) throws {
        let reports = try database.allMergeReports()
        guard let existing = reports.first(where: { $0.relativePath == filePath }),
              let chunkIndex = existing.chunks.firstIndex(where: { $0.id == chunkID }) else {
            return
        }
        var updatedChunks = existing.chunks
        updatedChunks[chunkIndex].resolvedSource = updatedSource
        updatedChunks[chunkIndex].resolution = updatedResolution

        let nonEmpty = updatedChunks
            .map(\.resolvedSource)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rebuiltText = nonEmpty.isEmpty ? "" : (nonEmpty.joined(separator: "\n\n") + "\n")
        let conflictTotal = updatedChunks.filter { $0.resolution.isConflict }.count
        let autoTotal = updatedChunks.filter { $0.resolution != .unchanged && !$0.resolution.isConflict }.count

        let rebuiltReport = ThreeWaySemanticMergeReport(
            relativePath: existing.relativePath,
            language: existing.language,
            leftLaneID: existing.leftLaneID,
            rightLaneID: existing.rightLaneID,
            chunks: updatedChunks,
            mergedText: rebuiltText,
            autoMergedCount: autoTotal,
            unresolvedConflictCount: conflictTotal,
            wouldGitLineMergeConflict: existing.wouldGitLineMergeConflict,
            crossFileCollisions: existing.crossFileCollisions
        )
        try database.saveMergeReport(rebuiltReport)
    }

    private func pushExtendedEntry(stackKind: String, title: String, operation: RelayJournalOperation) throws {
        let data = try encoder.encode(operation)
        let json = String(decoding: data, as: UTF8.self)
        let digest = Self.sha256Hex(data)
        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.runPrepared(
                db,
                sql: """
                INSERT INTO extended_undo_redo_stack
                (stack_kind, title, category_label, operation_json, payload_sha256, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                """
            ) { stmt in
                sqlite3_bind_text(stmt, 1, stackKind, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, title, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, operation.categoryLabel, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, json, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, digest, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            }
        }
    }

    private func popExtendedEntry(stackKind: String) throws -> (title: String, operation: RelayJournalOperation)? {
        try database.withLockedHandle { db in
            let sql = """
            SELECT seq, title, operation_json
            FROM extended_undo_redo_stack
            WHERE stack_kind = ?1
            ORDER BY seq DESC
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return nil }
            defer { sqlite3_finalize(p) }
            sqlite3_bind_text(p, 1, stackKind, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
            guard sqlite3_step(p) == SQLITE_ROW else { return nil }

            let seq = sqlite3_column_int64(p, 0)
            let title = RelayFTS5SearchStore.colString(p, 1)
            let json = RelayFTS5SearchStore.colString(p, 2)
            let op = try decoder.decode(RelayJournalOperation.self, from: Data(json.utf8))

            try RelayFTS5SearchStore.runPrepared(db, sql: "DELETE FROM extended_undo_redo_stack WHERE seq = ?1;") { delStmt in
                sqlite3_bind_int64(delStmt, 1, seq)
            }
            return (title, op)
        }
    }

    private func markJournalEntryState(id: String, state: RelayJournalEntryState) throws {
        try database.withLockedHandle { db in
            try RelayFTS5SearchStore.runPrepared(
                db,
                sql: "UPDATE undo_crash_journal SET state = ?1, finalized_at = ?2 WHERE journal_id = ?3;"
            ) { stmt in
                sqlite3_bind_text(stmt, 1, state.rawValue, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, id, -1, RELAY_JOURNAL_SQLITE_TRANSIENT)
            }
        }
    }

    private func readMetaPrefixMap<V>(prefix: String, transform: (String) -> V?) throws -> [String: V] {
        try database.withLockedHandle { db in
            var stmt: OpaquePointer?
            let sql = "SELECT key, value FROM workspace_meta WHERE key LIKE ?1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return [:] }
            defer { sqlite3_finalize(p) }
            sqlite3_bind_text(p, 1, "\(prefix)%", -1, RELAY_JOURNAL_SQLITE_TRANSIENT)

            var out: [String: V] = [:]
            while sqlite3_step(p) == SQLITE_ROW {
                let fullKey = RelayFTS5SearchStore.colString(p, 0)
                let rawVal = RelayFTS5SearchStore.colString(p, 1)
                let stripped = String(fullKey.dropFirst(prefix.count))
                if let parsed = transform(rawVal) {
                    out[stripped] = parsed
                }
            }
            return out
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Transactional Domain Mutators & Crash-Recovery Extensions on RelayUndoRedoController

public extension RelayUndoRedoController {
    var checkpointJournal: RelayCheckpointJournalManager {
        RelayCheckpointJournalManager(database: database)
    }

    /// Records a full `ManagedWorktreeLane` configuration edit (vendor reassignment, display name, branch/HEAD update) with crash-safe journaling.
    func recordLaneConfigurationEdit(
        previousLane: ManagedWorktreeLane,
        updatedLane: ManagedWorktreeLane,
        title: String? = nil
    ) throws {
        let actionTitle = title ?? "Configure Lane '\(updatedLane.displayName)' (\(updatedLane.assignedVendor.shortBadge))"
        try checkpointJournal.executeJournaledOperation(
            title: actionTitle,
            operation: .updateLaneConfiguration(
                laneID: updatedLane.id,
                previousLane: previousLane,
                updatedLane: updatedLane
            )
        )
    }

    /// Records a territory file-ownership glob guardrail update.
    func recordTerritoryOwnershipMutation(
        laneID: String,
        previousRule: FileOwnershipRule,
        updatedRule: FileOwnershipRule,
        title: String? = nil
    ) throws {
        let actionTitle = title ?? "Update Territory Ownership Globs for '\(laneID)'"
        try checkpointJournal.executeJournaledOperation(
            title: actionTitle,
            operation: .coreMutation(
                .updateLaneOwnership(laneID: laneID, previous: previousRule, updated: updatedRule)
            )
        )
    }

    /// Resolves a 3-Way Semantic AST Merge conflict chunk and accurately updates report conflict/auto-merge counters.
    func recordMergeConflictResolution(
        filePath: String,
        chunkID: UUID,
        previousResolution: SemanticMergeResolution = .conflictBothModifiedSameSymbol,
        updatedResolution: SemanticMergeResolution = .leftModifiedOnly,
        previousSource: String,
        updatedSource: String,
        title: String? = nil
    ) throws {
        let shortName = (filePath as NSString).lastPathComponent
        let actionTitle = title ?? "Resolve AST Merge Chunk in \(shortName) (\(updatedResolution.rawValue))"
        try checkpointJournal.executeJournaledOperation(
            title: actionTitle,
            operation: .resolveMergeChunkWithStatus(
                filePath: filePath,
                chunkID: chunkID,
                previousResolution: previousResolution,
                updatedResolution: updatedResolution,
                previousSource: previousSource,
                updatedSource: updatedSource
            )
        )
    }

    /// Records a per-lane USD circuit-breaker budget cap adjustment.
    func recordBudgetCapAdjustment(
        laneID: String,
        previousCeilingUSD: Double,
        updatedCeilingUSD: Double,
        title: String? = nil
    ) throws {
        let actionTitle = title ?? String(format: "Set '%@' Budget Ceiling $%.2f → $%.2f", laneID, previousCeilingUSD, updatedCeilingUSD)
        try checkpointJournal.executeJournaledOperation(
            title: actionTitle,
            operation: .coreMutation(
                .updateLaneBudget(laneID: laneID, previousCeilingUSD: previousCeilingUSD, updatedCeilingUSD: updatedCeilingUSD)
            )
        )
    }

    /// Records enabling or disabling a JavaScriptCore guardrail plugin.
    func recordGuardrailPluginToggle(
        pluginID: String,
        previousEnabled: Bool,
        updatedEnabled: Bool,
        title: String? = nil
    ) throws {
        let stateVerb = updatedEnabled ? "Enable" : "Disable"
        let actionTitle = title ?? "\(stateVerb) Guardrail Plugin '\(pluginID)'"
        try checkpointJournal.executeJournaledOperation(
            title: actionTitle,
            operation: .coreMutation(
                .togglePlugin(pluginID: pluginID, previousEnabled: previousEnabled, updatedEnabled: updatedEnabled)
            )
        )
    }

    /// Executes an atomic compound transaction group that undoes/redoes as a single logical step.
    func performCompoundTransaction(title: String, operations: [RelayJournalOperation]) throws {
        guard !operations.isEmpty else { return }
        try checkpointJournal.executeJournaledOperation(
            title: title,
            operation: .compoundBatch(operations)
        )
    }

    @discardableResult
    func undoJournaled() throws -> String? {
        try checkpointJournal.undoExtended()
    }

    @discardableResult
    func redoJournaled() throws -> String? {
        try checkpointJournal.redoExtended()
    }

    func undoTimeline(limit: Int = 50) throws -> [RelayUndoStackItem] {
        try checkpointJournal.stackEntries(stackKind: "undo", limit: limit)
    }

    func redoTimeline(limit: Int = 50) throws -> [RelayUndoStackItem] {
        try checkpointJournal.stackEntries(stackKind: "redo", limit: limit)
    }

    func replayCrashSafeJournal(
        strategy: JournalCrashRecoveryStrategy = .rollbackIncompleteIntents
    ) throws -> JournalCrashRecoveryReport {
        try checkpointJournal.replayCrashRecoveryJournal(strategy: strategy)
    }
}
