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
    /// A square satellite image centred on `coordinate`, `meters` across, at
    /// `pixels`×`pixels`. North is up. Needs network access (tiles download).
    ///
    /// MapKit clamps very small satellite areas to its max zoom, so a direct tiny
    /// mapRect is ignored. A reference area MapKit will honour is rendered, then its
    /// centre is cropped to the exact requested size — always to scale, just softer
    /// below the imagery's native resolution.
    @MainActor
    static func satelliteImage(coordinate: CLLocationCoordinate2D,
                               meters: Double,
                               pixels: CGFloat = 1200) async throws -> PlatformImage {
        let refMeters = max(meters, 250.0)
        let options = MKMapSnapshotter.Options()
        let side = refMeters * MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        let center = MKMapPoint(coordinate)
        options.mapRect = MKMapRect(x: center.x - side / 2, y: center.y - side / 2,
                                    width: side, height: side)
        options.mapType = .satellite
        let refPixels: CGFloat = 2048
        options.size = CGSize(width: refPixels, height: refPixels)
        options.showsBuildings = true

        let snapshot = try await MKMapSnapshotter(options: options).start()

        let fraction = CGFloat(meters / refMeters)     // ≤ 1
        let cropPixels = refPixels * fraction
        let crop = CGRect(x: (refPixels - cropPixels) / 2, y: (refPixels - cropPixels) / 2,
                          width: cropPixels, height: cropPixels)
        return cropAndScale(snapshot.image, crop: crop, to: CGSize(width: pixels, height: pixels))
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
