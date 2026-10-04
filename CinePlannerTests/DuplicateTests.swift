//
//  DuplicateTests.swift
//  CinePlannerTests
//
//  Scenes and shots are duplicated when shots move between script versions. A copy
//  must keep how its image background is aligned under the markers, and the clean
//  CineStager map a reference keeps for re-adding markers.
//

import XCTest
import SwiftData
@testable import CinePlanner

final class DuplicateTests: XCTestCase {

    func testSceneDuplicateKeepsBackgroundAlignment() throws {
        let container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let scene = Scene(sceneNumber: 5)
        context.insert(scene)
        scene.sceneMapBackgroundScale = 1.4
        scene.sceneMapBackgroundOffsetX = 0.12
        scene.sceneMapBackgroundOffsetY = -0.08
        scene.sceneMapBackgroundRotation = 17

        let copy = scene.duplicate()
        XCTAssertEqual(copy.sceneMapBackgroundScale, 1.4)
        XCTAssertEqual(copy.sceneMapBackgroundOffsetX, 0.12)
        XCTAssertEqual(copy.sceneMapBackgroundOffsetY, -0.08)
        XCTAssertEqual(copy.sceneMapBackgroundRotation, 17)
    }

    func testReferenceDuplicateKeepsTheCleanMap() {
        let reference = ShotReference(sortOrder: 0)
        reference.mapCleanData = Data([1, 2, 3])
        XCTAssertEqual(reference.duplicate().mapCleanData, Data([1, 2, 3]))
    }
}
