//
//  FloorPlan.swift
//  CinePlanner
//
//  A vector floor plan drawn as the scene-map background. Walls are edges
//  between shared vertices (points), so moving a point moves every wall
//  attached to it and the walls stay joined. Doors/windows sit on a wall.
//  Coordinates are normalized 0…1 within the map's (square) content rect,
//  matching how markers are stored. Persisted as JSON on Scene.sceneFloorPlanJSON.
//

import Foundation
import CoreGraphics

/// A shared corner point, normalized 0…1.
struct FloorVertex: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var x: Double
    var y: Double
    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// A wall segment between two vertices.
struct Wall: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var a: UUID
    var b: UUID
}

/// A door or window sitting on a wall.
struct Opening: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case door, window }
    var id: UUID = UUID()
    var kind: Kind
    var wallID: UUID
    /// Center position along the wall, 0…1 from the wall's first endpoint.
    var t: Double = 0.5
    /// Width along the wall, in normalized content units.
    var width: Double = 0.08
    /// Door only: which side of the wall it swings to (vertical flip).
    var flipped: Bool = false
    /// Door only: which jamb it hinges on (horizontal flip).
    var hingeAtEnd: Bool = false
    /// Door only: drawn nearly shut (small swing) rather than open.
    var closed: Bool = false

    enum CodingKeys: String, CodingKey { case id, kind, wallID, t, width, flipped, hingeAtEnd, closed }

    init(kind: Kind, wallID: UUID, t: Double = 0.5) {
        self.kind = kind; self.wallID = wallID; self.t = t
    }

    // Tolerate missing keys so future fields can't break decoding of old plans.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        wallID = try c.decode(UUID.self, forKey: .wallID)
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.08
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        hingeAtEnd = try c.decodeIfPresent(Bool.self, forKey: .hingeAtEnd) ?? false
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }
}

struct FloorPlan: Codable, Equatable {
    var vertices: [FloorVertex] = []
    var walls: [Wall] = []
    var openings: [Opening] = []

    var isEmpty: Bool { vertices.isEmpty && walls.isEmpty && openings.isEmpty }

    enum CodingKeys: String, CodingKey { case vertices, walls, openings }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vertices = try c.decodeIfPresent([FloorVertex].self, forKey: .vertices) ?? []
        walls = try c.decodeIfPresent([Wall].self, forKey: .walls) ?? []
        openings = try c.decodeIfPresent([Opening].self, forKey: .openings) ?? []
    }

    func vertex(_ id: UUID) -> FloorVertex? { vertices.first { $0.id == id } }
    func wall(_ id: UUID) -> Wall? { walls.first { $0.id == id } }

    /// Normalized endpoints of a wall, or nil if a vertex is missing.
    func endpoints(_ wall: Wall) -> (CGPoint, CGPoint)? {
        guard let a = vertex(wall.a), let b = vertex(wall.b) else { return nil }
        return (a.point, b.point)
    }

    /// Wall length in normalized units.
    func length(_ wall: Wall) -> Double {
        guard let (a, b) = endpoints(wall) else { return 0 }
        return hypot(b.x - a.x, b.y - a.y)
    }

    // MARK: - JSON round-tripping (stored on Scene.sceneFloorPlanJSON)

    static func load(from json: String?) -> FloorPlan {
        guard let json, let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(FloorPlan.self, from: data) else {
            return FloorPlan()
        }
        return plan
    }

    /// Encoded string, or nil when empty (so an untouched scene stores nothing).
    var jsonString: String? {
        guard !isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
