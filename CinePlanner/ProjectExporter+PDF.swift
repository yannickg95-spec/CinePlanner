//
//  ProjectExporter+PDF.swift
//  CinePlanner
//
//  The PDF exports: the shot-list document, and the script with coverage lines
//  burned into it.
//
//  Split out of ProjectExporter.swift, which had grown past 2,900 lines with
//  four unrelated export formats in it. Same type, same behaviour — an extension
//  in its own file, so each format can be read on its own.
//

import Foundation
import SwiftUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import os

extension ProjectExporter {
    // MARK: - Helper Functions

    /// Whether coverage lines are drawn down the right margin for this version.
    var coverageOnRight: Bool { version?.coverageLinesOnRight ?? false }

    /// The x-range the coverage lines occupy, measured from the near-text edge of
    /// the chosen margin: left band [pageEdge ... pageWidth×fraction], or its mirror
    /// on the right. `CoverageLineLayout.solve(onRight:)` anchors at the near-text
    /// end (upper for left, lower for right).
    func exportLineRange(for pageRect: CGRect) -> ClosedRange<CGFloat> {
        let inset: CGFloat = 6
        let marginFraction = CGFloat(version?.coverageLineMargin ?? 0.15)
        let span = pageRect.width * marginFraction
        if coverageOnRight {
            let lowerBound = pageRect.maxX - span            // near the text
            let upperBound = max(lowerBound, pageRect.maxX - inset)
            return lowerBound...upperBound
        } else {
            let upperBound = min(pageRect.maxX - inset, pageRect.minX + span)   // near the text
            let lowerBound = min(pageRect.minX, upperBound)
            return lowerBound...upperBound
        }
    }

    
    func createScriptWithCoverage() -> Data? {
        var result: Data?
        PlatformAppearance.performLight {
            result = buildScriptWithCoverage()
        }
        return result
    }

    private func buildScriptWithCoverage() -> Data? {
        Log.export.debug("🔵 [SCRIPT_COVERAGE] Creating script with burned-in coverage")
        
        // Check if script PDF exists
        guard let scriptPDFData = (version?.pdfData ?? project.scriptPDFData),
              let sourcePDF = PDFDocument(data: scriptPDFData) else {
            Log.export.error("❌ [SCRIPT_COVERAGE] No script PDF found")
            return nil
        }
        
        Log.export.debug("✅ [SCRIPT_COVERAGE] Loaded script PDF with \(sourcePDF.pageCount) pages")
        
        // Create a new PDF document
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else {
            Log.export.error("❌ [SCRIPT_COVERAGE] Failed to create data consumer")
            return nil
        }
        
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // Default US Letter
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            Log.export.error("❌ [SCRIPT_COVERAGE] Failed to create PDF context")
            return nil
        }
        
        // Collect all coverage selections organized by page
        var coverageByPage: [Int: [(shot: Shot, selection: ScriptTextSelection)]] = [:]
        
        Log.export.debug("📋 [EXPORT COLOR] Collecting coverage from all scenes and shots...")
        for scene in exportScenes {
            Log.export.debug("   🎬 Scene \(scene.sceneNumber)\(scene.suffix): \(scene.shots.count) shots")
            for (shotIndex, shot) in scene.shots.enumerated() {
                guard let selections = shot.scriptCoverageSelections else { continue }
                
                Log.export.debug("      📸 Shot \(shot.displayNumber) (index \(shotIndex)): \(selections.count) selection(s)")
                
                for selection in selections {
                    for pageRange in selection.pageRanges {
                        let pageIndex = pageRange.pageIndex
                        if coverageByPage[pageIndex] == nil {
                            coverageByPage[pageIndex] = []
                        }
                        coverageByPage[pageIndex]?.append((shot: shot, selection: selection))
                        Log.export.debug("         - Added to page \(pageIndex)")
                    }
                }
            }
        }
        
        Log.export.debug("📋 [SCRIPT_COVERAGE] Found coverage on \(coverageByPage.keys.count) pages")
        
        // Use the same color scheme as the editor tab
        // A shot's colour follows the project's palette and distribution setting,
        // resolved once here so the burned-in PDF matches the editor exactly.
        let coloring = CoverageColoring(version: version, project: project)
        Log.export.debug("Coverage colours: \(project.coveragePalette.rawValue, privacy: .public) palette, \(project.coverageColorMode.rawValue, privacy: .public) distribution")

        // Process each page
        for pageIndex in 0..<sourcePDF.pageCount {
            guard let page = sourcePDF.page(at: pageIndex) else { continue }
            
            let pageRect = page.bounds(for: .cropBox)
            
            context.beginPDFPage(nil)

            // Route text/bezier drawing into this PDF context (y-up like the page).
            PlatformGraphics.pushContext(context, flipped: false)

            // Draw the original page using PDFPage's draw method
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            
            // Draw coverage lines if any exist on this page
            if let coverages = coverageByPage[pageIndex] {
                Log.export.debug("📝 [SCRIPT_COVERAGE] Drawing \(coverages.count) coverage item(s) on page \(pageIndex + 1)")

                // Gather this page's bars, then pack them by density and share one
                // label scale — identical to the editor overlay, the on-screen viewer
                // and the web-export images (see CoverageLineLayout). The page context
                // is y-up, so a bar's top is its larger Y (maxY).
                struct Bar {
                    let color: PlatformColor
                    let label: String
                    let minY: CGFloat        // extended to page edges for continuations
                    let maxY: CGFloat
                    let labelTopY: CGFloat   // the true selection top; nil label when not drawn here
                    let labelWidth: CGFloat
                    let labelHeight: CGFloat
                    let drawsLabel: Bool
                }
                let baseFont = PlatformFont.systemFont(ofSize: 9)
                var bars: [Bar] = []
                for (shot, selection) in coverages {
                    guard let pageRange = selection.pageRanges.first(where: { $0.pageIndex == pageIndex }),
                          let firstSelection = pageRange.selections.first else { continue }

                    var minY = firstSelection.cgRect.minY
                    var maxY = firstSelection.cgRect.maxY
                    for bounds in pageRange.selections {
                        minY = min(minY, bounds.cgRect.minY)
                        maxY = max(maxY, bounds.cgRect.maxY)
                    }
                    let labelTopY = maxY   // the real selection top, before any page-edge extension

                    let allPageIndices = selection.pageRanges.map { $0.pageIndex }.sorted()
                    let isMultiPage = allPageIndices.count > 1
                    let isFirstPage = pageIndex == allPageIndices.first
                    let isLastPage = pageIndex == allPageIndices.last
                    if isMultiPage {
                        if !isFirstPage { maxY = pageRect.maxY }   // continues from above
                        if !isLastPage { minY = pageRect.minY }    // continues below
                    }

                    let ls = NSAttributedString(string: shot.displayNumber, attributes: [.font: baseFont]).size()
                    bars.append(Bar(color: coloring.color(for: shot),
                                    label: shot.displayNumber, minY: minY, maxY: maxY,
                                    labelTopY: labelTopY, labelWidth: ls.width, labelHeight: ls.height,
                                    drawsLabel: isFirstPage || !isMultiPage))
                }

                let pageBand = exportLineRange(for: pageRect)
                let lines: [CoverageLineLayout.Line] = bars.map { bar in
                    CoverageLineLayout.Line(
                        extent: bar.minY...bar.maxY,
                        band: pageBand,
                        labelWidth: bar.labelWidth,
                        labelBand: bar.drawsLabel ? (bar.labelTopY + 4)...(bar.labelTopY + 4 + bar.labelHeight) : nil)
                }
                let placements = CoverageLineLayout.solve(lines, onRight: coverageOnRight)

                for (bar, placed) in zip(bars, placements) {
                    let x = placed.x
                    context.setStrokeColor(bar.color.cgColor)
                    context.setLineWidth(max(1, 3 * placed.scale))
                    context.move(to: CGPoint(x: x, y: bar.minY))
                    context.addLine(to: CGPoint(x: x, y: bar.maxY))
                    context.strokePath()

                    guard bar.drawsLabel else { continue }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: PlatformFont.systemFont(ofSize: 9 * placed.scale),
                        .foregroundColor: bar.color
                    ]
                    let attrString = NSAttributedString(string: bar.label, attributes: attrs)
                    let size = attrString.size()
                    var labelX = x - size.width / 2
                    labelX = min(max(labelX, pageRect.minX + 6), max(pageRect.minX + 6, pageRect.maxX - 6 - size.width))
                    let labelRect = CGRect(x: labelX, y: bar.labelTopY + 4, width: size.width, height: size.height)

                    // The page context is y-up (flipped: false). AppKit text draws
                    // upright; UIKit text would be mirrored (the number upside down),
                    // so on iOS flip locally about the label box.
                    #if canImport(UIKit)
                    context.saveGState()
                    context.translateBy(x: 0, y: labelRect.minY + labelRect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    attrString.draw(at: CGPoint(x: labelRect.minX, y: labelRect.minY))
                    context.restoreGState()
                    #else
                    attrString.draw(at: CGPoint(x: labelRect.minX, y: labelRect.minY))
                    #endif
                }
            }

            PlatformGraphics.popContext()
            context.endPDFPage()
        }

        context.closePDF()

        Log.export.debug("✅ [SCRIPT_COVERAGE] Script with coverage created successfully")
        return outputData as Data
    }
    
    /// A PDF is always drawn on white paper, but PlatformColor.platformLabel and friends are
    /// dynamic: in dark mode they resolve to white, producing a page of invisible
    /// text. Drawing inside the light appearance pins every system colour to its
    /// light-mode value.
    func createPDFData(from text: String) -> Data? {
        var result: Data?
        PlatformAppearance.performLight {
            result = buildPDFData(from: text)
        }
        return result
    }

    private func buildPDFData(from text: String) -> Data? {
        // Page size (US Letter).
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 36
        let textWidth = pageWidth - (margin * 2)
        let bottomLimit = pageHeight - margin
        let headerHeight: CGFloat = 34
        // The scene map always takes its own page, so with it on scenes always start
        // fresh; otherwise honour the user's layout choice.
        let newPagePerScene = pdfOptions.includeSceneMap || pdfOptions.startEachSceneOnNewPage
        let orderedScenes = pdfExportScenes
        let dayMode = pdfOptions.groupByShootingDay && !(version?.orderedShootingDays.isEmpty ?? true)

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        // Scene maps are expensive to render; cache so both passes share them.
        var mapCache: [ObjectIdentifier: CoverageImage?] = [:]
        func cachedMap(_ scene: Scene) -> CoverageImage? {
            let key = ObjectIdentifier(scene)
            if let cached = mapCache[key] { return cached }
            let rendered = renderSceneMap(scene: scene)
            mapCache[key] = rendered
            return rendered
        }

        // Renders the document into `pdfContext`. In day mode it stamps a
        // "Day N · Page X of Y" header at the top-right of each day page, where the
        // totals come from `headerCounts` (nil on the first, counting pass). Returns
        // the per-day page counts it observed.
        func render(into pdfContext: CGContext, headerCounts: [Int: Int]?) -> [Int: Int] {
            var yPosition: CGFloat = 0
            var pageOpen = false
            var dayPageCounts: [Int: Int] = [:]
            var currentDayIndex: Int?
            var pageInDay = 0

            func drawCornerHeader() {
                guard let di = currentDayIndex, let total = headerCounts?[di] else { return }
                let str = "Day \(di + 1) · Page \(pageInDay) of \(total)"
                let attr: [NSAttributedString.Key: Any] = [
                    .font: PlatformFont.systemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: PlatformColor(white: 0.5, alpha: 1)
                ]
                let w = (str as NSString).size(withAttributes: attr).width
                (str as NSString).draw(at: CGPoint(x: pageWidth - margin - w, y: 16), withAttributes: attr)
            }

            func beginContentPage() {
                pdfContext.beginPDFPage(nil)
                pdfContext.saveGState()
                pdfContext.translateBy(x: 0, y: pageHeight)
                pdfContext.scaleBy(x: 1.0, y: -1.0)
                PlatformGraphics.pushContext(pdfContext)
                yPosition = margin
                pageOpen = true
                if let di = currentDayIndex {
                    pageInDay += 1
                    dayPageCounts[di] = pageInDay
                    drawCornerHeader()
                }
            }
            func endContentPage() {
                if pageOpen {
                    PlatformGraphics.popContext()
                    pdfContext.restoreGState(); pdfContext.endPDFPage(); pageOpen = false
                }
            }

            // PAGE 1: project info + statistics (never carries a day header).
            pdfContext.beginPDFPage(nil)
            pdfContext.saveGState()
            pdfContext.translateBy(x: 0, y: pageHeight)
            pdfContext.scaleBy(x: 1.0, y: -1.0)
            PlatformGraphics.pushContext(pdfContext)
            drawFirstPage(in: pdfContext, pageWidth: pageWidth, pageHeight: pageHeight, margin: margin, textWidth: textWidth)
            PlatformGraphics.popContext()
            pdfContext.restoreGState()
            pdfContext.endPDFPage()

            // Draws one scene: header, shot list, reference gallery, scene-map page.
            // `scheduledShotUIDs` is nil for a whole scene; when set (a split scene on
            // a shooting day) the shots outside it are shown greyed as "not scheduled".
            func drawScene(_ scene: Scene, scheduledShotUIDs: Set<String>?, newPage: Bool) {
                let orderedShots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
                func offDay(_ shot: Shot) -> Bool {
                    guard let ids = scheduledShotUIDs else { return false }
                    return !ids.contains(shot.uid)
                }

                if newPage {
                    endContentPage(); beginContentPage()
                } else {
                    // Continuous flow: fill the page, break only when the header plus
                    // its first shot won't fit; a small gap separates scenes.
                    let firstRowHeight = orderedShots.first.map { pdfShotRowHeight($0, textWidth: textWidth, offDay: offDay($0)) } ?? 30
                    let needed = headerHeight + min(firstRowHeight, pageHeight - margin * 2 - headerHeight)
                    if !pageOpen || yPosition + needed > bottomLimit {
                        endContentPage(); beginContentPage()
                    } else {
                        yPosition += 14
                    }
                }
                yPosition = drawSceneHeaderRow(scene, in: pdfContext, at: yPosition, margin: margin, pageWidth: pageWidth)

                // 0) Read-only aliases first: shots from earlier scenes whose
                // coverage runs into this one. A compact dimmed line each — edited in
                // their own scene, so no full row.
                let aliasShots = scene.coverageAliasShots
                if !aliasShots.isEmpty {
                    for shot in aliasShots {
                        let rowH: CGFloat = 18
                        if yPosition + rowH > bottomLimit {
                            endContentPage(); beginContentPage()
                            yPosition = drawSceneContinuationHeader(scene, in: pdfContext, at: yPosition, margin: margin, pageWidth: pageWidth)
                        }
                        let home = shot.scene
                        let note = home.map { " — continues from Scene \($0.sceneNumber)\($0.suffix)" } ?? ""
                        NSAttributedString(string: "↳ Shot \(shot.displayNumber)\(note)",
                                           attributes: [.font: PlatformFont.systemFont(ofSize: 10),
                                                        .foregroundColor: PlatformColor(white: 0.5, alpha: 1)])
                            .draw(at: CGPoint(x: margin, y: yPosition))
                        yPosition += rowH
                    }
                    yPosition += 6
                }

                // 1) Shot list.
                if orderedShots.isEmpty {
                    NSAttributedString(string: "No shots in this scene.",
                                       attributes: [.font: PlatformFont.systemFont(ofSize: 10), .foregroundColor: PlatformColor(white: 0.5, alpha: 1)])
                        .draw(at: CGPoint(x: margin, y: yPosition))
                    yPosition += 18
                } else {
                    for shot in orderedShots {
                        let dim = offDay(shot)
                        let h = pdfShotRowHeight(shot, textWidth: textWidth, offDay: dim)
                        if yPosition + h > bottomLimit {
                            endContentPage(); beginContentPage()
                            yPosition = drawSceneContinuationHeader(scene, in: pdfContext, at: yPosition, margin: margin, pageWidth: pageWidth)
                        }
                        yPosition = drawShotRow(shot, in: pdfContext, at: yPosition, margin: margin, textWidth: textWidth, offDay: dim)
                    }
                }

                // 2) Reference gallery (only the day's shots for a split scene).
                let items = pdfOptions.includeReferenceImages ? pdfGalleryItems(for: scene, onlyShotUIDs: scheduledShotUIDs) : []
                if !items.isEmpty {
                    let cols = 3
                    let gap: CGFloat = 12
                    let thumbW = (textWidth - gap * CGFloat(cols - 1)) / CGFloat(cols)
                    let thumbH = thumbW * 0.66
                    let rowH = thumbH + 12 + 10          // image + caption + gap
                    let headingH: CGFloat = 22

                    if yPosition + headingH + rowH > bottomLimit {
                        endContentPage(); beginContentPage()
                        yPosition = drawSceneContinuationHeader(scene, in: pdfContext, at: yPosition, margin: margin, pageWidth: pageWidth)
                    } else {
                        yPosition += 8
                    }
                    NSAttributedString(string: "References",
                                       attributes: [.font: PlatformFont.boldSystemFont(ofSize: 10), .foregroundColor: PlatformColor(white: 0.42, alpha: 1)])
                        .draw(at: CGPoint(x: margin, y: yPosition))
                    yPosition += headingH

                    var col = 0
                    for item in items {
                        if col == 0 && yPosition + rowH > bottomLimit {
                            endContentPage(); beginContentPage()
                        }
                        let x = margin + CGFloat(col) * (thumbW + gap)
                        drawPDFThumb(item.data, caption: item.caption, in: pdfContext,
                                     box: CGRect(x: x, y: yPosition, width: thumbW, height: thumbH))
                        col += 1
                        if col == cols { col = 0; yPosition += rowH }
                    }
                    if col != 0 { yPosition += rowH }
                }

                // 3) The scene map on its own page, as large as possible.
                if pdfOptions.includeSceneMap, let map = cachedMap(scene) {
                    endContentPage(); beginContentPage()
                    let title = "Scene \(scene.sceneNumber)\(scene.suffix) — Scene Map"
                    NSAttributedString(string: title,
                                       attributes: [.font: PlatformFont.boldSystemFont(ofSize: 12), .foregroundColor: PlatformColor.black])
                        .draw(at: CGPoint(x: margin, y: yPosition))
                    yPosition += 24
                    drawPDFImageFit(map.data, in: pdfContext,
                                    box: CGRect(x: margin, y: yPosition, width: textWidth, height: bottomLimit - yPosition),
                                    border: true)
                    yPosition = bottomLimit    // nothing else shares the map page
                }
            }

            if dayMode, let days = version?.orderedShootingDays {
                // Day-ordered (mirrors the web export): scenes grouped under each day,
                // a split scene shown whole with its off-day shots greyed out.
                for (dayIdx, day) in days.enumerated() {
                    let entries = day.orderedEntries.filter { entry in
                        guard let scene = entry.scene else { return false }
                        return pdfOptions.includesScene(scene)
                    }
                    guard !entries.isEmpty else { continue }
                    currentDayIndex = dayIdx
                    pageInDay = 0
                    endContentPage(); beginContentPage()
                    let setups = entries.count
                    let shots = entries.reduce(0) { $0 + $1.resolvedShots.count }
                    yPosition = drawDayHeader(day, setups: setups, shots: shots, in: pdfContext,
                                              at: yPosition, margin: margin, pageWidth: pageWidth, textWidth: textWidth)
                    for entry in entries {
                        guard let scene = entry.scene else { continue }
                        let scheduled: Set<String>? = entry.selectedShotUIDs.isEmpty ? nil : Set(entry.resolvedShots.map { $0.uid })
                        drawScene(scene, scheduledShotUIDs: scheduled, newPage: false)
                    }
                }
                currentDayIndex = nil
            } else {
                for scene in orderedScenes {
                    drawScene(scene, scheduledShotUIDs: nil, newPage: newPagePerScene)
                }
            }
            endContentPage()
            return dayPageCounts
        }

        // Day mode needs each day's total page count for the header, so run a
        // throwaway counting pass first.
        var counts: [Int: Int] = [:]
        if dayMode {
            let tmp = NSMutableData()
            if let consumer = CGDataConsumer(data: tmp as CFMutableData),
               let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) {
                counts = render(into: ctx, headerCounts: nil)
                ctx.closePDF()
            }
        }

        // Real pass.
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }
        _ = render(into: pdfContext, headerCounts: dayMode ? counts : nil)
        pdfContext.closePDF()
        return pdfData as Data
    }
    
    private func drawFirstPage(in context: CGContext, pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat, textWidth: CGFloat) {
        var yPosition: CGFloat = margin

        // "Made with CinePlanner" badge, top-right (first page only).
        let badge: CGFloat = 22
        let logoX = pageWidth - margin - badge
        let logoY = margin
        let logoRect = CGRect(x: logoX, y: logoY, width: badge, height: badge)
        PlatformColor(white: 1, alpha: 1).setFill()
        PlatformBezierPath.rounded(logoRect, radius: 5).fill()
        PlatformColor(white: 0.82, alpha: 1).setStroke()
        let ring = PlatformBezierPath.rounded(logoRect, radius: 5); ring.lineWidth = 0.5; ring.stroke()
        let s = badge / 100.0
        PlatformColor(red: 0.16, green: 0.42, blue: 1.0, alpha: 1).setFill()
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (11.6, 15.6, 76.4, 12.2), (11.6, 34.1, 61.9, 12.2),
            (11.6, 52.6, 70.3, 12.2), (11.6, 71.1, 48.1, 12.2)
        ]
        for b in bars {
            let r = CGRect(x: logoX + b.0 * s, y: logoY + b.1 * s, width: b.2 * s, height: b.3 * s)
            PlatformBezierPath.rounded(r, radius: b.3 * s / 2).fill()
        }
        let reg: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: PlatformColor(white: 0.45, alpha: 1)]
        let bold: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: PlatformColor(white: 0.2, alpha: 1)]
        let t1 = "Made with " as NSString
        let t2 = "CinePlanner" as NSString
        let w1 = t1.size(withAttributes: reg).width
        let w2 = t2.size(withAttributes: bold).width
        let textStartX = logoX - 8 - (w1 + w2)
        let ty = logoY + (badge - 11) / 2
        t1.draw(at: CGPoint(x: textStartX, y: ty), withAttributes: reg)
        t2.draw(at: CGPoint(x: textStartX + w1, y: ty), withAttributes: bold)

        // Title
        let titleFont = PlatformFont.boldSystemFont(ofSize: 24)
        let titleText = "\(project.filmName.uppercased())\nSHOT LIST"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: PlatformColor.platformLabel
        ]
        let titleAttrString = NSAttributedString(string: titleText, attributes: titleAttributes)
        let titleRect = CGRect(x: margin, y: yPosition, width: textWidth, height: 100)
        titleAttrString.draw(in: titleRect)
        yPosition += 80
        
        // Separator line
        context.setStrokeColor(PlatformColor.gray.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: margin, y: yPosition))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
        context.strokePath()
        yPosition += 20
        
        // Project Information Section
        let sectionFont = PlatformFont.boldSystemFont(ofSize: 14)
        let bodyFont = PlatformFont.systemFont(ofSize: 11)
        
        let sectionTitle = "PROJECT INFORMATION"
        let sectionAttr: [NSAttributedString.Key: Any] = [.font: sectionFont, .foregroundColor: PlatformColor.platformLabel]
        NSAttributedString(string: sectionTitle, attributes: sectionAttr).draw(at: CGPoint(x: margin, y: yPosition))
        yPosition += 25
        
        // Label/value rows; values all start at the same column so they line up.
        var rows: [(String, String)] = [("Project", project.filmName)]
        func addCredit(_ label: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { rows.append((label, v)) }
        }
        addCredit("Production Company", project.productionCompany)
        addCredit("Director", project.director)
        addCredit("Cinematographer", project.cinematographer)
        rows.append(("Total Scenes", "\(exportScenes.count)"))
        rows.append(("Total Shots", "\(exportScenes.reduce(0) { $0 + $1.shots.count })"))

        let labelAttr: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: PlatformColor(white: 0.45, alpha: 1)]
        let valueAttr: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: PlatformColor.platformLabel]
        let valueX = margin + 150
        for (label, value) in rows {
            NSAttributedString(string: label, attributes: labelAttr).draw(at: CGPoint(x: margin, y: yPosition))
            NSAttributedString(string: value, attributes: valueAttr).draw(at: CGPoint(x: valueX, y: yPosition))
            yPosition += 18
        }
    }
    
    // Chip colours mirror the web export: neutral INT/EXT, blue DAY, orange
    // NIGHT. The text label lives inside each chip, so it still reads in B&W.
    private static let pdfChipNeutral = (fill: PlatformColor(white: 0.90, alpha: 1), text: PlatformColor(white: 0.30, alpha: 1))
    private static let pdfChipDay = (fill: PlatformColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1), text: PlatformColor(red: 0.0, green: 0.40, blue: 0.85, alpha: 1))
    private static let pdfChipNight = (fill: PlatformColor(red: 1.0, green: 0.90, blue: 0.76, alpha: 1), text: PlatformColor(red: 0.70, green: 0.42, blue: 0.0, alpha: 1))

    /// Draws a small rounded chip (INT/EXT/DAY/NIGHT). Returns the x just past it.
    @discardableResult
    private func drawPDFChip(_ text: String, fill: PlatformColor, textColor: PlatformColor,
                             at point: CGPoint) -> CGFloat {
        let font = PlatformFont.boldSystemFont(ofSize: 8)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let padX: CGFloat = 5
        let rect = CGRect(x: point.x, y: point.y, width: size.width + padX * 2, height: size.height + 4)
        fill.setFill()
        PlatformBezierPath.rounded(rect, radius: 3).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + padX, y: point.y + 2),
                                withAttributes: [.font: font, .foregroundColor: textColor])
        return rect.maxX
    }

    /// The scene header row: "Scene N" + INT/EXT and DAY/NIGHT chips + location,
    /// with the script page and shot count on the right. Returns the new y.
    /// A shooting-day banner: "Day N", its date, totals, daylight times and note,
    /// above the day's scenes. Returns the y just below it.
    private func drawDayHeader(_ day: ShootingDay, setups: Int, shots: Int, in context: CGContext,
                               at y: CGFloat, margin: CGFloat, pageWidth: CGFloat, textWidth: CGFloat) -> CGFloat {
        var yy = y
        let grey = PlatformColor(white: 0.45, alpha: 1)

        let title = "Day \(day.sortOrder + 1)"
        let titleFont = PlatformFont.boldSystemFont(ofSize: 17)
        NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: PlatformColor.black])
            .draw(at: CGPoint(x: margin, y: yy))
        if let date = day.date {
            let df = DateFormatter(); df.dateStyle = .full
            let cx = margin + (title as NSString).size(withAttributes: [.font: titleFont]).width + 10
            NSAttributedString(string: df.string(from: date),
                               attributes: [.font: PlatformFont.systemFont(ofSize: 12), .foregroundColor: grey])
                .draw(at: CGPoint(x: cx, y: yy + 5))
        }
        yy += 24

        NSAttributedString(string: "\(setups) scene\(setups == 1 ? "" : "s") · \(shots) shot\(shots == 1 ? "" : "s")",
                           attributes: [.font: PlatformFont.systemFont(ofSize: 10), .foregroundColor: grey])
            .draw(at: CGPoint(x: margin, y: yy))
        yy += 15

        if let sun = ScheduleSummary.daylightTimes(for: day) {
            let line = "Sunrise \(sun.sunrise)    ·    Golden \(sun.goldenMorning)    ·    Golden \(sun.goldenEvening)    ·    Sunset \(sun.sunset)"
            NSAttributedString(string: line, attributes: [.font: PlatformFont.systemFont(ofSize: 9), .foregroundColor: PlatformColor(white: 0.5, alpha: 1)])
                .draw(at: CGPoint(x: margin, y: yy))
            yy += 14
        }

        let notes = day.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let h = pdfTextHeight(notes, font: PlatformFont.systemFont(ofSize: 10), width: textWidth)
            NSAttributedString(string: notes, attributes: [.font: PlatformFont.systemFont(ofSize: 10), .foregroundColor: PlatformColor(white: 0.2, alpha: 1)])
                .draw(with: CGRect(x: margin, y: yy + 2, width: textWidth, height: h), options: [.usesLineFragmentOrigin], context: nil)
            yy += h + 4
        }

        yy += 6
        context.setStrokeColor(PlatformColor(white: 0.65, alpha: 1).cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: margin, y: yy))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: yy))
        context.strokePath()
        return yy + 14
    }

    private func drawSceneHeaderRow(_ scene: Scene, in context: CGContext, at y: CGFloat,
                                    margin: CGFloat, pageWidth: CGFloat) -> CGFloat {
        var yPosition = y
        let titleFont = PlatformFont.boldSystemFont(ofSize: 14)
        let title = "Scene \(scene.sceneNumber)\(scene.suffix)"
        NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: PlatformColor.black])
            .draw(at: CGPoint(x: margin, y: yPosition + 2))

        var cx = margin + (title as NSString).size(withAttributes: [.font: titleFont]).width + 12
        let chipY = yPosition + 2
        cx = drawPDFChip(scene.isInterior ? "INT" : "EXT",
                         fill: Self.pdfChipNeutral.fill, textColor: Self.pdfChipNeutral.text,
                         at: CGPoint(x: cx, y: chipY)) + 5
        let day = scene.isDay
        cx = drawPDFChip(day ? "DAY" : "NIGHT",
                         fill: day ? Self.pdfChipDay.fill : Self.pdfChipNight.fill,
                         textColor: day ? Self.pdfChipDay.text : Self.pdfChipNight.text,
                         at: CGPoint(x: cx, y: chipY)) + 8

        let location = scene.nickname.trimmingCharacters(in: .whitespaces)
        if !location.isEmpty {
            NSAttributedString(string: location.uppercased(),
                               attributes: [.font: PlatformFont.systemFont(ofSize: 10), .foregroundColor: PlatformColor(white: 0.45, alpha: 1)])
                .draw(at: CGPoint(x: cx, y: yPosition + 3))
        }

        yPosition += 22
        context.setStrokeColor(PlatformColor(white: 0.8, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: margin, y: yPosition))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
        context.strokePath()
        return yPosition + 12
    }

    /// A light "Scene N — LOCATION (continued)" line at the top of a page whose
    /// scene carried over from the previous one.
    private func drawSceneContinuationHeader(_ scene: Scene, in context: CGContext, at y: CGFloat,
                                             margin: CGFloat, pageWidth: CGFloat) -> CGFloat {
        var text = "Scene \(scene.sceneNumber)\(scene.suffix)"
        let loc = scene.nickname.trimmingCharacters(in: .whitespaces)
        if !loc.isEmpty { text += " — \(loc.uppercased())" }
        text += " (continued)"
        NSAttributedString(string: text, attributes: [.font: PlatformFont.boldSystemFont(ofSize: 11), .foregroundColor: PlatformColor(white: 0.5, alpha: 1)])
            .draw(at: CGPoint(x: margin, y: y))
        return y + 22
    }

    /// The label/value pairs, long fields and reference rows a shot card shows.
    private func pdfShotContent(_ shot: Shot) -> (pairs: [(String, String)], extra: String, coverage: [String], refs: [ShotReference]) {
        var pairs: [(String, String)] = []
        if shot.hasSize {
            var v = shot.sizeShort
            if shot.hasSecondSize { v += " → " + shot.secondSizeShort }
            pairs.append(("Size", v))
        }
        if shot.hasType {
            var v = shot.typeShort
            if shot.hasSecondType { v += " + " + shot.secondTypeShort }
            if shot.hasThirdType { v += " + " + shot.thirdTypeShort }
            pairs.append(("Type", v))
        }
        if shot.lensfocal > 0 {
            pairs.append(("Focal Length", shot.lensIsPrime ? "\(shot.lensfocal)mm" : "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"))
        }
        if shot.hasGrip { pairs.append(("Grip", shot.gripName)) }
        if !shot.camera.isEmpty { pairs.append(("Camera", shot.camera)) }
        if !shot.framelines.isEmpty { pairs.append(("Framelines", shot.framelines)) }
        if !shot.lensPreset.isEmpty { pairs.append(("Lens", shot.lensPreset)) }
        for info in shot.orderedCustomInfo {
            let value = info.exportValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            pairs.append((info.exportLabel, value))
        }

        let extra = shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverage = (shot.scriptCoverageSelections ?? []).map { formatCoverageSummary($0) }
        let refs = shot.orderedReferences.filter { $0.imageData != nil || $0.mapData != nil }
        return (pairs, extra, coverage, refs)
    }

    // Shot-list row + reference-gallery layout for the PDF.
    private static let pdfRowGutter: CGFloat = 30          // shot-number column width
    private static let pdfSubFont = PlatformFont.systemFont(ofSize: 9)

    private func pdfTextHeight(_ text: String, font: PlatformFont, width: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
    }

    /// Size, Type and Focal Length ride the shot's name row; everything else drops
    /// into a muted two-column label/value grid below it.
    private static let pdfPrimaryLabels: Set<String> = ["Size", "Type", "Focal Length", "Grip"]
    private static let pdfMetaRowH: CGFloat = 13
    private static let pdfMetaBoxPadTop: CGFloat = 5
    private static let pdfMetaBoxPadBottom: CGFloat = 4
    private static let pdfMetaBoxPadLeft: CGFloat = 10
    private static let pdfMetaLabelColW: CGFloat = 66
    private static let pdfMetaLabelFont = PlatformFont.systemFont(ofSize: 8.5)
    private static let pdfMetaValueFont = PlatformFont.systemFont(ofSize: 8.5, weight: .medium)

    /// Height of the grey box's inner content (two-column specs grid + full-width
    /// coverage rows), or nil when there's nothing to box. Shared by the height
    /// calc and the drawing so they stay in sync.
    private func pdfMetaBoxContentHeight(secondary: [(String, String)], coverage: [String], contentW: CGFloat) -> CGFloat? {
        guard !secondary.isEmpty || !coverage.isEmpty else { return nil }
        let gridRows = Int(ceil(Double(secondary.count) / 2.0))
        var contentH = CGFloat(gridRows) * Self.pdfMetaRowH
        if !coverage.isEmpty {
            if !secondary.isEmpty { contentH += 2 }
            let valW = contentW - Self.pdfMetaBoxPadLeft * 2 - Self.pdfMetaLabelColW - 8
            for line in coverage {
                contentH += max(Self.pdfMetaRowH, pdfTextHeight(line, font: Self.pdfMetaValueFont, width: valW)) + 2
            }
        }
        return contentH
    }

    /// The height a text-only shot row occupies — mirrors `drawShotRow` exactly.
    /// `offDay` shots (a split scene's shots not shot on the current day) show a
    /// compact greyed row with a "not scheduled" note instead of the full details.
    func pdfShotRowHeight(_ shot: Shot, textWidth: CGFloat, offDay: Bool = false) -> CGFloat {
        let contentW = textWidth - Self.pdfRowGutter
        if offDay {
            return 16 + pdfTextHeight("Not scheduled for this day", font: Self.pdfSubFont, width: contentW) + 8
        }
        let c = pdfShotContent(shot)
        var h: CGFloat = 16                                 // number + nickname + primary specs line
        let secondary = c.pairs.filter { !Self.pdfPrimaryLabels.contains($0.0) && pdfOptions.includesField($0.0) }
        let coverage = pdfOptions.includesField(PDFExportOptions.coverageLabel) ? c.coverage : []
        let extra = pdfOptions.includesField(PDFExportOptions.extraInfoLabel) ? c.extra : ""
        if let contentH = pdfMetaBoxContentHeight(secondary: secondary, coverage: coverage, contentW: contentW) {
            h += 4 + Self.pdfMetaBoxPadTop + contentH + Self.pdfMetaBoxPadBottom
        }
        if !extra.isEmpty { h += pdfTextHeight("Extra:  " + extra, font: Self.pdfSubFont, width: contentW) + 2 }
        return h + 8                                        // gap + separator
    }

    /// Every reference photo in the scene, each with a caption, for the gallery drawn
    /// below a scene's shot list. (The scene map gets its own full page afterwards.)
    /// `onlyShotUIDs`, when set, limits the gallery to those shots (a split scene's
    /// shots for the current shooting day).
    private func pdfGalleryItems(for scene: Scene, onlyShotUIDs: Set<String>? = nil) -> [(data: Data, caption: String)] {
        var items: [(data: Data, caption: String)] = []
        for shot in scene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }) {
            if let ids = onlyShotUIDs, !ids.contains(shot.uid) { continue }
            // Only the reference photos — the per-shot top-down maps are skipped.
            let refs = shot.orderedReferences.filter { $0.imageData != nil }
            for (i, r) in refs.enumerated() {
                let suffix = refs.count > 1 ? " \(i + 1)" : ""
                if let d = r.imageData { items.append((d, "Shot \(shot.displayNumber) — Ref\(suffix)")) }
            }
        }
        return items
    }

    /// Draws one text-only shot row (number, nickname, specs, coverage, extra) with
    /// a light separator beneath. Returns the y just below it. Mirrors `pdfShotRowHeight`.
    /// An `offDay` shot draws a compact greyed row noting it isn't scheduled today.
    private func drawShotRow(_ shot: Shot, in context: CGContext, at yTop: CGFloat,
                             margin: CGFloat, textWidth: CGFloat, offDay: Bool = false) -> CGFloat {
        let ink = PlatformColor.black
        let grey = PlatformColor(white: 0.42, alpha: 1)
        let contentX = margin + Self.pdfRowGutter
        let contentW = textWidth - Self.pdfRowGutter
        var cy = yTop

        func separator(_ atY: CGFloat) {
            context.setStrokeColor(PlatformColor(white: 0.90, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: atY))
            context.addLine(to: CGPoint(x: margin + textWidth, y: atY))
            context.strokePath()
        }

        // A split scene's off-day shot: compact, greyed, with a "not scheduled" note.
        if offDay {
            let dim = PlatformColor(white: 0.62, alpha: 1)
            NSAttributedString(string: shot.displayNumber,
                               attributes: [.font: PlatformFont.boldSystemFont(ofSize: 11), .foregroundColor: dim])
                .draw(at: CGPoint(x: margin, y: cy))
            if !shot.nickname.isEmpty {
                NSAttributedString(string: shot.nickname,
                                   attributes: [.font: PlatformFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: dim])
                    .draw(at: CGPoint(x: contentX, y: cy))
            }
            cy += 16
            let note = "Not scheduled for this day"
            let h = pdfTextHeight(note, font: Self.pdfSubFont, width: contentW)
            NSAttributedString(string: note, attributes: [.font: Self.pdfSubFont, .foregroundColor: dim])
                .draw(in: CGRect(x: contentX, y: cy, width: contentW, height: h))
            cy += h + 2
            cy += 4
            separator(cy)
            return cy + 4
        }

        let c = pdfShotContent(shot)

        // Line 1: shot number (bold, in the gutter) + nickname, with Size/Type/Focal
        // right-aligned on the same row.
        NSAttributedString(string: shot.displayNumber,
                           attributes: [.font: PlatformFont.boldSystemFont(ofSize: 11), .foregroundColor: ink])
            .draw(at: CGPoint(x: margin, y: cy))
        var nickW: CGFloat = 0
        if !shot.nickname.isEmpty {
            let nickAttr: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink]
            NSAttributedString(string: shot.nickname, attributes: nickAttr)
                .draw(at: CGPoint(x: contentX, y: cy))
            nickW = (shot.nickname as NSString).size(withAttributes: nickAttr).width
        }
        // Size / Type / Focal, left-aligned right after the shot name.
        let primary = c.pairs.filter { Self.pdfPrimaryLabels.contains($0.0) && pdfOptions.includesField($0.0) }
        let primaryText = primary.map { $0.1 }.joined(separator: "   ·   ")
        if !primaryText.isEmpty {
            let px = contentX + (nickW > 0 ? nickW + 14 : 0)
            NSAttributedString(string: primaryText,
                               attributes: [.font: PlatformFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: grey])
                .draw(at: CGPoint(x: px, y: cy + 1))
        }
        cy += 16

        // Secondary specs (two-column grid) + coverage, together in a light grey box.
        let secondary = c.pairs.filter { !Self.pdfPrimaryLabels.contains($0.0) && pdfOptions.includesField($0.0) }
        let coverage = pdfOptions.includesField(PDFExportOptions.coverageLabel) ? c.coverage : []
        if let contentH = pdfMetaBoxContentHeight(secondary: secondary, coverage: coverage, contentW: contentW) {
            cy += 4
            let boxH = Self.pdfMetaBoxPadTop + contentH + Self.pdfMetaBoxPadBottom
            let boxRect = CGRect(x: contentX, y: cy, width: contentW, height: boxH)
            PlatformColor(white: 0.95, alpha: 1).setFill()
            PlatformBezierPath.rounded(boxRect, radius: 6).fill()
            PlatformColor(white: 0.90, alpha: 1).setStroke()
            let boxBorder = PlatformBezierPath.rounded(boxRect, radius: 6)
            boxBorder.lineWidth = 0.5
            boxBorder.stroke()

            let gridX = contentX + Self.pdfMetaBoxPadLeft
            let gridW = contentW - Self.pdfMetaBoxPadLeft * 2
            let colW = gridW / 2
            let labelColW = Self.pdfMetaLabelColW
            let labelAttr: [NSAttributedString.Key: Any] = [.font: Self.pdfMetaLabelFont, .foregroundColor: PlatformColor(white: 0.5, alpha: 1)]
            let valueAttr: [NSAttributedString.Key: Any] = [.font: Self.pdfMetaValueFont, .foregroundColor: PlatformColor(white: 0.2, alpha: 1)]

            let gridRows = Int(ceil(Double(secondary.count) / 2.0))
            for (i, pair) in secondary.enumerated() {
                let col = i % 2, row = i / 2
                let x = gridX + CGFloat(col) * colW
                let y = cy + Self.pdfMetaBoxPadTop + CGFloat(row) * Self.pdfMetaRowH
                NSAttributedString(string: pair.0, attributes: labelAttr).draw(at: CGPoint(x: x, y: y))
                NSAttributedString(string: pair.1, attributes: valueAttr)
                    .draw(with: CGRect(x: x + labelColW, y: y, width: colW - labelColW - 8, height: Self.pdfMetaRowH),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }

            // Coverage rows span the full box width, styled like the grid fields.
            var innerY = cy + Self.pdfMetaBoxPadTop + CGFloat(gridRows) * Self.pdfMetaRowH
            if !coverage.isEmpty {
                if gridRows > 0 { innerY += 2 }
                let valW = gridW - labelColW - 8
                for (i, line) in coverage.enumerated() {
                    if i == 0 {
                        NSAttributedString(string: "Coverage", attributes: labelAttr).draw(at: CGPoint(x: gridX, y: innerY))
                    }
                    let hh = max(Self.pdfMetaRowH, pdfTextHeight(line, font: Self.pdfMetaValueFont, width: valW))
                    NSAttributedString(string: line, attributes: valueAttr)
                        .draw(with: CGRect(x: gridX + labelColW, y: innerY, width: valW, height: hh),
                              options: [.usesLineFragmentOrigin], context: nil)
                    innerY += hh + 2
                }
            }
            cy += boxH
        }
        // Extra info.
        let extra = pdfOptions.includesField(PDFExportOptions.extraInfoLabel) ? c.extra : ""
        if !extra.isEmpty {
            let text = "Extra:  " + extra
            let h = pdfTextHeight(text, font: Self.pdfSubFont, width: contentW)
            NSAttributedString(string: text, attributes: [.font: Self.pdfSubFont, .foregroundColor: ink])
                .draw(in: CGRect(x: contentX, y: cy, width: contentW, height: h))
            cy += h + 2
        }

        // Light separator under the row.
        cy += 4
        context.setStrokeColor(PlatformColor(white: 0.90, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: cy))
        context.addLine(to: CGPoint(x: margin + textWidth, y: cy))
        context.strokePath()
        return cy + 4
    }

    /// Draws one gallery thumbnail (image letterboxed in `box`, thin border, caption
    /// centered just below).
    private func drawPDFThumb(_ data: Data, caption: String, in context: CGContext, box: CGRect) {
        let grey = PlatformColor(white: 0.42, alpha: 1)
        if let img = PlatformImage(data: data), img.size.width > 0, img.size.height > 0,
           let cg = img.cgImageForDrawing {
            let aspect = img.size.width / img.size.height
            var dw = box.width, dh = box.width / aspect
            if dh > box.height { dh = box.height; dw = dh * aspect }
            let r = CGRect(x: box.midX - dw / 2, y: box.minY + (box.height - dh) / 2, width: dw, height: dh)
            context.saveGState()
            context.translateBy(x: 0, y: r.origin.y + r.size.height)
            context.scaleBy(x: 1.0, y: -1.0)
            context.translateBy(x: 0, y: -r.origin.y)
            context.draw(cg, in: r)
            context.restoreGState()
        }
        PlatformColor(white: 0.85, alpha: 1).setStroke()
        let b = PlatformBezierPath(rect: box)
        b.lineWidth = 0.5
        b.stroke()
        let attr: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: grey]
        let cs = (caption as NSString).size(withAttributes: attr)
        (caption as NSString).draw(at: CGPoint(x: box.midX - cs.width / 2, y: box.maxY + 2), withAttributes: attr)
    }

    /// Draws an image letterboxed and centered to fill `box` as large as possible,
    /// with an optional thin border around the image itself.
    private func drawPDFImageFit(_ data: Data, in context: CGContext, box: CGRect, border: Bool = false) {
        guard let img = PlatformImage(data: data), img.size.width > 0, img.size.height > 0,
              let cg = img.cgImageForDrawing else { return }
        let aspect = img.size.width / img.size.height
        var dw = box.width, dh = box.width / aspect
        if dh > box.height { dh = box.height; dw = dh * aspect }
        let r = CGRect(x: box.midX - dw / 2, y: box.minY + (box.height - dh) / 2, width: dw, height: dh)
        context.saveGState()
        context.translateBy(x: 0, y: r.origin.y + r.size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: 0, y: -r.origin.y)
        context.draw(cg, in: r)
        context.restoreGState()
        if border {
            PlatformColor(white: 0.85, alpha: 1).setStroke()
            let b = PlatformBezierPath(rect: r)
            b.lineWidth = 0.5
            b.stroke()
        }
    }
    
    func formatCoverageSummary(_ selection: ScriptTextSelection) -> String {
        let pageRange = formatPageRange(selection)
        
        guard let fullText = selection.fullText, !fullText.isEmpty else {
            return pageRange
        }
        
        // Split text into words and clean up
        let words = fullText.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else {
            return pageRange
        }
        
        // Format the summary
        let textSummary: String
        if words.count <= 3 {
            // If 3 or fewer words, just show them all
            textSummary = words.joined(separator: " ")
        } else if words.count <= 6 {
            // If 4-6 words, show all without ellipsis
            textSummary = words.joined(separator: " ")
        } else {
            // Show first 3 ... last 3
            let firstThree = words.prefix(3).joined(separator: " ")
            let lastThree = words.suffix(3).joined(separator: " ")
            textSummary = "\(firstThree)...\(lastThree)"
        }
        
        return "\(textSummary) \(pageRange)"
    }
    
    private func formatPageRange(_ selection: ScriptTextSelection) -> String {
        let pages = selection.pageRanges.map { $0.pageIndex + 1 }.sorted()
        
        guard !pages.isEmpty else {
            return ""
        }
        
        if pages.count == 1 {
            return "(P\(pages[0]))"
        } else {
            let firstPage = pages.first!
            let lastPage = pages.last!
            return "(P\(firstPage) - P\(lastPage))"
        }
    }
    
    #if os(macOS)
    func showErrorAlert(error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func showSuccessNotification(fileURL: URL, format: ExportFormat) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Export Successful"
            alert.informativeText = "Your shot list has been exported as a \(format.displayName) file."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                // Show in Finder
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }
    #endif
}
