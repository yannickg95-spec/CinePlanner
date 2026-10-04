//
//  PhotoSlot.swift
//  CinePlanner
//
//  A photo slot that picks, shows and clears one image.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

struct PhotoSlot: View {
    let photoData: Data?
    @Binding var selectedItem: PhotosPickerItem?
    let title: String
    var maxWidth: CGFloat = 700
    /// Most shots have no photo, so an empty slot collapses to a single row
    /// rather than reserving 200pt of placeholder.
    var compactWhenEmpty: Bool = false
    var onDelete: (() -> Void)?
    /// Shown as a button over the image; the image itself belongs to the picker.
    var onEnlarge: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if photoData == nil && compactWhenEmpty {
            compactAddRow
        } else {
            fullSlot
        }
    }

    private var compactAddRow: some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(.secondary)
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Add")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var fullSlot: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    if let photoData, let image = ThumbnailCache.image(for: photoData) {
                        #if os(macOS)
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: maxWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            }
                        #else
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: maxWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            }
                        #endif
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.06))
                            .frame(maxWidth: maxWidth)
                            .frame(height: 200)
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                    Text(title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                    Text("Click to add a photo")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            }
                    }
                }
                .buttonStyle(.plain)
                
                // Enlarge / delete, shown only once a photo exists
                if photoData != nil {
                    HStack(spacing: 6) {
                        if let onEnlarge {
                            Button(action: onEnlarge) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white, .black)
                                    .opacity(0.7)
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .help("View full size")
                            .accessibilityLabel("View full size")
                        }
                        if let onDelete {
                            Button(action: onDelete) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white, .black)
                                    .opacity(0.7)
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .help("Remove photo")
                            .accessibilityLabel("Remove photo")
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
    
}
