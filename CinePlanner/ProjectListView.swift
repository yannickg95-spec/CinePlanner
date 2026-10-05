//
//  ProjectListView.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

/// The `.cineplan` content type, shared by the import/export file pickers. Declared
/// in the Info.plist (with the app as its owner), so Finder, Files and AirDrop know
/// a `.cineplan` file belongs to CinePlanner and open it here.
extension UTType {
    nonisolated static let cineplanProject = UTType(exportedAs: "com.yannickgiraud.cineplanner.project",
                                        conformingTo: .data)
}

/// A `.cineplan` archive as a `FileDocument`, so export uses the cross-platform
/// `.fileExporter` (Save panel on macOS, document picker on iPad) instead of a
/// mac-only `NSSavePanel`.
struct ProjectArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.cineplanProject] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdDate, order: .reverse) private var regularProjects: [Project]
    /// Projects in the shared store (see SharedProjectStore), which `@Query` — bound
    /// to the regular store — doesn't see.
    @State private var sharedProjects: [Project] = []
    private var projects: [Project] { regularProjects + sharedProjects }
    @State private var showingNewProjectSheet = false
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var importErrorMessage: String?
    @State private var showingRestoreSheet = false
    @State private var recoveryMessage: String?
    @State private var showingWalkthrough = false
    /// The project whose sharing window is open (by uid: sharing moves it between stores).
    @State private var sharingProjectUID: SharingTarget?
    @State private var showingManageRepos = false
    @State private var showingDefaultCredits = false
    @State private var showingProjectImporter = false
    @State private var showingUnlock = false
    @State private var menuCommands = ProjectListCommands()
    @EnvironmentObject private var access: AppAccess
    @State private var restoringPurchase = false
    @State private var restoreMessage: String?
    @StateObject private var syncMonitor = CloudSyncMonitor()
    /// Drives On-Set Mode as a full-window, top-level viewing mode.
    @State private var onSet = OnSetController()
    @AppStorage("didShowWalkthrough_v1") private var didShowWalkthrough = false
    @AppStorage("projectSort") private var sortRaw = ProjectSort.recent.rawValue
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone portrait (regular height, compact width) has no room for the search
    /// box in the action row; it returns in landscape. iPad/Mac always show it.
    private var hideSearchBox: Bool {
        DeviceLayout.isPhone && verticalSizeClass == .regular
    }

    enum ProjectSort: String, CaseIterable, Identifiable {
        case recent, name
        var id: String { rawValue }
        var label: String { self == .recent ? "Recent" : "Name" }
    }

    private var sort: ProjectSort { ProjectSort(rawValue: sortRaw) ?? .recent }

    /// Repo full names still tied to a project in the app, so the manage-repos
    /// sheet can flag which published pages are still "in use".
    private var inUseRepoNames: Set<String> {
        Set(projects.compactMap { $0.publishedRepoFullName })
    }

    private func refreshSharedProjects() {
        sharedProjects = SharedProjectStore.contextIfPresent()
            .flatMap { try? $0.fetch(FetchDescriptor<Project>()) } ?? []
    }

    private var visibleProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty
            ? projects
            : projects.filter { $0.filmName.lowercased().contains(query) }
        switch sort {
        case .name:
            return filtered.sorted { $0.filmName.localizedCaseInsensitiveCompare($1.filmName) == .orderedAscending }
        case .recent:
            return filtered.sorted { ($0.lastOpenedDate ?? $0.createdDate) > ($1.lastOpenedDate ?? $1.createdDate) }
        }
    }

    // Cards are square, so the width range doubles as the height range — kept
    // tighter than a wide card would need so the tiles don't become huge.
    /// True on iPhone; false on iPad/Mac.
    private var isCompact: Bool { DeviceLayout.isPhone }

    /// iPhone fits two smaller cards per row; iPad/Mac keep the larger adaptive cards.
    private var columns: [GridItem] {
        if DeviceLayout.isPhone {
            return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]
    }

    var body: some View {
        ZStack {
        NavigationStack(path: $navigationPath) {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    projectGrid
                }
            }
            .overlay(alignment: .top) { TrialBanner() }
            .navigationTitle("CinePlanner")
            .task { refreshSharedProjects() }
            .onReceive(NotificationCenter.default.publisher(for: SharedProjectStore.didChange)) { _ in
                refreshSharedProjects()
            }
            // Sharing, asked for by a card or by the editor (which closes first: the
            // project may move to the shared store underneath it).
            .onReceive(NotificationCenter.default.publisher(for: ProjectSync.requestSharing)) { note in
                guard let uid = note.object as? String else { return }
                navigationPath = NavigationPath()
                sharingProjectUID = SharingTarget(uid: uid)
            }
            .sheet(item: $sharingProjectUID, onDismiss: refreshSharedProjects) { target in
                ProjectSharingSheet(projectUID: target.uid)
            }
            .overlay(alignment: .bottom) { SyncNoticeBanner() }
            .navigationDestination(for: Project.self) { project in
                // The editor — or, after the trial, the read-only viewer.
                ProjectDestination(project: project)
            }
            // Read-only after the trial: making or importing a project offers the unlock.
            .sheet(isPresented: $showingUnlock) { PaywallView(dismissable: true) }
            // File ▸ New / Import and Help ▸ Walkthrough in the menu bar — one stable
            // commands object, wired once (see AppCommands).
            .onAppear {
                menuCommands.newProject = newProject
                menuCommands.importProject = importProject
                menuCommands.showWalkthrough = { showingWalkthrough = true }
            }
            .focusedSceneValue(\.projectListCommands, menuCommands)
            .sheet(isPresented: $showingNewProjectSheet) {
                NewProjectSheet(isPresented: $showingNewProjectSheet) { projectName, isSeries, scriptURL in
                    createProject(named: projectName, isSeries: isSeries, scriptURL: scriptURL)
                }
            }
            .alert("Couldn't Import Project", isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importErrorMessage ?? "")
            }
            .fileImporter(isPresented: $showingProjectImporter,
                          allowedContentTypes: [.cineplanProject],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importProject(from: url)
                }
            }
            // A `.cineplan` opened from outside the app: double-clicked in Finder,
            // "Open in CinePlanner" from Files, an AirDrop or a mail attachment.
            .onOpenURL { url in
                guard url.isFileURL, url.pathExtension.lowercased() == ProjectArchive.fileExtension else { return }
                importProject(from: url)
                #if os(iOS)
                // A file is read in place where it lives (Files), but some routes (mail,
                // AirDrop) hand over a copy in the app's Inbox — drop that copy once it's
                // imported. Never the user's original.
                if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                #endif
            }
            .sheet(isPresented: $showingRestoreSheet) {
                RestoreBackupSheet()
            }
            .sheet(isPresented: $showingWalkthrough) {
                WalkthroughView()
            }
            .sheet(isPresented: $showingDefaultCredits) {
                DefaultCreditsSheet()
            }
            .sheet(isPresented: $showingManageRepos) {
                ManageRepositoriesSheet(inUseRepos: inUseRepoNames) { deletedRepo in
                    // Clear the link on any project that pointed at the deleted repo,
                    // so re-publishing it starts fresh.
                    for project in projects where project.publishedRepoFullName == deletedRepo {
                        project.publishedRepoFullName = nil
                    }
                }
            }
            .alert("Data Recovery", isPresented: Binding(
                get: { recoveryMessage != nil },
                set: { if !$0 { recoveryMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(recoveryMessage ?? "")
            }
            .alert("Restore Purchase", isPresented: Binding(
                get: { restoreMessage != nil },
                set: { if !$0 { restoreMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(restoreMessage ?? "")
            }
            .onAppear {
                // Surface a recovery notice from the launch's store-open, once.
                if let message = UserDefaults.standard.string(forKey: CinePlannerApp.recoveryMessageKey) {
                    recoveryMessage = message
                    UserDefaults.standard.removeObject(forKey: CinePlannerApp.recoveryMessageKey)
                }
                // First launch: show the walkthrough once (but never on top of a
                // recovery alert).
                if !didShowWalkthrough && recoveryMessage == nil {
                    didShowWalkthrough = true
                    showingWalkthrough = true
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)   // macOS window minimum; iPad sizes to the screen
        #endif

            // On-Set Mode takes over the whole window as its own viewing mode.
            if let onSetVersion = onSet.version {
                OnSetModeView(version: onSetVersion) { onSet.version = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .environment(onSet)
        .animation(.easeInOut(duration: 0.22), value: onSet.version?.uid)
        #if os(macOS)
        // While On-Set Mode is up, let the window content fill under the title bar so
        // the mode reaches the very top; restored when it closes.
        .background(OnSetWindowFiller(active: onSet.version != nil))
        #endif
    }

    /// Presents the system file picker to choose a .cineplan file to import.
    private func importProject() {
        guard !access.isLocked else { return }   // the trial offer is up (⌘O from the menu)
        if access.isReadOnly { showingUnlock = true; return }
        showingProjectImporter = true
    }

    /// Opens the new-project sheet — or, read-only after the trial, the unlock.
    private func newProject() {
        guard !access.isLocked else { return }   // the trial offer is up (⌘N from the menu)
        if access.isReadOnly { showingUnlock = true; return }
        showingNewProjectSheet = true
    }

    /// Restores a previous "CinePlanner — Full Version" purchase on this device.
    private func restorePurchase() {
        restoringPurchase = true
        Task {
            access.store.lastError = nil
            await access.store.restore()
            restoringPurchase = false
            if access.store.isPurchased {
                access.unlockedAfterPurchase()
                restoreMessage = "Your purchase has been restored. Thanks!"
            } else {
                restoreMessage = access.store.lastError ?? "No previous purchase found on this account."
            }
        }
    }

    /// Reads a chosen .cineplan file and adds its project (with fresh ids).
    @MainActor
    private func importProject(from url: URL) {
        if access.isReadOnly { showingUnlock = true; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let project = try ProjectArchive.importProject(from: data, into: modelContext)
            try modelContext.save()
            navigationPath.append(project)   // open the imported project
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Grid

    private var projectGrid: some View {
        VStack(spacing: 0) {
            // Search + sort
            HStack(spacing: 12) {
                // Hidden on iPhone portrait (no room); shown again in landscape.
                if !hideSearchBox {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search projects", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 320)
                }

                Spacer()

                CloudSyncBadge(monitor: syncMonitor) {
                    syncMonitor.requestSync(context: modelContext)
                }

                Button {
                    showingDefaultCredits = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.text.rectangle")
                        if !isCompact { Text("Credits") }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Default Credits — set a Director and Cinematographer to pre-fill on new projects")

                Button {
                    showingManageRepos = true
                } label: {
                    HStack(spacing: 6) {
                        Image("GitHubLogo")
                            .resizable().scaledToFit()
                            .frame(width: 15, height: 15)
                        if !isCompact { Text("Repositories") }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Manage Repositories — review and delete published pages on your GitHub account")

                Button {
                    showingRestoreSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        if !isCompact { Text("Backup") }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Restore from Backup — roll your data back to an earlier snapshot")

                if access.state != .full {
                    Button(action: restorePurchase) {
                        HStack(spacing: 6) {
                            if restoringPurchase {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            if !isCompact { Text("Restore Purchase") }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(restoringPurchase)
                    .help("Restore Purchase — unlock on this device if you already bought CinePlanner")
                }

                Button {
                    showingWalkthrough = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("How CinePlanner works — a quick visual walkthrough")

            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                if visibleProjects.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("No project matches “\(searchText)”.")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        // The add-project tile leads the grid, but only when not
                        // searching — it isn't a search result.
                        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            addProjectCard
                        }
                        ForEach(visibleProjects) { project in
                            NavigationLink(value: project) {
                                ProjectCardView(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
            }
        }
        // Clear any active search when the box hides (iPhone → portrait), so the
        // grid isn't left filtered with no visible way to reset it.
        .onChange(of: hideSearchBox) { _, hidden in
            if hidden { searchText = "" }
        }
    }

    /// Square tile matching the project cards but styled distinctly (dashed
    /// accent border) so it reads as an action. Split into two tappable halves:
    /// create a new project, or import one from a .cineplan file.
    private var addProjectCard: some View {
        VStack(spacing: 0) {
            Button {
                newProject()
            } label: {
                addCardHalf(icon: "plus", title: "New Project")
            }
            .buttonStyle(.plain)
            .help("Create a new project")

            Divider()

            Button {
                importProject()
            } label: {
                addCardHalf(icon: "square.and.arrow.down", title: "Import Project")
            }
            .buttonStyle(.plain)
            .help("Import a project from a .cineplan file")
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }

    private func addCardHalf(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
#if os(macOS)
            if let url = Bundle.main.url(forResource: "CinePlannerLogo", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 90)
            }
#else
            Image("CinePlannerLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 70)
#endif
            Text("Welcome to CinePlanner")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Create a project to import a script and start planning your shots.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                newProject()
            } label: {
                Label("New Project", systemImage: "plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)

            Button {
                showingWalkthrough = true
            } label: {
                Label("How it works", systemImage: "questionmark.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func createProject(named name: String, isSeries: Bool, scriptURL: URL?) {
        let newProject = Project(filmName: name, isSeries: isSeries)
        modelContext.insert(newProject)
        newProject.migrateStructureIfNeeded() // creates the first episode + version

        // Pre-fill the default credits (features read the project's fields; series
        // read each episode's), leaving anything the user hasn't set blank.
        let defDirector = CreditDefaults.director
        let defDP = CreditDefaults.cinematographer
        if !defDirector.isEmpty { newProject.director = defDirector }
        if !defDP.isEmpty { newProject.cinematographer = defDP }
        if let firstEpisode = newProject.orderedEpisodes.first {
            if !defDirector.isEmpty { firstEpisode.director = defDirector }
            if !defDP.isEmpty { firstEpisode.cinematographer = defDP }
        }

        navigationPath.append(newProject)

        guard let url = scriptURL,
              let version = newProject.orderedEpisodes.first?.orderedVersions.first else { return }

        Task { @MainActor in
            guard url.startAccessingSecurityScopedResource() else {
                Log.app.error("❌ Unable to access selected script file")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                _ = try await ScriptImporter.importScenes(from: url, into: version, project: newProject)
            } catch {
                Log.app.error("❌ Script import failed: \(error.localizedDescription)")
            }
        }
    }
    
}

// MARK: - Project Card

struct ProjectCardView: View {
    @Bindable var project: Project
    @EnvironmentObject private var access: AppAccess
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var showingSeriesToFilmBlocked = false
    @State private var exportErrorMessage: String?
    @State private var exportDocument: ProjectArchiveDocument?
    @State private var showingExporter = false
    @Environment(\.modelContext) private var modelContext

    private var shotCount: Int {
        project.scenes.reduce(0) { $0 + $1.shots.count }
    }

    /// Shared with us (not ours): it can be left, not deleted.
    private var isSharedWithUs: Bool {
        _ = ProjectSync.shared.sharesGeneration
        return ProjectSync.shared.shareInfo(for: project)?.isOwner == false
    }

    /// The card's actions. Read-only after the trial — or shared with us to view
    /// only — exporting (and the sharing window) is left.
    private var cardMenuItems: [ChipMenuItem] {
        let export = ChipMenuItem(title: "Export Project…", systemImage: "square.and.arrow.up") { exportProject() }
        guard !access.isReadOnly, ProjectSync.shared.canEdit(project) else { return [export] + sharingItems }
        let remove = isSharedWithUs
            ? ChipMenuItem(title: "Leave Shared Project…", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                NotificationCenter.default.post(name: ProjectSync.requestSharing, object: project.uid)
            }
            : ChipMenuItem(title: "Delete Project…", systemImage: "trash", role: .destructive) { showingDeleteAlert = true }
        return [
            ChipMenuItem(title: "Rename…", systemImage: "pencil") { showingEditSheet = true },
            ChipMenuItem(title: project.isSeries ? "Change to Film" : "Change to Series",
                         systemImage: project.isSeries ? "film" : "tv") { toggleProjectType() },
            export,
            .divider,
            remove,
        ] + sharingItems
    }

    /// Share… (the window explains Pro), or Sharing… once shared.
    private var sharingItems: [ChipMenuItem] {
        guard ProjectSharing.isEnabled else { return [] }
        let share = ChipMenuItem(title: SharedProjectStore.contains(project) ? "Sharing…" : "Share…",
                                 systemImage: "person.2") {
            NotificationCenter.default.post(name: ProjectSync.requestSharing, object: project.uid)
        }
        return [.divider, share]
    }

    private var subtitle: String {
        var parts: [String] = []
        if project.isSeries {
            parts.append("\(project.episodes.count) episode\(project.episodes.count == 1 ? "" : "s")")
        }
        parts.append("\(project.scenes.count) scene\(project.scenes.count == 1 ? "" : "s")")
        parts.append("\(shotCount) shot\(shotCount == 1 ? "" : "s")")
        if SharedProjectStore.contains(project) { parts.append(sharingLabel) }
        return parts.joined(separator: " · ")
    }

    private var sharingLabel: String {
        _ = ProjectSync.shared.sharesGeneration
        guard let info = ProjectSync.shared.shareInfo(for: project) else { return "Shared" }
        if !info.isOwner { return "Shared by \(info.ownerName ?? "someone")" }
        switch info.participantCount {
        case 0: return "Shared"
        case 1: return "Shared with 1 person"
        default: return "Shared with \(info.participantCount) people"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: project.isSeries ? "tv" : "film")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .help(project.isSeries ? "Series" : "Film")

                Spacer(minLength: 0)

                // Same actions as the right-click menu, always visible.
                ChipMenu(items: cardMenuItems, width: 210) {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help("Project options")
            }

            // The square card leaves room to spare, so the title sits on the
            // baseline of the card with the metadata beneath it rather than
            // everything crowding the top edge.
            Spacer(minLength: 8)

            Text(project.filmName)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(lastOpenedText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .aspectRatio(1, contentMode: .fit)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingEditSheet) {
            EditProjectNameSheet(project: project, isPresented: $showingEditSheet)
        }
        .alert("Couldn't Export Project", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .fileExporter(isPresented: $showingExporter,
                      document: exportDocument,
                      contentType: .cineplanProject,
                      defaultFilename: ProjectArchive.suggestedFileName(for: project)) { result in
            if case .failure(let error) = result {
                exportErrorMessage = error.localizedDescription
            }
        }
        .alert("Delete “\(project.filmName)”?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Project", role: .destructive) {
                deleteProject()
            }
        } message: {
            Text(SharedProjectStore.contains(project)
                 ? "This permanently deletes the project with all its episodes, scenes and shots, and stops sharing it. The people it was shared with keep their own copy. This cannot be undone."
                 : "This permanently deletes the project with all its episodes, scenes and shots. This cannot be undone.")
        }
        .alert("Can't switch to a film", isPresented: $showingSeriesToFilmBlocked) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A film has a single episode, but this series has \(project.episodes.count). Open it and delete the extra episodes first, then switch to a film.")
        }
    }

    /// The store this project lives in — the shared one for a shared project.
    private var context: ModelContext { project.modelContext ?? modelContext }

    /// Deletes the project and its whole object graph, in whichever store holds it.
    private func deleteProject() {
        let isShared = SharedProjectStore.contains(project)
        let context = context
        context.destructiveDelete { context.deleteProjectGraph(project) }
        if isShared { NotificationCenter.default.post(name: SharedProjectStore.didChange, object: nil) }
    }


    private var lastOpenedText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if let opened = project.lastOpenedDate {
            return "Opened \(formatter.localizedString(for: opened, relativeTo: Date()))"
        }
        return "Created \(formatter.localizedString(for: project.createdDate, relativeTo: Date()))"
    }

    /// Writes the whole project (media included) to a single .cineplan file the
    /// user can back up or hand off.
    @MainActor
    private func exportProject() {
        do {
            let data = try ProjectArchive.data(for: project)
            exportDocument = ProjectArchiveDocument(data: data)
            showingExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    /// Switches a project between film and series. Film→series always works
    /// (the lone episode becomes "Episode 1"). Series→film only when there's a
    /// single episode — otherwise the extras would be orphaned, so it's blocked.
    private func toggleProjectType() {
        if project.isSeries {
            guard project.episodes.count <= 1 else {
                showingSeriesToFilmBlocked = true
                return
            }
            project.isSeries = false
            if let episode = project.orderedEpisodes.first, episode.title == "Episode 1" {
                episode.title = "Main Feature"
            }
        } else {
            project.isSeries = true
            if let episode = project.orderedEpisodes.first, episode.title == "Main Feature" {
                episode.title = "Episode 1"
            }
        }
        context.saveReporting()
    }
}

// MARK: - Edit Project Name Sheet

struct EditProjectNameSheet: View {
    @Bindable var project: Project
    @Binding var isPresented: Bool
    @State private var editedName: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Project")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Give this project a new name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 8) {
                Text("Project Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Project name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($isTextFieldFocused)
                    .onSubmit(save)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)

            Divider()

            // Footer
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 460, height: 250)
        .onAppear {
            editedName = project.filmName
            isTextFieldFocused = true
        }
    }

    private func save() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.filmName = trimmed
        isPresented = false
    }
}

// MARK: - New Project Sheet

struct NewProjectSheet: View {
    @Binding var isPresented: Bool
    let onCreate: (String, Bool, URL?) -> Void
    @State private var projectName = ""
    @State private var isSeries = false
    @State private var step: Step = .name
    @State private var isImportingScript = false
    @FocusState private var isTextFieldFocused: Bool

    enum Step {
        case name
        case script
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .name:
                nameStep
            case .script:
                scriptStep
            }
        }
        .adaptiveSheetFrame(width: 520, height: 400)
    }

    private var nameStep: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Project",
                        subtitle: "Name your project and choose what kind it is.")

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SheetSectionHeader(title: "PROJECT NAME")
                    TextField("e.g. The Grand Budapest Hotel", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($isTextFieldFocused)
                        .onSubmit(goToScriptStep)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SheetSectionHeader(title: "PROJECT TYPE")
                    // Two cards rather than a segmented control: they carry the
                    // explanation inline instead of in a caption that changes
                    // under the picker, and they echo the project cards outside.
                    HStack(spacing: 10) {
                        SheetSelectableCard(
                            icon: "film",
                            title: "Film",
                            detail: "A single script, with versions as it changes.",
                            isSelected: !isSeries
                        ) { isSeries = false }

                        SheetSelectableCard(
                            icon: "tv",
                            title: "Series",
                            detail: "Multiple episodes, each with its own script.",
                            isSelected: isSeries
                        ) { isSeries = true }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Next", action: goToScriptStep)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            // Overlaid rather than placed between the buttons, so the dots centre
            // on the window instead of drifting with the buttons' widths.
            .overlay(SheetStepDots(count: 2, current: 0))
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private var scriptStep: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Add a Script",
                        subtitle: "Import a screenplay PDF to create scenes automatically, or start empty and add them by hand.")

            Divider()

            VStack(spacing: 10) {
                SheetActionCard(
                    icon: "sparkles",
                    title: "Auto-Load Scenes from Script",
                    detail: "Pick a screenplay PDF. Every scene heading becomes a scene, ready for shots.",
                    isProminent: true
                ) { isImportingScript = true }

                SheetActionCard(
                    icon: "square.dashed",
                    title: "Skip for Now",
                    detail: "Create the project empty. You can import a script at any time later."
                ) {
                    onCreate(projectName, isSeries, nil)
                    finish()
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)

            Divider()

            HStack {
                Button("Back") { step = .name }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(16)
            .overlay(SheetStepDots(count: 2, current: 1))
        }
        .fileImporter(
            isPresented: $isImportingScript,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onCreate(projectName, isSeries, url)
                finish()
            }
        }
    }

    private func goToScriptStep() {
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isTextFieldFocused = false
        step = .script
    }

    private func finish() {
        isPresented = false
        projectName = ""
        isSeries = false
        step = .name
    }
}

// MARK: - Restore from Backup Sheet

struct RestoreBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [StoreBackup.Backup] = []
    @State private var confirmBackup: StoreBackup.Backup?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore from Backup")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("CinePlanner snapshots your data each time it launches. Restoring replaces your current data with a snapshot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            if backups.isEmpty {
                ContentUnavailableView(
                    "No Backups Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("A backup is made automatically each time you open CinePlanner. They'll appear here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                .fontWeight(.medium)
                            Text(ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { confirmBackup = backup }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 460, height: 440)
        .onAppear { backups = StoreBackup.listBackups() }
        .alert("Restore this backup?", isPresented: Binding(
            get: { confirmBackup != nil },
            set: { if !$0 { confirmBackup = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button(restoreConfirmTitle, role: .destructive) {
                if let backup = confirmBackup {
                    StoreBackup.requestRestore(backup)
                    #if os(macOS)
                    // Close the alert and the sheet first: AppKit refuses to terminate
                    // (and beeps) while a modal sheet is still open. Relaunch once it's
                    // had a moment to animate away.
                    confirmBackup = nil
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { relaunchApp() }
                    #else
                    // iOS can't relaunch itself; the restore applies on next launch
                    // (the user reopens from the App Switcher).
                    #endif
                }
            }
        } message: {
            #if os(macOS)
            Text("Your current data will be replaced with this backup. CinePlanner will restart to finish restoring.")
            #else
            Text("Your current data will be replaced with this backup. CinePlanner will quit — reopen it to finish restoring.")
            #endif
        }
    }

    private var restoreConfirmTitle: String {
        #if os(macOS)
        "Restore & Restart"
        #else
        "Restore & Quit"
        #endif
    }

    #if os(macOS)
    /// Relaunch the app: a detached shell waits for this process to exit, then
    /// reopens the app bundle, so the queued restore is applied on the fresh launch.
    private func relaunchApp() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.2; done; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
    #endif
}

#Preview {
    ProjectListView()
        .modelContainer(for: Project.self, inMemory: true)
        .environmentObject(AppAccess())
}
