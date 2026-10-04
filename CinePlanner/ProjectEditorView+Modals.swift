//
//  ProjectEditorView+Modals.swift
//  CinePlanner
//
//  The project editor's sheets and alerts, including the delete confirmations.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    func editorSheets<Content: View>(_ content: Content) -> some View {
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
            CoverageSettingsSheet(project: project, version: selectedVersion,
                                  margin: $scriptCoverageMargin, onRight: $scriptCoverageOnRight)
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

    func editorAlerts<Content: View>(_ content: Content) -> some View {
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
                modelContext.saveReporting() // stable IDs before matching
                showTransferSheet = true
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("The scenes were imported. Do you want to copy over the shots you planned in a previous script version? You can match old scenes to the new ones before anything is copied.")
        }
    }

    func deletionAlerts<Content: View>(_ content: Content) -> some View {
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

    var sceneDeletionTitle: String {
        if pendingSceneDeletion.count == 1, let scene = pendingSceneDeletion.first {
            return "Delete Scene \(scene.sceneNumber)\(scene.suffix)?"
        }
        return "Delete \(pendingSceneDeletion.count) Scenes?"
    }

    var shotDeletionTitle: String {
        if pendingShotDeletion.count == 1, let shot = pendingShotDeletion.first {
            return "Delete Shot \(shot.displayNumber)?"
        }
        return "Delete \(pendingShotDeletion.count) Shots?"
    }
}
