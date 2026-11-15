import Compression
import Foundation
import RelayModels
import RelayWorktreeGit
import Testing

@Suite("Git Worktree Plumbing, Loose Object Inspector, Diff Parser & Handoff Codec", .timeLimit(.minutes(1)))
struct WorktreeGitDiffAndHandoffTests {

    // MARK: - Isolated Temp Directory Helper

    private func makeIsolatedTempDirectory(prefix: String = "relay-git-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. `GlobPatternMatcher` Wildcards, Recursive `**` & Deny Precedence

    @Test("GlobPatternMatcher evaluates *, ?, **, forbidden overrides, and read-only verifier rules")
    func globPatternMatcherAllowDenyAndVerifierPrecedence() {
        #expect(GlobPatternMatcher.matches(path: "Sources/Ledger/BillingEngine.swift", glob: "Sources/**/*.swift"))
        #expect(GlobPatternMatcher.matches(path: "Sources/BillingEngine.swift", glob: "Sources/**/*.swift"))
        #expect(GlobPatternMatcher.matches(path: "Tests/Spec1.swift", glob: "Tests/Spec?.swift"))
        #expect(!GlobPatternMatcher.matches(path: "Tests/Spec12.swift", glob: "Tests/Spec?.swift"))
        #expect(!GlobPatternMatcher.matches(path: "Docs/README.md", glob: "Sources/**/*.swift"))

        let codexRule = FileOwnershipRule(
            allowedGlobs: ["Sources/API/**", "Tests/**"],
            forbiddenGlobs: ["Sources/API/Secrets/**", "**/*.pem"],
            autoRevertViolations: true,
            isReadOnlyVerifier: false
        )

        #expect(GlobPatternMatcher.evaluateOwnership(relativePath: "Sources/API/Router.swift", rule: codexRule).allowed == true)
        #expect(GlobPatternMatcher.evaluateOwnership(relativePath: "Tests/RouterTests.swift", rule: codexRule).allowed == true)

        // Forbidden glob overrides allowed glob
        let secretVerdict = GlobPatternMatcher.evaluateOwnership(
            relativePath: "Sources/API/Secrets/MasterKey.swift",
            rule: codexRule
        )
        #expect(secretVerdict.allowed == false)

        // Path outside allowed globs is rejected
        let outsideVerdict = GlobPatternMatcher.evaluateOwnership(
            relativePath: "Sources/Kernel/Scheduler.swift",
            rule: codexRule
        )
        #expect(outsideVerdict.allowed == false)

        // Read-only verifier rejects every write even if allowedGlobs is non-empty
        let verifierRule = FileOwnershipRule(
            allowedGlobs: ["**/*"],
            forbiddenGlobs: [],
            autoRevertViolations: true,
            isReadOnlyVerifier: true
        )
        let verifierVerdict = GlobPatternMatcher.evaluateOwnership(
            relativePath: "Tests/VerifierCheck.swift",
            rule: verifierRule
        )
        #expect(verifierVerdict.allowed == false)
    }

    // MARK: - 2. `GitWorktreePlumbingEngine` Demo Repo, Linked Worktrees & Dirty Deltas

    @Test("GitWorktreePlumbingEngine initializes repository, spawns isolated lane worktrees, and inspects dirty deltas")
    func gitWorktreePlumbingLifecycleAndDirtyDeltas() throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "relay-worktree")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let worktreesRoot = tempRoot.appendingPathComponent("lanes", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)

        let engine = GitWorktreePlumbingEngine()
        let baseOID = try engine.initializeDemoRepository(at: repoDir.path)
        #expect(baseOID.count == 40)
        #expect(try engine.verifyGitRepository(at: repoDir.path) != "")
        #expect(try engine.headCommitOID(at: repoDir.path) == baseOID)

        let claudeLane = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            laneID: "lane-claude",
            displayName: "Claude Core",
            vendor: .claudeCode,
            baseRef: "HEAD",
            worktreesRootDirectory: worktreesRoot.path,
            ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/**"], forbiddenGlobs: ["Docs/**"])
        )
        #expect(FileManager.default.fileExists(atPath: claudeLane.worktreePath))
        #expect(claudeLane.baseCommitOID == baseOID)

        // Modify an existing file and add an untracked file inside the lane worktree
        let existingBlob = engine.readBlobString(
            repositoryPath: repoDir.path,
            revision: "HEAD",
            relativePath: "Sources/BillingEngine.swift"
        )
        #expect(existingBlob != nil)

        let newFileURL = URL(fileURLWithPath: claudeLane.worktreePath)
            .appendingPathComponent("Sources/Ledger/InvoiceTax.swift")
        try FileManager.default.createDirectory(
            at: newFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "public struct InvoiceTax {}\n".write(to: newFileURL, atomically: true, encoding: .utf8)

        let deltas = try engine.inspectDirtyDeltas(in: claudeLane.worktreePath)
        #expect(deltas.contains { $0.relativePath.hasSuffix("InvoiceTax.swift") })

        try engine.removeLaneWorktree(
            repositoryPath: repoDir.path,
            worktreePath: claudeLane.worktreePath,
            deleteBranch: claudeLane.branchName
        )
        #expect(!FileManager.default.fileExists(atPath: claudeLane.worktreePath))
    }

    // MARK: - 3. `FSEventsOwnershipMonitor` Boundary Audit & Auto-Revert

    @Test("FSEventsOwnershipMonitor detects territory violations and auto-reverts unauthorized edits in worktree")
    func fsEventsOwnershipMonitorAutoRevertsForbiddenEdit() throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "relay-fsevents")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let worktreesDir = tempRoot.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)

        let engine = GitWorktreePlumbingEngine()
        _ = try engine.initializeDemoRepository(at: repoDir.path)

        let strictRule = FileOwnershipRule(
            allowedGlobs: ["Tests/**"],
            forbiddenGlobs: ["Sources/**"],
            autoRevertViolations: true,
            isReadOnlyVerifier: false
        )
        let vibeLane = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            laneID: "lane-vibe-tests",
            displayName: "Mistral Vibe Tests",
            vendor: .mistralVibe,
            worktreesRootDirectory: worktreesDir.path,
            ownershipRule: strictRule
        )

        let billingURL = URL(fileURLWithPath: vibeLane.worktreePath)
            .appendingPathComponent("Sources/BillingEngine.swift")
        let originalContent = try String(contentsOf: billingURL, encoding: .utf8)
        try "// UNAUTHORIZED MUTATION\n".write(to: billingURL, atomically: true, encoding: .utf8)

        let monitor = FSEventsOwnershipMonitor(gitEngine: engine)
        monitor.registerLane(vibeLane)

        // Allowed path produces nil violation
        #expect(monitor.auditChangedPath(worktreePath: vibeLane.worktreePath, relativePath: "Tests/BillingTests.swift") == nil)

        // Forbidden path triggers violation and auto-reverts file back to HEAD!
        let violation = monitor.auditChangedPath(
            worktreePath: vibeLane.worktreePath,
            relativePath: "Sources/BillingEngine.swift"
        )
        #expect(violation != nil)
        #expect(violation?.laneID == "lane-vibe-tests")
        #expect(violation?.wasAutoReverted == true)
        #expect(monitor.recordedViolations().count == 1)

        let restoredContent = try String(contentsOf: billingURL, encoding: .utf8)
        #expect(restoredContent == originalContent)
    }

    // MARK: - 4. RFC 1950 Zlib Inflate & Adler-32 Checksum Verification

    @Test("GitRepositoryObjectInspector computes exact RFC 1950 Adler-32 checksums and inflates zlib streams")
    func rfc1950Adler32AndZlibInflateVerification() throws {
        // Canonical RFC 1950 / Wikipedia test vector: Adler32("Wikipedia") == 0x11E60398
        let wikiData = Data("Wikipedia".utf8)
        #expect(GitRepositoryObjectInspector.computeAdler32(wikiData) == 0x11E6_0398)

        // Build a valid RFC 1950 zlib stream (0x78 0x9C + raw DEFLATE + big-endian Adler-32)
        let originalPayload = Data(
            ("commit 215\0tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" +
             "author Relay Conductor <relay@bauhaus.dev> 1763020800 +0000\n\n" +
             "feat: deterministic loose object payload\n").utf8
        )
        let rawDeflateBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalPayload.count + 128)
        defer { rawDeflateBuffer.deallocate() }

        let compressedCount = originalPayload.withUnsafeBytes { srcPtr -> Int in
            guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                rawDeflateBuffer,
                originalPayload.count + 128,
                base,
                originalPayload.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        #expect(compressedCount > 0)

        var rfc1950Stream = Data([0x78, 0x9C])
        rfc1950Stream.append(rawDeflateBuffer, count: compressedCount)
        let adler = GitRepositoryObjectInspector.computeAdler32(originalPayload).bigEndian
        withUnsafeBytes(of: adler) { rfc1950Stream.append(contentsOf: $0) }

        let inflated = try GitRepositoryObjectInspector.inflateRFC1950ZlibStream(rfc1950Stream)
        #expect(inflated == originalPayload)

        // Corrupting the trailing Adler-32 byte must throw an integrity error
        var corrupted = rfc1950Stream
        corrupted[corrupted.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try GitRepositoryObjectInspector.inflateRFC1950ZlibStream(corrupted)
        }
    }

    // MARK: - 5. Real `git init` Loose Commit, Tree, Tag & Worktree Inspection

    @Test("GitRepositoryObjectInspector reads loose commits, binary tree entries, annotated tags, and linked worktrees")
    func gitRepositoryObjectInspectorLooseObjectsAndWorktrees() throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "relay-inspector")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoDir = tempRoot.appendingPathComponent("main-repo", isDirectory: true)
        let linkedDir = tempRoot.appendingPathComponent("linked-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let git = GitWorktreePlumbingEngine()
        _ = try git.runGit(["init", "-b", "main"], cwd: repoDir.path)
        _ = try git.runGit(["config", "user.name", "Ada Lovelace"], cwd: repoDir.path)
        _ = try git.runGit(["config", "user.email", "ada@relayide.dev"], cwd: repoDir.path)
        _ = try git.runGit(["config", "commit.gpgsign", "false"], cwd: repoDir.path)
        _ = try git.runGit(["config", "tag.gpgSign", "false"], cwd: repoDir.path)

        let srcSubdir = repoDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: srcSubdir, withIntermediateDirectories: true)
        try "public let version = 1\n".write(
            to: srcSubdir.appendingPathComponent("Core.swift"),
            atomically: true,
            encoding: .utf8
        )
        let scriptURL = repoDir.appendingPathComponent("bootstrap.sh")
        try "#!/bin/sh\necho ok\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        _ = try git.runGit(["add", "."], cwd: repoDir.path)
        _ = try git.runGit(["commit", "-m", "feat: initial architecture\n\nDetailed body line."], cwd: repoDir.path)
        let commit1OID = try git.runGit(["rev-parse", "HEAD"], cwd: repoDir.path).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try git.runGit(["tag", "-a", "v0.1.0", "-m", "First milestone tag"], cwd: repoDir.path)
        let tagOID = try git.runGit(["rev-parse", "refs/tags/v0.1.0"], cwd: repoDir.path).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try git.runGit(["worktree", "add", "-b", "lane/codex", linkedDir.path, "HEAD"], cwd: repoDir.path)

        let inspector = GitRepositoryObjectInspector()

        // 1. Resolve directories on both primary repo and linked worktree
        let mainDirs = try inspector.resolveRepositoryDirectories(at: repoDir.path)
        #expect(mainDirs.isLinkedWorktree == false)
        #expect(mainDirs.isBareRepository == false)

        let linkedDirs = try inspector.resolveRepositoryDirectories(at: linkedDir.path)
        #expect(linkedDirs.isLinkedWorktree == true)

        // 2. Read symbolic HEAD & references
        let head = try inspector.readHEAD(at: repoDir.path)
        #expect(head.shortBranchName == "main")
        #expect(head.resolvedCommitOID == commit1OID)

        let refs = try inspector.listAllReferences(at: repoDir.path)
        #expect(refs.contains { $0.shortName == "main" && $0.namespace == .localBranch })
        #expect(refs.contains { $0.shortName == "lane/codex" && $0.namespace == .localBranch })
        #expect(refs.contains { $0.shortName == "v0.1.0" && $0.namespace == .tag })

        // 3. Inspect worktrees
        let worktrees = try inspector.inspectWorktrees(at: repoDir.path)
        #expect(worktrees.count == 2)
        #expect(worktrees.contains { $0.isMainWorktree })
        #expect(worktrees.contains { !$0.isMainWorktree && $0.head.shortBranchName == "lane/codex" })

        // 4. Read loose commit, root tree entries, and annotated tag directly from .git/objects
        let commitObj = try inspector.readCommitObject(at: repoDir.path, commitOID: commit1OID)
        #expect(commitObj.author.name == "Ada Lovelace")
        #expect(commitObj.subject == "feat: initial architecture")
        #expect(commitObj.messageBody.contains("Detailed body line."))
        #expect(commitObj.parentOIDs.isEmpty)

        let treeEntries = try inspector.readTreeEntries(at: repoDir.path, treeOID: commitObj.treeOID)
        #expect(treeEntries.contains { $0.name == "Sources" && $0.entryType == .directoryTree })
        #expect(treeEntries.contains { $0.name == "bootstrap.sh" && $0.entryType == .executableFile })

        let annotatedTag = try inspector.readAnnotatedTag(at: repoDir.path, tagOID: tagOID)
        #expect(annotatedTag.tagName == "v0.1.0")
        #expect(annotatedTag.targetOID == commit1OID)
        #expect(annotatedTag.message.contains("First milestone tag"))

        let walked = try inspector.walkLooseCommitGraph(at: repoDir.path)
        #expect(walked.count == 1)
        #expect(walked[0].oid == commit1OID)
    }

    // MARK: - 6. `GitCommitDAGAnalyzer` Merge Bases, Ahead/Behind & Swimlanes

    @Test("GitCommitDAGAnalyzer computes ancestry, merge bases, ahead/behind divergence, and swimlanes")
    func gitCommitDAGAnalyzerMergeBaseAheadBehindAndSwimlanes() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Diamond + diverged branch topology:
        //   c1 (root) -> c2 -> c4 (main)
        //          \---> c3 -> c5 (feature)
        //   u1 (unrelated root)
        let c1 = GitCommitNode(oid: String(repeating: "1", count: 40), parentOIDs: [], authorName: "A", authorEmail: "a@x", authoredAt: t0, subject: "root")
        let c2 = GitCommitNode(oid: String(repeating: "2", count: 40), parentOIDs: [c1.oid], authorName: "A", authorEmail: "a@x", authoredAt: t0.addingTimeInterval(10), subject: "main-1")
        let c3 = GitCommitNode(oid: String(repeating: "3", count: 40), parentOIDs: [c1.oid], authorName: "B", authorEmail: "b@x", authoredAt: t0.addingTimeInterval(20), subject: "feat-1")
        let c4 = GitCommitNode(oid: String(repeating: "4", count: 40), parentOIDs: [c2.oid], authorName: "A", authorEmail: "a@x", authoredAt: t0.addingTimeInterval(30), subject: "main-2")
        let c5 = GitCommitNode(oid: String(repeating: "5", count: 40), parentOIDs: [c3.oid], authorName: "B", authorEmail: "b@x", authoredAt: t0.addingTimeInterval(40), subject: "feat-2")
        let cMerge = GitCommitNode(oid: String(repeating: "6", count: 40), parentOIDs: [c4.oid, c5.oid], authorName: "C", authorEmail: "c@x", authoredAt: t0.addingTimeInterval(50), subject: "merge")
        let u1 = GitCommitNode(oid: String(repeating: "9", count: 40), parentOIDs: [], authorName: "Z", authorEmail: "z@x", authoredAt: t0.addingTimeInterval(5), subject: "orphan")

        let analyzer = GitCommitDAGAnalyzer(commits: [cMerge, c5, c4, c3, c2, c1, u1])

        #expect(analyzer.isAncestor(ancestorOID: c1.oid, of: c4.oid) == true)
        #expect(analyzer.isAncestor(ancestorOID: c2.oid, of: c5.oid) == false)

        let bases = analyzer.findMergeBases(leftOID: c4.oid, rightOID: c5.oid)
        #expect(bases == [c1.oid])

        // Diverged: c5 vs c4 (2 ahead, 2 behind, merge base c1)
        let diverged = analyzer.computeAheadBehind(localOID: c5.oid, upstreamOID: c4.oid)
        #expect(diverged.relation == .diverged)
        #expect(diverged.aheadCount == 2)
        #expect(diverged.behindCount == 2)
        #expect(diverged.mergeBaseOIDs == [c1.oid])

        // Fast-forward ahead: c4 vs c1
        let ffAhead = analyzer.computeAheadBehind(localOID: c4.oid, upstreamOID: c1.oid)
        #expect(ffAhead.relation == .fastForwardAhead)
        #expect(ffAhead.aheadCount == 2)
        #expect(ffAhead.behindCount == 0)

        // Fast-forward behind: c1 vs c4
        let ffBehind = analyzer.computeAheadBehind(localOID: c1.oid, upstreamOID: c4.oid)
        #expect(ffBehind.relation == .fastForwardBehind)
        #expect(ffBehind.behindCount == 2)

        // Identical
        #expect(analyzer.computeAheadBehind(localOID: c4.oid, upstreamOID: c4.oid).relation == .identical)

        // Unrelated histories
        #expect(analyzer.computeAheadBehind(localOID: c4.oid, upstreamOID: u1.oid).relation == .unrelatedHistories)

        // Topological swimlanes assign concurrent branches to >= 2 columns
        let swimlanes = analyzer.buildTopologicalSwimlanes()
        #expect(swimlanes.count == 7)
        let maxCols = swimlanes.map(\.totalActiveColumns).max() ?? 0
        #expect(maxCols >= 2)
    }

    // MARK: - 7. `UnifiedAndSplitDiffParser` Multi-Hunk Unified & Split Row Alignment

    @Test("UnifiedAndSplitDiffParser aligns unified rows, paired split modifications, and expandable gaps")
    func unifiedAndSplitDiffParserRowsAndGaps() {
        let patch = """
        diff --git a/Sources/Ledger/BillingEngine.swift b/Sources/Ledger/BillingEngine.swift
        index 83db48f..bf269f4 100644
        --- a/Sources/Ledger/BillingEngine.swift
        +++ b/Sources/Ledger/BillingEngine.swift
        @@ -10,5 +10,6 @@ public struct BillingEngine {
             public func subtotal(cents: [Int]) -> Int {
        -        return cents.reduce(0, +)
        +        let gross = cents.reduce(0, +)
        +        return max(0, gross)
             }
         }
        @@ -40,4 +41,4 @@ public struct BillingEngine {
             public func currencyCode() -> String {
        -        return "USD"
        +        return "NZD"
             }
        """

        let parser = UnifiedAndSplitDiffParser()
        let parsed = parser.parsePatch(patch)
        #expect(parsed.files.count == 1)
        #expect(parsed.totalAdditions == 3)
        #expect(parsed.totalDeletions == 2)

        let file = parsed.files[0]
        #expect(file.changeKind == .modified)
        #expect(file.displayPath == "Sources/Ledger/BillingEngine.swift")
        #expect(file.hunks.count == 2)
        #expect(file.hunks[0].sectionHeading.contains("BillingEngine"))

        // Hunk 0 has paired modification + pure addition
        let hunk0Split = file.hunks[0].splitRows
        #expect(hunk0Split.contains { $0.kind == .modifiedPair })
        #expect(hunk0Split.contains { $0.kind == .additionOnly })

        // Hunk 1 starts at oldStart=40 after hunk 0 ended at line 14 -> expandable gap must be populated!
        let hunk1Header = file.hunks[1].splitRows.first { $0.kind == .hunkHeader }
        #expect(hunk1Header?.expandableGap != nil)
        #expect((hunk1Header?.expandableGap?.hiddenLineCount ?? 0) > 20)
    }

    // MARK: - 8. `DiffIntralineHighlighter` Token Emphasis Spans

    @Test("DiffIntralineHighlighter pinpoints changed tokens within paired lines")
    func diffIntralineHighlighterTokenSpans() {
        let highlighter = DiffIntralineHighlighter()
        let oldLine = #"    let timeoutSeconds = config.readInt("http_timeout", fallback: 15)"#
        let newLine = #"    let timeoutSeconds = config.readInt("wiretap_timeout", fallback: 60)"#

        let result = highlighter.computeHighlightSpans(oldLine: oldLine, newLine: newLine)
        #expect(result.similarity > 0.50)
        #expect(result.oldSpans.contains { $0.emphasis == .deletedToken })
        #expect(result.newSpans.contains { $0.emphasis == .insertedToken })
        #expect(result.oldSpans[0].startCharOffset > 0)
    }

    // MARK: - 9. `UnifiedAndSplitDiffParser` Single-Hunk Stageable Patch Extraction

    @Test("UnifiedAndSplitDiffParser extracts valid git-apply stageable sub-patches for selected hunk indices")
    func extractStageableSingleHunkSubPatch() throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-stage-hunk")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let git = GitWorktreePlumbingEngine()
        _ = try git.runGit(["init", "-b", "main"], cwd: tempDir.path)
        _ = try git.runGit(["config", "user.name", "Relay"], cwd: tempDir.path)
        _ = try git.runGit(["config", "user.email", "relay@test.dev"], cwd: tempDir.path)
        _ = try git.runGit(["config", "commit.gpgsign", "false"], cwd: tempDir.path)

        let originalLines = (1...20).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        let fileURL = tempDir.appendingPathComponent("Module.txt")
        try originalLines.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try git.runGit(["add", "Module.txt"], cwd: tempDir.path)
        _ = try git.runGit(["commit", "-m", "base"], cwd: tempDir.path)

        var mutated = (1...20).map { "line-\($0)" }
        mutated[1] = "line-2-HUNK-ZERO"
        mutated[18] = "line-19-HUNK-ONE"
        try (mutated.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let rawDiff = try git.runGit(["diff"], cwd: tempDir.path)
        let parser = UnifiedAndSplitDiffParser()
        let patchSet = parser.parsePatch(rawDiff)
        #expect(patchSet.files.count == 1)
        #expect(patchSet.files[0].hunks.count == 2)

        // Extract ONLY hunk index 1 (leaving hunk 0 unstaged!) and verify `git apply --check --cached` accepts it
        let subPatch = parser.extractStageableSubPatch(from: patchSet.files[0], hunkIndices: [1])
        #expect(subPatch != nil)
        #expect(subPatch!.contains("line-19-HUNK-ONE"))
        #expect(!subPatch!.contains("line-2-HUNK-ZERO"))

        let patchFile = tempDir.appendingPathComponent("hunk1.patch")
        try subPatch!.write(to: patchFile, atomically: true, encoding: .utf8)
        _ = try git.runGit(["apply", "--cached", patchFile.path], cwd: tempDir.path)

        let cachedDiff = try git.runGit(["diff", "--cached"], cwd: tempDir.path)
        #expect(cachedDiff.contains("line-19-HUNK-ONE"))
        #expect(!cachedDiff.contains("line-2-HUNK-ZERO"))
    }

    // MARK: - 10.Diff Edge Cases: Renames, Binary Assets, Quoted Paths & Missing Trailing Newline

    @Test("UnifiedAndSplitDiffParser parses renames, binary diffs, C-quoted paths, and missing newline markers")
    func diffParserRenamesBinariesAndQuotedPaths() {
        let complexPatch = """
        diff --git a/OldName.swift b/NewName.swift
        similarity index 94%
        rename from OldName.swift
        rename to NewName.swift
        index 1111111..2222222 100644
        --- a/OldName.swift
        +++ b/NewName.swift
        @@ -1,2 +1,2 @@
         let x = 1
        -let y = 2
        \\ No newline at end of file
        +let y = 3
        \\ No newline at end of file
        diff --git a/assets/logo.png b/assets/logo.png
        index 3333333..4444444 100644
        Binary files a/assets/logo.png and b/assets/logo.png differ
        """

        let parser = UnifiedAndSplitDiffParser()
        let set = parser.parsePatch(complexPatch)
        #expect(set.files.count == 2)
        #expect(set.renamedFileCount == 1)
        #expect(set.binaryFileCount == 1)
        #expect(set.files[0].changeKind == .renamed)
        #expect(set.files[0].similarityPercent == 94)
        #expect(set.files[0].allUnifiedRows.contains { $0.missingTrailingNewline || $0.kind == .noNewlineNotice })
        #expect(set.files[1].isBinary == true)

        let unquoted = UnifiedAndSplitDiffParser.unquoteGitPath(#""docs/Relay Plan.md""#)
        #expect(unquoted == "docs/Relay Plan.md")
    }

    // MARK: - 11. `RelayHandoffProtocolCodec` Kickoff Specification Markdown Round-Trip

    @Test("RelayHandoffProtocolCodec round-trips RELAY_KICKOFF.md 4-vendor pipeline and converts to RelayDAGSpec")
    func kickoffMarkdownRoundTripAndDAGConversion() throws {
        let spec = RelayKickoffSpecification.standardFourVendorPipeline(
            title: "HTTP/3 Zero-Copy Relay",
            repositoryPath: "/tmp/relay-demo-repo",
            baseBranch: "main"
        )
        #expect(spec.stages.count == 4)

        let codec = RelayHandoffProtocolCodec()
        let markdown = codec.generateKickoffMarkdown(spec)
        #expect(markdown.contains("HTTP/3 Zero-Copy Relay"))

        let reparsed = try codec.parseKickoffMarkdown(markdown)
        #expect(reparsed.pipelineTitle == spec.pipelineTitle)
        #expect(reparsed.baseBranch == "main")
        #expect(reparsed.stages.count == 4)
        #expect(reparsed.stages.map(\.vendor) == spec.stages.map(\.vendor))
        #expect(reparsed.stages.map(\.stageID) == spec.stages.map(\.stageID))

        let dag = reparsed.toRelayDAGSpec()
        #expect(dag.tasks.count == 4)
        #expect(dag.globalBudgetCeilingUSD == spec.globalBudgetCeilingUSD)
    }

    // MARK: - 12. `RelayHandoffProtocolCodec` `.relay/LOG.md` Ledger Round-Trip

    @Test("RelayHandoffProtocolCodec serializes and parses .relay/LOG.md handoff ledger steps losslessly")
    func handoffLedgerMarkdownRoundTrip() throws {
        let digest = RelayArtifactDigestEntry(
            relativePath: ".relay/artifacts/arch-spec.json",
            byteSize: 512,
            sha256Hex: RelayHandoffProtocolCodec.sha256Hex(ofString: "{\"ok\":true}")
        )
        let step1 = RelayHandoffLogStep(
            stepNumber: 1,
            stageID: "stage-arch",
            vendor: .claudeCode,
            laneID: "lane-claude",
            timestampISO8601: "2026-11-13T08:00:00Z",
            headCommitOID: String(repeating: "a", count: 40),
            exitCode: 0,
            status: .completed,
            producedArtifacts: [digest],
            modifiedPaths: ["Sources/Arch/Contract.swift"],
            verificationCommand: "swift build",
            handoffNotes: "Contract frozen and verified."
        )
        let step2 = RelayHandoffLogStep(
            stepNumber: 2,
            stageID: "stage-impl",
            vendor: .codex,
            laneID: "lane-codex",
            timestampISO8601: "2026-11-13T08:05:00Z",
            exitCode: 0,
            status: .handoffReady,
            producedArtifacts: [],
            modifiedPaths: ["Sources/Impl/Engine.swift"],
            handoffNotes: "Ready for Vibe test suite."
        )

        let ledger = RelayHandoffLedgerDocument(
            pipelineTitle: "HTTP/3 Zero-Copy Relay",
            repositoryPath: "/tmp/relay-demo-repo",
            createdAtISO8601: "2026-11-13T07:59:00Z",
            steps: [step1, step2]
        )

        let codec = RelayHandoffProtocolCodec()
        let md = codec.generateHandoffLogMarkdown(ledger)
        let parsed = try codec.parseHandoffLogMarkdown(md)

        #expect(parsed.pipelineTitle == ledger.pipelineTitle)
        #expect(parsed.steps.count == 2)
        #expect(parsed.steps[0].stageID == "stage-arch")
        #expect(parsed.steps[0].producedArtifacts == [digest])
        #expect(parsed.steps[0].modifiedPaths == ["Sources/Arch/Contract.swift"])
        #expect(parsed.steps[1].vendor == .codex)
    }

    // MARK: - 13. `RelayHandoffProtocolCodec` SHA-256 Artifact & Ownership Pipeline Validation

    @Test("RelayHandoffProtocolCodec validates on-disk SHA-256 artifact digests and flags tampering or ownership breaches")
    func handoffPipelineSHA256AndOwnershipValidation() throws {
        let workspaceDir = try makeIsolatedTempDirectory(prefix: "relay-handoff-verify")
        defer { try? FileManager.default.removeItem(at: workspaceDir) }

        let artifactRelPath = ".relay/spec.md"
        let artifactURL = workspaceDir.appendingPathComponent(artifactRelPath)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Approved Spec v1\n".write(to: artifactURL, atomically: true, encoding: .utf8)

        let codec = RelayHandoffProtocolCodec()
        let realDigest = try codec.computeArtifactDigest(workspaceRoot: workspaceDir.path, relativePath: artifactRelPath)

        let stage1 = RelayKickoffStageContract(
            stageNumber: 1,
            stageID: "s1-spec",
            title: "Spec",
            vendor: .claudeCode,
            laneID: "lane-claude",
            outputArtifacts: [artifactRelPath],
            ownershipRule: FileOwnershipRule(allowedGlobs: [".relay/**", "Sources/**"], forbiddenGlobs: ["Secrets/**"]),
            promptBrief: "Write spec"
        )
        let kickoff = RelayKickoffSpecification(
            pipelineTitle: "Verified Relay",
            repositoryPath: workspaceDir.path,
            stages: [stage1]
        )

        let cleanLedger = RelayHandoffLedgerDocument(
            pipelineTitle: "Verified Relay",
            repositoryPath: workspaceDir.path,
            createdAtISO8601: "2026-11-13T08:00:00Z",
            steps: [
                RelayHandoffLogStep(
                    stepNumber: 1,
                    stageID: "s1-spec",
                    vendor: .claudeCode,
                    laneID: "lane-claude",
                    timestampISO8601: "2026-11-13T08:01:00Z",
                    status: .completed,
                    producedArtifacts: [realDigest],
                    modifiedPaths: [".relay/spec.md", "Sources/App.swift"]
                )
            ]
        )

        let cleanReport = codec.validateHandoffPipeline(
            kickoff: kickoff,
            ledger: cleanLedger,
            workspaceRootPath: workspaceDir.path,
            conductorEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(cleanReport.isValid == true)
        #expect(cleanReport.verifiedDigestMatches == 1)
        #expect(cleanReport.ownershipViolationsCount == 0)

        // Tamper with the artifact on disk and add an unauthorized path in ledger -> validation must fail!
        try "# TAMPERED SPEC\n".write(to: artifactURL, atomically: true, encoding: .utf8)
        let dirtyLedger = RelayHandoffLedgerDocument(
            pipelineTitle: "Verified Relay",
            repositoryPath: workspaceDir.path,
            createdAtISO8601: "2026-11-13T08:00:00Z",
            steps: [
                RelayHandoffLogStep(
                    stepNumber: 1,
                    stageID: "s1-spec",
                    vendor: .claudeCode,
                    laneID: "lane-claude",
                    timestampISO8601: "2026-11-13T08:02:00Z",
                    status: .completed,
                    producedArtifacts: [realDigest],
                    modifiedPaths: ["Secrets/prod.key"]
                )
            ]
        )
        let dirtyReport = codec.validateHandoffPipeline(
            kickoff: kickoff,
            ledger: dirtyLedger,
            workspaceRootPath: workspaceDir.path,
            conductorEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(dirtyReport.isValid == false)
        #expect(dirtyReport.ownershipViolationsCount == 1)
        #expect(dirtyReport.findings.contains { $0.severity == .error })
    }

    // MARK: - 14. `RelayWorkerRecursionGuard` Anti-Nesting Enforcement

    @Test("RelayWorkerRecursionGuard blocks nested worker-to-conductor recursion and sanitizes worker env")
    func workerRecursionGuardBlocksNestedRelay() {
        let guardEngine = RelayWorkerRecursionGuard(maxAllowedDepth: 1)

        // Clean top-level conductor environment is permitted
        let cleanCheck = guardEngine.evaluateConductorEligibility(environment: ["HOME": "/Users/test"])
        #expect(cleanCheck.isPermittedToLaunchRelay == true)
        #expect(cleanCheck.isInsideActiveWorker == false)
        #expect(cleanCheck.violations.isEmpty)

        // Build isolated worker environment for stage
        let stage = RelayKickoffStageContract(
            stageNumber: 2,
            stageID: "stage-codex",
            title: "Codex Impl",
            vendor: .codex,
            laneID: "lane-codex",
            ownershipRule: FileOwnershipRule(allowedGlobs: ["Sources/**"], forbiddenGlobs: [".env"]),
            promptBrief: "Implement engine"
        )
        let workerEnv = guardEngine.buildWorkerEnvironment(
            inheritingFrom: [
                "PATH": "/usr/bin:/bin",
                "RELAY_CONDUCTOR_CONTROL_TOKEN": "secret-conductor-token",
            ],
            stage: stage,
            wiretapProxyURL: "http://127.0.0.1:19080"
        )
        #expect(workerEnv[RelayWorkerRecursionGuard.workerActiveEnvKey] == "1")
        #expect(workerEnv[RelayWorkerRecursionGuard.relayStageIDEnvKey] == "stage-codex")
        #expect(workerEnv[RelayWorkerRecursionGuard.relayLaneIDEnvKey] == "lane-codex")

        // If that worker tries to invoke the relay conductor recursively, it MUST be blocked!
        let nestedAttempt = guardEngine.evaluateConductorEligibility(environment: workerEnv)
        #expect(nestedAttempt.isPermittedToLaunchRelay == false)
        #expect(nestedAttempt.isInsideActiveWorker == true)
        #expect(nestedAttempt.violations.contains(.workerAlreadyActive))
    }

    // MARK: - 15. `GitWorktreePlumbingEngine` Merge-Base & Commit DAG Parsing on Real Repo

    @Test("GitWorktreePlumbingEngine resolves real git merge-base and parses commit DAG history")
    func gitPlumbingMergeBaseAndCommitDAG() throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-mergebase")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = GitWorktreePlumbingEngine()
        let baseOID = try engine.initializeDemoRepository(at: tempDir.path)

        _ = try engine.runGit(["checkout", "-b", "branch-left"], cwd: tempDir.path)
        try "public let left = 1\n".write(
            to: tempDir.appendingPathComponent("Left.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try engine.runGit(["add", "Left.swift"], cwd: tempDir.path)
        _ = try engine.runGit(["-c", "commit.gpgsign=false", "commit", "-m", "left commit"], cwd: tempDir.path)

        _ = try engine.runGit(["checkout", baseOID, "-b", "branch-right"], cwd: tempDir.path)
        try "public let right = 2\n".write(
            to: tempDir.appendingPathComponent("Right.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try engine.runGit(["add", "Right.swift"], cwd: tempDir.path)
        _ = try engine.runGit(["-c", "commit.gpgsign=false", "commit", "-m", "right commit"], cwd: tempDir.path)

        let resolvedBase = try engine.mergeBase(
            repositoryPath: tempDir.path,
            leftRef: "branch-left",
            rightRef: "branch-right"
        )
        #expect(resolvedBase == baseOID)

        let dagNodes = try engine.parseCommitDAG(at: tempDir.path, maxCount: 20)
        #expect(dagNodes.count >= 2)
        #expect(dagNodes.contains { $0.oid == baseOID })
    }

    // MARK: - 16. Detached HEAD Inspection in `GitRepositoryObjectInspector`

    @Test("GitRepositoryObjectInspector distinguishes detached HEAD from symbolic branch HEAD")
    func gitInspectorDetachedHeadState() throws {
        let tempDir = try makeIsolatedTempDirectory(prefix: "relay-detached")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let git = GitWorktreePlumbingEngine()
        let oid = try git.initializeDemoRepository(at: tempDir.path)
        _ = try git.runGit(["checkout", "--detach", oid], cwd: tempDir.path)

        let inspector = GitRepositoryObjectInspector()
        let head = try inspector.readHEAD(at: tempDir.path)
        if case .detached(let detachedOID) = head {
            #expect(detachedOID == oid)
        } else {
            Issue.record("Expected .detached HEAD state")
        }
        #expect(head.shortBranchName == nil)
        #expect(head.resolvedCommitOID == oid)
    }

    // MARK: - 17. SHA-256 Deterministic Digest Vector in `RelayHandoffProtocolCodec`

    @Test("RelayHandoffProtocolCodec computes NIST FIPS 180-4 SHA-256 hex digest vectors")
    func handoffSHA256StandardTestVectors() {
        // Empty string SHA-256
        #expect(
            RelayHandoffProtocolCodec.sha256Hex(ofString: "") ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        // "abc" SHA-256
        #expect(
            RelayHandoffProtocolCodec.sha256Hex(ofString: "abc") ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - 18. Non-Repository Error Handling in `GitWorktreePlumbingEngine`

    @Test("GitWorktreePlumbingEngine throws structured error when inspecting a non-git directory")
    func gitPlumbingNonRepoThrowsError() throws {
        let plainDir = try makeIsolatedTempDirectory(prefix: "relay-non-git")
        defer { try? FileManager.default.removeItem(at: plainDir) }

        let engine = GitWorktreePlumbingEngine()
        #expect(throws: (any Error).self) {
            _ = try engine.verifyGitRepository(at: plainDir.path)
        }
    }

    // MARK: - 19. M1 `createLaneWorktree` (`-b`, `relay/<runID>/<laneID>`, No Reset, Lane ID Guard, R36)

    @Test("GitWorktreePlumbingEngine.createLaneWorktree creates relay/<runID>/<laneID> with -b, refuses existing branches without resetting them (exit 125), and validates laneID before creating directories (R36)")
    func createLaneWorktreeEnforcesRunBranchWithoutResetAndValidatesLaneID() throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "relay-r36")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let gitEnv: [String: String] = [
            "HOME": homeDir.path,
            "CFFIXED_USER_HOME": homeDir.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]

        let engine = GitWorktreePlumbingEngine()
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "Fake R36 Author"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "r36@relay.invalid"], cwd: repoDir.path, environment: gitEnv)
        try "v1\n".write(to: repoDir.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "base.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "base"], cwd: repoDir.path, environment: gitEnv)
        let baseOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Invalid lane names (`a/b`, `../escape`, `integration`) must fail with exit 2 BEFORE creating worktreesRootDirectory
        let untouchedRoot = tempRoot.appendingPathComponent("should-not-be-created/worktrees", isDirectory: true)
        for badID in ["a/b", "../escape", "integration"] {
            do {
                _ = try engine.createLaneWorktree(
                    repositoryPath: repoDir.path,
                    runID: "20261116-010000-0001",
                    laneID: badID,
                    displayName: badID,
                    vendor: .claudeCode,
                    baseRef: baseOID,
                    worktreesRootDirectory: untouchedRoot.path,
                    environment: gitEnv
                )
                Issue.record("Expected createLaneWorktree to reject invalid laneID '\(badID)'")
            } catch let err as RelayIDEError {
                #expect(err.cliExitCode == 2)
            }
            #expect(!FileManager.default.fileExists(atPath: untouchedRoot.path))
        }

        // 2. Valid creation produces branch `relay/<runID>/<laneID>` at `<worktreesRoot>/<laneID>`
        let run1ID = "20261116-010000-aaaa"
        let wtRoot1 = tempRoot.appendingPathComponent("runs/\(run1ID)/worktrees", isDirectory: true)
        let laneA = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            runID: run1ID,
            laneID: "api",
            displayName: "api",
            vendor: .claudeCode,
            baseRef: baseOID,
            worktreesRootDirectory: wtRoot1.path,
            environment: gitEnv
        )
        #expect(laneA.branchName == "relay/\(run1ID)/api")
        #expect(laneA.worktreePath == wtRoot1.appendingPathComponent("api").path)
        let branchRefOID = try engine.runGit(["rev-parse", "refs/heads/relay/\(run1ID)/api"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branchRefOID == baseOID)

        // 3. Pre-existing branch `relay/<run2ID>/api` with an extra commit must NEVER be reset (-b, not -B); error cliExitCode == 125
        let run2ID = "20261116-010001-bbbb"
        let preexistingBranch = "relay/\(run2ID)/api"
        _ = try engine.runGit(["checkout", "-b", preexistingBranch, baseOID], cwd: repoDir.path, environment: gitEnv)
        try "precious-work\n".write(to: repoDir.appendingPathComponent("precious.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "precious.txt"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "precious commit"], cwd: repoDir.path, environment: gitEnv)
        let preciousOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try engine.runGit(["checkout", "main"], cwd: repoDir.path, environment: gitEnv)
        #expect(preciousOID != baseOID)

        let wtRoot2 = tempRoot.appendingPathComponent("runs/\(run2ID)/worktrees", isDirectory: true)
        do {
            _ = try engine.createLaneWorktree(
                repositoryPath: repoDir.path,
                runID: run2ID,
                laneID: "api",
                displayName: "api",
                vendor: .claudeCode,
                baseRef: baseOID,
                worktreesRootDirectory: wtRoot2.path,
                environment: gitEnv
            )
            Issue.record("Expected createLaneWorktree to fail when branch '\(preexistingBranch)' already exists")
        } catch let err as RelayIDEError {
            #expect(err.cliExitCode == 125)
        }

        let afterAttemptOID = try engine.runGit(["rev-parse", "refs/heads/\(preexistingBranch)"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterAttemptOID == preciousOID)
    }

    // MARK: - 20. M1 Lane Commit (`--no-verify`, `:(exclude).relay`, No-Changes, Agent Commits) & Uncommitted List (R46, R47)

    @Test("GitWorktreePlumbingEngine commits lane changes with --no-verify and :(exclude).relay, skips empty commits, preserves agent commits, and lists uncommitted files")
    func laneCommitExcludesRelaySkipsHooksPreservesAgentCommitsAndListsDirtyFiles() throws {
        let tempRoot = try makeIsolatedTempDirectory(prefix: "relay-r47")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let gitEnv: [String: String] = [
            "HOME": homeDir.path,
            "CFFIXED_USER_HOME": homeDir.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin"
        ]

        let engine = GitWorktreePlumbingEngine()
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "Lane Committer"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "committer@relay.invalid"], cwd: repoDir.path, environment: gitEnv)
        // Deliberately add `!.relay` in .gitignore to verify R47 pathspec exclusion `:(exclude).relay`
        try "!.relay\n!.relay/**\n".write(to: repoDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", ".gitignore"], cwd: repoDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "init with !.relay"], cwd: repoDir.path, environment: gitEnv)
        let baseOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Install a failing pre-commit hook to verify `--no-verify` skips hooks in M1
        let hooksDir = repoDir.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let preCommitURL = hooksDir.appendingPathComponent("pre-commit")
        try "#!/bin/sh\necho 'hook should be skipped' >&2\nexit 1\n".write(to: preCommitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preCommitURL.path)

        let runID = "20261116-010500-c0de"
        let wtRoot = tempRoot.appendingPathComponent("runs/\(runID)/worktrees", isDirectory: true)

        // Case 1: Changes + .relay/ files -> commits ONLY non-.relay files, uses repo identity, skips pre-commit hook
        let wt1 = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            runID: runID,
            laneID: "api",
            displayName: "api",
            vendor: .claudeCode,
            baseRef: baseOID,
            worktreesRootDirectory: wtRoot.path,
            environment: gitEnv
        )
        let wt1URL = URL(fileURLWithPath: wt1.worktreePath)
        try FileManager.default.createDirectory(at: wt1URL.appendingPathComponent(".relay"), withIntermediateDirectories: true)
        try "## 01-claude: ok, 1s, 2026-11-16 01:05\n".write(
            to: wt1URL.appendingPathComponent(".relay/LOG.md"),
            atomically: true,
            encoding: .utf8
        )
        try "export const api = 1;\n".write(
            to: wt1URL.appendingPathComponent("api.ts"),
            atomically: true,
            encoding: .utf8
        )
        let res1 = try engine.commitLaneChangesIfNeeded(
            worktreePath: wt1.worktreePath,
            startCommitOID: baseOID,
            runID: runID,
            laneID: "api",
            agent: .claude,
            status: .succeeded,
            environment: gitEnv
        )
        guard case .committed(let commit1OID) = res1 else {
            Issue.record("Expected .committed, got \(res1)")
            return
        }
        #expect(commit1OID != baseOID)
        let changed1 = try engine.runGit(["diff", "--name-only", "\(baseOID)..\(commit1OID)"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(changed1 == "api.ts")
        let subject1 = try engine.runGit(["log", "-1", "--format=%s", commit1OID], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(subject1 == "relay \(runID) api (claude): succeeded")
        let author1 = try engine.runGit(["log", "-1", "--format=%an <%ae>", commit1OID], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(author1 == "Lane Committer <committer@relay.invalid>")

        // Case 2: Only .relay/ files, no repo changes -> `.noChanges`, zero new commits
        let wt2 = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            runID: runID,
            laneID: "noop",
            displayName: "noop",
            vendor: .codex,
            baseRef: baseOID,
            worktreesRootDirectory: wtRoot.path,
            environment: gitEnv
        )
        let wt2URL = URL(fileURLWithPath: wt2.worktreePath)
        try FileManager.default.createDirectory(at: wt2URL.appendingPathComponent(".relay"), withIntermediateDirectories: true)
        try "log\n".write(to: wt2URL.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        let res2 = try engine.commitLaneChangesIfNeeded(
            worktreePath: wt2.worktreePath,
            startCommitOID: baseOID,
            runID: runID,
            laneID: "noop",
            agent: .codex,
            status: .succeeded,
            environment: gitEnv
        )
        #expect(res2 == .noChanges(headCommitOID: baseOID))
        let count2 = try engine.runGit(["rev-list", "--count", "\(baseOID)..\(wt2.branchName)"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(count2 == "0")

        // Case 3: Agent already committed its own work (`--no-verify`) + left an unstaged file -> preserves agent commit + adds 1 RelayIDE commit
        let wt3 = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            runID: runID,
            laneID: "selfcommit",
            displayName: "selfcommit",
            vendor: .antigravity,
            baseRef: baseOID,
            worktreesRootDirectory: wtRoot.path,
            environment: gitEnv
        )
        let wt3URL = URL(fileURLWithPath: wt3.worktreePath)
        try "step1\n".write(to: wt3URL.appendingPathComponent("step1.txt"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "step1.txt"], cwd: wt3.worktreePath, environment: gitEnv)
        _ = try engine.runGit(["commit", "--no-verify", "-m", "agent own commit"], cwd: wt3.worktreePath, environment: gitEnv)
        let agentCommitOID = try engine.runGit(["rev-parse", "HEAD"], cwd: wt3.worktreePath, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "step2\n".write(to: wt3URL.appendingPathComponent("step2.txt"), atomically: true, encoding: .utf8)
        let res3 = try engine.commitLaneChangesIfNeeded(
            worktreePath: wt3.worktreePath,
            startCommitOID: baseOID,
            runID: runID,
            laneID: "selfcommit",
            agent: .agy,
            status: .partial,
            environment: gitEnv
        )
        guard case .committed(let relayTopOID) = res3 else {
            Issue.record("Expected .committed on top of agent commit, got \(res3)")
            return
        }
        let parentOfTop = try engine.runGit(["rev-parse", "\(relayTopOID)^"], cwd: repoDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(parentOfTop == agentCommitOID)

        // Case 3b: Calling commitLaneChangesIfNeeded again when HEAD != startCommitOID and only .relay changed preserves HEAD
        try FileManager.default.createDirectory(at: wt3URL.appendingPathComponent(".relay"), withIntermediateDirectories: true)
        try "log2\n".write(to: wt3URL.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        let res3b = try engine.commitLaneChangesIfNeeded(
            worktreePath: wt3.worktreePath,
            startCommitOID: baseOID,
            runID: runID,
            laneID: "selfcommit",
            agent: .agy,
            status: .succeeded,
            environment: gitEnv
        )
        #expect(res3b == .preservedExistingCommits(headCommitOID: relayTopOID))

        // Case 4: Failed lane dirty files -> listUncommittedFilesExcludingRelay lists dirty files without .relay/
        let wt4 = try engine.createLaneWorktree(
            repositoryPath: repoDir.path,
            runID: runID,
            laneID: "dirty",
            displayName: "dirty",
            vendor: .mistralVibe,
            baseRef: baseOID,
            worktreesRootDirectory: wtRoot.path,
            environment: gitEnv
        )
        let wt4URL = URL(fileURLWithPath: wt4.worktreePath)
        try FileManager.default.createDirectory(at: wt4URL.appendingPathComponent(".relay"), withIntermediateDirectories: true)
        try "log\n".write(to: wt4URL.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: wt4URL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try "# modified\n".write(to: wt4URL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let dirtyList = try engine.listUncommittedFilesExcludingRelay(in: wt4.worktreePath, environment: gitEnv)
        #expect(dirtyList == [".gitignore", "untracked.txt"])

        // Case 5: Real `relay.sh` writes `.relay/` into `.git/info/exclude` on a normal repository without `.gitignore` negation;
        // `commitLaneChangesIfNeeded` must succeed (exit 0) and commit only non-`.relay` files without failing on ignored pathspecs.
        let repoInfoExcludeDir = tempRoot.appendingPathComponent("repo-info-exclude", isDirectory: true)
        try FileManager.default.createDirectory(at: repoInfoExcludeDir, withIntermediateDirectories: true)
        _ = try engine.runGit(["init", "-b", "main"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.name", "Lane Committer"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
        _ = try engine.runGit(["config", "user.email", "committer@relay.invalid"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
        try "readme\n".write(to: repoInfoExcludeDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try engine.runGit(["add", "README.md"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
        _ = try engine.runGit(["commit", "-m", "init"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
        let baseInfoOID = try engine.runGit(["rev-parse", "HEAD"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let infoExcludeURL = repoInfoExcludeDir.appendingPathComponent(".git/info/exclude")
        try FileManager.default.createDirectory(at: infoExcludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ".relay/\n".write(to: infoExcludeURL, atomically: true, encoding: .utf8)

        let wt5 = try engine.createLaneWorktree(
            repositoryPath: repoInfoExcludeDir.path,
            runID: runID,
            laneID: "real-relay",
            displayName: "real-relay",
            vendor: .claudeCode,
            baseRef: baseInfoOID,
            worktreesRootDirectory: tempRoot.appendingPathComponent("runs-ie/\(runID)/worktrees").path,
            environment: gitEnv
        )
        let wt5URL = URL(fileURLWithPath: wt5.worktreePath)
        try FileManager.default.createDirectory(at: wt5URL.appendingPathComponent(".relay"), withIntermediateDirectories: true)
        try "## 01-claude: ok, 1s, 2026-11-16 01:06\n".write(to: wt5URL.appendingPathComponent(".relay/LOG.md"), atomically: true, encoding: .utf8)
        try "hello\n".write(to: wt5URL.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        let res5 = try engine.commitLaneChangesIfNeeded(
            worktreePath: wt5.worktreePath,
            startCommitOID: baseInfoOID,
            runID: runID,
            laneID: "real-relay",
            agent: .claude,
            status: .succeeded,
            environment: gitEnv
        )
        guard case .committed(let commit5OID) = res5 else {
            Issue.record("Expected .committed when .relay/ is in .git/info/exclude, got \(res5)")
            return
        }
        let changed5 = try engine.runGit(["diff", "--name-only", "\(baseInfoOID)..\(commit5OID)"], cwd: repoInfoExcludeDir.path, environment: gitEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(changed5 == "feature.txt")
    }
}
