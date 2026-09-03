//
//  SceneMapExportView.swift
//  CinePlanner
//
//  A non-interactive rendering of a scene map, used for the PDF and web exports
//  and for On-Set mode.
//
//  Split out of SceneMapEditorView.swift, which had grown past 3,700 lines. These
//  are standalone types and helpers, moved unchanged; the editor view itself stays
//  put, since its 49 pieces of @State are private to it and splitting the body
//  would mean opening all of them up.
//

import SwiftUI
import SwiftData

// MARK: - Static export rendering

/// A static, non-interactive rendering of a scene map, used to rasterize a
/// thumbnail for the web/HTML export via `ImageRenderer`. It mirrors the editor
/// canvas — background (or grid), floor plan, furniture, movement arrows and
/// markers — minus every editing affordance (selection rings, handles, drawing
/// overlays). Lives in this file so it can reuse the private `MapMarkerView`
/// and `FurnitureView`.
/// The Apple Maps attribution badge (Apple logo + "Maps"), pinned to the
/// bottom-left of a map rect and sized relative to it — mirrors MapKit's own
/// placement. Shown wherever Apple satellite imagery is displayed or exported, as
/// Apple's map content must carry visible attribution.
/// Shown over satellite backgrounds in the editor as well as in exports.
struct AppleMapsAttribution: View {
    let rect: CGRect

    var body: some View {
        let fontSize = max(5, min(rect.width, rect.height) * 0.0125)
        HStack(spacing: fontSize * 0.35) {
            Image(systemName: "apple.logo")
            Text("Maps")
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, fontSize * 0.55)
        .padding(.vertical, fontSize * 0.28)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .padding(fontSize * 0.6)
        .frame(width: rect.width, height: rect.height, alignment: .bottomLeading)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
}

struct SceneMapExportView: View {
    let doc: SceneMapDoc
    let plan: FloorPlan
    let background: PlatformImage?
    /// Resolved display labels per element id (camera → its shot's number).
    let labels: [UUID: String]
    let size: CGSize
    /// Real-world scale data (see `sceneMarkerScale`); nil = default marker sizes.
    var metersWide: Double? = nil
    var cameraMeters: Double? = nil
    /// When true, markers use the fixed viewable size instead of real-world scale.
    var viewableMarkers: Bool = false
    /// True when the background is an Apple Maps satellite still — shows the
    /// required Apple Maps attribution in the corner of the map (Apple's map
    /// content must carry visible attribution wherever it's displayed/exported).
    var isSatellite: Bool = false

    var body: some View {
        let rect = Self.contentRect(in: size, background: background, hasFloorPlan: !plan.isEmpty)
        ZStack {
            if let background {
                Image(platformImage: background)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            } else {
                Canvas { ctx, _ in Self.drawGrid(ctx, rect) }
            }
            if !plan.isEmpty {
                Canvas { ctx, _ in Self.drawFloorPlan(ctx, plan: plan, in: rect) }
            }
            ForEach(doc.furniture) { item in
                FurnitureView(furniture: item, isSelected: false, contentRect: rect,
                              onSelect: {}, onMove: { _ in }, onRotate: { _ in },
                              onResize: { _, _ in }, onSetColor: { _ in }, onReorder: { _ in },
                              onDuplicate: {}, onDelete: {})
            }
            if !doc.arrows.isEmpty {
                Canvas { ctx, _ in Self.drawArrows(ctx, doc: doc, in: rect) }
            }
            ForEach(doc.elements) { element in
                MapMarkerView(element: element, label: labels[element.id] ?? element.label,
                              isSelected: false, contentRect: rect,
                              onSelect: {}, onMove: { _ in }, onRotate: { _ in },
                              onSetColor: { _ in }, onDelete: {}, onMoveTo: {}, onMoveFrom: {},
                              onMoveLabel: { _ in },
                              scale: sceneMarkerScale(kind: element.kind, metersWide: metersWide,
                                                      cameraMeters: cameraMeters, mapWidthPoints: rect.width,
                                                      viewable: viewableMarkers))
            }
            if isSatellite, background != nil {
                AppleMapsAttribution(rect: rect)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.platformTextBackground)
    }

    /// The rect the normalized coordinates map onto: the background's aspect-fit
    /// rect, a centered square when a floor plan is present, else the whole view.
    /// Mirrors `SceneMapEditorView.contentRect(in:)`.
    static func contentRect(in size: CGSize, background: PlatformImage?, hasFloorPlan: Bool) -> CGRect {
        if let bg = background, bg.size.width > 0, bg.size.height > 0 {
            let imageAspect = bg.size.width / bg.size.height
            let boxAspect = size.width / max(size.height, 1)
            var w = size.width, h = size.height
            if imageAspect > boxAspect { h = w / imageAspect } else { w = h * imageAspect }
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }
        if hasFloorPlan {
            let side = min(size.width, size.height)
            return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        }
        return CGRect(origin: .zero, size: size)
    }

    private static func canvasPoint(_ nx: Double, _ ny: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(nx) * rect.width, y: rect.minY + CGFloat(ny) * rect.height)
    }

    private static func unit(_ v: CGPoint) -> CGPoint {
        let m = hypot(v.x, v.y)
        return m > 0 ? CGPoint(x: v.x / m, y: v.y / m) : CGPoint(x: 1, y: 0)
    }

    private static func drawGrid(_ ctx: GraphicsContext, _ rect: CGRect) {
        let step: CGFloat = 40
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
        var y = rect.minY
        while y <= rect.maxY { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
        ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
    }

    /// Walls with gaps, plus door swing arcs and window symbols. Mirrors the
    /// non-interactive parts of `SceneMapEditorView.drawFloorPlan(_:in:)`.
    private static func drawFloorPlan(_ ctx: GraphicsContext, plan: FloorPlan, in rect: CGRect) {
        func point(_ nx: Double, _ ny: Double) -> CGPoint { canvasPoint(nx, ny, in: rect) }
        let wallShading = GraphicsContext.Shading.color(.primary.opacity(0.85))
        for wall in plan.walls {
            guard let (a, b) = plan.endpoints(wall) else { continue }
            let p1 = point(a.x, a.y), p2 = point(b.x, b.y)
            func lerp(_ t: Double) -> CGPoint {
                CGPoint(x: p1.x + CGFloat(t) * (p2.x - p1.x), y: p1.y + CGFloat(t) * (p2.y - p1.y))
            }
            let wallLen = max(plan.length(wall), 1e-6)
            let wallOpenings = plan.openings.filter { $0.wallID == wall.id }
            let gaps = wallOpenings
                .map { o -> (Double, Double) in
                    let half = min((o.width / 2) / wallLen, 0.49)
                    return (max(0, o.t - half), min(1, o.t + half))
                }
                .sorted { $0.0 < $1.0 }
            var solid = Path()
            var cursor = 0.0
            for gap in gaps {
                if gap.0 > cursor { solid.move(to: lerp(cursor)); solid.addLine(to: lerp(gap.0)) }
                cursor = max(cursor, gap.1)
            }
            if cursor < 1.0 { solid.move(to: lerp(cursor)); solid.addLine(to: lerp(1.0)) }
            ctx.stroke(solid, with: wallShading, style: StrokeStyle(lineWidth: 4, lineCap: .round))

            let dir = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            for o in wallOpenings {
                let half = min((o.width / 2) / wallLen, 0.49)
                let jambA = lerp(max(0, o.t - half))
                let jambB = lerp(min(1, o.t + half))
                switch o.kind {
                case .door:
                    let gapLen = hypot(jambB.x - jambA.x, jambB.y - jambA.y)
                    let hinge = o.hingeAtEnd ? jambB : jambA
                    let alongWall = o.hingeAtEnd ? CGPoint(x: -dir.x, y: -dir.y) : dir
                    let swingPerp = o.flipped ? CGPoint(x: -perp.x, y: -perp.y) : perp
                    let openAngle = o.closed ? (10.0 * .pi / 180.0) : (.pi / 2)
                    func leafDir(_ phi: Double) -> CGPoint {
                        CGPoint(x: alongWall.x * CGFloat(cos(phi)) + swingPerp.x * CGFloat(sin(phi)),
                                y: alongWall.y * CGFloat(cos(phi)) + swingPerp.y * CGFloat(sin(phi)))
                    }
                    let ld = leafDir(openAngle)
                    let leafEnd = CGPoint(x: hinge.x + ld.x * gapLen, y: hinge.y + ld.y * gapLen)
                    var leaf = Path(); leaf.move(to: hinge); leaf.addLine(to: leafEnd)
                    ctx.stroke(leaf, with: wallShading, lineWidth: 1.5)
                    var arc = Path()
                    for i in 0...16 {
                        let d = leafDir(openAngle * Double(i) / 16)
                        let pt = CGPoint(x: hinge.x + d.x * gapLen, y: hinge.y + d.y * gapLen)
                        if i == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
                    }
                    ctx.stroke(arc, with: .color(.secondary), lineWidth: 1)
                case .window:
                    for sign in [CGFloat(1.6), CGFloat(-1.6)] {
                        var line = Path()
                        line.move(to: CGPoint(x: jambA.x + perp.x * sign, y: jambA.y + perp.y * sign))
                        line.addLine(to: CGPoint(x: jambB.x + perp.x * sign, y: jambB.y + perp.y * sign))
                        ctx.stroke(line, with: wallShading, lineWidth: 1.4)
                    }
                }
            }
        }
    }

    /// Movement arrows: smooth shaft with a solid triangular head. Mirrors
    /// `SceneMapEditorView.drawArrows(_:in:)`.
    private static func drawArrows(_ ctx: GraphicsContext, doc: SceneMapDoc, in rect: CGRect) {
        let lineWidth: CGFloat = 6
        for arrow in doc.arrows {
            guard let from = doc.elements.first(where: { $0.id == arrow.fromID }),
                  let to = doc.elements.first(where: { $0.id == arrow.toID }) else { continue }
            var pts = [canvasPoint(from.x, from.y, in: rect)]
            pts += arrow.pivots.map { canvasPoint($0.x, $0.y, in: rect) }
            pts.append(canvasPoint(to.x, to.y, in: rect))
            guard pts.count >= 2 else { continue }
            let shading = GraphicsContext.Shading.color(Color(hex: from.colorHex))
            let n = pts.count
            let ds = unit(CGPoint(x: pts[1].x - pts[0].x, y: pts[1].y - pts[0].y))
            pts[0] = CGPoint(x: pts[0].x + ds.x * 20, y: pts[0].y + ds.y * 20)
            let de = unit(CGPoint(x: pts[n - 1].x - pts[n - 2].x, y: pts[n - 1].y - pts[n - 2].y))
            pts[n - 1] = CGPoint(x: pts[n - 1].x - de.x * 22, y: pts[n - 1].y - de.y * 22)
            let tip = pts[n - 1]
            let headLength: CGFloat = 20, headHalfWidth: CGFloat = 11
            let baseCenter = CGPoint(x: tip.x - de.x * headLength, y: tip.y - de.y * headLength)
            var shaftPts = pts
            shaftPts[n - 1] = baseCenter
            ctx.stroke(smoothPolyline(shaftPts), with: shading,
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            let perp = CGPoint(x: -de.y, y: de.x)
            var head = Path()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: baseCenter.x + perp.x * headHalfWidth, y: baseCenter.y + perp.y * headHalfWidth))
            head.addLine(to: CGPoint(x: baseCenter.x - perp.x * headHalfWidth, y: baseCenter.y - perp.y * headHalfWidth))
            head.closeSubpath()
            ctx.fill(head, with: shading)
        }
    }
}
