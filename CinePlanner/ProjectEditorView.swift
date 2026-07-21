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
    @State private var sceneWidth: CGFloat = 300
    @State private var scriptWidth: CGFloat = 420
    @State private var selectedScenes: Set<Scene> = []
    @State private var selectedShots: Set<Shot> = []
    @State private var selectedTab: ProjectTab = .editor

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

    private var selectedScene: Scene? {
        orderedScenes.first { selectedScenes.contains($0) }
    }

    private var selectedShot: Shot? {
        guard let scene = selectedScene else { return nil }
        return scene.shots.sorted { $0.shotNumber < $1.shotNumber }.first { selectedShots.contains($0) }
    }
    
    enum ProjectTab {
        case editor
        case export
    }
    
    var body: some View {
        deletionAlerts(editorAlerts(editorSheets(coreView)))
    }

    private var coreView: some View {
        VStack(spacing: 0) {
            // Content based on selected tab
            Group {
                switch selectedTab {
                case .editor:
                    editorView
                case .export:
                    ExportView(project: project, version: selectedVersion)
                }
            }
        }
        .navigationTitle(project.filmName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Tab Bar in toolbar
                Picker("View", selection: $selectedTab) {
                    Label("Editor", systemImage: "film")
                        .tag(ProjectTab.editor)
                    Label("Shot List", systemImage: "list.bullet.rectangle")
                        .tag(ProjectTab.export)
                }
                .pickerStyle(.segmented)
            }
            
            // Scene/shot actions are only relevant while editing
            if selectedTab == .editor {
                ToolbarItem(placement: .primaryAction) {
                    actionButtons
                }
            }

            // Export is available from both tabs
            ToolbarItem(placement: .primaryAction) {
                exportButton
            }
        }
        .onAppear {
            // Ensure the project has the episode → version structure (migrates legacy projects)
            project.migrateStructureIfNeeded()
            project.lastOpenedDate = Date()

            // Seed the live column widths from the saved values (clamped, so an
            // odd stored value can't make the window wider than the display)
            sceneWidth = min(max(CGFloat(project.sceneColumnWidth), Self.sceneColumnMinWidth), sceneColumnMaxWidth)
            // scriptWidth is derived from the stored fraction once the width is known
            if selectedEpisode == nil {
                selectedEpisode = project.orderedEpisodes.first
            }
            if selectedVersion == nil {
                selectedVersion = selectedEpisode?.orderedVersions.last
            }

            // Select first scene and shot automatically
            if selectedScenes.isEmpty, let firstScene = orderedScenes.first {
                selectedScenes = [firstScene]
                if let firstShot = firstScene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
                    selectedShots = [firstShot]
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
                selectedScenes = [firstScene]
            } else {
                selectedScenes = []
            }
        }
        .onChange(of: selectedScene) { oldScene, newScene in
            // Picking a scene lands on its first shot, so the detail pane always
            // has something to show. Scenes without shots clear the selection.
            guard oldScene !== newScene else { return }
            if let firstShot = newScene?.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
                selectedShots = [firstShot]
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
                Text("Version:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(currentVersions, id: \.persistentModelID) { version in
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
        Menu {
            ForEach(project.orderedEpisodes, id: \.persistentModelID) { episode in
                Button {
                    selectedEpisode = episode
                } label: {
                    if selectedEpisode === episode {
                        Label(episode.title, systemImage: "checkmark")
                    } else {
                        Text(episode.title)
                    }
                }
            }
            Divider()
            Button {
                addEpisode()
            } label: {
                Label("New Episode…", systemImage: "plus")
            }
            Button {
                if let episode = selectedEpisode {
                    renameText = episode.title
                    episodeToRename = episode
                }
            } label: {
                Label("Rename Episode…", systemImage: "pencil")
            }
            .disabled(selectedEpisode == nil)
            Button(role: .destructive) {
                episodePendingDeletion = selectedEpisode
            } label: {
                Label("Delete Episode…", systemImage: "trash")
            }
            .disabled(project.episodes.count <= 1)
        } label: {
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
            }
        }
        .menuStyle(.borderlessButton)
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
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                versionPendingDeletion = version
            } label: {
                Label("Delete Version…", systemImage: "trash")
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
        250 + Self.shotColumnWidth + (Self.paneMinWidth * 2) + Self.dividerAllowance
    }

    private static let shotColumnWidth: CGFloat = 190
    private static let dividerAllowance: CGFloat = 30
    private static let sceneColumnMinWidth: CGFloat = 250

    // Shot details and script split the space left over from the fixed columns
    // evenly, and the divider between them is fixed — there is nothing to drag.
    private static let scriptSplitDefault: CGFloat = 0.5
    /// Hard floor so a very narrow window can't collapse either pane entirely.
    private static let paneMinWidth: CGFloat = 240

    /// Space the details and script panes divide between them.
    private func combinedPaneWidth(available: CGFloat) -> CGFloat {
        max(0, available - sceneWidth - Self.shotColumnWidth - Self.dividerAllowance)
    }

    /// Gives the script pane exactly half of what the pair has to share.
    private func applyScriptSplit(available: CGFloat) {
        let combined = combinedPaneWidth(available: available)
        guard combined > 0 else { return }
        scriptWidth = max(Self.paneMinWidth, combined * Self.scriptSplitDefault)
    }

    /// The widest the scenes column ever usefully needs to be: enough to show the
    /// longest "Scene 12A  Location" title in full. Dragging past this would only
    /// add empty space, so it becomes the divider's maximum.
    private var sceneColumnMaxWidth: CGFloat {
        let titleFont = NSFont.preferredFont(forTextStyle: .headline)
        let nameFont = NSFont.preferredFont(forTextStyle: .subheadline)

        var widest: CGFloat = 0
        for scene in orderedScenes {
            let title = "Scene \(scene.sceneNumber)\(scene.suffix)"
            var width = (title as NSString).size(withAttributes: [.font: titleFont]).width
            let nickname = scene.nickname.trimmingCharacters(in: .whitespaces)
            if !nickname.isEmpty {
                width += 6 + (nickname as NSString).size(withAttributes: [.font: nameFont]).width
            }
            widest = max(widest, width)
        }

        // List row insets + selection chrome + a little breathing room
        let chrome: CGFloat = 46
        return max(Self.sceneColumnMinWidth, ceil(widest) + chrome)
    }

    /// Width the fixed columns may occupy before the flexible panes hit their minimums.
    private func fixedColumnBudget(available: CGFloat) -> CGFloat {
        available - (Self.paneMinWidth * 2) - Self.dividerAllowance
    }

    /// Keeps the stored widths inside what the current window can actually show.
    private func clampColumnWidths(available: CGFloat) {
        guard available > 0 else { return }
        let budget = fixedColumnBudget(available: available)
        guard budget > 0 else { return }
        sceneWidth = min(sceneWidth,
                         max(Self.sceneColumnMinWidth,
                             min(sceneColumnMaxWidth, budget - Self.shotColumnWidth)))
    }

    private var editorColumns: some View {
        GeometryReader { geo in
            editorColumnStack(available: geo.size.width)
                .onAppear {
                    clampColumnWidths(available: geo.size.width)
                    applyScriptSplit(available: geo.size.width)
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    clampColumnWidths(available: newWidth)
                    // Re-derive from the fraction so the split holds as the window resizes.
                    applyScriptSplit(available: newWidth)
                }
                .onChange(of: sceneWidth) { _, _ in
                    // Widening the scenes column changes what the pair has to share.
                    applyScriptSplit(available: geo.size.width)
                }
        }
        .frame(minWidth: minimumEditorWidth, minHeight: 700)
    }

    private func editorColumnStack(available: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Sidebar - Scenes (Resizable width)
            SceneListView(
                project: project,
                version: selectedVersion,
                selectedScenes: $selectedScenes,
                canImportShots: !otherVersionsWithShots.isEmpty,
                onEditScene: { sceneToEdit = $0 },
                onImportShots: { try? modelContext.save(); sceneForShotImport = $0 },
                onDeleteScenes: { pendingSceneDeletion = $0 }
            )
            .frame(width: sceneWidth)
            .clipped()

            // Draggable divider between Scenes and Shots. The maximum is whatever
            // is left after the other panes' minimums, so a drag can never push
            // content outside the window.
            ResizableDivider(
                width: $sceneWidth,
                minWidth: 250,
                maxWidth: max(Self.sceneColumnMinWidth,
                              min(sceneColumnMaxWidth,
                                  fixedColumnBudget(available: available) - Self.shotColumnWidth))
            ) { project.sceneColumnWidth = Double($0) }
            
            // Middle column - Shots (Resizable width)
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
            .frame(width: Self.shotColumnWidth)
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
            .frame(minWidth: Self.paneMinWidth, maxWidth: .infinity)

            // Divider sets the script pane's width (it's to the right, so inverted).
            // Capped so the detail pane always keeps its minimum.
            // Fixed divider: the details and script panes are always equal, so
            // there is nothing to drag here.
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

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
            selectedScenes = [firstScene]
            if let firstShot = firstScene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }).first {
                selectedShots = [firstShot]
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
            selectedShots = [firstShot]
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

// MARK: - Export View

struct ExportView: View {
    @Bindable var project: Project
    let version: ScriptVersion?

    var orderedScenes: [Scene] {
        (version?.scenes ?? project.scenes).sorted { $0.sortOrder < $1.sortOrder }
    }

    private var totalShots: Int {
        orderedScenes.reduce(0) { $0 + $1.shots.count }
    }

    // Fixed row heights keep the frozen column aligned with the scrolling columns
    private static let headerHeight: CGFloat = 40
    private static let sceneRowHeight: CGFloat = 46
    private static let shotRowHeight: CGFloat = 76
    private static let thumbnailHeight: CGFloat = 60
    private static let thumbnailRowSpacing: CGFloat = 6

    /// A shot's row grows with its references, since each gets its own row of
    /// thumbnails. The frozen column uses the same value — if the two halves of
    /// the table disagree by even a point, every row below drifts out of line.
    static func rowHeight(for shot: Shot) -> CGFloat {
        let rows = max(1, shot.orderedReferences.count)
        return CGFloat(rows) * thumbnailHeight
             + CGFloat(rows - 1) * thumbnailRowSpacing
             + (shotRowHeight - thumbnailHeight)   // padding above and below
    }
    private static let frozenColumnWidth: CGFloat = 240

    /// The table flattened into rows, honouring each scene's expanded state.
    private enum ExportRow: Identifiable {
        case scene(Scene)
        case shot(Shot)

        var id: String {
            switch self {
            case .scene(let scene): return "scene-\(scene.persistentModelID.hashValue)"
            case .shot(let shot): return "shot-\(shot.persistentModelID.hashValue)"
            }
        }
    }

    private var rows: [ExportRow] {
        var result: [ExportRow] = []
        for scene in orderedScenes {
            result.append(.scene(scene))
            if scene.isExpandedInExport {
                for shot in scene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }) {
                    result.append(.shot(shot))
                }
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Context header — which film/series, episode, and version this list is for
            contextHeader
            Divider()
            table
        }
    }

    /// Scene/shot numbers stay pinned on the left; the detail columns scroll
    /// horizontally, so a wide shot list never pushes content off-screen.
    private var table: some View {
        GeometryReader { geo in
            tableContent(available: geo.size.width)
        }
    }

    private func tableContent(available: CGFloat) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // Frozen identifier column
                VStack(spacing: 0) {
                    Text("Scene / Shot")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: Self.headerHeight)
                        .background(Color(nsColor: .controlBackgroundColor))
                    Divider()

                    ForEach(rows) { row in
                        frozenCell(row)
                        Divider()
                    }
                }
                .frame(width: Self.frozenColumnWidth)

                Divider()

                // Scrolling detail columns (header scrolls with the rows so they stay aligned)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ExportColumnHeaders(showsShotColumn: false)
                            .frame(height: Self.headerHeight)
                            .background(Color(nsColor: .controlBackgroundColor))
                        Divider()

                        ForEach(rows) { row in
                            dataCell(row)
                            Divider()
                        }
                    }
                    // Fill the window when the columns are narrower than it. Without
                    // this the content sizes to the columns' total, the trailing
                    // Spacer collapses, and the table stops short of the right edge.
                    .frame(minWidth: max(0, available - Self.frozenColumnWidth),
                           alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func frozenCell(_ row: ExportRow) -> some View {
        switch row {
        case .scene(let scene):
            Button {
                scene.isExpandedInExport.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scene.isExpandedInExport ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text(scene.nickname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: Self.sceneRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.08))

        case .shot(let shot):
            HStack(spacing: 6) {
                // Matches the shot icons in the editor tab (default colour, not blue)
                Image(systemName: "camera.circle.fill")
                Text("Shot \(shot.displayNumber)")
                    .font(.body)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
            .padding(.trailing, 12)
            .frame(height: Self.rowHeight(for: shot), alignment: .top)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func dataCell(_ row: ExportRow) -> some View {
        switch row {
        case .scene(let scene):
            SceneHeaderView(scene: scene, showsIdentifier: false)
                .padding(.horizontal, 16)
                .frame(height: Self.sceneRowHeight, alignment: .leading)
                .background(Color.secondary.opacity(0.08))

        case .shot(let shot):
            ShotExportRow(shot: shot, showsIdentifier: false)
                .padding(.horizontal, 16)
                .frame(height: Self.rowHeight(for: shot), alignment: .topLeading)
        }
    }

    private var contextHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: project.isSeries ? "tv" : "film")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(project.filmName)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(project.isSeries ? "Series" : "Film")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                HStack(spacing: 6) {
                    if project.isSeries, let episode = version?.episode {
                        infoPill(icon: "tv", label: episode.title)
                    }
                    if let version {
                        infoPill(icon: "doc.text.magnifyingglass", label: version.name)
                    }
                    Text("\(orderedScenes.count) scene\(orderedScenes.count == 1 ? "" : "s") · \(totalShots) shot\(totalShots == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func infoPill(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Scene Disclosure Group

// MARK: - Export Column Headers

struct ExportColumnHeaders: View {
    /// The Shot column lives in the frozen left column of the table
    var showsShotColumn: Bool = true

    var body: some View {
        HStack(spacing: 16) {
            // Shot number header (includes icon space)
            if showsShotColumn {
                Text("Shot")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 106, alignment: .leading) // 20 (icon) + 6 (spacing) + 80 = 106
            }

            // Nickname header
            Text("Nickname")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            
            // Size header
            Text("Size")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            
            // Type header
            Text("Type")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            
            // Focal Length header
            Text("Focal Length")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            
            // Grip header
            Text("Grip")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            
            // Camera header
            Text("Camera")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            
            // Format header
            Text("Format")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            
            // Lens Preset header
            Text("Lens Preset")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(minWidth: 100, maxWidth: 200, alignment: .leading)
            
            // Extra Info header
            Text("Extra Info")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            
            // Coverage header
            Text("Coverage")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)
            
            Spacer()
            
            // Photos header
            HStack(spacing: 12) {
                Text("Ref")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .center)
                
                Text("Map")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .center)
            }
            .frame(width: 172)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Scene Header View

struct SceneHeaderView: View {
    let scene: Scene
    /// Scene number/name live in the frozen left column of the table
    var showsIdentifier: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if showsIdentifier {
                Image(systemName: "moonphase.full.moon")
                    .foregroundStyle(.blue)

                // Scene number and nickname
                HStack(spacing: 6) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.headline)
                        .fontWeight(.bold)

                    if !scene.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("-")
                            .font(.headline)
                        Text(scene.nickname)
                            .font(.headline)
                    }
                }
            }

            Spacer()

            // Tags: INT/EXT and DAY/NIGHT
            HStack(spacing: 6) {
                // INT/EXT is neutral; DAY/NIGHT carries the colour
                Text(scene.isInterior ? "INT" : "EXT")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(scene.isDay ? "DAY" : "NIGHT")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((scene.isDay ? Color.blue : Color.orange).opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                
                Text("\(scene.shots.count) shots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shot Export Row

struct ShotExportRow: View {
    let shot: Shot
    /// The shot number lives in the frozen left column of the table
    var showsIdentifier: Bool = true
    @State private var previewImage: NSImage?
    @State private var previewTitle = ""
    
    
    // Helper function to format coverage summary
    private func formatCoverageSummary(_ selection: ScriptTextSelection) -> String {
        let pageRange = formatPageRange(selection)
        
        guard let fullText = selection.fullText, !fullText.isEmpty else {
            return pageRange
        }
        
        // Split text into words and clean up
        let words = fullText.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else {
            return pageRange
        }
        
        // Format the summary
        let textSummary: String
        if words.count <= 3 {
            // If 3 or fewer words, just show them all
            textSummary = words.joined(separator: " ")
        } else if words.count <= 6 {
            // If 4-6 words, show all without ellipsis
            textSummary = words.joined(separator: " ")
        } else {
            // Show first 3 ... last 3
            let firstThree = words.prefix(3).joined(separator: " ")
            let lastThree = words.suffix(3).joined(separator: " ")
            textSummary = "\(firstThree)...\(lastThree)"
        }
        
        return "\(textSummary) \(pageRange)"
    }
    
    // Helper function to format page range
    private func formatPageRange(_ selection: ScriptTextSelection) -> String {
        // Get the PDF page offset from the project
        guard let scene = shot.scene,
              let project = scene.project else {
            // Fallback to simple 1-based indexing if no project context
            let pages = selection.pageRanges.map { $0.pageIndex + 1 }.sorted()
            guard !pages.isEmpty else { return "" }

            if pages.count == 1 {
                return "(P\(pages[0]))"
            } else {
                return "(P\(pages.first!) - P\(pages.last!))"
            }
        }

        let pdfPageOffset = project.resolvedPDFPageOffset
        
        // Convert PDF page indices to script page numbers
        let scriptPages = selection.pageRanges.map { pageRange in
            // Script page = (PDF page index - offset) + 1
            return (pageRange.pageIndex - pdfPageOffset) + 1
        }.sorted()
        
        guard !scriptPages.isEmpty else {
            return ""
        }
        
        if scriptPages.count == 1 {
            return "(P\(scriptPages[0]))"
        } else {
            let firstPage = scriptPages.first!
            let lastPage = scriptPages.last!
            return "(P\(firstPage) - P\(lastPage))"
        }
    }
    

    /// Thumbnail(s) for one reference: its media, plus its map when it has one.
    @ViewBuilder
    private func referenceThumbnails(_ reference: ShotReference, index: Int) -> some View {
        HStack(spacing: 6) {
            thumbnail(data: reference.imageData,
                      placeholder: reference.isVideo ? "video" : "photo",
                      accent: Color.blue.opacity(0.6),
                      label: shot.references.count > 1 ? "Ref \(index)" : "Reference") {
                previewImage = reference.imageData.flatMap { NSImage(data: $0) }
                previewTitle = shot.references.count > 1 ? "Reference \(index)" : "Reference"
            }
            if reference.mapData != nil {
                thumbnail(data: reference.mapData,
                          placeholder: "map",
                          accent: Color.purple.opacity(0.6),
                          label: "Map") {
                    previewImage = reference.mapData.flatMap { NSImage(data: $0) }
                    previewTitle = "Top Down Map"
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(data: Data?, placeholder: String, accent: Color,
                           label: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            if let data, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent, lineWidth: 2))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 80, height: 60)
                    .overlay(Image(systemName: placeholder).font(.title3).foregroundStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .disabled(data == nil)
        .help(data == nil ? "No \(label)" : "Click to preview \(label)")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Shot number with icon
            if showsIdentifier {
                HStack(spacing: 6) {
                    Image(systemName: "camera.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.body)

                    Text("Shot \(shot.displayNumber)")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(width: 80, alignment: .leading)
                }
            }

            // Nickname
            if !shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(shot.nickname)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 120, alignment: .leading)
            }
            
            // Size
            if shot.size != .none {
                HStack(spacing: 3) {
                    Text(shot.size.shortVersion)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    // Show arrow and second size if it exists
                    if shot.secondSize != .none {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(shot.secondSize.shortVersion)
                            .font(.body)
                            .fontWeight(.medium)
                    }
                }
                .frame(width: 80, alignment: .leading)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .leading)
            }
            
            // Type Category
            if shot.typeCategory != .none {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(shot.typeCategory.shortDisplayName)
                            .font(.body)
                            .fontWeight(.medium)
                        
                        if shot.secondTypeCategory != .none {
                            Text("+ \(shot.secondTypeCategory.shortDisplayName)")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                        
                        if shot.thirdTypeCategory != .none && shot.secondTypeCategory != .none {
                            // If we have all three types, put the third on a new line
                            Spacer()
                        }
                    }
                    
                    if shot.thirdTypeCategory != .none && shot.secondTypeCategory != .none {
                        HStack(spacing: 4) {
                            Text("+ \(shot.thirdTypeCategory.shortDisplayName)")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                    } else if shot.thirdTypeCategory != .none {
                        // If only first and third type (no second), show third inline
                        HStack(spacing: 4) {
                            Text("+ \(shot.thirdTypeCategory.shortDisplayName)")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                    }
                }
                .frame(width: 150, alignment: .leading)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 150, alignment: .leading)
            }
            
            // Focal Length
            if shot.lensfocal > 0 {
                if shot.lensIsPrime {
                    Text("\(shot.lensfocal)mm")
                        .font(.body)
                        .fontWeight(.medium)
                        .frame(width: 80, alignment: .leading)
                } else {
                    Text("\(shot.lensfocal)→\(shot.lensfocalEnd)mm")
                        .font(.body)
                        .fontWeight(.medium)
                        .frame(width: 80, alignment: .leading)
                }
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .leading)
            }
            
            // Grip Type
            if shot.type != .none {
                Text(shot.type.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 90, alignment: .leading)
            }
            
            // Camera
            if !shot.camera.isEmpty {
                Text(shot.camera)
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 120, alignment: .leading)
            }
            
            // Format
            if !shot.format.isEmpty {
                Text(shot.format)
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(width: 100, alignment: .leading)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 100, alignment: .leading)
            }
            
            // Lens Preset
            if !shot.lensPreset.isEmpty {
                Text(shot.lensPreset)
                    .font(.body)
                    .fontWeight(.medium)
                    .frame(minWidth: 100, maxWidth: 200, alignment: .leading)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 100, maxWidth: 200, alignment: .leading)
            }
            
            // Extra Info
            if !shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(shot.extraInfo)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 150, alignment: .leading)
            }
            
            // Coverage
            if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(selections) { selection in
                        Text(formatCoverageSummary(selection))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(width: 300, alignment: .leading)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(width: 300, alignment: .leading)
            }
            
            Spacer()
            
            // Photo thumbnails
            // Each reference is its own row — its media and map side by side —
            // with the next reference beneath, matching the web export.
            VStack(alignment: .leading, spacing: 6) {
                if shot.orderedReferences.isEmpty {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 80, height: 60)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        )
                } else {
                    ForEach(Array(shot.orderedReferences.enumerated()), id: \.element.persistentModelID) { index, reference in
                        referenceThumbnails(reference, index: index + 1)
                    }
                }
            }
            .frame(minWidth: 172, alignment: .topLeading)
        }
        .padding(.vertical, 8)
        .sheet(item: Binding(get: { previewImage.map { ImagePreview(image: $0, title: previewTitle) } },
                             set: { if $0 == nil { previewImage = nil } })) { preview in
            ImagePreviewSheet(preview: preview)
        }
    }
}

// MARK: - Photo Preview Sheet

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
