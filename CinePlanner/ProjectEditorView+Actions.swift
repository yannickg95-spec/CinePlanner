//
//  ProjectEditorView+Actions.swift
//  CinePlanner
//
//  Deleting scenes and shots, and renumbering shots.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    // MARK: - Helper Functions

    func deleteScenes(_ scenes: [Scene]) {
        guard !scenes.isEmpty else { return }

        modelContext.destructiveDelete {
            for scene in scenes {
                scene.forgetCoverageAliases()
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

    func deleteShots(_ shots: [Shot]) {
        guard !shots.isEmpty else { return }
        let affectedScenes = Set(shots.compactMap { $0.scene })

        modelContext.destructiveDelete {
            for shot in shots {
                shot.scene?.forgetShot(uid: shot.uid)
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
    
    func applyNumberingStyleToAllShots(_ style: ShotNumberingStyle) {
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
