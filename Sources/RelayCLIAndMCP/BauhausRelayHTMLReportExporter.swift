import Foundation
import RelayModels
import RelayOrchestrator
import RelayWorkspaceStore

// MARK: - Bauhaus Warm-Sandpaper Bilingual Standalone HTML Dossier Exporter (Hallmark Zero-Slop Compliant)

public struct BauhausRelayHTMLReportExporter: Sendable {
    public init() {}

    public func exportHTMLDossier(
        orchestrator: MultiVendorDAGOrchestrator,
        initialLanguage: RelayLanguage = .en
    ) throws -> String {
        let stats = try orchestrator.database.computeStats()
        let lanes = try orchestrator.database.allLanes()
        let mergeReports = try orchestrator.database.allMergeReports()
        let spans = try orchestrator.database.allWiretapSpans()
        let findings = try orchestrator.database.allGuardrailFindings()
        let isDemoWorkspace = (orchestrator.database.getMeta(key: "is_demo_workspace") == "1")

        let isZh = initialLanguage.isChinese
        func pick(_ en: String, _ zh: String) -> String {
            isZh ? zh : en
        }

        let rawTitleEN = stats.workspaceName
        let rawTitleZH = RelayLocalizer.translateDisplayText(stats.workspaceName, language: .zhHans)
        let workspaceTitleEN = isDemoWorkspace ? "[DEMO] \(rawTitleEN)" : rawTitleEN
        let workspaceTitleZH = isDemoWorkspace ? "[演示数据] \(rawTitleZH)" : rawTitleZH
        let pageTitleEN = "RelayIDE v1.2.0 Workspace Dossier: \(workspaceTitleEN)"
        let pageTitleZH = "RelayIDE v1.2.0 工作区报告：\(workspaceTitleZH)"

        let laneRowsHTML = lanes.map { lane in
            let filesSummary = lane.dirtyFiles
                .map { "\(escapeHTML($0.status.rawValue)) \(escapeHTML($0.relativePath))" }
                .joined(separator: "<br>")
            let vendorEN = lane.assignedVendor.localizedDisplayName(in: .en)
            let vendorZH = lane.assignedVendor.localizedDisplayName(in: .zhHans)
            let deltaCell = filesSummary.isEmpty
                ? bilingualSpan(en: "Clean", zh: "干净无变更", initial: initialLanguage)
                : filesSummary
            return """
            <tr>
              <td class="mono">\(escapeHTML(lane.id))</td>
              <td><strong>\(bilingualSpan(en: vendorEN, zh: vendorZH, initial: initialLanguage))</strong></td>
              <td class="mono">\(escapeHTML(lane.branchName))</td>
              <td class="mono">\(escapeHTML(lane.ownershipRule.allowedGlobs.joined(separator: ", ")))</td>
              <td class="mono">\(deltaCell)</td>
            </tr>
            """
        }.joined(separator: "\n")

        let mergeRowsHTML = mergeReports.map { rep in
            let stateEN = rep.unresolvedConflictCount == 0
                ? "Auto-Merged Cleanly"
                : "\(rep.unresolvedConflictCount) Divergent Symbol(s)"
            let stateZH = rep.unresolvedConflictCount == 0
                ? "无冲突自动合并"
                : "\(rep.unresolvedConflictCount) 处符号分叉冲突"
            let gitNoteEN = rep.wouldGitLineMergeConflict ? "Rescued Git Line Conflict" : "Standard AST Pass"
            let gitNoteZH = rep.wouldGitLineMergeConflict ? "已消解 Git 行级冲突" : "标准 AST 扫描通过"
            let summaryEN = "\(stateEN) · \(gitNoteEN)"
            let summaryZH = "\(stateZH) · \(gitNoteZH)"
            return """
            <tr>
              <td class="mono">\(escapeHTML(rep.relativePath))</td>
              <td>\(escapeHTML(rep.language.rawValue))</td>
              <td class="num">\(rep.autoMergedCount)</td>
              <td class="num">\(rep.unresolvedConflictCount)</td>
              <td>\(bilingualSpan(en: summaryEN, zh: summaryZH, initial: initialLanguage))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let spanRowsHTML = spans.map { s in
            let vendorEN = s.vendor.localizedDisplayName(in: .en)
            let vendorZH = s.vendor.localizedDisplayName(in: .zhHans)
            return """
            <tr>
              <td class="mono">\(escapeHTML(s.laneID))</td>
              <td>\(bilingualSpan(en: vendorEN, zh: vendorZH, initial: initialLanguage))</td>
              <td class="mono">\(escapeHTML(s.modelIdentifier))</td>
              <td class="num">\(s.inputTokens)</td>
              <td class="num">\(s.cachedReadTokens)</td>
              <td class="num">\(s.outputTokens + s.reasoningTokens)</td>
              <td class="num">$\(String(format: "%.4f", s.costUSD))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let findingRowsHTML = findings.map { f in
            let sevEN = sentenceCaseSeverity(f.severity)
            let sevZH = f.severity.localizedBadge(in: .zhHans)
            let pluginEN = f.pluginName
            let pluginZH = RelayLocalizer.translateDisplayText(f.pluginName, language: .zhHans)
            let scopeEN = f.laneID ?? "workspace"
            let scopeZH = f.laneID ?? "全局工作区"
            let titleEN = "\(f.title):"
            let titleZH = "\(RelayLocalizer.translateDisplayText(f.title, language: .zhHans))："
            let detailEN = f.detail
            let detailZH = RelayLocalizer.translateDisplayText(f.detail, language: .zhHans)
            return """
            <tr>
              <td class="mono">\(bilingualSpan(en: sevEN, zh: sevZH, initial: initialLanguage))</td>
              <td>\(bilingualSpan(en: pluginEN, zh: pluginZH, initial: initialLanguage))</td>
              <td class="mono">\(bilingualSpan(en: scopeEN, zh: scopeZH, initial: initialLanguage))</td>
              <td><strong data-en="\(escapeHTML(titleEN))" data-zh="\(escapeHTML(titleZH))">\(escapeHTML(pick(titleEN, titleZH)))</strong> \(bilingualSpan(en: detailEN, zh: detailZH, initial: initialLanguage))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let walTotalBytes = stats.sqliteBytes + stats.walBytes
        let schemaMetaEN = "Schema v\(stats.schemaVersion) · SQLite WAL \(walTotalBytes) B"
        let schemaMetaZH = "架构 v\(stats.schemaVersion) · SQLite WAL \(walTotalBytes) 字节"
        let kickerEN = isDemoWorkspace
            ? "RelayIDE v1.2.0 Synthetic Demo Workspace Snapshot (Preview Only, Not Output from Live Agent Runs)"
            : "RelayIDE v1.2.0 Workspace Ledger Snapshot"
        let kickerZH = isDemoWorkspace
            ? "RelayIDE v1.2.0 合成演示工作区快照（仅供预览，非真实智能体运行产物）"
            : "RelayIDE v1.2.0 工作区台账快照"
        let demoBannerHTML: String = {
            guard isDemoWorkspace else { return "" }
            let demoEN = "[DEMO] Synthetic preview dataset: lanes, worktree paths, commit OIDs, experimental 3-way merges, token counts, and guardrail entries below were generated by --seed-demo and do not represent live coding agent runs."
            let demoZH = "[演示数据] 合成预览数据集：下方展示的通道、工作树路径、提交哈希、实验性三路合并、令牌统计与护栏记录均由 --seed-demo 生成，并非真实智能体运行产物。"
            return """
            <aside class="demo-callout" role="note" data-en="\(escapeHTML(demoEN))" data-zh="\(escapeHTML(demoZH))">\(escapeHTML(pick(demoEN, demoZH)))</aside>
            """
        }()

        let zhActiveClass = isZh ? " is-active" : ""
        let enActiveClass = isZh ? "" : " is-active"
        let zhAriaPressed = isZh ? "true" : "false"
        let enAriaPressed = isZh ? "false" : "true"

        return """
        <!DOCTYPE html>
        <html lang="\(initialLanguage.rawValue)" data-title-en="\(escapeHTML(pageTitleEN))" data-title-zh="\(escapeHTML(pageTitleZH))">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="description" content="RelayIDE v1.2.0 bilingual multi-vendor coding agent worktree matrix, declaration AST merge ledger, and wiretap spend dossier.">
          <title>\(escapeHTML(pick(pageTitleEN, pageTitleZH)))</title>
          <style>
            /* Hallmark · v2.0.0 · scope: app · genre: modern-minimal · posture: restrained · shape: app screen · surface: absolute */
            :root {
              --paper: #F4F2EC;
              --surface: #FDFCF9;
              --stone: #EAE6DC;
              --rule: #D6D1C4;
              --ink: #18181B;
              --ink-muted: #57534E;
              --terracotta: #C2410C;
              --vermilion: #DA3C2A;
              --cobalt: #205DD1;
              --emerald: #188B5D;
              --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
              --font-mono: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
            }
            *, *::before, *::after { box-sizing: border-box; }
            html, body {
              margin: 0;
              padding: 0;
              overflow-x: clip;
              background: var(--paper);
              color: var(--ink);
              font-family: var(--font-sans);
              font-size: 16px;
              line-height: 1.5;
              -webkit-font-smoothing: antialiased;
            }
            .sheet {
              max-width: 1140px;
              margin: 0 auto;
              padding: 2.5rem 1.5rem 4rem;
            }
            header.masthead {
              display: flex;
              flex-wrap: wrap;
              justify-content: space-between;
              align-items: flex-end;
              gap: 1rem;
              padding-bottom: 1.25rem;
              border-bottom: 2px solid var(--ink);
              margin-bottom: 1.75rem;
            }
            h1 {
              margin: 0;
              font-size: 1.75rem;
              line-height: 1.15;
              letter-spacing: -0.02em;
              font-weight: 700;
              text-wrap: balance;
              overflow-wrap: break-word;
              min-width: 0;
            }
            .kicker {
              font-size: 0.84rem;
              font-weight: 600;
              color: var(--ink-muted);
              margin: 0.35rem 0 0;
            }
            .masthead-controls {
              display: flex;
              flex-direction: column;
              align-items: flex-end;
              gap: 0.5rem;
            }
            .lang-switch {
              display: inline-flex;
              align-items: center;
              gap: 2px;
              padding: 2px;
              background: var(--paper);
              border: 1px solid var(--rule);
              border-radius: 6px;
            }
            .lang-btn {
              appearance: none;
              border: 1px solid transparent;
              background: transparent;
              color: var(--ink-muted);
              font-family: var(--font-sans);
              font-size: 0.82rem;
              font-weight: 600;
              line-height: 1.2;
              padding: 0.28rem 0.65rem;
              border-radius: 4px;
              cursor: pointer;
              transition: background-color 120ms ease, color 120ms ease, border-color 120ms ease;
            }
            .lang-btn:hover:not(.is-active) {
              color: var(--ink);
              background: var(--stone);
            }
            .lang-btn.is-active {
              background: var(--ink);
              color: var(--paper);
              border-color: var(--terracotta);
            }
            .meta-tag {
              color: var(--ink-muted);
            }
            .demo-callout {
              margin: 0 0 1.5rem;
              padding: 0.75rem 1rem;
              background: #FEF2F2;
              border: 1px solid var(--vermilion);
              border-left: 4px solid var(--vermilion);
              border-radius: 6px;
              color: var(--ink);
              font-size: 0.88rem;
              font-weight: 600;
            }
            .ledger-strip {
              display: grid;
              grid-template-columns: repeat(5, minmax(0, 1fr));
              border: 1px solid var(--rule);
              background: var(--surface);
              border-radius: 6px;
              margin-bottom: 2rem;
            }
            .ledger-cell {
              padding: 0.9rem 1rem;
              border-right: 1px solid var(--rule);
              min-width: 0;
            }
            .ledger-cell:last-child { border-right: none; }
            .ledger-label {
              font-size: 0.82rem;
              color: var(--ink-muted);
            }
            .ledger-val {
              font-size: 1.25rem;
              font-weight: 600;
              font-variant-numeric: tabular-nums;
              margin-top: 0.25rem;
              overflow-wrap: break-word;
            }
            section {
              margin-bottom: 2.1rem;
            }
            h2 {
              font-size: 1.12rem;
              font-weight: 600;
              margin: 0 0 0.75rem;
              padding-bottom: 0.4rem;
              border-bottom: 1px solid var(--rule);
              text-wrap: balance;
            }
            .table-wrap {
              background: var(--surface);
              border: 1px solid var(--rule);
              border-radius: 6px;
              overflow-x: auto;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              font-size: 0.88rem;
            }
            th {
              text-align: left;
              background: var(--stone);
              padding: 0.6rem 0.85rem;
              font-size: 0.82rem;
              font-weight: 600;
              color: var(--ink-muted);
              border-bottom: 1px solid var(--rule);
            }
            td {
              padding: 0.6rem 0.85rem;
              border-bottom: 1px solid var(--rule);
              vertical-align: top;
            }
            tr:last-child td { border-bottom: none; }
            .mono {
              font-family: var(--font-mono);
              font-variant-numeric: tabular-nums;
              font-size: 0.82rem;
            }
            .num {
              text-align: right;
              font-variant-numeric: tabular-nums;
              font-family: var(--font-mono);
            }
            @media (max-width: 860px) {
              .ledger-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
              .masthead-controls { align-items: flex-start; }
            }
            a:focus-visible, button:focus-visible, summary:focus-visible, [tabindex]:focus-visible {
              outline: 2px solid var(--cobalt);
              outline-offset: 2px;
            }
            a:active, button:active, summary:active, [tabindex]:active {
              transform: translateY(1px);
            }
            button:disabled, [aria-disabled="true"] {
              opacity: 0.45;
              cursor: not-allowed;
            }
            @media (prefers-reduced-motion: reduce) {
              *, *::before, *::after {
                transition-duration: 0.01ms !important;
                animation-duration: 0.01ms !important;
              }
            }
          </style>
        </head>
        <body>
          <main class="sheet">
            <header class="masthead">
              <div>
                <h1 data-en="\(escapeHTML(workspaceTitleEN))" data-zh="\(escapeHTML(workspaceTitleZH))">\(escapeHTML(pick(workspaceTitleEN, workspaceTitleZH)))</h1>
                <p class="kicker" data-en="\(escapeHTML(kickerEN))" data-zh="\(escapeHTML(kickerZH))">\(escapeHTML(pick(kickerEN, kickerZH)))</p>
              </div>
              <div class="masthead-controls">
                <div class="lang-switch" role="group" aria-label="Language switcher">
                  <button type="button" class="lang-btn\(zhActiveClass)" data-lang-choice="zh-Hans" aria-pressed="\(zhAriaPressed)">中文</button>
                  <button type="button" class="lang-btn\(enActiveClass)" data-lang-choice="en" aria-pressed="\(enAriaPressed)">EN</button>
                </div>
                <div class="mono meta-tag" data-en="\(escapeHTML(schemaMetaEN))" data-zh="\(escapeHTML(schemaMetaZH))">\(escapeHTML(pick(schemaMetaEN, schemaMetaZH)))</div>
              </div>
            </header>
            \(demoBannerHTML)
            <section class="ledger-strip" aria-label="Workspace summary metrics">
              <div class="ledger-cell">
                <div class="ledger-label" data-en="Repository Root" data-zh="仓库根目录">\(pick("Repository Root", "仓库根目录"))</div>
                <div class="ledger-val mono">\(escapeHTML((stats.repositoryPath as NSString).lastPathComponent))</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label" data-en="Isolated Lanes" data-zh="隔离工作树通道">\(pick("Isolated Lanes", "隔离工作树通道"))</div>
                <div class="ledger-val">\(stats.activeLaneCount)</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label" data-en="AST Auto-Merges" data-zh="AST 自动合并数">\(pick("AST Auto-Merges", "AST 自动合并数"))</div>
                <div class="ledger-val">\(stats.semanticAutoMergeCount)</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label" data-en="Observed Tokens" data-zh="累计观测令牌">\(pick("Observed Tokens", "累计观测令牌"))</div>
                <div class="ledger-val">\(stats.totalTokensObserved)</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label" data-en="Recorded Spend" data-zh="已记录花费">\(pick("Recorded Spend", "已记录花费"))</div>
                <div class="ledger-val">$\(String(format: "%.4f", stats.totalSpendUSD))</div>
              </div>
            </section>

            <section>
              <h2 data-en="1. Isolated Git Worktree Matrix &amp; File Ownership Scopes" data-zh="1. 隔离 Git 工作树矩阵与文件归属围栏">\(escapeHTML(pick("1. Isolated Git Worktree Matrix & File Ownership Scopes", "1. 隔离 Git 工作树矩阵与文件归属围栏")))</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th data-en="Lane ID" data-zh="通道 ID">\(pick("Lane ID", "通道 ID"))</th>
                      <th data-en="Assigned Agent" data-zh="指派智能体">\(pick("Assigned Agent", "指派智能体"))</th>
                      <th data-en="Branch" data-zh="Git 分支">\(pick("Branch", "Git 分支"))</th>
                      <th data-en="Allowed Globs" data-zh="授权路径围栏">\(pick("Allowed Globs", "授权路径围栏"))</th>
                      <th data-en="Working Tree Deltas" data-zh="工作树变更">\(pick("Working Tree Deltas", "工作树变更"))</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(laneRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>

            <section>
              <h2 data-en="2. Experimental Declaration-Level 3-Way Merge Ledger" data-zh="2. 实验性声明级三路合并台账">\(escapeHTML(pick("2. Experimental Declaration-Level 3-Way Merge Ledger", "2. 实验性声明级三路合并台账")))</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th data-en="Relative Path" data-zh="相对路径">\(pick("Relative Path", "相对路径"))</th>
                      <th data-en="Language" data-zh="语言">\(pick("Language", "语言"))</th>
                      <th class="num" data-en="Auto-Merged" data-zh="自动合并">\(pick("Auto-Merged", "自动合并"))</th>
                      <th class="num" data-en="Conflicts" data-zh="语义冲突">\(pick("Conflicts", "语义冲突"))</th>
                      <th data-en="Resolution Summary" data-zh="合并结论摘要">\(pick("Resolution Summary", "合并结论摘要"))</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(mergeRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>

            <section>
              <h2 data-en="3. Recorded Token &amp; USD Budget Ledger" data-zh="3. 已记录令牌与美元预算台账">\(escapeHTML(pick("3. Recorded Token & USD Budget Ledger", "3. 已记录令牌与美元预算台账")))</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th data-en="Lane" data-zh="通道">\(pick("Lane", "通道"))</th>
                      <th data-en="Vendor" data-zh="智能体厂商">\(pick("Vendor", "智能体厂商"))</th>
                      <th data-en="Model" data-zh="模型标识">\(pick("Model", "模型标识"))</th>
                      <th class="num" data-en="Input" data-zh="输入令牌">\(pick("Input", "输入令牌"))</th>
                      <th class="num" data-en="Cached" data-zh="缓存命中">\(pick("Cached", "缓存命中"))</th>
                      <th class="num" data-en="Output" data-zh="输出令牌">\(pick("Output", "输出令牌"))</th>
                      <th class="num" data-en="Cost (USD)" data-zh="费用 (USD)">\(pick("Cost (USD)", "费用 (USD)"))</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(spanRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>

            <section>
              <h2 data-en="4. JavaScriptCore Guardrail Plugin Audit" data-zh="4. JavaScriptCore 编排护栏插件审计">\(escapeHTML(pick("4. JavaScriptCore Guardrail Plugin Audit", "4. JavaScriptCore 编排护栏插件审计")))</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th data-en="Severity" data-zh="级别">\(pick("Severity", "级别"))</th>
                      <th data-en="Plugin" data-zh="护栏插件">\(pick("Plugin", "护栏插件"))</th>
                      <th data-en="Scope" data-zh="作用范围">\(pick("Scope", "作用范围"))</th>
                      <th data-en="Finding" data-zh="审计详情">\(pick("Finding", "审计详情"))</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(findingRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>
          </main>
          <script>
            (function () {
              var STORAGE_KEY = 'io.github.zxu756.RelayIDE.language';
              function detectPreferredLanguage() {
                try {
                  var saved = window.localStorage.getItem(STORAGE_KEY);
                  if (saved === 'zh-Hans' || saved === 'en') {
                    return saved;
                  }
                } catch (_) {}
                var nav = (navigator.language || '').toLowerCase();
                return nav.startsWith('zh') ? 'zh-Hans' : 'en';
              }
              function applyLanguage(lang) {
                var isZh = (lang === 'zh-Hans');
                var root = document.documentElement;
                root.lang = isZh ? 'zh-Hans' : 'en';
                var nextTitle = root.getAttribute(isZh ? 'data-title-zh' : 'data-title-en');
                if (nextTitle) {
                  document.title = nextTitle;
                }
                var nodes = document.querySelectorAll('[data-en][data-zh]');
                for (var i = 0; i < nodes.length; i++) {
                  var el = nodes[i];
                  var val = el.getAttribute(isZh ? 'data-zh' : 'data-en');
                  if (val !== null) {
                    el.textContent = val;
                  }
                }
                var buttons = document.querySelectorAll('.lang-btn[data-lang-choice]');
                for (var j = 0; j < buttons.length; j++) {
                  var btn = buttons[j];
                  var active = (btn.getAttribute('data-lang-choice') === (isZh ? 'zh-Hans' : 'en'));
                  btn.classList.toggle('is-active', active);
                  btn.setAttribute('aria-pressed', active ? 'true' : 'false');
                }
              }
              var buttons = document.querySelectorAll('.lang-btn[data-lang-choice]');
              for (var k = 0; k < buttons.length; k++) {
                buttons[k].addEventListener('click', function (ev) {
                  var choice = ev.currentTarget.getAttribute('data-lang-choice') || 'en';
                  try {
                    window.localStorage.setItem(STORAGE_KEY, choice);
                  } catch (_) {}
                  applyLanguage(choice);
                });
              }
              applyLanguage(detectPreferredLanguage());
            })();
          </script>
        </body>
        </html>
        """
    }

    private func bilingualSpan(en: String, zh: String, initial: RelayLanguage) -> String {
        let visible = initial.isChinese ? zh : en
        return "<span data-en=\"\(escapeHTML(en))\" data-zh=\"\(escapeHTML(zh))\">\(escapeHTML(visible))</span>"
    }

    private func sentenceCaseSeverity(_ severity: GuardrailSeverity) -> String {
        switch severity {
        case .pass: return "Pass"
        case .advisory: return "Advisory"
        case .warning: return "Warning"
        case .blocker: return "Blocker"
        }
    }

    private func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{2014}", with: "·")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
