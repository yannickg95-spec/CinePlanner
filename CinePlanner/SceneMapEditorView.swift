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
    let scene: Scene
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var doc: SceneMapDoc
    @State private var selectedID: UUID?
    @State private var canvasSize: CGSize = .zero
    @State private var dragOrigin: [UUID: CGPoint] = [:]

    init(scene: Scene) {
        self.scene = scene
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
            header
            Divider()
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
        .frame(minWidth: 920, minHeight: 660)
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { add(.character) } label: { Label("Add Character", systemImage: "person.fill") }
            Button { add(.camera) } label: { Label("Add Camera", systemImage: "video.fill") }
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
                Canvas { ctx, size in
                    drawGrid(ctx, size)
                    for cam in doc.elements where cam.kind == .camera {
                        drawFOV(ctx, cam)
                    }
                }
                ForEach($doc.elements) { $element in
                    marker(for: $element)
                        .position(x: element.x, y: element.y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
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

    private func drawFOV(_ ctx: GraphicsContext, _ cam: MapElement) {
        let center = CGPoint(x: cam.x, y: cam.y)
        let fov = cam.horizontalFOV
        let radius = 240.0
        let left = MapGeometry.point(from: center, angleDeg: cam.rotation - fov / 2, radius: radius)
        let right = MapGeometry.point(from: center, angleDeg: cam.rotation + fov / 2, radius: radius)
        var path = Path()
        path.move(to: center)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        let color = Color(hex: cam.colorHex)
        ctx.fill(path, with: .color(color.opacity(0.15)))
        ctx.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 1)
    }

    // MARK: - Element markers

    @ViewBuilder
    private func marker(for binding: Binding<MapElement>) -> some View {
        let element = binding.wrappedValue
        let color = Color(hex: element.colorHex)
        let isSelected = selectedID == element.id

        VStack(spacing: 3) {
            ZStack {
                if isSelected {
                    Circle().stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
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
                                .frame(width: 30, height: 20)
                            Image(systemName: "video.fill").foregroundStyle(.white).font(.caption)
                        }
                    }
                }
                .rotationEffect(.degrees(element.rotation))
            }
            if !element.label.isEmpty {
                Text(element.label)
                    .font(.caption2).fontWeight(.medium)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedID = element.id }
        .gesture(
            DragGesture()
                .onChanged { value in
                    selectedID = element.id
                    if dragOrigin[element.id] == nil {
                        dragOrigin[element.id] = CGPoint(x: element.x, y: element.y)
                    }
                    let origin = dragOrigin[element.id]!
                    binding.wrappedValue.x = origin.x + value.translation.width
                    binding.wrappedValue.y = origin.y + value.translation.height
                }
                .onEnded { _ in
                    dragOrigin[element.id] = nil
                    persist()
                }
        )
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Facing \(Int(element.rotation.rounded()))°")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: selected.rotation, in: 0...360) { editing in
                            if !editing { persist() }
                        }
                    }

                    ColorPicker("Color", selection: Binding(
                        get: { Color(hex: selected.wrappedValue.colorHex) },
                        set: { selected.wrappedValue.colorHex = $0.hexString; persist() }
                    ))

                    if element.kind == .camera {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lens \(Int(element.focalLengthMM.rounded()))mm · FOV \(Int(element.horizontalFOV.rounded()))°")
                                .font(.caption).foregroundStyle(.secondary)
                            Slider(value: selected.focalLengthMM, in: 8...200) { editing in
                                if !editing { persist() }
                            }
                        }
                    }

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

    private func add(_ kind: MapElement.Kind) {
        let center = CGPoint(x: (canvasSize.width == 0 ? 400 : canvasSize.width / 2),
                             y: (canvasSize.height == 0 ? 300 : canvasSize.height / 2))
        let jitter = Double(doc.elements.count % 6) * 26
        let count = doc.elements.filter { $0.kind == kind }.count + 1
        var element = MapElement(kind: kind,
                                 x: center.x - 60 + jitter,
                                 y: center.y - 40 + jitter)
        element.label = kind == .character ? "Character \(count)" : "Cam \(count)"
        element.colorHex = kind == .character ? "#4C8DFF" : "#FF9500"
        doc.elements.append(element)
        selectedID = element.id
        persist()
    }

    private func persist() {
        scene.sceneMapJSON = doc.jsonString
        try? scene.modelContext?.save()
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
