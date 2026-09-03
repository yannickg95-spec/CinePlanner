//
//  CoverageLineLayoutTests.swift
//  CinePlannerTests
//
//  CoverageLineLayout decides where every coverage bar sits and how large the
//  shot numbers may be, for the script editor, the on-screen viewer, the PDF
//  export and the web export alike. It is pure geometry, so it can be pinned
//  down exactly — which matters, because a regression here is invisible until
//  someone opens an export.
//

import XCTest
import CoreGraphics
@testable import CinePlanner

final class CoverageLineLayoutTests: XCTestCase {

    /// A line spanning `top...bottom`, with a shot number `width` wide sitting
    /// just above it (the y-down convention the viewer uses).
    private func line(_ top: CGFloat, _ bottom: CGFloat,
                      width: CGFloat = 14,
                      band: ClosedRange<CGFloat> = 0...120,
                      labelled: Bool = true) -> CoverageLineLayout.Line {
        CoverageLineLayout.Line(
            extent: top...bottom,
            band: band,
            labelWidth: width,
            labelBand: labelled ? (top - 15)...(top - 2) : nil)
    }

    // MARK: - Shape of the result

    func testEmptyInputProducesNoPlacements() {
        XCTAssertTrue(CoverageLineLayout.solve([]).isEmpty)
    }

    func testResultIsParallelToInput() {
        let placed = CoverageLineLayout.solve([line(0, 50), line(60, 90), line(70, 120)])
        XCTAssertEqual(placed.count, 3)
    }

    func testEveryLineSharesOneScale() {
        let placed = CoverageLineLayout.solve([line(0, 100), line(10, 110), line(20, 120)])
        XCTAssertEqual(Set(placed.map(\.scale)).count, 1,
                       "The numbers shrink together, so one scale applies to all of them.")
    }

    // MARK: - Column packing

    func testLoneLineSitsAgainstTheTextEdge() {
        let placed = CoverageLineLayout.solve([line(0, 50, band: 10...90)])
        XCTAssertEqual(placed[0].x, 90, "Column 0 is the band's upper bound — nearest the text.")
        XCTAssertEqual(placed[0].scale, 1, "Nothing to collide with, so the number stays full size.")
    }

    func testLinesThatDoNotOverlapReuseAColumn() {
        // Second line starts below where the first ends.
        let placed = CoverageLineLayout.solve([line(0, 50), line(50, 100)])
        XCTAssertEqual(placed[0].x, placed[1].x,
                       "Disjoint bars can share a column, keeping them near the text.")
        XCTAssertEqual(placed[0].scale, 1)
    }

    func testOverlappingLinesGetSeparateColumns() {
        let placed = CoverageLineLayout.solve([line(0, 100), line(50, 150)])
        XCTAssertNotEqual(placed[0].x, placed[1].x)
    }

    func testColumnsArePackedNotSpreadWhenThereIsRoom() {
        // A wide band could spread these to opposite edges; it must not.
        let placed = CoverageLineLayout.solve([line(0, 100, width: 14, band: 0...500),
                                               line(50, 150, width: 14, band: 0...500)])
        XCTAssertEqual(abs(placed[0].x - placed[1].x), 14 + 4, accuracy: 0.001,
                       "Spacing is the widest number plus spacingPad — no wider.")
    }

    func testAChainOfOverlapsStillUsesOnlyTwoColumns() {
        // A overlaps B, B overlaps C, but A and C are disjoint.
        let placed = CoverageLineLayout.solve([line(0, 60), line(50, 110), line(100, 160)])
        XCTAssertEqual(placed[0].x, placed[2].x, "A and C don't overlap, so they share a column.")
        XCTAssertNotEqual(placed[0].x, placed[1].x)
        XCTAssertEqual(placed[0].scale, 1, "Two columns a full label apart need no shrinking.")
    }

    func testColumnCountFollowsPeakDensityNotTotalCount() {
        // Six bars, but never more than two overlap at once.
        let lines = [line(0, 40), line(30, 70), line(60, 100),
                     line(90, 130), line(120, 160), line(150, 190)]
        let xs = Set(CoverageLineLayout.solve(lines).map(\.x))
        XCTAssertEqual(xs.count, 2, "Peak concurrency is two, so two columns suffice.")
    }

    // MARK: - Falling back to a spread when packing won't fit

    func testANarrowBandSpreadsColumnsAcrossItAndShrinksTheNumbers() {
        // Three mutually overlapping lines in a band far too narrow to pack them.
        let band: ClosedRange<CGFloat> = 0...20
        let placed = CoverageLineLayout.solve([line(0, 100, width: 14, band: band),
                                               line(10, 110, width: 14, band: band),
                                               line(20, 120, width: 14, band: band)])
        let xs = placed.map(\.x).sorted()
        XCTAssertEqual(xs.first!, band.lowerBound, accuracy: 0.001)
        XCTAssertEqual(xs.last!, band.upperBound, accuracy: 0.001, "Forced to use the whole band.")
        XCTAssertLessThan(placed[0].scale, 1, "Numbers give way once the lines cannot.")
    }

    func testScaleNeverFallsBelowTheFloor() {
        let band: ClosedRange<CGFloat> = 0...4
        let lines = (0..<8).map { line(CGFloat($0), 200, width: 30, band: band) }
        let scale = CoverageLineLayout.solve(lines, minScale: 0.4)[0].scale
        XCTAssertEqual(scale, 0.4, accuracy: 0.001,
                       "Unreadably small is worse than slightly overlapping.")
    }

    func testScaleNeverExceedsOne() {
        // Enormous band, tiny numbers — no reason to grow them.
        let placed = CoverageLineLayout.solve([line(0, 100, width: 2, band: 0...9000),
                                               line(10, 110, width: 2, band: 0...9000)])
        XCTAssertEqual(placed[0].scale, 1)
    }

    // MARK: - Unlabelled lines

    func testLinesWithoutANumberDoNotForceOthersToShrink() {
        // Narrow enough that two 14pt numbers genuinely collide (12 < 14 + 2).
        let band: ClosedRange<CGFloat> = 0...12
        let withLabels = CoverageLineLayout.solve([line(0, 100, band: band),
                                                   line(10, 110, band: band)])
        let oneUnlabelled = CoverageLineLayout.solve([line(0, 100, band: band),
                                                      line(10, 110, band: band, labelled: false)])
        XCTAssertLessThan(withLabels[0].scale, 1)
        XCTAssertEqual(oneUnlabelled[0].scale, 1,
                       "A continuation bar draws no number, so it can't collide with one.")
    }

    func testUnlabelledLinesStillGetTheirOwnColumn() {
        let placed = CoverageLineLayout.solve([line(0, 100), line(50, 150, labelled: false)])
        XCTAssertNotEqual(placed[0].x, placed[1].x, "Bars must not be drawn on top of each other.")
    }

    // MARK: - The promise the algorithm makes

    func testNumbersNeverOverlapAcrossManyRandomLayouts() {
        var seed: UInt64 = 20260903
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }

        let labelGap: CGFloat = 2, minScale: CGFloat = 0.4
        for _ in 0..<500 {
            let lower = CGFloat(rnd(10))
            let band = lower...(lower + CGFloat(15 + rnd(150)))
            let lines = (0..<(1 + rnd(8))).map { _ -> CoverageLineLayout.Line in
                let top = CGFloat(rnd(600))
                return line(top, top + CGFloat(5 + rnd(180)),
                            width: CGFloat(6 + rnd(22)), band: band)
            }
            let placed = CoverageLineLayout.solve(lines, labelGap: labelGap, minScale: minScale)
            let scale = placed[0].scale

            for i in lines.indices {
                for j in (i + 1)..<lines.count {
                    guard let a = lines[i].labelBand, let b = lines[j].labelBand,
                          a.lowerBound < b.upperBound, b.lowerBound < a.upperBound else { continue }
                    let dx = abs(placed[i].x - placed[j].x)
                    let needed = (lines[i].labelWidth + lines[j].labelWidth) / 2 * scale
                    // Either they clear each other, or the scale floor stopped us
                    // from shrinking any further — the one accepted compromise.
                    XCTAssertTrue(dx + 0.001 >= needed + labelGap || scale == minScale,
                                  "Numbers overlap without the floor being reached: dx=\(dx) needed=\(needed)")
                }
            }
        }
    }

    func testEveryLineStaysInsideItsBand() {
        var seed: UInt64 = 77
        func rnd(_ n: Int) -> Int {
            seed = seed &* 2862933555777941757 &+ 3037000493
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<300 {
            let lower = CGFloat(rnd(20))
            let band = lower...(lower + CGFloat(10 + rnd(200)))
            let lines = (0..<(1 + rnd(7))).map { _ -> CoverageLineLayout.Line in
                let top = CGFloat(rnd(400))
                return line(top, top + CGFloat(5 + rnd(150)), width: CGFloat(6 + rnd(20)), band: band)
            }
            for placed in CoverageLineLayout.solve(lines) {
                XCTAssertGreaterThanOrEqual(placed.x, band.lowerBound - 0.001)
                XCTAssertLessThanOrEqual(placed.x, band.upperBound + 0.001)
            }
        }
    }
}
