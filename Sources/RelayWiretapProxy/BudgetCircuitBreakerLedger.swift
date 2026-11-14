import Foundation
import RelayModels

// MARK: - Thread-Safe Per-Lane & Global Budget Circuit Breaker

public final class BudgetCircuitBreakerLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let pricingCatalog: ProviderPricingCatalog
    private var accountsByLane: [String: LaneBudgetAccount] = [:]
    private var spans: [WiretapAPISpan] = []
    private var globalCeilingUSD: Double

    public init(
        globalCeilingUSD: Double = 25.0,
        pricingCatalog: ProviderPricingCatalog = ProviderPricingCatalog()
    ) {
        self.globalCeilingUSD = globalCeilingUSD
        self.pricingCatalog = pricingCatalog
    }

    public func registerLane(laneID: String, vendor: AgentVendor, ceilingUSD: Double) {
        lock.lock()
        defer { lock.unlock() }
        if var existing = accountsByLane[laneID] {
            existing.ceilingUSD = ceilingUSD
            existing.circuitOpen = existing.spentUSD >= ceilingUSD
            accountsByLane[laneID] = existing
        } else {
            accountsByLane[laneID] = LaneBudgetAccount(
                laneID: laneID,
                vendor: vendor,
                ceilingUSD: ceilingUSD
            )
        }
    }

    public func setGlobalCeilingUSD(_ ceiling: Double) {
        lock.lock()
        defer { lock.unlock() }
        globalCeilingUSD = max(0.01, ceiling)
    }

    public func checkAdmission(forLane laneID: String) throws {
        try lock.withLock {
            let totalSpent = accountsByLane.values.reduce(0.0) { $0 + $1.spentUSD }
            if totalSpent >= globalCeilingUSD {
                throw RelayIDEError.budgetCircuitTripped(
                    laneID: laneID,
                    spentUSD: totalSpent,
                    limitUSD: globalCeilingUSD
                )
            }
            if let account = accountsByLane[laneID], (account.circuitOpen || account.spentUSD >= account.ceilingUSD) {
                throw RelayIDEError.budgetCircuitTripped(
                    laneID: laneID,
                    spentUSD: account.spentUSD,
                    limitUSD: account.ceilingUSD
                )
            }
        }
    }

    @discardableResult
    public func recordUsage(
        laneID: String,
        taskID: String? = nil,
        vendor: AgentVendor,
        providerHost: String,
        usage: ExtractedUsagePayload,
        durationMs: Double,
        statusCode: Int = 200
    ) -> WiretapAPISpan {
        let rate = pricingCatalog.matchRate(for: usage.modelIdentifier, fallbackVendor: vendor)
        let cost = rate.estimateCostUSD(
            inputTokens: usage.inputTokens,
            cachedReadTokens: usage.cachedReadTokens,
            outputTokens: usage.outputTokens,
            reasoningTokens: usage.reasoningTokens
        )

        lock.lock()
        defer { lock.unlock() }

        var account = accountsByLane[laneID] ?? LaneBudgetAccount(
            laneID: laneID,
            vendor: vendor,
            ceilingUSD: 10.0
        )
        account.requestCount += 1
        account.inputTokens += usage.inputTokens
        account.cachedTokens += usage.cachedReadTokens
        account.outputTokens += (usage.outputTokens + usage.reasoningTokens)
        account.spentUSD += cost
        if account.spentUSD >= account.ceilingUSD {
            account.circuitOpen = true
        }
        accountsByLane[laneID] = account

        let span = WiretapAPISpan(
            laneID: laneID,
            taskID: taskID,
            vendor: vendor,
            providerHost: providerHost,
            modelIdentifier: usage.modelIdentifier,
            inputTokens: usage.inputTokens,
            cachedReadTokens: usage.cachedReadTokens,
            outputTokens: usage.outputTokens,
            reasoningTokens: usage.reasoningTokens,
            costUSD: cost,
            durationMs: durationMs,
            statusCode: statusCode,
            blockedByCircuitBreaker: account.circuitOpen
        )
        spans.append(span)
        return span
    }

    public func recordBlockedAttempt(laneID: String, vendor: AgentVendor, providerHost: String) -> WiretapAPISpan {
        lock.lock()
        defer { lock.unlock() }
        let span = WiretapAPISpan(
            laneID: laneID,
            vendor: vendor,
            providerHost: providerHost,
            modelIdentifier: "circuit-breaker-halted",
            inputTokens: 0,
            outputTokens: 0,
            costUSD: 0.0,
            durationMs: 0.2,
            statusCode: 429,
            blockedByCircuitBreaker: true
        )
        spans.append(span)
        return span
    }

    public func resetCircuit(forLane laneID: String, newCeilingUSD: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountsByLane[laneID] else { return }
        if let ceiling = newCeilingUSD {
            account.ceilingUSD = ceiling
        }
        account.circuitOpen = account.spentUSD >= account.ceilingUSD
        accountsByLane[laneID] = account
    }

    public func allAccounts() -> [LaneBudgetAccount] {
        lock.lock()
        defer { lock.unlock() }
        return accountsByLane.values.sorted { $0.laneID < $1.laneID }
    }

    public func allSpans() -> [WiretapAPISpan] {
        lock.lock()
        defer { lock.unlock() }
        return spans
    }

    public func totalSpendUSD() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return accountsByLane.values.reduce(0.0) { $0 + $1.spentUSD }
    }
}
