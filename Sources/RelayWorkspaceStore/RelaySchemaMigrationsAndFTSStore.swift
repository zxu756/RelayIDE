import CryptoKit
import Foundation
import RelayModels
import SQLite3

private let RELAY_FTS_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Versioned SQLite WAL Schema Migration Catalog (v1 -> v4)

public struct RelaySchemaMigrationDescriptor: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { version }
    public let version: Int
    public let codename: String
    public let summary: String
    public let ddlStatements: [String]
    public let expectedTables: [String]
    public let ddlSHA256Prefix: String

    public init(
        version: Int,
        codename: String,
        summary: String,
        ddlStatements: [String],
        expectedTables: [String]
    ) {
        self.version = version
        self.codename = codename
        self.summary = summary
        self.ddlStatements = ddlStatements
        self.expectedTables = expectedTables
        let joined = ddlStatements.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        self.ddlSHA256Prefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RelayAppliedMigrationRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { version }
    public let version: Int
    public let codename: String
    public let appliedAt: Date
    public let ddlSHA256Prefix: String
    public let allExpectedTablesPresent: Bool

    public init(
        version: Int,
        codename: String,
        appliedAt: Date,
        ddlSHA256Prefix: String,
        allExpectedTablesPresent: Bool
    ) {
        self.version = version
        self.codename = codename
        self.appliedAt = appliedAt
        self.ddlSHA256Prefix = ddlSHA256Prefix
        self.allExpectedTablesPresent = allExpectedTablesPresent
    }
}

public enum RelaySchemaMigrationCatalog {
    public static let v1CoreWorkspaceAndDAG = RelaySchemaMigrationDescriptor(
        version: 1,
        codename: "v1_core_lanes_and_dag",
        summary: "Initializes workspace_meta, isolated Git worktree managed_lanes, and topological dag_specs.",
        ddlStatements: [
            """
            CREATE TABLE IF NOT EXISTS workspace_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS managed_lanes (
                lane_id TEXT PRIMARY KEY,
                vendor TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS dag_specs (
                dag_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        ],
        expectedTables: ["workspace_meta", "managed_lanes", "dag_specs"]
    )

    public static let v2SemanticMergeLedger = RelaySchemaMigrationDescriptor(
        version: 2,
        codename: "v2_semantic_ast_merge_ledger",
        summary: "Adds declaration-level 3-Way Semantic AST merge reports and conflict resolution counts.",
        ddlStatements: [
            """
            CREATE TABLE IF NOT EXISTS semantic_merge_reports (
                relative_path TEXT PRIMARY KEY,
                auto_merged_count INTEGER NOT NULL,
                conflict_count INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        ],
        expectedTables: ["semantic_merge_reports"]
    )

    public static let v3WiretapAndGuardrails = RelaySchemaMigrationDescriptor(
        version: 3,
        codename: "v3_wiretap_spans_and_guardrails",
        summary: "Adds indexed wiretap_spans token/USD telemetry ledger and JavaScriptCore guardrail_findings.",
        ddlStatements: [
            """
            CREATE TABLE IF NOT EXISTS wiretap_spans (
                span_id TEXT PRIMARY KEY,
                lane_id TEXT NOT NULL,
                vendor TEXT NOT NULL,
                total_tokens INTEGER NOT NULL,
                cost_usd REAL NOT NULL,
                payload_json TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_wiretap_lane ON wiretap_spans(lane_id);",
            """
            CREATE TABLE IF NOT EXISTS guardrail_findings (
                finding_id TEXT PRIMARY KEY,
                plugin_id TEXT NOT NULL,
                severity TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """
        ],
        expectedTables: ["wiretap_spans", "guardrail_findings"]
    )

    public static let v4UndoJournalAndFTS5Index = RelaySchemaMigrationDescriptor(
        version: 4,
        codename: "v4_undo_journal_and_fts5_bm25",
        summary: "Adds persistent undo_redo_stack, crash-safe checkpoint journal, and FTS5 BM25 multi-agent search.",
        ddlStatements: [
            """
            CREATE TABLE IF NOT EXISTS undo_redo_stack (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                stack_kind TEXT NOT NULL,
                title TEXT NOT NULL,
                mutation_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS relay_fts5_doc_meta (
                doc_id TEXT PRIMARY KEY,
                corpus TEXT NOT NULL,
                lane_id TEXT NOT NULL,
                vendor TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                title TEXT NOT NULL,
                body_text TEXT NOT NULL,
                tags TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_fts_meta_corpus ON relay_fts5_doc_meta(corpus, lane_id);",
            """
            CREATE TABLE IF NOT EXISTS wal_checkpoint_history (
                checkpoint_seq INTEGER PRIMARY KEY AUTOINCREMENT,
                mode TEXT NOT NULL,
                log_frames INTEGER NOT NULL,
                checkpointed_frames INTEGER NOT NULL,
                wal_bytes_before INTEGER NOT NULL,
                wal_bytes_after INTEGER NOT NULL,
                elapsed_ms REAL NOT NULL,
                executed_at REAL NOT NULL
            );
            """
        ],
        expectedTables: ["undo_redo_stack", "relay_fts5_doc_meta", "wal_checkpoint_history"]
    )

    public static let v5RelayRunsAndRunLanes = RelaySchemaMigrationDescriptor(
        version: 5,
        codename: "v5_relay_runs_and_run_lanes",
        summary: "Adds relay_runs and relay_run_lanes ledgers for M1 headless agent-relay execution and crash reconciliation.",
        ddlStatements: [
            """
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
            """,
            """
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
            """,
            "CREATE INDEX IF NOT EXISTS idx_relay_run_lanes_run ON relay_run_lanes(run_id, ordinal);"
        ],
        expectedTables: ["relay_runs", "relay_run_lanes"]
    )

    public static let allMigrations: [RelaySchemaMigrationDescriptor] = [
        v1CoreWorkspaceAndDAG,
        v2SemanticMergeLedger,
        v3WiretapAndGuardrails,
        v4UndoJournalAndFTS5Index,
        v5RelayRunsAndRunLanes
    ]

    public static func descriptor(forVersion version: Int) -> RelaySchemaMigrationDescriptor? {
        allMigrations.first { $0.version == version }
    }
}

// MARK: - SQLite FTS5 BM25 Multi-Agent Full-Text Search Models

public enum FTSDocumentCorpus: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case terminalTranscript = "terminal_transcript"
    case taskPromptBrief = "task_prompt"
    case handoffLog = "handoff_log"
    case mergeHistory = "merge_history"
    case guardrailAudit = "guardrail_audit"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .terminalTranscript: return "PTY Terminal Transcript"
        case .taskPromptBrief: return "Task Prompt Brief"
        case .handoffLog: return "Agent Handoff Artifact"
        case .mergeHistory: return "3-Way AST Merge History"
        case .guardrailAudit: return "Guardrail Audit Finding"
        }
    }
}

public struct FTSIndexedDocument: Sendable, Codable, Hashable, Identifiable {
    public var id: String { docID }
    public let docID: String
    public let corpus: FTSDocumentCorpus
    public let laneID: String
    public let vendor: AgentVendor
    public let relativePath: String
    public let title: String
    public let bodyText: String
    public let tags: [String]
    public let recordedAt: Date

    public init(
        docID: String,
        corpus: FTSDocumentCorpus,
        laneID: String,
        vendor: AgentVendor,
        relativePath: String = "",
        title: String,
        bodyText: String,
        tags: [String] = [],
        recordedAt: Date = Date()
    ) {
        self.docID = docID
        self.corpus = corpus
        self.laneID = laneID
        self.vendor = vendor
        self.relativePath = relativePath
        self.title = title
        self.bodyText = bodyText
        self.tags = tags
        self.recordedAt = recordedAt
    }
}

public struct FTSQueryOptions: Sendable, Codable, Hashable {
    public var allowedCorpora: Set<FTSDocumentCorpus>?
    public var laneIDFilter: String?
    public var vendorFilter: AgentVendor?
    public var sinceDate: Date?
    public var limit: Int
    public var highlightOpenMarker: String
    public var highlightCloseMarker: String

    public init(
        allowedCorpora: Set<FTSDocumentCorpus>? = nil,
        laneIDFilter: String? = nil,
        vendorFilter: AgentVendor? = nil,
        sinceDate: Date? = nil,
        limit: Int = 40,
        highlightOpenMarker: String = "«",
        highlightCloseMarker: String = "»"
    ) {
        self.allowedCorpora = allowedCorpora
        self.laneIDFilter = laneIDFilter
        self.vendorFilter = vendorFilter
        self.sinceDate = sinceDate
        self.limit = max(1, min(500, limit))
        self.highlightOpenMarker = highlightOpenMarker
        self.highlightCloseMarker = highlightCloseMarker
    }
}

public struct FTSSearchHit: Sendable, Codable, Hashable, Identifiable {
    public var id: String { docID }
    public let docID: String
    public let corpus: FTSDocumentCorpus
    public let laneID: String
    public let vendor: AgentVendor
    public let relativePath: String
    public let title: String
    public let highlightedSnippet: String
    public let relevanceScore: Double
    public let usedNativeSQLiteFTS5: Bool
    public let recordedAt: Date

    public init(
        docID: String,
        corpus: FTSDocumentCorpus,
        laneID: String,
        vendor: AgentVendor,
        relativePath: String,
        title: String,
        highlightedSnippet: String,
        relevanceScore: Double,
        usedNativeSQLiteFTS5: Bool,
        recordedAt: Date
    ) {
        self.docID = docID
        self.corpus = corpus
        self.laneID = laneID
        self.vendor = vendor
        self.relativePath = relativePath
        self.title = title
        self.highlightedSnippet = highlightedSnippet
        self.relevanceScore = relevanceScore
        self.usedNativeSQLiteFTS5 = usedNativeSQLiteFTS5
        self.recordedAt = recordedAt
    }
}

public struct FTSCorpusFacetCount: Sendable, Codable, Hashable, Identifiable {
    public var id: String { corpus.rawValue }
    public let corpus: FTSDocumentCorpus
    public let documentCount: Int
    public let totalUTF8Bytes: Int64

    public init(corpus: FTSDocumentCorpus, documentCount: Int, totalUTF8Bytes: Int64) {
        self.corpus = corpus
        self.documentCount = documentCount
        self.totalUTF8Bytes = totalUTF8Bytes
    }
}

// MARK: - SQLite Integrity, WAL Checkpoint & Storage Telemetry Models

public enum SQLiteWALCheckpointMode: String, Sendable, Codable, Hashable, CaseIterable {
    case passive = "PASSIVE"
    case full = "FULL"
    case restart = "RESTART"
    case truncate = "TRUNCATE"

    internal var sqliteModeConstant: Int32 {
        switch self {
        case .passive: return SQLITE_CHECKPOINT_PASSIVE
        case .full: return SQLITE_CHECKPOINT_FULL
        case .restart: return SQLITE_CHECKPOINT_RESTART
        case .truncate: return SQLITE_CHECKPOINT_TRUNCATE
        }
    }
}

public struct SQLiteWALCheckpointReport: Sendable, Codable, Hashable {
    public let mode: SQLiteWALCheckpointMode
    public let totalLogFrames: Int
    public let checkpointedFrames: Int
    public let walBytesBefore: Int64
    public let walBytesAfter: Int64
    public let reclaimedBytes: Int64
    public let elapsedMs: Double
    public let executedAt: Date

    public init(
        mode: SQLiteWALCheckpointMode,
        totalLogFrames: Int,
        checkpointedFrames: Int,
        walBytesBefore: Int64,
        walBytesAfter: Int64,
        elapsedMs: Double,
        executedAt: Date = Date()
    ) {
        self.mode = mode
        self.totalLogFrames = totalLogFrames
        self.checkpointedFrames = checkpointedFrames
        self.walBytesBefore = walBytesBefore
        self.walBytesAfter = walBytesAfter
        self.reclaimedBytes = max(0, walBytesBefore - walBytesAfter)
        self.elapsedMs = elapsedMs
        self.executedAt = executedAt
    }
}

public struct SQLiteIntegrityAuditReport: Sendable, Codable, Hashable {
    public let isHealthy: Bool
    public let integrityMessages: [String]
    public let foreignKeyViolations: Int
    public let journalMode: String
    public let pageSizeBytes: Int
    public let totalPageCount: Int
    public let freelistPageCount: Int
    public let fragmentationRatio: Double
    public let fts5Available: Bool
    public let auditedAt: Date

    public init(
        isHealthy: Bool,
        integrityMessages: [String],
        foreignKeyViolations: Int,
        journalMode: String,
        pageSizeBytes: Int,
        totalPageCount: Int,
        freelistPageCount: Int,
        fts5Available: Bool,
        auditedAt: Date = Date()
    ) {
        self.isHealthy = isHealthy
        self.integrityMessages = integrityMessages
        self.foreignKeyViolations = foreignKeyViolations
        self.journalMode = journalMode
        self.pageSizeBytes = pageSizeBytes
        self.totalPageCount = totalPageCount
        self.freelistPageCount = freelistPageCount
        self.fragmentationRatio = totalPageCount > 0 ? Double(freelistPageCount) / Double(totalPageCount) : 0.0
        self.fts5Available = fts5Available
        self.auditedAt = auditedAt
    }
}

public struct SQLiteTableTelemetryRow: Sendable, Codable, Hashable, Identifiable {
    public var id: String { tableName }
    public let tableName: String
    public let rowCount: Int
    public let payloadBytes: Int64

    public init(tableName: String, rowCount: Int, payloadBytes: Int64) {
        self.tableName = tableName
        self.rowCount = rowCount
        self.payloadBytes = payloadBytes
    }
}

public struct WorkspaceStorageTelemetryReport: Sendable, Codable, Hashable {
    public let schemaVersion: Int
    public let sqliteFileBytes: Int64
    public let walFileBytes: Int64
    public let shmFileBytes: Int64
    public let totalFootprintBytes: Int64
    public let tables: [SQLiteTableTelemetryRow]
    public let ftsCorpusFacets: [FTSCorpusFacetCount]
    public let integritySummary: SQLiteIntegrityAuditReport
    public let recommendsVacuum: Bool

    public init(
        schemaVersion: Int,
        sqliteFileBytes: Int64,
        walFileBytes: Int64,
        shmFileBytes: Int64,
        tables: [SQLiteTableTelemetryRow],
        ftsCorpusFacets: [FTSCorpusFacetCount],
        integritySummary: SQLiteIntegrityAuditReport
    ) {
        self.schemaVersion = schemaVersion
        self.sqliteFileBytes = sqliteFileBytes
        self.walFileBytes = walFileBytes
        self.shmFileBytes = shmFileBytes
        self.totalFootprintBytes = sqliteFileBytes + walFileBytes + shmFileBytes
        self.tables = tables
        self.ftsCorpusFacets = ftsCorpusFacets
        self.integritySummary = integritySummary
        self.recommendsVacuum = integritySummary.fragmentationRatio >= 0.25 && sqliteFileBytes >= 524_288
    }
}

// MARK: - SQLite FTS5 BM25 Search Engine & ANSI Sanitizer

public final class RelayFTS5SearchStore: @unchecked Sendable {
    public let database: RelayProjectDatabase
    private var fts5Ready: Bool = false
    private let initLock = NSLock()
    private var didBootstrapTables: Bool = false

    public init(database: RelayProjectDatabase) {
        self.database = database
        try? ensureExtensionTables()
    }

    public var isNativeFTS5Enabled: Bool {
        initLock.lock()
        defer { initLock.unlock() }
        return fts5Ready
    }

    public func ensureExtensionTables() throws {
        initLock.lock()
        if didBootstrapTables {
            initLock.unlock()
            return
        }
        initLock.unlock()

        var createdFTS5 = false
        try database.withLockedHandle { db in
            try Self.execSQL(db, sql: """
            CREATE TABLE IF NOT EXISTS relay_fts5_doc_meta (
                doc_id TEXT PRIMARY KEY,
                corpus TEXT NOT NULL,
                lane_id TEXT NOT NULL,
                vendor TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                title TEXT NOT NULL,
                body_text TEXT NOT NULL,
                tags TEXT NOT NULL,
                recorded_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_fts_meta_corpus ON relay_fts5_doc_meta(corpus, lane_id);
            CREATE TABLE IF NOT EXISTS wal_checkpoint_history (
                checkpoint_seq INTEGER PRIMARY KEY AUTOINCREMENT,
                mode TEXT NOT NULL,
                log_frames INTEGER NOT NULL,
                checkpointed_frames INTEGER NOT NULL,
                wal_bytes_before INTEGER NOT NULL,
                wal_bytes_after INTEGER NOT NULL,
                elapsed_ms REAL NOT NULL,
                executed_at REAL NOT NULL
            );
            """)

            let ftsDDL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS relay_fts5_index USING fts5(
                doc_id UNINDEXED,
                corpus,
                lane_id,
                vendor,
                relative_path,
                title,
                body_text,
                tags,
                tokenize = 'porter unicode61'
            );
            """
            if sqlite3_exec(db, ftsDDL, nil, nil, nil) == SQLITE_OK {
                createdFTS5 = true
            }
        }

        initLock.lock()
        self.fts5Ready = createdFTS5
        self.didBootstrapTables = true
        initLock.unlock()
    }

    /// Indexes or updates a single searchable workspace artifact in both metadata and FTS5 BM25 virtual tables.
    public func indexDocument(_ doc: FTSIndexedDocument) throws {
        try ensureExtensionTables()
        let useFTS = isNativeFTS5Enabled
        let cleanBody = Self.stripVT100EscapeSequences(doc.bodyText)
        let tagsJoined = doc.tags.joined(separator: " ")

        try database.withLockedHandle { db in
            try Self.execSQL(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try Self.runPrepared(
                    db,
                    sql: """
                    INSERT OR REPLACE INTO relay_fts5_doc_meta
                    (doc_id, corpus, lane_id, vendor, relative_path, title, body_text, tags, recorded_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                    """
                ) { stmt in
                    sqlite3_bind_text(stmt, 1, doc.docID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, doc.corpus.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, doc.laneID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, doc.vendor.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 5, doc.relativePath, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 6, doc.title, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 7, cleanBody, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 8, tagsJoined, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 9, doc.recordedAt.timeIntervalSince1970)
                }

                if useFTS {
                    try Self.runPrepared(db, sql: "DELETE FROM relay_fts5_index WHERE doc_id = ?1;") { stmt in
                        sqlite3_bind_text(stmt, 1, doc.docID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    }
                    try Self.runPrepared(
                        db,
                        sql: """
                        INSERT INTO relay_fts5_index
                        (doc_id, corpus, lane_id, vendor, relative_path, title, body_text, tags)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                        """
                    ) { stmt in
                        sqlite3_bind_text(stmt, 1, doc.docID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 2, doc.corpus.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 3, doc.laneID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 4, doc.vendor.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 5, doc.relativePath, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 6, doc.title, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 7, cleanBody, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 8, tagsJoined, -1, RELAY_FTS_SQLITE_TRANSIENT)
                    }
                }
                try Self.execSQL(db, sql: "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    /// Batch-indexes a collection of multi-agent documents inside a single atomic WAL transaction.
    public func indexBatch(_ documents: [FTSIndexedDocument]) throws {
        guard !documents.isEmpty else { return }
        try ensureExtensionTables()
        let useFTS = isNativeFTS5Enabled

        try database.withLockedHandle { db in
            try Self.execSQL(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                for doc in documents {
                    let cleanBody = Self.stripVT100EscapeSequences(doc.bodyText)
                    let tagsJoined = doc.tags.joined(separator: " ")

                    try Self.runPrepared(
                        db,
                        sql: """
                        INSERT OR REPLACE INTO relay_fts5_doc_meta
                        (doc_id, corpus, lane_id, vendor, relative_path, title, body_text, tags, recorded_at)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                        """
                    ) { stmt in
                        sqlite3_bind_text(stmt, 1, doc.docID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 2, doc.corpus.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 3, doc.laneID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 4, doc.vendor.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 5, doc.relativePath, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 6, doc.title, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 7, cleanBody, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_text(stmt, 8, tagsJoined, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        sqlite3_bind_double(stmt, 9, doc.recordedAt.timeIntervalSince1970)
                    }

                    if useFTS {
                        try Self.runPrepared(db, sql: "DELETE FROM relay_fts5_index WHERE doc_id = ?1;") { stmt in
                            sqlite3_bind_text(stmt, 1, doc.docID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        }
                        try Self.runPrepared(
                            db,
                            sql: """
                            INSERT INTO relay_fts5_index
                            (doc_id, corpus, lane_id, vendor, relative_path, title, body_text, tags)
                            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                            """
                        ) { stmt in
                            sqlite3_bind_text(stmt, 1, doc.docID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 2, doc.corpus.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 3, doc.laneID, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 4, doc.vendor.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 5, doc.relativePath, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 6, doc.title, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 7, cleanBody, -1, RELAY_FTS_SQLITE_TRANSIENT)
                            sqlite3_bind_text(stmt, 8, tagsJoined, -1, RELAY_FTS_SQLITE_TRANSIENT)
                        }
                    }
                }
                try Self.execSQL(db, sql: "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    /// Convenience helper for indexing ANSI/VT100 terminal transcripts emitted by an agent lane.
    public func indexTerminalTranscript(
        laneID: String,
        vendor: AgentVendor,
        rawTranscript: String,
        windowTitle: String = "",
        recordedAt: Date = Date()
    ) throws {
        let doc = FTSIndexedDocument(
            docID: "pty:\(laneID)",
            corpus: .terminalTranscript,
            laneID: laneID,
            vendor: vendor,
            relativePath: ".worktrees/\(laneID)",
            title: windowTitle.isEmpty ? "\(vendor.displayName) PTY (\(laneID))" : windowTitle,
            bodyText: rawTranscript,
            tags: ["pty", "terminal", vendor.rawValue, laneID],
            recordedAt: recordedAt
        )
        try indexDocument(doc)
    }

    /// Synchronizes all persisted DAG tasks, handoffs, 3-Way AST merge reports, and guardrail findings into the FTS5 index.
    @discardableResult
    public func synchronizeFromPersistedWorkspace() throws -> Int {
        let dags = try database.allDAGs()
        let merges = try database.allMergeReports()
        let findings = try database.allGuardrailFindings()
        var docs: [FTSIndexedDocument] = []

        for dag in dags {
            for task in dag.tasks {
                docs.append(
                    FTSIndexedDocument(
                        docID: "prompt:\(dag.id.uuidString):\(task.id)",
                        corpus: .taskPromptBrief,
                        laneID: task.laneID,
                        vendor: task.vendor,
                        relativePath: task.allowedWriteGlobs.first ?? "",
                        title: "\(task.title) (\(task.id))",
                        bodyText: task.promptBrief + "\n" + (task.verificationShellCommand ?? ""),
                        tags: [task.status.rawValue, task.vendor.rawValue] + task.outputHandoffFiles,
                        recordedAt: task.startedAt ?? dag.createdAt
                    )
                )
                if let handoff = task.handoffSummary, !handoff.isEmpty {
                    docs.append(
                        FTSIndexedDocument(
                            docID: "handoff:\(dag.id.uuidString):\(task.id)",
                            corpus: .handoffLog,
                            laneID: task.laneID,
                            vendor: task.vendor,
                            relativePath: task.outputHandoffFiles.first ?? ".relay/handoff.md",
                            title: "Handoff · \(task.title)",
                            bodyText: handoff,
                            tags: task.inputHandoffFiles + task.outputHandoffFiles,
                            recordedAt: task.finishedAt ?? dag.createdAt
                        )
                    )
                }
            }
        }

        for report in merges {
            let chunkSummaries = report.chunks.map { chunk in
                "[\(chunk.resolution.rawValue)] \(chunk.symbolName): \(chunk.explanation)\n\(chunk.resolvedSource)"
            }.joined(separator: "\n\n")
            docs.append(
                FTSIndexedDocument(
                    docID: "merge:\(report.relativePath)",
                    corpus: .mergeHistory,
                    laneID: "\(report.leftLaneID)+\(report.rightLaneID)",
                    vendor: report.chunks.first?.leftVendor ?? .claudeCode,
                    relativePath: report.relativePath,
                    title: "3-Way AST Merge · \(report.relativePath)",
                    bodyText: chunkSummaries,
                    tags: [report.language.rawValue, report.isCleanlyMerged ? "clean" : "conflict"]
                )
            )
        }

        for finding in findings {
            docs.append(
                FTSIndexedDocument(
                    docID: "guardrail:\(finding.id.uuidString)",
                    corpus: .guardrailAudit,
                    laneID: finding.laneID ?? "workspace",
                    vendor: .customShell,
                    relativePath: finding.relativePath ?? "",
                    title: "[\(finding.severity.rawValue)] \(finding.title)",
                    bodyText: "\(finding.pluginName): \(finding.detail)",
                    tags: [finding.pluginID, finding.severity.rawValue],
                    recordedAt: finding.createdAt
                )
            )
        }

        try indexBatch(docs)
        return docs.count
    }

    /// Executes BM25-ranked full-text search across terminal transcripts, prompts, handoff logs, and merge history.
    public func search(_ rawQuery: String, options: FTSQueryOptions = FTSQueryOptions()) throws -> [FTSSearchHit] {
        try ensureExtensionTables()
        let parsed = Self.compileUserSearchQuery(rawQuery, baseOptions: options)
        guard !parsed.ftsMatchExpression.isEmpty else { return [] }

        if isNativeFTS5Enabled {
            if let hits = try? executeNativeFTS5Query(parsed: parsed, options: parsed.effectiveOptions) {
                return hits
            }
        }
        return try executePureSwiftBM25Fallback(terms: parsed.plainTokens, options: parsed.effectiveOptions)
    }

    public func corpusFacets() throws -> [FTSCorpusFacetCount] {
        try ensureExtensionTables()
        return try database.withLockedHandle { db in
            let sql = """
            SELECT corpus, COUNT(*), COALESCE(SUM(LENGTH(CAST(body_text AS BLOB))), 0)
            FROM relay_fts5_doc_meta
            GROUP BY corpus
            ORDER BY corpus ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
                return []
            }
            defer { sqlite3_finalize(prepared) }
            var rows: [FTSCorpusFacetCount] = []
            while sqlite3_step(prepared) == SQLITE_ROW {
                guard let cPtr = sqlite3_column_text(prepared, 0),
                      let corpus = FTSDocumentCorpus(rawValue: String(cString: cPtr)) else { continue }
                let count = Int(sqlite3_column_int64(prepared, 1))
                let bytes = sqlite3_column_int64(prepared, 2)
                rows.append(FTSCorpusFacetCount(corpus: corpus, documentCount: count, totalUTF8Bytes: bytes))
            }
            return rows
        }
    }

    // MARK: - Native SQLite FTS5 BM25 & Pure-Swift BM25 Fallback

    private struct CompiledQuery {
        let ftsMatchExpression: String
        let plainTokens: [String]
        let effectiveOptions: FTSQueryOptions
    }

    private func executeNativeFTS5Query(parsed: CompiledQuery, options: FTSQueryOptions) throws -> [FTSSearchHit] {
        try database.withLockedHandle { db in
            let sql = """
            SELECT
                m.doc_id,
                m.corpus,
                m.lane_id,
                m.vendor,
                m.relative_path,
                m.title,
                snippet(relay_fts5_index, 6, ?2, ?3, ' … ', 26) AS snip,
                (-1.0 * bm25(relay_fts5_index, 0.0, 1.0, 1.0, 0.8, 2.0, 3.2, 1.5, 1.8)) AS rank_score,
                m.recorded_at
            FROM relay_fts5_index
            JOIN relay_fts5_doc_meta m ON m.doc_id = relay_fts5_index.doc_id
            WHERE relay_fts5_index MATCH ?1
            ORDER BY rank_score DESC, m.recorded_at DESC
            LIMIT ?4;
            """
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let prepared = stmt else {
                throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(prepared) }

            sqlite3_bind_text(prepared, 1, parsed.ftsMatchExpression, -1, RELAY_FTS_SQLITE_TRANSIENT)
            sqlite3_bind_text(prepared, 2, options.highlightOpenMarker, -1, RELAY_FTS_SQLITE_TRANSIENT)
            sqlite3_bind_text(prepared, 3, options.highlightCloseMarker, -1, RELAY_FTS_SQLITE_TRANSIENT)
            sqlite3_bind_int(prepared, 4, Int32(options.limit * 3))

            var hits: [FTSSearchHit] = []
            while sqlite3_step(prepared) == SQLITE_ROW {
                let docID = Self.colString(prepared, 0)
                guard let corpus = FTSDocumentCorpus(rawValue: Self.colString(prepared, 1)) else { continue }
                let laneID = Self.colString(prepared, 2)
                let vendor = AgentVendor(rawValue: Self.colString(prepared, 3)) ?? .customShell
                let relPath = Self.colString(prepared, 4)
                let title = Self.colString(prepared, 5)
                let snippet = Self.colString(prepared, 6)
                let score = max(0.0001, sqlite3_column_double(prepared, 7))
                let recorded = Date(timeIntervalSince1970: sqlite3_column_double(prepared, 8))

                if !Self.passesPostFilters(corpus: corpus, laneID: laneID, vendor: vendor, recordedAt: recorded, options: options) {
                    continue
                }
                hits.append(
                    FTSSearchHit(
                        docID: docID,
                        corpus: corpus,
                        laneID: laneID,
                        vendor: vendor,
                        relativePath: relPath,
                        title: title,
                        highlightedSnippet: snippet,
                        relevanceScore: score,
                        usedNativeSQLiteFTS5: true,
                        recordedAt: recorded
                    )
                )
                if hits.count >= options.limit {
                    break
                }
            }
            return hits
        }
    }

    private func executePureSwiftBM25Fallback(terms: [String], options: FTSQueryOptions) throws -> [FTSSearchHit] {
        guard !terms.isEmpty else { return [] }
        let lowerTerms = terms.map { $0.lowercased() }

        let allDocs: [FTSIndexedDocument] = try database.withLockedHandle { db in
            let sql = "SELECT doc_id, corpus, lane_id, vendor, relative_path, title, body_text, tags, recorded_at FROM relay_fts5_doc_meta;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else { return [] }
            defer { sqlite3_finalize(prepared) }
            var list: [FTSIndexedDocument] = []
            while sqlite3_step(prepared) == SQLITE_ROW {
                guard let corpus = FTSDocumentCorpus(rawValue: Self.colString(prepared, 1)) else { continue }
                let lane = Self.colString(prepared, 2)
                let vendor = AgentVendor(rawValue: Self.colString(prepared, 3)) ?? .customShell
                let rec = Date(timeIntervalSince1970: sqlite3_column_double(prepared, 8))
                if !Self.passesPostFilters(corpus: corpus, laneID: lane, vendor: vendor, recordedAt: rec, options: options) {
                    continue
                }
                list.append(
                    FTSIndexedDocument(
                        docID: Self.colString(prepared, 0),
                        corpus: corpus,
                        laneID: lane,
                        vendor: vendor,
                        relativePath: Self.colString(prepared, 4),
                        title: Self.colString(prepared, 5),
                        bodyText: Self.colString(prepared, 6),
                        tags: Self.colString(prepared, 7).split(separator: " ").map(String.init),
                        recordedAt: rec
                    )
                )
            }
            return list
        }

        guard !allDocs.isEmpty else { return [] }
        let tokenizedDocs = allDocs.map { doc -> [String] in
            Self.tokenizeWords("\(doc.title) \(doc.title) \(doc.relativePath) \(doc.bodyText) \(doc.tags.joined(separator: " "))")
        }
        let avgDocLen = max(1.0, Double(tokenizedDocs.reduce(0) { $0 + $1.count }) / Double(tokenizedDocs.count))
        let totalN = Double(allDocs.count)
        let k1 = 1.2
        let b = 0.75

        var docFreq: [String: Int] = [:]
        for term in lowerTerms {
            var df = 0
            for words in tokenizedDocs where words.contains(where: { $0.hasPrefix(term) }) {
                df += 1
            }
            docFreq[term] = df
        }

        var scored: [(Int, Double)] = []
        for (idx, words) in tokenizedDocs.enumerated() {
            var score = 0.0
            let docLen = Double(words.count)
            for term in lowerTerms {
                let tf = Double(words.filter { $0.hasPrefix(term) }.count)
                guard tf > 0 else { continue }
                let df = Double(docFreq[term] ?? 1)
                let idf = Foundation.log(1.0 + (totalN - df + 0.5) / (df + 0.5))
                let denom = tf + k1 * (1.0 - b + b * (docLen / avgDocLen))
                score += idf * ((tf * (k1 + 1.0)) / max(1e-6, denom))
            }
            if score > 0 {
                scored.append((idx, score))
            }
        }

        scored.sort { $0.1 > $1.1 }
        return scored.prefix(options.limit).map { idx, score in
            let doc = allDocs[idx]
            let snip = Self.buildHighlightedExcerpt(
                in: doc.bodyText,
                terms: lowerTerms,
                openMark: options.highlightOpenMarker,
                closeMark: options.highlightCloseMarker
            )
            return FTSSearchHit(
                docID: doc.docID,
                corpus: doc.corpus,
                laneID: doc.laneID,
                vendor: doc.vendor,
                relativePath: doc.relativePath,
                title: doc.title,
                highlightedSnippet: snip,
                relevanceScore: score,
                usedNativeSQLiteFTS5: false,
                recordedAt: doc.recordedAt
            )
        }
    }

    // MARK: - Query Compilation & Text Utilities

    public static func stripVT100EscapeSequences(_ raw: String) -> String {
        guard raw.contains("\u{1B}") else { return raw.replacingOccurrences(of: "\r\n", with: "\n") }
        // Remove OSC (\e]...\a or \e]...\e\\) and CSI (\e[...[@-~]) escape codes
        var cleaned = raw
        if let oscRegex = try? NSRegularExpression(pattern: "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)", options: []) {
            cleaned = oscRegex.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length), withTemplate: "")
        }
        if let csiRegex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;?]*[ -/]*[@-~]", options: []) {
            cleaned = csiRegex.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length), withTemplate: "")
        }
        return cleaned.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func compileUserSearchQuery(_ raw: String, baseOptions: FTSQueryOptions) -> CompiledQuery {
        var opts = baseOptions
        var positiveClauses: [String] = []
        var negativeClauses: [String] = []
        var plainTokens: [String] = []

        // Extract quoted phrases first
        var remainder = raw
        if let quoteRx = try? NSRegularExpression(pattern: #""([^"]+)""#, options: []) {
            let matches = quoteRx.matches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length))
            for m in matches.reversed() {
                let phrase = (raw as NSString).substring(with: m.range(at: 1))
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !phrase.isEmpty {
                    positiveClauses.append("\"\(phrase)\"")
                    plainTokens.append(contentsOf: tokenizeWords(phrase))
                }
                if let r = Range(m.range(at: 0), in: remainder) {
                    remainder.replaceSubrange(r, with: " ")
                }
            }
        }

        for rawTok in remainder.split(whereSeparator: \.isWhitespace) {
            let token = String(rawTok)
            let lower = token.lowercased()

            if lower.hasPrefix("lane:") {
                let val = String(token.dropFirst(5))
                if !val.isEmpty { opts.laneIDFilter = val }
                continue
            }
            if lower.hasPrefix("vendor:") {
                let val = String(token.dropFirst(7)).lowercased()
                if let v = AgentVendor(rawValue: val) { opts.vendorFilter = v }
                continue
            }
            if lower.hasPrefix("corpus:") {
                let val = String(token.dropFirst(7)).lowercased()
                if let c = FTSDocumentCorpus(rawValue: val) {
                    opts.allowedCorpora = [c]
                }
                continue
            }

            let isNegated = token.hasPrefix("-") && token.count > 1
            let core = isNegated ? String(token.dropFirst()) : token
            let hasPrefixStar = core.hasSuffix("*")
            let alphaNum = core.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            let cleanWord = String(String.UnicodeScalarView(alphaNum))
            guard !cleanWord.isEmpty else { continue }

            if isNegated {
                negativeClauses.append("NOT \"\(cleanWord)\"")
            } else if hasPrefixStar {
                positiveClauses.append("\"\(cleanWord)\"*")
                plainTokens.append(cleanWord)
            } else {
                positiveClauses.append("\"\(cleanWord)\"")
                plainTokens.append(cleanWord)
            }
        }

        guard !positiveClauses.isEmpty else {
            return CompiledQuery(ftsMatchExpression: "", plainTokens: [], effectiveOptions: opts)
        }
        let expr = (positiveClauses + negativeClauses).joined(separator: " ")
        return CompiledQuery(ftsMatchExpression: expr, plainTokens: plainTokens, effectiveOptions: opts)
    }

    private static func passesPostFilters(
        corpus: FTSDocumentCorpus,
        laneID: String,
        vendor: AgentVendor,
        recordedAt: Date,
        options: FTSQueryOptions
    ) -> Bool {
        if let allowed = options.allowedCorpora, !allowed.contains(corpus) {
            return false
        }
        if let laneFilter = options.laneIDFilter, !laneFilter.isEmpty,
           !laneID.localizedCaseInsensitiveContains(laneFilter) {
            return false
        }
        if let vendorFilter = options.vendorFilter, vendor != vendorFilter {
            return false
        }
        if let since = options.sinceDate, recordedAt < since {
            return false
        }
        return true
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func buildHighlightedExcerpt(
        in body: String,
        terms: [String],
        openMark: String,
        closeMark: String
    ) -> String {
        let singleLine = body.replacingOccurrences(of: "\n", with: " ")
        var excerpt = String(singleLine.prefix(200))
        let lowerBody = singleLine.lowercased()
        for t in terms {
            if let r = lowerBody.range(of: t) {
                let dist = lowerBody.distance(from: lowerBody.startIndex, to: r.lowerBound)
                let startOff = max(0, dist - 50)
                let startIdx = singleLine.index(singleLine.startIndex, offsetBy: startOff)
                let endIdx = singleLine.index(startIdx, offsetBy: min(180, singleLine.distance(from: startIdx, to: singleLine.endIndex)))
                excerpt = (startOff > 0 ? "… " : "") + String(singleLine[startIdx..<endIdx]) + (endIdx < singleLine.endIndex ? " …" : "")
                break
            }
        }
        for t in terms where !t.isEmpty {
            if let rx = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: t), options: [.caseInsensitive]) {
                excerpt = rx.stringByReplacingMatches(
                    in: excerpt,
                    range: NSRange(location: 0, length: (excerpt as NSString).length),
                    withTemplate: "\(openMark)$0\(closeMark)"
                )
            }
        }
        return excerpt
    }

    // MARK: - Internal SQLite Primitives

    internal static func execSQL(_ db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite execution failure"
            sqlite3_free(errMsg)
            throw RelayIDEError.databaseError(code: rc, message: msg)
        }
    }

    internal static func runPrepared(_ db: OpaquePointer, sql: String, bind: (OpaquePointer) -> Void) throws {
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

    internal static func colString(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }
}

// MARK: - RelayProjectDatabase Extensions: Migrations, Checkpointing, Integrity & Storage Telemetry

public extension RelayProjectDatabase {
    func makeFTS5SearchStore() -> RelayFTS5SearchStore {
        RelayFTS5SearchStore(database: self)
    }

    /// Inspects `schema_migrations` (`v1` -> `v4`) and verifies physical presence of every expected table.
    func appliedSchemaMigrations() throws -> [RelayAppliedMigrationRecord] {
        try withLockedHandle { db in
            var existingTables = Set<String>()
            var tblStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view');", -1, &tblStmt, nil) == SQLITE_OK,
               let preparedTbl = tblStmt {
                defer { sqlite3_finalize(preparedTbl) }
                while sqlite3_step(preparedTbl) == SQLITE_ROW {
                    existingTables.insert(RelayFTS5SearchStore.colString(preparedTbl, 0))
                }
            }

            var appliedEpochs: [Int: Double] = [:]
            var migStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT version, applied_at FROM schema_migrations ORDER BY version ASC;", -1, &migStmt, nil) == SQLITE_OK,
               let preparedMig = migStmt {
                defer { sqlite3_finalize(preparedMig) }
                while sqlite3_step(preparedMig) == SQLITE_ROW {
                    let v = Int(sqlite3_column_int64(preparedMig, 0))
                    let ts = sqlite3_column_double(preparedMig, 1)
                    appliedEpochs[v] = ts
                }
            }

            var records: [RelayAppliedMigrationRecord] = []
            for desc in RelaySchemaMigrationCatalog.allMigrations {
                guard let ts = appliedEpochs[desc.version] else { continue }
                let verified = desc.expectedTables.allSatisfy { existingTables.contains($0) }
                records.append(
                    RelayAppliedMigrationRecord(
                        version: desc.version,
                        codename: desc.codename,
                        appliedAt: Date(timeIntervalSince1970: ts),
                        ddlSHA256Prefix: desc.ddlSHA256Prefix,
                        allExpectedTablesPresent: verified
                    )
                )
            }
            return records
        }
    }

    /// Executes `PRAGMA integrity_check`, `PRAGMA foreign_key_check`, page geometry, and FTS5 capability diagnostics.
    func runDetailedIntegrityAudit() throws -> SQLiteIntegrityAuditReport {
        try withLockedHandle { db in
            var messages: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA integrity_check(32);", -1, &stmt, nil) == SQLITE_OK, let p = stmt {
                defer { sqlite3_finalize(p) }
                while sqlite3_step(p) == SQLITE_ROW {
                    messages.append(RelayFTS5SearchStore.colString(p, 0))
                }
            }

            var fkViolations = 0
            var fkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA foreign_key_check;", -1, &fkStmt, nil) == SQLITE_OK, let p = fkStmt {
                defer { sqlite3_finalize(p) }
                while sqlite3_step(p) == SQLITE_ROW {
                    fkViolations += 1
                }
            }

            let journalMode = Self.scalarText(db, sql: "PRAGMA journal_mode;")
            let pageSize = Self.scalarInt(db, sql: "PRAGMA page_size;")
            let pageCount = Self.scalarInt(db, sql: "PRAGMA page_count;")
            let freePages = Self.scalarInt(db, sql: "PRAGMA freelist_count;")

            var ftsSupported = false
            var ftsCheckStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT sqlite_compileoption_used('ENABLE_FTS5');", -1, &ftsCheckStmt, nil) == SQLITE_OK,
               let p = ftsCheckStmt {
                defer { sqlite3_finalize(p) }
                if sqlite3_step(p) == SQLITE_ROW {
                    ftsSupported = sqlite3_column_int(p, 0) == 1
                }
            }

            let ok = (messages.count == 1 && messages[0].lowercased() == "ok" && fkViolations == 0)
            return SQLiteIntegrityAuditReport(
                isHealthy: ok,
                integrityMessages: messages,
                foreignKeyViolations: fkViolations,
                journalMode: journalMode,
                pageSizeBytes: pageSize,
                totalPageCount: pageCount,
                freelistPageCount: freePages,
                fts5Available: ftsSupported
            )
        }
    }

    /// Runs `sqlite3_wal_checkpoint_v2` to flush WAL frames into `workspace.sqlite` and records telemetry history.
    @discardableResult
    func performWALCheckpoint(mode: SQLiteWALCheckpointMode = .truncate) throws -> SQLiteWALCheckpointReport {
        let walPath = sqliteFileURL.path + "-wal"
        let beforeBytes = Self.diskBytes(atPath: walPath)
        let startNs = DispatchTime.now().uptimeNanoseconds

        let (logFrames, ckptFrames) = try withLockedHandle { db -> (Int, Int) in
            var nLog: Int32 = 0
            var nCkpt: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(db, "main", mode.sqliteModeConstant, &nLog, &nCkpt)
            if rc != SQLITE_OK && rc != SQLITE_BUSY {
                throw RelayIDEError.databaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            return (Int(max(0, nLog)), Int(max(0, nCkpt)))
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let afterBytes = Self.diskBytes(atPath: walPath)
        let report = SQLiteWALCheckpointReport(
            mode: mode,
            totalLogFrames: logFrames,
            checkpointedFrames: ckptFrames,
            walBytesBefore: beforeBytes,
            walBytesAfter: afterBytes,
            elapsedMs: elapsedMs
        )

        // Persist checkpoint telemetry row if history table exists
        try? withLockedHandle { db in
            try RelayFTS5SearchStore.execSQL(db, sql: """
            CREATE TABLE IF NOT EXISTS wal_checkpoint_history (
                checkpoint_seq INTEGER PRIMARY KEY AUTOINCREMENT,
                mode TEXT NOT NULL,
                log_frames INTEGER NOT NULL,
                checkpointed_frames INTEGER NOT NULL,
                wal_bytes_before INTEGER NOT NULL,
                wal_bytes_after INTEGER NOT NULL,
                elapsed_ms REAL NOT NULL,
                executed_at REAL NOT NULL
            );
            """)
            try RelayFTS5SearchStore.runPrepared(
                db,
                sql: """
                INSERT INTO wal_checkpoint_history
                (mode, log_frames, checkpointed_frames, wal_bytes_before, wal_bytes_after, elapsed_ms, executed_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
                """
            ) { stmt in
                sqlite3_bind_text(stmt, 1, report.mode.rawValue, -1, RELAY_FTS_SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(report.totalLogFrames))
                sqlite3_bind_int(stmt, 3, Int32(report.checkpointedFrames))
                sqlite3_bind_int64(stmt, 4, report.walBytesBefore)
                sqlite3_bind_int64(stmt, 5, report.walBytesAfter)
                sqlite3_bind_double(stmt, 6, report.elapsedMs)
                sqlite3_bind_double(stmt, 7, report.executedAt.timeIntervalSince1970)
            }
        }

        return report
    }

    /// Collects per-table row counts, payload byte distributions, FTS5 corpus facets, and WAL storage footprint.
    func collectStorageTelemetry() throws -> WorkspaceStorageTelemetryReport {
        let fts = RelayFTS5SearchStore(database: self)
        try fts.ensureExtensionTables()
        let facets = try fts.corpusFacets()
        let integrity = try runDetailedIntegrityAudit()

        let tableSpecs: [(table: String, payloadColumn: String)] = [
            ("workspace_meta", "value"),
            ("managed_lanes", "payload_json"),
            ("dag_specs", "payload_json"),
            ("semantic_merge_reports", "payload_json"),
            ("wiretap_spans", "payload_json"),
            ("guardrail_findings", "payload_json"),
            ("undo_redo_stack", "mutation_json"),
            ("relay_fts5_doc_meta", "body_text"),
            ("relay_runs", "plan_copy_path"),
            ("relay_run_lanes", "prompt_path")
        ]

        let tableRows: [SQLiteTableTelemetryRow] = try withLockedHandle { db in
            var rows: [SQLiteTableTelemetryRow] = []
            for spec in tableSpecs {
                let sql = "SELECT COUNT(*), COALESCE(SUM(LENGTH(CAST(\(spec.payloadColumn) AS BLOB))), 0) FROM \(spec.table);"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt {
                    defer { sqlite3_finalize(p) }
                    if sqlite3_step(p) == SQLITE_ROW {
                        rows.append(
                            SQLiteTableTelemetryRow(
                                tableName: spec.table,
                                rowCount: Int(sqlite3_column_int64(p, 0)),
                                payloadBytes: sqlite3_column_int64(p, 1)
                            )
                        )
                    }
                }
            }
            return rows
        }

        let mainBytes = Self.diskBytes(atPath: sqliteFileURL.path)
        let walBytes = Self.diskBytes(atPath: sqliteFileURL.path + "-wal")
        let shmBytes = Self.diskBytes(atPath: sqliteFileURL.path + "-shm")

        return WorkspaceStorageTelemetryReport(
            schemaVersion: Self.currentSchemaVersion,
            sqliteFileBytes: mainBytes,
            walFileBytes: walBytes,
            shmFileBytes: shmBytes,
            tables: tableRows,
            ftsCorpusFacets: facets,
            integritySummary: integrity
        )
    }

    /// Creates a crash-consistent online SQLite snapshot at `destinationFileURL` using `sqlite3_backup_init`.
    func createOnlineSQLiteBackup(to destinationFileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try withLockedHandle { sourceDB in
            var destDB: OpaquePointer?
            let openRC = sqlite3_open_v2(
                destinationFileURL.path,
                &destDB,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openRC == SQLITE_OK, let target = destDB else {
                if let destDB { sqlite3_close(destDB) }
                throw RelayIDEError.databaseError(code: openRC, message: "Failed to open backup destination database")
            }
            defer { sqlite3_close(target) }

            guard let backupHandle = sqlite3_backup_init(target, "main", sourceDB, "main") else {
                throw RelayIDEError.databaseError(
                    code: sqlite3_errcode(target),
                    message: String(cString: sqlite3_errmsg(target))
                )
            }
            let stepRC = sqlite3_backup_step(backupHandle, -1)
            let finishRC = sqlite3_backup_finish(backupHandle)
            guard stepRC == SQLITE_DONE && finishRC == SQLITE_OK else {
                throw RelayIDEError.databaseError(
                    code: finishRC != SQLITE_OK ? finishRC : stepRC,
                    message: "Online SQLite backup failed (step=\(stepRC), finish=\(finishRC))"
                )
            }
        }
    }

    private static func scalarInt(_ db: OpaquePointer, sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return 0 }
        defer { sqlite3_finalize(p) }
        return sqlite3_step(p) == SQLITE_ROW ? Int(sqlite3_column_int64(p, 0)) : 0
    }

    private static func scalarText(_ db: OpaquePointer, sql: String) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let p = stmt else { return "" }
        defer { sqlite3_finalize(p) }
        return sqlite3_step(p) == SQLITE_ROW ? RelayFTS5SearchStore.colString(p, 0) : ""
    }

    private static func diskBytes(atPath path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
