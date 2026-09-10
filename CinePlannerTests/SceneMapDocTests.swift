//
//  SceneMapDocTests.swift
//  CinePlannerTests
//
//  The scene map persists as a JSON string on the scene. `jsonString` is allowed
//  to return nil for a truly empty map (so an untouched scene stores nothing) —
//  but "empty" has to mean no elements *and* no arrows *and* no furniture. Keying
//  it on elements alone silently dropped a furniture-only map (e.g. a floor plan
//  borrowed from another scene), which then vanished on the next reload.
//

import XCTest
@testable import CinePlanner

final class SceneMapDocTests: XCTestCase {

    private func furniture() -> Furniture {
        Furniture(kind: .table, x: 0.4, y: 0.6, width: 0.15, height: 0.10)
    }

    func testEmptyDocEncodesToNil() {
        XCTAssertNil(SceneMapDoc().jsonString)
    }

    func testFurnitureOnlyDocPersists() {
        var doc = SceneMapDoc()
        doc.furniture = [furniture()]
        let json = doc.jsonString
        XCTAssertNotNil(json, "a map with only furniture must still be saved")
        XCTAssertEqual(SceneMapDoc.load(from: json), doc)
    }

    func testArrowOnlyDocPersists() {
        var doc = SceneMapDoc()
        doc.arrows = [MapArrow(fromID: UUID(), toID: UUID(),
                               pivots: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)])]
        let json = doc.jsonString
        XCTAssertNotNil(json, "a map with only arrows must still be saved")
        XCTAssertEqual(SceneMapDoc.load(from: json), doc)
    }
}
