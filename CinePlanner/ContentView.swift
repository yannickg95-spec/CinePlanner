//
//  ContentView.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//
//  Shared UI Components for scene and shot management

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers

// MARK: - Notifications

extension Notification.Name {
    static let startScriptTextSelection = Notification.Name("startScriptTextSelection")
    static let scriptTextSelectionCompleted = Notification.Name("scriptTextSelectionCompleted")
    // The PDF coordinator tells the coverage card when selection mode turns on or
    // off; the card's Done/Cancel tell the coordinator to capture or abort. This
    // moves the instruction + buttons out of the PDF and into the card.
    static let scriptSelectionModeChanged = Notification.Name("scriptSelectionModeChanged")
    static let captureScriptSelection = Notification.Name("captureScriptSelection")
    static let cancelScriptSelection = Notification.Name("cancelScriptSelection")
}

// MARK: - Scene List View

struct SceneListView: View {
    let project: Project
    let version: ScriptVersion?
    /// Selection tracked by Scene.uid (stable across saves), not the model
    /// itself, so a freshly-created scene can't fall out of the set when its
    /// persistentModelID changes.
    @Binding var selectedScenes: Set<String>
    var canImportShots: Bool = false
    var onEditScene: ((Scene) -> Void)? = nil
    var onImportShots: ((Scene) -> Void)? = nil
    var onDeleteScenes: (([Scene]) -> Void)? = nil
    @State private var showDeleteOldScenesConfirmation = false
    @State private var searchText = ""

    var orderedScenes: [Scene] {
        (version?.scenes ?? project.scenes).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Scenes matching the search field (number, location, INT/EXT, day/night).
    private func matchesSearch(_ scene: Scene) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let haystack = [
            "\(scene.sceneNumber)\(scene.suffix)",
            scene.nickname,
            scene.isInterior ? "int interior" : "ext exterior",
            scene.isDay ? "day" : "night"
        ].joined(separator: " ").lowercased()
        return haystack.contains(query)
    }

    var currentScenes: [Scene] {
        orderedScenes.filter { !$0.isArchived && matchesSearch($0) }
    }

    var oldScenes: [Scene] {
        orderedScenes.filter { $0.isArchived && matchesSearch($0) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Scenes")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .frame(height: ProjectEditorView.paneHeaderHeight)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            sceneList
        }
    }

    private var sceneList: some View {
        List(selection: $selectedScenes) {
            // Current Scenes Section
            Section {
                ForEach(currentScenes, id: \.uid) { scene in
                    sceneRow(for: scene)
                }
                .onDelete { offsets in
                    deleteScenes(at: offsets, from: currentScenes)
                }
                .onMove { source, destination in
                    moveScenes(from: source, to: destination, in: currentScenes)
                }
            }

            // Add Scene Button
            Button {
                addScene()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Add Scene")
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            
            // Total Shots Summary
            HStack {
                Image(systemName: "camera.stack.fill")
                    .foregroundStyle(.blue)
                Text("Total Shots")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(totalShotsCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.visible)
            .listRowBackground(Color.blue.opacity(0.05))
            
            // Old Scenes Section (only show if there are old scenes)
            if !oldScenes.isEmpty {
                Section {
                    ForEach(oldScenes, id: \.uid) { scene in
                        sceneRow(for: scene)
                    }
                    .onDelete { offsets in
                        deleteScenes(at: offsets, from: oldScenes)
                    }
                } header: {
                    HStack {
                        Text("Old Scenes")
                        Spacer()
                        Button(role: .destructive) {
                            showDeleteOldScenesConfirmation = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .navigationTitle(project.filmName)
        .onDeleteCommand {
            if !selectedScenes.isEmpty {
                onDeleteScenes?(orderedScenes.filter { selectedScenes.contains($0.uid) })
            }
        }
        .alert(
            "Delete All Old Scenes?",
            isPresented: $showDeleteOldScenesConfirmation
        ) {
            Button("Delete All Old Scenes", role: .destructive) {
                deleteAllOldScenes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(oldScenes.count) old scene\(oldScenes.count == 1 ? "" : "s") and their shots. This action cannot be undone.")
        }
    }
    
    @ViewBuilder
    private func sceneRow(for scene: Scene) -> some View {
        NavigationLink(value: scene) {
            // Stacked so a narrow column can't push anything off the edge:
            // title, then the scene name on its own line, then tags + shot count.
            VStack(alignment: .leading, spacing: 3) {
                Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if !scene.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(scene.nickname)
                        .font(.headline)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    Text(scene.isInterior ? "INT" : "EXT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(scene.isDay ? "DAY" : "NIGHT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((scene.isDay ? Color.blue : Color.orange).opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("\(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 2)
        }
        .dropDestination(for: String.self) { shotIDStrings, _ in
            handleDrop(shotIDStrings: shotIDStrings, toScene: scene)
            return true
        }
        .contextMenu {
            Button {
                onEditScene?(scene)
            } label: {
                Text("Edit Scene")
            }
            if canImportShots {
                Button {
                    onImportShots?(scene)
                } label: {
                    Text("Import Shots from Version…")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDeleteScenes?(deletionTargets(for: scene))
            } label: {
                Text(sceneDeleteLabel(for: scene))
            }
        }
    }

    /// Scenes a delete action should affect: the whole selection when the
    /// right-clicked scene is part of it, otherwise just that scene.
    private func deletionTargets(for scene: Scene) -> [Scene] {
        selectedScenes.contains(scene.uid) ? orderedScenes.filter { selectedScenes.contains($0.uid) } : [scene]
    }

    private func sceneDeleteLabel(for scene: Scene) -> String {
        let count = deletionTargets(for: scene).count
        return count > 1 ? "Delete \(count) Scenes" : "Delete Scene"
    }
    
    private var totalShotsCount: Int {
        orderedScenes.reduce(0) { $0 + $1.shots.count }
    }

    private func handleDrop(shotIDStrings: [String], toScene targetScene: Scene) {
        print("🎬 Attempting to drop shots into scene \(targetScene.sceneNumber)")

        for shotIDString in shotIDStrings {
            // Find the shot in all scenes by matching the ID string
            var sourceScene: Scene?
            var shotToMove: Shot?

            for scene in orderedScenes {
                if let shot = scene.shots.first(where: { $0.id.hashValue.description == shotIDString }) {
                    sourceScene = scene
                    shotToMove = shot
                    break
                }
            }
            
            guard let shot = shotToMove, let source = sourceScene else {
                print("⚠️ Could not find shot with ID \(shotIDString)")
                continue
            }
            
            // Don't move if already in target scene
            if source === targetScene {
                print("ℹ️ Shot \(shot.displayNumber) is already in scene \(targetScene.sceneNumber)")
                continue
            }
            
            print("📦 Moving shot \(shot.displayNumber) from scene \(source.sceneNumber) to scene \(targetScene.sceneNumber)")
            
            // Remove from source scene
            if let index = source.shots.firstIndex(where: { $0.id == shot.id }) {
                source.shots.remove(at: index)
            }
            
            // Add to target scene
            shot.scene = targetScene
            targetScene.shots.append(shot)
            
            // Renumber shots in both scenes
            renumberShotsInScene(source)
            renumberShotsInScene(targetScene)
        }
    }
    
    private func renumberShotsInScene(_ scene: Scene) {
        let shots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
        for (index, shot) in shots.enumerated() {
            shot.shotNumber = index + 1
        }
    }
    
    private func addScene() {
        // Find the highest scene number in this version and add 1
        let highestNumber = orderedScenes.map { $0.sceneNumber }.max() ?? 0
        let nextNumber = highestNumber + 1
        let newScene = Scene(sceneNumber: nextNumber)
        newScene.project = project
        newScene.scriptVersion = version

        // Calculate the sortOrder for the new scene (at the end of current scenes)
        let currentScenesCount = currentScenes.count
        newScene.sortOrder = currentScenesCount

        // Add to project
        project.scenes.append(newScene)
        
        // Update sortOrder for old scenes to come after all current scenes (including the new one)
        for (index, oldScene) in oldScenes.enumerated() {
            oldScene.sortOrder = currentScenesCount + 1 + index
        }
        
        selectedScenes = [newScene.uid]
    }

    private func deleteScenes(at offsets: IndexSet, from sceneList: [Scene]) {
        // Delete scenes at the given indices in the specified list
        let scenesToDelete = offsets.map { sceneList[$0] }
        for scene in scenesToDelete {
            if let index = project.scenes.firstIndex(where: { $0 === scene }) {
                project.scenes.remove(at: index)
            }
            if let version, let index = version.scenes.firstIndex(where: { $0 === scene }) {
                version.scenes.remove(at: index)
            }
        }

        selectedScenes.subtract(scenesToDelete.map(\.uid))

        // Update sortOrder for remaining scenes in this version
        for (index, scene) in orderedScenes.enumerated() {
            scene.sortOrder = index
        }
    }
    
    private func moveScenes(from source: IndexSet, to destination: Int, in sceneList: [Scene]) {
        // Capture BOTH lists BEFORE modifying any sortOrder values to avoid mid-update rendering issues
        let capturedCurrentScenes = currentScenes
        let capturedOldScenes = oldScenes
        
        // Reorder the current scenes
        var reorderedScenes = capturedCurrentScenes
        reorderedScenes.move(fromOffsets: source, toOffset: destination)
        
        // Calculate ALL new sortOrder values BEFORE applying any
        var newSortOrders: [Scene: Int] = [:]
        
        // Assign new sortOrder for current scenes
        for (index, scene) in reorderedScenes.enumerated() {
            newSortOrders[scene] = index
        }
        
        // Assign new sortOrder for old scenes (after all current scenes)
        let newCurrentScenesCount = reorderedScenes.count
        for (index, oldScene) in capturedOldScenes.enumerated() {
            newSortOrders[oldScene] = newCurrentScenesCount + index
        }
        
        // Now apply ALL sortOrder changes at once
        for (scene, newOrder) in newSortOrders {
            scene.sortOrder = newOrder
        }
    }
    
    private func deleteAllOldScenes() {
        let scenesToDelete = oldScenes
        for scene in scenesToDelete {
            if let index = project.scenes.firstIndex(where: { $0 === scene }) {
                project.scenes.remove(at: index)
            }
            if let version, let index = version.scenes.firstIndex(where: { $0 === scene }) {
                version.scenes.remove(at: index)
            }
        }

        selectedScenes.subtract(scenesToDelete.map(\.uid))

        // Update sortOrder for remaining scenes in this version
        for (index, scene) in orderedScenes.enumerated() {
            scene.sortOrder = index
        }
    }
}

// MARK: - Shot List View

struct ShotListView: View {
    let scene: Scene
    /// Selection tracked by Shot.uid, stable across saves (see SceneListView).
    @Binding var selectedShots: Set<String>
    var onEditShot: ((Shot) -> Void)? = nil
    var onDeleteShots: (([Shot]) -> Void)? = nil
    @State private var showCineStagerImport = false

    var sortedShots: [Shot] {
        scene.shots.sorted { $0.shotNumber < $1.shotNumber }
    }
    
    var body: some View {
        List(selection: $selectedShots) {
            Section {
                ForEach(sortedShots, id: \.uid) { shot in
                NavigationLink(value: shot) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Shot \(shot.displayNumber)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            // Nickname on its own line, at the scene-name size.
                            let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !nickname.isEmpty {
                                Text(nickname)
                                    .font(.headline)
                                    .fontWeight(.regular)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Size and type as small labels below the nickname —
                            // side by side when they fit, stacked when they don't.
                            let sizeText = sizeSummary(for: shot)
                            let typeText = typeSummary(for: shot)
                            if sizeText != nil || typeText != nil {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 4) {
                                        if let sizeText { detailTag(sizeText) }
                                        if let typeText { detailTag(typeText) }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let sizeText { detailTag(sizeText) }
                                        if let typeText { detailTag(typeText) }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Spacer()
                    }
                }
                .draggable(shot.id.hashValue.description) {
                    // Preview shown while dragging
                    HStack(spacing: 8) {
                        Image(systemName: "camera.circle.fill")
                        Text("Shot \(shot.displayNumber)")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    Button {
                        onEditShot?(shot)
                    } label: {
                        Text("Edit Shot")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDeleteShots?(deletionTargets(for: shot))
                    } label: {
                        Text(shotDeleteLabel(for: shot))
                    }
                }
            }
            .onDelete(perform: deleteShots)
            .onMove(perform: moveShots)
            }

            // Add Shot Button
            Button {
                addShot()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Add Shot")
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)

            // Alternative: add a shot straight from a CineStager AR capture.
            Button {
                showCineStagerImport = true
            } label: {
                HStack {
                    Image("CineStagerLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text("Add Shot from CineStager")
                        .foregroundStyle(CineStagerImportSheet.cineStagerBlue)
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(scene.project?.filmName ?? "")
        .sheet(isPresented: $showCineStagerImport) {
            CineStagerImportSheet(provideReference: { makeImportedShotReference() })
        }
        .onDeleteCommand {
            if !selectedShots.isEmpty {
                onDeleteShots?(sortedShots.filter { selectedShots.contains($0.uid) })
            }
        }
    }

    /// Shots a delete action should affect: the whole selection when the
    /// right-clicked shot is part of it, otherwise just that shot.
    private func deletionTargets(for shot: Shot) -> [Shot] {
        selectedShots.contains(shot.uid) ? sortedShots.filter { selectedShots.contains($0.uid) } : [shot]
    }

    private func shotDeleteLabel(for shot: Shot) -> String {
        let count = deletionTargets(for: shot).count
        return count > 1 ? "Delete \(count) Shots" : "Delete Shot"
    }

    /// "WS → MS" — the shot's size (with a second size when set), or nil.
    private func sizeSummary(for shot: Shot) -> String? {
        guard shot.hasSize else { return nil }
        var size = shot.sizeShort
        if shot.hasSecondSize { size += " → " + shot.secondSizeShort }
        return size
    }

    /// A small label chip for a shot detail, matching the scene rows' tag style.
    private func detailTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The shot's type for the row subtitle — "Static", or "Static + Handheld"
    /// when a shot combines several. Matches how the exports read.
    private func typeSummary(for shot: Shot) -> String? {
        guard shot.hasType else { return nil }
        var text = shot.typeShort
        if shot.hasSecondType { text += " + " + shot.secondTypeShort }
        if shot.hasThirdType { text += " + " + shot.thirdTypeShort }
        return text
    }

    private func addShot() {
        // Find the next shot number
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        scene.shots.append(newShot)
        newShot.applyAutoTools()
        // Start the shot with one empty reference so its card is open and ready
        // for media, rather than only an "Add Reference" button.
        let reference = ShotReference(sortOrder: 0)
        reference.shot = newShot
        newShot.references.append(reference)
        // Persist now so the new shot — and, on a brand-new project, its new
        // scene — get permanent ids and a settled relationship before the detail
        // pane resolves the selection. Otherwise the very first shot can't be
        // opened until the scene is reselected.
        try? scene.modelContext?.save()
        selectedShots = [newShot.uid]
    }

    /// Creates a new shot with one empty reference, selects it, and returns that
    /// reference for the CineStager import sheet to fill. Called only when the
    /// user confirms a capture, so cancelling leaves no empty shot behind.
    private func makeImportedShotReference() -> ShotReference {
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        scene.shots.append(newShot)
        newShot.applyAutoTools()
        let reference = ShotReference(sortOrder: 0)
        reference.shot = newShot
        newShot.references.append(reference)
        try? scene.modelContext?.save()
        selectedShots = [newShot.uid]
        return reference
    }

    private func deleteShots(at offsets: IndexSet) {
        let shotsToDelete = offsets.map { sortedShots[$0] }
        for shot in shotsToDelete {
            scene.removeSceneMapMarkers(forShotUID: shot.uid)
            if let index = scene.shots.firstIndex(where: { $0 === shot }) {
                scene.shots.remove(at: index)
            }
        }
        selectedShots.subtract(shotsToDelete.map(\.uid))

        // Renumber all remaining shots
        renumberShots()
    }
    
    private func renumberShots() {
        let shots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
        for (index, shot) in shots.enumerated() {
            shot.shotNumber = index + 1
        }
    }
    
    private func moveShots(from source: IndexSet, to destination: Int) {
        var revisedShots = sortedShots
        revisedShots.move(fromOffsets: source, toOffset: destination)
        
        // Update shot numbers based on new order
        for (index, shot) in revisedShots.enumerated() {
            shot.shotNumber = index + 1
        }
    }
}

// MARK: - Shot Detail View

/// One editable custom-info field: a custom label plus its text value, with a
/// delete button. Matches the Shot Setup card's label-column / field layout.
private struct CustomInfoRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Label", text: $item.label)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(width: 100, alignment: .leading)
            TextField("Value", text: $item.value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...10)
                .frame(maxWidth: 200)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this field")
        }
    }
}

/// Film-stock calculator field: pick a gauge, then convert length↔duration.
private struct FilmStockRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void

    private var minutesField: Binding<Int> {
        Binding(get: { Int(item.filmAmount) / 60 },
                set: { item.filmAmount = Double(max(0, $0) * 60 + Int(item.filmAmount) % 60) })
    }
    private var secondsField: Binding<Int> {
        Binding(get: { Int(item.filmAmount) % 60 },
                set: { item.filmAmount = Double((Int(item.filmAmount) / 60) * 60 + max(0, min(59, $0))) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "film")
                    .foregroundStyle(.tint)
                Text("Film length")
                    .font(.headline)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this field")
            }

            // Gauge + frame rate.
            HStack(spacing: 12) {
                Picker("", selection: $item.filmGauge) {
                    ForEach(ShotCustomInfo.filmGauges, id: \.self) { Text("\($0)mm").tag($0) }
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 4) {
                    TextField("fps", value: $item.filmFPS, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                    Text("fps").foregroundStyle(.secondary)
                }
            }

            // Direction toggle.
            Picker("", selection: $item.filmMode) {
                Text("Length → Time").tag("meters")
                Text("Time → Length").tag("time")
            }
            .pickerStyle(.segmented).labelsHidden()

            // Input → result.
            HStack(spacing: 8) {
                if item.filmMode == "meters" {
                    TextField("0", value: $item.filmAmount, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                    Text("m").foregroundStyle(.secondary)
                } else {
                    TextField("0", value: minutesField, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                    Text("min").foregroundStyle(.secondary)
                    TextField("0", value: secondsField, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                    Text("sec").foregroundStyle(.secondary)
                }
                Image(systemName: "equal")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                Text(item.filmComputedText.isEmpty ? "—" : item.filmComputedText)
                    .font(.title3).fontWeight(.semibold).foregroundStyle(.tint)
                    .contentTransition(.numericText())
                    .animation(.default, value: item.filmComputedText)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
        )
        .frame(maxWidth: 320, alignment: .leading)
    }
}

struct ShotDetailView: View {
    @Bindable var shot: Shot
    /// Which photo is open full size, if any.
    @Environment(\.modelContext) private var shotModelContext
    @State private var isMarkingCoverage = false
    @State private var showSecondType: Bool = false
    @State private var showThirdType: Bool = false
    @State private var showSecondSize: Bool = false
    
    // Computed properties for autocomplete suggestions
    private var previousCameraValues: [String] {
        guard let project = shot.scene?.project else { return [] }
        
        var cameras = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                // Don't include the current shot
                if projectShot.id != shot.id && !projectShot.camera.isEmpty {
                    cameras.insert(projectShot.camera)
                }
            }
        }
        return Array(cameras).sorted()
    }
    
    private var previousFormatValues: [String] {
        guard let project = shot.scene?.project else { return [] }
        
        var formats = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                // Don't include the current shot
                if projectShot.id != shot.id && !projectShot.format.isEmpty {
                    formats.insert(projectShot.format)
                }
            }
        }
        return Array(formats).sorted()
    }
    
    private var previousLensValues: [String] {
        guard let project = shot.scene?.project else { return [] }

        var lenses = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                // Don't include the current shot
                if projectShot.id != shot.id && !projectShot.lensPreset.isEmpty {
                    lenses.insert(projectShot.lensPreset)
                }
            }
        }
        return Array(lenses).sorted()
    }

    private var previousFrameLinesValues: [String] {
        guard let project = shot.scene?.project else { return [] }

        var values = Set<String>()
        for scene in project.scenes {
            for projectShot in scene.shots {
                if projectShot.id != shot.id && !projectShot.framelines.isEmpty {
                    values.insert(projectShot.framelines)
                }
            }
        }
        return Array(values).sorted()
    }

    // MARK: Visual helpers

    /// A titled group of rows, used as one section inside the combined card.
    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .kerning(0.5)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shot's setup, camera and coverage sections, unified into one card.
    private var combinedDetailCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Setup + camera side by side when wide, stacked when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    shotSetupCard
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    cameraInformationCard
                        .frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 18) {
                    shotSetupCard
                    Divider()
                    cameraInformationCard
                }
            }

            Divider()

            scriptCoverageCard
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // Extracted so both can be laid out either side by side or stacked,
    // depending on how much width the details pane has.
    /// Whether the two photos came from the same capture. It describes the
    /// relationship between the cards, so it sits above the pair rather than
    /// buried under the top-down image.
    /// Images cap at this width; the metadata beneath them uses the same value
    /// so a data block is never wider than the picture it describes.
    private static let mediaMaxWidth: CGFloat = 700

    private var addReferenceLabel: some View {
        Label("Add Reference Image/Video", systemImage: "plus.circle.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func addReference() {
        let next = (shot.references.map(\.sortOrder).max() ?? -1) + 1
        let reference = ShotReference(sortOrder: next)
        shotModelContext.insert(reference)
        reference.shot = shot
        // Persist immediately so the reference's persistentModelID is permanent
        // from the start. Otherwise a later autosave flips it from temporary to
        // permanent, and if that happens while a file picker is open, the card
        // (keyed by that id) is rebuilt and the picker is torn down mid-use.
        try? shotModelContext.save()
    }

    private func deleteReference(_ reference: ShotReference) {
        reference.shot = nil
        shotModelContext.delete(reference)
    }

    private var shotSetupCard: some View {
    sectionCard("SHOT SETUP") {
    HStack {
        Text("Nickname")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        TextField("Add a nickname for this shot", text: $shot.nickname)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
    }
    
    HStack {
        Text("Size")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        HStack(spacing: 8) {
            OptionPickerView(
                noun: "size",
                placeholder: "Select size",
                sections: [(title: "Sizes", options: ShotSize.pickerOptions),
                           (title: "Other", options: ShotSize.framingOptions)],
                grouped: true,
                value: $shot.sizeName,
                customKey: "customSizes"
            )

            // Plus button (only show when first size is selected and second dropdown is hidden)
            if shot.hasSize && !showSecondSize {
                Button {
                    showSecondSize = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            // Arrow and second size dropdown (only show when showSecondSize is true)
            if showSecondSize {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                OptionPickerView(
                    noun: "size",
                    placeholder: "Select size",
                    sections: [(title: "", options: ShotSize.pickerOptions)],
                    grouped: false,
                    value: $shot.secondSizeName,
                    customKey: "customSizes",
                    onSelect: { if $0.isEmpty { showSecondSize = false } }
                )

                // Remove button for second size
                Button {
                    shot.secondSizeName = ""
                    showSecondSize = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
    }

    HStack {
        Text("Type")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        HStack(spacing: 8) {
            OptionPickerView(
                noun: "type",
                placeholder: "Select type",
                sections: ShotTypeCategory.pickerGroups,
                value: $shot.typeName,
                customKey: "customTypes"
            )

            // Plus button (only show when first type is selected and second dropdown is hidden)
            if shot.hasType && !showSecondType {
                Button {
                    showSecondType = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            // Second type dropdown (only show when showSecondType is true)
            if showSecondType {
                OptionPickerView(
                    noun: "type",
                    placeholder: "Select type",
                    sections: ShotTypeCategory.pickerGroups,
                    value: $shot.secondTypeName,
                    customKey: "customTypes",
                    onSelect: {
                        if $0.isEmpty {
                            showSecondType = false
                            showThirdType = false
                            shot.thirdTypeName = ""
                        }
                    }
                )

                // Plus button for third type (only show when second type is selected and third is hidden)
                if shot.hasSecondType && !showThirdType {
                    Button {
                        showThirdType = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                } else if !showThirdType {
                    // Remove button for second type (only show if third type is not visible)
                    Button {
                        shot.secondTypeName = ""
                        showSecondType = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Third type dropdown (only show when showThirdType is true)
            if showThirdType {
                OptionPickerView(
                    noun: "type",
                    placeholder: "Select type",
                    sections: ShotTypeCategory.pickerGroups,
                    value: $shot.thirdTypeName,
                    customKey: "customTypes",
                    onSelect: { if $0.isEmpty { showThirdType = false } }
                )

                // Remove button for third type
                Button {
                    shot.thirdTypeName = ""
                    showThirdType = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    HStack {
        Text("Focal Length")
            .font(.headline)
            .frame(width: 100, alignment: .leading)
        
        HStack(spacing: 8) {
            // First focal length field
            HStack(spacing: 4) {
                TextField("", value: $shot.lensfocal, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 35)
                    .multilineTextAlignment(.leading)
                
                Text("mm")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            
            // Arrow and second field (only for zoom)
            if !shot.lensIsPrime {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    TextField("", value: $shot.lensfocalEnd, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 35)
                        .multilineTextAlignment(.leading)

                    Text("mm")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Zoom checkbox (off = prime lens, the default)
            Toggle("Zoom", isOn: Binding(
                get: { !shot.lensIsPrime },
                set: { shot.lensIsPrime = !$0 }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("On: zoom lens with a focal range. Off: prime lens with a single focal length.")
        }
    }
    
    HStack {
        Text("Grip")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        OptionPickerView(
            noun: "grip",
            placeholder: "Select grip",
            sections: ShotType.pickerGroups,
            value: $shot.gripName,
            customKey: "customGrips"
        )
    }

    // Extra info — part of the core shot settings, right under Grip.
    // Vertical axis lets the field grow as the text gets longer.
    HStack(alignment: .top) {
        Text("Extra info")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        TextField("Additional information", text: $shot.extraInfo, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...10)
            .frame(maxWidth: 200)
    }

    customInfoSection

    }
    }

    // User-added custom fields, listed under Extra info with an "Add Custom Info"
    // menu (a labelled text box for now; more field types can join the menu).
    @ViewBuilder
    private var customInfoSection: some View {
        ForEach(shot.orderedCustomInfo) { item in
            if item.kind == "filmstock" {
                FilmStockRow(item: item) { deleteCustomInfo(item) }
            } else {
                CustomInfoRow(item: item) { deleteCustomInfo(item) }
            }
        }
        Menu {
            Button {
                addCustomInfo(kind: "text")
            } label: {
                Label("Text field with label", systemImage: "textformat")
            }
            Button {
                addFilmToolToProject()
            } label: {
                Label("Film length calculator", systemImage: "film")
            }
        } label: {
            Label("Add Tool", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, 2)
    }

    private func addCustomInfo(kind: String) {
        let next = (shot.customInfo.map(\.sortOrder).max() ?? -1) + 1
        let item = ShotCustomInfo(sortOrder: next, kind: kind)
        item.shot = shot
        shotModelContext.insert(item)
        try? shotModelContext.save()
    }

    /// The film-length calculator is project-wide: add it to every shot that
    /// doesn't have one and turn on auto-add for future shots.
    private func addFilmToolToProject() {
        guard let project = shot.scene?.project else { addCustomInfo(kind: "filmstock"); return }
        project.autoAddFilmTool = true
        for scene in project.scenes {
            for s in scene.shots where !s.customInfo.contains(where: { $0.kind == "filmstock" }) {
                let item = ShotCustomInfo(sortOrder: (s.customInfo.map(\.sortOrder).max() ?? -1) + 1,
                                          kind: "filmstock")
                item.shot = s
            }
        }
        try? shotModelContext.save()
    }

    private func deleteCustomInfo(_ item: ShotCustomInfo) {
        shotModelContext.delete(item)
        try? shotModelContext.save()
    }

    private var scriptCoverageCard: some View {
    sectionCard("SCRIPT COVERAGE") {
        // While marking, the instruction and Done/Cancel — previously an overlay
        // on the PDF — appear here in the card. The PDF selection itself is
        // unchanged; Done/Cancel just signal the coordinator.
        if isMarkingCoverage {
            HStack(spacing: 10) {
                Image(systemName: "highlighter")
                    .foregroundStyle(.blue)
                Text("Select text in the PDF, then:")
                    .font(.body)
                Spacer(minLength: 0)
                Button("Cancel") {
                    NotificationCenter.default.post(name: .cancelScriptSelection, object: nil)
                }
                .buttonStyle(.bordered)
                Button("Done") {
                    NotificationCenter.default.post(name: .captureScriptSelection, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            HStack {
                Button {
                    // Signal the PDF viewer to enter text selection mode
                    NotificationCenter.default.post(
                        name: .startScriptTextSelection, object: nil,
                        userInfo: ["shot": shot])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "highlighter")
                        Text("Mark Text")
                    }
                }
                .buttonStyle(.bordered)

                if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                    Text("(\(selections.count) marking\(selections.count == 1 ? "" : "s"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        shot.scriptCoverageSelections = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear all coverage markings")
                }
            }
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .scriptSelectionModeChanged)) { note in
        // Only react to this shot's selection; ignore an id that isn't ours.
        let active = note.userInfo?["active"] as? Bool ?? false
        if active {
            if let id = note.userInfo?["shotID"] as? PersistentIdentifier, id == shot.persistentModelID {
                isMarkingCoverage = true
            }
        } else {
            isMarkingCoverage = false
        }
    }
    }

    private var cameraInformationCard: some View {
    sectionCard("CAMERA INFORMATION") {
        // Camera - Always editable
        HStack {
            Text("Camera")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                TextField("Camera name", text: $shot.camera)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousCameraValues.isEmpty {
                    ChipMenu(items: previousCameraValues.map { v in
                        ChipMenuItem(title: v) { shot.camera = v }
                    }) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used cameras")
                }
            }
        }

        // Format - Always editable
        HStack {
            Text("Format")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                TextField("Format", text: $shot.format)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousFormatValues.isEmpty {
                    ChipMenu(items: previousFormatValues.map { v in
                        ChipMenuItem(title: v) { shot.format = v }
                    }) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used formats")
                }
            }
        }

        // Framelines - Always editable
        HStack {
            Text("Framelines")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                TextField("Framelines", text: $shot.framelines)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousFrameLinesValues.isEmpty {
                    ChipMenu(items: previousFrameLinesValues.map { v in
                        ChipMenuItem(title: v) { shot.framelines = v }
                    }) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used framelines")
                }
            }
        }

        // Lens - Always editable
        HStack {
            Text("Lens")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                TextField("Lens name", text: $shot.lensPreset)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousLensValues.isEmpty {
                    ChipMenu(items: previousLensValues.map { v in
                        ChipMenuItem(title: v) { shot.lensPreset = v }
                    }) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used lenses")
                }
            }
        }
    }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The shot number, nickname and size/type/grip already appear in
                // the shots list, so the detail pane goes straight to the cards.

                // Setup, camera and coverage, unified into one card.
                combinedDetailCard
                    .padding(.horizontal)
                
                // References: each is a photo or a video with its own optional
                // top-down map. A shot can carry as many as it needs.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(shot.orderedReferences.enumerated()), id: \.element.uid) { index, reference in
                        ReferenceCardView(
                            reference: reference,
                            index: index + 1,
                            totalCount: shot.references.count,
                            onDelete: { deleteReference(reference) }
                        )
                    }

                    // Full-width and large so it can't be overlooked.
                    Button(action: addReference) { addReferenceLabel }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.vertical)
        }
                        .onAppear {
            // Show second type dropdown if a second type is already set
            showSecondType = shot.hasSecondType
            // Show third type dropdown if a third type is already set
            showThirdType = shot.hasThirdType
            // Show second size dropdown if a second size is already set
            showSecondSize = shot.hasSecondSize
        }
        .onChange(of: shot.id) { _, _ in
            // Each reference card owns its own pickers now; only the
            // shot-level toggles need resetting here.
            showSecondType = shot.hasSecondType
            showThirdType = shot.hasThirdType
            showSecondSize = shot.hasSecondSize
        }
    }

}

// MARK: - Option Picker

/// A reusable field (size, type, grip): a button that opens a popover of options
/// laid out in two balanced columns, grouped like with like. The user can add
/// their own options, which are remembered app-wide and can be removed here.
struct OptionPickerView: View {
    typealias Option = (label: String, value: String)
    typealias Section = (title: String, options: [Option])

    let noun: String                    // "size" / "type" / "grip"
    let placeholder: String
    let sections: [Section]             // built-in options
    let grouped: Bool                   // false = one flat list, no section headers
    @Binding var value: String          // the stored value
    var onSelect: ((String) -> Void)? = nil   // called after any value change

    // Custom options are stored as one newline-joined string because @AppStorage
    // can't hold an array directly. The key is per-field, passed in at init.
    @AppStorage private var customRaw: String
    @State private var isPresented = false
    @State private var showAdd = false
    @State private var newName = ""

    init(noun: String, placeholder: String, sections: [Section], grouped: Bool = true,
         value: Binding<String>, customKey: String, onSelect: ((String) -> Void)? = nil) {
        self.noun = noun
        self.placeholder = placeholder
        self.sections = sections
        self.grouped = grouped
        self._value = value
        self.onSelect = onSelect
        self._customRaw = AppStorage(wrappedValue: "", customKey)
    }

    private var customOptions: [String] {
        customRaw.split(separator: "\n").map(String.init)
    }

    private var hasValue: Bool { !value.isEmpty && value != "none" }

    /// The menu label for the current value — a built-in's display name, or the
    /// custom text itself.
    private var currentLabel: String {
        for section in sections {
            if let match = section.options.first(where: { $0.value == value }) { return match.label }
        }
        return hasValue ? value : placeholder
    }

    /// Built-in groups plus the user's custom list. Custom options carry
    /// label == value.
    private var allSections: [Section] {
        var result = sections
        if !customOptions.isEmpty {
            result.append((title: "Custom", options: customOptions.map { (label: $0, value: $0) }))
        }
        return result
    }

    /// Splits the sections into two balanced columns, keeping each section whole
    /// and preserving top-to-bottom order within a column. A section's weight is
    /// its options plus one for the header row.
    private func splitColumns(_ sections: [Section]) -> (left: [Section], right: [Section]) {
        let total = sections.reduce(0) { $0 + $1.options.count + 1 }
        var accumulated = 0
        var breakIndex = sections.count
        for (index, section) in sections.enumerated() {
            accumulated += section.options.count + 1
            if accumulated >= (total + 1) / 2 { breakIndex = index + 1; break }
        }
        return (Array(sections[..<breakIndex]), Array(sections[breakIndex...]))
    }

    // Flat (ungrouped) layout: every built-in option followed by the customs,
    // each tagged so custom ones can carry a remove button.
    private var flatItems: [(option: Option, isCustom: Bool)] {
        var items = sections.flatMap { $0.options }.map { (option: $0, isCustom: false) }
        items += customOptions.map { (option: (label: $0, value: $0), isCustom: true) }
        return items
    }

    private func itemColumn(_ items: [(option: Option, isCustom: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.option.value) { item in
                optionChip(item.option, removable: item.isCustom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack {
                Text(currentLabel)
                    .foregroundStyle(hasValue ? .primary : .secondary)
                    // One line, sized to its text — the card is given enough width
                    // (camera card is capped narrower) so labels never wrap or clip.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 60)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
        .alert("Add Custom \(noun.capitalized)", isPresented: $showAdd) {
            TextField("\(noun.capitalized) name", text: $newName)
            Button("Add") { addCustom(newName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a \(noun) name. It'll be saved for use in all your projects.")
        }
    }

    private var popover: some View {
        // No fixed height — the popover fits its content, so a short list (sizes)
        // doesn't leave empty space below.
        VStack(alignment: .leading, spacing: 12) {
            if grouped {
                let split = splitColumns(allSections)
                HStack(alignment: .top, spacing: 16) {
                    sectionColumn(split.left)
                    sectionColumn(split.right)
                }
            } else {
                // A single column of titled sections (e.g. Sizes and Framing),
                // like the grouped picker but not split into two columns.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections, id: \.title) { section in
                        optionSection(section)
                    }
                    if !customOptions.isEmpty {
                        optionSection((title: "Custom", options: customOptions.map { (label: $0, value: $0) }))
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    // Close the popover first, then raise the alert — macOS
                    // doesn't present an alert cleanly over an open popover.
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        newName = ""
                        showAdd = true
                    }
                } label: {
                    Label("Add Custom \(noun.capitalized)…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                if hasValue {
                    Button("Clear") { select("") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: grouped ? 360 : 240)
    }

    /// One of the two side-by-side columns: a stack of whole sections.
    private func sectionColumn(_ sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections, id: \.title) { section in
                optionSection(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A section header with its options listed vertically underneath.
    private func optionSection(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(section.options, id: \.value) { option in
                optionChip(option, removable: section.title == "Custom")
            }
        }
    }

    private func optionChip(_ option: Option, removable: Bool = false) -> some View {
        let selected = option.value.caseInsensitiveCompare(value) == .orderedSame
        // The whole padded chip is the button (contentShape covers it), so a click
        // anywhere on the row selects — not just on the text. The remove-× floats
        // on top as its own button.
        return Button {
            select(option.value)
        } label: {
            Text(option.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, removable ? 26 : 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .trailing) {
            if removable {
                Button {
                    removeCustom(option.value)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help("Remove this custom \(noun)")
            }
        }
    }

    private func select(_ newValue: String) {
        value = newValue
        isPresented = false
        onSelect?(newValue)
    }

    /// Adds a custom option app-wide (unless it duplicates a built-in label,
    /// a built-in value, or an existing custom — all case-insensitively) and
    /// selects it.
    private func addCustom(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let builtIn = sections.flatMap { $0.options }.flatMap { [$0.label.lowercased(), $0.value.lowercased()] }
        let taken = Set(customOptions.map { $0.lowercased() } + builtIn)
        if !taken.contains(name.lowercased()) {
            customRaw = (customOptions + [name]).joined(separator: "\n")
        }
        select(name)
    }

    private func removeCustom(_ name: String) {
        customRaw = customOptions
            .filter { $0.caseInsensitiveCompare(name) != .orderedSame }
            .joined(separator: "\n")
    }
}

// MARK: - Photo Slot

struct PhotoSlot: View {
    let photoData: Data?
    @Binding var selectedItem: PhotosPickerItem?
    let title: String
    var maxWidth: CGFloat = 700
    /// Most shots have no photo, so an empty slot collapses to a single row
    /// rather than reserving 200pt of placeholder.
    var compactWhenEmpty: Bool = false
    var onDelete: (() -> Void)?
    /// Shown as a button over the image; the image itself belongs to the picker.
    var onEnlarge: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if photoData == nil && compactWhenEmpty {
            compactAddRow
        } else {
            fullSlot
        }
    }

    private var compactAddRow: some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(.secondary)
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Add")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var fullSlot: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    if let photoData, let image = loadImage(from: photoData) {
                        #if os(macOS)
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: maxWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            }
                        #else
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: maxWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            }
                        #endif
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.06))
                            .frame(maxWidth: maxWidth)
                            .frame(height: 200)
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                    Text(title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                    Text("Click to add a photo")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            }
                    }
                }
                .buttonStyle(.plain)
                
                // Enlarge / delete, shown only once a photo exists
                if photoData != nil {
                    HStack(spacing: 6) {
                        if let onEnlarge {
                            Button(action: onEnlarge) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white, .black)
                                    .opacity(0.7)
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .help("View full size")
                        }
                        if let onDelete {
                            Button(action: onDelete) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white, .black)
                                    .opacity(0.7)
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .help("Remove photo")
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
    
    #if os(macOS)
    private func loadImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }
    #else
    private func loadImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }
    #endif
}

// MARK: - Reference Video Player

/// Inline player for a shot's reference video. The video is stored as `Data`, so
/// it's written once to a stable temp file (keyed by the shot) and played from there.
struct ReferenceVideoView: View {
    let shotID: String
    let videoData: Data
    let fileExtension: String
    var onDelete: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let player {
                    // A 4:3 box on black, so the video reference matches the
                    // reference-image and map boxes beside it. The clip letterboxes
                    // inside rather than dictating the box's shape.
                    Color.black
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay { VideoPlayer(player: player) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.85))
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay(ProgressView().tint(.white))
                }
            }

            Button {
                player?.pause()
                player = nil
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black)
                    .opacity(0.7)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .onAppear { preparePlayer() }
        .onDisappear { player?.pause() }
        .onChange(of: shotID) { _, _ in preparePlayer() }
    }

    private func preparePlayer() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cineplanner_ref_\(shotID).\(fileExtension)")
        // Reuse the temp file if it already matches this data; otherwise (re)write it.
        let needsWrite: Bool
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size == videoData.count {
            needsWrite = false
        } else {
            needsWrite = true
        }
        if needsWrite {
            try? videoData.write(to: url, options: .atomic)
        }
        player = AVPlayer(url: url)
    }
}

// MARK: - Film Name Editor

struct FilmNameEditor: View {
    @Binding var filmName: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Film Name", text: $filmName)
            }
            .navigationTitle("Edit Film Name")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(200)])
    }
}

// MARK: - Metadata View

struct MetadataView: View {
    let metadata: PhotoMetadata

    /// All metadata as flat label/value pairs. Group headings are omitted on
    /// purpose — each label already reads clearly on its own, and dropping them
    /// lets the pairs flow side by side so the box stays short.
    private var items: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        // Camera / Format / Focal Length stay adjacent — they're read together.
        if let family = metadata.cameraFamily { rows.append(("Camera", family)) }
        if let format = metadata.cameraFormat { rows.append(("Format", format)) }
        if let focal = metadata.focalLength {
            let focalString = focal.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fmm", focal)
                : String(format: "%.1fmm", focal)
            rows.append(("Focal Length", focalString))
        }
        if let lens = metadata.lensPreset { rows.append(("Lens", lens)) }
        if let framelines = metadata.framelines, !framelines.isEmpty { rows.append(("Framelines", framelines)) }
        if let tilt = metadata.tilt { rows.append(("Tilt", String(format: "%.1f\u{00B0}", tilt))) }
        return rows
    }

    var body: some View {
        if !items.isEmpty {
            // Columns are built explicitly (rather than with LazyVGrid) so the
            // values read top-to-bottom down each column instead of across rows.
            // ViewThatFits picks the widest column count that still fits.
            ViewThatFits(in: .horizontal) {
                columnLayout(3)
                columnLayout(2)
                columnLayout(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    /// Splits the values into `count` columns, filling each column top-to-bottom.
    private func splitIntoColumns(_ count: Int) -> [[(label: String, value: String)]] {
        guard count > 1, items.count > 1 else { return [items] }
        let perColumn = Int((Double(items.count) / Double(count)).rounded(.up))
        var columns: [[(label: String, value: String)]] = []
        var index = 0
        while index < items.count {
            let end = min(index + perColumn, items.count)
            columns.append(Array(items[index..<end]))
            index = end
        }
        return columns
    }

    private func columnLayout(_ count: Int) -> some View {
        let columns = splitIntoColumns(count)
        return HStack(alignment: .top, spacing: 20) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(column, id: \.label) { item in
                        MetadataRow(label: item.label, value: item.value)
                    }
                }
                // Matches the map metadata's minimum so, side by side in the
                // reference card, the two columns split evenly and their image
                // boxes come out the same size. ViewThatFits still uses this to
                // drop to fewer columns as the pane narrows.
                .frame(minWidth: 130, alignment: .leading)
            }
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    var labelWidth: CGFloat = 92

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)   // wrap, don't clip, when narrow
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Top Down Metadata View

struct TopDownMetadataView: View {
    let metadata: PhotoMetadata
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Location Information")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Label above value, and the rows wrap into as many columns as fit —
            // so nothing runs off the edge when the box is narrow (these labels
            // are long) and they sit side by side when there's room.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18, alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                ForEach(metadata.mapDisplayItems, id: \.label) { item in
                    stackedPair(item.label, item.value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Label above value, so a long label never has to share a line with its
    /// value and get clipped in a narrow column.
    private func stackedPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
