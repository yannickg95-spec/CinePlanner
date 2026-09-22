//
//  SceneMapText.swift
//  CinePlanner
//
//  A free text annotation on a scene map: upright, a constant on-screen size (it
//  counters the map's zoom/placement scale and rotation like the marker labels),
//  draggable to reposition, tap to edit, right-click to edit or delete.
//

import SwiftUI

struct MapTextView: View {
    let text: MapText
    let contentRect: CGRect
    /// Canvas zoom and map placement, so the note counters them to stay upright and a
    /// constant on-screen size while the map is zoomed, scaled or rotated under it.
    var zoom: CGFloat = 1
    var placeScale: CGFloat = 1
    var placeRotation: Double = 0
    /// Keep the note inside the map bounds (snap to edge) unless the map allows pieces
    /// in the white margin.
    var clampToBounds: Bool = true
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var livePosition: CGPoint?
    @State private var grabOffset: CGSize = .zero

    private var center: CGPoint {
        CGPoint(x: contentRect.minX + text.x * contentRect.width,
                y: contentRect.minY + text.y * contentRect.height)
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let nx = (p.x - contentRect.minX) / contentRect.width
        let ny = (p.y - contentRect.minY) / contentRect.height
        guard clampToBounds else { return CGPoint(x: nx, y: ny) }
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    var body: some View {
        let counter = 1 / max(zoom * placeScale, 0.0001)
        let empty = text.string.trimmingCharacters(in: .whitespaces).isEmpty
        Text(empty ? "Text" : text.string)
            .font(.system(size: CGFloat(text.fontSize), weight: .semibold))
            .foregroundStyle(Color(hex: text.colorHex))
            .opacity(empty ? 0.4 : 1)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .scaleEffect(counter, anchor: .center)
            .rotationEffect(.degrees(-placeRotation))
            .position(livePosition ?? center)
            .onTapGesture { onSelect(); onEdit() }
            .gesture(dragGesture)
            .contextMenu {
                Button { onEdit() } label: { Label("Edit Text", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .named(SceneMapEditorView.canvasContentSpace))
            .onChanged { value in
                onSelect()
                if livePosition == nil {
                    grabOffset = CGSize(width: center.x - value.location.x, height: center.y - value.location.y)
                }
                livePosition = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
            }
            .onEnded { value in
                let final = CGPoint(x: value.location.x + grabOffset.width, y: value.location.y + grabOffset.height)
                livePosition = nil
                onMove(normalized(final))
            }
    }
}
