//
//  SatelliteFraming.swift
//  CinePlanner
//
//  The geometry behind a satellite scene-map background: what patch of the world
//  the canvas is showing at a given zoom/pan, what capture that framing would
//  produce, and how to carry a marker from one capture to another so it keeps its
//  real-world spot.
//
//  It is pure geometry, deliberately kept out of the editor view, because getting
//  it wrong is invisible until markers silently drift off the ground they were
//  placed on. Everything works in MapKit's projected `MKMapPoint` space — the exact
//  space `MapSnapshot` builds its images in — so there is no projection drift.
//

import Foundation
import CoreGraphics
import MapKit
import CoreLocation

/// A satellite capture: a square of world `meters` across, centred on `center`,
/// rendered north-up. Marker positions are stored normalized (0…1) within it.
struct SatelliteFraming: Equatable {
    let center: CLLocationCoordinate2D
    let meters: Double

    init(center: CLLocationCoordinate2D, meters: Double) {
        self.center = center
        self.meters = meters
    }

    static func == (lhs: SatelliteFraming, rhs: SatelliteFraming) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.meters == rhs.meters
    }

    /// The capture square in projected map points.
    var mapRect: MKMapRect {
        let side = meters * MKMapPointsPerMeterAtLatitude(center.latitude)
        let point = MKMapPoint(center)
        return MKMapRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    }

    /// Whether two captures cover any of the same ground. The test for whether
    /// markers should be carried across to a new capture (same place, they belong to
    /// the ground) or left where they sit (a different place, where remapping would
    /// fling every one of them out of frame).
    func overlaps(_ other: SatelliteFraming) -> Bool { mapRect.intersects(other.mapRect) }

    // MARK: - What the canvas is framing

    /// The world rect the whole canvas shows, given that this capture is drawn into
    /// a `contentWidth`-wide square centred in `canvas`, then scaled by `zoom` about
    /// that centre and shifted by `pan`.
    ///
    /// Returns nil for a degenerate canvas.
    func canvasRect(contentWidth: CGFloat, canvas: CGSize, zoom: CGFloat, pan: CGSize) -> MKMapRect? {
        guard contentWidth > 0, zoom > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        let side = meters * MKMapPointsPerMeterAtLatitude(center.latitude)
        // Map points covered by one screen point at this zoom.
        let perPoint = side / (Double(contentWidth) * Double(zoom))
        let point = MKMapPoint(center)
        // Panning the content right moves the ground under the canvas centre left.
        let cx = point.x - Double(pan.width) * perPoint
        let cy = point.y - Double(pan.height) * perPoint
        let width = Double(canvas.width) * perPoint
        let height = Double(canvas.height) * perPoint
        return MKMapRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }

    /// The capture the current framing would produce: the largest square centred in
    /// the canvas. At rest (zoom 1, no pan) this is exactly `self`, so committing
    /// without having moved changes nothing.
    func capture(contentWidth: CGFloat, canvas: CGSize, zoom: CGFloat, pan: CGSize) -> SatelliteFraming? {
        guard let live = canvasRect(contentWidth: contentWidth, canvas: canvas, zoom: zoom, pan: pan) else { return nil }
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
        guard pointsPerMeter > 0 else { return nil }
        return SatelliteFraming(center: MKMapPoint(x: live.midX, y: live.midY).coordinate,
                                meters: min(live.width, live.height) / pointsPerMeter)
    }

    // MARK: - Carrying markers between captures

    /// Re-maps a normalized (0…1) point from this capture to `other`, so it keeps
    /// the same real-world spot. Points outside `other` come back outside 0…1 — the
    /// honest answer for ground the new capture doesn't cover.
    func remap(_ p: CGPoint, to other: SatelliteFraming) -> CGPoint {
        let oldSide = meters * MKMapPointsPerMeterAtLatitude(center.latitude)
        let newSide = other.meters * MKMapPointsPerMeterAtLatitude(other.center.latitude)
        guard newSide > 0 else { return p }
        let oldC = MKMapPoint(center)
        let newC = MKMapPoint(other.center)
        // The marker's absolute world point, from where it sat in this capture…
        let worldX = oldC.x + (Double(p.x) - 0.5) * oldSide
        let worldY = oldC.y + (Double(p.y) - 0.5) * oldSide
        // …projected into the new capture's square.
        return CGPoint(x: 0.5 + (worldX - newC.x) / newSide,
                       y: 0.5 + (worldY - newC.y) / newSide)
    }

    /// How much sizes stored relative to the capture (furniture, say) must scale to
    /// keep their real-world dimensions in `other`.
    func sizeRatio(to other: SatelliteFraming) -> Double {
        other.meters > 0 ? meters / other.meters : 1
    }
}
