//
//  SceneMapEditorView+Walls.swift
//  CinePlanner
//
//  Editing a drawn floor plan's walls and its doors and windows.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Wall editing

    func canvasPoint(_ nx: Double, _ ny: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(nx) * rect.width, y: rect.minY + CGFloat(ny) * rect.height)
    }

    /// Invisible strip along a wall: tap to select, drag to move (translating
    /// both endpoint vertices, so joined walls follow).
    @ViewBuilder
    func wallHandle(_ wall: Wall, in rect: CGRect) -> some View {
        if let (a, b) = floorPlan.endpoints(wall) {
            let p1 = canvasPoint(a.x, a.y, in: rect)
            let p2 = canvasPoint(b.x, b.y, in: rect)
            let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            let length = hypot(p2.x - p1.x, p2.y - p1.y)
            let angle = Angle(radians: Double(atan2(p2.y - p1.y, p2.x - p1.x)))
            Rectangle().fill(Color.clear)
                .frame(width: max(length, 1), height: 18)
                .contentShape(Rectangle())
                // Tap routes to the draw handler (place a point, or drop a door/window
                // on this wall); drag moves the whole wall.
                .gesture(SpatialTapGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                    .onEnded { value in handleDrawClick(value.location, in: rect) })
                .gesture(wallMoveGesture(wall.id, in: rect))
                .contextMenu {
                    Button { beginWallScale(wall.id) } label: {
                        Label(realLength(of: wall) == nil ? "Set Length…" : "Change Length…",
                              systemImage: "ruler")
                    }
                    Button { toggleMeasurementLabels() } label: {
                        Label(floorPlan.hideMeasurements ? "Show Distance Labels" : "Hide Distance Labels",
                              systemImage: floorPlan.hideMeasurements ? "eye" : "eye.slash")
                    }
                    Divider()
                    Button(role: .destructive) { deleteWall(wall.id) } label: {
                        Label("Delete Wall", systemImage: "trash")
                    }
                }
                .rotationEffect(angle)
                .position(mid)
        }
    }

    /// A right-click (and tap-to-select) target along a wall, present outside Edit too,
    /// so the wall's menu (length, distance labels, delete) is reachable without entering
    /// Edit. Deliberately carries no draw/move gestures — those live in the drawing layer.
    @ViewBuilder
    func wallContextHitArea(_ wall: Wall, in rect: CGRect) -> some View {
        if let (a, b) = floorPlan.endpoints(wall) {
            let p1 = canvasPoint(a.x, a.y, in: rect)
            let p2 = canvasPoint(b.x, b.y, in: rect)
            let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            let length = hypot(p2.x - p1.x, p2.y - p1.y)
            let angle = Angle(radians: Double(atan2(p2.y - p1.y, p2.x - p1.x)))
            Rectangle().fill(Color.clear)
                .frame(width: max(length, 1), height: 18)
                .contentShape(Rectangle())
                .onTapGesture { selectWall(wall.id) }
                .contextMenu {
                    Button { beginWallScale(wall.id) } label: {
                        Label(realLength(of: wall) == nil ? "Set Length…" : "Change Length…",
                              systemImage: "ruler")
                    }
                    Button { toggleMeasurementLabels() } label: {
                        Label(floorPlan.hideMeasurements ? "Show Distance Labels" : "Hide Distance Labels",
                              systemImage: floorPlan.hideMeasurements ? "eye" : "eye.slash")
                    }
                    Divider()
                    Button(role: .destructive) { deleteWall(wall.id) } label: {
                        Label("Delete Wall", systemImage: "trash")
                    }
                }
                .rotationEffect(angle)
                .position(mid)
        }
    }

    /// A right-click (and tap-to-select) target over a door / window, present outside Edit
    /// too, so its menu (flip, width, delete, …) is reachable without entering Edit.
    @ViewBuilder
    func openingContextHitArea(_ opening: Opening, in rect: CGRect) -> some View {
        if let wall = floorPlan.wall(opening.wallID), let (a, b) = floorPlan.endpoints(wall),
           let center = openingCenter(opening, in: rect) {
            let dir = unit(CGPoint(x: b.x - a.x, y: b.y - a.y))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let halfPts = CGFloat(opening.width) * rect.width / 2
            let angle = Angle(radians: Double(atan2(dir.y, dir.x)))
            let length = max(halfPts * 2 + 6, 22)
            let isDoor = opening.kind == .door
            let reach = max(halfPts * 2, 24)
            let thickness: CGFloat = isDoor ? reach + 12 : 18
            let swing = opening.flipped ? CGPoint(x: -perp.x, y: -perp.y) : perp
            let hitCenter = isDoor
                ? CGPoint(x: center.x + swing.x * reach / 2, y: center.y + swing.y * reach / 2)
                : center
            Rectangle().fill(Color.clear)
                .frame(width: length, height: thickness)
                .contentShape(Rectangle())
                .onTapGesture { selectOpening(opening.id) }
                .contextMenu { openingMenu(opening) }
                .rotationEffect(angle)
                .position(hitCenter)
        }
    }

    /// A corner handle shown while drawing (over the click catcher, so it wins the
    /// gesture): drag it to move the corner, or tap it to begin a new wall from it —
    /// or, if a chain is already in progress, to finish the wall on it.
    func drawingVertexHandle(_ vertex: FloorVertex, in rect: CGRect) -> some View {
        // Transparent hit area over the drawn blue dot, generous enough to grab.
        Circle().fill(Color.clear)
            .frame(width: 26, height: 26)
            .contentShape(Circle().inset(by: -sceneMapHandleSlop))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                    .onChanged { value in
                        if vertexDragID != vertex.id { vertexDragID = vertex.id; vertexDragMoved = false }
                        if hypot(value.translation.width, value.translation.height) > 4 { vertexDragMoved = true }
                        if vertexDragMoved { moveVertex(vertex.id, to: value.location, in: rect) }
                    }
                    .onEnded { _ in
                        if vertexDragMoved { persistFloorPlan() } else { vertexChainTap(vertex.id) }
                        vertexDragID = nil; vertexDragMoved = false
                    }
            )
            .position(canvasPoint(vertex.x, vertex.y, in: rect))
    }

    /// Tapping a corner while drawing: start a new wall from it, or finish the
    /// in-progress wall on it (joining/closing the room).
    func vertexChainTap(_ id: UUID) {
        guard floorPlan.vertex(id) != nil else { return }
        if let last = chainLastVertex, last != id {
            floorPlan.walls.append(Wall(a: last, b: id))
            chainLastVertex = nil
        } else {
            chainLastVertex = id
        }
        persistFloorPlan()
    }

    func wallMoveGesture(_ id: UUID, in rect: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                selectWall(id)
                guard let wall = floorPlan.wall(id),
                      let ai = floorPlan.vertices.firstIndex(where: { $0.id == wall.a }),
                      let bi = floorPlan.vertices.firstIndex(where: { $0.id == wall.b }) else { return }
                if wallDragOrigin?.id != id {
                    wallDragOrigin = (id, floorPlan.vertices[ai].point, floorPlan.vertices[bi].point)
                }
                guard let origin = wallDragOrigin else { return }
                let dx = Double(value.translation.width) / Double(rect.width)
                let dy = Double(value.translation.height) / Double(rect.height)
                floorPlan.vertices[ai].x = origin.a.x + dx
                floorPlan.vertices[ai].y = origin.a.y + dy
                floorPlan.vertices[bi].x = origin.b.x + dx
                floorPlan.vertices[bi].y = origin.b.y + dy
            }
            .onEnded { _ in wallDragOrigin = nil; persistFloorPlan() }
    }

    func selectWall(_ id: UUID) {
        wallSelectedID = id
        openingSelectedID = nil
        selectedIDs = []
        arrowSelectedID = nil
        furnitureSelectedID = nil
        furnitureSelectedIDs = []
    }

    func moveVertex(_ id: UUID, to loc: CGPoint, in rect: CGRect) {
        guard let index = floorPlan.vertices.firstIndex(where: { $0.id == id }) else { return }
        var pos = normalizedFromCanvas(loc, in: rect)

        // Snap straight onto another corner when close, so points can be stacked
        // exactly (e.g. to close a room by landing on an existing corner).
        if let other = nearestVertex(to: pos, in: rect, excluding: id) {
            floorPlan.vertices[index].x = other.x
            floorPlan.vertices[index].y = other.y
            return
        }

        // Snap to axis alignment with any connected corner, so dragged walls
        // straighten just like when drawing. A corner can snap both axes.
        let neighborIDs = floorPlan.walls.compactMap { wall -> UUID? in
            if wall.a == id { return wall.b }
            if wall.b == id { return wall.a }
            return nil
        }
        var snapX: Double?
        var snapY: Double?
        for neighborID in neighborIDs {
            guard let neighbor = floorPlan.vertex(neighborID) else { continue }
            let snapped = axisSnap(from: neighbor.point, to: pos, in: rect)
            if snapped.x != pos.x, snapX == nil || abs(snapped.x - pos.x) < abs(snapX! - pos.x) {
                snapX = snapped.x
            }
            if snapped.y != pos.y, snapY == nil || abs(snapped.y - pos.y) < abs(snapY! - pos.y) {
                snapY = snapped.y
            }
        }
        if let snapX { pos.x = snapX }
        if let snapY { pos.y = snapY }

        // Also line up with the x/y level of any other corner (not just connected
        // ones), so a dragged point aligns with points across the plan.
        pos = alignSnap(pos, in: rect, excluding: id)

        floorPlan.vertices[index].x = pos.x
        floorPlan.vertices[index].y = pos.y
    }

    func deleteWall(_ id: UUID) {
        floorPlan.walls.removeAll { $0.id == id }
        floorPlan.openings.removeAll { $0.wallID == id }
        if wallSelectedID == id { wallSelectedID = nil }
        removeOrphanVertices()
        persistFloorPlan()
    }

    /// Drops vertices no longer used by any wall.
    func removeOrphanVertices() {
        let used = Set(floorPlan.walls.flatMap { [$0.a, $0.b] })
        floorPlan.vertices.removeAll { !used.contains($0.id) && $0.id != chainLastVertex }
    }

    // MARK: - Opening (door/window) editing

    func openingCenter(_ opening: Opening, in rect: CGRect) -> CGPoint? {
        guard let wall = floorPlan.wall(opening.wallID), let (a, b) = floorPlan.endpoints(wall) else { return nil }
        let x = a.x + opening.t * (b.x - a.x)
        let y = a.y + opening.t * (b.y - a.y)
        return CGPoint(x: rect.minX + CGFloat(x) * rect.width, y: rect.minY + CGFloat(y) * rect.height)
    }

    @ViewBuilder
    func openingHandle(_ opening: Opening, in rect: CGRect) -> some View {
        if let wall = floorPlan.wall(opening.wallID), let (a, b) = floorPlan.endpoints(wall),
           let center = openingCenter(opening, in: rect) {
            let dir = unit(CGPoint(x: b.x - a.x, y: b.y - a.y))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let halfPts = CGFloat(opening.width) * rect.width / 2
            let angle = Angle(radians: Double(atan2(dir.y, dir.x)))
            let length = max(halfPts * 2 + 6, 22)   // along the wall
            // Windows are a thin strip on the wall; doors get a taller area
            // shifted over their swing so the arc/leaf is clickable.
            let isDoor = opening.kind == .door
            let reach = max(halfPts * 2, 24)
            let thickness: CGFloat = isDoor ? reach + 12 : 18
            let swing = opening.flipped ? CGPoint(x: -perp.x, y: -perp.y) : perp
            let hitCenter = isDoor
                ? CGPoint(x: center.x + swing.x * reach / 2, y: center.y + swing.y * reach / 2)
                : center
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear)
                    .frame(width: length, height: thickness)
                    .contentShape(Rectangle())
                    .onTapGesture { selectOpening(opening.id) }
                    .gesture(
                        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                            .onChanged { value in
                                selectOpening(opening.id)
                                moveOpening(opening.id, toLocation: value.location, in: rect)
                            }
                            .onEnded { _ in persistFloorPlan() }
                    )
                    .contextMenu { openingMenu(opening) }
                    .rotationEffect(angle)
                    .position(hitCenter)

                // Window width handles at each end.
                if openingSelectedID == opening.id && opening.kind == .window {
                    resizeHandle(opening.id, at: CGPoint(x: center.x - dir.x * halfPts, y: center.y - dir.y * halfPts), in: rect)
                    resizeHandle(opening.id, at: CGPoint(x: center.x + dir.x * halfPts, y: center.y + dir.y * halfPts), in: rect)
                }

                // Temporary width readout while a window is being resized.
                if resizingOpeningID == opening.id, let metres = openingRealWidth(opening) {
                    let side = openingOutwardPerp(perp, center: center, in: rect)
                    Text(lengthLabel(metres))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.92), in: Capsule())
                        .fixedSize()
                        .scaleEffect(labelCounterScale)
                        .rotationEffect(.degrees(labelUprightRotation))
                        .position(x: center.x + side.x * 20, y: center.y + side.y * 20)
                }
            }
        }
    }

    /// The wall-perpendicular direction pointing to the OUTSIDE of the room (away
    /// from the plan's centre), so a label sits clear of the wall rather than on it.
    func openingOutwardPerp(_ perp: CGPoint, center: CGPoint, in rect: CGRect) -> CGPoint {
        let c = floorPlanCentroid()
        let cx = rect.minX + CGFloat(c.x) * rect.width
        let cy = rect.minY + CGFloat(c.y) * rect.height
        let toCenter = CGPoint(x: center.x - cx, y: center.y - cy)
        return (perp.x * toCenter.x + perp.y * toCenter.y) < 0
            ? CGPoint(x: -perp.x, y: -perp.y) : perp
    }

    func resizeHandle(_ id: UUID, at point: CGPoint, in rect: CGRect) -> some View {
        Circle().fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 13, height: 13)
            .contentShape(Circle().inset(by: -(6 + sceneMapHandleSlop)))
            .gesture(
                DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                    .onChanged { value in
                        resizingOpeningID = id
                        resizeWindow(id, handleLocation: value.location, in: rect)
                    }
                    .onEnded { _ in resizingOpeningID = nil; persistFloorPlan() }
            )
            .position(point)
    }

    @ViewBuilder
    func openingMenu(_ opening: Opening) -> some View {
        if opening.kind == .door {
            Button { updateOpening(opening.id) { $0.flipped.toggle() } } label: {
                Label("Flip Vertical", systemImage: "arrow.up.and.down")
            }
            Button { updateOpening(opening.id) { $0.hingeAtEnd.toggle() } } label: {
                Label("Flip Horizontal", systemImage: "arrow.left.and.right")
            }
            Button { updateOpening(opening.id) { $0.closed.toggle() } } label: {
                Text(opening.closed ? "Open Door" : "Closed Door")
            }
        } else {
            Button { updateOpening(opening.id) { $0.width = min($0.width + 0.02, 0.35) } } label: {
                Label("Wider", systemImage: "plus")
            }
            Button { updateOpening(opening.id) { $0.width = max($0.width - 0.02, 0.03) } } label: {
                Label("Narrower", systemImage: "minus")
            }
        }
        Divider()
        Button(role: .destructive) { deleteOpening(opening.id) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    func selectOpening(_ id: UUID) {
        openingSelectedID = id
        selectedIDs = []
        wallSelectedID = nil
        arrowSelectedID = nil
        furnitureSelectedID = nil
        furnitureSelectedIDs = []
    }

    /// Projects a normalized point onto a wall, returning the parameter t.
    func projectT(_ p: CGPoint, onto wall: Wall) -> Double {
        guard let (a, b) = floorPlan.endpoints(wall) else { return 0.5 }
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-9 else { return 0.5 }
        return ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
    }

    /// Slides an opening along its wall, keeping it fully on the wall.
    func moveOpening(_ id: UUID, toLocation loc: CGPoint, in rect: CGRect) {
        guard let index = floorPlan.openings.firstIndex(where: { $0.id == id }),
              let wall = floorPlan.wall(floorPlan.openings[index].wallID) else { return }
        let halfT = min((floorPlan.openings[index].width / 2) / max(floorPlan.length(wall), 1e-6), 0.49)
        let t = projectT(normalizedFromCanvas(loc, in: rect), onto: wall)
        floorPlan.openings[index].t = min(max(t, halfT), 1 - halfT)
    }

    /// Resizes a window symmetrically by dragging an end handle.
    func resizeWindow(_ id: UUID, handleLocation loc: CGPoint, in rect: CGRect) {
        guard let index = floorPlan.openings.firstIndex(where: { $0.id == id }),
              let wall = floorPlan.wall(floorPlan.openings[index].wallID) else { return }
        let opening = floorPlan.openings[index]
        let tHandle = projectT(normalizedFromCanvas(loc, in: rect), onto: wall)
        let halfT = min(abs(tHandle - opening.t), min(opening.t, 1 - opening.t))
        floorPlan.openings[index].width = min(max(2 * halfT * floorPlan.length(wall), 0.03), 0.35)
    }

    func updateOpening(_ id: UUID, _ change: (inout Opening) -> Void) {
        guard let index = floorPlan.openings.firstIndex(where: { $0.id == id }) else { return }
        change(&floorPlan.openings[index])
        persistFloorPlan()
    }

    func deleteOpening(_ id: UUID) {
        floorPlan.openings.removeAll { $0.id == id }
        if openingSelectedID == id { openingSelectedID = nil }
        persistFloorPlan()
    }
}
