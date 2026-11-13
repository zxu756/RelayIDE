import Foundation
import RelayModels
import RelayOrchestrator
import RelayWorkspaceStore

// MARK: - Bauhaus Warm-Sandpaper Standalone HTML Dossier Exporter (Hallmark Zero-Slop Compliant)

public struct BauhausRelayHTMLReportExporter: Sendable {
    public init() {}

    public func exportHTMLDossier(orchestrator: MultiVendorDAGOrchestrator) throws -> String {
        let stats = try orchestrator.database.computeStats()
        let lanes = try orchestrator.database.allLanes()
        let mergeReports = try orchestrator.database.allMergeReports()
        let spans = try orchestrator.database.allWiretapSpans()
        let findings = try orchestrator.database.allGuardrailFindings()

        let laneRowsHTML = lanes.map { lane in
            let filesSummary = lane.dirtyFiles.map { "\($0.status.rawValue) \($0.relativePath)" }.joined(separator: "<br>")
            return """
            <tr>
              <td class="mono">\(escapeHTML(lane.id))</td>
              <td><strong>\(escapeHTML(lane.assignedVendor.displayName))</strong></td>
              <td class="mono">\(escapeHTML(lane.branchName))</td>
              <td class="mono">\(escapeHTML(lane.ownershipRule.allowedGlobs.joined(separator: ", ")))</td>
              <td class="mono">\(filesSummary.isEmpty ? "Clean" : filesSummary)</td>
            </tr>
            """
        }.joined(separator: "\n")

        let mergeRowsHTML = mergeReports.map { rep in
            let stateText = rep.unresolvedConflictCount == 0 ? "Auto-Merged Cleanly" : "\(rep.unresolvedConflictCount) Divergent Symbol(s)"
            let gitNote = rep.wouldGitLineMergeConflict ? "Rescued Git Line Conflict" : "Standard AST Pass"
            return """
            <tr>
              <td class="mono">\(escapeHTML(rep.relativePath))</td>
              <td>\(escapeHTML(rep.language.rawValue))</td>
              <td class="num">\(rep.autoMergedCount)</td>
              <td class="num">\(rep.unresolvedConflictCount)</td>
              <td>\(escapeHTML(stateText)) · \(escapeHTML(gitNote))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let spanRowsHTML = spans.map { s in
            return """
            <tr>
              <td class="mono">\(escapeHTML(s.laneID))</td>
              <td>\(escapeHTML(s.vendor.displayName))</td>
              <td class="mono">\(escapeHTML(s.modelIdentifier))</td>
              <td class="num">\(s.inputTokens)</td>
              <td class="num">\(s.cachedReadTokens)</td>
              <td class="num">\(s.outputTokens + s.reasoningTokens)</td>
              <td class="num">$\(String(format: "%.4f", s.costUSD))</td>
            </tr>
            """
        }.joined(separator: "\n")

        let findingRowsHTML = findings.map { f in
            return """
            <tr>
              <td class="mono">\(escapeHTML(f.severity.rawValue))</td>
              <td>\(escapeHTML(f.pluginName))</td>
              <td class="mono">\(escapeHTML(f.laneID ?? "workspace"))</td>
              <td><strong>\(escapeHTML(f.title)):</strong> \(escapeHTML(f.detail))</td>
            </tr>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="description" content="RelayIDE multi-vendor coding agent worktree matrix, declaration AST merge ledger, and wiretap spend dossier.">
          <title>RelayIDE Workspace Dossier: \(escapeHTML(stats.workspaceName))</title>
          <style>
            /* Hallmark · v2.0.0 · scope: app · genre: modern-minimal · posture: restrained · shape: app screen · surface: absolute */
            :root {
              --paper: #F4F2EC;
              --surface: #FDFCF9;
              --stone: #EAE6DC;
              --rule: #D6D1C4;
              --ink: #191816;
              --ink-muted: #57534E;
              --vermilion: #DA3C2A;
              --cobalt: #205DD1;
              --emerald: #188B5D;
              --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
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
              font-size: 0.82rem;
              font-weight: 600;
              color: var(--ink-muted);
              margin-bottom: 0.35rem;
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
            }
          </style>
        </head>
        <body>
          <main class="sheet">
            <header class="masthead">
              <div>
                <div class="kicker">RelayIDE Multi-Vendor Parallel Engineering Ledger</div>
                <h1>\(escapeHTML(stats.workspaceName))</h1>
              </div>
              <div class="mono">Schema v\(stats.schemaVersion) · SQLite WAL \(stats.sqliteBytes + stats.walBytes) B</div>
            </header>

            <section class="ledger-strip" aria-label="Workspace summary metrics">
              <div class="ledger-cell">
                <div class="ledger-label">Repository Root</div>
                <div class="ledger-val mono">\(escapeHTML((stats.repositoryPath as NSString).lastPathComponent))</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label">Isolated Lanes</div>
                <div class="ledger-val">\(stats.activeLaneCount)</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label">AST Auto-Merges</div>
                <div class="ledger-val">\(stats.semanticAutoMergeCount)</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label">Observed Tokens</div>
                <div class="ledger-val">\(stats.totalTokensObserved)</div>
              </div>
              <div class="ledger-cell">
                <div class="ledger-label">Wiretap Spend</div>
                <div class="ledger-val">$\(String(format: "%.4f", stats.totalSpendUSD))</div>
              </div>
            </section>

            <section>
              <h2>1. Isolated Git Worktree Matrix &amp; File Ownership Scopes</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>Lane ID</th>
                      <th>Assigned Agent</th>
                      <th>Branch</th>
                      <th>Allowed Globs</th>
                      <th>Working Tree Deltas</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(laneRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>

            <section>
              <h2>2. Declaration-Level 3-Way Semantic AST Merge Ledger</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>Relative Path</th>
                      <th>Language</th>
                      <th class="num">Auto-Merged</th>
                      <th class="num">Conflicts</th>
                      <th>Resolution Summary</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(mergeRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>

            <section>
              <h2>3. Loopback Wiretap Token &amp; USD Circuit-Breaker Telemetry</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>Lane</th>
                      <th>Vendor</th>
                      <th>Model</th>
                      <th class="num">Input</th>
                      <th class="num">Cached</th>
                      <th class="num">Output</th>
                      <th class="num">Cost (USD)</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(spanRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>

            <section>
              <h2>4. JavaScriptCore Guardrail Plugin Audit</h2>
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>Severity</th>
                      <th>Plugin</th>
                      <th>Scope</th>
                      <th>Finding</th>
                    </tr>
                  </thead>
                  <tbody>
                    \(findingRowsHTML)
                  </tbody>
                </table>
              </div>
            </section>
          </main>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
