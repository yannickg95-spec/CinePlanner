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
    var colorHex: String = "#4C8DFF"

    // Camera-only: drives the FOV cone.
    var focalLengthMM: Double = 35
    var sensorWidthMM: Double = 24.89   // Super 35 width by default

    /// Horizontal field of view in degrees, from focal length + sensor width.
    var horizontalFOV: Double {
        guard focalLengthMM > 0 else { return 0 }
        return 2 * atan(sensorWidthMM / (2 * focalLengthMM)) * 180 / .pi
    }
}

/// The whole scene map document.
struct SceneMapDoc: Codable, Equatable {
    var elements: [MapElement] = []

    var isEmpty: Bool { elements.isEmpty }

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
