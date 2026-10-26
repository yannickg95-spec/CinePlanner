//
//  CineStagerGeographyTests.swift
//  CinePlannerTests
//
//  What CineStager 6.3 sends along with a capture: the camera's height above
//  the floor, the lens's stop and focus, an anamorphic squeeze, and where the
//  location lies in the world — its storey, its north and its place. A map
//  belongs to one storey; north is fixed by the map and turns with it; a place
//  is only put on a scene that isn't somewhere else already.
//

import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import CinePlanner

@MainActor
final class CineStagerGeographyTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Project.self, Episode.self, ScriptVersion.self, Scene.self, Shot.self,
            ShotReference.self, ShotCustomInfo.self, ShootingDay.self, ScheduleEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// A JPEG with `parts` as its EXIF UserComment (and any other EXIF), as
    /// CineStager writes its photos and maps.
    private func jpeg(_ parts: [String], exif extra: [String: Any] = [:], caption: String? = nil) throws -> Data {
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var exif = extra
        exif[kCGImagePropertyExifUserComment as String] = parts.joined(separator: " | ")
        var properties: [String: Any] = [kCGImagePropertyExifDictionary as String: exif]
        if let caption {
            properties[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCCaptionAbstract as String: caption]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - A photo

    func testAPhotoGivesTheHeightAboveTheFloorAndTheLensSettings() throws {
        let photo = try jpeg(["Height:155.0cm", "Camera Height Above Floor:110.2cm",
                              "T-Stop:3.1", "F-Number:2.8", "Focus Distance:3.25m", "Horizontal FOV:56.74"],
                             exif: [kCGImagePropertyExifFNumber as String: 2.8,
                                    kCGImagePropertyExifSubjectDistance as String: 3.25],
                             caption: "Camera: Arri Alexa Mini LF 4.3K LF 16:9 • 33mm • T3.1 (f/2.8) • Focus 3.2 m")
        let metadata = try XCTUnwrap(EXIFExtractor.extractMetadata(from: photo))
        // Above the floor, not from where the AR session began.
        XCTAssertEqual(metadata.height, 110.2)
        XCTAssertEqual(metadata.fNumber, 2.8)
        XCTAssertEqual(metadata.tStop, 3.1)
        XCTAssertEqual(metadata.focusDistance, 3.25)
        XCTAssertEqual(metadata.horizontalFOV, 56.74)
        XCTAssertEqual(metadata.stopText, "T3.1 (f/2.8)")
        XCTAssertEqual(metadata.focusText, "3.2 m")
        // No framelines in that caption: the stop and focus aren't taken for them.
        XCTAssertNil(metadata.framelines)
    }

    /// A video's height above the floor is only in its map; an older map has
    /// just the session-relative height, which doesn't count as one.
    func testAMapSaysTheHeightAboveTheFloorOnlyWhenItKnowsIt() throws {
        let newer = try XCTUnwrap(EXIFExtractor.extractMetadata(
            from: try jpeg(["CameraMap2D:0.5,0.5", "Height:155.0cm", "Camera Height Above Floor:98.0cm"])))
        XCTAssertEqual(newer.heightAboveFloor, 98)
        let older = try XCTUnwrap(EXIFExtractor.extractMetadata(from: try jpeg(["CameraMap2D:0.5,0.5", "Height:155.0cm"])))
        XCTAssertNil(older.heightAboveFloor)
        XCTAssertEqual(older.height, 155)
    }

    func testARealCamerasPhotoGivesItsStopAndFocus() throws {
        let photo = try jpeg([], exif: [kCGImagePropertyExifFNumber as String: 4.0,
                                        kCGImagePropertyExifSubjectDistance as String: 150.0])
        let metadata = try XCTUnwrap(EXIFExtractor.extractMetadata(from: photo))
        XCTAssertEqual(metadata.stopText, "f/4")
        XCTAssertEqual(metadata.focusText, "150 m")
    }

    func testFramelinesAreOnlyARatio() {
        XCTAssertEqual(EXIFExtractor.parseFramelines(from: "Camera: Arri Alexa 35 4.6K 16:9 • 2.39 • 35mm • T2.8 (f/2.5)"), "2.39")
        XCTAssertEqual(EXIFExtractor.parseFramelines(from: "Camera: RED V-Raptor 8K VV • 1.85:1 • 50mm"), "1.85:1")
        XCTAssertEqual(EXIFExtractor.parseFramelines(from: "Camera: Sony FX6 • 16:9 • 24mm"), "16:9")
        for caption in ["Camera: Arri Alexa 35 4.6K 16:9 • 40mm • 2× anamorphic (1.5× lens, 1.33× front)",
                        "Camera: Arri Alexa 35 4.6K 16:9 • 40mm • T2.8 (f/2.5) • Focus 3.2 m",
                        "Camera: Arri Alexa 35 4.6K 16:9 • 40mm • Preset: Master Primes"] {
            XCTAssertNil(EXIFExtractor.parseFramelines(from: caption), caption)
        }
    }

    func testLensSettingsReadAsOnSet() {
        XCTAssertEqual(LensSettingsText.line(fNumber: 2.8, tStop: 3.1, focusDistance: 3.25, squeeze: 2,
                                             adapter: "1.33× front"),
                       "T3.1 (f/2.8) · Focus 3.2 m · 2× anamorphic (1.33× front)")
        XCTAssertEqual(LensSettingsText.line(fNumber: 5.6, tStop: nil, focusDistance: nil, squeeze: nil, adapter: nil),
                       "f/5.6")
        XCTAssertNil(LensSettingsText.line(fNumber: nil, tStop: nil, focusDistance: nil, squeeze: 1, adapter: nil))
    }

    func testARearAdapterLengthensTheFocalLength() {
        XCTAssertEqual(SceneMapEditorView.rearAdapterFactor("2× rear"), 2)
        XCTAssertEqual(SceneMapEditorView.rearAdapterFactor("1.33× front"), 1)
        XCTAssertEqual(SceneMapEditorView.rearAdapterFactor(nil), 1)
    }

    // MARK: - A map

    func testAMapGivesItsNorthPlaceAndStorey() throws {
        let map = try jpeg(["CameraMap2D:0.5000,0.5000", "Location Model:Kelder",
                            "Location Latitude:52.366033", "Location Longitude:4.916792",
                            "Location Time Zone:Europe/Amsterdam", "Location Place:Plantage 12, Amsterdam",
                            "MapNorth:14.0", "Location Floor:1", "Location Floor Name:Floor 1"])
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map))
        XCTAssertEqual(markers.mapNorth, 14)
        XCTAssertEqual(markers.floor, 1)
        XCTAssertEqual(markers.place, CineStagerPlace(latitude: 52.366033, longitude: 4.916792,
                                                      timeZoneIdentifier: "Europe/Amsterdam",
                                                      name: "Plantage 12, Amsterdam"))
        let metadata = try XCTUnwrap(EXIFExtractor.extractMetadata(from: map))
        XCTAssertEqual(metadata.locationFloor, 1)
        XCTAssertEqual(metadata.locationFloorName, "Floor 1")
        XCTAssertTrue(metadata.mapDisplayItems.contains { $0.label == "Floor" && $0.value == "Floor 1" })
    }

    func testAMapBelongsToOneStorey() {
        XCTAssertTrue(SceneMapMarkerImport.sameMap(location: "Kelder", floor: 1, as: "Kelder", floor: 1))
        XCTAssertFalse(SceneMapMarkerImport.sameMap(location: "Kelder", floor: 1, as: "Kelder", floor: 0))
        // Without a storey (one storey, or an older capture) the name decides.
        XCTAssertTrue(SceneMapMarkerImport.sameMap(location: "Kelder", floor: nil, as: "Kelder", floor: 0))
        XCTAssertFalse(SceneMapMarkerImport.sameMap(location: "Kelder", floor: 1, as: "Zolder", floor: 1))
        XCTAssertFalse(SceneMapMarkerImport.sameMap(location: nil, floor: nil, as: nil, floor: nil))
    }

    // MARK: - On the scene map

    func testSettingTheBackgroundFixesItsNorthAndStorey() {
        let scene = Scene(sceneNumber: 1)
        context.insert(scene)
        let reference = ShotReference(sortOrder: 0)
        reference.mapLocationFloor = 1
        SceneMapMarkerImport.setBackground(Data([1]), reference: reference, markers: nil,
                                           location: "Kelder", north: 14, in: scene)
        XCTAssertEqual(scene.sceneMapLocation, "Kelder")
        XCTAssertEqual(scene.sceneMapFloor, 1)
        XCTAssertEqual(scene.sunSettings.backgroundNorthDeg, 14)
        XCTAssertEqual(scene.sunSettings.northOffsetDeg, 14)
        XCTAssertEqual(scene.mapNorthOffset, 14)
    }

    func testNorthTurnsWithTheBackground() {
        let scene = Scene(sceneNumber: 1)
        context.insert(scene)
        var sun = scene.sunSettings
        sun.backgroundNorthDeg = 14
        scene.sunSettings = sun
        scene.sceneMapBackgroundRotation = 30
        XCTAssertEqual(scene.mapNorthOffset, 44)
        // Replacing the background forgets the old map's north.
        scene.clearSatelliteCapture()
        XCTAssertNil(scene.sunSettings.backgroundNorthDeg)
    }

    func testThePlaceComesAlongUnlessTheSceneIsElsewhere() {
        let scene = Scene(sceneNumber: 1)
        context.insert(scene)
        scene.sceneMapLocation = "Kelder"
        let kelder = CineStagerPlace(latitude: 52.366033, longitude: 4.916792,
                                     timeZoneIdentifier: "Europe/Amsterdam", name: "Plantage 12, Amsterdam")
        // No place yet: it's simply set, with north.
        XCTAssertNil(SceneMapMarkerImport.applyGeography(north: 14, place: kelder, location: "Kelder", floor: nil, to: scene))
        XCTAssertEqual(scene.sunSettings.address, "Plantage 12, Amsterdam")
        XCTAssertEqual(scene.sunSettings.timeZoneID, "Europe/Amsterdam")
        XCTAssertEqual(scene.sunSettings.backgroundNorthDeg, 14)

        // The same place again: no question.
        XCTAssertNil(SceneMapMarkerImport.applyGeography(north: 14, place: kelder, location: "Kelder", floor: nil, to: scene))

        // Somewhere else: handed back to ask first, nothing changed yet.
        let lisbon = CineStagerPlace(latitude: 38.7223, longitude: -9.1393, timeZoneIdentifier: "Europe/Lisbon", name: "Lisbon")
        XCTAssertEqual(SceneMapMarkerImport.applyGeography(north: 14, place: lisbon, location: "Kelder", floor: nil, to: scene),
                       lisbon)
        XCTAssertEqual(scene.sunSettings.address, "Plantage 12, Amsterdam")

        // Not this location's map: nothing at all.
        XCTAssertNil(SceneMapMarkerImport.applyGeography(north: 90, place: lisbon, location: "Zolder", floor: nil, to: scene))
        XCTAssertEqual(scene.sunSettings.backgroundNorthDeg, 14)
    }

    // MARK: - Kept

    func testTheNewFieldsAreKeptByADuplicate() {
        let reference = ShotReference(sortOrder: 0)
        reference.fNumber = 2.8
        reference.tStop = 3.1
        reference.focusDistance = 3.25
        reference.horizontalFOV = 56.74
        reference.anamorphicSqueeze = 2
        reference.anamorphicAdapter = "1.33× front"
        reference.mapLocationFloor = 1
        reference.mapLocationFloorName = "Floor 1"
        let copy = reference.duplicate()
        XCTAssertEqual(copy.lensSettingsLine, reference.lensSettingsLine)
        XCTAssertEqual(copy.horizontalFOV, 56.74)
        XCTAssertEqual(copy.mapLocationFloor, 1)
        XCTAssertEqual(copy.mapLocationFloorName, "Floor 1")
    }
}
