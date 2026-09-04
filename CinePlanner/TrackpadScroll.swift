//
//  TrackpadScroll.swift
//  CinePlanner
//
//  A transparent overlay that reports two-finger trackpad scroll deltas so a
//  zoomed view can be panned by swiping, without a click/drag. It never steals
//  taps or clicks:
//   • iOS: hitTest returns the view only for `.scroll` events; touches fall
//     through to the SwiftUI content below.
//   • macOS: a local scrollWheel monitor handles scrolls; hitTest returns nil so
//     clicks pass through untouched.
//  `enabled` gates whether scrolls are consumed. On macOS an optional `onZoom`
//  routes mouse-wheel (and ⌘-) scrolls to zooming instead, so a mouse user can
//  zoom a map that otherwise needs a trackpad pinch.
//

import SwiftUI

#if os(iOS)
import UIKit

struct TrackpadScrollCatcher: UIViewRepresentable {
    var enabled: Bool
    /// Unused on iOS — a pointer's scroll is always a precise (pan) scroll here.
    /// Present so call sites compile on both platforms.
    var onZoom: ((CGFloat) -> Void)? = nil
    var onScroll: (CGSize) -> Void

    func makeUIView(context: Context) -> ScrollCatchView {
        let view = ScrollCatchView()
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.allowedScrollTypesMask = .continuous   // trackpad / pointer scroll
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        context.coordinator.onScroll = onScroll
        view.enabled = enabled
        return view
    }

    func updateUIView(_ uiView: ScrollCatchView, context: Context) {
        context.coordinator.onScroll = onScroll
        uiView.enabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScroll: ((CGSize) -> Void)?
        private var last: CGPoint = .zero

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                last = .zero
            case .changed:
                let t = g.translation(in: g.view)
                onScroll?(CGSize(width: t.x - last.x, height: t.y - last.y))
                last = t
            default:
                break
            }
        }

        // Only indirect (trackpad/pointer) scrolling — never direct finger touches,
        // which stay with the SwiftUI marker/pan gestures.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class ScrollCatchView: UIView {
        var enabled = false
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Grab trackpad scrolls (only while enabled); let touches pass through.
            if enabled, event?.type == .scroll { return super.hitTest(point, with: event) }
            return nil
        }
    }
}
#elseif os(macOS)
import AppKit

struct TrackpadScrollCatcher: NSViewRepresentable {
    var enabled: Bool
    /// When set, a mouse wheel (or ⌘-scroll) zooms instead of panning — the only way
    /// to zoom without a trackpad. The value is a magnification factor around 1.
    var onZoom: ((CGFloat) -> Void)? = nil
    var onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> ScrollMonitorView {
        let view = ScrollMonitorView()
        view.onScroll = onScroll
        view.onZoom = onZoom
        view.enabled = enabled
        return view
    }

    func updateNSView(_ nsView: ScrollMonitorView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onZoom = onZoom
        nsView.enabled = enabled
    }

    final class ScrollMonitorView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        var enabled = false
        private var monitor: Any?

        // Never intercept clicks — a scrollWheel monitor handles scrolling instead.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let win = self.window, event.window === win else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                // A mouse wheel (no precise deltas) or ⌘-scroll zooms — otherwise a
                // mouse user has no way to zoom at all. Everything else pans.
                if let onZoom = self.onZoom,
                   !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command) {
                    let steps = event.scrollingDeltaY
                    guard steps != 0 else { return nil }
                    onZoom(pow(1.06, steps))
                    return nil
                }
                // Match the iPad "grab and move" feel: the map tracks the swipe. The
                // vertical delta is inverted from AppKit's convention; the horizontal
                // already matches.
                self.onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil   // consume so the page/list behind doesn't also scroll
            }
        }

        private func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        deinit { removeMonitor() }
    }
}
#endif
