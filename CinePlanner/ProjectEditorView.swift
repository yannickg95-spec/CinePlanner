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
    @Environment(\.modelContext) var modelContext
    /// iPhone collapses the multi-column editor into a single-column drill-down.
    /// iPad (any size) and Mac keep the columns unchanged.
    var isPhoneLayout: Bool { DeviceLayout.isPhone }
    /// iPhone: presents the script PDF full-screen (no room for a side-by-side pane).
    @State var showScriptSheet = false
    /// iPhone: the shot whose script lines are being marked in the full-screen
    /// script cover (set when its "Mark Text" opens the script), else nil.
    @State var coverageMarkingShot: Shot?
    /// iPhone: true while the script cover is in text-selection mode, so it shows
    /// Done/Cancel instead of a plain close button.
    @State var isCoverageMarkingInSheet = false
    /// iPhone two-tap marking: false while picking the first word, true for the last.
    @State var coverageMarkLastPhase = false
    /// iPhone landscape 30/70 split is active — the detail tabs move into the toolbar.
    @State var isLandscapeSplit = false
    /// The shooting-schedule board sheet.
    @State var showScheduleSheet = false
    /// On-Set Mode — a full-window viewing mode, driven from the app root.
    @Environment(OnSetController.self) var onSet

    // Live column widths. Dragging updates these (cheap, local); the value is
    // written back to the project only when the drag ends, so we're not saving
    // to SwiftData on every frame.
    @State var scriptWidth: CGFloat = 420
    /// The script pane's share of the details+script pair (seeded from the
    /// project, clamped to the allowed band).
    @State var scriptFraction: CGFloat = 0.5
    // Selection is tracked by uid (stable across saves), not the model itself.
    @State var selectedScenes: Set<String> = []
    @State var selectedShots: Set<String> = []

    /// Which view fills the flexible detail pane on the right. `.script` is an
    /// iPhone-only tab (iPad shows the script in its own column).
    enum DetailTab: Hashable { case shot, map, script }
    @State var detailTab: DetailTab = .shot

    // Edit / delete targets (driven by right-click context menus on rows)
    @State var sceneToEdit: Scene?
    @State var shotToEdit: Shot?
    @State var pendingSceneDeletion: [Scene] = []
    @State var pendingShotDeletion: [Shot] = []

    // Episodes & script versioning
    /// The scene whose script page the user is currently placing in the PDF, if any.
    @State var sceneBeingMarked: Scene?
    @State var selectedEpisode: Episode?
    @State var selectedVersion: ScriptVersion?
    @State var showCopyShotsPrompt = false
    @State var showTransferSheet = false
    @State var requestScriptImport = false
    // iPhone: the script settings gear lives beside the tabs, so the editor owns the
    // coverage-margin state (passed down for a live preview) and forces a PDF reload
    // when the script is deleted from here.
    @State var scriptCoverageMargin: Double = 0.15
    @State var scriptCoverageOnRight: Bool = false
    @State var showScriptMarginSheet = false
    @State var scriptReloadToken = 0
    @State var showExportSheet = false
    @State var showPublishSheet = false
    /// The menu bar's commands for this project (one stable object; see AppCommands).
    @State var menuCommands = ProjectEditorCommands()
    @State var showingDeletePageConfirm = false
    @State var isDeletingPage = false
    @State var deletePageError: String?
    @State var isUpdatingPage = false
    @State var updatePageError: String?
    @State var pageIsLive = false

    var publishedURL: String? { project.publishedPagesURL }
    @State var sceneForShotImport: Scene?
    @State var versionPendingDeletion: ScriptVersion?
    @State var versionToRename: ScriptVersion?
    @State var episodePendingDeletion: Episode?
    @State var episodeToRename: Episode?
    @State var renameText: String = ""

    /// Versions in the selected episode.
    var currentVersions: [ScriptVersion] {
        selectedEpisode?.orderedVersions ?? []
    }

    var orderedScenes: [Scene] {
        (selectedVersion?.scenes ?? project.scenes).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Versions of the current episode (other than the selected one) that contain
    /// at least one shot — candidates for copying shots into the current version.
    var otherVersionsWithShots: [ScriptVersion] {
        currentVersions.filter { $0 !== selectedVersion && $0.totalShotCount > 0 }
    }

    // Resolve the selected model by its stable uid. (uid never changes on save,
    // so unlike Set<Model>.contains this can't miss a freshly-created row.)
    var selectedScene: Scene? {
        orderedScenes.first { selectedScenes.contains($0.uid) }
    }

    var selectedShot: Shot? {
        guard let scene = selectedScene else { return nil }
        return scene.shots.sorted { $0.shotNumber < $1.shotNumber }.first { selectedShots.contains($0.uid) }
    }

    /// Whether a script PDF exists to place scenes against.
    var hasScriptPDF: Bool {
        (selectedVersion?.pdfData ?? project.scriptPDFData) != nil
    }

    /// Records the page the user scrolled to as the scene's script page. The stored
    /// value is scene-relative (offset from the first scene's page), matching how
    /// `Scene.absolutePDFPage` reconstructs it.
    func finishMarkingScenePage(atPageIndex pageIndex: Int) {
        defer { sceneBeingMarked = nil }
        guard let scene = sceneBeingMarked else { return }
        let offset = selectedVersion?.pdfPageOffset ?? project.resolvedPDFPageOffset
        scene.scriptPageNumber = max(1, pageIndex - offset + 1)
        modelContext.saveReporting()
    }
    
    var body: some View {
        deletionAlerts(editorAlerts(editorSheets(coreView)))
            .onAppear(perform: connectMenuCommands)
            .focusedSceneValue(\.projectEditorCommands, menuCommands)
    }

    /// What this project offers the menu bar (File, View) — wired once into the one
    /// stable commands object it publishes (see AppCommands).
    func connectMenuCommands() {
        menuCommands.importScript = { requestScriptImport = true }
        menuCommands.export = { showExportSheet = true }
        menuCommands.publish = { showPublishSheet = true }
        menuCommands.showShotDetails = { detailTab = .shot }
        menuCommands.showSceneMap = { detailTab = .map }
        menuCommands.showSchedule = { if selectedVersion != nil { showScheduleSheet = true } }
        menuCommands.startOnSet = { if let version = selectedVersion { onSet.version = version } }
    }

    var coreView: some View {
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

            // macOS: each control is its own toolbar item for uniform system
            // spacing. On macOS 26, hide the OS "Liquid Glass" per-item background —
            // otherwise it merges the two adjacent plain circle buttons into one
            // touching segmented pair — so only our own circle backgrounds show.
            #if os(macOS)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { onSetButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { scheduleButton }
                    .sharedBackgroundVisibility(.hidden)
                if let url = publishedURL {
                    ToolbarItem(placement: .primaryAction) { publishedPageMenu(url: url) }
                        .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .primaryAction) { exportButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { onSetButton }
                ToolbarItem(placement: .primaryAction) { scheduleButton }
                if let url = publishedURL {
                    ToolbarItem(placement: .primaryAction) { publishedPageMenu(url: url) }
                }
                ToolbarItem(placement: .primaryAction) { exportButton }
            }
            #endif

            // GitHub + Export share the toolbar row with the project name. iPhone
            // keeps its always-visible GitHub button (publish when unpublished, the
            // page menu once live) plus Export; the Script button and version chips
            // stay in the content header below. iPad uses its export group.
            // Hide the OS 26 "Liquid Glass" pill so the badges keep their own look.
            #if os(iOS)
            if isPhoneLayout {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { headerButtons }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { headerButtons }
                }
            } else {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { exportToolbarGroup }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { exportToolbarGroup }
                }
            }
            #endif
        }
        // In On-Set Mode the full-window overlay takes over, so hide the editor's
        // toolbar — including the navigation back button to the project list.
        #if os(iOS)
        .toolbar(onSet.version != nil ? .hidden : .automatic, for: .navigationBar)
        .navigationBarBackButtonHidden(onSet.version != nil)
        #else
        .toolbar(onSet.version != nil ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .onAppear {
            // Ensure the project has the episode → version structure (migrates legacy projects)
            project.migrateStructureIfNeeded()
            project.lastOpenedDate = Date()
            // Save right away rather than leave the project dirty until the next flush:
            // a dirty object isn't refreshed by an iCloud import (see SyncRefresher).
            modelContext.saveReporting()

            // The script split is seeded where its width is derived (in the
            // editor columns' GeometryReader), so nothing to do here.
            if selectedEpisode == nil {
                selectedEpisode = project.orderedEpisodes.first
            }
            if selectedVersion == nil {
                selectedVersion = selectedEpisode?.orderedVersions.last
            }
            scriptCoverageMargin = selectedVersion?.coverageLineMargin ?? 0.15
            scriptCoverageOnRight = selectedVersion?.coverageLinesOnRight ?? false

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
            scriptCoverageOnRight = selectedVersion?.coverageLinesOnRight ?? false
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
}

// MARK: - Custom Label Style

// MARK: - Resizable Divider

#Preview {
    let project = Project(filmName: "My Film")
    NavigationStack {
        ProjectEditorView(project: project)
    }
    .environment(OnSetController())
    .modelContainer(for: Project.self, inMemory: true)
}
