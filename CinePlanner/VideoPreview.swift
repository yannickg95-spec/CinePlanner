//
//  VideoPreview.swift
//  CinePlanner
//
//  Poster frames for video references, and a sheet to play one. Used by the
//  shot list, where a video reference would otherwise show a blank placeholder.
//

import SwiftUI
import AVKit
import SwiftData
import AppKit

/// Poster frames are expensive to make — the video has to be written to disk and
/// decoded — so each one is generated once and kept in memory. A shot list can
/// draw the same row many times while scrolling.
enum VideoPosterCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func poster(for reference: ShotReference) -> NSImage? {
        guard let data = reference.videoData else { return nil }
        let key = "\(reference.persistentModelID.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let image = generate(from: data, ext: reference.videoExtension ?? "mov") else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func generate(from data: Data, ext: String) -> NSImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cineplanner_poster_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: tmp))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // Half a second in: the very first frame is often black. Without zeroed
        // tolerances the generator snaps back to the nearest earlier keyframe —
        // usually frame 0 — and hands back the black frame anyway.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = (try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil))
              ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Identifies the video being previewed, so it can drive a `.sheet(item:)`.
struct VideoPreviewItem: Identifiable {
    let id: String
    let data: Data
    let fileExtension: String
    let title: String
}

struct VideoPreviewSheet: View {
    let item: VideoPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.title)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    player?.pause()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black.overlay(ProgressView().tint(.white))
                }
            }
        }
        .frame(width: 900, height: 620)
        .onAppear { preparePlayer() }
        .onDisappear { player?.pause() }
    }

    private func preparePlayer() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cineplanner_preview_\(item.id).\(item.fileExtension)")
        // Reuse the temp file when it already matches this data.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int
        if size != item.data.count {
            try? item.data.write(to: url, options: .atomic)
        }
        player = AVPlayer(url: url)
    }
}
