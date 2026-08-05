//
//  ManageRepositoriesSheet.swift
//  CinePlanner
//
//  Lists the CinePlanner-published repositories in the user's GitHub account so
//  they can be reviewed and deleted from inside the app — handy for cleaning up
//  pages left behind by projects that were removed locally. Only repos CinePlanner
//  created (by their stamped description) are shown, so an unrelated repository
//  can never be offered for deletion.
//

import SwiftUI

struct ManageRepositoriesSheet: View {
    /// Repo full names ("owner/repo") still tied to a project in the app, so those
    /// rows can be flagged "In use" rather than "Orphaned".
    let inUseRepos: Set<String>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var loadState: LoadState = .loading
    @State private var repos: [GitHubPublisher.RepoInfo] = []
    @State private var deleting: Set<String> = []
    @State private var repoPendingDeletion: GitHubPublisher.RepoInfo?
    @State private var errorMessage: String?

    private enum LoadState: Equatable { case loading, loaded, noToken, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 580, height: 540)
        .task { await load() }
        .alert("Delete Repository?", isPresented: Binding(
            get: { repoPendingDeletion != nil },
            set: { if !$0 { repoPendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let repo = repoPendingDeletion { Task { await delete(repo) } }
            }
        } message: {
            if let repo = repoPendingDeletion {
                Text(deletionWarning(for: repo))
            }
        }
        .alert("Couldn't Delete Repository", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manage Repositories")
                    .font(.title3.bold())
                Text("Published pages in your GitHub account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if loadState == .loaded || isFailed {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh the list from GitHub")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            centered { ProgressView("Loading repositories…") }
        case .noToken:
            centered {
                ContentUnavailableView(
                    "No GitHub Account Connected",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Publish a project to the web first — that's where you add your GitHub token.")
                )
            }
        case .failed(let message):
            centered {
                ContentUnavailableView {
                    Label("Couldn't Load Repositories", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        case .loaded:
            if repos.isEmpty {
                centered {
                    ContentUnavailableView(
                        "No Published Repositories",
                        systemImage: "checkmark.circle",
                        description: Text("CinePlanner hasn't published any pages to this account.")
                    )
                }
            } else {
                List {
                    Section {
                        ForEach(repos) { repo in
                            repoRow(repo)
                        }
                    } footer: {
                        Text("Deleting a repository permanently removes its published page from GitHub.")
                            .font(.caption)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func repoRow(_ repo: GitHubPublisher.RepoInfo) -> some View {
        let inUse = inUseRepos.contains(repo.fullName)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(repo.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    statusBadge(inUse: inUse)
                }
                Button {
                    if let url = URL(string: repo.pagesURL) { openURL(url) }
                } label: {
                    Text(repo.pagesURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open the published page")
            }
            Spacer(minLength: 8)

            if deleting.contains(repo.fullName) {
                ProgressView().controlSize(.small)
            } else {
                Button(role: .destructive) {
                    repoPendingDeletion = repo
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this repository from GitHub")
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(inUse: Bool) -> some View {
        Text(inUse ? "In use" : "Orphaned")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(inUse ? Color.green : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((inUse ? Color.green : Color.orange).opacity(0.15))
            .clipShape(Capsule())
    }

    private func centered<V: View>(@ViewBuilder _ view: () -> V) -> some View {
        view()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    private var isFailed: Bool { if case .failed = loadState { return true } else { return false } }

    private func deletionWarning(for repo: GitHubPublisher.RepoInfo) -> String {
        let base = "This permanently deletes “\(repo.name)” and its published page from GitHub. This can't be undone."
        if inUseRepos.contains(repo.fullName) {
            return base + "\n\nThis repository is still used by a project in CinePlanner — its published page will go offline, and re-publishing that project will create a new one."
        }
        return base
    }

    // MARK: - Actions

    private func load() async {
        guard GitHubPublisher.hasToken else { loadState = .noToken; return }
        loadState = .loading
        do {
            let list = try await GitHubPublisher.listCinePlannerRepos()
            repos = list
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func delete(_ repo: GitHubPublisher.RepoInfo) async {
        deleting.insert(repo.fullName)
        defer { deleting.remove(repo.fullName) }
        do {
            try await GitHubPublisher.deleteRepo(fullName: repo.fullName)
            repos.removeAll { $0.fullName == repo.fullName }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
