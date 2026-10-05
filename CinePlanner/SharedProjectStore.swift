//
//  SharedProjectStore.swift
//  CinePlanner
//
//  Shared projects live in a store of their own. The regular store is mirrored to
//  the user's private iCloud database by SwiftData, which can't share; this one
//  isn't mirrored — each project in it syncs through its own iCloud zone instead,
//  which is what can be shared with other people.
//
//  Opening a project from here gives the whole editor this store's context, so the
//  editor itself doesn't need to know. Moving a project in (to share it) or back
//  out goes through ProjectRecords and keeps every object's uid.
//

import Foundation
import SwiftData
import os

enum SharedProjectStore {
    /// Posted when projects arrive in or leave the store.
    static let didChange = Notification.Name("SharedProjectStore.didChange")

    /// Opened on first use.
    static let container: ModelContainer = open()

    private static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "SharedProjects.store") }

    /// The store's context if it's open or exists on disk — without creating an
    /// empty store for someone who has never shared a project.
    static func contextIfPresent() -> ModelContext? {
        if let openContext { return openContext }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        return container.mainContext
    }

    /// The container if something has opened it — for code that must not open it
    /// just to look.
    private(set) static var openContainer: ModelContainer?

    static var openContext: ModelContext? { openContainer?.mainContext }

    /// Whether this project lives here (rather than in the regular store).
    static func contains(_ project: Project) -> Bool {
        guard let openContainer, let context = project.modelContext else { return false }
        return context.container === openContainer
    }

    private static func open() -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config: ModelConfiguration
        if CinePlannerApp.isRunningTests {
            config = ModelConfiguration("SharedProjects", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration("SharedProjects", schema: schema,
                                        url: storeURL,
                                        cloudKitDatabase: .none)
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, migrationPlan: CinePlannerMigrationPlan.self, configurations: [config])
        } catch {
            // Never stop the app over this store: run on an empty in-memory one and
            // say so in the log (the projects come back from iCloud on a fix).
            Log.app.error("Couldn't open the shared projects store: \(error)")
            let memory = ModelConfiguration("SharedProjects", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            container = try! ModelContainer(for: schema, configurations: [memory])
        }
        let context = container.mainContext
        let undo = UndoManager()
        undo.levelsOfUndo = 50
        context.undoManager = undo
        context.author = SyncRefresher.localAuthor     // this device's edits, as in the regular store
        ReadOnlyGate.sharedContext = context
        openContainer = container
        return container
    }

    // MARK: Moving a project

    /// Moves a project into another store — into the shared one to share it, back to
    /// the regular one when sharing stops — keeping every uid. The original is
    /// deleted. Returns the project in its new store. Not undoable.
    @discardableResult
    static func move(_ project: Project, to target: ModelContext) throws -> Project {
        guard let source = project.modelContext, source.container !== target.container else { return project }
        // The shape every record expects, with any old-style shot media converted.
        project.migrateStructureIfNeeded()

        let uid = project.uid
        let records = ProjectRecords.records(for: project, zoneID: ProjectRecords.zoneID(for: project))
        let undo = target.undoManager
        target.undoManager = nil
        defer { target.undoManager = undo }
        ProjectRecords.apply(records, in: target)
        guard let moved = try target.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.uid == uid })).first else {
            throw CocoaError(.coderValueNotFound)
        }
        // This device's layout isn't part of the project's records, but it moves along.
        moved.lastOpenedDate = project.lastOpenedDate
        moved.sceneColumnWidth = project.sceneColumnWidth
        moved.shotColumnWidth = project.shotColumnWidth
        moved.detailColumnWidth = project.detailColumnWidth
        moved.scriptColumnWidth = project.scriptColumnWidth
        moved.scriptSplitFraction = project.scriptSplitFraction
        try target.save()

        source.destructiveDelete { source.deleteProjectGraph(project) }
        NotificationCenter.default.post(name: didChange, object: nil)
        return moved
    }
}
