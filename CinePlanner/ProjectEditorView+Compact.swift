//
//  ProjectEditorView+Compact.swift
//  CinePlanner
//
//  The iPhone layout: a single-column drill-down from scenes to shots, with its header.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    // MARK: - iPhone (compact) single-column drill-down

    /// iPhone: the scenes list is the root; tapping a scene pushes its shots/map,
    /// tapping a shot pushes the shot detail. The scene/shot rows are already
    /// `NavigationLink(value:)`, so these destinations (added only in compact
    /// width) turn them into pushes — leaving iPad/Mac, which never attach them,
    /// on the existing selection-driven columns.
    @ViewBuilder
    var compactColumns: some View {
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
                // Keyed on the sync generation too, so an iCloud import that changed
                // data redraws it with the refreshed values (see SyncRefresher).
                .id("\(shot.uid)#\(SyncRefresher.shared.generation)")
                .navigationTitle("Shot \(shot.displayNumber)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .onAppear { selectedShots = [shot.uid] }
        }
    }

    /// The iPhone scenes list. `selectsInPlace` (landscape split) makes a tap select
    /// the scene for the right-hand script pane instead of pushing its detail.
    func compactSceneList(selectsInPlace: Bool) -> some View {
        SceneListView(
            project: project,
            version: selectedVersion,
            selectedScenes: $selectedScenes,
            canImportShots: !otherVersionsWithShots.isEmpty,
            onEditScene: { sceneToEdit = $0 },
            onImportShots: { modelContext.saveReporting(); sceneForShotImport = $0 },
            onDeleteScenes: { pendingSceneDeletion = $0 },
            onSceneAdded: { scene in if hasScriptPDF { sceneBeingMarked = scene } },
            onSelectScene: selectsInPlace ? { _ in } : nil
        )
        // Redraw after an iCloud import changed data (see SyncRefresher).
        .id(SyncRefresher.shared.generation)
    }

    /// The 3-tab scene content (Shots / Scene Map / Script), without navigation
    /// chrome — shared by the pushed scene screen and the landscape split's right
    /// pane.
    func compactSceneDetail(_ scene: Scene) -> some View {
        VStack(spacing: 0) {
            detailTabBar
            Divider()
            compactSceneTabContent(scene)
        }
    }

    /// Just the selected tab's content (no tab bar) — the landscape split shows the
    /// tab bar in its own top row instead.
    @ViewBuilder
    func compactSceneTabContent(_ scene: Scene) -> some View {
        Group {
            switch detailTab {
            case .shot:
                ShotListView(
                    scene: scene,
                    selectedShots: $selectedShots,
                    onEditShot: { shotToEdit = $0 },
                    onDeleteShots: { pendingShotDeletion = $0 }
                )
                .id(SyncRefresher.shared.generation)   // redraw after a data-changing import
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
    func compactSceneScreen(_ scene: Scene) -> some View {
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
    func compactScriptView(for scene: Scene) -> some View {
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
            coverageMarginOverride: scriptCoverageMargin,
            coverageOnRightOverride: scriptCoverageOnRight
        )
        .id(scriptReloadToken)
        // Another device changed the script's coverage-line placement.
        .onChange(of: SyncRefresher.shared.generation) {
            scriptCoverageMargin = selectedVersion?.coverageLineMargin ?? 0.15
            scriptCoverageOnRight = selectedVersion?.coverageLinesOnRight ?? false
        }
    }

    /// iPhone header for the scenes screen: the Script button + version chips.
    /// GitHub and Export live in the toolbar row (with the project name).
    var compactEditorHeader: some View {
        headerVersions
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// Schedule + GitHub + Export, shown in the iPhone toolbar row.
    @ViewBuilder
    var headerButtons: some View {
        // Landscape has room for the four individual circles. Portrait doesn't, so
        // rather than let iOS collapse them into its own overflow control (whose menu
        // can't render our custom .plain buttons, so tapping it does nothing), we
        // supply a real Menu that lists the same four actions.
        if isLandscapeSplit {
            HStack(spacing: 8) {
                onSetButton
                scheduleButton
                gitHubHeaderButton
                exportButton
            }
        } else {
            headerOverflowMenu
        }
    }

    /// iPhone portrait: the four toolbar actions folded into one tappable circle.
    var headerOverflowMenu: some View {
        Menu {
            Button {
                onSet.version = selectedVersion
            } label: {
                Label("On-Set Mode", systemImage: "film")
            }
            .disabled(selectedVersion == nil)

            Button {
                showScheduleSheet = true
            } label: {
                Label("Shooting Schedule", systemImage: "calendar")
            }
            .disabled(selectedVersion == nil)

            Divider()

            if let url = publishedURL {
                // The live-page actions (open, copy link, update, unpublish) as a submenu.
                Menu {
                    publishedPageMenuItems(url: url)
                } label: {
                    Label("Published Page", image: "GitHubLogo")
                }
            } else {
                Button {
                    showPublishSheet = true
                } label: {
                    Label("Publish to GitHub", image: "GitHubLogo")
                }
            }

            Button {
                showExportSheet = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    /// iPhone header. For a series the episode switch gets its own row (it and the
    /// version row don't fit together in portrait); the "Version:" label stays put
    /// and only the version chips scroll.
    @ViewBuilder
    var headerVersions: some View {
        if project.isSeries {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    episodeMenu
                    Spacer(minLength: 0)
                }
                versionRow
            }
        } else {
            versionRow
        }
    }

    /// The "Version:" label with the horizontally scrolling version chips + New.
    var versionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Version:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
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
    var gitHubHeaderButton: some View {
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
            .accessibilityLabel("Publish to GitHub")
        }
    }
}
