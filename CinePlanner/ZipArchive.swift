//
//  ZipArchive.swift
//  CinePlanner
//
//  A tiny, dependency-free ZIP writer (store method, no compression) so we can
//  control entry paths exactly — needed for a Netlify zip deploy, where the
//  files must sit at the archive root (index.html at "/", media at "media/…").
//

import Foundation

struct ZipArchive {
    private struct Entry { let name: String; let crc: UInt32; let size: Int; let offset: Int }
    private var data = Data()
    private var entries: [Entry] = []

    /// Adds a file at `path` (relative, forward slashes, no leading slash).
    mutating func add(path: String, contents: Data) {
        let offset = data.count
        let nameBytes = Array(path.utf8)
        let crc = Self.crc32(contents)

        append32(0x04034b50)                 // local file header signature
        append16(20); append16(0); append16(0)      // version needed, flags, method (store)
        append16(0); append16(0)                     // mod time, mod date
        append32(crc)
        append32(UInt32(contents.count))             // compressed size
        append32(UInt32(contents.count))             // uncompressed size
        append16(UInt16(nameBytes.count)); append16(0)  // name length, extra length
        data.append(contentsOf: nameBytes)
        data.append(contents)

        entries.append(Entry(name: path, crc: crc, size: contents.count, offset: offset))
    }

    /// Returns the finished archive bytes (writes the central directory).
    mutating func finalize() -> Data {
        let cdStart = data.count
        for e in entries {
            let nameBytes = Array(e.name.utf8)
            append32(0x02014b50)             // central directory header signature
            append16(20); append16(20); append16(0); append16(0)   // made-by, needed, flags, method
            append16(0); append16(0)                                // mod time, mod date
            append32(e.crc)
            append32(UInt32(e.size)); append32(UInt32(e.size))      // compressed, uncompressed
            append16(UInt16(nameBytes.count)); append16(0); append16(0)  // name, extra, comment lengths
            append16(0); append16(0); append32(0)                   // disk#, internal, external attrs
            append32(UInt32(e.offset))                              // local header offset
            data.append(contentsOf: nameBytes)
        }
        let cdSize = data.count - cdStart

        append32(0x06054b50)                 // end of central directory signature
        append16(0); append16(0)                                    // disk numbers
        append16(UInt16(entries.count)); append16(UInt16(entries.count))
        append32(UInt32(cdSize)); append32(UInt32(cdStart))
        append16(0)                                                 // comment length
        return data
    }

    // MARK: - Little-endian appends

    private mutating func append16(_ v: UInt16) {
        data.append(UInt8(v & 0xff)); data.append(UInt8((v >> 8) & 0xff))
    }
    private mutating func append32(_ v: UInt32) {
        data.append(UInt8(v & 0xff)); data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8((v >> 16) & 0xff)); data.append(UInt8((v >> 24) & 0xff))
    }

    // MARK: - CRC-32 (table-based)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
        return crc ^ 0xffffffff
    }
}
