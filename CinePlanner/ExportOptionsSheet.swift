//
//  ExportOptionsSheet.swift
//  CinePlanner
//
//  The export window: pick a format, see what it's for, then export.

import SwiftUI

struct ExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let version: ScriptVersion?

    @State private var selected: Set<ExportFormat> = [.pdf]

    /// Selected formats in the order they're listed.
    private var orderedSelection: [ExportFormat] {
        (shotListOptions + scriptOptions)
            .map(\.format)
            .filter { selected.contains($0) }
    }

    private var hasScriptPDF: Bool {
        (version?.pdfData ?? project.scriptPDFData) != nil
    }

    private var exportScenes: [Scene] {
        version?.scenes ?? project.scenes
    }

    /// The web export only produces a zip when a video forces a media folder.
    private var hasVideoInShots: Bool {
        // The extension, not the Data — this runs while the view body evaluates,
        // and reading the blobs would load every video just to draw a label.
        exportScenes.contains { $0.shots.contains { $0.referenceVideoExtension != nil } }
    }

    /// Extension shown on the option's badge — accurate per project, not per format.
    private func fileExtension(for format: ExportFormat) -> String {
        if format == .htmlWithMedia { return hasVideoInShots ? "zip" : "html" }
        return format.fileExtension
    }

    /// "Film · Episode 2 · Version 3 · 14 scenes · 42 shots"
    private var contextLine: String {
        var parts: [String] = [project.filmName]
        if project.isSeries, let episode = version?.episode?.title { parts.append(episode) }
        if let versionName = version?.name { parts.append(versionName) }
        let sceneCount = exportScenes.count
        let shotCount = exportScenes.reduce(0) { $0 + $1.shots.count }
        parts.append("\(sceneCount) scene\(sceneCount == 1 ? "" : "s")")
        parts.append("\(shotCount) shot\(shotCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private struct Option: Identifiable {
        var id: String { title }
        let format: ExportFormat
        let icon: String
        let title: String
        let detail: String
        let requiresScript: Bool
    }

    /// Shot list formats.
    private var shotListOptions: [Option] {
        [
            Option(format: .pdf, icon: "doc.richtext", title: "PDF",
                   detail: "Clean, printable shot list with photos. Not compatible with video.",
                   requiresScript: false),
            Option(format: .text, icon: "doc.plaintext", title: "Text File",
                   detail: "Plain text you can paste into an email or message. No photos or video — media is only noted as present.",
                   requiresScript: false),
            Option(format: .htmlWithMedia, icon: "photo.on.rectangle.angled", title: "Webpage File",
                   detail: hasVideoInShots
                       ? "A zipped folder with a webpage plus every video. Photos are built into the page."
                       : "A single webpage with every photo built in. No folder to unpack.",
                   requiresScript: false),
            Option(format: .epub, icon: "book", title: "EPUB",
                   detail: "Best for mobile — photos and playable video in one file. Opens in Apple Books and other e-readers.",
                   requiresScript: false)
        ]
    }

    /// Not a shot list — the screenplay itself.
    private var scriptOptions: [Option] {
        [
            Option(format: .scriptWithCoverage, icon: "doc.text.image", title: "Script with Coverage",
                   detail: "The screenplay PDF with each shot's coverage drawn in the margin.",
                   requiresScript: true)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Shot List")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(contextLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            // Format options, grouped
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SHOT LIST")
                        ForEach(shotListOptions) { option in
                            optionRow(option)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SCRIPT")
                        ForEach(scriptOptions) { option in
                            optionRow(option)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                if orderedSelection.count > 1 {
                    Text("You'll choose one folder for all \(orderedSelection.count) files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(exportButtonTitle) { performExport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(orderedSelection.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 580, height: 560)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }

    @ViewBuilder
    private func optionRow(_ option: Option) -> some View {
        let isEnabled = !option.requiresScript || hasScriptPDF
        let isSelected = selected.contains(option.format)

        Button {
            if isSelected { selected.remove(option.format) } else { selected.insert(option.format) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: option.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .fontWeight(.semibold)
                        Text(".\(fileExtension(for: option.format))")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if option.requiresScript && !hasScriptPDF {
                        Text("Import a script PDF to enable this.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var exportButtonTitle: String {
        let count = orderedSelection.count
        return count > 1 ? "Export \(count) Files…" : "Export…"
    }

    private func performExport() {
        let exporter = ProjectExporter(project: project, version: version)
        let formats = orderedSelection
        guard !formats.isEmpty else { return }
        dismiss()

        // Let the sheet finish dismissing before a panel appears.
        DispatchQueue.main.async {
            // A single format keeps the familiar "name your file" save panel.
            if formats.count == 1 {
                exporter.exportShotList(format: formats[0])
                return
            }

            // Several formats: pick one destination folder for all of them.
            let panel = NSOpenPanel()
            panel.title = "Choose a Folder for the Export"
            panel.message = "All \(formats.count) files will be saved here."
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export Here"

            guard panel.runModal() == .OK, let folder = panel.url else { return }

            Task { @MainActor in
                do {
                    let urls = try await exporter.exportAll(formats: formats, to: folder)
                    exporter.showBatchSuccess(urls: urls, folder: folder)
                } catch {
                    exporter.showExportError(error)
                }
            }
        }
    }
}
