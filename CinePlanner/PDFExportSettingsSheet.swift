//
//  PDFExportSettingsSheet.swift
//  CinePlanner
//
//  Lets the user choose what the PDF shot-list export includes: which scenes,
//  which individual shot-detail fields, the scene map, and the reference images.
//

import SwiftUI

/// What a PDF shot-list export should contain. Defaults include everything.
struct PDFExportOptions: Equatable {
    /// nil = every scene; otherwise only scenes whose uid is in the set.
    var includedSceneUIDs: Set<String>? = nil
    /// Shot-detail fields turned OFF, by their label (e.g. "Grip", "Focal Length",
    /// "Film length", "Coverage", "Extra Info"). Empty = show every field present.
    var excludedFieldLabels: Set<String> = []
    /// Each shot's reference photos, gathered into the per-scene gallery.
    var includeReferenceImages = true
    /// The full-page scene map after each scene.
    var includeSceneMap = true

    func includesScene(_ scene: Scene) -> Bool {
        guard let ids = includedSceneUIDs else { return true }
        return ids.contains(scene.uid)
    }
    func includesField(_ label: String) -> Bool { !excludedFieldLabels.contains(label) }

    /// The special labels for the two fields that aren't camera/lens spec pairs.
    static let coverageLabel = "Coverage"
    static let extraInfoLabel = "Extra Info"

    /// The shot-detail fields actually present across `scenes`, in display order.
    /// Only fields that appear on at least one shot are returned, so the settings
    /// list shows exactly what this project has.
    static func availableFields(in scenes: [Scene]) -> [String] {
        let shots = scenes.flatMap { $0.shots }
        var fields: [String] = []
        func add(_ present: Bool, _ label: String) {
            if present, !fields.contains(label) { fields.append(label) }
        }
        add(shots.contains { $0.hasSize }, "Size")
        add(shots.contains { $0.hasType }, "Type")
        add(shots.contains { $0.lensfocal > 0 }, "Focal Length")
        add(shots.contains { $0.hasGrip }, "Grip")
        add(shots.contains { !$0.camera.isEmpty }, "Camera")
        add(shots.contains { !$0.framelines.isEmpty }, "Framelines")
        add(shots.contains { !$0.lensPreset.isEmpty }, "Lens")
        // Custom info fields (Film length, etc.), in the order they're first seen.
        for shot in shots {
            for info in shot.orderedCustomInfo {
                let value = info.exportValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                if !fields.contains(info.exportLabel) { fields.append(info.exportLabel) }
            }
        }
        add(shots.contains { !($0.scriptCoverageSelections ?? []).isEmpty }, coverageLabel)
        add(shots.contains { !$0.extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, extraInfoLabel)
        return fields
    }
}

struct PDFExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var options: PDFExportOptions
    /// All exportable scenes, in order, for the per-scene selection list.
    let scenes: [Scene]

    @State private var allScenes = true
    @State private var selectedScenes: Set<String> = []

    private var fields: [String] { PDFExportOptions.availableFields(in: scenes) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PDF Options").font(.title3.bold())
                Spacer()
                Button("Done") { commit(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            Form {
                Section {
                    ForEach(fields, id: \.self) { label in
                        Toggle(label, isOn: fieldBinding(label))
                    }
                } header: {
                    HStack {
                        Text("Shot Details")
                        Spacer()
                        Button("All") { options.excludedFieldLabels.subtract(fields) }
                            .font(.caption).buttonStyle(.borderless)
                        Text("·").foregroundStyle(.secondary)
                        Button("None") { options.excludedFieldLabels.formUnion(fields) }
                            .font(.caption).buttonStyle(.borderless)
                    }
                }

                Section("Images") {
                    Toggle("Reference images", isOn: $options.includeReferenceImages)
                    Toggle("Scene map page", isOn: $options.includeSceneMap)
                }

                Section("Scenes") {
                    Toggle("All scenes", isOn: $allScenes)
                    if !allScenes {
                        ForEach(scenes, id: \.uid) { scene in
                            Toggle(sceneLabel(scene), isOn: sceneBinding(scene))
                        }
                        if selectedScenes.isEmpty {
                            Text("Select at least one scene.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            if let ids = options.includedSceneUIDs {
                allScenes = false
                selectedScenes = ids
            } else {
                allScenes = true
                selectedScenes = Set(scenes.map(\.uid))
            }
        }
        .onChange(of: allScenes) { _, _ in commit() }
        .onChange(of: selectedScenes) { _, _ in commit() }
        .adaptiveSheetFrame(width: 440, height: 640)
    }

    private func fieldBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { !options.excludedFieldLabels.contains(label) },
            set: { on in
                if on { options.excludedFieldLabels.remove(label) } else { options.excludedFieldLabels.insert(label) }
            })
    }

    private func sceneLabel(_ scene: Scene) -> String {
        var s = "Scene \(scene.sceneNumber)\(scene.suffix)"
        let nick = scene.nickname.trimmingCharacters(in: .whitespaces)
        if !nick.isEmpty { s += " — \(nick)" }
        return s
    }

    private func sceneBinding(_ scene: Scene) -> Binding<Bool> {
        Binding(
            get: { selectedScenes.contains(scene.uid) },
            set: { on in
                if on { selectedScenes.insert(scene.uid) } else { selectedScenes.remove(scene.uid) }
            })
    }

    /// Fold the local scene selection back into the options.
    private func commit() {
        options.includedSceneUIDs = allScenes ? nil : selectedScenes
    }
}
