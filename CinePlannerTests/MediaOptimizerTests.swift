//
//  MediaOptimizerTests.swift
//  CinePlannerTests
//
//  Photos are scaled down when they come in. That must keep the metadata the app
//  reads from them (camera, lens, focal length, the CinemaAR UserComment) and must
//  leave images that are already small byte-for-byte alone.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CinePlanner

final class MediaOptimizerTests: XCTestCase {

    /// A `width`×`height` image encoded as `type`, carrying EXIF and TIFF metadata.
    private func makeImage(width: Int, height: Int, type: UTType = .jpeg, alpha: Bool = false) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: info))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(ctx.makeImage())

        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifLensModel: "Signature Prime 35mm",
                kCGImagePropertyExifUserComment: "CinemaAR|captureID=ABC123",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "ARRI",
                kCGImagePropertyTIFFModel: "Alexa 35",
                kCGImagePropertyTIFFSoftware: "CineStager",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testLargePhotoIsScaledToTheLongEdgeLimit() throws {
        let original = try makeImage(width: 6000, height: 4000)
        let small = MediaOptimizer.optimizedImage(original)
        let (w, h) = try XCTUnwrap(pixelSize(small))
        XCTAssertEqual(max(w, h), MediaOptimizer.photoMaxPixels)
        XCTAssertEqual(Double(w) / Double(h), 1.5, accuracy: 0.01, "aspect ratio kept")
        XCTAssertLessThan(small.count, original.count)
    }

    func testMetadataSurvivesScaling() throws {
        let original = try makeImage(width: 6000, height: 4000)
        let small = MediaOptimizer.optimizedImage(original)
        let exif = properties(small)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties(small)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifFocalLength] as? Double, 35)
        XCTAssertEqual(exif?[kCGImagePropertyExifLensModel] as? String, "Signature Prime 35mm")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "ARRI")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "Alexa 35")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFSoftware] as? String, "CineStager")
        // What the app actually reads from a photo is unchanged.
        let before = EXIFExtractor.extractMetadata(from: original)
        let after = EXIFExtractor.extractMetadata(from: small)
        XCTAssertEqual(after?.focalLength, before?.focalLength)
        XCTAssertEqual(after?.lensPreset, before?.lensPreset)
        XCTAssertEqual(after?.cameraFamily, before?.cameraFamily)
        XCTAssertEqual(after?.tiffSoftware, before?.tiffSoftware)
    }

    func testSmallPhotoIsLeftUntouched() throws {
        let original = try makeImage(width: 1600, height: 900)
        XCTAssertEqual(MediaOptimizer.optimizedImage(original), original)
    }

    func testMapsKeepMoreDetail() throws {
        let original = try makeImage(width: 8000, height: 6000)
        let map = MediaOptimizer.optimizedImage(original, maxPixels: MediaOptimizer.mapMaxPixels)
        XCTAssertEqual(pixelSize(map).map { max($0.0, $0.1) }, MediaOptimizer.mapMaxPixels)
    }

    func testTransparentImagesStayPNG() throws {
        let original = try makeImage(width: 5000, height: 5000, type: .png, alpha: true)
        let small = MediaOptimizer.optimizedImage(original)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
    }

    func testUnreadableDataIsLeftUntouched() {
        let junk = Data("not an image".utf8)
        XCTAssertEqual(MediaOptimizer.optimizedImage(junk), junk)
    }
}
