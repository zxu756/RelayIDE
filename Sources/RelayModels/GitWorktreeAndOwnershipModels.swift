import Foundation

// MARK: - Git Commit DAG, Worktree Matrix & File-Scope Ownership Guardrails

public struct GitCommitNode: Sendable, Codable, Hashable, Identifiable {
    public var id: String { oid }
    public let oid: String
    public let shortOID: String
    public let parentOIDs: [String]
    public let authorName: String
    public let authorEmail: String
    public let authoredAt: Date
    public let subject: String
    public let decorations: [String]

    public init(
        oid: String,
        parentOIDs: [String] = [],
        authorName: String,
        authorEmail: String,
        authoredAt: Date = Date(),
        subject: String,
        decorations: [String] = []
    ) {
        self.oid = oid
        self.shortOID = String(oid.prefix(8))
        self.parentOIDs = parentOIDs
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.subject = subject
        self.decorations = decorations
    }
}

public enum WorktreeFileStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case conflicted = "U"
}

public struct WorktreeFileDelta: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let previousPath: String?
    public let status: WorktreeFileStatus
    public let additions: Int
    public let deletions: Int
    public let observedAt: Date

    public init(
        relativePath: String,
        previousPath: String? = nil,
        status: WorktreeFileStatus,
        additions: Int = 0,
        deletions: Int = 0,
        observedAt: Date = Date()
    ) {
        self.relativePath = relativePath
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.observedAt = observedAt
    }
}

public struct FileOwnershipRule: Sendable, Codable, Hashable {
    public var allowedGlobs: [String]
    public var forbiddenGlobs: [String]
    public var autoRevertViolations: Bool
    public var isReadOnlyVerifier: Bool

    public init(
        allowedGlobs: [String] = ["**"],
        forbiddenGlobs: [String] = [".git/**", ".relay/**"],
        autoRevertViolations: Bool = false,
        isReadOnlyVerifier: Bool = false
    ) {
        self.allowedGlobs = allowedGlobs
        self.forbiddenGlobs = forbiddenGlobs
        self.autoRevertViolations = autoRevertViolations
        self.isReadOnlyVerifier = isReadOnlyVerifier
    }
}

public struct OwnershipViolationEvent: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let laneID: String
    public let vendor: AgentVendor
    public let relativePath: String
    public let violatedRuleSummary: String
    public let wasAutoReverted: Bool
    public let detectedAt: Date

    public init(
        id: UUID = UUID(),
        laneID: String,
        vendor: AgentVendor,
        relativePath: String,
        violatedRuleSummary: String,
        wasAutoReverted: Bool,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.laneID = laneID
        self.vendor = vendor
        self.relativePath = relativePath
        self.violatedRuleSummary = violatedRuleSummary
        self.wasAutoReverted = wasAutoReverted
        self.detectedAt = detectedAt
    }
}

public struct ManagedWorktreeLane: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public var displayName: String
    public var assignedVendor: AgentVendor
    public let worktreePath: String
    public let branchName: String
    public var baseCommitOID: String
    public var headCommitOID: String
    public var dirtyFiles: [WorktreeFileDelta]
    public var ownershipRule: FileOwnershipRule
    public let createdAt: Date

    public init(
        id: String,
        displayName: String,
        assignedVendor: AgentVendor,
        worktreePath: String,
        branchName: String,
        baseCommitOID: String,
        headCommitOID: String,
        dirtyFiles: [WorktreeFileDelta] = [],
        ownershipRule: FileOwnershipRule = FileOwnershipRule(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.assignedVendor = assignedVendor
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.baseCommitOID = baseCommitOID
        self.headCommitOID = headCommitOID
        self.dirtyFiles = dirtyFiles
        self.ownershipRule = ownershipRule
        self.createdAt = createdAt
    }
}
