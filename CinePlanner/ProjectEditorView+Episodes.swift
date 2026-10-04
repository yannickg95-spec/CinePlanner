//
//  ProjectEditorView+Episodes.swift
//  CinePlanner
//
//  Adding and deleting episodes and script versions.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    // MARK: - Episode Management

    func addEpisode() {
        let nextNumber = (project.episodes.map(\.episodeNumber).max() ?? 0) + 1
        let episode = Episode(episodeNumber: nextNumber)
        episode.project = project
        // Pre-fill the app's default credits (a series reads per-episode credits).
        let defDirector = CreditDefaults.director
        let defDP = CreditDefaults.cinematographer
        if !defDirector.isEmpty { episode.director = defDirector }
        if !defDP.isEmpty { episode.cinematographer = defDP }
        // Every episode starts with an empty first version, ready to import into.
        let version = ScriptVersion(versionNumber: 1)
        version.episode = episode
        selectedEpisode = episode
        selectedVersion = version
        // Prompt to import the episode's script right away
        requestScriptImport = true
    }

    func deleteEpisode(_ episode: Episode) {
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

    func addNewVersion() {
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

    func deleteVersion(_ version: ScriptVersion) {
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
}
