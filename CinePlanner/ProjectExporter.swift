//
//  ProjectExporter.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 25/12/2025.
//

import Foundation
import SwiftUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

/// Handles exporting project shot lists to PDF and TXT formats
struct ProjectExporter {
    let project: Project
    var version: ScriptVersion? = nil
    /// What the PDF export includes; set by the export sheet before a PDF export.
    var pdfOptions = PDFExportOptions()

    /// Scenes to export: the selected script version's scenes, or all project
    /// scenes for legacy projects without versions.
    private var exportScenes: [Scene] {
        version?.scenes ?? project.scenes
    }

    /// The scenes a PDF export covers — `exportScenes` in order, filtered by the
    /// PDF options' scene selection.
    private var pdfExportScenes: [Scene] {
        exportScenes.sorted { $0.sortOrder < $1.sortOrder }.filter { pdfOptions.includesScene($0) }
    }

    /// Whether the PDF is actually rendered day-ordered (option on and days exist).
    private var pdfIsDayMode: Bool {
        pdfOptions.groupByShootingDay && !(version?.orderedShootingDays.isEmpty ?? true)
    }
    /// The PDF's document name — "Shot List Per Day" when day-ordered, else "Shot List".
    private var pdfDocumentName: String { pdfIsDayMode ? "Shot List Per Day" : "Shot List" }

    enum ExportError: Error { case generationFailed }

    /// Generates the export for `format` into a temporary file and returns its URL,
    /// cross-platform (no save panel). The caller presents or saves it — used by the
    /// iPad share-sheet flow and reusable anywhere a file is needed.
    @MainActor
    func exportFileURL(format: ExportFormat) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        func temp(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            return url
        }
        switch format {
        case .text:
            let url = temp("\(project.filmName) - Shot List.txt")
            try generateFullTextContent().write(to: url, atomically: true, encoding: .utf8)
            return url
        case .pdf:
            guard let data = createPDFData(from: generateFullTextContent()) else { throw ExportError.generationFailed }
            let url = temp("\(project.filmName) - \(pdfDocumentName).pdf")
            try data.write(to: url)
            return url
        case .scriptWithCoverage:
            guard let data = createScriptWithCoverage() else { throw ExportError.generationFailed }
            let url = temp("\(project.filmName) - Script with Coverage.pdf")
            try data.write(to: url)
            return url
        case .htmlWithMedia:
            let filmName = project.filmName
            let versionName = version?.name
            let episodeName = version?.episode?.project?.isSeries == true ? version?.episode?.title : nil
            let scenes = snapshotScenesForMedia()
            let needsFolder = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil || $0.mapVideoData != nil } } }
            let baseName = webExportBaseName(filmName)
            let url = temp(needsFolder ? "\(baseName).zip" : "\(baseName).html")
            try writeWebExport(filmName: filmName, episodeName: episodeName,
                               versionName: versionName, scenes: scenes, to: url)
            return url
        }
    }

    /// Shows a save panel and exports the shot list
    #if os(macOS)
    func exportShotList(format: ExportFormat) {
        // These follow their own paths (need media Data, produce a package)
        if format == .htmlWithMedia {
            exportHTMLWithMedia()
            return
        }
        print("🔵 [EXPORT] Starting export process...")
        print("🔵 [EXPORT] Current thread: \(Thread.current)")
        print("🔵 [EXPORT] Is main thread: \(Thread.isMainThread)")
        
        // CRITICAL: Extract ALL data from SwiftData models BEFORE opening save panel
        // This prevents SwiftData threading violations
        print("🔵 [EXPORT] About to generate content from SwiftData...")
        let content: String
        do {
            content = generateFullTextContent()
            print("✅ [EXPORT] Content generated successfully (\(content.count) characters)")
        } catch {
            print("❌ [EXPORT] Error generating content: \(error)")
            showErrorAlert(error: error)
            return
        }
        
        // Show save panel on main thread
        print("🔵 [EXPORT] Preparing save panel...")
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.title = "Export Shot List"
            savePanel.message = "Choose where to save your \(format.displayName) export"
            
            // Set filename based on format
            let fileName: String
            switch format {
            case .scriptWithCoverage:
                fileName = "\(self.project.filmName) - Script with Coverage.\(format.fileExtension)"
            case .pdf:
                fileName = "\(self.project.filmName) - \(self.pdfDocumentName).\(format.fileExtension)"
            default:
                fileName = "\(self.project.filmName) - Shot List.\(format.fileExtension)"
            }
            
            savePanel.nameFieldStringValue = fileName
            savePanel.allowedContentTypes = [format.contentType]
            savePanel.canCreateDirectories = true
            savePanel.showsTagField = true
            
            print("🔵 [EXPORT] Showing save panel...")
            let response = savePanel.runModal()
            
            if response == .OK, let url = savePanel.url {
                print("✅ [EXPORT] User selected save location: \(url.path)")
                
                do {
                    // Create file based on format
                    switch format {
                    case .text:
                        // Write text file directly to selected location
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        print("✅ [EXPORT] Text file saved successfully")
                        
                    case .pdf:
                        // Convert text to PDF and save
                        guard let pdfData = self.createPDFData(from: content) else {
                            throw NSError(domain: "ProjectExporter", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF data"])
                        }
                        try pdfData.write(to: url)
                        print("✅ [EXPORT] PDF file saved successfully")
                        
                    case .scriptWithCoverage:
                        // Export script with coverage lines burned in
                        guard let pdfData = self.createScriptWithCoverage() else {
                            throw NSError(domain: "ProjectExporter", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to create script with coverage. Make sure a script PDF is imported."])
                        }
                        try pdfData.write(to: url)
                        print("✅ [EXPORT] Script with coverage saved successfully")

                    case .htmlWithMedia:
                        break // handled earlier via their own methods
                    }

                    // Show success notification
                    self.showSuccessNotification(fileURL: url, format: format)
                    
                } catch {
                    print("❌ [EXPORT] Error saving file: \(error)")
                    self.showErrorAlert(error: error)
                }
            } else {
                print("ℹ️ [EXPORT] User cancelled save operation")
            }
        }
    }
    #endif

    // MARK: - HTML with Media Export

    /// One reference belonging to a shot: a photo or a video, plus its own map.
    private struct MediaReference {
        let index: Int              // 1-based, for labelling ("Reference 2")
        let photoData: Data?        // JPEG
        let mapData: Data?          // JPEG
        let videoData: Data?
        let videoExtension: String
        let mapVideoData: Data?     // a top-down map can be a video too
        let mapVideoExtension: String
        let note: String?           // user caption shown under the media
    }

    private struct MediaShot {
        let displayNumber: String
        let slug: String            // filesystem-safe id for media filenames
        let nickname: String
        let details: [(label: String, value: String)]
        let coverageText: String?
        let coveragePreview: String?
        let hasCoverage: Bool
        let references: [MediaReference]
    }

    private struct MediaScene {
        let heading: String
            let subheading: String       // "INT · KITCHEN · DAY"
        let isInterior: Bool         // kept separate so the web page can filter on them
        let isDay: Bool
        let location: String
        let coverage: CoverageImage?   // scene's script pages with all shots' coverage
        let map: CoverageImage?        // scene's top-down blocking map
        let filmEntries: [FilmReportEntry]   // per-shot film lengths (empty = no film tool)
        let filmTotals: [(gauge: String, metres: String, time: String)]
        let projectFilmTotals: [(gauge: String, metres: String, time: String)]
        let shots: [MediaShot]
    }

    /// One row of the per-scene film-length report.
    private struct FilmReportEntry {
        let shot: String; let format: String; let fps: String; let length: String; let time: String
    }

    /// One scene placed on a shooting day (a schedule "strip") for the web export's
    /// shooting-day view. `sceneIndex` points into the exported `scenes` array.
    private struct MediaScheduleEntry {
        let sceneIndex: Int
        let allShots: Bool                    // whole scene on this day
        let scheduledShotNumbers: Set<String> // display numbers shot on this day
        let note: String
    }

    /// A shooting day for the web export's day-ordered view.
    private struct MediaScheduleDay {
        let number: Int          // 1-based
        let notes: String        // the day's free-text note, "" when none
        let dateLabel: String    // "" when no date assigned
        let isoDate: String      // "yyyy-MM-dd" for matching "today" in the browser, else ""
        let setups: Int          // scenes on the day
        let shots: Int           // shots planned on the day
        let sunrise: String      // "" when unavailable
        let sunset: String
        let goldenAM: String     // "6:12–6:48"
        let goldenPM: String     // "20:03–20:39"
        let entries: [MediaScheduleEntry]
    }

    /// Videos are the only thing that has to live beside the web page as a real
    /// file — photos are embedded in the HTML itself. Without them the export is a
    /// single self-contained page and needs no folder, and so no zip.
    var webExportNeedsFolder: Bool {
        // Tested via the extension, not the Data: the two are always written and
        // cleared together, and reading the blob just to see whether it exists
        // would pull every video in the project into memory.
        exportScenes.contains { $0.shots.contains { $0.references.contains { $0.videoExtension != nil || $0.mapVideoExtension != nil } } }
    }

    /// The name the exported page is saved under, in both the single-file and the
    /// zipped case, so the file is identifiable once it's out of the app.
    private func webExportBaseName(_ filmName: String) -> String {
        let safe = filmName.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        // An unnamed project would otherwise come out as "Shot List - Shot List".
        return safe.isEmpty ? "Shot List" : "\(safe) - Shot List"
    }

    /// With videos: a self-contained folder (page + media/) zipped for sharing.
    /// Without: one HTML file, since the photos are embedded in it anyway.
    #if os(macOS)
    private func exportHTMLWithMedia() {
        // Snapshot everything off SwiftData up front (main thread) so the save panel
        // and file writing never touch the models on another thread.
        let filmName = project.filmName
        let versionName = version?.name
        let episodeName = version?.episode?.project?.isSeries == true ? version?.episode?.title : nil
        let scenes = snapshotScenesForMedia()
        let needsFolder = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil || $0.mapVideoData != nil } } }
        let baseName = webExportBaseName(filmName)

        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.title = "Export Web Page"
            savePanel.message = needsFolder
                ? "Saves a .zip containing the web page and all videos"
                : "Saves a single web page with every photo built in"
            savePanel.nameFieldStringValue = needsFolder ? "\(baseName).zip" : "\(baseName).html"
            savePanel.allowedContentTypes = [needsFolder ? .zip : .html]
            savePanel.canCreateDirectories = true

            guard savePanel.runModal() == .OK, let destination = savePanel.url else {
                print("ℹ️ [EXPORT] HTML export cancelled")
                return
            }

            do {
                try self.writeWebExport(filmName: filmName,
                                        episodeName: episodeName,
                                        versionName: versionName,
                                        scenes: scenes,
                                        to: destination)
                self.showSuccessNotification(fileURL: destination, format: .htmlWithMedia)
            } catch {
                print("❌ [EXPORT] HTML export failed: \(error)")
                self.showErrorAlert(error: error)
            }
        }
    }
    #endif

    /// The per-shot colour used for coverage highlights, matching the editor and
    /// the "script with coverage" PDF: a shot's position within its scene.
    private static let coveragePalette: [PlatformColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink,
        .systemTeal, .systemIndigo, .systemRed, .systemYellow, .systemBrown
    ]

    /// A rendered scene-coverage image, plus its pixel size so the web page can set
    /// an aspect ratio and let the (often tall) image scroll at a readable width.
    struct CoverageImage {
        let data: Data
        let width: CGFloat
        let height: CGFloat
    }

    /// The absolute PDF page range a scene spans: from its heading page to the page
    /// where the next scene (on a later page) begins — which this scene shares — or
    /// the last page for the final scene. So the coverage card can show the whole
    /// scene, uncovered pages included.
    private func scenePageSpan(for scene: Scene, in pdf: PDFDocument) -> ClosedRange<Int> {
        let last = max(0, pdf.pageCount - 1)
        let start = min(max(0, scene.absolutePDFPage), last)
        let ordered = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        var end = last
        if let idx = ordered.firstIndex(where: { $0 === scene }) {
            for next in ordered[(idx + 1)...] where next.absolutePDFPage > start {
                end = next.absolutePDFPage
                break
            }
        }
        end = min(max(start, end), last)
        return start...end
    }

    /// Renders the scene's script page(s) as one image — the whole scene, not only
    /// the covered pages — drawing each shot's coverage as a coloured bar in the left
    /// margin next to the covered lines (the same style as the "script with coverage"
    /// PDF), with the shot number above each bar. Returns nil when no shot in the
    /// scene has coverage.
    private func renderSceneCoverage(scene: Scene, sourcePDF: PDFDocument) -> CoverageImage? {
        struct Bar { let color: PlatformColor; let label: String; let minY: CGFloat; let maxY: CGFloat }
        var byPage: [Int: [Bar]] = [:]
        for shot in scene.shots {
            guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { continue }
            let colorIndex = (scene.orderedShots.firstIndex { $0 === shot } ?? 0) % Self.coveragePalette.count
            let color = Self.coveragePalette[colorIndex]
            for selection in selections {
                for pageRange in selection.pageRanges {
                    let ys = pageRange.selections.map(\.cgRect)
                    guard let minY = ys.map(\.minY).min(), let maxY = ys.map(\.maxY).max() else { continue }
                    byPage[pageRange.pageIndex, default: []].append(
                        Bar(color: color, label: shot.displayNumber, minY: minY, maxY: maxY))
                }
            }
        }
        guard !byPage.isEmpty else { return nil }

        // Show the scene's whole extent — every page it spans — not only the pages
        // that happen to carry coverage lines, so the uncovered parts of the scene
        // are still visible.
        let span = scenePageSpan(for: scene, in: sourcePDF)

        // Higher scale than a poster: this is text meant to be read when opened.
        let scale: CGFloat = 3.0
        var pageImages: [PlatformImage] = []
        for pageIndex in span {
            guard pageIndex >= 0, pageIndex < sourcePDF.pageCount,
                  let page = sourcePDF.page(at: pageIndex) else { continue }
            let cropBox = page.bounds(for: .cropBox)
            let size = CGSize(width: cropBox.width * scale, height: cropBox.height * scale)
            guard size.width > 1, size.height > 1 else { continue }

            let image = PlatformGraphics.image(size: size) { ctx in
                ctx.setFillColor(PlatformColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -cropBox.origin.x, y: -cropBox.origin.y)
                page.draw(with: .cropBox, to: ctx)

                // Pack bars by density and share one label scale — identical to the
                // editor overlay and the on-screen viewer (see CoverageLineLayout).
                let bars = byPage[pageIndex] ?? []
                let baseFont = PlatformFont.systemFont(ofSize: 9, weight: .semibold)
                let barLines: [CoverageLineLayout.Line] = bars.map { bar in
                    let w = NSAttributedString(string: bar.label, attributes: [.font: baseFont]).size()
                    return CoverageLineLayout.Line(
                        extent: bar.minY...bar.maxY,
                        labelWidth: w.width,
                        labelBand: (bar.maxY + 3)...(bar.maxY + 3 + w.height))
                }
                let placements = CoverageLineLayout.solve(barLines, band: exportLineRange(for: cropBox))
                for (bar, placed) in zip(bars, placements) {
                    let x = placed.x
                    ctx.setStrokeColor(bar.color.cgColor)
                    ctx.setLineWidth(max(1, 3 * placed.scale))
                    ctx.move(to: CGPoint(x: x, y: bar.minY))
                    ctx.addLine(to: CGPoint(x: x, y: bar.maxY))
                    ctx.strokePath()

                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: PlatformFont.systemFont(ofSize: 9 * placed.scale, weight: .semibold),
                        .foregroundColor: bar.color
                    ]
                    let label = NSAttributedString(string: bar.label, attributes: attrs)
                    let ls = label.size()
                    let labelOrigin = CGPoint(x: x - ls.width / 2, y: bar.maxY + 3)
                    // The context is y-up (see PlatformGraphics.image). AppKit text
                    // draws upright in it, but UIKit text would be mirrored — the
                    // shot number upside down. On iOS, flip locally about the label
                    // box so the glyphs are upright.
                    #if canImport(UIKit)
                    let labelRect = CGRect(origin: labelOrigin, size: ls)
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: labelRect.minY + labelRect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    label.draw(at: labelOrigin)
                    ctx.restoreGState()
                    #else
                    label.draw(at: labelOrigin)
                    #endif
                }
                ctx.restoreGState()
            }
            pageImages.append(image)
        }
        guard !pageImages.isEmpty else { return nil }

        // Stack the pages vertically.
        let gap: CGFloat = 14 * scale
        let width = pageImages.map(\.size.width).max() ?? 0
        let height = pageImages.reduce(0) { $0 + $1.size.height } + gap * CGFloat(pageImages.count - 1)
        let composite = PlatformGraphics.image(size: CGSize(width: width, height: height)) { ctx in
            ctx.setFillColor(PlatformColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y = height
            for image in pageImages {
                y -= image.size.height
                if let cg = image.cgImageForDrawing {
                    ctx.draw(cg, in: CGRect(x: (width - image.size.width) / 2, y: y,
                                            width: image.size.width, height: image.size.height))
                }
                y -= gap
            }
        }

        guard let data = composite.jpegRepresentation(quality: 0.85) else { return nil }
        return CoverageImage(data: data, width: width, height: height)
    }

    /// Rasterizes the scene's blocking map (background/floor plan/furniture/
    /// arrows/markers) to a JPEG for the web export, mirroring the editor canvas.
    /// Returns nil when the scene has no map content. Called on the main thread
    /// (like the coverage renderer), which `ImageRenderer` and the SwiftData
    /// reads both require.
    private func renderSceneMap(scene: Scene) -> CoverageImage? {
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        let plan = FloorPlan.load(from: scene.sceneFloorPlanJSON)
        // Include the background — satellite (Apple Maps) captures included — so the
        // exported scene map matches the editor.
        let background = scene.sceneMapBackgroundData.flatMap(PlatformImage.init(data:))
        guard !doc.elements.isEmpty || !doc.furniture.isEmpty || !plan.isEmpty || background != nil else { return nil }

        // Output aspect follows the background image; otherwise a square (which is
        // what the editor uses for a floor-plan-only or grid-only map).
        let base: CGFloat = 1200
        let outSize: CGSize
        if let bg = background, bg.size.width > 0, bg.size.height > 0 {
            let aspect = bg.size.width / bg.size.height
            outSize = aspect >= 1 ? CGSize(width: base, height: (base / aspect).rounded())
                                  : CGSize(width: (base * aspect).rounded(), height: base)
        } else {
            outSize = CGSize(width: base, height: base)
        }

        // Camera markers show their shot's current number; characters stay blank.
        var labels: [UUID: String] = [:]
        for element in doc.elements where element.kind == .camera {
            if let uid = element.shotUID, let shot = scene.shots.first(where: { $0.uid == uid }) {
                labels[element.id] = shot.displayNumber
            } else if !element.label.isEmpty {
                labels[element.id] = element.label
            }
        }

        let view = SceneMapExportView(doc: doc, plan: plan, background: background,
                                      labels: labels, size: outSize,
                                      metersWide: scene.sceneMapMetersWide,
                                      cameraMeters: scene.sceneMapCameraSizeMeters,
                                      viewableMarkers: scene.sceneMapViewableMarkerSize,
                                      isSatellite: scene.sceneMapBackgroundIsSatellite)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let image = PlatformImage.fromCGImage(cg, size: outSize)
        guard let data = image.jpegRepresentation(quality: 0.85) else { return nil }
        return CoverageImage(data: data, width: outSize.width, height: outSize.height)
    }

    private func snapshotScenesForMedia() -> [MediaScene] {
        let ordered = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        let sourcePDF = (version?.pdfData ?? project.scriptPDFData).flatMap { PDFDocument(data: $0) }
        // Whole-export film totals, shared by every scene's report.
        let projectFilmTotals = ShotCustomInfo.filmTotalsByGauge(for: ordered.flatMap { $0.shots }).map {
            (gauge: ShotCustomInfo.filmGaugeLabel($0.gauge),
             metres: ShotCustomInfo.filmMetresString($0.metres),
             time: ShotCustomInfo.filmDurationString($0.seconds))
        }
        return ordered.map { scene in
            let heading = "Scene \(scene.sceneNumber)\(scene.suffix)"
            var parts: [String] = [scene.isInterior ? "INT" : "EXT"]
            let location = scene.nickname.trimmingCharacters(in: .whitespaces)
            if !location.isEmpty { parts.append(location) }
            parts.append(scene.isDay ? "DAY" : "NIGHT")

            let shots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }.map { shot -> MediaShot in
                MediaShot(
                    displayNumber: shot.displayNumber,
                    slug: shot.displayNumber.map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined(),
                    nickname: shot.nickname,
                    details: shotDetails(shot),
                    coverageText: coverageSummary(shot),
                    coveragePreview: coveragePreview(shot),
                    hasCoverage: !(shot.scriptCoverageSelections?.isEmpty ?? true),
                    references: shot.orderedReferences.enumerated().map { index, reference in
                        MediaReference(
                            index: index + 1,
                            photoData: reference.imageData.flatMap { Self.jpegData(from: $0) },
                            mapData: reference.mapData.flatMap { Self.jpegData(from: $0) },
                            videoData: reference.videoData,
                            videoExtension: reference.videoExtension ?? "mov",
                            mapVideoData: reference.mapVideoData,
                            mapVideoExtension: reference.mapVideoExtension ?? "mov",
                            note: Self.cleanNote(reference.note)
                        )
                    }
                )
            }
            let filmEntries: [FilmReportEntry] = scene.shots
                .sorted { $0.shotNumber < $1.shotNumber }
                .flatMap { shot in
                    shot.orderedCustomInfo.filter { $0.kind == "filmstock" }.map { info in
                        FilmReportEntry(shot: shot.displayNumber, format: ShotCustomInfo.filmGaugeLabel(info.filmGauge),
                                        fps: info.filmFPSString,
                                        length: ShotCustomInfo.filmMetresString(info.filmMetres),
                                        time: ShotCustomInfo.filmDurationString(info.filmSeconds))
                    }
                }
            let filmTotals = ShotCustomInfo.filmTotalsByGauge(for: scene.shots).map {
                (gauge: ShotCustomInfo.filmGaugeLabel($0.gauge),
                 metres: ShotCustomInfo.filmMetresString($0.metres),
                 time: ShotCustomInfo.filmDurationString($0.seconds))
            }
            return MediaScene(heading: heading,
                              subheading: parts.joined(separator: " · "),
                              isInterior: scene.isInterior,
                              isDay: scene.isDay,
                              location: location,
                              coverage: sourcePDF.flatMap { renderSceneCoverage(scene: scene, sourcePDF: $0) },
                              map: renderSceneMap(scene: scene),
                              filmEntries: filmEntries,
                              filmTotals: filmTotals,
                              projectFilmTotals: projectFilmTotals,
                              shots: shots)
        }
    }

    /// The shooting schedule for the day-ordered web view, aligned to the same scene
    /// order `snapshotScenesForMedia` uses (so `sceneIndex` matches). Empty when the
    /// version has no shooting days.
    private func snapshotSchedule() -> [MediaScheduleDay] {
        let ordered = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        var indexByScene: [ObjectIdentifier: Int] = [:]
        for (i, scene) in ordered.enumerated() { indexByScene[ObjectIdentifier(scene)] = i }
        guard let days = version?.orderedShootingDays, !days.isEmpty else { return [] }
        let df = DateFormatter(); df.dateStyle = .full
        let isoFmt = DateFormatter()
        isoFmt.locale = Locale(identifier: "en_US_POSIX")
        isoFmt.dateFormat = "yyyy-MM-dd"
        return days.map { day in
            let entries: [MediaScheduleEntry] = day.orderedEntries.compactMap { e in
                guard let scene = e.scene, let idx = indexByScene[ObjectIdentifier(scene)] else { return nil }
                let all = Set(scene.orderedShots.map { $0.displayNumber })
                let scheduled = Set(e.resolvedShots.map { $0.displayNumber })
                let isAll = e.selectedShotUIDs.isEmpty || scheduled == all
                return MediaScheduleEntry(sceneIndex: idx, allShots: isAll,
                                          scheduledShotNumbers: scheduled, note: e.note)
            }
            let totals = ScheduleSummary.totals(for: day)
            let sun = ScheduleSummary.daylightTimes(for: day)
            return MediaScheduleDay(number: day.sortOrder + 1,
                                    notes: day.notes,
                                    dateLabel: day.date.map { df.string(from: $0) } ?? "",
                                    isoDate: day.date.map { isoFmt.string(from: $0) } ?? "",
                                    setups: totals.setups,
                                    shots: totals.shots,
                                    sunrise: sun?.sunrise ?? "",
                                    sunset: sun?.sunset ?? "",
                                    goldenAM: sun?.goldenMorning ?? "",
                                    goldenPM: sun?.goldenEvening ?? "",
                                    entries: entries)
        }
    }

    private func shotDetails(_ shot: Shot) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if shot.hasSize {
            var s = shot.sizeShort
            if shot.hasSecondSize { s += " → " + shot.secondSizeShort }
            rows.append(("Size", s))
        }
        if shot.hasType {
            var t = shot.typeShort
            if shot.hasSecondType { t += " + " + shot.secondTypeShort }
            if shot.hasThirdType { t += " + " + shot.thirdTypeShort }
            rows.append(("Type", t))
        }
        if shot.lensfocal > 0 {
            rows.append(("Focal Length", shot.lensIsPrime ? "\(shot.lensfocal)mm" : "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"))
        }
        if shot.hasGrip { rows.append(("Grip", shot.gripName)) }
        if !shot.camera.isEmpty { rows.append(("Camera", shot.camera)) }
        if !shot.framelines.isEmpty { rows.append(("Framelines", shot.framelines)) }
        if !shot.lensPreset.isEmpty { rows.append(("Lens", shot.lensPreset)) }
        if !shot.extraInfo.isEmpty { rows.append(("Extra info", shot.extraInfo)) }
        for info in shot.orderedCustomInfo {
            let value = info.exportValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            rows.append((info.exportLabel, value))
        }
        return rows
    }

    /// Shown while coverage is collapsed: the first and last five words with the
    /// script page(s), so a closed block still says what it covers.
    private func coveragePreview(_ shot: Shot) -> String? {
        guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { return nil }
        let text = selections.compactMap { $0.fullText }.joined(separator: " ")
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let summary = words.count <= 10
            ? words.joined(separator: " ")
            : words.prefix(5).joined(separator: " ") + " … " + words.suffix(5).joined(separator: " ")

        let pages = Set(selections.flatMap { $0.pageRanges.map { $0.pageIndex + 1 } }).sorted()
        let pageText: String
        switch pages.count {
        case 0:  pageText = ""
        case 1:  pageText = " (P\(pages[0]))"
        case 2:  pageText = " (P\(pages[0]), P\(pages[1]))"
        default: pageText = " (P\(pages.first!)–P\(pages.last!))"
        }
        return summary + pageText
    }

    private func coverageSummary(_ shot: Shot) -> String? {
        guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { return nil }
        let text = selections.compactMap { $0.fullText }.joined(separator: " … ")
        return text.isEmpty ? nil : text
    }

    /// Writes the web export to `destination` — a lone .html file when there are no
    /// videos, otherwise a zipped folder holding the page and a media/ directory.
    private func writeWebExport(filmName: String, episodeName: String?, versionName: String?,
                                scenes: [MediaScene], to destination: URL) throws {
        let hasVideo = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil || $0.mapVideoData != nil } } }
        if hasVideo {
            try writeHTMLBundle(filmName: filmName, episodeName: episodeName, versionName: versionName,
                                scenes: scenes, to: destination)
        } else {
            // Photos are already data URIs, so the page stands alone.
            var rendered: [String: RenderedMedia] = [:]
            for scene in scenes {
                for shot in scene.shots {
                    for reference in shot.references {
                        rendered[Self.mediaKey(shot.slug, reference.index)] = RenderedMedia(
                            photoURI: reference.photoData.map { Self.dataURI($0) },
                            topDownURI: reference.mapData.map { Self.dataURI($0) },
                            videoPath: nil,
                            posterURI: nil,
                            note: reference.note
                        )
                    }
                }
            }
            let episode = WebEpisode(title: episodeName, versionName: versionName,
                                     director: resolvedDirector(version?.episode),
                                     cinematographer: resolvedCinematographer(version?.episode),
                                     scenes: scenes, media: rendered, schedule: self.snapshotSchedule())
            let html = Self.buildHTML(filmName: filmName,
                                      productionCompany: project.productionCompany,
                                      episodes: [episode])
            guard let data = html.data(using: .utf8) else {
                throw Self.exportError("Failed to encode the web page.")
            }
            try data.write(to: destination)
        }
    }

    /// Shared, mutable transcode-progress counter so a multi-episode publish shows
    /// one continuous bar across every episode's videos.
    private final class CompressProgress {
        var done = 0
        let total: Int
        let report: (Int, Int) -> Void
        init(total: Int, report: @escaping (Int, Int) -> Void) { self.total = total; self.report = report }
        func bump() { done += 1; report(done, total) }
    }

    /// Builds a self-contained website folder — index.html at the root plus a
    /// media/ folder for any videos — in a fresh temp directory, ready to deploy.
    /// Photos are embedded in the page; only videos live as sibling files. Videos
    /// over GitHub's file limit are transcoded down so publishing can't fail on an
    /// oversized file. The caller is responsible for removing the returned directory.
    /// `onCompress(done, total)` fires as each over-limit video is transcoded.
    ///
    /// Single-page publish (feature film, or a series episode viewed on its own):
    /// one `index.html` built from `self.version`.
    @MainActor
    func buildSiteDirectory(onCompress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("web-publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let scenes = snapshotScenesForMedia()
        let progress = CompressProgress(total: Self.oversizedVideoCount(in: scenes), report: onCompress)
        let media = try await buildPublishMedia(scenes: scenes, mediaSubdir: "media", into: staging, progress: progress)
        let episodeName = version?.episode?.project?.isSeries == true ? version?.episode?.title : nil
        let episode = WebEpisode(title: episodeName, versionName: version?.name,
                                 director: resolvedDirector(version?.episode),
                                 cinematographer: resolvedCinematographer(version?.episode),
                                 scenes: scenes, media: media, schedule: snapshotSchedule())
        try writeIndex(Self.buildHTML(filmName: project.filmName,
                                      productionCompany: project.productionCompany, episodes: [episode],
                                      assetURL: Self.fileAssetWriter(staging: staging, subdir: "media")), into: staging)
        return staging
    }

    /// Series publish: all selected episodes go into one `index.html` with an in-page
    /// episode switch. Each episode uses its latest version and its own
    /// `media/ep-<n>/` folder (so shot slugs can't collide across episodes).
    @MainActor
    func buildSiteDirectory(episodes: [Episode],
                            onCompress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        let ordered = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        // A single episode is just the normal one-page site (no switch).
        guard ordered.count > 1 else {
            var ex = self
            ex.version = ordered.first?.orderedVersions.last ?? version
            return try await ex.buildSiteDirectory(onCompress: onCompress)
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("web-publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Snapshot each episode's scenes once, then a single progress total across all.
        let epScenes: [(Episode, ProjectExporter, [MediaScene])] = ordered.map { ep in
            var ex = self; ex.version = ep.orderedVersions.last
            return (ep, ex, ex.snapshotScenesForMedia())
        }
        let progress = CompressProgress(total: epScenes.reduce(0) { $0 + Self.oversizedVideoCount(in: $1.2) },
                                        report: onCompress)

        var webEpisodes: [WebEpisode] = []
        for (ep, ex, scenes) in epScenes {
            let media = try await ex.buildPublishMedia(scenes: scenes, mediaSubdir: "media/ep-\(ep.episodeNumber)",
                                                       into: staging, progress: progress)
            webEpisodes.append(WebEpisode(title: ep.title, versionName: ex.version?.name,
                                          director: resolvedDirector(ep), cinematographer: resolvedCinematographer(ep),
                                          scenes: scenes, media: media, schedule: ex.snapshotSchedule()))
        }
        try writeIndex(Self.buildHTML(filmName: project.filmName,
                                      productionCompany: project.productionCompany, episodes: webEpisodes,
                                      assetURL: Self.fileAssetWriter(staging: staging, subdir: "media")), into: staging)
        return staging
    }

    private func writeIndex(_ html: String, into staging: URL) throws {
        guard let data = html.data(using: .utf8) else { throw Self.exportError("Failed to encode the web page.") }
        try data.write(to: staging.appendingPathComponent("index.html"))
    }

    /// How many reference/map clips exceed GitHub's size limit and will be transcoded.
    private static func oversizedVideoCount(in scenes: [MediaScene]) -> Int {
        scenes.reduce(0) { acc, scene in
            acc + scene.shots.reduce(0) { a, shot in
                a + shot.references.reduce(0) { c, ref in
                    c + (((ref.videoData?.count ?? 0) > Self.gitHubVideoLimit) ? 1 : 0)
                      + (((ref.mapVideoData?.count ?? 0) > Self.gitHubVideoLimit) ? 1 : 0)
                }
            }
        }
    }

    /// Writes an episode's media into `staging/<mediaSubdir>/` and returns the media
    /// map for `buildHTML`. On the hosted publish path every image is a sibling file
    /// referenced by URL (not a data URI): embedding them would pile every photo,
    /// map and poster into `index.html`, making one blob too big for GitHub's API.
    /// Videos over GitHub's size limit are transcoded down first.
    private func buildPublishMedia(scenes: [MediaScene], mediaSubdir: String, into staging: URL,
                                   progress: CompressProgress) async throws -> [String: RenderedMedia] {
        let fm = FileManager.default
        let hasAnyMedia = scenes.contains { $0.shots.contains { $0.references.contains {
            $0.videoData != nil || $0.mapVideoData != nil || $0.photoData != nil || $0.mapData != nil } } }
        if hasAnyMedia {
            try fm.createDirectory(at: staging.appendingPathComponent(mediaSubdir, isDirectory: true),
                                   withIntermediateDirectories: true)
        }

        // Writes JPEG bytes into the media folder and returns the page-relative path.
        func writeImage(_ jpeg: Data, name: String) throws -> String {
            let file = "\(mediaSubdir)/\(name).jpg"
            try jpeg.write(to: staging.appendingPathComponent(file))
            return file
        }

        // Compresses an oversized clip, writes it into the episode's media folder,
        // and returns its (page-relative) path plus a poster-frame file.
        func writeWebVideo(_ data: Data, ext: String, name: String) async throws -> (path: String, poster: String?) {
            var outData = data, outExt = ext
            if data.count > Self.gitHubVideoLimit {
                progress.bump()
                let result = await Self.videoForWeb(data: data, ext: ext, maxBytes: Self.gitHubVideoLimit)
                outData = result.data; outExt = result.ext
            }
            let file = "\(mediaSubdir)/\(name).\(outExt)"
            try outData.write(to: staging.appendingPathComponent(file))
            let poster = try Self.posterFrame(fromVideoData: outData, ext: outExt)
                .map { try writeImage($0, name: "\(name)_poster") }
            return (file, poster)
        }

        var rendered: [String: RenderedMedia] = [:]
        for scene in scenes {
            for shot in scene.shots {
                for reference in shot.references {
                    let base = "shot_\(shot.slug)_\(reference.index)"
                    var videoPath: String?
                    var posterURI: String?
                    if let data = reference.videoData {
                        let out = try await writeWebVideo(data, ext: reference.videoExtension, name: "\(base)_video")
                        videoPath = out.path; posterURI = out.poster
                    }
                    var mapVideoPath: String?
                    var mapPosterURI: String?
                    if let mData = reference.mapVideoData {
                        let out = try await writeWebVideo(mData, ext: reference.mapVideoExtension, name: "\(base)_map")
                        mapVideoPath = out.path; mapPosterURI = out.poster
                    }
                    // Reference stills go to files too (transcoded to JPEG for the browser).
                    let photoPath = try reference.photoData
                        .flatMap { Self.jpegData(from: $0) }
                        .map { try writeImage($0, name: "\(base)_photo") }
                    let topDownPath = try reference.mapData
                        .flatMap { Self.jpegData(from: $0) }
                        .map { try writeImage($0, name: "\(base)_maptop") }
                    rendered[Self.mediaKey(shot.slug, reference.index)] = RenderedMedia(
                        photoURI: photoPath,
                        topDownURI: topDownPath,
                        videoPath: videoPath,
                        posterURI: posterURI,
                        mapVideoPath: mapVideoPath,
                        mapPosterURI: mapPosterURI,
                        note: reference.note
                    )
                }
            }
        }

        return rendered
    }

    /// A `buildHTML` asset writer for the publish path: saves each image into the
    /// site's media folder and returns its page-relative URL, so coverage and
    /// scene-map images stay out of `index.html`.
    private static func fileAssetWriter(staging: URL, subdir: String) -> (Data, String) -> String {
        let dir = staging.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return { data, name in
            let file = "\(subdir)/\(name).jpg"
            do {
                try data.write(to: staging.appendingPathComponent(file))
                return file
            } catch {
                return dataURI(data)   // fall back to embedding so the image still shows
            }
        }
    }

    // MARK: - Web video compression

    /// GitHub rejects files over 100 MB. Transcode reference videos larger than
    /// this to a web-friendly H.264 MP4 so a publish can't fail on one big clip.
    /// Kept below 100 MB for headroom (base64 upload, container overhead). If real
    /// uploads ever reject smaller blobs, lower this one constant.
    static let gitHubVideoLimit = 90 * 1_024 * 1_024

    /// Transcodes video data down to an H.264 MP4 that fits under `maxBytes`,
    /// stepping resolution down until it does. Returns the smallest result it
    /// managed (still MP4) even if nothing fit — the caller enforces the hard
    /// limit and reports a clear error for a clip that's simply too long.
    static func videoForWeb(data: Data, ext: String, maxBytes: Int) async -> (data: Data, ext: String) {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("src_\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: src)) != nil else { return (data, ext) }
        defer { try? fm.removeItem(at: src) }

        let asset = AVURLAsset(url: src)
        let presets = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480]
        var smallest: Data?
        for preset in presets {
            guard let out = await Self.transcode(asset: asset, preset: preset) else { continue }
            if smallest == nil || out.count < smallest!.count { smallest = out }
            if out.count <= maxBytes { return (out, "mp4") }
        }
        // Best effort: hand back the smallest transcode if it beat the original.
        if let smallest, smallest.count < data.count { return (smallest, "mp4") }
        return (data, ext)
    }

    private static func transcode(asset: AVURLAsset, preset: String) async -> Data? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        session.shouldOptimizeForNetworkUse = true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            return nil
        }
        return try? Data(contentsOf: out)
    }

    /// Writes "<name>.html" + media/ into a temp folder and zips it to `destination`.
    private func writeHTMLBundle(filmName: String, episodeName: String?, versionName: String?,
                                 scenes: [MediaScene], to destination: URL) throws {
        let fm = FileManager.default
        // Unique parent temp dir containing a nicely-named bundle folder, so the
        // unzipped result is "<Film> - Shot List/" rather than a random UUID.
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleName = webExportBaseName(filmName)
        let staging = parent.appendingPathComponent(bundleName, isDirectory: true)
        let mediaDir = staging.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }

        // Photos are embedded directly in the HTML (as data URIs) so they render
        // reliably on iOS, where the stock viewer won't load sibling image files.
        // Only videos — too large to embed — go in media/, shown as tap-to-play
        // tiles with an extracted poster frame.
        var rendered: [String: RenderedMedia] = [:]
        for scene in scenes {
            for shot in scene.shots {
                for reference in shot.references {
                    func writeVideo(_ data: Data, ext: String, suffix: String) throws -> (String, String?) {
                        let name = "media/shot_\(shot.slug)_\(reference.index)_\(suffix).\(ext)"
                        try data.write(to: staging.appendingPathComponent(name))
                        return (name, Self.posterFrame(fromVideoData: data, ext: ext).map { Self.dataURI($0) })
                    }
                    var videoPath: String?, posterURI: String?
                    if let data = reference.videoData {
                        (videoPath, posterURI) = try writeVideo(data, ext: reference.videoExtension, suffix: "video")
                    }
                    var mapVideoPath: String?, mapPosterURI: String?
                    if let mData = reference.mapVideoData {
                        (mapVideoPath, mapPosterURI) = try writeVideo(mData, ext: reference.mapVideoExtension, suffix: "map")
                    }
                    rendered[Self.mediaKey(shot.slug, reference.index)] = RenderedMedia(
                        photoURI: reference.photoData.map { Self.dataURI($0) },
                        topDownURI: reference.mapData.map { Self.dataURI($0) },
                        videoPath: videoPath,
                        posterURI: posterURI,
                        mapVideoPath: mapVideoPath,
                        mapPosterURI: mapPosterURI,
                        note: reference.note
                    )
                }
            }
        }

        let episode = WebEpisode(title: episodeName, versionName: versionName,
                                 director: resolvedDirector(version?.episode),
                                 cinematographer: resolvedCinematographer(version?.episode),
                                 scenes: scenes, media: rendered, schedule: self.snapshotSchedule())
        let html = Self.buildHTML(filmName: filmName,
                                  productionCompany: project.productionCompany,
                                  episodes: [episode])
        // Named after the shot list rather than index.html, so it's identifiable
        // once unzipped alongside other files.
        try html.data(using: .utf8)?.write(to: staging.appendingPathComponent("\(bundleName).html"))

        try zipDirectory(staging, to: destination)
    }

    /// Zips a directory into `destination` using the system file coordinator
    /// (sandbox-safe, no third-party dependency).
    private func zipDirectory(_ directory: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var innerError: Error?
        coordinator.coordinate(readingItemAt: directory, options: [.forUploading], error: &coordError) { zippedURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: zippedURL, to: destination)
            } catch {
                innerError = error
            }
        }
        if let coordError { throw coordError }
        if let innerError { throw innerError }
    }

    /// Rendered media for one reference, keyed by "<shot slug>#<reference index>".
    private struct RenderedMedia {
        let photoURI: String?    // data:image/jpeg;base64,… (embedded, iOS-safe)
        let topDownURI: String?
        let videoPath: String?   // media/shot_x_1_video.mov
        let posterURI: String?   // data:image/jpeg;base64,… first frame
        var mapVideoPath: String? = nil   // media/shot_x_1_map.mov (map as video)
        var mapPosterURI: String? = nil
        var note: String?        // user caption, shown when the media is opened
    }

    private static func mediaKey(_ shotSlug: String, _ referenceIndex: Int) -> String {
        "\(shotSlug)#\(referenceIndex)"
    }

    /// Transcodes arbitrary image data (incl. HEIC/PNG) to JPEG so it renders in every browser.
    private static func jpegData(from data: Data, quality: CGFloat = 0.85) -> Data? {
        guard let image = PlatformImage(data: data) else { return data }
        return image.jpegRepresentation(quality: quality) ?? data
    }

    private static func dataURI(_ jpeg: Data) -> String {
        "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// Trims a user note and returns nil when it's blank.
    static func cleanNote(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// Extracts a poster frame (~0.5s in) from a video, as JPEG.
    private static func posterFrame(fromVideoData data: Data, ext: String) -> Data? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("poster_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: tmp))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        // Exact seek: otherwise the generator returns the nearest earlier
        // keyframe, which is frame 0 — often black.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cg = (try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil))
            ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
        guard let cg else { return nil }

        return PlatformImage.fromCGImage(cg, size: CGSize(width: cg.width, height: cg.height))
            .jpegRepresentation(quality: 0.8)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// One episode's rendered content for the web page. A feature film is a single
    /// episode; a series publishes several, switched between in-page.
    private struct WebEpisode {
        let title: String?        // episode label (switch button + subtitle); nil for a lone feature
        let versionName: String?
        let director: String      // per-episode credit (already resolved, project fallback applied)
        let cinematographer: String
        let scenes: [MediaScene]
        let media: [String: RenderedMedia]
        let schedule: [MediaScheduleDay]
    }

    /// Resolve an episode's Director / Cinematographer, falling back to the
    /// project-level value when the episode leaves one blank.
    private func resolvedDirector(_ ep: Episode?) -> String {
        let d = ep?.director ?? ""
        return d.isEmpty ? project.director : d
    }
    private func resolvedCinematographer(_ ep: Episode?) -> String {
        let c = ep?.cinematographer ?? ""
        return c.isEmpty ? project.cinematographer : c
    }

    /// Resolves an image to the URL used in the page. Defaults to embedding it as a
    /// data URI (self-contained, needed for the local `file://` export on iOS). The
    /// publish path passes a writer that saves each image as a sibling file and
    /// returns a relative URL, so `index.html` never grows into one oversized blob.
    private static func buildHTML(filmName: String,
                                  productionCompany: String = "",
                                  episodes: [WebEpisode],
                                  assetURL: (Data, String) -> String = { data, _ in ProjectExporter.dataURI(data) }) -> String {
        // Production credits. Production Company is project-level; Director and
        // Cinematographer can vary per episode, so for a series they're rebuilt in
        // the browser when the episode changes (from per-episode data attributes).
        func creditSpan(_ label: String, _ value: String) -> String {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? "" : "<span class=\"credit\"><b>\(esc(label))</b> \(esc(v))</span>"
        }
        func creditsInner(_ ep: WebEpisode?) -> String {
            creditSpan("Production Company", productionCompany)
            + creditSpan("Director", ep?.director ?? "")
            + creditSpan("Cinematographer", ep?.cinematographer ?? "")
        }
        let anyCredits = !productionCompany.trimmingCharacters(in: .whitespaces).isEmpty
            || episodes.contains { !$0.director.trimmingCharacters(in: .whitespaces).isEmpty
                                || !$0.cinematographer.trimmingCharacters(in: .whitespaces).isEmpty }
        let creditsHTML = anyCredits
            ? "<div class=\"credits\" id=\"credits\" data-company=\"\(esc(productionCompany))\">\(creditsInner(episodes.first))</div>"
            : ""

        // The shooting-day view is built in the browser by cloning scene cards per
        // this manifest, so each episode carries its schedule as JSON rather than a
        // second rendered copy of every scene.
        func scheduleJSON(_ schedule: [MediaScheduleDay]) -> String {
            guard !schedule.isEmpty else { return "[]" }
            let days: [[String: Any]] = schedule.map { day in
                ["n": day.number, "notes": day.notes, "date": day.dateLabel, "iso": day.isoDate,
                 "setups": day.setups, "shots": day.shots, "sunrise": day.sunrise, "sunset": day.sunset,
                 "goldenAM": day.goldenAM, "goldenPM": day.goldenPM,
                 "entries": day.entries.map { e -> [String: Any] in
                    ["s": e.sceneIndex, "all": e.allShots, "shots": Array(e.scheduledShotNumbers), "note": e.note] }]
            }
            if let data = try? JSONSerialization.data(withJSONObject: days),
               let str = String(data: data, encoding: .utf8) { return str }
            return "[]"
        }

        let showEpisodeSwitch = episodes.count > 1
        var coverageStyles = ""        // background-image rules; class names are ep-prefixed so episodes can't collide
        var shotSeq = 0                // globally unique id per shot, for its expand checkbox
        var episodeBlocks: [String] = []
        var switchButtons = ""
        var scheduleJSONs: [String] = []
        var episodeSubs: [String] = []   // per-episode "Episode · Version · N scenes · M shots"

        for (e, ep) in episodes.enumerated() {
            let scenes = ep.scenes
            let media = ep.media
            let totalShots = scenes.reduce(0) { $0 + $1.shots.count }
            var body = ""
            var toc = ""
        for (index, scene) in scenes.enumerated() {
            let anchor = "ep\(e)-scene-\(index)"
            // The scene's coverage image is embedded once as a CSS background and
            // shared by every covered shot's thumbnail, rather than inlined N times.
            var coverageClass: String? = nil
            if let cov = scene.coverage {
                let cls = "cov-\(e)-\(index)"
                coverageStyles += "          .\(cls) { background-image: url(\(assetURL(cov.data, "cov_\(e)_\(index)"))); aspect-ratio: \(Int(cov.width)) / \(Int(cov.height)); }\n"
                coverageClass = cls
            }
            // The scene map, embedded once per scene as its own background rule.
            var mapClass: String? = nil
            if let map = scene.map {
                let cls = "map-\(e)-\(index)"
                coverageStyles += "          .\(cls) { background-image: url(\(assetURL(map.data, "map_\(e)_\(index)"))); aspect-ratio: \(Int(map.width)) / \(Int(map.height)); }\n"
                mapClass = cls
            }
            let timeLabel = scene.isDay ? "DAY" : "NIGHT"
            let typeLabel = scene.isInterior ? "INT" : "EXT"

            // Everything the search box should be able to find this scene by.
            let sceneSearch = ([scene.heading, scene.location, typeLabel, timeLabel] + scene.shots.map(\.displayNumber))
                .joined(separator: " ").lowercased()
            let shotCount = scene.shots.count
            let mediaCount = scene.shots.filter { m in
                let r = media[m.slug]
                return r?.photoURI != nil || r?.topDownURI != nil || r?.videoPath != nil || r?.mapVideoPath != nil
            }.count

            toc += "  <a class=\"toc-item\" data-for=\"\(anchor)\" href=\"#\(anchor)\">"
            toc += "<span class=\"toc-num\">\(esc(scene.heading))</span>"
            toc += "<span class=\"toc-loc\">\(esc(scene.location.isEmpty ? scene.subheading : scene.location))</span>"
            toc += "<span class=\"toc-count\">\(shotCount)</span></a>\n"

            // <details> rather than a scripted toggle: collapsing has to work in
            // Apple's Quick Look preview, which renders the page with JavaScript
            // disabled. A heading inside <summary> is phrasing-content only, so the
            // title is a styled span.
            body += "<details class=\"scene\" id=\"\(anchor)\" open data-int=\"\(scene.isInterior ? 1 : 0)\" data-day=\"\(scene.isDay ? 1 : 0)\" data-media=\"\(mediaCount > 0 ? 1 : 0)\" data-text=\"\(esc(sceneSearch))\">\n"
            // The scene's cards (script coverage, blocking map, film report) — now
            // shown inside the header row alongside the text. Each is a <details> that
            // opens full screen; `stopPropagation` keeps a card tap from toggling the
            // scene's own disclosure.
            var cards = ""
            if let cls = coverageClass {
                cards += "      <details class=\"mi mi-doc\"><summary onclick=\"event.stopPropagation()\" title=\"Script with coverage for this scene\"><span class=\"cover-thumb \(cls)\"></span><span class=\"thumb-label\">Coverage</span></summary></details>\n"
            }
            if let cls = mapClass {
                cards += "      <details class=\"mi mi-doc\"><summary onclick=\"event.stopPropagation()\" title=\"Scene map\"><span class=\"cover-thumb is-map \(cls)\"></span><span class=\"thumb-label\">Scene map</span></summary></details>\n"
            }
            if !scene.filmEntries.isEmpty {
                var preview = "<span class=\"rp-title\">Film length</span>"
                for e in scene.filmEntries.prefix(6) {
                    preview += "<span class=\"rp-line\">\(esc("\(e.shot) · \(e.format) · \(e.length)"))</span>"
                }
                cards += "      <details class=\"mi mi-report\"><summary onclick=\"event.stopPropagation()\" title=\"Film length report\"><span class=\"cover-thumb is-report\"><span class=\"report-preview\">\(preview)</span></span><span class=\"thumb-label\">Film</span></summary>\n"
                cards += "        <div class=\"report-panel\"><div class=\"report-card\">\n"
                cards += "        <h3 class=\"report-title\">Film length — \(esc(scene.heading))</h3>\n"
                cards += "        <table class=\"report-table\"><thead><tr><th>Shot</th><th>Format</th><th>fps</th><th>Length</th><th>Time</th></tr></thead><tbody>\n"
                for e in scene.filmEntries {
                    cards += "          <tr><td>\(esc(e.shot))</td><td>\(esc(e.format))</td><td>\(esc(e.fps))</td><td>\(esc(e.length))</td><td>\(esc(e.time))</td></tr>\n"
                }
                cards += "        </tbody></table>\n"
                func totalsTable(_ title: String, _ totals: [(gauge: String, metres: String, time: String)]) {
                    cards += "        <div class=\"report-totals-title\">\(esc(title))</div>\n"
                    cards += "        <table class=\"report-table report-totals\"><tbody>\n"
                    for t in totals {
                        cards += "          <tr><td>\(esc(t.gauge))</td><td>\(esc(t.metres))</td><td>\(esc(t.time))</td></tr>\n"
                    }
                    cards += "        </tbody></table>\n"
                }
                if !scene.filmTotals.isEmpty { totalsTable("Scene totals", scene.filmTotals) }
                if !scene.projectFilmTotals.isEmpty { totalsTable("Project totals", scene.projectFilmTotals) }
                cards += "      </div></div>\n"
                cards += "      </details>\n"
            }

            body += "  <summary class=\"scene-head\">\n"
            body += "    <span class=\"scene-title\">\(esc(scene.heading))</span>\n"
            body += "    <span class=\"tag tag-type\">\(typeLabel)</span>\n"
            body += "    <span class=\"tag \(scene.isDay ? "tag-day" : "tag-night")\">\(timeLabel)</span>\n"
            if !scene.location.isEmpty {
                body += "    <span class=\"scene-loc\">\(esc(scene.location))</span>\n"
            }
            if !cards.isEmpty {
                body += "    <span class=\"scene-media\">\n\(cards)    </span>\n"
            }
            body += "  </summary>\n"
            body += "  <div class=\"shots\">\n"
            if scene.shots.isEmpty {
                body += "    <p class=\"empty\">No shots in this scene.</p>\n"
            }
            for shot in scene.shots {
                let refs = shot.references.map { (r: MediaReference) in (r, media[Self.mediaKey(shot.slug, r.index)]) }
                let hasMedia = refs.contains { $0.1?.photoURI != nil || $0.1?.topDownURI != nil || $0.1?.videoPath != nil || $0.1?.mapVideoPath != nil }
                let shotSearch = ([shot.displayNumber, shot.nickname, shot.coverageText ?? ""]
                                  + shot.details.map { "\($0.label) \($0.value)" })
                    .joined(separator: " ").lowercased()

                // The compact row drops the wordier gear fields (camera, format,
                // lens) and keeps the framing essentials, focal length included.
                // Film length gets its own always-visible chip below, so leave it
                // out of the generic values line.
                let inlineHidden: Set<String> = ["Camera", "Lens", "Framelines", "Film length", "Time of day"]
                let inlineDetails = shot.details.filter { !inlineHidden.contains($0.label) }
                let toggleID = "shot-\(shotSeq)"
                shotSeq += 1

                // A shot is a compact row that expands to its full details. The
                // expand is a pure-CSS checkbox toggle (works with no JS, so it
                // still opens in Quick Look) — unlike a <details>, this lets the row
                // carry its own openable media thumbnails without their clicks
                // fighting the expand.
                body += "    <div class=\"shot\" data-media=\"\(hasMedia ? 1 : 0)\" data-text=\"\(esc(shotSearch))\">\n"
                body += "      <input type=\"checkbox\" class=\"shot-toggle\" id=\"\(toggleID)\">\n"
                body += "      <div class=\"shot-row\">\n"
                // The text part is a <label> for the checkbox, so clicking it (but
                // not the thumbnails) expands the shot.
                body += "        <label class=\"shot-main\" for=\"\(toggleID)\">\n"
                body += "          <span class=\"shot-caret\" aria-hidden=\"true\"></span>\n"
                body += "          <span class=\"shot-num\">\(esc(shot.displayNumber))</span>\n"
                if !shot.nickname.isEmpty { body += "          <span class=\"shot-nick\">\(esc(shot.nickname))</span>\n" }
                if inlineDetails.isEmpty {
                    body += "          <span class=\"si-vals si-empty\">No details</span>\n"
                } else {
                    let inlineVals = inlineDetails.map { esc($0.value) }.joined(separator: " · ")
                    let inlineTitle = inlineDetails.map { "\($0.label): \($0.value)" }.joined(separator: " · ")
                    body += "          <span class=\"si-vals\" title=\"\(esc(inlineTitle))\">\(inlineVals)</span>\n"
                }
                body += "        </label>\n"
                // Openable reference/map thumbnails, inline in the row. Each is its
                // own <details> (independent of the shot's expand), so opening one
                // full screen never expands the shot. Empty when the shot has none.
                body += "        <div class=\"media\">\n"
                for (reference, rendered) in refs {
                    guard let m = rendered else { continue }
                    // Each reference is its own row: media and map side by side,
                    // with the next reference below rather than alongside.
                    body += "          <div class=\"mi-pair\">\n"
                    // Label each thumbnail with its reference number when a shot
                    // carries more than one.
                    let tag = shot.references.count > 1 ? " \(reference.index)" : ""
                    // The user's caption, revealed under the media in the open
                    // fullscreen view (hidden on the thumbnail).
                    let noteHTML = m.note.map { "<figcaption class=\"mi-note\">\(esc($0))</figcaption>" } ?? ""
                    if let video = m.videoPath {
                        let mime = video.hasSuffix(".mov") ? "video/quicktime" : "video/mp4"
                        body += "          <details class=\"mi mi-video\">\n            <summary title=\"Play video\">"
                        if let poster = m.posterURI {
                            body += "<img src=\"\(poster)\" alt=\"Video\">"
                        } else {
                            body += "<span class=\"thumb-blank\"></span>"
                        }
                        body += "<span class=\"play\">▶</span><span class=\"thumb-label\">Video\(tag)</span></summary>\n"
                        body += "            <video controls playsinline preload=\"none\"><source src=\"\(video)\" type=\"\(mime)\"></video>\(noteHTML)\n"
                        body += "          </details>\n"
                    }
                    if let photo = m.photoURI {
                        body += "          <details class=\"mi\"><summary title=\"Reference frame\"><img class=\"still\" src=\"\(photo)\" alt=\"Reference frame\"><span class=\"thumb-label\">Ref\(tag)</span></summary>\(noteHTML)</details>\n"
                    }
                    if let topDown = m.topDownURI {
                        body += "          <details class=\"mi ref-map\"><summary title=\"Top-down plan\"><img class=\"still\" src=\"\(topDown)\" alt=\"Top-down plan\"><span class=\"thumb-label\">Shot map\(tag)</span></summary>\(noteHTML)</details>\n"
                    }
                    if let mapVideo = m.mapVideoPath {
                        let mime = mapVideo.hasSuffix(".mov") ? "video/quicktime" : "video/mp4"
                        body += "          <details class=\"mi mi-video ref-map\">\n            <summary title=\"Play map\">"
                        if let poster = m.mapPosterURI {
                            body += "<img src=\"\(poster)\" alt=\"Map video\">"
                        } else {
                            body += "<span class=\"thumb-blank\"></span>"
                        }
                        body += "<span class=\"play\">▶</span><span class=\"thumb-label\">Shot map\(tag)</span></summary>\n"
                        body += "            <video controls playsinline preload=\"none\"><source src=\"\(mapVideo)\" type=\"\(mime)\"></video>\(noteHTML)\n"
                        body += "          </details>\n"
                    }
                    body += "          </div>\n"
                }
                body += "        </div>\n"          // close .media
                body += "      </div>\n"            // close .shot-row
                // Expanded details, revealed when the shot's checkbox is on, split
                // into two groups: Shot setup and Camera information.
                body += "      <div class=\"shot-body\">\n"
                if shot.details.isEmpty {
                    body += "        <p class=\"empty\">No details.</p>\n"
                } else {
                    let cameraLabels: Set<String> = ["Camera", "Framelines", "Lens", "Film length"]
                    let groups: [(title: String, rows: [(label: String, value: String)])] = [
                        ("Shot setup", shot.details.filter { !cameraLabels.contains($0.label) }),
                        ("Camera information", shot.details.filter { cameraLabels.contains($0.label) })
                    ].filter { !$0.rows.isEmpty }
                    body += "        <div class=\"detail-cols\">\n"
                    for group in groups {
                        body += "          <div class=\"detail-col\">\n"
                        body += "            <div class=\"col-title\">\(esc(group.title))</div>\n"
                        body += "            <div class=\"rows\">\n"
                        for row in group.rows {
                            body += "              <div class=\"row\"><span class=\"k\">\(esc(row.label))</span><span class=\"v\">\(esc(row.value))</span></div>\n"
                        }
                        body += "            </div>\n"
                        body += "          </div>\n"
                    }
                    body += "        </div>\n"          // close .detail-cols
                }
                body += "      </div>\n"            // close .shot-body
                body += "    </div>\n"              // close .shot
            }
            body += "  </div>\n"
            body += "</details>\n"
        }

            // Per-episode subtitle: episode/version name, then scene & shot counts.
            var subtitleBits: [String] = []
            if let t = ep.title { subtitleBits.append(esc(t)) }
            if let v = ep.versionName { subtitleBits.append(esc(v)) }
            subtitleBits.append("\(scenes.count) scene\(scenes.count == 1 ? "" : "s")")
            subtitleBits.append("\(totalShots) shot\(totalShots == 1 ? "" : "s")")

            scheduleJSONs.append(scheduleJSON(ep.schedule))
            let hasSchedule = !ep.schedule.isEmpty
            let subtitle = subtitleBits.joined(separator: " · ")
            episodeSubs.append(subtitle)
            if showEpisodeSwitch {
                switchButtons += "<button class=\"ep-btn\(e == 0 ? " on" : "")\" data-ep=\"\(e)\" type=\"button\">\(esc(ep.title ?? "Episode \(e + 1)"))</button>"
            }

            episodeBlocks.append("""
                    <section class="episode" data-ep="\(e)" data-has-days="\(hasSchedule ? 1 : 0)" data-sub="\(subtitle)" data-director="\(esc(ep.director))" data-cinematographer="\(esc(ep.cinematographer))"\(e == 0 ? "" : " hidden")>
                      <div class="layout">
                        <nav class="toc">
                          <div class="toc-title">Scenes</div>
                    \(toc)      </nav>
                        <main>
                          <div class="view-scenes">
                    \(body)        <div class="noresults" hidden>
                              <p><b>No matching shots.</b></p>
                              <p>Try a different search or clear the filters.</p>
                            </div>
                          </div>
                          <div class="view-days" hidden></div>
                        </main>
                      </div>
                    </section>
                    """)
        }

        let episodesHTML = episodeBlocks.joined(separator: "\n")
        let episodeStripHTML = showEpisodeSwitch
            ? "<div class=\"epstrip\" id=\"epstrip\">\(switchButtons)</div>"
            : ""
        // The subtitle sits under the credits (and, for a series, under the episode
        // pills). For a series it's updated in-browser to the active episode.
        let mastheadSub = episodeSubs.first ?? ""
        let mastheadSubHTML = mastheadSub.isEmpty ? "" : "<div class=\"sub\" id=\"masthead-sub\">\(mastheadSub)</div>"
        let episodesScheduleJSON = "[" + scheduleJSONs.joined(separator: ",") + "]"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(filmName)) — Shot List</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #f2f2f6; --card: #ffffff; --raised: #ffffff;
            --text: #1c1c1e; --muted: #6b6b70; --faint: #9a9aa0;
            --line: rgba(0,0,0,0.09); --line-strong: rgba(0,0,0,0.16);
            --accent: #0a84ff; --night: #ff9500;
            --chip: rgba(0,0,0,0.05); --chip-hover: rgba(0,0,0,0.09);
            --shadow: 0 1px 2px rgba(0,0,0,0.04), 0 4px 14px rgba(0,0,0,0.05);
            --bar: rgba(242,242,246,0.88);
            --sticky: 60px;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #121214; --card: #1d1d1f; --raised: #262629;
              --text: #f2f2f7; --muted: #98989d; --faint: #7c7c80;
              --line: rgba(255,255,255,0.10); --line-strong: rgba(255,255,255,0.18);
              --chip: rgba(255,255,255,0.08); --chip-hover: rgba(255,255,255,0.14);
              --shadow: none; --bar: rgba(18,18,20,0.88);
            }
          }
          * { box-sizing: border-box; }
          /* Pin text at 100% so mobile Safari doesn't inflate shot/body text in landscape. */
          html { scroll-behavior: smooth; -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 margin: 0; background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; }

          /* Masthead */
          .masthead { position: relative; padding: 30px 28px 22px; max-width: 1240px; margin: 0 auto; }
          .masthead h1 { margin: 0 0 6px; font-size: 30px; letter-spacing: -0.4px;
                         display: flex; flex-wrap: wrap; align-items: baseline; column-gap: 12px; row-gap: 2px; }
          /* "Shot List" beside the title, smaller; drops under it when there's no room. */
          .title-tag { font-size: 16px; font-weight: 600; color: var(--muted); letter-spacing: 0; white-space: nowrap; }
          .masthead .sub { color: var(--muted); font-size: 14px; margin-top: 12px; }
          /* Credits sit side by side, wrapping to stacked lines when the window is
             too narrow. Each credit keeps its label+value together (nowrap). */
          .credits { display: flex; flex-wrap: wrap; align-items: baseline; margin-top: 8px;
                     font-size: 13px; color: var(--muted); }
          .credit { white-space: nowrap; }
          .credit:not(:last-child)::after { content: "·"; margin: 0 12px; color: var(--faint); }
          .credit b { color: var(--text); font-weight: 600; }
          .brandline { position: absolute; top: 30px; right: 28px; display: flex; align-items: center;
                       gap: 7px; font-size: 12px; color: var(--muted); }
          .brandline b { color: var(--text); font-weight: 700; }
          .brandlogo { width: 20px; height: 20px; display: block; flex: none;
                       background: #fff; border-radius: 5px; box-shadow: 0 0 0 1px rgba(0,0,0,0.10); }
          /* On phones drop it back into the flow above the title so it can't overlap. */
          @media (max-width: 640px) { .brandline { position: static; margin: 0 0 12px; } }

          /* Episode switcher (series only): individual pills under the credits that
             swap which episode is shown, in-page. The row stays on one line and scrolls
             horizontally when it overflows (e.g. iPhone portrait) rather than wrapping. */
          .epstrip { display: flex; flex-wrap: nowrap; gap: 8px; margin-top: 16px;
                     overflow-x: auto; -webkit-overflow-scrolling: touch;
                     scrollbar-width: none; padding-bottom: 2px; }
          .epstrip::-webkit-scrollbar { display: none; }
          .ep-btn { flex: 0 0 auto; border: 1px solid var(--line-strong); background: var(--card); color: var(--muted);
                    font: inherit; font-size: 13px; font-weight: 600; padding: 7px 14px; border-radius: 999px;
                    cursor: pointer; white-space: nowrap; max-width: 220px; overflow: hidden; text-overflow: ellipsis; }
          .ep-btn:hover { color: var(--text); border-color: var(--muted); }
          .ep-btn.on { background: var(--accent); border-color: var(--accent); color: #fff; }

          /* Sticky filter bar */
          .toolbar { position: sticky; top: 0; z-index: 20; background: var(--bar);
                     backdrop-filter: saturate(180%) blur(14px); -webkit-backdrop-filter: saturate(180%) blur(14px);
                     border-bottom: 1px solid var(--line); }
          .toolbar-inner { max-width: 1240px; margin: 0 auto; padding: 10px 28px;
                           display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
          .search { position: relative; flex: 1 1 120px; min-width: 90px; }
          .search input { width: 100%; font: inherit; font-size: 14px; padding: 8px 32px 8px 32px;
                          border-radius: 9px; border: 1px solid var(--line-strong); background: var(--card);
                          color: var(--text); }
          .search input:focus { outline: 2px solid var(--accent); outline-offset: -1px; border-color: transparent; }
          .search .glass { position: absolute; left: 10px; top: 50%; transform: translateY(-50%);
                           color: var(--faint); font-size: 13px; pointer-events: none; }
          .search .clear { position: absolute; right: 6px; top: 50%; transform: translateY(-50%);
                           border: 0; background: transparent; color: var(--faint); font-size: 17px;
                           cursor: pointer; padding: 2px 6px; line-height: 1; }
          .chips { display: flex; gap: 6px; flex-wrap: wrap; }
          .chip { font: inherit; font-size: 12px; font-weight: 600; padding: 6px 11px; border-radius: 999px;
                  border: 1px solid transparent; background: var(--chip); color: var(--muted); cursor: pointer; }
          .chip:hover { background: var(--chip-hover); }
          .chip.on { background: var(--accent); color: #fff; }
          .chip.on.chip-night { background: var(--night); color: #1c1c1e; }
          .tools { display: flex; align-items: center; gap: 10px; margin-left: auto; }
          .count { font-size: 12px; color: var(--muted); white-space: nowrap; }
          .linkbtn { font: inherit; font-size: 12px; font-weight: 600; background: none; border: 0;
                     color: var(--accent); cursor: pointer; padding: 4px; }

          /* Layout: scene index + shot list */
          .layout { max-width: 1240px; margin: 0 auto; padding: 22px 28px 90px;
                    display: grid; grid-template-columns: 216px minmax(0,1fr); gap: 30px; align-items: start; }
          .toc { position: sticky; top: calc(var(--sticky) + 14px); max-height: calc(100vh - var(--sticky) - 40px);
                 overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
          .toc-title { font-size: 11px; font-weight: 700; letter-spacing: 0.6px; text-transform: uppercase;
                       color: var(--faint); padding: 0 8px 8px; }
          .toc-item { display: flex; align-items: baseline; gap: 8px; padding: 6px 8px; border-radius: 7px;
                      text-decoration: none; color: var(--text); font-size: 13px; }
          .toc-item:hover { background: var(--chip); }
          .toc-item.active { background: rgba(10,132,255,0.14); }
          .toc-num { font-weight: 600; white-space: nowrap; }
          .toc-loc { color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .toc-count { margin-left: auto; color: var(--faint); font-size: 11px; font-variant-numeric: tabular-nums; }
          @media (max-width: 980px) { .layout { grid-template-columns: minmax(0,1fr); } .toc { display: none; } }

          /* Scenes */
          .scene { margin-bottom: 46px; scroll-margin-top: calc(var(--sticky) + 16px); }
          .scene-head { display: flex; align-items: flex-end; gap: 9px; flex-wrap: wrap; cursor: pointer;
                        padding-bottom: 10px; margin-bottom: 16px; border-bottom: 1px solid var(--line-strong);
                        list-style: none; -webkit-tap-highlight-color: transparent; }
          .scene-head::-webkit-details-marker { display: none; }
          .scene-head::marker { content: ""; }
          .scene-head:focus { outline: none; }
          .scene-title { font-size: 19px; font-weight: 700; letter-spacing: -0.2px; }
          /* Our own disclosure arrow, since the native marker is hidden. */
          .scene-head::before { content: "▾"; font-size: 12px; color: var(--faint); width: 14px;
                                flex: none; transition: transform 0.15s ease; }
          .scene:not([open]) > .scene-head { margin-bottom: 0; }
          .scene:not([open]) > .scene-head::before { transform: rotate(-90deg); }
          .tag { font-size: 10px; font-weight: 700; letter-spacing: 0.6px; padding: 3px 7px; border-radius: 5px; }
          .tag-type { background: var(--chip); color: var(--muted); }
          .tag-day { background: rgba(10,132,255,0.16); color: var(--accent); }
          .tag-night { background: rgba(255,149,0,0.20); color: #b06a00; }
          @media (prefers-color-scheme: dark) { .tag-night { color: var(--night); } }
          .scene-loc { font-size: 13px; color: var(--muted); }
          .scene-count { margin-left: auto; font-size: 12px; color: var(--faint); }

          /* Shots — a compact one-row summary with inline, openable thumbnails,
             expanding to its detail rows. The expand is a pure-CSS checkbox
             toggle, so it works with no JS (and in Quick Look). */
          .shot { background: var(--card); border: 1px solid var(--line); border-radius: 14px;
                  box-shadow: var(--shadow); }
          .shot + .shot { margin-top: 8px; }
          .shot-toggle { position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none; }
          .shot-row { display: flex; align-items: center; gap: 7px 12px; padding: 9px 10px 9px 14px; }
          /* The clickable text part expands the shot; the thumbnails don't. */
          .shot-main { display: flex; align-items: center; gap: 7px 12px; flex: 1 1 auto;
                       min-width: 0; cursor: pointer; -webkit-tap-highlight-color: transparent; }
          .shot-caret { flex: none; width: 12px; font-size: 11px; color: var(--faint);
                        transition: transform 0.12s ease; }
          .shot-caret::before { content: "▸"; }
          .shot-toggle:checked ~ .shot-row .shot-caret { transform: rotate(90deg); }
          .shot-toggle:focus-visible ~ .shot-row .shot-main { outline: 2px solid var(--accent);
                        outline-offset: 3px; border-radius: 8px; }
          .shot-num { font-weight: 700; font-size: 13px; padding: 3px 9px; border-radius: 6px;
                      background: var(--chip); font-variant-numeric: tabular-nums; flex: none; }
          .shot-nick { color: var(--text); font-size: 14px; font-weight: 700; flex: none; }
          .si-vals { color: var(--muted); font-size: 12.5px; white-space: nowrap;
                     overflow: hidden; text-overflow: ellipsis; min-width: 0; flex: 1 1 160px; }
          .si-empty { font-style: italic; color: var(--faint); }
          /* Inline thumbnails, pushed to the right of the row and shrunk. */
          .media { display: flex; flex-direction: row; flex-wrap: wrap; gap: 6px;
                   flex: none; margin-left: auto; justify-content: flex-end; align-items: flex-start; }
          .media:empty { display: none; }
          .shot-row .media .mi:not([open]) > summary { display: flex; flex-direction: column;
                   align-items: center; gap: 2px; width: 46px; }
          .shot-row .media .mi:not([open]) .thumb-label { display: none; text-align: center; line-height: 1.15; }
          .shot-toggle:checked ~ .shot-row .media .mi:not([open]) .thumb-label { display: block; }
          .shot-row .media .mi:not([open]) > summary img,
          .shot-row .media .mi:not([open]) .thumb-blank { width: 46px; height: 32px; }
          .shot-row .media .mi:not([open]) .play { top: 16px; width: 18px; height: 18px; font-size: 8px; }
          /* The reference map is hidden in the collapsed row and appears only when the
             shot is expanded. */
          .shot-row .media .ref-map { display: none; }
          .shot-toggle:checked ~ .shot-row .media .ref-map { display: block; }
          /* Expanded detail rows, revealed by the checkbox; indented under the row. */
          .shot-body { display: none; padding: 4px 15px 13px 40px; }
          .shot-toggle:checked ~ .shot-body { display: block; }
          /* One reference: its photo/video and map side by side. */
          .mi-pair { display: flex; flex-direction: row; gap: 6px; }
          /* Closed: a 94px thumbnail. Open: a full-screen viewer. Driven entirely by
             the <details> element so it works without JavaScript. */
          .mi > summary { position: relative; display: block; width: 94px; cursor: zoom-in;
                          list-style: none; -webkit-tap-highlight-color: transparent; }
          .mi > summary::-webkit-details-marker { display: none; }
          .mi > summary::marker { content: ""; }
          .mi > summary:focus { outline: none; }
          .mi > summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 9px; }
          .mi > summary img, .thumb-blank { display: block; width: 94px; height: 66px; object-fit: cover;
                                            border-radius: 8px; border: 1px solid var(--line); background: #000; }
          .mi > summary:hover img { border-color: var(--accent); }
          .mi > video { display: none; }
          .thumb-label { display: block; font-size: 10px; color: var(--faint); margin-top: 3px;
                         text-align: center; letter-spacing: 0.2px; }
          .play { position: absolute; left: 50%; top: 33px; transform: translate(-50%,-50%);
                  width: 26px; height: 26px; border-radius: 50%; background: rgba(0,0,0,0.55);
                  color: #fff; font-size: 10px; display: flex; align-items: center; justify-content: center; }

          /* Expanded viewer */
          .mi[open] { position: fixed; inset: 0; z-index: 60; background: rgba(0,0,0,0.93);
                      display: flex; align-items: center; justify-content: center; padding: 20px; }
          .mi[open] > summary { position: absolute; inset: 0; width: auto; cursor: zoom-out; }
          .mi[open] > summary img { position: absolute; left: 50%; top: 50%;
                                    transform: translate(-50%,-50%); width: auto; height: auto;
                                    max-width: 96vw; max-height: 92vh; object-fit: contain;
                                    border-radius: 6px; border: 0; }
          .mi[open] > summary .thumb-label, .mi[open] > summary .play { display: none; }
          .mi-video[open] > summary img { display: none; }
          .mi-video[open] > video { display: block; position: relative; z-index: 1;
                                    max-width: 96vw; max-height: 92vh; border-radius: 6px; }
          /* Reference caption: hidden on the thumbnail, shown along the bottom of
             the open fullscreen viewer. */
          .mi-note { display: none; }
          .mi[open] > .mi-note { display: block; position: absolute; z-index: 2;
                                 left: 0; right: 0; bottom: 0; margin: 0;
                                 padding: 14px 20px calc(14px + env(safe-area-inset-bottom));
                                 text-align: center; color: #fff; font-size: 14px; line-height: 1.4;
                                 text-shadow: 0 1px 3px rgba(0,0,0,0.6);
                                 background: linear-gradient(to top, rgba(0,0,0,0.65), rgba(0,0,0,0)); }
          /* The scene's coverage + map thumbnails, shown once under the header. */
          .scene-coverage { display: flex; flex-wrap: wrap; gap: 14px; margin-bottom: 20px; }
          /* Same cards, folded into the scene header row: small thumbnails with a
             label underneath, pushed to the right of the title. */
          .scene-media { display: flex; align-items: flex-start; gap: 12px; margin-left: auto; }
          /* A collapsed scene hides its cards too, leaving just the heading row. */
          .scene:not([open]) > .scene-head .scene-media { display: none; }
          .scene-media .cover-thumb { width: 76px; height: 46px; }
          .scene-media .mi > summary { display: flex; flex-direction: column; align-items: center; gap: 2px; }
          .scene-media .thumb-label { display: block; margin-top: 0; }
          .scene-media .mi-doc > summary,
          .scene-media .mi-report > summary { width: auto; }
          /* Portrait phone: the scene cards drop onto their own line under the
             heading, left-aligned to start where "Scene x" does (past the caret),
             rather than pinned to the right as on wider screens. */
          @media (max-width: 640px) and (orientation: portrait) {
            .scene-media { margin-left: 0; width: 100%; box-sizing: border-box;
                           padding-left: 23px; justify-content: flex-start; }
          }
          /* The map is landscape, so show the whole thing (letterboxed) rather
             than the top crop the tall script page uses. */
          .cover-thumb.is-map { background-size: contain; background-position: center;
                                background-color: var(--chip); }
          /* Coverage thumbnail: a wide 16:9 crop of the script page's top. The
             image and its aspect ratio come from a per-scene rule (.cov-N) so the
             JPEG is embedded once, not per covered shot. */
          .cover-thumb { display: block; width: 120px; height: 68px; border-radius: 6px;
                         border: 1px solid var(--line); background-color: #fff;
                         background-size: 100% auto; background-repeat: no-repeat; background-position: top center; }
          /* Open: a scrollable dark overlay showing the pages at a readable width;
             the element's aspect-ratio (from .cov-N) gives it its full height, so
             a tall multi-page image scrolls rather than shrinking to fit. */
          .mi-doc[open] { display: block; overflow: auto; padding: 24px 0; }
          .mi-doc[open] > summary { position: static; inset: auto; display: block; cursor: zoom-out; }
          .mi-doc[open] > summary .cover-thumb { width: min(1000px, 94vw); height: auto;
                                    margin: 0 auto; border: 0; border-radius: 4px;
                                    background-size: 100% auto; background-position: top center; }
          .mi-doc > summary { width: 120px; }
          .mi-doc[open] > summary .thumb-label { display: none; }

          /* Film-length report: a thumbnail tile that opens an embedded stats
             panel (text, not an image). */
          .mi-report > summary { width: 120px; }
          /* The report thumbnail is a tiny text preview of the report itself. */
          .cover-thumb.is-report { background: var(--card); background-image: none;
                                   overflow: hidden; padding: 6px 7px; }
          .report-preview { display: flex; flex-direction: column; gap: 1px; text-align: left; }
          .rp-title { font-size: 7px; font-weight: 700; color: var(--text); margin-bottom: 1px;
                      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .rp-line { font-size: 6px; line-height: 1.4; color: var(--muted); white-space: nowrap;
                     overflow: hidden; text-overflow: ellipsis; font-variant-numeric: tabular-nums; }
          .report-panel { display: none; }
          .mi-report[open] > summary { position: absolute; inset: 0; width: auto; cursor: zoom-out; }
          .mi-report[open] > summary .cover-thumb,
          .mi-report[open] > summary .thumb-label { display: none; }
          .mi-report[open] > .report-panel { display: block; position: relative; z-index: 1;
                                             width: min(640px, 92vw); max-height: 88vh; overflow: auto; }
          .report-card { background: var(--card); color: var(--text); border-radius: 12px;
                         padding: 20px 22px; box-shadow: 0 12px 48px rgba(0,0,0,0.45); }
          .report-title { font-size: 16px; font-weight: 700; margin: 0 0 14px; }
          .report-table { width: 100%; border-collapse: collapse; font-size: 13px; }
          .report-table th { text-align: left; color: var(--faint); font-weight: 600; font-size: 10px;
                             text-transform: uppercase; letter-spacing: 0.5px; padding: 4px 12px 5px 0;
                             border-bottom: 1px solid var(--line-strong); }
          .report-table td { padding: 6px 12px 6px 0; border-bottom: 1px solid var(--line);
                             font-variant-numeric: tabular-nums; }
          .report-table td:first-child { font-weight: 600; }
          .report-totals-title { font-size: 10px; font-weight: 700; text-transform: uppercase;
                                 letter-spacing: 0.5px; color: var(--faint); margin: 18px 0 6px; }
          .report-totals td { font-weight: 600; }
          .nomedia { width: 94px; height: 66px; display: flex; align-items: center; justify-content: center;
                     color: var(--faint); border: 1px dashed var(--line-strong); border-radius: 8px; font-size: 13px; }
          .details { min-width: 0; }
          /* Expanded details split into two groups: Shot setup | Camera info.
             Side by side with a vertical divider when there's room; stacked with
             a horizontal divider when there isn't (e.g. on a phone). */
          .detail-cols { display: flex; align-items: stretch; }
          .detail-col { flex: 1 1 0; min-width: 0; }
          .detail-col + .detail-col { border-left: 1px solid var(--line); margin-left: 24px; padding-left: 24px; }
          .col-title { font-size: 10px; font-weight: 700; letter-spacing: 0.6px; text-transform: uppercase;
                       color: var(--faint); margin-bottom: 8px; }
          @media (max-width: 640px) {
            .detail-cols { display: block; }
            .detail-col + .detail-col { border-left: 0; margin-left: 0; padding-left: 0;
                                        border-top: 1px solid var(--line); margin-top: 12px; padding-top: 12px; }
          }
          /* Within a group, rows read straight down one column. */
          .rows { column-width: auto; }
          .row { display: grid; grid-template-columns: 96px minmax(0,1fr); gap: 10px; padding: 5px 0;
                 border-bottom: 1px solid var(--line); font-size: 13px; break-inside: avoid; }
          .k { color: var(--muted); }
          .v { font-weight: 600; overflow-wrap: anywhere; }
          .coverage { margin-top: 12px; font-size: 13px; background: var(--chip); border-radius: 9px; padding: 10px 12px; }
          .coverage > summary { cursor: pointer; list-style: none; display: flex; align-items: center; gap: 6px;
                                -webkit-tap-highlight-color: transparent; }
          .coverage > summary::-webkit-details-marker { display: none; }
          .coverage > summary::marker { content: ""; }
          .coverage > summary::before { content: "▾"; font-size: 10px; color: var(--faint);
                                        transition: transform 0.15s ease; }
          .coverage:not([open]) > summary::before { transform: rotate(-90deg); }
          /* Coverage text and its thumbnail side by side. */
          .coverage-row { display: flex; gap: 12px; align-items: flex-start; margin-top: 12px; }
          .coverage-row .coverage { margin-top: 0; flex: 1 1 auto; min-width: 0; }
          .coverage-row .mi-doc { flex: none; }
          .coverage-preview { font-size: 12px; color: var(--muted); font-weight: 400;
                              text-transform: none; letter-spacing: 0; min-width: 0;
                              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          /* The preview is a stand-in for the text, so it goes once the text is shown. */
          .coverage[open] > summary > .coverage-preview { display: none; }
          .coverage-text { margin-top: 8px; }
          .coverage-label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.6px;
                            color: var(--faint); font-weight: 600; }
          .empty { color: var(--faint); font-size: 13px; font-style: italic; }

          .page-note { max-width: 1240px; margin: 0 auto; padding: 11px 16px; font-size: 13px; color: var(--muted);
                 background: rgba(10,132,255,0.08);
                 border: 1px solid rgba(10,132,255,0.22); border-radius: 9px; }
          .page-note-wrap { max-width: 1240px; margin: 0 auto; padding: 0 28px; }

          .noresults { text-align: center; color: var(--muted); padding: 60px 20px; }
          .noresults b { color: var(--text); }

          .totop { position: fixed; right: 20px; bottom: 20px; z-index: 30; width: 40px; height: 40px;
                   border-radius: 50%; border: 1px solid var(--line-strong); background: var(--card);
                   color: var(--text); font-size: 15px; cursor: pointer; box-shadow: var(--shadow); }
          [hidden] { display: none !important; }

          @media print {
            .toolbar, .toc, .totop, .disclose, .page-note { display: none !important; }
            .layout { grid-template-columns: 1fr; padding: 0; }
            .shot { break-inside: avoid; box-shadow: none; }
            /* Expand every shot so nothing collapses off the printed page. */
            .shot-caret { display: none; }
            .shot-body { display: block !important; }
            .scene { break-inside: avoid-page; }
            body { background: #fff; }
          }
          /* Shooting-day view */
          .viewtoggle { display: inline-flex; gap: 2px; background: var(--chip); border-radius: 9px; padding: 2px; flex: 0 0 auto; }
          /* Narrow screens (e.g. iPhone portrait): a zero-height full-width break
             forces the search + filters onto the row below the view switch, while the
             switch keeps its natural (non-stretched) width. */
          .tb-break { display: none; flex-basis: 100%; height: 0; }
          @media (max-width: 640px) {
            .tb-break { display: block; }
            /* Below the switch: search + all four filter chips share one row, so the
               search shrinks small enough that the chips don't wrap. */
            .search { flex: 1 1 56px; min-width: 52px; }
            .search input { padding-left: 28px; padding-right: 10px; }
          }
          .vt { border: 0; background: transparent; color: var(--muted); font: inherit; font-size: 13px; font-weight: 600;
                padding: 5px 12px; border-radius: 7px; cursor: pointer; }
          .vt.on { background: var(--accent); color: #fff; }
          .day-group { margin: 24px 0 8px; scroll-margin-top: calc(var(--sticky) + 16px); }
          /* Nest each day's scenes (and their shots) under the day header. */
          .day-group > .scene, .day-group > .empty { margin-left: 24px; }
          /* Narrow / portrait phone: no indent — scenes start flush with the day header. */
          @media (max-width: 640px) { .day-group > .scene, .day-group > .empty { margin-left: 0; } }
          /* The day header sticks below the toolbar while its day scrolls, until the
             next day's header pushes it up (sticky within each .day-group). */
          .day-title { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 10px; font-size: 20px; font-weight: 800;
                margin: 0 0 8px; padding: 8px 0 6px; border-bottom: 2px solid var(--accent);
                position: sticky; top: var(--sticky); z-index: 10; background: var(--bg);
                /* Fill the sliver between the toolbar and the header while stuck. */
                box-shadow: 0 -12px 0 var(--bg); }
          .day-date { font-size: 13px; font-weight: 600; color: var(--muted); }
          .day-title .sun-tags { margin: 0 0 0 auto; }
          /* text-size-adjust:100% stops mobile Safari inflating these text blocks
             when the phone is in landscape (they look fine in portrait). */
          .day-meta { font-size: 13px; font-weight: 600; color: var(--muted); margin: -3px 0 30px;
                      -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
          /* The day's free-text note, shown under the header. Preserves line breaks. */
          .day-note { font-size: 14px; color: var(--text); line-height: 1.5; white-space: pre-wrap;
                      margin: -16px 0 30px; padding: 12px 14px; background: var(--chip);
                      border: 1px solid var(--line); border-radius: 10px;
                      -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
          .sun-tags { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 14px; }
          .sun-tag { font-size: 12px; padding: 3px 10px; border-radius: 999px;
                     background: rgba(10,132,255,0.10); color: var(--muted); white-space: nowrap; }
          .sun-tag b { color: var(--text); font-weight: 700; margin-right: 5px; }
          .sun-tag.golden { background: rgba(255,170,0,0.16); }
          .sun-tag.golden b { color: #a86a00; }
          @media (prefers-color-scheme: dark) { .sun-tag.golden b { color: #f0b84a; } }
          .today-badge { font-size: 11px; font-weight: 700; letter-spacing: 0.4px; color: #fff;
                background: var(--accent); padding: 2px 8px; border-radius: 999px; }
          .strip-note { font-size: 13px; color: var(--muted); font-style: italic; margin: 2px 0 8px; }
          .shot.shot-off { opacity: 0.4; }
          .shot-off-msg { font-size: 11px; font-style: italic; color: var(--muted); margin-left: 8px; }
          /* Tighten the top of the day view: less space under the switch and above
             the first day header (the space scrolls away once the header pins). */
          .days-mode .layout { grid-template-columns: minmax(0,1fr); padding-top: 10px; }
          .days-mode .toolbar-inner { padding-top: 8px; padding-bottom: 8px; }
          .view-days .day-group:first-child { margin-top: 0; }
          .days-mode .toc { display: none; }
          .days-mode .search, .days-mode .chips, .days-mode #reset, .days-mode #toggleall, .days-mode .count { display: none; }
          /* With the search/chips hidden in day view, the phone-portrait line break
             would leave an empty wrapped row (and its row-gap) under the switch. */
          .days-mode .tb-break { display: none; }
        \(coverageStyles)</style>
        </head>
        <body>
        <div class="masthead">
          <div class="brandline">
            <svg class="brandlogo" xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 100 100" aria-hidden="true">
              <defs><linearGradient id="cpg" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#3ECFFF"></stop><stop offset="1" stop-color="#1A4AFF"></stop></linearGradient></defs>
              <rect x="11.6" y="15.6" width="76.4" height="12.2" rx="6.1" fill="url(#cpg)"></rect>
              <rect x="11.6" y="34.1" width="61.9" height="12.2" rx="6.1" fill="url(#cpg)"></rect>
              <rect x="11.6" y="52.6" width="70.3" height="12.2" rx="6.1" fill="url(#cpg)"></rect>
              <rect x="11.6" y="71.1" width="48.1" height="12.2" rx="6.1" fill="url(#cpg)"></rect>
            </svg>
            <span>Made with <b>CinePlanner</b></span>
          </div>
          <h1>\(esc(filmName)) <span class="title-tag">Shot List</span></h1>
          \(creditsHTML)
          \(episodeStripHTML)
          \(mastheadSubHTML)
        </div>

        <noscript>
          <div class="page-note-wrap"><div class="page-note">
            <b>Tip:</b> tap a thumbnail to enlarge it, and tap a scene heading to collapse it.
            Search and filtering need a full browser — open this file in Safari or Documents
            by Readdle rather than the Files preview.
          </div></div>
        </noscript>

        <!-- Hidden until the script shows it: search and filters can't work in a
             preview that has JavaScript switched off, and a dead search box is
             worse than none. -->
        <div class="toolbar" id="toolbar" hidden>
          <div class="toolbar-inner">
            <div class="viewtoggle" id="viewtoggle">
              <button class="vt on" id="vt-scenes" type="button">Scenes</button>
              <button class="vt" id="vt-days" type="button">Shooting days</button>
            </div>
            <div class="tb-break"></div>
            <div class="search">
              <span class="glass">⌕</span>
              <input id="q" type="search" placeholder="Search" autocomplete="off">
              <button class="clear" id="clearq" type="button" aria-label="Clear search" hidden>×</button>
            </div>
            <div class="chips">
              <button class="chip" data-group="type" data-value="int" type="button">INT</button>
              <button class="chip" data-group="type" data-value="ext" type="button">EXT</button>
              <button class="chip" data-group="time" data-value="day" type="button">Day</button>
              <button class="chip chip-night" data-group="time" data-value="night" type="button">Night</button>
            </div>
            <div class="tools">
              <span class="count" id="count"></span>
              <button class="linkbtn" id="reset" type="button" hidden>Reset</button>
              <button class="linkbtn" id="toggleall" type="button">Collapse all</button>
            </div>
          </div>
        </div>

        <div class="episodes">
        \(episodesHTML)
        </div>

        <button class="totop" id="totop" type="button" aria-label="Back to top" hidden>↑</button>

        <script>var CP_EPISODES = \(episodesScheduleJSON).map(function (s) { return { schedule: s }; });</script>
        <script>
        (function () {
          function qsa(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }
          var q = document.getElementById('q');
          var clearq = document.getElementById('clearq');
          var countEl = document.getElementById('count');
          var resetEl = document.getElementById('reset');
          var toggleAll = document.getElementById('toggleall');
          var chips = qsa('.chip');
          var active = { type: null, time: null, media: false };
          // Episodes live in one page; a series switches which is shown (feature = 1).
          var episodeEls = qsa('.episode');
          var current = 0;
          var daysView = false;
          function ep() { return episodeEls[current]; }

          // Reveal the filter bar only now that we know scripting is available.
          var toolbarEl = document.getElementById('toolbar');
          toolbarEl.hidden = false;

          // Keep --sticky in step with the real toolbar height. On narrow phones the
          // toolbar wraps to two rows and grows past its 60px default; without this
          // the stuck "Day N" header tucks under it and its top text is clipped.
          function syncSticky() {
            var h = toolbarEl.offsetHeight;
            if (h > 0) document.documentElement.style.setProperty('--sticky', h + 'px');
          }
          syncSticky();
          window.addEventListener('resize', syncSticky);
          window.addEventListener('orientationchange', function () { setTimeout(syncSticky, 200); });

          // Shooting-day view: built on demand by cloning scene cards per the episode's
          // schedule, so scenes split across days show whole (off-day shots greyed out).
          var uid = 0;
          // Shooting-day view for one episode: clone its scene cards per its schedule.
          function buildDays(epEl, idx) {
            if (epEl.dataset.daysBuilt) return;
            epEl.dataset.daysBuilt = '1';
            var container = epEl.querySelector('.view-days');
            var sceneNodes = qsa('.view-scenes .scene', epEl);
            var schedule = (CP_EPISODES[idx] && CP_EPISODES[idx].schedule) || [];
            schedule.forEach(function (day) {
              var sec = document.createElement('section');
              sec.className = 'day-group';
              sec.id = 'day-' + day.n;
              if (day.iso) sec.setAttribute('data-date', day.iso);
              if (day.iso && day.iso === todayISO()) sec.classList.add('is-today');
              var h = document.createElement('div');
              h.className = 'day-title';
              h.innerHTML = '<span class="day-n">Day ' + day.n + '</span>' +
                (day.date ? '<span class="day-date">' + day.date + '</span>' : '') +
                (day.iso && day.iso === todayISO() ? '<span class="today-badge">Today</span>' : '');
              if (day.sunrise) {
                var tags = document.createElement('div');
                tags.className = 'sun-tags';
                function tag(label, val, golden) {
                  return '<span class="sun-tag' + (golden ? ' golden' : '') + '">' +
                    '<b>' + label + '</b>' + val + '</span>';
                }
                tags.innerHTML =
                  tag('Sunrise', day.sunrise, false) +
                  tag('Golden', day.goldenAM, true) +
                  tag('Golden', day.goldenPM, true) +
                  tag('Sunset', day.sunset, false);
                h.appendChild(tags);
              }
              sec.appendChild(h);
              var meta = document.createElement('div');
              meta.className = 'day-meta';
              meta.textContent = day.setups + ' scene' + (day.setups === 1 ? '' : 's') +
                ' · ' + day.shots + ' shot' + (day.shots === 1 ? '' : 's');
              sec.appendChild(meta);
              if (day.notes) {
                var note = document.createElement('div');
                note.className = 'day-note';
                note.textContent = day.notes;
                sec.appendChild(note);
              }
              if (!day.entries.length) {
                var p = document.createElement('p'); p.className = 'empty';
                p.textContent = 'No scenes scheduled.'; sec.appendChild(p);
              }
              day.entries.forEach(function (entry) {
                var src = sceneNodes[entry.s];
                if (!src) return;
                var node = src.cloneNode(true);
                node.removeAttribute('id');
                uid++;
                // Re-id the pure-CSS expand checkboxes so their labels still toggle.
                Array.prototype.forEach.call(node.querySelectorAll('.shot-toggle'), function (box) {
                  var lab = node.querySelector('label[for="' + box.id + '"]');
                  var newId = box.id + '-d' + uid;
                  box.id = newId;
                  if (lab) lab.setAttribute('for', newId);
                });
                // Optional strip note under the scene heading.
                if (entry.note) {
                  var nb = document.createElement('div');
                  nb.className = 'strip-note';
                  nb.textContent = entry.note;
                  var head = node.querySelector('.scene-head');
                  if (head && head.nextSibling) node.insertBefore(nb, head.nextSibling);
                  else node.appendChild(nb);
                }
                // Grey the shots not scheduled for this day.
                if (!entry.all) {
                  var wanted = {};
                  entry.shots.forEach(function (n) { wanted[n] = true; });
                  Array.prototype.forEach.call(node.querySelectorAll('.shot'), function (shot) {
                    var numEl = shot.querySelector('.shot-num');
                    var num = numEl ? numEl.textContent.trim() : '';
                    if (!wanted[num]) {
                      shot.classList.add('shot-off');
                      var main = shot.querySelector('.shot-main');
                      if (main) {
                        var msg = document.createElement('span');
                        msg.className = 'shot-off-msg';
                        msg.textContent = 'Not scheduled for this day';
                        main.appendChild(msg);
                      }
                    }
                  });
                }
                sec.appendChild(node);
              });
              container.appendChild(sec);
            });
          }

          function todayISO() {
            var d = new Date();
            function p(n) { return (n < 10 ? '0' : '') + n; }
            return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
          }
          function scrollToToday(epEl) {
            var el = epEl.querySelector('.view-days [data-date="' + todayISO() + '"]');
            if (!el) return;
            // Land the day header flush under the sticky toolbar (scrollIntoView would
            // add the day-group's scroll-margin, stopping short of the header).
            requestAnimationFrame(function () {
              var sticky = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sticky')) || 0;
              var y = window.scrollY + el.getBoundingClientRect().top - sticky;
              window.scrollTo({ top: Math.max(0, y) });
            });
          }

          var vtScenes = document.getElementById('vt-scenes');
          var vtDays = document.getElementById('vt-days');
          var viewtoggle = document.getElementById('viewtoggle');
          // Show the active episode in the chosen view; hide the day switch for an
          // episode that has no shooting schedule.
          function applyView() {
            var epEl = ep();
            var hasDays = epEl.getAttribute('data-has-days') === '1';
            if (viewtoggle) viewtoggle.hidden = !hasDays;
            var days = daysView && hasDays;
            if (days) buildDays(epEl, current);
            epEl.querySelector('.view-scenes').hidden = days;
            epEl.querySelector('.view-days').hidden = !days;
            document.body.classList.toggle('days-mode', days);
            // The toolbar shrinks in day view (search/chips hidden) — re-measure so
            // --sticky (the sticky day-header offset and the scroll target) is right.
            syncSticky();
            if (vtScenes) vtScenes.classList.toggle('on', !days);
            if (vtDays) vtDays.classList.toggle('on', days);
            if (days) scrollToToday(epEl);
          }
          function setView(days) { daysView = days; applyView(); }
          if (vtDays) vtDays.addEventListener('click', function () { setView(true); });
          if (vtScenes) vtScenes.addEventListener('click', function () { setView(false); });

          function tocFor(id) {
            var items = qsa('.toc-item');
            for (var i = 0; i < items.length; i++) {
              if (items[i].getAttribute('data-for') === id) return items[i];
            }
            return null;
          }

          function apply() {
            var term = q.value.trim().toLowerCase();
            var shownScenes = 0, shownShots = 0, totalShots = 0;
            var scenes = qsa('.view-scenes .scene', ep());

            scenes.forEach(function (scene) {
              var isInt = scene.getAttribute('data-int') === '1';
              var isDay = scene.getAttribute('data-day') === '1';
              var sceneText = scene.getAttribute('data-text') || '';
              var sceneMatches = term === '' || sceneText.indexOf(term) !== -1;

              // Scene-level filters
              var passes = true;
              if (active.type === 'int' && !isInt) passes = false;
              if (active.type === 'ext' && isInt) passes = false;
              if (active.time === 'day' && !isDay) passes = false;
              if (active.time === 'night' && isDay) passes = false;

              var shots = Array.prototype.slice.call(scene.querySelectorAll('.shot'));
              totalShots += shots.length;
              var visibleHere = 0;

              shots.forEach(function (shot) {
                var ok = passes;
                if (ok && active.media && shot.getAttribute('data-media') !== '1') ok = false;
                // A scene matching by name shows all of its shots; otherwise the
                // shot has to match the term itself.
                if (ok && term !== '' && !sceneMatches) {
                  var shotText = shot.getAttribute('data-text') || '';
                  if (shotText.indexOf(term) === -1) ok = false;
                }
                shot.hidden = !ok;
                if (ok) visibleHere++;
              });

              // Keep an empty scene visible only when nothing shot-specific is filtering.
              var shotFilterActive = active.media || term !== '';
              var show = passes && (visibleHere > 0 || (!shotFilterActive && shots.length === 0) ||
                                    (sceneMatches && !active.media && shots.length === 0));
              scene.hidden = !show;

              var item = tocFor(scene.id);
              if (item) item.hidden = !show;

              if (show) { shownScenes++; shownShots += visibleHere; }
            });

            var filtering = term !== '' || active.type || active.media || active.time;
            // The unfiltered total lives in the masthead subtitle; here we only show
            // the match count while filtering.
            countEl.textContent = filtering
              ? shownScenes + ' of ' + scenes.length + ' scenes · ' + shownShots + ' of ' + totalShots + ' shots'
              : '';
            resetEl.hidden = !filtering;
            clearq.hidden = term === '';
            var nr = ep().querySelector('.noresults');
            if (nr) nr.hidden = shownScenes !== 0;
          }

          q.addEventListener('input', apply);
          clearq.addEventListener('click', function () { q.value = ''; apply(); q.focus(); });

          chips.forEach(function (chip) {
            chip.addEventListener('click', function () {
              var group = chip.getAttribute('data-group');
              var value = chip.getAttribute('data-value');
              if (group === 'media') {
                active.media = !active.media;
              } else {
                active[group] = active[group] === value ? null : value;
              }
              chips.forEach(function (other) {
                var g = other.getAttribute('data-group');
                var v = other.getAttribute('data-value');
                var on = g === 'media' ? active.media : active[g] === v;
                other.classList.toggle('on', on);
              });
              apply();
            });
          });

          resetEl.addEventListener('click', function () {
            q.value = '';
            active = { type: null, time: null, media: false };
            chips.forEach(function (c) { c.classList.remove('on'); });
            apply();
          });

          // Individual scenes collapse natively via <details>; this only does all
          // of them at once, within the active episode.
          toggleAll.addEventListener('click', function () {
            var collapse = toggleAll.textContent.indexOf('Collapse') === 0;
            qsa('.view-scenes .scene', ep()).forEach(function (s) { s.open = !collapse; });
            toggleAll.textContent = collapse ? 'Expand all' : 'Collapse all';
          });

          // Update the subtitle and Director/Cinematographer credits to the active
          // episode (Production Company stays put). Only used when there's a switch.
          function esch(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
          function updateMasthead() {
            var el = ep();
            var subEl = document.getElementById('masthead-sub');
            if (subEl) subEl.textContent = el.getAttribute('data-sub') || '';
            var creditsEl = document.getElementById('credits');
            if (creditsEl) {
              var html = '';
              function span(label, val) {
                if (val && val.trim()) html += '<span class="credit"><b>' + label + '</b> ' + esch(val) + '</span>';
              }
              span('Production Company', creditsEl.getAttribute('data-company') || '');
              span('Director', el.getAttribute('data-director') || '');
              span('Cinematographer', el.getAttribute('data-cinematographer') || '');
              creditsEl.innerHTML = html;
            }
          }

          // Episode switch: swap which episode is shown, keeping search/filters/view.
          var epButtons = qsa('.ep-btn');
          function setEpisode(i) {
            if (i === current || !episodeEls[i]) return;
            current = i;
            episodeEls.forEach(function (el, idx) { el.hidden = idx !== i; });
            epButtons.forEach(function (b) {
              b.classList.toggle('on', parseInt(b.getAttribute('data-ep'), 10) === i);
            });
            toggleAll.textContent = 'Collapse all';
            updateMasthead();
            applyView();
            apply();
            window.scrollTo({ top: 0 });
          }
          epButtons.forEach(function (b) {
            b.addEventListener('click', function () { setEpisode(parseInt(b.getAttribute('data-ep'), 10)); });
          });

          // Enlarging a thumbnail is pure <details> — no script involved, so it
          // works in previews with JavaScript disabled. Script only adds the
          // niceties: one open at a time, and stopping a video when it closes.
          var mediaItems = qsa('.mi');
          mediaItems.forEach(function (item) {
            item.addEventListener('toggle', function () {
              if (item.open) {
                mediaItems.forEach(function (other) { if (other !== item) other.open = false; });
              } else {
                var video = item.querySelector('video');
                if (video) video.pause();
              }
            });
          });

          // Highlight the scene currently on screen in the index
          if ('IntersectionObserver' in window) {
            var observer = new IntersectionObserver(function (entries) {
              entries.forEach(function (entry) {
                var item = tocFor(entry.target.id);
                if (!item) return;
                if (entry.isIntersecting) {
                  qsa('.toc-item').forEach(function (i) { i.classList.remove('active'); });
                  item.classList.add('active');
                }
              });
            }, { rootMargin: '-70px 0px -70% 0px' });
            qsa('.view-scenes .scene').forEach(function (s) { observer.observe(s); });
          }

          var totop = document.getElementById('totop');
          window.addEventListener('scroll', function () { totop.hidden = window.scrollY < 500; });
          totop.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: 'smooth' }); });

          document.addEventListener('keydown', function (event) {
            if (event.key === '/' && document.activeElement !== q) { event.preventDefault(); q.focus(); }
            if (event.key === 'Escape') {
              var open = document.querySelector('.mi[open]');
              if (open) { open.open = false; }
              else if (document.activeElement === q) { q.value = ''; apply(); }
            }
          });

          applyView();
          apply();
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Batch Export

    /// Default filename for a format (used when exporting several at once).
    func defaultFileName(for format: ExportFormat) -> String {
        switch format {
        case .scriptWithCoverage:
            return "\(project.filmName) - Script with Coverage.\(format.fileExtension)"
        case .htmlWithMedia:
            // Only a shot list carrying video needs the zipped folder.
            return "\(project.filmName) - Shot List.\(webExportNeedsFolder ? "zip" : "html")"
        case .pdf:
            return "\(project.filmName) - \(pdfDocumentName).\(format.fileExtension)"
        default:
            return "\(project.filmName) - Shot List.\(format.fileExtension)"
        }
    }

    /// Writes several formats into one folder, no per-file save panel.
    /// Runs on the main actor because it reads SwiftData.
    @MainActor
    func exportAll(formats: [ExportFormat], to folder: URL) async throws -> [URL] {
        var written: [URL] = []
        let episodeName = version?.episode?.project?.isSeries == true ? version?.episode?.title : nil

        for format in formats {
            let url = folder.appendingPathComponent(defaultFileName(for: format))

            switch format {
            case .text:
                try generateFullTextContent().write(to: url, atomically: true, encoding: .utf8)

            case .pdf:
                guard let data = createPDFData(from: generateFullTextContent()) else {
                    throw Self.exportError("Failed to create the PDF.")
                }
                try data.write(to: url)

            case .scriptWithCoverage:
                guard let data = createScriptWithCoverage() else {
                    throw Self.exportError("Failed to create the script with coverage. Make sure a script PDF is imported.")
                }
                try data.write(to: url)

            case .htmlWithMedia:
                // Derive the extension from the very snapshot that gets written,
                // so a .html file can never end up containing a zip.
                let mediaScenes = snapshotScenesForMedia()
                let needsFolder = mediaScenes.contains {
                    $0.shots.contains { $0.references.contains { $0.videoData != nil || $0.mapVideoData != nil } }
                }
                let webURL = folder.appendingPathComponent(
                    "\(project.filmName) - Shot List.\(needsFolder ? "zip" : "html")")
                try writeWebExport(filmName: project.filmName,
                                   episodeName: episodeName,
                                   versionName: version?.name,
                                   scenes: mediaScenes,
                                   to: webURL)
                written.append(webURL)
                continue

            }
            written.append(url)
        }
        return written
    }

    private static func exportError(_ message: String) -> NSError {
        NSError(domain: "ProjectExporter", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if os(macOS)
    /// Success alert for a batch export.
    @MainActor
    func showBatchSuccess(urls: [URL], folder: URL) {
        let alert = NSAlert()
        alert.messageText = "Export Successful"
        alert.informativeText = "Exported \(urls.count) file\(urls.count == 1 ? "" : "s"):\n"
            + urls.map { "• \($0.lastPathComponent)" }.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [folder] : urls)
        }
    }

    @MainActor
    func showExportError(_ error: Error) {
        showErrorAlert(error: error)
    }
    #endif

    // MARK: - Text Generation

    private func generateFullTextContent() -> String {
        print("🔵 [CONTENT] Starting content generation...")

        let rule = String(repeating: "=", count: 80)
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short

        let orderedScenes = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        let totalShots = orderedScenes.reduce(0) { $0 + $1.shots.count }

        var output = ""

        // ── Header ──────────────────────────────────────────────────────────
        output += rule + "\n"
        output += "\(project.filmName.uppercased()) — SHOT LIST\n"
        if !textContextLine.isEmpty {
            output += textContextLine + "\n"
        }
        for (label, value) in [("Production Company", project.productionCompany),
                               ("Director", project.director),
                               ("Cinematographer", project.cinematographer)] {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { output += "\(label): \(v)\n" }
        }
        output += "Exported \(formatter.string(from: Date()))\n"
        output += rule + "\n\n"

        // ── Contents (only worth it for longer lists) ───────────────────────
        if orderedScenes.count > 1 {
            output += "CONTENTS\n"
            for scene in orderedScenes {
                let label = "\(scene.sceneNumber)\(scene.suffix)"
                let count = scene.shots.count
                let countText = "\(count) shot\(count == 1 ? "" : "s")"
                output += "  " + padRight(label, 6) + padRight(sceneSlug(scene), 48) + countText + "\n"
            }
            output += "\n"
        }

        // ── Statistics ──────────────────────────────────────────────────────
        let stats = calculateStatistics()
        output += "STATISTICS\n"
        output += "  " + padRight("Shots with photos", 22) + "\(stats.shotsWithPhotos) / \(totalShots)\n"
        output += "  " + padRight("Shots with coverage", 22) + "\(stats.shotsWithCoverage) / \(totalShots)\n"
        output += "  " + padRight("Complete (both)", 22) + "\(stats.completeShots) / \(totalShots)  (\(stats.completionPercentage)%)\n"
        output += "  " + padRight("Scene types", 22)
        output += "INT/DAY \(stats.intDayCount) · INT/NIGHT \(stats.intNightCount) · EXT/DAY \(stats.extDayCount) · EXT/NIGHT \(stats.extNightCount)\n"
        let hasScript = (version?.pdfData ?? project.scriptPDFData) != nil
        output += "  " + padRight("Script PDF", 22) + (hasScript ? "Attached" : "None") + "\n"
        output += "\n"

        // ── Scene breakdown ─────────────────────────────────────────────────
        output += generateExportText(orderedScenes: orderedScenes)

        // ── Footer ──────────────────────────────────────────────────────────
        output += "\n" + rule + "\n"
        output += "End of shot list · generated by CinePlanner\n"
        output += rule + "\n"

        print("✅ [CONTENT] Content generation complete!")
        return output
    }

    /// "Episode 2 · Version 3 · 14 scenes · 42 shots" — mirrors the export
    /// window's context line, minus the film name (already the title above).
    private var textContextLine: String {
        var parts: [String] = []
        if project.isSeries, let episode = version?.episode?.title { parts.append(episode) }
        if let versionName = version?.name { parts.append(versionName) }
        let sceneCount = exportScenes.count
        let shotCount = exportScenes.reduce(0) { $0 + $1.shots.count }
        parts.append("\(sceneCount) scene\(sceneCount == 1 ? "" : "s")")
        parts.append("\(shotCount) shot\(shotCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// Screenplay-style slugline: "EXT. COTTON FIELD – DAY".
    private func sceneSlug(_ scene: Scene) -> String {
        let intExt = scene.isInterior ? "INT." : "EXT."
        let time = scene.isDay ? "DAY" : "NIGHT"
        let place = scene.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if place.isEmpty {
            return "\(intExt) – \(time)"
        }
        return "\(intExt) \(place.uppercased()) – \(time)"
    }

    /// Pads `s` with trailing spaces to `width`; never truncates.
    private func padRight(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }
    
    // Calculate project statistics
    private func calculateStatistics() -> (
        shotsWithPhotos: Int,
        shotsWithCoverage: Int,
        completeShots: Int,
        completionPercentage: Int,
        intDayCount: Int,
        intNightCount: Int,
        extDayCount: Int,
        extNightCount: Int
    ) {
        var shotsWithPhotos = 0
        var shotsWithCoverage = 0
        var completeShots = 0
        var intDayCount = 0
        var intNightCount = 0
        var extDayCount = 0
        var extNightCount = 0
        
        let totalShots = exportScenes.reduce(0) { $0 + $1.shots.count }
        
        for scene in exportScenes {
            // Count scene types
            if scene.isInterior && scene.isDay { intDayCount += 1 }
            else if scene.isInterior && !scene.isDay { intNightCount += 1 }
            else if !scene.isInterior && scene.isDay { extDayCount += 1 }
            else if !scene.isInterior && !scene.isDay { extNightCount += 1 }
            
            for shot in scene.shots {
                // Check for photos
                if shot.hasAnyReferenceMedia {
                    shotsWithPhotos += 1
                }
                
                // Check for coverage
                if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                    shotsWithCoverage += 1
                }
                
                // Check if complete (has both photos and coverage)
                if shot.hasAnyReferenceMedia &&
                   shot.scriptCoverageSelections != nil &&
                   !(shot.scriptCoverageSelections?.isEmpty ?? true) {
                    completeShots += 1
                }
            }
        }
        
        let completionPercentage = totalShots > 0 ? Int(Double(completeShots) / Double(totalShots) * 100) : 0
        
        return (
            shotsWithPhotos: shotsWithPhotos,
            shotsWithCoverage: shotsWithCoverage,
            completeShots: completeShots,
            completionPercentage: completionPercentage,
            intDayCount: intDayCount,
            intNightCount: intNightCount,
            extDayCount: extDayCount,
            extNightCount: extNightCount
        )
    }
    
    private func generateExportText(orderedScenes: [Scene]) -> String {
        print("🔵 [EXPORT_TEXT] Starting scene breakdown...")

        // Aligns detail values into a column; survives proportional fonts far
        // better than the old box-drawing frame did.
        let sceneRule = String(repeating: "─", count: 72)
        let valueIndent = "      "                       // under "  SHOT"
        let contIndent = valueIndent + String(repeating: " ", count: 12)
        func detailRow(_ label: String, _ value: String) -> String {
            valueIndent + padRight(label, 12) + value + "\n"
        }

        var output = ""

        for scene in orderedScenes {
            let shotCount = scene.shots.count
            let countText = "\(shotCount) shot\(shotCount == 1 ? "" : "s")"

            var header = "SCENE \(scene.sceneNumber)\(scene.suffix) — \(sceneSlug(scene))"
            if scene.scriptPageNumber > 0 {
                header += "  (p.\(scene.scriptPageNumber))"
            }
            header += " · \(countText)"

            output += sceneRule + "\n"
            output += header + "\n"
            output += sceneRule + "\n\n"

            let orderedShots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
            if orderedShots.isEmpty {
                output += "  (No shots in this scene)\n\n"
                continue
            }

            for shot in orderedShots {
                var line = "  SHOT \(shot.displayNumber)"
                if !shot.nickname.isEmpty {
                    line += " — \(shot.nickname)"
                }
                output += line + "\n"

                if shot.hasSize {
                    var sizeText = shot.sizeShort
                    if shot.hasSecondSize {
                        sizeText += " → " + shot.secondSizeShort
                    }
                    output += detailRow("Size", sizeText)
                }

                if shot.hasType {
                    var typeText = shot.typeShort
                    if shot.hasSecondType {
                        typeText += " + " + shot.secondTypeShort
                    }
                    if shot.hasThirdType {
                        typeText += " + " + shot.thirdTypeShort
                    }
                    output += detailRow("Type", typeText)
                }

                if shot.lensfocal > 0 {
                    let focal = shot.lensIsPrime
                        ? "\(shot.lensfocal)mm"
                        : "\(shot.lensfocal)→\(shot.lensfocalEnd)mm"
                    output += detailRow("Focal", focal)
                }

                if shot.hasGrip {
                    output += detailRow("Grip", shot.gripName)
                }
                if !shot.camera.isEmpty {
                    output += detailRow("Camera", shot.camera)
                }
                if !shot.framelines.isEmpty {
                    output += detailRow("Framelines", shot.framelines)
                }
                if !shot.lensPreset.isEmpty {
                    output += detailRow("Lens", shot.lensPreset)
                }
                if !shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output += detailRow("Extra", shot.extraInfo)
                }

                // Reference media — noted as present (text can't carry it).
                if let media = referenceSummary(for: shot) {
                    output += detailRow("Reference", media)
                }

                // Script coverage
                if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                    output += detailRow("Coverage", "\(selections.count) selection\(selections.count == 1 ? "" : "s")")
                    for selection in selections {
                        output += contIndent + "· " + formatCoverageSummary(selection) + "\n"
                    }
                }

                output += "\n"
            }
        }

        print("✅ [EXPORT_TEXT] Scene breakdown complete!")
        return output
    }

    /// "2 photos · 1 video · 1 map", or nil when the shot has no media.
    private func referenceSummary(for shot: Shot) -> String? {
        let photos = shot.referenceImages.count
        let maps = shot.referenceMaps.count
        let videos = shot.orderedReferences.filter { $0.videoExtension != nil }.count

        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if maps > 0 { parts.append("\(maps) map\(maps == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    
    // MARK: - Helper Functions

    private func exportLineRange(for pageRect: CGRect) -> ClosedRange<CGFloat> {
        let minimumPageX = pageRect.minX
        let maximumPageX = pageRect.maxX - 6
        let marginFraction = CGFloat(version?.coverageLineMargin ?? 0.15)
        let marginLimitX = pageRect.minX + (pageRect.width * marginFraction)
        let upperBound = min(maximumPageX, marginLimitX)
        let lowerBound = min(minimumPageX, upperBound)
        return lowerBound...upperBound
    }

    
    private func createScriptWithCoverage() -> Data? {
        var result: Data?
        PlatformAppearance.performLight {
            result = buildScriptWithCoverage()
        }
        return result
    }

    private func buildScriptWithCoverage() -> Data? {
        print("🔵 [SCRIPT_COVERAGE] Creating script with burned-in coverage")
        
        // Check if script PDF exists
        guard let scriptPDFData = (version?.pdfData ?? project.scriptPDFData),
              let sourcePDF = PDFDocument(data: scriptPDFData) else {
            print("❌ [SCRIPT_COVERAGE] No script PDF found")
            return nil
        }
        
        print("✅ [SCRIPT_COVERAGE] Loaded script PDF with \(sourcePDF.pageCount) pages")
        
        // Create a new PDF document
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else {
            print("❌ [SCRIPT_COVERAGE] Failed to create data consumer")
            return nil
        }
        
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // Default US Letter
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            print("❌ [SCRIPT_COVERAGE] Failed to create PDF context")
            return nil
        }
        
        // Collect all coverage selections organized by page
        var coverageByPage: [Int: [(shot: Shot, selection: ScriptTextSelection)]] = [:]
        
        print("📋 [EXPORT COLOR] Collecting coverage from all scenes and shots...")
        for scene in exportScenes {
            print("   🎬 Scene \(scene.sceneNumber)\(scene.suffix): \(scene.shots.count) shots")
            for (shotIndex, shot) in scene.shots.enumerated() {
                guard let selections = shot.scriptCoverageSelections else { continue }
                
                print("      📸 Shot \(shot.displayNumber) (index \(shotIndex)): \(selections.count) selection(s)")
                
                for selection in selections {
                    for pageRange in selection.pageRanges {
                        let pageIndex = pageRange.pageIndex
                        if coverageByPage[pageIndex] == nil {
                            coverageByPage[pageIndex] = []
                        }
                        coverageByPage[pageIndex]?.append((shot: shot, selection: selection))
                        print("         - Added to page \(pageIndex)")
                    }
                }
            }
        }
        
        print("📋 [SCRIPT_COVERAGE] Found coverage on \(coverageByPage.keys.count) pages")
        
        // Use the same color scheme as the editor tab
        let shotColors: [PlatformColor] = [
            .systemBlue,
            .systemGreen,
            .systemOrange,
            .systemPurple,
            .systemPink,
            .systemTeal,
            .systemIndigo,
            .systemRed,
            .systemYellow,
            .systemBrown
        ]
        
        print("🎨 [EXPORT COLOR] Using color palette with \(shotColors.count) colors:")
        for (index, color) in shotColors.enumerated() {
            print("   \(index): \(color)")
        }
        
        // STEP 1: Assign base colors to each shot based on their sorted position within their scene
        // This ensures the same shot always gets the same base color (matching editor behavior)
        var shotBaseColors: [ObjectIdentifier: (colorIndex: Int, color: PlatformColor)] = [:]
        
        print("🎨 [EXPORT COLOR] Step 1: Assigning base colors to shots...")
        for scene in exportScenes {
            for shot in scene.shots {
                guard let shotIndex = scene.orderedShots.firstIndex(where: { $0 === shot }) else { continue }
                let colorIndex = shotIndex % shotColors.count
                shotBaseColors[ObjectIdentifier(shot)] = (colorIndex, shotColors[colorIndex])
                print("   - Scene \(scene.sceneNumber)\(scene.suffix), Shot \(shot.displayNumber): Base color index \(colorIndex)")
            }
        }
        
        print("✅ [EXPORT COLOR] Base color assignment complete")

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
                print("📝 [SCRIPT_COVERAGE] Drawing \(coverages.count) coverage item(s) on page \(pageIndex + 1)")

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
                          let baseColorInfo = shotBaseColors[ObjectIdentifier(shot)],
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
                    bars.append(Bar(color: shotColors[baseColorInfo.colorIndex],
                                    label: shot.displayNumber, minY: minY, maxY: maxY,
                                    labelTopY: labelTopY, labelWidth: ls.width, labelHeight: ls.height,
                                    drawsLabel: isFirstPage || !isMultiPage))
                }

                let lines: [CoverageLineLayout.Line] = bars.map { bar in
                    CoverageLineLayout.Line(
                        extent: bar.minY...bar.maxY,
                        labelWidth: bar.labelWidth,
                        labelBand: bar.drawsLabel ? (bar.labelTopY + 4)...(bar.labelTopY + 4 + bar.labelHeight) : nil)
                }
                let placements = CoverageLineLayout.solve(lines, band: exportLineRange(for: pageRect))

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

        print("✅ [SCRIPT_COVERAGE] Script with coverage created successfully")
        return outputData as Data
    }
    
    /// A PDF is always drawn on white paper, but PlatformColor.platformLabel and friends are
    /// dynamic: in dark mode they resolve to white, producing a page of invisible
    /// text. Drawing inside the light appearance pins every system colour to its
    /// light-mode value.
    private func createPDFData(from text: String) -> Data? {
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
    
    private func formatCoverageSummary(_ selection: ScriptTextSelection) -> String {
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
    private func showErrorAlert(error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showSuccessNotification(fileURL: URL, format: ExportFormat) {
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

// MARK: - Export Format

enum ExportFormat: Hashable {
    case pdf
    case text
    case scriptWithCoverage
    case htmlWithMedia

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .text: return "Text File"
        case .scriptWithCoverage: return "Script with Coverage"
        case .htmlWithMedia: return "Web Page with Media"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .text: return "txt"
        case .scriptWithCoverage: return "pdf"
        case .htmlWithMedia: return "zip"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .text: return .plainText
        case .scriptWithCoverage: return .pdf
        case .htmlWithMedia: return .zip
        }
    }
}
