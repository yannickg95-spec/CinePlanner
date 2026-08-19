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
    /// Which edge of the button the popover's arrow attaches to. `.bottom` (the
    /// default) opens above the button; `.top` opens below it — useful when the
    /// button sits near the top of the screen with little room above.
    var arrowEdge: Edge = .bottom
    /// iPhone only: present a detented, scrollable sheet instead of an anchored
    /// popover. Better for longer lists that a popover would crop.
    var prefersSheetOnPhone: Bool = false
    @ViewBuilder var label: () -> Label

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label() }
            .buttonStyle(.plain)
            #if os(iOS)
            .applyIf(DeviceLayout.isPhone && prefersSheetOnPhone) {
                $0.sheet(isPresented: $isPresented) { phoneSheet }
            }
            .applyIf(!(DeviceLayout.isPhone && prefersSheetOnPhone)) {
                $0.popover(isPresented: $isPresented, arrowEdge: arrowEdge) { popoverContent }
            }
            #else
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) { popoverContent }
            #endif
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                if item.isDivider {
                    Divider().padding(.vertical, 2)
                } else {
                    row(item)
                }
            }
        }
    }

    private var popoverContent: some View {
        ScrollView {
            listContent.padding(10)
        }
        .frame(width: width)
        .frame(maxHeight: 420)
        #if os(iOS)
        // Stay an anchored popover on iPhone instead of adapting to a
        // full-screen sheet for a handful of rows.
        .presentationCompactAdaptation(.popover)
        #endif
    }

    /// iPhone: a detented, scrollable sheet so the whole list fits and scrolls.
    private var phoneSheet: some View {
        ScrollView {
            listContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
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
