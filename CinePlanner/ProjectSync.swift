//
//  ProjectSync.swift
//  CinePlanner
//
//  Syncs the shared store's projects with iCloud, each in a zone of its own: the
//  projects this account owns in its private database (those zones are what gets
//  shared), the projects shared with it in the shared database. One CKSyncEngine
//  per database; the decisions are ProjectSyncCore's.
//
//  The engine schedules its own syncs "when conditions are good", which is too
//  slow for working together, so changes go out a moment after an edit and a push
//  from iCloud fetches right away (with a fetch on returning to the app, and every
//  half minute while a shared project is open, as a safety net).
//
//  The private database also holds SwiftData's zone with every regular project;
//  the private engine leaves it alone.
//
//  Debug builds only until sharing is finished (`ProjectSharing.isEnabled`).
//

import Foundation
import CloudKit
import SwiftData
import os

enum ProjectSharing {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}

@MainActor @Observable
final class ProjectSync {
    static let shared = ProjectSync()

    /// A problem the user should hear about (a full iCloud, say); nil when fine.
    private(set) var problem: String?

    @ObservationIgnored let core = ProjectSyncCore(
        existingStore: { SharedProjectStore.contextIfPresent()?.container },
        store: { SharedProjectStore.container },
        mainStore: { ProjectSync.shared.mainContainer })

    /// Made on start: creating it without the iCloud entitlement (the unsigned test
    /// host) traps, and nothing here runs before start anyway.
    @ObservationIgnored private var ckContainer: CKContainer?
    @ObservationIgnored private var mainContainer: ModelContainer?
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var sendTasks: [CKDatabase.Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private var bookSaveTask: Task<Void, Never>?

    /// SwiftData's zone in the private database — the regular store's mirror.
    private static let swiftDataZone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")

    private init() {}

    // MARK: Starting

    func start(mainContainer: ModelContainer) {
        guard ProjectSharing.isEnabled, privateEngine == nil else { return }
        self.mainContainer = mainContainer
        ckContainer = CKContainer(identifier: "iCloud.YannickGiraud.CinePlanner")
        core.book = Self.loadBook()
        makeEngines()
        // Every save in the shared store: what changed goes out.
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                              queue: .main) { note in
            let container = (note.object as? ModelContext)?.container
            MainActor.assumeIsolated {
                guard let container, container === SharedProjectStore.openContainer else { return }
                ProjectSync.shared.collectLocalChanges()
            }
        }
        collectLocalChanges()   // anything saved while sync wasn't running
    }

    private func makeEngines() {
        guard let ckContainer else { return }
        privateEngine = CKSyncEngine(.init(database: ckContainer.privateCloudDatabase,
                                           stateSerialization: Self.loadEngineState(.private), delegate: self))
        sharedEngine = CKSyncEngine(.init(database: ckContainer.sharedCloudDatabase,
                                          stateSerialization: Self.loadEngineState(.shared), delegate: self))
    }

    private func engine(_ scope: CKDatabase.Scope) -> CKSyncEngine? {
        scope == .shared ? sharedEngine : privateEngine
    }

    // MARK: Here → there

    func collectLocalChanges() {
        let changes = core.collectLocalChanges()
        queue(changes)
    }

    /// Starts syncing a project of ours that's new to the shared store: every
    /// object goes up, into a zone of its own.
    func startSyncing(_ project: Project) {
        queue(core.markWholeProject(project))
    }

    private func queue(_ changes: [LocalRecordChange]) {
        scheduleBookSave()
        guard !changes.isEmpty else { return }
        for scope in Set(changes.map(\.scope)) {
            guard let engine = engine(scope) else { continue }
            let ofScope = changes.filter { $0.scope == scope }
            let zones = Set(ofScope.compactMap(\.zoneToCreate))
            if !zones.isEmpty {
                engine.state.add(pendingDatabaseChanges: zones.map { .saveZone(CKRecordZone(zoneID: $0)) })
            }
            let doomed = Set(ofScope.compactMap(\.zoneToDelete))
            if !doomed.isEmpty {
                engine.state.add(pendingDatabaseChanges: doomed.map { .deleteZone($0) })
            }
            engine.state.add(pendingRecordZoneChanges: ofScope.compactMap(\.change))
            sendSoon(scope)
        }
    }

    private func sendSoon(_ scope: CKDatabase.Scope) {
        sendTasks[scope]?.cancel()
        sendTasks[scope] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            do { try await engine(scope)?.sendChanges() }
            catch { Log.sync.error("Send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: There → here

    func fetchNow() async {
        do {
            try await privateEngine?.fetchChanges()
            try await sharedEngine?.fetchChanges()
        } catch {
            Log.sync.error("Fetch failed: \(error.localizedDescription)")
        }
    }

    func receivedPush(scope: CKDatabase.Scope?) {
        Task {
            do {
                switch scope {
                case .private: try await privateEngine?.fetchChanges()
                case .shared: try await sharedEngine?.fetchChanges()
                default: await fetchNow()
                }
            } catch {
                Log.sync.error("Fetch after a push failed: \(error.localizedDescription)")
            }
        }
    }

    /// While a shared project is open: a fetch every half minute, for pushes that
    /// don't arrive.
    func keepFresh(while project: Project) async {
        guard privateEngine != nil, SharedProjectStore.contains(project) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            await fetchNow()
        }
    }

    /// Joins a project someone shared with this account.
    func accept(_ metadata: CKShare.Metadata) async throws {
        guard let ckContainer else { return }
        _ = try await ckContainer.accept(metadata)
        let zoneID = metadata.share.recordID.zoneID
        core.book.sharedZoneOwners[zoneID.zoneName] = zoneID.ownerName
        scheduleBookSave()
        try await sharedEngine?.fetchChanges()
    }

    // MARK: Engine events

    fileprivate func handle(_ event: CKSyncEngine.Event, scope: CKDatabase.Scope) {
        switch event {
        case .stateUpdate(let update):
            Self.saveEngineState(update.stateSerialization, scope)

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedDatabaseChanges(let changes):
            for modification in changes.modifications where scope == .shared {
                core.book.sharedZoneOwners[modification.zoneID.zoneName] = modification.zoneID.ownerName
            }
            for deletion in changes.deletions where deletion.zoneID.zoneName.hasPrefix("Project-") {
                if scope == .private {
                    core.ownZoneDeleted(deletion.zoneID)
                } else {
                    core.sharedZoneDeleted(deletion.zoneID)
                }
                projectsChanged()
            }
            scheduleBookSave()

        case .fetchedRecordZoneChanges(let changes):
            let records = changes.modifications.map(\.record)
            let deletions = changes.deletions.map { (recordType: $0.recordType, recordID: $0.recordID) }
            if core.applyRemote(records, deletions: deletions) { projectsChanged() }
            if !records.isEmpty || !deletions.isEmpty { SyncRefresher.shared.noteExternalChanges() }
            scheduleBookSave()

        case .sentDatabaseChanges(let sent):
            for zone in sent.savedZones { core.book.createdZones.insert(zone.zoneID.zoneName) }
            for failure in sent.failedZoneSaves {
                Log.sync.error("Couldn't create zone \(failure.zone.zoneID.zoneName): \(failure.error.localizedDescription)")
            }
            scheduleBookSave()

        case .sentRecordZoneChanges(let sent):
            sent.savedRecords.forEach(core.didSave)
            sent.deletedRecordIDs.forEach(core.didDelete)
            for failure in sent.failedRecordSaves { handleFailedSave(failure, scope: scope) }
            scheduleBookSave()

        default:
            break
        }
    }

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                  scope: CKDatabase.Scope) {
        let id = failure.record.recordID
        switch failure.error.code {
        case .serverRecordChanged:
            // Someone saved first: theirs, with our unsent fields on top, goes again.
            guard let server = failure.error.serverRecord else { return }
            if core.resolveConflict(server: server) {
                engine(scope)?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                sendSoon(scope)
            }
            SyncRefresher.shared.noteExternalChanges()

        case .zoneNotFound, .userDeletedZone:
            if scope == .private {
                // Our zone isn't there (yet, or any more): make it, send everything.
                guard let context = SharedProjectStore.openContext,
                      let project = RecordSchemas.project.fetch(context, String(id.zoneID.zoneName.dropFirst("Project-".count)))
                else { return }
                startSyncing(project)
            } else {
                core.sharedZoneDeleted(id.zoneID)
                projectsChanged()
            }

        case .unknownItem:
            // Gone on the server: send it as new (a deletion from elsewhere, still
            // to be fetched, removes it here instead).
            core.book.records[id.recordName]?.systemFields = nil
            core.book.pendingFields[id.recordName] = ProjectSyncCore.allFields
            engine(scope)?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])

        case .quotaExceeded:
            problem = "Your iCloud storage is full, so changes to shared projects can't be sent. Free up space in iCloud and they'll go out."

        case .permissionFailure:
            problem = "You can view this shared project but not change it."

        default:
            Log.sync.error("Save failed (\(failure.error.code.rawValue)): \(failure.error.localizedDescription)")
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn(let user):
            if let previous = core.book.userRecordName, previous != user.recordName { resetForNewAccount() }
            core.book.userRecordName = user.recordName
        case .switchAccounts(_, let user):
            resetForNewAccount()
            core.book.userRecordName = user.recordName
        case .signOut:
            break   // keep what's here; it syncs again when the same account returns
        @unknown default:
            break
        }
        scheduleBookSave()
    }

    /// Another iCloud account: the previous one's shared projects go, sync starts over.
    private func resetForNewAccount() {
        core.reset()
        Self.saveEngineState(nil, .private)
        Self.saveEngineState(nil, .shared)
        makeEngines()
        projectsChanged()
    }

    private func projectsChanged() {
        NotificationCenter.default.post(name: SharedProjectStore.didChange, object: nil)
    }

    fileprivate func batch(for context: CKSyncEngine.SendChangesContext,
                           engine syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            if case .saveRecord(let id) = change, let record = core.recordToSave(id) { records[id] = record }
        }
        let built = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in built[id] }
    }

    // MARK: Persistence

    private static let directory = URL.applicationSupportDirectory.appending(path: "ProjectSync", directoryHint: .isDirectory)

    private static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    private static func loadBook() -> SyncBookkeeping {
        guard let data = try? Data(contentsOf: file("bookkeeping.json")),
              let book = try? JSONDecoder().decode(SyncBookkeeping.self, from: data) else { return SyncBookkeeping() }
        return book
    }

    /// Bookkeeping is written a moment after the last change, not on every one.
    private func scheduleBookSave() {
        bookSaveTask?.cancel()
        bookSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveBookNow()
        }
    }

    func saveBookNow() {
        guard privateEngine != nil, let data = try? JSONEncoder().encode(core.book) else { return }
        try? data.write(to: Self.file("bookkeeping.json"), options: .atomic)
    }

    private static func loadEngineState(_ scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: file("engine-\(scope == .shared ? "shared" : "private").json")) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func saveEngineState(_ state: CKSyncEngine.State.Serialization?, _ scope: CKDatabase.Scope) {
        let url = file("engine-\(scope == .shared ? "shared" : "private").json")
        if let state, let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension ProjectSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let scope = syncEngine.database.databaseScope
        await handle(event, scope: scope)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await batch(for: context, engine: syncEngine)
    }

    /// The private engine fetches every zone but SwiftData's (the regular store's
    /// mirror, with all regular projects and their media).
    nonisolated func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                             syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        guard syncEngine.database.databaseScope == .private else { return context.options }
        var options = context.options
        options.scope = .allExcluding([CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")])
        return options
    }
}
