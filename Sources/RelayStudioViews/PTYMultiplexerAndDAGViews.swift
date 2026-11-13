import CryptoKit
import Foundation
import RelayModels
import RelayOrchestrator
import RelayPTYCore
import RelayWorkbenchShell
import SwiftUI

// MARK: - 1. Multi-Vendor PTY Multiplexer Grid + CPM DAG & .relay Handoff Inspector

public struct PTYMultiplexerGridView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            ptyTopControlStrip

            if viewModel.isBroadcastBarExpanded {
                broadcastComposerBar
            }

            HStack(alignment: .top, spacing: 10) {
                ptyArrangementStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                PTYCriticalPathAndHandoffInspector(viewModel: viewModel)
                    .frame(width: 288)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(10)
        .background(RelayBauhausDesign.warmSandpaper)
    }

    // MARK: - Top Control Bar (Layout Presets, Live Scrollback Search, Broadcast Toggle)

    private var ptyTopControlStrip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(RelayTerminalGridPreset.allCases) { preset in
                    let isSelected = (viewModel.terminalLayoutPreset == preset)
                    Button {
                        viewModel.setTerminalLayoutPreset(preset)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: preset.symbolName)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(preset.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .fill(isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.warmIvory)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .strokeBorder(isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Live Scrollback Search Input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)

                RelayAdaptiveTextField(
                    "Search VT100 scrollback",
                    text: Binding(
                        get: { viewModel.terminalSearchQuery },
                        set: { viewModel.updateTerminalSearch($0) }
                    ),
                    font: .system(size: 11.5, design: .monospaced)
                )

                if !viewModel.terminalSearchQuery.isEmpty {
                    let hits = viewModel.totalTerminalSearchHits
                    Text("\(hits) hits")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(hits > 0 ? RelayBauhausDesign.codexCobalt : RelayBauhausDesign.claudeVermilion)
                        .fixedSize(horizontal: true, vertical: false)

                    Button {
                        viewModel.stepTerminalSearchHit(delta: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.stepTerminalSearchHit(delta: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.updateTerminalSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("BMH + Regex")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .fill(RelayBauhausDesign.warmIvory)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )

            Spacer(minLength: 4)

            RelayBauhausPill(
                "PTY 96×26 · TrueColor",
                foreground: RelayBauhausDesign.graphiteInk,
                background: RelayBauhausDesign.warmIvory,
                border: RelayBauhausDesign.hairlineBorder,
                symbolName: "terminal",
                monospaced: true
            )

            Button {
                viewModel.isBroadcastBarExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Broadcast Input ⌘⇧B")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(viewModel.isBroadcastBarExpanded ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.claudeVermilion)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(viewModel.isBroadcastBarExpanded ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.vermilionWash)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .strokeBorder(RelayBauhausDesign.claudeVermilion, lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - Broadcast Input Bar (⌘⇧B)

    private var broadcastComposerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                Text("TARGETS")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 4) {
                ForEach(viewModel.lanes) { lane in
                    let isTargeted = viewModel.broadcastTargetLaneIDs.contains(lane.id)
                    let accent = RelayBauhausDesign.vendorColor(lane.assignedVendor)
                    Button {
                        viewModel.toggleBroadcastTarget(laneID: lane.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isTargeted ? "checkmark.square.fill" : "square")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isTargeted ? accent : RelayBauhausDesign.mutedStoneInk)
                            Text(RelayBauhausDesign.vendorShortTag(lane.assignedVendor))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(isTargeted ? accent : RelayBauhausDesign.graphiteInk)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .fill(isTargeted ? RelayBauhausDesign.vendorWashColor(lane.assignedVendor) : RelayBauhausDesign.sandstoneStrip)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .strokeBorder(isTargeted ? accent.opacity(0.6) : RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.claudeVermilion)

                RelayAdaptiveTextField(
                    "Broadcast shell command to selected PTY worktrees",
                    text: $viewModel.broadcastDraftCommand,
                    font: .system(size: 11.5, weight: .medium, design: .monospaced),
                    onSubmitAction: {
                        viewModel.dispatchBroadcastCommand()
                    }
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )

            Button {
                viewModel.dispatchBroadcastCommand()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Send (\(viewModel.broadcastTargetLaneIDs.count) Lanes)")
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(RelayBauhausDesign.warmIvory)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.espressoInk)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.warmIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - PTY Grid Arrangement Stage

    @ViewBuilder
    private var ptyArrangementStage: some View {
        let lanes = viewModel.lanes
        switch viewModel.terminalLayoutPreset {
        case .quad2x2:
            if lanes.count >= 4 {
                GeometryReader { geo in
                    let colW = max(180, (geo.size.width - 8) * 0.5)
                    let rowH = max(120, (geo.size.height - 8) * 0.5)
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            RecessedVT100TerminalPaneView(lane: lanes[0], viewModel: viewModel)
                                .frame(width: colW, height: rowH)
                            RecessedVT100TerminalPaneView(lane: lanes[1], viewModel: viewModel)
                                .frame(width: colW, height: rowH)
                        }
                        HStack(spacing: 8) {
                            RecessedVT100TerminalPaneView(lane: lanes[2], viewModel: viewModel)
                                .frame(width: colW, height: rowH)
                            RecessedVT100TerminalPaneView(lane: lanes[3], viewModel: viewModel)
                                .frame(width: colW, height: rowH)
                        }
                    }
                }
            } else {
                fallbackStack(for: lanes)
            }

        case .conductor1Plus3:
            if lanes.count >= 4 {
                let primaryLane = lanes.first(where: { $0.id == viewModel.selectedLaneID }) ?? lanes[0]
                let secondaryLanes = lanes.filter { $0.id != primaryLane.id }
                HStack(spacing: 8) {
                    RecessedVT100TerminalPaneView(lane: primaryLane, viewModel: viewModel, maxVisibleRows: 22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 8) {
                        ForEach(secondaryLanes) { secLane in
                            RecessedVT100TerminalPaneView(lane: secLane, viewModel: viewModel, maxVisibleRows: 8)
                        }
                    }
                    .frame(width: 340)
                }
            } else {
                fallbackStack(for: lanes)
            }

        case .sideBySide:
            HStack(spacing: 8) {
                ForEach(lanes.prefix(2)) { lane in
                    RecessedVT100TerminalPaneView(lane: lane, viewModel: viewModel, maxVisibleRows: 22)
                }
            }
        }
    }

    private func fallbackStack(for lanes: [ManagedWorktreeLane]) -> some View {
        VStack(spacing: 8) {
            ForEach(lanes) { lane in
                RecessedVT100TerminalPaneView(lane: lane, viewModel: viewModel)
            }
        }
    }
}

// MARK: - Individual Recessed #18181B VT100 Colored Terminal Pane

public struct RecessedVT100TerminalPaneView: View {
    public let lane: ManagedWorktreeLane
    @ObservedObject public var viewModel: RelayStudioViewModel
    public var maxVisibleRows: Int

    public init(
        lane: ManagedWorktreeLane,
        viewModel: RelayStudioViewModel,
        maxVisibleRows: Int = 14
    ) {
        self.lane = lane
        self.viewModel = viewModel
        self.maxVisibleRows = maxVisibleRows
    }

    private var isSelected: Bool {
        viewModel.selectedLaneID == lane.id
    }

    private var vendorAccent: Color {
        RelayBauhausDesign.vendorColor(lane.assignedVendor)
    }

    private var budgetAccount: LaneBudgetAccount? {
        viewModel.budgetAccount(forLane: lane.id)
    }

    private var snapshot: TerminalViewportSnapshot? {
        viewModel.terminalSnapshotsByLane[lane.id]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalVendorHeaderStrip

            Rectangle()
                .fill(RelayBauhausDesign.carbonInsetBorder)
                .frame(height: 1)

            terminalViewportContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle()
                .fill(RelayBauhausDesign.carbonInsetBorder)
                .frame(height: 1)

            terminalOwnershipAndTelemetryFooter
        }
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.carbonMatteWell)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? vendorAccent : RelayBauhausDesign.carbonInsetBorder,
                    lineWidth: isSelected ? 1.5 : 1.0
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedLaneID = lane.id
        }
    }

    private var terminalVendorHeaderStrip: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(vendorAccent)
                .frame(width: 4, height: 14)

            Text("\(RelayBauhausDesign.vendorStudioName(lane.assignedVendor)) · \(lane.id)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayBauhausDesign.carbonPrimaryText)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            if let acct = budgetAccount {
                if acct.circuitOpen {
                    Text("429")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(relayHex: "#FCA5A5"))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(relayHex: "#451A1A"))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(RelayBauhausDesign.claudeVermilion, lineWidth: 1)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text("\(RelayBauhausDesign.formatTokensCompact(acct.inputTokens + acct.outputTokens)) · \(RelayBauhausDesign.formatUSD(acct.spentUSD))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(acct.circuitOpen ? Color(relayHex: "#FDBA74") : Color(relayHex: "#D4D4D8"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(relayHex: "#27272A"))
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RelayBauhausDesign.carbonHeaderBar)
    }

    private var terminalViewportContent: some View {
        let renderedRows = buildRenderedTerminalRows()
        let laneHits = viewModel.terminalSearchMatchesByLane[lane.id] ?? []
        let matchedRowIndices = Set(laneHits.compactMap { match -> Int? in
            if case .activeViewport(let r) = match.origin { return r }
            return match.lineIndex
        })

        return RelayAdaptiveScrollContainer {
            VStack(alignment: .leading, spacing: 1.5) {
                ForEach(renderedRows) { row in
                    let isSearchMatch = matchedRowIndices.contains(row.rowIndex)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%02d", row.rowIndex + 1))
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(isSearchMatch ? Color(relayHex: "#FACC15") : RelayBauhausDesign.carbonGutterInk)
                            .frame(width: 16, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(row.attributedLine)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .lineSpacing(1.0)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 0.5)
                    .background(
                        isSearchMatch
                            ? Color(relayHex: "#854D0E").opacity(0.38)
                            : Color.clear
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var terminalOwnershipAndTelemetryFooter: some View {
        let branchShort = lane.branchName.replacingOccurrences(of: "relay/", with: "")
        let primaryGlob = conciseOwnershipSummary(lane.ownershipRule.allowedGlobs)
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(vendorAccent)
                Text(branchShort)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(relayHex: "#D4D4D8"))
            }
            .fixedSize(horizontal: true, vertical: false)

            Text("·")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.carbonGutterInk)

            HStack(spacing: 3) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color(relayHex: "#A1A1AA"))
                Text(primaryGlob)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(relayHex: "#A1A1AA"))
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            Text("+\(lane.totalAdditions)/-\(lane.totalDeletions)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color(relayHex: "#4ADE80"))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(Color(relayHex: "#1E1E23"))
    }

    private func conciseOwnershipSummary(_ globs: [String]) -> String {
        guard !globs.isEmpty else { return "**" }
        if globs.count == 1 { return globs[0] }
        let cleaned = globs.map {
            $0.replacingOccurrences(of: "Sources/", with: "")
              .replacingOccurrences(of: "/**", with: "")
        }
        return "Sources/{" + cleaned.joined(separator: ",") + "}"
    }

    // MARK: - VT100 Cell Run -> AttributedString Renderer

    private struct RenderedVT100Row: Identifiable {
        let id: Int
        let rowIndex: Int
        let attributedLine: AttributedString
    }

    private func buildRenderedTerminalRows() -> [RenderedVT100Row] {
        guard let snap = snapshot else {
            return [
                RenderedVT100Row(
                    id: 0,
                    rowIndex: 0,
                    attributedLine: AttributedString("$ awaiting pty session attach")
                )
            ]
        }

        // Trim trailing completely blank rows while keeping cursor row visible
        var lastActiveRow = min(snap.visibleGrid.count - 1, max(0, snap.cursor.row))
        for rIdx in snap.visibleGrid.indices {
            let row = snap.visibleGrid[rIdx]
            let hasContent = row.contains { cell in
                cell.grapheme != " " || cell.background != .defaultBackground || !cell.attributes.isEmpty
            }
            if hasContent {
                lastActiveRow = max(lastActiveRow, rIdx)
            }
        }

        let upperBound = min(snap.visibleGrid.count, max(1, min(lastActiveRow + 1, maxVisibleRows)))
        var rows: [RenderedVT100Row] = []
        rows.reserveCapacity(upperBound)

        for rIdx in 0..<upperBound {
            let cells = snap.visibleGrid[rIdx]
            let isCursorRow = snap.cursor.isVisible && (snap.cursor.row == rIdx)
            let attr = buildAttributedLine(
                cells: cells,
                isCursorRow: isCursorRow,
                cursorColumn: snap.cursor.column,
                cursorShape: snap.cursor.shape
            )
            rows.append(RenderedVT100Row(id: rIdx, rowIndex: rIdx, attributedLine: attr))
        }
        return rows
    }

    private func buildAttributedLine(
        cells: [TerminalCell],
        isCursorRow: Bool,
        cursorColumn: Int,
        cursorShape: TerminalCursorShape
    ) -> AttributedString {
        var lastCol = cells.count - 1
        while lastCol >= 0 {
            let c = cells[lastCol]
            let isCursorHere = isCursorRow && (lastCol == cursorColumn)
            if isCursorHere || c.grapheme != " " || c.background != .defaultBackground || !c.attributes.isEmpty {
                break
            }
            lastCol -= 1
        }

        if lastCol < 0 {
            if isCursorRow {
                var cursorBlock = AttributedString("▋")
                cursorBlock.foregroundColor = vendorAccent
                return cursorBlock
            }
            return AttributedString(" ")
        }

        var output = AttributedString()
        let palette = viewModel.xtermPalette
        let defaultBG = palette.theme.defaultBackground

        struct StyledSegment {
            var text: String
            var fg: RGBATerminalColor
            var bg: RGBATerminalColor
            var hasCustomBG: Bool
            var isBold: Bool
            var isItalic: Bool
            var isUnderlined: Bool
        }

        var currentSegment: StyledSegment?

        func flushSegment(_ seg: StyledSegment) {
            var part = AttributedString(seg.text)
            part.foregroundColor = Color(
                red: Double(seg.fg.r) / 255.0,
                green: Double(seg.fg.g) / 255.0,
                blue: Double(seg.fg.b) / 255.0
            )
            if seg.hasCustomBG {
                part.backgroundColor = Color(
                    red: Double(seg.bg.r) / 255.0,
                    green: Double(seg.bg.g) / 255.0,
                    blue: Double(seg.bg.b) / 255.0
                )
            }
            if seg.isBold && seg.isItalic {
                part.font = .system(size: 9.5, weight: .bold, design: .monospaced).italic()
            } else if seg.isBold {
                part.font = .system(size: 9.5, weight: .bold, design: .monospaced)
            } else if seg.isItalic {
                part.font = .system(size: 9.5, weight: .regular, design: .monospaced).italic()
            }
            if seg.isUnderlined {
                part.underlineStyle = .single
            }
            output.append(part)
        }

        for colIdx in 0...lastCol {
            let cell = cells[colIdx]
            let isCursorCell = isCursorRow && (colIdx == cursorColumn)
            let resolved = palette.resolveCellColors(
                for: cell,
                isCursorCell: isCursorCell,
                cursorShape: cursorShape
            )
            let customBG = (resolved.background != defaultBG) || isCursorCell
            let bold = cell.attributes.contains(.bold)
            let italic = cell.attributes.contains(.italic)
            let underline = cell.attributes.contains(.underline)
            let glyph = (isCursorCell && cell.grapheme == " ") ? "▋" : cell.grapheme

            if var active = currentSegment,
               active.fg == resolved.foreground,
               active.bg == resolved.background,
               active.hasCustomBG == customBG,
               active.isBold == bold,
               active.isItalic == italic,
               active.isUnderlined == underline {
                active.text.append(glyph)
                currentSegment = active
            } else {
                if let active = currentSegment {
                    flushSegment(active)
                }
                currentSegment = StyledSegment(
                    text: glyph,
                    fg: resolved.foreground,
                    bg: resolved.background,
                    hasCustomBG: customBG,
                    isBold: bold,
                    isItalic: italic,
                    isUnderlined: underline
                )
            }
        }

        if let active = currentSegment {
            flushSegment(active)
        }

        if isCursorRow && cursorColumn > lastCol {
            var cursorTail = AttributedString(" ▋")
            cursorTail.foregroundColor = vendorAccent
            output.append(cursorTail)
        }

        return output
    }
}

// MARK: - Right-Hand Critical-Path DAG & .relay Handoff Ledger Inspector

public struct PTYCriticalPathAndHandoffInspector: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cpmSummaryHeaderCard
            criticalPathNodeListCard
            relayHandoffLedgerCard
        }
    }

    private var cpmSummaryHeaderCard: some View {
        let speedup = viewModel.cpmSchedule.speedup
        return RelayBauhausCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("CRITICAL-PATH DAG")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.75)
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    Button {
                        viewModel.selectPane(.dagPipeline)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Canvas")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.codexCobalt)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SPEEDUP")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        Text(String(format: "%.2f×", speedup.theoreticalSpeedupFactor))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(RelayBauhausDesign.agySignalGreen)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MAKESPAN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        Text(String(format: "%.0fs / %.0fs", speedup.parallelMakespanSeconds, speedup.serialDurationSeconds))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var criticalPathNodeListCard: some View {
        RelayBauhausCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                RelaySectionEyebrow(
                    "Wave & CPM Slack",
                    trailingText: "\(viewModel.cpmSchedule.criticalPathTaskIDs.count) crit"
                )

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(viewModel.cpmSchedule.nodeSchedules) { node in
                            cpmCompactRow(node)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private func cpmCompactRow(_ node: CPMNodeScheduleMetrics) -> some View {
        let vendorColor = RelayBauhausDesign.vendorColor(node.vendor)
        let isCrit = node.isOnCriticalPath
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("W\(node.topologicalWaveIndex)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(RelayBauhausDesign.sandstoneStrip)
                    )
                    .fixedSize(horizontal: true, vertical: false)

                Text(RelayBauhausDesign.vendorShortTag(node.vendor))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(vendorColor)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Text(isCrit
                     ? "CRIT 0s"
                     : String(format: "+%.0fs slack", node.totalSlackSeconds))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isCrit ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(node.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(String(format: "ES %.0fs → EF %.0fs", node.earliestStartSeconds, node.earliestFinishSeconds))
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                Spacer(minLength: 2)
                Text(node.status.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusInk(for: node.status))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(isCrit ? RelayBauhausDesign.vermilionWash.opacity(0.6) : RelayBauhausDesign.sandstoneStrip.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(isCrit ? RelayBauhausDesign.claudeVermilion.opacity(0.45) : RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private var relayHandoffLedgerCard: some View {
        let artifacts = collectHandoffContracts()
        return RelayBauhausCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                RelaySectionEyebrow(".relay Handoff Ledger", trailingText: "\(artifacts.count) files")

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(artifacts) { item in
                            VStack(alignment: .leading, spacing: 2.5) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(RelayBauhausDesign.vendorColor(item.producerVendor))
                                        .frame(width: 6, height: 6)
                                    Text(item.shortFileName)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 2)
                                    Text("sha:\(item.sha256Prefix)")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                Text("\(RelayBauhausDesign.vendorShortTag(item.producerVendor)) → \(item.consumerLabel)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(5.5)
                            .background(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private struct HandoffLedgerRow: Identifiable {
        let id: String
        let shortFileName: String
        let producerVendor: AgentVendor
        let consumerLabel: String
        let sha256Prefix: String
    }

    private func collectHandoffContracts() -> [HandoffLedgerRow] {
        var rows: [HandoffLedgerRow] = []
        for task in viewModel.dagSpec.tasks {
            for outPath in task.outputHandoffFiles {
                let consumers = viewModel.dagSpec.tasks
                    .filter { $0.inputHandoffFiles.contains(outPath) }
                    .map { RelayBauhausDesign.vendorShortTag($0.vendor) }
                let consumerText = consumers.isEmpty ? "Release Bundle" : consumers.joined(separator: ", ")
                let digest = SHA256.hash(data: Data("\(task.id):\(outPath)".utf8))
                let prefix = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
                let shortName = (outPath as NSString).lastPathComponent
                rows.append(
                    HandoffLedgerRow(
                        id: "\(task.id)->\(outPath)",
                        shortFileName: shortName,
                        producerVendor: task.vendor,
                        consumerLabel: consumerText,
                        sha256Prefix: prefix
                    )
                )
            }
        }
        return rows
    }

    private func statusInk(for status: RelayTaskStatus) -> Color {
        switch status {
        case .completed:
            return RelayBauhausDesign.agySignalGreen
        case .running, .verifyingGate:
            return RelayBauhausDesign.codexCobalt
        case .failed, .haltedByBudget:
            return RelayBauhausDesign.claudeVermilion
        case .pending, .blockedOnDeps, .cancelled:
            return RelayBauhausDesign.vibeOchre
        }
    }
}

// MARK: - 2. Full-Bleed Topological Wave & Critical Path DAG Pipeline Canvas

public struct RelayDAGPipelineCanvasView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            dagHeaderMetricsStrip

            HStack(alignment: .top, spacing: 10) {
                dagTopologicalSwimlaneCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                dagSelectedTaskInspector
                    .frame(width: 306)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(10)
        .background(RelayBauhausDesign.warmSandpaper)
    }

    // MARK: - Top Metrics Banner

    private var dagHeaderMetricsStrip: some View {
        let speedup = viewModel.cpmSchedule.speedup
        return HStack(spacing: 10) {
            RelayBauhausPill(
                String(format: "Parallel Speedup %.2f×", speedup.theoreticalSpeedupFactor),
                foreground: RelayBauhausDesign.agySignalGreen,
                background: RelayBauhausDesign.greenWash,
                border: RelayBauhausDesign.agySignalGreen.opacity(0.45),
                symbolName: "bolt.fill",
                monospaced: true
            )

            RelayBauhausPill(
                String(format: "Makespan %.0fs (Serial %.0fs)", speedup.parallelMakespanSeconds, speedup.serialDurationSeconds),
                foreground: RelayBauhausDesign.espressoInk,
                background: RelayBauhausDesign.warmIvory,
                border: RelayBauhausDesign.hairlineBorder,
                symbolName: "clock",
                monospaced: true
            )

            RelayBauhausPill(
                "Critical Path: \(viewModel.cpmSchedule.criticalPathTaskIDs.count) Nodes",
                foreground: RelayBauhausDesign.claudeVermilion,
                background: RelayBauhausDesign.vermilionWash,
                border: RelayBauhausDesign.claudeVermilion.opacity(0.45),
                symbolName: "point.topleft.down.curvedto.point.bottomright.up",
                monospaced: true
            )

            Spacer(minLength: 6)

            Toggle(isOn: $viewModel.highlightCriticalPathOnly) {
                Text("Isolate Critical Path")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .toggleStyle(.checkbox)

            Button {
                viewModel.selectPane(.ptyGrid)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .bold))
                    Text("Inspect PTY Grid")
                        .font(.system(size: 11, weight: .semibold))
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
                        .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - Interactive Topological Wave & Bezier CPM Canvas

    private var dagTopologicalSwimlaneCanvas: some View {
        GeometryReader { geo in
            let layout = computeDAGCardPositions(in: geo.size)

            ZStack(alignment: .topLeading) {
                // Drafting background + Bezier dependency edges on SwiftUI.Canvas
                Canvas { context, size in
                    drawArchitecturalGrid(in: &context, size: size)
                    drawWaveColumnHeaders(in: &context, size: size, maxWave: layout.maxWave)
                    drawBezierDependencyEdges(in: &context, layout: layout)
                }

                // Interactive Positioned Task Cards
                ForEach(layout.positionedNodes) { item in
                    dagTaskNodeCard(item)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                    .fill(RelayBauhausDesign.warmIvory)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                    .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )
        }
    }

    private struct PositionedDAGNode: Identifiable {
        let id: String
        let task: RelayTaskNode
        let schedule: CPMNodeScheduleMetrics
        let frame: CGRect
        let sha256ContractHex: String
    }

    private struct DAGCanvasLayout {
        let maxWave: Int
        let positionedNodes: [PositionedDAGNode]
        let framesByTaskID: [String: CGRect]
        let criticalSet: Set<String>
    }

    private func computeDAGCardPositions(in canvasSize: CGSize) -> DAGCanvasLayout {
        let schedules = viewModel.cpmSchedule.nodeSchedules
        let scheduleByID = Dictionary(uniqueKeysWithValues: schedules.map { ($0.taskID, $0) })
        let maxWave = max(0, schedules.map(\.topologicalWaveIndex).max() ?? 2)
        let waveCount = maxWave + 1

        let horizontalPad: CGFloat = 22
        let topHeaderHeight: CGFloat = 44
        let usableWidth = max(480, canvasSize.width - horizontalPad * 2)
        let usableHeight = max(360, canvasSize.height - topHeaderHeight - 18)

        let colSpacing: CGFloat = 34
        let cardWidth = min(236, max(176, (usableWidth - CGFloat(max(0, waveCount - 1)) * colSpacing) / CGFloat(max(1, waveCount))))
        let cardHeight: CGFloat = 148

        var tasksByWave: [Int: [RelayTaskNode]] = [:]
        for task in viewModel.dagSpec.tasks {
            let w = scheduleByID[task.id]?.topologicalWaveIndex ?? 0
            tasksByWave[w, default: []].append(task)
        }

        var positioned: [PositionedDAGNode] = []
        var frameMap: [String: CGRect] = [:]

        for wave in 0...maxWave {
            let waveTasks = tasksByWave[wave] ?? []
            guard !waveTasks.isEmpty else { continue }

            let stepX = waveCount > 1
                ? (usableWidth - cardWidth) / CGFloat(waveCount - 1)
                : 0
            let originX = horizontalPad + CGFloat(wave) * stepX

            let totalCardsHeight = CGFloat(waveTasks.count) * cardHeight
            let verticalGap = max(14, (usableHeight - totalCardsHeight) / CGFloat(waveTasks.count + 1))

            for (rowIdx, task) in waveTasks.enumerated() {
                let originY = topHeaderHeight + verticalGap + CGFloat(rowIdx) * (cardHeight + verticalGap)
                let rect = CGRect(x: originX, y: originY, width: cardWidth, height: cardHeight)
                frameMap[task.id] = rect

                let sched = scheduleByID[task.id] ?? CPMNodeScheduleMetrics(
                    taskID: task.id,
                    title: task.title,
                    vendor: task.vendor,
                    laneID: task.laneID,
                    status: task.status,
                    topologicalWaveIndex: wave,
                    durationSeconds: 30,
                    earliestStartSeconds: 0,
                    earliestFinishSeconds: 30,
                    latestStartSeconds: 0,
                    latestFinishSeconds: 30,
                    totalSlackSeconds: 0,
                    freeSlackSeconds: 0,
                    isOnCriticalPath: false
                )

                let contractSeed = ([task.id] + task.outputHandoffFiles).joined(separator: "|")
                let digest = SHA256.hash(data: Data(contractSeed.utf8))
                let shaPrefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()

                positioned.append(
                    PositionedDAGNode(
                        id: task.id,
                        task: task,
                        schedule: sched,
                        frame: rect,
                        sha256ContractHex: shaPrefix
                    )
                )
            }
        }

        return DAGCanvasLayout(
            maxWave: maxWave,
            positionedNodes: positioned,
            framesByTaskID: frameMap,
            criticalSet: Set(viewModel.cpmSchedule.criticalPathTaskIDs)
        )
    }

    private func drawArchitecturalGrid(in context: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 24
        var gridPath = Path()
        var x: CGFloat = spacing
        while x < size.width {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            x += spacing
        }
        var y: CGFloat = spacing
        while y < size.height {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        context.stroke(gridPath, with: .color(RelayBauhausDesign.sandstoneStrip.opacity(0.75)), lineWidth: 0.6)
    }

    private func drawWaveColumnHeaders(in context: inout GraphicsContext, size: CGSize, maxWave: Int) {
        let waveCount = maxWave + 1
        guard waveCount > 0 else { return }
        let colWidth = size.width / CGFloat(waveCount)

        for w in 0...maxWave {
            let centerX = CGFloat(w) * colWidth + colWidth * 0.5
            let label = Text("WAVE \(w) · TOPOLOGICAL STAGE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RelayBauhausDesign.mutedStoneInk)
            context.draw(label, at: CGPoint(x: centerX, y: 20), anchor: .center)
        }
    }

    private func drawBezierDependencyEdges(in context: inout GraphicsContext, layout: DAGCanvasLayout) {
        for item in layout.positionedNodes {
            for depID in item.task.dependsOnTaskIDs {
                guard let fromRect = layout.framesByTaskID[depID] else { continue }
                let toRect = item.frame
                let isCriticalEdge = layout.criticalSet.contains(depID) && layout.criticalSet.contains(item.id)

                if viewModel.highlightCriticalPathOnly && !isCriticalEdge {
                    continue
                }

                let p0 = CGPoint(x: fromRect.maxX, y: fromRect.midY)
                let p3 = CGPoint(x: toRect.minX, y: toRect.midY)
                let ctrlOffset = max(24, (p3.x - p0.x) * 0.48)
                let c1 = CGPoint(x: p0.x + ctrlOffset, y: p0.y)
                let c2 = CGPoint(x: p3.x - ctrlOffset, y: p3.y)

                var curve = Path()
                curve.move(to: p0)
                curve.addCurve(to: p3, control1: c1, control2: c2)

                let edgeColor = isCriticalEdge
                    ? RelayBauhausDesign.claudeVermilion
                    : RelayBauhausDesign.structuralBorder

                if isCriticalEdge {
                    context.stroke(curve, with: .color(edgeColor), lineWidth: 2.3)
                } else {
                    context.stroke(
                        curve,
                        with: .color(edgeColor),
                        style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])
                    )
                }

                // Directional arrowhead at p3
                var arrow = Path()
                arrow.move(to: p3)
                arrow.addLine(to: CGPoint(x: p3.x - 7, y: p3.y - 4))
                arrow.addLine(to: CGPoint(x: p3.x - 7, y: p3.y + 4))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(edgeColor))
            }
        }
    }

    private func dagTaskNodeCard(_ item: PositionedDAGNode) -> some View {
        let isSelected = (viewModel.selectedDAGTaskID == item.id)
        let isCrit = item.schedule.isOnCriticalPath
        let dimmed = viewModel.highlightCriticalPathOnly && !isCrit
        let vendorAccent = RelayBauhausDesign.vendorColor(item.task.vendor)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                RelayVendorBadge(vendor: item.task.vendor, compact: true)
                Text("W\(item.schedule.topologicalWaveIndex)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                Text(isCrit ? "CRIT" : String(format: "+%.0fs", item.schedule.totalSlackSeconds))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isCrit ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.mutedStoneInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isCrit ? RelayBauhausDesign.vermilionWash : RelayBauhausDesign.sandstoneStrip)
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(item.task.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(String(format: "ES %.0fs · EF %.0fs", item.schedule.earliestStartSeconds, item.schedule.earliestFinishSeconds))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                Spacer(minLength: 2)
                Text(String(format: "LS %.0fs", item.schedule.latestStartSeconds))
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
            }

            Spacer(minLength: 2)

            Divider()
                .overlay(RelayBauhausDesign.hairlineBorder)

            HStack(spacing: 5) {
                Image(systemName: item.task.status == .completed ? "checkmark.seal.fill" : "clock.badge.checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(item.task.status == .completed ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.vibeOchre)
                Text(item.task.status.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                Text(".relay #\(item.sha256ContractHex)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.warmIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? vendorAccent : (isCrit ? RelayBauhausDesign.claudeVermilion.opacity(0.65) : RelayBauhausDesign.hairlineBorder),
                    lineWidth: isSelected ? 2.0 : 1.0
                )
        )
        .opacity(dimmed ? 0.35 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedDAGTaskID = item.id
        }
    }

    // MARK: - Selected DAG Task & Verification Gate Inspector

    private var dagSelectedTaskInspector: some View {
        let task = viewModel.dagSpec.tasks.first(where: { $0.id == viewModel.selectedDAGTaskID })
            ?? viewModel.dagSpec.tasks.first
        let sched = viewModel.cpmSchedule.nodeSchedules.first(where: { $0.taskID == task?.id })

        return RelayBauhausCard(padding: 11) {
            if let task {
                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            RelayVendorBadge(vendor: task.vendor)
                            Spacer()
                            RelayBauhausPill(
                                task.status.rawValue,
                                foreground: RelayBauhausDesign.espressoInk,
                                background: RelayBauhausDesign.sandstoneStrip,
                                border: RelayBauhausDesign.hairlineBorder,
                                monospaced: true
                            )
                        }

                        Text(task.title)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Node ID: \(task.id) · Lane: \(task.laneID)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)

                        if let sched {
                            VStack(alignment: .leading, spacing: 5) {
                                RelaySectionEyebrow("CPM Schedule Window", trailingText: sched.isOnCriticalPath ? "CRITICAL" : "FLOAT")
                                HStack(spacing: 8) {
                                    metricBox(label: "ES → EF", value: String(format: "%.0fs → %.0fs", sched.earliestStartSeconds, sched.earliestFinishSeconds))
                                    metricBox(label: "LS → LF", value: String(format: "%.0fs → %.0fs", sched.latestStartSeconds, sched.latestFinishSeconds))
                                    metricBox(label: "SLACK", value: String(format: "%.1fs", sched.totalSlackSeconds))
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            RelaySectionEyebrow("Agent Assignment Brief")
                            Text(task.promptBrief)
                                .font(.system(size: 11))
                                .foregroundStyle(RelayBauhausDesign.graphiteInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                        .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.55))
                                )
                        }

                        if let cmd = task.verificationShellCommand {
                            VStack(alignment: .leading, spacing: 4) {
                                RelaySectionEyebrow("Verification Shell Gate")
                                Text("$ \(cmd)")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RelayBauhausDesign.carbonPrimaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                            .fill(RelayBauhausDesign.carbonMatteWell)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                            .strokeBorder(RelayBauhausDesign.carbonInsetBorder, lineWidth: 1)
                                    )
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            RelaySectionEyebrow(".relay Artifact Contracts")
                            ForEach(task.inputHandoffFiles, id: \.self) { inFile in
                                Text("IN  ← \(inFile)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RelayBauhausDesign.codexCobalt)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(task.outputHandoffFiles, id: \.self) { outFile in
                                Text("OUT → \(outFile)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RelayBauhausDesign.agySignalGreen)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                Text("Select a DAG task card to inspect CPM slack and verification contracts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
            }
        }
    }

    private func metricBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
            Text(value)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.65))
        )
    }
}
