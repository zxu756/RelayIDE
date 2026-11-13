import Dispatch
import Foundation
import RelayModels

// MARK: - Multiplexer Geometry & Tiling Split-Tree Primitives

public enum PTYSplitAxis: String, Sendable, Codable, Hashable, CaseIterable {
    /// Splits left and right columns side-by-side (`|`).
    case horizontal
    /// Splits top and bottom rows stacked (`—`).
    case vertical

    public var perpendicular: PTYSplitAxis {
        self == .horizontal ? .vertical : .horizontal
    }
}

public enum PTYFocusDirection: String, Sendable, Codable, Hashable, CaseIterable {
    case left
    case right
    case up
    case down
}

public struct PTYMultiplexerRect: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0.0, width)
        self.height = max(0.0, height)
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width * 0.5 }
    public var midY: Double { y + height * 0.5 }

    public func insetBy(dx: Double, dy: Double) -> PTYMultiplexerRect {
        PTYMultiplexerRect(
            x: x + dx,
            y: y + dy,
            width: max(0.0, width - dx * 2.0),
            height: max(0.0, height - dy * 2.0)
        )
    }

    public func split(
        along axis: PTYSplitAxis,
        ratio: Double,
        dividerThickness: Double
    ) -> (first: PTYMultiplexerRect, divider: PTYMultiplexerRect, second: PTYMultiplexerRect) {
        let clampedRatio = min(0.90, max(0.10, ratio))
        let div = max(0.0, dividerThickness)

        switch axis {
        case .horizontal:
            let usableW = max(0.0, width - div)
            let firstW = (usableW * clampedRatio).rounded(.towardZero)
            let secondW = max(0.0, usableW - firstW)
            let r1 = PTYMultiplexerRect(x: x, y: y, width: firstW, height: height)
            let rDiv = PTYMultiplexerRect(x: x + firstW, y: y, width: div, height: height)
            let r2 = PTYMultiplexerRect(x: x + firstW + div, y: y, width: secondW, height: height)
            return (r1, rDiv, r2)

        case .vertical:
            let usableH = max(0.0, height - div)
            let firstH = (usableH * clampedRatio).rounded(.towardZero)
            let secondH = max(0.0, usableH - firstH)
            let r1 = PTYMultiplexerRect(x: x, y: y, width: width, height: firstH)
            let rDiv = PTYMultiplexerRect(x: x, y: y + firstH, width: width, height: div)
            let r2 = PTYMultiplexerRect(x: x, y: y + firstH + div, width: width, height: secondH)
            return (r1, rDiv, r2)
        }
    }
}

public struct PTYPaneDescriptor: Sendable, Codable, Hashable, Identifiable {
    public var id: String { paneID }
    public let paneID: String
    public var laneID: String
    public var vendor: AgentVendor?
    public var title: String
    public var isReadOnlyVerifier: Bool
    public var minimumColumns: Int
    public var minimumRows: Int

    public init(
        paneID: String,
        laneID: String,
        vendor: AgentVendor? = nil,
        title: String = "",
        isReadOnlyVerifier: Bool = false,
        minimumColumns: Int = 20,
        minimumRows: Int = 5
    ) {
        self.paneID = paneID
        self.laneID = laneID
        self.vendor = vendor
        self.title = title.isEmpty ? laneID : title
        self.isReadOnlyVerifier = isReadOnlyVerifier
        self.minimumColumns = max(12, minimumColumns)
        self.minimumRows = max(4, minimumRows)
    }
}

public indirect enum PTYBinarySplitNode: Sendable, Codable, Hashable {
    case leaf(PTYPaneDescriptor)
    case split(
        splitID: String,
        axis: PTYSplitAxis,
        ratio: Double,
        first: PTYBinarySplitNode,
        second: PTYBinarySplitNode
    )

    public var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, _, _, let first, let second):
            return first.leafCount + second.leafCount
        }
    }

    public func allLeaves() -> [PTYPaneDescriptor] {
        switch self {
        case .leaf(let desc):
            return [desc]
        case .split(_, _, _, let first, let second):
            return first.allLeaves() + second.allLeaves()
        }
    }

    public func containsPane(_ paneID: String) -> Bool {
        switch self {
        case .leaf(let desc):
            return desc.paneID == paneID
        case .split(_, _, _, let first, let second):
            return first.containsPane(paneID) || second.containsPane(paneID)
        }
    }

    public func findPane(_ paneID: String) -> PTYPaneDescriptor? {
        switch self {
        case .leaf(let desc):
            return desc.paneID == paneID ? desc : nil
        case .split(_, _, _, let first, let second):
            return first.findPane(paneID) ?? second.findPane(paneID)
        }
    }
}

// MARK: - Solved Multiplexer Layout Output

public struct PTYSolvedPaneFrame: Sendable, Codable, Hashable, Identifiable {
    public var id: String { pane.paneID }
    public let pane: PTYPaneDescriptor
    public let outerFrame: PTYMultiplexerRect
    public let contentFrame: PTYMultiplexerRect
    public let columns: Int
    public let rows: Int
    public let isFocused: Bool
    public let isZoomed: Bool
    public let isHiddenByZoom: Bool

    public init(
        pane: PTYPaneDescriptor,
        outerFrame: PTYMultiplexerRect,
        contentFrame: PTYMultiplexerRect,
        columns: Int,
        rows: Int,
        isFocused: Bool,
        isZoomed: Bool,
        isHiddenByZoom: Bool
    ) {
        self.pane = pane
        self.outerFrame = outerFrame
        self.contentFrame = contentFrame
        self.columns = columns
        self.rows = rows
        self.isFocused = isFocused
        self.isZoomed = isZoomed
        self.isHiddenByZoom = isHiddenByZoom
    }
}

public struct PTYSolvedSplitDivider: Sendable, Codable, Hashable, Identifiable {
    public var id: String { splitID }
    public let splitID: String
    public let axis: PTYSplitAxis
    public let frame: PTYMultiplexerRect
    public let ratio: Double
    public let parentSpanAlongAxis: Double

    public init(
        splitID: String,
        axis: PTYSplitAxis,
        frame: PTYMultiplexerRect,
        ratio: Double,
        parentSpanAlongAxis: Double
    ) {
        self.splitID = splitID
        self.axis = axis
        self.frame = frame
        self.ratio = ratio
        self.parentSpanAlongAxis = parentSpanAlongAxis
    }

    /// Computes the updated split ratio resulting from dragging this divider by `deltaPixels` along its split axis.
    public func ratioAfterDragging(deltaPixels: Double) -> Double {
        guard parentSpanAlongAxis > 1.0 else { return ratio }
        return min(0.90, max(0.10, ratio + (deltaPixels / parentSpanAlongAxis)))
    }
}

public struct PTYSolvedMultiplexerLayout: Sendable, Codable, Hashable {
    public let viewport: PTYMultiplexerRect
    public let panes: [PTYSolvedPaneFrame]
    public let dividers: [PTYSolvedSplitDivider]
    public let zoomedPaneID: String?

    public init(
        viewport: PTYMultiplexerRect,
        panes: [PTYSolvedPaneFrame],
        dividers: [PTYSolvedSplitDivider],
        zoomedPaneID: String?
    ) {
        self.viewport = viewport
        self.panes = panes
        self.dividers = dividers
        self.zoomedPaneID = zoomedPaneID
    }

    public var visiblePanes: [PTYSolvedPaneFrame] {
        panes.filter { !$0.isHiddenByZoom }
    }
}

// MARK: - Multi-Agent Tiling Presets (`2x2` Quad, `3x2` Matrix, `1+3` Lead-Conductor)

public enum PTYMultiplexerPreset: String, Sendable, Codable, Hashable, CaseIterable {
    case singleFocus = "1x1 Single Focus"
    case sideBySide = "1x2 Side-by-Side"
    case quadGrid2x2 = "2x2 Quad Grid"
    case matrix3x2 = "3x2 Agent Matrix"
    case leadConductor1Plus3 = "1+3 Lead-Conductor"
}

// MARK: - Binary Split-Tree Tiling Multiplexer Engine

public struct PTYBinarySplitTree: Sendable, Codable, Hashable {
    public static let minSplitRatio: Double = 0.10
    public static let maxSplitRatio: Double = 0.90

    public private(set) var root: PTYBinarySplitNode?
    public private(set) var focusedPaneID: String?
    public private(set) var zoomedPaneID: String?
    private var nextSplitCounter: Int = 1

    public init(root: PTYBinarySplitNode? = nil, focusedPaneID: String? = nil) {
        self.root = root
        let firstLeafID = root?.allLeaves().first?.paneID
        if let f = focusedPaneID, root?.containsPane(f) == true {
            self.focusedPaneID = f
        } else {
            self.focusedPaneID = firstLeafID
        }
        self.zoomedPaneID = nil
    }

    public var panes: [PTYPaneDescriptor] {
        root?.allLeaves() ?? []
    }

    public var paneCount: Int {
        root?.leafCount ?? 0
    }

    // MARK: - Preset Construction

    public static func makePreset(
        _ preset: PTYMultiplexerPreset,
        panes suppliedPanes: [PTYPaneDescriptor]
    ) -> PTYBinarySplitTree {
        let requiredCount: Int
        switch preset {
        case .singleFocus:         requiredCount = 1
        case .sideBySide:          requiredCount = 2
        case .quadGrid2x2:         requiredCount = 4
        case .matrix3x2:           requiredCount = 6
        case .leadConductor1Plus3: requiredCount = 4
        }

        var normalized = suppliedPanes
        let defaultVendors: [AgentVendor] = [.claudeCode, .codex, .antigravity, .mistralVibe, .customShell, .claudeCode]
        while normalized.count < requiredCount {
            let idx = normalized.count
            let vendor = defaultVendors[idx % defaultVendors.count]
            normalized.append(
                PTYPaneDescriptor(
                    paneID: "pane-\(idx + 1)",
                    laneID: "lane-\(vendor.rawValue)-\(idx + 1)",
                    vendor: vendor,
                    title: "\(vendor.displayName) #\(idx + 1)",
                    isReadOnlyVerifier: vendor == .customShell
                )
            )
        }

        let p = Array(normalized.prefix(requiredCount))
        let rootNode: PTYBinarySplitNode

        switch preset {
        case .singleFocus:
            rootNode = .leaf(p[0])

        case .sideBySide:
            rootNode = .split(
                splitID: "preset-h-root",
                axis: .horizontal,
                ratio: 0.50,
                first: .leaf(p[0]),
                second: .leaf(p[1])
            )

        case .quadGrid2x2:
            let topRow = PTYBinarySplitNode.split(
                splitID: "preset-2x2-top",
                axis: .horizontal,
                ratio: 0.50,
                first: .leaf(p[0]),
                second: .leaf(p[1])
            )
            let bottomRow = PTYBinarySplitNode.split(
                splitID: "preset-2x2-bottom",
                axis: .horizontal,
                ratio: 0.50,
                first: .leaf(p[2]),
                second: .leaf(p[3])
            )
            rootNode = .split(
                splitID: "preset-2x2-root",
                axis: .vertical,
                ratio: 0.50,
                first: topRow,
                second: bottomRow
            )

        case .matrix3x2:
            // 3 columns x 2 rows = 6 equal cells (`1/3` outer horizontal split + `1/2` inner horizontal split)
            let top3 = PTYBinarySplitNode.split(
                splitID: "preset-3x2-top-outer",
                axis: .horizontal,
                ratio: 1.0 / 3.0,
                first: .leaf(p[0]),
                second: .split(
                    splitID: "preset-3x2-top-inner",
                    axis: .horizontal,
                    ratio: 0.50,
                    first: .leaf(p[1]),
                    second: .leaf(p[2])
                )
            )
            let bottom3 = PTYBinarySplitNode.split(
                splitID: "preset-3x2-bot-outer",
                axis: .horizontal,
                ratio: 1.0 / 3.0,
                first: .leaf(p[3]),
                second: .split(
                    splitID: "preset-3x2-bot-inner",
                    axis: .horizontal,
                    ratio: 0.50,
                    first: .leaf(p[4]),
                    second: .leaf(p[5])
                )
            )
            rootNode = .split(
                splitID: "preset-3x2-root",
                axis: .vertical,
                ratio: 0.50,
                first: top3,
                second: bottom3
            )

        case .leadConductor1Plus3:
            // Left 56% Lead Conductor + Right 44% vertical stack of 3 worker panes (`1/3` + `1/2`)
            let rightStack = PTYBinarySplitNode.split(
                splitID: "preset-1p3-stack-top",
                axis: .vertical,
                ratio: 1.0 / 3.0,
                first: .leaf(p[1]),
                second: .split(
                    splitID: "preset-1p3-stack-bot",
                    axis: .vertical,
                    ratio: 0.50,
                    first: .leaf(p[2]),
                    second: .leaf(p[3])
                )
            )
            rootNode = .split(
                splitID: "preset-1p3-root",
                axis: .horizontal,
                ratio: 0.56,
                first: .leaf(p[0]),
                second: rightStack
            )
        }

        var tree = PTYBinarySplitTree(root: rootNode, focusedPaneID: p[0].paneID)
        tree.nextSplitCounter = 10
        return tree
    }

    // MARK: - Split, Close, Swap, Zoom & Proportional Resize Mutations

    @discardableResult
    public mutating func splitPane(
        targetPaneID: String? = nil,
        axis: PTYSplitAxis,
        ratio: Double = 0.50,
        newPane: PTYPaneDescriptor,
        insertNewPaneFirst: Bool = false
    ) -> Bool {
        guard let currentRoot = root else {
            root = .leaf(newPane)
            focusedPaneID = newPane.paneID
            return true
        }
        guard !currentRoot.containsPane(newPane.paneID) else { return false }

        let anchorID = targetPaneID ?? focusedPaneID ?? currentRoot.allLeaves().first?.paneID ?? ""
        let splitID = "split-\(nextSplitCounter)"
        let clamped = Self.clampRatio(ratio)

        let (updatedRoot, didSplit) = Self.insertSplit(
            in: currentRoot,
            targetPaneID: anchorID,
            splitID: splitID,
            axis: axis,
            ratio: clamped,
            newPane: newPane,
            insertFirst: insertNewPaneFirst
        )
        if didSplit {
            nextSplitCounter += 1
            root = updatedRoot
            focusedPaneID = newPane.paneID
            zoomedPaneID = nil
        }
        return didSplit
    }

    @discardableResult
    public mutating func closePane(_ paneID: String) -> Bool {
        guard let currentRoot = root, currentRoot.containsPane(paneID) else {
            return false
        }
        root = Self.removeLeaf(from: currentRoot, paneID: paneID)
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
        }
        if focusedPaneID == paneID {
            focusedPaneID = root?.allLeaves().first?.paneID
        }
        return true
    }

    @discardableResult
    public mutating func focusPane(_ paneID: String) -> Bool {
        guard root?.containsPane(paneID) == true else { return false }
        focusedPaneID = paneID
        if zoomedPaneID != nil {
            zoomedPaneID = paneID
        }
        return true
    }

    /// Toggles single-pane zoom/maximize mode while keeping the underlying split hierarchy intact.
    @discardableResult
    public mutating func toggleZoom(forPane paneID: String? = nil) -> String? {
        let candidate = paneID ?? focusedPaneID
        guard let target = candidate, root?.containsPane(target) == true else {
            zoomedPaneID = nil
            return nil
        }
        if zoomedPaneID == target {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = target
            focusedPaneID = target
        }
        return zoomedPaneID
    }

    public mutating func unzoom() {
        zoomedPaneID = nil
    }

    @discardableResult
    public mutating func setSplitRatio(splitID: String, ratio: Double) -> Bool {
        guard let currentRoot = root else { return false }
        let clamped = Self.clampRatio(ratio)
        let (updated, changed) = Self.updateRatio(in: currentRoot, splitID: splitID, newRatio: clamped)
        if changed { root = updated }
        return changed
    }

    /// Adjusts the nearest ancestor split along `axis` containing `paneID` by `deltaRatio`.
    @discardableResult
    public mutating func resizePaneProportionally(
        paneID: String? = nil,
        along axis: PTYSplitAxis,
        deltaRatio: Double
    ) -> Bool {
        guard let currentRoot = root,
              let targetID = paneID ?? focusedPaneID else {
            return false
        }
        let (updated, changed) = Self.nudgeAncestorRatio(
            in: currentRoot,
            paneID: targetID,
            axis: axis,
            delta: deltaRatio
        )
        if changed { root = updated }
        return changed
    }

    @discardableResult
    public mutating func swapPanes(_ paneIDA: String, _ paneIDB: String) -> Bool {
        guard paneIDA != paneIDB,
              let currentRoot = root,
              let descA = currentRoot.findPane(paneIDA),
              let descB = currentRoot.findPane(paneIDB) else {
            return false
        }
        root = Self.replaceLeaves(in: currentRoot, replacements: [paneIDA: descB, paneIDB: descA])
        return true
    }

    /// Rebalances every split node ratio proportionally to the leaf counts on either side along the same axis.
    public mutating func equalizeSplitRatios() {
        guard let currentRoot = root else { return }
        root = Self.rebalanceNode(currentRoot)
    }

    // MARK: - Geometric Layout Solver & Directional Focus Navigation

    public func solveLayout(
        in viewport: PTYMultiplexerRect,
        cellWidth: Double = 8.0,
        cellHeight: Double = 18.0,
        dividerThickness: Double = 2.0,
        paneHeaderAndPaddingHeight: Double = 26.0,
        horizontalPadding: Double = 8.0
    ) -> PTYSolvedMultiplexerLayout {
        guard let currentRoot = root else {
            return PTYSolvedMultiplexerLayout(viewport: viewport, panes: [], dividers: [], zoomedPaneID: nil)
        }

        let cw = max(4.0, cellWidth)
        let ch = max(8.0, cellHeight)

        // When a single pane is zoomed, give it 100% of the viewport and mark siblings as hidden-by-zoom
        if let zID = zoomedPaneID, currentRoot.containsPane(zID) {
            let allPanes = currentRoot.allLeaves()
            var frames: [PTYSolvedPaneFrame] = []
            frames.reserveCapacity(allPanes.count)

            for desc in allPanes {
                if desc.paneID == zID {
                    let content = PTYMultiplexerRect(
                        x: viewport.x + horizontalPadding,
                        y: viewport.y + paneHeaderAndPaddingHeight,
                        width: max(0.0, viewport.width - horizontalPadding * 2.0),
                        height: max(0.0, viewport.height - paneHeaderAndPaddingHeight - 4.0)
                    )
                    let cols = max(desc.minimumColumns, Int((content.width / cw).rounded(.down)))
                    let rows = max(desc.minimumRows, Int((content.height / ch).rounded(.down)))
                    frames.append(
                        PTYSolvedPaneFrame(
                            pane: desc,
                            outerFrame: viewport,
                            contentFrame: content,
                            columns: cols,
                            rows: rows,
                            isFocused: focusedPaneID == desc.paneID,
                            isZoomed: true,
                            isHiddenByZoom: false
                        )
                    )
                } else {
                    let zeroRect = PTYMultiplexerRect(x: viewport.x, y: viewport.y, width: 0, height: 0)
                    frames.append(
                        PTYSolvedPaneFrame(
                            pane: desc,
                            outerFrame: zeroRect,
                            contentFrame: zeroRect,
                            columns: desc.minimumColumns,
                            rows: desc.minimumRows,
                            isFocused: false,
                            isZoomed: false,
                            isHiddenByZoom: true
                        )
                    )
                }
            }
            return PTYSolvedMultiplexerLayout(viewport: viewport, panes: frames, dividers: [], zoomedPaneID: zID)
        }

        var solvedPanes: [PTYSolvedPaneFrame] = []
        var solvedDividers: [PTYSolvedSplitDivider] = []
        solveNodeRecursive(
            node: currentRoot,
            rect: viewport,
            cellWidth: cw,
            cellHeight: ch,
            dividerThickness: dividerThickness,
            headerHeight: paneHeaderAndPaddingHeight,
            hPad: horizontalPadding,
            panesOut: &solvedPanes,
            dividersOut: &solvedDividers
        )
        return PTYSolvedMultiplexerLayout(
            viewport: viewport,
            panes: solvedPanes,
            dividers: solvedDividers,
            zoomedPaneID: nil
        )
    }

    @discardableResult
    public mutating func focusNeighbor(
        in direction: PTYFocusDirection,
        viewport: PTYMultiplexerRect = PTYMultiplexerRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> String? {
        guard zoomedPaneID == nil else { return focusedPaneID }
        let solved = solveLayout(in: viewport)
        guard let currentID = focusedPaneID,
              let originFrame = solved.panes.first(where: { $0.pane.paneID == currentID })?.outerFrame else {
            return focusedPaneID
        }

        var bestCandidateID: String?
        var bestScore = Double.greatestFiniteMagnitude

        for candidate in solved.panes where candidate.pane.paneID != currentID && !candidate.isHiddenByZoom {
            let rect = candidate.outerFrame
            let primaryGap: Double
            let orthogonalOverlap: Double

            switch direction {
            case .left:
                guard rect.maxX <= originFrame.minX + 4.0 else { continue }
                primaryGap = max(0.0, originFrame.minX - rect.maxX)
                orthogonalOverlap = max(0.0, min(originFrame.maxY, rect.maxY) - max(originFrame.minY, rect.minY))
            case .right:
                guard rect.minX >= originFrame.maxX - 4.0 else { continue }
                primaryGap = max(0.0, rect.minX - originFrame.maxX)
                orthogonalOverlap = max(0.0, min(originFrame.maxY, rect.maxY) - max(originFrame.minY, rect.minY))
            case .up:
                guard rect.maxY <= originFrame.minY + 4.0 else { continue }
                primaryGap = max(0.0, originFrame.minY - rect.maxY)
                orthogonalOverlap = max(0.0, min(originFrame.maxX, rect.maxX) - max(originFrame.minX, rect.minX))
            case .down:
                guard rect.minY >= originFrame.maxY - 4.0 else { continue }
                primaryGap = max(0.0, rect.minY - originFrame.maxY)
                orthogonalOverlap = max(0.0, min(originFrame.maxX, rect.maxX) - max(originFrame.minX, rect.minX))
            }

            guard orthogonalOverlap > 1.0 else { continue }
            let centerDist = hypot(rect.midX - originFrame.midX, rect.midY - originFrame.midY)
            let score = primaryGap * 10.0 + centerDist - orthogonalOverlap * 0.25
            if score < bestScore {
                bestScore = score
                bestCandidateID = candidate.pane.paneID
            }
        }

        if let nextID = bestCandidateID {
            focusedPaneID = nextID
        }
        return focusedPaneID
    }

    // MARK: - Private Tree Helpers

    private static func clampRatio(_ r: Double) -> Double {
        min(maxSplitRatio, max(minSplitRatio, r))
    }

    private func solveNodeRecursive(
        node: PTYBinarySplitNode,
        rect: PTYMultiplexerRect,
        cellWidth: Double,
        cellHeight: Double,
        dividerThickness: Double,
        headerHeight: Double,
        hPad: Double,
        panesOut: inout [PTYSolvedPaneFrame],
        dividersOut: inout [PTYSolvedSplitDivider]
    ) {
        switch node {
        case .leaf(let desc):
            let content = PTYMultiplexerRect(
                x: rect.x + hPad,
                y: rect.y + headerHeight,
                width: max(0.0, rect.width - hPad * 2.0),
                height: max(0.0, rect.height - headerHeight - 4.0)
            )
            let cols = max(desc.minimumColumns, Int((content.width / cellWidth).rounded(.down)))
            let rows = max(desc.minimumRows, Int((content.height / cellHeight).rounded(.down)))
            panesOut.append(
                PTYSolvedPaneFrame(
                    pane: desc,
                    outerFrame: rect,
                    contentFrame: content,
                    columns: cols,
                    rows: rows,
                    isFocused: focusedPaneID == desc.paneID,
                    isZoomed: false,
                    isHiddenByZoom: false
                )
            )

        case .split(let splitID, let axis, let ratio, let first, let second):
            let (firstRect, divRect, secondRect) = rect.split(
                along: axis,
                ratio: ratio,
                dividerThickness: dividerThickness
            )
            let spanAlongAxis = (axis == .horizontal)
                ? max(1.0, rect.width - dividerThickness)
                : max(1.0, rect.height - dividerThickness)
            dividersOut.append(
                PTYSolvedSplitDivider(
                    splitID: splitID,
                    axis: axis,
                    frame: divRect,
                    ratio: ratio,
                    parentSpanAlongAxis: spanAlongAxis
                )
            )
            solveNodeRecursive(
                node: first,
                rect: firstRect,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                dividerThickness: dividerThickness,
                headerHeight: headerHeight,
                hPad: hPad,
                panesOut: &panesOut,
                dividersOut: &dividersOut
            )
            solveNodeRecursive(
                node: second,
                rect: secondRect,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                dividerThickness: dividerThickness,
                headerHeight: headerHeight,
                hPad: hPad,
                panesOut: &panesOut,
                dividersOut: &dividersOut
            )
        }
    }

    private static func insertSplit(
        in node: PTYBinarySplitNode,
        targetPaneID: String,
        splitID: String,
        axis: PTYSplitAxis,
        ratio: Double,
        newPane: PTYPaneDescriptor,
        insertFirst: Bool
    ) -> (PTYBinarySplitNode, Bool) {
        switch node {
        case .leaf(let existing):
            guard existing.paneID == targetPaneID else { return (node, false) }
            let newLeaf = PTYBinarySplitNode.leaf(newPane)
            let splitNode: PTYBinarySplitNode = insertFirst
                ? .split(splitID: splitID, axis: axis, ratio: ratio, first: newLeaf, second: node)
                : .split(splitID: splitID, axis: axis, ratio: ratio, first: node, second: newLeaf)
            return (splitNode, true)

        case .split(let sid, let ax, let r, let first, let second):
            let (updatedFirst, didFirst) = insertSplit(
                in: first,
                targetPaneID: targetPaneID,
                splitID: splitID,
                axis: axis,
                ratio: ratio,
                newPane: newPane,
                insertFirst: insertFirst
            )
            if didFirst {
                return (.split(splitID: sid, axis: ax, ratio: r, first: updatedFirst, second: second), true)
            }
            let (updatedSecond, didSecond) = insertSplit(
                in: second,
                targetPaneID: targetPaneID,
                splitID: splitID,
                axis: axis,
                ratio: ratio,
                newPane: newPane,
                insertFirst: insertFirst
            )
            return (.split(splitID: sid, axis: ax, ratio: r, first: first, second: updatedSecond), didSecond)
        }
    }

    private static func removeLeaf(from node: PTYBinarySplitNode, paneID: String) -> PTYBinarySplitNode? {
        switch node {
        case .leaf(let desc):
            return desc.paneID == paneID ? nil : node
        case .split(let sid, let ax, let r, let first, let second):
            if first.containsPane(paneID) {
                if let remFirst = removeLeaf(from: first, paneID: paneID) {
                    return .split(splitID: sid, axis: ax, ratio: r, first: remFirst, second: second)
                } else {
                    return second
                }
            }
            if second.containsPane(paneID) {
                if let remSecond = removeLeaf(from: second, paneID: paneID) {
                    return .split(splitID: sid, axis: ax, ratio: r, first: first, second: remSecond)
                } else {
                    return first
                }
            }
            return node
        }
    }

    private static func updateRatio(
        in node: PTYBinarySplitNode,
        splitID: String,
        newRatio: Double
    ) -> (PTYBinarySplitNode, Bool) {
        switch node {
        case .leaf:
            return (node, false)
        case .split(let sid, let ax, let r, let first, let second):
            if sid == splitID {
                return (.split(splitID: sid, axis: ax, ratio: newRatio, first: first, second: second), true)
            }
            let (u1, c1) = updateRatio(in: first, splitID: splitID, newRatio: newRatio)
            if c1 {
                return (.split(splitID: sid, axis: ax, ratio: r, first: u1, second: second), true)
            }
            let (u2, c2) = updateRatio(in: second, splitID: splitID, newRatio: newRatio)
            return (.split(splitID: sid, axis: ax, ratio: r, first: first, second: u2), c2)
        }
    }

    private static func nudgeAncestorRatio(
        in node: PTYBinarySplitNode,
        paneID: String,
        axis: PTYSplitAxis,
        delta: Double
    ) -> (PTYBinarySplitNode, Bool) {
        switch node {
        case .leaf:
            return (node, false)
        case .split(let sid, let ax, let r, let first, let second):
            let inFirst = first.containsPane(paneID)
            let inSecond = !inFirst && second.containsPane(paneID)
            guard inFirst || inSecond else { return (node, false) }

            // Try deeper matching split first so inner panes adjust their immediate divider
            if inFirst {
                let (deeper, didChange) = nudgeAncestorRatio(in: first, paneID: paneID, axis: axis, delta: delta)
                if didChange {
                    return (.split(splitID: sid, axis: ax, ratio: r, first: deeper, second: second), true)
                }
            } else {
                let (deeper, didChange) = nudgeAncestorRatio(in: second, paneID: paneID, axis: axis, delta: delta)
                if didChange {
                    return (.split(splitID: sid, axis: ax, ratio: r, first: first, second: deeper), true)
                }
            }

            guard ax == axis else { return (node, false) }
            let signedDelta = inFirst ? delta : -delta
            let adjusted = clampRatio(r + signedDelta)
            return (.split(splitID: sid, axis: ax, ratio: adjusted, first: first, second: second), adjusted != r)
        }
    }

    private static func replaceLeaves(
        in node: PTYBinarySplitNode,
        replacements: [String: PTYPaneDescriptor]
    ) -> PTYBinarySplitNode {
        switch node {
        case .leaf(let desc):
            if let rep = replacements[desc.paneID] {
                return .leaf(rep)
            }
            return node
        case .split(let sid, let ax, let r, let first, let second):
            return .split(
                splitID: sid,
                axis: ax,
                ratio: r,
                first: replaceLeaves(in: first, replacements: replacements),
                second: replaceLeaves(in: second, replacements: replacements)
            )
        }
    }

    private static func axisSpanWeight(_ node: PTYBinarySplitNode, along axis: PTYSplitAxis) -> Int {
        switch node {
        case .leaf:
            return 1
        case .split(_, let ax, _, let first, let second):
            if ax == axis {
                return axisSpanWeight(first, along: axis) + axisSpanWeight(second, along: axis)
            }
            return max(axisSpanWeight(first, along: axis), axisSpanWeight(second, along: axis))
        }
    }

    private static func rebalanceNode(_ node: PTYBinarySplitNode) -> PTYBinarySplitNode {
        switch node {
        case .leaf:
            return node
        case .split(let sid, let ax, _, let first, let second):
            let bFirst = rebalanceNode(first)
            let bSecond = rebalanceNode(second)
            let w1 = Double(axisSpanWeight(bFirst, along: ax))
            let w2 = Double(axisSpanWeight(bSecond, along: ax))
            let eqRatio = clampRatio(w1 / max(1.0, w1 + w2))
            return .split(splitID: sid, axis: ax, ratio: eqRatio, first: bFirst, second: bSecond)
        }
    }
}

// MARK: - Synchronized Multi-Pane Broadcast Input Filter

public enum PTYBroadcastTargetScope: Sendable, Codable, Hashable {
    case focusedPaneOnly
    case selectedPaneIDs(Set<String>)
    case matchingVendors(Set<AgentVendor>)
    case allWritableAgentPanes
}

public struct PTYBroadcastSafetyPolicy: Sendable, Codable, Hashable {
    public var blockReadOnlyVerifierPanes: Bool
    public var blockDestructiveShellPatterns: Bool
    public var blockControlSignalInterruptsInMultiBroadcast: Bool
    public var forbiddenSubstrings: [String]

    public init(
        blockReadOnlyVerifierPanes: Bool = true,
        blockDestructiveShellPatterns: Bool = true,
        blockControlSignalInterruptsInMultiBroadcast: Bool = false,
        forbiddenSubstrings: [String] = [
            "rm -rf /",
            "rm -rf *",
            "git reset --hard",
            "git clean -fd",
            "git push --force",
            "git push -f",
            "mkfs.",
            "dd if=",
            ":(){:|:&};:"
        ]
    ) {
        self.blockReadOnlyVerifierPanes = blockReadOnlyVerifierPanes
        self.blockDestructiveShellPatterns = blockDestructiveShellPatterns
        self.blockControlSignalInterruptsInMultiBroadcast = blockControlSignalInterruptsInMultiBroadcast
        self.forbiddenSubstrings = forbiddenSubstrings
    }
}

public struct PTYBroadcastDispatchReceipt: Sendable, Codable, Hashable {
    public let deliveredLaneIDs: [String]
    public let skippedReadOnlyLaneIDs: [String]
    public let blockedByPolicyReason: String?
    public let bytesPerLane: Int

    public init(
        deliveredLaneIDs: [String],
        skippedReadOnlyLaneIDs: [String],
        blockedByPolicyReason: String?,
        bytesPerLane: Int
    ) {
        self.deliveredLaneIDs = deliveredLaneIDs
        self.skippedReadOnlyLaneIDs = skippedReadOnlyLaneIDs
        self.blockedByPolicyReason = blockedByPolicyReason
        self.bytesPerLane = bytesPerLane
    }

    public var wasBlocked: Bool {
        blockedByPolicyReason != nil
    }
}

public struct PTYBroadcastInputFilter: Sendable {
    public var scope: PTYBroadcastTargetScope
    public var safetyPolicy: PTYBroadcastSafetyPolicy

    public init(
        scope: PTYBroadcastTargetScope = .focusedPaneOnly,
        safetyPolicy: PTYBroadcastSafetyPolicy = PTYBroadcastSafetyPolicy()
    ) {
        self.scope = scope
        self.safetyPolicy = safetyPolicy
    }

    /// Resolves target panes and filters input payload through safety guardrails before dispatching to `PTYMultiplexerGrid`.
    public func evaluateAndDispatch(
        inputData: Data,
        in splitTree: PTYBinarySplitTree,
        grid: PTYMultiplexerGrid? = nil
    ) -> PTYBroadcastDispatchReceipt {
        guard !inputData.isEmpty else {
            return PTYBroadcastDispatchReceipt(
                deliveredLaneIDs: [],
                skippedReadOnlyLaneIDs: [],
                blockedByPolicyReason: nil,
                bytesPerLane: 0
            )
        }

        let allPanes = splitTree.panes
        let candidatePanes: [PTYPaneDescriptor]

        switch scope {
        case .focusedPaneOnly:
            if let fID = splitTree.focusedPaneID, let pane = allPanes.first(where: { $0.paneID == fID }) {
                candidatePanes = [pane]
            } else {
                candidatePanes = []
            }
        case .selectedPaneIDs(let ids):
            candidatePanes = allPanes.filter { ids.contains($0.paneID) }
        case .matchingVendors(let vendors):
            candidatePanes = allPanes.filter { pane in
                guard let v = pane.vendor else { return false }
                return vendors.contains(v)
            }
        case .allWritableAgentPanes:
            candidatePanes = allPanes
        }

        var writableLanes: [String] = []
        var skippedReadOnly: [String] = []
        for pane in candidatePanes {
            if safetyPolicy.blockReadOnlyVerifierPanes && pane.isReadOnlyVerifier {
                skippedReadOnly.append(pane.laneID)
            } else {
                writableLanes.append(pane.laneID)
            }
        }

        // Apply multi-pane broadcast safety checks whenever broadcasting to >1 lane (or always if destructive check enabled)
        if writableLanes.count > 1 && safetyPolicy.blockControlSignalInterruptsInMultiBroadcast {
            if inputData.contains(0x03) || inputData.contains(0x04) || inputData.contains(0x1C) {
                return PTYBroadcastDispatchReceipt(
                    deliveredLaneIDs: [],
                    skippedReadOnlyLaneIDs: skippedReadOnly,
                    blockedByPolicyReason: "Control interrupt (^C / ^D / ^\\) blocked across \(writableLanes.count)-lane broadcast",
                    bytesPerLane: 0
                )
            }
        }

        if safetyPolicy.blockDestructiveShellPatterns && writableLanes.count > 1 {
            let decodedText = String(decoding: inputData, as: UTF8.self).lowercased()
            for pattern in safetyPolicy.forbiddenSubstrings {
                if decodedText.contains(pattern.lowercased()) {
                    return PTYBroadcastDispatchReceipt(
                        deliveredLaneIDs: [],
                        skippedReadOnlyLaneIDs: skippedReadOnly,
                        blockedByPolicyReason: "Destructive broadcast pattern '\(pattern)' intercepted",
                        bytesPerLane: 0
                    )
                }
            }
        }

        if let targetGrid = grid {
            for laneID in writableLanes {
                targetGrid.session(forLane: laneID)?.writeInput(inputData)
            }
        }

        return PTYBroadcastDispatchReceipt(
            deliveredLaneIDs: writableLanes,
            skippedReadOnlyLaneIDs: skippedReadOnly,
            blockedByPolicyReason: nil,
            bytesPerLane: inputData.count
        )
    }
}

// MARK: - Power-of-Two Backpressure Ring Buffer & 60 Hz Output Frame Coalescer

public struct PTYRingBufferTelemetry: Sendable, Codable, Hashable {
    public let capacityBytes: Int
    public let readableBytes: Int
    public let highWatermarkBytes: Int
    public let lowWatermarkBytes: Int
    public let isBackpressured: Bool
    public let totalBytesEnqueued: UInt64
    public let totalBytesDequeued: UInt64
    public let totalBytesDropped: UInt64

    public init(
        capacityBytes: Int,
        readableBytes: Int,
        highWatermarkBytes: Int,
        lowWatermarkBytes: Int,
        isBackpressured: Bool,
        totalBytesEnqueued: UInt64,
        totalBytesDequeued: UInt64,
        totalBytesDropped: UInt64
    ) {
        self.capacityBytes = capacityBytes
        self.readableBytes = readableBytes
        self.highWatermarkBytes = highWatermarkBytes
        self.lowWatermarkBytes = lowWatermarkBytes
        self.isBackpressured = isBackpressured
        self.totalBytesEnqueued = totalBytesEnqueued
        self.totalBytesDequeued = totalBytesDequeued
        self.totalBytesDropped = totalBytesDropped
    }
}

public struct PTYByteRingBuffer: Sendable {
    public let capacity: Int
    public let highWatermark: Int
    public let lowWatermark: Int

    private let mask: Int
    private var storage: [UInt8]
    private var readHead: Int = 0
    private var writeTail: Int = 0
    public private(set) var readableBytes: Int = 0
    public private(set) var isBackpressured: Bool = false
    public private(set) var totalBytesEnqueued: UInt64 = 0
    public private(set) var totalBytesDequeued: UInt64 = 0
    public private(set) var totalBytesDropped: UInt64 = 0

    public init(minimumCapacity: Int = 262_144) {
        let pow2 = Self.nextPowerOfTwo(max(1024, minimumCapacity))
        self.capacity = pow2
        self.mask = pow2 - 1
        self.highWatermark = (pow2 * 3) / 4
        self.lowWatermark = pow2 / 4
        self.storage = [UInt8](repeating: 0, count: pow2)
    }

    public var writableBytes: Int {
        capacity - readableBytes
    }

    /// Appends `data` into the ring buffer. When full and `dropOldestOnOverflow` is true, advances `readHead` on a UTF-8 safe boundary so live tail output stays responsive.
    @discardableResult
    public mutating func enqueue(_ data: Data, dropOldestOnOverflow: Bool = true) -> Int {
        guard !data.isEmpty else { return 0 }

        // If incoming burst exceeds entire ring capacity, keep only the newest `capacity` bytes
        let sliceToWrite: Data
        if data.count > capacity {
            let excess = data.count - capacity
            totalBytesDropped += UInt64(excess + readableBytes)
            readHead = 0
            writeTail = 0
            readableBytes = 0
            sliceToWrite = data.suffix(capacity)
        } else {
            sliceToWrite = data
        }

        if sliceToWrite.count > writableBytes {
            let needed = sliceToWrite.count - writableBytes
            if dropOldestOnOverflow {
                advanceReadHeadDropping(bytes: needed)
            } else {
                let fitCount = writableBytes
                let dropped = sliceToWrite.count - fitCount
                totalBytesDropped += UInt64(dropped)
                writeContiguousBytes(sliceToWrite.prefix(fitCount))
                updateBackpressureFlag()
                return fitCount
            }
        }

        writeContiguousBytes(sliceToWrite)
        updateBackpressureFlag()
        return sliceToWrite.count
    }

    /// Extracts up to `maxBytes` from the ring buffer, avoiding splitting trailing multi-byte UTF-8 sequences when more bytes remain queued.
    public mutating func dequeue(maxBytes: Int) -> Data {
        let limit = min(max(0, maxBytes), readableBytes)
        guard limit > 0 else { return Data() }

        var takeCount = limit
        if takeCount < readableBytes && takeCount > 4 {
            // Avoid slicing mid-UTF-8 continuation sequence if we are capping frame budget
            var backtrack = 0
            while backtrack < 3 {
                let lastIdx = (readHead + takeCount - 1 - backtrack) & mask
                let b = storage[lastIdx]
                if b < 0x80 {
                    break
                } else if (b & 0xC0) == 0xC0 {
                    let expectedLen: Int
                    if (b & 0xE0) == 0xC0      { expectedLen = 2 }
                    else if (b & 0xF0) == 0xE0 { expectedLen = 3 }
                    else                       { expectedLen = 4 }
                    if backtrack + 1 < expectedLen {
                        takeCount -= (backtrack + 1)
                    }
                    break
                }
                backtrack += 1
            }
        }

        var out = Data(count: takeCount)
        out.withUnsafeMutableBytes { rawOut in
            guard let dstBase = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let firstChunk = min(takeCount, capacity - readHead)
            storage.withUnsafeBufferPointer { srcBuf in
                guard let srcBase = srcBuf.baseAddress else { return }
                dstBase.update(from: srcBase.advanced(by: readHead), count: firstChunk)
                if firstChunk < takeCount {
                    dstBase.advanced(by: firstChunk).update(from: srcBase, count: takeCount - firstChunk)
                }
            }
        }

        readHead = (readHead + takeCount) & mask
        readableBytes -= takeCount
        totalBytesDequeued += UInt64(takeCount)
        updateBackpressureFlag()
        return out
    }

    public func telemetry() -> PTYRingBufferTelemetry {
        PTYRingBufferTelemetry(
            capacityBytes: capacity,
            readableBytes: readableBytes,
            highWatermarkBytes: highWatermark,
            lowWatermarkBytes: lowWatermark,
            isBackpressured: isBackpressured,
            totalBytesEnqueued: totalBytesEnqueued,
            totalBytesDequeued: totalBytesDequeued,
            totalBytesDropped: totalBytesDropped
        )
    }

    private mutating func writeContiguousBytes(_ slice: Data) {
        let count = slice.count
        guard count > 0 else { return }
        let firstChunk = min(count, capacity - writeTail)
        slice.withUnsafeBytes { rawIn in
            guard let srcBase = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            storage.withUnsafeMutableBufferPointer { dstBuf in
                guard let dstBase = dstBuf.baseAddress else { return }
                dstBase.advanced(by: writeTail).update(from: srcBase, count: firstChunk)
                if firstChunk < count {
                    dstBase.update(from: srcBase.advanced(by: firstChunk), count: count - firstChunk)
                }
            }
        }
        writeTail = (writeTail + count) & mask
        readableBytes += count
        totalBytesEnqueued += UInt64(count)
    }

    private mutating func advanceReadHeadDropping(bytes count: Int) {
        let drop = min(readableBytes, max(0, count))
        readHead = (readHead + drop) & mask
        readableBytes -= drop
        totalBytesDropped += UInt64(drop)
        // Advance past orphan UTF-8 continuation bytes (`10xxxxxx`) at new readHead
        var skippedContinuations = 0
        while readableBytes > 0 && skippedContinuations < 3 {
            let b = storage[readHead]
            if (b & 0xC0) == 0x80 {
                readHead = (readHead + 1) & mask
                readableBytes -= 1
                totalBytesDropped += 1
                skippedContinuations += 1
            } else {
                break
            }
        }
    }

    private mutating func updateBackpressureFlag() {
        if !isBackpressured && readableBytes >= highWatermark {
            isBackpressured = true
        } else if isBackpressured && readableBytes <= lowWatermark {
            isBackpressured = false
        }
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var v = max(1, n - 1)
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}

public struct PTYCoalescedFrameUpdate: Sendable, Codable, Hashable {
    public let laneID: String
    public let frameSequenceNumber: UInt64
    public let coalescedWriteCount: Int
    public let bytesDrainedInFrame: Int
    public let snapshot: TerminalViewportSnapshot
    public let ringTelemetry: PTYRingBufferTelemetry

    public init(
        laneID: String,
        frameSequenceNumber: UInt64,
        coalescedWriteCount: Int,
        bytesDrainedInFrame: Int,
        snapshot: TerminalViewportSnapshot,
        ringTelemetry: PTYRingBufferTelemetry
    ) {
        self.laneID = laneID
        self.frameSequenceNumber = frameSequenceNumber
        self.coalescedWriteCount = coalescedWriteCount
        self.bytesDrainedInFrame = bytesDrainedInFrame
        self.snapshot = snapshot
        self.ringTelemetry = ringTelemetry
    }
}

public final class PTYOutputFrameCoalescer: @unchecked Sendable {
    private struct LaneCoalesceSlot {
        let screenBuffer: VT100TerminalScreenBuffer
        var ringBuffer: PTYByteRingBuffer
        var pendingWriteChunks: Int = 0
        var frameSequence: UInt64 = 0
    }

    public let targetFramesPerSecond: Int
    public let maxBytesPerLanePerFrame: Int
    public let ringBufferCapacityPerLane: Int

    private let lock = NSLock()
    private var slotsByLaneID: [String: LaneCoalesceSlot] = [:]
    private let timerQueue = DispatchQueue(label: "io.github.zxu756.RelayIDE.pty.coalescer60hz", qos: .userInteractive)
    private var frameTimer: DispatchSourceTimer?

    public var onCoalescedFrameBatch: (@Sendable ([PTYCoalescedFrameUpdate]) -> Void)?

    public init(
        targetFramesPerSecond: Int = 60,
        maxBytesPerLanePerFrame: Int = 65_536,
        ringBufferCapacityPerLane: Int = 262_144
    ) {
        self.targetFramesPerSecond = min(120, max(15, targetFramesPerSecond))
        self.maxBytesPerLanePerFrame = max(4_096, maxBytesPerLanePerFrame)
        self.ringBufferCapacityPerLane = max(16_384, ringBufferCapacityPerLane)
    }

    deinit {
        stop60HzLoop()
    }

    public func registerLane(laneID: String, screenBuffer: VT100TerminalScreenBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if slotsByLaneID[laneID] == nil {
            slotsByLaneID[laneID] = LaneCoalesceSlot(
                screenBuffer: screenBuffer,
                ringBuffer: PTYByteRingBuffer(minimumCapacity: ringBufferCapacityPerLane)
            )
        }
    }

    public func unregisterLane(laneID: String) {
        lock.lock()
        slotsByLaneID.removeValue(forKey: laneID)
        lock.unlock()
    }

    /// Non-blocking producer entry point: buffers raw PTY output bytes for the next 60 Hz frame tick.
    public func enqueueOutput(laneID: String, data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if var slot = slotsByLaneID[laneID] {
            _ = slot.ringBuffer.enqueue(data, dropOldestOnOverflow: true)
            slot.pendingWriteChunks += 1
            slotsByLaneID[laneID] = slot
        }
        lock.unlock()
    }

    /// Starts the real-time 60 Hz (`16.67ms`) frame batching timer.
    public func start60HzLoop() {
        lock.lock()
        if frameTimer != nil {
            lock.unlock()
            return
        }
        let intervalNanos = UInt64(1_000_000_000 / max(1, targetFramesPerSecond))
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNanos)),
            repeating: .nanoseconds(Int(intervalNanos)),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let updates = self.flushFrameTick()
            if !updates.isEmpty, let callback = self.onCoalescedFrameBatch {
                callback(updates)
            }
        }
        frameTimer = timer
        lock.unlock()
        timer.resume()
    }

    public func stop60HzLoop() {
        lock.lock()
        let timer = frameTimer
        frameTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    /// Deterministically drains up to `maxBytesPerLanePerFrame` per dirty lane, feeds its `VT100TerminalScreenBuffer` once, and emits batched snapshots.
    @discardableResult
    public func flushFrameTick(overrideBudgetBytes: Int? = nil) -> [PTYCoalescedFrameUpdate] {
        let budget = overrideBudgetBytes ?? maxBytesPerLanePerFrame
        var drainedWork: [(laneID: String, screenBuffer: VT100TerminalScreenBuffer, chunk: Data, writeCount: Int, seq: UInt64, telemetry: PTYRingBufferTelemetry)] = []

        lock.lock()
        let sortedKeys = slotsByLaneID.keys.sorted()
        for key in sortedKeys {
            guard var slot = slotsByLaneID[key], slot.ringBuffer.readableBytes > 0 else {
                continue
            }
            let dataSlice = slot.ringBuffer.dequeue(maxBytes: budget)
            guard !dataSlice.isEmpty else { continue }
            let writes = max(1, slot.pendingWriteChunks)
            if slot.ringBuffer.readableBytes == 0 {
                slot.pendingWriteChunks = 0
            } else {
                slot.pendingWriteChunks = 1
            }
            slot.frameSequence += 1
            let seq = slot.frameSequence
            let telem = slot.ringBuffer.telemetry()
            let buf = slot.screenBuffer
            slotsByLaneID[key] = slot
            drainedWork.append((key, buf, dataSlice, writes, seq, telem))
        }
        lock.unlock()

        var updates: [PTYCoalescedFrameUpdate] = []
        updates.reserveCapacity(drainedWork.count)
        for item in drainedWork {
            item.screenBuffer.feed(item.chunk)
            updates.append(
                PTYCoalescedFrameUpdate(
                    laneID: item.laneID,
                    frameSequenceNumber: item.seq,
                    coalescedWriteCount: item.writeCount,
                    bytesDrainedInFrame: item.chunk.count,
                    snapshot: item.screenBuffer.snapshot(),
                    ringTelemetry: item.telemetry
                )
            )
        }
        return updates
    }

    public func telemetry(forLane laneID: String) -> PTYRingBufferTelemetry? {
        lock.lock()
        defer { lock.unlock() }
        return slotsByLaneID[laneID]?.ringBuffer.telemetry()
    }
}

// MARK: - Unified Multiplexer Layout & Session Coordinator

public final class PTYMultiplexerLayoutCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    public let grid: PTYMultiplexerGrid
    public let coalescer: PTYOutputFrameCoalescer
    public private(set) var splitTree: PTYBinarySplitTree
    public var broadcastFilter: PTYBroadcastInputFilter

    public init(
        grid: PTYMultiplexerGrid = PTYMultiplexerGrid(),
        preset: PTYMultiplexerPreset = .quadGrid2x2,
        initialPanes: [PTYPaneDescriptor] = []
    ) {
        self.grid = grid
        self.coalescer = PTYOutputFrameCoalescer()
        let tree = PTYBinarySplitTree.makePreset(preset, panes: initialPanes)
        self.splitTree = tree
        self.broadcastFilter = PTYBroadcastInputFilter(scope: .focusedPaneOnly)

        for pane in tree.panes {
            let session = grid.getOrCreateSession(laneID: pane.laneID)
            coalescer.registerLane(laneID: pane.laneID, screenBuffer: session.screenBuffer)
        }
    }

    public func applyPreset(_ preset: PTYMultiplexerPreset, panes: [PTYPaneDescriptor] = []) {
        lock.lock()
        let nextTree = PTYBinarySplitTree.makePreset(preset, panes: panes.isEmpty ? splitTree.panes : panes)
        splitTree = nextTree
        lock.unlock()

        for pane in nextTree.panes {
            let session = grid.getOrCreateSession(laneID: pane.laneID)
            coalescer.registerLane(laneID: pane.laneID, screenBuffer: session.screenBuffer)
        }
    }

    /// Solves tiling geometry for `viewport` and synchronizes `TIOCSWINSZ` + `VT100TerminalScreenBuffer` dimensions on every visible PTY session.
    public func relayoutAndSyncTerminalSizes(
        in viewport: PTYMultiplexerRect,
        cellWidth: Double = 8.0,
        cellHeight: Double = 18.0
    ) -> PTYSolvedMultiplexerLayout {
        lock.lock()
        let solved = splitTree.solveLayout(in: viewport, cellWidth: cellWidth, cellHeight: cellHeight)
        lock.unlock()

        for frame in solved.visiblePanes {
            let session = grid.getOrCreateSession(
                laneID: frame.pane.laneID,
                rows: frame.rows,
                columns: frame.columns
            )
            session.resizeTerminal(rows: frame.rows, columns: frame.columns)
            coalescer.registerLane(laneID: frame.pane.laneID, screenBuffer: session.screenBuffer)
        }
        return solved
    }

    public func mutateTree(_ mutation: (inout PTYBinarySplitTree) -> Void) {
        lock.lock()
        mutation(&splitTree)
        let panes = splitTree.panes
        lock.unlock()

        for pane in panes {
            let session = grid.getOrCreateSession(laneID: pane.laneID)
            coalescer.registerLane(laneID: pane.laneID, screenBuffer: session.screenBuffer)
        }
    }

    public func dispatchInput(_ data: Data) -> PTYBroadcastDispatchReceipt {
        lock.lock()
        let currentTree = splitTree
        let currentFilter = broadcastFilter
        lock.unlock()
        return currentFilter.evaluateAndDispatch(inputData: data, in: currentTree, grid: grid)
    }
}
