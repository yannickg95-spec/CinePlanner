//
//  CineStagerImporter.swift
//  CineStager 2
//
//  Created by Yannick Giraud on 15/12/2025.
//

import SwiftUI
import PhotosUI

/// A view for importing photos from the CineStager app
struct CineStagerImporter: View {
    @Binding var isPresented: Bool
    let onImport: ([Data]) -> Void
    
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                
                Text("Import from CineStager")
                    .font(.title2)
                    .bold()
                
                Text("Select photos from your photo library that were exported from CineStager")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    Label("Select Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)
                .buttonStyle(.plain)
                
                if !selectedItems.isEmpty {
                    Text("\(selectedItems.count) photo(s) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Import Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importPhotos()
                    }
                    .disabled(selectedItems.isEmpty || isImporting)
                }
            }
        }
    }
    
    private func importPhotos() {
        isImporting = true
        
        Task {
            var photoDataArray: [Data] = []
            
            for item in selectedItems {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    photoDataArray.append(data)
                }
            }
            
            await MainActor.run {
                onImport(photoDataArray)
                isImporting = false
                isPresented = false
            }
        }
    }
}

#Preview {
    CineStagerImporter(isPresented: .constant(true)) { photos in
        print("Imported \(photos.count) photos")
    }
}
