//
//  ShotSizeEstimator.swift
//  CinePlanner
//
//  A best-effort guess at a shot's framing size from a reference image, using
//  on-device Vision (no network). It looks at how much of a human subject is in
//  frame — which body landmarks are visible and how large the face is — and maps
//  that to a ShotSize. Returns nil when there's no clear human subject to judge
//  from, so callers only ever pre-fill an empty Size the user can override.
//

import Foundation
import Vision
import CoreGraphics
import ImageIO

enum ShotSizeEstimator {

    // Assumptions for the geometric estimate. Coarse buckets tolerate the slack.
    private static let subjectHeightM = 1.75      // a standing person
    private static let sensorHeightMM = 14.0      // Super 35, ~16:9 frame height

    /// Geometric shot-size guess from the camera↔subject distance and focal
    /// length — how much of a standing person the lens frames vertically. Far
    /// more reliable than image analysis for CineStager (mannequin) shots.
    /// Uses the nearest mannequin. Nil when the geometry isn't available.
    /// Shot size from an explicit camera↔subject distance + focal + sensor. This
    /// is the core geometry; it needs no map or location model.
    static func size(distanceM: Double, focalMM: Double, sensorHeightMM: Double? = nil) -> ShotSize? {
        guard focalMM > 0, distanceM > 0.2 else { return nil }
        // The real sensor height drives the vertical FOV; fall back to Super 35
        // for captures made before CineStager exported it.
        let sensorH = (sensorHeightMM ?? 0) > 0 ? sensorHeightMM! : Self.sensorHeightMM
        // Subject height as a fraction of the frame's world height: >1 means the
        // person is taller than the frame (we're cropping in → closer sizes).
        let coverage = subjectHeightM * focalMM / (distanceM * sensorH)
        switch coverage {
        case ..<0.45:      return .extremeWideShot   // tiny figure in the scene
        case 0.45..<0.7:   return .wideShot          // full figure, lots of space
        case 0.7..<1.15:   return .longShot          // full figure, head to toe
        case 1.15..<1.5:   return .mediumLongShot    // head to knees/thighs
        case 1.5..<2.6:    return .mediumShot        // head to waist
        case 2.6..<4.5:    return .mediumCloseUp      // head to shoulders
        case 4.5..<6.5:    return .closeUp            // head
        default:           return .extremeCloseUp     // face detail
        }
    }

    /// Same, but measuring the camera↔nearest-mannequin distance from the map's
    /// world coordinates (used when a subject distance wasn't exported directly).
    static func geometricEstimate(camera: CineStagerMapMetadata.Marker,
                                  mannequins: [CineStagerMapMetadata.Marker],
                                  focalMM: Double,
                                  sensorHeightMM: Double? = nil) -> ShotSize? {
        guard let cx = camera.worldX, let cz = camera.worldZ else { return nil }
        let distance = mannequins.compactMap { m -> Double? in
            guard let mx = m.worldX, let mz = m.worldZ else { return nil }
            return hypot(cx - mx, cz - mz)
        }.min()
        guard let distance else { return nil }
        return size(distanceM: distance, focalMM: focalMM, sensorHeightMM: sensorHeightMM)
    }

    /// Estimates a shot size from image bytes. Nil when it can't tell.
    static func estimate(from imageData: Data) -> ShotSize? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        try? handler.perform([bodyRequest, faceRequest])

        // The biggest face (by height) — a good proxy for close framings and a
        // tiebreaker when the body pose is ambiguous.
        let faceHeight = (faceRequest.results ?? []).map { $0.boundingBox.height }.max() ?? 0

        // The body pose with the most confident joints is our main subject.
        if let body = (bodyRequest.results ?? [])
            .max(by: { confidentJointCount($0) < confidentJointCount($1) }),
           confidentJointCount(body) > 0,
           let size = sizeFromBody(body, faceHeight: faceHeight) {
            return size
        }

        // No usable body — judge from the face alone.
        if faceHeight > 0 { return sizeFromFace(faceHeight) }
        return nil
    }

    // MARK: - Body pose

    private static func point(_ obs: VNHumanBodyPoseObservation,
                              _ joint: VNHumanBodyPoseObservation.JointName,
                              minConfidence: Float = 0.3) -> Bool {
        guard let p = try? obs.recognizedPoint(joint), p.confidence > minConfidence else { return false }
        let l = p.location   // normalized, origin bottom-left
        return l.x >= 0 && l.x <= 1 && l.y >= 0 && l.y <= 1
    }

    private static func confidentJointCount(_ obs: VNHumanBodyPoseObservation) -> Int {
        let joints: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .leftEye, .rightEye, .neck, .leftShoulder, .rightShoulder,
            .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        return joints.filter { point(obs, $0) }.count
    }

    /// The lowest visible body region sets the framing: feet → wide, knees →
    /// medium-long, hips → medium, shoulders → medium-close, head only → close.
    private static func sizeFromBody(_ obs: VNHumanBodyPoseObservation, faceHeight: CGFloat) -> ShotSize? {
        func any(_ joints: [VNHumanBodyPoseObservation.JointName]) -> Bool { joints.contains { point(obs, $0) } }
        if any([.leftAnkle, .rightAnkle]) { return .wideShot }
        if any([.leftKnee, .rightKnee])   { return .mediumLongShot }
        if any([.leftHip, .rightHip])     { return .mediumShot }
        if any([.leftShoulder, .rightShoulder]) {
            return faceHeight > 0.5 ? .closeUp : .mediumCloseUp
        }
        if any([.nose, .leftEye, .rightEye]) {
            return faceHeight > 0.55 ? .extremeCloseUp : .closeUp
        }
        return nil
    }

    // MARK: - Face only

    private static func sizeFromFace(_ faceHeight: CGFloat) -> ShotSize {
        switch faceHeight {
        case 0.55...:      return .extremeCloseUp
        case 0.30..<0.55:  return .closeUp
        case 0.18..<0.30:  return .mediumCloseUp
        case 0.10..<0.18:  return .mediumShot
        default:           return .mediumLongShot
        }
    }
}

/// Best-effort guess at how many people a shot frames — Single / Two Shot /
/// Three Shot / Group Shot — from on-device Vision (no network). Returns nil
/// when no person is found, so callers only ever pre-fill an empty Type the
/// user can override.
enum ShotTypeEstimator {

    /// Maps the number of people detected in the image to a shot type.
    static func estimate(from imageData: Data) -> ShotTypeCategory? {
        switch personCount(from: imageData) {
        case 1:    return .single
        case 2:    return .twoShot
        case 3:    return .threeShot
        case 4...: return .groupShot
        default:   return nil
        }
    }

    /// Counts distinct people in the frame. Runs three detectors and takes the
    /// most that agree on — person rectangles are the primary signal, with body
    /// poses and faces as backups (each is roughly one hit per person), which
    /// also gives stylised subjects like CineStager mannequins more than one
    /// chance to register.
    static func personCount(from imageData: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return 0 }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let humanRequest = VNDetectHumanRectanglesRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        try? handler.perform([humanRequest, bodyRequest, faceRequest])

        let humans = (humanRequest.results ?? []).filter { $0.confidence > 0.4 }.count
        let bodies = (bodyRequest.results ?? []).count
        let faces = (faceRequest.results ?? []).filter { $0.confidence > 0.3 }.count
        return max(humans, bodies, faces)
    }
}
