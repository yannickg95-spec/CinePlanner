//
//  SceneMapEditorView+Undo.swift
//  CinePlanner
//
//  The scene map's own undo history.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Undo

    /// Called as an edit is committed (every edit ends in `persist` /
    /// `persistFloorPlan`, a drag only once it's released): the map as it was before
    /// becomes the next undo step.
    func recordCommit() {
        let current = MapHistoryState(doc: doc, floorPlan: floorPlan)
        defer { committedState = current }
        guard let previous = committedState, !previous.sameContent(as: current), !suppressHistory else { return }
        history.record(previous)
    }

    /// Starts the history afresh from the map as it is now — on opening, and when the
    /// map changed from outside (iCloud, a CineStager import), so undo never takes
    /// back anything but this editor's own edits.
    func resetHistory() {
        history.reset()
        committedState = MapHistoryState(doc: doc, floorPlan: floorPlan)
    }

    /// Runs a change that isn't the user's own edit, without making it undoable.
    func withoutHistory(_ body: () -> Void) {
        suppressHistory = true
        body()
        suppressHistory = false
    }

    func undoMap() {
        guard let previous = history.undo(from: MapHistoryState(doc: doc, floorPlan: floorPlan)) else { return }
        restore(previous)
    }

    func redoMap() {
        guard let next = history.redo(from: MapHistoryState(doc: doc, floorPlan: floorPlan)) else { return }
        restore(next)
    }

    /// Puts the map back to `state` and saves it (as a change of its own, so it syncs).
    func restore(_ state: MapHistoryState) {
        doc = state.doc
        floorPlan = state.floorPlan
        committedState = state
        // Selections and in-progress drawing may point at things that are gone.
        selectedIDs = []
        furnitureSelectedIDs = []
        furnitureSelectedID = nil
        arrowSelectedID = nil
        wallSelectedID = nil
        openingSelectedID = nil
        chainLastVertex = nil
        withoutHistory {
            persist()
            persistFloorPlan()
            pruneOrphanedShotCameras()   // a restored camera whose shot is gone
            syncShotLabels()
        }
    }

    /// Writes map data without registering it with the app-wide (SwiftData) undo: the
    /// map keeps its own history, and the two mustn't both replay the same change.
    func writeWithoutGlobalUndo(_ body: () -> Void) {
        let context = scene.modelContext ?? modelContext
        let undo = context.undoManager
        context.undoManager = nil
        body()
        context.undoManager = undo
    }

    /// Undo / redo as a toolbar pill, for touch (and for anyone who prefers a click).
    var undoRedoGroup: some View {
        HStack(spacing: 0) {
            Button(action: undoMap) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: toolbarIconSize, weight: .medium))
                    .frame(width: toolbarCellWidth).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .disabled(!history.canUndo)
            .help("Undo")
            .accessibilityLabel("Undo")
            segmentDivider
            Button(action: redoMap) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: toolbarIconSize, weight: .medium))
                    .frame(width: toolbarCellWidth).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .disabled(!history.canRedo)
            .help("Redo")
            .accessibilityLabel("Redo")
        }
        .buttonStyle(.borderless)
        .modifier(SegmentedGroup(height: toolbarPillHeight))
    }
}

/// One step of the scene map's undo history: the map and its floor plan.
struct MapHistoryState: Equatable {
    var doc: SceneMapDoc
    var floorPlan: FloorPlan

    /// Same map, ignoring the edit timestamp.
    func sameContent(as other: MapHistoryState) -> Bool {
        doc.sameContent(as: other.doc) && floorPlan == other.floorPlan
    }
}
