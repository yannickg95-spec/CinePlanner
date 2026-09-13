//
//  SceneMapFurniture.swift
//  CinePlanner
//
//  The scene map's furniture pieces: their glyphs, the drawing helpers behind
//  them, and the draggable view that places one on the map.
//
//  Split out of SceneMapEditorView.swift, which had grown past 3,700 lines. These
//  are standalone types and helpers, moved unchanged; the editor view itself stays
//  put, since its 49 pieces of @State are private to it and splitting the body
//  would mean opening all of them up.
//

import SwiftUI
import SwiftData

/// Layer-stack reordering of a furniture piece (its z-order on the map).
enum FurnitureLayerMove { case toFront, forward, backward, toBack }

/// Draws a furniture piece as a top-down floor-plan silhouette (fill + outline,
/// with light interior detail lines), sized to `size`, tinted by `fill`/`stroke`.
private struct FurnitureGlyph: View {
    let kind: Furniture.Kind
    let size: CGSize
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat
    /// Live magnification this glyph will undergo (map placement scale × canvas
    /// zoom). The Canvas is drawn that many times larger and scaled back down, so it
    /// rasterizes at the final on-screen resolution instead of a blurry, magnified
    /// 1× bitmap. Capped so the backing bitmap stays bounded at extreme zoom.
    var renderScale: CGFloat = 1

    var body: some View {
        let k = min(max(renderScale, 1), 8)
        Canvas { context, canvasSize in
            var ctx = context
            drawFurniture(kind, in: CGRect(origin: .zero, size: canvasSize),
                          into: &ctx, fill: fill, stroke: stroke, lineWidth: lineWidth * k)
        }
        // Render k× larger, then scale back: the layout stays `size`, but the raster
        // is drawn at k× so the parent group's scaleEffect has real pixels to show.
        .frame(width: size.width * k, height: size.height * k)
        .scaleEffect(1 / k)
        .frame(width: size.width, height: size.height)
    }
}

private func furnitureRoundedPath(_ r: CGRect, _ radius: CGFloat) -> Path {
    Path(roundedRect: r, cornerRadius: radius)
}

/// A row of cushion outlines inside `rect` — shared by the sofa's back and seat.
private func drawFurnitureCushions(_ rect: CGRect, count: Int, into ctx: inout GraphicsContext,
                                   shade: GraphicsContext.Shading, lineWidth lw: CGFloat) {
    guard count > 0, rect.width > 2, rect.height > 2 else { return }
    let cw = rect.width / CGFloat(count)
    for i in 0..<count {
        let c = CGRect(x: rect.minX + CGFloat(i) * cw, y: rect.minY, width: cw, height: rect.height)
            .insetBy(dx: 1.5, dy: 0.5)
        ctx.stroke(furnitureRoundedPath(c, min(c.width, c.height) * 0.25), with: shade, lineWidth: lw)
    }
}

/// Aputure STORM-style point-source monolight from directly above (used for both the
/// 700x and the 80C): a rounded-square body carried between two short yoke arms with
/// round tilt knobs, a ProLock collar on the front edge, and a reflector that tapers
/// from the wide collar to a narrower front. A three-line control strip sits high on
/// the body and a connector at the centre-back. Front = up at 0°, so rotating the
/// piece aims the light. `reflectorDepth` is the fraction of the piece's length taken
/// by the reflector, so each fixture's real housing/reflector proportions can be set.
private func drawStormMonolight(_ rect: CGRect, reflectorDepth: CGFloat = 0.44,
                                reflectorFrontHalf: CGFloat = 0.28,
                                reflectorBaseHalf: CGFloat = 0.14,
                                into ctx: inout GraphicsContext,
                                fill: GraphicsContext.Shading, deepFill: GraphicsContext.Shading,
                                stroke: GraphicsContext.Shading, detail: GraphicsContext.Shading,
                                lineWidth lw: CGFloat) {
    // Geometry is expressed as fractions of the piece's bounding box.
    func X(_ f: CGFloat) -> CGFloat { rect.minX + f * rect.width }
    func Y(_ f: CGFloat) -> CGFloat { rect.minY + f * rect.height }
    func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: X(x0), y: Y(y0), width: (x1 - x0) * rect.width, height: (y1 - y0) * rect.height)
    }
    let unit = min(rect.width, rect.height)
    let mid: CGFloat = 0.5

    // Reflector flares from the collar (base, at the body) out to the front mouth,
    // each as a half-width fraction of the piece.
    let baseHalf = reflectorBaseHalf       // at the collar
    let frontHalf = reflectorFrontHalf     // at the front mouth
    let reflDepth = min(max(reflectorDepth, 0.1), 0.7)
    // The reflector sits in front of the housing, with a collar band between them; the
    // housing occupies the rest, the connector poking out the back.
    let collarGap: CGFloat = 0.025
    let bodyY0 = reflDepth + collarGap
    let bodyY1: CGFloat = 0.95
    let bodyH = bodyY1 - bodyY0

    // Reflector.
    var hood = Path()
    hood.move(to: CGPoint(x: X(mid - frontHalf), y: Y(0)))
    hood.addLine(to: CGPoint(x: X(mid + frontHalf), y: Y(0)))
    hood.addLine(to: CGPoint(x: X(mid + baseHalf), y: Y(reflDepth)))
    hood.addLine(to: CGPoint(x: X(mid - baseHalf), y: Y(reflDepth)))
    hood.closeSubpath()
    ctx.fill(hood, with: deepFill)
    ctx.stroke(hood, with: stroke, lineWidth: lw)

    // Yoke arms — thin bars down each side, just outside the housing.
    let armY0 = bodyY0 + bodyH * 0.12
    let armY1 = bodyY1 - bodyH * 0.12
    for xs in [(CGFloat(0.06), CGFloat(0.135)), (CGFloat(0.865), CGFloat(0.94))] {
        let arm = furnitureRoundedPath(box(xs.0, armY0, xs.1, armY1), unit * 0.02)
        ctx.fill(arm, with: fill)
        ctx.stroke(arm, with: stroke, lineWidth: lw)
    }

    // Body — the housing, inset so the yoke arms show at the sides.
    let bodyPath = furnitureRoundedPath(box(0.135, bodyY0, 0.865, bodyY1), unit * 0.075)
    ctx.fill(bodyPath, with: fill)
    ctx.stroke(bodyPath, with: stroke, lineWidth: lw)

    // ProLock collar — the band between the reflector base and the housing.
    let collarRect = box(mid - baseHalf, reflDepth - 0.004, mid + baseHalf, bodyY0 + 0.012)
    ctx.fill(furnitureRoundedPath(collarRect, collarRect.height * 0.35), with: fill)
    ctx.stroke(furnitureRoundedPath(collarRect, collarRect.height * 0.35), with: stroke, lineWidth: lw)

    // Round tilt knobs at the outer ends of the yoke arms.
    let knobR = unit * 0.05
    let knobY = (bodyY0 + bodyY1) / 2
    for cx in [X(0.04), X(0.96)] {
        let knob = CGRect(x: cx - knobR, y: Y(knobY) - knobR, width: knobR * 2, height: knobR * 2)
        ctx.fill(Path(ellipseIn: knob), with: fill)
        ctx.stroke(Path(ellipseIn: knob), with: stroke, lineWidth: lw)
    }

    // Three-line control strip, on the upper half of the housing.
    var strip = Path()
    for k in 0..<3 {
        let fy = bodyY0 + bodyH * (0.28 + CGFloat(k) * 0.13)
        strip.move(to: CGPoint(x: X(0.27), y: Y(fy)))
        strip.addLine(to: CGPoint(x: X(0.73), y: Y(fy)))
    }
    ctx.stroke(strip, with: detail, lineWidth: lw * 0.6)

    // Connector poking out the centre-back.
    let plugRect = box(0.44, bodyY1 - 0.01, 0.56, 1.0)
    ctx.fill(furnitureRoundedPath(plugRect, plugRect.height * 0.25), with: stroke)
}

/// Aputure STORM CS32-style fixture from directly above, following the shared design:
/// a big rounded body carried between two yoke arms with tilt knobs, a reflector hood
/// flaring out the front, a control strip across the back of the body and a connector
/// at its back corner. Front = up at 0°, so rotating the piece aims the light.
private func drawStormCS32(_ rect: CGRect, into ctx: inout GraphicsContext,
                           fill: GraphicsContext.Shading, deepFill: GraphicsContext.Shading,
                           stroke: GraphicsContext.Shading, detail: GraphicsContext.Shading,
                           lineWidth lw: CGFloat) {
    // Geometry is expressed as fractions of the piece's bounding box.
    func X(_ f: CGFloat) -> CGFloat { rect.minX + f * rect.width }
    func Y(_ f: CGFloat) -> CGFloat { rect.minY + f * rect.height }
    func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: X(x0), y: Y(y0), width: (x1 - x0) * rect.width, height: (y1 - y0) * rect.height)
    }
    let unit = min(rect.width, rect.height)

    // Reflector hood, flaring toward the front.
    var hood = Path()
    hood.move(to: CGPoint(x: X(0.178), y: Y(0.000)))
    hood.addLine(to: CGPoint(x: X(0.786), y: Y(0.000)))
    hood.addLine(to: CGPoint(x: X(0.710), y: Y(0.472)))
    hood.addLine(to: CGPoint(x: X(0.298), y: Y(0.472)))
    hood.closeSubpath()
    ctx.fill(hood, with: deepFill)
    ctx.stroke(hood, with: stroke, lineWidth: lw)

    // Yoke arms down each side, behind the body.
    for xs in [(CGFloat(0.081), CGFloat(0.155)), (CGFloat(0.852), CGFloat(0.929))] {
        let arm = furnitureRoundedPath(box(xs.0, 0.528, xs.1, 0.950), unit * 0.03)
        ctx.fill(arm, with: fill)
        ctx.stroke(arm, with: stroke, lineWidth: lw)
    }

    // Body.
    let bodyPath = furnitureRoundedPath(box(0.155, 0.495, 0.852, 0.968), unit * 0.07)
    ctx.fill(bodyPath, with: fill)
    ctx.stroke(bodyPath, with: stroke, lineWidth: lw)

    // Mount lip where the hood meets the body.
    let lipRect = box(0.282, 0.472, 0.715, 0.499)
    let lip = furnitureRoundedPath(lipRect, lipRect.height * 0.4)
    ctx.fill(lip, with: fill)
    ctx.stroke(lip, with: stroke, lineWidth: lw)

    // Tilt knobs on the yoke.
    let knobR = unit * 0.053
    for cx in [X(0.053), X(0.947)] {
        let knob = CGRect(x: cx - knobR, y: Y(0.706) - knobR, width: knobR * 2, height: knobR * 2)
        ctx.fill(Path(ellipseIn: knob), with: fill)
        ctx.stroke(Path(ellipseIn: knob), with: stroke, lineWidth: lw)
    }

    // Control strip across the back of the body.
    var strip = Path()
    for fy in [CGFloat(0.856), CGFloat(0.887), CGFloat(0.917)] {
        strip.move(to: CGPoint(x: X(0.239), y: Y(fy)))
        strip.addLine(to: CGPoint(x: X(0.761), y: Y(fy)))
    }
    ctx.stroke(strip, with: detail, lineWidth: lw * 0.6)

    // Connector at the back corner.
    let plugRect = box(0.234, 0.957, 0.354, 1.000)
    ctx.fill(furnitureRoundedPath(plugRect, plugRect.height * 0.25), with: stroke)
}

/// Top-down silhouette per furniture kind, drawn into `rect`.
private func drawFurniture(_ kind: Furniture.Kind, in rect: CGRect, into ctx: inout GraphicsContext,
                           fill: Color, stroke: Color, lineWidth lw: CGFloat) {
    // Opaque light tint so furniture occludes the map/background behind it, with
    // the darker outline and detail lines still reading on top.
    let solidFill = fill.mixedWithWhite(0.72)
    let fillC = GraphicsContext.Shading.color(solidFill)
    // A deeper tint for recessed parts (e.g. a reflector hood).
    let deepFillC = GraphicsContext.Shading.color(fill.mixedWithWhite(0.42))
    let strokeC = GraphicsContext.Shading.color(stroke)
    let detailC = GraphicsContext.Shading.color(stroke.opacity(0.55))
    let w = rect.width, h = rect.height
    func rr(_ r: CGRect, _ rad: CGFloat) -> Path { furnitureRoundedPath(r, rad) }

    switch kind {
    case .sofa:
        let rad = min(w, h) * 0.18
        let body = rr(rect, rad)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        let arm = min(w * 0.15, h * 0.42)
        let back = min(h * 0.34, w * 0.34)
        let seatTop = rect.minY + back
        let inner = CGRect(x: rect.minX + arm, y: rect.minY, width: w - 2 * arm, height: h)
        let backRect = CGRect(x: inner.minX, y: rect.minY + h * 0.06, width: inner.width, height: back - h * 0.08).insetBy(dx: 2, dy: 0)
        drawFurnitureCushions(backRect, count: 2, into: &ctx, shade: detailC, lineWidth: lw * 0.7)
        var arms = Path()
        arms.move(to: CGPoint(x: rect.minX + arm, y: seatTop)); arms.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY - h * 0.08))
        arms.move(to: CGPoint(x: rect.maxX - arm, y: seatTop)); arms.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY - h * 0.08))
        ctx.stroke(arms, with: detailC, lineWidth: lw * 0.8)
        let seatRect = CGRect(x: inner.minX, y: seatTop, width: inner.width, height: rect.maxY - seatTop - h * 0.06).insetBy(dx: 2, dy: 1)
        drawFurnitureCushions(seatRect, count: 2, into: &ctx, shade: detailC, lineWidth: lw * 0.7)

    case .bed:
        let rad = min(w, h) * 0.10
        let body = rr(rect, rad)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        let head = h * 0.10
        var hb = Path()
        hb.move(to: CGPoint(x: rect.minX, y: rect.minY + head)); hb.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + head))
        ctx.stroke(hb, with: detailC, lineWidth: lw * 0.8)
        let pillowH = h * 0.16
        let pad = w * 0.08
        let pillowW = (w - 3 * pad) / 2
        for i in 0..<2 {
            let p = CGRect(x: rect.minX + pad + CGFloat(i) * (pillowW + pad), y: rect.minY + head + h * 0.05, width: pillowW, height: pillowH)
            ctx.stroke(rr(p, pillowH * 0.35), with: detailC, lineWidth: lw * 0.7)
        }
        var fold = Path()
        let foldY = rect.minY + head + pillowH + h * 0.14
        fold.move(to: CGPoint(x: rect.minX, y: foldY)); fold.addLine(to: CGPoint(x: rect.maxX, y: foldY))
        ctx.stroke(fold, with: detailC, lineWidth: lw * 0.8)

    case .chair:
        let rad = min(w, h) * 0.18
        let seat = rect.insetBy(dx: w * 0.04, dy: h * 0.04)
        let seatBody = rr(CGRect(x: seat.minX, y: seat.minY + h * 0.14, width: seat.width, height: seat.height - h * 0.14), rad)
        ctx.fill(seatBody, with: fillC)
        ctx.stroke(seatBody, with: strokeC, lineWidth: lw)
        let backBar = rr(CGRect(x: rect.minX + w * 0.06, y: rect.minY, width: w - w * 0.12, height: h * 0.20), min(w, h) * 0.12)
        ctx.fill(backBar, with: fillC)
        ctx.stroke(backBar, with: strokeC, lineWidth: lw)

    case .table:
        let rad = min(w, h) * 0.10
        let body = rr(rect, rad)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        ctx.stroke(rr(rect.insetBy(dx: w * 0.10, dy: h * 0.12), rad * 0.7), with: detailC, lineWidth: lw * 0.7)

    case .roundTable:
        let d = min(w, h)
        let c = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        ctx.fill(Path(ellipseIn: c), with: fillC)
        ctx.stroke(Path(ellipseIn: c), with: strokeC, lineWidth: lw)
        ctx.stroke(Path(ellipseIn: c.insetBy(dx: d * 0.14, dy: d * 0.14)), with: detailC, lineWidth: lw * 0.7)

    case .rug:
        let rad = min(w, h) * 0.05
        let body = rr(rect, rad)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        ctx.stroke(rr(rect.insetBy(dx: w * 0.06, dy: h * 0.08), rad), with: detailC, lineWidth: lw * 0.7)
        ctx.stroke(rr(rect.insetBy(dx: w * 0.12, dy: h * 0.16), rad), with: detailC, lineWidth: lw * 0.6)

    case .plant:
        let d = min(w, h)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let lobes = 7
        let R = d * 0.5
        // Solid centre + lobes for a filled shape; stroke only the lobes for a
        // scalloped, leafy edge.
        var fillPath = Path()
        fillPath.addEllipse(in: CGRect(x: c.x - R * 0.66, y: c.y - R * 0.66, width: R * 1.32, height: R * 1.32))
        var lobePath = Path()
        for i in 0..<lobes {
            let a = CGFloat(i) / CGFloat(lobes) * 2 * .pi
            let lc = CGPoint(x: c.x + cos(a) * R * 0.58, y: c.y + sin(a) * R * 0.58)
            let e = CGRect(x: lc.x - R * 0.42, y: lc.y - R * 0.42, width: R * 0.84, height: R * 0.84)
            fillPath.addEllipse(in: e)
            lobePath.addEllipse(in: e)
        }
        ctx.fill(fillPath, with: fillC)
        ctx.stroke(lobePath, with: strokeC, lineWidth: lw * 0.8)
        let pot = CGRect(x: c.x - d * 0.16, y: c.y - d * 0.16, width: d * 0.32, height: d * 0.32)
        ctx.fill(Path(ellipseIn: pot), with: fillC)
        ctx.stroke(Path(ellipseIn: pot), with: detailC, lineWidth: lw * 0.7)

    case .smallLight:
        // Aputure STORM 80C, matching the reference top view: 42 cm total, reflector
        // ≈20 cm of it (20/42), flaring wide at the mouth to a narrower collar.
        drawStormMonolight(rect, reflectorDepth: 20.0 / 42.0,
                           reflectorFrontHalf: 0.30, reflectorBaseHalf: 0.206,
                           into: &ctx, fill: fillC, deepFill: deepFillC,
                           stroke: strokeC, detail: detailC, lineWidth: lw)

    case .mediumLight:
        // Aputure STORM 700x.
        drawStormMonolight(rect, reflectorDepth: 0.44, into: &ctx, fill: fillC, deepFill: deepFillC,
                           stroke: strokeC, detail: detailC, lineWidth: lw)

    case .bigLight:
        drawStormCS32(rect, into: &ctx, fill: fillC, deepFill: deepFillC,
                      stroke: strokeC, detail: detailC, lineWidth: lw)

    case .lightBall:
        // China ball / space light from above: a sphere with a concentric ring
        // and a faint frame cross. Non-directional.
        let d = min(w, h), c = CGPoint(x: rect.midX, y: rect.midY), R = d * 0.5
        let outer = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        ctx.fill(Path(ellipseIn: outer), with: fillC)
        ctx.stroke(Path(ellipseIn: outer), with: strokeC, lineWidth: lw)
        ctx.stroke(Path(ellipseIn: outer.insetBy(dx: R * 0.5, dy: R * 0.5)), with: detailC, lineWidth: lw * 0.7)
        var frame = Path()
        frame.move(to: CGPoint(x: c.x - R, y: c.y)); frame.addLine(to: CGPoint(x: c.x + R, y: c.y))
        frame.move(to: CGPoint(x: c.x, y: c.y - R)); frame.addLine(to: CGPoint(x: c.x, y: c.y + R))
        ctx.stroke(frame, with: detailC, lineWidth: lw * 0.5)

    case .par:
        // PAR can from above: a round can with a yoke hugging the sides and a lens.
        let d = min(w, h), c = CGPoint(x: rect.midX, y: rect.midY), R = d * 0.40
        let can = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        // Yoke arms wrapping the sides.
        ctx.stroke(Path(ellipseIn: can.insetBy(dx: -d * 0.08, dy: -d * 0.08)), with: detailC, lineWidth: lw * 0.8)
        ctx.fill(Path(ellipseIn: can), with: fillC)
        ctx.stroke(Path(ellipseIn: can), with: strokeC, lineWidth: lw)
        ctx.stroke(Path(ellipseIn: can.insetBy(dx: R * 0.30, dy: R * 0.30)), with: detailC, lineWidth: lw * 0.8)
        ctx.fill(Path(ellipseIn: can.insetBy(dx: R * 0.66, dy: R * 0.66)), with: detailC)

    case .practical:
        // A real in-scene lamp from above: a shade ring with a lit bulb centre.
        let d = min(w, h), c = CGPoint(x: rect.midX, y: rect.midY), R = d * 0.42
        let shade = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        ctx.fill(Path(ellipseIn: shade), with: fillC)
        ctx.stroke(Path(ellipseIn: shade), with: strokeC, lineWidth: lw)
        ctx.stroke(Path(ellipseIn: shade.insetBy(dx: R * 0.30, dy: R * 0.30)), with: detailC, lineWidth: lw * 0.7)
        ctx.fill(Path(ellipseIn: shade.insetBy(dx: R * 0.62, dy: R * 0.62)), with: detailC)

    case .tube:
        // LED tube from above: a long capsule with end caps and a centre line.
        let body = rr(rect, min(w, h) * 0.5)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        var caps = Path()
        caps.move(to: CGPoint(x: rect.minX + w * 0.06, y: rect.minY)); caps.addLine(to: CGPoint(x: rect.minX + w * 0.06, y: rect.maxY))
        caps.move(to: CGPoint(x: rect.maxX - w * 0.06, y: rect.minY)); caps.addLine(to: CGPoint(x: rect.maxX - w * 0.06, y: rect.maxY))
        caps.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.midY)); caps.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.midY))
        ctx.stroke(caps, with: detailC, lineWidth: lw * 0.7)

    case .bounce:
        // Reflector board from above: the piece IS a thin board, so fill the whole
        // rect as a rounded bar with a reflective (hatched) face.
        let boardPath = rr(rect, min(w, h) * 0.5)
        ctx.fill(boardPath, with: fillC)
        ctx.stroke(boardPath, with: strokeC, lineWidth: lw)
        var hatch = Path()
        let step = max(w * 0.06, 4)
        var x = rect.minX + step
        while x < rect.maxX {
            hatch.move(to: CGPoint(x: x, y: rect.minY))
            hatch.addLine(to: CGPoint(x: x - h, y: rect.maxY))
            x += step
        }
        var clipped = ctx
        clipped.clip(to: boardPath)
        clipped.stroke(hatch, with: detailC, lineWidth: lw * 0.6)

    case .softbox:
        // Softbox from above: a trapezoid tapering from the lamp (back) to the wide
        // diffusion face (front, up), with the lamp shown at the back.
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let frontHalf = w * 0.46, backHalf = w * 0.18
        let frontY = rect.minY + h * 0.12, backY = rect.maxY - h * 0.16
        var box = Path()
        box.move(to: CGPoint(x: c.x - frontHalf, y: frontY))
        box.addLine(to: CGPoint(x: c.x + frontHalf, y: frontY))
        box.addLine(to: CGPoint(x: c.x + backHalf, y: backY))
        box.addLine(to: CGPoint(x: c.x - backHalf, y: backY))
        box.closeSubpath()
        ctx.fill(box, with: fillC)
        ctx.stroke(box, with: strokeC, lineWidth: lw)
        var face = Path()
        face.move(to: CGPoint(x: c.x - frontHalf, y: frontY)); face.addLine(to: CGPoint(x: c.x + frontHalf, y: frontY))
        ctx.stroke(face, with: detailC, lineWidth: lw * 1.3)
        let lampR = w * 0.055
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - lampR, y: backY - lampR * 1.6, width: lampR * 2, height: lampR * 2)), with: detailC)

    case .lightPanel:
        // Flat LED panel from above: a thin wide panel (emitting from the front, up)
        // with an LED grid, on a small stand behind it.
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let panel = CGRect(x: rect.minX + w * 0.06, y: rect.minY + h * 0.16, width: w * 0.88, height: h * 0.40)
        let panelPath = rr(panel, min(panel.width, panel.height) * 0.14)
        ctx.fill(panelPath, with: fillC)
        ctx.stroke(panelPath, with: strokeC, lineWidth: lw)
        var grid = Path()
        let cols = 4
        for i in 1..<cols {
            let gx = panel.minX + panel.width * CGFloat(i) / CGFloat(cols)
            grid.move(to: CGPoint(x: gx, y: panel.minY)); grid.addLine(to: CGPoint(x: gx, y: panel.maxY))
        }
        grid.move(to: CGPoint(x: panel.minX, y: panel.midY)); grid.addLine(to: CGPoint(x: panel.maxX, y: panel.midY))
        var clip = ctx
        clip.clip(to: panelPath)
        clip.stroke(grid, with: detailC, lineWidth: lw * 0.6)
        var stand = Path()
        stand.move(to: CGPoint(x: c.x, y: panel.maxY)); stand.addLine(to: CGPoint(x: c.x, y: rect.maxY - h * 0.08))
        ctx.stroke(stand, with: detailC, lineWidth: lw)
    }
}

struct FurnitureView: View {
    let furniture: Furniture
    let isSelected: Bool
    let contentRect: CGRect
    /// Counter-scales the label by 1/zoom so it stays a constant on-screen size.
    var zoom: CGFloat = 1
    /// Map placement (see `SceneMapBackgroundTransform`): the glyph rides it via the
    /// parent group; the label and handles are countered so they stay upright and a
    /// constant on-screen size.
    var placeScale: CGFloat = 1
    var placeRotation: Double = 0
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onRotate: (Double) -> Void
    let onResize: (Double, Double) -> Void
    let onSetColor: (String) -> Void
    let onReorder: (FurnitureLayerMove) -> Void
    let onDuplicate: () -> Void
    var onEditLabel: () -> Void = {}
    /// Reports the label's new nudge (canvas points) once its drag ends.
    var onMoveLabel: (CGSize) -> Void = { _ in }
    /// Real-world metres spanning the (square) measured background; nil = unmeasured
    /// (no dimensions shown while resizing).
    var metersWide: Double? = nil
    let onDelete: () -> Void

    @State private var livePosition: CGPoint?
    @State private var grabOffset: CGSize = .zero
    @State private var liveRotation: Double?
    @State private var liveSize: CGSize?
    /// Live label nudge while the label is being dragged; `nil` otherwise.
    @State private var liveLabelOffset: CGSize?
    /// Pointer-to-label offset captured when the label drag begins.
    @State private var labelGrab: CGSize = .zero

    /// Farthest a label's centre may sit from its default spot (canvas points).
    private static let labelMaxDistance: CGFloat = 80

    private var color: Color { Color(hex: furniture.colorHex) }
    private var displayRotation: Double { liveRotation ?? furniture.rotation }
    private var center: CGPoint {
        CGPoint(x: contentRect.minX + furniture.x * contentRect.width,
                y: contentRect.minY + furniture.y * contentRect.height)
    }
    private var sizePts: CGSize {
        liveSize ?? CGSize(width: CGFloat(furniture.width) * contentRect.width,
                           height: CGFloat(furniture.height) * contentRect.height)
    }
    var body: some View {
        let w = max(sizePts.width, 8), h = max(sizePts.height, 8)
        ZStack {
            FurnitureGlyph(kind: furniture.kind, size: CGSize(width: w, height: h),
                           fill: color, stroke: isSelected ? Color.accentColor : color,
                           lineWidth: isSelected ? 2.5 : 2,
                           renderScale: zoom * placeScale)
                .contentShape(Rectangle())
                .rotationEffect(.degrees(displayRotation))
                .onTapGesture { onSelect() }
                .gesture(dragGesture)
                .contextMenu { menu }
            if !furniture.label.isEmpty {
                let nudge = liveLabelOffset ?? furniture.labelOffset
                Text(furniture.label)
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.regularMaterial, in: Capsule())
                    .scaleEffect(1 / (zoom * placeScale), anchor: .top)
                    .rotationEffect(.degrees(-placeRotation), anchor: .top)
                    .offset(x: nudge.width, y: labelBaseOffsetY(w: w, h: h) + nudge.height)
                    .gesture(labelDragGesture(w: w, h: h))
                    .help("Drag to move the label")
            }
            if isSelected {
                selectionBox(w: w, h: h)
                cornerHandle(-1, -1, w: w, h: h)
                cornerHandle( 1, -1, w: w, h: h)
                cornerHandle(-1,  1, w: w, h: h)
                cornerHandle( 1,  1, w: w, h: h)
                rotationHandle
                    .scaleEffect(1 / (zoom * placeScale), anchor: .center)
                    .offset(rotationHandleOffset(h: h))
            }
            // Real dimensions while resizing (only on a measured background). Kept a
            // constant, readable on-screen size — countering the full map scale
            // (zoom × placement) — so it isn't blown up when the piece is large or
            // the map zoomed in. Its distance above the piece still scales, so it
            // tracks the corner. Always in the hierarchy, toggled with opacity.
            if let dims = realSizeText {
                Text(dims)
                    .font(.caption2.monospacedDigit()).fontWeight(.medium)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    .scaleEffect(1 / (zoom * placeScale), anchor: .center)
                    .rotationEffect(.degrees(-placeRotation))
                    // Sit just above the piece's actual top edge (its rotated
                    // bounding-box half-height) plus a fixed on-screen gap — so a very
                    // wide piece doesn't fling the label upward, and the gap stays the
                    // same whether or not the map is zoomed in.
                    .offset(y: -(rotatedHalfHeight(w: w, h: h) + 18 / max(zoom * placeScale, 0.0001)))
                    .opacity(liveSize != nil ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .position(livePosition ?? center)
    }

    /// The piece's vertical half-extent (group units) at its current rotation — the
    /// distance from its centre to its top edge — so a label can sit just above the
    /// piece rather than off `max(w, h)/2`, which flings it up for a wide piece.
    private func rotatedHalfHeight(w: CGFloat, h: CGFloat) -> CGFloat {
        let r = displayRotation * .pi / 180
        return (abs(w * CGFloat(sin(r))) + abs(h * CGFloat(cos(r)))) / 2
    }

    /// The furniture's real-world dimensions ("W × H") from the current point size,
    /// or nil when the background isn't measured.
    private var realSizeText: String? {
        guard let metersWide, contentRect.width > 0, contentRect.height > 0 else { return nil }
        func label(_ meters: Double) -> String {
            meters < 1 ? String(format: "%.0f cm", meters * 100) : String(format: "%.2f m", meters)
        }
        let wMeters = Double(sizePts.width / contentRect.width) * metersWide
        let hMeters = Double(sizePts.height / contentRect.height) * metersWide
        return "\(label(wMeters)) × \(label(hMeters))"
    }

    /// The label's default vertical offset (below the piece).
    private func labelBaseOffsetY(w: CGFloat, h: CGFloat) -> CGFloat { max(w, h) / 2 + 12 }

    /// Drags the label around its piece, in the fixed canvas space (like the piece
    /// drag) so the moving label can't shift its own frame. The nudge is stored
    /// relative to the label's default spot (centre + `labelBaseOffsetY`).
    private func labelDragGesture(w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                let c = livePosition ?? center
                let baseY = c.y + labelBaseOffsetY(w: w, h: h)
                if liveLabelOffset == nil {
                    onSelect()
                    let current = CGPoint(x: c.x + furniture.labelOffset.width,
                                          y: baseY + furniture.labelOffset.height)
                    labelGrab = CGSize(width: current.x - value.location.x,
                                       height: current.y - value.location.y)
                }
                let newPos = CGPoint(x: value.location.x + labelGrab.width,
                                     y: value.location.y + labelGrab.height)
                var dx = newPos.x - c.x, dy = newPos.y - c.y
                let dist = hypot(dx, dy)
                if dist > Self.labelMaxDistance {
                    let scale = Self.labelMaxDistance / dist
                    dx *= scale; dy *= scale
                }
                liveLabelOffset = CGSize(width: dx, height: dy - labelBaseOffsetY(w: w, h: h))
            }
            .onEnded { _ in
                if let offset = liveLabelOffset { onMoveLabel(offset) }
                liveLabelOffset = nil
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                onSelect()
                if livePosition == nil {
                    grabOffset = CGSize(width: center.x - value.location.x, height: center.y - value.location.y)
                }
                livePosition = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
            }
            .onEnded { value in
                let final = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
                livePosition = nil
                onMove(normalized(final))
            }
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let nx = contentRect.width > 0 ? (p.x - contentRect.minX) / contentRect.width : 0
        let ny = contentRect.height > 0 ? (p.y - contentRect.minY) / contentRect.height : 0
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    private func rotationHandleOffset(h: CGFloat) -> CGSize {
        let d = h / 2 + 24
        let r = displayRotation * .pi / 180
        return CGSize(width: d * sin(r), height: -d * cos(r))
    }

    private var rotationHandle: some View {
        Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 1.5))
            .overlay(Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
            .frame(width: 16, height: 16)
            .contentShape(Circle().inset(by: -sceneMapHandleSlop))
            .gesture(
                DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                    .onChanged { value in onSelect(); liveRotation = sceneMapAngle(from: center, to: value.location) }
                    .onEnded { value in
                        let final = sceneMapAngle(from: center, to: value.location)
                        liveRotation = nil
                        onRotate(final)
                    }
            )
    }

    /// Dashed selection frame around the piece (rotates with it), purely visual.
    private func selectionBox(w: CGFloat, h: CGFloat) -> some View {
        Rectangle()
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(width: w, height: h)
            .rotationEffect(.degrees(displayRotation))
            .allowsHitTesting(false)
    }

    /// One draggable corner of the selection box. `sx`,`sy` ∈ {−1,+1} pick the
    /// corner; dragging resizes symmetrically about the centre (so the piece stays
    /// put), which matches how furniture is stored (centre + size).
    private func cornerHandle(_ sx: CGFloat, _ sy: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let r = displayRotation * .pi / 180
        let lx = sx * w / 2, ly = sy * h / 2
        let ox = lx * cos(r) - ly * sin(r)
        let oy = lx * sin(r) + ly * cos(r)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.accentColor, lineWidth: 1.2))
            .frame(width: 7, height: 7)
            .contentShape(Rectangle().inset(by: -(7 + sceneMapHandleSlop)))
            // Scales with the map (like the piece and its selection box) rather than
            // staying a fixed on-screen size, so the grab squares stay on the corners
            // and grow with the furniture when zoomed in.
            .offset(x: ox, y: oy)
            .gesture(resizeDrag)
    }

    private var resizeDrag: some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                onSelect()
                let r = displayRotation * .pi / 180
                let dx = value.location.x - center.x, dy = value.location.y - center.y
                // Project the pointer into the furniture's unrotated frame; the
                // half-extent is its distance from centre, so the size is doubled.
                let localX = dx * cos(r) + dy * sin(r)
                let localY = -dx * sin(r) + dy * cos(r)
                liveSize = CGSize(width: max(abs(localX) * 2, 14), height: max(abs(localY) * 2, 14))
            }
            .onEnded { _ in
                if let s = liveSize {
                    liveSize = nil
                    onResize(min(max(Double(s.width / contentRect.width), 0.02), 1),
                             min(max(Double(s.height / contentRect.height), 0.02), 1))
                }
            }
    }

    @ViewBuilder
    private var menu: some View {
        Button { onEditLabel() } label: {
            Label(furniture.label.isEmpty ? "Add Label…" : "Edit Label…", systemImage: "textformat")
        }
        Menu("Color") {
            ForEach(sceneMapPalette, id: \.hex) { item in
                Button {
                    onSetColor(item.hex)
                } label: {
                    menuSelectionLabel(item.name, isSelected: furniture.colorHex.caseInsensitiveCompare(item.hex) == .orderedSame)
                }
            }
        }
        Menu {
            Button { onReorder(.toFront) } label: { Label("Bring to Front", systemImage: "square.3.layers.3d.top.filled") }
            Button { onReorder(.forward) } label: { Label("Bring Forward", systemImage: "arrow.up") }
            Button { onReorder(.backward) } label: { Label("Send Backward", systemImage: "arrow.down") }
            Button { onReorder(.toBack) } label: { Label("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") }
        } label: {
            Label("Arrange", systemImage: "square.3.layers.3d")
        }
        Divider()
        Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
    }
}
