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
//  A video's map also says where the camera went, when it travelled: every
//  position it stood at, in order, and the points the route from each to the
//  next bends through (legs separated by "/", a straight one empty):
//
//    CameraPathMap2D:u,v;u,v;…      (CameraMap2D is the first)
//    CameraPathTime:s;s;…           (seconds into the video at each)
//    CameraPathRoute:u,v;u,v/…
//
//  and where the people in view went, the same way per person, people
//  separated by "#" (index-aligned with ActorsMap2D, where each started):
//
//    ActorPathsMap2D:u,v;u,v#u,v;…
//    ActorPathsRoute:u,v/…#…
//
//  The clean (marker-free) map is framed on the location alone: the square of
//  its world bounds. Where that square lies on this map says how a marker here
//  lands on the clean map:
//
//    CleanMapRect2D:uMin,vMin,uMax,vMax
//
//  Older maps don't record it; it's worked out from the room rect and the
//  markers' world positions (see `derivedCleanMapRect`).
//

import CoreGraphics
import Foundation
import ImageIO

/// Where a CineStager location is on earth, as shots.json and the map's EXIF
/// carry it.
nonisolated struct CineStagerPlace: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    /// An IANA time zone, e.g. "Europe/Amsterdam".
    var timeZoneIdentifier: String?
    /// The address it was found by in CineStager.
    var name: String?

    /// Within ~50 m of `other`: the same place.
    func isNear(latitude: Double, longitude: Double) -> Bool {
        abs(self.latitude - latitude) < 0.0005 && abs(self.longitude - longitude) * cos(self.latitude * .pi / 180) < 0.0005
    }
}

nonisolated enum CineStagerMapMetadata {
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

    /// Where a video's camera, or a person in it, went: the positions it stood
    /// at, in order, and the points the route from each to the next bends
    /// through (one leg fewer than positions; a straight leg is empty).
    struct MovementPath: Equatable {
        var positions: [Marker]
        var legs: [[CGPoint]]
        /// Seconds into the video at each position (index-aligned); empty when the
        /// map doesn't say.
        var times: [Double] = []
    }

    struct Markers: Equatable {
        /// The camera; for a video, where it started.
        var camera: Marker?
        /// A video's camera, when it travelled (two or more positions).
        var cameraPath: MovementPath?
        var mannequins: [Marker] = []
        /// The people CineStager saw; for a video, where each started.
        var actors: [Marker] = []
        /// A video's people: where each went (index-aligned with `actors`), when
        /// one of them travelled.
        var actorPaths: [MovementPath] = []
        /// The room's footprint within the map image (normalized 0…1, origin
        /// top-left), when CineStager recorded it: the location's world bounds as
        /// they land on the map, so larger than the room when it's turned.
        var roomRect: CGRect?
        /// Where the clean map lies on this map (normalized, origin top-left), so
        /// markers can be placed on it; nil when it can't be told.
        var cleanMapRect: CGRect?
        /// The longer side (m) of the location's world bounds: how wide the clean
        /// map is.
        var locationSpan: Double?
        /// Which way north lies on the map: degrees clockwise from the top of the
        /// image (it holds for the clean map too), when the location knows it.
        var mapNorth: Double?
        /// Where on earth the location is, when it's been set.
        var place: CineStagerPlace?
        /// The storey the camera stood on (0 = the lowest set up), for a location
        /// with several.
        var floor: Int?

        var isEmpty: Bool { camera == nil && cameraPath == nil && mannequins.isEmpty && actors.isEmpty }

        /// The camera's positions: a video's path, else the one camera.
        var cameraPositions: [Marker] { cameraPath?.positions ?? camera.map { [$0] } ?? [] }

        /// Each person's positions and route: a video's paths, else where each stood.
        var actorMovements: [MovementPath] {
            actorPaths.isEmpty ? actors.map { MovementPath(positions: [$0], legs: []) } : actorPaths
        }
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
        if let path = fields["CameraPathMap2D"] {
            let positions = applyWorld(applyRotations(parsePoints(path), fields["CameraPathMapRot"]),
                                       fields["CameraPathWorldXZ"])
            if positions.count > 1 {
                markers.cameraPath = movement(positions, route: fields["CameraPathRoute"], times: fields["CameraPathTime"])
            }
        }
        if let manns = fields["MannequinsMap2D"] {
            markers.mannequins = applyWorld(applyRotations(parsePoints(manns), fields["MannequinsMapRot"]),
                                            fields["MannequinsWorldXZ"])
        }
        if let actors = fields["ActorsMap2D"] {
            markers.actors = applyWorld(applyRotations(parsePoints(actors), fields["ActorsMapRot"]),
                                        fields["ActorsWorldXZ"])
        }
        markers.actorPaths = actorPaths(fields, people: markers.actors.count)
        markers.roomRect = parseRect(fields["RoomRectMap2D"])
        let sides = ["Location Width", "Location Length"].compactMap { key in
            fields[key].flatMap { Double($0.replacingOccurrences(of: "m", with: "")) }
        }
        markers.locationSpan = sides.max()
        markers.cleanMapRect = parseRect(fields["CleanMapRect2D"]) ?? derivedCleanMapRect(markers)
        markers.mapNorth = fields["MapNorth"].flatMap { Double($0) }
        if let lat = fields["Location Latitude"].flatMap({ Double($0) }),
           let lon = fields["Location Longitude"].flatMap({ Double($0) }) {
            markers.place = CineStagerPlace(latitude: lat, longitude: lon,
                                            timeZoneIdentifier: fields["Location Time Zone"].flatMap { $0.isEmpty ? nil : $0 },
                                            name: fields["Location Place"].flatMap { $0.isEmpty ? nil : $0 })
        }
        markers.floor = fields["Location Floor"].flatMap { Int($0) }
        return markers.isEmpty ? nil : markers
    }

    /// Where the clean map lies on an older map, which doesn't say. The clean map
    /// is the square of the location's world bounds, `locationSpan` wide, and the
    /// room rect is those bounds as they land on this map — so its centre is the
    /// square's. How large the square is here follows from how far apart two
    /// markers are on this map and in the world (half a metre at least, for
    /// precision). Nil without them.
    private static func derivedCleanMapRect(_ markers: Markers) -> CGRect? {
        guard let room = markers.roomRect, let span = markers.locationSpan, span > 0 else { return nil }
        let placed = (markers.cameraPositions + markers.mannequins + markers.actors).compactMap { marker -> (map: CGPoint, world: CGPoint)? in
            guard let x = marker.worldX, let z = marker.worldZ else { return nil }
            return (CGPoint(x: marker.u, y: marker.v), CGPoint(x: x, y: z))
        }
        var farthest: (map: Double, world: Double)?
        for (index, a) in placed.enumerated() {
            for b in placed[(index + 1)...] {
                let world = Double(hypot(a.world.x - b.world.x, a.world.y - b.world.y))
                if world > (farthest?.world ?? 0.5) {
                    farthest = (Double(hypot(a.map.x - b.map.x, a.map.y - b.map.y)), world)
                }
            }
        }
        guard let farthest else { return nil }
        let side = span * farthest.map / farthest.world
        return CGRect(x: room.midX - side / 2, y: room.midY - side / 2, width: side, height: side)
    }

    /// A path through `positions`, with the legs of `route` ("u,v;u,v/…") and
    /// the seconds of `times` ("s;s;…", dropped unless one per position).
    private static func movement(_ positions: [Marker], route: String?, times: String?) -> MovementPath {
        let legs = (route ?? "").components(separatedBy: "/").map { leg in
            parsePoints(leg).map { CGPoint(x: $0.u, y: $0.v) }
        }
        let seconds = (times ?? "").components(separatedBy: ";").map { Double($0) }
        return MovementPath(positions: positions,
                            legs: (0..<max(positions.count - 1, 0)).map { $0 < legs.count ? legs[$0] : [] },
                            times: seconds.count == positions.count ? seconds.compactMap { $0 } : [])
    }

    /// The people's paths, `people` of them — none unless the map has them for
    /// each.
    private static func actorPaths(_ fields: [String: String], people: Int) -> [MovementPath] {
        guard let all = fields["ActorPathsMap2D"] else { return [] }
        let positions = all.components(separatedBy: "#")
        guard positions.count == people else { return [] }
        func each(_ key: String) -> [String?] {
            let parts = fields[key]?.components(separatedBy: "#") ?? []
            return positions.indices.map { $0 < parts.count ? parts[$0] : nil }
        }
        let rotations = each("ActorPathsMapRot"), worlds = each("ActorPathsWorldXZ")
        let routes = each("ActorPathsRoute"), times = each("ActorPathsTime")
        return positions.indices.map { person in
            movement(applyWorld(applyRotations(parsePoints(positions[person]), rotations[person]), worlds[person]),
                 route: routes[person], times: times[person])
        }
    }

    /// "uMin,vMin,uMax,vMax" → a rect; nil when malformed or empty.
    private static func parseRect(_ raw: String?) -> CGRect? {
        guard let n = raw?.components(separatedBy: ",").compactMap({ Double($0) }),
              n.count == 4, n[2] > n[0], n[3] > n[1] else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
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
