import AppKit
import Combine
import CoreGraphics
import Foundation
import PDFKit
import RelayModels
import RelayOrchestrator
import RelayPTYCore
import RelayStudioViews
import RelayWorkbenchShell
import RelayWorkspaceStore
import RelayWorktreeGit
import SQLite3
import SwiftUI
import Testing

// MARK: - Tightened M5 Non-Demo Number Provenance & Key-Field Exact Equality Auditor

enum M5NumberProvenanceAndFieldAuditor {
    /// Set temporarily to `true` only when proving RED for Stage 3 Item 2; `false` in production tests.
    static let useLegacyLooseCheckForRedProof = false

    /// Original 12 static UI chrome tokens from M5-01/M5-02, plus 1 newly named bottom-drawer token (`BM25`).
    /// Every item is a fixed keyboard shortcut, technical standard/algorithm identifier, or layout preset label — never business data.
    static let explicitNamedStaticChromeTokens: [(name: String, literal: String)] = [
        // Preserved from M5-01 / M5-02:
        (name: "leftRailPaneShortcutRange", literal: "⌘1–5"),
        (name: "pane1ShortcutPTYGrid", literal: "⌘1"),
        (name: "pane2ShortcutDAGPipeline", literal: "⌘2"),
        (name: "pane3ShortcutMergeView", literal: "⌘3"),
        (name: "pane4ShortcutTerritoryMap", literal: "⌘4"),
        (name: "pane5ShortcutGuardrailPlugins", literal: "⌘5"),
        (name: "sqliteFullTextSearchEngineName", literal: "FTS5"),
        (name: "terminalEmulationStandardName", literal: "VT100"),
        (name: "quadGridPresetLabel", literal: "2×2"),
        (name: "conductorGridPresetLabel", literal: "1+3"),
        (name: "mergePaneLegacyAlgorithmName", literal: "3-Way"),
        (name: "isometricProjectionDimensionLabel", literal: "2.5D"),
        // Newly added in M5-03 (for expanded Bottom Drawer FTS5 search placeholder):
        (name: "sqliteBM25RankingAlgorithmName", literal: "BM25")
    ]

    /// Terminal line-number gutter labels (`01`..`26`), permitted ONLY on `.ptyGrid` when active terminal lanes exist.
    static let explicitTerminalGutterRowNumbers: Set<String> = Set(
        (1...26).map { String(format: "%02d", $0) }
    )

    struct IndependentLaneLogSpend: Sendable {
        let hasStepRecord: Bool
        let costUSD: Double?
        let tokens: Int?
        let costSource: String // "usd", "unpriced", "no_record"
    }

    struct IndependentGitOwnedFile: Sendable, Equatable {
        let relativePath: String
        let additions: Int
        let deletions: Int
        let isCommitted: Bool
    }

    struct IndependentGitLaneOwnership: Sendable {
        let laneID: String
        let startCommitOID: String
        let files: [IndependentGitOwnedFile]

        var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
        var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
        var committedCount: Int { files.filter(\.isCommitted).count }
        var uncommittedCount: Int { files.filter { !$0.isCommitted }.count }
    }

    struct AuditGroundTruth: Sendable {
        let schemaVersion: Int
        let checkpointsCount: Int
        let commonNumbers: Set<String>
        let ptyLogNumbers: Set<String>
        let mergeVerifyAndConflictNumbers: Set<String>
        /// Whole-token identifiers (40/64-char hex OIDs, runID, laneIDs, branch names, file paths).
        /// Scrubbed only as whole tokens, NEVER split into sub-digits!
        let exactIdentifiers: [String]
        let latestRun: RelayRunRecord?
        let logSpendsByLane: [String: IndependentLaneLogSpend]
        let gitOwnershipByLane: [String: IndependentGitLaneOwnership]
        let reconstructedConflicts: [RelayReconstructedMergeConflictBlock]
        let ptyRenderedRowStrings: [String]
        let verifyOutputLines: [String]
        let conflictBlockLines: [String]
        /// Legacy loose set used ONLY during Step 1A RED demonstration.
        let legacyLooseNumbers: Set<String>
        let legacyTerminalLogText: String
    }

    enum AuditRenderSurface: String, Sendable, Hashable, CaseIterable {
        case ptyGrid = "ptyGrid"
        case dagPipeline = "dagPipeline"
        case semanticMerge = "semanticMerge"
        case territoryMap = "territoryMap"
        case guardrailPlugins = "guardrailPlugins"
        case bottomDrawer = "bottomDrawer"
        case preferencesModal = "preferencesModal"

        init(pane: RelayStudioPane) {
            switch pane {
            case .ptyGrid: self = .ptyGrid
            case .dagPipeline: self = .dagPipeline
            case .semanticMerge: self = .semanticMerge
            case .territoryMap: self = .territoryMap
            case .guardrailPlugins: self = .guardrailPlugins
            }
        }

        var rendersPTYGridStage: Bool {
            switch self {
            case .ptyGrid, .bottomDrawer, .preferencesModal:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Complete Number Token Extraction (No Substring Matching)

    static func extractCompleteNumberTokens(from text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"(?<![0-9.])\d+(?:\.\d+)?(?![0-9.])"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    /// Extracts complete number tokens from freeform terminal/verify/conflict text AFTER stripping hex hashes,
    /// ISO timestamps, paths, and run IDs so hex/path/timestamp sub-digits never pollute ground truth.
    static func extractSafeLogNumbers(from rawLogText: String, strippingIdentifiers identifiers: [String]) throws -> Set<String> {
        var cleaned = rawLogText
        for ident in identifiers where !ident.isEmpty {
            cleaned = scrubSingleIdentifier(ident, from: cleaned)
        }
        // Strip 7..64 char hex strings containing at least one a-f hex letter so commit hashes in logs never leak sub-digits
        let hexRegex = try NSRegularExpression(pattern: #"\b(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{7,64}\b"#)
        cleaned = hexRegex.stringByReplacingMatches(
            in: cleaned,
            range: NSRange(location: 0, length: (cleaned as NSString).length),
            withTemplate: " "
        )
        return Set(try extractCompleteNumberTokens(from: cleaned))
    }

    static func scrubSingleIdentifier(_ ident: String, from text: String) -> String {
        guard !ident.isEmpty else { return text }
        // For long hex hashes / runIDs (>= 16 chars), allow optional single line-wrap whitespace inside PDF rendering
        if ident.count >= 16 && ident.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }) {
            let pieces = ident.map { NSRegularExpression.escapedPattern(for: String($0)) }
            let joined = pieces.joined(separator: #"(?:\s*\n\s*)?"#)
            let pat = "(?<![A-Za-z0-9])\(joined)(?![A-Za-z0-9])"
            if let rx = try? NSRegularExpression(pattern: pat) {
                return rx.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: " "
                )
            }
        }
        let escaped = NSRegularExpression.escapedPattern(for: ident)
        let pat = "(?<![A-Za-z0-9_./-])\(escaped)(?![A-Za-z0-9_./-])"
        guard let rx = try? NSRegularExpression(pattern: pat) else { return text }
        return rx.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: " "
        )
    }

    // MARK: - Independent .relay/LOG.md & Git Queries

    static func parseIndependentLaneLogSpend(worktreeURL: URL) -> IndependentLaneLogSpend {
        let logURL = worktreeURL.appendingPathComponent(".relay/LOG.md")
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return IndependentLaneLogSpend(hasStepRecord: false, costUSD: nil, tokens: nil, costSource: "no_record")
        }
        let parsed = RelayLogSpendParser.parseStepSpend(fromLogFileAt: logURL, initialByteOffset: 0)
        return IndependentLaneLogSpend(
            hasStepRecord: parsed.didAppendStepEntry,
            costUSD: parsed.costUSD,
            tokens: parsed.tokens,
            costSource: parsed.costSource
        )
    }

    private static func runReadOnlyGit(_ args: [String], cwd: String) -> (exitCode: Int32, stdout: Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["--no-optional-locks"] + args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        proc.environment = env
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return (-1, Data())
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, data)
    }

    static func queryIndependentGitOwnership(
        laneID: String,
        worktreePath: String,
        startCommitOID: String
    ) -> IndependentGitLaneOwnership {
        guard !worktreePath.isEmpty,
              !startCommitOID.isEmpty,
              FileManager.default.fileExists(atPath: worktreePath) else {
            return IndependentGitLaneOwnership(laneID: laneID, startCommitOID: startCommitOID, files: [])
        }

        func isExcluded(_ rel: String) -> Bool {
            rel == ".relay" || rel.hasPrefix(".relay/") || rel == ".git" || rel.hasPrefix(".git/")
        }

        // 1. Tracked changed files since startCommitOID
        let diffNamesRes = runReadOnlyGit(["diff", "--no-renames", "--name-only", "-z", startCommitOID], cwd: worktreePath)
        var allPaths = Set<String>()
        if diffNamesRes.exitCode == 0 {
            for part in diffNamesRes.stdout.split(separator: 0) {
                let p = String(decoding: part, as: UTF8.self)
                if !p.isEmpty && !isExcluded(p) { allPaths.insert(p) }
            }
        }

        // 2. Untracked files
        let untrackedRes = runReadOnlyGit(["ls-files", "--others", "--exclude-standard", "-z"], cwd: worktreePath)
        var untrackedSet = Set<String>()
        if untrackedRes.exitCode == 0 {
            for part in untrackedRes.stdout.split(separator: 0) {
                let p = String(decoding: part, as: UTF8.self)
                if !p.isEmpty && !isExcluded(p) {
                    allPaths.insert(p)
                    untrackedSet.insert(p)
                }
            }
        }

        // 3. Porcelain dirty status (uncommitted in worktree vs committed to lane branch)
        let statusRes = runReadOnlyGit(["status", "--porcelain=v1", "-z", "-uall"], cwd: worktreePath)
        var dirtySet = untrackedSet
        if statusRes.exitCode == 0 {
            let parts = statusRes.stdout.split(separator: 0, omittingEmptySubsequences: true)
            var idx = 0
            while idx < parts.count {
                let entry = String(decoding: parts[idx], as: UTF8.self)
                if entry.count > 3 {
                    let code = String(entry.prefix(2))
                    let path = String(entry.dropFirst(3))
                    if !isExcluded(path) {
                        dirtySet.insert(path)
                    }
                    if code.contains("R") || code.contains("C") {
                        idx += 1
                    }
                }
                idx += 1
            }
        }

        // 4. Numstat for tracked changes
        var numstatMap: [String: (Int, Int)] = [:]
        let numstatRes = runReadOnlyGit(["diff", "--no-renames", "--numstat", "-z", startCommitOID], cwd: worktreePath)
        if numstatRes.exitCode == 0 {
            for part in numstatRes.stdout.split(separator: 0) {
                let rec = String(decoding: part, as: UTF8.self)
                let cols = rec.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                if cols.count == 3 {
                    let add = Int(cols[0]) ?? 0
                    let del = Int(cols[1]) ?? 0
                    let path = String(cols[2])
                    numstatMap[path] = (add, del)
                }
            }
        }

        var ownedFiles: [IndependentGitOwnedFile] = []
        for rel in allPaths.sorted() {
            let add: Int
            let del: Int
            if let pair = numstatMap[rel] {
                add = pair.0
                del = pair.1
            } else if untrackedSet.contains(rel) {
                let fullURL = URL(fileURLWithPath: worktreePath, isDirectory: true).appendingPathComponent(rel)
                if let data = try? Data(contentsOf: fullURL), !data.contains(0) {
                    let str = String(decoding: data, as: UTF8.self)
                    if str.isEmpty {
                        add = 0
                    } else {
                        let nlCount = str.utf8.filter { $0 == UInt8(ascii: "\n") }.count
                        add = str.hasSuffix("\n") ? nlCount : (nlCount + 1)
                    }
                } else {
                    add = 0
                }
                del = 0
            } else {
                add = 0
                del = 0
            }
            ownedFiles.append(
                IndependentGitOwnedFile(
                    relativePath: rel,
                    additions: add,
                    deletions: del,
                    isCommitted: !dirtySet.contains(rel)
                )
            )
        }

        return IndependentGitLaneOwnership(laneID: laneID, startCommitOID: startCommitOID, files: ownedFiles)
    }

    // MARK: - Ground Truth Collection

    static func collectGroundTruth(bundleURL: URL) throws -> AuditGroundTruth {
        var common = Set<String>()
        var ptyNums = Set<String>()
        var mergeNums = Set<String>()
        var identifiersSet = Set<String>()

        var legacyLoose = Set<String>()
        var legacyTermLog = ""

        var schemaVer = RelayProjectDatabase.currentSchemaVersion
        var checkpointsCnt = 0
        var latestRun: RelayRunRecord?
        var logSpends: [String: IndependentLaneLogSpend] = [:]
        var gitOwnership: [String: IndependentGitLaneOwnership] = [:]
        var reconstructedConflicts: [RelayReconstructedMergeConflictBlock] = []
        var ptyRenderedRows: [String] = []
        var verifyLines: [String] = []
        var conflictLinesCollected: [String] = []

        let sqliteURL = bundleURL.appendingPathComponent("workspace.sqlite")
        identifiersSet.insert(bundleURL.deletingPathExtension().lastPathComponent)
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            var rawDB: OpaquePointer?
            if sqlite3_open_v2(sqliteURL.path, &rawDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = rawDB {
                defer { sqlite3_close(db) }
                func queryInt(_ sql: String) -> Int? {
                    var st: OpaquePointer?
                    defer { sqlite3_finalize(st) }
                    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK,
                          sqlite3_step(st) == SQLITE_ROW else { return nil }
                    return Int(sqlite3_column_int64(st, 0))
                }
                func queryString(_ sql: String) -> String? {
                    var st: OpaquePointer?
                    defer { sqlite3_finalize(st) }
                    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK,
                          sqlite3_step(st) == SQLITE_ROW,
                          let cStr = sqlite3_column_text(st, 0) else { return nil }
                    return String(cString: cStr)
                }
                if let wsName = queryString("SELECT value FROM workspace_meta WHERE key = 'workspace_name';"), !wsName.isEmpty {
                    identifiersSet.insert(wsName)
                }
                if let sv = queryInt("SELECT MAX(version) FROM schema_migrations;") {
                    schemaVer = sv
                    common.insert("\(sv)")
                    legacyLoose.insert("\(sv)")
                }
                if let cp = queryInt("SELECT COUNT(*) FROM checkpoints;") {
                    checkpointsCnt = cp
                    common.insert("\(cp)")
                    legacyLoose.insert("\(cp)")
                }
                for tbl in ["managed_lanes", "dag_specs", "semantic_merge_reports", "guardrail_findings", "relay_runs", "relay_run_lanes", "relay_run_integration", "relay_run_merges"] {
                    if let cnt = queryInt("SELECT COUNT(*) FROM \(tbl);") {
                        common.insert("\(cnt)")
                        legacyLoose.insert("\(cnt)")
                    }
                }
            }

            let projDB = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleURL)
            let gitInspector = RelayReadOnlyGitRunInspector()

            let runs = try projDB.allRuns(reconcileWithLock: true)
            if let run = runs.last {
                latestRun = run
                identifiersSet.insert(run.runID)
                identifiersSet.insert(run.baseCommitOID)
                identifiersSet.insert(run.relayShSHA256)

                // Legacy loose leak (for Step 1A RED proof only):
                for tok in try extractCompleteNumberTokens(from: run.runID) { legacyLoose.insert(tok) }
                for tok in try extractCompleteNumberTokens(from: run.baseCommitOID) { legacyLoose.insert(tok) }

                common.insert("\(run.lanes.count)")
                let termCount = run.lanes.filter(\.status.isTerminal).count
                common.insert("\(termCount)")
                let succCount = run.lanes.filter { $0.status == .succeeded || $0.status == .succeededNoChanges }.count
                common.insert("\(succCount)")

                legacyLoose.formUnion(common)

                if let runEnd = run.finishedAt {
                    let durStr = String(format: "%.2f", max(0.0, runEnd.timeIntervalSince(run.startedAt)))
                    common.insert(durStr)
                    legacyLoose.insert(durStr)
                }
                if run.pricedLaneCount > 0 {
                    let s = String(format: "%.4f", run.totalCostUSD)
                    common.insert(s)
                    legacyLoose.insert(s)
                }
                if run.unpricedTokens > 0 {
                    common.insert("\(run.unpricedTokens)")
                    legacyLoose.insert("\(run.unpricedTokens)")
                }
                if let cap = run.budgetUSD {
                    let c = String(format: "%.4f", cap)
                    common.insert(c)
                    legacyLoose.insert(c)
                }

                if let integ = run.integration {
                    identifiersSet.insert(integ.baseCommitOID)
                    for tok in try extractCompleteNumberTokens(from: integ.baseCommitOID) { legacyLoose.insert(tok) }
                    if let headOID = integ.headCommitOID, !headOID.isEmpty {
                        identifiersSet.insert(headOID)
                        for tok in try extractCompleteNumberTokens(from: headOID) { legacyLoose.insert(tok) }
                    }
                    common.insert("\(integ.merges.count)")
                    let totalConflicts = integ.merges.reduce(0) { $0 + $1.conflicts.count }
                    common.insert("\(totalConflicts)")
                    let mergedCount = integ.merges.filter { $0.status == .merged }.count
                    common.insert("\(mergedCount)")
                    legacyLoose.insert("\(integ.merges.count)")
                    legacyLoose.insert("\(totalConflicts)")
                    legacyLoose.insert("\(mergedCount)")

                    for step in integ.merges {
                        mergeNums.insert("\(step.ordinal)")
                        mergeNums.insert("\(step.conflicts.count)")
                        legacyLoose.insert("\(step.ordinal)")
                        legacyLoose.insert("\(step.conflicts.count)")
                        identifiersSet.insert(step.laneID)
                        if let lOID = step.laneCommitOID, !lOID.isEmpty {
                            identifiersSet.insert(lOID)
                            for tok in try extractCompleteNumberTokens(from: lOID) { legacyLoose.insert(tok) }
                        }
                        if let mOID = step.mergeCommitOID, !mOID.isEmpty {
                            identifiersSet.insert(mOID)
                            for tok in try extractCompleteNumberTokens(from: mOID) { legacyLoose.insert(tok) }
                        }
                        for c in step.conflicts {
                            identifiersSet.insert(c.path)
                        }
                    }

                    reconstructedConflicts = gitInspector.reconstructIntegrationConflictBlocks(
                        repositoryPath: run.repoPath,
                        integration: integ
                    )
                    for blk in reconstructedConflicts {
                        identifiersSet.insert(blk.mergeBaseOID)
                        identifiersSet.insert(blk.oursCommitOID)
                        identifiersSet.insert(blk.theirsCommitOID)
                        identifiersSet.insert(blk.path)
                        identifiersSet.insert(blk.laneID)
                        if let text = blk.conflictText {
                            legacyTermLog += "\n" + text
                            for tok in try extractCompleteNumberTokens(from: text) { legacyLoose.insert(tok) }
                        }
                    }

                    if let verify = integ.verify {
                        if let vec = verify.exitCode {
                            mergeNums.insert("\(vec)")
                            legacyLoose.insert("\(vec)")
                        }
                        if let vs = verify.startedAt, let vf = verify.finishedAt {
                            let vd = String(format: "%.2f", max(0.0, vf.timeIntervalSince(vs)))
                            mergeNums.insert(vd)
                            legacyLoose.insert(vd)
                        }
                    }
                }

                var totalFiles = 0
                var totalCommitted = 0
                var totalUncommitted = 0
                var totalAdd = 0
                var totalDel = 0

                for lane in run.lanes {
                    common.insert("\(lane.ordinal)")
                    legacyLoose.insert("\(lane.ordinal)")
                    identifiersSet.insert(lane.laneID)
                    for dep in lane.after { identifiersSet.insert(dep) }
                    if let branch = lane.branch, !branch.isEmpty { identifiersSet.insert(branch) }
                    if let cOID = lane.commitOID, !cOID.isEmpty {
                        identifiersSet.insert(cOID)
                        for tok in try extractCompleteNumberTokens(from: cOID) { legacyLoose.insert(tok) }
                    }
                    if let ec = lane.exitCode {
                        common.insert("\(ec)")
                        legacyLoose.insert("\(ec)")
                    }
                    if let s = lane.startedAt {
                        let so = String(format: "%.2f", max(0.0, s.timeIntervalSince(run.startedAt)))
                        common.insert(so)
                        legacyLoose.insert(so)
                    }
                    if let f = lane.finishedAt {
                        let fo = String(format: "%.2f", max(0.0, f.timeIntervalSince(run.startedAt)))
                        common.insert(fo)
                        legacyLoose.insert(fo)
                    }
                    if let s = lane.startedAt, let f = lane.finishedAt {
                        let dur = String(format: "%.2f", max(0.0, f.timeIntervalSince(s)))
                        common.insert(dur)
                        legacyLoose.insert(dur)
                    }

                    let wtDir = lane.worktreePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("worktrees", isDirectory: true)
                            .appendingPathComponent(lane.laneID, isDirectory: true)

                    // Independent LOG.md spend/tokens (ONLY spend & token numbers, NEVER ISO-8601 timestamps!)
                    let logSpend = parseIndependentLaneLogSpend(worktreeURL: wtDir)
                    logSpends[lane.laneID] = logSpend
                    if logSpend.costSource == "usd", let usd = logSpend.costUSD {
                        common.insert(String(format: "%.4f", usd))
                    } else if logSpend.costSource == "unpriced", let tok = logSpend.tokens {
                        common.insert("\(tok)")
                    }
                    // Also check DB fallback if worktree was cleaned up
                    if let tokCount = lane.tokens, lane.costSource == "unpriced" {
                        common.insert("\(tokCount)")
                        legacyLoose.insert("\(tokCount)")
                    }
                    if lane.costSource == "usd", let usd = lane.costUSD {
                        common.insert(String(format: "%.4f", usd))
                        legacyLoose.insert(String(format: "%.4f", usd))
                    }

                    let logMD = wtDir.appendingPathComponent(".relay/LOG.md")
                    if let mdText = try? String(contentsOf: logMD, encoding: .utf8) {
                        for tok in try extractCompleteNumberTokens(from: mdText) {
                            legacyLoose.insert(tok)
                        }
                    }

                    let startOID = RelayReadOnlyGitRunInspector.resolveLaneStartCommitOID(for: lane, in: run)
                    identifiersSet.insert(startOID)
                    for tok in try extractCompleteNumberTokens(from: startOID) { legacyLoose.insert(tok) }

                    let own = queryIndependentGitOwnership(
                        laneID: lane.laneID,
                        worktreePath: wtDir.path,
                        startCommitOID: startOID
                    )
                    gitOwnership[lane.laneID] = own
                    totalFiles += own.files.count
                    totalCommitted += own.committedCount
                    totalUncommitted += own.uncommittedCount
                    totalAdd += own.totalAdditions
                    totalDel += own.totalDeletions
                    common.insert("\(own.files.count)")
                    common.insert("\(own.totalAdditions)")
                    common.insert("\(own.totalDeletions)")
                    common.insert("\(own.committedCount)")
                    common.insert("\(own.uncommittedCount)")
                    for f in own.files {
                        identifiersSet.insert(f.relativePath)
                        common.insert("\(f.additions)")
                        common.insert("\(f.deletions)")
                    }
                }

                common.insert("\(totalFiles)")
                common.insert("\(totalCommitted)")
                common.insert("\(totalUncommitted)")
                common.insert("\(totalAdd)")
                common.insert("\(totalDel)")
                legacyLoose.formUnion(common)

                let sortedIdents = identifiersSet.filter { !$0.isEmpty }.sorted { $0.count > $1.count }

                // Collect PTY / step log numbers strictly scoped to `.ptyGrid` (including exact 96-column VT100 row wraps, zero substring matching)
                for lane in run.lanes {
                    let wtDir = lane.worktreePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("worktrees", isDirectory: true)
                            .appendingPathComponent(lane.laneID, isDirectory: true)
                    let relayDir = wtDir.appendingPathComponent(".relay", isDirectory: true)
                    let refVT = VT100TerminalScreenBuffer(laneID: lane.laneID, rows: 26, columns: 96)
                    var hadStepLog = false
                    if let items = try? FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil) {
                        for f in items.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                            if let txt = try? String(contentsOf: f, encoding: .utf8), !txt.isEmpty {
                                hadStepLog = true
                                legacyTermLog += "\n" + txt
                                ptyNums.formUnion(try extractSafeLogNumbers(from: txt, strippingIdentifiers: sortedIdents))
                                let crlf = txt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
                                refVT.feed(Data(crlf.utf8))
                                for tok in try extractCompleteNumberTokens(from: txt) { legacyLoose.insert(tok) }
                            }
                        }
                    }
                    if !hadStepLog {
                        let ptyURL = bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("lanes", isDirectory: true)
                            .appendingPathComponent("\(lane.laneID).pty")
                        if let ptyText = try? String(contentsOf: ptyURL, encoding: .utf8), !ptyText.isEmpty {
                            legacyTermLog += "\n" + ptyText
                            ptyNums.formUnion(try extractSafeLogNumbers(from: ptyText, strippingIdentifiers: sortedIdents))
                            refVT.feed(Data(ptyText.utf8))
                            for tok in try extractCompleteNumberTokens(from: ptyText) { legacyLoose.insert(tok) }
                        }
                    }
                    let vtRowList = refVT.snapshot().visibleGrid.map { row in
                        row.map { $0.grapheme }.joined().trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }
                    ptyRenderedRows.append(contentsOf: vtRowList)
                    let vtLines = vtRowList.joined(separator: "\n")
                    if !vtLines.isEmpty {
                        ptyNums.formUnion(try extractSafeLogNumbers(from: vtLines, strippingIdentifiers: sortedIdents))
                    }
                }

                // Collect verify.pty & conflict block numbers strictly scoped to `.semanticMerge`
                if let integ = run.integration {
                    for blk in reconstructedConflicts {
                        if let text = blk.conflictText {
                            mergeNums.formUnion(try extractSafeLogNumbers(from: text, strippingIdentifiers: sortedIdents))
                            for ln in text.components(separatedBy: .newlines) {
                                let t = ln.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty { conflictLinesCollected.append(t) }
                            }
                        }
                    }
                    if let verify = integ.verify {
                        mergeNums.formUnion(try extractSafeLogNumbers(from: verify.command, strippingIdentifiers: sortedIdents))
                        let vPath = verify.logPath ?? bundleURL
                            .appendingPathComponent("runs", isDirectory: true)
                            .appendingPathComponent(run.runID, isDirectory: true)
                            .appendingPathComponent("verify.pty")
                            .path
                        if let vText = try? String(contentsOfFile: vPath, encoding: .utf8), !vText.isEmpty {
                            legacyTermLog += "\n" + vText
                            mergeNums.formUnion(try extractSafeLogNumbers(from: vText, strippingIdentifiers: sortedIdents))
                            for ln in vText.components(separatedBy: .newlines) {
                                let t = ln.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty { verifyLines.append(t) }
                            }
                            for tok in try extractCompleteNumberTokens(from: vText) { legacyLoose.insert(tok) }
                        }
                    }
                }
            } else {
                // Check persisted managed_lanes when no relay_runs exist
                let persistedLanes = (try? projDB.allLanes()) ?? []
                var totalManagedFiles = 0
                for mLane in persistedLanes {
                    identifiersSet.insert(mLane.id)
                    identifiersSet.insert(mLane.baseCommitOID)
                    let own = queryIndependentGitOwnership(
                        laneID: mLane.id,
                        worktreePath: mLane.worktreePath,
                        startCommitOID: mLane.baseCommitOID
                    )
                    gitOwnership[mLane.id] = own
                    totalManagedFiles += own.files.count
                    common.insert("\(own.files.count)")
                    common.insert("\(own.totalAdditions)")
                    common.insert("\(own.totalDeletions)")
                    for f in own.files {
                        identifiersSet.insert(f.relativePath)
                        common.insert("\(f.additions)")
                        common.insert("\(f.deletions)")
                    }
                }
                if !persistedLanes.isEmpty {
                    common.insert("\(totalManagedFiles)")
                }
                legacyLoose.formUnion(common)
            }
        } else {
            common.insert("\(schemaVer)")
            common.insert("0")
            legacyLoose.formUnion(common)
        }

        let sortedIdentifiers = identifiersSet.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        return AuditGroundTruth(
            schemaVersion: schemaVer,
            checkpointsCount: checkpointsCnt,
            commonNumbers: common,
            ptyLogNumbers: ptyNums,
            mergeVerifyAndConflictNumbers: mergeNums,
            exactIdentifiers: sortedIdentifiers,
            latestRun: latestRun,
            logSpendsByLane: logSpends,
            gitOwnershipByLane: gitOwnership,
            reconstructedConflicts: reconstructedConflicts,
            ptyRenderedRowStrings: ptyRenderedRows,
            verifyOutputLines: verifyLines,
            conflictBlockLines: conflictLinesCollected,
            legacyLooseNumbers: legacyLoose,
            legacyTerminalLogText: legacyTermLog
        )
    }

    // MARK: - Part (a): Complete-Token Unmatched Number Check

    static func unmatchedNumbersInPDF(
        pdfText: String,
        pane: RelayStudioPane,
        hasActiveTerminalRows: Bool,
        truth: AuditGroundTruth
    ) throws -> [String] {
        if useLegacyLooseCheckForRedProof {
            var scrubbed = pdfText
            for entry in explicitNamedStaticChromeTokens {
                scrubbed = scrubbed.replacingOccurrences(of: entry.literal, with: " ")
            }
            let extracted = try extractCompleteNumberTokens(from: scrubbed)
            let compactLog = truth.legacyTerminalLogText.replacingOccurrences(of: "\n", with: " ")
            return extracted.filter { token in
                if truth.legacyLooseNumbers.contains(token) { return false }
                if hasActiveTerminalRows && explicitTerminalGutterRowNumbers.contains(token) { return false }
                if token.count >= 2 && compactLog.contains(token) { return false }
                return true
            }
        }

        var scrubbed = pdfText
        // 1. Scrub explicitly named static chrome tokens
        for entry in explicitNamedStaticChromeTokens {
            scrubbed = scrubbed.replacingOccurrences(of: entry.literal, with: " ")
        }
        // 2. Scrub exact whole-token identifiers (commit OIDs, runID, laneIDs, branch names, file paths)
        for ident in truth.exactIdentifiers {
            scrubbed = scrubSingleIdentifier(ident, from: scrubbed)
        }

        let extracted = try extractCompleteNumberTokens(from: scrubbed)
        var allowed = truth.commonNumbers
        if pane == .ptyGrid {
            allowed.formUnion(truth.ptyLogNumbers)
        } else if pane == .semanticMerge {
            allowed.formUnion(truth.mergeVerifyAndConflictNumbers)
        }

        return extracted.filter { token in
            if allowed.contains(token) {
                return false
            }
            if pane == .ptyGrid && hasActiveTerminalRows && explicitTerminalGutterRowNumbers.contains(token) {
                return false
            }
            return true
        }
    }

    // MARK: - Part (b): Key-Field Exact Value Equality Check Against SQLite, .relay/LOG.md & Git

    private static func regexCaptures(_ pattern: String, in text: String) throws -> [[String]] {
        let rx = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { idx in
                let r = m.range(at: idx)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func normalizePDFSpacingForFieldParsing(_ raw: String) throws -> String {
        // Normalize macOS PDFKit ToUnicode Kangxi Radicals (e.g. U+2F42 '⽂' -> U+6587 '文') without altering ASCII/symbols
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for sc in raw.unicodeScalars {
            if (0x2E80...0x2FDF).contains(sc.value) || (0xF900...0xFAFF).contains(sc.value) {
                for norm in String(sc).precomposedStringWithCompatibilityMapping.unicodeScalars {
                    scalars.append(norm)
                }
            } else {
                scalars.append(sc)
            }
        }
        var s = String(scalars)
        // PDFKit inserts spaces between adjacent CJK glyphs or around '/' in monospaced pills; collapse only those gaps
        let cjkGap = try NSRegularExpression(pattern: #"([\p{Han}])\s+([\p{Han}])"#)
        for _ in 0..<3 {
            s = cjkGap.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1$2")
        }
        let numCjkGap = try NSRegularExpression(pattern: #"(\d)\s+([\p{Han}])"#)
        s = numCjkGap.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1 $2")
        let cjkDotGap = try NSRegularExpression(pattern: #"([\p{Han}])\s*·\s*([\p{Han}])"#)
        s = cjkDotGap.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1 · $2")
        let ratioSlashGap = try NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#)
        s = ratioSlashGap.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1/$2")
        return s
    }

    private static func formatViolation(
        surface: AuditRenderSurface,
        language: RelayLanguage,
        lane: String,
        field: String,
        got: String,
        expected: String
    ) -> String {
        "[pane=\(surface.rawValue) lang=\(language.rawValue) lane=\(lane) field=\(field)] got=\(got) expected=\(expected)"
    }

    private static func formatMultiset(_ items: [String]) -> String {
        if items.isEmpty { return "[]" }
        var counts: [String: Int] = [:]
        for item in items { counts[item, default: 0] += 1 }
        let body = counts.keys.sorted().map { k in
            let c = counts[k] ?? 0
            return c == 1 ? "'\(k)'" : "'\(k)'×\(c)"
        }.joined(separator: ", ")
        return "[\(body)]"
    }

    private static func compareExact(
        got: [String],
        expected: [String],
        surface: AuditRenderSurface,
        language: RelayLanguage,
        lane: String,
        field: String,
        into violations: inout [String]
    ) {
        if got != expected {
            violations.append(
                formatViolation(
                    surface: surface,
                    language: language,
                    lane: lane,
                    field: field,
                    got: "\(got)",
                    expected: "\(expected)"
                )
            )
        }
    }

    private static func compareMultiset(
        got: [String],
        expected: [String],
        surface: AuditRenderSurface,
        language: RelayLanguage,
        lane: String,
        field: String,
        into violations: inout [String]
    ) {
        var gotCounts: [String: Int] = [:]
        for x in got { gotCounts[x, default: 0] += 1 }
        var expCounts: [String: Int] = [:]
        for x in expected { expCounts[x, default: 0] += 1 }
        if gotCounts != expCounts {
            violations.append(
                formatViolation(
                    surface: surface,
                    language: language,
                    lane: lane,
                    field: field,
                    got: formatMultiset(got),
                    expected: formatMultiset(expected)
                )
            )
        }
    }

    private static func statusAlternationPattern(in language: RelayLanguage) -> String {
        RelayRunStatus.allCases
            .map { $0.localizedLabel(in: language) }
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
    }

    private static func scrubUIChromeText(
        normalizedPDF: String,
        surface: AuditRenderSurface,
        orderedLanes: [RelayRunLaneRecord],
        truth: AuditGroundTruth
    ) throws -> String {
        var text = normalizedPDF

        if surface.rendersPTYGridStage && !orderedLanes.isEmpty {
            let gutterRx = try NSRegularExpression(pattern: #"^(?:0[1-9]|1[0-9]|2[0-6])\s+(?!checkpoints\b|个快照)(.*)$"#)
            let normVTRows = try truth.ptyRenderedRowStrings.map {
                try normalizePDFSpacingForFieldParsing($0).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            var pendingWrappedTails: [String: Int] = [:]
            var keptLines: [String] = []
            for line in text.components(separatedBy: "\n") {
                let ns = line as NSString
                if let m = gutterRx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let head = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    if !head.isEmpty && head != "▋" {
                        for vtRow in normVTRows where vtRow.hasPrefix(head) && vtRow.count > head.count {
                            let tail = String(vtRow.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
                            if !tail.isEmpty {
                                pendingWrappedTails[tail, default: 0] += 1
                            }
                        }
                    }
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, let c = pendingWrappedTails[trimmed], c > 0 {
                    pendingWrappedTails[trimmed] = c - 1
                    continue
                }
                keptLines.append(line)
            }
            text = keptLines.joined(separator: "\n")
        }

        if surface == .semanticMerge {
            var transcriptLineCounts: [String: Int] = [:]
            for rawLine in (truth.verifyOutputLines + truth.conflictBlockLines) {
                let normLine = try normalizePDFSpacingForFieldParsing(rawLine).trimmingCharacters(in: .whitespaces)
                if !normLine.isEmpty {
                    transcriptLineCounts[normLine, default: 0] += 1
                }
            }
            var keptLines: [String] = []
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, let c = transcriptLineCounts[trimmed], c > 0 {
                    transcriptLineCounts[trimmed] = c - 1
                    continue
                }
                keptLines.append(line)
            }
            text = keptLines.joined(separator: "\n")
            if truth.latestRun?.integration?.verify != nil {
                let cmdRx = try NSRegularExpression(pattern: #"(?m)\$\s+[^\n]*$"#)
                text = cmdRx.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }
        }

        return text
    }

    static func verifyLedgerAgainstLogMD(truth: AuditGroundTruth) -> [String] {
        if useLegacyLooseCheckForRedProof {
            return []
        }
        guard let run = truth.latestRun else {
            return []
        }
        var violations: [String] = []
        let orderedLanes = run.lanes.sorted(by: { $0.ordinal < $1.ordinal })
        var logSumUSD = 0.0
        var logUnpricedTok = 0
        for lane in orderedLanes {
            if let ls = truth.logSpendsByLane[lane.laneID], ls.hasStepRecord {
                if ls.costSource != lane.costSource {
                    violations.append("[pane=sqliteLedger lang=all lane=\(lane.laneID) field=costSource] got=\(lane.costSource ?? "nil") expected=\(ls.costSource)")
                }
                if ls.costSource == "usd", let lUSD = ls.costUSD {
                    logSumUSD += lUSD
                    if abs((lane.costUSD ?? -1) - lUSD) > 1e-6 {
                        violations.append("[pane=sqliteLedger lang=all lane=\(lane.laneID) field=costUSD] got=\(String(describing: lane.costUSD)) expected=\(lUSD)")
                    }
                } else if ls.costSource == "unpriced", let lTok = ls.tokens {
                    logUnpricedTok += lTok
                    if lane.tokens != lTok {
                        violations.append("[pane=sqliteLedger lang=all lane=\(lane.laneID) field=tokens] got=\(String(describing: lane.tokens)) expected=\(lTok)")
                    }
                }
            }
        }
        if abs(run.totalCostUSD - logSumUSD) > 1e-6 {
            violations.append("[pane=sqliteLedger lang=all lane=<run> field=totalCostUSD] got=\(run.totalCostUSD) expected=\(logSumUSD)")
        }
        if run.unpricedTokens != logUnpricedTok {
            violations.append("[pane=sqliteLedger lang=all lane=<run> field=unpricedTokens] got=\(run.unpricedTokens) expected=\(logUnpricedTok)")
        }
        return violations
    }

    /// Audits a SINGLE rendered PDF surface in isolation: extracts EVERY displayed occurrence of all 11 key-field
    /// categories via regular expressions (never substring `contains`), verifying per-lane exact equality wherever
    /// lane identifiers and fields sit adjacent on the panel, plus panel-wide multiset equality across all occurrences.
    static func verifySingleRenderKeyFields(
        pdfText rawPDF: String,
        surface: AuditRenderSurface,
        language: RelayLanguage,
        truth: AuditGroundTruth
    ) throws -> [String] {
        if useLegacyLooseCheckForRedProof {
            return []
        }

        let normPDF = try normalizePDFSpacingForFieldParsing(rawPDF)
        let isZh = language.isChinese
        let run = truth.latestRun
        let orderedLanes = run?.lanes.sorted(by: { $0.ordinal < $1.ordinal }) ?? []
        let uiPDF = try scrubUIChromeText(
            normalizedPDF: normPDF,
            surface: surface,
            orderedLanes: orderedLanes,
            truth: truth
        )

        var violations: [String] = []
        let expectedLaneCount = orderedLanes.count
        let expectedFinishedCount = orderedLanes.filter(\.status.isTerminal).count
        let expectedConflictCount = run?.integration?.merges.reduce(0) { $0 + $1.conflicts.count } ?? 0
        let expectedTotalOwnedFiles = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.files.count ?? 0) }
        let expectedTotalAdd = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.totalAdditions ?? 0) }
        let expectedTotalDel = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.totalDeletions ?? 0) }
        let expectedTotalCommitted = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.committedCount ?? 0) }
        let expectedTotalUncommitted = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.uncommittedCount ?? 0) }
        let statusAlt = statusAlternationPattern(in: language)

        func expectedDuration(_ lane: RelayRunLaneRecord) -> String? {
            guard let s = lane.startedAt, let f = lane.finishedAt else { return nil }
            return String(format: "%.2fs", max(0.0, f.timeIntervalSince(s)))
        }
        func expectedSpendUSD(_ lane: RelayRunLaneRecord) -> String? {
            guard lane.costSource == "usd", let usd = lane.costUSD else { return nil }
            return RelayBauhausDesign.formatRunUSD(usd)
        }
        func expectedUnpricedTokens(_ lane: RelayRunLaneRecord) -> String? {
            if lane.costSource == "unpriced" || (lane.costUSD == nil && (lane.tokens ?? 0) > 0) {
                if let tok = lane.tokens, tok > 0 { return "\(tok)" }
            }
            return nil
        }

        // ------------------------------------------------------------------
        // 1. Top Bar Wave/Lane Count & Run Status + Left Rail Badges + Store Strip
        // ------------------------------------------------------------------
        let wavePat = isZh
            ? #"(\d+)/(\d+)\s*条通道\s*·\s*("# + statusAlt + #")"#
            : #"(\d+)/(\d+)\s+Lanes\s*·\s*("# + statusAlt + #")"#
        let waveCaps = try regexCaptures(wavePat, in: uiPDF).map { "\($0[0])/\($0[1])·\($0[2])" }
        if let run {
            let expWave = ["\(expectedFinishedCount)/\(expectedLaneCount)·\(run.status.localizedLabel(in: language))"]
            compareExact(got: waveCaps, expected: expWave, surface: surface, language: language, lane: "<topBar>", field: "activeWaveSummary", into: &violations)
        } else {
            compareExact(got: waveCaps, expected: [], surface: surface, language: language, lane: "<topBar>", field: "activeWaveSummary", into: &violations)
            let idlePat = isZh ? #"(\d+)\s*项任务\s*·\s*(空闲)"# : #"(\d+)\s+Tasks\s*·\s*(Idle)"#
            let idleCaps = try regexCaptures(idlePat, in: uiPDF).map { "\($0[0])·\($0[1])" }
            let expIdle = [isZh ? "0·空闲" : "0·Idle"]
            compareExact(got: idleCaps, expected: expIdle, surface: surface, language: language, lane: "<topBar>", field: "emptyIdleSummary", into: &violations)
        }

        let b1Caps = try regexCaptures(#"([^\s]+)\s+⌘1(?![0-9–])"#, in: uiPDF).map { $0[0] }
        compareExact(got: b1Caps, expected: ["\(expectedLaneCount)"], surface: surface, language: language, lane: "<leftRail>", field: "badge⌘1LaneCount", into: &violations)

        let b2Caps = try regexCaptures(#"([^\s]+)\s+⌘2"#, in: uiPDF).map { $0[0] }
        compareExact(got: b2Caps, expected: ["\(expectedLaneCount)"], surface: surface, language: language, lane: "<leftRail>", field: "badge⌘2LaneCount", into: &violations)

        let b3Caps = try regexCaptures(#"([^\s]+)\s+⌘3"#, in: uiPDF).map { $0[0] }
        if expectedConflictCount > 0 {
            compareExact(got: b3Caps, expected: ["\(expectedConflictCount)!"], surface: surface, language: language, lane: "<leftRail>", field: "badge⌘3ConflictCount", into: &violations)
        } else if isZh {
            if b3Caps.count != 1 || !b3Caps[0].hasSuffix("就绪") || b3Caps[0].rangeOfCharacter(from: .decimalDigits) != nil {
                violations.append(formatViolation(surface: surface, language: language, lane: "<leftRail>", field: "badge⌘3Clean", got: "\(b3Caps)", expected: "['*就绪' (0 digits)]"))
            }
        } else {
            compareExact(got: b3Caps, expected: ["OK"], surface: surface, language: language, lane: "<leftRail>", field: "badge⌘3Clean", into: &violations)
        }

        let b4Caps = try regexCaptures(#"([^\s]+)\s+⌘4"#, in: uiPDF).map { $0[0] }
        compareExact(got: b4Caps, expected: ["\(expectedTotalOwnedFiles)"], surface: surface, language: language, lane: "<leftRail>", field: "badge⌘4OwnedFiles", into: &violations)

        let svCaps = try regexCaptures(#"SQLite WAL v(\d+)\s*·\s*FTS5"#, in: uiPDF).map { $0[0] }
        compareExact(got: svCaps, expected: ["\(truth.schemaVersion)"], surface: surface, language: language, lane: "<leftRail>", field: "sqliteSchemaVersion", into: &violations)

        let cpPat = isZh ? #"(\d+)\s*个快照"# : #"(\d+)\s+checkpoints\b"#
        let cpCaps = try regexCaptures(cpPat, in: uiPDF).map { $0[0] }
        compareExact(got: cpCaps, expected: ["\(truth.checkpointsCount)"], surface: surface, language: language, lane: "<leftRail>", field: "checkpointsCount", into: &violations)

        // All standalone `N lanes` / `N 条通道` pills on this single panel + EN bottom bar `Observing N lane(s)`
        let lanePillPat = isZh ? #"(?<!/)(?<![0-9.])(\d+)\s*条通道"# : #"(?<!/)(?<![0-9.])(\d+)\s+lanes\b"#
        let gotLanePills = try regexCaptures(lanePillPat, in: uiPDF).map { $0[0] }
        let expLanePillOccurrences: Int = {
            if isZh {
                if expectedLaneCount > 0 {
                    // Left Rail + Bottom Status Bar (+1 on ⌘2 DAG header, +1 on ⌘4 Ownership header)
                    switch surface {
                    case .dagPipeline, .territoryMap: return 3
                    default: return 2
                    }
                } else {
                    // Left Rail (+1 on ⌘1 empty card '当前 0 条通道', +1 on ⌘4 Ownership header '0 条通道')
                    if surface.rendersPTYGridStage || surface == .territoryMap {
                        return 2
                    }
                    return 1
                }
            } else {
                switch surface {
                case .dagPipeline:
                    return expectedLaneCount > 0 ? 2 : 1
                case .territoryMap:
                    return 2
                default:
                    return 1
                }
            }
        }()
        compareMultiset(
            got: gotLanePills,
            expected: Array(repeating: "\(expectedLaneCount)", count: expLanePillOccurrences),
            surface: surface,
            language: language,
            lane: "<panel-multiset>",
            field: "laneCountPills",
            into: &violations
        )
        if !isZh {
            let obsCaps = try regexCaptures(#"Observing\s+(\d+)\s+lane\(s\)"#, in: uiPDF).map { $0[0] }
            let expObs = expectedLaneCount > 0 ? ["\(expectedLaneCount)"] : []
            compareExact(got: obsCaps, expected: expObs, surface: surface, language: language, lane: "<bottomBar>", field: "observingLaneCount", into: &violations)
        }

        // ------------------------------------------------------------------
        // 2. Top Bar Spend / Budget / Unpriced Pill + Forbidden $0.00 / Fake Ceiling
        // ------------------------------------------------------------------
        let forbiddenZeroCents = try regexCaptures(#"(\$0\.00(?!\d))"#, in: uiPDF).map { $0[0] }
        compareExact(got: forbiddenZeroCents, expected: [], surface: surface, language: language, lane: "<panel>", field: "forbiddenTwoDecimalZeroUSD", into: &violations)
        if run?.budgetUSD == nil {
            let fakeCeil = try regexCaptures(#"(/\s*\$\d+(?:\.\d+)?)"#, in: uiPDF).map { $0[0] }
            compareExact(got: fakeCeil, expected: [], surface: surface, language: language, lane: "<topBar>", field: "unexpectedBudgetCeiling", into: &violations)
        }

        let topSpendPat = isZh
            ? #"花费\s+(\$\d+(?:\.\d+)?)(?:\s*/\s*(\$\d+(?:\.\d+)?))?(?:\s*·\s*(\d+)\s*tokens\s*未计价)?"#
            : #"Spend\s+(\$\d+(?:\.\d+)?)(?:\s*/\s*(\$\d+(?:\.\d+)?))?(?:\s*·\s*(\d+)\s*tokens\s+unpriced)?"#
        let topSpendCaps = try regexCaptures(topSpendPat, in: uiPDF).map { c in
            "spend=\(c[0])|cap=\(c[1])|unpriced=\(c[2])"
        }
        if let run, (run.pricedLaneCount > 0 || run.budgetUSD != nil) {
            let expSpend = RelayBauhausDesign.formatRunUSD(run.totalCostUSD)
            let expCap = run.budgetUSD.map { RelayBauhausDesign.formatRunUSD($0) } ?? ""
            let expUnp = run.unpricedTokens > 0 ? "\(run.unpricedTokens)" : ""
            compareExact(
                got: topSpendCaps,
                expected: ["spend=\(expSpend)|cap=\(expCap)|unpriced=\(expUnp)"],
                surface: surface,
                language: language,
                lane: "<topBar>",
                field: "topBarSpendBudgetUnpriced",
                into: &violations
            )
        } else {
            compareExact(got: topSpendCaps, expected: [], surface: surface, language: language, lane: "<topBar>", field: "topBarSpendBudgetUnpriced", into: &violations)
        }

        if surface == .preferencesModal {
            let prefCapPat = isZh
                ? #"工作区全局美元预算上限\s*(\$\d+(?:\.\d+)?)"#
                : #"Global Workspace USD Budget Ceiling[^\n]*?\n?(?:[^\n]*?\s)?(\$\d+(?:\.\d+)?)"#
            if let cap = run?.budgetUSD {
                let expCap = RelayBauhausDesign.formatRunUSD(cap)
                let gotCap = try regexCaptures(prefCapPat, in: uiPDF).map { $0[0] }
                if !gotCap.isEmpty {
                    compareExact(got: gotCap, expected: [expCap], surface: surface, language: language, lane: "<preferencesModal>", field: "modalBudgetCeilingUSD", into: &violations)
                }
            }
        }

        // ------------------------------------------------------------------
        // 3. Left Rail Per-Lane Card Exact Binding (All 7 Surfaces)
        // ------------------------------------------------------------------
        for lane in orderedLanes {
            let escID = NSRegularExpression.escapedPattern(for: lane.laneID)
            let vendorName = RelayBauhausDesign.vendorStudioName(lane.agent.agentVendor, language: language)
            let escVendor = NSRegularExpression.escapedPattern(for: vendorName)

            let railPat = #"(?m)(?:^|\n)\s*"# + escID + #"(?![A-Za-z0-9_-])\s*("# + statusAlt + #")\s*(?:(?:exit|退出码)\s*(-?\d+)|in progress|执行中|—)(?:[ \t]*(\d+\.\d+s))?"#
            let railCaps = try regexCaptures(railPat, in: uiPDF)
            let expStatus = lane.status.localizedLabel(in: language)
            let expEC = lane.exitCode.map { "\($0)" } ?? ""
            let expDur = expectedDuration(lane) ?? ""
            compareExact(
                got: railCaps.map { $0[0] },
                expected: [expStatus],
                surface: surface,
                language: language,
                lane: lane.laneID,
                field: "leftRailStatus",
                into: &violations
            )
            compareExact(
                got: railCaps.map { $0[1] },
                expected: [expEC],
                surface: surface,
                language: language,
                lane: lane.laneID,
                field: "leftRailExitCode",
                into: &violations
            )
            compareExact(
                got: railCaps.map { $0[2] },
                expected: [expDur],
                surface: surface,
                language: language,
                lane: lane.laneID,
                field: "leftRailDuration",
                into: &violations
            )

            // Left rail per-lane spend / unpriced tokens adjacent to laneID
            let railSpendPat = #"(?m)^"# + escVendor + #"[ \t]+(\$\d+(?:\.\d+)?)\s*\n\s*"# + escID + #"(?![A-Za-z0-9_-])"#
            let railSpendCaps = try regexCaptures(railSpendPat, in: uiPDF).map { $0[0] }
            if let expUSD = expectedSpendUSD(lane) {
                if surface != .preferencesModal || !railSpendCaps.isEmpty {
                    compareExact(got: railSpendCaps, expected: [expUSD], surface: surface, language: language, lane: lane.laneID, field: "leftRailSpendUSD", into: &violations)
                }
            } else {
                compareExact(got: railSpendCaps, expected: [], surface: surface, language: language, lane: lane.laneID, field: "leftRailSpendUSD", into: &violations)
            }

            let railTokPat = #"(?m)^"# + escVendor + #"[ \t]+(\d+)\s*tokens\s*·\s*(?:unpriced|未计价)\s*\n\s*"# + escID + #"(?![A-Za-z0-9_-])"#
            let railTokCaps = try regexCaptures(railTokPat, in: uiPDF).map { $0[0] }
            if let expTok = expectedUnpricedTokens(lane) {
                if surface != .preferencesModal || !railTokCaps.isEmpty {
                    compareExact(got: railTokCaps, expected: [expTok], surface: surface, language: language, lane: lane.laneID, field: "leftRailUnpricedTokens", into: &violations)
                }
            } else {
                compareExact(got: railTokCaps, expected: [], surface: surface, language: language, lane: lane.laneID, field: "leftRailUnpricedTokens", into: &violations)
            }
        }

        // ------------------------------------------------------------------
        // 4. Surface `.ptyGrid`, `.bottomDrawer`, `.preferencesModal`: ⌘1 Per-Lane Terminal Headers
        // ------------------------------------------------------------------
        if surface.rendersPTYGridStage {
            for lane in orderedLanes {
                let escID = NSRegularExpression.escapedPattern(for: lane.laneID)
                let vendorName = RelayBauhausDesign.vendorStudioName(lane.agent.agentVendor, language: language)
                let escVendor = NSRegularExpression.escapedPattern(for: vendorName)

                let hdrPat = escVendor + #"\s*·\s*"# + escID + #"(?![A-Za-z0-9_-])(?:[ \t]+\$\d+(?:\.\d+)?)?\s*\n?\s*("# + statusAlt + #")(?:\s*·\s*(?:exit|退出码)\s*(-?\d+))?(?:[ \t]+(\d+\.\d+s))?"#
                let hdrCaps = try regexCaptures(hdrPat, in: uiPDF)
                let expStatus = lane.status.localizedLabel(in: language)
                let expEC = lane.exitCode.map { "\($0)" } ?? ""
                let expDur = expectedDuration(lane) ?? ""

                compareExact(
                    got: hdrCaps.map { $0[0] },
                    expected: [expStatus],
                    surface: surface,
                    language: language,
                    lane: lane.laneID,
                    field: "ptyHeaderStatus",
                    into: &violations
                )
                compareExact(
                    got: hdrCaps.map { $0[1] },
                    expected: [expEC],
                    surface: surface,
                    language: language,
                    lane: lane.laneID,
                    field: "ptyHeaderExitCode",
                    into: &violations
                )
                compareExact(
                    got: hdrCaps.map { $0[2] },
                    expected: [expDur],
                    surface: surface,
                    language: language,
                    lane: lane.laneID,
                    field: "ptyHeaderDuration",
                    into: &violations
                )

                if surface != .preferencesModal {
                    let hdrSpendPat = escVendor + #"\s*·\s*"# + escID + #"(?![A-Za-z0-9_-])[^\n]*?(\$\d+(?:\.\d+)?)"#
                    let hdrSpendCaps = try regexCaptures(hdrSpendPat, in: uiPDF).map { $0[0] }
                    let expUSD = expectedSpendUSD(lane).map { [$0] } ?? []
                    compareExact(got: hdrSpendCaps, expected: expUSD, surface: surface, language: language, lane: lane.laneID, field: "ptyHeaderSpendUSD", into: &violations)
                }

                let hdrTokPat = escVendor + #"\s*·\s*"# + escID + #"(?![A-Za-z0-9_-])(?:[ \t]+\$\d+(?:\.\d+)?)?\s*\n?[^\n]*?(\d+)\s*tokens\s*·\s*(?:unpriced|未计价)"#
                let hdrTokCaps = try regexCaptures(hdrTokPat, in: uiPDF).map { $0[0] }
                let expTok = expectedUnpricedTokens(lane).map { [$0] } ?? []
                compareExact(got: hdrTokCaps, expected: expTok, surface: surface, language: language, lane: lane.laneID, field: "ptyHeaderUnpricedTokens", into: &violations)
            }
        }

        // ------------------------------------------------------------------
        // 5. Surface `.dagPipeline` (⌘2): Header, Per-Node Status & Timing, Selected-Lane Inspector
        // ------------------------------------------------------------------
        if surface == .dagPipeline, let run, !orderedLanes.isEmpty {
            let escRunID = NSRegularExpression.escapedPattern(for: run.runID)
            let dagHdrPat = escRunID + #"\s+("# + statusAlt + #")\s+(\d+)\s*(?:lanes\b|条通道)(?:[ \t]+(\d+\.\d+s))?"#
            let dagHdrCaps = try regexCaptures(dagHdrPat, in: uiPDF)
            let expRunStatus = run.status.localizedLabel(in: language)
            let expRunDur = run.finishedAt.map { String(format: "%.2fs", max(0.0, $0.timeIntervalSince(run.startedAt))) } ?? ""
            compareExact(got: dagHdrCaps.map { $0[0] }, expected: [expRunStatus], surface: surface, language: language, lane: "<dagHeader>", field: "dagRunStatus", into: &violations)
            compareExact(got: dagHdrCaps.map { $0[1] }, expected: ["\(expectedLaneCount)"], surface: surface, language: language, lane: "<dagHeader>", field: "dagLaneCount", into: &violations)
            compareExact(got: dagHdrCaps.map { $0[2] }, expected: [expRunDur], surface: surface, language: language, lane: "<dagHeader>", field: "dagRunElapsed", into: &violations)

            var expectedNodeTimings: [String] = []
            for lane in orderedLanes {
                let shortTag = NSRegularExpression.escapedPattern(for: RelayBauhausDesign.vendorShortTag(lane.agent.agentVendor))
                let escID = NSRegularExpression.escapedPattern(for: lane.laneID)

                // Single-line header `<TAG> #<ordinal> <status>` uniquely identifies lane by `#ordinal`
                let nodeHdrPat = #"(?<![A-Za-z0-9_-])"# + shortTag + #"[ \t]+#"# + "\(lane.ordinal)" + #"(?!\d)[ \t]+("# + statusAlt + #")"#
                let nodeHdrCaps = try regexCaptures(nodeHdrPat, in: uiPDF).map { $0[0] }
                compareExact(
                    got: nodeHdrCaps,
                    expected: [lane.status.localizedLabel(in: language)],
                    surface: surface,
                    language: language,
                    lane: lane.laneID,
                    field: "dagNodeStatus",
                    into: &violations
                )

                if let s = lane.startedAt, let f = lane.finishedAt {
                    let so = max(0.0, s.timeIntervalSince(run.startedAt))
                    let fo = max(0.0, f.timeIntervalSince(run.startedAt))
                    let dur = String(format: "%.2fs", max(0.0, f.timeIntervalSince(s)))
                    let expTiming = String(format: "+%.2fs → +%.2fs · %@", so, fo, dur)
                    expectedNodeTimings.append(expTiming)

                    let adjTimingPat = #"(?<![A-Za-z0-9_-])"# + shortTag + #"[ \t]+#"# + "\(lane.ordinal)" + #"(?!\d)[ \t]+(?:"# + statusAlt + #")\s+"# + escID + #"(?![A-Za-z0-9_-])(?:(?!\+\d)[^\n]*\n?){0,2}\s*(\+\d+\.\d+s\s*→\s*\+\d+\.\d+s\s*·\s*\d+\.\d+s)"#
                    let adjCaps = try regexCaptures(adjTimingPat, in: uiPDF).map {
                        $0[0].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    }
                    if !adjCaps.isEmpty {
                        compareExact(
                            got: adjCaps,
                            expected: [expTiming],
                            surface: surface,
                            language: language,
                            lane: lane.laneID,
                            field: "dagNodeTiming",
                            into: &violations
                        )
                    }
                }
            }

            let allNodeTimingCaps = try regexCaptures(#"(\+\d+\.\d+s\s*→\s*\+\d+\.\d+s\s*·\s*\d+\.\d+s)"#, in: uiPDF).map {
                $0[0].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            compareMultiset(
                got: allNodeTimingCaps,
                expected: expectedNodeTimings,
                surface: surface,
                language: language,
                lane: "<dagNodes-multiset>",
                field: "dagNodeTimingMultiset",
                into: &violations
            )

            // Selected-lane inspector on the right (`orderedLanes[0]`)
            let selLane = orderedLanes[0]
            let selVendorName = NSRegularExpression.escapedPattern(for: RelayBauhausDesign.vendorStudioName(selLane.agent.agentVendor, language: language))
            let inspStatusCaps = try regexCaptures(selVendorName + #"[ \t]+("# + statusAlt + #")(?!\s*\$)"#, in: uiPDF).map { $0[0] }
            compareExact(got: inspStatusCaps, expected: [selLane.status.localizedLabel(in: language)], surface: surface, language: language, lane: selLane.laneID, field: "dagInspectorStatus", into: &violations)

            let inspTimingCaps = try regexCaptures(#"(\+\d+\.\d+s\s*→\s*\+\d+\.\d+s\s*\(\d+\.\d+s\))"#, in: uiPDF).map {
                $0[0].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            if let s = selLane.startedAt, let f = selLane.finishedAt, let dur = expectedDuration(selLane) {
                let so = max(0.0, s.timeIntervalSince(run.startedAt))
                let fo = max(0.0, f.timeIntervalSince(run.startedAt))
                let expInspTiming = [String(format: "+%.2fs → +%.2fs (%@)", so, fo, dur)]
                compareExact(got: inspTimingCaps, expected: expInspTiming, surface: surface, language: language, lane: selLane.laneID, field: "dagInspectorTiming", into: &violations)
            } else {
                compareExact(got: inspTimingCaps, expected: [], surface: surface, language: language, lane: selLane.laneID, field: "dagInspectorTiming", into: &violations)
            }

            let inspExitCaps = try regexCaptures(#"(?:EXIT STATUS|退出状态)\s*\n?\s*(?:exit|退出码)\s*(-?\d+)"#, in: uiPDF).map { $0[0] }
            compareExact(got: inspExitCaps, expected: selLane.exitCode.map { ["\($0)"] } ?? [], surface: surface, language: language, lane: selLane.laneID, field: "dagInspectorExitCode", into: &violations)

            if let selUSD = expectedSpendUSD(selLane) {
                let inspSpendCaps = try regexCaptures(#"(?:RECORDED SPEND / TOKENS|记录花费与 Token)\s*\n?\s*(\$\d+(?:\.\d+)?)"#, in: uiPDF).map { $0[0] }
                compareExact(got: inspSpendCaps, expected: [selUSD], surface: surface, language: language, lane: selLane.laneID, field: "dagInspectorSpendUSD", into: &violations)
            } else if let selTok = expectedUnpricedTokens(selLane) {
                let inspTokCaps = try regexCaptures(#"(?:RECORDED SPEND / TOKENS|记录花费与 Token)\s*\n?\s*(\d+)\s*tokens\s*·\s*(?:unpriced|未计价)"#, in: uiPDF).map { $0[0] }
                compareExact(got: inspTokCaps, expected: [selTok], surface: surface, language: language, lane: selLane.laneID, field: "dagInspectorUnpricedTokens", into: &violations)
            }
        }

        // ------------------------------------------------------------------
        // 6. Surface `.semanticMerge` (⌘3): Header Status, Ready, Steps, Conflicts, Verify
        // ------------------------------------------------------------------
        var statusCheckText = uiPDF
        if surface == .semanticMerge, let integ = run?.integration {
            let readyCaps = try regexCaptures(#"ready:\s*(true|false)"#, in: uiPDF).map { $0[0] }
            compareExact(got: readyCaps, expected: [integ.ready ? "true" : "false"], surface: surface, language: language, lane: "<integration>", field: "integrationReady", into: &violations)

            let integRawAlt = RelayIntegrationStatus.allCases.map(\.rawValue).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            if isZh {
                let integZhAlt = RelayIntegrationStatus.allCases.map { $0.localizedLabel(in: .zhHans) }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                let pat = #"集成合并与验证结果\s*("# + integZhAlt + #")\s*·\s*("# + integRawAlt + #")"#
                let caps = try regexCaptures(pat, in: uiPDF).map { "\($0[0])·\($0[1])" }
                let exp = ["\(integ.status.localizedLabel(in: .zhHans))·\(integ.status.rawValue)"]
                compareExact(got: caps, expected: exp, surface: surface, language: language, lane: "<integration>", field: "integrationStatus", into: &violations)
                let rx = try NSRegularExpression(pattern: pat)
                statusCheckText = rx.stringByReplacingMatches(in: statusCheckText, range: NSRange(location: 0, length: (statusCheckText as NSString).length), withTemplate: "集成合并与验证结果")
            } else {
                let pat = #"Integration Merge & Verification\s+("# + integRawAlt + #")\s+ready:"#
                let caps = try regexCaptures(pat, in: uiPDF).map { $0[0] }
                compareExact(got: caps, expected: [integ.status.rawValue], surface: surface, language: language, lane: "<integration>", field: "integrationStatus", into: &violations)
                let rx = try NSRegularExpression(pattern: pat)
                statusCheckText = rx.stringByReplacingMatches(in: statusCheckText, range: NSRange(location: 0, length: (statusCheckText as NSString).length), withTemplate: "Integration Merge & Verification ready:")
            }

            let stepPat = isZh ? #"(\d+)\s*步"# : #"(\d+)\s+steps\b"#
            let stepCaps = try regexCaptures(stepPat, in: uiPDF).map { $0[0] }
            compareExact(got: stepCaps, expected: ["\(integ.merges.count)"], surface: surface, language: language, lane: "<integration>", field: "mergeStepCount", into: &violations)

            let sortedSteps = integ.merges.sorted { $0.ordinal < $1.ordinal }
            for step in sortedSteps {
                let escStepLane = NSRegularExpression.escapedPattern(for: step.laneID)
                let stepRawAlt = RelayMergeStepStatus.allCases.map(\.rawValue).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                if isZh {
                    let stepZhAlt = RelayMergeStepStatus.allCases.map { $0.localizedLabel(in: .zhHans) }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                    let rowPat = #"#"# + "\(step.ordinal)" + #"(?!\d)\s+"# + escStepLane + #"(?![A-Za-z0-9_-])\s+("# + stepZhAlt + #")\s*·\s*("# + stepRawAlt + #")"#
                    let rowCaps = try regexCaptures(rowPat, in: uiPDF).map { "\($0[0])·\($0[1])" }
                    compareExact(got: rowCaps, expected: ["\(step.status.localizedLabel(in: .zhHans))·\(step.status.rawValue)"], surface: surface, language: language, lane: step.laneID, field: "mergeStepStatus", into: &violations)
                } else {
                    let rowPat = #"#"# + "\(step.ordinal)" + #"(?!\d)\s+"# + escStepLane + #"(?![A-Za-z0-9_-])\s+("# + stepRawAlt + #")"#
                    let rowCaps = try regexCaptures(rowPat, in: uiPDF).map { $0[0] }
                    compareExact(got: rowCaps, expected: [step.status.rawValue], surface: surface, language: language, lane: step.laneID, field: "mergeStepStatus", into: &violations)
                }
            }
            if sortedSteps.isEmpty, let reason = integ.reason, !reason.isEmpty {
                let normReason = try normalizePDFSpacingForFieldParsing(reason)
                statusCheckText = statusCheckText.replacingOccurrences(of: normReason, with: " ")
            }

            let hasConflicts = !truth.reconstructedConflicts.isEmpty || integ.status == .conflict
            let confPat = isZh ? #"(\d+)\s*个文件"# : #"(\d+)\s+files\b"#
            let confCaps = try regexCaptures(confPat, in: uiPDF).map { $0[0] }
            compareExact(got: confCaps, expected: hasConflicts ? ["\(truth.reconstructedConflicts.count)"] : [], surface: surface, language: language, lane: "<integration>", field: "conflictFileCount", into: &violations)

            if let verify = integ.verify {
                let verRawAlt = RelayVerifyStatus.allCases.map(\.rawValue).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                if isZh {
                    let verZhAlt = RelayVerifyStatus.allCases.map { $0.localizedLabel(in: .zhHans) }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                    let vPat = #"("# + verZhAlt + #")\s*·\s*("# + verRawAlt + #")(?:\s*退出码\s*(-?\d+))?"#
                    let vCaps = try regexCaptures(vPat, in: uiPDF)
                    compareExact(got: vCaps.map { "\($0[0])·\($0[1])" }, expected: ["\(verify.status.localizedLabel(in: .zhHans))·\(verify.status.rawValue)"], surface: surface, language: language, lane: "<verify>", field: "verifyStatus", into: &violations)
                    compareExact(got: vCaps.map { $0[2] }, expected: [verify.exitCode.map { "\($0)" } ?? ""], surface: surface, language: language, lane: "<verify>", field: "verifyExitCode", into: &violations)
                    let vRx = try NSRegularExpression(pattern: #"("# + verZhAlt + #")\s*·\s*("# + verRawAlt + #")"#)
                    statusCheckText = vRx.stringByReplacingMatches(in: statusCheckText, range: NSRange(location: 0, length: (statusCheckText as NSString).length), withTemplate: " ")
                } else {
                    let vPat = #"(?:VERIFICATION OUTPUT \(VERIFY\.PTY\)|Verification Output \(verify\.pty\))[^\n]*\n\s*("# + verRawAlt + #")(?:[ \t]+exit\s+(-?\d+))?"#
                    let vCaps = try regexCaptures(vPat, in: uiPDF)
                    compareExact(got: vCaps.map { $0[0] }, expected: [verify.status.rawValue], surface: surface, language: language, lane: "<verify>", field: "verifyStatus", into: &violations)
                    compareExact(got: vCaps.map { $0[1] }, expected: [verify.exitCode.map { "\($0)" } ?? ""], surface: surface, language: language, lane: "<verify>", field: "verifyExitCode", into: &violations)
                    let vRx = try NSRegularExpression(pattern: #"(?:VERIFICATION OUTPUT \(VERIFY\.PTY\)|Verification Output \(verify\.pty\))[^\n]*\n\s*("# + verRawAlt + #")"#)
                    statusCheckText = vRx.stringByReplacingMatches(in: statusCheckText, range: NSRange(location: 0, length: (statusCheckText as NSString).length), withTemplate: "Verification Output (verify.pty)\n")
                }
            } else {
                statusCheckText = statusCheckText
                    .replacingOccurrences(of: "verification was skipped", with: " ")
                    .replacingOccurrences(of: "验证阶段已跳过", with: " ")
            }
        }

        // ------------------------------------------------------------------
        // 7. Surface `.territoryMap` (⌘4): Header, Per-Lane Card Status/Files/+Add/-Del, Per-File State & Diffs
        // ------------------------------------------------------------------
        if surface == .territoryMap {
            for lane in orderedLanes {
                let shortTag = NSRegularExpression.escapedPattern(for: RelayBauhausDesign.vendorShortTag(lane.agent.agentVendor))
                let escID = NSRegularExpression.escapedPattern(for: lane.laneID)
                let own = truth.gitOwnershipByLane[lane.laneID]
                let expCardFiles = "\(own?.files.count ?? 0)"
                let expCardDiff = "+\(own?.totalAdditions ?? 0)/-\(own?.totalDeletions ?? 0)"

                // Per-lane status on ⌘4 card (`<TAG> <laneID> <status>`)
                let cardStatusPat = #"(?<![A-Za-z0-9_-])"# + shortTag + #"[ \t]+"# + escID + #"(?![A-Za-z0-9_-])\s*("# + statusAlt + #")"#
                let cardStatusCaps = try regexCaptures(cardStatusPat, in: uiPDF).map { $0[0] }
                compareExact(
                    got: cardStatusCaps,
                    expected: [lane.status.localizedLabel(in: language)],
                    surface: surface,
                    language: language,
                    lane: lane.laneID,
                    field: "ownershipCardStatus",
                    into: &violations
                )

                // Per-lane `+add / -del` & `N files` adjacent to `<TAG> <laneID> <status>`
                let cardMetricsPat = #"(?<![A-Za-z0-9_-])"# + shortTag + #"[ \t]+"# + escID + #"(?![A-Za-z0-9_-])\s*(?:"# + statusAlt + #")(?:\s*(?:start:|起点:)\s*[0-9a-fA-F]+)?\s*\+(\d+)\s*/\s*-(\d+)\s+(\d+)\s*(?:files\b|个文件)"#
                let cardMetricsCaps = try regexCaptures(cardMetricsPat, in: uiPDF)
                if !cardMetricsCaps.isEmpty {
                    compareExact(
                        got: cardMetricsCaps.map { "+\($0[0])/-\($0[1])" },
                        expected: [expCardDiff],
                        surface: surface,
                        language: language,
                        lane: lane.laneID,
                        field: "ownershipCardDiffSummary",
                        into: &violations
                    )
                    compareExact(
                        got: cardMetricsCaps.map { $0[2] },
                        expected: [expCardFiles],
                        surface: surface,
                        language: language,
                        lane: lane.laneID,
                        field: "ownershipCardFileCount",
                        into: &violations
                    )
                }
            }

            let filesPat = isZh ? #"(\d+)\s*个文件"# : #"(\d+)\s+files\b"#
            let gotFileCounts = try regexCaptures(filesPat, in: uiPDF).map { $0[0] }
            let expFileCounts: [String] = expectedLaneCount == 0
                ? ["0"]
                : (["\(expectedTotalOwnedFiles)"] + orderedLanes.map { "\(truth.gitOwnershipByLane[$0.laneID]?.files.count ?? 0)" })
            compareMultiset(
                got: gotFileCounts,
                expected: expFileCounts,
                surface: surface,
                language: language,
                lane: "<territoryMap-multiset>",
                field: "ownershipFileCounts",
                into: &violations
            )

            let gotSlashDiffs = try regexCaptures(#"\+(\d+)\s*/\s*-(\d+)"#, in: uiPDF).map { "+\($0[0])/-\($0[1])" }
            var expSlashDiffs: [String] = []
            if expectedTotalOwnedFiles > 0 {
                expSlashDiffs.append("+\(expectedTotalAdd)/-\(expectedTotalDel)")
            }
            for lane in orderedLanes {
                let own = truth.gitOwnershipByLane[lane.laneID]
                expSlashDiffs.append("+\(own?.totalAdditions ?? 0)/-\(own?.totalDeletions ?? 0)")
            }
            compareMultiset(
                got: gotSlashDiffs,
                expected: expSlashDiffs,
                surface: surface,
                language: language,
                lane: "<territoryMap-multiset>",
                field: "ownershipDiffSummaries",
                into: &violations
            )

            let stateSummaryPat = isZh
                ? #"(\d+)\s*已提交\s*·\s*(\d+)\s*未提交"#
                : #"(\d+)\s+committed\s*·\s*(\d+)\s+uncommitted"#
            let gotStateSummary = try regexCaptures(stateSummaryPat, in: uiPDF).map { "\($0[0])/\($0[1])" }
            let expStateSummary = expectedTotalOwnedFiles > 0 ? ["\(expectedTotalCommitted)/\(expectedTotalUncommitted)"] : []
            compareExact(
                got: gotStateSummary,
                expected: expStateSummary,
                surface: surface,
                language: language,
                lane: "<territoryMapHeader>",
                field: "committedUncommittedSummary",
                into: &violations
            )

            let fileRowPat = isZh
                ? #"(?m)(?:^|\s)([^\s\n]+)\s+(已提交|未提交)\s+\+(\d+)\s+-(\d+)(?!\s*/)"#
                : #"(?m)(?:^|\s)([^\s\n]+)\s+(committed|uncommitted)\s+\+(\d+)\s+-(\d+)(?!\s*/)"#
            let gotFileRows = try regexCaptures(fileRowPat, in: uiPDF).map { "\($0[0])|\($0[1])|+\($0[2]) -\($0[3])" }
            var expFileRows: [String] = []
            var expStandaloneFileDiffs: [String] = []
            for lane in orderedLanes {
                for f in truth.gitOwnershipByLane[lane.laneID]?.files ?? [] {
                    let stLabel = f.isCommitted ? (isZh ? "已提交" : "committed") : (isZh ? "未提交" : "uncommitted")
                    expFileRows.append("\(f.relativePath)|\(stLabel)|+\(f.additions) -\(f.deletions)")
                    expStandaloneFileDiffs.append("+\(f.additions) -\(f.deletions)")
                }
            }
            compareMultiset(
                got: gotFileRows,
                expected: expFileRows,
                surface: surface,
                language: language,
                lane: "<territoryMap-files>",
                field: "perFilePathStateAndDiff",
                into: &violations
            )

            let gotStandaloneFileDiffs = try regexCaptures(#"\+(\d+)\s+-(\d+)(?!\s*/)"#, in: uiPDF).map { "+\($0[0]) -\($0[1])" }
            compareMultiset(
                got: gotStandaloneFileDiffs,
                expected: expStandaloneFileDiffs,
                surface: surface,
                language: language,
                lane: "<territoryMap-files>",
                field: "perFileAdditionsDeletions",
                into: &violations
            )
        }

        // ------------------------------------------------------------------
        // 8. Panel-Wide Full Multiset Verification Across ALL Occurrences on This Surface
        //    (Catches ANY extra, missing, or displaced status, exitCode, duration, USD spend, or unpriced token!)
        // ------------------------------------------------------------------

        // 8a. All `RelayRunStatus` occurrences on this panel
        let allStatusPat = isZh
            ? #"("# + statusAlt + #")"#
            : #"(?<![A-Za-z0-9_-])("# + statusAlt + #")(?![A-Za-z0-9_-])"#
        let gotAllStatuses = try regexCaptures(allStatusPat, in: statusCheckText).map { $0[0] }
        var expAllStatuses: [String] = []
        if let run {
            let runLbl = run.status.localizedLabel(in: language)
            expAllStatuses.append(runLbl) // Top Bar
            if !orderedLanes.isEmpty {
                expAllStatuses.append(runLbl) // Bottom Status Bar `Live run (<status>)` / `实时运行<status>`
            }
            if surface == .dagPipeline && !orderedLanes.isEmpty {
                expAllStatuses.append(runLbl) // DAG Header Strip
            }
        }
        for lane in orderedLanes {
            let lbl = lane.status.localizedLabel(in: language)
            expAllStatuses.append(lbl) // Left Rail
            if surface.rendersPTYGridStage {
                expAllStatuses.append(lbl) // ⌘1 Terminal Pane Header
            } else if surface == .dagPipeline {
                expAllStatuses.append(lbl) // ⌘2 DAG Node Card
            } else if surface == .territoryMap {
                expAllStatuses.append(lbl) // ⌘4 Lane Ownership Card
            }
        }
        if surface == .dagPipeline, let sel = orderedLanes.first {
            expAllStatuses.append(sel.status.localizedLabel(in: language)) // ⌘2 Selected-Lane Inspector
        }
        compareMultiset(
            got: gotAllStatuses,
            expected: expAllStatuses,
            surface: surface,
            language: language,
            lane: "<panel-multiset>",
            field: "allStatusesOnPanel",
            into: &violations
        )

        // 8b. All `exit <N>` / `退出码 <N>` occurrences on this panel
        let exitPat = isZh ? #"退出码\s*(-?\d+)"# : #"\bexit\s+(-?\d+)\b"#
        let gotAllExits = try regexCaptures(exitPat, in: uiPDF).map { $0[0] }
        var expAllExits: [String] = []
        for lane in orderedLanes {
            if let ec = lane.exitCode {
                expAllExits.append("\(ec)") // Left Rail
                if surface.rendersPTYGridStage {
                    expAllExits.append("\(ec)") // ⌘1 Terminal Pane Header
                }
            }
        }
        if surface == .dagPipeline, let selEC = orderedLanes.first?.exitCode {
            expAllExits.append("\(selEC)") // ⌘2 Inspector
        }
        if surface == .semanticMerge, let verEC = run?.integration?.verify?.exitCode {
            expAllExits.append("\(verEC)") // ⌘3 Verify Section
        }
        compareMultiset(
            got: gotAllExits,
            expected: expAllExits,
            surface: surface,
            language: language,
            lane: "<panel-multiset>",
            field: "allExitCodesOnPanel",
            into: &violations
        )

        // 8c. All `%.2fs` / `+%.2fs` duration & offset tokens on this panel
        let gotAllTimings = try regexCaptures(#"([+]?\d+\.\d+s)\b"#, in: uiPDF).map { $0[0] }
        var expAllTimings: [String] = []
        for lane in orderedLanes {
            if let d = expectedDuration(lane) {
                expAllTimings.append(d) // Left Rail
                if surface.rendersPTYGridStage {
                    expAllTimings.append(d) // ⌘1 Terminal Pane Header
                }
            }
        }
        if surface == .dagPipeline, let run, !orderedLanes.isEmpty {
            if let end = run.finishedAt {
                expAllTimings.append(String(format: "%.2fs", max(0.0, end.timeIntervalSince(run.startedAt))))
            }
            for lane in orderedLanes {
                if let s = lane.startedAt, let f = lane.finishedAt, let d = expectedDuration(lane) {
                    expAllTimings.append(String(format: "+%.2fs", max(0.0, s.timeIntervalSince(run.startedAt))))
                    expAllTimings.append(String(format: "+%.2fs", max(0.0, f.timeIntervalSince(run.startedAt))))
                    expAllTimings.append(d)
                }
            }
            if let sel = orderedLanes.first, let s = sel.startedAt, let f = sel.finishedAt, let d = expectedDuration(sel) {
                expAllTimings.append(String(format: "+%.2fs", max(0.0, s.timeIntervalSince(run.startedAt))))
                expAllTimings.append(String(format: "+%.2fs", max(0.0, f.timeIntervalSince(run.startedAt))))
                expAllTimings.append(d)
            }
        }
        compareMultiset(
            got: gotAllTimings,
            expected: expAllTimings,
            surface: surface,
            language: language,
            lane: "<panel-multiset>",
            field: "allDurationsAndOffsetsOnPanel",
            into: &violations
        )

        // 8d. All `$X.XXXX` (or any `$\d+(?:\.\d+)?`) dollar spend tokens on this panel
        let gotAllDollars = try regexCaptures(#"(\$\d+(?:\.\d+)?)"#, in: uiPDF).map { $0[0] }
        var expAllDollars: [String] = []
        if let run {
            if run.pricedLaneCount > 0 || run.budgetUSD != nil {
                expAllDollars.append(RelayBauhausDesign.formatRunUSD(run.totalCostUSD))
                if let cap = run.budgetUSD {
                    expAllDollars.append(RelayBauhausDesign.formatRunUSD(cap))
                }
            }
            if surface == .preferencesModal, let cap = run.budgetUSD {
                expAllDollars.append(RelayBauhausDesign.formatRunUSD(cap))
            }
        }
        for lane in orderedLanes {
            if let usd = expectedSpendUSD(lane) {
                expAllDollars.append(usd) // Left Rail
                if surface.rendersPTYGridStage {
                    expAllDollars.append(usd) // ⌘1 Terminal Pane Header
                }
            }
        }
        if surface == .dagPipeline, let sel = orderedLanes.first, let selUSD = expectedSpendUSD(sel) {
            expAllDollars.append(selUSD) // ⌘2 Inspector
        }
        compareMultiset(
            got: gotAllDollars,
            expected: expAllDollars,
            surface: surface,
            language: language,
            lane: "<panel-multiset>",
            field: "allDollarAmountsOnPanel",
            into: &violations
        )

        // 8e. All `<N> tokens [·] unpriced|未计价` occurrences on this panel
        let unpPat = isZh ? #"(\d+)\s*tokens\s*(?:·\s*)?未计价"# : #"(\d+)\s*tokens\s*(?:·\s*)?unpriced"#
        let gotAllUnpriced = try regexCaptures(unpPat, in: uiPDF).map { $0[0] }
        var expAllUnpriced: [String] = []
        if let run, run.unpricedTokens > 0 {
            expAllUnpriced.append("\(run.unpricedTokens)") // Top Bar
        }
        for lane in orderedLanes {
            if let tok = expectedUnpricedTokens(lane) {
                expAllUnpriced.append(tok) // Left Rail
                if surface.rendersPTYGridStage {
                    expAllUnpriced.append(tok) // ⌘1 Terminal Pane Header
                }
            }
        }
        if surface == .dagPipeline, let sel = orderedLanes.first, let selTok = expectedUnpricedTokens(sel) {
            expAllUnpriced.append(selTok) // ⌘2 Inspector
        }
        compareMultiset(
            got: gotAllUnpriced,
            expected: expAllUnpriced,
            surface: surface,
            language: language,
            lane: "<panel-multiset>",
            field: "allUnpricedTokensOnPanel",
            into: &violations
        )

        return violations
    }

    static func verifyKeyFieldsExactEquality(
        pdfByPane rawPDFByPane: [RelayStudioPane: String],
        language: RelayLanguage,
        truth: AuditGroundTruth
    ) throws -> [String] {
        if useLegacyLooseCheckForRedProof {
            return []
        }
        var violations = verifyLedgerAgainstLogMD(truth: truth)
        for pane in RelayStudioPane.allCases {
            guard let pdf = rawPDFByPane[pane] else { continue }
            let errs = try verifySingleRenderKeyFields(
                pdfText: pdf,
                surface: AuditRenderSurface(pane: pane),
                language: language,
                truth: truth
            )
            violations.append(contentsOf: errs)
        }
        return violations
    }
}

// MARK: - Headless Offscreen ImageRenderer (PDF & 2720x1680 Bitmap) + M5 Acceptance Probe

@Suite("M5-03 Tightened Number Provenance Unit Tests & Headless UI Acceptance Probe", .serialized, .timeLimit(.minutes(3)))
struct M5UIAcceptanceTests {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    @MainActor
    private static func enforceZeroWindows() throws {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let count = NSApplication.shared.windows.count
        guard count == 0 else {
            throw NSError(
                domain: "M5UIAcceptanceTests",
                code: 90,
                userInfo: [NSLocalizedDescriptionKey: "Expected 0 NSWindows in headless UI check, found \(count)"]
            )
        }
    }

    @MainActor
    private static func renderPDFText(vm: RelayStudioViewModel) throws -> String {
        try enforceZeroWindows()
        let viewport = CGSize(width: 1360, height: 840)
        let rootView = RelayStudioRootWorkbenchView(viewModel: vm)
            .frame(width: viewport.width, height: viewport.height)
            .environment(\.colorScheme, .light)
            .environment(\.relaySnapshotRenderMode, true)
        let renderer = ImageRenderer(content: rootView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(viewport)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: viewport)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "M5UIAcceptanceTests", code: 91, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PDF CGContext"])
        }
        renderer.render { _, renderInContext in
            pdfCtx.beginPDFPage(nil)
            renderInContext(pdfCtx)
            pdfCtx.endPDFPage()
            pdfCtx.closePDF()
        }
        try enforceZeroWindows()
        return PDFDocument(data: pdfData as Data)?.string ?? ""
    }

    @MainActor
    private static func renderBitmapMetrics(vm: RelayStudioViewModel) throws -> (width: Int, height: Int, distinctRGB: Int) {
        try enforceZeroWindows()
        let viewport = CGSize(width: 1360, height: 840)
        let rootView = RelayStudioRootWorkbenchView(viewModel: vm)
            .frame(width: viewport.width, height: viewport.height)
            .environment(\.colorScheme, .light)
            .environment(\.relaySnapshotRenderMode, true)
        let renderer = ImageRenderer(content: rootView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(viewport)
        guard let cgImage = renderer.cgImage else {
            throw NSError(domain: "M5UIAcceptanceTests", code: 92, userInfo: [NSLocalizedDescriptionKey: "ImageRenderer returned nil cgImage"])
        }
        let w = cgImage.width
        let h = cgImage.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var distinct = Set<UInt32>()
        for y in stride(from: 0, to: h, by: 40) {
            for x in stride(from: 0, to: w, by: 40) {
                let idx = (y * w + x) * 4
                if buf[idx + 3] > 0 {
                    let packed = (UInt32(buf[idx]) << 16) | (UInt32(buf[idx + 1]) << 8) | UInt32(buf[idx + 2])
                    distinct.insert(packed)
                }
            }
        }
        try enforceZeroWindows()
        return (w, h, distinct.count)
    }

    // MARK: - 1. Standalone Unit Test of Tightened Auditor Rules (Runs in `swift test`)

    @Test("Tightened number provenance auditor rejects hex-hash/runID sub-digits and catches DAG laneCount + 7 & key-field mismatches")
    @MainActor
    func tightenedAuditorRejectsHexHashSubDigitsAndDAGPlusSevenMutation() throws {
        try Self.enforceZeroWindows()

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("m5-tight-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        let bundleURL = tmpRoot.appendingPathComponent("Audit.relayproj", isDirectory: true)
        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleURL)

        // Deliberately craft hex commit OIDs and runID containing "11", "7", "9", "42" inside hex segments!
        let sneakyBaseOID = "a11b07c09d42e00f11223344556677889900aabb"
        let sneakyLaneOID = "f11e07d09c42b00a99887766554433221100ccdd"
        let runStart = Date(timeIntervalSince1970: 1_795_340_000.0)
        let runEnd = Date(timeIntervalSince1970: 1_795_340_002.50)

        let lanes: [RelayRunLaneRecord] = try (0..<4).map { idx in
            let lid = "c\(idx + 1)"
            let wtURL = tmpRoot.appendingPathComponent("wt-\(lid)", isDirectory: true)
            let relayDir = wtURL.appendingPathComponent(".relay", isDirectory: true)
            try FileManager.default.createDirectory(at: relayDir, withIntermediateDirectories: true)
            let logBody = (idx % 2 == 0)
                ? "## 01-claude: task, 2s, 2026-11-22 11:07\n- cost $0.1234, tokens 1,500\n"
                : "## 01-agy: task, 2s, 2026-11-22 11:07\n- tokens 4,500\n"
            try logBody.write(to: relayDir.appendingPathComponent("LOG.md"), atomically: true, encoding: .utf8)

            return RelayRunLaneRecord(
                runID: "20261122-110700-a7b9",
                laneID: lid,
                ordinal: idx,
                agent: idx % 2 == 0 ? .claude : .agy,
                promptPath: "/tmp/p\(idx).md",
                after: [],
                status: .succeeded,
                exitCode: 0,
                signal: nil,
                reason: nil,
                startedAt: runStart,
                finishedAt: runEnd,
                pid: nil,
                costUSD: idx % 2 == 0 ? 0.1234 : nil,
                tokens: idx % 2 == 0 ? 1500 : 4500,
                costSource: idx % 2 == 0 ? "usd" : "unpriced",
                branch: "relay/20261122-110700-a7b9/\(lid)",
                commitOID: sneakyLaneOID,
                worktreePath: wtURL.path,
                uncommittedFiles: []
            )
        }
        let runRec = RelayRunRecord(
            runID: "20261122-110700-a7b9",
            repoPath: tmpRoot.path,
            planCopyPath: tmpRoot.appendingPathComponent("plan.json").path,
            baseRef: "main",
            baseCommitOID: sneakyBaseOID,
            verifyCommand: nil,
            relayShPath: "/tmp/relay.sh",
            relayShSHA256: String(repeating: "a711", count: 16),
            startedAt: runStart,
            finishedAt: runEnd,
            status: .succeeded,
            reason: nil,
            relayidePID: 1234,
            budgetUSD: nil,
            lanes: lanes,
            integration: nil
        )
        try db.createRun(runRec)

        let vm = RelayStudioViewModel(
            projectBundleURL: bundleURL,
            initialPane: .dagPipeline,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )
        let truth = try M5NumberProvenanceAndFieldAuditor.collectGroundTruth(bundleURL: bundleURL)

        var pdfByPane: [RelayStudioPane: String] = [:]
        for pane in RelayStudioPane.allCases {
            vm.selectPane(pane)
            let pdf = try Self.renderPDFText(vm: vm)
            pdfByPane[pane] = pdf
            let unmatched = try M5NumberProvenanceAndFieldAuditor.unmatchedNumbersInPDF(
                pdfText: pdf,
                pane: pane,
                hasActiveTerminalRows: (pane == .ptyGrid),
                truth: truth
            )
            #expect(unmatched.isEmpty, "Clean 4-lane render had unmatched tokens on \(pane.rawValue): \(unmatched)")
        }
        let cleanFieldViolations = try M5NumberProvenanceAndFieldAuditor.verifyKeyFieldsExactEquality(
            pdfByPane: pdfByPane,
            language: .en,
            truth: truth
        )
        #expect(cleanFieldViolations.isEmpty, "Clean 4-lane render had field violations: \(cleanFieldViolations)")

        // Now simulate Mutation 5: replace "4 lanes" in DAG header with "11 lanes" (4 + 7 = 11, where "11" is inside sneakyBaseOID & runID!)
        let origDAG = try #require(pdfByPane[.dagPipeline])
        // Replace only the second occurrence (DAG header pill) of "4 lanes" -> "11 lanes"
        var mutatedDAG = origDAG
        if let lastRange = mutatedDAG.range(of: "4 lanes", options: .backwards) {
            mutatedDAG.replaceSubrange(lastRange, with: "11 lanes")
        }
        let mutUnmatched = try M5NumberProvenanceAndFieldAuditor.unmatchedNumbersInPDF(
            pdfText: mutatedDAG,
            pane: .dagPipeline,
            hasActiveTerminalRows: false,
            truth: truth
        )
        var mutMap = pdfByPane
        mutMap[.dagPipeline] = mutatedDAG
        let mutFieldViolations = try M5NumberProvenanceAndFieldAuditor.verifyKeyFieldsExactEquality(
            pdfByPane: mutMap,
            language: .en,
            truth: truth
        )

        // BOTH Part (a) ("11" not leaked from hex OIDs / runID) AND Part (b) (DAG laneCount 11 != 4) MUST catch this!
        #expect(mutUnmatched.contains("11"), "Part (a) failed to reject '11' leaked from hex hash / runID: unmatched=\(mutUnmatched)")
        #expect(!mutFieldViolations.isEmpty, "Part (b) failed to detect DAG header laneCount 11 != SQLite laneCount 4")

        try Self.enforceZeroWindows()
    }

    // MARK: - 2. Headless UI Probe Entry Point for `Scripts/acceptance/m5-ui.sh`

    struct ProbeSpec: Decodable {
        let mode: String
        let projectPath: String?
        let secondProjectPath: String?
        let thirdProjectPath: String?
        let fourthProjectPath: String?
        let expectedConflictFile: String?
        let readyFilePath: String?
        let outputJSONPath: String
        let quick: Bool?
    }

    private static func writeResultJSON(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func extractPlainLines(_ snapshot: TerminalViewportSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        return snapshot.visibleGrid.compactMap { (row: [TerminalCell]) -> String? in
            let s = row.map { $0.grapheme }.joined().trimmingCharacters(in: CharacterSet(charactersIn: " \r\n\t"))
            return s.isEmpty ? nil : s
        }
    }

    @Test("M5 Headless UI Acceptance Probe Dispatcher")
    @MainActor
    func runM5AcceptanceProbe() async throws {
        try Self.enforceZeroWindows()

        guard let specPath = ProcessInfo.processInfo.environment["RELAY_M5_PROBE_SPEC"], !specPath.isEmpty else {
            // Standalone swift test mode: verify default empty headless ViewModel + bitmap + 0 windows
            let vm = RelayStudioViewModel(
                projectBundleURL: nil,
                initialPane: .ptyGrid,
                localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
                loadDemoWorkspace: false
            )
            let bmp = try Self.renderBitmapMetrics(vm: vm)
            #expect(bmp.width == 2720 && bmp.height == 1680 && bmp.distinctRGB >= 8)
            try Self.enforceZeroWindows()
            return
        }

        let specData = try Data(contentsOf: URL(fileURLWithPath: specPath))
        let spec = try JSONDecoder().decode(ProbeSpec.self, from: specData)

        switch spec.mode {
        case "row1_stream":
            try await runRow1StreamProbe(spec)
        case "row2_refused":
            try runRow2RefusedProbe(spec)
        case "row3_four_lanes":
            try await runRow3FourLanesProbe(spec)
        case "row4_ownership":
            try await runRow4OwnershipProbe(spec)
        case "row5_merge":
            try runRow5MergeProbe(spec)
        case "row6_number_audit":
            try runRow6NumberAuditProbe(spec)
        case "row7_raster":
            try runRow7RasterProbe(spec)
        default:
            throw NSError(domain: "M5UIAcceptanceTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown probe mode \(spec.mode)"])
        }

        try Self.enforceZeroWindows()
    }

    // --- Row 1: 2-lane streaming every <= 250ms, < 1.0s per line, matches .relay/*.log ---
    @MainActor
    private func runRow1StreamProbe(_ spec: ProbeSpec) async throws {
        let bundleURL = URL(fileURLWithPath: try #require(spec.projectPath), isDirectory: true)
        let vm = RelayStudioViewModel(
            projectBundleURL: bundleURL,
            initialPane: .ptyGrid,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )
        if let ready = spec.readyFilePath {
            try "ready\n".write(toFile: ready, atomically: true, encoding: .utf8)
        }

        var firstSeenEpoch: [String: [Int: Double]] = ["lane-claude": [:], "lane-vibe": [:]]
        var emitEpoch: [String: [Int: Double]] = ["lane-claude": [:], "lane-vibe": [:]]
        var distinctNonEmptyCounts: [String: Set<Int>] = ["lane-claude": [], "lane-vibe": []]
        var midRunPDFVerified = false

        let deadline = Date().addingTimeInterval(25.0)
        while Date() < deadline {
            let now = Date().timeIntervalSince1970
            for laneID in ["lane-claude", "lane-vibe"] {
                let lines = Self.extractPlainLines(vm.terminalSnapshotsByLane[laneID])
                let streamLines = lines.filter { $0.contains("STREAM lane=\(laneID) seq=") }
                if !streamLines.isEmpty {
                    distinctNonEmptyCounts[laneID, default: []].insert(streamLines.count)
                }
                for line in streamLines {
                    for seq in 1...4 where line.contains("seq=\(seq) ") {
                        if firstSeenEpoch[laneID]?[seq] == nil {
                            firstSeenEpoch[laneID, default: [:]][seq] = now
                            if let r = line.range(of: "emit=") {
                                let numPart = line[r.upperBound...].split(separator: " ").first ?? ""
                                if let em = Double(numPart) {
                                    emitEpoch[laneID, default: [:]][seq] = em
                                }
                            }
                        }
                    }
                }
            }

            let cCount = firstSeenEpoch["lane-claude"]?.count ?? 0
            let vCount = firstSeenEpoch["lane-vibe"]?.count ?? 0
            if !midRunPDFVerified && cCount >= 1 && cCount < 4 && vCount >= 1 && vCount < 4 {
                let pdf = try Self.renderPDFText(vm: vm)
                if pdf.contains("STREAM lane=lane-claude seq=1") && pdf.contains("STREAM lane=lane-vibe seq=1") && !pdf.contains("seq=4") {
                    midRunPDFVerified = true
                }
            }

            if let run = vm.activeRun, run.status.isTerminal, cCount == 4, vCount == 4 {
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000) // 150ms (<= 250ms requirement)
        }

        // Give final drain 100ms then render final PDF
        try await Task.sleep(nanoseconds: 100_000_000)
        let finalPDF = try Self.renderPDFText(vm: vm)

        var maxLatency = 0.0
        var latenciesDesc: [String] = []
        var violations: [String] = []

        for laneID in ["lane-claude", "lane-vibe"] {
            let steps = distinctNonEmptyCounts[laneID]?.count ?? 0
            if steps < 3 {
                violations.append("Lane \(laneID) did not stream progressively (distinctCounts=\(distinctNonEmptyCounts[laneID] ?? []))")
            }
            for seq in 1...4 {
                guard let obs = firstSeenEpoch[laneID]?[seq], let em = emitEpoch[laneID]?[seq] else {
                    violations.append("Missing streamed line \(laneID) seq=\(seq)")
                    continue
                }
                let lat = obs - em
                maxLatency = max(maxLatency, lat)
                latenciesDesc.append("\(laneID)#\(seq)=\(String(format: "%.3fs", lat))")
                if lat < 0.0 || lat > 1.0 {
                    violations.append("Lane \(laneID) seq=\(seq) latency \(String(format: "%.3fs", lat)) exceeded 1.0s")
                }
                if !finalPDF.contains("STREAM lane=\(laneID) seq=\(seq)") {
                    violations.append("Final PDF missing STREAM lane=\(laneID) seq=\(seq)")
                }
            }
        }
        if !midRunPDFVerified {
            violations.append("Mid-run PDF did not show partial streamed lines before seq=4")
        }

        // Verify exact match against <worktree>/.relay/01-<agent>.log
        if let run = vm.activeRun {
            for lane in run.lanes {
                let wtURL = URL(fileURLWithPath: try #require(lane.worktreePath), isDirectory: true)
                let relayDir = wtURL.appendingPathComponent(".relay", isDirectory: true)
                let logFiles = (try? FileManager.default.contentsOfDirectory(at: relayDir, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "log" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
                guard let firstLog = logFiles.first,
                      let rawLog = try? String(contentsOf: firstLog, encoding: .utf8) else {
                    violations.append("Missing .relay/*.log for \(lane.laneID)")
                    continue
                }
                let snapLines = Self.extractPlainLines(vm.terminalSnapshotsByLane[lane.laneID]).joined(separator: "\n")
                for seq in 1...4 {
                    let token = "STREAM lane=\(lane.laneID) seq=\(seq) emit="
                    if !rawLog.contains(token) {
                        violations.append(".relay/*.log for \(lane.laneID) missing \(token)")
                    }
                    if !snapLines.contains(token) {
                        violations.append("Terminal buffer for \(lane.laneID) missing \(token) from .relay/*.log")
                    }
                }
            }
        } else {
            violations.append("vm.activeRun was nil")
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "maxLatencySec": maxLatency,
            "latencies": latenciesDesc,
            "midRunPDFVerified": midRunPDFVerified,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 1 violations: \(violations)")
    }

    // --- Row 2: Refused lane without .relay/*.log shows lanes/<b>.pty refusal reason ---
    @MainActor
    private func runRow2RefusedProbe(_ spec: ProbeSpec) throws {
        let bundleURL = URL(fileURLWithPath: try #require(spec.projectPath), isDirectory: true)
        var violations: [String] = []

        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let vm = RelayStudioViewModel(
                projectBundleURL: bundleURL,
                initialPane: .ptyGrid,
                localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                loadDemoWorkspace: false
            )
            let laneB = vm.liveRunLane(forID: "b")
            if laneB?.status != .refused {
                violations.append("Expected lane b status=refused, got \(String(describing: laneB?.status))")
            }
            if laneB?.exitCode != 2 {
                violations.append("Expected lane b exitCode=2, got \(String(describing: laneB?.exitCode))")
            }
            let bLines = Self.extractPlainLines(vm.terminalSnapshotsByLane["b"]).joined(separator: "\n")
            if !bLines.contains("not started: the job budget") {
                violations.append("Lane b terminal buffer missing lanes/b.pty refusal message: '\(bLines)'")
            }
            let pdf = try Self.renderPDFText(vm: vm)
            if !pdf.contains("not started: the job budget") {
                violations.append("PDF (\(lang.rawValue)) missing 'not started: the job budget'")
            }
            let expExit = lang.isChinese ? "退出码 2" : "exit 2"
            if !pdf.contains(expExit) {
                violations.append("PDF (\(lang.rawValue)) missing '\(expExit)'")
            }
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 2 violations: \(violations)")
    }

    // --- Row 3: 4-lane completion updates UI & PDF within < 2.0s ---
    @MainActor
    private func runRow3FourLanesProbe(_ spec: ProbeSpec) async throws {
        let bundleURL = URL(fileURLWithPath: try #require(spec.projectPath), isDirectory: true)
        let vm = RelayStudioViewModel(
            projectBundleURL: bundleURL,
            initialPane: .ptyGrid,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )

        var laneObservedTerminalEpoch: [String: Double] = [:]
        let cancellable = vm.$liveRunLanesByID.sink { map in
            let now = Date().timeIntervalSince1970
            for (lid, rec) in map where rec.status.isTerminal && rec.exitCode != nil && rec.finishedAt != nil {
                if laneObservedTerminalEpoch[lid] == nil {
                    laneObservedTerminalEpoch[lid] = now
                }
            }
        }
        defer { cancellable.cancel() }

        if let ready = spec.readyFilePath {
            try "ready\n".write(toFile: ready, atomically: true, encoding: .utf8)
        }

        var pdfAllFourEpoch: Double?
        let deadline = Date().addingTimeInterval(25.0)
        while Date() < deadline {
            if laneObservedTerminalEpoch.count == 4 && abs(vm.totalWorkspaceSpendUSD - 0.3734) < 1e-6 {
                let pdf = try Self.renderPDFText(vm: vm)
                if pdf.contains("$0.3734")
                    && pdf.contains("$0.1234")
                    && pdf.contains("$0.2500")
                    && pdf.contains("4500")
                    && pdf.contains("1200")
                    && pdf.contains("unpriced")
                    && pdf.contains("failed")
                    && pdf.contains("exit 3")
                    && !pdf.contains("/ $0.00")
                    && !pdf.contains("$0.00") {
                    pdfAllFourEpoch = Date().timeIntervalSince1970
                    break
                }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        // Also check ZH rendering
        var violations: [String] = []
        if pdfAllFourEpoch == nil {
            violations.append("Timed out waiting for all 4 lanes to render status/exitCode/spend/unpriced tokens in PDF")
        } else {
            vm.setLanguage(.zhHans, postToast: false)
            let zhPDF = try Self.renderPDFText(vm: vm)
            for req in ["$0.1234", "$0.2500", "$0.3734", "4500", "1200", "未计价", "失败", "退出码 3"] where !zhPDF.contains(req) {
                violations.append("ZH PDF missing '\(req)'")
            }
            if zhPDF.contains("$0.00") || zhPDF.contains("/ $0.00") {
                violations.append("ZH PDF rendered forbidden '$0.00'")
            }
            for lid in ["c1", "v1", "a1", "x1"] {
                guard let dur = vm.formattedLiveLaneDuration(forLane: lid), dur != "0.00s" else {
                    violations.append("Lane \(lid) missing non-zero duration: \(String(describing: vm.formattedLiveLaneDuration(forLane: lid)))")
                    continue
                }
            }
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "laneObservedEpochs": laneObservedTerminalEpoch,
            "pdfAllFourEpoch": pdfAllFourEpoch as Any,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 3 violations: \(violations)")
    }

    // --- Row 4: File ownership refreshes tracked edit & new untracked file within < 2.0s ---
    @MainActor
    private func runRow4OwnershipProbe(_ spec: ProbeSpec) async throws {
        let bundleURL = URL(fileURLWithPath: try #require(spec.projectPath), isDirectory: true)
        let vm = RelayStudioViewModel(
            projectBundleURL: bundleURL,
            initialPane: .territoryMap,
            localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
            loadDemoWorkspace: false
        )
        vm.selectPane(.territoryMap)

        var violations: [String] = []
        let initialPDF = try Self.renderPDFText(vm: vm)
        if !initialPDF.contains("AlphaOwned.swift") {
            violations.append("Committed lane file AlphaOwned.swift missing before manual edits")
        }

        if let ready = spec.readyFilePath {
            try "ready\n".write(toFile: ready, atomically: true, encoding: .utf8)
        }

        var trackedVMEpoch: Double?
        var trackedPDFEpoch: Double?
        var untrackedVMEpoch: Double?
        var untrackedPDFEpoch: Double?

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if let snap = vm.liveFileOwnershipByLane["lane-own-a"] {
                if trackedVMEpoch == nil,
                   snap.files.contains(where: { $0.relativePath == "App.swift" && $0.worktreeState == .uncommittedInWorktree }) {
                    trackedVMEpoch = Date().timeIntervalSince1970
                }
                if trackedVMEpoch != nil && trackedPDFEpoch == nil {
                    let pdf = try Self.renderPDFText(vm: vm)
                    if pdf.contains("App.swift") && pdf.contains("uncommitted") {
                        trackedPDFEpoch = Date().timeIntervalSince1970
                    }
                }
                if untrackedVMEpoch == nil,
                   snap.files.contains(where: { $0.relativePath == "ManualOwnershipProbe.swift" }) {
                    untrackedVMEpoch = Date().timeIntervalSince1970
                }
                if untrackedVMEpoch != nil && untrackedPDFEpoch == nil {
                    let pdf = try Self.renderPDFText(vm: vm)
                    if pdf.contains("ManualOwnershipProbe.swift") {
                        untrackedPDFEpoch = Date().timeIntervalSince1970
                    }
                }
                if snap.files.contains(where: { $0.relativePath.contains(".relay") || $0.relativePath.contains(".git") }) {
                    violations.append(".relay or .git internal path leaked into liveFileOwnershipByLane")
                }
            }
            if trackedPDFEpoch != nil && untrackedPDFEpoch != nil {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let finalPDF = try Self.renderPDFText(vm: vm)
        if finalPDF.contains("99-noise.log") {
            violations.append(".relay/99-noise.log leaked into ⌘4 PDF")
        }
        if !finalPDF.contains("AlphaOwned.swift") {
            violations.append("Committed file AlphaOwned.swift disappeared after manual edits")
        }
        if trackedPDFEpoch == nil {
            violations.append("Tracked edit App.swift did not appear in ⌘4 PDF before timeout")
        }
        if untrackedPDFEpoch == nil {
            violations.append("Untracked file ManualOwnershipProbe.swift did not appear in ⌘4 PDF before timeout")
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "trackedVMEpoch": trackedVMEpoch as Any,
            "trackedPDFEpoch": trackedPDFEpoch as Any,
            "untrackedVMEpoch": untrackedVMEpoch as Any,
            "untrackedPDFEpoch": untrackedPDFEpoch as Any,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 4 violations: \(violations)")
    }

    // --- Row 5: Merge view shows M2 verified result + git merge-file -p conflicts & R74 clean ---
    @MainActor
    private func runRow5MergeProbe(_ spec: ProbeSpec) throws {
        let cleanURL = URL(fileURLWithPath: try #require(spec.projectPath), isDirectory: true)
        let conflictURL = URL(fileURLWithPath: try #require(spec.secondProjectPath), isDirectory: true)
        let expectedConflictText = try String(contentsOfFile: try #require(spec.expectedConflictFile), encoding: .utf8)
        var violations: [String] = []

        // 1. Clean verified run (EN & ZH)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let vm = RelayStudioViewModel(
                projectBundleURL: cleanURL,
                initialPane: .semanticMerge,
                localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                loadDemoWorkspace: false
            )
            vm.selectPane(.semanticMerge)
            let pdf = try Self.renderPDFText(vm: vm)
            _ = try Self.renderBitmapMetrics(vm: vm)
            for req in ["verified", "ready: true", "VERIFY_M5_OK"] where !pdf.contains(req) {
                violations.append("Clean merge PDF (\(lang.rawValue)) missing '\(req)'")
            }
            for step in vm.activeRun?.integration?.merges ?? [] {
                if let mOID = step.mergeCommitOID, !pdf.contains(mOID) {
                    violations.append("Clean merge PDF (\(lang.rawValue)) missing mergeCommitOID \(mOID)")
                }
            }
            if pdf.contains("Accept Left") || pdf.contains("采用左侧") {
                violations.append("Non-demo merge view leaked demo interactive AST buttons")
            }
        }

        // 2. Conflict run vs independent `git merge-file -p` (EN & ZH)
        for lang in [RelayLanguage.en, RelayLanguage.zhHans] {
            let vm = RelayStudioViewModel(
                projectBundleURL: conflictURL,
                initialPane: .semanticMerge,
                localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                loadDemoWorkspace: false
            )
            vm.selectPane(.semanticMerge)
            if vm.liveConflictBlocks.first?.conflictText != expectedConflictText {
                violations.append("liveConflictBlocks.first.conflictText != independent git merge-file -p output")
            }
            let pdf = try Self.renderPDFText(vm: vm)
            _ = try Self.renderBitmapMetrics(vm: vm)
            for req in ["conflict", "ready: false", "UU App.swift", "<<<<<<< integration", "=======", ">>>>>>>"] where !pdf.contains(req) {
                violations.append("Conflict merge PDF (\(lang.rawValue)) missing '\(req)'")
            }
            for line in expectedConflictText.split(whereSeparator: \.isNewline).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !pdf.contains(trimmed) {
                    violations.append("Conflict merge PDF (\(lang.rawValue)) missing git merge-file line '\(trimmed)'")
                }
            }
        }

        // 3. Static R74 scan across Sources/**/*.swift
        let sourcesDir = Self.repositoryRootURL.appendingPathComponent("Sources", isDirectory: true)
        if let en = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in en where fileURL.pathExtension == "swift" {
                let src = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                for forbidden in ["autoRunSemanticMergeOnHandoff", "passedTestCount: 18", "passedTestCount: 24", "18/18"] where src.contains(forbidden) {
                    violations.append("R74 forbidden token '\(forbidden)' found in \(fileURL.lastPathComponent)")
                }
            }
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 5 violations: \(violations)")
    }

    // --- Row 6: Tightened non-demo number provenance + key-field exact equality + --demo isolation ---
    @MainActor
    private func runRow6NumberAuditProbe(_ spec: ProbeSpec) throws {
        let isQuick = spec.quick ?? false
        let languages: [RelayLanguage] = isQuick ? [.en] : [.en, .zhHans]

        struct WorkspaceTarget {
            let label: String
            let bundleURL: URL?
        }

        var targets: [WorkspaceTarget] = [
            WorkspaceTarget(label: "default-empty-launch", bundleURL: nil)
        ]
        for p in [spec.projectPath, spec.secondProjectPath, spec.thirdProjectPath, spec.fourthProjectPath].compactMap({ $0 }) where !p.isEmpty {
            let url = URL(fileURLWithPath: p, isDirectory: true)
            targets.append(WorkspaceTarget(label: url.lastPathComponent, bundleURL: url))
        }

        var violations: [String] = []
        var auditedPaneRenders = 0

        for target in targets {
            for (langIdx, lang) in languages.enumerated() {
                let vm = RelayStudioViewModel(
                    projectBundleURL: target.bundleURL,
                    initialPane: .ptyGrid,
                    localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                    loadDemoWorkspace: false
                )
                let truth = try M5NumberProvenanceAndFieldAuditor.collectGroundTruth(bundleURL: vm.projectBundleURL)
                if langIdx == 0 {
                    for err in M5NumberProvenanceAndFieldAuditor.verifyLedgerAgainstLogMD(truth: truth) {
                        violations.append("[\(target.label)] \(err)")
                    }
                }

                for pane in RelayStudioPane.allCases {
                    vm.selectPane(pane)
                    let pdf = try Self.renderPDFText(vm: vm)
                    auditedPaneRenders += 1

                    let unmatched = try M5NumberProvenanceAndFieldAuditor.unmatchedNumbersInPDF(
                        pdfText: pdf,
                        pane: pane,
                        hasActiveTerminalRows: (pane == .ptyGrid && !vm.lanes.isEmpty),
                        truth: truth
                    )
                    if !unmatched.isEmpty {
                        violations.append("[\(target.label)/\(pane.rawValue)/\(lang.rawValue)] ungrounded numbers: \(unmatched)")
                    }
                    let fieldErrs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(
                        pdfText: pdf,
                        surface: .init(pane: pane),
                        language: lang,
                        truth: truth
                    )
                    for err in fieldErrs {
                        violations.append("[\(target.label)] \(err)")
                    }
                }

                // Also audit expanded Bottom Drawer & ⌘, Preferences modal as individual single-panel renders
                vm.selectPane(.ptyGrid)
                vm.isBottomDrawerPresented = true
                let drawerPDF = try Self.renderPDFText(vm: vm)
                auditedPaneRenders += 1
                let drawerUnmatched = try M5NumberProvenanceAndFieldAuditor.unmatchedNumbersInPDF(
                    pdfText: drawerPDF,
                    pane: .ptyGrid,
                    hasActiveTerminalRows: !vm.lanes.isEmpty,
                    truth: truth
                )
                if !drawerUnmatched.isEmpty {
                    violations.append("[\(target.label)/bottomDrawer/\(lang.rawValue)] ungrounded numbers: \(drawerUnmatched)")
                }
                for err in try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(
                    pdfText: drawerPDF,
                    surface: .bottomDrawer,
                    language: lang,
                    truth: truth
                ) {
                    violations.append("[\(target.label)] \(err)")
                }
                vm.isBottomDrawerPresented = false

                vm.isPreferencesModalPresented = true
                let prefsPDF = try Self.renderPDFText(vm: vm)
                auditedPaneRenders += 1
                let prefsUnmatched = try M5NumberProvenanceAndFieldAuditor.unmatchedNumbersInPDF(
                    pdfText: prefsPDF,
                    pane: .ptyGrid,
                    hasActiveTerminalRows: !vm.lanes.isEmpty,
                    truth: truth
                )
                if !prefsUnmatched.isEmpty {
                    violations.append("[\(target.label)/preferencesModal/\(lang.rawValue)] ungrounded numbers: \(prefsUnmatched)")
                }
                for err in try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(
                    pdfText: prefsPDF,
                    surface: .preferencesModal,
                    language: lang,
                    truth: truth
                ) {
                    violations.append("[\(target.label)] \(err)")
                }
                vm.isPreferencesModalPresented = false
            }
        }

        // Verify explicit --demo mode still displays [DEMO] / [演示数据] and never pollutes user EmptyInit.relayproj
        for lang in languages {
            let demoVM = RelayStudioViewModel(
                projectBundleURL: spec.projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
                initialPane: .ptyGrid,
                localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                loadDemoWorkspace: true
            )
            let demoPDF = try Self.renderPDFText(vm: demoVM)
            let expBadge = lang.isChinese ? "[演示数据]" : "[DEMO]"
            if !demoPDF.contains(expBadge) {
                violations.append("Demo mode PDF (\(lang.rawValue)) missing '\(expBadge)'")
            }
        }
        if let emptyInitPath = spec.projectPath, !emptyInitPath.isEmpty {
            let checkDB = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: emptyInitPath, isDirectory: true))
            let stats = try checkDB.computeStats()
            if stats.activeLaneCount != 0 || stats.totalSpendUSD != 0 {
                violations.append("User EmptyInit.relayproj was polluted by --demo preview: \(stats)")
            }
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "auditedRenders": auditedPaneRenders,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 6 violations: \(violations)")
    }

    // --- Row 7: 2720x1680 rasterization across all panes & 0 windows ---
    @MainActor
    private func runRow7RasterProbe(_ spec: ProbeSpec) throws {
        let liveURL = spec.projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var violations: [String] = []
        var minDistinctRGB = Int.max
        var checkedBitmaps = 0

        for (label, url, demo) in [
            ("empty", nil as URL?, false),
            ("live", liveURL, false),
            ("demo", nil as URL?, true)
        ] {
            let vm = RelayStudioViewModel(
                projectBundleURL: url,
                initialPane: .ptyGrid,
                localizer: RelayLocalizer(language: .en, persistToUserDefaults: false),
                loadDemoWorkspace: demo
            )
            for pane in RelayStudioPane.allCases {
                vm.selectPane(pane)
                let m = try Self.renderBitmapMetrics(vm: vm)
                checkedBitmaps += 1
                minDistinctRGB = min(minDistinctRGB, m.distinctRGB)
                if m.width != 2720 || m.height != 1680 {
                    violations.append("[\(label)/\(pane.rawValue)] bitmap dimensions \(m.width)x\(m.height) != 2720x1680")
                }
                if m.distinctRGB < 8 {
                    violations.append("[\(label)/\(pane.rawValue)] blank/low-diversity bitmap distinctRGB=\(m.distinctRGB)")
                }
            }
        }

        try Self.enforceZeroWindows()
        try Self.writeResultJSON([
            "ok": violations.isEmpty,
            "checkedBitmaps": checkedBitmaps,
            "minDistinctRGB": minDistinctRGB,
            "windowCount": NSApplication.shared.windows.count,
            "violations": violations
        ], to: spec.outputJSONPath)
        #expect(violations.isEmpty, "Row 7 violations: \(violations)")
    }

    @Test("Per-pane key-field auditor verifies all 7 surfaces in EN/ZH and catches Mutations 7, 8, 9, ⌘4 counts, and 3-decimal spend")
    @MainActor
    func perPaneFieldAuditorCatchesExitCodeDAGDurationOwnershipStatusAndSpendMutations() throws {
        try Self.enforceZeroWindows()
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("m5-per-pane-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        let repoURL = tmpRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        func git(_ args: [String], cwd: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid"] + args
            p.currentDirectoryURL = cwd
            try p.run()
            p.waitUntilExit()
        }
        try git(["init", "-b", "main"], cwd: repoURL)
        try "line1\nline2\n".write(to: repoURL.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try git(["add", "App.swift"], cwd: repoURL)
        try git(["commit", "-m", "init"], cwd: repoURL)
        let outP = Pipe()
        let revP = Process()
        revP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        revP.arguments = ["rev-parse", "HEAD"]
        revP.currentDirectoryURL = repoURL
        revP.standardOutput = outP
        try revP.run()
        revP.waitUntilExit()
        let baseOID = String(data: outP.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)

        let wtC1 = tmpRoot.appendingPathComponent("wt-c1", isDirectory: true)
        let wtV1 = tmpRoot.appendingPathComponent("wt-v1", isDirectory: true)
        let wtA1 = tmpRoot.appendingPathComponent("wt-a1", isDirectory: true)
        let wtX1 = tmpRoot.appendingPathComponent("wt-x1", isDirectory: true)
        for (id, wt) in [("c1", wtC1), ("v1", wtV1), ("a1", wtA1), ("x1", wtX1)] {
            try git(["worktree", "add", "-b", "relay/r1/\(id)", wt.path, baseOID], cwd: repoURL)
            try FileManager.default.createDirectory(at: wt.appendingPathComponent(".relay"), withIntermediateDirectories: true)
        }
        try "committed c1\n".write(to: wtC1.appendingPathComponent("C1.swift"), atomically: true, encoding: .utf8)
        try git(["add", "C1.swift"], cwd: wtC1)
        try git(["commit", "-m", "c1"], cwd: wtC1)
        try "line1\nmodified uncommitted\nline3\n".write(to: wtC1.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try "## 01-claude: t, 2s, 2026-11-22 11:07\n- cost $0.1234, tokens 1,500\n".write(to: wtC1.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        try "{\"result\":\"Completed c1\\nSTATUS: success\"}\n".write(to: wtC1.appendingPathComponent(".relay/01-claude.log"), atomically: true, encoding: .utf8)
        try "## 01-vibe: t, 2s, 2026-11-22 11:07\n- cost $0.2500, tokens 900\n".write(to: wtV1.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        try "[{\"content\":\"Completed v1\\nSTATUS: failed\"}]\n".write(to: wtV1.appendingPathComponent(".relay/01-vibe.log"), atomically: true, encoding: .utf8)
        try "committed a1\nl2\n".write(to: wtA1.appendingPathComponent("A1.swift"), atomically: true, encoding: .utf8)
        try git(["add", "A1.swift"], cwd: wtA1)
        try git(["commit", "-m", "a1"], cwd: wtA1)
        try "## 01-agy: t, 2s, 2026-11-22 11:07\n- tokens 4,500\n".write(to: wtA1.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        try "{\"status\":\"SUCCESS\"}\n".write(to: wtA1.appendingPathComponent(".relay/01-agy.log"), atomically: true, encoding: .utf8)

        let bundleURL = tmpRoot.appendingPathComponent("PerPane.relayproj", isDirectory: true)
        let db = try RelayProjectDatabase(bundleDirectoryURL: bundleURL)
        let runID = "20261122-120000-abcd"
        let lanesDir = bundleURL.appendingPathComponent("runs/\(runID)/lanes", isDirectory: true)
        try FileManager.default.createDirectory(at: lanesDir, withIntermediateDirectories: true)
        try "not started: the job budget ($0.2000) was exhausted\n".write(to: lanesDir.appendingPathComponent("x1.pty"), atomically: true, encoding: .utf8)

        let t0 = Date(timeIntervalSince1970: 1_795_340_000.0)
        let lanes: [RelayRunLaneRecord] = [
            RelayRunLaneRecord(runID: runID, laneID: "c1", ordinal: 0, agent: .claude, promptPath: "/tmp/c1.md", after: [], status: .succeeded, exitCode: 0, signal: nil, reason: nil, startedAt: t0, finishedAt: t0.addingTimeInterval(1.25), pid: nil, costUSD: 0.1234, tokens: 1500, costSource: "usd", branch: "relay/r1/c1", commitOID: baseOID, worktreePath: wtC1.path, uncommittedFiles: ["App.swift"]),
            RelayRunLaneRecord(runID: runID, laneID: "v1", ordinal: 1, agent: .vibe, promptPath: "/tmp/v1.md", after: [], status: .failed, exitCode: 3, signal: nil, reason: nil, startedAt: t0.addingTimeInterval(0.10), finishedAt: t0.addingTimeInterval(2.40), pid: nil, costUSD: 0.2500, tokens: 900, costSource: "usd", branch: "relay/r1/v1", commitOID: baseOID, worktreePath: wtV1.path, uncommittedFiles: []),
            RelayRunLaneRecord(runID: runID, laneID: "a1", ordinal: 2, agent: .agy, promptPath: "/tmp/a1.md", after: ["c1"], status: .succeeded, exitCode: 0, signal: nil, reason: nil, startedAt: t0.addingTimeInterval(1.30), finishedAt: t0.addingTimeInterval(3.05), pid: nil, costUSD: nil, tokens: 4500, costSource: "unpriced", branch: "relay/r1/a1", commitOID: baseOID, worktreePath: wtA1.path, uncommittedFiles: []),
            RelayRunLaneRecord(runID: runID, laneID: "x1", ordinal: 3, agent: .codex, promptPath: "/tmp/x1.md", after: ["v1"], status: .refused, exitCode: 2, signal: nil, reason: "budget", startedAt: t0.addingTimeInterval(2.45), finishedAt: t0.addingTimeInterval(2.45), pid: nil, costUSD: nil, tokens: nil, costSource: nil, branch: "relay/r1/x1", commitOID: baseOID, worktreePath: wtX1.path, uncommittedFiles: []),
        ]
        let integ = RelayRunIntegrationRecord(
            branch: "relay/r1/integration",
            worktreePath: repoURL.path,
            baseCommitOID: baseOID,
            headCommitOID: baseOID,
            status: .verified,
            reason: nil,
            ready: true,
            merges: [
                RelayRunMergeRecord(ordinal: 0, laneID: "c1", laneCommitOID: baseOID, status: .merged, mergeCommitOID: baseOID, conflicts: []),
                RelayRunMergeRecord(ordinal: 1, laneID: "a1", laneCommitOID: baseOID, status: .merged, mergeCommitOID: baseOID, conflicts: []),
            ],
            verify: RelayRunVerifyRecord(command: "echo ok", timeoutSec: 60, status: .passed, exitCode: 0, signal: nil, pid: nil, startedAt: t0.addingTimeInterval(3.20), finishedAt: t0.addingTimeInterval(3.55), logPath: nil)
        )
        let runRec = RelayRunRecord(runID: runID, repoPath: repoURL.path, planCopyPath: "/tmp/plan.json", baseRef: "main", baseCommitOID: baseOID, verifyCommand: "echo ok", relayShPath: "/tmp/relay.sh", relayShSHA256: String(repeating: "ab12", count: 16), startedAt: t0, finishedAt: t0.addingTimeInterval(3.60), status: .partial, reason: nil, relayidePID: 99, budgetUSD: 0.80, lanes: lanes, integration: integ)
        try db.createRun(runRec)

        let truth = try M5NumberProvenanceAndFieldAuditor.collectGroundTruth(bundleURL: bundleURL)
        #expect(M5NumberProvenanceAndFieldAuditor.verifyLedgerAgainstLogMD(truth: truth).isEmpty)

        var enPDFs: [M5NumberProvenanceAndFieldAuditor.AuditRenderSurface: String] = [:]
        var zhPDFs: [M5NumberProvenanceAndFieldAuditor.AuditRenderSurface: String] = [:]

        for lang in [RelayLanguage.en, .zhHans] {
            let vm = RelayStudioViewModel(projectBundleURL: bundleURL, initialPane: .ptyGrid, localizer: RelayLocalizer(language: lang, persistToUserDefaults: false), loadDemoWorkspace: false)
            for pane in RelayStudioPane.allCases {
                vm.selectPane(pane)
                let pdf = try Self.renderPDFText(vm: vm)
                let surf = M5NumberProvenanceAndFieldAuditor.AuditRenderSurface(pane: pane)
                if lang == .en { enPDFs[surf] = pdf } else { zhPDFs[surf] = pdf }
                let errs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: pdf, surface: surf, language: lang, truth: truth)
                #expect(errs.isEmpty, "Clean \(surf.rawValue)/\(lang.rawValue) had violations: \(errs)")
            }
            vm.selectPane(.ptyGrid)
            vm.isBottomDrawerPresented = true
            let drawerPDF = try Self.renderPDFText(vm: vm)
            #expect(try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: drawerPDF, surface: .bottomDrawer, language: lang, truth: truth).isEmpty)
            vm.isBottomDrawerPresented = false

            vm.isPreferencesModalPresented = true
            let prefsPDF = try Self.renderPDFText(vm: vm)
            #expect(try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: prefsPDF, surface: .preferencesModal, language: lang, truth: truth).isEmpty)
            vm.isPreferencesModalPresented = false
        }

        // Mutation 7 simulation: ⌘1 terminal header exit code changed from `exit 0` -> `exit 1` (`abs(0 - 1)`) while Left Rail still shows `exit 0`
        let ptyEN = try #require(enPDFs[.ptyGrid])
        let mut7PDF = ptyEN.replacingOccurrences(of: "Claude Code · c1 succeeded · exit 0", with: "Claude Code · c1 succeeded · exit 1")
        let mut7Errs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: mut7PDF, surface: .ptyGrid, language: .en, truth: truth)
        #expect(mut7Errs.contains { $0.contains("pane=ptyGrid") && $0.contains("lane=c1") && $0.contains("field=ptyHeaderExitCode") }, "Mut7 errs: \(mut7Errs)")

        // Mutation 8 simulation: ⌘2 DAG node duration +0.01s (`1.25s` -> `1.26s`) while Left Rail & Inspector still show `1.25s`
        let dagEN = try #require(enPDFs[.dagPipeline])
        let mut8PDF = dagEN.replacingOccurrences(of: "+0.00s → +1.25s · 1.25s", with: "+0.00s → +1.25s · 1.26s")
        let mut8Errs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: mut8PDF, surface: .dagPipeline, language: .en, truth: truth)
        #expect(mut8Errs.contains { $0.contains("pane=dagPipeline") && $0.contains("lane=c1") && $0.contains("field=dagNodeTiming") }, "Mut8 errs: \(mut8Errs)")

        // Mutation 9 simulation: ⌘4 ownership card status flipped (`CLAUDE c1 succeeded` -> `CLAUDE c1 failed`) while Left Rail still shows `c1 succeeded`
        let ownEN = try #require(enPDFs[.territoryMap])
        let mut9PDF = ownEN.replacingOccurrences(of: "CLAUDE c1 succeeded", with: "CLAUDE c1 failed")
        let mut9Errs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: mut9PDF, surface: .territoryMap, language: .en, truth: truth)
        #expect(mut9Errs.contains { $0.contains("pane=territoryMap") && $0.contains("lane=c1") && $0.contains("field=ownershipCardStatus") }, "Mut9 errs: \(mut9Errs)")

        // Uncommitted count +1 & 3-decimal spend simulation
        let mutUncommPDF = ownEN.replacingOccurrences(of: "2 committed · 1 uncommitted", with: "2 committed · 2 uncommitted")
        let mutUncommErrs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: mutUncommPDF, surface: .territoryMap, language: .en, truth: truth)
        #expect(mutUncommErrs.contains { $0.contains("field=committedUncommittedSummary") }, "Uncommitted errs: \(mutUncommErrs)")

        let mut3DecPDF = ptyEN.replacingOccurrences(of: "Claude Code · c1 succeeded · exit 0 1.25s $0.1234", with: "Claude Code · c1 succeeded · exit 0 1.25s $0.123")
        let mut3DecErrs = try M5NumberProvenanceAndFieldAuditor.verifySingleRenderKeyFields(pdfText: mut3DecPDF, surface: .ptyGrid, language: .en, truth: truth)
        #expect(mut3DecErrs.contains { $0.contains("lane=c1") && $0.contains("field=ptyHeaderSpendUSD") }, "3-decimal errs: \(mut3DecErrs)")

        try Self.enforceZeroWindows()
    }
}
