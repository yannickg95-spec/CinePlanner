//
//  ProjectExporter+Web.swift
//  CinePlanner
//
//  The web export: snapshotting a version's media, transcoding reference video
//  for the browser, and building the page itself.
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
    func webExportBaseName(_ filmName: String) -> String {
        let safe = filmName.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        // An unnamed project would otherwise come out as "Shot List - Shot List".
        return safe.isEmpty ? "Shot List" : "\(safe) - Shot List"
    }

    /// With videos: a self-contained folder (page + media/) zipped for sharing.
    /// Without: one HTML file, since the photos are embedded in it anyway.
    #if os(macOS)
    func exportHTMLWithMedia() {
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
                Log.export.debug("ℹ️ [EXPORT] HTML export cancelled")
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
                Log.export.error("❌ [EXPORT] HTML export failed: \(error)")
                self.showErrorAlert(error: error)
            }
        }
    }
    #endif

    /// The per-shot colour used for coverage highlights, matching the editor and
    /// the "script with coverage" PDF: a shot's position within its scene.

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
    private func renderSceneCoverage(scene: Scene, sourcePDF: PDFDocument,
                                     coloring: CoverageColoring) -> CoverageImage? {
        struct Bar { let color: PlatformColor; let label: String; let minY: CGFloat; let maxY: CGFloat }
        var byPage: [Int: [Bar]] = [:]
        for shot in scene.shots {
            guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { continue }
            let color = coloring.color(for: shot)
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
                let barBand = exportLineRange(for: cropBox)
                let barLines: [CoverageLineLayout.Line] = bars.map { bar in
                    let w = NSAttributedString(string: bar.label, attributes: [.font: baseFont]).size()
                    return CoverageLineLayout.Line(
                        extent: bar.minY...bar.maxY,
                        band: barBand,
                        labelWidth: w.width,
                        labelBand: (bar.maxY + 3)...(bar.maxY + 3 + w.height))
                }
                let placements = CoverageLineLayout.solve(barLines, onRight: coverageOnRight)
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
                    // Clamp so the number can't run off the page edge (the outermost
                    // line sits right against it), matching the PDF export.
                    let minX = cropBox.minX + 2
                    let maxX = cropBox.maxX - 2 - ls.width
                    let labelX = min(max(x - ls.width / 2, minX), max(minX, maxX))
                    let labelOrigin = CGPoint(x: labelX, y: bar.maxY + 3)
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
    func renderSceneMap(scene: Scene) -> CoverageImage? {
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
                                      isSatellite: scene.sceneMapBackgroundIsSatellite,
                                      backgroundTransform: scene.sceneMapBackgroundTransform,
                                      northOffsetDeg: scene.mapNorthOffset)
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
        // Resolved once for the whole export, not per scene: two of the colour
        // modes depend on a shot's place in the entire script.
        let coloring = CoverageColoring(version: version, project: project)
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
                              coverage: sourcePDF.flatMap { renderSceneCoverage(scene: scene, sourcePDF: $0, coloring: coloring) },
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
    /// Writes the web export and returns the URL used.
    ///
    /// The page ships as a lone .html file unless a reference carries video, in
    /// which case it needs a media folder beside it and goes out zipped. That
    /// choice is made from the very snapshot that gets written — deciding it
    /// separately is how a .html ends up containing a zip — so `makeURL` is handed
    /// the extension rather than being asked to guess it.
    func writeWebExport(filmName: String, episodeName: String?, versionName: String?,
                        url makeURL: (_ fileExtension: String) throws -> URL) throws -> URL {
        let scenes = snapshotScenesForMedia()
        let hasVideo = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil || $0.mapVideoData != nil } } }
        let destination = try makeURL(hasVideo ? "zip" : "html")
        try writeWebExport(filmName: filmName, episodeName: episodeName,
                           versionName: versionName, scenes: scenes, to: destination)
        return destination
    }

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
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { Log.export.error("Could not create the site's media folder, images will be embedded instead: \(error.localizedDescription)") }
        return { data, name in
            let file = "\(subdir)/\(name).jpg"
            do {
                try data.write(to: staging.appendingPathComponent(file))
                return file
            } catch {
                Log.export.notice("Could not write \(name, privacy: .public) to the media folder, embedding it instead: \(error.localizedDescription)")
                return dataURI(data)   // fall back to embedding so the image still shows
            }
        }
    }

    // MARK: - Web video compression

    /// Reference videos above this are transcoded down to a web-friendly H.264
    /// MP4, so a publish can't fail on one big clip. It is the publisher's own
    /// upload ceiling — the two must agree, or a clip is either compressed for no
    /// reason or waved through and then rejected by GitHub.
    static let gitHubVideoLimit = GitHubPublisher.maxUploadBytes

    /// Transcodes video data down to an H.264 MP4 that fits under `maxBytes`,
    /// stepping resolution down until it does. Returns the smallest result it
    /// managed (still MP4) even if nothing fit — the caller enforces the hard
    /// limit and reports a clear error for a clip that's simply too long.
    static func videoForWeb(data: Data, ext: String, maxBytes: Int) async -> (data: Data, ext: String) {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("src_\(UUID().uuidString).\(ext)")
        do { try data.write(to: src) }
        catch {
            Log.export.error("Could not stage a video for compression, publishing it at full size: \(error.localizedDescription)")
            return (data, ext)
        }
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
            Log.export.notice("Video transcode to \(preset, privacy: .public) failed: \(error.localizedDescription)")
            return nil
        }
        do { return try Data(contentsOf: out) }
        catch {
            Log.export.error("Transcoded video could not be read back: \(error.localizedDescription)")
            return nil
        }
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

    /// The exported page's stylesheet and script.
    ///
    /// They live as real `.css` / `.js` files in the bundle rather than as inline
    /// Swift strings: that way an editor checks their syntax, and `buildHTML` is
    /// about the page's structure instead of carrying 765 lines of them. Loaded
    /// once, not per export.
    private static let webExportCSS = webAsset("WebExport", withExtension: "css")
    private static let webExportJS  = webAsset("WebExport", withExtension: "js")

    private static func webAsset(_ name: String, withExtension ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Bundled, so this should be impossible — but a silent miss would ship
            // an unstyled or inert page, which is worth hearing about.
            Log.export.error("Bundled web asset \(name, privacy: .public).\(ext, privacy: .public) is missing; the exported page will lack its styling or behaviour.")
            return ""
        }
        return text
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
            guard let data = try? JSONSerialization.data(withJSONObject: days) else {
                Log.export.error("Could not encode the shooting schedule; the published page will have no day view.")
                return "[]"
            }
            if let str = String(data: data, encoding: .utf8) {
                // This JSON is inlined into a <script> element, and JSONSerialization
                // leaves "<" alone. A day note containing "</script>" would close the
                // element early and break the published page, so escape it — inside
                // serialized JSON every "<" is within a string, and \u003C parses back
                // to the same character.
                return str.replacingOccurrences(of: "<", with: "\\u003C")
            }
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
                // `--ar` (the ratio as a plain number) lets the fullscreen viewer size
                // the map to fit the screen in both orientations — see `.mi-map[open]`
                // in WebExport.css. A background image has no intrinsic size to fit.
                let ratio = map.height > 0 ? Double(map.width) / Double(map.height) : 1
                coverageStyles += "          .\(cls) { background-image: url(\(assetURL(map.data, "map_\(e)_\(index)"))); aspect-ratio: \(Int(map.width)) / \(Int(map.height)); --ar: \(String(format: "%.5f", ratio)); }\n"
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
                cards += "      <details class=\"mi mi-map\"><summary onclick=\"event.stopPropagation()\" title=\"Scene map\"><span class=\"cover-thumb is-map \(cls)\"></span><span class=\"thumb-label\">Scene map</span></summary></details>\n"
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
        \(webExportCSS)
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
        \(webExportJS)
        </script>
        </body>
        </html>
        """
    }
}
