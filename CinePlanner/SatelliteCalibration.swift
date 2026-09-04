//
//  SatelliteCalibration.swift
//  CinePlanner
//
//  Repairs satellite scene-map backgrounds captured before `MapSnapshot` measured
//  the snapshotter's scale instead of assuming it.
//
//  The old renderer asked MapKit for a 250 m reference area at 2048 points and
//  cropped the centre as though it had got one. MapKit does not refuse a request
//  finer than two map points per rendered point — it silently renders a *wider*
//  area — so those crops cover more ground than was recorded. The image is fine;
//  only the metres attached to it are wrong, which draws every marker too large and
//  makes a reframe drift, because a remap's translation term is in absolute metres.
//
//  The clamp is exactly 2 map points per rendered point, measured and identical at
//  every latitude, location and output size, so the error is computable rather than
//  guessable: the correction depends only on the stored size and latitude.
//

import Foundation
import MapKit
import CoreLocation
import os

enum SatelliteCalibration {
    /// Reference render size the old pipeline always used.
    private static let legacyReferencePoints = 2048.0
    /// Reference area it always asked for, in metres, for captures under that size.
    private static let legacyReferenceMeters = 250.0

    /// The ground a legacy capture recorded as `meters` at `latitude` actually
    /// covers. Returns `meters` unchanged when the old request was inside MapKit's
    /// limit and so was honoured.
    static func trueMeters(recorded meters: Double, latitude: Double) -> Double {
        guard meters > 0 else { return meters }
        let reference = max(meters, legacyReferenceMeters)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(latitude)
        guard pointsPerMeter > 0 else { return meters }
        // What the old code asked for, in map points per rendered point…
        let requested = reference * pointsPerMeter / legacyReferencePoints
        // …versus the finest MapKit will actually render.
        let delivered = max(MapSnapshot.minMapPointsPerRenderedPoint, requested)
        return meters * delivered / requested
    }

    /// Corrects one scene's recorded capture size, if it needs it. Returns the new
    /// size when something changed, so the caller can log or refresh.
    @discardableResult
    static func calibrate(_ scene: Scene) -> Double? {
        guard !scene.sceneMapSatelliteCalibrated else { return nil }
        guard scene.sceneMapBackgroundIsSatellite,
              let latitude = scene.sceneMapSatelliteLat,
              let recorded = scene.sceneMapSatelliteMeters, recorded > 0 else {
            // Nothing to correct — mark it so this isn't reconsidered every open.
            scene.sceneMapSatelliteCalibrated = true
            return nil
        }
        let corrected = trueMeters(recorded: recorded, latitude: latitude)
        scene.sceneMapSatelliteCalibrated = true
        guard abs(corrected - recorded) > 0.01 else { return nil }
        scene.sceneMapSatelliteMeters = corrected
        // The background's real-world width follows the capture, unless something
        // else (a CineStager location width) set it to a different measurement.
        if let wide = scene.sceneMapMetersWide, abs(wide - recorded) < 0.01 {
            scene.sceneMapMetersWide = corrected
        }
        Log.sceneMap.notice("Calibrated satellite capture: \(recorded, format: .fixed(precision: 1)) m → \(corrected, format: .fixed(precision: 1)) m")
        return corrected
    }
}
