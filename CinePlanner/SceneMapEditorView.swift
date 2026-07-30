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
import UniformTypeIdentifiers

struct SceneMapEditorView: View {
    static let canvasSpace = "sceneMapCanvas"

    let scene: Scene
    /// When embedded in a pane (vs. presented as a sheet), drop the title bar,
    /// the Done button, and the fixed minimum size.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum DrawTool: String, CaseIterable { case wall = "Wall"; case door = "Door"; case window = "Window" }
    enum MoveDirection { case to, from }

    @State private var doc: SceneMapDoc
    @State private var selectedID: UUID?
    @State private var backgroundImage: NSImage?
    @State private var showingImagePicker = false
    @State private var floorPlan: FloorPlan
    @State private var isDrawing = false
    @State private var drawTool: DrawTool = .wall
    /// The last vertex of the wall chain being drawn (the next click extends
    /// from here). nil = the next click starts a fresh chain.
    @State private var chainLastVertex: UUID?
    /// Cursor position (canvas points) for the rubber-band preview while drawing.
    @State private var drawHover: CGPoint?
    /// Door/window selected for editing.
    @State private var openingSelectedID: UUID?
    /// An in-progress "move to/from": the next canvas click places the second
    /// marker and connects it to `origin` with an arrow.
    @State private var pendingMove: (origin: UUID, direction: MoveDirection)?
    /// Wall selected for editing (reveals all vertex handles).
    @State private var wallSelectedID: UUID?
    /// A wall's endpoint positions captured at the start of a move drag.
    @State private var wallDragOrigin: (id: UUID, a: CGPoint, b: CGPoint)?

    init(scene: Scene, embedded: Bool = false) {
        self.scene = scene
        self.embedded = embedded
        _doc = State(initialValue: SceneMapDoc.load(from: scene.sceneMapJSON))
        _backgroundImage = State(initialValue: scene.sceneMapBackgroundData.flatMap(NSImage.init(data:)))
        _floorPlan = State(initialValue: FloorPlan.load(from: scene.sceneFloorPlanJSON))
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
            if isDrawing {
                drawToolbar
                Divider()
            }
            canvas
        }
        .frame(minWidth: embedded ? nil : 920, minHeight: embedded ? nil : 660)
        .onAppear { syncShotLabels(); pruneOrphanedShotCameras(); clearCharacterLabels() }
        // Keep this editor's in-memory doc in sync when shots change underneath
        // it (e.g. a shot is deleted from the shot list while the map is open),
        // so a stale doc can't re-add the marker when it next persists.
        .onChange(of: scene.shots.map(\.uid)) { _, _ in pruneOrphanedShotCameras() }
        // Reload when the map is changed externally while open — e.g. importing a
        // shot from CineStager adds markers/background to the scene. Round-trip
        // equality means our own saves don't trigger a redundant reload.
        .onChange(of: scene.sceneMapJSON) { _, newValue in
            let incoming = SceneMapDoc.load(from: newValue)
            guard incoming != doc else { return }
            doc = incoming
            if let id = selectedID, !doc.elements.contains(where: { $0.id == id }) {
                selectedID = nil
            }
        }
        .onChange(of: scene.sceneMapBackgroundData) { _, newValue in
            backgroundImage = newValue.flatMap(NSImage.init(data:))
        }
        .onChange(of: scene.sceneFloorPlanJSON) { _, newValue in
            let incoming = FloorPlan.load(from: newValue)
            if incoming != floorPlan { floorPlan = incoming }
        }
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { setBackground(from: url) }
        }
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
            Spacer()
            Button { add(.character) } label: { Label("+", systemImage: "person.fill") }
                .fixedSize()
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
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Camera")

            Menu {
                Button { startDrawing() } label: { Label("Draw", systemImage: "pencil.tip.crop.circle") }
                Button { showingImagePicker = true } label: { Label("Add Image…", systemImage: "photo") }
                Button { /* TODO: 3D model */ } label: { Label("Add 3D Model", systemImage: "cube") }
                    .disabled(true)
                if backgroundImage != nil || !floorPlan.isEmpty {
                    Divider()
                    Button(role: .destructive) { clearBackground() } label: { Label("Clear", systemImage: "xmark") }
                }
            } label: {
                Text("Background +")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .overlay(alignment: .trailing) {
            Text("\(doc.elements.count) item\(doc.elements.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.trailing, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var drawToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.tip.crop.circle").foregroundStyle(.secondary)
            Picker("Tool", selection: $drawTool) {
                ForEach(DrawTool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: drawTool) { _, _ in endChain() }
            Text(drawTool == .wall
                 ? "Click to drop points; click a point again to close the room."
                 : "Click a wall to place a \(drawTool.rawValue.lowercased()).")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if drawTool == .wall && chainLastVertex != nil {
                Button("Finish Line") { endChain() }
            }
            Button("Done") { endChain(); isDrawing = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
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
                    Canvas { ctx, _ in drawGrid(ctx, rect) }
                }
                // Drawn floor plan (walls + doors/windows), behind the markers.
                if !floorPlan.isEmpty || isDrawing {
                    Canvas { ctx, _ in drawFloorPlan(ctx, in: rect) }
                        .allowsHitTesting(false)
                }
                // Wall edit handles (below markers/openings), when not drawing.
                if !isDrawing {
                    ForEach(floorPlan.walls) { wall in
                        wallHandle(wall, in: rect)
                    }
                    // Selecting any wall reveals every corner point for editing.
                    if wallSelectedID != nil {
                        ForEach(floorPlan.vertices) { vertex in
                            vertexHandle(vertex, in: rect)
                        }
                    }
                }
                // Movement arrows between markers, drawn under the markers.
                if !doc.arrows.isEmpty {
                    Canvas { ctx, _ in drawArrows(ctx, in: rect) }
                        .allowsHitTesting(false)
                }
                ForEach(doc.elements) { element in
                    MapMarkerView(
                        element: element,
                        label: resolvedLabel(for: element),
                        isSelected: selectedID == element.id,
                        contentRect: rect,
                        onSelect: { selectedID = element.id; openingSelectedID = nil; wallSelectedID = nil },
                        onMove: { normalized in moveElement(element.id, to: normalized) },
                        onRotate: { newRotation in rotateElement(element.id, to: newRotation) },
                        onSetColor: { hex in setColor(element.id, hex) },
                        onDelete: { deleteElement(element.id) },
                        onMoveTo: { startMove(element.id, .to) },
                        onMoveFrom: { startMove(element.id, .from) }
                    )
                    .allowsHitTesting(!isDrawing && pendingMove == nil)
                }
                // Door/window edit handles (tap to select, right-click to edit).
                if !isDrawing {
                    ForEach(floorPlan.openings) { opening in
                        openingHandle(opening, in: rect)
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
                }
                // Placing the second (moved) marker: the next click drops it and
                // draws the connecting arrow.
                if pendingMove != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                            .onEnded { value in placeMovedMarker(at: value.location, in: rect) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .coordinateSpace(name: SceneMapEditorView.canvasSpace)
            .onTapGesture { if !isDrawing { selectedID = nil; openingSelectedID = nil; wallSelectedID = nil } }
            .overlay(alignment: .top) {
                if pendingMove != nil { moveBanner }
            }
        }
    }

    private var moveBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.right")
            Text("Click on the map to place the moved marker")
            Button("Cancel") { pendingMove = nil }
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
    private func contentRect(in size: CGSize) -> CGRect {
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

    private func drawGrid(_ ctx: GraphicsContext, _ rect: CGRect) {
        let step: CGFloat = 40
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
        var y = rect.minY
        while y <= rect.maxY { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
        ctx.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
    }

    // MARK: - Element actions

    private func setColor(_ id: UUID, _ hex: String) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].colorHex = hex
        persist()
    }

    private func deleteElement(_ id: UUID) {
        doc.elements.removeAll { $0.id == id }
        doc.arrows.removeAll { $0.fromID == id || $0.toID == id }
        if selectedID == id { selectedID = nil }
        persist()
    }

    // MARK: - Movement arrows

    /// Begins a move: the next canvas click places the second marker.
    private func startMove(_ id: UUID, _ direction: MoveDirection) {
        pendingMove = (origin: id, direction: direction)
        selectedID = nil
    }

    /// Drops the moved marker at the click and connects it with an arrow.
    private func placeMovedMarker(at loc: CGPoint, in rect: CGRect) {
        defer { pendingMove = nil }
        guard let move = pendingMove,
              let origin = doc.elements.first(where: { $0.id == move.origin }) else { return }
        let n = normalizedFromCanvas(loc, in: rect)
        var moved = MapElement(kind: origin.kind, x: n.x, y: n.y)
        moved.colorHex = origin.colorHex
        moved.rotation = origin.rotation
        moved.shotUID = origin.shotUID
        moved.label = origin.label
        doc.elements.append(moved)
        switch move.direction {
        case .to:   doc.arrows.append(MapArrow(fromID: origin.id, toID: moved.id))
        case .from: doc.arrows.append(MapArrow(fromID: moved.id, toID: origin.id))
        }
        selectedID = moved.id
        persist()
    }

    // MARK: - Wall editing

    private func canvasPoint(_ nx: Double, _ ny: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(nx) * rect.width, y: rect.minY + CGFloat(ny) * rect.height)
    }

    /// Invisible strip along a wall: tap to select, drag to move (translating
    /// both endpoint vertices, so joined walls follow).
    @ViewBuilder
    private func wallHandle(_ wall: Wall, in rect: CGRect) -> some View {
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
                .gesture(wallMoveGesture(wall.id, in: rect))
                .contextMenu {
                    Button(role: .destructive) { deleteWall(wall.id) } label: {
                        Label("Delete Wall", systemImage: "trash")
                    }
                }
                .rotationEffect(angle)
                .position(mid)
        }
    }

    /// A draggable corner point; moving it moves every wall attached to it.
    private func vertexHandle(_ vertex: FloorVertex, in rect: CGRect) -> some View {
        Circle().fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 14, height: 14)
            .contentShape(Circle().inset(by: -7))
            .gesture(
                DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                    .onChanged { value in moveVertex(vertex.id, to: value.location, in: rect) }
                    .onEnded { _ in persistFloorPlan() }
            )
            .position(canvasPoint(vertex.x, vertex.y, in: rect))
    }

    private func wallMoveGesture(_ id: UUID, in rect: CGRect) -> some Gesture {
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

    private func selectWall(_ id: UUID) {
        wallSelectedID = id
        openingSelectedID = nil
        selectedID = nil
    }

    private func moveVertex(_ id: UUID, to loc: CGPoint, in rect: CGRect) {
        guard let index = floorPlan.vertices.firstIndex(where: { $0.id == id }) else { return }
        var pos = normalizedFromCanvas(loc, in: rect)

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

        floorPlan.vertices[index].x = pos.x
        floorPlan.vertices[index].y = pos.y
    }

    private func deleteWall(_ id: UUID) {
        floorPlan.walls.removeAll { $0.id == id }
        floorPlan.openings.removeAll { $0.wallID == id }
        if wallSelectedID == id { wallSelectedID = nil }
        removeOrphanVertices()
        persistFloorPlan()
    }

    /// Drops vertices no longer used by any wall.
    private func removeOrphanVertices() {
        let used = Set(floorPlan.walls.flatMap { [$0.a, $0.b] })
        floorPlan.vertices.removeAll { !used.contains($0.id) && $0.id != chainLastVertex }
    }

    // MARK: - Opening (door/window) editing

    private func openingCenter(_ opening: Opening, in rect: CGRect) -> CGPoint? {
        guard let wall = floorPlan.wall(opening.wallID), let (a, b) = floorPlan.endpoints(wall) else { return nil }
        let x = a.x + opening.t * (b.x - a.x)
        let y = a.y + opening.t * (b.y - a.y)
        return CGPoint(x: rect.minX + CGFloat(x) * rect.width, y: rect.minY + CGFloat(y) * rect.height)
    }

    @ViewBuilder
    private func openingHandle(_ opening: Opening, in rect: CGRect) -> some View {
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
            }
        }
    }

    private func resizeHandle(_ id: UUID, at point: CGPoint, in rect: CGRect) -> some View {
        Circle().fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 13, height: 13)
            .contentShape(Circle().inset(by: -6))
            .gesture(
                DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                    .onChanged { value in resizeWindow(id, handleLocation: value.location, in: rect) }
                    .onEnded { _ in persistFloorPlan() }
            )
            .position(point)
    }

    @ViewBuilder
    private func openingMenu(_ opening: Opening) -> some View {
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

    private func selectOpening(_ id: UUID) {
        openingSelectedID = id
        selectedID = nil
        wallSelectedID = nil
    }

    /// Projects a normalized point onto a wall, returning the parameter t.
    private func projectT(_ p: CGPoint, onto wall: Wall) -> Double {
        guard let (a, b) = floorPlan.endpoints(wall) else { return 0.5 }
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-9 else { return 0.5 }
        return ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
    }

    /// Slides an opening along its wall, keeping it fully on the wall.
    private func moveOpening(_ id: UUID, toLocation loc: CGPoint, in rect: CGRect) {
        guard let index = floorPlan.openings.firstIndex(where: { $0.id == id }),
              let wall = floorPlan.wall(floorPlan.openings[index].wallID) else { return }
        let halfT = min((floorPlan.openings[index].width / 2) / max(floorPlan.length(wall), 1e-6), 0.49)
        let t = projectT(normalizedFromCanvas(loc, in: rect), onto: wall)
        floorPlan.openings[index].t = min(max(t, halfT), 1 - halfT)
    }

    /// Resizes a window symmetrically by dragging an end handle.
    private func resizeWindow(_ id: UUID, handleLocation loc: CGPoint, in rect: CGRect) {
        guard let index = floorPlan.openings.firstIndex(where: { $0.id == id }),
              let wall = floorPlan.wall(floorPlan.openings[index].wallID) else { return }
        let opening = floorPlan.openings[index]
        let tHandle = projectT(normalizedFromCanvas(loc, in: rect), onto: wall)
        let halfT = min(abs(tHandle - opening.t), min(opening.t, 1 - opening.t))
        floorPlan.openings[index].width = min(max(2 * halfT * floorPlan.length(wall), 0.03), 0.35)
    }

    private func updateOpening(_ id: UUID, _ change: (inout Opening) -> Void) {
        guard let index = floorPlan.openings.firstIndex(where: { $0.id == id }) else { return }
        change(&floorPlan.openings[index])
        persistFloorPlan()
    }

    private func deleteOpening(_ id: UUID) {
        floorPlan.openings.removeAll { $0.id == id }
        if openingSelectedID == id { openingSelectedID = nil }
        persistFloorPlan()
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
        // Characters are unlabeled; cameras get their label from their shot.
        var element = MapElement(kind: kind, x: point.x, y: point.y)
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

    /// Sets (replacing any existing) the scene-map background from an image file.
    /// An image and a drawn floor plan are mutually exclusive backgrounds.
    private func setBackground(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
        isDrawing = false
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        backgroundImage = image
        try? scene.modelContext?.save()
    }

    /// Enters floor-plan drawing mode, clearing any image background (one
    /// background per scene).
    private func startDrawing() {
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        drawTool = .wall
        chainLastVertex = nil
        isDrawing = true
        try? scene.modelContext?.save()
    }

    /// Removes the background (image or floor plan). Markers keep their
    /// normalized positions, now relative to the whole canvas.
    private func clearBackground() {
        isDrawing = false
        chainLastVertex = nil
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        try? scene.modelContext?.save()
    }

    private func persistFloorPlan() {
        scene.sceneFloorPlanJSON = floorPlan.jsonString
        try? scene.modelContext?.save()
    }

    private func persist() {
        scene.sceneMapJSON = doc.jsonString
        try? scene.modelContext?.save()
    }

    // MARK: - Floor plan drawing

    /// A click while drawing: wall tool adds/extends a chain of points; door and
    /// window tools drop an opening on the nearest wall.
    private func handleDrawClick(_ loc: CGPoint, in rect: CGRect) {
        switch drawTool {
        case .wall:
            addChainPoint(loc, in: rect)
        case .door, .window:
            let point = normalizedFromCanvas(loc, in: rect)
            if let (wall, t) = nearestWall(to: point, in: rect) {
                floorPlan.openings.append(
                    Opening(kind: drawTool == .door ? .door : .window, wallID: wall.id, t: t)
                )
                persistFloorPlan()
            }
        }
    }

    /// Adds a corner point. If it lands on an existing vertex, the chain joins
    /// to it (closing a loop) and ends; otherwise a new point (and a wall from
    /// the previous point) is created and the chain continues.
    private func addChainPoint(_ loc: CGPoint, in rect: CGRect) {
        let n = normalizedFromCanvas(loc, in: rect)
        if let existing = nearestVertex(to: n, in: rect, excluding: chainLastVertex) {
            if let last = chainLastVertex, last != existing.id {
                floorPlan.walls.append(Wall(a: last, b: existing.id))
            }
            chainLastVertex = nil          // joining/closing ends the chain
            persistFloorPlan()
            return
        }
        var pos = n
        if let last = chainLastVertex, let lastV = floorPlan.vertex(last) {
            pos = axisSnap(from: lastV.point, to: n, in: rect)
        }
        pos = alignSnap(pos, in: rect)
        let vertex = FloorVertex(x: pos.x, y: pos.y)
        floorPlan.vertices.append(vertex)
        if let last = chainLastVertex {
            floorPlan.walls.append(Wall(a: last, b: vertex.id))
        }
        chainLastVertex = vertex.id
        persistFloorPlan()
    }

    /// Ends the current chain, dropping a dangling single point.
    private func endChain() {
        if let last = chainLastVertex, !floorPlan.walls.contains(where: { $0.a == last || $0.b == last }) {
            floorPlan.vertices.removeAll { $0.id == last }
        }
        chainLastVertex = nil
        drawHover = nil
        persistFloorPlan()
    }

    private func normalizedFromCanvas(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        let nx = rect.width > 0 ? (p.x - rect.minX) / rect.width : 0
        let ny = rect.height > 0 ? (p.y - rect.minY) / rect.height : 0
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    /// Nearest existing vertex within ~14pt, so clicks snap to corners.
    private func nearestVertex(to p: CGPoint, in rect: CGRect, excluding: UUID? = nil) -> FloorVertex? {
        let threshold = 14.0 / max(Double(rect.width), 1)
        return floorPlan.vertices
            .filter { $0.id != excluding }
            .min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }
            .flatMap { hypot($0.x - p.x, $0.y - p.y) < threshold ? $0 : nil }
    }

    /// Snaps a wall to horizontal/vertical when it's within ~12° of an axis,
    /// leaving clearly diagonal walls alone.
    private func axisSnap(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        guard hypot(dx, dy) > 1e-6 else { return end }
        let angle = Double(atan2(dy, dx))          // -π…π
        let a = abs(angle)
        let threshold = 12.0 * Double.pi / 180.0
        if a < threshold || a > .pi - threshold { return CGPoint(x: end.x, y: start.y) }  // horizontal
        if abs(a - .pi / 2) < threshold { return CGPoint(x: start.x, y: end.y) }          // vertical
        return end
    }

    /// Aligns a point to the x/y of a nearby existing corner (within ~12pt), so
    /// walls line up — in particular the last wall closes a room cleanly.
    private func alignSnap(_ pos: CGPoint, in rect: CGRect) -> CGPoint {
        let threshold = 12.0 / max(Double(rect.width), 1)
        var p = pos
        var bestX: Double?
        var bestY: Double?
        for vertex in floorPlan.vertices where vertex.id != chainLastVertex {
            if abs(vertex.x - p.x) < threshold, bestX == nil || abs(vertex.x - p.x) < abs(bestX! - p.x) { bestX = vertex.x }
            if abs(vertex.y - p.y) < threshold, bestY == nil || abs(vertex.y - p.y) < abs(bestY! - p.y) { bestY = vertex.y }
        }
        if let bestX { p.x = bestX }
        if let bestY { p.y = bestY }
        return p
    }

    /// The wall nearest a point (within ~18pt) and the parameter t along it.
    private func nearestWall(to p: CGPoint, in rect: CGRect) -> (Wall, Double)? {
        var best: (wall: Wall, t: Double, dist: Double)?
        for wall in floorPlan.walls {
            guard let (a, b) = floorPlan.endpoints(wall) else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1e-9 else { continue }
            var t = Double(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)
            t = min(max(t, 0), 1)
            let cx = a.x + CGFloat(t) * dx, cy = a.y + CGFloat(t) * dy
            let d = Double(hypot(p.x - cx, p.y - cy))
            if best == nil || d < best!.dist { best = (wall, t, d) }
        }
        guard let b = best, b.dist < 18.0 / max(Double(rect.width), 1) else { return nil }
        return (b.wall, b.t)
    }

    private func drawFloorPlan(_ ctx: GraphicsContext, in rect: CGRect) {
        func point(_ nx: Double, _ ny: Double) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(nx) * rect.width, y: rect.minY + CGFloat(ny) * rect.height)
        }
        let wallShading = GraphicsContext.Shading.color(.primary.opacity(0.85))
        let wallWidth: CGFloat = 4

        for wall in floorPlan.walls {
            guard let (a, b) = floorPlan.endpoints(wall) else { continue }
            let p1 = point(a.x, a.y)
            let p2 = point(b.x, b.y)
            func lerp(_ t: Double) -> CGPoint {
                CGPoint(x: p1.x + CGFloat(t) * (p2.x - p1.x), y: p1.y + CGFloat(t) * (p2.y - p1.y))
            }
            let wallLen = max(floorPlan.length(wall), 1e-6)
            let wallOpenings = floorPlan.openings.filter { $0.wallID == wall.id }
            let gaps = wallOpenings
                .map { o -> (Double, Double) in
                    let half = min((o.width / 2) / wallLen, 0.49)
                    return (max(0, o.t - half), min(1, o.t + half))
                }
                .sorted { $0.0 < $1.0 }

            // Wall, with gaps where openings sit.
            var solid = Path()
            var cursor = 0.0
            for gap in gaps {
                if gap.0 > cursor { solid.move(to: lerp(cursor)); solid.addLine(to: lerp(gap.0)) }
                cursor = max(cursor, gap.1)
            }
            if cursor < 1.0 { solid.move(to: lerp(cursor)); solid.addLine(to: lerp(1.0)) }
            let wallSelected = wall.id == wallSelectedID
            ctx.stroke(solid, with: wallSelected ? .color(.accentColor) : wallShading,
                       style: StrokeStyle(lineWidth: wallSelected ? 5 : wallWidth, lineCap: .round))

            // Door / window symbols.
            let dir = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            for o in wallOpenings {
                let half = min((o.width / 2) / wallLen, 0.49)
                let jambA = lerp(max(0, o.t - half))
                let jambB = lerp(min(1, o.t + half))
                let selected = o.id == openingSelectedID
                let symbolShading: GraphicsContext.Shading = selected ? .color(.accentColor) : wallShading

                switch o.kind {
                case .door:
                    let gapLen = hypot(jambB.x - jambA.x, jambB.y - jambA.y)
                    // Hinge jamb (horizontal flip) and swing side (vertical flip).
                    let hinge = o.hingeAtEnd ? jambB : jambA
                    let alongWall = o.hingeAtEnd ? CGPoint(x: -dir.x, y: -dir.y) : dir
                    let swingPerp = o.flipped ? CGPoint(x: -perp.x, y: -perp.y) : perp
                    // A "closed" door is drawn slightly ajar; an open door swings 90°.
                    let openAngle = o.closed ? (10.0 * .pi / 180.0) : (.pi / 2)
                    // Leaf direction rotated `phi` off the wall toward the swing side.
                    func leafDir(_ phi: Double) -> CGPoint {
                        CGPoint(x: alongWall.x * CGFloat(cos(phi)) + swingPerp.x * CGFloat(sin(phi)),
                                y: alongWall.y * CGFloat(cos(phi)) + swingPerp.y * CGFloat(sin(phi)))
                    }
                    let ld = leafDir(openAngle)
                    let leafEnd = CGPoint(x: hinge.x + ld.x * gapLen, y: hinge.y + ld.y * gapLen)
                    var leaf = Path(); leaf.move(to: hinge); leaf.addLine(to: leafEnd)
                    ctx.stroke(leaf, with: symbolShading, lineWidth: 1.5)
                    // Swing arc from the wall to the leaf, sampled as a polyline.
                    var arc = Path()
                    for i in 0...16 {
                        let d = leafDir(openAngle * Double(i) / 16)
                        let pt = CGPoint(x: hinge.x + d.x * gapLen, y: hinge.y + d.y * gapLen)
                        if i == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
                    }
                    ctx.stroke(arc, with: selected ? .color(.accentColor) : .color(.secondary), lineWidth: 1)
                case .window:
                    for sign in [CGFloat(1.6), CGFloat(-1.6)] {
                        var line = Path()
                        line.move(to: CGPoint(x: jambA.x + perp.x * sign, y: jambA.y + perp.y * sign))
                        line.addLine(to: CGPoint(x: jambB.x + perp.x * sign, y: jambB.y + perp.y * sign))
                        ctx.stroke(line, with: symbolShading, lineWidth: 1.4)
                    }
                }
            }
        }

        // While drawing: show every corner point, and rubber-band from the
        // chain's last point to the cursor.
        if isDrawing {
            for vertex in floorPlan.vertices {
                let c = point(vertex.x, vertex.y)
                let isChainEnd = vertex.id == chainLastVertex
                let r: CGFloat = isChainEnd ? 5 : 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(.accentColor))
            }
            if drawTool == .wall, let last = chainLastVertex, let lastV = floorPlan.vertex(last), let hover = drawHover {
                // Show where the wall will actually land: snap to a nearby corner
                // (closing the room) else axis + alignment snapping.
                let hoverN = normalizedFromCanvas(hover, in: rect)
                let target = nearestVertex(to: hoverN, in: rect, excluding: last)?.point
                    ?? alignSnap(axisSnap(from: lastV.point, to: hoverN, in: rect), in: rect)
                var path = Path()
                path.move(to: point(lastV.x, lastV.y)); path.addLine(to: point(target.x, target.y))
                ctx.stroke(path, with: .color(.accentColor.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
            }
        }
    }

    private func unit(_ v: CGPoint) -> CGPoint {
        let m = hypot(v.x, v.y)
        return m > 0 ? CGPoint(x: v.x / m, y: v.y / m) : CGPoint(x: 1, y: 0)
    }

    private func drawArrows(_ ctx: GraphicsContext, in rect: CGRect) {
        let lineWidth: CGFloat = 6
        for arrow in doc.arrows {
            guard let from = doc.elements.first(where: { $0.id == arrow.fromID }),
                  let to = doc.elements.first(where: { $0.id == arrow.toID }) else { continue }
            // Same colour as the markers it connects.
            let shading = GraphicsContext.Shading.color(Color(hex: from.colorHex))
            let p1 = canvasPoint(from.x, from.y, in: rect)
            let p2 = canvasPoint(to.x, to.y, in: rect)
            let dir = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y))
            // Trim the ends so the shaft doesn't run under the marker icons.
            let start = CGPoint(x: p1.x + dir.x * 20, y: p1.y + dir.y * 20)
            let end = CGPoint(x: p2.x - dir.x * 22, y: p2.y - dir.y * 22)
            guard (end.x - start.x) * dir.x + (end.y - start.y) * dir.y > 6 else { continue }
            var shaft = Path(); shaft.move(to: start); shaft.addLine(to: end)
            ctx.stroke(shaft, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            let angle = Double(atan2(end.y - start.y, end.x - start.x))
            let size: CGFloat = 18
            let left = CGPoint(x: end.x - size * CGFloat(cos(angle - .pi / 6)),
                               y: end.y - size * CGFloat(sin(angle - .pi / 6)))
            let right = CGPoint(x: end.x - size * CGFloat(cos(angle + .pi / 6)),
                                y: end.y - size * CGFloat(sin(angle + .pi / 6)))
            var head = Path(); head.move(to: left); head.addLine(to: end); head.addLine(to: right)
            ctx.stroke(head, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
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
        let ids = Set(doc.elements.map(\.id))
        doc.arrows.removeAll { !ids.contains($0.fromID) || !ids.contains($0.toID) }
        if let id = selectedID, !doc.elements.contains(where: { $0.id == id }) {
            selectedID = nil
        }
        persist()
    }

    /// Characters (mannequins and hand-placed) are unlabeled, so clear any label
    /// left on existing maps.
    private func clearCharacterLabels() {
        var changed = false
        for index in doc.elements.indices where doc.elements[index].kind == .character
            && !doc.elements[index].label.isEmpty {
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
    let onSetColor: (String) -> Void
    let onDelete: () -> Void
    let onMoveTo: () -> Void
    let onMoveFrom: () -> Void

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
                .contextMenu { markerContextMenu }

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

    // MARK: Context menu

    @ViewBuilder
    private var markerContextMenu: some View {
        Button { onMoveTo() } label: { Label("Move To…", systemImage: "arrow.forward") }
        Button { onMoveFrom() } label: { Label("Move From…", systemImage: "arrow.backward") }
        Divider()
        Menu("Color") {
            ForEach(Self.palette, id: \.hex) { item in
                Button {
                    onSetColor(item.hex)
                } label: {
                    if element.colorHex.caseInsensitiveCompare(item.hex) == .orderedSame {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
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
