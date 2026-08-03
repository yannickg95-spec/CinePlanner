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
import SwiftData

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self, ShotReference.self, ShotCustomInfo.self]
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
