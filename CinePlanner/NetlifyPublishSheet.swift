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
    @State private var showingAccount = false

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
                    Button("Check Account…") { showingAccount = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .help("See which Netlify account this token belongs to and list its sites")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500, height: 430)
        .sheet(isPresented: $showingAccount) {
            NetlifyAccountStatusView()
        }
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

                if existingSiteID != nil {
                    Button("Publish to a new site instead") {
                        NetlifyPublisher.forgetSite(forProjectUID: project.uid)
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

// MARK: - Account status (diagnostic)

/// Shows which Netlify account the stored token belongs to and lists its sites,
/// probing each so throttled (429) pages are obvious. This is the answer to
/// "my pages are blank / I can't find them" — usually the token is on a
/// different account than the dashboard the user is signed into.
struct NetlifyAccountStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var info: NetlifyPublisher.AccountInfo?
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var deletingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Netlify Account")
                .font(.title2).fontWeight(.semibold)

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your token…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This token belongs to:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(info.email ?? info.fullName ?? "Unknown account")
                        .font(.body.monospaced()).textSelection(.enabled)
                    Text("Your pages are created under this account. If it isn't the one you're viewing in the Netlify dashboard, that's why you can't find them — switch to this account (or team) in the browser.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Divider()

                if info.sites.isEmpty {
                    Text("No sites found under this account.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("\(info.sites.count) site\(info.sites.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(info.sites) { site in
                                siteRow(site)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 500)
        .task { await load() }
    }

    @ViewBuilder
    private func siteRow(_ site: NetlifyPublisher.SiteInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name).fontWeight(.medium)
                Text(site.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                serveBadge(site.serveStatus)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if let admin = site.adminURL, let url = URL(string: admin) {
                    Link("Open", destination: url).font(.caption)
                }
                if deletingID == site.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(role: .destructive) {
                        delete(site)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this site on Netlify")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func serveBadge(_ status: Int?) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case 200: return ("Live", .green)
            case 429: return ("Throttled by Netlify (429)", .red)
            case .some(let code): return ("HTTP \(code)", .orange)
            case nil: return ("Unreachable", .secondary)
            }
        }()
        Text(text)
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            info = try await NetlifyPublisher.fetchAccountStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func delete(_ site: NetlifyPublisher.SiteInfo) {
        deletingID = site.id
        Task { @MainActor in
            do {
                try await NetlifyPublisher.deleteSite(id: site.id)
                info?.sites.removeAll { $0.id == site.id }
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingID = nil
        }
    }
}
