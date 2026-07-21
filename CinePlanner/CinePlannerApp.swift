//
//  CinePlannerApp.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import SwiftUI
import SwiftData

@main
struct CinePlannerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Project.self,
            Episode.self,
            ScriptVersion.self,
            Scene.self,
            Shot.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some SwiftUI.Scene {
        WindowGroup {
            ProjectListView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .modelContainer(sharedModelContainer)
        // Comfortably inside a 1600×1200 display (and typical laptop screens)
        .defaultSize(width: 1440, height: 860)
    }
}

