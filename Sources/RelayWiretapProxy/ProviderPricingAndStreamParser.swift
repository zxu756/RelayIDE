import Foundation
import RelayModels

// MARK: - Multi-Vendor Model Token Pricing Catalog

public struct ModelPricingRate: Sendable, Codable, Hashable {
    public let modelPrefix: String
    public let vendor: AgentVendor
    public let inputUSDPerMillion: Double
    public let cachedInputUSDPerMillion: Double
    public let outputUSDPerMillion: Double
    public let reasoningUSDPerMillion: Double

    public init(
        modelPrefix: String,
        vendor: AgentVendor,
        inputUSDPerMillion: Double,
        cachedInputUSDPerMillion: Double,
        outputUSDPerMillion: Double,
        reasoningUSDPerMillion: Double = 0.0
    ) {
        self.modelPrefix = modelPrefix
        self.vendor = vendor
        self.inputUSDPerMillion = inputUSDPerMillion
        self.cachedInputUSDPerMillion = cachedInputUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
        self.reasoningUSDPerMillion = reasoningUSDPerMillion
    }

    public func estimateCostUSD(
        inputTokens: Int,
        cachedReadTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int
    ) -> Double {
        let nonCachedInput = max(0, inputTokens - cachedReadTokens)
        let inCost = Double(nonCachedInput) * (inputUSDPerMillion / 1_000_000.0)
        let cacheCost = Double(max(0, cachedReadTokens)) * (cachedInputUSDPerMillion / 1_000_000.0)
        let outCost = Double(max(0, outputTokens)) * (outputUSDPerMillion / 1_000_000.0)
        let reasonCost = Double(max(0, reasoningTokens)) * ((reasoningUSDPerMillion > 0 ? reasoningUSDPerMillion : outputUSDPerMillion) / 1_000_000.0)
        return inCost + cacheCost + outCost + reasonCost
    }
}

public struct ProviderPricingCatalog: Sendable {
    public let rates: [ModelPricingRate]

    public init(rates: [ModelPricingRate] = ProviderPricingCatalog.defaultRates) {
        self.rates = rates
    }

    public static let defaultRates: [ModelPricingRate] = [
        ModelPricingRate(
            modelPrefix: "claude-opus-4",
            vendor: .claudeCode,
            inputUSDPerMillion: 15.00,
            cachedInputUSDPerMillion: 1.50,
            outputUSDPerMillion: 75.00
        ),
        ModelPricingRate(
            modelPrefix: "claude-sonnet-4",
            vendor: .claudeCode,
            inputUSDPerMillion: 3.00,
            cachedInputUSDPerMillion: 0.30,
            outputUSDPerMillion: 15.00
        ),
        ModelPricingRate(
            modelPrefix: "claude-3-5-haiku",
            vendor: .claudeCode,
            inputUSDPerMillion: 0.80,
            cachedInputUSDPerMillion: 0.08,
            outputUSDPerMillion: 4.00
        ),
        ModelPricingRate(
            modelPrefix: "gpt-5",
            vendor: .codex,
            inputUSDPerMillion: 2.50,
            cachedInputUSDPerMillion: 0.25,
            outputUSDPerMillion: 10.00,
            reasoningUSDPerMillion: 10.00
        ),
        ModelPricingRate(
            modelPrefix: "codex-mini",
            vendor: .codex,
            inputUSDPerMillion: 1.50,
            cachedInputUSDPerMillion: 0.375,
            outputUSDPerMillion: 6.00,
            reasoningUSDPerMillion: 6.00
        ),
        ModelPricingRate(
            modelPrefix: "o3",
            vendor: .codex,
            inputUSDPerMillion: 2.00,
            cachedInputUSDPerMillion: 0.50,
            outputUSDPerMillion: 8.00,
            reasoningUSDPerMillion: 8.00
        ),
        ModelPricingRate(
            modelPrefix: "gemini-2.5-pro",
            vendor: .antigravity,
            inputUSDPerMillion: 1.25,
            cachedInputUSDPerMillion: 0.31,
            outputUSDPerMillion: 10.00,
            reasoningUSDPerMillion: 10.00
        ),
        ModelPricingRate(
            modelPrefix: "gemini-2.5-flash",
            vendor: .antigravity,
            inputUSDPerMillion: 0.15,
            cachedInputUSDPerMillion: 0.0375,
            outputUSDPerMillion: 0.60
        ),
        ModelPricingRate(
            modelPrefix: "devstral",
            vendor: .mistralVibe,
            inputUSDPerMillion: 0.40,
            cachedInputUSDPerMillion: 0.10,
            outputUSDPerMillion: 2.00
        ),
        ModelPricingRate(
            modelPrefix: "codestral",
            vendor: .mistralVibe,
            inputUSDPerMillion: 0.30,
            cachedInputUSDPerMillion: 0.08,
            outputUSDPerMillion: 0.90
        )
    ]

    public func matchRate(for modelIdentifier: String, fallbackVendor: AgentVendor) -> ModelPricingRate {
        let lower = modelIdentifier.lowercased()
        if let matched = rates.first(where: { lower.contains($0.modelPrefix.lowercased()) }) {
            return matched
        }
        switch fallbackVendor {
        case .claudeCode:
            return rates[1]
        case .codex:
            return rates[3]
        case .antigravity:
            return rates[6]
        case .mistralVibe:
            return rates[8]
        case .customShell:
            return ModelPricingRate(
                modelPrefix: "shell",
                vendor: .customShell,
                inputUSDPerMillion: 0,
                cachedInputUSDPerMillion: 0,
                outputUSDPerMillion: 0
            )
        }
    }
}

// MARK: - Multi-Provider JSON & SSE Usage Telemetry Extractor

public struct ExtractedUsagePayload: Sendable, Equatable {
    public var modelIdentifier: String
    public var inputTokens: Int
    public var cachedReadTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int

    public init(
        modelIdentifier: String = "unknown-model",
        inputTokens: Int = 0,
        cachedReadTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0
    ) {
        self.modelIdentifier = modelIdentifier
        self.inputTokens = inputTokens
        self.cachedReadTokens = cachedReadTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public struct ProviderTokenStreamParser: Sendable {
    public init() {}

    /// Parses non-streaming JSON responses OR Server-Sent Events (`data: {...}`) streams from Anthropic, OpenAI/Codex, Gemini, and Mistral.
    public func parsePayload(responseBody: Data, requestBody: Data? = nil) -> ExtractedUsagePayload {
        var result = ExtractedUsagePayload()

        if let reqBody = requestBody,
           let reqObj = try? JSONSerialization.jsonObject(with: reqBody) as? [String: Any],
           let reqModel = reqObj["model"] as? String, !reqModel.isEmpty {
            result.modelIdentifier = reqModel
        }

        if let jsonObj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] {
            mergeJSONDictionary(jsonObj, into: &result)
            return result
        }

        // SSE event-stream fallback (`data: {...}`)
        let text = String(decoding: responseBody, as: UTF8.self)
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonSlice = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if jsonSlice == "[DONE]" || jsonSlice.isEmpty { continue }
            if let lineData = jsonSlice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                mergeJSONDictionary(obj, into: &result)
            }
        }
        return result
    }

    private func mergeJSONDictionary(_ dict: [String: Any], into acc: inout ExtractedUsagePayload) {
        if let model = dict["model"] as? String, !model.isEmpty {
            acc.modelIdentifier = model
        }
        if let msg = dict["message"] as? [String: Any] {
            mergeJSONDictionary(msg, into: &acc)
        }
        if let response = dict["response"] as? [String: Any] {
            mergeJSONDictionary(response, into: &acc)
        }

        // Anthropic & OpenAI `usage` dictionary
        if let usage = dict["usage"] as? [String: Any] {
            if let inTok = usage["input_tokens"] as? Int {
                acc.inputTokens = max(acc.inputTokens, inTok)
            }
            if let promptTok = usage["prompt_tokens"] as? Int {
                acc.inputTokens = max(acc.inputTokens, promptTok)
            }
            if let cacheRead = usage["cache_read_input_tokens"] as? Int {
                acc.cachedReadTokens = max(acc.cachedReadTokens, cacheRead)
            }
            if let promptDetails = usage["prompt_tokens_details"] as? [String: Any],
               let cached = promptDetails["cached_tokens"] as? Int {
                acc.cachedReadTokens = max(acc.cachedReadTokens, cached)
            }
            if let inputDetails = usage["input_tokens_details"] as? [String: Any],
               let cached = inputDetails["cached_tokens"] as? Int {
                acc.cachedReadTokens = max(acc.cachedReadTokens, cached)
            }
            if let outTok = usage["output_tokens"] as? Int {
                acc.outputTokens = max(acc.outputTokens, outTok)
            }
            if let compTok = usage["completion_tokens"] as? Int {
                acc.outputTokens = max(acc.outputTokens, compTok)
            }
            if let compDetails = usage["completion_tokens_details"] as? [String: Any],
               let reason = compDetails["reasoning_tokens"] as? Int {
                acc.reasoningTokens = max(acc.reasoningTokens, reason)
            }
            if let outDetails = usage["output_tokens_details"] as? [String: Any],
               let reason = outDetails["reasoning_tokens"] as? Int {
                acc.reasoningTokens = max(acc.reasoningTokens, reason)
            }
        }

        // Gemini `usageMetadata` dictionary
        if let geminiUsage = dict["usageMetadata"] as? [String: Any] {
            if let p = geminiUsage["promptTokenCount"] as? Int {
                acc.inputTokens = max(acc.inputTokens, p)
            }
            if let c = geminiUsage["cachedContentTokenCount"] as? Int {
                acc.cachedReadTokens = max(acc.cachedReadTokens, c)
            }
            if let o = geminiUsage["candidatesTokenCount"] as? Int {
                acc.outputTokens = max(acc.outputTokens, o)
            }
            if let t = geminiUsage["thoughtsTokenCount"] as? Int {
                acc.reasoningTokens = max(acc.reasoningTokens, t)
            }
        }
    }
}
