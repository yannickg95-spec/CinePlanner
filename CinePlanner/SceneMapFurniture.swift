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
/// Geometry of a softbox mounted on a light, as fractions of the (expanded) glyph
/// frame: the light sits centred, its front feeds a diffuser flaring out to the
/// opening. All fractions so they survive the glyph's render-scaling.
private struct MountedSoftboxGlyph: Equatable {
    var depthFrac: CGFloat        // softbox depth ÷ frame height
    var lightWidthFrac: CGFloat   // light width ÷ frame width
    var lightHeightFrac: CGFloat  // light depth ÷ frame height
    var openingFrac: CGFloat      // softbox opening width ÷ frame width
    var baseFrac: CGFloat         // softbox base (= light front) width ÷ frame width
    var frontInsetFrac: CGFloat   // fixture front inset from its box top ÷ frame height
}

private struct FurnitureGlyph: View {
    let kind: Furniture.Kind
    let size: CGSize
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat
    /// Tube only: draw the diffusion modifier fitted over the tube.
    var hasModifier: Bool = false
    /// A softbox mounted on the light's front, drawn as part of the piece.
    var softbox: MountedSoftboxGlyph? = nil
    /// Live magnification this glyph will undergo (map placement scale × canvas
    /// zoom). The Canvas is drawn that many times larger and scaled back down, so it
    /// rasterizes at the final on-screen resolution instead of a blurry, magnified
    /// 1× bitmap. Capped so the backing bitmap stays bounded at extreme zoom.
    var renderScale: CGFloat = 1

    var body: some View {
        let k = min(max(renderScale, 1), 8)
        Canvas { context, canvasSize in
            var ctx = context
            guard let sb = softbox else {
                drawFurniture(kind, in: CGRect(origin: .zero, size: canvasSize),
                              into: &ctx, fill: fill, stroke: stroke, lineWidth: lineWidth * k,
                              hasModifier: hasModifier)
                return
            }
            // Light centred in the frame; the softbox flares forward (up) from its front.
            let lightRect = CGRect(x: (1 - sb.lightWidthFrac) / 2 * canvasSize.width,
                                   y: sb.depthFrac * canvasSize.height,
                                   width: sb.lightWidthFrac * canvasSize.width,
                                   height: sb.lightHeightFrac * canvasSize.height)
            drawMountedSoftbox(centerX: canvasSize.width / 2,
                               backY: lightRect.minY + sb.frontInsetFrac * canvasSize.height, frontY: 0,
                               baseWidth: sb.baseFrac * canvasSize.width,
                               openingWidth: sb.openingFrac * canvasSize.width,
                               into: &ctx, fill: fill, stroke: stroke, lineWidth: lineWidth * k)
            drawFurniture(kind, in: lightRect,
                          into: &ctx, fill: fill, stroke: stroke, lineWidth: lineWidth * k,
                          hasModifier: hasModifier, reflectorReplaced: kind.isCOB)
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
                                bodyHalfWidth: CGFloat = 0.365,
                                showReflector: Bool = true,
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
    // housing occupies the rest, the connector poking out the back. With a softbox
    // fitted the reflector is removed and the body fills the piece, so the softbox
    // mounts on the body front (the Bowens / Aputure mount).
    let collarGap: CGFloat = 0.025
    let bodyY0 = showReflector ? reflDepth + collarGap : 0.05
    let bodyY1: CGFloat = showReflector ? 0.95 : 0.97
    let bodyH = bodyY1 - bodyY0

    if showReflector {
        // Reflector.
        var hood = Path()
        hood.move(to: CGPoint(x: X(mid - frontHalf), y: Y(0)))
        hood.addLine(to: CGPoint(x: X(mid + frontHalf), y: Y(0)))
        hood.addLine(to: CGPoint(x: X(mid + baseHalf), y: Y(reflDepth)))
        hood.addLine(to: CGPoint(x: X(mid - baseHalf), y: Y(reflDepth)))
        hood.closeSubpath()
        ctx.fill(hood, with: deepFill)
        ctx.stroke(hood, with: stroke, lineWidth: lw)
    }

    // Yoke arms — thin bars just outside each side of the housing.
    let bodyHalf = bodyHalfWidth
    let armW: CGFloat = 0.065
    let armY0 = bodyY0 + bodyH * 0.12
    let armY1 = bodyY1 - bodyH * 0.12
    for side in [CGFloat(-1), CGFloat(1)] {
        let inner = mid + side * bodyHalf
        let outer = inner + side * armW
        let arm = furnitureRoundedPath(box(min(inner, outer), armY0, max(inner, outer), armY1), unit * 0.02)
        ctx.fill(arm, with: fill)
        ctx.stroke(arm, with: stroke, lineWidth: lw)
    }

    // Body — the housing, inset so the yoke arms show at the sides.
    let bodyPath = furnitureRoundedPath(box(mid - bodyHalf, bodyY0, mid + bodyHalf, bodyY1), unit * 0.075)
    ctx.fill(bodyPath, with: fill)
    ctx.stroke(bodyPath, with: stroke, lineWidth: lw)

    if showReflector {
        // ProLock collar — the band between the reflector base and the housing.
        let collarRect = box(mid - baseHalf, reflDepth - 0.004, mid + baseHalf, bodyY0 + 0.012)
        ctx.fill(furnitureRoundedPath(collarRect, collarRect.height * 0.35), with: fill)
        ctx.stroke(furnitureRoundedPath(collarRect, collarRect.height * 0.35), with: stroke, lineWidth: lw)
    } else {
        // Mount lip across the body front — the speedring the softbox seats on.
        let lipRect = box(mid - bodyHalfWidth * 0.85, bodyY0 - 0.012, mid + bodyHalfWidth * 0.85, bodyY0 + 0.03)
        ctx.fill(furnitureRoundedPath(lipRect, lipRect.height * 0.4), with: fill)
        ctx.stroke(furnitureRoundedPath(lipRect, lipRect.height * 0.4), with: stroke, lineWidth: lw)
    }

    // Round tilt knobs at the outer ends of the yoke arms.
    let knobR = unit * 0.05
    let knobY = (bodyY0 + bodyY1) / 2
    let knobCx = bodyHalf + armW
    for cx in [X(mid - knobCx), X(mid + knobCx)] {
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

/// Aputure STORM XT52-style fixture from directly above, following the shared design:
/// a big rounded body carried between two yoke arms with tilt knobs, a reflector hood
/// flaring out the front, a control strip across the back of the body and a connector
/// at its back corner. Front = up at 0°, so rotating the piece aims the light.
private func drawStormXT52(_ rect: CGRect, showReflector: Bool = true,
                           into ctx: inout GraphicsContext,
                           fill: GraphicsContext.Shading, deepFill: GraphicsContext.Shading,
                           stroke: GraphicsContext.Shading, detail: GraphicsContext.Shading,
                           lineWidth lw: CGFloat) {
    // Geometry is expressed as fractions of the piece's bounding box.
    func X(_ f: CGFloat) -> CGFloat { rect.minX + f * rect.width }
    // With a softbox fitted the reflector is dropped, so the body (which normally sits
    // below the 0.252 hood/lip) is remapped to fill the whole piece and the softbox
    // mounts on its front.
    let srcTop: CGFloat = showReflector ? 0 : 0.252
    func Y(_ f: CGFloat) -> CGFloat {
        guard !showReflector else { return rect.minY + f * rect.height }
        let t = (f - srcTop) / (1 - srcTop)
        return rect.minY + (0.02 + t * 0.98) * rect.height
    }
    func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        let a = Y(y0), b = Y(y1)
        return CGRect(x: X(x0), y: a, width: (x1 - x0) * rect.width, height: b - a)
    }
    let unit = min(rect.width, rect.height)

    if showReflector {
        // Reflector hood (30 cm mouth, 20 cm collar, 20 cm long on a 79.4 cm piece).
        var hood = Path()
        hood.move(to: CGPoint(x: X(0.217), y: Y(0.000)))
        hood.addLine(to: CGPoint(x: X(0.783), y: Y(0.000)))
        hood.addLine(to: CGPoint(x: X(0.689), y: Y(0.252)))
        hood.addLine(to: CGPoint(x: X(0.311), y: Y(0.252)))
        hood.closeSubpath()
        ctx.fill(hood, with: deepFill)
        ctx.stroke(hood, with: stroke, lineWidth: lw)
    }

    // Yoke arms down each side, behind the body.
    for xs in [(CGFloat(0.081), CGFloat(0.155)), (CGFloat(0.852), CGFloat(0.929))] {
        let arm = furnitureRoundedPath(box(xs.0, 0.33, xs.1, 0.95), unit * 0.03)
        ctx.fill(arm, with: fill)
        ctx.stroke(arm, with: stroke, lineWidth: lw)
    }

    // Body — 55 cm long.
    let bodyPath = furnitureRoundedPath(box(0.155, 0.275, 0.852, 0.968), unit * 0.07)
    ctx.fill(bodyPath, with: fill)
    ctx.stroke(bodyPath, with: stroke, lineWidth: lw)

    // Mount lip at the body front — the collar the hood or a softbox seats on.
    let lipRect = box(0.311, 0.252, 0.689, 0.282)
    let lip = furnitureRoundedPath(lipRect, lipRect.height * 0.4)
    ctx.fill(lip, with: fill)
    ctx.stroke(lip, with: stroke, lineWidth: lw)

    // Tilt knobs on the yoke.
    let knobR = unit * 0.053
    for cx in [X(0.053), X(0.947)] {
        let knob = CGRect(x: cx - knobR, y: Y(0.60) - knobR, width: knobR * 2, height: knobR * 2)
        ctx.fill(Path(ellipseIn: knob), with: fill)
        ctx.stroke(Path(ellipseIn: knob), with: stroke, lineWidth: lw)
    }

    // Control strip across the back of the body.
    var strip = Path()
    for fy in [CGFloat(0.80), CGFloat(0.835), CGFloat(0.87)] {
        strip.move(to: CGPoint(x: X(0.239), y: Y(fy)))
        strip.addLine(to: CGPoint(x: X(0.761), y: Y(fy)))
    }
    ctx.stroke(strip, with: detail, lineWidth: lw * 0.6)

    // Connector at the back corner.
    let plugRect = box(0.234, 0.958, 0.354, 1.000)
    ctx.fill(furnitureRoundedPath(plugRect, plugRect.height * 0.25), with: stroke)
}

/// Top-down HMI head: a wide flared reflector (bowl) opening toward the front (up),
/// over a housing with vertical cooling fins. `domeTop` gives the big 18K a rounded
/// dome; a flat top with a rim line reads as the medium head.
private func drawHMILight(_ rect: CGRect, into ctx: inout GraphicsContext,
                          fill: GraphicsContext.Shading, stroke: GraphicsContext.Shading,
                          detail: GraphicsContext.Shading, lineWidth lw: CGFloat,
                          topHalf: CGFloat, topY: CGFloat, shoulderY: CGFloat,
                          neckHalf: CGFloat, neckY: CGFloat, bottomY: CGFloat,
                          domeTop: Bool) {
    let w = rect.width, h = rect.height, cx = rect.midX
    func Y(_ f: CGFloat) -> CGFloat { rect.minY + f * h }
    func Xc(_ off: CGFloat) -> CGFloat { cx + off * w }   // off = fraction from centre
    let unit = min(w, h)
    let tCorner = unit * 0.03
    let bCorner = unit * 0.06

    var outline = Path()
    outline.move(to: CGPoint(x: Xc(-neckHalf), y: Y(neckY)))          // neck, left
    if domeTop {
        // Thin angled flange out to the widest point, a broad shallow dome across the
        // top (a cubic so it reads as a wide arc, not a bulbous mushroom cap), flange in.
        outline.addLine(to: CGPoint(x: Xc(-topHalf), y: Y(shoulderY)))
        outline.addCurve(to: CGPoint(x: Xc(topHalf), y: Y(shoulderY)),
                         control1: CGPoint(x: Xc(-0.24), y: Y(topY)),
                         control2: CGPoint(x: Xc(0.24), y: Y(topY)))
        outline.addLine(to: CGPoint(x: Xc(neckHalf), y: Y(neckY)))
    } else {
        // Left wall, rounded top-left, flat top, rounded top-right, right wall.
        outline.addQuadCurve(to: CGPoint(x: Xc(-topHalf), y: Y(topY) + tCorner),
                             control: CGPoint(x: Xc(-topHalf), y: Y(neckY)))
        outline.addQuadCurve(to: CGPoint(x: Xc(-topHalf) + tCorner, y: Y(topY)),
                             control: CGPoint(x: Xc(-topHalf), y: Y(topY)))
        outline.addLine(to: CGPoint(x: Xc(topHalf) - tCorner, y: Y(topY)))
        outline.addQuadCurve(to: CGPoint(x: Xc(topHalf), y: Y(topY) + tCorner),
                             control: CGPoint(x: Xc(topHalf), y: Y(topY)))
        outline.addQuadCurve(to: CGPoint(x: Xc(neckHalf), y: Y(neckY)),
                             control: CGPoint(x: Xc(topHalf), y: Y(neckY)))
    }
    // Housing: straight sides down to a rounded bottom.
    outline.addLine(to: CGPoint(x: Xc(neckHalf), y: Y(bottomY) - bCorner))
    outline.addQuadCurve(to: CGPoint(x: Xc(neckHalf) - bCorner, y: Y(bottomY)),
                         control: CGPoint(x: Xc(neckHalf), y: Y(bottomY)))
    outline.addLine(to: CGPoint(x: Xc(-neckHalf) + bCorner, y: Y(bottomY)))
    outline.addQuadCurve(to: CGPoint(x: Xc(-neckHalf), y: Y(bottomY) - bCorner),
                         control: CGPoint(x: Xc(-neckHalf), y: Y(bottomY)))
    outline.closeSubpath()
    ctx.fill(outline, with: fill)
    ctx.stroke(outline, with: stroke, lineWidth: lw)

    // Rim line just inside the flat top (medium head only).
    if !domeTop {
        let lipY = topY + (neckY - topY) * 0.16
        var lip = Path()
        lip.move(to: CGPoint(x: Xc(-topHalf) + tCorner, y: Y(lipY)))
        lip.addLine(to: CGPoint(x: Xc(topHalf) - tCorner, y: Y(lipY)))
        ctx.stroke(lip, with: stroke, lineWidth: lw)
    }

    // Four vertical cooling fins in the housing.
    let barTop = neckY + (bottomY - neckY) * 0.16
    let barBottom = bottomY - (bottomY - neckY) * 0.14
    let barSpan = neckHalf * 0.70
    var bars = Path()
    let barOffsets: [CGFloat] = [-1, -1.0 / 3, 1.0 / 3, 1]
    for t in barOffsets {
        let bx = Xc(t * barSpan)
        bars.move(to: CGPoint(x: bx, y: Y(barTop)))
        bars.addLine(to: CGPoint(x: bx, y: Y(barBottom)))
    }
    ctx.stroke(bars, with: stroke, style: StrokeStyle(lineWidth: unit * 0.03, lineCap: .round))
}

/// A softbox mounted on a light's front, seen from above: a diffuser flaring from a
/// base that meets the light's front (`baseWidth`) out to the wider diffusion opening
/// (`openingWidth`) over `backY − frontY`, with a diffusion line across the opening.
/// `front` is up (toward the top of the frame), matching the light's facing.
private func drawMountedSoftbox(centerX: CGFloat, backY: CGFloat, frontY: CGFloat,
                                baseWidth: CGFloat, openingWidth: CGFloat,
                                into ctx: inout GraphicsContext,
                                fill: Color, stroke: Color, lineWidth lw: CGFloat) {
    let fillC = GraphicsContext.Shading.color(fill.mixedWithWhite(0.80))
    let strokeC = GraphicsContext.Shading.color(stroke)
    let detailC = GraphicsContext.Shading.color(stroke.opacity(0.55))
    let bx0 = centerX - baseWidth / 2, bx1 = centerX + baseWidth / 2
    let ox0 = centerX - openingWidth / 2, ox1 = centerX + openingWidth / 2
    let midY = (backY + frontY) / 2
    var body = Path()
    body.move(to: CGPoint(x: bx0, y: backY))
    body.addQuadCurve(to: CGPoint(x: ox0, y: frontY),
                      control: CGPoint(x: (bx0 + ox0) / 2, y: midY))
    body.addLine(to: CGPoint(x: ox1, y: frontY))
    body.addQuadCurve(to: CGPoint(x: bx1, y: backY),
                      control: CGPoint(x: (bx1 + ox1) / 2, y: midY))
    body.closeSubpath()
    ctx.fill(body, with: fillC)
    ctx.stroke(body, with: strokeC, lineWidth: lw)
    // Diffusion line just inside the front (opening) edge.
    var face = Path()
    face.move(to: CGPoint(x: ox0 + lw, y: frontY + lw))
    face.addLine(to: CGPoint(x: ox1 - lw, y: frontY + lw))
    ctx.stroke(face, with: detailC, style: StrokeStyle(lineWidth: lw, lineCap: .round))
}

/// Top-down silhouette per furniture kind, drawn into `rect`.
private func drawFurniture(_ kind: Furniture.Kind, in rect: CGRect, into ctx: inout GraphicsContext,
                           fill: Color, stroke: Color, lineWidth lw: CGFloat,
                           hasModifier: Bool = false, reflectorReplaced: Bool = false) {
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

    case .smallLight, .smallCOB:
        // Aputure STORM 80C, matching the reference top view: reflector 18 cm long
        // (was 20), flaring wide at the mouth to a narrower collar; 40 cm total.
        drawStormMonolight(rect, reflectorDepth: 18.0 / 40.0,
                           reflectorFrontHalf: 0.30, reflectorBaseHalf: 0.206,
                           bodyHalfWidth: 0.33, showReflector: !reflectorReplaced,
                           into: &ctx, fill: fillC, deepFill: deepFillC,
                           stroke: strokeC, detail: detailC, lineWidth: lw)

    case .mediumLight, .mediumCOB:
        // Aputure STORM 1200x: body 33×33 cm total (incl. yoke knobs), reflector 15 cm
        // long with an 18 cm mouth / 10 cm collar. Footprint 33 × 51.9 cm.
        drawStormMonolight(rect, reflectorDepth: 15.0 / 51.9,
                           reflectorFrontHalf: 9.0 / 33.0, reflectorBaseHalf: 5.0 / 33.0,
                           bodyHalfWidth: 0.385, showReflector: !reflectorReplaced,
                           into: &ctx, fill: fillC, deepFill: deepFillC,
                           stroke: strokeC, detail: detailC, lineWidth: lw)

    case .bigLight, .bigCOB:
        drawStormXT52(rect, showReflector: !reflectorReplaced,
                      into: &ctx, fill: fillC, deepFill: deepFillC,
                      stroke: strokeC, detail: detailC, lineWidth: lw)

    case .mediumHMI, .smallHMI:
        // Same bucket reflector as the big head, but with a larger reflector (front)
        // relative to the housing — the neck sits lower so the flared part is taller.
        drawHMILight(rect, into: &ctx, fill: fillC, stroke: strokeC, detail: detailC,
                     lineWidth: lw, topHalf: 0.48, topY: 0.02, shoulderY: 0.02,
                     neckHalf: 0.33, neckY: 0.36, bottomY: 0.98, domeTop: false)

    case .bigHMI:
        // Flat top with rounded corners and a rim line (bucket reflector).
        drawHMILight(rect, into: &ctx, fill: fillC, stroke: strokeC, detail: detailC,
                     lineWidth: lw, topHalf: 0.48, topY: 0.02, shoulderY: 0.02,
                     neckHalf: 0.394, neckY: 0.349, bottomY: 0.98, domeTop: false)

    case .bigTungsten, .mediumTungsten, .smallTungsten:
        // The Big HMI housing without the flared reflector: a finned tungsten box.
        let bodyRect = rect.insetBy(dx: w * 0.10, dy: h * 0.03)
        let body = furnitureRoundedPath(bodyRect, min(bodyRect.width, bodyRect.height) * 0.06)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        // Line near the front (lens) edge, spanning the full housing width, so a
        // strip reads at that end. Clipped to the body so it stops at the sides.
        var lensStrip = Path()
        let stripY = bodyRect.minY + bodyRect.height * 0.09
        lensStrip.move(to: CGPoint(x: bodyRect.minX, y: stripY))
        lensStrip.addLine(to: CGPoint(x: bodyRect.maxX, y: stripY))
        var stripCtx = ctx
        stripCtx.clip(to: body)
        stripCtx.stroke(lensStrip, with: strokeC, lineWidth: lw)
        let finTop = bodyRect.minY + bodyRect.height * 0.22
        let finBottom = bodyRect.maxY - bodyRect.height * 0.08
        let finSpan = bodyRect.width * 0.62
        var fins = Path()
        let finOffsets: [CGFloat] = [-1, -1.0 / 3, 1.0 / 3, 1]
        for t in finOffsets {
            let fx = bodyRect.midX + t * finSpan / 2
            fins.move(to: CGPoint(x: fx, y: finTop))
            fins.addLine(to: CGPoint(x: fx, y: finBottom))
        }
        ctx.stroke(fins, with: strokeC, style: StrokeStyle(lineWidth: min(w, h) * 0.03, lineCap: .round))

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
        // An in-scene lamp from above, read as a glowing point source: a round shade
        // with short light rays and a lit bulb at the centre.
        let d = min(w, h), c = CGPoint(x: rect.midX, y: rect.midY), R = d * 0.47
        let shade = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        ctx.fill(Path(ellipseIn: shade), with: fillC)
        ctx.stroke(Path(ellipseIn: shade), with: strokeC, lineWidth: lw)
        // Radiating rays around the bulb.
        var rays = Path()
        let rayCount = 8
        for i in 0..<rayCount {
            let a = Double(i) / Double(rayCount) * 2 * .pi
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            rays.move(to: CGPoint(x: c.x + dx * R * 0.46, y: c.y + dy * R * 0.46))
            rays.addLine(to: CGPoint(x: c.x + dx * R * 0.82, y: c.y + dy * R * 0.82))
        }
        ctx.stroke(rays, with: detailC, style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round))
        // Lit bulb at the centre.
        let br = R * 0.32
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - br, y: c.y - br, width: br * 2, height: br * 2)), with: detailC)

    case .tube, .shortTube:
        if hasModifier {
            // Tube with a diffusion modifier: the same strip, now the full (20 cm)
            // cross-section, with soft diffusion hatching along its length.
            let body = rr(rect, min(w, h) * 0.22)
            ctx.fill(body, with: fillC)
            ctx.stroke(body, with: strokeC, lineWidth: lw)
            var diff = Path()
            let n = 4
            for i in 1..<n {
                let gx = rect.minX + w * CGFloat(i) / CGFloat(n)
                diff.move(to: CGPoint(x: gx, y: rect.minY + h * 0.14))
                diff.addLine(to: CGPoint(x: gx, y: rect.maxY - h * 0.14))
            }
            diff.move(to: CGPoint(x: rect.minX + w * 0.05, y: rect.midY))
            diff.addLine(to: CGPoint(x: rect.maxX - w * 0.05, y: rect.midY))
            ctx.stroke(diff, with: detailC, lineWidth: lw * 0.6)
        } else {
            // LED tube from above: a long capsule with end caps and a centre line.
            let body = rr(rect, min(w, h) * 0.5)
            ctx.fill(body, with: fillC)
            ctx.stroke(body, with: strokeC, lineWidth: lw)
            var caps = Path()
            caps.move(to: CGPoint(x: rect.minX + w * 0.06, y: rect.minY)); caps.addLine(to: CGPoint(x: rect.minX + w * 0.06, y: rect.maxY))
            caps.move(to: CGPoint(x: rect.maxX - w * 0.06, y: rect.minY)); caps.addLine(to: CGPoint(x: rect.maxX - w * 0.06, y: rect.maxY))
            caps.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.midY)); caps.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.midY))
            ctx.stroke(caps, with: detailC, lineWidth: lw * 0.7)
        }

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

    case .softbox, .mediumSoftbox, .bigSoftbox:
        // Softbox from above: a parabolic (conical) reflector — a wide rounded
        // diffusion face at the front (up) with curved sides tapering to a rounded
        // point at the back, plus a diffusion line at the front.
        func X(_ off: CGFloat) -> CGFloat { rect.midX + off * w }
        func Y(_ f: CGFloat) -> CGFloat { rect.minY + f * h }
        var body = Path()
        body.move(to: CGPoint(x: X(-0.49), y: Y(0.10)))
        body.addQuadCurve(to: CGPoint(x: X(-0.41), y: Y(0.01)), control: CGPoint(x: X(-0.49), y: Y(0.02)))
        body.addLine(to: CGPoint(x: X(0.41), y: Y(0.01)))
        body.addQuadCurve(to: CGPoint(x: X(0.49), y: Y(0.10)), control: CGPoint(x: X(0.49), y: Y(0.02)))
        // Right side down to a short flat base at the back.
        body.addQuadCurve(to: CGPoint(x: X(0.10), y: Y(0.96)), control: CGPoint(x: X(0.47), y: Y(0.61)))
        body.addQuadCurve(to: CGPoint(x: X(0.06), y: Y(0.99)), control: CGPoint(x: X(0.10), y: Y(0.99)))
        body.addLine(to: CGPoint(x: X(-0.06), y: Y(0.99)))
        body.addQuadCurve(to: CGPoint(x: X(-0.10), y: Y(0.96)), control: CGPoint(x: X(-0.10), y: Y(0.99)))
        body.addQuadCurve(to: CGPoint(x: X(-0.49), y: Y(0.10)), control: CGPoint(x: X(-0.47), y: Y(0.61)))
        body.closeSubpath()
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        // Diffusion line just inside the front face.
        var face = Path()
        face.move(to: CGPoint(x: X(-0.42), y: Y(0.08)))
        face.addLine(to: CGPoint(x: X(0.42), y: Y(0.08)))
        ctx.stroke(face, with: detailC, style: StrokeStyle(lineWidth: lw, lineCap: .round))

    case .lightPanel, .panel1x1:
        // Flat LED panel (2x1 / 1x1) from above: a wide, shallow rounded rectangle filling
        // the piece's full footprint (so its drawn width reads true), with an LED
        // cell grid. Inset only by the stroke so the outline isn't clipped. No stand.
        let panel = rect.insetBy(dx: lw / 2, dy: lw / 2)
        let panelPath = rr(panel, min(panel.width, panel.height) * 0.16)
        ctx.fill(panelPath, with: fillC)
        ctx.stroke(panelPath, with: strokeC, lineWidth: lw)
        var grid = Path()
        // Column count follows the aspect so cells stay square-ish on either panel
        // (≈6 on the 2x1, ≈3 on the 1x1).
        let cols = max(2, Int((panel.width / max(panel.height, 1)).rounded()))
        for i in 1..<cols {
            let gx = panel.minX + panel.width * CGFloat(i) / CGFloat(cols)
            grid.move(to: CGPoint(x: gx, y: panel.minY)); grid.addLine(to: CGPoint(x: gx, y: panel.maxY))
        }
        var clip = ctx
        clip.clip(to: panelPath)
        clip.stroke(grid, with: detailC, lineWidth: lw * 0.6)

    case .frame4, .frame8, .frame12, .frame20:
        // Diffusion / silk frame from ABOVE: a frame stands vertically, so top-down it
        // reads as a thin bar the width of the frame — the fabric span with the two
        // side rails at the ends and a diagonal silk hatch.
        let bar = rect.insetBy(dx: lw / 2, dy: lw / 2)
        let body = rr(bar, min(bar.width, bar.height) * 0.3)
        ctx.fill(body, with: fillC)
        ctx.stroke(body, with: strokeC, lineWidth: lw)
        // Diagonal hatch (the silk), clipped to the bar.
        var hatch = Path()
        let step = max(bar.height * 1.1, 6)
        var x = bar.minX - bar.height
        while x < bar.maxX {
            hatch.move(to: CGPoint(x: x, y: bar.maxY))
            hatch.addLine(to: CGPoint(x: x + bar.height, y: bar.minY))
            x += step
        }
        var hatchClip = ctx
        hatchClip.clip(to: body)
        hatchClip.stroke(hatch, with: detailC, lineWidth: lw * 0.5)
        // Side rails at each end.
        var rails = Path()
        let rx0 = bar.minX + bar.width * 0.02, rx1 = bar.maxX - bar.width * 0.02
        rails.move(to: CGPoint(x: rx0, y: bar.minY)); rails.addLine(to: CGPoint(x: rx0, y: bar.maxY))
        rails.move(to: CGPoint(x: rx1, y: bar.minY)); rails.addLine(to: CGPoint(x: rx1, y: bar.maxY))
        ctx.stroke(rails, with: strokeC, lineWidth: lw)

    case .truss:
        // Lighting truss from above: just the tubes — the two chords, end caps and
        // zig-zag web bracing — with the space between them left open (no fill).
        let bar = rect.insetBy(dx: lw / 2, dy: lw / 2)
        var chords = Path()
        chords.move(to: CGPoint(x: bar.minX, y: bar.minY)); chords.addLine(to: CGPoint(x: bar.maxX, y: bar.minY))
        chords.move(to: CGPoint(x: bar.minX, y: bar.maxY)); chords.addLine(to: CGPoint(x: bar.maxX, y: bar.maxY))
        chords.move(to: CGPoint(x: bar.minX, y: bar.minY)); chords.addLine(to: CGPoint(x: bar.minX, y: bar.maxY))
        chords.move(to: CGPoint(x: bar.maxX, y: bar.minY)); chords.addLine(to: CGPoint(x: bar.maxX, y: bar.maxY))
        ctx.stroke(chords, with: strokeC, lineWidth: lw * 1.7)
        // Zig-zag web bracing between the chords.
        var web = Path()
        let seg = max(bar.height, 6)
        web.move(to: CGPoint(x: bar.minX, y: bar.maxY))
        var x = bar.minX
        var up = true
        while x < bar.maxX - 0.5 {
            let nx = min(x + seg, bar.maxX)
            web.addLine(to: CGPoint(x: nx, y: up ? bar.minY : bar.maxY))
            x = nx; up.toggle()
        }
        ctx.stroke(web, with: strokeC, lineWidth: lw * 1.2)
    }
}

struct FurnitureView: View {
    let furniture: Furniture
    let isSelected: Bool
    /// Whether resize handles are shown / resizing is allowed. Lights only expose them
    /// after the user picks "Resize" from the context menu, so a normal drag just moves
    /// them; non-lights are always resizable.
    var resizeArmed: Bool = true
    /// Whether the piece's size differs from its default, so "Reset Size" is offered.
    var canResetSize: Bool = false
    /// Resize changes the long axis only (fixed cross-section) — tubes, bounce,
    /// frames, and a truss on a measured map.
    var widthOnlyResize: Bool = false
    /// Truss on an unscaled map: show mid-end length handles (drag to lengthen /
    /// shorten from that end) in addition to the corner stretch handles.
    var showsLengthHandles: Bool = false
    let contentRect: CGRect
    /// Counter-scales the label by 1/zoom so it stays a constant on-screen size.
    var zoom: CGFloat = 1
    /// Map placement (see `SceneMapBackgroundTransform`): the glyph rides it via the
    /// parent group; the label and handles are countered so they stay upright and a
    /// constant on-screen size.
    var placeScale: CGFloat = 1
    var placeRotation: Double = 0
    let onSelect: () -> Void
    /// Whether a drag keeps the piece inside the map (snapping to the nearest edge).
    /// CineStager imports pass false, so a light can sit in the white margin like the
    /// camera/mannequin markers; every other map clamps.
    var clampToBounds: Bool = true
    let onMove: (CGPoint) -> Void
    let onRotate: (Double) -> Void
    let onResize: (Double, Double) -> Void
    /// Restores the piece to its default size (shown for light markers).
    var onResetSize: () -> Void = {}
    /// Tube only: toggles the diffusion modifier (20 cm cross-section).
    var onToggleModifier: () -> Void = {}
    /// Arms resize mode (shown for lights, which are move-only until armed).
    var onArmResize: () -> Void = {}
    /// Mounts a softbox on the light's front (shown for HMI/Tungsten/COB/panels).
    var onAddSoftbox: () -> Void = {}
    let onSetColor: (String) -> Void
    let onReorder: (FurnitureLayerMove) -> Void
    let onDuplicate: () -> Void
    var onEditLabel: () -> Void = {}
    /// Reports the label's new nudge (canvas points) once its drag ends.
    var onMoveLabel: (CGSize) -> Void = { _ in }
    /// Real-world metres spanning the (square) measured background; nil = unmeasured
    /// (no dimensions shown while resizing).
    var metersWide: Double? = nil
    /// "Enlarge markers" mode: floors a light's drawn size at its default so a lamp
    /// that renders tiny on a large measured map stays easy to see (mirrors the
    /// camera/mannequin markers' viewable-size floor). Off = true real-world size.
    var viewable: Bool = false
    /// Multi-selection (marquee) support, mirroring the camera/mannequin markers: when
    /// this piece is one of several selected, dragging it moves the whole group and the
    /// delete label counts them. `groupDragOffset` is the live group translation the
    /// parent applies to every selected piece.
    var selectedCount: Int = 1
    var isGroupMember: Bool = false
    var groupDragOffset: CGSize = .zero
    var onGroupDragChanged: (CGSize) -> Void = { _ in }
    var onGroupDragEnded: (CGSize) -> Void = { _ in }
    let onDelete: () -> Void

    @State private var livePosition: CGPoint?
    @State private var grabOffset: CGSize = .zero
    @State private var liveRotation: Double?
    @State private var liveSize: CGSize?
    /// Width (points) and centre captured when an end length-handle drag starts.
    @State private var lengthResizeBase: (width: CGFloat, center: CGPoint)?
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
    /// The light's own on-screen size (before any mounted softbox extends the piece).
    private var lightSizePts: CGSize {
        if let liveSize { return liveSize }
        var w = CGFloat(furniture.width), h = CGFloat(furniture.height)
        // Enlarge-markers mode: never let a light draw smaller than its default size,
        // so a lamp sized to a big measured map (tiny in real-world terms) stays
        // visible. A truss is length-to-scale, so it keeps its true size (enlarging it
        // would change how long it reads).
        if viewable, furniture.kind.isLight, !furniture.kind.isTruss {
            let def = furniture.kind.defaultSize
            w = max(w, def.width); h = max(h, def.height)
        }
        return CGSize(width: w * contentRect.width, height: h * contentRect.height)
    }
    /// The light as drawn once a softbox is fitted. COBs shed their reflector then, so
    /// only the body is drawn and the softbox mounts on its front; every other light
    /// keeps its full glyph. Width is unchanged.
    private var glyphLightSize: CGSize {
        let ls = lightSizePts
        if furniture.hasSoftbox, furniture.kind.isCOB {
            return CGSize(width: ls.width, height: ls.height * furniture.kind.cobBodyLengthFraction)
        }
        return ls
    }
    /// A mounted softbox's on-screen opening width and depth (points), sized off the
    /// light's front. `nil` when no softbox is fitted.
    private var softboxPts: (opening: CGFloat, depth: CGFloat)? {
        guard furniture.hasSoftbox, let r = furniture.kind.mountedSoftbox else { return nil }
        let lw = lightSizePts.width
        return (opening: CGFloat(r.openingRatio) * lw, depth: CGFloat(r.depthRatio) * lw)
    }
    /// The whole piece's footprint. With a softbox the piece grows: the box extends the
    /// light's front by its depth, so the frame is padded by that depth on both ends
    /// (keeping the light centred on the furniture's stored position) and widened to
    /// the softbox opening.
    private var sizePts: CGSize {
        let ls = glyphLightSize
        guard let sb = softboxPts else { return lightSizePts }
        return CGSize(width: max(ls.width, sb.opening), height: ls.height + 2 * sb.depth)
    }
    /// The mounted-softbox geometry as frame fractions, for the given frame size.
    private func softboxGlyph(w: CGFloat, h: CGFloat) -> MountedSoftboxGlyph? {
        guard let sb = softboxPts, w > 0, h > 0 else { return nil }
        let ls = glyphLightSize
        return MountedSoftboxGlyph(depthFrac: sb.depth / h,
                                   lightWidthFrac: ls.width / w,
                                   lightHeightFrac: ls.height / h,
                                   openingFrac: min(sb.opening, w) / w,
                                   baseFrac: furniture.kind.frontWidthFraction * ls.width / w,
                                   frontInsetFrac: furniture.kind.frontInsetFraction * ls.height / h)
    }
    var body: some View {
        let w = max(sizePts.width, 8), h = max(sizePts.height, 8)
        ZStack {
            FurnitureGlyph(kind: furniture.kind, size: CGSize(width: w, height: h),
                           fill: color, stroke: isSelected ? Color.accentColor : color,
                           lineWidth: isSelected ? 2.5 : 2,
                           hasModifier: furniture.hasModifier,
                           softbox: softboxGlyph(w: w, h: h),
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
                // Lights are move-only until "Resize" is picked; other pieces always
                // show the corner handles.
                if !furniture.kind.isLight || resizeArmed {
                    cornerHandle(-1, -1, w: w, h: h)
                    cornerHandle( 1, -1, w: w, h: h)
                    cornerHandle(-1,  1, w: w, h: h)
                    cornerHandle( 1,  1, w: w, h: h)
                }
                // Truss on an unscaled map: mid-end handles to lengthen/shorten.
                if showsLengthHandles && resizeArmed {
                    lengthHandle(-1, w: w, h: h)
                    lengthHandle( 1, w: w, h: h)
                }
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
        // While part of a multi-selection, the parent offsets every selected piece by
        // the live group translation so they move together.
        .offset(groupDragOffset)
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
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasContentSpace))
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
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasContentSpace))
            .onChanged { value in
                // Part of a multi-selection → drag the whole group (the parent offsets
                // every selected piece), leaving the selection intact.
                if isGroupMember {
                    onGroupDragChanged(value.translation)
                    return
                }
                onSelect()
                if livePosition == nil {
                    grabOffset = CGSize(width: center.x - value.location.x, height: center.y - value.location.y)
                }
                livePosition = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
            }
            .onEnded { value in
                if isGroupMember {
                    onGroupDragEnded(value.translation)
                    return
                }
                let final = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
                livePosition = nil
                onMove(normalized(final))
            }
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let nx = contentRect.width > 0 ? (p.x - contentRect.minX) / contentRect.width : 0
        let ny = contentRect.height > 0 ? (p.y - contentRect.minY) / contentRect.height : 0
        guard clampToBounds else { return CGPoint(x: nx, y: ny) }
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
                DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasContentSpace))
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

    /// A length handle at the middle of one short end (`side` −1 = left, +1 = right).
    /// Dragging it lengthens/shortens the piece from that end, the opposite end fixed.
    private func lengthHandle(_ side: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let r = displayRotation * .pi / 180
        let lx = side * w / 2
        let ox = lx * cos(r)
        let oy = lx * sin(r)
        return Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.4))
            .frame(width: 11, height: 11)
            .contentShape(Circle().inset(by: -(7 + sceneMapHandleSlop)))
            .offset(x: ox, y: oy)
            .gesture(
                DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasContentSpace))
                    .onChanged { value in
                        onSelect()
                        if lengthResizeBase == nil {
                            lengthResizeBase = (CGFloat(furniture.width) * contentRect.width, center)
                        }
                        guard let base = lengthResizeBase else { return }
                        // Drag projected onto the piece's long axis.
                        let localDX = value.translation.width * cos(r) + value.translation.height * sin(r)
                        let newWidth = max(base.width + side * localDX, 14)
                        // The far end stays put, so the centre shifts by half the change
                        // along the long axis.
                        let shift = side * (newWidth - base.width) / 2
                        livePosition = CGPoint(x: base.center.x + shift * cos(r),
                                               y: base.center.y + shift * sin(r))
                        liveSize = CGSize(width: newWidth, height: h)
                    }
                    .onEnded { _ in
                        if let s = liveSize {
                            onResize(min(max(Double(s.width / contentRect.width), 0.02), 1),
                                     Double(furniture.height))
                        }
                        if let p = livePosition { onMove(normalized(p)) }
                        liveSize = nil; livePosition = nil; lengthResizeBase = nil
                    }
            )
    }

    private var resizeDrag: some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasContentSpace))
            .onChanged { value in
                onSelect()
                let r = displayRotation * .pi / 180
                let dx = value.location.x - center.x, dy = value.location.y - center.y
                // Project the pointer into the furniture's unrotated frame; the
                // half-extent is its distance from centre, so the size is doubled.
                let localX = dx * cos(r) + dy * sin(r)
                let localY = -dx * sin(r) + dy * cos(r)
                if furniture.kind.lockAspectRatio {
                    // Scale uniformly from whichever axis is pulled furthest, so the
                    // width:height ratio never changes.
                    let curW = max(furniture.width * contentRect.width, 1)
                    let curH = max(furniture.height * contentRect.height, 1)
                    let s = max(abs(localX) * 2 / curW, abs(localY) * 2 / curH)
                    liveSize = CGSize(width: max(curW * s, 14), height: max(curH * s, 14))
                } else if widthOnlyResize {
                    // Only the length (long axis) resizes; the cross-section is fixed.
                    let curH = max(furniture.height * contentRect.height, 1)
                    liveSize = CGSize(width: max(abs(localX) * 2, 14), height: curH)
                } else {
                    liveSize = CGSize(width: max(abs(localX) * 2, 14), height: max(abs(localY) * 2, 14))
                }
            }
            .onEnded { _ in
                if let s = liveSize {
                    liveSize = nil
                    let newW = min(max(Double(s.width / contentRect.width), 0.02), 1)
                    if widthOnlyResize {
                        // Keep the fixed cross-section exactly — no min-clamp, which on
                        // a wide map would inflate the thin dimension.
                        onResize(newW, furniture.height)
                    } else {
                        onResize(newW, min(max(Double(s.height / contentRect.height), 0.02), 1))
                    }
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
        if furniture.kind.isTube {
            Button { onToggleModifier() } label: {
                Label(furniture.hasModifier ? "Remove Modifier" : "Add Modifier",
                      systemImage: furniture.hasModifier ? "rectangle.slash" : "rectangle.on.rectangle")
            }
        }
        if furniture.kind.canMountSoftbox {
            Button { onAddSoftbox() } label: {
                Label(furniture.hasSoftbox ? "Remove Softbox" : "Add Softbox",
                      systemImage: furniture.hasSoftbox ? "rectangle.slash" : "rectangle.portrait.on.rectangle.portrait")
            }
        }
        if furniture.kind.isLight {
            Button { onArmResize() } label: {
                Label("Resize", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if canResetSize {
                Button { onResetSize() } label: {
                    Label("Reset Size", systemImage: "arrow.counterclockwise")
                }
            }
        }
        Divider()
        Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { onDelete() } label: {
            Label(selectedCount > 1 ? "Delete \(selectedCount) Items" : "Delete", systemImage: "trash")
        }
    }
}
