import Foundation

// MARK: - Multi-Vendor Coding Agent Roster & Bauhaus Signal Palette

public enum AgentVendor: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"
    case antigravity = "agy"
    case mistralVibe = "vibe"
    case customShell = "shell"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "OpenAI Codex"
        case .antigravity: return "Antigravity (agy)"
        case .mistralVibe: return "Mistral Vibe"
        case .customShell: return "Verifier Shell"
        }
    }

    public var shortBadge: String {
        switch self {
        case .claudeCode: return "CC"
        case .codex: return "CX"
        case .antigravity: return "AGY"
        case .mistralVibe: return "VIBE"
        case .customShell: return "SH"
        }
    }

    /// Bauhaus Signal Palette hex strings (Vermilion, Cobalt, Emerald, Ochre, Slate)
    public var signalHexColor: String {
        switch self {
        case .claudeCode: return "#DA3C2A"
        case .codex: return "#205DD1"
        case .antigravity: return "#188B5D"
        case .mistralVibe: return "#DC8F14"
        case .customShell: return "#475569"
        }
    }

    public var defaultExecutableCandidates: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claudeCode:
            return [
                (home as NSString).appendingPathComponent(".local/bin/claude"),
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        case .codex:
            return [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        case .antigravity:
            return [
                (home as NSString).appendingPathComponent(".antigravity/antigravity/bin/agy"),
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy"
            ]
        case .mistralVibe:
            return [
                (home as NSString).appendingPathComponent(".local/bin/vibe"),
                "/opt/homebrew/bin/vibe"
            ]
        case .customShell:
            return ["/bin/zsh", "/bin/bash"]
        }
    }
}

// MARK: - Domain Errors

public enum RelayIDEError: Error, LocalizedError, Sendable, Equatable {
    case ptyAllocationFailed(errnoCode: Int32, message: String)
    case ptySessionAlreadyRunning(laneID: String, pid: Int32)
    case rawTranscriptOpenFailed(path: String, errnoCode: Int32, message: String)
    case processSpawnFailed(executable: String, reason: String)
    case gitRepositoryNotFound(String)
    case gitPlumbingFailure(command: String, exitCode: Int32, stderr: String)
    case worktreeAlreadyExists(String)
    case ownershipViolation(laneID: String, path: String, rule: String)
    case cyclicTaskDependency([String])
    case workspaceBundleNotFound(String)
    case semanticMergeFailure(String)
    case proxyBindFailure(port: UInt16, reason: String)
    case budgetCircuitTripped(laneID: String, spentUSD: Double, limitUSD: Double)
    case databaseError(code: Int32, message: String)
    case pluginError(pluginID: String, reason: String)
    case invalidCLIUsage(String)
    case invalidRunPlan(String)
    case relayEnvironmentFailure(String)
    case projectRunLocked(projectPath: String, holderRunID: String?, holderPID: Int32?)
    case relayRunInterrupted(runID: String, reason: String)

    /// Canonical CLI exit code (`03-relayide.md` §3, R40).
    /// Exit code `1` is reserved for completed `run` where at least one lane failed, merge conflicted, or `verify` failed.
    public var cliExitCode: Int32 {
        switch self {
        case .invalidCLIUsage,
             .invalidRunPlan,
             .workspaceBundleNotFound,
             .cyclicTaskDependency,
             .gitRepositoryNotFound:
            return 2
        case .semanticMergeFailure:
            return 4
        case .ptyAllocationFailed,
             .ptySessionAlreadyRunning,
             .rawTranscriptOpenFailed,
             .processSpawnFailed,
             .gitPlumbingFailure,
             .worktreeAlreadyExists,
             .ownershipViolation,
             .proxyBindFailure,
             .budgetCircuitTripped,
             .databaseError,
             .pluginError,
             .relayEnvironmentFailure,
             .projectRunLocked,
             .relayRunInterrupted:
            return 125
        }
    }

    public var errorDescription: String? {
        localizedDescription(in: .en)
    }

    public func localizedDescription(in language: RelayLanguage) -> String {
        let isZh = language.isChinese
        switch self {
        case .ptyAllocationFailed(let code, let msg):
            return isZh
                ? "伪终端分配失败（posix_openpt / grantpt / unlockpt，errno \(code)）：\(msg)"
                : "Pseudo-terminal allocation failed (posix_openpt / grantpt / unlockpt, errno \(code)): \(msg)"
        case .ptySessionAlreadyRunning(let lane, let pid):
            return isZh
                ? "伪终端会话 '\(lane)' 已在运行中（PID \(pid)），不能重复调用 spawn"
                : "PTY session '\(lane)' is already running (PID \(pid)); cannot spawn again"
        case .rawTranscriptOpenFailed(let path, let code, let msg):
            return isZh
                ? "打开伪终端原始记录文件 '\(path)' 失败（errno \(code)）：\(msg)"
                : "Failed to open raw PTY transcript file '\(path)' (errno \(code)): \(msg)"
        case .processSpawnFailed(let exe, let reason):
            return isZh
                ? "启动子进程 '\(exe)' 失败：\(reason)"
                : "Failed to spawn '\(exe)': \(reason)"
        case .gitRepositoryNotFound(let path):
            return isZh
                ? "未在 '\(path)' 找到 Git 仓库"
                : "Git repository not found at '\(path)'"
        case .gitPlumbingFailure(let cmd, let code, let err):
            return isZh
                ? "Git 底层命令 '\(cmd)' 失败（退出码 \(code)）：\(err)"
                : "Git plumbing '\(cmd)' exited with \(code): \(err)"
        case .worktreeAlreadyExists(let path):
            return isZh
                ? "受管工作树已存在于 '\(path)'"
                : "Managed worktree already exists at '\(path)'"
        case .ownershipViolation(let lane, let path, let rule):
            return isZh
                ? "通道 '\(lane)' 修改了越界路径 '\(path)'（规则：\(rule)）"
                : "Lane '\(lane)' modified forbidden path '\(path)' (rule: \(rule))"
        case .cyclicTaskDependency(let cycle):
            return isZh
                ? "Relay DAG 包含循环依赖：\(cycle.joined(separator: " -> "))"
                : "Relay DAG contains a dependency cycle: \(cycle.joined(separator: " -> "))"
        case .workspaceBundleNotFound(let path):
            return isZh
                ? "工程目录不存在或未初始化：'\(path)'（请先运行 'RelayIDE init --project \(path)'）"
                : "Workspace project bundle does not exist at '\(path)' (run 'RelayIDE init --project \(path)' first)"
        case .semanticMergeFailure(let msg):
            return isZh
                ? "三路语义合并失败：\(msg)"
                : "3-Way Semantic AST Merge failed: \(msg)"
        case .proxyBindFailure(let port, let reason):
            return isZh
                ? "回环 HTTP 代理绑定端口 \(port) 失败：\(reason)"
                : "Wiretap HTTP proxy failed to bind port \(port): \(reason)"
        case .budgetCircuitTripped(let lane, let spent, let limit):
            return isZh
                ? String(format: "通道 '%@' 预算熔断已触发 ($%.4f / $%.4f)", lane, spent, limit)
                : String(format: "Budget circuit tripped for lane '%@' ($%.4f / $%.4f)", lane, spent, limit)
        case .databaseError(let code, let msg):
            return isZh
                ? "Relay SQLite WAL 错误 (\(code))：\(msg)"
                : "Relay SQLite WAL error (\(code)): \(msg)"
        case .pluginError(let id, let reason):
            return isZh
                ? "Relay 插件 '\(id)' 错误：\(reason)"
                : "Relay plugin '\(id)' error: \(reason)"
        case .invalidCLIUsage(let msg):
            return isZh
                ? "命令行参数无效：\(msg)"
                : "Invalid CLI arguments: \(msg)"
        case .invalidRunPlan(let msg):
            return isZh
                ? "计划或参数错误：\(msg)"
                : "Invalid run plan: \(msg)"
        case .relayEnvironmentFailure(let msg):
            return isZh
                ? "RelayIDE 运行环境错误：\(msg)"
                : "RelayIDE environment error: \(msg)"
        case .projectRunLocked(let projectPath, let holderRunID, let holderPID):
            let runNote: String
            switch (holderRunID, holderPID) {
            case (let runID?, let pid?):
                runNote = isZh
                    ? "正在被运行 \(runID)（PID \(pid)）占用"
                    : "held by active run \(runID) (PID \(pid))"
            case (let runID?, nil):
                runNote = isZh
                    ? "正在被运行 \(runID) 占用"
                    : "held by active run \(runID)"
            case (nil, let pid?):
                runNote = isZh
                    ? "正在被另一个进程（PID \(pid)）占用"
                    : "held by another process (PID \(pid))"
            case (nil, nil):
                runNote = isZh
                    ? "正在被另一个 run 占用"
                    : "held by another active run"
            }
            return isZh
                ? "工程 '\(projectPath)' 无法启动新的运行：\(runNote)"
                : "Project '\(projectPath)' cannot start a new run: \(runNote)"
        case .relayRunInterrupted(let runID, let reason):
            return isZh
                ? "运行 \(runID) 已中断：\(reason)"
                : "Run \(runID) interrupted: \(reason)"
        }
    }
}
