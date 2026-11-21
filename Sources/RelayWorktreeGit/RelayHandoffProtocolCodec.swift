import CryptoKit
import Foundation
import RelayModels

// MARK: - Cross-Vendor Relay Kickoff (`RELAY_KICKOFF.md`) & Ledger (`.relay/LOG.md`) Models

public enum RelayHandoffStepStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case handoffReady = "HANDOFF_READY"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case blockedByGuardrail = "BLOCKED_BY_GUARDRAIL"
}

public struct RelayArtifactDigestEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let byteSize: Int64
    public let sha256Hex: String

    public init(relativePath: String, byteSize: Int64, sha256Hex: String) {
        self.relativePath = relativePath
        self.byteSize = max(0, byteSize)
        self.sha256Hex = sha256Hex.lowercased()
    }
}

public struct RelayKickoffStageContract: Sendable, Codable, Hashable, Identifiable {
    public var id: String { stageID }
    public let stageNumber: Int
    public let stageID: String
    public var title: String
    public var vendor: AgentVendor
    public var laneID: String
    public var dependsOnStageIDs: [String]
    public var inputArtifacts: [String]
    public var outputArtifacts: [String]
    public var ownershipRule: FileOwnershipRule
    public var verificationCommand: String?
    public var budgetCeilingUSD: Double
    public var promptBrief: String

    public init(
        stageNumber: Int,
        stageID: String,
        title: String,
        vendor: AgentVendor,
        laneID: String,
        dependsOnStageIDs: [String] = [],
        inputArtifacts: [String] = [],
        outputArtifacts: [String] = [],
        ownershipRule: FileOwnershipRule = FileOwnershipRule(),
        verificationCommand: String? = nil,
        budgetCeilingUSD: Double = 5.0,
        promptBrief: String
    ) {
        self.stageNumber = max(1, stageNumber)
        self.stageID = stageID
        self.title = title
        self.vendor = vendor
        self.laneID = laneID
        self.dependsOnStageIDs = dependsOnStageIDs
        self.inputArtifacts = inputArtifacts
        self.outputArtifacts = outputArtifacts
        self.ownershipRule = ownershipRule
        self.verificationCommand = verificationCommand
        self.budgetCeilingUSD = max(0.0, budgetCeilingUSD)
        self.promptBrief = promptBrief
    }

    public func toRelayTaskNode() -> RelayTaskNode {
        RelayTaskNode(
            id: stageID,
            title: title,
            vendor: vendor,
            laneID: laneID,
            dependsOnTaskIDs: dependsOnStageIDs,
            promptBrief: promptBrief,
            inputHandoffFiles: inputArtifacts,
            outputHandoffFiles: outputArtifacts,
            allowedWriteGlobs: ownershipRule.allowedGlobs,
            verificationShellCommand: verificationCommand,
            maxBudgetUSD: budgetCeilingUSD
        )
    }
}

public struct RelayKickoffSpecification: Sendable, Codable, Hashable {
    public var pipelineTitle: String
    public var repositoryPath: String
    public var baseBranch: String
    public var conductorVendor: AgentVendor
    public var enforceAntiRecursionGuard: Bool
    public var globalBudgetCeilingUSD: Double
    public var stages: [RelayKickoffStageContract]

    public init(
        pipelineTitle: String,
        repositoryPath: String,
        baseBranch: String = "main",
        conductorVendor: AgentVendor = .claudeCode,
        enforceAntiRecursionGuard: Bool = true,
        globalBudgetCeilingUSD: Double = 25.0,
        stages: [RelayKickoffStageContract]
    ) {
        self.pipelineTitle = pipelineTitle
        self.repositoryPath = repositoryPath
        self.baseBranch = baseBranch
        self.conductorVendor = conductorVendor
        self.enforceAntiRecursionGuard = enforceAntiRecursionGuard
        self.globalBudgetCeilingUSD = max(0.0, globalBudgetCeilingUSD)
        self.stages = stages.sorted { $0.stageNumber < $1.stageNumber }
    }

    public func toRelayDAGSpec() -> RelayDAGSpec {
        RelayDAGSpec(
            name: pipelineTitle,
            repositoryPath: repositoryPath,
            baseBranch: baseBranch,
            tasks: stages.map { $0.toRelayTaskNode() },
            globalBudgetCeilingUSD: globalBudgetCeilingUSD
        )
    }

    /// Canonical 4-vendor sequential/diamond relay blueprint (`Claude Code` -> `Codex` -> `Mistral Vibe` -> `AGY`).
    public static func standardFourVendorPipeline(
        title: String,
        repositoryPath: String,
        baseBranch: String = "main"
    ) -> RelayKickoffSpecification {
        let stages: [RelayKickoffStageContract] = [
            RelayKickoffStageContract(
                stageNumber: 1,
                stageID: "stage-1-claude-arch",
                title: "Core Architecture & Domain Implementation",
                vendor: .claudeCode,
                laneID: "lane-claude-code",
                dependsOnStageIDs: [],
                inputArtifacts: [],
                outputArtifacts: [".relay/stage-1-api-contract.json"],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Sources/**", ".relay/**"],
                    forbiddenGlobs: [".git/**", "Tests/**", "docs/**"]
                ),
                verificationCommand: "swift build",
                budgetCeilingUSD: 8.0,
                promptBrief: "Implement core domain models and write .relay/stage-1-api-contract.json"
            ),
            RelayKickoffStageContract(
                stageNumber: 2,
                stageID: "stage-2-codex-engines",
                title: "Systems Engines & Edge-Case Optimization",
                vendor: .codex,
                laneID: "lane-codex-exec",
                dependsOnStageIDs: ["stage-1-claude-arch"],
                inputArtifacts: [".relay/stage-1-api-contract.json"],
                outputArtifacts: [".relay/stage-2-engine-manifest.json"],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Sources/**", ".relay/**"],
                    forbiddenGlobs: [".git/**", "docs/**"]
                ),
                verificationCommand: "swift build",
                budgetCeilingUSD: 7.0,
                promptBrief: "Consume .relay/stage-1-api-contract.json and implement performance-critical engines"
            ),
            RelayKickoffStageContract(
                stageNumber: 3,
                stageID: "stage-3-vibe-tests",
                title: "Property & Regression Test Suite",
                vendor: .mistralVibe,
                laneID: "lane-vibe-tests",
                dependsOnStageIDs: ["stage-2-codex-engines"],
                inputArtifacts: [".relay/stage-1-api-contract.json", ".relay/stage-2-engine-manifest.json"],
                outputArtifacts: [".relay/stage-3-test-report.json"],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["Tests/**", ".relay/**"],
                    forbiddenGlobs: [".git/**", "Sources/**"]
                ),
                verificationCommand: "swift test",
                budgetCeilingUSD: 5.0,
                promptBrief: "Write exhaustive unit and property tests against stage-1 and stage-2 contracts"
            ),
            RelayKickoffStageContract(
                stageNumber: 4,
                stageID: "stage-4-agy-docs",
                title: "Architecture Documentation & Release Audit",
                vendor: .antigravity,
                laneID: "lane-agy-docs",
                dependsOnStageIDs: ["stage-3-vibe-tests"],
                inputArtifacts: [".relay/stage-2-engine-manifest.json", ".relay/stage-3-test-report.json"],
                outputArtifacts: ["docs/ARCHITECTURE.md", ".relay/stage-4-release-summary.md"],
                ownershipRule: FileOwnershipRule(
                    allowedGlobs: ["docs/**", "README.md", ".relay/**"],
                    forbiddenGlobs: [".git/**", "Sources/**", "Tests/**"]
                ),
                verificationCommand: "test -s docs/ARCHITECTURE.md",
                budgetCeilingUSD: 5.0,
                promptBrief: "Synthesize architecture docs and release audit from verified upstream artifacts"
            )
        ]

        return RelayKickoffSpecification(
            pipelineTitle: title,
            repositoryPath: repositoryPath,
            baseBranch: baseBranch,
            conductorVendor: .claudeCode,
            enforceAntiRecursionGuard: true,
            globalBudgetCeilingUSD: 25.0,
            stages: stages
        )
    }
}

public struct RelayHandoffLogStep: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(stepNumber):\(stageID)" }
    public let stepNumber: Int
    public let stageID: String
    public let vendor: AgentVendor
    public let laneID: String
    public let timestampISO8601: String
    public let headCommitOID: String?
    public let exitCode: Int32
    public let status: RelayHandoffStepStatus
    public let producedArtifacts: [RelayArtifactDigestEntry]
    public let modifiedPaths: [String]
    public let verificationCommand: String?
    public let handoffNotes: String

    public init(
        stepNumber: Int,
        stageID: String,
        vendor: AgentVendor,
        laneID: String,
        timestampISO8601: String,
        headCommitOID: String? = nil,
        exitCode: Int32 = 0,
        status: RelayHandoffStepStatus = .handoffReady,
        producedArtifacts: [RelayArtifactDigestEntry] = [],
        modifiedPaths: [String] = [],
        verificationCommand: String? = nil,
        handoffNotes: String = ""
    ) {
        self.stepNumber = max(1, stepNumber)
        self.stageID = stageID
        self.vendor = vendor
        self.laneID = laneID
        self.timestampISO8601 = timestampISO8601
        self.headCommitOID = headCommitOID
        self.exitCode = exitCode
        self.status = status
        self.producedArtifacts = producedArtifacts
        self.modifiedPaths = modifiedPaths
        self.verificationCommand = verificationCommand
        self.handoffNotes = handoffNotes
    }
}

public struct RelayHandoffLedgerDocument: Sendable, Codable, Hashable {
    public var pipelineTitle: String
    public var repositoryPath: String
    public var createdAtISO8601: String
    public var steps: [RelayHandoffLogStep]

    public init(
        pipelineTitle: String,
        repositoryPath: String,
        createdAtISO8601: String,
        steps: [RelayHandoffLogStep] = []
    ) {
        self.pipelineTitle = pipelineTitle
        self.repositoryPath = repositoryPath
        self.createdAtISO8601 = createdAtISO8601
        self.steps = steps.sorted { $0.stepNumber < $1.stepNumber }
    }
}

// MARK: - Anti-Recursion Worker Guardrail (`RELAY_WORKER_ACTIVE=1`)

public enum RelayRecursionGuardViolation: String, Sendable, Codable, Hashable {
    case workerAlreadyActive = "RELAY_WORKER_ACTIVE=1 detected: worker agents must never recursively invoke the relay conductor"
    case maxRelayDepthExceeded = "RELAY_DEPTH exceeded maximum permitted nesting depth"
    case conductorCredentialsExposedInWorker = "Conductor control token detected inside isolated worker environment"
}

public struct RelayRecursionCheckReport: Sendable, Codable, Hashable {
    public let isPermittedToLaunchRelay: Bool
    public let isInsideActiveWorker: Bool
    public let detectedDepth: Int
    public let activeStageID: String?
    public let activeLaneID: String?
    public let violations: [RelayRecursionGuardViolation]

    public init(
        isPermittedToLaunchRelay: Bool,
        isInsideActiveWorker: Bool,
        detectedDepth: Int,
        activeStageID: String?,
        activeLaneID: String?,
        violations: [RelayRecursionGuardViolation]
    ) {
        self.isPermittedToLaunchRelay = isPermittedToLaunchRelay
        self.isInsideActiveWorker = isInsideActiveWorker
        self.detectedDepth = detectedDepth
        self.activeStageID = activeStageID
        self.activeLaneID = activeLaneID
        self.violations = violations
    }
}

public struct RelayWorkerRecursionGuard: Sendable {
    public static let workerActiveEnvKey = "RELAY_WORKER_ACTIVE"
    public static let relayDepthEnvKey = "RELAY_DEPTH"
    public static let relayStageIDEnvKey = "RELAY_STAGE_ID"
    public static let relayLaneIDEnvKey = "RELAY_LANE_ID"
    public static let relayVendorEnvKey = "RELAY_VENDOR"
    public static let relayAllowedGlobsEnvKey = "RELAY_ALLOWED_GLOBS"
    public static let relayForbiddenGlobsEnvKey = "RELAY_FORBIDDEN_GLOBS"

    public let maxAllowedDepth: Int

    public init(maxAllowedDepth: Int = 1) {
        self.maxAllowedDepth = max(1, maxAllowedDepth)
    }

    /// Evaluates an environment dictionary to block worker-inside-worker relay套娃 recursion.
    public func evaluateConductorEligibility(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RelayRecursionCheckReport {
        let workerFlag = environment[Self.workerActiveEnvKey]?.trimmingCharacters(in: .whitespaces).lowercased()
        let isWorker = (workerFlag == "1" || workerFlag == "true" || workerFlag == "yes")
        let depth = Int(environment[Self.relayDepthEnvKey] ?? "0") ?? 0
        let stageID = environment[Self.relayStageIDEnvKey]
        let laneID = environment[Self.relayLaneIDEnvKey]

        var violations: [RelayRecursionGuardViolation] = []
        if isWorker {
            violations.append(.workerAlreadyActive)
        }
        if depth >= maxAllowedDepth {
            violations.append(.maxRelayDepthExceeded)
        }

        return RelayRecursionCheckReport(
            isPermittedToLaunchRelay: violations.isEmpty,
            isInsideActiveWorker: isWorker,
            detectedDepth: depth,
            activeStageID: stageID,
            activeLaneID: laneID,
            violations: violations
        )
    }

    /// Constructs a sanitized environment for a headless worker CLI (`claude`, `codex`, `vibe`, `agy`), stamping `RELAY_WORKER_ACTIVE=1`.
    public func buildWorkerEnvironment(
        inheritingFrom baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        stage: RelayKickoffStageContract
    ) -> [String: String] {
        var env = baseEnv
        // Strip conductor-only tokens so child agents cannot impersonate the orchestrator
        env.removeValue(forKey: "RELAY_CONDUCTOR_SECRET")
        env.removeValue(forKey: "RELAY_ALLOW_NESTED_SPAWN")

        let parentDepth = Int(baseEnv[Self.relayDepthEnvKey] ?? "0") ?? 0
        env[Self.workerActiveEnvKey] = "1"
        env[Self.relayDepthEnvKey] = "\(parentDepth + 1)"
        env[Self.relayStageIDEnvKey] = stage.stageID
        env[Self.relayLaneIDEnvKey] = stage.laneID
        env[Self.relayVendorEnvKey] = stage.vendor.rawValue
        env[Self.relayAllowedGlobsEnvKey] = stage.ownershipRule.allowedGlobs.joined(separator: ",")
        env[Self.relayForbiddenGlobsEnvKey] = stage.ownershipRule.forbiddenGlobs.joined(separator: ",")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["CI"] = "1"

        return env
    }
}

// MARK: - Handoff Validation Issue & Audit Report

public enum RelayHandoffValidationSeverity: String, Sendable, Codable, Hashable {
    case warning = "WARNING"
    case error = "ERROR"
}

public struct RelayHandoffValidationFinding: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let severity: RelayHandoffValidationSeverity
    public let stageID: String?
    public let artifactOrPath: String?
    public let code: String
    public let message: String

    public init(
        id: UUID = UUID(),
        severity: RelayHandoffValidationSeverity,
        stageID: String? = nil,
        artifactOrPath: String? = nil,
        code: String,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.stageID = stageID
        self.artifactOrPath = artifactOrPath
        self.code = code
        self.message = message
    }
}

public struct RelayHandoffValidationReport: Sendable, Codable, Hashable {
    public let isValid: Bool
    public let verifiedArtifactCount: Int
    public let verifiedDigestMatches: Int
    public let ownershipViolationsCount: Int
    public let findings: [RelayHandoffValidationFinding]

    public init(
        verifiedArtifactCount: Int,
        verifiedDigestMatches: Int,
        ownershipViolationsCount: Int,
        findings: [RelayHandoffValidationFinding]
    ) {
        self.verifiedArtifactCount = verifiedArtifactCount
        self.verifiedDigestMatches = verifiedDigestMatches
        self.ownershipViolationsCount = ownershipViolationsCount
        self.findings = findings
        self.isValid = !findings.contains { $0.severity == .error }
    }
}

// MARK: - Deterministic Parser, Generator & SHA-256 Validator (`RelayHandoffProtocolCodec`)

public struct RelayHandoffProtocolCodec: Sendable {
    public let recursionGuard: RelayWorkerRecursionGuard

    public init(recursionGuard: RelayWorkerRecursionGuard = RelayWorkerRecursionGuard()) {
        self.recursionGuard = recursionGuard
    }

    // MARK: - SHA-256 Digest Helpers

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofString text: String) -> String {
        sha256Hex(of: Data(text.utf8))
    }

    public func computeArtifactDigest(workspaceRoot: String, relativePath: String) throws -> RelayArtifactDigestEntry {
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RelayIDEError.invalidCLIUsage("Handoff artifact missing at '\(relativePath)'")
        }
        let data = try Data(contentsOf: fileURL)
        return RelayArtifactDigestEntry(
            relativePath: relativePath,
            byteSize: Int64(data.count),
            sha256Hex: Self.sha256Hex(of: data)
        )
    }

    // MARK: - Deterministic `RELAY_KICKOFF.md` Generator & Parser

    public func generateKickoffMarkdown(_ spec: RelayKickoffSpecification) -> String {
        var lines: [String] = []
        lines.append("# RELAY_KICKOFF: \(spec.pipelineTitle)")
        lines.append("")
        lines.append("- **Repository**: `\(spec.repositoryPath)`")
        lines.append("- **Base Branch**: `\(spec.baseBranch)`")
        lines.append("- **Conductor**: `\(spec.conductorVendor.rawValue)` (\(spec.conductorVendor.displayName))")
        lines.append("- **Anti-Recursion Guard**: `\(spec.enforceAntiRecursionGuard ? "RELAY_WORKER_ACTIVE=1" : "disabled")`")
        lines.append(String(format: "- **Global Budget Ceiling**: `$%.2f`", spec.globalBudgetCeilingUSD))
        lines.append("")
        lines.append("## Stage Roster")
        lines.append("")
        lines.append("| # | Stage ID | Vendor | Lane | Depends On | Budget |")
        lines.append("|---|---|---|---|---|---|")
        for st in spec.stages {
            let deps = st.dependsOnStageIDs.isEmpty ? "—" : st.dependsOnStageIDs.joined(separator: ", ")
            lines.append(String(
                format: "| %d | `%@` | `%@` | `%@` | %@ | $%.2f |",
                st.stageNumber, st.stageID, st.vendor.rawValue, st.laneID, deps, st.budgetCeilingUSD
            ))
        }
        lines.append("")

        for st in spec.stages {
            lines.append("## Stage \(st.stageNumber): \(st.stageID)")
            lines.append("- **Title**: \(st.title)")
            lines.append("- **Vendor**: `\(st.vendor.rawValue)`")
            lines.append("- **Lane**: `\(st.laneID)`")
            lines.append("- **Depends-On**: \(Self.formatCSVList(st.dependsOnStageIDs))")
            lines.append("- **Input-Artifacts**: \(Self.formatCSVList(st.inputArtifacts))")
            lines.append("- **Output-Artifacts**: \(Self.formatCSVList(st.outputArtifacts))")
            lines.append("- **Allowed-Globs**: \(Self.formatCSVList(st.ownershipRule.allowedGlobs))")
            lines.append("- **Forbidden-Globs**: \(Self.formatCSVList(st.ownershipRule.forbiddenGlobs))")
            lines.append("- **Read-Only-Verifier**: `\(st.ownershipRule.isReadOnlyVerifier ? "true" : "false")`")
            lines.append("- **Verify-Command**: `\(st.verificationCommand ?? "none")`")
            lines.append(String(format: "- **Budget-USD**: `%.2f`", st.budgetCeilingUSD))
            lines.append("- **Brief**: \(st.promptBrief)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public func parseKickoffMarkdown(_ markdown: String) throws -> RelayKickoffSpecification {
        let rawLines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var pipelineTitle = "Untitled Relay Pipeline"
        var repoPath = "."
        var baseBranch = "main"
        var conductor: AgentVendor = .claudeCode
        var enforceGuard = true
        var globalBudget = 25.0

        var stages: [RelayKickoffStageContract] = []

        // Parse top-level metadata and `## Stage N: <stageID>` sections
        var idx = 0
        while idx < rawLines.count {
            let trimmed = rawLines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# RELAY_KICKOFF:") {
                pipelineTitle = String(trimmed.dropFirst("# RELAY_KICKOFF:".count)).trimmingCharacters(in: .whitespaces)
                idx += 1
                continue
            }

            if trimmed.hasPrefix("## Stage ") {
                let headerBody = String(trimmed.dropFirst("## Stage ".count))
                if let colonIdx = headerBody.firstIndex(of: ":") {
                    let numStr = String(headerBody[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let stageNum = Int(numStr) ?? (stages.count + 1)
                    let stageID = Self.stripCodeTicks(String(headerBody[headerBody.index(after: colonIdx)...]))

                    var kv: [String: String] = [:]
                    idx += 1
                    while idx < rawLines.count {
                        let sub = rawLines[idx].trimmingCharacters(in: .whitespaces)
                        if sub.hasPrefix("## ") { break }
                        if let (k, v) = Self.parseMarkdownBulletKV(sub) {
                            kv[k.lowercased()] = v
                        }
                        idx += 1
                    }

                    let vendorStr = Self.stripCodeTicks(kv["vendor"] ?? "claude")
                    let vendor = Self.resolveVendor(vendorStr)
                    let laneID = Self.stripCodeTicks(kv["lane"] ?? "lane-\(stageID)")
                    let title = kv["title"] ?? stageID
                    let deps = Self.parseCSVList(kv["depends-on"] ?? "")
                    let inputs = Self.parseCSVList(kv["input-artifacts"] ?? "")
                    let outputs = Self.parseCSVList(kv["output-artifacts"] ?? "")
                    let allowed = Self.parseCSVList(kv["allowed-globs"] ?? "**")
                    let forbidden = Self.parseCSVList(kv["forbidden-globs"] ?? ".git/**")
                    let isRO = Self.stripCodeTicks(kv["read-only-verifier"] ?? "false").lowercased() == "true"
                    let verifyRaw = Self.stripCodeTicks(kv["verify-command"] ?? "none")
                    let verifyCmd = (verifyRaw.isEmpty || verifyRaw == "none") ? nil : verifyRaw
                    let budget = Double(Self.stripCodeTicks(kv["budget-usd"] ?? "5.0").replacingOccurrences(of: "$", with: "")) ?? 5.0
                    let brief = kv["brief"] ?? ""

                    stages.append(
                        RelayKickoffStageContract(
                            stageNumber: stageNum,
                            stageID: stageID,
                            title: title,
                            vendor: vendor,
                            laneID: laneID,
                            dependsOnStageIDs: deps,
                            inputArtifacts: inputs,
                            outputArtifacts: outputs,
                            ownershipRule: FileOwnershipRule(
                                allowedGlobs: allowed.isEmpty ? ["**"] : allowed,
                                forbiddenGlobs: forbidden,
                                isReadOnlyVerifier: isRO
                            ),
                            verificationCommand: verifyCmd,
                            budgetCeilingUSD: budget,
                            promptBrief: brief
                        )
                    )
                    continue
                }
            }

            if let (key, val) = Self.parseMarkdownBulletKV(trimmed) {
                switch key.lowercased() {
                case "repository":
                    repoPath = Self.stripCodeTicks(val)
                case "base branch":
                    baseBranch = Self.stripCodeTicks(val)
                case "conductor":
                    let token = val.split(separator: " ").first.map(String.init) ?? val
                    conductor = Self.resolveVendor(Self.stripCodeTicks(token))
                case "anti-recursion guard":
                    enforceGuard = !Self.stripCodeTicks(val).lowercased().contains("disabled")
                case "global budget ceiling":
                    let cleaned = Self.stripCodeTicks(val).replacingOccurrences(of: "$", with: "")
                    globalBudget = Double(cleaned) ?? 25.0
                default:
                    break
                }
            }

            idx += 1
        }

        guard !stages.isEmpty else {
            throw RelayIDEError.invalidCLIUsage("RELAY_KICKOFF.md contains zero `## Stage N: <id>` stage definitions")
        }

        return RelayKickoffSpecification(
            pipelineTitle: pipelineTitle,
            repositoryPath: repoPath,
            baseBranch: baseBranch,
            conductorVendor: conductor,
            enforceAntiRecursionGuard: enforceGuard,
            globalBudgetCeilingUSD: globalBudget,
            stages: stages
        )
    }

    // MARK: - Deterministic `.relay/LOG.md` Generator & Parser

    public func generateHandoffLogMarkdown(_ ledger: RelayHandoffLedgerDocument) -> String {
        var lines: [String] = []
        lines.append("# RELAY HANDOFF LOG: \(ledger.pipelineTitle)")
        lines.append("")
        lines.append("- **Repository**: `\(ledger.repositoryPath)`")
        lines.append("- **Created-At**: `\(ledger.createdAtISO8601)`")
        lines.append("- **Total-Steps**: `\(ledger.steps.count)`")
        lines.append("")

        for step in ledger.steps {
            lines.append("## Step \(step.stepNumber): \(step.stageID)")
            lines.append("- **Vendor**: `\(step.vendor.rawValue)`")
            lines.append("- **Lane**: `\(step.laneID)`")
            lines.append("- **Timestamp**: `\(step.timestampISO8601)`")
            lines.append("- **Status**: `\(step.status.rawValue)`")
            lines.append("- **Exit-Code**: `\(step.exitCode)`")
            lines.append("- **Commit-OID**: `\(step.headCommitOID ?? "uncommitted")`")
            lines.append("- **Verify-Command**: `\(step.verificationCommand ?? "none")`")
            lines.append("- **Modified-Paths**: \(Self.formatCSVList(step.modifiedPaths))")
            lines.append("- **Notes**: \(step.handoffNotes.isEmpty ? "none" : step.handoffNotes)")
            lines.append("### Artifacts")
            if step.producedArtifacts.isEmpty {
                lines.append("- _none_")
            } else {
                for art in step.producedArtifacts {
                    lines.append("- `\(art.relativePath)` | bytes=`\(art.byteSize)` | sha256=`\(art.sha256Hex)`")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public func parseHandoffLogMarkdown(_ markdown: String) throws -> RelayHandoffLedgerDocument {
        let rawLines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var pipelineTitle = "Relay Log"
        var repoPath = "."
        var createdISO = ""
        var steps: [RelayHandoffLogStep] = []

        var idx = 0
        while idx < rawLines.count {
            let trimmed = rawLines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# RELAY HANDOFF LOG:") {
                pipelineTitle = String(trimmed.dropFirst("# RELAY HANDOFF LOG:".count)).trimmingCharacters(in: .whitespaces)
                idx += 1
                continue
            }

            if trimmed.hasPrefix("## Step ") {
                let hdr = String(trimmed.dropFirst("## Step ".count))
                if let colon = hdr.firstIndex(of: ":") {
                    let stepNum = Int(String(hdr[..<colon]).trimmingCharacters(in: .whitespaces)) ?? (steps.count + 1)
                    let stageID = Self.stripCodeTicks(String(hdr[hdr.index(after: colon)...]))

                    var kv: [String: String] = [:]
                    var artifacts: [RelayArtifactDigestEntry] = []
                    var inArtifactsBlock = false

                    idx += 1
                    while idx < rawLines.count {
                        let sub = rawLines[idx].trimmingCharacters(in: .whitespaces)
                        if sub.hasPrefix("## Step ") { break }
                        if sub == "### Artifacts" {
                            inArtifactsBlock = true
                            idx += 1
                            continue
                        }
                        if inArtifactsBlock {
                            if let art = Self.parseArtifactDigestLine(sub) {
                                artifacts.append(art)
                            }
                        } else if let (k, v) = Self.parseMarkdownBulletKV(sub) {
                            kv[k.lowercased()] = v
                        }
                        idx += 1
                    }

                    let vendor = Self.resolveVendor(Self.stripCodeTicks(kv["vendor"] ?? "claude"))
                    let laneID = Self.stripCodeTicks(kv["lane"] ?? "lane-\(stageID)")
                    let ts = Self.stripCodeTicks(kv["timestamp"] ?? "")
                    let statusRaw = Self.stripCodeTicks(kv["status"] ?? RelayHandoffStepStatus.handoffReady.rawValue)
                    let status = RelayHandoffStepStatus(rawValue: statusRaw) ?? .handoffReady
                    let exitCode = Int32(Self.stripCodeTicks(kv["exit-code"] ?? "0")) ?? 0
                    let oidRaw = Self.stripCodeTicks(kv["commit-oid"] ?? "uncommitted")
                    let commitOID = (oidRaw.isEmpty || oidRaw == "uncommitted") ? nil : oidRaw
                    let verifyRaw = Self.stripCodeTicks(kv["verify-command"] ?? "none")
                    let verifyCmd = (verifyRaw.isEmpty || verifyRaw == "none") ? nil : verifyRaw
                    let modPaths = Self.parseCSVList(kv["modified-paths"] ?? "")
                    let notesRaw = kv["notes"] ?? ""
                    let notes = notesRaw == "none" ? "" : notesRaw

                    steps.append(
                        RelayHandoffLogStep(
                            stepNumber: stepNum,
                            stageID: stageID,
                            vendor: vendor,
                            laneID: laneID,
                            timestampISO8601: ts,
                            headCommitOID: commitOID,
                            exitCode: exitCode,
                            status: status,
                            producedArtifacts: artifacts,
                            modifiedPaths: modPaths,
                            verificationCommand: verifyCmd,
                            handoffNotes: notes
                        )
                    )
                    continue
                }
            }

            if let (k, v) = Self.parseMarkdownBulletKV(trimmed) {
                switch k.lowercased() {
                case "repository": repoPath = Self.stripCodeTicks(v)
                case "created-at": createdISO = Self.stripCodeTicks(v)
                default: break
                }
            }

            idx += 1
        }

        return RelayHandoffLedgerDocument(
            pipelineTitle: pipelineTitle,
            repositoryPath: repoPath,
            createdAtISO8601: createdISO,
            steps: steps
        )
    }

    // MARK: - End-to-End Handoff Contract, SHA-256 Digest & Ownership Validator

    /// Validates `.relay/LOG.md` handoff steps against `RELAY_KICKOFF.md` contracts, live on-disk artifact SHA-256 digests, lane ownership rules, and anti-recursion environment flags.
    public func validateHandoffPipeline(
        kickoff: RelayKickoffSpecification,
        ledger: RelayHandoffLedgerDocument,
        workspaceRootPath: String? = nil,
        conductorEnvironment: [String: String]? = nil
    ) -> RelayHandoffValidationReport {
        var findings: [RelayHandoffValidationFinding] = []
        var verifiedArtifacts = 0
        var verifiedDigests = 0
        var ownershipViolations = 0

        // 1. Verify anti-recursion guard when conductor environment is supplied
        if kickoff.enforceAntiRecursionGuard, let env = conductorEnvironment {
            let recCheck = recursionGuard.evaluateConductorEligibility(environment: env)
            for v in recCheck.violations {
                findings.append(
                    RelayHandoffValidationFinding(
                        severity: .error,
                        stageID: recCheck.activeStageID,
                        code: "ANTI_RECURSION_GUARD",
                        message: v.rawValue
                    )
                )
            }
        }

        // 2. Index stages and check DAG dependency references
        var stageByID: [String: RelayKickoffStageContract] = [:]
        for st in kickoff.stages {
            if stageByID[st.stageID] != nil {
                findings.append(
                    RelayHandoffValidationFinding(
                        severity: .error,
                        stageID: st.stageID,
                        code: "DUPLICATE_STAGE_ID",
                        message: "Duplicate stage ID '\(st.stageID)' in RELAY_KICKOFF.md"
                    )
                )
            }
            stageByID[st.stageID] = st
        }
        for st in kickoff.stages {
            for dep in st.dependsOnStageIDs where stageByID[dep] == nil {
                findings.append(
                    RelayHandoffValidationFinding(
                        severity: .error,
                        stageID: st.stageID,
                        code: "UNKNOWN_STAGE_DEPENDENCY",
                        message: "Stage '\(st.stageID)' depends on unknown stage '\(dep)'"
                    )
                )
            }
        }

        // 3. Validate each recorded handoff step against its stage contract, ownership rules, and SHA-256 artifact digests
        var completedStageIDs = Set<String>()
        var producedArtifactSet = Set<String>()
        let effectiveRoot = workspaceRootPath ?? kickoff.repositoryPath

        for step in ledger.steps {
            guard let contract = stageByID[step.stageID] else {
                findings.append(
                    RelayHandoffValidationFinding(
                        severity: .warning,
                        stageID: step.stageID,
                        code: "UNDECLARED_LOG_STAGE",
                        message: "Log step '\(step.stageID)' is not declared in RELAY_KICKOFF.md"
                    )
                )
                continue
            }

            if step.vendor != contract.vendor {
                findings.append(
                    RelayHandoffValidationFinding(
                        severity: .error,
                        stageID: step.stageID,
                        code: "VENDOR_MISMATCH",
                        message: "Stage '\(step.stageID)' assigned to '\(contract.vendor.rawValue)' but executed by '\(step.vendor.rawValue)'"
                    )
                )
            }

            // Ensure upstream dependencies finished before this step
            for depID in contract.dependsOnStageIDs where !completedStageIDs.contains(depID) {
                findings.append(
                    RelayHandoffValidationFinding(
                        severity: .error,
                        stageID: step.stageID,
                        code: "UPSTREAM_DEPENDENCY_INCOMPLETE",
                        message: "Stage '\(step.stageID)' ran before upstream dependency '\(depID)' completed"
                    )
                )
            }

            // Ensure required input handoff artifacts were already produced or exist on disk
            for reqInput in contract.inputArtifacts {
                let existsOnDisk: Bool
                if workspaceRootPath != nil {
                    let full = URL(fileURLWithPath: effectiveRoot).appendingPathComponent(reqInput).path
                    existsOnDisk = FileManager.default.fileExists(atPath: full)
                } else {
                    existsOnDisk = true
                }
                if !producedArtifactSet.contains(reqInput) && !existsOnDisk {
                    findings.append(
                        RelayHandoffValidationFinding(
                            severity: .error,
                            stageID: step.stageID,
                            artifactOrPath: reqInput,
                            code: "MISSING_INPUT_ARTIFACT",
                            message: "Required input handoff file '\(reqInput)' was not produced prior to '\(step.stageID)'"
                        )
                    )
                }
            }

            // Ownership contract audit across all `modifiedPaths`
            for modifiedPath in step.modifiedPaths {
                let verdict = GlobPatternMatcher.evaluateOwnership(
                    relativePath: modifiedPath,
                    rule: contract.ownershipRule
                )
                if !verdict.allowed {
                    ownershipViolations += 1
                    findings.append(
                        RelayHandoffValidationFinding(
                            severity: .error,
                            stageID: step.stageID,
                            artifactOrPath: modifiedPath,
                            code: "LANE_OWNERSHIP_VIOLATION",
                            message: "Lane '\(step.laneID)' (\(step.vendor.displayName)) modified '\(modifiedPath)': \(verdict.reason)"
                        )
                    )
                }
            }

            // Verify declared output artifacts exist in step manifest and match live disk SHA-256 digests
            var stepArtifactByPath: [String: RelayArtifactDigestEntry] = [:]
            for art in step.producedArtifacts {
                stepArtifactByPath[art.relativePath] = art
                producedArtifactSet.insert(art.relativePath)
            }

            if step.status == .completed || step.status == .handoffReady {
                if step.exitCode != 0 {
                    findings.append(
                        RelayHandoffValidationFinding(
                            severity: .error,
                            stageID: step.stageID,
                            code: "NONZERO_EXIT_MARKED_COMPLETE",
                            message: "Stage '\(step.stageID)' marked \(step.status.rawValue) despite exit code \(step.exitCode)"
                        )
                    )
                }

                for expectedOut in contract.outputArtifacts {
                    guard let recorded = stepArtifactByPath[expectedOut] else {
                        findings.append(
                            RelayHandoffValidationFinding(
                                severity: .error,
                                stageID: step.stageID,
                                artifactOrPath: expectedOut,
                                code: "MISSING_OUTPUT_MANIFEST_ENTRY",
                                message: "Stage '\(step.stageID)' did not record expected output artifact '\(expectedOut)' in .relay/LOG.md"
                            )
                        )
                        continue
                    }
                    verifiedArtifacts += 1

                    if workspaceRootPath != nil {
                        let absPath = URL(fileURLWithPath: effectiveRoot).appendingPathComponent(expectedOut).path
                        if !FileManager.default.fileExists(atPath: absPath) {
                            findings.append(
                                RelayHandoffValidationFinding(
                                    severity: .error,
                                    stageID: step.stageID,
                                    artifactOrPath: expectedOut,
                                    code: "MISSING_DISK_ARTIFACT",
                                    message: "Handoff artifact '\(expectedOut)' missing on disk at '\(absPath)'"
                                )
                            )
                        } else if let diskDigest = try? computeArtifactDigest(workspaceRoot: effectiveRoot, relativePath: expectedOut) {
                            if diskDigest.sha256Hex != recorded.sha256Hex {
                                findings.append(
                                    RelayHandoffValidationFinding(
                                        severity: .error,
                                        stageID: step.stageID,
                                        artifactOrPath: expectedOut,
                                        code: "SHA256_DIGEST_MISMATCH",
                                        message: "Artifact '\(expectedOut)' SHA-256 mismatch: log=\(recorded.sha256Hex.prefix(12))… vs disk=\(diskDigest.sha256Hex.prefix(12))…"
                                    )
                                )
                            } else if diskDigest.byteSize != recorded.byteSize {
                                findings.append(
                                    RelayHandoffValidationFinding(
                                        severity: .warning,
                                        stageID: step.stageID,
                                        artifactOrPath: expectedOut,
                                        code: "BYTE_SIZE_MISMATCH",
                                        message: "Artifact '\(expectedOut)' byte count mismatch (\(recorded.byteSize) vs \(diskDigest.byteSize))"
                                    )
                                )
                            } else {
                                verifiedDigests += 1
                            }
                        }
                    }
                }

                completedStageIDs.insert(step.stageID)
            }
        }

        return RelayHandoffValidationReport(
            verifiedArtifactCount: verifiedArtifacts,
            verifiedDigestMatches: verifiedDigests,
            ownershipViolationsCount: ownershipViolations,
            findings: findings
        )
    }

    // MARK: - Formatting & Parsing Helpers

    private static func formatCSVList(_ items: [String]) -> String {
        if items.isEmpty { return "`none`" }
        return items.map { "`\($0)`" }.joined(separator: ", ")
    }

    private static func parseCSVList(_ raw: String) -> [String] {
        let stripped = stripCodeTicks(raw)
        if stripped.isEmpty || stripped.lowercased() == "none" || stripped == "—" {
            return []
        }
        return raw
            .split(separator: ",")
            .map { stripCodeTicks(String($0)) }
            .filter { !$0.isEmpty && $0.lowercased() != "none" && $0 != "—" }
    }

    private static func stripCodeTicks(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "` \t\r\n"))
    }

    private static func parseMarkdownBulletKV(_ line: String) -> (String, String)? {
        guard line.hasPrefix("- **"), let closeBold = line.range(of: "**:") else {
            return nil
        }
        let keyStart = line.index(line.startIndex, offsetBy: 4)
        let key = String(line[keyStart..<closeBold.lowerBound]).trimmingCharacters(in: .whitespaces)
        let value = String(line[closeBold.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func parseArtifactDigestLine(_ line: String) -> RelayArtifactDigestEntry? {
        guard line.hasPrefix("- ") && line.contains("sha256=") else { return nil }
        let parts = line.dropFirst(2).split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let path = stripCodeTicks(parts[0])
        var byteSize: Int64 = 0
        var sha = ""
        for p in parts.dropFirst() {
            if p.hasPrefix("bytes=") {
                byteSize = Int64(stripCodeTicks(String(p.dropFirst("bytes=".count)))) ?? 0
            } else if p.hasPrefix("sha256=") {
                sha = stripCodeTicks(String(p.dropFirst("sha256=".count)))
            }
        }
        guard !path.isEmpty, !sha.isEmpty else { return nil }
        return RelayArtifactDigestEntry(relativePath: path, byteSize: byteSize, sha256Hex: sha)
    }

    private static func resolveVendor(_ raw: String) -> AgentVendor {
        let low = raw.lowercased()
        if let exact = AgentVendor(rawValue: low) {
            return exact
        }
        if low.contains("claude") || low == "cc" { return .claudeCode }
        if low.contains("codex") || low == "cx"  { return .codex }
        if low.contains("agy") || low.contains("antigravity") { return .antigravity }
        if low.contains("vibe") || low.contains("mistral") { return .mistralVibe }
        return .customShell
    }
}
