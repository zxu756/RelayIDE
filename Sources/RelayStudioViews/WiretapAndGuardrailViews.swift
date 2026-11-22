import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelayWorkbenchShell
import SwiftUI

// MARK: - JavaScriptCore Guardrail Plugin Studio & Live Hook Scratchpad

public struct GuardrailPluginStudioView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.isDemoMode {
            VStack(spacing: 8) {
                guardrailStudioHeaderStrip

                HStack(alignment: .top, spacing: 10) {
                    pluginCatalogColumn
                        .frame(width: 404)
                        .frame(maxHeight: .infinity)

                    VStack(spacing: 8) {
                        jsScratchpadCard
                        guardrailFindingsAndTraceLedger
                            .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(10)
            .background(RelayBauhausDesign.warmSandpaper)
        } else {
            VStack {
                RelayBauhausCard(padding: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.L("Guardrail Plugins · Not Connected", "护栏插件 · 未接入"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)

                        Text(
                            viewModel.L(
                                "JavaScriptCore guardrail hooks are not connected to live 'RelayIDE run' executions. Launch with --demo to inspect synthetic guardrail policies.",
                                "JavaScriptCore 护栏钩子未接入真实的 RelayIDE run 执行流程。如需查看合成护栏策略演示，请使用 --demo 模式启动。"
                            )
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(10)
            .background(RelayBauhausDesign.warmSandpaper)
        }
    }

    // MARK: - Top Guardrail Policy Pack Header

    private var guardrailStudioHeaderStrip: some View {
        let enabledCount = viewModel.policyPack.entries.filter(\.manifest.isEnabled).count
        let blockerCount = viewModel.guardrailFindings.filter { $0.severity == .blocker }.count

        return HStack(spacing: 8) {
            RelayBauhausPill(
                viewModel.L(
                    "Policy Pack: \(viewModel.policyPack.formatVersion)",
                    "策略包：\(viewModel.policyPack.formatVersion)"
                ),
                foreground: RelayBauhausDesign.espressoInk,
                background: RelayBauhausDesign.warmIvory,
                border: RelayBauhausDesign.hairlineBorder,
                symbolName: "checkmark.shield.fill",
                monospaced: true
            )

            RelayBauhausPill(
                viewModel.L(
                    "\(enabledCount)/\(viewModel.policyPack.entries.count) Plugins Active",
                    "\(enabledCount)/\(viewModel.policyPack.entries.count) 个插件已启用"
                ),
                foreground: RelayBauhausDesign.agySignalGreen,
                background: RelayBauhausDesign.greenWash,
                border: RelayBauhausDesign.agySignalGreen.opacity(0.45),
                monospaced: true
            )

            RelayBauhausPill(
                viewModel.currentLanguage.isChinese
                    ? String(format: "VM 预算 %.0f µs", viewModel.policyPack.defaultExecutionBudgetMicros)
                    : String(format: "VM Budget %.0f µs", viewModel.policyPack.defaultExecutionBudgetMicros),
                foreground: RelayBauhausDesign.codexCobalt,
                background: RelayBauhausDesign.cobaltWash,
                border: RelayBauhausDesign.codexCobalt.opacity(0.45),
                symbolName: "cpu",
                monospaced: true
            )

            Spacer(minLength: 4)

            if blockerCount > 0 {
                RelayBauhausPill(
                    viewModel.L("\(blockerCount) Active Veto Finding", "\(blockerCount) 项活跃否决拦截"),
                    foreground: RelayBauhausDesign.claudeVermilion,
                    background: RelayBauhausDesign.vermilionWash,
                    border: RelayBauhausDesign.claudeVermilion.opacity(0.55),
                    symbolName: "hand.raised.fill",
                    monospaced: true
                )
            }

            Button {
                viewModel.evaluateScratchpadHook(postToast: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(viewModel.L("Evaluate Hook", "执行钩子演练"))
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(RelayBauhausDesign.warmIvory)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.claudeVermilion)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - Left Column: Built-In & Lifecycle JavaScriptCore Plugin Cards

    private var pluginCatalogColumn: some View {
        RelayBauhausCard(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                RelaySectionEyebrow(
                    viewModel.L("Capability-Gated JSCore Plugins", "能力门禁 JSCore 编排插件"),
                    trailingText: "p50 / p95 µs"
                )

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(viewModel.policyPack.entries) { entry in
                            pluginManifestCard(entry)
                        }
                    }
                }
            }
        }
    }

    private func pluginManifestCard(_ entry: RelayPolicyPackPluginEntry) -> some View {
        let manifest = entry.manifest
        let slug = manifest.id.replacingOccurrences(of: "io.relayide.", with: "")
        let isSelected = (viewModel.selectedPluginID == manifest.id)
        let latency = viewModel.pluginLatencyByID[manifest.id]
        let cardFill: Color = isSelected
            ? RelayBauhausDesign.cobaltWash.opacity(0.45)
            : RelayBauhausDesign.sandstoneStrip.opacity(0.35)
        let cardBorder: Color = isSelected
            ? RelayBauhausDesign.codexCobalt
            : RelayBauhausDesign.hairlineBorder
        let cardLineWidth: CGFloat = isSelected ? 1.5 : 1.0

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(viewModel.T(manifest.name))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(slug)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.codexCobalt)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 4)

                pluginStatusToggleButton(entry: entry)
            }

            Text(viewModel.T(manifest.summary))
                .font(.system(size: 10))
                .foregroundStyle(RelayBauhausDesign.graphiteInk)
                .fixedSize(horizontal: false, vertical: true)

            pluginCapabilitiesAndLatencyRow(entry: entry, latency: latency)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: cardLineWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedPluginID = manifest.id
            viewModel.scratchpadScriptSource = manifest.scriptSource
        }
    }

    private func pluginStatusToggleButton(entry: RelayPolicyPackPluginEntry) -> some View {
        let manifest = entry.manifest
        let isEnabled = manifest.isEnabled
        let labelText = isEnabled ? viewModel.L("ACTIVE", "已启用") : viewModel.L("PAUSED", "已暂停")
        let fgColor: Color = isEnabled ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.mutedStoneInk
        let bgColor: Color = isEnabled ? RelayBauhausDesign.greenWash : RelayBauhausDesign.sandstoneStrip
        let strokeColor: Color = isEnabled
            ? RelayBauhausDesign.agySignalGreen.opacity(0.5)
            : RelayBauhausDesign.hairlineBorder

        return Button {
            viewModel.toggleGuardrailPlugin(pluginID: manifest.id)
        } label: {
            Text(labelText)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(fgColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(bgColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private func pluginCapabilitiesAndLatencyRow(
        entry: RelayPolicyPackPluginEntry,
        latency: PluginLatencySummary?
    ) -> some View {
        let manifest = entry.manifest
        let latencyText = latency.map {
            String(format: "p50 %.0fµs · p95 %.0fµs", $0.p50Micros, $0.p95Micros)
        } ?? viewModel.L("No runs recorded", "暂无运行记录")
        return HStack(spacing: 5) {
            ForEach(manifest.capabilities, id: \.self) { cap in
                Text(cap.localizedLabel(in: viewModel.currentLanguage))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(RelayBauhausDesign.sandstoneStrip)
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 4)

            Text(latencyText)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Right Top: Live JS Scratchpad Editor & Evaluate Hook Runner

    private var jsScratchpadCard: some View {
        RelayBauhausCard(padding: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RelaySectionEyebrow(viewModel.L("Live JavaScriptCore Hook Scratchpad", "实时 JavaScriptCore 钩子演练台"))

                    Picker("", selection: $viewModel.scratchpadHookKind) {
                        ForEach(RelayLifecycleHookKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                }

                HStack(spacing: 6) {
                    Text(viewModel.L("EVENT SUBJECT", "事件输入"))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)

                    RelayAdaptiveTextField(
                        viewModel.L("Command or file path to test against hook", "输入待测试的 Shell 命令或文件路径"),
                        text: $viewModel.scratchpadSubjectInput,
                        font: .system(size: 11, design: .monospaced)
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                    )

                    Button {
                        viewModel.evaluateScratchpadHook(postToast: true)
                    } label: {
                        Text(viewModel.L("Run in JSCore", "在 JSCore 中运行"))
                            .font(.system(size: 10.5, weight: .bold))
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

                // Recessed #18181B Live JS Code Editor Well
                RelayAdaptiveCodeEditor(text: $viewModel.scratchpadScriptSource)
                    .frame(height: 156)
                    .background(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .fill(RelayBauhausDesign.carbonMatteWell)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .strokeBorder(RelayBauhausDesign.carbonInsetBorder, lineWidth: 1)
                    )

                if let eval = viewModel.lastScratchpadResult {
                    let isVeto = (eval.hookDecision == .veto)
                    HStack(spacing: 8) {
                        RelayBauhausPill(
                            viewModel.L(
                                "Verdict: \(eval.hookDecision.rawValue)",
                                "裁决：\(localizedVerdictLabel(eval.hookDecision))"
                            ),
                            foreground: isVeto ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen,
                            background: isVeto ? RelayBauhausDesign.vermilionWash : RelayBauhausDesign.greenWash,
                            border: (isVeto ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen).opacity(0.55),
                            monospaced: true
                        )

                        Text(viewModel.T(eval.hookReason))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)

                        Text(viewModel.currentLanguage.isChinese
                             ? String(format: "VM 耗时 %.0f µs (编译 %.0f µs)", eval.profile.totalWallMicros, eval.profile.scriptCompileMicros)
                             : String(format: "VM %.0f µs (compile %.0f µs)", eval.profile.totalWallMicros, eval.profile.scriptCompileMicros))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private func localizedVerdictLabel(_ decision: RelayHookVerdictDecision) -> String {
        switch decision {
        case .allow: return viewModel.L("ALLOW", "放行")
        case .advisory: return viewModel.L("ADVISORY", "提示")
        case .warn: return viewModel.L("WARN", "告警")
        case .redact: return viewModel.L("REDACT", "脱敏")
        case .veto: return viewModel.L("VETO", "否决拦截")
        }
    }

    // MARK: - Right Bottom: Active RelayGuardrailFinding Ledger

    private var guardrailFindingsAndTraceLedger: some View {
        RelayBauhausCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                RelaySectionEyebrow(
                    viewModel.L("Active RelayGuardrailFinding Audit Ledger", "活跃护栏审计台账"),
                    trailingText: viewModel.L("\(viewModel.guardrailFindings.count) findings", "\(viewModel.guardrailFindings.count) 条记录")
                )

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.guardrailFindings) { finding in
                            let sevColor = RelayBauhausDesign.severityColor(finding.severity)
                            let sevWash = RelayBauhausDesign.severityWash(finding.severity)

                            HStack(alignment: .top, spacing: 8) {
                                Text(finding.severity.localizedBadge(in: viewModel.currentLanguage))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(sevColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(sevWash)
                                    )
                                    .fixedSize(horizontal: true, vertical: false)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(viewModel.T(finding.title))
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 4)
                                        Text(finding.laneID ?? viewModel.L("workspace", "全局工作区"))
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }

                                    Text(viewModel.T(finding.detail))
                                        .font(.system(size: 10))
                                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(7)
                            .background(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.38))
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
    }
}
