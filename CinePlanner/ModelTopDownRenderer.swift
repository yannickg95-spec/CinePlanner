//
//  ModelTopDownRenderer.swift
//  CinePlanner
//
//  Renders a top-down, orthographic, *unlit* still of a 3D model — used to turn a
//  set/location model (USDZ, OBJ, DAE, …) into a scene-map background. The camera
//  looks straight down the +Y axis (the up-axis SceneKit/USD import normalises to),
//  so it frames the floor plan, lit with a constant/unlit shading model, and fitted
//  perfectly inside a square with a small margin.
//
//  Backface culling gives the "dollhouse" view: interior models are authored with
//  faces pointing inward, so from directly above the ceiling shows its back face
//  and is culled — revealing the floor — exactly as Quick Look renders them, and
//  regardless of whether the ceiling is flat, sloped, or multi-level.
//

import Foundation
import AppKit
import Metal
import SceneKit
import SceneKit.ModelIO
import ModelIO

enum ModelTopDownRenderer {

    /// Top-down orthographic unlit image of the model at `url`, fitted to a
    /// square. Backface culling hides the ceiling (dollhouse view). Returns nil if
    /// the file can't be loaded or the GPU is unavailable.
    static func topDownImage(from url: URL, size: CGFloat = 1024, margin: CGFloat = 0.04) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let model = loadNode(url) else { return nil }

        let scene = SCNScene()
        scene.rootNode.addChildNode(model)
        applyUnlit(model)

        // Frame the model's footprint (its extent on the X/Z ground plane) into a
        // square, looking straight down the up-axis (+Y).
        guard let b = worldBounds(model) else { return nil }
        let center = SCNVector3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
        let width = b.max.x - b.min.x
        let depth = b.max.z - b.min.z
        let height = b.max.y - b.min.y
        let half = max(width, depth) / 2 * (1 + margin)
        guard half > 0 else { return nil }

        // Camera sits above the model looking straight down; culled backfaces hide
        // the ceiling so the floor shows through.
        let camY = b.max.y + 1
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(half)
        camera.zNear = 0.001
        camera.zFar = Double(camY - b.min.y) + 1
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x, camY, center.z)
        cameraNode.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)   // look straight down −Y
        scene.rootNode.addChildNode(cameraNode)

        scene.background.contents = NSColor.clear   // transparent around the model

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0,
                                 with: CGSize(width: size, height: size),
                                 antialiasingMode: .multisampling4X)
    }

    // MARK: - Loading

    /// Loads a 3D file into a single node. Tries SceneKit's importer first (USDZ,
    /// USD, SCN, DAE, ABC), then Model I/O (OBJ, PLY, STL, …).
    private static func loadNode(_ url: URL) -> SCNNode? {
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: false]),
           !scene.rootNode.childNodes.isEmpty {
            return collapse(scene.rootNode)
        }
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        return collapse(SCNScene(mdlAsset: asset).rootNode)
    }

    /// Moves a scene root's children under one fresh node.
    private static func collapse(_ root: SCNNode) -> SCNNode {
        let node = SCNNode()
        for child in root.childNodes { node.addChildNode(child) }
        return node
    }

    // MARK: - Materials

    private static func applyUnlit(_ node: SCNNode) {
        node.enumerateHierarchy { n, _ in
            guard let materials = n.geometry?.materials else { return }
            for material in materials {
                material.lightingModel = .constant   // unlit: flat diffuse, no shading
                material.isDoubleSided = false        // cull backfaces → ceiling drops away
                material.cullMode = .back
            }
        }
    }

    // MARK: - Geometry

    /// World-space axis-aligned bounding box across every geometry node in the
    /// hierarchy, honouring each node's transforms.
    private static func worldBounds(_ node: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
        var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var found = false
        node.enumerateHierarchy { n, _ in
            guard n.geometry != nil else { return }
            let (a, b) = n.boundingBox
            let corners = [
                SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, a.y, a.z),
                SCNVector3(a.x, b.y, a.z), SCNVector3(b.x, b.y, a.z),
                SCNVector3(a.x, a.y, b.z), SCNVector3(b.x, a.y, b.z),
                SCNVector3(a.x, b.y, b.z), SCNVector3(b.x, b.y, b.z),
            ]
            for c in corners {
                let w = n.convertPosition(c, to: nil)
                lo.x = min(lo.x, w.x); lo.y = min(lo.y, w.y); lo.z = min(lo.z, w.z)
                hi.x = max(hi.x, w.x); hi.y = max(hi.y, w.y); hi.z = max(hi.z, w.z)
                found = true
            }
        }
        return found ? (lo, hi) : nil
    }
}

extension NSImage {
    /// PNG encoding that preserves transparency, for storing rendered backgrounds.
    func pngDataForBackground() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
