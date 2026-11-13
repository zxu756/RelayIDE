import AppKit
import Foundation
import RelayModels
import RelayPluginSDK
import RelayWorkspaceStore
import SwiftUI

// MARK: - Bauhaus Design Tokens & Hex Color Utilities

public struct BauhausColorThemeTokens: Sendable, Codable, Hashable {
    /// Bauhaus Warm Sandpaper outer workbench chrome (`#F4F2EC`)
    public var chromeWarmSandpaperHex: String
    /// Crisp elevated card surface (`#FDFCF9`)
    public var elevatedCardHex: String
    /// Architectural stone header (`#EAE6DC`)
    public var stoneToolbarHex: String
    /// Hairline structural border (`#D6D1C4`)
    public var hairlineBorderHex: String
    /// High-contrast recessed terminal well (`#18181B`)
    public var terminalWellHex: String
    /// Bauhaus Vermilion signal (`#D94E34`) — Claude Code / Blocker
    public var vermilionHex: String
    /// Bauhaus Cobalt signal (`#2563EB`) — OpenAI Codex / Selection
    public var cobaltHex: String
    /// Bauhaus Ochre signal (`#D97706`) — Mistral Vibe / Warning
    public var ochreHex: String
    /// Bauhaus Signal Green (`#15803D`) — Google AGY / Clean AST Auto-Merge
    public var signalGreenHex: String

    public init(
        chromeWarmSandpaperHex: String = "#F4F2EC",
        elevatedCardHex: String = "#FDFCF9",
        stoneToolbarHex: String = "#EAE6DC",
        hairlineBorderHex: String = "#D6D1C4",
        terminalWellHex: String = "#18181B",
        vermilionHex: String = "#D94E34",
        cobaltHex: String = "#2563EB",
        ochreHex: String = "#D97706",
        signalGreenHex: String = "#15803D"
    ) {
        self.chromeWarmSandpaperHex = chromeWarmSandpaperHex
        self.elevatedCardHex = elevatedCardHex
        self.stoneToolbarHex = stoneToolbarHex
        self.hairlineBorderHex = hairlineBorderHex
        self.terminalWellHex = terminalWellHex
        self.vermilionHex = vermilionHex
        self.cobaltHex = cobaltHex
        self.ochreHex = ochreHex
        self.signalGreenHex = signalGreenHex
    }

    public static let bauhausStandard = BauhausColorThemeTokens()

    public var chromeWarmSandpaperColor: Color { Color(relayHex: chromeWarmSandpaperHex) }
    public var elevatedCardColor: Color { Color(relayHex: elevatedCardHex) }
    public var stoneToolbarColor: Color { Color(relayHex: stoneToolbarHex) }
    public var hairlineBorderColor: Color { Color(relayHex: hairlineBorderHex) }
    public var terminalWellColor: Color { Color(relayHex: terminalWellHex) }
    public var vermilionColor: Color { Color(relayHex: vermilionHex) }
    public var cobaltColor: Color { Color(relayHex: cobaltHex) }
    public var ochreColor: Color { Color(relayHex: ochreHex) }
    public var signalGreenColor: Color { Color(relayHex: signalGreenHex) }

    public func signalColor(for vendor: AgentVendor) -> Color {
        switch vendor {
        case .claudeCode: return vermilionColor
        case .codex: return cobaltColor
        case .antigravity: return signalGreenColor
        case .mistralVibe: return ochreColor
        case .customShell: return BauhausRelayPalette.secondaryInk
        }
    }
}

public extension Color {
    init(relayHex hexString: String) {
        let cleaned = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r: Double
        let g: Double
        let b: Double
        let a: Double
        switch cleaned.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        case 6:
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        default:
            r = 0.957
            g = 0.949
            b = 0.925
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

public extension BauhausRelayPalette {
    static let bauhausVermilionExact = Color(relayHex: "#D94E34")
    static let bauhausCobaltExact = Color(relayHex: "#2563EB")
    static let bauhausOchreExact = Color(relayHex: "#D97706")
    static let bauhausSignalGreenExact = Color(relayHex: "#15803D")
}

// MARK: - Persistent User Preferences Controller

public struct RelayUserPreferencesSnapshot: Sendable, Codable, Hashable {
    public var colorTokens: BauhausColorThemeTokens
    public var terminalFontFamily: String
    public var terminalFontSizePoints: Double
    public var enableMonospacedLigatures: Bool
    public var maxScrollbackLines: Int
    public var defaultGlobalBudgetCeilingUSD: Double
    public var defaultLaneBudgetCeilingUSD: Double
    public var autoRunSemanticMergeOnHandoff: Bool
    public var autoRevertOwnershipViolations: Bool
    public var outboundDLPRedactByDefault: Bool
    public var preferCompactChromeDensity: Bool
    public var respectReducedMotion: Bool

    public init(
        colorTokens: BauhausColorThemeTokens = .bauhausStandard,
        terminalFontFamily: String = "SF Mono",
        terminalFontSizePoints: Double = 12.5,
        enableMonospacedLigatures: Bool = false,
        maxScrollbackLines: Int = 5_000,
        defaultGlobalBudgetCeilingUSD: Double = 25.0,
        defaultLaneBudgetCeilingUSD: Double = 6.0,
        autoRunSemanticMergeOnHandoff: Bool = true,
        autoRevertOwnershipViolations: Bool = false,
        outboundDLPRedactByDefault: Bool = true,
        preferCompactChromeDensity: Bool = false,
        respectReducedMotion: Bool = false
    ) {
        self.colorTokens = colorTokens
        self.terminalFontFamily = terminalFontFamily
        self.terminalFontSizePoints = min(24.0, max(9.0, terminalFontSizePoints))
        self.enableMonospacedLigatures = enableMonospacedLigatures
        self.maxScrollbackLines = max(500, min(50_000, maxScrollbackLines))
        self.defaultGlobalBudgetCeilingUSD = max(1.0, defaultGlobalBudgetCeilingUSD)
        self.defaultLaneBudgetCeilingUSD = max(0.25, defaultLaneBudgetCeilingUSD)
        self.autoRunSemanticMergeOnHandoff = autoRunSemanticMergeOnHandoff
        self.autoRevertOwnershipViolations = autoRevertOwnershipViolations
        self.outboundDLPRedactByDefault = outboundDLPRedactByDefault
        self.preferCompactChromeDensity = preferCompactChromeDensity
        self.respectReducedMotion = respectReducedMotion
    }
}

@MainActor
public final class RelayUserPreferences: ObservableObject {
    public static let defaultUserDefaultsKey = "io.relayide.workbench.preferences.v1"

    @Published public var snapshot: RelayUserPreferencesSnapshot {
        didSet {
            persistSnapshot()
        }
    }

    private let backingFileURL: URL?
    private let userDefaults: UserDefaults
    private let storageKey: String

    public init(
        backingFileURL: URL? = nil,
        userDefaults: UserDefaults = .standard,
        storageKey: String = RelayUserPreferences.defaultUserDefaultsKey
    ) {
        self.backingFileURL = backingFileURL
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        if let url = backingFileURL,
           let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(RelayUserPreferencesSnapshot.self, from: raw) {
            self.snapshot = decoded
        } else if let raw = userDefaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode(RelayUserPreferencesSnapshot.self, from: raw) {
            self.snapshot = decoded
        } else {
            self.snapshot = RelayUserPreferencesSnapshot()
        }
    }

    public var colorTokens: BauhausColorThemeTokens {
        get { snapshot.colorTokens }
        set { snapshot.colorTokens = newValue }
    }

    public var terminalFontSizePoints: Double {
        get { snapshot.terminalFontSizePoints }
        set { snapshot.terminalFontSizePoints = min(24.0, max(9.0, newValue)) }
    }

    public func increaseTerminalFontSize() {
        terminalFontSizePoints += 1.0
    }

    public func decreaseTerminalFontSize() {
        terminalFontSizePoints -= 1.0
    }

    public func resetToBauhausDefaults() {
        snapshot = RelayUserPreferencesSnapshot()
    }

    private func persistSnapshot() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(snapshot) else { return }
        if let url = backingFileURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: url, options: [.atomic])
        } else {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
}

// MARK: - Fuzzy Subsequence Scoring & Command Palette Controller

public enum PaletteCommandCategory: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case studioNavigation = "Studio Views"
    case ptyMultiplexer = "PTY Lanes & Broadcast"
    case semanticMerge = "3-Way Semantic Merge"
    case wiretapAndBudget = "Wiretap & Circuit Breakers"
    case guardrailsAndPlugins = "Guardrails & Scratchpad"
    case workspaceAndJournal = "Undo, Checkpoints & Export"

    public var id: String { rawValue }
}

public struct RelayPaletteCommandItem: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: PaletteCommandCategory
    public var shortcutBadge: String
    public let sfSymbolName: String
    public let targetPane: RelayStudioPane?
    public let keywords: [String]

    public init(
        id: String,
        title: String,
        subtitle: String,
        category: PaletteCommandCategory,
        shortcutBadge: String,
        sfSymbolName: String,
        targetPane: RelayStudioPane? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.shortcutBadge = shortcutBadge
        self.sfSymbolName = sfSymbolName
        self.targetPane = targetPane
        self.keywords = keywords
    }
}

public struct ScoredPaletteCommandMatch: Sendable, Hashable, Identifiable {
    public var id: String { item.id }
    public let item: RelayPaletteCommandItem
    public let score: Int
    public let matchedTitleIndices: [Int]

    public init(item: RelayPaletteCommandItem, score: Int, matchedTitleIndices: [Int] = []) {
        self.item = item
        self.score = score
        self.matchedTitleIndices = matchedTitleIndices
    }
}

public enum RelayFuzzySubsequenceScorer {
    /// Computes deterministic subsequence match score + character highlight indices (word-boundary, camelCase, contiguous streak bonuses).
    public static func score(query rawQuery: String, candidate: String) -> (matched: Bool, score: Int, indices: [Int]) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return (true, 0, []) }

        let qChars = Array(query.lowercased())
        let cOrigChars = Array(candidate)
        let cLowerChars = Array(candidate.lowercased())
        guard qChars.count <= cLowerChars.count else { return (false, Int.min, []) }

        var qIdx = 0
        var matchedPositions: [Int] = []
        matchedPositions.reserveCapacity(qChars.count)

        var totalScore = 0
        var prevMatchIndex: Int?

        for cIdx in 0..<cLowerChars.count where qIdx < qChars.count {
            if cLowerChars[cIdx] == qChars[qIdx] {
                matchedPositions.append(cIdx)

                // Base match points
                totalScore += 10

                // Start-of-string prefix bonus
                if cIdx == 0 {
                    totalScore += 30
                }

                // Word boundary or camelCase transition bonus
                if cIdx > 0 {
                    let prevChar = cOrigChars[cIdx - 1]
                    let currChar = cOrigChars[cIdx]
                    if prevChar == " " || prevChar == "-" || prevChar == "/" || prevChar == "·" || prevChar == "_" {
                        totalScore += 24
                    } else if prevChar.isLowercase && currChar.isUppercase {
                        totalScore += 20
                    }
                }

                // Consecutive streak bonus vs gap penalty
                if let prev = prevMatchIndex {
                    let gap = cIdx - prev - 1
                    if gap == 0 {
                        totalScore += 22
                    } else {
                        totalScore -= min(18, gap * 2)
                    }
                } else {
                    // Penalty for late first match
                    totalScore -= min(15, cIdx)
                }

                prevMatchIndex = cIdx
                qIdx += 1
            }
        }

        guard qIdx == qChars.count else {
            return (false, Int.min, [])
        }
        return (true, totalScore, matchedPositions)
    }
}

@MainActor
public final class RelayCommandPaletteController: ObservableObject {
    @Published public var isPresented: Bool = false
    @Published public var searchQuery: String = "" {
        didSet {
            selectedIndex = 0
        }
    }
    @Published public var categoryFilter: PaletteCommandCategory? {
        didSet {
            selectedIndex = 0
        }
    }
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var catalog: [RelayPaletteCommandItem]
    @Published public private(set) var recentCommandIDs: [String] = []

    public var onCommandTriggered: ((RelayPaletteCommandItem) -> Void)?

    public init(catalog: [RelayPaletteCommandItem] = RelayCommandPaletteController.defaultCatalog) {
        self.catalog = catalog
    }

    public var rankedMatches: [ScoredPaletteCommandMatch] {
        let baseItems: [RelayPaletteCommandItem]
        if let categoryFilter {
            baseItems = catalog.filter { $0.category == categoryFilter }
        } else {
            baseItems = catalog
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return baseItems.enumerated().map { offset, item in
                let recencyBoost: Int
                if let mruRank = recentCommandIDs.firstIndex(of: item.id) {
                    recencyBoost = max(0, 100 - mruRank * 15)
                } else {
                    recencyBoost = 0
                }
                return ScoredPaletteCommandMatch(item: item, score: recencyBoost - offset, matchedTitleIndices: [])
            }.sorted { $0.score > $1.score }
        }

        var matches: [ScoredPaletteCommandMatch] = []
        for item in baseItems {
            let titleHit = RelayFuzzySubsequenceScorer.score(query: trimmed, candidate: item.title)
            let subHit = RelayFuzzySubsequenceScorer.score(query: trimmed, candidate: item.subtitle)
            let kwJoined = ([item.category.rawValue, item.shortcutBadge] + item.keywords).joined(separator: " ")
            let kwHit = RelayFuzzySubsequenceScorer.score(query: trimmed, candidate: kwJoined)

            guard titleHit.matched || subHit.matched || kwHit.matched else { continue }
            var bestScore = max(
                titleHit.matched ? titleHit.score + 25 : Int.min / 2,
                max(
                    subHit.matched ? subHit.score : Int.min / 2,
                    kwHit.matched ? kwHit.score - 5 : Int.min / 2
                )
            )
            if recentCommandIDs.contains(item.id) {
                bestScore += 14
            }
            matches.append(
                ScoredPaletteCommandMatch(
                    item: item,
                    score: bestScore,
                    matchedTitleIndices: titleHit.matched ? titleHit.indices : []
                )
            )
        }

        return matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.title < rhs.item.title
        }
    }

    public func togglePresented() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    public func present(initialQuery: String = "", category: PaletteCommandCategory? = nil) {
        self.categoryFilter = category
        self.searchQuery = initialQuery
        self.selectedIndex = 0
        self.isPresented = true
    }

    public func dismiss() {
        self.isPresented = false
    }

    public func moveSelectionDown() {
        let total = rankedMatches.count
        guard total > 0 else { return }
        selectedIndex = (selectedIndex + 1) % total
    }

    public func moveSelectionUp() {
        let total = rankedMatches.count
        guard total > 0 else { return }
        selectedIndex = (selectedIndex - 1 + total) % total
    }

    @discardableResult
    public func executeSelected() -> RelayPaletteCommandItem? {
        let matches = rankedMatches
        guard !matches.isEmpty else { return nil }
        let idx = min(max(0, selectedIndex), matches.count - 1)
        let chosen = matches[idx].item
        return execute(commandID: chosen.id)
    }

    @discardableResult
    public func execute(commandID: String) -> RelayPaletteCommandItem? {
        guard let chosen = catalog.first(where: { $0.id == commandID }) else { return nil }
        recentCommandIDs.removeAll { $0 == commandID }
        recentCommandIDs.insert(commandID, at: 0)
        if recentCommandIDs.count > 12 {
            recentCommandIDs.removeLast(recentCommandIDs.count - 12)
        }
        isPresented = false
        onCommandTriggered?(chosen)
        return chosen
    }

    public func synchronizeShortcutBadges(from registry: [String: String]) {
        for idx in catalog.indices {
            if let badge = registry[catalog[idx].id] {
                catalog[idx].shortcutBadge = badge
            }
        }
    }

    public static let defaultCatalog: [RelayPaletteCommandItem] = [
        RelayPaletteCommandItem(
            id: "studio.ptyGrid",
            title: "Focus 2×2 Multi-Vendor PTY Multiplexer",
            subtitle: "Inspect live Claude Code, Codex, Google AGY & Mistral Vibe terminals",
            category: .studioNavigation,
            shortcutBadge: "⌘1",
            sfSymbolName: RelayStudioPane.ptyGrid.sfSymbolName,
            targetPane: .ptyGrid,
            keywords: ["terminal", "vt100", "console", "claude", "codex", "agy", "vibe"]
        ),
        RelayPaletteCommandItem(
            id: "studio.dagPipeline",
            title: "Focus Topological Relay DAG & CPM Critical Path",
            subtitle: "Inspect parallel execution waves, slack & .relay handoffs",
            category: .studioNavigation,
            shortcutBadge: "⌘2",
            sfSymbolName: RelayStudioPane.dagPipeline.sfSymbolName,
            targetPane: .dagPipeline,
            keywords: ["dag", "cpm", "critical path", "waves", "speedup"]
        ),
        RelayPaletteCommandItem(
            id: "studio.semanticMerge",
            title: "Focus 3-Way Semantic AST Merge Studio",
            subtitle: "Resolve declaration-level auto-merges & intra-function conflicts",
            category: .studioNavigation,
            shortcutBadge: "⌘3",
            sfSymbolName: RelayStudioPane.semanticMerge.sfSymbolName,
            targetPane: .semanticMerge,
            keywords: ["ast", "merge", "conflict", "diff", "three-way"]
        ),
        RelayPaletteCommandItem(
            id: "studio.territoryMap",
            title: "Focus 2.5D Isometric Architecture & Territory Map",
            subtitle: "Inspect 18 module instability scores, coupling arcs & boundary collisions",
            category: .studioNavigation,
            shortcutBadge: "⌘4",
            sfSymbolName: RelayStudioPane.territoryMap.sfSymbolName,
            targetPane: .territoryMap,
            keywords: ["isometric", "coupling", "martin", "ownership", "fence"]
        ),
        RelayPaletteCommandItem(
            id: "studio.wiretapBudget",
            title: "Focus Loopback Wiretap Flamechart & Spend Analytics",
            subtitle: "Inspect SSE TTFT, prompt cache savings, DLP redactions & burn rate",
            category: .studioNavigation,
            shortcutBadge: "⌘5",
            sfSymbolName: RelayStudioPane.wiretapBudget.sfSymbolName,
            targetPane: .wiretapBudget,
            keywords: ["wiretap", "tokens", "cost", "usd", "flamechart", "dlp"]
        ),
        RelayPaletteCommandItem(
            id: "studio.guardrailPlugins",
            title: "Focus JavaScriptCore Guardrail Plugins & Scratchpad",
            subtitle: "Audit policy packs, microsecond profiles & lifecycle hook traces",
            category: .studioNavigation,
            shortcutBadge: "⌘6",
            sfSymbolName: RelayStudioPane.guardrailPlugins.sfSymbolName,
            targetPane: .guardrailPlugins,
            keywords: ["jsc", "plugins", "guardrail", "scratchpad", "veto"]
        ),
        RelayPaletteCommandItem(
            id: "workbench.commandPalette",
            title: "Toggle Fuzzy Command Palette",
            subtitle: "Jump to any studio view, lane action, or policy operation",
            category: .studioNavigation,
            shortcutBadge: "⌘K",
            sfSymbolName: "command.square",
            keywords: ["palette", "quick open"]
        ),
        RelayPaletteCommandItem(
            id: "pty.broadcastInput",
            title: "Broadcast Input Prompt Across Active Agent PTY Lanes",
            subtitle: "Send synchronized shell or steering input to multiple vendor lanes",
            category: .ptyMultiplexer,
            shortcutBadge: "⌘⇧B",
            sfSymbolName: "dot.radiowaves.left.and.right",
            keywords: ["broadcast", "multiplex", "paste", "all lanes"]
        ),
        RelayPaletteCommandItem(
            id: "merge.runThreeWaySemantic",
            title: "Run 3-Way Semantic AST Merge Across Dirty Worktrees",
            subtitle: "Reconcile disjoint struct methods, imports & cross-file signatures",
            category: .semanticMerge,
            shortcutBadge: "⌘⇧M",
            sfSymbolName: "arrow.triangle.merge",
            targetPane: .semanticMerge,
            keywords: ["reconcile", "auto-merge", "AuthSessionManager"]
        ),
        RelayPaletteCommandItem(
            id: "wiretap.tripOrResetCircuitBreaker",
            title: "Trip or Reset Selected Lane Budget Circuit Breaker",
            subtitle: "Halt outbound LLM API packets or restore lane admission on 127.0.0.1",
            category: .wiretapAndBudget,
            shortcutBadge: "⌘⇧K",
            sfSymbolName: "bolt.horizontal.circle",
            targetPane: .wiretapBudget,
            keywords: ["circuit", "breaker", "halt", "reset", "ceiling", "429"]
        ),
        RelayPaletteCommandItem(
            id: "journal.undo",
            title: "Undo Last Workspace Mutation",
            subtitle: "Revert ownership, budget, merge resolution or plugin toggle via SQLite WAL",
            category: .workspaceAndJournal,
            shortcutBadge: "⌘Z",
            sfSymbolName: "arrow.uturn.backward",
            keywords: ["undo", "revert", "journal"]
        ),
        RelayPaletteCommandItem(
            id: "journal.redo",
            title: "Redo Workspace Mutation",
            subtitle: "Re-apply reverted mutation from persistent SQLite redo stack",
            category: .workspaceAndJournal,
            shortcutBadge: "⌘⇧Z",
            sfSymbolName: "arrow.uturn.forward",
            keywords: ["redo", "journal"]
        ),
        RelayPaletteCommandItem(
            id: "journal.createCheckpoint",
            title: "Create Named Workspace Checkpoint Snapshot",
            subtitle: "Save lanes, DAG, merge chunks & policy state into workspace.sqlite",
            category: .workspaceAndJournal,
            shortcutBadge: "⌘⇧S",
            sfSymbolName: "bookmark.square",
            keywords: ["snapshot", "checkpoint", "backup"]
        ),
        RelayPaletteCommandItem(
            id: "workbench.ftsSearch",
            title: "Search Transcripts, Prompts & Merges (SQLite FTS5 BM25)",
            subtitle: "Open bottom FTS5 full-text drawer across all 4 vendor lanes",
            category: .workspaceAndJournal,
            shortcutBadge: "⌘⇧F",
            sfSymbolName: "doc.text.magnifyingglass",
            keywords: ["search", "fts5", "bm25", "grep", "transcript"]
        ),
        RelayPaletteCommandItem(
            id: "workbench.exportHTMLDossier",
            title: "Export Standalone Bauhaus HTML Workspace Dossier",
            subtitle: "Generate offline single-file audit report of lanes, merges & spend",
            category: .workspaceAndJournal,
            shortcutBadge: "⌘⇧E",
            sfSymbolName: "square.and.arrow.up",
            keywords: ["export", "html", "report", "dossier"]
        )
    ]
}

// MARK: - Split Workspace, Tab Strip & Drawer Docking Controller

public enum RelaySplitArrangement: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case quadTwoByTwo = "2×2 Quad Grid"
    case horizontalSideBySide = "Side-by-Side Split"
    case verticalStacked = "Top/Bottom Split"
    case focusPlusSidebar = "1 Primary + 3 Stack"
    case singleMaximized = "Maximized Single Lane"

    public var id: String { rawValue }
}

public enum RelayInspectorSection: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case laneOwnership = "Territory & Globs"
    case astOutline = "AST Declarations"
    case spendAndDLP = "Spend & DLP"
    case undoCheckpoints = "Undo & Checkpoints"
    case pluginLatency = "JSC Micro-Profiler"

    public var id: String { rawValue }
}

public enum RelayBottomDrawerTab: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case ftsSearch = "FTS5 Search"
    case verificationGate = "Verifier Console"
    case wiretapStream = "Wiretap SSE Feed"
    case hookTraces = "Guardrail Hook Ring"

    public var id: String { rawValue }
}

public struct RelayWorkspaceTab: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var studioPane: RelayStudioPane
    public var associatedLaneID: String?
    public var associatedFilePath: String?
    public var vendorAccent: AgentVendor?
    public var isPinned: Bool
    public var hasUnresolvedConflict: Bool
    public var badgeCount: Int

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        studioPane: RelayStudioPane,
        associatedLaneID: String? = nil,
        associatedFilePath: String? = nil,
        vendorAccent: AgentVendor? = nil,
        isPinned: Bool = false,
        hasUnresolvedConflict: Bool = false,
        badgeCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.studioPane = studioPane
        self.associatedLaneID = associatedLaneID
        self.associatedFilePath = associatedFilePath
        self.vendorAccent = vendorAccent
        self.isPinned = isPinned
        self.hasUnresolvedConflict = hasUnresolvedConflict
        self.badgeCount = badgeCount
    }
}

@MainActor
public final class RelaySplitWorkspaceController: ObservableObject {
    @Published public var tabs: [RelayWorkspaceTab]
    @Published public var activeTabID: String
    @Published public var splitArrangement: RelaySplitArrangement = .quadTwoByTwo
    @Published public var horizontalSplitRatio: CGFloat = 0.50
    @Published public var verticalSplitRatio: CGFloat = 0.50
    @Published public var maximizedLaneID: String?

    @Published public var isBroadcastComposerPresented: Bool = false
    @Published public var broadcastDraftText: String = ""
    @Published public var broadcastSelectedLaneIDs: Set<String> = [
        "lane-claude-quic",
        "lane-codex-auth",
        "lane-agy-gateway",
        "lane-vibe-fuzz"
    ]

    @Published public var isRightInspectorVisible: Bool = true
    @Published public var rightInspectorWidth: CGFloat = 310
    @Published public var activeInspectorSection: RelayInspectorSection = .laneOwnership

    @Published public var isBottomDrawerVisible: Bool = false
    @Published public var bottomDrawerHeight: CGFloat = 220
    @Published public var activeBottomDrawerTab: RelayBottomDrawerTab = .ftsSearch
    @Published public var ftsSearchQuery: String = ""

    public init(initialTabs: [RelayWorkspaceTab] = RelaySplitWorkspaceController.defaultFlagshipTabs) {
        let resolvedTabs = initialTabs.isEmpty ? Self.defaultFlagshipTabs : initialTabs
        self.tabs = resolvedTabs
        self.activeTabID = resolvedTabs[0].id
    }

    public var activeTab: RelayWorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    public func openOrActivatePane(_ pane: RelayStudioPane, filePath: String? = nil, laneID: String? = nil) {
        if let existingIdx = tabs.firstIndex(where: {
            $0.studioPane == pane &&
            (filePath == nil || $0.associatedFilePath == filePath) &&
            (laneID == nil || $0.associatedLaneID == laneID)
        }) {
            activeTabID = tabs[existingIdx].id
            return
        }

        let tabID = "tab.\(pane.rawValue).\(filePath ?? laneID ?? UUID().uuidString)"
        let title = filePath.map { ($0 as NSString).lastPathComponent } ?? pane.rawValue
        let created = RelayWorkspaceTab(
            id: tabID,
            title: title,
            subtitle: filePath ?? pane.rawValue,
            studioPane: pane,
            associatedLaneID: laneID,
            associatedFilePath: filePath
        )
        tabs.append(created)
        activeTabID = created.id
    }

    public func closeTab(id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[idx].isPinned && tabs.count == 1 { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            tabs = Self.defaultFlagshipTabs
        }
        if activeTabID == id {
            let fallbackIdx = min(idx, tabs.count - 1)
            activeTabID = tabs[fallbackIdx].id
        }
    }

    public func togglePin(tabID: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[idx].isPinned.toggle()
    }

    public func setHorizontalSplitRatio(_ proposed: CGFloat) {
        let clamped = min(0.78, max(0.22, proposed))
        horizontalSplitRatio = abs(clamped - 0.50) < 0.025 ? 0.50 : clamped
    }

    public func setVerticalSplitRatio(_ proposed: CGFloat) {
        let clamped = min(0.78, max(0.22, proposed))
        verticalSplitRatio = abs(clamped - 0.50) < 0.025 ? 0.50 : clamped
    }

    public func toggleMaximize(laneID: String) {
        if maximizedLaneID == laneID {
            maximizedLaneID = nil
            if splitArrangement == .singleMaximized {
                splitArrangement = .quadTwoByTwo
            }
        } else {
            maximizedLaneID = laneID
            splitArrangement = .singleMaximized
        }
    }

    public func toggleRightInspector(section: RelayInspectorSection? = nil) {
        if let section {
            if isRightInspectorVisible && activeInspectorSection == section {
                isRightInspectorVisible = false
            } else {
                activeInspectorSection = section
                isRightInspectorVisible = true
            }
        } else {
            isRightInspectorVisible.toggle()
        }
    }

    public func toggleBottomDrawer(tab: RelayBottomDrawerTab? = nil) {
        if let tab {
            if isBottomDrawerVisible && activeBottomDrawerTab == tab {
                isBottomDrawerVisible = false
            } else {
                activeBottomDrawerTab = tab
                isBottomDrawerVisible = true
            }
        } else {
            isBottomDrawerVisible.toggle()
        }
    }

    public static let defaultFlagshipTabs: [RelayWorkspaceTab] = [
        RelayWorkspaceTab(
            id: "tab.pty.quad",
            title: "4-Vendor PTY Grid",
            subtitle: "Claude · Codex · AGY · Vibe",
            studioPane: .ptyGrid,
            isPinned: true,
            badgeCount: 4
        ),
        RelayWorkspaceTab(
            id: "tab.dag.http3",
            title: "HTTP/3 Relay DAG",
            subtitle: "6 Tasks · 2.16× Speedup",
            studioPane: .dagPipeline,
            isPinned: true
        ),
        RelayWorkspaceTab(
            id: "tab.merge.auth",
            title: "AuthSessionManager.swift",
            subtitle: "Sources/Auth/AuthSessionManager.swift",
            studioPane: .semanticMerge,
            associatedFilePath: "Sources/Auth/AuthSessionManager.swift",
            vendorAccent: .claudeCode,
            hasUnresolvedConflict: true,
            badgeCount: 1
        ),
        RelayWorkspaceTab(
            id: "tab.iso.map",
            title: "18-Module Territory",
            subtitle: "1 Boundary Collision",
            studioPane: .territoryMap,
            badgeCount: 1
        ),
        RelayWorkspaceTab(
            id: "tab.wiretap.spend",
            title: "Wiretap 24 Spans",
            subtitle: "1 Circuit Warning",
            studioPane: .wiretapBudget,
            badgeCount: 1
        ),
        RelayWorkspaceTab(
            id: "tab.plugins.audit",
            title: "Guardrail Policies",
            subtitle: "5 Active Findings",
            studioPane: .guardrailPlugins,
            badgeCount: 5
        )
    ]
}

// MARK: - Bauhaus Non-Blocking Toast Center

public enum RelayToastSeverity: String, Sendable, Codable, Hashable, CaseIterable {
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARNING"
    case danger = "DANGER"

    public func accentColor(using tokens: BauhausColorThemeTokens = .bauhausStandard) -> Color {
        switch self {
        case .info: return tokens.cobaltColor
        case .success: return tokens.signalGreenColor
        case .warning: return tokens.ochreColor
        case .danger: return tokens.vermilionColor
        }
    }
}

public struct RelayToastItem: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let severity: RelayToastSeverity
    public let title: String
    public let detail: String
    public let vendor: AgentVendor?
    public let shortcutHint: String?
    public let autoDismissSeconds: Double
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        severity: RelayToastSeverity,
        title: String,
        detail: String,
        vendor: AgentVendor? = nil,
        shortcutHint: String? = nil,
        autoDismissSeconds: Double = 4.5,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.vendor = vendor
        self.shortcutHint = shortcutHint
        self.autoDismissSeconds = max(1.0, autoDismissSeconds)
        self.createdAt = createdAt
    }
}

@MainActor
public final class RelayToastCenter: ObservableObject {
    @Published public private(set) var visibleToasts: [RelayToastItem] = []
    public let maxVisibleCount: Int
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init(maxVisibleCount: Int = 4) {
        self.maxVisibleCount = max(1, maxVisibleCount)
    }

    @discardableResult
    public func post(
        severity: RelayToastSeverity,
        title: String,
        detail: String,
        vendor: AgentVendor? = nil,
        shortcutHint: String? = nil,
        autoDismissSeconds: Double = 4.5,
        scheduleAutoDismiss: Bool = true
    ) -> RelayToastItem {
        let item = RelayToastItem(
            severity: severity,
            title: title,
            detail: detail,
            vendor: vendor,
            shortcutHint: shortcutHint,
            autoDismissSeconds: autoDismissSeconds
        )
        visibleToasts.append(item)
        if visibleToasts.count > maxVisibleCount {
            let evicted = visibleToasts.removeFirst()
            dismissTasks[evicted.id]?.cancel()
            dismissTasks.removeValue(forKey: evicted.id)
        }

        if scheduleAutoDismiss {
            let id = item.id
            let delayNs = UInt64(item.autoDismissSeconds * 1_000_000_000.0)
            dismissTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                self?.dismiss(id: id)
            }
        }
        return item
    }

    public func dismiss(id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)
        visibleToasts.removeAll { $0.id == id }
    }

    public func dismissAll() {
        for task in dismissTasks.values {
            task.cancel()
        }
        dismissTasks.removeAll()
        visibleToasts.removeAll()
    }

    public func postSemanticMergeFeedback(_ report: ThreeWaySemanticMergeReport) {
        if report.isCleanlyMerged {
            _ = post(
                severity: .success,
                title: "Clean 3-Way Semantic AST Merge",
                detail: "\(report.relativePath): \(report.autoMergedCount) declarations auto-merged with 0 conflicts.",
                shortcutHint: "⌘3"
            )
        } else {
            _ = post(
                severity: .warning,
                title: "Intra-Function AST Conflict Requires Review",
                detail: "\(report.relativePath): \(report.autoMergedCount) auto-merged, \(report.unresolvedConflictCount) symbol conflict(s).",
                shortcutHint: "⌘3"
            )
        }
    }

    public func postCircuitBreakerStatus(laneID: String, vendor: AgentVendor, isOpen: Bool, ceilingUSD: Double) {
        if isOpen {
            _ = post(
                severity: .danger,
                title: "Budget Circuit Tripped (\(vendor.shortBadge))",
                detail: String(format: "Halted outbound API traffic on '%@' at $%.2f ceiling.", laneID, ceilingUSD),
                vendor: vendor,
                shortcutHint: "⌘⇧K"
            )
        } else {
            _ = post(
                severity: .success,
                title: "Budget Circuit Reset (\(vendor.shortBadge))",
                detail: String(format: "Restored outbound API admission on '%@' (cap $%.2f).", laneID, ceilingUSD),
                vendor: vendor,
                shortcutHint: "⌘⇧K"
            )
        }
    }
}
