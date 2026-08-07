//
//  SceneMapMarkerImport.swift
//  CinePlanner
//
//  Adds a CineStager reference's camera + mannequin markers to a scene map, using
//  the coordinates embedded in the reference's top-down map EXIF. Used by the
//  reference card's "add markers to scene map" action, and mirrors how the
//  initial CineStager import places them.
//

import Foundation
import SwiftData

enum SceneMapMarkerImport {
    /// ~0.4% of the map — "the same point", matching the import's de-dup tolerance.
    static let sameSpot = 0.004

    /// Camera + mannequin markers embedded in the reference's CineStager top-down
    /// map, or nil when it isn't a CineStager map with marker data.
    static func markers(for reference: ShotReference) -> CineStagerMapMetadata.Markers? {
        guard let data = reference.mapData else { return nil }
        return CineStagerMapMetadata.markers(from: data)
    }

    /// Whether the reference's clean top-down map is already the scene background.
    static func backgroundPresent(for reference: ShotReference, in scene: Scene) -> Bool {
        guard let bg = reference.mapCleanData ?? reference.mapData else { return true }
        return scene.sceneMapBackgroundData == bg
    }

    /// Re-adds this shot to the scene map: sets the clean top-down as the (scaled)
    /// background and adds any missing camera + mannequin markers.
    static func addToSceneMap(_ markers: CineStagerMapMetadata.Markers, reference: ShotReference,
                              shot: Shot, to scene: Scene) {
        if let background = reference.mapCleanData ?? reference.mapData {
            scene.sceneMapBackgroundData = background
            scene.sceneMapBackgroundIsSatellite = false
            scene.sceneFloorPlanJSON = nil
            let loc = reference.mapLocationModel?.trimmingCharacters(in: .whitespaces)
            scene.sceneMapLocation = (loc?.isEmpty == false) ? loc : nil
            // Same scale as the import: a square map spanning the room's longer side.
            let span = max(reference.mapLocationWidth ?? 0, reference.mapLocationLength ?? 0)
            scene.sceneMapMetersWide = span > 0 ? span : nil
            scene.sceneMapCameraSizeMeters = (reference.mapCameraPhysicalWidth ?? 0) > 0
                ? reference.mapCameraPhysicalWidth! / 100 : nil
            try? scene.modelContext?.save()
        }
        _ = addMissing(markers, shot: shot, to: scene)
    }

    /// Whether every marker in `markers` is already on the scene map.
    static func allPresent(_ markers: CineStagerMapMetadata.Markers, shot: Shot, in scene: Scene) -> Bool {
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        if markers.camera != nil,
           !doc.elements.contains(where: { $0.kind == .camera && $0.shotUID == shot.uid }) {
            return false
        }
        return markers.mannequins.allSatisfy { mannequinPresent($0, in: doc) }
    }

    /// Adds any of the reference's markers not already present. Returns whether
    /// anything was added (and saves the scene when it did).
    @discardableResult
    static func addMissing(_ markers: CineStagerMapMetadata.Markers, shot: Shot, to scene: Scene) -> Bool {
        var doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        var changed = false

        if let cam = markers.camera,
           !doc.elements.contains(where: { $0.kind == .camera && $0.shotUID == shot.uid }) {
            var element = MapElement(kind: .camera, x: cam.u, y: cam.v)
            element.label = shot.displayNumber
            element.shotUID = shot.uid
            element.colorHex = "#FF9500"
            if let rot = cam.rotationDeg { element.rotation = rot }
            doc.elements.append(element)
            changed = true
        }
        for mannequin in markers.mannequins where !mannequinPresent(mannequin, in: doc) {
            var element = MapElement(kind: .character, x: mannequin.u, y: mannequin.v)
            element.colorHex = "#4C8DFF"
            if let rot = mannequin.rotationDeg { element.rotation = rot }
            doc.elements.append(element)
            changed = true
        }

        guard changed else { return false }
        assignSceneCharacters(&doc, scene: scene)
        scene.sceneMapJSON = doc.jsonString
        try? scene.modelContext?.save()
        return true
    }

    private static func mannequinPresent(_ mannequin: CineStagerMapMetadata.Marker, in doc: SceneMapDoc) -> Bool {
        doc.elements.contains { element in
            element.kind == .character
                && abs(element.x - mannequin.u) < sameSpot
                && abs(element.y - mannequin.v) < sameSpot
        }
    }

    /// Labels unlabeled mannequins with the scene's detected characters (in order),
    /// tinting each with its project color — same best-effort guess as the import.
    private static func assignSceneCharacters(_ doc: inout SceneMapDoc, scene: Scene) {
        let names = scene.sceneCharacterNames
        guard !names.isEmpty else { return }
        let projectChars = scene.project?.scriptCharacters ?? []
        func color(for name: String) -> String {
            projectChars.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.colorHex ?? "#4C8DFF"
        }
        var next = 0
        for i in doc.elements.indices
        where doc.elements[i].kind == .character && doc.elements[i].label.isEmpty {
            guard next < names.count else { break }
            doc.elements[i].label = names[next]
            doc.elements[i].colorHex = color(for: names[next])
            next += 1
        }
    }
}
