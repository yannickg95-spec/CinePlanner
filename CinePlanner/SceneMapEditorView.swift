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
import CoreLocation
import MapKit
import os

struct SceneMapEditorView: View {
    static let canvasSpace = "sceneMapCanvas"

    let scene: Scene
    /// When embedded in a pane (vs. presented as a sheet), drop the title bar,
    /// the Done button, and the fixed minimum size.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// iPhone in portrait — where the sun time bar needs the slider on its own row.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        return DeviceLayout.isPhone && verticalSizeClass == .regular
        #else
        return false
        #endif
    }

    enum DrawTool: String, CaseIterable { case wall = "Wall"; case door = "Door"; case window = "Window" }
    enum MoveDirection { case to, from }

    @State private var doc: SceneMapDoc
    /// Selected camera/mannequin markers. Usually one, but a marquee drag over the
    /// canvas can select several to move or delete together.
    @State private var selectedIDs: Set<UUID> = []
    /// Marquee (rubber-band) selection box corners in canvas points while dragging
    /// over empty canvas; nil when not marqueeing.
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    /// Live translation (canvas points) while dragging a multi-selection as a
    /// group; nil when no group drag is in progress.
    @State private var groupDragTranslation: CGSize?
    /// Camera marker whose shot-info popover is open (left-click a camera).
    @State private var cameraInfoElementID: UUID?
    @State private var showManageCharacters = false
    @State private var sun = SunSettings()
    @State private var showSunSettings = false
    /// Mirror of the scene's background scale, refreshed on every background change
    /// so markers re-scale immediately when the measured background swaps.
    @State private var mapMetersWide: Double?
    @State private var mapCameraMeters: Double?
    /// The map content rect's current width (points), mirrored from the canvas so
    /// the toolbar can tell whether markers would render smaller than default.
    @State private var mapContentWidth: CGFloat = 0
    /// Pinch-to-zoom of the map canvas. `zoom` is the live scale (1 = fit), `lastZoom`
    /// holds it between pinches; `pan` offsets the zoomed content, `lastPan` its
    /// committed value. The coordinate space stays logical (unscaled) so every marker
    /// gesture keeps working — only the rendering is scaled.
    ///
    /// On a satellite background these double as the reframe gesture: zooming out
    /// past 1× and panning past the image edge are allowed, a sharp satellite render
    /// of the new framing is fetched behind the markers, and the pill offers to make
    /// it the scene's background (see `commitReframe`).
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    /// Sharp satellite render of the area the canvas currently frames, fetched while
    /// reframing so the map doesn't just magnify the stored capture's pixels. Drawn
    /// under the markers, positioned by `reframePreviewRect` — the world rect it was
    /// rendered for — so it stays glued to the ground as the pan continues.
    /// True while the reframe tool is on. Panning and zooming only move the
    /// satellite background in this mode — otherwise they are the plain look-closer
    /// gestures they have always been, so nobody re-frames their map by accident.
    @State private var isReframeMode = false
    @State private var reframePreview: PlatformImage?
    @State private var reframePreviewRect: MKMapRect?
    @State private var reframeTask: Task<Void, Never>?
    @State private var isCommittingReframe = false
    /// Shared width for every icon cell in the scene-map toolbar, so the add-menu
    /// segments match the trash / sun buttons. Shrinks in iPhone landscape to give
    /// the map more room.
    private var toolbarCellWidth: CGFloat { isPhoneLandscape ? 30 : 40 }
    /// Toolbar icon point size — smaller in iPhone landscape.
    private var toolbarIconSize: CGFloat { isPhoneLandscape ? 13 : 16 }
    /// Toolbar pill height — shorter in iPhone landscape.
    private var toolbarPillHeight: CGFloat { isPhoneLandscape ? 26 : 34 }
    /// iPhone: the toolbar scrolls horizontally instead of centering with edge
    /// overlays, which would overlap on a narrow screen.
    private var isPhone: Bool { DeviceLayout.isPhone }
    /// iPhone in landscape — the scene-map toolbar shrinks and centers so the map
    /// itself gets the most space.
    private var isPhoneLandscape: Bool {
        #if os(iOS)
        return DeviceLayout.isPhone && verticalSizeClass == .compact
        #else
        return false
        #endif
    }
    @State private var furnitureToLabel: UUID?
    @State private var furnitureLabelText = ""
    @State private var markerToLabel: UUID?
    @State private var markerLabelText = ""
    @State private var backgroundImage: PlatformImage?
    @State private var showingImagePicker = false
    @State private var showingModelPicker = false
    /// The satellite location picker. Framing an already-set map is done on the
    /// canvas, so this is only for choosing where in the world the map is.
    @State private var showingMapPicker = false
    @State private var isRenderingModel = false
    @State private var showingClearAllConfirm = false
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
    /// Last cursor position over an arrow, so "Add Pivot Point" lands where you
    /// right-clicked.
    @State private var arrowHover: CGPoint = .zero
    /// Wall selected for editing (reveals all vertex handles).
    @State private var wallSelectedID: UUID?
    /// Arrow selected for editing (reveals its pivot handles).
    @State private var arrowSelectedID: UUID?
    /// Furniture selected for editing (reveals rotate/resize handles).
    @State private var furnitureSelectedID: UUID?
    /// A wall's endpoint positions captured at the start of a move drag.
    @State private var wallDragOrigin: (id: UUID, a: CGPoint, b: CGPoint)?

    init(scene: Scene, embedded: Bool = false) {
        self.scene = scene
        self.embedded = embedded
        _doc = State(initialValue: SceneMapDoc.load(from: scene.sceneMapJSON))
        _backgroundImage = State(initialValue: scene.sceneMapBackgroundData.flatMap(PlatformImage.init(data:)))
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
        .onAppear { syncShotLabels(); pruneOrphanedShotCameras(); sun = scene.sunSettings; calibrateSatelliteCapture(); refreshMapScale() }
        // Keep this editor's in-memory doc in sync when shots change underneath
        // it (e.g. a shot is deleted from the shot list while the map is open),
        // so a stale doc can't re-add the marker when it next persists.
        .onChange(of: scene.shots.map(\.uid)) { _, _ in pruneOrphanedShotCameras() }
        // Reload when the map is changed externally while open — e.g. importing a
        // shot from CineStager adds markers/background to the scene. Round-trip
        // equality means our own saves don't trigger a redundant reload.
        .onChange(of: scene.sceneMapJSON) { _, newValue in
            // A nil JSON is a definitive clear ("Clear Scene" / "Clear Map") — always
            // reset. Otherwise never let a stale/empty external value wipe a map we
            // already have; our own edits go through `doc` directly, not this path.
            if newValue == nil {
                if !doc.isEmpty { doc = SceneMapDoc(); selectedIDs = [] }
                return
            }
            let incoming = SceneMapDoc.load(from: newValue)
            guard incoming != doc, !(incoming.isEmpty && !doc.isEmpty) else { return }
            doc = incoming
            selectedIDs = selectedIDs.filter { id in doc.elements.contains { $0.id == id } }
        }
        .onChange(of: scene.sceneMapBackgroundData) { _, newValue in
            backgroundImage = newValue.flatMap(PlatformImage.init(data:))
            refreshMapScale()
            // A new background — whether just committed here or arrived from a sync —
            // makes any in-flight framing meaningless.
            resetReframe()
            isReframeMode = false
        }
        .onDisappear { reframeTask?.cancel() }
        .onChange(of: scene.sceneFloorPlanJSON) { _, newValue in
            let incoming = FloorPlan.load(from: newValue)
            guard incoming != floorPlan, !(incoming.isEmpty && !floorPlan.isEmpty) else { return }
            floorPlan = incoming
        }
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { setBackground(from: url) }
        }
        .fileImporter(isPresented: $showingModelPicker, allowedContentTypes: modelContentTypes) { result in
            if case .success(let url) = result { setBackgroundFromModel(url: url) }
        }
        .overlay {
            if isRenderingModel {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Rendering 3D model…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
        .confirmationDialog("Clear the entire scene map?", isPresented: $showingClearAllConfirm, titleVisibility: .visible) {
            Button("Clear Map", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every marker, arrow, furniture piece, floor plan and background from this scene's map. It can't be undone.")
        }
        .sheet(isPresented: $showManageCharacters) {
            if let project = scene.project {
                ManageCharactersSheet(project: project)
            }
        }
        .sheet(isPresented: $showSunSettings) {
            SunSettingsSheet(settings: $sun, onChange: saveSun,
                             isNorthLocked: scene.sceneMapBackgroundIsSatellite)
        }
        .sheet(isPresented: $showingMapPicker) {
            MapBackgroundSheet(initialCoordinate: savedSatelliteCoordinate,
                               initialMeters: scene.sceneMapBackgroundIsSatellite ? scene.sceneMapSatelliteMeters : nil) { data, coordinate, meters, label in
                // Nudging the same location keeps every marker on its real-world
                // spot; jumping somewhere else entirely is a fresh start, where
                // carrying the markers along would only fling them off the map.
                if capturesOverlap(coordinate: coordinate, meters: meters) {
                    rescaleSatelliteBackground(data, coordinate: coordinate, meters: meters, label: label)
                } else {
                    setMapBackground(data, coordinate: coordinate, meters: meters, label: label)
                }
            }
        }
        .alert("Furniture Label", isPresented: Binding(
            get: { furnitureToLabel != nil },
            set: { if !$0 { furnitureToLabel = nil } }
        )) {
            TextField("Label", text: $furnitureLabelText)
            Button("Save") {
                if let id = furnitureToLabel { setFurnitureLabel(id, furnitureLabelText) }
                furnitureToLabel = nil
            }
            Button("Cancel", role: .cancel) { furnitureToLabel = nil }
        } message: {
            Text("Shown beneath the furniture piece on the map.")
        }
        .alert("Name Label", isPresented: Binding(
            get: { markerToLabel != nil },
            set: { if !$0 { markerToLabel = nil } }
        )) {
            TextField("Name", text: $markerLabelText)
            Button("Save") {
                if let id = markerToLabel { setMarkerLabel(id, markerLabelText) }
                markerToLabel = nil
            }
            Button("Cancel", role: .cancel) { markerToLabel = nil }
        } message: {
            Text("Shown beneath the character marker on the map.")
        }
        .onDisappear { persist(); persistFloorPlan() }
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

    /// Add-camera menu label: shot number, then its nickname and size when set —
    /// e.g. "Shot 4 – Kitchen wide · MS".
    private func cameraMenuLabel(for shot: Shot) -> String {
        var text = "Shot \(shot.displayNumber)"
        let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty { text += " – \(nickname)" }
        if shot.hasSize { text += " · \(shot.sizeShort)" }
        return text
    }

    @ViewBuilder
    private var toolbar: some View {
        if isPhone { compactToolbar } else { regularToolbar }
    }

    /// iPad + Mac: the add menus centered, with the trash and sun/size pills
    /// floating at the edges (unchanged from the original layout).
    private var regularToolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            addSegmentedGroup
            Spacer()
        }
        .overlay(alignment: .leading) { trashButton.padding(.leading, 16) }
        .overlay(alignment: .trailing) { sizeSunGroup.padding(.trailing, 16) }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// iPhone: every group in one horizontally scrollable row so nothing overlaps.
    /// In landscape the groups are smaller and fit centered without scrolling, and
    /// the row is pulled tight to the top so the map gets the most height.
    private var compactToolbar: some View {
        Group {
            if isPhoneLandscape {
                HStack(spacing: 10) {
                    trashButton
                    addSegmentedGroup
                    sizeSunGroup
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        trashButton
                        addSegmentedGroup
                        sizeSunGroup
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// The four "add to the map" menus as one segmented control.
    private var addSegmentedGroup: some View {
            // One segmented bar for the four "add to the map" menus, so they read
            // as a single control.
            HStack(spacing: 0) {
                Menu {
                    let characters = (scene.project?.scriptCharacters ?? []).filter { !$0.name.isEmpty }
                    ForEach(characters) { character in
                        Button(character.name) { addCharacterMarker(name: character.name, colorHex: character.colorHex) }
                    }
                    if !characters.isEmpty { Divider() }
                    // An unlabeled background figure.
                    Button { addCharacterMarker(name: "", colorHex: "#8E8E93") } label: {
                        Label("Extra", systemImage: "plus")
                    }
                    Button { showManageCharacters = true } label: {
                        Label("Manage…", systemImage: "slider.horizontal.3")
                    }
                } label: { addMenuLabel("person.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Character")

                segmentDivider
                Menu {
                    if sceneShots.isEmpty {
                        Text("No shots in this scene")
                    } else {
                        // One camera per shot from here; a shot already on the map is
                        // disabled (a second marker for it only comes from Move To/From).
                        ForEach(sceneShots, id: \.uid) { shot in
                            Button {
                                addCamera(for: shot)
                            } label: {
                                menuSelectionLabel(cameraMenuLabel(for: shot), isSelected: hasCamera(for: shot))
                            }
                            .disabled(hasCamera(for: shot))
                        }
                    }
                } label: { addMenuLabel("video.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Camera")

                segmentDivider
                Menu {
                    Button { showingImagePicker = true } label: { Label("Image…", systemImage: "photo") }
                    // One item: the picker is for choosing a *place*. Adjusting the
                    // framing of a map that's already set happens on the canvas
                    // itself — pan and zoom, then keep it.
                    Button { showingMapPicker = true } label: {
                        Label("Satellite Map…", systemImage: "globe.europe.africa.fill")
                    }
                    Button { showingModelPicker = true } label: { Label("3D Model…", systemImage: "cube") }
                    Menu {
                        let others = scenesWithBackground
                        if others.isEmpty {
                            Text("No other scene has a background")
                        } else {
                            ForEach(others, id: \.uid) { other in
                                Button(sceneBackgroundLabel(other)) { setBackgroundFromScene(other) }
                            }
                        }
                    } label: { Label("From Another Scene…", systemImage: "square.on.square") }
                    Divider()
                    Button { startDrawing() } label: { Label("Draw Floor Plan", systemImage: "pencil.and.ruler") }
                    if backgroundImage != nil || !floorPlan.isEmpty {
                        Divider()
                        Button(role: .destructive) { clearBackground() } label: { Label("Clear Background", systemImage: "xmark") }
                    }
                } label: { addMenuLabel("map.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Background")

                segmentDivider
                Menu {
                    ForEach(Furniture.Kind.allCases, id: \.self) { kind in
                        Button(kind.rawValue) { addFurniture(kind) }
                    }
                } label: { addMenuLabel("chair.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Furniture")
            }
            .modifier(SegmentedGroup(height: toolbarPillHeight))
    }

    /// Clear-map (trash) pill.
    private var trashButton: some View {
        Button(role: .destructive) { showingClearAllConfirm = true } label: {
            Image(systemName: "trash").font(.system(size: toolbarIconSize, weight: .medium)).frame(width: toolbarCellWidth).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .modifier(SegmentedGroup(height: toolbarPillHeight))
        .disabled(mapIsEmpty)
        .help("Clear Map — remove everything from the scene map")
        .accessibilityLabel("Clear map")
        .accessibilityHint("Removes everything from the scene map")
    }

    /// The marker-size toggle (when relevant) plus the sun overlay and its settings.
    private var sizeSunGroup: some View {
        // Two separate pills: the marker-size toggle stands on its own (only on
        // measured maps where a marker would render smaller than default), then
        // the sun overlay + its settings.
        HStack(spacing: 10) {
            if viewableSizeToggleRelevant {
                Button { toggleViewableMarkerSize() } label: {
                    Image(systemName: scene.sceneMapViewableMarkerSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: toolbarIconSize, weight: .medium))
                        .foregroundStyle(scene.sceneMapViewableMarkerSize ? Color.accentColor : .secondary)
                        .frame(width: toolbarCellWidth).frame(maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .modifier(SegmentedGroup(height: toolbarPillHeight))
                .help(scene.sceneMapViewableMarkerSize
                      ? "Markers: easy-to-see size — tap for real-world scale"
                      : "Markers: real-world scale — tap for an easy-to-see size")
                .accessibilityLabel(scene.sceneMapViewableMarkerSize
                                    ? "Switch markers to real-world scale"
                                    : "Switch markers to an easy-to-see size")
            }
            Button {
                sun.enabled.toggle()
                saveSun()
                if sun.enabled && !sun.hasLocation { showSunSettings = true }
            } label: {
                Image(systemName: sun.enabled ? "sun.max.fill" : "sun.max")
                    .font(.system(size: toolbarIconSize, weight: .medium))
                    .foregroundStyle(sun.enabled ? .orange : .secondary)
                    .frame(width: toolbarCellWidth).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .modifier(SegmentedGroup(height: toolbarPillHeight))
            .help("Toggle the sun-direction overlay")

            Button { showSunSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: toolbarIconSize, weight: .medium))
                    .frame(width: toolbarCellWidth).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .modifier(SegmentedGroup(height: toolbarPillHeight))
            .help("Location details")
            .accessibilityLabel("Location details")
        }
    }

    /// One segment's label. Matches the trash and sun pills exactly — a single
    /// 16pt symbol with the same padding — so every toolbar group uses the same
    /// square button.
    private func addMenuLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: toolbarIconSize, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private var segmentDivider: some View {
        Divider().frame(height: 18)
    }

    private func saveSun() {
        scene.sunSettings = sun
        try? scene.modelContext?.save()
    }

    /// Corrects a satellite capture whose recorded size predates the measured
    /// snapshot scale — a one-off, on first open of the scene map. Without it the
    /// stored metres understate the ground the image covers, so markers draw too
    /// large and reframing drifts by the size of the error.
    private func calibrateSatelliteCapture() {
        guard !scene.sceneMapSatelliteCalibrated else { return }
        SatelliteCalibration.calibrate(scene)
        try? scene.modelContext?.save()
    }

    /// Re-reads the background's real-world scale into local state so markers
    /// re-scale whenever the background (and its scale) changes.
    private func refreshMapScale() {
        mapMetersWide = scene.sceneMapMetersWide
        mapCameraMeters = scene.sceneMapCameraSizeMeters
    }

    /// True when there's nothing on the map to clear.
    private var mapIsEmpty: Bool {
        doc.elements.isEmpty && doc.arrows.isEmpty && doc.furniture.isEmpty
            && floorPlan.isEmpty && backgroundImage == nil
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
                Color.platformTextBackground
                // The background art rides the same transform as the content, but in
                // its own layer so the sharp reframe render can slot in between it
                // and the markers.
                backgroundArt(in: rect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(zoom, anchor: .center)
                    .offset(pan)
                    .clipped()
                    .allowsHitTesting(false)
                reframeRender(in: rect, canvas: geo.size)
                canvasContent(in: rect, geo: geo)
            }
            .overlay { reframeButton(in: rect) }
            .overlay { reframeChrome(in: rect, canvas: geo.size) }
            .onChange(of: reframeKey) { scheduleReframeRender(in: rect, canvas: geo.size) }
        }
    }

    /// The stored background image, or a grid standing in for a missing one.
    @ViewBuilder
    private func backgroundArt(in rect: CGRect) -> some View {
        if let backgroundImage {
            Image(platformImage: backgroundImage)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        } else {
            // A grid stands in for the (missing) background. Kept free of
            // `doc` so it never redraws while a marker is being dragged.
            Canvas { ctx, _ in drawGrid(ctx, rect) }
        }
    }

    private func canvasContent(in rect: CGRect, geo: GeometryProxy) -> some View {
        ZStack {
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
            // Furniture, below the people/cameras so they read as "on" it.
            if !isDrawing {
                ForEach(doc.furniture) { item in
                    FurnitureView(
                        furniture: item,
                        isSelected: furnitureSelectedID == item.id,
                        contentRect: rect,
                        zoom: zoom,
                        onSelect: { selectFurniture(item.id) },
                        onMove: { normalized in moveFurniture(item.id, to: normalized) },
                        onRotate: { r in rotateFurniture(item.id, to: r) },
                        onResize: { w, h in resizeFurniture(item.id, width: w, height: h) },
                        onSetColor: { hex in setFurnitureColor(item.id, hex) },
                        onReorder: { move in reorderFurniture(item.id, move) },
                        onDuplicate: { duplicateFurniture(item.id) },
                        onEditLabel: {
                            furnitureToLabel = item.id
                            furnitureLabelText = item.label
                        },
                        onMoveLabel: { offset in moveFurnitureLabel(item.id, to: offset) },
                        metersWide: mapMetersWide,
                        onDelete: { deleteFurniture(item.id) }
                    )
                    .allowsHitTesting(pendingMove == nil && !reframeActive)
                }
            }
            // Camera field-of-view wedges, under the arrows and markers.
            // Reads the scene flag directly so toggling it re-renders here.
            if scene.sceneMapShowCameraFOV {
                Canvas { ctx, _ in drawCameraFOV(ctx, in: rect) }
                    .allowsHitTesting(false)
            }
            // Movement arrows are drawn crisply in a screen-space overlay outside
            // the zoom (see below); only their right-click hit areas live here.
            if !doc.arrows.isEmpty, !isDrawing, pendingMove == nil {
                ForEach(doc.arrows) { arrow in
                    arrowHitView(arrow, in: rect)
                }
            }
            ForEach(doc.elements) { element in
                MapMarkerView(
                    element: element,
                    label: resolvedLabel(for: element),
                    zoom: zoom,
                    isSelected: selectedIDs.contains(element.id),
                    contentRect: rect,
                    onSelect: { selectMarker(element.id) },
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
                    showsRotationHandle: selectedIDs.count == 1,
                    selectedCount: (selectedIDs.count > 1 && selectedIDs.contains(element.id)) ? selectedIDs.count : 1,
                    isGroupMember: selectedIDs.count > 1 && selectedIDs.contains(element.id),
                    groupDragOffset: (selectedIDs.count > 1 && selectedIDs.contains(element.id))
                        ? (groupDragTranslation ?? .zero) : .zero,
                    onGroupDragChanged: { groupDragTranslation = $0 },
                    onGroupDragEnded: { commitGroupDrag($0, in: rect) },
                    scale: sceneMarkerScale(kind: element.kind,
                                            metersWide: mapMetersWide,
                                            cameraMeters: mapCameraMeters,
                                            mapWidthPoints: rect.width,
                                            viewable: scene.sceneMapViewableMarkerSize)
                )
                .allowsHitTesting(!isDrawing && pendingMove == nil && !reframeActive)
            }
            // Door/window edit handles (tap to select, right-click to edit).
            if !isDrawing {
                ForEach(floorPlan.openings) { opening in
                    openingHandle(opening, in: rect)
                }
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
            }
            // Placing the second (moved) marker: the next click drops it and
            // draws the connecting arrow.
            if pendingMove != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named(SceneMapEditorView.canvasSpace))
                        .onEnded { value in placeMovedMarker(at: value.location, in: rect) })
            }
            // Marquee (rubber-band) selection box, above the markers.
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
            // Sun-direction overlay (non-interactive), above the map content.
            sunOverlay(in: rect)
            // Apple Maps attribution on satellite backgrounds.
            if scene.sceneMapBackgroundIsSatellite, backgroundImage != nil {
                AppleMapsAttribution(rect: rect)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(name: SceneMapEditorView.canvasSpace)
        // Pinch-to-zoom (all platforms). Applied after the coordinate space so
        // the canvasSpace stays in logical points — marker/selection gestures,
        // which read `.named(canvasSpace)`, are unaffected by the zoom.
        .scaleEffect(zoom, anchor: .center)
        .offset(pan)
        .clipped()
        // scaleEffect also scales the canvas's hit region, so when zoomed in it
        // spilled over the toolbar above and swallowed its taps. Reset the
        // interactive shape to the (unscaled) frame so touches outside it — the
        // toolbar — pass through again.
        .contentShape(Rectangle())
        // Movement arrows: drawn OUTSIDE the zoom in a screen-space Canvas so the
        // vector rasterizes crisply at any zoom (a Canvas inside scaleEffect would
        // just be a magnified 1x bitmap). The zoom/pan is applied to the graphics
        // context instead. Their markers are trimmed away, so drawing on top reads
        // the same as under them.
        .overlay {
            if !doc.arrows.isEmpty {
                Canvas { ctx, _ in drawArrows(ctx, in: rect, canvas: geo.size) }
                    .allowsHitTesting(false)
                    .clipped()
            }
        }
        // Camera shot-info card — a plain overlay (not a system popover), so the
        // marker underneath stays draggable. Placed OUTSIDE the zoom transform so
        // it's a constant on-screen size and always fits, tracking the marker's
        // transformed screen position at any zoom.
        .overlay { cameraShotCard(in: rect, canvas: geo.size) }
        // Two-finger trackpad swipe pans the zoomed map (and any satellite map,
        // where panning reframes it); a mouse wheel zooms. macOS only: on iPad the
        // transparent catcher overlay sat on the touch/pinch path and is the
        // suspected cause of a zoom crash — touch devices pan by dragging anyway.
        #if os(macOS)
        .overlay(
            TrackpadScrollCatcher(
                enabled: zoom > 1 || canReframe,
                onZoom: { factor in zoomBy(factor, size: geo.size) },
                onScroll: { delta in panBy(delta, size: geo.size) }
            )
        )
        #endif
        .onAppear { mapContentWidth = rect.width }
        .onChange(of: geo.size) { mapContentWidth = contentRect(in: geo.size).width }
        // Pinch (zoom) and one-finger empty-canvas drag (pan/marquee) as a single
        // recognizer — a separate `.simultaneousGesture` for the pinch made iOS
        // defer the drag's continuous updates, so panning only jumped on release.
        // Attached with `.gesture`, so markers still capture their own drags.
        .gesture(
            SimultaneousGesture(
                magnifyGesture(size: geo.size),
                canvasPanOrMarquee(in: rect, size: geo.size,
                                   canvasOrigin: geo.frame(in: .global).origin)
            )
        )
        .onTapGesture { if !isDrawing { selectedIDs = []; openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil; furnitureSelectedID = nil; cameraInfoElementID = nil } }
        #if os(macOS)
        .onDeleteCommand { if !selectedIDs.isEmpty { deleteSelectedMarkers() } }
        #endif
        .overlay(alignment: .top) {
            if pendingMove != nil { moveBanner }
        }
        .overlay(alignment: .bottom) {
            if sun.enabled && sun.hasLocation { sunTimeBar }
        }
    }

    // MARK: - Reframing a satellite background

    /// The stored capture's geo-anchor: where its centre is and how many metres it
    /// spans. Present only for a satellite background, which is the only kind that
    /// can be reframed — a photo or a drawn plan has no world behind its edges.
    private var satelliteAnchor: SatelliteFraming? {
        guard scene.sceneMapBackgroundIsSatellite,
              let lat = scene.sceneMapSatelliteLat,
              let lon = scene.sceneMapSatelliteLon,
              let meters = scene.sceneMapSatelliteMeters, meters > 0 else { return nil }
        return SatelliteFraming(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                meters: meters)
    }

    /// Whether this map *could* be reframed — the toolbar button's condition.
    private var canReframe: Bool { satelliteAnchor != nil }

    /// Whether the reframe tool is actually running.
    private var reframeActive: Bool { isReframeMode && canReframe }

    /// True once the canvas frames something other than the stored capture.
    private var isReframing: Bool { reframeActive && (zoom != 1 || pan != .zero) }

    /// Zooming out below 1× only means something when there's more world to show.
    private var minZoom: CGFloat { reframeActive ? 0.3 : 1 }

    /// Slider range for the reframe zoom, widest to tightest.
    private static let reframeZoomRange: ClosedRange<CGFloat> = 0.3...4

    /// How far the content may be panned. Normally just enough to reach the edges of
    /// the zoomed image; while reframing, freely — panning *is* the point, and the
    /// stored capture's edge is no longer a wall.
    private func panLimits(_ size: CGSize, zoom z: CGFloat) -> CGSize {
        if reframeActive { return CGSize(width: size.width * 1.5, height: size.height * 1.5) }
        return CGSize(width: size.width * (z - 1) / 2, height: size.height * (z - 1) / 2)
    }

    /// Whether an empty-canvas drag pans. While reframing it always does — dragging
    /// the map is the whole point of the tool, and marker edits are suspended anyway.
    private var dragPansCanvas: Bool { reframeActive || zoom > 1 }

    /// The world rect the whole canvas is showing at the current zoom/pan.
    private func liveCanvasRect(in rect: CGRect, canvas: CGSize) -> MKMapRect? {
        satelliteAnchor?.canvasRect(contentWidth: rect.width, canvas: canvas, zoom: zoom, pan: pan)
    }

    /// The capture the current framing would produce — exactly what the crop frame
    /// draws. At rest this is identical to the stored capture, so committing without
    /// having moved is a no-op.
    private func pendingCapture(in rect: CGRect, canvas: CGSize) -> SatelliteFraming? {
        satelliteAnchor?.capture(contentWidth: rect.width, canvas: canvas, zoom: zoom, pan: pan)
    }

    /// Coarse key so a new satellite render is fetched only when the framing has
    /// meaningfully moved, not on every sub-pixel of a drag.
    private var reframeKey: String {
        "\(Int(zoom * 100))-\(Int(pan.width))-\(Int(pan.height))"
    }

    /// The sharp render of the framed area, drawn under the markers. Positioned by
    /// the world rect it was rendered for, so it stays pinned to the ground while a
    /// later pan is still in flight — it goes stale by drifting off-canvas, never by
    /// sliding out of register with the markers.
    @ViewBuilder
    private func reframeRender(in rect: CGRect, canvas: CGSize) -> some View {
        if let image = reframePreview, let shot = reframePreviewRect,
           let live = liveCanvasRect(in: rect, canvas: canvas), live.width > 0 {
            let scale = Double(canvas.width) / live.width
            Image(platformImage: image)
                .resizable()
                .frame(width: CGFloat(shot.width * scale), height: CGFloat(shot.height * scale))
                .position(x: CGFloat((shot.midX - live.minX) * scale),
                          y: CGFloat((shot.midY - live.minY) * scale))
                .clipped()
                .allowsHitTesting(false)
        }
    }

    /// Picks up the reframe tool. It sits on the map rather than in the toolbar:
    /// it acts on the map, only a satellite background has any use for it, and the
    /// toolbar row is long enough already. Hidden once the tool is running — the
    /// reframe bar carries its own way out.
    @ViewBuilder
    private func reframeButton(in rect: CGRect) -> some View {
        if canReframe, !isReframeMode, !isDrawing, pendingMove == nil {
            let inset: CGFloat = 25
            Button { isReframeMode = true } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .help("Reframe the satellite map")
            // Pinned to the map's own top-right corner, not the canvas's — on a wide
            // window the square map leaves empty canvas beside it, and a button
            // floating out there reads as belonging to nothing. Placed outside the
            // zoom transform so it stays put while the map moves under it.
            .position(x: rect.maxX - inset, y: rect.minY + inset)
        }
    }

    /// The reframe tool's furniture: the square that will be captured, everything
    /// outside it dimmed, and a bar to zoom, keep or cancel. Shown for as long as the
    /// tool is on — not only once something has moved — so it is always clear which
    /// mode the map is in.
    @ViewBuilder
    private func reframeChrome(in rect: CGRect, canvas: CGSize) -> some View {
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
            .overlay(alignment: .top) { reframeBar(meters: pending.meters, rect: rect, canvas: canvas) }
        }
    }

    /// Maps the zoom onto the slider's 0…1 geometrically, so the tight and wide ends
    /// both get usable travel and 1× (the stored framing) sits near the middle.
    private func reframeZoomBinding(canvas: CGSize) -> Binding<Double> {
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

    private func reframeBar(meters: Double, rect: CGRect, canvas: CGSize) -> some View {
        // The full bar needs about 480 pt; below that it drops the magnifier icons
        // and shortens the slider rather than running off a narrow canvas.
        let compact = isPhone || canvas.width < 520
        return HStack(spacing: compact ? 7 : 10) {
            Image(systemName: "viewfinder").foregroundStyle(.secondary)
            Text("\(Int(meters.rounded())) m").monospacedDigit()
            Divider().frame(height: 14)
            if !compact { Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary) }
            Slider(value: reframeZoomBinding(canvas: canvas), in: 0...1)
                .frame(width: compact ? 90 : 140)
            if !compact { Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary) }
            Divider().frame(height: 14)
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
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.top, 10)
    }

    /// How much wider than the canvas each render reaches. The overshoot is what the
    /// next pan slides into, so a drag doesn't drag a bare edge along with it.
    private static let reframeRenderMargin = 1.4

    /// Debounced: fetches a satellite render of the framed area shortly after the
    /// gesture settles, so panning stays smooth and only one render is in flight.
    private func scheduleReframeRender(in rect: CGRect, canvas: CGSize) {
        reframeTask?.cancel()
        guard isReframing, let live = liveCanvasRect(in: rect, canvas: canvas) else {
            reframePreview = nil
            reframePreviewRect = nil
            return
        }
        let margin = Self.reframeRenderMargin
        let area = MKMapRect(x: live.midX - live.width * margin / 2,
                             y: live.midY - live.height * margin / 2,
                             width: live.width * margin, height: live.height * margin)
        reframeTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let pixels = CGSize(width: max(canvas.width, 320) * margin,
                                height: max(canvas.height, 320) * margin)
            let image = try? await MapSnapshot.satelliteImage(mapRect: area, pixelSize: pixels)
            if Task.isCancelled { return }
            if let image {
                reframePreview = image
                reframePreviewRect = area
            }
        }
    }

    /// Makes the framed area the scene's background. `rescaleSatelliteBackground`
    /// carries every marker, arrow, furniture piece and floor-plan vertex to the same
    /// real-world spot in the new capture, so nothing moves on screen — the ground
    /// under it just becomes the map.
    private func commitReframe(in rect: CGRect, canvas: CGSize) {
        guard !isCommittingReframe, let target = pendingCapture(in: rect, canvas: canvas) else { return }
        isCommittingReframe = true
        Task {
            defer { isCommittingReframe = false }
            do {
                let image = try await MapSnapshot.satelliteImage(coordinate: target.center,
                                                                meters: target.meters)
                guard let data = image.pngRepresentation() else { return }
                rescaleSatelliteBackground(data, coordinate: target.center,
                                           meters: target.meters, label: nil)
                resetReframe()
                isReframeMode = false
            } catch {
                Log.sceneMap.error("Reframe capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Leaves the tool, putting the map back exactly as it was.
    private func cancelReframe() {
        resetReframe()
        isReframeMode = false
    }

    /// Back to the stored capture, exactly as it was.
    private func resetReframe() {
        reframeTask?.cancel()
        reframeTask = nil
        reframePreview = nil
        reframePreviewRect = nil
        zoom = 1; lastZoom = 1
        pan = .zero; lastPan = .zero
    }

    /// The sun as a yellow ball on a ring around the map centre, in its compass
    /// direction (adjusted for the map's North), with an arrow showing the way the
    /// light travels (inward, toward the scene). Greyed when below the horizon.
    @ViewBuilder
    private func sunOverlay(in rect: CGRect) -> some View {
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
    private func sunColor(altitude: Double) -> Color {
        let t = min(max(altitude / 50, 0), 1)
        return Color(hue: 0.06 + 0.09 * t, saturation: 1 - 0.15 * t, brightness: 1)
    }

    /// Bottom bar shown with the overlay: scrub the time of day; reads out the
    /// sun's altitude plus the day's sunrise / sunset times.
    private var sunTimeBar: some View {
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
    private func cameraShotCard(in rect: CGRect, canvas: CGSize) -> some View {
        if let id = cameraInfoElementID,
           let element = doc.elements.first(where: { $0.id == id }),
           element.kind == .camera,
           let uid = element.shotUID,
           let shot = scene.shots.first(where: { $0.uid == uid }) {
            // The card lives outside the zoom transform (constant on-screen size), so
            // work in screen space: map the marker's logical position through the
            // scaleEffect(anchor: .center) + offset(pan) to where it actually appears.
            let compact = DeviceLayout.isPhone
            let cardW: CGFloat = compact ? 190 : 264
            let estH: CGFloat = compact ? 230 : 300
            let gap: CGFloat = 24
            let mLogicalX = rect.minX + element.x * rect.width
            let mLogicalY = rect.minY + element.y * rect.height
            let cxScreen = canvas.width / 2 + (mLogicalX - canvas.width / 2) * zoom + pan.width
            let cyScreen = canvas.height / 2 + (mLogicalY - canvas.height / 2) * zoom + pan.height
            let placeRight = cxScreen + gap + cardW <= canvas.width
            let cxRaw = placeRight ? cxScreen + gap + cardW / 2 : cxScreen - gap - cardW / 2
            // Clamp to the screen so an edge marker's card stays fully visible.
            let cx = min(max(cxRaw, cardW / 2 + 8), max(cardW / 2 + 8, canvas.width - cardW / 2 - 8))
            let cy = min(max(cyScreen, estH / 2 + 8), max(estH / 2 + 8, canvas.height - estH / 2 - 8))
            CameraShotPopover(shot: shot, compact: compact)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 9, y: 2)
                .fixedSize()
                .position(x: cx, y: cy)
                .transition(.opacity)
        }
    }

    private var moveBanner: some View {
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

    /// Assigns a character (its name as the label, its color) to a mannequin marker.
    private func setCharacter(_ id: UUID, _ character: ScriptCharacter) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].label = character.name
        doc.elements[index].colorHex = character.colorHex
        persist()
    }

    /// Sets (or clears, with "") a character marker's free-text name label.
    private func setMarkerLabel(_ id: UUID, _ label: String) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// Toggles one marker's name-label visibility (per marker, so a character's two
    /// walk markers are independent).
    private func toggleLabelHidden(_ id: UUID) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].labelHidden.toggle()
        persist()
    }

    private func deleteElement(_ id: UUID) {
        doc.elements.removeAll { $0.id == id }
        doc.arrows.removeAll { $0.fromID == id || $0.toID == id }
        selectedIDs.remove(id)
        persist()
    }

    /// Deletes a marker, or — when it's part of a multi-selection — every selected
    /// marker (used by the marker's Delete menu item and the delete key).
    private func deleteMarkerOrSelection(_ id: UUID) {
        if selectedIDs.count > 1 && selectedIDs.contains(id) {
            deleteSelectedMarkers()
        } else {
            deleteElement(id)
        }
    }

    /// Deletes every selected marker (and any arrows touching them) in one go.
    private func deleteSelectedMarkers() {
        guard !selectedIDs.isEmpty else { return }
        let ids = selectedIDs
        doc.elements.removeAll { ids.contains($0.id) }
        doc.arrows.removeAll { ids.contains($0.fromID) || ids.contains($0.toID) }
        selectedIDs = []
        persist()
    }

    /// Selects a single marker (a plain tap), clearing every other kind of
    /// selection.
    private func selectMarker(_ id: UUID) {
        selectedIDs = [id]
        openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil; furnitureSelectedID = nil
    }

    /// Commits a group drag: shifts every selected marker by the drag translation
    /// (canvas points), clamped to the map.
    private func commitGroupDrag(_ translation: CGSize, in rect: CGRect) {
        defer { groupDragTranslation = nil }
        guard rect.width > 0, rect.height > 0 else { return }
        for i in doc.elements.indices where selectedIDs.contains(doc.elements[i].id) {
            let cx = rect.minX + doc.elements[i].x * rect.width + translation.width
            let cy = rect.minY + doc.elements[i].y * rect.height + translation.height
            doc.elements[i].x = min(max((cx - rect.minX) / rect.width, 0), 1)
            doc.elements[i].y = min(max((cy - rect.minY) / rect.height, 0), 1)
        }
        persist()
    }

    /// Selects every camera/mannequin marker whose center falls inside the marquee
    /// rectangle (canvas points).
    private func selectMarkersInMarquee(_ box: CGRect, in rect: CGRect) {
        var hits: Set<UUID> = []
        for element in doc.elements {
            let c = CGPoint(x: rect.minX + element.x * rect.width,
                            y: rect.minY + element.y * rect.height)
            if box.contains(c) { hits.insert(element.id) }
        }
        selectedIDs = hits
        openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil; furnitureSelectedID = nil
    }

    /// Pinch-to-zoom the whole map, clamped `minZoom`…4×. Zooms about the pinch/cursor
    /// point (not the map centre): the scale stays anchored at `.center`, but `pan`
    /// is adjusted each step so the content under the pinch stays put. On a plain
    /// background, pinching back to 1× recenters; on a satellite map 1× is just
    /// another framing, so only the scale snaps.
    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let z0 = zoom
                let z1 = min(max(lastZoom * value.magnification, minZoom), 4)
                guard z1 != z0 else { return }
                // Offset of the pinch point from the map centre.
                let dx = value.startAnchor.x * size.width - size.width / 2
                let dy = value.startAnchor.y * size.height - size.height / 2
                let ratio = z1 / z0
                var newPan = CGSize(width: dx - ratio * (dx - pan.width),
                                    height: dy - ratio * (dy - pan.height))
                let limits = panLimits(size, zoom: z1)
                newPan.width = min(max(newPan.width, -limits.width), limits.width)
                newPan.height = min(max(newPan.height, -limits.height), limits.height)
                zoom = z1
                pan = newPan
            }
            .onEnded { _ in
                lastZoom = zoom
                lastPan = pan
                if reframeActive {
                    if abs(zoom - 1) < 0.02 { zoom = 1; lastZoom = 1 }
                } else if zoom <= 1.02 {
                    zoom = 1; lastZoom = 1
                    withAnimation(.easeOut(duration: 0.15)) { pan = .zero }
                    lastPan = .zero
                }
            }
    }

    /// Zoom a step from a mouse wheel, about the map centre (a wheel has no anchor
    /// the way a pinch does). `pan` scales with the zoom so the ground under the
    /// centre stays put.
    private func zoomBy(_ factor: CGFloat, size: CGSize) {
        let z1 = min(max(zoom * factor, minZoom), 4)
        guard z1 != zoom else { return }
        let ratio = z1 / zoom
        var newPan = CGSize(width: pan.width * ratio, height: pan.height * ratio)
        let limits = panLimits(size, zoom: z1)
        newPan.width = min(max(newPan.width, -limits.width), limits.width)
        newPan.height = min(max(newPan.height, -limits.height), limits.height)
        zoom = z1; lastZoom = z1
        pan = newPan; lastPan = newPan
    }

    /// One empty-canvas drag: pans the zoomed map when zoomed in, else (macOS) draws
    /// a rubber-band selection box. Measured in the global (screen) space so the pan
    /// tracks the finger 1:1 and updates live — reading the canvas space here would
    /// feed the moving `pan` offset back into the measurement.
    private func canvasPanOrMarquee(in rect: CGRect, size: CGSize, canvasOrigin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if dragPansCanvas {
                    let limits = panLimits(size, zoom: zoom)
                    pan = CGSize(
                        width: min(max(lastPan.width + value.translation.width, -limits.width), limits.width),
                        height: min(max(lastPan.height + value.translation.height, -limits.height), limits.height))
                    return
                }
                #if os(macOS)
                guard !isDrawing, pendingMove == nil else { return }
                if marqueeStart == nil {
                    marqueeStart = CGPoint(x: value.startLocation.x - canvasOrigin.x,
                                           y: value.startLocation.y - canvasOrigin.y)
                    cameraInfoElementID = nil
                }
                marqueeCurrent = CGPoint(x: value.location.x - canvasOrigin.x,
                                         y: value.location.y - canvasOrigin.y)
                #endif
            }
            .onEnded { value in
                if dragPansCanvas { lastPan = pan; return }
                #if os(macOS)
                defer { marqueeStart = nil; marqueeCurrent = nil }
                guard !isDrawing, pendingMove == nil, let start = marqueeStart else { return }
                let loc = CGPoint(x: value.location.x - canvasOrigin.x, y: value.location.y - canvasOrigin.y)
                let box = CGRect(x: min(start.x, loc.x), y: min(start.y, loc.y),
                                 width: abs(loc.x - start.x), height: abs(loc.y - start.y))
                selectMarkersInMarquee(box, in: rect)
                #endif
            }
    }

    /// Pan the zoomed map by an incremental trackpad-scroll delta, clamped to the
    /// same bounds as the drag pan. `lastPan` is kept in sync so a following drag
    /// continues from here.
    private func panBy(_ delta: CGSize, size: CGSize) {
        guard zoom > 1 || reframeActive else { return }
        let limits = panLimits(size, zoom: zoom)
        pan = CGSize(
            width: min(max(pan.width + delta.width, -limits.width), limits.width),
            height: min(max(pan.height + delta.height, -limits.height), limits.height))
        lastPan = pan
    }

    // MARK: - Furniture

    private func addFurniture(_ kind: Furniture.Kind) {
        let point = newElementPoint
        let size = kind.defaultSize
        let item = Furniture(kind: kind, x: point.x, y: point.y,
                             width: Double(size.width), height: Double(size.height))
        doc.furniture.append(item)
        selectFurniture(item.id)
        persist()
    }

    private func selectFurniture(_ id: UUID) {
        furnitureSelectedID = id
        selectedIDs = []; openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil
    }

    private func moveFurniture(_ id: UUID, to n: CGPoint) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].x = n.x; doc.furniture[i].y = n.y
        persist()
    }

    private func rotateFurniture(_ id: UUID, to r: Double) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].rotation = r
        persist()
    }

    private func resizeFurniture(_ id: UUID, width: Double, height: Double) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].width = width; doc.furniture[i].height = height
        persist()
    }

    private func setFurnitureColor(_ id: UUID, _ hex: String) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].colorHex = hex
        persist()
    }

    private func setFurnitureLabel(_ id: UUID, _ label: String) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// Commit a furniture label's nudge once its drag ends.
    private func moveFurnitureLabel(_ id: UUID, to offset: CGSize) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].labelOffset = offset
        persist()
    }

    /// Reorders a furniture piece within the draw stack (its z-order): later in
    /// the array = drawn on top.
    private func reorderFurniture(_ id: UUID, _ move: FurnitureLayerMove) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        let item = doc.furniture.remove(at: i)
        let target: Int
        switch move {
        case .toBack:   target = 0
        case .backward: target = max(0, i - 1)
        case .forward:  target = min(doc.furniture.count, i + 1)
        case .toFront:  target = doc.furniture.count
        }
        doc.furniture.insert(item, at: target)
        persist()
    }

    /// Duplicates a furniture piece, offset slightly and placed on top, then
    /// selects the copy.
    private func duplicateFurniture(_ id: UUID) {
        guard let item = doc.furniture.first(where: { $0.id == id }) else { return }
        var copy = item
        copy.id = UUID()
        copy.x = min(max(item.x + 0.03, 0), 1)
        copy.y = min(max(item.y + 0.03, 0), 1)
        doc.furniture.append(copy)
        furnitureSelectedID = copy.id
        persist()
    }

    private func deleteFurniture(_ id: UUID) {
        doc.furniture.removeAll { $0.id == id }
        if furnitureSelectedID == id { furnitureSelectedID = nil }
        persist()
    }

    // MARK: - Movement arrows

    /// Begins a move: the next canvas click places the second marker.
    private func startMove(_ id: UUID, _ direction: MoveDirection) {
        pendingMove = (origin: id, direction: direction)
        selectedIDs = []
    }

    /// Completes a move. If the click lands on an existing marker of the same
    /// kind, the arrow connects to it; otherwise a new marker is dropped there.
    private func placeMovedMarker(at loc: CGPoint, in rect: CGRect) {
        defer { pendingMove = nil }
        guard let move = pendingMove,
              let origin = doc.elements.first(where: { $0.id == move.origin }) else { return }

        let endID: UUID
        if let target = nearestElement(to: loc, in: rect, kind: origin.kind, excluding: origin.id) {
            endID = target.id
        } else {
            let n = normalizedFromCanvas(loc, in: rect)
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
    private func nearestElement(to loc: CGPoint, in rect: CGRect,
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

    private func selectArrow(_ id: UUID) {
        arrowSelectedID = id
        selectedIDs = []
        openingSelectedID = nil
        wallSelectedID = nil
        furnitureSelectedID = nil
    }

    @ViewBuilder
    private func arrowHitView(_ arrow: MapArrow, in rect: CGRect) -> some View {
        if let pts = arrowCanvasPoints(arrow, in: rect), pts.count >= 2 {
            Color.clear
                .contentShape(ArrowHitShape(points: pts))
                .onTapGesture { selectArrow(arrow.id) }
                .onContinuousHover(coordinateSpace: .named(SceneMapEditorView.canvasSpace)) { phase in
                    if case .active(let location) = phase { arrowHover = location }
                }
                .contextMenu {
                    Button { selectArrow(arrow.id); addPivot(to: arrow.id, at: arrowHover, in: rect) } label: {
                        Label("Add Pivot Point", systemImage: "smallcircle.filled.circle")
                    }
                    Divider()
                    Button(role: .destructive) { deleteArrow(arrow.id) } label: {
                        Label("Delete Arrow", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func pivotHandle(arrowID: UUID, index: Int, in rect: CGRect) -> some View {
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
    private func addPivot(to arrowID: UUID, at loc: CGPoint, in rect: CGRect) {
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

    private func movePivot(_ arrowID: UUID, _ index: Int, to loc: CGPoint, in rect: CGRect) {
        guard let ai = doc.arrows.firstIndex(where: { $0.id == arrowID }),
              index < doc.arrows[ai].pivots.count else { return }
        doc.arrows[ai].pivots[index] = normalizedFromCanvas(loc, in: rect)
    }

    private func removePivot(_ arrowID: UUID, _ index: Int) {
        guard let ai = doc.arrows.firstIndex(where: { $0.id == arrowID }),
              index < doc.arrows[ai].pivots.count else { return }
        doc.arrows[ai].pivots.remove(at: index)
        persist()
    }

    private func deleteArrow(_ id: UUID) {
        doc.arrows.removeAll { $0.id == id }
        persist()
    }

    /// Distance from a point to a segment, all in normalized coordinates.
    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-12 { return Double(hypot(p.x - a.x, p.y - a.y)) }
        var t = Double(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)
        t = min(max(t, 0), 1)
        let cx = a.x + CGFloat(t) * dx, cy = a.y + CGFloat(t) * dy
        return Double(hypot(p.x - cx, p.y - cy))
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
            .contentShape(Circle().inset(by: -(7 + sceneMapHandleSlop)))
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
        selectedIDs = []
        arrowSelectedID = nil
        furnitureSelectedID = nil
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
            .contentShape(Circle().inset(by: -(6 + sceneMapHandleSlop)))
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
        selectedIDs = []
        wallSelectedID = nil
        arrowSelectedID = nil
        furnitureSelectedID = nil
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

    /// Adds a mannequin (character) marker labeled with the character's name and
    /// tinted with its color.
    private func addCharacterMarker(name: String, colorHex: String) {
        let point = newElementPoint
        var element = MapElement(kind: .character, x: point.x, y: point.y)
        element.label = name
        element.colorHex = colorHex
        doc.elements.append(element)
        selectedIDs = [element.id]
        persist()
    }

    /// Whether a camera for this shot is already on the map. Extra markers made
    /// with Move To/From share the shot's uid too, so this also reports true once
    /// a shot has been moved — which is fine: the dropdown only adds the first.
    private func hasCamera(for shot: Shot) -> Bool {
        doc.elements.contains { $0.kind == .camera && $0.shotUID == shot.uid }
    }

    /// Add a camera linked to a specific shot: its label follows the shot's
    /// number, and it's removed if the shot is deleted. At most one per shot from
    /// here — a second marker for a shot only comes from Move To/From.
    private func addCamera(for shot: Shot) {
        guard !hasCamera(for: shot) else { return }
        let point = newElementPoint
        var element = MapElement(kind: .camera, x: point.x, y: point.y)
        element.label = shot.displayNumber
        element.shotUID = shot.uid
        element.colorHex = "#FF9500"
        doc.elements.append(element)
        selectedIDs = [element.id]
        persist()
    }

    /// Commit a label's nudge once its drag ends.
    private func moveLabel(_ id: UUID, to offset: CGSize) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].labelOffset = offset
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

    /// Other scenes in the project that have a background image to borrow.
    private var scenesWithBackground: [Scene] {
        (scene.project?.scenes ?? [])
            .filter { $0.uid != scene.uid && $0.sceneMapBackgroundData != nil }
            .sorted { ($0.sceneNumber, $0.suffix) < ($1.sceneNumber, $1.suffix) }
    }

    private func sceneBackgroundLabel(_ other: Scene) -> String {
        let nickname = other.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Scene \(other.sceneNumber)\(other.suffix)"
        return nickname.isEmpty ? base : "\(base) – \(nickname)"
    }

    /// Sets a rendered satellite still as the scene-map background (replacing any
    /// image or floor plan), tagging it with the looked-up address. Also seeds the
    /// sun overlay from the captured location — a satellite map is north-up and to
    /// scale, so its coordinate and north (0°) are exactly what the sun needs.
    /// The satellite capture's stored centre, so the picker reopens there.
    private var savedSatelliteCoordinate: CLLocationCoordinate2D? {
        guard scene.sceneMapBackgroundIsSatellite,
              let lat = scene.sceneMapSatelliteLat, let lon = scene.sceneMapSatelliteLon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Whether a new capture covers any of the same ground as the current one —
    /// the test for whether markers should be carried across to it (they belong to
    /// a place) or left where they sit on the map (a different place entirely, where
    /// remapping would push every one of them out of frame).
    private func capturesOverlap(coordinate: CLLocationCoordinate2D, meters: Double) -> Bool {
        guard let anchor = satelliteAnchor else { return false }
        return anchor.overlaps(SatelliteFraming(center: coordinate, meters: meters))
    }

    /// Replaces the satellite background with a new capture (a different zoom
    /// and/or centre) while keeping every marker, arrow, furniture piece and
    /// floor-plan vertex at the same real-world location. Falls back to a plain
    /// set when the old capture's geo-anchor is missing.
    private func rescaleSatelliteBackground(_ data: Data, coordinate: CLLocationCoordinate2D, meters: Double, label: String?) {
        guard let oldLat = scene.sceneMapSatelliteLat,
              let oldLon = scene.sceneMapSatelliteLon,
              let oldMeters = scene.sceneMapSatelliteMeters, oldMeters > 0, meters > 0 else {
            setMapBackground(data, coordinate: coordinate, meters: meters, label: label)
            return
        }
        let old = SatelliteFraming(center: CLLocationCoordinate2D(latitude: oldLat, longitude: oldLon),
                                   meters: oldMeters)
        let new = SatelliteFraming(center: coordinate, meters: meters)
        let ratio = old.sizeRatio(to: new)   // normalized sizes scale by this to keep real size
        func remap(_ x: Double, _ y: Double) -> (Double, Double) {
            let p = old.remap(CGPoint(x: x, y: y), to: new)
            return (Double(p.x), Double(p.y))
        }

        for i in doc.elements.indices { (doc.elements[i].x, doc.elements[i].y) = remap(doc.elements[i].x, doc.elements[i].y) }
        for i in doc.furniture.indices {
            (doc.furniture[i].x, doc.furniture[i].y) = remap(doc.furniture[i].x, doc.furniture[i].y)
            doc.furniture[i].width *= ratio
            doc.furniture[i].height *= ratio
        }
        for i in doc.arrows.indices {
            doc.arrows[i].pivots = doc.arrows[i].pivots.map {
                let (x, y) = remap(Double($0.x), Double($0.y)); return CGPoint(x: x, y: y)
            }
        }
        for i in floorPlan.vertices.indices { (floorPlan.vertices[i].x, floorPlan.vertices[i].y) = remap(floorPlan.vertices[i].x, floorPlan.vertices[i].y) }

        // Swap in the new capture, keeping the (remapped) markers + floor plan.
        scene.sceneMapBackgroundData = data
        scene.sceneMapBackgroundIsSatellite = true
        if let label { scene.sceneMapLocation = label }
        scene.sceneMapSatelliteLat = coordinate.latitude
        scene.sceneMapSatelliteLon = coordinate.longitude
        scene.sceneMapSatelliteMeters = meters
        scene.sceneMapSatelliteCalibrated = true   // rendered by the measuring pipeline
        scene.sceneMapMetersWide = meters
        backgroundImage = PlatformImage(data: data)
        scene.sceneMapJSON = doc.jsonString
        scene.sceneFloorPlanJSON = floorPlan.jsonString
        // Keep the sun anchored to the (possibly re-centred) location.
        sun.latitude = coordinate.latitude
        sun.longitude = coordinate.longitude
        saveSun()
        saveContext()
    }

    private func setMapBackground(_ data: Data, coordinate: CLLocationCoordinate2D, meters: Double, label: String?) {
        isDrawing = false
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        scene.sceneMapBackgroundIsSatellite = true
        scene.sceneMapLocation = label
        scene.sceneMapSatelliteLat = coordinate.latitude
        scene.sceneMapSatelliteLon = coordinate.longitude
        scene.sceneMapSatelliteMeters = meters
        scene.sceneMapSatelliteCalibrated = true   // rendered by the measuring pipeline
        scene.sceneMapMetersWide = meters          // satellite square is `meters` across
        scene.sceneMapCameraSizeMeters = nil       // no camera size → default 0.35 m
        backgroundImage = PlatformImage(data: data)
        try? scene.modelContext?.save()

        // Seed the sun overlay from this location.
        sun.latitude = coordinate.latitude
        sun.longitude = coordinate.longitude
        sun.northOffsetDeg = 0
        if let label { sun.address = label }
        saveSun()
        // Fill the accurate timezone (for sunrise/sunset) in the background.
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) { placemarks, _ in
            if let tz = placemarks?.first?.timeZone {
                sun.timeZoneID = tz.identifier
                saveSun()
            }
        }
    }

    /// Copies another scene's background image (and its location tag) onto this
    /// scene, replacing any current image or drawn floor plan.
    private func setBackgroundFromScene(_ other: Scene) {
        guard let data = other.sceneMapBackgroundData else { return }
        isDrawing = false
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        scene.sceneMapBackgroundIsSatellite = other.sceneMapBackgroundIsSatellite
        scene.sceneMapLocation = other.sceneMapLocation
        scene.sceneMapMetersWide = other.sceneMapMetersWide
        scene.sceneMapCameraSizeMeters = other.sceneMapCameraSizeMeters
        backgroundImage = PlatformImage(data: data)
        try? scene.modelContext?.save()
    }

    /// Sets (replacing any existing) the scene-map background from an image file.
    /// An image and a drawn floor plan are mutually exclusive backgrounds.
    private func setBackground(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) else { return }
        isDrawing = false
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        scene.sceneMapBackgroundIsSatellite = false
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        backgroundImage = image
        try? scene.modelContext?.save()
    }

    /// 3D file types offered by the model picker.
    private var modelContentTypes: [UTType] {
        var types: [UTType] = [.usdz]
        for ext in ["usd", "usdc", "usda", "obj", "dae", "scn", "ply", "stl", "abc"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    /// Renders a top-down, unlit, square image of the picked 3D model and sets it
    /// as the scene-map background (replacing any image or floor plan). Renders off
    /// the main thread so a heavy model doesn't freeze the editor.
    private func setBackgroundFromModel(url: URL) {
        // Copy out of the security scope so the render can run on a background task.
        let accessing = url.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "usdz" : url.pathExtension)
        let copied = (try? FileManager.default.copyItem(at: url, to: temp)) != nil
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard copied else { return }

        isRenderingModel = true
        Task.detached {
            let image = ModelTopDownRenderer.topDownImage(from: temp)
            let data = image?.pngRepresentation()
            try? FileManager.default.removeItem(at: temp)
            await MainActor.run {
                isRenderingModel = false
                guard let image, let data else { return }
                isDrawing = false
                floorPlan = FloorPlan()
                scene.sceneFloorPlanJSON = nil
                scene.sceneMapLocation = nil
                scene.sceneMapBackgroundData = data
                scene.sceneMapBackgroundIsSatellite = false
                scene.sceneMapMetersWide = nil
                scene.sceneMapCameraSizeMeters = nil
                backgroundImage = image
                try? scene.modelContext?.save()
            }
        }
    }

    /// Enters floor-plan drawing mode, clearing any image background (one
    /// background per scene).
    private func startDrawing() {
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.sceneMapBackgroundIsSatellite = false
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        drawTool = .wall
        chainLastVertex = nil
        isDrawing = true
        try? scene.modelContext?.save()
    }

    /// Wipes the whole scene map — markers, arrows, furniture, floor plan and
    /// background — back to empty.
    private func clearAll() {
        isDrawing = false
        chainLastVertex = nil
        pendingMove = nil
        selectedIDs = []; furnitureSelectedID = nil; arrowSelectedID = nil
        wallSelectedID = nil; openingSelectedID = nil
        doc = SceneMapDoc()
        floorPlan = FloorPlan()
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.sceneMapBackgroundIsSatellite = false
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        scene.sceneMapLocation = nil
        persist()
        persistFloorPlan()
    }

    /// Removes the background (image or floor plan). Markers keep their
    /// normalized positions, now relative to the whole canvas.
    private func clearBackground() {
        isDrawing = false
        chainLastVertex = nil
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.sceneMapBackgroundIsSatellite = false
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        try? scene.modelContext?.save()
    }

    private func persistFloorPlan() {
        scene.sceneFloorPlanJSON = floorPlan.jsonString
        saveContext()
    }

    private func persist() {
        scene.sceneMapJSON = doc.jsonString
        saveContext()
    }

    /// Flushes the store. Uses the environment context (never nil, unlike a
    /// detached model's) and logs failures instead of silently dropping them.
    private func saveContext() {
        let context = scene.modelContext ?? modelContext
        do {
            try context.save()
        } catch {
            Log.sceneMap.notice("⚠️ Scene map save failed: \(error)")
        }
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

    /// The arrow's polyline in canvas points: from-marker, its pivots, to-marker.
    private func arrowCanvasPoints(_ arrow: MapArrow, in rect: CGRect) -> [CGPoint]? {
        guard let from = doc.elements.first(where: { $0.id == arrow.fromID }),
              let to = doc.elements.first(where: { $0.id == arrow.toID }) else { return nil }
        var pts = [canvasPoint(from.x, from.y, in: rect)]
        pts += arrow.pivots.map { canvasPoint($0.x, $0.y, in: rect) }
        pts.append(canvasPoint(to.x, to.y, in: rect))
        return pts
    }

    private func drawArrows(_ baseCtx: GraphicsContext, in rect: CGRect, canvas: CGSize) {
        // This Canvas sits outside the map's scaleEffect, so replicate the map's
        // scaleEffect(zoom, anchor: .center) + offset(pan) on the context. Drawing in
        // logical (rect) coordinates then rasterizes crisply at the on-screen scale.
        var ctx = baseCtx
        ctx.translateBy(x: canvas.width / 2 * (1 - zoom) + pan.width,
                        y: canvas.height / 2 * (1 - zoom) + pan.height)
        ctx.scaleBy(x: zoom, y: zoom)
        // Counter-scale the shaft width and arrowhead so they don't balloon with the
        // map zoom — the path (endpoints, and the trim that clears the markers) still
        // scales, but the body thins and the head shrinks as you zoom in. `pow(…, 0.7)`
        // makes this a bit gentler than a full 1/zoom counter-scale. (Widths are in
        // pre-scale units; the ctx scale multiplies them back up.)
        let vs = 1 / pow(max(zoom, 1), 0.7)
        let lineWidth: CGFloat = 6 * vs
        for arrow in doc.arrows {
            guard var pts = arrowCanvasPoints(arrow, in: rect), pts.count >= 2,
                  let from = doc.elements.first(where: { $0.id == arrow.fromID }) else { continue }
            let shading = GraphicsContext.Shading.color(Color(hex: from.colorHex))
            // Trim the first/last segment so the shaft clears the marker icons.
            let n = pts.count
            let ds = unit(CGPoint(x: pts[1].x - pts[0].x, y: pts[1].y - pts[0].y))
            pts[0] = CGPoint(x: pts[0].x + ds.x * 20, y: pts[0].y + ds.y * 20)
            let de = unit(CGPoint(x: pts[n - 1].x - pts[n - 2].x, y: pts[n - 1].y - pts[n - 2].y))
            pts[n - 1] = CGPoint(x: pts[n - 1].x - de.x * 22, y: pts[n - 1].y - de.y * 22)

            // Solid triangular head; the shaft attaches to its base (not the tip).
            let tip = pts[n - 1]
            let headLength: CGFloat = 20 * vs
            let headHalfWidth: CGFloat = 11 * vs
            let baseCenter = CGPoint(x: tip.x - de.x * headLength, y: tip.y - de.y * headLength)
            var shaftPts = pts
            shaftPts[n - 1] = baseCenter
            ctx.stroke(smoothPolyline(shaftPts), with: shading,
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            let perp = CGPoint(x: -de.y, y: de.x)
            var head = Path()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: baseCenter.x + perp.x * headHalfWidth, y: baseCenter.y + perp.y * headHalfWidth))
            head.addLine(to: CGPoint(x: baseCenter.x - perp.x * headHalfWidth, y: baseCenter.y - perp.y * headHalfWidth))
            head.closeSubpath()
            ctx.fill(head, with: shading)
        }
    }

    /// Draws a field-of-view wedge — two rays — from every shot-linked camera
    /// whose shot has a focal length. Purely visual; toggled per-scene from a
    /// camera's right-click menu. Cameras without a focal length draw nothing.
    private func drawCameraFOV(_ ctx: GraphicsContext, in rect: CGRect) {
        // The horizontal angle of view from the shot's focal length + sensor width:
        //   halfAngle = atan((sensorWidth / 2) / focal).
        // Each camera's sensor width comes from its own FOV basis: a fixed format
        // (S16/S35/LF), or its shot's CineStager sensor (Super-35 fallback).
        // Long enough to cross the map from any interior point; clipped to `rect`.
        let reach = hypot(rect.width, rect.height) * 2
        var ctx = ctx
        ctx.clip(to: Path(rect))
        for element in doc.elements where element.kind == .camera {
            guard let uid = element.shotUID,
                  let shot = scene.shots.first(where: { $0.uid == uid }),
                  shot.lensfocal > 0 else { continue }
            let halfAngle = atan((sensorWidthMM(for: element, shot: shot) / 2) / Double(shot.lensfocal))
            let cx = rect.minX + element.x * rect.width
            let cy = rect.minY + element.y * rect.height
            // Facing unit vector matches the marker's rotation handle: (sin, -cos).
            let r = element.rotation * .pi / 180
            let facing = atan2(-cos(r), sin(r))
            let shading = GraphicsContext.Shading.color(Color(hex: element.colorHex).opacity(0.85))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4])
            for side in [-halfAngle, halfAngle] {
                let a = facing + side
                var path = Path()
                path.move(to: CGPoint(x: cx, y: cy))
                path.addLine(to: CGPoint(x: cx + reach * cos(a), y: cy + reach * sin(a)))
                ctx.stroke(path, with: shading, style: style)
            }
        }
    }

    /// Flips the per-scene camera FOV overlay. Scene-wide by design: it applies to
    /// every camera marker in the scene, and to any added later (and hides them
    /// all the same way).
    private func toggleCameraFOV() {
        scene.sceneMapShowCameraFOV.toggle()
        saveContext()
    }

    /// Switches camera + mannequin markers between real-world scale and a fixed,
    /// easy-to-see size (see `sceneMarkerScale`).
    private func toggleViewableMarkerSize() {
        scene.sceneMapViewableMarkerSize.toggle()
        saveContext()
    }

    /// Whether the viewable-size toggle is worth showing: only when a marker would
    /// actually render smaller than default. If both the camera and mannequin are
    /// already ≥ default size at the current scale, the toggle would do nothing, so
    /// it's hidden.
    private var viewableSizeToggleRelevant: Bool {
        guard let metersWide = mapMetersWide, metersWide > 0, mapContentWidth > 0 else { return false }
        let camera = realisticMarkerScale(kind: .camera, metersWide: metersWide,
                                          cameraMeters: mapCameraMeters, mapWidthPoints: mapContentWidth)
        let mannequin = realisticMarkerScale(kind: .character, metersWide: metersWide,
                                             cameraMeters: mapCameraMeters, mapWidthPoints: mapContentWidth)
        return camera < 1 || mannequin < 1
    }

    /// Sets one camera marker's FOV sensor basis (S16 / S35 / LF / its CineStager
    /// camera). Per-camera — only the given marker changes.
    private func setFOVBasis(_ basis: FOVBasis, for element: MapElement) {
        guard let index = doc.elements.firstIndex(where: { $0.id == element.id }) else { return }
        doc.elements[index].fovBasis = basis
        persist()
    }

    /// A camera marker's effective FOV basis: its explicit choice, or the auto
    /// default — the CineStager camera when the shot has an imported sensor, else
    /// Super-35. Drives the checkmark in the "FOV Settings" menu.
    private func effectiveBasis(for element: MapElement) -> FOVBasis {
        if let basis = element.fovBasis { return basis }
        return cineStagerCameraName(for: element) != nil ? .cineStager : .super35
    }

    /// The sensor width (mm) a camera's FOV wedge is drawn from, resolving its
    /// basis: a fixed format, or the shot's CineStager sensor with a Super-35
    /// fallback.
    private func sensorWidthMM(for element: MapElement, shot: Shot) -> Double {
        if let fixed = effectiveBasis(for: element).fixedSensorWidthMM { return fixed }
        return (shot.sensorWidthMM ?? 0) > 0 ? shot.sensorWidthMM! : 24.89
    }

    /// The CineStager camera name for a camera marker (used to resolve the auto
    /// basis), or nil when that shot has no imported sensor.
    private func cineStagerCameraName(for element: MapElement) -> String? {
        guard let uid = element.shotUID,
              let shot = scene.shots.first(where: { $0.uid == uid }),
              (shot.sensorWidthMM ?? 0) > 0 else { return nil }
        let name = shot.camera.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "CineStager Camera" : name
    }

    /// Every distinct CineStager camera profile imported anywhere in the project
    /// — a (combined camera, sensor width) any camera marker's FOV can be based on.
    private var cineStagerProfiles: [CineStagerProfile] {
        guard let project = scene.project else { return [] }
        var seen = Set<String>()
        var result: [CineStagerProfile] = []
        for scn in project.scenes {
            for s in scn.shots {
                guard let sensor = s.sensorWidthMM, sensor > 0, !s.camera.isEmpty else { continue }
                let profile = CineStagerProfile(camera: s.camera, sensorWidthMM: sensor)
                if seen.insert(profile.id).inserted { result.append(profile) }
            }
        }
        return result
    }

    /// The profile rows for the FOV menu: (id, display label) — the combined
    /// camera value, which already carries its format.
    private var fovProfileRows: [(id: String, label: String)] {
        cineStagerProfiles
            .map { (id: $0.id, label: $0.camera) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Which profile row is checked for a camera marker: the one matching its
    /// shot's camera, when the marker is on the CineStager basis.
    private func selectedFOVProfileID(for element: MapElement) -> String? {
        guard effectiveBasis(for: element) == .cineStager,
              let uid = element.shotUID,
              let shot = scene.shots.first(where: { $0.uid == uid }) else { return nil }
        return shot.camera
    }

    /// Picks a project CineStager profile as a camera marker's FOV basis, and
    /// fills the linked shot's camera + sensor to match — so the shot editor shows
    /// the same camera the FOV is drawn from.
    private func selectFOVProfile(_ id: String, for element: MapElement) {
        guard let profile = cineStagerProfiles.first(where: { $0.id == id }),
              let index = doc.elements.firstIndex(where: { $0.id == element.id }) else { return }
        doc.elements[index].fovBasis = .cineStager   // draw from the shot's own sensor…
        if let uid = element.shotUID, let shot = scene.shots.first(where: { $0.uid == uid }) {
            shot.camera = profile.camera              // …which we set to match the profile.
            shot.sensorWidthMM = profile.sensorWidthMM
        }
        persist()
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
        // If the whole map was just cleared from under us (e.g. "Clear Scene"),
        // don't resurrect the stale in-memory doc — reset it to match.
        if scene.sceneMapJSON == nil {
            if !doc.isEmpty { doc = SceneMapDoc(); selectedIDs = [] }
            return
        }
        let shotUIDs = Set(scene.shots.map(\.uid))
        let before = doc.elements.count
        doc.elements.removeAll { element in
            guard let uid = element.shotUID else { return false }
            return !shotUIDs.contains(uid)
        }
        guard doc.elements.count != before else { return }
        let ids = Set(doc.elements.map(\.id))
        doc.arrows.removeAll { !ids.contains($0.fromID) || !ids.contains($0.toID) }
        selectedIDs = selectedIDs.filter { id in doc.elements.contains { $0.id == id } }
        persist()
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

private struct SegmentedGroup: ViewModifier {
    var height: CGFloat = 34
    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
    }
}

let sceneMapPalette: [(name: String, hex: String)] = [
    ("Blue", "#4C8DFF"), ("Orange", "#FF9500"), ("Green", "#34C759"),
    ("Red", "#FF3B30"), ("Purple", "#AF52DE"), ("Yellow", "#FFCC00"),
    ("Gray", "#8E8E93"), ("Brown", "#A2845E"), ("White", "#FFFFFF")
]

/// Compass-style angle (0° = up, clockwise positive) from `center` to `point`.
func sceneMapAngle(from center: CGPoint, to point: CGPoint) -> Double {
    let dx = point.x - center.x, dy = point.y - center.y
    var deg = atan2(dx, -dy) * 180 / .pi
    if deg < 0 { deg += 360 }
    return deg
}

// MARK: - Furniture

/// A movable, rotatable, resizable furniture piece on the map.
/// Small popover shown when a camera marker is left-clicked: the linked shot's
/// reference image plus its basic info.
private struct CameraShotPopover: View {
    let shot: Shot
    /// iPhone: a narrower card with a smaller still, so it fits the screen.
    var compact: Bool = false

    private var cardWidth: CGFloat { compact ? 190 : 264 }
    private var imageSize: CGSize { compact ? CGSize(width: 166, height: 93) : CGSize(width: 240, height: 135) }

    private var referenceImage: PlatformImage? {
        shot.references.sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { $0.imageData }.first.flatMap(PlatformImage.init(data:))
    }
    private var sizeText: String? {
        guard shot.hasSize else { return nil }
        return shot.hasSecondSize ? "\(shot.sizeShort) → \(shot.secondSizeShort)" : shot.sizeShort
    }
    private var typeText: String? {
        guard shot.hasType else { return nil }
        var t = shot.typeShort
        if shot.hasSecondType { t += " + \(shot.secondTypeShort)" }
        if shot.hasThirdType { t += " + \(shot.thirdTypeShort)" }
        return t
    }
    private var gripText: String? { shot.hasGrip ? shot.gripName : nil }
    private var focalText: String? {
        guard shot.lensfocal > 0 else { return nil }
        if !shot.lensIsPrime, shot.lensfocalEnd > 0, shot.lensfocalEnd != shot.lensfocal {
            return "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"
        }
        return "\(shot.lensfocal)mm"
    }
    private var extraText: String? {
        let t = shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(nickname.isEmpty ? "Shot \(shot.displayNumber)" : "Shot \(shot.displayNumber) – \(nickname)")
                .font(.headline)
                .lineLimit(1)
            if let image = referenceImage {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: imageSize.width, height: imageSize.height)
                    .overlay(Image(systemName: "photo").font(.title2).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 3) {
                infoRow("Size", sizeText)
                infoRow("Type", typeText)
                infoRow("Grip", gripText)
                infoRow("Focal Length", focalText)
                infoRow("Extra Info", extraText)
            }
        }
        .padding(12)
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack(alignment: .top, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Text(value).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}


/// A smooth Catmull-Rom curve through the given points (used for movement
/// arrows so their bends at pivots are rounded, not sharp).
func smoothPolyline(_ pts: [CGPoint]) -> Path {
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
struct ArrowHitShape: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else { return Path() }
        return smoothPolyline(points).strokedPath(StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round))
    }
}

