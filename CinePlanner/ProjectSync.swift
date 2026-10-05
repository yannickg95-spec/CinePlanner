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
        // And the word left when sharing ends, in the public database.
        let sample = Self.sharingEndedID(zoneName: "CPSchema")
        try await saveSharingEnded(sample, removeCopies: false)
        _ = try? await ckContainer?.publicCloudDatabase.modifyRecords(saving: [], deleting: [sample])
        return records.count + 1
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
            show(notice: "Joining “\(title)”…")
            _ = try await ckContainer.accept(metadata)
            let zoneID = metadata.share.recordID.zoneID
            core.book.sharedZoneOwners[zoneID.zoneName] = zoneID.ownerName
            core.book.sharedZoneJoined[zoneID.zoneName] = Date()
            noteShare(metadata.share)
            scheduleBookSave()
            // The whole project straight from its zone: the engine's own fetch can
            // miss a zone joined a moment ago, and goes on from where it last was.
            if try await fetchWholeZone(zoneID) {
                show(notice: "Joined “\(title)”")
            } else {
                show(notice: "Joined “\(title)”. It appears here once it has finished uploading from its owner's device.")
            }
            try? await sharedEngine?.fetchChanges()
        } catch {
            show(notice: "Couldn't join “\(title)”: \(error.localizedDescription)")
        }
    }

    /// Everything in a zone shared with us, from the start, applied in one go (so
    /// links between records on different pages resolve). False when the project
    /// itself wasn't among it.
    private func fetchWholeZone(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        guard let database = ckContainer?.sharedCloudDatabase else { return false }
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var moreComing = true
        var attempts = 0
        while moreComing {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                records += changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                token = changes.changeToken
                moreComing = changes.moreComing
            } catch let error as CKError where error.code == .zoneNotFound && attempts < 5 {
                // Just joined: the zone can take a moment to show up.
                attempts += 1
                try await Task.sleep(for: .seconds(2))
            }
        }
        Log.sync.notice("Fetched \(records.count) record(s) of joined zone \(zoneID.zoneName)")
        applyFetched(records, deletions: [], scope: .shared)
        return records.contains { $0.recordType == RecordSchemas.project.recordType }
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
        try await ensureUploaded(zoneID, projectUID: uid, in: database)
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
        return saved
    }

    /// Makes sure the project is in its zone before anyone is invited to it. A zone
    /// deleted on another device and made again holds only what was sent since, so
    /// someone joining would get scenes and shots without the project they belong to.
    private func ensureUploaded(_ zoneID: CKRecordZone.ID, projectUID uid: String, in database: CKDatabase) async throws {
        func projectIsThere() async throws -> Bool {
            do {
                _ = try await database.record(for: CKRecord.ID(recordName: uid, zoneID: zoneID))
                return true
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                return false
            }
        }
        if try await projectIsThere() { return }
        // Just started sharing: it may only still be on its way.
        try? await privateEngine?.sendChanges()
        if try await projectIsThere() { return }
        guard let context = SharedProjectStore.openContext, let project = RecordSchemas.project.fetch(context, uid) else { return }
        Log.sync.notice("Zone \(zoneID.zoneName) was missing its project: sending all of it")
        queue(core.markWholeProject(project))
        try await privateEngine?.sendChanges()
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

    /// A new invitation to one of our shared projects: a one-time link that lets in
    /// whoever opens it first, who can edit until the owner says otherwise.
    func makeInvitationLink(forProjectUID uid: String) async throws -> (url: URL, participantID: CKShare.Participant.ID) {
        guard let database = ckContainer?.privateCloudDatabase else { throw CKError(.notAuthenticated) }
        let share = try await createShare(forProjectUID: uid)
        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        share.addParticipant(participant)
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        guard case .success(let saved as CKShare)? = result.saveResults[share.recordID] else {
            if case .failure(let error)? = result.saveResults[share.recordID] { throw error }
            throw CKError(.internalError)
        }
        noteShare(saved)
        // The Swift spelling is iOS/macOS 26 only; the method itself is 18/15.
        guard let url = saved.__oneTimeURL(forParticipantID: participant.participantID) else {
            throw CKError(.internalError)
        }
        return (url, participant.participantID)
    }

    /// Takes back an invitation that wasn't sent after all, if nobody used it yet.
    func withdrawInvitation(_ participantID: CKShare.Participant.ID, projectUID: String) async {
        guard let share = try? await fetchShare(forProjectUID: projectUID),
              let participant = share.participants.first(where: { $0.participantID == participantID }),
              participant.acceptanceStatus == .pending else { return }
        share.removeParticipant(participant)
        try? await saveShare(share)
    }

    /// Stops sharing one of our projects: it goes back to the regular store, and its
    /// zone (with the share) is deleted. The people it was shared with keep their
    /// copy, or — if the owner asks — it goes from their devices too.
    @discardableResult
    func stopSharing(_ project: Project, removeCopies: Bool) async throws -> Project? {
        try await leaveWord(zoneName: "Project-\(project.uid)", removeCopies: removeCopies)
        guard let main = mainContainer?.mainContext else { return nil }
        core.book.shares["Project-\(project.uid)"] = nil
        let moved = try SharedProjectStore.move(project, to: main)
        sendSoon(.private)
        return moved
    }

    /// Deletes one of our shared projects; the people it was shared with keep their
    /// copy, or it goes from their devices too.
    func deleteSharedProject(_ project: Project, removeCopies: Bool) async throws {
        try await leaveWord(zoneName: "Project-\(project.uid)", removeCopies: removeCopies)
        guard let context = project.modelContext else { return }
        context.destructiveDelete { context.deleteProjectGraph(project) }
        projectsChanged()
    }

    /// Takes someone off one of our shared projects; they keep their copy, or it
    /// goes from their devices.
    func removeParticipant(_ participant: CKShare.Participant, from share: CKShare, removeCopy: Bool) async throws {
        // Nobody's behind an invitation that wasn't used yet, so there's no copy.
        if let user = participant.userIdentity.userRecordID?.recordName {
            try await leaveWord(zoneName: share.recordID.zoneID.zoneName, user: user, removeCopies: removeCopy)
        }
        share.removeParticipant(participant)
        try await saveShare(share)
    }

    /// Shared with this account by someone else.
    func isSharedWithUs(_ project: Project) -> Bool {
        guard SharedProjectStore.contains(project) else { return false }
        if let info = shareInfo(for: project) { return !info.isOwner }
        return core.book.sharedZoneOwners["Project-\(project.uid)"] != nil
    }

    /// Leaves a project shared with us: our copy goes, and we're taken off its share.
    func leave(_ project: Project) async {
        // This account's other devices see only that the project is gone: word that
        // it should go there too, rather than stay as a copy.
        if let me = try? await ckContainer?.userRecordID().recordName {
            try? await saveSharingEnded(Self.sharingEndedID(zoneName: "Project-\(project.uid)", user: me, left: true),
                                        removeCopies: true)
        }
        guard let context = project.modelContext else { return }
        core.book.shares["Project-\(project.uid)"] = nil
        context.destructiveDelete { context.deleteProjectGraph(project) }
        projectsChanged()
        sendSoon(.shared)
    }

    // MARK: When sharing ends

    /// What the people a project was shared with are told when it stops being
    /// shared with them — whether to keep their copy. It's left in the public
    /// database, as the project's zone is about to go. Named after the zone, plus
    /// the person when it's about one of them (and ".left" when they left it
    /// themselves, for their other devices); it holds nothing else.
    nonisolated static let sharingEndedRecordType = "CP_SharingEnded"

    private static func sharingEndedID(zoneName: String, user: String? = nil, left: Bool = false) -> CKRecord.ID {
        CKRecord.ID(recordName: [zoneName, user, left ? "left" : nil].compactMap { $0 }.joined(separator: "."))
    }

    /// The owner's word, before the zone goes. Keeping a copy is what happens
    /// without it too, so only asking for the copies to go must get through.
    private func leaveWord(zoneName: String, user: String? = nil, removeCopies: Bool) async throws {
        do {
            try await saveSharingEnded(Self.sharingEndedID(zoneName: zoneName, user: user), removeCopies: removeCopies)
        } catch where !removeCopies {
            Log.sync.error("Couldn't leave word that copies stay: \(error.localizedDescription)")
        }
    }

    private func saveSharingEnded(_ id: CKRecord.ID, removeCopies: Bool) async throws {
        guard let database = ckContainer?.publicCloudDatabase else { throw CKError(.notAuthenticated) }
        let record = CKRecord(recordType: Self.sharingEndedRecordType, recordID: id)
        record["removeCopies"] = removeCopies ? Int64(1) : Int64(0)
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        if case .failure(let error)? = result.saveResults[id] { throw error }
    }

    private enum SharingEnd { case keep, removedByOwner, left }

    /// The latest word about a zone shared with us since we joined it: about
    /// everyone, about us, or from our own leaving on another device.
    private func sharingEnd(of zoneID: CKRecordZone.ID) async -> SharingEnd {
        guard let ckContainer else { return .keep }
        let zoneName = zoneID.zoneName
        let joined = core.book.sharedZoneJoined[zoneName] ?? .distantPast
        var ids = [Self.sharingEndedID(zoneName: zoneName)]
        let me = try? await ckContainer.userRecordID().recordName
        if let me {
            ids += [Self.sharingEndedID(zoneName: zoneName, user: me), Self.sharingEndedID(zoneName: zoneName, user: me, left: true)]
        }
        for attempt in 0..<3 {
            do {
                let latest = try await ckContainer.publicCloudDatabase.records(for: ids).values
                    .compactMap { try? $0.get() }
                    .filter { ($0.modificationDate ?? .distantPast) >= joined }
                    .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
                guard let latest, (latest["removeCopies"] as? Int64) == 1 else { return .keep }
                return latest.recordID.recordName.hasSuffix(".left") ? .left : .removedByOwner
            } catch {
                Log.sync.error("Couldn't read the word about \(zoneName): \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(2 << attempt))
            }
        }
        return .keep
    }

    /// Zones shared with us whose end is being looked into.
    private var endingZones: Set<String> = []

    /// A project shared with us isn't any more: the owner stopped sharing it,
    /// deleted it or took us off — or we left it on another device. Our copy goes
    /// or stays (in the regular store), as the word about it says.
    private func sharingEnded(_ zoneID: CKRecordZone.ID) {
        let zoneName = zoneID.zoneName
        guard endingZones.insert(zoneName).inserted else { return }
        let title = SharedProjectStore.openContext
            .flatMap { RecordSchemas.project.fetch($0, String(zoneName.dropFirst("Project-".count))) }?.filmName
        Task {
            defer { endingZones.remove(zoneName) }
            switch await sharingEnd(of: zoneID) {
            case .keep:
                core.sharedZoneDeleted(zoneID)
                if let title { show(notice: "“\(title)” is no longer shared. You keep your own copy.") }
            case .removedByOwner:
                core.sharedZoneRemoved(zoneID)
                if let title { show(notice: "“\(title)” is no longer shared, and its owner removed it.") }
            case .left:
                core.sharedZoneRemoved(zoneID)
            }
            projectsChanged()
            scheduleBookSave()
        }
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
                let zoneName = modification.zoneID.zoneName
                core.book.sharedZoneOwners[zoneName] = modification.zoneID.ownerName
                if core.book.sharedZoneJoined[zoneName] == nil { core.book.sharedZoneJoined[zoneName] = Date() }
            }
            for deletion in changes.deletions where deletion.zoneID.zoneName.hasPrefix("Project-") {
                if scope == .private {
                    core.ownZoneDeleted(deletion.zoneID)
                    projectsChanged()
                } else {
                    sharingEnded(deletion.zoneID)
                }
            }
            scheduleBookSave()

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes.modifications.map(\.record),
                         deletions: changes.deletions.map { (recordType: $0.recordType, recordID: $0.recordID) },
                         scope: scope)

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
                sharingEnded(id.zoneID)
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

    /// Fetched changes: shares noted, the rest into the store.
    private func applyFetched(_ all: [CKRecord], deletions allDeletions: [(recordType: String, recordID: CKRecord.ID)],
                              scope: CKDatabase.Scope) {
        for case let share as CKShare in all { noteShare(share) }
        for deletion in allDeletions where deletion.recordType == CKRecord.SystemType.share {
            core.book.shares[deletion.recordID.zoneID.zoneName] = nil
            sharesGeneration &+= 1
        }
        let records = all.filter { !($0 is CKShare) }
        let deletions = allDeletions.filter { $0.recordType != CKRecord.SystemType.share }
        if !records.isEmpty || !deletions.isEmpty {
            Log.sync.notice("Received \(records.count) change(s), \(deletions.count) deletion(s) (\(scope == .shared ? "shared" : "private"))")
        }
        if core.applyRemote(records, deletions: deletions) { projectsChanged() }
        if !records.isEmpty || !deletions.isEmpty { SyncRefresher.shared.noteExternalChanges() }
        scheduleBookSave()
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
