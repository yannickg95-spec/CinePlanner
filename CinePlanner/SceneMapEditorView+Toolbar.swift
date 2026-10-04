//
//  SceneMapEditorView+Toolbar.swift
//  CinePlanner
//
//  The scene map editor's header and toolbar: tools, layer toggles, menus, and the
//  iPhone corner buttons.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Header & toolbar

    var header: some View {
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

    var sceneShots: [Shot] {
        scene.shots.sorted { $0.shotNumber < $1.shotNumber }
    }

    /// Add-camera menu label: shot number, then its nickname and size when set —
    /// e.g. "Shot 4 – Kitchen wide · MS".
    func cameraMenuLabel(for shot: Shot) -> String {
        var text = "Shot \(shot.displayNumber)"
        let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty { text += " – \(nickname)" }
        if shot.hasSize { text += " · \(shot.sizeShort)" }
        return text
    }

    @ViewBuilder
    var toolbar: some View {
        if isPhone { compactToolbar } else { regularToolbar }
    }

    /// iPad + Mac: the add menus centered, with the trash and sun/size pills
    /// floating at the edges (unchanged from the original layout).
    var regularToolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            addSegmentedGroup
            Spacer()
        }
        .overlay(alignment: .leading) {
            HStack(spacing: 10) { trashButton; undoRedoGroup }.padding(.leading, 16)
        }
        .overlay(alignment: .trailing) { sizeSunGroup.padding(.trailing, 16) }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// iPhone: every group in one horizontally scrollable row so nothing overlaps.
    /// In landscape the groups are smaller and fit centered without scrolling, and
    /// the row is pulled tight to the top so the map gets the most height.
    var compactToolbar: some View {
        Group {
            // On iPhone the clear-map and undo/redo buttons move to the map's
            // top-left corner (opposite ADJUST), so they never crowd this row — see
            // `clearMapCornerButton`.
            if isPhoneLandscape {
                HStack(spacing: 10) {
                    addSegmentedGroup
                    sizeSunGroup
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            } else {
                // Centre the row when it fits; only scroll when it genuinely overflows.
                // A GeometryReader gives the available width, and `minWidth` on the
                // content makes it at least that wide (so it centres) while still able
                // to grow and scroll past it.
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            addSegmentedGroup
                            sizeSunGroup
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minWidth: geo.size.width, alignment: .center)
                    }
                }
                .frame(height: toolbarPillHeight + 20)
            }
        }
    }

    /// The four "add to the map" menus as one segmented control.
    var addSegmentedGroup: some View {
            // One segmented bar for the four "add to the map" menus, so they read
            // as a single control.
            HStack(spacing: 0) {
                Menu {
                    layerVisibilityToggle(doc.showCharacters, "Characters") { doc.showCharacters = $0 }
                    Divider()
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
                    layerVisibilityToggle(doc.showCameras, "Cameras") { doc.showCameras = $0 }
                    Divider()
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
                    layerVisibilityToggle(doc.showBackground, "Background") { doc.showBackground = $0 }
                    Divider()
                    Button { backgroundImportKind = .image } label: { Label("Image…", systemImage: "photo") }
                    // One item: the picker is for choosing a *place*. Adjusting the
                    // framing of a map that's already set happens on the canvas
                    // itself — pan and zoom, then keep it.
                    Button { showingMapPicker = true } label: {
                        Label("Satellite Map…", systemImage: "globe.europe.africa.fill")
                    }
                    Button { backgroundImportKind = .model } label: { Label("3D Model…", systemImage: "cube") }
                    Menu {
                        let others = scenesWithMap
                        if others.isEmpty {
                            Text("No other scene has a map")
                        } else {
                            ForEach(others, id: \.uid) { other in
                                Button {
                                    setBackgroundFromScene(other)
                                } label: {
                                    Label(sceneBackgroundLabel(other), systemImage: sceneMapSymbol(other))
                                }
                            }
                        }
                    } label: { Label("From Another Scene…", systemImage: "square.on.square") }
                    Divider()
                    if floorPlan.isEmpty {
                        Menu {
                            Button { startDrawing(toScale: true) } label: {
                                Label("To Scale…", systemImage: "ruler")
                            }
                            Button { startDrawing() } label: {
                                Label("Freehand", systemImage: "scribble")
                            }
                        } label: { Label("Draw Floor Plan", systemImage: "pencil.and.ruler") }
                    }
                    // When a plan already exists, editing/redrawing it lives on the
                    // map's own EDIT button rather than in this menu.
                    if backgroundImage != nil || !floorPlan.isEmpty {
                        Divider()
                        Button(role: .destructive) { clearBackground() } label: { Label("Clear Background", systemImage: "xmark") }
                    }
                } label: { addMenuLabel("map.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Background")

                segmentDivider
                Menu {
                    layerVisibilityToggle(doc.showFurniture, "Furniture") { doc.showFurniture = $0 }
                    Divider()
                    ForEach(Furniture.Kind.allCases.filter { !$0.isLight }, id: \.self) { kind in
                        Button(kind.rawValue) { addFurniture(kind) }
                    }
                } label: { addMenuLabel("chair.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Furniture")

                segmentDivider
                Menu {
                    layerVisibilityToggle(doc.showLights, "Lights") { doc.showLights = $0 }
                    Divider()
                    Menu("HMI") {
                        Button("Small HMI") { addFurniture(.smallHMI) }
                        Button("Medium HMI") { addFurniture(.mediumHMI) }
                        Button("Big HMI") { addFurniture(.bigHMI) }
                    }
                    Menu("Tungsten") {
                        Button("Small Tungsten") { addFurniture(.smallTungsten) }
                        Button("Medium Tungsten") { addFurniture(.mediumTungsten) }
                        Button("Big Tungsten") { addFurniture(.bigTungsten) }
                    }
                    Menu("LED COB") {
                        ForEach(Furniture.Kind.allCases.filter { $0.isCOB }, id: \.self) { kind in
                            Button(kind.rawValue) { addFurniture(kind) }
                        }
                    }
                    Menu("Tube") {
                        Button("Long Tube") { addFurniture(.tube) }
                        Button("Short Tube") { addFurniture(.shortTube) }
                    }
                    Menu("Light Panel") {
                        Button(Furniture.Kind.lightPanel.displayName) { addFurniture(.lightPanel) }
                        Button(Furniture.Kind.panel1x1.displayName) { addFurniture(.panel1x1) }
                    }
                    Menu("Softbox") {
                        Button(Furniture.Kind.softbox.displayName) { addFurniture(.softbox) }
                        Button("Medium Softbox") { addFurniture(.mediumSoftbox) }
                        Button("Big Softbox") { addFurniture(.bigSoftbox) }
                    }
                    Menu("Frame/Cloth") {
                        Button(Furniture.Kind.frame4.displayName) { addFurniture(.frame4) }
                        Button(Furniture.Kind.frame8.displayName) { addFurniture(.frame8) }
                        Button(Furniture.Kind.frame12.displayName) { addFurniture(.frame12) }
                        Button(Furniture.Kind.frame20.displayName) { addFurniture(.frame20) }
                    }
                    Menu("Mirror") {
                        Button("15 cm") { addFurniture(.mirror15) }
                        Button("25 cm") { addFurniture(.mirror25) }
                        Button("50 cm") { addFurniture(.mirror50) }
                        Button("100 cm") { addFurniture(.mirror100) }
                    }
                    Button("Truss") { beginAddTruss() }
                    Button(Furniture.Kind.profileSpot.displayName) { addFurniture(.profileSpot) }
                    ForEach(Furniture.Kind.allCases.filter {
                        $0.isLight && !$0.isCOB && !$0.isLegacyLight
                            && $0 != .tube && $0 != .shortTube
                            && $0 != .lightPanel && $0 != .panel1x1
                            && $0 != .smallHMI && $0 != .mediumHMI && $0 != .bigHMI
                            && $0 != .smallTungsten && $0 != .mediumTungsten && $0 != .bigTungsten
                            && $0 != .softbox && $0 != .mediumSoftbox && $0 != .bigSoftbox
                            && !$0.isFrame
                            && $0 != .truss
                            && $0 != .bounce
                            && $0 != .par
                            && $0 != .profileSpot
                            && !$0.isMirror
                    }, id: \.self) { kind in
                        Button(kind.displayName) { addFurniture(kind) }
                    }
                } label: { addMenuLabel("lightbulb.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: toolbarCellWidth)
                .help("Add Light")
            }
            .modifier(SegmentedGroup(height: toolbarPillHeight))
    }

    /// Clear-map (trash) pill.
    var trashButton: some View {
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
    var sizeSunGroup: some View {
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
    func addMenuLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: toolbarIconSize, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    var segmentDivider: some View {
        Divider().frame(height: 18)
    }

    /// A layer's Show/Hide toggle for a toolbar tool's menu.
    @ViewBuilder
    func layerVisibilityToggle(_ isOn: Bool, _ name: String, set: @escaping (Bool) -> Void) -> some View {
        Button { set(!isOn); persist() } label: {
            Label(isOn ? "Hide \(name)" : "Show \(name)",
                  systemImage: isOn ? "eye.slash" : "eye")
        }
    }

    func saveSun() {
        scene.sunSettings = sun
        scene.modelContext?.saveReporting()
    }

    /// Corrects a satellite capture whose recorded size predates the measured
    /// snapshot scale — a one-off, on first open of the scene map. Without it the
    /// stored metres understate the ground the image covers, so markers draw too
    /// large and reframing drifts by the size of the error.
    func calibrateSatelliteCapture() {
        guard !scene.sceneMapSatelliteCalibrated else { return }
        SatelliteCalibration.calibrate(scene)
        scene.modelContext?.saveReporting()
    }

    /// Re-reads the background's real-world scale into local state so markers
    /// re-scale whenever the background (and its scale) changes.
    func refreshMapScale() {
        mapMetersWide = scene.sceneMapMetersWide
        mapCameraMeters = scene.sceneMapCameraSizeMeters
    }

    /// True when there's nothing on the map to clear.
    var mapIsEmpty: Bool {
        doc.elements.isEmpty && doc.arrows.isEmpty && doc.furniture.isEmpty
            && floorPlan.isEmpty && backgroundImage == nil
    }

    /// Asks for a wall's real length; confirming scales the whole map. Used both
    /// after drawing the first wall to-scale and from a wall's "Change Length".
    var scaleInvalid: Bool {
        Double(scaleInput.replacingOccurrences(of: ",", with: ".")).map { $0 <= 0 } ?? true
    }

    var scaleLengthSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Map Scale").font(.headline)
                Text(drawToScale ? "Enter the real length of the wall you just drew."
                                 : "Enter this wall's real length.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("Length", text: $scaleInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .onSubmit { if !scaleInvalid { confirmScaleLength() } }
                Text("metres").foregroundStyle(.secondary)
            }

            Text("The whole map scales to this, so every marker and furniture piece matches real dimensions. Centimetres work as a decimal, e.g. 3.45.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { scaleWallID = nil; drawToScale = false }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { confirmScaleLength() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(scaleInvalid)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 360)
        #else
        .frame(maxWidth: 420, alignment: .leading)
        #endif
        .fixedSize(horizontal: false, vertical: true)
    }

    var scaleHint: String {
        guard let tool = drawTool else {
            return "Choose Wall, Door or Window to start editing."
        }
        if drawToScale && scene.sceneMapMetersWide == nil && tool == .wall {
            return "Draw the first wall, then enter its real length to set the scale."
        }
        if tool == .wall {
            return "Click to drop points; click a point again to close the room."
        }
        return "Click a wall to place a \(tool.rawValue.lowercased())."
    }

    var drawToolbar: some View {
        Group {
            if isPhonePortrait {
                // Portrait iPhone has no room for the hint beside the controls, so it
                // gets its own full-width line below them instead of being squeezed.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { drawToolControls }
                    Text(scaleHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "pencil.tip.crop.circle").foregroundStyle(.secondary)
                    drawToolPicker
                    Text(scaleHint)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    drawToolActions
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    /// The icon, tool picker, spacer and action buttons on one row (portrait iPhone).
    @ViewBuilder
    var drawToolControls: some View {
        Image(systemName: "pencil.tip.crop.circle").foregroundStyle(.secondary)
        drawToolPicker
        Spacer()
        drawToolActions
    }

    var drawToolPicker: some View {
        Picker("Tool", selection: $drawTool) {
            ForEach(DrawTool.allCases, id: \.self) { Text($0.rawValue).tag($0 as DrawTool?) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .onChange(of: drawTool) { _, _ in endChain() }
    }

    @ViewBuilder
    var drawToolActions: some View {
        if drawTool == .wall && chainLastVertex != nil {
            Button("Finish Line") { endChain() }
        }
        Button("Done") { endChain(); isDrawing = false; drawToScale = false; scaleWallID = nil }
            .keyboardShortcut(.cancelAction)
    }
}

struct SegmentedGroup: ViewModifier {
    var height: CGFloat = 34
    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
    }
}

/// The floating capsule look of the iPhone map-corner buttons.
struct MapCornerCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}
