//
//  MapSnapshot.swift
//  CinePlanner
//
//  Renders a north-up satellite still of a real-world location via MapKit's
//  offscreen snapshotter, for use as a scene-map background. Given a coordinate
//  and a size in metres, it produces a square, to-scale image.
//

import Foundation
import MapKit
import AppKit

enum MapSnapshot {
    /// A square satellite image centred on `coordinate`, `meters` across, at
    /// `pixels`×`pixels`. North is up. Needs network access (tiles download).
    static func satelliteImage(coordinate: CLLocationCoordinate2D,
                               meters: Double,
                               pixels: CGFloat = 1200) async throws -> NSImage {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate,
                                            latitudinalMeters: meters,
                                            longitudinalMeters: meters)
        options.mapType = .satellite
        options.size = CGSize(width: pixels, height: pixels)
        options.showsBuildings = true
        let snapshot = try await MKMapSnapshotter(options: options).start()
        return snapshot.image
    }
}
