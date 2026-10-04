//
//  SceneMapEditorView+BackgroundAlign.swift
//  CinePlanner
//
//  Aligning an image background under the markers.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Aligning an image background under the markers

    /// What the align tool can move, zoom and rotate: a plain image, or a drawn
    /// floor plan. A satellite still is positioned by reframing instead, and the
    /// bare grid has nothing to place.
    var hasAlignableBackground: Bool {
        guard !scene.sceneMapBackgroundIsSatellite else { return false }
        return backgroundImage != nil || !floorPlan.isEmpty
    }

    /// Whether the align tool is actually running.
    var backgroundAdjustActive: Bool { isBackgroundAdjustMode && hasAlignableBackground }

    /// The live placement applied to the whole map group. A satellite map is never
    /// manually placed (it reframes instead), so it stays identity.
    var mapPlacement: SceneMapBackgroundTransform {
        if scene.sceneMapBackgroundIsSatellite { return .init() }
        if isBackgroundAdjustMode { return bgTransform }   // live while aligning
        // Just the stored placement (identity unless the user aligned the map by hand,
        // or a CineStager import zoomed it out once to fit out-of-room markers). The
        // view never refits live: on every other map markers clamp to the map's bounds
        // as they're dragged, so nothing lands in the margin to chase.
        return scene.sceneMapBackgroundTransform
    }

    /// Markers and furniture may be placed in the margin around the map (not clamped to
    /// its edge) on every map the user can zoom out to open a white margin around: a
    /// loose image or 3D model (Adjust), a CineStager import (fitted to out-of-room
    /// pieces), or a drawn floor plan (canvas zoom). Only satellite maps — north-up and
    /// reframed rather than zoomed — keep their pieces snapped to the edge.
    var allowsPiecesOutsideMap: Bool {
        !scene.sceneMapBackgroundIsSatellite && (backgroundImage != nil || !floorPlan.isEmpty)
    }

    /// Widest / tightest the image may be scaled, and the geometric zoom slider.
    static let bgScaleRange: ClosedRange<Double> = 0.2...5

    /// Picks up the align tool. Panning/zooming/turning now move the image under the
    /// fixed markers; the canvas's own zoom is parked at rest so screen deltas map
    /// straight onto the image.
    func startBackgroundAdjust() {
        cameraInfoElementID = nil
        selectedIDs = []; furnitureSelectedID = nil; furnitureSelectedIDs = []; arrowSelectedID = nil
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
        // Start from what's on screen — including an auto-fit that hasn't been saved —
        // so opening the tool doesn't jump the map back to 1×.
        bgTransform = mapPlacement
        isBackgroundAdjustMode = true
    }

    /// Leaves the tool, keeping the placement (it was written live as it changed).
    func finishBackgroundAdjust() {
        isBackgroundAdjustMode = false
        persistBackgroundTransform()
    }

    /// Back to a plain aspect-fitted image.
    func resetBackgroundTransform() {
        bgTransform = .init()
        persistBackgroundTransform()
    }

    func persistBackgroundTransform() {
        scene.sceneMapBackgroundTransform = bgTransform
        scene.modelContext?.saveReporting()
    }

    /// Drag = move, and only move. Scale and rotation are set from the panel
    /// sliders, never a gesture, so a stray pinch or twist can't warp the placement.
    func backgroundAdjustGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard rect.width > 0, rect.height > 0 else { return }
                if bgAdjustStartOffset == .zero, value.translation == .zero {
                    bgAdjustStartOffset = CGSize(width: bgTransform.offsetX, height: bgTransform.offsetY)
                }
                bgTransform.offsetX = Double(bgAdjustStartOffset.width) + Double(value.translation.width) / Double(rect.width)
                bgTransform.offsetY = Double(bgAdjustStartOffset.height) + Double(value.translation.height) / Double(rect.height)
            }
            .onEnded { _ in
                bgAdjustStartOffset = .zero
                persistBackgroundTransform()
            }
    }

    /// The align tool's panel: precise zoom and rotation controls plus reset/done,
    /// so the placement can be dialled in even where a trackpad twist is awkward.
    func backgroundAdjustPanel(canvas: CGSize) -> some View {
        let compact = isPhone || canvas.width < 520
        let zoomBinding = Binding<Double>(
            get: {
                let lo = Self.bgScaleRange.lowerBound, hi = Self.bgScaleRange.upperBound
                return log(bgTransform.scale / lo) / log(hi / lo)
            },
            set: { t in
                let lo = Self.bgScaleRange.lowerBound, hi = Self.bgScaleRange.upperBound
                bgTransform.scale = lo * pow(hi / lo, min(max(t, 0), 1))
                persistBackgroundTransform()
            }
        )
        let rotationBinding = Binding<Double>(
            get: { bgTransform.rotation },
            set: { bgTransform.rotation = $0; persistBackgroundTransform() }
        )

        let zoomRow = HStack(spacing: compact ? 7 : 9) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: zoomBinding, in: 0...1).frame(width: compact ? 210 : 140)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        let turnRow = HStack(spacing: compact ? 7 : 9) {
            Image(systemName: "rotate.right").foregroundStyle(.secondary)
            Slider(value: rotationBinding, in: -180...180).frame(width: compact ? 210 : 140)
            Text("\(Int(bgTransform.rotation.rounded()))°").monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        let actionRow = HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text(compact ? "Drag to move" : "Drag to move · sliders to zoom & rotate")
            }
            .font(.caption)
            Spacer(minLength: 14)
            Button("Reset") { resetBackgroundTransform() }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(bgTransform.isIdentity)
            Button("Done") { finishBackgroundAdjust() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }

        return VStack(alignment: .leading, spacing: compact ? 7 : 8) {
            if compact {
                zoomRow; turnRow
            } else {
                HStack(spacing: 12) { zoomRow; Divider().frame(height: 16); turnRow }
            }
            actionRow
        }
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.top, 10)
    }

    /// The align tool's on-canvas chrome: the panel, pinned to the top of the map.
    @ViewBuilder
    func backgroundAdjustChrome(in rect: CGRect, canvas: CGSize) -> some View {
        if backgroundAdjustActive, !isDrawing, pendingMove == nil {
            backgroundAdjustPanel(canvas: canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The sun as a yellow ball on a ring around the map centre, in its compass
    /// direction (adjusted for the map's North), with an arrow showing the way the
    /// light travels (inward, toward the scene). Greyed when below the horizon.
    @ViewBuilder
    func sunOverlay(in rect: CGRect) -> some View {
        if sun.enabled, let lat = sun.latitude, let lon = sun.longitude {
            let pos = SolarPosition.altAzimuth(date: sun.instant, latitude: lat, longitude: lon)
            let theta = (sun.northOffsetDeg + pos.azimuth) * .pi / 180   // screen angle, from up, clockwise
            let dir = CGVector(dx: sin(theta), dy: -cos(theta))          // toward the sun (y-down)
            let radius = min(rect.width, rect.height) * 0.42
            let ball = CGPoint(x: rect.midX + dir.dx * radius, y: rect.midY + dir.dy * radius)
            let below = pos.altitude < 0
            let tint = below ? Color.gray : sunColor(altitude: pos.altitude)

            Canvas { ctx, _ in
                // Thin light rays across the whole map, parallel to the arrow.
                let light = CGVector(dx: -dir.dx, dy: -dir.dy)       // direction light travels
                let rayPerp = CGVector(dx: -light.dy, dy: light.dx)
                let diag = hypot(rect.width, rect.height)
                let spacing: CGFloat = 22
                let steps = Int(diag / spacing) + 2
                ctx.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    for i in -steps...steps {
                        let off = CGFloat(i) * spacing
                        let base = CGPoint(x: rect.midX + rayPerp.dx * off, y: rect.midY + rayPerp.dy * off)
                        var line = Path()
                        line.move(to: CGPoint(x: base.x - light.dx * diag, y: base.y - light.dy * diag))
                        line.addLine(to: CGPoint(x: base.x + light.dx * diag, y: base.y + light.dy * diag))
                        layer.stroke(line, with: .color(tint.opacity(below ? 0.14 : 0.4)), lineWidth: 1.1)
                    }
                }

                // Arrow from just inside the ball toward the centre (light direction).
                let start = CGPoint(x: ball.x - dir.dx * 16, y: ball.y - dir.dy * 16)
                let end = CGPoint(x: ball.x - dir.dx * 52, y: ball.y - dir.dy * 52)
                var shaft = Path(); shaft.move(to: start); shaft.addLine(to: end)
                ctx.stroke(shaft, with: .color(tint.opacity(below ? 0.5 : 0.9)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // Arrowhead.
                let ah = 8.0
                let back = CGPoint(x: end.x + dir.dx * ah, y: end.y + dir.dy * ah)
                let perp = CGVector(dx: -dir.dy, dy: dir.dx)
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: back.x + perp.dx * ah * 0.7, y: back.y + perp.dy * ah * 0.7))
                head.addLine(to: CGPoint(x: back.x - perp.dx * ah * 0.7, y: back.y - perp.dy * ah * 0.7))
                head.closeSubpath()
                ctx.fill(head, with: .color(tint.opacity(below ? 0.5 : 0.9)))
                // The sun ball, with a soft halo.
                let r: CGFloat = 13
                ctx.fill(Path(ellipseIn: CGRect(x: ball.x - r*1.6, y: ball.y - r*1.6, width: r*3.2, height: r*3.2)),
                         with: .color(tint.opacity(below ? 0.08 : 0.2)))
                ctx.fill(Path(ellipseIn: CGRect(x: ball.x - r, y: ball.y - r, width: r*2, height: r*2)),
                         with: .color(tint.opacity(below ? 0.55 : 1)))
                ctx.stroke(Path(ellipseIn: CGRect(x: ball.x - r, y: ball.y - r, width: r*2, height: r*2)),
                           with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }

    /// Warm-to-bright sun colour by altitude: reddish near the horizon, yellow high.
    func sunColor(altitude: Double) -> Color {
        let t = min(max(altitude / 50, 0), 1)
        return Color(hue: 0.06 + 0.09 * t, saturation: 1 - 0.15 * t, brightness: 1)
    }

    /// Bottom bar shown with the overlay: scrub the time of day; reads out the
    /// sun's altitude plus the day's sunrise / sunset times.
    var sunTimeBar: some View {
        func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        let altReadout: String = {
            guard let lat = sun.latitude, let lon = sun.longitude else { return "" }
            let pos = SolarPosition.altAzimuth(date: sun.instant, latitude: lat, longitude: lon)
            return pos.altitude < 0 ? "Below horizon" : String(format: "Altitude %.0f°", pos.altitude)
        }()
        let riseSet: (sunrise: Int, sunset: Int)? = {
            guard let lat = sun.latitude, let lon = sun.longitude else { return nil }
            return SolarPosition.sunriseSunset(date: sun.date, latitude: lat, longitude: lon, timeZone: sun.timeZone)
        }()
        let minutes = Int(sun.timeMinutes)
        let slider = Slider(value: $sun.timeMinutes, in: 0...1439) { editing in if !editing { saveSun() } }
        let readouts = HStack(spacing: 10) {
            if let riseSet {
                Label(hhmm(riseSet.sunrise), systemImage: "sunrise.fill")
                Label(hhmm(riseSet.sunset), systemImage: "sunset.fill")
            }
            Text(altReadout)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)

        return Group {
            if isPhonePortrait {
                // Portrait iPhone is too narrow for one row — give the slider the full
                // width and drop the sunrise/sunset/altitude readouts underneath.
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                        Text(hhmm(minutes))
                            .font(.callout.monospacedDigit()).frame(width: 48, alignment: .leading)
                        slider
                    }
                    readouts
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                    Text(hhmm(minutes))
                        .font(.callout.monospacedDigit()).frame(width: 48, alignment: .leading)
                    slider
                    readouts.fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: 640)
    }

    /// Floating shot-info card for the clicked camera, placed beside its marker
    /// (flipping to the other side / clamping so it stays on-canvas). Rendered in
    /// the canvas rather than as a system popover so the marker stays draggable.
    @ViewBuilder
    func cameraShotCard(in rect: CGRect, canvas: CGSize) -> some View {
        if let id = cameraInfoElementID,
           let element = doc.elements.first(where: { $0.id == id }),
           element.kind == .camera,
           let uid = element.shotUID,
           let shot = scene.shots.first(where: { $0.uid == uid }) {
            // The card lives outside the zoom transform (constant on-screen size), so
            // work in screen space: map the marker's logical position through the
            // scaleEffect(anchor: .center) + offset(pan) to where it actually appears.
            let compact = DeviceLayout.isPhone
            let gap: CGFloat = 24
            // Shrink the card to whatever the (possibly resized) canvas allows, so it
            // always fits, then let the still scale with it.
            let baseW: CGFloat = compact ? 190 : 264
            let cardW = max(140, min(baseW, canvas.width - 2 * (gap + 8)))
            // Header + 16:9 still + info rows + padding — tracks the scaled width.
            let estH: CGFloat = (cardW - 24) * 9 / 16 + 150
            // The marker's true screen point: the logical position through the canvas
            // zoom/pan, then the map group's placement (rotate + scale about the
            // centre, then offset) — the same transform the map is drawn with.
            let cxMid = canvas.width / 2, cyMid = canvas.height / 2
            let zx = cxMid + (rect.minX + element.x * rect.width - cxMid) * zoom + pan.width
            let zy = cyMid + (rect.minY + element.y * rect.height - cyMid) * zoom + pan.height
            let place = mapPlacement
            let theta = (place.rotation - reframeTurn) * .pi / 180
            let c = cos(theta), s = sin(theta)
            let rx = (zx - cxMid) * c - (zy - cyMid) * s
            let ry = (zx - cxMid) * s + (zy - cyMid) * c
            let cxScreen = cxMid + CGFloat(place.scale) * rx + CGFloat(place.offsetX) * rect.width
            let cyScreen = cyMid + CGFloat(place.scale) * ry + CGFloat(place.offsetY) * rect.height
            // Keep the card off the rotation handle. The handle orbits the marker in
            // its facing direction, turned by the map's placement, so put the card on
            // the side away from it. Fall back to the other side only when the
            // preferred one won't fit, and then nudge the card vertically clear.
            let handleAngle = (element.rotation + place.rotation - reframeTurn) * .pi / 180
            let handleDX = sin(handleAngle)     // >0 handle to the right, <0 to the left
            let handleDY = -cos(handleAngle)    // >0 handle below the marker, <0 above
            let handleThreshold = 0.15          // treat a near-vertical handle as neither side
            let fitsRight = cxScreen + gap + cardW <= canvas.width
            let fitsLeft = cxScreen - gap - cardW >= 0
            // Handle on the right → prefer the left side (right only if left won't fit).
            // Otherwise (handle on the left, or ~vertical) → the usual right-if-it-fits.
            let placeRight = (handleDX > handleThreshold) ? !fitsLeft : fitsRight
            let cxRaw = placeRight ? cxScreen + gap + cardW / 2 : cxScreen - gap - cardW / 2
            // Clamp to the screen so an edge marker's card stays fully visible.
            let cx = min(max(cxRaw, cardW / 2 + 8), max(cardW / 2 + 8, canvas.width - cardW / 2 - 8))
            // If the card had to land on the handle's own side, shift it vertically
            // away from the handle so its body still doesn't sit over it.
            let cardOnHandleSide = (placeRight && handleDX > handleThreshold) ||
                (!placeRight && handleDX < -handleThreshold)
            let cyBase = cardOnHandleSide
                ? cyScreen + (handleDY >= 0 ? -1 : 1) * (estH / 2 + 44)
                : cyScreen
            let cy = min(max(cyBase, estH / 2 + 8), max(estH / 2 + 8, canvas.height - estH / 2 - 8))
            CameraShotPopover(shot: shot, compact: compact, width: cardW)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 9, y: 2)
                .fixedSize()
                .position(x: cx, y: cy)
                .transition(.opacity)
        }
    }

    var moveBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.right")
            Text("Click the map to place the marker, or an existing one to link to it")
            Button("Cancel") { pendingMove = nil }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        .padding(.top, 10)
    }

    var scaleMeasureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "ruler")
            Text(scaleMeasurePoints.isEmpty
                 ? "Tap the first point"
                 : (scaleMeasurePoints.count < 2 ? "Tap the second point" : "Enter the distance"))
            Button("Cancel") { cancelScaleMeasure() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        .padding(.top, 10)
    }

    /// The rect (in canvas points) the map's normalized coordinates map onto:
    /// the background image's aspect-fit rect; a centered square while a floor
    /// plan is present (so it can't distort); otherwise the whole canvas.
    func contentRect(in size: CGSize) -> CGRect {
        if let bg = backgroundImage, bg.size.width > 0, bg.size.height > 0 {
            let imageAspect = bg.size.width / bg.size.height
            let boxAspect = size.width / max(size.height, 1)
            var w = size.width
            var h = size.height
            if imageAspect > boxAspect { h = w / imageAspect } else { w = h * imageAspect }
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }
        if !floorPlan.isEmpty || isDrawing {
            let side = min(size.width, size.height)
            return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        }
        return CGRect(origin: .zero, size: size)
    }

    func drawGrid(_ ctx: GraphicsContext, _ rect: CGRect) {
        let step: CGFloat = 40
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
        var y = rect.minY
        while y <= rect.maxY { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
        ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
    }
}
