import CryptoKit
import Foundation
import RelayModels

// MARK: - Outbound Loopback Data-Loss-Prevention (DLP) Categories & Policy

public enum DLPSecretCategory: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case dotenvAssignment = "DOTENV_SECRET"
    case pemPrivateKey = "PEM_PRIVATE_KEY"
    case openSSHPrivateKey = "OPENSSH_PRIVATE_KEY"
    case anthropicAPIKey = "ANTHROPIC_API_KEY"
    case openAIAPIKey = "OPENAI_API_KEY"
    case googleGeminiAPIKey = "GOOGLE_API_KEY"
    case gitHubPAT = "GITHUB_PAT"
    case awsAccessKeyID = "AWS_ACCESS_KEY_ID"
    case awsSecretAccessKey = "AWS_SECRET_KEY"
    case stripeSecretKey = "STRIPE_LIVE_KEY"
    case slackToken = "SLACK_TOKEN"
    case jwtBearerToken = "JWT_TOKEN"
    case localMacOSSSHMaterial = "MACOS_SSH_MATERIAL"
    case localMacOSHomePath = "MACOS_USER_PATH"
    case databaseConnectionURI = "DATABASE_CREDENTIALS_URI"
    case highEntropySecret = "HIGH_ENTROPY_TOKEN"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .dotenvAssignment: return ".env Secret Assignment"
        case .pemPrivateKey: return "PEM Cryptographic Private Key"
        case .openSSHPrivateKey: return "OpenSSH Private Key Block"
        case .anthropicAPIKey: return "Anthropic API Key"
        case .openAIAPIKey: return "OpenAI Project / Secret Key"
        case .googleGeminiAPIKey: return "Google Cloud / Gemini API Key"
        case .gitHubPAT: return "GitHub Personal Access Token"
        case .awsAccessKeyID: return "AWS IAM Access Key ID"
        case .awsSecretAccessKey: return "AWS IAM Secret Access Key"
        case .stripeSecretKey: return "Stripe Live Secret / Restricted Key"
        case .slackToken: return "Slack Bot / User Token"
        case .jwtBearerToken: return "Signed JSON Web Token (JWT)"
        case .localMacOSSSHMaterial: return "Local /Users SSH Key or Config Path"
        case .localMacOSHomePath: return "Hardcoded macOS /Users Home Path"
        case .databaseConnectionURI: return "Database URI with Embedded Password"
        case .highEntropySecret: return "High-Entropy Bearer / Secret Token"
        }
    }

    public var defaultSeverity: GuardrailSeverity {
        switch self {
        case .pemPrivateKey, .openSSHPrivateKey, .stripeSecretKey, .localMacOSSSHMaterial, .databaseConnectionURI:
            return .blocker
        case .anthropicAPIKey, .openAIAPIKey, .googleGeminiAPIKey, .gitHubPAT, .awsAccessKeyID, .awsSecretAccessKey, .slackToken, .dotenvAssignment:
            return .blocker
        case .jwtBearerToken, .highEntropySecret:
            return .warning
        case .localMacOSHomePath:
            return .advisory
        }
    }
}

public enum DLPEnforcementMode: String, Sendable, Codable, Hashable, CaseIterable {
    case auditOnly = "AUDIT_ONLY"
    case redactInPlace = "REDACT_IN_PLACE"
    case blockOutboundPacket = "BLOCK_OUTBOUND"
}

public struct DLPPolicyConfiguration: Sendable, Codable, Hashable {
    public var isEnabled: Bool
    public var defaultMode: DLPEnforcementMode
    public var categoryOverrides: [DLPSecretCategory: DLPEnforcementMode]
    public var allowlistedSubstrings: [String]
    public var minimumHighEntropyBitsPerChar: Double
    public var redactLocalMacOSHomePaths: Bool
    public var maxAuditRingBufferCapacity: Int

    public init(
        isEnabled: Bool = true,
        defaultMode: DLPEnforcementMode = .redactInPlace,
        categoryOverrides: [DLPSecretCategory: DLPEnforcementMode] = DLPPolicyConfiguration.recommendedCategoryOverrides,
        allowlistedSubstrings: [String] = [
            "EXAMPLE",
            "DUMMY",
            "PLACEHOLDER",
            "sk-test-allowlisted",
            "AKIAIOSFODNN7EXAMPLE"
        ],
        minimumHighEntropyBitsPerChar: Double = 4.25,
        redactLocalMacOSHomePaths: Bool = false,
        maxAuditRingBufferCapacity: Int = 512
    ) {
        self.isEnabled = isEnabled
        self.defaultMode = defaultMode
        self.categoryOverrides = categoryOverrides
        self.allowlistedSubstrings = allowlistedSubstrings
        self.minimumHighEntropyBitsPerChar = minimumHighEntropyBitsPerChar
        self.redactLocalMacOSHomePaths = redactLocalMacOSHomePaths
        self.maxAuditRingBufferCapacity = max(16, maxAuditRingBufferCapacity)
    }

    public static let recommendedCategoryOverrides: [DLPSecretCategory: DLPEnforcementMode] = [
        .pemPrivateKey: .blockOutboundPacket,
        .openSSHPrivateKey: .blockOutboundPacket,
        .localMacOSSSHMaterial: .blockOutboundPacket,
        .stripeSecretKey: .blockOutboundPacket,
        .databaseConnectionURI: .redactInPlace,
        .anthropicAPIKey: .redactInPlace,
        .openAIAPIKey: .redactInPlace,
        .googleGeminiAPIKey: .redactInPlace,
        .gitHubPAT: .redactInPlace,
        .awsAccessKeyID: .redactInPlace,
        .awsSecretAccessKey: .redactInPlace,
        .slackToken: .redactInPlace,
        .dotenvAssignment: .redactInPlace,
        .jwtBearerToken: .redactInPlace,
        .highEntropySecret: .redactInPlace,
        .localMacOSHomePath: .auditOnly
    ]

    public func effectiveMode(for category: DLPSecretCategory) -> DLPEnforcementMode {
        if category == .localMacOSHomePath && redactLocalMacOSHomePaths {
            return .redactInPlace
        }
        return categoryOverrides[category] ?? defaultMode
    }
}

public struct DLPDetectionMatch: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let category: DLPSecretCategory
    public let severity: GuardrailSeverity
    public let enforcementApplied: DLPEnforcementMode
    public let jsonFieldPath: String
    public let maskedSample: String
    public let replacementToken: String
    public let shannonEntropy: Double
    public let secretFingerprintHex: String

    public init(
        id: UUID = UUID(),
        category: DLPSecretCategory,
        severity: GuardrailSeverity,
        enforcementApplied: DLPEnforcementMode,
        jsonFieldPath: String,
        maskedSample: String,
        replacementToken: String,
        shannonEntropy: Double,
        secretFingerprintHex: String
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.enforcementApplied = enforcementApplied
        self.jsonFieldPath = jsonFieldPath
        self.maskedSample = maskedSample
        self.replacementToken = replacementToken
        self.shannonEntropy = shannonEntropy
        self.secretFingerprintHex = secretFingerprintHex
    }
}

public enum DLPInspectionOutcome: String, Sendable, Codable, Hashable {
    case cleanPass = "CLEAN_PASS"
    case auditedPass = "AUDITED_PASS"
    case sanitizedAndForwarded = "SANITIZED_FORWARDED"
    case blockedBeforeLoopbackExit = "BLOCKED_AT_LOOPBACK"
}

public struct DLPInspectionVerdict: Sendable, Codable, Hashable {
    public let outcome: DLPInspectionOutcome
    public let matches: [DLPDetectionMatch]
    public let outputPayload: Data
    public let scanDurationMicros: Double
    public let peakEntropyObserved: Double

    public init(
        outcome: DLPInspectionOutcome,
        matches: [DLPDetectionMatch],
        outputPayload: Data,
        scanDurationMicros: Double,
        peakEntropyObserved: Double
    ) {
        self.outcome = outcome
        self.matches = matches
        self.outputPayload = outputPayload
        self.scanDurationMicros = scanDurationMicros
        self.peakEntropyObserved = peakEntropyObserved
    }

    public var shouldBlockRequest: Bool {
        outcome == .blockedBeforeLoopbackExit
    }
}

public struct DLPAuditEvent: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let laneID: String
    public let vendor: AgentVendor
    public let providerHost: String
    public let outcome: DLPInspectionOutcome
    public let matches: [DLPDetectionMatch]
    public let scanDurationMicros: Double
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        laneID: String,
        vendor: AgentVendor,
        providerHost: String,
        outcome: DLPInspectionOutcome,
        matches: [DLPDetectionMatch],
        scanDurationMicros: Double,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.laneID = laneID
        self.vendor = vendor
        self.providerHost = providerHost
        self.outcome = outcome
        self.matches = matches
        self.scanDurationMicros = scanDurationMicros
        self.recordedAt = recordedAt
    }

    public func toGuardrailFindings() -> [RelayGuardrailFinding] {
        matches.map { match in
            let actionPrefix: String
            switch match.enforcementApplied {
            case .blockOutboundPacket:
                actionPrefix = "Blocked outbound packet"
            case .redactInPlace:
                actionPrefix = "Redacted in outbound prompt"
            case .auditOnly:
                actionPrefix = "Audited in outbound prompt"
            }
            return RelayGuardrailFinding(
                pluginID: "io.relayide.wiretap-outbound-dlp",
                pluginName: "Wiretap Outbound Secret DLP",
                severity: match.severity,
                laneID: laneID,
                relativePath: match.jsonFieldPath,
                title: "\(actionPrefix): \(match.category.displayTitle)",
                detail: "Matched \(match.maskedSample) at \(match.jsonFieldPath) targeting \(providerHost) (sha256=\(match.secretFingerprintHex)).",
                createdAt: recordedAt
            )
        }
    }
}

// MARK: - Real-Time Outbound Secret DLP Engine

public final class OutboundSecretDLPEngine: @unchecked Sendable {
    private struct CompiledRule: @unchecked Sendable {
        let category: DLPSecretCategory
        let regex: NSRegularExpression
        let captureGroup: Int
        let requiresJWTValidation: Bool
        let requiresEntropyFloor: Bool
    }

    private let lock = NSLock()
    private var policyConfig: DLPPolicyConfiguration
    private var auditRingBuffer: [DLPAuditEvent] = []
    private let compiledRules: [CompiledRule]

    public init(policy: DLPPolicyConfiguration = DLPPolicyConfiguration()) {
        self.policyConfig = policy
        self.compiledRules = Self.compileDefaultRules()
    }

    public var policy: DLPPolicyConfiguration {
        get {
            lock.lock()
            defer { lock.unlock() }
            return policyConfig
        }
        set {
            lock.lock()
            policyConfig = newValue
            if auditRingBuffer.count > newValue.maxAuditRingBufferCapacity {
                auditRingBuffer.removeFirst(auditRingBuffer.count - newValue.maxAuditRingBufferCapacity)
            }
            lock.unlock()
        }
    }

    public func recentAuditEvents(limit: Int = 100) -> [DLPAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        let n = max(0, min(limit, auditRingBuffer.count))
        return Array(auditRingBuffer.suffix(n))
    }

    public func clearAuditEvents() {
        lock.lock()
        auditRingBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Scans an outbound HTTP JSON request body before any bytes leave `127.0.0.1`.
    /// Preserves 100% valid JSON syntax when redacting string nodes in-place.
    public func inspectOutboundBody(
        _ body: Data,
        laneID: String,
        vendor: AgentVendor,
        providerHost: String
    ) -> DLPInspectionVerdict {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let activePolicy = self.policy

        guard activePolicy.isEnabled, !body.isEmpty else {
            let micros = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000.0
            return DLPInspectionVerdict(
                outcome: .cleanPass,
                matches: [],
                outputPayload: body,
                scanDurationMicros: micros,
                peakEntropyObserved: 0.0
            )
        }

        var collectedMatches: [DLPDetectionMatch] = []
        var peakEntropy = 0.0
        let outputData: Data

        if let jsonRoot = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            let transformedRoot = walkAndSanitizeJSONNode(
                jsonRoot,
                path: "$",
                policy: activePolicy,
                matches: &collectedMatches,
                peakEntropy: &peakEntropy
            )
            let didMutate = collectedMatches.contains { $0.enforcementApplied == .redactInPlace }
            if didMutate, JSONSerialization.isValidJSONObject(transformedRoot),
               let reserialized = try? JSONSerialization.data(withJSONObject: transformedRoot, options: []) {
                outputData = reserialized
            } else {
                outputData = body
            }
        } else {
            // Raw UTF-8 payload fallback for multipart or non-JSON bodies
            let rawText = String(decoding: body, as: UTF8.self)
            let sanitizedText = scanAndSanitizeString(
                rawText,
                jsonPath: "$rawBody",
                policy: activePolicy,
                matches: &collectedMatches,
                peakEntropy: &peakEntropy
            )
            let didMutate = collectedMatches.contains { $0.enforcementApplied == .redactInPlace }
            outputData = didMutate ? Data(sanitizedText.utf8) : body
        }

        let elapsedMicros = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000.0
        let outcome: DLPInspectionOutcome
        if collectedMatches.isEmpty {
            outcome = .cleanPass
        } else if collectedMatches.contains(where: { $0.enforcementApplied == .blockOutboundPacket }) {
            outcome = .blockedBeforeLoopbackExit
        } else if collectedMatches.contains(where: { $0.enforcementApplied == .redactInPlace }) {
            outcome = .sanitizedAndForwarded
        } else {
            outcome = .auditedPass
        }

        if !collectedMatches.isEmpty {
            let audit = DLPAuditEvent(
                laneID: laneID,
                vendor: vendor,
                providerHost: providerHost,
                outcome: outcome,
                matches: collectedMatches,
                scanDurationMicros: elapsedMicros
            )
            appendAuditEvent(audit, maxCapacity: activePolicy.maxAuditRingBufferCapacity)
        }

        return DLPInspectionVerdict(
            outcome: outcome,
            matches: collectedMatches,
            outputPayload: outcome == .blockedBeforeLoopbackExit ? Data() : outputData,
            scanDurationMicros: elapsedMicros,
            peakEntropyObserved: peakEntropy
        )
    }

    // MARK: - Recursive Structure-Preserving JSON Sanitizer

    private func walkAndSanitizeJSONNode(
        _ node: Any,
        path: String,
        policy: DLPPolicyConfiguration,
        matches: inout [DLPDetectionMatch],
        peakEntropy: inout Double
    ) -> Any {
        if let str = node as? String {
            // Skip structural model/role/type identifiers that are tiny and non-secret
            if str.count < 10 {
                return str
            }
            return scanAndSanitizeString(
                str,
                jsonPath: path,
                policy: policy,
                matches: &matches,
                peakEntropy: &peakEntropy
            )
        }
        if let array = node as? [Any] {
            var out: [Any] = []
            out.reserveCapacity(array.count)
            for (idx, item) in array.enumerated() {
                out.append(
                    walkAndSanitizeJSONNode(
                        item,
                        path: "\(path)[\(idx)]",
                        policy: policy,
                        matches: &matches,
                        peakEntropy: &peakEntropy
                    )
                )
            }
            return out
        }
        if let dict = node as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for key in dict.keys.sorted() {
                guard let val = dict[key] else { continue }
                out[key] = walkAndSanitizeJSONNode(
                    val,
                    path: "\(path).\(key)",
                    policy: policy,
                    matches: &matches,
                    peakEntropy: &peakEntropy
                )
            }
            return out
        }
        return node
    }

    private func scanAndSanitizeString(
        _ input: String,
        jsonPath: String,
        policy: DLPPolicyConfiguration,
        matches: inout [DLPDetectionMatch],
        peakEntropy: inout Double
    ) -> String {
        var working = input

        for rule in compiledRules {
            let nsWorking = working as NSString
            let fullRange = NSRange(location: 0, length: nsWorking.length)
            let regexMatches = rule.regex.matches(in: working, options: [], range: fullRange)
            guard !regexMatches.isEmpty else { continue }

            // Replace from back to front so earlier NSRanges remain valid
            for match in regexMatches.reversed() {
                let targetRange = (rule.captureGroup < match.numberOfRanges && match.range(at: rule.captureGroup).location != NSNotFound)
                    ? match.range(at: rule.captureGroup)
                    : match.range(at: 0)
                guard targetRange.location != NSNotFound, targetRange.length > 0 else { continue }
                let rawMatched = (working as NSString).substring(with: targetRange)

                if isAllowlisted(rawMatched, allowlist: policy.allowlistedSubstrings) {
                    continue
                }
                if rule.requiresJWTValidation && !Self.isValidJWTStructure(rawMatched) {
                    continue
                }
                let entropy = Self.shannonEntropyBitsPerCharacter(rawMatched)
                peakEntropy = max(peakEntropy, entropy)
                if rule.requiresEntropyFloor && entropy < policy.minimumHighEntropyBitsPerChar {
                    continue
                }

                let fingerprint = Self.shortSHA256Hex(rawMatched)
                let mode = policy.effectiveMode(for: rule.category)
                let replacement = "[REDACTED:\(rule.category.rawValue):\(fingerprint)]"
                let masked = Self.maskPreview(rawMatched)

                matches.append(
                    DLPDetectionMatch(
                        category: rule.category,
                        severity: rule.category.defaultSeverity,
                        enforcementApplied: mode,
                        jsonFieldPath: jsonPath,
                        maskedSample: masked,
                        replacementToken: replacement,
                        shannonEntropy: entropy,
                        secretFingerprintHex: fingerprint
                    )
                )

                if mode == .redactInPlace, let swiftRange = Range(targetRange, in: working) {
                    working.replaceSubrange(swiftRange, with: replacement)
                }
            }
        }

        return working
    }

    private func isAllowlisted(_ candidate: String, allowlist: [String]) -> Bool {
        let upper = candidate.uppercased()
        for token in allowlist where !token.isEmpty {
            if upper.contains(token.uppercased()) {
                return true
            }
        }
        return false
    }

    private func appendAuditEvent(_ event: DLPAuditEvent, maxCapacity: Int) {
        lock.lock()
        defer { lock.unlock() }
        auditRingBuffer.append(event)
        if auditRingBuffer.count > maxCapacity {
            auditRingBuffer.removeFirst(auditRingBuffer.count - maxCapacity)
        }
    }

    // MARK: - Cryptographic & Statistical Validators

    public static func shannonEntropyBitsPerCharacter(_ text: String) -> Double {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty else { return 0.0 }
        var counts = [Int](repeating: 0, count: 256)
        for b in utf8 {
            counts[Int(b)] += 1
        }
        let invLen = 1.0 / Double(utf8.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let p = Double(count) * invLen
            entropy -= p * Foundation.log2(p)
        }
        return entropy
    }

    public static func isValidJWTStructure(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ"), parts[1].hasPrefix("eyJ"), parts[2].count >= 8 else {
            return false
        }
        guard let headerData = decodeBase64URL(String(parts[0])),
              let headerJSON = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return false
        }
        return headerJSON["alg"] != nil || headerJSON["typ"] != nil || headerJSON["kid"] != nil
    }

    private static func decodeBase64URL(_ raw: String) -> Data? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func shortSHA256Hex(_ secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func maskPreview(_ secret: String) -> String {
        let clean = secret.replacingOccurrences(of: "\n", with: "\\n")
        if clean.count <= 10 {
            return String(clean.prefix(2)) + "••••"
        }
        return "\(clean.prefix(6))••••\(clean.suffix(4))"
    }

    private static func compileDefaultRules() -> [CompiledRule] {
        let specs: [(DLPSecretCategory, String, Int, Bool, Bool)] = [
            // 1. Multi-line PEM & OpenSSH Private Key Blocks
            (.openSSHPrivateKey, #"-----BEGIN OPENSSH PRIVATE KEY-----[\s\S]*?-----END OPENSSH PRIVATE KEY-----"#, 0, false, false),
            (.pemPrivateKey, #"-----BEGIN (?:RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----"#, 0, false, false),
            // 2. Local macOS SSH material (/Users/<name>/.ssh/id_ed25519, known_hosts, config, etc.)
            (.localMacOSSSHMaterial, #"/Users/[A-Za-z0-9._\-]+/\.ssh/[A-Za-z0-9._/\-]+"#, 0, false, false),
            // 3. Vendor Cloud & LLM Keys
            (.anthropicAPIKey, #"\bsk-ant-(?:api\d{2}-)?[A-Za-z0-9\-_]{20,}\b"#, 0, false, false),
            (.openAIAPIKey, #"\bsk-(?:proj|svcacct|live)-[A-Za-z0-9\-_]{20,}\b"#, 0, false, false),
            (.googleGeminiAPIKey, #"\bAIza[0-9A-Za-z\-_]{35}\b"#, 0, false, false),
            (.gitHubPAT, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,255}\b|\bgithub_pat_[A-Za-z0-9_]{36,255}\b"#, 0, false, false),
            (.awsAccessKeyID, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, 0, false, false),
            (.awsSecretAccessKey, #"(?i)(?:aws_secret_access_key|aws_secret_key)\s*[:=]\s*['"]?([A-Za-z0-9/+=]{40})['"]?"#, 1, false, true),
            (.stripeSecretKey, #"\b(?:sk|rk)_live_[0-9a-zA-Z]{20,99}\b"#, 0, false, false),
            (.slackToken, #"\bxox(?:b|p|a|r|s)-[0-9]{10,15}-[0-9A-Za-z\-]{16,}\b"#, 0, false, false),
            // 4. Database URIs with embedded user:password@host credentials
            (.databaseConnectionURI, #"\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|rediss)://[^/\s:@]+:([^/\s@]{6,})@[^\s'"]+"#, 1, false, false),
            // 5. Signed JSON Web Tokens (header.payload.signature)
            (.jwtBearerToken, #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, 0, true, false),
            // 6. .env style secret assignments (e.g., DATABASE_PASSWORD=..., API_SECRET=...)
            (.dotenvAssignment, ##"(?m)^[ \t]*(?:export[ \t]+)?[A-Z0-9_]*(?:SECRET|PASSWORD|PRIVATE_KEY|ACCESS_TOKEN|API_KEY|AUTH_TOKEN)[A-Z0-9_]*[ \t]*=[ \t]*['"]?([^\s'"#]{12,})['"]?"##, 1, false, true),
            // 7. Generic high-entropy Authorization Bearer tokens
            (.highEntropySecret, #"(?i)\bBearer[ \t]+([A-Za-z0-9\-._~+/]{32,}=*)"#, 1, false, true),
            // 8. Non-SSH local macOS /Users/<user>/ paths
            (.localMacOSHomePath, #"/Users/[A-Za-z0-9._\-]+/(?!\.ssh/)[A-Za-z0-9._/\-]+"#, 0, false, false)
        ]

        return specs.compactMap { category, pattern, group, checkJWT, checkEntropy in
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            return CompiledRule(
                category: category,
                regex: rx,
                captureGroup: group,
                requiresJWTValidation: checkJWT,
                requiresEntropyFloor: checkEntropy
            )
        }
    }
}

// MARK: - Multi-Lane USD Burn-Rate Forecasting & Anomaly Spike Detection

public enum BurnRateRiskState: String, Sendable, Codable, Hashable, CaseIterable {
    case nominal = "NOMINAL"
    case elevated = "ELEVATED"
    case imminentExhaustion = "IMMINENT_EXHAUSTION"
    case circuitTripped = "CIRCUIT_TRIPPED"
}

public struct LaneBurnRateForecast: Sendable, Codable, Hashable, Identifiable {
    public var id: String { laneID }
    public let laneID: String
    public let vendor: AgentVendor
    public let requestCount: Int
    public let spentUSD: Double
    public let ceilingUSD: Double
    public let remainingBudgetUSD: Double
    public let ewmaUSDPerMinute: Double
    public let linearSlopeUSDPerMinute: Double
    public let blendedUSDPerHour: Double
    public let tokensPerMinute: Double
    public let promptCacheHitRatio: Double
    public let averageCostPerTurnUSD: Double
    public let projectedExhaustionSeconds: Double?
    public let estimatedTurnsRemaining: Int?
    public let riskState: BurnRateRiskState

    public init(
        laneID: String,
        vendor: AgentVendor,
        requestCount: Int,
        spentUSD: Double,
        ceilingUSD: Double,
        remainingBudgetUSD: Double,
        ewmaUSDPerMinute: Double,
        linearSlopeUSDPerMinute: Double,
        blendedUSDPerHour: Double,
        tokensPerMinute: Double,
        promptCacheHitRatio: Double,
        averageCostPerTurnUSD: Double,
        projectedExhaustionSeconds: Double?,
        estimatedTurnsRemaining: Int?,
        riskState: BurnRateRiskState
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.requestCount = requestCount
        self.spentUSD = spentUSD
        self.ceilingUSD = ceilingUSD
        self.remainingBudgetUSD = remainingBudgetUSD
        self.ewmaUSDPerMinute = ewmaUSDPerMinute
        self.linearSlopeUSDPerMinute = linearSlopeUSDPerMinute
        self.blendedUSDPerHour = blendedUSDPerHour
        self.tokensPerMinute = tokensPerMinute
        self.promptCacheHitRatio = promptCacheHitRatio
        self.averageCostPerTurnUSD = averageCostPerTurnUSD
        self.projectedExhaustionSeconds = projectedExhaustionSeconds
        self.estimatedTurnsRemaining = estimatedTurnsRemaining
        self.riskState = riskState
    }
}

public enum CostAnomalyKind: String, Sendable, Codable, Hashable, CaseIterable {
    case spendSpikeOutlier = "SPEND_SPIKE_OUTLIER"
    case promptCacheCollapse = "PROMPT_CACHE_COLLAPSE"
    case reasoningTokenRunaway = "REASONING_TOKEN_RUNAWAY"
    case rapidRetryBurst = "RAPID_RETRY_BURST"
    case ttftLatencyDegradation = "TTFT_LATENCY_SPIKE"
}

public struct CostAnomalyAlert: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: CostAnomalyKind
    public let severity: GuardrailSeverity
    public let laneID: String
    public let vendor: AgentVendor
    public let triggeringSpanID: UUID
    public let observedValue: Double
    public let baselineMedian: Double
    public let anomalyMultiplier: Double
    public let summary: String
    public let remediationHint: String
    public let detectedAt: Date

    public init(
        id: UUID = UUID(),
        kind: CostAnomalyKind,
        severity: GuardrailSeverity,
        laneID: String,
        vendor: AgentVendor,
        triggeringSpanID: UUID,
        observedValue: Double,
        baselineMedian: Double,
        anomalyMultiplier: Double,
        summary: String,
        remediationHint: String,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.laneID = laneID
        self.vendor = vendor
        self.triggeringSpanID = triggeringSpanID
        self.observedValue = observedValue
        self.baselineMedian = baselineMedian
        self.anomalyMultiplier = anomalyMultiplier
        self.summary = summary
        self.remediationHint = remediationHint
        self.detectedAt = detectedAt
    }
}

public struct VendorSpendBreakdown: Sendable, Codable, Hashable, Identifiable {
    public var id: String { vendor.rawValue }
    public let vendor: AgentVendor
    public let turnCount: Int
    public let inputTokens: Int
    public let cachedReadTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let spentUSD: Double
    public let shareOfTotalSpend: Double
    public let estimatedCacheSavingsUSD: Double

    public init(
        vendor: AgentVendor,
        turnCount: Int,
        inputTokens: Int,
        cachedReadTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        spentUSD: Double,
        shareOfTotalSpend: Double,
        estimatedCacheSavingsUSD: Double
    ) {
        self.vendor = vendor
        self.turnCount = turnCount
        self.inputTokens = inputTokens
        self.cachedReadTokens = cachedReadTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.spentUSD = spentUSD
        self.shareOfTotalSpend = shareOfTotalSpend
        self.estimatedCacheSavingsUSD = estimatedCacheSavingsUSD
    }
}

public struct WorkspaceCostAnalyticsSnapshot: Sendable, Codable, Hashable {
    public let totalSpentUSD: Double
    public let globalCeilingUSD: Double
    public let totalCacheSavingsUSD: Double
    public let workspaceBurnRateUSDPerHour: Double
    public let projectedGlobalExhaustionSeconds: Double?
    public let laneForecasts: [LaneBurnRateForecast]
    public let vendorBreakdowns: [VendorSpendBreakdown]
    public let anomalies: [CostAnomalyAlert]

    public init(
        totalSpentUSD: Double,
        globalCeilingUSD: Double,
        totalCacheSavingsUSD: Double,
        workspaceBurnRateUSDPerHour: Double,
        projectedGlobalExhaustionSeconds: Double?,
        laneForecasts: [LaneBurnRateForecast],
        vendorBreakdowns: [VendorSpendBreakdown],
        anomalies: [CostAnomalyAlert]
    ) {
        self.totalSpentUSD = totalSpentUSD
        self.globalCeilingUSD = globalCeilingUSD
        self.totalCacheSavingsUSD = totalCacheSavingsUSD
        self.workspaceBurnRateUSDPerHour = workspaceBurnRateUSDPerHour
        self.projectedGlobalExhaustionSeconds = projectedGlobalExhaustionSeconds
        self.laneForecasts = laneForecasts
        self.vendorBreakdowns = vendorBreakdowns
        self.anomalies = anomalies
    }
}

public struct WiretapCostAnalyticsEngine: Sendable {
    public let pricingCatalog: ProviderPricingCatalog
    public let ewmaAlpha: Double
    public let spikeMultiplierThreshold: Double

    public init(
        pricingCatalog: ProviderPricingCatalog = ProviderPricingCatalog(),
        ewmaAlpha: Double = 0.35,
        spikeMultiplierThreshold: Double = 2.6
    ) {
        self.pricingCatalog = pricingCatalog
        self.ewmaAlpha = min(0.95, max(0.05, ewmaAlpha))
        self.spikeMultiplierThreshold = max(1.5, spikeMultiplierThreshold)
    }

    public func analyzeWorkspace(
        accounts: [LaneBudgetAccount],
        spans: [WiretapAPISpan],
        globalCeilingUSD: Double = 25.0
    ) -> WorkspaceCostAnalyticsSnapshot {
        let sortedSpans = spans.sorted { $0.recordedAt < $1.recordedAt }
        var spansByLane: [String: [WiretapAPISpan]] = [:]
        for s in sortedSpans {
            spansByLane[s.laneID, default: []].append(s)
        }

        var allLaneIDs = Set(accounts.map(\.laneID)).union(spansByLane.keys)
        if allLaneIDs.isEmpty {
            allLaneIDs = []
        }

        var accountMap: [String: LaneBudgetAccount] = [:]
        for acc in accounts {
            accountMap[acc.laneID] = acc
        }

        var forecasts: [LaneBurnRateForecast] = []
        var detectedAnomalies: [CostAnomalyAlert] = []
        var workspaceUSDPerMin = 0.0

        for laneID in allLaneIDs.sorted() {
            let laneSpans = spansByLane[laneID] ?? []
            let inferredVendor = accountMap[laneID]?.vendor ?? laneSpans.first?.vendor ?? .customShell
            let acc = accountMap[laneID] ?? Self.synthesizeAccount(laneID: laneID, vendor: inferredVendor, spans: laneSpans)
            let forecast = forecastLane(account: acc, spans: laneSpans)
            forecasts.append(forecast)
            workspaceUSDPerMin += max(forecast.ewmaUSDPerMinute, forecast.linearSlopeUSDPerMinute) * 0.5
                + min(forecast.ewmaUSDPerMinute, forecast.linearSlopeUSDPerMinute) * 0.5

            detectedAnomalies.append(contentsOf: detectLaneAnomalies(laneID: laneID, vendor: inferredVendor, spans: laneSpans))
        }

        // Vendor Breakdowns & Cache Savings
        var byVendor: [AgentVendor: [WiretapAPISpan]] = [:]
        for span in sortedSpans {
            byVendor[span.vendor, default: []].append(span)
        }
        let totalSpent = max(
            accounts.reduce(0.0) { $0 + $1.spentUSD },
            sortedSpans.reduce(0.0) { $0 + $1.costUSD }
        )

        var vendorSummaries: [VendorSpendBreakdown] = []
        var totalSavings = 0.0
        for vendor in AgentVendor.allCases {
            guard let vSpans = byVendor[vendor], !vSpans.isEmpty else { continue }
            var inSum = 0
            var cacheSum = 0
            var outSum = 0
            var reasonSum = 0
            var costSum = 0.0
            var savingsSum = 0.0

            for s in vSpans {
                inSum += s.inputTokens
                cacheSum += s.cachedReadTokens
                outSum += s.outputTokens
                reasonSum += s.reasoningTokens
                costSum += s.costUSD
                let rate = pricingCatalog.matchRate(for: s.modelIdentifier, fallbackVendor: vendor)
                let savedPerTok = max(0.0, rate.inputUSDPerMillion - rate.cachedInputUSDPerMillion) / 1_000_000.0
                savingsSum += Double(s.cachedReadTokens) * savedPerTok
            }
            totalSavings += savingsSum
            let share = totalSpent > 0 ? (costSum / totalSpent) : 0.0
            vendorSummaries.append(
                VendorSpendBreakdown(
                    vendor: vendor,
                    turnCount: vSpans.count,
                    inputTokens: inSum,
                    cachedReadTokens: cacheSum,
                    outputTokens: outSum,
                    reasoningTokens: reasonSum,
                    spentUSD: costSum,
                    shareOfTotalSpend: share,
                    estimatedCacheSavingsUSD: savingsSum
                )
            )
        }

        let remainingGlobal = max(0.0, globalCeilingUSD - totalSpent)
        let projectedGlobalSec: Double?
        if workspaceUSDPerMin > 1e-6 {
            projectedGlobalSec = (remainingGlobal / workspaceUSDPerMin) * 60.0
        } else {
            projectedGlobalSec = nil
        }

        return WorkspaceCostAnalyticsSnapshot(
            totalSpentUSD: totalSpent,
            globalCeilingUSD: globalCeilingUSD,
            totalCacheSavingsUSD: totalSavings,
            workspaceBurnRateUSDPerHour: workspaceUSDPerMin * 60.0,
            projectedGlobalExhaustionSeconds: projectedGlobalSec,
            laneForecasts: forecasts,
            vendorBreakdowns: vendorSummaries,
            anomalies: detectedAnomalies.sorted { $0.severity > $1.severity }
        )
    }

    // MARK: - Forecasting & Robust Outlier Math

    private func forecastLane(account: LaneBudgetAccount, spans: [WiretapAPISpan]) -> LaneBurnRateForecast {
        let nonBlocked = spans.filter { !$0.blockedByCircuitBreaker }
        let remaining = max(0.0, account.ceilingUSD - account.spentUSD)
        let avgTurnCost = account.requestCount > 0 ? (account.spentUSD / Double(account.requestCount)) : 0.0
        let cacheRatio = account.inputTokens > 0 ? (Double(account.cachedTokens) / Double(account.inputTokens)) : 0.0

        guard !nonBlocked.isEmpty else {
            return LaneBurnRateForecast(
                laneID: account.laneID,
                vendor: account.vendor,
                requestCount: account.requestCount,
                spentUSD: account.spentUSD,
                ceilingUSD: account.ceilingUSD,
                remainingBudgetUSD: remaining,
                ewmaUSDPerMinute: 0.0,
                linearSlopeUSDPerMinute: 0.0,
                blendedUSDPerHour: 0.0,
                tokensPerMinute: 0.0,
                promptCacheHitRatio: cacheRatio,
                averageCostPerTurnUSD: avgTurnCost,
                projectedExhaustionSeconds: nil,
                estimatedTurnsRemaining: avgTurnCost > 0 ? Int(remaining / avgTurnCost) : nil,
                riskState: account.circuitOpen ? .circuitTripped : .nominal
            )
        }

        // Compute instantaneous USD/min per turn from duration + inter-arrival window
        let t0 = nonBlocked.first!.recordedAt.timeIntervalSince1970
        let tLast = nonBlocked.last!.recordedAt.timeIntervalSince1970
        let wallWindowMinutes: Double
        if nonBlocked.count >= 2 && (tLast - t0) >= 1.0 {
            wallWindowMinutes = (tLast - t0 + (nonBlocked.last!.durationMs / 1_000.0)) / 60.0
        } else {
            let sumDurSec = max(1.0, nonBlocked.reduce(0.0) { $0 + ($1.durationMs / 1_000.0) })
            wallWindowMinutes = sumDurSec / 60.0
        }

        var ewmaRate = (nonBlocked[0].costUSD / max(0.02, nonBlocked[0].durationMs / 60_000.0))
        for idx in 1..<nonBlocked.count {
            let dtSec = max(
                nonBlocked[idx].durationMs / 1_000.0,
                nonBlocked[idx].recordedAt.timeIntervalSince(nonBlocked[idx - 1].recordedAt)
            )
            let instUSDPerMin = nonBlocked[idx].costUSD / max(0.02, dtSec / 60.0)
            ewmaRate = ewmaAlpha * instUSDPerMin + (1.0 - ewmaAlpha) * ewmaRate
        }

        // Ordinary Least Squares slope over cumulative spend vs elapsed minutes
        let linearSlope = computeCumulativeSpendLinearSlopeUSDPerMin(spans: nonBlocked, FallbackWindowMin: wallWindowMinutes)
        let blendedPerMin = max(0.0, 0.6 * ewmaRate + 0.4 * linearSlope)
        let totalTokens = nonBlocked.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.reasoningTokens }
        let tokPerMin = Double(totalTokens) / max(0.05, wallWindowMinutes)

        let projectedExhaustionSec: Double? = blendedPerMin > 1e-6 ? (remaining / blendedPerMin) * 60.0 : nil
        let estTurnsLeft: Int? = avgTurnCost > 1e-6 ? Int((remaining / avgTurnCost).rounded(.down)) : nil

        let risk: BurnRateRiskState
        if account.circuitOpen || remaining <= 0.0 {
            risk = .circuitTripped
        } else if (account.spentUSD / max(0.01, account.ceilingUSD)) >= 0.85 || (projectedExhaustionSec ?? .infinity) < 180.0 {
            risk = .imminentExhaustion
        } else if (account.spentUSD / max(0.01, account.ceilingUSD)) >= 0.60 || (projectedExhaustionSec ?? .infinity) < 600.0 {
            risk = .elevated
        } else {
            risk = .nominal
        }

        return LaneBurnRateForecast(
            laneID: account.laneID,
            vendor: account.vendor,
            requestCount: account.requestCount,
            spentUSD: account.spentUSD,
            ceilingUSD: account.ceilingUSD,
            remainingBudgetUSD: remaining,
            ewmaUSDPerMinute: ewmaRate,
            linearSlopeUSDPerMinute: linearSlope,
            blendedUSDPerHour: blendedPerMin * 60.0,
            tokensPerMinute: tokPerMin,
            promptCacheHitRatio: cacheRatio,
            averageCostPerTurnUSD: avgTurnCost,
            projectedExhaustionSeconds: projectedExhaustionSec,
            estimatedTurnsRemaining: estTurnsLeft,
            riskState: risk
        )
    }

    private func computeCumulativeSpendLinearSlopeUSDPerMin(spans: [WiretapAPISpan], FallbackWindowMin: Double) -> Double {
        guard spans.count >= 2 else {
            return (spans.first?.costUSD ?? 0.0) / max(0.05, FallbackWindowMin)
        }
        let origin = spans[0].recordedAt.timeIntervalSince1970
        var xs: [Double] = []
        var ys: [Double] = []
        var cumCost = 0.0
        var syntheticClockSec = 0.0

        for s in spans {
            let naturalSec = s.recordedAt.timeIntervalSince1970 - origin
            syntheticClockSec = max(syntheticClockSec + max(0.5, s.durationMs / 1_000.0), naturalSec)
            cumCost += s.costUSD
            xs.append(syntheticClockSec / 60.0)
            ys.append(cumCost)
        }

        let n = Double(xs.count)
        let meanX = xs.reduce(0.0, +) / n
        let meanY = ys.reduce(0.0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            num += dx * (ys[i] - meanY)
            den += dx * dx
        }
        guard den > 1e-9 else {
            return cumCost / max(0.05, FallbackWindowMin)
        }
        return max(0.0, num / den)
    }

    private func detectLaneAnomalies(
        laneID: String,
        vendor: AgentVendor,
        spans: [WiretapAPISpan]
    ) -> [CostAnomalyAlert] {
        guard spans.count >= 3 else { return [] }
        var alerts: [CostAnomalyAlert] = []

        let activeSpans = spans.filter { !$0.blockedByCircuitBreaker && $0.costUSD > 0 }
        if activeSpans.count >= 3 {
            let costs = activeSpans.map(\.costUSD)
            let medCost = Self.median(costs)
            let madCost = Self.medianAbsoluteDeviation(costs, medianValue: medCost)

            for span in activeSpans where medCost > 0.001 {
                let ratio = span.costUSD / medCost
                let robustZ = madCost > 1e-6 ? (0.6745 * (span.costUSD - medCost) / madCost) : ratio
                if ratio >= spikeMultiplierThreshold && robustZ >= 2.5 {
                    alerts.append(
                        CostAnomalyAlert(
                            kind: .spendSpikeOutlier,
                            severity: ratio >= 4.0 ? .blocker : .warning,
                            laneID: laneID,
                            vendor: vendor,
                            triggeringSpanID: span.id,
                            observedValue: span.costUSD,
                            baselineMedian: medCost,
                            anomalyMultiplier: ratio,
                            summary: String(format: "Turn cost spiked %.1fx above lane median ($%.4f vs $%.4f)", ratio, span.costUSD, medCost),
                            remediationHint: "Inspect tool output truncation or large diff context in \(span.modelIdentifier).",
                            detectedAt: span.recordedAt
                        )
                    )
                }
            }
        }

        // Detect sudden prompt-cache bust regression after warm cache turns
        for idx in 1..<activeSpans.count {
            let prev = activeSpans[idx - 1]
            let curr = activeSpans[idx]
            guard prev.inputTokens >= 30_000, curr.inputTokens >= 30_000 else { continue }
            let prevHit = Double(prev.cachedReadTokens) / Double(prev.inputTokens)
            let currHit = Double(curr.cachedReadTokens) / Double(curr.inputTokens)
            if prevHit >= 0.55 && currHit <= 0.08 {
                alerts.append(
                    CostAnomalyAlert(
                        kind: .promptCacheCollapse,
                        severity: .warning,
                        laneID: laneID,
                        vendor: vendor,
                        triggeringSpanID: curr.id,
                        observedValue: currHit * 100.0,
                        baselineMedian: prevHit * 100.0,
                        anomalyMultiplier: prevHit / max(0.01, currHit),
                        summary: String(format: "Prompt cache hit rate collapsed from %.0f%% to %.0f%% on %dk context", prevHit * 100, currHit * 100, curr.inputTokens / 1000),
                        remediationHint: "Avoid mutating system prompt header timestamps or tool schema ordering mid-session.",
                        detectedAt: curr.recordedAt
                    )
                )
            }
        }

        // Detect runaway reasoning token share (>75% of output budget with >= 8,000 reasoning tokens)
        for span in activeSpans where span.reasoningTokens >= 8_000 {
            let totalGenerated = max(1, span.outputTokens + span.reasoningTokens)
            let reasonShare = Double(span.reasoningTokens) / Double(totalGenerated)
            if reasonShare >= 0.78 {
                alerts.append(
                    CostAnomalyAlert(
                        kind: .reasoningTokenRunaway,
                        severity: .advisory,
                        laneID: laneID,
                        vendor: vendor,
                        triggeringSpanID: span.id,
                        observedValue: Double(span.reasoningTokens),
                        baselineMedian: Double(span.outputTokens),
                        anomalyMultiplier: Double(span.reasoningTokens) / Double(max(1, span.outputTokens)),
                        summary: "Extended reasoning consumed \(span.reasoningTokens) tokens (\(Int(reasonShare * 100))% of generation)",
                        remediationHint: "Consider capping reasoning_effort or decomposing task brief into smaller AST scopes.",
                        detectedAt: span.recordedAt
                    )
                )
            }
        }

        // Detect rapid 429 / 5xx retry storm
        let errorSpans = spans.filter { $0.statusCode == 429 || $0.statusCode >= 500 || $0.blockedByCircuitBreaker }
        if errorSpans.count >= 2, let lastErr = errorSpans.last {
            alerts.append(
                CostAnomalyAlert(
                    kind: .rapidRetryBurst,
                    severity: lastErr.blockedByCircuitBreaker ? .blocker : .warning,
                    laneID: laneID,
                    vendor: vendor,
                    triggeringSpanID: lastErr.id,
                    observedValue: Double(errorSpans.count),
                    baselineMedian: 0.0,
                    anomalyMultiplier: Double(errorSpans.count),
                    summary: "Observed \(errorSpans.count) throttled or circuit-halted API attempts in lane '\(laneID)'",
                    remediationHint: "Trigger VendorFailoverAndRetryController or raise lane ceiling if verified safe.",
                    detectedAt: lastErr.recordedAt
                )
            )
        }

        return alerts
    }

    private static func synthesizeAccount(laneID: String, vendor: AgentVendor, spans: [WiretapAPISpan]) -> LaneBudgetAccount {
        var acc = LaneBudgetAccount(laneID: laneID, vendor: vendor, ceilingUSD: 10.0)
        for s in spans {
            acc.requestCount += 1
            acc.inputTokens += s.inputTokens
            acc.cachedTokens += s.cachedReadTokens
            acc.outputTokens += (s.outputTokens + s.reasoningTokens)
            acc.spentUSD += s.costUSD
            if s.blockedByCircuitBreaker {
                acc.circuitOpen = true
            }
        }
        return acc
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) * 0.5
        }
        return sorted[mid]
    }

    private static func medianAbsoluteDeviation(_ values: [Double], medianValue: Double) -> Double {
        let deviations = values.map { abs($0 - medianValue) }
        return median(deviations)
    }
}

// MARK: - Convenience Analytics & Flamechart Extensions on BudgetCircuitBreakerLedger

public extension BudgetCircuitBreakerLedger {
    func computeCostAnalyticsSnapshot(globalCeilingUSD: Double = 25.0) -> WorkspaceCostAnalyticsSnapshot {
        WiretapCostAnalyticsEngine().analyzeWorkspace(
            accounts: allAccounts(),
            spans: allSpans(),
            globalCeilingUSD: globalCeilingUSD
        )
    }

    func buildFlamechartTimeline() -> WiretapFlamechartTimeline {
        WiretapFlamechartBuilder.buildTimeline(from: allSpans())
    }
}

