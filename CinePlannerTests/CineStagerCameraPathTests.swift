//
//  CineStagerCameraPathTests.swift
//  CinePlannerTests
//
//  A CineStager video whose camera travelled lands on the scene map as a camera
//  at every position it stood at, joined in order by arrows that bend along its
//  route — placed on the clean map like every other marker, the import and the
//  reference card's "Add to Scene Map" alike. A photo still gives one camera.
//

import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import CinePlanner

@MainActor
final class CineStagerCameraPathTests: XCTestCase {

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

    // MARK: - Helpers

    /// A JPEG with `comment` as its EXIF UserComment, as CineStager writes its maps.
    private func map(_ parts: [String]) throws -> Data {
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let exif = [kCGImagePropertyExifUserComment as String: parts.joined(separator: " | ")]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary as String: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A video's map: three positions, the last leg bending twice.
    private let videoMap = [
        "CameraMap2D:0.2000,0.8000", "CameraWorldXZ:0.000,3.000", "CameraMapRot:0.0",
        "CameraPathMap2D:0.2000,0.8000;0.2000,0.5000;0.7000,0.4000",
        "CameraPathWorldXZ:0.000,3.000;0.000,1.200;-3.000,0.250",
        "CameraPathMapRot:0.0;0.0;280.9",
        "CameraPathTime:0.0;4.0;9.6",
        "CameraPathRoute:/0.4000,0.4500;0.6000,0.4200",
        "MannequinsMap2D:0.5000,0.2000", "MannequinsWorldXZ:0.000,-2.500", "MannequinsMapRot:180.0",
        "Type:Top Down Map",
    ]

    private func shotInScene() -> (Scene, Shot) {
        let scene = Scene(sceneNumber: 12)
        context.insert(scene)
        let shot = Shot(shotNumber: 3)
        context.insert(shot)
        shot.scene = scene
        return (scene, shot)
    }

    private func cameras(_ doc: SceneMapDoc) -> [MapElement] { doc.elements.filter { $0.kind == .camera } }

    private func assertClose(_ values: [Double], _ expected: [Double], accuracy: Double = 1e-9, line: UInt = #line) {
        XCTAssertEqual(values.count, expected.count, line: line)
        for (value, want) in zip(values, expected) { XCTAssertEqual(value, want, accuracy: accuracy, line: line) }
    }

    // MARK: - Reading the map

    func testAVideosMapGivesEveryPositionAndTheBendsOfEveryLeg() throws {
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(videoMap)))
        let path = try XCTUnwrap(markers.cameraPath)
        XCTAssertEqual(path.positions.map(\.u), [0.2, 0.2, 0.7])
        XCTAssertEqual(path.positions.map(\.v), [0.8, 0.5, 0.4])
        XCTAssertEqual(path.positions.map(\.rotationDeg), [0, 0, 280.9])
        XCTAssertEqual(path.positions.map(\.worldX), [0, 0, -3])
        XCTAssertEqual(path.legs, [[], [CGPoint(x: 0.4, y: 0.45), CGPoint(x: 0.6, y: 0.42)]])
        XCTAssertEqual(markers.camera?.u, 0.2)   // the start, as older readers see it
        XCTAssertEqual(markers.cameraPositions.count, 3)
    }

    func testAPhotosMapHasOneCameraAndNoPath() throws {
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(["CameraMap2D:0.5000,0.5000", "CameraMapRot:90.0"])))
        XCTAssertNil(markers.cameraPath)
        XCTAssertEqual(markers.cameraPositions.map(\.rotationDeg), [90])
    }

    func testAPathWithoutRouteHasStraightLegsAndOnePositionIsNoPath() throws {
        let straight = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(["CameraPathMap2D:0.1,0.1;0.5,0.5;0.9,0.1"])))
        XCTAssertEqual(straight.cameraPath?.legs, [[], []])
        let one = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(["CameraMap2D:0.1,0.1", "CameraPathMap2D:0.1,0.1"])))
        XCTAssertNil(one.cameraPath)
    }

    // MARK: - Placing it on the scene map

    func testAVideoBecomesACameraPerPositionJoinedByArrowsWithinTheRoom() throws {
        let (scene, shot) = shotInScene()
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(videoMap)))
        let room = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)

        XCTAssertTrue(SceneMapMarkerImport.addMissing(markers, frame: room, shot: shot, to: scene))
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        let cameras = cameras(doc)
        XCTAssertEqual(cameras.count, 3)
        XCTAssertTrue(cameras.allSatisfy { $0.shotUID == shot.uid && $0.label == shot.displayNumber })
        assertClose(cameras.map(\.x), [0.125, 0.125, 0.75])        // (u − 0.1) / 0.8
        XCTAssertEqual(cameras.map(\.rotation), [0, 0, 280.9])
        XCTAssertEqual(cameras.map(\.worldX), [0, 0, -3])

        XCTAssertEqual(doc.arrows.count, 2)
        XCTAssertEqual(doc.arrows.map(\.fromID), [cameras[0].id, cameras[1].id])
        XCTAssertEqual(doc.arrows.map(\.toID), [cameras[1].id, cameras[2].id])
        XCTAssertEqual(doc.arrows[0].pivots, [])
        assertClose(doc.arrows[1].pivots.map { Double($0.x) }, [0.375, 0.625])
        assertClose(doc.arrows[1].pivots.map { Double($0.y) }, [0.45, 0.42])
        XCTAssertEqual(doc.elements.filter { $0.kind == .character }.count, 1)

        // Again: all there already, nothing doubles.
        XCTAssertFalse(SceneMapMarkerImport.addMissing(markers, frame: room, shot: shot, to: scene))
        XCTAssertEqual(SceneMapDoc.load(from: scene.sceneMapJSON).elements.count, 4)
    }

    func testAPhotoStillGivesOneCamera() throws {
        let (scene, shot) = shotInScene()
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(["CameraMap2D:0.5000,0.5000"])))
        SceneMapMarkerImport.addMissing(markers, frame: nil, shot: shot, to: scene)
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        XCTAssertEqual(cameras(doc).count, 1)
        XCTAssertTrue(doc.arrows.isEmpty)
    }

    func testARouteBeyondTheRoomZoomsTheBackgroundOut() throws {
        let (scene, shot) = shotInScene()
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map([
            "CameraPathMap2D:0.2,0.5;0.8,0.5", "CameraPathRoute:0.5,1.4",
        ])))
        SceneMapMarkerImport.addMissing(markers, frame: nil, shot: shot, to: scene)
        SceneMapMarkerImport.fitBackgroundToMarkers(in: scene)
        XCTAssertLessThan(scene.sceneMapBackgroundTransform.scale, 1)
    }

    /// The reference card's "Add to Scene Map" puts the clean map up and places
    /// the markers on it, as the import does.
    func testAddingFromTheReferencePlacesTheMarkersOnTheCleanMap() throws {
        let (scene, shot) = shotInScene()
        let reference = ShotReference(sortOrder: 0)
        context.insert(reference)
        reference.shot = shot
        reference.mapData = try map(videoMap + ["CleanMapRect2D:0.1000,0.1000,0.9000,0.9000",
                                                "Location Width:6.00m", "Location Length:8.00m"])
        reference.mapCleanData = Data([1, 2, 3])
        reference.mapLocationWidth = 6
        reference.mapLocationLength = 8
        let markers = try XCTUnwrap(SceneMapMarkerImport.markers(for: reference))
        XCTAssertFalse(SceneMapMarkerImport.allPresent(markers, reference: reference, shot: shot, in: scene))

        SceneMapMarkerImport.addToSceneMap(markers, reference: reference, shot: shot, to: scene)
        XCTAssertEqual(scene.sceneMapBackgroundData, Data([1, 2, 3]))
        XCTAssertEqual(scene.sceneMapMetersWide, 8)   // the location's longer side
        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        assertClose(cameras(doc).map(\.x), [0.125, 0.125, 0.75])
        assertClose(cameras(doc).map(\.y), [0.875, 0.5, 0.375])
        XCTAssertEqual(doc.arrows.count, 2)
        XCTAssertTrue(SceneMapMarkerImport.allPresent(markers, reference: reference, shot: shot, in: scene))
    }

    // MARK: - Where the clean map lies

    /// A map from before CineStager recorded it, of a turned room (its world
    /// bounds land larger than the map): worked out from the markers' world
    /// positions, it's the whole map — as it is when everything is in the room —
    /// not the room rect.
    func testAnOlderMapOfATurnedRoomFindsItsCleanMap() throws {
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map([
            "Location Width:6.85m", "Location Length:7.60m",
            "RoomRectMap2D:-0.1639,-0.1488,1.1639,1.1488",
            "CameraMap2D:0.2107,0.4628", "CameraWorldXZ:0.450,1.359",
            "MannequinsMap2D:0.4500,0.5648", "MannequinsWorldXZ:2.083,0.245",
            "CameraPathMap2D:0.2107,0.4628;0.4284,0.6794;0.3781,0.6466",
            "CameraPathWorldXZ:0.450,1.359;2.727,0.852;2.312,1.040",
        ])))
        XCTAssertEqual(markers.locationSpan, 7.6)
        let clean = try XCTUnwrap(markers.cleanMapRect)
        assertClose([clean.minX, clean.minY, clean.maxX, clean.maxY].map { Double($0) }, [0, 0, 1, 1], accuracy: 0.002)
    }

    func testAnOlderMapWithoutWorldPositionsKeepsTheRoomRect() throws {
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map([
            "Location Width:6.00m", "Location Length:8.00m",
            "RoomRectMap2D:0.1000,0.0000,0.9000,1.0000", "CameraMap2D:0.5000,0.5000",
        ])))
        XCTAssertNil(markers.cleanMapRect)
        XCTAssertEqual(SceneMapMarkerImport.cleanMapFrame(of: markers, onCleanMap: true), markers.roomRect)
        XCTAssertNil(SceneMapMarkerImport.cleanMapFrame(of: markers, onCleanMap: false))
    }
}
