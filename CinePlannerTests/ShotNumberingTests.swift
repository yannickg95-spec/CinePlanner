//
//  ShotNumberingTests.swift
//  CinePlannerTests
//
//  Shot numbers appear on call sheets, coverage lines and every export, so the
//  three numbering styles need to stay exactly as they are. Uses an in-memory
//  store, so nothing here touches the user's data.
//

import XCTest
import SwiftData
@testable import CinePlanner

final class ShotNumberingTests: XCTestCase {

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

    /// A scene with one shot, wired up the way the app does it.
    private func makeShot(scene sceneNumber: Int, shot shotNumber: Int,
                          sceneSuffix: String = "", shotSuffix: String = "") -> Shot {
        let scene = Scene(sceneNumber: sceneNumber)
        scene.suffix = sceneSuffix
        let shot = Shot(shotNumber: shotNumber)
        shot.suffix = shotSuffix
        shot.scene = scene
        scene.shots.append(shot)
        context.insert(scene)
        return shot
    }

    func testNumberStyleJoinsSceneAndShot() {
        let shot = makeShot(scene: 12, shot: 3)
        XCTAssertEqual(shot.formattedNumber(style: .numbers), "12.3")
    }

    func testLetterStyleUsesLettersForTheShot() {
        XCTAssertEqual(makeShot(scene: 12, shot: 1).formattedNumber(style: .letters), "12.A")
        XCTAssertEqual(makeShot(scene: 12, shot: 2).formattedNumber(style: .letters), "12.B")
    }

    func testLetterStyleCarriesPastZ() {
        // The 27th shot must not collapse back onto "A".
        let z = makeShot(scene: 1, shot: 26).formattedNumber(style: .letters)
        let aa = makeShot(scene: 1, shot: 27).formattedNumber(style: .letters)
        XCTAssertEqual(z, "1.Z")
        XCTAssertNotEqual(aa, "1.A")
        XCTAssertEqual(aa, "1.AA")
    }

    func testSceneSuffixIsKept() {
        // Scene 12A is a real, distinct scene — its shots must say so.
        XCTAssertEqual(makeShot(scene: 12, shot: 3, sceneSuffix: "A").formattedNumber(style: .numbers), "12A.3")
    }

    func testShotSuffixIsKept() {
        XCTAssertEqual(makeShot(scene: 12, shot: 3, shotSuffix: "X").formattedNumber(style: .numbers), "12.3X")
    }

    func testShotWithoutASceneDoesNotCrash() {
        // Shots exist briefly before being attached, and during import.
        let orphan = Shot(shotNumber: 4)
        context.insert(orphan)
        XCTAssertFalse(orphan.formattedNumber(style: .numbers).isEmpty)
    }

    func testDisplayNumberFollowsTheShotsOwnStyle() {
        let shot = makeShot(scene: 5, shot: 2)
        shot.numberingStyle = .letters
        XCTAssertEqual(shot.displayNumber, shot.formattedNumber(style: .letters))
    }
}
