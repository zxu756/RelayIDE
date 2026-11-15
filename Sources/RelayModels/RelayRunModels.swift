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
        lanes: [RelayRunLaneRecord] = []
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
