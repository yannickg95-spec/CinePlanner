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
    static let recoveryMessageKey = "storeRecoveryMessage"

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        // Sync the store across the user's Macs via CloudKit. An explicit private
        // container (not .automatic) because the entitlement also lists CineStager's
        // CloudDocuments container — .automatic could pick the wrong one. The models
        // are CloudKit-compatible (every attribute optional or defaulted).
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                        cloudKitDatabase: .private("iCloud.YannickGiraud.CinePlanner"))

        // Before the store is opened (the only safe moment to touch its files):
        // apply a queued restore, then snapshot the last good state ahead of any
        // migration this launch runs.
        StoreBackup.performPendingRestoreIfNeeded()
        StoreBackup.backupBeforeOpening()

        func open() throws -> ModelContainer {
            try ModelContainer(for: schema, migrationPlan: CinePlannerMigrationPlan.self, configurations: [config])
        }
        func finish(_ container: ModelContainer) -> ModelContainer {
            StoreBackup.recordStoreURL(container)
            Self.backfillUIDsIfNeeded(container)
            StoreBackup.backupIfNeeded(container: container)
            return container
        }

        do {
            return finish(try open())
        } catch {
            // The store won't open — corruption, an interrupted write, or a bad
            // migration. Recover instead of crashing.
            // 1. Restore the most recent backup and retry.
            if let latest = StoreBackup.listBackups().first,
               StoreBackup.restoreNow(latest),
               let container = try? open() {
                Self.setRecoveryMessage("Your data couldn't be opened, so it was restored from the most recent backup (\(latest.date.formatted(date: .abbreviated, time: .shortened))).")
                return finish(container)
            }
            // 2. Set the unreadable store aside and start fresh, so the app opens.
            //    The real data is quarantined and still lives in Backups.
            StoreBackup.quarantineUnreadableStore()
            if let container = try? open() {
                Self.setRecoveryMessage("Your data couldn't be opened and no backup could be restored automatically. It's been set aside safely — use “Restore from Backup…” to recover a snapshot.")
                return finish(container)
            }
            // 3. Even a fresh store won't open — the environment itself is broken.
            fatalError("Could not open or recover the data store: \(error)")
        }
    }()

    init() {
        // Enable undo/redo (⌘Z / ⇧⌘Z) for model edits. Capped so a long editing
        // session's history can't grow without bound.
        let undo = UndoManager()
        undo.levelsOfUndo = 50
        sharedModelContainer.mainContext.undoManager = undo
    }

    private static func setRecoveryMessage(_ message: String) {
        UserDefaults.standard.set(message, forKey: recoveryMessageKey)
    }

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
        .commands {
            // Route the standard Edit ▸ Undo/Redo (⌘Z / ⇧⌘Z) to SwiftData's
            // context undo manager, so edits can be reversed.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { sharedModelContainer.mainContext.undoManager?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { sharedModelContainer.mainContext.undoManager?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

