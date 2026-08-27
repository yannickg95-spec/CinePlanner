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

    init(project: Project, version: ScriptVersion?) {
        self.project = project
        self.version = version
        // Default to publishing every episode of a series.
        let eps = project.isSeries ? project.orderedEpisodes.map(\.uid) : []
        _selectedEpisodeUIDs = State(initialValue: Set(eps))
    }

    /// Which episodes to publish (series only). All selected by default.
    @State private var selectedEpisodeUIDs: Set<String>
    @State private var tokenInput = ""
    @State private var hasToken = GitHubPublisher.hasToken
    @State private var isPublishing = false
    @State private var phase: GitHubPublishPhase?
    @State private var result: GitHubPublisher.Result?
    @State private var errorMessage: String?
    // Device-flow connect state.
    @State private var deviceCode: GitHubDeviceAuth.DeviceCode?
    @State private var connecting = false
    @State private var authError: String?
    @State private var connectTask: Task<Void, Never>?
    @State private var connectedUsername: String?
    private var existingRepo: String? { project.publishedRepoFullName }

    /// Episodes offered for selection — only when this is a series with more than one.
    private var seriesEpisodes: [Episode] { project.isSeries ? project.orderedEpisodes : [] }
    private var showsEpisodePicker: Bool { seriesEpisodes.count > 1 }
    private var episodesToPublish: [Episode] { seriesEpisodes.filter { selectedEpisodeUIDs.contains($0.uid) } }
    /// True when the picker is shown but nothing is ticked (publishing is blocked).
    private var noEpisodesChosen: Bool { showsEpisodePicker && episodesToPublish.isEmpty }

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
                    connectContent
                } else {
                    publishBody
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                if hasToken {
                    Button("Disconnect") { clearToken() }
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
        .adaptiveSheetFrame(width: 500, height: showsEpisodePicker ? 580 : 460)
        .task {
            if hasToken, connectedUsername == nil { connectedUsername = await GitHubPublisher.currentUsername() }
        }
        .onDisappear { connectTask?.cancel() }
        #if os(iOS)
        // iPhone: open as a compact half-height sheet (draggable up) rather than
        // filling the whole screen for a handful of controls.
        .applyIf(DeviceLayout.isPhone) { $0.presentationDetents([.medium, .large]) }
        #endif
    }

    // MARK: - Connect (device flow)

    @ViewBuilder
    private var connectContent: some View {
        if GitHubDeviceAuth.isConfigured {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect your GitHub account").font(.headline)
                Text("Publishing puts your shot list on your own GitHub for free. Connect once — no token to create or copy.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let code = deviceCode {
                    deviceCodeSteps(code)
                } else {
                    Button { startConnect() } label: {
                        Label("Connect GitHub", systemImage: "link").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(connecting)
                    if connecting {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting…").font(.caption).foregroundStyle(.secondary) }
                    }
                }

                if let authError {
                    Text(authError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Paste a token instead") { manualTokenEntry.padding(.top, 6) }
                    .font(.caption)

                Spacer(minLength: 0)
            }
        } else {
            // No OAuth App configured in this build — manual token entry only.
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect your GitHub account").font(.headline)
                manualTokenEntry
                Spacer(minLength: 0)
            }
        }
    }

    /// The code + "open GitHub" step shown while waiting for authorization.
    private func deviceCodeSteps(_ code: GitHubDeviceAuth.DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1.  Copy this code").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(code.userCode)
                    .font(.title2.monospaced().weight(.bold))
                    .textSelection(.enabled)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button { PlatformPasteboard.copy(code.userCode) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
            }
            Text("2.  Open GitHub and paste it").font(.caption).foregroundStyle(.secondary)
            Button {
                PlatformPasteboard.copy(code.userCode)
                if let u = URL(string: code.verificationURI) { PlatformURLOpener.open(u) }
            } label: {
                Label("Open GitHub & enter code", systemImage: "safari").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to authorize on GitHub…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// Fallback: paste a personal access token (kept behind a disclosure).
    private var manualTokenEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link("Create a token on GitHub ↗", destination: tokenURL)
                .font(.subheadline)
            Text("The link pre-selects the permissions needed. Scroll down, click “Generate token,” then paste it here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste your GitHub token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
            Button("Save Token") { saveToken() }
                .buttonStyle(.bordered)
                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Publish body

    private var publishBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let connectedUsername {
                Label("Connected as @\(connectedUsername)", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            if showsEpisodePicker && !isPublishing {
                episodePicker
                Divider()
            }
            if isPublishing {
                // A single compact progress state — showing it instead of the hero
                // (or the link box) keeps the sheet from overflowing while uploading.
                publishingState
            } else if let result {
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
                // First publish — a hero, then the action. For a series the episode
                // picker already fills the top, so the hero stays compact.
                VStack(spacing: 14) {
                    if !showsEpisodePicker {
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
                    }

                    Button { publish() } label: {
                        Label(publishButtonTitle, systemImage: "globe").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(isPublishing || noEpisodesChosen)
                    .padding(.top, 4)

                    Label("Building the page takes about a minute.", systemImage: "clock")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, showsEpisodePicker ? 0 : 10)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// The compact state shown while an upload/build is in progress.
    private var publishingState: some View {
        VStack(spacing: 16) {
            ProgressView(value: phase?.fraction ?? 0)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.3), value: phase?.fraction ?? 0)
            Text(phase?.label ?? "Publishing…")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Label("Building the page on GitHub takes about a minute.", systemImage: "clock")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    /// Series only: choose which episodes go into the published site. When more than
    /// one is chosen the page gets an episode switcher at the top.
    private var episodePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EPISODES TO PUBLISH")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).kerning(0.5)
                Spacer()
                Button(selectedEpisodeUIDs.count == seriesEpisodes.count ? "Deselect All" : "Select All") {
                    selectedEpisodeUIDs = selectedEpisodeUIDs.count == seriesEpisodes.count
                        ? [] : Set(seriesEpisodes.map(\.uid))
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(seriesEpisodes, id: \.uid) { ep in episodeRow(ep) }
                }
            }
            .frame(maxHeight: 150)
            if episodesToPublish.count > 1 {
                Text("Published with an episode switcher at the top of the page.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if noEpisodesChosen {
                Text("Pick at least one episode to publish.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func episodeRow(_ ep: Episode) -> some View {
        let on = selectedEpisodeUIDs.contains(ep.uid)
        return Button {
            if on { selectedEpisodeUIDs.remove(ep.uid) } else { selectedEpisodeUIDs.insert(ep.uid) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(ep.title).font(.subheadline).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private var publishButtonTitle: String {
        guard showsEpisodePicker else { return "Publish" }
        let n = episodesToPublish.count
        return n <= 1 ? "Publish" : "Publish \(n) Episodes"
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
            .disabled(isPublishing || noEpisodesChosen)
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

    /// Runs the device-flow handshake: get a code, then poll until authorized.
    private func startConnect() {
        authError = nil
        connecting = true
        connectTask = Task { @MainActor in
            do {
                let code = try await GitHubDeviceAuth.requestDeviceCode()
                deviceCode = code
                let token = try await GitHubDeviceAuth.pollForToken(code)
                GitHubPublisher.token = token
                connectedUsername = await GitHubPublisher.currentUsername()
                hasToken = true
                deviceCode = nil
            } catch is CancellationError {
                // Sheet dismissed mid-flow — nothing to report.
            } catch {
                authError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                deviceCode = nil
            }
            connecting = false
        }
    }

    private func saveToken() {
        GitHubPublisher.token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        hasToken = GitHubPublisher.hasToken
        tokenInput = ""
        Task { connectedUsername = await GitHubPublisher.currentUsername() }
    }

    private func clearToken() {
        connectTask?.cancel()
        GitHubPublisher.token = nil
        hasToken = false
        result = nil
        errorMessage = nil
        deviceCode = nil
        connecting = false
        connectedUsername = nil
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
                let onCompress: (Int, Int) -> Void = { done, total in phase = .compressing(done: done, total: total) }
                let siteDir: URL
                if showsEpisodePicker {
                    siteDir = try await exporter.buildSiteDirectory(episodes: episodesToPublish, onCompress: onCompress)
                } else {
                    siteDir = try await exporter.buildSiteDirectory(onCompress: onCompress)
                }
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
