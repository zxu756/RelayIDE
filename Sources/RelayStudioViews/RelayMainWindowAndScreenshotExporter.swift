import AppKit
import CoreGraphics
import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelayWorkbenchShell
import RelayWorkspaceStore
import SwiftUI

// MARK: - Complete Bauhaus Warm Sandpaper Workbench Root Chrome

public struct RelayStudioRootWorkbenchView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBauhausHeaderBar

                Rectangle()
                    .fill(RelayBauhausDesign.hairlineBorder)
                    .frame(height: 1)

                HStack(spacing: 0) {
                    leftStudioAndWorktreeRail
                        .frame(width: 218)

                    Rectangle()
                        .fill(RelayBauhausDesign.hairlineBorder)
                        .frame(width: 1)

                    VStack(spacing: 0) {
                        activeStudioPaneStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if viewModel.isBottomDrawerPresented {
                            Rectangle()
                                .fill(RelayBauhausDesign.hairlineBorder)
                                .frame(height: 1)

                            RelayBottomDrawerView(viewModel: viewModel)
                                .frame(height: 196)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(RelayBauhausDesign.warmSandpaper)

            // Toast Notification Stack (Bottom-Right)
            if !viewModel.coordinator.toastCenter.visibleToasts.isEmpty {
                RelayToastOverlayStack(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(14)
            }

            // ⌘K Fuzzy Command Palette Modal Overlay
            if viewModel.isCommandPalettePresented {
                RelayCommandPaletteModalView(viewModel: viewModel)
            }

            // ⌘, Studio Preferences Modal Overlay
            if viewModel.isPreferencesModalPresented {
                RelayPreferencesModalView(viewModel: viewModel)
            }
        }
        .background(RelayBauhausDesign.warmSandpaper)
    }

    // MARK: - Top Bauhaus Header Bar

    private var topBauhausHeaderBar: some View {
        HStack(spacing: 8) {
            // Brand Emblem + Campaign Title
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(RelayBauhausDesign.claudeVermilion)
                        .frame(width: 24, height: 24)
                    Text("R")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.warmIvory)
                }

                VStack(alignment: .leading, spacing: 0.5) {
                    HStack(spacing: 5) {
                        Text("RELAY IDE")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                            .fixedSize(horizontal: true, vertical: false)

                        Text("·")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)

                        Text("MULTI-AGENT WORKBENCH")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(viewModel.campaignTitle)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 6)

            // Active Wave Pill
            RelayBauhausPill(
                viewModel.activeWaveSummaryLabel,
                foreground: RelayBauhausDesign.codexCobalt,
                background: RelayBauhausDesign.cobaltWash,
                border: RelayBauhausDesign.codexCobalt.opacity(0.45),
                symbolName: "point.3.connected.trianglepath.dotted",
                monospaced: true
            )

            // Total Spend USD Pill
            RelayBauhausPill(
                "Spend \(RelayBauhausDesign.formatUSD(viewModel.totalWorkspaceSpendUSD)) / \(RelayBauhausDesign.formatUSD(viewModel.globalBudgetCeilingUSD))",
                foreground: RelayBauhausDesign.espressoInk,
                background: RelayBauhausDesign.warmIvory,
                border: RelayBauhausDesign.hairlineBorder,
                symbolName: "dollarsign.circle.fill",
                monospaced: true
            )

            // Undo / Redo Architectural Buttons
            HStack(spacing: 3) {
                Button {
                    viewModel.performUndo()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .bold))
                        Text("Undo")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .fill(RelayBauhausDesign.warmIvory)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.performRedo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5.5)
                        .background(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .fill(RelayBauhausDesign.warmIvory)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }

            // ⌘K Fuzzy Command Palette Trigger
            Button {
                viewModel.isCommandPalettePresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "command")
                        .font(.system(size: 10, weight: .bold))
                    Text("Palette ⌘K")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.warmIvory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .strokeBorder(RelayBauhausDesign.structuralBorder, lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)

            // Bottom Drawer Toggle
            Button {
                viewModel.isBottomDrawerPresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Drawer")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(viewModel.isBottomDrawerPresented ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(viewModel.isBottomDrawerPresented ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.warmIvory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)

            // Save Checkpoint Button
            Button {
                viewModel.createWorkspaceCheckpoint()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Checkpoint")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .foregroundStyle(RelayBauhausDesign.warmIvory)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.espressoInk)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RelayBauhausDesign.sandstoneStrip)
    }

    // MARK: - Left Studio Pane & Isolated Git Worktree Rail

    private var leftStudioAndWorktreeRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Studio Panes Navigation
            VStack(alignment: .leading, spacing: 5) {
                RelaySectionEyebrow("Studio Views", trailingText: "⌘1–6")

                ForEach(Array(RelayStudioPane.allCases.enumerated()), id: \.element.id) { idx, pane in
                    railStudioPaneRow(pane: pane, shortcutDigit: idx + 1)
                }
            }

            Divider()
                .overlay(RelayBauhausDesign.hairlineBorder)

            // Isolated Vendor Git Worktrees
            VStack(alignment: .leading, spacing: 5) {
                RelaySectionEyebrow("Agent Worktrees", trailingText: "\(viewModel.lanes.count) lanes")

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.lanes) { lane in
                            railWorktreeCard(lane)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
                .overlay(RelayBauhausDesign.hairlineBorder)

            // SQLite WAL Store Status Strip
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(RelayBauhausDesign.agySignalGreen)
                        .frame(width: 6, height: 6)
                    Text("SQLite WAL v4 · FTS5")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text("\(viewModel.checkpoints.count) checkpoints · 127.0.0.1 proxy")
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .background(RelayBauhausDesign.sandstoneStrip.opacity(0.62))
    }

    private func railStudioPaneRow(pane: RelayStudioPane, shortcutDigit: Int) -> some View {
        let isSelected = (viewModel.activePane == pane)
        let shortTitle = concisePaneTitle(pane)
        let badgeText = railBadge(for: pane)

        return Button {
            viewModel.selectPane(pane)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: pane.sfSymbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.claudeVermilion)
                    .frame(width: 15)

                Text(shortTitle)
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 2)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.graphiteInk)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.18) : RelayBauhausDesign.sandstoneStrip)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text("⌘\(shortcutDigit)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .fill(isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.warmIvory)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .strokeBorder(isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func concisePaneTitle(_ pane: RelayStudioPane) -> String {
        switch pane {
        case .ptyGrid:
            return "PTY Grid"
        case .dagPipeline:
            return "Relay DAG"
        case .semanticMerge:
            return "AST Merge"
        case .territoryMap:
            return "Territory Map"
        case .wiretapBudget:
            return "Wiretap Spend"
        case .guardrailPlugins:
            return "JS Guardrails"
        }
    }

    private func railBadge(for pane: RelayStudioPane) -> String? {
        switch pane {
        case .ptyGrid:
            return "\(viewModel.lanes.count)"
        case .dagPipeline:
            return "\(viewModel.dagSpec.tasks.count)"
        case .semanticMerge:
            let c = viewModel.totalUnresolvedConflicts
            return c > 0 ? "\(c)!" : "OK"
        case .territoryMap:
            return "\(viewModel.isometricTiles.count)"
        case .wiretapBudget:
            return RelayBauhausDesign.formatUSD(viewModel.totalWorkspaceSpendUSD)
        case .guardrailPlugins:
            return "\(viewModel.policyPack.entries.count)"
        }
    }

    private func railWorktreeCard(_ lane: ManagedWorktreeLane) -> some View {
        let isSelected = (viewModel.selectedLaneID == lane.id)
        let accent = RelayBauhausDesign.vendorColor(lane.assignedVendor)
        let acct = viewModel.budgetAccount(forLane: lane.id)

        return Button {
            viewModel.selectedLaneID = lane.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent)
                        .frame(width: 6, height: 6)

                    Text(RelayBauhausDesign.vendorStudioName(lane.assignedVendor))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    if let acct {
                        Text(RelayBauhausDesign.formatUSD(acct.spentUSD))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(acct.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.graphiteInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Text(lane.id)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 5) {
                    Text("+\(lane.totalAdditions)/-\(lane.totalDeletions)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.agySignalGreen)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    Text("\(lane.dirtyFiles.count) files")
                        .font(.system(size: 9, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .fill(RelayBauhausDesign.warmIvory)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .strokeBorder(isSelected ? accent : RelayBauhausDesign.hairlineBorder, lineWidth: isSelected ? 1.5 : 1.0)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active Center Studio Stage

    @ViewBuilder
    private var activeStudioPaneStage: some View {
        switch viewModel.activePane {
        case .ptyGrid:
            PTYMultiplexerGridView(viewModel: viewModel)
        case .dagPipeline:
            RelayDAGPipelineCanvasView(viewModel: viewModel)
        case .semanticMerge:
            SemanticASTMergeStudioView(viewModel: viewModel)
        case .territoryMap:
            IsometricTerritoryMapCanvasView(viewModel: viewModel)
        case .wiretapBudget:
            WiretapBudgetStudioView(viewModel: viewModel)
        case .guardrailPlugins:
            GuardrailPluginStudioView(viewModel: viewModel)
        }
    }
}

// MARK: - Bottom Drawer (FTS5 Search, Hook Trace, Git Worktrees)

public struct RelayBottomDrawerView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(RelayBottomDrawerMode.allCases) { mode in
                    let isSelected = (viewModel.activeBottomDrawerMode == mode)
                    Button {
                        viewModel.activeBottomDrawerMode = mode
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 10, weight: .bold))
                            Text(mode.rawValue)
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.warmIvory)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if viewModel.activeBottomDrawerMode == .ftsSearch {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        RelayAdaptiveTextField(
                            "FTS5 BM25 query across transcripts, handoffs & merges",
                            text: Binding(
                                get: { viewModel.ftsQueryText },
                                set: { viewModel.runFTSSearch($0) }
                            ),
                            font: .system(size: 11, design: .monospaced)
                        )
                        .frame(width: 320)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(RelayBauhausDesign.warmIvory)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                    )
                }

                Button {
                    viewModel.isBottomDrawerPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                        .padding(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RelayBauhausDesign.sandstoneStrip)

            Rectangle()
                .fill(RelayBauhausDesign.hairlineBorder)
                .frame(height: 1)

            RelayAdaptiveScrollContainer {
                switch viewModel.activeBottomDrawerMode {
                case .ftsSearch:
                    ftsResultsContent
                case .hookTrace:
                    hookTraceContent
                case .gitWorktrees:
                    gitWorktreeCommitsContent
                }
            }
            .padding(8)
            .background(RelayBauhausDesign.warmIvory)
        }
    }

    private var ftsResultsContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(viewModel.ftsSearchResults) { hit in
                HStack(spacing: 8) {
                    RelayVendorBadge(vendor: hit.vendor, compact: true)
                    Text(hit.corpus.displayTitle)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.codexCobalt)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(hit.title)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(String(format: "BM25 %.2f", hit.relevanceScore))
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.4))
                )
            }
        }
    }

    private var hookTraceContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(viewModel.hookTraceEntries) { trace in
                HStack(spacing: 8) {
                    Text("#\(trace.sequenceNumber)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    Text(trace.hookKind.rawValue)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.codexCobalt)
                    Text(trace.decision.rawValue)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(trace.decision == .veto ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen)
                    Text("\(trace.pluginName) · \(trace.reasonSummary)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(String(format: "%.0f µs", trace.elapsedMicros))
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.4))
                )
            }
        }
    }

    private var gitWorktreeCommitsContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(viewModel.gitCommits) { commit in
                HStack(spacing: 8) {
                    Text(commit.shortOID)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(commit.subject)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(commit.authorName)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.4))
                )
            }
        }
    }
}

// MARK: - ⌘K Fuzzy Command Palette Modal, Preferences Modal & Toast Stack

public struct RelayCommandPaletteModalView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.isCommandPalettePresented = false
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)

                    RelayAdaptiveTextField(
                        "Jump to studio pane, run AST merge, trip circuit, or save checkpoint",
                        text: $viewModel.commandPaletteQuery,
                        font: .system(size: 13, weight: .medium)
                    )

                    Button("ESC") {
                        viewModel.isCommandPalettePresented = false
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                }
                .padding(12)
                .background(RelayBauhausDesign.sandstoneStrip)

                Rectangle()
                    .fill(RelayBauhausDesign.hairlineBorder)
                    .frame(height: 1)

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredActions) { action in
                            Button {
                                if let pane = action.targetPane {
                                    viewModel.selectPane(pane)
                                }
                                viewModel.isCommandPalettePresented = false
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(action.title)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                                        Text(action.subtitle)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(RelayBauhausDesign.graphiteInk)
                                    }
                                    Spacer()
                                    Text(action.shortcutHint)
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                                .fill(RelayBauhausDesign.vermilionWash)
                                        )
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                        .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.35))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 560)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                    .fill(RelayBauhausDesign.warmIvory)
            )
            .clipShape(RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                    .strokeBorder(RelayBauhausDesign.espressoInk, lineWidth: 1.5)
            )
        }
    }

    private var filteredActions: [RelayCommandAction] {
        viewModel.coordinator.shellState.commandQuery = viewModel.commandPaletteQuery
        return viewModel.coordinator.shellState.filteredActions()
    }
}

public struct RelayPreferencesModalView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.isPreferencesModalPresented = false
                }

            RelayBauhausCard(padding: 16, fill: RelayBauhausDesign.warmIvory, borderColor: RelayBauhausDesign.espressoInk) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("RelayIDE Studio Preferences")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                        Spacer()
                        Button("Close") {
                            viewModel.isPreferencesModalPresented = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                    }

                    Divider().overlay(RelayBauhausDesign.hairlineBorder)

                    Toggle(
                        "Redact Outbound Secrets in Loopback Proxy by Default",
                        isOn: Binding(
                            get: { viewModel.coordinator.preferences.snapshot.outboundDLPRedactByDefault },
                            set: { viewModel.coordinator.preferences.snapshot.outboundDLPRedactByDefault = $0 }
                        )
                    )
                    .font(.system(size: 12))

                    Toggle(
                        "Auto-Run 3-Way Semantic AST Merge on .relay Handoff",
                        isOn: Binding(
                            get: { viewModel.coordinator.preferences.snapshot.autoRunSemanticMergeOnHandoff },
                            set: { viewModel.coordinator.preferences.snapshot.autoRunSemanticMergeOnHandoff = $0 }
                        )
                    )
                    .font(.system(size: 12))

                    HStack {
                        Text("Global Workspace USD Budget Ceiling")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(RelayBauhausDesign.formatUSD(viewModel.globalBudgetCeilingUSD))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                    }
                }
            }
            .frame(width: 460)
        }
    }
}

public struct RelayToastOverlayStack: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(viewModel.coordinator.toastCenter.visibleToasts) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(item.severity.accentColor())
                        .frame(width: 4, height: 28)

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                        Text(item.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    }

                    Button {
                        viewModel.coordinator.toastCenter.dismiss(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                        .fill(RelayBauhausDesign.warmIvory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                        .strokeBorder(RelayBauhausDesign.espressoInk, lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Native macOS Menu Bar Commands

public struct RelayStudioMenuCommands: Commands {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some Commands {
        CommandMenu("Studio") {
            Button("2×2 Multi-Vendor PTY Grid") {
                viewModel.selectPane(.ptyGrid)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Topological Relay DAG") {
                viewModel.selectPane(.dagPipeline)
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("3-Way Semantic AST Merge Studio") {
                viewModel.selectPane(.semanticMerge)
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("2.5D Isometric Coupling & Territory Map") {
                viewModel.selectPane(.territoryMap)
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button("Wiretap Flamechart & USD Spend") {
                viewModel.selectPane(.wiretapBudget)
            }
            .keyboardShortcut("5", modifiers: [.command])

            Button("JavaScriptCore Guardrail Plugins") {
                viewModel.selectPane(.guardrailPlugins)
            }
            .keyboardShortcut("6", modifiers: [.command])

            Divider()

            Button("Fuzzy Command Palette") {
                viewModel.isCommandPalettePresented.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Broadcast Input to PTY Lanes") {
                viewModel.selectPane(.ptyGrid)
                viewModel.isBroadcastBarExpanded.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button("Toggle Bottom Search & Trace Drawer") {
                viewModel.isBottomDrawerPresented.toggle()
            }
            .keyboardShortcut("j", modifiers: [.command])

            Divider()

            Button("Studio Preferences") {
                viewModel.isPreferencesModalPresented = true
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("Workspace") {
            Button("Undo Workspace Mutation") {
                viewModel.performUndo()
            }
            .keyboardShortcut("z", modifiers: [.command])

            Button("Redo Workspace Mutation") {
                viewModel.performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider()

            Button("Create Named Checkpoint Snapshot") {
                viewModel.createWorkspaceCheckpoint()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Deterministic 2x Retina Screenshot Exporter (2720 × 1680 px)

@MainActor
public enum RelayRetinaScreenshotExporter {
    public static let viewportPoints = CGSize(width: 1360, height: 840)
    public static let retinaScale: CGFloat = 2.0

    public struct ExportedScreenshotRecord: Sendable {
        public let fileName: String
        public let outputURL: URL
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// Exports all 4 flagship `2720 × 1680` Retina PNG screenshots into `outputDirectory`.
    @discardableResult
    public static func exportFlagshipScreenshots(to outputDirectory: URL) throws -> [ExportedScreenshotRecord] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let specs: [(fileName: String, configure: (RelayStudioViewModel) -> Void)] = [
            (
                "screenshot-pty-grid.png",
                { vm in
                    vm.selectPane(.ptyGrid)
                    vm.terminalLayoutPreset = .quad2x2
                    vm.isBroadcastBarExpanded = true
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            ),
            (
                "screenshot-semantic-merge.png",
                { vm in
                    vm.selectPane(.semanticMerge)
                    vm.selectedMergeFilePath = "Sources/Auth/AuthSessionManager.swift"
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            ),
            (
                "screenshot-territory-map.png",
                { vm in
                    vm.selectPane(.territoryMap)
                    vm.selectedIsometricModulePath = "Sources/Auth/AuthSessionManager.swift"
                    vm.territoryVendorFilter = nil
                    vm.showCrossLaneCouplingOnly = false
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            ),
            (
                "screenshot-wiretap-guardrails.png",
                { vm in
                    vm.selectPane(.wiretapBudget)
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            )
        ]

        var exported: [ExportedScreenshotRecord] = []
        for spec in specs {
            let vm = RelayStudioViewModel(initialPane: .ptyGrid)
            spec.configure(vm)
            // Ensure zero transient toasts occlude the exported Retina frame
            for t in vm.coordinator.toastCenter.visibleToasts {
                vm.coordinator.toastCenter.dismiss(id: t.id)
            }

            let rootView = RelayStudioRootWorkbenchView(viewModel: vm)
                .frame(width: viewportPoints.width, height: viewportPoints.height)
                .environment(\.colorScheme, .light)
                .environment(\.relaySnapshotRenderMode, true)

            let renderer = ImageRenderer(content: rootView)
            renderer.scale = retinaScale
            renderer.proposedSize = ProposedViewSize(viewportPoints)

            guard let cgImage = renderer.cgImage else {
                throw RelayIDEError.invalidCLIUsage("ImageRenderer failed to rasterize \(spec.fileName)")
            }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = viewportPoints
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw RelayIDEError.invalidCLIUsage("PNG encoding failed for \(spec.fileName)")
            }

            let fileURL = outputDirectory.appendingPathComponent(spec.fileName)
            try pngData.write(to: fileURL, options: [.atomic])
            exported.append(
                ExportedScreenshotRecord(
                    fileName: spec.fileName,
                    outputURL: fileURL,
                    pixelWidth: cgImage.width,
                    pixelHeight: cgImage.height
                )
            )
        }
        return exported
    }
}
