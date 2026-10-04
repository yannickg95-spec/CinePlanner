//
//  ReferenceVideoView.swift
//  CinePlanner
//
//  A reference video player, and the platform player view under it.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit
import UniformTypeIdentifiers
import os

/// Inline player for a shot's reference video. The video is stored as `Data`, so
/// it's written once to a stable temp file (keyed by the shot) and played from there.
struct ReferenceVideoView: View {
    let shotID: String
    let videoData: Data
    let fileExtension: String
    var onDelete: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let player {
                    // A 4:3 box on black, so the video reference matches the
                    // reference-image and map boxes beside it. The clip letterboxes
                    // inside rather than dictating the box's shape.
                    Color.black
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay { PlatformVideoPlayer(player: player) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.85))
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay(ProgressView().tint(.white))
                }
            }

            Button {
                player?.pause()
                player = nil
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black)
                    .opacity(0.7)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .onAppear { preparePlayer() }
        .onDisappear { player?.pause() }
        .onChange(of: shotID) { _, _ in preparePlayer() }
    }

    private func preparePlayer() {
        // Build the player off the main thread and hand it back on a later runloop
        // turn — never inside the view update that's running right now. A user's
        // reference video is added as a file-import panel dismisses, and creating an
        // AVKit player synchronously in that same update has aborted the app while
        // AVKit resolves its type metadata. Writing the (possibly large) video to disk
        // off-main also keeps that panel dismissal from hitching.
        let data = videoData, ext = fileExtension, id = shotID
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cineplanner_ref_\(id).\(ext)")
            // Reuse the temp file if it already matches this data; otherwise (re)write.
            let needsWrite: Bool
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size == data.count {
                needsWrite = false
            } else {
                needsWrite = true
            }
            if needsWrite {
                try? data.write(to: url, options: .atomic)
            }
            DispatchQueue.main.async {
                // The row may have been reused for another shot while we wrote; only
                // adopt the player if this view still wants this video.
                guard id == shotID else { return }
                player = AVPlayer(url: url)
            }
        }
    }
}

/// The reference video player, backed by AVKit's own player view rather than
/// SwiftUI's `VideoPlayer`. `VideoPlayer` lives in `_AVKit_SwiftUI` and resolves
/// generic type metadata the first time it's built; doing that inside the view
/// update that runs as a file-import panel closes has aborted the app on some
/// Macs. `AVPlayerView` / `AVPlayerViewController` are plain AVKit classes with no
/// such step, so they sidestep the crash and behave identically here.
#if os(macOS)
struct PlatformVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#elseif os(iOS)
struct PlatformVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif
