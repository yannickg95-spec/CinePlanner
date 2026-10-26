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
                          location: reference.mapLocationModel, north: markers.mapNorth, in: scene)
            scene.sceneFloorPlanJSON = nil
            // The place too, unless the scene is already somewhere else.
            if let place = markers.place, !placeConflicts(place, with: scene) {
                setPlace(place, in: scene)
            }
        }
        addMissing(markers, frame: cleanMapFrame(of: markers, onCleanMap: onCleanMap), shot: shot,
                   video: reference, to: scene)
        fitBackgroundToMarkers(in: scene)
        scene.modelContext?.saveReporting()
    }

    /// Makes `background`, a CineStager clean map with `markers` on the marker
    /// map, the scene map's background at CineStager's scale: the square of the
    /// location's world bounds, as wide as their longer side. (Where it can't be
    /// told where the clean map lies, the room rect was taken for it, and its
    /// width for the map's.) Remembers the location and its storey, so another
    /// shot of it adds its markers without a replace prompt, and fixes north
    /// where the map knows it.
    static func setBackground(_ background: Data, reference: ShotReference, markers: CineStagerMapMetadata.Markers?,
                              location: String?, north: Double?, in scene: Scene) {
        scene.sceneMapBackgroundData = background
        scene.clearSatelliteCapture()
        let location = location?.trimmingCharacters(in: .whitespaces)
        scene.sceneMapLocation = (location?.isEmpty == false) ? location : nil
        scene.sceneMapFloor = reference.mapLocationFloor
        setNorth(north, in: scene)
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

    // MARK: - Location, storey, north and place

    /// Whether a map of `location` on `floor` is the same as one of
    /// `otherLocation` on `otherFloor`: the same location and, when both say,
    /// the same storey — a map belongs to one. Captures without a storey (one
    /// storey, or older) go by the name alone.
    static func sameMap(location: String?, floor: Int?, as otherLocation: String?, floor otherFloor: Int?) -> Bool {
        let a = location?.trimmingCharacters(in: .whitespaces) ?? ""
        let b = otherLocation?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !a.isEmpty, a == b else { return false }
        guard let floor, let otherFloor else { return true }
        return floor == otherFloor
    }

    /// Whether the scene's background is `location`'s map, on `floor`.
    static func sceneShows(location: String?, floor: Int?, in scene: Scene) -> Bool {
        sameMap(location: location, floor: floor, as: scene.sceneMapLocation, floor: scene.sceneMapFloor)
    }

    /// Fixes north as the background's own (CineStager's, degrees clockwise from
    /// the top of its map) for the sun and the compass, like a satellite map's:
    /// turned with the background. Nil leaves north to the user again.
    static func setNorth(_ north: Double?, in scene: Scene) {
        var sun = scene.sunSettings
        sun.backgroundNorthDeg = north
        if let north { sun.northOffsetDeg = Compass.normalized(north + scene.sceneMapBackgroundRotation) }
        if sun != scene.sunSettings { scene.sunSettings = sun }
    }

    /// Puts the location's place into the scene's sun settings: its address,
    /// coordinates and time zone.
    static func setPlace(_ place: CineStagerPlace, in scene: Scene) {
        var sun = scene.sunSettings
        if let name = place.name, !name.isEmpty { sun.address = name }
        sun.latitude = place.latitude
        sun.longitude = place.longitude
        if let zone = place.timeZoneIdentifier { sun.timeZoneID = zone }
        if sun != scene.sunSettings { scene.sunSettings = sun }
    }

    /// Whether `place` would replace somewhere else the scene is already set to.
    static func placeConflicts(_ place: CineStagerPlace, with scene: Scene) -> Bool {
        let sun = scene.sunSettings
        guard let lat = sun.latitude, let lon = sun.longitude else { return false }
        return !place.isNear(latitude: lat, longitude: lon)
    }

    /// Brings a location's geography onto the scene, when its background is that
    /// location's map: its north, if the map doesn't know one yet (every map of a
    /// location lies the same way), and its place — handed back instead when it
    /// would replace somewhere else, so the caller can ask first.
    @discardableResult
    static func applyGeography(north: Double?, place: CineStagerPlace?, location: String?, floor: Int?,
                               to scene: Scene) -> CineStagerPlace? {
        guard sceneShows(location: location, floor: floor, in: scene) else { return nil }
        if let north, scene.sunSettings.backgroundNorthDeg == nil, scene.satelliteCapture == nil {
            setNorth(north, in: scene)
        }
        guard let place else { return nil }
        if placeConflicts(place, with: scene) { return place }
        setPlace(place, in: scene)
        return nil
    }

    /// Whether every marker in `markers` (the reference's) is already on the scene map.
    static func allPresent(_ markers: CineStagerMapMetadata.Markers, reference: ShotReference,
                           shot: Shot, in scene: Scene) -> Bool {
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        if !markers.cameraPositions.isEmpty, !hasCamera(of: shot, in: doc) {
            return false
        }
        let frame = cleanMapFrame(of: markers, onCleanMap: reference.mapCleanData != nil)
        let starts = markers.mannequins + markers.actorMovements.compactMap(\.positions.first)
        return starts.allSatisfy { characterPresent($0, frame: frame, in: doc) }
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
    /// position of a video's path, joined by arrows through the route's bends,
    /// each knowing its moment in `video` — and mannequins and people standing
    /// where no one is: for a video, a person at every position of their path,
    /// joined by arrows.
    /// Returns whether anything was added (and stores the scene map when it did).
    @discardableResult
    static func addMissing(_ markers: CineStagerMapMetadata.Markers, frame: CGRect?,
                           shot: Shot, video: ShotReference? = nil, to scene: Scene) -> Bool {
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
                if let video, let times = markers.cameraPath?.times, index < times.count {
                    element.videoTime = times[index]
                    element.videoReferenceUID = video.uid
                }
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
        // Mannequins and people already on the map from an earlier shot stay single.
        let mannequins = markers.mannequins.map { CineStagerMapMetadata.MovementPath(positions: [$0], legs: []) }
        for character in mannequins + markers.actorMovements {
            guard let start = character.positions.first, !characterPresent(start, frame: frame, in: doc) else { continue }
            var previous: UUID?
            for (index, position) in character.positions.enumerated() {
                let p = onBackground(position.u, position.v, frame)
                var element = MapElement(kind: .character, x: p.x, y: p.y)
                element.colorHex = "#4C8DFF"
                element.worldX = position.worldX
                element.worldZ = position.worldZ
                if let rotation = position.rotationDeg { element.rotation = rotation }
                doc.elements.append(element)
                if let previous {
                    doc.arrows.append(MapArrow(fromID: previous, toID: element.id,
                                               pivots: character.legs[index - 1].map { onBackground($0.x, $0.y, frame) }))
                }
                previous = element.id
            }
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

    // MARK: Moments in the video

    /// Where on its shot's video a camera marker stood, by marker: as recorded when
    /// it was placed, or — for markers placed before that was recorded — the
    /// position on a reference's video path it matches (the same world spot, else
    /// the same map spot). Taken in the path's order, so a camera that came back to
    /// a spot gets each visit once.
    static func videoMoments(for shot: Shot, in doc: SceneMapDoc) -> [UUID: (reference: ShotReference, time: Double)] {
        let references = shot.references.sorted { $0.sortOrder < $1.sortOrder }
        var moments: [UUID: (reference: ShotReference, time: Double)] = [:]
        var unmatched: [MapElement] = []
        for camera in doc.elements where camera.kind == .camera && camera.shotUID == shot.uid {
            if let time = camera.videoTime, let uid = camera.videoReferenceUID,
               let reference = references.first(where: { $0.uid == uid }) {
                moments[camera.id] = (reference, time)
            } else {
                unmatched.append(camera)
            }
        }
        for reference in references where !unmatched.isEmpty {
            guard let path = videoPath(of: reference) else { continue }
            var taken = Set<Int>()
            unmatched.removeAll { camera in
                let hit = path.path.positions.indices.first { i in
                    guard !taken.contains(i) else { return false }
                    let position = path.path.positions[i]
                    if let ex = camera.worldX, let ez = camera.worldZ, let px = position.worldX, let pz = position.worldZ {
                        return abs(ex - px) < sameWorld && abs(ez - pz) < sameWorld
                    }
                    let p = onBackground(position.u, position.v, path.frame)
                    return abs(camera.x - p.x) < 0.01 && abs(camera.y - p.y) < 0.01
                }
                guard let hit else { return false }
                taken.insert(hit)
                moments[camera.id] = (reference, path.path.times[hit])
                return true
            }
        }
        return moments
    }

    /// A reference's camera path with its moments, and where its background lies
    /// on the marker map — read once per reference (its map's EXIF), as the card
    /// asking for it redraws with every pointer move.
    private static func videoPath(of reference: ShotReference) -> (path: CineStagerMapMetadata.MovementPath, frame: CGRect?)? {
        if let cached = pathCache[reference.uid] { return cached }
        var found: (path: CineStagerMapMetadata.MovementPath, frame: CGRect?)?
        if let markers = markers(for: reference), let path = markers.cameraPath,
           path.times.count == path.positions.count {
            found = (path, cleanMapFrame(of: markers, onCleanMap: reference.mapCleanData != nil))
        }
        pathCache[reference.uid] = .some(found)
        return found
    }

    private static var pathCache: [String: (path: CineStagerMapMetadata.MovementPath, frame: CGRect?)?] = [:]

    private static func hasCamera(of shot: Shot, in doc: SceneMapDoc) -> Bool {
        doc.elements.contains { $0.kind == .camera && $0.shotUID == shot.uid }
    }

    /// Whether a character stands on the map where this mannequin or person
    /// does. Matched on the ARKit world position, which is the same spot
    /// whatever shot or map framing it appears in — far more reliable than the
    /// on-map coordinate, which shifts when a later import frames the map
    /// differently. Falls back to the on-map position for markers without one
    /// (older imports, hand-placed).
    private static func characterPresent(_ mannequin: CineStagerMapMetadata.Marker, frame: CGRect?,
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

    /// Labels unlabeled characters with the scene's detected characters (in
    /// order), tinting each with its project color — a best-effort guess the user
    /// can fix. Characters joined by arrows are one character moving: they share
    /// a name (the one already given to any of them, else the next).
    private static func assignSceneCharacters(_ doc: inout SceneMapDoc, scene: Scene) {
        let names = scene.sceneCharacterNames
        guard !names.isEmpty else { return }
        let projectChars = scene.project?.scriptCharacters ?? []
        func color(for name: String) -> String {
            projectChars.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.colorHex ?? "#4C8DFF"
        }
        let characters = Set(doc.elements.filter { $0.kind == .character }.map(\.id))
        var joined: [UUID: [UUID]] = [:]
        for arrow in doc.arrows where characters.contains(arrow.fromID) && characters.contains(arrow.toID) {
            joined[arrow.fromID, default: []].append(arrow.toID)
            joined[arrow.toID, default: []].append(arrow.fromID)
        }
        var next = 0
        var done = Set<UUID>()
        for element in doc.elements where element.kind == .character && !done.contains(element.id) {
            // The character's markers: this one and all joined to it.
            var group: [UUID] = [], queue = [element.id]
            while let id = queue.popLast() {
                guard done.insert(id).inserted else { continue }
                group.append(id)
                queue += joined[id] ?? []
            }
            let indices = group.compactMap { id in doc.elements.firstIndex { $0.id == id } }
            guard indices.contains(where: { doc.elements[$0].label.isEmpty }) else { continue }
            let named = indices.first { !doc.elements[$0].label.isEmpty }
            let name: String, colorHex: String
            if let named {
                name = doc.elements[named].label
                colorHex = doc.elements[named].colorHex
            } else {
                guard next < names.count else { continue }
                name = names[next]
                colorHex = color(for: name)
                next += 1
            }
            for index in indices where doc.elements[index].label.isEmpty {
                doc.elements[index].label = name
                doc.elements[index].colorHex = colorHex
            }
        }
    }
}
