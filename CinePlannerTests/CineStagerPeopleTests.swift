//
//  CineStagerPeopleTests.swift
//  CinePlannerTests
//
//  The real people CineStager saw come onto the scene map as characters: where
//  each stood in a photo, and in a video where each went — a character at
//  every position, joined by arrows along their route, all one character with
//  one name.
//

import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import CinePlanner

@MainActor
final class CineStagerPeopleTests: XCTestCase {

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

    /// A JPEG with `parts` as its EXIF UserComment, as CineStager writes its maps.
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

    private func shotInScene(characters: [String] = []) -> (Scene, Shot) {
        let scene = Scene(sceneNumber: 4)
        context.insert(scene)
        scene.sceneCharacterNames = characters
        let shot = Shot(shotNumber: 1)
        context.insert(shot)
        shot.scene = scene
        return (scene, shot)
    }

    private func characters(_ scene: Scene) -> [MapElement] {
        SceneMapDoc.load(from: scene.sceneMapJSON).elements.filter { $0.kind == .character }
    }

    /// A video's map: one person walks from the left to the right and on down,
    /// the other stands still.
    private let videoMap = [
        "CameraMap2D:0.5000,0.9000", "CameraWorldXZ:0.000,4.000",
        "ActorsMap2D:0.1000,0.2000;0.8000,0.7000", "ActorsWorldXZ:-4.000,-3.000;3.000,2.000", "ActorsMapRot:90.0;270.0",
        "ActorPathsMap2D:0.1000,0.2000;0.6000,0.2000;0.6000,0.6000#0.8000,0.7000",
        "ActorPathsWorldXZ:-4.000,-3.000;1.000,-3.000;1.000,1.000#3.000,2.000",
        "ActorPathsMapRot:90.0;90.0;180.0#270.0",
        "ActorPathsTime:0.0;4.2;7.9#0.0",
        "ActorPathsRoute:0.3500,0.2500/0.6200,0.4000;0.6100,0.5000#",
    ]

    func testAVideosPeopleAreReadWithTheirPaths() throws {
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(videoMap)))
        XCTAssertEqual(markers.actors.map(\.worldX), [-4, 3])
        XCTAssertEqual(markers.actorPaths.count, 2)
        let walker = markers.actorPaths[0]
        XCTAssertEqual(walker.positions.map(\.u), [0.1, 0.6, 0.6])
        XCTAssertEqual(walker.positions.map(\.rotationDeg), [90, 90, 180])
        XCTAssertEqual(walker.times, [0, 4.2, 7.9])
        XCTAssertEqual(walker.legs, [[CGPoint(x: 0.35, y: 0.25)], [CGPoint(x: 0.62, y: 0.4), CGPoint(x: 0.61, y: 0.5)]])
        XCTAssertEqual(markers.actorPaths[1].positions.count, 1)
        XCTAssertEqual(markers.actorPaths[1].legs, [])
    }

    func testAPhotosPeopleBecomeCharactersOnce() throws {
        let (scene, shot) = shotInScene()
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map([
            "CameraMap2D:0.5000,0.9000",
            "ActorsMap2D:0.2000,0.3000;0.7000,0.4000", "ActorsWorldXZ:-2.000,-1.000;2.000,-0.500",
            "ActorsMapRot:45.0;",
        ])))
        XCTAssertTrue(markers.actorPaths.isEmpty)
        XCTAssertTrue(SceneMapMarkerImport.addMissing(markers, frame: nil, shot: shot, to: scene))
        let people = characters(scene)
        XCTAssertEqual(people.map(\.x), [0.2, 0.7])
        XCTAssertEqual(people.map(\.rotation), [45, 0])
        XCTAssertEqual(people.map(\.worldX), [-2, 2])
        XCTAssertTrue(SceneMapDoc.load(from: scene.sceneMapJSON).arrows.isEmpty)
        XCTAssertFalse(SceneMapMarkerImport.addMissing(markers, frame: nil, shot: shot, to: scene), "already there")
    }

    func testAVideosPeopleMoveAlongArrowsAsOneCharacterEach() throws {
        let (scene, shot) = shotInScene(characters: ["ANNA", "BRAM"])
        let markers = try XCTUnwrap(CineStagerMapMetadata.markers(from: map(videoMap)))
        let frame = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(SceneMapMarkerImport.addMissing(markers, frame: frame, shot: shot, to: scene))

        let doc = SceneMapDoc.load(from: scene.sceneMapJSON)
        let people = doc.elements.filter { $0.kind == .character }
        XCTAssertEqual(people.count, 4)
        XCTAssertEqual(people.map(\.label), ["ANNA", "ANNA", "ANNA", "BRAM"])
        // The walker's arrows: start → middle → end, bending where the route did.
        let arrows = doc.arrows.filter { arrow in people.contains { $0.id == arrow.fromID } }
        XCTAssertEqual(arrows.map(\.fromID), [people[0].id, people[1].id])
        XCTAssertEqual(arrows.map(\.toID), [people[1].id, people[2].id])
        XCTAssertEqual(arrows[0].pivots.count, 1)
        XCTAssertEqual(Double(arrows[0].pivots[0].x), (0.35 - 0.1) / 0.8, accuracy: 1e-9)
        XCTAssertEqual(arrows[1].pivots.count, 2)
        XCTAssertEqual(people[1].x, (0.6 - 0.1) / 0.8, accuracy: 1e-9)

        XCTAssertFalse(SceneMapMarkerImport.addMissing(markers, frame: frame, shot: shot, to: scene), "already there")
        let reference = ShotReference(sortOrder: 0)
        context.insert(reference)
        reference.shot = shot
        reference.mapData = try map(videoMap)
        XCTAssertTrue(SceneMapMarkerImport.allPresent(markers, reference: reference, shot: shot, in: scene))
    }
}
