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
