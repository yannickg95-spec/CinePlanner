//
//  CoveragePalette.swift
//  CinePlanner
//
//  The colours a shot's coverage is drawn in. A shot's colour is its position
//  within its scene, so the same shot keeps the same colour everywhere: the
//  script editor's overlay, the on-screen viewer, the burned-in PDF and the
//  web-export images.
//
//  That promise only holds while every one of those draws from the same list —
//  it used to be copied into four places that had to be kept in step by hand.
//

import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum CoveragePalette {
    /// Ten distinct hues, cycled by a shot's index within its scene.
    static let colors: [PlatformColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink,
        .systemTeal, .systemIndigo, .systemRed, .systemYellow, .systemBrown
    ]

    /// The colour for a shot at `index` within its scene.
    static func color(at index: Int) -> PlatformColor {
        colors[abs(index) % colors.count]
    }
}
