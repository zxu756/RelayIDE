import Foundation
import RelayModels
import RelayOrchestrator
import RelaySemanticMerge
import RelayWorkbenchShell
import SwiftUI

// MARK: - 2.5D Isometric Coupling & Live Agent Territory Map Studio

public struct IsometricTerritoryMapCanvasView: View {
    @ObservedObject public var viewModel: RelayStudioViewModel

    public init(viewModel: RelayStudioViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            territoryToolbarStrip

            HStack(alignment: .top, spacing: 10) {
                isometricCanvasStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                martinMetricsAndFenceInspector
                    .frame(width: 322)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(10)
        .background(RelayBauhausDesign.warmSandpaper)
    }

    // MARK: - Top Vendor Territory Filter & Arc Control Bar

    private var territoryToolbarStrip: some View {
        let crossLaneArcCount = viewModel.isometricCouplingArcs.filter(\.crossesAgentLanes).count
        let conflictTowers = viewModel.isometricTiles.filter(\.hasMergeConflict).count

        return HStack(spacing: 8) {
            // All + Per-Vendor Filter Buttons
            HStack(spacing: 4) {
                vendorFilterButton(vendor: nil, label: "All (\(viewModel.isometricTiles.count))")
                ForEach([AgentVendor.claudeCode, .codex, .antigravity, .mistralVibe], id: \.self) { vendor in
                    let count = viewModel.isometricTiles.filter { $0.activeOwnerVendor == vendor }.count
                    vendorFilterButton(
                        vendor: vendor,
                        label: "\(RelayBauhausDesign.vendorShortTag(vendor)) (\(count))"
                    )
                }
            }

            Spacer(minLength: 6)

            Toggle(isOn: $viewModel.showCrossLaneCouplingOnly) {
                Text("Cross-Lane Arcs Only (\(crossLaneArcCount))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .toggleStyle(.checkbox)

            RelayBauhausPill(
                "\(viewModel.boundaryCollisions.count) Fence Alert",
                foreground: viewModel.boundaryCollisions.isEmpty ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.claudeVermilion,
                background: viewModel.boundaryCollisions.isEmpty ? RelayBauhausDesign.greenWash : RelayBauhausDesign.vermilionWash,
                border: (viewModel.boundaryCollisions.isEmpty ? RelayBauhausDesign.agySignalGreen : RelayBauhausDesign.claudeVermilion).opacity(0.5),
                symbolName: "exclamationmark.shield.fill",
                monospaced: true
            )

            if conflictTowers > 0 {
                RelayBauhausPill(
                    "\(conflictTowers) Conflict Beacon",
                    foreground: RelayBauhausDesign.claudeVermilion,
                    background: RelayBauhausDesign.vermilionWash,
                    border: RelayBauhausDesign.claudeVermilion.opacity(0.5),
                    symbolName: "flame.fill",
                    monospaced: true
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private func vendorFilterButton(vendor: AgentVendor?, label: String) -> some View {
        let isSelected = (viewModel.territoryVendorFilter == vendor)
        let accent = vendor.map { RelayBauhausDesign.vendorColor($0) } ?? RelayBauhausDesign.espressoInk

        return Button {
            viewModel.territoryVendorFilter = vendor
        } label: {
            HStack(spacing: 5) {
                if let vendor {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.vendorColor(vendor))
                        .frame(width: 6.5, height: 6.5)
                }
                Text(label)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .fill(isSelected ? accent : RelayBauhausDesign.warmIvory)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                    .strokeBorder(isSelected ? accent : RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2.5D Isometric Drafting Stage (SwiftUI.Canvas + Interactive Selection)

    private var isometricCanvasStage: some View {
        GeometryReader { geo in
            let projectedScene = buildProjectedIsometricScene(in: geo.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawPaperDraftingGrid(in: &context, size: size)
                    drawIsometricFloorPlatform(in: &context, scene: projectedScene)

                    // Painter's order: draw back-to-front 3D isometric towers
                    for prism in projectedScene.sortedPrisms {
                        drawIsometricPrismTower(in: &context, prism: prism)
                    }

                    // Elevated quadratic Bezier coupling arcs above tower roofs
                    drawIsometricCouplingArcs(in: &context, scene: projectedScene)

                    // Unoccluded foreground module plaques (collision-free)
                    drawIsometricForegroundLabels(in: &context, scene: projectedScene)
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            if let hit = hitTestPrism(at: event.location, in: projectedScene) {
                                viewModel.selectedIsometricModulePath = hit.tower.relativePath
                            }
                        }
                )

                // Legend Overlay in Top-Left Corner
                isometricLegendOverlay
                    .padding(10)

                // Bottom-Left Module Quick Bar
                isometricBottomCaptionOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                    .fill(RelayBauhausDesign.warmIvory)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayBauhausDesign.cornerRadius, style: .continuous)
                    .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )
        }
    }

    private var isometricLegendOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("2.5D ISOMETRIC TERRITORY PROJECTION")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.75)
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 10) {
                legendDot(color: RelayBauhausDesign.claudeVermilion, text: "Claude")
                legendDot(color: RelayBauhausDesign.codexCobalt, text: "Codex")
                legendDot(color: RelayBauhausDesign.agySignalGreen, text: "Google AGY")
                legendDot(color: RelayBauhausDesign.vibeOchre, text: "Mistral Vibe")
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(RelayBauhausDesign.claudeVermilion)
                        .frame(width: 14, height: 2.2)
                    Text("Cross-Lane Dependency Arc")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(RelayBauhausDesign.structuralBorder)
                        .frame(width: 14, height: 1.5)
                    Text("Intra-Lane Arc")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.warmSandpaper.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(RelayBauhausDesign.espressoInk)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var isometricBottomCaptionOverlay: some View {
        HStack(spacing: 8) {
            Text("Prism height = LOC & AST declarations · Click any module tower to inspect Ca/Ce/I/D metrics")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RelayBauhausDesign.graphiteInk)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - Isometric Projection Geometry & Shading

    private struct ProjectedPrism {
        let tower: RelayModels.IsometricModuleTower
        let baseCenter: CGPoint
        let roofCenter: CGPoint
        let halfTileW: CGFloat
        let halfTileH: CGFloat
        let extrusionHeight: CGFloat
        let isSelected: Bool
        let isDimmed: Bool
        let hasFenceIntrusion: Bool
    }

    private struct ProjectedIsometricScene {
        let origin: CGPoint
        let tileStepX: CGFloat
        let tileStepY: CGFloat
        let maxCols: Int
        let maxRows: Int
        let sortedPrisms: [ProjectedPrism]
        let prismByPath: [String: ProjectedPrism]
    }

    private func buildProjectedIsometricScene(in size: CGSize) -> ProjectedIsometricScene {
        let tiles = viewModel.isometricTiles
        let maxCol = max(5, (tiles.map(\.gridColumn).max() ?? 5))
        let maxRow = max(2, (tiles.map(\.gridRow).max() ?? 2))

        let stepX = min(78.0, max(54.0, size.width / CGFloat(maxCol + maxRow + 4)))
        let stepY = stepX * 0.50

        // Center the (maxCol + 1) x (maxRow + 1) diamond grid cleanly in the stage
        let gridSpanIndexDiff = CGFloat(maxCol - maxRow) * 0.5
        let originX = (size.width * 0.5) - gridSpanIndexDiff * stepX
        let totalGridVertical = CGFloat(maxCol + maxRow + 2) * stepY
        let originY = max(168.0, (size.height - totalGridVertical) * 0.5 + 88.0)
        let origin = CGPoint(x: originX, y: originY)

        let intrudedPaths = Set(viewModel.boundaryCollisions.map(\.relativePath))

        func isoPoint(col: CGFloat, row: CGFloat) -> CGPoint {
            CGPoint(
                x: origin.x + (col - row) * stepX,
                y: origin.y + (col + row) * stepY
            )
        }

        let orderedTiles = tiles.sorted { lhs, rhs in
            let depthL = lhs.gridColumn + lhs.gridRow
            let depthR = rhs.gridColumn + rhs.gridRow
            if depthL != depthR { return depthL < depthR }
            return lhs.gridColumn < rhs.gridColumn
        }

        var built: [ProjectedPrism] = []
        var byPath: [String: ProjectedPrism] = [:]

        for tile in orderedTiles {
            let center = isoPoint(col: CGFloat(tile.gridColumn) + 0.5, row: CGFloat(tile.gridRow) + 0.5)
            let normalizedLOC = min(1.0, Double(tile.lineCount) / 360.0)
            let normalizedDecl = min(1.0, Double(tile.declarationCount) / 14.0)
            let height = CGFloat(24.0 + normalizedLOC * 56.0 + normalizedDecl * 22.0)
            let roof = CGPoint(x: center.x, y: center.y - height)

            let dimmed: Bool = {
                guard let filter = viewModel.territoryVendorFilter else { return false }
                return tile.activeOwnerVendor != filter
            }()

            let prism = ProjectedPrism(
                tower: tile,
                baseCenter: center,
                roofCenter: roof,
                halfTileW: stepX * 0.62,
                halfTileH: stepY * 0.62,
                extrusionHeight: height,
                isSelected: tile.relativePath == viewModel.selectedIsometricModulePath,
                isDimmed: dimmed,
                hasFenceIntrusion: intrudedPaths.contains(tile.relativePath)
            )
            built.append(prism)
            byPath[tile.relativePath] = prism
        }

        return ProjectedIsometricScene(
            origin: origin,
            tileStepX: stepX,
            tileStepY: stepY,
            maxCols: maxCol + 1,
            maxRows: maxRow + 1,
            sortedPrisms: built,
            prismByPath: byPath
        )
    }

    private func drawPaperDraftingGrid(in context: inout GraphicsContext, size: CGSize) {
        let step: CGFloat = 28
        var bgGrid = Path()
        var x: CGFloat = step
        while x < size.width {
            bgGrid.move(to: CGPoint(x: x, y: 0))
            bgGrid.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = step
        while y < size.height {
            bgGrid.move(to: CGPoint(x: 0, y: y))
            bgGrid.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(bgGrid, with: .color(RelayBauhausDesign.sandstoneStrip.opacity(0.65)), lineWidth: 0.5)
    }

    private func drawIsometricFloorPlatform(in context: inout GraphicsContext, scene: ProjectedIsometricScene) {
        func pt(_ c: CGFloat, _ r: CGFloat) -> CGPoint {
            CGPoint(
                x: scene.origin.x + (c - r) * scene.tileStepX,
                y: scene.origin.y + (c + r) * scene.tileStepY
            )
        }

        let cols = CGFloat(scene.maxCols)
        let rows = CGFloat(scene.maxRows)

        // Warm Sandstone Isometric Plinth Slab
        var slab = Path()
        slab.move(to: pt(-0.25, -0.25))
        slab.addLine(to: pt(cols + 0.25, -0.25))
        slab.addLine(to: pt(cols + 0.25, rows + 0.25))
        slab.addLine(to: pt(-0.25, rows + 0.25))
        slab.closeSubpath()

        context.fill(slab, with: .color(RelayBauhausDesign.sandstoneStrip.opacity(0.55)))
        context.stroke(slab, with: .color(RelayBauhausDesign.structuralBorder), lineWidth: 1.2)

        // Crisp Isometric Grid Lines
        var isoLines = Path()
        for c in 0...scene.maxCols {
            isoLines.move(to: pt(CGFloat(c), 0))
            isoLines.addLine(to: pt(CGFloat(c), rows))
        }
        for r in 0...scene.maxRows {
            isoLines.move(to: pt(0, CGFloat(r)))
            isoLines.addLine(to: pt(cols, CGFloat(r)))
        }
        context.stroke(isoLines, with: .color(RelayBauhausDesign.hairlineBorder), lineWidth: 0.9)
    }

    private func drawIsometricPrismTower(in context: inout GraphicsContext, prism: ProjectedPrism) {
        let cx = prism.baseCenter.x
        let cy = prism.baseCenter.y
        let hw = prism.halfTileW
        let hh = prism.halfTileH
        let h = prism.extrusionHeight

        let topNorth = CGPoint(x: cx, y: cy - hh - h)
        let topEast  = CGPoint(x: cx + hw, y: cy - h)
        let topSouth = CGPoint(x: cx, y: cy + hh - h)
        let topWest  = CGPoint(x: cx - hw, y: cy - h)

        let baseEast  = CGPoint(x: cx + hw, y: cy)
        let baseSouth = CGPoint(x: cx, y: cy + hh)
        let baseWest  = CGPoint(x: cx - hw, y: cy)

        let alpha: Double = prism.isDimmed ? 0.26 : 1.0
        let palette = prismFaceColors(for: prism.tower.activeOwnerVendor)

        // Selection or Fence-Collision Floor Halo
        if prism.isSelected || prism.hasFenceIntrusion {
            let haloW = hw * 1.24
            let haloH = hh * 1.24
            var halo = Path()
            halo.move(to: CGPoint(x: cx, y: cy - haloH))
            halo.addLine(to: CGPoint(x: cx + haloW, y: cy))
            halo.addLine(to: CGPoint(x: cx, y: cy + haloH))
            halo.addLine(to: CGPoint(x: cx - haloW, y: cy))
            halo.closeSubpath()

            let haloColor = prism.isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.claudeVermilion
            context.stroke(
                halo,
                with: .color(haloColor.opacity(alpha)),
                style: StrokeStyle(lineWidth: prism.isSelected ? 2.2 : 1.6, dash: prism.isSelected ? [] : [4, 3])
            )
        }

        // Left Face (West -> South)
        var leftFace = Path()
        leftFace.move(to: topWest)
        leftFace.addLine(to: topSouth)
        leftFace.addLine(to: baseSouth)
        leftFace.addLine(to: baseWest)
        leftFace.closeSubpath()
        context.fill(leftFace, with: .color(palette.left.opacity(alpha)))

        // Right Face (South -> East)
        var rightFace = Path()
        rightFace.move(to: topSouth)
        rightFace.addLine(to: topEast)
        rightFace.addLine(to: baseEast)
        rightFace.addLine(to: baseSouth)
        rightFace.closeSubpath()
        context.fill(rightFace, with: .color(palette.right.opacity(alpha)))

        // Top Roof Diamond
        var roofFace = Path()
        roofFace.move(to: topNorth)
        roofFace.addLine(to: topEast)
        roofFace.addLine(to: topSouth)
        roofFace.addLine(to: topWest)
        roofFace.closeSubpath()
        context.fill(roofFace, with: .color(palette.top.opacity(alpha)))

        // Crisp Architectural Edge Wireframe
        let borderColor = prism.isSelected
            ? RelayBauhausDesign.espressoInk
            : Color(relayHex: "#272522").opacity(0.65 * alpha)
        let borderWidth: CGFloat = prism.isSelected ? 1.8 : 0.95
        context.stroke(leftFace, with: .color(borderColor), lineWidth: borderWidth)
        context.stroke(rightFace, with: .color(borderColor), lineWidth: borderWidth)
        context.stroke(roofFace, with: .color(borderColor), lineWidth: borderWidth)

        // Conflict Beacon Diamond above Roof if Conflicted
        if prism.tower.hasMergeConflict && !prism.isDimmed {
            let bx = topNorth.x
            let by = topNorth.y - 11
            var beacon = Path()
            beacon.move(to: CGPoint(x: bx, y: by - 6))
            beacon.addLine(to: CGPoint(x: bx + 6, y: by))
            beacon.addLine(to: CGPoint(x: bx, y: by + 6))
            beacon.addLine(to: CGPoint(x: bx - 6, y: by))
            beacon.closeSubpath()
            context.fill(beacon, with: .color(RelayBauhausDesign.claudeVermilion))
            context.stroke(beacon, with: .color(RelayBauhausDesign.warmIvory), lineWidth: 1.0)
        }
    }

    private func drawIsometricForegroundLabels(in context: inout GraphicsContext, scene: ProjectedIsometricScene) {
        var placedRects: [CGRect] = []

        // Prioritize selected & conflicted towers first, then perimeter towers, then interior roofs
        let prioritized = scene.sortedPrisms.sorted { lhs, rhs in
            if lhs.isSelected != rhs.isSelected { return lhs.isSelected }
            if lhs.tower.hasMergeConflict != rhs.tower.hasMergeConflict { return lhs.tower.hasMergeConflict }
            let perimL = (lhs.tower.gridRow == scene.maxRows - 1) || (lhs.tower.gridColumn == scene.maxCols - 1)
            let perimR = (rhs.tower.gridRow == scene.maxRows - 1) || (rhs.tower.gridColumn == scene.maxCols - 1)
            if perimL != perimR { return perimL }
            return (lhs.tower.gridColumn + lhs.tower.gridRow) > (rhs.tower.gridColumn + rhs.tower.gridRow)
        }

        for prism in prioritized where !prism.isDimmed {
            let fileStem = (prism.tower.relativePath as NSString).lastPathComponent
            let conciseName = conciseTowerTitle(fileStem)
            let label = Text(conciseName)
                .font(.system(size: 8.0, weight: prism.isSelected ? .bold : .semibold, design: .monospaced))
                .foregroundColor(prism.isSelected ? RelayBauhausDesign.warmIvory : RelayBauhausDesign.espressoInk)

            let isFrontPerimeter = (prism.tower.gridRow == scene.maxRows - 1) || (prism.tower.gridColumn == scene.maxCols - 1)
            let labelPos: CGPoint = isFrontPerimeter
                ? CGPoint(x: prism.baseCenter.x, y: prism.baseCenter.y + prism.halfTileH + 9)
                : CGPoint(x: prism.roofCenter.x, y: prism.roofCenter.y + 1)

            let resolved = context.resolve(label)
            let textSize = resolved.measure(in: CGSize(width: 220, height: 24))
            let pillRect = CGRect(
                x: labelPos.x - textSize.width * 0.5 - 4,
                y: labelPos.y - textSize.height * 0.5 - 1.5,
                width: textSize.width + 8,
                height: textSize.height + 3
            )

            let paddedRect = pillRect.insetBy(dx: -3, dy: -2)
            if !prism.isSelected && placedRects.contains(where: { $0.intersects(paddedRect) }) {
                continue
            }
            placedRects.append(pillRect)

            let pillPath = Path(roundedRect: pillRect, cornerRadius: 3)
            context.fill(
                pillPath,
                with: .color(prism.isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.warmIvory.opacity(0.95))
            )
            context.stroke(
                pillPath,
                with: .color(prism.isSelected ? RelayBauhausDesign.espressoInk : RelayBauhausDesign.structuralBorder),
                lineWidth: 0.85
            )
            context.draw(resolved, at: labelPos, anchor: .center)
        }
    }

    private func drawIsometricCouplingArcs(in context: inout GraphicsContext, scene: ProjectedIsometricScene) {
        for arc in viewModel.isometricCouplingArcs {
            if viewModel.showCrossLaneCouplingOnly && !arc.crossesAgentLanes {
                continue
            }
            guard let src = scene.prismByPath[arc.sourcePath],
                  let dst = scene.prismByPath[arc.targetPath] else {
                continue
            }
            if src.isDimmed && dst.isDimmed {
                continue
            }

            let p0 = src.roofCenter
            let p2 = dst.roofCenter
            let dist = hypot(p2.x - p0.x, p2.y - p0.y)
            let arcLift = min(74.0, max(28.0, dist * 0.34))
            let ctrl = CGPoint(
                x: (p0.x + p2.x) * 0.5,
                y: min(p0.y, p2.y) - arcLift
            )

            var path = Path()
            path.move(to: p0)
            path.addQuadCurve(to: p2, control: ctrl)

            if arc.crossesAgentLanes {
                let width = min(2.8, 1.4 + CGFloat(arc.sharedSymbolCount) * 0.22)
                context.stroke(path, with: .color(RelayBauhausDesign.claudeVermilion.opacity(0.9)), lineWidth: width)

                var startDot = Path()
                startDot.addEllipse(in: CGRect(x: p0.x - 2.5, y: p0.y - 2.5, width: 5, height: 5))
                context.fill(startDot, with: .color(RelayBauhausDesign.claudeVermilion))

                var endDot = Path()
                endDot.addEllipse(in: CGRect(x: p2.x - 3, y: p2.y - 3, width: 6, height: 6))
                context.fill(endDot, with: .color(RelayBauhausDesign.claudeVermilion))
            } else {
                context.stroke(
                    path,
                    with: .color(RelayBauhausDesign.graphiteInk.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 1.15, dash: [4, 3])
                )
            }
        }
    }

    private func hitTestPrism(at point: CGPoint, in scene: ProjectedIsometricScene) -> ProjectedPrism? {
        // Reverse painter's order so foreground towers win clicks first
        for prism in scene.sortedPrisms.reversed() {
            let minX = prism.baseCenter.x - prism.halfTileW
            let maxX = prism.baseCenter.x + prism.halfTileW
            let minY = prism.roofCenter.y - prism.halfTileH
            let maxY = prism.baseCenter.y + prism.halfTileH + 14
            if point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY {
                return prism
            }
        }
        return nil
    }

    private func prismFaceColors(for vendor: AgentVendor?) -> (top: Color, left: Color, right: Color) {
        switch vendor {
        case .claudeCode:
            return (
                top: Color(relayHex: "#F08572"),
                left: Color(relayHex: "#D94E34"),
                right: Color(relayHex: "#9E3320")
            )
        case .codex:
            return (
                top: Color(relayHex: "#6B9BF7"),
                left: Color(relayHex: "#2563EB"),
                right: Color(relayHex: "#1A44A3")
            )
        case .antigravity:
            return (
                top: Color(relayHex: "#4EB878"),
                left: Color(relayHex: "#15803D"),
                right: Color(relayHex: "#0E5729")
            )
        case .mistralVibe:
            return (
                top: Color(relayHex: "#F2A640"),
                left: Color(relayHex: "#D97706"),
                right: Color(relayHex: "#995204")
            )
        case .customShell, .none:
            return (
                top: Color(relayHex: "#DFD9CC"),
                left: Color(relayHex: "#BEB6A5"),
                right: Color(relayHex: "#968E7E")
            )
        }
    }

    private func conciseTowerTitle(_ rawName: String) -> String {
        let stripped = rawName
            .replacingOccurrences(of: ".swift", with: "")
            .replacingOccurrences(of: ".rs", with: "")
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "HTTP3", with: "H3")
            .replacingOccurrences(of: "Manager", with: "Mgr")
            .replacingOccurrences(of: "Multiplexer", with: "Mux")
            .replacingOccurrences(of: "Middleware", with: "MW")
            .replacingOccurrences(of: "Controller", with: "Ctrl")
            .replacingOccurrences(of: "Verifier", with: "Verify")
            .replacingOccurrences(of: "Generator", with: "Gen")
            .replacingOccurrences(of: "Exporter", with: "Export")
            .replacingOccurrences(of: "Connection", with: "Conn")
            .replacingOccurrences(of: "Verification", with: "Verify")
            .replacingOccurrences(of: "Assertions", with: "Assert")
            .replacingOccurrences(of: "ZeroCopy", with: "ZC")
        return stripped
    }

    // MARK: - Right-Hand Robert C. Martin Architecture Metrics & Fence Inspector

    private var martinMetricsAndFenceInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectedModuleMartinCard
            ownershipFenceCollisionCard
        }
    }

    private var selectedModuleMartinCard: some View {
        let tower = viewModel.selectedIsometricTower
        return RelayBauhausCard(padding: 10) {
            if let tower {
                let ca = tower.fanIn
                let ce = tower.fanOut
                let instability = tower.instabilityMetric
                let abstractness = computeAbstractness(for: tower)
                let distanceD = abs(abstractness + instability - 1.0)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if let vendor = tower.activeOwnerVendor {
                            RelayVendorBadge(vendor: vendor)
                        } else {
                            RelayBauhausPill("SHARED CORE", monospaced: true)
                        }
                        Spacer(minLength: 4)
                        RelayBauhausPill(
                            "\(tower.lineCount) LOC · \(tower.declarationCount) decl",
                            foreground: RelayBauhausDesign.graphiteInk,
                            background: RelayBauhausDesign.sandstoneStrip,
                            border: RelayBauhausDesign.hairlineBorder,
                            monospaced: true
                        )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tower.moduleName)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayBauhausDesign.espressoInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(tower.relativePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if tower.hasMergeConflict {
                        Button {
                            viewModel.selectedMergeFilePath = tower.relativePath
                            viewModel.selectPane(.semanticMerge)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Active AST Merge Conflict · Open Merge Studio")
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                            .foregroundStyle(RelayBauhausDesign.warmIvory)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .fill(RelayBauhausDesign.claudeVermilion)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .overlay(RelayBauhausDesign.hairlineBorder)

                    RelaySectionEyebrow(
                        "Robert C. Martin Metrics",
                        trailingText: distanceZoneLabel(distanceD: distanceD, instability: instability, abstractness: abstractness)
                    )

                    // 2x2 Ca / Ce / Instability I / Distance D Grid
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            martinMetricCell(
                                code: "Ca",
                                title: "Afferent In",
                                value: "\(ca)",
                                accent: RelayBauhausDesign.codexCobalt
                            )
                            martinMetricCell(
                                code: "Ce",
                                title: "Efferent Out",
                                value: "\(ce)",
                                accent: RelayBauhausDesign.vibeOchre
                            )
                        }
                        HStack(spacing: 6) {
                            martinMetricCell(
                                code: "I",
                                title: "Instability",
                                value: String(format: "%.2f", instability),
                                accent: RelayBauhausDesign.espressoInk
                            )
                            martinMetricCell(
                                code: "D",
                                title: "Main Seq Dist",
                                value: String(format: "%.2f", distanceD),
                                accent: distanceD > 0.42 ? RelayBauhausDesign.claudeVermilion : RelayBauhausDesign.agySignalGreen
                            )
                        }
                    }

                    // Compact Main Sequence (I vs A) Architectural Plot
                    mainSequenceMiniPlot(instability: instability, abstractness: abstractness)
                }
            }
        }
    }

    private func martinMetricCell(code: String, title: String, value: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Text(code)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(RelayBauhausDesign.sandstoneStrip)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RelayBauhausDesign.mutedStoneInk)
                    .fixedSize(horizontal: true, vertical: false)
                Text(value)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .fill(RelayBauhausDesign.sandstoneStrip.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
        )
    }

    private func mainSequenceMiniPlot(instability: Double, abstractness: Double) -> some View {
        HStack(spacing: 8) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(RelayBauhausDesign.sandstoneStrip.opacity(0.6)))

                // Ideal Main Sequence line from (I=0, A=1) -> (I=1, A=0)
                var diag = Path()
                diag.move(to: CGPoint(x: 6, y: 6))
                diag.addLine(to: CGPoint(x: size.width - 6, y: size.height - 6))
                context.stroke(
                    diag,
                    with: .color(RelayBauhausDesign.agySignalGreen.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1.4, dash: [3, 3])
                )

                let px = 6 + CGFloat(min(1, max(0, instability))) * (size.width - 12)
                let py = (size.height - 6) - CGFloat(min(1, max(0, abstractness))) * (size.height - 12)

                var pt = Path()
                pt.addEllipse(in: CGRect(x: px - 4, y: py - 4, width: 8, height: 8))
                context.fill(pt, with: .color(RelayBauhausDesign.claudeVermilion))
                context.stroke(pt, with: .color(RelayBauhausDesign.warmIvory), lineWidth: 1.2)
            }
            .frame(width: 68, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(RelayBauhausDesign.hairlineBorder, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2.5) {
                Text(String(format: "Abstractness A = %.2f", abstractness))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.espressoInk)
                Text("Ideal corridor: A + I = 1.00")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                Text(String(format: "Coupling Heat: %.0f%%", (viewModel.selectedIsometricTower?.couplingHeat ?? 0) * 100))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayBauhausDesign.claudeVermilion)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Ownership Fence Collision Card

    private var ownershipFenceCollisionCard: some View {
        RelayBauhausCard(
            padding: 10,
            fill: RelayBauhausDesign.warmIvory,
            borderColor: viewModel.boundaryCollisions.isEmpty
                ? RelayBauhausDesign.hairlineBorder
                : RelayBauhausDesign.claudeVermilion.opacity(0.6)
        ) {
            VStack(alignment: .leading, spacing: 7) {
                RelaySectionEyebrow(
                    "Ownership Fence Collisions",
                    trailingText: "\(viewModel.boundaryCollisions.count) active"
                )

                RelayAdaptiveScrollContainer {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(viewModel.boundaryCollisions) { warning in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                                    Text((warning.relativePath as NSString).lastPathComponent)
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(RelayBauhausDesign.espressoInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                HStack(spacing: 5) {
                                    RelayVendorBadge(vendor: warning.intrudingVendor, compact: true)
                                    Text("intruded on")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(RelayBauhausDesign.graphiteInk)
                                    RelayVendorBadge(vendor: warning.rightfulOwnerVendor, compact: true)
                                }

                                Text(warning.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(RelayBauhausDesign.graphiteInk)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button {
                                    viewModel.selectedIsometricModulePath = warning.relativePath
                                } label: {
                                    Text("Focus Module on Isometric Grid")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(RelayBauhausDesign.claudeVermilion)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                                .fill(RelayBauhausDesign.warmIvory)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                                .strokeBorder(RelayBauhausDesign.claudeVermilion.opacity(0.55), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .fill(RelayBauhausDesign.vermilionWash.opacity(0.62))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RelayBauhausDesign.compactRadius, style: .continuous)
                                    .strokeBorder(RelayBauhausDesign.claudeVermilion.opacity(0.45), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func computeAbstractness(for tower: RelayModels.IsometricModuleTower) -> Double {
        let lower = tower.moduleName.lowercased()
        if lower.contains("protocol") || lower.contains("contract") || lower.contains("rfc") {
            return 0.72
        } else if lower.contains("router") || lower.contains("middleware") || lower.contains("manager") {
            return 0.34
        } else if lower.contains("test") || lower.contains("fuzz") {
            return 0.08
        }
        return min(0.65, max(0.14, Double(tower.fanIn) / Double(max(1, tower.fanIn + tower.fanOut + 2)) * 0.75))
    }

    private func distanceZoneLabel(distanceD: Double, instability: Double, abstractness: Double) -> String {
        if distanceD <= 0.25 {
            return "MAIN SEQ"
        } else if instability < 0.4 && abstractness < 0.3 {
            return "RIGID CORE"
        }
        return "DRIFT WATCH"
    }
}
