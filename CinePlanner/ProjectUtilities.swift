//
//  ProjectUtilities.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import Foundation
import SwiftUI

/// Utilities for working with CineStager projects
enum ProjectUtilities {
    
    /// Generate a summary of a project
    static func generateProjectSummary(for project: Project) -> String {
        let sceneCount = project.scenes.count
        let shotCount = project.scenes.reduce(0) { $0 + $1.shots.count }
        let photoCount = project.scenes.reduce(0) { sceneTotal, scene in
            sceneTotal + scene.shots.reduce(0) { shotTotal, shot in
                var count = 0
                count += shot.attachedPhotoCount
                return shotTotal + count
            }
        }
        
        return """
        Film: \(project.filmName)
        Created: \(project.createdDate.formatted(date: .abbreviated, time: .omitted))
        Scenes: \(sceneCount)
        Shots: \(shotCount)
        Photos: \(photoCount)
        """
    }
    
    /// Export project data as CSV
    static func exportToCSV(project: Project) -> String {
        var csv = "Scene,Shot,Information,Has Photo 1,Has Photo 2\n"
        
        for scene in project.scenes.sorted(by: { $0.sceneNumber < $1.sceneNumber }) {
            for shot in scene.shots.sorted(by: { $0.shotNumber < $1.shotNumber }) {
                let info = shot.shotInformation.replacingOccurrences(of: "\n", with: " ")
                let hasPhoto1 = shot.primaryImageData != nil ? "Yes" : "No"
                let hasPhoto2 = shot.primaryMapData != nil ? "Yes" : "No"
                csv += "\(scene.sceneNumber),\(shot.shotNumber),\"\(info)\",\(hasPhoto1),\(hasPhoto2)\n"
            }
        }
        
        return csv
    }
    
    /// Calculate project statistics
    static func calculateStatistics(for project: Project) -> ProjectStatistics {
        let sceneCount = project.scenes.count
        let shotCount = project.scenes.reduce(0) { $0 + $1.shots.count }
        
        var totalPhotos = 0
        var shotsWithBothPhotos = 0
        var shotsWithOnePhoto = 0
        var shotsWithNoPhotos = 0
        var totalInfoLength = 0
        
        for scene in project.scenes {
            for shot in scene.shots {
                let photoCount = shot.attachedPhotoCount
                totalPhotos += photoCount
                
                switch photoCount {
                case 2:
                    shotsWithBothPhotos += 1
                case 1:
                    shotsWithOnePhoto += 1
                default:
                    shotsWithNoPhotos += 1
                }
                
                totalInfoLength += shot.shotInformation.count
            }
        }
        
        return ProjectStatistics(
            sceneCount: sceneCount,
            shotCount: shotCount,
            totalPhotos: totalPhotos,
            shotsWithBothPhotos: shotsWithBothPhotos,
            shotsWithOnePhoto: shotsWithOnePhoto,
            shotsWithNoPhotos: shotsWithNoPhotos,
            averageInfoLength: shotCount > 0 ? totalInfoLength / shotCount : 0
        )
    }
    
    /// Find missing shot numbers in a scene
    static func findMissingShots(in scene: Scene) -> [Int] {
        guard !scene.shots.isEmpty else { return [] }
        
        let shotNumbers = scene.shots.map { $0.shotNumber }.sorted()
        guard let min = shotNumbers.first, let max = shotNumbers.last else { return [] }
        
        let expectedRange = Set(min...max)
        let actualNumbers = Set(shotNumbers)
        
        return Array(expectedRange.subtracting(actualNumbers)).sorted()
    }
    
    /// Find duplicate shot numbers in a scene
    static func findDuplicateShots(in scene: Scene) -> [Int] {
        let shotNumbers = scene.shots.map { $0.shotNumber }
        var seen = Set<Int>()
        var duplicates = Set<Int>()
        
        for number in shotNumbers {
            if seen.contains(number) {
                duplicates.insert(number)
            } else {
                seen.insert(number)
            }
        }
        
        return Array(duplicates).sorted()
    }
}

/// Statistics about a project
struct ProjectStatistics {
    let sceneCount: Int
    let shotCount: Int
    let totalPhotos: Int
    let shotsWithBothPhotos: Int
    let shotsWithOnePhoto: Int
    let shotsWithNoPhotos: Int
    let averageInfoLength: Int
    
    var completionPercentage: Double {
        guard shotCount > 0 else { return 0 }
        return Double(shotsWithBothPhotos) / Double(shotCount) * 100
    }
}

/// View for displaying project statistics
struct ProjectStatisticsView: View {
    let project: Project
    
    var statistics: ProjectStatistics {
        ProjectUtilities.calculateStatistics(for: project)
    }
    
    var body: some View {
        Form {
            Section("Overview") {
                LabeledContent("Film Name", value: project.filmName)
                LabeledContent("Created", value: project.createdDate.formatted(date: .long, time: .omitted))
                LabeledContent("Scenes", value: "\(statistics.sceneCount)")
                LabeledContent("Shots", value: "\(statistics.shotCount)")
            }
            
            Section("Photos") {
                LabeledContent("Total Photos", value: "\(statistics.totalPhotos)")
                LabeledContent("Complete Shots", value: "\(statistics.shotsWithBothPhotos)")
                LabeledContent("Partial Shots", value: "\(statistics.shotsWithOnePhoto)")
                LabeledContent("Empty Shots", value: "\(statistics.shotsWithNoPhotos)")
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Completion")
                    ProgressView(value: statistics.completionPercentage, total: 100)
                    Text("\(Int(statistics.completionPercentage))% of shots have both photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Shot Information") {
                LabeledContent("Average Length", value: "\(statistics.averageInfoLength) characters")
            }
            
            Section("Actions") {
                Button {
                    let csv = ProjectUtilities.exportToCSV(project: project)
                    shareCSV(csv)
                } label: {
                    Label("Export to CSV", systemImage: "square.and.arrow.up")
                }
                
                Button {
                    let summary = ProjectUtilities.generateProjectSummary(for: project)
                    shareSummary(summary)
                } label: {
                    Label("Share Summary", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Statistics")
    }
    
    private func shareCSV(_ csv: String) {
        #if os(iOS)
        let activityVC = UIActivityViewController(activityItems: [csv], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.filmName).csv"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
    
    private func shareSummary(_ summary: String) {
        #if os(iOS)
        let activityVC = UIActivityViewController(activityItems: [summary], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        #endif
    }
}

#Preview {
    @Previewable @State var project: Project = {
        let project = Project(filmName: "Sample Film")
        let scene1 = Scene(sceneNumber: 1)
        let shot1 = Shot(shotNumber: 1, shotInformation: "Wide shot of the location")
        scene1.shots.append(shot1)
        project.scenes.append(scene1)
        return project
    }()
    
    NavigationStack {
        ProjectStatisticsView(project: project)
    }
}
