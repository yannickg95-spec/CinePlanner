//
//  PathVideoMoment.swift
//  CinePlanner
//
//  What a camera saw from a position on its CineStager video's path: the video's
//  frame at the moment it stood there, shown as the still on the camera's card in
//  the scene map, with the time.
//
//  AVFoundation reads files, not Data, so a reference's video is written to
//  Caches once (named by the reference and its size, so a replaced video gets a
//  new file) and the frames come from that.
//

import SwiftUI
import AVFoundation

enum PathVideoFrames {
    private static let directory = URL.cachesDirectory.appending(path: "PathVideo", directoryHint: .isDirectory)
    private static let frames = NSCache<NSString, PlatformImage>()
    /// Each reference's video file once found or written this session — so the
    /// video isn't read from the store again just to find it.
    private static var files: [String: URL] = [:]

    /// The reference's video as a file, written on first use; nil without one.
    static func videoFile(for reference: ShotReference) async -> URL? {
        if let url = files[reference.uid], FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = reference.videoData else { return nil }
        let directory = directory
        let url = directory.appending(path: "\(reference.uid)-\(data.count).\(reference.videoExtension ?? "mp4")")
        if !FileManager.default.fileExists(atPath: url.path) {
            let written = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return (try? data.write(to: url, options: .atomic)) != nil
            }.value
            guard written else { return nil }
        }
        files[reference.uid] = url
        return url
    }

    /// The video's frame at `seconds`, kept for the rest of the session.
    static func frame(of reference: ShotReference, at seconds: Double) async -> PlatformImage? {
        let key = "\(reference.uid)@\(Int(seconds * 1000))" as NSString
        if let cached = frames.object(forKey: key) { return cached }
        guard let url = await videoFile(for: reference),
              let image = await extractFrame(from: url, at: seconds) else { return nil }
        let frame = PlatformImage.fromCGImage(image, size: CGSize(width: image.width, height: image.height))
        frames.setObject(frame, forKey: key)
        return frame
    }

    nonisolated private static func extractFrame(from url: URL, at seconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        // The frame at (or just before) the moment — not the nearest keyframe,
        // which can be half a second off.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero
        let time = await playableTime(seconds, in: asset)
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// `seconds`, kept just inside the video: the last position's moment is when
    /// the recording stopped, which can lie a hair past the video's last frame.
    nonisolated private static func playableTime(_ seconds: Double, in asset: AVAsset) async -> Double {
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0.1 else {
            return max(seconds, 0)
        }
        return min(max(seconds, 0), duration - 0.05)
    }

    /// Clears videos and frames not used for a week (Caches may go anyway).
    static func pruneOld(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentAccessDateKey]) else { return }
        for url in files {
            let used = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
            if now.timeIntervalSince(used) > 7 * 24 * 3600 { try? fm.removeItem(at: url) }
        }
    }
}

/// The frame a camera on a video's path saw, filling the card's still, with the
/// moment in a corner.
struct PathMomentStill: View {
    let reference: ShotReference
    let time: Double
    let size: CGSize
    /// Shown when the video's frame can't be had (the video isn't here).
    let fallback: PlatformImage?

    @State private var frame: PlatformImage?
    @State private var failed = false

    private var timeText: String { Duration.seconds(time).formatted(.time(pattern: .minuteSecond)) }

    var body: some View {
        ZStack {
            if let frame {
                still(frame)
            } else if failed {
                if let fallback {
                    still(fallback)
                } else {
                    Color.secondary.opacity(0.12)
                        .overlay(Image(systemName: "photo").font(.title2).foregroundStyle(.secondary))
                }
            } else {
                Color.secondary.opacity(0.12).overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomLeading) {
            if frame != nil {
                Text(timeText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(reference.uid)@\(time)") { await load() }
    }

    private func still(_ image: PlatformImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private func load() async {
        failed = false
        frame = await PathVideoFrames.frame(of: reference, at: time)
        failed = frame == nil
    }
}
