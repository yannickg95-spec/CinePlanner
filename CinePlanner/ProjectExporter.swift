//
//  ProjectExporter.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 25/12/2025.
//

import Foundation
import AppKit
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
        let shots: [MediaShot]
    }

    /// Videos are the only thing that has to live beside the web page as a real
    /// file — photos are embedded in the HTML itself. Without them the export is a
    /// single self-contained page and needs no folder, and so no zip.
    var webExportNeedsFolder: Bool {
        // Tested via the extension, not the Data: the two are always written and
        // cleared together, and reading the blob just to see whether it exists
        // would pull every video in the project into memory.
        exportScenes.contains { $0.shots.contains { $0.references.contains { $0.videoExtension != nil } } }
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
        let needsFolder = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil } } }
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

    private func snapshotScenesForMedia() -> [MediaScene] {
        let ordered = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        let sourcePDF = (version?.pdfData ?? project.scriptPDFData).flatMap { PDFDocument(data: $0) }
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
                            videoExtension: reference.videoExtension ?? "mov"
                        )
                    }
                )
            }
            return MediaScene(heading: heading,
                              subheading: parts.joined(separator: " · "),
                              isInterior: scene.isInterior,
                              isDay: scene.isDay,
                              location: location,
                              coverage: sourcePDF.flatMap { renderSceneCoverage(scene: scene, sourcePDF: $0) },
                              shots: shots)
        }
    }

    private func shotDetails(_ shot: Shot) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if shot.size != .none {
            var s = shot.size.shortVersion
            if shot.secondSize != .none { s += " → " + shot.secondSize.shortVersion }
            rows.append(("Size", s))
        }
        if shot.typeCategory != .none {
            var t = shot.typeCategory.shortDisplayName
            if shot.secondTypeCategory != .none { t += " + " + shot.secondTypeCategory.shortDisplayName }
            if shot.thirdTypeCategory != .none { t += " + " + shot.thirdTypeCategory.shortDisplayName }
            rows.append(("Type", t))
        }
        if shot.lensfocal > 0 {
            rows.append(("Focal Length", shot.lensIsPrime ? "\(shot.lensfocal)mm" : "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"))
        }
        if shot.type != .none { rows.append(("Grip", shot.type.displayName)) }
        if !shot.camera.isEmpty { rows.append(("Camera", shot.camera)) }
        if !shot.format.isEmpty { rows.append(("Format", shot.format)) }
        if !shot.framelines.isEmpty { rows.append(("Framelines", shot.framelines)) }
        if !shot.lensPreset.isEmpty { rows.append(("Lens", shot.lensPreset)) }
        if !shot.extraInfo.isEmpty { rows.append(("Extra info", shot.extraInfo)) }
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
        let hasVideo = scenes.contains { $0.shots.contains { $0.references.contains { $0.videoData != nil } } }
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
                            posterURI: nil
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
                    var videoPath: String?
                    var posterURI: String?
                    if let data = reference.videoData {
                        let name = "media/shot_\(shot.slug)_\(reference.index)_video.\(reference.videoExtension)"
                        try data.write(to: staging.appendingPathComponent(name))
                        videoPath = name
                        if let poster = Self.posterFrame(fromVideoData: data, ext: reference.videoExtension) {
                            posterURI = Self.dataURI(poster)
                        }
                    }
                    rendered[Self.mediaKey(shot.slug, reference.index)] = RenderedMedia(
                        photoURI: reference.photoData.map { Self.dataURI($0) },
                        topDownURI: reference.mapData.map { Self.dataURI($0) },
                        videoPath: videoPath,
                        posterURI: posterURI
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
            let timeLabel = scene.isDay ? "DAY" : "NIGHT"
            let typeLabel = scene.isInterior ? "INT" : "EXT"

            // Everything the search box should be able to find this scene by.
            let sceneSearch = ([scene.heading, scene.location, typeLabel, timeLabel] + scene.shots.map(\.displayNumber))
                .joined(separator: " ").lowercased()
            let shotCount = scene.shots.count
            let mediaCount = scene.shots.filter { m in
                let r = media[m.slug]
                return r?.photoURI != nil || r?.topDownURI != nil || r?.videoPath != nil
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
            body += "  <div class=\"shots\">\n"
            if scene.shots.isEmpty {
                body += "    <p class=\"empty\">No shots in this scene.</p>\n"
            }
            for shot in scene.shots {
                let refs = shot.references.map { (r: MediaReference) in (r, media[Self.mediaKey(shot.slug, r.index)]) }
                let hasMedia = refs.contains { $0.1?.photoURI != nil || $0.1?.topDownURI != nil || $0.1?.videoPath != nil }
                let shotSearch = ([shot.displayNumber, shot.nickname, shot.coverageText ?? ""]
                                  + shot.details.map { "\($0.label) \($0.value)" })
                    .joined(separator: " ").lowercased()

                body += "    <article class=\"shot\" data-media=\"\(hasMedia ? 1 : 0)\" data-text=\"\(esc(shotSearch))\">\n"
                body += "      <div class=\"shot-head\"><span class=\"shot-num\">\(esc(shot.displayNumber))</span>"
                if !shot.nickname.isEmpty { body += "<span class=\"shot-nick\">\(esc(shot.nickname))</span>" }
                if refs.contains(where: { $0.1?.videoPath != nil }) { body += "<span class=\"pill pill-video\">Video</span>" }
                body += "</div>\n"

                body += "      <div class=\"shot-body\">\n"
                // Details first in the markup as well as on screen, so the reading
                // order matches the layout for screen readers and printing.
                body += "        <div class=\"details\">\n"
                if shot.details.isEmpty {
                    body += "          <p class=\"empty\">No details.</p>\n"
                } else {
                    body += "          <div class=\"rows\">\n"
                    for row in shot.details {
                        body += "            <div class=\"row\"><span class=\"k\">\(esc(row.label))</span><span class=\"v\">\(esc(row.value))</span></div>\n"
                    }
                    body += "          </div>\n"
                }
                if shot.coverageText != nil || (shot.hasCoverage && coverageClass != nil) {
                    // Coverage text and the script-coverage thumbnail sit side by
                    // side, so the thumbnail is next to what it illustrates.
                    body += "          <div class=\"coverage-row\">\n"
                    if let coverage = shot.coverageText {
                        // Coverage can run long, so it collapses. <details> again, so
                        // it still opens in previews with JavaScript disabled. Short
                        // coverage starts open — nothing to gain by hiding one line.
                        let startsOpen = coverage.count <= 180
                        body += "            <details class=\"coverage\"\(startsOpen ? " open" : "")>\n"
                        body += "              <summary class=\"coverage-label\">Coverage"
                        if let preview = shot.coveragePreview {
                            body += "<span class=\"coverage-preview\">\(esc(preview))</span>"
                        }
                        body += "</summary>\n"
                        body += "              <div class=\"coverage-text\">\(esc(coverage))</div>\n"
                        body += "            </details>\n"
                    }
                    if shot.hasCoverage, let cls = coverageClass {
                        // Opens the scene's script pages with every shot's coverage
                        // marked — the same image for each covered shot.
                        body += "            <details class=\"mi mi-doc\"><summary title=\"Script coverage for this scene\"><span class=\"cover-thumb \(cls)\"></span><span class=\"thumb-label\">Coverage</span></summary></details>\n"
                    }
                    body += "          </div>\n"
                }
                body += "        </div>\n"
                // Thumbnail strip on the right — small on purpose, so the shot's
                // details lead. Each is a <details>: tapping the thumbnail opens it
                // full screen with no JavaScript, which is what makes it work in
                // Apple's Quick Look preview. The same <img> is reused enlarged, so
                // nothing is embedded twice.
                body += "        <div class=\"media\">\n"
                for (reference, rendered) in refs {
                    guard let m = rendered else { continue }
                    // Each reference is its own row: media and map side by side,
                    // with the next reference below rather than alongside.
                    body += "          <div class=\"mi-pair\">\n"
                    // Label each thumbnail with its reference number when a shot
                    // carries more than one.
                    let tag = shot.references.count > 1 ? " \(reference.index)" : ""
                    if let video = m.videoPath {
                        let mime = video.hasSuffix(".mov") ? "video/quicktime" : "video/mp4"
                        body += "          <details class=\"mi mi-video\">\n            <summary title=\"Play video\">"
                        if let poster = m.posterURI {
                            body += "<img src=\"\(poster)\" alt=\"Video\">"
                        } else {
                            body += "<span class=\"thumb-blank\"></span>"
                        }
                        body += "<span class=\"play\">▶</span><span class=\"thumb-label\">Video\(tag)</span></summary>\n"
                        body += "            <video controls playsinline preload=\"none\"><source src=\"\(video)\" type=\"\(mime)\"></video>\n"
                        body += "          </details>\n"
                    }
                    if let photo = m.photoURI {
                        body += "          <details class=\"mi\"><summary title=\"Reference frame\"><img class=\"still\" src=\"\(photo)\" alt=\"Reference frame\"><span class=\"thumb-label\">Ref\(tag)</span></summary></details>\n"
                    }
                    if let topDown = m.topDownURI {
                        body += "          <details class=\"mi\"><summary title=\"Top-down plan\"><img class=\"still\" src=\"\(topDown)\" alt=\"Top-down plan\"><span class=\"thumb-label\">Map\(tag)</span></summary></details>\n"
                    }
                    body += "          </div>\n"
                }
                if !hasMedia {
                    body += "          <div class=\"nomedia\" title=\"No reference media\">—</div>\n"
                }
                body += "        </div>\n"
                body += "      </div>\n"
                body += "    </article>\n"
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

          /* Shots */
          .shot { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 15px 16px;
                  box-shadow: var(--shadow); }
          .shot + .shot { margin-top: 12px; }
          .shot-head { display: flex; align-items: center; gap: 9px; margin-bottom: 12px; }
          .shot-num { font-weight: 700; font-size: 13px; padding: 3px 9px; border-radius: 6px;
                      background: var(--chip); font-variant-numeric: tabular-nums; }
          .shot-nick { color: var(--muted); font-size: 14px; }
          .pill { font-size: 10px; font-weight: 700; letter-spacing: 0.4px; padding: 3px 7px; border-radius: 5px;
                  background: rgba(10,132,255,0.15); color: var(--accent); }
          /* Thumbnails sit in a narrow column so the details carry the row. */
          .shot-body { display: grid; grid-template-columns: minmax(0,1fr) 196px; gap: 16px; align-items: start; }
          @media (max-width: 700px) { .shot-body { grid-template-columns: minmax(0,1fr); } }
          .media { display: flex; flex-direction: column; gap: 10px; flex: none; }
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
          /* Coverage thumbnail: a small portrait script page showing its top, so
             it reads as the script (not a cropped landscape strip). The image and
             its aspect ratio come from a per-scene rule (.cov-N) so the JPEG is
             embedded once, not per covered shot. */
          .cover-thumb { display: block; width: 60px; height: 84px; border-radius: 6px;
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
          .mi-doc > summary { width: 60px; }
          .mi-doc[open] > summary .thumb-label { display: none; }
          .nomedia { width: 94px; height: 66px; display: flex; align-items: center; justify-content: center;
                     color: var(--faint); border: 1px dashed var(--line-strong); border-radius: 8px; font-size: 13px; }
          .details { min-width: 0; }
          /* Multi-column rather than grid so values read top-to-bottom down one
             column before starting the next, matching the app's shot details. */
          .rows { column-width: 250px; column-gap: 26px; }
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
            .coverage > div { display: block !important; }   /* print collapsed coverage too */
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
                    $0.shots.contains { $0.references.contains { $0.videoData != nil } }
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
        print("🔵 [CONTENT] Thread: \(Thread.current), Main: \(Thread.isMainThread)")
        
        var output = ""
        
        // Header Section
        print("🔵 [CONTENT] Building header...")
        output += String(repeating: "=", count: 80) + "\n"
        
        print("🔵 [CONTENT] Accessing project.filmName...")
        output += "\(project.filmName.uppercased()) - COMPLETE SHOT LIST\n"
        
        output += String(repeating: "=", count: 80) + "\n\n"
        
        // Metadata Section
        print("🔵 [CONTENT] Building metadata section...")
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        
        output += "PROJECT INFORMATION\n"
        output += String(repeating: "-", count: 80) + "\n"
        
        print("🔵 [CONTENT] Accessing project properties...")
        output += "Film Name:        \(project.filmName)\n"
        output += "Created:          \(formatter.string(from: project.createdDate))\n"
        output += "Exported:         \(formatter.string(from: Date()))\n"
        
        print("🔵 [CONTENT] Accessing exportScenes...")
        let sceneCount = exportScenes.count
        print("🔵 [CONTENT] Scene count: \(sceneCount)")
        
        output += "Total Scenes:     \(sceneCount)\n"
        
        print("🔵 [CONTENT] Calculating total shots...")
        let totalShots = exportScenes.reduce(0) { $0 + $1.shots.count }
        print("🔵 [CONTENT] Total shots: \(totalShots)")
        
        output += "Total Shots:      \(totalShots)\n"
        
        // Script info
        print("🔵 [CONTENT] Checking script PDF...")
        if (version?.pdfData ?? project.scriptPDFData) != nil {
            output += "Script PDF:       Attached (imported)\n"
        } else {
            output += "Script PDF:       None\n"
        }
        
        output += "\n"
        
        // Statistics Section
        print("🔵 [CONTENT] Calculating statistics...")
        let stats = calculateStatistics()
        print("✅ [CONTENT] Statistics calculated")
        
        output += "STATISTICS\n"
        output += String(repeating: "-", count: 80) + "\n"
        output += "Shots with Photos:      \(stats.shotsWithPhotos)\n"
        output += "Shots with Coverage:    \(stats.shotsWithCoverage)\n"
        output += "Complete Shots:         \(stats.completeShots) (\(stats.completionPercentage)%)\n"
        output += "INT/DAY Scenes:         \(stats.intDayCount)\n"
        output += "INT/NIGHT Scenes:       \(stats.intNightCount)\n"
        output += "EXT/DAY Scenes:         \(stats.extDayCount)\n"
        output += "EXT/NIGHT Scenes:       \(stats.extNightCount)\n"
        output += "\n\n"
        
        // Shot List
        print("🔵 [CONTENT] Generating shot list details...")
        output += generateExportText()
        print("✅ [CONTENT] Shot list details generated")
        
        // Footer
        print("🔵 [CONTENT] Adding footer...")
        output += "\n" + String(repeating: "=", count: 80) + "\n"
        output += "END OF SHOT LIST\n"
        output += "Generated by CinePlanner on \(formatter.string(from: Date()))\n"
        output += String(repeating: "=", count: 80) + "\n"
        
        print("✅ [CONTENT] Content generation complete!")
        return output
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
    
    private func generateExportText() -> String {
        print("🔵 [EXPORT_TEXT] Starting scene breakdown...")
        var output = ""
        
        output += String(repeating: "=", count: 80) + "\n"
        output += "SCENE BREAKDOWN\n"
        output += String(repeating: "=", count: 80) + "\n"
        
        print("🔵 [EXPORT_TEXT] Sorting scenes by sortOrder...")
        let orderedScenes = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        print("🔵 [EXPORT_TEXT] Processing \(orderedScenes.count) scenes...")
        
        for (sceneIndex, scene) in orderedScenes.enumerated() {
            print("🔵 [EXPORT_TEXT] Scene \(sceneIndex + 1)/\(orderedScenes.count): \(scene.sceneNumber)\(scene.suffix)")
            
            output += "\n"
            output += String(repeating: "━", count: 80) + "\n"
            output += "SCENE \(scene.sceneNumber)\(scene.suffix)"
            if !scene.nickname.isEmpty {
                output += " - \(scene.nickname)"
            }
            output += "\n"
            output += "Location: \(scene.isInterior ? "INT" : "EXT")   Time: \(scene.isDay ? "DAY" : "NIGHT")"
            
            // Add script page info if available
            if scene.scriptPageNumber > 0 {
                output += "   Script Page: \(scene.scriptPageNumber)"
            }
            
            output += "\n"
            
            print("🔵 [EXPORT_TEXT] Accessing scene.shots for scene \(scene.sceneNumber)...")
            let shotCount = scene.shots.count
            print("🔵 [EXPORT_TEXT] Scene \(scene.sceneNumber) has \(shotCount) shots")
            
            output += "Total Shots: \(shotCount)\n"
            output += String(repeating: "━", count: 80) + "\n\n"
            
            print("🔵 [EXPORT_TEXT] Sorting shots for scene \(scene.sceneNumber)...")
            let orderedShots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
            
            if orderedShots.isEmpty {
                output += "  (No shots in this scene)\n\n"
            } else {
                for (shotIndex, shot) in orderedShots.enumerated() {
                    print("🔵 [EXPORT_TEXT]   Shot \(shotIndex + 1)/\(orderedShots.count): \(shot.displayNumber)")
                    
                    output += "  ┌─ SHOT \(shot.displayNumber)"
                    if !shot.nickname.isEmpty {
                        output += " - \(shot.nickname)"
                    }
                    output += "\n"
                    
                    // Shot details
                    var hasDetails = false
                    
                    if shot.size != .none {
                        var sizeText = ""
                        if shot.size != .none {
                            sizeText = shot.size.shortVersion
                            if shot.secondSize != .none {
                                sizeText += " → " + shot.secondSize.shortVersion
                            }
                        }
                        output += "  │  Size:         \(sizeText)\n"
                        hasDetails = true
                    }
                    
                    if shot.typeCategory != .none {
                        var typeText = shot.typeCategory.shortDisplayName
                        if shot.secondTypeCategory != .none {
                            typeText += " + " + shot.secondTypeCategory.shortDisplayName
                        }
                        if shot.thirdTypeCategory != .none {
                            typeText += " + " + shot.thirdTypeCategory.shortDisplayName
                        }
                        output += "  │  Type:         \(typeText)\n"
                        hasDetails = true
                    }
                    
                    if shot.lensfocal > 0 {
                        if shot.lensIsPrime {
                            output += "  │  Focal Length: \(shot.lensfocal)mm\n"
                        } else {
                            output += "  │  Focal Length: \(shot.lensfocal)→\(shot.lensfocalEnd)mm\n"
                        }
                        hasDetails = true
                    }
                    
                    if shot.type != .none {
                        output += "  │  Grip:         \(shot.type.displayName)\n"
                        hasDetails = true
                    }
                    
                    if !shot.camera.isEmpty {
                        output += "  │  Camera:       \(shot.camera)\n"
                        hasDetails = true
                    }
                    
                    if !shot.format.isEmpty {
                        output += "  │  Format:       \(shot.format)\n"
                        hasDetails = true
                    }
                    
                    if !shot.framelines.isEmpty {
                        output += "  │  Framelines:   \(shot.framelines)\n"
                        hasDetails = true
                    }
                    
                    if !shot.lensPreset.isEmpty {
                        output += "  │  Lens Preset:  \(shot.lensPreset)\n"
                        hasDetails = true
                    }
                    
                    if !shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        output += "  │  Extra Info:   \(shot.extraInfo)\n"
                        hasDetails = true
                    }
                    
                    // Script coverage
                    print("🔵 [EXPORT_TEXT]   Checking script coverage for shot \(shot.displayNumber)...")
                    if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                        print("🔵 [EXPORT_TEXT]   Shot has \(selections.count) coverage selection(s)")
                        output += "  │  Coverage:     \(selections.count) selection\(selections.count == 1 ? "" : "s")\n"
                        for (index, selection) in selections.enumerated() {
                            let prefix = index == selections.count - 1 ? "  │               └─" : "  │               ├─"
                            output += "\(prefix) \(formatCoverageSummary(selection))\n"
                        }
                        hasDetails = true
                    }
                    
                    if !hasDetails {
                        output += "  │  (No details specified)\n"
                    }
                    
                    output += "  └─\(String(repeating: "─", count: 74))\n\n"
                }
            }
            
            // Add spacing between scenes (except after last scene)
            if sceneIndex < orderedScenes.count - 1 {
                output += "\n"
            }
        }
        
        print("✅ [EXPORT_TEXT] Scene breakdown complete!")
        return output
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
        
        // SUBSEQUENT PAGES: Each scene starts on a new page, but can span multiple pages
        let orderedScenes = exportScenes.sorted { $0.sortOrder < $1.sortOrder }
        
        for scene in orderedScenes {
            // Draw scene across as many pages as needed
            pageNumber = drawSceneAcrossPages(
                scene: scene,
                in: pdfContext,
                startingPageNumber: pageNumber,
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                margin: margin,
                textWidth: textWidth,
                textHeight: textHeight
            )
        }
        
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

    private func drawSceneAcrossPages(
        scene: Scene,
        in context: CGContext,
        startingPageNumber: Int,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat,
        textWidth: CGFloat,
        textHeight: CGFloat
    ) -> Int {
        var currentPage = startingPageNumber
        let orderedShots = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
        var shotIndex = 0
        var isFirstPageOfScene = true
        
        while shotIndex < orderedShots.count || isFirstPageOfScene {
            currentPage += 1
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1.0, y: -1.0)
            
            let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.current = nsContext
            
            var yPosition: CGFloat = margin
            
            // Draw scene header only on first page of scene
            if isFirstPageOfScene {
                // "Scene 5" + INT/EXT and DAY/NIGHT chips + location, with the
                // script page and shot count on the right — like the web export.
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
                                       attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                    .foregroundColor: NSColor(white: 0.45, alpha: 1)])
                        .draw(at: CGPoint(x: cx, y: yPosition + 3))
                }

                var rightBits: [String] = []
                if scene.scriptPageNumber > 0 { rightBits.append("Script p.\(scene.scriptPageNumber)") }
                rightBits.append("\(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s")")
                let rightText = rightBits.joined(separator: " · ")
                let rightAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                                .foregroundColor: NSColor(white: 0.5, alpha: 1)]
                let rw = (rightText as NSString).size(withAttributes: rightAttr).width
                NSAttributedString(string: rightText, attributes: rightAttr)
                    .draw(at: CGPoint(x: pageWidth - margin - rw, y: yPosition + 5))

                yPosition += 26

                // Separator line
                context.setStrokeColor(NSColor(white: 0.8, alpha: 1).cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: margin, y: yPosition))
                context.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
                context.strokePath()
                yPosition += 16

                isFirstPageOfScene = false
            } else {
                // Continuation header on subsequent pages
                let contHeaderFont = NSFont.boldSystemFont(ofSize: 14)
                let contHeaderText = "SCENE \(scene.sceneNumber)\(scene.suffix) (continued)"
                let contHeaderAttr: [NSAttributedString.Key: Any] = [
                    .font: contHeaderFont,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                NSAttributedString(string: contHeaderText, attributes: contHeaderAttr).draw(at: CGPoint(x: margin, y: yPosition))
                yPosition += 25
            }
            
            // Draw shots
            if orderedShots.isEmpty && isFirstPageOfScene {
                let emptyFont = NSFont.systemFont(ofSize: 10)
                let emptyAttr: [NSAttributedString.Key: Any] = [.font: emptyFont, .foregroundColor: NSColor.secondaryLabelColor]
                NSAttributedString(string: "(No shots in this scene)", attributes: emptyAttr).draw(at: CGPoint(x: margin, y: yPosition))
            } else {
                let shotFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
                let shotBoldFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
                
                while shotIndex < orderedShots.count {
                    let shot = orderedShots[shotIndex]

                    // Colours
                    let ink = NSColor.black
                    let grey = NSColor(white: 0.45, alpha: 1)
                    let cardFill = NSColor(white: 0.97, alpha: 1)
                    let cardStroke = NSColor(white: 0.88, alpha: 1)

                    // Short label/value pairs shown in two columns.
                    var pairs: [(String, String)] = []
                    if shot.size != .none {
                        var v = shot.size.shortVersion
                        if shot.secondSize != .none { v += " → " + shot.secondSize.shortVersion }
                        pairs.append(("Size", v))
                    }
                    if shot.typeCategory != .none {
                        var v = shot.typeCategory.shortDisplayName
                        if shot.secondTypeCategory != .none { v += " + " + shot.secondTypeCategory.shortDisplayName }
                        if shot.thirdTypeCategory != .none { v += " + " + shot.thirdTypeCategory.shortDisplayName }
                        pairs.append(("Type", v))
                    }
                    if shot.lensfocal > 0 {
                        pairs.append(("Focal Length", shot.lensIsPrime ? "\(shot.lensfocal)mm" : "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"))
                    }
                    if shot.type != .none { pairs.append(("Grip", shot.type.displayName)) }
                    if !shot.camera.isEmpty { pairs.append(("Camera", shot.camera)) }
                    if !shot.format.isEmpty { pairs.append(("Format", shot.format)) }
                    if !shot.framelines.isEmpty { pairs.append(("Framelines", shot.framelines)) }
                    if !shot.lensPreset.isEmpty { pairs.append(("Lens", shot.lensPreset)) }

                    // Long fields go full width below the grid.
                    let extraInfo = shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines)
                    var coverageLines: [String] = []
                    if let selections = shot.scriptCoverageSelections {
                        coverageLines = selections.map { formatCoverageSummary($0) }
                    }

                    // Reference photo rows (image + map side by side per reference).
                    let referenceRows = shot.orderedReferences.filter { $0.imageData != nil || $0.mapData != nil }

                    // --- Height ---
                    let innerX = margin + 12
                    let innerWidth = textWidth - 24
                    let colGap: CGFloat = 16
                    let colWidth = (innerWidth - colGap) / 2
                    let labelColWidth: CGFloat = 78
                    let rowH: CGFloat = 15
                    let bodyFont = NSFont.systemFont(ofSize: 9.5)
                    let bodyBold = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
                    let labelFont = NSFont.systemFont(ofSize: 9)

                    let gridRows = Int(ceil(Double(pairs.count) / 2.0))
                    var contentHeight: CGFloat = 22 // header (badge + nickname)
                    contentHeight += CGFloat(gridRows) * rowH

                    func fullWidthHeight(_ text: String, font: NSFont) -> CGFloat {
                        NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
                            with: CGSize(width: innerWidth, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                    }
                    if !extraInfo.isEmpty {
                        contentHeight += 4 + 12 + fullWidthHeight(extraInfo, font: bodyFont)
                    }
                    for line in coverageLines {
                        contentHeight += 4 + 12 + fullWidthHeight(line, font: bodyFont)
                    }

                    var photoBlockHeight: CGFloat = 0
                    let photoSpacing: CGFloat = 12
                    let photoAreaWidth = innerWidth
                    for reference in referenceRows {
                        let pairWidth = (reference.imageData != nil && reference.mapData != nil)
                            ? (photoAreaWidth - photoSpacing) / 2
                            : min(photoAreaWidth * 0.6, 320)
                        photoBlockHeight += pairWidth * 0.75 + 24
                    }
                    if photoBlockHeight > 0 { contentHeight += 8 + photoBlockHeight }

                    let cardHeight = contentHeight + 22 // top + bottom padding

                    // --- Page break ---
                    if yPosition + cardHeight > pageHeight - margin && shotIndex > 0 {
                        NSAttributedString(string: "(Continued on next page…)",
                                           attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: grey])
                            .draw(at: CGPoint(x: margin, y: yPosition))
                        break
                    }

                    // --- Card ---
                    let cardTop = yPosition
                    let cardRect = CGRect(x: margin, y: cardTop, width: textWidth, height: cardHeight)
                    cardFill.setFill()
                    NSBezierPath(roundedRect: cardRect, xRadius: 7, yRadius: 7).fill()
                    cardStroke.setStroke()
                    let cardBorder = NSBezierPath(roundedRect: cardRect, xRadius: 7, yRadius: 7)
                    cardBorder.lineWidth = 0.5
                    cardBorder.stroke()

                    var cy = cardTop + 11

                    // Shot number badge + nickname
                    let badgeFont = NSFont.boldSystemFont(ofSize: 9)
                    let badgeText = shot.displayNumber
                    let badgeTextW = (badgeText as NSString).size(withAttributes: [.font: badgeFont]).width
                    let badgeRect = CGRect(x: innerX, y: cy, width: badgeTextW + 12, height: 15)
                    NSColor(white: 0.90, alpha: 1).setFill()
                    NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
                    (badgeText as NSString).draw(at: CGPoint(x: innerX + 6, y: cy + 2),
                                                 withAttributes: [.font: badgeFont, .foregroundColor: ink])
                    if !shot.nickname.isEmpty {
                        NSAttributedString(string: shot.nickname,
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: grey])
                            .draw(at: CGPoint(x: badgeRect.maxX + 8, y: cy + 1))
                    }
                    cy += 22

                    // Two-column details
                    for (i, pair) in pairs.enumerated() {
                        let col = i / gridRows
                        let row = i % gridRows
                        let px = innerX + CGFloat(col) * (colWidth + colGap)
                        let py = cy + CGFloat(row) * rowH
                        NSAttributedString(string: pair.0, attributes: [.font: labelFont, .foregroundColor: grey])
                            .draw(at: CGPoint(x: px, y: py))
                        NSAttributedString(string: pair.1, attributes: [.font: bodyBold, .foregroundColor: ink])
                            .draw(in: CGRect(x: px + labelColWidth, y: py, width: colWidth - labelColWidth, height: rowH))
                    }
                    cy += CGFloat(gridRows) * rowH

                    // Extra info (full width)
                    if !extraInfo.isEmpty {
                        cy += 4
                        NSAttributedString(string: "Extra Info", attributes: [.font: labelFont, .foregroundColor: grey])
                            .draw(at: CGPoint(x: innerX, y: cy))
                        cy += 12
                        let h = fullWidthHeight(extraInfo, font: bodyFont)
                        NSAttributedString(string: extraInfo, attributes: [.font: bodyFont, .foregroundColor: ink])
                            .draw(in: CGRect(x: innerX, y: cy, width: innerWidth, height: h))
                        cy += h
                    }

                    // Coverage (full width, one line per selection)
                    for (idx, line) in coverageLines.enumerated() {
                        cy += 4
                        if idx == 0 {
                            NSAttributedString(string: "Coverage", attributes: [.font: labelFont, .foregroundColor: grey])
                                .draw(at: CGPoint(x: innerX, y: cy))
                            cy += 12
                        }
                        let h = fullWidthHeight(line, font: bodyFont)
                        NSAttributedString(string: line, attributes: [.font: bodyFont, .foregroundColor: ink])
                            .draw(in: CGRect(x: innerX, y: cy, width: innerWidth, height: h))
                        cy += h
                    }

                    // Reference photos
                    if !referenceRows.isEmpty {
                        cy += 8
                        func drawFramed(_ data: Data, caption: String, at origin: CGPoint, size: CGSize) {
                            guard let nsImage = NSImage(data: data) else { return }
                            NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: grey])
                                .draw(at: CGPoint(x: origin.x, y: origin.y))
                            let boxY = origin.y + 12
                            let imgSize = nsImage.size
                            guard imgSize.width > 0, imgSize.height > 0 else { return }
                            let aspect = imgSize.width / imgSize.height
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
                        for (offset, reference) in referenceRows.enumerated() {
                            let both = reference.imageData != nil && reference.mapData != nil
                            let pairWidth = both ? (photoAreaWidth - photoSpacing) / 2 : min(photoAreaWidth * 0.6, 320)
                            let pairHeight = pairWidth * 0.75
                            let suffix = referenceRows.count > 1 ? " \(offset + 1)" : ""
                            var px = innerX
                            if let data = reference.imageData {
                                drawFramed(data, caption: "Reference\(suffix)", at: CGPoint(x: px, y: cy), size: CGSize(width: pairWidth, height: pairHeight))
                                px += pairWidth + photoSpacing
                            }
                            if let data = reference.mapData {
                                drawFramed(data, caption: "Top Down Map\(suffix)", at: CGPoint(x: px, y: cy), size: CGSize(width: pairWidth, height: pairHeight))
                            }
                            cy += pairHeight + 24
                        }
                    }

                    yPosition = cardTop + cardHeight + 12
                    shotIndex += 1
                }
            }
            
            context.restoreGState()
            context.endPDFPage()
            
            // If we've drawn all shots (or scene is empty), exit loop
            if shotIndex >= orderedShots.count {
                break
            }
        }
        
        return currentPage
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
