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
        [Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self, ShotReference.self]
    }
}

enum CinePlannerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No stages yet — one schema version. Add stages here when introducing V2+.
        []
    }
}
