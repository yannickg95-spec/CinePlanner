//
//  SceneMapEditorView+Arrows.swift
//  CinePlanner
//
//  Movement arrows between markers, and their bend points.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Movement arrows

    /// Begins a move: the next canvas click places the second marker.
    func startMove(_ id: UUID, _ direction: MoveDirection) {
        pendingMove = (origin: id, direction: direction)
        selectedIDs = []
    }

    /// Completes a move. If the click lands on an existing marker of the same
    /// kind, the arrow connects to it; otherwise a new marker is dropped there.
    /// Places the moved marker from a point in the untransformed root space (so the white
    /// margin works): map it back to a pre-placement canvas point, then reuse the normal
    /// placement path (which also snaps to a nearby existing marker).
    func placeMovedMarkerAtScreen(_ p: CGPoint, in rect: CGRect, canvas: CGSize) {
        let n = normalizedFromScreen(p, in: rect, canvas: canvas)
        let loc = CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)
        placeMovedMarker(at: loc, in: rect)
    }

    func placeMovedMarker(at loc: CGPoint, in rect: CGRect) {
        defer { pendingMove = nil }
        guard let move = pendingMove,
              let origin = doc.elements.first(where: { $0.id == move.origin }) else { return }

        let endID: UUID
        if let target = nearestElement(to: loc, in: rect, kind: origin.kind, excluding: origin.id) {
            endID = target.id
        } else {
            let n = normalizedFromCanvas(loc, in: rect, clamped: false)
            var moved = MapElement(kind: origin.kind, x: n.x, y: n.y)
            moved.colorHex = origin.colorHex
            moved.rotation = origin.rotation
            moved.shotUID = origin.shotUID
            moved.label = origin.label
            doc.elements.append(moved)
            endID = moved.id
        }

        let (fromID, toID) = move.direction == .to ? (origin.id, endID) : (endID, origin.id)
        // Don't add a second identical arrow if this link already exists.
        if !doc.arrows.contains(where: { $0.fromID == fromID && $0.toID == toID }) {
            doc.arrows.append(MapArrow(fromID: fromID, toID: toID))
        }
        selectedIDs = [endID]
        persist()
    }

    /// The nearest marker of `kind` within tapping distance of a canvas point,
    /// excluding `excluding`. Used to link a move to an existing marker.
    func nearestElement(to loc: CGPoint, in rect: CGRect,
                                kind: MapElement.Kind, excluding: UUID) -> MapElement? {
        let hitRadius: CGFloat = 24
        var best: (element: MapElement, distance: CGFloat)?
        for element in doc.elements where element.kind == kind && element.id != excluding {
            let c = canvasPoint(element.x, element.y, in: rect)
            let d = hypot(c.x - loc.x, c.y - loc.y)
            if d <= hitRadius, best == nil || d < best!.distance { best = (element, d) }
        }
        return best?.element
    }

    // MARK: Arrow pivots

    func selectArrow(_ id: UUID) {
        arrowSelectedID = id
        selectedIDs = []
        openingSelectedID = nil
        wallSelectedID = nil
        furnitureSelectedID = nil
        furnitureSelectedIDs = []
    }

    /// Whether an arrow shows: it belongs to the marker layer it connects (both its
    /// endpoints are the same kind), so it hides when that layer is hidden.
    func arrowVisible(_ arrow: MapArrow) -> Bool {
        let el = doc.elements.first { $0.id == arrow.fromID } ?? doc.elements.first { $0.id == arrow.toID }
        guard let kind = el?.kind else { return false }
        return kind == .camera ? doc.showCameras : doc.showCharacters
    }

    @ViewBuilder
    func arrowHitView(_ arrow: MapArrow, in rect: CGRect) -> some View {
        if let pts = arrowCanvasPoints(arrow, in: rect), pts.count >= 2 {
            // Frame the hit view to the arrow's own bounding box (in local coords),
            // not the whole canvas: a `.contextMenu` anchors to its view's frame, so
            // a canvas-filling hit view put the long-press menu in the middle of the
            // screen instead of beside the arrow. A filled (near-invisible) shape,
            // rather than Color.clear + contentShape, stays reliably tappable.
            let width = 20 + sceneMapHandleSlop * 2
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = CGRect(x: xs.min()! - width / 2, y: ys.min()! - width / 2,
                             width: (xs.max()! - xs.min()!) + width,
                             height: (ys.max()! - ys.min()!) + width)
            let local = pts.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
            ArrowHitShape(points: local)
                .fill(Color.black.opacity(0.001))
                .frame(width: box.width, height: box.height)
                .onTapGesture { selectArrow(arrow.id) }
                .onContinuousHover(coordinateSpace: .named(SceneMapEditorView.canvasSpace)) { phase in
                    if case .active(let location) = phase { arrowHover = location }
                }
                .contextMenu {
                    Button {
                        selectArrow(arrow.id)
                        // Hover gives the exact spot on macOS; touch has no hover, so
                        // fall back to the arrow's midpoint (then it can be dragged).
                        let mid = CGPoint(x: (pts.first!.x + pts.last!.x) / 2,
                                          y: (pts.first!.y + pts.last!.y) / 2)
                        addPivot(to: arrow.id, at: box.contains(arrowHover) ? arrowHover : mid, in: rect)
                    } label: {
                        Label("Add Pivot Point", systemImage: "smallcircle.filled.circle")
                    }
                    Divider()
                    Button(role: .destructive) { deleteArrow(arrow.id) } label: {
                        Label("Delete Arrow", systemImage: "trash")
                    }
                }
                .position(x: box.midX, y: box.midY)
        }
    }

    @ViewBuilder
    func pivotHandle(arrowID: UUID, index: Int, in rect: CGRect) -> some View {
        if let arrow = doc.arrows.first(where: { $0.id == arrowID }), index < arrow.pivots.count {
            let pivot = arrow.pivots[index]
            Circle().fill(.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: 12, height: 12)
                .contentShape(Circle().inset(by: -(7 + sceneMapHandleSlop)))
                .gesture(
                    DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                        .onChanged { value in movePivot(arrowID, index, to: value.location, in: rect) }
                        .onEnded { _ in persist() }
                )
                .contextMenu {
                    Button(role: .destructive) { removePivot(arrowID, index) } label: {
                        Label("Remove Pivot", systemImage: "xmark")
                    }
                }
                .position(canvasPoint(pivot.x, pivot.y, in: rect))
        }
    }

    /// Inserts a pivot at the clicked point, into the nearest segment.
    func addPivot(to arrowID: UUID, at loc: CGPoint, in rect: CGRect) {
        guard let ai = doc.arrows.firstIndex(where: { $0.id == arrowID }),
              let from = doc.elements.first(where: { $0.id == doc.arrows[ai].fromID }),
              let to = doc.elements.first(where: { $0.id == doc.arrows[ai].toID }) else { return }
        let n = normalizedFromCanvas(loc, in: rect)
        let full = [CGPoint(x: from.x, y: from.y)] + doc.arrows[ai].pivots + [CGPoint(x: to.x, y: to.y)]
        var bestSegment = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for s in 0..<(full.count - 1) {
            let d = distanceToSegment(n, full[s], full[s + 1])
            if d < bestDistance { bestDistance = d; bestSegment = s }
        }
        doc.arrows[ai].pivots.insert(n, at: bestSegment)
        persist()
    }

    func movePivot(_ arrowID: UUID, _ index: Int, to loc: CGPoint, in rect: CGRect) {
        guard let ai = doc.arrows.firstIndex(where: { $0.id == arrowID }),
              index < doc.arrows[ai].pivots.count else { return }
        doc.arrows[ai].pivots[index] = normalizedFromCanvas(loc, in: rect)
    }

    func removePivot(_ arrowID: UUID, _ index: Int) {
        guard let ai = doc.arrows.firstIndex(where: { $0.id == arrowID }),
              index < doc.arrows[ai].pivots.count else { return }
        doc.arrows[ai].pivots.remove(at: index)
        persist()
    }

    func deleteArrow(_ id: UUID) {
        doc.arrows.removeAll { $0.id == id }
        persist()
    }

    /// Distance from a point to a segment, all in normalized coordinates.
    func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-12 { return Double(hypot(p.x - a.x, p.y - a.y)) }
        var t = Double(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)
        t = min(max(t, 0), 1)
        let cx = a.x + CGFloat(t) * dx, cy = a.y + CGFloat(t) * dy
        return Double(hypot(p.x - cx, p.y - cy))
    }
}

/// A smooth Catmull-Rom curve through the given points (used for movement
/// arrows so their bends at pivots are rounded, not sharp).
nonisolated func smoothPolyline(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard pts.count >= 2 else { return path }
    guard pts.count > 2 else {
        path.move(to: pts[0]); path.addLine(to: pts[1]); return path
    }
    path.move(to: pts[0])
    for i in 0..<(pts.count - 1) {
        let p0 = i > 0 ? pts[i - 1] : pts[i]
        let p1 = pts[i]
        let p2 = pts[i + 1]
        let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

/// A thick hit region along an arrow's smooth path (canvas points), for
/// clicking the arrow to add pivots or delete it.
nonisolated struct ArrowHitShape: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else { return Path() }
        // Wider on touch (a finger's worth) so the thin drawn arrow is easy to tap.
        let width = 20 + sceneMapHandleSlop * 2
        return smoothPolyline(points).strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
