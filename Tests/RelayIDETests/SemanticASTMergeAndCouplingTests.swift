import Foundation
import RelayModels
@testable import RelaySemanticMerge
import Testing

// `.serialized`: the guarded-merge tests run git and a compiler and block their thread while they wait (see the note
// in CLIMCPAndWorkbenchShellTests).
@Suite("3-Way Semantic AST Merger, Myers/Diff3, Conflict Resolution, Call-Site & Isometric Coupling", .serialized, .timeLimit(.minutes(1)))
struct SemanticASTMergeAndCouplingTests {

    // MARK: - 1. Multi-Language Declaration Parsing: Swift & Structural Fingerprints

    @Test("MultiLanguageDeclarationParser extracts Swift imports, protocols, structs, and nested methods")
    func parseSwiftDeclarationsAndStructuralFingerprint() {
        let swiftSource = """
        import Foundation
        import CryptoKit

        public protocol PaymentSettler: Sendable {
            func settle(cents: Int) throws -> String
        }

        public struct BillingEngine: PaymentSettler {
            public let merchantID: String

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }

            public func settle(cents: Int) throws -> String {
                return "\\(merchantID):\\(cents)"
            }
        }
        """

        #expect(SourceLanguage.detect(fromPath: "Sources/BillingEngine.swift") == .swift)
        let parser = MultiLanguageDeclarationParser()
        let decls = parser.parseDeclarations(source: swiftSource, language: .swift)

        #expect(decls.contains { $0.kind == .importGroup })
        #expect(decls.contains { $0.kind == .protocolOrInterface && $0.symbolName == "PaymentSettler" })

        let billingStruct = decls.first { $0.kind == .structDecl && $0.symbolName == "BillingEngine" }
        #expect(billingStruct != nil)
        #expect((billingStruct?.children.count ?? 0) >= 2)
        #expect(billingStruct?.children.contains { $0.symbolName == "subtotal" } == true)
        #expect(billingStruct?.children.contains { $0.symbolName == "settle" } == true)

        // Structural fingerprint collapses cosmetic whitespace/indentation while changing on token edits
        let fpA = MultiLanguageDeclarationParser.structuralFingerprint(of: "func add(x: Int) -> Int { return x + 1 }")
        let fpB = MultiLanguageDeclarationParser.structuralFingerprint(of: "func   add(x: Int)   ->   Int {\n    return   x   +   1\n}")
        let fpC = MultiLanguageDeclarationParser.structuralFingerprint(of: "func add(x: Int) -> Int { return x + 2 }")
        #expect(fpA == fpB)
        #expect(fpA != fpC)
    }

    // MARK: - 2. Multi-Language Declaration Parsing: Python & TypeScript

    @Test("MultiLanguageDeclarationParser parses Python indentation blocks and TypeScript classes/interfaces")
    func parsePythonAndTypeScriptDeclarations() {
        let pythonSource = """
        import math
        from typing import List

        class TokenLedger:
            def record_turn(self, prompt_tokens: int, completion_tokens: int) -> int:
                return prompt_tokens + completion_tokens

            def reset_balance(self) -> None:
                pass

        def compute_burn_rate(samples: List[float]) -> float:
            return sum(samples) / max(1, len(samples))
        """

        let tsSource = """
        import { EventEmitter } from "node:events";

        export interface WiretapSpan {
            laneId: string;
            costUsd: number;
        }

        export class TelemetryRouter extends EventEmitter {
            ingestSpan(span: WiretapSpan): boolean {
                return span.costUsd >= 0;
            }

            flushQueue(): number {
                return 0;
            }
        }
        """

        #expect(SourceLanguage.detect(fromPath: "analytics/ledger.py") == .python)
        #expect(SourceLanguage.detect(fromPath: "web/router.ts") == .typeScript)

        let parser = MultiLanguageDeclarationParser()
        let pyDecls = parser.parseDeclarations(source: pythonSource, language: .python)
        let pyClass = pyDecls.first { $0.symbolName == "TokenLedger" }
        #expect(pyClass != nil)
        #expect(pyClass?.declarationSource.contains("def record_turn") == true)
        #expect(pyClass?.declarationSource.contains("def reset_balance") == true)
        #expect(pyDecls.contains { $0.symbolName == "compute_burn_rate" })

        let tsDecls = parser.parseDeclarations(source: tsSource, language: .typeScript)
        #expect(tsDecls.contains { $0.symbolName == "WiretapSpan" })
        let tsClass = tsDecls.first { $0.symbolName == "TelemetryRouter" }
        #expect(tsClass != nil)
        #expect(tsClass?.children.contains { $0.symbolName == "ingestSpan" } == true)
        #expect(tsClass?.children.contains { $0.symbolName == "flushQueue" } == true)
    }

    // MARK: - 3. Multi-Language Declaration Parsing: Rust & Go

    @Test("MultiLanguageDeclarationParser parses Rust struct/impl/fn blocks and Go package/struct/receiver methods")
    func parseRustAndGoDeclarations() {
        let rustSource = """
        use std::collections::HashMap;

        pub struct RingFrame {
            pub sequence: u64,
            pub payload_len: usize,
        }

        impl RingFrame {
            pub fn new(sequence: u64, payload_len: usize) -> Self {
                Self { sequence, payload_len }
            }

            pub fn is_empty(&self) -> bool {
                self.payload_len == 0
            }
        }

        pub fn checksum_bytes(buf: &[u8]) -> u32 {
            buf.iter().map(|b| *b as u32).sum()
        }
        """

        let goSource = """
        package wiretap

        import (
            "context"
            "fmt"
        )

        type CircuitGate struct {
            LimitUSD float64
        }

        func (g *CircuitGate) Allow(ctx context.Context, spend float64) error {
            if spend > g.LimitUSD {
                return fmt.Errorf("tripped")
            }
            return nil
        }

        func DefaultCeiling() float64 {
            return 25.0
        }
        """

        #expect(SourceLanguage.detect(fromPath: "crates/pty/src/lib.rs") == .rust)
        #expect(SourceLanguage.detect(fromPath: "pkg/wiretap/gate.go") == .go)

        let parser = MultiLanguageDeclarationParser()
        let rustDecls = parser.parseDeclarations(source: rustSource, language: .rust)
        #expect(rustDecls.contains { $0.symbolName == "RingFrame" })
        #expect(rustDecls.contains { $0.kind == .extensionOrImpl })
        #expect(rustDecls.contains { $0.symbolName == "checksum_bytes" })

        let goDecls = parser.parseDeclarations(source: goSource, language: .go)
        #expect(goDecls.contains { $0.symbolName == "CircuitGate" })
        #expect(goDecls.contains { $0.declarationSource.contains("Allow(ctx context.Context") })
        #expect(goDecls.contains { $0.symbolName == "DefaultCeiling" })
    }

    // MARK: - 4. 3-Way Semantic AST Clean Auto-Merge Where Line-Based `diff3` Conflicts!

    @Test("ThreeWaySemanticASTMerger cleanly auto-merges adjacent member additions inside same struct where line diff3 conflicts")
    func threeWaySemanticAutoMergeBeatsLineBasedDiff3OnAdjacentStructMethods() {
        let baseSwift = """
        import Foundation

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }
        }
        """

        // Left agent (Claude) appends `applyDiscount` right at the bottom of `BillingEngine` + imports CryptoKit
        let leftSwift = """
        import Foundation
        import CryptoKit

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }

            public func applyDiscount(subtotal: Int, basisPoints: Int) -> Int {
                return subtotal - (subtotal * basisPoints) / 10_000
            }
        }
        """

        // Right agent (Codex) appends `computeGST` at the exact same bottom lines of `BillingEngine` + imports Dispatch
        let rightSwift = """
        import Foundation
        import Dispatch

        public struct BillingEngine {
            public init() {}

            public func subtotal(cents: [Int]) -> Int {
                return cents.reduce(0, +)
            }

            public func computeGST(subtotal: Int) -> Int {
                return (subtotal * 15) / 100
            }
        }
        """

        // Confirm classic line-based diff3 reports a conflict on the same insertion locus
        let lineDiff3 = Diff3TextMergeEngine().mergeThreeWay(base: baseSwift, ours: leftSwift, theirs: rightSwift)
        #expect(lineDiff3.hasConflicts == true)

        // Confirm 3-Way Semantic AST Merger resolves BOTH imports and BOTH struct methods with ZERO conflicts!
        let semanticMerger = ThreeWaySemanticASTMerger()
        let report = semanticMerger.mergeFile(
            relativePath: "Sources/Ledger/BillingEngine.swift",
            baseSource: baseSwift,
            leftSource: leftSwift,
            rightSource: rightSwift,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex",
            leftVendor: .claudeCode,
            rightVendor: .codex
        )

        #expect(report.isCleanlyMerged == true)
        #expect(report.unresolvedConflictCount == 0)
        #expect(report.wouldGitLineMergeConflict == true)
        #expect(report.autoMergedCount >= 1)
        #expect(report.mergedText.contains("import CryptoKit"))
        #expect(report.mergedText.contains("import Dispatch"))
        #expect(report.mergedText.contains("func applyDiscount"))
        #expect(report.mergedText.contains("func computeGST"))
    }

    // MARK: - 5. 3-Way Semantic Merge: Disjoint Function Modifications in Python Module

    @Test("ThreeWaySemanticASTMerger cleanly merges concurrent edits to distinct functions in a Python module")
    func threeWaySemanticMergeDisjointPythonFunctions() {
        let basePy = """
        import hashlib

        def open_session(user_id: str) -> str:
            return f"tok:{user_id}"

        def revoke_session(token: str) -> bool:
            return False
        """

        let leftPy = """
        import hashlib
        import hmac

        def open_session(user_id: str) -> str:
            return f"v2_tok:{user_id.strip()}"

        def revoke_session(token: str) -> bool:
            return False
        """

        let rightPy = """
        import hashlib
        import time

        def open_session(user_id: str) -> str:
            return f"tok:{user_id}"

        def revoke_session(token: str) -> bool:
            return token.startswith("tok:") or token.startswith("v2_tok:")
        """

        let report = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "auth/session_manager.py",
            baseSource: basePy,
            leftSource: leftPy,
            rightSource: rightPy,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-agy"
        )
        #expect(report.isCleanlyMerged == true)
        #expect(report.unresolvedConflictCount == 0)
        #expect(report.mergedText.contains("v2_tok:"))
        #expect(report.mergedText.contains("token.startswith"))
    }

    // MARK: - 6. True Intra-Function Semantic Conflict & Delete-Modify Conflict Detection

    @Test("ThreeWaySemanticASTMerger flags true intra-function body divergence and delete-vs-modify conflicts")
    func threeWaySemanticTrueIntraFunctionAndDeleteModifyConflicts() {
        let baseSwift = """
        public func retryBackoffMs(attempt: Int) -> Int {
            return attempt * 100
        }

        public func legacyEndpoint() -> String {
            return "/v1/pay"
        }
        """

        let leftSwift = """
        public func retryBackoffMs(attempt: Int) -> Int {
            return (1 << attempt) * 250
        }
        """ // Left also deleted legacyEndpoint()

        let rightSwift = """
        public func retryBackoffMs(attempt: Int) -> Int {
            return min(5_000, attempt * 400)
        }

        public func legacyEndpoint() -> String {
            return "/v2/pay-compat"
        }
        """

        let report = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "Sources/Net/RetryPolicy.swift",
            baseSource: baseSwift,
            leftSource: leftSwift,
            rightSource: rightSwift,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex"
        )

        #expect(report.isCleanlyMerged == false)
        #expect(report.unresolvedConflictCount == 2)
        #expect(report.chunks.contains { $0.resolution == .conflictBothModifiedSameSymbol })
        #expect(report.chunks.contains { $0.resolution == .conflictDeleteModify })
    }

    // MARK: - 7. Identical Concurrent Edits Converge Cleanly

    @Test("ThreeWaySemanticASTMerger deduplicates identical concurrent edits from two lanes without conflict")
    func threeWaySemanticIdenticalConcurrentEditsAutoMerge() {
        let baseTS = """
        export function maxBatchSize(): number {
            return 32;
        }
        """
        let updatedTS = """
        export function maxBatchSize(): number {
            return 128;
        }
        """

        let report = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "src/limits.ts",
            baseSource: baseTS,
            leftSource: updatedTS,
            rightSource: updatedTS,
            leftLaneID: "lane-codex",
            rightLaneID: "lane-vibe"
        )
        #expect(report.isCleanlyMerged == true)
        #expect(report.unresolvedConflictCount == 0)
        #expect(report.chunks.contains { $0.resolution == .autoMergedIdenticalChange })
    }

    // MARK: - 8. Myers $O(ND)$ Exact Edit Script vs Patience Diff Anchoring

    @Test("MyersLineAndTokenDiffEngine computes minimal Myers O(ND) edit scripts and Patience anchored hunks")
    func myersLineAndPatienceDiffCorrectness() {
        let engine = MyersLineAndTokenDiffEngine()

        let oldArr = ["A", "B", "C", "A", "B", "B", "A"]
        let newArr = ["C", "B", "A", "B", "A", "C"]
        let steps = engine.diffElementsMyers(oldArr, newArr)

        // Reconstruct oldArr & newArr from edit script to prove mathematical soundness
        let reconstructedOld = steps.compactMap { $0.kind != .insert ? $0.element : nil }
        let reconstructedNew = steps.compactMap { $0.kind != .delete ? $0.element : nil }
        #expect(reconstructedOld == oldArr)
        #expect(reconstructedNew == newArr)
        // LCS("ABCABBA", "CBABAC") has length 4 -> shortest edit distance D = 7 + 6 - 2*4 = 5
        let editDistance = steps.filter { $0.kind != .equal }.count
        #expect(editDistance == 5)

        // Patience diff anchors unique function headers rather than misaligning `}` braces
        let oldCode = """
        func alpha() {
            let v = 1
        }

        func omega() {
            let v = 2
        }
        """
        let newCode = """
        func alpha() {
            let v = 1
        }

        func middleInserted() {
            let v = 99
        }

        func omega() {
            let v = 2
        }
        """
        let patienceHunks = engine.computeCoalescedHunks(
            oldText: oldCode,
            newText: newCode,
            contextLines: 1,
            usePatienceAnchoring: true
        )
        #expect(patienceHunks.count == 1)
        let formatted = engine.formatUnifiedDiff(
            oldPath: "a/Service.swift",
            newPath: "b/Service.swift",
            oldText: oldCode,
            newText: newCode
        )
        #expect(formatted.contains("+func middleInserted()"))
    }

    // MARK: - 9. Source Lexical Tokenization & Sub-Line Token Diff

    @Test("MyersLineAndTokenDiffEngine tokenizes source literals/comments/operators and diffs token streams")
    func myersSourceTokenDiffing() {
        let engine = MyersLineAndTokenDiffEngine()
        let oldSrc = #"let rate = 0.05 // base fee"#
        let newSrc = #"let rate = 0.075 // updated fee"#

        let tokens = engine.tokenizeSource(oldSrc)
        #expect(tokens.contains { $0.kind == .identifier && $0.text == "rate" })
        #expect(tokens.contains { $0.kind == .numberLiteral && $0.text == "0.05" })
        #expect(tokens.contains { $0.kind == .comment })

        let tokenSteps = engine.diffTokens(oldSource: oldSrc, newSource: newSrc)
        #expect(tokenSteps.contains { $0.kind == .delete && $0.element.text == "0.05" })
        #expect(tokenSteps.contains { $0.kind == .insert && $0.element.text == "0.075" })
    }

    // MARK: - 10. `Diff3TextMergeEngine` & `ConflictMarkerDocumentCodec` Round-Trip

    @Test("Diff3TextMergeEngine merges disjoint regions and ConflictMarkerDocumentCodec round-trips diff3 markers")
    func diff3TextMergeAndConflictMarkerCodecRoundTrip() {
        let base = "line1\nline2\nline3\nline4\nline5\n"
        let ours = "line1-OURS\nline2\nline3\nline4\nline5\n"
        let theirs = "line1\nline2\nline3\nline4\nline5-THEIRS\n"

        let engine = Diff3TextMergeEngine()
        let clean = engine.mergeThreeWay(base: base, ours: ours, theirs: theirs)
        #expect(clean.hasConflicts == false)
        #expect(clean.renderedText.contains("line1-OURS"))
        #expect(clean.renderedText.contains("line5-THEIRS"))

        // Conflicting middle line with diff3WithBase markers
        let conflictOurs = "line1\nline2\nOURS-MID\nline4\nline5\n"
        let conflictTheirs = "line1\nline2\nTHEIRS-MID\nline4\nline5\n"
        let conflicted = engine.mergeThreeWay(
            base: base,
            ours: conflictOurs,
            theirs: conflictTheirs,
            oursLabel: "lane-claude",
            baseLabel: "merge-base",
            theirsLabel: "lane-codex",
            markerStyle: .diff3WithBase
        )
        #expect(conflicted.hasConflicts == true)
        #expect(conflicted.conflictCount == 1)
        #expect(conflicted.renderedText.contains("<<<<<<< lane-claude"))
        #expect(conflicted.renderedText.contains("||||||| merge-base"))
        #expect(conflicted.renderedText.contains("======="))
        #expect(conflicted.renderedText.contains(">>>>>>> lane-codex"))

        let codec = ConflictMarkerDocumentCodec()
        let parsedSegments = codec.parseDocument(conflicted.renderedText)
        let blockCount = parsedSegments.filter {
            if case .conflictBlock = $0 { return true }
            return false
        }.count
        #expect(blockCount == 1)

        let reserializedDiff3 = codec.serializeDocument(parsedSegments, style: .diff3WithBase)
        #expect(reserializedDiff3 == conflicted.renderedText)

        let twoWay = codec.serializeDocument(parsedSegments, style: .standardTwoWay)
        #expect(!twoWay.contains("|||||||"))
        #expect(twoWay.contains("<<<<<<< lane-claude"))
    }

    // MARK: - 11. `InteractiveConflictResolutionEngine`: `acceptLeft`, `acceptRight` & Undo Mutation

    @Test("InteractiveConflictResolutionEngine resolves chunks via acceptLeft/acceptRight and reverses via RelayUndoMutation")
    func interactiveResolutionAcceptLeftRightAndUndo() throws {
        let base = "public func limit() -> Int {\n    return 10\n}\n"
        let left = "public func limit() -> Int {\n    return 50\n}\n"
        let right = "public func limit() -> Int {\n    return 100\n}\n"

        let initialReport = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "Sources/Quota.swift",
            baseSource: base,
            leftSource: left,
            rightSource: right,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex"
        )
        #expect(initialReport.unresolvedConflictCount == 1)
        let conflictChunk = initialReport.chunks.first { $0.resolution.isConflict }!

        let resolver = InteractiveConflictResolutionEngine()

        // 1. Resolve via acceptLeft
        let leftResult = try resolver.resolveChunk(
            in: initialReport,
            chunkID: conflictChunk.id,
            strategy: .acceptLeft
        ).get()
        #expect(leftResult.report.isCleanlyMerged == true)
        #expect(leftResult.report.mergedText.contains("return 50"))
        #expect(leftResult.outcome.delimiterAudit.isBalanced == true)

        // 2. Apply inverted undo mutation -> restores previous conflicted source
        let undoneReport = resolver.applyUndoMutation(
            leftResult.outcome.undoMutation.inverted,
            to: leftResult.report
        )
        #expect(!undoneReport.mergedText.contains("return 50") || undoneReport.chunks[0].resolvedSource == conflictChunk.resolvedSource)

        // 3. Resolve via acceptRight
        let rightResult = try resolver.resolveChunk(
            in: initialReport,
            chunkID: conflictChunk.id,
            strategy: .acceptRight
        ).get()
        #expect(rightResult.report.isCleanlyMerged == true)
        #expect(rightResult.report.mergedText.contains("return 100"))
    }

    // MARK: - 12. `InteractiveConflictResolutionEngine`: `acceptBothOrdered` & `interleaveMembersByName`

    @Test("InteractiveConflictResolutionEngine combines compatible edits via acceptBothOrdered and interleaveMembersByName")
    func interactiveResolutionAcceptBothOrderedAndInterleave() {
        let base = """
        public struct FeatureFlags {
            public static let alpha = true
        }
        """
        let left = """
        public struct FeatureFlags {
            public static let alpha = false
            public static let zebraFlag = true
        }
        """
        let right = """
        public struct FeatureFlags {
            public static let alpha = true
            public static let betaFlag = true
        }
        """

        // Force a direct chunk conflict on `alpha` or full struct to test batch strategies
        let funcBase = "public func configure() {\n    setupLogging()\n}\n"
        let funcLeft = "public func configure() {\n    setupLogging()\n    enableTracing()\n}\n"
        let funcRight = "public func configure() {\n    setupLogging()\n    enableMetrics()\n}\n"

        let funcReport = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "Sources/Bootstrap.swift",
            baseSource: funcBase,
            leftSource: funcLeft,
            rightSource: funcRight,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex"
        )
        #expect(funcReport.unresolvedConflictCount == 1)

        let resolver = InteractiveConflictResolutionEngine()
        let bothSession = resolver.resolveAllConflicts(
            in: funcReport,
            strategy: .acceptBothOrdered,
            options: ConflictResolutionOptions(orderingPreference: .leftThenRight, deduplicateIdenticalStatements: true)
        )
        #expect(bothSession.remainingConflictCount == 0)
        #expect(bothSession.emittedDocument.formattedSource.contains("enableTracing()"))
        #expect(bothSession.emittedDocument.formattedSource.contains("enableMetrics()"))
        #expect(bothSession.emittedDocument.delimiterAudit.isBalanced == true)

        // Also test interleaveMembersByName on a conflicted struct chunk
        let structChunk = SemanticMergeChunk(
            qualifiedKey: "struct:FeatureFlags",
            symbolName: "FeatureFlags",
            kind: .structDecl,
            resolution: .conflictBothModifiedSameSymbol,
            baseSource: base,
            leftSource: left,
            rightSource: right,
            resolvedSource: left,
            explanation: "Both lanes modified FeatureFlags"
        )
        let interleaved = resolver.resolveSingleChunk(
            structChunk,
            language: .swift,
            filePath: "Sources/FeatureFlags.swift",
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex",
            strategy: .interleaveMembersByName
        )
        #expect(!interleaved.updatedChunk.resolution.isConflict)
        #expect(interleaved.updatedChunk.resolvedSource.contains("betaFlag"))
        #expect(interleaved.updatedChunk.resolvedSource.contains("zebraFlag"))
    }

    // MARK: - 13. `InteractiveConflictResolutionEngine`: `preferVerifiedTestPassingLane`

    @Test("InteractiveConflictResolutionEngine selects test-passing green lane via preferVerifiedTestPassingLane")
    func interactiveResolutionPrefersVerifiedGreenLane() {
        let base = "public func computeTax(cents: Int) -> Int {\n    return cents / 10\n}\n"
        let leftBroken = "public func computeTax(cents: Int) -> Int {\n    return cents - 9999\n}\n"
        let rightGreen = "public func computeTax(cents: Int) -> Int {\n    return (cents * 15) / 100\n}\n"

        let report = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "Sources/Tax.swift",
            baseSource: base,
            leftSource: leftBroken,
            rightSource: rightGreen,
            leftLaneID: "lane-claude",
            rightLaneID: "lane-codex"
        )

        let evidence: [String: LaneVerificationEvidence] = [
            "lane-claude": LaneVerificationEvidence(
                laneID: "lane-claude",
                vendor: .claudeCode,
                exitCode: 1,
                passedTestCount: 18,
                failedTestCount: 3
            ),
            "lane-codex": LaneVerificationEvidence(
                laneID: "lane-codex",
                vendor: .codex,
                exitCode: 0,
                passedTestCount: 24,
                failedTestCount: 0,
                compilerWarningCount: 0
            ),
        ]

        let resolver = InteractiveConflictResolutionEngine()
        let session = resolver.resolveAllConflicts(
            in: report,
            strategy: .preferVerifiedTestPassingLane,
            laneEvidence: evidence
        )
        #expect(session.remainingConflictCount == 0)
        #expect(session.chunkOutcomes.first?.verificationSelection?.decision == .selectedRightVerifiedGreen)
        #expect(session.chunkOutcomes.first?.verificationSelection?.winningLaneID == "lane-codex")
        #expect(session.emittedDocument.formattedSource.contains("(cents * 15) / 100"))
    }

    // MARK: - 14. `CleanASTSourceCodeEmitter` Indentation Detection & Delimiter Balance Audit

    @Test("CleanASTSourceCodeEmitter detects 2-space/4-space/tab indentation and audits unbalanced delimiters")
    func cleanASTSourceEmitterIndentationAndDelimiterAudit() {
        let emitter = CleanASTSourceCodeEmitter()

        let twoSpaceTS = """
        export class Box {
          private count = 0;
          public inc(): void {
            this.count += 1;
          }
        }
        """
        let profile2 = emitter.detectIndentationProfile(samples: [twoSpaceTS])
        #expect(profile2.unitKind == .spaces)
        #expect(profile2.indentWidth == 2)

        let tabGo = "func main() {\n\tfmt.Println(\"ok\")\n}\n"
        let profileTabs = emitter.detectIndentationProfile(samples: [tabGo])
        #expect(profileTabs.unitKind == .tabs)

        // Balanced source with braces inside string literals and comments must pass
        let trickyBalanced = """
        public func render() -> String {
            // Unmatched brace in comment: {{{
            let literal = "unclosed ( [ { in string"
            return literal
        }
        """
        #expect(emitter.auditDelimiterBalance(in: trickyBalanced, language: .swift).isBalanced == true)

        // Genuinely unclosed `{` and `(` must fail delimiter audit
        let broken = "public func broken(x: Int {\n    return x\n"
        let brokenAudit = emitter.auditDelimiterBalance(in: broken, language: .swift)
        #expect(brokenAudit.isBalanced == false)
        #expect(!brokenAudit.unclosedBraceLines.isEmpty || !brokenAudit.unclosedParenLines.isEmpty)
    }

    // MARK: - 15. `CrossFileBrokenCallSiteDetector`: Arity Mismatch & Fix-It Generation

    @Test("CrossFileBrokenCallSiteDetector catches cross-lane arity mismatches and generates suggested fix-it snippets")
    func crossFileBrokenCallSiteDetectorArityAndLabelFixIts() {
        let baseEngine = """
        public struct InvoiceService {
            public func charge(amountCents: Int) -> Bool {
                return amountCents > 0
            }
        }
        """
        let baseController = """
        public struct CheckoutController {
            public func submit(service: InvoiceService) -> Bool {
                return service.charge(amountCents: 4500)
            }
        }
        """

        // Left lane (Claude) adds a required `currency: String` parameter without default value!
        let leftEngine = """
        public struct InvoiceService {
            public func charge(amountCents: Int, currency: String) -> Bool {
                return amountCents > 0 && !currency.isEmpty
            }
        }
        """

        // Right lane (Codex) adds a new call site still using the old 1-argument signature!
        let rightController = """
        public struct CheckoutController {
            public func submit(service: InvoiceService) -> Bool {
                let first = service.charge(amountCents: 4500)
                let second = service.charge(amountCents: 1200)
                return first && second
            }
        }
        """

        let detector = CrossFileBrokenCallSiteDetector()
        let diagnostics = detector.detectBrokenCallSites(
            baseFiles: [
                "Sources/Billing/InvoiceService.swift": baseEngine,
                "Sources/Web/CheckoutController.swift": baseController,
            ],
            leftLaneID: "lane-claude",
            leftFiles: [
                "Sources/Billing/InvoiceService.swift": leftEngine,
                "Sources/Web/CheckoutController.swift": baseController,
            ],
            rightLaneID: "lane-codex",
            rightFiles: [
                "Sources/Billing/InvoiceService.swift": baseEngine,
                "Sources/Web/CheckoutController.swift": rightController,
            ]
        )

        #expect(!diagnostics.isEmpty)
        let tooFew = diagnostics.first { $0.symbolName == "charge" && $0.mismatchKind == .tooFewArguments }
        #expect(tooFew != nil)
        #expect(tooFew?.modifiedByLane == "lane-claude")
        #expect(tooFew?.callerLane == "lane-codex")
        #expect(tooFew?.suggestedFixCallSnippet?.contains("currency") == true)
    }

    // MARK: - 16. `CrossFileBrokenCallSiteDetector`: Newly Required `await` / `throws` & Deleted Callable

    @Test("CrossFileBrokenCallSiteDetector detects newly required async/throws effects and deleted callables")
    func crossFileDetectorAsyncThrowsAndDeletedCallable() {
        let baseAPI = """
        public func fetchToken(userID: String) -> String {
            return userID
        }
        public func deprecatedPing() -> Int {
            return 1
        }
        """
        let baseCaller = """
        public func runFlow() {
            let tok = fetchToken(userID: "u-1")
            let p = deprecatedPing()
        }
        """

        // Left lane upgrades `fetchToken` to `async throws` and deletes `deprecatedPing`
        let leftAPI = """
        public func fetchToken(userID: String) async throws -> String {
            return userID
        }
        """

        let detector = CrossFileBrokenCallSiteDetector()
        let diags = detector.detectBrokenCallSites(
            baseFiles: ["Sources/API.swift": baseAPI, "Sources/Flow.swift": baseCaller],
            leftLaneID: "lane-claude",
            leftFiles: ["Sources/API.swift": leftAPI, "Sources/Flow.swift": baseCaller],
            rightLaneID: "lane-codex",
            rightFiles: ["Sources/API.swift": baseAPI, "Sources/Flow.swift": baseCaller]
        )

        #expect(diags.contains { $0.symbolName == "deprecatedPing" && $0.mismatchKind == .callableDeletedWhileReferenced })
        #expect(diags.contains {
            $0.symbolName == "fetchToken" &&
            ($0.mismatchKind == .newlyRequiredAsyncAwait || $0.mismatchKind == .newlyRequiredTryEffect)
        })
    }

    // MARK: - 17. Cross-Language Import Directive Extraction Across 6 Syntaxes

    @Test("CrossLanguageCouplingAndIsometricEngine extracts imports from Swift, Python, TS/CJS, Rust, Go, and C")
    func extractCrossLanguageImportDirectives() {
        let engine = CrossLanguageCouplingAndIsometricEngine()

        let swiftImports = engine.extractImportDirectives(
            filePath: "Sources/App/Main.swift",
            source: "import Foundation\nimport RelayModels\n"
        )
        #expect(swiftImports.map(\.moduleSpecifier) == ["Foundation", "RelayModels"])

        let pyImports = engine.extractImportDirectives(
            filePath: "pkg/worker.py",
            source: "import os\nfrom .models import Invoice, Receipt\n"
        )
        #expect(pyImports.count == 2)
        #expect(pyImports.contains { $0.isRelativeImport && $0.importedSymbols.contains("Invoice") })

        let tsImports = engine.extractImportDirectives(
            filePath: "src/index.ts",
            source: """
            import { Router, Request } from "./http/router";
            const crypto = require("node:crypto");
            """
        )
        #expect(tsImports.contains { $0.syntaxKind == .esmImportOrReexport && $0.isRelativeImport })
        #expect(tsImports.contains { $0.syntaxKind == .commonJSRequire && $0.moduleSpecifier == "node:crypto" })

        let rustImports = engine.extractImportDirectives(
            filePath: "src/lib.rs",
            source: "use crate::ring::ByteRing;\nmod codec;\n"
        )
        #expect(rustImports.count == 2)

        let goImports = engine.extractImportDirectives(
            filePath: "internal/server.go",
            source: """
            package internal
            import (
                "fmt"
                "github.com/relayide/core/wiretap"
            )
            """
        )
        #expect(goImports.contains { $0.moduleSpecifier == "github.com/relayide/core/wiretap" })
    }

    // MARK: - 18. Tarjan's Strongly Connected Components Cycle Detection

    @Test("CrossLanguageCouplingAndIsometricEngine detects dependency cycles via Tarjan SCC and flags cross-lane loops")
    func tarjanStronglyConnectedDependencyCycles() {
        let engine = CrossLanguageCouplingAndIsometricEngine()

        // Graph: A -> B -> C -> A (3-cycle spanning lane-claude and lane-codex), plus D -> E (acyclic tail)
        let adjacency: [String: Set<String>] = [
            "Sources/Auth/Session.swift": ["Sources/Billing/Wallet.swift"],
            "Sources/Billing/Wallet.swift": ["Sources/Audit/Logger.swift"],
            "Sources/Audit/Logger.swift": ["Sources/Auth/Session.swift", "Sources/Leaf/Utils.swift"],
            "Sources/Leaf/Utils.swift": [],
        ]
        let laneOwners: [String: Set<String>] = [
            "Sources/Auth/Session.swift": ["lane-claude"],
            "Sources/Billing/Wallet.swift": ["lane-codex"],
            "Sources/Audit/Logger.swift": ["lane-codex"],
        ]

        let cycles = engine.computeTarjanDependencyCycles(adjacency: adjacency, laneOwnerByNode: laneOwners)
        #expect(cycles.count == 1)
        let cycle = cycles[0]
        #expect(Set(cycle.memberNodes) == Set([
            "Sources/Auth/Session.swift",
            "Sources/Billing/Wallet.swift",
            "Sources/Audit/Logger.swift",
        ]))
        #expect(cycle.spansMultipleAgentLanes == true)
        #expect(cycle.witnessCyclePath.first == cycle.witnessCyclePath.last)
    }

    // MARK: - 19. Martin Coupling Metrics $(C_a, C_e, I, A, D)$ & Architecture Zones

    @Test("MartinPackageCouplingMetrics computes instability I, abstractness A, main-sequence distance D, and zone")
    func martinCouplingMetricsMathematicalFormulas() {
        // Stable & abstract core package: Ca = 8, Ce = 2 -> I = 2/10 = 0.2; 3 protocols + 1 struct -> A = 3/4 = 0.75
        // D = |0.75 + 0.20 - 1.0| = 0.05 -> Healthy Main Sequence!
        let coreMetrics = MartinPackageCouplingMetrics(
            packageName: "CoreContracts",
            filePaths: ["Sources/CoreContracts/PaymentSettler.swift"],
            afferentCoupling: 8,
            efferentCoupling: 2,
            abstractTypeCount: 3,
            concreteTypeCount: 1
        )
        #expect(abs(coreMetrics.instability - 0.20) < 0.0001)
        #expect(abs(coreMetrics.abstractness - 0.75) < 0.0001)
        #expect(abs(coreMetrics.distanceFromMainSequence - 0.05) < 0.0001)
        #expect(coreMetrics.zone == .healthyMainSequence)

        // Rigid & concrete package depended on by everyone: Ca = 10, Ce = 0 -> I = 0.0, A = 0.0 -> D = 1.0 -> Zone of Pain
        let rigidConcrete = MartinPackageCouplingMetrics(
            packageName: "LegacySingleton",
            filePaths: ["Sources/LegacySingleton/DB.swift"],
            afferentCoupling: 10,
            efferentCoupling: 0,
            abstractTypeCount: 0,
            concreteTypeCount: 5
        )
        #expect(abs(rigidConcrete.instability - 0.0) < 0.0001)
        #expect(abs(rigidConcrete.abstractness - 0.0) < 0.0001)
        #expect(abs(rigidConcrete.distanceFromMainSequence - 1.0) < 0.0001)
        #expect(rigidConcrete.zone == .zoneOfPain)
    }

    // MARK: - 20. 2.5D Isometric City Topology Scene, Diamond Coordinates & Boundary Alerts

    @Test("CrossLanguageCouplingAndIsometricEngine builds 2.5D isometric tiles, coupling arcs, heat overlays, and boundary alerts")
    func buildIsometricCitySceneGeometryAndBoundaryCollisionAlerts() {
        let workspaceFiles: [String: String] = [
            "Sources/Core/Contracts.swift": """
            public protocol LedgerStore {
                func save(amount: Int)
            }
            """,
            "Sources/Billing/BillingService.swift": """
            import Core
            public struct BillingService {
                public func run(store: LedgerStore) {
                    store.save(amount: 100)
                }
            }
            """,
            "Sources/Web/BillingEndpoint.swift": """
            import Billing
            public struct BillingEndpoint {
                public func handle(svc: BillingService, store: LedgerStore) {
                    svc.run(store: store)
                }
            }
            """,
        ]

        let activities = [
            AgentTerritoryActivityInput(
                laneID: "lane-claude",
                vendor: .claudeCode,
                dirtyChurnByPath: [
                    "Sources/Core/Contracts.swift": 24,
                    "Sources/Billing/BillingService.swift": 40, // Contested overlap!
                ]
            ),
            AgentTerritoryActivityInput(
                laneID: "lane-codex",
                vendor: .codex,
                dirtyChurnByPath: [
                    "Sources/Billing/BillingService.swift": 35, // Contested overlap!
                    "Sources/Web/BillingEndpoint.swift": 50,
                ]
            ),
        ]

        let engine = CrossLanguageCouplingAndIsometricEngine(tileWidthPx: 88.0, tileDepthHeightPx: 44.0)
        let scene = engine.buildIsometricCityScene(
            workspaceFiles: workspaceFiles,
            agentActivities: activities,
            conflictedPaths: ["Sources/Billing/BillingService.swift"]
        )

        #expect(scene.tiles.count == 3)
        #expect(!scene.packageMetrics.isEmpty)
        #expect(scene.agentHeatOverlays.count == 2)

        // Verify isometric diamond polygon geometry (north.y < south.y, west.x < east.x, roof higher than base)
        for tile in scene.tiles {
            #expect(tile.extrusionHeightPx > 0)
            #expect(tile.baseFootprint.west.x < tile.baseFootprint.east.x)
            #expect(tile.baseFootprint.north.y < tile.baseFootprint.south.y)
            #expect(tile.roofCenter.y < tile.screenCenter.y)
        }

        let contestedTile = scene.tiles.first { $0.relativePath == "Sources/Billing/BillingService.swift" }
        #expect(contestedTile?.hasMergeConflict == true)
        #expect((contestedTile?.contendingLaneIDs.count ?? 0) == 2)
        #expect(scene.boundaryAlerts.contains { $0.kind == .directMultiLaneTileOverlap })

        // Verify conversion bridge to RelayModels `IsometricModuleTower`
        let tower = contestedTile!.toIsometricModuleTower()
        #expect(tower.relativePath == "Sources/Billing/BillingService.swift")
        #expect(tower.hasMergeConflict == true)
    }

    // MARK: - 21. `ThreeWaySemanticASTMerger.detectCrossFileSignatureCollisions` & Coupling Map

    @Test("ThreeWaySemanticASTMerger detects cross-file signature collisions and builds tower/arc coupling map")
    func threeWayMergerCrossFileCollisionsAndCouplingMap() {
        let baseA = "public struct Auth {\n    public func verify(token: String) -> Bool { true }\n}\n"
        let baseB = "public struct Gateway {\n    public func check(a: Auth) -> Bool { a.verify(token: \"x\") }\n}\n"
        let leftA = "public struct Auth {\n    public func verify(token: String, audience: String) -> Bool { true }\n}\n"

        let merger = ThreeWaySemanticASTMerger()
        let collisions = merger.detectCrossFileSignatureCollisions(
            baseFiles: ["Sources/Auth.swift": baseA, "Sources/Gateway.swift": baseB],
            leftLaneID: "lane-claude",
            leftFiles: ["Sources/Auth.swift": leftA, "Sources/Gateway.swift": baseB],
            rightLaneID: "lane-codex",
            rightFiles: ["Sources/Auth.swift": baseA, "Sources/Gateway.swift": baseB]
        )
        #expect(!collisions.isEmpty)
        #expect(collisions[0].symbolName == "verify")

        let map = merger.buildIsometricCouplingMap(
            files: ["Sources/Auth.swift": leftA, "Sources/Gateway.swift": baseB],
            laneOwnerByPath: [
                "Sources/Auth.swift": ("lane-claude", .claudeCode),
                "Sources/Gateway.swift": ("lane-codex", .codex),
            ]
        )
        #expect(map.towers.count == 2)
        #expect(map.arcs.contains { $0.crossesAgentLanes })
    }

    // MARK: - 22. Verification Tie-Breaking in `InteractiveConflictResolutionEngine`

    @Test("InteractiveConflictResolutionEngine evaluates tied or missing verification evidence deterministically")
    func verificationLaneTieBreakerAndMissingEvidence() {
        let resolver = InteractiveConflictResolutionEngine()

        // Missing evidence on both sides with no fallback -> unresolvedBothFailedOrMissingEvidence
        let missingOutcome = resolver.evaluateVerifiedLanePreference(
            leftLaneID: "lane-a",
            rightLaneID: "lane-b",
            laneEvidence: [:],
            fallback: nil
        )
        #expect(missingOutcome.decision == .unresolvedBothFailedOrMissingEvidence)
        #expect(missingOutcome.winningLaneID == nil)

        // Both green, left has more passed tests & zero warnings -> selectedHigherQualityGreenLane
        let bothGreen = resolver.evaluateVerifiedLanePreference(
            leftLaneID: "lane-a",
            rightLaneID: "lane-b",
            laneEvidence: [
                "lane-a": LaneVerificationEvidence(laneID: "lane-a", exitCode: 0, passedTestCount: 45, compilerWarningCount: 0),
                "lane-b": LaneVerificationEvidence(laneID: "lane-b", exitCode: 0, passedTestCount: 12, compilerWarningCount: 4),
            ]
        )
        #expect(bothGreen.decision == .selectedHigherQualityGreenLane)
        #expect(bothGreen.winningLaneID == "lane-a")
    }

    // MARK: - 23. M0 Rework (R28): `LineAnchoredGuardedMerger` (git merge-file as the anchor, the engine only as referee)

    private var pathGitMerger: LineAnchoredGuardedMerger {
        LineAnchoredGuardedMerger(environment: ProcessInfo.processInfo.environment)
    }

    private func makeScratchDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("LineAnchoredGuardedMerger returns git's line-level text when git merges cleanly")
    func guardedMergerReturnsGitLineResultWhenClean() throws {
        let base = "import functools\n\n\ndef f(x):\n    return x + 1\n\n\ndef g(x):\n    return x * 2\n"
        let left = base.replacingOccurrences(of: "return x + 1", with: "return x + 100")
        let right = base.replacingOccurrences(of: "def g(x):", with: "@functools.lru_cache\ndef g(x):")
        let outcome = pathGitMerger.merge(relativePath: "calc.py", baseSource: base, leftSource: left, rightSource: right)
        #expect(outcome == .clean(
            mergedText: "import functools\n\n\ndef f(x):\n    return x + 100\n\n\n@functools.lru_cache\ndef g(x):\n    return x * 2\n",
            strategy: .lineLevel,
            syntaxParser: "python3 -m py_compile",
            resolvedConflictBlocks: 0
        ))
    }

    @Test("LineAnchoredGuardedMerger keeps both insertions using git's bytes, not the engine's reformatted text")
    func guardedMergerAssemblesBothInsertionsFromGitBytes() throws {
        // A multi-line string with a blank line in it, and members that are not separated by blank lines.
        let base = "struct S {\n    let banner = \"\"\"\n        Title\n\n        end\n        \"\"\"\n    func a() -> Int { 1 }\n}\n"
        let left = base.replacingOccurrences(of: "    func a() -> Int { 1 }\n", with: "    func a() -> Int { 1 }\n    @discardableResult\n    func l() -> Int { 2 }\n")
        let right = base.replacingOccurrences(of: "    func a() -> Int { 1 }\n", with: "    func a() -> Int { 1 }\n    func r() -> Int { 3 }\n")
        let expected = "struct S {\n    let banner = \"\"\"\n        Title\n\n        end\n        \"\"\"\n    func a() -> Int { 1 }\n    @discardableResult\n    func l() -> Int { 2 }\n    func r() -> Int { 3 }\n}\n"

        let outcome = pathGitMerger.merge(relativePath: "S.swift", baseSource: base, leftSource: left, rightSource: right)
        #expect(outcome == .clean(mergedText: expected, strategy: .declarationLevel, syntaxParser: "swiftc -parse", resolvedConflictBlocks: 1))

        // The declaration engine's own text for the same input is not byte-identical to that (it re-spaces declarations),
        // which is exactly why its text is never emitted.
        let engineText = ThreeWaySemanticASTMerger().mergeFile(
            relativePath: "S.swift", baseSource: base, leftSource: left, rightSource: right, leftLaneID: "left", rightLaneID: "right"
        ).mergedText
        #expect(engineText != expected)
    }

    @Test("LineAnchoredGuardedMerger is not confused by file content that looks like a conflict separator")
    func guardedMergerHandlesSeparatorLookalikeContent() throws {
        // The string literal contains lines that are exactly git's 7-character conflict separator.
        let base = "BANNER = \"\"\"\n=======\nTitle\n\n=======\n\"\"\"\n\n\ndef a():\n    return 1\n"
        let left = base + "\n\ndef l():\n    return 2\n"
        let right = base + "\n\ndef r():\n    return 3\n"
        let keepBoth = base + "\n\ndef l():\n    return 2\n\n\ndef r():\n    return 3\n"
        let gitConflict = base + "\n\n<<<<<<< left\ndef l():\n    return 2\n=======\ndef r():\n    return 3\n>>>>>>> right\n"

        // Whatever the declaration engine makes of this file, only two results are acceptable: both insertions kept
        // around the untouched string, or git's own conflict text. The --diff3 output must have been readable.
        switch pathGitMerger.merge(relativePath: "banner.py", baseSource: base, leftSource: left, rightSource: right) {
        case .clean(let mergedText, let strategy, _, _):
            #expect(mergedText == keepBoth)
            #expect(strategy == .declarationLevel)
        case .conflict(let lineMergeText, let conflictCount, let verdict):
            #expect(lineMergeText == gitConflict)
            #expect(conflictCount == 1)
            if case .structuralMergeUnreadable(let detail) = verdict {
                Issue.record("the --diff3 output was misread: \(detail)")
            }
        case let other:
            Issue.record("unexpected outcome \(other)")
        }
    }

    @Test("LineAnchoredGuardedMerger falls back to git's conflict text when the engine does not reproduce every non-blank line in place")
    func guardedMergerRejectsEngineResultThatDoesNotMatchLineMerge() throws {
        // left decorates g, right inserts h directly above g: git sees two insertions at the same place.
        // Keeping "left then right" would silently move the decorator onto h.
        let base = "def f(x):\n    return x + 1\n\n\ndef g(x):\n    return x * 2\n"
        let left = base.replacingOccurrences(of: "def g(x):", with: "@trace\ndef g(x):")
        let right = base.replacingOccurrences(of: "def g(x):", with: "def h(x):\n    return x - 3\n\n\ndef g(x):")
        let outcome = pathGitMerger.merge(relativePath: "m.py", baseSource: base, leftSource: left, rightSource: right)
        guard case .conflict(let text, let count, let verdict) = outcome else {
            Issue.record("expected a conflict, got \(outcome)")
            return
        }
        #expect(count == 1)
        #expect(text == "def f(x):\n    return x + 1\n\n\n<<<<<<< left\n@trace\n=======\ndef h(x):\n    return x - 3\n\n\n>>>>>>> right\ndef g(x):\n    return x * 2\n")
        if case .engineDisagreesWithLineMerge = verdict {} else {
            Issue.record("expected engineDisagreesWithLineMerge, got \(verdict)")
        }
    }

    @Test("LineAnchoredGuardedMerger never resolves a conflict block that modifies or deletes base lines")
    func guardedMergerRejectsConflictsThatTouchBaseLines() throws {
        let base = "public func compute() -> Int {\n    return 1\n}\n"
        let left = base.replacingOccurrences(of: "return 1", with: "return 10")
        let right = base.replacingOccurrences(of: "return 1", with: "return 20")
        let outcome = pathGitMerger.merge(relativePath: "C.swift", baseSource: base, leftSource: left, rightSource: right)
        #expect(outcome == .conflict(
            lineMergeText: "public func compute() -> Int {\n<<<<<<< left\n    return 10\n=======\n    return 20\n>>>>>>> right\n}\n",
            conflictCount: 1,
            declarationVerdict: .conflictTouchesBaseLines(blockNumber: 1, blockCount: 1)
        ))
    }

    @Test("LineAnchoredGuardedMerger behaves exactly like git merge-file for file types without a syntax checker")
    func guardedMergerLeavesUncheckedFileTypesToGit() throws {
        let base = "pub fn base() -> u32 {\n    0\n}\n"
        let left = base + "\n#[inline]\npub fn from_left() -> u32 {\n    1\n}\n"
        let right = base + "\n#[must_use]\npub fn from_right() -> u32 {\n    2\n}\n"
        for path in ["lib.rs", "main.go", "notes.txt", "Makefile"] {
            let outcome = pathGitMerger.merge(relativePath: path, baseSource: base, leftSource: left, rightSource: right)
            guard case .conflict(let text, _, let verdict) = outcome else {
                Issue.record("\(path): expected git's conflict, got \(outcome)")
                continue
            }
            #expect(text.contains("<<<<<<< left\n") && text.contains("=======\n") && text.contains(">>>>>>> right\n"))
            #expect(verdict == .noSyntaxCheckerForFileType(fileExtension: (path as NSString).pathExtension.lowercased()))
        }
        // Clean line merges of such files are passed through, flagged as unchecked (syntaxParser == nil).
        let cleanRight = base.replacingOccurrences(of: "    0\n", with: "    7\n")
        let clean = pathGitMerger.merge(relativePath: "lib.rs", baseSource: base, leftSource: base, rightSource: cleanRight)
        #expect(clean == .clean(mergedText: cleanRight, strategy: .lineLevel, syntaxParser: nil, resolvedConflictBlocks: 0))
    }

    @Test("LineAnchoredGuardedMerger preserves a missing final newline and CRLF line endings")
    func guardedMergerPreservesFinalNewlineStateAndCRLF() throws {
        // No version ends in a newline: neither does the result.
        let base = "struct S {\n    func a() -> Int { 1 }\n}"
        let left = "struct S {\n    func a() -> Int { 1 }\n    func l() -> Int { 2 }\n}"
        let right = "struct S {\n    func a() -> Int { 1 }\n    func r() -> Int { 3 }\n}"
        let unterminated = pathGitMerger.merge(relativePath: "S.swift", baseSource: base, leftSource: left, rightSource: right)
        #expect(unterminated == .clean(
            mergedText: "struct S {\n    func a() -> Int { 1 }\n    func l() -> Int { 2 }\n    func r() -> Int { 3 }\n}",
            strategy: .declarationLevel,
            syntaxParser: "swiftc -parse",
            resolvedConflictBlocks: 1
        ))

        // Versions that disagree about the final newline are not handed to the declaration-level path at all.
        let mixed = pathGitMerger.merge(relativePath: "S.swift", baseSource: base, leftSource: left + "\n", rightSource: right)
        if case .conflict(_, _, let verdict) = mixed {
            #expect(verdict == .inconsistentFinalNewline)
        } else {
            Issue.record("expected a conflict for mixed final-newline state, got \(mixed)")
        }

        // CRLF content survives a clean merge byte for byte.
        let crlfBase = "def first():\r\n    return 1\r\n\r\n\r\ndef second():\r\n    return 2\r\n"
        let crlfLeft = crlfBase.replacingOccurrences(of: "return 1", with: "return 100")
        let crlfRight = crlfBase.replacingOccurrences(of: "return 2", with: "return 200")
        let crlf = pathGitMerger.merge(relativePath: "m.py", baseSource: crlfBase, leftSource: crlfLeft, rightSource: crlfRight)
        guard case .clean(let crlfText, let strategy, _, _) = crlf else {
            Issue.record("expected a clean CRLF merge, got \(crlf)")
            return
        }
        #expect(strategy == .lineLevel)
        #expect(Array(crlfText.utf8) == Array("def first():\r\n    return 100\r\n\r\n\r\ndef second():\r\n    return 200\r\n".utf8))
    }

    @Test("LineAnchoredGuardedMerger refuses to merge when git is missing, is not git, or fails")
    func guardedMergerRefusesWithoutWorkingGit() throws {
        let base = "x = 1\ny = 2\n"
        let left = "x = 10\ny = 2\n"
        let right = "x = 1\ny = 20\n"
        func isUnavailable(_ outcome: GuardedMergeOutcome) -> Bool {
            if case .lineMergeUnavailable = outcome { return true }
            return false
        }

        #expect(isUnavailable(LineAnchoredGuardedMerger(gitExecutablePath: nil).merge(relativePath: "a.py", baseSource: base, leftSource: left, rightSource: right)))
        #expect(LineAnchoredGuardedMerger.locateGit(in: [:]) == nil)
        #expect(LineAnchoredGuardedMerger.locateGit(in: ["PATH": "/nonexistent-relay-dir"]) == nil)

        let scratch = try makeScratchDirectory(prefix: "relay-fake-git")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func fakeGit(_ name: String, _ script: String) throws -> String {
            let url = scratch.appendingPathComponent(name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        // 1. Not there at all.
        let missing = scratch.appendingPathComponent("no-such-git").path
        // 2. Exits 0 and prints nothing: would otherwise be read as "clean merge, empty file".
        let silent = try fakeGit("silent", "#!/bin/sh\nexit 0\n")
        // 3. Fails like a shim that cannot find the real tool: would otherwise be read as "1 conflict".
        let failing = try fakeGit("failing", "#!/bin/sh\necho 'no developer tools' >&2\nexit 1\n")
        // 4. Identifies as git but merge-file errors out.
        let brokenMerge = try fakeGit("broken-merge", "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'git version 0.0.0'; exit 0; fi\necho 'fatal: boom' >&2\nexit 255\n")
        // 5. Identifies as git, claims one conflict, prints no conflict markers.
        let markerless = try fakeGit("markerless", "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'git version 0.0.0'; exit 0; fi\nexit 1\n")

        for path in [missing, silent, failing, brokenMerge, markerless] {
            let outcome = LineAnchoredGuardedMerger(gitExecutablePath: path).merge(relativePath: "a.py", baseSource: base, leftSource: left, rightSource: right)
            #expect(isUnavailable(outcome), "\((path as NSString).lastPathComponent): expected lineMergeUnavailable, got \(outcome)")
        }
    }

    @Test("Conflict-marker width and --diff3 parsing cannot be confused by marker-like lines in the files")
    func guardedMergerMarkerSizeAndDiff3Parsing() throws {
        func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

        #expect(LineAnchoredGuardedMerger.unambiguousMarkerSize(for: [bytes("a\nb\n")]) == 7)
        #expect(LineAnchoredGuardedMerger.unambiguousMarkerSize(for: [bytes("Title\n=======\n")]) == 8)
        #expect(LineAnchoredGuardedMerger.unambiguousMarkerSize(for: [bytes("x\n"), bytes("<<<<<<<<<< left\n"), bytes("||\n")]) == 11)
        #expect(LineAnchoredGuardedMerger.unambiguousMarkerSize(for: [bytes("a ======= b\n")]) == 7)
        #expect(LineAnchoredGuardedMerger.unambiguousMarkerSize(for: [bytes(">>>>>>>>>")]) == 10)

        let output = bytes("keep\n=======\n<<<<<<<< left\nL1\n\n|||||||| base\n========\nR1\n>>>>>>>> right\ntail")
        let parsed = try LineAnchoredGuardedMerger.parseDiff3(output, markerSize: 8).get()
        #expect(parsed == [
            .stable(bytes("keep\n=======\n")),
            .conflict(left: bytes("L1\n\n"), base: [], right: bytes("R1\n")),
            .stable(bytes("tail"))
        ])

        for malformed in ["<<<<<<< left\nL\n", "=======\n", "<<<<<<< left\n<<<<<<< left\n", "a\n>>>>>>> right\n"] {
            if case .success(let segments) = LineAnchoredGuardedMerger.parseDiff3(bytes(malformed), markerSize: 7) {
                Issue.record("malformed --diff3 text was accepted: \(malformed.debugDescription) -> \(segments)")
            }
        }

        #expect(LineAnchoredGuardedMerger.nonBlankLines(bytes("a\n\n  \t\r\n b \nc")) == [bytes("a"), bytes(" b "), bytes("c")])
        #expect(LineAnchoredGuardedMerger.splitLinesKeepingTerminators(bytes("a\n\nb")).map { Array($0) } == [bytes("a\n"), bytes("\n"), bytes("b")])
    }
}
