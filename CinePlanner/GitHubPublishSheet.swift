//
//  GitHubPublishSheet.swift
//  CinePlanner
//
//  Publish the web shot list to GitHub Pages on the user's own account and get a
//  public link. GitHub *builds* the page after each upload, so this sheet is
//  explicit that publishing takes about a minute.
//

import SwiftUI
import AppKit

struct GitHubPublishSheet: View {
    let project: Project
    let version: ScriptVersion?
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput = ""
    @State private var hasToken = GitHubPublisher.hasToken
    @State private var isPublishing = false
    @State private var result: GitHubPublisher.Result?
    @State private var errorMessage: String?

    private var existingRepo: String? { GitHubPublisher.savedRepo(forProjectUID: project.uid) }

    /// A classic token pre-filled with the one scope we need. Public repos only.
    private let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=public_repo&description=CinePlanner")!

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
        .frame(width: 500, height: 460)
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
        VStack(alignment: .leading, spacing: 16) {
            if let result {
                if result.isLive {
                    Label("Published", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Label("Uploaded — GitHub is building the page", systemImage: "clock.badge.checkmark")
                        .foregroundStyle(.orange)
                        .font(.headline)
                }

                Text(result.url)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if !result.isLive {
                    Text("The link is set — it usually goes live within a minute of finishing the build. If it shows a 404 at first, wait a moment and refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.url, forType: .string)
                    } label: { Label("Copy Link", systemImage: "doc.on.doc") }

                    Button {
                        if let url = URL(string: result.url) { NSWorkspace.shared.open(url) }
                    } label: { Label("Open", systemImage: "safari") }

                    if let repoURL = URL(string: result.repoURL) {
                        Link(destination: repoURL) { Label("Repository", systemImage: "chevron.left.forwardslash.chevron.right") }
                    }

                    Spacer()

                    Button { publish() } label: {
                        Label("Update Page", systemImage: "arrow.clockwise")
                    }
                    .disabled(isPublishing)
                }
            } else {
                Text(existingRepo == nil
                     ? "This creates a repository on your GitHub account, turns on Pages, and gives you a link to share. Re-publishing later updates the same page."
                     : "This project already has a published page. Publishing updates it at the same link.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("Heads up: GitHub builds the page after uploading, so publishing takes about a minute.", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button { publish() } label: {
                    Label(existingRepo == nil ? "Publish" : "Update Page", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isPublishing)

                if existingRepo != nil {
                    Button("Publish to a new repository instead") {
                        GitHubPublisher.forgetRepo(forProjectUID: project.uid)
                        publish()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(isPublishing)
                }
            }

            if isPublishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Publishing… uploading files, then waiting for GitHub to build the page (about a minute).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

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
        Task { @MainActor in
            do {
                let exporter = ProjectExporter(project: project, version: version)
                let siteDir = try exporter.buildSiteDirectory()
                defer { try? FileManager.default.removeItem(at: siteDir) }
                result = try await GitHubPublisher.publish(
                    siteDirectory: siteDir,
                    existingRepo: existingRepo,
                    projectName: project.filmName,
                    projectUID: project.uid)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPublishing = false
        }
    }
}
