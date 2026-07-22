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
}

// MARK: - Scene List View

struct SceneListView: View {
    let project: Project
    let version: ScriptVersion?
    @Binding var selectedScenes: Set<Scene>
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
            // Search / filter
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("Search Scene", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            sceneList
        }
    }

    private var sceneList: some View {
        List(selection: $selectedScenes) {
            // Current Scenes Section
            Section {
                ForEach(currentScenes) { scene in
                    sceneRow(for: scene)
                }
                .onDelete { offsets in
                    deleteScenes(at: offsets, from: currentScenes)
                }
                .onMove { source, destination in
                    moveScenes(from: source, to: destination, in: currentScenes)
                }
            } header: {
                Text("Scenes")
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
                    ForEach(oldScenes) { scene in
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
                onDeleteScenes?(orderedScenes.filter { selectedScenes.contains($0) })
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
            // Two lines so a narrow column can't push anything off the edge:
            // title (truncating) above, tags + shot count below.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.headline)
                        .fixedSize()
                    if !scene.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(scene.nickname)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
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
                Label("Edit Scene", systemImage: "pencil")
            }
            if canImportShots {
                Button {
                    onImportShots?(scene)
                } label: {
                    Label("Import Shots from Version…", systemImage: "square.and.arrow.down.on.square")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDeleteScenes?(deletionTargets(for: scene))
            } label: {
                Label(sceneDeleteLabel(for: scene), systemImage: "trash")
            }
        }
    }

    /// Scenes a delete action should affect: the whole selection when the
    /// right-clicked scene is part of it, otherwise just that scene.
    private func deletionTargets(for scene: Scene) -> [Scene] {
        selectedScenes.contains(scene) ? orderedScenes.filter { selectedScenes.contains($0) } : [scene]
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
        
        selectedScenes = [newScene]
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

        selectedScenes.subtract(scenesToDelete)

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

        selectedScenes.subtract(scenesToDelete)

        // Update sortOrder for remaining scenes in this version
        for (index, scene) in orderedScenes.enumerated() {
            scene.sortOrder = index
        }
    }
}

// MARK: - Shot List View

struct ShotListView: View {
    let scene: Scene
    @Binding var selectedShots: Set<Shot>
    var onEditShot: ((Shot) -> Void)? = nil
    var onDeleteShots: (([Shot]) -> Void)? = nil

    var sortedShots: [Shot] {
        scene.shots.sorted { $0.shotNumber < $1.shotNumber }
    }
    
    var body: some View {
        List(selection: $selectedShots) {
            Section {
                ForEach(sortedShots) { shot in
                NavigationLink(value: shot) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.circle.fill")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Shot \(shot.displayNumber)")
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if !shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(shot.nickname)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if shot.size != .none {
                                    if !shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("•")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(shot.size.shortVersion)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    // Show arrow and second size if it exists
                                    if shot.secondSize != .none {
                                        Image(systemName: "arrow.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(shot.secondSize.shortVersion)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Spacer()
                        if shot.hasAnyReferenceMedia {
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        Label("Edit Shot", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDeleteShots?(deletionTargets(for: shot))
                    } label: {
                        Label(shotDeleteLabel(for: shot), systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteShots)
            .onMove(perform: moveShots)
            } header: {
                Text("Shots")
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
        }
        .navigationTitle(scene.project?.filmName ?? "")
        .onDeleteCommand {
            if !selectedShots.isEmpty {
                onDeleteShots?(sortedShots.filter { selectedShots.contains($0) })
            }
        }
    }

    /// Shots a delete action should affect: the whole selection when the
    /// right-clicked shot is part of it, otherwise just that shot.
    private func deletionTargets(for shot: Shot) -> [Shot] {
        selectedShots.contains(shot) ? sortedShots.filter { selectedShots.contains($0) } : [shot]
    }

    private func shotDeleteLabel(for shot: Shot) -> String {
        let count = deletionTargets(for: shot).count
        return count > 1 ? "Delete \(count) Shots" : "Delete Shot"
    }

    private func addShot() {
        // Find the next shot number
        let nextNumber = (sortedShots.last?.shotNumber ?? 0) + 1
        let newShot = Shot(shotNumber: nextNumber)
        newShot.scene = scene
        scene.shots.append(newShot)
        selectedShots = [newShot]
    }
    
    private func deleteShots(at offsets: IndexSet) {
        let shotsToDelete = offsets.map { sortedShots[$0] }
        for shot in shotsToDelete {
            if let index = scene.shots.firstIndex(where: { $0 === shot }) {
                scene.shots.remove(at: index)
            }
        }
        selectedShots.subtract(shotsToDelete)

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

struct ShotDetailView: View {
    @Bindable var shot: Shot
    /// Which photo is open full size, if any.
    @Environment(\.modelContext) private var shotModelContext
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

    // MARK: Visual helpers

    /// Uniform card container for a group of related rows.
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    /// Small accent chip for the header summary (size, type, grip).
    private func headerChip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
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
        Label(shot.references.isEmpty ? "Add Reference Image" : "Add Another Reference Image",
              systemImage: "plus.circle.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func addReference() {
        let next = (shot.references.map(\.sortOrder).max() ?? -1) + 1
        let reference = ShotReference(sortOrder: next)
        reference.shot = shot
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
            .frame(width: 200)
    }
    
    HStack {
        Text("Size")
            .font(.headline)
            .frame(width: 100, alignment: .leading)
        
        HStack(spacing: 8) {
            Menu {
                ForEach(ShotSize.allCases, id: \.self) { size in
                    Button(size.displayName) {
                        shot.size = size
                    }
                }
            } label: {
                HStack {
                    Text(shot.size == .none ? "Select size" : shot.size.displayName)
                        .foregroundStyle(shot.size == .none ? .secondary : .primary)
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
            
            // Plus button (only show when first size is selected and second dropdown is hidden)
            if shot.size != .none && !showSecondSize {
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
                
                Menu {
                    ForEach(ShotSize.allCases, id: \.self) { size in
                        Button(size.displayName) {
                            shot.secondSize = size
                            // Hide second dropdown if none is selected
                            if size == .none {
                                showSecondSize = false
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(shot.secondSize == .none ? "Select size" : shot.secondSize.displayName)
                            .foregroundStyle(shot.secondSize == .none ? .secondary : .primary)
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
                
                // Remove button for second size
                Button {
                    shot.secondSize = .none
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
            Menu {
                ForEach(ShotTypeCategory.allCases, id: \.self) { typeCategory in
                    if typeCategory == .topShot || typeCategory == .pushIn {
                        Divider()
                    }
                    Button(typeCategory.displayName) {
                        shot.typeCategory = typeCategory
                    }
                }
            } label: {
                HStack {
                    Text(shot.typeCategory == .none ? "Select type" : shot.typeCategory.displayName)
                        .foregroundStyle(shot.typeCategory == .none ? .secondary : .primary)
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
            
            // Plus button (only show when first type is selected and second dropdown is hidden)
            if shot.typeCategory != .none && !showSecondType {
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
                Menu {
                    ForEach(ShotTypeCategory.allCases, id: \.self) { typeCategory in
                        if typeCategory == .topShot || typeCategory == .pushIn {
                            Divider()
                        }
                        Button(typeCategory.displayName) {
                            shot.secondTypeCategory = typeCategory
                            // Hide second dropdown if none is selected
                            if typeCategory == .none {
                                showSecondType = false
                                showThirdType = false
                                shot.thirdTypeCategory = .none
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(shot.secondTypeCategory == .none ? "Select type" : shot.secondTypeCategory.displayName)
                            .foregroundStyle(shot.secondTypeCategory == .none ? .secondary : .primary)
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
                
                // Plus button for third type (only show when second type is selected and third is hidden)
                if shot.secondTypeCategory != .none && !showThirdType {
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
                        shot.secondTypeCategory = .none
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
                Menu {
                    ForEach(ShotTypeCategory.allCases, id: \.self) { typeCategory in
                        if typeCategory == .topShot || typeCategory == .pushIn {
                            Divider()
                        }
                        Button(typeCategory.displayName) {
                            shot.thirdTypeCategory = typeCategory
                            // Hide third dropdown if none is selected
                            if typeCategory == .none {
                                showThirdType = false
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(shot.thirdTypeCategory == .none ? "Select type" : shot.thirdTypeCategory.displayName)
                            .foregroundStyle(shot.thirdTypeCategory == .none ? .secondary : .primary)
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
                
                // Remove button for third type
                Button {
                    shot.thirdTypeCategory = .none
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
            Toggle("Zoom lens", isOn: Binding(
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
        
        Menu {
            ForEach(ShotType.allCases, id: \.self) { type in
                Button(type.displayName) {
                    shot.type = type
                }
            }
        } label: {
            HStack {
                Text(shot.type == .none ? "Select grip" : shot.type.displayName)
                    .foregroundStyle(shot.type == .none ? .secondary : .primary)
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
            .frame(width: 200)
    }

    }
    }

    private var scriptCoverageCard: some View {
    sectionCard("SCRIPT COVERAGE") {
        HStack {
        Button {
            // Signal to enter text selection mode
            NotificationCenter.default.post(
                name: .startScriptTextSelection,
                object: nil,
                userInfo: ["shot": shot]
            )
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
                    .frame(width: 200)

                // Show suggestions menu if there are previous values
                if !previousCameraValues.isEmpty {
                    Menu {
                        ForEach(previousCameraValues, id: \.self) { camera in
                            Button(camera) {
                                shot.camera = camera
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                    .frame(width: 200)

                // Show suggestions menu if there are previous values
                if !previousFormatValues.isEmpty {
                    Menu {
                        ForEach(previousFormatValues, id: \.self) { format in
                            Button(format) {
                                shot.format = format
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Select from previously used formats")
                }
            }
        }

        // Framelines - Only show if metadata is available
        if !shot.framelines.isEmpty {
            HStack {
                Text("Framelines")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)

                Text(shot.framelines)
                    .font(.body)
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
                    .frame(width: 200)

                // Show suggestions menu if there are previous values
                if !previousLensValues.isEmpty {
                    Menu {
                        ForEach(previousLensValues, id: \.self) { lens in
                            Button(lens) {
                                shot.lensPreset = lens
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Select from previously used lenses")
                }
            }
        }
    }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shot \(shot.displayNumber)")
                        .font(.largeTitle)
                        .bold()

                    HStack(spacing: 8) {
                        if !shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(shot.nickname)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        // At-a-glance summary chips
                        if shot.size != .none {
                            headerChip(shot.secondSize == .none
                                       ? shot.size.shortVersion
                                       : "\(shot.size.shortVersion) → \(shot.secondSize.shortVersion)")
                        }
                        if shot.typeCategory != .none {
                            headerChip(shot.typeCategory.shortDisplayName)
                        }
                        if shot.type != .none {
                            headerChip(shot.type.displayName)
                        }
                    }
                }
                .padding(.horizontal)
                
                // Settings, grouped into cards
                VStack(alignment: .leading, spacing: 16) {
                    // Side by side when the details pane is wide enough for both,
                    // stacked when it isn't.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            shotSetupCard
                            // Shot setup is the taller card, so coverage fills the
                            // space beneath camera information rather than leaving a gap.
                            VStack(alignment: .leading, spacing: 16) {
                                cameraInformationCard
                                scriptCoverageCard
                            }
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            shotSetupCard
                            cameraInformationCard
                            scriptCoverageCard
                        }
                    }
                }
                .padding(.horizontal)
                
                // References: each is a photo or a video with its own optional
                // top-down map. A shot can carry as many as it needs.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(shot.orderedReferences.enumerated()), id: \.element.persistentModelID) { index, reference in
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
            showSecondType = shot.secondTypeCategory != .none
            // Show third type dropdown if a third type is already set
            showThirdType = shot.thirdTypeCategory != .none
            // Show second size dropdown if a second size is already set
            showSecondSize = shot.secondSize != .none
        }
        .onChange(of: shot.id) { _, _ in
            // Each reference card owns its own pickers now; only the
            // shot-level toggles need resetting here.
            showSecondType = shot.secondTypeCategory != .none
            showThirdType = shot.thirdTypeCategory != .none
            showSecondSize = shot.secondSize != .none
        }
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
                    VideoPlayer(player: player)
                        .frame(height: 260)
                        .frame(maxWidth: 700)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.85))
                        .frame(height: 260)
                        .frame(maxWidth: 700)
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
        if let horizon = metadata.horizon { rows.append(("Horizon", String(format: "%.1f\u{00B0}", horizon))) }
        if let tilt = metadata.tilt { rows.append(("Tilt", String(format: "%.1f\u{00B0}", tilt))) }
        if let captureType = metadata.captureType { rows.append(("Capture", captureType)) }
        if let date = metadata.dateTimeOriginal {
            rows.append(("Date", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)))
        }
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
                .frame(minWidth: 200, alignment: .leading)
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
                .lineLimit(1)
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

            // Rows flow across the full width so the box stays short
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18, alignment: .topLeading)],
                      alignment: .leading, spacing: 4) {
                // Camera Physical Size (width x length)
                if let width = metadata.cameraPhysicalWidth, let length = metadata.cameraPhysicalLength {
                    let sizeString = String(format: "%.1fcm × %.1fcm", width, length)
                    MetadataRow(label: "Camera Size", value: sizeString, labelWidth: 132)
                } else if let width = metadata.cameraPhysicalWidth {
                    MetadataRow(label: "Camera Width", value: String(format: "%.1fcm", width), labelWidth: 132)
                } else if let length = metadata.cameraPhysicalLength {
                    MetadataRow(label: "Camera Length", value: String(format: "%.1fcm", length), labelWidth: 132)
                }

                // Location Dimensions (width x length only)
                if let width = metadata.locationWidth, let length = metadata.locationLength {
                    let dimensionsString = String(format: "%.2fm × %.2fm", width, length)
                    MetadataRow(label: "Location Dimensions", value: dimensionsString, labelWidth: 132)
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
}
