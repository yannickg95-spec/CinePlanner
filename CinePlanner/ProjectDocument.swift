//
//  ProjectDocument.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static var cineplannerProject: UTType {
        UTType(importedAs: "com.yourcompany.cineplanner.project")
    }
}

struct ProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.cineplannerProject] }
    
    var project: Project
    
    init(filmName: String = "Untitled Film") {
        self.project = Project(filmName: filmName)
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        let decoder = JSONDecoder()
        let container = try decoder.decode(ProjectContainer.self, from: data)
        self.project = container.toProject()
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let container = ProjectContainer(from: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(container)
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Codable Container Types

struct ProjectContainer: Codable {
    var filmName: String
    var createdDate: Date
    var sceneColumnWidth: Double
    var shotColumnWidth: Double
    var scenes: [SceneContainer]
    
    init(from project: Project) {
        self.filmName = project.filmName
        self.createdDate = project.createdDate
        self.sceneColumnWidth = project.sceneColumnWidth
        self.shotColumnWidth = project.shotColumnWidth
        self.scenes = project.scenes.map { SceneContainer(from: $0) }
    }
    
    func toProject() -> Project {
        let project = Project(filmName: filmName, createdDate: createdDate)
        project.sceneColumnWidth = sceneColumnWidth
        project.shotColumnWidth = shotColumnWidth
        project.scenes = scenes.map { sceneContainer in
            let scene = sceneContainer.toScene()
            scene.project = project
            return scene
        }
        return project
    }
}

struct SceneContainer: Codable {
    var sceneNumber: Int
    var shots: [ShotContainer]
    
    init(from scene: Scene) {
        self.sceneNumber = scene.sceneNumber
        self.shots = scene.shots.map { ShotContainer(from: $0) }
    }
    
    func toScene() -> Scene {
        let scene = Scene(sceneNumber: sceneNumber)
        scene.shots = shots.map { shotContainer in
            let shot = shotContainer.toShot()
            shot.scene = scene
            return shot
        }
        return scene
    }
}

struct ShotContainer: Codable {
    var shotNumber: Int
    var shotInformation: String
    var photo1Data: Data?
    var photo2Data: Data?
    
    init(from shot: Shot) {
        self.shotNumber = shot.shotNumber
        self.shotInformation = shot.shotInformation
        self.photo1Data = shot.primaryImageData
        self.photo2Data = shot.primaryMapData
    }
    
    func toShot() -> Shot {
        let shot = Shot(shotNumber: shotNumber, shotInformation: shotInformation)
        // Rebuild as a reference; the fixed slots are legacy.
        if photo1Data != nil || photo2Data != nil {
            let reference = ShotReference(sortOrder: 0)
            reference.imageData = photo1Data
            reference.mapData = photo2Data
            reference.shot = shot
        }
        return shot
    }
}
