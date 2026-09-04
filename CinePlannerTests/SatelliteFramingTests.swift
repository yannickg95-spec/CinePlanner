//
//  SatelliteFramingTests.swift
//  CinePlannerTests
//
//  SatelliteFraming decides which patch of world a scene map covers and where a
//  marker sits inside it. A mistake here is invisible — the map still looks like a
//  map — until every marker has quietly drifted off the ground it was placed on, so
//  the round-trip is pinned down exactly.
//

import XCTest
import CoreGraphics
import MapKit
import CoreLocation
@testable import CinePlanner

final class SatelliteFramingTests: XCTestCase {

    private let amsterdam = CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952)
    private func framing(_ meters: Double = 60) -> SatelliteFraming {
        SatelliteFraming(center: amsterdam, meters: meters)
    }

    /// A canvas wider than it is tall, with the square background fitted into it —
    /// the everyday case in the editor.
    private let canvas = CGSize(width: 900, height: 640)
    private var contentWidth: CGFloat { min(canvas.width, canvas.height) }

    /// Where a normalized marker appears on screen under the editor's
    /// `scaleEffect(zoom, anchor: .center).offset(pan)`.
    private func screenPoint(_ n: CGPoint, zoom: CGFloat, pan: CGSize) -> CGPoint {
        let side = contentWidth
        let rect = CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2,
                          width: side, height: side)
        let lx = rect.minX + n.x * rect.width
        let ly = rect.minY + n.y * rect.height
        return CGPoint(x: canvas.width / 2 + (lx - canvas.width / 2) * zoom + pan.width,
                       y: canvas.height / 2 + (ly - canvas.height / 2) * zoom + pan.height)
    }

    // MARK: - What the canvas frames

    func testAtRestTheFramingIsTheStoredCapture() {
        let anchor = framing()
        let capture = anchor.capture(contentWidth: contentWidth, canvas: canvas, zoom: 1, pan: .zero)
        XCTAssertEqual(capture?.meters ?? 0, anchor.meters, accuracy: 0.0001)
        XCTAssertEqual(capture?.center.latitude ?? 0, anchor.center.latitude, accuracy: 1e-9)
        XCTAssertEqual(capture?.center.longitude ?? 0, anchor.center.longitude, accuracy: 1e-9)
    }

    func testZoomingOutWidensTheCaptureProportionally() {
        let anchor = framing()
        let out = anchor.capture(contentWidth: contentWidth, canvas: canvas, zoom: 0.5, pan: .zero)
        XCTAssertEqual(out?.meters ?? 0, anchor.meters * 2, accuracy: 0.0001,
                       "Half the zoom shows twice the ground.")
        let inward = anchor.capture(contentWidth: contentWidth, canvas: canvas, zoom: 2, pan: .zero)
        XCTAssertEqual(inward?.meters ?? 0, anchor.meters / 2, accuracy: 0.0001)
    }

    func testPanningMovesTheCaptureButNotItsSize() {
        let anchor = framing()
        let panned = anchor.capture(contentWidth: contentWidth, canvas: canvas, zoom: 1,
                                    pan: CGSize(width: 150, height: 0))
        XCTAssertEqual(panned?.meters ?? 0, anchor.meters, accuracy: 0.0001)
        XCTAssertLessThan(panned?.center.longitude ?? 0, anchor.center.longitude,
                          "Dragging the map right shows ground to the west.")
    }

    func testADegenerateCanvasHasNoFraming() {
        XCTAssertNil(framing().canvasRect(contentWidth: 0, canvas: canvas, zoom: 1, pan: .zero))
        XCTAssertNil(framing().canvasRect(contentWidth: 400, canvas: .zero, zoom: 1, pan: .zero))
        XCTAssertNil(framing().canvasRect(contentWidth: 400, canvas: canvas, zoom: 0, pan: .zero))
    }

    // MARK: - The promise: committing a framing doesn't move anything

    func testMarkersStayPutOnScreenAcrossACommit() {
        let anchor = framing()
        let markers = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.12, y: 0.83),
                       CGPoint(x: 0.97, y: 0.04), CGPoint(x: 0, y: 1)]
        let framings: [(CGFloat, CGSize)] = [
            (1, CGSize(width: 120, height: -70)),
            (2.5, CGSize(width: -40, height: 30)),
            (0.4, CGSize(width: 200, height: 150)),
            (0.3, .zero),
            (4, CGSize(width: -300, height: -220))
        ]
        for (zoom, pan) in framings {
            guard let target = anchor.capture(contentWidth: contentWidth, canvas: canvas,
                                              zoom: zoom, pan: pan) else {
                return XCTFail("No capture for zoom \(zoom)")
            }
            for marker in markers {
                let before = screenPoint(marker, zoom: zoom, pan: pan)
                // After committing, the new capture fills the content rect at rest.
                let after = screenPoint(anchor.remap(marker, to: target), zoom: 1, pan: .zero)
                XCTAssertEqual(before.x, after.x, accuracy: 0.01,
                               "Marker \(marker) shifted at zoom \(zoom)")
                XCTAssertEqual(before.y, after.y, accuracy: 0.01,
                               "Marker \(marker) shifted at zoom \(zoom)")
            }
        }
    }

    func testRemappingToTheSameCaptureChangesNothing() {
        let anchor = framing()
        let p = CGPoint(x: 0.31, y: 0.77)
        let same = anchor.remap(p, to: anchor)
        XCTAssertEqual(same.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(same.y, p.y, accuracy: 1e-9)
    }

    func testRemappingIsReversible() {
        let a = framing(60)
        let b = SatelliteFraming(center: CLLocationCoordinate2D(latitude: 52.3710, longitude: 4.8961),
                                 meters: 25)
        let p = CGPoint(x: 0.44, y: 0.52)
        let back = b.remap(a.remap(p, to: b), to: a)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }

    func testGroundOutsideTheNewCaptureLandsOutsideZeroToOne() {
        let a = framing(400)
        let tight = SatelliteFraming(center: amsterdam, meters: 20)
        let corner = a.remap(CGPoint(x: 0.02, y: 0.02), to: tight)
        XCTAssertLessThan(corner.x, 0, "A far corner isn't in a tight capture, and shouldn't pretend to be.")
        XCTAssertLessThan(corner.y, 0)
    }

    func testSizesKeepTheirRealDimensions() {
        let wide = framing(60)
        let tight = framing(20)
        // A table taking a fifth of a 60 m capture is 12 m; in a 20 m capture that's
        // three fifths of the width.
        XCTAssertEqual(0.2 * wide.sizeRatio(to: tight), 0.6, accuracy: 1e-9)
    }

    // MARK: - Same place or a different one

    func testOverlapDecidesWhetherMarkersTravel() {
        let here = framing(60)
        XCTAssertTrue(here.overlaps(framing(30)), "A tighter capture of the same spot is the same place.")
        XCTAssertTrue(here.overlaps(SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 52.3704, longitude: 4.8955), meters: 60)),
            "A nudge is still the same place.")
        XCTAssertFalse(here.overlaps(SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), meters: 60)),
            "Paris is not Amsterdam.")
    }
}
