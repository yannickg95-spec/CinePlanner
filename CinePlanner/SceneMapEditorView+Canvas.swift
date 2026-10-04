//
//  SceneMapEditorView+Canvas.swift
//  CinePlanner
//
//  The scene map editor's canvas: the map itself, its markers, and the gestures on it.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Canvas

    var canvas: some View {
        GeometryReader { geo in
            let rect = contentRect(in: geo.size)
            let place = mapPlacement
            ZStack {
                // A dark surround while framing: whatever the render hasn't reached
                // yet reads as being outside the map, where the page white read as a
                // hole punched in it.
                (reframeActive ? Color(white: 0.12) : Color.platformTextBackground)
                // Drawn floor plan: a screen-space Canvas that replicates the group's
                // transform, so walls/doors/windows stay crisp at any zoom or adjust
                // scale (a Canvas inside the group would be a magnified 1× bitmap).
                // Below the group, above the surround — so the markers, drawn in the
                // group, still sit on top of it.
                if (doc.showBackground && !floorPlan.isEmpty) || isDrawing {
                    Canvas { ctx, _ in drawFloorPlanLayer(ctx, in: rect, canvas: geo.size) }
                        .allowsHitTesting(false)
                        .clipped()
                }
                // The background art rides the same transform as the content, but in
                // its own layer so the sharp reframe render can slot in between it
                // and the markers.
                // Turned as one group, and clipped *after* the turn. Clipping each
                // layer first and turning it afterwards rotates the clipped square
                // itself, which throws the map's corners across the scene list and
                // the script while the dial is being dragged.
                ZStack {
                    backgroundArt(in: rect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(zoom, anchor: .center)
                        .offset(pan)
                        .allowsHitTesting(false)
                        .opacity(doc.showBackground ? 1 : 0)
                    reframeRender(in: rect, canvas: geo.size)
                    // While reframing, preview the markers on the fetched framing so they
                    // track the map live instead of snapping into place only on commit.
                    // Placed exactly like `reframeRender`, in the same layer, so it stays
                    // pinned to the preview image whatever the transform stack does.
                    reframeMarkerOverlay(in: rect, canvas: geo.size)
                    canvasContent(in: rect, geo: geo)
                }
                // The placement turns, scales and shifts the whole group — image and
                // its overlays — so everything stays pinned to the spots on the image it
                // annotates. Applied outside `canvasSpace` (like the canvas zoom), so
                // edit gestures keep reading logical coordinates. Offset is last, in
                // screen space, so a drag tracks the finger 1:1.
                .rotationEffect(.degrees(place.rotation - reframeTurn))
                .scaleEffect(place.scale)
                .offset(x: CGFloat(place.offsetX) * rect.width, y: CGFloat(place.offsetY) * rect.height)
                .clipped()
                // The placement scaleEffect also scales the group's hit region, so once
                // the map is enlarged with Adjust the group's edit handles (wall labels,
                // arrow strips) spilled over the toolbar above and swallowed its taps —
                // the same trap the canvas zoom hits (see the contentShape below the zoom
                // scaleEffect). Reset the interactive shape to the (unscaled) pane so
                // touches outside it pass through to the toolbar again.
                .contentShape(Rectangle())
                // Empty-canvas gestures live on `canvasContent` too, but the placement
                // scales that down to the drawn area, so on a zoomed-out map its reach
                // doesn't cover the white margin. The group spans the whole pane (its
                // content shape above), so the same pan/marquee/deselect gestures here
                // catch drags out in the white; a drag over the drawn area is consumed by
                // canvasContent (a descendant, higher priority) before it reaches here.
                .gesture(canvasPanOrMarquee(in: rect, size: geo.size),
                         including: backgroundAdjustActive ? .none : .all)
                .gesture(backgroundAdjustGesture(in: rect),
                         including: backgroundAdjustActive ? .gesture : .subviews)
                .onTapGesture {
                    if !isDrawing && !backgroundAdjustActive {
                        selectedIDs = []; furnitureSelectedIDs = []; openingSelectedID = nil; wallSelectedID = nil
                        arrowSelectedID = nil; furnitureSelectedID = nil; furnitureResizeID = nil
                        cameraInfoElementID = nil
                    }
                }
                #if os(iOS)
                // Touch: long-press an empty spot to drop a text note under the finger
                // (the Mac uses a right-click menu with the pointer's hover position).
                // Simultaneous, so the pan / marquee / tap above keep working; markers,
                // furniture and notes sit in front of this layer and keep their own
                // long-press menus, and walls/doors/windows/arrows are skipped by position.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(SceneMapEditorView.canvasScreenSpace))
                        .onChanged { value in if touchDownScreen == nil { touchDownScreen = value.startLocation } }
                        .onEnded { _ in touchDownScreen = nil }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                        .onEnded { _ in longPressAddText(in: rect, canvas: geo.size) }
                )
                #endif
                // Markers and furniture ride the SAME placement, but in their own layer
                // that overflows the pane and is never clipped or masked — so a piece the
                // placement pushes into the white margin (a CineStager import fitted to an
                // out-of-room camera) stays tappable however far out it sits. A canvas-
                // sized layer drops hit-testing beyond its edges; masking an oversized one
                // builds a huge offscreen buffer (it froze the app). This layer holds only
                // lightweight positioned views — no Canvas — so the big frame is cheap.
                markerFurnitureLayer(in: markerContentRect(rect, geo: geo), geo: geo)
                    .frame(width: geo.size.width * 5, height: geo.size.height * 5)
                    .coordinateSpace(name: SceneMapEditorView.canvasContentSpace)
                    .rotationEffect(.degrees(place.rotation - reframeTurn))
                    .scaleEffect(place.scale)
                    .offset(x: CGFloat(place.offsetX) * rect.width, y: CGFloat(place.offsetY) * rect.height)
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Clip the *rendering* to the pane so a piece dragged past the edge
                    // doesn't paint over the app's UI. This is a cheap rectangular clip
                    // (no offscreen buffer, unlike `.mask`), and because the layer's own
                    // frame is oversized, a marker out in the white — rendered inside the
                    // pane by the fit — still receives taps.
                    .clipped()
                    // NB: no `.contentShape(Rectangle())` here — this layer sits in front
                    // of the drawing catcher and wall/opening handles (in the group
                    // below), so a full-pane content shape would make the otherwise
                    // pass-through layer swallow every tap and break drawing and editing.
                    // The group's own content shape already bounds the placement-scaled
                    // hit region to the pane.
                    // Hidden while reframing — `reframeMarkerOverlay` shows the live
                    // preview positions instead.
                    .opacity(reframeActive ? 0 : 1)
            }
            // The untransformed pane space the marquee is measured and drawn in (see the
            // gesture). Defined on the canvas root so it sits outside the placement and
            // zoom transforms the map group and canvas content apply.
            .coordinateSpace(name: SceneMapEditorView.canvasScreenSpace)
            // Track the pointer in the untransformed pane space so a right-click "Add
            // Text" can drop the note where the cursor is (a context menu doesn't report
            // its own click location).
            .onContinuousHover(coordinateSpace: .named(SceneMapEditorView.canvasScreenSpace)) { phase in
                if case .active(let loc) = phase { lastMapHoverScreen = loc }
            }
            // Right-click an empty spot on the map to drop a text note there. Markers,
            // furniture, walls and openings carry their own menus (in front), so this
            // only appears on empty space. Mac only: on touch a canvas-wide context menu
            // is a long press that lifts the whole map as its preview (reading as if the
            // background got selected) — touch uses the long press on the map group.
            #if os(macOS)
            .contextMenu {
                if !isDrawing && !backgroundAdjustActive && !reframeActive && pendingMove == nil {
                    Button { addTextAtLastHover(in: rect, canvas: geo.size) } label: {
                        Label("Add Text", systemImage: "textformat")
                    }
                }
            }
            #endif
            // Marquee (rubber-band) selection box: its corners are captured in this pane
            // space, so it's drawn here — outside the map group's placement — or a
            // zoomed-out map's scale/offset would drag the box away from the pointer.
            .overlay {
                if let start = marqueeStart, let current = marqueeCurrent {
                    let box = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                     width: abs(current.x - start.x), height: abs(current.y - start.y))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .allowsHitTesting(false)
                }
            }
            // Placing the second (moved) marker: a pane-wide catcher measured in the
            // untransformed root space, so the drop point can be anywhere on screen —
            // including the white margin, which the placement-scaled canvas layer misses.
            .overlay {
                if pendingMove != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture(coordinateSpace: .named(SceneMapEditorView.canvasScreenSpace))
                            .onEnded { value in placeMovedMarkerAtScreen(value.location, in: rect, canvas: geo.size) })
                }
            }
            // Which way is North — the same compass the exports carry. Drawn outside
            // the transform so it stays in its corner while the map moves under it,
            // and reading the framing being previewed so it turns as the map is
            // turned rather than after the fact.
            // Chrome, outside the turn: the sun's time bar and the move banner belong
            // to the pane, not to the ground, so they stay upright and in place while
            // the map turns under them. The sun's rays and ball do turn — those are
            // map content, tied to the compass rather than to the screen.
            // Movement arrows: drawn OUTSIDE the map group's transform in a
            // screen-space Canvas so the vector rasterizes crisply at any placement
            // scale or zoom (a Canvas inside the group's scaleEffect would just be a
            // magnified, blurry 1× bitmap). drawArrows replicates the whole transform
            // on the graphics context instead. Beneath the chrome, above the map.
            .overlay {
                if !doc.arrows.isEmpty {
                    Canvas { ctx, _ in drawArrows(ctx, in: rect, canvas: geo.size) }
                        .allowsHitTesting(false)
                        .clipped()
                }
            }
            // The export frame: dim what falls outside the crop and outline it, so it's
            // always clear what will end up inside the map on export. Always shown
            // (except while the reframe tool draws its own frame). Above the map and
            // arrows, below the chrome.
            .overlay {
                if !reframeActive {
                    mapClipFrame(in: rect, canvas: geo.size)
                }
            }
            .overlay(alignment: .top) {
                if pendingMove != nil { moveBanner }
            }
            .overlay(alignment: .top) {
                if scaleMeasureActive { scaleMeasureBanner }
            }
            .overlay(alignment: .bottom) {
                if sun.enabled && sun.hasLocation { sunTimeBar }
            }
            .overlay { mapCompass(in: rect) }
            // Apple Maps attribution — fixed chrome pinned to the map rect, drawn
            // outside the map group's transform so it stays put (and one size) while
            // the map zooms/pans under it, instead of scaling with the map and
            // reading as a second logo baked into the imagery.
            .overlay {
                if scene.sceneMapBackgroundIsSatellite, backgroundImage != nil {
                    AppleMapsAttribution(rect: rect)
                }
            }
            .overlay { reframeButton() }
            .overlay { backgroundAdjustButton() }
            .overlay { clearMapCornerButton() }
            .overlay { reframeChrome(in: rect, canvas: geo.size) }
            .overlay { backgroundAdjustChrome(in: rect, canvas: geo.size) }
            // Camera shot-info card — fixed chrome outside the map group's transform,
            // so it stays upright and a constant size while the map is rotated,
            // scaled or panned under it, tracking the marker's true screen position.
            .overlay { cameraShotCard(in: rect, canvas: geo.size) }
            .onChange(of: reframeKey) { scheduleReframeRender(in: rect, canvas: geo.size) }
            .onChange(of: isReframeMode) { scheduleReframeRender(in: rect, canvas: geo.size) }
        }
    }

    @ViewBuilder
    func mapCompass(in rect: CGRect) -> some View {
        let north = reframeActive
            ? satelliteAnchor.map { -($0.heading + reframeTurn) }
            : scene.mapNorthOffset
        if let north {
            MapCompass(rect: rect, northOffsetDeg: north)
        }
    }

    /// Marks the export frame — the rect the map is cropped to on export. Dims the
    /// area outside it and outlines it, so anything the editor still shows past the
    /// frame (e.g. the corners of a rotated background image) reads clearly as cut.
    /// Skipped when the map already fills the canvas (nothing is cropped).
    @ViewBuilder
    func mapClipFrame(in rect: CGRect, canvas: CGSize) -> some View {
        if rect.width < canvas.width - 0.5 || rect.height < canvas.height - 0.5 {
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: canvas))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.1), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Color.white.opacity(0.65), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }

    /// The stored background image, or a grid standing in for a missing one.
    @ViewBuilder
    func backgroundArt(in rect: CGRect) -> some View {
        if let backgroundImage {
            Image(platformImage: backgroundImage)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        } else if !floorPlan.isEmpty || isDrawing {
            // A drawn floor plan gets a plain white "paper" background (filled in the
            // crisp floor-plan layer below this group) — no grid.
            EmptyView()
        } else {
            // A grid stands in for the (missing) background. Kept free of
            // `doc` so it never redraws while a marker is being dragged.
            Canvas { ctx, _ in drawGrid(ctx, rect) }
        }
    }

    /// How far the marker layer overflows the pane on each side — two pane widths /
    /// heights, matching the ×5 frame in `canvas`. A marker in the white margin sits
    /// within this, so it stays hit-testable however far the placement scaled the map.
    func markerOverscan(_ geo: GeometryProxy) -> CGSize {
        CGSize(width: geo.size.width * 2, height: geo.size.height * 2)
    }

    /// The content rect in the oversized marker layer's coordinates: the pieces render
    /// on the same spots (the layer is centred over the pane, so the overscan shift
    /// cancels), but inside a layer big enough to keep them tappable out in the margin.
    func markerContentRect(_ rect: CGRect, geo: GeometryProxy) -> CGRect {
        let m = markerOverscan(geo)
        return CGRect(x: rect.minX + m.width, y: rect.minY + m.height,
                      width: rect.width, height: rect.height)
    }

    /// The on-screen point a normalized map position maps to: through the canvas zoom/pan,
    /// then the map group's placement (rotate + scale about the pane centre, then offset)
    /// — the same transform the map is drawn with (mirrors the camera card's math).
    func pieceScreenCenter(nx: Double, ny: Double, in rect: CGRect, canvas: CGSize) -> CGPoint {
        let cxMid = canvas.width / 2, cyMid = canvas.height / 2
        let zx = cxMid + (rect.minX + CGFloat(nx) * rect.width - cxMid) * zoom + pan.width
        let zy = cyMid + (rect.minY + CGFloat(ny) * rect.height - cyMid) * zoom + pan.height
        let place = mapPlacement
        let theta = (place.rotation - reframeTurn) * .pi / 180
        let c = cos(theta), s = sin(theta)
        let rx = (zx - cxMid) * c - (zy - cyMid) * s
        let ry = (zx - cxMid) * s + (zy - cyMid) * c
        return CGPoint(x: cxMid + CGFloat(place.scale) * rx + CGFloat(place.offsetX) * rect.width,
                       y: cyMid + CGFloat(place.scale) * ry + CGFloat(place.offsetY) * rect.height)
    }

    /// Whether a piece at this normalized spot renders inside the pane, so it should take
    /// taps. The marker/furniture layer is oversized and never hit-clipped (so a piece in
    /// the white margin stays grabbable and the drawing catcher below stays reachable), so
    /// a big Adjust could otherwise push a piece's invisible hit-area out over the toolbar
    /// and swallow its taps. Gating per piece keeps in-pane pieces live without letting the
    /// whole layer consume taps. The stored spot is used (not the live drag position) so an
    /// in-progress drag past the edge isn't cut off.
    func pieceHittable(nx: Double, ny: Double, in rect: CGRect, canvas: CGSize) -> Bool {
        let p = pieceScreenCenter(nx: nx, ny: ny, in: rect, canvas: canvas)
        let m: CGFloat = 4   // tiny slack so a piece centred right on the edge still counts
        return p.x >= -m && p.x <= canvas.width + m && p.y >= -m && p.y <= canvas.height + m
    }

    /// The inverse of `pieceScreenCenter`: a point in the untransformed pane space back to
    /// a normalized map position, so a right-click drops a note where the pointer is.
    func normalizedFromScreen(_ p: CGPoint, in rect: CGRect, canvas: CGSize) -> CGPoint {
        let cxMid = canvas.width / 2, cyMid = canvas.height / 2
        let place = mapPlacement
        let s = max(CGFloat(place.scale), 0.0001)
        let rx = (p.x - cxMid - CGFloat(place.offsetX) * rect.width) / s
        let ry = (p.y - cyMid - CGFloat(place.offsetY) * rect.height) / s
        let theta = (place.rotation - reframeTurn) * .pi / 180
        let c = cos(theta), sn = sin(theta)
        let dzx = rx * c + ry * sn
        let dzy = -rx * sn + ry * c
        let zx = cxMid + dzx, zy = cyMid + dzy
        let z = max(zoom, 0.0001)
        let nx = ((zx - pan.width - cxMid) / z + cxMid - rect.minX) / rect.width
        let ny = ((zy - pan.height - cyMid) / z + cyMid - rect.minY) / rect.height
        return CGPoint(x: nx, y: ny)
    }
}
