//
//  EditHistoryTests.swift
//  CinePlannerTests
//
//  The scene map's undo/redo rules.
//

import XCTest
@testable import CinePlanner

final class EditHistoryTests: XCTestCase {

    func testUndoAndRedoWalkTheEdits() {
        var history = EditHistory<String>()
        var state = "a"
        // Two edits: a → b → c.
        history.record(state); state = "b"
        history.record(state); state = "c"

        state = history.undo(from: state) ?? state
        XCTAssertEqual(state, "b")
        state = history.undo(from: state) ?? state
        XCTAssertEqual(state, "a")
        XCTAssertNil(history.undo(from: state), "nothing before the first edit")

        state = history.redo(from: state) ?? state
        XCTAssertEqual(state, "b")
        state = history.redo(from: state) ?? state
        XCTAssertEqual(state, "c")
        XCTAssertNil(history.redo(from: state))
    }

    func testANewEditClearsRedo() {
        var history = EditHistory<String>()
        var state = "a"
        history.record(state); state = "b"
        state = history.undo(from: state) ?? state
        XCTAssertTrue(history.canRedo)
        history.record(state); state = "x"   // a different edit after undoing
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo(from: state), "a")
    }

    func testOldestStepsFallOffAtTheLimit() {
        var history = EditHistory<Int>()
        history.limit = 3
        for i in 0..<5 { history.record(i) }
        XCTAssertEqual(history.undoStack, [2, 3, 4])
    }

    func testResetForgetsEverything() {
        var history = EditHistory<Int>()
        history.record(1)
        _ = history.undo(from: 2)
        history.reset()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}
