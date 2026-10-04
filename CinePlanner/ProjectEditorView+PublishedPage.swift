//
//  ProjectEditorView+PublishedPage.swift
//  CinePlanner
//
//  The published web page: its menu, updating it, checking it's live, deleting it.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    /// Small round GitHub button next to Export — opens/updates/deletes the online page.
    func publishedPageMenu(url: String, arrowEdge: Edge = .bottom) -> some View {
        ChipMenu(items: [
            ChipMenuItem(title: "Open Published Page", systemImage: "safari") {
                if let u = URL(string: url) { PlatformURLOpener.open(u) }
            },
            ChipMenuItem(title: "Update Page", systemImage: "arrow.clockwise") { updatePublishedPage() },
            .divider,
            ChipMenuItem(title: "Delete Published Page", systemImage: "trash", role: .destructive) {
                showingDeletePageConfirm = true
            },
        ], width: 230, arrowEdge: arrowEdge) {
            Group {
                if isDeletingPage || isUpdatingPage {
                    ProgressView().controlSize(.small)
                } else {
                    Image("GitHubLogo")
                        .resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.secondary.opacity(0.12)))
            // A green check in the corner when the page is confirmed live.
            .overlay(alignment: .topTrailing) {
                if pageIsLive && !isDeletingPage {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 13, weight: .bold))
                        .padding(1)
                        .background(Circle().fill(.white))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(Circle())
        }
        .disabled(isDeletingPage || isUpdatingPage)
        .help(pageIsLive ? "Published page is live — open, update, or delete it"
                         : "Published page — open, update, or delete it online")
        .task(id: url) { await checkPageLive(url) }
    }

    /// Native menu rows for the live published page — reused inside the iPhone
    /// portrait overflow menu (`headerOverflowMenu`), which can't host `ChipMenu`.
    @ViewBuilder
    func publishedPageMenuItems(url: String) -> some View {
        Button {
            if let u = URL(string: url) { PlatformURLOpener.open(u) }
        } label: {
            Label("Open Published Page", systemImage: "safari")
        }
        Button {
            updatePublishedPage()
        } label: {
            Label("Update Page", systemImage: "arrow.clockwise")
        }
        Divider()
        Button(role: .destructive) {
            showingDeletePageConfirm = true
        } label: {
            Label("Delete Published Page", systemImage: "trash")
        }
    }

    /// Re-publishes the web page in place using the saved repo + token — no sheet.
    /// Falls back to the publish sheet if the token or repo isn't available.
    func updatePublishedPage() {
        guard GitHubPublisher.hasToken,
              let repo = project.publishedRepoFullName else {
            showPublishSheet = true
            return
        }
        isUpdatingPage = true
        Task { @MainActor in
            await Task.yield()   // let the spinner paint before the main-actor build
            do {
                let exporter = ProjectExporter(project: project, version: selectedVersion)
                // A series page carries every episode (with the in-page switch); a
                // feature is a single page. Without this, a quick update would rebuild
                // a series as one episode and drop the switch.
                let siteDir: URL
                if project.isSeries && project.orderedEpisodes.count > 1 {
                    siteDir = try await exporter.buildSiteDirectory(episodes: project.orderedEpisodes)
                } else {
                    siteDir = try await exporter.buildSiteDirectory()
                }
                defer { try? FileManager.default.removeItem(at: siteDir) }
                let result = try await GitHubPublisher.publish(
                    siteDirectory: siteDir,
                    existingRepo: repo,
                    projectName: project.filmName,
                    onProgress: { _ in })
                project.publishedRepoFullName = result.repoFullName
            } catch {
                updatePageError = error.localizedDescription
            }
            isUpdatingPage = false
        }
    }

    /// Probes the published URL; the corner check shows when it responds live.
    @MainActor
    func checkPageLive(_ urlString: String) async {
        guard let url = URL(string: urlString) else { pageIsLive = false; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let response = try? await URLSession.shared.data(for: request)
        let code = (response?.1 as? HTTPURLResponse)?.statusCode ?? 0
        pageIsLive = (200..<400).contains(code)
    }

    func deletePublishedPage() {
        guard let repo = project.publishedRepoFullName else { return }
        isDeletingPage = true
        Task { @MainActor in
            do {
                try await GitHubPublisher.deletePublishedPage(repoFullName: repo)
                project.publishedRepoFullName = nil
            } catch {
                deletePageError = error.localizedDescription
            }
            isDeletingPage = false
        }
    }
}
