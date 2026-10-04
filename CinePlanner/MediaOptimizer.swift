//
//  MediaOptimizer.swift
//  CinePlanner
//
//  Reference photos and videos used to be stored exactly as picked — a 48 MP photo
//  or a minute of 4K video — and all of it syncs through the user's iCloud. That
//  costs their iCloud storage, slows every sync, and makes each redraw decode a
//  huge image. Media is now brought down to a size that's plenty for planning when
//  it comes in:
//
//  • Photos: at most `photoMaxPixels` on the long edge (maps and backgrounds keep
//    more detail, `mapMaxPixels`), re-encoded only when larger — with all their
//    metadata (EXIF, TIFF, CinemaAR UserComment) carried over, since that's where
//    camera, lens and capture info come from.
//  • Videos: transcoded in the background to 1080p H.264 when larger than that.
//    H.264 rather than HEVC so a published web page plays in every browser.
//
//  Anything that's already small enough is left byte-for-byte untouched.
//

import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import os

enum MediaOptimizer {
    /// Long edge for reference photos.
    nonisolated static let photoMaxPixels = 2560
    /// Long edge for top-down maps and scene-map backgrounds, which get zoomed into.
    nonisolated static let mapMaxPixels = 4096

    // MARK: - Photos

    /// `data` scaled down to `maxPixels` on its long edge, with its metadata intact.
    /// Returns the original bytes when the image is already small enough, can't be
    /// read, or wouldn't get any smaller.
    nonisolated static func optimizedImage(_ data: Data, maxPixels: Int = photoMaxPixels) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixels else { return data }

        // Keep transparency (a PNG map) lossless; everything else becomes JPEG.
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return data }
        // Adding from the source (rather than a decoded CGImage) copies every
        // metadata dictionary across; the max pixel size does the scaling.
        let options: [CFString: Any] = [
            kCGImageDestinationImageMaxPixelSize: maxPixels,
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length < data.count else { return data }
        return out as Data
    }

    // MARK: - Videos

    /// Starts shrinking a video in the background and hands the result to `apply`
    /// (on the main actor) — only when it actually came out smaller. The original is
    /// shown meanwhile; `apply` should check the reference still holds it.
    static func shrinkVideoLater(_ data: Data, fileExtension ext: String,
                                 apply: @escaping @MainActor (Data, String) -> Void) {
        Task.detached(priority: .utility) {
            guard let smaller = await optimizedVideo(data, fileExtension: ext) else { return }
            await apply(smaller.data, smaller.ext)
        }
    }

    /// The video as 1080p H.264 MP4, or nil when it's already within 1080p (and not
    /// oversized), couldn't be transcoded, or the result isn't smaller.
    nonisolated static func optimizedVideo(_ data: Data, fileExtension ext: String) async -> (data: Data, ext: String)? {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("import_\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
        do { try data.write(to: source) } catch { return nil }
        defer { try? fm.removeItem(at: source) }

        let asset = AVURLAsset(url: source)
        // Leave it alone when it's already 1080p or smaller and not unusually large.
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            let longEdge = max(abs(size.width), abs(size.height))
            if longEdge <= 1920, data.count <= 60 * 1_048_576 { return nil }
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { return nil }
        session.shouldOptimizeForNetworkUse = true
        let output = fm.temporaryDirectory.appendingPathComponent("import_out_\(UUID().uuidString).mp4")
        defer { try? fm.removeItem(at: output) }
        do {
            try await session.export(to: output, as: .mp4)
            let result = try Data(contentsOf: output)
            guard result.count < data.count else { return nil }
            Log.media.debug("Reference video shrunk from \(data.count) to \(result.count) bytes")
            return (result, "mp4")
        } catch {
            Log.media.notice("Reference video kept at full size; transcode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
