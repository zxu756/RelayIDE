import Combine
import Foundation

// MARK: - Bilingual Language Model & Live Localizer (`中文 / EN`)

public enum RelayLanguage: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    /// Short segmented toggle badge (`中文` | `EN`)
    public var badge: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public var isChinese: Bool {
        self == .zhHans
    }

    public var toggled: RelayLanguage {
        self == .zhHans ? .en : .zhHans
    }

    /// Parses CLI / env / persisted language identifiers (`zh`, `zh-Hans`, `zh-CN`, `en`, etc.).
    public static func parse(_ raw: String?) -> RelayLanguage? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }

        if normalized == "zh"
            || normalized.hasPrefix("zh-")
            || normalized == "cn"
            || normalized == "chinese"
            || normalized == "中文"
            || normalized == "简体中文" {
            return .zhHans
        }
        if normalized == "en"
            || normalized.hasPrefix("en-")
            || normalized == "english" {
            return .en
        }
        return nil
    }
}

@MainActor
public final class RelayLocalizer: ObservableObject {
    public nonisolated static let userDefaultsKey = "io.github.zxu756.RelayIDE.language"
    public nonisolated static let environmentKey = "RELAYIDE_LANG"

    public static let shared = RelayLocalizer()

    @Published public var language: RelayLanguage {
        didSet {
            guard oldValue != language else { return }
            if persistToUserDefaults {
                userDefaults.set(language.rawValue, forKey: storageKey)
            }
        }
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let persistToUserDefaults: Bool

    public init(
        language: RelayLanguage? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        storageKey: String = RelayLocalizer.userDefaultsKey,
        preferredLanguages: [String] = Locale.preferredLanguages,
        persistToUserDefaults: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.persistToUserDefaults = persistToUserDefaults
        if let explicit = language {
            self.language = explicit
            if persistToUserDefaults {
                userDefaults.set(explicit.rawValue, forKey: storageKey)
            }
        } else {
            self.language = Self.resolveLanguage(
                arguments: arguments,
                environment: environment,
                userDefaults: userDefaults,
                storageKey: storageKey,
                preferredLanguages: preferredLanguages
            )
        }
    }

    /// Strict resolution precedence:
    /// 1. CLI `--lang zh|en` (or `--lang=zh|en`)
    /// 2. Environment `RELAYIDE_LANG=zh|en`
    /// 3. `UserDefaults` (`io.github.zxu756.RelayIDE.language`)
    /// 4. `Locale.preferredLanguages.first` starting with `"zh"` -> `.zhHans`, otherwise `.en`
    public nonisolated static func resolveLanguage(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        storageKey: String = RelayLocalizer.userDefaultsKey,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> RelayLanguage {
        if let cliLang = parseCLILanguageOverride(arguments: arguments) {
            return cliLang
        }
        if let envRaw = environment[environmentKey], let envLang = RelayLanguage.parse(envRaw) {
            return envLang
        }
        if let storedRaw = userDefaults.string(forKey: storageKey),
           let storedLang = RelayLanguage.parse(storedRaw) {
            return storedLang
        }
        if let primaryPreferred = preferredLanguages.first,
           primaryPreferred.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("zh") {
            return .zhHans
        }
        return .en
    }

    public nonisolated static func parseCLILanguageOverride(arguments: [String]) -> RelayLanguage? {
        var resolved: RelayLanguage?
        var idx = 0
        while idx < arguments.count {
            let arg = arguments[idx]
            if arg == "--lang" {
                if idx + 1 < arguments.count, let parsed = RelayLanguage.parse(arguments[idx + 1]) {
                    resolved = parsed
                    idx += 2
                    continue
                }
            } else if arg.hasPrefix("--lang=") {
                let value = String(arg.dropFirst("--lang=".count))
                if let parsed = RelayLanguage.parse(value) {
                    resolved = parsed
                }
            }
            idx += 1
        }
        return resolved
    }

    public var isChinese: Bool {
        language == .zhHans
    }

    /// Primary inline bilingual selector: returns English when `.en`, Simplified Chinese when `.zhHans`.
    public func L(_ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public nonisolated static func select(_ language: RelayLanguage, _ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public func setLanguage(_ newLanguage: RelayLanguage) {
        if language != newLanguage {
            language = newLanguage
        }
    }

    @discardableResult
    public func toggleLanguage() -> RelayLanguage {
        let next = language.toggled
        language = next
        return next
    }

    /// Translates known synthesized campaign & domain strings in the presentation layer when `.zhHans` is active,
    /// leaving underlying persisted identifiers untouched and passing user strings through unchanged.
    public func display(_ text: String) -> String {
        Self.translateDisplayText(text, language: language)
    }

    public nonisolated static func translateDisplayText(_ text: String, language: RelayLanguage) -> String {
        guard language == .zhHans else { return text }
        if let exact = zhCampaignGlossary[text] {
            return exact
        }
        // Dynamic AST auto-merge explanation patterns produced by ThreeWaySemanticASTMerger
        if text.hasPrefix("Auto-merged disjoint imports") && text.contains("Darwin") && text.contains("CryptoKit") {
            return "自动合并离散导入 (Claude Code 新增 Darwin + OpenAI Codex 新增 CryptoKit)。"
        }
        if text.hasPrefix("Added new ") && text.contains("acquireZeroCopyReadSlice") {
            return "语义无冲突自动合并：采纳 Claude Code 新增方法 'acquireZeroCopyReadSlice'。"
        }
        if text.hasPrefix("Added new ") && text.contains("computeSlotIntegrityTag") {
            return "语义无冲突自动合并：采纳 OpenAI Codex 新增方法 'computeSlotIntegrityTag'。"
        }
        if text.hasPrefix("Auto-merged disjoint nested declarations inside ") {
            let symbol = text.replacingOccurrences(of: "Auto-merged disjoint nested declarations inside ", with: "")
            return "自动合并类型内部离散成员声明：\(symbol)"
        }
        if text.hasPrefix("Unchanged across base, left, and right") {
            return "基线、左侧与右侧通道保持一致，无漂移。"
        }
        if text.hasPrefix("Lane '") && text.hasSuffix(" without touching Tests/.") {
            let trimmed = text
                .replacingOccurrences(of: "Lane '", with: "通道 '")
                .replacingOccurrences(of: "' modified ", with: "' 修改了 Sources/ 下的 ")
                .replacingOccurrences(of: " AST symbols under Sources/ without touching Tests/.", with: " 个 AST 符号，但未同步更新 Tests/ 测试套件。")
            return trimmed
        }
        if text.hasPrefix("feat(multi-lane): integrate ") {
            let symbols = text.replacingOccurrences(of: "feat(multi-lane): integrate ", with: "")
            return "feat(multi-lane): 集成多通道符号 \(symbols)"
        }
        return text
    }

    private nonisolated static let zhCampaignGlossary: [String: String] = [
        // Campaign & Workspace Titles
        "Zero-Copy HTTP/3 Edge Gateway & Passkey Auth": "零拷贝 HTTP/3 边缘网关与通行密钥认证",
        "Zero-Copy HTTP/3 Transport & Auth Refactor": "零拷贝 HTTP/3 传输层与通行密钥重构",
        "RelayIDE Demo Campaign": "RelayIDE 演示接力战役",
        "PaymentsCore-Relay": "PaymentsCore-Relay · 支付清结算并行工程",

        // Four Vendor Worktree Lane Display Names
        "Claude Code · Zero-Copy QUIC & Passkeys": "Claude Code · 零拷贝 QUIC 与通行密钥",
        "OpenAI Codex · HKDF Subkey Rotation": "OpenAI Codex · HKDF 子密钥轮换",
        "Google AGY · HTTP/3 Router & Spec": "Google AGY · HTTP/3 路由与规范",
        "Mistral Vibe · QUIC & JWT Fuzz Suite": "Mistral Vibe · QUIC 与 JWT 模糊测试",

        // DAG Task Titles
        "Zero-Copy QUIC IOVector Ring & VarInt Codec": "零拷贝 QUIC IOVector 环形缓冲与 VarInt 编解码",
        "WebAuthn P-256 Passkey Assertion Verifier": "WebAuthn P-256 通行密钥断言验证器",
        "RFC 9001 HKDF Session Subkey Ratchet": "RFC 9001 HKDF 会话子密钥棘轮",
        "HTTP/3 QPACK Stream Multiplexer & RFC Spec": "HTTP/3 QPACK 流多路复用器与架构规范",
        "3-Way Semantic AST Reconcile (AuthSessionManager)": "三路 AST 语义合并调解 (AuthSessionManager)",
        "128-Case QUIC Frame & Token Replay Fuzz Gate": "128 组 QUIC 帧与令牌重放模糊测试门禁",

        // DAG Task Briefs & Handoff Summaries
        "Implement lock-free zero-copy HTTP3ZeroCopyRing and RFC 9000 variable-length integer frame decoder.":
            "实现无锁零拷贝 HTTP3ZeroCopyRing 与 RFC 9000 变长整数帧解码器。",
        "Delivered acquireZeroCopyReadSlice(frameBytes:) with 0 heap copies per 64KB datagram.":
            "已交付 acquireZeroCopyReadSlice(frameBytes:)，单 64KB 数据报实现 0 次堆内存拷贝。",
        "Add verifyPasskeyAssertion(...) and strict clock-leeway audience checks in AuthSessionManager.swift.":
            "在 AuthSessionManager.swift 中新增 verifyPasskeyAssertion(...) 与严格时钟容差受众校验。",
        "Added verifyPasskeyAssertion(...) using CryptoKit P256.Signing + userVerified gate.":
            "已基于 CryptoKit P256.Signing 与 userVerified 门禁新增 verifyPasskeyAssertion(...)。",
        "Implement rotateSessionSubkeys(...) and HKDF epoch ring validation in AuthSessionManager.swift.":
            "在 AuthSessionManager.swift 中实现 rotateSessionSubkeys(...) 与 HKDF 纪元环校验。",
        "Implemented stateless HKDF-Expand-Label subkey rotation + replay bloom filter.":
            "已实现无状态 HKDF-Expand-Label 子密钥轮换与防重放布隆过滤器。",
        "Integrate zero-copy QUIC ring + HKDF subkeys into HTTP3StreamMultiplexer and author docs/HTTP3-ZEROCOPY-RFC.md.":
            "将零拷贝 QUIC 环形缓冲与 HKDF 子密钥接入 HTTP3StreamMultiplexer 并撰写 docs/HTTP3-ZEROCOPY-RFC.md。",
        "Wired 0-RTT stream prioritization and authored complete HTTP/3 architecture RFC.":
            "已接入 0-RTT 流优先级调度并完成 HTTP/3 架构 RFC 文档。",
        "Reconcile disjoint passkey/subkey methods and resolve intra-function validateTokenClaims conflict.":
            "自动合并离散通行密钥/子密钥方法，并解决 validateTokenClaims 函数内语义冲突。",
        "Execute property & differential fuzz tests across merged HTTP3ZeroCopyRing and AuthSessionManager.":
            "针对合并后的 HTTP3ZeroCopyRing 与 AuthSessionManager 执行属性测试与差分模糊验证。",

        // Semantic AST Merge Chunk Explanations & Cross-File Collision Diagnostic
        "AuthSessionManager (stored properties & init)": "AuthSessionManager (存储属性与构造器)",
        "Auto-merged disjoint imports (AuthenticationServices from Claude Code + OSLog from OpenAI Codex).":
            "已自动合并离散导入集合 (Claude Code 的 AuthenticationServices + OpenAI Codex 的 OSLog)。",
        "Struct header and initializer preserved without drift across both lanes.":
            "结构体声明头与构造器在双侧通道保持一致，无语义漂移。",
        "Clean Semantic Auto-Merge: Added new method 'verifyPasskeyAssertion' from Claude Code.":
            "语义无冲突自动合并：采纳 Claude Code 新增方法 'verifyPasskeyAssertion'。",
        "Clean Semantic Auto-Merge: Added new method 'rotateSessionSubkeys' from OpenAI Codex.":
            "语义无冲突自动合并：采纳 OpenAI Codex 新增方法 'rotateSessionSubkeys'。",
        "True Intra-Function Conflict: Claude Code added 15s passkey UV leeway while Codex added HKDF minAcceptedKeyEpoch parameter & JTI check.":
            "函数内真实冲突：Claude Code 新增 15s 通行密钥 UV 容差，而 Codex 新增 HKDF minAcceptedKeyEpoch 参数与 JTI 校验。",
        "'validateTokenClaims' gained required parameter 'minAcceptedKeyEpoch' in lane-codex-auth, impacting call-site in HTTP3AuthMiddleware.swift:48 (lane-agy-gateway).":
            "'validateTokenClaims' 在 lane-codex-auth 中新增必填参数 'minAcceptedKeyEpoch'，影响调用点 HTTP3AuthMiddleware.swift:48 (lane-agy-gateway)。",

        // Territory Fence & Ownership Collision Warnings
        "Outside allowed globs [Sources/Auth/**, Sources/Crypto/**]; owned by lane-claude-quic (Sources/Transport/**)":
            "超出授权围栏 [Sources/Auth/**, Sources/Crypto/**]；该路径归属 lane-claude-quic (Sources/Transport/**)",
        "OpenAI Codex (lane-codex-auth) modified HTTP3ConnectionPool.swift inside Claude Code's Sources/Transport/** territory to wire subkey epoch callbacks.":
            "OpenAI Codex (lane-codex-auth) 越界修改了 Claude Code 领地 Sources/Transport/** 内的 HTTP3ConnectionPool.swift 以接入子密钥纪元回调。",

        // Built-in & Lifecycle Plugin Names & Summaries
        "Destructive Shell Command Blocker": "破坏性 Shell 命令拦截器",
        "Territory Fence Cross-Lane Guard": "跨通道领地围栏守卫",
        "Outbound Prompt Secret Redactor": "外发提示词密钥脱敏器",
        "Wiretap Token & Cache Efficiency Auditor": "Wiretap 令牌与缓存效率审计器",
        "AST Conventional Commit Synthesizer": "AST 约定式提交生成器",
        "Secret & Local-Path Leak Blocker": "密钥与本机路径泄漏拦截器",
        "Test Coverage Gate Enforcer": "测试覆盖率门禁守卫",
        "Vetoes merges containing API credentials (AWS/Anthropic/OpenAI/GitHub), private keys, or hardcoded /Users paths.":
            "否决包含 API 凭据 (AWS/Anthropic/OpenAI/GitHub)、私钥或硬编码 /Users 路径的合并。",
        "Checks that lanes introducing production declarations under Sources/ also contribute test suites under Tests/.":
            "检查在 Sources/ 下新增生产声明的通道是否同步在 Tests/ 下补充测试套件。",
        "Synthesizes deterministic Conventional Commit titles from AST symbol deltas across merged agent lanes.":
            "基于多智能体通道合并后的 AST 符号增量合成确定性的约定式提交标题。",
        "Flags lanes approaching their USD circuit ceiling or exhibiting < 15% prompt-cache reuse on large contexts.":
            "标记接近美元预算熔断上限或大上下文提示词缓存命中率低于 15% 的通道。",
        "Intercepts git reset --hard, git push --force, git clean -fdx, and recursive root deletions on onCommandSpawn.":
            "在 onCommandSpawn 阶段拦截 git reset --hard、git push --force、git clean -fdx 及根目录递归删除。",
        "Flags cross-lane file touches violating worktree ownership globs on onFileTouch.":
            "在 onFileTouch 阶段标记违反工作树领地归属规则的跨通道文件修改。",
        "Masks accidentally pasted API tokens inside outbound LLM prompts on onWiretapRequest.":
            "在 onWiretapRequest 阶段自动脱敏外发大模型提示词中误粘贴的 API 令牌。",

        // Guardrail Findings & Hook Trace Summaries
        "Blocked destructive shell invocation (git reset --hard)":
            "已拦截高危破坏性 Shell 调用 (git reset --hard)",
        "Intercepted `git reset --hard HEAD~1` spawned by OpenAI Codex during HKDF retry; preserved uncommitted worktree state.":
            "已拦截 OpenAI Codex 在 HKDF 重试期间发起的 `git reset --hard HEAD~1`，完整保留未提交工作树修改。",
        "Cross-lane territory drift detected":
            "检测到跨通道领地越界漂移",
        "Lane 'lane-codex-auth' edited 'Sources/Transport/HTTP3ConnectionPool.swift' outside assigned globs [Sources/Auth/**, Sources/Crypto/**].":
            "通道 'lane-codex-auth' 修改了授权范围 [Sources/Auth/**, Sources/Crypto/**] 之外的 'Sources/Transport/HTTP3ConnectionPool.swift'。",
        "Masked test credential token in outbound prompt":
            "已脱敏外发提示词中的测试凭据令牌",
        ("Redacted fixture token `" + "sk-ant-" + "api03-••••9f2a` → `[REDACTED:ANTHROPIC_API_KEY:8c41e09b]` before packet left 127.0.0.1."):
            "数据包离开 127.0.0.1 前已将测试令牌脱敏为 `[REDACTED:ANTHROPIC_API_KEY:8c41e09b]`。",
        "Circuit breaker tripped on lane-codex-auth (103% of $1.15 cap)":
            "lane-codex-auth 触发预算熔断器 (达 $1.15 上限的 103%)",
        "OpenAI Codex lane reached $1.186 across 6 heavy reasoning turns; turn #7 halted with HTTP 429 locally.":
            "OpenAI Codex 通道经 6 轮深度推理累计消耗 $1.186；第 7 轮已在本地以 HTTP 429 熔断拦截。",
        "Synthesized Conventional Commit Proposal":
            "已生成约定式提交建议",
        "Synthesized Conventional Commit":
            "已生成约定式提交建议",
        "Production AST modified without companion Tests/ update":
            "修改生产环境 AST 符号但未同步补充 Tests/ 测试",
        "Masked test credential token in .env fixture snippet":
            "已脱敏 .env 测试夹具片段中的凭据令牌",
        "Blocked destructive command: git reset --hard":
            "已拦截高危命令：git reset --hard",
        "Path outside assigned territory globs [Sources/Auth/**, Sources/Crypto/**]":
            "路径超出分配的领地围栏范围 [Sources/Auth/**, Sources/Crypto/**]",
        "3 symbols auto-merged cleanly; 1 intra-function conflict in validateTokenClaims requires operator resolution":
            "3 个符号已无冲突自动合并；validateTokenClaims 内 1 处函数体冲突需人工裁决",

        // Checkpoint Labels
        "Wave 2 Handoff · Pre-Merge Snapshot": "第 2 波交接 · 合并前快照",
        "Captured automatically before 3-Way Semantic AST reconciliation of AuthSessionManager.swift":
            "在 AuthSessionManager.swift 执行三路 AST 语义合并前自动捕获",

        // DLP Secret Category Display Titles
        ".env Secret Assignment": ".env 密钥环境变量赋值",
        "PEM Cryptographic Private Key": "PEM 加密私钥证书",
        "OpenSSH Private Key Block": "OpenSSH 私钥数据块",
        "Anthropic API Key": "Anthropic API 密钥",
        "OpenAI Project / Secret Key": "OpenAI 项目 / 访问密钥",
        "Google Cloud / Gemini API Key": "Google Cloud / Gemini API 密钥",
        "GitHub Personal Access Token": "GitHub 个人访问令牌 (PAT)",
        "AWS IAM Access Key ID": "AWS IAM 访问密钥 ID",
        "AWS IAM Secret Access Key": "AWS IAM 秘密访问密钥",
        "Stripe Live Secret / Restricted Key": "Stripe 生产环境秘密密钥",
        "Slack Bot / User Token": "Slack 机器人 / 用户令牌",
        "Signed JSON Web Token (JWT)": "签名 JSON Web 令牌 (JWT)",
        "Local /Users SSH Key or Config Path": "本机 /Users SSH 密钥或配置路径",
        "Hardcoded macOS /Users Home Path": "硬编码 macOS /Users 主目录路径",
        "Database URI with Embedded Password": "内嵌明文密码的数据库连接串",
        "High-Entropy Bearer / Secret Token": "高信息熵 Bearer / 凭据令牌",

        // Conflict Resolution Strategy Titles & Scratchpad Verdicts
        "Accept Left Lane": "采纳左侧通道",
        "Accept Right Lane": "采纳右侧通道",
        "Accept Both (Ordered)": "双侧顺序合并",
        "Interleave Container Members by Name": "按符号名交错合并成员",
        "Prefer Verified Test-Passing Lane": "优先采纳验证通过通道",
        "Destructive history/tree wipe prohibited": "禁止执行高危历史回滚或目录清空命令",
        "Verified safe worktree command": "已验证安全工作树命令",
        "Blocked destructive shell command": "已拦截破坏性 Shell 命令",
        "Live JSCore Scratchpad": "实时 JSCore 钩子演练台",

        // FTS5 Document Corpus Titles
        "PTY Terminal Transcript": "PTY 终端实录",
        "Task Prompt Brief": "任务指派简报",
        "Agent Handoff Artifact": "智能体交接产物",
        "3-Way AST Merge History": "三路 AST 合并历史",
        "Guardrail Audit Finding": "护栏审计记录"
    ]
}

// MARK: - Domain Enum Localization Extensions

public extension RelayStudioPane {
    func localizedTitle(in language: RelayLanguage) -> String {
        switch self {
        case .ptyGrid:
            return RelayLocalizer.select(language, "PTY Multiplexer", "并行终端网格")
        case .dagPipeline:
            return RelayLocalizer.select(language, "Relay DAG", "DAG 接力编排")
        case .semanticMerge:
            return RelayLocalizer.select(language, "3-Way AST Merge", "三路语义合并")
        case .territoryMap:
            return RelayLocalizer.select(language, "Isometric Territory", "领地围栏地图")
        case .wiretapBudget:
            return RelayLocalizer.select(language, "Wiretap & Spend", "Wiretap 预算网关")
        case .guardrailPlugins:
            return RelayLocalizer.select(language, "Guardrail Plugins", "JSC 编排插件")
        }
    }
}

public extension AgentVendor {
    func localizedDisplayName(in language: RelayLanguage) -> String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "OpenAI Codex"
        case .antigravity: return "Antigravity (agy)"
        case .mistralVibe: return "Mistral Vibe"
        case .customShell: return RelayLocalizer.select(language, "Verifier Shell", "验证终端")
        }
    }
}

public extension GuardrailSeverity {
    func localizedBadge(in language: RelayLanguage) -> String {
        switch self {
        case .pass: return RelayLocalizer.select(language, "PASS", "通过")
        case .advisory: return RelayLocalizer.select(language, "ADVISORY", "提示")
        case .warning: return RelayLocalizer.select(language, "WARNING", "警告")
        case .blocker: return RelayLocalizer.select(language, "BLOCKER", "阻断")
        }
    }
}

public extension RelayTaskStatus {
    func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .pending: return RelayLocalizer.select(language, "Pending", "待命")
        case .blockedOnDeps: return RelayLocalizer.select(language, "Waiting on Deps", "等待前置")
        case .running: return RelayLocalizer.select(language, "Running", "运行中")
        case .verifyingGate: return RelayLocalizer.select(language, "Verifying Gate", "门禁校验")
        case .completed: return RelayLocalizer.select(language, "Completed", "已完成")
        case .failed: return RelayLocalizer.select(language, "Failed", "已失败")
        case .haltedByBudget: return RelayLocalizer.select(language, "Budget Halted", "预算熔断")
        case .cancelled: return RelayLocalizer.select(language, "Cancelled", "已取消")
        }
    }
}

public extension ASTDeclarationKind {
    func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .importGroup: return RelayLocalizer.select(language, "Import Block", "导入块")
        case .packageOrModule: return RelayLocalizer.select(language, "Module Header", "模块头")
        case .structDecl: return RelayLocalizer.select(language, "Struct", "结构体")
        case .classDecl: return RelayLocalizer.select(language, "Class", "类")
        case .enumDecl: return RelayLocalizer.select(language, "Enum", "枚举")
        case .protocolOrInterface: return RelayLocalizer.select(language, "Protocol / Interface", "协议 / 接口")
        case .extensionOrImpl: return RelayLocalizer.select(language, "Extension / Impl", "扩展 / 实现")
        case .functionDecl: return RelayLocalizer.select(language, "Function", "函数")
        case .methodDecl: return RelayLocalizer.select(language, "Method", "方法")
        case .constantOrVar: return RelayLocalizer.select(language, "Binding / Property", "属性 / 绑定")
        case .typeAlias: return RelayLocalizer.select(language, "Type Alias", "类型别名")
        case .topLevelBlock: return RelayLocalizer.select(language, "Top-Level Statement", "顶层语句")
        }
    }
}

public extension SemanticMergeResolution {
    func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .unchanged:
            return RelayLocalizer.select(language, "Unchanged", "无变更")
        case .leftModifiedOnly:
            return RelayLocalizer.select(language, "Took Left Lane", "采纳左侧通道")
        case .rightModifiedOnly:
            return RelayLocalizer.select(language, "Took Right Lane", "采纳右侧通道")
        case .leftAddedDeclaration:
            return RelayLocalizer.select(language, "Added by Left Lane", "左侧通道新增")
        case .rightAddedDeclaration:
            return RelayLocalizer.select(language, "Added by Right Lane", "右侧通道新增")
        case .leftDeletedDeclaration:
            return RelayLocalizer.select(language, "Deleted by Left Lane", "左侧通道删除")
        case .rightDeletedDeclaration:
            return RelayLocalizer.select(language, "Deleted by Right Lane", "右侧通道删除")
        case .autoMergedImportSetUnion:
            return RelayLocalizer.select(language, "Auto-Merged Import Union", "自动合并导入并集")
        case .autoMergedIdenticalChange:
            return RelayLocalizer.select(language, "Auto-Merged Identical Edits", "自动合并相同修改")
        case .autoMergedNestedMembers:
            return RelayLocalizer.select(language, "Auto-Merged Disjoint Type Members", "自动合并离散成员")
        case .conflictBothModifiedSameSymbol:
            return RelayLocalizer.select(language, "Conflict: Same Declaration Diverged", "冲突：同一声明分叉")
        case .conflictDeleteModify:
            return RelayLocalizer.select(language, "Conflict: Deleted vs Modified", "冲突：删除与修改竞争")
        }
    }
}

public extension RelayPluginCapability {
    func localizedLabel(in language: RelayLanguage) -> String {
        switch self {
        case .inspectDiffs:
            return RelayLocalizer.select(language, rawValue, "审查差异")
        case .inspectASTNodes:
            return RelayLocalizer.select(language, rawValue, "审查 AST")
        case .inspectTokenTelemetry:
            return RelayLocalizer.select(language, rawValue, "令牌遥测")
        case .vetoMergeGate:
            return RelayLocalizer.select(language, rawValue, "合并否决")
        case .synthesizeCommitMessage:
            return RelayLocalizer.select(language, rawValue, "生成提交")
        }
    }
}
