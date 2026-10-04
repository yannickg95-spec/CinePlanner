//
//  SyncRefreshTests.swift
//  CinePlannerTests
//
//  After an iCloud import, SyncRefresher re-fetches only what the import changed
//  (plus parents) in the UI's context. These play the import with a second context
//  on a real on-disk store, read the store's history the way the app does, and check
//  the UI context then shows the other device's edits, additions and deletions.
//

import XCTest
import SwiftData
@testable import CinePlanner

@MainActor
final class SyncRefreshTests: XCTestCase {

    private var container: ModelContainer!
    private var main: ModelContext!
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).store")
        container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        main = container.mainContext
        main.author = SyncRefresher.localAuthor
    }

    override func tearDown() {
        main = nil
        container = nil
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }

    /// A project with one scene holding one shot, saved by the UI context.
    private func makeScene() throws -> Scene {
        let project = Project(filmName: "Sync")
        main.insert(project)
        let episode = Episode(episodeNumber: 1); episode.project = project
        let version = ScriptVersion(versionNumber: 1); version.episode = episode
        let scene = Scene(sceneNumber: 1); scene.scriptVersion = version; scene.project = project
        let shot = Shot(shotNumber: 1, shotInformation: "Wide"); shot.scene = scene
        try main.save()
        _ = scene.shots.count   // load the relationship, as a list on screen would
        return scene
    }

    private func latestToken() throws -> DefaultHistoryToken? {
        try ModelContext(container).fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last?.token
    }

    /// The changes made by anyone but the UI context since `token`.
    private func remoteChanges(since token: DefaultHistoryToken?) throws -> [HistoryChange] {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token { descriptor.predicate = #Predicate { $0.token > token } }
        return try ModelContext(container).fetchHistory(descriptor)
            .filter { $0.author != SyncRefresher.localAuthor }
            .flatMap(\.changes)
    }

    func testEditsAndAdditionsFromAnotherDeviceAppear() throws {
        let scene = try makeScene()
        let shot = try XCTUnwrap(scene.shots.first)
        let sceneID = scene.persistentModelID
        let token = try latestToken()

        // "Another device": a separate context edits the shot and adds a new one.
        let importer = ModelContext(container)
        let remoteScene = try XCTUnwrap(importer.fetch(FetchDescriptor<Scene>(predicate: #Predicate { $0.persistentModelID == sceneID })).first)
        remoteScene.shots.first?.shotInformation = "Wide, slow push"
        let added = Shot(shotNumber: 2, shotInformation: "Close-up"); added.scene = remoteScene
        try importer.save()

        XCTAssertEqual(shot.shotInformation, "Wide", "the UI context is stale until refreshed")
        XCTAssertEqual(scene.shots.count, 1)

        SyncRefresher.refresh(try remoteChanges(since: token), in: main)

        XCTAssertEqual(shot.shotInformation, "Wide, slow push")
        XCTAssertEqual(scene.shots.count, 2)
        XCTAssertEqual(Set(scene.shots.map(\.shotInformation)), ["Wide, slow push", "Close-up"])
    }

    func testDeletionsFromAnotherDeviceDisappear() throws {
        let scene = try makeScene()
        let extra = Shot(shotNumber: 2, shotInformation: "Insert"); extra.scene = scene
        try main.save()
        XCTAssertEqual(scene.shots.count, 2)
        let extraID = extra.persistentModelID
        let token = try latestToken()

        let importer = ModelContext(container)
        let remoteShot = try XCTUnwrap(importer.fetch(FetchDescriptor<Shot>(predicate: #Predicate { $0.persistentModelID == extraID })).first)
        importer.delete(remoteShot)
        try importer.save()

        SyncRefresher.refresh(try remoteChanges(since: token), in: main)
        XCTAssertEqual(scene.shots.count, 1)
        XCTAssertEqual(scene.shots.first?.shotInformation, "Wide")
    }

    func testOwnSavesAreNotTreatedAsRemote() throws {
        _ = try makeScene()
        let token = try latestToken()
        let project = try XCTUnwrap(main.fetch(FetchDescriptor<Project>()).first)
        project.filmName = "Renamed here"
        try main.save()
        XCTAssertTrue(try remoteChanges(since: token).isEmpty)
    }
}
