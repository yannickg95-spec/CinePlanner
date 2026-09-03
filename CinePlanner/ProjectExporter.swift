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
import os

/// Handles exporting project shot lists to PDF and TXT formats
struct ProjectExporter {
    let project: Project
    var version: ScriptVersion? = nil
    /// What the PDF export includes; set by the export sheet before a PDF export.
    var pdfOptions = PDFExportOptions()

    /// Scenes to export: the selected script version's scenes, or all project
    /// scenes for legacy projects without versions.
    var exportScenes: [Scene] {
        version?.scenes ?? project.scenes
    }

    /// The scenes a PDF export covers — `exportScenes` in order, filtered by the
    /// PDF options' scene selection.
    var pdfExportScenes: [Scene] {
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
            let baseName = webExportBaseName(filmName)
            return try writeWebExport(filmName: filmName, episodeName: episodeName,
                                      versionName: versionName) { temp("\(baseName).\($0)") }
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
        Log.export.debug("🔵 [EXPORT] Starting export process...")
        Log.export.debug("🔵 [EXPORT] Current thread: \(Thread.current)")
        Log.export.debug("🔵 [EXPORT] Is main thread: \(Thread.isMainThread)")
        
        // CRITICAL: Extract ALL data from SwiftData models BEFORE opening save panel
        // This prevents SwiftData threading violations
        Log.export.debug("🔵 [EXPORT] About to generate content from SwiftData...")
        let content: String
        do {
            content = generateFullTextContent()
            Log.export.debug("✅ [EXPORT] Content generated successfully (\(content.count) characters)")
        } catch {
            Log.export.error("❌ [EXPORT] Error generating content: \(error)")
            showErrorAlert(error: error)
            return
        }
        
        // Show save panel on main thread
        Log.export.debug("🔵 [EXPORT] Preparing save panel...")
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
            
            Log.export.debug("🔵 [EXPORT] Showing save panel...")
            let response = savePanel.runModal()
            
            if response == .OK, let url = savePanel.url {
                Log.export.debug("✅ [EXPORT] User selected save location: \(url.path)")
                
                do {
                    // Create file based on format
                    switch format {
                    case .text:
                        // Write text file directly to selected location
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        Log.export.debug("✅ [EXPORT] Text file saved successfully")
                        
                    case .pdf:
                        // Convert text to PDF and save
                        guard let pdfData = self.createPDFData(from: content) else {
                            throw NSError(domain: "ProjectExporter", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF data"])
                        }
                        try pdfData.write(to: url)
                        Log.export.debug("✅ [EXPORT] PDF file saved successfully")
                        
                    case .scriptWithCoverage:
                        // Export script with coverage lines burned in
                        guard let pdfData = self.createScriptWithCoverage() else {
                            throw NSError(domain: "ProjectExporter", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "Failed to create script with coverage. Make sure a script PDF is imported."])
                        }
                        try pdfData.write(to: url)
                        Log.export.debug("✅ [EXPORT] Script with coverage saved successfully")

                    case .htmlWithMedia:
                        break // handled earlier via their own methods
                    }

                    // Show success notification
                    self.showSuccessNotification(fileURL: url, format: format)
                    
                } catch {
                    Log.export.error("❌ [EXPORT] Error saving file: \(error)")
                    self.showErrorAlert(error: error)
                }
            } else {
                Log.export.debug("ℹ️ [EXPORT] User cancelled save operation")
            }
        }
    }
    #endif

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
                let webURL = try writeWebExport(filmName: project.filmName,
                                                episodeName: episodeName,
                                                versionName: version?.name) {
                    folder.appendingPathComponent("\(project.filmName) - Shot List.\($0)")
                }
                written.append(webURL)
                continue

            }
            written.append(url)
        }
        return written
    }

    static func exportError(_ message: String) -> NSError {
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
