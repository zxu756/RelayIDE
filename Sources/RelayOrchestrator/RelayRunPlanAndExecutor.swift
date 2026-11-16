import CryptoKit
import Darwin
import Foundation
import RelayModels
import RelayWorkspaceStore
import RelayWorktreeGit

// MARK: - Resolved `relay.sh` Descriptor (`03-relayide.md` §2, §3, §4)

public struct ResolvedRelayScript: Sendable, Equatable {
    public let url: URL
    public let utilURL: URL
    public let sha256Hex: String

    public init(url: URL, utilURL: URL, sha256Hex: String) {
        self.url = url
        self.utilURL = utilURL
        self.sha256Hex = sha256Hex
    }
}

// MARK: - UTC Run Identifier Generator (`YYYYMMDD-HHMMSS-<4hex>`, `03-relayide.md` §4)

public enum RelayRunIDGenerator {
    public static func generate(now: Date = Date(), randomSuffix: UInt16? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let suffix = randomSuffix ?? UInt16.random(in: UInt16.min ... UInt16.max)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%04x",
            year, month, day, hour, minute, second, suffix
        )
    }
}

// MARK: - Pre-Run Plan & Repository Validator (`03-relayide.md` §2, §3, R38, R44, R46)

public enum RelayPlanValidator {
    /// Enforces `^[a-z0-9][a-z0-9-]{0,39}$` strictly over ASCII bytes and reserves `"integration"`.
    public static func isValidLaneID(_ id: String) -> Bool {
        RelayPlanLaneSpec.isValidLaneID(id)
    }

    /// Validates `plan.json`, environment preconditions (`RELAY_BUDGET_USD`), lane IDs, prompts, single-predecessor DAG,
    /// target Git repository, `--project` outside `repo` working tree, `base` commit OID, and Git committer identity.
    /// Throws `RelayIDEError.invalidRunPlan` (`cliExitCode == 2`) before any worktree, branch, directory, or DB row is created.
    public static func validate(
        planFileURL: URL,
        projectBundleURL: URL,
        environment: [String: String],
        language: RelayLanguage
    ) throws -> RelayValidatedRunPlan {
        let isZh = language.isChinese

        // 1. Reject RELAY_BUDGET_USD prior to M4 (R44, R63)
        if let rawBudget = environment["RELAY_BUDGET_USD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawBudget.isEmpty {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "当前不支持环境变量 RELAY_BUDGET_USD（各通道在独立 worktree 中不累计整单预算，预算控制排在 M4）"
                    : "RELAY_BUDGET_USD is not supported yet (spend does not accumulate across isolated lane worktrees; whole-job budget enforcement is scheduled for M4)"
            )
        }

        // 2. Read & decode plan.json
        let standardizedPlanURL = planFileURL.standardizedFileURL
        var isPlanDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedPlanURL.path, isDirectory: &isPlanDir),
              !isPlanDir.boolValue,
              FileManager.default.isReadableFile(atPath: standardizedPlanURL.path) else {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "计划文件不存在或不可读：'\(standardizedPlanURL.path)'"
                    : "Plan file does not exist or is not readable: '\(standardizedPlanURL.path)'"
            )
        }

        let rawPlanData: Data
        do {
            rawPlanData = try Data(contentsOf: standardizedPlanURL)
        } catch {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "无法读取计划文件 '\(standardizedPlanURL.path)'：\(error.localizedDescription)"
                    : "Failed to read plan file '\(standardizedPlanURL.path)': \(error.localizedDescription)"
            )
        }

        if hasNonIntegerTopLevelVerifyTimeoutLiteral(in: rawPlanData) {
            let schemaErr = RelayPlanSchemaError.invalidFieldType(
                field: "verify_timeout",
                expectedEN: "an integer (1...86400)",
                expectedZH: "1 到 86400 的整数"
            )
            throw RelayIDEError.invalidRunPlan(schemaErr.localizedDescription(in: language))
        }

        let plan: RelayRunPlan
        do {
            plan = try JSONDecoder().decode(RelayRunPlan.self, from: rawPlanData)
        } catch let schemaErr as RelayPlanSchemaError {
            throw RelayIDEError.invalidRunPlan(schemaErr.localizedDescription(in: language))
        } catch let decodingErr as DecodingError {
            throw RelayIDEError.invalidRunPlan(
                describePlanDecodingError(decodingErr, planPath: standardizedPlanURL.path, isZh: isZh)
            )
        } catch {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "计划文件 '\(standardizedPlanURL.path)' 不是合法的 JSON 或字段类型不匹配：\(error.localizedDescription)"
                    : "Plan file '\(standardizedPlanURL.path)' is not valid JSON or has invalid field types: \(error.localizedDescription)"
            )
        }

        let rawRepo = plan.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRepo.isEmpty else {
            throw RelayIDEError.invalidRunPlan(
                isZh ? "计划字段 'repo' 不能为空" : "Plan field 'repo' must not be empty"
            )
        }

        let baseRef = plan.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRef.isEmpty, !baseRef.hasPrefix("-") else {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "计划字段 'base' 不能为空且不能以 '-' 开头：'\(plan.base)'"
                    : "Plan field 'base' must be non-empty and must not start with '-': '\(plan.base)'"
            )
        }

        guard !plan.lanes.isEmpty else {
            throw RelayIDEError.invalidRunPlan(
                isZh ? "计划字段 'lanes' 至少需要包含一条通道" : "Plan field 'lanes' must contain at least one lane"
            )
        }

        let planBaseDir = standardizedPlanURL.deletingLastPathComponent()

        // 3. Validate lane IDs, uniqueness, vendor names, and prompt files
        var seenLaneIDs = Set<String>()
        var validatedLanes: [RelayValidatedLaneSpec] = []
        validatedLanes.reserveCapacity(plan.lanes.count)

        for (ordinal, rawLane) in plan.lanes.enumerated() {
            guard isValidLaneID(rawLane.id) else {
                let reservedHint = rawLane.id == "integration"
                    ? (isZh ? "（'integration' 为保留名）" : " ('integration' is reserved)")
                    : ""
                throw RelayIDEError.invalidRunPlan(
                    isZh
                        ? "通道名 '\(rawLane.id)' 不合法\(reservedHint)：必须匹配 ^[a-z0-9][a-z0-9-]{0,39}$"
                        : "Invalid lane id '\(rawLane.id)'\(reservedHint): must match ^[a-z0-9][a-z0-9-]{0,39}$"
                )
            }

            guard seenLaneIDs.insert(rawLane.id).inserted else {
                throw RelayIDEError.invalidRunPlan(
                    isZh
                        ? "计划中存在重复的通道名 '\(rawLane.id)'"
                        : "Duplicate lane id '\(rawLane.id)' in plan"
                )
            }

            guard let parsedAgent = RelayPlanAgent(rawValue: rawLane.agent) else {
                throw RelayIDEError.invalidRunPlan(
                    isZh
                        ? "通道 '\(rawLane.id)' 使用了未知的 agent '\(rawLane.agent)'（仅支持 claude、codex、agy、vibe）"
                        : "Lane '\(rawLane.id)' specifies unknown agent '\(rawLane.agent)' (expected claude, codex, agy, or vibe)"
                )
            }

            let trimmedPrompt = rawLane.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPrompt.isEmpty, trimmedPrompt != "-" else {
                throw RelayIDEError.invalidRunPlan(
                    isZh
                        ? "通道 '\(rawLane.id)' 的提示文件路径不合法：'\(rawLane.prompt)'"
                        : "Lane '\(rawLane.id)' has invalid prompt path: '\(rawLane.prompt)'"
                )
            }

            let resolvedPromptURL = resolvePath(rawLane.prompt, relativeToDirectory: planBaseDir)
            var isPromptDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedPromptURL.path, isDirectory: &isPromptDir),
                  !isPromptDir.boolValue,
                  FileManager.default.isReadableFile(atPath: resolvedPromptURL.path) else {
                throw RelayIDEError.invalidRunPlan(
                    isZh
                        ? "通道 '\(rawLane.id)' 的提示文件不存在或不可读：'\(resolvedPromptURL.path)'"
                        : "Prompt file for lane '\(rawLane.id)' does not exist or is not readable: '\(resolvedPromptURL.path)'"
                )
            }

            validatedLanes.append(
                RelayValidatedLaneSpec(
                    ordinal: ordinal,
                    id: rawLane.id,
                    agent: parsedAgent,
                    rawPrompt: rawLane.prompt,
                    resolvedPromptURL: resolvedPromptURL,
                    after: rawLane.after
                )
            )
        }

        // 4. Validate `after` references, single-predecessor rule, and DAG acyclicity (R38)
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for lane in validatedLanes {
            inDegree[lane.id] = 0
        }

        for lane in validatedLanes {
            for dep in lane.after {
                guard seenLaneIDs.contains(dep) else {
                    throw RelayIDEError.invalidRunPlan(
                        isZh
                            ? "通道 '\(lane.id)' 的 after 引用了不存在的通道 '\(dep)'"
                            : "Lane '\(lane.id)' references nonexistent after lane '\(dep)'"
                    )
                }
                if dep == lane.id {
                    throw RelayIDEError.invalidRunPlan(
                        isZh
                            ? "通道 '\(lane.id)' 的依赖存在自环"
                            : "Lane '\(lane.id)' depends on itself (cycle)"
                    )
                }
            }
            guard lane.after.count <= 1 else {
                throw RelayIDEError.invalidRunPlan(
                    isZh
                        ? "通道 '\(lane.id)' 指定了多个前置通道 \(lane.after)；每条通道最多允许一个前置"
                        : "Lane '\(lane.id)' specifies multiple predecessors \(lane.after); at most one predecessor per lane is supported"
                )
            }
            inDegree[lane.id] = lane.after.count
            for dep in lane.after {
                dependents[dep, default: []].append(lane.id)
            }
        }

        var queue: [String] = validatedLanes.compactMap { lane in
            (inDegree[lane.id] ?? 0) == 0 ? lane.id : nil
        }
        var queueIndex = 0
        var visitedCount = 0
        while queueIndex < queue.count {
            let current = queue[queueIndex]
            queueIndex += 1
            visitedCount += 1
            for child in dependents[current] ?? [] {
                let nextDeg = (inDegree[child] ?? 1) - 1
                inDegree[child] = nextDeg
                if nextDeg == 0 {
                    queue.append(child)
                }
            }
        }

        if visitedCount < validatedLanes.count {
            let cyclicIDs = validatedLanes.map(\.id).filter { (inDegree[$0] ?? 0) > 0 }
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "计划中的通道依赖存在环：\(cyclicIDs.joined(separator: " -> "))"
                    : "Dependency cycle detected among lanes: \(cyclicIDs.joined(separator: " -> "))"
            )
        }

        // 5. Resolve `repo`, verify Git working tree, and ensure `--project` is outside `repo`
        let candidateRepoURL = resolvePath(plan.repo, relativeToDirectory: planBaseDir)
        var isRepoDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateRepoURL.path, isDirectory: &isRepoDir),
              isRepoDir.boolValue else {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "计划指定的目标仓库目录不存在：'\(candidateRepoURL.path)'"
                    : "Target repository directory does not exist: '\(candidateRepoURL.path)'"
            )
        }

        let git = GitWorktreePlumbingEngine()
        let insideCheck = try? git.runGitCommand(
            ["rev-parse", "--is-inside-work-tree"],
            cwd: candidateRepoURL.path,
            environment: environment
        )
        let topLevelCheck = try? git.runGitCommand(
            ["rev-parse", "--show-toplevel"],
            cwd: candidateRepoURL.path,
            environment: environment
        )
        let insideWorkTree = insideCheck?.exitCode == 0
            && insideCheck?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let topLevelPath = topLevelCheck?.exitCode == 0
            ? topLevelCheck?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        guard insideWorkTree, !topLevelPath.isEmpty else {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "路径 '\(candidateRepoURL.path)' 不是有效的 Git 工作区仓库"
                    : "Path '\(candidateRepoURL.path)' is not a valid Git working tree repository"
            )
        }

        let resolvedRepoURL = URL(fileURLWithPath: topLevelPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalRepoPath = canonicalPathString(resolvedRepoURL)
        let canonicalProjectPath = canonicalPathString(projectBundleURL)
        if canonicalProjectPath == canonicalRepoPath
            || canonicalProjectPath.hasPrefix(canonicalRepoPath + "/") {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "工程目录 '\(projectBundleURL.path)' 位于目标仓库工作区 '\(resolvedRepoURL.path)' 内部，拒绝运行以免污染工作树"
                    : "Project directory '\(projectBundleURL.path)' is inside target repository working tree '\(resolvedRepoURL.path)'; refusing to run"
            )
        }

        // 6. Resolve `base` to commit OID
        let baseCheck = try? git.runGitCommand(
            ["rev-parse", "--verify", "--quiet", "\(baseRef)^{commit}"],
            cwd: resolvedRepoURL.path,
            environment: environment
        )
        let baseCommitOID = baseCheck?.exitCode == 0
            ? baseCheck?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        guard !baseCommitOID.isEmpty else {
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "无法在仓库 '\(resolvedRepoURL.path)' 中解析基准引用 '\(baseRef)'"
                    : "Cannot resolve base reference '\(baseRef)' to a commit in '\(resolvedRepoURL.path)'"
            )
        }

        // 7. Verify Git committer identity without hostname fallback (`git -c user.useConfigOnly=true var GIT_COMMITTER_IDENT`, R46)
        let identCheck = try? git.runGitCommand(
            ["-c", "user.useConfigOnly=true", "var", "GIT_COMMITTER_IDENT"],
            cwd: resolvedRepoURL.path,
            environment: environment
        )
        let identOutput = identCheck?.exitCode == 0
            ? identCheck?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        guard !identOutput.isEmpty else {
            let detail = identCheck?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RelayIDEError.invalidRunPlan(
                isZh
                    ? "目标仓库 '\(resolvedRepoURL.path)' 未配置 Git 提交者身份（请配置 user.name 和 user.email）\(detail.isEmpty ? "" : "：\(detail)")"
                    : "Target repository '\(resolvedRepoURL.path)' has no configured Git committer identity (set user.name and user.email)\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }

        let normalizedVerify: String?
        if let rawVerify = plan.verify,
           !rawVerify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedVerify = rawVerify
        } else {
            normalizedVerify = nil
        }

        if let explicitTimeout = plan.verifyTimeout {
            guard RelayRunPlan.validVerifyTimeoutRange.contains(explicitTimeout) else {
                throw RelayIDEError.invalidRunPlan(
                    RelayPlanSchemaError.verifyTimeoutOutOfRange(explicitTimeout).localizedDescription(in: language)
                )
            }
            guard normalizedVerify != nil else {
                throw RelayIDEError.invalidRunPlan(
                    RelayPlanSchemaError.verifyTimeoutWithoutVerify.localizedDescription(in: language)
                )
            }
        }
        let effectiveVerifyTimeoutSec: Int? = normalizedVerify != nil
            ? (plan.verifyTimeout ?? RelayRunPlan.defaultVerifyTimeoutSeconds)
            : nil

        return RelayValidatedRunPlan(
            planFileURL: standardizedPlanURL,
            rawPlanData: rawPlanData,
            plan: plan,
            resolvedRepoURL: resolvedRepoURL,
            baseRef: baseRef,
            baseCommitOID: baseCommitOID,
            lanes: validatedLanes,
            verifyCommand: normalizedVerify,
            verifyTimeoutSec: effectiveVerifyTimeoutSec
        )
    }

    /// Detects top-level `"verify_timeout": <number>` literals containing `.`, `e`, or `E` (e.g. `1.0`),
    /// which `JSONDecoder.decode(Int.self)` may coerce to `Int` even though the JSON token is floating-point.
    private static func hasNonIntegerTopLevelVerifyTimeoutLiteral(in data: Data) -> Bool {
        let bytes = Array(data)
        var i = 0
        let n = bytes.count

        func skipWhitespace() {
            while i < n {
                let b = bytes[i]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    i += 1
                } else {
                    break
                }
            }
        }

        func readJSONString() -> String? {
            guard i < n, bytes[i] == 0x22 else { return nil }
            let start = i
            i += 1
            while i < n {
                let b = bytes[i]
                if b == 0x5C {
                    i += 2
                    continue
                }
                if b == 0x22 {
                    i += 1
                    let slice = Data(bytes[start..<i])
                    return try? JSONDecoder().decode(String.self, from: slice)
                }
                i += 1
            }
            return nil
        }

        skipWhitespace()
        guard i < n, bytes[i] == 0x7B else { return false }
        var depth = 0
        while i < n {
            let b = bytes[i]
            if b == 0x22 {
                let keyCandidate = readJSONString()
                if depth == 1, keyCandidate == "verify_timeout" {
                    skipWhitespace()
                    if i < n, bytes[i] == 0x3A {
                        i += 1
                        skipWhitespace()
                        if i < n {
                            let vb = bytes[i]
                            if vb == 0x2D || (vb >= 0x30 && vb <= 0x39) {
                                var hasFloatMarker = false
                                while i < n {
                                    let nb = bytes[i]
                                    if nb == 0x2E || nb == 0x65 || nb == 0x45 {
                                        hasFloatMarker = true
                                        i += 1
                                    } else if (nb >= 0x30 && nb <= 0x39) || nb == 0x2B || nb == 0x2D {
                                        i += 1
                                    } else {
                                        break
                                    }
                                }
                                if hasFloatMarker {
                                    return true
                                }
                            }
                        }
                    }
                }
                continue
            }
            if b == 0x7B || b == 0x5B {
                depth += 1
            } else if b == 0x7D || b == 0x5D {
                depth -= 1
                if depth <= 0 {
                    break
                }
            }
            i += 1
        }
        return false
    }

    private static func describePlanDecodingError(
        _ error: DecodingError,
        planPath: String,
        isZh: Bool
    ) -> String {
        let codingPath: [CodingKey]
        switch error {
        case .keyNotFound(let key, let ctx):
            codingPath = ctx.codingPath + [key]
        case .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx),
             .dataCorrupted(let ctx):
            codingPath = ctx.codingPath
        @unknown default:
            codingPath = []
        }
        let fieldPath = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        if !fieldPath.isEmpty {
            return isZh
                ? "计划文件 '\(planPath)' 字段 '\(fieldPath)' 不合法：\(error.localizedDescription)"
                : "Plan file '\(planPath)' has invalid field '\(fieldPath)': \(error.localizedDescription)"
        }
        return isZh
            ? "计划文件 '\(planPath)' 不是合法的 JSON 或顶层不是对象：\(error.localizedDescription)"
            : "Plan file '\(planPath)' is not valid JSON or top-level value is not an object: \(error.localizedDescription)"
    }

    private static func resolvePath(_ rawPath: String, relativeToDirectory baseDir: URL) -> URL {
        if (rawPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }
        return URL(fileURLWithPath: rawPath, relativeTo: baseDir).standardizedFileURL
    }

    private static func canonicalPathString(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        var missingTail: [String] = []
        var cursor = standardized
        while !FileManager.default.fileExists(atPath: cursor.path) && cursor.path != "/" {
            missingTail.append(cursor.lastPathComponent)
            cursor = cursor.deletingLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingTail.reversed() {
            resolved.appendPathComponent(component)
        }
        var path = resolved.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

// MARK: - `RelayIDE run` Pre-Scheduling & Execution Coordinator (`03-relayide.md` §2, §4, §9, §12)

public struct RelayRunExecutionOutcome: Sendable, Equatable {
    public let runRecord: RelayRunRecord?
    public let stderrNotes: [String]
    public let exitCode: Int32
    public let error: RelayIDEError?

    public init(
        runRecord: RelayRunRecord?,
        stderrNotes: [String] = [],
        exitCode: Int32,
        error: RelayIDEError? = nil
    ) {
        self.runRecord = runRecord
        self.stderrNotes = stderrNotes
        self.exitCode = exitCode
        self.error = error
    }
}

public struct RelayRunExecutor: Sendable {
    public let runIDProvider: (@Sendable () -> String)?
    public let activeLaneRegistry: RelayActiveLaneRegistry?
    public let cancellationPolicy: RelayCancellationPolicy

    public init(
        runIDProvider: (@Sendable () -> String)? = nil,
        activeLaneRegistry: RelayActiveLaneRegistry? = nil,
        cancellationPolicy: RelayCancellationPolicy = .default
    ) {
        self.runIDProvider = runIDProvider
        self.activeLaneRegistry = activeLaneRegistry
        self.cancellationPolicy = cancellationPolicy
    }

    /// Resolves `relay.sh` in order: `--relay-sh`, `RELAYIDE_RELAY_SH`, `$HOME/.agents/skills/agent-relay/scripts/relay.sh`.
    /// Verifies executable permission, sibling `relay_util.py`, and computes lowercase SHA-256 hex.
    /// Throws `RelayIDEError.relayEnvironmentFailure` (`cliExitCode == 125`) when missing or unusable.
    public static func resolveAndVerifyRelayScript(
        explicitPath: String?,
        environment: [String: String],
        language: RelayLanguage
    ) throws -> ResolvedRelayScript {
        let isZh = language.isChinese
        let candidatePath: String
        if let explicitPath {
            candidatePath = explicitPath
        } else if let envRelay = environment["RELAYIDE_RELAY_SH"], !envRelay.isEmpty {
            candidatePath = envRelay
        } else {
            let homeDir: String
            if let envHome = environment["HOME"], !envHome.isEmpty {
                homeDir = envHome
            } else {
                homeDir = NSHomeDirectory()
            }
            candidatePath = (homeDir as NSString).appendingPathComponent(".agents/skills/agent-relay/scripts/relay.sh")
        }

        let relayURL = URL(fileURLWithPath: candidatePath).standardizedFileURL
        var isRelayDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: relayURL.path, isDirectory: &isRelayDir),
              !isRelayDir.boolValue else {
            throw RelayIDEError.relayEnvironmentFailure(
                isZh
                    ? "找不到 relay.sh：'\(relayURL.path)'"
                    : "relay.sh not found at '\(relayURL.path)'"
            )
        }

        guard FileManager.default.isExecutableFile(atPath: relayURL.path) else {
            throw RelayIDEError.relayEnvironmentFailure(
                isZh
                    ? "relay.sh 不可执行：'\(relayURL.path)'"
                    : "relay.sh is not executable: '\(relayURL.path)'"
            )
        }

        let utilURL = relayURL.deletingLastPathComponent().appendingPathComponent("relay_util.py")
        var isUtilDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: utilURL.path, isDirectory: &isUtilDir),
              !isUtilDir.boolValue,
              FileManager.default.isReadableFile(atPath: utilURL.path) else {
            throw RelayIDEError.relayEnvironmentFailure(
                isZh
                    ? "relay.sh 旁边缺少可读的 relay_util.py：'\(utilURL.path)'"
                    : "Missing readable sibling relay_util.py next to relay.sh: '\(utilURL.path)'"
            )
        }

        let scriptBytes: Data
        do {
            scriptBytes = try Data(contentsOf: relayURL)
        } catch {
            throw RelayIDEError.relayEnvironmentFailure(
                isZh
                    ? "读取 relay.sh 失败（'\(relayURL.path)'）：\(error.localizedDescription)"
                    : "Failed to read relay.sh ('\(relayURL.path)'): \(error.localizedDescription)"
            )
        }
        let sha256Hex = SHA256.hash(data: scriptBytes).map { String(format: "%02x", $0) }.joined()
        return ResolvedRelayScript(url: relayURL, utilURL: utilURL, sha256Hex: sha256Hex)
    }

    public func execute(
        planPath: String,
        projectBundlePath: String,
        explicitRelayShPath: String?,
        language: RelayLanguage,
        environment: [String: String],
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async -> RelayRunExecutionOutcome {
        let isZh = language.isChinese
        let projectBundleURL = URL(fileURLWithPath: projectBundlePath).standardizedFileURL
        let planFileURL = URL(fileURLWithPath: planPath).standardizedFileURL

        // 1. Project bundle must already be `init`-ed (`exit 2`, never auto-create)
        guard RelayProjectDatabase.bundleExists(at: projectBundleURL) else {
            let missingErr = RelayIDEError.workspaceBundleNotFound(projectBundlePath)
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: [],
                exitCode: missingErr.cliExitCode,
                error: missingErr
            )
        }

        // 2. Validate plan.json, repo, base, git identity, project-outside-repo, and RELAY_BUDGET_USD (`exit 2`)
        let validatedPlan: RelayValidatedRunPlan
        do {
            validatedPlan = try RelayPlanValidator.validate(
                planFileURL: planFileURL,
                projectBundleURL: projectBundleURL,
                environment: environment,
                language: language
            )
        } catch let relayErr as RelayIDEError {
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: [],
                exitCode: relayErr.cliExitCode,
                error: relayErr
            )
        } catch {
            let wrapped = RelayIDEError.invalidRunPlan(error.localizedDescription)
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: [],
                exitCode: wrapped.cliExitCode,
                error: wrapped
            )
        }

        // 3. Reject nested execution when RELAY_WORKER is set (`exit 125`, R45)
        if let worker = environment["RELAY_WORKER"], !worker.isEmpty {
            let nestedErr = RelayIDEError.relayEnvironmentFailure(
                isZh
                    ? "检测到环境变量 RELAY_WORKER='\(worker)'，拒绝嵌套调用 RelayIDE run"
                    : "Environment variable RELAY_WORKER='\(worker)' is set; refusing nested RelayIDE run"
            )
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: [],
                exitCode: nestedErr.cliExitCode,
                error: nestedErr
            )
        }

        // 4. Resolve & verify `relay.sh` + sibling `relay_util.py` + SHA-256 (`exit 125`)
        let relayScript: ResolvedRelayScript
        do {
            relayScript = try Self.resolveAndVerifyRelayScript(
                explicitPath: explicitRelayShPath,
                environment: environment,
                language: language
            )
        } catch let relayErr as RelayIDEError {
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: [],
                exitCode: relayErr.cliExitCode,
                error: relayErr
            )
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: [],
                exitCode: wrapped.cliExitCode,
                error: wrapped
            )
        }

        // 5. Open existing SQLite ledger, acquire non-blocking `<project>/run.lock`, copy `plan.json`, and persist `running`/`pending` rows
        final class StderrCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            private let liveHandler: (@Sendable (String) -> Void)?

            init(liveHandler: (@Sendable (String) -> Void)?) {
                self.liveHandler = liveHandler
            }

            func emit(_ line: String) {
                lock.lock()
                lines.append(line)
                lock.unlock()
                liveHandler?(line)
            }

            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return lines
            }
        }

        let collector = StderrCollector(liveHandler: onStderrLine)
        do {
            let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: projectBundleURL)
            let runID = try generateUniqueRunID(
                projectBundleURL: projectBundleURL,
                database: db,
                repositoryURL: validatedPlan.resolvedRepoURL,
                environment: environment
            )
            let runLock = try RelayProjectRunLock.acquire(
                bundleDirectoryURL: projectBundleURL,
                runID: runID,
                pid: getpid()
            )
            defer { runLock.release() }

            // Reconcile any prior crashed (`kill -9`) run rows permanently in SQLite now that we hold `run.lock`
            try? db.persistOrphanedRunsAsInterrupted(activeRunID: runID)

            let runDirectoryURL = projectBundleURL
                .appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
            try FileManager.default.createDirectory(at: runDirectoryURL, withIntermediateDirectories: true)
            let planCopyURL = runDirectoryURL.appendingPathComponent("plan.json")
            try validatedPlan.rawPlanData.write(to: planCopyURL, options: .atomic)

            if validatedPlan.verifyCommand != nil {
                collector.emit(
                    isZh
                        ? "提示：计划包含 verify 命令，M1 仅将其记录到运行台账，将在 M2 执行。"
                        : "Note: plan includes a 'verify' command; M1 records it in the run ledger without executing it (scheduled for M2)."
                )
            }

            let startedAt = Date()
            let pendingLanes = validatedPlan.lanes.map { lane in
                RelayRunLaneRecord(
                    runID: runID,
                    laneID: lane.id,
                    ordinal: lane.ordinal,
                    agent: lane.agent,
                    promptPath: lane.resolvedPromptURL.path,
                    after: lane.after,
                    status: .pending
                )
            }
            let initialRecord = RelayRunRecord(
                runID: runID,
                repoPath: validatedPlan.resolvedRepoURL.path,
                planCopyPath: planCopyURL.path,
                baseRef: validatedPlan.baseRef,
                baseCommitOID: validatedPlan.baseCommitOID,
                verifyCommand: validatedPlan.verifyCommand,
                relayShPath: relayScript.url.path,
                relayShSHA256: relayScript.sha256Hex,
                startedAt: startedAt,
                finishedAt: nil,
                status: .running,
                reason: nil,
                relayidePID: getpid(),
                lanes: pendingLanes
            )
            try db.createRun(initialRecord)

            let schedulerResult = try await executeScheduledLanes(
                runID: runID,
                validatedPlan: validatedPlan,
                relayScript: relayScript,
                runDirectoryURL: runDirectoryURL,
                projectBundleURL: projectBundleURL,
                database: db,
                language: language,
                environment: environment,
                emitStderrLine: collector.emit
            )
            return RelayRunExecutionOutcome(
                runRecord: schedulerResult.runRecord,
                stderrNotes: collector.snapshot(),
                exitCode: schedulerResult.cliExitCode,
                error: nil
            )
        } catch let relayErr as RelayIDEError {
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: collector.snapshot(),
                exitCode: relayErr.cliExitCode,
                error: relayErr
            )
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            return RelayRunExecutionOutcome(
                runRecord: nil,
                stderrNotes: collector.snapshot(),
                exitCode: wrapped.cliExitCode,
                error: wrapped
            )
        }
    }

    // MARK: - Stage 04 Lane Worktree Setup & Event-Driven DAG Scheduling (`RelayDAGRunScheduler`)

    private func executeScheduledLanes(
        runID: String,
        validatedPlan: RelayValidatedRunPlan,
        relayScript: ResolvedRelayScript,
        runDirectoryURL: URL,
        projectBundleURL: URL,
        database: RelayProjectDatabase,
        language: RelayLanguage,
        environment: [String: String],
        emitStderrLine: @escaping @Sendable (String) -> Void
    ) async throws -> RelayDAGRunSchedulerResult {
        let scheduler = RelayDAGRunScheduler(
            runID: runID,
            validatedPlan: validatedPlan,
            relayScript: relayScript,
            runDirectoryURL: runDirectoryURL,
            projectBundleURL: projectBundleURL,
            database: database,
            language: language,
            environment: environment,
            activeLaneRegistry: activeLaneRegistry ?? RelayActiveLaneRegistry(),
            cancellationPolicy: cancellationPolicy,
            emitStderrLine: emitStderrLine
        )
        do {
            // 1. Execute all DAG lanes (`relay_runs.status` remains `.running` in SQLite, R61).
            let laneSummary = try await scheduler.executeLanesPhase()

            // 2. Post-lane integration & verify phase slot (M2 Stage 4 inserts `runIntegrationMergePhase` + `verify` here).

            // 3. Persist terminal `relay_runs` status strictly AFTER the integration phase slot (R61).
            return try scheduler.persistTerminalRunStatus(afterIntegration: laneSummary)
        } catch let relayErr as RelayIDEError {
            scheduler.persistFatalErrorRunStatus(relayErr)
            throw relayErr
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            scheduler.persistFatalErrorRunStatus(wrapped)
            throw wrapped
        }
    }

    private func generateUniqueRunID(
        projectBundleURL: URL,
        database: RelayProjectDatabase,
        repositoryURL: URL,
        environment: [String: String]
    ) throws -> String {
        if let custom = runIDProvider {
            return custom()
        }
        let runsRootURL = projectBundleURL.appendingPathComponent("runs", isDirectory: true)
        let git = GitWorktreePlumbingEngine()
        for _ in 0..<32 {
            let candidate = RelayRunIDGenerator.generate()
            let candidateDir = runsRootURL.appendingPathComponent(candidate, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidateDir.path) {
                continue
            }
            if try database.fetchRun(runID: candidate, reconcileWithLock: false) != nil {
                continue
            }
            let refProbe = try? git.runGitCommand(
                ["for-each-ref", "--count=1", "--format=%(refname)", "refs/heads/relay/\(candidate)/"],
                cwd: repositoryURL.path,
                environment: environment
            )
            let existingRef = refProbe?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingRef.isEmpty {
                return candidate
            }
        }
        return RelayRunIDGenerator.generate()
    }
}
