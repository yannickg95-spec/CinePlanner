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
//  store's history — our own saves are tagged with `localAuthor`), every model type is
//  re-fetched in the main context, and `generation` is bumped so the views keyed on it
//  redraw with the refreshed values.
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

        let remote = transactions.contains { $0.author != Self.localAuthor && !$0.changes.isEmpty }
        guard remote else { return }
        refreshMainContext()
        generation &+= 1
    }

    /// Re-fetches every model type in the main context, refreshing loaded (clean)
    /// objects in place — parents included, so relationships pick up added/removed
    /// children.
    private func refreshMainContext() {
        guard let context = container?.mainContext else { return }
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
