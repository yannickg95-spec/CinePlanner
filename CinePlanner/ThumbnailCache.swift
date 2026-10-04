//
//  ThumbnailCache.swift
//  CinePlanner
//
//  Cards and rows used to decode the full stored image (`PlatformImage(data:)`) in
//  their body — on every redraw, at full resolution — which is slow and memory-heavy
//  on iPhone, worst with large photos. They now show a downsampled thumbnail, made
//  once with ImageIO and cached; the full image is only decoded for the large view.
//

import Foundation
import ImageIO

enum ThumbnailCache {
    /// Long edge of a card thumbnail: sharp at a card's size on a Retina screen.
    static let cardPixels = 1400

    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 128 * 1_048_576   // decoded bytes
        return cache
    }()

    /// A thumbnail of `data` at most `maxPixels` on its long edge (orientation
    /// applied), from the cache when it's been made before.
    static func image(for data: Data, maxPixels: Int = cardPixels) -> PlatformImage? {
        let key = "\(fingerprint(data))-\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return PlatformImage.fromData(data)
        }
        let image = PlatformImage.fromCGImage(cg, size: CGSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }

    /// A cheap, practically unique key: the size plus hashes of the first and last
    /// 64 KB (hashing a whole multi-megabyte photo on every redraw would undo the point).
    private static func fingerprint(_ data: Data) -> String {
        let span = 65_536
        var hasher = Hasher()
        hasher.combine(data.prefix(span))
        hasher.combine(data.suffix(span))
        return "\(data.count)-\(hasher.finalize())"
    }
}
