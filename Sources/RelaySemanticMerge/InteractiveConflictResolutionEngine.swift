import Foundation
import RelayModels

// MARK: - AST Conflict Resolution Strategies, Options & Verification Evidence

public enum ConflictOrderingPreference: String, Sendable, Codable, Hashable, CaseIterable {
    case leftThenRight = "left_then_right"
    case rightThenLeft = "right_then_left"
}

public enum MemberCollisionTieBreaker: String, Sendable, Codable, Hashable, CaseIterable {
    case preferLeft = "prefer_left"
    case preferRight = "prefer_right"
    case keepBothSuffixed = "keep_both_suffixed"
    case emitInnerConflictMarkers = "emit_inner_conflict_markers"
}

public enum ConflictResolutionStrategy: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case acceptLeft = "acceptLeft"
    case acceptRight = "acceptRight"
    case acceptBothOrdered = "acceptBothOrdered"
    case interleaveMembersByName = "interleaveMembersByName"
    case preferVerifiedTestPassingLane = "preferVerifiedTestPassingLane"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .acceptLeft:
            return "Accept Left Lane"
        case .acceptRight:
            return "Accept Right Lane"
        case .acceptBothOrdered:
            return "Accept Both (Ordered)"
        case .interleaveMembersByName:
            return "Interleave Container Members by Name"
        case .preferVerifiedTestPassingLane:
            return "Prefer Verified Test-Passing Lane"
        }
    }
}

public enum IndentationUnitKind: String, Sendable, Codable, Hashable, CaseIterable {
    case spaces = "spaces"
    case tabs = "tabs"
}

public enum IndentationStylePreference: Sendable, Codable, Hashable {
    case autoDetect
    case spaces(Int)
    case tabs
}

public struct ConflictResolutionOptions: Sendable, Codable, Hashable {
    public let orderingPreference: ConflictOrderingPreference
    public let memberTieBreaker: MemberCollisionTieBreaker
    public let deduplicateIdenticalStatements: Bool
    public let mergeCompatibleTypeConformances: Bool
    public let fallbackStrategyWhenVerificationTied: ConflictResolutionStrategy?
    public let indentationPreference: IndentationStylePreference

    public init(
        orderingPreference: ConflictOrderingPreference = .leftThenRight,
        memberTieBreaker: MemberCollisionTieBreaker = .preferLeft,
        deduplicateIdenticalStatements: Bool = true,
        mergeCompatibleTypeConformances: Bool = true,
        fallbackStrategyWhenVerificationTied: ConflictResolutionStrategy? = nil,
        indentationPreference: IndentationStylePreference = .autoDetect
    ) {
        self.orderingPreference = orderingPreference
        self.memberTieBreaker = memberTieBreaker
        self.deduplicateIdenticalStatements = deduplicateIdenticalStatements
        self.mergeCompatibleTypeConformances = mergeCompatibleTypeConformances
        self.fallbackStrategyWhenVerificationTied = fallbackStrategyWhenVerificationTied
        self.indentationPreference = indentationPreference
    }
}

public struct LaneVerificationEvidence: Sendable, Codable, Hashable, Identifiable {
    public var id: String { laneID }
    public let laneID: String
    public let vendor: AgentVendor?
    public let testCommand: String
    public let exitCode: Int32
    public let passedTestCount: Int
    public let failedTestCount: Int
    public let skippedTestCount: Int
    public let compilerErrorCount: Int
    public let compilerWarningCount: Int
    public let ownershipViolationCount: Int
    public let guardrailBlockerCount: Int
    public let executionDurationMs: Double

    public init(
        laneID: String,
        vendor: AgentVendor? = nil,
        testCommand: String = "swift test",
        exitCode: Int32,
        passedTestCount: Int,
        failedTestCount: Int = 0,
        skippedTestCount: Int = 0,
        compilerErrorCount: Int = 0,
        compilerWarningCount: Int = 0,
        ownershipViolationCount: Int = 0,
        guardrailBlockerCount: Int = 0,
        executionDurationMs: Double = 0.0
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.testCommand = testCommand
        self.exitCode = exitCode
        self.passedTestCount = max(0, passedTestCount)
        self.failedTestCount = max(0, failedTestCount)
        self.skippedTestCount = max(0, skippedTestCount)
        self.compilerErrorCount = max(0, compilerErrorCount)
        self.compilerWarningCount = max(0, compilerWarningCount)
        self.ownershipViolationCount = max(0, ownershipViolationCount)
        self.guardrailBlockerCount = max(0, guardrailBlockerCount)
        self.executionDurationMs = max(0.0, executionDurationMs)
    }

    public var isVerifiedGreen: Bool {
        exitCode == 0
            && failedTestCount == 0
            && compilerErrorCount == 0
            && ownershipViolationCount == 0
            && guardrailBlockerCount == 0
    }

    /// Deterministic quality score used to break ties when both lanes pass verification suites.
    public var qualityScore: Double {
        guard isVerifiedGreen else {
            let penalty = Double(
                failedTestCount * 50
                + compilerErrorCount * 100
                + ownershipViolationCount * 80
                + guardrailBlockerCount * 90
                + Int(abs(exitCode)) * 25
            )
            return -1000.0 - penalty
        }
        let passBonus = min(500.0, Double(passedTestCount) * 2.5)
        let warningPenalty = Double(compilerWarningCount) * 4.0
        let skipPenalty = Double(skippedTestCount) * 0.5
        return 1000.0 + passBonus - warningPenalty - skipPenalty
    }
}

public enum VerifiedLaneSelectionDecision: String, Sendable, Codable, Hashable {
    case selectedLeftVerifiedGreen
    case selectedRightVerifiedGreen
    case selectedHigherQualityGreenLane
    case appliedConfiguredFallback
    case unresolvedBothFailedOrMissingEvidence
    case unresolvedExactVerificationTie
}

public struct VerifiedLaneSelectionOutcome: Sendable, Codable, Hashable {
    public let decision: VerifiedLaneSelectionDecision
    public let winningLaneID: String?
    public let leftScore: Double?
    public let rightScore: Double?
    public let rationale: String

    public init(
        decision: VerifiedLaneSelectionDecision,
        winningLaneID: String?,
        leftScore: Double?,
        rightScore: Double?,
        rationale: String
    ) {
        self.decision = decision
        self.winningLaneID = winningLaneID
        self.leftScore = leftScore
        self.rightScore = rightScore
        self.rationale = rationale
    }
}

// MARK: - Callable Signature & Cross-File Broken Call-Site Arity Models

public enum CallableVisibility: String, Sendable, Codable, Hashable {
    case publicOrOpen = "public"
    case internalOrPackage = "internal"
    case privateOrFileprivate = "private"
}

public struct CallableParameterDescriptor: Sendable, Codable, Hashable {
    public let positionIndex: Int
    /// External argument label (`nil` when unlabeled / positional `_`, or parameter name in Swift/Python).
    public let externalLabel: String?
    public let internalName: String
    public let typeAnnotation: String
    public let hasDefaultValue: Bool
    public let defaultValueExpression: String?
    public let isVariadic: Bool
    public let isInoutOrMutRef: Bool

    public init(
        positionIndex: Int,
        externalLabel: String?,
        internalName: String,
        typeAnnotation: String,
        hasDefaultValue: Bool = false,
        defaultValueExpression: String? = nil,
        isVariadic: Bool = false,
        isInoutOrMutRef: Bool = false
    ) {
        self.positionIndex = positionIndex
        self.externalLabel = externalLabel
        self.internalName = internalName
        self.typeAnnotation = typeAnnotation
        self.hasDefaultValue = hasDefaultValue
        self.defaultValueExpression = defaultValueExpression
        self.isVariadic = isVariadic
        self.isInoutOrMutRef = isInoutOrMutRef
    }
}

public struct ParsedCallableSignature: Sendable, Codable, Hashable {
    public let symbolName: String
    public let containerTypeName: String?
    public let language: SourceLanguage
    public let rawSignatureText: String
    public let parameters: [CallableParameterDescriptor]
    public let minimumRequiredArity: Int
    /// `nil` indicates unbounded upper arity (variadic parameter list).
    public let maximumAcceptedArity: Int?
    public let isAsync: Bool
    public let canThrow: Bool
    public let returnTypeAnnotation: String?
    public let visibility: CallableVisibility

    public init(
        symbolName: String,
        containerTypeName: String? = nil,
        language: SourceLanguage,
        rawSignatureText: String,
        parameters: [CallableParameterDescriptor],
        minimumRequiredArity: Int,
        maximumAcceptedArity: Int?,
        isAsync: Bool = false,
        canThrow: Bool = false,
        returnTypeAnnotation: String? = nil,
        visibility: CallableVisibility = .internalOrPackage
    ) {
        self.symbolName = symbolName
        self.containerTypeName = containerTypeName
        self.language = language
        self.rawSignatureText = rawSignatureText
        self.parameters = parameters
        self.minimumRequiredArity = minimumRequiredArity
        self.maximumAcceptedArity = maximumAcceptedArity
        self.isAsync = isAsync
        self.canThrow = canThrow
        self.returnTypeAnnotation = returnTypeAnnotation
        self.visibility = visibility
    }

    public var canonicalSummary: String {
        let paramText = parameters.map { param -> String in
            let labelPart: String
            if language == .swift {
                if let ext = param.externalLabel {
                    labelPart = ext == param.internalName ? "\(ext): " : "\(ext) \(param.internalName): "
                } else {
                    labelPart = "_ \(param.internalName): "
                }
            } else {
                labelPart = "\(param.internalName): "
            }
            let typePart = param.typeAnnotation.isEmpty ? "Any" : param.typeAnnotation
            let variadicSuffix = param.isVariadic ? "..." : ""
            let defaultSuffix = param.hasDefaultValue ? " = default" : ""
            return "\(labelPart)\(typePart)\(variadicSuffix)\(defaultSuffix)"
        }.joined(separator: ", ")

        var effects: [String] = []
        if isAsync { effects.append("async") }
        if canThrow { effects.append("throws") }
        let effectPart = effects.isEmpty ? "" : " " + effects.joined(separator: " ")
        let retPart = (returnTypeAnnotation?.isEmpty == false) ? " -> \(returnTypeAnnotation!)" : ""
        return "\(symbolName)(\(paramText))\(effectPart)\(retPart)"
    }
}

public struct ScannedCallSiteArgument: Sendable, Codable, Hashable {
    public let index: Int
    public let label: String?
    public let expressionSnippet: String
    public let isSpreadOrUnpack: Bool

    public init(
        index: Int,
        label: String?,
        expressionSnippet: String,
        isSpreadOrUnpack: Bool = false
    ) {
        self.index = index
        self.label = label
        self.expressionSnippet = expressionSnippet
        self.isSpreadOrUnpack = isSpreadOrUnpack
    }
}

public struct ScannedCallSiteOccurrence: Sendable, Codable, Hashable {
    public let symbolName: String
    public let receiverExpression: String?
    public let filePath: String
    public let lineNumber: Int
    public let columnNumber: Int
    public let rawCallSnippet: String
    public let arguments: [ScannedCallSiteArgument]
    public let hasTrailingClosure: Bool
    public let hasAwaitPrefix: Bool
    public let hasTryPrefix: Bool

    public init(
        symbolName: String,
        receiverExpression: String? = nil,
        filePath: String,
        lineNumber: Int,
        columnNumber: Int,
        rawCallSnippet: String,
        arguments: [ScannedCallSiteArgument],
        hasTrailingClosure: Bool = false,
        hasAwaitPrefix: Bool = false,
        hasTryPrefix: Bool = false
    ) {
        self.symbolName = symbolName
        self.receiverExpression = receiverExpression
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.rawCallSnippet = rawCallSnippet
        self.arguments = arguments
        self.hasTrailingClosure = hasTrailingClosure
        self.hasAwaitPrefix = hasAwaitPrefix
        self.hasTryPrefix = hasTryPrefix
    }

    /// Total effective argument count including a trailing closure when present.
    public var effectiveArgumentCount: Int {
        arguments.count + (hasTrailingClosure ? 1 : 0)
    }
}

public enum CallSiteMismatchKind: String, Sendable, Codable, Hashable, CaseIterable {
    case tooFewArguments = "too_few_arguments"
    case tooManyArguments = "too_many_arguments"
    case argumentLabelMismatch = "argument_label_mismatch"
    case newlyRequiredAsyncAwait = "newly_required_await"
    case newlyRequiredTryEffect = "newly_required_try"
    case callableDeletedWhileReferenced = "callable_deleted_while_referenced"
}

public struct CallSiteArityDiagnostic: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let mismatchKind: CallSiteMismatchKind
    public let symbolName: String
    public let declarationFile: String
    public let modifiedByLane: String
    public let oldSignature: ParsedCallableSignature
    public let newSignature: ParsedCallableSignature?
    public let callSite: ScannedCallSiteOccurrence
    public let callerLane: String
    public let diagnosticMessage: String
    public let suggestedFixCallSnippet: String?

    public init(
        id: UUID = UUID(),
        mismatchKind: CallSiteMismatchKind,
        symbolName: String,
        declarationFile: String,
        modifiedByLane: String,
        oldSignature: ParsedCallableSignature,
        newSignature: ParsedCallableSignature?,
        callSite: ScannedCallSiteOccurrence,
        callerLane: String,
        diagnosticMessage: String,
        suggestedFixCallSnippet: String?
    ) {
        self.id = id
        self.mismatchKind = mismatchKind
        self.symbolName = symbolName
        self.declarationFile = declarationFile
        self.modifiedByLane = modifiedByLane
        self.oldSignature = oldSignature
        self.newSignature = newSignature
        self.callSite = callSite
        self.callerLane = callerLane
        self.diagnosticMessage = diagnosticMessage
        self.suggestedFixCallSnippet = suggestedFixCallSnippet
    }

    public func asCrossFileSignatureCollision() -> CrossFileSignatureCollision {
        CrossFileSignatureCollision(
            id: id,
            symbolName: symbolName,
            declarationFile: declarationFile,
            oldSignature: oldSignature.canonicalSummary,
            newSignature: newSignature?.canonicalSummary ?? "<deleted>",
            modifiedByLane: modifiedByLane,
            callerFile: callSite.filePath,
            callerLine: callSite.lineNumber,
            callerLane: callerLane,
            diagnosticMessage: diagnosticMessage
        )
    }
}

// MARK: - Clean Source-Code Emitter Models

public struct DetectedIndentationProfile: Sendable, Codable, Hashable {
    public let unitKind: IndentationUnitKind
    public let indentWidth: Int
    public let newlineSequence: String
    public let ensuresTrailingNewline: Bool

    public init(
        unitKind: IndentationUnitKind = .spaces,
        indentWidth: Int = 4,
        newlineSequence: String = "\n",
        ensuresTrailingNewline: Bool = true
    ) {
        self.unitKind = unitKind
        self.indentWidth = max(1, indentWidth)
        self.newlineSequence = newlineSequence
        self.ensuresTrailingNewline = ensuresTrailingNewline
    }

    public var indentUnitString: String {
        switch unitKind {
        case .spaces:
            return String(repeating: " ", count: indentWidth)
        case .tabs:
            return "\t"
        }
    }
}

public struct DelimiterBalanceAudit: Sendable, Codable, Hashable {
    public let isBalanced: Bool
    public let unclosedBraceLines: [Int]
    public let unclosedParenLines: [Int]
    public let unclosedBracketLines: [Int]
    public let unexpectedClosingLocations: [String]

    public init(
        isBalanced: Bool,
        unclosedBraceLines: [Int] = [],
        unclosedParenLines: [Int] = [],
        unclosedBracketLines: [Int] = [],
        unexpectedClosingLocations: [String] = []
    ) {
        self.isBalanced = isBalanced
        self.unclosedBraceLines = unclosedBraceLines
        self.unclosedParenLines = unclosedParenLines
        self.unclosedBracketLines = unclosedBracketLines
        self.unexpectedClosingLocations = unexpectedClosingLocations
    }
}

public struct EmittedSourceDocument: Sendable, Codable, Hashable {
    public let formattedSource: String
    public let indentationProfile: DetectedIndentationProfile
    public let delimiterAudit: DelimiterBalanceAudit
    public let normalizedImportCount: Int
    public let emittedDeclarationCount: Int

    public init(
        formattedSource: String,
        indentationProfile: DetectedIndentationProfile,
        delimiterAudit: DelimiterBalanceAudit,
        normalizedImportCount: Int,
        emittedDeclarationCount: Int
    ) {
        self.formattedSource = formattedSource
        self.indentationProfile = indentationProfile
        self.delimiterAudit = delimiterAudit
        self.normalizedImportCount = normalizedImportCount
        self.emittedDeclarationCount = emittedDeclarationCount
    }
}

// MARK: - Interactive Conflict Resolution Outcomes

public struct ChunkResolutionOutcome: Sendable, Codable, Hashable {
    public let updatedChunk: SemanticMergeChunk
    public let appliedStrategy: ConflictResolutionStrategy
    public let undoMutation: RelayUndoMutation
    public let verificationSelection: VerifiedLaneSelectionOutcome?
    public let delimiterAudit: DelimiterBalanceAudit
    public let resolutionNotes: [String]

    public init(
        updatedChunk: SemanticMergeChunk,
        appliedStrategy: ConflictResolutionStrategy,
        undoMutation: RelayUndoMutation,
        verificationSelection: VerifiedLaneSelectionOutcome? = nil,
        delimiterAudit: DelimiterBalanceAudit,
        resolutionNotes: [String] = []
    ) {
        self.updatedChunk = updatedChunk
        self.appliedStrategy = appliedStrategy
        self.undoMutation = undoMutation
        self.verificationSelection = verificationSelection
        self.delimiterAudit = delimiterAudit
        self.resolutionNotes = resolutionNotes
    }
}

public struct BatchConflictResolutionSessionReport: Sendable, Codable, Hashable {
    public let updatedMergeReport: ThreeWaySemanticMergeReport
    public let emittedDocument: EmittedSourceDocument
    public let chunkOutcomes: [ChunkResolutionOutcome]
    public let undoMutations: [RelayUndoMutation]
    public let callSiteDiagnostics: [CallSiteArityDiagnostic]
    public let resolvedChunkCount: Int
    public let remainingConflictCount: Int

    public init(
        updatedMergeReport: ThreeWaySemanticMergeReport,
        emittedDocument: EmittedSourceDocument,
        chunkOutcomes: [ChunkResolutionOutcome],
        undoMutations: [RelayUndoMutation],
        callSiteDiagnostics: [CallSiteArityDiagnostic],
        resolvedChunkCount: Int,
        remainingConflictCount: Int
    ) {
        self.updatedMergeReport = updatedMergeReport
        self.emittedDocument = emittedDocument
        self.chunkOutcomes = chunkOutcomes
        self.undoMutations = undoMutations
        self.callSiteDiagnostics = callSiteDiagnostics
        self.resolvedChunkCount = resolvedChunkCount
        self.remainingConflictCount = remainingConflictCount
    }
}

// MARK: - Cross-File Broken Call-Site Arity & Label Detector

public struct CrossFileBrokenCallSiteDetector: Sendable {
    private let parser = MultiLanguageDeclarationParser()

    public init() {}

    /// Detects cross-file broken call sites when one agent worktree alters a callable's parameter arity,
    /// external parameter labels, or async/throws effects while another worktree invokes the stale signature.
    public func detectBrokenCallSites(
        baseFiles: [String: String],
        leftLaneID: String,
        leftFiles: [String: String],
        rightLaneID: String,
        rightFiles: [String: String],
        includeInternalVisibility: Bool = true
    ) -> [CallSiteArityDiagnostic] {
        let leftMutations = collectCallableSignatureMutations(
            baseFiles: baseFiles,
            updatedFiles: leftFiles,
            modifiedByLane: leftLaneID,
            includeInternalVisibility: includeInternalVisibility
        )
        let rightMutations = collectCallableSignatureMutations(
            baseFiles: baseFiles,
            updatedFiles: rightFiles,
            modifiedByLane: rightLaneID,
            includeInternalVisibility: includeInternalVisibility
        )

        var diagnostics: [CallSiteArityDiagnostic] = []
        diagnostics.append(contentsOf: auditCallerWorkspace(
            mutations: leftMutations,
            callerLaneID: rightLaneID,
            callerFiles: rightFiles,
            baseFiles: baseFiles
        ))
        diagnostics.append(contentsOf: auditCallerWorkspace(
            mutations: rightMutations,
            callerLaneID: leftLaneID,
            callerFiles: leftFiles,
            baseFiles: baseFiles
        ))

        return diagnostics.sorted { lhs, rhs in
            if lhs.callSite.filePath != rhs.callSite.filePath {
                return lhs.callSite.filePath < rhs.callSite.filePath
            }
            if lhs.callSite.lineNumber != rhs.callSite.lineNumber {
                return lhs.callSite.lineNumber < rhs.callSite.lineNumber
            }
            return lhs.symbolName < rhs.symbolName
        }
    }

    /// Parses a rich multi-language `ParsedCallableSignature` from a function/method/initializer declaration header.
    public func parseCallableSignature(
        declarationSource: String,
        symbolName: String,
        containerTypeName: String? = nil,
        language: SourceLanguage
    ) -> ParsedCallableSignature? {
        let headerSnippet = extractCallableHeaderPrefix(from: declarationSource, language: language)
        guard let openParen = findParameterListOpenParen(in: headerSnippet, symbolName: symbolName, language: language),
              let closeParen = findMatchingCloseParen(in: headerSnippet, openParenIndex: openParen) else {
            return nil
        }

        let insideParens = String(headerSnippet[headerSnippet.index(after: openParen)..<closeParen])
        let afterCloseIdx = headerSnippet.index(after: closeParen)
        let trailingHeader = afterCloseIdx < headerSnippet.endIndex ? String(headerSnippet[afterCloseIdx...]) : ""
        let leadingHeader = String(headerSnippet[..<openParen])

        let visibility = detectVisibility(in: leadingHeader, symbolName: symbolName, language: language)
        let rawParamSegments = splitTopLevelCommaSeparated(insideParens)

        var descriptors: [CallableParameterDescriptor] = []
        var position = 0
        for rawSeg in rawParamSegments {
            let trimmedSeg = rawSeg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSeg.isEmpty else { continue }
            if isImplicitReceiverParameter(trimmedSeg, position: position, language: language) {
                continue
            }
            if let desc = parseSingleParameter(trimmedSeg, positionIndex: descriptors.count, language: language) {
                descriptors.append(desc)
            }
            position += 1
        }

        let minArity = descriptors.filter { !$0.hasDefaultValue && !$0.isVariadic }.count
        let hasVariadic = descriptors.contains(where: \.isVariadic)
        let maxArity: Int? = hasVariadic ? nil : descriptors.count

        let effects = detectAsyncAndThrowEffects(
            leadingHeader: leadingHeader,
            trailingHeader: trailingHeader,
            language: language
        )
        let returnType = extractReturnTypeAnnotation(from: trailingHeader, language: language)

        return ParsedCallableSignature(
            symbolName: symbolName,
            containerTypeName: containerTypeName,
            language: language,
            rawSignatureText: headerSnippet.trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: descriptors,
            minimumRequiredArity: minArity,
            maximumAcceptedArity: maxArity,
            isAsync: effects.isAsync,
            canThrow: effects.canThrow,
            returnTypeAnnotation: returnType,
            visibility: visibility
        )
    }

    /// Scans `source` for call-site invocations of any target symbol in `targetSymbols`, ignoring comments,
    /// string literals, and declaration headers.
    public func scanCallSites(
        in source: String,
        filePath: String,
        language: SourceLanguage,
        targetSymbols: Set<String>
    ) -> [ScannedCallSiteOccurrence] {
        guard !targetSymbols.isEmpty, !source.isEmpty else { return [] }
        let chars = Array(source)
        let count = chars.count

        // Precompute line start offsets for O(log L) line/column lookup
        var lineStartOffsets: [Int] = [0]
        for idx in 0..<count where chars[idx] == "\n" {
            lineStartOffsets.append(idx + 1)
        }

        var occurrences: [ScannedCallSiteOccurrence] = []
        var i = 0

        while i < count {
            let ch = chars[i]

            // Skip line comments (`//` or Python `#`)
            if ch == "/" && i + 1 < count && chars[i + 1] == "/" {
                i += 2
                while i < count && chars[i] != "\n" { i += 1 }
                continue
            }
            if language == .python && ch == "#" {
                i += 1
                while i < count && chars[i] != "\n" { i += 1 }
                continue
            }

            // Skip C-style block comments `/* ... */`
            if ch == "/" && i + 1 < count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") {
                    i += 1
                }
                i += 2
                continue
            }

            // Skip string / template literals
            if ch == "\"" || ch == "'" || (language == .typeScript && ch == "`") {
                i = advancePastStringLiteral(chars: chars, startIndex: i)
                continue
            }

            // Scan identifier token
            if isIdentifierStart(ch) {
                let identStart = i
                var identEnd = i + 1
                while identEnd < count && isIdentifierContinue(chars[identEnd]) {
                    identEnd += 1
                }
                let ident = String(chars[identStart..<identEnd])

                if targetSymbols.contains(ident) {
                    // Skip optional generic specialization `<T, U>` on call site (Swift/TS/Rust `foo<Int>(...)` or `foo::<i32>(...)`)
                    var cursor = identEnd
                    while cursor < count && (chars[cursor] == " " || chars[cursor] == "\t") {
                        cursor += 1
                    }
                    if language == .rust && cursor + 2 < count && chars[cursor] == ":" && chars[cursor + 1] == ":" && chars[cursor + 2] == "<" {
                        if let afterTurbo = skipBalancedAngleBrackets(chars: chars, openIndex: cursor + 2) {
                            cursor = afterTurbo
                        }
                    } else if (language == .swift || language == .typeScript) && cursor < count && chars[cursor] == "<" {
                        if let afterGeneric = skipBalancedAngleBrackets(chars: chars, openIndex: cursor) {
                            var peekParen = afterGeneric
                            while peekParen < count && (chars[peekParen] == " " || chars[peekParen] == "\t") {
                                peekParen += 1
                            }
                            if peekParen < count && chars[peekParen] == "(" {
                                cursor = peekParen
                            }
                        }
                    }

                    if cursor < count && chars[cursor] == "(" {
                        if !isDeclarationDefinitionPrefix(chars: chars, identStart: identStart, language: language) {
                            if let closeIdx = findMatchingParenInCharBuffer(chars: chars, openIndex: cursor) {
                                let (lineNum, colNum) = resolveLineAndColumn(offset: identStart, lineStarts: lineStartOffsets)
                                let receiver = extractPrecedingReceiver(chars: chars, identStart: identStart)
                                let prefixEffects = inspectCallPrefixEffects(chars: chars, callStart: identStart)
                                let rawArgsSlice = String(chars[(cursor + 1)..<closeIdx])
                                let parsedArgs = parseCallArguments(rawArgsSlice, language: language)
                                let trailingClosure = detectTrailingClosureAfterCall(
                                    chars: chars,
                                    closeParenIndex: closeIdx,
                                    language: language
                                )
                                let rawCall = String(chars[identStart...closeIdx])

                                occurrences.append(
                                    ScannedCallSiteOccurrence(
                                        symbolName: ident,
                                        receiverExpression: receiver,
                                        filePath: filePath,
                                        lineNumber: lineNum,
                                        columnNumber: colNum,
                                        rawCallSnippet: rawCall,
                                        arguments: parsedArgs,
                                        hasTrailingClosure: trailingClosure,
                                        hasAwaitPrefix: prefixEffects.hasAwait,
                                        hasTryPrefix: prefixEffects.hasTry
                                    )
                                )
                            }
                        }
                    }
                }

                i = identEnd
                continue
            }

            i += 1
        }

        return occurrences
    }

    // MARK: - Private Signature Mutation & Call-Site Comparison Helpers

    private struct CallableSignatureMutation {
        let symbolName: String
        let declarationFile: String
        let modifiedByLane: String
        let oldSignature: ParsedCallableSignature
        let newSignature: ParsedCallableSignature?
    }

    private func collectCallableSignatureMutations(
        baseFiles: [String: String],
        updatedFiles: [String: String],
        modifiedByLane: String,
        includeInternalVisibility: Bool
    ) -> [CallableSignatureMutation] {
        var mutations: [CallableSignatureMutation] = []

        for path in baseFiles.keys.sorted() {
            guard let baseSrc = baseFiles[path] else { continue }
            let updatedSrc = updatedFiles[path]
            if baseSrc == updatedSrc { continue }

            let lang = SourceLanguage.detect(fromPath: path)
            let baseCallables = extractCallableMap(from: baseSrc, language: lang)
            let updatedCallables = updatedSrc.map { extractCallableMap(from: $0, language: lang) } ?? [:]

            for (qualKey, baseSig) in baseCallables {
                if baseSig.visibility == .privateOrFileprivate {
                    continue
                }
                if !includeInternalVisibility && baseSig.visibility != .publicOrOpen {
                    continue
                }

                if let newSig = updatedCallables[qualKey] {
                    if isSignatureBreakingOrDivergent(old: baseSig, new: newSig) {
                        mutations.append(
                            CallableSignatureMutation(
                                symbolName: baseSig.symbolName,
                                declarationFile: path,
                                modifiedByLane: modifiedByLane,
                                oldSignature: baseSig,
                                newSignature: newSig
                            )
                        )
                    }
                } else {
                    // Fallback check by bare symbol name in case container qualification shifted slightly
                    let sameSymbolCandidates = updatedCallables.values.filter { $0.symbolName == baseSig.symbolName }
                    if sameSymbolCandidates.count == 1, let matchedNew = sameSymbolCandidates.first {
                        if isSignatureBreakingOrDivergent(old: baseSig, new: matchedNew) {
                            mutations.append(
                                CallableSignatureMutation(
                                    symbolName: baseSig.symbolName,
                                    declarationFile: path,
                                    modifiedByLane: modifiedByLane,
                                    oldSignature: baseSig,
                                    newSignature: matchedNew
                                )
                            )
                        }
                    } else if sameSymbolCandidates.isEmpty {
                        mutations.append(
                            CallableSignatureMutation(
                                symbolName: baseSig.symbolName,
                                declarationFile: path,
                                modifiedByLane: modifiedByLane,
                                oldSignature: baseSig,
                                newSignature: nil
                            )
                        )
                    }
                }
            }
        }

        return mutations
    }

    private func extractCallableMap(
        from source: String,
        language: SourceLanguage
    ) -> [String: ParsedCallableSignature] {
        let topNodes = parser.parseDeclarations(source: source, language: language)
        var map: [String: ParsedCallableSignature] = [:]

        for node in topNodes {
            if node.kind == .functionDecl || node.kind == .methodDecl {
                if let sig = parseCallableSignature(
                    declarationSource: node.declarationSource,
                    symbolName: node.symbolName,
                    containerTypeName: nil,
                    language: language
                ) {
                    map[node.qualifiedKey] = sig
                }
            }
            for child in node.children where child.kind == .functionDecl || child.kind == .methodDecl {
                if let sig = parseCallableSignature(
                    declarationSource: child.declarationSource,
                    symbolName: child.symbolName,
                    containerTypeName: node.symbolName,
                    language: language
                ) {
                    map[child.qualifiedKey] = sig
                }
            }
        }
        return map
    }

    private func isSignatureBreakingOrDivergent(
        old: ParsedCallableSignature,
        new: ParsedCallableSignature
    ) -> Bool {
        if old.minimumRequiredArity != new.minimumRequiredArity { return true }
        if old.maximumAcceptedArity != new.maximumAcceptedArity { return true }
        if !old.isAsync && new.isAsync { return true }
        if !old.canThrow && new.canThrow { return true }

        let sharedCount = min(old.parameters.count, new.parameters.count)
        for idx in 0..<sharedCount {
            let oldP = old.parameters[idx]
            let newP = new.parameters[idx]
            if old.language == .swift && oldP.externalLabel != newP.externalLabel {
                return true
            }
            if old.language == .python && oldP.internalName != newP.internalName {
                return true
            }
        }
        return false
    }

    private func auditCallerWorkspace(
        mutations: [CallableSignatureMutation],
        callerLaneID: String,
        callerFiles: [String: String],
        baseFiles: [String: String]
    ) -> [CallSiteArityDiagnostic] {
        guard !mutations.isEmpty else { return [] }

        var mutationsBySymbol: [String: [CallableSignatureMutation]] = [:]
        for m in mutations {
            mutationsBySymbol[m.symbolName, default: []].append(m)
        }
        let targetSymbols = Set(mutationsBySymbol.keys)

        var diagnostics: [CallSiteArityDiagnostic] = []

        for callerPath in callerFiles.keys.sorted() {
            guard let callerSrc = callerFiles[callerPath] else { continue }
            let lang = SourceLanguage.detect(fromPath: callerPath)
            let sites = scanCallSites(
                in: callerSrc,
                filePath: callerPath,
                language: lang,
                targetSymbols: targetSymbols
            )

            for site in sites {
                guard let candidateMutations = mutationsBySymbol[site.symbolName] else { continue }
                for mutation in candidateMutations where mutation.declarationFile != callerPath {
                    // Skip if the caller lane itself also updated the declaration file identically
                    if let callerDeclSrc = callerFiles[mutation.declarationFile],
                       let baseDeclSrc = baseFiles[mutation.declarationFile],
                       callerDeclSrc != baseDeclSrc,
                       let newSig = mutation.newSignature {
                        let callerDecls = extractCallableMap(
                            from: callerDeclSrc,
                            language: SourceLanguage.detect(fromPath: mutation.declarationFile)
                        )
                        if callerDecls.values.contains(where: { $0.symbolName == newSig.symbolName && $0.canonicalSummary == newSig.canonicalSummary }) {
                            continue
                        }
                    }

                    if let diag = evaluateCallSiteAgainstMutation(
                        callSite: site,
                        mutation: mutation,
                        callerLaneID: callerLaneID
                    ) {
                        diagnostics.append(diag)
                    }
                }
            }
        }

        return diagnostics
    }

    private func evaluateCallSiteAgainstMutation(
        callSite: ScannedCallSiteOccurrence,
        mutation: CallableSignatureMutation,
        callerLaneID: String
    ) -> CallSiteArityDiagnostic? {
        guard let newSig = mutation.newSignature else {
            let msg = "'\(mutation.symbolName)' was deleted in \(mutation.modifiedByLane) (\(mutation.declarationFile)), breaking call-site at \(callSite.filePath):\(callSite.lineNumber) in \(callerLaneID)."
            return CallSiteArityDiagnostic(
                mismatchKind: .callableDeletedWhileReferenced,
                symbolName: mutation.symbolName,
                declarationFile: mutation.declarationFile,
                modifiedByLane: mutation.modifiedByLane,
                oldSignature: mutation.oldSignature,
                newSignature: nil,
                callSite: callSite,
                callerLane: callerLaneID,
                diagnosticMessage: msg,
                suggestedFixCallSnippet: nil
            )
        }

        let hasSpread = callSite.arguments.contains(where: \.isSpreadOrUnpack)
        let effectiveCount = callSite.effectiveArgumentCount

        // 1. Arity lower bound check
        if !hasSpread && effectiveCount < newSig.minimumRequiredArity {
            let fixSnippet = synthesizeFixItCallSnippet(callSite: callSite, newSignature: newSig)
            let msg = "Call to '\(mutation.symbolName)' at \(callSite.filePath):\(callSite.lineNumber) (\(callerLaneID)) passes \(effectiveCount) argument(s), but \(mutation.modifiedByLane) updated '\(mutation.declarationFile)' to require at least \(newSig.minimumRequiredArity) (\(newSig.canonicalSummary))."
            return CallSiteArityDiagnostic(
                mismatchKind: .tooFewArguments,
                symbolName: mutation.symbolName,
                declarationFile: mutation.declarationFile,
                modifiedByLane: mutation.modifiedByLane,
                oldSignature: mutation.oldSignature,
                newSignature: newSig,
                callSite: callSite,
                callerLane: callerLaneID,
                diagnosticMessage: msg,
                suggestedFixCallSnippet: fixSnippet
            )
        }

        // 2. Arity upper bound check
        if let maxAccepted = newSig.maximumAcceptedArity, effectiveCount > maxAccepted {
            let fixSnippet = synthesizeFixItCallSnippet(callSite: callSite, newSignature: newSig)
            let msg = "Call to '\(mutation.symbolName)' at \(callSite.filePath):\(callSite.lineNumber) (\(callerLaneID)) passes \(effectiveCount) argument(s), exceeding maximum \(maxAccepted) accepted by updated signature \(newSig.canonicalSummary) in \(mutation.modifiedByLane)."
            return CallSiteArityDiagnostic(
                mismatchKind: .tooManyArguments,
                symbolName: mutation.symbolName,
                declarationFile: mutation.declarationFile,
                modifiedByLane: mutation.modifiedByLane,
                oldSignature: mutation.oldSignature,
                newSignature: newSig,
                callSite: callSite,
                callerLane: callerLaneID,
                diagnosticMessage: msg,
                suggestedFixCallSnippet: fixSnippet
            )
        }

        // 3. External parameter label compatibility check (Swift / Python keyword arguments)
        if newSig.language == .swift {
            for arg in callSite.arguments where arg.index < newSig.parameters.count {
                let param = newSig.parameters[arg.index]
                if param.isVariadic && arg.index > 0 { break }
                if arg.label != param.externalLabel {
                    // Only flag if the call site actually matched the old signature's label (avoids overload false positives)
                    if arg.index < mutation.oldSignature.parameters.count,
                       arg.label == mutation.oldSignature.parameters[arg.index].externalLabel {
                        let expectedDesc = param.externalLabel ?? "_"
                        let actualDesc = arg.label ?? "_"
                        let fixSnippet = synthesizeFixItCallSnippet(callSite: callSite, newSignature: newSig)
                        let msg = "Call to '\(mutation.symbolName)' at \(callSite.filePath):\(callSite.lineNumber) (\(callerLaneID)) uses outdated argument label '\(actualDesc):' at position \(arg.index + 1); \(mutation.modifiedByLane) renamed it to '\(expectedDesc):'."
                        return CallSiteArityDiagnostic(
                            mismatchKind: .argumentLabelMismatch,
                            symbolName: mutation.symbolName,
                            declarationFile: mutation.declarationFile,
                            modifiedByLane: mutation.modifiedByLane,
                            oldSignature: mutation.oldSignature,
                            newSignature: newSig,
                            callSite: callSite,
                            callerLane: callerLaneID,
                            diagnosticMessage: msg,
                            suggestedFixCallSnippet: fixSnippet
                        )
                    }
                }
            }
        } else if newSig.language == .python {
            let validNames = Set(newSig.parameters.map(\.internalName))
            let hasKwargsCatchAll = newSig.parameters.contains { $0.isVariadic && $0.internalName.hasPrefix("**") }
            if !hasKwargsCatchAll {
                for arg in callSite.arguments {
                    if let kw = arg.label, !validNames.contains(kw) {
                        let fixSnippet = synthesizeFixItCallSnippet(callSite: callSite, newSignature: newSig)
                        let msg = "Call to '\(mutation.symbolName)' at \(callSite.filePath):\(callSite.lineNumber) (\(callerLaneID)) passes removed/renamed keyword argument '\(kw)=' after \(mutation.modifiedByLane) updated \(mutation.declarationFile)."
                        return CallSiteArityDiagnostic(
                            mismatchKind: .argumentLabelMismatch,
                            symbolName: mutation.symbolName,
                            declarationFile: mutation.declarationFile,
                            modifiedByLane: mutation.modifiedByLane,
                            oldSignature: mutation.oldSignature,
                            newSignature: newSig,
                            callSite: callSite,
                            callerLane: callerLaneID,
                            diagnosticMessage: msg,
                            suggestedFixCallSnippet: fixSnippet
                        )
                    }
                }
            }
        }

        // 4. Newly introduced `async` / `throws` effects without `await` / `try` at call site
        if !mutation.oldSignature.isAsync && newSig.isAsync && !callSite.hasAwaitPrefix {
            let fixSnippet = synthesizeFixItCallSnippet(callSite: callSite, newSignature: newSig)
            let msg = "'\(mutation.symbolName)' became 'async' in \(mutation.modifiedByLane) (\(mutation.declarationFile)), but call-site at \(callSite.filePath):\(callSite.lineNumber) in \(callerLaneID) is missing 'await'."
            return CallSiteArityDiagnostic(
                mismatchKind: .newlyRequiredAsyncAwait,
                symbolName: mutation.symbolName,
                declarationFile: mutation.declarationFile,
                modifiedByLane: mutation.modifiedByLane,
                oldSignature: mutation.oldSignature,
                newSignature: newSig,
                callSite: callSite,
                callerLane: callerLaneID,
                diagnosticMessage: msg,
                suggestedFixCallSnippet: fixSnippet
            )
        }

        if newSig.language == .swift && !mutation.oldSignature.canThrow && newSig.canThrow && !callSite.hasTryPrefix {
            let fixSnippet = synthesizeFixItCallSnippet(callSite: callSite, newSignature: newSig)
            let msg = "'\(mutation.symbolName)' now 'throws' in \(mutation.modifiedByLane) (\(mutation.declarationFile)), but call-site at \(callSite.filePath):\(callSite.lineNumber) in \(callerLaneID) is missing 'try'."
            return CallSiteArityDiagnostic(
                mismatchKind: .newlyRequiredTryEffect,
                symbolName: mutation.symbolName,
                declarationFile: mutation.declarationFile,
                modifiedByLane: mutation.modifiedByLane,
                oldSignature: mutation.oldSignature,
                newSignature: newSig,
                callSite: callSite,
                callerLane: callerLaneID,
                diagnosticMessage: msg,
                suggestedFixCallSnippet: fixSnippet
            )
        }

        return nil
    }

    private func synthesizeFixItCallSnippet(
        callSite: ScannedCallSiteOccurrence,
        newSignature: ParsedCallableSignature
    ) -> String {
        var renderedArgs: [String] = []
        let targetCount = max(
            newSignature.minimumRequiredArity,
            min(callSite.arguments.count, newSignature.maximumAcceptedArity ?? callSite.arguments.count)
        )

        for idx in 0..<targetCount {
            let param: CallableParameterDescriptor? = idx < newSignature.parameters.count
                ? newSignature.parameters[idx]
                : newSignature.parameters.last

            let expr: String
            if idx < callSite.arguments.count {
                expr = callSite.arguments[idx].expressionSnippet
            } else if let p = param {
                let typeHint = p.typeAnnotation.isEmpty ? "Value" : p.typeAnnotation
                expr = "<#\(p.internalName): \(typeHint)#>"
            } else {
                expr = "<#arg#>"
            }

            if newSignature.language == .swift, let p = param {
                if let ext = p.externalLabel {
                    renderedArgs.append("\(ext): \(expr)")
                } else {
                    renderedArgs.append(expr)
                }
            } else if newSignature.language == .python,
                      idx < callSite.arguments.count,
                      callSite.arguments[idx].label != nil,
                      let p = param {
                renderedArgs.append("\(p.internalName)=\(expr)")
            } else {
                renderedArgs.append(expr)
            }
        }

        let receiverPrefix = callSite.receiverExpression.map { "\($0)." } ?? ""
        var effectPrefixes: [String] = []
        if newSignature.language == .swift && newSignature.canThrow && !callSite.hasTryPrefix {
            effectPrefixes.append("try")
        }
        if newSignature.isAsync && !callSite.hasAwaitPrefix && newSignature.language != .rust && newSignature.language != .go {
            effectPrefixes.append("await")
        }
        let prefixText = effectPrefixes.isEmpty ? "" : (effectPrefixes.joined(separator: " ") + " ")
        let rustAwaitSuffix = (newSignature.language == .rust && newSignature.isAsync && !callSite.hasAwaitPrefix) ? ".await" : ""

        return "\(prefixText)\(receiverPrefix)\(callSite.symbolName)(\(renderedArgs.joined(separator: ", ")))\(rustAwaitSuffix)"
    }

    // MARK: - Lexical Signature & Call-Site Parsing Primitives

    private func extractCallableHeaderPrefix(from source: String, language: SourceLanguage) -> String {
        let chars = Array(source)
        var inSingle = false
        var inDouble = false
        var escaped = false
        var parenDepth = 0
        var angleDepth = 0
        var sawCloseParen = false

        for idx in 0..<chars.count {
            let c = chars[idx]
            if escaped {
                escaped = false
                continue
            }
            if c == "\\" && (inSingle || inDouble) {
                escaped = true
                continue
            }
            if c == "\"" && !inSingle { inDouble.toggle(); continue }
            if c == "'" && !inDouble { inSingle.toggle(); continue }
            if inSingle || inDouble { continue }

            if c == "(" { parenDepth += 1 }
            if c == ")" {
                parenDepth = max(0, parenDepth - 1)
                if parenDepth == 0 { sawCloseParen = true }
            }
            if c == "<" { angleDepth += 1 }
            if c == ">" && angleDepth > 0 { angleDepth -= 1 }

            if sawCloseParen && parenDepth == 0 && angleDepth == 0 {
                if c == "{" {
                    return String(chars[..<idx])
                }
                if language == .python && c == ":" {
                    let prevIsArrow = idx > 0 && chars[idx - 1] == "-"
                    if !prevIsArrow {
                        return String(chars[..<idx])
                    }
                }
            }
        }
        return source.components(separatedBy: "\n").first ?? source
    }

    private func findParameterListOpenParen(
        in header: String,
        symbolName: String,
        language: SourceLanguage
    ) -> String.Index? {
        // In Go methods `func (r *Receiver) Name(a int)`, skip the leading receiver `(...)` before `Name`.
        if language == .go {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("func ") || trimmed.hasPrefix("func(") || trimmed.hasPrefix("func\t") {
                if let firstOpen = header.firstIndex(of: "("),
                   let firstClose = findMatchingCloseParen(in: header, openParenIndex: firstOpen) {
                    let beforeFirstOpen = header[..<firstOpen]
                    if !beforeFirstOpen.contains(symbolName) {
                        let rest = header[header.index(after: firstClose)...]
                        return rest.firstIndex(of: "(")
                    }
                }
            }
        }

        if let symRange = header.range(of: symbolName) {
            if let openAfterSym = header[symRange.upperBound...].firstIndex(of: "(") {
                return openAfterSym
            }
        }
        return header.firstIndex(of: "(")
    }

    private func findMatchingCloseParen(in text: String, openParenIndex: String.Index) -> String.Index? {
        var depth = 0
        var inSingle = false
        var inDouble = false
        var escaped = false
        var idx = openParenIndex

        while idx < text.endIndex {
            let c = text[idx]
            if escaped {
                escaped = false
                idx = text.index(after: idx)
                continue
            }
            if c == "\\" && (inSingle || inDouble) {
                escaped = true
                idx = text.index(after: idx)
                continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle()
            } else if c == "'" && !inDouble {
                inSingle.toggle()
            } else if !inSingle && !inDouble {
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private func splitTopLevelCommaSeparated(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var angleDepth = 0
        var inSingle = false
        var inDouble = false
        var escaped = false

        let chars = Array(raw)
        for idx in 0..<chars.count {
            let c = chars[idx]
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\" && (inSingle || inDouble) {
                current.append(c)
                escaped = true
                continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle()
                current.append(c)
                continue
            }
            if c == "'" && !inDouble {
                inSingle.toggle()
                current.append(c)
                continue
            }
            if !inSingle && !inDouble {
                switch c {
                case "(": parenDepth += 1
                case ")": parenDepth = max(0, parenDepth - 1)
                case "[": bracketDepth += 1
                case "]": bracketDepth = max(0, bracketDepth - 1)
                case "{": braceDepth += 1
                case "}": braceDepth = max(0, braceDepth - 1)
                case "<": angleDepth += 1
                case ">":
                    let prev = idx > 0 ? chars[idx - 1] : " "
                    if prev != "-" && prev != "=" && angleDepth > 0 {
                        angleDepth -= 1
                    }
                case "," where parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 && angleDepth == 0:
                    parts.append(current)
                    current = ""
                    continue
                default:
                    break
                }
            }
            current.append(c)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts
    }

    private func isImplicitReceiverParameter(_ segment: String, position: Int, language: SourceLanguage) -> Bool {
        guard position == 0 else { return false }
        switch language {
        case .python:
            return segment == "self" || segment == "cls" || segment.hasPrefix("self:") || segment.hasPrefix("cls:")
        case .rust:
            let cleaned = segment.replacingOccurrences(of: " ", with: "")
            return cleaned == "self" || cleaned == "&self" || cleaned == "&mutself" || cleaned == "mutself" || cleaned.hasPrefix("self:")
        default:
            return false
        }
    }

    private func parseSingleParameter(
        _ rawSegment: String,
        positionIndex: Int,
        language: SourceLanguage
    ) -> CallableParameterDescriptor? {
        // Split top-level `= defaultExpr` if present
        let (declSide, defaultExpr) = splitTopLevelAssignment(rawSegment)
        let hasDefault = defaultExpr != nil
        let trimmedDecl = declSide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDecl.isEmpty else { return nil }

        switch language {
        case .swift:
            return parseSwiftParameter(
                trimmedDecl: trimmedDecl,
                positionIndex: positionIndex,
                hasDefault: hasDefault,
                defaultExpr: defaultExpr
            )
        case .python:
            return parsePythonParameter(
                trimmedDecl: trimmedDecl,
                positionIndex: positionIndex,
                hasDefault: hasDefault,
                defaultExpr: defaultExpr
            )
        case .typeScript:
            return parseTypeScriptParameter(
                trimmedDecl: trimmedDecl,
                positionIndex: positionIndex,
                hasDefault: hasDefault,
                defaultExpr: defaultExpr
            )
        case .rust:
            return parseRustParameter(
                trimmedDecl: trimmedDecl,
                positionIndex: positionIndex,
                hasDefault: hasDefault,
                defaultExpr: defaultExpr
            )
        case .go:
            return parseGoParameter(trimmedDecl: trimmedDecl, positionIndex: positionIndex)
        default:
            return CallableParameterDescriptor(
                positionIndex: positionIndex,
                externalLabel: nil,
                internalName: trimmedDecl,
                typeAnnotation: "",
                hasDefaultValue: hasDefault,
                defaultValueExpression: defaultExpr
            )
        }
    }

    private func parseSwiftParameter(
        trimmedDecl: String,
        positionIndex: Int,
        hasDefault: Bool,
        defaultExpr: String?
    ) -> CallableParameterDescriptor {
        let (lhsRaw, rhsRaw) = splitTopLevelColon(trimmedDecl)
        // Strip leading attributes like `@escaping` or `@Sendable` on parameter if placed before label
        let lhsTokens = lhsRaw
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .filter { !$0.hasPrefix("@") }

        let externalLabel: String?
        let internalName: String
        if lhsTokens.count >= 2 {
            let ext = lhsTokens[lhsTokens.count - 2]
            let name = lhsTokens[lhsTokens.count - 1]
            externalLabel = (ext == "_") ? nil : ext
            internalName = name
        } else if let single = lhsTokens.first {
            externalLabel = (single == "_") ? nil : single
            internalName = single
        } else {
            externalLabel = nil
            internalName = "arg\(positionIndex)"
        }

        var typeText = (rhsRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isVariadic = typeText.hasSuffix("...")
        if isVariadic {
            typeText = String(typeText.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        let isInout = typeText.contains("inout ")
        typeText = typeText
            .replacingOccurrences(of: "inout ", with: "")
            .trimmingCharacters(in: .whitespaces)

        return CallableParameterDescriptor(
            positionIndex: positionIndex,
            externalLabel: externalLabel,
            internalName: internalName,
            typeAnnotation: typeText,
            hasDefaultValue: hasDefault,
            defaultValueExpression: defaultExpr,
            isVariadic: isVariadic,
            isInoutOrMutRef: isInout
        )
    }

    private func parsePythonParameter(
        trimmedDecl: String,
        positionIndex: Int,
        hasDefault: Bool,
        defaultExpr: String?
    ) -> CallableParameterDescriptor? {
        if trimmedDecl == "*" || trimmedDecl == "/" {
            return nil
        }
        let isDoubleStar = trimmedDecl.hasPrefix("**")
        let isSingleStar = !isDoubleStar && trimmedDecl.hasPrefix("*")
        let stripped = isDoubleStar
            ? String(trimmedDecl.dropFirst(2))
            : (isSingleStar ? String(trimmedDecl.dropFirst(1)) : trimmedDecl)
        let (nameSide, typeSide) = splitTopLevelColon(stripped)
        let baseName = nameSide.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullInternalName = isDoubleStar ? "**\(baseName)" : (isSingleStar ? "*\(baseName)" : baseName)
        let typeText = (typeSide ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return CallableParameterDescriptor(
            positionIndex: positionIndex,
            externalLabel: (isSingleStar || isDoubleStar) ? nil : baseName,
            internalName: fullInternalName,
            typeAnnotation: typeText,
            hasDefaultValue: hasDefault,
            defaultValueExpression: defaultExpr,
            isVariadic: isSingleStar || isDoubleStar,
            isInoutOrMutRef: false
        )
    }

    private func parseTypeScriptParameter(
        trimmedDecl: String,
        positionIndex: Int,
        hasDefault: Bool,
        defaultExpr: String?
    ) -> CallableParameterDescriptor {
        var working = trimmedDecl
        for modifier in ["public ", "private ", "protected ", "readonly "] {
            if working.hasPrefix(modifier) {
                working = String(working.dropFirst(modifier.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let isRest = working.hasPrefix("...")
        if isRest {
            working = String(working.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        let (nameSide, typeSide) = splitTopLevelColon(working)
        var rawName = nameSide.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOptionalQuestion = rawName.hasSuffix("?")
        if isOptionalQuestion {
            rawName = String(rawName.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let typeText = (typeSide ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return CallableParameterDescriptor(
            positionIndex: positionIndex,
            externalLabel: nil,
            internalName: rawName.isEmpty ? "arg\(positionIndex)" : rawName,
            typeAnnotation: typeText,
            hasDefaultValue: hasDefault || isOptionalQuestion,
            defaultValueExpression: defaultExpr,
            isVariadic: isRest,
            isInoutOrMutRef: false
        )
    }

    private func parseRustParameter(
        trimmedDecl: String,
        positionIndex: Int,
        hasDefault: Bool,
        defaultExpr: String?
    ) -> CallableParameterDescriptor {
        let (nameSide, typeSide) = splitTopLevelColon(trimmedDecl)
        var rawName = nameSide.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawName.hasPrefix("mut ") {
            rawName = String(rawName.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        let typeText = (typeSide ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isMutRef = typeText.hasPrefix("&mut ")

        return CallableParameterDescriptor(
            positionIndex: positionIndex,
            externalLabel: nil,
            internalName: rawName.isEmpty ? "arg\(positionIndex)" : rawName,
            typeAnnotation: typeText,
            hasDefaultValue: hasDefault,
            defaultValueExpression: defaultExpr,
            isVariadic: false,
            isInoutOrMutRef: isMutRef
        )
    }

    private func parseGoParameter(trimmedDecl: String, positionIndex: Int) -> CallableParameterDescriptor {
        let parts = trimmedDecl.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let name: String
        var typeText: String
        if parts.count >= 2 {
            name = parts[0]
            typeText = parts.dropFirst().joined(separator: " ")
        } else {
            name = "arg\(positionIndex)"
            typeText = parts.first ?? ""
        }
        let isVariadic = typeText.hasPrefix("...")
        if isVariadic {
            typeText = String(typeText.dropFirst(3))
        }
        let isPointer = typeText.hasPrefix("*")
        return CallableParameterDescriptor(
            positionIndex: positionIndex,
            externalLabel: nil,
            internalName: name,
            typeAnnotation: typeText,
            hasDefaultValue: false,
            defaultValueExpression: nil,
            isVariadic: isVariadic,
            isInoutOrMutRef: isPointer
        )
    }

    private func splitTopLevelAssignment(_ raw: String) -> (lhs: String, rhs: String?) {
        let chars = Array(raw)
        var paren = 0
        var bracket = 0
        var brace = 0
        var angle = 0
        var inSingle = false
        var inDouble = false
        var escaped = false

        for idx in 0..<chars.count {
            let c = chars[idx]
            if escaped { escaped = false; continue }
            if c == "\\" && (inSingle || inDouble) { escaped = true; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); continue }
            if c == "'" && !inDouble { inSingle.toggle(); continue }
            if inSingle || inDouble { continue }

            switch c {
            case "(": paren += 1
            case ")": paren = max(0, paren - 1)
            case "[": bracket += 1
            case "]": bracket = max(0, bracket - 1)
            case "{": brace += 1
            case "}": brace = max(0, brace - 1)
            case "<": angle += 1
            case ">": if angle > 0 { angle -= 1 }
            case "=" where paren == 0 && bracket == 0 && brace == 0 && angle == 0:
                let prev = idx > 0 ? chars[idx - 1] : " "
                let next = idx + 1 < chars.count ? chars[idx + 1] : " "
                if prev != "=" && prev != "!" && prev != "<" && prev != ">" && next != "=" && next != ">" {
                    let lhs = String(chars[..<idx])
                    let rhs = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (lhs, rhs)
                }
            default:
                break
            }
        }
        return (raw, nil)
    }

    private func splitTopLevelColon(_ raw: String) -> (lhs: String, rhs: String?) {
        let chars = Array(raw)
        var paren = 0
        var bracket = 0
        var angle = 0

        for idx in 0..<chars.count {
            let c = chars[idx]
            switch c {
            case "(": paren += 1
            case ")": paren = max(0, paren - 1)
            case "[": bracket += 1
            case "]": bracket = max(0, bracket - 1)
            case "<": angle += 1
            case ">": if angle > 0 { angle -= 1 }
            case ":" where paren == 0 && bracket == 0 && angle == 0:
                let next = idx + 1 < chars.count ? chars[idx + 1] : " "
                let prev = idx > 0 ? chars[idx - 1] : " "
                if next != ":" && prev != ":" {
                    return (String(chars[..<idx]), String(chars[(idx + 1)...]))
                }
            default:
                break
            }
        }
        return (raw, nil)
    }

    private func detectVisibility(
        in leadingHeader: String,
        symbolName: String,
        language: SourceLanguage
    ) -> CallableVisibility {
        switch language {
        case .swift:
            if leadingHeader.contains("public ") || leadingHeader.contains("open ") {
                return .publicOrOpen
            }
            if leadingHeader.contains("private ") || leadingHeader.contains("fileprivate ") {
                return .privateOrFileprivate
            }
            return .internalOrPackage
        case .typeScript:
            if leadingHeader.contains("private ") { return .privateOrFileprivate }
            if leadingHeader.contains("export ") || leadingHeader.contains("public ") { return .publicOrOpen }
            return .internalOrPackage
        case .rust:
            if leadingHeader.contains("pub ") || leadingHeader.contains("pub(") { return .publicOrOpen }
            return .privateOrFileprivate
        case .go:
            if let first = symbolName.first, first.isUppercase {
                return .publicOrOpen
            }
            return .internalOrPackage
        case .python:
            if symbolName.hasPrefix("_") && !symbolName.hasPrefix("__") {
                return .privateOrFileprivate
            }
            return .publicOrOpen
        default:
            return .internalOrPackage
        }
    }

    private func detectAsyncAndThrowEffects(
        leadingHeader: String,
        trailingHeader: String,
        language: SourceLanguage
    ) -> (isAsync: Bool, canThrow: Bool) {
        switch language {
        case .swift:
            let tokens = Set(trailingHeader.components(separatedBy: CharacterSet.alphanumerics.inverted))
            let isAsync = tokens.contains("async")
            let canThrow = tokens.contains("throws") || tokens.contains("rethrows")
            return (isAsync, canThrow)
        case .python:
            return (leadingHeader.contains("async def"), false)
        case .typeScript:
            let isAsync = leadingHeader.contains("async ") || trailingHeader.contains("Promise<")
            return (isAsync, false)
        case .rust:
            let isAsync = leadingHeader.contains("async fn")
            let canThrow = trailingHeader.contains("Result<")
            return (isAsync, canThrow)
        case .go:
            let canThrow = trailingHeader.contains("error")
            return (false, canThrow)
        default:
            return (false, false)
        }
    }

    private func extractReturnTypeAnnotation(from trailingHeader: String, language: SourceLanguage) -> String? {
        let trimmed = trailingHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch language {
        case .swift, .python, .rust:
            if let arrowRange = trimmed.range(of: "->") {
                let after = trimmed[arrowRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let whereRange = after.range(of: " where ") {
                    return String(after[..<whereRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return after.isEmpty ? nil : after
            }
            return nil
        case .typeScript:
            if let colon = trimmed.firstIndex(of: ":") {
                let after = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return after.isEmpty ? nil : after
            }
            return nil
        case .go:
            return trimmed
        default:
            return nil
        }
    }

    private func isIdentifierStart(_ ch: Character) -> Bool {
        ch == "_" || ch == "$" || ch.isLetter
    }

    private func isIdentifierContinue(_ ch: Character) -> Bool {
        ch == "_" || ch == "$" || ch.isLetter || ch.isNumber
    }

    private func advancePastStringLiteral(chars: [Character], startIndex: Int) -> Int {
        let quote = chars[startIndex]
        let count = chars.count
        // Triple-quoted strings (`"""` or `'''`) in Swift / Python
        if startIndex + 2 < count && chars[startIndex + 1] == quote && chars[startIndex + 2] == quote {
            var idx = startIndex + 3
            while idx + 2 < count {
                if chars[idx] == "\\" {
                    idx += 2
                    continue
                }
                if chars[idx] == quote && chars[idx + 1] == quote && chars[idx + 2] == quote {
                    return idx + 3
                }
                idx += 1
            }
            return count
        }

        var idx = startIndex + 1
        while idx < count {
            if chars[idx] == "\\" {
                idx += 2
                continue
            }
            if chars[idx] == quote {
                return idx + 1
            }
            if quote != "`" && chars[idx] == "\n" {
                return idx + 1
            }
            idx += 1
        }
        return count
    }

    private func skipBalancedAngleBrackets(chars: [Character], openIndex: Int) -> Int? {
        var depth = 0
        var idx = openIndex
        let limit = min(chars.count, openIndex + 160)
        while idx < limit {
            let c = chars[idx]
            if c == "<" {
                depth += 1
            } else if c == ">" {
                depth -= 1
                if depth == 0 { return idx + 1 }
            } else if c == ";" || c == "{" || c == "}" || c == "\n" {
                return nil
            }
            idx += 1
        }
        return nil
    }

    private func findMatchingParenInCharBuffer(chars: [Character], openIndex: Int) -> Int? {
        var depth = 0
        var idx = openIndex
        let count = chars.count
        while idx < count {
            let c = chars[idx]
            if c == "\"" || c == "'" {
                idx = advancePastStringLiteral(chars: chars, startIndex: idx)
                continue
            }
            if c == "/" && idx + 1 < count && chars[idx + 1] == "/" {
                idx += 2
                while idx < count && chars[idx] != "\n" { idx += 1 }
                continue
            }
            if c == "/" && idx + 1 < count && chars[idx + 1] == "*" {
                idx += 2
                while idx + 1 < count && !(chars[idx] == "*" && chars[idx + 1] == "/") { idx += 1 }
                idx += 2
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx += 1
        }
        return nil
    }

    private func isDeclarationDefinitionPrefix(
        chars: [Character],
        identStart: Int,
        language: SourceLanguage
    ) -> Bool {
        var end = identStart
        while end > 0 && (chars[end - 1] == " " || chars[end - 1] == "\t") {
            end -= 1
        }
        // In Go methods `func (s *Srv) Foo(...)`, right before `Foo` is `) ` preceded by `func` on same line
        if language == .go && end > 0 && chars[end - 1] == ")" {
            var lineScan = end - 1
            while lineScan > 0 && chars[lineScan - 1] != "\n" {
                lineScan -= 1
            }
            let linePrefix = String(chars[lineScan..<identStart]).trimmingCharacters(in: .whitespaces)
            if linePrefix.hasPrefix("func ") || linePrefix.hasPrefix("func(") {
                return true
            }
        }

        var wordStart = end
        while wordStart > 0 && isIdentifierContinue(chars[wordStart - 1]) {
            wordStart -= 1
        }
        guard wordStart < end else { return false }
        let prevWord = String(chars[wordStart..<end])
        let declKeywords: Set<String> = ["func", "def", "fn", "function", "class", "struct", "enum", "protocol", "interface"]
        return declKeywords.contains(prevWord)
    }

    private func extractPrecedingReceiver(chars: [Character], identStart: Int) -> String? {
        var dotIdx = identStart - 1
        while dotIdx >= 0 && (chars[dotIdx] == " " || chars[dotIdx] == "\t") {
            dotIdx -= 1
        }
        guard dotIdx >= 0 && chars[dotIdx] == "." else { return nil }
        var recvEnd = dotIdx
        if recvEnd > 0 && chars[recvEnd - 1] == "?" {
            recvEnd -= 1
        }
        var recvStart = recvEnd
        while recvStart > 0 && (isIdentifierContinue(chars[recvStart - 1]) || chars[recvStart - 1] == ".") {
            recvStart -= 1
        }
        guard recvStart < recvEnd else { return nil }
        return String(chars[recvStart..<recvEnd])
    }

    private func inspectCallPrefixEffects(chars: [Character], callStart: Int) -> (hasAwait: Bool, hasTry: Bool) {
        var lineStart = callStart
        while lineStart > 0 && chars[lineStart - 1] != "\n" && chars[lineStart - 1] != ";" && chars[lineStart - 1] != "{" {
            lineStart -= 1
        }
        let prefixSlice = String(chars[lineStart..<callStart])
        let words = Set(prefixSlice.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let hasAwait = words.contains("await")
        let hasTry = words.contains("try")
        return (hasAwait, hasTry)
    }

    private func detectTrailingClosureAfterCall(
        chars: [Character],
        closeParenIndex: Int,
        language: SourceLanguage
    ) -> Bool {
        guard language == .swift else { return false }
        var scan = closeParenIndex + 1
        while scan < chars.count && (chars[scan] == " " || chars[scan] == "\t") {
            scan += 1
        }
        return scan < chars.count && chars[scan] == "{"
    }

    private func parseCallArguments(_ rawInsideParens: String, language: SourceLanguage) -> [ScannedCallSiteArgument] {
        let trimmedAll = rawInsideParens.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAll.isEmpty else { return [] }

        let segments = splitTopLevelCommaSeparated(rawInsideParens)
        var results: [ScannedCallSiteArgument] = []

        for (idx, seg) in segments.enumerated() {
            let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let isSpread = trimmed.hasPrefix("...") || (language == .python && trimmed.hasPrefix("*"))
            var label: String?
            var expr = trimmed

            if language == .swift {
                let (lhs, rhs) = splitTopLevelColon(trimmed)
                if let rhsExpr = rhs {
                    let candidateLabel = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidateLabel.isEmpty && candidateLabel.allSatisfy({ isIdentifierContinue($0) }) {
                        label = candidateLabel
                        expr = rhsExpr.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } else if language == .python && !isSpread {
                let (lhs, rhs) = splitTopLevelAssignment(trimmed)
                if let rhsExpr = rhs {
                    let candidateKw = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidateKw.isEmpty && candidateKw.allSatisfy({ isIdentifierContinue($0) }) {
                        label = candidateKw
                        expr = rhsExpr
                    }
                }
            }

            results.append(
                ScannedCallSiteArgument(
                    index: idx,
                    label: label,
                    expressionSnippet: expr,
                    isSpreadOrUnpack: isSpread
                )
            )
        }

        return results
    }

    private func resolveLineAndColumn(offset: Int, lineStarts: [Int]) -> (line: Int, column: Int) {
        var low = 0
        var high = lineStarts.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return (best + 1, offset - lineStarts[best] + 1)
    }
}

// MARK: - Clean Source-Code Emitter Preserving Indentation & Doc-Comments

public struct CleanASTSourceCodeEmitter: Sendable {
    public init() {}

    /// Detects the dominant indentation style (2-space, 4-space, or tab) and newline convention across source samples.
    public func detectIndentationProfile(
        samples: [String],
        preference: IndentationStylePreference = .autoDetect
    ) -> DetectedIndentationProfile {
        let nonEmptySamples = samples.filter { !$0.isEmpty }
        let usesCRLF = nonEmptySamples.first?.contains("\r\n") ?? false
        let newlineSeq = usesCRLF ? "\r\n" : "\n"

        switch preference {
        case .spaces(let width):
            return DetectedIndentationProfile(
                unitKind: .spaces,
                indentWidth: max(1, width),
                newlineSequence: newlineSeq,
                ensuresTrailingNewline: true
            )
        case .tabs:
            return DetectedIndentationProfile(
                unitKind: .tabs,
                indentWidth: 4,
                newlineSequence: newlineSeq,
                ensuresTrailingNewline: true
            )
        case .autoDetect:
            break
        }

        var tabIndentedLineCount = 0
        var spaceIndentedLineCount = 0
        var stepHistogram: [Int: Int] = [:]

        for sample in nonEmptySamples {
            let lines = sample.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            var prevSpaces = 0
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("*") { continue }
                if line.hasPrefix("\t") {
                    tabIndentedLineCount += 1
                    continue
                }
                var spaces = 0
                for ch in line {
                    if ch == " " { spaces += 1 } else { break }
                }
                if spaces > 0 {
                    spaceIndentedLineCount += 1
                    let delta = abs(spaces - prevSpaces)
                    if delta >= 2 && delta <= 8 {
                        stepHistogram[delta, default: 0] += 1
                    }
                }
                prevSpaces = spaces
            }
        }

        if tabIndentedLineCount > spaceIndentedLineCount && tabIndentedLineCount > 0 {
            return DetectedIndentationProfile(
                unitKind: .tabs,
                indentWidth: 4,
                newlineSequence: newlineSeq,
                ensuresTrailingNewline: true
            )
        }

        let count2 = stepHistogram[2, default: 0]
        let count4 = stepHistogram[4, default: 0]
        let chosenWidth: Int
        if count2 > count4 * 2 && count2 >= 2 {
            chosenWidth = 2
        } else {
            chosenWidth = 4
        }

        return DetectedIndentationProfile(
            unitKind: .spaces,
            indentWidth: chosenWidth,
            newlineSequence: newlineSeq,
            ensuresTrailingNewline: true
        )
    }

    /// Emits clean, deterministically spaced source code from resolved `SemanticMergeChunk` entries while preserving
    /// leading file header comments, doc-comments (`///`, `/** ... */`, `#`, `//!`), and detected indentation.
    public func emitMergedDocument(
        chunks: [SemanticMergeChunk],
        language: SourceLanguage,
        leadingFileBanner: String? = nil,
        referenceSources: [String] = [],
        indentationPreference: IndentationStylePreference = .autoDetect
    ) -> EmittedSourceDocument {
        let profile = detectIndentationProfile(
            samples: referenceSources + chunks.map(\.resolvedSource),
            preference: indentationPreference
        )

        var renderedSections: [(kind: ASTDeclarationKind, text: String)] = []
        var normalizedImportCount = 0

        if let banner = leadingFileBanner?.trimmingCharacters(in: .whitespacesAndNewlines), !banner.isEmpty {
            renderedSections.append((.packageOrModule, stripTrailingHorizontalWhitespace(banner)))
        }

        for chunk in chunks {
            let raw = chunk.resolvedSource
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .newlines)
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if chunk.kind == .importGroup && !chunk.resolution.isConflict {
                let (formattedImports, count) = normalizeImportGroupBlock(raw, language: language)
                if !formattedImports.isEmpty {
                    normalizedImportCount += count
                    renderedSections.append((.importGroup, formattedImports))
                }
            } else {
                let cleanedBlock = normalizeTopLevelDeclarationBlock(raw, profile: profile)
                renderedSections.append((chunk.kind, cleanedBlock))
            }
        }

        var outputBuffer = ""
        for (idx, section) in renderedSections.enumerated() {
            if idx > 0 {
                let prevKind = renderedSections[idx - 1].kind
                let blankLinesBetween = preferredVerticalBlankLines(
                    previous: prevKind,
                    current: section.kind,
                    language: language
                )
                outputBuffer += String(repeating: "\n", count: blankLinesBetween + 1)
            }
            outputBuffer += section.text
        }

        if profile.ensuresTrailingNewline && !outputBuffer.isEmpty && !outputBuffer.hasSuffix("\n") {
            outputBuffer += "\n"
        }

        if profile.newlineSequence != "\n" {
            outputBuffer = outputBuffer.replacingOccurrences(of: "\n", with: profile.newlineSequence)
        }

        let audit = auditDelimiterBalance(in: outputBuffer, language: language)
        return EmittedSourceDocument(
            formattedSource: outputBuffer,
            indentationProfile: profile,
            delimiterAudit: audit,
            normalizedImportCount: normalizedImportCount,
            emittedDeclarationCount: renderedSections.count
        )
    }

    /// Re-indents a nested member block (preserving its doc-comments and internal relative body indentation)
    /// to sit cleanly at `indentDepth` levels inside a parent type declaration.
    public func formatMemberBlock(
        leadingTrivia: String,
        declarationSource: String,
        indentDepth: Int,
        profile: DetectedIndentationProfile
    ) -> String {
        let targetIndent = String(repeating: profile.indentUnitString, count: max(0, indentDepth))
        var outputLines: [String] = []

        if !leadingTrivia.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let triviaLines = leadingTrivia
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
            // Drop trailing empty line generated by `leadingTrivia` joiner
            let effectiveTrivia = triviaLines.last?.isEmpty == true ? Array(triviaLines.dropLast()) : triviaLines
            let normalizedTrivia = reindentLinesPreservingRelativeStructure(
                effectiveTrivia,
                targetBaseIndent: targetIndent,
                tabWidth: profile.indentWidth
            )
            outputLines.append(contentsOf: normalizedTrivia)
        }

        let declLines = declarationSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let normalizedDecl = reindentLinesPreservingRelativeStructure(
            declLines,
            targetBaseIndent: targetIndent,
            tabWidth: profile.indentWidth
        )
        outputLines.append(contentsOf: normalizedDecl)

        return outputLines
            .map { stripSingleLineTrailingWhitespace($0) }
            .joined(separator: "\n")
    }

    /// Extracts any leading file header banner comment (e.g. copyright/license/module doc-comment) preceding imports.
    public func extractLeadingFileHeaderBanner(from source: String, language: SourceLanguage) -> String? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var bannerLines: [String] = []
        var inBlockComment = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                bannerLines.append(line)
                if trimmed.contains("*/") {
                    inBlockComment = false
                }
                continue
            }
            if trimmed.hasPrefix("/*") {
                bannerLines.append(line)
                if !trimmed.contains("*/") {
                    inBlockComment = true
                }
                continue
            }
            if trimmed.hasPrefix("//") || (language == .python && trimmed.hasPrefix("#")) {
                bannerLines.append(line)
                continue
            }
            if trimmed.isEmpty && !bannerLines.isEmpty {
                // Blank line separates file header banner from subsequent declaration/import
                return bannerLines.joined(separator: "\n")
            }
            // If no blank line separated the comment from the first declaration, it's declaration trivia, not a file banner
            return nil
        }

        return bannerLines.isEmpty ? nil : bannerLines.joined(separator: "\n")
    }

    /// Performs a string- and comment-aware `{}` / `()` / `[]` delimiter balance verification.
    public func auditDelimiterBalance(in source: String, language: SourceLanguage) -> DelimiterBalanceAudit {
        if language == .markdown || language == .plainText {
            return DelimiterBalanceAudit(isBalanced: true)
        }

        let chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        let count = chars.count
        var braceStack: [Int] = []
        var parenStack: [Int] = []
        var bracketStack: [Int] = []
        var unexpectedClosings: [String] = []

        var lineNumber = 1
        var i = 0

        while i < count {
            let c = chars[i]
            if c == "\n" {
                lineNumber += 1
                i += 1
                continue
            }
            // Skip conflict marker lines (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`) so `>>>` or marker text doesn't skew check
            if (i == 0 || chars[i - 1] == "\n"),
               i + 6 < count,
               (c == "<" || c == "|" || c == "=" || c == ">") {
                let markerRun = String(chars[i..<(i + 7)])
                if markerRun == "<<<<<<<" || markerRun == "|||||||" || markerRun == "=======" || markerRun == ">>>>>>>" {
                    while i < count && chars[i] != "\n" { i += 1 }
                    continue
                }
            }

            // Skip line comments
            if c == "/" && i + 1 < count && chars[i + 1] == "/" {
                i += 2
                while i < count && chars[i] != "\n" { i += 1 }
                continue
            }
            if language == .python && c == "#" {
                i += 1
                while i < count && chars[i] != "\n" { i += 1 }
                continue
            }
            // Skip block comments
            if c == "/" && i + 1 < count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { lineNumber += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            // Skip string literals
            if c == "\"" || c == "'" || (language == .typeScript && c == "`") {
                let quote = c
                if i + 2 < count && chars[i + 1] == quote && chars[i + 2] == quote {
                    i += 3
                    while i + 2 < count {
                        if chars[i] == "\n" { lineNumber += 1 }
                        if chars[i] == "\\" { i += 2; continue }
                        if chars[i] == quote && chars[i + 1] == quote && chars[i + 2] == quote {
                            i += 3
                            break
                        }
                        i += 1
                    }
                    continue
                } else if language != .rust || quote != "'" {
                    i += 1
                    while i < count {
                        if chars[i] == "\n" {
                            if quote != "`" { break }
                            lineNumber += 1
                        }
                        if chars[i] == "\\" { i += 2; continue }
                        if chars[i] == quote { i += 1; break }
                        i += 1
                    }
                    continue
                }
            }

            switch c {
            case "{":
                braceStack.append(lineNumber)
            case "}":
                if braceStack.isEmpty {
                    unexpectedClosings.append("line \(lineNumber): unmatched '}'")
                } else {
                    braceStack.removeLast()
                }
            case "(":
                parenStack.append(lineNumber)
            case ")":
                if parenStack.isEmpty {
                    unexpectedClosings.append("line \(lineNumber): unmatched ')'")
                } else {
                    parenStack.removeLast()
                }
            case "[":
                bracketStack.append(lineNumber)
            case "]":
                if bracketStack.isEmpty {
                    unexpectedClosings.append("line \(lineNumber): unmatched ']'")
                } else {
                    bracketStack.removeLast()
                }
            default:
                break
            }

            i += 1
        }

        let ok = braceStack.isEmpty && parenStack.isEmpty && bracketStack.isEmpty && unexpectedClosings.isEmpty
        return DelimiterBalanceAudit(
            isBalanced: ok,
            unclosedBraceLines: braceStack,
            unclosedParenLines: parenStack,
            unclosedBracketLines: bracketStack,
            unexpectedClosingLocations: unexpectedClosings
        )
    }

    // MARK: - Private Formatting Helpers

    private func normalizeImportGroupBlock(_ raw: String, language: SourceLanguage) -> (formatted: String, count: Int) {
        let lines = raw.components(separatedBy: "\n")
        // For Go multi-line `import ( ... )` blocks, preserve block structure while stripping trailing spaces
        if language == .go && raw.contains("import (") {
            let cleaned = lines.map { stripSingleLineTrailingWhitespace($0) }.joined(separator: "\n")
            return (cleaned, lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
        }

        var packageHeaderLines: [String] = []
        var importLines: [String] = []
        var seenImports = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if language == .go && trimmed.hasPrefix("package ") {
                if !packageHeaderLines.contains(trimmed) {
                    packageHeaderLines.append(trimmed)
                }
            } else if seenImports.insert(trimmed).inserted {
                importLines.append(trimmed)
            }
        }

        importLines.sort()
        var combined: [String] = []
        if !packageHeaderLines.isEmpty {
            combined.append(packageHeaderLines.joined(separator: "\n"))
        }
        if !importLines.isEmpty {
            combined.append(importLines.joined(separator: "\n"))
        }
        return (combined.joined(separator: "\n\n"), importLines.count)
    }

    private func normalizeTopLevelDeclarationBlock(_ raw: String, profile: DetectedIndentationProfile) -> String {
        let lines = raw.components(separatedBy: "\n")
        let deindented = reindentLinesPreservingRelativeStructure(
            lines,
            targetBaseIndent: "",
            tabWidth: profile.indentWidth
        )
        // Collapse >= 3 consecutive blank lines inside a block down to a single blank line
        var collapsed: [String] = []
        var consecutiveBlank = 0
        for line in deindented {
            let cleaned = stripSingleLineTrailingWhitespace(line)
            if cleaned.isEmpty {
                consecutiveBlank += 1
                if consecutiveBlank <= 1 {
                    collapsed.append("")
                }
            } else {
                consecutiveBlank = 0
                collapsed.append(cleaned)
            }
        }
        return collapsed.joined(separator: "\n")
    }

    private func reindentLinesPreservingRelativeStructure(
        _ lines: [String],
        targetBaseIndent: String,
        tabWidth: Int
    ) -> [String] {
        guard !lines.isEmpty else { return [] }

        var minIndentColumns: Int?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let cols = measureLeadingColumns(line, tabWidth: tabWidth)
            if let existing = minIndentColumns {
                minIndentColumns = min(existing, cols)
            } else {
                minIndentColumns = cols
            }
        }

        let baseline = minIndentColumns ?? 0
        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "" }
            let stripped = stripLeadingColumns(line, columnsToDrop: baseline, tabWidth: tabWidth)
            return targetBaseIndent + stripped
        }
    }

    private func measureLeadingColumns(_ line: String, tabWidth: Int) -> Int {
        var cols = 0
        for ch in line {
            if ch == " " {
                cols += 1
            } else if ch == "\t" {
                cols += tabWidth
            } else {
                break
            }
        }
        return cols
    }

    private func stripLeadingColumns(_ line: String, columnsToDrop: Int, tabWidth: Int) -> String {
        guard columnsToDrop > 0 else { return line }
        var dropped = 0
        var idx = line.startIndex
        while idx < line.endIndex && dropped < columnsToDrop {
            let ch = line[idx]
            if ch == " " {
                dropped += 1
                idx = line.index(after: idx)
            } else if ch == "\t" {
                dropped += tabWidth
                idx = line.index(after: idx)
            } else {
                break
            }
        }
        return String(line[idx...])
    }

    private func preferredVerticalBlankLines(
        previous: ASTDeclarationKind,
        current: ASTDeclarationKind,
        language: SourceLanguage
    ) -> Int {
        if language == .python && (current == .functionDecl || current == .classDecl) && previous != .packageOrModule {
            // PEP 8: two blank lines around top-level functions and classes in Python
            return 2
        }
        if previous == .constantOrVar && current == .constantOrVar {
            return 0
        }
        if previous == .typeAlias && current == .typeAlias {
            return 0
        }
        return 1
    }

    private func stripTrailingHorizontalWhitespace(_ block: String) -> String {
        block
            .components(separatedBy: "\n")
            .map { stripSingleLineTrailingWhitespace($0) }
            .joined(separator: "\n")
    }

    private func stripSingleLineTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let prev = line.index(before: end)
            if line[prev] == " " || line[prev] == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(line[..<end])
    }
}

// MARK: - Interactive AST-Aware Conflict Resolution Engine

public struct InteractiveConflictResolutionEngine: Sendable {
    public let parser: MultiLanguageDeclarationParser
    public let callSiteDetector: CrossFileBrokenCallSiteDetector
    public let sourceEmitter: CleanASTSourceCodeEmitter

    public init(
        parser: MultiLanguageDeclarationParser = MultiLanguageDeclarationParser(),
        callSiteDetector: CrossFileBrokenCallSiteDetector = CrossFileBrokenCallSiteDetector(),
        sourceEmitter: CleanASTSourceCodeEmitter = CleanASTSourceCodeEmitter()
    ) {
        self.parser = parser
        self.callSiteDetector = callSiteDetector
        self.sourceEmitter = sourceEmitter
    }

    /// Resolves a single conflicted `SemanticMergeChunk` inside a `ThreeWaySemanticMergeReport`, regenerating
    /// clean formatted source code and producing a reversible `RelayUndoMutation`.
    public func resolveChunk(
        in report: ThreeWaySemanticMergeReport,
        chunkID: UUID,
        strategy: ConflictResolutionStrategy,
        options: ConflictResolutionOptions = ConflictResolutionOptions(),
        laneEvidence: [String: LaneVerificationEvidence] = [:]
    ) -> Result<(report: ThreeWaySemanticMergeReport, outcome: ChunkResolutionOutcome), RelayIDEError> {
        guard let targetIdx = report.chunks.firstIndex(where: { $0.id == chunkID }) else {
            return .failure(.semanticMergeFailure("Merge chunk '\(chunkID)' not found in '\(report.relativePath)'."))
        }

        let originalChunk = report.chunks[targetIdx]
        let outcome = resolveSingleChunk(
            originalChunk,
            language: report.language,
            filePath: report.relativePath,
            leftLaneID: report.leftLaneID,
            rightLaneID: report.rightLaneID,
            strategy: strategy,
            options: options,
            laneEvidence: laneEvidence
        )

        var updatedChunks = report.chunks
        updatedChunks[targetIdx] = outcome.updatedChunk

        let referenceSources = updatedChunks.compactMap(\.baseSource)
            + updatedChunks.compactMap(\.leftSource)
            + updatedChunks.compactMap(\.rightSource)
        let emitted = sourceEmitter.emitMergedDocument(
            chunks: updatedChunks,
            language: report.language,
            referenceSources: referenceSources,
            indentationPreference: options.indentationPreference
        )

        let updatedReport = rebuildMergeReport(
            from: report,
            updatedChunks: updatedChunks,
            mergedText: emitted.formattedSource,
            crossFileCollisions: report.crossFileCollisions
        )
        return .success((updatedReport, outcome))
    }

    /// Resolves an individual `SemanticMergeChunk` according to `strategy` and `options`.
    public func resolveSingleChunk(
        _ chunk: SemanticMergeChunk,
        language: SourceLanguage,
        filePath: String,
        leftLaneID: String,
        rightLaneID: String,
        strategy: ConflictResolutionStrategy,
        options: ConflictResolutionOptions = ConflictResolutionOptions(),
        laneEvidence: [String: LaneVerificationEvidence] = [:]
    ) -> ChunkResolutionOutcome {
        let previousSource = chunk.resolvedSource
        let profile = sourceEmitter.detectIndentationProfile(
            samples: [chunk.baseSource, chunk.leftSource, chunk.rightSource].compactMap { $0 },
            preference: options.indentationPreference
        )

        let computed = computeStrategyResolution(
            chunk: chunk,
            language: language,
            leftLaneID: leftLaneID,
            rightLaneID: rightLaneID,
            strategy: strategy,
            options: options,
            profile: profile,
            laneEvidence: laneEvidence
        )

        let updatedChunk = SemanticMergeChunk(
            id: chunk.id,
            qualifiedKey: chunk.qualifiedKey,
            symbolName: chunk.symbolName,
            kind: chunk.kind,
            resolution: computed.resolution,
            baseSource: chunk.baseSource,
            leftSource: chunk.leftSource,
            rightSource: chunk.rightSource,
            resolvedSource: computed.resolvedSource,
            leftVendor: chunk.leftVendor,
            rightVendor: chunk.rightVendor,
            explanation: computed.explanation
        )

        let undo = RelayUndoMutation.resolveMergeChunk(
            filePath: filePath,
            chunkID: chunk.id,
            previousSource: previousSource,
            updatedSource: computed.resolvedSource
        )
        let audit = sourceEmitter.auditDelimiterBalance(in: computed.resolvedSource, language: language)

        return ChunkResolutionOutcome(
            updatedChunk: updatedChunk,
            appliedStrategy: strategy,
            undoMutation: undo,
            verificationSelection: computed.verificationSelection,
            delimiterAudit: audit,
            resolutionNotes: computed.notes
        )
    }

    /// Resolves all unresolved conflict chunks in `report` in one deterministic pass, emits clean formatted code,
    /// and optionally runs cross-file broken call-site arity detection across the workspace.
    public func resolveAllConflicts(
        in report: ThreeWaySemanticMergeReport,
        strategy: ConflictResolutionStrategy,
        options: ConflictResolutionOptions = ConflictResolutionOptions(),
        laneEvidence: [String: LaneVerificationEvidence] = [:],
        leadingFileBanner: String? = nil,
        baseWorkspaceFiles: [String: String] = [:],
        leftWorkspaceFiles: [String: String] = [:],
        rightWorkspaceFiles: [String: String] = [:]
    ) -> BatchConflictResolutionSessionReport {
        var updatedChunks: [SemanticMergeChunk] = []
        var outcomes: [ChunkResolutionOutcome] = []
        var undoStack: [RelayUndoMutation] = []
        var newlyResolvedCount = 0

        for chunk in report.chunks {
            if chunk.resolution.isConflict {
                let outcome = resolveSingleChunk(
                    chunk,
                    language: report.language,
                    filePath: report.relativePath,
                    leftLaneID: report.leftLaneID,
                    rightLaneID: report.rightLaneID,
                    strategy: strategy,
                    options: options,
                    laneEvidence: laneEvidence
                )
                updatedChunks.append(outcome.updatedChunk)
                outcomes.append(outcome)
                if outcome.updatedChunk.resolvedSource != chunk.resolvedSource {
                    undoStack.append(outcome.undoMutation)
                }
                if !outcome.updatedChunk.resolution.isConflict {
                    newlyResolvedCount += 1
                }
            } else {
                updatedChunks.append(chunk)
            }
        }

        let referenceSources = updatedChunks.compactMap(\.baseSource)
            + updatedChunks.compactMap(\.leftSource)
            + updatedChunks.compactMap(\.rightSource)
        let emitted = sourceEmitter.emitMergedDocument(
            chunks: updatedChunks,
            language: report.language,
            leadingFileBanner: leadingFileBanner,
            referenceSources: referenceSources,
            indentationPreference: options.indentationPreference
        )

        var callSiteDiags: [CallSiteArityDiagnostic] = []
        var collisions = report.crossFileCollisions

        if !baseWorkspaceFiles.isEmpty && (!leftWorkspaceFiles.isEmpty || !rightWorkspaceFiles.isEmpty) {
            var effectiveLeft = leftWorkspaceFiles
            var effectiveRight = rightWorkspaceFiles
            // Reflect the newly resolved file text in the active merge target before cross-file arity check
            if !emitted.formattedSource.isEmpty && updatedChunks.allSatisfy({ !$0.resolution.isConflict }) {
                if effectiveLeft[report.relativePath] != nil {
                    effectiveLeft[report.relativePath] = emitted.formattedSource
                }
                if effectiveRight[report.relativePath] != nil {
                    effectiveRight[report.relativePath] = emitted.formattedSource
                }
            }
            callSiteDiags = callSiteDetector.detectBrokenCallSites(
                baseFiles: baseWorkspaceFiles,
                leftLaneID: report.leftLaneID,
                leftFiles: effectiveLeft,
                rightLaneID: report.rightLaneID,
                rightFiles: effectiveRight
            )
            collisions = callSiteDiags.map { $0.asCrossFileSignatureCollision() }
        }

        let updatedReport = rebuildMergeReport(
            from: report,
            updatedChunks: updatedChunks,
            mergedText: emitted.formattedSource,
            crossFileCollisions: collisions
        )

        return BatchConflictResolutionSessionReport(
            updatedMergeReport: updatedReport,
            emittedDocument: emitted,
            chunkOutcomes: outcomes,
            undoMutations: undoStack,
            callSiteDiagnostics: callSiteDiags,
            resolvedChunkCount: newlyResolvedCount,
            remainingConflictCount: updatedReport.unresolvedConflictCount
        )
    }

    /// Applies or reverts a `.resolveMergeChunk` undo/redo mutation onto a `ThreeWaySemanticMergeReport`.
    public func applyUndoMutation(
        _ mutation: RelayUndoMutation,
        to report: ThreeWaySemanticMergeReport,
        indentationPreference: IndentationStylePreference = .autoDetect
    ) -> ThreeWaySemanticMergeReport {
        guard case let .resolveMergeChunk(filePath, chunkID, _, updatedSource) = mutation,
              filePath == report.relativePath,
              let idx = report.chunks.firstIndex(where: { $0.id == chunkID }) else {
            return report
        }

        let target = report.chunks[idx]
        let containsConflictMarkers = updatedSource.contains("<<<<<<< ") && updatedSource.contains(">>>>>>> ")
        let inferredResolution: SemanticMergeResolution
        if containsConflictMarkers {
            inferredResolution = (target.leftSource == nil || target.rightSource == nil)
                ? .conflictDeleteModify
                : .conflictBothModifiedSameSymbol
        } else if updatedSource == target.leftSource {
            inferredResolution = .leftModifiedOnly
        } else if updatedSource == target.rightSource {
            inferredResolution = .rightModifiedOnly
        } else if updatedSource.isEmpty && target.leftSource == nil {
            inferredResolution = .leftDeletedDeclaration
        } else if updatedSource.isEmpty && target.rightSource == nil {
            inferredResolution = .rightDeletedDeclaration
        } else {
            inferredResolution = .autoMergedNestedMembers
        }

        var updatedChunks = report.chunks
        updatedChunks[idx] = SemanticMergeChunk(
            id: target.id,
            qualifiedKey: target.qualifiedKey,
            symbolName: target.symbolName,
            kind: target.kind,
            resolution: inferredResolution,
            baseSource: target.baseSource,
            leftSource: target.leftSource,
            rightSource: target.rightSource,
            resolvedSource: updatedSource,
            leftVendor: target.leftVendor,
            rightVendor: target.rightVendor,
            explanation: target.explanation
        )

        let emitted = sourceEmitter.emitMergedDocument(
            chunks: updatedChunks,
            language: report.language,
            indentationPreference: indentationPreference
        )
        return rebuildMergeReport(
            from: report,
            updatedChunks: updatedChunks,
            mergedText: emitted.formattedSource,
            crossFileCollisions: report.crossFileCollisions
        )
    }

    // MARK: - Strategy Dispatch & AST Resolution Implementations

    private struct StrategyComputationResult {
        let resolution: SemanticMergeResolution
        let resolvedSource: String
        let explanation: String
        let verificationSelection: VerifiedLaneSelectionOutcome?
        let notes: [String]
    }

    private func computeStrategyResolution(
        chunk: SemanticMergeChunk,
        language: SourceLanguage,
        leftLaneID: String,
        rightLaneID: String,
        strategy: ConflictResolutionStrategy,
        options: ConflictResolutionOptions,
        profile: DetectedIndentationProfile,
        laneEvidence: [String: LaneVerificationEvidence]
    ) -> StrategyComputationResult {
        switch strategy {
        case .acceptLeft:
            return applyAcceptLeft(chunk: chunk, leftLaneID: leftLaneID, profile: profile)

        case .acceptRight:
            return applyAcceptRight(chunk: chunk, rightLaneID: rightLaneID, profile: profile)

        case .acceptBothOrdered:
            return applyAcceptBothOrdered(
                chunk: chunk,
                language: language,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                options: options,
                profile: profile
            )

        case .interleaveMembersByName:
            return applyInterleaveMembersByName(
                chunk: chunk,
                language: language,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                options: options,
                profile: profile
            )

        case .preferVerifiedTestPassingLane:
            return applyPreferVerifiedTestPassingLane(
                chunk: chunk,
                language: language,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                options: options,
                profile: profile,
                laneEvidence: laneEvidence
            )
        }
    }

    private func applyAcceptLeft(
        chunk: SemanticMergeChunk,
        leftLaneID: String,
        profile: DetectedIndentationProfile
    ) -> StrategyComputationResult {
        if let leftSrc = chunk.leftSource {
            let formatted = sourceEmitter.formatMemberBlock(
                leadingTrivia: "",
                declarationSource: leftSrc,
                indentDepth: 0,
                profile: profile
            )
            return StrategyComputationResult(
                resolution: chunk.baseSource == nil ? .leftAddedDeclaration : .leftModifiedOnly,
                resolvedSource: formatted,
                explanation: "Accepted Left lane (\(leftLaneID)) version of '\(chunk.symbolName)'.",
                verificationSelection: nil,
                notes: ["Selected Left lane (\(leftLaneID)) source verbatim with preserved doc-comments."]
            )
        } else {
            return StrategyComputationResult(
                resolution: .leftDeletedDeclaration,
                resolvedSource: "",
                explanation: "Accepted Left lane (\(leftLaneID)) deletion of '\(chunk.symbolName)'.",
                verificationSelection: nil,
                notes: ["Honored Left lane (\(leftLaneID)) declaration deletion."]
            )
        }
    }

    private func applyAcceptRight(
        chunk: SemanticMergeChunk,
        rightLaneID: String,
        profile: DetectedIndentationProfile
    ) -> StrategyComputationResult {
        if let rightSrc = chunk.rightSource {
            let formatted = sourceEmitter.formatMemberBlock(
                leadingTrivia: "",
                declarationSource: rightSrc,
                indentDepth: 0,
                profile: profile
            )
            return StrategyComputationResult(
                resolution: chunk.baseSource == nil ? .rightAddedDeclaration : .rightModifiedOnly,
                resolvedSource: formatted,
                explanation: "Accepted Right lane (\(rightLaneID)) version of '\(chunk.symbolName)'.",
                verificationSelection: nil,
                notes: ["Selected Right lane (\(rightLaneID)) source verbatim with preserved doc-comments."]
            )
        } else {
            return StrategyComputationResult(
                resolution: .rightDeletedDeclaration,
                resolvedSource: "",
                explanation: "Accepted Right lane (\(rightLaneID)) deletion of '\(chunk.symbolName)'.",
                verificationSelection: nil,
                notes: ["Honored Right lane (\(rightLaneID)) declaration deletion."]
            )
        }
    }

    private func applyAcceptBothOrdered(
        chunk: SemanticMergeChunk,
        language: SourceLanguage,
        leftLaneID: String,
        rightLaneID: String,
        options: ConflictResolutionOptions,
        profile: DetectedIndentationProfile
    ) -> StrategyComputationResult {
        let leftRaw = chunk.leftSource?.trimmingCharacters(in: .newlines) ?? ""
        let rightRaw = chunk.rightSource?.trimmingCharacters(in: .newlines) ?? ""

        if leftRaw.isEmpty && rightRaw.isEmpty {
            return StrategyComputationResult(
                resolution: .leftDeletedDeclaration,
                resolvedSource: "",
                explanation: "Both lanes removed '\(chunk.symbolName)'.",
                verificationSelection: nil,
                notes: ["Both Left and Right sources were empty."]
            )
        }
        if leftRaw.isEmpty {
            return applyAcceptRight(chunk: chunk, rightLaneID: rightLaneID, profile: profile)
        }
        if rightRaw.isEmpty {
            return applyAcceptLeft(chunk: chunk, leftLaneID: leftLaneID, profile: profile)
        }

        // Import groups combine cleanly with ordered deduplication
        if chunk.kind == .importGroup {
            let orderedSources = options.orderingPreference == .leftThenRight ? [leftRaw, rightRaw] : [rightRaw, leftRaw]
            var seen = Set<String>()
            var combinedImports: [String] = []
            for block in orderedSources {
                for line in block.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                        combinedImports.append(trimmed)
                    }
                }
            }
            return StrategyComputationResult(
                resolution: .autoMergedImportSetUnion,
                resolvedSource: combinedImports.joined(separator: "\n"),
                explanation: "Combined imports from \(leftLaneID) and \(rightLaneID) (\(options.orderingPreference.rawValue)).",
                verificationSelection: nil,
                notes: ["Deduplicated \(combinedImports.count) import directives in requested order."]
            )
        }

        // Check if structurally identical when normalized
        if options.deduplicateIdenticalStatements &&
            MultiLanguageDeclarationParser.structuralFingerprint(of: leftRaw) ==
            MultiLanguageDeclarationParser.structuralFingerprint(of: rightRaw) {
            let preferred = options.orderingPreference == .leftThenRight ? leftRaw : rightRaw
            let formatted = sourceEmitter.formatMemberBlock(
                leadingTrivia: "",
                declarationSource: preferred,
                indentDepth: 0,
                profile: profile
            )
            return StrategyComputationResult(
                resolution: .autoMergedIdenticalChange,
                resolvedSource: formatted,
                explanation: "Deduplicated structurally identical implementations of '\(chunk.symbolName)'.",
                verificationSelection: nil,
                notes: ["Left and Right blocks shared identical normalized structural fingerprint."]
            )
        }

        let firstBlock = options.orderingPreference == .leftThenRight ? leftRaw : rightRaw
        let secondBlock = options.orderingPreference == .leftThenRight ? rightRaw : leftRaw
        let firstFormatted = sourceEmitter.formatMemberBlock(
            leadingTrivia: "",
            declarationSource: firstBlock,
            indentDepth: 0,
            profile: profile
        )
        let secondFormatted = sourceEmitter.formatMemberBlock(
            leadingTrivia: "",
            declarationSource: secondBlock,
            indentDepth: 0,
            profile: profile
        )

        let separator = (language == .python && (chunk.kind == .functionDecl || chunk.kind == .classDecl)) ? "\n\n\n" : "\n\n"
        let merged = firstFormatted + separator + secondFormatted
        let orderLabel = options.orderingPreference == .leftThenRight
            ? "\(leftLaneID) -> \(rightLaneID)"
            : "\(rightLaneID) -> \(leftLaneID)"

        return StrategyComputationResult(
            resolution: .autoMergedNestedMembers,
            resolvedSource: merged,
            explanation: "Retained both declarations for '\(chunk.symbolName)' ordered (\(orderLabel)).",
            verificationSelection: nil,
            notes: ["Emitted both declarations sequentially (\(orderLabel))."]
        )
    }

    private func applyInterleaveMembersByName(
        chunk: SemanticMergeChunk,
        language: SourceLanguage,
        leftLaneID: String,
        rightLaneID: String,
        options: ConflictResolutionOptions,
        profile: DetectedIndentationProfile
    ) -> StrategyComputationResult {
        guard let leftSrc = chunk.leftSource, !leftSrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rightSrc = chunk.rightSource, !rightSrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return applyAcceptBothOrdered(
                chunk: chunk,
                language: language,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                options: options,
                profile: profile
            )
        }

        if language == .python && chunk.kind == .classDecl {
            if let pythonMerged = interleavePythonClassMembers(
                baseSource: chunk.baseSource,
                leftSource: leftSrc,
                rightSource: rightSrc,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                options: options,
                profile: profile
            ) {
                return pythonMerged
            }
        }

        let isContainerKind: Bool
        switch chunk.kind {
        case .structDecl, .classDecl, .enumDecl, .protocolOrInterface, .extensionOrImpl:
            isContainerKind = true
        default:
            isContainerKind = false
        }

        if isContainerKind, language != .python {
            if let containerMerged = interleaveBraceContainerMembers(
                baseSource: chunk.baseSource,
                leftSource: leftSrc,
                rightSource: rightSrc,
                language: language,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                options: options,
                profile: profile
            ) {
                return containerMerged
            }
        }

        // Non-container fallback: parse multiple declarations in chunk and interleave by symbolName
        let leftNodes = parser.parseDeclarations(source: leftSrc, language: language)
        let rightNodes = parser.parseDeclarations(source: rightSrc, language: language)
        if leftNodes.count > 1 || rightNodes.count > 1 {
            let (blocks, hadInnerConflict, notes) = mergeAndSortDeclarationListsByName(
                baseNodes: chunk.baseSource.map { parser.parseDeclarations(source: $0, language: language) } ?? [],
                leftNodes: leftNodes,
                rightNodes: rightNodes,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                tieBreaker: options.memberTieBreaker,
                indentDepth: 0,
                profile: profile
            )
            let joined = blocks.joined(separator: "\n\n")
            return StrategyComputationResult(
                resolution: hadInnerConflict ? .conflictBothModifiedSameSymbol : .autoMergedNestedMembers,
                resolvedSource: joined,
                explanation: "Interleaved \(blocks.count) declarations in '\(chunk.symbolName)' alphabetically by name.",
                verificationSelection: nil,
                notes: notes
            )
        }

        // Single leaf declaration with identical name: apply configured tie-breaker
        switch options.memberTieBreaker {
        case .preferLeft:
            return applyAcceptLeft(chunk: chunk, leftLaneID: leftLaneID, profile: profile)
        case .preferRight:
            return applyAcceptRight(chunk: chunk, rightLaneID: rightLaneID, profile: profile)
        case .keepBothSuffixed:
            let suffixedRight = suffixDeclarationSymbolName(
                in: rightSrc,
                symbolName: chunk.symbolName,
                suffix: "_\(sanitizeIdentifierSuffix(rightLaneID))"
            )
            let leftFormatted = sourceEmitter.formatMemberBlock(
                leadingTrivia: "",
                declarationSource: leftSrc,
                indentDepth: 0,
                profile: profile
            )
            let rightFormatted = sourceEmitter.formatMemberBlock(
                leadingTrivia: "",
                declarationSource: suffixedRight,
                indentDepth: 0,
                profile: profile
            )
            return StrategyComputationResult(
                resolution: .autoMergedNestedMembers,
                resolvedSource: leftFormatted + "\n\n" + rightFormatted,
                explanation: "Retained both leaf declarations of '\(chunk.symbolName)' with lane-disambiguated suffix.",
                verificationSelection: nil,
                notes: ["Appended lane suffix to Right declaration to prevent redeclaration error."]
            )
        case .emitInnerConflictMarkers:
            return StrategyComputationResult(
                resolution: chunk.resolution,
                resolvedSource: chunk.resolvedSource,
                explanation: "Leaf declaration '\(chunk.symbolName)' cannot be member-interleaved without a tie-breaker.",
                verificationSelection: nil,
                notes: ["Preserved conflict markers per .emitInnerConflictMarkers policy."]
            )
        }
    }

    private func applyPreferVerifiedTestPassingLane(
        chunk: SemanticMergeChunk,
        language: SourceLanguage,
        leftLaneID: String,
        rightLaneID: String,
        options: ConflictResolutionOptions,
        profile: DetectedIndentationProfile,
        laneEvidence: [String: LaneVerificationEvidence]
    ) -> StrategyComputationResult {
        let selection = evaluateVerifiedLanePreference(
            leftLaneID: leftLaneID,
            rightLaneID: rightLaneID,
            laneEvidence: laneEvidence,
            fallback: options.fallbackStrategyWhenVerificationTied
        )

        if selection.winningLaneID == leftLaneID {
            let baseRes = applyAcceptLeft(chunk: chunk, leftLaneID: leftLaneID, profile: profile)
            return StrategyComputationResult(
                resolution: baseRes.resolution,
                resolvedSource: baseRes.resolvedSource,
                explanation: "\(selection.rationale) -> Accepted \(leftLaneID).",
                verificationSelection: selection,
                notes: baseRes.notes + [selection.rationale]
            )
        }

        if selection.winningLaneID == rightLaneID {
            let baseRes = applyAcceptRight(chunk: chunk, rightLaneID: rightLaneID, profile: profile)
            return StrategyComputationResult(
                resolution: baseRes.resolution,
                resolvedSource: baseRes.resolvedSource,
                explanation: "\(selection.rationale) -> Accepted \(rightLaneID).",
                verificationSelection: selection,
                notes: baseRes.notes + [selection.rationale]
            )
        }

        // Check if non-lane-specific fallback (e.g. `.interleaveMembersByName` or `.acceptBothOrdered`) was configured
        if let fallback = options.fallbackStrategyWhenVerificationTied,
           fallback != .preferVerifiedTestPassingLane {
            let fallbackRes = computeStrategyResolution(
                chunk: chunk,
                language: language,
                leftLaneID: leftLaneID,
                rightLaneID: rightLaneID,
                strategy: fallback,
                options: options,
                profile: profile,
                laneEvidence: laneEvidence
            )
            return StrategyComputationResult(
                resolution: fallbackRes.resolution,
                resolvedSource: fallbackRes.resolvedSource,
                explanation: "\(selection.rationale) Applied fallback '\(fallback.rawValue)'.",
                verificationSelection: selection,
                notes: [selection.rationale] + fallbackRes.notes
            )
        }

        return StrategyComputationResult(
            resolution: chunk.resolution,
            resolvedSource: chunk.resolvedSource,
            explanation: selection.rationale,
            verificationSelection: selection,
            notes: [selection.rationale]
        )
    }

    public func evaluateVerifiedLanePreference(
        leftLaneID: String,
        rightLaneID: String,
        laneEvidence: [String: LaneVerificationEvidence],
        fallback: ConflictResolutionStrategy? = nil
    ) -> VerifiedLaneSelectionOutcome {
        let leftEv = laneEvidence[leftLaneID]
        let rightEv = laneEvidence[rightLaneID]

        switch (leftEv, rightEv) {
        case (let .some(l), let .some(r)):
            if l.isVerifiedGreen && !r.isVerifiedGreen {
                return VerifiedLaneSelectionOutcome(
                    decision: .selectedLeftVerifiedGreen,
                    winningLaneID: leftLaneID,
                    leftScore: l.qualityScore,
                    rightScore: r.qualityScore,
                    rationale: "Lane '\(leftLaneID)' passed verification (\(l.passedTestCount) tests green, exit 0) while '\(rightLaneID)' failed (exit \(r.exitCode), \(r.failedTestCount) failed tests, \(r.compilerErrorCount) errors)."
                )
            }
            if !l.isVerifiedGreen && r.isVerifiedGreen {
                return VerifiedLaneSelectionOutcome(
                    decision: .selectedRightVerifiedGreen,
                    winningLaneID: rightLaneID,
                    leftScore: l.qualityScore,
                    rightScore: r.qualityScore,
                    rationale: "Lane '\(rightLaneID)' passed verification (\(r.passedTestCount) tests green, exit 0) while '\(leftLaneID)' failed (exit \(l.exitCode), \(l.failedTestCount) failed tests, \(l.compilerErrorCount) errors)."
                )
            }
            if l.isVerifiedGreen && r.isVerifiedGreen {
                if abs(l.qualityScore - r.qualityScore) > 0.001 {
                    let winner = l.qualityScore > r.qualityScore ? leftLaneID : rightLaneID
                    return VerifiedLaneSelectionOutcome(
                        decision: .selectedHigherQualityGreenLane,
                        winningLaneID: winner,
                        leftScore: l.qualityScore,
                        rightScore: r.qualityScore,
                        rationale: "Both lanes passed tests; selected '\(winner)' by higher quality score (\(String(format: "%.1f", max(l.qualityScore, r.qualityScore))) vs \(String(format: "%.1f", min(l.qualityScore, r.qualityScore))))."
                    )
                }
                if fallback == .acceptLeft {
                    return VerifiedLaneSelectionOutcome(
                        decision: .appliedConfiguredFallback,
                        winningLaneID: leftLaneID,
                        leftScore: l.qualityScore,
                        rightScore: r.qualityScore,
                        rationale: "Both lanes passed verification with identical score (\(String(format: "%.1f", l.qualityScore))); applied fallback acceptLeft."
                    )
                }
                if fallback == .acceptRight {
                    return VerifiedLaneSelectionOutcome(
                        decision: .appliedConfiguredFallback,
                        winningLaneID: rightLaneID,
                        leftScore: l.qualityScore,
                        rightScore: r.qualityScore,
                        rationale: "Both lanes passed verification with identical score (\(String(format: "%.1f", r.qualityScore))); applied fallback acceptRight."
                    )
                }
                return VerifiedLaneSelectionOutcome(
                    decision: .unresolvedExactVerificationTie,
                    winningLaneID: nil,
                    leftScore: l.qualityScore,
                    rightScore: r.qualityScore,
                    rationale: "Both '\(leftLaneID)' and '\(rightLaneID)' passed verification with identical score (\(String(format: "%.1f", l.qualityScore))); manual tie-break required."
                )
            }
            return VerifiedLaneSelectionOutcome(
                decision: .unresolvedBothFailedOrMissingEvidence,
                winningLaneID: nil,
                leftScore: l.qualityScore,
                rightScore: r.qualityScore,
                rationale: "Neither '\(leftLaneID)' (exit \(l.exitCode)) nor '\(rightLaneID)' (exit \(r.exitCode)) has a clean green verification run."
            )

        case (let .some(l), nil):
            if l.isVerifiedGreen {
                return VerifiedLaneSelectionOutcome(
                    decision: .selectedLeftVerifiedGreen,
                    winningLaneID: leftLaneID,
                    leftScore: l.qualityScore,
                    rightScore: nil,
                    rationale: "Lane '\(leftLaneID)' passed verification (\(l.passedTestCount) tests green); '\(rightLaneID)' has no verification run."
                )
            }
            return VerifiedLaneSelectionOutcome(
                decision: .unresolvedBothFailedOrMissingEvidence,
                winningLaneID: nil,
                leftScore: l.qualityScore,
                rightScore: nil,
                rationale: "Lane '\(leftLaneID)' failed verification and '\(rightLaneID)' has no verification evidence."
            )

        case (nil, let .some(r)):
            if r.isVerifiedGreen {
                return VerifiedLaneSelectionOutcome(
                    decision: .selectedRightVerifiedGreen,
                    winningLaneID: rightLaneID,
                    leftScore: nil,
                    rightScore: r.qualityScore,
                    rationale: "Lane '\(rightLaneID)' passed verification (\(r.passedTestCount) tests green); '\(leftLaneID)' has no verification run."
                )
            }
            return VerifiedLaneSelectionOutcome(
                decision: .unresolvedBothFailedOrMissingEvidence,
                winningLaneID: nil,
                leftScore: nil,
                rightScore: r.qualityScore,
                rationale: "Lane '\(rightLaneID)' failed verification and '\(leftLaneID)' has no verification evidence."
            )

        case (nil, nil):
            return VerifiedLaneSelectionOutcome(
                decision: .unresolvedBothFailedOrMissingEvidence,
                winningLaneID: nil,
                leftScore: nil,
                rightScore: nil,
                rationale: "No test verification evidence recorded for either '\(leftLaneID)' or '\(rightLaneID)'."
            )
        }
    }

    // MARK: - Container Member Interleaving Helpers (Brace Languages & Python)

    private func interleaveBraceContainerMembers(
        baseSource: String?,
        leftSource: String,
        rightSource: String,
        language: SourceLanguage,
        leftLaneID: String,
        rightLaneID: String,
        options: ConflictResolutionOptions,
        profile: DetectedIndentationProfile
    ) -> StrategyComputationResult? {
        let baseNode = baseSource.flatMap { parser.parseDeclarations(source: $0, language: language).first }
        guard let leftNode = parser.parseDeclarations(source: leftSource, language: language).first,
              let rightNode = parser.parseDeclarations(source: rightSource, language: language).first,
              !leftNode.children.isEmpty || !rightNode.children.isEmpty else {
            return nil
        }

        let mergedTrivia = mergeContainerLeadingTrivia(
            baseTrivia: baseNode?.leadingTrivia,
            leftTrivia: leftNode.leadingTrivia,
            rightTrivia: rightNode.leadingTrivia
        )

        let baseHeader = baseNode.map { extractContainerHeaderBeforeBrace($0.declarationSource) }
        let leftHeader = extractContainerHeaderBeforeBrace(leftNode.declarationSource)
        let rightHeader = extractContainerHeaderBeforeBrace(rightNode.declarationSource)
        let reconciledHeader = reconcileContainerHeaders(
            baseHeader: baseHeader,
            leftHeader: leftHeader,
            rightHeader: rightHeader,
            language: language,
            mergeConformances: options.mergeCompatibleTypeConformances,
            tieBreaker: options.memberTieBreaker
        )

        let (memberBlocks, hadInnerConflict, notes) = mergeAndSortDeclarationListsByName(
            baseNodes: baseNode?.children ?? [],
            leftNodes: leftNode.children,
            rightNodes: rightNode.children,
            leftLaneID: leftLaneID,
            rightLaneID: rightLaneID,
            tieBreaker: options.memberTieBreaker,
            indentDepth: 1,
            profile: profile
        )

        let innerJoined = memberBlocks.joined(separator: "\n\n")
        let fullContainer: String
        if innerJoined.isEmpty {
            fullContainer = "\(mergedTrivia)\(reconciledHeader) {}"
        } else {
            fullContainer = "\(mergedTrivia)\(reconciledHeader) {\n\(innerJoined)\n}"
        }

        return StrategyComputationResult(
            resolution: hadInnerConflict ? .conflictBothModifiedSameSymbol : .autoMergedNestedMembers,
            resolvedSource: fullContainer,
            explanation: "Interleaved \(memberBlocks.count) member(s) inside \(leftNode.kind.rawValue) '\(leftNode.symbolName)' sorted by member kind and name.",
            verificationSelection: nil,
            notes: notes
        )
    }

    private func interleavePythonClassMembers(
        baseSource: String?,
        leftSource: String,
        rightSource: String,
        leftLaneID: String,
        rightLaneID: String,
        options: ConflictResolutionOptions,
        profile: DetectedIndentationProfile
    ) -> StrategyComputationResult? {
        guard let (leftHeader, leftBodyDeindented) = splitPythonClassHeaderAndBody(leftSource),
              let (rightHeader, rightBodyDeindented) = splitPythonClassHeaderAndBody(rightSource) else {
            return nil
        }
        let baseParsed = baseSource.flatMap { splitPythonClassHeaderAndBody($0) }

        let baseMembers = baseParsed.map { parser.parseDeclarations(source: $0.body, language: .python) } ?? []
        let leftMembers = parser.parseDeclarations(source: leftBodyDeindented, language: .python)
        let rightMembers = parser.parseDeclarations(source: rightBodyDeindented, language: .python)
        guard !leftMembers.isEmpty || !rightMembers.isEmpty else { return nil }

        let chosenHeader: String
        if let bH = baseParsed?.header, leftHeader == bH && rightHeader != bH {
            chosenHeader = rightHeader
        } else {
            chosenHeader = leftHeader
        }

        let (memberBlocks, hadInnerConflict, notes) = mergeAndSortDeclarationListsByName(
            baseNodes: baseMembers,
            leftNodes: leftMembers,
            rightNodes: rightMembers,
            leftLaneID: leftLaneID,
            rightLaneID: rightLaneID,
            tieBreaker: options.memberTieBreaker,
            indentDepth: 1,
            profile: profile
        )

        let bodyText = memberBlocks.isEmpty
            ? "\(profile.indentUnitString)pass"
            : memberBlocks.joined(separator: "\n\n")
        let fullClass = "\(chosenHeader)\n\(bodyText)"

        return StrategyComputationResult(
            resolution: hadInnerConflict ? .conflictBothModifiedSameSymbol : .autoMergedNestedMembers,
            resolvedSource: fullClass,
            explanation: "Interleaved \(memberBlocks.count) Python method/attribute member(s) by name.",
            verificationSelection: nil,
            notes: notes
        )
    }

    private func splitPythonClassHeaderAndBody(_ source: String) -> (header: String, body: String)? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let classLineIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("class ") }) else {
            return nil
        }
        let headerLines = Array(lines[...classLineIdx])
        let bodyRaw = Array(lines[(classLineIdx + 1)...])
        guard !bodyRaw.isEmpty else { return nil }

        // De-indent body by one minimal indentation level so top-level Python parser extracts methods cleanly
        var minSpaces: Int?
        for line in bodyRaw {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var sp = 0
            for c in line {
                if c == " " { sp += 1 }
                else if c == "\t" { sp += 4 }
                else { break }
            }
            minSpaces = minSpaces.map { min($0, sp) } ?? sp
        }
        let dropCols = minSpaces ?? 4
        let deindented = bodyRaw.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "" }
            var dropped = 0
            var idx = line.startIndex
            while idx < line.endIndex && dropped < dropCols {
                if line[idx] == " " { dropped += 1; idx = line.index(after: idx) }
                else if line[idx] == "\t" { dropped += 4; idx = line.index(after: idx) }
                else { break }
            }
            return String(line[idx...])
        }.joined(separator: "\n")

        return (headerLines.joined(separator: "\n"), deindented)
    }

    private func mergeAndSortDeclarationListsByName(
        baseNodes: [ASTDeclarationNode],
        leftNodes: [ASTDeclarationNode],
        rightNodes: [ASTDeclarationNode],
        leftLaneID: String,
        rightLaneID: String,
        tieBreaker: MemberCollisionTieBreaker,
        indentDepth: Int,
        profile: DetectedIndentationProfile
    ) -> (blocks: [String], hadInnerConflict: Bool, notes: [String]) {
        var baseMap: [String: ASTDeclarationNode] = [:]
        for n in baseNodes { baseMap[memberIdentityKey(n)] = n }
        var leftMap: [String: ASTDeclarationNode] = [:]
        for n in leftNodes { leftMap[memberIdentityKey(n)] = n }
        var rightMap: [String: ASTDeclarationNode] = [:]
        for n in rightNodes { rightMap[memberIdentityKey(n)] = n }

        let allKeys = Set(baseMap.keys).union(leftMap.keys).union(rightMap.keys)

        struct ResolvedMemberEntry {
            let sortCategory: Int
            let symbolName: String
            let tieKey: String
            let formattedText: String
        }

        var entries: [ResolvedMemberEntry] = []
        var notes: [String] = []
        var hadInnerConflict = false

        for key in allKeys {
            let b = baseMap[key]
            let l = leftMap[key]
            let r = rightMap[key]
            guard let sample = l ?? r ?? b else { continue }
            let catRank = memberSortCategoryRank(sample)

            switch (b, l, r) {
            case (nil, let .some(lv), nil):
                entries.append(ResolvedMemberEntry(
                    sortCategory: catRank,
                    symbolName: lv.symbolName,
                    tieKey: key,
                    formattedText: sourceEmitter.formatMemberBlock(
                        leadingTrivia: lv.leadingTrivia,
                        declarationSource: lv.declarationSource,
                        indentDepth: indentDepth,
                        profile: profile
                    )
                ))
            case (nil, nil, let .some(rv)):
                entries.append(ResolvedMemberEntry(
                    sortCategory: catRank,
                    symbolName: rv.symbolName,
                    tieKey: key,
                    formattedText: sourceEmitter.formatMemberBlock(
                        leadingTrivia: rv.leadingTrivia,
                        declarationSource: rv.declarationSource,
                        indentDepth: indentDepth,
                        profile: profile
                    )
                ))
            case (nil, let .some(lv), let .some(rv)):
                if lv.structuralFingerprint == rv.structuralFingerprint {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: lv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: lv.leadingTrivia.isEmpty ? rv.leadingTrivia : lv.leadingTrivia,
                            declarationSource: lv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                } else {
                    let resolved = resolveCollidingMemberPair(
                        left: lv,
                        right: rv,
                        leftLaneID: leftLaneID,
                        rightLaneID: rightLaneID,
                        tieBreaker: tieBreaker,
                        indentDepth: indentDepth,
                        profile: profile
                    )
                    if resolved.isConflict { hadInnerConflict = true }
                    notes.append(resolved.note)
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: lv.symbolName,
                        tieKey: key,
                        formattedText: resolved.formatted
                    ))
                }
            case (let .some(bv), let .some(lv), let .some(rv)):
                let lChanged = lv.structuralFingerprint != bv.structuralFingerprint
                let rChanged = rv.structuralFingerprint != bv.structuralFingerprint
                if !lChanged && !rChanged {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: bv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: bv.leadingTrivia,
                            declarationSource: bv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                } else if lChanged && !rChanged {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: lv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: lv.leadingTrivia,
                            declarationSource: lv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                } else if !lChanged && rChanged {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: rv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: rv.leadingTrivia,
                            declarationSource: rv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                } else if lv.structuralFingerprint == rv.structuralFingerprint {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: lv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: lv.leadingTrivia,
                            declarationSource: lv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                } else {
                    let resolved = resolveCollidingMemberPair(
                        left: lv,
                        right: rv,
                        leftLaneID: leftLaneID,
                        rightLaneID: rightLaneID,
                        tieBreaker: tieBreaker,
                        indentDepth: indentDepth,
                        profile: profile
                    )
                    if resolved.isConflict { hadInnerConflict = true }
                    notes.append(resolved.note)
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: lv.symbolName,
                        tieKey: key,
                        formattedText: resolved.formatted
                    ))
                }
            case (let .some(bv), nil, let .some(rv)):
                if rv.structuralFingerprint != bv.structuralFingerprint && tieBreaker != .preferLeft {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: rv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: rv.leadingTrivia,
                            declarationSource: rv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                }
            case (let .some(bv), let .some(lv), nil):
                if lv.structuralFingerprint != bv.structuralFingerprint && tieBreaker != .preferRight {
                    entries.append(ResolvedMemberEntry(
                        sortCategory: catRank,
                        symbolName: lv.symbolName,
                        tieKey: key,
                        formattedText: sourceEmitter.formatMemberBlock(
                            leadingTrivia: lv.leadingTrivia,
                            declarationSource: lv.declarationSource,
                            indentDepth: indentDepth,
                            profile: profile
                        )
                    ))
                }
            default:
                break
            }
        }

        entries.sort { lhs, rhs in
            if lhs.sortCategory != rhs.sortCategory {
                return lhs.sortCategory < rhs.sortCategory
            }
            let cmp = lhs.symbolName.localizedStandardCompare(rhs.symbolName)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.tieKey < rhs.tieKey
        }

        notes.append("Sorted \(entries.count) member declaration(s) deterministically by category and name.")
        return (entries.map(\.formattedText), hadInnerConflict, notes)
    }

    private func resolveCollidingMemberPair(
        left: ASTDeclarationNode,
        right: ASTDeclarationNode,
        leftLaneID: String,
        rightLaneID: String,
        tieBreaker: MemberCollisionTieBreaker,
        indentDepth: Int,
        profile: DetectedIndentationProfile
    ) -> (formatted: String, isConflict: Bool, note: String) {
        switch tieBreaker {
        case .preferLeft:
            let fmt = sourceEmitter.formatMemberBlock(
                leadingTrivia: left.leadingTrivia.isEmpty ? right.leadingTrivia : left.leadingTrivia,
                declarationSource: left.declarationSource,
                indentDepth: indentDepth,
                profile: profile
            )
            return (fmt, false, "Member '\(left.symbolName)' diverged in both lanes; selected \(leftLaneID) per preferLeft.")

        case .preferRight:
            let fmt = sourceEmitter.formatMemberBlock(
                leadingTrivia: right.leadingTrivia.isEmpty ? left.leadingTrivia : right.leadingTrivia,
                declarationSource: right.declarationSource,
                indentDepth: indentDepth,
                profile: profile
            )
            return (fmt, false, "Member '\(right.symbolName)' diverged in both lanes; selected \(rightLaneID) per preferRight.")

        case .keepBothSuffixed:
            let leftFmt = sourceEmitter.formatMemberBlock(
                leadingTrivia: left.leadingTrivia,
                declarationSource: left.declarationSource,
                indentDepth: indentDepth,
                profile: profile
            )
            let suffixedSrc = suffixDeclarationSymbolName(
                in: right.declarationSource,
                symbolName: right.symbolName,
                suffix: "_\(sanitizeIdentifierSuffix(rightLaneID))"
            )
            let rightFmt = sourceEmitter.formatMemberBlock(
                leadingTrivia: right.leadingTrivia,
                declarationSource: suffixedSrc,
                indentDepth: indentDepth,
                profile: profile
            )
            return (leftFmt + "\n\n" + rightFmt, false, "Retained both colliding members for '\(left.symbolName)' using lane suffix.")

        case .emitInnerConflictMarkers:
            let leftFmt = sourceEmitter.formatMemberBlock(
                leadingTrivia: left.leadingTrivia,
                declarationSource: left.declarationSource,
                indentDepth: indentDepth,
                profile: profile
            )
            let rightFmt = sourceEmitter.formatMemberBlock(
                leadingTrivia: right.leadingTrivia,
                declarationSource: right.declarationSource,
                indentDepth: indentDepth,
                profile: profile
            )
            let marker = """
            <<<<<<< \(leftLaneID)
            \(leftFmt)
            =======
            \(rightFmt)
            >>>>>>> \(rightLaneID)
            """
            return (marker, true, "Emitted localized member conflict markers for '\(left.symbolName)'.")
        }
    }

    private func memberIdentityKey(_ node: ASTDeclarationNode) -> String {
        if node.parameterSignature.isEmpty {
            return "\(node.kind.rawValue):\(node.symbolName)"
        }
        return "\(node.kind.rawValue):\(node.symbolName):\(node.parameterSignature)"
    }

    private func memberSortCategoryRank(_ node: ASTDeclarationNode) -> Int {
        if node.symbolName == "init" || node.symbolName == "__init__" || node.symbolName == "constructor" {
            return 2
        }
        switch node.kind {
        case .importGroup, .packageOrModule: return 0
        case .typeAlias: return 1
        case .constantOrVar: return 1
        case .methodDecl, .functionDecl: return 3
        case .structDecl, .classDecl, .enumDecl, .protocolOrInterface, .extensionOrImpl: return 4
        case .topLevelBlock: return 5
        }
    }

    private func extractContainerHeaderBeforeBrace(_ source: String) -> String {
        guard let braceIdx = source.firstIndex(of: "{") else {
            return source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(source[..<braceIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeContainerLeadingTrivia(
        baseTrivia: String?,
        leftTrivia: String,
        rightTrivia: String
    ) -> String {
        let baseTrim = (baseTrivia ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let leftTrim = leftTrivia.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrim = rightTrivia.trimmingCharacters(in: .whitespacesAndNewlines)

        if leftTrim == rightTrim {
            return leftTrim.isEmpty ? "" : (leftTrim + "\n")
        }
        if leftTrim == baseTrim && !rightTrim.isEmpty {
            return rightTrim + "\n"
        }
        if rightTrim == baseTrim && !leftTrim.isEmpty {
            return leftTrim + "\n"
        }
        if leftTrim.isEmpty {
            return rightTrim.isEmpty ? "" : (rightTrim + "\n")
        }
        return leftTrim + "\n"
    }

    private func reconcileContainerHeaders(
        baseHeader: String?,
        leftHeader: String,
        rightHeader: String,
        language: SourceLanguage,
        mergeConformances: Bool,
        tieBreaker: MemberCollisionTieBreaker
    ) -> String {
        if leftHeader == rightHeader { return leftHeader }
        if let b = baseHeader {
            if leftHeader == b { return rightHeader }
            if rightHeader == b { return leftHeader }
        }

        // Union Swift/TS/Rust `: ConformanceA, ConformanceB` lists when the declaration stem matches!
        if mergeConformances && (language == .swift || language == .rust),
           let lColon = leftHeader.firstIndex(of: ":"),
           let rColon = rightHeader.firstIndex(of: ":") {
            let lStem = String(leftHeader[..<lColon]).trimmingCharacters(in: .whitespaces)
            let rStem = String(rightHeader[..<rColon]).trimmingCharacters(in: .whitespaces)
            if lStem == rStem {
                let sepChar: Character = language == .rust ? "+" : ","
                let lConfs = leftHeader[leftHeader.index(after: lColon)...]
                    .split(separator: sepChar)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let rConfs = rightHeader[rightHeader.index(after: rColon)...]
                    .split(separator: sepChar)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                var seen = Set<String>()
                var mergedConfs: [String] = []
                for c in (lConfs + rConfs) where !c.isEmpty && seen.insert(c).inserted {
                    mergedConfs.append(c)
                }
                let joiner = language == .rust ? " + " : ", "
                return "\(lStem): \(mergedConfs.joined(separator: joiner))"
            }
        }

        return tieBreaker == .preferRight ? rightHeader : leftHeader
    }

    private func suffixDeclarationSymbolName(
        in source: String,
        symbolName: String,
        suffix: String
    ) -> String {
        guard !symbolName.isEmpty,
              let range = source.range(of: "\\b\(NSRegularExpression.escapedPattern(for: symbolName))\\b", options: .regularExpression) else {
            return source
        }
        var copy = source
        copy.replaceSubrange(range, with: symbolName + suffix)
        return copy
    }

    private func sanitizeIdentifierSuffix(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        let collapsed = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "alt" : collapsed
    }

    private func rebuildMergeReport(
        from prior: ThreeWaySemanticMergeReport,
        updatedChunks: [SemanticMergeChunk],
        mergedText: String,
        crossFileCollisions: [CrossFileSignatureCollision]
    ) -> ThreeWaySemanticMergeReport {
        var autoMerged = 0
        var unresolved = 0
        for chunk in updatedChunks {
            if chunk.resolution.isConflict {
                unresolved += 1
            } else if chunk.resolution != .unchanged {
                autoMerged += 1
            }
        }
        return ThreeWaySemanticMergeReport(
            relativePath: prior.relativePath,
            language: prior.language,
            leftLaneID: prior.leftLaneID,
            rightLaneID: prior.rightLaneID,
            chunks: updatedChunks,
            mergedText: mergedText,
            autoMergedCount: autoMerged,
            unresolvedConflictCount: unresolved,
            wouldGitLineMergeConflict: prior.wouldGitLineMergeConflict,
            crossFileCollisions: crossFileCollisions
        )
    }
}
