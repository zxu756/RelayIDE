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
        switch self {
        case .claudeCode:
            return [
                "/Users/xu/.local/bin/claude",
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
                "/Users/xu/.antigravity/antigravity/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy"
            ]
        case .mistralVibe:
            return [
                "/Users/xu/.local/bin/vibe",
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
    case processSpawnFailed(executable: String, reason: String)
    case gitRepositoryNotFound(String)
    case gitPlumbingFailure(command: String, exitCode: Int32, stderr: String)
    case worktreeAlreadyExists(String)
    case ownershipViolation(laneID: String, path: String, rule: String)
    case cyclicTaskDependency([String])
    case semanticMergeFailure(String)
    case proxyBindFailure(port: UInt16, reason: String)
    case budgetCircuitTripped(laneID: String, spentUSD: Double, limitUSD: Double)
    case databaseError(code: Int32, message: String)
    case pluginError(pluginID: String, reason: String)
    case invalidCLIUsage(String)

    public var errorDescription: String? {
        switch self {
        case .ptyAllocationFailed(let code, let msg):
            return "POSIX forkpty failed (errno \(code)): \(msg)"
        case .processSpawnFailed(let exe, let reason):
            return "Failed to spawn '\(exe)': \(reason)"
        case .gitRepositoryNotFound(let path):
            return "Git repository not found at '\(path)'"
        case .gitPlumbingFailure(let cmd, let code, let err):
            return "Git plumbing '\(cmd)' exited with \(code): \(err)"
        case .worktreeAlreadyExists(let path):
            return "Managed worktree already exists at '\(path)'"
        case .ownershipViolation(let lane, let path, let rule):
            return "Lane '\(lane)' modified forbidden path '\(path)' (rule: \(rule))"
        case .cyclicTaskDependency(let cycle):
            return "Relay DAG contains a dependency cycle: \(cycle.joined(separator: " -> "))"
        case .semanticMergeFailure(let msg):
            return "3-Way Semantic AST Merge failed: \(msg)"
        case .proxyBindFailure(let port, let reason):
            return "Wiretap HTTP proxy failed to bind 127.0.0.1:\(port): \(reason)"
        case .budgetCircuitTripped(let lane, let spent, let limit):
            return String(format: "Budget circuit tripped for lane '%@' ($%.4f / $%.4f)", lane, spent, limit)
        case .databaseError(let code, let msg):
            return "Relay SQLite WAL error (\(code)): \(msg)"
        case .pluginError(let id, let reason):
            return "Relay plugin '\(id)' error: \(reason)"
        case .invalidCLIUsage(let msg):
            return "Invalid CLI arguments: \(msg)"
        }
    }
}
