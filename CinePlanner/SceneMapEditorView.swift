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
import CoreData

struct SceneMapEditorView: View {
    static let canvasSpace = "sceneMapCanvas"
    /// Coordinate space *inside* the map group — before its placement scale/rotation/
    /// offset. Marker and furniture drags read this so a gesture's location matches the
    /// piece's (pre-placement) `center`, which keeps grabbing/dragging correct on a
    /// map the placement has scaled down (e.g. a CineStager import fitted to markers
    /// that sit outside the room). `canvasSpace`, being outside the group, includes the
    /// placement scale and would mismatch `center` on such a map.
    static let canvasContentSpace = "sceneMapContent"
    /// The untransformed canvas (pane) space, defined on the canvas root — outside every
    /// zoom/placement transform. The marquee gesture measures here so a scaled map (the
    /// gesture sits inside the placement scaleEffect, which skews `.global`) can't throw
    /// the rubber-band box off; the box is drawn in this same space.
    static let canvasScreenSpace = "sceneMapScreen"
    /// Opacity of a layer hidden from the toolbar: its markers (and their arrows / FOV
    /// wedges) stay as a faint, non-interactive ghost for reference.
    static let hiddenLayerOpacity: Double = 0.35

    let scene: Scene
    /// When embedded in a pane (vs. presented as a sheet), drop the title bar,
    /// the Done button, and the fixed minimum size.
    var embedded: Bool = false
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    #if os(iOS)
    @Environment(\.verticalSizeClass) var verticalSizeClass
    #endif

    /// iPhone in portrait — where the sun time bar needs the slider on its own row.
    var isPhonePortrait: Bool {
        #if os(iOS)
        return DeviceLayout.isPhone && verticalSizeClass == .regular
        #else
        return false
        #endif
    }

    enum DrawTool: String, CaseIterable { case wall = "Wall"; case door = "Door"; case window = "Window" }
    enum MoveDirection { case to, from }

    @State var doc: SceneMapDoc
    /// Selected camera/mannequin markers. Usually one, but a marquee drag over the
    /// canvas can select several to move or delete together.
    @State var selectedIDs: Set<UUID> = []
    /// Marquee (rubber-band) selection box corners in canvas points while dragging
    /// over empty canvas; nil when not marqueeing.
    @State var marqueeStart: CGPoint?
    @State var marqueeCurrent: CGPoint?
    /// Live translation (canvas points) while dragging a multi-selection as a
    /// group; nil when no group drag is in progress.
    @State var groupDragTranslation: CGSize?
    /// Camera marker whose shot-info popover is open (left-click a camera).
    @State var cameraInfoElementID: UUID?
    @State var showManageCharacters = false
    @State var sun = SunSettings()
    @State var showSunSettings = false
    /// Mirror of the scene's background scale, refreshed on every background change
    /// so markers re-scale immediately when the measured background swaps.
    @State var mapMetersWide: Double?
    @State var mapCameraMeters: Double?
    /// The map content rect's current width (points), mirrored from the canvas so
    /// the toolbar can tell whether markers would render smaller than default.
    @State var mapContentWidth: CGFloat = 0
    /// Pinch-to-zoom of the map canvas. `zoom` is the live scale (1 = fit), `lastZoom`
    /// holds it between pinches; `pan` offsets the zoomed content, `lastPan` its
    /// committed value. The coordinate space stays logical (unscaled) so every marker
    /// gesture keeps working — only the rendering is scaled.
    ///
    /// On a satellite background these double as the reframe gesture: zooming out
    /// past 1× and panning past the image edge are allowed, a sharp satellite render
    /// of the new framing is fetched behind the markers, and the pill offers to make
    /// it the scene's background (see `commitReframe`).
    @State var zoom: CGFloat = 1
    @State var lastZoom: CGFloat = 1
    @State var pan: CGSize = .zero
    @State var lastPan: CGSize = .zero
    /// Sharp satellite render of the area the canvas currently frames, fetched while
    /// reframing so the map doesn't just magnify the stored capture's pixels. Drawn
    /// under the markers, positioned by `reframePreviewRect` — the world rect it was
    /// rendered for — so it stays glued to the ground as the pan continues.
    /// True while the reframe tool is on. Panning and zooming only move the
    /// satellite background in this mode — otherwise they are the plain look-closer
    /// gestures they have always been, so nobody re-frames their map by accident.
    @State var isReframeMode = false
    /// Which compass direction points up while reframing — absolute, not a turn from
    /// where the map already sits, so the control opens showing where the map points
    /// and agrees with the same control in the location picker. Seeded from the
    /// capture when the tool is picked up.
    @State var reframeHeading: Double = 0
    @State var reframePreview: PlatformImage?
    @State var reframePreviewArea: SatelliteFraming?
    @State var reframeTask: Task<Void, Never>?
    @State var isCommittingReframe = false
    /// Shared width for every icon cell in the scene-map toolbar, so the add-menu
    /// segments match the trash / sun buttons. Shrinks in iPhone landscape to give
    /// the map more room.
    var toolbarCellWidth: CGFloat { isPhoneLandscape ? 30 : 40 }
    /// Toolbar icon point size — smaller in iPhone landscape.
    var toolbarIconSize: CGFloat { isPhoneLandscape ? 13 : 16 }
    /// Toolbar pill height — shorter in iPhone landscape.
    var toolbarPillHeight: CGFloat { isPhoneLandscape ? 26 : 34 }
    /// iPhone: the toolbar scrolls horizontally instead of centering with edge
    /// overlays, which would overlap on a narrow screen.
    var isPhone: Bool { DeviceLayout.isPhone }
    /// iPhone in landscape — the scene-map toolbar shrinks and centers so the map
    /// itself gets the most space.
    var isPhoneLandscape: Bool {
        #if os(iOS)
        return DeviceLayout.isPhone && verticalSizeClass == .compact
        #else
        return false
        #endif
    }
    @State var furnitureToLabel: UUID?
    @State var furnitureLabelText = ""
    @State var markerToLabel: UUID?
    @State var markerLabelText = ""
    /// The text annotation being edited in the alert, and its working string.
    @State var textToEdit: UUID?
    @State var textEditString = ""
    /// The last hovered point on the map, in the untransformed canvas-root space
    /// (`canvasScreenSpace`), used to place a right-click "Add Text" where the pointer is.
    @State var lastMapHoverScreen: CGPoint?
    /// Touch: where the current finger went down on empty map (root space), so a long
    /// press can drop a text note right there (touch has no hover to track).
    @State var touchDownScreen: CGPoint?
    /// Live (normalized) spots of markers being dragged that have arrows attached, so
    /// those arrows follow the drag. Empty when nothing's being dragged.
    @State var liveMarkerPositions: [UUID: CGPoint] = [:]
    @State var backgroundImage: PlatformImage?
    /// Which kind of file the single background importer is currently offering.
    /// Two separate `.fileImporter` modifiers on one view collide in SwiftUI —
    /// only the last presents — so both the image and the 3D-model pickers are
    /// driven through one importer keyed on this.
    enum BackgroundImportKind { case image, model }
    @State var backgroundImportKind: BackgroundImportKind?
    /// Live placement of a non-satellite background image under the markers. Edited
    /// by the align tool, mirrored to the scene on gesture end. The editor renders
    /// from this so drags update at once without hitting SwiftData every frame.
    @State var bgTransform = SceneMapBackgroundTransform()
    /// True while the align-background tool is up.
    @State var isBackgroundAdjustMode = false
    /// The placement offset captured at the start of a move drag, the base the live
    /// drag translation is applied to.
    @State var bgAdjustStartOffset: CGSize = .zero
    /// The satellite location picker. Framing an already-set map is done on the
    /// canvas, so this is only for choosing where in the world the map is.
    @State var showingMapPicker = false
    @State var isRenderingModel = false
    @State var showingClearAllConfirm = false
    @State var floorPlan: FloorPlan
    @State var isDrawing = false
    /// nil = no tool chosen yet (after EDIT the user must pick Wall/Door/Window first).
    @State var drawTool: DrawTool?
    /// The last vertex of the wall chain being drawn (the next click extends
    /// from here). nil = the next click starts a fresh chain.
    @State var chainLastVertex: UUID?
    /// Cursor position (canvas points) for the rubber-band preview while drawing.
    @State var drawHover: CGPoint?
    /// Drawing to real-world scale: after the first wall the user enters its length,
    /// which sets the map's metres-wide so every later wall, marker and furniture
    /// piece is correctly scaled and shown with live measurements.
    @State var drawToScale = false
    /// The first wall awaiting its real length (drives the length prompt). nil once
    /// the map is calibrated (or when not drawing to scale).
    @State var scaleWallID: UUID?
    /// Length entry for the calibration wall, in metres (decimal).
    @State var scaleInput = ""
    /// Wall whose measurement label is being dragged, with its offset at drag start.
    @State var wallLabelDrag: (id: UUID, base: CGSize)?
    /// Door/window selected for editing.
    @State var openingSelectedID: UUID?
    /// Window currently being resized by dragging a handle — drives a temporary
    /// width label beside it while the drag is in progress.
    @State var resizingOpeningID: UUID?
    /// While drawing: the corner point a gesture is on, and whether it has moved far
    /// enough to count as a drag (move the corner) rather than a tap (start/end a wall).
    @State var vertexDragID: UUID?
    @State var vertexDragMoved = false
    /// An in-progress "move to/from": the next canvas click places the second
    /// marker and connects it to `origin` with an arrow.
    @State var pendingMove: (origin: UUID, direction: MoveDirection)?
    /// Last cursor position over an arrow, so "Add Pivot Point" lands where you
    /// right-clicked.
    @State var arrowHover: CGPoint = .zero
    /// Wall selected for editing (reveals all vertex handles).
    @State var wallSelectedID: UUID?
    /// Arrow selected for editing (reveals its pivot handles).
    @State var arrowSelectedID: UUID?
    /// Furniture selected for editing (reveals rotate/resize handles).
    @State var furnitureSelectedID: UUID?
    /// Furniture picked out by a marquee drag (multi-selection), alongside the single
    /// `furnitureSelectedID`. Members move and delete together with any selected markers.
    @State var furnitureSelectedIDs: Set<UUID> = []
    /// The furniture currently in resize mode (armed via the context menu). Lights are
    /// move-only until armed; cleared when the selection changes.
    @State var furnitureResizeID: UUID?
    /// Touch (iPhone/iPad): once a single marker/furniture is selected, a drag
    /// anywhere on the map moves it. These hold the drag target and its start spot.
    @State var anywhereMoveTarget: MoveTarget?
    @State var anywhereMoveBase: CGPoint?
    /// Truss add: prompts for a length in metres on a measured map.
    @State var trussPrompt = false
    @State var trussInput = ""
    /// "Set True Scale" (image maps): tap two points, then enter their real distance.
    @State var scaleMeasureActive = false
    @State var scaleMeasurePoints: [CGPoint] = []   // normalized
    @State var scaleMeasurePrompt = false
    @State var scaleMeasureInput = ""
    /// A wall's endpoint positions captured at the start of a move drag.
    @State var wallDragOrigin: (id: UUID, a: CGPoint, b: CGPoint)?

    // Undo / redo of map edits (see "Undo" below).
    @State var history = EditHistory<MapHistoryState>() {
        didSet {
            undoCommands.canUndo = history.canUndo
            undoCommands.canRedo = history.canRedo
        }
    }
    /// One stable object for the menu bar's Undo / Redo (see AppCommands).
    @State var undoCommands = MapUndoCommands()
    /// The map as last committed (persisted) — what the next edit is undone back to.
    @State var committedState: MapHistoryState?
    /// Set while a change isn't the user's own edit (maintenance), so it isn't undoable.
    @State var suppressHistory = false

    init(scene: Scene, embedded: Bool = false) {
        self.scene = scene
        self.embedded = embedded
        _doc = State(initialValue: SceneMapDoc.load(from: scene.sceneMapJSON))
        _backgroundImage = State(initialValue: scene.sceneMapBackgroundData.flatMap(PlatformImage.init(data:)))
        _floorPlan = State(initialValue: FloorPlan.load(from: scene.sceneFloorPlanJSON))
        _bgTransform = State(initialValue: scene.sceneMapBackgroundTransform)
    }

    var sceneTitle: String {
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
        // Start from what's actually in the store: the UI context's copy of the scene
        // isn't refreshed when iCloud imports, so it can be older than the store.
        .onAppear {
            sun = scene.sunSettings; reloadFromStoreIfNewer(); syncShotLabels(); pruneOrphanedShotCameras()
            calibrateSatelliteCapture(); refreshMapScale(); resetHistory()
            undoCommands.undo = undoMap
            undoCommands.redo = redoMap
        }
        // ⌘Z / ⇧⌘Z (Edit menu) walk the map's own history while it's on screen.
        .focusedSceneValue(\.mapUndoCommands, undoCommands)
        // Pick up another device's edits live: after each iCloud import, re-read this
        // scene from the store and show a newer map / floor plan.
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            reloadFromStoreIfNewer()
        }
        // Reading the sync generation re-runs this body once SyncRefresher has
        // refreshed the scene, so settings read straight off it (camera FOV, marker
        // size) redraw and the `onChange(of: scene.…)` watchers below see the
        // imported values (background image, sun settings).
        .onChange(of: SyncRefresher.shared.generation) { _, _ in reloadFromStoreIfNewer() }
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
                if !doc.isEmpty { doc = SceneMapDoc(); selectedIDs = []; furnitureSelectedIDs = [] }
                return
            }
            let incoming = SceneMapDoc.load(from: newValue)
            // An empty map that lists removals is a clear, not a stale value.
            guard incoming != doc, !(incoming.isEmpty && !doc.isEmpty && incoming.removed.isEmpty) else { return }
            doc = incoming
            selectedIDs = selectedIDs.filter { id in doc.elements.contains { $0.id == id } }
            furnitureSelectedIDs = furnitureSelectedIDs.filter { id in doc.furniture.contains { $0.id == id } }
            resetHistory()   // changed from outside: not an undoable edit of ours
        }
        .onChange(of: scene.sceneMapBackgroundData) { _, newValue in
            backgroundImage = newValue.flatMap(PlatformImage.init(data:))
            // A new or replaced background — set here or arrived by sync — carries
            // its own placement (identity for a fresh image). Close the align tool
            // if the image it was aligning is gone.
            bgTransform = scene.sceneMapBackgroundTransform
            if newValue == nil || scene.sceneMapBackgroundIsSatellite { isBackgroundAdjustMode = false }
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
            resetHistory()
        }
        // Pick up sun settings changed from outside the editor — e.g. scheduling the
        // scene on a dated day carries that date into the sun seeker. Round-trip
        // equality means our own `saveSun` writes don't reload (and clobber) an edit.
        .onChange(of: scene.sunSettingsJSON) { _, _ in
            let incoming = scene.sunSettings
            guard incoming != sun else { return }
            sun = incoming
        }
        .fileImporter(
            isPresented: Binding(
                get: { backgroundImportKind != nil },
                set: { if !$0 { backgroundImportKind = nil } }
            ),
            allowedContentTypes: backgroundImportKind == .model ? modelContentTypes : [.image]
        ) { result in
            let kind = backgroundImportKind
            backgroundImportKind = nil
            if case .success(let url) = result {
                switch kind {
                case .model: setBackgroundFromModel(url: url)
                default: setBackground(from: url)
                }
            }
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
        .alert("Truss Length", isPresented: $trussPrompt) {
            TextField("Length in metres", text: $trussInput)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Button("Add") { addTrussFromPrompt() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("How many metres long is the truss?")
        }
        .alert("True Scale", isPresented: $scaleMeasurePrompt) {
            TextField("Distance in metres", text: $scaleMeasureInput)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Button("Set Scale") { applyTrueScaleFromPrompt() }
            Button("Cancel", role: .cancel) { cancelScaleMeasure() }
        } message: {
            Text("How far apart are the two points, in metres?")
        }
        .sheet(isPresented: $showManageCharacters) {
            if let project = scene.project {
                ManageCharactersSheet(project: project)
            }
        }
        .sheet(isPresented: Binding(get: { scaleWallID != nil },
                                    set: { if !$0 { scaleWallID = nil } })) {
            scaleLengthSheet
        }
        .sheet(isPresented: $showSunSettings) {
            SunSettingsSheet(settings: $sun, onChange: saveSun,
                             lockedNorthOffset: satelliteAnchor.map { -$0.heading })
        }
        .sheet(isPresented: $showingMapPicker) {
            MapBackgroundSheet(initialCoordinate: savedSatelliteCoordinate,
                               initialMeters: scene.sceneMapBackgroundIsSatellite ? scene.sceneMapSatelliteMeters : nil,
                               initialHeading: satelliteAnchor?.heading ?? 0,
                               existingCapture: satelliteAnchor,
                               markerCount: doc.elements.count) { data, framing, label in
                // Nudging the same location keeps every marker on its real-world
                // spot; jumping somewhere else entirely is a fresh start, where
                // carrying the markers along would only fling them off the map.
                if satelliteAnchor?.overlaps(framing) == true {
                    rescaleSatelliteBackground(data, framing: framing, label: label)
                } else {
                    setMapBackground(data, framing: framing, label: label)
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
        .alert("Text", isPresented: Binding(
            get: { textToEdit != nil },
            set: { if !$0 { endTextEdit() } }
        )) {
            TextField("Text", text: $textEditString)
            Button("Save") { commitTextEdit() }
            Button("Cancel", role: .cancel) { endTextEdit() }
        } message: {
            Text("A free text note placed on the map.")
        }
        .onDisappear { persist(); persistFloorPlan() }
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
