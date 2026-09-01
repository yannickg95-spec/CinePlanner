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

/// Width of the focal-length text fields. Wider on iPad, where the larger text
/// field font needs more room to show three-digit focal lengths (100 mm+).
#if os(iOS)
private let focalFieldWidth: CGFloat = 60
#else
private let focalFieldWidth: CGFloat = 35
#endif

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
    // iOS two-tap marking: the coordinator reports which word the user is picking
    // (0 = first word, 1 = last word) so the card/toolbar can update its prompt and
    // its confirm-button label ("Next" vs "Done").
    static let scriptSelectionPhaseChanged = Notification.Name("scriptSelectionPhaseChanged")
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
    /// Called with the freshly created scene so the editor can prompt the user to
    /// place its script page.
    var onSceneAdded: ((Scene) -> Void)? = nil
    /// When set, tapping a row selects the scene (and calls this) instead of pushing
    /// its detail — used by the iPhone landscape split, where the right pane follows
    /// the selection. Nil everywhere else, so the normal drill-down navigation stays.
    var onSelectScene: ((Scene) -> Void)? = nil
    @State private var showDeleteOldScenesConfirmation = false
    @State private var searchText = ""
    @State private var sceneToClear: Scene?

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
            // iPad/Mac: a "Scenes" header labels the column. iPhone shows the scene
            // list directly under its own screen header, so it's omitted there.
            if !DeviceLayout.isPhone {
                Text("Scenes")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .frame(height: ProjectEditorView.paneHeaderHeight)
                    .background(Color.platformControlBackground)

                Divider()
            }

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
        #if os(iOS)
        // Plain style + tight insets let the scene cards span the full column width
        // on iPad (the default grouped style insets them with side margins).
        .listStyle(.plain)
        // iPad: the scenes column carries the film-name title. iPhone shows the name
        // in the editor's content header, so don't set a bar title here.
        .applyIf(!DeviceLayout.isPhone) { $0.navigationTitle(project.filmName) }
        #endif
        #if os(macOS)
        .onDeleteCommand {
            if !selectedScenes.isEmpty {
                onDeleteScenes?(orderedScenes.filter { selectedScenes.contains($0.uid) })
            }
        }
        #endif
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
        .alert(
            "Clear Scene?",
            isPresented: Binding(get: { sceneToClear != nil }, set: { if !$0 { sceneToClear = nil } })
        ) {
            Button("Clear Scene", role: .destructive) {
                if let scene = sceneToClear { clearScene(scene) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let scene = sceneToClear {
                Text("This deletes all \(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s") in Scene \(scene.sceneNumber)\(scene.suffix) and clears its scene map. The scene itself stays. This can't be undone.")
            }
        }
    }

    /// Empties a scene: removes all its shots and wipes its scene map, but keeps
    /// the scene itself. Detaches the shots from the scene (the same way the shot
    /// list's delete does) rather than calling `context.delete` on each — deleting
    /// objects that the open shot list is still rendering can crash on the dangling
    /// reference.
    private func clearScene(_ scene: Scene) {
        scene.shots.removeAll()
        scene.clearSceneMap()
        try? scene.modelContext?.save()
        sceneToClear = nil
    }
    
    /// The row's content — title, scene name, tags. Stacked so a narrow column can't
    /// push anything off the edge.
    private func sceneRowLabel(for scene: Scene) -> some View {
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

            // "NIGHT" when the column has room, else the shorter "NITE" — so it
            // never clips on smaller iPads or at larger text sizes.
            ViewThatFits(in: .horizontal) {
                sceneTagRow(scene, nightLabel: "NIGHT")
                sceneTagRow(scene, nightLabel: "NITE")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sceneRow(for scene: Scene) -> some View {
        Group {
            if let onSelectScene {
                // Landscape split: select-in-place instead of pushing a detail screen.
                Button {
                    selectedScenes = [scene.uid]
                    onSelectScene(scene)
                } label: {
                    sceneRowLabel(for: scene)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(selectedScenes.contains(scene.uid)
                                   ? Color.accentColor.opacity(0.15) : nil)
            } else {
                NavigationLink(value: scene) { sceneRowLabel(for: scene) }
            }
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
            Button {
                bumpSceneNumber(from: scene)
            } label: {
                Label("Increase Scene Number", systemImage: "arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                sceneToClear = scene
            } label: {
                Text("Clear Scene")
            }
            Button(role: .destructive) {
                onDeleteScenes?(deletionTargets(for: scene))
            } label: {
                Text(sceneDeleteLabel(for: scene))
            }
        }
        #if os(iOS)
        // Tight row insets so the card content uses the full column width on iPad.
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        #endif
    }

    /// The INT/EXT + time-of-day + shot-count tags. `nightLabel` lets a caller pass
    /// a shorter spelling ("NITE") for the compact fallback. No trailing spacer, so
    /// `ViewThatFits` can measure the row's true width.
    private func sceneTagRow(_ scene: Scene, nightLabel: String) -> some View {
        HStack(spacing: 6) {
            Text(scene.isInterior ? "INT" : "EXT")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(scene.isDay ? "DAY" : nightLabel)
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
        }
        .fixedSize(horizontal: true, vertical: false)
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

    /// Increments this scene's number and every scene ordered after it, opening a
    /// gap in the numbering (e.g. to make room for a scene inserted before it).
    private func bumpSceneNumber(from scene: Scene) {
        let ordered = orderedScenes
        guard let index = ordered.firstIndex(where: { $0 === scene }) else { return }
        for s in ordered[index...] {
            s.sceneNumber += 1
        }
        try? scene.modelContext?.save()
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
        onSceneAdded?(newScene)
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
    @State private var isImportingShotImages = false
    #if os(iOS)
    // iPad lets the user pick the source: Files or the Photos library.
    @State private var isPresentingShotPhotos = false
    @State private var selectedShotPhotos: [PhotosPickerItem] = []
    #endif

    var sortedShots: [Shot] {
        scene.shots.sorted { $0.shotNumber < $1.shotNumber }
    }

    /// The numbering style already in use in this project (kept uniform across all
    /// shots), so a newly added shot matches instead of reverting to the default.
    private var currentNumberingStyle: ShotNumberingStyle {
        scene.shots.first?.numberingStyle
            ?? scene.project?.scenes.first(where: { !$0.shots.isEmpty })?.shots.first?.numberingStyle
            ?? .numbers
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
                        Text("Shot Numbering")
                    }
                    Button {
                        duplicateShot(shot)
                    } label: {
                        Text("Duplicate Shot")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDeleteShots?(deletionTargets(for: shot))
                    } label: {
                        Text(shotDeleteLabel(for: shot))
                    }
                }
                #if os(iOS)
                // Tight row insets so the shot card uses the full column width on iPad.
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                #endif
            }
            .onDelete(perform: deleteShots)
            .onMove(perform: moveShots)
            }

            // Add-shot actions grouped into one neutral card: a primary "Add Shot"
            // plus the two import sources, split by dividers so it reads as a
            // single control rather than three loose pills.
            VStack(spacing: 0) {
                addSourceRow("Add Shot", systemImage: "plus.circle.fill") {
                    addShot()
                }
                Divider()
                // Bulk add: pick several photos/videos at once — each becomes its
                // own shot (EXIF + size guessed per image).
                #if os(iOS)
                // iPad: a styled dropdown to pick the source — Files or Photos.
                ChipMenu(items: [
                    ChipMenuItem(title: "Choose from Files", systemImage: "folder") {
                        isImportingShotImages = false
                        DispatchQueue.main.async { isImportingShotImages = true }
                    },
                    ChipMenuItem(title: "Choose from Photos", systemImage: "photo.on.rectangle") {
                        isPresentingShotPhotos = true
                    },
                ], width: 240) {
                    addSourceRowLabel("From Images", systemImage: "photo.on.rectangle.angled")
                }
                .fileImporter(isPresented: $isImportingShotImages,
                              allowedContentTypes: [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { addShotsFromMedia(urls) }
                }
                .photosPicker(isPresented: $isPresentingShotPhotos, selection: $selectedShotPhotos,
                              matching: .any(of: [.images, .videos]))
                .onChange(of: selectedShotPhotos) { _, items in
                    guard !items.isEmpty else { return }
                    let picked = items
                    selectedShotPhotos = []
                    addShotsFromPhotos(picked)
                }
                #else
                addSourceRow("From Images", systemImage: "photo.on.rectangle.angled") {
                    isImportingShotImages = false
                    DispatchQueue.main.async { isImportingShotImages = true }
                }
                .fileImporter(isPresented: $isImportingShotImages,
                              allowedContentTypes: [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { addShotsFromMedia(urls) }
                }
                #endif
                Divider()
                // Add a shot straight from a CineStager AR capture.
                addSourceRow("From CineStager", assetImage: "CineStagerLogo") {
                    showCineStagerImport = true
                }
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        // Plain style + tight insets let the shot cards span the full column width
        // on iPad (the default grouped style insets them with side margins).
        .listStyle(.plain)
        // iPad/Mac: the shots column carries the film-name title. On iPhone the
        // pushed scene screen owns the title ("Scene X"), so don't override it.
        .applyIf(!DeviceLayout.isPhone) { $0.navigationTitle(scene.project?.filmName ?? "") }
        #endif
        .sheet(isPresented: $showCineStagerImport) {
            CineStagerImportSheet(provideReference: { makeImportedShotReference() })
        }
        #if os(macOS)
        .onDeleteCommand {
            if !selectedShots.isEmpty {
                onDeleteShots?(sortedShots.filter { selectedShots.contains($0.uid) })
            }
        }
        #endif
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

    /// One row of the grouped add-shot card: leading icon (SF Symbol or asset),
    /// title, full-width tap target — styled neutrally so the three read as one
    /// control.
    private func addSourceRow(_ title: String,
                              systemImage: String? = nil,
                              assetImage: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            addSourceRowLabel(title, systemImage: systemImage, assetImage: assetImage)
        }
        .buttonStyle(.plain)
    }

    private func addSourceRowLabel(_ title: String,
                                  systemImage: String? = nil,
                                  assetImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Fill a shot's camera package from the project default — but only fields that
    /// are still empty, so it works both as the seed for a manual shot and as a
    /// gap-filling fallback after an import (which always leads).
    private func applyCameraDefaults(to shot: Shot) {
        guard let project = scene.resolvedProject else { return }
        if shot.camera.isEmpty { shot.camera = project.defaultCamera }
        if shot.framelines.isEmpty { shot.framelines = project.defaultFramelines }
        if shot.lensPreset.isEmpty { shot.lensPreset = project.defaultLens }
    }

    private func addShot() {
        // Find the next shot number
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        newShot.numberingStyle = currentNumberingStyle
        applyCameraDefaults(to: newShot)
        scene.shots.append(newShot)
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

    /// Bulk-adds one shot per picked media file, each with the photo/video as its
    /// first reference (EXIF and a Vision size guess filled per image), mirroring
    /// the multi-select CineStager import. Selects the new shots.
    private func addShotsFromMedia(_ urls: [URL]) {
        var nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        var created: [Shot] = []
        for url in urls {
            let newShot = Shot(shotNumber: nextNumber)
            nextNumber += 1
            newShot.scene = scene
            newShot.numberingStyle = currentNumberingStyle
            scene.shots.append(newShot)
            let reference = ShotReference(sortOrder: 0)
            reference.shot = newShot
            newShot.references.append(reference)
            ReferenceMediaLoader.load(mediaAt: url, into: reference)
            // The import (EXIF / Cadrage) leads; the project default only fills
            // fields the import left empty.
            applyCameraDefaults(to: newShot)
            created.append(newShot)
        }
        guard !created.isEmpty else { return }
        try? scene.modelContext?.save()
        selectedShots = Set(created.map { $0.uid })
    }

    #if os(iOS)
    /// Bulk add from the Photos library: writes each picked item to a temporary
    /// file so it can reuse the same URL-based media loader as the Files path
    /// (which reads EXIF and guesses size/type), then cleans the temp files up.
    private func addShotsFromPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
            addShotsFromMedia(urls)
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }
    #endif

    /// Creates a new shot with one empty reference, selects it, and returns that
    /// reference for the CineStager import sheet to fill. Called only when the
    /// user confirms a capture, so cancelling leaves no empty shot behind.
    private func makeImportedShotReference() -> ShotReference {
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        newShot.numberingStyle = currentNumberingStyle
        // No project-camera default here: the CineStager import fills the camera
        // fields (and only falls back to the project default for gaps), so the
        // imported values always lead.
        scene.shots.append(newShot)
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

    /// Duplicates a shot (all its fields, references and custom info, with fresh
    /// ids) and drops the copy right after the original, renumbering the scene.
    private func duplicateShot(_ shot: Shot) {
        let copy = shot.duplicate()
        copy.scene = scene
        scene.shots.append(copy)
        var ordered = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
        ordered.removeAll { $0 === copy }
        if let index = ordered.firstIndex(where: { $0 === shot }) {
            ordered.insert(copy, at: index + 1)
        } else {
            ordered.append(copy)
        }
        for (index, s) in ordered.enumerated() { s.shotNumber = index + 1 }
        try? scene.modelContext?.save()
        selectedShots = [copy.uid]
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
            DebouncedTextField("Label", text: $item.label)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(width: 100, alignment: .leading)
            DebouncedTextField("Value", text: $item.value, axis: .vertical)
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

/// Time-of-day field: a preset picker (dawn, dusk, golden hour…) plus a Custom
/// option that reveals a free-text field.
private struct ShotTimeOfDayRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void

    private static let customTag = "\u{1}custom"   // sentinel that can't be a preset

    private var isCustom: Bool { !ShotCustomInfo.timeOfDayPresets.contains(item.value) }

    private var selection: Binding<String> {
        Binding(
            get: { ShotCustomInfo.timeOfDayPresets.contains(item.value) ? item.value : Self.customTag },
            set: { newValue in
                if newValue == Self.customTag {
                    if ShotCustomInfo.timeOfDayPresets.contains(item.value) { item.value = "" }
                } else {
                    item.value = newValue
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Time of day")
                .font(.headline).frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: selection) {
                    ForEach(ShotCustomInfo.timeOfDayPresets, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }
                .labelsHidden().fixedSize()
                if isCustom {
                    DebouncedTextField("Describe the time of day", text: $item.value)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove this field")
        }
    }
}

/// Film-stock calculator field: pick a gauge, then convert length↔duration.
private struct FilmStockRow: View {
    @Bindable var item: ShotCustomInfo
    let onDelete: () -> Void
    @State private var showTotals = false

    private var sceneShots: [Shot] { item.shot?.scene?.shots ?? [] }
    private var projectShots: [Shot] {
        item.shot?.scene?.project?.scenes.flatMap { $0.shots } ?? sceneShots
    }

    @ViewBuilder
    private func totalsSection(_ title: String,
                              _ totals: [(gauge: String, metres: Double, seconds: Double)]) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if totals.isEmpty {
                Text("—").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        ForEach(totals, id: \.gauge) { t in
            HStack {
                Text(ShotCustomInfo.filmGaugeLabel(t.gauge))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                Spacer()
                Text("\(ShotCustomInfo.filmMetresString(t.metres)) · \(ShotCustomInfo.filmDurationString(t.seconds))")
                    .font(.subheadline).fontWeight(.medium).monospacedDigit()
            }
        }
    }

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
                    ForEach(ShotCustomInfo.filmGauges, id: \.self) { Text(ShotCustomInfo.filmGaugeLabel($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 4) {
                    DecimalField(value: $item.filmFPS, width: 52, alignment: .trailing, placeholder: "fps")
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
                    DecimalField(value: $item.filmAmount, width: 64, alignment: .trailing, placeholder: "0")
                    Text("m").foregroundStyle(.secondary)
                } else {
                    NumericField(value: minutesField, width: 44, alignment: .trailing, placeholder: "0")
                    Text("min").foregroundStyle(.secondary)
                    NumericField(value: secondsField, width: 44, alignment: .trailing, placeholder: "0")
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

            // Roll-ups across the scene and the whole project, per gauge —
            // collapsed by default so the card stays compact. The whole label row
            // toggles it.
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showTotals.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(showTotals ? 90 : 0))
                    Text("Scene & project totals").font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTotals {
                VStack(alignment: .leading, spacing: 6) {
                    totalsSection("Scene total", ShotCustomInfo.filmTotalsByGauge(for: sceneShots))
                    totalsSection("Project total", ShotCustomInfo.filmTotalsByGauge(for: projectShots))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
        )
        .frame(maxWidth: 340, alignment: .leading)
        .onAppear {
            // Migrate the old generic "35" to explicit 4-perf so the picker matches.
            if item.filmGauge == "35" { item.filmGauge = "35-4" }
        }
    }
}

/// A `TextField` that types into fast local state and writes the bound value only
/// after the user pauses (or when the field goes away). Binding a `TextField`
/// straight to a SwiftData `@Model` property makes every keystroke trigger a store
/// write (autosave + CloudKit) and re-render the whole detail view, which makes
/// typing lag badly. This decouples keystrokes from those writes.
///
/// Safe against shot-switching only when its host view has a stable identity per
/// shot (see the `.id(shot.uid)` on `ShotDetailView`): the field then reseeds on
/// appear and flushes any pending write on disappear, so no edit is lost.
struct DebouncedTextField: View {
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let axis: Axis

    @State private var draft = ""
    @State private var debounce: Task<Void, Never>?

    init(_ placeholder: LocalizedStringKey, text: Binding<String>, axis: Axis = .horizontal) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                // Adopt external changes (undo/redo, sync) and drop any pending
                // write so a stale draft can't clobber them.
                if newValue != draft { debounce?.cancel(); draft = newValue }
            }
            .onChange(of: draft) { _, newValue in
                guard newValue != text else { return }
                debounce?.cancel()
                debounce = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { text = newValue }
                }
            }
            .onDisappear {
                debounce?.cancel()
                if draft != text { text = draft }   // flush before leaving
            }
    }
}

struct ShotDetailView: View {
    @Bindable var shot: Shot
    /// Which photo is open full size, if any.
    @Environment(\.modelContext) private var shotModelContext
    @State private var isMarkingCoverage = false
    /// iOS two-tap marking: false while picking the first word, true for the last.
    @State private var markLastPhase = false
    /// iPad with a pointer marks the Mac way (drag to select, one Done) instead of
    /// the two-tap word picker.
    @State private var pointerMarking = false
    @State private var showSecondType: Bool = false
    @State private var showThirdType: Bool = false
    @State private var showSecondSize: Bool = false
    /// Presents the per-project card settings (Shot Setup field order + the
    /// Camera Information default), opened from either card's gear.
    @State private var showingCardSettings = false

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
    
    /// When this shot's (combined) camera matches one already imported from
    /// CineStager — which carries a real sensor width — reuse that sensor for this
    /// shot. So a manually-added shot set to a previously-imported camera gets the
    /// correct scene-map FOV, without a CineStager import of its own. Only ever
    /// copies a value in — never clears one — so it can't wipe an imported shot's
    /// own sensor. Runs when the camera changes.
    private func inheritCineStagerSensorWidth() {
        guard !shot.camera.isEmpty, let project = shot.scene?.project else { return }
        for scene in project.scenes {
            for other in scene.shots where other.id != shot.id {
                if let sensor = other.sensorWidthMM, sensor > 0, other.camera == shot.camera {
                    if shot.sensorWidthMM != sensor { shot.sensorWidthMM = sensor }
                    return
                }
            }
        }
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
    private func sectionCard<Content: View>(_ title: String, gear: (() -> Void)? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                if let gear {
                    Spacer(minLength: 8)
                    Button(action: gear) {
                        Image(systemName: "gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Card settings")
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A SHOT SETUP row: the label sits beside its controls when the pane is wide
    /// enough, and stacks above them when it's too narrow — so the controls (a
    /// zoom range, or several sizes/types) never overlap or clip.
    private func setupRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        let controls = content()
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).font(.headline).frame(width: 100, alignment: .leading)
                controls
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.headline)
                controls
            }
        }
    }

    /// The shot's setup and camera sections, unified into one card.
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
        }
        .modifier(DetailCardChrome())
    }

    /// Script coverage as its own card, matching the reference cards.
    private var scriptCoverageStandaloneCard: some View {
        scriptCoverageCard
            .modifier(DetailCardChrome())
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
    sectionCard("SHOT SETUP", gear: { showingCardSettings = true }) {
        ForEach(orderedSetupFields) { field in
            shotSetupFieldView(field)
        }
        customInfoSection
    }
    }

    /// The Shot Setup fields in this project's chosen order, minus any hidden here.
    private var orderedSetupFields: [ShotSetupField] {
        guard let project = shot.scene?.resolvedProject else { return ShotSetupField.allCases }
        let hidden = project.hiddenShotSetupFields
        return project.shotSetupFieldOrder.filter { !hidden.contains($0) }
    }

    /// One Shot Setup field — lets the card render them in the project's order.
    @ViewBuilder
    private func shotSetupFieldView(_ field: ShotSetupField) -> some View {
        switch field {
        case .nickname:
    setupRow("Nickname") {
        DebouncedTextField("Add a nickname for this shot", text: $shot.nickname)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
    }

        case .size:
    setupRow("Size") {
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

        case .type:
    setupRow("Type") {
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
    
        case .focal:
    setupRow("Focal Length") {
        HStack(spacing: 8) {
            // First focal length field
            HStack(spacing: 4) {
                NumericField(value: $shot.lensfocal, width: focalFieldWidth)

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
                    NumericField(value: $shot.lensfocalEnd, width: focalFieldWidth)

                    Text("mm")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Zoom toggle (off = prime lens, the default).
            let zoomBinding = Binding(
                get: { !shot.lensIsPrime },
                set: { shot.lensIsPrime = !$0 }
            )
            #if os(macOS)
            Toggle("Zoom", isOn: zoomBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize()
                .help("On: zoom lens with a focal range. Off: prime lens with a single focal length.")
            #else
            // A compact switch so the row fits more often before it has to stack.
            HStack(spacing: 10) {
                Text("Zoom").foregroundStyle(.secondary).fixedSize()
                Toggle("", isOn: zoomBinding)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .frame(width: 42, height: 26)
            }
            .help("On: zoom lens with a focal range. Off: prime lens with a single focal length.")
            #endif
        }
    }
    
        case .grip:
    setupRow("Grip") {
        OptionPickerView(
            noun: "grip",
            placeholder: "Select grip",
            sections: ShotType.pickerGroups,
            value: $shot.gripName,
            customKey: "customGrips"
        )
    }

        case .description:
    // Shot description — part of the core shot settings, right under Grip.
    // Vertical axis lets the field grow as the text gets longer.
    HStack(alignment: .top) {
        Text("Description")
            .font(.headline)
            .frame(width: 100, alignment: .leading)

        DebouncedTextField("Describe the shot", text: $shot.extraInfo, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...10)
            .frame(maxWidth: 200)
    }

        }
    }

    // User-added custom fields, listed under Extra info with an "Add Custom Info"
    // menu (a labelled text box for now; more field types can join the menu).
    // Film-length tools live in the Camera Information card (see filmToolsSection).
    @ViewBuilder
    private var customInfoSection: some View {
        ForEach(shot.orderedCustomInfo.filter { $0.kind != "filmstock" }) { item in
            if item.kind == "timeofday" {
                ShotTimeOfDayRow(item: item) { deleteCustomInfo(item) }
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
                addCustomInfo(kind: "timeofday")
            } label: {
                Label("Time of day", systemImage: "sun.horizon")
            }
            Button {
                addCustomInfo(kind: "filmstock")
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
        if kind == "timeofday" { item.value = ShotCustomInfo.timeOfDayPresets.first ?? "" }
        item.shot = shot
        shotModelContext.insert(item)
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
                #if os(iOS)
                Text(pointerMarking ? "Select text in the PDF, then:"
                     : (markLastPhase ? "Tap the last word, then Done"
                                      : "Tap the first word, then Next"))
                    .font(.body)
                #else
                Text("Select text in the PDF, then:")
                    .font(.body)
                #endif
                Spacer(minLength: 0)
                Button("Cancel") {
                    NotificationCenter.default.post(name: .cancelScriptSelection, object: nil)
                }
                .buttonStyle(.bordered)
                #if os(iOS)
                Button(pointerMarking || markLastPhase ? "Done" : "Next") {
                    NotificationCenter.default.post(name: .captureScriptSelection, object: nil)
                }
                .buttonStyle(.borderedProminent)
                #else
                Button("Done") {
                    NotificationCenter.default.post(name: .captureScriptSelection, object: nil)
                }
                .buttonStyle(.borderedProminent)
                #endif
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
                markLastPhase = false
                pointerMarking = note.userInfo?["pointer"] as? Bool ?? false
            }
        } else {
            isMarkingCoverage = false
            markLastPhase = false
            pointerMarking = false
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .scriptSelectionPhaseChanged)) { note in
        markLastPhase = (note.userInfo?["phase"] as? Int ?? 0) == 1
    }
    }

    private var cameraInformationCard: some View {
    sectionCard("CAMERA INFORMATION", gear: { showingCardSettings = true }) {
        // Camera - Always editable
        HStack {
            Text("Camera")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            HStack(spacing: 4) {
                DebouncedTextField("Camera · Format", text: $shot.camera)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onChange(of: shot.camera) { inheritCineStagerSensorWidth() }

                // Show suggestions menu if there are previous values
                if !previousCameraValues.isEmpty {
                    ChipMenu(items: previousCameraValues.map { v in
                        ChipMenuItem(title: v) { shot.camera = v }
                    }, prefersSheetOnPhone: true) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used cameras")
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
                DebouncedTextField("Framelines", text: $shot.framelines)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousFrameLinesValues.isEmpty {
                    ChipMenu(items: previousFrameLinesValues.map { v in
                        ChipMenuItem(title: v) { shot.framelines = v }
                    }, prefersSheetOnPhone: true) {
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
                DebouncedTextField("Lens name", text: $shot.lensPreset)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                // Show suggestions menu if there are previous values
                if !previousLensValues.isEmpty {
                    ChipMenu(items: previousLensValues.map { v in
                        ChipMenuItem(title: v) { shot.lensPreset = v }
                    }, prefersSheetOnPhone: true) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Select from previously used lenses")
                }
            }
        }

        filmToolsSection
    }
    }

    // Film-length calculator tools live here, in Camera Information.
    @ViewBuilder
    private var filmToolsSection: some View {
        ForEach(shot.orderedCustomInfo.filter { $0.kind == "filmstock" }) { item in
            FilmStockRow(item: item) { deleteCustomInfo(item) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The shot number, nickname and size/type/grip already appear in
                // the shots list, so the detail pane goes straight to the cards.

                // Setup + camera, unified into one card.
                combinedDetailCard
                    .padding(.horizontal)

                // Script coverage, as its own card like the references.
                scriptCoverageStandaloneCard
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
            // Tapping/clicking empty space in the editor confirms and dismisses the
            // active text field.
            .contentShape(Rectangle())
            .onTapGesture { PlatformKeyboard.dismiss() }
        }
        .scrollDismissesKeyboard(.interactively)
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
        .sheet(isPresented: $showingCardSettings) {
            if let project = shot.scene?.resolvedProject {
                ShotCardSettingsSheet(project: project)
            }
        }
    }

}

/// Shared card chrome for the shot-detail cards (setup/camera, script coverage),
/// so they match each other and the reference cards.
private struct DetailCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
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
        // iPhone: a popover is too small for the longer Size/Type/Grip lists, so
        // present a sheet (detented, scrollable) where every item fits.
        // iPad: open beside the button (arrow on its trailing edge) so the popover
        // has the full screen height. macOS keeps the below-the-button placement.
        #if os(iOS)
        .applyIf(DeviceLayout.isPhone) { $0.sheet(isPresented: $isPresented) { phoneSheet } }
        .applyIf(!DeviceLayout.isPhone) { $0.popover(isPresented: $isPresented, arrowEdge: .trailing) { popover } }
        #else
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
        #endif
        .alert("Add Custom \(noun.capitalized)", isPresented: $showAdd) {
            TextField("\(noun.capitalized) name", text: $newName)
            Button("Add") { addCustom(newName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a \(noun) name. It'll be saved for use in all your projects.")
        }
    }

    /// The option columns/sections, without the Add/Clear footer.
    @ViewBuilder private var pickerOptions: some View {
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
    }

    private var popover: some View {
        // No fixed height — the popover fits its content, so a short list (sizes)
        // doesn't leave empty space below. On iPad the taller lists (Type) can
        // exceed the available popover height, so the options scroll there while
        // the Add/Clear footer stays pinned.
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            ScrollView {
                pickerOptions.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Tall enough that the built-in Size/Type/Grip lists show in full on any
            // iPad (all are ≥744pt high); only very long custom lists still scroll.
            .frame(maxHeight: 600)
            #else
            pickerOptions
            #endif

            Divider()
            pickerFooter
        }
        .padding(12)
        .frame(width: grouped ? 360 : 240)
        #if os(iOS)
        // Keep it a popover (not a full-screen sheet) even in a compact width.
        .presentationCompactAdaptation(.popover)
        #endif
    }

    /// iPhone: the picker as a detented, scrollable sheet — the whole list fits and
    /// scrolls, unlike a size-constrained popover.
    private var phoneSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                pickerOptions.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            pickerFooter
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The Add-custom / Clear row shown under the options in both presentations.
    private var pickerFooter: some View {
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

/// A whole-number text field that clears when you click/tap into it (so you type
/// fresh instead of editing the old value) and commits every keystroke straight to
/// the binding — so there's no separate "confirm" step (which the iPad number pad,
/// with no Return key, otherwise lacks). Leaving it empty keeps the current value.
private struct NumericField: View {
    @Binding var value: Int
    var width: CGFloat = 60
    var alignment: TextAlignment = .leading
    var placeholder: String = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(alignment)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .focused($focused)
            .onAppear { text = display(value) }
            // Keep the field in sync if the value changes elsewhere (e.g. a CineStager
            // import), but never yank text out from under an active edit.
            .onChange(of: value) { _, newValue in if !focused { text = display(newValue) } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { text = "" }          // clear on focus — type fresh
                else { text = display(value) }      // resync display when leaving
            }
            .onChange(of: text) { _, newText in
                let digits = newText.filter(\.isNumber)
                if digits != newText { text = digits; return }
                if let n = Int(digits) { value = n } // live commit; empty keeps current value
            }
    }

    private func display(_ v: Int) -> String { v == 0 ? "" : String(v) }
}

/// Decimal sibling of `NumericField` (clears on focus, commits live) for `Double`
/// values — allows digits and a single decimal point.
private struct DecimalField: View {
    @Binding var value: Double
    var width: CGFloat = 60
    var alignment: TextAlignment = .leading
    var placeholder: String = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(alignment)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .focused($focused)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, newValue in if !focused { text = display(newValue) } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { text = "" } else { text = display(value) }
            }
            .onChange(of: text) { _, newText in
                let filtered = sanitize(newText)
                if filtered != newText { text = filtered; return }
                if let n = Double(filtered) { value = n } // live commit; empty/"." keeps current
            }
    }

    private func display(_ v: Double) -> String {
        if v == 0 { return "" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }
    /// Digits plus at most one decimal point.
    private func sanitize(_ s: String) -> String {
        var seenDot = false
        return String(s.filter { c in
            if c.isNumber { return true }
            if c == ".", !seenDot { seenDot = true; return true }
            return false
        })
    }
}

struct MetadataView: View {
    let metadata: PhotoMetadata

    /// All metadata as flat label/value pairs. Group headings are omitted on
    /// purpose — each label already reads clearly on its own, and dropping them
    /// lets the pairs flow side by side so the box stays short.
    private var items: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        // Camera (name + format as one) and Focal Length stay adjacent — read together.
        let camera = Shot.combinedCamera(metadata.cameraFamily ?? "", metadata.cameraFormat ?? "")
        if !camera.isEmpty { rows.append(("Camera", camera)) }
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
            // Label above value, wrapping into as many columns as fit — the same
            // layout the map reference's metadata uses, so nothing runs off the
            // edge in a narrow card (iPad, or a narrow Mac window).
            stackedLayout
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

    /// Label above value, wrapping into as many columns as fit — the same layout
    /// the map reference's metadata uses, so nothing runs off the edge in a narrow
    /// card.
    private var stackedLayout: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18, alignment: .topLeading)],
                  alignment: .leading, spacing: 8) {
            ForEach(items, id: \.label) { item in
                stackedPair(item.label, item.value)
            }
        }
    }

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
