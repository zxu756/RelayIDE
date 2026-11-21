import Foundation

// MARK: - JavaScriptCore Guardrail Plugins, Isometric Territory Map & Workbench State

public enum RelayPluginCapability: String, Sendable, Codable, Hashable, CaseIterable {
    case inspectDiffs = "diffs.inspect"
    case inspectASTNodes = "ast.inspect"
    case inspectTokenTelemetry = "wiretap.inspect"
    case vetoMergeGate = "merge.veto"
    case synthesizeCommitMessage = "commit.synthesize"
}

public enum GuardrailSeverity: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case pass = "PASS"
    case advisory = "ADVISORY"
    case warning = "WARNING"
    case blocker = "BLOCKER"

    private var rank: Int {
        switch self {
        case .pass: return 0
        case .advisory: return 1
        case .warning: return 2
        case .blocker: return 3
        }
    }

    public static func < (lhs: GuardrailSeverity, rhs: GuardrailSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct RelayGuardrailFinding: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let pluginID: String
    public let pluginName: String
    public let severity: GuardrailSeverity
    public let laneID: String?
    public let relativePath: String?
    public let title: String
    public let detail: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        pluginID: String,
        pluginName: String,
        severity: GuardrailSeverity,
        laneID: String? = nil,
        relativePath: String? = nil,
        title: String,
        detail: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.severity = severity
        self.laneID = laneID
        self.relativePath = relativePath
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct RelayPluginManifest: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let capabilities: [RelayPluginCapability]
    public let isBuiltIn: Bool
    public var isEnabled: Bool
    public let scriptSource: String

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        summary: String,
        capabilities: [RelayPluginCapability],
        isBuiltIn: Bool = true,
        isEnabled: Bool = true,
        scriptSource: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.capabilities = capabilities
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.scriptSource = scriptSource
    }
}

// MARK: - 2.5D Isometric Coupling & Live Agent Territory Map

public struct IsometricModuleTower: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let moduleName: String
    public let language: SourceLanguage
    public let lineCount: Int
    public let declarationCount: Int
    public let fanIn: Int
    public let fanOut: Int
    public let instabilityMetric: Double
    public let couplingHeat: Double
    public let activeOwnerVendor: AgentVendor?
    public let activeLaneID: String?
    public let hasMergeConflict: Bool
    public let gridColumn: Int
    public let gridRow: Int

    public init(
        relativePath: String,
        moduleName: String,
        language: SourceLanguage,
        lineCount: Int,
        declarationCount: Int,
        fanIn: Int,
        fanOut: Int,
        activeOwnerVendor: AgentVendor? = nil,
        activeLaneID: String? = nil,
        hasMergeConflict: Bool = false,
        gridColumn: Int,
        gridRow: Int
    ) {
        self.relativePath = relativePath
        self.moduleName = moduleName
        self.language = language
        self.lineCount = lineCount
        self.declarationCount = declarationCount
        self.fanIn = fanIn
        self.fanOut = fanOut
        let totalDeg = fanIn + fanOut
        self.instabilityMetric = totalDeg == 0 ? 0.0 : Double(fanOut) / Double(totalDeg)
        self.couplingHeat = min(1.0, Double(fanIn * 2 + fanOut) / 24.0)
        self.activeOwnerVendor = activeOwnerVendor
        self.activeLaneID = activeLaneID
        self.hasMergeConflict = hasMergeConflict
        self.gridColumn = gridColumn
        self.gridRow = gridRow
    }
}

public struct IsometricCouplingArc: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(sourcePath)->\(targetPath)" }
    public let sourcePath: String
    public let targetPath: String
    public let sharedSymbolCount: Int
    public let crossesAgentLanes: Bool

    public init(sourcePath: String, targetPath: String, sharedSymbolCount: Int, crossesAgentLanes: Bool) {
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.sharedSymbolCount = sharedSymbolCount
        self.crossesAgentLanes = crossesAgentLanes
    }
}

// MARK: - Undo/Redo & Workbench Views

public enum RelayUndoMutation: Sendable, Codable, Hashable {
    case updateLaneOwnership(laneID: String, previous: FileOwnershipRule, updated: FileOwnershipRule)
    case updateLaneBudget(laneID: String, previousCeilingUSD: Double, updatedCeilingUSD: Double)
    case resolveMergeChunk(filePath: String, chunkID: UUID, previousSource: String, updatedSource: String)
    case togglePlugin(pluginID: String, previousEnabled: Bool, updatedEnabled: Bool)

    public var inverted: RelayUndoMutation {
        switch self {
        case .updateLaneOwnership(let id, let prev, let next):
            return .updateLaneOwnership(laneID: id, previous: next, updated: prev)
        case .updateLaneBudget(let id, let prev, let next):
            return .updateLaneBudget(laneID: id, previousCeilingUSD: next, updatedCeilingUSD: prev)
        case .resolveMergeChunk(let path, let cid, let prev, let next):
            return .resolveMergeChunk(filePath: path, chunkID: cid, previousSource: next, updatedSource: prev)
        case .togglePlugin(let pid, let prev, let next):
            return .togglePlugin(pluginID: pid, previousEnabled: next, updatedEnabled: prev)
        }
    }
}

public enum RelayStudioPane: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case ptyGrid = "PTY Multiplexer"
    case dagPipeline = "Relay DAG"
    case semanticMerge = "3-Way AST Merge"
    case territoryMap = "Isometric Territory"
    case guardrailPlugins = "Guardrail Plugins"

    public var id: String { rawValue }

    public var sfSymbolName: String {
        switch self {
        case .ptyGrid: return "rectangle.split.2x2"
        case .dagPipeline: return "point.bottomleft.forward.to.arrow.triangle.scurvepath"
        case .semanticMerge: return "arrow.triangle.merge"
        case .territoryMap: return "cube.transparent"
        case .guardrailPlugins: return "checkmark.shield"
        }
    }
}

public struct RelayWorkspaceStats: Sendable, Codable, Hashable {
    public let workspaceName: String
    public let repositoryPath: String
    public let schemaVersion: Int
    public let sqliteBytes: Int64
    public let walBytes: Int64
    public let activeLaneCount: Int
    public let taskNodeCount: Int
    public let semanticAutoMergeCount: Int
    public let unresolvedConflictCount: Int
    public let totalTokensObserved: Int
    public let totalSpendUSD: Double
    public let guardrailFindingCount: Int
    public let undoDepth: Int
    public let redoDepth: Int

    public init(
        workspaceName: String,
        repositoryPath: String,
        schemaVersion: Int,
        sqliteBytes: Int64,
        walBytes: Int64,
        activeLaneCount: Int,
        taskNodeCount: Int,
        semanticAutoMergeCount: Int,
        unresolvedConflictCount: Int,
        totalTokensObserved: Int,
        totalSpendUSD: Double,
        guardrailFindingCount: Int,
        undoDepth: Int,
        redoDepth: Int
    ) {
        self.workspaceName = workspaceName
        self.repositoryPath = repositoryPath
        self.schemaVersion = schemaVersion
        self.sqliteBytes = sqliteBytes
        self.walBytes = walBytes
        self.activeLaneCount = activeLaneCount
        self.taskNodeCount = taskNodeCount
        self.semanticAutoMergeCount = semanticAutoMergeCount
        self.unresolvedConflictCount = unresolvedConflictCount
        self.totalTokensObserved = totalTokensObserved
        self.totalSpendUSD = totalSpendUSD
        self.guardrailFindingCount = guardrailFindingCount
        self.undoDepth = undoDepth
        self.redoDepth = redoDepth
    }
}
