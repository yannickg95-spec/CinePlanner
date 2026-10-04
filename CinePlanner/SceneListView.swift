//
//  SceneListView.swift
//  CinePlanner
//
//  The scene list of a script version: scenes with their numbers, nicknames and
//  status, reordering, and the scene actions.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

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
        scene.modelContext?.saveReporting()
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
            Button {
                duplicateScene(scene)
            } label: {
                Text("Duplicate Scene")
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
                Text("Increase Scene Number")
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
        scene.modelContext?.saveReporting()
    }
    
    private var totalShotsCount: Int {
        orderedScenes.reduce(0) { $0 + $1.shots.count }
    }

    private func handleDrop(shotIDStrings: [String], toScene targetScene: Scene) {
        Log.app.debug("🎬 Attempting to drop shots into scene \(targetScene.sceneNumber)")

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
                Log.app.notice("⚠️ Could not find shot with ID \(shotIDString)")
                continue
            }
            
            // Don't move if already in target scene
            if source === targetScene {
                Log.app.debug("ℹ️ Shot \(shot.displayNumber) is already in scene \(targetScene.sceneNumber)")
                continue
            }
            
            Log.app.debug("📦 Moving shot \(shot.displayNumber) from scene \(source.sceneNumber) to scene \(targetScene.sceneNumber)")
            
            // Remove from source scene (its map camera and schedule strips included)
            source.forgetShot(uid: shot.uid)
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

    /// Duplicates a whole scene — all its fields, shots (with fresh ids) and scene
    /// map — as a new scene at the end of the list with the next scene number.
    private func duplicateScene(_ scene: Scene) {
        let highestNumber = orderedScenes.map { $0.sceneNumber }.max() ?? 0
        let copy = scene.duplicate()
        copy.sceneNumber = highestNumber + 1
        copy.project = project
        copy.scriptVersion = version

        let currentScenesCount = currentScenes.count
        copy.sortOrder = currentScenesCount
        project.scenes.append(copy)
        // Push archived scenes after the new one, mirroring addScene().
        for (index, oldScene) in oldScenes.enumerated() {
            oldScene.sortOrder = currentScenesCount + 1 + index
        }

        project.modelContext?.saveReporting()
        selectedScenes = [copy.uid]
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
