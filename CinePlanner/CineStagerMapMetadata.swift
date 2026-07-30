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
    /// A normalized marker position (0…1 from the top-left of the map image).
    struct Marker: Equatable {
        var u: Double
        var v: Double
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
        if let camera = fields["CameraMap2D"], let point = parsePoints(camera).first {
            markers.camera = point
        }
        if let manns = fields["MannequinsMap2D"] {
            markers.mannequins = parsePoints(manns)
        }
        if let actors = fields["ActorsMap2D"] {
            markers.actors = parsePoints(actors)
        }
        return markers.isEmpty ? nil : markers
    }

    /// "u,v;u,v" → [Marker]. Skips malformed entries.
    private static func parsePoints(_ raw: String) -> [Marker] {
        raw.components(separatedBy: ";").compactMap { pair in
            let xy = pair.components(separatedBy: ",")
            guard xy.count == 2, let u = Double(xy[0]), let v = Double(xy[1]) else { return nil }
            return Marker(u: u, v: v)
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
