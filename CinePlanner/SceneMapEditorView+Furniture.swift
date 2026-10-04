//
//  SceneMapEditorView+Furniture.swift
//  CinePlanner
//
//  Furniture and lights on the scene map.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Furniture

    /// An implied metres-wide for UNSCALED maps, derived from the marker base size
    /// (a 0.45 m person drawn ~30 pt), so a light placed on a map without dimensions
    /// still comes out realistically sized relative to the people/camera markers
    /// instead of using its (much larger) normalized default.
    var impliedMetersWide: Double? {
        mapContentWidth > 0 ? Double(mapContentWidth) * (0.45 / 30) : nil
    }

    func addFurniture(_ kind: Furniture.Kind) {
        let point = newElementPoint
        // Use the real-world default size on a scaled map (so it lands at true size),
        // else the normalized default. Either way it stays freely resizable.
        let size: CGSize
        if let real = kind.defaultRealSize, let m = mapMetersWide, m > 0 {
            size = CGSize(width: real.width / m, height: real.height / m)
        } else if kind.isLight, let real = kind.defaultRealSize, let m = impliedMetersWide {
            // Unscaled map: size lights by the implied scale so they match the markers.
            size = CGSize(width: real.width / m, height: real.height / m)
        } else {
            size = kind.defaultSize
        }
        var item = Furniture(kind: kind, x: point.x, y: point.y,
                             width: Double(size.width), height: Double(size.height))
        item.colorHex = kind.defaultColorHex
        doc.furniture.append(item)
        selectFurniture(item.id)
        persist()
    }

    /// Toggles a softbox mounted on `lightID`. The softbox is part of the light (drawn
    /// attached to its front, base matching the front, no gap), so the two select, drag
    /// and rotate as one. Its real Chimera size comes from `Kind.mountedSoftbox`.
    func addSoftbox(to lightID: UUID) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == lightID }) else { return }
        doc.furniture[i].hasSoftbox.toggle()
        selectFurniture(doc.furniture[i].id)
        persist()
    }

    /// Truss: prompt for a length on a measured map; on an unscaled map add a
    /// default-length truss the user can stretch/lengthen with its handles.
    func beginAddTruss() {
        if mapMetersWide != nil {
            trussInput = ""
            trussPrompt = true
        } else {
            addTruss(lengthMeters: nil)
        }
    }

    func addTrussFromPrompt() {
        let normalized = trussInput.replacingOccurrences(of: ",", with: ".")
        guard let meters = Double(normalized), meters > 0 else { return }
        addTruss(lengthMeters: meters)
    }

    func addTruss(lengthMeters: Double?) {
        let point = newElementPoint
        let thickness = Furniture.Kind.trussThicknessMeters
        let size: CGSize
        if let m = mapMetersWide, m > 0, let len = lengthMeters, len > 0 {
            size = CGSize(width: len / m, height: thickness / m)
        } else if let m = impliedMetersWide {
            // Unscaled map: a default 3 m truss at the implied scale (matches markers).
            size = CGSize(width: 3.0 / m, height: thickness / m)
        } else {
            size = Furniture.Kind.truss.defaultSize
        }
        var item = Furniture(kind: .truss, x: point.x, y: point.y,
                             width: Double(size.width), height: Double(size.height))
        item.colorHex = Furniture.Kind.truss.defaultColorHex
        doc.furniture.append(item)
        selectFurniture(item.id)
        persist()
    }

    func selectFurniture(_ id: UUID) {
        // A plain (re)selection disarms resize: a light stays move-only until the user
        // explicitly picks "Resize" again.
        if furnitureSelectedID != id { furnitureResizeID = nil }
        furnitureSelectedID = id
        selectedIDs = []; furnitureSelectedIDs = []; openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil
    }

    func moveFurniture(_ id: UUID, to n: CGPoint) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].x = n.x; doc.furniture[i].y = n.y
        persist()
    }

    func rotateFurniture(_ id: UUID, to r: Double) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].rotation = r
        persist()
    }

    func resizeFurniture(_ id: UUID, width: Double, height: Double) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].width = width; doc.furniture[i].height = height
        persist()
    }

    /// The size a piece would be reset to (real-world on a scaled map, else the
    /// normalized default; tubes keep their modifier's cross-section).
    func defaultFurnitureSize(_ item: Furniture) -> CGSize {
        let kind = item.kind
        var size: CGSize
        if let real = kind.defaultRealSize, let m = mapMetersWide, m > 0 {
            size = CGSize(width: real.width / m, height: real.height / m)
        } else if kind.isLight, let real = kind.defaultRealSize, let m = impliedMetersWide {
            size = CGSize(width: real.width / m, height: real.height / m)
        } else {
            size = kind.defaultSize
        }
        if kind.isTube { size.height = CGFloat(tubeCrossHeight(hasModifier: item.hasModifier)) }
        return size
    }

    /// Whether a piece's current size differs from its default (so "Reset Size" is worth showing).
    func furnitureSizeChanged(_ item: Furniture) -> Bool {
        let d = defaultFurnitureSize(item)
        return abs(item.width - Double(d.width)) > 1e-4 || abs(item.height - Double(d.height)) > 1e-4
    }

    /// Restores a piece to its default size — real-world size on a scaled map,
    /// else the normalized default (mirrors `addFurniture`).
    func resetFurnitureSize(_ id: UUID) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        let kind = doc.furniture[i].kind
        let size: CGSize
        if let real = kind.defaultRealSize, let m = mapMetersWide, m > 0 {
            size = CGSize(width: real.width / m, height: real.height / m)
        } else {
            size = kind.defaultSize
        }
        doc.furniture[i].width = Double(size.width)
        doc.furniture[i].height = Double(size.height)
        // A tube keeps its modifier's wide cross-section after a size reset.
        if kind.isTube {
            doc.furniture[i].height = tubeCrossHeight(hasModifier: doc.furniture[i].hasModifier)
        }
        persist()
    }

    /// Normalized height for a tube's fixed cross-section: 20 cm with the diffusion
    /// modifier, otherwise 7 cm. On a scaled map this is metres ÷ map width; on an
    /// unscaled map it's scaled from the tube's 7 cm default.
    func tubeCrossHeight(hasModifier: Bool) -> Double {
        let crossM = hasModifier ? 0.20 : 0.07
        if let m = mapMetersWide, m > 0 { return crossM / m }
        return Double(Furniture.Kind.tube.defaultSize.height) * (crossM / 0.07)
    }

    /// Tube only: fits/removes the diffusion modifier, widening the cross-section
    /// to 20 cm (or back to 7 cm). The length is untouched.
    func toggleTubeModifier(_ id: UUID) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }),
              doc.furniture[i].kind.isTube else { return }
        let on = !doc.furniture[i].hasModifier
        doc.furniture[i].hasModifier = on
        doc.furniture[i].height = tubeCrossHeight(hasModifier: on)
        persist()
    }

    func setFurnitureColor(_ id: UUID, _ hex: String) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].colorHex = hex
        persist()
    }

    func setFurnitureLabel(_ id: UUID, _ label: String) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// Commit a furniture label's nudge once its drag ends.
    func moveFurnitureLabel(_ id: UUID, to offset: CGSize) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        doc.furniture[i].labelOffset = offset
        persist()
    }

    /// Reorders a furniture piece within the draw stack (its z-order): later in
    /// the array = drawn on top.
    func reorderFurniture(_ id: UUID, _ move: FurnitureLayerMove) {
        guard let i = doc.furniture.firstIndex(where: { $0.id == id }) else { return }
        let item = doc.furniture.remove(at: i)
        let target: Int
        switch move {
        case .toBack:   target = 0
        case .backward: target = max(0, i - 1)
        case .forward:  target = min(doc.furniture.count, i + 1)
        case .toFront:  target = doc.furniture.count
        }
        doc.furniture.insert(item, at: target)
        persist()
    }

    /// Duplicates a furniture piece, placing the copy right beside the original (one
    /// piece-width to the side, so they sit edge to edge rather than far apart or on top
    /// of each other), then selects the copy. Falls to the left when the original is too
    /// close to the right edge.
    func duplicateFurniture(_ id: UUID) {
        guard let item = doc.furniture.first(where: { $0.id == id }) else { return }
        var copy = item
        copy.id = UUID()
        // A gap of the piece's own width (floored so tiny lights still separate).
        let gap = max(item.width, 0.025) + 0.005
        // On maps that keep pieces inside the bounds, place the copy to the right unless
        // that runs off the edge (then to the left) and clamp. Where pieces may sit in
        // the white margin, keep the copy right beside the original — never clamp it back
        // to the map, which would fling a far-out light back to the edge.
        let clamp = !allowsPiecesOutsideMap
        var nx = item.x + gap
        if clamp && nx > 1 { nx = item.x - gap }
        copy.x = clamp ? min(max(nx, 0), 1) : nx
        copy.y = clamp ? min(max(item.y, 0), 1) : item.y
        doc.furniture.append(copy)
        furnitureSelectedID = copy.id
        furnitureSelectedIDs = []
        persist()
    }

    func deleteFurniture(_ id: UUID) {
        doc.furniture.removeAll { $0.id == id }
        if furnitureSelectedID == id { furnitureSelectedID = nil }
        furnitureSelectedIDs.remove(id)
        persist()
    }
}
