//
//  ReferenceMediaLoader.swift
//  CinePlanner
//
//  Shared logic for populating a ShotReference from a picked media file: stores
//  the image (or video), pulls EXIF into the reference and its shot's camera
//  fields, and best-effort guesses the shot size with on-device Vision. Used by
//  both the reference card's single import and the shot list's multi-image
//  "one image → one shot" add.
//

import Foundation
import UniformTypeIdentifiers

enum ReferenceMediaLoader {

    /// Populates a reference from picked image bytes.
    @MainActor
    static func loadImage(_ data: Data, into reference: ShotReference) {
        let metadata = EXIFExtractor.extractMetadata(from: data)
        reference.imageData = data
        reference.videoData = nil          // a reference holds one or the other
        reference.videoExtension = nil

        // Best-effort: guess the shot size from the photo (on-device Vision),
        // pre-filling only an empty Size that the user can override.
        if let shot = reference.shot, !shot.hasSize {
            Task { @MainActor in
                let guess = await Task.detached { ShotSizeEstimator.estimate(from: data) }.value
                if let guess, guess != .none, !shot.hasSize { shot.sizeName = guess.rawValue }
            }
        }
        // Best-effort: guess the type (Single / Two Shot / …) from how many people
        // are in frame, pre-filling only an empty Type the user can override.
        if let shot = reference.shot, !shot.hasType {
            Task { @MainActor in
                let type = await Task.detached { ShotTypeEstimator.estimate(from: data) }.value
                if let type, !shot.hasType { shot.typeName = type.rawValue }
            }
        }
        guard let metadata else { return }
        reference.cameraFamily = metadata.cameraFamily
        reference.cameraFormat = metadata.cameraFormat
        reference.focalLength = metadata.focalLength
        reference.lensPreset = metadata.lensPreset
        reference.horizon = metadata.horizon
        reference.tilt = metadata.tilt
        reference.height = metadata.height
        reference.captureID = metadata.captureID
        reference.captureType = metadata.captureType
        reference.dateTimeOriginal = metadata.dateTimeOriginal
        reference.keywords = metadata.iptcKeywords
        reference.caption = metadata.iptcCaption
        reference.framelines = metadata.framelines
        reference.software = metadata.tiffSoftware

        // Fill the shot's camera fields from the first reference that has them.
        if let shot = reference.shot {
            if shot.camera.isEmpty {
                let combined = Shot.combinedCamera(metadata.cameraFamily ?? "", metadata.cameraFormat ?? "")
                if !combined.isEmpty { shot.camera = combined }
            }
            if let lines = metadata.framelines, shot.framelines.isEmpty { shot.framelines = lines }
            if let lens = metadata.lensPreset, shot.lensPreset.isEmpty { shot.lensPreset = lens }
            // A single focal length is a prime lens; only fill it when the shot
            // hasn't got one yet, so a manual value isn't overwritten.
            if let focal = metadata.focalLength, focal > 0, shot.lensfocal == 0 {
                shot.lensfocal = Int(focal.rounded())
                shot.lensIsPrime = true
            }
        }
    }

    /// Populates a reference from a picked media URL (photo or video), routing by
    /// its type. Reads the bytes honouring the security scope.
    @MainActor
    static func load(mediaAt url: URL, into reference: ShotReference) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }

        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let type, type.conforms(to: .movie) || type.conforms(to: .video) {
            reference.imageData = nil       // a reference holds one or the other
            reference.videoData = data
            reference.videoExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        } else {
            loadImage(data, into: reference)
        }
    }
}
