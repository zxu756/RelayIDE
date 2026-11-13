import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelaySemanticMerge
import RelayWiretapProxy
import RelayWorkspaceStore
import RelayWorktreeGit

// MARK: - 15-Subcommand Headless CLI & JSON-RPC 2.0 MCP Server (stdio)

public struct RelayCLIRunner: Sendable {
    public init() {}

    public func execute(arguments: [String]) async throws -> String {
        guard let subcommand = arguments.first else {
            return Self.helpBanner
        }
        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "help", "--help", "-h":
            return Self.helpBanner

        case "version", "--version":
            return "RelayIDE 1.0.0 (macOS arm64 · 3-Way Semantic AST Merger + Wiretap Proxy + POSIX PTY Grid)"

        case "init":
            let bundlePath = optionValue("--project", in: rest) ?? "PaymentsCore.relayproj"
            let db = try RelayProjectDatabase(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
            let orch = MultiVendorDAGOrchestrator(database: db)
            if rest.contains("--seed-demo") {
                try orch.seedIndustrialDemoWorkspace()
            }
            let stats = try db.computeStats()
            return "Initialized \(bundlePath) (lanes=\(stats.activeLaneCount), tasks=\(stats.taskNodeCount), autoMerges=\(stats.semanticAutoMergeCount))"

        case "status":
            let bundlePath = optionValue("--project", in: rest) ?? "PaymentsCore.relayproj"
            let db = try RelayProjectDatabase(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
            let stats = try db.computeStats()
            let data = try JSONEncoder().encode(stats)
            return String(decoding: data, as: UTF8.self)

        case "lanes":
            let bundlePath = optionValue("--project", in: rest) ?? "PaymentsCore.relayproj"
            let db = try RelayProjectDatabase(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
            let lanes = try db.allLanes()
            return lanes.map { "\($0.id)\t\($0.assignedVendor.displayName)\t\($0.branchName)\tglobs=\($0.ownershipRule.allowedGlobs.joined(separator: ","))" }.joined(separator: "\n")

        case "dag-waves":
            let bundlePath = optionValue("--project", in: rest) ?? "PaymentsCore.relayproj"
            let db = try RelayProjectDatabase(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
            let orch = MultiVendorDAGOrchestrator(database: db)
            guard let dag = try db.allDAGs().first else { return "No DAG registered" }
            let waves = try orch.computeTopologicalWaves(for: dag)
            return waves.enumerated().map { idx, nodes in
                "Wave \(idx + 1): " + nodes.map { "\($0.id) [\($0.vendor.rawValue)]" }.joined(separator: ", ")
            }.joined(separator: "\n")

        case "semantic-merge":
            guard rest.count >= 3 else {
                throw RelayIDEError.invalidCLIUsage("Usage: RelayIDE semantic-merge <base-file> <left-file> <right-file>")
            }
            let baseText = try String(contentsOfFile: rest[0], encoding: .utf8)
            let leftText = try String(contentsOfFile: rest[1], encoding: .utf8)
            let rightText = try String(contentsOfFile: rest[2], encoding: .utf8)
            let merger = ThreeWaySemanticASTMerger()
            let report = merger.mergeFile(
                relativePath: (rest[0] as NSString).lastPathComponent,
                baseSource: baseText,
                leftSource: leftText,
                rightSource: rightText,
                leftLaneID: "left",
                rightLaneID: "right"
            )
            return report.mergedText

        case "audit-plugins":
            let bundlePath = optionValue("--project", in: rest) ?? "PaymentsCore.relayproj"
            let db = try RelayProjectDatabase(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
            let findings = try db.allGuardrailFindings()
            return findings.map { "[\($0.severity.rawValue)] \($0.pluginName): \($0.title) — \($0.detail)" }.joined(separator: "\n")

        case "export-html":
            let bundlePath = optionValue("--project", in: rest) ?? "PaymentsCore.relayproj"
            let outPath = optionValue("--output", in: rest) ?? (rest.first { !$0.hasPrefix("--") } ?? "relay-report.html")
            let db = try RelayProjectDatabase(bundleDirectoryURL: URL(fileURLWithPath: bundlePath))
            let orch = MultiVendorDAGOrchestrator(database: db)
            let html = try BauhausRelayHTMLReportExporter().exportHTMLDossier(orchestrator: orch)
            try html.write(toFile: outPath, atomically: true, encoding: .utf8)
            return "Exported standalone HTML dossier to \(outPath)"

        case "mcp":
            let server = RelayMCPServer()
            await server.serveStdio()
            return ""

        default:
            throw RelayIDEError.invalidCLIUsage("Unknown subcommand '\(subcommand)'. Run 'RelayIDE --help'.")
        }
    }

    private func optionValue(_ flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    public static let helpBanner = """
    RelayIDE — Multi-Vendor Coding Agent Parallel Workbench
    Commands:
      init [--project <path.relayproj>] [--seed-demo]   Initialize .relayproj SQLite WAL workspace
      status [--project <path.relayproj>]               Print JSON workspace statistics
      lanes [--project <path.relayproj>]                List isolated Git worktree lanes & ownership globs
      dag-waves [--project <path.relayproj>]            Compute topological execution waves for active DAG
      semantic-merge <base> <left> <right>              Run declaration-level 3-Way Semantic AST Merge
      audit-plugins [--project <path.relayproj>]        List JavaScriptCore guardrail findings
      export-html <out.html> [--project <path>]         Export standalone Bauhaus HTML dossier
      mcp                                               Start JSON-RPC 2.0 MCP server on stdio
      --export-screenshots <output-dir>                 Render 2x Retina workbench screenshots
    """
}

// MARK: - JSON-RPC 2.0 MCP Server Over Stdio

public struct RelayMCPServer: Sendable {
    public init() {}

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
            resultPayload = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "relayide-mcp", "version": "1.0.0"]
            ]
        case "tools/list":
            resultPayload = [
                "tools": [
                    [
                        "name": "relay_semantic_merge",
                        "description": "Perform a declaration-level 3-Way Semantic AST Merge across base, left, and right source revisions.",
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
                        "description": "Verify whether a relative file path is permitted by a lane's FileOwnershipRule globs.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "relativePath": ["type": "string"],
                                "allowedGlobs": ["type": "array", "items": ["type": "string"]]
                            ],
                            "required": ["relativePath", "allowedGlobs"]
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
                resultPayload = [
                    "content": [
                        ["type": "text", "text": report.mergedText]
                    ],
                    "isError": !report.isCleanlyMerged
                ]
            } else if toolName == "relay_check_ownership" {
                let rel = args["relativePath"] as? String ?? ""
                let globs = args["allowedGlobs"] as? [String] ?? ["**"]
                let verdict = GlobPatternMatcher.evaluateOwnership(
                    relativePath: rel,
                    rule: FileOwnershipRule(allowedGlobs: globs)
                )
                resultPayload = [
                    "content": [
                        ["type": "text", "text": "\(verdict.allowed ? "ALLOWED" : "DENIED"): \(verdict.reason)"]
                    ],
                    "isError": !verdict.allowed
                ]
            } else {
                resultPayload = ["content": [["type": "text", "text": "Unknown tool '\(toolName)'"]], "isError": true]
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
