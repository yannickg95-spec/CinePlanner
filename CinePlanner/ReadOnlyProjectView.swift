//
//  ReadOnlyProjectView.swift
//  CinePlanner
//
//  After the trial a project opens read-only: rather than an editor with every
//  control switched off, it's shown as the web shot list (the same page a publish
//  produces — scenes, shots, references, maps, schedule, coverage), with a bar to
//  unlock and an Export menu, so nobody's work is ever locked away. Nothing here can
//  edit the project, and ReadOnlyGate keeps the store unchanged regardless. A project
//  shared with us to view only opens here too, saying so instead of offering Pro.
//
//  `ProjectDestination` picks this or the editor, and switches on its own the
//  moment the access changes — e.g. right after a purchase, or when the owner
//  changes what we may do.
//

import SwiftUI
import WebKit
import SwiftData

/// What opening a project shows: the editor, or — after the trial — the viewer.
/// Either works in the project's own store: a shared project's isn't the regular
/// one (see SharedProjectStore).
struct ProjectDestination: View {
    let project: Project
    @EnvironmentObject private var access: AppAccess
    @Environment(\.modelContext) private var environmentContext

    var body: some View {
        Group {
            if access.isReadOnly || !ProjectSync.shared.canEdit(project) {
                ReadOnlyProjectView(project: project)
            } else {
                ProjectEditorView(project: project)
            }
        }
        .modelContext(project.modelContext ?? environmentContext)
    }
}

struct ReadOnlyProjectView: View {
    let project: Project

    @State private var siteDirectory: URL?
    @State private var failure: String?
    @State private var showPaywall = false
    @State private var exportedFile: URL?
    @State private var showMover = false
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            readOnlyBar
            Divider()
            Group {
                if let siteDirectory {
                    WebPageView(page: siteDirectory.appendingPathComponent("index.html"), readAccess: siteDirectory)
                } else if let failure {
                    ContentUnavailableView("Couldn't Show This Project",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Preparing…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(project.filmName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { exportMenu }
        }
        .task { await buildSite() }
        .onDisappear {
            if let siteDirectory { try? FileManager.default.removeItem(at: siteDirectory) }
        }
        .sheet(isPresented: $showPaywall) { PaywallView(dismissable: true) }
        .fileMover(isPresented: $showMover, file: exportedFile) { _ in exportedFile = nil }
        .alert("Couldn't Export", isPresented: Binding(get: { exportError != nil },
                                                      set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Bar

    /// Shared with us to view only — rather than read-only because the trial ended.
    private var isViewOnlyShare: Bool { !ProjectSync.shared.canEdit(project) }

    private var readOnlyBar: some View {
        HStack(spacing: 12) {
            Image(systemName: isViewOnlyShare ? "eye" : "lock.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(isViewOnlyShare ? "View Only" : "Read-only").font(.subheadline.weight(.semibold))
                Text(readOnlyReason)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !isViewOnlyShare {
                Button("Unlock to Edit") { showPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var readOnlyReason: String {
        guard isViewOnlyShare else { return "Your free trial has ended. You can view and export this project." }
        let owner = ProjectSync.shared.shareInfo(for: project)?.ownerName
        return "\(owner ?? "The owner") shared this project with you to view. You can export it; changes are up to the people who can edit."
    }

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            if project.isSeries {
                ForEach(project.orderedEpisodes, id: \.uid) { episode in
                    Menu(episodeTitle(episode)) {
                        formatButtons(version: episode.orderedVersions.last)
                    }
                }
            } else {
                formatButtons(version: project.orderedEpisodes.first?.orderedVersions.last)
            }
            Divider()
            Button("Project File (.cineplan)…") { exportArchive() }
        } label: {
            if exporting {
                ProgressView().controlSize(.small)
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(exporting)
    }

    @ViewBuilder
    private func formatButtons(version: ScriptVersion?) -> some View {
        Button("PDF Shot List…") { export(.pdf, version: version) }
        if version?.pdfData != nil || project.scriptPDFData != nil {
            Button("Script with Coverage…") { export(.scriptWithCoverage, version: version) }
        }
        Button("Web Page with Media…") { export(.htmlWithMedia, version: version) }
    }

    private func episodeTitle(_ episode: Episode) -> String {
        let title = episode.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Episode \(episode.episodeNumber)" : "Episode \(episode.episodeNumber) — \(title)"
    }

    /// Generates the file in a temporary location, then lets the user choose where it
    /// goes (Save panel on Mac, document picker on iPhone and iPad).
    private func export(_ format: ExportFormat, version: ScriptVersion?) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportedFile = try await ProjectExporter(project: project, version: version).exportFileURL(format: format)
                showMover = true
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportArchive() {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(ProjectArchive.suggestedFileName(for: project))
            try? FileManager.default.removeItem(at: url)
            try ProjectArchive.data(for: project).write(to: url)
            exportedFile = url
            showMover = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Page

    /// Builds the web shot list into a temporary folder — every episode for a series
    /// (with the page's own episode switch), else the latest script version.
    private func buildSite() async {
        guard siteDirectory == nil else { return }
        let episodes = project.orderedEpisodes
        let exporter = ProjectExporter(project: project, version: episodes.first?.orderedVersions.last)
        do {
            if project.isSeries, episodes.count > 1 {
                siteDirectory = try await exporter.buildSiteDirectory(episodes: episodes)
            } else {
                siteDirectory = try await exporter.buildSiteDirectory()
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Web view

/// Shows a local HTML page (with its media folder) in a WKWebView.
private struct WebPageView {
    let page: URL
    let readAccess: URL

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadFileURL(page, allowingReadAccessTo: readAccess)
        return view
    }
}

#if os(macOS)
extension WebPageView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension WebPageView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
