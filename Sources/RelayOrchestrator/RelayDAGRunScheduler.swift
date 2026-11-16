import Darwin
import Foundation
import RelayModels
import RelayPTYCore
import RelayWorkspaceStore
import RelayWorktreeGit

// MARK: - `.relay/LOG.md` Spend & Token Parser (`03-relayide.md` §11, matching `relay_util.py`)

public struct RelayLaneSpendReading: Sendable, Equatable {
    public let didAppendStepEntry: Bool
    public let stepID: String?
    public let costUSD: Double?
    public let tokens: Int?
    public let costSource: String

    public init(
        didAppendStepEntry: Bool,
        stepID: String? = nil,
        costUSD: Double? = nil,
        tokens: Int? = nil,
        costSource: String
    ) {
        self.didAppendStepEntry = didAppendStepEntry
        self.stepID = stepID
        self.costUSD = costUSD
        self.tokens = tokens
        self.costSource = costSource
    }
}

public enum RelayLogSpendParser {
    // Matches `relay_util.py` lines 121-125 verbatim:
    // HEADER = re.compile(r"^## (\S+?): (.*), (?:(\d+)s|done in-session by the conductor), (\d{4}-\d\d-\d\d \d\d:\d\d)$")
    // COST   = re.compile(r"\bcost \$([0-9]+(?:\.[0-9]+)?)")
    // TOKENS = re.compile(r"\btokens ([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)")
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"^## (\S+?): (.*), (?:(\d+)s|done in-session by the conductor), (\d{4}-\d\d-\d\d \d\d:\d\d)$"#
    )
    private static let costRegex = try! NSRegularExpression(
        pattern: #"\bcost \$([0-9]+(?:\.[0-9]+)?)"#
    )
    private static let tokensRegex = try! NSRegularExpression(
        pattern: #"\btokens ([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)"#
    )

    public static func currentFileByteLength(at logURL: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return max(0, size.intValue)
    }

    public static func parseStepSpend(
        fromLogFileAt logURL: URL,
        initialByteOffset: Int = 0
    ) -> RelayLaneSpendReading {
        guard let data = try? Data(contentsOf: logURL) else {
            return RelayLaneSpendReading(didAppendStepEntry: false, costUSD: nil, tokens: nil, costSource: "no_record")
        }
        let clampedOffset = max(0, initialByteOffset)
        guard data.count > clampedOffset else {
            return RelayLaneSpendReading(didAppendStepEntry: false, costUSD: nil, tokens: nil, costSource: "no_record")
        }
        let slice = data.subdata(in: clampedOffset..<data.count)
        let appendedMarkdown = String(decoding: slice, as: UTF8.self)
        return parseStepSpend(fromAppendedMarkdown: appendedMarkdown)
    }

    public static func parseStepSpend(fromAppendedMarkdown markdown: String) -> RelayLaneSpendReading {
        struct StepAcc {
            let stepID: String
            var costUSD: Double?
            var tokens: Int?
        }

        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var steps: [StepAcc] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            if let hMatch = headerRegex.firstMatch(in: line, options: [], range: fullRange),
               hMatch.numberOfRanges >= 2 {
                let idStr = nsLine.substring(with: hMatch.range(at: 1))
                steps.append(StepAcc(stepID: idStr, costUSD: nil, tokens: nil))
                continue
            }

            guard !steps.isEmpty, line.hasPrefix("- ") else { continue }
            let lastIdx = steps.count - 1

            if steps[lastIdx].costUSD == nil,
               let cMatch = costRegex.firstMatch(in: line, options: [], range: fullRange),
               cMatch.numberOfRanges >= 2 {
                let rawNum = nsLine.substring(with: cMatch.range(at: 1))
                if let parsed = Double(rawNum) {
                    steps[lastIdx].costUSD = parsed
                }
            }

            if steps[lastIdx].tokens == nil,
               let tMatch = tokensRegex.firstMatch(in: line, options: [], range: fullRange),
               tMatch.numberOfRanges >= 2 {
                let rawTok = nsLine.substring(with: tMatch.range(at: 1))
                    .replacingOccurrences(of: ",", with: "")
                if let parsedTok = Int(rawTok) {
                    steps[lastIdx].tokens = parsedTok
                }
            }
        }

        guard let last = steps.last else {
            return RelayLaneSpendReading(
                didAppendStepEntry: false,
                stepID: nil,
                costUSD: nil,
                tokens: nil,
                costSource: "no_record"
            )
        }

        if let usd = last.costUSD {
            return RelayLaneSpendReading(
                didAppendStepEntry: true,
                stepID: last.stepID,
                costUSD: usd,
                tokens: last.tokens,
                costSource: "usd"
            )
        } else if let tok = last.tokens {
            return RelayLaneSpendReading(
                didAppendStepEntry: true,
                stepID: last.stepID,
                costUSD: nil,
                tokens: tok,
                costSource: "unpriced"
            )
        } else {
            return RelayLaneSpendReading(
                didAppendStepEntry: true,
                stepID: last.stepID,
                costUSD: nil,
                tokens: nil,
                costSource: "no_record"
            )
        }
    }
}

// MARK: - `relay.sh` Exit / Signal Status Classifier (`03-relayide.md` §7, R32, R43)

public struct RelayClassifiedLaneOutcome: Sendable, Equatable {
    public let status: RelayRunStatus
    public let exitCode: Int32?
    public let signal: Int32?
    public let reason: String?

    public init(
        status: RelayRunStatus,
        exitCode: Int32?,
        signal: Int32?,
        reason: String?
    ) {
        self.status = status
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
    }
}

public enum RelayLaneOutcomeClassifier {
    private static let ansiCSIRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    public static func extractLastRelayRefusalLine(from ptyTranscript: String) -> String? {
        let normalized = ptyTranscript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lastRefusal: String?
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(rawLine)
            let range = NSRange(location: 0, length: (lineStr as NSString).length)
            let cleaned = ansiCSIRegex.stringByReplacingMatches(in: lineStr, options: [], range: range, withTemplate: "")
            guard cleaned.hasPrefix("relay: ") else { continue }
            if cleaned.hasPrefix("relay: warning:") || cleaned.hasPrefix("relay: note:") {
                continue
            }
            lastRefusal = cleaned
        }
        return lastRefusal
    }

    public static func classify(
        termination: PTYExitReason,
        ptyTranscript: String,
        didAppendLogStep: Bool,
        language: RelayLanguage
    ) -> RelayClassifiedLaneOutcome {
        switch termination {
        case .exited(code: 0):
            return RelayClassifiedLaneOutcome(status: .succeeded, exitCode: 0, signal: nil, reason: nil)
        case .exited(code: 5):
            return RelayClassifiedLaneOutcome(status: .partial, exitCode: 5, signal: nil, reason: nil)
        case .exited(code: 124):
            return RelayClassifiedLaneOutcome(status: .timeout, exitCode: 124, signal: nil, reason: nil)
        case .exited(code: 2):
            if didAppendLogStep {
                let reason = RelayLocalizer.select(language, "failed (exit 2)", "失败（退出码 2）")
                return RelayClassifiedLaneOutcome(status: .failed, exitCode: 2, signal: nil, reason: reason)
            } else {
                let refusal = extractLastRelayRefusalLine(from: ptyTranscript)
                    ?? RelayLocalizer.select(language, "relay: refused (exit 2)", "relay: 被拒绝（退出码 2）")
                return RelayClassifiedLaneOutcome(status: .refused, exitCode: 2, signal: nil, reason: refusal)
            }
        case .exited(code: let code):
            let reason = RelayLocalizer.select(language, "failed (exit \(code))", "失败（退出码 \(code)）")
            return RelayClassifiedLaneOutcome(status: .failed, exitCode: code, signal: nil, reason: reason)
        case .signaled(signal: let sig):
            let reason = RelayLocalizer.select(language, "failed (signal \(sig))", "失败（信号 \(sig)）")
            return RelayClassifiedLaneOutcome(status: .failed, exitCode: nil, signal: sig, reason: reason)
        case .waitFailed(errnoCode: let errCode):
            let reason = RelayLocalizer.select(
                language,
                "failed (waitpid errno \(errCode))",
                "失败（waitpid errno \(errCode)）"
            )
            return RelayClassifiedLaneOutcome(status: .failed, exitCode: nil, signal: nil, reason: reason)
        }
    }
}

// MARK: - Cancellation & Per-Lane Hard-Limit Policy (`03-relayide.md` §7, §8, R42)

public struct RelayCancellationPolicy: Sendable, Equatable {
    public static let defaultSigintGraceSeconds: TimeInterval = 10.0
    public static let defaultSigtermGraceSeconds: TimeInterval = 5.0
    public static let defaultRelayTimeoutSeconds: TimeInterval = 1800.0
    public static let defaultHardLimitSlackSeconds: TimeInterval = 60.0

    public var sigintGraceSeconds: TimeInterval
    public var sigtermGraceSeconds: TimeInterval
    public var defaultRelayTimeoutSeconds: TimeInterval
    public var hardLimitSlackSeconds: TimeInterval
    public var hardLimitOverrideSeconds: TimeInterval?

    public static let `default` = RelayCancellationPolicy()

    public init(
        sigintGraceSeconds: TimeInterval = RelayCancellationPolicy.defaultSigintGraceSeconds,
        sigtermGraceSeconds: TimeInterval = RelayCancellationPolicy.defaultSigtermGraceSeconds,
        defaultRelayTimeoutSeconds: TimeInterval = RelayCancellationPolicy.defaultRelayTimeoutSeconds,
        hardLimitSlackSeconds: TimeInterval = RelayCancellationPolicy.defaultHardLimitSlackSeconds,
        hardLimitOverrideSeconds: TimeInterval? = nil
    ) {
        self.sigintGraceSeconds = sigintGraceSeconds
        self.sigtermGraceSeconds = sigtermGraceSeconds
        self.defaultRelayTimeoutSeconds = defaultRelayTimeoutSeconds
        self.hardLimitSlackSeconds = hardLimitSlackSeconds
        self.hardLimitOverrideSeconds = hardLimitOverrideSeconds
    }

    public func effectiveHardLimitSeconds(environment: [String: String]) -> TimeInterval {
        if let override = hardLimitOverrideSeconds {
            return max(0.01, override)
        }
        let baseTimeout: TimeInterval
        if let raw = environment["RELAY_TIMEOUT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = TimeInterval(raw),
           parsed.isFinite,
           parsed > 0 {
            baseTimeout = parsed
        } else {
            baseTimeout = defaultRelayTimeoutSeconds
        }
        return baseTimeout + hardLimitSlackSeconds
    }
}

// MARK: - Active Per-Lane Process Handle & Thread-Safe Registry (`03-relayide.md` §7, §8, R42)

/// Holds a live lane's `POSIXPseudoTerminalSession` and process group leader `pid` (`POSIX_SPAWN_SETSID` sets `pgid == pid`).
/// Used by `RelayActiveLaneRegistry` and `RelayDAGRunScheduler` during `SIGINT`/`SIGTERM` cancellation, hard limits, and `125` aborts.
public struct RelayActiveLaneProcess: @unchecked Sendable {
    public let runID: String
    public let laneID: String
    public let agent: RelayPlanAgent
    public let session: POSIXPseudoTerminalSession
    public let pid: pid_t
    public let worktreeURL: URL
    public let branchName: String
    public let ptyTranscriptURL: URL
    public let startedAt: Date

    public init(
        runID: String,
        laneID: String,
        agent: RelayPlanAgent,
        session: POSIXPseudoTerminalSession,
        pid: pid_t,
        worktreeURL: URL,
        branchName: String,
        ptyTranscriptURL: URL,
        startedAt: Date
    ) {
        self.runID = runID
        self.laneID = laneID
        self.agent = agent
        self.session = session
        self.pid = pid
        self.worktreeURL = worktreeURL
        self.branchName = branchName
        self.ptyTranscriptURL = ptyTranscriptURL
        self.startedAt = startedAt
    }
}

public final class RelayActiveLaneRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeByLaneID: [String: RelayActiveLaneProcess] = [:]
    private var cancelledLaneIDs: Set<String> = []
    private var killedByHardLimitLaneIDs: Set<String> = []
    private var runCancellingFlag: Bool = false
    private var cancellationSignalValue: Int32?
    private var cancellationHandler: (@Sendable (Int32) -> Void)?

    public init() {}

    /// Registers an active lane process and atomically returns `true` if run cancellation or fatal abort is already in progress.
    @discardableResult
    public func register(_ process: RelayActiveLaneProcess) -> Bool {
        lock.lock()
        activeByLaneID[process.laneID] = process
        let alreadyCancelling = runCancellingFlag
        if cancellationSignalValue != nil && !killedByHardLimitLaneIDs.contains(process.laneID) {
            cancelledLaneIDs.insert(process.laneID)
        }
        lock.unlock()
        return alreadyCancelling
    }

    @discardableResult
    public func unregister(laneID: String) -> RelayActiveLaneProcess? {
        lock.lock()
        defer { lock.unlock() }
        return activeByLaneID.removeValue(forKey: laneID)
    }

    public func activeProcess(forLaneID laneID: String) -> RelayActiveLaneProcess? {
        lock.lock()
        defer { lock.unlock() }
        return activeByLaneID[laneID]
    }

    public func snapshotActiveProcesses() -> [RelayActiveLaneProcess] {
        lock.lock()
        defer { lock.unlock() }
        return activeByLaneID.keys.sorted().compactMap { activeByLaneID[$0] }
    }

    public var isRunCancelling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return runCancellingFlag
    }

    public var cancellationSignal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationSignalValue
    }

    public func markRunCancelling() {
        lock.lock()
        runCancellingFlag = true
        lock.unlock()
    }

    public func markLaneCancelled(_ laneID: String) {
        lock.lock()
        cancelledLaneIDs.insert(laneID)
        lock.unlock()
    }

    public func isLaneCancelled(_ laneID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledLaneIDs.contains(laneID)
    }

    public func markLaneKilledByHardLimit(_ laneID: String) {
        lock.lock()
        killedByHardLimitLaneIDs.insert(laneID)
        lock.unlock()
    }

    public func isLaneKilledByHardLimit(_ laneID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return killedByHardLimitLaneIDs.contains(laneID)
    }

    public func setCancellationHandler(_ handler: (@Sendable (Int32) -> Void)?) {
        var existingSignal: Int32?
        lock.lock()
        cancellationHandler = handler
        if handler != nil {
            existingSignal = cancellationSignalValue
        }
        lock.unlock()
        if let sig = existingSignal {
            handler?(sig)
        }
    }

    public func requestCancellation(signal: Int32) {
        var handlerToCall: (@Sendable (Int32) -> Void)?
        lock.lock()
        if cancellationSignalValue == nil {
            cancellationSignalValue = signal
            runCancellingFlag = true
            for laneID in activeByLaneID.keys where !killedByHardLimitLaneIDs.contains(laneID) {
                cancelledLaneIDs.insert(laneID)
            }
            handlerToCall = cancellationHandler
        }
        lock.unlock()
        handlerToCall?(signal)
    }
}

// MARK: - Event-Driven Single-Predecessor DAG Scheduler (`03-relayide.md` §4–§7, §10–§11, §13; R36, R38, R46, R47, R49)

public struct RelayDAGRunSchedulerResult: Sendable {
    public let runRecord: RelayRunRecord
    public let cliExitCode: Int32

    public init(runRecord: RelayRunRecord, cliExitCode: Int32) {
        self.runRecord = runRecord
        self.cliExitCode = cliExitCode
    }
}

public struct RelayLanePhaseSummary: Sendable, Equatable {
    public let orderedLanes: [RelayRunLaneRecord]
    public let runStatus: RelayRunStatus
    public let runReason: String?
    public let cancellationSignal: Int32?

    public init(
        orderedLanes: [RelayRunLaneRecord],
        runStatus: RelayRunStatus,
        runReason: String?,
        cancellationSignal: Int32?
    ) {
        self.orderedLanes = orderedLanes
        self.runStatus = runStatus
        self.runReason = runReason
        self.cancellationSignal = cancellationSignal
    }
}

/// Standalone M1 `run` scheduler. Intentionally never instantiates `MultiVendorDAGOrchestrator` (R49).
public final class RelayDAGRunScheduler: @unchecked Sendable {
    public let runID: String
    public let validatedPlan: RelayValidatedRunPlan
    public let relayScript: ResolvedRelayScript
    public let runDirectoryURL: URL
    public let projectBundleURL: URL
    public let database: RelayProjectDatabase
    public let gitEngine: GitWorktreePlumbingEngine
    public let language: RelayLanguage
    public let environment: [String: String]
    public let activeLaneRegistry: RelayActiveLaneRegistry
    public let cancellationPolicy: RelayCancellationPolicy
    public let emitStderrLine: @Sendable (String) -> Void

    private enum EscalationContext: Sendable {
        case signalCancellation
        case hardLimit
        case fatalInternalError
    }

    private struct SchedulerCancellationSkip: Error {}

    private final class LaneEscalationHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func finish() {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending {
                waiter.resume()
            }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if completed {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    /// Enforces strictly at most one `git worktree add -b` running at a time (`03-relayide.md` §4).
    private let worktreeSerialQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.run.worktree-serial")
    private let stateLock = NSLock()
    private var laneRecordsByID: [String: RelayRunLaneRecord] = [:]
    private var escalationHandlesByLaneID: [String: LaneEscalationHandle] = [:]
    private var firstFatalError: RelayIDEError?
    private let childrenByPredecessor: [String: [RelayValidatedLaneSpec]]
    private let rootLanes: [RelayValidatedLaneSpec]

    public init(
        runID: String,
        validatedPlan: RelayValidatedRunPlan,
        relayScript: ResolvedRelayScript,
        runDirectoryURL: URL,
        projectBundleURL: URL,
        database: RelayProjectDatabase,
        gitEngine: GitWorktreePlumbingEngine = GitWorktreePlumbingEngine(),
        language: RelayLanguage,
        environment: [String: String],
        activeLaneRegistry: RelayActiveLaneRegistry = RelayActiveLaneRegistry(),
        cancellationPolicy: RelayCancellationPolicy = .default,
        emitStderrLine: @escaping @Sendable (String) -> Void
    ) {
        self.runID = runID
        self.validatedPlan = validatedPlan
        self.relayScript = relayScript
        self.runDirectoryURL = runDirectoryURL
        self.projectBundleURL = projectBundleURL
        self.database = database
        self.gitEngine = gitEngine
        self.language = language
        self.environment = environment
        self.activeLaneRegistry = activeLaneRegistry
        self.cancellationPolicy = cancellationPolicy
        self.emitStderrLine = emitStderrLine

        var records: [String: RelayRunLaneRecord] = [:]
        var children: [String: [RelayValidatedLaneSpec]] = [:]
        var roots: [RelayValidatedLaneSpec] = []
        for spec in validatedPlan.lanes {
            records[spec.id] = RelayRunLaneRecord(
                runID: runID,
                laneID: spec.id,
                ordinal: spec.ordinal,
                agent: spec.agent,
                promptPath: spec.resolvedPromptURL.path,
                after: spec.after,
                status: .pending
            )
            if let pred = spec.after.first {
                children[pred, default: []].append(spec)
            } else {
                roots.append(spec)
            }
        }
        self.laneRecordsByID = records
        self.childrenByPredecessor = children
        self.rootLanes = roots
    }

    public func run(
        afterLanesPhase: ((RelayLanePhaseSummary) async throws -> Void)? = nil
    ) async throws -> RelayDAGRunSchedulerResult {
        do {
            let laneSummary = try await executeLanesPhase()
            if let afterLanesPhase {
                try await afterLanesPhase(laneSummary)
            }
            return try persistTerminalRunStatus(afterIntegration: laneSummary)
        } catch let relayErr as RelayIDEError {
            persistFatalErrorRunStatus(relayErr)
            throw relayErr
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            persistFatalErrorRunStatus(wrapped)
            throw wrapped
        }
    }

    /// Executes all DAG lanes until every lane reaches a terminal state in `relay_run_lanes`,
    /// intentionally keeping `relay_runs.status == .running` (`finished_at == NULL`) so M2 integration
    /// and `verify` execute before terminal run status is persisted (`03-relayide.md` M2 §7, R61).
    public func executeLanesPhase() async throws -> RelayLanePhaseSummary {
        let lanesDirURL = runDirectoryURL.appendingPathComponent("lanes", isDirectory: true)
        try FileManager.default.createDirectory(at: lanesDirURL, withIntermediateDirectories: true)

        activeLaneRegistry.setCancellationHandler { [weak self] sig in
            self?.handleRunCancellationSignal(sig)
        }
        defer {
            activeLaneRegistry.setCancellationHandler(nil)
        }

        await withTaskGroup(of: Void.self) { group in
            for rootSpec in rootLanes {
                let baseOID = validatedPlan.baseCommitOID
                group.addTask {
                    await self.executeSubtree(rootedAt: rootSpec, startCommitOID: baseOID)
                }
            }
            await group.waitForAll()
        }

        await waitForAllOngoingEscalations()

        if let fatal = currentFatalError() {
            reconcileNonTerminalLanesOnFatalError(fatal)
            throw fatal
        }

        if let cancelSig = activeLaneRegistry.cancellationSignal {
            let isZh = language.isChinese
            let sigName = Self.signalDisplayName(cancelSig)
            let skipReason = isZh ? "已跳过（运行被取消）" : "skipped (run cancelled)"
            let runCancelReason = isZh
                ? "已取消（收到 \(sigName)）"
                : "cancelled (received \(sigName))"
            let now = Date()

            for record in snapshotOrderedLaneRecords() where !record.status.isTerminal {
                var skipped = record
                skipped.status = .skipped
                skipped.exitCode = nil
                skipped.signal = nil
                skipped.reason = skipReason
                skipped.startedAt = nil
                skipped.finishedAt = now
                skipped.pid = nil
                skipped.costUSD = nil
                skipped.tokens = nil
                skipped.costSource = nil
                skipped.branch = nil
                skipped.commitOID = nil
                skipped.worktreePath = nil
                skipped.uncommittedFiles = nil
                try persistLaneRecord(skipped)

                let skipLine = isZh
                    ? "[relay] 通道 \(skipped.laneID) (\(skipped.agent.rawValue)) 已跳过 · \(skipReason)"
                    : "[relay] lane \(skipped.laneID) (\(skipped.agent.rawValue)) skipped · \(skipReason)"
                emitStderrLine(skipLine)
            }

            return RelayLanePhaseSummary(
                orderedLanes: snapshotOrderedLaneRecords(),
                runStatus: .cancelled,
                runReason: runCancelReason,
                cancellationSignal: cancelSig
            )
        }

        let orderedLanes = snapshotOrderedLaneRecords()
        let overallStatus = Self.computeOverallRunStatus(from: orderedLanes)
        return RelayLanePhaseSummary(
            orderedLanes: orderedLanes,
            runStatus: overallStatus,
            runReason: nil,
            cancellationSignal: nil
        )
    }

    /// Writes the terminal `relay_runs` status and `finished_at` AFTER the post-lane integration / `verify` phase (R61).
    public func persistTerminalRunStatus(
        afterIntegration laneSummary: RelayLanePhaseSummary,
        overrideStatus: RelayRunStatus? = nil,
        overrideReason: String? = nil,
        cliExitCodeOverride: Int32? = nil
    ) throws -> RelayDAGRunSchedulerResult {
        let finalStatus = overrideStatus ?? laneSummary.runStatus
        let finalReason = overrideReason ?? laneSummary.runReason
        try database.updateRunStatus(
            runID: runID,
            status: finalStatus,
            reason: finalReason,
            finishedAt: Date()
        )

        guard let persisted = try database.fetchRun(runID: runID, reconcileWithLock: false) else {
            throw RelayIDEError.relayEnvironmentFailure("Persisted run '\(runID)' missing after completion")
        }

        let cliExitCode: Int32
        if let explicitExit = cliExitCodeOverride {
            cliExitCode = explicitExit
        } else if let cancelSig = laneSummary.cancellationSignal {
            cliExitCode = (cancelSig == SIGTERM) ? 143 : 130
        } else {
            let allSucceeded = laneSummary.orderedLanes.allSatisfy {
                $0.status == .succeeded || $0.status == .succeededNoChanges
            }
            cliExitCode = allSucceeded ? 0 : 1
        }
        return RelayDAGRunSchedulerResult(runRecord: persisted, cliExitCode: cliExitCode)
    }

    public func persistFatalErrorRunStatus(_ error: RelayIDEError) {
        reconcileAbortedRunOnFatalError(error)
    }

    public static func computeOverallRunStatus(from lanes: [RelayRunLaneRecord]) -> RelayRunStatus {
        if lanes.allSatisfy({ $0.status == .succeeded || $0.status == .succeededNoChanges }) {
            return .succeeded
        }
        if lanes.contains(where: { $0.status == .interrupted }) {
            return .interrupted
        }
        if lanes.contains(where: { $0.status == .cancelled }) {
            return .cancelled
        }
        let onlySuccessPartialOrSkipped = lanes.allSatisfy {
            $0.status == .succeeded || $0.status == .succeededNoChanges || $0.status == .partial || $0.status == .skipped
        }
        if onlySuccessPartialOrSkipped && lanes.contains(where: { $0.status == .partial }) {
            return .partial
        }
        return .failed
    }

    // MARK: - Recursive Event-Driven Subtree Execution (Zero Wave Barriers)

    private func executeSubtree(rootedAt spec: RelayValidatedLaneSpec, startCommitOID: String) async {
        guard currentFatalError() == nil, !activeLaneRegistry.isRunCancelling else {
            return
        }

        let outcomeOpt = await executeSingleLane(spec: spec, startCommitOID: startCommitOID)
        guard let outcome = outcomeOpt, currentFatalError() == nil else {
            return
        }

        let directChildren = childrenByPredecessor[spec.id] ?? []
        guard !directChildren.isEmpty else { return }

        if outcome.record.status == .succeeded || outcome.record.status == .succeededNoChanges {
            guard !activeLaneRegistry.isRunCancelling, currentFatalError() == nil else {
                return
            }
            let nextBaseOID = outcome.headCommitOID
            await withTaskGroup(of: Void.self) { childGroup in
                for childSpec in directChildren {
                    childGroup.addTask {
                        await self.executeSubtree(rootedAt: childSpec, startCommitOID: nextBaseOID)
                    }
                }
                await childGroup.waitForAll()
            }
        } else if activeLaneRegistry.cancellationSignal == nil && currentFatalError() == nil {
            markSubtreeSkipped(
                children: directChildren,
                failedPredecessorID: spec.id,
                failedPredecessorStatus: outcome.record.status
            )
        }
    }

    private struct SingleLaneCompletion {
        let record: RelayRunLaneRecord
        let headCommitOID: String
    }

    private func createLaneWorktreeSerially(
        spec: RelayValidatedLaneSpec,
        startCommitOID: String,
        worktreesRootPath: String
    ) async throws -> ManagedWorktreeLane {
        try await withCheckedThrowingContinuation { continuation in
            worktreeSerialQueue.async {
                do {
                    if let fatal = self.currentFatalError() {
                        throw fatal
                    }
                    if self.activeLaneRegistry.isRunCancelling {
                        throw SchedulerCancellationSkip()
                    }
                    let wt = try self.gitEngine.createLaneWorktree(
                        repositoryPath: self.validatedPlan.resolvedRepoURL.path,
                        runID: self.runID,
                        laneID: spec.id,
                        displayName: spec.id,
                        vendor: spec.agent.agentVendor,
                        baseRef: startCommitOID,
                        worktreesRootDirectory: worktreesRootPath,
                        environment: self.environment
                    )
                    continuation.resume(returning: wt)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeSingleLane(
        spec: RelayValidatedLaneSpec,
        startCommitOID: String
    ) async -> SingleLaneCompletion? {
        let worktreesRootURL = runDirectoryURL.appendingPathComponent("worktrees", isDirectory: true)
        let ptyURL = runDirectoryURL
            .appendingPathComponent("lanes", isDirectory: true)
            .appendingPathComponent("\(spec.id).pty")

        do {
            // 1. Serially create worktree `<project>/runs/<runID>/worktrees/<lane>` and branch `relay/<runID>/<lane>` (`-b`, never `-B`)
            let managedWT = try await createLaneWorktreeSerially(
                spec: spec,
                startCommitOID: startCommitOID,
                worktreesRootPath: worktreesRootURL.path
            )

            let worktreeURL = URL(fileURLWithPath: managedWT.worktreePath).standardizedFileURL
            let logURL = worktreeURL.appendingPathComponent(".relay/LOG.md")
            let initialLogOffset = RelayLogSpendParser.currentFileByteLength(at: logURL)

            // Guard narrow window where cancellation or fatal error arrived right after worktree creation before spawn
            if currentFatalError() != nil {
                var abortedRecord = snapshotLaneRecord(for: spec.id)
                abortedRecord.status = .running
                abortedRecord.startedAt = Date()
                abortedRecord.branch = managedWT.branchName
                abortedRecord.worktreePath = worktreeURL.path
                try? persistLaneRecord(abortedRecord)
                return nil
            }
            if let cancelSig = activeLaneRegistry.cancellationSignal {
                let now = Date()
                let isZh = language.isChinese
                let sigName = Self.signalDisplayName(cancelSig)
                var preSpawnCancelled = snapshotLaneRecord(for: spec.id)
                preSpawnCancelled.status = .cancelled
                preSpawnCancelled.reason = isZh ? "已取消（收到 \(sigName)）" : "cancelled (received \(sigName))"
                preSpawnCancelled.startedAt = now
                preSpawnCancelled.finishedAt = now
                preSpawnCancelled.costSource = "no_record"
                preSpawnCancelled.branch = managedWT.branchName
                preSpawnCancelled.worktreePath = worktreeURL.path
                preSpawnCancelled.commitOID = nil
                preSpawnCancelled.uncommittedFiles = (try? gitEngine.listUncommittedFilesExcludingRelay(
                    in: worktreeURL.path,
                    environment: environment
                )) ?? []
                try persistLaneRecord(preSpawnCancelled)
                emitStderrLine(formatFinishLine(record: preSpawnCancelled, startedAt: now, finishedAt: now))
                return SingleLaneCompletion(record: preSpawnCancelled, headCommitOID: startCommitOID)
            }

            // 2. Spawn `<relay.sh> <agent> <worktree-abs-path> <prompt-abs-path>` inside a real PTY
            let session = POSIXPseudoTerminalSession(laneID: spec.id)
            try session.spawn(
                executablePath: relayScript.url.standardizedFileURL.path,
                arguments: [
                    spec.agent.rawValue,
                    worktreeURL.path,
                    spec.resolvedPromptURL.standardizedFileURL.path
                ],
                workingDirectory: worktreeURL.path,
                baseEnvironment: environment,
                rawOutputFilePath: ptyURL.path
            )

            let childPID = session.childProcessID
            let startedAt = Date()
            let activeProc = RelayActiveLaneProcess(
                runID: runID,
                laneID: spec.id,
                agent: spec.agent,
                session: session,
                pid: childPID,
                worktreeURL: worktreeURL,
                branchName: managedWT.branchName,
                ptyTranscriptURL: ptyURL,
                startedAt: startedAt
            )
            let alreadyCancelling = activeLaneRegistry.register(activeProc)
            defer { activeLaneRegistry.unregister(laneID: spec.id) }

            var runningRecord = snapshotLaneRecord(for: spec.id)
            runningRecord.status = .running
            runningRecord.startedAt = startedAt
            runningRecord.pid = childPID > 0 ? childPID : nil
            runningRecord.branch = managedWT.branchName
            runningRecord.worktreePath = worktreeURL.path
            try persistLaneRecord(runningRecord)
            emitStderrLine(formatStartLine(spec: spec, pid: childPID, branchName: managedWT.branchName))

            if alreadyCancelling {
                let ctx: EscalationContext = (activeLaneRegistry.cancellationSignal != nil)
                    ? .signalCancellation
                    : .fatalInternalError
                startEscalationOnce(for: activeProc, context: ctx)
            }

            // Arm per-lane hard time limit (`RELAY_TIMEOUT + 60s` by default, or injected test override)
            let hardLimitSeconds = cancellationPolicy.effectiveHardLimitSeconds(environment: environment)
            let timerQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.run.hardlimit.\(spec.id)")
            let hardLimitTimer = DispatchSource.makeTimerSource(queue: timerQueue)
            hardLimitTimer.schedule(deadline: .now() + hardLimitSeconds)
            hardLimitTimer.setEventHandler { [weak self] in
                guard let self else { return }
                guard self.currentFatalError() == nil,
                      !self.activeLaneRegistry.isRunCancelling,
                      session.metrics().isRunning else {
                    return
                }
                self.activeLaneRegistry.markLaneKilledByHardLimit(spec.id)
                let isZh = self.language.isChinese
                let limitStr = String(format: "%.2fs", hardLimitSeconds)
                let note = isZh
                    ? "[relay] 通道 \(spec.id) (\(spec.agent.rawValue)) 超过硬上限（\(limitStr)），正在结束进程..."
                    : "[relay] lane \(spec.id) (\(spec.agent.rawValue)) exceeded hard time limit (\(limitStr)); terminating..."
                self.emitStderrLine(note)
                self.startEscalationOnce(for: activeProc, context: .hardLimit)
            }
            hardLimitTimer.resume()
            defer {
                hardLimitTimer.setEventHandler {}
                hardLimitTimer.cancel()
            }

            // 3. Wait asynchronously for PTY exit, full transcript flush, and any escalation descendant drain
            let exitReason = await session.awaitExit()
            await awaitEscalationIfAny(forLaneID: spec.id)
            let finishedAt = Date()

            // If a sibling lane triggered a fatal internal RelayIDE error (125), unwind immediately without committing
            if currentFatalError() != nil {
                return nil
            }

            // 4. Read `.pty` transcript, parse `.relay/LOG.md` spend, and classify outcome
            let ptyData = (try? Data(contentsOf: ptyURL)) ?? Data()
            let ptyText = String(decoding: ptyData, as: UTF8.self)
            let spend = RelayLogSpendParser.parseStepSpend(
                fromLogFileAt: logURL,
                initialByteOffset: initialLogOffset
            )
            let baseClassified = RelayLaneOutcomeClassifier.classify(
                termination: exitReason,
                ptyTranscript: ptyText,
                didAppendLogStep: spend.didAppendStepEntry,
                language: language
            )

            let effectiveOutcome: RelayClassifiedLaneOutcome
            if activeLaneRegistry.isLaneKilledByHardLimit(spec.id) {
                let isZh = language.isChinese
                effectiveOutcome = RelayClassifiedLaneOutcome(
                    status: .killed,
                    exitCode: exitReason.exitCode,
                    signal: exitReason.terminationSignal,
                    reason: isZh ? "被强制结束（超过硬上限）" : "killed (exceeded hard time limit)"
                )
            } else if activeLaneRegistry.isLaneCancelled(spec.id) || activeLaneRegistry.cancellationSignal != nil {
                let isZh = language.isChinese
                let sigName = Self.signalDisplayName(activeLaneRegistry.cancellationSignal ?? SIGINT)
                effectiveOutcome = RelayClassifiedLaneOutcome(
                    status: .cancelled,
                    exitCode: exitReason.exitCode,
                    signal: exitReason.terminationSignal,
                    reason: isZh ? "已取消（收到 \(sigName)）" : "cancelled (received \(sigName))"
                )
            } else {
                effectiveOutcome = baseClassified
            }

            var finalStatus = effectiveOutcome.status
            var commitOID: String? = nil
            var uncommittedFiles: [String]? = nil
            var headCommitForSuccessors = startCommitOID

            // 5. Commit ONLY on `.succeeded` and `.partial` (`--no-verify`, `:(exclude).relay`); never commit cancelled/killed/failed
            if effectiveOutcome.status == .succeeded || effectiveOutcome.status == .partial {
                let commitResult = try gitEngine.commitLaneChangesIfNeeded(
                    worktreePath: worktreeURL.path,
                    startCommitOID: startCommitOID,
                    runID: runID,
                    laneID: spec.id,
                    agent: spec.agent,
                    status: effectiveOutcome.status,
                    environment: environment
                )
                switch commitResult {
                case .committed(let oid):
                    commitOID = oid
                    headCommitForSuccessors = oid
                case .preservedExistingCommits(let headOID):
                    commitOID = headOID
                    headCommitForSuccessors = headOID
                case .noChanges(let headOID):
                    commitOID = nil
                    headCommitForSuccessors = headOID
                    if effectiveOutcome.status == .succeeded {
                        finalStatus = .succeededNoChanges
                    }
                }
            } else {
                uncommittedFiles = try gitEngine.listUncommittedFilesExcludingRelay(
                    in: worktreeURL.path,
                    environment: environment
                )
            }

            var completedRecord = runningRecord
            completedRecord.status = finalStatus
            completedRecord.exitCode = effectiveOutcome.exitCode
            completedRecord.signal = effectiveOutcome.signal
            completedRecord.reason = effectiveOutcome.reason
            completedRecord.finishedAt = finishedAt
            completedRecord.costUSD = spend.costUSD
            completedRecord.tokens = spend.tokens
            completedRecord.costSource = spend.costSource
            completedRecord.commitOID = commitOID
            completedRecord.uncommittedFiles = uncommittedFiles

            try persistLaneRecord(completedRecord)
            emitStderrLine(formatFinishLine(record: completedRecord, startedAt: startedAt, finishedAt: finishedAt))
            return SingleLaneCompletion(record: completedRecord, headCommitOID: headCommitForSuccessors)
        } catch is SchedulerCancellationSkip {
            return nil
        } catch let relayErr as RelayIDEError {
            recordFatalInternalError(relayErr)
            return nil
        } catch {
            recordFatalInternalError(.relayEnvironmentFailure(error.localizedDescription))
            return nil
        }
    }

    private func markSubtreeSkipped(
        children: [RelayValidatedLaneSpec],
        failedPredecessorID: String,
        failedPredecessorStatus: RelayRunStatus
    ) {
        let isZh = language.isChinese
        for childSpec in children {
            guard currentFatalError() == nil else { return }
            let skipReason = isZh
                ? "已跳过：前置通道 '\(failedPredecessorID)' 状态为\(failedPredecessorStatus.localizedLabel(in: .zhHans))（\(failedPredecessorStatus.rawValue)）"
                : "skipped: predecessor '\(failedPredecessorID)' finished with status \(failedPredecessorStatus.rawValue)"

            var skippedRecord = snapshotLaneRecord(for: childSpec.id)
            skippedRecord.status = .skipped
            skippedRecord.exitCode = nil
            skippedRecord.signal = nil
            skippedRecord.reason = skipReason
            skippedRecord.startedAt = nil
            skippedRecord.finishedAt = Date()
            skippedRecord.pid = nil
            skippedRecord.costUSD = nil
            skippedRecord.tokens = nil
            skippedRecord.costSource = nil
            skippedRecord.branch = nil
            skippedRecord.commitOID = nil
            skippedRecord.worktreePath = nil
            skippedRecord.uncommittedFiles = nil

            do {
                try persistLaneRecord(skippedRecord)
            } catch let relayErr as RelayIDEError {
                recordFatalInternalError(relayErr)
                return
            } catch {
                recordFatalInternalError(.relayEnvironmentFailure(error.localizedDescription))
                return
            }

            let skipLine = isZh
                ? "[relay] 通道 \(childSpec.id) (\(childSpec.agent.rawValue)) 已跳过 · \(skipReason)"
                : "[relay] lane \(childSpec.id) (\(childSpec.agent.rawValue)) skipped · \(skipReason)"
            emitStderrLine(skipLine)

            if let grandChildren = childrenByPredecessor[childSpec.id], !grandChildren.isEmpty {
                markSubtreeSkipped(
                    children: grandChildren,
                    failedPredecessorID: childSpec.id,
                    failedPredecessorStatus: .skipped
                )
            }
        }
    }

    // MARK: - Escalating Cancellation (`SIGINT -> SIGTERM -> descendant-PGID SIGKILL`, R42) & Fatal Error Helpers

    private static func signalDisplayName(_ sig: Int32) -> String {
        switch sig {
        case SIGINT:
            return "SIGINT"
        case SIGTERM:
            return "SIGTERM"
        default:
            return "SIG(\(sig))"
        }
    }

    private func handleRunCancellationSignal(_ sig: Int32) {
        guard currentFatalError() == nil else { return }
        let isZh = language.isChinese
        let sigName = Self.signalDisplayName(sig)
        let banner = isZh
            ? "[relay] 收到 \(sigName)，不再启动新通道，正在取消运行中的通道..."
            : "[relay] received \(sigName); stopping new lanes and cancelling running lanes..."
        emitStderrLine(banner)
        for active in activeLaneRegistry.snapshotActiveProcesses() {
            startEscalationOnce(for: active, context: .signalCancellation)
        }
    }

    private func startEscalationOnce(for activeProc: RelayActiveLaneProcess, context: EscalationContext) {
        let handle = LaneEscalationHandle()
        stateLock.lock()
        if escalationHandlesByLaneID[activeProc.laneID] != nil {
            stateLock.unlock()
            return
        }
        escalationHandlesByLaneID[activeProc.laneID] = handle
        stateLock.unlock()

        let sigintGrace = cancellationPolicy.sigintGraceSeconds
        let sigtermGrace = cancellationPolicy.sigtermGraceSeconds
        let isZh = language.isChinese
        let emit = emitStderrLine
        let laneID = activeProc.laneID
        let agentRaw = activeProc.agent.rawValue

        DispatchQueue.global(qos: .userInitiated).async {
            _ = activeProc.session.terminateWithEscalation(
                sigintGraceSeconds: sigintGrace,
                sigtermGraceSeconds: sigtermGrace,
                onStep: { step in
                    switch step {
                    case .sentSIGINT(let pid):
                        let waitStr = String(format: "%.2fs", sigintGrace)
                        let msg = isZh
                            ? "[relay] 通道 \(laneID) (\(agentRaw)) · 向进程组 -\(pid) 发送 SIGINT（等待最多 \(waitStr)）"
                            : "[relay] lane \(laneID) (\(agentRaw)) · sent SIGINT to process group -\(pid) (waiting up to \(waitStr))"
                        emit(msg)
                    case .sentSIGTERM(let pid):
                        let waitStr = String(format: "%.2fs", sigtermGrace)
                        let msg = isZh
                            ? "[relay] 通道 \(laneID) (\(agentRaw)) · 仍未退出，向进程组 -\(pid) 发送 SIGTERM（等待最多 \(waitStr)）"
                            : "[relay] lane \(laneID) (\(agentRaw)) · still running; sent SIGTERM to process group -\(pid) (waiting up to \(waitStr))"
                        emit(msg)
                    case .sentSIGKILL(let pid, let descendants, let pgids):
                        let msg = isZh
                            ? "[relay] 通道 \(laneID) (\(agentRaw)) · 仍未退出，向进程组 \(pgids) 与后代 \(descendants) 发送 SIGKILL（主进程 \(pid)）"
                            : "[relay] lane \(laneID) (\(agentRaw)) · still running; sent SIGKILL to process groups \(pgids) and descendants \(descendants) (leader \(pid))"
                        emit(msg)
                    }
                    _ = context
                }
            )
            handle.finish()
        }
    }

    private func awaitEscalationIfAny(forLaneID laneID: String) async {
        let handle: LaneEscalationHandle? = {
            stateLock.lock()
            defer { stateLock.unlock() }
            return escalationHandlesByLaneID[laneID]
        }()
        if let handle {
            await handle.wait()
        }
    }

    private func waitForAllOngoingEscalations() async {
        let handles: [LaneEscalationHandle] = {
            stateLock.lock()
            defer { stateLock.unlock() }
            return Array(escalationHandlesByLaneID.values)
        }()
        for handle in handles {
            await handle.wait()
        }
    }

    private func snapshotLaneRecord(for laneID: String) -> RelayRunLaneRecord {
        stateLock.lock()
        defer { stateLock.unlock() }
        return laneRecordsByID[laneID]!
    }

    private func snapshotOrderedLaneRecords() -> [RelayRunLaneRecord] {
        stateLock.lock()
        let values = Array(laneRecordsByID.values)
        stateLock.unlock()
        return values.sorted { $0.ordinal < $1.ordinal }
    }

    private func persistLaneRecord(_ record: RelayRunLaneRecord) throws {
        try database.updateRunLane(record)
        stateLock.lock()
        laneRecordsByID[record.laneID] = record
        stateLock.unlock()
    }

    private func currentFatalError() -> RelayIDEError? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return firstFatalError
    }

    private func recordFatalInternalError(_ error: RelayIDEError) {
        var shouldAbortSiblings = false
        stateLock.lock()
        if firstFatalError == nil {
            firstFatalError = error
            shouldAbortSiblings = true
        }
        stateLock.unlock()

        guard shouldAbortSiblings else { return }
        activeLaneRegistry.markRunCancelling()
        for active in activeLaneRegistry.snapshotActiveProcesses() {
            startEscalationOnce(for: active, context: .fatalInternalError)
        }
    }

    @discardableResult
    private func reconcileNonTerminalLanesOnFatalError(_ error: RelayIDEError, now: Date = Date()) -> String {
        let isZh = language.isChinese
        let fatalReason = isZh
            ? "中断（RelayIDE 出错）：\(error.localizedDescription(in: language))"
            : "interrupted (RelayIDE error): \(error.localizedDescription(in: language))"

        for record in snapshotOrderedLaneRecords() where !record.status.isTerminal {
            var updated = record
            if updated.status == .running {
                updated.status = .interrupted
                updated.reason = fatalReason
                updated.finishedAt = now
                if let wt = updated.worktreePath {
                    updated.uncommittedFiles = try? gitEngine.listUncommittedFilesExcludingRelay(
                        in: wt,
                        environment: environment
                    )
                }
            } else {
                updated.status = .skipped
                updated.reason = fatalReason
                updated.finishedAt = now
            }
            try? database.updateRunLane(updated)
            stateLock.lock()
            laneRecordsByID[updated.laneID] = updated
            stateLock.unlock()
        }
        return fatalReason
    }

    private func reconcileAbortedRunOnFatalError(_ error: RelayIDEError) {
        let now = Date()
        let fatalReason = reconcileNonTerminalLanesOnFatalError(error, now: now)
        try? database.updateRunStatus(
            runID: runID,
            status: .interrupted,
            reason: fatalReason,
            finishedAt: now
        )
    }

    // MARK: - Localized Stderr Progress Formatting (`03-relayide.md` §13)

    private func formatStartLine(spec: RelayValidatedLaneSpec, pid: pid_t, branchName: String) -> String {
        if language.isChinese {
            return "[relay] 通道 \(spec.id) (\(spec.agent.rawValue)) 已启动 · PID \(pid) · 分支 \(branchName)"
        } else {
            return "[relay] lane \(spec.id) (\(spec.agent.rawValue)) started · pid \(pid) · branch \(branchName)"
        }
    }

    private func formatFinishLine(record: RelayRunLaneRecord, startedAt: Date, finishedAt: Date) -> String {
        let isZh = language.isChinese
        let statusLabel = record.status.localizedLabel(in: language)
        let exitPart: String
        if let sig = record.signal {
            exitPart = isZh ? "信号 \(sig)" : "signal \(sig)"
        } else if let code = record.exitCode {
            exitPart = isZh ? "退出码 \(code)" : "exit \(code)"
        } else {
            exitPart = "-"
        }
        let durationStr = String(format: "%.2fs", max(0, finishedAt.timeIntervalSince(startedAt)))
        let costPart: String
        if let usd = record.costUSD {
            costPart = isZh ? String(format: "花费 $%.4f", usd) : String(format: "cost $%.4f", usd)
        } else if record.costSource == "unpriced", let tok = record.tokens {
            costPart = isZh ? "花费 未计价（\(tok) tokens）" : "cost unpriced (\(tok) tokens)"
        } else {
            costPart = isZh ? "花费 无记录" : "cost no record"
        }
        let commitPart: String
        if let oid = record.commitOID {
            commitPart = isZh ? "提交 \(String(oid.prefix(12)))" : "commit \(String(oid.prefix(12)))"
        } else {
            commitPart = isZh ? "提交 无" : "commit none"
        }
        let reasonSuffix = record.reason.map { " · \($0)" } ?? ""

        if isZh {
            return "[relay] 通道 \(record.laneID) (\(record.agent.rawValue)) 已结束 · 状态 \(statusLabel) · \(exitPart) · 耗时 \(durationStr) · \(costPart) · \(commitPart)\(reasonSuffix)"
        } else {
            return "[relay] lane \(record.laneID) (\(record.agent.rawValue)) finished · status \(statusLabel) · \(exitPart) · time \(durationStr) · \(costPart) · \(commitPart)\(reasonSuffix)"
        }
    }
}
