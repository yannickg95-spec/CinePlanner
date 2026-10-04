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

        let shot = Shot(shotNumber: 3, shotInformation: "Push in on the kettle")
        shot.scene = scene
        shot.lensfocal = 50
        shot.camera = "Arri Alexa 35 · 4.6K 16:9"
        shot.extraInfo = "Slow"
        shot.isShot = true
        shot.takeCount = 4
        shot.circledTake = true

        let reference = ShotReference(sortOrder: 0)
        reference.shot = shot
        reference.imageData = Data([0xFF, 0xD8, 0xFF, 0x01])
        reference.note = "Like the trailer"

        let info = ShotCustomInfo(sortOrder: 0, kind: "text", label: "Grip", value: "Slider")
        info.shot = shot

        let day = ShootingDay(sortOrder: 0, date: Date(timeIntervalSince1970: 1_800_000_000))
        day.scriptVersion = version
        let entry = ScheduleEntry(scene: scene, sortOrder: 0, note: "Part 1")
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

        let scene = try XCTUnwrap(version.scenes.first)
        XCTAssertEqual(scene.sceneNumber, 12)
        XCTAssertEqual(scene.suffix, "A")
        XCTAssertEqual(scene.nickname, "Kitchen")
        XCTAssertFalse(scene.isDay)
        XCTAssertEqual(scene.sceneMapJSON, #"{"elements":[]}"#)
        XCTAssertEqual(scene.sceneFloorPlanJSON, #"{"walls":[]}"#)
        XCTAssertEqual(scene.sceneMapMetersWide, 8.5)

        let shot = try XCTUnwrap(scene.shots.first)
        XCTAssertEqual(shot.shotNumber, 3)
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

    /// Known gaps: these aren't written to the archive yet, so they're lost on a
    /// backup/restore or when a project is shared as a file. Remove the expected
    /// failure once the archive carries them.
    func testRoundTripKeepsCreditsOnSetStateAndSchedule() throws {
        let (_, copy) = try roundTrip()
        let episode = try XCTUnwrap(copy.orderedEpisodes.first)
        let version = try XCTUnwrap(episode.orderedVersions.first)
        let shot = try XCTUnwrap(version.scenes.first?.shots.first)

        XCTExpectFailure("The .cineplan archive doesn't carry credits, on-set state or the schedule yet.")
        XCTAssertEqual(copy.productionCompany, "Zuidwaarts")
        XCTAssertEqual(copy.director, "A. Director")
        XCTAssertEqual(copy.cinematographer, "D. Photography")
        XCTAssertEqual(episode.director, "Episode Director")
        XCTAssertTrue(version.coverageLinesOnRight)
        XCTAssertTrue(shot.isShot)
        XCTAssertEqual(shot.takeCount, 4)
        XCTAssertTrue(shot.circledTake)
        XCTAssertEqual(version.shootingDays.count, 1)
        XCTAssertEqual(version.shootingDays.first?.orderedEntries.first?.note, "Part 1")
    }
}
