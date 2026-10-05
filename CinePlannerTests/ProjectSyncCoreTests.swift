//
//  ProjectSyncCoreTests.swift
//  CinePlannerTests
//
//  Shared-project sync without iCloud: edits here become the right record changes
//  (only the fields that changed, deletions by uid); sync's own writes aren't sent
//  back; fetched changes leave this device's unsent fields alone and merge a scene
//  map changed on both sides; a conflict keeps ours on top of theirs; and when a
//  project stops being shared with us, our copy stays, in the regular store.
//

import XCTest
import SwiftData
import CloudKit
@testable import CinePlanner

@MainActor
final class ProjectSyncCoreTests: XCTestCase {

    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        }
        urls = []
    }

    /// A store on disk — history needs one.
    private func makeStore() throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).store")
        urls.append(url)
        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        container.mainContext.author = SyncRefresher.localAuthor
        return container
    }

    private func makeCore(shared: ModelContainer, main: ModelContainer? = nil) -> ProjectSyncCore {
        ProjectSyncCore(existingStore: { shared }, store: { shared }, mainStore: { main })
    }

    /// A small project — a scene with one shot — saved in the shared store.
    private func makeProject(in context: ModelContext) throws -> (Project, Scene, Shot) {
        let project = Project(filmName: "Defrost")
        context.insert(project)
        let episode = Episode(episodeNumber: 1); context.insert(episode); episode.project = project
        let version = ScriptVersion(versionNumber: 1); context.insert(version); version.episode = episode
        let scene = Scene(sceneNumber: 1); context.insert(scene); scene.scriptVersion = version; scene.project = project
        let shot = Shot(shotNumber: 1); context.insert(shot); shot.scene = scene
        shot.lensfocal = 35
        try context.save()
        return (project, scene, shot)
    }

    /// Pretends the server took everything pending: each record "saved" as built.
    private func confirmAll(_ changes: [LocalRecordChange], core: ProjectSyncCore) {
        for change in changes {
            if case .saveRecord(let id) = change.change, let record = core.recordToSave(id) { core.didSave(record) }
        }
    }

    private func savedIDs(_ changes: [LocalRecordChange]) -> [String] {
        changes.compactMap { if case .saveRecord(let id) = $0.change { id.recordName } else { nil } }
    }

    // MARK: Here → there

    func testEditsBecomeRecordChangesWithOnlyTheChangedFields() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let (project, _, shot) = try makeProject(in: store.mainContext)

        let first = core.collectLocalChanges()
        XCTAssertEqual(Set(savedIDs(first)).count, 5, "project, episode, version, scene, shot")
        let zone = core.zoneID(forProjectUID: project.uid)
        XCTAssertEqual(first.first?.zoneToCreate, zone, "a new zone of ours to create first")
        XCTAssertTrue(first.allSatisfy { $0.scope == .private })
        confirmAll(first, core: core)
        XCTAssertTrue(core.book.pendingFields.isEmpty)

        shot.lensfocal = 85
        try store.mainContext.save()
        let edit = core.collectLocalChanges()
        XCTAssertEqual(savedIDs(edit), [shot.uid])
        XCTAssertEqual(core.book.pendingFields[shot.uid], ["lensfocal"])
        let id = CKRecord.ID(recordName: shot.uid, zoneID: zone)
        let record = try XCTUnwrap(core.recordToSave(id))
        XCTAssertEqual(Set(record.changedKeys()), ["lensfocal"], "unchanged fields (and media) aren't sent again")
        XCTAssertEqual(record["lensfocal"] as? Int, 85)

        let uid = shot.uid
        store.mainContext.delete(shot)
        try store.mainContext.save()
        let deletion = core.collectLocalChanges()
        XCTAssertTrue(deletion.contains { if case .deleteRecord(let id) = $0.change { id.recordName == uid } else { false } })
    }

    func testSyncsOwnWritesAreNotSentBack() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let source = try makeStore()
        let (project, _, _) = try makeProject(in: source.mainContext)
        let records = ProjectRecords.records(for: project, zoneID: ProjectRecords.zoneID(for: project, ownerName: "someoneElse"))

        XCTAssertTrue(core.applyRemote(records, deletions: []))
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Shot>()), 1)
        XCTAssertTrue(core.collectLocalChanges().isEmpty)
        XCTAssertEqual(core.book.sharedZoneOwners[ProjectRecords.zoneID(for: project).zoneName], "someoneElse")
    }

    func testDeletingOurProjectDeletesItsZone() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let (project, _, _) = try makeProject(in: store.mainContext)
        confirmAll(core.collectLocalChanges(), core: core)
        let zone = core.zoneID(forProjectUID: project.uid)

        store.mainContext.deleteProjectGraph(project)
        try store.mainContext.save()
        let changes = core.collectLocalChanges()

        XCTAssertEqual(changes.compactMap(\.zoneToDelete), [zone])
        XCTAssertTrue(changes.allSatisfy { $0.change == nil }, "no record-by-record deletions")
        XCTAssertTrue(core.book.records.isEmpty)
    }

    func testDeletingAProjectSharedWithUsLeavesItInsteadOfDeletingItForEveryone() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let source = try makeStore()
        let (original, _, _) = try makeProject(in: source.mainContext)
        let zone = ProjectRecords.zoneID(for: original, ownerName: "someoneElse")
        core.applyRemote(ProjectRecords.records(for: original, zoneID: zone), deletions: [])
        _ = core.collectLocalChanges()

        let ours = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<Project>()).first)
        store.mainContext.deleteProjectGraph(ours)
        try store.mainContext.save()
        let changes = core.collectLocalChanges()

        XCTAssertEqual(changes.count, 1)
        guard case .deleteRecord(let id) = changes.first?.change else { return XCTFail("expected leaving the share") }
        XCTAssertEqual(id.recordName, CKRecordNameZoneWideShare)
        XCTAssertEqual(id.zoneID, zone)
        XCTAssertEqual(changes.first?.scope, .shared)
    }

    // MARK: There → here

    func testFetchedChangesLeaveUnsentFieldsAlone() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let (project, _, shot) = try makeProject(in: store.mainContext)
        confirmAll(core.collectLocalChanges(), core: core)

        shot.lensfocal = 85                                   // ours, not sent yet
        try store.mainContext.save()
        _ = core.collectLocalChanges()

        let theirs = try XCTUnwrap(ProjectRecords.record(for: shot, zoneID: core.zoneID(forProjectUID: project.uid)))
        theirs["lensfocal"] = 35
        theirs["nickname"] = "Wide"
        core.applyRemote([theirs], deletions: [])

        XCTAssertEqual(shot.lensfocal, 85, "our unsent edit stays")
        XCTAssertEqual(shot.nickname, "Wide", "their other change arrives")
        XCTAssertEqual(core.book.pendingFields[shot.uid], ["lensfocal"])
    }

    func testASceneMapChangedOnBothSidesIsMerged() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let (project, scene, _) = try makeProject(in: store.mainContext)
        confirmAll(core.collectLocalChanges(), core: core)

        var base = SceneMapDoc()
        base.elements = [MapElement(kind: .character, x: 0.2, y: 0.2)]
        base = SceneMapMerge.stamped(base, against: SceneMapDoc(), now: 1_800_000_000)
        var ours = base; ours.elements.append(MapElement(kind: .camera, x: 0.5, y: 0.5))
        ours = SceneMapMerge.stamped(ours, against: base, now: 1_800_000_010)
        var theirs = base; theirs.elements.append(MapElement(kind: .character, x: 0.8, y: 0.8))
        theirs = SceneMapMerge.stamped(theirs, against: base, now: 1_800_000_005)

        scene.sceneMapJSON = ours.jsonString
        try store.mainContext.save()
        _ = core.collectLocalChanges()

        let record = try XCTUnwrap(ProjectRecords.record(for: scene, zoneID: core.zoneID(forProjectUID: project.uid)))
        record["sceneMapJSON"] = theirs.jsonString
        core.applyRemote([record], deletions: [])

        XCTAssertEqual(SceneMapDoc.load(from: scene.sceneMapJSON).elements.count, 3, "both additions")
        XCTAssertNotNil(core.book.pendingFields[scene.uid], "the merge is ours to send")
    }

    func testAConflictKeepsOursOnTopOfTheirs() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let (project, _, shot) = try makeProject(in: store.mainContext)
        confirmAll(core.collectLocalChanges(), core: core)

        shot.lensfocal = 85
        try store.mainContext.save()
        let zone = core.zoneID(forProjectUID: project.uid)
        _ = core.collectLocalChanges()
        _ = core.recordToSave(CKRecord.ID(recordName: shot.uid, zoneID: zone))   // in flight…

        let server = try XCTUnwrap(ProjectRecords.record(for: shot, zoneID: zone))
        server["lensfocal"] = 24
        server["extraInfo"] = "Handheld"
        XCTAssertTrue(core.resolveConflict(server: server), "ours still to send")
        XCTAssertEqual(shot.lensfocal, 85)
        XCTAssertEqual(shot.extraInfo, "Handheld")
    }

    // MARK: Bookkeeping

    func testOlderBookkeepingStillLoads() throws {
        var book = SyncBookkeeping()
        book.userRecordName = "_abc"
        book.records["x"] = .init(recordType: "CP_Shot", zoneName: "Project-1")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        json["shares"] = nil                       // written before sharing info existed
        json["sharedZoneJoined"] = nil
        let decoded = try JSONDecoder().decode(SyncBookkeeping.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.userRecordName, "_abc")
        XCTAssertEqual(decoded.records["x"]?.zoneName, "Project-1")
        XCTAssertTrue(decoded.shares.isEmpty)
        XCTAssertTrue(decoded.sharedZoneJoined.isEmpty)
    }

    // MARK: Zones that go away

    func testWhenSharingStopsOurCopyStaysInTheRegularStore() throws {
        let store = try makeStore(), main = try makeStore()
        let core = makeCore(shared: store, main: main)
        let source = try makeStore()
        let (project, _, _) = try makeProject(in: source.mainContext)
        let zone = ProjectRecords.zoneID(for: project, ownerName: "someoneElse")
        core.applyRemote(ProjectRecords.records(for: project, zoneID: zone), deletions: [])

        let kept = try XCTUnwrap(core.sharedZoneDeleted(zone))
        XCTAssertEqual(kept.uid, project.uid)
        XCTAssertEqual(try main.mainContext.fetchCount(FetchDescriptor<Shot>()), 1)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertTrue(core.collectLocalChanges().isEmpty, "leaving isn't a deletion to send")
        XCTAssertTrue(core.book.records.isEmpty)
    }

    func testWhenTheOwnerAsksOurCopyGoesEverywhere() throws {
        let store = try makeStore(), main = try makeStore()
        let core = makeCore(shared: store, main: main)
        let source = try makeStore()
        let (project, _, _) = try makeProject(in: source.mainContext)
        let zone = ProjectRecords.zoneID(for: project, ownerName: "someoneElse")
        core.applyRemote(ProjectRecords.records(for: project, zoneID: zone), deletions: [])
        core.book.sharedZoneOwners[zone.zoneName] = "someoneElse"
        core.book.sharedZoneJoined[zone.zoneName] = Date()

        core.sharedZoneRemoved(zone)

        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Shot>()), 0)
        XCTAssertEqual(try main.mainContext.fetchCount(FetchDescriptor<Project>()), 0, "no copy kept")
        XCTAssertTrue(core.collectLocalChanges().isEmpty, "not a leaving to send")
        XCTAssertTrue(core.book.records.isEmpty)
        XCTAssertNil(core.book.sharedZoneOwners[zone.zoneName])
        XCTAssertNil(core.book.sharedZoneJoined[zone.zoneName])
    }

    func testAnotherAccountNeverDeletesTheSharedProjects() throws {
        let store = try makeStore(), main = try makeStore()
        let core = makeCore(shared: store, main: main)
        let (project, _, _) = try makeProject(in: store.mainContext)
        let uid = project.uid
        confirmAll(core.collectLocalChanges(), core: core)

        core.detachAll()

        XCTAssertEqual(try main.mainContext.fetch(FetchDescriptor<Project>()).map(\.uid), [uid], "kept as an own copy")
        XCTAssertEqual(try main.mainContext.fetchCount(FetchDescriptor<Shot>()), 1)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertTrue(core.book.records.isEmpty)
        XCTAssertTrue(core.collectLocalChanges().allSatisfy { $0.zoneToDelete == nil }, "nothing deleted in iCloud")
    }

    func testOurZoneDeletedElsewhereRemovesTheProjectHere() throws {
        let store = try makeStore()
        let core = makeCore(shared: store)
        let (project, _, _) = try makeProject(in: store.mainContext)
        confirmAll(core.collectLocalChanges(), core: core)

        core.ownZoneDeleted(core.zoneID(forProjectUID: project.uid))
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<Shot>()), 0)
        XCTAssertTrue(core.collectLocalChanges().isEmpty)
    }
}
