import Foundation

// MARK: - Multi-Agent DAG Orchestrator & Wiretap Token/Budget Proxy Models

public enum RelayTaskStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case pending = "Pending"
    case blockedOnDeps = "Waiting on Deps"
    case running = "Running"
    case verifyingGate = "Verifying Gate"
    case completed = "Completed"
    case failed = "Failed"
    case haltedByBudget = "Budget Halted"
    case cancelled = "Cancelled"
}

public struct RelayTaskNode: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var vendor: AgentVendor
    public var laneID: String
    public var dependsOnTaskIDs: [String]
    public var promptBrief: String
    public var inputHandoffFiles: [String]
    public var outputHandoffFiles: [String]
    public var allowedWriteGlobs: [String]
    public var verificationShellCommand: String?
    public var maxBudgetUSD: Double
    public var status: RelayTaskStatus
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var handoffSummary: String?

    public init(
        id: String,
        title: String,
        vendor: AgentVendor,
        laneID: String,
        dependsOnTaskIDs: [String] = [],
        promptBrief: String,
        inputHandoffFiles: [String] = [],
        outputHandoffFiles: [String] = [],
        allowedWriteGlobs: [String] = ["**"],
        verificationShellCommand: String? = nil,
        maxBudgetUSD: Double = 5.0,
        status: RelayTaskStatus = .pending,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        handoffSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.vendor = vendor
        self.laneID = laneID
        self.dependsOnTaskIDs = dependsOnTaskIDs
        self.promptBrief = promptBrief
        self.inputHandoffFiles = inputHandoffFiles
        self.outputHandoffFiles = outputHandoffFiles
        self.allowedWriteGlobs = allowedWriteGlobs
        self.verificationShellCommand = verificationShellCommand
        self.maxBudgetUSD = maxBudgetUSD
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.handoffSummary = handoffSummary
    }
}

public struct RelayDAGSpec: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var repositoryPath: String
    public var baseBranch: String
    public var tasks: [RelayTaskNode]
    public var globalBudgetCeilingUSD: Double
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        repositoryPath: String,
        baseBranch: String = "main",
        tasks: [RelayTaskNode],
        globalBudgetCeilingUSD: Double = 25.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.baseBranch = baseBranch
        self.tasks = tasks
        self.globalBudgetCeilingUSD = globalBudgetCeilingUSD
        self.createdAt = createdAt
    }
}

public struct WiretapAPISpan: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let laneID: String
    public let taskID: String?
    public let vendor: AgentVendor
    public let providerHost: String
    public let modelIdentifier: String
    public let inputTokens: Int
    public let cachedReadTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let costUSD: Double
    public let durationMs: Double
    public let statusCode: Int
    public let blockedByCircuitBreaker: Bool
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        laneID: String,
        taskID: String? = nil,
        vendor: AgentVendor,
        providerHost: String,
        modelIdentifier: String,
        inputTokens: Int,
        cachedReadTokens: Int = 0,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        costUSD: Double,
        durationMs: Double,
        statusCode: Int = 200,
        blockedByCircuitBreaker: Bool = false,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.laneID = laneID
        self.taskID = taskID
        self.vendor = vendor
        self.providerHost = providerHost
        self.modelIdentifier = modelIdentifier
        self.inputTokens = inputTokens
        self.cachedReadTokens = cachedReadTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
        self.durationMs = durationMs
        self.statusCode = statusCode
        self.blockedByCircuitBreaker = blockedByCircuitBreaker
        self.recordedAt = recordedAt
    }
}

public struct LaneBudgetAccount: Sendable, Codable, Hashable, Identifiable {
    public var id: String { laneID }
    public let laneID: String
    public let vendor: AgentVendor
    public var requestCount: Int
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
    public var spentUSD: Double
    public var ceilingUSD: Double
    public var circuitOpen: Bool

    public init(
        laneID: String,
        vendor: AgentVendor,
        requestCount: Int = 0,
        inputTokens: Int = 0,
        cachedTokens: Int = 0,
        outputTokens: Int = 0,
        spentUSD: Double = 0.0,
        ceilingUSD: Double = 10.0,
        circuitOpen: Bool = false
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.spentUSD = spentUSD
        self.ceilingUSD = ceilingUSD
        self.circuitOpen = circuitOpen
    }

    public var utilizationRatio: Double {
        guard ceilingUSD > 0 else { return 0.0 }
        return min(1.5, spentUSD / ceilingUSD)
    }
}
