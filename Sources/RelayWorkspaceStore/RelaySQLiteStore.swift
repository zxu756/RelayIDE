import Foundation
import RelayModels
import SQLite3

// MARK: - .relayproj SQLite3 WAL Persistence Engine (Schema v1..v6)

private let RELAY_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class RelayProjectDatabase: @unchecked Sendable {
    public static let currentSchemaVersion = 6
    private let lock = NSLock()
    public let bundleDirectoryURL: URL
    public let sqliteFileURL: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static func bundleExists(at bundleDirectoryURL: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundleDirectoryURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        let sqlitePath = bundleDirectoryURL.appendingPathComponent("workspace.sqlite").path
        return FileManager.default.fileExists(atPath: sqlitePath)
    }

    public static func openExisting(bundleDirectoryURL: URL) throws -> RelayProjectDatabase {
        guard bundleExists(at: bundleDirectoryURL) else {
            throw RelayIDEError.workspaceBundleNotFound(bundleDirectoryURL.path)
        }
        return try RelayProjectDatabase(bundleDirectoryURL: bundleDirectoryURL)
    }

    public init(bundleDirectoryURL: URL) throws {
        self.bundleDirectoryURL = bundleDirectoryURL
        try FileManager.default.createDirectory(at: bundleDirectoryURL, withIntermediateDirectories: true)
        self.sqliteFileURL = bundleDirectoryURL.appendingPathComponent("workspace.sqlite")

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            sqliteFileURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Failed to open SQLite file"
            if let handle { sqlite3_close(handle) }
            throw RelayIDEError.databaseError(code: rc, message: msg)
        }
        self.db = opened
        sqlite3_busy_timeout(opened, 5000)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try migrateSchemaIfNeeded()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func migrateSchemaIfNeeded() throws {
        try execRaw("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        """)

        let current = queryInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
        if current < 1 {
            try execRaw("""
            CREATE TABLE IF NOT EXISTS workspace_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS managed_lanes (
                lane_id TEXT PRIMARY KEY,
                vendor TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dag_specs (
                dag_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            INSERT INTO schema_migrations (version, applied_at) VALUES (1, strftime('%s','now'));
            """)
        }
        if current < 2 {
            try execRaw("""
            CREATE TABLE IF NOT EXISTS semantic_merge_reports (
                relative_path TEXT PRIMARY KEY,
                auto_merged_count INTEGER NOT NULL,
                conflict_count INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            INSERT INTO schema_migrations (version, applied_at) VALUES (2, strftime('%s','now'));
            """)
        }
        if current < 3 {
            try execRaw("""
            CREATE TABLE IF NOT EXISTS wiretap_spans (
                span_id TEXT PRIMARY KEY,
                lane_id TEXT NOT NULL,
                vendor TEXT NOT NULL,
                total_tokens INTEGER NOT NULL,
                cost_usd REAL NOT NULL,
                payload_json TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_wiretap_lane ON wiretap_spans(lane_id);
            CREATE TABLE IF NOT EXISTS guardrail_findings (
                finding_id TEXT PRIMARY KEY,
                plugin_id TEXT NOT NULL,
                severity TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT INTO schema_migrations (version, applied_at) VALUES (3, strftime('%s','now'));
            """)
        }
        if current < 4 {
            try execRaw("""
            CREATE TABLE IF NOT EXISTS undo_redo_stack (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                stack_kind TEXT NOT NULL, -- 'undo' or 'redo'
                title TEXT NOT NULL,
                mutation_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT INTO schema_migrations (version, applied_at) VALUES (4, strftime('%s','now'));
            """)
        }
        if current < 5 {
            try execRaw("""
            CREATE TABLE IF NOT EXISTS relay_runs (
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
            CREATE TABLE IF NOT EXISTS relay_run_lanes (
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
            CREATE INDEX IF NOT EXISTS idx_relay_run_lanes_run ON relay_run_lanes(run_id, ordinal);
            INSERT INTO schema_migrations (version, applied_at) VALUES (5, strftime('%s','now'));
            """)
        }
        if current < 6 {
            try execRaw("""
            CREATE TABLE IF NOT EXISTS relay_run_integration (
                run_id TEXT PRIMARY KEY REFERENCES relay_runs(run_id) ON DELETE CASCADE,
                branch TEXT,
                worktree_path TEXT,
                base_commit_oid TEXT NOT NULL,
                head_commit_oid TEXT,
                status TEXT NOT NULL,
                reason TEXT,
                ready INTEGER NOT NULL DEFAULT 0,
                verify_command TEXT,
                verify_timeout_sec INTEGER,
                verify_status TEXT,
                verify_exit_code INTEGER,
                verify_signal INTEGER,
                verify_pid INTEGER,
                verify_started_at REAL,
                verify_finished_at REAL,
                verify_log_path TEXT,
                verify_log_bytes INTEGER,
                verify_log_truncated INTEGER,
                verify_modified_tracked_files_json TEXT
            );
            CREATE TABLE IF NOT EXISTS relay_run_merges (
                run_id TEXT NOT NULL REFERENCES relay_runs(run_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                lane_id TEXT NOT NULL,
                lane_commit_oid TEXT,
                status TEXT NOT NULL,
                merge_commit_oid TEXT,
                conflicts_json TEXT NOT NULL,
                conflict_lines_json TEXT NOT NULL,
                started_at REAL,
                finished_at REAL,
                PRIMARY KEY (run_id, lane_id)
            );
            CREATE INDEX IF NOT EXISTS idx_relay_run_merges_run ON relay_run_merges(run_id, ordinal);
            INSERT INTO schema_migrations (version, applied_at) VALUES (6, strftime('%s','now'));
            """)
        }
    }

    // MARK: - Workspace Metadata & Lanes

    public func setMeta(key: String, value: String) throws {
        try runBound("INSERT OR REPLACE INTO workspace_meta (key, value) VALUES (?1, ?2);") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, RELAY_SQLITE_TRANSIENT)
        }
    }

    public func getMeta(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM workspace_meta WHERE key = ?1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, RELAY_SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    public func saveLane(_ lane: ManagedWorktreeLane) throws {
        let json = try encodeJSONString(lane)
        try runBound("""
        INSERT OR REPLACE INTO managed_lanes (lane_id, vendor, payload_json, updated_at)
        VALUES (?1, ?2, ?3, ?4);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, lane.id, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, lane.assignedVendor.rawValue, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, json, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        }
    }

    public func allLanes() throws -> [ManagedWorktreeLane] {
        try queryJSONPayloads("SELECT payload_json FROM managed_lanes ORDER BY lane_id ASC;")
    }

    public func saveDAG(_ dag: RelayDAGSpec) throws {
        let json = try encodeJSONString(dag)
        try runBound("""
        INSERT OR REPLACE INTO dag_specs (dag_id, name, payload_json, updated_at)
        VALUES (?1, ?2, ?3, ?4);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, dag.id.uuidString, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, dag.name, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, json, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        }
    }

    public func allDAGs() throws -> [RelayDAGSpec] {
        try queryJSONPayloads("SELECT payload_json FROM dag_specs ORDER BY updated_at DESC;")
    }

    public func saveMergeReport(_ report: ThreeWaySemanticMergeReport) throws {
        let json = try encodeJSONString(report)
        try runBound("""
        INSERT OR REPLACE INTO semantic_merge_reports (relative_path, auto_merged_count, conflict_count, payload_json, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, report.relativePath, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(report.autoMergedCount))
            sqlite3_bind_int(stmt, 3, Int32(report.unresolvedConflictCount))
            sqlite3_bind_text(stmt, 4, json, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        }
    }

    public func allMergeReports() throws -> [ThreeWaySemanticMergeReport] {
        try queryJSONPayloads("SELECT payload_json FROM semantic_merge_reports ORDER BY relative_path ASC;")
    }

    public func appendWiretapSpan(_ span: WiretapAPISpan) throws {
        let json = try encodeJSONString(span)
        let totalTok = span.inputTokens + span.outputTokens + span.reasoningTokens
        try runBound("""
        INSERT OR REPLACE INTO wiretap_spans (span_id, lane_id, vendor, total_tokens, cost_usd, payload_json, recorded_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, span.id.uuidString, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, span.laneID, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, span.vendor.rawValue, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(totalTok))
            sqlite3_bind_double(stmt, 5, span.costUSD)
            sqlite3_bind_text(stmt, 6, json, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 7, span.recordedAt.timeIntervalSince1970)
        }
    }

    public func allWiretapSpans() throws -> [WiretapAPISpan] {
        try queryJSONPayloads("SELECT payload_json FROM wiretap_spans ORDER BY recorded_at ASC;")
    }

    public func replaceGuardrailFindings(_ findings: [RelayGuardrailFinding]) throws {
        try execRaw("DELETE FROM guardrail_findings;")
        for f in findings {
            let json = try encodeJSONString(f)
            try runBound("""
            INSERT INTO guardrail_findings (finding_id, plugin_id, severity, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5);
            """) { stmt in
                sqlite3_bind_text(stmt, 1, f.id.uuidString, -1, RELAY_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, f.pluginID, -1, RELAY_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, f.severity.rawValue, -1, RELAY_SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, json, -1, RELAY_SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 5, f.createdAt.timeIntervalSince1970)
            }
        }
    }

    public func allGuardrailFindings() throws -> [RelayGuardrailFinding] {
        try queryJSONPayloads("SELECT payload_json FROM guardrail_findings ORDER BY created_at DESC;")
    }

    public func verifyIntegrity() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: ptr).lowercased() == "ok"
    }

    public func configuredBusyTimeoutMs() throws -> Int {
        queryInt("PRAGMA busy_timeout;")
    }

    // MARK: - M1 Run & Lane Persistence (Schema v5)

    public func createRun(
        _ run: RelayRunRecord,
        configuredVerifyTimeoutSec: Int? = nil
    ) throws {
        try withLockedHandle { db in
            try Self.execImmediateSQL(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try Self.runPreparedStatement(
                    db,
                    sql: """
                    INSERT INTO relay_runs (
                        run_id, repo_path, plan_copy_path, base_ref, base_commit_oid,
                        verify_command, relay_sh_path, relay_sh_sha256,
                        started_at, finished_at, status, reason, relayide_pid
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
                    """
                ) { stmt in
                    Self.bindText(stmt, 1, run.runID)
                    Self.bindText(stmt, 2, run.repoPath)
                    Self.bindText(stmt, 3, run.planCopyPath)
                    Self.bindText(stmt, 4, run.baseRef)
                    Self.bindText(stmt, 5, run.baseCommitOID)
                    Self.bindOptionalText(stmt, 6, run.verifyCommand)
                    Self.bindText(stmt, 7, run.relayShPath)
                    Self.bindText(stmt, 8, run.relayShSHA256)
                    sqlite3_bind_double(stmt, 9, run.startedAt.timeIntervalSince1970)
                    Self.bindOptionalDate(stmt, 10, run.finishedAt)
                    Self.bindText(stmt, 11, run.status.rawValue)
                    Self.bindOptionalText(stmt, 12, run.reason)
                    sqlite3_bind_int(stmt, 13, run.relayidePID)
                }

                for lane in run.lanes {
                    let afterJSON = try encodeJSONString(lane.after)
                    let uncommittedJSON = try lane.uncommittedFiles.map { try encodeJSONString($0) }
                    try Self.runPreparedStatement(
                        db,
                        sql: """
                        INSERT INTO relay_run_lanes (
                            run_id, lane_id, ordinal, agent, prompt_path, after_json,
                            status, exit_code, signal, reason, started_at, finished_at,
                            pid, cost_usd, tokens, cost_source, branch, commit_oid,
                            worktree_path, uncommitted_files_json
                        ) VALUES (
                            ?1, ?2, ?3, ?4, ?5, ?6,
                            ?7, ?8, ?9, ?10, ?11, ?12,
                            ?13, ?14, ?15, ?16, ?17, ?18,
                            ?19, ?20
                        );
                        """
                    ) { stmt in
                        Self.bindText(stmt, 1, lane.runID)
                        Self.bindText(stmt, 2, lane.laneID)
                        sqlite3_bind_int(stmt, 3, Int32(lane.ordinal))
                        Self.bindText(stmt, 4, lane.agent.rawValue)
                        Self.bindText(stmt, 5, lane.promptPath)
                        Self.bindText(stmt, 6, afterJSON)
                        Self.bindText(stmt, 7, lane.status.rawValue)
                        Self.bindOptionalInt32(stmt, 8, lane.exitCode)
                        Self.bindOptionalInt32(stmt, 9, lane.signal)
                        Self.bindOptionalText(stmt, 10, lane.reason)
                        Self.bindOptionalDate(stmt, 11, lane.startedAt)
                        Self.bindOptionalDate(stmt, 12, lane.finishedAt)
                        Self.bindOptionalInt32(stmt, 13, lane.pid)
                        Self.bindOptionalDouble(stmt, 14, lane.costUSD)
                        Self.bindOptionalInt(stmt, 15, lane.tokens)
                        Self.bindOptionalText(stmt, 16, lane.costSource)
                        Self.bindOptionalText(stmt, 17, lane.branch)
                        Self.bindOptionalText(stmt, 18, lane.commitOID)
                        Self.bindOptionalText(stmt, 19, lane.worktreePath)
                        Self.bindOptionalText(stmt, 20, uncommittedJSON)
                    }
                }

                if let integration = run.integration {
                    try upsertRunIntegrationUnlocked(
                        db: db,
                        runID: run.runID,
                        integration: integration,
                        configuredVerifyCommand: run.verifyCommand,
                        configuredVerifyTimeoutSec: integration.verify?.timeoutSec ?? configuredVerifyTimeoutSec
                    )
                }

                try Self.execImmediateSQL(db, sql: "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    public func updateRunStatus(
        runID: String,
        status: RelayRunStatus,
        reason: String?,
        finishedAt: Date? = nil
    ) throws {
        try runBound("""
        UPDATE relay_runs
        SET status = ?1,
            reason = ?2,
            finished_at = COALESCE(?3, finished_at)
        WHERE run_id = ?4;
        """) { stmt in
            Self.bindText(stmt, 1, status.rawValue)
            Self.bindOptionalText(stmt, 2, reason)
            Self.bindOptionalDate(stmt, 3, finishedAt)
            Self.bindText(stmt, 4, runID)
        }
    }

    public func updateRunLane(_ lane: RelayRunLaneRecord) throws {
        let uncommittedJSON = try lane.uncommittedFiles.map { try encodeJSONString($0) }
        try runBound("""
        UPDATE relay_run_lanes
        SET status = ?1,
            exit_code = ?2,
            signal = ?3,
            reason = ?4,
            started_at = ?5,
            finished_at = ?6,
            pid = ?7,
            cost_usd = ?8,
            tokens = ?9,
            cost_source = ?10,
            branch = ?11,
            commit_oid = ?12,
            worktree_path = ?13,
            uncommitted_files_json = ?14
        WHERE run_id = ?15 AND lane_id = ?16;
        """) { stmt in
            Self.bindText(stmt, 1, lane.status.rawValue)
            Self.bindOptionalInt32(stmt, 2, lane.exitCode)
            Self.bindOptionalInt32(stmt, 3, lane.signal)
            Self.bindOptionalText(stmt, 4, lane.reason)
            Self.bindOptionalDate(stmt, 5, lane.startedAt)
            Self.bindOptionalDate(stmt, 6, lane.finishedAt)
            Self.bindOptionalInt32(stmt, 7, lane.pid)
            Self.bindOptionalDouble(stmt, 8, lane.costUSD)
            Self.bindOptionalInt(stmt, 9, lane.tokens)
            Self.bindOptionalText(stmt, 10, lane.costSource)
            Self.bindOptionalText(stmt, 11, lane.branch)
            Self.bindOptionalText(stmt, 12, lane.commitOID)
            Self.bindOptionalText(stmt, 13, lane.worktreePath)
            Self.bindOptionalText(stmt, 14, uncommittedJSON)
            Self.bindText(stmt, 15, lane.runID)
            Self.bindText(stmt, 16, lane.laneID)
        }
    }

    // MARK: - M2 Integration & Merge Ledger Persistence (Schema v6)

    public func upsertRunIntegration(
        runID: String,
        _ integration: RelayRunIntegrationRecord,
        configuredVerifyCommand: String? = nil,
        configuredVerifyTimeoutSec: Int? = nil
    ) throws {
        try withLockedHandle { db in
            try Self.execImmediateSQL(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try upsertRunIntegrationUnlocked(
                    db: db,
                    runID: runID,
                    integration: integration,
                    configuredVerifyCommand: configuredVerifyCommand,
                    configuredVerifyTimeoutSec: configuredVerifyTimeoutSec
                )
                try Self.execImmediateSQL(db, sql: "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    public func updateRunMerge(runID: String, _ merge: RelayRunMergeRecord) throws {
        let conflictsJSON = try encodeJSONString(merge.conflicts)
        let conflictLinesJSON = try encodeJSONString(merge.conflictLines)
        try runBound("""
        INSERT INTO relay_run_merges (
            run_id, ordinal, lane_id, lane_commit_oid, status, merge_commit_oid,
            conflicts_json, conflict_lines_json, started_at, finished_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(run_id, lane_id) DO UPDATE SET
            ordinal = excluded.ordinal,
            lane_commit_oid = excluded.lane_commit_oid,
            status = excluded.status,
            merge_commit_oid = excluded.merge_commit_oid,
            conflicts_json = excluded.conflicts_json,
            conflict_lines_json = excluded.conflict_lines_json,
            started_at = excluded.started_at,
            finished_at = excluded.finished_at;
        """) { stmt in
            Self.bindText(stmt, 1, runID)
            sqlite3_bind_int(stmt, 2, Int32(merge.ordinal))
            Self.bindText(stmt, 3, merge.laneID)
            Self.bindOptionalText(stmt, 4, merge.laneCommitOID)
            Self.bindText(stmt, 5, merge.status.rawValue)
            Self.bindOptionalText(stmt, 6, merge.mergeCommitOID)
            Self.bindText(stmt, 7, conflictsJSON)
            Self.bindText(stmt, 8, conflictLinesJSON)
            Self.bindOptionalDate(stmt, 9, merge.startedAt)
            Self.bindOptionalDate(stmt, 10, merge.finishedAt)
        }
    }

    public func replaceRunMerges(runID: String, _ merges: [RelayRunMergeRecord]) throws {
        try withLockedHandle { db in
            try Self.execImmediateSQL(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try replaceRunMergesUnlocked(db: db, runID: runID, merges: merges)
                try Self.execImmediateSQL(db, sql: "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    public func configuredIntegrationVerifySpec(runID: String) throws -> (command: String?, timeoutSec: Int?)? {
        try withLockedHandle { db in
            let sql = "SELECT verify_command, verify_timeout_sec FROM relay_run_integration WHERE run_id = ?1;"
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let prepared = stmt else {
                throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(prepared) }
            Self.bindText(prepared, 1, runID)
            guard sqlite3_step(prepared) == SQLITE_ROW else {
                return nil
            }
            return (Self.columnText(prepared, 0), Self.columnOptionalInt(prepared, 1))
        }
    }

    private func upsertRunIntegrationUnlocked(
        db: OpaquePointer,
        runID: String,
        integration: RelayRunIntegrationRecord,
        configuredVerifyCommand: String?,
        configuredVerifyTimeoutSec: Int?
    ) throws {
        let verify = integration.verify
        let modifiedTrackedJSON = try verify.map { try encodeJSONString($0.modifiedTrackedFiles) }
        let effectiveVerifyCommand = verify?.command ?? configuredVerifyCommand
        let effectiveVerifyTimeoutSec = verify?.timeoutSec ?? configuredVerifyTimeoutSec

        try Self.runPreparedStatement(
            db,
            sql: """
            INSERT INTO relay_run_integration (
                run_id, branch, worktree_path, base_commit_oid, head_commit_oid,
                status, reason, ready, verify_command, verify_timeout_sec,
                verify_status, verify_exit_code, verify_signal, verify_pid,
                verify_started_at, verify_finished_at, verify_log_path,
                verify_log_bytes, verify_log_truncated, verify_modified_tracked_files_json
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5,
                ?6, ?7, ?8, ?9, ?10,
                ?11, ?12, ?13, ?14,
                ?15, ?16, ?17,
                ?18, ?19, ?20
            )
            ON CONFLICT(run_id) DO UPDATE SET
                branch = excluded.branch,
                worktree_path = excluded.worktree_path,
                base_commit_oid = excluded.base_commit_oid,
                head_commit_oid = excluded.head_commit_oid,
                status = excluded.status,
                reason = excluded.reason,
                ready = excluded.ready,
                verify_command = COALESCE(excluded.verify_command, relay_run_integration.verify_command),
                verify_timeout_sec = COALESCE(excluded.verify_timeout_sec, relay_run_integration.verify_timeout_sec),
                verify_status = excluded.verify_status,
                verify_exit_code = excluded.verify_exit_code,
                verify_signal = excluded.verify_signal,
                verify_pid = excluded.verify_pid,
                verify_started_at = excluded.verify_started_at,
                verify_finished_at = excluded.verify_finished_at,
                verify_log_path = excluded.verify_log_path,
                verify_log_bytes = excluded.verify_log_bytes,
                verify_log_truncated = excluded.verify_log_truncated,
                verify_modified_tracked_files_json = excluded.verify_modified_tracked_files_json;
            """
        ) { stmt in
            Self.bindText(stmt, 1, runID)
            Self.bindOptionalText(stmt, 2, integration.branch)
            Self.bindOptionalText(stmt, 3, integration.worktreePath)
            Self.bindText(stmt, 4, integration.baseCommitOID)
            Self.bindOptionalText(stmt, 5, integration.headCommitOID)
            Self.bindText(stmt, 6, integration.status.rawValue)
            Self.bindOptionalText(stmt, 7, integration.reason)
            sqlite3_bind_int(stmt, 8, integration.ready ? 1 : 0)
            Self.bindOptionalText(stmt, 9, effectiveVerifyCommand)
            Self.bindOptionalInt(stmt, 10, effectiveVerifyTimeoutSec)
            Self.bindOptionalText(stmt, 11, verify?.status.rawValue)
            Self.bindOptionalInt32(stmt, 12, verify?.exitCode)
            Self.bindOptionalInt32(stmt, 13, verify?.signal)
            Self.bindOptionalInt32(stmt, 14, verify?.pid)
            Self.bindOptionalDate(stmt, 15, verify?.startedAt)
            Self.bindOptionalDate(stmt, 16, verify?.finishedAt)
            Self.bindOptionalText(stmt, 17, verify?.logPath)
            Self.bindOptionalInt(stmt, 18, verify?.logBytes)
            Self.bindOptionalInt32(stmt, 19, verify.map { $0.logTruncated ? 1 : 0 })
            Self.bindOptionalText(stmt, 20, modifiedTrackedJSON)
        }

        try replaceRunMergesUnlocked(db: db, runID: runID, merges: integration.merges)
    }

    private func replaceRunMergesUnlocked(
        db: OpaquePointer,
        runID: String,
        merges: [RelayRunMergeRecord]
    ) throws {
        try Self.runPreparedStatement(db, sql: "DELETE FROM relay_run_merges WHERE run_id = ?1;") { stmt in
            Self.bindText(stmt, 1, runID)
        }
        for merge in merges {
            let conflictsJSON = try encodeJSONString(merge.conflicts)
            let conflictLinesJSON = try encodeJSONString(merge.conflictLines)
            try Self.runPreparedStatement(
                db,
                sql: """
                INSERT INTO relay_run_merges (
                    run_id, ordinal, lane_id, lane_commit_oid, status, merge_commit_oid,
                    conflicts_json, conflict_lines_json, started_at, finished_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
                """
            ) { stmt in
                Self.bindText(stmt, 1, runID)
                sqlite3_bind_int(stmt, 2, Int32(merge.ordinal))
                Self.bindText(stmt, 3, merge.laneID)
                Self.bindOptionalText(stmt, 4, merge.laneCommitOID)
                Self.bindText(stmt, 5, merge.status.rawValue)
                Self.bindOptionalText(stmt, 6, merge.mergeCommitOID)
                Self.bindText(stmt, 7, conflictsJSON)
                Self.bindText(stmt, 8, conflictLinesJSON)
                Self.bindOptionalDate(stmt, 9, merge.startedAt)
                Self.bindOptionalDate(stmt, 10, merge.finishedAt)
            }
        }
    }

    private func fetchIntegrationUnlocked(db: OpaquePointer, runID: String) throws -> RelayRunIntegrationRecord? {
        let sql = """
        SELECT branch, worktree_path, base_commit_oid, head_commit_oid,
               status, reason, ready, verify_command, verify_timeout_sec,
               verify_status, verify_exit_code, verify_signal, verify_pid,
               verify_started_at, verify_finished_at, verify_log_path,
               verify_log_bytes, verify_log_truncated, verify_modified_tracked_files_json
        FROM relay_run_integration
        WHERE run_id = ?1;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        Self.bindText(prepared, 1, runID)
        guard sqlite3_step(prepared) == SQLITE_ROW else {
            return nil
        }

        let status = RelayIntegrationStatus(rawValue: Self.columnText(prepared, 4) ?? "") ?? .interrupted
        let ready = sqlite3_column_int(prepared, 6) != 0
        let verify: RelayRunVerifyRecord?
        if let rawVerifyStatus = Self.columnText(prepared, 9) {
            let vStatus = RelayVerifyStatus(rawValue: rawVerifyStatus) ?? .interrupted
            let modifiedFiles: [String]
            if let rawModified = Self.columnText(prepared, 18) {
                modifiedFiles = (try? decoder.decode([String].self, from: Data(rawModified.utf8))) ?? []
            } else {
                modifiedFiles = []
            }
            verify = RelayRunVerifyRecord(
                command: Self.columnText(prepared, 7) ?? "",
                timeoutSec: Self.columnOptionalInt(prepared, 8) ?? 1800,
                status: vStatus,
                exitCode: Self.columnOptionalInt32(prepared, 10),
                signal: Self.columnOptionalInt32(prepared, 11),
                pid: Self.columnOptionalInt32(prepared, 12),
                startedAt: Self.columnOptionalDate(prepared, 13),
                finishedAt: Self.columnOptionalDate(prepared, 14),
                logPath: Self.columnText(prepared, 15),
                logBytes: Self.columnOptionalInt(prepared, 16) ?? 0,
                logTruncated: (Self.columnOptionalInt32(prepared, 17) ?? 0) != 0,
                modifiedTrackedFiles: modifiedFiles
            )
        } else {
            verify = nil
        }

        let merges = try fetchMergesUnlocked(db: db, runID: runID)
        return RelayRunIntegrationRecord(
            branch: Self.columnText(prepared, 0),
            worktreePath: Self.columnText(prepared, 1),
            baseCommitOID: Self.columnText(prepared, 2) ?? "",
            headCommitOID: Self.columnText(prepared, 3),
            status: status,
            reason: Self.columnText(prepared, 5),
            ready: ready,
            merges: merges,
            verify: verify
        )
    }

    private func fetchMergesUnlocked(db: OpaquePointer, runID: String) throws -> [RelayRunMergeRecord] {
        let sql = """
        SELECT ordinal, lane_id, lane_commit_oid, status, merge_commit_oid,
               conflicts_json, conflict_lines_json, started_at, finished_at
        FROM relay_run_merges
        WHERE run_id = ?1
        ORDER BY ordinal ASC, lane_id ASC;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        Self.bindText(prepared, 1, runID)

        var list: [RelayRunMergeRecord] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let rawConflicts = Self.columnText(prepared, 5) ?? "[]"
            let conflicts = (try? decoder.decode([RelayMergeConflictItem].self, from: Data(rawConflicts.utf8))) ?? []
            let rawConflictLines = Self.columnText(prepared, 6) ?? "[]"
            let conflictLines = (try? decoder.decode([String].self, from: Data(rawConflictLines.utf8))) ?? []
            let status = RelayMergeStepStatus(rawValue: Self.columnText(prepared, 3) ?? "") ?? .notAttempted
            list.append(
                RelayRunMergeRecord(
                    ordinal: Int(sqlite3_column_int(prepared, 0)),
                    laneID: Self.columnText(prepared, 1) ?? "",
                    laneCommitOID: Self.columnText(prepared, 2),
                    status: status,
                    mergeCommitOID: Self.columnText(prepared, 4),
                    conflicts: conflicts,
                    conflictLines: conflictLines,
                    startedAt: Self.columnOptionalDate(prepared, 7),
                    finishedAt: Self.columnOptionalDate(prepared, 8)
                )
            )
        }
        return list
    }

    public func fetchRun(runID: String, reconcileWithLock: Bool = true) throws -> RelayRunRecord? {
        let rawRecord: RelayRunRecord? = try withLockedHandle { db in
            let sql = """
            SELECT run_id, repo_path, plan_copy_path, base_ref, base_commit_oid,
                   verify_command, relay_sh_path, relay_sh_sha256,
                   started_at, finished_at, status, reason, relayide_pid
            FROM relay_runs
            WHERE run_id = ?1;
            """
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let prepared = stmt else {
                throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(prepared) }
            Self.bindText(prepared, 1, runID)
            guard sqlite3_step(prepared) == SQLITE_ROW else {
                return nil
            }
            var run = Self.decodeRunRow(prepared)
            run.lanes = try fetchLanesUnlocked(db: db, runID: run.runID)
            run.integration = try fetchIntegrationUnlocked(db: db, runID: run.runID)
            return run
        }

        guard let record = rawRecord else { return nil }
        guard reconcileWithLock else { return record }
        let activeLock = RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: bundleDirectoryURL)
        return Self.reconcileWithActiveLock(record, activeLock: activeLock)
    }

    public func allRuns(reconcileWithLock: Bool = true) throws -> [RelayRunRecord] {
        let rawRuns: [RelayRunRecord] = try withLockedHandle { db in
            let sql = """
            SELECT run_id, repo_path, plan_copy_path, base_ref, base_commit_oid,
                   verify_command, relay_sh_path, relay_sh_sha256,
                   started_at, finished_at, status, reason, relayide_pid
            FROM relay_runs
            ORDER BY started_at ASC, run_id ASC;
            """
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let prepared = stmt else {
                throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(prepared) }
            var list: [RelayRunRecord] = []
            while sqlite3_step(prepared) == SQLITE_ROW {
                list.append(Self.decodeRunRow(prepared))
            }
            for idx in list.indices {
                list[idx].lanes = try fetchLanesUnlocked(db: db, runID: list[idx].runID)
                list[idx].integration = try fetchIntegrationUnlocked(db: db, runID: list[idx].runID)
            }
            return list
        }

        guard reconcileWithLock else { return rawRuns }
        let activeLock = RelayProjectRunLock.inspectActiveHolder(bundleDirectoryURL: bundleDirectoryURL)
        return rawRuns.map { Self.reconcileWithActiveLock($0, activeLock: activeLock) }
    }

    /// Persists any stale `running` or mid-integration/mid-verify runs (other than `activeRunID`, which currently owns `run.lock`)
    /// as `interrupted` and reconciles their non-terminal lanes, integration, and verify rows.
    public func persistOrphanedRunsAsInterrupted(activeRunID: String) throws {
        let rawRuns = try allRuns(reconcileWithLock: false)
        let now = Date()
        for run in rawRuns where run.runID != activeRunID && Self.needsOrphanReconciliation(run) {
            for var lane in run.lanes where !lane.status.isTerminal {
                if lane.status == .running {
                    lane.status = .interrupted
                    if lane.reason == nil {
                        lane.reason = "interrupted (owner process exited without releasing run)"
                    }
                } else {
                    lane.status = .skipped
                    if lane.reason == nil {
                        lane.reason = "skipped (owner process exited before lane started)"
                    }
                }
                if lane.finishedAt == nil {
                    lane.finishedAt = now
                }
                try updateRunLane(lane)
            }
            if let integration = run.integration {
                let (reconciledInt, didMutateInt) = Self.reconcileOrphanedIntegration(
                    integration,
                    finishedAtIfPersisting: now
                )
                if didMutateInt {
                    try upsertRunIntegration(runID: run.runID, reconciledInt)
                }
            }
            try updateRunStatus(
                runID: run.runID,
                status: .interrupted,
                reason: run.reason ?? "run.lock is no longer held by active RelayIDE process",
                finishedAt: run.finishedAt ?? now
            )
        }
    }

    private func fetchLanesUnlocked(db: OpaquePointer, runID: String) throws -> [RelayRunLaneRecord] {
        let sql = """
        SELECT run_id, lane_id, ordinal, agent, prompt_path, after_json,
               status, exit_code, signal, reason, started_at, finished_at,
               pid, cost_usd, tokens, cost_source, branch, commit_oid,
               worktree_path, uncommitted_files_json
        FROM relay_run_lanes
        WHERE run_id = ?1
        ORDER BY ordinal ASC, lane_id ASC;
        """
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        Self.bindText(prepared, 1, runID)

        var lanes: [RelayRunLaneRecord] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let afterJSON = Self.columnText(prepared, 5) ?? "[]"
            let after = (try? decoder.decode([String].self, from: Data(afterJSON.utf8))) ?? []
            let uncommitted: [String]?
            if let rawUncommitted = Self.columnText(prepared, 19) {
                uncommitted = try? decoder.decode([String].self, from: Data(rawUncommitted.utf8))
            } else {
                uncommitted = nil
            }
            let agent = RelayPlanAgent(rawValue: Self.columnText(prepared, 3) ?? "") ?? .claude
            let status = RelayRunStatus(rawValue: Self.columnText(prepared, 6) ?? "") ?? .interrupted
            lanes.append(
                RelayRunLaneRecord(
                    runID: Self.columnText(prepared, 0) ?? runID,
                    laneID: Self.columnText(prepared, 1) ?? "",
                    ordinal: Int(sqlite3_column_int(prepared, 2)),
                    agent: agent,
                    promptPath: Self.columnText(prepared, 4) ?? "",
                    after: after,
                    status: status,
                    exitCode: Self.columnOptionalInt32(prepared, 7),
                    signal: Self.columnOptionalInt32(prepared, 8),
                    reason: Self.columnText(prepared, 9),
                    startedAt: Self.columnOptionalDate(prepared, 10),
                    finishedAt: Self.columnOptionalDate(prepared, 11),
                    pid: Self.columnOptionalInt32(prepared, 12),
                    costUSD: Self.columnOptionalDouble(prepared, 13),
                    tokens: Self.columnOptionalInt(prepared, 14),
                    costSource: Self.columnText(prepared, 15),
                    branch: Self.columnText(prepared, 16),
                    commitOID: Self.columnText(prepared, 17),
                    worktreePath: Self.columnText(prepared, 18),
                    uncommittedFiles: uncommitted
                )
            )
        }
        return lanes
    }

    private static func decodeRunRow(_ stmt: OpaquePointer) -> RelayRunRecord {
        let status = RelayRunStatus(rawValue: columnText(stmt, 10) ?? "") ?? .interrupted
        return RelayRunRecord(
            runID: columnText(stmt, 0) ?? "",
            repoPath: columnText(stmt, 1) ?? "",
            planCopyPath: columnText(stmt, 2) ?? "",
            baseRef: columnText(stmt, 3) ?? "",
            baseCommitOID: columnText(stmt, 4) ?? "",
            verifyCommand: columnText(stmt, 5),
            relayShPath: columnText(stmt, 6) ?? "",
            relayShSHA256: columnText(stmt, 7) ?? "",
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            finishedAt: columnOptionalDate(stmt, 9),
            status: status,
            reason: columnText(stmt, 11),
            relayidePID: sqlite3_column_int(stmt, 12),
            lanes: []
        )
    }

    private static func needsOrphanReconciliation(_ record: RelayRunRecord) -> Bool {
        if !record.status.isTerminal {
            return true
        }
        if let integration = record.integration {
            if !integration.status.isTerminal {
                return true
            }
            if let verify = integration.verify, !verify.status.isTerminal {
                return true
            }
        }
        return false
    }

    private static func reconcileOrphanedIntegration(
        _ integration: RelayRunIntegrationRecord,
        finishedAtIfPersisting: Date?
    ) -> (reconciled: RelayRunIntegrationRecord, didMutate: Bool) {
        var updated = integration
        var mutated = false

        switch updated.status {
        case .merging:
            updated.status = .interrupted
            updated.ready = false
            if updated.reason == nil {
                updated.reason = "interrupted during merge; integration worktree may be stopped on an unfinished merge"
            }
            mutated = true
        case .verifying:
            updated.status = .interrupted
            updated.ready = false
            if updated.reason == nil {
                updated.reason = "interrupted during verify (owner process exited without releasing run)"
            }
            mutated = true
        case .pending:
            updated.status = .skipped
            updated.ready = false
            if updated.reason == nil {
                updated.reason = "skipped (owner process exited before integration started)"
            }
            mutated = true
        default:
            break
        }

        if var verify = updated.verify, !verify.status.isTerminal {
            verify.status = .interrupted
            if let finishedAt = finishedAtIfPersisting, verify.finishedAt == nil {
                verify.finishedAt = finishedAt
            }
            updated.verify = verify
            updated.ready = false
            mutated = true
        }

        return (updated, mutated)
    }

    private static func reconcileWithActiveLock(
        _ record: RelayRunRecord,
        activeLock: (isHeld: Bool, holder: RelayRunLockHolderInfo?)
    ) -> RelayRunRecord {
        guard needsOrphanReconciliation(record) else {
            return record
        }
        let isOwnedByThisRun: Bool
        if !activeLock.isHeld {
            isOwnedByThisRun = false
        } else if let holder = activeLock.holder {
            isOwnedByThisRun = (holder.runID == record.runID)
        } else {
            isOwnedByThisRun = record.relayidePID > 0
                && (Darwin.kill(record.relayidePID, 0) == 0 || errno == EPERM)
        }
        guard !isOwnedByThisRun else {
            return record
        }

        var reconciled = record
        reconciled.status = .interrupted
        if reconciled.reason == nil {
            reconciled.reason = "run.lock is no longer held by active RelayIDE process"
        }
        for idx in reconciled.lanes.indices where !reconciled.lanes[idx].status.isTerminal {
            if reconciled.lanes[idx].status == .running {
                reconciled.lanes[idx].status = .interrupted
                if reconciled.lanes[idx].reason == nil {
                    reconciled.lanes[idx].reason = "interrupted (owner process exited without releasing run)"
                }
            } else {
                reconciled.lanes[idx].status = .skipped
                if reconciled.lanes[idx].reason == nil {
                    reconciled.lanes[idx].reason = "skipped (owner process exited before lane started)"
                }
            }
        }
        if let integration = reconciled.integration {
            reconciled.integration = reconcileOrphanedIntegration(
                integration,
                finishedAtIfPersisting: nil
            ).reconciled
        }
        return reconciled
    }

    private static func execImmediateSQL(_ db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errMsg)
            throw RelayIDEError.databaseError(code: rc, message: msg)
        }
    }

    private static func runPreparedStatement(
        _ db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer) -> Void
    ) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        bind(prepared)
        let stepRC = sqlite3_step(prepared)
        guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
            throw RelayIDEError.databaseError(code: stepRC, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, RELAY_SQLITE_TRANSIENT)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, RELAY_SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalInt32(_ stmt: OpaquePointer, _ index: Int32, _ value: Int32?) {
        if let value {
            sqlite3_bind_int(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalDate(_ stmt: OpaquePointer, _ index: Int32, _ value: Date?) {
        if let value {
            sqlite3_bind_double(stmt, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func columnText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else {
            return nil
        }
        return String(cString: ptr)
    }

    private static func columnOptionalInt32(_ stmt: OpaquePointer, _ col: Int32) -> Int32? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(stmt, col)
    }

    private static func columnOptionalInt(_ stmt: OpaquePointer, _ col: Int32) -> Int? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, col))
    }

    private static func columnOptionalDouble(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }

    private static func columnOptionalDate(_ stmt: OpaquePointer, _ col: Int32) -> Date? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, col))
    }

    public func computeStats() throws -> RelayWorkspaceStats {
        let name = getMeta(key: "workspace_name") ?? bundleDirectoryURL.deletingPathExtension().lastPathComponent
        let repo = getMeta(key: "repository_path") ?? ""
        let dbBytes = fileSize(at: sqliteFileURL.path)
        let walBytes = fileSize(at: sqliteFileURL.path + "-wal")
        let lanes = queryInt("SELECT COUNT(*) FROM managed_lanes;")
        let dags = try allDAGs()
        let taskCount = dags.reduce(0) { $0 + $1.tasks.count }
        let autoMerges = queryInt("SELECT COALESCE(SUM(auto_merged_count), 0) FROM semantic_merge_reports;")
        let conflicts = queryInt("SELECT COALESCE(SUM(conflict_count), 0) FROM semantic_merge_reports;")
        let tokens = queryInt("SELECT COALESCE(SUM(total_tokens), 0) FROM wiretap_spans;")
        let spend = queryDouble("SELECT COALESCE(SUM(cost_usd), 0.0) FROM wiretap_spans;")
        let findings = queryInt("SELECT COUNT(*) FROM guardrail_findings;")
        let undoCount = queryInt("SELECT COUNT(*) FROM undo_redo_stack WHERE stack_kind = 'undo';")
        let redoCount = queryInt("SELECT COUNT(*) FROM undo_redo_stack WHERE stack_kind = 'redo';")

        return RelayWorkspaceStats(
            workspaceName: name,
            repositoryPath: repo,
            schemaVersion: Self.currentSchemaVersion,
            sqliteBytes: dbBytes,
            walBytes: walBytes,
            activeLaneCount: lanes,
            taskNodeCount: taskCount,
            semanticAutoMergeCount: autoMerges,
            unresolvedConflictCount: conflicts,
            totalTokensObserved: tokens,
            totalSpendUSD: spend,
            guardrailFindingCount: findings,
            undoDepth: undoCount,
            redoDepth: redoCount
        )
    }

    // MARK: - Persistent Undo/Redo Stack Primitives

    internal func pushStackEntry(kind: String, title: String, mutation: RelayUndoMutation) throws {
        let json = try encodeJSONString(mutation)
        try runBound("INSERT INTO undo_redo_stack (stack_kind, title, mutation_json, created_at) VALUES (?1, ?2, ?3, ?4);") { stmt in
            sqlite3_bind_text(stmt, 1, kind, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, title, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, json, -1, RELAY_SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        }
    }

    internal func popStackEntry(kind: String) throws -> (title: String, mutation: RelayUndoMutation)? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        let sql = "SELECT seq, title, mutation_json FROM undo_redo_stack WHERE stack_kind = ?1 ORDER BY seq DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, RELAY_SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let seq = sqlite3_column_int64(stmt, 0)
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let json = String(cString: sqlite3_column_text(stmt, 2))
        let mutation = try decoder.decode(RelayUndoMutation.self, from: Data(json.utf8))

        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM undo_redo_stack WHERE seq = ?1;", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(delStmt, 1, seq)
            _ = sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        return (title, mutation)
    }

    internal func clearRedoStack() throws {
        try execRaw("DELETE FROM undo_redo_stack WHERE stack_kind = 'redo';")
    }

    // MARK: - Low-Level SQLite Helpers

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func queryJSONPayloads<T: Decodable>(_ sql: String) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        var items: [T] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(prepared, 0) {
                let raw = Data(String(cString: ptr).utf8)
                items.append(try decoder.decode(T.self, from: raw))
            }
        }
        return items
    }

    private func execRaw(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errMsg)
            throw RelayIDEError.databaseError(code: rc, message: msg)
        }
    }

    private func runBound(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        bind(prepared)
        let stepRC = sqlite3_step(prepared)
        guard stepRC == SQLITE_DONE || stepRC == SQLITE_ROW else {
            throw RelayIDEError.databaseError(code: stepRC, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func queryInt(_ sql: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func queryDouble(_ sql: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0.0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0.0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : 0.0
    }

    private func fileSize(at path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    internal func withLockedHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else {
            throw RelayIDEError.databaseError(code: SQLITE_MISUSE, message: "SQLite connection handle is closed")
        }
        return try body(db)
    }
}

// MARK: - Persistent Infinite Undo / Redo Controller

public final class RelayUndoRedoController: @unchecked Sendable {
    public let database: RelayProjectDatabase

    public init(database: RelayProjectDatabase) {
        self.database = database
    }

    public func perform(title: String, mutation: RelayUndoMutation) throws {
        try applyMutation(mutation)
        try database.pushStackEntry(kind: "undo", title: title, mutation: mutation)
        try database.clearRedoStack()
    }

    @discardableResult
    public func undo() throws -> String? {
        guard let popped = try database.popStackEntry(kind: "undo") else { return nil }
        try applyMutation(popped.mutation.inverted)
        try database.pushStackEntry(kind: "redo", title: popped.title, mutation: popped.mutation)
        return popped.title
    }

    @discardableResult
    public func redo() throws -> String? {
        guard let popped = try database.popStackEntry(kind: "redo") else { return nil }
        try applyMutation(popped.mutation)
        try database.pushStackEntry(kind: "undo", title: popped.title, mutation: popped.mutation)
        return popped.title
    }

    private func applyMutation(_ mutation: RelayUndoMutation) throws {
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
            var reports = try database.allMergeReports()
            if let rIdx = reports.firstIndex(where: { $0.relativePath == filePath }),
               let cIdx = reports[rIdx].chunks.firstIndex(where: { $0.id == chunkID }) {
                reports[rIdx].chunks[cIdx].resolvedSource = updatedSource
                reports[rIdx].chunks[cIdx].resolution = .leftModifiedOnly
                let nonEmpty = reports[rIdx].chunks.map(\.resolvedSource).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                reports[rIdx].mergedText = nonEmpty.joined(separator: "\n\n") + "\n"
                try database.saveMergeReport(reports[rIdx])
            }
        case .togglePlugin(let pluginID, _, let enabled):
            try database.setMeta(key: "plugin_enabled_\(pluginID)", value: enabled ? "1" : "0")
        }
    }
}
