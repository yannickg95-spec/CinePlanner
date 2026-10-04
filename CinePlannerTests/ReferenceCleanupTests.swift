//
//  ReferenceCleanupTests.swift
//  CinePlannerTests
//
//  What points at a shot or scene by uid lets go of it when the shot leaves or the
//  scene is deleted; and the old fixed media fields get converted for good.
//

import XCTest
import SwiftData
@testable import CinePlanner

@MainActor
final class ReferenceCleanupTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func scene(shots count: Int) -> (Scene, [Shot]) {
        let scene = Scene(sceneNumber: 1)
        context.insert(scene)
        let shots = (1...count).map { n -> Shot in
            let shot = Shot(shotNumber: n)
            context.insert(shot)
            shot.scene = scene
            return shot
        }
        return (scene, shots)
    }

    func testALeavingShotDropsOutOfTheSchedule() throws {
        let (scene, shots) = scene(shots: 3)
        let day = ShootingDay(sortOrder: 0)
        context.insert(day)
        let several = ScheduleEntry(scene: scene, sortOrder: 0)
        context.insert(several)
        several.day = day
        several.selectedShotUIDs = [shots[0].uid, shots[1].uid]
        several.shotShootOrderUIDs = [shots[1].uid, shots[0].uid]
        let onlyThat = ScheduleEntry(scene: scene, sortOrder: 1)
        context.insert(onlyThat)
        onlyThat.day = day
        onlyThat.selectedShotUIDs = [shots[1].uid]
        try context.save()

        scene.forgetShot(uid: shots[1].uid)

        XCTAssertEqual(several.selectedShotUIDs, [shots[0].uid])
        XCTAssertEqual(several.shotShootOrderUIDs, [shots[0].uid])
        // Emptying it would mean "every shot" — the strip keeps its choice instead.
        XCTAssertEqual(onlyThat.selectedShotUIDs, [shots[1].uid])
    }

    func testALeavingShotTakesItsCameraOffTheMap() throws {
        let (scene, shots) = scene(shots: 2)
        var doc = SceneMapDoc()
        var camera = MapElement(kind: .camera, x: 0.5, y: 0.5)
        camera.shotUID = shots[0].uid
        doc.elements = [camera, MapElement(kind: .character, x: 0.2, y: 0.2)]
        scene.storeSceneMap(doc)

        scene.forgetShot(uid: shots[0].uid)

        let map = SceneMapDoc.load(from: scene.sceneMapJSON)
        XCTAssertEqual(map.elements.count, 1)
        XCTAssertNotNil(map.removed[camera.id.uuidString], "the removal is recorded for merging")
    }

    func testADeletedSceneLeavesTheOtherScenesCoverage() throws {
        let version = ScriptVersion(versionNumber: 1)
        context.insert(version)
        let doomed = Scene(sceneNumber: 1), kept = Scene(sceneNumber: 2)
        context.insert(doomed); context.insert(kept)
        doomed.scriptVersion = version; kept.scriptVersion = version
        let shot = Shot(shotNumber: 1)
        context.insert(shot)
        shot.scene = kept
        let elsewhere = UUID().uuidString
        shot.coverageSceneUIDs = [doomed.uid, elsewhere]
        try context.save()

        doomed.forgetCoverageAliases()
        XCTAssertEqual(shot.coverageSceneUIDs, [elsewhere])

        shot.coverageSceneUIDs = [doomed.uid]
        doomed.forgetCoverageAliases()
        XCTAssertNil(shot.coverageSceneUIDs)
    }

    func testOldStyleMediaIsConvertedForEveryShot() throws {
        let (_, shots) = scene(shots: 2)
        shots[0].photo1Data = Data([1, 2, 3])
        shots[0].photo2Data = Data([4, 5])
        try context.save()

        XCTAssertEqual(LegacyMediaSweep.run(in: context), 1)

        XCTAssertNil(shots[0].photo1Data)
        XCTAssertNil(shots[0].photo2Data)
        let reference = try XCTUnwrap(shots[0].references.first)
        XCTAssertEqual(reference.imageData, Data([1, 2, 3]))
        XCTAssertEqual(reference.mapData, Data([4, 5]))
        XCTAssertTrue(shots[1].references.isEmpty)
        XCTAssertEqual(LegacyMediaSweep.run(in: context), 0, "nothing left on a second run")
    }
}
