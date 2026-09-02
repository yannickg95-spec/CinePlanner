//
//  ChipMenu.swift
//  CinePlanner
//
//  A left-click dropdown, now backed by a native `Menu` (it opens instantly and
//  lets you go straight from one dropdown to another). The item model and the
//  call-site API are unchanged, so every existing ChipMenu keeps working.
//

import SwiftUI

struct ChipMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String? = nil
    var isSelected: Bool = false       // shows a trailing checkmark
    var role: ButtonRole? = nil        // .destructive → red
    var isDivider: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void = {}

    static var divider: ChipMenuItem { ChipMenuItem(title: "", isDivider: true) }
}

struct ChipMenu<Label: View>: View {
    var items: [ChipMenuItem]
    // Kept for source compatibility with existing call sites; the native menu
    // sizes and positions itself, so these no longer have an effect.
    var width: CGFloat = 240
    var arrowEdge: Edge = .bottom
    var prefersSheetOnPhone: Bool = false
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            ForEach(items) { item in
                if item.isDivider {
                    Divider()
                } else {
                    Button(role: item.role) { item.action() } label: {
                        if item.isSelected {
                            menuSelectionLabel(item.title, isSelected: true)
                        } else if let icon = item.systemImage {
                            SwiftUI.Label(item.title, systemImage: icon)
                        } else {
                            Text(item.title)
                        }
                    }
                    .disabled(item.isDisabled)
                }
            }
        } label: {
            label()
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // Render the label exactly as authored (no control bezel/tint), so custom
        // labels like the round GitHub button look identical to iOS/iPadOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        #endif
    }
}
