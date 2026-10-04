//
//  ProjectEditorView+DetailColumn.swift
//  CinePlanner
//
//  The editor's column stack and the detail pane's tabs (shot details, scene map,
//  script).
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    func editorColumnStack(available: CGFloat, showScript: Bool) -> some View {
        HStack(spacing: 0) {
            // Sidebar - Scenes (fixed width, matching the shots column)
            SceneListView(
                project: project,
                version: selectedVersion,
                selectedScenes: $selectedScenes,
                canImportShots: !otherVersionsWithShots.isEmpty,
                onEditScene: { sceneToEdit = $0 },
                onImportShots: { modelContext.saveReporting(); sceneForShotImport = $0 },
                onDeleteScenes: { pendingSceneDeletion = $0 },
                onSceneAdded: { scene in
                    // With a script loaded, let the user place the scene's page by
                    // scrolling the PDF; otherwise the scene is just added.
                    if hasScriptPDF { sceneBeingMarked = scene }
                }
            )
            // Redraw after an iCloud import changed data (see SyncRefresher).
            .id(SyncRefresher.shared.generation)
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
                                .id(SyncRefresher.shared.generation)   // redraw after a data-changing import
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
    var detailTabPill: some View {
        HStack(spacing: 4) {
            tabButton("Shots", .shot)
            tabButton("Scene Map", .map)
            // iPhone: the script lives in a tab here (iPad has its own column).
            if isPhoneLayout { tabButton("Script", .script) }
        }
        .padding(3)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
    }

    var detailTabBar: some View {
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
    var scriptTabGear: some View {
        Menu {
            Button {
                requestScriptImport = true
            } label: {
                Label("Replace Script…", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                showScriptMarginSheet = true
            } label: {
                Label("Coverage Line Settings…", systemImage: "paintpalette")
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
    func deleteScriptFromEditor() {
        selectedVersion?.pdfData = nil
        project.scriptPDFData = nil
        modelContext.saveReporting()
        scriptReloadToken += 1
    }


    func tabButton(_ title: String, _ tab: DetailTab) -> some View {
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
    func detailContent(for scene: Scene) -> some View {
        switch detailTab {
        // `.script` is iPhone-only; the iPad detail pane never selects it, but the
        // switch must stay exhaustive, so it falls back to the shot detail.
        case .shot, .script:
            if let shot = selectedShot {
                ShotDetailView(shot: shot)
                    // Also keyed on the sync generation (see SyncRefresher).
                    .id("\(shot.uid)#\(SyncRefresher.shared.generation)")
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
}
