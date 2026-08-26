//
//  PDFExportSettingsSheet.swift
//  CinePlanner
//
//  Lets the user choose what the PDF shot-list export includes: which scenes,
//  which shot info, the scene map, and the reference images.
//

import SwiftUI

/// What a PDF shot-list export should contain. Defaults include everything.
struct PDFExportOptions: Equatable {
    /// nil = every scene; otherwise only scenes whose uid is in the set.
    var includedSceneUIDs: Set<String>? = nil
    /// The camera / lens / framelines / custom-field grid under each shot.
    var includeTechnicalSpecs = true
    var includeCoverage = true
    var includeExtraInfo = true
    /// Each shot's reference photos, gathered into the per-scene gallery.
    var includeReferenceImages = true
    /// The full-page scene map after each scene.
    var includeSceneMap = true

    func includesScene(_ scene: Scene) -> Bool {
        guard let ids = includedSceneUIDs else { return true }
        return ids.contains(scene.uid)
    }
}

struct PDFExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var options: PDFExportOptions
    /// All exportable scenes, in order, for the per-scene selection list.
    let scenes: [Scene]

    @State private var allScenes = true
    @State private var selectedScenes: Set<String> = []

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
                Section("Shot Details") {
                    Toggle("Technical specs (camera, lens, etc.)", isOn: $options.includeTechnicalSpecs)
                    Toggle("Coverage", isOn: $options.includeCoverage)
                    Toggle("Extra info", isOn: $options.includeExtraInfo)
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
        .adaptiveSheetFrame(width: 420, height: 560)
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
