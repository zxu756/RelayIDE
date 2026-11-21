import Darwin
import Foundation
import RelayModels
import RelayPTYCore
import RelayPluginSDK
import RelaySemanticMerge
import RelayWorkspaceStore
import RelayWorktreeGit

// Alias matching both `RelayTaskNode` and `RelayDAGTaskNode` naming conventions
public typealias RelayDAGTaskNode = RelayTaskNode

// MARK: - Critical Path Method (CPM) Slack & Parallel Speedup Models

public struct CPMNodeScheduleMetrics: Sendable, Codable, Hashable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let title: String
    public let vendor: AgentVendor
    public let laneID: String
    public let status: RelayTaskStatus
    public let topologicalWaveIndex: Int
    public let durationSeconds: Double
    public let earliestStartSeconds: Double
    public let earliestFinishSeconds: Double
    public let latestStartSeconds: Double
    public let latestFinishSeconds: Double
    public let totalSlackSeconds: Double
    public let freeSlackSeconds: Double
    public let isOnCriticalPath: Bool

    public init(
        taskID: String,
        title: String,
        vendor: AgentVendor,
        laneID: String,
        status: RelayTaskStatus,
        topologicalWaveIndex: Int,
        durationSeconds: Double,
        earliestStartSeconds: Double,
        earliestFinishSeconds: Double,
        latestStartSeconds: Double,
        latestFinishSeconds: Double,
        totalSlackSeconds: Double,
        freeSlackSeconds: Double,
        isOnCriticalPath: Bool
    ) {
        self.taskID = taskID
        self.title = title
        self.vendor = vendor
        self.laneID = laneID
        self.status = status
        self.topologicalWaveIndex = topologicalWaveIndex
        self.durationSeconds = durationSeconds
        self.earliestStartSeconds = earliestStartSeconds
        self.earliestFinishSeconds = earliestFinishSeconds
        self.latestStartSeconds = latestStartSeconds
        self.latestFinishSeconds = latestFinishSeconds
        self.totalSlackSeconds = totalSlackSeconds
        self.freeSlackSeconds = freeSlackSeconds
        self.isOnCriticalPath = isOnCriticalPath
    }
}

public struct ParallelSpeedupMetrics: Sendable, Codable, Hashable {
    public let serialDurationSeconds: Double
    public let parallelMakespanSeconds: Double
    public let theoreticalSpeedupFactor: Double
    public let observedLiveSpeedupFactor: Double
    public let activeVendorLaneCount: Int
    public let parallelEfficiencyRatio: Double
    public let peakWaveConcurrency: Int
    public let bottleneckTaskID: String?

    public init(
        serialDurationSeconds: Double,
        parallelMakespanSeconds: Double,
        theoreticalSpeedupFactor: Double,
        observedLiveSpeedupFactor: Double,
        activeVendorLaneCount: Int,
        parallelEfficiencyRatio: Double,
        peakWaveConcurrency: Int,
        bottleneckTaskID: String?
    ) {
        self.serialDurationSeconds = serialDurationSeconds
        self.parallelMakespanSeconds = parallelMakespanSeconds
        self.theoreticalSpeedupFactor = theoreticalSpeedupFactor
        self.observedLiveSpeedupFactor = observedLiveSpeedupFactor
        self.activeVendorLaneCount = activeVendorLaneCount
        self.parallelEfficiencyRatio = parallelEfficiencyRatio
        self.peakWaveConcurrency = peakWaveConcurrency
        self.bottleneckTaskID = bottleneckTaskID
    }
}

public struct CPMAnalysisReport: Sendable, Codable, Hashable {
    public let nodeSchedules: [CPMNodeScheduleMetrics]
    public let criticalPathTaskIDs: [String]
    public let speedup: ParallelSpeedupMetrics
    public let schedulesByLaneID: [String: [CPMNodeScheduleMetrics]]

    public init(
        nodeSchedules: [CPMNodeScheduleMetrics],
        criticalPathTaskIDs: [String],
        speedup: ParallelSpeedupMetrics,
        schedulesByLaneID: [String: [CPMNodeScheduleMetrics]]
    ) {
        self.nodeSchedules = nodeSchedules
        self.criticalPathTaskIDs = criticalPathTaskIDs
        self.speedup = speedup
        self.schedulesByLaneID = schedulesByLaneID
    }
}

// MARK: - CPM Earliest/Latest Start Slack Analyzer & Speedup Calculator

public struct CriticalPathMethodAnalyzer: Sendable {
    public let criticalSlackEpsilon: Double

    public init(criticalSlackEpsilon: Double = 1e-4) {
        self.criticalSlackEpsilon = max(1e-9, criticalSlackEpsilon)
    }

    /// Runs forward/backward CPM passes over `[RelayDAGTaskNode]` (`[RelayTaskNode]`), computing slack, critical path, and live parallel speedup.
    public func analyze(
        tasks: [RelayDAGTaskNode],
        durationOverridesSeconds: [String: Double] = [:],
        observedWiretapSpans: [WiretapAPISpan] = []
    ) throws -> CPMAnalysisReport {
        guard !tasks.isEmpty else {
            return CPMAnalysisReport(
                nodeSchedules: [],
                criticalPathTaskIDs: [],
                speedup: ParallelSpeedupMetrics(
                    serialDurationSeconds: 0,
                    parallelMakespanSeconds: 0,
                    theoreticalSpeedupFactor: 1.0,
                    observedLiveSpeedupFactor: 1.0,
                    activeVendorLaneCount: 0,
                    parallelEfficiencyRatio: 1.0,
                    peakWaveConcurrency: 0,
                    bottleneckTaskID: nil
                ),
                schedulesByLaneID: [:]
            )
        }

        var nodeByID: [String: RelayDAGTaskNode] = [:]
        var inDegree: [String: Int] = [:]
        var predecessors: [String: [String]] = [:]
        var successors: [String: [String]] = [:]

        for task in tasks {
            nodeByID[task.id] = task
            inDegree[task.id] = 0
            predecessors[task.id] = []
            successors[task.id] = []
        }

        for task in tasks {
            for depID in task.dependsOnTaskIDs where nodeByID[depID] != nil {
                inDegree[task.id, default: 0] += 1
                predecessors[task.id, default: []].append(depID)
                successors[depID, default: []].append(task.id)
            }
        }

        // Kahn's topological sort + wave assignment
        var waveIndexByID: [String: Int] = [:]
        var topoOrder: [String] = []
        var frontier = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var currentWave = 0
        var peakWaveSize = 0

        while !frontier.isEmpty {
            peakWaveSize = max(peakWaveSize, frontier.count)
            var nextFrontier: [String] = []
            for id in frontier {
                topoOrder.append(id)
                waveIndexByID[id] = currentWave
                for childID in (successors[id] ?? []) {
                    let nextDeg = (inDegree[childID] ?? 1) - 1
                    inDegree[childID] = nextDeg
                    if nextDeg == 0 {
                        nextFrontier.append(childID)
                    }
                }
            }
            frontier = nextFrontier.sorted()
            currentWave += 1
        }

        if topoOrder.count < tasks.count {
            let cycleIDs = inDegree.filter { $0.value > 0 }.map(\.key).sorted()
            throw RelayIDEError.cyclicTaskDependency(cycleIDs)
        }

        // Aggregate wiretap duration per taskID if available
        var spanSecondsByTask: [String: Double] = [:]
        for span in observedWiretapSpans {
            if let tid = span.taskID {
                spanSecondsByTask[tid, default: 0.0] += (span.durationMs / 1_000.0)
            }
        }

        var durationByID: [String: Double] = [:]
        for id in topoOrder {
            guard let task = nodeByID[id] else { continue }
            if let explicit = durationOverridesSeconds[id], explicit > 0 {
                durationByID[id] = explicit
            } else if let s = task.startedAt, let f = task.finishedAt, f > s {
                durationByID[id] = max(0.5, f.timeIntervalSince(s))
            } else if let spanSec = spanSecondsByTask[id], spanSec > 0.2 {
                durationByID[id] = spanSec
            } else {
                durationByID[id] = Self.estimateHeuristicDurationSeconds(for: task)
            }
        }

        // Forward Pass: Earliest Start (ES) and Earliest Finish (EF)
        var esByID: [String: Double] = [:]
        var efByID: [String: Double] = [:]
        for id in topoOrder {
            let preds = predecessors[id] ?? []
            let maxPredEF = preds.compactMap { efByID[$0] }.max() ?? 0.0
            let dur = durationByID[id] ?? 1.0
            esByID[id] = maxPredEF
            efByID[id] = maxPredEF + dur
        }

        let makespan = max(0.001, efByID.values.max() ?? 0.001)

        // Backward Pass: Latest Finish (LF) and Latest Start (LS)
        var lfByID: [String: Double] = [:]
        var lsByID: [String: Double] = [:]
        for id in topoOrder.reversed() {
            let succs = successors[id] ?? []
            let dur = durationByID[id] ?? 1.0
            let lf: Double
            if succs.isEmpty {
                lf = makespan
            } else {
                lf = succs.compactMap { lsByID[$0] }.min() ?? makespan
            }
            lfByID[id] = lf
            lsByID[id] = max(0.0, lf - dur)
        }

        var nodeMetrics: [CPMNodeScheduleMetrics] = []
        var criticalChain: [String] = []
        var byLane: [String: [CPMNodeScheduleMetrics]] = [:]

        for id in topoOrder {
            guard let task = nodeByID[id] else { continue }
            let dur = durationByID[id] ?? 1.0
            let es = esByID[id] ?? 0.0
            let ef = efByID[id] ?? dur
            let ls = lsByID[id] ?? 0.0
            let lf = lfByID[id] ?? makespan
            let totalSlack = max(0.0, ls - es)

            let succs = successors[id] ?? []
            let freeSlack: Double
            if succs.isEmpty {
                freeSlack = max(0.0, makespan - ef)
            } else {
                let minSuccES = succs.compactMap { esByID[$0] }.min() ?? ef
                freeSlack = max(0.0, minSuccES - ef)
            }

            let isCritical = totalSlack <= criticalSlackEpsilon
            if isCritical {
                criticalChain.append(id)
            }

            let item = CPMNodeScheduleMetrics(
                taskID: id,
                title: task.title,
                vendor: task.vendor,
                laneID: task.laneID,
                status: task.status,
                topologicalWaveIndex: waveIndexByID[id] ?? 0,
                durationSeconds: dur,
                earliestStartSeconds: es,
                earliestFinishSeconds: ef,
                latestStartSeconds: ls,
                latestFinishSeconds: lf,
                totalSlackSeconds: totalSlack,
                freeSlackSeconds: freeSlack,
                isOnCriticalPath: isCritical
            )
            nodeMetrics.append(item)
            byLane[task.laneID, default: []].append(item)
        }

        let serialSum = durationByID.values.reduce(0.0, +)
        let theoreticalSpeedup = max(1.0, serialSum / makespan)
        let liveSpeedup = Self.computeObservedLiveSpeedup(tasks: tasks, fallbackTheoretical: theoreticalSpeedup)
        let distinctLanes = max(1, Set(tasks.map(\.laneID)).count)
        let efficiency = min(1.0, theoreticalSpeedup / Double(distinctLanes))
        let bottleneckID = nodeMetrics
            .filter(\.isOnCriticalPath)
            .max(by: { $0.durationSeconds < $1.durationSeconds })?
            .taskID

        let speedupMetrics = ParallelSpeedupMetrics(
            serialDurationSeconds: serialSum,
            parallelMakespanSeconds: makespan,
            theoreticalSpeedupFactor: theoreticalSpeedup,
            observedLiveSpeedupFactor: liveSpeedup,
            activeVendorLaneCount: distinctLanes,
            parallelEfficiencyRatio: efficiency,
            peakWaveConcurrency: peakWaveSize,
            bottleneckTaskID: bottleneckID
        )

        return CPMAnalysisReport(
            nodeSchedules: nodeMetrics,
            criticalPathTaskIDs: criticalChain,
            speedup: speedupMetrics,
            schedulesByLaneID: byLane
        )
    }

    private static func estimateHeuristicDurationSeconds(for task: RelayDAGTaskNode) -> Double {
        let baseByVendor: Double
        switch task.vendor {
        case .claudeCode: baseByVendor = 38.0
        case .codex: baseByVendor = 34.0
        case .antigravity: baseByVendor = 29.0
        case .mistralVibe: baseByVendor = 22.0
        case .customShell: baseByVendor = 8.0
        }
        let promptFactor = Double(min(400, task.promptBrief.count)) * 0.06
        let gateOverhead = (task.verificationShellCommand?.isEmpty == false) ? 9.5 : 0.0
        let handoffOverhead = Double(task.inputHandoffFiles.count + task.outputHandoffFiles.count) * 2.5
        return baseByVendor + promptFactor + gateOverhead + handoffOverhead
    }

    private static func computeObservedLiveSpeedup(tasks: [RelayDAGTaskNode], fallbackTheoretical: Double) -> Double {
        let timed = tasks.compactMap { t -> (start: Date, end: Date)? in
            guard let s = t.startedAt, let e = t.finishedAt, e > s else { return nil }
            return (s, e)
        }
        guard timed.count >= 2,
              let minStart = timed.map(\.start).min(),
              let maxEnd = timed.map(\.end).max() else {
            return fallbackTheoretical
        }
        let wallSpan = max(0.5, maxEnd.timeIntervalSince(minStart))
        let sumWork = timed.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return max(1.0, sumWork / wallSpan)
    }
}

// MARK: - Automatic Vendor Failover, Lane Pause/Handoff & Retry Policy

public enum TaskFailureTrigger: Sendable, Codable, Hashable {
    case vendorQuotaOrRateLimited(httpStatus: Int, providerMessage: String)
    case laneBudgetCircuitTripped(spentUSD: Double, ceilingUSD: Double)
    case verificationGateRejected(exitCode: Int32, diagnosticSummary: String)
    case processAbnormalExit(exitCode: Int32)
    case heartbeatStallTimeout(idleSeconds: Double)
}

public struct VendorFailoverPolicyConfig: Sendable, Codable, Hashable {
    public var maxSameVendorRetries: Int
    public var initialBackoffSeconds: Double
    public var maxBackoffSeconds: Double
    public var autoFailoverOnQuotaExhaustion: Bool
    public var pauseLaneOnBudgetTripUnlessStandbyAllowed: Bool
    public var standbyVendorPriority: [AgentVendor: [AgentVendor]]

    public init(
        maxSameVendorRetries: Int = 2,
        initialBackoffSeconds: Double = 2.0,
        maxBackoffSeconds: Double = 30.0,
        autoFailoverOnQuotaExhaustion: Bool = true,
        pauseLaneOnBudgetTripUnlessStandbyAllowed: Bool = true,
        standbyVendorPriority: [AgentVendor: [AgentVendor]] = VendorFailoverPolicyConfig.defaultPriorityMatrix
    ) {
        self.maxSameVendorRetries = max(0, maxSameVendorRetries)
        self.initialBackoffSeconds = max(0.25, initialBackoffSeconds)
        self.maxBackoffSeconds = max(1.0, maxBackoffSeconds)
        self.autoFailoverOnQuotaExhaustion = autoFailoverOnQuotaExhaustion
        self.pauseLaneOnBudgetTripUnlessStandbyAllowed = pauseLaneOnBudgetTripUnlessStandbyAllowed
        self.standbyVendorPriority = standbyVendorPriority
    }

    public static let defaultPriorityMatrix: [AgentVendor: [AgentVendor]] = [
        .claudeCode: [.codex, .antigravity, .mistralVibe],
        .codex: [.claudeCode, .antigravity, .mistralVibe],
        .antigravity: [.claudeCode, .codex, .mistralVibe],
        .mistralVibe: [.codex, .claudeCode, .antigravity],
        .customShell: [.customShell]
    ]
}

public enum FailoverResolutionDecision: Sendable, Codable, Hashable {
    case retrySameLane(attempt: Int, delaySeconds: Double, augmentedPromptSuffix: String?)
    case failoverHandoff(
        newVendor: AgentVendor,
        standbyLaneID: String,
        handoffArtifactPath: String,
        handoffMarkdown: String
    )
    case pauseLaneAwaitingOperator(laneID: String, reason: String)
    case abortTaskPermanently(reason: String)
}

public struct FailoverAuditRecord: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let taskID: String
    public let originalLaneID: String
    public let originalVendor: AgentVendor
    public let trigger: TaskFailureTrigger
    public let decision: FailoverResolutionDecision
    public let decidedAt: Date

    public init(
        id: UUID = UUID(),
        taskID: String,
        originalLaneID: String,
        originalVendor: AgentVendor,
        trigger: TaskFailureTrigger,
        decision: FailoverResolutionDecision,
        decidedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.originalLaneID = originalLaneID
        self.originalVendor = originalVendor
        self.trigger = trigger
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

public final class VendorFailoverAndRetryController: @unchecked Sendable {
    private let lock = NSLock()
    public var policy: VendorFailoverPolicyConfig
    private var retryCountsByTask: [String: Int] = [:]
    private var exhaustedVendorsByTask: [String: Set<AgentVendor>] = [:]
    private var pausedLanes: Set<String> = []
    private var auditHistory: [FailoverAuditRecord] = []

    public init(policy: VendorFailoverPolicyConfig = VendorFailoverPolicyConfig()) {
        self.policy = policy
    }

    public func isLanePaused(_ laneID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedLanes.contains(laneID)
    }

    public func resumePausedLane(_ laneID: String) {
        lock.lock()
        pausedLanes.remove(laneID)
        lock.unlock()
    }

    public func allAuditRecords() -> [FailoverAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return auditHistory
    }

    /// Evaluates retry backoff, lane pause, or cross-vendor handoff when an agent task faults or hits quota limits.
    public func evaluateFailure(
        task: RelayDAGTaskNode,
        trigger: TaskFailureTrigger,
        availableLanes: [ManagedWorktreeLane],
        budgetAccounts: [LaneBudgetAccount] = [],
        partialDirtyFiles: [String] = [],
        terminalTailLines: [String] = []
    ) -> FailoverResolutionDecision {
        lock.lock()
        defer { lock.unlock() }

        let currentRetries = retryCountsByTask[task.id, default: 0]
        let accountByLane = Dictionary(uniqueKeysWithValues: budgetAccounts.map { ($0.laneID, $0) })

        let decision: FailoverResolutionDecision

        switch trigger {
        case .laneBudgetCircuitTripped(let spent, let ceiling):
            pausedLanes.insert(task.laneID)
            if policy.pauseLaneOnBudgetTripUnlessStandbyAllowed {
                decision = .pauseLaneAwaitingOperator(
                    laneID: task.laneID,
                    reason: String(format: "Budget circuit open on '%@' ($%.2f / $%.2f). Raise ceiling or approve standby handoff.", task.laneID, spent, ceiling)
                )
            } else if let standby = pickStandbyTarget(for: task, availableLanes: availableLanes, accounts: accountByLane) {
                decision = buildFailoverHandoff(
                    task: task,
                    targetVendor: standby.vendor,
                    targetLaneID: standby.laneID,
                    reasonSummary: "Primary lane budget exhausted ($\(String(format: "%.2f", spent)))",
                    partialDirtyFiles: partialDirtyFiles,
                    terminalTailLines: terminalTailLines
                )
            } else {
                decision = .pauseLaneAwaitingOperator(laneID: task.laneID, reason: "All vendor lanes budget-constrained.")
            }

        case .vendorQuotaOrRateLimited(let status, let msg):
            if status == 429 && currentRetries < 1 {
                retryCountsByTask[task.id] = currentRetries + 1
                let delay = computeExponentialBackoff(attempt: currentRetries + 1, taskID: task.id)
                decision = .retrySameLane(attempt: currentRetries + 1, delaySeconds: delay, augmentedPromptSuffix: nil)
            } else if policy.autoFailoverOnQuotaExhaustion,
                      let standby = pickStandbyTarget(for: task, availableLanes: availableLanes, accounts: accountByLane) {
                pausedLanes.insert(task.laneID)
                decision = buildFailoverHandoff(
                    task: task,
                    targetVendor: standby.vendor,
                    targetLaneID: standby.laneID,
                    reasonSummary: "Upstream \(task.vendor.displayName) quota/rate limit (HTTP \(status): \(msg))",
                    partialDirtyFiles: partialDirtyFiles,
                    terminalTailLines: terminalTailLines
                )
            } else {
                decision = .pauseLaneAwaitingOperator(
                    laneID: task.laneID,
                    reason: "Vendor \(task.vendor.displayName) rate-limited and no healthy standby lane available."
                )
            }

        case .verificationGateRejected(let code, let diagSummary):
            if currentRetries < policy.maxSameVendorRetries {
                let nextAttempt = currentRetries + 1
                retryCountsByTask[task.id] = nextAttempt
                let repairHint = """
                [RELAY VERIFICATION GATE FAILED — EXIT \(code)]
                Fix the following compiler/test diagnostics without touching files outside \(task.allowedWriteGlobs.joined(separator: ", ")):
                \(diagSummary)
                """
                decision = .retrySameLane(
                    attempt: nextAttempt,
                    delaySeconds: 1.0,
                    augmentedPromptSuffix: repairHint
                )
            } else if let standby = pickStandbyTarget(for: task, availableLanes: availableLanes, accounts: accountByLane) {
                decision = buildFailoverHandoff(
                    task: task,
                    targetVendor: standby.vendor,
                    targetLaneID: standby.laneID,
                    reasonSummary: "Verification gate failed after \(currentRetries) self-repair attempts: \(diagSummary)",
                    partialDirtyFiles: partialDirtyFiles,
                    terminalTailLines: terminalTailLines
                )
            } else {
                decision = .abortTaskPermanently(
                    reason: "Verification gate failed (\(code)) after exhausting retries and standby vendors."
                )
            }

        case .processAbnormalExit(let exitCode):
            if currentRetries < policy.maxSameVendorRetries {
                let nextAttempt = currentRetries + 1
                retryCountsByTask[task.id] = nextAttempt
                let delay = computeExponentialBackoff(attempt: nextAttempt, taskID: task.id)
                decision = .retrySameLane(attempt: nextAttempt, delaySeconds: delay, augmentedPromptSuffix: nil)
            } else if let standby = pickStandbyTarget(for: task, availableLanes: availableLanes, accounts: accountByLane) {
                decision = buildFailoverHandoff(
                    task: task,
                    targetVendor: standby.vendor,
                    targetLaneID: standby.laneID,
                    reasonSummary: "Agent CLI exited unexpectedly with code \(exitCode)",
                    partialDirtyFiles: partialDirtyFiles,
                    terminalTailLines: terminalTailLines
                )
            } else {
                decision = .abortTaskPermanently(reason: "Agent process exited with \(exitCode) and retries exhausted.")
            }

        case .heartbeatStallTimeout(let idleSec):
            if let standby = pickStandbyTarget(for: task, availableLanes: availableLanes, accounts: accountByLane) {
                pausedLanes.insert(task.laneID)
                decision = buildFailoverHandoff(
                    task: task,
                    targetVendor: standby.vendor,
                    targetLaneID: standby.laneID,
                    reasonSummary: String(format: "Primary PTY lane stalled for %.0fs without output", idleSec),
                    partialDirtyFiles: partialDirtyFiles,
                    terminalTailLines: terminalTailLines
                )
            } else {
                decision = .pauseLaneAwaitingOperator(
                    laneID: task.laneID,
                    reason: String(format: "Task stalled for %.0fs.", idleSec)
                )
            }
        }

        auditHistory.append(
            FailoverAuditRecord(
                taskID: task.id,
                originalLaneID: task.laneID,
                originalVendor: task.vendor,
                trigger: trigger,
                decision: decision
            )
        )
        return decision
    }

    private func pickStandbyTarget(
        for task: RelayDAGTaskNode,
        availableLanes: [ManagedWorktreeLane],
        accounts: [String: LaneBudgetAccount]
    ) -> (vendor: AgentVendor, laneID: String)? {
        var tried = exhaustedVendorsByTask[task.id, default: []]
        tried.insert(task.vendor)
        let candidates = policy.standbyVendorPriority[task.vendor] ?? [.codex, .claudeCode, .antigravity, .mistralVibe]

        for candidateVendor in candidates where !tried.contains(candidateVendor) {
            if let matchingLane = availableLanes.first(where: { lane in
                lane.assignedVendor == candidateVendor &&
                !pausedLanes.contains(lane.id) &&
                !(accounts[lane.id]?.circuitOpen ?? false)
            }) {
                tried.insert(candidateVendor)
                exhaustedVendorsByTask[task.id] = tried
                retryCountsByTask[task.id] = 0
                return (candidateVendor, matchingLane.id)
            }
            // Synthesize dynamic failover lane ID if no pre-created standby lane exists
            tried.insert(candidateVendor)
            exhaustedVendorsByTask[task.id] = tried
            retryCountsByTask[task.id] = 0
            return (candidateVendor, "lane-failover-\(candidateVendor.rawValue)-\(task.id)")
        }
        return nil
    }

    private func buildFailoverHandoff(
        task: RelayDAGTaskNode,
        targetVendor: AgentVendor,
        targetLaneID: String,
        reasonSummary: String,
        partialDirtyFiles: [String],
        terminalTailLines: [String]
    ) -> FailoverResolutionDecision {
        let artifactPath = ".relay/failover-\(task.id)-to-\(targetVendor.rawValue).md"
        let dirtyList = partialDirtyFiles.isEmpty
            ? "- _(No uncommitted working tree modifications)_"
            : partialDirtyFiles.map { "- `\($0)`" }.joined(separator: "\n")
        let tailBlock = terminalTailLines.suffix(12).joined(separator: "\n")

        let markdown = """
        # RelayIDE Automatic Vendor Failover Handoff
        - **Task ID**: `\(task.id)` (\(task.title))
        - **Previous Lane / Vendor**: `\(task.laneID)` (\(task.vendor.displayName))
        - **Assigned Standby Lane / Vendor**: `\(targetLaneID)` (\(targetVendor.displayName))
        - **Failover Trigger**: \(reasonSummary)
        - **Permitted Write Territory**: `\(task.allowedWriteGlobs.joined(separator: ", "))`

        ## Original Engineering Objective
        \(task.promptBrief)

        ## Partial Worktree State Preserved
        \(dirtyList)

        ## Recent Terminal Diagnostics
        ```text
        \(tailBlock.isEmpty ? "(no terminal output captured)" : tailBlock)
        ```
        """
        return .failoverHandoff(
            newVendor: targetVendor,
            standbyLaneID: targetLaneID,
            handoffArtifactPath: artifactPath,
            handoffMarkdown: markdown
        )
    }

    private func computeExponentialBackoff(attempt: Int, taskID: String) -> Double {
        let exp = pow(2.0, Double(max(0, attempt - 1)))
        // Deterministic FNV-style micro-jitter (0..0.35s) derived from taskID + attempt
        var hash: UInt64 = 14_695_981_039_346_656_037
        for b in "\(taskID)#\(attempt)".utf8 {
            hash ^= UInt64(b)
            hash &*= 1_099_511_628_211
        }
        let jitter = Double(hash % 350) / 1_000.0
        return min(policy.maxBackoffSeconds, policy.initialBackoffSeconds * exp + jitter)
    }
}

// MARK: - Convenience CPM & Failover Extensions on MultiVendorDAGOrchestrator

public extension MultiVendorDAGOrchestrator {
    func computeCriticalPathSchedule(
        for dag: RelayDAGSpec,
        durationOverridesSeconds: [String: Double] = [:]
    ) throws -> CPMAnalysisReport {
        let spans = (try? database.allWiretapSpans()) ?? []
        return try CriticalPathMethodAnalyzer().analyze(
            tasks: dag.tasks,
            durationOverridesSeconds: durationOverridesSeconds,
            observedWiretapSpans: spans
        )
    }
}
