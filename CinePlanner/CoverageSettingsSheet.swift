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
            VStack(alignment: .leading, spacing: 26) {
                colourSection
                distributionSection
                marginSection
                previewSection
            }
            .padding(20)
            .scrollOnPhone()   // iPad/Mac size to content; only a short phone scrolls
            Divider()
            footer
        }
        .adaptiveFittedSheetFrame(maxWidth: 460)
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

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Preview", "Two scenes of stand-in text, coloured with these settings.")
            CoveragePreview(palette: palette, mode: mode, margin: margin)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)   // decorative; the controls above carry the meaning
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

// MARK: - Live preview

/// A small stand-in for the script: two scenes of placeholder text with coverage
/// bars drawn beside them, so the palette, the distribution mode and the margin
/// can be seen together before leaving the sheet. Not the real renderer — just
/// enough to read the choices at a glance.
private struct CoveragePreview: View {
    let palette: CoveragePaletteChoice
    let mode: CoverageColorMode
    let margin: Double

    /// Two scenes of two shots. Each entry is the shot's row span within the page.
    private let scenes: [[ClosedRange<Int>]] = [[0...1, 2...3], [4...5, 6...7]]
    private let rows = 8

    /// The palette slot each shot draws in, mirroring CoverageColoring's three
    /// modes over this fixed two-scene, two-shot layout.
    private func slot(scene: Int, shot: Int, runningColorIndex: Int) -> Int {
        switch mode {
        case .perScene:     return shot
        case .acrossScript: return runningColorIndex
        case .sceneUniform: return scene
        }
    }

    var body: some View {
        let colors = palette.displayColors
        Canvas { ctx, size in
            let rowH = size.height / CGFloat(rows)
            // Right edge of the coverage band, as in the real export: a fraction of
            // page width. Text sits just past it; bars pack against it.
            let bandRight = size.width * CGFloat(margin) + 8
            let textInset = bandRight + 8
            let barX = bandRight - 5

            // Stand-in script text: grey lines of a few different widths.
            let widths: [CGFloat] = [0.9, 0.7, 0.82, 0.6, 0.88, 0.66, 0.78, 0.72]
            for r in 0..<rows {
                let y = CGFloat(r) * rowH + rowH * 0.32
                let w = (size.width - textInset - 10) * widths[r % widths.count]
                let line = Path(roundedRect: CGRect(x: textInset, y: y, width: max(4, w), height: rowH * 0.34),
                                cornerRadius: 1.5)
                ctx.fill(line, with: .color(.gray.opacity(0.35)))
            }

            // Coverage bars, one per shot, coloured by the current mode.
            var running = 0
            for (sceneIndex, shots) in scenes.enumerated() {
                for span in shots {
                    let color = colors.isEmpty ? Color.blue : colors[slot(scene: sceneIndex, shot: running, runningColorIndex: running) % colors.count]
                    let top = CGFloat(span.lowerBound) * rowH + rowH * 0.2
                    let bottom = CGFloat(span.upperBound) * rowH + rowH * 0.8
                    var bar = Path()
                    bar.move(to: CGPoint(x: barX, y: top))
                    bar.addLine(to: CGPoint(x: barX, y: bottom))
                    ctx.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    let label = Text("\(sceneIndex + 1).\(running % shots.count + 1)")
                        .font(.system(size: 7, weight: .semibold)).foregroundColor(color)
                    ctx.draw(label, at: CGPoint(x: barX, y: top - 5), anchor: .center)
                    running += 1
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.15), value: margin)
    }
}
