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
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformBezierPath = NSBezierPath
/// …but `CGFloat` on macOS.
typealias SCNScalar = CGFloat
#endif

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
