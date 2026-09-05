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
        XCTAssertNil(framing().capture(contentWidth: 0, canvas: canvas, zoom: 1, pan: .zero))
        XCTAssertNil(framing().capture(contentWidth: 400, canvas: .zero, zoom: 1, pan: .zero))
        XCTAssertNil(framing().capture(contentWidth: 400, canvas: canvas, zoom: 0, pan: .zero))
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

// MARK: - Turning the map

extension SatelliteFramingTests {

    private var here: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952) }

    func testANorthUpCaptureIsUnaffectedByTheRotationMaths() {
        // The turn is new; captures made before it must remap exactly as they did.
        let a = SatelliteFraming(center: here, meters: 60)
        let b = SatelliteFraming(center: CLLocationCoordinate2D(latitude: 52.3706, longitude: 4.8958),
                                 meters: 25)
        for p in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.83, y: 0.22)] {
            let turned = a.remap(p, to: b)
            // Same thing computed the old way: straight scale and shift.
            let oldSide = 60 * MKMapPointsPerMeterAtLatitude(a.center.latitude)
            let newSide = 25 * MKMapPointsPerMeterAtLatitude(b.center.latitude)
            let oldC = MKMapPoint(a.center), newC = MKMapPoint(b.center)
            let wx = oldC.x + (Double(p.x) - 0.5) * oldSide
            let wy = oldC.y + (Double(p.y) - 0.5) * oldSide
            XCTAssertEqual(Double(turned.x), 0.5 + (wx - newC.x) / newSide, accuracy: 1e-12)
            XCTAssertEqual(Double(turned.y), 0.5 + (wy - newC.y) / newSide, accuracy: 1e-12)
        }
    }

    func testTurningTheMapMovesMarkersAroundItsCentre() {
        // Same ground, same size, turned a quarter turn clockwise: what was to the
        // north of centre is now to the west of it, i.e. left of centre in the image.
        let north = SatelliteFraming(center: here, meters: 60, heading: 0)
        let turned = SatelliteFraming(center: here, meters: 60, heading: 90)
        let aboveCentre = CGPoint(x: 0.5, y: 0.2)          // north of centre
        let moved = north.remap(aboveCentre, to: turned)
        XCTAssertEqual(Double(moved.x), 0.2, accuracy: 1e-9, "north should now lie to the left")
        XCTAssertEqual(Double(moved.y), 0.5, accuracy: 1e-9)
    }

    func testTheCentreNeverMovesHoweverTheMapIsTurned() {
        let a = SatelliteFraming(center: here, meters: 60, heading: 0)
        for heading in [0.0, 37.0, 90.0, 180.0, -145.0] {
            let b = SatelliteFraming(center: here, meters: 60, heading: heading)
            let c = a.remap(CGPoint(x: 0.5, y: 0.5), to: b)
            XCTAssertEqual(Double(c.x), 0.5, accuracy: 1e-9)
            XCTAssertEqual(Double(c.y), 0.5, accuracy: 1e-9)
        }
    }

    func testRemappingBetweenTurnedCapturesIsReversible() {
        let a = SatelliteFraming(center: here, meters: 60, heading: 25)
        let b = SatelliteFraming(center: CLLocationCoordinate2D(latitude: 52.3710, longitude: 4.8961),
                                 meters: 25, heading: -70)
        for p in [CGPoint(x: 0.44, y: 0.52), CGPoint(x: 0.05, y: 0.95)] {
            let back = b.remap(a.remap(p, to: b), to: a)
            XCTAssertEqual(Double(back.x), Double(p.x), accuracy: 1e-6)
            XCTAssertEqual(Double(back.y), Double(p.y), accuracy: 1e-6)
        }
    }

    func testDistancesSurviveATurn() {
        // A turn must not stretch anything: two markers keep their separation.
        let a = SatelliteFraming(center: here, meters: 60, heading: 0)
        let b = SatelliteFraming(center: here, meters: 60, heading: 63)
        let p1 = CGPoint(x: 0.30, y: 0.40), p2 = CGPoint(x: 0.70, y: 0.75)
        let q1 = a.remap(p1, to: b), q2 = a.remap(p2, to: b)
        XCTAssertEqual(hypot(q2.x - q1.x, q2.y - q1.y),
                       hypot(p2.x - p1.x, p2.y - p1.y), accuracy: 1e-9)
    }

    func testAMarkersFacingIsOffsetByTheTurn() {
        let a = SatelliteFraming(center: here, meters: 60, heading: 0)
        let b = SatelliteFraming(center: here, meters: 60, heading: 90)
        // Turning the map 90° clockwise leaves a marker facing the same way in the
        // world only if its stored facing drops by 90.
        XCTAssertEqual(a.headingDelta(to: b), 90, accuracy: 1e-9)
        XCTAssertEqual(b.headingDelta(to: a), -90, accuracy: 1e-9)
    }
}

// MARK: - Committing a turned framing

extension SatelliteFramingTests {

    /// Where a marker appears once the canvas has also been turned: the reframe tool
    /// rotates the whole content about the canvas centre, outside the zoom and pan.
    private func screenPointTurned(_ n: CGPoint, zoom: CGFloat, pan: CGSize,
                                   turn: Double, canvas: CGSize) -> CGPoint {
        let side = min(canvas.width, canvas.height)
        let rect = CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2,
                          width: side, height: side)
        let lx = rect.minX + n.x * rect.width
        let ly = rect.minY + n.y * rect.height
        let px = canvas.width / 2 + (lx - canvas.width / 2) * zoom + pan.width
        let py = canvas.height / 2 + (ly - canvas.height / 2) * zoom + pan.height
        // …then rotated by -turn about the canvas centre.
        let r = -turn * .pi / 180
        let dx = px - canvas.width / 2, dy = py - canvas.height / 2
        return CGPoint(x: canvas.width / 2 + dx * cos(r) - dy * sin(r),
                       y: canvas.height / 2 + dx * sin(r) + dy * cos(r))
    }

    func testTurningWhileReframingLeavesMarkersWhereTheyLook() {
        let anchor = SatelliteFraming(center: amsterdam, meters: 60, heading: 12)
        let markers = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.18, y: 0.77), CGPoint(x: 0.92, y: 0.11)]
        let cases: [(CGFloat, CGSize, Double)] = [
            (1, .zero, 45),
            (1, CGSize(width: 90, height: -60), -30),
            (2, CGSize(width: -40, height: 25), 120),
            (0.5, CGSize(width: 150, height: 110), -170)
        ]
        for (zoom, pan, turn) in cases {
            guard let target = anchor.capture(contentWidth: contentWidth, canvas: canvas,
                                              zoom: zoom, pan: pan, turnedBy: turn) else {
                return XCTFail("No capture")
            }
            XCTAssertEqual(target.heading, (anchor.heading + turn).truncatingRemainder(dividingBy: 360),
                           accuracy: 1e-9)
            for marker in markers {
                let before = screenPointTurned(marker, zoom: zoom, pan: pan, turn: turn, canvas: canvas)
                // After committing: new capture at rest, no turn left over.
                let after = screenPointTurned(anchor.remap(marker, to: target),
                                              zoom: 1, pan: .zero, turn: 0, canvas: canvas)
                XCTAssertEqual(before.x, after.x, accuracy: 0.01,
                               "Marker \(marker) shifted at turn \(turn)")
                XCTAssertEqual(before.y, after.y, accuracy: 0.01,
                               "Marker \(marker) shifted at turn \(turn)")
            }
        }
    }

    func testAFacingSurvivesACommittedTurn() {
        // A marker facing 20° in an image whose up is 12° faces 32° in the world.
        // After turning the map to 57°, it must still face 32°.
        let anchor = SatelliteFraming(center: amsterdam, meters: 60, heading: 12)
        guard let target = anchor.capture(contentWidth: contentWidth, canvas: canvas,
                                          zoom: 1, pan: .zero, turnedBy: 45) else {
            return XCTFail("No capture")
        }
        let storedBefore = 20.0
        let worldFacing = storedBefore + anchor.heading
        let storedAfter = storedBefore - anchor.headingDelta(to: target)
        XCTAssertEqual(storedAfter + target.heading, worldFacing, accuracy: 1e-9)
    }
}

// MARK: - Reading a heading as a compass direction

final class CompassTests: XCTestCase {

    func testCompassPointsReadTheWayPeopleSayThem() {
        XCTAssertEqual(Compass.label(0), "N")
        XCTAssertEqual(Compass.label(45), "NE")
        XCTAssertEqual(Compass.label(90), "E")
        XCTAssertEqual(Compass.label(180), "S")
        XCTAssertEqual(Compass.label(270), "W")
        XCTAssertEqual(Compass.label(359), "N", "Just short of north is still north.")
        XCTAssertEqual(Compass.label(-90), "W", "A heading stored as negative still reads right.")
    }

    func testHeadingsFoldIntoOneTurn() {
        XCTAssertEqual(Compass.normalized(0), 0)
        XCTAssertEqual(Compass.normalized(360), 0, accuracy: 1e-9)
        XCTAssertEqual(Compass.normalized(-60), 300, accuracy: 1e-9)
        XCTAssertEqual(Compass.normalized(725), 5, accuracy: 1e-9)
    }

    func testTheSameDirectionWrittenTwoWaysIsNoTurnAtAll() {
        // The trap: a capture stored at -60 and a slider showing 300 are the same
        // map. Subtracting them raw gives 360, which would read as "turned".
        XCTAssertEqual(Compass.signedDelta(from: -60, to: 300), 0, accuracy: 1e-9)
        XCTAssertEqual(Compass.signedDelta(from: 300, to: -60), 0, accuracy: 1e-9)
    }

    func testATurnTakesTheShortWayRound() {
        XCTAssertEqual(Compass.signedDelta(from: 350, to: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Compass.signedDelta(from: 10, to: 350), -20, accuracy: 1e-9)
        XCTAssertEqual(Compass.signedDelta(from: 0, to: 180), 180, accuracy: 1e-9)
    }
}

// MARK: - A capture survives being stored on a scene

final class SatelliteCaptureStorageTests: XCTestCase {

    /// The bug this guards: a capture gained a heading, one write path recorded it
    /// and the other didn't, so the background turned while the controls still read
    /// the old direction. Reading a capture back has to give the same capture.
    func testEveryPartOfACaptureIsWrittenAndReadBack() {
        let scene = Scene(sceneNumber: 1)
        let capture = SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952),
            meters: 85, heading: 137)
        scene.recordSatelliteCapture(capture)

        guard let read = scene.satelliteCapture else { return XCTFail("nothing read back") }
        XCTAssertEqual(read.center.latitude, capture.center.latitude, accuracy: 1e-12)
        XCTAssertEqual(read.center.longitude, capture.center.longitude, accuracy: 1e-12)
        XCTAssertEqual(read.meters, capture.meters, accuracy: 1e-12)
        XCTAssertEqual(read.heading, capture.heading, accuracy: 1e-12)
        XCTAssertEqual(read, capture)
    }

    func testRecordingASecondCaptureReplacesTheFirstEntirely() {
        // Turning an already-turned map is where the missing write showed up.
        let scene = Scene(sceneNumber: 2)
        scene.recordSatelliteCapture(SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952),
            meters: 60, heading: 100))
        let turned = SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952),
            meters: 60, heading: 180)
        scene.recordSatelliteCapture(turned)
        XCTAssertEqual(scene.satelliteCapture, turned)
        XCTAssertEqual(scene.sceneMapSatelliteHeading, 180, accuracy: 1e-12)
    }

    func testTheBackgroundsMeasuredWidthFollowsTheCapture() {
        let scene = Scene(sceneNumber: 3)
        scene.recordSatelliteCapture(SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0), meters: 42))
        XCTAssertEqual(scene.sceneMapMetersWide, 42)
        XCTAssertTrue(scene.sceneMapSatelliteCalibrated)
        XCTAssertTrue(scene.sceneMapBackgroundIsSatellite)
    }

    func testANonSatelliteSceneHasNoCapture() {
        XCTAssertNil(Scene(sceneNumber: 4).satelliteCapture)
    }
}

// MARK: - When the map knows which way North is

extension SatelliteCaptureStorageTests {

    func testASatelliteMapAlwaysKnowsNorthFromItsCapture() {
        let scene = Scene(sceneNumber: 10)
        scene.recordSatelliteCapture(SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 52.3702, longitude: 4.8952),
            meters: 60, heading: 137))
        // The image is turned so 137° points up, so North sits 137° the other way.
        XCTAssertEqual(scene.mapNorthOffset ?? 0, -137, accuracy: 1e-12)
    }

    func testANorthUpCaptureReadsAsNorthUp() {
        let scene = Scene(sceneNumber: 11)
        scene.recordSatelliteCapture(SatelliteFraming(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0), meters: 60))
        XCTAssertEqual(scene.mapNorthOffset ?? .nan, 0, accuracy: 1e-12)
    }

    func testAnUnorientedMapClaimsNothing() {
        // A photo or drawn plan nobody has oriented: showing a compass pointing up
        // would be asserting north is up because no one said otherwise.
        XCTAssertNil(Scene(sceneNumber: 12).mapNorthOffset)
    }

    func testAPlanTheUserHasOrientedDoesKnow() {
        let scene = Scene(sceneNumber: 13)
        var sun = SunSettings()
        sun.latitude = 52.3702
        sun.longitude = 4.8952
        sun.northOffsetDeg = -40
        scene.sunSettings = sun
        XCTAssertEqual(scene.mapNorthOffset ?? .nan, -40, accuracy: 1e-12)
    }
}

// MARK: - The compass dial's layout

final class MapCompassLayoutTests: XCTestCase {

    /// The letter rides the needle's head, so the two are only ever a few percent of
    /// the dial apart. These pin that gap: nudge one band and the numbers, not a
    /// screenshot months later, say the letter has started clipping the needle.
    func testTheLetterClearsTheNeedle() {
        let needleTip = MapCompass.needleLength
        let letterBottom = MapCompass.letterCentre - MapCompass.letterSize / 2
        XCTAssertGreaterThan(letterBottom, needleTip,
                             "The N would sit on the needle's point.")
        XCTAssertGreaterThanOrEqual(letterBottom - needleTip, 0.03,
                                    "Clearance too tight to read as a gap.")
    }

    func testTheLetterStaysInsideTheDial() {
        let letterTop = MapCompass.letterCentre + MapCompass.letterSize / 2
        XCTAssertLessThan(letterTop, 0.5, "The N would run over the rim.")
        XCTAssertGreaterThanOrEqual(0.5 - letterTop, 0.03)
    }
}
