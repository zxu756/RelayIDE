import CryptoKit
import Foundation
import JavaScriptCore
import RelayModels
import RelaySemanticMerge

// MARK: - Lifecycle Hook Kinds, Payloads & Structured Hook Trace Ring-Buffer

public enum RelayLifecycleHookKind: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case onCommandSpawn = "onCommandSpawn"
    case onFileTouch = "onFileTouch"
    case onPreMerge = "onPreMerge"
    case onWiretapRequest = "onWiretapRequest"

    public var id: String { rawValue }

    public var jsFunctionName: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .onCommandSpawn: return "PTY Command Spawn Gate"
        case .onFileTouch: return "Worktree File Touch Fence"
        case .onPreMerge: return "3-Way Pre-Merge AST Gate"
        case .onWiretapRequest: return "Outbound Wiretap Prompt Gate"
        }
    }
}

public struct RelayCommandSpawnContext: Sendable, Codable, Hashable {
    public let laneID: String
    public let vendor: AgentVendor
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String

    public init(
        laneID: String,
        vendor: AgentVendor,
        executablePath: String,
        arguments: [String],
        workingDirectory: String
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    public var commandLineString: String {
        ([executablePath] + arguments).joined(separator: " ")
    }
}

public enum RelayFileTouchOperation: String, Sendable, Codable, Hashable {
    case created = "CREATED"
    case modified = "MODIFIED"
    case deleted = "DELETED"
}

public struct RelayFileTouchContext: Sendable, Codable, Hashable {
    public let laneID: String
    public let vendor: AgentVendor
    public let relativePath: String
    public let operation: RelayFileTouchOperation
    public let byteDelta: Int
    public let allowedGlobs: [String]
    public let forbiddenGlobs: [String]

    public init(
        laneID: String,
        vendor: AgentVendor,
        relativePath: String,
        operation: RelayFileTouchOperation,
        byteDelta: Int = 0,
        allowedGlobs: [String] = ["**"],
        forbiddenGlobs: [String] = [".git/**"]
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.relativePath = relativePath
        self.operation = operation
        self.byteDelta = byteDelta
        self.allowedGlobs = allowedGlobs
        self.forbiddenGlobs = forbiddenGlobs
    }
}

public struct RelayPreMergeContext: Sendable, Codable, Hashable {
    public let relativePath: String
    public let leftLaneID: String
    public let rightLaneID: String
    public let autoMergedCount: Int
    public let unresolvedConflictCount: Int
    public let mergedSourcePreview: String

    public init(
        relativePath: String,
        leftLaneID: String,
        rightLaneID: String,
        autoMergedCount: Int,
        unresolvedConflictCount: Int,
        mergedSourcePreview: String
    ) {
        self.relativePath = relativePath
        self.leftLaneID = leftLaneID
        self.rightLaneID = rightLaneID
        self.autoMergedCount = autoMergedCount
        self.unresolvedConflictCount = unresolvedConflictCount
        self.mergedSourcePreview = mergedSourcePreview
    }
}

public struct RelayWiretapRequestContext: Sendable, Codable, Hashable {
    public let laneID: String
    public let vendor: AgentVendor
    public let providerHost: String
    public let modelIdentifier: String
    public let promptSnippet: String
    public let spentUSD: Double
    public let ceilingUSD: Double

    public init(
        laneID: String,
        vendor: AgentVendor,
        providerHost: String,
        modelIdentifier: String,
        promptSnippet: String,
        spentUSD: Double,
        ceilingUSD: Double
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.providerHost = providerHost
        self.modelIdentifier = modelIdentifier
        self.promptSnippet = promptSnippet
        self.spentUSD = spentUSD
        self.ceilingUSD = ceilingUSD
    }
}

public enum RelayLifecycleHookEvent: Sendable, Codable, Hashable {
    case commandSpawn(RelayCommandSpawnContext)
    case fileTouch(RelayFileTouchContext)
    case preMerge(RelayPreMergeContext)
    case wiretapRequest(RelayWiretapRequestContext)

    public var kind: RelayLifecycleHookKind {
        switch self {
        case .commandSpawn: return .onCommandSpawn
        case .fileTouch: return .onFileTouch
        case .preMerge: return .onPreMerge
        case .wiretapRequest: return .onWiretapRequest
        }
    }

    public var laneID: String? {
        switch self {
        case .commandSpawn(let c): return c.laneID
        case .fileTouch(let f): return f.laneID
        case .preMerge(let m): return "\(m.leftLaneID)+\(m.rightLaneID)"
        case .wiretapRequest(let w): return w.laneID
        }
    }

    public var targetSubject: String {
        switch self {
        case .commandSpawn(let c): return c.commandLineString
        case .fileTouch(let f): return f.relativePath
        case .preMerge(let m): return m.relativePath
        case .wiretapRequest(let w): return "\(w.providerHost)/\(w.modelIdentifier)"
        }
    }

    internal func toJSObjectDictionary() -> [String: Any] {
        switch self {
        case .commandSpawn(let c):
            return [
                "hook": kind.rawValue,
                "laneID": c.laneID,
                "vendor": c.vendor.rawValue,
                "executablePath": c.executablePath,
                "arguments": c.arguments,
                "commandLine": c.commandLineString,
                "workingDirectory": c.workingDirectory
            ]
        case .fileTouch(let f):
            return [
                "hook": kind.rawValue,
                "laneID": f.laneID,
                "vendor": f.vendor.rawValue,
                "relativePath": f.relativePath,
                "operation": f.operation.rawValue,
                "byteDelta": f.byteDelta,
                "allowedGlobs": f.allowedGlobs,
                "forbiddenGlobs": f.forbiddenGlobs
            ]
        case .preMerge(let m):
            return [
                "hook": kind.rawValue,
                "relativePath": m.relativePath,
                "leftLaneID": m.leftLaneID,
                "rightLaneID": m.rightLaneID,
                "autoMergedCount": m.autoMergedCount,
                "unresolvedConflictCount": m.unresolvedConflictCount,
                "mergedSourcePreview": m.mergedSourcePreview
            ]
        case .wiretapRequest(let w):
            return [
                "hook": kind.rawValue,
                "laneID": w.laneID,
                "vendor": w.vendor.rawValue,
                "providerHost": w.providerHost,
                "modelIdentifier": w.modelIdentifier,
                "promptSnippet": w.promptSnippet,
                "spentUSD": w.spentUSD,
                "ceilingUSD": w.ceilingUSD
            ]
        }
    }
}

public enum RelayHookVerdictDecision: String, Sendable, Codable, Hashable, CaseIterable {
    case allow = "ALLOW"
    case advisory = "ADVISORY"
    case warn = "WARN"
    case redact = "REDACT"
    case veto = "VETO"
}

public struct RelayHookTraceEntry: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let sequenceNumber: UInt64
    public let hookKind: RelayLifecycleHookKind
    public let pluginID: String
    public let pluginName: String
    public let laneID: String?
    public let subjectSummary: String
    public let decision: RelayHookVerdictDecision
    public let reasonSummary: String
    public let redactedPayload: String?
    public let elapsedMicros: Double
    public let findings: [RelayGuardrailFinding]
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        sequenceNumber: UInt64,
        hookKind: RelayLifecycleHookKind,
        pluginID: String,
        pluginName: String,
        laneID: String?,
        subjectSummary: String,
        decision: RelayHookVerdictDecision,
        reasonSummary: String,
        redactedPayload: String? = nil,
        elapsedMicros: Double,
        findings: [RelayGuardrailFinding] = [],
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.hookKind = hookKind
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.laneID = laneID
        self.subjectSummary = subjectSummary
        self.decision = decision
        self.reasonSummary = reasonSummary
        self.redactedPayload = redactedPayload
        self.elapsedMicros = elapsedMicros
        self.findings = findings
        self.recordedAt = recordedAt
    }
}

/// Fixed-capacity lock-safe ring buffer storing structured lifecycle hook traces across all guardrail plugins.
public final class RelayPluginHookTraceRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    public let capacity: Int
    private var storage: [RelayHookTraceEntry?]
    private var writeIndex: Int = 0
    private var countValue: Int = 0
    private var nextSequenceNumber: UInt64 = 1

    public init(capacity: Int = 512) {
        let cap = max(16, capacity)
        self.capacity = cap
        self.storage = Array(repeating: nil, count: cap)
    }

    @discardableResult
    public func appendTrace(
        hookKind: RelayLifecycleHookKind,
        pluginID: String,
        pluginName: String,
        laneID: String?,
        subjectSummary: String,
        decision: RelayHookVerdictDecision,
        reasonSummary: String,
        redactedPayload: String? = nil,
        elapsedMicros: Double,
        findings: [RelayGuardrailFinding] = [],
        recordedAt: Date = Date()
    ) -> RelayHookTraceEntry {
        lock.lock()
        defer { lock.unlock() }
        let seq = nextSequenceNumber
        nextSequenceNumber += 1

        let entry = RelayHookTraceEntry(
            sequenceNumber: seq,
            hookKind: hookKind,
            pluginID: pluginID,
            pluginName: pluginName,
            laneID: laneID,
            subjectSummary: subjectSummary,
            decision: decision,
            reasonSummary: reasonSummary,
            redactedPayload: redactedPayload,
            elapsedMicros: elapsedMicros,
            findings: findings,
            recordedAt: recordedAt
        )
        storage[writeIndex] = entry
        writeIndex = (writeIndex + 1) % capacity
        countValue = min(capacity, countValue + 1)
        return entry
    }

    public func insertPrebuiltEntry(_ entry: RelayHookTraceEntry) {
        lock.lock()
        defer { lock.unlock() }
        nextSequenceNumber = max(nextSequenceNumber, entry.sequenceNumber + 1)
        storage[writeIndex] = entry
        writeIndex = (writeIndex + 1) % capacity
        countValue = min(capacity, countValue + 1)
    }

    public func recentEntries(limit: Int? = nil, filterHook: RelayLifecycleHookKind? = nil) -> [RelayHookTraceEntry] {
        lock.lock()
        var ordered: [RelayHookTraceEntry] = []
        ordered.reserveCapacity(countValue)
        let start = countValue < capacity ? 0 : writeIndex
        for offset in 0..<countValue {
            let idx = (start + offset) % capacity
            if let item = storage[idx] {
                if let filterHook, item.hookKind != filterHook { continue }
                ordered.append(item)
            }
        }
        lock.unlock()

        let reversedNewestFirst = Array(ordered.reversed())
        if let limit {
            return Array(reversedNewestFirst.prefix(max(0, limit)))
        }
        return reversedNewestFirst
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countValue
    }

    public func clear() {
        lock.lock()
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        countValue = 0
        lock.unlock()
    }
}

// MARK: - Deterministic Execution Microsecond Profiler

public struct PluginExecutionMicroProfile: Sendable, Codable, Hashable {
    public let pluginID: String
    public let vmBootstrapMicros: Double
    public let hostBridgeSetupMicros: Double
    public let scriptCompileMicros: Double
    public let entrypointInvokeMicros: Double
    public let totalWallMicros: Double
    public let exceededLatencyBudget: Bool

    public init(
        pluginID: String,
        vmBootstrapMicros: Double,
        hostBridgeSetupMicros: Double,
        scriptCompileMicros: Double,
        entrypointInvokeMicros: Double,
        totalWallMicros: Double,
        latencyBudgetMicros: Double = 15_000.0
    ) {
        self.pluginID = pluginID
        self.vmBootstrapMicros = vmBootstrapMicros
        self.hostBridgeSetupMicros = hostBridgeSetupMicros
        self.scriptCompileMicros = scriptCompileMicros
        self.entrypointInvokeMicros = entrypointInvokeMicros
        self.totalWallMicros = totalWallMicros
        self.exceededLatencyBudget = totalWallMicros > latencyBudgetMicros
    }
}

public struct PluginLatencyPercentiles: Sendable, Codable, Hashable, Identifiable {
    public var id: String { pluginID }
    public let pluginID: String
    public let sampleCount: Int
    public let minMicros: Double
    public let p50Micros: Double
    public let p95Micros: Double
    public let p99Micros: Double
    public let maxMicros: Double
    public let meanMicros: Double
    public let budgetBreachCount: Int

    public init(
        pluginID: String,
        sampleCount: Int,
        minMicros: Double,
        p50Micros: Double,
        p95Micros: Double,
        p99Micros: Double,
        maxMicros: Double,
        meanMicros: Double,
        budgetBreachCount: Int
    ) {
        self.pluginID = pluginID
        self.sampleCount = sampleCount
        self.minMicros = minMicros
        self.p50Micros = p50Micros
        self.p95Micros = p95Micros
        self.p99Micros = p99Micros
        self.maxMicros = maxMicros
        self.meanMicros = meanMicros
        self.budgetBreachCount = budgetBreachCount
    }
}

public final class RelayPluginMicrosecondProfiler: @unchecked Sendable {
    private let lock = NSLock()
    public let maxSamplesPerPlugin: Int
    public let latencyBudgetMicros: Double
    private var samplesByPlugin: [String: [PluginExecutionMicroProfile]] = [:]

    public init(maxSamplesPerPlugin: Int = 256, latencyBudgetMicros: Double = 15_000.0) {
        self.maxSamplesPerPlugin = max(8, maxSamplesPerPlugin)
        self.latencyBudgetMicros = max(100.0, latencyBudgetMicros)
    }

    public func record(_ profile: PluginExecutionMicroProfile) {
        lock.lock()
        defer { lock.unlock() }
        var arr = samplesByPlugin[profile.pluginID, default: []]
        arr.append(profile)
        if arr.count > maxSamplesPerPlugin {
            arr.removeFirst(arr.count - maxSamplesPerPlugin)
        }
        samplesByPlugin[profile.pluginID] = arr
    }

    public func summary(forPlugin pluginID: String) -> PluginLatencyPercentiles? {
        lock.lock()
        let arr = samplesByPlugin[pluginID] ?? []
        lock.unlock()
        guard !arr.isEmpty else { return nil }
        return Self.computePercentiles(pluginID: pluginID, profiles: arr)
    }

    public func allPluginSummaries() -> [PluginLatencyPercentiles] {
        lock.lock()
        let snapshot = samplesByPlugin
        lock.unlock()
        return snapshot.keys.sorted().compactMap { key in
            guard let arr = snapshot[key], !arr.isEmpty else { return nil }
            return Self.computePercentiles(pluginID: key, profiles: arr)
        }
    }

    private static func computePercentiles(pluginID: String, profiles: [PluginExecutionMicroProfile]) -> PluginLatencyPercentiles {
        let totals = profiles.map(\.totalWallMicros).sorted()
        let n = totals.count
        let sum = totals.reduce(0.0, +)
        let breaches = profiles.filter(\.exceededLatencyBudget).count

        func percentile(_ q: Double) -> Double {
            let pos = min(n - 1, max(0, Int((Double(n - 1) * q).rounded())))
            return totals[pos]
        }

        return PluginLatencyPercentiles(
            pluginID: pluginID,
            sampleCount: n,
            minMicros: totals.first ?? 0.0,
            p50Micros: percentile(0.50),
            p95Micros: percentile(0.95),
            p99Micros: percentile(0.99),
            maxMicros: totals.last ?? 0.0,
            meanMicros: sum / Double(max(1, n)),
            budgetBreachCount: breaches
        )
    }
}

// MARK: - Plugin Configuration Schema Validator

public enum PluginConfigValue: Sendable, Codable, Hashable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case stringArray([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .boolean(b)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([String].self) {
            self = .stringArray(arr)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported PluginConfigValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        case .number(let d): try container.encode(d)
        case .boolean(let b): try container.encode(b)
        case .stringArray(let arr): try container.encode(arr)
        }
    }

    internal var toJSBridgeValue: Any {
        switch self {
        case .string(let s): return s
        case .integer(let i): return i
        case .number(let d): return d
        case .boolean(let b): return b
        case .stringArray(let arr): return arr
        }
    }
}

public enum PluginConfigFieldType: String, Sendable, Codable, Hashable, CaseIterable {
    case string = "string"
    case integer = "integer"
    case number = "number"
    case boolean = "boolean"
    case stringArray = "string[]"
}

public struct PluginConfigFieldSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let fieldType: PluginConfigFieldType
    public let isRequired: Bool
    public let summary: String
    public let defaultValue: PluginConfigValue?
    public let minimumNumeric: Double?
    public let maximumNumeric: Double?
    public let allowedEnumValues: [String]?
    public let regexPattern: String?

    public init(
        key: String,
        fieldType: PluginConfigFieldType,
        isRequired: Bool = false,
        summary: String,
        defaultValue: PluginConfigValue? = nil,
        minimumNumeric: Double? = nil,
        maximumNumeric: Double? = nil,
        allowedEnumValues: [String]? = nil,
        regexPattern: String? = nil
    ) {
        self.key = key
        self.fieldType = fieldType
        self.isRequired = isRequired
        self.summary = summary
        self.defaultValue = defaultValue
        self.minimumNumeric = minimumNumeric
        self.maximumNumeric = maximumNumeric
        self.allowedEnumValues = allowedEnumValues
        self.regexPattern = regexPattern
    }
}

public struct PluginConfigSchema: Sendable, Codable, Hashable, Identifiable {
    public var id: String { pluginID }
    public let pluginID: String
    public let schemaVersion: String
    public let fields: [PluginConfigFieldSpec]
    public let allowUnknownKeys: Bool

    public init(
        pluginID: String,
        schemaVersion: String = "1.0",
        fields: [PluginConfigFieldSpec],
        allowUnknownKeys: Bool = false
    ) {
        self.pluginID = pluginID
        self.schemaVersion = schemaVersion
        self.fields = fields
        self.allowUnknownKeys = allowUnknownKeys
    }
}

public struct PluginConfigValidationDiagnostic: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(fieldKey):\(message)" }
    public let pluginID: String
    public let fieldKey: String
    public let message: String

    public init(pluginID: String, fieldKey: String, message: String) {
        self.pluginID = pluginID
        self.fieldKey = fieldKey
        self.message = message
    }
}

public struct RelayPluginConfigSchemaValidator: Sendable {
    public init() {}

    public func validateAndMaterializeDefaults(
        rawConfig: [String: PluginConfigValue],
        against schema: PluginConfigSchema
    ) -> (resolvedConfig: [String: PluginConfigValue], diagnostics: [PluginConfigValidationDiagnostic]) {
        var resolved = rawConfig
        var diagnostics: [PluginConfigValidationDiagnostic] = []
        let fieldMap = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.key, $0) })

        if !schema.allowUnknownKeys {
            for key in rawConfig.keys.sorted() where fieldMap[key] == nil {
                diagnostics.append(
                    PluginConfigValidationDiagnostic(
                        pluginID: schema.pluginID,
                        fieldKey: key,
                        message: "Unknown configuration property '\(key)' is not permitted by schema."
                    )
                )
            }
        }

        for spec in schema.fields {
            if resolved[spec.key] == nil, let defVal = spec.defaultValue {
                resolved[spec.key] = defVal
            }
            guard let val = resolved[spec.key] else {
                if spec.isRequired {
                    diagnostics.append(
                        PluginConfigValidationDiagnostic(
                            pluginID: schema.pluginID,
                            fieldKey: spec.key,
                            message: "Missing required configuration property '\(spec.key)' (\(spec.fieldType.rawValue))."
                        )
                    )
                }
                continue
            }

            // Type & range checks
            switch (spec.fieldType, val) {
            case (.string, .string(let str)):
                if let allowed = spec.allowedEnumValues, !allowed.contains(str) {
                    diagnostics.append(
                        PluginConfigValidationDiagnostic(
                            pluginID: schema.pluginID,
                            fieldKey: spec.key,
                            message: "Value '\(str)' must be one of [\(allowed.joined(separator: ", "))]."
                        )
                    )
                }
                if let pattern = spec.regexPattern,
                   let rx = try? NSRegularExpression(pattern: pattern) {
                    let ns = str as NSString
                    if rx.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)) == nil {
                        diagnostics.append(
                            PluginConfigValidationDiagnostic(
                                pluginID: schema.pluginID,
                                fieldKey: spec.key,
                                message: "Value '\(str)' failed regex constraint '\(pattern)'."
                            )
                        )
                    }
                }

            case (.integer, .integer(let intVal)):
                checkNumericBounds(Double(intVal), spec: spec, pluginID: schema.pluginID, diagnostics: &diagnostics)

            case (.number, .number(let dblVal)):
                checkNumericBounds(dblVal, spec: spec, pluginID: schema.pluginID, diagnostics: &diagnostics)

            case (.number, .integer(let intVal)):
                checkNumericBounds(Double(intVal), spec: spec, pluginID: schema.pluginID, diagnostics: &diagnostics)

            case (.boolean, .boolean):
                break

            case (.stringArray, .stringArray(let arr)):
                if let minCount = spec.minimumNumeric, Double(arr.count) < minCount {
                    diagnostics.append(
                        PluginConfigValidationDiagnostic(
                            pluginID: schema.pluginID,
                            fieldKey: spec.key,
                            message: "Array '\(spec.key)' requires at least \(Int(minCount)) item(s)."
                        )
                    )
                }

            default:
                diagnostics.append(
                    PluginConfigValidationDiagnostic(
                        pluginID: schema.pluginID,
                        fieldKey: spec.key,
                        message: "Expected type '\(spec.fieldType.rawValue)' for '\(spec.key)'."
                    )
                )
            }
        }

        return (resolved, diagnostics)
    }

    private func checkNumericBounds(
        _ value: Double,
        spec: PluginConfigFieldSpec,
        pluginID: String,
        diagnostics: inout [PluginConfigValidationDiagnostic]
    ) {
        if let minVal = spec.minimumNumeric, value < minVal {
            diagnostics.append(
                PluginConfigValidationDiagnostic(
                    pluginID: pluginID,
                    fieldKey: spec.key,
                    message: "Value \(value) is below minimum \(minVal)."
                )
            )
        }
        if let maxVal = spec.maximumNumeric, value > maxVal {
            diagnostics.append(
                PluginConfigValidationDiagnostic(
                    pluginID: pluginID,
                    fieldKey: spec.key,
                    message: "Value \(value) exceeds maximum \(maxVal)."
                )
            )
        }
    }
}

// MARK: - Capability-Gated JavaScriptCore Scratchpad & Hook Evaluator

public struct ScratchpadConsoleLine: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let level: String
    public let message: String

    public init(id: UUID = UUID(), level: String, message: String) {
        self.id = id
        self.level = level
        self.message = message
    }
}

public struct RelayScratchpadEvaluationResult: Sendable, Codable, Hashable {
    public let succeeded: Bool
    public let returnValuePreview: String
    public let findings: [RelayGuardrailFinding]
    public let synthesizedCommitTitle: String?
    public let hookDecision: RelayHookVerdictDecision
    public let hookReason: String
    public let redactedOutput: String?
    public let consoleOutput: [ScratchpadConsoleLine]
    public let capabilityDenials: [String]
    public let exceptionMessage: String?
    public let profile: PluginExecutionMicroProfile

    public init(
        succeeded: Bool,
        returnValuePreview: String,
        findings: [RelayGuardrailFinding],
        synthesizedCommitTitle: String?,
        hookDecision: RelayHookVerdictDecision,
        hookReason: String,
        redactedOutput: String?,
        consoleOutput: [ScratchpadConsoleLine],
        capabilityDenials: [String],
        exceptionMessage: String?,
        profile: PluginExecutionMicroProfile
    ) {
        self.succeeded = succeeded
        self.returnValuePreview = returnValuePreview
        self.findings = findings
        self.synthesizedCommitTitle = synthesizedCommitTitle
        self.hookDecision = hookDecision
        self.hookReason = hookReason
        self.redactedOutput = redactedOutput
        self.consoleOutput = consoleOutput
        self.capabilityDenials = capabilityDenials
        self.exceptionMessage = exceptionMessage
        self.profile = profile
    }
}

public final class RelayJSScratchpadEvaluator: @unchecked Sendable {
    public let profiler: RelayPluginMicrosecondProfiler
    public let traceBuffer: RelayPluginHookTraceRingBuffer
    private let astParser = MultiLanguageDeclarationParser()

    public init(
        profiler: RelayPluginMicrosecondProfiler = RelayPluginMicrosecondProfiler(),
        traceBuffer: RelayPluginHookTraceRingBuffer = RelayPluginHookTraceRingBuffer()
    ) {
        self.profiler = profiler
        self.traceBuffer = traceBuffer
    }

    /// Evaluates an interactive or policy-pack JavaScript guardrail script inside a capability-gated `JavaScriptCore` VM.
    public func evaluateScratchpad(
        pluginID: String = "io.relayide.scratchpad",
        pluginName: String = "Interactive Guardrail Scratchpad",
        scriptSource: String,
        grantedCapabilities: Set<RelayPluginCapability>,
        configValues: [String: PluginConfigValue] = [:],
        modifiedFilesByLane: [String: [String: String]] = [:],
        budgetAccounts: [LaneBudgetAccount] = [],
        hookEvent: RelayLifecycleHookEvent? = nil
    ) -> RelayScratchpadEvaluationResult {
        let t0 = DispatchTime.now().uptimeNanoseconds

        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            let zeroProfile = PluginExecutionMicroProfile(
                pluginID: pluginID,
                vmBootstrapMicros: 0,
                hostBridgeSetupMicros: 0,
                scriptCompileMicros: 0,
                entrypointInvokeMicros: 0,
                totalWallMicros: 0
            )
            return RelayScratchpadEvaluationResult(
                succeeded: false,
                returnValuePreview: "undefined",
                findings: [],
                synthesizedCommitTitle: nil,
                hookDecision: .allow,
                hookReason: "VM allocation failure",
                redactedOutput: nil,
                consoleOutput: [],
                capabilityDenials: [],
                exceptionMessage: "Failed to initialize JavaScriptCore JSVirtualMachine",
                profile: zeroProfile
            )
        }
        let tAfterVM = DispatchTime.now().uptimeNanoseconds

        var jsException: String?
        var consoleLines: [ScratchpadConsoleLine] = []
        var capabilityDenials: [String] = []
        var emittedFindings: [RelayGuardrailFinding] = []
        var commitTitle: String?
        var hookDecision: RelayHookVerdictDecision = .allow
        var hookReason: String = "Passed hook evaluation"
        var hookRedactedText: String?

        ctx.exceptionHandler = { _, exc in
            jsException = exc?.toString() ?? "JavaScript evaluation error"
        }

        let logBlock: @convention(block) (String, String) -> Void = { level, text in
            if consoleLines.count < 200 {
                consoleLines.append(ScratchpadConsoleLine(level: level, message: text))
            }
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__relayConsole" as NSString)

        let getConfigBlock: @convention(block) () -> [String: Any] = {
            var dict: [String: Any] = [:]
            for (k, v) in configValues {
                dict[k] = v.toJSBridgeValue
            }
            return dict
        }
        ctx.setObject(getConfigBlock, forKeyedSubscript: "__relayGetConfig" as NSString)

        let getHookEventBlock: @convention(block) () -> [String: Any] = {
            hookEvent?.toJSObjectDictionary() ?? [:]
        }
        ctx.setObject(getHookEventBlock, forKeyedSubscript: "__relayGetHookPayload" as NSString)

        let getDiffsBlock: @convention(block) () -> [[String: Any]] = {
            guard grantedCapabilities.contains(.inspectDiffs) else {
                capabilityDenials.append("Denied RelayHost.getDiffs() — missing capability 'diffs.inspect'")
                return []
            }
            var rows: [[String: Any]] = []
            for (laneID, files) in modifiedFilesByLane.sorted(by: { $0.key < $1.key }) {
                for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                    rows.append(["laneID": laneID, "path": path, "content": content])
                }
            }
            return rows
        }
        ctx.setObject(getDiffsBlock, forKeyedSubscript: "__relayGetDiffs" as NSString)

        let parser = self.astParser
        let getASTBlock: @convention(block) () -> [[String: Any]] = {
            guard grantedCapabilities.contains(.inspectASTNodes) else {
                capabilityDenials.append("Denied RelayHost.getAST() — missing capability 'ast.inspect'")
                return []
            }
            var items: [[String: Any]] = []
            for (laneID, files) in modifiedFilesByLane.sorted(by: { $0.key < $1.key }) {
                for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                    let lang = SourceLanguage.detect(fromPath: path)
                    let nodes = parser.parseDeclarations(source: content, language: lang)
                    for n in nodes where n.kind != .importGroup {
                        items.append([
                            "laneID": laneID,
                            "path": path,
                            "kind": n.kind.rawValue,
                            "symbol": n.symbolName,
                            "startLine": n.startLine,
                            "endLine": n.endLine
                        ])
                    }
                }
            }
            return items
        }
        ctx.setObject(getASTBlock, forKeyedSubscript: "__relayGetAST" as NSString)

        let getBudgetsBlock: @convention(block) () -> [[String: Any]] = {
            guard grantedCapabilities.contains(.inspectTokenTelemetry) else {
                capabilityDenials.append("Denied RelayHost.getBudgets() — missing capability 'wiretap.inspect'")
                return []
            }
            return budgetAccounts.map { acc in
                [
                    "laneID": acc.laneID,
                    "vendor": acc.vendor.rawValue,
                    "inputTokens": acc.inputTokens,
                    "cachedTokens": acc.cachedTokens,
                    "outputTokens": acc.outputTokens,
                    "spentUSD": acc.spentUSD,
                    "ceilingUSD": acc.ceilingUSD,
                    "circuitOpen": acc.circuitOpen
                ]
            }
        }
        ctx.setObject(getBudgetsBlock, forKeyedSubscript: "__relayGetBudgets" as NSString)

        let emitFindingBlock: @convention(block) (String, String, String, String, String) -> Void = { sevRaw, laneID, path, title, detail in
            let sev = GuardrailSeverity(rawValue: sevRaw.uppercased()) ?? .advisory
            if sev == .blocker && !grantedCapabilities.contains(.vetoMergeGate) {
                capabilityDenials.append("Downgraded BLOCKER to WARNING — missing capability 'merge.veto'")
                emittedFindings.append(
                    RelayGuardrailFinding(
                        pluginID: pluginID,
                        pluginName: pluginName,
                        severity: .warning,
                        laneID: laneID.isEmpty ? nil : laneID,
                        relativePath: path.isEmpty ? nil : path,
                        title: title,
                        detail: detail
                    )
                )
                return
            }
            emittedFindings.append(
                RelayGuardrailFinding(
                    pluginID: pluginID,
                    pluginName: pluginName,
                    severity: sev,
                    laneID: laneID.isEmpty ? nil : laneID,
                    relativePath: path.isEmpty ? nil : path,
                    title: title,
                    detail: detail
                )
            )
        }
        ctx.setObject(emitFindingBlock, forKeyedSubscript: "__relayEmitFinding" as NSString)

        let proposeCommitBlock: @convention(block) (String) -> Void = { headline in
            guard grantedCapabilities.contains(.synthesizeCommitMessage) else {
                capabilityDenials.append("Denied RelayHost.proposeCommit() — missing capability 'commit.synthesize'")
                return
            }
            commitTitle = headline
        }
        ctx.setObject(proposeCommitBlock, forKeyedSubscript: "__relayProposeCommit" as NSString)

        let setVerdictBlock: @convention(block) (String, String, String) -> Void = { decisionRaw, reason, redacted in
            let dec = RelayHookVerdictDecision(rawValue: decisionRaw.uppercased()) ?? .allow
            if dec == .veto && !grantedCapabilities.contains(.vetoMergeGate) {
                capabilityDenials.append("Denied VETO hook decision — missing capability 'merge.veto'")
                hookDecision = .warn
                hookReason = reason
                return
            }
            hookDecision = dec
            hookReason = reason
            if !redacted.isEmpty {
                hookRedactedText = redacted
            }
        }
        ctx.setObject(setVerdictBlock, forKeyedSubscript: "__relaySetHookVerdict" as NSString)

        let sandboxBootstrap = """
        const console = Object.freeze({
            log: (...args) => __relayConsole("INFO", args.map(String).join(" ")),
            warn: (...args) => __relayConsole("WARN", args.map(String).join(" ")),
            error: (...args) => __relayConsole("ERROR", args.map(String).join(" "))
        });
        const RelayHost = Object.freeze({
            log: (msg) => __relayConsole("INFO", String(msg)),
            getConfig: () => __relayGetConfig(),
            getHookPayload: () => __relayGetHookPayload(),
            getDiffs: () => __relayGetDiffs(),
            getAST: () => __relayGetAST(),
            getBudgets: () => __relayGetBudgets(),
            emitFinding: (severity, laneID, path, title, detail) =>
                __relayEmitFinding(String(severity), String(laneID || ""), String(path || ""), String(title), String(detail)),
            proposeCommit: (headline) => __relayProposeCommit(String(headline)),
            setHookVerdict: (decision, reason, redactedText) =>
                __relaySetHookVerdict(String(decision), String(reason || ""), String(redactedText || ""))
        });
        """
        _ = ctx.evaluateScript(sandboxBootstrap)
        let tAfterBridge = DispatchTime.now().uptimeNanoseconds

        let topLevelVal = ctx.evaluateScript(scriptSource)
        let tAfterCompile = DispatchTime.now().uptimeNanoseconds

        var callRetPreview = topLevelVal?.toString() ?? "undefined"
        if jsException == nil {
            if let hookEvent {
                let hookFnName = hookEvent.kind.jsFunctionName
                if let hookFn = ctx.objectForKeyedSubscript(hookFnName as NSString), !hookFn.isUndefined {
                    let ret = hookFn.call(withArguments: [hookEvent.toJSObjectDictionary()])
                    if let r = ret, !r.isUndefined {
                        callRetPreview = r.toString() ?? callRetPreview
                    }
                } else if let fallbackFn = ctx.objectForKeyedSubscript("runRelayGuardrail" as NSString), !fallbackFn.isUndefined {
                    let ret = fallbackFn.call(withArguments: [])
                    if let r = ret, !r.isUndefined {
                        callRetPreview = r.toString() ?? callRetPreview
                    }
                }
            } else if let entryFn = ctx.objectForKeyedSubscript("runRelayGuardrail" as NSString), !entryFn.isUndefined {
                let ret = entryFn.call(withArguments: [])
                if let r = ret, !r.isUndefined {
                    callRetPreview = r.toString() ?? callRetPreview
                }
            }
        }
        let tEnd = DispatchTime.now().uptimeNanoseconds

        let profile = PluginExecutionMicroProfile(
            pluginID: pluginID,
            vmBootstrapMicros: Double(tAfterVM - t0) / 1_000.0,
            hostBridgeSetupMicros: Double(tAfterBridge - tAfterVM) / 1_000.0,
            scriptCompileMicros: Double(tAfterCompile - tAfterBridge) / 1_000.0,
            entrypointInvokeMicros: Double(tEnd - tAfterCompile) / 1_000.0,
            totalWallMicros: Double(tEnd - t0) / 1_000.0,
            latencyBudgetMicros: profiler.latencyBudgetMicros
        )
        profiler.record(profile)

        if let hookEvent {
            traceBuffer.appendTrace(
                hookKind: hookEvent.kind,
                pluginID: pluginID,
                pluginName: pluginName,
                laneID: hookEvent.laneID,
                subjectSummary: hookEvent.targetSubject,
                decision: hookDecision,
                reasonSummary: jsException ?? hookReason,
                redactedPayload: hookRedactedText,
                elapsedMicros: profile.totalWallMicros,
                findings: emittedFindings
            )
        }

        return RelayScratchpadEvaluationResult(
            succeeded: jsException == nil,
            returnValuePreview: callRetPreview,
            findings: emittedFindings,
            synthesizedCommitTitle: commitTitle,
            hookDecision: hookDecision,
            hookReason: hookReason,
            redactedOutput: hookRedactedText,
            consoleOutput: consoleLines,
            capabilityDenials: capabilityDenials,
            exceptionMessage: jsException,
            profile: profile
        )
    }

    /// Dispatches a lifecycle hook across all enabled plugins in a `RelayJavaScriptPluginHost` and aggregates findings + trace entries.
    public func dispatchLifecycleHook(
        _ event: RelayLifecycleHookEvent,
        across plugins: [RelayPluginManifest],
        configsByPluginID: [String: [String: PluginConfigValue]] = [:]
    ) -> [RelayScratchpadEvaluationResult] {
        plugins.filter(\.isEnabled).map { manifest in
            evaluateScratchpad(
                pluginID: manifest.id,
                pluginName: manifest.name,
                scriptSource: manifest.scriptSource,
                grantedCapabilities: Set(manifest.capabilities),
                configValues: configsByPluginID[manifest.id] ?? [:],
                hookEvent: event
            )
        }
    }
}

// MARK: - Built-In Lifecycle Hook Guardrail Policies

public enum BuiltInLifecycleHookGuardrails {
    public static let destructiveShellBlocker = RelayPluginManifest(
        id: "io.relayide.destructive-shell-blocker",
        name: "Destructive Shell Command Blocker",
        version: "1.2.0",
        summary: "Intercepts git reset --hard, git push --force, git clean -fdx, and recursive root deletions on onCommandSpawn.",
        capabilities: [.vetoMergeGate],
        scriptSource: #"""
        function onCommandSpawn(ctx) {
            const cmd = ctx.commandLine || "";
            const rules = [
                { label: "git reset --hard", rx: /\bgit\s+reset\s+--hard\b/ },
                { label: "git push --force", rx: /\bgit\s+push\s+(?:--force|-f)\b/ },
                { label: "git clean -fdx", rx: /\bgit\s+clean\s+-[a-zA-Z]*f[a-zA-Z]*d/ },
                { label: "rm -rf root/parent", rx: /\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+(?:\/|\.\.)/ }
            ];
            for (const rule of rules) {
                if (rule.rx.test(cmd)) {
                    RelayHost.emitFinding(
                        "BLOCKER",
                        ctx.laneID,
                        ctx.workingDirectory,
                        "Blocked destructive shell invocation (" + rule.label + ")",
                        "Agent '" + ctx.vendor + "' in '" + ctx.laneID + "' attempted '" + cmd + "'."
                    );
                    RelayHost.setHookVerdict("VETO", "Blocked destructive command: " + rule.label, "");
                    return "VETO";
                }
            }
            RelayHost.setHookVerdict("ALLOW", "Command verified safe", "");
            return "ALLOW";
        }
        """#
    )

    public static let territoryFenceGuard = RelayPluginManifest(
        id: "io.relayide.territory-fence-guard",
        name: "Territory Fence Cross-Lane Guard",
        version: "1.2.0",
        summary: "Flags cross-lane file touches violating worktree ownership globs on onFileTouch.",
        capabilities: [.inspectDiffs, .vetoMergeGate],
        scriptSource: #"""
        function globMatches(path, glob) {
            if (glob === "**" || glob === "**/*") return true;
            const prefix = glob.replace(/\/\*\*$/, "");
            return path === prefix || path.startsWith(prefix + "/");
        }
        function onFileTouch(ctx) {
            const rel = ctx.relativePath || "";
            const forbidden = ctx.forbiddenGlobs || [];
            const allowed = ctx.allowedGlobs || ["**"];
            for (const fg of forbidden) {
                if (globMatches(rel, fg)) {
                    RelayHost.emitFinding(
                        "BLOCKER",
                        ctx.laneID,
                        rel,
                        "Territory fence violation (forbidden scope)",
                        "Lane '" + ctx.laneID + "' touched '" + rel + "' matching forbidden glob '" + fg + "'."
                    );
                    RelayHost.setHookVerdict("VETO", "Matched forbidden glob " + fg, "");
                    return "VETO";
                }
            }
            const ok = allowed.some(ag => globMatches(rel, ag));
            if (!ok) {
                RelayHost.emitFinding(
                    "WARNING",
                    ctx.laneID,
                    rel,
                    "Cross-lane territory drift detected",
                    "Lane '" + ctx.laneID + "' modified '" + rel + "' outside assigned globs [" + allowed.join(", ") + "]."
                );
                RelayHost.setHookVerdict("WARN", "Path outside assigned territory globs", "");
                return "WARN";
            }
            RelayHost.setHookVerdict("ALLOW", "Within assigned territory", "");
            return "ALLOW";
        }
        """#
    )

    public static let secretPromptRedactor = RelayPluginManifest(
        id: "io.relayide.secret-prompt-redactor",
        name: "Outbound Prompt Secret Redactor",
        version: "1.2.0",
        summary: "Masks accidentally pasted API tokens inside outbound LLM prompts on onWiretapRequest.",
        capabilities: [.inspectTokenTelemetry],
        scriptSource: #"""
        function onWiretapRequest(ctx) {
            let text = ctx.promptSnippet || "";
            const ghTokenPrefix = "gh" + "p_";
            const secretRx = new RegExp("\\b(sk-ant-[A-Za-z0-9\\-_]{12,}|sk-proj-[A-Za-z0-9\\-_]{12,}|" + ghTokenPrefix + "[A-Za-z0-9]{20,})\\b", "g");
            if (secretRx.test(text)) {
                const masked = text.replace(secretRx, "[REDACTED_BY_PLUGIN]");
                RelayHost.emitFinding(
                    "WARNING",
                    ctx.laneID,
                    ctx.providerHost,
                    "Masked credential token in outbound prompt",
                    "Sanitized secret token before forwarding turn to " + ctx.providerHost + " (" + ctx.modelIdentifier + ")."
                );
                RelayHost.setHookVerdict("REDACT", "Masked inline credential token", masked);
                return "REDACT";
            }
            RelayHost.setHookVerdict("ALLOW", "No inline credentials found", "");
            return "ALLOW";
        }
        """#
    )

    public static let allLifecyclePlugins: [RelayPluginManifest] = [
        destructiveShellBlocker,
        territoryFenceGuard,
        secretPromptRedactor
    ]
}

// MARK: - .relay-guardrails.json Policy Pack Importer & Exporter

public struct RelayPolicyPackPluginEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String { manifest.id }
    public var manifest: RelayPluginManifest
    public var configSchema: PluginConfigSchema?
    public var configuration: [String: PluginConfigValue]
    public var scriptSHA256Hex: String

    public init(
        manifest: RelayPluginManifest,
        configSchema: PluginConfigSchema? = nil,
        configuration: [String: PluginConfigValue] = [:]
    ) {
        self.manifest = manifest
        self.configSchema = configSchema
        self.configuration = configuration
        self.scriptSHA256Hex = Self.computeScriptSHA256(manifest.scriptSource)
    }

    public var isScriptDigestValid: Bool {
        scriptSHA256Hex == Self.computeScriptSHA256(manifest.scriptSource)
    }

    public static func computeScriptSHA256(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct RelayGuardrailsPolicyPack: Sendable, Codable, Hashable, Identifiable {
    public static let currentFormatVersion = "relay-guardrails/v1"

    public var id: String { packID }
    public let formatVersion: String
    public let packID: String
    public var packName: String
    public var summary: String
    public var defaultExecutionBudgetMicros: Double
    public var entries: [RelayPolicyPackPluginEntry]
    public let exportedAt: Date

    public init(
        formatVersion: String = RelayGuardrailsPolicyPack.currentFormatVersion,
        packID: String,
        packName: String,
        summary: String,
        defaultExecutionBudgetMicros: Double = 15_000.0,
        entries: [RelayPolicyPackPluginEntry],
        exportedAt: Date = Date()
    ) {
        self.formatVersion = formatVersion
        self.packID = packID
        self.packName = packName
        self.summary = summary
        self.defaultExecutionBudgetMicros = defaultExecutionBudgetMicros
        self.entries = entries
        self.exportedAt = exportedAt
    }

    public static func defaultIndustrialPack() -> RelayGuardrailsPolicyPack {
        let combined = BuiltInRelayGuardrailPlugins.all + BuiltInLifecycleHookGuardrails.allLifecyclePlugins
        let entries = combined.map { manifest -> RelayPolicyPackPluginEntry in
            if manifest.id == "io.relayide.budget-anomaly-auditor" {
                let schema = PluginConfigSchema(
                    pluginID: manifest.id,
                    fields: [
                        PluginConfigFieldSpec(
                            key: "utilizationWarningRatio",
                            fieldType: .number,
                            isRequired: true,
                            summary: "Spend-to-ceiling ratio threshold for emitting WARNING",
                            defaultValue: .number(0.85),
                            minimumNumeric: 0.10,
                            maximumNumeric: 1.00
                        ),
                        PluginConfigFieldSpec(
                            key: "minimumCacheHitRatio",
                            fieldType: .number,
                            isRequired: true,
                            summary: "Minimum prompt-cache reuse ratio on >50k token contexts",
                            defaultValue: .number(0.15),
                            minimumNumeric: 0.0,
                            maximumNumeric: 0.95
                        )
                    ]
                )
                return RelayPolicyPackPluginEntry(
                    manifest: manifest,
                    configSchema: schema,
                    configuration: [
                        "utilizationWarningRatio": .number(0.85),
                        "minimumCacheHitRatio": .number(0.15)
                    ]
                )
            }
            return RelayPolicyPackPluginEntry(manifest: manifest)
        }

        return RelayGuardrailsPolicyPack(
            packID: "io.relayide.pack.industrial-default",
            packName: "RelayIDE Industrial Multi-Agent Guardrails",
            summary: "Default capability-gated policy pack covering secret leaks, destructive commands, territory fences, test coverage gates, and Conventional Commits.",
            entries: entries
        )
    }
}

public struct PolicyPackDiffSummary: Sendable, Codable, Hashable {
    public let addedPluginIDs: [String]
    public let removedPluginIDs: [String]
    public let modifiedScriptPluginIDs: [String]
    public let toggledEnablementPluginIDs: [String]
    public let modifiedConfigPluginIDs: [String]

    public init(
        addedPluginIDs: [String],
        removedPluginIDs: [String],
        modifiedScriptPluginIDs: [String],
        toggledEnablementPluginIDs: [String],
        modifiedConfigPluginIDs: [String]
    ) {
        self.addedPluginIDs = addedPluginIDs
        self.removedPluginIDs = removedPluginIDs
        self.modifiedScriptPluginIDs = modifiedScriptPluginIDs
        self.toggledEnablementPluginIDs = toggledEnablementPluginIDs
        self.modifiedConfigPluginIDs = modifiedConfigPluginIDs
    }
}

public struct RelayGuardrailsPolicyPackCodec: Sendable {
    public let schemaValidator = RelayPluginConfigSchemaValidator()

    public init() {}

    public func exportData(_ pack: RelayGuardrailsPolicyPack, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(pack)
    }

    public func exportToFile(_ pack: RelayGuardrailsPolicyPack, fileURL: URL) throws {
        let data = try exportData(pack, prettyPrinted: true)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func importData(
        _ data: Data,
        verifyScriptDigests: Bool = true
    ) throws -> (pack: RelayGuardrailsPolicyPack, diagnostics: [PluginConfigValidationDiagnostic]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded = try decoder.decode(RelayGuardrailsPolicyPack.self, from: data)
        var allDiagnostics: [PluginConfigValidationDiagnostic] = []

        for idx in decoded.entries.indices {
            let entry = decoded.entries[idx]
            if verifyScriptDigests && !entry.isScriptDigestValid {
                throw RelayIDEError.pluginError(
                    pluginID: entry.manifest.id,
                    reason: "Script SHA-256 integrity mismatch in .relay-guardrails.json"
                )
            }
            if let schema = entry.configSchema {
                let (resolved, diags) = schemaValidator.validateAndMaterializeDefaults(
                    rawConfig: entry.configuration,
                    against: schema
                )
                decoded.entries[idx].configuration = resolved
                allDiagnostics.append(contentsOf: diags)
            }
        }
        return (decoded, allDiagnostics)
    }

    public func importFromFile(
        fileURL: URL,
        verifyScriptDigests: Bool = true
    ) throws -> (pack: RelayGuardrailsPolicyPack, diagnostics: [PluginConfigValidationDiagnostic]) {
        let raw = try Data(contentsOf: fileURL)
        return try importData(raw, verifyScriptDigests: verifyScriptDigests)
    }

    public func apply(_ pack: RelayGuardrailsPolicyPack, to host: RelayJavaScriptPluginHost) {
        for entry in pack.entries {
            host.registerPlugin(entry.manifest)
            host.setPluginEnabled(id: entry.manifest.id, isEnabled: entry.manifest.isEnabled)
        }
    }

    public func diff(baseline: RelayGuardrailsPolicyPack, candidate: RelayGuardrailsPolicyPack) -> PolicyPackDiffSummary {
        let baseMap = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.id, $0) })
        let candMap = Dictionary(uniqueKeysWithValues: candidate.entries.map { ($0.id, $0) })

        let added = Set(candMap.keys).subtracting(baseMap.keys).sorted()
        let removed = Set(baseMap.keys).subtracting(candMap.keys).sorted()
        var scriptChanged: [String] = []
        var enabledToggled: [String] = []
        var configChanged: [String] = []

        for id in Set(baseMap.keys).intersection(candMap.keys).sorted() {
            guard let b = baseMap[id], let c = candMap[id] else { continue }
            if b.scriptSHA256Hex != c.scriptSHA256Hex {
                scriptChanged.append(id)
            }
            if b.manifest.isEnabled != c.manifest.isEnabled {
                enabledToggled.append(id)
            }
            if b.configuration != c.configuration {
                configChanged.append(id)
            }
        }

        return PolicyPackDiffSummary(
            addedPluginIDs: added,
            removedPluginIDs: removed,
            modifiedScriptPluginIDs: scriptChanged,
            toggledEnablementPluginIDs: enabledToggled,
            modifiedConfigPluginIDs: configChanged
        )
    }
}
