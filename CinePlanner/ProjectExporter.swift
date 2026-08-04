//
//  ProjectExporter.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 25/12/2025.
//

import Foundation
import AppKit
import SwiftUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

/// Handles exporting project shot lists to PDF and TXT formats
struct ProjectExporter {
    let project: Project
    var version: ScriptVersion? = nil

    /// Scenes to export: the selected script version's scenes, or all project
    /// scenes for legacy projects without versions.
    private var exportScenes: [Scene] {
        version?.scenes ?? project.scenes
    }

    /// Shows a save panel and exports the shot list
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

    /// The per-shot colour used for coverage highlights, matching the editor and
    /// the "script with coverage" PDF: a shot's position within its scene.
    private static let coveragePalette: [NSColor] = [
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

    /// Renders the scene's covered script page(s) as one image, drawing each shot's
    /// coverage as a coloured bar in the left margin next to the covered lines —
    /// the same style as the "script with coverage" PDF — with the shot number
    /// above each bar. Returns nil when no shot in the scene has coverage.
    private func renderSceneCoverage(scene: Scene, sourcePDF: PDFDocument) -> CoverageImage? {
        struct Bar { let color: NSColor; let label: String; let minY: CGFloat; let maxY: CGFloat }
        var byPage: [Int: [Bar]] = [:]
        for shot in scene.shots {
            guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { continue }
            let colorIndex = (scene.shots.firstIndex { $0 === shot } ?? 0) % Self.coveragePalette.count
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

        // Higher scale than a poster: this is text meant to be read when opened.
        let scale: CGFloat = 3.0
        var pageImages: [NSImage] = []
        for pageIndex in byPage.keys.sorted() {
            guard let page = sourcePDF.page(at: pageIndex) else { continue }
            let cropBox = page.bounds(for: .cropBox)
            let size = NSSize(width: cropBox.width * scale, height: cropBox.height * scale)
            guard size.width > 1, size.height > 1 else { continue }

            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -cropBox.origin.x, y: -cropBox.origin.y)
                page.draw(with: .cropBox, to: ctx)

                // Place each bar into a free margin slot, avoiding vertical overlap.
                var placed: [(range: ClosedRange<CGFloat>, offset: CGFloat, slot: Int)] = []
                let xRange = exportLineRange(for: cropBox)
                for bar in byPage[pageIndex] ?? [] {
                    let x = calculateCoverageLineX(at: bar.minY...bar.maxY, within: xRange, existingLines: &placed)
                    ctx.setStrokeColor(bar.color.cgColor)
                    ctx.setLineWidth(3)
                    ctx.move(to: CGPoint(x: x, y: bar.minY))
                    ctx.addLine(to: CGPoint(x: x, y: bar.maxY))
                    ctx.strokePath()

                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                        .foregroundColor: bar.color
                    ]
                    let label = NSAttributedString(string: bar.label, attributes: attrs)
                    let ls = label.size()
                    label.draw(at: CGPoint(x: x - ls.width / 2, y: bar.maxY + 3))
                }
                ctx.restoreGState()
            }
            image.unlockFocus()
            pageImages.append(image)
        }
        guard !pageImages.isEmpty else { return nil }

        // Stack the pages vertically.
        let gap: CGFloat = 14 * scale
        let width = pageImages.map(\.size.width).max() ?? 0
        let height = pageImages.reduce(0) { $0 + $1.size.height } + gap * CGFloat(pageImages.count - 1)
        let composite = NSImage(size: NSSize(width: width, height: height))
        composite.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var y = height
        for image in pageImages {
            y -= image.size.height
            image.draw(in: NSRect(x: (width - image.size.width) / 2, y: y,
                                  width: image.size.width, height: image.size.height))
            y -= gap
        }
        composite.unlockFocus()

        guard let tiff = composite.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
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
        let background = scene.sceneMapBackgroundData.flatMap(NSImage.init(data:))
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
                                      labels: labels, size: outSize)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
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
        if !shot.format.isEmpty { rows.append(("Format", shot.format)) }
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
            let html = Self.buildHTML(filmName: filmName, episodeName: episodeName, versionName: versionName,
                                      scenes: scenes, media: rendered)
            guard let data = html.data(using: .utf8) else {
                throw Self.exportError("Failed to encode the web page.")
            }
            try data.write(to: destination)
        }
    }

    /// Builds a self-contained website folder — index.html at the root plus a
    /// media/ folder for any videos — in a fresh temp directory, ready to deploy.
    /// Photos are embedded in the page; only videos live as sibling files. Videos
    /// over GitHub's file limit are transcoded down so publishing can't fail on an
    /// oversized file. The caller is responsible for removing the returned directory.
    /// `onCompress(done, total)` fires as each over-limit video is transcoded.
    @MainActor
    func buildSiteDirectory(onCompress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        let filmName = project.filmName
        let versionName = version?.name
        let episodeName = version?.episode?.project?.isSeries == true ? version?.episode?.title : nil
        let scenes = snapshotScenesForMedia()

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("web-publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let hasVideo = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil || $0.mapVideoData != nil } } }
        if hasVideo {
            try fm.createDirectory(at: staging.appendingPathComponent("media", isDirectory: true),
                                   withIntermediateDirectories: true)
        }

        // How many videos will need transcoding — for accurate progress. Counts
        // both the reference video and a map video.
        let oversizedTotal = scenes.reduce(0) { acc, scene in
            acc + scene.shots.reduce(0) { a, shot in
                a + shot.references.reduce(0) { c, ref in
                    c + (((ref.videoData?.count ?? 0) > Self.gitHubVideoLimit) ? 1 : 0)
                      + (((ref.mapVideoData?.count ?? 0) > Self.gitHubVideoLimit) ? 1 : 0)
                }
            }
        }
        var compressedDone = 0

        // Compresses an oversized clip, writes it into media/, and returns its path
        // and a poster frame.
        func writeWebVideo(_ data: Data, ext: String, name: String) async throws -> (path: String, poster: String?) {
            var outData = data, outExt = ext
            if data.count > Self.gitHubVideoLimit {
                compressedDone += 1
                onCompress(compressedDone, oversizedTotal)
                let result = await Self.videoForWeb(data: data, ext: ext, maxBytes: Self.gitHubVideoLimit)
                outData = result.data; outExt = result.ext
            }
            let file = "media/\(name).\(outExt)"
            try outData.write(to: staging.appendingPathComponent(file))
            return (file, Self.posterFrame(fromVideoData: outData, ext: outExt).map { Self.dataURI($0) })
        }

        var rendered: [String: RenderedMedia] = [:]
        for scene in scenes {
            for shot in scene.shots {
                for reference in shot.references {
                    var videoPath: String?
                    var posterURI: String?
                    if let data = reference.videoData {
                        let out = try await writeWebVideo(data, ext: reference.videoExtension,
                                                          name: "shot_\(shot.slug)_\(reference.index)_video")
                        videoPath = out.path; posterURI = out.poster
                    }
                    var mapVideoPath: String?
                    var mapPosterURI: String?
                    if let mData = reference.mapVideoData {
                        let out = try await writeWebVideo(mData, ext: reference.mapVideoExtension,
                                                          name: "shot_\(shot.slug)_\(reference.index)_map")
                        mapVideoPath = out.path; mapPosterURI = out.poster
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

        let html = Self.buildHTML(filmName: filmName, episodeName: episodeName, versionName: versionName,
                                  scenes: scenes, media: rendered)
        guard let data = html.data(using: .utf8) else {
            throw Self.exportError("Failed to encode the web page.")
        }
        try data.write(to: staging.appendingPathComponent("index.html"))
        return staging
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

        let html = Self.buildHTML(filmName: filmName, episodeName: episodeName, versionName: versionName,
                                  scenes: scenes, media: rendered)
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
        guard let rep = NSBitmapImageRep(data: data) else { return data }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
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

        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func buildHTML(filmName: String, episodeName: String?, versionName: String?,
                                  scenes: [MediaScene],
                                  media: [String: RenderedMedia]) -> String {
        let totalShots = scenes.reduce(0) { $0 + $1.shots.count }
        var subtitleBits: [String] = []
        if let episodeName { subtitleBits.append(esc(episodeName)) }
        if let versionName { subtitleBits.append(esc(versionName)) }
        subtitleBits.append("\(scenes.count) scene\(scenes.count == 1 ? "" : "s")")
        subtitleBits.append("\(totalShots) shot\(totalShots == 1 ? "" : "s")")

        var body = ""
        var toc = ""
        var coverageStyles = ""   // one background-image rule per scene, so the JPEG isn't inlined per shot
        var shotSeq = 0           // unique id per shot, for its expand checkbox
        for (index, scene) in scenes.enumerated() {
            let anchor = "scene-\(index)"
            // The scene's coverage image is embedded once as a CSS background and
            // shared by every covered shot's thumbnail, rather than inlined N times.
            var coverageClass: String? = nil
            if let cov = scene.coverage {
                let cls = "cov-\(index)"
                coverageStyles += "          .\(cls) { background-image: url(\(Self.dataURI(cov.data))); aspect-ratio: \(Int(cov.width)) / \(Int(cov.height)); }\n"
                coverageClass = cls
            }
            // The scene map, embedded once per scene as its own background rule.
            var mapClass: String? = nil
            if let map = scene.map {
                let cls = "map-\(index)"
                coverageStyles += "          .\(cls) { background-image: url(\(Self.dataURI(map.data))); aspect-ratio: \(Int(map.width)) / \(Int(map.height)); }\n"
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
            body += "  <summary class=\"scene-head\">\n"
            body += "    <span class=\"scene-title\">\(esc(scene.heading))</span>\n"
            body += "    <span class=\"tag tag-type\">\(typeLabel)</span>\n"
            body += "    <span class=\"tag \(scene.isDay ? "tag-day" : "tag-night")\">\(timeLabel)</span>\n"
            if !scene.location.isEmpty {
                body += "    <span class=\"scene-loc\">\(esc(scene.location))</span>\n"
            }
            body += "    <span class=\"scene-count\">\(shotCount) shot\(shotCount == 1 ? "" : "s")</span>\n"
            body += "  </summary>\n"
            // Shown once at the top of the scene: the script pages with every
            // shot's coverage marked, and the scene's blocking map — side by side,
            // rather than repeated on each shot. Each is a <details> so it expands
            // full screen with no JavaScript (works in Quick Look).
            if coverageClass != nil || mapClass != nil || !scene.filmEntries.isEmpty {
                body += "  <div class=\"scene-coverage\">\n"
                if let cls = coverageClass {
                    body += "    <details class=\"mi mi-doc\"><summary title=\"Script with coverage for this scene\"><span class=\"cover-thumb \(cls)\"></span><span class=\"thumb-label\">Script coverage</span></summary></details>\n"
                }
                if let cls = mapClass {
                    body += "    <details class=\"mi mi-doc\"><summary title=\"Scene map\"><span class=\"cover-thumb is-map \(cls)\"></span><span class=\"thumb-label\">Scene map</span></summary></details>\n"
                }
                if !scene.filmEntries.isEmpty {
                    // A tiny text preview of the report, standing in for a thumbnail.
                    var preview = "<span class=\"rp-title\">Film length</span>"
                    for e in scene.filmEntries.prefix(6) {
                        preview += "<span class=\"rp-line\">\(esc("\(e.shot) · \(e.format) · \(e.length)"))</span>"
                    }
                    body += "    <details class=\"mi mi-report\"><summary title=\"Film length report\"><span class=\"cover-thumb is-report\"><span class=\"report-preview\">\(preview)</span></span><span class=\"thumb-label\">Film report</span></summary>\n"
                    body += "      <div class=\"report-panel\"><div class=\"report-card\">\n"
                    body += "        <h3 class=\"report-title\">Film length — \(esc(scene.heading))</h3>\n"
                    body += "        <table class=\"report-table\"><thead><tr><th>Shot</th><th>Format</th><th>fps</th><th>Length</th><th>Time</th></tr></thead><tbody>\n"
                    for e in scene.filmEntries {
                        body += "          <tr><td>\(esc(e.shot))</td><td>\(esc(e.format))</td><td>\(esc(e.fps))</td><td>\(esc(e.length))</td><td>\(esc(e.time))</td></tr>\n"
                    }
                    body += "        </tbody></table>\n"
                    func totalsTable(_ title: String, _ totals: [(gauge: String, metres: String, time: String)]) {
                        body += "        <div class=\"report-totals-title\">\(esc(title))</div>\n"
                        body += "        <table class=\"report-table report-totals\"><tbody>\n"
                        for t in totals {
                            body += "          <tr><td>\(esc(t.gauge))</td><td>\(esc(t.metres))</td><td>\(esc(t.time))</td></tr>\n"
                        }
                        body += "        </tbody></table>\n"
                    }
                    if !scene.filmTotals.isEmpty { totalsTable("Scene totals", scene.filmTotals) }
                    if !scene.projectFilmTotals.isEmpty { totalsTable("Project totals", scene.projectFilmTotals) }
                    body += "      </div></div>\n"
                    body += "    </details>\n"
                }
                body += "  </div>\n"
            }
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
                let inlineHidden: Set<String> = ["Camera", "Format", "Lens", "Framelines", "Film length"]
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
                        body += "          <details class=\"mi\"><summary title=\"Top-down plan\"><img class=\"still\" src=\"\(topDown)\" alt=\"Top-down plan\"><span class=\"thumb-label\">Shot map\(tag)</span></summary>\(noteHTML)</details>\n"
                    }
                    if let mapVideo = m.mapVideoPath {
                        let mime = mapVideo.hasSuffix(".mov") ? "video/quicktime" : "video/mp4"
                        body += "          <details class=\"mi mi-video\">\n            <summary title=\"Play map\">"
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
                    let cameraLabels: Set<String> = ["Camera", "Format", "Framelines", "Lens", "Film length"]
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
          html { scroll-behavior: smooth; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 margin: 0; background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; }

          /* Masthead */
          .masthead { padding: 30px 28px 22px; max-width: 1240px; margin: 0 auto; }
          .masthead h1 { margin: 0 0 6px; font-size: 30px; letter-spacing: -0.4px; }
          .masthead .sub { color: var(--muted); font-size: 14px; }

          /* Sticky filter bar */
          .toolbar { position: sticky; top: 0; z-index: 20; background: var(--bar);
                     backdrop-filter: saturate(180%) blur(14px); -webkit-backdrop-filter: saturate(180%) blur(14px);
                     border-bottom: 1px solid var(--line); }
          .toolbar-inner { max-width: 1240px; margin: 0 auto; padding: 10px 28px;
                           display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
          .search { position: relative; flex: 1 1 260px; min-width: 200px; }
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
          .scene-head { display: flex; align-items: center; gap: 9px; flex-wrap: wrap; cursor: pointer;
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
          .shot-row { display: flex; align-items: center; gap: 7px 12px; padding: 9px 14px; }
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
                   flex: none; margin-left: auto; }
          .media:empty { display: none; }
          .shot-row .media .thumb-label { display: none; }
          .shot-row .media .mi:not([open]) > summary,
          .shot-row .media .mi:not([open]) > summary img,
          .shot-row .media .mi:not([open]) .thumb-blank { width: 46px; height: 32px; }
          .shot-row .media .mi:not([open]) .play { top: 16px; width: 18px; height: 18px; font-size: 8px; }
          /* Expanded detail rows, revealed by the checkbox; indented under the row. */
          .shot-body { display: none; padding: 4px 15px 13px 40px; }
          .shot-toggle:checked ~ .shot-body { display: block; }
          /* One reference: its photo/video and map side by side. */
          .mi-pair { display: flex; flex-direction: row; gap: 8px; }
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
        \(coverageStyles)</style>
        </head>
        <body>
        <div class="masthead">
          <h1>\(esc(filmName))</h1>
          <div class="sub">\(subtitleBits.joined(separator: " · "))</div>
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
            <div class="search">
              <span class="glass">⌕</span>
              <input id="q" type="search" placeholder="Search scenes, shots, locations, details…" autocomplete="off">
              <button class="clear" id="clearq" type="button" aria-label="Clear search" hidden>×</button>
            </div>
            <div class="chips">
              <button class="chip" data-group="type" data-value="int" type="button">INT</button>
              <button class="chip" data-group="type" data-value="ext" type="button">EXT</button>
              <button class="chip" data-group="time" data-value="day" type="button">Day</button>
              <button class="chip chip-night" data-group="time" data-value="night" type="button">Night</button>
              <button class="chip" data-group="media" data-value="media" type="button">Has media</button>
            </div>
            <div class="tools">
              <span class="count" id="count"></span>
              <button class="linkbtn" id="reset" type="button" hidden>Reset</button>
              <button class="linkbtn" id="toggleall" type="button">Collapse all</button>
            </div>
          </div>
        </div>

        <div class="layout">
          <nav class="toc" id="toc">
            <div class="toc-title">Scenes</div>
        \(toc)  </nav>
          <main id="main">
        \(body)    <div class="noresults" id="noresults" hidden>
              <p><b>No matching shots.</b></p>
              <p>Try a different search or clear the filters.</p>
            </div>
          </main>
        </div>

        <button class="totop" id="totop" type="button" aria-label="Back to top" hidden>↑</button>

        <script>
        (function () {
          var scenes = Array.prototype.slice.call(document.querySelectorAll('.scene'));
          var tocItems = Array.prototype.slice.call(document.querySelectorAll('.toc-item'));
          var q = document.getElementById('q');
          var clearq = document.getElementById('clearq');
          var countEl = document.getElementById('count');
          var resetEl = document.getElementById('reset');
          var toggleAll = document.getElementById('toggleall');
          var noresults = document.getElementById('noresults');
          var chips = Array.prototype.slice.call(document.querySelectorAll('.chip'));
          var active = { type: null, time: null, media: false };

          // Reveal the filter bar only now that we know scripting is available.
          document.getElementById('toolbar').hidden = false;

          function tocFor(id) {
            for (var i = 0; i < tocItems.length; i++) {
              if (tocItems[i].getAttribute('data-for') === id) return tocItems[i];
            }
            return null;
          }

          function apply() {
            var term = q.value.trim().toLowerCase();
            var shownScenes = 0, shownShots = 0, totalShots = 0;

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
            countEl.textContent = filtering
              ? shownScenes + ' of ' + scenes.length + ' scenes · ' + shownShots + ' of ' + totalShots + ' shots'
              : scenes.length + ' scenes · ' + totalShots + ' shots';
            resetEl.hidden = !filtering;
            clearq.hidden = term === '';
            noresults.hidden = shownScenes !== 0;
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
          // of them at once.
          toggleAll.addEventListener('click', function () {
            var collapse = toggleAll.textContent.indexOf('Collapse') === 0;
            scenes.forEach(function (s) { s.open = !collapse; });
            toggleAll.textContent = collapse ? 'Expand all' : 'Collapse all';
          });

          // Enlarging a thumbnail is pure <details> — no script involved, so it
          // works in previews with JavaScript disabled. Script only adds the
          // niceties: one open at a time, and stopping a video when it closes.
          var mediaItems = Array.prototype.slice.call(document.querySelectorAll('.mi'));
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
                  tocItems.forEach(function (i) { i.classList.remove('active'); });
                  item.classList.add('active');
                }
              });
            }, { rootMargin: '-70px 0px -70% 0px' });
            scenes.forEach(function (s) { observer.observe(s); });
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
                if !shot.format.isEmpty {
                    output += detailRow("Format", shot.format)
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

    private func calculateCoverageLineX(
        at verticalRange: ClosedRange<CGFloat>,
        within xRange: ClosedRange<CGFloat>,
        existingLines: inout [(range: ClosedRange<CGFloat>, offset: CGFloat, slot: Int)]
    ) -> CGFloat {
        let usableWidth = xRange.upperBound - xRange.lowerBound
        guard usableWidth > 0 else {
            return xRange.lowerBound
        }

        let slotCount = 8
        let slotStep = usableWidth / CGFloat(slotCount)

        for slotIndex in 0..<slotCount {
            let candidateX = xRange.upperBound - ((CGFloat(slotIndex) + 0.5) * slotStep)
            let conflicts = existingLines.contains { existing in
                existing.slot == slotIndex && existing.range.overlaps(verticalRange)
            }

            if !conflicts {
                existingLines.append((range: verticalRange, offset: candidateX, slot: slotIndex))
                return candidateX
            }
        }

        let fallbackX = xRange.lowerBound
        existingLines.append((range: verticalRange, offset: fallbackX, slot: slotCount - 1))
        return fallbackX
    }

    private func calculateCoverageLineX(
        preferredSlot: Int?,
        at verticalRange: ClosedRange<CGFloat>,
        within xRange: ClosedRange<CGFloat>,
        existingLines: inout [(range: ClosedRange<CGFloat>, offset: CGFloat, slot: Int)]
    ) -> (x: CGFloat, slot: Int) {
        let usableWidth = xRange.upperBound - xRange.lowerBound
        guard usableWidth > 0 else {
            let fallbackSlot = max(0, min(7, preferredSlot ?? 7))
            return (xRange.lowerBound, fallbackSlot)
        }

        let slotCount = 8
        let slotStep = usableWidth / CGFloat(slotCount)

        func candidateX(for slotIndex: Int) -> CGFloat {
            xRange.upperBound - ((CGFloat(slotIndex) + 0.5) * slotStep)
        }

        func slotIsFree(_ slotIndex: Int) -> Bool {
            !existingLines.contains { existing in
                existing.slot == slotIndex && existing.range.overlaps(verticalRange)
            }
        }

        if let preferredSlot {
            let clampedPreferredSlot = max(0, min(slotCount - 1, preferredSlot))
            if slotIsFree(clampedPreferredSlot) {
                let x = candidateX(for: clampedPreferredSlot)
                existingLines.append((range: verticalRange, offset: x, slot: clampedPreferredSlot))
                return (x, clampedPreferredSlot)
            }

            for slotIndex in clampedPreferredSlot..<slotCount {
                if slotIsFree(slotIndex) {
                    let x = candidateX(for: slotIndex)
                    existingLines.append((range: verticalRange, offset: x, slot: slotIndex))
                    return (x, slotIndex)
                }
            }

            for slotIndex in 0..<clampedPreferredSlot {
                if slotIsFree(slotIndex) {
                    let x = candidateX(for: slotIndex)
                    existingLines.append((range: verticalRange, offset: x, slot: slotIndex))
                    return (x, slotIndex)
                }
            }
        }

        for slotIndex in 0..<slotCount {
            if slotIsFree(slotIndex) {
                let x = candidateX(for: slotIndex)
                existingLines.append((range: verticalRange, offset: x, slot: slotIndex))
                return (x, slotIndex)
            }
        }

        let fallbackSlot = slotCount - 1
        let fallbackX = candidateX(for: fallbackSlot)
        existingLines.append((range: verticalRange, offset: fallbackX, slot: fallbackSlot))
        return (fallbackX, fallbackSlot)
    }

    private func exportLineRange(for pageRect: CGRect) -> ClosedRange<CGFloat> {
        let minimumPageX = pageRect.minX
        let maximumPageX = pageRect.maxX - 6
        let marginLimitX = pageRect.minX + (pageRect.width * 0.15)
        let upperBound = min(maximumPageX, marginLimitX)
        let lowerBound = min(minimumPageX, upperBound)
        return lowerBound...upperBound
    }

    private func exportLineSlotSpacing(for pageRect: CGRect) -> CGFloat {
        let xRange = exportLineRange(for: pageRect)
        let slotCount = 8
        let usableWidth = xRange.upperBound - xRange.lowerBound
        return usableWidth / CGFloat(slotCount)
    }

    private func exportLineX(for slotIndex: Int, pageRect: CGRect) -> CGFloat {
        let xRange = exportLineRange(for: pageRect)
        let spacing = exportLineSlotSpacing(for: pageRect)
        return xRange.upperBound - ((CGFloat(slotIndex) + 0.5) * spacing)
    }

    private func exportSlotIndex(for lineX: CGFloat, pageRect: CGRect) -> Int {
        let xRange = exportLineRange(for: pageRect)
        let spacing = max(exportLineSlotSpacing(for: pageRect), 1)
        let rawIndex = Int(floor((xRange.upperBound - lineX) / spacing))
        return max(0, min(7, rawIndex))
    }

    private func exportLineCollisionRects(
        from lines: [(range: ClosedRange<CGFloat>, offset: CGFloat, slot: Int)],
        horizontalPadding: CGFloat = 5,
        verticalPadding: CGFloat = 2
    ) -> [CGRect] {
        lines.map { line in
            CGRect(
                x: line.offset - horizontalPadding,
                y: line.range.lowerBound - verticalPadding,
                width: horizontalPadding * 2,
                height: (line.range.upperBound - line.range.lowerBound) + (verticalPadding * 2)
            )
        }
    }

    private func resolvedExportLabelRect(
        desiredRect: CGRect,
        lineX: CGFloat,
        lineTopY: CGFloat,
        pageBounds: CGRect,
        existingLineRects: [CGRect],
        placedLabelRects: [CGRect]
    ) -> CGRect {
        let topGap: CGFloat = 4
        let sideGap: CGFloat = 8
        let verticalStep: CGFloat = desiredRect.height + 3
        let halfHeight = desiredRect.height / 2

        func clampedX(_ originX: CGFloat) -> CGFloat {
            min(max(originX, pageBounds.minX), max(pageBounds.minX, pageBounds.maxX - desiredRect.width))
        }

        func candidate(_ originX: CGFloat, _ originY: CGFloat) -> CGRect {
            CGRect(x: clampedX(originX), y: originY, width: desiredRect.width, height: desiredRect.height)
        }

        var candidates: [CGRect] = []
        for step in 0..<8 {
            let y = lineTopY + topGap + (CGFloat(step) * verticalStep)
            candidates.append(candidate(lineX - (desiredRect.width / 2), y))
        }

        candidates.append(candidate(lineX + sideGap, lineTopY - halfHeight))
        candidates.append(candidate(lineX - desiredRect.width - sideGap, lineTopY - halfHeight))

        for step in 1..<8 {
            let y = lineTopY + topGap + (CGFloat(step) * verticalStep)
            candidates.append(candidate(lineX + sideGap, y))
            candidates.append(candidate(lineX - desiredRect.width - sideGap, y))
        }

        for rect in candidates {
            let overlapsLine = existingLineRects.contains { $0.intersects(rect) }
            let overlapsLabel = placedLabelRects.contains { $0.intersects(rect.insetBy(dx: -2, dy: -1)) }
            if !overlapsLine && !overlapsLabel {
                return rect
            }
        }

        return candidates.last ?? desiredRect
    }
    
    private func createScriptWithCoverage() -> Data? {
        var result: Data?
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        light.performAsCurrentDrawingAppearance {
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
        let shotColors: [NSColor] = [
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
        var shotBaseColors: [ObjectIdentifier: (colorIndex: Int, color: NSColor)] = [:]
        
        print("🎨 [EXPORT COLOR] Step 1: Assigning base colors to shots...")
        for scene in exportScenes {
            for shot in scene.shots {
                guard let shotIndex = scene.shots.firstIndex(where: { $0 === shot }) else { continue }
                let colorIndex = shotIndex % shotColors.count
                shotBaseColors[ObjectIdentifier(shot)] = (colorIndex, shotColors[colorIndex])
                print("   - Scene \(scene.sceneNumber)\(scene.suffix), Shot \(shot.displayNumber): Base color index \(colorIndex)")
            }
        }
        
        print("✅ [EXPORT COLOR] Base color assignment complete")
        
        var selectionColorIndices: [String: Int] = [:]
        var selectionSlotIndices: [String: Int] = [:]
        var occupiedRangesByPageAndSlot: [Int: [Int: [ClosedRange<CGFloat>]]] = [:]
        
        struct ExportSelectionLayout {
            let key: String
            let shot: Shot
            let preferredColorIndex: Int
            let pageRanges: [(pageIndex: Int, range: ClosedRange<CGFloat>)]
        }
        
        var exportSelectionLayouts: [ExportSelectionLayout] = []
        for scene in exportScenes {
            for shot in scene.shots {
                guard let selections = shot.scriptCoverageSelections,
                      let baseColorInfo = shotBaseColors[ObjectIdentifier(shot)] else {
                    continue
                }
                
                for selection in selections {
                    var layoutRanges: [(pageIndex: Int, range: ClosedRange<CGFloat>)] = []
                    let allPageIndices = selection.pageRanges.map { $0.pageIndex }.sorted()
                    let isMultiPage = allPageIndices.count > 1
                    
                    for pageRange in selection.pageRanges {
                        guard let page = sourcePDF.page(at: pageRange.pageIndex),
                              let firstSelection = pageRange.selections.first else {
                            continue
                        }
                        
                        let pageRect = page.bounds(for: .cropBox)
                        var minY = firstSelection.cgRect.minY
                        var maxY = firstSelection.cgRect.maxY
                        for selectionBounds in pageRange.selections {
                            let rect = selectionBounds.cgRect
                            minY = min(minY, rect.minY)
                            maxY = max(maxY, rect.maxY)
                        }
                        
                        if isMultiPage {
                            let isFirstPage = pageRange.pageIndex == allPageIndices.first
                            let isLastPage = pageRange.pageIndex == allPageIndices.last
                            if !isFirstPage {
                                maxY = pageRect.maxY
                            }
                            if !isLastPage {
                                minY = pageRect.minY
                            }
                        }
                        
                        layoutRanges.append((pageIndex: pageRange.pageIndex, range: minY...maxY))
                    }
                    
                    exportSelectionLayouts.append(
                        ExportSelectionLayout(
                            key: "\(shot.id)_\(selection.id)",
                            shot: shot,
                            preferredColorIndex: baseColorInfo.colorIndex,
                            pageRanges: layoutRanges.sorted { $0.pageIndex < $1.pageIndex }
                        )
                    )
                }
            }
        }
        
        exportSelectionLayouts.sort { lhs, rhs in
            let lhsFirstPage = lhs.pageRanges.first?.pageIndex ?? 0
            let rhsFirstPage = rhs.pageRanges.first?.pageIndex ?? 0
            if lhsFirstPage != rhsFirstPage {
                return lhsFirstPage < rhsFirstPage
            }
            if lhs.preferredColorIndex != rhs.preferredColorIndex {
                return lhs.preferredColorIndex < rhs.preferredColorIndex
            }
            return lhs.shot.displayNumber < rhs.shot.displayNumber
        }
        
        for layout in exportSelectionLayouts {
            let assignedSlot = (0..<8).first { slotIndex in
                layout.pageRanges.allSatisfy { pageRange in
                    let occupiedRanges = occupiedRangesByPageAndSlot[pageRange.pageIndex]?[slotIndex] ?? []
                    return !occupiedRanges.contains { $0.overlaps(pageRange.range) }
                }
            } ?? 7
            
            selectionSlotIndices[layout.key] = assignedSlot
            selectionColorIndices[layout.key] = layout.preferredColorIndex
            
            for pageRange in layout.pageRanges {
                occupiedRangesByPageAndSlot[pageRange.pageIndex, default: [:]][assignedSlot, default: []].append(pageRange.range)
            }
        }
        
        // Process each page
        for pageIndex in 0..<sourcePDF.pageCount {
            guard let page = sourcePDF.page(at: pageIndex) else { continue }
            
            let pageRect = page.bounds(for: .cropBox)
            
            context.beginPDFPage(nil)
            
            // Set up NSGraphicsContext for drawing
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext
            
            // Draw the original page using PDFPage's draw method
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            
            // Draw coverage lines if any exist on this page
            if let coverages = coverageByPage[pageIndex] {
                print("📝 [SCRIPT_COVERAGE] Drawing \(coverages.count) coverage item(s) on page \(pageIndex + 1)")
                
                let sortedCoverages = coverages.sorted { (item1, item2) -> Bool in
                    let key1 = "\(item1.shot.id)_\(item1.selection.id)"
                    let key2 = "\(item2.shot.id)_\(item2.selection.id)"
                    let slot1 = selectionSlotIndices[key1]
                    let slot2 = selectionSlotIndices[key2]
                    
                    // Reserve continuing selections first so new selections adapt to them.
                    if (slot1 != nil) != (slot2 != nil) {
                        return slot1 != nil
                    }
                    if let slot1, let slot2, slot1 != slot2 {
                        return slot1 < slot2
                    }
                    
                    let shot1BaseIndex = shotBaseColors[ObjectIdentifier(item1.shot)]?.colorIndex ?? 0
                    let shot2BaseIndex = shotBaseColors[ObjectIdentifier(item2.shot)]?.colorIndex ?? 0
                    return shot1BaseIndex < shot2BaseIndex
                }
                var placedLines: [(range: ClosedRange<CGFloat>, offset: CGFloat, slot: Int)] = []
                var shotNumberRects: [CGRect] = []
                var usedColorIndices: Set<Int> = []
                
                for (shot, selection) in sortedCoverages {
                    // Find the page range for this specific page
                    guard let pageRange = selection.pageRanges.first(where: { $0.pageIndex == pageIndex }) else {
                        continue
                    }
                    let selectionKey = "\(shot.id)_\(selection.id)"

                    guard let baseColorInfo = shotBaseColors[ObjectIdentifier(shot)] else {
                        print("   ⚠️ No base color assigned for shot \(shot.displayNumber)")
                        continue
                    }

                    let preferredColorIndex = baseColorInfo.colorIndex
                    let finalColorIndex: Int
                    if let persistedColorIndex = selectionColorIndices[selectionKey] {
                        finalColorIndex = persistedColorIndex
                    } else if !usedColorIndices.contains(preferredColorIndex) {
                        finalColorIndex = preferredColorIndex
                    } else {
                        finalColorIndex = (0..<shotColors.count).first { !usedColorIndices.contains($0) } ?? preferredColorIndex
                    }
                    usedColorIndices.insert(finalColorIndex)
                    selectionColorIndices[selectionKey] = finalColorIndex
                    let lineColor = shotColors[finalColorIndex]
                    
                    print("   🖊️ [EXPORT DRAW] Drawing line for shot \(shot.displayNumber)")
                    print("      - Color: \(lineColor)")

                    // Get first selection bounds for Y calculation
                    guard let firstSelection = pageRange.selections.first else { continue }
                    let firstRect = firstSelection.cgRect
                    
                    // Calculate bounds for this page
                    var minY = firstRect.minY
                    var maxY = firstRect.maxY
                    
                    for selectionBounds in pageRange.selections {
                        let rect = selectionBounds.cgRect
                        minY = min(minY, rect.minY)
                        maxY = max(maxY, rect.maxY)
                    }
                    
                    print("      - Y range: \(minY) to \(maxY)")
                    
                    // Check if this selection spans multiple pages
                    let allPageIndices = selection.pageRanges.map { $0.pageIndex }.sorted()
                    let isMultiPage = allPageIndices.count > 1
                    let isFirstPage = pageIndex == allPageIndices.first
                    let isLastPage = pageIndex == allPageIndices.last
                    
                    if isMultiPage {
                        print("      - Multi-page: first=\(isFirstPage), last=\(isLastPage)")
                    }
                    
                    // Extend line to page boundaries if it continues to other pages
                    if isMultiPage {
                        if !isFirstPage {
                            // Continue from top of page
                            maxY = pageRect.maxY
                        }
                        if !isLastPage {
                            // Continue to bottom of page
                            minY = pageRect.minY
                        }
                    }
                    
                    let finalSlotIndex: Int
                    let finalLineX: CGFloat
                    if let persistedSlotIndex = selectionSlotIndices[selectionKey] {
                        finalSlotIndex = persistedSlotIndex
                        finalLineX = exportLineX(for: finalSlotIndex, pageRect: pageRect)
                        placedLines.append((range: minY...maxY, offset: finalLineX, slot: finalSlotIndex))
                    } else {
                        let linePlacement = calculateCoverageLineX(
                            preferredSlot: nil,
                            at: minY...maxY,
                            within: exportLineRange(for: pageRect),
                            existingLines: &placedLines
                        )
                        finalLineX = linePlacement.x
                        finalSlotIndex = linePlacement.slot
                    }
                    print("      - X position: \(finalLineX)")
                    
                    // Draw vertical line
                    let lineWidth: CGFloat = 3
                    
                    context.setStrokeColor(lineColor.cgColor)
                    context.setLineWidth(lineWidth)
                    context.move(to: CGPoint(x: finalLineX, y: minY))
                    context.addLine(to: CGPoint(x: finalLineX, y: maxY))
                    context.strokePath()
                    
                    print("      ✅ Drew line from (\(finalLineX), \(minY)) to (\(finalLineX), \(maxY))")
                    
                    // Draw shot number ABOVE the line (only on first page or if text starts on this page)
                    if isFirstPage || (!isMultiPage) {
                        let shotNumberText = shot.displayNumber
                        let font = NSFont.systemFont(ofSize: 9)
                        let textAttributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: lineColor
                        ]
                        
                        let attrString = NSAttributedString(string: shotNumberText, attributes: textAttributes)
                        let textSize = attrString.size()
                        
                        // Use the actual top of the selection (not extended maxY)
                        var actualMaxY = firstRect.maxY
                        for selectionBounds in pageRange.selections {
                            actualMaxY = max(actualMaxY, selectionBounds.cgRect.maxY)
                        }
                        
                        let desiredRect = CGRect(
                            x: finalLineX - (textSize.width / 2),
                            y: actualMaxY + 4,
                            width: textSize.width,
                            height: textSize.height
                        )
                        let pageBounds = CGRect(
                            x: pageRect.minX + 6,
                            y: pageRect.minY,
                            width: max(0, pageRect.width - 12),
                            height: pageRect.height
                        )
                        let labelRect = resolvedExportLabelRect(
                            desiredRect: desiredRect,
                            lineX: finalLineX,
                            lineTopY: actualMaxY,
                            pageBounds: pageBounds,
                            existingLineRects: exportLineCollisionRects(from: placedLines),
                            placedLabelRects: shotNumberRects
                        )
                        
                        attrString.draw(at: CGPoint(x: labelRect.minX, y: labelRect.minY))
                        
                        shotNumberRects.append(labelRect)
                    }
                }
            }
            
            context.endPDFPage()
        }
        
        context.closePDF()
        
        print("✅ [SCRIPT_COVERAGE] Script with coverage created successfully")
        return outputData as Data
    }
    
    /// A PDF is always drawn on white paper, but NSColor.textColor and friends are
    /// dynamic: in dark mode they resolve to white, producing a page of invisible
    /// text. Drawing inside the light appearance pins every system colour to its
    /// light-mode value.
    private func createPDFData(from text: String) -> Data? {
        var result: Data?
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        light.performAsCurrentDrawingAppearance {
            result = buildPDFData(from: text)
        }
        return result
    }

    private func buildPDFData(from text: String) -> Data? {
        print("🔵 [PDF] Creating PDF with new layout")
        
        // Define page size (US Letter)
        let pageWidth: CGFloat = 612  // 8.5" x 72 DPI
        let pageHeight: CGFloat = 792 // 11" x 72 DPI
        let margin: CGFloat = 36      // 0.5" margins
        
        let textWidth = pageWidth - (margin * 2)
        let textHeight = pageHeight - (margin * 2)
        
        // Create PDF data
        let pdfData = NSMutableData()
        
        // Create PDF context
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            print("❌ [PDF] Failed to create data consumer")
            return nil
        }
        
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            print("❌ [PDF] Failed to create PDF context")
            return nil
        }
        
        var pageNumber = 0
        
        // PAGE 1: Project Information and Statistics
        pageNumber += 1
        pdfContext.beginPDFPage(nil)
        pdfContext.saveGState()
        pdfContext.translateBy(x: 0, y: pageHeight)
        pdfContext.scaleBy(x: 1.0, y: -1.0)
        
        let nsContext = NSGraphicsContext(cgContext: pdfContext, flipped: true)
        NSGraphicsContext.current = nsContext
        
        // Draw first page content
        drawFirstPage(in: pdfContext, pageWidth: pageWidth, pageHeight: pageHeight, margin: margin, textWidth: textWidth)
        
        pdfContext.restoreGState()
        pdfContext.endPDFPage()
        
        // Scenes flow continuously: a new scene continues on the current page
        // when there's room, only breaking to a new page when it must — but a
        // scene header is never left stranded at the foot of a page without at
        // least its first shot.
        let orderedScenes = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        var yPosition: CGFloat = 0
        var pageOpen = false

        func beginContentPage() {
            pdfContext.beginPDFPage(nil)
            pdfContext.saveGState()
            pdfContext.translateBy(x: 0, y: pageHeight)
            pdfContext.scaleBy(x: 1.0, y: -1.0)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdfContext, flipped: true)
            yPosition = margin
            pageOpen = true
            pageNumber += 1
        }
        func endContentPage() {
            if pageOpen { pdfContext.restoreGState(); pdfContext.endPDFPage(); pageOpen = false }
        }

        let headerHeight: CGFloat = 42
        for scene in orderedScenes {
            let orderedShots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
            let firstShotHeight = orderedShots.first.map { shotCardHeight($0, textWidth: textWidth) } ?? 30
            let needed = headerHeight + min(firstShotHeight, pageHeight - margin * 2 - headerHeight)

            if !pageOpen || yPosition + needed > pageHeight - margin {
                endContentPage(); beginContentPage()
            } else {
                yPosition += 16   // gap before a new scene sharing the page
            }
            yPosition = drawSceneHeaderRow(scene, in: pdfContext, at: yPosition, margin: margin, pageWidth: pageWidth)

            if orderedShots.isEmpty {
                NSAttributedString(string: "No shots in this scene.",
                                   attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
                    .draw(at: CGPoint(x: margin, y: yPosition))
                yPosition += 18
                continue
            }

            for shot in orderedShots {
                let h = shotCardHeight(shot, textWidth: textWidth)
                if yPosition + h > pageHeight - margin {
                    endContentPage(); beginContentPage()
                    yPosition = drawSceneContinuationHeader(scene, in: pdfContext, at: yPosition, margin: margin, pageWidth: pageWidth)
                }
                yPosition = drawShotCard(shot, in: pdfContext, at: yPosition, margin: margin, textWidth: textWidth) + 10
            }
        }
        endContentPage()
        
        // Close the PDF
        pdfContext.closePDF()
        
        print("✅ [PDF] Created PDF with \(pageNumber) page(s)")
        
        return pdfData as Data
    }
    
    private func drawFirstPage(in context: CGContext, pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat, textWidth: CGFloat) {
        var yPosition: CGFloat = margin
        
        // Title
        let titleFont = NSFont.boldSystemFont(ofSize: 24)
        let titleText = "\(project.filmName.uppercased())\nSHOT LIST"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.textColor
        ]
        let titleAttrString = NSAttributedString(string: titleText, attributes: titleAttributes)
        let titleRect = CGRect(x: margin, y: yPosition, width: textWidth, height: 100)
        titleAttrString.draw(in: titleRect)
        yPosition += 80
        
        // Separator line
        context.setStrokeColor(NSColor.gray.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: margin, y: yPosition))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
        context.strokePath()
        yPosition += 20
        
        // Project Information Section
        let sectionFont = NSFont.boldSystemFont(ofSize: 14)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        
        let sectionTitle = "PROJECT INFORMATION"
        let sectionAttr: [NSAttributedString.Key: Any] = [.font: sectionFont, .foregroundColor: NSColor.textColor]
        NSAttributedString(string: sectionTitle, attributes: sectionAttr).draw(at: CGPoint(x: margin, y: yPosition))
        yPosition += 25
        
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        
        let stats = calculateStatistics()
        
        let projectInfo = [
            "Film Name:        \(project.filmName)",
            "Exported:         \(formatter.string(from: Date()))",
            "Total Scenes:     \(exportScenes.count)",
            "Total Shots:      \(exportScenes.reduce(0) { $0 + $1.shots.count })",
            "INT/DAY Scenes:   \(stats.intDayCount)",
            "INT/NIGHT Scenes: \(stats.intNightCount)",
            "EXT/DAY Scenes:   \(stats.extDayCount)",
            "EXT/NIGHT Scenes: \(stats.extNightCount)"
        ]
        
        let bodyAttr: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        for info in projectInfo {
            NSAttributedString(string: info, attributes: bodyAttr).draw(at: CGPoint(x: margin, y: yPosition))
            yPosition += 18
        }
    }
    
    // Chip colours mirror the web export: neutral INT/EXT, blue DAY, orange
    // NIGHT. The text label lives inside each chip, so it still reads in B&W.
    private static let pdfChipNeutral = (fill: NSColor(white: 0.90, alpha: 1), text: NSColor(white: 0.30, alpha: 1))
    private static let pdfChipDay = (fill: NSColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1), text: NSColor(red: 0.0, green: 0.40, blue: 0.85, alpha: 1))
    private static let pdfChipNight = (fill: NSColor(red: 1.0, green: 0.90, blue: 0.76, alpha: 1), text: NSColor(red: 0.70, green: 0.42, blue: 0.0, alpha: 1))

    /// Draws a small rounded chip (INT/EXT/DAY/NIGHT). Returns the x just past it.
    @discardableResult
    private func drawPDFChip(_ text: String, fill: NSColor, textColor: NSColor,
                             at point: CGPoint) -> CGFloat {
        let font = NSFont.boldSystemFont(ofSize: 8)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let padX: CGFloat = 5
        let rect = CGRect(x: point.x, y: point.y, width: size.width + padX * 2, height: size.height + 4)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + padX, y: point.y + 2),
                                withAttributes: [.font: font, .foregroundColor: textColor])
        return rect.maxX
    }

    /// The scene header row: "Scene N" + INT/EXT and DAY/NIGHT chips + location,
    /// with the script page and shot count on the right. Returns the new y.
    private func drawSceneHeaderRow(_ scene: Scene, in context: CGContext, at y: CGFloat,
                                    margin: CGFloat, pageWidth: CGFloat) -> CGFloat {
        var yPosition = y
        let titleFont = NSFont.boldSystemFont(ofSize: 16)
        let title = "Scene \(scene.sceneNumber)\(scene.suffix)"
        NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: NSColor.black])
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
                               attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
                .draw(at: CGPoint(x: cx, y: yPosition + 3))
        }

        var rightBits: [String] = []
        if scene.scriptPageNumber > 0 { rightBits.append("Script p.\(scene.scriptPageNumber)") }
        rightBits.append("\(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s")")
        let rightText = rightBits.joined(separator: " · ")
        let rightAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.5, alpha: 1)]
        let rw = (rightText as NSString).size(withAttributes: rightAttr).width
        NSAttributedString(string: rightText, attributes: rightAttr)
            .draw(at: CGPoint(x: pageWidth - margin - rw, y: yPosition + 5))

        yPosition += 26
        context.setStrokeColor(NSColor(white: 0.8, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: margin, y: yPosition))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
        context.strokePath()
        return yPosition + 16
    }

    /// A light "Scene N — LOCATION (continued)" line at the top of a page whose
    /// scene carried over from the previous one.
    private func drawSceneContinuationHeader(_ scene: Scene, in context: CGContext, at y: CGFloat,
                                             margin: CGFloat, pageWidth: CGFloat) -> CGFloat {
        var text = "Scene \(scene.sceneNumber)\(scene.suffix)"
        let loc = scene.nickname.trimmingCharacters(in: .whitespaces)
        if !loc.isEmpty { text += " — \(loc.uppercased())" }
        text += " (continued)"
        NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
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
        if !shot.format.isEmpty { pairs.append(("Format", shot.format)) }
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

    // Card layout constants, shared by the height calc and the drawing.
    private static let pdfCardInnerInset: CGFloat = 12
    private static let pdfCardRowH: CGFloat = 15
    private static let pdfCardBodyFont = NSFont.systemFont(ofSize: 9.5)
    /// Vertical space reserved for a reference note line under its image.
    private static let pdfRefNoteH: CGFloat = 14

    private func pdfFullWidthHeight(_ text: String, width: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: Self.pdfCardBodyFont]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    }

    /// The height a shot card will occupy — same formula the drawing uses.
    func shotCardHeight(_ shot: Shot, textWidth: CGFloat) -> CGFloat {
        let c = pdfShotContent(shot)
        let innerWidth = textWidth - Self.pdfCardInnerInset * 2
        let gridRows = Int(ceil(Double(c.pairs.count) / 2.0))
        var h: CGFloat = 22 + CGFloat(gridRows) * Self.pdfCardRowH
        if !c.extra.isEmpty { h += 4 + 12 + pdfFullWidthHeight(c.extra, width: innerWidth) }
        for line in c.coverage { h += 4 + 12 + pdfFullWidthHeight(line, width: innerWidth) }
        var photoH: CGFloat = 0
        let spacing: CGFloat = 12
        for r in c.refs {
            let pw = (r.imageData != nil && r.mapData != nil) ? (innerWidth - spacing) / 2 : min(innerWidth * 0.6, 320)
            photoH += pw * 0.75 + 24
            if Self.cleanNote(r.note) != nil { photoH += Self.pdfRefNoteH }
        }
        if photoH > 0 { h += 8 + photoH }
        return h + 22
    }

    /// Draws one shot card at `yTop`; returns the y just below it.
    private func drawShotCard(_ shot: Shot, in context: CGContext, at yTop: CGFloat,
                              margin: CGFloat, textWidth: CGFloat) -> CGFloat {
        let c = pdfShotContent(shot)
        let ink = NSColor.black
        let grey = NSColor(white: 0.45, alpha: 1)
        let cardFill = NSColor(white: 0.97, alpha: 1)
        let cardStroke = NSColor(white: 0.88, alpha: 1)

        let innerX = margin + Self.pdfCardInnerInset
        let innerWidth = textWidth - Self.pdfCardInnerInset * 2
        let colGap: CGFloat = 16
        let colWidth = (innerWidth - colGap) / 2
        let labelColWidth: CGFloat = 78
        let rowH = Self.pdfCardRowH
        let bodyFont = Self.pdfCardBodyFont
        let bodyBold = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 9)
        let gridRows = Int(ceil(Double(c.pairs.count) / 2.0))
        let cardHeight = shotCardHeight(shot, textWidth: textWidth)

        let cardRect = CGRect(x: margin, y: yTop, width: textWidth, height: cardHeight)
        cardFill.setFill()
        NSBezierPath(roundedRect: cardRect, xRadius: 7, yRadius: 7).fill()
        cardStroke.setStroke()
        let border = NSBezierPath(roundedRect: cardRect, xRadius: 7, yRadius: 7)
        border.lineWidth = 0.5
        border.stroke()

        var cy = yTop + 11
        let badgeFont = NSFont.boldSystemFont(ofSize: 9)
        let badgeW = (shot.displayNumber as NSString).size(withAttributes: [.font: badgeFont]).width
        let badgeRect = CGRect(x: innerX, y: cy, width: badgeW + 12, height: 15)
        NSColor(white: 0.90, alpha: 1).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
        (shot.displayNumber as NSString).draw(at: CGPoint(x: innerX + 6, y: cy + 2),
                                              withAttributes: [.font: badgeFont, .foregroundColor: ink])
        if !shot.nickname.isEmpty {
            NSAttributedString(string: shot.nickname, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: grey])
                .draw(at: CGPoint(x: badgeRect.maxX + 8, y: cy + 1))
        }
        cy += 22

        for (i, pair) in c.pairs.enumerated() {
            let col = i / gridRows, row = i % gridRows
            let px = innerX + CGFloat(col) * (colWidth + colGap)
            let py = cy + CGFloat(row) * rowH
            NSAttributedString(string: pair.0, attributes: [.font: labelFont, .foregroundColor: grey])
                .draw(at: CGPoint(x: px, y: py))
            NSAttributedString(string: pair.1, attributes: [.font: bodyBold, .foregroundColor: ink])
                .draw(in: CGRect(x: px + labelColWidth, y: py, width: colWidth - labelColWidth, height: rowH))
        }
        cy += CGFloat(gridRows) * rowH

        if !c.extra.isEmpty {
            cy += 4
            NSAttributedString(string: "Extra Info", attributes: [.font: labelFont, .foregroundColor: grey]).draw(at: CGPoint(x: innerX, y: cy))
            cy += 12
            let h = pdfFullWidthHeight(c.extra, width: innerWidth)
            NSAttributedString(string: c.extra, attributes: [.font: bodyFont, .foregroundColor: ink]).draw(in: CGRect(x: innerX, y: cy, width: innerWidth, height: h))
            cy += h
        }
        for (idx, line) in c.coverage.enumerated() {
            cy += 4
            if idx == 0 {
                NSAttributedString(string: "Coverage", attributes: [.font: labelFont, .foregroundColor: grey]).draw(at: CGPoint(x: innerX, y: cy))
                cy += 12
            }
            let h = pdfFullWidthHeight(line, width: innerWidth)
            NSAttributedString(string: line, attributes: [.font: bodyFont, .foregroundColor: ink]).draw(in: CGRect(x: innerX, y: cy, width: innerWidth, height: h))
            cy += h
        }

        if !c.refs.isEmpty {
            cy += 8
            let spacing: CGFloat = 12
            func drawFramed(_ data: Data, caption: String, at origin: CGPoint, size: CGSize) {
                guard let nsImage = NSImage(data: data) else { return }
                NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: grey])
                    .draw(at: CGPoint(x: origin.x, y: origin.y))
                let boxY = origin.y + 12
                let s = nsImage.size
                guard s.width > 0, s.height > 0 else { return }
                let aspect = s.width / s.height
                var dw = size.width, dh = size.width / aspect
                if dh > size.height { dh = size.height; dw = dh * aspect }
                let imageRect = CGRect(x: origin.x + (size.width - dw) / 2, y: boxY + (size.height - dh) / 2, width: dw, height: dh)
                context.saveGState()
                context.translateBy(x: 0, y: imageRect.origin.y + imageRect.size.height)
                context.scaleBy(x: 1.0, y: -1.0)
                context.translateBy(x: 0, y: -imageRect.origin.y)
                nsImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                context.restoreGState()
                cardStroke.setStroke()
                let b = NSBezierPath(rect: CGRect(x: origin.x, y: boxY, width: size.width, height: size.height))
                b.lineWidth = 0.5
                b.stroke()
            }
            for (offset, r) in c.refs.enumerated() {
                let both = r.imageData != nil && r.mapData != nil
                let pw = both ? (innerWidth - spacing) / 2 : min(innerWidth * 0.6, 320)
                let ph = pw * 0.75
                let suffix = c.refs.count > 1 ? " \(offset + 1)" : ""
                var px = innerX
                if let data = r.imageData {
                    drawFramed(data, caption: "Reference\(suffix)", at: CGPoint(x: px, y: cy), size: CGSize(width: pw, height: ph))
                    px += pw + spacing
                }
                if let data = r.mapData {
                    drawFramed(data, caption: "Top Down Map\(suffix)", at: CGPoint(x: px, y: cy), size: CGSize(width: pw, height: ph))
                }
                // The user's note, on its own line just below the image(s).
                if let note = Self.cleanNote(r.note) {
                    NSAttributedString(string: note,
                                       attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ink])
                        .draw(with: CGRect(x: innerX, y: cy + 12 + ph + 3, width: innerWidth, height: Self.pdfRefNoteH),
                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                    cy += Self.pdfRefNoteH
                }
                cy += ph + 24
            }
        }
        return yTop + cardHeight
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
