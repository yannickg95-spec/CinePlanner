//
//  CoverageColoringTests.swift
//  CinePlannerTests
//
//  A shot's coverage colour is decided once, here, for the editor overlay, the
//  viewer, the PDF export and the web export alike. The three distributions are
//  easy to describe and easy to break silently, so they are pinned down.
//

import XCTest
import SwiftData
@testable import CinePlanner

final class CoverageColoringTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var project: Project!
    private var version: ScriptVersion!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        project = Project(filmName: "Test")
        version = ScriptVersion(versionNumber: 1)
        context.insert(project)
        context.insert(version)
    }

    override func tearDown() { context = nil; container = nil; project = nil; version = nil }

    /// `scenes` scenes of `shotsPerScene` shots each, in order.
    @discardableResult
    private func buildScript(scenes: Int, shotsPerScene: Int) -> [[Shot]] {
        var built: [[Shot]] = []
        for s in 0..<scenes {
            let scene = Scene(sceneNumber: s + 1)
            scene.sortOrder = s
            scene.scriptVersion = version
            var shots: [Shot] = []
            for n in 0..<shotsPerScene {
                let shot = Shot(shotNumber: n + 1)
                shot.scene = scene
                scene.shots.append(shot)
                shots.append(shot)
            }
            version.scenes.append(scene)
            context.insert(scene)
            built.append(shots)
        }
        return built
    }

    private func coloring() -> CoverageColoring {
        CoverageColoring(version: version, project: project)
    }

    // MARK: - Restart each scene

    func testRestartEachSceneRepeatsThePaletteEveryScene() {
        project.coverageColorMode = .perScene
        let script = buildScript(scenes: 3, shotsPerScene: 3)
        let c = coloring()
        // Shot 1 of every scene shares a colour; that is the point of this mode.
        XCTAssertEqual(c.color(for: script[0][0]), c.color(for: script[1][0]))
        XCTAssertEqual(c.color(for: script[0][0]), c.color(for: script[2][0]))
        // Within a scene the shots differ.
        XCTAssertNotEqual(c.color(for: script[0][0]), c.color(for: script[0][1]))
    }

    // MARK: - Spread across the script

    func testSpreadAcrossScriptKeepsNeighbouringScenesApart() {
        project.coverageColorMode = .acrossScript
        let script = buildScript(scenes: 3, shotsPerScene: 3)
        let c = coloring()
        XCTAssertNotEqual(c.color(for: script[0][0]), c.color(for: script[1][0]),
                          "The palette should carry on into the next scene, not restart.")
    }

    func testSpreadAcrossScriptUsesEveryColourBeforeRepeating() {
        project.coverageColorMode = .acrossScript
        project.coveragePalette = .classic
        let n = CoveragePaletteChoice.classic.colors.count
        let script = buildScript(scenes: 1, shotsPerScene: n)
        let c = coloring()
        let used = Set(script[0].map { c.color(for: $0).description })
        XCTAssertEqual(used.count, n, "All \(n) colours should be used before any repeats.")
    }

    func testSpreadAcrossScriptCyclesOnceThePaletteRunsOut() {
        project.coverageColorMode = .acrossScript
        let n = CoveragePaletteChoice.classic.colors.count
        let script = buildScript(scenes: 1, shotsPerScene: n + 1)
        let c = coloring()
        XCTAssertEqual(c.color(for: script[0][0]), c.color(for: script[0][n]))
    }

    // MARK: - One colour per scene

    func testOneColourPerSceneMakesEveryLineInASceneMatch() {
        project.coverageColorMode = .sceneUniform
        let script = buildScript(scenes: 2, shotsPerScene: 4)
        let c = coloring()
        for shot in script[0] {
            XCTAssertEqual(c.color(for: shot), c.color(for: script[0][0]))
        }
        XCTAssertNotEqual(c.color(for: script[0][0]), c.color(for: script[1][0]),
                          "Scenes should differ from each other.")
    }

    // MARK: - Palette choice

    func testPaletteChoiceChangesTheColoursDrawn() {
        let script = buildScript(scenes: 1, shotsPerScene: 3)
        project.coveragePalette = .classic
        let classic = script[0].map { coloring().color(for: $0).description }
        project.coveragePalette = .highContrast
        let contrast = script[0].map { coloring().color(for: $0).description }
        XCTAssertNotEqual(classic, contrast)
    }

    func testEveryPaletteHasDistinctColours() {
        for choice in CoveragePaletteChoice.allCases {
            let unique = Set(choice.colors.map { $0.description })
            XCTAssertEqual(unique.count, choice.colors.count,
                           "\(choice.label) repeats a colour, so two shots would look alike.")
            XCTAssertGreaterThanOrEqual(choice.colors.count, 5,
                                        "\(choice.label) is too small to separate a scene's coverage.")
        }
    }

    // MARK: - Defaults and edges

    func testDefaultsMatchTheBehaviourProjectsAlreadyHad() {
        XCTAssertEqual(project.coverageColorMode, .perScene)
        XCTAssertEqual(project.coveragePalette, .classic)
    }

    func testSettingsSurviveARoundTripThroughTheirStoredForm() {
        // They persist as raw strings so the attributes stay CloudKit-safe.
        for mode in CoverageColorMode.allCases {
            project.coverageColorMode = mode
            XCTAssertEqual(project.coverageColorMode, mode)
        }
        for palette in CoveragePaletteChoice.allCases {
            project.coveragePalette = palette
            XCTAssertEqual(project.coveragePalette, palette)
        }
    }

    func testUnknownStoredValueFallsBackInsteadOfCrashing() {
        // A newer version of the app could write a mode this build doesn't know.
        project.coverageColorModeRaw = "somethingNewer"
        project.coveragePaletteRaw = "somethingNewer"
        XCTAssertEqual(project.coverageColorMode, .perScene)
        XCTAssertEqual(project.coveragePalette, .classic)
    }

    func testShotOutsideTheVersionStillGetsAColour() {
        let orphanScene = Scene(sceneNumber: 99)
        let orphan = Shot(shotNumber: 1)
        orphan.scene = orphanScene
        orphanScene.shots.append(orphan)
        context.insert(orphanScene)
        XCTAssertNotNil(coloring().color(for: orphan))
    }

    func testArchivedScenesDoNotShiftTheColoursOfLiveOnes() {
        project.coverageColorMode = .acrossScript
        let script = buildScript(scenes: 2, shotsPerScene: 2)
        let before = script[1].map { coloring().color(for: $0).description }
        let archived = Scene(sceneNumber: 50)
        archived.sortOrder = 99
        archived.isArchived = true
        archived.scriptVersion = version
        version.scenes.append(archived)
        context.insert(archived)
        let after = script[1].map { coloring().color(for: $0).description }
        XCTAssertEqual(before, after)
    }
}
