//
//  SyncRefresher.swift
//  CinePlanner
//
//  Keeps the UI's ModelContext in step with what iCloud imports.
//
//  SwiftData doesn't do this on its own (verified in isolated tests):
//  • When another context saves — which is what a CloudKit import is — objects
//    already loaded in the main context keep their old values, and views observing
//    them get no update.
//  • Worse, the next save of such a stale object (even of an unrelated field, e.g.
//    `lastOpenedDate`) writes ALL its old values back, reverting the other device's
//    edits in the store and sending that revert to iCloud.
//  • A fresh fetch in the main context refreshes loaded objects in place (clean ones
//    only), and a to-many relationship (scene.shots) only picks up a remotely added
//    child once its parent is re-fetched.
//
//  So after every import that brought changes from another device (read from the
//  store's history — our own saves are tagged with `localAuthor`), the objects it
//  changed are re-fetched in the main context — with their parents, and in full for
//  the parents of deleted objects — and `generation` is bumped so the views keyed on
//  it redraw with the refreshed values. Scene maps the import changed are first merged
//  with this device's own changes (SceneMapSync), which a whole-field import would
//  otherwise overwrite.
//

import Foundation
import CoreData
import SwiftData
import Observation

@MainActor @Observable
final class SyncRefresher {
    static let shared = SyncRefresher()

    /// Bumped after an iCloud import that changed data, so views keyed on it redraw.
    private(set) var generation = 0

    /// Author stamped on the main context's saves, to tell them apart from imports.
    static let localAuthor = "CinePlanner.main"

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var lastToken: DefaultHistoryToken?
    @ObservationIgnored private let startDate = Date()
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {}

    /// Something outside the regular store's imports changed data on screen (a
    /// shared project's sync): redraw the same way.
    func noteExternalChanges() { generation &+= 1 }

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        container.mainContext.author = Self.localAuthor
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            MainActor.assumeIsolated { self?.refreshAfterImport() }
        }
    }

    /// Reads the store's history since the last check; if anything was changed by
    /// someone other than the main context (i.e. an iCloud import), refreshes the main
    /// context and bumps `generation`.
    private func refreshAfterImport() {
        guard let container else { return }
        let historyContext = ModelContext(container)
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = lastToken {
            descriptor.predicate = #Predicate { $0.token > token }
        } else {
            // First check this launch: only what happened since the app started.
            let since = startDate
            descriptor.predicate = #Predicate { $0.timestamp > since }
        }
        guard let transactions = try? historyContext.fetchHistory(descriptor),
              let newest = transactions.last else { return }
        lastToken = newest.token

        let remoteChanges = transactions
            .filter { $0.author != Self.localAuthor }
            .flatMap(\.changes)
        guard !remoteChanges.isEmpty else { return }
        Self.refresh(remoteChanges, in: container.mainContext)
        SceneMapSync.reconcile(sceneIDs: Self.changedScenes(in: remoteChanges), in: container.mainContext)
        generation &+= 1
    }

    /// Refreshes what the imported changes touched, instead of re-fetching every
    /// object of every type (which grew with the size of the whole library):
    /// • inserted / updated objects are re-fetched by id — and so are their parents,
    ///   since a to-many (scene.shots) only shows an added child once the parent is
    ///   re-fetched;
    /// • for a deletion the parent can't be found any more (the object is gone), so
    ///   the parent *types* are re-fetched in full, as before.
    /// Anything unrecognised falls back to the full refresh.
    static func refresh(_ changes: [HistoryChange], in context: ModelContext) {
        var changed: [String: Set<PersistentIdentifier>] = [:]
        var deleted: Set<String> = []
        for change in changes {
            switch change {
            case .insert(let insert):
                changed[insert.changedPersistentIdentifier.entityName, default: []].insert(insert.changedPersistentIdentifier)
            case .update(let update):
                changed[update.changedPersistentIdentifier.entityName, default: []].insert(update.changedPersistentIdentifier)
            case .delete(let delete):
                deleted.insert(delete.changedPersistentIdentifier.entityName)
            @unknown default:
                refreshEverything(in: context); return
            }
        }
        let known: Set<String> = ["Project", "Episode", "ScriptVersion", "Scene", "Shot", "ShotReference",
                                  "ShotCustomInfo", "ShootingDay", "ScheduleEntry"]
        guard Set(changed.keys).union(deleted).isSubset(of: known) else { refreshEverything(in: context); return }

        func refetch<T: PersistentModel>(_ type: T.Type, _ ids: Set<PersistentIdentifier>) -> [T] {
            guard !ids.isEmpty else { return [] }
            return (try? context.fetch(FetchDescriptor<T>(predicate: #Predicate { ids.contains($0.persistentModelID) }))) ?? []
        }
        func ids(_ entity: String) -> Set<PersistentIdentifier> { changed[entity] ?? [] }

        // Children first, collecting the parents to re-fetch after them.
        var shots = ids("Shot"), scenes = ids("Scene"), days = ids("ShootingDay")
        var versions = ids("ScriptVersion"), episodes = ids("Episode"), projects = ids("Project")
        for r in refetch(ShotReference.self, ids("ShotReference")) { if let s = r.shot { shots.insert(s.persistentModelID) } }
        for i in refetch(ShotCustomInfo.self, ids("ShotCustomInfo")) { if let s = i.shot { shots.insert(s.persistentModelID) } }
        for e in refetch(ScheduleEntry.self, ids("ScheduleEntry")) {
            if let d = e.day { days.insert(d.persistentModelID) }
            if let s = e.scene { scenes.insert(s.persistentModelID) }
        }
        for shot in refetch(Shot.self, shots) { if let s = shot.scene { scenes.insert(s.persistentModelID) } }
        for day in refetch(ShootingDay.self, days) { if let v = day.scriptVersion { versions.insert(v.persistentModelID) } }
        for scene in refetch(Scene.self, scenes) {
            if let v = scene.scriptVersion { versions.insert(v.persistentModelID) }
            if let p = scene.project { projects.insert(p.persistentModelID) }
        }
        for version in refetch(ScriptVersion.self, versions) {
            if let e = version.episode { episodes.insert(e.persistentModelID) }
            if let p = version.project { projects.insert(p.persistentModelID) }
        }
        for episode in refetch(Episode.self, episodes) { if let p = episode.project { projects.insert(p.persistentModelID) } }
        _ = refetch(Project.self, projects)

        // Deletions: re-fetch the parent types in full, so their lists drop the child.
        func refetchAll<T: PersistentModel>(_ type: T.Type) { _ = try? context.fetch(FetchDescriptor<T>()) }
        if !deleted.isDisjoint(with: ["ShotReference", "ShotCustomInfo"]) { refetchAll(Shot.self) }
        if deleted.contains("Shot") { refetchAll(Scene.self) }
        if deleted.contains("ScheduleEntry") { refetchAll(ShootingDay.self); refetchAll(Scene.self) }
        if !deleted.isDisjoint(with: ["ShootingDay", "Scene"]) { refetchAll(ScriptVersion.self) }
        if !deleted.isDisjoint(with: ["Scene", "ScriptVersion", "Episode"]) { refetchAll(Project.self) }
        if deleted.contains("ScriptVersion") { refetchAll(Episode.self) }
    }

    /// The scenes that were inserted or changed (their maps may need merging).
    static func changedScenes(in changes: [HistoryChange]) -> Set<PersistentIdentifier> {
        var ids: Set<PersistentIdentifier> = []
        for change in changes {
            switch change {
            case .insert(let insert) where insert.changedPersistentIdentifier.entityName == "Scene":
                ids.insert(insert.changedPersistentIdentifier)
            case .update(let update) where update.changedPersistentIdentifier.entityName == "Scene":
                ids.insert(update.changedPersistentIdentifier)
            default:
                break
            }
        }
        return ids
    }

    /// Re-fetches every model type in the main context — the fallback when the
    /// changes can't be narrowed down.
    static func refreshEverything(in context: ModelContext) {
        func refetch<T: PersistentModel>(_ type: T.Type) { _ = try? context.fetch(FetchDescriptor<T>()) }
        refetch(Project.self)
        refetch(Episode.self)
        refetch(ScriptVersion.self)
        refetch(Scene.self)
        refetch(Shot.self)
        refetch(ShotReference.self)
        refetch(ShotCustomInfo.self)
        refetch(ShootingDay.self)
        refetch(ScheduleEntry.self)
    }
}
