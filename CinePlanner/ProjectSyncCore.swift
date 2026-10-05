//
//  ProjectSyncCore.swift
//  CinePlanner
//
//  The decisions of shared-project sync, kept apart from CKSyncEngine so they can
//  be tested without iCloud (ProjectSync is the engine around it):
//  • what changed here — the shared store's history since the last check: which
//    objects, and per object which fields — becomes record changes to send;
//  • what changed there — fetched records are applied by uid, leaving alone the
//    fields this device changed and hasn't sent; a scene map changed on both sides
//    is merged item by item;
//  • a conflict (someone saved first) is the same: their record, our unsent fields
//    on top, and send again.
//

import Foundation
import CloudKit
import SwiftData

/// What sync remembers between launches.
struct SyncBookkeeping: Codable {
    /// The shared store's history read up to here.
    var historyToken: DefaultHistoryToken?
    /// The iCloud account this was synced with — another account must start afresh.
    var userRecordName: String?
    /// The iCloud container this was synced with (nil: the one development builds
    /// used first, SwiftData's) — another container must start afresh.
    var containerIdentifier: String?
    /// Zones shared with this account: zone name → owner.
    var sharedZoneOwners: [String: String] = [:]
    /// Every record known to the server: uid → type, zone, last server version.
    var records: [String: RecordInfo] = [:]
    /// Fields changed here and not yet confirmed saved: uid → keys ("*" = all).
    var pendingFields: [String: Set<String>] = [:]
    /// Zones of this account's own projects that exist on the server.
    var createdZones: Set<String> = []
    /// Who a project is shared with or by: zone name → its share, as last seen.
    var shares: [String: ShareInfo] = [:]

    struct ShareInfo: Codable, Equatable {
        var isOwner: Bool
        var ownerName: String?
        /// People who joined, besides the owner.
        var participantCount: Int
        var canEdit: Bool
    }

    init() {}

    // Every field optional on reading, so a bookkeeping file from before a field
    // existed still loads (instead of starting sync over).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyToken = try c.decodeIfPresent(DefaultHistoryToken.self, forKey: .historyToken)
        userRecordName = try c.decodeIfPresent(String.self, forKey: .userRecordName)
        containerIdentifier = try c.decodeIfPresent(String.self, forKey: .containerIdentifier)
        sharedZoneOwners = try c.decodeIfPresent([String: String].self, forKey: .sharedZoneOwners) ?? [:]
        records = try c.decodeIfPresent([String: RecordInfo].self, forKey: .records) ?? [:]
        pendingFields = try c.decodeIfPresent([String: Set<String>].self, forKey: .pendingFields) ?? [:]
        createdZones = try c.decodeIfPresent(Set<String>.self, forKey: .createdZones) ?? []
        shares = try c.decodeIfPresent([String: ShareInfo].self, forKey: .shares) ?? [:]
    }

    struct RecordInfo: Codable {
        var recordType: String
        var zoneName: String
        /// The record's system fields as last returned by the server (its change
        /// tag), so a save isn't mistaken for a conflict.
        var systemFields: Data?
    }
}

/// A change to send: a record change (with the zone to create first when it's a new
/// one of ours), or a whole zone to delete.
struct LocalRecordChange {
    let scope: CKDatabase.Scope
    let change: CKSyncEngine.PendingRecordZoneChange?
    let zoneToCreate: CKRecordZone.ID?
    var zoneToDelete: CKRecordZone.ID? = nil
}

final class ProjectSyncCore {
    /// Author of the changes sync applies, so they aren't sent back.
    static let syncAuthor = "CinePlanner.sync"
    static let allFields: Set<String> = ["*"]

    var book = SyncBookkeeping()
    /// The shared store if it exists (looking shouldn't create it).
    private let existingStore: () -> ModelContainer?
    /// The shared store, created if needed (when a shared project arrives).
    private let store: () -> ModelContainer
    /// The regular store, where a project goes when it stops being shared with us.
    private let mainStore: () -> ModelContainer?
    /// Keys being sent, per uid, so a later edit's keys stay pending after the save.
    private var inFlight: [String: Set<String>] = [:]

    init(existingStore: @escaping () -> ModelContainer?, store: @escaping () -> ModelContainer,
         mainStore: @escaping () -> ModelContainer?) {
        self.existingStore = existingStore
        self.store = store
        self.mainStore = mainStore
    }

    // MARK: Zones

    func zoneID(forProjectUID uid: String) -> CKRecordZone.ID {
        let name = "Project-\(uid)"
        return CKRecordZone.ID(zoneName: name, ownerName: book.sharedZoneOwners[name] ?? CKCurrentUserDefaultName)
    }

    static func scope(of zoneID: CKRecordZone.ID) -> CKDatabase.Scope {
        zoneID.ownerName == CKCurrentUserDefaultName ? .private : .shared
    }

    private func zoneID(for info: SyncBookkeeping.RecordInfo) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: info.zoneName, ownerName: book.sharedZoneOwners[info.zoneName] ?? CKCurrentUserDefaultName)
    }

    // MARK: Here → there

    /// Reads the shared store's history since last time into record changes:
    /// inserts send every field, updates the fields that changed, deletions delete.
    /// Sync's own writes are skipped.
    func collectLocalChanges() -> [LocalRecordChange] {
        guard let container = existingStore() else { return [] }
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = book.historyToken { descriptor.predicate = #Predicate { $0.token > token } }
        guard let transactions = try? ModelContext(container).fetchHistory(descriptor),
              let newest = transactions.last else { return [] }
        book.historyToken = newest.token

        let context = container.mainContext
        var out: [LocalRecordChange] = []
        let local = transactions.filter { $0.author != Self.syncAuthor }

        // A deleted project isn't a heap of record deletions: our own project's zone
        // is deleted (which ends any sharing too); a project shared with us is left,
        // by removing ourselves from its share — deleting its records would delete
        // the project for everyone.
        var gone: Set<String> = []
        for transaction in local {
            for case .delete(let delete) in transaction.changes {
                guard let d = delete as? DefaultHistoryDelete<Project>, let uid = d.tombstone[\.uid] as? String,
                      book.records[uid] != nil else { continue }
                let zoneID = zoneID(forProjectUID: uid)
                gone.insert(zoneID.zoneName)
                if Self.scope(of: zoneID) == .private {
                    out.append(LocalRecordChange(scope: .private, change: nil, zoneToCreate: nil, zoneToDelete: zoneID))
                } else {
                    let share = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
                    out.append(LocalRecordChange(scope: .shared, change: .deleteRecord(share), zoneToCreate: nil))
                }
            }
        }

        for transaction in local {
            for change in transaction.changes {
                switch change {
                case .insert(let insert):
                    if let c = noteSave(insert.changedPersistentIdentifier, keys: Self.allFields, in: context) { out.append(c) }
                case .update(let update):
                    if let c = noteSave(update.changedPersistentIdentifier, keys: Self.keys(of: update), in: context) { out.append(c) }
                case .delete(let delete):
                    guard let uid = Self.uid(ofDeleted: delete), let info = book.records[uid],
                          !gone.contains(info.zoneName) else { continue }
                    let zoneID = zoneID(for: info)
                    out.append(LocalRecordChange(scope: Self.scope(of: zoneID),
                                                 change: .deleteRecord(CKRecord.ID(recordName: uid, zoneID: zoneID)),
                                                 zoneToCreate: nil))
                    book.records[uid] = nil
                    book.pendingFields[uid] = nil
                @unknown default:
                    break
                }
            }
        }
        for zoneName in gone {
            forgetZone(zoneName)
            book.createdZones.remove(zoneName)
        }
        return out
    }

    /// Skips the shared store's history up to now (its changes are covered another
    /// way, such as a whole-project upload).
    func markHistoryRead() {
        guard let container = existingStore(),
              let last = try? ModelContext(container).fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last
        else { return }
        book.historyToken = last.token
    }

    /// Every object of a project as new, for its first upload (or after its zone
    /// went missing on the server).
    func markWholeProject(_ project: Project) -> [LocalRecordChange] {
        let zoneID = zoneID(forProjectUID: project.uid)
        if Self.scope(of: zoneID) == .private { book.createdZones.remove(zoneID.zoneName) }
        return ProjectRecords.objects(in: project).compactMap { object in
            book.records[object.uid]?.systemFields = nil
            return noteSave(object, keys: Self.allFields, zoneID: zoneID)
        }
    }

    private func noteSave(_ id: PersistentIdentifier, keys: Set<String>, in context: ModelContext) -> LocalRecordChange? {
        // Fetched, not `model(for:)`: an object deleted since comes back as nil
        // rather than as a stale one that traps when touched.
        guard let schema = RecordSchemas.schema(recordType: "CP_\(id.entityName)"),
              let object = schema.find(id: id, in: context), !object.isDeleted,
              let project = ProjectRecords.project(of: object) else { return nil }
        return noteSave(object, keys: keys, zoneID: zoneID(forProjectUID: project.uid))
    }

    private func noteSave(_ object: any SyncedModel, keys: Set<String>, zoneID: CKRecordZone.ID) -> LocalRecordChange? {
        guard let schema = RecordSchemas.schema(for: type(of: object)) else { return nil }
        let relevant = keys == Self.allFields ? keys : keys.intersection(schema.syncedKeys.union(schema.parentKeys))
        guard !relevant.isEmpty else { return nil }
        let uid = object.uid
        if book.records[uid] == nil {
            book.records[uid] = .init(recordType: schema.recordType, zoneName: zoneID.zoneName)
        }
        book.pendingFields[uid, default: []].formUnion(relevant)
        let scope = Self.scope(of: zoneID)
        let needsZone = scope == .private && !book.createdZones.contains(zoneID.zoneName)
        return LocalRecordChange(scope: scope, change: .saveRecord(CKRecord.ID(recordName: uid, zoneID: zoneID)),
                                 zoneToCreate: needsZone ? zoneID : nil)
    }

    /// The record to save for a pending change: from the last server version (for
    /// its change tag) with the changed fields written in — or the whole object if
    /// the server hasn't got it yet. Nil when the object is gone.
    func recordToSave(_ id: CKRecord.ID) -> CKRecord? {
        let uid = id.recordName
        guard let container = existingStore(), let info = book.records[uid],
              let schema = RecordSchemas.schema(recordType: info.recordType),
              let object = schema.find(uid: uid, in: container.mainContext) else { return nil }
        let base = info.systemFields.flatMap(Self.record(fromSystemFields:))
        let pending = book.pendingFields[uid]
        let keys = (pending == nil || pending == Self.allFields) ? nil : pending
        inFlight[uid] = pending ?? []
        return ProjectRecords.record(for: object, zoneID: id.zoneID, base: base, keys: keys)
    }

    /// The server took a save: keep its version, and clear what was sent.
    func didSave(_ record: CKRecord) {
        let uid = record.recordID.recordName
        book.records[uid]?.systemFields = Self.systemFields(of: record)
        if let sent = inFlight.removeValue(forKey: uid), var pending = book.pendingFields[uid] {
            pending.subtract(sent)
            book.pendingFields[uid] = pending.isEmpty ? nil : pending
        }
    }

    func didDelete(_ id: CKRecord.ID) {
        book.records[id.recordName] = nil
        book.pendingFields[id.recordName] = nil
    }

    // MARK: There → here

    /// Applies fetched changes to the shared store. This device's unsent fields
    /// stay; a scene map changed on both sides becomes the merge of the two (still
    /// ours to send). Returns whether projects came or went.
    @discardableResult
    func applyRemote(_ records: [CKRecord], deletions: [(recordType: String, recordID: CKRecord.ID)]) -> Bool {
        guard !records.isEmpty || !deletions.isEmpty else { return false }
        let container = store()
        let context = container.mainContext
        // This device's edits go in as its own first, so they're sent, not taken
        // for sync's.
        if context.hasChanges { try? context.save() }

        var keeping: [String: Set<String>] = [:]
        for record in records {
            let uid = record.recordID.recordName
            guard var pending = book.pendingFields[uid],
                  let schema = RecordSchemas.schema(recordType: record.recordType) else { continue }
            if pending == Self.allFields { pending = schema.syncedKeys.union(schema.parentKeys) }
            if record.recordType == RecordSchemas.scene.recordType, pending.contains("sceneMapJSON"),
               let scene = RecordSchemas.scene.fetch(context, uid) {
                let ours = SceneMapDoc.load(from: scene.sceneMapJSON)
                let theirs = SceneMapDoc.load(from: record["sceneMapJSON"] as? String)
                let merged = SceneMapMerge.merge(ours, theirs)
                if !merged.sameContent(as: ours) || merged.removed != ours.removed {
                    scene.sceneMapJSON = merged.jsonString
                    SceneMapShadow.save(merged, for: uid)
                }
            }
            keeping[uid] = pending
        }
        if context.hasChanges { try? context.save() }   // the merged maps: ours, to send

        let projectsBefore = (try? context.fetchCount(FetchDescriptor<Project>())) ?? 0
        writeAsSync(in: context) {
            ProjectRecords.apply(records, in: context, keeping: keeping)
            ProjectRecords.delete(deletions.map { ($0.recordType, $0.recordID.recordName) }, in: context)
        }
        let projectsAfter = (try? context.fetchCount(FetchDescriptor<Project>())) ?? 0

        for record in records {
            let zoneID = record.recordID.zoneID
            if zoneID.ownerName != CKCurrentUserDefaultName { book.sharedZoneOwners[zoneID.zoneName] = zoneID.ownerName }
            book.records[record.recordID.recordName] = .init(recordType: record.recordType, zoneName: zoneID.zoneName,
                                                             systemFields: Self.systemFields(of: record))
        }
        for deletion in deletions { didDelete(deletion.recordID) }
        return projectsBefore != projectsAfter || records.contains { $0.recordType == RecordSchemas.project.recordType }
    }

    /// Someone saved first: take their version, keep our unsent fields on top.
    /// Returns whether there's still something of ours to send.
    func resolveConflict(server: CKRecord) -> Bool {
        let uid = server.recordID.recordName
        inFlight[uid] = nil
        applyRemote([server], deletions: [])
        return book.pendingFields[uid] != nil
    }

    // MARK: Zones that go away

    /// A zone of ours was deleted on the server (the project was deleted, or moved
    /// back to the regular store, on another of this account's devices): it goes
    /// here too.
    func ownZoneDeleted(_ zoneID: CKRecordZone.ID) {
        book.createdZones.remove(zoneID.zoneName)
        guard let context = existingStore()?.mainContext, let project = project(inZone: zoneID.zoneName, in: context) else {
            forgetZone(zoneID.zoneName); return
        }
        writeAsSync(in: context) { context.deleteProjectGraph(project) }
        forgetZone(zoneID.zoneName)
    }

    /// A project shared with us stopped being shared (the owner stopped sharing,
    /// or removed us): we keep our own copy, in the regular store.
    @discardableResult
    func sharedZoneDeleted(_ zoneID: CKRecordZone.ID) -> Project? {
        defer { forgetZone(zoneID.zoneName); book.sharedZoneOwners[zoneID.zoneName] = nil }
        guard let context = existingStore()?.mainContext,
              let project = project(inZone: zoneID.zoneName, in: context),
              let main = mainStore()?.mainContext else { return nil }
        let author = context.author
        context.author = Self.syncAuthor          // leaving the shared store isn't an edit to send
        defer { context.author = author }
        return try? SharedProjectStore.move(project, to: main)
    }

    /// Another iCloud account signed in: the shared projects stop syncing — they
    /// belong to the previous account's zones — and stay, as own copies in the
    /// regular store (never deleted). Sync starts over.
    func detachAll() {
        if let context = existingStore()?.mainContext, let main = mainStore()?.mainContext,
           let projects = try? context.fetch(FetchDescriptor<Project>()) {
            let author = context.author
            context.author = Self.syncAuthor          // not edits to send
            for project in projects { _ = try? SharedProjectStore.move(project, to: main) }
            context.author = author
        }
        book = SyncBookkeeping()
        inFlight = [:]
        markHistoryRead()   // what's in the history now is the previous account's
    }

    private func project(inZone zoneName: String, in context: ModelContext) -> Project? {
        guard zoneName.hasPrefix("Project-") else { return nil }
        let uid = String(zoneName.dropFirst("Project-".count))
        return RecordSchemas.project.fetch(context, uid)
    }

    private func forgetZone(_ zoneName: String) {
        for (uid, info) in book.records where info.zoneName == zoneName {
            book.records[uid] = nil
            book.pendingFields[uid] = nil
        }
    }

    // MARK: Helpers

    /// Runs writes as sync's — not undoable, not sent back — and saves them. Saves
    /// directly, not through `saveReporting()`, so updates still arrive read-only.
    private func writeAsSync(in context: ModelContext, _ body: () -> Void) {
        let author = context.author, undo = context.undoManager
        context.author = Self.syncAuthor
        context.undoManager = nil
        body()
        try? context.save()
        context.author = author
        context.undoManager = undo
    }

    private static func keys<U: HistoryUpdate>(of update: U) -> Set<String> {
        // "\Shot.lensfocal" → "lensfocal"
        Set(update.updatedAttributes.map { String("\($0)".split(separator: ".").last ?? "") })
    }

    private static func uid(ofDeleted delete: any HistoryDelete) -> String? {
        switch delete {
        case let d as DefaultHistoryDelete<Project>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<Episode>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<ScriptVersion>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<Scene>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<Shot>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<ShotReference>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<ShotCustomInfo>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<ShootingDay>: d.tombstone[\.uid] as? String
        case let d as DefaultHistoryDelete<ScheduleEntry>: d.tombstone[\.uid] as? String
        default: nil
        }
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
