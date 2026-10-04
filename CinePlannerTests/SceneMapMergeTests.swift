//
//  SceneMapMergeTests.swift
//  CinePlannerTests
//
//  Two devices changing the same scene map before they've synced: the copies merge
//  item by item — both sides' changes stay, the later change to one item wins, a
//  removal sticks — instead of one whole copy replacing the other.
//

import XCTest
import SwiftData
@testable import CinePlanner

@MainActor
final class SceneMapMergeTests: XCTestCase {

    private let t0 = 1_800_000_000.0

    private func marker(_ x: Double) -> MapElement {
        MapElement(kind: .character, x: x, y: 0.5)
    }

    private func element(_ doc: SceneMapDoc, _ id: UUID) -> MapElement? {
        doc.elements.first { $0.id == id }
    }

    /// A map both devices have, saved once at `t0`.
    private func sharedBase() -> (doc: SceneMapDoc, a: UUID, b: UUID) {
        var doc = SceneMapDoc()
        doc.elements = [marker(0.2), marker(0.4)]
        let base = SceneMapMerge.stamped(doc, against: SceneMapDoc(), now: t0)
        return (base, base.elements[0].id, base.elements[1].id)
    }

    // MARK: Stamping

    func testOnlyChangedItemsAreStamped() {
        let (base, a, b) = sharedBase()
        var edit = base
        edit.elements[0].x = 0.9
        let saved = SceneMapMerge.stamped(edit, against: base, now: t0 + 5)
        XCTAssertEqual(element(saved, a)?.editedAt, t0 + 5)
        XCTAssertEqual(element(saved, b)?.editedAt, t0)
        XCTAssertEqual(saved.editedAt, t0 + 5)
    }

    func testRemovalsAreRecorded() {
        let (base, a, _) = sharedBase()
        var edit = base
        edit.elements.removeAll { $0.id == a }
        let saved = SceneMapMerge.stamped(edit, against: base, now: t0 + 5)
        XCTAssertEqual(saved.removed[a.uuidString], t0 + 5)
    }

    func testStampsDoNotCountAsContent() {
        let (base, _, _) = sharedBase()
        var restamped = base
        restamped.elements[0].editedAt = t0 + 99
        restamped.removed["x"] = t0
        XCTAssertTrue(base.sameContent(as: restamped))
    }

    // MARK: Merging

    func testEditsToDifferentItemsBothSurvive() {
        let (base, a, b) = sharedBase()
        var mine = base; mine.elements[0].x = 0.9
        var theirs = base; theirs.elements[1].x = 0.1
        let merged = SceneMapMerge.merge(SceneMapMerge.stamped(mine, against: base, now: t0 + 2),
                                         SceneMapMerge.stamped(theirs, against: base, now: t0 + 1))
        XCTAssertEqual(element(merged, a)?.x, 0.9)
        XCTAssertEqual(element(merged, b)?.x, 0.1)
    }

    func testTheLaterChangeToOneItemWins() {
        let (base, a, _) = sharedBase()
        var mine = base; mine.elements[0].x = 0.9
        var theirs = base; theirs.elements[0].x = 0.1
        let merged = SceneMapMerge.merge(SceneMapMerge.stamped(mine, against: base, now: t0 + 1),
                                         SceneMapMerge.stamped(theirs, against: base, now: t0 + 2))
        XCTAssertEqual(element(merged, a)?.x, 0.1)
    }

    func testARemovalBeatsAnOlderEdit() {
        let (base, a, _) = sharedBase()
        var mine = base; mine.elements[0].x = 0.9
        var theirs = base; theirs.elements.removeAll { $0.id == a }
        let merged = SceneMapMerge.merge(SceneMapMerge.stamped(mine, against: base, now: t0 + 1),
                                         SceneMapMerge.stamped(theirs, against: base, now: t0 + 2))
        XCTAssertNil(element(merged, a))
    }

    func testAnUntouchedItemRemovedElsewhereStaysRemoved() {
        let (base, a, b) = sharedBase()
        var mine = base; mine.elements[1].x = 0.7                 // edits B, leaves A
        var theirs = base; theirs.elements.removeAll { $0.id == a }
        let merged = SceneMapMerge.merge(SceneMapMerge.stamped(mine, against: base, now: t0 + 2),
                                         SceneMapMerge.stamped(theirs, against: base, now: t0 + 1))
        XCTAssertNil(element(merged, a))
        XCTAssertEqual(element(merged, b)?.x, 0.7)
    }

    func testAnItemAddedOnOneDeviceIsKept() {
        let (base, _, _) = sharedBase()
        var mine = base; mine.elements.append(marker(0.6))
        let newID = mine.elements[2].id
        var theirs = base; theirs.elements[0].x = 0.1
        let merged = SceneMapMerge.merge(SceneMapMerge.stamped(mine, against: base, now: t0 + 1),
                                         SceneMapMerge.stamped(theirs, against: base, now: t0 + 2))
        XCTAssertNotNil(element(merged, newID))
        XCTAssertEqual(merged.elements.count, 3)
    }

    func testAClearedMapStaysCleared() {
        let (base, _, _) = sharedBase()
        let cleared = SceneMapMerge.stamped(SceneMapDoc(), against: base, now: t0 + 2)
        XCTAssertNotNil(cleared.jsonString, "a clear keeps its removals so it can sync")
        let merged = SceneMapMerge.merge(base, SceneMapDoc.load(from: cleared.jsonString))
        XCTAssertTrue(merged.isEmpty)
    }

    func testAnArrowGoesWithTheMarkerItPointsAt() {
        let shared = sharedBase()
        let a = shared.a, b = shared.b
        var base = shared.doc
        base.arrows = [MapArrow(fromID: a, toID: b)]
        base = SceneMapMerge.stamped(base, against: SceneMapDoc(), now: t0)
        var theirs = base; theirs.elements.removeAll { $0.id == b }; theirs.arrows = []
        var mine = base; mine.arrows[0].pivots = [CGPoint(x: 0.3, y: 0.3)]
        let merged = SceneMapMerge.merge(SceneMapMerge.stamped(mine, against: base, now: t0 + 1),
                                         SceneMapMerge.stamped(theirs, against: base, now: t0 + 2))
        XCTAssertTrue(merged.arrows.isEmpty)
    }

    func testCopiesFromOlderVersionsStillLetTheNewerMapWin() {
        // No item stamps, no removal list: as before, the newer copy decides.
        var older = SceneMapDoc(); older.elements = [marker(0.2), marker(0.4)]; older.editedAt = t0
        var newer = older; newer.elements.removeLast(); newer.elements[0].x = 0.8; newer.editedAt = t0 + 1
        let merged = SceneMapMerge.merge(older, newer)
        XCTAssertEqual(merged.elements.count, 1)
        XCTAssertEqual(merged.elements[0].x, 0.8)
    }

    func testTheResultDoesNotDependOnWhichDeviceMerges() {
        let (base, _, _) = sharedBase()
        var mine = base; mine.elements[0].x = 0.9; mine.elements.append(marker(0.6))
        var theirs = base; theirs.elements[1].x = 0.1; theirs.elements[0].x = 0.3
        let m = SceneMapMerge.stamped(mine, against: base, now: t0 + 1)
        let t = SceneMapMerge.stamped(theirs, against: base, now: t0 + 2)
        let here = SceneMapMerge.merge(m, t), there = SceneMapMerge.merge(t, m)
        XCTAssertEqual(Set(here.elements.map(\.id)), Set(there.elements.map(\.id)))
        for item in here.elements { XCTAssertEqual(element(there, item.id), item) }
    }

    func testOldMapsStillDecode() {
        let json = #"{"elements":[{"id":"6B1C3C9E-6E0E-4E5A-9C1B-1F2D3E4A5B6C","kind":"camera","x":0.5,"y":0.5}],"editedAt":12}"#
        let doc = SceneMapDoc.load(from: json)
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertNil(doc.elements[0].editedAt)
        XCTAssertTrue(doc.removed.isEmpty)
        XCTAssertEqual(SceneMapDoc.load(from: doc.jsonString), doc)
    }

    // MARK: After an import

    func testAnImportedCopyIsMergedWithThisDevicesChanges() throws {
        let container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let scene = Scene(sceneNumber: 1)
        context.insert(scene)
        let start = Date()

        // Both devices have this map…
        var doc = SceneMapDoc(); doc.elements = [marker(0.2), marker(0.4)]
        let base = scene.storeSceneMap(doc, now: start)
        try context.save()
        let a = base.elements[0].id, b = base.elements[1].id

        // …this one moves A…
        var mine = base; mine.elements[0].x = 0.9
        scene.storeSceneMap(mine, now: start.addingTimeInterval(2))
        try context.save()

        // …while the other moved B, and its copy arrives over ours.
        var theirs = base; theirs.elements[1].x = 0.1
        theirs = SceneMapMerge.stamped(theirs, against: base, now: start.timeIntervalSince1970 + 1)
        let importer = ModelContext(container)
        let imported = try XCTUnwrap(importer.fetch(FetchDescriptor<Scene>()).first)
        imported.sceneMapJSON = theirs.jsonString
        try importer.save()

        SceneMapSync.reconcile(sceneIDs: [scene.persistentModelID], in: context)

        let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Scene>()).first)
        let result = SceneMapDoc.load(from: stored.sceneMapJSON)
        XCTAssertEqual(element(result, a)?.x, 0.9)
        XCTAssertEqual(element(result, b)?.x, 0.1)
    }
}
