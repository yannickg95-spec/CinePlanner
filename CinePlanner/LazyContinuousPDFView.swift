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
import GameController

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

        // Coverage lines over the marking view, so existing coverage is visible
        // while marking. Same overlay the mac viewer uses; passes touches through.
        let markingOverlay = PDFCoverageOverlayView()
        markingOverlay.pdfView = marking
        markingOverlay.isHidden = true
        markingOverlay.translatesAutoresizingMaskIntoConstraints = false

        // Word-pick tap, attached directly to the marking PDFView. A separate overlay
        // sibling never received touches under SwiftUI hosting; a recognizer on the
        // PDFView itself does. A tap is discrete, so it coexists with normal
        // drag-scrolling (no conflict) — it just picks the word under the finger.
        // Enabled only while marking.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleWordTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.isEnabled = false
        marking.addGestureRecognizer(tap)
        context.coordinator.wordTap = tap

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
        /// Word-pick tap on the marking PDFView, enabled only while marking.
        weak var wordTap: UITapGestureRecognizer?

        // Two-tap word marking. The user taps the first word, hits Next, taps the last
        // word, hits Done — and everything from the first word's start to the last
        // word's end (inclusive) is marked. Each tap re-picks that end's word, shown
        // highlighted so a mistap is easy to see and correct.
        enum MarkPhase { case first, last }
        private var markPhase: MarkPhase = .first
        private var firstWordSelection: PDFSelection?
        private var lastWordSelection: PDFSelection?

        /// True when a pointer (mouse/trackpad/Magic Keyboard) is connected. Kept live
        /// via GameController connect/disconnect notifications.
        private var hasPointer = !GCMouse.mice().isEmpty
        /// The current marking session uses the Mac-style native drag-selection (a
        /// pointer is attached on iPad) rather than the touch two-tap word picker.
        private var pointerMarking = false

        /// iPad + a pointer → mark the Mac way (drag to select, one Done). iPhone, or
        /// an iPad with no pointer, keeps the two-tap word picker (best for touch).
        private func pointerMarkingAvailable() -> Bool {
            UIDevice.current.userInterfaceIdiom == .pad && hasPointer
        }

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
            let coloring = CoverageColoring(version: version, project: project)
            for scene in scenes {
                for shot in scene.shots {
                    guard let selections = shot.scriptCoverageSelections, !selections.isEmpty else { continue }
                    let color = coloring.color(for: shot)
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
                self?.advanceOrCapture()
            })
            observers.append(nc.addObserver(forName: .cancelScriptSelection, object: nil, queue: .main) { [weak self] _ in
                self?.endMarking()
            })
            observers.append(nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
                self?.hasPointer = true
            })
            observers.append(nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                self?.hasPointer = !GCMouse.mice().isEmpty
            })
        }

        private func beginMarking(shot: Shot) {
            guard let doc = document, let marking = markingView else { return }
            selectionShot = shot
            pointerMarking = pointerMarkingAvailable()
            markPhase = .first
            firstWordSelection = nil
            lastWordSelection = nil
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
            DispatchQueue.main.async {
                self.alignMarkingToScene(of: shot)
                self.markingOverlay?.requestRedraw()
            }
            NotificationCenter.default.post(name: .scriptSelectionModeChanged, object: nil,
                                            userInfo: ["active": true, "shotID": shot.persistentModelID,
                                                       "pointer": pointerMarking])
            postPhase()

            // Touch: enable the word-pick tap so a tap picks a word from the first
            // touch. Pointer (Mac-style): leave native drag-selection on instead.
            // Re-apply next runloop as a safety net.
            setMarkingSelectionInstant(true)
            DispatchQueue.main.async { [weak self] in
                if self?.selectionShot != nil { self?.setMarkingSelectionInstant(true) }
            }
        }

        /// Tell the card/toolbar which word the user is picking now.
        private func postPhase() {
            NotificationCenter.default.post(name: .scriptSelectionPhaseChanged, object: nil,
                                            userInfo: ["phase": markPhase == .last ? 1 : 0])
        }

        /// While marking, enable the word-pick tap (touch mode only). Reversed when
        /// marking ends.
        private func setMarkingSelectionInstant(_ instant: Bool) {
            // Turn the word-pick tap on/off. PDFView keeps its normal drag-scrolling —
            // a tap doesn't conflict with it. In pointer mode we leave the tap off so
            // PDFView's native drag-selection (Mac-style) is the interaction. Disable
            // the nav edge-swipe-back so an edge tap can't pop the screen.
            wordTap?.isEnabled = instant && !pointerMarking
            if let pop = navigationPopGesture() { pop.isEnabled = !instant }
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

        /// Tap the catcher overlay to pick the word under the finger — the first word
        /// or the last, depending on the phase. Re-tapping re-picks (the previous pick
        /// is discarded), so a mistap is corrected by tapping the right word.
        @objc func handleWordTap(_ g: UITapGestureRecognizer) {
            guard selectionShot != nil, let marking = markingView else { return }
            // The recognizer is on the marking view, so its location is in that space.
            let p = g.location(in: marking)
            guard let page = marking.page(for: p, nearest: true) else { return }
            let pagePoint = marking.convert(p, to: page)
            guard let word = wordSelection(on: page, near: pagePoint),
                  !(word.string?.isEmpty ?? true) else { return }
            switch markPhase {
            case .first: firstWordSelection = word
            case .last:  lastWordSelection = word
            }
            refreshPreview()
        }

        /// The word nearest `point` on `page`. A screenplay is Courier with wide line
        /// spacing, so a fingertip often lands in the gaps between glyphs where the
        /// strict `selectionForWord(at:)` returns nil. We first snap to the nearest
        /// character (which tolerates that) and take the word around its center, then
        /// fall back to the raw point.
        private func wordSelection(on page: PDFPage, near point: CGPoint) -> PDFSelection? {
            let idx = page.characterIndex(at: point)
            if idx >= 0 {
                let cb = page.characterBounds(at: idx)
                if let w = page.selectionForWord(at: CGPoint(x: cb.midX, y: cb.midY)),
                   !(w.string?.isEmpty ?? true) {
                    return w
                }
            }
            return page.selectionForWord(at: point)
        }

        /// Confirm the current phase. First → advance to picking the last word.
        /// Last → capture the whole range and finish. Called by the card/toolbar's
        /// Next/Done button (via `.captureScriptSelection`).
        private func advanceOrCapture() {
            // Pointer (Mac-style): one Done captures whatever is natively selected.
            if pointerMarking {
                guard let sel = markingView?.currentSelection, !(sel.string?.isEmpty ?? true) else { return }
                captureSelection(sel)
                return
            }
            switch markPhase {
            case .first:
                guard firstWordSelection != nil else { return }   // need a first word
                markPhase = .last
                postPhase()
                refreshPreview()
            case .last:
                guard lastWordSelection != nil,
                      let combined = combinedRangeSelection(), !(combined.string?.isEmpty ?? true)
                else { return }
                captureSelection(combined)   // stores our own selection, ends marking
            }
        }

        /// The selection from the first word's start to the last word's end (inclusive),
        /// ordered by document position so it works regardless of tap order.
        private func combinedRangeSelection() -> PDFSelection? {
            guard let doc = document,
                  let first = firstWordSelection, let firstPage = first.pages.first,
                  let last = lastWordSelection, let lastPage = last.pages.first else {
                return firstWordSelection
            }
            let fb = first.bounds(for: firstPage), lb = last.bounds(for: lastPage)
            let fIdx = doc.index(for: firstPage), lIdx = doc.index(for: lastPage)
            // Document order: earlier page first; within a page, higher y (PDF is
            // y-up) is earlier. The start point is the leading edge of the earlier
            // word, the end point the trailing edge of the later word.
            let firstIsEarlier = fIdx < lIdx || (fIdx == lIdx && fb.midY >= lb.midY)
            let (sPage, sRect) = firstIsEarlier ? (firstPage, fb) : (lastPage, lb)
            let (ePage, eRect) = firstIsEarlier ? (lastPage, lb) : (firstPage, fb)
            let start = CGPoint(x: sRect.minX, y: sRect.midY)
            let end = CGPoint(x: eRect.maxX, y: eRect.midY)
            return doc.selection(from: sPage, at: start, to: ePage, at: end)
        }

        /// Show the current pick highlighted: just the first word while picking it, or
        /// the whole building range once the user is on the last word. Uses
        /// `highlightedSelections` (persistent) rather than `currentSelection`, which
        /// PDFView clears on every tap — the reason a picked word flashed and vanished.
        private func refreshPreview() {
            guard let marking = markingView else { return }
            let sel: PDFSelection?
            switch markPhase {
            case .first: sel = firstWordSelection
            case .last:  sel = combinedRangeSelection() ?? firstWordSelection
            }
            if let sel {
                sel.color = UIColor.systemBlue.withAlphaComponent(0.35)
                marking.highlightedSelections = [sel]
            } else {
                marking.highlightedSelections = nil
            }
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

        private func captureSelection(_ selection: PDFSelection) {
            defer { endMarking() }
            guard let shot = selectionShot, let doc = document,
                  !(selection.string?.isEmpty ?? true) else { return }
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
            setMarkingSelectionInstant(false)
            selectionShot = nil
            firstWordSelection = nil
            lastWordSelection = nil
            markPhase = .first
            pointerMarking = false
            markingScrollObs?.invalidate()
            markingScrollObs = nil
            markingView?.highlightedSelections = nil
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

        struct Placement {
            let x: CGFloat, minY: CGFloat, maxY: CGFloat
            let color: UIColor, label: String, baseLabelRect: CGRect
        }
        struct RawBar { let minY: CGFloat, maxY: CGFloat, color: UIColor, label: String, textSize: CGSize }

        // Pass 1: resolve each bar's vertical extent (no X yet).
        var raws: [RawBar] = []
        for bar in bars {
            let a = viewY(bar.maxY), b = viewY(bar.minY)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 11),
                .foregroundColor: bar.color
            ]
            let textSize = NSAttributedString(string: bar.label, attributes: attrs).size()
            raws.append(RawBar(minY: min(a, b), maxY: max(a, b), color: bar.color,
                               label: bar.label, textSize: textSize))
        }

        // Column packing and the shared label scale — the same maths the editor
        // overlay and every export use (see CoverageLineLayout). This view is
        // y-down, so a bar's top is its minY and the number sits just above it.
        let solved = CoverageLineLayout.solve(raws.map { raw in
            CoverageLineLayout.Line(
                extent: raw.minY...raw.maxY,
                band: xLower...xUpper,
                labelWidth: raw.textSize.width,
                labelBand: (raw.minY - 2 - raw.textSize.height)...(raw.minY - 2))
        })
        let scale = solved.first?.scale ?? 1

        var placements: [Placement] = []
        for (raw, placed) in zip(raws, solved) {
            let baseLabelRect = CGRect(x: placed.x - raw.textSize.width / 2,
                                       y: raw.minY - 2 - raw.textSize.height,
                                       width: raw.textSize.width, height: raw.textSize.height)
            placements.append(Placement(x: placed.x, minY: raw.minY, maxY: raw.maxY, color: raw.color,
                                        label: raw.label, baseLabelRect: baseLabelRect))
        }

        // Line thickness scales with the coverage-band width — the same for every
        // page (identical pane width), so all bars are equally thick regardless of
        // how crowded their own page is. (The per-page `scale` still governs the
        // labels so numbers never overlap.)
        let bandWidth = xUpper - xLower
        let lineScale = max(0.4, min(1, bandWidth / 55))

        // Pass 2: draw the bars, then the scaled shot numbers above them.
        for p in placements {
            ctx.setStrokeColor(p.color.cgColor)
            ctx.setLineWidth(max(1, 3 * lineScale))
            ctx.move(to: CGPoint(x: p.x, y: p.minY))
            ctx.addLine(to: CGPoint(x: p.x, y: p.maxY))
            ctx.strokePath()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 11 * scale),
                .foregroundColor: p.color
            ]
            let label = NSAttributedString(string: p.label, attributes: attrs)
            let ts = label.size()
            let padding: CGFloat = 2
            var x = p.x - ts.width / 2
            x = min(max(x, 0), max(0, bounds.width - ts.width))
            label.draw(at: CGPoint(x: x, y: p.minY - padding - ts.height))
        }
    }

}
#endif
