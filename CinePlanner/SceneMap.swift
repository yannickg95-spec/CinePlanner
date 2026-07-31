//
//  SceneMap.swift
//  CinePlanner
//
//  A Shot Designer–style top-down blocking map for a scene: a canvas of
//  characters and cameras (with real field-of-view cones). Stored as a
//  self-contained JSON document on `Scene.sceneMapJSON`, so it rides the
//  existing archive + iCloud sync as a plain attribute — no new SwiftData
//  models or relationships.
//

import Foundation
import SwiftUI
import AppKit

/// One placed item on the map.
struct MapElement: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case character
        case camera
    }

    var id: UUID = UUID()
    var kind: Kind
    // Position normalized 0…1 within the map's content rect (the background
    // image's fitted rect, or the whole canvas when there's no background).
    // Origin top-left, matching CineStager's exported map coordinates.
    var x: Double
    var y: Double
    var rotation: Double = 0        // degrees, 0 = facing up, clockwise positive
    var label: String = ""
    /// User nudge (in canvas points) applied to the label on top of its default
    /// position below the marker, so a label can be moved clear of an arrow.
    var labelOffset: CGSize = .zero
    /// For a camera imported from a shot: the shot's stable uid, so the marker's
    /// label tracks the shot's number if it's renumbered. nil = free-standing.
    var shotUID: String? = nil
    var colorHex: String = "#4C8DFF"

    // Camera-only: drives the FOV cone.
    var focalLengthMM: Double = 35
    var sensorWidthMM: Double = 24.89   // Super 35 width by default

    enum CodingKeys: String, CodingKey {
        case id, kind, x, y, rotation, label, labelOffset, shotUID, colorHex, focalLengthMM, sensorWidthMM
    }

    init(kind: Kind, x: Double, y: Double) {
        self.kind = kind; self.x = x; self.y = y
    }

    // Tolerate missing keys so future fields can't break decoding of old maps.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        labelOffset = try c.decodeIfPresent(CGSize.self, forKey: .labelOffset) ?? .zero
        shotUID = try c.decodeIfPresent(String.self, forKey: .shotUID)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#4C8DFF"
        focalLengthMM = try c.decodeIfPresent(Double.self, forKey: .focalLengthMM) ?? 35
        sensorWidthMM = try c.decodeIfPresent(Double.self, forKey: .sensorWidthMM) ?? 24.89
    }

    /// Horizontal field of view in degrees, from focal length + sensor width.
    var horizontalFOV: Double {
        guard focalLengthMM > 0 else { return 0 }
        return 2 * atan(sensorWidthMM / (2 * focalLengthMM)) * 180 / .pi
    }
}

/// A movement arrow between two markers (e.g. an actor or camera moving from
/// one position to another during the shot).
struct MapArrow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var fromID: UUID
    var toID: UUID
    /// Optional bend points (normalized 0…1) the arrow routes through, in order
    /// from `fromID` to `toID`.
    var pivots: [CGPoint] = []

    enum CodingKeys: String, CodingKey { case id, fromID, toID, pivots }

    init(id: UUID = UUID(), fromID: UUID, toID: UUID, pivots: [CGPoint] = []) {
        self.id = id; self.fromID = fromID; self.toID = toID; self.pivots = pivots
    }

    // Tolerate older JSON without `pivots`, so adding the field can't wipe a map.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fromID = try c.decode(UUID.self, forKey: .fromID)
        toID = try c.decode(UUID.self, forKey: .toID)
        pivots = try c.decodeIfPresent([CGPoint].self, forKey: .pivots) ?? []
    }
}

/// A piece of furniture placed on the map (top-down).
struct Furniture: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case table = "Table"
        case roundTable = "Round Table"
        case chair = "Chair"
        case sofa = "Sofa"
        case bed = "Bed"
        case rug = "Rug"
        case plant = "Plant"

        /// Default size (normalized to the map's content rect) for a new piece.
        var defaultSize: CGSize {
            switch self {
            case .table:      return CGSize(width: 0.15, height: 0.10)
            case .roundTable: return CGSize(width: 0.12, height: 0.12)
            case .chair:      return CGSize(width: 0.05, height: 0.05)
            case .sofa:       return CGSize(width: 0.22, height: 0.08)
            case .bed:        return CGSize(width: 0.16, height: 0.20)
            case .rug:        return CGSize(width: 0.26, height: 0.18)
            case .plant:      return CGSize(width: 0.05, height: 0.05)
            }
        }

        var isRound: Bool { self == .roundTable || self == .plant }
    }

    var id: UUID = UUID()
    var kind: Kind
    var x: Double            // normalized center
    var y: Double
    var width: Double        // normalized
    var height: Double
    var rotation: Double = 0
    var colorHex: String = "#8E8E93"

    enum CodingKeys: String, CodingKey { case id, kind, x, y, width, height, rotation, colorHex }

    init(kind: Kind, x: Double, y: Double, width: Double, height: Double) {
        self.kind = kind; self.x = x; self.y = y; self.width = width; self.height = height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.1
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.1
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#8E8E93"
    }
}

/// The whole scene map document.
struct SceneMapDoc: Codable, Equatable {
    var elements: [MapElement] = []
    var arrows: [MapArrow] = []
    var furniture: [Furniture] = []

    var isEmpty: Bool { elements.isEmpty && arrows.isEmpty && furniture.isEmpty }

    enum CodingKeys: String, CodingKey { case elements, arrows, furniture }

    init() {}

    // Tolerate missing keys so adding a new collection (e.g. `furniture`) can
    // never make older saved maps fail to decode and get wiped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elements = try c.decodeIfPresent([MapElement].self, forKey: .elements) ?? []
        arrows = try c.decodeIfPresent([MapArrow].self, forKey: .arrows) ?? []
        furniture = try c.decodeIfPresent([Furniture].self, forKey: .furniture) ?? []
    }

    // MARK: - JSON round-tripping (stored on Scene.sceneMapJSON)

    static func load(from json: String?) -> SceneMapDoc {
        guard let json, let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(SceneMapDoc.self, from: data) else {
            return SceneMapDoc()
        }
        return doc
    }

    /// Encoded string, or nil when the map is empty (so an untouched scene
    /// stores nothing).
    var jsonString: String? {
        guard !elements.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Geometry helpers

enum MapGeometry {
    /// A point at `radius` from `center`, `angleDeg` measured clockwise from up.
    static func point(from center: CGPoint, angleDeg: Double, radius: Double) -> CGPoint {
        let r = angleDeg * .pi / 180
        return CGPoint(x: center.x + radius * sin(r), y: center.y - radius * cos(r))
    }
}

// MARK: - Hex colours

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.3; g = 0.55; b = 1.0
        }
        self = Color(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
