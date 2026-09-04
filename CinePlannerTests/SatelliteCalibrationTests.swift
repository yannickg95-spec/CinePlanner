//
//  SatelliteCalibrationTests.swift
//  CinePlannerTests
//
//  Pins the repair for satellite captures made before the snapshot scale was
//  measured. MapKit renders no finer than two map points per rendered point and
//  silently widens anything tighter, so those captures cover more ground than they
//  recorded — which drew markers too large and made a reframe drift by exactly the
//  size of the error.
//

import XCTest
import MapKit
@testable import CinePlanner

final class SatelliteCalibrationTests: XCTestCase {

    private let amsterdam = 52.3702
    private let quito = -0.1807
    private let reykjavik = 64.1466

    /// The reference area the old renderer asked for, in map points per rendered
    /// point — the quantity MapKit actually clamps.
    private func requestedDetail(recorded: Double, latitude: Double) -> Double {
        max(recorded, 250) * MKMapPointsPerMeterAtLatitude(latitude) / 2048
    }

    func testACaptureWideEnoughToBeHonouredIsLeftAlone() {
        // 800 m in Amsterdam asks for ~4.3 map points per point — well inside the limit.
        XCTAssertGreaterThan(requestedDetail(recorded: 800, latitude: amsterdam),
                             MapSnapshot.minMapPointsPerRenderedPoint)
        XCTAssertEqual(SatelliteCalibration.trueMeters(recorded: 800, latitude: amsterdam),
                       800, accuracy: 0.0001)
    }

    func testATightCaptureIsWidenedByExactlyWhatMapKitWithheld() {
        let recorded = 60.0
        let asked = requestedDetail(recorded: recorded, latitude: amsterdam)
        XCTAssertLessThan(asked, MapSnapshot.minMapPointsPerRenderedPoint, "This request is clamped.")
        let expected = recorded * MapSnapshot.minMapPointsPerRenderedPoint / asked
        XCTAssertEqual(SatelliteCalibration.trueMeters(recorded: recorded, latitude: amsterdam),
                       expected, accuracy: 0.0001)
        // Concretely: a "60 m" Amsterdam capture really covers about 90 m.
        XCTAssertEqual(SatelliteCalibration.trueMeters(recorded: 60, latitude: amsterdam),
                       89.6, accuracy: 0.5)
    }

    func testTheCorrectionNeverShrinksACapture() {
        for meters in stride(from: 10.0, through: 400.0, by: 10.0) {
            for latitude in [quito, amsterdam, reykjavik, -33.9] {
                let corrected = SatelliteCalibration.trueMeters(recorded: meters, latitude: latitude)
                XCTAssertGreaterThanOrEqual(corrected, meters - 0.0001,
                                            "\(meters) m at \(latitude)° shrank")
            }
        }
    }

    func testTheErrorIsLargestNearTheEquator() {
        // The clamp is fixed in map points, and a map point is fewer metres the
        // further from the equator — so the same request is withheld hardest at
        // the equator and least near the poles.
        let atEquator = SatelliteCalibration.trueMeters(recorded: 60, latitude: quito)
        let midLatitude = SatelliteCalibration.trueMeters(recorded: 60, latitude: amsterdam)
        let far = SatelliteCalibration.trueMeters(recorded: 60, latitude: reykjavik)
        XCTAssertGreaterThan(atEquator, midLatitude)
        XCTAssertGreaterThan(midLatitude, far)
        XCTAssertGreaterThan(far, 60)
    }

    /// `trueMeters` answers "what did the old renderer actually produce for this
    /// recorded size" — a question that only makes sense once. Feeding it its own
    /// output inflates a capture a second time, so the flag, not the arithmetic, is
    /// what has to stop a repeat. These two tests pin both halves of that.
    func testApplyingTheCorrectionTwiceWouldInflateACapture() {
        let once = SatelliteCalibration.trueMeters(recorded: 60, latitude: amsterdam)
        let twice = SatelliteCalibration.trueMeters(recorded: once, latitude: amsterdam)
        XCTAssertGreaterThan(twice, once + 1,
                             "Documenting the hazard the calibrated flag exists to prevent.")
    }

    func testAnAlreadyCalibratedSceneIsNeverTouched() {
        let scene = Scene(sceneNumber: 1)
        scene.sceneMapBackgroundIsSatellite = true
        scene.sceneMapSatelliteLat = amsterdam
        scene.sceneMapSatelliteLon = 4.8952
        scene.sceneMapSatelliteMeters = 60
        scene.sceneMapMetersWide = 60

        SatelliteCalibration.calibrate(scene)
        let corrected = scene.sceneMapSatelliteMeters
        XCTAssertNotNil(corrected)
        XCTAssertGreaterThan(corrected ?? 0, 60)
        XCTAssertTrue(scene.sceneMapSatelliteCalibrated)
        XCTAssertEqual(scene.sceneMapMetersWide ?? 0, corrected ?? 0, accuracy: 0.0001,
                       "The background's measured width follows the capture it came from.")

        // Second pass: the flag stops it.
        SatelliteCalibration.calibrate(scene)
        XCTAssertEqual(scene.sceneMapSatelliteMeters ?? 0, corrected ?? 0, accuracy: 0.0001)
    }

    func testANonSatelliteSceneIsMarkedWithoutBeingChanged() {
        let scene = Scene(sceneNumber: 2)
        scene.sceneMapMetersWide = 12          // e.g. a measured CineStager location
        SatelliteCalibration.calibrate(scene)
        XCTAssertTrue(scene.sceneMapSatelliteCalibrated, "So it isn't reconsidered on every open.")
        XCTAssertEqual(scene.sceneMapMetersWide, 12)
    }

    func testAMeasuredWidthFromElsewhereIsLeftAlone() {
        // A satellite capture whose metresWide came from something other than the
        // capture size must not be dragged along by the correction.
        let scene = Scene(sceneNumber: 3)
        scene.sceneMapBackgroundIsSatellite = true
        scene.sceneMapSatelliteLat = amsterdam
        scene.sceneMapSatelliteLon = 4.8952
        scene.sceneMapSatelliteMeters = 60
        scene.sceneMapMetersWide = 35
        SatelliteCalibration.calibrate(scene)
        XCTAssertEqual(scene.sceneMapMetersWide, 35)
    }

    func testNonsenseSizesArePassedThrough() {
        XCTAssertEqual(SatelliteCalibration.trueMeters(recorded: 0, latitude: amsterdam), 0)
        XCTAssertEqual(SatelliteCalibration.trueMeters(recorded: -5, latitude: amsterdam), -5)
    }
}
