import Darwin
import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelaySemanticMerge
import RelayWiretapProxy
import RelayWorkspaceStore
import RelayWorktreeGit

// MARK: - Structured Headless CLI Result & Runner

public struct RelayCLIExecutionResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let error: RelayIDEError?
    /// True when `stdout` is file content that must reach the caller byte for byte (no newline appended).
    /// `semantic-merge` sets it: an extra trailing newline would itself be a change nobody made.
    public let stdoutIsVerbatim: Bool
    /// True when `stderr` lines were already streamed live to `FileHandle.standardError` during execution.
    public let stderrAlreadyStreamed: Bool

    public init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        error: RelayIDEError? = nil,
        stdoutIsVerbatim: Bool = false,
        stderrAlreadyStreamed: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.error = error
        self.stdoutIsVerbatim = stdoutIsVerbatim
        self.stderrAlreadyStreamed = stderrAlreadyStreamed
    }
}

// MARK: - Guarded `semantic-merge` Reporting Shared by the CLI and the MCP Server

public enum RelaySemanticMergeReporting {
    public static let exitCodeClean: Int32 = 0
    public static let exitCodeConflict: Int32 = 1
    public static let exitCodeSyntaxCheckFailed: Int32 = 3
    public static let exitCodeLineMergeUnavailable: Int32 = 4

    /// One-line account of how a clean result was obtained. The `[strategy=...]` token is the same in both languages.
    public static func cleanNote(
        strategy: GuardedMergeStrategy,
        syntaxParser: String?,
        resolvedConflictBlocks: Int,
        relativePath: String,
        language: RelayLanguage
    ) -> String {
        let zh = language.isChinese
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let shownExt = ext.isEmpty ? (zh ? "无扩展名的" : "extensionless") : ".\(ext)"
        let syntaxPart: String
        if let syntaxParser {
            syntaxPart = zh ? "语法检查通过（\(syntaxParser)）" : "syntax check passed (\(syntaxParser))"
        } else {
            syntaxPart = zh
                ? "\(shownExt) 文件没有语法检查器，输出未做语法检查"
                : "no syntax checker for \(shownExt) files, output was not syntax-checked"
        }
        switch strategy {
        case .lineLevel:
            return zh
                ? "[strategy=line-level] 无冲突：采用 git merge-file 的行级合并结果；\(syntaxPart)"
                : "[strategy=line-level] clean: this is the git merge-file line-level result; \(syntaxPart)"
        case .declarationLevel:
            return zh
                ? "[strategy=declaration-level] 无冲突：git merge-file 报告的 \(resolvedConflictBlocks) 个冲突块都是两边在同一位置各自插入，两边内容已原样保留（声明级引擎判定一致）；\(syntaxPart)"
                : "[strategy=declaration-level] clean: all \(resolvedConflictBlocks) conflict block(s) reported by git merge-file were both-sides insertions and both insertions were kept verbatim (the declaration-level engine agreed); \(syntaxPart)"
        }
    }

    public static func conflictNote(verdict: GuardedMergeDeclarationVerdict, language: RelayLanguage) -> String {
        let lead = language.isChinese
            ? "[strategy=none] 输出是 git merge-file 带冲突标记的结果："
            : "[strategy=none] the output is the conflict-marked git merge-file result: "
        return lead + verdict.localizedDescription(in: language)
    }

    public static func lineMergeUnavailableError(reason: String, language: RelayLanguage) -> RelayIDEError {
        .semanticMergeFailure(
            language.isChinese
                ? "git 不可用或 git merge-file 运行失败（\(reason)）。没有行级合并结果作参照，拒绝合并"
                : "git is unavailable or `git merge-file` failed (\(reason)). Refusing to merge without the line-level reference"
        )
    }
}

public enum RelayCLILaunchDisposition: Sendable, Equatable {
    case exportScreenshots(directoryURL: URL)
    case headlessCLI(filteredArguments: [String], subcommand: String)
    case unknownSubcommand(filteredArguments: [String], offendingToken: String)
    case desktopWorkbench
}

/// Installs POSIX `SIGINT` and `SIGTERM` `DispatchSourceSignal` listeners for headless `RelayIDE run`
/// and forwards the first received signal to `activeLaneRegistry.requestCancellation(signal:)` (`03-relayide.md` §8, R42).
/// `POSIXPseudoTerminalSession.spawn` passes `POSIX_SPAWN_SETSIGDEF` with `sigfillset`, so `SIG_IGN` in `RelayIDE`
/// never leaks into spawned `relay.sh` children.
public final class RelayCLISignalForwarder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.zxu756.RelayIDE.cli.signal-forwarder")
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var stopped = false

    public init(registry: RelayActiveLaneRegistry) {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler {
            registry.requestCancellation(signal: SIGINT)
        }
        intSource.resume()

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler {
            registry.requestCancellation(signal: SIGTERM)
        }
        termSource.resume()

        self.sources = [intSource, termSource]
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let activeSources = sources
        sources.removeAll()
        lock.unlock()
        for src in activeSources {
            src.cancel()
        }
    }

    deinit {
        stop()
    }
}

public struct RelayCLIRunner: Sendable {
    public static let knownCLISubcommands: Set<String> = [
        "init",
        "run",
        "status",
        "lanes",
        "dag-waves",
        "semantic-merge",
        "audit-plugins",
        "export-html",
        "mcp",
        "help",
        "--help",
        "-h",
        "version",
        "--version"
    ]

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

    public static func makeSignalForwardedRunContext(
        cancellationPolicy: RelayCancellationPolicy = .default
    ) -> (runner: RelayCLIRunner, forwarder: RelayCLISignalForwarder) {
        let registry = RelayActiveLaneRegistry()
        let forwarder = RelayCLISignalForwarder(registry: registry)
        let runner = RelayCLIRunner(
            activeLaneRegistry: registry,
            cancellationPolicy: cancellationPolicy
        )
        return (runner, forwarder)
    }

    /// Classifies `CommandLine.arguments.dropFirst()` without touching AppKit/SwiftUI (`03-relayide.md` §1, R39).
    /// When the first effective argument does not start with `-`, is not a `.relayproj` path, and is not a known
    /// subcommand, returns `.unknownSubcommand` so the executable exits with code `2` instead of opening the GUI.
    public static func classifyLaunchArguments(_ rawArguments: [String]) -> RelayCLILaunchDisposition {
        let filteredArgs = filterSystemLaunchArguments(rawArguments)

        if let exportDir = parseExportScreenshotsDirectory(from: filteredArgs) {
            return .exportScreenshots(directoryURL: exportDir)
        }

        let subcommandArgs = stripLanguageArguments(from: filteredArgs)
        guard let firstArg = subcommandArgs.first else {
            return .desktopWorkbench
        }

        if knownCLISubcommands.contains(firstArg) {
            return .headlessCLI(filteredArguments: filteredArgs, subcommand: firstArg)
        }
        if firstArg.hasPrefix("-") || isRelayProjectBundleArgument(firstArg) {
            return .desktopWorkbench
        }
        return .unknownSubcommand(filteredArguments: filteredArgs, offendingToken: firstArg)
    }

    public static func filterSystemLaunchArguments(_ rawArguments: [String]) -> [String] {
        var filtered: [String] = []
        var idx = 0
        while idx < rawArguments.count {
            let arg = rawArguments[idx]
            if arg.hasPrefix("-psn_") {
                idx += 1
                continue
            }
            if arg == "-NSDocumentRevisionsDebugMode" {
                if idx + 1 < rawArguments.count,
                   rawArguments[idx + 1] == "YES" || rawArguments[idx + 1] == "NO" {
                    idx += 2
                } else {
                    idx += 1
                }
                continue
            }
            filtered.append(arg)
            idx += 1
        }
        return filtered
    }

    public static func parseExportScreenshotsDirectory(from args: [String]) -> URL? {
        if let flagIdx = args.firstIndex(of: "--export-screenshots") {
            let path = (flagIdx + 1 < args.count && !args[flagIdx + 1].hasPrefix("-")) ? args[flagIdx + 1] : "./docs"
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        for arg in args where arg.hasPrefix("--export-screenshots=") {
            let path = String(arg.dropFirst("--export-screenshots=".count))
            return URL(fileURLWithPath: path.isEmpty ? "./docs" : path, isDirectory: true)
        }
        return nil
    }

    public static func isRelayProjectBundleArgument(_ token: String) -> Bool {
        var trimmed = token
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return (trimmed as NSString).pathExtension.lowercased() == "relayproj"
    }

    public func execute(arguments: [String]) async throws -> String {
        let result = await executeCommand(arguments: arguments)
        if result.exitCode != 0 {
            throw result.error ?? RelayIDEError.invalidCLIUsage(result.stderr)
        }
        return result.stdout
    }

    public func executeCommand(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onLiveStderrLine: (@Sendable (String) -> Void)? = nil
    ) async -> RelayCLIExecutionResult {
        let lang = Self.resolveCLILanguage(arguments: arguments, environment: environment)
        let normalizedArgs = Self.stripLanguageArguments(from: arguments)
        guard let subcommand = normalizedArgs.first else {
            return RelayCLIExecutionResult(stdout: Self.helpBanner(language: lang), exitCode: 0)
        }
        let rest = Array(normalizedArgs.dropFirst())

        do {
            switch subcommand {
            case "help", "--help", "-h":
                return RelayCLIExecutionResult(stdout: Self.helpBanner(language: lang), exitCode: 0)

            case "version", "--version":
                let msg = lang.isChinese
                    ? "RelayIDE 1.2.0 (macOS arm64 · 工作区台账、MCP 所有权校验与实验性三路合并；M0 尚未接入智能体执行)"
                    : "RelayIDE 1.2.0 (macOS arm64 · Workspace Ledger, MCP Ownership Check & Experimental 3-Way Merge; M0 does not launch coding agents yet)"
                return RelayCLIExecutionResult(stdout: msg, exitCode: 0)

            case "init":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
                let bundleURL = URL(fileURLWithPath: bundlePath)
                let db = try RelayProjectDatabase(bundleDirectoryURL: bundleURL)
                let orch = MultiVendorDAGOrchestrator(database: db)
                let seedDemo = rest.contains("--seed-demo")
                if seedDemo {
                    try orch.seedIndustrialDemoWorkspace()
                    try db.setMeta(key: "is_demo_workspace", value: "1")
                } else {
                    if db.getMeta(key: "workspace_name") == nil {
                        let baseName = bundleURL.deletingPathExtension().lastPathComponent
                        try db.setMeta(key: "workspace_name", value: baseName.isEmpty ? "RelayWorkspace" : baseName)
                    }
                    try db.setMeta(key: "is_demo_workspace", value: "0")
                }
                let stats = try db.computeStats()
                if seedDemo {
                    let demoMsg = lang.isChinese
                        ? "[演示数据] 已在 \(bundlePath) 初始化合成演示工作区 (lanes=\(stats.activeLaneCount), tasks=\(stats.taskNodeCount), autoMerges=\(stats.semanticAutoMergeCount)；工作树路径、提交哈希与花费均为合成预览样本)"
                        : "[DEMO] Initialized synthetic demo workspace at \(bundlePath) (lanes=\(stats.activeLaneCount), tasks=\(stats.taskNodeCount), autoMerges=\(stats.semanticAutoMergeCount); worktree paths, commit OIDs, and spend are synthetic preview fixtures)"
                    return RelayCLIExecutionResult(stdout: demoMsg, exitCode: 0)
                } else {
                    let cleanMsg = lang.isChinese
                        ? "已初始化空工作区 \(bundlePath) (lanes=\(stats.activeLaneCount), tasks=\(stats.taskNodeCount), autoMerges=\(stats.semanticAutoMergeCount))"
                        : "Initialized \(bundlePath) (lanes=\(stats.activeLaneCount), tasks=\(stats.taskNodeCount), autoMerges=\(stats.semanticAutoMergeCount))"
                    return RelayCLIExecutionResult(stdout: cleanMsg, exitCode: 0)
                }

            case "run":
                let parsedRun = try parseRunCLIArguments(rest, language: lang)
                let outcome = await RelayRunExecutor(
                    runIDProvider: runIDProvider,
                    activeLaneRegistry: activeLaneRegistry,
                    cancellationPolicy: cancellationPolicy
                ).execute(
                    planPath: parsedRun.planPath,
                    projectBundlePath: parsedRun.projectPath,
                    explicitRelayShPath: parsedRun.relayShPath,
                    language: lang,
                    environment: environment,
                    onStderrLine: onLiveStderrLine
                )
                let emitsRunJSON = outcome.exitCode == 0
                    || outcome.exitCode == 1
                    || outcome.exitCode == 130
                    || outcome.exitCode == 143
                if emitsRunJSON, let record = outcome.runRecord {
                    let json = try RelayRunJSONCodec.encode(record)
                    let stderrText = outcome.stderrNotes.joined(separator: "\n")
                    return RelayCLIExecutionResult(
                        stdout: json,
                        stderr: stderrText,
                        exitCode: outcome.exitCode,
                        stderrAlreadyStreamed: onLiveStderrLine != nil
                    )
                } else {
                    var errLines = outcome.stderrNotes
                    if let err = outcome.error {
                        let rendered = err.localizedDescription(in: lang)
                        if !rendered.isEmpty {
                            errLines.append(rendered)
                            onLiveStderrLine?(rendered)
                        }
                    }
                    return RelayCLIExecutionResult(
                        stdout: "",
                        stderr: errLines.filter { !$0.isEmpty }.joined(separator: "\n"),
                        exitCode: outcome.exitCode,
                        error: outcome.error,
                        stderrAlreadyStreamed: onLiveStderrLine != nil
                    )
                }

            case "status":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
                let wantsRunsList = rest.contains("--runs")
                let explicitRunOption = extractRunFlagValue(in: rest)
                if wantsRunsList && explicitRunOption.present {
                    let conflictErr = RelayIDEError.invalidCLIUsage(
                        lang.isChinese
                            ? "不能同时指定 --run 与 --runs"
                            : "Cannot specify both --run and --runs"
                    )
                    return RelayCLIExecutionResult(
                        stderr: conflictErr.localizedDescription(in: lang),
                        exitCode: conflictErr.cliExitCode,
                        error: conflictErr
                    )
                }
                if explicitRunOption.present {
                    guard let runID = explicitRunOption.value, !runID.isEmpty, !runID.hasPrefix("-") else {
                        let missingID = RelayIDEError.invalidCLIUsage(
                            lang.isChinese ? "--run 需要提供运行编号" : "--run requires a run ID"
                        )
                        return RelayCLIExecutionResult(
                            stderr: missingID.localizedDescription(in: lang),
                            exitCode: missingID.cliExitCode,
                            error: missingID
                        )
                    }
                    let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                    guard let run = try db.fetchRun(runID: runID, reconcileWithLock: true) else {
                        let notFound = RelayIDEError.invalidCLIUsage(
                            lang.isChinese
                                ? "在工程 '\(bundlePath)' 中未找到运行编号 '\(runID)'"
                                : "Run '\(runID)' not found in project '\(bundlePath)'"
                        )
                        return RelayCLIExecutionResult(
                            stderr: notFound.localizedDescription(in: lang),
                            exitCode: notFound.cliExitCode,
                            error: notFound
                        )
                    }
                    let json = try RelayRunJSONCodec.encode(run)
                    return RelayCLIExecutionResult(stdout: json, exitCode: 0)
                }
                if wantsRunsList {
                    let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                    let runs = try db.allRuns(reconcileWithLock: true)
                    let json = try RelayRunJSONCodec.encode(runs)
                    return RelayCLIExecutionResult(stdout: json, exitCode: 0)
                }
                let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                let stats = try db.computeStats()
                let data = try JSONEncoder().encode(stats)
                return RelayCLIExecutionResult(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)

            case "lanes":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
                let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                let lanes = try db.allLanes()
                let text = lanes.map {
                    "\($0.id)\t\($0.assignedVendor.localizedDisplayName(in: lang))\t\($0.branchName)\tglobs=\($0.ownershipRule.allowedGlobs.joined(separator: ","))"
                }.joined(separator: "\n")
                return RelayCLIExecutionResult(stdout: text, exitCode: 0)

            case "dag-waves":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
                let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                let orch = MultiVendorDAGOrchestrator(database: db)
                guard let dag = try db.allDAGs().first else {
                    return RelayCLIExecutionResult(
                        stdout: lang.isChinese ? "当前工作区尚未注册任何 DAG" : "No DAG registered",
                        exitCode: 0
                    )
                }
                let waves = try orch.computeTopologicalWaves(for: dag)
                let text = waves.enumerated().map { idx, nodes in
                    let prefix = lang.isChinese ? "波次 \(idx + 1): " : "Wave \(idx + 1): "
                    return prefix + nodes.map { "\($0.id) [\($0.vendor.rawValue)]" }.joined(separator: ", ")
                }.joined(separator: "\n")
                return RelayCLIExecutionResult(stdout: text, exitCode: 0)

            case "semantic-merge":
                let positional = rest.filter { !$0.hasPrefix("-") }
                guard positional.count >= 3 else {
                    let usageErr = RelayIDEError.invalidCLIUsage(
                        lang.isChinese
                            ? "用法：RelayIDE semantic-merge <base-file> <left-file> <right-file>"
                            : "Usage: RelayIDE semantic-merge <base-file> <left-file> <right-file>"
                    )
                    return RelayCLIExecutionResult(
                        stderr: usageErr.localizedDescription(in: lang),
                        exitCode: 2,
                        error: usageErr
                    )
                }
                var sources: [String] = []
                for path in positional.prefix(3) {
                    // Read bytes and require a lossless UTF-8 decoding, so that what is merged is exactly what is on disk.
                    guard let data = FileManager.default.contents(atPath: path) else {
                        let readErr = RelayIDEError.invalidCLIUsage(
                            lang.isChinese ? "无法读取文件 '\(path)'" : "Cannot read file '\(path)'"
                        )
                        return RelayCLIExecutionResult(stderr: readErr.localizedDescription(in: lang), exitCode: 2, error: readErr)
                    }
                    let text = String(decoding: data, as: UTF8.self)
                    guard Array(text.utf8) == Array(data) else {
                        let encodingErr = RelayIDEError.invalidCLIUsage(
                            lang.isChinese ? "文件 '\(path)' 不是合法的 UTF-8 文本" : "File '\(path)' is not valid UTF-8 text"
                        )
                        return RelayCLIExecutionResult(stderr: encodingErr.localizedDescription(in: lang), exitCode: 2, error: encodingErr)
                    }
                    sources.append(text)
                }

                let outcome = LineAnchoredGuardedMerger(environment: environment).merge(
                    relativePath: (positional[0] as NSString).lastPathComponent,
                    baseSource: sources[0],
                    leftSource: sources[1],
                    rightSource: sources[2]
                )
                switch outcome {
                case .clean(let mergedText, let strategy, let syntaxParser, let resolvedConflictBlocks):
                    let note = RelaySemanticMergeReporting.cleanNote(
                        strategy: strategy,
                        syntaxParser: syntaxParser,
                        resolvedConflictBlocks: resolvedConflictBlocks,
                        relativePath: positional[0],
                        language: lang
                    )
                    return RelayCLIExecutionResult(
                        stdout: mergedText,
                        stderr: "semantic-merge: \(note)",
                        exitCode: RelaySemanticMergeReporting.exitCodeClean,
                        stdoutIsVerbatim: true
                    )

                case .conflict(let lineMergeText, let conflictCount, let declarationVerdict):
                    let conflictErr = RelayIDEError.semanticMergeConflictsDetected(max(1, conflictCount))
                    let note = RelaySemanticMergeReporting.conflictNote(verdict: declarationVerdict, language: lang)
                    return RelayCLIExecutionResult(
                        stdout: lineMergeText,
                        stderr: "semantic-merge: \(conflictErr.localizedDescription(in: lang))\nsemantic-merge: \(note)",
                        exitCode: RelaySemanticMergeReporting.exitCodeConflict,
                        error: conflictErr,
                        stdoutIsVerbatim: true
                    )

                case .syntaxCheckFailed(let parser, let diagnostic):
                    let syntaxErr = RelayIDEError.semanticMergeSyntaxCheckFailed(parser: parser, diagnostic: diagnostic)
                    return RelayCLIExecutionResult(
                        stdout: "",
                        stderr: "semantic-merge: \(syntaxErr.localizedDescription(in: lang))",
                        exitCode: RelaySemanticMergeReporting.exitCodeSyntaxCheckFailed,
                        error: syntaxErr,
                        stdoutIsVerbatim: true
                    )

                case .lineMergeUnavailable(let reason):
                    let unavailableErr = RelaySemanticMergeReporting.lineMergeUnavailableError(reason: reason, language: lang)
                    return RelayCLIExecutionResult(
                        stdout: "",
                        stderr: "semantic-merge: \(unavailableErr.localizedDescription(in: lang))",
                        exitCode: RelaySemanticMergeReporting.exitCodeLineMergeUnavailable,
                        error: unavailableErr,
                        stdoutIsVerbatim: true
                    )
                }

            case "audit-plugins":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
                let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                let findings = try db.allGuardrailFindings()
                let text = findings.map {
                    "[\($0.severity.localizedBadge(in: lang))] \(RelayLocalizer.translateDisplayText($0.pluginName, language: lang)): \(RelayLocalizer.translateDisplayText($0.title, language: lang)) · \(RelayLocalizer.translateDisplayText($0.detail, language: lang))"
                }.joined(separator: "\n")
                return RelayCLIExecutionResult(stdout: text, exitCode: 0)

            case "export-html":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
                let outPath = optionValue("--output", in: rest) ?? positionalOutPath(in: rest) ?? "relay-report.html"
                let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
                let orch = MultiVendorDAGOrchestrator(database: db)
                let html = try BauhausRelayHTMLReportExporter().exportHTMLDossier(
                    orchestrator: orch,
                    initialLanguage: lang
                )
                try html.write(toFile: outPath, atomically: true, encoding: .utf8)
                let msg = lang.isChinese
                    ? "已导出独立 HTML 报告至 \(outPath)"
                    : "Exported standalone HTML dossier to \(outPath)"
                return RelayCLIExecutionResult(stdout: msg, exitCode: 0)

            case "mcp":
                var boundProjectURL: URL?
                if let explicitPath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) {
                    let candidateURL = URL(fileURLWithPath: explicitPath)
                    guard RelayProjectDatabase.bundleExists(at: candidateURL) else {
                        let missingErr = RelayIDEError.workspaceBundleNotFound(candidateURL.path)
                        return RelayCLIExecutionResult(
                            stderr: missingErr.localizedDescription(in: lang),
                            exitCode: missingErr.cliExitCode,
                            error: missingErr
                        )
                    }
                    boundProjectURL = candidateURL
                }
                let server = RelayMCPServer(projectBundleURL: boundProjectURL, language: lang, environment: environment)
                await server.serveStdio()
                return RelayCLIExecutionResult(stdout: "", exitCode: 0)

            default:
                let unknownErr = RelayIDEError.invalidCLIUsage(
                    lang.isChinese
                        ? "未知子命令 '\(subcommand)'。请运行 'RelayIDE --help' 查看帮助。"
                        : "Unknown subcommand '\(subcommand)'. Run 'RelayIDE --help'."
                )
                return RelayCLIExecutionResult(
                    stderr: unknownErr.localizedDescription(in: lang),
                    exitCode: unknownErr.cliExitCode,
                    error: unknownErr
                )
            }
        } catch let relayErr as RelayIDEError {
            return RelayCLIExecutionResult(
                stderr: relayErr.localizedDescription(in: lang),
                exitCode: relayErr.cliExitCode,
                error: relayErr
            )
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            return RelayCLIExecutionResult(
                stderr: wrapped.localizedDescription(in: lang),
                exitCode: wrapped.cliExitCode,
                error: wrapped
            )
        }
    }

    private func parseRunCLIArguments(
        _ args: [String],
        language: RelayLanguage
    ) throws -> (planPath: String, projectPath: String, relayShPath: String?) {
        let isZh = language.isChinese
        var positionals: [String] = []
        var projectPath: String?
        var relayShPath: String?
        var idx = 0
        while idx < args.count {
            let tok = args[idx]
            if tok == "--project" || tok == "-p" {
                guard idx + 1 < args.count, !args[idx + 1].isEmpty, !args[idx + 1].hasPrefix("-") else {
                    throw RelayIDEError.invalidCLIUsage(
                        isZh ? "'--project' 需要提供工程路径" : "'--project' requires a project path"
                    )
                }
                projectPath = args[idx + 1]
                idx += 2
                continue
            }
            if tok.hasPrefix("--project=") {
                let val = String(tok.dropFirst("--project=".count))
                guard !val.isEmpty else {
                    throw RelayIDEError.invalidCLIUsage(
                        isZh ? "'--project=' 不能为空" : "'--project=' must not be empty"
                    )
                }
                projectPath = val
                idx += 1
                continue
            }
            if tok == "--relay-sh" {
                guard idx + 1 < args.count, !args[idx + 1].isEmpty, !args[idx + 1].hasPrefix("-") else {
                    throw RelayIDEError.invalidCLIUsage(
                        isZh ? "'--relay-sh' 需要提供 relay.sh 路径" : "'--relay-sh' requires a path to relay.sh"
                    )
                }
                relayShPath = args[idx + 1]
                idx += 2
                continue
            }
            if tok.hasPrefix("--relay-sh=") {
                let val = String(tok.dropFirst("--relay-sh=".count))
                guard !val.isEmpty else {
                    throw RelayIDEError.invalidCLIUsage(
                        isZh ? "'--relay-sh=' 不能为空" : "'--relay-sh=' must not be empty"
                    )
                }
                relayShPath = val
                idx += 1
                continue
            }
            if tok.hasPrefix("-") {
                throw RelayIDEError.invalidCLIUsage(
                    isZh
                        ? "run 不支持的选项 '\(tok)'（用法：RelayIDE run <plan.json> --project <工程> [--relay-sh <路径>] [--lang zh|en]）"
                        : "Unsupported option '\(tok)' for run (usage: RelayIDE run <plan.json> --project <project.relayproj> [--relay-sh <path>] [--lang zh|en])"
                )
            }
            positionals.append(tok)
            idx += 1
        }

        guard positionals.count == 1, let planPath = positionals.first, !planPath.isEmpty else {
            throw RelayIDEError.invalidCLIUsage(
                isZh
                    ? "用法：RelayIDE run <plan.json> --project <工程> [--relay-sh <路径>] [--lang zh|en]"
                    : "Usage: RelayIDE run <plan.json> --project <project.relayproj> [--relay-sh <path>] [--lang zh|en]"
            )
        }
        guard let resolvedProject = projectPath, !resolvedProject.isEmpty else {
            throw RelayIDEError.invalidCLIUsage(
                isZh
                    ? "RelayIDE run 必须显式指定 --project <工程>"
                    : "RelayIDE run requires --project <project.relayproj>"
            )
        }
        return (planPath: planPath, projectPath: resolvedProject, relayShPath: relayShPath)
    }

    private func extractRunFlagValue(in args: [String]) -> (present: Bool, value: String?) {
        if let idx = args.firstIndex(of: "--run") {
            let val = (idx + 1 < args.count) ? args[idx + 1] : nil
            return (true, val)
        }
        for tok in args where tok.hasPrefix("--run=") {
            return (true, String(tok.dropFirst("--run=".count)))
        }
        return (false, nil)
    }

    private func optionValue(_ flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private func positionalOutPath(in args: [String]) -> String? {
        var idx = 0
        while idx < args.count {
            let tok = args[idx]
            if tok == "--project" || tok == "-p" || tok == "--output" {
                idx += 2
                continue
            }
            if !tok.hasPrefix("-") {
                return tok
            }
            idx += 1
        }
        return nil
    }

    private static func resolveCLILanguage(arguments: [String], environment: [String: String]) -> RelayLanguage {
        if let cliOverride = RelayLocalizer.parseCLILanguageOverride(arguments: arguments) {
            return cliOverride
        }
        if let envRaw = environment[RelayLocalizer.environmentKey],
           let envParsed = RelayLanguage.parse(envRaw) {
            return envParsed
        }
        return .en
    }

    private static func stripLanguageArguments(from args: [String]) -> [String] {
        var out: [String] = []
        var idx = 0
        while idx < args.count {
            let tok = args[idx]
            if tok == "--lang" {
                idx += 2
                continue
            }
            if tok.hasPrefix("--lang=") {
                idx += 1
                continue
            }
            out.append(tok)
            idx += 1
        }
        return out
    }

    public static var helpBanner: String {
        helpBanner(language: .en)
    }

    public static func helpBanner(language: RelayLanguage) -> String {
        if language.isChinese {
            return """
            RelayIDE 1.2.0 · 多智能体并行工作台原型（M0：当前版本尚不会启动任何 coding agent，排在 M1）
            命令（可执行文件名：RelayIDE；Homebrew Cask 软链名：relayide）：
              init [--project <path.relayproj>] [--seed-demo]       新建 .relayproj SQLite WAL 工作区（--seed-demo 会写入带 [演示数据] 标记的合成样本）
              status [--project <path.relayproj>]                   输出已有工作区的 JSON 统计（工程不存在时报错，不会自动新建）
              lanes [--project <path.relayproj>]                    列出工作区已登记的通道与路径归属规则
              dag-waves [--project <path.relayproj>]                按拓扑排序计算已登记 DAG 的并行执行波次
              semantic-merge <base> <left> <right>                  【实验性】以 git merge-file 为准的三路合并：git 能干净合并时原样输出它的行级结果；git 报冲突时，
                                                                    只有每个冲突块都是两边在同一位置各自插入、声明级引擎判定一致、且结果通过语法检查，才把两边内容原样都保留。
                                                                    声明级引擎单独使用时已知会损坏 Python 和 Swift 的输出，所以它的文本从不输出。
                                                                    退出码：0 无冲突；1 有冲突（stdout 是 git 带冲突标记的结果）；3 合并结果未通过语法检查（不输出）；4 git 不可用（拒绝合并）
              audit-plugins [--project <path.relayproj>]            列出工作区已保存的 JavaScriptCore 护栏记录
              export-html <out.html> [--project <path>]             导出双语单文件 HTML 报告（演示工作区带 [演示数据] 标记）
              mcp [--project <path.relayproj>]                      在 stdio 上启动 JSON-RPC 2.0 MCP 服务（2 个工具：relay_semantic_merge、relay_check_ownership）
              --demo                                                启动桌面界面并显式载入演示数据（默认空状态启动）
              --export-screenshots <output-dir> [--lang zh|en]      导出 2x Retina 演示界面截图（2720x1680，带 DEMO 标记）
              --lang <zh|en>                                        指定输出与界面语言（或设置 RELAYIDE_LANG=zh|en）
            """
        }
        return """
        RelayIDE 1.2.0 · Multi-Agent Workbench Prototype (M0: does not launch coding agents yet; scheduled for M1)
        Commands (built executable: RelayIDE; Homebrew Cask symlink: relayide):
          init [--project <path.relayproj>] [--seed-demo]       Initialize .relayproj SQLite WAL workspace (--seed-demo writes [DEMO] synthetic fixtures)
          status [--project <path.relayproj>]                   Print JSON workspace statistics (errors if --project does not exist; never auto-creates)
          lanes [--project <path.relayproj>]                    List registered worktree lanes & ownership globs
          dag-waves [--project <path.relayproj>]                Compute topological execution waves for registered DAG
          semantic-merge <base> <left> <right>                  EXPERIMENTAL 3-way merge anchored on git merge-file: prints git's line-level result when git merges cleanly. When git
                                                                reports conflicts, both sides are kept verbatim only if every conflict block is a both-sides insertion at the same
                                                                place, the declaration-level engine agrees, and the result passes the syntax check. The declaration-level engine
                                                                alone is known to corrupt Python and Swift output, so its text is never printed.
                                                                Exit codes: 0 clean; 1 conflict (stdout is git's conflict-marked text); 3 merged text fails the syntax check
                                                                (nothing printed); 4 git unavailable (nothing merged)
          audit-plugins [--project <path.relayproj>]            List saved JavaScriptCore guardrail findings in workspace
          export-html <out.html> [--project <path>]             Export bilingual standalone HTML report (carries [DEMO] banner on seeded demo workspaces)
          mcp [--project <path.relayproj>]                      Start JSON-RPC 2.0 MCP server on stdio (2 tools: relay_semantic_merge, relay_check_ownership)
          --demo                                                Launch desktop GUI with synthetic demo campaign (starts empty by default)
          --export-screenshots <output-dir> [--lang zh|en]      Render 2x Retina demo screenshots (2720x1680, with visible DEMO badge)
          --lang <zh|en>                                        Override display language (or set RELAYIDE_LANG=zh|en)
        """
    }
}

// MARK: - JSON-RPC 2.0 MCP Server Over Stdio

public struct RelayMCPServer: Sendable {
    public let projectBundleURL: URL?
    public let language: RelayLanguage
    /// Environment used to locate `git` for `relay_semantic_merge` (PATH lookup only).
    public let environment: [String: String]

    public init(
        projectBundleURL: URL? = nil,
        language: RelayLanguage = .en,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.projectBundleURL = projectBundleURL
        self.language = language
        self.environment = environment
    }

    public func handleJSONRPCLine(_ rawLine: String) -> String? {
        guard let data = rawLine.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = req["method"] as? String else {
            return nil
        }
        let idVal = req["id"]

        let resultPayload: Any
        switch method {
        case "initialize":
            var serverInfo: [String: Any] = [
                "name": "relayide-mcp",
                "version": "1.2.0"
            ]
            if let boundPath = projectBundleURL?.path {
                serverInfo["projectPath"] = boundPath
            }
            resultPayload = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": serverInfo
            ]

        case "tools/list":
            resultPayload = [
                "tools": [
                    [
                        "name": "relay_semantic_merge",
                        "description": "EXPERIMENTAL 3-way merge of base, left and right anchored on git merge-file. Returns git's line-level result when git merges cleanly. When git reports conflicts, both sides are kept verbatim only if every conflict block is a both-sides insertion at the same place, the declaration-level engine agrees, and the result passes the language syntax check; otherwise isError is true and the text is git's conflict-marked output. The declaration-level engine alone is known to corrupt Python and Swift output, so its text is never returned. isError is also true when the merged text fails the syntax check or git is unavailable.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string"],
                                "base": ["type": "string"],
                                "left": ["type": "string"],
                                "right": ["type": "string"]
                            ],
                            "required": ["path", "base", "left", "right"]
                        ]
                    ],
                    [
                        "name": "relay_check_ownership",
                        "description": "Verify whether a relative file path is permitted by allowedGlobs or by a registered laneID in the bound --project workspace.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "relativePath": ["type": "string"],
                                "allowedGlobs": ["type": "array", "items": ["type": "string"]],
                                "laneID": ["type": "string"]
                            ],
                            "required": ["relativePath"]
                        ]
                    ]
                ]
            ]

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]

            if toolName == "relay_semantic_merge" {
                let path = args["path"] as? String ?? "File.swift"
                let base = args["base"] as? String ?? ""
                let left = args["left"] as? String ?? ""
                let right = args["right"] as? String ?? ""
                let outcome = LineAnchoredGuardedMerger(environment: environment).merge(
                    relativePath: path,
                    baseSource: base,
                    leftSource: left,
                    rightSource: right
                )
                // content[0] is always the payload (merged text, conflict-marked text, or the error message);
                // content[1], when present, says how the result was obtained.
                switch outcome {
                case .clean(let mergedText, let strategy, let syntaxParser, let resolvedConflictBlocks):
                    let note = RelaySemanticMergeReporting.cleanNote(
                        strategy: strategy,
                        syntaxParser: syntaxParser,
                        resolvedConflictBlocks: resolvedConflictBlocks,
                        relativePath: path,
                        language: language
                    )
                    resultPayload = [
                        "content": [
                            ["type": "text", "text": mergedText],
                            ["type": "text", "text": "semantic-merge: \(note)"]
                        ],
                        "isError": false
                    ]
                case .conflict(let lineMergeText, let conflictCount, let declarationVerdict):
                    let conflictMsg = RelayIDEError.semanticMergeConflictsDetected(max(1, conflictCount))
                        .localizedDescription(in: language)
                    let note = RelaySemanticMergeReporting.conflictNote(verdict: declarationVerdict, language: language)
                    resultPayload = [
                        "content": [
                            ["type": "text", "text": lineMergeText],
                            ["type": "text", "text": "semantic-merge: \(conflictMsg)\nsemantic-merge: \(note)"]
                        ],
                        "isError": true
                    ]
                case .syntaxCheckFailed(let parser, let diagnostic):
                    let errMsg = RelayIDEError.semanticMergeSyntaxCheckFailed(parser: parser, diagnostic: diagnostic)
                        .localizedDescription(in: language)
                    resultPayload = [
                        "content": [
                            ["type": "text", "text": errMsg]
                        ],
                        "isError": true
                    ]
                case .lineMergeUnavailable(let reason):
                    let errMsg = RelaySemanticMergeReporting.lineMergeUnavailableError(reason: reason, language: language)
                        .localizedDescription(in: language)
                    resultPayload = [
                        "content": [
                            ["type": "text", "text": errMsg]
                        ],
                        "isError": true
                    ]
                }
            } else if toolName == "relay_check_ownership" {
                let rel = args["relativePath"] as? String ?? ""
                if let explicitGlobs = args["allowedGlobs"] as? [String] {
                    let forbidden = args["forbiddenGlobs"] as? [String] ?? []
                    let verdict = GlobPatternMatcher.evaluateOwnership(
                        relativePath: rel,
                        rule: FileOwnershipRule(allowedGlobs: explicitGlobs, forbiddenGlobs: forbidden)
                    )
                    resultPayload = [
                        "content": [
                            ["type": "text", "text": "\(verdict.allowed ? "ALLOWED" : "DENIED"): \(verdict.reason)"]
                        ],
                        "isError": !verdict.allowed
                    ]
                } else if let laneID = args["laneID"] as? String, let bundleURL = projectBundleURL {
                    do {
                        let db = try RelayProjectDatabase.openExisting(bundleDirectoryURL: bundleURL)
                        guard let lane = try db.allLanes().first(where: { $0.id == laneID }) else {
                            resultPayload = [
                                "content": [["type": "text", "text": "Lane '\(laneID)' not found in workspace '\(bundleURL.path)'"]],
                                "isError": true
                            ]
                            break
                        }
                        let verdict = GlobPatternMatcher.evaluateOwnership(
                            relativePath: rel,
                            rule: lane.ownershipRule
                        )
                        resultPayload = [
                            "content": [
                                ["type": "text", "text": "\(verdict.allowed ? "ALLOWED" : "DENIED"): \(verdict.reason)"]
                            ],
                            "isError": !verdict.allowed
                        ]
                    } catch {
                        resultPayload = [
                            "content": [["type": "text", "text": error.localizedDescription]],
                            "isError": true
                        ]
                    }
                } else {
                    resultPayload = [
                        "content": [["type": "text", "text": "relay_check_ownership requires either 'allowedGlobs' or ('laneID' with 'mcp --project <path>')"]],
                        "isError": true
                    ]
                }
            } else {
                resultPayload = [
                    "content": [["type": "text", "text": "Unknown tool '\(toolName)'"]],
                    "isError": true
                ]
            }

        default:
            if idVal == nil { return nil }
            resultPayload = [String: Any]()
        }

        guard let idVal else { return nil }
        let responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idVal,
            "result": resultPayload
        ]
        guard let outData = try? JSONSerialization.data(withJSONObject: responseObj) else { return nil }
        return String(decoding: outData, as: UTF8.self)
    }

    public func serveStdio() async {
        while let line = readLine() {
            if let reply = handleJSONRPCLine(line) {
                print(reply)
                fflush(stdout)
            }
        }
    }
}
