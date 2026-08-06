//
//  EXIFExtractor.swift
//  CineStager 2
//
//  Created by Yannick Giraud on 16/12/2025.
//

import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PhotoMetadata {
    /// True when anything was actually read off the file — used to decide
    /// whether a metadata block is worth showing at all.
    var hasContent: Bool {
        cameraFamily != nil || cameraFormat != nil || focalLength != nil || lensPreset != nil
            || tilt != nil || horizon != nil || height != nil || captureID != nil
            || captureType != nil || dateTimeOriginal != nil || iptcCaption != nil
            || framelines != nil || tiffSoftware != nil
            || cameraPhysicalWidth != nil || cameraPhysicalLength != nil
            || locationModel != nil || locationWidth != nil || locationLength != nil
            || locationHeight != nil
    }

    /// The rows the top-down map metadata card actually shows — used both to
    /// render it and to decide whether it's worth showing (so it never appears
    /// empty just because, say, only a capture id came through).
    var mapDisplayItems: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let model = locationModel, !model.isEmpty { rows.append(("Location", model)) }
        if let w = cameraPhysicalWidth, let l = cameraPhysicalLength {
            rows.append(("Camera Size", String(format: "%.1fcm × %.1fcm", w, l)))
        } else if let w = cameraPhysicalWidth {
            rows.append(("Camera Width", String(format: "%.1fcm", w)))
        } else if let l = cameraPhysicalLength {
            rows.append(("Camera Length", String(format: "%.1fcm", l)))
        }
        if let w = locationWidth, let l = locationLength {
            rows.append(("Location Dimensions", String(format: "%.2fm × %.2fm", w, l)))
        }
        if let h = locationHeight {
            rows.append(("Location Height", String(format: "%.2fm", h)))
        }
        return rows
    }

    // Camera Settings
    var cameraFamily: String?
    var cameraFormat: String?
    var focalLength: Double?
    var lensPreset: String?
    
    // Device Pose
    var tilt: Double?      // Pitch
    var horizon: Double?   // Roll
    var height: Double?
    
    // Capture Matching
    var captureID: String?
    var captureType: String?
    
    // Additional Fields
    var dateTimeOriginal: Date?
    var iptcKeywords: [String]?
    var iptcCaption: String?
    var tiffSoftware: String?
    var framelines: String?
    
    // Location/Environment Data (Top-Down Photo)
    var cameraPhysicalWidth: Double?   // in cm
    var cameraPhysicalLength: Double?  // in cm
    var locationModel: String?
    var locationWidth: Double?         // in meters
    var locationLength: Double?        // in meters
    var locationHeight: Double?        // in meters
}

class EXIFExtractor {
    
    /// Extract EXIF metadata from image data
    static func extractMetadata(from imageData: Data) -> PhotoMetadata? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            print("❌ Failed to create image source or get properties")
            return nil
        }
        
        // Debug: Print all available properties
        print("📸 Available metadata dictionaries:")
        for (key, value) in properties {
            print("  - \(key)")
            // Print the actual content of smaller dictionaries
            if let dict = value as? [String: Any], dict.count < 20 {
                for (subKey, subValue) in dict {
                    print("      [\(subKey)] = \(subValue)")
                }
            }
        }
        
        var metadata = PhotoMetadata()
        
        // Extract EXIF data
        if let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            print("📝 EXIF Dictionary found with \(exifDict.count) keys")
            
            // Debug: Print all EXIF keys
            print("  EXIF keys: \(exifDict.keys.joined(separator: ", "))")
            
            // Focal length
            if let focalLength = exifDict[kCGImagePropertyExifFocalLength as String] as? Double {
                metadata.focalLength = focalLength
                print("  ✅ Focal Length: \(focalLength)mm")
            }
            
            // Lens model/preset
            if let lensModel = exifDict[kCGImagePropertyExifLensModel as String] as? String {
                metadata.lensPreset = lensModel
                print("  ✅ Lens Model: \(lensModel)")
            }
            
            // Parse UserComment (CinemaAR pipe-delimited format)
            if let userComment = exifDict[kCGImagePropertyExifUserComment as String] {
                print("  📋 UserComment found: \(type(of: userComment))")
                parseCinemaARUserComment(userComment, into: &metadata)
            } else {
                print("  ⚠️ No UserComment found in EXIF")
            }
            
            // Date/Time Original
            if let dtString = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                let formatter = DateFormatter()
                // Common EXIF format: "yyyy:MM:dd HH:mm:ss"
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                if let date = formatter.date(from: dtString) {
                    metadata.dateTimeOriginal = date
                    print("  ✅ DateTimeOriginal: \(date)")
                } else {
                    print("  ⚠️ Could not parse DateTimeOriginal string: \(dtString)")
                }
            } else if let dt = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? Date {
                metadata.dateTimeOriginal = dt
                print("  ✅ DateTimeOriginal: \(dt)")
            }
        } else {
            print("⚠️ No EXIF dictionary found")
        }
        
        // Extract TIFF data (camera info)
        if let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            print("🏷️ TIFF Dictionary found with \(tiffDict.count) keys")
            print("  TIFF keys: \(tiffDict.keys.joined(separator: ", "))")
            
            // Debug: Print all TIFF values
            for (key, value) in tiffDict {
                print("    TIFF[\(key)] = \(value)")
            }
            
            let make = tiffDict[kCGImagePropertyTIFFMake as String] as? String
            let model = tiffDict[kCGImagePropertyTIFFModel as String] as? String
            let software = tiffDict[kCGImagePropertyTIFFSoftware as String] as? String

            if let software {
                metadata.tiffSoftware = software
                print("  ✅ TIFF Software: \(software)")
            }

            // Cadrage packs its data differently from CineStager: the camera,
            // sensor mode and aspect are pipe-separated inside Make, and the
            // focal length sits in Model. Detect it by the Software tag and parse
            // accordingly; otherwise use the standard Make=camera / Model=format.
            if let software, software.localizedCaseInsensitiveContains("cadrage") {
                parseCadrageTIFF(make: make, model: model, into: &metadata)
            } else {
                if let make {
                    metadata.cameraFamily = make
                    print("  ✅ Camera Make: \(make)")
                }
                if let model {
                    metadata.cameraFormat = model
                    print("  ✅ Camera Model: \(model)")
                }
            }
        } else {
            print("⚠️ No TIFF dictionary found")
        }
        
        // Extract IPTC data (CinemaAR keywords and SpecialInstructions)
        if let iptcDict = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            print("📰 IPTC Dictionary found with \(iptcDict.count) keys")
            print("  IPTC keys: \(iptcDict.keys.joined(separator: ", "))")
            extractIPTCMetadata(from: iptcDict, into: &metadata)
        } else {
            print("⚠️ No IPTC dictionary found")
        }
        
        // Extract GPS data (if available, for height)
        if let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            print("📍 GPS Dictionary found")
            if let altitude = gpsDict[kCGImagePropertyGPSAltitude as String] as? Double {
                // Convert meters to centimeters
                metadata.height = altitude * 100
                print("  ✅ GPS Altitude: \(altitude)m (\(altitude * 100)cm)")
            }
        }
        
        print("📊 Final metadata summary:")
        print("  Camera: \(metadata.cameraFamily ?? "nil") / \(metadata.cameraFormat ?? "nil")")
        print("  Focal Length: \(metadata.focalLength?.description ?? "nil")")
        print("  Lens Preset: \(metadata.lensPreset ?? "nil")")
        print("  Horizon: \(metadata.horizon?.description ?? "nil")")
        print("  Tilt: \(metadata.tilt?.description ?? "nil")")
        print("  Height: \(metadata.height?.description ?? "nil")")
        print("  Capture ID: \(metadata.captureID ?? "nil")")
        print("  Capture Type: \(metadata.captureType ?? "nil")")
        print("  DateTimeOriginal: \(metadata.dateTimeOriginal?.description ?? "nil")")
        print("  Framelines: \(metadata.framelines ?? "nil")")
        print("  IPTC Keywords: \(metadata.iptcKeywords?.joined(separator: ", ") ?? "nil")")
        print("  TIFF Software: \(metadata.tiffSoftware ?? "nil")")
        print("  IPTC Caption: \(metadata.iptcCaption ?? "nil")")
        
        return metadata
    }
    
    /// Parse CinemaAR pipe-delimited UserComment format
    /// Format: "Yaw:45.23° | Pitch:12.50° | Roll:0.15° | Height:150.0cm | Preset:Wide Primes | CaptureID:UUID | Type:Photo"
    /// Cadrage Director's Viewfinder stores its data in the TIFF fields:
    ///   Make  = "ARRI Alexa Mini  |  4:3 2.8K  |  2.39:1"  (camera | sensor | aspect)
    ///   Model = "35mm"                                      (focal length)
    /// so the camera goes to cameraFamily, the sensor mode to cameraFormat, the
    /// trailing aspect ratio to framelines, and the focal length is read off Model
    /// rather than EXIF FocalLength.
    /// True for a bare aspect ratio like "1.78:1", "2.39:1", "16:9" — as opposed
    /// to a sensor mode ("16:9 Mode 3.2K") that merely contains one.
    private static func isAspectRatio(_ s: String) -> Bool {
        s.range(of: #"^[0-9]+(\.[0-9]+)?\s*:\s*[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private static func parseCadrageTIFF(make: String?, model: String?, into metadata: inout PhotoMetadata) {
        if let make {
            let parts = make.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let camera = parts.first {
                metadata.cameraFamily = camera
                print("  ✅ [Cadrage] Camera: \(camera)")
            }
            if parts.count > 1 {
                var formatParts = Array(parts.dropFirst())
                // Cadrage appends the frameline aspect ratio as the last field — a
                // bare ratio like "1.78:1". Peel it off into framelines so it lands
                // in the right place, leaving the sensor mode ("16:9 Mode 3.2K") as
                // the format.
                if let last = formatParts.last, isAspectRatio(last) {
                    metadata.framelines = last
                    formatParts.removeLast()
                    print("  ✅ [Cadrage] Framelines: \(last)")
                }
                if !formatParts.isEmpty {
                    let format = formatParts.joined(separator: " · ")
                    metadata.cameraFormat = format
                    print("  ✅ [Cadrage] Format: \(format)")
                }
            }
        }

        // "35mm", "35 mm", "35.0mm" -> 35.0
        if let model,
           let match = model.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
           let focal = Double(model[match]) {
            metadata.focalLength = focal
            print("  ✅ [Cadrage] Focal Length: \(focal)mm")
        }
    }

    private static func parseCinemaARUserComment(_ userComment: Any, into metadata: inout PhotoMetadata) {
        // UserComment can be String, Data, or Array
        var commentString: String?
        
        print("  🔍 Parsing UserComment of type: \(type(of: userComment))")
        
        if let str = userComment as? String {
            commentString = str
            print("  📝 UserComment as String: '\(str)'")
        } else if let data = userComment as? Data {
            commentString = String(data: data, encoding: .utf8)
            print("  📝 UserComment as Data, converted to: '\(commentString ?? "nil")'")
        } else if let array = userComment as? [UInt8] {
            commentString = String(bytes: array, encoding: .utf8)
            print("  📝 UserComment as [UInt8], converted to: '\(commentString ?? "nil")'")
        } else {
            print("  ⚠️ UserComment is unexpected type, trying description")
            commentString = String(describing: userComment)
        }
        
        guard let comment = commentString else {
            print("  ❌ Could not convert UserComment to String")
            return
        }
        
        print("  🔸 Splitting by ' | '")
        
        // Split by " | " (pipe with spaces)
        let parts = comment.components(separatedBy: " | ")
        print("  🔸 Found \(parts.count) parts: \(parts)")
        
        for part in parts {
            let keyValue = part.components(separatedBy: ":")
            guard keyValue.count >= 2 else {
                print("    ⚠️ Skipping malformed part: '\(part)'")
                continue
            }
            
            let key = keyValue[0].trimmingCharacters(in: .whitespaces)
            let value = keyValue[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            
            print("    🔑 Key: '\(key)', Value: '\(value)'")
            
            switch key {
            case "Pitch":
                if let angle = parseNumericDouble(from: value) {
                    metadata.tilt = angle
                    print("      ✅ Parsed and SET Tilt (from Pitch): \(angle)")
                    print("      🔍 Metadata.tilt is now: \(metadata.tilt?.description ?? "nil")")
                } else {
                    print("      ⚠️ Could not parse Tilt from '\(value)'")
                }
                
            case "Roll":
                if let angle = parseNumericDouble(from: value) {
                    metadata.horizon = angle
                    print("      ✅ Parsed and SET Horizon (from Roll): \(angle)")
                    print("      🔍 Metadata.horizon is now: \(metadata.horizon?.description ?? "nil")")
                } else {
                    print("      ⚠️ Could not parse Horizon from '\(value)'")
                }
                
            case "Height":
                if let h = parseNumericDouble(from: value) {
                    metadata.height = h
                    print("      ✅ Parsed Height: \(h)cm")
                } else {
                    print("      ⚠️ Could not parse Height from '\(value)'")
                }
                
            case "Preset":
                metadata.lensPreset = value
                print("      ✅ Parsed Preset: \(value)")
                
            case "CaptureID":
                metadata.captureID = value
                print("      ✅ Parsed CaptureID: \(value)")
                
            case "Type":
                metadata.captureType = value
                print("      ✅ Parsed Type: \(value)")
            
            // Location/Environment metadata (Top-Down Photos)
            case "Camera Physical Width":
                if let width = parseNumericDouble(from: value) {
                    metadata.cameraPhysicalWidth = width
                    print("      ✅ Parsed Camera Physical Width: \(width)cm")
                } else {
                    print("      ⚠️ Could not parse Camera Physical Width from '\(value)'")
                }
            
            case "Camera Physical Length":
                if let length = parseNumericDouble(from: value) {
                    metadata.cameraPhysicalLength = length
                    print("      ✅ Parsed Camera Physical Length: \(length)cm")
                } else {
                    print("      ⚠️ Could not parse Camera Physical Length from '\(value)'")
                }
            
            case "Location Model":
                metadata.locationModel = value
                print("      ✅ Parsed Location Model: \(value)")
            
            case "Location Width":
                if let width = parseNumericDouble(from: value) {
                    metadata.locationWidth = width
                    print("      ✅ Parsed Location Width: \(width)m")
                } else {
                    print("      ⚠️ Could not parse Location Width from '\(value)'")
                }
            
            case "Location Length":
                if let length = parseNumericDouble(from: value) {
                    metadata.locationLength = length
                    print("      ✅ Parsed Location Length: \(length)m")
                } else {
                    print("      ⚠️ Could not parse Location Length from '\(value)'")
                }
            
            case "Location Height":
                if let height = parseNumericDouble(from: value) {
                    metadata.locationHeight = height
                    print("      ✅ Parsed Location Height: \(height)m")
                } else {
                    print("      ⚠️ Could not parse Location Height from '\(value)'")
                }
                
            default:
                print("    ⚠️ Unknown key: '\(key)'")
                break
            }
        }
    }
    
    /// Strip non-numeric characters (except '-', '.'), then convert to Double
    private static func parseNumericDouble(from string: String) -> Double? {
        // Remove common suffixes like °, ?, cm, mm, etc.
        let cleaned = string
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "cm", with: "")
            .replacingOccurrences(of: "mm", with: "")
            .trimmingCharacters(in: .whitespaces)
        
        // Filter to keep only valid numeric characters
        let filtered = cleaned.filter { "0123456789.-".contains($0) }
        
        // Debug log
        if filtered != string {
            print("        🔧 Cleaned '\(string)' → '\(filtered)'")
        }
        
        guard let result = Double(filtered) else {
            print("        ❌ Failed to parse '\(filtered)' as Double")
            return nil
        }
        
        return result
    }
    
    /// Extract metadata from IPTC fields
    private static func extractIPTCMetadata(from iptcDict: [String: Any], into metadata: inout PhotoMetadata) {
        // CinemaAR puts Capture ID in SpecialInstructions
        // Format: "CaptureID:A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        if let specialInstructions = iptcDict[kCGImagePropertyIPTCSpecialInstructions as String] as? String {
            if specialInstructions.hasPrefix("CaptureID:") {
                let captureID = String(specialInstructions.dropFirst("CaptureID:".count))
                metadata.captureID = captureID
            }
        }

        // Keywords array
        if let keywords = iptcDict[kCGImagePropertyIPTCKeywords as String] as? [String] {
            metadata.iptcKeywords = keywords
            // Also infer capture type from keywords if available
            if metadata.captureType == nil {
                if keywords.contains("Photo") {
                    metadata.captureType = "Photo"
                } else if keywords.contains("Top-Down") || keywords.contains("TopDown") {
                    metadata.captureType = "TopDown"
                }
            }
        }

        // Caption-Abstract may contain camera info and framelines
        if let caption = iptcDict[kCGImagePropertyIPTCCaptionAbstract as String] as? String {
            metadata.iptcCaption = caption
            // Caption format: "Camera: ARRI Alexa Mini • 2.39:1 • 35mm • Preset: Wide Primes"
            extractCameraInfoFromCaption(caption, into: &metadata)
            // Parse framelines token from caption if present
            if metadata.framelines == nil {
                metadata.framelines = parseFramelines(from: caption)
            }
        }
    }
    
    /// Extract camera info from IPTC caption
    private static func extractCameraInfoFromCaption(_ caption: String, into metadata: inout PhotoMetadata) {
        let parts = caption.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        
        for part in parts {
            if part.hasPrefix("Camera:") {
                let camera = part.replacingOccurrences(of: "Camera:", with: "").trimmingCharacters(in: .whitespaces)
                if metadata.cameraFormat == nil {
                    metadata.cameraFormat = camera
                }
            } else if part.hasPrefix("Preset:") {
                let preset = part.replacingOccurrences(of: "Preset:", with: "").trimmingCharacters(in: .whitespaces)
                if metadata.lensPreset == nil {
                    metadata.lensPreset = preset
                }
            } else if part.hasSuffix("mm") {
                // Focal length like "35mm"
                let focalStr = part.replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
                if let focal = Double(focalStr), metadata.focalLength == nil {
                    metadata.focalLength = focal
                }
            }
        }
    }
    
    /// Parse framelines token from IPTC caption. Example caption:
    /// "Camera: Arri Alexa 35 4.6K 16:9 • Anamorphic 2.39:1 • 35mm"
    private static func parseFramelines(from caption: String) -> String? {
        let parts = caption.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        
        // Look through all parts to find one that matches framelines pattern
        for part in parts {
            // Skip empty parts
            if part.isEmpty {
                continue
            }
            
            // Skip if it ends with "mm" (focal length, not framelines)
            if part.hasSuffix("mm") {
                continue
            }
            
            // Skip if it starts with known non-framelines prefixes
            if part.hasPrefix("Camera:") || part.hasPrefix("Preset:") {
                continue
            }
            
            // Framelines should contain either ":" or "."
            if part.contains(":") || part.contains(".") {
                return part
            }
        }
        
        return nil
    }
    
    /// Format metadata for display
    static func formatMetadata(_ metadata: PhotoMetadata) -> [String] {
        var lines: [String] = []
        
        // Camera Settings
        if let family = metadata.cameraFamily {
            lines.append("Camera: \(family)")
        }
        if let format = metadata.cameraFormat {
            lines.append("Model: \(format)")
        }
        if let focal = metadata.focalLength {
            lines.append("Focal Length: \(String(format: "%.1f", focal))mm")
        }
        if let lens = metadata.lensPreset {
            lines.append("Lens: \(lens)")
        }
        
        // Device Pose
        if let horizon = metadata.horizon {
            lines.append("Horizon: \(String(format: "%.1f", horizon))°")
        }
        if let tilt = metadata.tilt {
            lines.append("Tilt: \(String(format: "%.1f", tilt))°")
        }
        if let height = metadata.height {
            lines.append("Height: \(String(format: "%.0f", height))cm")
        }
        
        // Capture Info
        if let captureType = metadata.captureType {
            lines.append("Type: \(captureType)")
        }
        if let captureID = metadata.captureID {
            lines.append("Capture ID: \(captureID)")
        }
        
        // Additional
        if let date = metadata.dateTimeOriginal {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            lines.append("Date: \(df.string(from: date))")
        }
        if let framelines = metadata.framelines {
            lines.append("Framelines: \(framelines)")
        }
        if let keywords = metadata.iptcKeywords, !keywords.isEmpty {
            lines.append("Keywords: \(keywords.joined(separator: ", "))")
        }
        if let software = metadata.tiffSoftware {
            lines.append("Software: \(software)")
        }
        
        return lines
    }
}
