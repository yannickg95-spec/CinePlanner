//
//  SceneMapEditorView+Scale.swift
//  CinePlanner
//
//  The map's real-world scale: measuring a wall or two points, and the length labels.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    /// Enters floor-plan drawing mode, clearing any image background (one
    /// background per scene).
    /// Calibrate the map from the first wall's real length: the wall's on-map length
    /// (a fraction of the square) maps to the entered metres, giving the map's
    /// metres-wide — which every marker and furniture size, and the live wall
    /// readouts, then scale against.
    /// Opens the length prompt for any wall (right-click → Set/Change Length). Setting
    /// it recalibrates the whole map's scale from this wall, so every other wall,
    /// marker, furniture piece, door and window matches. Pre-fills the current real
    /// length when the map is already scaled.
    func beginWallScale(_ id: UUID) {
        drawToScale = false
        if let wall = floorPlan.wall(id), let metres = realLength(of: wall) {
            scaleInput = String(format: "%g", (metres * 100).rounded() / 100)
        } else {
            scaleInput = ""
        }
        scaleWallID = id
    }

    func confirmScaleLength() {
        defer { scaleWallID = nil; scaleInput = ""; drawToScale = false }
        guard let wid = scaleWallID,
              let wall = floorPlan.walls.first(where: { $0.id == wid }),
              let metres = Double(scaleInput.replacingOccurrences(of: ",", with: ".")),
              metres > 0 else { return }
        let normLen = floorPlan.length(wall)
        guard normLen > 1e-6 else { return }
        let metersWide = metres / normLen
        // Keep furniture/lights at their real size across a scale change.
        rescaleFurniture(from: mapMetersWide ?? impliedMetersWide, to: metersWide)
        scene.sceneMapMetersWide = metersWide
        mapMetersWide = metersWide
        // Now that the map has a real scale, size every door to a real 85 cm.
        let doorWidth = doorNormalizedWidth(metersWide: metersWide)
        for i in floorPlan.openings.indices where floorPlan.openings[i].kind == .door {
            floorPlan.openings[i].width = doorWidth
        }
        persistFloorPlan()
        saveContext()
    }

    /// Keeps every furniture/light piece at the same REAL size when the map's scale
    /// changes: their stored size is normalized (realSize ÷ metresWide), so a scale
    /// change must multiply it by old ÷ new. (People/camera markers derive their size
    /// from the scale directly, so they update on their own.)
    func rescaleFurniture(from oldMeters: Double?, to newMeters: Double) {
        guard let old = oldMeters, old > 0, newMeters > 0, abs(old - newMeters) > 1e-9 else { return }
        let ratio = old / newMeters
        for i in doc.furniture.indices {
            doc.furniture[i].width *= ratio
            doc.furniture[i].height *= ratio
        }
        persist()
    }

    // MARK: - Set true scale (two points on an image background)

    func startScaleMeasure() {
        cameraInfoElementID = nil
        selectedIDs = []; furnitureSelectedID = nil; furnitureSelectedIDs = []; arrowSelectedID = nil
        openingSelectedID = nil; wallSelectedID = nil
        scaleMeasurePoints = []
        scaleMeasureActive = true
    }

    func cancelScaleMeasure() {
        scaleMeasureActive = false
        scaleMeasurePoints = []
    }

    func recordScalePoint(_ loc: CGPoint, in rect: CGRect) {
        scaleMeasurePoints.append(normalizedFromCanvas(loc, in: rect))
        if scaleMeasurePoints.count >= 2 {
            scaleMeasureInput = ""
            scaleMeasurePrompt = true
        }
    }

    func applyTrueScaleFromPrompt() {
        let normalized = scaleMeasureInput.replacingOccurrences(of: ",", with: ".")
        guard scaleMeasurePoints.count == 2,
              let metres = Double(normalized), metres > 0 else { cancelScaleMeasure(); return }
        let p0 = scaleMeasurePoints[0], p1 = scaleMeasurePoints[1]
        let dNorm = hypot(p1.x - p0.x, p1.y - p0.y)
        guard dNorm > 1e-6 else { cancelScaleMeasure(); return }
        let newMeters = metres / Double(dNorm)
        rescaleFurniture(from: mapMetersWide ?? impliedMetersWide, to: newMeters)
        scene.sceneMapMetersWide = newMeters
        mapMetersWide = newMeters
        saveContext()
        cancelScaleMeasure()
    }

    /// A wall's real length in the scene, or nil until the map is scaled. Reads the
    /// normalized length against the map's metres-wide.
    func realLength(of wall: Wall) -> Double? {
        guard let metersWide = mapMetersWide, metersWide > 0 else { return nil }
        return floorPlan.length(wall) * metersWide
    }

    /// A length in metres as a compact label: "3.45 m", or "45 cm" under a metre.
    func lengthLabel(_ metres: Double) -> String {
        metres < 1 ? "\(Int((metres * 100).rounded())) cm" : String(format: "%.2f m", metres)
    }

    /// Standard real door width (85 cm) expressed in normalized content units for a
    /// map of the given metres-wide, so a placed door draws at the right size.
    func doorNormalizedWidth(metersWide: Double) -> Double {
        guard metersWide > 0 else { return 0.08 }
        return 0.85 / metersWide
    }

    /// An opening's real width in metres, or nil until the map is scaled.
    func openingRealWidth(_ opening: Opening) -> Double? {
        guard let metersWide = mapMetersWide, metersWide > 0 else { return nil }
        return opening.width * metersWide
    }

    /// The floor plan's centre (normalized), used to push each wall's label to the
    /// outside of the room.
    func floorPlanCentroid() -> CGPoint {
        let vs = floorPlan.vertices
        guard !vs.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sx = vs.reduce(0.0) { $0 + $1.x }, sy = vs.reduce(0.0) { $0 + $1.y }
        return CGPoint(x: sx / Double(vs.count), y: sy / Double(vs.count))
    }

    /// Ray-cast test (normalized coords): is `p` inside the region the walls enclose?
    /// Counts how many wall segments a rightward ray from `p` crosses — odd = inside.
    func isInsideRoom(_ p: CGPoint) -> Bool {
        var inside = false
        for wall in floorPlan.walls {
            guard let (a, b) = floorPlan.endpoints(wall) else { continue }
            if (a.y > p.y) != (b.y > p.y) {
                let xCross = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < xCross { inside.toggle() }
            }
        }
        return inside
    }

    /// Where a wall's measurement label sits (canvas points): beside the wall on the
    /// outside of the room by default, plus the user's saved nudge.
    func wallLabelPoint(_ wall: Wall, in rect: CGRect) -> CGPoint? {
        guard let (a, b) = floorPlan.endpoints(wall) else { return nil }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        var perp = len > 1e-6 ? CGPoint(x: -dy / len, y: dx / len) : CGPoint(x: 0, y: -1)
        // Put the label OUTSIDE the room: probe a little to each side and take the
        // one that lands outside the walls (a point-in-polygon test, which is correct
        // even for L-shaped / non-convex rooms where "away from the centre" isn't).
        // Fall back to the centroid direction when the walls don't enclose a clear
        // inside (an open plan).
        let probe = 0.02
        let outPlus = !isInsideRoom(CGPoint(x: mid.x + perp.x * probe, y: mid.y + perp.y * probe))
        let outMinus = !isInsideRoom(CGPoint(x: mid.x - perp.x * probe, y: mid.y - perp.y * probe))
        if outMinus && !outPlus {
            perp = CGPoint(x: -perp.x, y: -perp.y)
        } else if outPlus == outMinus {
            let c = floorPlanCentroid()
            let toMid = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
            if perp.x * toMid.x + perp.y * toMid.y < 0 { perp = CGPoint(x: -perp.x, y: -perp.y) }
        }
        // Offset so the pill's NEAR EDGE sits a small, constant on-screen distance
        // from the wall, whatever the zoom or wall angle. The pill is a horizontal
        // capsule, so its reach toward the wall is ~its half-width when offset
        // sideways (a vertical wall) and ~its half-height when offset up/down (a
        // horizontal wall); computing the offset from that keeps it tight without
        // touching, instead of a fixed distance that reads far on vertical walls.
        let halfW = 24.0, halfH = 9.0, margin = 5.0
        let clearPts = margin + halfW * abs(perp.x) + halfH * abs(perp.y)
        let denom = max(Double(rect.width) * Double(zoom) * mapPlacement.scale, 1)
        let gap = clearPts / denom
        let nx = mid.x + perp.x * gap + Double(wall.labelOffset.width)
        let ny = mid.y + perp.y * gap + Double(wall.labelOffset.height)
        return CGPoint(x: rect.minX + CGFloat(nx) * rect.width,
                       y: rect.minY + CGFloat(ny) * rect.height)
    }

    /// Counter-scale for on-canvas measurement labels so they keep a constant,
    /// readable on-screen size instead of growing with the canvas zoom or the map's
    /// adjust (placement) scale — matching how marker labels behave.
    var labelCounterScale: CGFloat {
        1 / max(zoom * CGFloat(mapPlacement.scale), 0.0001)
    }

    /// Counter-rotation that cancels the map's rotation, so an in-group measurement
    /// label stays upright and horizontally readable at any map rotation.
    var labelUprightRotation: Double {
        -(mapPlacement.rotation - reframeTurn)
    }

    /// A pill showing a wall's real length. Always shows its context menu; only
    /// draggable (to nudge it clear of markers) while editing the plan.
    @ViewBuilder
    func wallMeasureLabel(_ wall: Wall, in rect: CGRect, draggable: Bool) -> some View {
        if let metres = realLength(of: wall), let p = wallLabelPoint(wall, in: rect) {
            Text(lengthLabel(metres))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color(white: 0.1).opacity(0.78), in: Capsule())
                .fixedSize()
                .contentShape(Capsule())
                .contextMenu {
                    Button { beginWallScale(wall.id) } label: {
                        Label("Change Length…", systemImage: "ruler")
                    }
                    Button { toggleMeasurementLabels() } label: {
                        Label("Hide Distance Labels", systemImage: "eye.slash")
                    }
                }
                .scaleEffect(labelCounterScale)
                .rotationEffect(.degrees(labelUprightRotation))
                .position(p)
                .gesture(
                    // Read the drag in the canvas coordinate space (logical points,
                    // before zoom and the map's placement scale), so the label's
                    // counter-scale doesn't distort the drag and the nudge tracks the
                    // finger 1:1 at any zoom. The offset is stored normalized.
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                        .onChanged { value in
                            guard rect.width > 0, rect.height > 0 else { return }
                            let base = wallLabelDrag?.id == wall.id
                                ? wallLabelDrag!.base : wall.labelOffset
                            if wallLabelDrag?.id != wall.id { wallLabelDrag = (wall.id, base) }
                            let dx = value.translation.width / rect.width
                            let dy = value.translation.height / rect.height
                            setWallLabelOffset(wall.id, CGSize(width: base.width + dx,
                                                               height: base.height + dy))
                        }
                        .onEnded { _ in wallLabelDrag = nil; persistFloorPlan() },
                    // Only draggable while editing; otherwise the label is inert
                    // (its context menu still works).
                    including: draggable ? .all : .none)
        }
    }

    func setWallLabelOffset(_ id: UUID, _ offset: CGSize) {
        guard let i = floorPlan.walls.firstIndex(where: { $0.id == id }) else { return }
        floorPlan.walls[i].labelOffset = offset
    }
}
