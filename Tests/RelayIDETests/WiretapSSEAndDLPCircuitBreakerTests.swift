import Foundation
import RelayModels
import RelayWiretapProxy
import Testing

@Suite("Loopback Wiretap Proxy, HTTP/1.1 & Multi-Vendor SSE Dissector, DLP & Burn-Rate Circuit Breaker")
struct WiretapSSEAndDLPCircuitBreakerTests {

    // MARK: - 1. `HTTP11WireStateMachine` Chunked Transfer Reassembly & Trailers

    @Test("HTTP11WireStateMachine reassembles fragmented chunked Transfer-Encoding bodies and trailing headers")
    func http11ChunkedTransferReassemblyAcrossFragmentedReads() throws {
        let payloadString = String(repeating: "data: {\"delta\":\"bauhaus-sse-chunk\"}\n\n", count: 12)
        let originalBody = Data(payloadString.utf8)

        var trailers = HTTPHeaderMap()
        trailers.set(name: "X-Relay-Checksum", value: "sha256-verified")
        let chunkedWireBody = HTTP11WireStateMachine.encodeChunkedBody(
            originalBody,
            maxChunkSize: 37,
            trailers: trailers
        )

        let rawHead =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "Trailer: X-Relay-Checksum\r\n" +
            "x-request-id: req_anthropic_99\r\n\r\n"

        var fullWire = Data(rawHead.utf8)
        fullWire.append(chunkedWireBody)

        final class LockedDataBox: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var data = Data()
            func append(_ slice: Data) {
                lock.lock()
                data.append(slice)
                lock.unlock()
            }
        }
        var machine = HTTP11WireStateMachine(expectedRole: .response)
        let streamedBytes = LockedDataBox()
        machine.onBodySliceDecoded = { slice in
            streamedBytes.append(slice)
        }

        // Feed in prime-sized 13-byte fragments to stress every state boundary (hex digits, CRLF, trailers)
        var parsedMessages: [HTTP11DissectedMessage] = []
        var offset = 0
        while offset < fullWire.count {
            let end = min(offset + 13, fullWire.count)
            let msgs = try machine.feed(fullWire.subdata(in: offset..<end))
            parsedMessages.append(contentsOf: msgs)
            offset = end
        }

        #expect(parsedMessages.count == 1)
        let msg = parsedMessages[0]
        #expect(msg.startLine.statusCode == 200)
        #expect(msg.wasChunked == true)
        #expect(msg.headers.isEventStreamContentType == true)
        #expect(msg.headers.requestID == "req_anthropic_99")
        #expect(msg.body == originalBody)
        #expect(streamedBytes.data == originalBody)
        #expect(msg.trailers.value(for: "x-relay-checksum") == "sha256-verified")
        #expect(msg.chunkFrames.count >= 10)
        #expect(machine.isIdleAtBoundary == true)
    }

    // MARK: - 2. `HTTP11WireStateMachine` Smuggling Guard & Pipelined Requests

    @Test("HTTP11WireStateMachine parses pipelined requests and rejects conflicting Content-Length + Transfer-Encoding")
    func http11PipelinedRequestsAndSmugglingRejection() throws {
        var reqMachine = HTTP11WireStateMachine(expectedRole: .request)
        let req1Body = #"{"model":"claude-sonnet-4-5"}"#
        let req2Body = #"{"model":"gpt-5-codex"}"#
        let pipelined =
            "POST /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\nContent-Length: \(req1Body.utf8.count)\r\n\r\n\(req1Body)" +
            "POST /v1/responses HTTP/1.1\r\nHost: api.openai.com\r\nContent-Length: \(req2Body.utf8.count)\r\n\r\n\(req2Body)"

        let decoded = try reqMachine.feed(Data(pipelined.utf8))
        #expect(decoded.count == 2)
        #expect(decoded[0].startLine.requestPath == "/v1/messages")
        #expect(decoded[1].startLine.requestPath == "/v1/responses")

        // RFC 9112 smuggling attempt: both Transfer-Encoding: chunked and Content-Length present
        var smuggledMachine = HTTP11WireStateMachine(expectedRole: .request)
        let smuggled =
            "POST /v1/messages HTTP/1.1\r\n" +
            "Host: api.anthropic.com\r\n" +
            "Content-Length: 4\r\n" +
            "Transfer-Encoding: chunked\r\n\r\n" +
            "0\r\n\r\n"
        #expect(throws: HTTP11DissectorError.self) {
            _ = try smuggledMachine.feed(Data(smuggled.utf8))
        }
    }

    // MARK: - 3. `SSEEventStreamReassembler` Multi-Line Data, Comments & `[DONE]` Sentinel

    @Test("SSEEventStreamReassembler reconstructs split SSE frames, comments, retry hints, and [DONE] sentinels")
    func sseEventStreamReassemblerFragmentedFrames() {
        let rawSSE = """
        : keep-alive ping
        id: evt-01
        retry: 1500
        event: content_block_delta
        data: {"line":1,
        data: "text":"hello"}

        data: [DONE]

        """

        var reassembler = SSEEventStreamReassembler()
        let bytes = Array(rawSSE.utf8)
        var events: [SSEWireEvent] = []
        for idx in stride(from: 0, to: bytes.count, by: 9) {
            let chunk = Data(bytes[idx..<min(idx + 9, bytes.count)])
            events.append(contentsOf: reassembler.feed(chunk, timestampNs: UInt64(idx + 1) * 1_000_000))
        }
        events.append(contentsOf: reassembler.flushEOF(timestampNs: 99_000_000))

        #expect(events.count == 2)
        #expect(events[0].eventIDHeader == "evt-01")
        #expect(events[0].retryMilliseconds == 1500)
        #expect(events[0].eventType == "content_block_delta")
        #expect(events[0].comments == ["keep-alive ping"])
        #expect(events[0].data == "{\"line\":1,\n\"text\":\"hello\"}")
        #expect(events[1].isDoneSentinel == true)
    }

    // MARK: - 4. `MultiVendorSSEDissector`: Anthropic Messages SSE (Cache + Thinking + Tool Call)

    @Test("MultiVendorSSEDissector dissects Anthropic Messages SSE with prompt cache, extended thinking, and tool calls")
    func dissectAnthropicMessagesSSEStream() {
        let anthropicSSE = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_01CC","model":"claude-sonnet-4-5-20260901","usage":{"input_tokens":1200,"cache_read_input_tokens":8000,"cache_creation_input_tokens":500,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Analyzing BillingEngine AST boundaries..."}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_ed25519_abc"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Applying clean 3-way merge."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"edit_file","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"Sources/"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"Billing.swift\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":2}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":340}}

        event: message_stop
        data: {"type":"message_stop"}

        """

        var headers = HTTPHeaderMap()
        headers.set(name: "Content-Type", value: "text/event-stream")

        let dissector = MultiVendorSSEDissector()
        let report = dissector.dissectInteraction(
            laneID: "lane-claude",
            taskID: "task-arch",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com",
            requestPath: "/v1/messages",
            requestBody: Data(#"{"model":"claude-sonnet-4-5"}"#.utf8),
            responseStatusCode: 200,
            responseHeaders: headers,
            responseBody: Data(anthropicSSE.utf8),
            requestStartNs: 1_000_000_000,
            firstTokenObservedNs: 1_180_000_000,
            responseEndNs: 2_400_000_000,
            dlpScanDurationMs: 0.45
        )

        #expect(report.dialect == .anthropicMessages)
        #expect(report.responseMessageID == "msg_01CC")
        #expect(report.stopReason == "tool_use")
        #expect(report.assistantText == "Applying clean 3-way merge.")
        #expect(report.thinkingBlocks.count == 1)
        #expect(report.thinkingBlocks[0].thinkingText.contains("BillingEngine"))
        #expect(report.thinkingBlocks[0].cryptographicSignature == "sig_ed25519_abc")
        #expect(report.toolCalls.count == 1)
        #expect(report.toolCalls[0].toolName == "edit_file")
        #expect(report.toolCalls[0].rawArgumentsJSON == #"{"path":"Sources/Billing.swift"}"#)
        #expect(report.cacheMetrics.cacheReadTokens == 8000)
        #expect(report.cacheMetrics.cacheWriteTokens == 500)
        #expect(report.cacheMetrics.outputTokens == 340)
        #expect(report.cacheMetrics.estimatedCacheSavingsUSD > 0)
        #expect(abs(report.latencyAndThroughput.ttftMs - 180.0) < 1.0)
        #expect(report.estimatedCostUSD > 0)
        #expect(report.flameSpans.contains { $0.kind == .requestTurnRoot })
        #expect(report.flameSpans.contains { $0.kind == .providerQueueTTFT })
    }

    // MARK: - 5. `MultiVendorSSEDissector`: OpenAI Responses SSE Stream

    @Test("MultiVendorSSEDissector dissects OpenAI Responses SSE with cached & reasoning token accounting")
    func dissectOpenAIResponsesSSEStream() {
        let openAISSE = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_cx_01","model":"gpt-5-codex"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_99","name":"run_tests"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Running test suite now."}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","output_index":0,"call_id":"call_99","delta":"{\\"filter\\":\\"BillingTests\\"}"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_cx_01","model":"gpt-5-codex","status":"completed","usage":{"input_tokens":5000,"input_tokens_details":{"cached_tokens":3500},"output_tokens":900,"output_tokens_details":{"reasoning_tokens":600}}}}

        """

        var headers = HTTPHeaderMap()
        headers.set(name: "Content-Type", value: "text/event-stream")

        let report = MultiVendorSSEDissector().dissectInteraction(
            laneID: "lane-codex",
            taskID: "task-impl",
            vendor: .codex,
            providerHost: "api.openai.com",
            requestPath: "/v1/responses",
            requestBody: Data(),
            responseStatusCode: 200,
            responseHeaders: headers,
            responseBody: Data(openAISSE.utf8),
            requestStartNs: 0,
            firstTokenObservedNs: 120_000_000,
            responseEndNs: 950_000_000
        )

        #expect(report.dialect == .openAIResponses)
        #expect(report.modelIdentifier == "gpt-5-codex")
        #expect(report.assistantText == "Running test suite now.")
        #expect(report.cacheMetrics.cacheReadTokens == 3500)
        #expect(report.cacheMetrics.reasoningTokens == 600)
        #expect(report.cacheMetrics.outputTokens == 900)
        #expect(!report.toolCalls.isEmpty)
    }

    // MARK: - 6. `MultiVendorSSEDissector`: Google Gemini & Mistral Vibe SSE Streams

    @Test("MultiVendorSSEDissector dissects Google Gemini streamGenerateContent and Mistral Chat SSE")
    func dissectGeminiAndMistralSSEStreams() {
        let geminiSSE = """
        data: {"modelVersion":"gemini-2.5-pro","candidates":[{"content":{"parts":[{"thought":true,"text":"Checking docs coverage..."}]}}]}

        data: {"modelVersion":"gemini-2.5-pro","candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Documentation updated."},{"functionCall":{"name":"write_doc","args":{"file":"README.md"}}}]}}],"usageMetadata":{"promptTokenCount":4000,"cachedContentTokenCount":2500,"candidatesTokenCount":300,"thoughtsTokenCount":180}}

        """

        let mistralSSE = """
        data: {"id":"cmpl-vibe-1","model":"devstral-medium-2507","choices":[{"index":0,"delta":{"content":"Verified 42 assertions."},"finish_reason":null}]}

        data: {"id":"cmpl-vibe-1","model":"devstral-medium-2507","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_v1","function":{"name":"report_gate","arguments":"{\\"passed\\":true}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1800,"completion_tokens":220}}

        data: [DONE]

        """

        var headers = HTTPHeaderMap()
        headers.set(name: "Content-Type", value: "text/event-stream")
        let dissector = MultiVendorSSEDissector()

        let geminiReport = dissector.dissectInteraction(
            laneID: "lane-agy",
            taskID: "task-docs",
            vendor: .antigravity,
            providerHost: "generativelanguage.googleapis.com",
            requestPath: "/v1beta/models/gemini-2.5-pro:streamGenerateContent",
            requestBody: Data(),
            responseStatusCode: 200,
            responseHeaders: headers,
            responseBody: Data(geminiSSE.utf8),
            requestStartNs: 0,
            firstTokenObservedNs: 90_000_000,
            responseEndNs: 600_000_000
        )
        #expect(geminiReport.dialect == .googleGeminiStream)
        #expect(geminiReport.assistantText == "Documentation updated.")
        #expect(geminiReport.cacheMetrics.cacheReadTokens == 2500)
        #expect(geminiReport.cacheMetrics.reasoningTokens == 180)
        #expect(geminiReport.toolCalls.contains { $0.toolName == "write_doc" })

        let mistralReport = dissector.dissectInteraction(
            laneID: "lane-vibe",
            taskID: "task-test",
            vendor: .mistralVibe,
            providerHost: "api.mistral.ai",
            requestPath: "/v1/chat/completions",
            requestBody: Data(),
            responseStatusCode: 200,
            responseHeaders: headers,
            responseBody: Data(mistralSSE.utf8),
            requestStartNs: 0,
            firstTokenObservedNs: 70_000_000,
            responseEndNs: 450_000_000
        )
        #expect(mistralReport.dialect == .mistralChatSSE)
        #expect(mistralReport.assistantText == "Verified 42 assertions.")
        #expect(mistralReport.toolCalls.contains { $0.toolName == "report_gate" })
        #expect(mistralReport.cacheMetrics.outputTokens == 220)
    }

    // MARK: - 7. `ProviderPricingCatalog` & `ProviderTokenStreamParser` Rate Matching

    @Test("ProviderPricingCatalog matches vendor prefixes and computes cached vs uncached token costs")
    func providerPricingCatalogAndTokenStreamParser() {
        let catalog = ProviderPricingCatalog()
        let claudeRate = catalog.matchRate(for: "claude-sonnet-4-5-20260901", fallbackVendor: .claudeCode)
        // Cached tokens must cost strictly less per token than uncached input tokens
        #expect(claudeRate.cachedInputUSDPerMillion < claudeRate.inputUSDPerMillion)

        let costNoCache = claudeRate.estimateCostUSD(
            inputTokens: 100_000,
            cachedReadTokens: 0,
            outputTokens: 10_000,
            reasoningTokens: 0
        )
        let costWithCache = claudeRate.estimateCostUSD(
            inputTokens: 20_000,
            cachedReadTokens: 80_000,
            outputTokens: 10_000,
            reasoningTokens: 0
        )
        #expect(costWithCache < costNoCache)

        let parser = ProviderTokenStreamParser()
        let jsonBody = Data(
            #"{"model":"gpt-5-codex","usage":{"prompt_tokens":2000,"completion_tokens":500,"prompt_tokens_details":{"cached_tokens":1500},"completion_tokens_details":{"reasoning_tokens":200}}}"#.utf8
        )
        let extracted = parser.parsePayload(responseBody: jsonBody, requestBody: Data())
        #expect(extracted.modelIdentifier == "gpt-5-codex")
        #expect(extracted.cachedReadTokens == 1500)
        #expect(extracted.outputTokens == 500)
        #expect(extracted.reasoningTokens == 200)
    }

    // MARK: - 8. `BudgetCircuitBreakerLedger` Warning Utilization, Hard Trip & Reset

    @Test("BudgetCircuitBreakerLedger tracks utilization warnings, trips hard ceiling, and resets cleanly")
    func budgetCircuitBreakerWarningHardTripAndReset() throws {
        let ledger = BudgetCircuitBreakerLedger(globalCeilingUSD: 10.0)
        ledger.registerLane(laneID: "lane-claude", vendor: .claudeCode, ceilingUSD: 1.00)

        try ledger.checkAdmission(forLane: "lane-claude")

        // Spend ~$0.84 (above 80% warning utilization, below $1.00 hard ceiling)
        // claude-opus-4 ($15/M input, $75/M output): 10,000 output tokens = $0.75 + 6,000 input = $0.09 => $0.84
        let warnSpan = ledger.recordUsage(
            laneID: "lane-claude",
            taskID: "t1",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com",
            usage: ExtractedUsagePayload(
                modelIdentifier: "claude-opus-4-1",
                inputTokens: 6_000,
                cachedReadTokens: 0,
                outputTokens: 10_000,
                reasoningTokens: 0
            ),
            durationMs: 920.0,
            statusCode: 200
        )
        #expect(warnSpan.costUSD > 0.70)
        let midAccount = ledger.allAccounts().first { $0.laneID == "lane-claude" }!
        #expect(midAccount.utilizationRatio >= 0.75)
        #expect(midAccount.circuitOpen == false)
        try ledger.checkAdmission(forLane: "lane-claude")

        // Second turn crosses $1.00 lane ceiling -> circuit trips open!
        _ = ledger.recordUsage(
            laneID: "lane-claude",
            taskID: "t1",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com",
            usage: ExtractedUsagePayload(
                modelIdentifier: "claude-opus-4-1",
                inputTokens: 5_000,
                cachedReadTokens: 0,
                outputTokens: 5_000,
                reasoningTokens: 0
            ),
            durationMs: 610.0,
            statusCode: 200
        )

        let trippedAccount = ledger.allAccounts().first { $0.laneID == "lane-claude" }!
        #expect(trippedAccount.circuitOpen == true)
        #expect(throws: RelayIDEError.self) {
            try ledger.checkAdmission(forLane: "lane-claude")
        }

        // Record blocked attempt and build flamechart timeline
        let blockedSpan = ledger.recordBlockedAttempt(
            laneID: "lane-claude",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com"
        )
        #expect(blockedSpan.blockedByCircuitBreaker == true)
        #expect(blockedSpan.statusCode == 429)

        let timeline = ledger.buildFlamechartTimeline()
        #expect(timeline.tracks.count == 1)
        #expect(timeline.globalSpendUSD > 1.0)

        // Operator raises ceiling to $3.00 and resets circuit breaker
        ledger.resetCircuit(forLane: "lane-claude", newCeilingUSD: 3.00)
        try ledger.checkAdmission(forLane: "lane-claude")
    }

    // MARK: - 9. Live Loopback TCP `LoopbackWiretapProxyServer` Round-Trip & 429 Gate

    @Test("LoopbackWiretapProxyServer serves /healthz, intercepts live TCP requests, records spans, and returns 429 on trip")
    func liveLoopbackWiretapProxyServerEndToEndRoundTrip() async throws {
        let ledger = BudgetCircuitBreakerLedger(globalCeilingUSD: 20.0)
        ledger.registerLane(laneID: "lane-codex", vendor: .codex, ceilingUSD: 0.50)

        // Deterministic in-memory mock upstream so zero external network sockets are opened
        let proxy = LoopbackWiretapProxyServer(ledger: ledger) { upstreamRequest in
            #expect(upstreamRequest.httpMethod == "POST")
            #expect(upstreamRequest.url?.host == "api.openai.com")
            let mockSSE = """
            data: {"model":"claude-opus-4-1","usage":{"input_tokens":10000,"output_tokens":8000}}

            data: [DONE]

            """
            let httpResponse = HTTPURLResponse(
                url: upstreamRequest.url ?? URL(string: "https://api.openai.com/v1/responses")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (Data(mockSSE.utf8), httpResponse)
        }

        let port = try proxy.start(port: 0)
        defer { proxy.stop() }
        #expect(proxy.isRunning == true)
        #expect(port > 0)

        let envVars = proxy.proxyEnvironmentVariables(forLane: "lane-codex", vendor: .codex)
        #expect(envVars["OPENAI_BASE_URL"]?.contains("127.0.0.1:\(port)") == true)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [:]
        sessionConfig.timeoutIntervalForRequest = 5.0
        let urlSession = URLSession(configuration: sessionConfig)

        // 1. Verify GET /healthz
        let healthURL = URL(string: "http://127.0.0.1:\(port)/healthz")!
        let (healthData, healthResp) = try await urlSession.data(from: healthURL)
        #expect((healthResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: healthData, as: UTF8.self).contains("ok"))

        // 2. First proxied POST succeeds (200) and trips the $0.50 ceiling ($0.75 spent)
        let turnURL = URL(string: "http://127.0.0.1:\(port)/lane/lane-codex/codex/https/api.openai.com/v1/responses")!
        var req1 = URLRequest(url: turnURL)
        req1.httpMethod = "POST"
        req1.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req1.httpBody = Data(#"{"model":"claude-opus-4-1","stream":true}"#.utf8)

        let (_, resp1) = try await urlSession.data(for: req1)
        #expect((resp1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(ledger.allSpans().count == 1)
        #expect(ledger.totalSpendUSD() > 0.50)

        // 3. Second proxied POST is immediately halted at loopback with HTTP 429!
        let (blockedBody, resp2) = try await urlSession.data(for: req1)
        #expect((resp2 as? HTTPURLResponse)?.statusCode == 429)
        let blockedText = String(decoding: blockedBody, as: UTF8.self)
        #expect(blockedText.lowercased().contains("budget") || blockedText.lowercased().contains("circuit"))
    }

    // MARK: - 10. `OutboundSecretDLPEngine`: JSON-Preserving Redaction Across API Keys & DB URIs

    @Test("OutboundSecretDLPEngine redacts Anthropic/OpenAI/Gemini/GitHub/AWS keys and DB URIs while preserving valid JSON")
    func outboundDLPRedactsAPIKeysPreservingValidJSON() throws {
        // Construct synthetic test tokens dynamically so static scanners never confuse test fixtures with real keys
        let fakeAnthropic = "sk-ant-api03-" + String(repeating: "A9bX", count: 24)
        let fakeOpenAI = "sk-proj-" + String(repeating: "k7Qm", count: 14)
        let fakeGemini = "AIzaSy" + String(repeating: "D4rT8pL9", count: 4) + "X"
        let fakeGitHub = "ghp_" + String(repeating: "9xYzAbCdEfGh", count: 3)
        let fakeAWS = "AKIA" + "9X7K2M8P4Q6R3T5Z"
        let fakePG = "postgres://admin_user:Sup3rS3cretP@ssw0rd!@db.internal.corp:5432/prod_ledger"

        let requestObject: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "messages": [
                [
                    "role": "user",
                    "content": """
                    Debug config:
                    ANTHROPIC_API_KEY=\(fakeAnthropic)
                    OPENAI=\(fakeOpenAI)
                    GEMINI=\(fakeGemini)
                    GH=\(fakeGitHub)
                    AWS=\(fakeAWS)
                    DATABASE_URL=\(fakePG)
                    File loaded from /Users/alice/Projects/SecretApp/config.json
                    """,
                ]
            ],
        ]
        let rawJSON = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])

        let dlp = OutboundSecretDLPEngine(policy: DLPPolicyConfiguration(redactLocalMacOSHomePaths: true))
        let verdict = dlp.inspectOutboundBody(
            rawJSON,
            laneID: "lane-claude",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com"
        )

        #expect(verdict.outcome == .sanitizedAndForwarded)
        #expect(verdict.shouldBlockRequest == false)
        #expect(verdict.matches.count >= 5)

        // Output payload MUST remain 100% parseable JSON and contain ZERO raw secrets!
        let parsedSanitized = try JSONSerialization.jsonObject(with: verdict.outputPayload) as? [String: Any]
        #expect(parsedSanitized != nil)

        let sanitizedText = String(decoding: verdict.outputPayload, as: UTF8.self)
        #expect(!sanitizedText.contains(fakeAnthropic))
        #expect(!sanitizedText.contains(fakeOpenAI))
        #expect(!sanitizedText.contains(fakeGemini))
        #expect(!sanitizedText.contains(fakeGitHub))
        #expect(!sanitizedText.contains(fakeAWS))
        #expect(!sanitizedText.contains("Sup3rS3cretP@ssw0rd!"))
        #expect(!sanitizedText.contains("/Users/alice/"))
        #expect(dlp.recentAuditEvents(limit: 10).count == 1)
    }

    // MARK: - 11. `OutboundSecretDLPEngine`: Hard Block on PEM / OpenSSH / Stripe Live Keys

    @Test("OutboundSecretDLPEngine hard-blocks PEM private keys, OpenSSH keys, and .ssh material before loopback exit")
    func outboundDLPHardBlocksPEMAndSSHPrivateKeys() throws {
        let pemHeader = "-----BEGIN " + "RSA PRIVATE KEY-----"
        let pemFooter = "-----END " + "RSA PRIVATE KEY-----"
        let fakePEMBody = String(repeating: "MIIEpAIBAAKCAQEA7VJTUt9Us8cKjMzEfYyjiWA4R4s5", count: 3)

        let payload = try JSONSerialization.data(withJSONObject: [
            "prompt": "Here is the key:\n\(pemHeader)\n\(fakePEMBody)\n\(pemFooter)"
        ])

        let dlp = OutboundSecretDLPEngine()
        let verdict = dlp.inspectOutboundBody(
            payload,
            laneID: "lane-codex",
            vendor: .codex,
            providerHost: "api.openai.com"
        )

        #expect(verdict.outcome == .blockedBeforeLoopbackExit)
        #expect(verdict.shouldBlockRequest == true)
        #expect(verdict.outputPayload.isEmpty)
        #expect(verdict.matches.contains { $0.category == .pemPrivateKey })
    }

    // MARK: - 12. `OutboundSecretDLPEngine`: JWT Structural Validation & Shannon Entropy

    @Test("OutboundSecretDLPEngine validates 3-part base64url JWT structure and computes Shannon entropy")
    func outboundDLPJWTStructureAndShannonEntropy() throws {
        // Header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
        // Payload: {"sub":"1234567890","role":"admin"} -> eyJzdWIiOiIxMjM0NTY3ODkwIiwicm9sZSI6ImFkbWluIn0
        let validJWT =
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
            "eyJzdWIiOiIxMjM0NTY3ODkwIiwicm9sZSI6ImFkbWluIn0." +
            "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        #expect(OutboundSecretDLPEngine.isValidJWTStructure(validJWT) == true)
        #expect(OutboundSecretDLPEngine.isValidJWTStructure("not.a.jwt") == false)

        let lowEntropy = OutboundSecretDLPEngine.shannonEntropyBitsPerCharacter("aaaaaaaaaaaaaaaaaaaa")
        let uniformFourSymbol = OutboundSecretDLPEngine.shannonEntropyBitsPerCharacter("ABCDABCDABCDABCD")
        #expect(lowEntropy == 0.0)
        #expect(abs(uniformFourSymbol - 2.0) < 0.001)

        let dlp = OutboundSecretDLPEngine()
        let body = try JSONSerialization.data(withJSONObject: ["Authorization": "Bearer \(validJWT)"])
        let verdict = dlp.inspectOutboundBody(
            body,
            laneID: "lane-agy",
            vendor: .antigravity,
            providerHost: "generativelanguage.googleapis.com"
        )
        #expect(verdict.matches.contains { $0.category == .jwtBearerToken })
        #expect(!String(decoding: verdict.outputPayload, as: UTF8.self).contains("dBjftJeZ4CVP"))
    }

    // MARK: - 13. `OutboundSecretDLPEngine`: Clean Prompt Fast-Path & Allowlist

    @Test("OutboundSecretDLPEngine passes benign code prompts untouched with zero false positives")
    func outboundDLPCleanPassAndAllowlist() throws {
        let cleanBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-5",
            "messages": [
                ["role": "user", "content": "Refactor BillingEngine.subtotal(cents:) to guard against integer overflow."]
            ],
        ])
        let dlp = OutboundSecretDLPEngine()
        let verdict = dlp.inspectOutboundBody(
            cleanBody,
            laneID: "lane-claude",
            vendor: .claudeCode,
            providerHost: "api.anthropic.com"
        )
        #expect(verdict.outcome == .cleanPass)
        #expect(verdict.matches.isEmpty)
        #expect(verdict.outputPayload == cleanBody)
    }

    // MARK: - 14. `WiretapCostAnalyticsEngine`: EWMA + Linear Regression Burn Rate & Exhaustion Forecast

    @Test("WiretapCostAnalyticsEngine forecasts EWMA burn rate, time-to-exhaustion, and vendor spend shares")
    func wiretapCostAnalyticsBurnRateAndVendorBreakdown() {
        let t0 = Date(timeIntervalSince1970: 1_763_020_800)
        let accounts = [
            LaneBudgetAccount(
                laneID: "lane-claude",
                vendor: .claudeCode,
                requestCount: 5,
                inputTokens: 50_000,
                cachedTokens: 40_000,
                outputTokens: 12_000,
                spentUSD: 4.20,
                ceilingUSD: 5.00,
                circuitOpen: false
            ),
            LaneBudgetAccount(
                laneID: "lane-codex",
                vendor: .codex,
                requestCount: 3,
                inputTokens: 30_000,
                cachedTokens: 15_000,
                outputTokens: 6_000,
                spentUSD: 1.20,
                ceilingUSD: 5.00,
                circuitOpen: false
            ),
        ]

        // 5 spans spaced 30 seconds apart on lane-claude ($0.84 each -> ~$1.68/min burn rate, $0.80 remaining -> < 35s left!)
        var spans: [WiretapAPISpan] = []
        for idx in 0..<5 {
            spans.append(
                WiretapAPISpan(
                    laneID: "lane-claude",
                    taskID: "t-arch",
                    vendor: .claudeCode,
                    providerHost: "api.anthropic.com",
                    modelIdentifier: "claude-sonnet-4-5",
                    inputTokens: 10_000,
                    cachedReadTokens: 8_000,
                    outputTokens: 2_400,
                    costUSD: 0.84,
                    durationMs: 1_200,
                    statusCode: 200,
                    recordedAt: t0.addingTimeInterval(Double(idx) * 30.0)
                )
            )
        }
        for idx in 0..<3 {
            spans.append(
                WiretapAPISpan(
                    laneID: "lane-codex",
                    taskID: "t-impl",
                    vendor: .codex,
                    providerHost: "api.openai.com",
                    modelIdentifier: "gpt-5-codex",
                    inputTokens: 10_000,
                    cachedReadTokens: 5_000,
                    outputTokens: 2_000,
                    costUSD: 0.40,
                    durationMs: 900,
                    statusCode: 200,
                    recordedAt: t0.addingTimeInterval(Double(idx) * 60.0)
                )
            )
        }

        let engine = WiretapCostAnalyticsEngine(ewmaAlpha: 0.35, spikeMultiplierThreshold: 3.0)
        let snapshot = engine.analyzeWorkspace(accounts: accounts, spans: spans, globalCeilingUSD: 15.0)

        #expect(abs(snapshot.totalSpentUSD - 5.40) < 0.01)
        #expect(snapshot.workspaceBurnRateUSDPerHour > 0)
        #expect(snapshot.totalCacheSavingsUSD > 0)
        #expect(snapshot.vendorBreakdowns.count == 2)

        let claudeForecast = snapshot.laneForecasts.first { $0.laneID == "lane-claude" }!
        #expect(claudeForecast.ewmaUSDPerMinute > 0.5)
        #expect(claudeForecast.projectedExhaustionSeconds != nil)
        #expect(claudeForecast.riskState == .elevated || claudeForecast.riskState == .imminentExhaustion)
    }

    // MARK: - 15. `WiretapCostAnalyticsEngine`: Spend Spike & Prompt Cache Collapse Anomaly Detection

    @Test("WiretapCostAnalyticsEngine detects spend-spike outliers and prompt-cache collapse anomalies")
    func wiretapCostAnalyticsDetectsSpendSpikeAndCacheCollapse() {
        let t0 = Date(timeIntervalSince1970: 1_763_020_800)
        // 4 baseline turns at $0.10 with 90% cache hit, followed by a sudden $1.80 uncached spike!
        var spans: [WiretapAPISpan] = []
        for idx in 0..<4 {
            spans.append(
                WiretapAPISpan(
                    laneID: "lane-claude",
                    vendor: .claudeCode,
                    providerHost: "api.anthropic.com",
                    modelIdentifier: "claude-sonnet-4-5",
                    inputTokens: 40_000,
                    cachedReadTokens: 36_000,
                    outputTokens: 500,
                    costUSD: 0.10,
                    durationMs: 800,
                    statusCode: 200,
                    recordedAt: t0.addingTimeInterval(Double(idx) * 20.0)
                )
            )
        }
        spans.append(
            WiretapAPISpan(
                laneID: "lane-claude",
                vendor: .claudeCode,
                providerHost: "api.anthropic.com",
                modelIdentifier: "claude-sonnet-4-5",
                inputTokens: 50_000,
                cachedReadTokens: 0,
                outputTokens: 8_000,
                reasoningTokens: 7_200,
                costUSD: 1.80,
                durationMs: 9_500,
                statusCode: 200,
                recordedAt: t0.addingTimeInterval(100.0)
            )
        )

        let account = LaneBudgetAccount(
            laneID: "lane-claude",
            vendor: .claudeCode,
            requestCount: 5,
            spentUSD: 2.20,
            ceilingUSD: 10.0
        )

        let analytics = WiretapCostAnalyticsEngine(spikeMultiplierThreshold: 3.0)
            .analyzeWorkspace(accounts: [account], spans: spans, globalCeilingUSD: 25.0)

        #expect(analytics.anomalies.contains { $0.kind == .spendSpikeOutlier })
        #expect(analytics.anomalies.contains { $0.kind == .promptCacheCollapse })
    }

    // MARK: - 16. `WiretapCostAnalyticsEngine`: Rapid 429/5xx Retry Burst Detection

    @Test("WiretapCostAnalyticsEngine flags rapid retry storms when consecutive 429/503 responses arrive")
    func wiretapCostAnalyticsRapidRetryBurstAnomaly() {
        let t0 = Date(timeIntervalSince1970: 1_763_021_000)
        var retrySpans: [WiretapAPISpan] = [
            WiretapAPISpan(
                laneID: "lane-vibe",
                vendor: .mistralVibe,
                providerHost: "api.mistral.ai",
                modelIdentifier: "devstral-medium",
                inputTokens: 1_200,
                outputTokens: 300,
                costUSD: 0.05,
                durationMs: 650,
                statusCode: 200,
                recordedAt: t0
            )
        ]
        retrySpans.append(contentsOf: (1...4).map { idx in
            WiretapAPISpan(
                laneID: "lane-vibe",
                vendor: .mistralVibe,
                providerHost: "api.mistral.ai",
                modelIdentifier: "devstral-medium",
                inputTokens: 200,
                outputTokens: 0,
                costUSD: 0.0,
                durationMs: 120,
                statusCode: 429,
                recordedAt: t0.addingTimeInterval(Double(idx) * 2.0)
            )
        })
        let account = LaneBudgetAccount(laneID: "lane-vibe", vendor: .mistralVibe, requestCount: 5, spentUSD: 0.05, ceilingUSD: 5.0)
        let snapshot = WiretapCostAnalyticsEngine().analyzeWorkspace(accounts: [account], spans: retrySpans, globalCeilingUSD: 20.0)

        #expect(snapshot.anomalies.contains { $0.kind == .rapidRetryBurst })
    }

    // MARK: - 17. `WiretapFlamechartBuilder` Multi-Lane Concurrency Horizon

    @Test("WiretapFlamechartBuilder computes concurrent lane watermark and per-lane cache hit percentages")
    func wiretapFlamechartBuilderMultiLaneTimeline() {
        let t0 = Date(timeIntervalSince1970: 1_763_022_000)
        let spans = [
            WiretapAPISpan(
                laneID: "lane-claude",
                vendor: .claudeCode,
                providerHost: "api.anthropic.com",
                modelIdentifier: "claude-sonnet-4-5",
                inputTokens: 2_000,
                cachedReadTokens: 8_000,
                outputTokens: 1_000,
                costUSD: 0.25,
                durationMs: 2_000,
                statusCode: 200,
                recordedAt: t0
            ),
            WiretapAPISpan(
                laneID: "lane-codex",
                vendor: .codex,
                providerHost: "api.openai.com",
                modelIdentifier: "gpt-5-codex",
                inputTokens: 4_000,
                cachedReadTokens: 4_000,
                outputTokens: 1_200,
                costUSD: 0.30,
                durationMs: 2_000,
                statusCode: 200,
                recordedAt: t0.addingTimeInterval(0.5) // Overlaps in wall-clock window with lane-claude!
            ),
        ]

        let timeline = WiretapFlamechartBuilder.buildTimeline(from: spans)
        #expect(timeline.tracks.count == 2)
        #expect(timeline.maxConcurrentActiveLanes == 2)
        #expect(abs(timeline.globalSpendUSD - 0.55) < 0.001)
    }

    // MARK: - 18. Global Ceiling Enforcement Across Multiple Lanes

    @Test("BudgetCircuitBreakerLedger blocks admission when aggregate multi-lane spend crosses global ceiling")
    func globalBudgetCeilingHaltsAllLanes() {
        let ledger = BudgetCircuitBreakerLedger(globalCeilingUSD: 0.50)
        ledger.registerLane(laneID: "lane-a", vendor: .claudeCode, ceilingUSD: 5.00)
        ledger.registerLane(laneID: "lane-b", vendor: .codex, ceilingUSD: 5.00)

        // Lane A spends ~$0.75 (under its $5.00 lane cap, but above the $0.50 global workspace ceiling!)
        _ = ledger.recordUsage(
            laneID: "lane-a",
            taskID: nil,
            vendor: .claudeCode,
            providerHost: "api.anthropic.com",
            usage: ExtractedUsagePayload(modelIdentifier: "claude-opus-4-1", inputTokens: 0, cachedReadTokens: 0, outputTokens: 10_000),
            durationMs: 500,
            statusCode: 200
        )

        // Lane B has $0.00 spend, yet must be halted because global workspace spend exceeded $0.50!
        #expect(throws: RelayIDEError.self) {
            try ledger.checkAdmission(forLane: "lane-b")
        }

        ledger.setGlobalCeilingUSD(10.0)
        #expect(throws: Never.self) {
            try ledger.checkAdmission(forLane: "lane-b")
        }
    }

    // MARK: - 19. `HTTPHeaderMap` Case-Insensitive Lookup & Folded Obs-Fold Continuation

    @Test("HTTPHeaderMap supports case-insensitive multi-value headers and RFC 7230 obs-fold continuations")
    func httpHeaderMapCaseInsensitiveAndFoldedValues() {
        var map = HTTPHeaderMap()
        map.append(name: "Set-Cookie", value: "a=1")
        map.append(name: "set-cookie", value: "b=2")
        map.append(name: "X-Custom-Trace", value: "part1")
        _ = map.appendFoldedContinuation("part2")

        #expect(map.values(for: "SET-COOKIE") == ["a=1", "b=2"])
        #expect(map.value(for: "x-custom-trace") == "part1 part2")
    }
}
