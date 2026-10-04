//
//  ProjectArchiveTests.swift
//  CinePlannerTests
//
//  A `.cineplan` file is how a project is backed up, moved and shared, so whatever
//  goes in has to come back out. Builds a project in an in-memory store, writes it
//  to an archive, reads it into a second store and compares.
//

import XCTest
import SwiftData
@testable import CinePlanner

final class ProjectArchiveTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A small but complete project: one episode, version, scene, shot, reference
    /// and custom field, plus the settings and schedule around them.
    private func makeProject(in context: ModelContext) -> Project {
        let project = Project(filmName: "Defrost")
        project.productionCompany = "Zuidwaarts"
        project.director = "A. Director"
        project.cinematographer = "D. Photography"
        project.coverageColorModeRaw = CoverageColorMode.allCases.last!.rawValue
        project.coveragePaletteRaw = CoveragePaletteChoice.allCases.last!.rawValue
        project.shotSetupFieldOrderRaw = "lens,size,type"
        project.hiddenShotSetupFieldsRaw = "grip"
        project.defaultCamera = "Sony Venice 2"
        project.defaultFramelines = "2.39:1"
        project.defaultLens = "Cooke S4"
        context.insert(project)

        let episode = Episode(episodeNumber: 1, title: "Pilot")
        episode.project = project
        episode.director = "Episode Director"

        let version = ScriptVersion(versionNumber: 2, name: "Pink")
        version.episode = episode
        version.pdfData = Data("%PDF-fake".utf8)
        version.pdfPageOffset = 3
        version.coverageLineMargin = 0.22
        version.coverageLinesOnRight = true

        let scene = Scene(sceneNumber: 12)
        scene.scriptVersion = version
        scene.project = project
        scene.suffix = "A"
        scene.nickname = "Kitchen"
        scene.isDay = false
        scene.isInterior = true
        scene.sceneMapJSON = #"{"elements":[]}"#
        scene.sceneFloorPlanJSON = #"{"walls":[]}"#
        scene.sceneMapMetersWide = 8.5
        scene.sceneFilmToolEnabled = true
        scene.sceneFilmFPS = 24
        let other = Scene(sceneNumber: 13)
        other.scriptVersion = version
        other.project = project
        other.sortOrder = 1

        let shot = Shot(shotNumber: 3, shotInformation: "Push in on the kettle")
        shot.scene = scene
        shot.lensfocal = 50
        shot.camera = "Arri Alexa 35 · 4.6K 16:9"
        shot.extraInfo = "Slow"
        shot.isShot = true
        shot.takeCount = 4
        shot.circledTake = true
        shot.coverageSceneUIDs = [other.uid]
        let second = Shot(shotNumber: 4, shotInformation: "Insert")
        second.scene = scene
        // A camera marker tied to shot 3, and a free-standing one.
        var linked = MapElement(kind: .camera, x: 0.4, y: 0.5)
        linked.label = "3"
        linked.shotUID = shot.uid
        var free = MapElement(kind: .camera, x: 0.6, y: 0.5)
        free.label = "B-cam"
        var map = SceneMapDoc()
        map.elements = [linked, free]
        scene.sceneMapJSON = map.jsonString

        let reference = ShotReference(sortOrder: 0)
        reference.shot = shot
        reference.imageData = Data([0xFF, 0xD8, 0xFF, 0x01])
        reference.note = "Like the trailer"
        reference.mapCleanData = Data([0x89, 0x50, 0x4E, 0x47])

        let info = ShotCustomInfo(sortOrder: 0, kind: "text", label: "Grip", value: "Slider")
        info.shot = shot

        let day = ShootingDay(sortOrder: 0, date: Date(timeIntervalSince1970: 1_800_000_000))
        day.scriptVersion = version
        day.notes = "Early call"
        let entry = ScheduleEntry(scene: scene, sortOrder: 0, note: "Part 1")
        entry.selectedShotUIDs = [shot.uid, second.uid]
        entry.shotShootOrderUIDs = [second.uid, shot.uid]
        entry.day = day
        return project
    }

    private func roundTrip() throws -> (original: Project, copy: Project) {
        let source = try makeContext()
        let original = makeProject(in: source)
        try source.save()
        let data = try ProjectArchive.data(for: original)
        let target = try makeContext()
        let copy = try ProjectArchive.importProject(from: data, into: target)
        try target.save()
        return (original, copy)
    }

    func testRoundTripKeepsTheShotList() throws {
        let (original, copy) = try roundTrip()
        XCTAssertEqual(copy.filmName, "Defrost")
        XCTAssertNotEqual(copy.uid, original.uid, "an import gets fresh ids")

        let episode = try XCTUnwrap(copy.orderedEpisodes.first)
        XCTAssertEqual(episode.title, "Pilot")
        let version = try XCTUnwrap(episode.orderedVersions.first)
        XCTAssertEqual(version.name, "Pink")
        XCTAssertEqual(version.pdfData, Data("%PDF-fake".utf8))
        XCTAssertEqual(version.pdfPageOffset, 3)
        XCTAssertEqual(version.coverageLineMargin, 0.22, accuracy: 0.0001)

        let scene = try XCTUnwrap(version.orderedScenes.first)
        XCTAssertEqual(scene.sceneNumber, 12)
        XCTAssertEqual(scene.suffix, "A")
        XCTAssertEqual(scene.nickname, "Kitchen")
        XCTAssertFalse(scene.isDay)
        XCTAssertEqual(scene.sceneFloorPlanJSON, #"{"walls":[]}"#)
        XCTAssertEqual(scene.sceneMapMetersWide, 8.5)

        let shot = try XCTUnwrap(scene.shots.first { $0.shotNumber == 3 })
        XCTAssertEqual(shot.shotInformation, "Push in on the kettle")
        XCTAssertEqual(shot.lensfocal, 50)
        XCTAssertEqual(shot.camera, "Arri Alexa 35 · 4.6K 16:9")
        XCTAssertEqual(shot.extraInfo, "Slow")

        let reference = try XCTUnwrap(shot.references.first)
        XCTAssertEqual(reference.imageData, Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertEqual(reference.note, "Like the trailer")
        XCTAssertEqual(shot.orderedCustomInfo.first?.label, "Grip")
        XCTAssertEqual(shot.orderedCustomInfo.first?.value, "Slider")
    }

    func testRoundTripKeepsCreditsSettingsAndOnSetState() throws {
        let (_, copy) = try roundTrip()
        XCTAssertEqual(copy.productionCompany, "Zuidwaarts")
        XCTAssertEqual(copy.director, "A. Director")
        XCTAssertEqual(copy.cinematographer, "D. Photography")
        XCTAssertEqual(copy.coverageColorModeRaw, CoverageColorMode.allCases.last!.rawValue)
        XCTAssertEqual(copy.coveragePaletteRaw, CoveragePaletteChoice.allCases.last!.rawValue)
        XCTAssertEqual(copy.shotSetupFieldOrderRaw, "lens,size,type")
        XCTAssertEqual(copy.hiddenShotSetupFieldsRaw, "grip")
        XCTAssertEqual(copy.defaultCamera, "Sony Venice 2")
        XCTAssertEqual(copy.defaultFramelines, "2.39:1")
        XCTAssertEqual(copy.defaultLens, "Cooke S4")

        let episode = try XCTUnwrap(copy.orderedEpisodes.first)
        XCTAssertEqual(episode.director, "Episode Director")
        let version = try XCTUnwrap(episode.orderedVersions.first)
        XCTAssertTrue(version.coverageLinesOnRight)

        let scene = try XCTUnwrap(version.orderedScenes.first)
        XCTAssertTrue(scene.sceneFilmToolEnabled)
        XCTAssertEqual(scene.sceneFilmFPS, 24)
        let shot = try XCTUnwrap(scene.shots.first { $0.shotNumber == 3 })
        XCTAssertTrue(shot.isShot)
        XCTAssertEqual(shot.takeCount, 4)
        XCTAssertTrue(shot.circledTake)
        XCTAssertEqual(shot.references.first?.mapCleanData, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testRoundTripKeepsTheScheduleAndRepointsItsReferences() throws {
        let (_, copy) = try roundTrip()
        let version = try XCTUnwrap(copy.orderedEpisodes.first?.orderedVersions.first)
        let scene = try XCTUnwrap(version.orderedScenes.first)
        let other = try XCTUnwrap(version.orderedScenes.last)
        let shot = try XCTUnwrap(scene.shots.first { $0.shotNumber == 3 })
        let second = try XCTUnwrap(scene.shots.first { $0.shotNumber == 4 })

        let day = try XCTUnwrap(version.orderedShootingDays.first)
        XCTAssertEqual(day.date, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(day.notes, "Early call")
        let entry = try XCTUnwrap(day.orderedEntries.first)
        XCTAssertEqual(entry.note, "Part 1")
        // The strip points at the imported scene and shots — their new uids.
        XCTAssertTrue(entry.scene === scene)
        XCTAssertEqual(entry.selectedShotUIDs, [shot.uid, second.uid])
        XCTAssertEqual(entry.shotShootOrderUIDs, [second.uid, shot.uid])
        XCTAssertEqual(entry.resolvedShots.map(\.shotNumber), [4, 3])
        // And the coverage alias points at the imported other scene.
        XCTAssertEqual(shot.coverageSceneUIDs, [other.uid])
    }

    func testCameraMarkersFollowTheirShotsToTheNewIDs() throws {
        let (_, copy) = try roundTrip()
        let scene = try XCTUnwrap(copy.orderedEpisodes.first?.orderedVersions.first?.orderedScenes.first)
        let shot = try XCTUnwrap(scene.shots.first { $0.shotNumber == 3 })
        let map = SceneMapDoc.load(from: scene.sceneMapJSON)
        XCTAssertEqual(map.elements.count, 2)
        // Still linked — to the imported shot — so opening the map won't prune it.
        XCTAssertEqual(map.elements.first { $0.label == "3" }?.shotUID, shot.uid)
        XCTAssertNil(map.elements.first { $0.label == "B-cam" }?.shotUID)
    }

    /// Archives written before these fields existed must still open.
    func testAnArchiveWithoutTheNewerFieldsStillImports() throws {
        let source = try makeContext()
        let original = makeProject(in: source)
        try source.save()
        let newer: Set<String> = [
            "productionCompany", "director", "cinematographer", "coveragePalette", "coverageColorMode",
            "shotSetupFieldOrder", "hiddenShotSetupFields", "defaultCamera", "defaultFramelines", "defaultLens",
            "coverageLinesOnRight", "shootingDays", "uid", "sceneMapImportedMetersWide", "sceneFilmToolEnabled",
            "sceneFilmGauge", "sceneFilmFPS", "sceneFilmMode", "isShot", "takeCount", "circledTake",
            "coverageSceneUIDs", "mapCleanData",
        ]
        func strip(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.filter { !newer.contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: ProjectArchive.data(for: original))
        let oldStyle = try JSONSerialization.data(withJSONObject: strip(json))

        let target = try makeContext()
        let copy = try ProjectArchive.importProject(from: oldStyle, into: target)
        XCTAssertEqual(copy.filmName, "Defrost")
        XCTAssertEqual(copy.director, "")
        let version = try XCTUnwrap(copy.orderedEpisodes.first?.orderedVersions.first)
        XCTAssertEqual(version.scenes.count, 2)
        XCTAssertTrue(version.shootingDays.isEmpty)
        XCTAssertFalse(version.coverageLinesOnRight)
        // Its shot-linked camera can't be matched (no shot uids back then), so it's
        // kept as a free camera instead of being pruned as an orphan.
        let scene = try XCTUnwrap(version.orderedScenes.first)
        let map = SceneMapDoc.load(from: scene.sceneMapJSON)
        XCTAssertEqual(map.elements.count, 2)
        XCTAssertTrue(map.elements.allSatisfy { $0.shotUID == nil })
    }
}
