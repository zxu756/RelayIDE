import Foundation

// MARK: - M1 Run & Lane Fixed Status Vocabulary (`03-relayide.md` §13)

/// Fixed English status tokens shared across SQLite persistence, `run` JSON output, and `status --run` / `status --runs`.
/// Identical under `--lang en` and `--lang zh`.
public enum RelayRunStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case succeeded = "succeeded"
    case succeededNoChanges = "succeeded-no-changes"
    case partial = "partial"
    case failed = "failed"
    case timeout = "timeout"
    case refused = "refused"
    case skipped = "skipped"
    case cancelled = "cancelled"
    case killed = "killed"
    case interrupted = "interrupted"
    case running = "running"
    case pending = "pending"

    public var isTerminal: Bool {
        switch self {
        case .running, .pending:
            return false
        default:
            return true
        }
    }

    public func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .succeeded:
            return RelayLocalizer.select(language, "succeeded", "成功")
        case .succeededNoChanges:
            return RelayLocalizer.select(language, "succeeded (no changes)", "成功，无改动")
        case .partial:
            return RelayLocalizer.select(language, "partial", "部分完成")
        case .failed:
            return RelayLocalizer.select(language, "failed", "失败")
        case .timeout:
            return RelayLocalizer.select(language, "timeout", "超时")
        case .refused:
            return RelayLocalizer.select(language, "refused", "被拒绝")
        case .skipped:
            return RelayLocalizer.select(language, "skipped", "已跳过")
        case .cancelled:
            return RelayLocalizer.select(language, "cancelled", "已取消")
        case .killed:
            return RelayLocalizer.select(language, "killed", "被强制结束")
        case .interrupted:
            return RelayLocalizer.select(language, "interrupted", "中断")
        case .running:
            return RelayLocalizer.select(language, "running", "运行中")
        case .pending:
            return RelayLocalizer.select(language, "pending", "待命")
        }
    }
}

// MARK: - Supported Headless Vendors in `plan.json`

public enum RelayPlanAgent: String, Sendable, Codable, Hashable, CaseIterable {
    case claude = "claude"
    case codex = "codex"
    case agy = "agy"
    case vibe = "vibe"

    public var agentVendor: AgentVendor {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codex
        case .agy: return .antigravity
        case .vibe: return .mistralVibe
        }
    }
}

// MARK: - Raw & Validated `plan.json` Models

public struct RelayPlanLaneSpec: Sendable, Codable, Hashable, Equatable {
    public let id: String
    public let agent: String
    public let prompt: String
    public let after: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case agent
        case prompt
        case after
    }

    public init(id: String, agent: String, prompt: String, after: [String] = []) {
        self.id = id
        self.agent = agent
        self.prompt = prompt
        self.after = after
    }

    /// Enforces `^[a-z0-9][a-z0-9-]{0,39}$` strictly over ASCII bytes and reserves `"integration"` (`03-relayide.md` §2, R36).
    public static func isValidLaneID(_ id: String) -> Bool {
        guard id != "integration" else { return false }
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count <= 40 else { return false }
        let isLowercaseOrDigit: (UInt8) -> Bool = { b in
            (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
        }
        guard isLowercaseOrDigit(bytes[0]) else { return false }
        for b in bytes.dropFirst() {
            guard isLowercaseOrDigit(b) || b == 0x2D else { return false }
        }
        return true
    }

    /// Enforces safe single-segment ASCII run identifier (`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`, no slashes or `..`).
    public static func isValidRunID(_ runID: String) -> Bool {
        let bytes = Array(runID.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        let isAlphaNum: (UInt8) -> Bool = { b in
            (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
        }
        guard isAlphaNum(bytes[0]) else { return false }
        for b in bytes.dropFirst() {
            guard isAlphaNum(b) || b == 0x2D || b == 0x5F else { return false }
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.agent = try container.decode(String.self, forKey: .agent)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        if container.contains(.after) {
            if try container.decodeNil(forKey: .after) {
                self.after = []
            } else {
                self.after = try container.decode([String].self, forKey: .after)
            }
        } else {
            self.after = []
        }
    }
}

public struct RelayRunPlan: Sendable, Codable, Hashable, Equatable {
    public let repo: String
    public let base: String
    public let lanes: [RelayPlanLaneSpec]
    public let verify: String?

    private enum CodingKeys: String, CodingKey {
        case repo
        case base
        case lanes
        case verify
    }

    public init(repo: String, base: String, lanes: [RelayPlanLaneSpec], verify: String? = nil) {
        self.repo = repo
        self.base = base
        self.lanes = lanes
        self.verify = verify
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.base = try container.decode(String.self, forKey: .base)
        self.lanes = try container.decode([RelayPlanLaneSpec].self, forKey: .lanes)
        if container.contains(.verify) {
            if try container.decodeNil(forKey: .verify) {
                self.verify = nil
            } else {
                self.verify = try container.decode(String.self, forKey: .verify)
            }
        } else {
            self.verify = nil
        }
    }
}

public struct RelayValidatedLaneSpec: Sendable, Hashable, Equatable {
    public let ordinal: Int
    public let id: String
    public let agent: RelayPlanAgent
    public let rawPrompt: String
    public let resolvedPromptURL: URL
    public let after: [String]

    public init(
        ordinal: Int,
        id: String,
        agent: RelayPlanAgent,
        rawPrompt: String,
        resolvedPromptURL: URL,
        after: [String]
    ) {
        self.ordinal = ordinal
        self.id = id
        self.agent = agent
        self.rawPrompt = rawPrompt
        self.resolvedPromptURL = resolvedPromptURL
        self.after = after
    }
}

public struct RelayValidatedRunPlan: Sendable, Hashable, Equatable {
    public let planFileURL: URL
    public let rawPlanData: Data
    public let plan: RelayRunPlan
    public let resolvedRepoURL: URL
    public let baseRef: String
    public let baseCommitOID: String
    public let lanes: [RelayValidatedLaneSpec]
    public let verifyCommand: String?

    public init(
        planFileURL: URL,
        rawPlanData: Data,
        plan: RelayRunPlan,
        resolvedRepoURL: URL,
        baseRef: String,
        baseCommitOID: String,
        lanes: [RelayValidatedLaneSpec],
        verifyCommand: String?
    ) {
        self.planFileURL = planFileURL
        self.rawPlanData = rawPlanData
        self.plan = plan
        self.resolvedRepoURL = resolvedRepoURL
        self.baseRef = baseRef
        self.baseCommitOID = baseCommitOID
        self.lanes = lanes
        self.verifyCommand = verifyCommand
    }
}

// MARK: - Persisted Run & Lane Records (`relay_runs` / `relay_run_lanes` + JSON Output)

public struct RelayRunLaneRecord: Sendable, Hashable, Equatable, Identifiable, Codable {
    public var id: String { "\(runID):\(laneID)" }
    public let runID: String
    public let laneID: String
    public let ordinal: Int
    public let agent: RelayPlanAgent
    public let promptPath: String
    public let after: [String]
    public var status: RelayRunStatus
    public var exitCode: Int32?
    public var signal: Int32?
    public var reason: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var pid: Int32?
    public var costUSD: Double?
    public var tokens: Int?
    public var costSource: String?
    public var branch: String?
    public var commitOID: String?
    public var worktreePath: String?
    public var uncommittedFiles: [String]?

    private enum CodingKeys: String, CodingKey {
        case runID
        case laneID
        case ordinal
        case agent
        case promptPath
        case after
        case status
        case exitCode
        case signal
        case reason
        case startedAt
        case finishedAt
        case pid
        case costUSD
        case tokens
        case costSource
        case branch
        case commitOID
        case worktreePath
        case uncommittedFiles
    }

    public init(
        runID: String,
        laneID: String,
        ordinal: Int,
        agent: RelayPlanAgent,
        promptPath: String,
        after: [String] = [],
        status: RelayRunStatus = .pending,
        exitCode: Int32? = nil,
        signal: Int32? = nil,
        reason: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        pid: Int32? = nil,
        costUSD: Double? = nil,
        tokens: Int? = nil,
        costSource: String? = nil,
        branch: String? = nil,
        commitOID: String? = nil,
        worktreePath: String? = nil,
        uncommittedFiles: [String]? = nil
    ) {
        self.runID = runID
        self.laneID = laneID
        self.ordinal = ordinal
        self.agent = agent
        self.promptPath = promptPath
        self.after = after
        self.status = status
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pid = pid
        self.costUSD = costUSD
        self.tokens = tokens
        self.costSource = costSource
        self.branch = branch
        self.commitOID = commitOID
        self.worktreePath = worktreePath
        self.uncommittedFiles = uncommittedFiles
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runID, forKey: .runID)
        try c.encode(laneID, forKey: .laneID)
        try c.encode(ordinal, forKey: .ordinal)
        try c.encode(agent, forKey: .agent)
        try c.encode(promptPath, forKey: .promptPath)
        try c.encode(after, forKey: .after)
        try c.encode(status, forKey: .status)
        try encodeNullable(exitCode, into: &c, forKey: .exitCode)
        try encodeNullable(signal, into: &c, forKey: .signal)
        try encodeNullable(reason, into: &c, forKey: .reason)
        try encodeNullable(startedAt, into: &c, forKey: .startedAt)
        try encodeNullable(finishedAt, into: &c, forKey: .finishedAt)
        try encodeNullable(pid, into: &c, forKey: .pid)
        try encodeNullable(costUSD, into: &c, forKey: .costUSD)
        try encodeNullable(tokens, into: &c, forKey: .tokens)
        try encodeNullable(costSource, into: &c, forKey: .costSource)
        try encodeNullable(branch, into: &c, forKey: .branch)
        try encodeNullable(commitOID, into: &c, forKey: .commitOID)
        try encodeNullable(worktreePath, into: &c, forKey: .worktreePath)
        try encodeNullable(uncommittedFiles, into: &c, forKey: .uncommittedFiles)
    }
}

// MARK: - M2 Integration, Merge & Verify Fixed Status Vocabularies (`03-relayide.md` M2 §9, §10)

/// Fixed English status tokens for `integration.status`, identical under `--lang en` and `--lang zh`.
public enum RelayIntegrationStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case pending = "pending"
    case skipped = "skipped"
    case nothingToMerge = "nothing-to-merge"
    case merging = "merging"
    case conflict = "conflict"
    case merged = "merged"
    case verifying = "verifying"
    case verifyFailed = "verify-failed"
    case verifyTimeout = "verify-timeout"
    case verified = "verified"
    case cancelled = "cancelled"
    case interrupted = "interrupted"
    case error = "error"

    public var isTerminal: Bool {
        switch self {
        case .pending, .merging, .verifying:
            return false
        default:
            return true
        }
    }

    public func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .pending:
            return RelayLocalizer.select(language, "pending", "待命")
        case .skipped:
            return RelayLocalizer.select(language, "skipped", "已跳过")
        case .nothingToMerge:
            return RelayLocalizer.select(language, "nothing to merge", "无改动可合并")
        case .merging:
            return RelayLocalizer.select(language, "merging", "合并中")
        case .conflict:
            return RelayLocalizer.select(language, "conflict", "冲突")
        case .merged:
            return RelayLocalizer.select(language, "merged", "已合并")
        case .verifying:
            return RelayLocalizer.select(language, "verifying", "验证中")
        case .verifyFailed:
            return RelayLocalizer.select(language, "verify failed", "验证失败")
        case .verifyTimeout:
            return RelayLocalizer.select(language, "verify timeout", "验证超时")
        case .verified:
            return RelayLocalizer.select(language, "verified", "已验证")
        case .cancelled:
            return RelayLocalizer.select(language, "cancelled", "已取消")
        case .interrupted:
            return RelayLocalizer.select(language, "interrupted", "中断")
        case .error:
            return RelayLocalizer.select(language, "error", "出错")
        }
    }
}

/// Fixed English status tokens for per-lane `relay_run_merges` / `integration.merges[*].status`.
public enum RelayMergeStepStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case merged = "merged"
    case noChanges = "no-changes"
    case conflict = "conflict"
    case notAttempted = "not-attempted"

    public func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .merged:
            return RelayLocalizer.select(language, "merged", "已合并")
        case .noChanges:
            return RelayLocalizer.select(language, "no changes", "无改动")
        case .conflict:
            return RelayLocalizer.select(language, "conflict", "冲突")
        case .notAttempted:
            return RelayLocalizer.select(language, "not attempted", "未尝试")
        }
    }
}

/// Fixed English status tokens for `integration.verify.status`.
public enum RelayVerifyStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case running = "running"
    case passed = "passed"
    case failed = "failed"
    case timeout = "timeout"
    case cancelled = "cancelled"
    case interrupted = "interrupted"

    public var isTerminal: Bool {
        switch self {
        case .running:
            return false
        default:
            return true
        }
    }

    public func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .running:
            return RelayLocalizer.select(language, "running", "运行中")
        case .passed:
            return RelayLocalizer.select(language, "passed", "通过")
        case .failed:
            return RelayLocalizer.select(language, "failed", "失败")
        case .timeout:
            return RelayLocalizer.select(language, "timeout", "超时")
        case .cancelled:
            return RelayLocalizer.select(language, "cancelled", "已取消")
        case .interrupted:
            return RelayLocalizer.select(language, "interrupted", "中断")
        }
    }
}

public struct RelayMergeConflictItem: Sendable, Codable, Hashable, Equatable {
    public let path: String
    public let code: String

    public init(path: String, code: String) {
        self.path = path
        self.code = code
    }
}

public struct RelayRunMergeRecord: Sendable, Codable, Hashable, Equatable, Identifiable {
    public var id: String { laneID }
    public var ordinal: Int
    public let laneID: String
    public var laneCommitOID: String?
    public var status: RelayMergeStepStatus
    public var mergeCommitOID: String?
    public var conflicts: [RelayMergeConflictItem]
    public var conflictLines: [String]
    public var startedAt: Date?
    public var finishedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case ordinal
        case laneID
        case laneCommitOID
        case status
        case mergeCommitOID
        case conflicts
        case conflictLines
        case startedAt
        case finishedAt
    }

    public init(
        ordinal: Int = 0,
        laneID: String,
        laneCommitOID: String? = nil,
        status: RelayMergeStepStatus,
        mergeCommitOID: String? = nil,
        conflicts: [RelayMergeConflictItem] = [],
        conflictLines: [String] = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.ordinal = ordinal
        self.laneID = laneID
        self.laneCommitOID = laneCommitOID
        self.status = status
        self.mergeCommitOID = mergeCommitOID
        self.conflicts = conflicts
        self.conflictLines = conflictLines
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        self.laneID = try c.decode(String.self, forKey: .laneID)
        self.laneCommitOID = try c.decodeIfPresent(String.self, forKey: .laneCommitOID)
        self.status = try c.decode(RelayMergeStepStatus.self, forKey: .status)
        self.mergeCommitOID = try c.decodeIfPresent(String.self, forKey: .mergeCommitOID)
        self.conflicts = try c.decodeIfPresent([RelayMergeConflictItem].self, forKey: .conflicts) ?? []
        self.conflictLines = try c.decodeIfPresent([String].self, forKey: .conflictLines) ?? []
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ordinal, forKey: .ordinal)
        try c.encode(laneID, forKey: .laneID)
        try encodeNullable(laneCommitOID, into: &c, forKey: .laneCommitOID)
        try c.encode(status, forKey: .status)
        try encodeNullable(mergeCommitOID, into: &c, forKey: .mergeCommitOID)
        try c.encode(conflicts, forKey: .conflicts)
        try c.encode(conflictLines, forKey: .conflictLines)
        try encodeNullable(startedAt, into: &c, forKey: .startedAt)
        try encodeNullable(finishedAt, into: &c, forKey: .finishedAt)
    }
}

public struct RelayRunVerifyRecord: Sendable, Codable, Hashable, Equatable {
    public var command: String
    public var timeoutSec: Int
    public var status: RelayVerifyStatus
    public var exitCode: Int32?
    public var signal: Int32?
    public var pid: Int32?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var logPath: String?
    public var logBytes: Int
    public var logTruncated: Bool
    public var modifiedTrackedFiles: [String]

    private enum CodingKeys: String, CodingKey {
        case command
        case timeoutSec
        case status
        case exitCode
        case signal
        case pid
        case startedAt
        case finishedAt
        case logPath
        case logBytes
        case logTruncated
        case modifiedTrackedFiles
    }

    public init(
        command: String,
        timeoutSec: Int,
        status: RelayVerifyStatus,
        exitCode: Int32? = nil,
        signal: Int32? = nil,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        logPath: String? = nil,
        logBytes: Int = 0,
        logTruncated: Bool = false,
        modifiedTrackedFiles: [String] = []
    ) {
        self.command = command
        self.timeoutSec = timeoutSec
        self.status = status
        self.exitCode = exitCode
        self.signal = signal
        self.pid = pid
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.logPath = logPath
        self.logBytes = logBytes
        self.logTruncated = logTruncated
        self.modifiedTrackedFiles = modifiedTrackedFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try c.decode(String.self, forKey: .command)
        self.timeoutSec = try c.decode(Int.self, forKey: .timeoutSec)
        self.status = try c.decode(RelayVerifyStatus.self, forKey: .status)
        self.exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        self.signal = try c.decodeIfPresent(Int32.self, forKey: .signal)
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.logPath = try c.decodeIfPresent(String.self, forKey: .logPath)
        self.logBytes = try c.decodeIfPresent(Int.self, forKey: .logBytes) ?? 0
        self.logTruncated = try c.decodeIfPresent(Bool.self, forKey: .logTruncated) ?? false
        self.modifiedTrackedFiles = try c.decodeIfPresent([String].self, forKey: .modifiedTrackedFiles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        try c.encode(timeoutSec, forKey: .timeoutSec)
        try c.encode(status, forKey: .status)
        try encodeNullable(exitCode, into: &c, forKey: .exitCode)
        try encodeNullable(signal, into: &c, forKey: .signal)
        try encodeNullable(pid, into: &c, forKey: .pid)
        try encodeNullable(startedAt, into: &c, forKey: .startedAt)
        try encodeNullable(finishedAt, into: &c, forKey: .finishedAt)
        try encodeNullable(logPath, into: &c, forKey: .logPath)
        try c.encode(logBytes, forKey: .logBytes)
        try c.encode(logTruncated, forKey: .logTruncated)
        try c.encode(modifiedTrackedFiles, forKey: .modifiedTrackedFiles)
    }
}

public struct RelayRunIntegrationRecord: Sendable, Codable, Hashable, Equatable {
    public var branch: String?
    public var worktreePath: String?
    public var baseCommitOID: String
    public var headCommitOID: String?
    public var status: RelayIntegrationStatus
    public var reason: String?
    public var ready: Bool
    public var merges: [RelayRunMergeRecord]
    public var verify: RelayRunVerifyRecord?

    private enum CodingKeys: String, CodingKey {
        case branch
        case worktreePath
        case baseCommitOID
        case headCommitOID
        case status
        case reason
        case ready
        case merges
        case verify
    }

    public init(
        branch: String? = nil,
        worktreePath: String? = nil,
        baseCommitOID: String,
        headCommitOID: String? = nil,
        status: RelayIntegrationStatus = .pending,
        reason: String? = nil,
        ready: Bool = false,
        merges: [RelayRunMergeRecord] = [],
        verify: RelayRunVerifyRecord? = nil
    ) {
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseCommitOID = baseCommitOID
        self.headCommitOID = headCommitOID
        self.status = status
        self.reason = reason
        self.ready = ready
        self.merges = merges
        self.verify = verify
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        self.baseCommitOID = try c.decode(String.self, forKey: .baseCommitOID)
        self.headCommitOID = try c.decodeIfPresent(String.self, forKey: .headCommitOID)
        self.status = try c.decode(RelayIntegrationStatus.self, forKey: .status)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.ready = try c.decode(Bool.self, forKey: .ready)
        self.merges = try c.decodeIfPresent([RelayRunMergeRecord].self, forKey: .merges) ?? []
        self.verify = try c.decodeIfPresent(RelayRunVerifyRecord.self, forKey: .verify)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeNullable(branch, into: &c, forKey: .branch)
        try encodeNullable(worktreePath, into: &c, forKey: .worktreePath)
        try c.encode(baseCommitOID, forKey: .baseCommitOID)
        try encodeNullable(headCommitOID, into: &c, forKey: .headCommitOID)
        try c.encode(status, forKey: .status)
        try encodeNullable(reason, into: &c, forKey: .reason)
        try c.encode(ready, forKey: .ready)
        try c.encode(merges, forKey: .merges)
        try encodeNullable(verify, into: &c, forKey: .verify)
    }
}

public struct RelayRunRecord: Sendable, Hashable, Equatable, Identifiable, Codable {
    public var id: String { runID }
    public let runID: String
    public let repoPath: String
    public let planCopyPath: String
    public let baseRef: String
    public let baseCommitOID: String
    public let verifyCommand: String?
    public let relayShPath: String
    public let relayShSHA256: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: RelayRunStatus
    public var reason: String?
    public let relayidePID: Int32
    public var lanes: [RelayRunLaneRecord]
    public var integration: RelayRunIntegrationRecord?

    private enum CodingKeys: String, CodingKey {
        case runID
        case repoPath
        case planCopyPath
        case baseRef
        case baseCommitOID
        case verifyCommand
        case relayShPath
        case relayShSHA256
        case startedAt
        case finishedAt
        case status
        case reason
        case relayidePID
        case lanes
    }

    public init(
        runID: String,
        repoPath: String,
        planCopyPath: String,
        baseRef: String,
        baseCommitOID: String,
        verifyCommand: String? = nil,
        relayShPath: String,
        relayShSHA256: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: RelayRunStatus,
        reason: String? = nil,
        relayidePID: Int32,
        lanes: [RelayRunLaneRecord] = [],
        integration: RelayRunIntegrationRecord? = nil
    ) {
        self.runID = runID
        self.repoPath = repoPath
        self.planCopyPath = planCopyPath
        self.baseRef = baseRef
        self.baseCommitOID = baseCommitOID
        self.verifyCommand = verifyCommand
        self.relayShPath = relayShPath
        self.relayShSHA256 = relayShSHA256
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.reason = reason
        self.relayidePID = relayidePID
        self.lanes = lanes
        self.integration = integration
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runID, forKey: .runID)
        try c.encode(repoPath, forKey: .repoPath)
        try c.encode(planCopyPath, forKey: .planCopyPath)
        try c.encode(baseRef, forKey: .baseRef)
        try c.encode(baseCommitOID, forKey: .baseCommitOID)
        try encodeNullable(verifyCommand, into: &c, forKey: .verifyCommand)
        try c.encode(relayShPath, forKey: .relayShPath)
        try c.encode(relayShSHA256, forKey: .relayShSHA256)
        try c.encode(startedAt, forKey: .startedAt)
        try encodeNullable(finishedAt, into: &c, forKey: .finishedAt)
        try c.encode(status, forKey: .status)
        try encodeNullable(reason, into: &c, forKey: .reason)
        try c.encode(relayidePID, forKey: .relayidePID)
        try c.encode(lanes, forKey: .lanes)
    }
}

public enum RelayRunJSONCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }
}

private func encodeNullable<T: Encodable, K: CodingKey>(
    _ value: T?,
    into container: inout KeyedEncodingContainer<K>,
    forKey key: K
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}
