//
//  SceneMapEditorView.swift
//  CinePlanner
//
//  The scene-level top-down map editor. Place characters and cameras on a grid;
//  cameras draw a field-of-view cone from their focal length + sensor width.
//  Saved back to Scene.sceneMapJSON.
//

import SwiftUI
import SwiftData

struct SceneMapEditorView: View {
    static let canvasSpace = "sceneMapCanvas"

    let scene: Scene
    /// When embedded in a pane (vs. presented as a sheet), drop the title bar,
    /// the Done button, and the fixed minimum size.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var doc: SceneMapDoc
    @State private var selectedID: UUID?
    @State private var backgroundImage: NSImage?

    init(scene: Scene, embedded: Bool = false) {
        self.scene = scene
        self.embedded = embedded
        _doc = State(initialValue: SceneMapDoc.load(from: scene.sceneMapJSON))
        _backgroundImage = State(initialValue: scene.sceneMapBackgroundData.flatMap(NSImage.init(data:)))
    }

    private var sceneTitle: String {
        var t = "Scene \(scene.sceneNumber)\(scene.suffix)"
        let loc = scene.nickname.trimmingCharacters(in: .whitespaces)
        if !loc.isEmpty { t += " · \(loc)" }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                header
                Divider()
            }
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                if selectedBinding != nil {
                    Divider()
                    inspector
                        .frame(width: 240)
                }
            }
        }
        .frame(minWidth: embedded ? nil : 920, minHeight: embedded ? nil : 660)
        .onAppear { syncShotLabels(); pruneOrphanedShotCameras(); clearMannequinLabels() }
        // Keep this editor's in-memory doc in sync when shots change underneath
        // it (e.g. a shot is deleted from the shot list while the map is open),
        // so a stale doc can't re-add the marker when it next persists.
        .onChange(of: scene.shots.map(\.uid)) { _, _ in pruneOrphanedShotCameras() }
        .onDisappear { persist() }
    }

    // MARK: - Header & toolbar

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scene Map").font(.title2).fontWeight(.semibold)
                Text(sceneTitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { persist(); dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var sceneShots: [Shot] {
        scene.shots.sorted { $0.shotNumber < $1.shotNumber }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { add(.character) } label: { Label("+", systemImage: "person.fill") }
                .help("Add Character")
            Menu {
                if sceneShots.isEmpty {
                    Text("No shots in this scene")
                } else {
                    ForEach(sceneShots, id: \.uid) { shot in
                        Button("Shot \(shot.displayNumber)") { addCamera(for: shot) }
                    }
                }
            } label: {
                Label("+", systemImage: "video.fill")
            }
            .fixedSize()
            .help("Add Camera")
            if backgroundImage != nil {
                Button { clearBackground() } label: {
                    Label("Clear Background", systemImage: "xmark.rectangle")
                }
            }
            Spacer()
            Text("\(doc.elements.count) item\(doc.elements.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let rect = contentRect(in: geo.size)
            ZStack {
                if let backgroundImage {
                    Image(nsImage: backgroundImage)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                } else {
                    // A grid stands in for the (missing) background. Kept free of
                    // `doc` so it never redraws while a marker is being dragged.
                    Canvas { ctx, size in
                        drawGrid(ctx, CGRect(origin: .zero, size: size))
                    }
                }
                ForEach(doc.elements) { element in
                    MapMarkerView(
                        element: element,
                        label: resolvedLabel(for: element),
                        isSelected: selectedID == element.id,
                        contentRect: rect,
                        onSelect: { selectedID = element.id },
                        onMove: { normalized in moveElement(element.id, to: normalized) },
                        onRotate: { newRotation in rotateElement(element.id, to: newRotation) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .coordinateSpace(name: SceneMapEditorView.canvasSpace)
            .onTapGesture { selectedID = nil }
        }
    }

    /// The rect (in canvas points) the map's normalized coordinates map onto:
    /// the background image's aspect-fit rect, or the whole canvas when there's
    /// no background.
    private func contentRect(in size: CGSize) -> CGRect {
        guard let bg = backgroundImage, bg.size.width > 0, bg.size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let imageAspect = bg.size.width / bg.size.height
        let boxAspect = size.width / max(size.height, 1)
        var w = size.width
        var h = size.height
        if imageAspect > boxAspect { h = w / imageAspect } else { w = h * imageAspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func drawGrid(_ ctx: GraphicsContext, _ rect: CGRect) {
        let step: CGFloat = 40
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
        var y = rect.minY
        while y <= rect.maxY { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
        ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
    }

    // MARK: - Inspector

    private var selectedBinding: Binding<MapElement>? {
        guard let id = selectedID, let index = doc.elements.firstIndex(where: { $0.id == id }) else { return nil }
        return $doc.elements[index]
    }

    @ViewBuilder
    private var inspector: some View {
        if let selected = selectedBinding {
            let element = selected.wrappedValue
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(element.kind == .character ? "Character" : "Camera")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Label").font(.caption).foregroundStyle(.secondary)
                        if element.shotUID != nil {
                            HStack(spacing: 6) {
                                Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                                Text(resolvedLabel(for: element))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("Linked to its shot — the number updates automatically.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TextField("Name", text: selected.label, onCommit: persist)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    ColorPicker("Color", selection: Binding(
                        get: { Color(hex: selected.wrappedValue.colorHex) },
                        set: { selected.wrappedValue.colorHex = $0.hexString; persist() }
                    ))

                    Text("Drag the handle above the icon to rotate.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Button(role: .destructive) {
                        doc.elements.removeAll { $0.id == element.id }
                        selectedID = nil
                        persist()
                    } label: {
                        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Actions

    /// Spawn point (normalized 0…1) for a new element: near the center, nudged
    /// so successive additions don't stack exactly on top of each other.
    private var newElementPoint: CGPoint {
        let jitter = Double(doc.elements.count % 6) * 0.03
        return CGPoint(x: 0.44 + jitter, y: 0.42 + jitter)
    }

    private func add(_ kind: MapElement.Kind) {
        let point = newElementPoint
        let count = doc.elements.filter { $0.kind == kind }.count + 1
        var element = MapElement(kind: kind, x: point.x, y: point.y)
        element.label = kind == .character ? "Character \(count)" : "Cam \(count)"
        element.colorHex = kind == .character ? "#4C8DFF" : "#FF9500"
        doc.elements.append(element)
        selectedID = element.id
        persist()
    }

    /// Add a camera linked to a specific shot: its label follows the shot's
    /// number, and it's removed if the shot is deleted.
    private func addCamera(for shot: Shot) {
        let point = newElementPoint
        var element = MapElement(kind: .camera, x: point.x, y: point.y)
        element.label = shot.displayNumber
        element.shotUID = shot.uid
        element.colorHex = "#FF9500"
        doc.elements.append(element)
        selectedID = element.id
        persist()
    }

    /// Commit a marker's new position once its drag ends (mid-drag movement is
    /// handled locally inside MapMarkerView so the canvas doesn't re-render).
    private func moveElement(_ id: UUID, to position: CGPoint) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].x = position.x
        doc.elements[index].y = position.y
        persist()
    }

    private func rotateElement(_ id: UUID, to rotation: Double) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].rotation = rotation
        persist()
    }

    /// Removes the background image. Markers keep their normalized positions, now
    /// relative to the whole canvas instead of the image's fitted rect.
    private func clearBackground() {
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        try? scene.modelContext?.save()
    }

    private func persist() {
        scene.sceneMapJSON = doc.jsonString
        try? scene.modelContext?.save()
    }

    /// The label to show for an element: a shot-linked camera follows the shot's
    /// current number; everything else uses its own stored label.
    private func resolvedLabel(for element: MapElement) -> String {
        if let uid = element.shotUID,
           let shot = scene.shots.first(where: { $0.uid == uid }) {
            return shot.displayNumber
        }
        return element.label
    }

    /// Drops shot-linked cameras whose shot no longer exists (deleted from the
    /// shot list), keeping the open editor consistent with the model.
    private func pruneOrphanedShotCameras() {
        let shotUIDs = Set(scene.shots.map(\.uid))
        let before = doc.elements.count
        doc.elements.removeAll { element in
            guard let uid = element.shotUID else { return false }
            return !shotUIDs.contains(uid)
        }
        guard doc.elements.count != before else { return }
        if let id = selectedID, !doc.elements.contains(where: { $0.id == id }) {
            selectedID = nil
        }
        persist()
    }

    /// Clears the "Mannequin" label from imported mannequin markers so they
    /// show unlabeled on the map (one-time cleanup for maps made before this).
    private func clearMannequinLabels() {
        var changed = false
        for index in doc.elements.indices where doc.elements[index].kind == .character
            && doc.elements[index].label.hasPrefix("Mannequin") {
            doc.elements[index].label = ""
            changed = true
        }
        if changed { persist() }
    }

    /// Refresh stored labels of shot-linked cameras to their shot's current
    /// number (so the saved map + archive stay correct even when rendered
    /// without a scene, and as a fallback if the shot is later deleted).
    private func syncShotLabels() {
        var changed = false
        for index in doc.elements.indices {
            guard let uid = doc.elements[index].shotUID,
                  let shot = scene.shots.first(where: { $0.uid == uid }),
                  doc.elements[index].label != shot.displayNumber else { continue }
            doc.elements[index].label = shot.displayNumber
            changed = true
        }
        if changed { persist() }
    }
}

// MARK: - Marker

/// One draggable token on the map. Owns its drag offset locally so that
/// dragging re-renders only this view — the grid and the other markers stay
/// put — and commits the final position to the document on release.
private struct MapMarkerView: View {
    let element: MapElement
    /// Display label (resolved by the parent — a shot-linked camera follows its
    /// shot's number).
    let label: String
    let isSelected: Bool
    /// The rect (canvas points) that normalized element coordinates map onto.
    let contentRect: CGRect
    let onSelect: () -> Void
    /// Reports the new position in normalized (0…1) content-rect coordinates.
    let onMove: (CGPoint) -> Void
    let onRotate: (Double) -> Void

    /// Live position while dragging, in canvas-space. `nil` = not dragging, so
    /// the committed `element` position is used.
    @State private var livePosition: CGPoint?
    /// Pointer-to-center offset captured when the drag begins, so the token
    /// keeps its grab point instead of snapping its center to the cursor.
    @State private var grabOffset: CGSize = .zero
    /// Live facing while the rotation handle is being dragged; `nil` otherwise.
    @State private var liveRotation: Double?

    private var color: Color { Color(hex: element.colorHex) }
    private var displayRotation: Double { liveRotation ?? element.rotation }
    /// The element's committed position in canvas points.
    private var center: CGPoint {
        CGPoint(x: contentRect.minX + element.x * contentRect.width,
                y: contentRect.minY + element.y * contentRect.height)
    }

    /// Converts a canvas point back to normalized (0…1) content-rect coordinates.
    private func normalized(_ point: CGPoint) -> CGPoint {
        let nx = contentRect.width > 0 ? (point.x - contentRect.minX) / contentRect.width : 0
        let ny = contentRect.height > 0 ? (point.y - contentRect.minY) / contentRect.height : 0
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    /// Distance from the icon center to the rotation handle.
    private static let handleDistance: CGFloat = 40

    var body: some View {
        ZStack {
            // Selection ring — a circle, so it needn't rotate.
            if isSelected {
                Circle().stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 40, height: 40)
            }

            // The icon turns to point in its facing direction.
            iconGraphic
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .gesture(dragGesture)
                .rotationEffect(.degrees(displayRotation))

            // Label floats below the center without shifting it (an upright
            // caption, never rotated).
            if !label.isEmpty {
                labelView.offset(y: 26)
            }

            if isSelected {
                rotationHandle.offset(handleOffset)
            }
        }
        .position(livePosition ?? center)
    }

    // MARK: Rotation handle

    private var handleOffset: CGSize {
        let r = displayRotation * .pi / 180
        return CGSize(width: Self.handleDistance * sin(r),
                      height: -Self.handleDistance * cos(r))
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
            .contentShape(Circle())
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
                if livePosition == nil {
                    onSelect()
                    grabOffset = CGSize(width: center.x - value.location.x,
                                        height: center.y - value.location.y)
                }
                livePosition = CGPoint(x: value.location.x + grabOffset.width,
                                       y: value.location.y + grabOffset.height)
            }
            .onEnded { value in
                let final = CGPoint(x: value.location.x + grabOffset.width,
                                    y: value.location.y + grabOffset.height)
                livePosition = nil
                onMove(normalized(final))
            }
    }

    // The draggable icon (no rotation of its own — the parent unit rotates it).
    private var iconGraphic: some View {
        Group {
            if element.kind == .character {
                ZStack {
                    Circle().fill(color)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 28, height: 28)
                    Triangle().fill(color).frame(width: 14, height: 10).offset(y: -21)
                }
            } else {
                // Just the camera icon, pointing in its facing direction.
                // `video.fill` points right by default, so a -90° base turn makes
                // it face "up" when the marker's rotation is 0.
                Image(systemName: "video.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
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
