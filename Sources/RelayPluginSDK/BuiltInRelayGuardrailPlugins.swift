import Foundation
import RelayModels

// MARK: - 4 Built-In Industrial Guardrail Plugins

public enum BuiltInRelayGuardrailPlugins {
    public static let all: [RelayPluginManifest] = [
        secretAndPathLeakBlocker,
        verificationTestGateEnforcer,
        conventionalCommitSynthesizer,
        tokenBudgetAnomalyAuditor
    ]

    public static let secretAndPathLeakBlocker = RelayPluginManifest(
        id: "io.relayide.secret-diff-blocker",
        name: "Secret & Local-Path Leak Blocker",
        version: "1.0.0",
        summary: "Vetoes merges containing API credentials (AWS/Anthropic/OpenAI/GitHub), private keys, or hardcoded /Users paths.",
        capabilities: [.inspectDiffs, .vetoMergeGate],
        scriptSource: #"""
        function runRelayGuardrail() {
            const diffs = RelayHost.getDiffs();
            const awsPrefix = "AK" + "IA";
            const ghPrefix = "gh" + "p_";
            const patterns = [
                { name: "Anthropic API Key", rx: /sk-ant-[A-Za-z0-9\-_]{16,}/ },
                { name: "OpenAI Project Key", rx: /sk-proj-[A-Za-z0-9\-_]{16,}/ },
                { name: "AWS Access Key ID", rx: new RegExp(awsPrefix + "[0-9A-Z]{16}") },
                { name: "GitHub Personal Token", rx: new RegExp(ghPrefix + "[A-Za-z0-9]{24,}") },
                { name: "PEM Private Key", rx: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/ },
                { name: "Hardcoded macOS User Path", rx: /\/Users\/[A-Za-z0-9._\-]+\// }
            ];
            for (const item of diffs) {
                for (const pat of patterns) {
                    if (pat.rx.test(item.content)) {
                        RelayHost.emitFinding(
                            "BLOCKER",
                            item.laneID,
                            item.path,
                            "Blocked " + pat.name + " in diff",
                            "Detected sensitive token or non-portable host path in " + item.path + " (" + item.laneID + ")."
                        );
                    }
                }
            }
        }
        """#
    )

    public static let verificationTestGateEnforcer = RelayPluginManifest(
        id: "io.relayide.test-gate-enforcer",
        name: "Test Coverage Gate Enforcer",
        version: "1.0.0",
        summary: "Checks that lanes introducing production declarations under Sources/ also contribute test suites under Tests/.",
        capabilities: [.inspectDiffs, .inspectASTNodes],
        scriptSource: #"""
        function runRelayGuardrail() {
            const diffs = RelayHost.getDiffs();
            const ast = RelayHost.getAST();
            const lanesWithSourceChanges = new Set();
            const lanesWithTestChanges = new Set();

            for (const d of diffs) {
                if (d.path.startsWith("Sources/") || d.path.startsWith("src/")) {
                    lanesWithSourceChanges.add(d.laneID);
                }
                if (d.path.startsWith("Tests/") || d.path.includes(".test.") || d.path.includes("_test.")) {
                    lanesWithTestChanges.add(d.laneID);
                }
            }

            for (const laneID of lanesWithSourceChanges) {
                if (!lanesWithTestChanges.has(laneID)) {
                    const count = ast.filter(n => n.laneID === laneID).length;
                    RelayHost.emitFinding(
                        "WARNING",
                        laneID,
                        "",
                        "Production AST modified without companion Tests/ update",
                        "Lane '" + laneID + "' modified " + count + " AST symbols under Sources/ without touching Tests/."
                    );
                }
            }
        }
        """#
    )

    public static let conventionalCommitSynthesizer = RelayPluginManifest(
        id: "io.relayide.conventional-commit-synthesizer",
        name: "AST Conventional Commit Synthesizer",
        version: "1.0.0",
        summary: "Synthesizes deterministic Conventional Commit titles from AST symbol deltas across merged agent lanes.",
        capabilities: [.inspectASTNodes, .synthesizeCommitMessage],
        scriptSource: #"""
        function runRelayGuardrail() {
            const nodes = RelayHost.getAST();
            if (nodes.length === 0) {
                RelayHost.proposeCommit("chore(relay): synchronize multi-agent workspace");
                return;
            }
            const symbols = Array.from(new Set(nodes.map(n => n.symbol))).slice(0, 3);
            const lanes = Array.from(new Set(nodes.map(n => n.laneID)));
            const scope = lanes.length === 1 ? lanes[0] : "multi-lane";
            const summary = "feat(" + scope + "): integrate " + symbols.join(", ");
            RelayHost.proposeCommit(summary);
            RelayHost.emitFinding(
                "PASS",
                "",
                "",
                "Synthesized Conventional Commit",
                summary
            );
        }
        """#
    )

    public static let tokenBudgetAnomalyAuditor = RelayPluginManifest(
        id: "io.relayide.budget-anomaly-auditor",
        name: "Wiretap Token & Cache Efficiency Auditor",
        version: "1.0.0",
        summary: "Flags lanes approaching their USD circuit ceiling or exhibiting < 15% prompt-cache reuse on large contexts.",
        capabilities: [.inspectTokenTelemetry],
        scriptSource: #"""
        function runRelayGuardrail() {
            const budgets = RelayHost.getBudgets();
            for (const b of budgets) {
                const ratio = b.ceilingUSD > 0 ? (b.spentUSD / b.ceilingUSD) : 0;
                if (b.circuitOpen || ratio >= 0.85) {
                    RelayHost.emitFinding(
                        "WARNING",
                        b.laneID,
                        "",
                        "High API spend utilization (" + Math.round(ratio * 100) + "%)",
                        "Lane '" + b.laneID + "' (" + b.vendor + ") spent $" + b.spentUSD.toFixed(3) + " of $" + b.ceilingUSD.toFixed(2) + " ceiling."
                    );
                }
                if (b.inputTokens >= 50000) {
                    const cacheShare = b.cachedTokens / b.inputTokens;
                    if (cacheShare < 0.15) {
                        RelayHost.emitFinding(
                            "ADVISORY",
                            b.laneID,
                            "",
                            "Low prompt-cache hit rate (" + Math.round(cacheShare * 100) + "%)",
                            "Consider pinning stable context prefixes in lane '" + b.laneID + "'."
                        );
                    }
                }
            }
        }
        """#
    )
}
