//
//  NetlifyPublishSheet.swift
//  CinePlanner
//
//  Publish the web shot list to the user's own Netlify account and get a public
//  link — no server of ours involved.
//

import SwiftUI
import AppKit

struct NetlifyPublishSheet: View {
    let project: Project
    let version: ScriptVersion?
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput = ""
    @State private var hasToken = NetlifyPublisher.hasToken
    @State private var isPublishing = false
    @State private var result: NetlifyPublisher.Result?
    @State private var errorMessage: String?

    private var existingSiteID: String? { NetlifyPublisher.savedSiteID(forProjectUID: project.uid) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Publish to Web")
                    .font(.title2).fontWeight(.semibold)
                Text("Puts the web shot list on your own Netlify account and gives you a public link — no server of ours involved.")
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
                    Button("Change Token", role: .none) { clearToken() }
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
        .frame(width: 500, height: 430)
    }

    // MARK: - Token entry

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your Netlify account")
                .font(.headline)
            Text("Netlify hosts the page for free on your own account. Create a personal access token once, then paste it here — it's stored securely in your Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("Create a token on Netlify ↗",
                 destination: URL(string: "https://app.netlify.com/user/applications#personal-access-tokens")!)
                .font(.subheadline)

            SecureField("Paste your Netlify token", text: $tokenInput)
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
                Label("Published", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)

                Text(result.url)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.url, forType: .string)
                    } label: { Label("Copy Link", systemImage: "doc.on.doc") }

                    Button {
                        if let url = URL(string: result.url) { NSWorkspace.shared.open(url) }
                    } label: { Label("Open", systemImage: "safari") }

                    if let admin = result.adminURL, let adminURL = URL(string: admin) {
                        Link(destination: adminURL) { Label("Manage on Netlify", systemImage: "gearshape") }
                    }

                    Spacer()

                    Button { publish() } label: {
                        Label("Update Page", systemImage: "arrow.clockwise")
                    }
                    .disabled(isPublishing)
                }

                DisclosureGroup("Details") {
                    Text(result.diagnostics)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            } else {
                Text(existingSiteID == nil
                     ? "This creates a page on your Netlify account and gives you a link to share. Re-publishing later updates the same page."
                     : "This project already has a published page. Publishing updates it at the same link.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button { publish() } label: {
                    Label(existingSiteID == nil ? "Publish" : "Update Page", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isPublishing)
            }

            if isPublishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Publishing… videos can take a moment to upload.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        NetlifyPublisher.token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        hasToken = NetlifyPublisher.hasToken
        tokenInput = ""
    }

    private func clearToken() {
        NetlifyPublisher.token = nil
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
                result = try await NetlifyPublisher.publish(
                    siteDirectory: siteDir,
                    existingSiteID: existingSiteID,
                    projectUID: project.uid)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPublishing = false
        }
    }
}
