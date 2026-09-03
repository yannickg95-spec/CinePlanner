//
//  CoveragePaletteTests.swift
//  CinePlannerTests
//
//  The palettes themselves. The classic set matters most: it is what every
//  existing project is coloured with, and reordering it would silently recolour
//  shot lists people have already planned and printed.
//

import XCTest
@testable import CinePlanner

final class CoveragePaletteTests: XCTestCase {

    func testClassicKeepsTheOrderExistingProjectsWerePlannedWith() {
        let classic = CoveragePaletteChoice.classic.colors
        XCTAssertEqual(classic.count, 10)
        XCTAssertEqual(classic[0].description, PlatformColor.systemBlue.description)
        XCTAssertEqual(classic[1].description, PlatformColor.systemGreen.description)
        XCTAssertEqual(classic[2].description, PlatformColor.systemOrange.description)
    }

    func testEveryPaletteIsUsable() {
        for choice in CoveragePaletteChoice.allCases {
            XCTAssertFalse(choice.colors.isEmpty, "\(choice.label) has no colours")
            XCTAssertFalse(choice.label.isEmpty)
            XCTAssertFalse(choice.detail.isEmpty, "\(choice.label) has nothing to explain itself with")
        }
    }

    func testEveryModeDescribesItself() {
        // The sheet offers these by name and explanation; an empty one is a blank row.
        for mode in CoverageColorMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty)
        }
    }

    func testRawValuesAreStableBecauseTheyArePersisted() {
        // These strings sit in the store and sync through iCloud; renaming a case
        // without keeping its raw value would reset everyone's choice.
        XCTAssertEqual(CoveragePaletteChoice.classic.rawValue, "classic")
        XCTAssertEqual(CoveragePaletteChoice.highContrast.rawValue, "highContrast")
        XCTAssertEqual(CoverageColorMode.perScene.rawValue, "perScene")
        XCTAssertEqual(CoverageColorMode.acrossScript.rawValue, "acrossScript")
        XCTAssertEqual(CoverageColorMode.sceneUniform.rawValue, "sceneUniform")
    }

    func testDisplayColoursMatchTheDrawnOnes() {
        for choice in CoveragePaletteChoice.allCases {
            XCTAssertEqual(choice.displayColors.count, choice.colors.count,
                           "\(choice.label): the settings swatches must show what gets drawn")
        }
    }
}
