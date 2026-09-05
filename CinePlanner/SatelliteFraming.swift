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
    /// Compass direction that points up in the capture, in degrees clockwise from
    /// north. 0 is north-up, which is how every capture was made before the map
    /// could be turned.
    let heading: Double

    init(center: CLLocationCoordinate2D, meters: Double, heading: Double = 0) {
        self.center = center
        self.meters = meters
        self.heading = heading
    }

    static func == (lhs: SatelliteFraming, rhs: SatelliteFraming) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.meters == rhs.meters
            && lhs.heading == rhs.heading
    }

    /// How far the map has turned between two captures, in degrees. A marker's
    /// stored facing is relative to the image, so it has to be offset by this to
    /// keep pointing the same way in the real world.
    func headingDelta(to other: SatelliteFraming) -> Double { other.heading - heading }

    /// The capture square in projected map points, ignoring any turn — so for a
    /// turned capture this is the north-up square of the same size, which is what
    /// `overlaps` wants: a slightly generous test of "same patch of ground".
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

    /// Map points covered by one screen point, when this capture is drawn into a
    /// `contentWidth`-wide square and scaled by `zoom`.
    func mapPointsPerScreenPoint(contentWidth: CGFloat, zoom: CGFloat) -> Double? {
        guard contentWidth > 0, zoom > 0 else { return nil }
        return meters * MKMapPointsPerMeterAtLatitude(center.latitude)
            / (Double(contentWidth) * Double(zoom))
    }

    /// The world point under the middle of the canvas.
    ///
    /// `pan` is a screen displacement, so it is a displacement in *this capture's*
    /// frame — which is turned by `heading` relative to the world. Treating it as a
    /// world displacement would put the new capture's centre off by that turn, and
    /// every marker with it.
    func canvasCenter(contentWidth: CGFloat, zoom: CGFloat, pan: CGSize) -> MKMapPoint? {
        guard let perPoint = mapPointsPerScreenPoint(contentWidth: contentWidth, zoom: zoom) else { return nil }
        let point = MKMapPoint(center)
        // Panning the content right moves the ground under the canvas centre left.
        let local = Self.rotate(x: -Double(pan.width) * perPoint,
                                y: -Double(pan.height) * perPoint, byDegrees: heading)
        return MKMapPoint(x: point.x + local.x, y: point.y + local.y)
    }

    /// A square of ground, in this capture's frame, covering the canvas at the given
    /// zoom and pan — widened by `margin`. Used to fetch a sharp render while
    /// reframing, so it comes back turned the same way the canvas is drawn.
    func canvasCover(contentWidth: CGFloat, canvas: CGSize, zoom: CGFloat, pan: CGSize,
                     margin: Double = 1) -> SatelliteFraming? {
        guard canvas.width > 0, canvas.height > 0,
              let perPoint = mapPointsPerScreenPoint(contentWidth: contentWidth, zoom: zoom),
              let centre = canvasCenter(contentWidth: contentWidth, zoom: zoom, pan: pan) else { return nil }
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
        guard pointsPerMeter > 0 else { return nil }
        let side = Double(max(canvas.width, canvas.height)) * perPoint * margin
        return SatelliteFraming(center: centre.coordinate, meters: side / pointsPerMeter,
                                heading: heading)
    }

    /// The capture the current framing would produce: the largest square centred in
    /// the canvas. At rest (zoom 1, no pan, no turn) this is exactly `self`, so
    /// committing without having moved changes nothing.
    ///
    /// `turnedBy` is how far the user has rotated the canvas on top of this capture's
    /// own heading. Rotation is about the canvas centre, so neither the centre nor the
    /// size depends on it — only the heading the new capture is rendered at.
    func capture(contentWidth: CGFloat, canvas: CGSize, zoom: CGFloat, pan: CGSize,
                 turnedBy degrees: Double = 0) -> SatelliteFraming? {
        guard canvas.width > 0, canvas.height > 0,
              let perPoint = mapPointsPerScreenPoint(contentWidth: contentWidth, zoom: zoom),
              let centre = canvasCenter(contentWidth: contentWidth, zoom: zoom, pan: pan) else { return nil }
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
        guard pointsPerMeter > 0 else { return nil }
        let side = Double(min(canvas.width, canvas.height)) * perPoint
        return SatelliteFraming(center: centre.coordinate, meters: side / pointsPerMeter,
                                heading: (heading + degrees).truncatingRemainder(dividingBy: 360))
    }

    /// Where `other`'s centre sits on the canvas, in screen points from the middle,
    /// measured in this capture's frame — how a fetched render is placed under the
    /// markers while the canvas is panned.
    func screenOffset(of other: SatelliteFraming, contentWidth: CGFloat,
                      zoom: CGFloat, pan: CGSize) -> CGSize? {
        guard let perPoint = mapPointsPerScreenPoint(contentWidth: contentWidth, zoom: zoom),
              perPoint > 0,
              let centre = canvasCenter(contentWidth: contentWidth, zoom: zoom, pan: pan) else { return nil }
        let target = MKMapPoint(other.center)
        let local = Self.rotate(x: target.x - centre.x, y: target.y - centre.y, byDegrees: -heading)
        return CGSize(width: local.x / perPoint, height: local.y / perPoint)
    }

    // MARK: - Carrying markers between captures

    /// Re-maps a normalized (0…1) point from this capture to `other`, so it keeps
    /// the same real-world spot. Points outside `other` come back outside 0…1 — the
    /// honest answer for ground the new capture doesn't cover.
    ///
    /// Both captures may be turned, so the point goes out of this image's frame into
    /// the world and back into the other's. With both headings at 0 the rotations
    /// vanish and this is a plain scale-and-shift.
    func remap(_ p: CGPoint, to other: SatelliteFraming) -> CGPoint {
        let oldSide = meters * MKMapPointsPerMeterAtLatitude(center.latitude)
        let newSide = other.meters * MKMapPointsPerMeterAtLatitude(other.center.latitude)
        guard newSide > 0 else { return p }
        let oldC = MKMapPoint(center)
        let newC = MKMapPoint(other.center)
        // Where it sits in this image, in map points, before the image is turned…
        let localX = (Double(p.x) - 0.5) * oldSide
        let localY = (Double(p.y) - 0.5) * oldSide
        // …turned into world axes, giving its absolute world point…
        let world = Self.rotate(x: localX, y: localY, byDegrees: heading)
        let worldX = oldC.x + world.x
        let worldY = oldC.y + world.y
        // …then into the other image's frame, undoing that image's turn.
        let into = Self.rotate(x: worldX - newC.x, y: worldY - newC.y,
                               byDegrees: -other.heading)
        return CGPoint(x: 0.5 + into.x / newSide, y: 0.5 + into.y / newSide)
    }

    /// Rotates a vector in map-point space (x east, y south), clockwise on screen.
    private static func rotate(x: Double, y: Double, byDegrees degrees: Double) -> (x: Double, y: Double) {
        guard degrees != 0 else { return (x, y) }
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return (x * c - y * s, x * s + y * c)
    }

    /// How much sizes stored relative to the capture (furniture, say) must scale to
    /// keep their real-world dimensions in `other`.
    func sizeRatio(to other: SatelliteFraming) -> Double {
        other.meters > 0 ? meters / other.meters : 1
    }
}

// MARK: - Storing a capture on a scene

extension Scene {
    /// The satellite capture this scene's background was made from, if it has one.
    var satelliteCapture: SatelliteFraming? {
        guard sceneMapBackgroundIsSatellite,
              let lat = sceneMapSatelliteLat, let lon = sceneMapSatelliteLon,
              let meters = sceneMapSatelliteMeters, meters > 0 else { return nil }
        return SatelliteFraming(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                meters: meters, heading: sceneMapSatelliteHeading)
    }

    /// Screen angle (from up, clockwise) that points North on this scene's map, when
    /// its orientation is actually known.
    ///
    /// A satellite capture always knows: it was rendered at a heading. Any other
    /// background only knows once someone has told the sun overlay where the scene
    /// is — before that, showing a compass would be asserting north is up because
    /// nobody has said otherwise, which is a guess dressed as a fact.
    var mapNorthOffset: Double? {
        if let capture = satelliteCapture { return -capture.heading }
        let sun = sunSettings
        return sun.hasLocation ? sun.northOffsetDeg : nil
    }

    /// Drops the capture along with the flag.
    ///
    /// Five places replace a scene's background one way or another — a photo, an
    /// import, a drawn plan, clearing the map, clearing everything — and each used
    /// to lower the satellite flag on its own. Left behind, the anchor from a map
    /// that no longer exists would quietly turn the next one and reopen the picker
    /// pointing the wrong way.
    func clearSatelliteCapture() {
        sceneMapBackgroundIsSatellite = false
        sceneMapSatelliteLat = nil
        sceneMapSatelliteLon = nil
        sceneMapSatelliteMeters = nil
        sceneMapSatelliteHeading = 0
        sceneMapSatelliteCalibrated = false
    }

    /// Records a capture against the scene.
    ///
    /// Both ways of setting a satellite background go through here, because they
    /// used not to: when the capture gained a heading, one path wrote it and the
    /// other quietly didn't, so the map turned while the controls still read the old
    /// direction. A capture is one thing; it gets written in one place.
    func recordSatelliteCapture(_ framing: SatelliteFraming) {
        sceneMapBackgroundIsSatellite = true
        sceneMapSatelliteLat = framing.center.latitude
        sceneMapSatelliteLon = framing.center.longitude
        sceneMapSatelliteMeters = framing.meters
        sceneMapSatelliteHeading = framing.heading
        sceneMapSatelliteCalibrated = true      // rendered by the measuring pipeline
        sceneMapMetersWide = framing.meters     // the square is `meters` across
    }
}
