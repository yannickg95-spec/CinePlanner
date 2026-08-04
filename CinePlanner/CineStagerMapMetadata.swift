//
//  CineStagerMapMetadata.swift
//  CinePlanner
//
//  Reads the marker coordinates CineStager embeds in a top-down map image's
//  EXIF UserComment. The comment is a " | "-separated list of "Key:Value"
//  parts; the ones we care about are the normalized (0…1, origin top-left)
//  map positions:
//
//    CameraMap2D:u,v
//    MannequinsMap2D:u,v;u,v;…
//    ActorsMap2D:u,v;…
//
//  These normalized coordinates map directly onto the clean (marker-free) map
//  image, which shares the same orthographic framing.
//

import Foundation
import ImageIO

enum CineStagerMapMetadata {
    /// A normalized marker position (0…1 from the top-left of the map image),
    /// with an optional facing (degrees, 0 = up, clockwise positive).
    struct Marker: Equatable {
        var u: Double
        var v: Double
        var rotationDeg: Double?
        /// World position in metres (X, Z) when CineStager embedded it — used to
        /// measure the camera↔subject distance for a shot-size estimate.
        var worldX: Double?
        var worldZ: Double?
    }

    struct Markers: Equatable {
        var camera: Marker?
        var mannequins: [Marker] = []
        var actors: [Marker] = []

        var isEmpty: Bool { camera == nil && mannequins.isEmpty && actors.isEmpty }
    }

    /// Parses marker positions from a top-down map image's EXIF UserComment.
    static func markers(from imageData: Data) -> Markers? {
        guard let comment = userComment(from: imageData) else { return nil }
        let parts = comment.components(separatedBy: " | ")
        var fields: [String: String] = [:]
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = String(part[..<colon])
            let value = String(part[part.index(after: colon)...])
            fields[key] = value
        }

        var markers = Markers()
        if let camera = fields["CameraMap2D"], var point = parsePoints(camera).first {
            point.rotationDeg = fields["CameraMapRot"].flatMap { Double($0) }
            if let world = parseWorld(fields["CameraWorldXZ"]).first {
                point.worldX = world.0; point.worldZ = world.1
            }
            markers.camera = point
        }
        if let manns = fields["MannequinsMap2D"] {
            markers.mannequins = applyWorld(applyRotations(parsePoints(manns), fields["MannequinsMapRot"]),
                                            fields["MannequinsWorldXZ"])
        }
        if let actors = fields["ActorsMap2D"] {
            markers.actors = applyRotations(parsePoints(actors), fields["ActorsMapRot"])
        }
        return markers.isEmpty ? nil : markers
    }

    /// "u,v;u,v" → [Marker]. Skips malformed entries.
    private static func parsePoints(_ raw: String) -> [Marker] {
        raw.components(separatedBy: ";").compactMap { pair in
            let xy = pair.components(separatedBy: ",")
            guard xy.count == 2, let u = Double(xy[0]), let v = Double(xy[1]) else { return nil }
            return Marker(u: u, v: v, rotationDeg: nil)
        }
    }

    /// "x,z;x,z" → [(x, z)]. Skips malformed entries.
    private static func parseWorld(_ raw: String?) -> [(Double, Double)] {
        guard let raw else { return [] }
        return raw.components(separatedBy: ";").compactMap { pair in
            let xz = pair.components(separatedBy: ",")
            guard xz.count == 2, let x = Double(xz[0]), let z = Double(xz[1]) else { return nil }
            return (x, z)
        }
    }

    /// Attaches per-marker world positions ("x,z;x,z;…", index-aligned).
    private static func applyWorld(_ points: [Marker], _ raw: String?) -> [Marker] {
        let world = parseWorld(raw)
        return points.enumerated().map { index, point in
            var marker = point
            if index < world.count { marker.worldX = world[index].0; marker.worldZ = world[index].1 }
            return marker
        }
    }

    /// Attaches per-marker rotations ("deg;deg;…", index-aligned; empty = none).
    private static func applyRotations(_ points: [Marker], _ raw: String?) -> [Marker] {
        guard let raw else { return points }
        let degrees = raw.components(separatedBy: ";")
        return points.enumerated().map { index, point in
            var marker = point
            if index < degrees.count { marker.rotationDeg = Double(degrees[index]) }
            return marker
        }
    }

    private static func userComment(from imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let comment = exif[kCGImagePropertyExifUserComment as String] as? String
        else { return nil }
        return comment
    }
}
