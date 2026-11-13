import Foundation
import RelayModels

// MARK: - 3-Way Semantic AST Merger, Cross-File Collision Detector & Isometric Coupling Analyzer

public struct ThreeWaySemanticASTMerger: Sendable {
    public let parser = MultiLanguageDeclarationParser()

    public init() {}

    /// Performs a declaration-level 3-Way Semantic AST Merge across `base`, `left`, and `right` revisions of a file.
    public func mergeFile(
        relativePath: String,
        baseSource: String,
        leftSource: String,
        rightSource: String,
        leftLaneID: String,
        rightLaneID: String,
        leftVendor: AgentVendor? = nil,
        rightVendor: AgentVendor? = nil
    ) -> ThreeWaySemanticMergeReport {
        let language = SourceLanguage.detect(fromPath: relativePath)
        let baseNodes = parser.parseDeclarations(source: baseSource, language: language)
        let leftNodes = parser.parseDeclarations(source: leftSource, language: language)
        let rightNodes = parser.parseDeclarations(source: rightSource, language: language)

        let lineMergeWouldConflict = detectLineLevelAdjacentOverlap(
            base: baseSource,
            left: leftSource,
            right: rightSource
        )

        var baseByKey: [String: ASTDeclarationNode] = [:]
        for n in baseNodes { baseByKey[n.qualifiedKey] = n }
        var leftByKey: [String: ASTDeclarationNode] = [:]
        for n in leftNodes { leftByKey[n.qualifiedKey] = n }
        var rightByKey: [String: ASTDeclarationNode] = [:]
        for n in rightNodes { rightByKey[n.qualifiedKey] = n }

        // Establish deterministic declaration ordering: Base order -> Left additions -> Right additions
        var orderedKeys: [String] = []
        var seen = Set<String>()
        for list in [baseNodes, leftNodes, rightNodes] {
            for node in list where seen.insert(node.qualifiedKey).inserted {
                orderedKeys.append(node.qualifiedKey)
            }
        }

        // Ensure ImportBlock always stays at index 0 if present
        if let impIdx = orderedKeys.firstIndex(of: "ImportBlock:__imports__"), impIdx > 0 {
            let key = orderedKeys.remove(at: impIdx)
            orderedKeys.insert(key, at: 0)
        }

        var chunks: [SemanticMergeChunk] = []
        var autoMergedCount = 0
        var conflictCount = 0

        for key in orderedKeys {
            let bNode = baseByKey[key]
            let lNode = leftByKey[key]
            let rNode = rightByKey[key]
            let sampleNode = lNode ?? rNode ?? bNode!

            // Special Case 1: Import Block Set Union
            if sampleNode.kind == .importGroup {
                let bSet = Set(bNode?.importedModules ?? [])
                let lSet = Set(lNode?.importedModules ?? [])
                let rSet = Set(rNode?.importedModules ?? [])
                if lSet == bSet && rSet == bSet {
                    let src = bNode?.fullTextWithTrivia ?? ""
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: "__imports__",
                            kind: .importGroup,
                            resolution: .unchanged,
                            baseSource: bNode?.fullTextWithTrivia,
                            leftSource: lNode?.fullTextWithTrivia,
                            rightSource: rNode?.fullTextWithTrivia,
                            resolvedSource: src,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Import header unchanged across both lanes."
                        )
                    )
                } else {
                    let addedL = lSet.subtracting(bSet)
                    let addedR = rSet.subtracting(bSet)
                    let removedL = bSet.subtracting(lSet)
                    let removedR = bSet.subtracting(rSet)
                    let unioned = bSet.subtracting(removedL).subtracting(removedR).union(addedL).union(addedR).sorted()
                    let mergedImports = unioned.joined(separator: "\n")
                    let res: SemanticMergeResolution = (!addedL.isEmpty && !addedR.isEmpty) ? .autoMergedImportSetUnion : (lSet != bSet ? .leftModifiedOnly : .rightModifiedOnly)
                    if res == .autoMergedImportSetUnion { autoMergedCount += 1 }
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: "__imports__",
                            kind: .importGroup,
                            resolution: res,
                            baseSource: bNode?.fullTextWithTrivia,
                            leftSource: lNode?.fullTextWithTrivia,
                            rightSource: rNode?.fullTextWithTrivia,
                            resolvedSource: mergedImports,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Unioned imports from \(leftLaneID) and \(rightLaneID) deterministically."
                        )
                    )
                }
                continue
            }

            // Case 2: Added in one or both lanes (absent from Base)
            if bNode == nil {
                switch (lNode, rNode) {
                case (let .some(l), nil):
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: l.symbolName,
                            kind: l.kind,
                            resolution: .leftAddedDeclaration,
                            baseSource: nil,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: nil,
                            resolvedSource: l.fullTextWithTrivia,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Added new \(l.kind.rawValue) '\(l.symbolName)' from \(leftLaneID)."
                        )
                    )
                case (nil, let .some(r)):
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: r.symbolName,
                            kind: r.kind,
                            resolution: .rightAddedDeclaration,
                            baseSource: nil,
                            leftSource: nil,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: r.fullTextWithTrivia,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Added new \(r.kind.rawValue) '\(r.symbolName)' from \(rightLaneID)."
                        )
                    )
                case (let .some(l), let .some(r)):
                    if l.structuralFingerprint == r.structuralFingerprint {
                        autoMergedCount += 1
                        chunks.append(
                            SemanticMergeChunk(
                                qualifiedKey: key,
                                symbolName: l.symbolName,
                                kind: l.kind,
                                resolution: .autoMergedIdenticalChange,
                                baseSource: nil,
                                leftSource: l.fullTextWithTrivia,
                                rightSource: r.fullTextWithTrivia,
                                resolvedSource: l.fullTextWithTrivia,
                                leftVendor: leftVendor,
                                rightVendor: rightVendor,
                                explanation: "Both lanes independently introduced structurally identical '\(l.symbolName)'."
                            )
                        )
                    } else {
                        conflictCount += 1
                        let marker = formatConflictMarkers(leftLabel: leftLaneID, leftText: l.fullTextWithTrivia, rightLabel: rightLaneID, rightText: r.fullTextWithTrivia)
                        chunks.append(
                            SemanticMergeChunk(
                                qualifiedKey: key,
                                symbolName: l.symbolName,
                                kind: l.kind,
                                resolution: .conflictBothModifiedSameSymbol,
                                baseSource: nil,
                                leftSource: l.fullTextWithTrivia,
                                rightSource: r.fullTextWithTrivia,
                                resolvedSource: marker,
                                leftVendor: leftVendor,
                                rightVendor: rightVendor,
                                explanation: "Both lanes created '\(l.symbolName)' with divergent implementations."
                            )
                        )
                    }
                case (nil, nil):
                    break
                }
                continue
            }

            // Base exists (`bNode != nil`)
            let base = bNode!
            switch (lNode, rNode) {
            case (nil, nil):
                // Both deleted the declaration
                autoMergedCount += 1
            case (nil, let .some(r)):
                if r.structuralFingerprint == base.structuralFingerprint {
                    // Deleted on Left, untouched on Right -> clean deletion
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: base.symbolName,
                            kind: base.kind,
                            resolution: .leftDeletedDeclaration,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: nil,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: "",
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Deleted '\(base.symbolName)' per \(leftLaneID) (untouched in \(rightLaneID))."
                        )
                    )
                } else {
                    conflictCount += 1
                    let marker = formatConflictMarkers(leftLabel: "\(leftLaneID) (deleted)", leftText: "", rightLabel: rightLaneID, rightText: r.fullTextWithTrivia)
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: base.symbolName,
                            kind: base.kind,
                            resolution: .conflictDeleteModify,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: nil,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: marker,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "\(leftLaneID) deleted '\(base.symbolName)' while \(rightLaneID) modified it."
                        )
                    )
                }
            case (let .some(l), nil):
                if l.structuralFingerprint == base.structuralFingerprint {
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: base.symbolName,
                            kind: base.kind,
                            resolution: .rightDeletedDeclaration,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: nil,
                            resolvedSource: "",
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Deleted '\(base.symbolName)' per \(rightLaneID) (untouched in \(leftLaneID))."
                        )
                    )
                } else {
                    conflictCount += 1
                    let marker = formatConflictMarkers(leftLabel: leftLaneID, leftText: l.fullTextWithTrivia, rightLabel: "\(rightLaneID) (deleted)", rightText: "")
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: base.symbolName,
                            kind: base.kind,
                            resolution: .conflictDeleteModify,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: nil,
                            resolvedSource: marker,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "\(leftLaneID) modified '\(base.symbolName)' while \(rightLaneID) deleted it."
                        )
                    )
                }
            case (let .some(l), let .some(r)):
                let lChanged = l.structuralFingerprint != base.structuralFingerprint
                let rChanged = r.structuralFingerprint != base.structuralFingerprint

                if !lChanged && !rChanged {
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: base.symbolName,
                            kind: base.kind,
                            resolution: .unchanged,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: base.fullTextWithTrivia,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Unchanged across both lanes."
                        )
                    )
                } else if lChanged && !rChanged {
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: l.symbolName,
                            kind: l.kind,
                            resolution: .leftModifiedOnly,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: l.fullTextWithTrivia,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Modified exclusively by \(leftLaneID)."
                        )
                    )
                } else if !lChanged && rChanged {
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: r.symbolName,
                            kind: r.kind,
                            resolution: .rightModifiedOnly,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: r.fullTextWithTrivia,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Modified exclusively by \(rightLaneID)."
                        )
                    )
                } else if l.structuralFingerprint == r.structuralFingerprint {
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: l.symbolName,
                            kind: l.kind,
                            resolution: .autoMergedIdenticalChange,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: l.fullTextWithTrivia,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Both lanes applied structurally identical edits to '\(l.symbolName)'."
                        )
                    )
                } else if let nestedMerged = tryMergeNestedTypeMembers(base: base, left: l, right: r) {
                    autoMergedCount += 1
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: l.symbolName,
                            kind: l.kind,
                            resolution: .autoMergedNestedMembers,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: nestedMerged,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Recursively merged disjoint member declarations inside \(l.kind.rawValue) '\(l.symbolName)'."
                        )
                    )
                } else {
                    conflictCount += 1
                    let marker = formatConflictMarkers(leftLabel: leftLaneID, leftText: l.fullTextWithTrivia, rightLabel: rightLaneID, rightText: r.fullTextWithTrivia)
                    chunks.append(
                        SemanticMergeChunk(
                            qualifiedKey: key,
                            symbolName: l.symbolName,
                            kind: l.kind,
                            resolution: .conflictBothModifiedSameSymbol,
                            baseSource: base.fullTextWithTrivia,
                            leftSource: l.fullTextWithTrivia,
                            rightSource: r.fullTextWithTrivia,
                            resolvedSource: marker,
                            leftVendor: leftVendor,
                            rightVendor: rightVendor,
                            explanation: "Both \(leftLaneID) and \(rightLaneID) edited '\(l.symbolName)' with divergent logic."
                        )
                    )
                }
            }
        }

        let nonEmptyBlocks = chunks.map(\.resolvedSource).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let mergedDocument = nonEmptyBlocks.joined(separator: "\n\n") + "\n"

        return ThreeWaySemanticMergeReport(
            relativePath: relativePath,
            language: language,
            leftLaneID: leftLaneID,
            rightLaneID: rightLaneID,
            chunks: chunks,
            mergedText: mergedDocument,
            autoMergedCount: autoMergedCount,
            unresolvedConflictCount: conflictCount,
            wouldGitLineMergeConflict: lineMergeWouldConflict
        )
    }

    /// Recursively merges disjoint child members inside a `struct` / `class` / `enum` / `extension` / `impl` container.
    private func tryMergeNestedTypeMembers(
        base: ASTDeclarationNode,
        left: ASTDeclarationNode,
        right: ASTDeclarationNode
    ) -> String? {
        guard !left.children.isEmpty || !right.children.isEmpty else { return nil }
        let baseHeader = extractOuterHeaderBeforeFirstBrace(base.declarationSource)
        let leftHeader = extractOuterHeaderBeforeFirstBrace(left.declarationSource)
        let rightHeader = extractOuterHeaderBeforeFirstBrace(right.declarationSource)
        // If both lanes also changed the type's conformance/inheritance header differently, cannot auto-merge
        if leftHeader != baseHeader && rightHeader != baseHeader && leftHeader != rightHeader {
            return nil
        }
        let chosenHeader = leftHeader != baseHeader ? leftHeader : rightHeader

        var bMap: [String: ASTDeclarationNode] = [:]
        base.children.forEach { bMap[$0.qualifiedKey] = $0 }
        var lMap: [String: ASTDeclarationNode] = [:]
        left.children.forEach { lMap[$0.qualifiedKey] = $0 }
        var rMap: [String: ASTDeclarationNode] = [:]
        right.children.forEach { rMap[$0.qualifiedKey] = $0 }

        var keys: [String] = []
        var seen = Set<String>()
        for list in [base.children, left.children, right.children] {
            for c in list where seen.insert(c.qualifiedKey).inserted {
                keys.append(c.qualifiedKey)
            }
        }

        var mergedMembers: [String] = []
        for k in keys {
            let b = bMap[k]
            let l = lMap[k]
            let r = rMap[k]
            switch (b, l, r) {
            case (nil, let .some(lv), nil):
                mergedMembers.append(lv.fullTextWithTrivia)
            case (nil, nil, let .some(rv)):
                mergedMembers.append(rv.fullTextWithTrivia)
            case (nil, let .some(lv), let .some(rv)):
                guard lv.structuralFingerprint == rv.structuralFingerprint else { return nil }
                mergedMembers.append(lv.fullTextWithTrivia)
            case (let .some(bv), let .some(lv), let .some(rv)):
                let lc = lv.structuralFingerprint != bv.structuralFingerprint
                let rc = rv.structuralFingerprint != bv.structuralFingerprint
                if lc && rc && lv.structuralFingerprint != rv.structuralFingerprint {
                    return nil // True member-level collision
                }
                mergedMembers.append(lc ? lv.fullTextWithTrivia : (rc ? rv.fullTextWithTrivia : bv.fullTextWithTrivia))
            case (let .some(bv), nil, let .some(rv)):
                guard rv.structuralFingerprint == bv.structuralFingerprint else { return nil }
            case (let .some(bv), let .some(lv), nil):
                guard lv.structuralFingerprint == bv.structuralFingerprint else { return nil }
            default:
                break
            }
        }

        let bodyJoined = mergedMembers.joined(separator: "\n\n")
        return "\(left.leadingTrivia)\(chosenHeader) {\n\(bodyJoined)\n}"
    }

    // MARK: - Cross-File Call-Signature Collision Detector & Isometric Tower Builder

    public func detectCrossFileSignatureCollisions(
        baseFiles: [String: String],
        leftLaneID: String,
        leftFiles: [String: String],
        rightLaneID: String,
        rightFiles: [String: String]
    ) -> [CrossFileSignatureCollision] {
        var collisions: [CrossFileSignatureCollision] = []

        // Collect signature changes in Left and Right relative to Base
        let leftSigChanges = collectSignatureChanges(baseFiles: baseFiles, updatedFiles: leftFiles, laneID: leftLaneID)
        let rightSigChanges = collectSignatureChanges(baseFiles: baseFiles, updatedFiles: rightFiles, laneID: rightLaneID)

        // Check if Right lane calls any symbol whose parameter signature changed in Left lane (and vice versa)
        collisions.append(contentsOf: matchCallSitesAgainstSignatureChanges(
            changes: leftSigChanges,
            callerLaneID: rightLaneID,
            callerFiles: rightFiles
        ))
        collisions.append(contentsOf: matchCallSitesAgainstSignatureChanges(
            changes: rightSigChanges,
            callerLaneID: leftLaneID,
            callerFiles: leftFiles
        ))

        return collisions
    }

    public func buildIsometricCouplingMap(
        files: [String: String],
        laneOwnerByPath: [String: (laneID: String, vendor: AgentVendor)] = [:],
        conflictedPaths: Set<String> = []
    ) -> (towers: [IsometricModuleTower], arcs: [IsometricCouplingArc]) {
        let sortedPaths = files.keys.sorted()
        var declsByFile: [String: [ASTDeclarationNode]] = [:]
        var symbolOwnerFile: [String: String] = [:]

        for path in sortedPaths {
            let src = files[path] ?? ""
            let lang = SourceLanguage.detect(fromPath: path)
            let nodes = parser.parseDeclarations(source: src, language: lang)
            declsByFile[path] = nodes
            for n in nodes where n.kind != .importGroup {
                symbolOwnerFile[n.symbolName] = path
                for child in n.children {
                    symbolOwnerFile[child.symbolName] = path
                }
            }
        }

        var fanIn: [String: Int] = [:]
        var fanOut: [String: Int] = [:]
        var pairWeight: [String: (src: String, dst: String, count: Int)] = [:]

        for path in sortedPaths {
            let nodes = declsByFile[path] ?? []
            var refs = Set<String>()
            for n in nodes {
                refs.formUnion(n.referencedSymbols)
                for c in n.children { refs.formUnion(c.referencedSymbols) }
            }
            for sym in refs {
                if let targetPath = symbolOwnerFile[sym], targetPath != path {
                    fanOut[path, default: 0] += 1
                    fanIn[targetPath, default: 0] += 1
                    let key = "\(path)->\(targetPath)"
                    let prev = pairWeight[key]?.count ?? 0
                    pairWeight[key] = (path, targetPath, prev + 1)
                }
            }
        }

        let gridCols = max(1, Int(Double(sortedPaths.count).squareRoot().rounded(.up)))
        var towers: [IsometricModuleTower] = []
        for (idx, path) in sortedPaths.enumerated() {
            let src = files[path] ?? ""
            let lines = src.components(separatedBy: "\n").count
            let nodes = declsByFile[path] ?? []
            let comps = path.split(separator: "/").map(String.init)
            let modName = comps.count >= 2 ? comps[comps.count - 2] : "Root"
            let owner = laneOwnerByPath[path]

            towers.append(
                IsometricModuleTower(
                    relativePath: path,
                    moduleName: modName,
                    language: SourceLanguage.detect(fromPath: path),
                    lineCount: lines,
                    declarationCount: nodes.count,
                    fanIn: fanIn[path, default: 0],
                    fanOut: fanOut[path, default: 0],
                    activeOwnerVendor: owner?.vendor,
                    activeLaneID: owner?.laneID,
                    hasMergeConflict: conflictedPaths.contains(path),
                    gridColumn: idx % gridCols,
                    gridRow: idx / gridCols
                )
            )
        }

        let arcs = pairWeight.values.sorted { $0.src < $1.src }.map { entry in
            let laneA = laneOwnerByPath[entry.src]?.laneID
            let laneB = laneOwnerByPath[entry.dst]?.laneID
            let crosses = (laneA != nil && laneB != nil && laneA != laneB)
            return IsometricCouplingArc(
                sourcePath: entry.src,
                targetPath: entry.dst,
                sharedSymbolCount: entry.count,
                crossesAgentLanes: crosses
            )
        }

        return (towers, arcs)
    }

    // MARK: - Internal Helpers

    private struct SignatureChange {
        let symbolName: String
        let filePath: String
        let oldSig: String
        let newSig: String
        let laneID: String
    }

    private func collectSignatureChanges(
        baseFiles: [String: String],
        updatedFiles: [String: String],
        laneID: String
    ) -> [SignatureChange] {
        var out: [SignatureChange] = []
        for (path, updatedSrc) in updatedFiles {
            guard let baseSrc = baseFiles[path], baseSrc != updatedSrc else { continue }
            let lang = SourceLanguage.detect(fromPath: path)
            let bNodes = flattenCallableNodes(parser.parseDeclarations(source: baseSrc, language: lang))
            let uNodes = flattenCallableNodes(parser.parseDeclarations(source: updatedSrc, language: lang))
            var bSigByName: [String: String] = [:]
            for b in bNodes where !b.parameterSignature.isEmpty {
                bSigByName[b.symbolName] = b.parameterSignature
            }
            for u in uNodes where !u.parameterSignature.isEmpty {
                if let oldSig = bSigByName[u.symbolName], oldSig != u.parameterSignature {
                    out.append(
                        SignatureChange(
                            symbolName: u.symbolName,
                            filePath: path,
                            oldSig: oldSig,
                            newSig: u.parameterSignature,
                            laneID: laneID
                        )
                    )
                }
            }
        }
        return out
    }

    private func matchCallSitesAgainstSignatureChanges(
        changes: [SignatureChange],
        callerLaneID: String,
        callerFiles: [String: String]
    ) -> [CrossFileSignatureCollision] {
        guard !changes.isEmpty else { return [] }
        var collisions: [CrossFileSignatureCollision] = []
        for change in changes {
            for (path, src) in callerFiles where path != change.filePath {
                let lines = src.components(separatedBy: "\n")
                for (lineZero, lineText) in lines.enumerated() where lineText.contains("\(change.symbolName)(") {
                    collisions.append(
                        CrossFileSignatureCollision(
                            symbolName: change.symbolName,
                            declarationFile: change.filePath,
                            oldSignature: change.oldSig,
                            newSignature: change.newSig,
                            modifiedByLane: change.laneID,
                            callerFile: path,
                            callerLine: lineZero + 1,
                            callerLane: callerLaneID,
                            diagnosticMessage: "'\(change.symbolName)' signature changed from \(change.oldSig) to \(change.newSig) in \(change.laneID), impacting call-site at \(path):\(lineZero + 1) in \(callerLaneID)."
                        )
                    )
                }
            }
        }
        return collisions
    }

    private func flattenCallableNodes(_ nodes: [ASTDeclarationNode]) -> [ASTDeclarationNode] {
        var flat: [ASTDeclarationNode] = []
        for n in nodes {
            flat.append(n)
            flat.append(contentsOf: n.children)
        }
        return flat
    }

    private func extractOuterHeaderBeforeFirstBrace(_ src: String) -> String {
        guard let brace = src.firstIndex(of: "{") else { return src.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(src[..<brace]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatConflictMarkers(leftLabel: String, leftText: String, rightLabel: String, rightText: String) -> String {
        """
        <<<<<<< \(leftLabel)
        \(leftText)
        =======
        \(rightText)
        >>>>>>> \(rightLabel)
        """
    }

    private func detectLineLevelAdjacentOverlap(base: String, left: String, right: String) -> Bool {
        if base == left || base == right || left == right { return false }
        let bLines = base.components(separatedBy: "\n")
        let lLines = left.components(separatedBy: "\n")
        let rLines = right.components(separatedBy: "\n")
        // Classic append-at-EOF collision or header-import line-0 collision
        if lLines.count > bLines.count && rLines.count > bLines.count {
            let lTail = Array(lLines.dropFirst(min(bLines.count, lLines.count)))
            let rTail = Array(rLines.dropFirst(min(bLines.count, rLines.count)))
            if !lTail.isEmpty && !rTail.isEmpty && lTail != rTail {
                return true
            }
        }
        if lLines.first != bLines.first && rLines.first != bLines.first && lLines.first != rLines.first {
            return true
        }
        return false
    }
}
