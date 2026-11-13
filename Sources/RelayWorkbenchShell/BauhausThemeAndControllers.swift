import AppKit
import Foundation
import RelayModels
import RelayPluginSDK
import RelayWorkspaceStore
import SwiftUI

// MARK: - Bauhaus Warm Sandpaper & Recessed Charcoal Terminal Palette

public enum BauhausRelayPalette {
    /// Warm Sandpaper outer studio canvas (`#F4F2EC`)
    public static let studioPaper = Color(red: 0.957, green: 0.949, blue: 0.925)
    /// Crisp elevated ivory card (`#FDFCF9`)
    public static let elevatedSurface = Color(red: 0.992, green: 0.988, blue: 0.976)
    /// Subtle stone toolbar / header (`#EAE6DC`)
    public static let headerStone = Color(red: 0.918, green: 0.902, blue: 0.863)
    /// Hairline architectural divider (`#D6D1C4`)
    public static let hairlineRule = Color(red: 0.839, green: 0.820, blue: 0.769)
    /// Recessed matte charcoal PTY terminal well (`#18181B`)
    public static let terminalWell = Color(red: 0.094, green: 0.094, blue: 0.106)
    /// Terminal header chrome (`#222227`)
    public static let terminalHeader = Color(red: 0.133, green: 0.133, blue: 0.153)

    /// Primary espresso ink (`#191816`)
    public static let primaryInk = Color(red: 0.098, green: 0.094, blue: 0.086)
    /// Secondary graphite ink (`#57534E`)
    public static let secondaryInk = Color(red: 0.341, green: 0.325, blue: 0.306)
    /// Muted caption ink (`#78716C`)
    public static let mutedInk = Color(red: 0.471, green: 0.443, blue: 0.424)

    /// Bauhaus Signal Accents
    public static let signalVermilion = Color(red: 0.855, green: 0.235, blue: 0.165) // Claude Code / Blocker
    public static let signalCobalt    = Color(red: 0.125, green: 0.365, blue: 0.820) // OpenAI Codex
    public static let signalEmerald   = Color(red: 0.094, green: 0.545, blue: 0.365) // Antigravity / Clean Merge
    public static let signalOchre     = Color(red: 0.863, green: 0.561, blue: 0.078) // Mistral Vibe / Warning

    public static func vendorColor(_ vendor: AgentVendor) -> Color {
        switch vendor {
        case .claudeCode: return signalVermilion
        case .codex: return signalCobalt
        case .antigravity: return signalEmerald
        case .mistralVibe: return signalOchre
        case .customShell: return secondaryInk
        }
    }
}

// MARK: - Fuzzy Command Palette & Workbench Shell State Controller

public struct RelayCommandAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let shortcutHint: String
    public let targetPane: RelayStudioPane?

    public init(
        id: String,
        title: String,
        subtitle: String,
        shortcutHint: String,
        targetPane: RelayStudioPane? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.targetPane = targetPane
    }
}

@MainActor
public final class RelayWorkbenchShellState: ObservableObject {
    @Published public var activePane: RelayStudioPane = .ptyGrid
    @Published public var selectedLaneID: String = "lane-claude-core"
    @Published public var selectedMergeFilePath: String = "Sources/Ledger/BillingEngine.swift"
    @Published public var gridColumnsCount: Int = 2
    @Published public var isCommandPalettePresented: Bool = false
    @Published public var commandQuery: String = ""
    @Published public var statusBannerText: String = "Wiretap Proxy Ready · 4 Agent Worktrees Isolated"

    public let availableActions: [RelayCommandAction] = [
        RelayCommandAction(id: "goto.pty", title: "Open 2×2 Multi-Vendor PTY Grid", subtitle: "Inspect live VT100/TrueColor agent terminals", shortcutHint: "⌘1", targetPane: .ptyGrid),
        RelayCommandAction(id: "goto.dag", title: "Open Topological Relay DAG", subtitle: "Inspect parallel waves & .relay artifact handoffs", shortcutHint: "⌘2", targetPane: .dagPipeline),
        RelayCommandAction(id: "goto.merge", title: "Open 3-Way Semantic AST Merge Studio", subtitle: "Resolve declaration-level & nested member merges", shortcutHint: "⌘3", targetPane: .semanticMerge),
        RelayCommandAction(id: "goto.iso", title: "Open 2.5D Isometric Coupling & Territory Map", subtitle: "Inspect module fan-in/out & live lane ownership", shortcutHint: "⌘4", targetPane: .territoryMap),
        RelayCommandAction(id: "goto.wiretap", title: "Open Wiretap Token & Spend Flamechart", subtitle: "Configure USD circuit breakers per vendor lane", shortcutHint: "⌘5", targetPane: .wiretapBudget),
        RelayCommandAction(id: "goto.plugins", title: "Run JavaScriptCore Guardrail Plugins", subtitle: "Audit secret leaks, test gates & Conventional Commits", shortcutHint: "⌘6", targetPane: .guardrailPlugins)
    ]

    public init(initialPane: RelayStudioPane = .ptyGrid) {
        self.activePane = initialPane
    }

    public func filteredActions() -> [RelayCommandAction] {
        let trimmed = commandQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return availableActions }
        return availableActions.filter {
            $0.title.lowercased().contains(trimmed) || $0.subtitle.lowercased().contains(trimmed)
        }
    }
}
