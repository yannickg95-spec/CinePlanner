//
//  CinePlannerApp.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import SwiftUI
import SwiftData

@main
struct CinePlannerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Project.self,
            Episode.self,
            ScriptVersion.self,
            Scene.self,
            Shot.self,
            ShotReference.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // Apply a queued restore before the store is opened — the only safe
        // moment to overwrite the store files.
        StoreBackup.performPendingRestoreIfNeeded()

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            Self.backfillUIDsIfNeeded(container)
            // Snapshot the (possibly just-restored) store for next time.
            StoreBackup.backupIfNeeded(container: container)
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// The `uid` property is new, so rows that existed before it was added may
    /// share the default value the migration applied. Once, on first launch
    /// after the update, give every object a fresh unique uid. Nothing references
    /// uid externally yet, so reassigning is safe; the guard flag makes it run
    /// exactly once.
    private static func backfillUIDsIfNeeded(_ container: ModelContainer) {
        let key = "didBackfillUIDs_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = ModelContext(container)
        if let objs = try? context.fetch(FetchDescriptor<Project>()) { objs.forEach { $0.uid = UUID().uuidString } }
        if let objs = try? context.fetch(FetchDescriptor<Episode>()) { objs.forEach { $0.uid = UUID().uuidString } }
        if let objs = try? context.fetch(FetchDescriptor<ScriptVersion>()) { objs.forEach { $0.uid = UUID().uuidString } }
        if let objs = try? context.fetch(FetchDescriptor<Scene>()) { objs.forEach { $0.uid = UUID().uuidString } }
        if let objs = try? context.fetch(FetchDescriptor<Shot>()) { objs.forEach { $0.uid = UUID().uuidString } }
        if let objs = try? context.fetch(FetchDescriptor<ShotReference>()) { objs.forEach { $0.uid = UUID().uuidString } }
        try? context.save()

        UserDefaults.standard.set(true, forKey: key)
    }
    
    var body: some SwiftUI.Scene {
        WindowGroup {
            ProjectListView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .modelContainer(sharedModelContainer)
        // Comfortably inside a 1600×1200 display (and typical laptop screens)
        .defaultSize(width: 1440, height: 860)
    }
}

