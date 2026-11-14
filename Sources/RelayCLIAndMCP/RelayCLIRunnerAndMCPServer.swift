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

    public init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        error: RelayIDEError? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.error = error
    }
}

public struct RelayCLIRunner: Sendable {
    public init() {}

    public func execute(arguments: [String]) async throws -> String {
        let result = await executeCommand(arguments: arguments)
        if result.exitCode != 0 {
            throw result.error ?? RelayIDEError.invalidCLIUsage(result.stderr)
        }
        return result.stdout
    }

    public func executeCommand(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
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
                    ? "RelayIDE 1.1.0 (macOS arm64 · 工作区台账、MCP 所有权校验与实验性三路合并；M0 尚未接入智能体执行)"
                    : "RelayIDE 1.1.0 (macOS arm64 · Workspace Ledger, MCP Ownership Check & Experimental 3-Way Merge; M0 does not launch coding agents yet)"
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

            case "status":
                let bundlePath = optionValue("--project", in: rest) ?? optionValue("-p", in: rest) ?? "PaymentsCore.relayproj"
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
                let baseText = try String(contentsOfFile: positional[0], encoding: .utf8)
                let leftText = try String(contentsOfFile: positional[1], encoding: .utf8)
                let rightText = try String(contentsOfFile: positional[2], encoding: .utf8)
                let merger = ThreeWaySemanticASTMerger()
                let report = merger.mergeFile(
                    relativePath: (positional[0] as NSString).lastPathComponent,
                    baseSource: baseText,
                    leftSource: leftText,
                    rightSource: rightText,
                    leftLaneID: "left",
                    rightLaneID: "right"
                )

                let hasConflicts = !report.isCleanlyMerged || report.mergedText.contains("<<<<<<<")
                if hasConflicts {
                    let count = max(1, report.unresolvedConflictCount)
                    let conflictErr = RelayIDEError.semanticMergeConflictsDetected(count)
                    return RelayCLIExecutionResult(
                        stdout: report.mergedText,
                        stderr: "semantic-merge: \(conflictErr.localizedDescription(in: lang))",
                        exitCode: 1,
                        error: conflictErr
                    )
                }

                let verdict = LanguageSyntaxValidator.validate(
                    source: report.mergedText,
                    filePath: positional[0]
                )
                guard verdict.passed else {
                    let syntaxErr = RelayIDEError.semanticMergeSyntaxCheckFailed(
                        parser: verdict.parserUsed ?? "parser",
                        diagnostic: verdict.diagnostic
                    )
                    return RelayCLIExecutionResult(
                        stdout: "",
                        stderr: "semantic-merge: \(syntaxErr.localizedDescription(in: lang))",
                        exitCode: 3,
                        error: syntaxErr
                    )
                }

                return RelayCLIExecutionResult(stdout: report.mergedText, exitCode: 0)

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
                            exitCode: 1,
                            error: missingErr
                        )
                    }
                    boundProjectURL = candidateURL
                }
                let server = RelayMCPServer(projectBundleURL: boundProjectURL, language: lang)
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
                    exitCode: 2,
                    error: unknownErr
                )
            }
        } catch let relayErr as RelayIDEError {
            let code: Int32
            switch relayErr {
            case .invalidCLIUsage:
                code = 2
            case .semanticMergeSyntaxCheckFailed:
                code = 3
            default:
                code = 1
            }
            return RelayCLIExecutionResult(
                stderr: relayErr.localizedDescription(in: lang),
                exitCode: code,
                error: relayErr
            )
        } catch {
            let wrapped = RelayIDEError.invalidCLIUsage(error.localizedDescription)
            return RelayCLIExecutionResult(
                stderr: error.localizedDescription,
                exitCode: 1,
                error: wrapped
            )
        }
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
            RelayIDE 1.1.0 · 多智能体并行工作台原型（M0：当前版本尚不会启动任何 coding agent，排在 M1）
            命令（可执行文件名：RelayIDE；Homebrew Cask 软链名：relayide）：
              init [--project <path.relayproj>] [--seed-demo]       新建 .relayproj SQLite WAL 工作区（--seed-demo 会写入带 [演示数据] 标记的合成样本）
              status [--project <path.relayproj>]                   输出已有工作区的 JSON 统计（工程不存在时报错，不会自动新建）
              lanes [--project <path.relayproj>]                    列出工作区已登记的通道与路径归属规则
              dag-waves [--project <path.relayproj>]                按拓扑排序计算已登记 DAG 的并行执行波次
              semantic-merge <base> <left> <right>                  声明级三路合并（【实验性】已知会在 Python 代码上损坏输出；冲突退出码 1，语法检查失败退出码 3）
              audit-plugins [--project <path.relayproj>]            列出工作区已保存的 JavaScriptCore 护栏记录
              export-html <out.html> [--project <path>]             导出双语单文件 HTML 报告（演示工作区带 [演示数据] 标记）
              mcp [--project <path.relayproj>]                      在 stdio 上启动 JSON-RPC 2.0 MCP 服务（2 个工具：relay_semantic_merge、relay_check_ownership）
              --demo                                                启动桌面界面并显式载入演示数据（默认空状态启动）
              --export-screenshots <output-dir> [--lang zh|en]      导出 2x Retina 演示界面截图（2720x1680，带 DEMO 标记）
              --lang <zh|en>                                        指定输出与界面语言（或设置 RELAYIDE_LANG=zh|en）
            """
        }
        return """
        RelayIDE 1.1.0 · Multi-Agent Workbench Prototype (M0: does not launch coding agents yet; scheduled for M1)
        Commands (built executable: RelayIDE; Homebrew Cask symlink: relayide):
          init [--project <path.relayproj>] [--seed-demo]       Initialize .relayproj SQLite WAL workspace (--seed-demo writes [DEMO] synthetic fixtures)
          status [--project <path.relayproj>]                   Print JSON workspace statistics (errors if --project does not exist; never auto-creates)
          lanes [--project <path.relayproj>]                    List registered worktree lanes & ownership globs
          dag-waves [--project <path.relayproj>]                Compute topological execution waves for registered DAG
          semantic-merge <base> <left> <right>                  3-Way declaration merge (EXPERIMENTAL: known to corrupt output on Python; exit 1 on conflict, exit 3 on syntax check failure)
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

    public init(projectBundleURL: URL? = nil, language: RelayLanguage = .en) {
        self.projectBundleURL = projectBundleURL
        self.language = language
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
                "version": "1.1.0"
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
                        "description": "EXPERIMENTAL: known to corrupt output on Python. Perform a declaration-level 3-Way merge across base, left, and right source revisions with post-merge syntax validation.",
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
                let report = ThreeWaySemanticASTMerger().mergeFile(
                    relativePath: path,
                    baseSource: base,
                    leftSource: left,
                    rightSource: right,
                    leftLaneID: "left",
                    rightLaneID: "right"
                )
                let hasConflicts = !report.isCleanlyMerged || report.mergedText.contains("<<<<<<<")
                if hasConflicts {
                    resultPayload = [
                        "content": [
                            ["type": "text", "text": report.mergedText]
                        ],
                        "isError": true
                    ]
                } else {
                    let verdict = LanguageSyntaxValidator.validate(source: report.mergedText, filePath: path)
                    if verdict.passed {
                        resultPayload = [
                            "content": [
                                ["type": "text", "text": report.mergedText]
                            ],
                            "isError": false
                        ]
                    } else {
                        let errMsg = RelayIDEError.semanticMergeSyntaxCheckFailed(
                            parser: verdict.parserUsed ?? "parser",
                            diagnostic: verdict.diagnostic
                        ).localizedDescription(in: language)
                        resultPayload = [
                            "content": [
                                ["type": "text", "text": errMsg]
                            ],
                            "isError": true
                        ]
                    }
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
