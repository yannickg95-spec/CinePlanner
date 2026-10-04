//
//  SceneMapEditorView+FloorPlan.swift
//  CinePlanner
//
//  Drawing a floor plan: walls, snapping, and the drawing commands.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    func startDrawing(toScale: Bool = false) {
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.clearSatelliteCapture()
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        scene.sceneMapBackgroundTransform = .init()
        mapMetersWide = nil
        drawToScale = toScale
        scaleWallID = nil
        scaleInput = ""
        drawTool = .wall
        chainLastVertex = nil
        isDrawing = true
        scene.modelContext?.saveReporting()
    }

    /// Re-enters drawing on the EXISTING floor plan to add more walls, doors and
    /// windows — keeping the current walls, background and (crucially) the scale,
    /// unlike `startDrawing` which wipes them to begin a fresh plan. New walls
    /// inherit the map's metres-wide, so they measure and scale like the rest.
    func resumeDrawing() {
        drawToScale = false        // scale is already set; no calibration prompt
        scaleWallID = nil
        scaleInput = ""
        drawTool = nil        // start unselected: pick Wall/Door/Window first
        chainLastVertex = nil
        wallSelectedID = nil
        openingSelectedID = nil
        selectedIDs = []
        isDrawing = true
    }

    /// Wipes the whole scene map — markers, arrows, furniture, floor plan and
    /// background — back to empty.
    func clearAll() {
        isDrawing = false
        chainLastVertex = nil
        pendingMove = nil
        selectedIDs = []; furnitureSelectedID = nil; furnitureSelectedIDs = []; arrowSelectedID = nil
        wallSelectedID = nil; openingSelectedID = nil
        doc = SceneMapDoc()
        floorPlan = FloorPlan()
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.clearSatelliteCapture()
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        scene.sceneMapLocation = nil
        scene.sceneMapBackgroundTransform = .init()
        persist()
        persistFloorPlan()
    }

    /// Removes the background (image or floor plan). Markers keep their
    /// normalized positions, now relative to the whole canvas.
    func clearBackground() {
        isDrawing = false
        chainLastVertex = nil
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.clearSatelliteCapture()
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        scene.sceneMapBackgroundTransform = .init()
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.modelContext?.saveReporting()
    }

    func toggleMeasurementLabels() {
        floorPlan.hideMeasurements.toggle()
        persistFloorPlan()
    }

    // MARK: - Floor plan drawing

    /// A click while drawing: wall tool adds/extends a chain of points; door and
    /// window tools drop an opening on the nearest wall.
    func handleDrawClick(_ loc: CGPoint, in rect: CGRect) {
        guard let drawTool else { return }   // no tool chosen yet → placing is disabled
        switch drawTool {
        case .wall:
            addChainPoint(loc, in: rect)
        case .door, .window:
            let point = normalizedFromCanvas(loc, in: rect)
            if let (wall, t) = nearestWall(to: point, in: rect) {
                var opening = Opening(kind: drawTool == .door ? .door : .window, wallID: wall.id, t: t)
                // A real-world door is 85 cm wide — set it from the map's scale so
                // it's drawn at the correct size. Windows keep their default until
                // the user resizes them.
                if drawTool == .door, let m = mapMetersWide, m > 0 {
                    opening.width = doorNormalizedWidth(metersWide: m)
                }
                floorPlan.openings.append(opening)
                persistFloorPlan()
            }
        }
    }

    /// Adds a corner point. If it lands on an existing vertex, the chain joins
    /// to it (closing a loop) and ends; otherwise a new point (and a wall from
    /// the previous point) is created and the chain continues.
    func addChainPoint(_ loc: CGPoint, in rect: CGRect) {
        let n = normalizedFromCanvas(loc, in: rect)
        if let existing = nearestVertex(to: n, in: rect, excluding: chainLastVertex) {
            if let last = chainLastVertex, last != existing.id {
                // Continuing a chain onto an existing corner joins/closes it.
                floorPlan.walls.append(Wall(a: last, b: existing.id))
                chainLastVertex = nil
            } else {
                // No chain yet: start a new wall from this existing corner.
                chainLastVertex = existing.id
            }
            persistFloorPlan()
            return
        }
        var pos = n
        if let last = chainLastVertex, let lastV = floorPlan.vertex(last) {
            pos = axisSnap(from: lastV.point, to: n, in: rect)
        }
        pos = alignSnap(pos, in: rect)
        let vertex = FloorVertex(x: pos.x, y: pos.y)
        floorPlan.vertices.append(vertex)
        if let last = chainLastVertex {
            floorPlan.walls.append(Wall(a: last, b: vertex.id))
        }
        chainLastVertex = vertex.id
        persistFloorPlan()

        // Drawing to scale: the first wall calibrates the map. Ask for its real
        // length once it exists (two points → one wall) and the map isn't scaled yet.
        if drawToScale, scene.sceneMapMetersWide == nil, floorPlan.walls.count == 1,
           let first = floorPlan.walls.first {
            scaleInput = ""
            scaleWallID = first.id
        }
    }

    /// Ends the current chain, dropping a dangling single point.
    func endChain() {
        if let last = chainLastVertex, !floorPlan.walls.contains(where: { $0.a == last || $0.b == last }) {
            floorPlan.vertices.removeAll { $0.id == last }
        }
        chainLastVertex = nil
        drawHover = nil
        persistFloorPlan()
    }

    /// `clamped` keeps a point on the map (0…1) — right for floor-plan corners and
    /// arrow pivots, which belong to the drawing. Markers pass `false`: they may be
    /// placed in the space around the image.
    func normalizedFromCanvas(_ p: CGPoint, in rect: CGRect, clamped: Bool = true) -> CGPoint {
        let nx = rect.width > 0 ? (p.x - rect.minX) / rect.width : 0
        let ny = rect.height > 0 ? (p.y - rect.minY) / rect.height : 0
        guard clamped else { return CGPoint(x: nx, y: ny) }
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    /// Nearest existing vertex within ~14pt, so clicks snap to corners.
    func nearestVertex(to p: CGPoint, in rect: CGRect, excluding: UUID? = nil) -> FloorVertex? {
        let threshold = 14.0 / max(Double(rect.width), 1)
        return floorPlan.vertices
            .filter { $0.id != excluding }
            .min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }
            .flatMap { hypot($0.x - p.x, $0.y - p.y) < threshold ? $0 : nil }
    }

    /// Snaps a wall to horizontal/vertical when it's within ~12° of an axis,
    /// leaving clearly diagonal walls alone.
    func axisSnap(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        guard hypot(dx, dy) > 1e-6 else { return end }
        let angle = Double(atan2(dy, dx))          // -π…π
        let a = abs(angle)
        let threshold = 12.0 * Double.pi / 180.0
        if a < threshold || a > .pi - threshold { return CGPoint(x: end.x, y: start.y) }  // horizontal
        if abs(a - .pi / 2) < threshold { return CGPoint(x: start.x, y: end.y) }          // vertical
        return end
    }

    /// Aligns a point to the x/y of a nearby existing corner (within ~12pt), so
    /// walls line up — in particular the last wall closes a room cleanly.
    func alignSnap(_ pos: CGPoint, in rect: CGRect, excluding: UUID? = nil) -> CGPoint {
        let threshold = 12.0 / max(Double(rect.width), 1)
        let skip = excluding ?? chainLastVertex
        var p = pos
        var bestX: Double?
        var bestY: Double?
        for vertex in floorPlan.vertices where vertex.id != skip {
            if abs(vertex.x - p.x) < threshold, bestX == nil || abs(vertex.x - p.x) < abs(bestX! - p.x) { bestX = vertex.x }
            if abs(vertex.y - p.y) < threshold, bestY == nil || abs(vertex.y - p.y) < abs(bestY! - p.y) { bestY = vertex.y }
        }
        if let bestX { p.x = bestX }
        if let bestY { p.y = bestY }
        return p
    }

    /// The wall nearest a point (within ~18pt) and the parameter t along it.
    func nearestWall(to p: CGPoint, in rect: CGRect) -> (Wall, Double)? {
        var best: (wall: Wall, t: Double, dist: Double)?
        for wall in floorPlan.walls {
            guard let (a, b) = floorPlan.endpoints(wall) else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1e-9 else { continue }
            var t = Double(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)
            t = min(max(t, 0), 1)
            let cx = a.x + CGFloat(t) * dx, cy = a.y + CGFloat(t) * dy
            let d = Double(hypot(p.x - cx, p.y - cy))
            if best == nil || d < best!.dist { best = (wall, t, d) }
        }
        guard let b = best, b.dist < 18.0 / max(Double(rect.width), 1) else { return nil }
        return (b.wall, b.t)
    }
}
