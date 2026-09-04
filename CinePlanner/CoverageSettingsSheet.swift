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
import PDFKit

struct CoverageSettingsSheet: View {
    let project: Project
    let version: ScriptVersion?
    /// The host's live-preview value. Bound rather than copied so dragging the
    /// slider redraws the coverage lines behind the sheet, as it always has.
    @Binding var margin: Double

    @Environment(\.dismiss) private var dismiss
    @State private var palette: CoveragePaletteChoice = .classic
    @State private var mode: CoverageColorMode = .perScene
    /// A strip of the real script behind the preview, rendered once. Nil until it
    /// loads, or when there's no script yet — then the preview uses stand-in text.
    @State private var scriptStrip: PlatformImage?

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
            loadScriptStrip()
        }
    }

    /// Renders the top of the script's first-scene page once, off the main thread,
    /// so the preview shows real text at its real left margin.
    private func loadScriptStrip() {
        guard scriptStrip == nil,
              let data = version?.pdfData ?? project.scriptPDFData else { return }
        let page = version?.pdfPageOffset ?? 0
        Task.detached(priority: .userInitiated) {
            let image = CoveragePreview.renderStrip(pdfData: data, pageIndex: page)
            await MainActor.run { scriptStrip = image }
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
            CoveragePreview(palette: palette, margin: margin, background: scriptStrip)
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

/// A live preview of the coverage settings: a strip of the real script (or, until
/// it loads / when there's no script, stand-in text) with a single coverage line
/// laid over it. The line sits at the same fraction of the page width the real
/// renderer uses, so the margin reads truthfully against the actual text.
private struct CoveragePreview: View {
    let palette: CoveragePaletteChoice
    let margin: Double
    var background: PlatformImage? = nil

    var body: some View {
        let color = palette.displayColors.first ?? .blue
        ZStack {
            // Background: the real script strip fills the width so the margin
            // fraction maps to the same place it does on the page; otherwise a
            // stand-in of grey text lines.
            if let background {
                Image(platformImage: background)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                standInText
            }

            Canvas { ctx, size in
                // The coverage line at the band's right edge — a fraction of page
                // width — exactly where the real renderer packs it.
                let barX = max(3, size.width * CGFloat(margin))
                var path = Path()
                path.move(to: CGPoint(x: barX, y: size.height * 0.14))
                path.addLine(to: CGPoint(x: barX, y: size.height * 0.86))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                let label = Text("1.1").font(.system(size: 7, weight: .semibold)).foregroundColor(color)
                ctx.draw(label, at: CGPoint(x: barX, y: size.height * 0.14 - 5), anchor: .center)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.12), value: margin)
    }

    private var standInText: some View {
        Canvas { ctx, size in
            // Text starts around a screenplay's real left margin, so the bars to its
            // left read like the actual page even without a rendered strip.
            let textInset = size.width * 0.22
            let widths: [CGFloat] = [0.9, 0.7, 0.82, 0.6, 0.88, 0.66, 0.78, 0.72]
            let rows = 8
            let rowH = size.height / CGFloat(rows)
            for r in 0..<rows {
                let y = CGFloat(r) * rowH + rowH * 0.34
                let w = (size.width - textInset - 10) * widths[r % widths.count]
                let line = Path(roundedRect: CGRect(x: textInset, y: y, width: max(4, w), height: rowH * 0.32),
                                cornerRadius: 1.5)
                ctx.fill(line, with: .color(.gray.opacity(0.35)))
            }
        }
    }

    /// Renders the top of a script page at full page width — a wide strip whose
    /// horizontal scale is the page's, so overlaid bars land at the right margin.
    static func renderStrip(pdfData: Data, pageIndex: Int) -> PlatformImage? {
        guard let doc = PDFDocument(data: pdfData), doc.pageCount > 0 else { return nil }
        let idx = min(max(0, pageIndex), doc.pageCount - 1)
        guard let page = doc.page(at: idx) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }

        // A strip a little wider than it is tall, from the top of the page.
        let stripH = min(box.height, box.width * 0.5)
        let size = CGSize(width: box.width, height: stripH)
        return PlatformGraphics.image(size: size, scale: 2) { ctx in
            ctx.setFillColor(PlatformColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // y-up context: shift so the page's top `stripH` fills the image.
            ctx.saveGState()
            ctx.translateBy(x: -box.minX, y: -(box.maxY - stripH))
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
        }
    }
}
