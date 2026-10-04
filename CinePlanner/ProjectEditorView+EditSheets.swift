//
//  ProjectEditorView+EditSheets.swift
//  CinePlanner
//
//  The scene and shot edit sheets and their form sections.
//

import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

extension ProjectEditorView {
    // MARK: - Sheet Views

    @ViewBuilder
    func editSceneSheet(for scene: Scene) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Scene")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Scene \(scene.sceneNumber)\(scene.suffix)\(scene.nickname.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " — \(scene.nickname)")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sceneDetailsSection(for: scene)
                    sceneScriptLocationSection(for: scene)
                    sceneTimeAndLocationSection(for: scene)
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Done") { sceneToEdit = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 480, height: 620)
    }

    /// A titled card matching the Edit Shot sheet — a caps label above a rounded,
    /// tinted container. Shared by the Edit Scene sections.
    @ViewBuilder
    func settingsCard<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    /// One labelled row inside a `settingsCard`: name on the left, control right.
    @ViewBuilder
    func settingsRow<Content: View>(_ label: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 8)
            content()
        }
    }

    @ViewBuilder
    func editShotSheet(for shot: Shot) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "number.square.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shot Numbering")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Currently shown as Shot \(shot.displayNumber)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text("NUMBERING STYLE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                numberingOptionRow(shot, style: .numbers, title: "Scene Numbers",
                                   detail: "Numbered within each scene: 1, 2, 3…")
                numberingOptionRow(shot, style: .letters, title: "Scene Letters",
                                   detail: "Lettered within each scene: A, B, C…")
                numberingOptionRow(shot, style: .continuous, title: "Continuous",
                                   detail: "A unique running number across the project: 001, 002, 003…")

                Label("Changing the style updates every shot in the project.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Spacer(minLength: 0)
            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Done") { shotToEdit = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 480, height: 440)
    }

    /// One selectable numbering-style card: a radio dot, its name and description,
    /// and a live preview of how this shot would read in that style.
    @ViewBuilder
    func numberingOptionRow(_ shot: Shot, style: ShotNumberingStyle,
                                    title: String, detail: String) -> some View {
        let isSelected = shot.numberingStyle == style
        Button {
            applyNumberingStyleToAllShots(style)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(shot.formattedNumber(style: style))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.15),
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Scene Form Sections
    
    @ViewBuilder
    func sceneDetailsSection(for scene: Scene) -> some View {
        settingsCard("SCENE DETAILS") {
            settingsRow("Scene Number") {
                TextField("Number", value: Binding(
                    get: { scene.sceneNumber },
                    set: { scene.sceneNumber = max(1, $0) }
                ), format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
            }

            Divider()

            settingsRow("Suffix") {
                HStack(spacing: 8) {
                    Text("\(scene.suffix.count)/5")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    TextField("None", text: Binding(
                        get: { scene.suffix },
                        set: { newValue in
                            if newValue.count <= 5 { scene.suffix = newValue.uppercased() }
                        }
                    ))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                }
            }

            Divider()

            settingsRow("Nickname") {
                TextField("Optional name", text: Binding(
                    get: { scene.nickname },
                    set: { scene.nickname = $0 }
                ))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }
        }
    }

    @ViewBuilder
    func sceneScriptLocationSection(for scene: Scene) -> some View {
        settingsCard("SCRIPT LOCATION") {
            settingsRow("Scene Page") {
                HStack(spacing: 8) {
                    if scene.scriptPageNumber > 0 {
                        Text("PDF page \(scene.absolutePDFPage + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Page", value: Binding(
                        get: { scene.scriptPageNumber }, // Already 1-based
                        set: { scene.scriptPageNumber = max(1, $0) } // Minimum page 1
                    ), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                }
            }
        }
    }

    @ViewBuilder
    func sceneTimeAndLocationSection(for scene: Scene) -> some View {
        settingsCard("TIME & LOCATION") {
            settingsRow("Time of Day") {
                Picker("Time", selection: Binding(
                    get: { scene.isDay ? "Day" : "Night" },
                    set: { scene.isDay = ($0 == "Day") }
                )) {
                    Text("Day").tag("Day")
                    Text("Night").tag("Night")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            Divider()

            settingsRow("Location Type") {
                Picker("Location", selection: Binding(
                    get: { scene.isInterior ? "Int." : "Ext." },
                    set: { scene.isInterior = ($0 == "Int.") }
                )) {
                    Text("Int.").tag("Int.")
                    Text("Ext.").tag("Ext.")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }
}
