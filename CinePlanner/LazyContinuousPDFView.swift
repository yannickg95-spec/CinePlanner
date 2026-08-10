//
//  LazyContinuousPDFView.swift
//  CinePlanner
//
//  An iPad script viewer that scrolls continuously through a screenplay WITHOUT
//  the freeze PDFKit's `.singlePageContinuous` causes: PDFView lays out (and
//  holds) every page up front, which hangs iPad each time a version's script
//  loads. This instead renders pages lazily in a UICollectionView — only the
//  visible pages are rasterised — so switching versions never lays out the whole
//  document. Coverage lines are drawn per page (each cell is exactly one page, so
//  the page→view mapping is a simple scale, no cross-page conversion).
//
//  iOS only; macOS keeps PDFKit's PDFView.
//

#if canImport(UIKit)
import SwiftUI
import SwiftData
import PDFKit
import UIKit

struct LazyContinuousPDFView: UIViewRepresentable {
    let document: PDFDocument
    /// 0-based page to scroll to when it changes.
    let pageToDisplay: Int?
    /// The scene to align to, so we can scroll to its heading (not just page top).
    let sceneToAlign: Scene?
    let selectedShot: Shot?
    let project: Project
    let version: ScriptVersion?
    /// Reports the top visible page (0-based) as the user scrolls.
    @Binding var currentPageIndex: Int

    /// Per-shot coverage bar for one page: a colour, a label, and the vertical
    /// span (in page coordinates, y-up) it should mark.
    struct Bar { let color: UIColor; let label: String; let minY: CGFloat; let maxY: CGFloat }

    private static let palette: [UIColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink,
        .systemTeal, .systemIndigo, .systemRed, .systemYellow, .systemBrown
    ]

    /// Coverage bars grouped by page index, for the current version's shots.
    private func barsByPage() -> [Int: [Bar]] {
        var result: [Int: [Bar]] = [:]
        let scenes = version?.scenes ?? project.scenes
        for scene in scenes {
            for shot in scene.shots {
                guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { continue }
                let colorIndex = (scene.shots.firstIndex { $0 === shot } ?? 0) % Self.palette.count
                let color = Self.palette[colorIndex]
                for selection in selections {
                    for pageRange in selection.pageRanges {
                        let ys = pageRange.selections.map(\.cgRect)
                        guard let minY = ys.map(\.minY).min(), let maxY = ys.map(\.maxY).max() else { continue }
                        result[pageRange.pageIndex, default: []].append(
                            Bar(color: color, label: shot.displayNumber, minY: minY, maxY: maxY))
                    }
                }
            }
        }
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .secondarySystemBackground
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.register(PageCell.self, forCellWithReuseIdentifier: PageCell.reuseID)
        cv.alwaysBounceVertical = true

        context.coordinator.collectionView = cv
        context.coordinator.apply(document: document, bars: barsByPage())
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.onPageChange = { idx in
            if currentPageIndex != idx { currentPageIndex = idx }
        }
        let changedDocument = context.coordinator.document !== document
        if changedDocument {
            context.coordinator.apply(document: document, bars: barsByPage())
            cv.reloadData()
        } else {
            // Coverage may have changed even when the document didn't — re-configure
            // the visible cells with the freshly computed bars (not just redraw).
            context.coordinator.bars = barsByPage()
            for cell in cv.visibleCells {
                guard let pc = cell as? PageCell, let ip = cv.indexPath(for: cell) else { continue }
                let pageBounds = document.page(at: ip.item)?.bounds(for: .cropBox) ?? .zero
                pc.configure(bars: context.coordinator.bars[ip.item] ?? [], pageBounds: pageBounds)
            }
        }

        // Scroll to the requested page (aligned to the scene heading) when it
        // changes, or right after a document reload.
        let sceneID = sceneToAlign?.persistentModelID
        if let page = pageToDisplay,
           page != context.coordinator.lastScrolledPage || sceneID != context.coordinator.lastAlignedScene || changedDocument,
           page >= 0, page < document.pageCount {
            context.coordinator.lastScrolledPage = page
            context.coordinator.lastAlignedScene = sceneID
            let headingY = headingTopY(forPage: page, scene: sceneToAlign)
            DispatchQueue.main.async {
                guard page < cv.numberOfItems(inSection: 0) else { return }
                context.coordinator.scroll(toPage: page, headingPageY: headingY, in: cv)
            }
        }
    }

    // MARK: - Scene-heading detection (to scroll to the heading, not the page top)

    private func isHeadingLine(_ line: String) -> Bool {
        line.uppercased().range(of: "(?<![A-Z])(INT|EXT|I/E)(?![A-Z])",
                                options: .regularExpression) != nil
    }

    /// The page-space y (y-up, the top of the heading line) for `scene` on `page`,
    /// or nil to fall back to the page top. Mirrors the macOS PDFView aligner.
    private func headingTopY(forPage pageIndex: Int, scene: Scene?) -> CGFloat? {
        guard let scene, let page = document.page(at: pageIndex) else { return nil }
        let targetPage = scene.absolutePDFPage
        let scenesOnPage = (version?.orderedScenes ?? project.scenes.sorted { $0.sortOrder < $1.sortOrder })
            .filter { $0.absolutePDFPage == targetPage }
        let occurrence = scenesOnPage.firstIndex(where: { $0 === scene }) ?? 0
        let location = scene.nickname.trimmingCharacters(in: .whitespaces).uppercased()

        guard let wholePage = page.selection(for: page.bounds(for: .mediaBox)) else { return nil }
        var headings: [(location: String, top: CGFloat)] = []
        for line in wholePage.selectionsByLine() {
            guard let raw = line.string?.trimmingCharacters(in: .whitespaces),
                  isHeadingLine(raw) else { continue }
            let parsed = ScreenplayParser.headingLocation(of: raw) ?? raw
            headings.append((parsed.trimmingCharacters(in: .whitespaces).uppercased(),
                             line.bounds(for: page).maxY))
        }
        guard !headings.isEmpty else { return nil }
        let positional = headings[min(occurrence, headings.count - 1)]
        if location.isEmpty || positional.location == location { return positional.top }
        let named = headings.filter { $0.location == location }
        guard !named.isEmpty else { return positional.top }
        let sameLocation = scenesOnPage.filter {
            $0.nickname.trimmingCharacters(in: .whitespaces).uppercased() == location
        }
        let index = sameLocation.firstIndex(where: { $0 === scene }) ?? 0
        return named[min(index, named.count - 1)].top
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        private let parent: LazyContinuousPDFView
        weak var collectionView: UICollectionView?
        private(set) var document: PDFDocument?
        var bars: [Int: [Bar]] = [:]
        var onPageChange: ((Int) -> Void)?
        var lastScrolledPage: Int?
        var lastAlignedScene: PersistentIdentifier?

        /// Page aspect (height / width) from the first page; screenplay pages are
        /// uniform, so one aspect sizes every cell.
        private var pageAspect: CGFloat = 1.294   // US Letter default (11/8.5)
        private let renderCache = NSCache<NSNumber, UIImage>()
        private let renderQueue = DispatchQueue(label: "pdf.page.render", qos: .userInitiated)

        init(_ parent: LazyContinuousPDFView) { self.parent = parent }

        func apply(document: PDFDocument, bars: [Int: [Bar]]) {
            self.document = document
            self.bars = bars
            self.lastScrolledPage = nil
            renderCache.removeAllObjects()
            if let first = document.page(at: 0) {
                let b = first.bounds(for: .cropBox)
                if b.width > 0 { pageAspect = b.height / b.width }
            }
        }

        /// Scrolls so page `page`'s scene heading (in page-space y-up, or the page
        /// top when nil) sits at the top of the viewport. Item heights are uniform,
        /// so the offset is computed directly rather than via layout attributes.
        func scroll(toPage page: Int, headingPageY: CGFloat?, in cv: UICollectionView) {
            guard let doc = document, page >= 0, page < doc.pageCount,
                  let pdfPage = doc.page(at: page) else { return }
            let width = cv.bounds.width
            guard width > 0 else { return }
            let itemHeight = (width * pageAspect).rounded()
            let sectionTop: CGFloat = 12, lineSpacing: CGFloat = 12
            let itemOriginY = sectionTop + CGFloat(page) * (itemHeight + lineSpacing)

            var offsetInCell: CGFloat = 0
            if let headingPageY {
                let pb = pdfPage.bounds(for: .cropBox)
                if pb.height > 0 {
                    // headingPageY is y-up (page space); convert to the cell's y-down
                    // top, leaving a small margin above the heading.
                    let frac = (headingPageY - pb.minY) / pb.height   // 1 near top
                    offsetInCell = max(0, itemHeight * (1 - frac) - 14)
                }
            }

            let maxOffset = max(0, cv.collectionViewLayout.collectionViewContentSize.height - cv.bounds.height)
            let target = min(max(0, itemOriginY + offsetInCell), maxOffset)
            cv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            document?.pageCount ?? 0
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = collectionView.bounds.width
            return CGSize(width: width, height: (width * pageAspect).rounded())
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageCell.reuseID, for: indexPath) as! PageCell
            let index = indexPath.item
            cell.configure(bars: bars[index] ?? [], pageBounds: document?.page(at: index)?.bounds(for: .cropBox) ?? .zero)

            if let cached = renderCache.object(forKey: NSNumber(value: index)) {
                cell.setImage(cached, forIndex: index)
            } else {
                cell.setImage(nil, forIndex: index)
                let size = self.collectionView(collectionView, layout: collectionView.collectionViewLayout, sizeForItemAt: indexPath)
                let scale = collectionView.traitCollection.displayScale
                renderQueue.async { [weak self, weak collectionView] in
                    guard let self, let page = self.document?.page(at: index) else { return }
                    let image = Self.render(page: page, size: size, scale: scale)
                    self.renderCache.setObject(image, forKey: NSNumber(value: index))
                    DispatchQueue.main.async {
                        // Only apply if the cell is still showing this page.
                        guard let cv = collectionView,
                              let visible = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? PageCell
                        else { return }
                        visible.setImage(image, forIndex: index)
                    }
                }
            }
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView else { return }
            // Topmost visible page = the current page.
            let topPoint = CGPoint(x: cv.bounds.midX, y: cv.contentOffset.y + 8)
            if let indexPath = cv.indexPathForItem(at: topPoint) {
                onPageChange?(indexPath.item)
            }
        }

        /// Rasterises a PDF page to a white-backed image at `size` (× screen scale).
        static func render(page: PDFPage, size: CGSize, scale: CGFloat) -> UIImage {
            let bounds = page.bounds(for: .cropBox)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                let cg = ctx.cgContext
                UIColor.white.setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                guard bounds.width > 0, bounds.height > 0 else { return }
                cg.saveGState()
                // Flip to PDF's y-up space and scale the page to fill the cell.
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: size.width / bounds.width, y: -size.height / bounds.height)
                cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
            }
        }
    }
}

// MARK: - Coverage marking (iPad)

/// A selectable single-page PDFView for marking coverage on iPad (the lazy viewer
/// is image-based and can't select text). Single-page avoids the continuous-layout
/// freeze; the user selects on the visible page.
struct ScriptSelectionView: UIViewRepresentable {
    let document: PDFDocument
    let initialPage: Int?
    /// Set so the sheet can read the current selection when the user taps Save.
    let pdfViewRef: PDFViewBox

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePage
        v.usePageViewController(true)
        v.document = document
        pdfViewRef.view = v
        if let p = initialPage, let page = document.page(at: p) {
            DispatchQueue.main.async { v.go(to: page) }
        }
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document !== document { v.document = document }
        pdfViewRef.view = v
    }
}

/// Holds a weak reference to the marking PDFView so the sheet can read its selection.
final class PDFViewBox { weak var view: PDFView? }

struct MarkCoverageSheet: View {
    let document: PDFDocument
    let shot: Shot
    let initialPage: Int?
    @Environment(\.dismiss) private var dismiss
    private let box = PDFViewBox()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Select the script text this shot covers, then tap Save.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.08))
                Divider()
                ScriptSelectionView(document: document, initialPage: initialPage, pdfViewRef: box)
            }
            .navigationTitle("Mark Coverage — Shot \(shot.displayNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                }
            }
        }
    }

    /// Captures the PDFView's current text selection into the shot's coverage,
    /// mirroring the macOS capture flow.
    private func save() {
        guard let pdfView = box.view,
              let selection = pdfView.currentSelection,
              !(selection.string?.isEmpty ?? true) else { return }
        var pageRanges: [PageTextRange] = []
        for page in selection.pages {
            guard let pageIndex = pdfView.document?.index(for: page) else { continue }
            var bounds: [PDFSelectionBounds] = []
            for line in selection.selectionsByLine() where line.pages.contains(page) {
                let b = line.bounds(for: page)
                if !b.isEmpty { bounds.append(PDFSelectionBounds(from: b)) }
            }
            if bounds.isEmpty {
                let b = selection.bounds(for: page)
                if !b.isEmpty { bounds.append(PDFSelectionBounds(from: b)) }
            }
            if !bounds.isEmpty { pageRanges.append(PageTextRange(pageIndex: pageIndex, selections: bounds)) }
        }
        guard !pageRanges.isEmpty else { return }
        let selection2 = ScriptTextSelection(pageRanges: pageRanges, fullText: selection.string ?? "")
        if shot.scriptCoverageSelections == nil { shot.scriptCoverageSelections = [] }
        shot.scriptCoverageSelections?.append(selection2)
    }
}

// MARK: - Page cell

private final class PageCell: UICollectionViewCell {
    static let reuseID = "PageCell"

    private let imageView = UIImageView()
    private let overlay = CoverageBarsView()
    private var index: Int = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .white
        imageView.layer.borderColor = UIColor.separator.cgColor
        imageView.layer.borderWidth = 0.5
        imageView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        contentView.addSubview(imageView)
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(bars: [LazyContinuousPDFView.Bar], pageBounds: CGRect) {
        overlay.bars = bars
        overlay.pageBounds = pageBounds
        overlay.setNeedsDisplay()
    }

    func refreshBars() { overlay.setNeedsDisplay() }

    func setImage(_ image: UIImage?, forIndex index: Int) {
        self.index = index
        imageView.image = image
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }
}

// MARK: - Per-page coverage overlay

private final class CoverageBarsView: UIView {
    var bars: [LazyContinuousPDFView.Bar] = []
    var pageBounds: CGRect = .zero

    override func draw(_ rect: CGRect) {
        guard pageBounds.width > 0, pageBounds.height > 0,
              let ctx = UIGraphicsGetCurrentContext(), !bars.isEmpty else { return }

        // Map page coords (y-up) to this view's coords (y-down).
        let sx = bounds.width / pageBounds.width
        let sy = bounds.height / pageBounds.height
        func viewY(_ pageY: CGFloat) -> CGFloat { bounds.height - (pageY - pageBounds.minY) * sy }

        // Stack overlapping bars across the left margin so they don't sit on top of
        // each other. A small fixed set of x-slots near the left edge.
        let slotWidth: CGFloat = 10
        let leftInset: CGFloat = 6
        var placed: [(range: ClosedRange<CGFloat>, slot: Int)] = []

        for bar in bars {
            let topY = viewY(bar.maxY)
            let botY = viewY(bar.minY)
            let range = min(topY, botY)...max(topY, botY)
            // Pick the first slot with no vertical overlap.
            var slot = 0
            while placed.contains(where: { $0.slot == slot && $0.range.overlaps(range) }) { slot += 1 }
            placed.append((range, slot))
            let x = leftInset + CGFloat(slot) * slotWidth

            ctx.setStrokeColor(bar.color.cgColor)
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: x, y: range.lowerBound))
            ctx.addLine(to: CGPoint(x: x, y: range.upperBound))
            ctx.strokePath()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: bar.color
            ]
            let label = NSAttributedString(string: bar.label, attributes: attrs)
            let ls = label.size()
            label.draw(at: CGPoint(x: x - ls.width / 2, y: max(0, range.lowerBound - ls.height - 1)))
        }
    }
}
#endif
