import Foundation
import RelayModels
import RelayWorkspaceStore
import RelayWorktreeGit

// MARK: - Deterministic Topological + Plan-Order Merge Sequence (`03-relayide.md` M2 §4)

public struct RelayMergeOrderItem: Sendable, Hashable, Equatable {
    public let laneID: String
    public let after: [String]

    public init(laneID: String, after: [String] = []) {
        self.laneID = laneID
        self.after = after
    }
}

public enum RelayIntegrationMergeOrder {
    /// Computes deterministic topological merge order, breaking ties at every step by picking
    /// the ready lane (all `after` dependencies already scheduled) with the smallest plan index.
    public static func computeMergeOrder(_ planItems: [RelayMergeOrderItem]) throws -> [String] {
        guard !planItems.isEmpty else { return [] }

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(planItems.count)
        for (idx, item) in planItems.enumerated() {
            if indexByID.updateValue(idx, forKey: item.laneID) != nil {
                throw RelayIDEError.invalidRunPlan("Duplicate lane id '\(item.laneID)' in merge order input")
            }
        }

        var remainingPredecessors = Array(repeating: 0, count: planItems.count)
        var dependents = Array(repeating: [Int](), count: planItems.count)

        for (idx, item) in planItems.enumerated() {
            var uniqueDeps = Set<String>()
            for dep in item.after {
                guard let depIdx = indexByID[dep] else {
                    throw RelayIDEError.invalidRunPlan(
                        "Lane '\(item.laneID)' references nonexistent after lane '\(dep)'"
                    )
                }
                if depIdx == idx {
                    throw RelayIDEError.cyclicTaskDependency([item.laneID, item.laneID])
                }
                if uniqueDeps.insert(dep).inserted {
                    remainingPredecessors[idx] += 1
                    dependents[depIdx].append(idx)
                }
            }
        }

        var scheduled = Array(repeating: false, count: planItems.count)
        var result: [String] = []
        result.reserveCapacity(planItems.count)

        for _ in 0..<planItems.count {
            var nextReadyIndex: Int?
            for idx in 0..<planItems.count where !scheduled[idx] && remainingPredecessors[idx] == 0 {
                nextReadyIndex = idx
                break
            }
            guard let chosen = nextReadyIndex else {
                let cyclicIDs = (0..<planItems.count)
                    .filter { !scheduled[$0] }
                    .map { planItems[$0].laneID }
                throw RelayIDEError.cyclicTaskDependency(cyclicIDs)
            }
            scheduled[chosen] = true
            result.append(planItems[chosen].laneID)
            for childIdx in dependents[chosen] {
                remainingPredecessors[childIdx] -= 1
            }
        }

        return result
    }

    public static func computeMergeOrder(planLanes: [RelayPlanLaneSpec]) throws -> [String] {
        try computeMergeOrder(planLanes.map { RelayMergeOrderItem(laneID: $0.id, after: $0.after) })
    }

    public static func computeMergeOrder(validatedLanes: [RelayValidatedLaneSpec]) throws -> [String] {
        try computeMergeOrder(validatedLanes.map { RelayMergeOrderItem(laneID: $0.id, after: $0.after) })
    }

    public static func computeMergeOrder(
        lanes: [RelayRunLaneRecord],
        planOrder: [String]
    ) throws -> [String] {
        var byID: [String: RelayRunLaneRecord] = [:]
        for lane in lanes {
            if byID.updateValue(lane, forKey: lane.laneID) != nil {
                throw RelayIDEError.invalidRunPlan("Duplicate lane record '\(lane.laneID)'")
            }
        }
        var items: [RelayMergeOrderItem] = []
        items.reserveCapacity(planOrder.count)
        for laneID in planOrder {
            guard let record = byID[laneID] else {
                throw RelayIDEError.invalidRunPlan("Plan order references missing lane record '\(laneID)'")
            }
            items.append(RelayMergeOrderItem(laneID: laneID, after: record.after))
        }
        let ordered = try computeMergeOrder(items)
        guard ordered.count == byID.count else {
            throw RelayIDEError.invalidRunPlan("Plan order omitted one or more lane records")
        }
        return ordered
    }
}

// MARK: - Localized Stderr Integration & Merge Progress Lines (`03-relayide.md` M2 §10)

public enum RelayIntegrationStderrFormatter {
    public static func formatIntegrationBranchCreatedLine(
        branchName: String,
        worktreePath: String,
        baseCommitOID: String,
        language: RelayLanguage
    ) -> String {
        let shortBase = String(baseCommitOID.prefix(12))
        if language.isChinese {
            return "[relay] 已创建集成分支 \(branchName) · 基线 \(shortBase) · 工作树 \(worktreePath)"
        } else {
            return "[relay] created integration branch \(branchName) · base \(shortBase) · worktree \(worktreePath)"
        }
    }

    public static func formatMergeStepLine(
        step: RelayRunMergeRecord,
        agent: RelayPlanAgent?,
        language: RelayLanguage
    ) -> String {
        let isZh = language.isChinese
        let agentSuffix = agent.map { " (\($0.rawValue))" } ?? ""
        let statusLabel = step.status.localizedLabel(in: language)

        switch step.status {
        case .merged:
            let shortOID = step.mergeCommitOID.map { String($0.prefix(12)) } ?? "-"
            if isZh {
                return "[relay] 合并通道 \(step.laneID)\(agentSuffix) · 结果 \(statusLabel) · 合并提交 \(shortOID)"
            } else {
                return "[relay] merge lane \(step.laneID)\(agentSuffix) · result \(statusLabel) · commit \(shortOID)"
            }
        case .noChanges:
            if isZh {
                return "[relay] 合并通道 \(step.laneID)\(agentSuffix) · 结果 \(statusLabel) · 合并提交 无"
            } else {
                return "[relay] merge lane \(step.laneID)\(agentSuffix) · result \(statusLabel) · commit none"
            }
        case .conflict:
            let conflictDesc = step.conflicts.isEmpty
                ? "-"
                : step.conflicts.map { "\($0.path) (\($0.code))" }.joined(separator: ", ")
            if isZh {
                return "[relay] 合并通道 \(step.laneID)\(agentSuffix) · 结果 \(statusLabel) · 冲突文件 \(conflictDesc)"
            } else {
                return "[relay] merge lane \(step.laneID)\(agentSuffix) · result \(statusLabel) · conflicts \(conflictDesc)"
            }
        case .notAttempted:
            if isZh {
                return "[relay] 合并通道 \(step.laneID)\(agentSuffix) · 结果 \(statusLabel)"
            } else {
                return "[relay] merge lane \(step.laneID)\(agentSuffix) · result \(statusLabel)"
            }
        }
    }

    public static func formatIntegrationSummaryLine(
        integration: RelayRunIntegrationRecord,
        language: RelayLanguage
    ) -> String {
        let isZh = language.isChinese
        let statusLabel = integration.status.localizedLabel(in: language)
        if isZh {
            let readyLabel = integration.ready ? "可合入 是" : "可合入 否"
            let headSuffix = integration.headCommitOID.map { " · 分支头 \(String($0.prefix(12)))" } ?? ""
            return "[relay] 集成结果 · 状态 \(statusLabel) · \(readyLabel)\(headSuffix)"
        } else {
            let readyLabel = integration.ready ? "ready yes" : "ready no"
            let headSuffix = integration.headCommitOID.map { " · head \(String($0.prefix(12)))" } ?? ""
            return "[relay] integration finished · status \(statusLabel) · \(readyLabel)\(headSuffix)"
        }
    }
}

// MARK: - Per-Lane Git Merge & Overall Integration Merge Phase (`03-relayide.md` M2 §1, §5, §7; R55–R59)

public enum RelayIntegrationMergeRunner {
    @discardableResult
    public static func runIntegrationMergePhase(
        runID: String,
        repositoryPath: String,
        projectBundlePath: String,
        baseCommitOID: String,
        lanes: [RelayRunLaneRecord],
        planOrder: [String],
        database: RelayProjectDatabase,
        gitEngine: GitWorktreePlumbingEngine = GitWorktreePlumbingEngine(),
        language: RelayLanguage = .en,
        environment: [String: String]? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        emitSummaryLineOnMerged: Bool = true,
        onStderrLine: @Sendable (String) -> Void = { _ in }
    ) throws -> RelayRunIntegrationRecord {
        var laneByID: [String: RelayRunLaneRecord] = [:]
        laneByID.reserveCapacity(lanes.count)
        for lane in lanes {
            if laneByID.updateValue(lane, forKey: lane.laneID) != nil {
                throw RelayIDEError.relayEnvironmentFailure(
                    "Duplicate lane record '\(lane.laneID)' in run '\(runID)'"
                )
            }
        }

        let mergeOrderIDs: [String]
        do {
            mergeOrderIDs = try RelayIntegrationMergeOrder.computeMergeOrder(
                lanes: lanes,
                planOrder: planOrder
            )
        } catch let relayErr as RelayIDEError {
            throw RelayIDEError.relayEnvironmentFailure(relayErr.localizedDescription(in: .en))
        }

        // 1. D1 check (`03-relayide.md` M2 §1 & D1): merge ONLY when every lane finished `succeeded` or `succeeded-no-changes`.
        let nonSucceeded = planOrder
            .compactMap { laneByID[$0] }
            .filter { $0.status != .succeeded && $0.status != .succeededNoChanges }
        if !nonSucceeded.isEmpty {
            let details = nonSucceeded
                .map { "\($0.laneID) (\($0.status.rawValue))" }
                .joined(separator: ", ")
            let skipped = RelayRunIntegrationRecord(
                branch: nil,
                worktreePath: nil,
                baseCommitOID: baseCommitOID,
                headCommitOID: nil,
                status: .skipped,
                reason: "skipped: non-succeeded lanes: \(details)",
                ready: false,
                merges: [],
                verify: nil
            )
            try database.upsertRunIntegration(runID: runID, skipped)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                    integration: skipped,
                    language: language
                )
            )
            return skipped
        }

        // 2. Entry cancellation check (`03-relayide.md` M2 §7): before creating integration worktree / branch.
        if isCancelled() {
            let cancelled = RelayRunIntegrationRecord(
                branch: nil,
                worktreePath: nil,
                baseCommitOID: baseCommitOID,
                headCommitOID: nil,
                status: .cancelled,
                reason: "cancelled",
                ready: false,
                merges: [],
                verify: nil
            )
            try database.upsertRunIntegration(runID: runID, cancelled)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                    integration: cancelled,
                    language: language
                )
            )
            return cancelled
        }

        // 3. `nothing-to-merge` (`03-relayide.md` M2 §1): all lanes finished without commits (`succeeded-no-changes`).
        let allNoChanges = lanes.allSatisfy { $0.status == .succeededNoChanges || $0.commitOID == nil }
        if allNoChanges {
            let nothingToMerge = RelayRunIntegrationRecord(
                branch: nil,
                worktreePath: nil,
                baseCommitOID: baseCommitOID,
                headCommitOID: nil,
                status: .nothingToMerge,
                reason: nil,
                ready: false,
                merges: [],
                verify: nil
            )
            try database.upsertRunIntegration(runID: runID, nothingToMerge)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                    integration: nothingToMerge,
                    language: language
                )
            )
            return nothingToMerge
        }

        // 4. Create `relay/<runID>/integration` worktree at `<project>/runs/<runID>/worktrees/integration` (`03-relayide.md` M2 §3, Row 22).
        let initialMerges = mergeOrderIDs.enumerated().map { ordinal, laneID in
            RelayRunMergeRecord(
                ordinal: ordinal,
                laneID: laneID,
                laneCommitOID: laneByID[laneID]?.commitOID,
                status: .notAttempted,
                mergeCommitOID: nil,
                conflicts: [],
                conflictLines: [],
                startedAt: nil,
                finishedAt: nil
            )
        }

        let worktreeHandle: GitWorktreePlumbingEngine.IntegrationWorktreeHandle
        do {
            worktreeHandle = try gitEngine.createIntegrationWorktree(
                repositoryPath: repositoryPath,
                projectBundlePath: projectBundlePath,
                runID: runID,
                baseCommitOID: baseCommitOID,
                environment: environment
            )
        } catch let relayErr as RelayIDEError {
            let failedIntegration = RelayRunIntegrationRecord(
                branch: nil,
                worktreePath: nil,
                baseCommitOID: baseCommitOID,
                headCommitOID: nil,
                status: .error,
                reason: Self.extractIntegrationErrorReason(from: relayErr),
                ready: false,
                merges: [],
                verify: nil
            )
            try? database.upsertRunIntegration(runID: runID, failedIntegration)
            throw relayErr
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            let failedIntegration = RelayRunIntegrationRecord(
                branch: nil,
                worktreePath: nil,
                baseCommitOID: baseCommitOID,
                headCommitOID: nil,
                status: .error,
                reason: error.localizedDescription,
                ready: false,
                merges: [],
                verify: nil
            )
            try? database.upsertRunIntegration(runID: runID, failedIntegration)
            throw wrapped
        }

        var integration = RelayRunIntegrationRecord(
            branch: worktreeHandle.branchName,
            worktreePath: worktreeHandle.worktreePath,
            baseCommitOID: baseCommitOID,
            headCommitOID: baseCommitOID,
            status: .merging,
            reason: nil,
            ready: false,
            merges: initialMerges,
            verify: nil
        )
        try database.upsertRunIntegration(runID: runID, integration)
        onStderrLine(
            RelayIntegrationStderrFormatter.formatIntegrationBranchCreatedLine(
                branchName: worktreeHandle.branchName,
                worktreePath: worktreeHandle.worktreePath,
                baseCommitOID: baseCommitOID,
                language: language
            )
        )

        // 5. Sequentially merge each lane in `mergeOrderIDs`, checking `isCancelled()` before every step (D3, §5, §7).
        for (stepIndex, laneID) in mergeOrderIDs.enumerated() {
            if isCancelled() {
                integration.status = .cancelled
                integration.reason = "cancelled"
                integration.ready = false
                try database.upsertRunIntegration(runID: runID, integration)
                onStderrLine(
                    RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                        integration: integration,
                        language: language
                    )
                )
                return integration
            }

            guard let lane = laneByID[laneID] else {
                throw RelayIDEError.relayEnvironmentFailure(
                    "Missing lane record '\(laneID)' during integration merge of run '\(runID)'"
                )
            }

            let stepOutcome = try mergeSingleLaneStep(
                runID: runID,
                stepIndex: stepIndex,
                lane: lane,
                integration: &integration,
                database: database,
                gitEngine: gitEngine,
                language: language,
                environment: environment,
                onStderrLine: onStderrLine
            )

            if case .conflict = stepOutcome {
                if isCancelled() {
                    integration.status = .cancelled
                    integration.reason = "cancelled"
                    integration.ready = false
                    try database.upsertRunIntegration(runID: runID, integration)
                }
                onStderrLine(
                    RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                        integration: integration,
                        language: language
                    )
                )
                return integration
            }
        }

        if isCancelled() {
            integration.status = .cancelled
            integration.reason = "cancelled"
            integration.ready = false
            try database.upsertRunIntegration(runID: runID, integration)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                    integration: integration,
                    language: language
                )
            )
            return integration
        }

        // 6. All lane merges succeeded: stop at `merged` with `ready = false` (`verify` connects in Stages 3 & 4).
        integration.status = .merged
        integration.reason = nil
        integration.ready = false
        try database.upsertRunIntegration(runID: runID, integration)
        if emitSummaryLineOnMerged {
            onStderrLine(
                RelayIntegrationStderrFormatter.formatIntegrationSummaryLine(
                    integration: integration,
                    language: language
                )
            )
        }
        return integration
    }
    @discardableResult
    public static func mergeSingleLaneStep(
        runID: String,
        stepIndex: Int,
        lane: RelayRunLaneRecord,
        integration: inout RelayRunIntegrationRecord,
        database: RelayProjectDatabase,
        gitEngine: GitWorktreePlumbingEngine = GitWorktreePlumbingEngine(),
        language: RelayLanguage = .en,
        environment: [String: String]? = nil,
        onStderrLine: @Sendable (String) -> Void = { _ in }
    ) throws -> GitWorktreePlumbingEngine.SingleLaneGitMergeOutcome {
        guard stepIndex >= 0, stepIndex < integration.merges.count else {
            throw RelayIDEError.relayEnvironmentFailure(
                "Invalid merge step index \(stepIndex) for run '\(runID)'"
            )
        }
        guard let worktreePath = integration.worktreePath, !worktreePath.isEmpty else {
            throw RelayIDEError.relayEnvironmentFailure(
                "Integration worktree path missing when merging lane '\(lane.laneID)' in run '\(runID)'"
            )
        }

        let startedAt = Date()
        let outcome: GitWorktreePlumbingEngine.SingleLaneGitMergeOutcome
        do {
            outcome = try gitEngine.mergeLaneCommitInIntegrationWorktree(
                integrationWorktreePath: worktreePath,
                runID: runID,
                laneID: lane.laneID,
                agent: lane.agent,
                laneBranchName: lane.branch,
                laneCommitOID: lane.commitOID,
                environment: environment
            )
        } catch let relayErr as RelayIDEError {
            integration.status = .error
            integration.ready = false
            integration.reason = Self.extractIntegrationErrorReason(from: relayErr)
            try? database.upsertRunIntegration(runID: runID, integration)
            throw relayErr
        } catch {
            let wrapped = RelayIDEError.relayEnvironmentFailure(error.localizedDescription)
            integration.status = .error
            integration.ready = false
            integration.reason = error.localizedDescription
            try? database.upsertRunIntegration(runID: runID, integration)
            throw wrapped
        }

        let finishedAt = Date()
        switch outcome {
        case .noChanges:
            integration.merges[stepIndex].laneCommitOID = lane.commitOID
            integration.merges[stepIndex].status = .noChanges
            integration.merges[stepIndex].mergeCommitOID = nil
            integration.merges[stepIndex].conflicts = []
            integration.merges[stepIndex].conflictLines = []
            integration.merges[stepIndex].startedAt = startedAt
            integration.merges[stepIndex].finishedAt = finishedAt
            try database.updateRunMerge(runID: runID, integration.merges[stepIndex])
            try database.upsertRunIntegration(runID: runID, integration)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatMergeStepLine(
                    step: integration.merges[stepIndex],
                    agent: lane.agent,
                    language: language
                )
            )
            return .noChanges

        case .merged(let mergeCommitOID):
            integration.merges[stepIndex].laneCommitOID = lane.commitOID
            integration.merges[stepIndex].status = .merged
            integration.merges[stepIndex].mergeCommitOID = mergeCommitOID
            integration.merges[stepIndex].conflicts = []
            integration.merges[stepIndex].conflictLines = []
            integration.merges[stepIndex].startedAt = startedAt
            integration.merges[stepIndex].finishedAt = finishedAt
            integration.headCommitOID = mergeCommitOID
            try database.updateRunMerge(runID: runID, integration.merges[stepIndex])
            try database.upsertRunIntegration(runID: runID, integration)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatMergeStepLine(
                    step: integration.merges[stepIndex],
                    agent: lane.agent,
                    language: language
                )
            )
            return .merged(mergeCommitOID: mergeCommitOID)

        case .conflict(let conflicts, let conflictLines, let headCommitOID):
            integration.merges[stepIndex].laneCommitOID = lane.commitOID
            integration.merges[stepIndex].status = .conflict
            integration.merges[stepIndex].mergeCommitOID = nil
            integration.merges[stepIndex].conflicts = conflicts
            integration.merges[stepIndex].conflictLines = conflictLines
            integration.merges[stepIndex].startedAt = startedAt
            integration.merges[stepIndex].finishedAt = finishedAt
            for remainingIdx in (stepIndex + 1)..<integration.merges.count {
                integration.merges[remainingIdx].status = .notAttempted
                integration.merges[remainingIdx].mergeCommitOID = nil
                integration.merges[remainingIdx].conflicts = []
                integration.merges[remainingIdx].conflictLines = []
                integration.merges[remainingIdx].startedAt = nil
                integration.merges[remainingIdx].finishedAt = nil
            }
            integration.headCommitOID = headCommitOID
            integration.status = .conflict
            integration.reason = "merge conflict in lane '\(lane.laneID)'"
            integration.ready = false
            try database.updateRunMerge(runID: runID, integration.merges[stepIndex])
            try database.upsertRunIntegration(runID: runID, integration)
            onStderrLine(
                RelayIntegrationStderrFormatter.formatMergeStepLine(
                    step: integration.merges[stepIndex],
                    agent: lane.agent,
                    language: language
                )
            )
            return .conflict(
                conflicts: conflicts,
                conflictLines: conflictLines,
                headCommitOID: headCommitOID
            )

        case .nonConflictError(let exitCode, let lastStderrLine, let command):
            integration.status = .error
            integration.reason = lastStderrLine
            integration.ready = false
            try database.upsertRunIntegration(runID: runID, integration)
            throw RelayIDEError.gitPlumbingFailure(
                command: command,
                exitCode: exitCode,
                stderr: lastStderrLine
            )
        }
    }

    internal static func extractIntegrationErrorReason(from error: RelayIDEError) -> String {
        switch error {
        case .gitPlumbingFailure(_, _, let stderr):
            return GitWorktreePlumbingEngine.preferredErrorReasonLine(stderr: stderr)
                ?? error.localizedDescription(in: .en)
        case .relayEnvironmentFailure(let message):
            return message
        default:
            return error.localizedDescription(in: .en)
        }
    }
}
