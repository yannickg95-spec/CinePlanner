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

    @State private var selected: Set<ExportFormat> = []
    @State private var showingPublish = false

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
        exportScenes.contains { $0.shots.contains { $0.references.contains { $0.videoExtension != nil || $0.mapVideoExtension != nil } } }
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
        var badge: String? = nil
    }

    /// Shot list formats, listed most capable first — which is also the order we
    /// recommend.
    private var shotListOptions: [Option] {
        [
            Option(format: .htmlWithMedia, icon: "photo.on.rectangle.angled", title: "Webpage",
                   detail: hasVideoInShots
                       ? "Searchable, filterable page with photos, playable video and coverage. Saved as a zipped folder. Opens anywhere."
                       : "Searchable, filterable page with photos and coverage — one self-contained file. Opens anywhere.",
                   requiresScript: false,
                   badge: "Recommended"),
            Option(format: .pdf, icon: "doc.richtext", title: "PDF",
                   detail: "Clean, printable shot list with photos and coverage. No video.",
                   requiresScript: false),
            Option(format: .text, icon: "doc.plaintext", title: "Text File",
                   detail: "Plain text for an email or message. Media is noted, not included.",
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
                        sectionHeader("SHARE ONLINE")
                        publishFeatureCard
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SHOTLIST AS FILE")
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
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(exportButtonTitle) { performExport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(orderedSelection.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 600, height: 720)
        .sheet(isPresented: $showingPublish) {
            GitHubPublishSheet(project: project, version: version)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }

    /// The hero action: publishing online is the richest way to share a shot
    /// list, so it leads the sheet. It's an action (not a selectable format), so
    /// the accent lives in the Publish button — the tinted-blue "selected" look
    /// is reserved for the file checkboxes below.
    private var publishFeatureCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("GitHubLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Publish to Web")
                        .fontWeight(.semibold)
                    Text("Best way to share")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text("Put your shot list online and get a link to share — searchable and filterable, with reference photos and video, opening on any device. Re-publishing updates the same link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(project.publishedRepoFullName != nil ? "Update" : "Publish") {
                showingPublish = true
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
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
                        if let badge = option.badge {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
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

        #if os(macOS)
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
        #else
        // iPad: generate each format to a temp file and hand them to a share sheet
        // (Save to Files, AirDrop, Mail, etc.).
        Task { @MainActor in
            var urls: [URL] = []
            for format in formats {
                if let url = try? await exporter.exportFileURL(format: format) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            PlatformShare.present(urls)
        }
        #endif
    }
}
