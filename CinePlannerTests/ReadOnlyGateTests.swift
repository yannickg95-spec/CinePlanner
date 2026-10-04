//
//  ReadOnlyGateTests.swift
//  CinePlannerTests
//
//  After the trial nothing may be saved: with the gate on, a save rolls the edit
//  back and the store keeps what it had. Lifting it (a purchase) saves normally.
//

import XCTest
import SwiftData
@testable import CinePlanner

@MainActor
final class ReadOnlyGateTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        ReadOnlyGate.mainContext = context
    }

    override func tearDown() {
        ReadOnlyGate.isActive = false
        ReadOnlyGate.mainContext = nil
        context = nil
        container = nil
    }

    private func storedName() throws -> String? {
        try ModelContext(container).fetch(FetchDescriptor<Project>()).first?.filmName
    }

    func testReadOnlyKeepsEditsOutOfTheStore() throws {
        let project = Project(filmName: "Original")
        context.insert(project)
        context.saveReporting()

        ReadOnlyGate.isActive = true
        XCTAssertFalse(context.autosaveEnabled, "autosave is off while read-only")
        project.filmName = "Edited after the trial"
        context.saveReporting()

        XCTAssertEqual(project.filmName, "Original", "the edit is rolled back")
        XCTAssertEqual(try storedName(), "Original")
        XCTAssertFalse(context.hasChanges)
    }

    func testUnlockingSavesAgain() throws {
        let project = Project(filmName: "Original")
        context.insert(project)
        ReadOnlyGate.isActive = true
        ReadOnlyGate.isActive = false
        XCTAssertTrue(context.autosaveEnabled)
        project.filmName = "Edited after unlocking"
        context.saveReporting()
        XCTAssertEqual(try storedName(), "Edited after unlocking")
    }
}
