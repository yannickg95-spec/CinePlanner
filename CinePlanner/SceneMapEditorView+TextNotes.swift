//
//  SceneMapEditorView+TextNotes.swift
//  CinePlanner
//
//  Free text notes on the scene map.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Text notes

    /// Drops a new text note at the last hovered point (the right-click spot) and opens
    /// the editor to type it.
    func addTextAtLastHover(in rect: CGRect, canvas: CGSize) {
        let screen = lastMapHoverScreen ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        addText(atScreen: screen, in: rect, canvas: canvas)
    }

    /// Touch: a long press on empty map drops a text note under the finger — unless it
    /// landed on a wall, door, window or arrow, whose own long-press menu it is.
    func longPressAddText(in rect: CGRect, canvas: CGSize) {
        guard let point = touchDownScreen,
              !isDrawing, !backgroundAdjustActive, !reframeActive, pendingMove == nil,
              !mapItemUnderTouch(point, in: rect, canvas: canvas) else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        addText(atScreen: point, in: rect, canvas: canvas)
    }

    /// Whether a root-space point lies on a wall, door/window or arrow — the items
    /// inside the map group that carry their own long-press menus (markers, furniture
    /// and notes sit in a layer in front, so they never reach the group's gesture).
    /// Compared in pre-placement canvas units, the same space their hit areas use.
    func mapItemUnderTouch(_ p: CGPoint, in rect: CGRect, canvas: CGSize) -> Bool {
        let n = normalizedFromScreen(p, in: rect, canvas: canvas)
        let q = CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)
        func distance(to a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(max(((q.x - a.x) * dx + (q.y - a.y) * dy) / len2, 0), 1) : 0
            return hypot(q.x - (a.x + t * dx), q.y - (a.y + t * dy))
        }
        if doc.showBackground {
            // Walls: their hit strip is 18 tall, so 9 either side of the line.
            for wall in floorPlan.walls {
                guard let (a, b) = floorPlan.endpoints(wall) else { continue }
                if distance(to: canvasPoint(a.x, a.y, in: rect), canvasPoint(b.x, b.y, in: rect)) <= 9 { return true }
            }
            // Doors/windows: within their width (plus a door's swing) of the centre.
            for opening in floorPlan.openings {
                guard let c = openingCenter(opening, in: rect) else { continue }
                let reach = max(CGFloat(opening.width) * rect.width, 24)
                if hypot(q.x - c.x, q.y - c.y) <= reach { return true }
            }
        }
        for arrow in doc.arrows where arrowVisible(arrow) {
            guard let pts = arrowCanvasPoints(arrow, in: rect), pts.count >= 2 else { continue }
            for i in 0..<(pts.count - 1) where distance(to: pts[i], pts[i + 1]) <= 10 { return true }
        }
        return false
    }

    /// Drops a new text note at a root-space point and opens the editor to type it.
    func addText(atScreen screen: CGPoint, in rect: CGRect, canvas: CGSize) {
        var n = normalizedFromScreen(screen, in: rect, canvas: canvas)
        if !allowsPiecesOutsideMap {
            n.x = min(max(n.x, 0), 1); n.y = min(max(n.y, 0), 1)
        }
        let note = MapText(x: Double(n.x), y: Double(n.y))
        doc.texts.append(note)
        textEditString = ""
        textToEdit = note.id
        persist()
    }

    func editTextNote(_ id: UUID) {
        guard let note = doc.texts.first(where: { $0.id == id }) else { return }
        textEditString = note.string
        textToEdit = id
    }

    /// Saves the edited string; an emptied note is removed rather than left invisible.
    func commitTextEdit() {
        guard let id = textToEdit else { return }
        let trimmed = textEditString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            doc.texts.removeAll { $0.id == id }
        } else if let i = doc.texts.firstIndex(where: { $0.id == id }) {
            doc.texts[i].string = trimmed
        }
        textToEdit = nil
        persist()
    }

    /// Dismissed without saving: drop a note that was never given any text (e.g. a
    /// just-added one), otherwise leave the existing note untouched.
    func endTextEdit() {
        if let id = textToEdit,
           let note = doc.texts.first(where: { $0.id == id }),
           note.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.texts.removeAll { $0.id == id }
            persist()
        }
        textToEdit = nil
    }

    func moveText(_ id: UUID, to n: CGPoint) {
        guard let i = doc.texts.firstIndex(where: { $0.id == id }) else { return }
        doc.texts[i].x = Double(n.x); doc.texts[i].y = Double(n.y)
        persist()
    }

    /// Grows or shrinks a text note's font (points), clamped to a sensible range.
    func resizeText(_ id: UUID, by step: Double) {
        guard let i = doc.texts.firstIndex(where: { $0.id == id }) else { return }
        doc.texts[i].fontSize = min(max(doc.texts[i].fontSize + step, 8), 60)
        persist()
    }

    func deleteText(_ id: UUID) {
        doc.texts.removeAll { $0.id == id }
        persist()
    }

    /// Furniture and camera/mannequin markers, in their own oversized, never-clipped
    /// layer (see `canvas`) so a piece pushed into the white margin by the placement
    /// stays selectable and draggable. Gestures read `canvasContentSpace` — the
    /// pre-placement space, like `rect` here — so grabs land true at any scale. Holds
    /// only positioned views (no Canvas), so the large frame stays cheap.
    func markerFurnitureLayer(in rect: CGRect, geo: GeometryProxy) -> some View {
        // The pane rect (not the overscanned layer rect) — the space a normalized point
        // maps through to land on screen, so pieces whose stored spot falls outside the
        // pane can drop their hit-testing (see `pieceHittable`).
        let paneRect = contentRect(in: geo.size)
        // Markers that anchor an arrow report their live drag spot (so the arrow follows);
        // the rest don't, so dragging them doesn't re-render the editor every frame.
        let arrowed = Set(doc.arrows.flatMap { [$0.fromID, $0.toID] })
        return ZStack {
            // Furniture, below the people/cameras so they read as "on" it. Hidden
            // while drawing the floor plan.
            if !isDrawing {
                ForEach(doc.furniture) { item in
                    let totalSelected = selectedIDs.count + furnitureSelectedIDs.count
                    let inGroup = totalSelected > 1 && furnitureSelectedIDs.contains(item.id)
                    // A layer hidden from the toolbar stays as a faint ghost for
                    // reference, but can't be picked up.
                    let visible = item.kind.isLight ? doc.showLights : doc.showFurniture
                    FurnitureView(
                        furniture: item,
                        isSelected: furnitureSelectedID == item.id || furnitureSelectedIDs.contains(item.id),
                        resizeArmed: furnitureResizeID == item.id,
                        canResetSize: furnitureSizeChanged(item),
                        widthOnlyResize: item.kind.resizeWidthOnly
                            || (item.kind.isTruss && mapMetersWide != nil),
                        showsLengthHandles: item.kind.isTruss && mapMetersWide == nil,
                        contentRect: rect,
                        zoom: zoom,
                        placeScale: CGFloat(mapPlacement.scale),
                        placeRotation: mapPlacement.rotation,
                        onSelect: { selectFurniture(item.id) },
                        clampToBounds: !allowsPiecesOutsideMap,
                        onMove: { normalized in moveFurniture(item.id, to: normalized) },
                        onRotate: { r in rotateFurniture(item.id, to: r) },
                        onResize: { w, h in resizeFurniture(item.id, width: w, height: h) },
                        onResetSize: { resetFurnitureSize(item.id) },
                        onToggleModifier: { toggleTubeModifier(item.id) },
                        onArmResize: { selectFurniture(item.id); furnitureResizeID = item.id },
                        onAddSoftbox: { addSoftbox(to: item.id) },
                        onSetColor: { hex in setFurnitureColor(item.id, hex) },
                        onReorder: { move in reorderFurniture(item.id, move) },
                        onDuplicate: { duplicateFurniture(item.id) },
                        onEditLabel: {
                            furnitureToLabel = item.id
                            furnitureLabelText = item.label
                        },
                        onMoveLabel: { offset in moveFurnitureLabel(item.id, to: offset) },
                        metersWide: mapMetersWide,
                        viewable: scene.sceneMapViewableMarkerSize,
                        selectedCount: inGroup ? totalSelected : 1,
                        isGroupMember: inGroup,
                        groupDragOffset: inGroup ? (groupDragTranslation ?? .zero) : .zero,
                        onGroupDragChanged: { groupDragTranslation = $0 },
                        onGroupDragEnded: { commitGroupDrag($0, in: rect) },
                        isGhosted: !visible,
                        onDelete: { deleteFurnitureOrSelection(item.id) }
                    )
                    .opacity(visible ? 1 : Self.hiddenLayerOpacity)
                    .allowsHitTesting(visible && pendingMove == nil && !reframeActive && !backgroundAdjustActive
                                      && pieceHittable(nx: item.x, ny: item.y, in: paneRect, canvas: geo.size))
                    // Furniture normally sits below the people/cameras, but the selected
                    // piece floats above them — so a just-added (auto-selected) light
                    // can't hide under a marker and stays easy to grab.
                    .zIndex(furnitureSelectedID == item.id || furnitureSelectedIDs.contains(item.id) ? 2 : 0)
                }
            }
            ForEach(doc.elements) { element in
                let totalSelected = selectedIDs.count + furnitureSelectedIDs.count
                let inGroup = totalSelected > 1 && selectedIDs.contains(element.id)
                // Hidden layer: a faint, non-interactive ghost (see furniture above).
                let visible = element.kind == .camera ? doc.showCameras : doc.showCharacters
                MapMarkerView(
                    element: element,
                    label: resolvedLabel(for: element),
                    zoom: zoom,
                    isSelected: selectedIDs.contains(element.id),
                    contentRect: rect,
                    onSelect: { selectMarker(element.id) },
                    clampToBounds: !allowsPiecesOutsideMap,
                    onMove: { normalized in moveElement(element.id, to: normalized) },
                    onRotate: { newRotation in rotateElement(element.id, to: newRotation) },
                    onSetColor: { hex in setColor(element.id, hex) },
                    onDelete: { deleteMarkerOrSelection(element.id) },
                    onMoveTo: { startMove(element.id, .to) },
                    onMoveFrom: { startMove(element.id, .from) },
                    onMoveLabel: { offset in moveLabel(element.id, to: offset) },
                    onTap: {
                        // Left-clicking a camera opens its shot-info card;
                        // clicking any other marker closes it.
                        cameraInfoElementID = (element.kind == .camera) ? element.id : nil
                    },
                    onDragStart: { cameraInfoElementID = nil },
                    characters: scene.project?.scriptCharacters ?? [],
                    onSetCharacter: { character in setCharacter(element.id, character) },
                    onRequestLabel: { markerToLabel = element.id; markerLabelText = element.label },
                    onToggleLabelHidden: { toggleLabelHidden(element.id) },
                    showsFOV: scene.sceneMapShowCameraFOV,
                    onToggleFOV: { toggleCameraFOV() },
                    fovBasis: effectiveBasis(for: element),
                    onSetFOVBasis: { setFOVBasis($0, for: element) },
                    fovProfiles: fovProfileRows,
                    selectedFOVProfileID: selectedFOVProfileID(for: element),
                    onSelectFOVProfile: { selectFOVProfile($0, for: element) },
                    showsRotationHandle: totalSelected == 1,
                    selectedCount: inGroup ? totalSelected : 1,
                    isGroupMember: inGroup,
                    groupDragOffset: inGroup ? (groupDragTranslation ?? .zero) : .zero,
                    onGroupDragChanged: { groupDragTranslation = $0 },
                    onGroupDragEnded: { commitGroupDrag($0, in: rect) },
                    scale: sceneMarkerScale(kind: element.kind,
                                            metersWide: mapMetersWide,
                                            cameraMeters: mapCameraMeters,
                                            mapWidthPoints: rect.width,
                                            viewable: scene.sceneMapViewableMarkerSize),
                    placeScale: CGFloat(mapPlacement.scale),
                    placeRotation: mapPlacement.rotation,
                    // Fades itself, part by part (see MapMarkerView.ghostOpacity) — an
                    // opacity out here left the camera's white outline un-faded live.
                    isGhosted: !visible,
                    onLiveMove: arrowed.contains(element.id)
                        ? { p in liveMarkerPositions[element.id] = p }
                        : { _ in }
                )
                .allowsHitTesting(visible && !isDrawing && pendingMove == nil && !reframeActive && !backgroundAdjustActive
                                  && pieceHittable(nx: element.x, ny: element.y, in: paneRect, canvas: geo.size))
                // Above unselected furniture, below the *selected* furniture piece.
                .zIndex(1)
            }
            // Free text notes, on top of the pieces.
            ForEach(doc.texts) { text in
                MapTextView(
                    text: text,
                    contentRect: rect,
                    zoom: zoom,
                    placeScale: CGFloat(mapPlacement.scale),
                    placeRotation: mapPlacement.rotation,
                    clampToBounds: !allowsPiecesOutsideMap,
                    onSelect: { cameraInfoElementID = nil },
                    onMove: { n in moveText(text.id, to: n) },
                    onEdit: { editTextNote(text.id) },
                    onResize: { step in resizeText(text.id, by: step) },
                    onDelete: { deleteText(text.id) }
                )
                .allowsHitTesting(pendingMove == nil && !reframeActive && !backgroundAdjustActive
                                  && pieceHittable(nx: text.x, ny: text.y, in: paneRect, canvas: geo.size))
                .zIndex(3)
            }
        }
    }

    func canvasContent(in rect: CGRect, geo: GeometryProxy) -> some View {
        ZStack {
            // The drawn floor plan itself is rendered crisply in a screen-space layer
            // below this group (see `canvas`); only its edit handles live here.
            // Walls, corners and openings are only draggable in EDIT mode (their
            // handles live in the `isDrawing` layer further down), so the plan can't
            // be nudged by accident while moving markers or panning.
            // (Furniture and markers live in `markerFurnitureLayer`, an oversized
            // sibling layer, so they stay tappable out in the white margin.)
            // Camera field-of-view wedges, under the arrows and markers.
            // Reads the scene flag directly so toggling it re-renders here.
            if scene.sceneMapShowCameraFOV {
                Canvas { ctx, _ in drawCameraFOV(ctx, in: rect) }
                    .allowsHitTesting(false)
                    // Ghosts with the camera layer when that's hidden.
                    .opacity(doc.showCameras ? 1 : Self.hiddenLayerOpacity)
            }
            // Movement arrows are drawn crisply in a screen-space overlay outside
            // the zoom (see below); only their right-click hit areas live here.
            if !doc.arrows.isEmpty, !isDrawing, pendingMove == nil {
                ForEach(doc.arrows.filter { arrowVisible($0) }) { arrow in
                    arrowHitView(arrow, in: rect)
                }
                .allowsHitTesting(!backgroundAdjustActive)
            }
            // Arrow pivot handles, only for the selected arrow.
            if !isDrawing && pendingMove == nil, let selectedArrow = arrowSelectedID {
                if let arrow = doc.arrows.first(where: { $0.id == selectedArrow }) {
                    ForEach(Array(arrow.pivots.indices), id: \.self) { index in
                        pivotHandle(arrowID: arrow.id, index: index, in: rect)
                    }
                }
            }
            // While drawing, a top layer captures clicks so the markers below
            // don't intercept them; hover drives the rubber-band preview.
            if isDrawing {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                        .onEnded { value in handleDrawClick(value.location, in: rect) })
                    .onContinuousHover(coordinateSpace: .named(SceneMapEditorView.canvasSpace)) { phase in
                        switch phase {
                        case .active(let location): drawHover = location
                        case .ended: drawHover = nil
                        }
                    }
                // ABOVE the catcher, so they can be grabbed: whole-wall drag strips
                // and door/window handles. A tap on a wall still places a point/opening
                // (routed through the same draw-click handler); a drag moves it.
                ForEach(floorPlan.walls) { wall in
                    wallHandle(wall, in: rect)
                }
                ForEach(floorPlan.openings) { opening in
                    openingHandle(opening, in: rect)
                }
                // Corner handles on top: drag a blue point to move it, or tap one to
                // start/finish a wall on it.
                ForEach(floorPlan.vertices) { vertex in
                    drawingVertexHandle(vertex, in: rect)
                }
            } else if pendingMove == nil && !backgroundAdjustActive && !reframeActive && doc.showBackground {
                // Outside Edit: right-click targets on walls / doors / windows, so their
                // context menus (length, delete, flip, …) don't require entering Edit.
                // No draw or move gestures — those stay in the drawing layer above.
                ForEach(floorPlan.walls) { wall in
                    wallContextHitArea(wall, in: rect)
                }
                ForEach(floorPlan.openings) { opening in
                    openingContextHitArea(opening, in: rect)
                }
            }
            // Wall measurement labels: always visible (with their context menu), but
            // only draggable while editing. After the draw catcher, so an in-EDIT drag
            // reaches the label.
            if mapMetersWide != nil && !floorPlan.hideMeasurements && (doc.showBackground || isDrawing) {
                ForEach(floorPlan.walls) { wall in
                    wallMeasureLabel(wall, in: rect, draggable: isDrawing)
                }
                .allowsHitTesting(!backgroundAdjustActive)
            }
            // Placing the second (moved) marker is handled by a pane-wide catcher at the
            // canvas root (see `canvas`), so a point out in the white margin — where this
            // placement-scaled layer doesn't reach — can still be chosen.
            // Set-true-scale: the tapped points, a connecting line, and (until two are
            // placed) a catcher above the markers to record the next tap.
            if scaleMeasureActive {
                if scaleMeasurePoints.count == 2 {
                    Path { pth in
                        pth.move(to: canvasPoint(scaleMeasurePoints[0].x, scaleMeasurePoints[0].y, in: rect))
                        pth.addLine(to: canvasPoint(scaleMeasurePoints[1].x, scaleMeasurePoints[1].y, in: rect))
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .allowsHitTesting(false)
                }
                ForEach(Array(scaleMeasurePoints.enumerated()), id: \.offset) { _, p in
                    Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                        .position(canvasPoint(p.x, p.y, in: rect))
                        .allowsHitTesting(false)
                }
                if scaleMeasurePoints.count < 2 {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                            .onEnded { value in recordScalePoint(value.location, in: rect) })
                }
            }
            // Sun-direction overlay (non-interactive), above the map content.
            sunOverlay(in: rect)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(name: SceneMapEditorView.canvasSpace)
        // Pinch-to-zoom (all platforms). Applied after the coordinate space so
        // the canvasSpace stays in logical points — marker/selection gestures,
        // which read `.named(canvasSpace)`, are unaffected by the zoom.
        .scaleEffect(zoom, anchor: .center)
        .offset(pan)
        // No clip here: the canvas clips the whole stack after the turn instead.
        // Clipping at this level cuts to the *unturned* frame, which reappears as a
        // diagonal edge across the map the moment anything is rotated.
        // scaleEffect also scales the canvas's hit region, so when zoomed in it
        // spilled over the toolbar above and swallowed its taps. Reset the
        // interactive shape to the (unscaled) frame so touches outside it — the
        // toolbar — pass through again.
        .contentShape(Rectangle())
        // Two-finger trackpad swipe pans the zoomed map (and any satellite map,
        // where panning reframes it); a mouse wheel zooms. macOS only: on iPad the
        // transparent catcher overlay sat on the touch/pinch path and is the
        // suspected cause of a zoom crash — touch devices pan by dragging anyway.
        #if os(macOS)
        // Trackpad two-finger swipe pans while reframing or zoomed in. Wheel/pinch
        // zoom is intentionally not wired: the map's scale changes only through the
        // reframe and align sliders, never a gesture.
        .overlay(
            TrackpadScrollCatcher(
                enabled: reframeActive || zoom > 1,
                onZoom: { _ in },
                onScroll: { delta in panBy(delta, size: geo.size) }
            )
        )
        #endif
        .onAppear { mapContentWidth = rect.width }
        .onChange(of: geo.size) { mapContentWidth = contentRect(in: geo.size).width }
        // One-finger empty-canvas drag pans (while reframing/zoomed) or draws a
        // marquee. Pinch-to-zoom is intentionally gone: the map is zoomed only via
        // the reframe/align sliders, so a stray pinch can't warp it.
        .gesture(
            canvasPanOrMarquee(in: rect, size: geo.size),
            including: backgroundAdjustActive ? .none : .all
        )
        // While aligning, the same touches move/zoom/turn the image instead; this
        // gesture takes over the canvas and ignores the (hit-test-disabled) markers.
        .gesture(backgroundAdjustGesture(in: rect),
                 including: backgroundAdjustActive ? .gesture : .subviews)
        .onTapGesture { if !isDrawing && !backgroundAdjustActive { selectedIDs = []; furnitureSelectedIDs = []; openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil; furnitureSelectedID = nil; furnitureResizeID = nil; cameraInfoElementID = nil } }
        #if os(macOS)
        .onDeleteCommand { if !selectedIDs.isEmpty || !furnitureSelectedIDs.isEmpty { deleteSelectedPieces() } }
        #endif
    }
}
