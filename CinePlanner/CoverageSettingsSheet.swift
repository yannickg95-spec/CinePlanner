//
//  CoverageSettingsSheet.swift
//  CinePlanner
//
//  Everything about how coverage lines look, in one sheet reached from the
//  script's settings menu. The margin belongs to the script version, since it
//  matches that script's page layout; the colours belong to the project, so a
//  series looks the same across its episodes and, through iCloud, on every
//  device.
//
//  Shared by the Mac and the iPhone/iPad script views, which each used to carry
//  their own copy of the margin sheet.
//

import SwiftUI
import SwiftData

struct CoverageSettingsSheet: View {
    let project: Project
    let version: ScriptVersion?
    /// The host's live-preview value. Bound rather than copied so dragging the
    /// slider redraws the coverage lines behind the sheet, as it always has.
    @Binding var margin: Double

    @Environment(\.dismiss) private var dismiss
    @State private var palette: CoveragePaletteChoice = .classic
    @State private var mode: CoverageColorMode = .perScene

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    colourSection
                    distributionSection
                    marginSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .adaptiveSheetFrame(width: 460, height: 620)
        .onAppear {
            palette = project.coveragePalette
            mode = project.coverageColorMode
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Coverage Lines").font(.title3.bold())
            Text("How the lines beside the script are coloured and placed.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Colours

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Colours", "Applies to every episode in this project.")
            ForEach(CoveragePaletteChoice.allCases) { choice in
                Button {
                    palette = choice
                    project.coveragePalette = choice
                } label: {
                    HStack(spacing: 12) {
                        swatches(choice)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.label).font(.body)
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: palette == choice ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(palette == choice ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(palette == choice ? .isSelected : [])
            }
        }
    }

    private func swatches(_ choice: CoveragePaletteChoice) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(choice.displayColors.prefix(6).enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 5, height: 22)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: Distribution

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Distribution", "Which shots end up sharing a colour.")
            ForEach(CoverageColorMode.allCases) { option in
                Button {
                    mode = option
                    project.coverageColorMode = option
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mode == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(mode == option ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.body)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
    }

    // MARK: Margin

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Margin", "Only this script version — it follows the page layout.")
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Slider(value: $margin, in: 0.05...0.35)
                    .onChange(of: margin) { _, new in version?.coverageLineMargin = new }
                Image(systemName: "text.alignright").foregroundStyle(.secondary)
            }
            Text("\(Int((margin * 100).rounded()))% of page width")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: Chrome

    private func sectionTitle(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset") {
                margin = 0.15
                palette = .classic
                mode = .perScene
                version?.coverageLineMargin = 0.15
                project.coveragePalette = .classic
                project.coverageColorMode = .perScene
            }
            Spacer()
            Button("Done") {
                try? project.modelContext?.save()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
