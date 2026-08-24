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
    /// iPhone collapses the multi-column editor into a single-column drill-down.
    /// iPad (any size) and Mac keep the columns unchanged.
    private var isPhoneLayout: Bool { DeviceLayout.isPhone }
    /// iPhone: presents the script PDF full-screen (no room for a side-by-side pane).
    @State private var showScriptSheet = false
    /// iPhone: the shot whose script lines are being marked in the full-screen
    /// script cover (set when its "Mark Text" opens the script), else nil.
    @State private var coverageMarkingShot: Shot?
    /// iPhone: true while the script cover is in text-selection mode, so it shows
    /// Done/Cancel instead of a plain close button.
    @State private var isCoverageMarkingInSheet = false
    /// iPhone two-tap marking: false while picking the first word, true for the last.
    @State private var coverageMarkLastPhase = false
    /// iPhone landscape 30/70 split is active — the detail tabs move into the toolbar.
    @State private var isLandscapeSplit = false
    /// The shooting-schedule board sheet.
    @State private var showScheduleSheet = false

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

    /// Which view fills the flexible detail pane on the right. `.script` is an
    /// iPhone-only tab (iPad shows the script in its own column).
    private enum DetailTab: Hashable { case shot, map, script }
    @State private var detailTab: DetailTab = .shot

    // Edit / delete targets (driven by right-click context menus on rows)
    @State private var sceneToEdit: Scene?
    @State private var shotToEdit: Shot?
    @State private var pendingSceneDeletion: [Scene] = []
    @State private var pendingShotDeletion: [Shot] = []

    // Episodes & script versioning
    /// The scene whose script page the user is currently placing in the PDF, if any.
    @State private var sceneBeingMarked: Scene?
    @State private var selectedEpisode: Episode?
    @State private var selectedVersion: ScriptVersion?
    @State private var showCopyShotsPrompt = false
    @State private var showTransferSheet = false
    @State private var requestScriptImport = false
    // iPhone: the script settings gear lives beside the tabs, so the editor owns the
    // coverage-margin state (passed down for a live preview) and forces a PDF reload
    // when the script is deleted from here.
    @State private var scriptCoverageMargin: Double = 0.15
    @State private var showScriptMarginSheet = false
    @State private var scriptReloadToken = 0
    @State private var showExportSheet = false
    @State private var showPublishSheet = false
    @State private var showingDeletePageConfirm = false
    @State private var isDeletingPage = false
    @State private var deletePageError: String?
    @State private var isUpdatingPage = false
    @State private var updatePageError: String?
    @State private var pageIsLive = false

    private var publishedURL: String? { project.publishedPagesURL }
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

    /// Whether a script PDF exists to place scenes against.
    private var hasScriptPDF: Bool {
        (selectedVersion?.pdfData ?? project.scriptPDFData) != nil
    }

    /// Records the page the user scrolled to as the scene's script page. The stored
    /// value is scene-relative (offset from the first scene's page), matching how
    /// `Scene.absolutePDFPage` reconstructs it.
    private func finishMarkingScenePage(atPageIndex pageIndex: Int) {
        defer { sceneBeingMarked = nil }
        guard let scene = sceneBeingMarked else { return }
        let offset = selectedVersion?.pdfPageOffset ?? project.resolvedPDFPageOffset
        scene.scriptPageNumber = max(1, pageIndex - offset + 1)
        try? modelContext.save()
    }
    
    var body: some View {
        deletionAlerts(editorAlerts(editorSheets(coreView)))
    }

    private var coreView: some View {
        editorView
        #if os(iOS)
        // iPad: inline title centered in the toolbar row. iPhone shows the project
        // name in its own content header instead, so the bar title is left empty.
        .navigationTitle(isPhoneLayout ? "" : project.filmName)
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS: no navigationTitle (which would also show at the leading edge next
        // to the back button); the centered title comes from the principal item below.
        .navigationTitle("")
        #endif
        .toolbar {
            #if os(macOS)
            // Centre the project name in the toolbar row, matching iPad's inline title.
            if #available(macOS 26.0, *) {
                // Hide the macOS 26 "Liquid Glass" pill so it reads as a plain title.
                ToolbarItem(placement: .principal) {
                    Text(project.filmName).font(.headline)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    Text(project.filmName).font(.headline)
                }
            }
            #endif

            #if os(iOS)
            // iPhone: the project name sits next to the back chevron. Hide the OS 26
            // "Liquid Glass" toolbar pill so it reads as plain text, not a chip.
            if isPhoneLayout {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(project.filmName).font(.headline).lineLimit(1).fixedSize()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(project.filmName).font(.headline).lineLimit(1).fixedSize()
                    }
                }
            }
            #endif

            #if os(iOS)
            // iPhone landscape split: the detail tabs ride the toolbar row, between
            // the project name and the GitHub/Export buttons.
            if isPhoneLayout && isLandscapeSplit {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .principal) { detailTabPill }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { detailTabPill }
                }
            }
            #endif

            ToolbarItem(placement: .primaryAction) {
                actionButtons
            }

            #if os(iOS)
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { scheduleButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { scheduleButton }
            }
            #else
            ToolbarItem(placement: .primaryAction) { scheduleButton }
            #endif

            // GitHub + Export share the toolbar row with the project name. iPhone
            // keeps its always-visible GitHub button (publish when unpublished, the
            // page menu once live) plus Export; the Script button and version chips
            // stay in the content header below. iPad/Mac use their export group.
            // Hide the OS 26 "Liquid Glass" pill so the badges keep their own look.
            #if os(iOS)
            if isPhoneLayout {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { headerButtons }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { headerButtons }
                }
            }
            #endif
            if !isPhoneLayout {
                if #available(iOS 26.0, macOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { exportToolbarGroup }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { exportToolbarGroup }
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
            scriptCoverageMargin = selectedVersion?.coverageLineMargin ?? 0.15

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
            scriptCoverageMargin = selectedVersion?.coverageLineMargin ?? 0.15
            selectedShots = []
            if let firstScene = orderedScenes.first {
                selectedScenes = [firstScene.uid]
            } else {
                selectedScenes = []
            }
        }
        .onChange(of: orderedScenes.count) {
            // Scenes appearing while nothing is selected — a script finished
            // importing into a new project/version (which imports asynchronously,
            // after the editor is already on screen). Land on Scene 1 so it never
            // sits on "No Scene Selected"; its first shot follows via the uid watcher.
            if selectedScenes.isEmpty, let firstScene = orderedScenes.first {
                selectedScenes = [firstScene.uid]
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
        #if os(iOS)
        // iPhone script pane, presented full-screen. Opens automatically when a new
        // scene needs its script page placed, or when a shot's "Mark Text" fires —
        // the PDF isn't otherwise on screen to select text in.
        .onChange(of: sceneBeingMarked) { _, marking in
            if isPhoneLayout, marking != nil { showScriptSheet = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startScriptTextSelection)) { note in
            // Intercept only when the script isn't open yet; once it is, the mounted
            // PDF view handles the (re-posted) notification itself.
            guard isPhoneLayout, !showScriptSheet else { return }
            coverageMarkingShot = note.userInfo?["shot"] as? Shot
            showScriptSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .scriptSelectionModeChanged)) { note in
            guard isPhoneLayout else { return }
            let active = note.userInfo?["active"] as? Bool ?? false
            isCoverageMarkingInSheet = active
            if active { coverageMarkLastPhase = false }
            // The coverage session ended (Done captured a selection, or Cancel) —
            // close the script and return to the shot.
            if !active, coverageMarkingShot != nil {
                coverageMarkingShot = nil
                showScriptSheet = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scriptSelectionPhaseChanged)) { note in
            guard isPhoneLayout else { return }
            coverageMarkLastPhase = (note.userInfo?["phase"] as? Int ?? 0) == 1
        }
        .fullScreenCover(isPresented: $showScriptSheet,
                         onDismiss: { coverageMarkingShot = nil; isCoverageMarkingInSheet = false }) {
            NavigationStack {
                ScriptPDFViewer(
                    project: project,
                    version: selectedVersion,
                    selectedScenePage: selectedScene?.absolutePDFPage,
                    selectedScene: selectedScene,
                    selectedShot: selectedShot,
                    onScenesImported: { _ in
                        // iPhone imported into a new version via this sheet: close it so
                        // the fresh scenes and the copy-shots prompt (an alert on the
                        // editor) are visible.
                        showScriptSheet = false
                        if !otherVersionsWithShots.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                showCopyShotsPrompt = true
                            }
                        }
                    },
                    requestImport: $requestScriptImport,
                    isMarkingScenePage: sceneBeingMarked != nil,
                    markingSceneLabel: sceneBeingMarked.map { "\($0.sceneNumber)\($0.suffix)" } ?? "",
                    onFinishMarking: {
                        finishMarkingScenePage(atPageIndex: $0)
                        showScriptSheet = false
                    },
                    onCancelMarking: { sceneBeingMarked = nil }
                )
                .navigationTitle(coverageMarkingShot != nil
                                 ? (coverageMarkLastPhase ? "Tap the Last Word" : "Tap the First Word")
                                 : (sceneBeingMarked != nil ? "Place Scene Page" : "Script"))
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    // Begin selection once the PDF is mounted and scrolled to the page.
                    if let shot = coverageMarkingShot {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NotificationCenter.default.post(name: .startScriptTextSelection,
                                                            object: nil, userInfo: ["shot": shot])
                        }
                    }
                }
                .toolbar {
                    if isCoverageMarkingInSheet {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                NotificationCenter.default.post(name: .cancelScriptSelection, object: nil)
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(coverageMarkLastPhase ? "Done" : "Next") {
                                NotificationCenter.default.post(name: .captureScriptSelection, object: nil)
                            }
                        }
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showScriptSheet = false
                                sceneBeingMarked = nil
                            }
                        }
                    }
                }
            }
        }
        #endif
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
        .sheet(isPresented: $showScheduleSheet) {
            if let version = selectedVersion {
                ShootingScheduleView(project: project, version: version)
            }
        }
        .sheet(isPresented: $showScriptMarginSheet) {
            scriptMarginSheet
                #if os(iOS)
                .presentationDetents([.height(300)])
                #endif
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
        .alert("Couldn't update the page", isPresented: Binding(
            get: { updatePageError != nil }, set: { if !$0 { updatePageError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(updatePageError ?? "")
        }
    }

    /// Small round GitHub button next to Export — opens/updates/deletes the online page.
    private func publishedPageMenu(url: String, arrowEdge: Edge = .bottom) -> some View {
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

    /// Re-publishes the web page in place using the saved repo + token — no sheet.
    /// Falls back to the publish sheet if the token or repo isn't available.
    private func updatePublishedPage() {
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
                let siteDir = try await exporter.buildSiteDirectory()
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
    private func checkPageLive(_ urlString: String) async {
        guard let url = URL(string: urlString) else { pageIsLive = false; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let response = try? await URLSession.shared.data(for: request)
        let code = (response?.1 as? HTTPURLResponse)?.statusCode ?? 0
        pageIsLive = (200..<400).contains(code)
    }

    private func deletePublishedPage() {
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
            // iPhone builds its own header (title + buttons + versions) inside
            // compactColumns; iPad/Mac keep the shared context bar here.
            if !isPhoneLayout {
                contextBar
                Divider()
            }
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
        .background(Color.platformControlBackground)
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
            ],
            // Opens below the button — it sits near the top of the window, so there's
            // little room above for the popover.
            arrowEdge: .top
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
                // iPhone keeps the chips compact — the per-version shot count is dropped.
                if !DeviceLayout.isPhone, version.totalShotCount > 0 {
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
    /// Shared height for the detail tab header and the script pane header.
    static let paneHeaderHeight: CGFloat = 44

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

    @ViewBuilder
    private var editorColumns: some View {
        if isPhoneLayout {
            compactColumns
        } else {
            regularColumns
        }
    }

    /// iPad + Mac: the resizable multi-column layout (unchanged).
    private var regularColumns: some View {
        GeometryReader { geo in
            // On iPad in portrait there isn't room for three columns, so the script
            // pane is hidden — leaving Scenes and Shots/Scene Map. macOS always
            // shows it.
            #if os(iOS)
            let showScript = geo.size.width >= geo.size.height
            #else
            let showScript = true
            #endif
            editorColumnStack(available: geo.size.width, showScript: showScript)
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
        #if os(macOS)
        // Keep the macOS window from shrinking below what the columns need. On iPad
        // the editor sizes to the screen instead (forcing this width would overflow
        // a portrait iPad and leave the divider no room to move).
        .frame(minWidth: minimumEditorWidth, minHeight: 700)
        #endif
    }

    // MARK: - iPhone (compact) single-column drill-down

    /// iPhone: the scenes list is the root; tapping a scene pushes its shots/map,
    /// tapping a shot pushes the shot detail. The scene/shot rows are already
    /// `NavigationLink(value:)`, so these destinations (added only in compact
    /// width) turn them into pushes — leaving iPad/Mac, which never attach them,
    /// on the existing selection-driven columns.
    @ViewBuilder
    private var compactColumns: some View {
        GeometryReader { geo in
            // Landscape iPhone: a 30/70 split — scenes on the left, the selected
            // scene's full 3-tab page (Shots / Scene Map / Script) on the right. The
            // versions row is hidden here to reclaim vertical space.
            let split = geo.size.width > geo.size.height
            let leftWidth = geo.size.width * 0.3
            VStack(spacing: 0) {
                if split {
                    // The 3 tabs move up into the toolbar row (see isLandscapeSplit);
                    // here we just show the two panes.
                    HStack(spacing: 0) {
                        compactSceneList(selectsInPlace: true)
                            .frame(width: leftWidth)
                        Divider()
                        Group {
                            if let scene = selectedScene ?? orderedScenes.first {
                                compactSceneTabContent(scene)
                            } else {
                                ContentUnavailableView("No Scenes", systemImage: "film")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // Let the panes run to the physical bottom (under the home
                    // indicator) so the map isn't cut short by the safe-area inset.
                    .ignoresSafeArea(.container, edges: .bottom)
                } else {
                    compactEditorHeader
                    Divider()
                    compactSceneList(selectsInPlace: false)
                }
            }
            .onAppear { isLandscapeSplit = split }
            .onChange(of: split) { _, now in isLandscapeSplit = now }
        }
        .navigationDestination(for: Scene.self) { scene in
            compactSceneScreen(scene)
        }
        .navigationDestination(for: Shot.self) { shot in
            ShotDetailView(shot: shot)
                .navigationTitle("Shot \(shot.displayNumber)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .onAppear { selectedShots = [shot.uid] }
        }
    }

    /// The iPhone scenes list. `selectsInPlace` (landscape split) makes a tap select
    /// the scene for the right-hand script pane instead of pushing its detail.
    private func compactSceneList(selectsInPlace: Bool) -> some View {
        SceneListView(
            project: project,
            version: selectedVersion,
            selectedScenes: $selectedScenes,
            canImportShots: !otherVersionsWithShots.isEmpty,
            onEditScene: { sceneToEdit = $0 },
            onImportShots: { try? modelContext.save(); sceneForShotImport = $0 },
            onDeleteScenes: { pendingSceneDeletion = $0 },
            onSceneAdded: { scene in if hasScriptPDF { sceneBeingMarked = scene } },
            onSelectScene: selectsInPlace ? { _ in } : nil
        )
    }

    /// The 3-tab scene content (Shots / Scene Map / Script), without navigation
    /// chrome — shared by the pushed scene screen and the landscape split's right
    /// pane.
    private func compactSceneDetail(_ scene: Scene) -> some View {
        VStack(spacing: 0) {
            detailTabBar
            Divider()
            compactSceneTabContent(scene)
        }
    }

    /// Just the selected tab's content (no tab bar) — the landscape split shows the
    /// tab bar in its own top row instead.
    @ViewBuilder
    private func compactSceneTabContent(_ scene: Scene) -> some View {
        Group {
            switch detailTab {
            case .shot:
                ShotListView(
                    scene: scene,
                    selectedShots: $selectedShots,
                    onEditShot: { shotToEdit = $0 },
                    onDeleteShots: { pendingShotDeletion = $0 }
                )
            case .map:
                SceneMapEditorView(scene: scene, embedded: true)
                    .id(scene.uid)
            case .script:
                compactScriptView(for: scene)
            }
        }
        // Breathing room under the local tab bar; none in the landscape split, where
        // the tabs are in the toolbar and the space would just sit above the content.
        .padding(.top, isLandscapeSplit ? 0 : 10)
    }

    /// A scene's screen on iPhone: the Shots list and the Scene Map, toggled by the
    /// same tab control the wide layout uses. Shot rows push the shot detail.
    private func compactSceneScreen(_ scene: Scene) -> some View {
        compactSceneDetail(scene)
        .navigationTitle("Scene \(scene.sceneNumber)\(scene.suffix)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // A larger centered title than the default inline size.
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)").font(.title2.bold())
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)").font(.title2.bold())
                }
            }
        }
        #endif
        // Keep the selection in step with the drill-down, so the script page and
        // shot detail resolve to this scene.
        .onAppear { selectedScenes = [scene.uid] }
    }

    /// iPhone Script tab: the script PDF, opened at this scene's page (view only —
    /// coverage marking still goes through the full-screen cover from a shot).
    private func compactScriptView(for scene: Scene) -> some View {
        ScriptPDFViewer(
            project: project,
            version: selectedVersion,
            selectedScenePage: scene.absolutePDFPage,
            selectedScene: scene,
            selectedShot: selectedShot,
            onScenesImported: { _ in
                if !otherVersionsWithShots.isEmpty { showCopyShotsPrompt = true }
            },
            requestImport: $requestScriptImport,
            isMarkingScenePage: false,
            markingSceneLabel: "",
            onFinishMarking: { _ in },
            onCancelMarking: { },
            coverageMarginOverride: scriptCoverageMargin
        )
        .id(scriptReloadToken)
    }

    /// iPhone header for the scenes screen: the Script button + version chips.
    /// GitHub and Export live in the toolbar row (with the project name).
    private var compactEditorHeader: some View {
        headerVersions
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// GitHub + Export, shown in the iPhone toolbar row.
    private var headerButtons: some View {
        HStack(spacing: 8) {
            gitHubHeaderButton
            exportButton
        }
    }

    /// The episode menu (series) and "Script Version:" label stay put; only the
    /// version chips scroll.
    private var headerVersions: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Version:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            if project.isSeries {
                episodeMenu
                Divider().frame(height: 18)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(currentVersions, id: \.uid) { versionTab(for: $0) }
                    Button { addNewVersion() } label: {
                        Label("New Version", systemImage: "plus").font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    /// GitHub control for the iPhone header: the published-page menu when the
    /// project is live, otherwise a button that starts publishing.
    @ViewBuilder
    private var gitHubHeaderButton: some View {
        if let url = publishedURL {
            // iPhone header sits at the top of the screen, so open the menu below
            // the button (.top arrow) — above it there's no room for all the rows.
            publishedPageMenu(url: url, arrowEdge: .top)
        } else {
            Button { showPublishSheet = true } label: {
                Image("GitHubLogo")
                    .resizable().scaledToFit()
                    .frame(width: 19, height: 19)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Publish this shot list to the web through your GitHub account")
        }
    }

    private func editorColumnStack(available: CGFloat, showScript: Bool) -> some View {
        HStack(spacing: 0) {
            // Sidebar - Scenes (fixed width, matching the shots column)
            SceneListView(
                project: project,
                version: selectedVersion,
                selectedScenes: $selectedScenes,
                canImportShots: !otherVersionsWithShots.isEmpty,
                onEditScene: { sceneToEdit = $0 },
                onImportShots: { try? modelContext.save(); sceneForShotImport = $0 },
                onDeleteScenes: { pendingSceneDeletion = $0 },
                onSceneAdded: { scene in
                    // With a script loaded, let the user place the scene's page by
                    // scrolling the PDF; otherwise the scene is just added.
                    if hasScriptPDF { sceneBeingMarked = scene }
                }
            )
            .frame(width: Self.sideColumnWidth)
            .clipped()

            Divider()

            // Shots + Detail share one tab header that spans both. The Shots
            // column is hidden on the Scene Map tab so the map gets its space.
            VStack(spacing: 0) {
                detailTabBar
                Divider()
                HStack(spacing: 0) {
                    if detailTab != .map {
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
                        .frame(width: Self.sideColumnWidth)
                        .clipped()

                        Divider()
                    }

                    Group {
                        if let scene = selectedScene {
                            detailContent(for: scene)
                        } else {
                            ContentUnavailableView(
                                "No Scene Selected",
                                systemImage: "film",
                                description: Text("Select a scene from the sidebar or create a new one")
                            )
                        }
                    }
                    .frame(minWidth: Self.detailPaneMinWidth, maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)

            if showScript {
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
                    requestImport: $requestScriptImport,
                    isMarkingScenePage: sceneBeingMarked != nil,
                    markingSceneLabel: sceneBeingMarked.map { "\($0.sceneNumber)\($0.suffix)" } ?? "",
                    onFinishMarking: { finishMarkingScenePage(atPageIndex: $0) },
                    onCancelMarking: { sceneBeingMarked = nil }
                )
                .frame(minWidth: Self.paneMinWidth, idealWidth: scriptWidth, maxWidth: scriptWidth)
                .clipped()
            }
        }
    }

    /// The flexible right pane, tabbed between the selected shot's details and
    /// the scene-level top-down map.
    /// The tab header (Shot Details / Scene Map), spanning the shots + detail
    /// region so it sits above both.
    /// The tab pill itself (Shots / Scene Map / Script), without surrounding spacers —
    /// reused in the iPhone landscape toolbar's principal slot.
    private var detailTabPill: some View {
        HStack(spacing: 4) {
            tabButton("Shots", .shot)
            tabButton("Scene Map", .map)
            // iPhone: the script lives in a tab here (iPad has its own column).
            if isPhoneLayout { tabButton("Script", .script) }
        }
        .padding(3)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
    }

    private var detailTabBar: some View {
        HStack {
            Spacer(minLength: 0)
            detailTabPill
            Spacer(minLength: 0)
        }
        .frame(height: isPhoneLayout ? 38 : Self.paneHeaderHeight)
        // iPhone: the script settings gear rides the trailing edge, so the tab pill
        // stays centred on the page.
        .overlay(alignment: .trailing) {
            if isPhoneLayout && detailTab == .script && hasScriptPDF {
                scriptTabGear.padding(.trailing, 8)
            }
        }
    }

    /// iPhone: the script settings menu shown next to the Script tab — replace the
    /// script, delete it, or set the coverage margin. Mirrors the gear the wide
    /// layouts show in the script pane header.
    private var scriptTabGear: some View {
        Menu {
            Button {
                requestScriptImport = true
            } label: {
                Label("Replace Script…", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                scriptCoverageMargin = selectedVersion?.coverageLineMargin ?? 0.15
                showScriptMarginSheet = true
            } label: {
                Label("Set Coverage Margin…", systemImage: "arrow.left.and.right")
            }
            Divider()
            Button(role: .destructive) {
                deleteScriptFromEditor()
            } label: {
                Label("Delete Script", systemImage: "trash")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 32)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
        }
        .menuIndicator(.hidden)
    }

    /// iPhone: clear the current version's script PDF and force the viewer to reset
    /// to its empty state (the viewer caches its document, so bump its reload id).
    private func deleteScriptFromEditor() {
        selectedVersion?.pdfData = nil
        project.scriptPDFData = nil
        try? modelContext.save()
        scriptReloadToken += 1
    }

    /// iPhone: adjust how far the coverage lines sit from the script text. The value
    /// feeds the live PDF preview via `scriptCoverageMargin` and is saved to the version.
    private var scriptMarginSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Coverage Margin")
                    .font(.title3).fontWeight(.semibold)
                Text("Move the coverage lines closer to or further from the script text, to match this script's left margin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Slider(value: $scriptCoverageMargin, in: 0.05...0.35)
                    .onChange(of: scriptCoverageMargin) { _, new in
                        selectedVersion?.coverageLineMargin = new
                    }
                Image(systemName: "text.alignright").foregroundStyle(.secondary)
            }

            Text("\(Int((scriptCoverageMargin * 100).rounded()))% of page width")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset") {
                    scriptCoverageMargin = 0.15
                    selectedVersion?.coverageLineMargin = 0.15
                }
                Spacer()
                Button("Done") {
                    try? modelContext.save()
                    showScriptMarginSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }

    private func tabButton(_ title: String, _ tab: DetailTab) -> some View {
        let isSelected = detailTab == tab
        return Button { detailTab = tab } label: {
            Text(title)
                .font(isPhoneLayout ? .subheadline.bold() : .title3.bold())
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, isPhoneLayout ? 12 : 18)
                .padding(.vertical, isPhoneLayout ? 4 : 6)
                .background(isSelected ? Color.platformControlBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailContent(for scene: Scene) -> some View {
        switch detailTab {
        // `.script` is iPhone-only; the iPad detail pane never selects it, but the
        // switch must stay exhaustive, so it falls back to the shot detail.
        case .shot, .script:
            if let shot = selectedShot {
                ShotDetailView(shot: shot)
            } else {
                ContentUnavailableView {
                    Text("No Shot Selected").font(.headline)
                } description: {
                    Text("Select a shot to view its details")
                }
            }
        case .map:
            // Keyed by scene so switching scenes reloads the map document.
            SceneMapEditorView(scene: scene, embedded: true)
                .id(scene.uid)
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
        modelContext.destructiveDelete {
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
        }
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
        // Prompt to import the new script right away.
        requestScriptImport = true
        #if os(iOS)
        // iPhone has no always-on script pane to catch requestScriptImport, so open
        // the script sheet — its ScriptPDFViewer consumes the pending flag on appear
        // and shows the import prompt (auto-detect scenes, then copy shots).
        if DeviceLayout.isPhone { showScriptSheet = true }
        #endif
    }

    private func deleteVersion(_ version: ScriptVersion) {
        // Move the selection off this version FIRST, so no editor view is still
        // bound to one of its scenes when we delete them — otherwise a view holding
        // a now-deleted Scene traps with "this model instance was invalidated".
        if selectedVersion === version {
            selectedShots = []
            selectedScenes = []
            selectedVersion = selectedEpisode?.orderedVersions.first(where: { $0 !== version })
        }

        // Delete on the next runloop tick, after SwiftUI has re-rendered onto the
        // newly-selected version and released the old scenes.
        let context = modelContext
        DispatchQueue.main.async {
            context.destructiveDelete {
                // A Scene is cascade-reachable from BOTH its Project and its
                // ScriptVersion. Sever only the (legacy) Project link so the version
                // is the sole owner, then delete the version and let SwiftData's
                // cascade remove its scenes (and their shots) exactly once. Deleting
                // the scenes by hand as well double-deletes them — the version's
                // cascade still targets them, because severing `scene.scriptVersion`
                // doesn't synchronously empty `version.scenesStore` — and trips an
                // assertion.
                for scene in version.scenes {
                    scene.project = nil
                }
                context.delete(version)
            }
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
    
    /// The GitHub published-page indicator (when published) plus the Export button.
    @ViewBuilder
    private var exportToolbarGroup: some View {
        HStack(spacing: 8) {
            if let url = publishedURL {
                publishedPageMenu(url: url)
            }
            exportButton
        }
    }

    /// Primary export action — an accent capsule matching the version tabs
    /// and the chips used elsewhere in the app.
    private var exportButton: some View {
        Button {
            showExportSheet = true
        } label: {
            if isPhoneLayout {
                // iPhone: an icon-only accent circle (matching the GitHub button) to
                // save room in the toolbar row.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .contentShape(Circle())
            } else {
                Text("Export")
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.14))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help("Export this shot list as PDF, text, or a web page with media")
    }

    /// Opens the shooting-schedule board for the selected version.
    @ViewBuilder
    private var scheduleButton: some View {
        Button { showScheduleSheet = true } label: {
            Label("Schedule", systemImage: "calendar")
        }
        .help("Plan shooting days and arrange scenes in shoot order")
        .disabled(selectedVersion == nil)
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
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Scene")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)\(scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " — \(scene.nickname)")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sceneDetailsSection(for: scene)
                    sceneScriptLocationSection(for: scene)
                    sceneTimeAndLocationSection(for: scene)
                }
                .padding(20)
            }

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
        .adaptiveSheetFrame(width: 480, height: 620)
    }

    /// A titled card matching the Edit Shot sheet — a caps label above a rounded,
    /// tinted container. Shared by the Edit Scene sections.
    @ViewBuilder
    private func settingsCard<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    /// One labelled row inside a `settingsCard`: name on the left, control right.
    @ViewBuilder
    private func settingsRow<Content: View>(_ label: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 8)
            content()
        }
    }

    @ViewBuilder
    private func editShotSheet(for shot: Shot) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "number.square.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shot Numbering")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Currently shown as Shot \(shot.displayNumber)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text("NUMBERING STYLE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                numberingOptionRow(shot, style: .numbers, title: "Scene Numbers",
                                   detail: "Numbered within each scene: 1, 2, 3…")
                numberingOptionRow(shot, style: .letters, title: "Scene Letters",
                                   detail: "Lettered within each scene: A, B, C…")
                numberingOptionRow(shot, style: .continuous, title: "Continuous",
                                   detail: "A unique running number across the project: 001, 002, 003…")

                Label("Changing the style updates every shot in the project.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Spacer(minLength: 0)
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
        .adaptiveSheetFrame(width: 480, height: 440)
    }

    /// One selectable numbering-style card: a radio dot, its name and description,
    /// and a live preview of how this shot would read in that style.
    @ViewBuilder
    private func numberingOptionRow(_ shot: Shot, style: ShotNumberingStyle,
                                    title: String, detail: String) -> some View {
        let isSelected = shot.numberingStyle == style
        Button {
            applyNumberingStyleToAllShots(style)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(shot.formattedNumber(style: style))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.15),
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Scene Form Sections
    
    @ViewBuilder
    private func sceneDetailsSection(for scene: Scene) -> some View {
        settingsCard("SCENE DETAILS") {
            settingsRow("Scene Number") {
                TextField("Number", value: Binding(
                    get: { scene.sceneNumber },
                    set: { scene.sceneNumber = max(1, $0) }
                ), format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
            }

            Divider()

            settingsRow("Suffix") {
                HStack(spacing: 8) {
                    Text("\(scene.suffix.count)/5")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

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
                }
            }

            Divider()

            settingsRow("Nickname") {
                TextField("Optional name", text: Binding(
                    get: { scene.nickname },
                    set: { scene.nickname = $0 }
                ))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }
        }
    }

    @ViewBuilder
    private func sceneScriptLocationSection(for scene: Scene) -> some View {
        settingsCard("SCRIPT LOCATION") {
            settingsRow("Scene Page") {
                HStack(spacing: 8) {
                    if scene.scriptPageNumber > 0 {
                        Text("PDF page \(scene.absolutePDFPage + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Page", value: Binding(
                        get: { scene.scriptPageNumber }, // Already 1-based
                        set: { scene.scriptPageNumber = max(1, $0) } // Minimum page 1
                    ), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                }
            }
        }
    }

    @ViewBuilder
    private func sceneTimeAndLocationSection(for scene: Scene) -> some View {
        settingsCard("TIME & LOCATION") {
            settingsRow("Time of Day") {
                Picker("Time", selection: Binding(
                    get: { scene.isDay ? "Day" : "Night" },
                    set: { scene.isDay = ($0 == "Day") }
                )) {
                    Text("Day").tag("Day")
                    Text("Night").tag("Night")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            Divider()

            settingsRow("Location Type") {
                Picker("Location", selection: Binding(
                    get: { scene.isInterior ? "Int." : "Ext." },
                    set: { scene.isInterior = ($0 == "Int.") }
                )) {
                    Text("Int.").tag("Int.")
                    Text("Ext.").tag("Ext.")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }
    
    // MARK: - Confirmation Dialog
    
    // MARK: - Helper Functions

    private func deleteScenes(_ scenes: [Scene]) {
        guard !scenes.isEmpty else { return }

        modelContext.destructiveDelete {
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

        modelContext.destructiveDelete {
            for shot in shots {
                shot.scene?.removeSceneMapMarkers(forShotUID: shot.uid)
                if let scene = shot.scene, let index = scene.shots.firstIndex(where: { $0 === shot }) {
                    scene.shots.remove(at: index)
                }
                modelContext.delete(shot)
            }
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
                // Hit area wider than the 1pt line so it's easy to grab — and wider
                // still on iPad, where a fingertip needs a bigger target than a cursor.
                #if os(iOS)
                let hitWidth: CGFloat = 36
                #else
                let hitWidth: CGFloat = 12
                #endif
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: hitWidth)
                        .contentShape(Rectangle())
                    // A visible grip pill with three dots, so it's obvious the
                    // divider can be dragged. Doesn't intercept the drag itself.
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 3.5)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                        .overlay {
                            VStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle().fill(Color.secondary.opacity(0.6))
                                        .frame(width: 2.5, height: 2.5)
                                }
                            }
                        }
                        .frame(width: 7, height: 46)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                        .opacity(isDragging ? 1 : 0.9)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                // Pointer feedback for the drag handle — macOS only (no cursor on iPad).
                #if os(macOS)
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
                #endif
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
