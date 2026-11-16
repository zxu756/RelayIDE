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
