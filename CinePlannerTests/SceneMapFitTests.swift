//
//  SceneMapFitTests.swift
//  CinePlannerTests
//
//  A CineStager import can place a camera outside — or right on the edge of — the
//  room's top-down image. The scene map then zooms out (a placement scale < 1) just
//  enough that every marker, icon and all, sits in view. The fit is pinned here:
//  identity when everything is comfortably inside, and a uniform scale set by
//  whichever marker (padded by its icon's reach) extends furthest.
//

import XCTest
import CoreGraphics
@testable import CinePlanner

final class SceneMapFitTests: XCTestCase {

    private let m = 0.15   // default markerHalfExtent
    private let pad = 0.9  // default padding

    func testComfortablyInsideKeepsIdentity() {
        let fit = SceneMapBackgroundTransform.fittingMarkers(
            [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)])
        XCTAssertTrue(fit.isIdentity)
    }

    func testNoMarkersKeepsIdentity() {
        XCTAssertTrue(SceneMapBackgroundTransform.fittingMarkers([]).isIdentity)
    }

    func testMarkerOutsideZoomsOut() {
        let fit = SceneMapBackgroundTransform.fittingMarkers([CGPoint(x: 1.3, y: 0.5)])
        // reach = (1.3 + m) - 0.5 = 0.88 → scale = (0.5 / 0.88) * pad
        XCTAssertEqual(fit.scale, (0.5 / (1.3 + m - 0.5)) * pad, accuracy: 0.0001)
        XCTAssertEqual(fit.offsetX, 0)
        XCTAssertEqual(fit.rotation, 0)
    }

    func testCameraOnTopWallZoomsOutSoItsIconClears() {
        // The real CineStager case: anchor just inside the top edge, icon poking out.
        let fit = SceneMapBackgroundTransform.fittingMarkers([CGPoint(x: 0.55, y: 0.055)])
        XCTAssertLessThan(fit.scale, 1.0)
        XCTAssertEqual(fit.scale, (0.5 / (0.5 - (0.055 - m))) * pad, accuracy: 0.0001)
    }

    func testFurthestAxisSetsTheScale() {
        let fit = SceneMapBackgroundTransform.fittingMarkers(
            [CGPoint(x: -0.1, y: 0.5), CGPoint(x: 0.5, y: 1.1)])
        // left reach = 0.5 - (-0.1 - m) ; bottom reach = (1.1 + m) - 0.5 — equal.
        XCTAssertEqual(fit.scale, (0.5 / (0.6 + m)) * pad, accuracy: 0.0001)
    }

    func testVeryFarMarkerClampsToTheFloor() {
        let fit = SceneMapBackgroundTransform.fittingMarkers([CGPoint(x: 6, y: 0.5)])
        XCTAssertEqual(fit.scale, SceneMapBackgroundTransform.scaleRange.lowerBound, accuracy: 0.0001)
    }
}
