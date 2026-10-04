//
//  FilmNameEditor.swift
//  CinePlanner
//
//  Inline editor for a project's film name.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

struct FilmNameEditor: View {
    @Binding var filmName: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Film Name", text: $filmName)
            }
            .navigationTitle("Edit Film Name")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(200)])
    }
}
