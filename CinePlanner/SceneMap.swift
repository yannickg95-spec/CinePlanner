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
    /// Hide this marker's name label without clearing the name — per marker, so one
    /// of a character's two walk markers can show the name while the other doesn't.
    var labelHidden: Bool = false
    /// User nudge (in canvas points) applied to the label on top of its default
    /// position below the marker, so a label can be moved clear of an arrow.
    var labelOffset: CGSize = .zero
    /// For a camera imported from a shot: the shot's stable uid, so the marker's
    /// label tracks the shot's number if it's renumbered. nil = free-standing.
    var shotUID: String? = nil
    /// ARKit world position (metres) this marker came from, for markers imported
    /// from CineStager. It's the same whichever shot/map framing it appears in, so a
    /// later import can tell an unmoved mannequin (already on the map) from one that
    /// moved. nil for hand-placed markers. Not used for drawing.
    var worldX: Double? = nil
    var worldZ: Double? = nil
    var colorHex: String = "#4C8DFF"

    // Camera-only: drives the FOV cone.
    var focalLengthMM: Double = 35
    var sensorWidthMM: Double = 24.89   // Super 35 width by default
    /// Camera-only: which sensor this camera's FOV wedge is sized from. nil =
    /// auto — the shot's own CineStager sensor when it has one, else Super-35.
    /// An explicit value (S16/S35/LF or the CineStager camera) overrides that.
    var fovBasis: FOVBasis? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, x, y, rotation, label, labelHidden, labelOffset, shotUID, worldX, worldZ, colorHex, focalLengthMM, sensorWidthMM, fovBasis
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
        labelHidden = try c.decodeIfPresent(Bool.self, forKey: .labelHidden) ?? false
        labelOffset = try c.decodeIfPresent(CGSize.self, forKey: .labelOffset) ?? .zero
        shotUID = try c.decodeIfPresent(String.self, forKey: .shotUID)
        worldX = try c.decodeIfPresent(Double.self, forKey: .worldX)
        worldZ = try c.decodeIfPresent(Double.self, forKey: .worldZ)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#4C8DFF"
        focalLengthMM = try c.decodeIfPresent(Double.self, forKey: .focalLengthMM) ?? 35
        sensorWidthMM = try c.decodeIfPresent(Double.self, forKey: .sensorWidthMM) ?? 24.89
        fovBasis = try c.decodeIfPresent(FOVBasis.self, forKey: .fovBasis)
    }

    /// Horizontal field of view in degrees, from focal length + sensor width.
    var horizontalFOV: Double {
        guard focalLengthMM > 0 else { return 0 }
        return 2 * atan(sensorWidthMM / (2 * focalLengthMM)) * 180 / .pi
    }
}

/// What the scene-map camera FOV wedges are sized from. The three fixed formats
/// use a standard horizontal sensor width; `.cineStager` uses each shot's own
/// sensor width imported from CineStager (falling back to Super-35 for shots
/// without it).
enum FOVBasis: String, Codable, CaseIterable {
    case super16, super35, largeFormat, cineStager

    /// Fixed horizontal sensor width (mm), or nil for `.cineStager` (per-shot).
    /// Super-16 ≈ 12.52 mm, Super-35 ≈ 24.89 mm, Large Format ≈ 36.70 mm.
    var fixedSensorWidthMM: Double? {
        switch self {
        case .super16: return 12.52
        case .super35: return 24.89
        case .largeFormat: return 36.70
        case .cineStager: return nil
        }
    }

    /// Short menu label for the fixed formats (the CineStager option shows the
    /// camera's name instead).
    var menuLabel: String {
        switch self {
        case .super16: return "S16"
        case .super35: return "S35"
        case .largeFormat: return "LF"
        case .cineStager: return "CineStager Camera"
        }
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
        // Lights — shown on their own toolbar tab, in this order.
        case smallLight = "Small Light"
        case mediumLight = "Medium Light"
        case bigLight = "Big Light"
        case tube = "Tube"           // long tube, 120 cm (kept rawValue for old maps)
        case shortTube = "Short Tube" // 60 cm
        case bounce = "Bounce"
        case softbox = "Softbox"   // shown as "Small Softbox"
        case mediumSoftbox = "Medium Softbox"
        case bigSoftbox = "Big Softbox"
        case par = "PAR"
        case lightBall = "Light Ball"
        case practical = "Practical"
        case lightPanel = "Light Panel"   // shown as "2x1 Panel"
        case panel1x1 = "1x1 Panel"
        case smallHMI = "Small HMI"
        case mediumHMI = "Medium HMI"
        case bigHMI = "Big HMI"
        case smallTungsten = "Small Tungsten"
        case mediumTungsten = "Medium Tungsten"
        case bigTungsten = "Big Tungsten"
        // LED COB heads — grouped under an "LED COB" submenu in the light tab.
        case smallCOB = "Small COB"
        case mediumCOB = "Medium COB"
        case bigCOB = "Big COB"

        /// Name shown in menus. Kept separate from `rawValue` (which is the stable
        /// storage key) so a piece can be renamed without breaking old saved maps.
        var displayName: String {
            switch self {
            case .lightPanel: return "2x1 Panel"
            case .softbox:    return "Small Softbox"
            default:          return rawValue
            }
        }

        /// Default size (normalized to the map's content rect) for a new piece.
        var defaultSize: CGSize {
            switch self {
            case .table:       return CGSize(width: 0.15, height: 0.10)
            case .roundTable:  return CGSize(width: 0.12, height: 0.12)
            case .chair:       return CGSize(width: 0.05, height: 0.05)
            case .sofa:        return CGSize(width: 0.22, height: 0.08)
            case .bed:         return CGSize(width: 0.16, height: 0.20)
            case .rug:         return CGSize(width: 0.26, height: 0.18)
            case .plant:       return CGSize(width: 0.05, height: 0.05)
            // Deeper than wide, matching the STORM 80C / 700x top-view proportions.
            case .smallLight:  return CGSize(width: 0.056, height: 0.101)
            case .mediumLight: return CGSize(width: 0.064, height: 0.101)
            // Deeper than wide, matching the STORM CS32 top-view proportions.
            case .bigLight:    return CGSize(width: 0.073, height: 0.109)
            case .tube:        return CGSize(width: 0.22, height: 0.013)
            case .shortTube:   return CGSize(width: 0.11, height: 0.013)
            case .bounce:      return CGSize(width: 0.20, height: 0.014)
            case .softbox:       return CGSize(width: 0.10, height: 0.10)
            case .mediumSoftbox: return CGSize(width: 0.13, height: 0.13)
            case .bigSoftbox:    return CGSize(width: 0.19, height: 0.127)
            case .par:         return CGSize(width: 0.06, height: 0.06)
            case .lightBall:   return CGSize(width: 0.12, height: 0.12)
            case .practical:   return CGSize(width: 0.04, height: 0.04)
            case .lightPanel:  return CGSize(width: 0.13, height: 0.023)
            case .panel1x1:    return CGSize(width: 0.066, height: 0.023)
            case .smallHMI:    return CGSize(width: 0.063, height: 0.061)
            case .mediumHMI:   return CGSize(width: 0.09, height: 0.101)
            case .smallTungsten: return CGSize(width: 0.043, height: 0.05)
            case .mediumTungsten: return CGSize(width: 0.10, height: 0.113)
            case .bigTungsten: return CGSize(width: 0.13, height: 0.163)
            case .bigHMI:      return CGSize(width: 0.12, height: 0.137)
            // COBs are the STORM 80C / 1200x / XT52 designs, so they match the lights.
            case .smallCOB:    return CGSize(width: 0.056, height: 0.101)
            case .mediumCOB:   return CGSize(width: 0.064, height: 0.101)
            case .bigCOB:      return CGSize(width: 0.073, height: 0.109)
            }
        }

        /// Real-world default footprint in metres, when a piece has a standard size.
        /// Used on a scaled map so it's placed at true size (still freely resizable);
        /// otherwise `defaultSize` (normalized) is used.
        var defaultRealSize: CGSize? {
            switch self {
            case .lightBall: return CGSize(width: 0.60, height: 0.60)   // 60 cm across
            case .practical: return CGSize(width: 0.20, height: 0.20)   // 20 cm across
            case .softbox:       return CGSize(width: 0.50, height: 0.50)   // small, 50 × 50 cm
            case .mediumSoftbox: return CGSize(width: 0.90, height: 0.90)   // medium, 90 × 90 cm
            case .bigSoftbox:    return CGSize(width: 1.50, height: 1.00)   // big, 150 × 100 cm
            case .tube:      return CGSize(width: 1.20, height: 0.07)   // 120 × 7 cm
            case .shortTube: return CGSize(width: 0.60, height: 0.07)   // 60 × 7 cm
            case .bounce:    return CGSize(width: 1.00, height: 0.07)   // 100 × 7 cm
            // Aputure STORM XT52 from above: 53 cm wide, 55 cm body + 20 cm reflector
            // ≈ 79 cm long.
            case .bigLight:  return CGSize(width: 0.53, height: 0.794)
            // Aputure STORM 1200x from above: 33×33 cm body (incl. yoke) + 15 cm
            // reflector → 33 cm wide × 51.9 cm long.
            case .mediumLight: return CGSize(width: 0.33, height: 0.519)
            // Aputure STORM 80C from above: ~22 cm wide, 40 cm long (18 cm reflector).
            case .smallLight:  return CGSize(width: 0.22, height: 0.40)
            // COBs are the STORM 80C / 1200x / XT52 designs, so they match the lights.
            case .smallCOB:    return CGSize(width: 0.22, height: 0.40)
            case .mediumCOB:   return CGSize(width: 0.33, height: 0.519)
            case .bigCOB:      return CGSize(width: 0.53, height: 0.794)
            // 2x1 LED panel from above: 69 cm wide × 12 cm deep.
            case .lightPanel:  return CGSize(width: 0.69, height: 0.12)
            // 1x1 LED panel from above: 35 cm wide × 12 cm deep.
            case .panel1x1:    return CGSize(width: 0.35, height: 0.12)
            // HMI heads from above (reflector + finned housing): length given by user.
            case .smallHMI:    return CGSize(width: 0.28, height: 0.27)   // 28 × 27 cm
            case .mediumHMI:   return CGSize(width: 0.40, height: 0.45)   // 40 × 45 cm
            case .bigHMI:      return CGSize(width: 0.70, height: 0.80)   // 18K: 70 × 80 cm
            case .smallTungsten: return CGSize(width: 0.19, height: 0.22)  // 19 × 22 cm
            case .mediumTungsten: return CGSize(width: 0.46, height: 0.52) // 46 × 52 cm
            case .bigTungsten: return CGSize(width: 0.80, height: 1.00)   // 80 × 100 cm
            default:         return nil
            }
        }

        var isRound: Bool {
            switch self {
            case .roundTable, .plant, .par, .lightBall, .practical:
                return true
            default:
                return false
            }
        }

        /// LED COB heads (the STORM 80C / 1200x / XT52), grouped under an "LED COB"
        /// submenu at the top of the light tab.
        var isCOB: Bool {
            self == .smallCOB || self == .mediumCOB || self == .bigCOB
        }

        /// HMI heads (Small/Medium/Big), grouped under an "HMI" submenu.
        var isHMI: Bool {
            self == .smallHMI || self == .mediumHMI || self == .bigHMI
        }

        /// Tungsten heads (Small/Medium/Big), grouped under a "Tungsten" submenu.
        var isTungsten: Bool {
            self == .smallTungsten || self == .mediumTungsten || self == .bigTungsten
        }

        /// LED panels (2x1 / 1x1).
        var isPanel: Bool { self == .lightPanel || self == .panel1x1 }

        /// Softbox heads (Small/Medium/Big).
        var isSoftbox: Bool { self == .softbox || self == .mediumSoftbox || self == .bigSoftbox }

        /// Fixtures a softbox can be mounted on (its base snaps to their front).
        var canMountSoftbox: Bool { isHMI || isTungsten || isCOB || isPanel }

        /// Pieces whose width:height ratio is locked while resizing, so they can only
        /// scale uniformly and never be stretched.
        var lockAspectRatio: Bool { isCOB || isHMI || isTungsten || isPanel }

        /// LED tubes (long/short): only their length resizes; the cross-section
        /// (physical width) stays fixed, and can be swapped via the "modifier".
        var isTube: Bool { self == .tube || self == .shortTube }

        /// Pieces that resize along their long axis only, keeping a fixed cross-section
        /// (tubes and the bounce board).
        var resizeWidthOnly: Bool { isTube || self == .bounce }

        /// The original Small/Medium/Big Light kinds are now superseded by the COBs;
        /// kept for decoding old maps, but no longer shown in the menu.
        var isLegacyLight: Bool {
            self == .smallLight || self == .mediumLight || self == .bigLight
        }

        /// Lights live on their own toolbar tab, not in the furniture menu.
        var isLight: Bool {
            switch self {
            case .smallLight, .mediumLight, .bigLight, .tube, .shortTube, .bounce,
                 .softbox, .mediumSoftbox, .bigSoftbox,
                 .par, .lightBall, .practical, .lightPanel, .panel1x1,
                 .smallHMI, .mediumHMI, .bigHMI,
                 .smallTungsten, .mediumTungsten, .bigTungsten,
                 .smallCOB, .mediumCOB, .bigCOB:
                return true
            default:
                return false
            }
        }

        /// Default tint for a new piece — a warm glow for lights, neutral grey else.
        var defaultColorHex: String { isLight ? "#F2C14E" : "#8E8E93" }
    }

    var id: UUID = UUID()
    var kind: Kind
    var x: Double            // normalized center
    var y: Double
    var width: Double        // normalized
    var height: Double
    var rotation: Double = 0
    var colorHex: String = "#8E8E93"
    var label: String = ""
    var labelOffset: CGSize = .zero   // canvas-point nudge from the label's default spot
    /// Tube only: a diffusion modifier is fitted, widening its cross-section to 20 cm.
    var hasModifier: Bool = false

    enum CodingKeys: String, CodingKey { case id, kind, x, y, width, height, rotation, colorHex, label, labelOffset, hasModifier }

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
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        labelOffset = try c.decodeIfPresent(CGSize.self, forKey: .labelOffset) ?? .zero
        hasModifier = try c.decodeIfPresent(Bool.self, forKey: .hasModifier) ?? false
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
    /// stores nothing). "Empty" means no elements *and* no arrows *and* no
    /// furniture — keying only on elements silently dropped a map that had just
    /// furniture (or just arrows), so it never persisted.
    var jsonString: String? {
        guard !isEmpty else { return nil }
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
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        PlatformColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let ns = PlatformColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        r = ns.redComponent; g = ns.greenComponent; b = ns.blueComponent
        #endif
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
