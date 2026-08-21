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
    var coverageMargin: CGFloat = 0.15
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
        let cv = WidthAwareCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .secondarySystemBackground
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.register(PageCell.self, forCellWithReuseIdentifier: PageCell.reuseID)
        cv.alwaysBounceVertical = true
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.handleWidthChange() }

        // Selectable continuous PDFView, shown only while marking coverage — so a
        // selection can span pages. Loaded on demand (once), not on every switch.
        let marking = PDFView()
        marking.displayMode = .singlePageContinuous
        marking.displayDirection = .vertical
        marking.autoScales = true
        marking.backgroundColor = .secondarySystemBackground
        marking.isHidden = true
        marking.translatesAutoresizingMaskIntoConstraints = false

        // Our own selection gesture: a near-instant long press that drives the text
        // selection directly (PDFKit's built-in selection needs a ~0.5s hold, which
        // felt like scrolling on touch). It also auto-scrolls past the edges. Enabled
        // only while marking; while it's on, the marking view's own scrolling is
        // disabled (below) so a one-finger drag selects instead of scrolling.
        let selectPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSelectionPress(_:)))
        selectPress.minimumPressDuration = 0.03
        selectPress.allowableMovement = .greatestFiniteMagnitude   // don't fail on a quick drag
        selectPress.delegate = context.coordinator
        selectPress.cancelsTouchesInView = false
        selectPress.isEnabled = false
        marking.addGestureRecognizer(selectPress)
        context.coordinator.selectionPress = selectPress

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

        // Side scroll buttons — the way to scroll while marking (page scrolling is off
        // then so a drag selects). Each tap bumps the script up/down by a fixed step,
        // which stays predictable on long scripts (a slider was too sensitive). Shown
        // only while marking.
        func scrollButton(_ symbol: String, _ action: Selector) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            config.cornerStyle = .capsule
            config.baseBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
            config.baseForegroundColor = .label
            let button = UIButton(configuration: config)
            button.addTarget(context.coordinator, action: action, for: .touchUpInside)
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.separator.cgColor
            button.layer.cornerRadius = 22
            button.layer.masksToBounds = true
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
            return button
        }
        let scrollButtons = UIStackView(arrangedSubviews: [
            scrollButton("chevron.up", #selector(Coordinator.scrollUp)),
            scrollButton("chevron.down", #selector(Coordinator.scrollDown)),
        ])
        scrollButtons.axis = .vertical
        scrollButtons.spacing = 12
        scrollButtons.isHidden = true
        scrollButtons.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollButtons)
        NSLayoutConstraint.activate([
            scrollButtons.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            scrollButtons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        context.coordinator.scrollButtons = scrollButtons

        let c = context.coordinator
        c.collectionView = cv
        c.markingView = marking
        c.markingOverlay = markingOverlay
        c.document = document
        c.project = project
        c.version = version
        c.coverageMargin = coverageMargin
        markingOverlay.marginFraction = coverageMargin
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

        let marginChanged = c.coverageMargin != coverageMargin
        c.coverageMargin = coverageMargin
        c.markingOverlay?.marginFraction = coverageMargin
        if marginChanged { c.markingOverlay?.requestRedraw() }

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
                pc.setMarginFraction(coverageMargin)
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

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
        weak var collectionView: UICollectionView?
        weak var markingView: PDFView?
        weak var markingOverlay: PDFCoverageOverlayView?
        private var markingScrollObs: NSKeyValueObservation?
        var document: PDFDocument?
        weak var project: Project?
        var version: ScriptVersion?
        var coverageMargin: CGFloat = 0.15
        var selectedShot: Shot?
        var bars: [Int: [Bar]] = [:]
        var onPageChange: ((Int) -> Void)?
        var lastScrolledPage: Int?
        var lastAlignedScene: PersistentIdentifier?
        private var pageAspect: CGFloat = 1.294
        private let renderCache = NSCache<NSNumber, UIImage>()
        private let renderQueue = DispatchQueue(label: "pdf.page.render", qos: .userInitiated)
        private var resharpenWork: DispatchWorkItem?

        private var selectionShot: Shot?
        private var observers: [NSObjectProtocol] = []
        /// Our own instant selection gesture (enabled only while marking) and its
        /// anchor — so a drag selects text immediately, without PDFKit's long press.
        weak var selectionPress: UILongPressGestureRecognizer?
        private var pressAnchorPage: PDFPage?
        private var pressAnchorPoint: CGPoint = .zero
        private var pressAnchorView: CGPoint = .zero   // view-space start, to resolve the page lazily
        /// Every other gesture on the marking view, disabled while marking so only our
        /// box-drag runs (no scroll, zoom, native selection); re-enabled when done.
        private var disabledMarkingGestures: [UIGestureRecognizer] = []
        /// Side up/down scroll buttons, shown while marking (page scrolling is off then).
        weak var scrollButtons: UIStackView?

        // Edge auto-scroll while selecting.
        private var autoScrollLink: CADisplayLink?
        private var autoScrollDirection: CGFloat = 0   // +1 down, -1 up
        private var selectionAnchorPage: PDFPage?
        private var selectionAnchorPoint: CGPoint = .zero
        private var lastFingerLocation: CGPoint = .zero

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

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
                    let colorIndex = (scene.orderedShots.firstIndex { $0 === shot } ?? 0) % LazyContinuousPDFView.palette.count
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
            cell.setMarginFraction(coverageMargin)
            cell.overlayPageBounds = document?.page(at: index)?.bounds(for: .cropBox) ?? .zero
            loadImage(for: cell, at: index, in: collectionView)
            return cell
        }

        /// Sets the page image from cache, or renders it (off the main thread) at
        /// the collection view's current width and caches it. `clearFirst` blanks
        /// the cell while rendering — skip it when re-sharpening after a resize so
        /// the existing (stretched) image stays visible until the crisp one lands.
        private func loadImage(for cell: PageCell, at index: Int, in cv: UICollectionView, clearFirst: Bool = true) {
            if let cached = renderCache.object(forKey: NSNumber(value: index)) {
                cell.setImage(cached)
                return
            }
            if clearFirst { cell.setImage(nil) }
            let width = cv.bounds.width
            let size = CGSize(width: width, height: (width * pageAspect).rounded())
            let scale = cv.traitCollection.displayScale
            renderQueue.async { [weak self, weak cv] in
                guard let self, let page = self.document?.page(at: index) else { return }
                let image = Self.render(page: page, size: size, scale: scale)
                self.renderCache.setObject(image, forKey: NSNumber(value: index))
                DispatchQueue.main.async {
                    guard let cv,
                          let visible = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? PageCell
                    else { return }
                    visible.setImage(image)
                }
            }
        }

        /// The script pane is user-resizable; when its width changes, re-lay out so
        /// each page fills the new width and re-render the visible pages crisply
        /// (images are cached by page index, so a stale one would only be stretched).
        /// Debounced so a live drag doesn't thrash the renderer.
        func handleWidthChange() {
            resharpenWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let cv = self.collectionView else { return }
                cv.collectionViewLayout.invalidateLayout()
                self.renderCache.removeAllObjects()
                for cell in cv.visibleCells {
                    guard let pc = cell as? PageCell, let ip = cv.indexPath(for: cell) else { continue }
                    self.loadImage(for: pc, at: ip.item, in: cv, clearFirst: false)
                }
            }
            resharpenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
            guard let doc = document, let marking = markingView else { return }
            selectionShot = shot
            marking.document = doc
            marking.isHidden = false
            // Force a layout pass now so the PDFView's internal scroll view exists
            // immediately — then disabling its scrolling (below) actually takes hold
            // before the first drag, instead of a beat later.
            marking.layoutIfNeeded()

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

            // Open with the shot's scene heading at the top (after layout).
            scrollButtons?.isHidden = false
            DispatchQueue.main.async {
                self.alignMarkingToScene(of: shot)
                self.markingOverlay?.requestRedraw()
            }
            NotificationCenter.default.post(name: .scriptSelectionModeChanged, object: nil,
                                            userInfo: ["active": true, "shotID": shot.persistentModelID])

            // Enable instant drag-to-select and disable scrolling right away so it
            // works from the first touch. Re-apply next runloop as a safety net.
            setMarkingSelectionInstant(true)
            DispatchQueue.main.async { [weak self] in
                if self?.selectionShot != nil { self?.setMarkingSelectionInstant(true) }
            }
        }

        /// While marking, turn on our instant selection gesture and stop the marking
        /// view from scrolling, so a drag selects text immediately instead of
        /// scrolling (the edge-pan still auto-scrolls via contentOffset). Reversed
        /// when marking ends.
        private func setMarkingSelectionInstant(_ instant: Bool) {
            guard let marking = markingView else { return }
            selectionPress?.isEnabled = instant
            if instant {
                // Skip every other gesture on the marking view — scroll, pinch-zoom,
                // PDFKit's own text selection — so only our box-drag runs. (Scrolling
                // is via the side buttons; the box selects lines.)
                for pan in disabledMarkingGestures { pan.isEnabled = true }   // clear stale
                disabledMarkingGestures.removeAll()
                func walk(_ v: UIView) {
                    for gr in v.gestureRecognizers ?? [] where gr !== selectionPress && gr.isEnabled {
                        gr.isEnabled = false
                        disabledMarkingGestures.append(gr)
                    }
                    v.subviews.forEach(walk)
                }
                walk(marking)
                marking.firstMarkingScrollView?.isScrollEnabled = false
                if let pop = navigationPopGesture() { pop.isEnabled = false }
            } else {
                for gr in disabledMarkingGestures { gr.isEnabled = true }
                disabledMarkingGestures.removeAll()
                marking.firstMarkingScrollView?.isScrollEnabled = true
                if let pop = navigationPopGesture() { pop.isEnabled = true }
            }
        }

        /// The hosting navigation controller's interactive-pop (edge swipe back)
        /// gesture, via the responder chain from the marking view.
        private func navigationPopGesture() -> UIGestureRecognizer? {
            var responder: UIResponder? = markingView
            while let r = responder {
                if let nav = r as? UINavigationController { return nav.interactivePopGestureRecognizer }
                responder = r.next
            }
            return nil
        }

        /// Drag a box to select the script lines it spans. Anchor the box on begin,
        /// then on every move select every whole line from the anchor's row to the
        /// finger's row (full width, across pages) — robust and predictable for
        /// coverage, and driven entirely by us (no PDFKit long-press).
        @objc func handleSelectionPress(_ g: UILongPressGestureRecognizer) {
            guard selectionShot != nil, let marking = markingView else { return }
            let vPoint = g.location(in: marking)
            switch g.state {
            case .began:
                pressAnchorView = vPoint
                pressAnchorPage = marking.page(for: vPoint, nearest: true)
                lastFingerLocation = vPoint
            case .changed:
                lastFingerLocation = vPoint
                // The anchor page may not have been laid out at .began; resolve it now.
                if pressAnchorPage == nil { pressAnchorPage = marking.page(for: pressAnchorView, nearest: true) }
                if autoScrollLink == nil { updateBoxSelection(to: vPoint) }
                // Auto-scroll when the finger reaches the top/bottom edge.
                if marking.currentSelection?.string?.isEmpty == false {
                    let threshold: CGFloat = 64, h = marking.bounds.height
                    if vPoint.y > h - threshold { startAutoScroll(direction: 1) }
                    else if vPoint.y < threshold { startAutoScroll(direction: -1) }
                    else { stopAutoScroll() }
                } else {
                    stopAutoScroll()
                }
            case .ended, .cancelled, .failed:
                stopAutoScroll()
            default:
                break
            }
        }

        /// Select whole lines from the anchor row down to `viewPoint`'s row, full
        /// width, spanning pages — a box selection by vertical extent.
        private func updateBoxSelection(to viewPoint: CGPoint) {
            guard let marking = markingView, let doc = document,
                  let anchorPage = pressAnchorPage,
                  let endPage = marking.page(for: viewPoint, nearest: true) else { return }
            // Order top→bottom so the selection direction doesn't matter.
            let ai = doc.index(for: anchorPage), ei = doc.index(for: endPage)
            let (topPage, topView, botPage, botView) = ai <= ei
                ? (anchorPage, pressAnchorView, endPage, viewPoint)
                : (endPage, viewPoint, anchorPage, pressAnchorView)
            // Start at the left edge of the top row, end at the right edge of the
            // bottom row → whole lines regardless of the drag's horizontal position.
            let tb = topPage.bounds(for: .cropBox), bb = botPage.bounds(for: .cropBox)
            let start = CGPoint(x: tb.minX, y: marking.convert(topView, to: topPage).y)
            let end = CGPoint(x: bb.maxX, y: marking.convert(botView, to: botPage).y)
            if let sel = doc.selection(from: topPage, at: start, to: botPage, at: end) {
                marking.setCurrentSelection(sel, animate: false)
                markingOverlay?.requestRedraw()
            }
        }

        // MARK: Side scroll buttons (page scrolling is disabled while marking)

        @objc func scrollUp() { bumpScroll(-1) }
        @objc func scrollDown() { bumpScroll(1) }

        /// Scroll the marking view by ~20% of a screen in `direction` (−1 up, +1 down).
        private func bumpScroll(_ direction: CGFloat) {
            guard let sv = markingView?.firstMarkingScrollView else { return }
            let maxY = max(0, sv.contentSize.height - sv.bounds.height)
            let step = sv.bounds.height * 0.2
            let newY = min(max(0, sv.contentOffset.y + direction * step), maxY)
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: newY), animated: true)
            markingOverlay?.requestRedraw()
        }

        // MARK: Align the marking view to a shot's scene

        /// Scroll the marking view so the shot's scene heading sits at the top.
        private func alignMarkingToScene(of shot: Shot) {
            guard let marking = markingView, let doc = document, let scene = shot.scene else { return }
            let pageIndex = scene.absolutePDFPage
            guard pageIndex >= 0, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) else { return }
            let pb = page.bounds(for: .cropBox)
            // Heading line top (PDF coords, y-up); fall back to the top of the page.
            let y = sceneHeadingTopY(pageIndex: pageIndex, scene: scene) ?? pb.maxY
            marking.go(to: PDFDestination(page: page, at: CGPoint(x: pb.minX, y: y)))
        }

        private func isHeadingLine(_ line: String) -> Bool {
            line.uppercased().range(of: "(?<![A-Z])(INT|EXT|I/E)(?![A-Z])",
                                    options: .regularExpression) != nil
        }

        /// The top Y (page coords) of `scene`'s heading on `pageIndex`, or nil.
        /// Mirrors LazyContinuousPDFView.headingTopY for the marking coordinator.
        private func sceneHeadingTopY(pageIndex: Int, scene: Scene) -> CGFloat? {
            guard let doc = document, let page = doc.page(at: pageIndex) else { return nil }
            let targetPage = scene.absolutePDFPage
            let scenesOnPage = (version?.orderedScenes ?? project?.scenes.sorted { $0.sortOrder < $1.sortOrder } ?? [])
                .filter { $0.absolutePDFPage == targetPage }
            let occurrence = scenesOnPage.firstIndex(where: { $0 === scene }) ?? 0
            let location = scene.nickname.trimmingCharacters(in: .whitespaces).uppercased()

            guard let wholePage = page.selection(for: page.bounds(for: .mediaBox)) else { return nil }
            var headings: [(location: String, top: CGFloat)] = []
            for line in wholePage.selectionsByLine() {
                guard let raw = line.string?.trimmingCharacters(in: .whitespaces), isHeadingLine(raw) else { continue }
                let parsed = ScreenplayParser.headingLocation(of: raw) ?? raw
                headings.append((parsed.trimmingCharacters(in: .whitespaces).uppercased(), line.bounds(for: page).maxY))
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

        // MARK: Edge auto-scroll during selection

        private func startAutoScroll(direction: CGFloat) {
            guard let marking = markingView, let sel = marking.currentSelection else { return }
            if autoScrollLink != nil && autoScrollDirection == direction { return }
            autoScrollDirection = direction

            // Anchor is the far end of the selection from the scroll direction, so
            // we extend toward the finger as content scrolls under it.
            let lines = sel.selectionsByLine()
            if direction > 0, let page = sel.pages.first, let line = lines.first {
                let b = line.bounds(for: page)
                selectionAnchorPage = page
                selectionAnchorPoint = CGPoint(x: b.minX, y: b.maxY)   // top-left
            } else if direction < 0, let page = sel.pages.last, let line = lines.last {
                let b = line.bounds(for: page)
                selectionAnchorPage = page
                selectionAnchorPoint = CGPoint(x: b.maxX, y: b.minY)   // bottom-right
            }
            guard selectionAnchorPage != nil else { return }

            if autoScrollLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
                link.add(to: .main, forMode: .common)
                autoScrollLink = link
            }
        }

        @objc private func autoScrollTick() {
            guard let marking = markingView,
                  let sv = marking.firstMarkingScrollView,
                  let anchorPage = selectionAnchorPage,
                  let doc = document else { stopAutoScroll(); return }

            var offset = sv.contentOffset
            let maxY = max(0, sv.contentSize.height - sv.bounds.height)
            let newY = min(max(0, offset.y + 9 * autoScrollDirection), maxY)
            if newY == offset.y { stopAutoScroll(); return }   // reached the end
            offset.y = newY
            sv.setContentOffset(offset, animated: false)

            // Re-derive the selection from the fixed anchor to the finger, which is
            // now hovering over freshly-scrolled content.
            guard let endPage = marking.page(for: lastFingerLocation, nearest: true) else { return }
            let endPoint = marking.convert(lastFingerLocation, to: endPage)
            if let sel = doc.selection(from: anchorPage, at: selectionAnchorPoint,
                                       to: endPage, at: endPoint) {
                marking.setCurrentSelection(sel, animate: false)
            }
            markingOverlay?.requestRedraw()
        }

        private func stopAutoScroll() {
            autoScrollLink?.invalidate()
            autoScrollLink = nil
            autoScrollDirection = 0
            selectionAnchorPage = nil
        }

        private func endMarking() {
            stopAutoScroll()
            setMarkingSelectionInstant(false)
            scrollButtons?.isHidden = true
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

// MARK: - Width-aware collection view

/// Reports when its width changes so the page images can be re-rendered to fill
/// the new (user-resizable) pane width instead of being stretched.
private final class WidthAwareCollectionView: UICollectionView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastWidth) > 0.5 else { return }
        let isFirstLayout = lastWidth < 0
        lastWidth = bounds.width
        if !isFirstLayout { onWidthChange?() }
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
        // Recompute the coverage lines on resize instead of stretching the last
        // drawing, so line positions and thickness stay correct at any pane width.
        overlay.contentMode = .redraw
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
    func setMarginFraction(_ fraction: CGFloat) {
        guard overlay.marginFraction != fraction else { return }
        overlay.marginFraction = fraction
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
    /// Right edge of the coverage-line band, as a fraction of page width.
    var marginFraction: CGFloat = 0.15

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
        let marginLimitX = bounds.width * marginFraction
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

            // Label — above the top of the line (minY is the visual top in UIKit's
            // y-down space), matching the Mac editor. Stagger upward to avoid
            // overlapping a label already placed for another line.
            let padding: CGFloat = 2
            var labelRect = CGRect(x: x - textSize.width / 2, y: minY - padding - textSize.height,
                                   width: textSize.width, height: textSize.height)
            labelRect.origin.x = min(max(labelRect.minX, 0), max(0, bounds.width - textSize.width))
            while placedLabelRects.contains(where: { $0.intersects(labelRect.insetBy(dx: -1, dy: -1)) }) {
                labelRect.origin.y -= (textSize.height + 2)
            }
            label.draw(at: labelRect.origin)
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
}
#endif
