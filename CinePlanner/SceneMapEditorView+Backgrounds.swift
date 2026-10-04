//
//  SceneMapEditorView+Backgrounds.swift
//  CinePlanner
//
//  Where a scene map's background comes from: an image, a 3D scan, a satellite
//  capture, or another scene's map.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    /// Other scenes in the project whose map can be borrowed: an image or satellite
    /// background, or a drawn floor plan (which lives in its own field, not in
    /// `sceneMapBackgroundData`, so it used to be invisible here).
    var scenesWithMap: [Scene] {
        (scene.project?.scenes ?? [])
            .filter { $0.uid != scene.uid && ($0.sceneMapBackgroundData != nil || Self.hasFloorPlan($0)) }
            .sorted { ($0.sceneNumber, $0.suffix) < ($1.sceneNumber, $1.suffix) }
    }

    static func hasFloorPlan(_ other: Scene) -> Bool {
        !FloorPlan.load(from: other.sceneFloorPlanJSON).isEmpty
    }

    func sceneBackgroundLabel(_ other: Scene) -> String {
        let nickname = other.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Scene \(other.sceneNumber)\(other.suffix)"
        return nickname.isEmpty ? base : "\(base) – \(nickname)"
    }

    /// The kind of map a borrow would bring, so the menu can show it at a glance.
    func sceneMapSymbol(_ other: Scene) -> String {
        if other.satelliteCapture != nil { return "globe.europe.africa.fill" }
        if other.sceneMapBackgroundData != nil { return "photo" }
        return "pencil.and.ruler"
    }

    /// Sets a rendered satellite still as the scene-map background (replacing any
    /// image or floor plan), tagging it with the looked-up address. Also seeds the
    /// sun overlay from the captured location — a satellite map is north-up and to
    /// scale, so its coordinate and north (0°) are exactly what the sun needs.
    /// The satellite capture's stored centre, so the picker reopens there.
    var savedSatelliteCoordinate: CLLocationCoordinate2D? {
        guard scene.sceneMapBackgroundIsSatellite,
              let lat = scene.sceneMapSatelliteLat, let lon = scene.sceneMapSatelliteLon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Replaces the satellite background with a new capture (a different zoom
    /// and/or centre) while keeping every marker, arrow, furniture piece and
    /// floor-plan vertex at the same real-world location. Falls back to a plain
    /// set when the old capture's geo-anchor is missing.
    func rescaleSatelliteBackground(_ data: Data, framing new: SatelliteFraming, label: String?) {
        guard let old = satelliteAnchor, new.meters > 0 else {
            setMapBackground(data, framing: new, label: label)
            return
        }
        let coordinate = new.center
        let ratio = old.sizeRatio(to: new)   // normalized sizes scale by this to keep real size
        // A facing is stored against the image, so turning the image has to swing it
        // back by the same amount or every marker ends up pointing somewhere else.
        let turn = old.headingDelta(to: new)
        func remap(_ x: Double, _ y: Double) -> (Double, Double) {
            let p = old.remap(CGPoint(x: x, y: y), to: new)
            return (Double(p.x), Double(p.y))
        }

        for i in doc.elements.indices {
            (doc.elements[i].x, doc.elements[i].y) = remap(doc.elements[i].x, doc.elements[i].y)
            doc.elements[i].rotation -= turn
        }
        for i in doc.furniture.indices {
            (doc.furniture[i].x, doc.furniture[i].y) = remap(doc.furniture[i].x, doc.furniture[i].y)
            doc.furniture[i].rotation -= turn
            doc.furniture[i].width *= ratio
            doc.furniture[i].height *= ratio
        }
        for i in doc.arrows.indices {
            doc.arrows[i].pivots = doc.arrows[i].pivots.map {
                let (x, y) = remap(Double($0.x), Double($0.y)); return CGPoint(x: x, y: y)
            }
        }
        for i in floorPlan.vertices.indices { (floorPlan.vertices[i].x, floorPlan.vertices[i].y) = remap(floorPlan.vertices[i].x, floorPlan.vertices[i].y) }

        // Swap in the new capture, keeping the (remapped) markers + floor plan.
        scene.sceneMapBackgroundData = data
        scene.recordSatelliteCapture(new)
        if let label { scene.sceneMapLocation = label }
        backgroundImage = PlatformImage(data: data)
        doc = scene.storeSceneMap(doc)
        scene.sceneFloorPlanJSON = floorPlan.jsonString
        // Keep the sun anchored to the (possibly re-centred) location, and to the
        // way the map now lies.
        sun.latitude = coordinate.latitude
        sun.longitude = coordinate.longitude
        sun.northOffsetDeg = -new.heading
        saveSun()
        saveContext()
    }

    func setMapBackground(_ data: Data, framing: SatelliteFraming, label: String?) {
        let coordinate = framing.center
        isDrawing = false
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        scene.recordSatelliteCapture(framing)
        scene.sceneMapLocation = label
        scene.sceneMapCameraSizeMeters = nil       // no camera size → default 0.35 m
        scene.sceneMapBackgroundTransform = .init() // satellite: never manually placed
        backgroundImage = PlatformImage(data: data)
        scene.modelContext?.saveReporting()

        // Seed the sun overlay from this location.
        sun.latitude = coordinate.latitude
        sun.longitude = coordinate.longitude
        // The image is turned so `heading` points up, so North sits that far the
        // other way round the dial.
        sun.northOffsetDeg = -framing.heading
        if let label { sun.address = label }
        saveSun()
        // Fill the accurate timezone (for sunrise/sunset) in the background.
        Task {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let tz = try? await CLGeocoder().reverseGeocodeLocation(location).first?.timeZone {
                sun.timeZoneID = tz.identifier
                saveSun()
            }
        }
    }

    /// Copies another scene's background image (and its location tag) onto this
    /// scene, replacing any current image or drawn floor plan.
    func setBackgroundFromScene(_ other: Scene) {
        isDrawing = false
        guard let data = other.sceneMapBackgroundData else {
            // No image or satellite background — borrow the drawn floor plan instead.
            setFloorPlanFromScene(other)
            return
        }
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        if let capture = other.satelliteCapture {
            // Carry the whole capture, not just the flag. Copying only "this is a
            // satellite map" left the scene marked as one with no geo-anchor behind
            // it: no compass, no reframe tool, and nothing to remap markers against.
            scene.recordSatelliteCapture(capture)
            // The background *is* a place, so the sun belongs to it too.
            sun.latitude = capture.center.latitude
            sun.longitude = capture.center.longitude
            sun.northOffsetDeg = -capture.heading
            saveSun()
        } else {
            scene.sceneMapBackgroundIsSatellite = other.sceneMapBackgroundIsSatellite
            scene.sceneMapMetersWide = other.sceneMapMetersWide
        }
        scene.sceneMapLocation = other.sceneMapLocation
        scene.sceneMapCameraSizeMeters = other.sceneMapCameraSizeMeters
        // Carry the source's manual placement (identity for a satellite copy) so a
        // painstakingly aligned image comes across still aligned.
        scene.sceneMapBackgroundTransform = other.satelliteCapture == nil ? other.sceneMapBackgroundTransform : .init()
        backgroundImage = PlatformImage(data: data)
        scene.modelContext?.saveReporting()
    }

    /// Copies another scene's drawn floor plan — the walls and the furniture on them
    /// — onto this scene. A floor plan and an image/satellite background are mutually
    /// exclusive, so this clears the image side the same way starting a fresh drawing
    /// does. The furniture is part of the room; the source scene's blocking (cameras,
    /// actors, arrows) is not, so that stays behind. Both the plan and the furniture
    /// are stored normalized to the same content rect, so they land in register.
    func setFloorPlanFromScene(_ other: Scene) {
        let plan = FloorPlan.load(from: other.sceneFloorPlanJSON)
        guard !plan.isEmpty else { return }
        // Fresh ids so a copied piece is never confused with the original.
        let furniture = SceneMapDoc.load(from: other.sceneMapJSON).furniture
            .map { var f = $0; f.id = UUID(); return f }
        backgroundImage = nil
        scene.sceneMapBackgroundData = nil
        scene.clearSatelliteCapture()
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        scene.sceneMapBackgroundTransform = .init()
        floorPlan = plan
        doc.furniture = furniture
        scene.sceneFloorPlanJSON = other.sceneFloorPlanJSON
        doc = scene.storeSceneMap(doc)
        scene.sceneMapLocation = other.sceneMapLocation
        scene.modelContext?.saveReporting()
    }

    /// Sets (replacing any existing) the scene-map background from an image file.
    /// An image and a drawn floor plan are mutually exclusive backgrounds.
    func setBackground(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let picked = try? Data(contentsOf: url) else { return }
        // A picked plan or photo is kept at map resolution, not as the full original.
        let data = MediaOptimizer.optimizedImage(picked, maxPixels: MediaOptimizer.mapMaxPixels)
        guard let image = PlatformImage(data: data) else { return }
        isDrawing = false
        floorPlan = FloorPlan()
        scene.sceneFloorPlanJSON = nil
        scene.sceneMapBackgroundData = data
        scene.clearSatelliteCapture()
        scene.sceneMapMetersWide = nil
        scene.sceneMapCameraSizeMeters = nil
        scene.sceneMapBackgroundTransform = .init()  // a fresh image starts fitted
        backgroundImage = image
        scene.modelContext?.saveReporting()
    }

    /// 3D file types offered by the model picker.
    var modelContentTypes: [UTType] {
        var types: [UTType] = [.usdz]
        for ext in ["usd", "usdc", "usda", "obj", "dae", "scn", "ply", "stl", "abc"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    /// Renders a top-down, unlit, square image of the picked 3D model and sets it
    /// as the scene-map background (replacing any image or floor plan). Renders off
    /// the main thread so a heavy model doesn't freeze the editor.
    func setBackgroundFromModel(url: URL) {
        // Copy out of the security scope so the render can run on a background task.
        let accessing = url.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "usdz" : url.pathExtension)
        let copied = (try? FileManager.default.copyItem(at: url, to: temp)) != nil
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard copied else { return }

        isRenderingModel = true
        Task.detached {
            let image = ModelTopDownRenderer.topDownImage(from: temp)
            let data = image?.pngRepresentation()
            try? FileManager.default.removeItem(at: temp)
            await MainActor.run {
                isRenderingModel = false
                guard let image, let data else { return }
                isDrawing = false
                floorPlan = FloorPlan()
                scene.sceneFloorPlanJSON = nil
                scene.sceneMapLocation = nil
                scene.sceneMapBackgroundData = data
                scene.clearSatelliteCapture()
                scene.sceneMapMetersWide = nil
                scene.sceneMapCameraSizeMeters = nil
                scene.sceneMapBackgroundTransform = .init()
                backgroundImage = image
                scene.modelContext?.saveReporting()
            }
        }
    }
}
