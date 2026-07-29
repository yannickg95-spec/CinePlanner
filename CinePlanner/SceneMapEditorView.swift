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
    @State private var canvasSize: CGSize = .zero

    init(scene: Scene, embedded: Bool = false) {
        self.scene = scene
        self.embedded = embedded
        _doc = State(initialValue: SceneMapDoc.load(from: scene.sceneMapJSON))
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
            Button { add(.character) } label: { Label("Add Character", systemImage: "person.fill") }
            Menu {
                if sceneShots.isEmpty {
                    Text("No shots in this scene")
                } else {
                    ForEach(sceneShots, id: \.uid) { shot in
                        Button("Shot \(shot.displayNumber)") { addCamera(for: shot) }
                    }
                }
            } label: {
                Label("Add Camera", systemImage: "video.fill")
            }
            .fixedSize()
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
            ZStack {
                // Static grid only — kept free of `doc` so it never redraws
                // while a marker is being dragged.
                Canvas { ctx, size in
                    drawGrid(ctx, size)
                }
                ForEach(doc.elements) { element in
                    MapMarkerView(
                        element: element,
                        isSelected: selectedID == element.id,
                        onSelect: { selectedID = element.id },
                        onMove: { newPosition in moveElement(element.id, to: newPosition) },
                        onRotate: { newRotation in rotateElement(element.id, to: newRotation) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .coordinateSpace(name: SceneMapEditorView.canvasSpace)
            .onTapGesture { selectedID = nil }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 40
        var path = Path()
        var x: CGFloat = 0
        while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
        var y: CGFloat = 0
        while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
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
                        TextField("Name", text: selected.label, onCommit: persist)
                            .textFieldStyle(.roundedBorder)
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

    /// Spawn point for a new element: near the canvas center, nudged so
    /// successive additions don't stack exactly on top of each other.
    private var newElementPoint: CGPoint {
        let center = CGPoint(x: (canvasSize.width == 0 ? 400 : canvasSize.width / 2),
                             y: (canvasSize.height == 0 ? 300 : canvasSize.height / 2))
        let jitter = Double(doc.elements.count % 6) * 26
        return CGPoint(x: center.x - 60 + jitter, y: center.y - 40 + jitter)
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

    /// Add a camera named for a specific shot.
    private func addCamera(for shot: Shot) {
        let point = newElementPoint
        var element = MapElement(kind: .camera, x: point.x, y: point.y)
        element.label = shot.displayNumber
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

    private func persist() {
        scene.sceneMapJSON = doc.jsonString
        try? scene.modelContext?.save()
    }
}

// MARK: - Marker

/// One draggable token on the map. Owns its drag offset locally so that
/// dragging re-renders only this view — the grid and the other markers stay
/// put — and commits the final position to the document on release.
private struct MapMarkerView: View {
    let element: MapElement
    let isSelected: Bool
    let onSelect: () -> Void
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
    private var center: CGPoint { CGPoint(x: element.x, y: element.y) }

    /// Distance from the icon center to the rotation handle, past the cone tip.
    private static let handleDistance: CGFloat = 74

    var body: some View {
        ZStack {
            // Selection ring — a circle, so it needn't rotate.
            if isSelected {
                Circle().stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 40, height: 40)
            }

            // Cone + icon share one center and rotate together as a single unit,
            // so the triangle's apex stays locked to the top of the icon.
            ZStack {
                if element.kind == .camera {
                    coneView.allowsHitTesting(false)
                }
                iconGraphic
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect() }
                    .gesture(dragGesture)
            }
            .rotationEffect(.degrees(displayRotation))

            // Label floats below the center without shifting it (an upright
            // caption, never rotated).
            if !element.label.isEmpty {
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
                    grabOffset = CGSize(width: element.x - value.location.x,
                                        height: element.y - value.location.y)
                }
                livePosition = CGPoint(x: value.location.x + grabOffset.width,
                                       y: value.location.y + grabOffset.height)
            }
            .onEnded { value in
                let final = CGPoint(x: value.location.x + grabOffset.width,
                                    y: value.location.y + grabOffset.height)
                livePosition = nil
                onMove(final)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
                        .frame(width: 24, height: 24)
                    Image(systemName: "video.fill").foregroundStyle(.white).font(.caption)
                }
            }
        }
    }

    private var labelView: some View {
        Text(element.label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.thinMaterial, in: Capsule())
    }

    // The field-of-view cone: a small, fixed 39° wedge whose apex starts at the
    // top of the black camera box and turns with the camera.
    private var coneView: some View {
        let radius: CGFloat = 58
        let boxHalfHeight: CGFloat = 12          // black icon box is 24pt square
        let extent = radius + boxHalfHeight
        let cone = ConeShape(fovDegrees: 39, radius: Double(radius), apexInset: Double(boxHalfHeight))
        return cone
            .fill(color.opacity(0.18))
            .overlay(cone.stroke(color.opacity(0.5), lineWidth: 1))
            .frame(width: extent * 2, height: extent * 2)
    }
}

/// A wedge pointing up, used for a camera's field of view. Its apex sits
/// `apexInset` above the rect center (so it can start at the top of the icon)
/// while the rect center stays the rotation anchor.
struct ConeShape: Shape {
    var fovDegrees: Double
    var radius: Double
    var apexInset: Double = 0

    func path(in rect: CGRect) -> Path {
        let apex = CGPoint(x: rect.midX, y: rect.midY - apexInset)
        let left = MapGeometry.point(from: apex, angleDeg: -fovDegrees / 2, radius: radius)
        let right = MapGeometry.point(from: apex, angleDeg: fovDegrees / 2, radius: radius)
        var path = Path()
        path.move(to: apex)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
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
