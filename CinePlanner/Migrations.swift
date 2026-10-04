//
//  Migrations.swift
//  CinePlanner
//
//  Versioned schema + migration plan. Today there's a single version whose
//  models are the current ones, so opening an existing store is a no-op (its
//  schema already matches V1). The value is forward-looking: the next time the
//  model structure changes, add a SchemaV2 and a MigrationStage here, and the
//  change becomes explicit and staged rather than an implicit lightweight
//  migration — and StoreBackup snapshots the store right before it runs.
//

import Foundation
import CoreData
import SwiftData

enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self, ShotReference.self, ShotCustomInfo.self,
         ShootingDay.self, ScheduleEntry.self]
    }
}

enum CinePlannerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // Additive, optional-attribute changes (e.g. adding ShotReference.note)
        // are handled by SwiftData's automatic lightweight migration — no explicit
        // stage needed. A distinct SchemaV2 here would need frozen model copies to
        // get a different checksum; adding one that reuses the live types trips
        // "Duplicate version checksums". Add a real staged V2 only for a
        // non-inferrable change (renames, type changes, data transforms).
        []
    }
}

// MARK: - Retiring the old shot media fields

/// Before multiple references per shot (July 2026) a shot held one photo, one video
/// and one map in fixed fields. Those are converted into a ShotReference when their
/// project is opened — so a project nobody has opened since could still keep media
/// only there. This converts every such shot, so a later version can drop the fields
/// (a lightweight migration) without losing anything.
///
/// It waits for the launch's first finished iCloud import: converting, from a stale
/// local copy, a shot another device already converted would duplicate its reference.
@MainActor
enum LegacyMediaSweep {
    private static var observer: NSObjectProtocol?

    static func start(container: ModelContainer) {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            run(in: container.mainContext)   // not signed in to iCloud: nothing to wait for
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            MainActor.assumeIsolated {
                guard let observer else { return }
                NotificationCenter.default.removeObserver(observer)
                Self.observer = nil
                run(in: container.mainContext)
            }
        }
    }

    /// Converts every shot that still holds media in the old fields; returns how many.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Shot>(predicate: #Predicate {
            $0.photo1Data != nil || $0.videoDataLegacy != nil || $0.photo2Data != nil
        })
        guard let shots = try? context.fetch(descriptor), !shots.isEmpty else { return 0 }
        // Housekeeping, not an edit of the user's: keep it out of ⌘Z.
        let undo = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = undo }
        for shot in shots { shot.migrateReferencesIfNeeded() }
        context.saveReporting()
        return shots.count
    }
}
