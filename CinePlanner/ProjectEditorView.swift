//
//  ProjectEditorView.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

struct ProjectEditorView: View {
    @Bindable var project: Project
    @Environment(\.modelContext) private var modelContext

    // Live column widths. Dragging updates these (cheap, local); the value is
    // written back to the project only when the drag ends, so we're not saving
    // to SwiftData on every frame.
    @State private var scriptWidth: CGFloat = 420
    /// The script pane's share of the details+script pair (seeded from the
    /// project, clamped to the allowed band).
    @State private var scriptFraction: CGFloat = 0.5
    // Selection is tracked by uid (stable across saves), not the model itself.
    @State private var selectedScenes: Set<String> = []
    @State private var selectedShots: Set<String> = []

    // Edit / delete targets (driven by right-click context menus on rows)
    @State private var sceneToEdit: Scene?
    @State private var shotToEdit: Shot?
    @State private var pendingSceneDeletion: [Scene] = []
    @State private var pendingShotDeletion: [Shot] = []

    // Episodes & script versioning
    @State private var selectedEpisode: Episode?
    @State private var selectedVersion: ScriptVersion?
    @State private var showCopyShotsPrompt = false
    @State private var showTransferSheet = false
    @State private var requestScriptImport = false
    @State private var showExportSheet = false
    @State private var showPublishSheet = false
    @State private var showingDeletePageConfirm = false
    @State private var isDeletingPage = false
    @State private var deletePageError: String?
    @State private var pageIsLive = false

    private var publishedURL: String? { GitHubPublisher.publishedURL(forProjectUID: project.uid) }
    @State private var sceneForShotImport: Scene?
    @State private var versionPendingDeletion: ScriptVersion?
    @State private var versionToRename: ScriptVersion?
    @State private var episodePendingDeletion: Episode?
    @State private var episodeToRename: Episode?
    @State private var renameText: String = ""

    /// Versions in the selected episode.
    private var currentVersions: [ScriptVersion] {
        selectedEpisode?.orderedVersions ?? []
    }

    private var orderedScenes: [Scene] {
        (selectedVersion?.scenes ?? project.scenes).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Versions of the current episode (other than the selected one) that contain
    /// at least one shot — candidates for copying shots into the current version.
    private var otherVersionsWithShots: [ScriptVersion] {
        currentVersions.filter { $0 !== selectedVersion && $0.totalShotCount > 0 }
    }

    // Resolve the selected model by its stable uid. (uid never changes on save,
    // so unlike Set<Model>.contains this can't miss a freshly-created row.)
    private var selectedScene: Scene? {
        orderedScenes.first { selectedScenes.contains($0.uid) }
    }

    private var selectedShot: Shot? {
        guard let scene = selectedScene else { return nil }
        return scene.shots.sorted { $0.shotNumber < $1.shotNumber }.first { selectedShots.contains($0.uid) }
    }
    
    var body: some View {
        deletionAlerts(editorAlerts(editorSheets(coreView)))
    }

    private var coreView: some View {
        editorView
        .navigationTitle(project.filmName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                actionButtons
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if let url = publishedURL {
                        publishedPageMenu(url: url)
                    }
                    exportButton
                }
            }
        }
        .onAppear {
            // Ensure the project has the episode → version structure (migrates legacy projects)
            project.migrateStructureIfNeeded()
            project.lastOpenedDate = Date()

            // The script split is seeded where its width is derived (in the
            // editor columns' GeometryReader), so nothing to do here.
            if selectedEpisode == nil {
                selectedEpisode = project.orderedEpisodes.first
            }
            if selectedVersion == nil {
                selectedVersion = selectedEpisode?.orderedVersions.last
            }

            // Select first scene and shot automatically
            if selectedScenes.isEmpty, let firstScene = orderedScenes.first {
                selectedScenes = [firstScene.uid]
                if let firstShot = firstScene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
                    selectedShots = [firstShot.uid]
                }
            }
        }
        .onChange(of: selectedEpisode) {
            // Switching episodes selects that episode's latest version
            selectedVersion = selectedEpisode?.orderedVersions.last
        }
        .onChange(of: selectedVersion) {
            // Switching script versions invalidates the scene/shot selection
            selectedShots = []
            if let firstScene = orderedScenes.first {
                selectedScenes = [firstScene.uid]
            } else {
                selectedScenes = []
            }
        }
        // Key on the scene's stable uid, not the scene itself: a brand-new scene's
        // persistentModelID (which drives Scene's Equatable) flips on its first
        // save, and keying on the scene would fire this handler on that flip and
        // wipe a just-made shot selection. uid never changes, so this fires only
        // on a real scene switch.
        .onChange(of: selectedScene?.uid) { oldUID, newUID in
            // Picking a scene lands on its first shot, so the detail pane always
            // has something to show. Scenes without shots clear the selection.
            guard oldUID != newUID else { return }
            if let firstShot = selectedScene?.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
                selectedShots = [firstShot.uid]
            } else {
                selectedShots = []
            }
        }
    }

    private func editorSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $sceneToEdit) { scene in
            editSceneSheet(for: scene)
        }
        .sheet(item: $shotToEdit) { shot in
            editShotSheet(for: shot)
        }
        .sheet(isPresented: $showTransferSheet) {
            if let targetVersion = selectedVersion {
                ShotTransferView(project: project, targetVersion: targetVersion)
            }
        }
        .sheet(item: $sceneForShotImport) { targetScene in
            SingleSceneShotImportSheet(project: project, targetScene: targetScene)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportOptionsSheet(project: project, version: selectedVersion)
        }
        .sheet(isPresented: $showPublishSheet) {
            GitHubPublishSheet(project: project, version: selectedVersion)
        }
        .alert("Delete the published page?", isPresented: $showingDeletePageConfirm) {
            Button("Delete", role: .destructive) { deletePublishedPage() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes the GitHub repository and takes the online page offline. Your project in CinePlanner is untouched.")
        }
        .alert("Couldn't delete the page", isPresented: Binding(
            get: { deletePageError != nil }, set: { if !$0 { deletePageError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deletePageError ?? "")
        }
    }

    /// Small round GitHub button next to Export — opens/updates/deletes the online page.
    private func publishedPageMenu(url: String) -> some View {
        ChipMenu(items: [
            ChipMenuItem(title: "Open Published Page", systemImage: "safari") {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            },
            ChipMenuItem(title: "Update Page", systemImage: "arrow.clockwise") { showPublishSheet = true },
            .divider,
            ChipMenuItem(title: "Delete Published Page", systemImage: "trash", role: .destructive) {
                showingDeletePageConfirm = true
            },
        ], width: 230) {
            Group {
                if isDeletingPage {
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
        .disabled(isDeletingPage)
        .help(pageIsLive ? "Published page is live — open, update, or delete it"
                         : "Published page — open, update, or delete it online")
        .task(id: url) { await checkPageLive(url) }
    }

    /// Probes the published URL; the corner check shows when it responds live.
    @MainActor
    private func checkPageLive(_ urlString: String) async {
        guard let url = URL(string: urlString) else { pageIsLive = false; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let response = try? await URLSession.shared.data(for: request)
        let code = (response?.1 as? HTTPURLResponse)?.statusCode ?? 0
        pageIsLive = (200..<400).contains(code)
    }

    private func deletePublishedPage() {
        isDeletingPage = true
        Task { @MainActor in
            do {
                try await GitHubPublisher.deletePublishedPage(forProjectUID: project.uid)
            } catch {
                deletePageError = error.localizedDescription
            }
            isDeletingPage = false
        }
    }

    private func editorAlerts<Content: View>(_ content: Content) -> some View {
        content
        .alert("Rename Script Version", isPresented: Binding(
            get: { versionToRename != nil },
            set: { if !$0 { versionToRename = nil } }
        )) {
            TextField("Version name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let version = versionToRename, !trimmed.isEmpty {
                    version.name = trimmed
                }
                versionToRename = nil
            }
            Button("Cancel", role: .cancel) { versionToRename = nil }
        } message: {
            Text("Enter a new name for this script version.")
        }
        .alert("Rename Episode", isPresented: Binding(
            get: { episodeToRename != nil },
            set: { if !$0 { episodeToRename = nil } }
        )) {
            TextField("Episode title", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let episode = episodeToRename, !trimmed.isEmpty {
                    episode.title = trimmed
                }
                episodeToRename = nil
            }
            Button("Cancel", role: .cancel) { episodeToRename = nil }
        } message: {
            Text("Enter a new title for this episode.")
        }
        .alert(
            "Delete \(episodePendingDeletion?.title ?? "Episode")?",
            isPresented: Binding(
                get: { episodePendingDeletion != nil },
                set: { if !$0 { episodePendingDeletion = nil } }
            )
        ) {
            Button("Delete Episode", role: .destructive) {
                if let episode = episodePendingDeletion {
                    deleteEpisode(episode)
                }
                episodePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { episodePendingDeletion = nil }
        } message: {
            let versionCount = episodePendingDeletion?.scriptVersions.count ?? 0
            let shotCount = episodePendingDeletion?.totalShotCount ?? 0
            Text("This deletes the episode with its \(versionCount) script version\(versionCount == 1 ? "" : "s") and \(shotCount) shot\(shotCount == 1 ? "" : "s"). This cannot be undone.")
        }
        .alert("Copy Shots from a Previous Version?", isPresented: $showCopyShotsPrompt) {
            Button("Copy Shots…") {
                try? modelContext.save() // stable IDs before matching
                showTransferSheet = true
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("The scenes were imported. Do you want to copy over the shots you planned in a previous script version? You can match old scenes to the new ones before anything is copied.")
        }
    }

    private func deletionAlerts<Content: View>(_ content: Content) -> some View {
        content
        .alert(
            "Delete \(versionPendingDeletion?.name ?? "Version")?",
            isPresented: Binding(
                get: { versionPendingDeletion != nil },
                set: { if !$0 { versionPendingDeletion = nil } }
            )
        ) {
            Button("Delete Version", role: .destructive) {
                if let version = versionPendingDeletion {
                    deleteVersion(version)
                }
                versionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { versionPendingDeletion = nil }
        } message: {
            let sceneCount = versionPendingDeletion?.scenes.count ?? 0
            let shotCount = versionPendingDeletion?.totalShotCount ?? 0
            Text("This deletes the script version with its \(sceneCount) scene\(sceneCount == 1 ? "" : "s") and \(shotCount) shot\(shotCount == 1 ? "" : "s"). This cannot be undone.")
        }
        .alert(
            sceneDeletionTitle,
            isPresented: Binding(
                get: { !pendingSceneDeletion.isEmpty },
                set: { if !$0 { pendingSceneDeletion = [] } }
            )
        ) {
            Button(pendingSceneDeletion.count > 1 ? "Delete \(pendingSceneDeletion.count) Scenes" : "Delete Scene", role: .destructive) {
                deleteScenes(pendingSceneDeletion)
                pendingSceneDeletion = []
            }
            Button("Cancel", role: .cancel) { pendingSceneDeletion = [] }
        } message: {
            Text(pendingSceneDeletion.count > 1
                 ? "This will permanently delete \(pendingSceneDeletion.count) scenes and all their shots. This action cannot be undone."
                 : "This will permanently delete the scene and all its shots. This action cannot be undone.")
        }
        .alert(
            shotDeletionTitle,
            isPresented: Binding(
                get: { !pendingShotDeletion.isEmpty },
                set: { if !$0 { pendingShotDeletion = [] } }
            )
        ) {
            Button(pendingShotDeletion.count > 1 ? "Delete \(pendingShotDeletion.count) Shots" : "Delete Shot", role: .destructive) {
                deleteShots(pendingShotDeletion)
                pendingShotDeletion = []
            }
            Button("Cancel", role: .cancel) { pendingShotDeletion = [] }
        } message: {
            Text(pendingShotDeletion.count > 1
                 ? "This will permanently delete \(pendingShotDeletion.count) shots. This action cannot be undone."
                 : "This will permanently delete this shot. This action cannot be undone.")
        }
    }

    private var sceneDeletionTitle: String {
        if pendingSceneDeletion.count == 1, let scene = pendingSceneDeletion.first {
            return "Delete Scene \(scene.sceneNumber)\(scene.suffix)?"
        }
        return "Delete \(pendingSceneDeletion.count) Scenes?"
    }

    private var shotDeletionTitle: String {
        if pendingShotDeletion.count == 1, let shot = pendingShotDeletion.first {
            return "Delete Shot \(shot.displayNumber)?"
        }
        return "Delete \(pendingShotDeletion.count) Shots?"
    }
    
    // MARK: - Editor View

    private var editorView: some View {
        VStack(spacing: 0) {
            contextBar
            Divider()
            editorColumns
        }
    }

    // MARK: - Context Bar (episode + script versions in one row)

    private var contextBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Episodes collapse into a menu so a 12-episode show stays compact
                if project.isSeries {
                    episodeMenu
                    Divider().frame(height: 18)
                }

                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Script Version:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(currentVersions, id: \.uid) { version in
                    versionTab(for: version)
                }

                Button {
                    addNewVersion()
                } label: {
                    Label("New Version", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a new script version and import an updated screenplay")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var episodeMenu: some View {
        ChipMenu(items:
            project.orderedEpisodes.map { episode in
                ChipMenuItem(title: episode.title, isSelected: selectedEpisode === episode) {
                    selectedEpisode = episode
                }
            }
            + [
                .divider,
                ChipMenuItem(title: "New Episode…", systemImage: "plus") { addEpisode() },
                ChipMenuItem(title: "Rename Episode…", systemImage: "pencil",
                             isDisabled: selectedEpisode == nil) {
                    if let episode = selectedEpisode {
                        renameText = episode.title
                        episodeToRename = episode
                    }
                },
                ChipMenuItem(title: "Delete Episode…", systemImage: "trash", role: .destructive,
                             isDisabled: project.episodes.count <= 1) {
                    episodePendingDeletion = selectedEpisode
                },
            ]
        ) {
            HStack(spacing: 6) {
                Image(systemName: "tv")
                    .font(.caption)
                Text(selectedEpisode?.title ?? "Episode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let shots = selectedEpisode?.totalShotCount, shots > 0 {
                    Text("\(shots) shots")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .fixedSize()
        .help("Switch episode, or add/rename/delete episodes")
    }

    @ViewBuilder
    private func versionTab(for version: ScriptVersion) -> some View {
        let isSelected = selectedVersion === version
        Button {
            selectedVersion = version
        } label: {
            HStack(spacing: 6) {
                Text(version.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                if version.totalShotCount > 0 {
                    Text("\(version.totalShotCount) shots")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(
                Capsule().stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = version.name
                versionToRename = version
            } label: {
                Text("Rename…")
            }
            Divider()
            Button(role: .destructive) {
                versionPendingDeletion = version
            } label: {
                Text("Delete Version…")
            }
            .disabled(currentVersions.count <= 1)
        }
    }

    /// Sum of the columns' minimum widths (scenes + shots + detail + script + dividers).
    /// Keeps the window from ever being narrower than the layout needs — otherwise
    /// the columns get squeezed into (and clipped by) one another.
    private var minimumEditorWidth: CGFloat {
        // Uses each pane's *minimum* (not its preferred width) so the window can
        // still shrink to fit smaller displays.
        (Self.sideColumnWidth * 2) + Self.paneMinWidth + Self.detailPaneMinWidth + Self.dividerAllowance
    }

    /// Scenes and shots share one fixed width. Both have predictable row content
    /// — the scene tag line ("EXT" + "NIGHT" + a three-digit shot count) is the
    /// widest thing either shows — so neither needs a resize handle, and a shared
    /// value keeps the two lists aligned with each other.
    private static let sideColumnWidth: CGFloat = 190
    private static let dividerAllowance: CGFloat = 12

    // Shot details and script split the space left over from the fixed columns.
    // Default 50/50; the divider may move up to 20% of the pair either way.
    private static let scriptSplitDefault: CGFloat = 0.5
    private static let scriptSplitMinFraction: CGFloat = 0.30
    private static let scriptSplitMaxFraction: CGFloat = 0.70
    /// Script pane minimum — low, so the script can shrink to 30% (letting the
    /// details pane grow) on normal windows.
    private static let paneMinWidth: CGFloat = 200
    /// Details pane minimum — set by its content (labelled fields), so the script
    /// only grows past 50% when the window is wide enough to leave this much room.
    private static let detailPaneMinWidth: CGFloat = 340

    /// Space the details and script panes divide between them.
    private func combinedPaneWidth(available: CGFloat) -> CGFloat {
        max(0, available - (Self.sideColumnWidth * 2) - Self.dividerAllowance)
    }

    /// The width range the script pane may be dragged to at the current window
    /// size: the ±20% band, clamped so neither pane drops below its minimum.
    private func scriptWidthBounds(available: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let combined = combinedPaneWidth(available: available)
        let low = max(Self.paneMinWidth, combined * Self.scriptSplitMinFraction)
        let high = min(combined - Self.detailPaneMinWidth, combined * Self.scriptSplitMaxFraction)
        return (min(low, high), max(low, high))
    }

    /// Derives the script pane's width from the stored fraction, clamped to the
    /// allowed band — so the split holds its proportion as the window resizes.
    private func applyScriptSplit(available: CGFloat) {
        let combined = combinedPaneWidth(available: available)
        guard combined > 0 else { return }
        let bounds = scriptWidthBounds(available: available)
        scriptWidth = min(max(combined * scriptFraction, bounds.min), bounds.max)
    }

    private var editorColumns: some View {
        GeometryReader { geo in
            editorColumnStack(available: geo.size.width)
                .onAppear {
                    // Seed here, right before deriving the width, so the order
                    // relative to the view's own onAppear can't matter.
                    scriptFraction = min(max(CGFloat(project.scriptSplitFraction),
                                             Self.scriptSplitMinFraction), Self.scriptSplitMaxFraction)
                    applyScriptSplit(available: geo.size.width)
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    // Re-derive from the fraction so the split holds as the window resizes.
                    applyScriptSplit(available: newWidth)
                }
        }
        .frame(minWidth: minimumEditorWidth, minHeight: 700)
    }

    private func editorColumnStack(available: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Sidebar - Scenes (fixed width, matching the shots column)
            SceneListView(
                project: project,
                version: selectedVersion,
                selectedScenes: $selectedScenes,
                canImportShots: !otherVersionsWithShots.isEmpty,
                onEditScene: { sceneToEdit = $0 },
                onImportShots: { try? modelContext.save(); sceneForShotImport = $0 },
                onDeleteScenes: { pendingSceneDeletion = $0 }
            )
            .frame(width: Self.sideColumnWidth)
            .clipped()

            Divider()

            // Middle column - Shots (fixed width)
            Group {
                if let scene = selectedScene {
                    ShotListView(
                        scene: scene,
                        selectedShots: $selectedShots,
                        onEditShot: { shotToEdit = $0 },
                        onDeleteShots: { pendingShotDeletion = $0 }
                    )
                } else {
                    ContentUnavailableView(
                        "No Scene Selected",
                        systemImage: "film",
                        description: Text("Select a scene from the sidebar or create a new one")
                    )
                }
            }
            // Fixed width: the shot rows have a predictable size, so this is just
            // wide enough to show them in full — no resize handle needed.
            .frame(width: Self.sideColumnWidth)
            .clipped()

            Divider()
            
            // Detail - Shot information (Resizable width)
            Group {
                if let shot = selectedShot {
                    ShotDetailView(shot: shot)
                } else {
                    ContentUnavailableView(
                        "No Shot Selected",
                        systemImage: "camera.circle.fill",
                        description: Text("Select a shot to view its details")
                    )
                }
            }
            // Detail is the flexible pane: it absorbs whatever width is left and can
            // compress down to its minimum so the layout fits narrower displays.
            .frame(minWidth: Self.detailPaneMinWidth, maxWidth: .infinity)

            // Draggable divider setting the script pane's width. The script pane
            // is to the right, so the drag is inverted. Its range is the split
            // band, so the two panes stay near even.
            ResizableDivider(
                width: $scriptWidth,
                minWidth: scriptWidthBounds(available: available).min,
                maxWidth: scriptWidthBounds(available: available).max,
                invertDrag: true
            ) { newWidth in
                let combined = combinedPaneWidth(available: available)
                guard combined > 0 else { return }
                scriptFraction = newWidth / combined
                project.scriptSplitFraction = Double(scriptFraction)
            }

            // Fourth column - Script PDF Viewer (preferred width, can compress)
            ScriptPDFViewer(
                project: project,
                version: selectedVersion,
                selectedScenePage: selectedScene?.absolutePDFPage,
                selectedScene: selectedScene,
                selectedShot: selectedShot,
                onScenesImported: { _ in
                    // Offer to copy shots over when another version has planned shots
                    if !otherVersionsWithShots.isEmpty {
                        showCopyShotsPrompt = true
                    }
                },
                requestImport: $requestScriptImport
            )
            .frame(minWidth: Self.paneMinWidth, idealWidth: scriptWidth, maxWidth: scriptWidth)
            .clipped()
        }
    }

    // MARK: - Episode Management

    private func addEpisode() {
        let nextNumber = (project.episodes.map(\.episodeNumber).max() ?? 0) + 1
        let episode = Episode(episodeNumber: nextNumber)
        episode.project = project
        // Every episode starts with an empty first version, ready to import into.
        let version = ScriptVersion(versionNumber: 1)
        version.episode = episode
        selectedEpisode = episode
        selectedVersion = version
        // Prompt to import the episode's script right away
        requestScriptImport = true
    }

    private func deleteEpisode(_ episode: Episode) {
        let wasSelected = selectedEpisode === episode
        // Detach every scene of the episode's versions from the project list, then
        // delete the episode — its versions/scenes/shots cascade with it.
        for version in episode.scriptVersions {
            for scene in version.scenes {
                if let index = project.scenes.firstIndex(where: { $0 === scene }) {
                    project.scenes.remove(at: index)
                }
            }
        }
        if let index = project.episodes.firstIndex(where: { $0 === episode }) {
            project.episodes.remove(at: index)
        }
        modelContext.delete(episode)
        if wasSelected {
            selectedEpisode = project.orderedEpisodes.first
            selectedVersion = selectedEpisode?.orderedVersions.last
        }
    }

    // MARK: - Version Management

    private func addNewVersion() {
        guard let episode = selectedEpisode else { return }
        let nextNumber = (episode.scriptVersions.map(\.versionNumber).max() ?? 0) + 1
        let version = ScriptVersion(versionNumber: nextNumber)
        version.episode = episode
        selectedVersion = version
        // Prompt to import the new script right away
        requestScriptImport = true
    }

    private func deleteVersion(_ version: ScriptVersion) {
        let wasSelected = selectedVersion === version
        // Detach the version's scenes from the project list, then delete the
        // version — its scenes (and their shots) cascade with it.
        for scene in version.scenes {
            if let index = project.scenes.firstIndex(where: { $0 === scene }) {
                project.scenes.remove(at: index)
            }
        }
        if let episode = version.episode, let index = episode.scriptVersions.firstIndex(where: { $0 === version }) {
            episode.scriptVersions.remove(at: index)
        }
        modelContext.delete(version)
        if wasSelected {
            selectedVersion = selectedEpisode?.orderedVersions.last
        }
    }
    
    // MARK: - Toolbar Views
    
    private var titleView: some View {
        Text(project.filmName)
            .font(.title2)
            .fontWeight(.bold)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
    
    /// Primary export action — an accent capsule matching the version tabs
    /// and the chips used elsewhere in the app.
    private var exportButton: some View {
        Button {
            showExportSheet = true
        } label: {
            Text("Export")
                .font(.body)
                .fontWeight(.semibold)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.14))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Export this shot list as PDF, text, or a web page with media")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if selectedScenes.count == 1, let scene = selectedScene, !otherVersionsWithShots.isEmpty {
            Button {
                try? modelContext.save() // stable IDs before matching
                sceneForShotImport = scene
            } label: {
                Label("Import Shots…", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Copy the shots of a scene from a different script version into this scene")
        }
    }

    // MARK: - Sheet Views

    @ViewBuilder
    private func editSceneSheet(for scene: Scene) -> some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Scene")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Scene \(scene.sceneNumber)\(scene.suffix)\(scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " — \(scene.nickname)")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            // Content
            Form {
                sceneDetailsSection(for: scene)
                sceneDayNightSection(for: scene)
                sceneLocationSection(for: scene)
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Done") { sceneToEdit = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 640)
    }

    @ViewBuilder
    private func editShotSheet(for shot: Shot) -> some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Shot")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Shot \(shot.displayNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            // Content
            Form {
                Section("Numbering Style") {
                    Picker("Style", selection: Binding(
                        get: { shot.numberingStyle },
                        set: { newStyle in
                            applyNumberingStyleToAllShots(newStyle)
                        }
                    )) {
                        Text("Numbers (1, 2, 3...)").tag(ShotNumberingStyle.numbers)
                        Text("Letters (A, B, C...)").tag(ShotNumberingStyle.letters)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Preview") {
                        Text("Shot \(shot.displayNumber)")
                            .fontWeight(.semibold)
                    }

                    Text("This style will be applied to all shots in the project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Done") { shotToEdit = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 380)
    }
    
    // MARK: - Scene Form Sections
    
    @ViewBuilder
    private func sceneDetailsSection(for scene: Scene) -> some View {
        Section("Scene Details") {
            LabeledContent("Scene Number") {
                TextField("Number", value: Binding(
                    get: { scene.sceneNumber },
                    set: { scene.sceneNumber = max(1, $0) }
                ), format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
            }

            LabeledContent("Suffix") {
                HStack(spacing: 8) {
                    TextField("None", text: Binding(
                        get: { scene.suffix },
                        set: { newValue in
                            if newValue.count <= 5 { scene.suffix = newValue.uppercased() }
                        }
                    ))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)

                    Text("\(scene.suffix.count)/5")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Nickname") {
                TextField("Optional name", text: Binding(
                    get: { scene.nickname },
                    set: { scene.nickname = $0 }
                ))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }
        }

        Section("Script Location") {
            LabeledContent("Scene Page") {
                HStack(spacing: 8) {
                    TextField("Page", value: Binding(
                        get: { scene.scriptPageNumber }, // Already 1-based
                        set: { scene.scriptPageNumber = max(1, $0) } // Minimum page 1
                    ), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)

                    if scene.scriptPageNumber > 0 {
                        Text("PDF page \(scene.absolutePDFPage + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let hasPDF = (scene.scriptVersion?.pdfData ?? project.scriptPDFData) != nil
            if scene.scriptPageNumber == 0 && hasPDF {
                Text("Page number not set. Enter the scene page where this scene appears (first scene = page 1).")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if scene.scriptPageNumber > 0 {
                Text("This is scene page \(scene.scriptPageNumber). The PDF viewer will jump to PDF page \(scene.absolutePDFPage + 1) when this scene is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasPDF {
                Text("No script PDF imported. Import a script to enable PDF page synchronization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    @ViewBuilder
    private func sceneDayNightSection(for scene: Scene) -> some View {
        Section("Time of Day") {
            Picker("Time", selection: Binding(
                get: { scene.isDay ? "Day" : "Night" },
                set: { scene.isDay = ($0 == "Day") }
            )) {
                Text("Day").tag("Day")
                Text("Night").tag("Night")
            }
            .pickerStyle(.segmented)
        }
    }
    
    @ViewBuilder
    private func sceneLocationSection(for scene: Scene) -> some View {
        Section("Location Type") {
            Picker("Location", selection: Binding(
                get: { scene.isInterior ? "Int." : "Ext." },
                set: { scene.isInterior = ($0 == "Int.") }
            )) {
                Text("Int.").tag("Int.")
                Text("Ext.").tag("Ext.")
            }
            .pickerStyle(.segmented)
        }
    }
    
    // MARK: - Confirmation Dialog
    
    // MARK: - Helper Functions

    private func deleteScenes(_ scenes: [Scene]) {
        guard !scenes.isEmpty else { return }

        for scene in scenes {
            if let index = project.scenes.firstIndex(where: { $0 === scene }) {
                project.scenes.remove(at: index)
            }
            if let version = scene.scriptVersion,
               let index = version.scenes.firstIndex(where: { $0 === scene }) {
                version.scenes.remove(at: index)
            }
            modelContext.delete(scene)
        }

        selectedScenes = []
        selectedShots = []

        // Renumber sortOrder and select the first remaining scene in this version
        for (index, scene) in orderedScenes.enumerated() {
            scene.sortOrder = index
        }
        if let firstScene = orderedScenes.first {
            selectedScenes = [firstScene.uid]
            if let firstShot = firstScene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
                selectedShots = [firstShot.uid]
            }
        }
    }

    private func deleteShots(_ shots: [Shot]) {
        guard !shots.isEmpty else { return }
        let affectedScenes = Set(shots.compactMap { $0.scene })

        for shot in shots {
            if let scene = shot.scene, let index = scene.shots.firstIndex(where: { $0 === shot }) {
                scene.shots.remove(at: index)
            }
            modelContext.delete(shot)
        }

        selectedShots = []

        // Renumber remaining shots in every affected scene
        for scene in affectedScenes {
            let ordered = scene.shots.sorted { $0.shotNumber < $1.shotNumber }
            for (index, shot) in ordered.enumerated() {
                shot.shotNumber = index + 1
            }
        }

        if let scene = selectedScene,
           let firstShot = scene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
            selectedShots = [firstShot.uid]
        }
    }
    
    private func applyNumberingStyleToAllShots(_ style: ShotNumberingStyle) {
        // Loop through all scenes in the project
        for scene in project.scenes {
            // Loop through all shots in each scene
            for shot in scene.shots {
                // Apply the new numbering style
                shot.numberingStyle = style
            }
        }
    }
}

// MARK: - Custom Label Style

struct TitleAndIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.body)
            configuration.title
                .font(.body)
        }
    }
}

// MARK: - Resizable Divider

struct ResizableDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// When the resized pane sits to the *right* of the divider, dragging left
    /// should make it wider — so the translation is inverted.
    var invertDrag: Bool = false
    /// Called once when the drag ends, so the width can be persisted without
    /// writing to the store on every frame of the drag.
    var onCommit: ((CGFloat) -> Void)? = nil
    
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(isDragging ? 0.3 : 0.2))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8) // Wider hit area for easier dragging
                    .contentShape(Rectangle())
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // MUST be measured in a coordinate space that doesn't move with the
                // divider. In the default `.local` space, widening the column shifts
                // the divider, which changes the reported translation, which resizes
                // again — a feedback loop that makes the drag oscillate.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        // `translation` is cumulative from the start of the drag, so it
                        // must be applied to the width as it was when the drag began —
                        // adding it to the running width compounds and snaps to the limit.
                        if dragStartWidth == nil { dragStartWidth = width }
                        isDragging = true
                        let base = dragStartWidth ?? width
                        let delta = invertDrag ? -value.translation.width : value.translation.width
                        width = min(max(base + delta, minWidth), maxWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartWidth = nil
                        onCommit?(width)
                    }
            )
    }
}

#Preview {
    let project = Project(filmName: "My Film")
    NavigationStack {
        ProjectEditorView(project: project)
    }
    .modelContainer(for: Project.self, inMemory: true)
}
