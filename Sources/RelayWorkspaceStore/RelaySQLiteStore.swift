import Foundation
import RelayModels
import SQLite3

// MARK: - .relayproj SQLite3 WAL Persistence Engine (Schema v1..v4)

private let RELAY_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class RelayProjectDatabase: @unchecked Sendable {
    public static let currentSchemaVersion = 4
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
