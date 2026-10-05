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
//  It uses an iCloud container of its own: SwiftData's sync (the regular store, in
//  iCloud.YannickGiraud.CinePlanner) looks at every zone of its private database,
//  so zones of ours there were fetched by it too — media and all — and one that
//  was deleted left it retrying forever.
//
//  `ProjectSharing.isEnabled` is the one switch for the whole feature.
//

import Foundation
import CloudKit
import SwiftData
import os

enum ProjectSharing {
    static let isEnabled = true
}

@MainActor @Observable
final class ProjectSync {
    static let shared = ProjectSync()

    /// A problem the user should hear about (a full iCloud, say); nil when fine.
    private(set) var problem: String?
    /// A short note for the project list ("Joined “Defrost”"), cleared after a while.
    private(set) var notice: String?
    /// Bumped when who a project is shared with changes, for the list to redraw.
    private(set) var sharesGeneration = 0

    /// Asks the project list to open a project's sharing window (closing the
    /// editor first) — object: the project's uid.
    static let requestSharing = Notification.Name("ProjectSync.requestSharing")
    nonisolated static let containerIdentifier = "iCloud.YannickGiraud.CinePlanner.Sharing"

    /// The regular store's context (where a project goes when sharing stops).
    var mainContext: ModelContext? { mainContainer?.mainContext }

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

    private init() {}

    // MARK: Starting

    func start(mainContainer: ModelContainer) {
        guard ProjectSharing.isEnabled, privateEngine == nil else { return }
        self.mainContainer = mainContainer
        ckContainer = CKContainer(identifier: Self.containerIdentifier)
        core.book = Self.loadBook()
        let moving = core.book.containerIdentifier != Self.containerIdentifier
        if moving {
            // Synced with another container before (development builds did, in
            // SwiftData's): start over in this one.
            Self.saveEngineState(nil, .private)
            Self.saveEngineState(nil, .shared)
        }
        makeEngines()
        if moving { moveToThisContainer() }
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
        // Edits to a shared project are saved — and so sent — within two seconds,
        // rather than at the app's general five-second flush.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let context = SharedProjectStore.openContext, context.hasChanges { context.saveReporting() }
            }
        }
    }

    /// Sync starting over in this container: our shared projects go up again (into
    /// zones here), projects shared with us become our own copies — their shares
    /// are in the old container — and the bookkeeping starts fresh.
    private func moveToThisContainer() {
        let owners = core.book.sharedZoneOwners
        if let context = SharedProjectStore.contextIfPresent(),
           let projects = try? context.fetch(FetchDescriptor<Project>()) {
            for project in projects {
                let zoneName = "Project-\(project.uid)"
                if let owner = owners[zoneName] {
                    core.sharedZoneDeleted(CKRecordZone.ID(zoneName: zoneName, ownerName: owner))
                }
            }
        }
        core.book = SyncBookkeeping()
        // Not the old account id: iCloud gives the same person a different user
        // record in every container, so it would look like another account.
        core.book.containerIdentifier = Self.containerIdentifier
        // Only now, with fresh bookkeeping, mark what's left (ours) for upload.
        if let context = SharedProjectStore.contextIfPresent(),
           let projects = try? context.fetch(FetchDescriptor<Project>()) {
            projects.forEach(startSyncing)
        }
        // The history so far is already in those projects' records.
        core.markHistoryRead()
        saveBookNow()
        projectsChanged()
        Log.sync.notice("Sync moved to \(Self.containerIdentifier)")
    }

    #if DEBUG
    /// Development only: brings back shared projects from the container development
    /// builds synced with before (SwiftData's), into the store that holds them or —
    /// when they're gone — the regular store. Run on one device only.
    func recoverFromOldContainer() async throws -> [String] {
        guard let main = mainContainer?.mainContext else { return [] }
        let database = CKContainer(identifier: "iCloud.YannickGiraud.CinePlanner").privateCloudDatabase
        let zones = try await database.allRecordZones().map(\.zoneID).filter { $0.zoneName.hasPrefix("Project-") }
        var recovered: [String] = []
        for zoneID in zones {
            var records: [CKRecord] = []
            var token: CKServerChangeToken?
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result, !(modification.record is CKShare) {
                        records.append(modification.record)
                    }
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            guard records.contains(where: { $0.recordType == RecordSchemas.project.recordType }) else { continue }
            let uid = String(zoneID.zoneName.dropFirst("Project-".count))
            let shared = SharedProjectStore.contextIfPresent()
            let target = shared.flatMap { RecordSchemas.project.fetch($0, uid) != nil ? $0 : nil } ?? main
            ProjectRecords.apply(records, in: target)
            try target.save()
            recovered.append(RecordSchemas.project.fetch(target, uid)?.filmName ?? uid)
        }
        projectsChanged()
        return recovered
    }
    #endif

    /// Whether this device is signed in to iCloud (sharing needs it).
    func accountAvailable() async -> Bool {
        (try? await ckContainer?.accountStatus()) == .available
    }

    #if DEBUG
    /// Development only: saves one record of every type, with every field filled, in
    /// a zone of its own — so iCloud's Development schema knows them all — and
    /// deletes the records again (the zone stays: deleting zones beside SwiftData's
    /// trips up its sync). Deploy the schema to Production in the CloudKit Console
    /// afterwards: Production can't add record types or fields, and a save carrying
    /// one it doesn't know fails.
    func prepareSchema() async throws -> Int {
        guard let database = ckContainer?.privateCloudDatabase else { throw CKError(.notAuthenticated) }
        let zone = CKRecordZone(zoneName: "CPSchema")
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        let records = RecordSchemas.all.map { $0.sampleRecord(in: zone.zoneID) }
        let result = try await database.modifyRecords(saving: records, deleting: [])
        _ = try? await database.modifyRecords(saving: [], deleting: records.map(\.recordID))
        for (_, saved) in result.saveResults { if case .failure(let error) = saved { throw error } }
        return records.count
    }

    #endif

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
        Log.sync.notice("Push received (\(scope == .shared ? "shared" : scope == .private ? "private" : "other"))")
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

    /// While a shared project is open: a fetch every ten seconds. iCloud's pushes
    /// for changes others make in our own zones (the private database) arrive late
    /// or not at all, and this is a small request.
    func keepFresh(while project: Project) async {
        guard privateEngine != nil, SharedProjectStore.contains(project) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            await fetchNow()
        }
    }

    // MARK: Sharing

    /// Joins a project someone shared with this account.
    func accept(_ metadata: CKShare.Metadata) async {
        guard let ckContainer else { return }
        let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "the project"
        do {
            _ = try await ckContainer.accept(metadata)
            let zoneID = metadata.share.recordID.zoneID
            core.book.sharedZoneOwners[zoneID.zoneName] = zoneID.ownerName
            noteShare(metadata.share)
            scheduleBookSave()
            show(notice: "Joining “\(title)”…")
            try await sharedEngine?.fetchChanges()
            show(notice: "Joined “\(title)”")
        } catch {
            show(notice: "Couldn't join “\(title)”: \(error.localizedDescription)")
        }
    }

    /// Who a project is shared with or by, as last seen; nil when it isn't shared.
    func shareInfo(for project: Project) -> SyncBookkeeping.ShareInfo? {
        _ = sharesGeneration   // so views showing it follow changes to the share
        guard SharedProjectStore.contains(project) else { return nil }
        return core.book.shares["Project-\(project.uid)"]
    }

    /// False for a project shared with us to view only.
    func canEdit(_ project: Project) -> Bool { shareInfo(for: project)?.canEdit ?? true }

    /// Starts sharing one of our projects: it moves to the shared store, and from
    /// there into an iCloud zone of its own. Returns the project in its new store.
    func startSharing(_ project: Project) throws -> Project {
        let moved = try SharedProjectStore.move(project, to: SharedProjectStore.container.mainContext)
        sendSoon(.private)
        return moved
    }

    /// The project's share, creating it — and the zone it shares — when there isn't
    /// one yet. Called by the system's sharing window once a way to invite is picked.
    func createShare(forProjectUID uid: String) async throws -> CKShare {
        guard let database = ckContainer?.privateCloudDatabase else { throw CKError(.notAuthenticated) }
        let zoneID = core.zoneID(forProjectUID: uid)
        if !core.book.createdZones.contains(zoneID.zoneName) {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            core.book.createdZones.insert(zoneID.zoneName)
        }
        if let existing = try await fetchShare(zoneID: zoneID) { return existing }
        let share = CKShare(recordZoneID: zoneID)
        let title = SharedProjectStore.openContext.flatMap { RecordSchemas.project.fetch($0, uid) }?.filmName
        share[CKShare.SystemFieldKey.title] = (title ?? "CinePlanner Project") as CKRecordValue
        share.publicPermission = .none
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        guard case .success(let saved as CKShare)? = result.saveResults[share.recordID] else {
            throw CKError(.internalError)
        }
        noteShare(saved)
        try? await privateEngine?.sendChanges()          // the project's records follow
        return saved
    }

    /// The project's share as it is on the server now, if there is one.
    func fetchShare(forProjectUID uid: String) async throws -> CKShare? {
        try await fetchShare(zoneID: core.zoneID(forProjectUID: uid))
    }

    private func fetchShare(zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let scope = ProjectSyncCore.scope(of: zoneID)
        guard let database = scope == .shared ? ckContainer?.sharedCloudDatabase : ckContainer?.privateCloudDatabase
        else { return nil }
        do {
            let share = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare
            if let share { noteShare(share) }
            return share
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Saves changes to who a project is shared with (permissions, removals).
    func saveShare(_ share: CKShare) async throws {
        guard let database = ckContainer?.privateCloudDatabase else { return }
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        if case .success(let saved as CKShare)? = result.saveResults[share.recordID] { noteShare(saved) }
    }

    /// Stops sharing one of our projects: it goes back to the regular store, and its
    /// zone (with the share) is deleted. The people it was shared with keep a copy.
    @discardableResult
    func stopSharing(_ project: Project) throws -> Project? {
        guard let main = mainContainer?.mainContext else { return nil }
        core.book.shares["Project-\(project.uid)"] = nil
        let moved = try SharedProjectStore.move(project, to: main)
        sendSoon(.private)
        return moved
    }

    /// Leaves a project shared with us: our copy goes, and we're taken off its share.
    func leave(_ project: Project) {
        guard let context = project.modelContext else { return }
        core.book.shares["Project-\(project.uid)"] = nil
        context.destructiveDelete { context.deleteProjectGraph(project) }
        projectsChanged()
        sendSoon(.shared)
    }

    private func noteShare(_ share: CKShare) {
        let zoneID = share.recordID.zoneID
        let isOwner = zoneID.ownerName == CKCurrentUserDefaultName || share.currentUserParticipant?.role == .owner
        let joined = share.participants.filter { $0.role != .owner && $0.acceptanceStatus == .accepted }
        let info = SyncBookkeeping.ShareInfo(
            isOwner: isOwner,
            ownerName: share.owner.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) },
            participantCount: joined.count,
            canEdit: isOwner || share.currentUserParticipant?.permission == .readWrite)
        guard core.book.shares[zoneID.zoneName] != info else { return }
        core.book.shares[zoneID.zoneName] = info
        sharesGeneration &+= 1
        scheduleBookSave()
    }

    private func show(notice text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(6))
            if notice == text { notice = nil }
        }
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
            let all = changes.modifications.map(\.record)
            for case let share as CKShare in all { noteShare(share) }
            for deletion in changes.deletions where deletion.recordType == CKRecord.SystemType.share {
                core.book.shares[deletion.recordID.zoneID.zoneName] = nil
                sharesGeneration &+= 1
            }
            let records = all.filter { !($0 is CKShare) }
            let deletions = changes.deletions
                .filter { $0.recordType != CKRecord.SystemType.share }
                .map { (recordType: $0.recordType, recordID: $0.recordID) }
            if !records.isEmpty || !deletions.isEmpty {
                Log.sync.notice("Received \(records.count) change(s), \(deletions.count) deletion(s) (\(scope == .shared ? "shared" : "private"))")
            }
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
            if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty {
                Log.sync.notice("Sent \(sent.savedRecords.count) change(s), \(sent.deletedRecordIDs.count) deletion(s) (\(scope == .shared ? "shared" : "private"))")
            }
            // Saving works again (space was freed, say): the problem is over.
            if !sent.savedRecords.isEmpty, !sent.failedRecordSaves.contains(where: { $0.error.code == .quotaExceeded }) {
                problem = nil
            }
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

    /// Another iCloud account: the previous one's shared projects become own copies,
    /// and sync starts over.
    private func resetForNewAccount() {
        let container = core.book.containerIdentifier
        core.detachAll()
        core.book.containerIdentifier = container
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
}
