//
//  ExportView.swift
//  CinePlanner
//
//  Created on 24/12/2025.
//

import SwiftUI
import SwiftData

struct ExportView: View {
    let project: Project
    
    var orderedScenes: [Scene] {
        project.scenes.sorted { $0.sortOrder < $1.sortOrder }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedScenes) { scene in
                    Section {
                        ForEach(scene.shots.sorted { $0.shotNumber < $1.shotNumber }) { shot in
                            ShotExportRow(shot: shot)
                        }
                    } header: {
                        SceneHeaderView(scene: scene)
                    }
                }
            }
            .navigationTitle("Export - \(project.filmName)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // TODO: Export functionality
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// MARK: - Scene Header View

struct SceneHeaderView: View {
    let scene: Scene
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "moonphase.full.moon")
                    .foregroundStyle(.blue)
                
                HStack(spacing: 6) {
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)")
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    if !scene.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("-")
                            .font(.headline)
                        Text(scene.nickname)
                            .font(.headline)
                    }
                }
                
                Spacer()
                
                // Tags: INT/EXT and DAY/NIGHT
                HStack(spacing: 6) {
                    Text(scene.isInterior ? "INT" : "EXT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    
                    Text(scene.isDay ? "DAY" : "NIGHT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    
                    Text("\(scene.shots.count) shots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shot Export Row

struct ShotExportRow: View {
    let shot: Shot
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Shot number and info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "camera.circle.fill")
                        .foregroundStyle(.blue)
                    
                    Text("Shot \(shot.displayNumber)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                
                if !shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(shot.nickname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, alignment: .leading)
            
            // Shot details
            VStack(alignment: .leading, spacing: 4) {
                if shot.size != .none {
                    HStack(spacing: 4) {
                        Text("Size:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shot.size.shortVersion)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                
                if shot.typeCategory != .none {
                    HStack(spacing: 4) {
                        Text("Type:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shot.typeCategory.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        if shot.secondTypeCategory != .none {
                            Text("+ \(shot.secondTypeCategory.displayName)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                }
                
                if shot.type != .none {
                    HStack(spacing: 4) {
                        Text("Grip:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shot.type.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                
                if shot.lensfocal > 0 {
                    HStack(spacing: 4) {
                        Text("Focal:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if shot.lensIsPrime {
                            Text("\(shot.lensfocal)mm")
                                .font(.caption)
                                .fontWeight(.medium)
                        } else {
                            Text("\(shot.lensfocal)mm - \(shot.lensfocalEnd)mm")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                }
                
                if !shot.camera.isEmpty {
                    HStack(spacing: 4) {
                        Text("Camera:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shot.camera)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                
                if !shot.format.isEmpty {
                    HStack(spacing: 4) {
                        Text("Format:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shot.format)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                
                if !shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 4) {
                        Text("Info:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shot.extraInfo)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Photo indicators
            HStack(spacing: 8) {
                if shot.photo1Data != nil {
                    VStack(spacing: 2) {
                        Image(systemName: "photo.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Ref")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if shot.photo2Data != nil {
                    VStack(spacing: 2) {
                        Image(systemName: "map.fill")
                            .font(.caption)
                            .foregroundStyle(.purple)
                        Text("Map")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 60)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let project = Project(filmName: "Preview Film")
    
    // Add some sample scenes
    let scene1 = Scene(sceneNumber: 1)
    scene1.nickname = "Opening"
    scene1.isDay = true
    scene1.isInterior = true
    
    let shot1 = Shot(shotNumber: 1)
    shot1.nickname = "Wide establishing"
    shot1.size = .wideShot
    shot1.typeCategory = .establishingShot
    shot1.type = .tripod
    shot1.lensfocal = 24
    shot1.camera = "ARRI Alexa Mini"
    shot1.scene = scene1
    scene1.shots.append(shot1)
    
    let shot2 = Shot(shotNumber: 2)
    shot2.nickname = "Close on character"
    shot2.size = .closeUp
    shot2.typeCategory = .single
    shot2.type = .handheld
    shot2.lensfocal = 50
    shot2.scene = scene1
    scene1.shots.append(shot2)
    
    project.scenes.append(scene1)
    
    let scene2 = Scene(sceneNumber: 2)
    scene2.nickname = "Kitchen"
    scene2.isDay = false
    scene2.isInterior = true
    
    let shot3 = Shot(shotNumber: 1)
    shot3.size = .mediumShot
    shot3.scene = scene2
    scene2.shots.append(shot3)
    
    project.scenes.append(scene2)
    
    return ExportView(project: project)
        .modelContainer(for: Project.self, inMemory: true)
}
