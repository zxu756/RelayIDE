import Foundation

// MARK: - Multi-Language Declaration AST & 3-Way Semantic Merge Models

public enum SourceLanguage: String, Sendable, Codable, Hashable, CaseIterable {
    case swift = "Swift"
    case python = "Python"
    case typeScript = "TypeScript"
    case rust = "Rust"
    case go = "Go"
    case json = "JSON"
    case markdown = "Markdown"
    case plainText = "Plain Text"

    public static func detect(fromPath path: String) -> SourceLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "py", "pyi": return .python
        case "ts", "tsx", "js", "jsx", "mjs": return .typeScript
        case "rs": return .rust
        case "go": return .go
        case "json": return .json
        case "md", "markdown": return .markdown
        default: return .plainText
        }
    }
}

public enum ASTDeclarationKind: String, Sendable, Codable, Hashable, CaseIterable {
    case importGroup = "Import Block"
    case packageOrModule = "Module Header"
    case structDecl = "Struct"
    case classDecl = "Class"
    case enumDecl = "Enum"
    case protocolOrInterface = "Protocol / Interface"
    case extensionOrImpl = "Extension / Impl"
    case functionDecl = "Function"
    case methodDecl = "Method"
    case constantOrVar = "Binding / Property"
    case typeAlias = "Type Alias"
    case topLevelBlock = "Top-Level Statement"
}

public struct ASTDeclarationNode: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let kind: ASTDeclarationKind
    public let symbolName: String
    public let qualifiedKey: String
    public let parameterSignature: String
    public let startLine: Int
    public let endLine: Int
    public let leadingTrivia: String
    public let declarationSource: String
    public let referencedSymbols: [String]
    public let importedModules: [String]
    public let children: [ASTDeclarationNode]
    public let structuralFingerprint: UInt64

    public init(
        kind: ASTDeclarationKind,
        symbolName: String,
        qualifiedKey: String? = nil,
        parameterSignature: String = "",
        startLine: Int,
        endLine: Int,
        leadingTrivia: String = "",
        declarationSource: String,
        referencedSymbols: [String] = [],
        importedModules: [String] = [],
        children: [ASTDeclarationNode] = [],
        structuralFingerprint: UInt64
    ) {
        let qk = qualifiedKey ?? "\(kind.rawValue):\(symbolName)"
        self.id = "\(qk)@\(startLine)"
        self.kind = kind
        self.symbolName = symbolName
        self.qualifiedKey = qk
        self.parameterSignature = parameterSignature
        self.startLine = startLine
        self.endLine = endLine
        self.leadingTrivia = leadingTrivia
        self.declarationSource = declarationSource
        self.referencedSymbols = referencedSymbols
        self.importedModules = importedModules
        self.children = children
        self.structuralFingerprint = structuralFingerprint
    }

    public var fullTextWithTrivia: String {
        leadingTrivia + declarationSource
    }
}

public enum SemanticMergeResolution: String, Sendable, Codable, Hashable, CaseIterable {
    case unchanged = "Unchanged"
    case leftModifiedOnly = "Took Left Lane"
    case rightModifiedOnly = "Took Right Lane"
    case leftAddedDeclaration = "Added by Left Lane"
    case rightAddedDeclaration = "Added by Right Lane"
    case leftDeletedDeclaration = "Deleted by Left Lane"
    case rightDeletedDeclaration = "Deleted by Right Lane"
    case autoMergedImportSetUnion = "Auto-Merged Import Union"
    case autoMergedIdenticalChange = "Auto-Merged Identical Edits"
    case autoMergedNestedMembers = "Auto-Merged Disjoint Type Members"
    case conflictBothModifiedSameSymbol = "Conflict: Same Declaration Diverged"
    case conflictDeleteModify = "Conflict: Deleted vs Modified"

    public var isConflict: Bool {
        switch self {
        case .conflictBothModifiedSameSymbol, .conflictDeleteModify:
            return true
        default:
            return false
        }
    }
}

public struct SemanticMergeChunk: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let qualifiedKey: String
    public let symbolName: String
    public let kind: ASTDeclarationKind
    public var resolution: SemanticMergeResolution
    public let baseSource: String?
    public let leftSource: String?
    public let rightSource: String?
    public var resolvedSource: String
    public let leftVendor: AgentVendor?
    public let rightVendor: AgentVendor?
    public let explanation: String

    public init(
        id: UUID = UUID(),
        qualifiedKey: String,
        symbolName: String,
        kind: ASTDeclarationKind,
        resolution: SemanticMergeResolution,
        baseSource: String?,
        leftSource: String?,
        rightSource: String?,
        resolvedSource: String,
        leftVendor: AgentVendor? = nil,
        rightVendor: AgentVendor? = nil,
        explanation: String
    ) {
        self.id = id
        self.qualifiedKey = qualifiedKey
        self.symbolName = symbolName
        self.kind = kind
        self.resolution = resolution
        self.baseSource = baseSource
        self.leftSource = leftSource
        self.rightSource = rightSource
        self.resolvedSource = resolvedSource
        self.leftVendor = leftVendor
        self.rightVendor = rightVendor
        self.explanation = explanation
    }
}

public struct CrossFileSignatureCollision: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let symbolName: String
    public let declarationFile: String
    public let oldSignature: String
    public let newSignature: String
    public let modifiedByLane: String
    public let callerFile: String
    public let callerLine: Int
    public let callerLane: String
    public let diagnosticMessage: String

    public init(
        id: UUID = UUID(),
        symbolName: String,
        declarationFile: String,
        oldSignature: String,
        newSignature: String,
        modifiedByLane: String,
        callerFile: String,
        callerLine: Int,
        callerLane: String,
        diagnosticMessage: String
    ) {
        self.id = id
        self.symbolName = symbolName
        self.declarationFile = declarationFile
        self.oldSignature = oldSignature
        self.newSignature = newSignature
        self.modifiedByLane = modifiedByLane
        self.callerFile = callerFile
        self.callerLine = callerLine
        self.callerLane = callerLane
        self.diagnosticMessage = diagnosticMessage
    }
}

public struct ThreeWaySemanticMergeReport: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let language: SourceLanguage
    public let leftLaneID: String
    public let rightLaneID: String
    public var chunks: [SemanticMergeChunk]
    public var mergedText: String
    public let autoMergedCount: Int
    public let unresolvedConflictCount: Int
    public let wouldGitLineMergeConflict: Bool
    public let crossFileCollisions: [CrossFileSignatureCollision]

    public init(
        relativePath: String,
        language: SourceLanguage,
        leftLaneID: String,
        rightLaneID: String,
        chunks: [SemanticMergeChunk],
        mergedText: String,
        autoMergedCount: Int,
        unresolvedConflictCount: Int,
        wouldGitLineMergeConflict: Bool = false,
        crossFileCollisions: [CrossFileSignatureCollision] = []
    ) {
        self.relativePath = relativePath
        self.language = language
        self.leftLaneID = leftLaneID
        self.rightLaneID = rightLaneID
        self.chunks = chunks
        self.mergedText = mergedText
        self.autoMergedCount = autoMergedCount
        self.unresolvedConflictCount = unresolvedConflictCount
        self.wouldGitLineMergeConflict = wouldGitLineMergeConflict
        self.crossFileCollisions = crossFileCollisions
    }

    public var isCleanlyMerged: Bool {
        unresolvedConflictCount == 0 && crossFileCollisions.isEmpty
    }
}
