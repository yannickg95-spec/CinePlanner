//
//  CoverageLineLayout.swift
//  CinePlanner
//
//  Shared placement math for script-coverage lines, so the editor overlay, the
//  on-screen viewer, and every export lay them out identically.
//
//  Each coverage line gets a column via earliest-start interval colouring: lines
//  that don't share vertical space reuse a column, so the column count is the
//  largest number of lines overlapping at any one point (their true density).
//  Columns are then packed tightly from the text edge outward, spaced by just
//  enough for a full-size shot number — so numbers stay large and the lines stay
//  close together. Only when that won't fit does the spacing collapse to an even
//  spread across the whole band and the numbers scale down together (never
//  repositioned, never overlapping).
//

import CoreGraphics

enum CoverageLineLayout {

    /// One coverage line to place.
    ///
    /// `extent` is the bar's vertical span, used to pack columns. `band` is the
    /// usable margin x-range for this line, with `upperBound` the edge nearest the
    /// text (column 0) — it is per line because a selection spanning pages can
    /// resolve to different page bounds. `labelWidth`/`labelBand` describe the shot
    /// number at the base font; `labelBand` is nil when no number is drawn for this
    /// line (the continuation of a multi-page selection), so it never constrains
    /// the scale.
    struct Line {
        var extent: ClosedRange<CGFloat>
        var band: ClosedRange<CGFloat>
        var labelWidth: CGFloat = 0
        var labelBand: ClosedRange<CGFloat>? = nil
    }

    /// The resolved X for a line plus the single label scale shared by the whole set.
    struct Placed {
        var x: CGFloat
        var scale: CGFloat
    }

    /// Places `lines` and returns each one's X plus one uniform label scale in
    /// `minScale...1`. `spacingPad` is added to the widest shot number to get the
    /// column spacing; `labelGap` is the clearance kept between two numbers before
    /// they are scaled down. `onRight` packs the columns rightward from the band's
    /// lower (near-text) edge — for lines drawn down the right margin — instead of
    /// leftward from the upper edge.
    static func solve(_ lines: [Line],
                      spacingPad: CGFloat = 4,
                      labelGap: CGFloat = 2,
                      minScale: CGFloat = 0.4,
                      onRight: Bool = false) -> [Placed] {
        guard !lines.isEmpty else { return [] }

        // Column per line — reuse a column once its last bar has ended above this one.
        var columns = [Int](repeating: 0, count: lines.count)
        var columnMaxY: [CGFloat] = []
        for idx in lines.indices.sorted(by: { lines[$0].extent.lowerBound < lines[$1].extent.lowerBound }) {
            var placed = false
            for c in columnMaxY.indices where columnMaxY[c] <= lines[idx].extent.lowerBound {
                columnMaxY[c] = lines[idx].extent.upperBound
                columns[idx] = c
                placed = true
                break
            }
            if !placed {
                columns[idx] = columnMaxY.count
                columnMaxY.append(lines[idx].extent.upperBound)
            }
        }
        let count = max(1, columnMaxY.count)

        // Pack columns from the near-text edge; only widen to the full band if
        // forced. Left margin: anchor at the band's upper edge, columns go left.
        // Right margin: anchor at the lower edge, columns go right.
        let labelSpacing = (lines.compactMap { $0.labelBand == nil ? nil : $0.labelWidth }.max() ?? 0) + spacingPad
        let xs = lines.indices.map { i -> CGFloat in
            let band = lines[i].band
            let anchor = onRight ? band.lowerBound : band.upperBound
            guard count > 1 else { return anchor }
            let step = min(labelSpacing, (band.upperBound - band.lowerBound) / CGFloat(count - 1))
            return anchor + (onRight ? 1 : -1) * CGFloat(columns[i]) * step
        }

        // Largest uniform scale (≤ 1) at which no two drawn numbers overlap.
        var scale: CGFloat = 1
        for i in lines.indices {
            guard let a = lines[i].labelBand else { continue }
            for j in (i + 1)..<lines.count {
                guard let b = lines[j].labelBand else { continue }
                guard a.lowerBound < b.upperBound, b.lowerBound < a.upperBound else { continue }
                let dx = abs(xs[i] - xs[j])
                let needed = (lines[i].labelWidth + lines[j].labelWidth) / 2
                guard needed > 0, dx < needed + labelGap else { continue }
                scale = min(scale, max(0, dx - labelGap) / needed)
            }
        }
        scale = max(minScale, min(1, scale))

        return lines.indices.map { Placed(x: xs[$0], scale: scale) }
    }
}
