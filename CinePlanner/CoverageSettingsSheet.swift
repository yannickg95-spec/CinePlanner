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
    /// The host's live-preview values. Bound rather than copied so changing them
    /// redraws the coverage lines behind the sheet, as the margin always has.
    @Binding var margin: Double
    @Binding var onRight: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var palette: CoveragePaletteChoice = .classic
    @State private var mode: CoverageColorMode = .perScene
    /// A strip of the real script behind the preview, rendered once. Nil until it
    /// loads, or when there's no script yet — then the preview uses stand-in text.
    @State private var scriptStrip: PlatformImage?
    /// The scrollable content's natural height, measured so that on Mac — where the
    /// sheet is content-sized — the scroll area is capped at it (and scrolls only
    /// when the window is shorter). Unused on iOS, where the sheet is fixed-size.
    @State private var contentHeight: CGFloat = 0

    /// Cap the scroll area at the measured content height on Mac and iPad — where
    /// the sheet is sized to its content, so the content must report a real height
    /// (and it scrolls only when the sheet is capped to the screen). iPhone fills
    /// the screen, so no cap there.
    private var scrollCap: CGFloat? {
        if DeviceLayout.isPhone { return nil }
        return contentHeight == 0 ? nil : contentHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    colourSection
                    distributionSection
                    marginSection
                    previewSection
                }
                .padding(20)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            // Mac and iPad size the sheet to their content, so cap the scroll area
            // at the content height (it scrolls only when capped to the screen).
            // iPhone fills the screen.
            .frame(maxHeight: scrollCap)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .adaptiveSettingsSheet(width: 460)
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

    // MARK: Placement

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Placement", "Only this script version — it follows the page layout.")

            Picker("Side", selection: sideBinding) {
                Text("Left margin").tag(false)
                Text("Right margin").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Slider(value: $margin, in: 0.05...0.35)
                    .onChange(of: margin) { _, new in version?.coverageLineMargin = new }
                Image(systemName: "text.alignright").foregroundStyle(.secondary)
            }
            Text("\(Int((margin * 100).rounded()))% of page width from the \(onRight ? "right" : "left") edge")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// Writes the side to both the live preview binding and the model.
    private var sideBinding: Binding<Bool> {
        Binding(get: { onRight }, set: { onRight = $0; version?.coverageLinesOnRight = $0 })
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Preview", "A coverage line on your script at the chosen colour and margin.")
            CoveragePreview(palette: palette, margin: margin, onRight: onRight, background: scriptStrip)
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
                onRight = false
                palette = .classic
                mode = .perScene
                version?.coverageLineMargin = 0.15
                version?.coverageLinesOnRight = false
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

// MARK: - Content-height measurement

/// Carries the scrollable content's natural height up to the sheet, so the scroll
/// area can be capped at exactly that.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    var onRight: Bool = false
    var background: PlatformImage? = nil

    var body: some View {
        let colors = palette.displayColors
        // The box takes the strip's own aspect ratio, so the image maps onto it
        // one-to-one: no cropping, the scene heading stays at the very top, and the
        // margin fraction lands exactly where it does on the page. (`.fill` cropped
        // symmetrically, which cut the heading off no matter the alignment.)
        let aspect = background?.size ?? CGSize(width: 2.5, height: 1)
        ZStack {
            if let background {
                Image(platformImage: background).resizable()
            } else {
                standInText
            }

            Canvas { ctx, size in
                // Three lines placed by the real layout, so the gaps between them and
                // to the script match the actual renderer. Solve in page points, then
                // scale the result into the preview: the strip is the full page width,
                // so preview width maps to page width.
                let labels = ["1.1", "1.2", "1.3"]
                let pageW = background?.size.width ?? 595
                let scale = size.width / pageW
                let baseFont = PlatformFont.boldSystemFont(ofSize: 11)
                func labelWidth(_ s: String) -> CGFloat {
                    NSAttributedString(string: s, attributes: [.font: baseFont]).size().width
                }
                // Same band as exportLineRange, on the chosen side: a fraction of
                // page width in from the near edge.
                let span = pageW * CGFloat(margin)
                let band: ClosedRange<CGFloat> = onRight ? (pageW - span)...pageW : 0...span
                let extent: ClosedRange<CGFloat> = 0...100   // all three overlap → three columns
                let placed = CoverageLineLayout.solve(labels.map {
                    CoverageLineLayout.Line(extent: extent, band: band,
                                            labelWidth: labelWidth($0), labelBand: 0...20)
                }, onRight: onRight)

                let top = max(9, size.height * 0.22)   // keep the numbers inside the box
                let bottom = size.height * 0.92
                for (i, p) in placed.enumerated() {
                    let x = p.x * scale
                    let color = colors.isEmpty ? .blue : colors[i % colors.count]
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: top))
                    path.addLine(to: CGPoint(x: x, y: bottom))
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    let label = Text(labels[i]).font(.system(size: 7, weight: .semibold)).foregroundColor(color)
                    ctx.draw(label, at: CGPoint(x: x, y: top - 5), anchor: .center)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
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

    /// Renders a strip of a script page at full page width — its horizontal scale
    /// is the page's, so overlaid bars land at the right margin. Starts at the
    /// first scene heading on the page, trimming the top margin and page number,
    /// so the preview opens on scene content rather than blank space.
    static func renderStrip(pdfData: Data, pageIndex: Int) -> PlatformImage? {
        guard let doc = PDFDocument(data: pdfData), doc.pageCount > 0 else { return nil }
        let idx = min(max(0, pageIndex), doc.pageCount - 1)
        guard let page = doc.page(at: idx) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }

        // Wider than tall (~2.6:1) — the preview box takes this aspect, so a
        // shorter strip keeps the box from getting too tall.
        let stripH = min(box.height, box.width * 0.38)
        // Where the content starts (y-up), a little above it for breathing room,
        // capped at the page top. Falls back to the page top if nothing is found.
        let contentTop = contentTopY(on: page) ?? box.maxY
        let stripTop = min(box.maxY, contentTop + 10)

        let size = CGSize(width: box.width, height: stripH)
        return PlatformGraphics.image(size: size, scale: 2) { ctx in
            ctx.setFillColor(PlatformColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // y-up context: shift so the strip [stripTop - stripH ... stripTop]
            // fills the image, top-aligned.
            ctx.saveGState()
            ctx.translateBy(x: -box.minX, y: -(stripTop - stripH))
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
        }
    }

    /// The top y (y-up) of the first scene heading on the page, or the first real
    /// text line when no heading is found — skipping a lone page number at the top.
    private static func contentTopY(on page: PDFPage) -> CGFloat? {
        guard let whole = page.selection(for: page.bounds(for: .mediaBox)) else { return nil }
        let lines = whole.selectionsByLine().compactMap { line -> (top: CGFloat, text: String)? in
            let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            return (line.bounds(for: page).maxY, text)
        }.sorted { $0.top > $1.top }   // top of page first

        if let heading = lines.first(where: { isSceneHeading($0.text) }) { return heading.top }
        // No heading (a scene that continues onto this page): first line that isn't
        // just a page number.
        return lines.first(where: { !isPageNumber($0.text) })?.top ?? lines.first?.top
    }

    private static func isSceneHeading(_ line: String) -> Bool {
        line.uppercased().range(of: "(?<![A-Z])(INT|EXT|I/E)(?![A-Z])", options: .regularExpression) != nil
    }

    private static func isPageNumber(_ line: String) -> Bool {
        line.range(of: "^[0-9]{1,4}\\.?$", options: .regularExpression) != nil
    }
}
