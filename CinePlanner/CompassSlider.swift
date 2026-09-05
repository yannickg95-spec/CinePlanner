//
//  CompassSlider.swift
//  CinePlanner
//
//  Choosing which way is up, in compass terms rather than degrees of correction.
//
//  Both places that turn a satellite map — the location picker and the reframe tool
//  on the canvas — use this, and both bind it to the *absolute* heading rather than
//  a turn from wherever the map happens to sit. A relative control reads as 0 every
//  time you open it, which says nothing about where the map is pointing and makes
//  two such controls disagree with each other.
//

import SwiftUI

enum Compass {
    /// Nearest compass point to a heading: N, NE, E, and so on.
    static func label(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((normalized(degrees) / 45).rounded()) % 8]
    }

    /// A heading folded into 0..<360.
    static func normalized(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// The shortest turn from one heading to another, in (-180, 180]. Two headings
    /// that mean the same direction — 300 and -60, say — come back as no turn at all.
    static func signedDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    /// "NE 45°" — the compass point first, since that's what's being chosen; the
    /// number is only there for precision.
    static func readout(_ degrees: Double) -> String {
        "\(label(degrees)) \(Int(normalized(degrees).rounded()))°"
    }
}

/// A slider across the whole compass, ticked N E S W, for picking the direction
/// that points up. Wraps the bound heading into 0..<360, so it always opens showing
/// where the map actually points.
struct CompassSlider: View {
    @Binding var heading: Double
    var width: CGFloat?

    var body: some View {
        VStack(spacing: 1) {
            Slider(value: wrapped, in: 0...360)
            HStack(spacing: 0) {
                ForEach(Array(["N", "E", "S", "W", "N"].enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .frame(maxWidth: .infinity,
                               alignment: item.offset == 0 ? .leading
                                        : (item.offset == 4 ? .trailing : .center))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }

    private var wrapped: Binding<Double> {
        Binding(get: { Compass.normalized(heading) },
                set: { heading = $0 >= 360 ? 0 : $0 })
    }
}
