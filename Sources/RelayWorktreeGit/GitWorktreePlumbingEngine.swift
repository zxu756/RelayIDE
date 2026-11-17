import CryptoKit
import Darwin
import Foundation
import RelayModels

@_silgen_name("flock")
private func gitPlumbingFlock(_ fd: Int32, _ operation: Int32) -> Int32

// MARK: - Git Worktree Matrix, Commit DAG & Merge-Base Plumbing Engine

public struct GitWorktreePlumbingEngine: Sendable {
    public let gitExecutablePath: String

    public init(gitExecutablePath: String = "/usr/bin/git") {
        self.gitExecutablePath = gitExecutablePath
    }

    public func verifyGitRepository(at repoPath: String) throws -> String {
        let out = try runGit(["rev-parse", "--show-toplevel"], cwd: repoPath)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RelayIDEError.gitRepositoryNotFound(repoPath)
        }
        return trimmed
    }

    public func headCommitOID(at repoPath: String) throws -> String {
        try runGit(["rev-parse", "HEAD"], cwd: repoPath).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum LaneCommitResult: Sendable, Equatable {
        case committed(commitOID: String)
        case preservedExistingCommits(headCommitOID: String)
        case noChanges(headCommitOID: String)
    }

    public struct IntegrationWorktreeHandle: Sendable, Hashable, Equatable {
        public let runID: String
        public let branchName: String
        public let worktreePath: String
        public let baseCommitOID: String

        public init(runID: String, branchName: String, worktreePath: String, baseCommitOID: String) {
            self.runID = runID
            self.branchName = branchName
            self.worktreePath = worktreePath
            self.baseCommitOID = baseCommitOID
        }
    }

    public enum SingleLaneGitMergeOutcome: Sendable, Equatable {
        case noChanges
        case merged(mergeCommitOID: String)
        case conflict(
            conflicts: [RelayMergeConflictItem],
            conflictLines: [String],
            headCommitOID: String
        )
        case nonConflictError(
            exitCode: Int32,
            lastStderrLine: String,
            command: String
        )
    }

    public static let unmergedPorcelainStatusCodes: Set<String> = [
        "DD", "AU", "UD", "UA", "DU", "AA", "UU"
    ]

    public func mergeLaneCommitInIntegrationWorktree(
        integrationWorktreePath: String,
        runID: String,
        laneID: String,
        agent: RelayPlanAgent,
        laneBranchName: String? = nil,
        laneCommitOID: String?,
        environment: [String: String]? = nil
    ) throws -> SingleLaneGitMergeOutcome {
        var mergeEnv = environment ?? ProcessInfo.processInfo.environment
        mergeEnv["GIT_TERMINAL_PROMPT"] = "0"
        mergeEnv["GIT_MERGE_AUTOEDIT"] = "no"

        guard let rawCommitOID = laneCommitOID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCommitOID.isEmpty else {
            return .noChanges
        }
        guard Self.isHexObjectID(rawCommitOID) else {
            throw RelayIDEError.relayEnvironmentFailure(
                "Merge target commitOID for lane '\(laneID)' must be a hex object ID, got '\(rawCommitOID)'"
            )
        }

        let preMergeHead = try runGit(["rev-parse", "--verify", "HEAD"], cwd: integrationWorktreePath, environment: mergeEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ancestorCheck = try runGitCommand(
            ["merge-base", "--is-ancestor", rawCommitOID, "HEAD"],
            cwd: integrationWorktreePath,
            environment: mergeEnv
        )
        if ancestorCheck.exitCode == 0 {
            return .noChanges
        } else if ancestorCheck.exitCode != 1 {
            let reasonLine = Self.preferredErrorReasonLine(
                stderr: ancestorCheck.stderr,
                stdout: ancestorCheck.stdout
            ) ?? "git merge-base --is-ancestor exited with \(ancestorCheck.exitCode)"
            return .nonConflictError(
                exitCode: ancestorCheck.exitCode,
                lastStderrLine: reasonLine,
                command: "git merge-base --is-ancestor \(rawCommitOID) HEAD"
            )
        }

        let subject = "relay \(runID) merge \(laneID) (\(agent.rawValue))"
        let effectiveLaneBranch = laneBranchName ?? "relay/\(runID)/\(laneID)"
        let body = """
        Lane branch: \(effectiveLaneBranch)
        Lane commit: \(rawCommitOID)
        Merged by RelayIDE; repository hooks skipped.
        """

        let mergeArgs: [String] = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "rerere.enabled=false",
            "-c", "gc.auto=0",
            "-c", "maintenance.auto=false",
            "-c", "user.useConfigOnly=true",
            "merge",
            "--no-ff",
            "--no-edit",
            "--no-log",
            "--no-stat",
            "--no-squash",
            "--no-autostash",
            "--no-verify-signatures",
            "--no-gpg-sign",
            "-m", subject,
            "-m", body,
            rawCommitOID
        ]

        let mergeResult = try runGitCommand(
            mergeArgs,
            cwd: integrationWorktreePath,
            environment: mergeEnv
        )

        if mergeResult.exitCode == 0 {
            let newHead = try runGit(["rev-parse", "--verify", "HEAD"], cwd: integrationWorktreePath, environment: mergeEnv)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let p1Res = try runGitCommand(
                ["rev-parse", "--verify", "--quiet", "HEAD^1"],
                cwd: integrationWorktreePath,
                environment: mergeEnv
            )
            let p2Res = try runGitCommand(
                ["rev-parse", "--verify", "--quiet", "HEAD^2"],
                cwd: integrationWorktreePath,
                environment: mergeEnv
            )
            let p1 = p1Res.exitCode == 0 ? p1Res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let p2 = p2Res.exitCode == 0 ? p2Res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard p1 == preMergeHead, p2 == rawCommitOID else {
                throw RelayIDEError.relayEnvironmentFailure(
                    "Merge commit parent check failed for lane '\(laneID)': expected HEAD^1=\(preMergeHead) HEAD^2=\(rawCommitOID), got HEAD^1='\(p1)' HEAD^2='\(p2)'"
                )
            }
            return .merged(mergeCommitOID: newHead)
        }

        if try hasMergeHead(in: integrationWorktreePath, environment: mergeEnv) {
            let conflicts = try listUnmergedConflictItems(in: integrationWorktreePath, environment: mergeEnv)
            let conflictLines = Self.extractConflictLines(stdout: mergeResult.stdout, stderr: mergeResult.stderr)
            try abortInProgressMergeAndVerifyClean(
                in: integrationWorktreePath,
                expectedHeadOID: preMergeHead,
                environment: mergeEnv
            )
            return .conflict(
                conflicts: conflicts,
                conflictLines: conflictLines,
                headCommitOID: preMergeHead
            )
        } else {
            let reasonLine = Self.preferredErrorReasonLine(
                stderr: mergeResult.stderr,
                stdout: mergeResult.stdout
            ) ?? "git merge exited with \(mergeResult.exitCode)"
            return .nonConflictError(
                exitCode: mergeResult.exitCode,
                lastStderrLine: reasonLine,
                command: "git " + mergeArgs.joined(separator: " ")
            )
        }
    }

    public func hasMergeHead(
        in worktreePath: String,
        environment: [String: String]? = nil
    ) throws -> Bool {
        let revCheck = try runGitCommand(
            ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
            cwd: worktreePath,
            environment: environment
        )
        if revCheck.exitCode == 0 {
            return true
        }
        let pathCheck = try runGitCommand(
            ["rev-parse", "--git-path", "MERGE_HEAD"],
            cwd: worktreePath,
            environment: environment
        )
        guard pathCheck.exitCode == 0 else {
            return false
        }
        let rawPath = pathCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            return false
        }
        let resolvedPath: String
        if (rawPath as NSString).isAbsolutePath {
            resolvedPath = rawPath
        } else {
            resolvedPath = URL(fileURLWithPath: rawPath, relativeTo: URL(fileURLWithPath: worktreePath, isDirectory: true))
                .standardizedFileURL
                .path
        }
        return FileManager.default.fileExists(atPath: resolvedPath)
    }

    public func listUnmergedConflictItems(
        in worktreePath: String,
        environment: [String: String]? = nil
    ) throws -> [RelayMergeConflictItem] {
        let raw = try runGit(
            ["status", "--porcelain=v1", "-z"],
            cwd: worktreePath,
            environment: environment
        )
        let bytes = Array(raw.utf8)
        var slices: [ArraySlice<UInt8>] = []
        var cursor = 0
        while cursor < bytes.count {
            var end = cursor
            while end < bytes.count && bytes[end] != 0 {
                end += 1
            }
            if end > cursor {
                slices.append(bytes[cursor..<end])
            }
            cursor = end + 1
        }

        var conflicts: [RelayMergeConflictItem] = []
        var idx = 0
        while idx < slices.count {
            let entry = Array(slices[idx])
            idx += 1
            guard entry.count >= 4, entry[2] == 0x20 else { continue }
            let code = String(decoding: entry[0..<2], as: UTF8.self)
            let path = String(decoding: entry[3...], as: UTF8.self)
            if entry[0] == UInt8(ascii: "R") || entry[0] == UInt8(ascii: "C") {
                if idx < slices.count {
                    idx += 1
                }
            }
            if Self.unmergedPorcelainStatusCodes.contains(code) {
                conflicts.append(RelayMergeConflictItem(path: path, code: code))
            }
        }
        return conflicts
    }

    public func abortInProgressMergeAndVerifyClean(
        in worktreePath: String,
        expectedHeadOID: String,
        environment: [String: String]? = nil
    ) throws {
        var abortEnv = environment ?? ProcessInfo.processInfo.environment
        abortEnv["GIT_TERMINAL_PROMPT"] = "0"
        abortEnv["GIT_MERGE_AUTOEDIT"] = "no"

        let abortArgs: [String] = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "rerere.enabled=false",
            "-c", "gc.auto=0",
            "-c", "maintenance.auto=false",
            "-c", "user.useConfigOnly=true",
            "merge",
            "--abort"
        ]
        let abortRes = try runGitCommand(abortArgs, cwd: worktreePath, environment: abortEnv)
        guard abortRes.exitCode == 0 else {
            let detail = Self.lastNonEmptyLine(of: abortRes.stderr) ?? "exit \(abortRes.exitCode)"
            throw RelayIDEError.gitPlumbingFailure(
                command: "git " + abortArgs.joined(separator: " "),
                exitCode: abortRes.exitCode,
                stderr: detail
            )
        }

        let postHead = try runGit(["rev-parse", "--verify", "HEAD"], cwd: worktreePath, environment: abortEnv)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard postHead == expectedHeadOID else {
            throw RelayIDEError.relayEnvironmentFailure(
                "git merge --abort left HEAD at \(postHead), expected \(expectedHeadOID)"
            )
        }

        if try hasMergeHead(in: worktreePath, environment: abortEnv) {
            throw RelayIDEError.relayEnvironmentFailure(
                "git merge --abort left MERGE_HEAD present in '\(worktreePath)'"
            )
        }

        let statusRes = try runGitCommand(
            ["status", "--porcelain=v1", "-uall", "--ignored"],
            cwd: worktreePath,
            environment: abortEnv
        )
        guard statusRes.exitCode == 0, statusRes.stdout.isEmpty else {
            let dirtySummary = statusRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RelayIDEError.relayEnvironmentFailure(
                "git merge --abort left unclean integration worktree: \(dirtySummary)"
            )
        }
    }

    public static func extractConflictLines(stdout: String, stderr: String) -> [String] {
        var lines: [String] = []
        for source in [stdout, stderr] {
            let normalized = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine)
                if line.hasPrefix("CONFLICT") {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    public static func preferredErrorReasonLine(stderr: String, stdout: String = "") -> String? {
        let normalizedStderr = stderr
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var nonEmptyStderrLines: [String] = []
        for rawLine in normalizedStderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("error:") || trimmed.hasPrefix("fatal:") {
                return trimmed
            }
            nonEmptyStderrLines.append(trimmed)
        }
        if let lastStderr = nonEmptyStderrLines.last {
            return lastStderr
        }
        return lastNonEmptyLine(of: stdout)
    }

    public static func lastNonEmptyLine(of text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    public func createIntegrationWorktree(
        repositoryPath: String,
        projectBundlePath: String,
        runID: String,
        baseCommitOID: String,
        environment: [String: String]? = nil
    ) throws -> IntegrationWorktreeHandle {
        guard RelayPlanLaneSpec.isValidRunID(runID) else {
            throw RelayIDEError.relayEnvironmentFailure(
                "Invalid run id '\(runID)' for integration worktree"
            )
        }
        let trimmedBaseOID = baseCommitOID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isHexObjectID(trimmedBaseOID) else {
            throw RelayIDEError.relayEnvironmentFailure(
                "Integration worktree requires a resolved commit OID (not a ref name), got '\(baseCommitOID)'"
            )
        }

        let worktreesRootDirectory = URL(fileURLWithPath: projectBundlePath, isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .path
        let worktreePath = (worktreesRootDirectory as NSString).appendingPathComponent("integration")
        let branchName = "relay/\(runID)/integration"

        return try withExclusiveRepositoryWorktreeLock(repositoryPath: repositoryPath, environment: environment) {
            if FileManager.default.fileExists(atPath: worktreePath)
                || (try? FileManager.default.attributesOfItem(atPath: worktreePath)) != nil {
                throw RelayIDEError.worktreeAlreadyExists(worktreePath)
            }

            let branchExistsCheck = try runGitCommand(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
                cwd: repositoryPath,
                environment: environment
            )
            if branchExistsCheck.exitCode == 0 {
                throw RelayIDEError.gitPlumbingFailure(
                    command: "git -c core.hooksPath=/dev/null worktree add -b \(branchName) \(worktreePath) \(trimmedBaseOID)",
                    exitCode: 128,
                    stderr: "fatal: a branch named '\(branchName)' already exists"
                )
            }

            do {
                try FileManager.default.createDirectory(
                    atPath: worktreesRootDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw RelayIDEError.relayEnvironmentFailure(
                    "Failed to create integration worktrees directory '\(worktreesRootDirectory)': \(error.localizedDescription)"
                )
            }

            _ = try runGit(
                ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", branchName, worktreePath, trimmedBaseOID],
                cwd: repositoryPath,
                environment: environment
            )
            return IntegrationWorktreeHandle(
                runID: runID,
                branchName: branchName,
                worktreePath: worktreePath,
                baseCommitOID: trimmedBaseOID
            )
        }
    }

    public static func isHexObjectID(_ candidate: String) -> Bool {
        let bytes = Array(candidate.utf8)
        guard bytes.count == 40 || bytes.count == 64 else { return false }
        for b in bytes {
            let isDigit = (b >= 0x30 && b <= 0x39)
            let isLowerHex = (b >= 0x61 && b <= 0x66)
            let isUpperHex = (b >= 0x41 && b <= 0x46)
            guard isDigit || isLowerHex || isUpperHex else { return false }
        }
        return true
    }

    public func createLaneWorktree(
        repositoryPath: String,
        runID: String = "manual",
        laneID: String,
        displayName: String,
        vendor: AgentVendor,
        baseRef: String = "HEAD",
        worktreesRootDirectory: String,
        ownershipRule: FileOwnershipRule = FileOwnershipRule(),
        environment: [String: String]? = nil
    ) throws -> ManagedWorktreeLane {
        guard RelayPlanLaneSpec.isValidLaneID(laneID) else {
            let reservedHint = laneID == "integration" ? " ('integration' is reserved)" : ""
            throw RelayIDEError.invalidRunPlan(
                "Invalid lane id '\(laneID)'\(reservedHint): must match ^[a-z0-9][a-z0-9-]{0,39}$"
            )
        }
        guard RelayPlanLaneSpec.isValidRunID(runID) else {
            throw RelayIDEError.invalidRunPlan(
                "Invalid run id '\(runID)': must match ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"
            )
        }

        let baseOID = try runGit(["rev-parse", "--verify", "\(baseRef)^{commit}"], cwd: repositoryPath, environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreePath = (worktreesRootDirectory as NSString).appendingPathComponent(laneID)
        let branchName = "relay/\(runID)/\(laneID)"

        return try withExclusiveRepositoryWorktreeLock(repositoryPath: repositoryPath, environment: environment) {
            if FileManager.default.fileExists(atPath: worktreePath) {
                throw RelayIDEError.worktreeAlreadyExists(worktreePath)
            }

            let branchExistsCheck = try runGitCommand(
                ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
                cwd: repositoryPath,
                environment: environment
            )
            if branchExistsCheck.exitCode == 0 {
                throw RelayIDEError.gitPlumbingFailure(
                    command: "git -c core.hooksPath=/dev/null worktree add -b \(branchName) \(worktreePath) \(baseOID)",
                    exitCode: 128,
                    stderr: "fatal: a branch named '\(branchName)' already exists"
                )
            }

            do {
                try FileManager.default.createDirectory(
                    atPath: worktreesRootDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw RelayIDEError.relayEnvironmentFailure(
                    "Failed to create worktrees directory '\(worktreesRootDirectory)': \(error.localizedDescription)"
                )
            }

            _ = try runGit(
                ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", branchName, worktreePath, baseOID],
                cwd: repositoryPath,
                environment: environment
            )
            return ManagedWorktreeLane(
                id: laneID,
                displayName: displayName,
                assignedVendor: vendor,
                worktreePath: worktreePath,
                branchName: branchName,
                baseCommitOID: baseOID,
                headCommitOID: baseOID,
                dirtyFiles: [],
                ownershipRule: ownershipRule
            )
        }
    }

    private func withExclusiveRepositoryWorktreeLock<T>(
        repositoryPath: String,
        environment: [String: String]?,
        body: () throws -> T
    ) throws -> T {
        let commonDirOut = (try? runGitCommand(["rev-parse", "--git-common-dir"], cwd: repositoryPath, environment: environment))
        let rawKeyPath: String
        if let out = commonDirOut, out.exitCode == 0 {
            let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed as NSString).isAbsolutePath {
                rawKeyPath = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
            } else {
                rawKeyPath = URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: repositoryPath, isDirectory: true))
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
            }
        } else {
            rawKeyPath = URL(fileURLWithPath: repositoryPath).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let digestHex = SHA256.hash(data: Data(rawKeyPath.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayide-repo-wt-\(digestHex.prefix(24)).lock")

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return try body()
        }
        while gitPlumbingFlock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            Darwin.close(fd)
            return try body()
        }
        defer {
            _ = gitPlumbingFlock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        return try body()
    }

    public func commitLaneChangesIfNeeded(
        worktreePath: String,
        startCommitOID: String,
        runID: String,
        laneID: String,
        agent: RelayPlanAgent,
        status: RelayRunStatus,
        environment: [String: String]? = nil
    ) throws -> LaneCommitResult {
        // Stage all worktree changes, then explicitly reset `.relay` against `HEAD`.
        // Note: Passing `:(exclude).relay` to `git add` fails with exit code 1 on Apple Git whenever `relay.sh`
        // has written `.relay/` into `.git/info/exclude`; `git add -A -- .` + `git reset -q HEAD -- .relay`
        // succeeds in both ignored and `!.relay`-negated (R47) repositories while keeping `.relay/` out of commits.
        _ = try runGit(
            ["-c", "core.hooksPath=/dev/null", "add", "-A", "--", "."],
            cwd: worktreePath,
            environment: environment
        )
        _ = try runGit(
            ["-c", "core.hooksPath=/dev/null", "reset", "-q", "HEAD", "--", ".relay"],
            cwd: worktreePath,
            environment: environment
        )

        let diffCheck = try runGitCommand(
            ["diff", "--cached", "--quiet", "--exit-code"],
            cwd: worktreePath,
            environment: environment
        )
        if diffCheck.exitCode == 0 {
            let currentHead = try runGit(["rev-parse", "HEAD"], cwd: worktreePath, environment: environment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHead == startCommitOID {
                return .noChanges(headCommitOID: currentHead)
            } else {
                return .preservedExistingCommits(headCommitOID: currentHead)
            }
        } else if diffCheck.exitCode != 1 {
            throw RelayIDEError.gitPlumbingFailure(
                command: "git diff --cached --quiet --exit-code",
                exitCode: diffCheck.exitCode,
                stderr: diffCheck.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let subject = "relay \(runID) \(laneID) (\(agent.rawValue)): \(status.rawValue)"
        let body = "Committed by RelayIDE; repository hooks skipped."
        _ = try runGit(
            [
                "-c", "core.hooksPath=/dev/null",
                "-c", "user.useConfigOnly=true",
                "-c", "commit.gpgsign=false",
                "-c", "gc.auto=0",
                "-c", "maintenance.auto=false",
                "commit",
                "--no-verify",
                "--no-gpg-sign",
                "-m", subject,
                "-m", body
            ],
            cwd: worktreePath,
            environment: environment
        )
        let committedOID = try runGit(["rev-parse", "HEAD"], cwd: worktreePath, environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .committed(commitOID: committedOID)
    }

    public func listUncommittedFilesExcludingRelay(
        in worktreePath: String,
        environment: [String: String]? = nil
    ) throws -> [String] {
        let raw = try runGit(["status", "--porcelain=v1", "-z", "-uall"], cwd: worktreePath, environment: environment)
        let entries = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var collected = Set<String>()
        var idx = 0
        while idx < entries.count {
            let entry = entries[idx]
            idx += 1
            guard entry.count >= 4 else { continue }
            let xy = Array(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if xy[0] == "R" || xy[0] == "C" {
                // Skip the second NUL-terminated field (`orig_path`) in porcelain v1 `-z` mode
                if idx < entries.count {
                    idx += 1
                }
            }
            if path == ".relay" || path.hasPrefix(".relay/") {
                continue
            }
            collected.insert(path)
        }
        return collected.sorted()
    }

    public func removeLaneWorktree(repositoryPath: String, worktreePath: String, deleteBranch: String? = nil) throws {
        _ = try runGit(["-c", "core.hooksPath=/dev/null", "worktree", "remove", "--force", worktreePath], cwd: repositoryPath)
        if let branch = deleteBranch {
            _ = try? runGit(["-c", "core.hooksPath=/dev/null", "branch", "-D", branch], cwd: repositoryPath)
        }
    }

    public func parseCommitDAG(at repositoryPath: String, maxCount: Int = 60) throws -> [GitCommitNode] {
        let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s"
        let raw = try runGit(
            ["log", "--all", "--date-order", "-n", "\(max(1, maxCount))", "--format=\(format)"],
            cwd: repositoryPath
        )
        var nodes: [GitCommitNode] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            let oid = fields[0]
            let parents = fields[1].split(separator: " ").map(String.init)
            let authorName = fields[2]
            let authorEmail = fields[3]
            let epoch = TimeInterval(fields[4]) ?? Date().timeIntervalSince1970
            let decorations = fields[5]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let subject = fields[6]
            nodes.append(
                GitCommitNode(
                    oid: oid,
                    parentOIDs: parents,
                    authorName: authorName,
                    authorEmail: authorEmail,
                    authoredAt: Date(timeIntervalSince1970: epoch),
                    subject: subject,
                    decorations: decorations
                )
            )
        }
        return nodes
    }

    public func inspectDirtyDeltas(in worktreePath: String) throws -> [WorktreeFileDelta] {
        let statusOut = try runGit(["status", "--porcelain=v1", "-uall"], cwd: worktreePath)
        let numstatOut = (try? runGit(["diff", "--numstat", "HEAD"], cwd: worktreePath)) ?? ""

        var lineCountsByPath: [String: (add: Int, del: Int)] = [:]
        for line in numstatOut.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            let adds = Int(cols[0]) ?? 0
            let dels = Int(cols[1]) ?? 0
            lineCountsByPath[String(cols[2])] = (adds, dels)
        }

        var deltas: [WorktreeFileDelta] = []
        for rawLine in statusOut.split(whereSeparator: \.isNewline) {
            guard rawLine.count >= 4 else { continue }
            let xy = String(rawLine.prefix(2))
            let rest = String(rawLine.dropFirst(3))

            let status: WorktreeFileStatus
            if xy.contains("U") || xy == "AA" || xy == "DD" {
                status = .conflicted
            } else if xy == "??" {
                status = .untracked
            } else if xy.contains("R") {
                status = .renamed
            } else if xy.contains("A") {
                status = .added
            } else if xy.contains("D") {
                status = .deleted
            } else {
                status = .modified
            }

            var prevPath: String?
            var currentPath = rest
            if status == .renamed, let arrowRange = rest.range(of: " -> ") {
                prevPath = String(rest[..<arrowRange.lowerBound])
                currentPath = String(rest[arrowRange.upperBound...])
            }
            let stats = lineCountsByPath[currentPath] ?? (0, 0)
            deltas.append(
                WorktreeFileDelta(
                    relativePath: currentPath,
                    previousPath: prevPath,
                    status: status,
                    additions: stats.add,
                    deletions: stats.del
                )
            )
        }
        return deltas
    }

    public func mergeBase(repositoryPath: String, leftRef: String, rightRef: String) throws -> String {
        try runGit(["merge-base", leftRef, rightRef], cwd: repositoryPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func readBlobString(repositoryPath: String, revision: String, relativePath: String) -> String? {
        try? runGit(["show", "\(revision):\(relativePath)"], cwd: repositoryPath)
    }

    public func revertPathToHEAD(in worktreePath: String, relativePath: String) throws {
        let fullURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(relativePath)
        let trackedCheck = try? runGit(["ls-files", "--error-unmatch", relativePath], cwd: worktreePath)
        if trackedCheck != nil {
            _ = try runGit(["-c", "core.hooksPath=/dev/null", "checkout", "HEAD", "--", relativePath], cwd: worktreePath)
        } else if FileManager.default.fileExists(atPath: fullURL.path) {
            try FileManager.default.removeItem(at: fullURL)
        }
    }

    /// Bootstraps a deterministic Git repository with real branches for demos and automated testing.
    public func initializeDemoRepository(at directoryPath: String) throws -> String {
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        _ = try runGit(["init", "-b", "main"], cwd: directoryPath)
        _ = try runGit(["config", "user.name", "RelayIDE Bot"], cwd: directoryPath)
        _ = try runGit(["config", "user.email", "relay@local.dev"], cwd: directoryPath)

        let srcDir = (directoryPath as NSString).appendingPathComponent("Sources")
        try FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: true)
        let baseCode = """
        import Foundation

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                cents.reduce(0, +)
            }
        }
        """
        try baseCode.write(
            toFile: (srcDir as NSString).appendingPathComponent("BillingEngine.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try runGit(["-c", "core.hooksPath=/dev/null", "add", "."], cwd: directoryPath)
        _ = try runGit(
            ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--no-gpg-sign", "-m", "Initial commit"],
            cwd: directoryPath
        )
        return try headCommitOID(at: directoryPath)
    }

    @discardableResult
    public func runGit(
        _ arguments: [String],
        cwd: String,
        environment: [String: String]? = nil
    ) throws -> String {
        let result = try runGitCommand(arguments, cwd: cwd, environment: environment)
        guard result.exitCode == 0 else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "git " + arguments.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    public func runGitCommand(
        _ arguments: [String],
        cwd: String,
        environment: [String: String]? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitExecutablePath)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = environment ?? ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw RelayIDEError.gitPlumbingFailure(
                command: "git " + arguments.joined(separator: " "),
                exitCode: -1,
                stderr: error.localizedDescription
            )
        }

        // Drain stdout and stderr concurrently so large outputs can never deadlock on pipe buffer capacity (R37).
        final class DataBox: @unchecked Sendable { var data = Data() }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()

        return (
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }
}
