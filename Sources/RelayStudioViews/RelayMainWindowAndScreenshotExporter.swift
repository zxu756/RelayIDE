import AppKit
import CoreGraphics
import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelayWorkbenchShell
import RelayWorkspaceStore
import SwiftUI

// MARK: - Bauhaus Warm Sandpaper Segmented Language Pill (`中文 | EN`)

public struct RelayLanguageTogglePill: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let activeLang = viewModel.currentLanguage
        HStack(spacing: 0) {
            languageSegment(.zhHans, isSelected: activeLang == .zhHans)

            Rectangle()
                .fill(RelayBauhausDesign.structuralBorder)
                .frame(width: 1, height: 14)

            languageSegment(.en, isSelected: activeLang == .en)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius + 1, style: .continuous)
                .fill(RelayBauhausDesign.warmSandpaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius + 1, style: .continuous)
                .strokeBorder(RelayBauhausDesign.carbonMatteWell.opacity(0.82), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help("切换语言 / Toggle Language (⇧⌘L)")
    }

    private func languageSegment(_ lang: RelayLanguage, isSelected: Bool) -> some View {
        Button {
            viewModel.setLanguage(lang, postToast: true)
        } label: {
            HStack(spacing: 4) {
                if isSelected {
                    Circle()
                        .fill(RelayBauhausDesign.terracottaAccent)
                        .frame(width: 5, height: 5)
                }
                Text(lang.badge)
                    .font(lang == .en
                          ? .system(size: 10.5, weight: .bold, design: .monospaced)
                          : .system(size: 10.5, weight: .bold))
                    .tracking(0)
            }
            .foregroundStyle(isSelected ? RelayBauhausDesign.warmSandpaper : RelayBauhausDesign.carbonMatteWell)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius - 0.5, style: .continuous)
                    .fill(isSelected ? RelayBauhausDesign.carbonMatteWell : Color.clear)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }
}

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
                        .frame(width: 236)

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

                Rectangle()
                    .fill(RelayBauhausDesign.hairlineBorder)
                    .frame(height: 1)

                bottomStudioStatusBar
            }
            .background(RelayBauhausDesign.warmSandpaper)

            // Toast Notification Stack (Bottom-Right)
            if !viewModel.coordinator.toastCenter.visibleToasts.isEmpty {
                RelayToastOverlayStack(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
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
        let isZh = viewModel.currentLanguage.isChinese
        return HStack(spacing: 7) {
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

                        Text(viewModel.L("MULTI-AGENT WORKBENCH", "多智能体接力编排工作台"))
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(isZh ? 0 : 0.6)
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(viewModel.localizedCampaignTitle)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 6)

            if viewModel.isDemoMode {
                RelayBauhausPill(
                    viewModel.demoBadgeLabel,
                    foreground: RelayBauhausDesign.warmIvory,
                    background: RelayBauhausDesign.claudeVermilion,
                    border: RelayBauhausDesign.espressoInk,
                    symbolName: "sparkles.rectangle.stack.fill",
                    monospaced: !isZh
                )
            } else if viewModel.lanes.isEmpty {
                Button {
                    viewModel.loadDemoCampaign()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(viewModel.L("Load Demo", "载入演示数据"))
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .fill(RelayBauhausDesign.vermilionWash)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .strokeBorder(RelayBauhausDesign.claudeVermilion.opacity(0.65), lineWidth: 1)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }

            // Active Wave Pill
            RelayBauhausPill(
                viewModel.activeWaveSummaryLabel,
                foreground: RelayBauhausDesign.codexCobalt,
                background: RelayBauhausDesign.cobaltWash,
                border: RelayBauhausDesign.codexCobalt.opacity(0.45),
                symbolName: "point.3.connected.trianglepath.dotted",
                monospaced: !isZh
            )

            // Total Spend USD Pill (hidden when empty and non-demo so zero fake spend numbers appear)
            if viewModel.isDemoMode {
                RelayBauhausPill(
                    viewModel.L(
                        "Spend \(RelayBauhausDesign.formatUSD(viewModel.totalWorkspaceSpendUSD)) / \(RelayBauhausDesign.formatUSD(viewModel.globalBudgetCeilingUSD))",
                        "消耗 \(RelayBauhausDesign.formatUSD(viewModel.totalWorkspaceSpendUSD)) / \(RelayBauhausDesign.formatUSD(viewModel.globalBudgetCeilingUSD))"
                    ),
                    foreground: RelayBauhausDesign.espressoInk,
                    background: RelayBauhausDesign.warmIvory,
                    border: RelayBauhausDesign.hairlineBorder,
                    symbolName: "dollarsign.circle.fill",
                    monospaced: !isZh
                )
            } else if let run = viewModel.activeRun {
                if run.pricedLaneCount > 0 || run.budgetUSD != nil {
                    let spendText = RelayBauhausDesign.formatRunUSD(run.totalCostUSD)
                    let capSuffix = run.budgetUSD.map { " / \(RelayBauhausDesign.formatRunUSD($0))" } ?? ""
                    let unpricedSuffix = run.unpricedTokens > 0
                        ? viewModel.L(" · \(run.unpricedTokens) tokens unpriced", " · \(run.unpricedTokens) tokens 未计价")
                        : ""
                    RelayBauhausPill(
                        viewModel.L(
                            "Spend \(spendText)\(capSuffix)\(unpricedSuffix)",
                            "花费 \(spendText)\(capSuffix)\(unpricedSuffix)"
                        ),
                        foreground: RelayBauhausDesign.espressoInk,
                        background: RelayBauhausDesign.warmIvory,
                        border: RelayBauhausDesign.hairlineBorder,
                        symbolName: "dollarsign.circle.fill",
                        monospaced: !isZh
                    )
                } else if run.unpricedTokens > 0 {
                    RelayBauhausPill(
                        viewModel.L(
                            "\(run.unpricedTokens) tokens · unpriced",
                            "\(run.unpricedTokens) tokens · 未计价"
                        ),
                        foreground: RelayBauhausDesign.espressoInk,
                        background: RelayBauhausDesign.warmIvory,
                        border: RelayBauhausDesign.hairlineBorder,
                        symbolName: "number.circle.fill",
                        monospaced: !isZh
                    )
                }
            }

            // Bauhaus `中文 | EN` Live Language Toggle Pill (`⇧⌘L`)
            RelayLanguageTogglePill(viewModel: viewModel)

            // Undo / Redo Architectural Buttons
            HStack(spacing: 3) {
                Button {
                    viewModel.performUndo()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .bold))
                        Text(viewModel.L("Undo", "撤销"))
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
                    Text(viewModel.L("Palette ⌘K", "命令面板 ⌘K"))
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
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
                    Text(viewModel.L("Drawer", "抽屉"))
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
                    Text(viewModel.L("Checkpoint", "快照"))
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

    // MARK: - Bottom Architectural Status Bar

    private var bottomStudioStatusBar: some View {
        let selectedLane = viewModel.lane(forID: viewModel.selectedLaneID)
        let activePaneLabel = viewModel.activePane.localizedTitle(in: viewModel.currentLanguage)
        let autoCount = viewModel.totalAutoMergedDeclarations
        let conflictCount = viewModel.totalUnresolvedConflicts

        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(RelayBauhausDesign.agySignalGreen)
                    .frame(width: 6, height: 6)
                Text(viewModel.coordinator.shellState.statusBannerText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text("·")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)

            if let selectedLane {
                Text(viewModel.T(selectedLane.displayName))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 6)

            if viewModel.isDemoMode {
                Text(
                    viewModel.L(
                        "AST Auto-Merged: \(autoCount) · Conflicts: \(conflictCount)",
                        "AST 自动合并：\(autoCount) · 待裁决冲突：\(conflictCount)"
                    )
                )
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(conflictCount > 0 ? RelayBauhausDesign.terracottaAccent : RelayBauhausDesign.agySignalGreen)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(viewModel.L("Read-Only Live Observer", "只读实时观察模式"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.agySignalGreen)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text("·")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)

            Text(activePaneLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: true, vertical: false)

            Text("·")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)

            Text("\(viewModel.currentLanguage.displayName) · ⇧⌘L")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.terracottaAccent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RelayBauhausDesign.sandstoneStrip)
    }

    // MARK: - Left Studio Pane & Isolated Git Worktree Rail

    private var leftStudioAndWorktreeRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Studio Panes Navigation
            VStack(alignment: .leading, spacing: 5) {
                RelaySectionEyebrow(
                    viewModel.L("Studio Views", "工作台视图"),
                    trailingText: "⌘1–5"
                )

                ForEach(Array(RelayStudioPane.allCases.enumerated()), id: \.element.id) { idx, pane in
                    railStudioPaneRow(pane: pane, shortcutDigit: idx + 1)
                }
            }

            Divider()
                .overlay(RelayBauhausDesign.hairlineBorder)

            // Isolated Vendor Git Worktrees
            VStack(alignment: .leading, spacing: 5) {
                RelaySectionEyebrow(
                    viewModel.L("Agent Worktrees", "智能体工作树"),
                    trailingText: viewModel.L("\(viewModel.lanes.count) lanes", "\(viewModel.lanes.count) 条通道")
                )

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
                    Text("SQLite WAL v\(RelayProjectDatabase.currentSchemaVersion) · FTS5")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(
                    viewModel.L(
                        "\(viewModel.checkpoints.count) checkpoints",
                        "\(viewModel.checkpoints.count) 个快照"
                    )
                )
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                .fixedSize(horizontal: false, vertical: true)
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
            HStack(spacing: 6) {
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
        if viewModel.currentLanguage.isChinese {
            return pane.localizedTitle(in: .zhHans)
        }
        switch pane {
        case .ptyGrid:
            return "PTY Grid"
        case .dagPipeline:
            return "Relay DAG"
        case .semanticMerge:
            return "AST Merge"
        case .territoryMap:
            return "Territory Map"
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
            return c > 0 ? "\(c)!" : viewModel.L("OK", "就绪")
        case .territoryMap:
            return "\(viewModel.isometricTiles.count)"
        case .guardrailPlugins:
            return viewModel.isDemoMode ? "\(viewModel.policyPack.entries.count)" : nil
        }
    }

    private func railWorktreeCard(_ lane: ManagedWorktreeLane) -> some View {
        let isSelected = (viewModel.selectedLaneID == lane.id)
        let accent = RelayBauhausDesign.vendorColor(lane.assignedVendor)
        let acct = viewModel.budgetAccount(forLane: lane.id)
        let liveRec = viewModel.liveRunLane(forID: lane.id)

        return Button {
            viewModel.selectedLaneID = lane.id
        } label: {
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent)
                        .frame(width: 6, height: 6)

                    Text(RelayBauhausDesign.vendorStudioName(lane.assignedVendor, language: viewModel.currentLanguage))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    if viewModel.isDemoMode, let acct {
                        Text(RelayBauhausDesign.formatUSD(acct.spentUSD))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(acct.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.graphiteInk)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if let spendLabel = viewModel.formattedLiveLaneSpend(forLane: lane.id) {
                        Text(spendLabel)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(RelayBauhausDesign.graphiteInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack(spacing: 5) {
                    Text(lane.id)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    if !viewModel.isDemoMode, let liveRec {
                        Text(liveRec.status.localizedLabel(in: viewModel.currentLanguage))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayBauhausDesign.runStatusColor(liveRec.status))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if viewModel.isDemoMode {
                    HStack(spacing: 5) {
                        Text("+\(lane.totalAdditions)/-\(lane.totalDeletions)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(RelayBauhausDesign.agySignalGreen)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 2)

                        Text(viewModel.L("\(lane.dirtyFiles.count) files", "\(lane.dirtyFiles.count) 个文件"))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else if let liveRec {
                    HStack(spacing: 5) {
                        if let ec = liveRec.exitCode {
                            Text(viewModel.L("exit \(ec)", "退出码 \(ec)"))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(ec == 0 ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.claudeVermilion)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Text(liveRec.status == .running ? viewModel.L("in progress", "执行中") : "—")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Spacer(minLength: 2)

                        if let durLabel = viewModel.formattedLiveLaneDuration(forLane: lane.id) {
                            Text(durLabel)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
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
                            Text(mode.localizedTitle(in: viewModel.currentLanguage))
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
                            viewModel.L(
                                "FTS5 BM25 query across transcripts, handoffs & merges",
                                "跨终端实录、交接产物与合并记录执行 FTS5 BM25 检索"
                            ),
                            text: Binding(
                                get: { viewModel.ftsQueryText },
                                set: { viewModel.runFTSSearch($0) }
                            ),
                            font: .system(size: 11, design: .monospaced)
                        )
                        .frame(width: 340)
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
                    RelayVendorBadge(vendor: hit.vendor, compact: true, language: viewModel.currentLanguage)
                    Text(viewModel.T(hit.corpus.displayTitle))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.codexCobalt)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(viewModel.T(hit.title))
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
                    Text(trace.decision == .veto ? viewModel.L("VETO", "拦截") : viewModel.L("ALLOW", "放行"))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(trace.decision == .veto ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen)
                    Text("\(viewModel.T(trace.pluginName)) · \(viewModel.T(trace.reasonSummary))")
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

            paletteCardBody
        }
    }

    private var paletteCardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            paletteSearchHeaderBar

            Rectangle()
                .fill(RelayBauhausDesign.hairlineBorder)
                .frame(height: 1)

            RelayAdaptiveScrollContainer {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredMatches) { match in
                        paletteMatchRow(match.item)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 336)
        }
        .frame(width: 580)
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

    private var paletteSearchHeaderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.claudeVermilion)

            RelayAdaptiveTextField(
                viewModel.L(
                    "Jump to studio pane, toggle language, run AST merge, or save checkpoint",
                    "跳转视图、切换中英文、执行三路语义合并或保存快照"
                ),
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
    }

    private func paletteMatchRow(_ item: RelayPaletteCommandItem) -> some View {
        Button {
            viewModel.coordinator.dispatchCommand(id: item.id, targetPane: item.targetPane)
            if let pane = item.targetPane {
                viewModel.selectPane(pane)
            }
            viewModel.isCommandPalettePresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.sfSymbolName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.codexCobalt)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                }

                Spacer()

                Text(item.shortcutBadge)
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

    private var filteredMatches: [ScoredPaletteCommandMatch] {
        let palette = viewModel.coordinator.commandPalette
        if palette.searchQuery != viewModel.commandPaletteQuery {
            palette.searchQuery = viewModel.commandPaletteQuery
        }
        return palette.rankedMatches
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
                        Text(viewModel.L("RelayIDE Studio Preferences", "RelayIDE 工作台偏好设置"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                        Spacer()
                        Button(viewModel.L("Close", "关闭")) {
                            viewModel.isPreferencesModalPresented = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                    }

                    Divider().overlay(RelayBauhausDesign.hairlineBorder)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.L("Interface Language (⇧⌘L)", "界面语言 (⇧⌘L)"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(RelayBauhausDesign.espressoInk)
                            Text(
                                viewModel.L(
                                    "Live bilingual switching persisted to UserDefaults",
                                    "实时切换中英文工作台界面并自动持久化偏好"
                                )
                            )
                            .font(.system(size: 10.5))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        }
                        Spacer()
                        RelayLanguageTogglePill(viewModel: viewModel)
                    }

                    if viewModel.isDemoMode {
                        Divider().overlay(RelayBauhausDesign.hairlineBorder)

                        Toggle(
                            viewModel.L(
                                "Auto-Run 3-Way Semantic AST Merge on .relay Handoff (Disabled before M3)",
                                "收到 .relay 交接产物时自动执行三路 AST 语义合并（M3 前默认关闭）"
                            ),
                            isOn: Binding(
                                get: { viewModel.coordinator.preferences.snapshot.autoRunSemanticMergeOnHandoff },
                                set: { viewModel.coordinator.preferences.snapshot.autoRunSemanticMergeOnHandoff = $0 }
                            )
                        )
                        .font(.system(size: 12))
                    }

                    if let cap = viewModel.activeBudgetCeilingUSD {
                        HStack {
                            Text(viewModel.L("Global Workspace USD Budget Ceiling", "工作区全局美元预算上限"))
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(viewModel.isDemoMode ? RelayBauhausDesign.formatUSD(cap) : RelayBauhausDesign.formatRunUSD(cap))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(width: 490)
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
        CommandMenu(viewModel.L("Studio", "工作台")) {
            Button(RelayStudioPane.ptyGrid.localizedTitle(in: viewModel.currentLanguage)) {
                viewModel.selectPane(.ptyGrid)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button(RelayStudioPane.dagPipeline.localizedTitle(in: viewModel.currentLanguage)) {
                viewModel.selectPane(.dagPipeline)
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button(RelayStudioPane.semanticMerge.localizedTitle(in: viewModel.currentLanguage)) {
                viewModel.selectPane(.semanticMerge)
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button(RelayStudioPane.territoryMap.localizedTitle(in: viewModel.currentLanguage)) {
                viewModel.selectPane(.territoryMap)
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button(RelayStudioPane.guardrailPlugins.localizedTitle(in: viewModel.currentLanguage)) {
                viewModel.selectPane(.guardrailPlugins)
            }
            .keyboardShortcut("5", modifiers: [.command])

            Divider()

            Button(viewModel.L("Fuzzy Command Palette", "模糊命令面板")) {
                viewModel.isCommandPalettePresented.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button(viewModel.L("Broadcast Input to PTY Lanes", "向 PTY 终端通道广播输入")) {
                guard viewModel.isBroadcastInputEnabled else { return }
                viewModel.selectPane(.ptyGrid)
                viewModel.isBroadcastBarExpanded.toggle()
            }
            .disabled(!viewModel.isBroadcastInputEnabled)
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button(viewModel.L("Toggle Bottom Search & Trace Drawer", "切换底部检索与轨迹抽屉")) {
                viewModel.isBottomDrawerPresented.toggle()
            }
            .keyboardShortcut("j", modifiers: [.command])

            Button("切换语言 / Toggle Language") {
                viewModel.toggleLanguage(postToast: true)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button(viewModel.L("Studio Preferences…", "工作台偏好设置…")) {
                viewModel.isPreferencesModalPresented = true
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu(viewModel.L("Workspace", "工作区")) {
            Button(viewModel.L("Undo Workspace Mutation", "撤销工作区变更")) {
                viewModel.performUndo()
            }
            .keyboardShortcut("z", modifiers: [.command])

            Button(viewModel.L("Redo Workspace Mutation", "重做工作区变更")) {
                viewModel.performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider()

            Button(viewModel.L("Create Named Checkpoint Snapshot", "创建命名检查点快照")) {
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
    /// When `language == .zhHans`, exports `-zh.png` files (`screenshot-*-zh.png`) while keeping English `.png` files untouched.
    @discardableResult
    public static func exportFlagshipScreenshots(
        to outputDirectory: URL,
        language: RelayLanguage? = nil
    ) throws -> [ExportedScreenshotRecord] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let resolvedLanguage = language ?? .en
        let fileExtensionSuffix = (resolvedLanguage == .zhHans) ? "-zh.png" : ".png"

        let specs: [(stem: String, configure: (RelayStudioViewModel) -> Void)] = [
            (
                "screenshot-pty-grid",
                { vm in
                    vm.selectPane(.ptyGrid)
                    vm.terminalLayoutPreset = .quad2x2
                    vm.isBroadcastBarExpanded = true
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            ),
            (
                "screenshot-semantic-merge",
                { vm in
                    vm.selectPane(.semanticMerge)
                    vm.selectedMergeFilePath = "Sources/Auth/AuthSessionManager.swift"
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            ),
            (
                "screenshot-territory-map",
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
                "screenshot-guardrails",
                { vm in
                    vm.selectPane(.guardrailPlugins)
                    vm.isBottomDrawerPresented = false
                    vm.isCommandPalettePresented = false
                }
            )
        ]

        var exported: [ExportedScreenshotRecord] = []
        for spec in specs {
            let fileName = spec.stem + fileExtensionSuffix
            let isolatedLocalizer = RelayLocalizer(
                language: resolvedLanguage,
                persistToUserDefaults: false
            )
            let vm = RelayStudioViewModel(
                initialPane: .ptyGrid,
                localizer: isolatedLocalizer,
                loadDemoWorkspace: true
            )
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
                throw RelayIDEError.invalidCLIUsage("ImageRenderer failed to rasterize \(fileName)")
            }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = viewportPoints
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw RelayIDEError.invalidCLIUsage("PNG encoding failed for \(fileName)")
            }

            let fileURL = outputDirectory.appendingPathComponent(fileName)
            try pngData.write(to: fileURL, options: [.atomic])
            exported.append(
                ExportedScreenshotRecord(
                    fileName: fileName,
                    outputURL: fileURL,
                    pixelWidth: cgImage.width,
                    pixelHeight: cgImage.height
                )
            )
        }
        return exported
    }
}
