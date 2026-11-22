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
        /// Legacy loose set used ONLY during Step 1A RED demonstration.
        let legacyLooseNumbers: Set<String>
        let legacyTerminalLogText: String
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
                    let vtLines = refVT.snapshot().visibleGrid.map { row in
                        row.map { $0.grapheme }.joined().trimmingCharacters(in: .whitespaces)
                    }.joined(separator: "\n")
                    if !vtLines.isEmpty {
                        ptyNums.formUnion(try extractSafeLogNumbers(from: vtLines, strippingIdentifiers: sortedIdents))
                    }
                }

                // Collect verify.pty & conflict block numbers strictly scoped to `.semanticMerge`
                if let integ = run.integration {
                    for blk in reconstructedConflicts {
                        if let text = blk.conflictText {
                            mergeNums.formUnion(try extractSafeLogNumbers(from: text, strippingIdentifiers: sortedIdents))
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

    private static func normalizePDFSpacingForFieldParsing(_ raw: String) throws -> String {
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

    static func verifyKeyFieldsExactEquality(
        pdfByPane rawPDFByPane: [RelayStudioPane: String],
        language: RelayLanguage,
        truth: AuditGroundTruth
    ) throws -> [String] {
        if useLegacyLooseCheckForRedProof {
            return []
        }

        var pdfByPane: [RelayStudioPane: String] = [:]
        for (k, v) in rawPDFByPane {
            pdfByPane[k] = try normalizePDFSpacingForFieldParsing(v)
        }

        var violations: [String] = []
        let isZh = language.isChinese
        let run = truth.latestRun
        let expectedLaneCount = run?.lanes.count ?? 0
        let expectedFinishedCount = run?.lanes.filter(\.status.isTerminal).count ?? 0
        let expectedConflictCount = run?.integration?.merges.reduce(0) { $0 + $1.conflicts.count } ?? 0
        let orderedLanes = run?.lanes.sorted(by: { $0.ordinal < $1.ordinal }) ?? []
        let expectedTotalOwnedFiles = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.files.count ?? 0) }
        let expectedTotalAdd = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.totalAdditions ?? 0) }
        let expectedTotalDel = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.totalDeletions ?? 0) }
        let expectedTotalCommitted = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.committedCount ?? 0) }
        let expectedTotalUncommitted = orderedLanes.reduce(0) { $0 + (truth.gitOwnershipByLane[$1.laneID]?.uncommittedCount ?? 0) }

        // Cross-check SQLite run spend/tokens against independent .relay/LOG.md readings
        if let run {
            var logSumUSD = 0.0
            var logUnpricedTok = 0
            for lane in orderedLanes {
                if let ls = truth.logSpendsByLane[lane.laneID], ls.hasStepRecord {
                    if ls.costSource != lane.costSource {
                        violations.append("Lane \(lane.laneID) SQLite costSource=\(lane.costSource ?? "nil") != LOG.md \(ls.costSource)")
                    }
                    if ls.costSource == "usd", let lUSD = ls.costUSD {
                        logSumUSD += lUSD
                        if abs((lane.costUSD ?? -1) - lUSD) > 1e-6 {
                            violations.append("Lane \(lane.laneID) SQLite costUSD=\(String(describing: lane.costUSD)) != LOG.md \(lUSD)")
                        }
                    } else if ls.costSource == "unpriced", let lTok = ls.tokens {
                        logUnpricedTok += lTok
                        if lane.tokens != lTok {
                            violations.append("Lane \(lane.laneID) SQLite tokens=\(String(describing: lane.tokens)) != LOG.md \(lTok)")
                        }
                    }
                }
            }
            if abs(run.totalCostUSD - logSumUSD) > 1e-6 {
                violations.append("Run totalCostUSD \(run.totalCostUSD) != LOG.md sum \(logSumUSD)")
            }
            if run.unpricedTokens != logUnpricedTok {
                violations.append("Run unpricedTokens \(run.unpricedTokens) != LOG.md sum \(logUnpricedTok)")
            }
        }

        // Check Top Bar & Left Rail common fields across EVERY pane
        for (pane, pdf) in pdfByPane {
            let ctx = "[\(pane.rawValue)/\(language.rawValue)]"

            // 1. Top bar active wave / lane count & run status pill
            if let run {
                let pat = isZh ? #"(\d+)/(\d+)\s*条通道\s*·\s*([^\n]+)"# : #"(\d+)/(\d+)\s+Lanes\s*·\s*([^\n]+)"#
                let caps = try regexCaptures(pat, in: pdf)
                if caps.count != 1 {
                    violations.append("\(ctx) Top bar missing exact lane summary pill (matches=\(caps.count))")
                } else {
                    let gotFin = Int(caps[0][0]) ?? -1
                    let gotTot = Int(caps[0][1]) ?? -1
                    if gotFin != expectedFinishedCount || gotTot != expectedLaneCount {
                        violations.append("\(ctx) Top bar lane counts \(gotFin)/\(gotTot) != expected \(expectedFinishedCount)/\(expectedLaneCount)")
                    }
                    let expRunStatus = run.status.localizedLabel(in: language)
                    if !caps[0][2].contains(expRunStatus) {
                        violations.append("\(ctx) Top bar run status '\(caps[0][2])' missing expected '\(expRunStatus)'")
                    }
                }
            } else {
                let idleNeedle = isZh ? "0 项任务 · 空闲" : "0 Tasks · Idle"
                if !pdf.contains(idleNeedle) {
                    violations.append("\(ctx) Empty top bar missing '\(idleNeedle)'")
                }
            }

            // 2. Top bar total spend / budget / unpriced tokens pill
            if let run {
                if run.pricedLaneCount > 0 || run.budgetUSD != nil {
                    let spendText = RelayBauhausDesign.formatRunUSD(run.totalCostUSD)
                    let capSuffix = run.budgetUSD.map { " / \(RelayBauhausDesign.formatRunUSD($0))" } ?? ""
                    let unpricedSuffix = run.unpricedTokens > 0
                        ? (isZh ? " · \(run.unpricedTokens) tokens 未计价" : " · \(run.unpricedTokens) tokens unpriced")
                        : ""
                    let expectedSpendPill = isZh
                        ? "花费 \(spendText)\(capSuffix)\(unpricedSuffix)"
                        : "Spend \(spendText)\(capSuffix)\(unpricedSuffix)"
                    if !pdf.contains(expectedSpendPill) {
                        violations.append("\(ctx) Top bar spend pill mismatch: expected exact '\(expectedSpendPill)'")
                    }
                    if run.budgetUSD == nil && pdf.contains("/ $0.00") {
                        violations.append("\(ctx) Top bar rendered fake '/ $0.00' budget ceiling")
                    }
                } else if run.unpricedTokens > 0 {
                    let expUnpriced = isZh
                        ? "\(run.unpricedTokens) tokens · 未计价"
                        : "\(run.unpricedTokens) tokens · unpriced"
                    if !pdf.contains(expUnpriced) {
                        violations.append("\(ctx) Top bar unpriced pill mismatch: expected '\(expUnpriced)'")
                    }
                }
            } else {
                if pdf.contains("Spend $") || pdf.contains("花费 $") {
                    violations.append("\(ctx) Empty workspace rendered unexpected top-bar spend pill")
                }
            }

            // 3. Left rail badges for ⌘1..⌘4
            let b1 = try regexCaptures(#"([^\s]+)\s+⌘1(?![0-9–])"#, in: pdf).first?.first
            if b1 != "\(expectedLaneCount)" {
                violations.append("\(ctx) Left rail ⌘1 badge '\(b1 ?? "nil")' != expected laneCount '\(expectedLaneCount)'")
            }
            let b2 = try regexCaptures(#"([^\s]+)\s+⌘2"#, in: pdf).first?.first
            if b2 != "\(expectedLaneCount)" {
                violations.append("\(ctx) Left rail ⌘2 badge '\(b2 ?? "nil")' != expected DAG laneCount '\(expectedLaneCount)'")
            }
            let b3 = try regexCaptures(#"([^\s]+)\s+⌘3"#, in: pdf).first?.first
            if expectedConflictCount > 0 {
                if b3 != "\(expectedConflictCount)!" {
                    violations.append("\(ctx) Left rail ⌘3 badge '\(b3 ?? "nil")' != expected '\(expectedConflictCount)!'")
                }
            } else if isZh {
                if b3?.hasSuffix("就绪") != true || b3?.rangeOfCharacter(from: .decimalDigits) != nil {
                    violations.append("\(ctx) Left rail ⌘3 badge '\(b3 ?? "nil")' missing clean '就绪' badge")
                }
            } else if b3 != "OK" {
                violations.append("\(ctx) Left rail ⌘3 badge '\(b3 ?? "nil")' != expected 'OK'")
            }
            let b4 = try regexCaptures(#"([^\s]+)\s+⌘4"#, in: pdf).first?.first
            if b4 != "\(expectedTotalOwnedFiles)" {
                violations.append("\(ctx) Left rail ⌘4 badge '\(b4 ?? "nil")' != expected ownedFiles '\(expectedTotalOwnedFiles)'")
            }

            // 4. SQLite schema version & checkpoints
            let svCaps = try regexCaptures(#"SQLite WAL v(\d+)\s*·\s*FTS5"#, in: pdf)
            if svCaps.first?.first != "\(truth.schemaVersion)" {
                violations.append("\(ctx) SQLite schema version badge != \(truth.schemaVersion)")
            }
            let cpPat = isZh ? #"(\d+)\s*个快照"# : #"(\d+)\s+checkpoints"#
            let cpCaps = try regexCaptures(cpPat, in: pdf)
            if cpCaps.first?.first != "\(truth.checkpointsCount)" {
                violations.append("\(ctx) Checkpoints count != \(truth.checkpointsCount)")
            }

            // 5. Left rail per-lane status, exitCode, duration, spend/tokens
            for lane in orderedLanes {
                if !pdf.contains(lane.laneID) {
                    violations.append("\(ctx) Left rail missing laneID '\(lane.laneID)'")
                }
                let stLabel = lane.status.localizedLabel(in: language)
                if !pdf.contains(stLabel) {
                    violations.append("\(ctx) Left rail missing status '\(stLabel)' for '\(lane.laneID)'")
                }
                if let ec = lane.exitCode {
                    let exitStr = isZh ? "退出码 \(ec)" : "exit \(ec)"
                    if !pdf.contains(exitStr) {
                        violations.append("\(ctx) Left rail missing '\(exitStr)' for '\(lane.laneID)'")
                    }
                }
                if let s = lane.startedAt, let f = lane.finishedAt {
                    let durStr = String(format: "%.2fs", max(0.0, f.timeIntervalSince(s)))
                    if !pdf.contains(durStr) {
                        violations.append("\(ctx) Left rail missing duration '\(durStr)' for '\(lane.laneID)'")
                    }
                }
                if lane.costSource == "usd", let usd = lane.costUSD {
                    let usdStr = RelayBauhausDesign.formatRunUSD(usd)
                    if !pdf.contains(usdStr) {
                        violations.append("\(ctx) Left rail missing 4-decimal spend '\(usdStr)' for '\(lane.laneID)'")
                    }
                } else if lane.costSource == "unpriced", let tok = lane.tokens, tok > 0 {
                    let tokStr = isZh ? "\(tok) tokens · 未计价" : "\(tok) tokens · unpriced"
                    if !pdf.contains(tokStr) {
                        violations.append("\(ctx) Left rail missing unpriced tokens '\(tokStr)' for '\(lane.laneID)'")
                    }
                    if pdf.contains("$0.00") {
                        violations.append("\(ctx) Rendered forbidden '$0.00' alongside unpriced lane '\(lane.laneID)'")
                    }
                }
            }
        }

        // 6. Pane 2 (⌘2 DAG) specific field-equality checks (laneCount pill, run elapsed, per-node timings)
        if let dagPDF = pdfByPane[.dagPipeline] {
            let ctx = "[dagPipeline/\(language.rawValue)]"
            let lanePillPat = isZh ? #"(?<!/)\b(\d+)\s*条通道"# : #"(?<!/)\b(\d+)\s+lanes\b"#
            let laneCountsInDAG = try regexCaptures(lanePillPat, in: dagPDF).compactMap { Int($0[0]) }
            // In ZH when lanes > 0, bottom status bar also renders "只读观察 N 条通道" alongside Left Rail & DAG header
            let expectedOccurrences = expectedLaneCount > 0 ? (isZh ? 3 : 2) : (isZh ? 2 : 1)
            if !laneCountsInDAG.allSatisfy({ $0 == expectedLaneCount }) || laneCountsInDAG.count < (expectedLaneCount > 0 ? 2 : 1) {
                violations.append("\(ctx) DAG laneCount pills \(laneCountsInDAG) != expected \(expectedOccurrences)x [\(expectedLaneCount)]")
            }
            if let run, !orderedLanes.isEmpty {
                if let runEnd = run.finishedAt {
                    let expRunDur = String(format: "%.2fs", max(0.0, runEnd.timeIntervalSince(run.startedAt)))
                    if !dagPDF.contains(expRunDur) {
                        violations.append("\(ctx) DAG header missing run elapsed '\(expRunDur)'")
                    }
                }
                for lane in orderedLanes {
                    if !dagPDF.contains("#\(lane.ordinal)") {
                        violations.append("\(ctx) DAG missing ordinal '#\(lane.ordinal)' for '\(lane.laneID)'")
                    }
                    if let s = lane.startedAt, let f = lane.finishedAt {
                        let so = max(0.0, s.timeIntervalSince(run.startedAt))
                        let fo = max(0.0, f.timeIntervalSince(run.startedAt))
                        let dur = String(format: "%.2fs", max(0.0, f.timeIntervalSince(s)))
                        let timingLine = String(format: "+%.2fs → +%.2fs · %@", so, fo, dur)
                        if !dagPDF.contains(timingLine) {
                            violations.append("\(ctx) DAG node '\(lane.laneID)' missing exact timing '\(timingLine)'")
                        }
                    }
                }
            }
        }

        // 7. Pane 3 (⌘3 Merge) specific field-equality checks (merge step count, conflict file count, ready, verify)
        if let mergePDF = pdfByPane[.semanticMerge] {
            let ctx = "[semanticMerge/\(language.rawValue)]"
            if let integ = run?.integration {
                let expReady = integ.ready ? "ready: true" : "ready: false"
                if !mergePDF.contains(expReady) {
                    violations.append("\(ctx) Merge header missing '\(expReady)'")
                }
                if !mergePDF.contains(integ.status.rawValue) {
                    violations.append("\(ctx) Merge header missing status '\(integ.status.rawValue)'")
                }
                let stepPat = isZh ? #"(\d+)\s*步"# : #"(\d+)\s+steps\b"#
                let stepCounts = try regexCaptures(stepPat, in: mergePDF).compactMap { Int($0[0]) }
                if stepCounts != [integ.merges.count] {
                    violations.append("\(ctx) Merge step count \(stepCounts) != expected [\(integ.merges.count)]")
                }
                if !truth.reconstructedConflicts.isEmpty || integ.status == .conflict {
                    let confPat = isZh ? #"(\d+)\s*个文件"# : #"(\d+)\s+files\b"#
                    let confCounts = try regexCaptures(confPat, in: mergePDF).compactMap { Int($0[0]) }
                    if confCounts != [truth.reconstructedConflicts.count] {
                        violations.append("\(ctx) Conflict file count \(confCounts) != expected [\(truth.reconstructedConflicts.count)]")
                    }
                }
                if let verify = integ.verify, let vec = verify.exitCode {
                    let expVerifyExit = isZh ? "退出码 \(vec)" : "exit \(vec)"
                    if !mergePDF.contains(expVerifyExit) {
                        violations.append("\(ctx) Merge verify section missing '\(expVerifyExit)'")
                    }
                }
            }
        }

        // 8. Pane 4 (⌘4 File Ownership) specific field-equality checks (file count, committed/uncommitted, +add/-del)
        if let ownPDF = pdfByPane[.territoryMap] {
            let ctx = "[territoryMap/\(language.rawValue)]"
            let lanePillPat = isZh ? #"(?<!/)\b(\d+)\s*条通道"# : #"(?<!/)\b(\d+)\s+lanes\b"#
            let lanePills = try regexCaptures(lanePillPat, in: ownPDF).compactMap { Int($0[0]) }
            if lanePills.count < 2 || !lanePills.allSatisfy({ $0 == expectedLaneCount }) {
                violations.append("\(ctx) Ownership laneCount pills \(lanePills) != expected all \(expectedLaneCount)")
            }

            let filesPat = isZh ? #"(\d+)\s*个文件"# : #"(\d+)\s+files\b"#
            let gotFileCounts = try regexCaptures(filesPat, in: ownPDF).compactMap { Int($0[0]) }
            let expFileCounts: [Int] = expectedLaneCount == 0
                ? [0]
                : ([expectedTotalOwnedFiles] + orderedLanes.map { truth.gitOwnershipByLane[$0.laneID]?.files.count ?? 0 })
            if gotFileCounts != expFileCounts {
                violations.append("\(ctx) Ownership file counts \(gotFileCounts) != git expected \(expFileCounts)")
            }

            let slashDiffCaps = try regexCaptures(#"\+(\d+)\s*/\s*-(\d+)"#, in: ownPDF)
            let gotSlashDiffs = slashDiffCaps.map { [Int($0[0]) ?? -1, Int($0[1]) ?? -1] }
            var expSlashDiffs: [[Int]] = []
            if expectedTotalOwnedFiles > 0 {
                expSlashDiffs.append([expectedTotalAdd, expectedTotalDel])
            }
            for lane in orderedLanes {
                let own = truth.gitOwnershipByLane[lane.laneID]
                expSlashDiffs.append([own?.totalAdditions ?? 0, own?.totalDeletions ?? 0])
            }
            if gotSlashDiffs != expSlashDiffs {
                violations.append("\(ctx) Ownership +add / -del summaries \(gotSlashDiffs) != git expected \(expSlashDiffs)")
            }

            if expectedTotalOwnedFiles > 0 {
                let statePat = isZh
                    ? #"(\d+)\s*已提交\s*·\s*(\d+)\s*未提交"#
                    : #"(\d+)\s+committed\s*·\s*(\d+)\s+uncommitted"#
                let stateCaps = try regexCaptures(statePat, in: ownPDF)
                let gotState = stateCaps.first.map { [Int($0[0]) ?? -1, Int($0[1]) ?? -1] }
                if gotState != [expectedTotalCommitted, expectedTotalUncommitted] {
                    violations.append("\(ctx) Ownership committed/uncommitted \(String(describing: gotState)) != git expected [\(expectedTotalCommitted), \(expectedTotalUncommitted)]")
                }
            }

            let fileDiffCaps = try regexCaptures(#"\+(\d+)\s+-(\d+)"#, in: ownPDF)
            let gotFileDiffs = fileDiffCaps.map { [Int($0[0]) ?? -1, Int($0[1]) ?? -1] }
            var expFileDiffs: [[Int]] = []
            for lane in orderedLanes {
                for f in truth.gitOwnershipByLane[lane.laneID]?.files ?? [] {
                    expFileDiffs.append([f.additions, f.deletions])
                    if !ownPDF.contains(f.relativePath) {
                        violations.append("\(ctx) Ownership missing git file '\(f.relativePath)'")
                    }
                }
            }
            if gotFileDiffs != expFileDiffs {
                violations.append("\(ctx) Per-file +add -del \(gotFileDiffs) != git expected \(expFileDiffs)")
            }
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
            for lang in languages {
                let vm = RelayStudioViewModel(
                    projectBundleURL: target.bundleURL,
                    initialPane: .ptyGrid,
                    localizer: RelayLocalizer(language: lang, persistToUserDefaults: false),
                    loadDemoWorkspace: false
                )
                let truth = try M5NumberProvenanceAndFieldAuditor.collectGroundTruth(bundleURL: vm.projectBundleURL)
                var pdfByPane: [RelayStudioPane: String] = [:]

                for pane in RelayStudioPane.allCases {
                    vm.selectPane(pane)
                    let pdf = try Self.renderPDFText(vm: vm)
                    pdfByPane[pane] = pdf
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
                }

                // Also audit expanded Bottom Drawer & ⌘, Preferences modal
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
                vm.isPreferencesModalPresented = false

                // Part (b): Exact field-by-field equality against SQLite, LOG.md & Git
                let fieldErrs = try M5NumberProvenanceAndFieldAuditor.verifyKeyFieldsExactEquality(
                    pdfByPane: pdfByPane,
                    language: lang,
                    truth: truth
                )
                for err in fieldErrs {
                    violations.append("[\(target.label)] \(err)")
                }
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
}
