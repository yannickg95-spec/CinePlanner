//
//  MapSnapshot.swift
//  CinePlanner
//
//  Renders a north-up satellite still of a location via MapKit's offscreen
//  snapshotter, for use as a scene-map background. Given a coordinate and a size
//  in metres, it produces a square, to-scale image.
//

import Foundation
import MapKit
import SwiftUI

enum MapSnapshot {
    /// The finest detail MapKit's snapshotter will render: two map points per
    /// rendered point. Measured, and identical at every latitude, location and
    /// output size — which is why it is expressed in map points rather than metres
    /// (373 m across 2048 points in Amsterdam is 607 m in Quito and 267 m in
    /// Reykjavík; all of them are 2 map points per point).
    ///
    /// Ask for more detail than this and MapKit does not fail — it quietly renders a
    /// *wider* area than requested. A tight capture therefore has to be rendered
    /// coarse and cropped back down, and the crop must be measured from what came
    /// back rather than from what was asked for.
    static let minMapPointsPerRenderedPoint = 2.0
    /// Upper bound on the reference render's long edge. The clamp usually sets the
    /// size instead; this only caps a very wide capture.
    private static let referenceLongEdge: CGFloat = 2048

    /// A square satellite image centred on `coordinate`, `meters` across, at
    /// `pixels`×`pixels`. North is up. Needs network access (tiles download).
    @MainActor
    static func satelliteImage(coordinate: CLLocationCoordinate2D,
                               meters: Double,
                               pixels: CGFloat = 1200) async throws -> PlatformImage {
        let side = meters * MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        let center = MKMapPoint(coordinate)
        let rect = MKMapRect(x: center.x - side / 2, y: center.y - side / 2,
                             width: side, height: side)
        return try await satelliteImage(mapRect: rect,
                                        pixelSize: CGSize(width: pixels, height: pixels))
    }

    /// A north-up satellite image of exactly `mapRect`, rendered at `pixelSize`.
    ///
    /// `mapRect` and `pixelSize` are expected to share an aspect ratio; the image is
    /// always to scale. Areas below MapKit's max zoom are rendered wide and cropped
    /// to the exact requested rect — just softer than the imagery's native
    /// resolution, never a different area.
    @MainActor
    static func satelliteImage(mapRect: MKMapRect, pixelSize: CGSize) async throws -> PlatformImage {
        let aspect = pixelSize.width / max(pixelSize.height, 1)
        // Past the clamp a bigger reference buys nothing: the usable crop always
        // comes back at `mapRect.width / minMapPointsPerRenderedPoint` points however
        // large the render was. So cap the reference there — a tight capture used to
        // render 2048x2048 and throw away 99% of it, which is slow enough that a
        // preview visibly lags the framing it belongs to.
        let clampedLongEdge = CGFloat(max(mapRect.width, mapRect.height) / minMapPointsPerRenderedPoint)
        let longEdge = max(min(referenceLongEdge, clampedLongEdge.rounded()), 64)
        let refSize = aspect >= 1
            ? CGSize(width: longEdge, height: (longEdge / aspect).rounded())
            : CGSize(width: (longEdge * aspect).rounded(), height: longEdge)
        // Widen the requested rect rather than asking for detail MapKit won't render.
        let widen = max(1, minMapPointsPerRenderedPoint * Double(refSize.width) / max(mapRect.width, 1))
        let refRect = MKMapRect(x: mapRect.midX - mapRect.width * widen / 2,
                                y: mapRect.midY - mapRect.height * widen / 2,
                                width: mapRect.width * widen,
                                height: mapRect.height * widen)

        let options = MKMapSnapshotter.Options()
        options.mapRect = refRect
        options.mapType = .satellite
        options.size = refSize
        options.showsBuildings = true
        let snapshot = try await MKMapSnapshotter(options: options).start()

        // Crop the centre back out — measuring the returned image's true scale
        // instead of assuming the request was honoured. `widen` is only a bid for
        // detail; if MapKit rendered wider anyway, cropping to the requested size
        // would silently store more ground than the caller believes it has, and
        // every marker placed on it would sit at the wrong scale.
        let scale = mapPointsPerImagePoint(in: snapshot, around: refRect)
            ?? (refRect.width / Double(refSize.width))
        let cropSize = CGSize(width: min(CGFloat(mapRect.width / scale), refSize.width),
                              height: min(CGFloat(mapRect.height / scale), refSize.height))
        let crop = CGRect(x: (refSize.width - cropSize.width) / 2,
                          y: (refSize.height - cropSize.height) / 2,
                          width: cropSize.width, height: cropSize.height)
        return cropAndScale(snapshot.image, crop: crop, to: pixelSize)
    }

    /// How many map points one point of the rendered image covers, read back from
    /// the snapshot itself: `point(for:)` reports where a coordinate actually landed.
    /// Returns nil when the probe is unusable (a rect straddling the antimeridian,
    /// say), leaving the caller to fall back on the requested scale.
    @MainActor
    private static func mapPointsPerImagePoint(in snapshot: MKMapSnapshotter.Snapshot,
                                               around rect: MKMapRect) -> Double? {
        let span = rect.width / 4
        let west = MKMapPoint(x: rect.midX - span / 2, y: rect.midY).coordinate
        let east = MKMapPoint(x: rect.midX + span / 2, y: rect.midY).coordinate
        let dx = Double(snapshot.point(for: east).x - snapshot.point(for: west).x)
        guard dx > 0.5 else { return nil }
        return span / dx
    }

    /// Crops `crop` (in the source's points) and scales it to `size`.
    @MainActor
    private static func cropAndScale(_ image: PlatformImage, crop: CGRect, to size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // Scale the whole image so the crop region fills the destination.
            let sx = size.width / crop.width, sy = size.height / crop.height
            image.draw(in: CGRect(x: -crop.origin.x * sx, y: -crop.origin.y * sy,
                                  width: image.size.width * sx, height: image.size.height * sy))
        }
        #else
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: .zero, size: size), from: crop, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
        #endif
    }

    /// Approximate width, in metres, of a map rect at its centre latitude.
    static func metersWide(_ rect: MKMapRect) -> Double {
        let centerLat = MKMapPoint(x: rect.midX, y: rect.midY).coordinate.latitude
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(centerLat)
        return pointsPerMeter > 0 ? rect.width / pointsPerMeter : 0
    }
}
