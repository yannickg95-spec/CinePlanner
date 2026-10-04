//
//  SceneMapEditorView+Reframe.swift
//  CinePlanner
//
//  Reframing a satellite background: pan, zoom and turn the capture, then re-render it.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Reframing a satellite background

    /// The stored capture's geo-anchor: where its centre is and how many metres it
    /// spans. Present only for a satellite background, which is the only kind that
    /// can be reframed — a photo or a drawn plan has no world behind its edges.
    var satelliteAnchor: SatelliteFraming? { scene.satelliteCapture }

    /// Whether this map *could* be reframed — the toolbar button's condition.
    var canReframe: Bool { satelliteAnchor != nil }

    /// Whether the reframe tool is actually running.
    var reframeActive: Bool { isReframeMode && canReframe }

    /// True once the canvas frames something other than the stored capture.
    /// How far the canvas is turned from the stored capture.
    var reframeTurn: Double {
        // Only while the tool is up. `reframeHeading` is a control's position, and it
        // starts at 0 until the tool seeds it from the map — so on a freshly opened
        // scene with a turned map this read as "turned back to north", tilting the
        // canvas at rest and cutting white corners out of a background that is in
        // fact perfectly square.
        guard reframeActive, let anchor = satelliteAnchor else { return 0 }
        return Compass.signedDelta(from: anchor.heading, to: reframeHeading)
    }

    var isReframing: Bool { reframeActive && (zoom != 1 || pan != .zero || reframeTurn != 0) }

    /// Zooming out below 1× only means something when there's more world to show.
    var minZoom: CGFloat { reframeActive ? 0.3 : 1 }

    /// Slider range for the reframe zoom, widest to tightest.
    static let reframeZoomRange: ClosedRange<CGFloat> = 0.3...4

    /// How far the content may be panned. Normally just enough to reach the edges of
    /// the zoomed image; while reframing, freely — panning *is* the point, and the
    /// stored capture's edge is no longer a wall.
    /// A drag is measured on screen, but `pan` is applied inside the turn — so a
    /// screen movement has to be rotated into the image's frame, or dragging right
    /// on a quarter-turned map walks the ground downward.
    func panDelta(fromScreen delta: CGSize) -> CGSize {
        guard reframeTurn != 0 else { return delta }
        let r = reframeTurn * .pi / 180
        let c = CGFloat(cos(r)), s = CGFloat(sin(r))
        return CGSize(width: delta.width * c - delta.height * s,
                      height: delta.width * s + delta.height * c)
    }

    func panLimits(_ size: CGSize, zoom z: CGFloat) -> CGSize {
        if reframeActive { return CGSize(width: size.width * 1.5, height: size.height * 1.5) }
        return CGSize(width: size.width * (z - 1) / 2, height: size.height * (z - 1) / 2)
    }

    /// Whether an empty-canvas drag pans. While reframing it always does — dragging
    /// the map is the whole point of the tool, and marker edits are suspended anyway.
    var dragPansCanvas: Bool { reframeActive || zoom > 1 }

    /// The patch of ground the canvas is showing, in the stored capture's own frame
    /// so it comes back turned the same way the canvas is drawn.
    func liveCanvasCover(in rect: CGRect, canvas: CGSize, margin: Double = 1) -> SatelliteFraming? {
        satelliteAnchor?.canvasCover(contentWidth: rect.width, canvas: canvas,
                                     zoom: zoom, pan: pan, margin: margin)
    }

    /// The capture the current framing would produce — exactly what the crop frame
    /// draws. At rest this is identical to the stored capture, so committing without
    /// having moved is a no-op.
    func pendingCapture(in rect: CGRect, canvas: CGSize) -> SatelliteFraming? {
        satelliteAnchor?.capture(contentWidth: rect.width, canvas: canvas,
                                 zoom: zoom, pan: pan, turnedBy: reframeTurn)
    }

    /// Coarse key so a new satellite render is fetched only when the framing has
    /// meaningfully moved, not on every sub-pixel of a drag.
    var reframeKey: String {
        "\(Int(zoom * 100))-\(Int(pan.width))-\(Int(pan.height))-\(Int(reframeHeading))"
    }

    /// The sharp render of the framed area, drawn under the markers. Positioned by
    /// the world rect it was rendered for, so it stays pinned to the ground while a
    /// later pan is still in flight — it goes stale by drifting off-canvas, never by
    /// sliding out of register with the markers.
    @ViewBuilder
    func reframeRender(in rect: CGRect, canvas: CGSize) -> some View {
        if let image = reframePreview, let shot = reframePreviewArea, let anchor = satelliteAnchor,
           let perPoint = anchor.mapPointsPerScreenPoint(contentWidth: rect.width, zoom: zoom),
           let offset = anchor.screenOffset(of: shot, contentWidth: rect.width, zoom: zoom, pan: pan),
           perPoint > 0 {
            let side = CGFloat(shot.meters * MKMapPointsPerMeterAtLatitude(shot.center.latitude) / perPoint)
            Image(platformImage: image)
                .resizable()
                .frame(width: side, height: side)
                .position(x: canvas.width / 2 + offset.width, y: canvas.height / 2 + offset.height)
                .allowsHitTesting(false)
        }
    }

    /// Live marker/furniture preview during a reframe: each piece is remapped onto the
    /// fetched framing and drawn on the same rect the preview image fills, so it stays
    /// on its real-world spot as the map is panned, zoomed and turned — matching where
    /// it will land on commit. Non-interactive; the real layer is hidden meanwhile.
    @ViewBuilder
    func reframeMarkerOverlay(in rect: CGRect, canvas: CGSize) -> some View {
        if reframeActive, let shot = reframePreviewArea, let anchor = satelliteAnchor,
           let perPoint = anchor.mapPointsPerScreenPoint(contentWidth: rect.width, zoom: zoom),
           let offset = anchor.screenOffset(of: shot, contentWidth: rect.width, zoom: zoom, pan: pan),
           perPoint > 0 {
            let side = CGFloat(shot.meters * MKMapPointsPerMeterAtLatitude(shot.center.latitude) / perPoint)
            // The preview image's on-screen rect — the same square markers are placed in.
            let previewRect = CGRect(x: canvas.width / 2 + offset.width - side / 2,
                                     y: canvas.height / 2 + offset.height - side / 2,
                                     width: side, height: side)
            let ratio = anchor.sizeRatio(to: shot)
            let labelRotation = mapPlacement.rotation - reframeTurn
            // `zoom: 1` — this overlay bakes the reframe zoom into `previewRect`/`side`
            // and the marker `scale`, not a `scaleEffect`, so the label/handle
            // counter-scale (which divides by `zoom`) must not also undo it, or the
            // captions would shrink and grow as the map is zoomed during the adjust.
            ForEach(doc.furniture) { item in
                let copy = Self.remapped(item, from: anchor, to: shot, sizeRatio: ratio)
                FurnitureView(furniture: copy, isSelected: false, contentRect: previewRect,
                              zoom: 1, placeScale: 1, placeRotation: labelRotation,
                              onSelect: {}, onMove: { _ in }, onRotate: { _ in },
                              onResize: { _, _ in }, onSetColor: { _ in }, onReorder: { _ in },
                              onDuplicate: {}, viewable: scene.sceneMapViewableMarkerSize, onDelete: {})
                    .allowsHitTesting(false)
            }
            ForEach(doc.elements) { element in
                let copy = Self.remapped(element, from: anchor, to: shot)
                MapMarkerView(element: copy, label: resolvedLabel(for: element),
                              zoom: 1, isSelected: false, contentRect: previewRect,
                              onSelect: {}, onMove: { _ in }, onRotate: { _ in },
                              onSetColor: { _ in }, onDelete: {}, onMoveTo: {}, onMoveFrom: {},
                              onMoveLabel: { _ in },
                              scale: sceneMarkerScale(kind: element.kind, metersWide: shot.meters,
                                                      cameraMeters: mapCameraMeters, mapWidthPoints: side,
                                                      viewable: scene.sceneMapViewableMarkerSize),
                              placeScale: 1, placeRotation: labelRotation)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A marker copy remapped from `anchor` onto the reframed `shot`, for live preview.
    static func remapped(_ element: MapElement, from anchor: SatelliteFraming,
                                 to shot: SatelliteFraming) -> MapElement {
        var copy = element
        let p = anchor.remap(CGPoint(x: element.x, y: element.y), to: shot)
        copy.x = Double(p.x); copy.y = Double(p.y)
        return copy
    }

    /// A furniture copy remapped onto the reframed `shot` (position and real-world size).
    static func remapped(_ item: Furniture, from anchor: SatelliteFraming,
                                 to shot: SatelliteFraming, sizeRatio: Double) -> Furniture {
        var copy = item
        let p = anchor.remap(CGPoint(x: item.x, y: item.y), to: shot)
        copy.x = Double(p.x); copy.y = Double(p.y)
        copy.width = item.width * sizeRatio
        copy.height = item.height * sizeRatio
        return copy
    }

    /// Picks up the reframe tool. It sits on the map rather than in the toolbar:
    /// it acts on the map, only a satellite background has any use for it, and the
    /// toolbar row is long enough already. Hidden once the tool is running — the
    /// reframe bar carries its own way out.
    @ViewBuilder
    func reframeButton() -> some View {
        if canReframe, !isReframeMode, !isDrawing, pendingMove == nil {
            Button {
                reframeHeading = Compass.normalized(satelliteAnchor?.heading ?? 0)
                // The shot card is positioned from the marker's unturned screen spot,
                // so it would hang in the wrong place for the whole session.
                cameraInfoElementID = nil
                isReframeMode = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                    Text("ADJUST")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .help("Adjust the satellite map")
            // Pinned to the map area's top-right corner (just under the toolbar),
            // overlaid on the map, matching the drawn-plan ADJUST/EDIT chrome.
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// Picks up the align tool. Like the reframe button it lives on the map, in the
    /// same top-right corner — the two never show together, since a satellite map
    /// reframes and only a plain image aligns. Hidden while the tool is running; the
    /// align panel carries its own way out.
    /// Whether the EDIT/ADJUST chrome should currently be offered.
    var hasMapChromeButtons: Bool {
        guard !isBackgroundAdjustMode, !isReframeMode, !isDrawing, pendingMove == nil, !scaleMeasureActive else { return false }
        return !floorPlan.isEmpty || hasAlignableBackground
    }

    /// "Adjust Scale" is only for backgrounds that carry no real-world scale of their
    /// own: a loose image or a rendered 3D model. Not CineStager imports (they arrive
    /// scaled — detected by `sceneMapImportedMetersWide`), not satellite maps, and not
    /// drawn floor plans (scaled from a wall length).
    var showsAdjustScale: Bool {
        backgroundImage != nil
            && !scene.sceneMapBackgroundIsSatellite
            && floorPlan.isEmpty
            && scene.sceneMapImportedMetersWide == nil
    }

    /// EDIT (walls/doors/windows) and ADJUST (zoom/rotate/move) pills. Placed in the
    /// map's top-right corner on iPhone and in a strip under the toolbar on iPad/Mac.
    @ViewBuilder
    var mapChromeButtons: some View {
        HStack(spacing: 8) {
            if !floorPlan.isEmpty {
                mapChromePill("EDIT", systemImage: "pencil.and.ruler") { resumeDrawing() }
                    .help("Add walls, doors and windows")
            }
            if hasAlignableBackground {
                mapChromePill("ADJUST", systemImage: "arrow.up.left.and.arrow.down.right") {
                    startBackgroundAdjust()
                }
                .help("Move, zoom and rotate the map")
            }
            if showsAdjustScale {
                mapChromePill("SCALE", systemImage: "ruler") { startScaleMeasure() }
                    .help("Set the map's true scale from two points a known distance apart")
            }
        }
    }

    /// EDIT/ADJUST pinned to the map area's top-right corner (just under the toolbar),
    /// overlaid on the plan on every platform.
    @ViewBuilder
    func backgroundAdjustButton() -> some View {
        if hasMapChromeButtons {
            mapChromeButtons
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// iPhone only: the clear-map button — and next to it undo/redo — in the map's
    /// top-LEFT corner (opposite ADJUST), so they don't have to fit in the compact
    /// toolbar row. Trash shows when there's something to clear, undo/redo when
    /// there's something to undo or redo; neither while a mode is running.
    @ViewBuilder
    func clearMapCornerButton() -> some View {
        let showTrash = !mapIsEmpty
        let showUndo = history.canUndo || history.canRedo
        if isPhone, showTrash || showUndo, !isBackgroundAdjustMode, !isReframeMode, !isDrawing, pendingMove == nil {
            HStack(spacing: 8) {
                if showTrash {
                    Button(role: .destructive) { showingClearAllConfirm = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .modifier(MapCornerCapsule())
                    }
                    .buttonStyle(.plain)
                    .help("Clear Map — remove everything from the scene map")
                    .accessibilityLabel("Clear map")
                }
                if showUndo {
                    HStack(spacing: 0) {
                        Button(action: undoMap) {
                            Image(systemName: "arrow.uturn.backward")
                                .padding(.leading, 10).padding(.trailing, 7).padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .disabled(!history.canUndo)
                        .opacity(history.canUndo ? 1 : 0.35)
                        .accessibilityLabel("Undo")
                        Divider().frame(height: 14)
                        Button(action: redoMap) {
                            Image(systemName: "arrow.uturn.forward")
                                .padding(.leading, 7).padding(.trailing, 10).padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .disabled(!history.canRedo)
                        .opacity(history.canRedo ? 1 : 0.35)
                        .accessibilityLabel("Redo")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .modifier(MapCornerCapsule())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A small labelled capsule button used for the map's top-trailing chrome
    /// (Edit / Adjust), so both pills share one look.
    func mapChromePill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { mapChromePillLabel(title, systemImage: systemImage) }
            .buttonStyle(.plain)
    }

    /// The capsule label shared by the chrome pills, so a plain button and a menu
    /// trigger look identical.
    func mapChromePillLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }

    /// The reframe tool's furniture: the square that will be captured, everything
    /// outside it dimmed, and one panel to zoom, turn, keep or cancel. Shown for as
    /// long as the tool is on — not only once something has moved — so it is always
    /// clear which mode the map is in.
    @ViewBuilder
    func reframeChrome(in rect: CGRect, canvas: CGSize) -> some View {
        if reframeActive, !isDrawing, pendingMove == nil,
           let pending = pendingCapture(in: rect, canvas: canvas) {
            let side = min(canvas.width, canvas.height)
            let frame = CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2,
                               width: side, height: side)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: canvas))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.22), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: side, height: side)
            }
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                reframePanel(meters: pending.meters, rect: rect, canvas: canvas)
            }
        }
    }

    /// Maps the zoom onto the slider's 0…1 geometrically, so the tight and wide ends
    /// both get usable travel and 1× (the stored framing) sits near the middle.
    func reframeZoomBinding(canvas: CGSize) -> Binding<Double> {
        let low = Self.reframeZoomRange.lowerBound, high = Self.reframeZoomRange.upperBound
        return Binding(
            get: {
                let t = log(zoom / low) / log(high / low)
                return Double(min(max(t, 0), 1))
            },
            set: { t in
                let target = low * pow(high / low, CGFloat(t))
                guard zoom > 0 else { return }
                zoomBy(target / zoom, size: canvas)
            }
        )
    }

    /// Everything the tool offers, in one panel.
    ///
    /// It was three stacked capsules — zoom, turn, hint — each carrying its own
    /// padding, border and shadow, and together they ate the top of the very map they
    /// were there to help frame. One panel pays for that chrome once. Given the width
    /// the two sliders share a row and the hint sits opposite the buttons; below that
    /// the rows split, rather than the sliders shrinking until they can't be aimed.
    func reframePanel(meters: Double, rect: CGRect, canvas: CGSize) -> some View {
        // Both slider rows side by side need about 580 pt.
        let compact = isPhone || canvas.width < 580

        let zoomRow = HStack(spacing: compact ? 7 : 9) {
            Image(systemName: "viewfinder").foregroundStyle(.secondary)
            Text("\(Int(meters.rounded())) m").monospacedDigit()
                .frame(minWidth: 46, alignment: .leading)
            if !compact { Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary) }
            Slider(value: reframeZoomBinding(canvas: canvas), in: 0...1)
                .frame(width: compact ? 150 : 130)
            if !compact { Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary) }
        }

        let turnRow = HStack(spacing: compact ? 7 : 9) {
            Text("Up is").foregroundStyle(.secondary)
            CompassSlider(heading: $reframeHeading, width: compact ? 150 : 150)
            Text(Compass.readout(reframeHeading)).monospacedDigit()
                .frame(width: 66, alignment: .trailing)
            Button { reframeHeading = 0 } label: { Image(systemName: "location.north.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(Compass.normalized(reframeHeading) == 0 ? Color.secondary : Color.accentColor)
                .help("Turn north back up")
        }

        // The hint shares the buttons' row: it is the quietest thing here, and the row
        // it would otherwise own is the one worth reclaiming.
        let actionRow = HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text(compact ? "Drag to move the map"
                             : "Drag the map to move it under the frame")
            }
            .font(.caption)
            Spacer(minLength: 14)
            Button("Cancel") { cancelReframe() }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button {
                commitReframe(in: rect, canvas: canvas)
            } label: {
                if isCommittingReframe {
                    ProgressView().controlSize(.small)
                } else {
                    Text(compact ? "Keep" : "Use This Framing")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isCommittingReframe)
        }

        return VStack(alignment: .leading, spacing: compact ? 7 : 8) {
            if compact {
                zoomRow
                turnRow
            } else {
                HStack(spacing: 12) {
                    zoomRow
                    Divider().frame(height: 16)
                    turnRow
                }
            }
            actionRow
        }
        .font(.callout)
        // Without this the action row's spacer — and the panel with it — would stretch
        // to the full width of the canvas the overlay offers.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.top, 10)
    }

    /// How much wider than the canvas each render reaches. The overshoot is what the
    /// next pan slides into, so a drag doesn't drag a bare edge along with it.
    static let reframeRenderMargin = 1.4

    /// The turn control: which way the map lies. Separate from the main bar so
    /// neither row has to shrink to fit the other on a narrow canvas.
    func reframeTurnBar(canvas: CGSize) -> some View {
        let compact = isPhone || canvas.width < 520
        return HStack(spacing: compact ? 7 : 10) {
            Text("Up is").foregroundStyle(.secondary)
            CompassSlider(heading: $reframeHeading, width: compact ? 120 : 180)
            Text(Compass.readout(reframeHeading)).monospacedDigit()
                .frame(width: 66, alignment: .trailing)
            Button { reframeHeading = 0 } label: { Image(systemName: "location.north.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(Compass.normalized(reframeHeading) == 0 ? Color.secondary : Color.accentColor)
                .help("Turn north back up")
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// Debounced: fetches a satellite render of the framed area shortly after the
    /// gesture settles, so panning stays smooth and only one render is in flight.
    func scheduleReframeRender(in rect: CGRect, canvas: CGSize) {
        reframeTask?.cancel()
        // Always a diagonal's worth wider than the canvas while the tool is up, not
        // only once something has turned: a square only covers a turned canvas out to
        // its inscribed circle, so anything less leaves bare corners for as long as
        // the fetch takes — which is exactly while the dial is being dragged.
        let margin = Self.reframeRenderMargin * 2.0.squareRoot()
        guard reframeActive, let area = liveCanvasCover(in: rect, canvas: canvas, margin: margin) else {
            reframePreview = nil
            reframePreviewArea = nil
            return
        }
        reframeTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let pixels = max(max(canvas.width, canvas.height), 320) * CGFloat(margin)
            let image = try? await MapSnapshot.satelliteImage(area, pixels: pixels)
            if Task.isCancelled { return }
            if let image {
                reframePreview = image
                reframePreviewArea = area
            }
        }
    }

    /// Makes the framed area the scene's background. `rescaleSatelliteBackground`
    /// carries every marker, arrow, furniture piece and floor-plan vertex to the same
    /// real-world spot in the new capture, so nothing moves on screen — the ground
    /// under it just becomes the map.
    func commitReframe(in rect: CGRect, canvas: CGSize) {
        guard !isCommittingReframe, let target = pendingCapture(in: rect, canvas: canvas) else { return }
        isCommittingReframe = true
        Task {
            defer { isCommittingReframe = false }
            do {
                let image = try await MapSnapshot.satelliteImage(target)
                guard let data = image.pngRepresentation() else { return }
                rescaleSatelliteBackground(data, framing: target, label: nil)
                resetReframe()
                isReframeMode = false
            } catch {
                Log.sceneMap.error("Reframe capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Leaves the tool, putting the map back exactly as it was.
    func cancelReframe() {
        resetReframe()
        isReframeMode = false
    }

    /// Back to the stored capture, exactly as it was.
    func resetReframe() {
        reframeTask?.cancel()
        reframeTask = nil
        reframePreview = nil
        reframePreviewArea = nil
        zoom = 1; lastZoom = 1
        pan = .zero; lastPan = .zero
        reframeHeading = satelliteAnchor?.heading ?? 0
    }
}
