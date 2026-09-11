//
//  SceneMapMarker.swift
//  CinePlanner
//
//  The scene map's markers — mannequins and cameras — plus the sizing and
//  colour choices shared with the furniture.
//
//  Split out of SceneMapEditorView.swift, which had grown past 3,700 lines. These
//  are standalone types and helpers, moved unchanged; the editor view itself stays
//  put, since its 49 pieces of @State are private to it and splitting the body
//  would mean opening all of them up.
//

import SwiftUI
import SwiftData

// MARK: - Marker

/// One draggable token on the map. Owns its drag offset locally so that
/// dragging re-renders only this view — the grid and the other markers stay
/// put — and commits the final position to the document on release.
/// A distinct camera profile imported from CineStager: the combined camera value
/// ("Arri Alexa 35 · 4.6K 16:9") and the sensor width it frames on. Identified by
/// the camera value, which already carries the recording format.
struct CineStagerProfile: Identifiable, Hashable {
    let camera: String
    let sensorWidthMM: Double
    var id: String { camera }
}

struct MapMarkerView: View {
    let element: MapElement
    /// Display label (resolved by the parent — a shot-linked camera follows its
    /// shot's number).
    let label: String
    /// Current canvas zoom. The label is counter-scaled by 1/zoom so it stays the
    /// same on-screen size while the marker itself grows with the zoom.
    var zoom: CGFloat = 1
    let isSelected: Bool
    /// The rect (canvas points) that normalized element coordinates map onto.
    let contentRect: CGRect
    let onSelect: () -> Void
    /// Reports the new position in normalized (0…1) content-rect coordinates.
    let onMove: (CGPoint) -> Void
    let onRotate: (Double) -> Void
    let onSetColor: (String) -> Void
    let onDelete: () -> Void
    let onMoveTo: () -> Void
    let onMoveFrom: () -> Void
    /// Reports the label's new nudge (canvas points) once its drag ends.
    let onMoveLabel: (CGSize) -> Void
    /// Fired on a genuine left-click (tap), not a drag — used to open a camera's
    /// shot-info popover.
    var onTap: () -> Void = {}
    /// Fired when a drag on the marker begins — used to dismiss the shot popover.
    var onDragStart: () -> Void = {}
    /// Project characters offered in a mannequin marker's right-click menu.
    var characters: [ScriptCharacter] = []
    /// Assigns the picked character (name + color) to this mannequin marker.
    var onSetCharacter: (ScriptCharacter) -> Void = { _ in }
    /// Character-marker name label: request a text prompt to add one, or remove it.
    var onRequestLabel: () -> Void = {}
    /// Toggles this marker's name-label visibility (keeps the name).
    var onToggleLabelHidden: () -> Void = {}
    /// Whether the scene's camera FOV overlay is currently on (drives the camera
    /// marker's Show/Hide menu label). Scene-wide, so every camera shows it.
    var showsFOV: Bool = false
    /// Toggles the scene-wide camera FOV overlay.
    var onToggleFOV: () -> Void = {}
    /// This camera's effective sensor basis (drives the checkmark on the
    /// S16/S35/LF rows in the "FOV Settings" submenu).
    var fovBasis: FOVBasis = .cineStager
    /// Sets this camera's FOV basis to a fixed format (S16/S35/LF).
    var onSetFOVBasis: (FOVBasis) -> Void = { _ in }
    /// Every CineStager camera profile imported anywhere in the project — each
    /// selectable as this camera's FOV basis: (stable id, display label).
    var fovProfiles: [(id: String, label: String)] = []
    /// The profile id currently driving this camera's FOV (checkmarked), or nil.
    var selectedFOVProfileID: String? = nil
    /// Selects a CineStager profile (by id) as this camera's FOV basis, and
    /// fills the linked shot's camera info to match.
    var onSelectFOVProfile: (String) -> Void = { _ in }
    /// Show the rotation handle only when this is the sole selected marker (not
    /// during a multi-selection).
    var showsRotationHandle: Bool = true
    /// How many markers are selected — drives the Delete menu label.
    var selectedCount: Int = 1
    /// True when this marker is part of a multi-selection, so dragging it moves the
    /// whole group instead of just this one.
    var isGroupMember: Bool = false
    /// Live group-drag offset (canvas points) applied while the selection is being
    /// dragged as a group.
    var groupDragOffset: CGSize = .zero
    /// Reports the live translation while group-dragging.
    var onGroupDragChanged: (CGSize) -> Void = { _ in }
    /// Commits the group drag with its final translation.
    var onGroupDragEnded: (CGSize) -> Void = { _ in }
    /// Real-world scale factor for the icon (1 = default). See `sceneMarkerScale`.
    var scale: CGFloat = 1
    /// The map's placement scale and rotation (see `SceneMapBackgroundTransform`).
    /// The icon rides these through the parent group; the label and rotation handle
    /// are counter-transformed by them so the caption stays upright and both keep a
    /// constant on-screen size while still moving with the marker.
    var placeScale: CGFloat = 1
    var placeRotation: Double = 0

    /// Marker color choices offered in the right-click menu.
    private static let palette: [(name: String, hex: String)] = [
        ("Blue", "#4C8DFF"), ("Orange", "#FF9500"), ("Green", "#34C759"),
        ("Red", "#FF3B30"), ("Purple", "#AF52DE"), ("Yellow", "#FFCC00"),
        ("Gray", "#8E8E93"), ("White", "#FFFFFF")
    ]

    /// Live position while dragging, in canvas-space. `nil` = not dragging, so
    /// the committed `element` position is used.
    @State private var livePosition: CGPoint?
    /// Pointer-to-center offset captured when the drag begins, so the token
    /// keeps its grab point instead of snapping its center to the cursor.
    @State private var grabOffset: CGSize = .zero
    /// Live facing while the rotation handle is being dragged; `nil` otherwise.
    @State private var liveRotation: Double?
    /// Live label nudge while the label is being dragged; `nil` otherwise.
    @State private var liveLabelOffset: CGSize?
    /// Pointer-to-label offset captured when the label drag begins.
    @State private var labelGrab: CGSize = .zero

    private var color: Color { Color(hex: element.colorHex) }
    private var displayRotation: Double { liveRotation ?? element.rotation }
    /// The element's committed position in canvas points.
    private var center: CGPoint {
        CGPoint(x: contentRect.minX + element.x * contentRect.width,
                y: contentRect.minY + element.y * contentRect.height)
    }

    /// Put the label below the icon normally, but flip it above when the marker
    /// sits near the bottom edge so the caption can't hang off the map.
    private var labelOffsetY: CGFloat {
        let c = livePosition ?? center
        let d = 14 * scale + 12   // just below the scaled icon
        return (c.y + d + 14 > contentRect.maxY) ? -d : d
    }

    /// Converts a canvas point back to normalized content-rect coordinates. Not
    /// clamped to 0…1: a marker may sit outside the map image — in the space a
    /// zoomed-out reframe opens up around it, or where a CineStager import placed a
    /// camera beyond the room — so a drag mustn't snap it back onto the image.
    private func normalized(_ point: CGPoint) -> CGPoint {
        let nx = contentRect.width > 0 ? (point.x - contentRect.minX) / contentRect.width : 0
        let ny = contentRect.height > 0 ? (point.y - contentRect.minY) / contentRect.height : 0
        return CGPoint(x: nx, y: ny)
    }

    /// Distance from the icon center to the rotation handle.
    private static let handleDistance: CGFloat = 40

    var body: some View {
        ZStack {
            // Selection ring — a circle, so it needn't rotate.
            if isSelected {
                Circle().stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 40 * scale, height: 40 * scale)
            }

            // The icon turns to point in its facing direction, scaled to its
            // real-world size when the background is measured.
            iconGraphic
                .scaleEffect(scale)
                // A finger-friendly tap/drag target: the icon plus a touch margin
                // (0 on macOS), so a small marker — a moved mannequin's start point
                // especially, sitting right under the arrow — is still easy to grab.
                .contentShape(Rectangle().inset(by: -sceneMapHandleSlop))
                .onTapGesture { onSelect(); onTap() }
                .gesture(dragGesture)
                .rotationEffect(.degrees(displayRotation))
                .contextMenu { markerContextMenu }

            // Label floats below the center without shifting it (an upright
            // caption, never rotated). Draggable, so it can be nudged clear of an
            // arrow; the nudge is stored on the element.
            if !label.isEmpty && !element.labelHidden {
                let nudge = liveLabelOffset ?? element.labelOffset
                labelView
                    // Counter the canvas zoom and the map placement so the caption
                    // stays a constant on-screen size and upright, while still
                    // riding with its marker.
                    .scaleEffect(1 / (zoom * placeScale), anchor: .top)
                    .rotationEffect(.degrees(-placeRotation), anchor: .top)
                    .contentShape(Rectangle())
                    .offset(x: nudge.width, y: labelOffsetY + nudge.height)
                    .gesture(labelDragGesture)
                    .help("Drag to move the label")
            }

            if isSelected && showsRotationHandle {
                // Counter-scale so the handle keeps a constant on-screen size (and
                // grab area) instead of ballooning with the map zoom. Its distance
                // from the marker still scales, so it sits just outside the marker.
                rotationHandle
                    .scaleEffect(1 / (zoom * placeScale), anchor: .center)
                    .offset(handleOffset)
            }
        }
        .position(livePosition ?? center)
        // Live group-drag shift (applied to every selected marker at once).
        .offset(groupDragOffset)
    }

    // MARK: Context menu

    @ViewBuilder
    private var markerContextMenu: some View {
        if element.kind == .character {
            if !characters.isEmpty {
                Menu("Character") {
                    ForEach(characters) { character in
                        Button {
                            onSetCharacter(character)
                        } label: {
                            menuSelectionLabel(character.name, isSelected: element.label.caseInsensitiveCompare(character.name) == .orderedSame)
                        }
                    }
                }
            }
            if element.label.isEmpty {
                Button { onRequestLabel() } label: { Label("Add Name Label…", systemImage: "textformat") }
            } else {
                Button { onToggleLabelHidden() } label: {
                    Label(element.labelHidden ? "Show Label" : "Hide Label",
                          systemImage: element.labelHidden ? "eye" : "eye.slash")
                }
            }
            Divider()
        }
        if element.kind == .camera {
            Button { onToggleFOV() } label: {
                Label(showsFOV ? "Hide Camera FOV" : "Show Camera FOV",
                      systemImage: showsFOV ? "eye.slash" : "eye")
            }
            Menu("FOV Settings") {
                fovBasisButton(.super16)
                fovBasisButton(.super35)
                fovBasisButton(.largeFormat)
                if !fovProfiles.isEmpty {
                    Divider()
                    ForEach(fovProfiles, id: \.id) { profile in
                        Button { onSelectFOVProfile(profile.id) } label: {
                            menuSelectionLabel(profile.label, isSelected: selectedFOVProfileID == profile.id)
                        }
                    }
                }
            }
            Divider()
        }
        Button { onMoveTo() } label: { Label("Move To…", systemImage: "arrow.forward") }
        Button { onMoveFrom() } label: { Label("Move From…", systemImage: "arrow.backward") }
        Divider()
        Menu("Color") {
            ForEach(Self.palette, id: \.hex) { item in
                Button {
                    onSetColor(item.hex)
                } label: {
                    menuSelectionLabel(item.name, isSelected: element.colorHex.caseInsensitiveCompare(item.hex) == .orderedSame)
                }
            }
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label(selectedCount > 1 ? "Delete \(selectedCount) Markers" : "Delete", systemImage: "trash")
        }
    }

    /// One selectable FOV sensor-basis row (S16 / S35 / LF), checkmarked when it's
    /// the scene's current basis.
    @ViewBuilder
    private func fovBasisButton(_ basis: FOVBasis) -> some View {
        Button { onSetFOVBasis(basis) } label: {
            menuSelectionLabel(basis.menuLabel, isSelected: fovBasis == basis)
        }
    }

    // MARK: Rotation handle

    private var handleOffset: CGSize {
        let r = displayRotation * .pi / 180
        let d = max(Self.handleDistance * scale, 26)
        return CGSize(width: d * sin(r), height: -d * cos(r))
    }

    private var rotationHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .overlay(
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 16, height: 16)
            .contentShape(Circle().inset(by: -sceneMapHandleSlop))
            .gesture(rotationGesture)
            .help("Drag to rotate")
    }

    private var rotationGesture: some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                onSelect()
                liveRotation = Self.angle(from: center, to: value.location)
            }
            .onEnded { value in
                let final = Self.angle(from: center, to: value.location)
                liveRotation = nil
                onRotate(final)
            }
    }

    /// Compass-style angle (0° = up, clockwise positive) from `center` to `point`.
    private static func angle(from center: CGPoint, to point: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        var deg = atan2(dx, -dy) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    private var dragGesture: some Gesture {
        // Positioned from the pointer's ABSOLUTE location in the fixed canvas
        // space — never from translation/offset — so the moving token can't
        // shift its own reference frame (which is what caused the jumping).
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                // Part of a multi-selection → drag the whole group (the parent
                // offsets every selected marker), leaving the selection intact.
                if isGroupMember {
                    onDragStart()
                    onGroupDragChanged(value.translation)
                    return
                }
                if livePosition == nil {
                    onSelect()
                    onDragStart()
                    grabOffset = CGSize(width: center.x - value.location.x,
                                        height: center.y - value.location.y)
                }
                livePosition = CGPoint(x: value.location.x + grabOffset.width,
                                       y: value.location.y + grabOffset.height)
            }
            .onEnded { value in
                if isGroupMember {
                    onGroupDragEnded(value.translation)
                    return
                }
                let final = CGPoint(x: value.location.x + grabOffset.width,
                                    y: value.location.y + grabOffset.height)
                livePosition = nil
                onMove(normalized(final))
            }
    }

    /// Drags the label around the marker. Works in the fixed canvas space (like
    /// the marker drag) so the moving label can't shift its own reference frame,
    /// and keeps the grab point. The nudge is measured relative to the label's
    /// default spot (center + labelOffsetY).
    private var labelDragGesture: some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
            .onChanged { value in
                let c = livePosition ?? center
                let baseY = c.y + labelOffsetY
                if liveLabelOffset == nil {
                    onSelect()
                    let current = CGPoint(x: c.x + element.labelOffset.width,
                                          y: baseY + element.labelOffset.height)
                    labelGrab = CGSize(width: current.x - value.location.x,
                                       height: current.y - value.location.y)
                }
                let newPos = CGPoint(x: value.location.x + labelGrab.width,
                                     y: value.location.y + labelGrab.height)
                // Keep the label within a fixed radius of the marker so it can be
                // nudged clear of an arrow but never stray far from its icon.
                var dx = newPos.x - c.x, dy = newPos.y - c.y
                let dist = hypot(dx, dy)
                if dist > Self.labelMaxDistance {
                    let scale = Self.labelMaxDistance / dist
                    dx *= scale; dy *= scale
                }
                liveLabelOffset = CGSize(width: dx, height: dy - labelOffsetY)
            }
            .onEnded { _ in
                if let offset = liveLabelOffset { onMoveLabel(offset) }
                liveLabelOffset = nil
            }
    }

    /// Farthest a label's centre may sit from its marker's centre (canvas points).
    private static let labelMaxDistance: CGFloat = 60

    // The draggable icon (no rotation of its own — the parent unit rotates it).
    private var iconGraphic: some View {
        Group {
            if element.kind == .character {
                // Top-down head and shoulders: a wide oval (50 cm shoulder span) with
                // a smaller head circle (20 cm) nudged forward to show facing. Base
                // sizes are proportional (head = 20/50 of the shoulder width).
                ZStack {
                    // Shoulders 40 cm wide × 15 cm deep; head 20 cm. Base sizes at
                    // scale 1 keep those proportions (width 30 pt = 40 cm).
                    Ellipse().fill(color)
                        .overlay(Ellipse().stroke(.white, lineWidth: 2))
                        .frame(width: 30, height: 11)
                    Circle().fill(color)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 15, height: 15)
                        .offset(y: -2)
                }
            } else {
                // Just the camera icon, pointing in its facing direction.
                // `video.fill` points right by default, so a -90° base turn makes
                // it face "up" when the marker's rotation is 0. Sized into a fixed
                // `iconSide`² box (resizable, not font-based): an SF Symbol's font
                // point size isn't its drawn width — `video.fill` renders much wider
                // than 26 pt — so the box pins the drawn width to `baseDiameter`
                // (26) in `sceneMarkerScale`, otherwise the camera renders oversized.
                // The white outline is the same glyph offset all around behind the
                // coloured one — an even stroke, not a distorted scaled-up copy.
                let iconSide: CGFloat = 26
                ZStack {
                    ForEach(0..<16, id: \.self) { i in
                        Image(systemName: "video.fill")
                            .resizable().scaledToFit()
                            .frame(width: iconSide, height: iconSide)
                            .foregroundStyle(.white)
                            .offset(x: 1.6 * cos(CGFloat(i) / 16 * 2 * .pi),
                                    y: 1.6 * sin(CGFloat(i) / 16 * 2 * .pi))
                    }
                    Image(systemName: "video.fill")
                        .resizable().scaledToFit()
                        .frame(width: iconSide, height: iconSide)
                        .foregroundStyle(color)
                }
                // Slim the body across its facing axis (compressed before the turn,
                // so it thins perpendicular to the lens, not along it) to 85% width.
                .scaleEffect(x: 1, y: 0.85)
                .rotationEffect(.degrees(-90))
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
            }
        }
    }

    private var labelView: some View {
        Text(label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.thinMaterial, in: Capsule())
    }
}

/// A simple upward-pointing triangle, used for a character's facing arrow.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Shared marker/furniture color choices.
/// Scale factor for a scene-map marker so it reads at its real-world size against
/// a measured background. 1 (default) when the background has no measurement.
/// A mannequin spans 0.45 m; cameras use `cameraMeters` (0.45 m default).
/// Clamped so markers stay visible/usable at extremes.
/// Extra hit-area padding around the scene map's small drag/rotate/resize handles,
/// so they're comfortably tappable with a finger on iPad. Zero on macOS, where a
/// precise cursor makes the tight targets fine (and keeps behaviour unchanged).
#if os(iOS)
let sceneMapHandleSlop: CGFloat = 12
#else
let sceneMapHandleSlop: CGFloat = 0
#endif

func sceneMarkerScale(kind: MapElement.Kind, metersWide: Double?, cameraMeters: Double?,
                      mapWidthPoints: CGFloat, viewable: Bool = false) -> CGFloat {
    let realistic = realisticMarkerScale(kind: kind, metersWide: metersWide,
                                         cameraMeters: cameraMeters, mapWidthPoints: mapWidthPoints)
    // Viewable mode floors the size at the default (1) so tiny markers become
    // easy to see, but keeps a marker that's already bigger than default at its
    // real-world size — there's no visibility problem to fix there.
    return viewable ? max(realistic, 1) : realistic
}

/// The real-world scale factor for a marker (1 = default icon size), before the
/// viewable-size floor is applied. Returns 1 when the map has no measured scale.
func realisticMarkerScale(kind: MapElement.Kind, metersWide: Double?, cameraMeters: Double?,
                          mapWidthPoints: CGFloat) -> CGFloat {
    guard let metersWide, metersWide > 0, mapWidthPoints > 0 else { return 1 }
    // Cameras use their measured width (from a CineStager map) when available;
    // otherwise (e.g. a satellite background) fall back to 0.45 m, matching the
    // mannequin's 0.45 m footprint.
    let realMeters = kind == .camera ? (cameraMeters ?? 0.45) : 0.45
    // The icons' *drawn* widths at scale 1. The mannequin's ellipse fills its box
    // (30), but `video.fill` leaves internal padding, so its visible glyph is
    // narrower than its 26-pt frame — use 20 here so the camera renders at its true
    // measured width and matches the CineStager map's camera marker.
    let baseDiameter: CGFloat = kind == .camera ? 20 : 30
    let target = CGFloat(realMeters / metersWide) * mapWidthPoints
    // Floor low enough that a person/camera can render at its true (tiny)
    // footprint on a wide satellite capture — a 0.5 floor there drew them several
    // times too big. Room-scale maps sit well above this, so they're unaffected;
    // the "viewable size" toggle is there when the true size is too small to see.
    return min(max(target / baseDiameter, 0.12), 3.5)
}

/// Wraps a row of borderless controls in one bordered, tinted capsule so a group
/// of scene-map toolbar buttons reads as a single segmented control.
