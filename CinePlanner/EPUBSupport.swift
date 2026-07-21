//
//  EPUBSupport.swift
//  CinePlanner
//
//  Low-level building blocks for the EPUB export: a minimal (store-only) ZIP
//  writer that satisfies the EPUB OCF layout, and an H.264 video transcoder so
//  the embedded clips play in Apple Books on iOS and macOS.

import Foundation
import AVFoundation

// MARK: - CRC32

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Store-only ZIP writer

/// Writes a ZIP archive with every entry *stored* (no compression). That's all
/// an EPUB needs — images/video are already compressed — and it keeps the
/// `mimetype` entry uncompressed and first, exactly as the OCF spec requires.
///
/// Note: uses 32-bit offsets/sizes (no ZIP64), which is fine for shot-list
/// reference media (individual files well under 4 GB).
struct ZipWriter {
    private var output = Data()
    private struct Entry { let name: String; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private var entries: [Entry] = []

    mutating func addFile(_ name: String, data fileData: Data) {
        let offset = UInt32(output.count)
        let crc = CRC32.checksum(fileData)
        let size = UInt32(fileData.count)
        let nameBytes = Array(name.utf8)

        // Local file header
        append32(0x0403_4b50)          // signature
        append16(20)                   // version needed
        append16(0)                    // general purpose flags
        append16(0)                    // method 0 = stored
        append16(0); append16(0)       // mod time / date
        append32(crc)
        append32(size)                 // compressed size
        append32(size)                 // uncompressed size
        append16(UInt16(nameBytes.count))
        append16(0)                    // extra length
        output.append(contentsOf: nameBytes)
        output.append(fileData)

        entries.append(Entry(name: name, crc: crc, size: size, offset: offset))
    }

    mutating func finalizeData() -> Data {
        let centralStart = UInt32(output.count)
        for e in entries {
            let nameBytes = Array(e.name.utf8)
            append32(0x0201_4b50)      // central directory signature
            append16(20)               // version made by
            append16(20)               // version needed
            append16(0)                // flags
            append16(0)                // method
            append16(0); append16(0)   // time / date
            append32(e.crc)
            append32(e.size)
            append32(e.size)
            append16(UInt16(nameBytes.count))
            append16(0)                // extra length
            append16(0)                // comment length
            append16(0)                // disk number
            append16(0)                // internal attrs
            append32(0)                // external attrs
            append32(e.offset)         // local header offset
            output.append(contentsOf: nameBytes)
        }
        let centralSize = UInt32(output.count) - centralStart

        // End of central directory
        append32(0x0605_4b50)
        append16(0); append16(0)       // disk numbers
        append16(UInt16(entries.count))
        append16(UInt16(entries.count))
        append32(centralSize)
        append32(centralStart)
        append16(0)                    // comment length

        return output
    }

    private mutating func append16(_ v: UInt16) {
        output.append(UInt8(v & 0xFF)); output.append(UInt8((v >> 8) & 0xFF))
    }
    private mutating func append32(_ v: UInt32) {
        output.append(UInt8(v & 0xFF))
        output.append(UInt8((v >> 8) & 0xFF))
        output.append(UInt8((v >> 16) & 0xFF))
        output.append(UInt8((v >> 24) & 0xFF))
    }
}

// MARK: - Video transcoding

enum VideoTranscoder {
    /// Transcodes a video to 720p H.264/AAC MP4 — the codec Apple Books plays
    /// reliably. Returns nil on failure (caller can fall back to the original).
    static func h264MP4(from videoData: Data, sourceExtension: String) async -> Data? {
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("epub_src_\(UUID().uuidString).\(sourceExtension)")
        let dst = dir.appendingPathComponent("epub_out_\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        do { try videoData.write(to: src) } catch { return nil }

        let asset = AVURLAsset(url: src)
        let preset = AVAssetExportPreset1280x720
        guard AVAssetExportSession.exportPresets(compatibleWith: asset).contains(preset),
              let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            return nil
        }
        export.outputURL = dst
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }

        guard export.status == .completed else {
            print("⚠️ [EPUB] Transcode failed: \(export.error?.localizedDescription ?? "unknown")")
            return nil
        }
        return try? Data(contentsOf: dst)
    }
}
