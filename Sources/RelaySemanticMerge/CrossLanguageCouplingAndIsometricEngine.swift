import Foundation
import RelayModels

// MARK: - Multi-Language Import / Use / Include Directive Models

public enum ImportDirectiveSyntaxKind: String, Sendable, Codable, Hashable {
    case swiftImport
    case pythonImport
    case pythonFromImport
    case esmImportOrReexport
    case commonJSRequire
    case cPreprocessorInclude
    case rustUseOrMod
    case goPackageImport
}

public struct ExtractedImportDirective: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(sourceFilePath):\(lineNumber):\(moduleSpecifier)" }
    public let sourceFilePath: String
    public let lineNumber: Int
    public let syntaxKind: ImportDirectiveSyntaxKind
    public let moduleSpecifier: String
    public let importedSymbols: [String]
    public let isRelativeImport: Bool

    public init(
        sourceFilePath: String,
        lineNumber: Int,
        syntaxKind: ImportDirectiveSyntaxKind,
        moduleSpecifier: String,
        importedSymbols: [String] = [],
        isRelativeImport: Bool = false
    ) {
        self.sourceFilePath = sourceFilePath
        self.lineNumber = lineNumber
        self.syntaxKind = syntaxKind
        self.moduleSpecifier = moduleSpecifier
        self.importedSymbols = importedSymbols
        self.isRelativeImport = isRelativeImport
    }
}

// MARK: - Robert C. Martin Package Coupling Metrics & Tarjan SCC Cycles

public enum MartinArchitectureZone: String, Sendable, Codable, Hashable {
    case healthyMainSequence = "Healthy Main Sequence"
    case zoneOfPain = "Zone of Pain (Rigid & Concrete)"
    case zoneOfUselessness = "Zone of Uselessness (Abstract & Unused)"
    case autonomousIsolated = "Isolated Leaf Module"
}

public struct MartinPackageCouplingMetrics: Sendable, Codable, Hashable, Identifiable {
    public var id: String { packageName }
    public let packageName: String
    public let filePaths: [String]
    /// `Ca`: Number of external modules/packages that depend upon classes/types within this package.
    public let afferentCoupling: Int
    /// `Ce`: Number of external modules/packages that types within this package depend upon.
    public let efferentCoupling: Int
    /// `I = Ce / (Ca + Ce)` in `[0.0, 1.0]` (`0` = maximally stable, `1` = maximally instable).
    public let instability: Double
    /// `A = abstractTypes / totalTypes` in `[0.0, 1.0]`.
    public let abstractness: Double
    /// Normalized perpendicular distance from ideal `A + I = 1` line: `D = |A + I - 1|`.
    public let distanceFromMainSequence: Double
    public let abstractTypeCount: Int
    public let concreteTypeCount: Int
    public let zone: MartinArchitectureZone

    public init(
        packageName: String,
        filePaths: [String],
        afferentCoupling: Int,
        efferentCoupling: Int,
        abstractTypeCount: Int,
        concreteTypeCount: Int
    ) {
        self.packageName = packageName
        self.filePaths = filePaths
        self.afferentCoupling = max(0, afferentCoupling)
        self.efferentCoupling = max(0, efferentCoupling)
        self.abstractTypeCount = max(0, abstractTypeCount)
        self.concreteTypeCount = max(0, concreteTypeCount)

        let totalCoupling = self.afferentCoupling + self.efferentCoupling
        let computedI = totalCoupling == 0 ? 0.0 : Double(self.efferentCoupling) / Double(totalCoupling)
        self.instability = computedI

        let totalTypes = self.abstractTypeCount + self.concreteTypeCount
        let computedA = totalTypes == 0 ? 0.0 : Double(self.abstractTypeCount) / Double(totalTypes)
        self.abstractness = computedA

        let dist = abs(computedA + computedI - 1.0)
        self.distanceFromMainSequence = dist

        if totalCoupling == 0 {
            self.zone = .autonomousIsolated
        } else if computedI < 0.35 && computedA < 0.25 && dist > 0.45 {
            self.zone = .zoneOfPain
        } else if computedI > 0.65 && computedA > 0.70 && dist > 0.45 {
            self.zone = .zoneOfUselessness
        } else {
            self.zone = .healthyMainSequence
        }
    }
}

public struct StronglyConnectedDependencyCycle: Sendable, Codable, Hashable, Identifiable {
    public var id: String { memberNodes.joined(separator: "::") }
    public let memberNodes: [String]
    /// Closed witness cycle path `["A", "B", "C", "A"]`.
    public let witnessCyclePath: [String]
    public let spansMultipleAgentLanes: Bool

    public init(memberNodes: [String], witnessCyclePath: [String], spansMultipleAgentLanes: Bool) {
        self.memberNodes = memberNodes
        self.witnessCyclePath = witnessCyclePath
        self.spansMultipleAgentLanes = spansMultipleAgentLanes
    }
}

// MARK: - 2.5D Isometric City / Territory Map Coordinates, Heat Overlays & Collision Alerts

public struct IsometricPoint2D: Sendable, Codable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct IsometricDiamondPolygon: Sendable, Codable, Hashable {
    public let north: IsometricPoint2D
    public let east: IsometricPoint2D
    public let south: IsometricPoint2D
    public let west: IsometricPoint2D

    public init(
        north: IsometricPoint2D,
        east: IsometricPoint2D,
        south: IsometricPoint2D,
        west: IsometricPoint2D
    ) {
        self.north = north
        self.east = east
        self.south = south
        self.west = west
    }
}

public struct IsometricModuleTile: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let packageDistrict: String
    public let language: SourceLanguage
    public let lineCount: Int
    public let declarationCount: Int
    public let gridColumn: Int
    public let gridRow: Int
    public let extrusionHeightPx: Double
    public let screenCenter: IsometricPoint2D
    public let roofCenter: IsometricPoint2D
    public let baseFootprint: IsometricDiamondPolygon
    public let roofFootprint: IsometricDiamondPolygon
    public let afferentCoupling: Int
    public let efferentCoupling: Int
    public let instability: Double
    public let abstractness: Double
    public let distanceFromMainSequence: Double
    public let isInDependencyCycle: Bool
    public let primaryOwnerLaneID: String?
    public let primaryOwnerVendor: AgentVendor?
    public let contendingLaneIDs: [String]
    public let liveHeatIntensity: Double
    public let hasMergeConflict: Bool

    public init(
        relativePath: String,
        packageDistrict: String,
        language: SourceLanguage,
        lineCount: Int,
        declarationCount: Int,
        gridColumn: Int,
        gridRow: Int,
        extrusionHeightPx: Double,
        screenCenter: IsometricPoint2D,
        roofCenter: IsometricPoint2D,
        baseFootprint: IsometricDiamondPolygon,
        roofFootprint: IsometricDiamondPolygon,
        afferentCoupling: Int,
        efferentCoupling: Int,
        instability: Double,
        abstractness: Double,
        distanceFromMainSequence: Double,
        isInDependencyCycle: Bool,
        primaryOwnerLaneID: String?,
        primaryOwnerVendor: AgentVendor?,
        contendingLaneIDs: [String],
        liveHeatIntensity: Double,
        hasMergeConflict: Bool
    ) {
        self.relativePath = relativePath
        self.packageDistrict = packageDistrict
        self.language = language
        self.lineCount = lineCount
        self.declarationCount = declarationCount
        self.gridColumn = gridColumn
        self.gridRow = gridRow
        self.extrusionHeightPx = extrusionHeightPx
        self.screenCenter = screenCenter
        self.roofCenter = roofCenter
        self.baseFootprint = baseFootprint
        self.roofFootprint = roofFootprint
        self.afferentCoupling = afferentCoupling
        self.efferentCoupling = efferentCoupling
        self.instability = instability
        self.abstractness = abstractness
        self.distanceFromMainSequence = distanceFromMainSequence
        self.isInDependencyCycle = isInDependencyCycle
        self.primaryOwnerLaneID = primaryOwnerLaneID
        self.primaryOwnerVendor = primaryOwnerVendor
        self.contendingLaneIDs = contendingLaneIDs
        self.liveHeatIntensity = min(1.0, max(0.0, liveHeatIntensity))
        self.hasMergeConflict = hasMergeConflict
    }

    public func toIsometricModuleTower() -> IsometricModuleTower {
        IsometricModuleTower(
            relativePath: relativePath,
            moduleName: packageDistrict,
            language: language,
            lineCount: lineCount,
            declarationCount: declarationCount,
            fanIn: afferentCoupling,
            fanOut: efferentCoupling,
            activeOwnerVendor: primaryOwnerVendor,
            activeLaneID: primaryOwnerLaneID,
            hasMergeConflict: hasMergeConflict,
            gridColumn: gridColumn,
            gridRow: gridRow
        )
    }
}

public struct IsometricTerritoryCouplingArc: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(sourcePath)->\(targetPath)" }
    public let sourcePath: String
    public let targetPath: String
    public let edgeWeight: Int
    public let crossesAgentLanes: Bool
    public let isPartOfCycle: Bool
    public let violatesStableDependenciesPrinciple: Bool
    public let startRoofPoint: IsometricPoint2D
    public let apexControlPoint: IsometricPoint2D
    public let endRoofPoint: IsometricPoint2D

    public init(
        sourcePath: String,
        targetPath: String,
        edgeWeight: Int,
        crossesAgentLanes: Bool,
        isPartOfCycle: Bool,
        violatesStableDependenciesPrinciple: Bool,
        startRoofPoint: IsometricPoint2D,
        apexControlPoint: IsometricPoint2D,
        endRoofPoint: IsometricPoint2D
    ) {
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.edgeWeight = max(1, edgeWeight)
        self.crossesAgentLanes = crossesAgentLanes
        self.isPartOfCycle = isPartOfCycle
        self.violatesStableDependenciesPrinciple = violatesStableDependenciesPrinciple
        self.startRoofPoint = startRoofPoint
        self.apexControlPoint = apexControlPoint
        self.endRoofPoint = endRoofPoint
    }

    public func toIsometricCouplingArc() -> IsometricCouplingArc {
        IsometricCouplingArc(
            sourcePath: sourcePath,
            targetPath: targetPath,
            sharedSymbolCount: edgeWeight,
            crossesAgentLanes: crossesAgentLanes
        )
    }
}

public struct AgentTerritoryHeatOverlay: Sendable, Codable, Hashable, Identifiable {
    public var id: String { laneID }
    public let laneID: String
    public let vendor: AgentVendor
    public let signalHexColor: String
    public let ownedTilePaths: [String]
    public let contestedTilePaths: [String]
    public let totalChurnLines: Int
    public let averageHeat: Double
    public let boundingCentroid: IsometricPoint2D

    public init(
        laneID: String,
        vendor: AgentVendor,
        ownedTilePaths: [String],
        contestedTilePaths: [String],
        totalChurnLines: Int,
        averageHeat: Double,
        boundingCentroid: IsometricPoint2D
    ) {
        self.laneID = laneID
        self.vendor = vendor
        self.signalHexColor = vendor.signalHexColor
        self.ownedTilePaths = ownedTilePaths
        self.contestedTilePaths = contestedTilePaths
        self.totalChurnLines = max(0, totalChurnLines)
        self.averageHeat = min(1.0, max(0.0, averageHeat))
        self.boundingCentroid = boundingCentroid
    }
}

public enum TerritoryBoundaryAlertKind: String, Sendable, Codable, Hashable {
    case directMultiLaneTileOverlap = "DIRECT_TILE_OVERLAP"
    case tightlyCoupledCrossLaneBorder = "CROSS_LANE_COUPLED_CHURN"
    case crossLaneDependencyCycle = "CROSS_LANE_DEPENDENCY_CYCLE"
    case unstableDependencyIntoStableCore = "STABILITY_DIRECTION_VIOLATION"
}

public struct TerritoryBoundaryCollisionAlert: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: TerritoryBoundaryAlertKind
    public let severity: GuardrailSeverity
    public let involvedLaneIDs: [String]
    public let primaryPath: String
    public let secondaryPath: String?
    public let summary: String

    public init(
        id: UUID = UUID(),
        kind: TerritoryBoundaryAlertKind,
        severity: GuardrailSeverity,
        involvedLaneIDs: [String],
        primaryPath: String,
        secondaryPath: String? = nil,
        summary: String
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.involvedLaneIDs = involvedLaneIDs
        self.primaryPath = primaryPath
        self.secondaryPath = secondaryPath
        self.summary = summary
    }
}

public struct AgentTerritoryActivityInput: Sendable, Codable, Hashable {
    public let laneID: String
    public let vendor: AgentVendor
    public let dirtyChurnByPath: [String: Int]

    public init(laneID: String, vendor: AgentVendor, dirtyChurnByPath: [String: Int]) {
        self.laneID = laneID
        self.vendor = vendor
        self.dirtyChurnByPath = dirtyChurnByPath
    }
}

public struct IsometricCityTopologyScene: Sendable, Codable, Hashable {
    public let tiles: [IsometricModuleTile]
    public let couplingArcs: [IsometricTerritoryCouplingArc]
    public let packageMetrics: [MartinPackageCouplingMetrics]
    public let dependencyCycles: [StronglyConnectedDependencyCycle]
    public let agentHeatOverlays: [AgentTerritoryHeatOverlay]
    public let boundaryAlerts: [TerritoryBoundaryCollisionAlert]
    public let extractedImports: [ExtractedImportDirective]

    public init(
        tiles: [IsometricModuleTile],
        couplingArcs: [IsometricTerritoryCouplingArc],
        packageMetrics: [MartinPackageCouplingMetrics],
        dependencyCycles: [StronglyConnectedDependencyCycle],
        agentHeatOverlays: [AgentTerritoryHeatOverlay],
        boundaryAlerts: [TerritoryBoundaryCollisionAlert],
        extractedImports: [ExtractedImportDirective]
    ) {
        self.tiles = tiles
        self.couplingArcs = couplingArcs
        self.packageMetrics = packageMetrics
        self.dependencyCycles = dependencyCycles
        self.agentHeatOverlays = agentHeatOverlays
        self.boundaryAlerts = boundaryAlerts
        self.extractedImports = extractedImports
    }
}

// MARK: - Multi-Language Dependency Extractor, Martin Metrics, Tarjan SCC & 2.5D Isometric Engine

public struct CrossLanguageCouplingAndIsometricEngine: Sendable {
    public let declarationParser: MultiLanguageDeclarationParser
    public var tileWidthPx: Double
    public var tileDepthHeightPx: Double

    public init(
        declarationParser: MultiLanguageDeclarationParser = MultiLanguageDeclarationParser(),
        tileWidthPx: Double = 88.0,
        tileDepthHeightPx: Double = 44.0
    ) {
        self.declarationParser = declarationParser
        self.tileWidthPx = max(24.0, tileWidthPx)
        self.tileDepthHeightPx = max(12.0, tileDepthHeightPx)
    }

    // MARK: - 1. Multi-Language Import / Use / Include / From-Import Extractor

    public func extractImportDirectives(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lang = SourceLanguage.detect(fromPath: filePath)
        let ext = (filePath as NSString).pathExtension.lowercased()

        // Also support C/C++/ObjC `#include` headers even if `SourceLanguage.detect` classifies `.h`/`.cpp` as `.plainText`
        let cFamilyExts: Set<String> = ["c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm"]
        if cFamilyExts.contains(ext) {
            return extractCPreprocessorIncludes(filePath: filePath, source: source)
        }

        switch lang {
        case .swift:
            return extractSwiftImports(filePath: filePath, source: source)
        case .python:
            return extractPythonImports(filePath: filePath, source: source)
        case .typeScript:
            return extractTypeScriptAndJSImports(filePath: filePath, source: source)
        case .rust:
            return extractRustUsesAndMods(filePath: filePath, source: source)
        case .go:
            return extractGoImports(filePath: filePath, source: source)
        case .json, .markdown, .plainText:
            if source.contains("#include") {
                return extractCPreprocessorIncludes(filePath: filePath, source: source)
            }
            return []
        }
    }

    private func extractSwiftImports(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lines = Self.stripBlockCommentsPreservingNewlines(source).components(separatedBy: "\n")
        let pattern = #"^(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_.]*)"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }

        var out: [ExtractedImportDirective] = []
        for (idx, rawLine) in lines.enumerated() {
            let clean = Self.stripLineComment(rawLine, marker: "//").trimmingCharacters(in: .whitespaces)
            guard clean.contains("import ") else { continue }
            let ns = clean as NSString
            if let m = rx.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 {
                let fullSpec = ns.substring(with: m.range(at: 1))
                let parts = fullSpec.split(separator: ".").map(String.init)
                let rootMod = parts.first ?? fullSpec
                let subSym = parts.count > 1 ? Array(parts.dropFirst()) : []
                out.append(
                    ExtractedImportDirective(
                        sourceFilePath: filePath,
                        lineNumber: idx + 1,
                        syntaxKind: .swiftImport,
                        moduleSpecifier: rootMod,
                        importedSymbols: subSym,
                        isRelativeImport: false
                    )
                )
            }
        }
        return out
    }

    private func extractPythonImports(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lines = source.components(separatedBy: "\n")
        var out: [ExtractedImportDirective] = []

        for (idx, rawLine) in lines.enumerated() {
            let clean = Self.stripLineComment(rawLine, marker: "#").trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }

            // `from ..pkg.mod import A, B` or `from . import utils`
            if clean.hasPrefix("from ") {
                let rest = String(clean.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let impRange = rest.range(of: " import ") {
                    let moduleSpec = String(rest[..<impRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let symPart = String(rest[impRange.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "() \\"))
                    let symbols = symPart
                        .split(separator: ",")
                        .map { $0.split(separator: " ").first.map(String.init) ?? "" }
                        .filter { !$0.isEmpty }
                    out.append(
                        ExtractedImportDirective(
                            sourceFilePath: filePath,
                            lineNumber: idx + 1,
                            syntaxKind: .pythonFromImport,
                            moduleSpecifier: moduleSpec,
                            importedSymbols: symbols,
                            isRelativeImport: moduleSpec.hasPrefix(".")
                        )
                    )
                }
                continue
            }

            // `import os, pkg.sub as ps`
            if clean.hasPrefix("import ") {
                let rest = String(clean.dropFirst(7))
                for clause in rest.split(separator: ",") {
                    let token = clause.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ")
                        .first
                        .map(String.init) ?? ""
                    if !token.isEmpty {
                        out.append(
                            ExtractedImportDirective(
                                sourceFilePath: filePath,
                                lineNumber: idx + 1,
                                syntaxKind: .pythonImport,
                                moduleSpecifier: token,
                                isRelativeImport: token.hasPrefix(".")
                            )
                        )
                    }
                }
            }
        }
        return out
    }

    private func extractTypeScriptAndJSImports(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lines = Self.stripBlockCommentsPreservingNewlines(source).components(separatedBy: "\n")
        let esmFromPattern = #"\b(?:import|export)\s+(?:type\s+)?(?:(.+?)\s+from\s+)?['\"]([^'\"]+)['\"]"#
        let dynamicOrRequirePattern = #"\b(?:import|require)\s*\(\s*['\"]([^'\"]+)['\"]\s*\)"#
        let esmRx = try? NSRegularExpression(pattern: esmFromPattern)
        let dynRx = try? NSRegularExpression(pattern: dynamicOrRequirePattern)

        var out: [ExtractedImportDirective] = []

        for (idx, rawLine) in lines.enumerated() {
            let clean = Self.stripLineComment(rawLine, marker: "//").trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            let ns = clean as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            if let matches = esmRx?.matches(in: clean, range: fullRange) {
                for m in matches where m.numberOfRanges >= 3 && m.range(at: 2).location != NSNotFound {
                    let spec = ns.substring(with: m.range(at: 2))
                    var syms: [String] = []
                    if m.range(at: 1).location != NSNotFound {
                        let clause = ns.substring(with: m.range(at: 1))
                        syms = Self.parseBracedSymbolNames(clause)
                    }
                    out.append(
                        ExtractedImportDirective(
                            sourceFilePath: filePath,
                            lineNumber: idx + 1,
                            syntaxKind: .esmImportOrReexport,
                            moduleSpecifier: spec,
                            importedSymbols: syms,
                            isRelativeImport: spec.hasPrefix(".") || spec.hasPrefix("/")
                        )
                    )
                }
            }

            if let dynMatches = dynRx?.matches(in: clean, range: fullRange) {
                for m in dynMatches where m.numberOfRanges >= 2 {
                    let spec = ns.substring(with: m.range(at: 1))
                    let isReq = ns.substring(with: m.range).hasPrefix("require")
                    out.append(
                        ExtractedImportDirective(
                            sourceFilePath: filePath,
                            lineNumber: idx + 1,
                            syntaxKind: isReq ? .commonJSRequire : .esmImportOrReexport,
                            moduleSpecifier: spec,
                            isRelativeImport: spec.hasPrefix(".") || spec.hasPrefix("/")
                        )
                    )
                }
            }
        }
        return out
    }

    private func extractRustUsesAndMods(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lines = Self.stripBlockCommentsPreservingNewlines(source).components(separatedBy: "\n")
        let usePattern = #"^(?:pub(?:\([^)]*\))?\s+)?use\s+([^;]+);"#
        let modPattern = #"^(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_][A-Za-z0-9_]*)\s*;"#
        let useRx = try? NSRegularExpression(pattern: usePattern)
        let modRx = try? NSRegularExpression(pattern: modPattern)

        var out: [ExtractedImportDirective] = []
        for (idx, rawLine) in lines.enumerated() {
            let clean = Self.stripLineComment(rawLine, marker: "//").trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            let ns = clean as NSString
            let range = NSRange(location: 0, length: ns.length)

            if let m = useRx?.firstMatch(in: clean, range: range), m.numberOfRanges >= 2 {
                let rawTree = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let basePath = rawTree.components(separatedBy: "{").first?.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) ?? rawTree
                let syms = Self.parseBracedSymbolNames(rawTree)
                let isRel = basePath.hasPrefix("crate") || basePath.hasPrefix("self") || basePath.hasPrefix("super")
                out.append(
                    ExtractedImportDirective(
                        sourceFilePath: filePath,
                        lineNumber: idx + 1,
                        syntaxKind: .rustUseOrMod,
                        moduleSpecifier: basePath,
                        importedSymbols: syms,
                        isRelativeImport: isRel
                    )
                )
            } else if let m = modRx?.firstMatch(in: clean, range: range), m.numberOfRanges >= 2 {
                let submod = ns.substring(with: m.range(at: 1))
                out.append(
                    ExtractedImportDirective(
                        sourceFilePath: filePath,
                        lineNumber: idx + 1,
                        syntaxKind: .rustUseOrMod,
                        moduleSpecifier: "self::\(submod)",
                        isRelativeImport: true
                    )
                )
            }
        }
        return out
    }

    private func extractGoImports(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lines = Self.stripBlockCommentsPreservingNewlines(source).components(separatedBy: "\n")
        let quotedPattern = #"\"([^\"]+)\""#
        let quotedRx = try? NSRegularExpression(pattern: quotedPattern)

        var out: [ExtractedImportDirective] = []
        var insideImportParen = false

        for (idx, rawLine) in lines.enumerated() {
            let clean = Self.stripLineComment(rawLine, marker: "//").trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }

            if !insideImportParen {
                if clean.hasPrefix("import (") || clean == "import(" {
                    insideImportParen = true
                    continue
                }
                if clean.hasPrefix("import ") {
                    let ns = clean as NSString
                    if let m = quotedRx?.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 {
                        let pkg = ns.substring(with: m.range(at: 1))
                        out.append(
                            ExtractedImportDirective(
                                sourceFilePath: filePath,
                                lineNumber: idx + 1,
                                syntaxKind: .goPackageImport,
                                moduleSpecifier: pkg,
                                isRelativeImport: pkg.hasPrefix(".")
                            )
                        )
                    }
                }
            } else {
                if clean.hasPrefix(")") {
                    insideImportParen = false
                    continue
                }
                let ns = clean as NSString
                if let m = quotedRx?.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 {
                    let pkg = ns.substring(with: m.range(at: 1))
                    out.append(
                        ExtractedImportDirective(
                            sourceFilePath: filePath,
                            lineNumber: idx + 1,
                            syntaxKind: .goPackageImport,
                            moduleSpecifier: pkg,
                            isRelativeImport: pkg.hasPrefix(".")
                        )
                    )
                }
            }
        }
        return out
    }

    private func extractCPreprocessorIncludes(filePath: String, source: String) -> [ExtractedImportDirective] {
        let lines = Self.stripBlockCommentsPreservingNewlines(source).components(separatedBy: "\n")
        let pattern = #"^\s*#\s*(?:include|import)\s*([<\"])([^>\"]+)[>\"]"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }

        var out: [ExtractedImportDirective] = []
        for (idx, rawLine) in lines.enumerated() {
            let clean = Self.stripLineComment(rawLine, marker: "//")
            let ns = clean as NSString
            if let m = rx.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 {
                let delim = ns.substring(with: m.range(at: 1))
                let headerPath = ns.substring(with: m.range(at: 2))
                out.append(
                    ExtractedImportDirective(
                        sourceFilePath: filePath,
                        lineNumber: idx + 1,
                        syntaxKind: .cPreprocessorInclude,
                        moduleSpecifier: headerPath,
                        isRelativeImport: delim == "\""
                    )
                )
            }
        }
        return out
    }

    // MARK: - 2. Tarjan Strongly-Connected-Component (`SCC`) Cycle Finder

    public func computeTarjanDependencyCycles(
        adjacency: [String: Set<String>],
        laneOwnerByNode: [String: Set<String>] = [:]
    ) -> [StronglyConnectedDependencyCycle] {
        let allNodes = Set(adjacency.keys).union(adjacency.values.flatMap { $0 }).sorted()
        var indexCounter = 0
        var discoveryIndex: [String: Int] = [:]
        var lowLink: [String: Int] = [:]
        var stack: [String] = []
        var onStack = Set<String>()
        var rawSCCs: [[String]] = []

        func strongConnect(_ v: String) {
            discoveryIndex[v] = indexCounter
            lowLink[v] = indexCounter
            indexCounter += 1
            stack.append(v)
            onStack.insert(v)

            let neighbors = (adjacency[v] ?? []).sorted()
            for w in neighbors {
                if discoveryIndex[w] == nil {
                    strongConnect(w)
                    lowLink[v] = min(lowLink[v]!, lowLink[w]!)
                } else if onStack.contains(w) {
                    lowLink[v] = min(lowLink[v]!, discoveryIndex[w]!)
                }
            }

            if lowLink[v] == discoveryIndex[v] {
                var component: [String] = []
                while let popped = stack.popLast() {
                    onStack.remove(popped)
                    component.append(popped)
                    if popped == v { break }
                }
                rawSCCs.append(component.sorted())
            }
        }

        for node in allNodes where discoveryIndex[node] == nil {
            strongConnect(node)
        }

        var cycles: [StronglyConnectedDependencyCycle] = []
        for scc in rawSCCs {
            let isNonTrivialCycle = scc.count > 1 || (scc.count == 1 && (adjacency[scc[0]]?.contains(scc[0]) == true))
            guard isNonTrivialCycle else { continue }

            let witness = Self.reconstructShortestCycleWitness(inSCC: Set(scc), startNode: scc[0], adjacency: adjacency)
            var lanesInvolved = Set<String>()
            for member in scc {
                lanesInvolved.formUnion(laneOwnerByNode[member] ?? [])
            }
            cycles.append(
                StronglyConnectedDependencyCycle(
                    memberNodes: scc,
                    witnessCyclePath: witness,
                    spansMultipleAgentLanes: lanesInvolved.count > 1
                )
            )
        }

        return cycles.sorted { $0.memberNodes.first ?? "" < $1.memberNodes.first ?? "" }
    }

    // MARK: - 3. Complete Workspace Analysis & 2.5D Isometric Territory Scene Synthesis

    public func buildIsometricCityScene(
        workspaceFiles: [String: String],
        agentActivities: [AgentTerritoryActivityInput] = [],
        conflictedPaths: Set<String> = []
    ) -> IsometricCityTopologyScene {
        let sortedPaths = workspaceFiles.keys.sorted()
        let pathSet = Set(sortedPaths)

        var packageByPath: [String: String] = [:]
        var filesByPackage: [String: [String]] = [:]
        var declsByPath: [String: [ASTDeclarationNode]] = [:]
        var symbolOwnerPath: [String: String] = [:]
        var allImports: [ExtractedImportDirective] = []

        for path in sortedPaths {
            let pkg = Self.inferPackageDistrict(fromRelativePath: path)
            packageByPath[path] = pkg
            filesByPackage[pkg, default: []].append(path)

            let src = workspaceFiles[path] ?? ""
            let lang = SourceLanguage.detect(fromPath: path)
            let nodes = declarationParser.parseDeclarations(source: src, language: lang)
            declsByPath[path] = nodes

            for node in nodes where node.kind != .importGroup {
                symbolOwnerPath[node.symbolName] = path
                for child in node.children {
                    symbolOwnerPath[child.symbolName] = path
                }
            }

            allImports.append(contentsOf: extractImportDirectives(filePath: path, source: src))
        }

        // Build file-level and package-level directed coupling graphs (from both explicit imports AND AST cross-file symbol calls)
        var fileEdgeWeight: [String: [String: Int]] = [:]
        var fileAdjacency: [String: Set<String>] = [:]
        var pkgAdjacency: [String: Set<String>] = [:]

        // A) Resolve multi-language import directives to workspace files / packages
        for imp in allImports {
            let resolvedTargets = Self.resolveImportTargets(
                directive: imp,
                allPaths: pathSet,
                filesByPackage: filesByPackage
            )
            let srcPkg = packageByPath[imp.sourceFilePath] ?? "Root"
            for dstPath in resolvedTargets where dstPath != imp.sourceFilePath {
                fileEdgeWeight[imp.sourceFilePath, default: [:]][dstPath, default: 0] += 2
                fileAdjacency[imp.sourceFilePath, default: []].insert(dstPath)
                let dstPkg = packageByPath[dstPath] ?? "Root"
                if dstPkg != srcPkg {
                    pkgAdjacency[srcPkg, default: []].insert(dstPkg)
                }
            }
        }

        // B) Augment with cross-file AST symbol reference edges
        for path in sortedPaths {
            let srcPkg = packageByPath[path] ?? "Root"
            let nodes = declsByPath[path] ?? []
            var referenced = Set<String>()
            for n in nodes {
                referenced.formUnion(n.referencedSymbols)
                for c in n.children { referenced.formUnion(c.referencedSymbols) }
            }
            for sym in referenced {
                if let dstPath = symbolOwnerPath[sym], dstPath != path {
                    fileEdgeWeight[path, default: [:]][dstPath, default: 0] += 1
                    fileAdjacency[path, default: []].insert(dstPath)
                    let dstPkg = packageByPath[dstPath] ?? "Root"
                    if dstPkg != srcPkg {
                        pkgAdjacency[srcPkg, default: []].insert(dstPkg)
                    }
                }
            }
        }

        // Compute file-level Ca / Ce
        var fileCa: [String: Int] = [:]
        var fileCe: [String: Int] = [:]
        for (src, targets) in fileAdjacency {
            fileCe[src] = targets.count
            for dst in targets {
                fileCa[dst, default: 0] += 1
            }
        }

        // Compute Robert C. Martin Package Coupling Metrics (`Ca`, `Ce`, `I`, `A`, `D`)
        var pkgCaSet: [String: Set<String>] = [:]
        var pkgCeSet: [String: Set<String>] = [:]
        for (srcPkg, dstPkgs) in pkgAdjacency {
            for dstPkg in dstPkgs where dstPkg != srcPkg {
                pkgCeSet[srcPkg, default: []].insert(dstPkg)
                pkgCaSet[dstPkg, default: []].insert(srcPkg)
            }
        }

        var packageMetricsList: [MartinPackageCouplingMetrics] = []
        var pkgMetricsByName: [String: MartinPackageCouplingMetrics] = [:]
        for pkgName in filesByPackage.keys.sorted() {
            let pkgFiles = filesByPackage[pkgName] ?? []
            var abstractTypes = 0
            var concreteTypes = 0
            for fp in pkgFiles {
                let src = workspaceFiles[fp] ?? ""
                for node in (declsByPath[fp] ?? []) {
                    switch node.kind {
                    case .protocolOrInterface:
                        abstractTypes += 1
                    case .classDecl:
                        if src.contains("abstract class \(node.symbolName)") || src.contains("(ABC)") || src.contains("(Protocol)") {
                            abstractTypes += 1
                        } else {
                            concreteTypes += 1
                        }
                    case .structDecl, .enumDecl:
                        concreteTypes += 1
                    default:
                        break
                    }
                }
            }

            let m = MartinPackageCouplingMetrics(
                packageName: pkgName,
                filePaths: pkgFiles,
                afferentCoupling: pkgCaSet[pkgName]?.count ?? 0,
                efferentCoupling: pkgCeSet[pkgName]?.count ?? 0,
                abstractTypeCount: abstractTypes,
                concreteTypeCount: concreteTypes
            )
            packageMetricsList.append(m)
            pkgMetricsByName[pkgName] = m
        }

        // Map live agent lane ownership & churn per file
        var lanesTouchingPath: [String: [(laneID: String, vendor: AgentVendor, churn: Int)]] = [:]
        for act in agentActivities {
            for (relPath, churn) in act.dirtyChurnByPath {
                lanesTouchingPath[relPath, default: []].append((act.laneID, act.vendor, max(1, churn)))
            }
        }
        var laneIDSetByPath: [String: Set<String>] = [:]
        for (p, entries) in lanesTouchingPath {
            laneIDSetByPath[p] = Set(entries.map(\.laneID))
        }

        // Detect Tarjan SCC dependency cycles across files
        let sccCycles = computeTarjanDependencyCycles(adjacency: fileAdjacency, laneOwnerByNode: laneIDSetByPath)
        let cyclicFileSet = Set(sccCycles.flatMap(\.memberNodes))

        // Order tiles by `(packageDistrict, relativePath)` so packages cluster into adjacent isometric city blocks!
        let districtOrderedPaths = sortedPaths.sorted { lhs, rhs in
            let pL = packageByPath[lhs] ?? ""
            let pR = packageByPath[rhs] ?? ""
            if pL != pR { return pL < pR }
            return lhs < rhs
        }

        let gridCols = max(1, Int(Double(max(1, districtOrderedPaths.count)).squareRoot().rounded(.up)))
        var tiles: [IsometricModuleTile] = []
        var tileByPath: [String: IsometricModuleTile] = [:]

        for (idx, path) in districtOrderedPaths.enumerated() {
            let col = idx % gridCols
            let row = idx / gridCols
            let src = workspaceFiles[path] ?? ""
            let lineCount = max(1, src.components(separatedBy: "\n").count)
            let nodes = declsByPath[path] ?? []
            let declCount = nodes.filter { $0.kind != .importGroup }.count
            let pkg = packageByPath[path] ?? "Root"

            // Extrusion height combines logarithmic LOC scale + declaration count
            let heightPx = min(180.0, 14.0 + log2(Double(lineCount) + 1.0) * 11.5 + Double(declCount) * 2.2)

            let geometry = projectIsometricTile(gridCol: col, gridRow: row, extrusionHeight: heightPx)

            let ca = fileCa[path, default: 0]
            let ce = fileCe[path, default: 0]
            let fileInstability = (ca + ce) == 0 ? 0.0 : Double(ce) / Double(ca + ce)
            let abstractDecls = nodes.filter { $0.kind == .protocolOrInterface }.count
            let typeDecls = nodes.filter { [.protocolOrInterface, .structDecl, .classDecl, .enumDecl].contains($0.kind) }.count
            let fileAbstractness = typeDecls == 0 ? (pkgMetricsByName[pkg]?.abstractness ?? 0.0) : Double(abstractDecls) / Double(typeDecls)
            let fileD = abs(fileAbstractness + fileInstability - 1.0)

            let touchers = (lanesTouchingPath[path] ?? []).sorted { $0.churn > $1.churn }
            let primary = touchers.first
            let contending = touchers.map(\.laneID)
            let totalChurn = touchers.reduce(0) { $0 + $1.churn }

            let couplingComponent = min(0.55, Double(ca * 2 + ce) / 24.0)
            let churnComponent = min(0.65, Double(totalChurn) / 120.0)
            let conflictBoost = (conflictedPaths.contains(path) || touchers.count > 1) ? 0.35 : 0.0
            let heat = min(1.0, couplingComponent + churnComponent + conflictBoost)

            let tile = IsometricModuleTile(
                relativePath: path,
                packageDistrict: pkg,
                language: SourceLanguage.detect(fromPath: path),
                lineCount: lineCount,
                declarationCount: declCount,
                gridColumn: col,
                gridRow: row,
                extrusionHeightPx: heightPx,
                screenCenter: geometry.center,
                roofCenter: geometry.roofCenter,
                baseFootprint: geometry.baseQuad,
                roofFootprint: geometry.roofQuad,
                afferentCoupling: ca,
                efferentCoupling: ce,
                instability: fileInstability,
                abstractness: fileAbstractness,
                distanceFromMainSequence: fileD,
                isInDependencyCycle: cyclicFileSet.contains(path),
                primaryOwnerLaneID: primary?.laneID,
                primaryOwnerVendor: primary?.vendor,
                contendingLaneIDs: contending,
                liveHeatIntensity: heat,
                hasMergeConflict: conflictedPaths.contains(path)
            )
            tiles.append(tile)
            tileByPath[path] = tile
        }

        // Synthesize 2.5D quadratic Bézier coupling arcs & detect boundary collisions
        var arcs: [IsometricTerritoryCouplingArc] = []
        var alerts: [TerritoryBoundaryCollisionAlert] = []

        // Alert Type 1: Direct Multi-Lane Tile Overlap
        for tile in tiles where tile.contendingLaneIDs.count > 1 {
            alerts.append(
                TerritoryBoundaryCollisionAlert(
                    kind: .directMultiLaneTileOverlap,
                    severity: tile.hasMergeConflict ? .blocker : .warning,
                    involvedLaneIDs: tile.contendingLaneIDs,
                    primaryPath: tile.relativePath,
                    summary: "Lanes [\(tile.contendingLaneIDs.joined(separator: ", "))] concurrently modified '\(tile.relativePath)'."
                )
            )
        }

        for srcPath in fileEdgeWeight.keys.sorted() {
            guard let srcTile = tileByPath[srcPath],
                  let targets = fileEdgeWeight[srcPath] else { continue }

            for dstPath in targets.keys.sorted() {
                guard let dstTile = tileByPath[dstPath],
                      let weight = targets[dstPath] else { continue }

                let srcLane = srcTile.primaryOwnerLaneID
                let dstLane = dstTile.primaryOwnerLaneID
                let crossesLanes = (srcLane != nil && dstLane != nil && srcLane != dstLane)
                let bothInSameCycle = sccCycles.contains { $0.memberNodes.contains(srcPath) && $0.memberNodes.contains(dstPath) }

                // Robert C. Martin Stable Dependencies Principle (`SDP`): depend in the direction of stability (`src.I >= dst.I`)
                let violatesSDP = (srcTile.afferentCoupling >= 2)
                    && (dstTile.efferentCoupling >= 2)
                    && (srcTile.instability + 0.30 < dstTile.instability)

                let p0 = srcTile.roofCenter
                let p2 = dstTile.roofCenter
                let spanDist = hypot(p2.x - p0.x, p2.y - p0.y)
                let apexLift = 28.0 + min(110.0, spanDist * 0.24) + Double(min(8, weight)) * 3.0
                let apex = IsometricPoint2D(
                    x: (p0.x + p2.x) * 0.5,
                    y: min(p0.y, p2.y) - apexLift
                )

                arcs.append(
                    IsometricTerritoryCouplingArc(
                        sourcePath: srcPath,
                        targetPath: dstPath,
                        edgeWeight: weight,
                        crossesAgentLanes: crossesLanes,
                        isPartOfCycle: bothInSameCycle,
                        violatesStableDependenciesPrinciple: violatesSDP,
                        startRoofPoint: p0,
                        apexControlPoint: apex,
                        endRoofPoint: p2
                    )
                )

                if crossesLanes, let lA = srcLane, let lB = dstLane, weight >= 2 {
                    alerts.append(
                        TerritoryBoundaryCollisionAlert(
                            kind: .tightlyCoupledCrossLaneBorder,
                            severity: .advisory,
                            involvedLaneIDs: [lA, lB],
                            primaryPath: srcPath,
                            secondaryPath: dstPath,
                            summary: "Active cross-lane coupling (\(weight) refs) between '\(srcPath)' (\(lA)) and '\(dstPath)' (\(lB))."
                        )
                    )
                }

                if violatesSDP {
                    alerts.append(
                        TerritoryBoundaryCollisionAlert(
                            kind: .unstableDependencyIntoStableCore,
                            severity: .warning,
                            involvedLaneIDs: [srcLane, dstLane].compactMap { $0 },
                            primaryPath: srcPath,
                            secondaryPath: dstPath,
                            summary: String(
                                format: "Stable module '%@' (I=%.2f) depends on volatile module '%@' (I=%.2f).",
                                srcPath, srcTile.instability, dstPath, dstTile.instability
                            )
                        )
                    )
                }
            }
        }

        // Alert Type 3: Cross-Lane SCC Cycles
        for cycle in sccCycles where cycle.spansMultipleAgentLanes {
            let cycleLanes = Array(Set(cycle.memberNodes.flatMap { laneIDSetByPath[$0] ?? [] })).sorted()
            alerts.append(
                TerritoryBoundaryCollisionAlert(
                    kind: .crossLaneDependencyCycle,
                    severity: .blocker,
                    involvedLaneIDs: cycleLanes,
                    primaryPath: cycle.witnessCyclePath.first ?? "",
                    secondaryPath: cycle.witnessCyclePath.dropFirst().first,
                    summary: "Cross-lane dependency cycle: \(cycle.witnessCyclePath.joined(separator: " -> "))"
                )
            )
        }

        // Build per-agent territory heat overlays
        var overlays: [AgentTerritoryHeatOverlay] = []
        for act in agentActivities {
            let owned = tiles.filter { $0.primaryOwnerLaneID == act.laneID || $0.contendingLaneIDs.contains(act.laneID) }
            let ownedPaths = owned.map(\.relativePath)
            let contestedPaths = owned.filter { $0.contendingLaneIDs.count > 1 }.map(\.relativePath)
            let churnSum = act.dirtyChurnByPath.values.reduce(0, +)
            let avgHeat = owned.isEmpty ? 0.0 : owned.reduce(0.0) { $0 + $1.liveHeatIntensity } / Double(owned.count)
            let cx = owned.isEmpty ? 0.0 : owned.reduce(0.0) { $0 + $1.screenCenter.x } / Double(owned.count)
            let cy = owned.isEmpty ? 0.0 : owned.reduce(0.0) { $0 + $1.screenCenter.y } / Double(owned.count)

            overlays.append(
                AgentTerritoryHeatOverlay(
                    laneID: act.laneID,
                    vendor: act.vendor,
                    ownedTilePaths: ownedPaths,
                    contestedTilePaths: contestedPaths,
                    totalChurnLines: churnSum,
                    averageHeat: avgHeat,
                    boundingCentroid: IsometricPoint2D(x: cx, y: cy)
                )
            )
        }

        return IsometricCityTopologyScene(
            tiles: tiles,
            couplingArcs: arcs,
            packageMetrics: packageMetricsList,
            dependencyCycles: sccCycles,
            agentHeatOverlays: overlays,
            boundaryAlerts: alerts,
            extractedImports: allImports
        )
    }

    // MARK: - 2.5D Isometric Projection & Import Resolution Helpers

    private func projectIsometricTile(
        gridCol: Int,
        gridRow: Int,
        extrusionHeight: Double
    ) -> (
        center: IsometricPoint2D,
        roofCenter: IsometricPoint2D,
        baseQuad: IsometricDiamondPolygon,
        roofQuad: IsometricDiamondPolygon
    ) {
        let halfW = tileWidthPx * 0.5
        let halfH = tileDepthHeightPx * 0.5
        let cx = Double(gridCol - gridRow) * halfW
        let cy = Double(gridCol + gridRow) * halfH

        let base = IsometricDiamondPolygon(
            north: IsometricPoint2D(x: cx, y: cy - halfH),
            east:  IsometricPoint2D(x: cx + halfW, y: cy),
            south: IsometricPoint2D(x: cx, y: cy + halfH),
            west:  IsometricPoint2D(x: cx - halfW, y: cy)
        )
        let roof = IsometricDiamondPolygon(
            north: IsometricPoint2D(x: cx, y: cy - halfH - extrusionHeight),
            east:  IsometricPoint2D(x: cx + halfW, y: cy - extrusionHeight),
            south: IsometricPoint2D(x: cx, y: cy + halfH - extrusionHeight),
            west:  IsometricPoint2D(x: cx - halfW, y: cy - extrusionHeight)
        )
        return (
            IsometricPoint2D(x: cx, y: cy),
            IsometricPoint2D(x: cx, y: cy - extrusionHeight),
            base,
            roof
        )
    }

    private static func inferPackageDistrict(fromRelativePath path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3 && (parts[0] == "Sources" || parts[0] == "Tests" || parts[0] == "packages" || parts[0] == "crates" || parts[0] == "src") {
            return parts[1]
        }
        if parts.count >= 2 {
            return parts[parts.count - 2]
        }
        return "Root"
    }

    private static func resolveImportTargets(
        directive: ExtractedImportDirective,
        allPaths: Set<String>,
        filesByPackage: [String: [String]]
    ) -> [String] {
        let spec = directive.moduleSpecifier
        let srcDir = (directive.sourceFilePath as NSString).deletingLastPathComponent

        switch directive.syntaxKind {
        case .swiftImport:
            // Direct SwiftPM target match in `filesByPackage`
            if let pkgFiles = filesByPackage[spec] {
                return pkgFiles
            }
            return []

        case .esmImportOrReexport, .commonJSRequire, .cPreprocessorInclude:
            var baseCandidate: String
            if spec.hasPrefix("@/") {
                baseCandidate = "src/" + String(spec.dropFirst(2))
            } else if directive.isRelativeImport {
                baseCandidate = normalizeRelativePath(baseDir: srcDir, relSpec: spec)
            } else {
                if let pkgFiles = filesByPackage[spec] { return pkgFiles }
                baseCandidate = spec
            }
            let tryExts = ["", ".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.tsx", "/index.js", ".h", ".hpp"]
            for ext in tryExts {
                let cand = baseCandidate + ext
                if allPaths.contains(cand) { return [cand] }
            }
            return []

        case .pythonImport, .pythonFromImport:
            var dotDepth = 0
            for ch in spec {
                if ch == "." { dotDepth += 1 } else { break }
            }
            let tailDots = String(spec.dropFirst(dotDepth)).replacingOccurrences(of: ".", with: "/")
            let resolvedPrefix: String
            if dotDepth > 0 {
                var upDir = srcDir
                for _ in 1..<dotDepth {
                    upDir = (upDir as NSString).deletingLastPathComponent
                }
                resolvedPrefix = tailDots.isEmpty ? upDir : (upDir.isEmpty ? tailDots : "\(upDir)/\(tailDots)")
            } else {
                resolvedPrefix = tailDots
            }
            var hits: [String] = []
            for ext in [".py", ".pyi", "/__init__.py"] {
                let cand = resolvedPrefix + ext
                if allPaths.contains(cand) { hits.append(cand) }
            }
            for sym in directive.importedSymbols {
                let symMod = resolvedPrefix.isEmpty ? "\(sym).py" : "\(resolvedPrefix)/\(sym).py"
                if allPaths.contains(symMod) { hits.append(symMod) }
            }
            return hits

        case .rustUseOrMod:
            let parts = spec.components(separatedBy: "::").filter { !$0.isEmpty }
            guard !parts.isEmpty else { return [] }
            var dirAnchor = srcDir
            var startIdx = 0
            if parts[0] == "crate" {
                dirAnchor = srcDir.hasPrefix("src") ? "src" : ""
                startIdx = 1
            } else if parts[0] == "self" {
                startIdx = 1
            } else if parts[0] == "super" {
                while startIdx < parts.count && parts[startIdx] == "super" {
                    dirAnchor = (dirAnchor as NSString).deletingLastPathComponent
                    startIdx += 1
                }
            }
            let relSegs = parts[startIdx...].joined(separator: "/")
            let prefix = dirAnchor.isEmpty ? relSegs : (relSegs.isEmpty ? dirAnchor : "\(dirAnchor)/\(relSegs)")
            for cand in ["\(prefix).rs", "\(prefix)/mod.rs", "\((prefix as NSString).deletingLastPathComponent).rs"] where allPaths.contains(cand) {
                return [cand]
            }
            return []

        case .goPackageImport:
            let lastSeg = spec.split(separator: "/").last.map(String.init) ?? spec
            if let pkgFiles = filesByPackage[lastSeg] {
                return pkgFiles
            }
            return allPaths.filter { ($0 as NSString).deletingLastPathComponent.hasSuffix(spec) }
        }
    }

    private static func normalizeRelativePath(baseDir: String, relSpec: String) -> String {
        let combined = baseDir.isEmpty ? relSpec : "\(baseDir)/\(relSpec)"
        var stack: [String] = []
        for comp in combined.split(separator: "/") {
            if comp == "." || comp.isEmpty { continue }
            if comp == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(comp))
            }
        }
        return stack.joined(separator: "/")
    }

    private static func reconstructShortestCycleWitness(
        inSCC scc: Set<String>,
        startNode: String,
        adjacency: [String: Set<String>]
    ) -> [String] {
        if adjacency[startNode]?.contains(startNode) == true {
            return [startNode, startNode]
        }
        var parentMap: [String: String] = [:]
        var visited: Set<String> = []
        var queue: [String] = []

        for firstHop in (adjacency[startNode] ?? []).sorted() where scc.contains(firstHop) {
            visited.insert(firstHop)
            parentMap[firstHop] = startNode
            queue.append(firstHop)
        }

        var head = 0
        while head < queue.count {
            let cur = queue[head]
            head += 1
            let neighbors = (adjacency[cur] ?? []).sorted()
            if neighbors.contains(startNode) {
                var pathReversed: [String] = [startNode, cur]
                var walk = cur
                while let p = parentMap[walk], p != startNode {
                    pathReversed.append(p)
                    walk = p
                }
                pathReversed.append(startNode)
                return pathReversed.reversed()
            }
            for nxt in neighbors where scc.contains(nxt) && visited.insert(nxt).inserted {
                parentMap[nxt] = cur
                queue.append(nxt)
            }
        }
        return Array(scc).sorted() + [startNode]
    }

    private static func stripBlockCommentsPreservingNewlines(_ source: String) -> String {
        let chars = Array(source)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        var inBlock = false

        while i < chars.count {
            if !inBlock && chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                inBlock = true
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            }
            if inBlock {
                if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                    inBlock = false
                    out.append(" ")
                    out.append(" ")
                    i += 2
                } else {
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func stripLineComment(_ line: String, marker: String) -> String {
        guard line.contains(marker) else { return line }
        let chars = Array(line)
        let mChars = Array(marker)
        var inSingle = false
        var inDouble = false
        var escaped = false

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if c == "\\" && (inSingle || inDouble) {
                escaped = true
                i += 1
                continue
            }
            if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == "'" && !inDouble { inSingle.toggle() }
            else if !inSingle && !inDouble && i + mChars.count <= chars.count {
                if Array(chars[i..<(i + mChars.count)]) == mChars {
                    return String(chars[0..<i])
                }
            }
            i += 1
        }
        return line
    }

    private static func parseBracedSymbolNames(_ clause: String) -> [String] {
        guard let open = clause.firstIndex(of: "{"),
              let close = clause[open...].firstIndex(of: "}") else {
            let trimmed = clause.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.contains("*") {
                return [trimmed]
            }
            return []
        }
        let body = clause[clause.index(after: open)..<close]
        return body
            .split(separator: ",")
            .compactMap { part in
                let cleaned = part
                    .replacingOccurrences(of: "type ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return cleaned.split(separator: " ").first.map(String.init)
            }
            .filter { !$0.isEmpty }
    }
}
