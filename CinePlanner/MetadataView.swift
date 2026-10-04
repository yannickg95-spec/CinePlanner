//
//  MetadataView.swift
//  CinePlanner
//
//  Read-only views of a reference photo's metadata and its top-down map's.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

struct MetadataView: View {
    let metadata: PhotoMetadata

    /// All metadata as flat label/value pairs. Group headings are omitted on
    /// purpose — each label already reads clearly on its own, and dropping them
    /// lets the pairs flow side by side so the box stays short.
    private var items: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        // Camera (name + format as one) and Focal Length stay adjacent — read together.
        let camera = Shot.combinedCamera(metadata.cameraFamily ?? "", metadata.cameraFormat ?? "")
        if !camera.isEmpty { rows.append(("Camera", camera)) }
        if let focal = metadata.focalLength {
            let focalString = focal.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fmm", focal)
                : String(format: "%.1fmm", focal)
            rows.append(("Focal Length", focalString))
        }
        if let lens = metadata.lensPreset { rows.append(("Lens", lens)) }
        if let framelines = metadata.framelines, !framelines.isEmpty { rows.append(("Framelines", framelines)) }
        if let tilt = metadata.tilt { rows.append(("Tilt", String(format: "%.1f\u{00B0}", tilt))) }
        return rows
    }

    var body: some View {
        if !items.isEmpty {
            // Label above value, wrapping into as many columns as fit — the same
            // layout the map reference's metadata uses, so nothing runs off the
            // edge in a narrow card (iPad, or a narrow Mac window).
            stackedLayout
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    /// Label above value, wrapping into as many columns as fit — the same layout
    /// the map reference's metadata uses, so nothing runs off the edge in a narrow
    /// card.
    private var stackedLayout: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18, alignment: .topLeading)],
                  alignment: .leading, spacing: 8) {
            ForEach(items, id: \.label) { item in
                stackedPair(item.label, item.value)
            }
        }
    }

    private func stackedPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TopDownMetadataView: View {
    let metadata: PhotoMetadata
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Location Information")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Label above value, and the rows wrap into as many columns as fit —
            // so nothing runs off the edge when the box is narrow (these labels
            // are long) and they sit side by side when there's room.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18, alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                ForEach(metadata.mapDisplayItems, id: \.label) { item in
                    stackedPair(item.label, item.value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Label above value, so a long label never has to share a line with its
    /// value and get clipped in a narrow column.
    private func stackedPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
