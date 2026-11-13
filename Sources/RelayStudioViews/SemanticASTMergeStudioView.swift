import Foundation
import RelayModels
import RelaySemanticMerge
import RelayWorkbenchShell
import SwiftUI

// MARK: - 3-Pane Declaration-Level Semantic AST Merge Studio

public struct SemanticASTMergeStudioView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let activeReport = viewModel.activeMergeReport

        VStack(spacing: 8) {
            fileSwitcherAndSummaryBanner(report: activeReport)

            if let report = activeReport {
                threePaneDeclarationComparisonGrid(report: report)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                crossFileArityDiagnosticsStrip(report: report)
            } else {
                RelayBauhausCard(padding: 20) {
                    Text(viewModel.L(
                        "No 3-Way Semantic AST merge reports loaded in this workspace.",
                        "当前工作区尚未加载三路 AST 语义合并报告。"
                    ))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(10)
        .background(RelayBauhausDesign.warmSandpaper)
    }

    // MARK: - Top File Switcher & Merge Summary Metrics Banner

    private func fileSwitcherAndSummaryBanner(report: ThreeWaySemanticMergeReport?) -> some View {
        let autoCount = report?.autoMergedCount ?? 0
        let conflictCount = report?.unresolvedConflictCount ?? 0
        let arityCount = max(
            report?.crossFileCollisions.count ?? 0,
            viewModel.callSiteDiagnostics.count
        )

        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                // File Tabs (AuthSessionManager.swift + HTTP3ZeroCopyRing.swift)
                HStack(spacing: 5) {
                    ForEach(viewModel.mergeReports) { item in
                        let isSelected = (item.relativePath == viewModel.selectedMergeFilePath)
                        let shortFile = (item.relativePath as NSString).lastPathComponent
                        let hasConflict = item.unresolvedConflictCount > 0

                        Button {
                            viewModel.selectedMergeFilePath = item.relativePath
                            viewModel.selectedMergeChunkID = item.chunks.first(where: { $0.resolution.isConflict })?.id
                                ?? item.chunks.first?.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: hasConflict ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(
                                        isSelected
                                            ? (hasConflict ? Color(relayHex: "#FCA5A5") : Color(relayHex: "#86EFAC"))
                                            : (hasConflict ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen)
                                    )

                                Text(shortFile)
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))

                                Text(hasConflict
                                     ? viewModel.L("\(item.unresolvedConflictCount) conflict", "\(item.unresolvedConflictCount) 处冲突")
                                     : viewModel.L("\(item.autoMergedCount) clean", "\(item.autoMergedCount) 项无冲突"))
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .monospacedDigit()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(
                                                isSelected
                                                    ? Color.white.opacity(0.16)
                                                    : (hasConflict ? RelayBauhausDesign.vermilionWash : RelayBauhausDesign.greenWash)
                                            )
                                    )
                            }
                            .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
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

                Spacer(minLength: 6)

                if let report, report.wouldGitLineMergeConflict && report.isCleanlyMerged {
                    RelayBauhausPill(
                        viewModel.L(
                            "Git Line-Diff Would Conflict · AST Auto-Resolved",
                            "Git 行级合并原本冲突 · AST 已自动消解"
                        ),
                        foreground: RelayBauhausDesign.agySignalGreen,
                        background: RelayBauhausDesign.greenWash,
                        border: RelayBauhausDesign.agySignalGreen.opacity(0.45),
                        symbolName: "sparkles.rectangle.stack",
                        monospaced: false
                    )
                } else if conflictCount > 0 {
                    Button {
                        viewModel.resolveAllConflictsInSelectedFile(strategy: .preferVerifiedTestPassingLane)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.rays")
                                .font(.system(size: 10.5, weight: .bold))
                            Text(viewModel.L("Resolve All via Verified Lane", "通过已验证通道一键裁决"))
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(RelayBauhausDesign.warmIvory)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(
                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                .fill(RelayBauhausDesign.claudeVermilion)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Summary KPI Row
            HStack(spacing: 8) {
                mergeBannerKPICard(
                    title: viewModel.L("Auto-Merged Declarations", "自动合并声明"),
                    value: "\(autoCount)",
                    detail: viewModel.L("Disjoint functions, imports & members", "离散函数、导入集合与类型成员"),
                    accent: RelayBauhausDesign.agySignalGreen,
                    wash: RelayBauhausDesign.greenWash,
                    icon: "checkmark.circle.fill"
                )

                mergeBannerKPICard(
                    title: viewModel.L("True Intra-Function Conflicts", "函数内真实冲突"),
                    value: "\(conflictCount)",
                    detail: conflictCount > 0
                        ? viewModel.L("Same AST symbol body diverged", "同一 AST 符号函数体发生分叉")
                        : viewModel.L("All AST symbols reconciled", "全部 AST 符号已调解一致"),
                    accent: conflictCount > 0 ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen,
                    wash: conflictCount > 0 ? RelayBauhausDesign.vermilionWash : RelayBauhausDesign.greenWash,
                    icon: conflictCount > 0 ? "bolt.trianglebadge.exclamationmark.fill" : "checkmark.shield.fill"
                )

                mergeBannerKPICard(
                    title: viewModel.L("Call-Site Arity Checks", "跨文件调用签名检查"),
                    value: viewModel.L("\(arityCount) flagged", "\(arityCount) 处标记"),
                    detail: arityCount > 0
                        ? viewModel.L("Cross-worktree signature drift audited", "已审计跨工作树函数签名漂移")
                        : viewModel.L("0 broken call sites across lanes", "跨通道 0 处损坏调用点"),
                    accent: arityCount > 0 ? RelayBauhausDesign.vibeOchre : RelayBauhausDesign.codexCobalt,
                    wash: arityCount > 0 ? RelayBauhausDesign.ochreWash : RelayBauhausDesign.cobaltWash,
                    icon: "link.badge.plus"
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private func mergeBannerKPICard(
        title: String,
        value: String,
        detail: String,
        accent: Color,
        wash: Color,
        icon: String
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .fill(wash)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.warmIvory)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - 3-Pane Declaration AST Merge Columns

    private func threePaneDeclarationComparisonGrid(report: ThreeWaySemanticMergeReport) -> some View {
        let orderedChunks = prioritizedMergeChunks(report.chunks)
        return HStack(alignment: .top, spacing: 8) {
            // Left Worktree Column: Claude Code
            worktreeSidePaneColumn(
                headerTitle: viewModel.L("Left Worktree · Claude Code", "左侧工作树 · Claude Code"),
                laneID: report.leftLaneID,
                vendor: .claudeCode,
                chunks: orderedChunks,
                isLeftSide: true
            )

            // Center Reconciled Output Column: Merged Semantic AST Output
            mergedSemanticCenterColumn(report: report, orderedChunks: orderedChunks)

            // Right Worktree Column: OpenAI Codex
            worktreeSidePaneColumn(
                headerTitle: viewModel.L("Right Worktree · OpenAI Codex", "右侧工作树 · OpenAI Codex"),
                laneID: report.rightLaneID,
                vendor: .codex,
                chunks: orderedChunks,
                isLeftSide: false
            )
        }
    }

    private func prioritizedMergeChunks(_ chunks: [SemanticMergeChunk]) -> [SemanticMergeChunk] {
        chunks.enumerated().sorted { lhs, rhs in
            let rankL = chunkPriorityRank(lhs.element)
            let rankR = chunkPriorityRank(rhs.element)
            if rankL != rankR { return rankL < rankR }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func chunkPriorityRank(_ chunk: SemanticMergeChunk) -> Int {
        if chunk.resolution.isConflict { return 0 }
        if chunk.resolution != .unchanged { return 1 }
        return 2
    }

    private func worktreeSidePaneColumn(
        headerTitle: String,
        laneID: String,
        vendor: AgentVendor,
        chunks: [SemanticMergeChunk],
        isLeftSide: Bool
    ) -> some View {
        let vendorAccent = RelayBauhausDesign.vendorColor(vendor)

        return VStack(alignment: .leading, spacing: 0) {
            // Column Header Strip
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(vendorAccent)
                    .frame(width: 4, height: 14)

                Text(headerTitle)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Text(laneID)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(vendorAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(RelayBauhausDesign.vendorWashColor(vendor))
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RelayBauhausDesign.sandstoneStrip)

            Rectangle()
                .fill(RelayBauhausDesign.hairlineBorder)
                .frame(height: 1)

            RelayAdaptiveScrollContainer {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chunks) { chunk in
                        sideDeclarationChunkCard(chunk: chunk, isLeftSide: isLeftSide, vendor: vendor)
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.warmIvory)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private func sideDeclarationChunkCard(
        chunk: SemanticMergeChunk,
        isLeftSide: Bool,
        vendor: AgentVendor
    ) -> some View {
        let rawCode = isLeftSide ? chunk.leftSource : chunk.rightSource
        let isConflict = chunk.resolution.isConflict
        let isSelected = (viewModel.selectedMergeChunkID == chunk.id)
        let statusTag = sideChunkStatusTag(chunk: chunk, isLeftSide: isLeftSide)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(viewModel.currentLanguage.isChinese
                     ? chunk.kind.localizedLabel(in: .zhHans)
                     : chunk.kind.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)

                Text(viewModel.T(chunk.symbolName))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Text(statusTag.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusTag.fg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(statusTag.bg)
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let source = rawCode, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RecessedASTCodeSnippetWell(sourceCode: source, maxLines: 7, language: viewModel.currentLanguage)
            } else {
                Text(viewModel.L(
                    "// Declaration not present in \(RelayBauhausDesign.vendorStudioName(vendor, language: .en)) worktree",
                    "// 该声明未出现在 \(RelayBauhausDesign.vendorStudioName(vendor, language: .zhHans)) 工作树"
                ))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.55))
                )
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(isConflict ? RelayBauhausDesign.vermilionWash.opacity(0.42) : RelayBauhausDesign.sandstoneStrip.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? RelayBauhausDesign.vendorColor(vendor)
                        : (isConflict ? RelayBauhausDesign.claudeVermilion.opacity(0.55) : RelayBauhausDesign.hairlineBorder),
                    lineWidth: isSelected ? 1.5 : 1.0
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedMergeChunkID = chunk.id
        }
    }

    private func sideChunkStatusTag(
        chunk: SemanticMergeChunk,
        isLeftSide: Bool
    ) -> (label: String, fg: Color, bg: Color) {
        if chunk.resolution.isConflict {
            return (viewModel.L("DIVERGED", "已分叉"), RelayBauhausDesign.claudeVermilion, RelayBauhausDesign.vermilionWash)
        }
        switch chunk.resolution {
        case .leftAddedDeclaration:
            return isLeftSide
                ? (viewModel.L("ADDED", "新增"), RelayBauhausDesign.agySignalGreen, RelayBauhausDesign.greenWash)
                : (viewModel.L("ABSENT", "未包含"), RelayBauhausDesign.mutedStoneInk, RelayBauhausDesign.sandstoneStrip)
        case .rightAddedDeclaration:
            return isLeftSide
                ? (viewModel.L("ABSENT", "未包含"), RelayBauhausDesign.mutedStoneInk, RelayBauhausDesign.sandstoneStrip)
                : (viewModel.L("ADDED", "新增"), RelayBauhausDesign.agySignalGreen, RelayBauhausDesign.greenWash)
        case .leftModifiedOnly:
            return isLeftSide
                ? (viewModel.L("MODIFIED", "已修改"), RelayBauhausDesign.claudeVermilion, RelayBauhausDesign.vermilionWash)
                : (viewModel.L("BASE", "基线"), RelayBauhausDesign.mutedStoneInk, RelayBauhausDesign.sandstoneStrip)
        case .rightModifiedOnly:
            return isLeftSide
                ? (viewModel.L("BASE", "基线"), RelayBauhausDesign.mutedStoneInk, RelayBauhausDesign.sandstoneStrip)
                : (viewModel.L("MODIFIED", "已修改"), RelayBauhausDesign.codexCobalt, RelayBauhausDesign.cobaltWash)
        case .autoMergedImportSetUnion:
            return (viewModel.L("IMPORT UNION", "导入并集"), RelayBauhausDesign.agySignalGreen, RelayBauhausDesign.greenWash)
        default:
            return (viewModel.L("SYNCED", "已同步"), RelayBauhausDesign.agySignalGreen, RelayBauhausDesign.greenWash)
        }
    }

    // MARK: - Center Column: Merged Semantic AST Output + One-Click Conflict Resolver

    private func mergedSemanticCenterColumn(
        report: ThreeWaySemanticMergeReport,
        orderedChunks: [SemanticMergeChunk]
    ) -> some View {
        let cleanState = report.unresolvedConflictCount == 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(cleanState ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.claudeVermilion)
                    .frame(width: 4, height: 14)

                Text(viewModel.L("Merged Semantic AST Output", "三路 AST 语义合并输出"))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Text(cleanState
                     ? viewModel.L("READY TO COMMIT", "可安全提交")
                     : viewModel.L("\(report.unresolvedConflictCount) CONFLICT", "\(report.unresolvedConflictCount) 处冲突"))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(cleanState ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.claudeVermilion)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(cleanState ? RelayBauhausDesign.greenWash : RelayBauhausDesign.vermilionWash)
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RelayBauhausDesign.sandstoneStrip)

            Rectangle()
                .fill(RelayBauhausDesign.hairlineBorder)
                .frame(height: 1)

            RelayAdaptiveScrollContainer {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(orderedChunks) { chunk in
                        mergedDeclarationCard(chunk: chunk)
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.warmIvory)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(
                    cleanState ? RelayBauhausDesign.agySignalGreen.opacity(0.55) : RelayBauhausDesign.claudeVermilion.opacity(0.65),
                    lineWidth: 1.25
                )
        )
    }

    private func mergedDeclarationCard(chunk: SemanticMergeChunk) -> some View {
        let isConflict = chunk.resolution.isConflict
        let isUnchanged = (chunk.resolution == .unchanged)
        let badgeLabel = isConflict
            ? viewModel.L("INTRA-FUNCTION CONFLICT", "函数内语义冲突")
            : (isUnchanged
                ? viewModel.L("UNCHANGED BASE", "无变更基线")
                : viewModel.L("CLEAN AUTO-MERGE", "无冲突自动合并"))
        let badgeColor = isConflict
            ? RelayBauhausDesign.claudeVermilion
            : (isUnchanged ? RelayBauhausDesign.graphiteInk : RelayBauhausDesign.agySignalGreen)
        let badgeWash = isConflict
            ? RelayBauhausDesign.vermilionWash
            : (isUnchanged ? RelayBauhausDesign.sandstoneStrip : RelayBauhausDesign.greenWash)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: isConflict ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(badgeLabel)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(badgeWash)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(badgeColor.opacity(0.45), lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Text(viewModel.T(chunk.symbolName))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(viewModel.T(chunk.explanation))
                .font(.system(size: 10))
                .foregroundStyle(RelayBauhausDesign.graphiteInk)
                .fixedSize(horizontal: false, vertical: true)

            RecessedASTCodeSnippetWell(
                sourceCode: chunk.resolvedSource,
                maxLines: isConflict ? 7 : 6,
                language: viewModel.currentLanguage
            )

            if isConflict {
                conflictStrategyActionRow(chunkID: chunk.id)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(isConflict ? RelayBauhausDesign.vermilionWash.opacity(0.55) : RelayBauhausDesign.greenWash.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(badgeColor.opacity(isConflict ? 0.75 : 0.4), lineWidth: isConflict ? 1.5 : 1.0)
        )
        .onTapGesture {
            viewModel.selectedMergeChunkID = chunk.id
        }
    }

    private func conflictStrategyActionRow(chunkID: UUID) -> some View {
        let isZh = viewModel.currentLanguage.isChinese
        return VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.L("ONE-CLICK AST RESOLUTION STRATEGY", "一键 AST 语义冲突裁决策略"))
                .font(.system(size: 9, weight: .bold))
                .tracking(isZh ? 0 : 0.6)
                .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 5) {
                strategyButton(
                    label: viewModel.L("Accept Left", "采纳左侧"),
                    accent: RelayBauhausDesign.claudeVermilion,
                    chunkID: chunkID,
                    strategy: .acceptLeft
                )
                strategyButton(
                    label: viewModel.L("Accept Right", "采纳右侧"),
                    accent: RelayBauhausDesign.codexCobalt,
                    chunkID: chunkID,
                    strategy: .acceptRight
                )
                strategyButton(
                    label: viewModel.L("Accept Both", "双侧合并"),
                    accent: RelayBauhausDesign.espressoInk,
                    chunkID: chunkID,
                    strategy: .acceptBothOrdered
                )
            }

            Button {
                viewModel.resolveConflictChunk(chunkID: chunkID, strategy: .preferVerifiedTestPassingLane)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(viewModel.L(
                        "Prefer Verified Lane (18/18 Tests + 0 Fence Violations)",
                        "优先采纳验证通过通道 (18/18 测试通过 + 0 越界)"
                    ))
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(RelayBauhausDesign.warmIvory)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.agySignalGreen)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func strategyButton(
        label: String,
        accent: Color,
        chunkID: UUID,
        strategy: ConflictResolutionStrategy
    ) -> some View {
        Button {
            viewModel.resolveConflictChunk(chunkID: chunkID, strategy: strategy)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4.5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.warmIvory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .strokeBorder(accent.opacity(0.65), lineWidth: 1)
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Cross-File Broken Call-Site Arity Check Strip

    private func crossFileArityDiagnosticsStrip(report: ThreeWaySemanticMergeReport) -> some View {
        let collisions: [CrossFileSignatureCollision] = {
            if !report.crossFileCollisions.isEmpty {
                return report.crossFileCollisions
            }
            return viewModel.callSiteDiagnostics
                .filter { $0.declarationFile == report.relativePath }
                .map { $0.asCrossFileSignatureCollision() }
        }()

        return RelayBauhausCard(
            padding: 8,
            fill: collisions.isEmpty ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.ochreWash,
            borderColor: collisions.isEmpty ? RelayBauhausDesign.hairlineBorder : RelayBauhausDesign.vibeOchre.opacity(0.65)
        ) {
            HStack(alignment: .center, spacing: 10) {
                RelayBauhausPill(
                    viewModel.L("CrossFileBrokenCallSiteDetector", "跨文件调用签名检测器"),
                    foreground: collisions.isEmpty ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.vibeOchre,
                    background: RelayBauhausDesign.warmIvory,
                    border: collisions.isEmpty ? RelayBauhausDesign.agySignalGreen.opacity(0.5) : RelayBauhausDesign.vibeOchre.opacity(0.6),
                    symbolName: collisions.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                    monospaced: true
                )

                if let first = collisions.first {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("\(first.callerFile):\(first.callerLine)")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(RelayBauhausDesign.espressoInk)
                                .fixedSize(horizontal: true, vertical: false)

                            Text(viewModel.L(
                                "Symbol `\(first.symbolName)` altered by `\(first.modifiedByLane)` while `\(first.callerLane)` calls stale arity",
                                "符号 `\(first.symbolName)` 被 `\(first.modifiedByLane)` 修改，而 `\(first.callerLane)` 仍调用旧参数签名"
                            ))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(viewModel.L(
                            "Old: \(first.oldSignature)   →   New: \(first.newSignature)",
                            "旧签名: \(first.oldSignature)   →   新签名: \(first.newSignature)"
                        ))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    RelayBauhausPill(
                        viewModel.L("\(collisions.count) Arity Alert", "\(collisions.count) 处签名告警"),
                        foreground: RelayBauhausDesign.claudeVermilion,
                        background: RelayBauhausDesign.vermilionWash,
                        border: RelayBauhausDesign.claudeVermilion.opacity(0.5),
                        monospaced: true
                    )
                } else {
                    Text(viewModel.L(
                        "All cross-file call sites match reconciled declaration parameter arities, external labels, and async/throws effects.",
                        "所有跨文件调用点均匹配合并后的声明参数个数、外部标签与 async/throws 效应。"
                    ))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    RelayBauhausPill(
                        viewModel.L("0 Arity Drift", "0 签名漂移"),
                        foreground: RelayBauhausDesign.agySignalGreen,
                        background: RelayBauhausDesign.greenWash,
                        border: RelayBauhausDesign.agySignalGreen.opacity(0.45),
                        monospaced: true
                    )
                }
            }
        }
    }
}

// MARK: - Recessed #18181B Syntax-Tinted Code Well (Anti-Truncation Soft Wrap)

public struct RecessedASTCodeSnippetWell: View {
    public let sourceCode: String
    public var maxLines: Int
    public var language: RelayLanguage

    public init(sourceCode: String, maxLines: Int = 10, language: RelayLanguage = .en) {
        self.sourceCode = sourceCode
        self.maxLines = maxLines
        self.language = language
    }

    public var body: some View {
        let rawLines = sourceCode
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let displayed = Array(rawLines.prefix(maxLines))
        let hiddenCount = max(0, rawLines.count - displayed.count)

        VStack(alignment: .leading, spacing: 1.5) {
            ForEach(Array(displayed.enumerated()), id: \.offset) { idx, lineText in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.carbonGutterInk)
                        .frame(width: 16, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(Self.highlightCodeLine(lineText))
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if hiddenCount > 0 {
                Text(language.isChinese
                     ? "  + 另有 \(hiddenCount) 行声明体代码已折叠"
                     : "  + \(hiddenCount) additional lines in declaration body")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color(relayHex: "#A1A1AA"))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.carbonMatteWell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.carbonInsetBorder, lineWidth: 1)
        )
    }

    private static let swiftKeywords: Set<String> = [
        "import", "public", "private", "internal", "fileprivate", "open",
        "struct", "class", "enum", "actor", "protocol", "extension",
        "func", "init", "let", "var", "return", "guard", "else", "if",
        "throw", "throws", "try", "async", "await", "mutating", "static",
        "true", "false", "nil", "in", "for", "while", "switch", "case"
    ]

    public static func highlightCodeLine(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<<<<<<<") || trimmed.hasPrefix("=======") || trimmed.hasPrefix(">>>>>>>") {
            var marker = AttributedString(line)
            marker.foregroundColor = Color(relayHex: "#FCA5A5")
            marker.backgroundColor = Color(relayHex: "#451A1A")
            marker.font = .system(size: 9.5, weight: .bold, design: .monospaced)
            return marker
        }
        if trimmed.hasPrefix("//") {
            var comment = AttributedString(line)
            comment.foregroundColor = Color(relayHex: "#9CA3AF")
            return comment
        }

        var result = AttributedString()
        var currentWord = ""

        func flushWord() {
            guard !currentWord.isEmpty else { return }
            var part = AttributedString(currentWord)
            if swiftKeywords.contains(currentWord) {
                part.foregroundColor = Color(relayHex: "#FB923C") // Warm Bauhaus amber keyword
                part.font = .system(size: 9.5, weight: .semibold, design: .monospaced)
            } else if let first = currentWord.first, first.isUppercase {
                part.foregroundColor = Color(relayHex: "#93C5FD") // Crisp sky type identifier
            } else if currentWord.allSatisfy({ $0.isNumber || $0 == "_" }) {
                part.foregroundColor = Color(relayHex: "#86EFAC") // Signal mint literal
            } else {
                part.foregroundColor = RelayBauhausDesign.carbonPrimaryText
            }
            result.append(part)
            currentWord.removeAll(keepingCapacity: true)
        }

        for ch in line {
            if ch.isLetter || ch.isNumber || ch == "_" {
                currentWord.append(ch)
            } else {
                flushWord()
                var punct = AttributedString(String(ch))
                punct.foregroundColor = Color(relayHex: "#D4D4D8")
                result.append(punct)
            }
        }
        flushWord()
        return result
    }
}
