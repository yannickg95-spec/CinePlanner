//
//  SceneMapEditorView+Drawing.swift
//  CinePlanner
//
//  Drawing the scene map's layers into the canvas: floor plan, arrows, camera views.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    func drawFloorPlan(_ ctx: GraphicsContext, in rect: CGRect) {
        func point(_ nx: Double, _ ny: Double) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(nx) * rect.width, y: rect.minY + CGFloat(ny) * rect.height)
        }
        // A measurement pill, centred on `p`, legible over the map.
        func drawLength(_ text: String, at p: CGPoint) {
            let resolved = ctx.resolve(Text(text).font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white))
            let size = resolved.measure(in: CGSize(width: 240, height: 40))
            let box = CGRect(x: p.x - size.width / 2 - 4, y: p.y - size.height / 2 - 2,
                             width: size.width + 8, height: size.height + 4)
            ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(white: 0.1).opacity(0.78)))
            ctx.draw(resolved, at: p)
        }
        // Fixed dark ink so the plan stays visible on its white paper background in
        // both light and dark mode (a theme-adaptive .primary would vanish on white
        // in dark mode).
        let wallShading = GraphicsContext.Shading.color(Color(white: 0.15))
        let wallWidth: CGFloat = 4

        for wall in floorPlan.walls {
            guard let (a, b) = floorPlan.endpoints(wall) else { continue }
            let p1 = point(a.x, a.y)
            let p2 = point(b.x, b.y)
            func lerp(_ t: Double) -> CGPoint {
                CGPoint(x: p1.x + CGFloat(t) * (p2.x - p1.x), y: p1.y + CGFloat(t) * (p2.y - p1.y))
            }
            let wallLen = max(floorPlan.length(wall), 1e-6)
            let wallOpenings = floorPlan.openings.filter { $0.wallID == wall.id }
            let gaps = wallOpenings
                .map { o -> (Double, Double) in
                    let half = min((o.width / 2) / wallLen, 0.49)
                    return (max(0, o.t - half), min(1, o.t + half))
                }
                .sorted { $0.0 < $1.0 }

            // Wall, with gaps where openings sit.
            var solid = Path()
            var cursor = 0.0
            for gap in gaps {
                if gap.0 > cursor { solid.move(to: lerp(cursor)); solid.addLine(to: lerp(gap.0)) }
                cursor = max(cursor, gap.1)
            }
            if cursor < 1.0 { solid.move(to: lerp(cursor)); solid.addLine(to: lerp(1.0)) }
            let wallSelected = wall.id == wallSelectedID
            ctx.stroke(solid, with: wallSelected ? .color(.accentColor) : wallShading,
                       style: StrokeStyle(lineWidth: wallSelected ? 5 : wallWidth, lineCap: .round))

            // Door / window symbols.
            let dir = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            for o in wallOpenings {
                let half = min((o.width / 2) / wallLen, 0.49)
                let jambA = lerp(max(0, o.t - half))
                let jambB = lerp(min(1, o.t + half))
                let selected = o.id == openingSelectedID
                let symbolShading: GraphicsContext.Shading = selected ? .color(.accentColor) : wallShading

                switch o.kind {
                case .door:
                    let gapLen = hypot(jambB.x - jambA.x, jambB.y - jambA.y)
                    // Hinge jamb (horizontal flip) and swing side (vertical flip).
                    let hinge = o.hingeAtEnd ? jambB : jambA
                    let alongWall = o.hingeAtEnd ? CGPoint(x: -dir.x, y: -dir.y) : dir
                    let swingPerp = o.flipped ? CGPoint(x: -perp.x, y: -perp.y) : perp
                    // A "closed" door is drawn slightly ajar; an open door swings 90°.
                    let openAngle = o.closed ? (10.0 * .pi / 180.0) : (.pi / 2)
                    // Leaf direction rotated `phi` off the wall toward the swing side.
                    func leafDir(_ phi: Double) -> CGPoint {
                        CGPoint(x: alongWall.x * CGFloat(cos(phi)) + swingPerp.x * CGFloat(sin(phi)),
                                y: alongWall.y * CGFloat(cos(phi)) + swingPerp.y * CGFloat(sin(phi)))
                    }
                    let ld = leafDir(openAngle)
                    let leafEnd = CGPoint(x: hinge.x + ld.x * gapLen, y: hinge.y + ld.y * gapLen)
                    var leaf = Path(); leaf.move(to: hinge); leaf.addLine(to: leafEnd)
                    ctx.stroke(leaf, with: symbolShading, lineWidth: 1.5)
                    // Swing arc from the wall to the leaf, sampled as a polyline.
                    var arc = Path()
                    for i in 0...16 {
                        let d = leafDir(openAngle * Double(i) / 16)
                        let pt = CGPoint(x: hinge.x + d.x * gapLen, y: hinge.y + d.y * gapLen)
                        if i == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
                    }
                    ctx.stroke(arc, with: selected ? .color(.accentColor) : .color(Color(white: 0.5)), lineWidth: 1)
                case .window:
                    for sign in [CGFloat(1.6), CGFloat(-1.6)] {
                        var line = Path()
                        line.move(to: CGPoint(x: jambA.x + perp.x * sign, y: jambA.y + perp.y * sign))
                        line.addLine(to: CGPoint(x: jambB.x + perp.x * sign, y: jambB.y + perp.y * sign))
                        ctx.stroke(line, with: symbolShading, lineWidth: 1.4)
                    }
                }
            }
        }

        // Placed walls' length labels are interactive, draggable views (see
        // wallMeasureLabel); only the live segment below is drawn in the canvas.

        // While drawing: show every corner point, and rubber-band from the
        // chain's last point to the cursor.
        if isDrawing {
            for vertex in floorPlan.vertices {
                let c = point(vertex.x, vertex.y)
                let isChainEnd = vertex.id == chainLastVertex
                let r: CGFloat = isChainEnd ? 5 : 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(.accentColor))
            }
            if drawTool == .wall, let last = chainLastVertex, let lastV = floorPlan.vertex(last), let hover = drawHover {
                // Show where the wall will actually land: snap to a nearby corner
                // (closing the room) else axis + alignment snapping.
                let hoverN = normalizedFromCanvas(hover, in: rect)
                let target = nearestVertex(to: hoverN, in: rect, excluding: last)?.point
                    ?? alignSnap(axisSnap(from: lastV.point, to: hoverN, in: rect), in: rect)
                var path = Path()
                path.move(to: point(lastV.x, lastV.y)); path.addLine(to: point(target.x, target.y))
                ctx.stroke(path, with: .color(.accentColor.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                // Live length of the segment being drawn, once the map is scaled.
                if let metersWide = mapMetersWide, metersWide > 0 {
                    let norm = hypot(target.x - lastV.x, target.y - lastV.y)
                    let a = point(lastV.x, lastV.y), b = point(target.x, target.y)
                    drawLength(lengthLabel(norm * metersWide),
                               at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                }
            }
        }
    }

    func unit(_ v: CGPoint) -> CGPoint {
        let m = hypot(v.x, v.y)
        return m > 0 ? CGPoint(x: v.x / m, y: v.y / m) : CGPoint(x: 1, y: 0)
    }

    /// The arrow's polyline in canvas points: from-marker, its pivots, to-marker.
    func arrowCanvasPoints(_ arrow: MapArrow, in rect: CGRect) -> [CGPoint]? {
        guard let from = doc.elements.first(where: { $0.id == arrow.fromID }),
              let to = doc.elements.first(where: { $0.id == arrow.toID }) else { return nil }
        var pts = [arrowEndpoint(from, in: rect)]
        pts += arrow.pivots.map { canvasPoint($0.x, $0.y, in: rect) }
        pts.append(arrowEndpoint(to, in: rect))
        return pts
    }

    /// Where an arrow meets its marker: the marker's live spot while it's being dragged
    /// (so the arrow follows it instead of snapping over on release), shifted by the
    /// live group translation when it's part of a multi-selection drag.
    func arrowEndpoint(_ element: MapElement, in rect: CGRect) -> CGPoint {
        if let live = liveMarkerPositions[element.id] {
            return canvasPoint(Double(live.x), Double(live.y), in: rect)
        }
        var p = canvasPoint(element.x, element.y, in: rect)
        if let t = groupDragTranslation, selectedIDs.contains(element.id),
           selectedIDs.count + furnitureSelectedIDs.count > 1 {
            p.x += t.width; p.y += t.height
        }
        return p
    }

    /// Applies the map group's full transform — the placement (rotate/scale about
    /// the canvas centre, then offset) and the canvas zoom/pan — to a screen-space
    /// graphics context. Content then drawn in logical (`rect`) coordinates
    /// rasterizes crisply at the final on-screen scale, instead of being a 1× bitmap
    /// magnified (and blurred) by the group's `scaleEffect`.
    func applyMapGroupTransform(_ ctx: inout GraphicsContext, in rect: CGRect, canvas: CGSize) {
        let place = mapPlacement
        let cx = canvas.width / 2, cy = canvas.height / 2
        // Placement (outermost): offset, then scale + turn about the canvas centre.
        ctx.translateBy(x: CGFloat(place.offsetX) * rect.width, y: CGFloat(place.offsetY) * rect.height)
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: .degrees(place.rotation - reframeTurn))
        ctx.scaleBy(x: CGFloat(place.scale), y: CGFloat(place.scale))
        ctx.translateBy(x: -cx, y: -cy)
        // Canvas zoom/pan (inner): scaleEffect(zoom, anchor: .center) + offset(pan).
        ctx.translateBy(x: cx * (1 - zoom) + pan.width,
                        y: cy * (1 - zoom) + pan.height)
        ctx.scaleBy(x: zoom, y: zoom)
    }

    /// Draws the floor plan (walls, doors, windows) in a screen-space Canvas that
    /// replicates the map group's transform, so it stays crisp when the map is
    /// zoomed or enlarged with the adjust tool rather than turning into a blurry,
    /// pixelated magnification of a 1× bitmap.
    func drawFloorPlanLayer(_ baseCtx: GraphicsContext, in rect: CGRect, canvas: CGSize) {
        var ctx = baseCtx
        applyMapGroupTransform(&ctx, in: rect, canvas: canvas)
        // Plain white "paper" behind the plan (no grid), so the drawing reads like a
        // floor plan on paper. The linework is drawn in fixed dark ink (see
        // drawFloorPlan) so it stays visible on white in dark mode too.
        ctx.fill(Path(rect), with: .color(.white))
        drawFloorPlan(ctx, in: rect)
    }

    func drawArrows(_ baseCtx: GraphicsContext, in rect: CGRect, canvas: CGSize) {
        // This Canvas sits outside the map group's transform, so replicate that whole
        // transform on the context, then draw in logical (rect) coordinates.
        var ctx = baseCtx
        applyMapGroupTransform(&ctx, in: rect, canvas: canvas)
        // Counter-scale the shaft width and arrowhead so they don't balloon with the
        // map zoom — the path (endpoints, and the trim that clears the markers) still
        // scales, but the body thins and the head shrinks as you zoom in. `pow(…, 0.7)`
        // makes this a bit gentler than a full 1/zoom counter-scale. (Widths are in
        // pre-scale units; the ctx scale multiplies them back up.) Dividing by the
        // placement scale keeps them constant as the whole map group is scaled too.
        func markerScale(_ el: MapElement) -> CGFloat {
            sceneMarkerScale(kind: el.kind, metersWide: mapMetersWide, cameraMeters: mapCameraMeters,
                             mapWidthPoints: rect.width, viewable: scene.sceneMapViewableMarkerSize)
        }
        for arrow in doc.arrows {
            guard var pts = arrowCanvasPoints(arrow, in: rect), pts.count >= 2,
                  let from = doc.elements.first(where: { $0.id == arrow.fromID }) else { continue }
            // An arrow belongs to the marker layer it connects, so it ghosts with it.
            let layerVisible = from.kind == .camera ? doc.showCameras : doc.showCharacters
            let shading = GraphicsContext.Shading.color(Color(hex: from.colorHex))
            // Clear the marker icons at both ends, whatever their size or rotation: the
            // icon fits a 40·scale circle, so trim by that radius (rotation-independent)
            // plus a gap. Each end uses its own marker's scale.
            let toEl = doc.elements.first(where: { $0.id == arrow.toID })
            let fromScale = markerScale(from)
            let toScale = toEl.map(markerScale) ?? fromScale
            let gap: CGFloat = 6
            let startTrim = 24 * fromScale + gap
            let endTrim = 24 * toScale + gap
            let n = pts.count
            let ds = unit(CGPoint(x: pts[1].x - pts[0].x, y: pts[1].y - pts[0].y))
            pts[0] = CGPoint(x: pts[0].x + ds.x * startTrim, y: pts[0].y + ds.y * startTrim)
            let de = unit(CGPoint(x: pts[n - 1].x - pts[n - 2].x, y: pts[n - 1].y - pts[n - 2].y))
            pts[n - 1] = CGPoint(x: pts[n - 1].x - de.x * endTrim, y: pts[n - 1].y - de.y * endTrim)

            // Shaft/head scale with the markers (same units as the trim), so the arrow
            // stays in proportion — small markers get a slim shaft and a small head.
            let avgScale = (fromScale + toScale) / 2
            let lineWidth: CGFloat = 6 * avgScale
            // Solid triangular head; the shaft attaches to its base (not the tip).
            let tip = pts[n - 1]
            let headLength: CGFloat = 20 * avgScale
            let headHalfWidth: CGFloat = 11 * avgScale
            let baseCenter = CGPoint(x: tip.x - de.x * headLength, y: tip.y - de.y * headLength)
            var shaftPts = pts
            shaftPts[n - 1] = baseCenter
            let perp = CGPoint(x: -de.y, y: de.x)
            var head = Path()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: baseCenter.x + perp.x * headHalfWidth, y: baseCenter.y + perp.y * headHalfWidth))
            head.addLine(to: CGPoint(x: baseCenter.x - perp.x * headHalfWidth, y: baseCenter.y - perp.y * headHalfWidth))
            head.closeSubpath()
            // Draw shaft + head as one layer and fade it whole when the layer is hidden,
            // so the shaft's round cap overlapping the head doesn't show as a darker spot.
            var arrowCtx = ctx
            arrowCtx.opacity = layerVisible ? 1 : Self.hiddenLayerOpacity
            arrowCtx.drawLayer { layer in
                layer.stroke(smoothPolyline(shaftPts), with: shading,
                             style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                layer.fill(head, with: shading)
            }
        }
    }

    /// Draws a field-of-view wedge — two rays — from every shot-linked camera
    /// whose shot has a focal length. Purely visual; toggled per-scene from a
    /// camera's right-click menu. Cameras without a focal length draw nothing.
    func drawCameraFOV(_ ctx: GraphicsContext, in rect: CGRect) {
        // The horizontal angle of view from the shot's focal length + sensor width:
        //   halfAngle = atan((sensorWidth / 2) / focal).
        // Each camera's sensor width comes from its own FOV basis: a fixed format
        // (S16/S35/LF), or its shot's CineStager sensor (Super-35 fallback).
        // Long enough to cross the map from any interior point; clipped to `rect`.
        let reach = hypot(rect.width, rect.height) * 2
        var ctx = ctx
        ctx.clip(to: Path(rect))
        for element in doc.elements where element.kind == .camera {
            guard let uid = element.shotUID,
                  let shot = scene.shots.first(where: { $0.uid == uid }),
                  shot.lensfocal > 0 else { continue }
            let halfAngle = atan((sensorWidthMM(for: element, shot: shot) / 2) / Double(shot.lensfocal))
            let cx = rect.minX + element.x * rect.width
            let cy = rect.minY + element.y * rect.height
            // Facing unit vector matches the marker's rotation handle: (sin, -cos).
            let r = element.rotation * .pi / 180
            let facing = atan2(-cos(r), sin(r))
            let shading = GraphicsContext.Shading.color(Color(hex: element.colorHex).opacity(0.85))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4])
            for side in [-halfAngle, halfAngle] {
                let a = facing + side
                var path = Path()
                path.move(to: CGPoint(x: cx, y: cy))
                path.addLine(to: CGPoint(x: cx + reach * cos(a), y: cy + reach * sin(a)))
                ctx.stroke(path, with: shading, style: style)
            }
        }
    }
}
