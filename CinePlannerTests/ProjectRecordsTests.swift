//
//  ProjectRecordsTests.swift
//  CinePlannerTests
//
//  A project as CloudKit records (for sharing): every attribute of every model is
//  carried or deliberately left out; a project survives the round trip with its
//  fields, relationships and media; applying the same records again changes
//  nothing; order doesn't matter; and a project moves between stores intact.
//

import XCTest
import SwiftData
import CloudKit
@testable import CinePlanner

@MainActor
final class ProjectRecordsTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    // MARK: Every field accounted for

    func testEveryAttributeIsSyncedOrDeliberatelyLeftOut() {
        let schema = Schema(versionedSchema: SchemaV1.self)
        XCTAssertEqual(schema.entities.count, RecordSchemas.all.count)
        for entity in schema.entities {
            guard let recordSchema = RecordSchemas.schema(recordType: "CP_\(entity.name)") else {
                XCTFail("No record schema for \(entity.name)"); continue
            }
            let attributes = Set(entity.attributes.map(\.name))
            let covered = recordSchema.syncedKeys.union(recordSchema.notSyncedKeys)
            XCTAssertEqual(attributes.subtracting(covered), [], "\(entity.name): attributes neither synced nor left out")
            XCTAssertEqual(covered.subtracting(attributes), [], "\(entity.name): keys that aren't attributes")
            XCTAssertTrue(recordSchema.syncedKeys.isDisjoint(with: recordSchema.notSyncedKeys), "\(entity.name): both synced and left out")
            let toOne = Set(entity.relationships.filter(\.isToOneRelationship).map(\.name))
            XCTAssertEqual(toOne, recordSchema.parentKeys, "\(entity.name): to-one relationships vs parent links")
        }
    }

    // MARK: Round trip

    /// A project with a bit of everything: two versions, scenes with a map, shots
    /// with references (media), custom info, coverage, and a shooting schedule.
    private func richProject(in context: ModelContext) -> Project {
        let project = Project(filmName: "Defrost")
        project.director = "Ada"
        project.scriptPDFData = Data([1, 2, 3])
        project.sceneColumnWidth = 333
        context.insert(project)
        let episode = Episode(episodeNumber: 1, title: "Main Feature")
        context.insert(episode); episode.project = project
        let v1 = ScriptVersion(versionNumber: 1), v2 = ScriptVersion(versionNumber: 2, name: "Pink")
        for v in [v1, v2] { context.insert(v); v.episode = episode }
        v2.pdfData = Data(repeating: 7, count: 2_000)

        let s1 = Scene(sceneNumber: 1), s2 = Scene(sceneNumber: 2)
        for (i, s) in [s1, s2].enumerated() { context.insert(s); s.scriptVersion = v2; s.project = project; s.sortOrder = i }
        s1.nickname = "Kitchen"
        s1.sceneMapJSON = #"{"elements":[],"editedAt":3}"#
        s1.sceneMapBackgroundData = Data(repeating: 9, count: 5_000)
        s1.sceneMapSatelliteLat = 52.1

        let shot = Shot(shotNumber: 1)
        context.insert(shot); shot.scene = s1
        shot.sizeName = "CU"
        shot.typeName = "Two Shot"
        shot.lensfocal = 50
        shot.sensorWidthMM = 27.99
        shot.coverageSceneUIDs = [s2.uid]
        shot.scriptCoverageSelections = [ScriptTextSelection(pageRanges: [], fullText: "INT. KITCHEN")]
        let reference = ShotReference(sortOrder: 0)
        context.insert(reference); reference.shot = shot
        reference.imageData = Data(repeating: 4, count: 10_000)
        reference.keywords = ["a", "b"]
        reference.dateTimeOriginal = Date(timeIntervalSince1970: 1_700_000_000)
        let info = ShotCustomInfo(sortOrder: 0, kind: "text", label: "Prop", value: "Kettle")
        context.insert(info); info.shot = shot

        let day = ShootingDay(sortOrder: 0, date: Date(timeIntervalSince1970: 1_800_000_000))
        context.insert(day); day.scriptVersion = v2
        let entry = ScheduleEntry(scene: s1, sortOrder: 0, note: "pt. 1")
        context.insert(entry); entry.day = day
        entry.selectedShotUIDs = [shot.uid]
        return project
    }

    private func project(_ uid: String, in context: ModelContext) throws -> Project {
        try XCTUnwrap(context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.uid == uid })).first)
    }

    func testAProjectSurvivesTheRoundTrip() throws {
        let sourceContainer = try makeContainer()
        let source = ModelContext(sourceContainer)
        let original = richProject(in: source)
        try source.save()
        let records = ProjectRecords.records(for: original, zoneID: ProjectRecords.zoneID(for: original))
        XCTAssertEqual(records.count, 11)

        let targetContainer = try makeContainer()
        let target = ModelContext(targetContainer)
        XCTAssertEqual(ProjectRecords.apply(records, in: target), 0, "every parent found")
        try target.save()

        let copy = try project(original.uid, in: target)
        XCTAssertEqual(copy.filmName, "Defrost")
        XCTAssertEqual(copy.director, "Ada")
        XCTAssertEqual(copy.scriptPDFData, Data([1, 2, 3]))
        XCTAssertEqual(copy.sceneColumnWidth, 300, "this device's layout stays behind")
        let episode = try XCTUnwrap(copy.episodes.first)
        XCTAssertEqual(episode.title, "Main Feature")
        XCTAssertEqual(episode.scriptVersions.count, 2)
        let v2 = try XCTUnwrap(episode.scriptVersions.first { $0.versionNumber == 2 })
        XCTAssertEqual(v2.name, "Pink")
        XCTAssertEqual(v2.pdfData?.count, 2_000)
        XCTAssertEqual(v2.scenes.count, 2)
        XCTAssertEqual(copy.scenes.count, 2)

        let s1 = try XCTUnwrap(v2.scenes.first { $0.sceneNumber == 1 })
        let s2 = try XCTUnwrap(v2.scenes.first { $0.sceneNumber == 2 })
        XCTAssertEqual(s1.nickname, "Kitchen")
        XCTAssertEqual(s1.sceneMapJSON, #"{"elements":[],"editedAt":3}"#)
        XCTAssertEqual(s1.sceneMapBackgroundData?.count, 5_000)
        XCTAssertEqual(s1.sceneMapSatelliteLat, 52.1)

        let shot = try XCTUnwrap(s1.shots.first)
        XCTAssertEqual(shot.sizeName, "CU")
        XCTAssertEqual(shot.typeName, "Two Shot")
        XCTAssertEqual(shot.lensfocal, 50)
        XCTAssertEqual(shot.sensorWidthMM, 27.99)
        XCTAssertEqual(shot.coverageSceneUIDs, [s2.uid])
        XCTAssertEqual(shot.scriptCoverageSelections?.first?.fullText, "INT. KITCHEN")
        let reference = try XCTUnwrap(shot.references.first)
        XCTAssertEqual(reference.imageData?.count, 10_000)
        XCTAssertEqual(reference.keywords, ["a", "b"])
        XCTAssertEqual(reference.dateTimeOriginal, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(shot.customInfo.first?.value, "Kettle")

        let day = try XCTUnwrap(v2.shootingDays.first)
        XCTAssertEqual(day.date, Date(timeIntervalSince1970: 1_800_000_000))
        let entry = try XCTUnwrap(day.entries.first)
        XCTAssertEqual(entry.note, "pt. 1")
        XCTAssertTrue(entry.scene === s1)
        XCTAssertEqual(entry.resolvedShots.map(\.uid), [shot.uid])
    }

    func testApplyingTheSameRecordsAgainChangesNothing() throws {
        let sourceContainer = try makeContainer()
        let source = ModelContext(sourceContainer)
        let original = richProject(in: source)
        try source.save()
        let records = ProjectRecords.records(for: original, zoneID: ProjectRecords.zoneID(for: original))

        let targetContainer = try makeContainer()
        let target = ModelContext(targetContainer)
        ProjectRecords.apply(records, in: target)
        try target.save()
        ProjectRecords.apply(records, in: target)
        XCTAssertFalse(target.hasChanges, "a repeat shouldn't touch anything (nor echo back to iCloud): \(target.changedModelsArray.map { "\(type(of: $0))" })")
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Shot>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Scene>()), 2)
    }

    func testOrderDoesNotMatterAndLateParentsStillLink() throws {
        let sourceContainer = try makeContainer()
        let source = ModelContext(sourceContainer)
        let original = richProject(in: source)
        try source.save()
        let records = ProjectRecords.records(for: original, zoneID: ProjectRecords.zoneID(for: original))

        // Children first, all in one go: still linked.
        let targetContainer = try makeContainer()
        let target = ModelContext(targetContainer)
        XCTAssertEqual(ProjectRecords.apply(records.reversed(), in: target), 0)

        // A shot whose scene hasn't arrived: unlinked until the scene does.
        let laterContainer = try makeContainer()
        let later = ModelContext(laterContainer)
        let shotRecord = try XCTUnwrap(records.first { $0.recordType == "CP_Shot" })
        let sceneRecord = try XCTUnwrap(records.first { $0.recordType == "CP_Scene" && ($0["sceneNumber"] as? Int) == 1 })
        XCTAssertEqual(ProjectRecords.apply([shotRecord], in: later), 1)
        ProjectRecords.apply([sceneRecord, shotRecord], in: later)
        let shot = try XCTUnwrap(later.fetch(FetchDescriptor<Shot>()).first)
        XCTAssertEqual(shot.scene?.sceneNumber, 1)
    }

    // MARK: Moving between stores

    func testAProjectMovesBetweenStoresIntact() throws {
        let regularContainer = try makeContainer(), sharedContainer = try makeContainer()
        let regular = regularContainer.mainContext, shared = sharedContainer.mainContext
        let original = richProject(in: regular)
        try regular.save()
        let uid = original.uid
        let shotUID = try XCTUnwrap(original.scenes.flatMap(\.shots).first).uid

        let moved = try SharedProjectStore.move(original, to: shared)

        XCTAssertEqual(moved.uid, uid)
        XCTAssertEqual(moved.sceneColumnWidth, 333, "this device's layout moves along")
        XCTAssertEqual(try regular.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try regular.fetchCount(FetchDescriptor<Shot>()), 0, "the whole graph left")
        XCTAssertEqual(try shared.fetchCount(FetchDescriptor<Shot>()), 1)
        XCTAssertEqual(moved.scenes.flatMap(\.shots).first?.uid, shotUID)

        let back = try SharedProjectStore.move(moved, to: regular)
        XCTAssertEqual(back.uid, uid)
        XCTAssertEqual(try shared.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(back.scenes.flatMap(\.shots).first?.references.first?.imageData?.count, 10_000)
    }
}
