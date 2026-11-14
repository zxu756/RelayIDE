import Foundation
import RelayModels
import RelayOrchestrator
import RelayPluginSDK
import RelayWiretapProxy
import RelayWorkbenchShell
import SwiftUI

// MARK: - 1. Multi-Vendor Wiretap Flamechart, USD Circuit Breakers & DLP Audit Studio

public struct WiretapBudgetStudioView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            wiretapTopTelemetryStrip
            wiretapTimelineFlamechartCard
            perLaneCircuitBreakerGrid
            dlpAndGuardrailBottomSplit
                .frame(maxHeight: .infinity)
        }
        .padding(10)
        .background(RelayBauhausDesign.warmSandpaper)
    }

    // MARK: - Top Loopback Proxy & Cost Telemetry Strip

    private var wiretapTopTelemetryStrip: some View {
        let analytics = viewModel.costAnalytics
        let trippedCount = viewModel.laneBudgetAccounts.filter(\.circuitOpen).count
        let proxyRunning = viewModel.isWiretapProxyRunning

        return HStack(spacing: 8) {
            RelayBauhausPill(
                proxyRunning
                    ? viewModel.L(
                        "Loopback Proxy Active · Port \(viewModel.wiretapProxyPort)",
                        "本地回环代理运行中 · 端口 \(viewModel.wiretapProxyPort)"
                    )
                    : viewModel.L(
                        "Loopback Proxy Not Started (Planned M4)",
                        "本地回环代理未启动（排在 M4）"
                    ),
                foreground: proxyRunning ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.graphiteInk,
                background: proxyRunning ? RelayBauhausDesign.greenWash : RelayBauhausDesign.warmIvory,
                border: proxyRunning ? RelayBauhausDesign.agySignalGreen.opacity(0.5) : RelayBauhausDesign.hairlineBorder,
                symbolName: "network.badge.shield.half.filled",
                monospaced: true
            )

            if viewModel.isDemoMode || !viewModel.laneBudgetAccounts.isEmpty {
                RelayBauhausPill(
                    viewModel.L(
                        "Total Spend \(RelayBauhausDesign.formatUSD(viewModel.totalWorkspaceSpendUSD)) / \(RelayBauhausDesign.formatUSD(viewModel.globalBudgetCeilingUSD))",
                        "总消耗 \(RelayBauhausDesign.formatUSD(viewModel.totalWorkspaceSpendUSD)) / \(RelayBauhausDesign.formatUSD(viewModel.globalBudgetCeilingUSD))"
                    ),
                    foreground: RelayBauhausDesign.espressoInk,
                    background: RelayBauhausDesign.warmIvory,
                    border: RelayBauhausDesign.hairlineBorder,
                    symbolName: "dollarsign.circle",
                    monospaced: true
                )

                RelayBauhausPill(
                    viewModel.L(
                        "Cache Saved \(RelayBauhausDesign.formatUSD(analytics.totalCacheSavingsUSD))",
                        "缓存节省 \(RelayBauhausDesign.formatUSD(analytics.totalCacheSavingsUSD))"
                    ),
                    foreground: RelayBauhausDesign.codexCobalt,
                    background: RelayBauhausDesign.cobaltWash,
                    border: RelayBauhausDesign.codexCobalt.opacity(0.45),
                    symbolName: "bolt.horizontal.circle.fill",
                    monospaced: true
                )

                RelayBauhausPill(
                    viewModel.currentLanguage.isChinese
                        ? String(format: "速率 $%.2f/时", analytics.workspaceBurnRateUSDPerHour)
                        : String(format: "Burn $%.2f/hr", analytics.workspaceBurnRateUSDPerHour),
                    foreground: RelayBauhausDesign.graphiteInk,
                    background: RelayBauhausDesign.warmIvory,
                    border: RelayBauhausDesign.hairlineBorder,
                    monospaced: true
                )
            }

            Spacer(minLength: 4)

            if trippedCount > 0 {
                RelayBauhausPill(
                    viewModel.L("\(trippedCount) Circuit Tripped (HTTP 429)", "\(trippedCount) 路熔断拦截 (HTTP 429)"),
                    foreground: RelayBauhausDesign.claudeVermilion,
                    background: RelayBauhausDesign.vermilionWash,
                    border: RelayBauhausDesign.claudeVermilion.opacity(0.55),
                    symbolName: "exclamationmark.octagon.fill",
                    monospaced: true
                )
            }

            Button {
                viewModel.selectPane(.guardrailPlugins)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "applescript.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(viewModel.L("JSCore Guardrails", "JSCore 编排护栏"))
                        .font(.system(size: 11, weight: .bold))
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

    // MARK: - Multi-Vendor HTTP/SSE Wiretap Timeline Flamechart (SwiftUI.Canvas)

    private var wiretapTimelineFlamechartCard: some View {
        RelayBauhausCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RelaySectionEyebrow(
                        viewModel.L("HTTP/SSE Wiretap Timeline Flamechart", "HTTP/SSE Wiretap 时序火焰图"),
                        trailingText: viewModel.L(
                            "\(viewModel.wiretapSpanRecords.count) turns · \(Int(viewModel.flamechartTimeline.horizonDurationMs / 1000))s window",
                            "\(viewModel.wiretapSpanRecords.count) 轮请求 · \(Int(viewModel.flamechartTimeline.horizonDurationMs / 1000))s 窗口"
                        )
                    )

                    Spacer(minLength: 8)

                    HStack(spacing: 10) {
                        flameLegendSwatch(
                            color: RelayBauhausDesign.structuralBorder,
                            label: viewModel.L("TTFT Prefill", "TTFT 首字预填充")
                        )
                        flameLegendSwatch(
                            color: RelayBauhausDesign.codexCobalt,
                            label: viewModel.L("SSE Token Stream", "SSE 令牌流")
                        )
                        flameLegendSwatch(
                            color: RelayBauhausDesign.claudeVermilion,
                            label: viewModel.L("HTTP 429 Circuit Gate", "HTTP 429 熔断门禁")
                        )
                    }
                }

                Canvas { context, size in
                    drawWiretapFlamechart(in: &context, size: size)
                }
                .frame(height: 158)
                .background(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .fill(RelayBauhausDesign.warmSandpaper.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                        .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                )
            }
        }
    }

    private func flameLegendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 6)
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(RelayBauhausDesign.graphiteInk)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func drawWiretapFlamechart(in context: inout GraphicsContext, size: CGSize) {
        let leftGutter: CGFloat = 152
        let rightPad: CGFloat = 14
        let topRulerHeight: CGFloat = 20
        let plotWidth = max(200, size.width - leftGutter - rightPad)
        let plotHeight = max(80, size.height - topRulerHeight - 6)

        // Draw time ruler ticks (0s ... 120s)
        let anchorTime = viewModel.wiretapSpanRecords.map(\.recordedAt).min() ?? Date()
        let maxEndOffsetSec: Double = {
            var peak = 120.0
            for rec in viewModel.wiretapSpanRecords {
                let startSec = max(0, rec.recordedAt.timeIntervalSince(anchorTime))
                peak = max(peak, startSec + rec.durationMs / 1_000.0)
            }
            return peak
        }()

        var rulerPath = Path()
        rulerPath.move(to: CGPoint(x: leftGutter, y: topRulerHeight))
        rulerPath.addLine(to: CGPoint(x: size.width - rightPad, y: topRulerHeight))
        context.stroke(rulerPath, with: .color(RelayBauhausDesign.hairlineBorder), lineWidth: 1)

        let tickCount = 6
        for i in 0...tickCount {
            let frac = CGFloat(i) / CGFloat(tickCount)
            let tx = leftGutter + frac * plotWidth

            var vGrid = Path()
            vGrid.move(to: CGPoint(x: tx, y: topRulerHeight))
            vGrid.addLine(to: CGPoint(x: tx, y: size.height - 4))
            context.stroke(
                vGrid,
                with: .color(RelayBauhausDesign.hairlineBorder.opacity(0.65)),
                style: StrokeStyle(lineWidth: 0.7, dash: [3, 3])
            )

            let secValue = Int((Double(frac) * maxEndOffsetSec).rounded())
            let tickLabel = Text("+\(secValue)s")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(RelayBauhausDesign.mutedStoneInk)
            context.draw(tickLabel, at: CGPoint(x: tx, y: 10), anchor: i == tickCount ? .trailing : .center)
        }

        let orderedLanes = viewModel.lanes
        let rowCount = max(1, orderedLanes.count)
        let rowHeight = plotHeight / CGFloat(rowCount)

        for (rowIdx, lane) in orderedLanes.enumerated() {
            let rowTop = topRulerHeight + CGFloat(rowIdx) * rowHeight
            let rowCenterY = rowTop + rowHeight * 0.5
            let vendorColor = RelayBauhausDesign.vendorColor(lane.assignedVendor)

            // Alternating subtle sandstone band
            if rowIdx % 2 == 1 {
                let band = CGRect(x: 0, y: rowTop, width: size.width, height: rowHeight)
                context.fill(Path(band), with: .color(RelayBauhausDesign.sandstoneStrip.opacity(0.42)))
            }

            // Left Track Header
            var dot = Path()
            dot.addRoundedRect(in: CGRect(x: 8, y: rowCenterY - 4, width: 6, height: 8), cornerSize: CGSize(width: 1.5, height: 1.5))
            context.fill(dot, with: .color(vendorColor))

            let trackTitle = Text(RelayBauhausDesign.vendorStudioName(lane.assignedVendor, language: viewModel.currentLanguage))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(RelayBauhausDesign.espressoInk)
            context.draw(trackTitle, at: CGPoint(x: 20, y: rowCenterY - 5), anchor: .leading)

            let laneSub = Text(lane.id)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundColor(RelayBauhausDesign.mutedStoneInk)
            context.draw(laneSub, at: CGPoint(x: 20, y: rowCenterY + 6.5), anchor: .leading)

            // Span Flame Bars for this Lane
            let spans = viewModel.wiretapSpanRecords.filter { $0.laneID == lane.id }
            for span in spans {
                let startSec = max(0, span.recordedAt.timeIntervalSince(anchorTime))
                let durSec = max(1.8, span.durationMs / 1_000.0)
                let ttftSec = min(durSec * 0.55, max(0.4, span.ttftMs / 1_000.0))

                let xStart = leftGutter + CGFloat(startSec / maxEndOffsetSec) * plotWidth
                let totalW = max(8.0, CGFloat(durSec / maxEndOffsetSec) * plotWidth)
                let ttftW = min(totalW, max(3.0, CGFloat(ttftSec / maxEndOffsetSec) * plotWidth))
                let barY = rowTop + 6
                let barH = max(14, rowHeight - 12)

                if span.blockedByCircuitBreaker || span.statusCode == 429 {
                    let blockedRect = CGRect(x: xStart, y: barY - 1, width: max(18, totalW), height: barH + 2)
                    let blockedPath = Path(roundedRect: blockedRect, cornerRadius: 3)
                    context.fill(blockedPath, with: .color(RelayBauhausDesign.claudeVermilion))
                    context.stroke(blockedPath, with: .color(RelayBauhausDesign.espressoInk), lineWidth: 1.1)

                    let tag = Text("429")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RelayBauhausDesign.warmIvory)
                    context.draw(tag, at: CGPoint(x: blockedRect.midX, y: blockedRect.midY), anchor: .center)
                } else {
                    // Full Turn Envelope (Streaming body)
                    let fullRect = CGRect(x: xStart, y: barY, width: totalW, height: barH)
                    let fullPath = Path(roundedRect: fullRect, cornerRadius: 3)
                    context.fill(fullPath, with: .color(vendorColor.opacity(0.86)))

                    // Leading TTFT Prefill Segment
                    let ttftRect = CGRect(x: xStart, y: barY, width: ttftW, height: barH)
                    let ttftPath = Path(roundedRect: ttftRect, cornerRadius: 2.5)
                    context.fill(ttftPath, with: .color(RelayBauhausDesign.espressoInk.opacity(0.32)))

                    context.stroke(fullPath, with: .color(RelayBauhausDesign.espressoInk.opacity(0.35)), lineWidth: 0.75)

                    if totalW >= 34 {
                        let costTag = Text(String(format: "$%.2f", span.costUSD))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(RelayBauhausDesign.warmIvory)
                        context.draw(costTag, at: CGPoint(x: fullRect.midX, y: fullRect.midY), anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 4 Per-Lane USD Circuit Breaker Cards

    private var perLaneCircuitBreakerGrid: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.laneBudgetAccounts) { account in
                laneCircuitBreakerCard(account)
            }
        }
    }

    private func laneCircuitBreakerCard(_ account: LaneBudgetAccount) -> some View {
        let vendorAccent = RelayBauhausDesign.vendorColor(account.vendor)
        let ratio = min(1.0, max(0.0, account.ceilingUSD > 0 ? account.spentUSD / account.ceilingUSD : 0))
        let cachePct = account.inputTokens > 0
            ? (Double(account.cachedTokens) / Double(account.inputTokens)) * 100.0
            : 0.0
        let laneSpans = viewModel.wiretapSpanRecords.filter { $0.laneID == account.laneID && !$0.blockedByCircuitBreaker }
        let avgTokPerSec: Double = {
            guard !laneSpans.isEmpty else { return 68.0 }
            return laneSpans.reduce(0.0) { $0 + $1.tokensPerSecond } / Double(laneSpans.count)
        }()

        return RelayBauhausCard(
            padding: 9,
            fill: account.circuitOpen ? RelayBauhausDesign.vermilionWash.opacity(0.55) : RelayBauhausDesign.warmIvory,
            borderColor: account.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.hairlineBorder
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    RelayVendorBadge(vendor: account.vendor, compact: false, language: viewModel.currentLanguage)
                    Spacer(minLength: 4)
                    Text(account.circuitOpen ? viewModel.L("TRIPPED", "已熔断") : viewModel.L("CLOSED", "正常闭合"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(account.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(account.circuitOpen ? RelayBauhausDesign.vermilionWash : RelayBauhausDesign.greenWash)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(RelayBauhausDesign.formatPreciseUSD(account.spentUSD))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(account.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.espressoInk)
                    Text(viewModel.L(
                        "/ \(RelayBauhausDesign.formatUSD(account.ceilingUSD)) cap",
                        "/ \(RelayBauhausDesign.formatUSD(account.ceilingUSD)) 上限"
                    ))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    Spacer(minLength: 2)
                    Text(String(format: "%.0f%%", (account.spentUSD / max(0.01, account.ceilingUSD)) * 100.0))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(account.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.graphiteInk)
                }

                // Crisp Architectural Progress Bar
                GeometryReader { barGeo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(RelayBauhausDesign.sandstoneStrip)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(account.circuitOpen ? RelayBauhausDesign.claudeVermilion : vendorAccent)
                            .frame(width: barGeo.size.width * CGFloat(ratio))
                    }
                }
                .frame(height: 6)

                HStack(spacing: 6) {
                    Text(viewModel.currentLanguage.isChinese
                         ? String(format: "缓存 %.0f%%", cachePct)
                         : String(format: "Cache %.0f%%", cachePct))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    Text(String(format: "%.0f tok/s", avgTokPerSec))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Button {
                    viewModel.toggleCircuitBreaker(forLane: account.laneID)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: account.circuitOpen ? "arrow.counterclockwise.circle.fill" : "power.dotted")
                            .font(.system(size: 10, weight: .bold))
                        Text(account.circuitOpen
                             ? viewModel.L("Reset Circuit (+Cap)", "恢复熔断 (+提额)")
                             : viewModel.L("Trip Circuit Breaker", "触发预算熔断"))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(account.circuitOpen ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
                    .padding(.vertical, 4.5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .fill(account.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.sandstoneStrip)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                            .strokeBorder(account.circuitOpen ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.hairlineBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Split: Outbound Secret DLP Audit Table + JSCore Guardrail Ledger

    private var dlpAndGuardrailBottomSplit: some View {
        HStack(alignment: .top, spacing: 8) {
            outboundSecretDLPAuditCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            activeGuardrailSummaryCard
                .frame(width: 432)
                .frame(maxHeight: .infinity)
        }
    }

    private var outboundSecretDLPAuditCard: some View {
        RelayBauhausCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                RelaySectionEyebrow(
                    viewModel.L("Outbound Secret DLP Loopback Audit", "外发敏感凭据 DLP 回环审计"),
                    trailingText: viewModel.L(
                        "\(viewModel.dlpAuditEvents.count) inspected payloads",
                        "已检 \(viewModel.dlpAuditEvents.count) 份载荷"
                    )
                )

                // Crisp Table Column Header
                HStack(spacing: 8) {
                    Text(viewModel.L("LANE", "通道"))
                        .frame(width: 68, alignment: .leading)
                    Text(viewModel.L("SECRET CATEGORY & MASKED SAMPLE", "凭据类别与脱敏样本"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(viewModel.L("SCAN", "耗时"))
                        .frame(width: 54, alignment: .trailing)
                    Text(viewModel.L("VERDICT", "裁决"))
                        .frame(width: 96, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(RelayBauhausDesign.sandstoneStrip)
                )

                RelayAdaptiveScrollContainer {
                    VStack(spacing: 4) {
                        ForEach(viewModel.dlpAuditEvents) { event in
                            dlpAuditTableRow(event)
                        }
                    }
                }
            }
        }
    }

    private func dlpAuditTableRow(_ event: DLPAuditEvent) -> some View {
        let firstMatch = event.matches.first
        let badge = dlpOutcomeBadge(event.outcome)

        return HStack(spacing: 8) {
            RelayVendorBadge(vendor: event.vendor, compact: true, language: viewModel.currentLanguage)
                .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(firstMatch.map { viewModel.T($0.category.displayTitle) }
                     ?? viewModel.L("Outbound Prompt JSON (\(event.providerHost))", "外发提示词 JSON (\(event.providerHost))"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text(firstMatch.map { "\($0.maskedSample) · sha:\($0.secretFingerprintHex)" }
                     ?? viewModel.L("0 credential patterns matched · forwarded intact", "0 项凭据命中 · 原样转发"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.0f µs", event.scanDurationMicros))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(RelayBauhausDesign.graphiteInk)
                .frame(width: 54, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)

            Text(badge.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(badge.fg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(badge.bg)
                )
                .frame(width: 96, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private func dlpOutcomeBadge(_ outcome: DLPInspectionOutcome) -> (label: String, fg: Color, bg: Color) {
        switch outcome {
        case .blockedBeforeLoopbackExit:
            return (viewModel.L("BLOCKED", "已阻断"), RelayBauhausDesign.claudeVermilion, RelayBauhausDesign.vermilionWash)
        case .sanitizedAndForwarded:
            return (viewModel.L("REDACTED", "已脱敏"), RelayBauhausDesign.vibeOchre, RelayBauhausDesign.ochreWash)
        case .auditedPass:
            return (viewModel.L("AUDITED", "已审计"), RelayBauhausDesign.codexCobalt, RelayBauhausDesign.cobaltWash)
        case .cleanPass:
            return (viewModel.L("CLEAN PASS", "安全放行"), RelayBauhausDesign.agySignalGreen, RelayBauhausDesign.greenWash)
        }
    }

    private var activeGuardrailSummaryCard: some View {
        RelayBauhausCard(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RelaySectionEyebrow(
                        viewModel.L("JavaScriptCore Guardrail Ledger", "JavaScriptCore 护栏审计台账"),
                        trailingText: viewModel.L("\(viewModel.guardrailFindings.count) events", "\(viewModel.guardrailFindings.count) 条事件")
                    )
                }

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(viewModel.guardrailFindings.prefix(5)) { finding in
                            let sevColor = RelayBauhausDesign.severityColor(finding.severity)
                            let sevWash = RelayBauhausDesign.severityWash(finding.severity)

                            VStack(alignment: .leading, spacing: 2.5) {
                                HStack(spacing: 5) {
                                    Text(finding.severity.localizedBadge(in: viewModel.currentLanguage))
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(sevColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(sevWash)
                                        )
                                        .fixedSize(horizontal: true, vertical: false)

                                    Text(viewModel.T(finding.title))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Text("\(finding.pluginID.replacingOccurrences(of: "io.relayide.", with: "")) · \(finding.laneID ?? viewModel.L("workspace", "全局工作区"))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.4))
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

// MARK: - 2. JavaScriptCore Guardrail Plugin Studio & Live Hook Scratchpad

public struct GuardrailPluginStudioView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
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
