//
//  LazyContinuousPDFView.swift
//  CinePlanner
//
//  The iPad script viewer. PDFKit's PDFView with `.singlePageContinuous` froze
//  iPad by laying out the whole screenplay on every version switch. This instead
//  lists the pages in a UICollectionView where each page is rendered lazily to a
//  cached image — only the visible pages are rasterised, so scrolling and version
//  switches stay light. Coverage lines are drawn per page.
//
//  Marking coverage still uses PDFKit's native text selection, but only while
//  marking: a selectable single-page PDFView is overlaid in place (not a popup)
//  so scrolling the rest of the time stays smooth. iOS only; macOS keeps the
//  standard continuous PDFView.
//

#if canImport(UIKit)
import SwiftUI
import SwiftData
import PDFKit
import UIKit

struct LazyContinuousPDFView: UIViewRepresentable {
    let document: PDFDocument
    let pageToDisplay: Int?
    let sceneToAlign: Scene?
    let selectedShot: Shot?
    let project: Project
    let version: ScriptVersion?
    @Binding var currentPageIndex: Int

    struct Bar { let color: UIColor; let label: String; let minY: CGFloat; let maxY: CGFloat }

    static let palette: [UIColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink,
        .systemTeal, .systemIndigo, .systemRed, .systemYellow, .systemBrown
    ]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

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
        cv.translatesAutoresizingMaskIntoConstraints = false

        // Selectable continuous PDFView, shown only while marking coverage — so a
        // selection can span pages. Loaded on demand (once), not on every switch.
        let marking = PDFView()
        marking.displayMode = .singlePageContinuous
        marking.displayDirection = .vertical
        marking.autoScales = true
        marking.backgroundColor = .secondarySystemBackground
        marking.isHidden = true
        marking.translatesAutoresizingMaskIntoConstraints = false

        // Coverage lines over the marking view, so existing coverage is visible
        // while marking. Same overlay the mac viewer uses; passes touches through.
        let markingOverlay = PDFCoverageOverlayView()
        markingOverlay.pdfView = marking
        markingOverlay.isHidden = true
        markingOverlay.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(cv)
        container.addSubview(marking)
        container.addSubview(markingOverlay)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cv.topAnchor.constraint(equalTo: container.topAnchor),
            cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            marking.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            marking.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            marking.topAnchor.constraint(equalTo: container.topAnchor),
            marking.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            markingOverlay.leadingAnchor.constraint(equalTo: marking.leadingAnchor),
            markingOverlay.trailingAnchor.constraint(equalTo: marking.trailingAnchor),
            markingOverlay.topAnchor.constraint(equalTo: marking.topAnchor),
            markingOverlay.bottomAnchor.constraint(equalTo: marking.bottomAnchor),
        ])

        let c = context.coordinator
        c.collectionView = cv
        c.markingView = marking
        c.markingOverlay = markingOverlay
        c.document = document
        c.project = project
        c.version = version
        c.selectedShot = selectedShot
        c.refreshPageAspect()
        c.recomputeBars()
        c.registerSelectionObservers()
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        let c = context.coordinator
        guard let cv = c.collectionView else { return }
        c.project = project
        c.version = version
        c.selectedShot = selectedShot
        c.onPageChange = { idx in if currentPageIndex != idx { currentPageIndex = idx } }

        let changedDocument = c.document !== document
        if changedDocument {
            c.document = document
            c.refreshPageAspect()
            c.recomputeBars()
            c.lastScrolledPage = nil
            cv.reloadData()
        } else {
            c.recomputeBars()
            for cell in cv.visibleCells {
                guard let pc = cell as? PageCell, let ip = cv.indexPath(for: cell) else { continue }
                pc.setBars(c.bars[ip.item] ?? [])
            }
        }

        let sceneID = sceneToAlign?.persistentModelID
        if let page = pageToDisplay,
           page != c.lastScrolledPage || sceneID != c.lastAlignedScene || changedDocument,
           page >= 0, page < document.pageCount {
            c.lastScrolledPage = page
            c.lastAlignedScene = sceneID
            let headingY = headingTopY(forPage: page, scene: sceneToAlign)
            DispatchQueue.main.async {
                guard page < cv.numberOfItems(inSection: 0) else { return }
                c.scroll(toPage: page, headingPageY: headingY, in: cv)
            }
        }
    }

    // MARK: - Scene-heading detection

    private func isHeadingLine(_ line: String) -> Bool {
        line.uppercased().range(of: "(?<![A-Z])(INT|EXT|I/E)(?![A-Z])",
                                options: .regularExpression) != nil
    }

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
        weak var collectionView: UICollectionView?
        weak var markingView: PDFView?
        weak var markingOverlay: PDFCoverageOverlayView?
        private var markingScrollObs: NSKeyValueObservation?
        var document: PDFDocument?
        weak var project: Project?
        var version: ScriptVersion?
        var selectedShot: Shot?
        var bars: [Int: [Bar]] = [:]
        var onPageChange: ((Int) -> Void)?
        var lastScrolledPage: Int?
        var lastAlignedScene: PersistentIdentifier?
        private var pageAspect: CGFloat = 1.294
        private let renderCache = NSCache<NSNumber, UIImage>()
        private let renderQueue = DispatchQueue(label: "pdf.page.render", qos: .userInitiated)

        private var selectionShot: Shot?
        private var observers: [NSObjectProtocol] = []

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func refreshPageAspect() {
            if let first = document?.page(at: 0) {
                let b = first.bounds(for: .cropBox)
                if b.width > 0 { pageAspect = b.height / b.width }
            }
            renderCache.removeAllObjects()
        }

        func recomputeBars() {
            var result: [Int: [Bar]] = [:]
            let scenes = version?.scenes ?? project?.scenes ?? []
            for scene in scenes {
                for shot in scene.shots {
                    guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { continue }
                    let colorIndex = (scene.shots.firstIndex { $0 === shot } ?? 0) % LazyContinuousPDFView.palette.count
                    let color = LazyContinuousPDFView.palette[colorIndex]
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
            bars = result
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
            cell.setBars(bars[index] ?? [])
            cell.overlayPageBounds = document?.page(at: index)?.bounds(for: .cropBox) ?? .zero

            if let cached = renderCache.object(forKey: NSNumber(value: index)) {
                cell.setImage(cached)
            } else {
                cell.setImage(nil)
                let size = self.collectionView(collectionView, layout: collectionView.collectionViewLayout, sizeForItemAt: indexPath)
                let scale = collectionView.traitCollection.displayScale
                renderQueue.async { [weak self, weak collectionView] in
                    guard let self, let page = self.document?.page(at: index) else { return }
                    let image = Self.render(page: page, size: size, scale: scale)
                    self.renderCache.setObject(image, forKey: NSNumber(value: index))
                    DispatchQueue.main.async {
                        guard let cv = collectionView,
                              let visible = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? PageCell
                        else { return }
                        visible.setImage(image)
                    }
                }
            }
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView else { return }
            let topPoint = CGPoint(x: cv.bounds.midX, y: cv.contentOffset.y + 8)
            if let indexPath = cv.indexPathForItem(at: topPoint) { onPageChange?(indexPath.item) }
        }

        func scroll(toPage page: Int, headingPageY: CGFloat?, in cv: UICollectionView) {
            guard let doc = document, page >= 0, page < doc.pageCount, let pdfPage = doc.page(at: page) else { return }
            let width = cv.bounds.width
            guard width > 0 else { return }
            let itemHeight = (width * pageAspect).rounded()
            let itemOriginY = 12 + CGFloat(page) * (itemHeight + 12)
            var offsetInCell: CGFloat = 0
            if let headingPageY {
                let pb = pdfPage.bounds(for: .cropBox)
                if pb.height > 0 {
                    let frac = (headingPageY - pb.minY) / pb.height
                    offsetInCell = max(0, itemHeight * (1 - frac) - 14)
                }
            }
            let maxOffset = max(0, cv.collectionViewLayout.collectionViewContentSize.height - cv.bounds.height)
            cv.setContentOffset(CGPoint(x: 0, y: min(max(0, itemOriginY + offsetInCell), maxOffset)), animated: false)
        }

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
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: size.width / bounds.width, y: -size.height / bounds.height)
                cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
            }
        }

        // MARK: Coverage marking (inline overlay PDFView)

        func registerSelectionObservers() {
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .startScriptTextSelection, object: nil, queue: .main) { [weak self] note in
                guard let self, let shot = note.userInfo?["shot"] as? Shot else { return }
                self.beginMarking(shot: shot)
            })
            observers.append(nc.addObserver(forName: .captureScriptSelection, object: nil, queue: .main) { [weak self] _ in
                self?.captureSelection()
            })
            observers.append(nc.addObserver(forName: .cancelScriptSelection, object: nil, queue: .main) { [weak self] _ in
                self?.endMarking()
            })
        }

        private func beginMarking(shot: Shot) {
            guard let doc = document, let marking = markingView, let cv = collectionView else { return }
            selectionShot = shot
            marking.document = doc
            marking.isHidden = false

            // Show existing coverage lines over the marking view.
            if let overlay = markingOverlay {
                overlay.allShotsWithCoverage = shotsWithCoverage()
                overlay.selectedShot = nil
                overlay.isHidden = false
                if let sv = marking.firstMarkingScrollView {
                    markingScrollObs = sv.observe(\.contentOffset, options: [.new]) { [weak overlay] _, _ in
                        overlay?.requestRedraw()
                    }
                }
            }

            // Start on the page the user is currently looking at (after layout).
            let index = cv.indexPathForItem(at: CGPoint(x: cv.bounds.midX, y: cv.contentOffset.y + 8))?.item ?? 0
            DispatchQueue.main.async {
                if let page = doc.page(at: index) { marking.go(to: page) }
                self.markingOverlay?.requestRedraw()
            }
            NotificationCenter.default.post(name: .scriptSelectionModeChanged, object: nil,
                                            userInfo: ["active": true, "shotID": shot.persistentModelID])
        }

        private func shotsWithCoverage() -> [Shot] {
            var result: [Shot] = []
            for scene in (version?.scenes ?? project?.scenes ?? []) {
                for shot in scene.shots where !(shot.scriptCoverageSelections?.isEmpty ?? true) {
                    result.append(shot)
                }
            }
            return result
        }

        private func captureSelection() {
            defer { endMarking() }
            guard let shot = selectionShot, let doc = document, let marking = markingView,
                  let selection = marking.currentSelection, !(selection.string?.isEmpty ?? true) else { return }
            var pageRanges: [PageTextRange] = []
            for page in selection.pages {
                let idx = doc.index(for: page)
                guard idx != NSNotFound else { continue }
                var bounds: [PDFSelectionBounds] = []
                for line in selection.selectionsByLine() where line.pages.contains(page) {
                    let b = line.bounds(for: page)
                    if !b.isEmpty { bounds.append(PDFSelectionBounds(from: b)) }
                }
                if bounds.isEmpty {
                    let b = selection.bounds(for: page)
                    if !b.isEmpty { bounds.append(PDFSelectionBounds(from: b)) }
                }
                if !bounds.isEmpty { pageRanges.append(PageTextRange(pageIndex: idx, selections: bounds)) }
            }
            guard !pageRanges.isEmpty else { return }
            let ts = ScriptTextSelection(pageRanges: pageRanges, fullText: selection.string ?? "")
            if shot.scriptCoverageSelections == nil { shot.scriptCoverageSelections = [] }
            shot.scriptCoverageSelections?.append(ts)

            recomputeBars()
            if let cv = collectionView {
                for cell in cv.visibleCells {
                    guard let pc = cell as? PageCell, let ip = cv.indexPath(for: cell) else { continue }
                    pc.setBars(bars[ip.item] ?? [])
                }
            }
        }

        private func endMarking() {
            selectionShot = nil
            markingScrollObs?.invalidate()
            markingScrollObs = nil
            markingView?.clearSelection()
            markingView?.isHidden = true
            markingView?.document = nil   // release the laid-out pages
            markingOverlay?.isHidden = true
            markingOverlay?.allShotsWithCoverage = []
            NotificationCenter.default.post(name: .scriptSelectionModeChanged, object: nil,
                                            userInfo: ["active": false])
        }
    }
}

private extension UIView {
    /// The first `UIScrollView` in this view's subtree (PDFView wraps its document
    /// in a private scroll view), for observing scroll offset.
    var firstMarkingScrollView: UIScrollView? {
        if let s = self as? UIScrollView { return s }
        for sub in subviews { if let f = sub.firstMarkingScrollView { return f } }
        return nil
    }
}

// MARK: - Page cell (image + coverage overlay)

private final class PageCell: UICollectionViewCell {
    static let reuseID = "PageCell"

    private let imageView = UIImageView()
    private let overlay = CoverageBarsView()

    var overlayPageBounds: CGRect {
        get { overlay.pageBounds }
        set { overlay.pageBounds = newValue; overlay.setNeedsDisplay() }
    }

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

    func setBars(_ bars: [LazyContinuousPDFView.Bar]) {
        overlay.bars = bars
        overlay.setNeedsDisplay()
    }
    func setImage(_ image: UIImage?) { imageView.image = image }

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

        let sy = bounds.height / pageBounds.height
        func viewY(_ pageY: CGFloat) -> CGFloat { bounds.height - (pageY - pageBounds.minY) * sy }

        // Left-margin x-range in view coords — mirrors the Mac overlay:
        // pageMinX + 6 ... pageMinX + pageWidth * 0.15 (clamped).
        let horizontalInset: CGFloat = 6
        let minimumPageX = horizontalInset
        let maximumPageX = bounds.width - horizontalInset
        let marginLimitX = bounds.width * 0.15
        let xUpper = min(maximumPageX, marginLimitX)
        let xLower = min(minimumPageX, xUpper)

        var existingLines: [(range: ClosedRange<CGFloat>, offset: CGFloat)] = []
        var placedLabelRects: [CGRect] = []

        for bar in bars {
            let a = viewY(bar.maxY), b = viewY(bar.minY)
            let minY = min(a, b), maxY = max(a, b)
            let verticalRange = minY...maxY

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 11),
                .foregroundColor: bar.color
            ]
            let label = NSAttributedString(string: bar.label, attributes: attrs)
            let textSize = label.size()

            let x = Self.calculateLineX(
                verticalRange: verticalRange,
                xRange: xLower...xUpper,
                minimumCenterSpacing: textSize.width + 6,
                existingLines: &existingLines)

            ctx.setStrokeColor(bar.color.cgColor)
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: x, y: minY))
            ctx.addLine(to: CGPoint(x: x, y: maxY))
            ctx.strokePath()

            // Label — placed just below the bottom of the line, matching the Mac overlay.
            let padding: CGFloat = 4
            let labelY = maxY
            let desired = CGRect(x: x - textSize.width / 2, y: labelY + padding,
                                 width: textSize.width, height: textSize.height)
            let pageRect = CGRect(x: minimumPageX, y: minY,
                                  width: max(0, maximumPageX - minimumPageX),
                                  height: max(0, maxY - minY) + 400)
            let labelRect = Self.resolvedLabelRect(
                desired: desired, lineX: x, lineTopY: labelY, pageBounds: pageRect,
                existingLineRects: Self.collisionRects(from: existingLines),
                placedLabelRects: placedLabelRects)
            label.draw(at: CGPoint(x: labelRect.minX, y: labelRect.minY))
            placedLabelRects.append(labelRect)
        }
    }

    // MARK: Placement helpers (ported from PDFCoverageOverlayView for identical layout)

    private static func calculateLineX(
        verticalRange: ClosedRange<CGFloat>,
        xRange: ClosedRange<CGFloat>,
        minimumCenterSpacing: CGFloat,
        existingLines: inout [(range: ClosedRange<CGFloat>, offset: CGFloat)]
    ) -> CGFloat {
        let usableWidth = xRange.upperBound - xRange.lowerBound
        guard usableWidth > 0 else { return xRange.lowerBound }

        let targetSlotCount = 8
        let targetSpacing = targetSlotCount > 1 ? usableWidth / CGFloat(targetSlotCount - 1) : usableWidth
        let minimumSpacing = max(6, min(minimumCenterSpacing, targetSpacing))
        let slotCount = max(1, Int(floor(usableWidth / minimumSpacing)) + 1)
        let actualSpacing = slotCount > 1 ? usableWidth / CGFloat(slotCount - 1) : 0

        for slotIndex in 0..<slotCount {
            let candidateX = xRange.upperBound - (CGFloat(slotIndex) * actualSpacing)
            let conflicts = existingLines.contains { existing in
                existing.range.overlaps(verticalRange)
                    && abs(existing.offset - candidateX) < max(minimumSpacing - 1, actualSpacing * 0.75)
            }
            if !conflicts {
                existingLines.append((range: verticalRange, offset: candidateX))
                return candidateX
            }
        }

        let fallbackX = xRange.lowerBound
        existingLines.append((range: verticalRange, offset: fallbackX))
        return fallbackX
    }

    private static func collisionRects(
        from lines: [(range: ClosedRange<CGFloat>, offset: CGFloat)],
        horizontalPadding: CGFloat = 5,
        verticalPadding: CGFloat = 2
    ) -> [CGRect] {
        lines.map { line in
            CGRect(x: line.offset - horizontalPadding,
                   y: line.range.lowerBound - verticalPadding,
                   width: horizontalPadding * 2,
                   height: (line.range.upperBound - line.range.lowerBound) + verticalPadding * 2)
        }
    }

    private static func resolvedLabelRect(
        desired: CGRect,
        lineX: CGFloat,
        lineTopY: CGFloat,
        pageBounds: CGRect,
        existingLineRects: [CGRect],
        placedLabelRects: [CGRect]
    ) -> CGRect {
        let topGap: CGFloat = 4
        let sideGap: CGFloat = 8
        let verticalStep: CGFloat = desired.height + 3
        let halfHeight = desired.height / 2

        func clampedX(_ originX: CGFloat) -> CGFloat {
            min(max(originX, pageBounds.minX), max(pageBounds.minX, pageBounds.maxX - desired.width))
        }
        func candidate(_ originX: CGFloat, _ originY: CGFloat) -> CGRect {
            CGRect(x: clampedX(originX), y: originY, width: desired.width, height: desired.height)
        }

        var candidates: [CGRect] = []
        for step in 0..<8 {
            let y = lineTopY + topGap + (CGFloat(step) * verticalStep)
            candidates.append(candidate(lineX - (desired.width / 2), y))
        }
        candidates.append(candidate(lineX + sideGap, lineTopY - halfHeight))
        candidates.append(candidate(lineX - desired.width - sideGap, lineTopY - halfHeight))
        for step in 1..<8 {
            let y = lineTopY + topGap + (CGFloat(step) * verticalStep)
            candidates.append(candidate(lineX + sideGap, y))
            candidates.append(candidate(lineX - desired.width - sideGap, y))
        }

        for rect in candidates {
            let overlapsLine = existingLineRects.contains { $0.intersects(rect) }
            let overlapsLabel = placedLabelRects.contains { $0.intersects(rect.insetBy(dx: -2, dy: -1)) }
            if !overlapsLine && !overlapsLabel { return rect }
        }
        return candidates.last ?? desired
    }
}
#endif
