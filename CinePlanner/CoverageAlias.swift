//
//  CoverageAlias.swift
//  CinePlanner
//
//  When a shot's coverage marking runs past its own scene into a later scene's
//  script region, the shot appears as a read-only alias in that scene's shot list
//  (editor and exports). This works out which scenes a shot's coverage reaches.
//
//  The scenes' script regions are found by parsing the PDF for their headings
//  (page + heading Y), the same way the viewers align to a scene. It runs while a
//  coverage marking is being saved — the one moment the document is laid out — and
//  the result is stored on the shot, so nothing here is needed again at display or
//  export time. Shared by the iPad (UIKit) and Mac (AppKit) marking paths.
//

import Foundation
import CoreGraphics
import PDFKit

enum CoverageAlias {
    /// The uids of scenes — other than the shot's own — whose script region the
    /// shot's coverage runs into. Empty when the coverage stays within its scene.
    static func overlappedSceneUIDs(for shot: Shot, in document: PDFDocument) -> [String] {
        guard let ownScene = shot.scene,
              let selections = shot.scriptCoverageSelections, !selections.isEmpty else { return [] }
        let scenes = ownScene.scriptVersion?.orderedScenes
            ?? ownScene.project?.scenes.sorted { $0.sortOrder < $1.sortOrder }
            ?? []

        // An order key that grows down the script: the page dominates; within a
        // page a lower y-up (further down) is later, so subtract the heading's top.
        func key(page: Int, yTop: CGFloat) -> Double { Double(page) * 100_000 - Double(yTop) }

        let anchors: [(uid: String, key: Double)] = scenes.map { scene in
            let y = headingTopY(for: scene, in: document, among: scenes) ?? CGFloat(100_000)
            return (scene.uid, key(page: scene.absolutePDFPage, yTop: y))
        }.sorted { $0.key < $1.key }

        func sceneUID(page: Int, yTop: CGFloat) -> String? {
            let k = key(page: page, yTop: yTop)
            var found: String?
            for a in anchors where a.key <= k + 0.5 { found = a.uid }
            return found
        }

        var overlapped = Set<String>()
        for selection in selections {
            for range in selection.pageRanges {
                for bounds in range.selections {
                    if let uid = sceneUID(page: range.pageIndex, yTop: bounds.cgRect.maxY),
                       uid != ownScene.uid {
                        overlapped.insert(uid)
                    }
                }
            }
        }
        return Array(overlapped)
    }

    /// The top Y (page coords, y-up) of `scene`'s heading on its page, or nil.
    /// Mirrors the viewers' own heading lookup so anchors line up with the image.
    private static func headingTopY(for scene: Scene, in document: PDFDocument,
                                    among scenes: [Scene]) -> CGFloat? {
        let targetPage = scene.absolutePDFPage
        guard targetPage >= 0, targetPage < document.pageCount,
              let page = document.page(at: targetPage) else { return nil }
        let scenesOnPage = scenes.filter { $0.absolutePDFPage == targetPage }
        let occurrence = scenesOnPage.firstIndex { $0 === scene } ?? 0
        let location = scene.nickname.trimmingCharacters(in: .whitespaces).uppercased()

        guard let whole = page.selection(for: page.bounds(for: .mediaBox)) else { return nil }
        var headings: [(location: String, top: CGFloat)] = []
        for line in whole.selectionsByLine() {
            guard let raw = line.string?.trimmingCharacters(in: .whitespaces),
                  isHeadingLine(raw) else { continue }
            let parsed = ScreenplayParser.headingLocation(of: raw) ?? raw
            headings.append((parsed.trimmingCharacters(in: .whitespaces).uppercased(),
                             line.bounds(for: page).maxY))
        }
        guard !headings.isEmpty else { return nil }
        let positional = headings[min(occurrence, headings.count - 1)]
        if location.isEmpty || positional.location == location { return positional.top }
        let named = headings.filter { $0.location == location }
        guard !named.isEmpty else { return positional.top }
        let sameLocation = scenesOnPage.filter {
            $0.nickname.trimmingCharacters(in: .whitespaces).uppercased() == location
        }
        let index = sameLocation.firstIndex { $0 === scene } ?? 0
        return named[min(index, named.count - 1)].top
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        line.uppercased().range(of: "(?<![A-Z])(INT|EXT|I/E)(?![A-Z])",
                                options: .regularExpression) != nil
    }
}
