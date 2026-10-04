//
//  SceneMapEditorView+Persistence.swift
//  CinePlanner
//
//  Saving the scene map and keeping the open editor in step with the store (iCloud
//  imports, merges, shots that changed underneath it).
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    func persistFloorPlan() {
        recordCommit()
        // Only write a real change. An unconditional write (e.g. on leaving the editor)
        // re-sent this device's possibly outdated copy and overwrote another device's
        // newer plan in iCloud.
        let stored = FloorPlan.load(from: storeScene()?.sceneFloorPlanJSON ?? scene.sceneFloorPlanJSON)
        guard floorPlan != stored else { return }
        writeWithoutGlobalUndo {
            scene.sceneFloorPlanJSON = floorPlan.jsonString
            saveContext()
        }
    }

    func persist() {
        // Only write a real change, compared with what's actually in the store (not the
        // UI context's copy, which iCloud imports don't refresh). An unconditional write
        // — `onDisappear` saved every time the map was left — re-sent this device's
        // stale copy and overwrote the other device's newer edits in iCloud.
        recordCommit()
        let stored = SceneMapDoc.load(from: storeScene()?.sceneMapJSON ?? scene.sceneMapJSON)
        guard !doc.sameContent(as: stored) else { return }
        writeWithoutGlobalUndo {
            doc = scene.storeSceneMap(doc)   // stamps what changed, for merging
            saveContext()
        }
    }

    /// This scene as it is in the store right now, read through a fresh context. The
    /// UI's `scene` lives in the main context, whose copy isn't refreshed when iCloud
    /// imports another device's edits — so it can be older than the store.
    func storeScene() -> Scene? {
        let id = scene.persistentModelID
        let context = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<Scene>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Brings the open editor up to date with the store after an iCloud import (or on
    /// opening): shows another device's map changes and floor plan. When the two copies
    /// of the map differ they're merged item by item (SceneMapMerge) — and if ours holds
    /// changes the store lacks (the other device saved over them), the merge is written
    /// back so it reaches iCloud too.
    func reloadFromStoreIfNewer() {
        guard let fresh = storeScene() else { return }

        let incoming = SceneMapDoc.load(from: fresh.sceneMapJSON)
        if !incoming.sameContent(as: doc) {
            let merged = SceneMapMerge.merge(doc, incoming)
            let showsOtherChanges = !merged.sameContent(as: doc)
            if SceneMapMerge.addsTo(incoming, merged) {
                doc = merged
                writeWithoutGlobalUndo {
                    doc = scene.storeSceneMap(doc)
                    saveContext()
                }
            } else {
                doc = incoming
                // Keep the UI context's copy in step with the store.
                if scene.sceneMapJSON != fresh.sceneMapJSON { scene.sceneMapJSON = fresh.sceneMapJSON }
                SceneMapShadow.save(incoming, for: scene.uid)
            }
            selectedIDs = selectedIDs.filter { id in doc.elements.contains { $0.id == id } }
            furnitureSelectedIDs = furnitureSelectedIDs.filter { id in doc.furniture.contains { $0.id == id } }
            // Another device's edit: undo must never take it back.
            if showsOtherChanges { resetHistory() }
        }

        // The floor plan: take the store's (unless we're mid-drawing it).
        let incomingPlan = FloorPlan.load(from: fresh.sceneFloorPlanJSON)
        if !isDrawing, incomingPlan != floorPlan {
            floorPlan = incomingPlan
            resetHistory()
            if scene.sceneFloorPlanJSON != fresh.sceneFloorPlanJSON { scene.sceneFloorPlanJSON = fresh.sceneFloorPlanJSON }
        }

        // The map's settings. Sun edits are saved as they're made, so the store's
        // copy is never older than ours.
        let incomingSun = fresh.sunSettings
        if incomingSun != sun { sun = incomingSun }
        // The background's placement — unless it's being aligned here right now.
        if !isBackgroundAdjustMode, fresh.sceneMapBackgroundTransform != bgTransform {
            bgTransform = fresh.sceneMapBackgroundTransform
        }
        if fresh.sceneMapMetersWide != mapMetersWide { mapMetersWide = fresh.sceneMapMetersWide }
        if fresh.sceneMapCameraSizeMeters != mapCameraMeters { mapCameraMeters = fresh.sceneMapCameraSizeMeters }
    }

    /// Flushes the store. Uses the environment context (never nil, unlike a
    /// detached model's) and logs failures instead of silently dropping them.
    func saveContext() {
        let context = scene.modelContext ?? modelContext
        do {
            try context.save()
        } catch {
            Log.sceneMap.notice("⚠️ Scene map save failed: \(error)")
        }
    }

    /// The label to show for an element: a shot-linked camera follows the shot's
    /// current number; everything else uses its own stored label.
    func resolvedLabel(for element: MapElement) -> String {
        if let uid = element.shotUID,
           let shot = scene.shots.first(where: { $0.uid == uid }) {
            return shot.displayNumber
        }
        return element.label
    }

    /// Drops shot-linked cameras whose shot no longer exists (deleted from the
    /// shot list), keeping the open editor consistent with the model.
    func pruneOrphanedShotCameras() {
        // If the whole map was just cleared from under us (e.g. "Clear Scene"),
        // don't resurrect the stale in-memory doc — reset it to match.
        let stored = SceneMapDoc.load(from: scene.sceneMapJSON)
        if stored.isEmpty && (scene.sceneMapJSON == nil || !stored.removed.isEmpty) {
            if !doc.isEmpty { doc = stored; selectedIDs = []; furnitureSelectedIDs = [] }
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
        withoutHistory { persist() }
    }

    /// Refresh stored labels of shot-linked cameras to their shot's current
    /// number (so the saved map + archive stay correct even when rendered
    /// without a scene, and as a fallback if the shot is later deleted).
    func syncShotLabels() {
        var changed = false
        for index in doc.elements.indices {
            guard let uid = doc.elements[index].shotUID,
                  let shot = scene.shots.first(where: { $0.uid == uid }),
                  doc.elements[index].label != shot.displayNumber else { continue }
            doc.elements[index].label = shot.displayNumber
            changed = true
        }
        if changed { withoutHistory { persist() } }
    }
}
