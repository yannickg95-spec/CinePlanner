//
//  CoveragePaletteTests.swift
//  CinePlannerTests
//
//  The palette exists to keep one promise: a shot is the same colour in the
//  editor, the viewer, the PDF and the published page. These tests pin the
//  properties that promise depends on.
//

import XCTest
@testable import CinePlanner

final class CoveragePaletteTests: XCTestCase {

    func testPaletteIsNotEmpty() {
        XCTAssertFalse(CoveragePalette.colors.isEmpty)
    }

    func testColoursAreDistinct() {
        // Two shots in one scene sharing a colour would make coverage ambiguous.
        XCTAssertEqual(Set(CoveragePalette.colors.map { $0.description }).count,
                       CoveragePalette.colors.count)
    }

    func testColourIsAPureFunctionOfTheIndex() {
        for index in 0..<50 {
            XCTAssertEqual(CoveragePalette.color(at: index).description,
                           CoveragePalette.color(at: index).description)
        }
    }

    func testColoursCycleOnceThePaletteRunsOut() {
        let count = CoveragePalette.colors.count
        XCTAssertEqual(CoveragePalette.color(at: 0).description,
                       CoveragePalette.color(at: count).description)
        XCTAssertEqual(CoveragePalette.color(at: 3).description,
                       CoveragePalette.color(at: count + 3).description)
    }

    func testANegativeIndexDoesNotTrap() {
        // Defensive: an index is derived from a lookup that can fail to find a shot.
        XCTAssertEqual(CoveragePalette.color(at: -1).description,
                       CoveragePalette.color(at: 1).description)
    }

    func testFirstColoursMatchTheOrderEveryRendererAssumes() {
        // The order is the contract — reordering it silently recolours old exports.
        XCTAssertEqual(CoveragePalette.colors.count, 10)
        XCTAssertEqual(CoveragePalette.colors[0].description, PlatformColor.systemBlue.description)
        XCTAssertEqual(CoveragePalette.colors[1].description, PlatformColor.systemGreen.description)
    }
}
