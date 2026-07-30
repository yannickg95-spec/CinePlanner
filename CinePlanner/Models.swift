//
//  Models.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class Project {
    /// Stable identity assigned at creation. Unlike persistentModelID (which is
    /// temporary until the first save), this never changes — safe to key SwiftUI
    /// selection and ForEach on. Backfilled for pre-existing rows at launch.
    var uid: String = UUID().uuidString
    var filmName: String = ""
    var createdDate: Date = Date()
    var lastOpenedDate: Date?   // Updated when the editor opens; drives "last opened" in the project list
    var isSeries: Bool = false  // Series projects have multiple episodes, each with its own script + versions

    // Column width preferences
    var sceneColumnWidth: Double = 300
    var shotColumnWidth: Double = 200
    var detailColumnWidth: Double = 800   // legacy; detail is now flexible
    var scriptColumnWidth: Double = 420   // preferred width of the script pane
    /// The script pane's share of the details+script pair, adjustable within a
    /// band around the middle. Persisted so the split survives window resizes.
    var scriptSplitFraction: Double = 0.5

    // Script PDF (legacy, pre-versioning — migrated into the first episode's first version)
    var scriptPDFData: Data?
    var scriptPDFPageOffset: Int = 0  // Absolute PDF page index (0-based) of the first scene

    // CloudKit requires to-many relationships to be optional. The stored arrays
    // are optional (originalName keeps them bound to the existing relationships,
    // so no data is lost); a computed wrapper preserves the non-optional API used
    // throughout the app.
    @Relationship(deleteRule: .cascade, originalName: "scenes", inverse: \Scene.project)
    var scenesStore: [Scene]?
    var scenes: [Scene] {
        get { scenesStore ?? [] }
        set { scenesStore = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "episodes", inverse: \Episode.project)
    var episodesStore: [Episode]?
    var episodes: [Episode] {
        get { episodesStore ?? [] }
        set { episodesStore = newValue }
    }

    // Legacy pre-episode versions (migrated into episode 1). Kept only for data migration.
    @Relationship(deleteRule: .cascade, originalName: "scriptVersions", inverse: \ScriptVersion.project)
    var scriptVersionsStore: [ScriptVersion]?
    var scriptVersions: [ScriptVersion] {
        get { scriptVersionsStore ?? [] }
        set { scriptVersionsStore = newValue }
    }

    init(filmName: String, isSeries: Bool = false, createdDate: Date = Date()) {
        self.filmName = filmName
        self.isSeries = isSeries
        self.createdDate = createdDate
    }

    var orderedEpisodes: [Episode] {
        episodes.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    /// Ensures the project has the episode → version structure, migrating any
    /// pre-episode / pre-version data into it. Safe to call repeatedly.
    func migrateStructureIfNeeded() {
        // 1. Ensure at least one episode, absorbing legacy project-level versions.
        if episodes.isEmpty {
            let episode = Episode(episodeNumber: 1, title: isSeries ? "Episode 1" : "Main Feature")
            episode.project = self
            for version in Array(scriptVersions) {
                version.episode = episode
                version.project = nil
            }
        }
        // 2. Ensure each episode has at least one version; the first episode
        //    inherits any legacy project-level PDF.
        for episode in orderedEpisodes {
            if episode.scriptVersions.isEmpty {
                let version = ScriptVersion(versionNumber: 1)
                version.episode = episode
                if episode === orderedEpisodes.first {
                    version.pdfData = scriptPDFData
                    version.pdfPageOffset = resolvedPDFPageOffset
                    scriptPDFData = nil
                }
            }
        }
        // 3. Adopt pre-versioning scenes into the first episode's first version.
        if let firstVersion = orderedEpisodes.first?.orderedVersions.first {
            for scene in scenes where scene.scriptVersion == nil {
                scene.scriptVersion = firstVersion
            }
        }

        // 4. Convert the legacy "[OLD] " nickname prefix into the isArchived flag.
        for scene in scenes where scene.nickname.hasPrefix("[OLD] ") {
            scene.isArchived = true
            scene.nickname = String(scene.nickname.dropFirst("[OLD] ".count))
        }

        // 5. Fold the fixed photo1/photo2/video slots into a ShotReference.
        for scene in scenes {
            for shot in scene.shots { shot.migrateReferencesIfNeeded() }
        }
    }

    /// Absolute PDF page index (0-based) of the first scene. Falls back to the
    /// legacy per-scene value for projects imported before the offset was stored here.
    var resolvedPDFPageOffset: Int {
        if scriptPDFPageOffset > 0 { return scriptPDFPageOffset }
        return scenes.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.pdfPageOffset ?? 0
    }
}

@Model
final class Episode {
    var uid: String = UUID().uuidString
    var episodeNumber: Int = 1
    var title: String = ""
    var createdDate: Date = Date()

    var project: Project?

    @Relationship(deleteRule: .cascade, originalName: "scriptVersions", inverse: \ScriptVersion.episode)
    var scriptVersionsStore: [ScriptVersion]?
    var scriptVersions: [ScriptVersion] {
        get { scriptVersionsStore ?? [] }
        set { scriptVersionsStore = newValue }
    }

    init(episodeNumber: Int, title: String? = nil, createdDate: Date = Date()) {
        self.episodeNumber = episodeNumber
        self.title = title ?? "Episode \(episodeNumber)"
        self.createdDate = createdDate
    }

    var orderedVersions: [ScriptVersion] {
        scriptVersions.sorted { $0.versionNumber < $1.versionNumber }
    }

    var totalShotCount: Int {
        scriptVersions.reduce(0) { $0 + $1.totalShotCount }
    }
}

@Model
final class ScriptVersion {
    var uid: String = UUID().uuidString
    var versionNumber: Int = 1
    var name: String = ""
    var createdDate: Date = Date()

    @Attribute(.externalStorage)
    var pdfData: Data?
    var pdfPageOffset: Int = 0  // Absolute PDF page index (0-based) of the first scene

    var project: Project?   // Legacy (nil after migration; ownership is via `episode`)
    var episode: Episode?

    @Relationship(deleteRule: .cascade, originalName: "scenes", inverse: \Scene.scriptVersion)
    var scenesStore: [Scene]?
    var scenes: [Scene] {
        get { scenesStore ?? [] }
        set { scenesStore = newValue }
    }

    init(versionNumber: Int, name: String? = nil, createdDate: Date = Date()) {
        self.versionNumber = versionNumber
        self.name = name ?? "Version \(versionNumber)"
        self.createdDate = createdDate
    }

    var orderedScenes: [Scene] {
        scenes.sorted { $0.sortOrder < $1.sortOrder }
    }

    var totalShotCount: Int {
        scenes.reduce(0) { $0 + $1.shots.count }
    }
}

@Model
final class Scene {
    var uid: String = UUID().uuidString
    var sceneNumber: Int = 0
    var project: Project?
    var scriptVersion: ScriptVersion?
    var sortOrder: Int = 0  // Explicit sort order to maintain list position
    
    var isDay: Bool = true
    var isInterior: Bool = true
    var nickname: String = ""
    var suffix: String = ""

    /// Top-down blocking map (characters + cameras) as a JSON SceneMapDoc.
    var sceneMapJSON: String?

    /// Optional background image for the scene map (e.g. a CineStager clean
    /// top-down location map). Marker positions in `sceneMapJSON` are normalized
    /// to this image's fitted rect.
    @Attribute(.externalStorage)
    var sceneMapBackgroundData: Data?

    /// Scenes kept from a previous import of this version (they still hold shots).
    /// Replaces the old "[OLD] " nickname prefix.
    var isArchived: Bool = false
    
    // UI State
    var isExpandedInExport: Bool = true  // Track if scene is expanded in export view
    
    // Script location information
    var scriptPageNumber: Int = 0  // Scene-relative page (first scene = 1, second scene = 2, etc.)
    var scriptLineNumber: Int = 0  // Line number in text where scene heading was found
    var scriptTimeOfDay: String = ""  // Raw time-of-day from the heading ("DAY", "NIGHT", "DAY - CONTINUOUS", ...)
    var manualAnnotationY: Double = 0  // Manual Y position for PDF annotation (when user drags marker)

    // Legacy PDF page offset (was stored on first scene only; now on Project.scriptPDFPageOffset).
    // Kept so projects imported by older versions keep working.
    var pdfPageOffset: Int = 0  // Absolute PDF page of first scene (0-based)
    
    @Relationship(deleteRule: .cascade, originalName: "shots", inverse: \Shot.scene)
    var shotsStore: [Shot]?
    var shots: [Shot] {
        get { shotsStore ?? [] }
        set { shotsStore = newValue }
    }
    
    init(sceneNumber: Int) {
        self.sceneNumber = sceneNumber
    }
    
    /// Converts scene-relative page number to absolute PDF page index (0-based)
    var absolutePDFPage: Int {
        // Calculate: offset + (scene page - 1)
        // Example: If first scene is on PDF page 5, and this is scene page 3:
        // absolutePDFPage = 5 + (3 - 1) = 7
        let offset = scriptVersion?.pdfPageOffset ?? project?.resolvedPDFPageOffset ?? 0
        return offset + max(0, scriptPageNumber - 1)
    }
}

enum ShotNumberingStyle: String, Codable {
    case numbers
    case letters
}
enum ShotSize: String, Codable, CaseIterable {
    case none = ""
    case extremeCloseUp = "XCU"
    case closeUp = "CU"
    case mediumCloseUp = "MCU"
    case mediumShot = "MS"
    case mediumLongShot = "MLS"
    case longShot = "LS"
    case wideShot = "WS"
    case extremeWideShot = "XWS"
    // Framing shots — a second group in the size picker, not part of the scale.
    case establishingShot = "Establishing Shot"
    case insert = "Insert"

    var shortVersion: String {
        switch self {
        case .none: return ""
        case .extremeCloseUp: return "XCU"
        case .closeUp: return "CU"
        case .mediumCloseUp: return "MCU"
        case .mediumShot: return "MS"
        case .mediumLongShot: return "MLS"
        case .longShot: return "LS"
        case .wideShot: return "WS"
        case .extremeWideShot: return "XWS"
        case .establishingShot: return "Est. Shot"
        case .insert: return "Insert"
        }
    }

    var displayName: String {
        switch self {
        case .none: return "Select size"
        case .extremeCloseUp: return "Extreme Close Up (XCU)"
        case .closeUp: return "Close Up (CU)"
        case .mediumCloseUp: return "Medium Close Up (MCU)"
        case .mediumShot: return "Medium Shot (MS)"
        case .mediumLongShot: return "Medium Long Shot (MLS)"
        case .longShot: return "Long Shot (LS)"
        case .wideShot: return "Wide Shot (WS)"
        case .extremeWideShot: return "Extreme Wide Shot (XWS)"
        case .establishingShot: return "Establishing Shot"
        case .insert: return "Insert"
        }
    }

    /// Short form for a stored raw value — the enum's abbreviation, or the raw
    /// text itself for a user's custom size. Empty when unset.
    static func short(forRaw raw: String) -> String {
        (raw.isEmpty || raw == "none") ? "" : (ShotSize(rawValue: raw)?.shortVersion ?? raw)
    }

    /// The size scale — the main group in the picker.
    static let scaleCases: [ShotSize] = [
        .extremeCloseUp, .closeUp, .mediumCloseUp, .mediumShot,
        .mediumLongShot, .longShot, .wideShot, .extremeWideShot,
    ]

    /// Framing shots — the picker's second group.
    static let framingCases: [ShotSize] = [.establishingShot, .insert]

    static var pickerOptions: [(label: String, value: String)] {
        // Full name without the "(CU)" abbreviation, e.g. "Close Up".
        scaleCases.map { size in
            (label: size.displayName.replacingOccurrences(of: " (\(size.shortVersion))", with: ""),
             value: size.rawValue)
        }
    }
    static var framingOptions: [(label: String, value: String)] {
        framingCases.map { (label: $0.displayName, value: $0.rawValue) }
    }
}

enum ShotType: String, Codable, CaseIterable {
    case none = "none"
    case tripod = "Tripod"
    case lowBowl = "Low Bowl"
    case dolly = "Dolly"
    case slider = "Slider"
    case rickshaw = "Rickshaw"
    case crane = "Crane"
    case jib = "Jib"
    case technocrane = "Technocrane"
    case handheld = "Handheld"
    case steadicam = "Steadicam"
    case gimbal = "Gimbal"
    case easyrig = "Easyrig"
    case drone = "Drone"
    case carmount = "Car Mount"

    var displayName: String {
        switch self {
        case .none: return "Select grip"
        case .tripod: return "Tripod"
        case .lowBowl: return "Low Bowl"
        case .dolly: return "Dolly"
        case .slider: return "Slider"
        case .rickshaw: return "Rickshaw"
        case .crane: return "Crane"
        case .jib: return "Jib"
        case .technocrane: return "Technocrane"
        case .handheld: return "Handheld"
        case .steadicam: return "Steadicam"
        case .gimbal: return "Gimbal"
        case .easyrig: return "Easyrig"
        case .drone: return "Drone"
        case .carmount: return "Car Mount"
        }
    }

    /// Built-in grips grouped for the picker, so like sits with like.
    static let menuGroups: [(title: String, grips: [ShotType])] = [
        ("Sticks",           [.tripod, .lowBowl]),
        ("Dolly & Track",    [.dolly, .slider, .rickshaw]),
        ("Crane & Jib",      [.crane, .jib, .technocrane]),
        ("Handheld",         [.handheld, .easyrig]),
        ("Stabilized",       [.steadicam, .gimbal]),
        ("Vehicle & Aerial", [.carmount, .drone]),
    ]

    /// Built-in grips as (menu label, stored value) pairs. A grip stores its
    /// display name, so label and value are the same.
    static var pickerGroups: [(title: String, options: [(label: String, value: String)])] {
        menuGroups.map { group in
            (title: group.title, options: group.grips.map { (label: $0.displayName, value: $0.displayName) })
        }
    }
}

// A grip has no separate short form, so a custom grip needs no derivation — it's
// read directly via Shot.gripName. Size and type below do have short forms.

enum ShotTypeCategory: String, Codable, CaseIterable {
    case none = ""
    case single = "Single"
    case overTheShoulder = "Over The Shoulder"
    case twoShot = "Two Shot"
    case threeShot = "Three Shot"
    case groupShot = "Group Shot"
    case insert = "Insert"
    case POV = "POV"
    case establishingShot = "Establishing Shot"
    case topShot = "Top Shot"
    case overhead = "Overhead"
    case aerial = "Aerial"
    case lowAngle = "Low Angle"
    case highAngle = "High Angle"
    case dutchAngle = "Dutch Angle"
    case profileShot = "Profile Shot"
    case pushIn = "Push In"
    case pushOut = "Push Out"
    case zoomIn = "Zoom In"
    case zoomOut = "Zoom Out"
    
    var displayName: String {
        switch self {
        case .none: return "Select type"
        case .single: return "Single"
        case .overTheShoulder: return "Over The Shoulder"
        case .twoShot: return "Two Shot"
        case .threeShot: return "Three Shot"
        case .groupShot: return "Group Shot"
        case .insert: return "Insert"
        case .POV: return "POV"
        case .establishingShot: return "Establishing Shot"
        case .topShot: return "Top Shot"
        case .overhead: return "Overhead"
        case .aerial: return "Aerial"
        case .lowAngle: return "Low Angle"
        case .highAngle: return "High Angle"
        case .dutchAngle: return "Dutch Angle"
        case .profileShot: return "Profile Shot"
        case .pushIn: return "Push In"
        case .pushOut: return "Push Out"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .none: return "Select type"
        case .single: return "Single"
        case .overTheShoulder: return "OTS"
        case .twoShot: return "Two Shot"
        case .threeShot: return "Three Shot"
        case .groupShot: return "Group Shot"
        case .insert: return "Insert"
        case .POV: return "POV"
        case .establishingShot: return "Est. Shot"
        case .topShot: return "Top Shot"
        case .overhead: return "Overhead"
        case .aerial: return "Aerial"
        case .lowAngle: return "Low Angle"
        case .highAngle: return "High Angle"
        case .dutchAngle: return "Dutch Angle"
        case .profileShot: return "Profile Shot"
        case .pushIn: return "Push In"
        case .pushOut: return "Push Out"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        }
    }

    /// Short form for a stored raw value — the enum's abbreviation, or the raw
    /// text itself for a user's custom type. Empty when unset.
    static func short(forRaw raw: String) -> String {
        (raw.isEmpty || raw == "none") ? "" : (ShotTypeCategory(rawValue: raw)?.shortDisplayName ?? raw)
    }

    /// Built-in types grouped for the picker, as (menu label, stored value).
    static var pickerGroups: [(title: String, options: [(label: String, value: String)])] {
        func opts(_ cases: [ShotTypeCategory]) -> [(label: String, value: String)] {
            cases.map { (label: $0.displayName, value: $0.rawValue) }
        }
        return [
            ("Coverage", opts([.single, .overTheShoulder, .twoShot, .threeShot, .groupShot, .POV, .profileShot])),
            ("Movement", opts([.pushIn, .pushOut, .zoomIn, .zoomOut])),
            ("Angle",    opts([.lowAngle, .highAngle, .dutchAngle, .topShot, .overhead, .aerial])),
        ]
    }
}

// MARK: - Shot Reference

/// One reference for a shot: a photo *or* a video, optionally paired with its
/// own top-down map. A shot can carry several, replacing the fixed
/// photo1/photo2/video slots the app started with.
@Model
final class ShotReference {
    var uid: String = UUID().uuidString
    var sortOrder: Int = 0

    // Media — exactly one of these is set
    var imageData: Data?
    var videoData: Data?
    var videoExtension: String?     // "mov", "mp4" — used for export filenames

    /// Top-down map belonging to this reference — an image, or a video (e.g. a
    /// Shot Designer top-down animation). At most one of the two is set.
    var mapData: Data?
    var mapVideoData: Data?
    var mapVideoExtension: String?  // "mov", "mp4" — used for export filenames

    /// A short user note shown under this reference's media in the PDF, the HTML
    /// export, and the published web page. Distinct from `caption`, which is EXIF
    /// text read off the image.
    var note: String?

    // EXIF/metadata read off the reference image
    var cameraFamily: String?
    var cameraFormat: String?
    var focalLength: Double?
    var lensPreset: String?
    var horizon: Double?
    var tilt: Double?
    var height: Double?
    var captureID: String?
    var captureType: String?
    var dateTimeOriginal: Date?
    var keywords: [String]?
    var caption: String?
    var framelines: String?
    var software: String?

    // Metadata read off the map
    var mapCaptureID: String?
    var mapCameraPhysicalWidth: Double?
    var mapCameraPhysicalLength: Double?
    var mapLocationModel: String?
    var mapLocationWidth: Double?
    var mapLocationLength: Double?
    var mapLocationHeight: Double?

    var shot: Shot?

    init(sortOrder: Int = 0) {
        self.sortOrder = sortOrder
    }

    /// True when this reference holds a video rather than a still.
    var isVideo: Bool { videoData != nil }
    var hasMedia: Bool { imageData != nil || videoData != nil }

    /// Metadata rebuilt for the shared MetadataView.
    var imageMetadata: PhotoMetadata {
        var m = PhotoMetadata()
        m.cameraFamily = cameraFamily
        m.cameraFormat = cameraFormat
        m.focalLength = focalLength
        m.lensPreset = lensPreset
        m.horizon = horizon
        m.tilt = tilt
        m.height = height
        m.captureID = captureID
        m.captureType = captureType
        m.dateTimeOriginal = dateTimeOriginal
        m.iptcKeywords = keywords
        m.iptcCaption = caption
        m.framelines = framelines
        m.tiffSoftware = software
        return m
    }

    var mapMetadata: PhotoMetadata {
        var m = PhotoMetadata()
        m.captureID = mapCaptureID
        m.cameraPhysicalWidth = mapCameraPhysicalWidth
        m.cameraPhysicalLength = mapCameraPhysicalLength
        m.locationModel = mapLocationModel
        m.locationWidth = mapLocationWidth
        m.locationLength = mapLocationLength
        m.locationHeight = mapLocationHeight
        return m
    }

    func duplicate() -> ShotReference {
        let copy = ShotReference(sortOrder: sortOrder)
        copy.imageData = imageData
        copy.videoData = videoData
        copy.videoExtension = videoExtension
        copy.mapData = mapData
        copy.mapVideoData = mapVideoData
        copy.mapVideoExtension = mapVideoExtension
        copy.note = note
        copy.cameraFamily = cameraFamily
        copy.cameraFormat = cameraFormat
        copy.focalLength = focalLength
        copy.lensPreset = lensPreset
        copy.horizon = horizon
        copy.tilt = tilt
        copy.height = height
        copy.captureID = captureID
        copy.captureType = captureType
        copy.dateTimeOriginal = dateTimeOriginal
        copy.keywords = keywords
        copy.caption = caption
        copy.framelines = framelines
        copy.software = software
        copy.mapCaptureID = mapCaptureID
        copy.mapCameraPhysicalWidth = mapCameraPhysicalWidth
        copy.mapCameraPhysicalLength = mapCameraPhysicalLength
        copy.mapLocationModel = mapLocationModel
        copy.mapLocationWidth = mapLocationWidth
        copy.mapLocationLength = mapLocationLength
        copy.mapLocationHeight = mapLocationHeight
        return copy
    }
}

@Model
final class Shot {
    var uid: String = UUID().uuidString
    var shotNumber: Int = 0
    var shotInformation: String = ""
    private var numberingStyleRaw: String = "numbers"
    private var sizeRaw: String = ""
    private var secondSizeRaw: String = ""
    private var typeCategoryRaw: String = ""
    private var secondTypeCategoryRaw: String = ""
    private var thirdTypeCategoryRaw: String = ""
    private var typeRaw: String = ""
    var suffix: String = ""
    var nickname: String = ""
    var lensIsPrime: Bool = true
    var lensfocal: Int = 0
    var lensfocalEnd: Int = 0
    var extraInfo: String = ""
    
    // Auto-filled from metadata
    var camera: String = ""
    var format: String = ""
    var framelines: String = ""
    var lensPreset: String = ""
    
    // Store photo data as Data
    @Attribute(.externalStorage)
    var photo1Data: Data?

    @Attribute(.externalStorage)
    var photo2Data: Data?

    // Optional reference video for the reference shot slot (shown in-app and in
    // the HTML-with-media export). Stored externally since videos are large.
    @Attribute(.externalStorage)
    /// Legacy single-video slot; migrated into a ShotReference on first open.
    /// originalName keeps it bound to the existing column — renaming a @Model
    /// property without it makes SwiftData treat it as a new, empty attribute.
    @Attribute(originalName: "referenceVideoData") var videoDataLegacy: Data?
    var referenceVideoExtension: String?  // e.g. "mov", "mp4" — used for the exported filename
    
    // EXIF Metadata for Photo 1 (Shot Photo)
    var photo1CameraFamily: String?
    var photo1CameraFormat: String?
    var photo1FocalLength: Double?
    var photo1LensPreset: String?
    var photo1Horizon: Double?  // Previously pitch
    var photo1Tilt: Double?      // Previously roll
    var photo1Height: Double?
    var photo1CaptureID: String?
    var photo1CaptureType: String?
    
    // Additional Metadata for Photo 1
    var photo1DateTimeOriginal: Date?
    var photo1Keywords: [String]?
    var photo1Caption: String?
    var photo1Framelines: String?
    var photo1Software: String?
    
    // EXIF Metadata for Photo 2 (Top Down Photo)
    var photo2CameraFamily: String?
    var photo2CameraFormat: String?
    var photo2FocalLength: Double?
    var photo2LensPreset: String?
    var photo2Horizon: Double?  // Previously pitch
    var photo2Tilt: Double?      // Previously roll
    var photo2Height: Double?
    var photo2CaptureID: String?
    var photo2CaptureType: String?
    
    // Additional Metadata for Photo 2
    var photo2DateTimeOriginal: Date?
    var photo2Keywords: [String]?
    var photo2Caption: String?
    var photo2Framelines: String?
    var photo2Software: String?
    
    // Location/Environment Metadata for Photo 2 (Top-Down)
    var photo2CameraPhysicalWidth: Double?
    var photo2CameraPhysicalLength: Double?
    var photo2LocationModel: String?
    var photo2LocationWidth: Double?
    var photo2LocationLength: Double?
    var photo2LocationHeight: Double?
    
    // Script Coverage - stores text selection information
    var scriptCoverageSelections: [ScriptTextSelection]?
    
    /// Reference photos/videos, each with an optional top-down map. Replaces the
    /// fixed photo1/photo2/video slots; those are migrated on first open.
    @Relationship(deleteRule: .cascade, originalName: "references", inverse: \ShotReference.shot)
    var referencesStore: [ShotReference]?
    var references: [ShotReference] {
        get { referencesStore ?? [] }
        set { referencesStore = newValue }
    }

    var orderedReferences: [ShotReference] {
        references.sorted { $0.sortOrder < $1.sortOrder }
    }

    var scene: Scene?
    
    var numberingStyle: ShotNumberingStyle {
        get {
            ShotNumberingStyle(rawValue: numberingStyleRaw) ?? .numbers
        }
        set {
            numberingStyleRaw = newValue.rawValue
        }
    }
    
    var size: ShotSize {
        get {
            ShotSize(rawValue: sizeRaw) ?? .none
        }
        set {
            sizeRaw = newValue.rawValue
        }
    }
    
    var secondSize: ShotSize {
        get {
            ShotSize(rawValue: secondSizeRaw) ?? .none
        }
        set {
            secondSizeRaw = newValue.rawValue
        }
    }
    
    var typeCategory: ShotTypeCategory {
        get {
            ShotTypeCategory(rawValue: typeCategoryRaw) ?? .none
        }
        set {
            typeCategoryRaw = newValue.rawValue
        }
    }
    
    var secondTypeCategory: ShotTypeCategory {
        get {
            ShotTypeCategory(rawValue: secondTypeCategoryRaw) ?? .none
        }
        set {
            secondTypeCategoryRaw = newValue.rawValue
        }
    }
    
    var thirdTypeCategory: ShotTypeCategory {
        get {
            ShotTypeCategory(rawValue: thirdTypeCategoryRaw) ?? .none
        }
        set {
            thirdTypeCategoryRaw = newValue.rawValue
        }
    }
    
    var type: ShotType {
        get {
            ShotType(rawValue: typeRaw) ?? .none
        }
        set {
            typeRaw = newValue.rawValue
        }
    }

    /// The grip as free text — a built-in name or a user's custom one; empty
    /// when unset. Backed by the same field as `type`, so a custom string that
    /// isn't one of the built-ins round-trips here where `type` would flatten it
    /// to `.none`.
    var gripName: String {
        get { Self.unset(typeRaw) }
        set { typeRaw = newValue }
    }
    var hasGrip: Bool { !gripName.isEmpty }

    // Size and type as free text, backed by the same raw fields as the enum
    // accessors above. A custom value that isn't a built-in round-trips here,
    // where the enum accessors would flatten it to `.none`. `…Short` yields the
    // export/subtitle abbreviation (the raw text itself for a custom value).
    var sizeName: String { get { Self.unset(sizeRaw) } set { sizeRaw = newValue } }
    var secondSizeName: String { get { Self.unset(secondSizeRaw) } set { secondSizeRaw = newValue } }
    var sizeShort: String { ShotSize.short(forRaw: sizeRaw) }
    var secondSizeShort: String { ShotSize.short(forRaw: secondSizeRaw) }
    var hasSize: Bool { !sizeShort.isEmpty }
    var hasSecondSize: Bool { !secondSizeShort.isEmpty }

    var typeName: String { get { Self.unset(typeCategoryRaw) } set { typeCategoryRaw = newValue } }
    var secondTypeName: String { get { Self.unset(secondTypeCategoryRaw) } set { secondTypeCategoryRaw = newValue } }
    var thirdTypeName: String { get { Self.unset(thirdTypeCategoryRaw) } set { thirdTypeCategoryRaw = newValue } }
    var typeShort: String { ShotTypeCategory.short(forRaw: typeCategoryRaw) }
    var secondTypeShort: String { ShotTypeCategory.short(forRaw: secondTypeCategoryRaw) }
    var thirdTypeShort: String { ShotTypeCategory.short(forRaw: thirdTypeCategoryRaw) }
    var hasType: Bool { !typeShort.isEmpty }
    var hasSecondType: Bool { !secondTypeShort.isEmpty }
    var hasThirdType: Bool { !thirdTypeShort.isEmpty }

    private static func unset(_ raw: String) -> String { (raw.isEmpty || raw == "none") ? "" : raw }

    init(shotNumber: Int, shotInformation: String = "") {
        self.shotNumber = shotNumber
        self.shotInformation = shotInformation
    }
    
    var displayNumber: String {
        let sceneNumber = scene?.sceneNumber ?? 0
        let sceneSuffix = scene?.suffix ?? ""
        
        switch numberingStyle {
        case .numbers:
            return "\(sceneNumber)\(sceneSuffix).\(shotNumber)\(suffix)"
        case .letters:
            return "\(sceneNumber)\(sceneSuffix).\(numberToLetter(shotNumber))\(suffix)"
        }
    }
    
    private func numberToLetter(_ number: Int) -> String {
        guard number > 0 else { return "A" }
        var result = ""
        var num = number - 1
        
        while num >= 0 {
            result = String(UnicodeScalar(65 + (num % 26))!) + result
            num = num / 26 - 1
        }
        
        return result
    }
}

extension Shot {
    /// Deep copy of this shot, for transferring into a scene of another script
    /// version. Script coverage selections are intentionally not copied — they
    /// store page positions in the source version's PDF and would misalign.
    /// Moves the legacy photo1 / video / photo2 slots into a single reference.
    /// Runs once per shot: afterwards the old fields are cleared, so `references`
    /// being non-empty (or the old fields being empty) means there's nothing to do.
    func migrateReferencesIfNeeded() {
        guard references.isEmpty else { return }
        let hasLegacyMedia = photo1Data != nil || videoDataLegacy != nil || photo2Data != nil
        guard hasLegacyMedia else { return }

        let reference = ShotReference(sortOrder: 0)
        reference.imageData = photo1Data
        reference.videoData = videoDataLegacy
        reference.videoExtension = referenceVideoExtension
        reference.mapData = photo2Data

        reference.cameraFamily = photo1CameraFamily
        reference.cameraFormat = photo1CameraFormat
        reference.focalLength = photo1FocalLength
        reference.lensPreset = photo1LensPreset
        reference.horizon = photo1Horizon
        reference.tilt = photo1Tilt
        reference.height = photo1Height
        reference.captureID = photo1CaptureID
        reference.captureType = photo1CaptureType
        reference.dateTimeOriginal = photo1DateTimeOriginal
        reference.keywords = photo1Keywords
        reference.caption = photo1Caption
        reference.framelines = photo1Framelines
        reference.software = photo1Software

        reference.mapCaptureID = photo2CaptureID
        reference.mapCameraPhysicalWidth = photo2CameraPhysicalWidth
        reference.mapCameraPhysicalLength = photo2CameraPhysicalLength
        reference.mapLocationModel = photo2LocationModel
        reference.mapLocationWidth = photo2LocationWidth
        reference.mapLocationLength = photo2LocationLength
        reference.mapLocationHeight = photo2LocationHeight

        reference.shot = self

        // Every reader now goes through `references`, so the legacy slots can go.
        photo1Data = nil
        photo2Data = nil
        videoDataLegacy = nil
        referenceVideoExtension = nil
    }

    func duplicate() -> Shot {
        let copy = Shot(shotNumber: shotNumber, shotInformation: shotInformation)
        copy.numberingStyle = numberingStyle
        // The …Name accessors copy the raw string, preserving a custom size,
        // type, or grip that the enum accessors would flatten to none.
        copy.sizeName = sizeName
        copy.secondSizeName = secondSizeName
        copy.typeName = typeName
        copy.secondTypeName = secondTypeName
        copy.thirdTypeName = thirdTypeName
        copy.gripName = gripName
        copy.suffix = suffix
        copy.nickname = nickname
        copy.lensIsPrime = lensIsPrime
        copy.lensfocal = lensfocal
        copy.lensfocalEnd = lensfocalEnd
        copy.extraInfo = extraInfo
        copy.camera = camera
        copy.format = format
        copy.framelines = framelines
        copy.lensPreset = lensPreset

        for reference in orderedReferences {
            let copied = reference.duplicate()
            copied.shot = copy
        }
        copy.photo1Data = photo1Data
        copy.photo2Data = photo2Data
        copy.videoDataLegacy = videoDataLegacy
        copy.referenceVideoExtension = referenceVideoExtension

        copy.photo1CameraFamily = photo1CameraFamily
        copy.photo1CameraFormat = photo1CameraFormat
        copy.photo1FocalLength = photo1FocalLength
        copy.photo1LensPreset = photo1LensPreset
        copy.photo1Horizon = photo1Horizon
        copy.photo1Tilt = photo1Tilt
        copy.photo1Height = photo1Height
        copy.photo1CaptureID = photo1CaptureID
        copy.photo1CaptureType = photo1CaptureType
        copy.photo1DateTimeOriginal = photo1DateTimeOriginal
        copy.photo1Keywords = photo1Keywords
        copy.photo1Caption = photo1Caption
        copy.photo1Framelines = photo1Framelines
        copy.photo1Software = photo1Software

        copy.photo2CameraFamily = photo2CameraFamily
        copy.photo2CameraFormat = photo2CameraFormat
        copy.photo2FocalLength = photo2FocalLength
        copy.photo2LensPreset = photo2LensPreset
        copy.photo2Horizon = photo2Horizon
        copy.photo2Tilt = photo2Tilt
        copy.photo2Height = photo2Height
        copy.photo2CaptureID = photo2CaptureID
        copy.photo2CaptureType = photo2CaptureType
        copy.photo2DateTimeOriginal = photo2DateTimeOriginal
        copy.photo2Keywords = photo2Keywords
        copy.photo2Caption = photo2Caption
        copy.photo2Framelines = photo2Framelines
        copy.photo2Software = photo2Software

        copy.photo2CameraPhysicalWidth = photo2CameraPhysicalWidth
        copy.photo2CameraPhysicalLength = photo2CameraPhysicalLength
        copy.photo2LocationModel = photo2LocationModel
        copy.photo2LocationWidth = photo2LocationWidth
        copy.photo2LocationLength = photo2LocationLength
        copy.photo2LocationHeight = photo2LocationHeight

        return copy
    }
}

// MARK: - Script Coverage Models

/// Represents a text selection in the PDF script for a shot
struct ScriptTextSelection: Codable, Identifiable {
    let id: UUID
    var pageRanges: [PageTextRange] // Array of ranges, one per page
    var fullText: String? // The complete selected text (optional for backward compatibility)
    
    init(id: UUID = UUID(), pageRanges: [PageTextRange], fullText: String? = nil) {
        self.id = id
        self.pageRanges = pageRanges
        self.fullText = fullText
    }
}

/// Represents a text selection range on a specific page
struct PageTextRange: Codable {
    let pageIndex: Int // 0-based PDF page index
    let selections: [PDFSelectionBounds] // Multiple selections on the same page
    
    init(pageIndex: Int, selections: [PDFSelectionBounds]) {
        self.pageIndex = pageIndex
        self.selections = selections
    }
}

/// Stores the bounds of a PDF selection in page coordinates
struct PDFSelectionBounds: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    
    init(from rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
    }
    
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Helper Extensions

extension ScriptTextSelection {
    /// Creates a ScriptTextSelection from a PDFSelection (requires PDFKit import)
    /// Use this method when creating coverage from PDF text selection
    init(id: UUID = UUID(), pdfSelection: Any, pageRanges: [PageTextRange]) {
        self.id = id
        self.pageRanges = pageRanges
        
        // Extract text from PDFSelection if available
        // In your ScriptPDFViewer, cast 'pdfSelection' to PDFSelection and use:
        // self.fullText = (pdfSelection as? PDFSelection)?.string
        self.fullText = nil // This will be set in the actual implementation
    }
}

// MARK: - Reference convenience

extension Shot {
    /// Every reference image, in order.
    var referenceImages: [Data] { orderedReferences.compactMap(\.imageData) }
    /// Every top-down map, in order.
    var referenceMaps: [Data] { orderedReferences.compactMap(\.mapData) }
    /// First reference image — for places that show a single representative photo.
    var primaryImageData: Data? { referenceImages.first }
    /// First top-down map.
    var primaryMapData: Data? { referenceMaps.first }
    /// Total photos attached to the shot (references + their maps).
    var attachedPhotoCount: Int { referenceImages.count + referenceMaps.count }
    var hasAnyReferenceMedia: Bool { orderedReferences.contains { $0.hasMedia || $0.mapData != nil || $0.mapVideoData != nil } }
}
