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
    /// Start every scene on a fresh page (default). Ignored while the scene map is
    /// on, since that already forces each scene onto its own page.
    var startEachSceneOnNewPage = true

    func includesScene(_ scene: Scene) -> Bool {
        guard let ids = includedSceneUIDs else { return true }
        return ids.contains(scene.uid)
    }
    func includesField(_ label: String) -> Bool { !excludedFieldLabels.contains(label) }

    /// The special labels for the two fields that aren't camera/lens spec pairs.
    static let coverageLabel = "Coverage"
    static let extraInfoLabel = "Extra Info"

    // MARK: - Presets

    enum Preset: String, CaseIterable {
        case custom = "Custom", full = "Full", textOnly = "Text Only", basic = "Basic"
    }

    /// The standard (non-custom) field labels; anything else is a custom "tool".
    static let standardLabels: Set<String> = [
        "Size", "Type", "Focal Length", "Grip", "Camera", "Framelines", "Lens",
        coverageLabel, extraInfoLabel
    ]

    /// "Basic" drops the camera/lens spec fields, coverage, and every custom tool
    /// field (e.g. Film length), keeping Size, Type, Focal Length, Grip, Extra Info.
    static func basicExcludedLabels(fields: [String]) -> Set<String> {
        let base: Set<String> = ["Camera", "Framelines", "Lens", coverageLabel]
        let customTools = Set(fields).subtracting(standardLabels)
        return base.intersection(fields).union(customTools)
    }

    /// Which preset the current field/image choices match (scene selection aside).
    func preset(fields: [String]) -> Preset {
        let imagesFull = includeReferenceImages && includeSceneMap
        let imagesOff = !includeReferenceImages && !includeSceneMap
        if excludedFieldLabels.isEmpty, imagesFull { return .full }
        if excludedFieldLabels.isEmpty, imagesOff { return .textOnly }
        if excludedFieldLabels == Self.basicExcludedLabels(fields: fields), imagesOff { return .basic }
        return .custom
    }

    /// Apply a preset to the field/image choices (scene selection is untouched).
    mutating func apply(_ preset: Preset, fields: [String]) {
        switch preset {
        case .custom:
            break
        case .full:
            excludedFieldLabels = []; includeReferenceImages = true; includeSceneMap = true
        case .textOnly:
            excludedFieldLabels = []; includeReferenceImages = false; includeSceneMap = false
        case .basic:
            excludedFieldLabels = Self.basicExcludedLabels(fields: fields)
            includeReferenceImages = false; includeSceneMap = false
        }
    }

    // MARK: - Persistence (field/image/layout choices; scene selection is not stored)

    private static let storeKey = "pdfExportOptions_v1"
    private struct Stored: Codable {
        var excludedFieldLabels: [String]
        var includeReferenceImages: Bool
        var includeSceneMap: Bool
        var startEachSceneOnNewPage: Bool
    }

    /// Loads the last-used options (scene selection always resets to all scenes,
    /// since scene ids are project-specific).
    static func loadStored() -> PDFExportOptions {
        var options = PDFExportOptions()
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            options.excludedFieldLabels = Set(s.excludedFieldLabels)
            options.includeReferenceImages = s.includeReferenceImages
            options.includeSceneMap = s.includeSceneMap
            options.startEachSceneOnNewPage = s.startEachSceneOnNewPage
        }
        return options
    }

    func store() {
        let s = Stored(excludedFieldLabels: Array(excludedFieldLabels),
                       includeReferenceImages: includeReferenceImages,
                       includeSceneMap: includeSceneMap,
                       startEachSceneOnNewPage: startEachSceneOnNewPage)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

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
    @State private var preset: PDFExportOptions.Preset = .full

    private var fields: [String] { PDFExportOptions.availableFields(in: scenes) }
    private var currentPreset: PDFExportOptions.Preset { options.preset(fields: fields) }

    private var presetDescription: String {
        switch preset {
        case .full:     return "Everything — all details, reference images and the scene map."
        case .textOnly: return "All shot details, no images."
        case .basic:    return "Essentials only — no camera info, tools, coverage or images."
        case .custom:   return "Your own selection below."
        }
    }

    /// The coherent top panel: preset picker + description, bulk select buttons,
    /// and the page-layout toggle — the quick controls, above the detailed toggles.
    private var topControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PRESET")
                    .font(.caption2.weight(.semibold)).kerning(0.6).foregroundStyle(.secondary)
                Picker("Preset", selection: $preset) {
                    ForEach(PDFExportOptions.Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(presetDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $options.startEachSceneOnNewPage) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start each scene on a new page")
                    if options.includeSceneMap {
                        Text("Always on while the scene map is shown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(options.includeSceneMap)

            Divider()

            HStack(spacing: 10) {
                Button { selectAll() } label: {
                    Label("Select All", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                }
                Button { deselectAll() } label: {
                    Label("Deselect All", systemImage: "circle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PDF Options").font(.title3.bold())
                Spacer()
                Button("Done") { commit(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            topControls

            Divider()

            Form {
                Section("Shot Details") {
                    let mid = Int(ceil(Double(fields.count) / 2.0))
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 10) {
                            ForEach(Array(fields.prefix(mid)), id: \.self) { label in
                                Toggle(label, isOn: fieldBinding(label))
                            }
                        }
                        VStack(spacing: 10) {
                            ForEach(Array(fields.dropFirst(mid)), id: \.self) { label in
                                Toggle(label, isOn: fieldBinding(label))
                            }
                        }
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
            preset = currentPreset
        }
        .onChange(of: allScenes) { _, _ in commit() }
        .onChange(of: selectedScenes) { _, _ in commit() }
        // Applying a preset writes the options; editing a field flips back to Custom.
        .onChange(of: preset) { _, new in options.apply(new, fields: fields) }
        .onChange(of: options) { _, _ in
            let detected = currentPreset
            if detected != preset { preset = detected }
        }
        .adaptiveSheetFrame(width: 440, height: 640)
    }

    /// Turn on all shot-detail fields and both image types. Scene selection is
    /// left untouched.
    private func selectAll() {
        options.excludedFieldLabels = []
        options.includeReferenceImages = true
        options.includeSceneMap = true
    }

    /// Turn off all shot-detail fields and both image types. Scene selection is
    /// left untouched.
    private func deselectAll() {
        options.excludedFieldLabels = Set(fields)
        options.includeReferenceImages = false
        options.includeSceneMap = false
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
