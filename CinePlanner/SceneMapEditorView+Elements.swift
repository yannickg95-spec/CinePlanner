//
//  SceneMapEditorView+Elements.swift
//  CinePlanner
//
//  Characters and cameras on the scene map: adding, selecting, moving, rotating.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import os
import CoreData

extension SceneMapEditorView {
    // MARK: - Element actions

    func setColor(_ id: UUID, _ hex: String) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].colorHex = hex
        persist()
    }

    /// Assigns a character (its name as the label, its color) to a mannequin marker.
    func setCharacter(_ id: UUID, _ character: ScriptCharacter) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].label = character.name
        doc.elements[index].colorHex = character.colorHex
        persist()
    }

    /// Sets (or clears, with "") a character marker's free-text name label.
    func setMarkerLabel(_ id: UUID, _ label: String) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// Toggles one marker's name-label visibility (per marker, so a character's two
    /// walk markers are independent).
    func toggleLabelHidden(_ id: UUID) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].labelHidden.toggle()
        persist()
    }

    func deleteElement(_ id: UUID) {
        doc.elements.removeAll { $0.id == id }
        doc.arrows.removeAll { $0.fromID == id || $0.toID == id }
        selectedIDs.remove(id)
        persist()
    }

    /// Deletes a marker, or — when it's part of a multi-selection — every selected
    /// piece (used by the marker's Delete menu item and the delete key).
    func deleteMarkerOrSelection(_ id: UUID) {
        if selectedIDs.count + furnitureSelectedIDs.count > 1 && selectedIDs.contains(id) {
            deleteSelectedPieces()
        } else {
            deleteElement(id)
        }
    }

    /// Deletes a furniture piece, or — when it's part of a multi-selection — every
    /// selected piece (used by the furniture Delete menu item).
    func deleteFurnitureOrSelection(_ id: UUID) {
        if selectedIDs.count + furnitureSelectedIDs.count > 1 && furnitureSelectedIDs.contains(id) {
            deleteSelectedPieces()
        } else {
            deleteFurniture(id)
        }
    }

    /// Deletes every selected marker and furniture piece (and any arrows touching a
    /// deleted marker) in one go.
    func deleteSelectedPieces() {
        let ids = selectedIDs
        let fids = furnitureSelectedIDs
        guard !ids.isEmpty || !fids.isEmpty else { return }
        if !ids.isEmpty {
            doc.elements.removeAll { ids.contains($0.id) }
            doc.arrows.removeAll { ids.contains($0.fromID) || ids.contains($0.toID) }
        }
        if !fids.isEmpty { doc.furniture.removeAll { fids.contains($0.id) } }
        selectedIDs = []
        furnitureSelectedIDs = []
        persist()
    }

    /// Selects a single marker (a plain tap), clearing every other kind of
    /// selection.
    func selectMarker(_ id: UUID) {
        selectedIDs = [id]
        furnitureSelectedIDs = []
        openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil; furnitureSelectedID = nil
    }

    /// Commits a group drag: shifts every selected marker by the drag translation
    /// (canvas points). Clamped so no marker leaves the map into the grey area, except
    /// on a CineStager import where markers may sit outside the framed room.
    func commitGroupDrag(_ translation: CGSize, in rect: CGRect) {
        defer { groupDragTranslation = nil }
        guard rect.width > 0, rect.height > 0 else { return }
        let clamp = !allowsPiecesOutsideMap
        for i in doc.elements.indices where selectedIDs.contains(doc.elements[i].id) {
            let cx = rect.minX + doc.elements[i].x * rect.width + translation.width
            let cy = rect.minY + doc.elements[i].y * rect.height + translation.height
            let nx = (cx - rect.minX) / rect.width
            let ny = (cy - rect.minY) / rect.height
            doc.elements[i].x = clamp ? min(max(nx, 0), 1) : nx
            doc.elements[i].y = clamp ? min(max(ny, 0), 1) : ny
        }
        for i in doc.furniture.indices where furnitureSelectedIDs.contains(doc.furniture[i].id) {
            let cx = rect.minX + doc.furniture[i].x * rect.width + translation.width
            let cy = rect.minY + doc.furniture[i].y * rect.height + translation.height
            let nx = (cx - rect.minX) / rect.width
            let ny = (cy - rect.minY) / rect.height
            doc.furniture[i].x = clamp ? min(max(nx, 0), 1) : nx
            doc.furniture[i].y = clamp ? min(max(ny, 0), 1) : ny
        }
        persist()
    }

    /// Selects every camera/mannequin marker and every furniture/light piece whose centre
    /// falls inside the marquee rectangle (canvas screen points). Centres are taken through
    /// the same placement transform the box is measured in, so selection stays correct on a
    /// scaled or offset (Adjusted) map.
    func selectMarkersInMarquee(_ box: CGRect, in rect: CGRect, canvas: CGSize) {
        var markerHits: Set<UUID> = []
        for element in doc.elements where (element.kind == .camera ? doc.showCameras : doc.showCharacters) {
            let c = pieceScreenCenter(nx: element.x, ny: element.y, in: rect, canvas: canvas)
            if box.contains(c) { markerHits.insert(element.id) }
        }
        var furnitureHits: Set<UUID> = []
        for item in doc.furniture where (item.kind.isLight ? doc.showLights : doc.showFurniture) {
            let c = pieceScreenCenter(nx: item.x, ny: item.y, in: rect, canvas: canvas)
            if box.contains(c) { furnitureHits.insert(item.id) }
        }
        selectedIDs = markerHits
        furnitureSelectedIDs = furnitureHits
        openingSelectedID = nil; wallSelectedID = nil; arrowSelectedID = nil; furnitureSelectedID = nil
    }


    /// Zoom a step from a mouse wheel, about the map centre (a wheel has no anchor
    /// the way a pinch does). `pan` scales with the zoom so the ground under the
    /// centre stays put.
    func zoomBy(_ factor: CGFloat, size: CGSize) {
        let z1 = min(max(zoom * factor, minZoom), 4)
        guard z1 != zoom else { return }
        let ratio = z1 / zoom
        var newPan = CGSize(width: pan.width * ratio, height: pan.height * ratio)
        let limits = panLimits(size, zoom: z1)
        newPan.width = min(max(newPan.width, -limits.width), limits.width)
        newPan.height = min(max(newPan.height, -limits.height), limits.height)
        zoom = z1; lastZoom = z1
        pan = newPan; lastPan = newPan
    }

    /// One empty-canvas drag: pans the zoomed map when zoomed in, else (macOS) draws
    /// a rubber-band selection box. Measured in `canvasScreenSpace` — the untransformed
    /// pane space on the canvas root — so the box tracks the finger even on a scaled map
    /// (the gesture sits inside the placement scaleEffect, which skews `.global`), yet
    /// stays outside the `pan` offset so a live pan can't feed back into the measurement.
    func canvasPanOrMarquee(in rect: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(SceneMapEditorView.canvasScreenSpace))
            .onChanged { value in
                #if os(iOS)
                // Touch: with one marker/furniture selected, a drag anywhere moves it
                // (so it needn't be grabbed precisely). Takes priority over panning.
                if let target = anywhereMoveTarget ?? singleSelectedMovable,
                   !isDrawing, pendingMove == nil, !backgroundAdjustActive, !reframeActive {
                    if anywhereMoveTarget == nil {
                        anywhereMoveTarget = target
                        anywhereMoveBase = normalizedPosition(of: target)
                        cameraInfoElementID = nil
                    }
                    if let base = anywhereMoveBase {
                        // Screen delta → normalized content delta: undo the map's
                        // rotation, then divide by the on-screen size of the content
                        // rect (rect × canvas zoom × placement scale).
                        let sx = rect.width * zoom * CGFloat(mapPlacement.scale)
                        let sy = rect.height * zoom * CGFloat(mapPlacement.scale)
                        let t = mapPlacement.rotation * .pi / 180
                        let tx = value.translation.width, ty = value.translation.height
                        let rx = tx * cos(t) + ty * sin(t)
                        let ry = -tx * sin(t) + ty * cos(t)
                        var nx = base.x + Double(rx / max(sx, 1))
                        var ny = base.y + Double(ry / max(sy, 1))
                        // Markers and furniture stay on the map, except where the map
                        // opens a white margin they may sit in (see allowsPiecesOutsideMap).
                        if !allowsPiecesOutsideMap { nx = min(max(nx, 0), 1); ny = min(max(ny, 0), 1) }
                        setMovableLive(target, to: CGPoint(x: nx, y: ny))
                    }
                    return
                }
                #endif
                if dragPansCanvas {
                    let limits = panLimits(size, zoom: zoom)
                    let moved = panDelta(fromScreen: value.translation)
                    pan = CGSize(
                        width: min(max(lastPan.width + moved.width, -limits.width), limits.width),
                        height: min(max(lastPan.height + moved.height, -limits.height), limits.height))
                    return
                }
                #if os(macOS)
                guard !isDrawing, pendingMove == nil else { return }
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    cameraInfoElementID = nil
                }
                marqueeCurrent = value.location
                #endif
            }
            .onEnded { value in
                #if os(iOS)
                if anywhereMoveTarget != nil {
                    anywhereMoveTarget = nil
                    anywhereMoveBase = nil
                    persist()
                    return
                }
                #endif
                if dragPansCanvas { lastPan = pan; return }
                #if os(macOS)
                defer { marqueeStart = nil; marqueeCurrent = nil }
                guard !isDrawing, pendingMove == nil, let start = marqueeStart else { return }
                let loc = value.location
                let box = CGRect(x: min(start.x, loc.x), y: min(start.y, loc.y),
                                 width: abs(loc.x - start.x), height: abs(loc.y - start.y))
                selectMarkersInMarquee(box, in: rect, canvas: size)
                #endif
            }
    }

    /// Pan the zoomed map by an incremental trackpad-scroll delta, clamped to the
    /// same bounds as the drag pan. `lastPan` is kept in sync so a following drag
    /// continues from here.
    func panBy(_ delta: CGSize, size: CGSize) {
        guard zoom > 1 || reframeActive else { return }
        let limits = panLimits(size, zoom: zoom)
        let moved = panDelta(fromScreen: delta)
        pan = CGSize(
            width: min(max(pan.width + moved.width, -limits.width), limits.width),
            height: min(max(pan.height + moved.height, -limits.height), limits.height))
        lastPan = pan
    }

    // MARK: - Actions

    /// Spawn point (normalized 0…1) for a new element: near the center, nudged
    /// so successive additions don't stack exactly on top of each other.
    var newElementPoint: CGPoint {
        let jitter = Double(doc.elements.count % 6) * 0.03
        return CGPoint(x: 0.44 + jitter, y: 0.42 + jitter)
    }

    /// Adds a mannequin (character) marker labeled with the character's name and
    /// tinted with its color.
    func addCharacterMarker(name: String, colorHex: String) {
        let point = newElementPoint
        var element = MapElement(kind: .character, x: point.x, y: point.y)
        element.label = name
        element.colorHex = colorHex
        doc.elements.append(element)
        selectedIDs = [element.id]
        persist()
    }

    /// Whether a camera for this shot is already on the map. Extra markers made
    /// with Move To/From share the shot's uid too, so this also reports true once
    /// a shot has been moved — which is fine: the dropdown only adds the first.
    func hasCamera(for shot: Shot) -> Bool {
        doc.elements.contains { $0.kind == .camera && $0.shotUID == shot.uid }
    }

    /// Add a camera linked to a specific shot: its label follows the shot's
    /// number, and it's removed if the shot is deleted. At most one per shot from
    /// here — a second marker for a shot only comes from Move To/From.
    func addCamera(for shot: Shot) {
        guard !hasCamera(for: shot) else { return }
        let point = newElementPoint
        var element = MapElement(kind: .camera, x: point.x, y: point.y)
        element.label = shot.displayNumber
        element.shotUID = shot.uid
        element.colorHex = "#FF9500"
        doc.elements.append(element)
        selectedIDs = [element.id]
        persist()
    }

    /// Commit a label's nudge once its drag ends.
    func moveLabel(_ id: UUID, to offset: CGSize) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].labelOffset = offset
        persist()
    }

    /// Commit a marker's new position once its drag ends (mid-drag movement is
    /// handled locally inside MapMarkerView so the canvas doesn't re-render).
    func moveElement(_ id: UUID, to position: CGPoint) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].x = position.x
        doc.elements[index].y = position.y
        persist()
    }

    // MARK: - Drag-anywhere move (touch)

    /// A single movable item that a drag-anywhere gesture can nudge.
    enum MoveTarget: Equatable { case element(UUID), furniture(UUID) }

    /// The one selected marker/furniture, if exactly one movable item is selected.
    var singleSelectedMovable: MoveTarget? {
        if let fid = furnitureSelectedID { return .furniture(fid) }
        if selectedIDs.count == 1, let id = selectedIDs.first { return .element(id) }
        return nil
    }

    func normalizedPosition(of target: MoveTarget) -> CGPoint? {
        switch target {
        case .element(let id):
            return doc.elements.first { $0.id == id }.map { CGPoint(x: $0.x, y: $0.y) }
        case .furniture(let id):
            return doc.furniture.first { $0.id == id }.map { CGPoint(x: $0.x, y: $0.y) }
        }
    }

    /// Live position update without persisting (persist once, on drag end).
    func setMovableLive(_ target: MoveTarget, to p: CGPoint) {
        switch target {
        case .element(let id):
            if let i = doc.elements.firstIndex(where: { $0.id == id }) {
                doc.elements[i].x = p.x; doc.elements[i].y = p.y
            }
        case .furniture(let id):
            if let i = doc.furniture.firstIndex(where: { $0.id == id }) {
                doc.furniture[i].x = p.x; doc.furniture[i].y = p.y
            }
        }
    }

    func rotateElement(_ id: UUID, to rotation: Double) {
        guard let index = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        doc.elements[index].rotation = rotation
        persist()
    }
}

/// Small popover shown when a camera marker is left-clicked: the linked shot's
/// reference image plus its basic info.
struct CameraShotPopover: View {
    let shot: Shot
    /// iPhone: a narrower card with a smaller still, so it fits the screen.
    var compact: Bool = false
    /// Resolved card width — capped by the caller to the space available, so the
    /// card (and its still) shrink to fit a small or resized window.
    var width: CGFloat = 264

    private var cardWidth: CGFloat { width }
    /// The still fills the card width (minus padding) at a 16:9 crop, so it scales
    /// with the card.
    private var imageSize: CGSize {
        let w = width - 24
        return CGSize(width: w, height: (w * 9 / 16).rounded())
    }

    private var referenceImage: PlatformImage? {
        shot.references.sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { $0.imageData }.first.flatMap(PlatformImage.init(data:))
    }
    private var sizeText: String? {
        guard shot.hasSize else { return nil }
        return shot.hasSecondSize ? "\(shot.sizeShort) → \(shot.secondSizeShort)" : shot.sizeShort
    }
    private var typeText: String? {
        guard shot.hasType else { return nil }
        var t = shot.typeShort
        if shot.hasSecondType { t += " + \(shot.secondTypeShort)" }
        if shot.hasThirdType { t += " + \(shot.thirdTypeShort)" }
        return t
    }
    private var gripText: String? { shot.hasGrip ? shot.gripName : nil }
    private var focalText: String? {
        guard shot.lensfocal > 0 else { return nil }
        if !shot.lensIsPrime, shot.lensfocalEnd > 0, shot.lensfocalEnd != shot.lensfocal {
            return "\(shot.lensfocal)–\(shot.lensfocalEnd)mm"
        }
        return "\(shot.lensfocal)mm"
    }
    private var extraText: String? {
        let t = shot.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let nickname = shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(nickname.isEmpty ? "Shot \(shot.displayNumber)" : "Shot \(shot.displayNumber) – \(nickname)")
                .font(.headline)
                .lineLimit(1)
            if let image = referenceImage {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: imageSize.width, height: imageSize.height)
                    .overlay(Image(systemName: "photo").font(.title2).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 3) {
                infoRow("Size", sizeText)
                infoRow("Type", typeText)
                infoRow("Grip", gripText)
                infoRow("Focal Length", focalText)
                infoRow("Extra Info", extraText)
            }
        }
        .padding(12)
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack(alignment: .top, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Text(value).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
