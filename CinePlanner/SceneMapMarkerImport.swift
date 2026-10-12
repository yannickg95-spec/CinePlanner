//
//  SceneMapMarkerImport.swift
//  CinePlanner
//
//  Puts a CineStager shot on its scene map: its clean top-down map as the
//  background, and the markers embedded in the reference's top-down map EXIF —
//  the camera (for a video that travelled, a camera at every position with an
//  arrow along the route from each to the next) and the mannequins. Used by the
//  CineStager import and by the reference card's "add markers to scene map"
//  action, so both place them the same way.
//

import CoreGraphics
import Foundation
import SwiftData

enum SceneMapMarkerImport {
    /// ~0.4% of the map — "the same point" for markers without a world position.
    static let sameSpot = 0.004
    /// Metres — "the same spot", not "nearby", for markers with a world position.
    static let sameWorld = 0.03

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
        // An older reference without a clean map falls back to the marker map
        // itself, whose framing the markers share.
        let onCleanMap = reference.mapCleanData != nil
        if let background = reference.mapCleanData ?? reference.mapData {
            setBackground(background, reference: reference, markers: onCleanMap ? markers : nil,
                          location: reference.mapLocationModel, in: scene)
            scene.sceneFloorPlanJSON = nil
        }
        addMissing(markers, frame: cleanMapFrame(of: markers, onCleanMap: onCleanMap), shot: shot, to: scene)
        fitBackgroundToMarkers(in: scene)
        scene.modelContext?.saveReporting()
    }

    /// Makes `background`, a CineStager clean map with `markers` on the marker
    /// map, the scene map's background at CineStager's scale: the square of the
    /// location's world bounds, as wide as their longer side. (Where it can't be
    /// told where the clean map lies, the room rect was taken for it, and its
    /// width for the map's.) Remembers the location, so another shot of it adds
    /// its markers without a replace prompt.
    static func setBackground(_ background: Data, reference: ShotReference, markers: CineStagerMapMetadata.Markers?,
                              location: String?, in scene: Scene) {
        scene.sceneMapBackgroundData = background
        scene.sceneMapBackgroundIsSatellite = false
        let location = location?.trimmingCharacters(in: .whitespaces)
        scene.sceneMapLocation = (location?.isEmpty == false) ? location : nil
        let span = max(reference.mapLocationWidth ?? 0, reference.mapLocationLength ?? 0)
        let tookRoomRect = markers?.cleanMapRect == nil && markers?.roomRect != nil
        let metersWide = (tookRoomRect ? reference.mapLocationWidth : nil) ?? span
        scene.sceneMapMetersWide = metersWide > 0 ? metersWide : nil
        // CineStager's own scale, so a later manual scale change can be reset to it.
        scene.sceneMapImportedMetersWide = metersWide > 0 ? metersWide : nil
        // Camera width is in cm.
        scene.sceneMapCameraSizeMeters = (reference.mapCameraPhysicalWidth ?? 0) > 0
            ? reference.mapCameraPhysicalWidth! / 100 : nil
    }

    /// Whether every marker in `markers` (the reference's) is already on the scene map.
    static func allPresent(_ markers: CineStagerMapMetadata.Markers, reference: ShotReference,
                           shot: Shot, in scene: Scene) -> Bool {
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        if !markers.cameraPositions.isEmpty, !hasCamera(of: shot, in: doc) {
            return false
        }
        let frame = cleanMapFrame(of: markers, onCleanMap: reference.mapCleanData != nil)
        return markers.mannequins.allSatisfy { mannequinPresent($0, frame: frame, in: doc) }
    }

    /// Where the background lies on the marker map, to place the markers on it:
    /// for a clean map, where CineStager says (or it can be worked out), else the
    /// room rect, which imports took for it before. Nil when the background is
    /// the marker map itself.
    static func cleanMapFrame(of markers: CineStagerMapMetadata.Markers, onCleanMap: Bool) -> CGRect? {
        onCleanMap ? markers.cleanMapRect ?? markers.roomRect : nil
    }

    /// Adds any of the markers not on the scene map yet, placed on the background
    /// lying at `frame` on the marker map: the shot's cameras when it has none on the map — one per
    /// position of a video's path, joined by arrows through the route's bends —
    /// and mannequins standing where none is. Returns whether anything was added
    /// (and stores the scene map when it did).
    @discardableResult
    static func addMissing(_ markers: CineStagerMapMetadata.Markers, frame: CGRect?,
                           shot: Shot, to scene: Scene) -> Bool {
        var doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        var changed = false

        if !hasCamera(of: shot, in: doc) {
            var previous: UUID?
            for (index, position) in markers.cameraPositions.enumerated() {
                let p = onBackground(position.u, position.v, frame)
                var element = MapElement(kind: .camera, x: p.x, y: p.y)
                element.label = shot.displayNumber
                element.shotUID = shot.uid
                element.colorHex = "#FF9500"
                element.worldX = position.worldX
                element.worldZ = position.worldZ
                if let rotation = position.rotationDeg { element.rotation = rotation }
                doc.elements.append(element)
                if let previous {
                    let bends = markers.cameraPath?.legs[index - 1] ?? []
                    doc.arrows.append(MapArrow(fromID: previous, toID: element.id,
                                               pivots: bends.map { onBackground($0.x, $0.y, frame) }))
                }
                previous = element.id
                changed = true
            }
        }
        // Mannequins already on the map from an earlier shot stay single.
        for mannequin in markers.mannequins where !mannequinPresent(mannequin, frame: frame, in: doc) {
            let p = onBackground(mannequin.u, mannequin.v, frame)
            var element = MapElement(kind: .character, x: p.x, y: p.y)
            element.colorHex = "#4C8DFF"
            element.worldX = mannequin.worldX
            element.worldZ = mannequin.worldZ
            if let rotation = mannequin.rotationDeg { element.rotation = rotation }
            doc.elements.append(element)
            changed = true
        }

        guard changed else { return false }
        assignSceneCharacters(&doc, scene: scene)
        scene.storeSceneMap(doc)
        return true
    }

    /// The one time the background is zoomed out to keep markers in the map: if
    /// a camera, mannequin or route bend lands beyond the room's edge, the
    /// placement is fitted to them now, once, and stored. After that it's just a
    /// stored placement like a hand-alignment — the editor never refits live, and
    /// markers dragged afterwards snap to the map's bounds instead.
    static func fitBackgroundToMarkers(in scene: Scene) {
        guard !scene.sceneMapBackgroundIsSatellite else { return }
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        let points = doc.elements.map { CGPoint(x: $0.x, y: $0.y) } + doc.arrows.flatMap(\.pivots)
        // markerHalfExtent 0: zoom out only when a marker's *anchor* genuinely
        // falls outside the image (0…1), e.g. a camera the capture placed beyond
        // the room. Markers merely near an edge (the common no-RoomRect capture)
        // sit inside the image and mustn't trigger a zoom.
        scene.sceneMapBackgroundTransform = SceneMapBackgroundTransform.fittingMarkers(points, markerHalfExtent: 0)
    }

    /// A point of the marker map (u, v) on the background lying at `frame` on
    /// it: one the capture framed outside it lands outside 0…1, and the fit opens
    /// a margin for it. Unchanged without a frame.
    static func onBackground(_ u: Double, _ v: Double, _ frame: CGRect?) -> CGPoint {
        guard let f = frame, f.width > 0, f.height > 0 else { return CGPoint(x: u, y: v) }
        return CGPoint(x: (u - Double(f.minX)) / Double(f.width), y: (v - Double(f.minY)) / Double(f.height))
    }

    private static func hasCamera(of shot: Shot, in doc: SceneMapDoc) -> Bool {
        doc.elements.contains { $0.kind == .camera && $0.shotUID == shot.uid }
    }

    /// Whether a mannequin stands on the map where this one does. Matched on the
    /// ARKit world position, which is the same mannequin's position whatever shot
    /// or map framing it appears in — far more reliable than the on-map
    /// coordinate, which shifts when a later import frames the map differently.
    /// Falls back to the on-map position for markers without one (older imports,
    /// hand-placed).
    private static func mannequinPresent(_ mannequin: CineStagerMapMetadata.Marker, frame: CGRect?,
                                         in doc: SceneMapDoc) -> Bool {
        let p = onBackground(mannequin.u, mannequin.v, frame)
        return doc.elements.contains { element in
            guard element.kind == .character else { return false }
            if let ex = element.worldX, let ez = element.worldZ,
               let mx = mannequin.worldX, let mz = mannequin.worldZ {
                return abs(ex - mx) < sameWorld && abs(ez - mz) < sameWorld
            }
            return abs(element.x - p.x) < sameSpot && abs(element.y - p.y) < sameSpot
        }
    }

    /// Labels unlabeled mannequins with the scene's detected characters (in order),
    /// tinting each with its project color — a best-effort guess the user can fix.
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
