//
//  CoveragePalette.swift
//  CinePlanner
//
//  The colours a shot's coverage is drawn in, and how they are handed out across
//  a script. A shot keeps the same colour everywhere — the script editor's
//  overlay, the on-screen viewer, the burned-in PDF and the web export — which
//  only holds while all four ask the same question here.
//
//  Both settings live on the Project, so they sync through iCloud and a series
//  looks the same across its episodes and on every device.
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Palette

/// A ready-made set of coverage colours.
enum CoveragePaletteChoice: String, CaseIterable, Identifiable, Codable {
    case classic, vivid, muted, highContrast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:      return "Classic"
        case .vivid:        return "Vivid"
        case .muted:        return "Muted"
        case .highContrast: return "High Contrast"
        }
    }

    var detail: String {
        switch self {
        case .classic:      return "The system colours CinePlanner has always used."
        case .vivid:        return "Saturated and loud — easiest to pick out at a glance."
        case .muted:        return "Softer, for a page carrying a lot of coverage."
        case .highContrast: return "Chosen to stay distinguishable with colour-blindness."
        }
    }

    var colors: [PlatformColor] {
        switch self {
        case .classic:
            // Unchanged from before the palettes existed, so old projects keep
            // the colours they were planned with.
            return [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink,
                    .systemTeal, .systemIndigo, .systemRed, .systemYellow, .systemBrown]
        case .vivid:
            return ["#0A6CFF", "#00A63E", "#FF6A00", "#8E24FF", "#FF1F6B",
                    "#00B3C4", "#4B32E0", "#E01B24", "#C79A00", "#8A5A2B"].map(PlatformColor.hex)
        case .muted:
            return ["#5B7FA6", "#6E9B6E", "#C08A5A", "#8A7AA6", "#B57F94",
                    "#5F98A0", "#6F6BA0", "#B06A62", "#A08A55", "#8A7466"].map(PlatformColor.hex)
        case .highContrast:
            // Okabe–Ito, a palette designed to stay separable for the common
            // colour-vision deficiencies. Its yellow is dropped: too pale to read
            // as a line on a white script page.
            return ["#E69F00", "#56B4E9", "#009E73", "#0072B2",
                    "#D55E00", "#CC79A7", "#000000"].map(PlatformColor.hex)
        }
    }
}

extension CoveragePaletteChoice {
    /// The same colours for SwiftUI, so a settings screen can show swatches of
    /// exactly what the renderers will draw.
    var displayColors: [Color] {
        #if canImport(UIKit)
        return colors.map(Color.init(uiColor:))
        #else
        return colors.map(Color.init(nsColor:))
        #endif
    }
}

// MARK: - How colours are handed out

/// How coverage colours are distributed over a script's shots.
enum CoverageColorMode: String, CaseIterable, Identifiable, Codable {
    /// The palette restarts at every scene, so shot 1 of each scene shares a colour.
    case perScene
    /// The palette runs on across the whole script, so neighbouring scenes differ.
    case acrossScript
    /// One colour per scene: every line in a scene matches, scenes differ.
    case sceneUniform

    var id: String { rawValue }

    var label: String {
        switch self {
        case .perScene:     return "Restart Each Scene"
        case .acrossScript: return "Spread Across Script"
        case .sceneUniform: return "One Colour Per Scene"
        }
    }

    var detail: String {
        switch self {
        case .perScene:
            return "Shots are coloured by their order within the scene, so the same colours repeat scene after scene."
        case .acrossScript:
            return "Colours keep cycling through the whole script, so shots near each other rarely match."
        case .sceneUniform:
            return "Every coverage line in a scene shares one colour, and the colour changes per scene."
        }
    }
}

// MARK: - Resolving a shot's colour

/// Works out each shot's coverage colour for one script version.
///
/// Build it once and reuse it for a whole render pass. Two of the modes need a
/// shot's place in the entire script, which is far too costly to work out per
/// line while drawing.
struct CoverageColoring {
    private let colors: [PlatformColor]
    private let byShotUID: [String: PlatformColor]

    init(version: ScriptVersion?, project: Project?) {
        let palette = project?.coveragePalette ?? .classic
        let mode = project?.coverageColorMode ?? .perScene
        colors = palette.colors

        let scenes = (version?.scenes ?? project?.scenes ?? [])
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }

        var map: [String: PlatformColor] = [:]
        var running = 0
        for (sceneIndex, scene) in scenes.enumerated() {
            for (shotIndex, shot) in scene.orderedShots.enumerated() {
                let slot: Int
                switch mode {
                case .perScene:     slot = shotIndex
                case .acrossScript: slot = running
                case .sceneUniform: slot = sceneIndex
                }
                map[shot.uid] = colors[slot % colors.count]
                running += 1
            }
        }
        byShotUID = map
    }

    /// The colour for a shot. Falls back to its position within its own scene for
    /// a shot the version doesn't list — an archived scene, or one still being
    /// imported — so a line is never left without a colour.
    func color(for shot: Shot) -> PlatformColor {
        if let c = byShotUID[shot.uid] { return c }
        let index = shot.scene?.orderedShots.firstIndex { $0 === shot } ?? 0
        return colors[index % colors.count]
    }
}
