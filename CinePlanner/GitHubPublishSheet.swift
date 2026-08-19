//
//  GitHubPublishSheet.swift
//  CinePlanner
//
//  Publish the web shot list to GitHub Pages on the user's own account and get a
//  public link. GitHub *builds* the page after each upload, so this sheet is
//  explicit that publishing takes about a minute.
//

import SwiftUI

struct GitHubPublishSheet: View {
    let project: Project
    let version: ScriptVersion?
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput = ""
    @State private var hasToken = GitHubPublisher.hasToken
    @State private var isPublishing = false
    @State private var phase: GitHubPublishPhase?
    @State private var result: GitHubPublisher.Result?
    @State private var errorMessage: String?
    private var existingRepo: String? { project.publishedRepoFullName }

    /// A classic token pre-filled with the scopes we need: public_repo to publish,
    /// delete_repo so "Delete Published Page" can fully remove the repository.
    private let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=public_repo,delete_repo&description=CinePlanner")!

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Publish to Web")
                    .font(.title2).fontWeight(.semibold)
                Text("Puts the web shot list on GitHub Pages under your own account and gives you a public link — free, no server of ours involved.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            Group {
                if !hasToken {
                    tokenEntry
                } else {
                    publishBody
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                if hasToken {
                    Button("Change Token") { clearToken() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 500, height: 460)
        #if os(iOS)
        // iPhone: open as a compact half-height sheet (draggable up) rather than
        // filling the whole screen for a handful of controls.
        .applyIf(DeviceLayout.isPhone) { $0.presentationDetents([.medium, .large]) }
        #endif
    }

    // MARK: - Token entry

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your GitHub account")
                .font(.headline)
            Text("GitHub Pages hosts the page for free on your own account. Create a personal access token once, then paste it here — it's stored securely in your Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("Create a token on GitHub ↗", destination: tokenURL)
                .font(.subheadline)
            Text("The link pre-selects the only permission needed (**public_repo**). Scroll down and click “Generate token,” then copy it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Paste your GitHub token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)

            Button("Save Token") { saveToken() }
                .buttonStyle(.borderedProminent)
                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Publish body

    private var publishBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                // Just published this session.
                Label(result.isLive ? "Published" : "Building on GitHub…",
                      systemImage: result.isLive ? "checkmark.circle.fill" : "clock.badge.checkmark")
                    .foregroundStyle(result.isLive ? .green : .orange)
                    .font(.headline)
                linkAndActions(url: result.url, repoURL: result.repoURL)
                if !result.isLive {
                    Text("The link goes live within a minute; if it 404s at first, refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                newRepoButton
            } else if let existingURL {
                // Already has a published page — show it, ready to open or update.
                Text("YOUR PUBLISHED PAGE")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).kerning(0.5)
                linkAndActions(url: existingURL, repoURL: existingRepoURL)
                newRepoButton
            } else {
                // First publish — a hero, then the action.
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 76, height: 76)
                        Image("GitHubLogo")
                            .resizable().scaledToFit()
                            .frame(width: 36, height: 36)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("Ready to publish")
                        .font(.headline)
                    Text("One click puts your shot list on your GitHub and gives you a link to share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button { publish() } label: {
                        Label("Publish", systemImage: "globe").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(isPublishing)
                    .padding(.top, 4)

                    Label("Building the page takes about a minute.", systemImage: "clock")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            }

            if isPublishing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: phase?.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.3), value: phase?.fraction ?? 0)
                    Text(phase?.label ?? "Publishing…")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// The published link in a box, with Open/Copy/Repository and a prominent
    /// Update button — shared by the "just published" and "already published" states.
    @ViewBuilder
    private func linkAndActions(url: String, repoURL: String?) -> some View {
        Text(url)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        HStack(spacing: 10) {
            Button {
                if let u = URL(string: url) { PlatformURLOpener.open(u) }
            } label: { Label("Open", systemImage: "safari") }

            Button {
                PlatformPasteboard.copy(url)
            } label: { Label("Copy", systemImage: "doc.on.doc") }

            if let repoURL, let u = URL(string: repoURL) {
                Link(destination: u) { Label("Repository", systemImage: "chevron.left.forwardslash.chevron.right") }
            }

            Spacer()

            Button { publish() } label: {
                Label("Update", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPublishing)
        }
    }

    /// Subtle "start over on a fresh repo" action.
    private var newRepoButton: some View {
        Button("Publish to a new repository instead") {
            project.publishedRepoFullName = nil
            result = nil
            publish()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(isPublishing)
    }

    // The existing page's public URL, derived from the saved "owner/repo".
    private var existingURL: String? {
        guard let repo = existingRepo, let slash = repo.firstIndex(of: "/") else { return nil }
        let owner = String(repo[..<slash]).lowercased()
        let name = String(repo[repo.index(after: slash)...])
        return "https://\(owner).github.io/\(name)/"
    }
    private var existingRepoURL: String? { existingRepo.map { "https://github.com/\($0)" } }

    // MARK: - Actions

    private func saveToken() {
        GitHubPublisher.token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        hasToken = GitHubPublisher.hasToken
        tokenInput = ""
    }

    private func clearToken() {
        GitHubPublisher.token = nil
        hasToken = false
        result = nil
        errorMessage = nil
    }

    private func publish() {
        isPublishing = true
        errorMessage = nil
        phase = .preparing
        Task { @MainActor in
            // Let the bar paint "Preparing…" before buildSiteDirectory blocks the
            // main actor (it reads SwiftData models and rasterises media).
            await Task.yield()
            do {
                let exporter = ProjectExporter(project: project, version: version)
                let siteDir = try await exporter.buildSiteDirectory(onCompress: { done, total in
                    phase = .compressing(done: done, total: total)
                })
                defer { try? FileManager.default.removeItem(at: siteDir) }
                let published = try await GitHubPublisher.publish(
                    siteDirectory: siteDir,
                    existingRepo: existingRepo,
                    projectName: project.filmName,
                    onProgress: { newPhase in
                        // Called off the main thread; hop back to update UI state.
                        Task { @MainActor in phase = newPhase }
                    })
                // Persist the repo link on the project so it syncs across devices.
                project.publishedRepoFullName = published.repoFullName
                result = published
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = nil
            isPublishing = false
        }
    }
}
