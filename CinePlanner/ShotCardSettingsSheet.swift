//
//  ShotCardSettingsSheet.swift
//  CinePlanner
//
//  Per-project settings for the shot detail cards, opened from the gear on either
//  the Shot Setup or Camera Information card:
//   • the order of the Shot Setup fields, and which are hidden, and
//   • a default camera package new shots inherit (each shot stays editable).
//  Both are stored on the Project and sync via CloudKit.
//

import SwiftUI
import SwiftData

struct ShotCardSettingsSheet: View {
    @Bindable var project: Project
    @Environment(\.dismiss) private var dismiss

    /// The field a drag is hovering over — draws the insertion line.
    @State private var dropTarget: ShotSetupField?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    shotSetupSection
                    cameraSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("Card Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    // MARK: - Shot Setup: order + visibility

    private var shotSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("SHOT SETUP — FIELDS")
            // Every field appears here (so hidden ones can be brought back);
            // the shot editor renders them in this order, skipping hidden ones.
            VStack(spacing: 6) {
                ForEach(project.shotSetupFieldOrder) { field in
                    fieldRow(field)
                }
            }
            Text("Drag to reorder. Tap the eye to hide a field for this project — hidden fields don't appear in the shot editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func fieldRow(_ field: ShotSetupField) -> some View {
        let hidden = project.hiddenShotSetupFields.contains(field)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Text(field.label)
                .foregroundStyle(hidden ? .secondary : .primary)
                .strikethrough(hidden, color: .secondary)
            Spacer(minLength: 8)
            Button { toggleHidden(field) } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .foregroundStyle(hidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .help(hidden ? "Show this field" : "Hide this field for this project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1))
        .overlay(alignment: .top) {
            if dropTarget == field {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -4)
            }
        }
        .contentShape(Rectangle())
        // ScrollView (not a List), so draggable + dropDestination reorders on
        // both macOS and iPadOS/iOS.
        .draggable(field.rawValue)
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let first = items.first else { return false }
            return moveField(first, before: field)
        } isTargeted: { on in
            if on { dropTarget = field } else if dropTarget == field { dropTarget = nil }
        }
    }

    @discardableResult
    private func moveField(_ draggedRaw: String, before target: ShotSetupField) -> Bool {
        guard let dragged = ShotSetupField(rawValue: draggedRaw), dragged != target else { return false }
        var order = project.shotSetupFieldOrder
        guard let from = order.firstIndex(of: dragged) else { return false }
        order.remove(at: from)
        let insertAt = order.firstIndex(of: target) ?? order.count
        order.insert(dragged, at: insertAt)
        project.shotSetupFieldOrder = order
        try? project.modelContext?.save()
        return true
    }

    private func toggleHidden(_ field: ShotSetupField) {
        var hidden = project.hiddenShotSetupFields
        if hidden.contains(field) { hidden.remove(field) } else { hidden.insert(field) }
        project.hiddenShotSetupFields = hidden
        try? project.modelContext?.save()
    }

    // MARK: - Camera Information: project default

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CAMERA INFORMATION — PROJECT DEFAULT")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                defaultRow("Camera · Format", text: $project.defaultCamera,
                           suggestions: distinctValues(\.camera))
                defaultRow("Framelines", text: $project.defaultFramelines,
                           suggestions: distinctValues(\.framelines))
                defaultRow("Lens", text: $project.defaultLens,
                           suggestions: distinctValues(\.lensPreset))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformTextBackground)
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1))
            Text("New shots in this project start with these camera values. Each shot stays independently editable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// One row of the camera-default grid: a label cell and a value cell (field +
    /// optional suggestions menu). The Grid keeps every label and every field
    /// column-aligned automatically.
    private func defaultRow(_ label: String, text: Binding<String>, suggestions: [String]) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
            HStack(spacing: 4) {
                DebouncedTextField(LocalizedStringKey(label), text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                // Pick from values already used elsewhere in this project.
                if !suggestions.isEmpty {
                    ChipMenu(items: suggestions.map { value in
                        ChipMenuItem(title: value) { text.wrappedValue = value }
                    }, prefersSheetOnPhone: true) {
                        Image(systemName: "chevron.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .help("Choose from values already used in this project")
                }
            }
            .gridColumnAlignment(.leading)
        }
    }

    /// Distinct non-empty values of a shot field across every shot in the project,
    /// sorted — the choices offered for the project default.
    private func distinctValues(_ keyPath: KeyPath<Shot, String>) -> [String] {
        var values = Set<String>()
        for shot in allProjectShots {
            let value = shot[keyPath: keyPath]
            if !value.isEmpty { values.insert(value) }
        }
        return values.sorted()
    }

    /// Every shot in the project — across direct scenes and, for a series, all
    /// episodes' script versions — so the default can reuse a camera setup from
    /// any episode.
    private var allProjectShots: [Shot] {
        var shots: [Shot] = project.scenes.flatMap { $0.shots }
        for version in project.scriptVersions {
            shots += version.scenes.flatMap { $0.shots }
        }
        for episode in project.episodes {
            for version in episode.scriptVersions {
                shots += version.scenes.flatMap { $0.shots }
            }
        }
        return shots
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption).fontWeight(.semibold).kerning(0.5)
            .foregroundStyle(.secondary)
    }
}
