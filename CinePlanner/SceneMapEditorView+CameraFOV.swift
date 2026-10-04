//
//  SceneMapEditorView+CameraFOV.swift
//  CinePlanner
//
//  Camera field-of-view settings: which sensor sizes a camera's view cone.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    /// Flips the per-scene camera FOV overlay. Scene-wide by design: it applies to
    /// every camera marker in the scene, and to any added later (and hides them
    /// all the same way).
    func toggleCameraFOV() {
        scene.sceneMapShowCameraFOV.toggle()
        saveContext()
    }

    /// Switches camera + mannequin markers between real-world scale and a fixed,
    /// easy-to-see size (see `sceneMarkerScale`).
    func toggleViewableMarkerSize() {
        scene.sceneMapViewableMarkerSize.toggle()
        saveContext()
    }

    /// Whether the viewable-size toggle is worth showing: only when a marker would
    /// actually render smaller than default. If both the camera and mannequin are
    /// already ≥ default size at the current scale, the toggle would do nothing, so
    /// it's hidden.
    var viewableSizeToggleRelevant: Bool {
        guard let metersWide = mapMetersWide, metersWide > 0, mapContentWidth > 0 else { return false }
        let camera = realisticMarkerScale(kind: .camera, metersWide: metersWide,
                                          cameraMeters: mapCameraMeters, mapWidthPoints: mapContentWidth)
        let mannequin = realisticMarkerScale(kind: .character, metersWide: metersWide,
                                             cameraMeters: mapCameraMeters, mapWidthPoints: mapContentWidth)
        return camera < 1 || mannequin < 1
    }

    /// Sets one camera marker's FOV sensor basis (S16 / S35 / LF / its CineStager
    /// camera). Per-camera — only the given marker changes.
    func setFOVBasis(_ basis: FOVBasis, for element: MapElement) {
        guard let index = doc.elements.firstIndex(where: { $0.id == element.id }) else { return }
        doc.elements[index].fovBasis = basis
        persist()
    }

    /// A camera marker's effective FOV basis: its explicit choice, or the auto
    /// default — the CineStager camera when the shot has an imported sensor, else
    /// Super-35. Drives the checkmark in the "FOV Settings" menu.
    func effectiveBasis(for element: MapElement) -> FOVBasis {
        if let basis = element.fovBasis { return basis }
        return cineStagerCameraName(for: element) != nil ? .cineStager : .super35
    }

    /// The sensor width (mm) a camera's FOV wedge is drawn from, resolving its
    /// basis: a fixed format, or the shot's CineStager sensor with a Super-35
    /// fallback.
    func sensorWidthMM(for element: MapElement, shot: Shot) -> Double {
        if let fixed = effectiveBasis(for: element).fixedSensorWidthMM { return fixed }
        return (shot.sensorWidthMM ?? 0) > 0 ? shot.sensorWidthMM! : 24.89
    }

    /// The CineStager camera name for a camera marker (used to resolve the auto
    /// basis), or nil when that shot has no imported sensor.
    func cineStagerCameraName(for element: MapElement) -> String? {
        guard let uid = element.shotUID,
              let shot = scene.shots.first(where: { $0.uid == uid }),
              (shot.sensorWidthMM ?? 0) > 0 else { return nil }
        let name = shot.camera.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "CineStager Camera" : name
    }

    /// Every distinct CineStager camera profile imported anywhere in the project
    /// — a (combined camera, sensor width) any camera marker's FOV can be based on.
    var cineStagerProfiles: [CineStagerProfile] {
        guard let project = scene.project else { return [] }
        var seen = Set<String>()
        var result: [CineStagerProfile] = []
        for scn in project.scenes {
            for s in scn.shots {
                guard let sensor = s.sensorWidthMM, sensor > 0, !s.camera.isEmpty else { continue }
                let profile = CineStagerProfile(camera: s.camera, sensorWidthMM: sensor)
                if seen.insert(profile.id).inserted { result.append(profile) }
            }
        }
        return result
    }

    /// The profile rows for the FOV menu: (id, display label) — the combined
    /// camera value, which already carries its format.
    var fovProfileRows: [(id: String, label: String)] {
        cineStagerProfiles
            .map { (id: $0.id, label: $0.camera) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Which profile row is checked for a camera marker: the one matching its
    /// shot's camera, when the marker is on the CineStager basis.
    func selectedFOVProfileID(for element: MapElement) -> String? {
        guard effectiveBasis(for: element) == .cineStager,
              let uid = element.shotUID,
              let shot = scene.shots.first(where: { $0.uid == uid }) else { return nil }
        return shot.camera
    }

    /// Picks a project CineStager profile as a camera marker's FOV basis, and
    /// fills the linked shot's camera + sensor to match — so the shot editor shows
    /// the same camera the FOV is drawn from.
    func selectFOVProfile(_ id: String, for element: MapElement) {
        guard let profile = cineStagerProfiles.first(where: { $0.id == id }),
              let index = doc.elements.firstIndex(where: { $0.id == element.id }) else { return }
        doc.elements[index].fovBasis = .cineStager   // draw from the shot's own sensor…
        if let uid = element.shotUID, let shot = scene.shots.first(where: { $0.uid == uid }) {
            shot.camera = profile.camera              // …which we set to match the profile.
            shot.sensorWidthMM = profile.sensorWidthMM
        }
        persist()
    }
}
