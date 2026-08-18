//
//  PlatformSupport.swift
//  CinePlanner
//
//  Cross-platform aliases and helpers so the app builds for macOS (AppKit) and
//  iPad/iOS (UIKit) from one source. AppKit and UIKit spell the same concepts
//  differently — NSImage/UIImage, NSColor/UIColor, NSBezierPath/UIBezierPath —
//  so we alias them to neutral `Platform…` names and paper over the few method
//  differences the app actually uses.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformBezierPath = UIBezierPath
/// SceneKit vector components are `Float` on iOS/iPadOS…
typealias SCNScalar = Float
typealias PlatformViewBase = UIView
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformBezierPath = NSBezierPath
/// …but `CGFloat` on macOS.
typealias SCNScalar = CGFloat
typealias PlatformViewBase = NSView
#endif

// MARK: - Conditional modifier

extension View {
    /// Applies `transform` only when `condition` is true, leaving the view
    /// untouched otherwise. Handy for gating a modifier by size class.
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - SwiftUI Image

extension Image {
    /// Builds a SwiftUI `Image` from the platform's native image type.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

// MARK: - Image encoding / decoding

extension PlatformImage {
    /// Decodes an image from data, cross-platform.
    static func fromData(_ data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    /// Wraps a `CGImage` in a platform image (macOS needs an explicit point size).
    static func fromCGImage(_ cg: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: size)
        #endif
    }

    /// PNG encoding that preserves transparency, cross-platform.
    func pngRepresentation() -> Data? {
        #if canImport(UIKit)
        return pngData()
        #else
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    /// JPEG encoding at the given quality (0…1), cross-platform.
    func jpegRepresentation(quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return jpegData(compressionQuality: quality)
        #else
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    /// The backing `CGImage`, cross-platform.
    var cgImageForDrawing: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #else
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// The image's size in pixels (points × scale on iOS; the largest bitmap rep
    /// on macOS), used when the true pixel resolution matters for export.
    var pixelSize: CGSize {
        #if canImport(UIKit)
        return CGSize(width: size.width * scale, height: size.height * scale)
        #else
        if let rep = representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
        #endif
    }
}

// MARK: - Keyboard / focus

enum PlatformKeyboard {
    /// Resigns the current text-field focus, committing the edit and dismissing the
    /// keyboard — used when the user taps/clicks outside a field.
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

// MARK: - Pasteboard

enum PlatformPasteboard {
    /// Copies a string to the system pasteboard, cross-platform.
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

// MARK: - Semantic background colors

extension Color {
    /// The window/control chrome background (`controlBackgroundColor` on macOS).
    static var platformControlBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// A text-field/editor background (`textBackgroundColor` on macOS).
    static var platformTextBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .textBackgroundColor)
        #endif
    }
}

// MARK: - Color components

extension Color {
    /// sRGB components of this color, cross-platform.
    var rgbaComponents: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if canImport(UIKit)
        PlatformColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let ns = PlatformColor(self).usingColorSpace(.sRGB) ?? .white
        r = ns.redComponent; g = ns.greenComponent; b = ns.blueComponent; a = ns.alphaComponent
        #endif
        return (r, g, b, a)
    }

    /// This color mixed toward white by `fraction` (0…1), returned opaque.
    func mixedWithWhite(_ fraction: CGFloat) -> Color {
        let c = rgbaComponents
        func mix(_ v: CGFloat) -> Double { Double(v * (1 - fraction) + fraction) }
        return Color(red: mix(c.r), green: mix(c.g), blue: mix(c.b))
    }
}

// MARK: - Graphics drawing (cross-platform)

enum PlatformGraphics {
    /// Makes `context` the current graphics context for the duration of `body`,
    /// so `NSAttributedString`/`NSString` drawing routes into it. AppKit uses
    /// `NSGraphicsContext.current`; UIKit uses `UIGraphicsPushContext`.
    /// `flipped` matters only on macOS (whether the context's y-axis grows down).
    static func drawing(into context: CGContext, flipped: Bool = true, _ body: () -> Void) {
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        body()
        #else
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        defer { NSGraphicsContext.current = previous }
        body()
        #endif
    }

    /// Makes `context` current for text/bezier drawing until `popContext()`.
    /// Push/pop must be balanced on iOS; on macOS `pop` is a no-op.
    static func pushContext(_ context: CGContext, flipped: Bool = true) {
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        #else
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        #endif
    }

    static func popContext() {
        #if canImport(UIKit)
        UIGraphicsPopContext()
        #endif
    }

    /// Renders `size`-point content into a `PlatformImage` via a drawing closure,
    /// cross-platform (UIGraphicsImageRenderer on iOS, lockFocus on macOS). The
    /// closure receives a context whose origin is bottom-left, y-up — matching the
    /// AppKit `lockFocus` convention the exporter's drawing code assumes.
    static func image(size: CGSize, scale: CGFloat = 1, _ draw: (CGContext) -> Void) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Flip to y-up so shared drawing code matches macOS's lockFocus context.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            drawing(into: cg, flipped: false) { draw(cg) }
        }
        #else
        let image = NSImage(size: size)
        image.lockFocus()
        if let cg = NSGraphicsContext.current?.cgContext { draw(cg) }
        image.unlockFocus()
        return image
        #endif
    }
}

// MARK: - Semantic label color

extension PlatformColor {
    /// Primary label/text color (`textColor` on macOS, `label` on iOS).
    static var platformLabel: PlatformColor {
        #if canImport(UIKit)
        return .label
        #else
        return .textColor
        #endif
    }
}

// MARK: - Rounded-rect bezier

extension PlatformBezierPath {
    /// A rounded-rect path, cross-platform (NSBezierPath uses xRadius/yRadius;
    /// UIBezierPath uses a single cornerRadius).
    static func rounded(_ rect: CGRect, radius: CGFloat) -> PlatformBezierPath {
        #if canImport(UIKit)
        return PlatformBezierPath(roundedRect: rect, cornerRadius: radius)
        #else
        return PlatformBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #endif
    }
}

// MARK: - Share sheet (iOS)

#if canImport(UIKit)
enum PlatformShare {
    /// Presents a share sheet for the given items (e.g. exported file URLs) from
    /// the top-most presented view controller. iPad anchors the popover centrally.
    /// `onComplete` fires after the share sheet is dismissed (shared or cancelled).
    @MainActor static func present(_ items: [Any], onComplete: (() -> Void)? = nil) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?
                .rootViewController else { onComplete?(); return }
        // Present from the top-most controller (e.g. an open export sheet), not one
        // that's mid-dismissal — otherwise the share sheet silently fails to appear.
        var presenter = root
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete?() }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
}
#endif

// MARK: - Appearance

enum PlatformAppearance {
    /// Runs `body` with the UI appearance pinned to light, so dynamic system
    /// colors resolve to their light-mode values (exported PDFs are on white paper,
    /// so dark-mode colors would render invisible).
    static func performLight(_ body: () -> Void) {
        #if canImport(UIKit)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { body() }
        #else
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        light.performAsCurrentDrawingAppearance { body() }
        #endif
    }
}

// MARK: - Opening URLs

enum PlatformURLOpener {
    /// Opens a URL in the user's browser / associated app, cross-platform.
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}
