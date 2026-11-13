import Foundation
import JavaScriptCore
import RelayModels
import RelaySemanticMerge

// MARK: - Capability-Gated JavaScriptCore Guardrail Plugin Host

public struct RelayPluginRunOutput: Sendable, Codable, Hashable {
    public let pluginID: String
    public let elapsedMs: Double
    public let findings: [RelayGuardrailFinding]
    public let synthesizedCommitTitle: String?
    public let logs: [String]

    public init(
        pluginID: String,
        elapsedMs: Double,
        findings: [RelayGuardrailFinding],
        synthesizedCommitTitle: String? = nil,
        logs: [String] = []
    ) {
        self.pluginID = pluginID
        self.elapsedMs = elapsedMs
        self.findings = findings
        self.synthesizedCommitTitle = synthesizedCommitTitle
        self.logs = logs
    }
}

public final class RelayJavaScriptPluginHost: @unchecked Sendable {
    private let lock = NSLock()
    private var plugins: [RelayPluginManifest]
    private let astParser = MultiLanguageDeclarationParser()

    public init(plugins: [RelayPluginManifest] = BuiltInRelayGuardrailPlugins.all) {
        self.plugins = plugins
    }

    public func listPlugins() -> [RelayPluginManifest] {
        lock.lock()
        defer { lock.unlock() }
        return plugins
    }

    public func registerPlugin(_ manifest: RelayPluginManifest) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = plugins.firstIndex(where: { $0.id == manifest.id }) {
            plugins[idx] = manifest
        } else {
            plugins.append(manifest)
        }
    }

    public func setPluginEnabled(id: String, isEnabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = plugins.firstIndex(where: { $0.id == id }) {
            plugins[idx].isEnabled = isEnabled
        }
    }

    public func evaluateEnabledPlugins(
        modifiedFilesByLane: [String: [String: String]],
        budgetAccounts: [LaneBudgetAccount]
    ) throws -> [RelayPluginRunOutput] {
        let active = listPlugins().filter(\.isEnabled)
        return try active.map { manifest in
            try executeSinglePlugin(
                manifest: manifest,
                modifiedFilesByLane: modifiedFilesByLane,
                budgetAccounts: budgetAccounts
            )
        }
    }

    public func executeSinglePlugin(
        manifest: RelayPluginManifest,
        modifiedFilesByLane: [String: [String: String]],
        budgetAccounts: [LaneBudgetAccount]
    ) throws -> RelayPluginRunOutput {
        let startNs = DispatchTime.now().uptimeNanoseconds
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            throw RelayIDEError.pluginError(pluginID: manifest.id, reason: "Failed to initialize JavaScriptCore VM")
        }

        let allowedCaps = Set(manifest.capabilities)
        var capturedError: String?
        var findings: [RelayGuardrailFinding] = []
        var commitHeadline: String?
        var consoleLogs: [String] = []

        ctx.exceptionHandler = { _, exc in
            capturedError = exc?.toString() ?? "Unknown JS exception"
        }

        let logFn: @convention(block) (String) -> Void = { msg in
            consoleLogs.append(msg)
        }
        ctx.setObject(logFn, forKeyedSubscript: "__relayLog" as NSString)

        let getDiffsFn: @convention(block) () -> [[String: Any]] = {
            guard allowedCaps.contains(.inspectDiffs) else { return [] }
            var rows: [[String: Any]] = []
            for (laneID, files) in modifiedFilesByLane.sorted(by: { $0.key < $1.key }) {
                for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                    rows.append([
                        "laneID": laneID,
                        "path": path,
                        "content": content
                    ])
                }
            }
            return rows
        }
        ctx.setObject(getDiffsFn, forKeyedSubscript: "__relayGetDiffs" as NSString)

        let parser = self.astParser
        let getASTFn: @convention(block) () -> [[String: Any]] = {
            guard allowedCaps.contains(.inspectASTNodes) else { return [] }
            var items: [[String: Any]] = []
            for (laneID, files) in modifiedFilesByLane.sorted(by: { $0.key < $1.key }) {
                for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                    let lang = SourceLanguage.detect(fromPath: path)
                    let nodes = parser.parseDeclarations(source: content, language: lang)
                    for n in nodes where n.kind != .importGroup {
                        items.append([
                            "laneID": laneID,
                            "path": path,
                            "kind": n.kind.rawValue,
                            "symbol": n.symbolName
                        ])
                    }
                }
            }
            return items
        }
        ctx.setObject(getASTFn, forKeyedSubscript: "__relayGetAST" as NSString)

        let getBudgetsFn: @convention(block) () -> [[String: Any]] = {
            guard allowedCaps.contains(.inspectTokenTelemetry) else { return [] }
            return budgetAccounts.map { acc in
                [
                    "laneID": acc.laneID,
                    "vendor": acc.vendor.rawValue,
                    "inputTokens": acc.inputTokens,
                    "cachedTokens": acc.cachedTokens,
                    "outputTokens": acc.outputTokens,
                    "spentUSD": acc.spentUSD,
                    "ceilingUSD": acc.ceilingUSD,
                    "circuitOpen": acc.circuitOpen
                ]
            }
        }
        ctx.setObject(getBudgetsFn, forKeyedSubscript: "__relayGetBudgets" as NSString)

        let emitFindingFn: @convention(block) (String, String, String, String, String) -> Void = { sevStr, laneID, path, title, detail in
            let sev = GuardrailSeverity(rawValue: sevStr.uppercased()) ?? .advisory
            if sev == .blocker && !allowedCaps.contains(.vetoMergeGate) {
                capturedError = "Plugin lacks 'merge.veto' capability required to emit BLOCKER findings"
                return
            }
            findings.append(
                RelayGuardrailFinding(
                    pluginID: manifest.id,
                    pluginName: manifest.name,
                    severity: sev,
                    laneID: laneID.isEmpty ? nil : laneID,
                    relativePath: path.isEmpty ? nil : path,
                    title: title,
                    detail: detail
                )
            )
        }
        ctx.setObject(emitFindingFn, forKeyedSubscript: "__relayEmitFinding" as NSString)

        let proposeCommitFn: @convention(block) (String) -> Void = { headline in
            guard allowedCaps.contains(.synthesizeCommitMessage) else { return }
            commitHeadline = headline
        }
        ctx.setObject(proposeCommitFn, forKeyedSubscript: "__relayProposeCommit" as NSString)

        let prelude = """
        const RelayHost = Object.freeze({
            log: (msg) => __relayLog(String(msg)),
            getDiffs: () => __relayGetDiffs(),
            getAST: () => __relayGetAST(),
            getBudgets: () => __relayGetBudgets(),
            emitFinding: (severity, laneID, path, title, detail) =>
                __relayEmitFinding(String(severity), String(laneID || ""), String(path || ""), String(title), String(detail)),
            proposeCommit: (headline) => __relayProposeCommit(String(headline))
        });
        """
        _ = ctx.evaluateScript(prelude)
        _ = ctx.evaluateScript(manifest.scriptSource)
        if let entryFn = ctx.objectForKeyedSubscript("runRelayGuardrail"), !entryFn.isUndefined {
            _ = entryFn.call(withArguments: [])
        }

        if let err = capturedError {
            throw RelayIDEError.pluginError(pluginID: manifest.id, reason: err)
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        return RelayPluginRunOutput(
            pluginID: manifest.id,
            elapsedMs: elapsedMs,
            findings: findings,
            synthesizedCommitTitle: commitHeadline,
            logs: consoleLogs
        )
    }
}
