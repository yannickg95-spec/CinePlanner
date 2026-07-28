//
//  ChipMenu.swift
//  CinePlanner
//
//  A left-click dropdown that opens a popover of chip-styled rows, matching the
//  size/type/grip pickers — used in place of native `Menu` so every dropdown in
//  the app looks the same. (Right-click .contextMenus stay native; macOS draws
//  those and they can't be custom-styled.)
//

import SwiftUI

struct ChipMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String? = nil
    var isSelected: Bool = false       // shows a trailing checkmark + accent tint
    var role: ButtonRole? = nil        // .destructive → red
    var isDivider: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void = {}

    static var divider: ChipMenuItem { ChipMenuItem(title: "", isDivider: true) }
}

struct ChipMenu<Label: View>: View {
    var items: [ChipMenuItem]
    var width: CGFloat = 240
    @ViewBuilder var label: () -> Label

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            if item.isDivider {
                                Divider().padding(.vertical, 2)
                            } else {
                                row(item)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(width: width)
                .frame(maxHeight: 420)
            }
    }

    private func row(_ item: ChipMenuItem) -> some View {
        Button {
            isPresented = false
            // Let the popover start dismissing before an action pops a sheet/alert
            // (macOS won't present one cleanly over an open popover).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { item.action() }
        } label: {
            HStack(spacing: 8) {
                if let icon = item.systemImage {
                    Image(systemName: icon).frame(width: 16)
                }
                Text(item.title).lineLimit(1)
                Spacer(minLength: 0)
                if item.isSelected {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .foregroundStyle(item.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(item.isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
            .contentShape(Rectangle())
            .opacity(item.isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(item.isDisabled)
    }
}
