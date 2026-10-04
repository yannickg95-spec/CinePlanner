//
//  AppCommands.swift
//  CinePlanner
//
//  The menu bar (and the iPad keyboard-shortcut overlay). Each screen publishes what
//  it can do through focused scene values — the project list, the project editor,
//  the scene map's undo — and the commands act on the window in front, greyed out
//  where an action doesn't apply.
//

import SwiftUI
import SwiftData

// Each screen keeps ONE instance of its commands object (in @State) and publishes
// that, so the focused value is the same object on every redraw. Publishing a fresh
// struct of closures each render made SwiftUI see a change every frame — "FocusedValue
// update tried to update multiple times per frame" — which looped and crashed.

/// What the project list offers the menu bar.
@MainActor @Observable
final class ProjectListCommands {
    @ObservationIgnored var newProject: () -> Void = {}
    @ObservationIgnored var importProject: () -> Void = {}
    @ObservationIgnored var showWalkthrough: () -> Void = {}
}

/// What an open project offers the menu bar.
@MainActor @Observable
final class ProjectEditorCommands {
    @ObservationIgnored var importScript: () -> Void = {}
    @ObservationIgnored var export: () -> Void = {}
    @ObservationIgnored var publish: () -> Void = {}
    @ObservationIgnored var showShotDetails: () -> Void = {}
    @ObservationIgnored var showSceneMap: () -> Void = {}
    @ObservationIgnored var showSchedule: () -> Void = {}
    @ObservationIgnored var startOnSet: () -> Void = {}
}

/// The scene map's own undo history, while the map is on screen. Only the two
/// flags are observed (they grey out Undo / Redo); the actions never change.
@MainActor @Observable
final class MapUndoCommands {
    @ObservationIgnored var undo: () -> Void = {}
    @ObservationIgnored var redo: () -> Void = {}
    var canUndo = false
    var canRedo = false
}

extension FocusedValues {
    @Entry var projectListCommands: ProjectListCommands?
    @Entry var projectEditorCommands: ProjectEditorCommands?
    @Entry var mapUndoCommands: MapUndoCommands?
}

struct CinePlannerCommands: Commands {
    let container: ModelContainer

    @FocusedValue(\.projectListCommands) private var list
    @FocusedValue(\.projectEditorCommands) private var editor
    @FocusedValue(\.mapUndoCommands) private var mapUndo

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("New Project") { list?.newProject() }
                .keyboardShortcut("n")
                .disabled(list == nil)
            Button("Import Project…") { list?.importProject() }
                .keyboardShortcut("o")
                .disabled(list == nil)
            Divider()
            Button("Import Script…") { editor?.importScript() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export…") { editor?.export() }
                .keyboardShortcut("e")
                .disabled(editor == nil)
            Button("Publish to Web…") { editor?.publish() }
                .disabled(editor == nil)
        }

        // Edit: in the scene map ⌘Z walks the map's own history, elsewhere the
        // app-wide (SwiftData) undo.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if let mapUndo { mapUndo.undo() } else { container.mainContext.undoManager?.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(mapUndo.map { !$0.canUndo } ?? false)
            Button("Redo") {
                if let mapUndo { mapUndo.redo() } else { container.mainContext.undoManager?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(mapUndo.map { !$0.canRedo } ?? false)
        }

        // View
        CommandGroup(before: .toolbar) {
            Button("Shot Details") { editor?.showShotDetails() }
                .keyboardShortcut("1")
                .disabled(editor == nil)
            Button("Scene Map") { editor?.showSceneMap() }
                .keyboardShortcut("2")
                .disabled(editor == nil)
            Divider()
            Button("Shooting Schedule…") { editor?.showSchedule() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("On-Set Mode") { editor?.startOnSet() }
                .disabled(editor == nil)
            Divider()
        }

        // Help
        CommandGroup(replacing: .help) {
            Button("CinePlanner Walkthrough") { list?.showWalkthrough() }
                .disabled(list == nil)
            Link("CinePlanner Website", destination: URL(string: "https://cineplannerapp.com")!)
        }
    }
}
