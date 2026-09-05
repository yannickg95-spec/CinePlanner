//
//  Models.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 15/12/2025.
//

import Foundation
import SwiftData
import SwiftUI

extension ModelContext {
    /// Runs an irreversible cascade delete without undo/autosave snapshotting.
    ///
    /// The app attaches an `UndoManager` to the main context, so every delete
    /// makes SwiftData snapshot the affected objects for undo. During a cascade
    /// delete that reaches un-faulted rows — notably shot references holding
    /// inline image/video data — snapshot creation crashes
    /// (`ModelSnapshot.swift: Unexpected backing data … _FullFutureBackingData`).
    /// These deletes are irreversible by design, so drop undo + autosave for the
    /// operation, clear the undo history that would otherwise dangle onto the
    /// deleted graph, run the deletions, then save explicitly (while autosave is
    /// still off, so the pending deletes are flushed before it re-enables).
    func destructiveDelete(_ body: () -> Void) {
        let undo = undoManager
        let autosave = autosaveEnabled
        undo?.removeAllActions()
        undoManager = nil
        autosaveEnabled = false
        defer {
            autosaveEnabled = autosave
            undoManager = undo
        }
        body()
        try? save()
    }
}

@Model
final class Project {
    /// Stable identity assigned at creation. Unlike persistentModelID (which is
    /// temporary until the first save), this never changes — safe to key SwiftUI
    /// selection and ForEach on. Backfilled for pre-existing rows at launch.
    var uid: String = UUID().uuidString
    var filmName: String = ""
    // Production credits, shown in exports. Live on the project so they persist
    // across all its script versions. Defaulted, so adding them migrates cleanly.
    var productionCompany: String = ""
    var director: String = ""
    var cinematographer: String = ""
    var createdDate: Date = Date()
    var lastOpenedDate: Date?   // Updated when the editor opens; drives "last opened" in the project list
    var isSeries: Bool = false  // Series projects have multiple episodes, each with its own script + versions
    /// When on, every shot carries a film-length calculator tool, and new shots
    /// get one automatically. Toggled on by adding the tool from a shot.
    var autoAddFilmTool: Bool = false

    // Per-project card settings (all defaulted → CloudKit-safe additive migration).
    /// Order of the Shot Setup card's fields, as comma-joined `ShotSetupField` raw
    /// values. Empty = the default order.
    /// How coverage-line colours are drawn and handed out. Stored raw and
    /// defaulted so the attributes stay CloudKit-safe; both live on the project so
    /// a series looks the same across its episodes and on every device.
    var coveragePaletteRaw: String = CoveragePaletteChoice.classic.rawValue
    var coverageColorModeRaw: String = CoverageColorMode.perScene.rawValue

    var shotSetupFieldOrderRaw: String = ""
    /// Shot Setup fields hidden for this project, as comma-joined raw values.
    var hiddenShotSetupFieldsRaw: String = ""
    /// Project-wide default camera package. New shots start with these values; each
    /// shot stays independently editable.
    var defaultCamera: String = ""
    var defaultFramelines: String = ""
    var defaultLens: String = ""

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

    /// Characters detected in the script (name + assigned marker color), as JSON.
    /// Optional so adding it migrates existing stores automatically.
    var scriptCharactersJSON: String?

    /// The GitHub repository ("owner/repo") this project's web page was published
    /// to, so re-publishing reuses the same repo and the "Manage Repositories"
    /// list can tell which pages are still in use. Stored on the model (not
    /// UserDefaults) so the link syncs across devices via CloudKit — otherwise a
    /// publish on iPad leaves the Mac showing the repo as orphaned.
    var publishedRepoFullName: String?

    /// The public GitHub Pages URL for `publishedRepoFullName`, or nil if unpublished.
    var publishedPagesURL: String? {
        guard let full = publishedRepoFullName, let slash = full.firstIndex(of: "/") else { return nil }
        let owner = String(full[..<slash]).lowercased()
        let name = String(full[full.index(after: slash)...])
        return "https://\(owner).github.io/\(name)/"
    }

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

    // MARK: Characters

    /// Distinct marker colors handed out to characters in order.
    static let characterPalette = [
        "#4C8DFF", "#FF9500", "#34C759", "#AF52DE", "#FF3B30",
        "#FFCC00", "#5AC8FA", "#FF2D55", "#A2845E", "#30B0C7",
    ]

    /// Characters detected in / added to the script, decoded from JSON.
    var scriptCharacters: [ScriptCharacter] {
        get {
            guard let data = scriptCharactersJSON?.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ScriptCharacter].self, from: data)) ?? []
        }
        set {
            scriptCharactersJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Adds any not-yet-known character names, each with the next palette color.
    /// Case-insensitive de-dup; existing characters keep their color.
    func addScriptCharacters(named names: [String]) {
        var chars = scriptCharacters
        var seen = Set(chars.map { $0.name.uppercased() })
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces)
            let key = name.uppercased()
            guard !name.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            let color = Project.characterPalette[chars.count % Project.characterPalette.count]
            chars.append(ScriptCharacter(name: name, colorHex: color))
        }
        scriptCharacters = chars
    }
}

/// A character found in the script, with the color used for its scene-map
/// mannequin markers.
struct ScriptCharacter: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String
}

@Model
final class Episode {
    var uid: String = UUID().uuidString
    var episodeNumber: Int = 1
    var title: String = ""
    var createdDate: Date = Date()
    // Per-episode production credits (a series can have a different director /
    // cinematographer per episode). Production Company stays on the project.
    // Empty falls back to the project-level value in exports.
    var director: String = ""
    var cinematographer: String = ""

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
    /// How far the script-coverage lines sit from the page edge, as a fraction of
    /// page width (the near-text edge of the coverage-line band). Larger = closer to
    /// the text, for scripts with a wider margin. Default 0.15.
    var coverageLineMargin: Double = 0.15
    /// Draw the coverage lines down the right margin instead of the left. Defaulted
    /// (CloudKit-safe); the margin fraction is measured from whichever edge.
    var coverageLinesOnRight: Bool = false

    var project: Project?   // Legacy (nil after migration; ownership is via `episode`)
    var episode: Episode?

    @Relationship(deleteRule: .cascade, originalName: "scenes", inverse: \Scene.scriptVersion)
    var scenesStore: [Scene]?
    var scenes: [Scene] {
        get { scenesStore ?? [] }
        set { scenesStore = newValue }
    }

    /// Shooting days for this version's scenes (the schedule board). Per version, so
    /// switching versions shows that version's schedule.
    @Relationship(deleteRule: .cascade, inverse: \ShootingDay.scriptVersion)
    var shootingDaysStore: [ShootingDay]?
    var shootingDays: [ShootingDay] {
        get { shootingDaysStore ?? [] }
        set { shootingDaysStore = newValue }
    }

    init(versionNumber: Int, name: String? = nil, createdDate: Date = Date()) {
        self.versionNumber = versionNumber
        self.name = name ?? "Version \(versionNumber)"
        self.createdDate = createdDate
    }

    var orderedScenes: [Scene] {
        scenes.sorted { $0.sortOrder < $1.sortOrder }
    }

    var orderedShootingDays: [ShootingDay] {
        shootingDays.sorted { $0.sortOrder < $1.sortOrder }
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

    /// True when the background is an Apple Maps satellite still. Kept out of
    /// exports (map-data redistribution), though markers still render.
    var sceneMapBackgroundIsSatellite: Bool = false
    /// The satellite capture's centre and size, so the map picker reopens where it
    /// was last set.
    var sceneMapSatelliteLat: Double?
    var sceneMapSatelliteLon: Double?
    var sceneMapSatelliteMeters: Double?
    /// Compass direction that points up in the capture, in degrees clockwise from
    /// north. 0 is north-up, which every capture was before the map could be turned —
    /// so an existing scene reads back exactly as it was made.
    var sceneMapSatelliteHeading: Double = 0
    /// False for captures made before the snapshot scale was measured rather than
    /// assumed. Those images cover more ground than `sceneMapSatelliteMeters` says
    /// (MapKit silently widens anything past its zoom limit), which draws markers
    /// too large and makes a reframe drift. `SatelliteCalibration` corrects them
    /// once, on open, and sets this. New captures are calibrated by construction.
    var sceneMapSatelliteCalibrated: Bool = false

    /// Real-world width (metres) the background represents, when known (satellite
    /// capture size, or CineStager location width). nil for backgrounds with no
    /// measurement → markers keep their default sizes.
    var sceneMapMetersWide: Double?
    /// Real camera-marker diameter (metres) from CineStager; nil → default 0.6 m.
    var sceneMapCameraSizeMeters: Double?

    /// Draw a field-of-view wedge (two rays) from every camera marker, from the
    /// linked shot's focal length. A per-scene toggle set from a camera's
    /// right-click menu — it applies to every camera in the scene, present and
    /// future. Cameras with no focal length draw nothing. Default off.
    var sceneMapShowCameraFOV: Bool = false

    /// On a measured background (a CineStager or satellite map), camera and
    /// mannequin markers render at their real-world size — which can be tiny on a
    /// large location. When true, they use a fixed, easily-visible size instead.
    /// A per-scene toggle; only meaningful when the map has a real-world scale.
    var sceneMapViewableMarkerSize: Bool = false

    /// The CineStager location model the current scene-map background came from,
    /// so importing another shot of the same location adds its markers without
    /// prompting to replace the (same) map. nil for hand-set / drawn backgrounds.
    var sceneMapLocation: String?

    /// Optional drawn floor plan (walls + doors/windows) as a JSON FloorPlan,
    /// used as the scene-map background instead of an image.
    var sceneFloorPlanJSON: String?

    /// Scenes kept from a previous import of this version (they still hold shots).
    /// Replaces the old "[OLD] " nickname prefix.
    var isArchived: Bool = false
    
    // UI State
    var isExpandedInExport: Bool = true  // Track if scene is expanded in export view
    
    // Script location information
    var scriptPageNumber: Int = 0  // Scene-relative page (first scene = 1, second scene = 2, etc.)
    var scriptLineNumber: Int = 0  // Line number in text where scene heading was found
    /// Character names cued in this scene's dialogue (JSON), detected at import —
    /// used to auto-label the scene map's mannequin markers.
    var sceneCharactersJSON: String?

    /// Sun-direction overlay settings for this scene's map (JSON).
    var sunSettingsJSON: String?
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

    /// Inverse of `ScheduleEntry.scene` — required by CloudKit (every relationship
    /// needs an inverse). Deleting a scene removes its schedule strips too.
    @Relationship(deleteRule: .cascade, inverse: \ScheduleEntry.scene)
    var scheduleEntriesStore: [ScheduleEntry]?

    /// Shots in their canonical display order. `shots` is an unordered SwiftData
    /// relationship whose iteration order can differ between stores/platforms, so
    /// anything that must be deterministic across Mac and iPad (e.g. per-shot
    /// coverage colours) indexes off this instead.
    var orderedShots: [Shot] {
        shots.sorted { ($0.shotNumber, $0.displayNumber) < ($1.shotNumber, $1.displayNumber) }
    }
    
    init(sceneNumber: Int) {
        self.sceneNumber = sceneNumber
    }

    /// Character names cued in this scene (decoded from `sceneCharactersJSON`).
    var sceneCharacterNames: [String] {
        get {
            guard let data = sceneCharactersJSON?.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            sceneCharactersJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Sun-direction overlay settings (decoded from `sunSettingsJSON`).
    var sunSettings: SunSettings {
        get {
            guard let data = sunSettingsJSON?.data(using: .utf8) else { return SunSettings() }
            return (try? JSONDecoder().decode(SunSettings.self, from: data)) ?? SunSettings()
        }
        set {
            sunSettingsJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
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
    /// A unique running number across the whole project (001, 002, 003…), ignoring
    /// scene boundaries.
    case continuous
}

/// The reorderable fields of the Shot Setup card. Their order is a per-project
/// setting (`Project.shotSetupFieldOrder`).
enum ShotSetupField: String, CaseIterable, Identifiable, Codable {
    case nickname, size, type, focal, grip, description
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nickname:    return "Nickname"
        case .size:        return "Size"
        case .type:        return "Type"
        case .focal:       return "Focal Length"
        case .grip:        return "Grip"
        case .description: return "Description"
        }
    }
}

extension Project {
    /// The set of colours this project's coverage lines are drawn from.
    var coveragePalette: CoveragePaletteChoice {
        get { CoveragePaletteChoice(rawValue: coveragePaletteRaw) ?? .classic }
        set { coveragePaletteRaw = newValue.rawValue }
    }

    /// How those colours are spread over the script's shots.
    var coverageColorMode: CoverageColorMode {
        get { CoverageColorMode(rawValue: coverageColorModeRaw) ?? .perScene }
        set { coverageColorModeRaw = newValue.rawValue }
    }

    /// The Shot Setup fields in this project's chosen order. Always complete and
    /// de-duplicated: any missing field is appended in its default position and
    /// unknown/duplicate entries are dropped, so it stays valid as fields change.
    var shotSetupFieldOrder: [ShotSetupField] {
        get {
            let saved = shotSetupFieldOrderRaw
                .split(separator: ",")
                .compactMap { ShotSetupField(rawValue: String($0)) }
            var result: [ShotSetupField] = []
            var seen = Set<ShotSetupField>()
            for f in saved where seen.insert(f).inserted { result.append(f) }
            for f in ShotSetupField.allCases where seen.insert(f).inserted { result.append(f) }
            return result
        }
        set { shotSetupFieldOrderRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }

    /// Shot Setup fields hidden for this project (not shown in the shot editor).
    var hiddenShotSetupFields: Set<ShotSetupField> {
        get {
            Set(hiddenShotSetupFieldsRaw.split(separator: ",")
                .compactMap { ShotSetupField(rawValue: String($0)) })
        }
        set { hiddenShotSetupFieldsRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }
}

extension Scene {
    /// The owning project, however the graph is wired: directly, or through the
    /// script version's episode, or the version's legacy project link.
    var resolvedProject: Project? {
        project ?? scriptVersion?.episode?.project ?? scriptVersion?.project
    }

    /// A deep copy of this scene with fresh ids: same content, its shots duplicated
    /// (keeping their per-scene numbers), and the scene map's camera markers
    /// re-pointed at the copied shots. The caller assigns the copy's scene number,
    /// sort order and owner (project / script version). Script-position fields and
    /// schedule strips are intentionally not copied — the copy is a new scene, not
    /// tied to the script text or the shooting schedule.
    func duplicate() -> Scene {
        let copy = Scene(sceneNumber: sceneNumber)
        copy.isDay = isDay
        copy.isInterior = isInterior
        copy.nickname = nickname
        copy.suffix = suffix
        copy.scriptTimeOfDay = scriptTimeOfDay

        // Scene map background, floor plan, sun overlay and their scale/flags.
        copy.sceneMapBackgroundData = sceneMapBackgroundData
        copy.sceneMapBackgroundIsSatellite = sceneMapBackgroundIsSatellite
        copy.sceneMapSatelliteLat = sceneMapSatelliteLat
        copy.sceneMapSatelliteLon = sceneMapSatelliteLon
        copy.sceneMapSatelliteMeters = sceneMapSatelliteMeters
        copy.sceneMapSatelliteHeading = sceneMapSatelliteHeading
        copy.sceneMapSatelliteCalibrated = sceneMapSatelliteCalibrated
        copy.sceneMapMetersWide = sceneMapMetersWide
        copy.sceneMapCameraSizeMeters = sceneMapCameraSizeMeters
        copy.sceneMapShowCameraFOV = sceneMapShowCameraFOV
        copy.sceneMapViewableMarkerSize = sceneMapViewableMarkerSize
        copy.sceneMapLocation = sceneMapLocation
        copy.sceneFloorPlanJSON = sceneFloorPlanJSON
        copy.sceneCharactersJSON = sceneCharactersJSON
        copy.sunSettingsJSON = sunSettingsJSON

        // Deep-copy the shots, tracking old→new uid so the map can be re-pointed.
        var uidMap: [String: String] = [:]
        for shot in orderedShots {
            let shotCopy = shot.duplicate()
            uidMap[shot.uid] = shotCopy.uid
            shotCopy.scene = copy
        }

        // Re-point the scene map's camera markers at the copied shots.
        if let json = sceneMapJSON {
            var doc = SceneMapDoc.load(from: json)
            for index in doc.elements.indices {
                if let old = doc.elements[index].shotUID, let new = uidMap[old] {
                    doc.elements[index].shotUID = new
                }
            }
            copy.sceneMapJSON = doc.jsonString
        }

        return copy
    }
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

    // Media — exactly one of these is set. Stored as files beside the store
    // rather than inline: a reference photo is ~0.8 MB and a video far more, and
    // inline blobs bloat every row, every fetch and every CloudKit record.
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var videoData: Data?
    var videoExtension: String?     // "mov", "mp4" — used for export filenames

    /// Top-down map belonging to this reference — an image, or a video (e.g. a
    /// Shot Designer top-down animation). At most one of the two is set.
    @Attribute(.externalStorage) var mapData: Data?
    @Attribute(.externalStorage) var mapVideoData: Data?
    var mapVideoExtension: String?  // "mov", "mp4" — used for export filenames
    /// CineStager's marker-free ("clean") top-down map, used as the scene-map
    /// background when re-adding this shot to the scene map.
    @Attribute(.externalStorage) var mapCleanData: Data?

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

/// A user-added custom information field on a shot (a labelled text box for now;
/// `kind` leaves room for other field types later). Shown in the Shot Setup card.
@Model
final class ShotCustomInfo {
    var uid: String = UUID().uuidString
    var sortOrder: Int = 0
    /// Field type — "text" or "filmstock"; future kinds reuse this.
    var kind: String = "text"
    var label: String = ""
    var value: String = ""

    // Film-stock calculator (kind == "filmstock").
    var filmGauge: String = "35-4"    // "8" | "16" | "35-2" | "35-3" | "35-4" | "65"
    var filmMode: String = "meters"   // "meters" (→ duration) | "time" (→ length)
    var filmAmount: Double = 0        // meters, or seconds when mode == "time"
    var filmFPS: Double = 25          // capture frame rate

    var shot: Shot?

    init(sortOrder: Int = 0, kind: String = "text", label: String = "", value: String = "") {
        self.sortOrder = sortOrder
        self.kind = kind
        self.label = label
        self.value = value
    }
}

extension ShotCustomInfo {
    /// Preset options for the "time of day" tool; "Custom…" lets the user type.
    static let timeOfDayPresets = ["Dawn", "Twilight", "Sunrise", "Golden hour", "Magic hour",
                                   "Sunny", "Overcast", "Sunset", "Dusk", "Blue hour", "Night"]

    static let filmGauges = ["8", "16", "35-2", "35-3", "35-4", "65"]

    /// Maps a stored gauge to its canonical id (legacy "35" == 35mm 4-perf).
    static func filmCanonicalGauge(_ gauge: String) -> String {
        gauge == "35" ? "35-4" : gauge
    }

    /// Human-readable gauge name, including 35mm perforation count.
    static func filmGaugeLabel(_ gauge: String) -> String {
        switch filmCanonicalGauge(gauge) {
        case "8":    return "Super 8"
        case "16":   return "16mm"
        case "35-2": return "35mm 2-perf"
        case "35-3": return "35mm 3-perf"
        case "35-4": return "35mm 4-perf"
        case "65":   return "65mm"
        default:     return "\(gauge)mm"
        }
    }

    /// Frames per foot. 35mm depends on perfs/frame: 2-perf 32, 3-perf ~21.3,
    /// 4-perf 16 (Super 8 72, 16mm 40, 65mm 5-perf 12.8).
    static func filmFramesPerFoot(_ gauge: String) -> Double {
        switch filmCanonicalGauge(gauge) {
        case "8":    return 72
        case "16":   return 40
        case "35-2": return 32
        case "35-3": return 64.0 / 3.0   // 21.33
        case "35-4": return 16
        case "65":   return 12.8
        default:     return 16
        }
    }

    /// Metres of film consumed per minute for the selected gauge and frame rate.
    var filmMetresPerMinute: Double {
        (filmFPS * 60 / Self.filmFramesPerFoot(filmGauge)) * 0.3048   // frames/min ÷ fr/ft · m/ft
    }

    /// The fps shown compactly (no trailing ".0" for whole rates).
    var filmFPSString: String {
        filmFPS == filmFPS.rounded() ? String(Int(filmFPS)) : String(format: "%g", filmFPS)
    }

    /// "M min S sec" for a duration in seconds.
    static func filmDurationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m) min \(s) sec" : "\(s) sec"
    }

    /// A length in metres without a trailing ".0".
    static func filmMetresString(_ metres: Double) -> String {
        metres == metres.rounded() ? "\(Int(metres)) m" : String(format: "%.1f m", metres)
    }

    /// This tool's film length in metres, whichever way it was entered.
    var filmMetres: Double {
        let mpm = filmMetresPerMinute
        guard mpm > 0 else { return 0 }
        return filmMode == "time" ? mpm * (filmAmount / 60) : filmAmount
    }

    /// This tool's running time in seconds, whichever way it was entered.
    var filmSeconds: Double {
        let mpm = filmMetresPerMinute
        guard mpm > 0 else { return 0 }
        return filmMode == "time" ? filmAmount : filmAmount / mpm * 60
    }

    /// Film-length totals across the given shots, grouped by gauge (metres of
    /// different gauges are different stock, so they're never added together).
    /// Ordered 8→16→35→65; only gauges actually used are included.
    static func filmTotalsByGauge(for shots: [Shot]) -> [(gauge: String, metres: Double, seconds: Double)] {
        var byGauge: [String: (metres: Double, seconds: Double)] = [:]
        for shot in shots {
            for info in shot.customInfo where info.kind == "filmstock" {
                let key = filmCanonicalGauge(info.filmGauge)
                var t = byGauge[key] ?? (0, 0)
                t.metres += info.filmMetres
                t.seconds += info.filmSeconds
                byGauge[key] = t
            }
        }
        return filmGauges.compactMap { g in byGauge[g].map { (g, $0.metres, $0.seconds) } }
    }

    /// The complementary value: a duration when in "meters" mode, a length when
    /// in "time" mode.
    var filmComputedText: String {
        let mpm = filmMetresPerMinute
        guard mpm > 0 else { return "" }
        if filmMode == "time" {
            return Self.filmMetresString(mpm * (filmAmount / 60))
        } else {
            return Self.filmDurationString(filmAmount / mpm * 60)
        }
    }

    /// The label to show, with a sensible default per kind.
    var exportLabel: String {
        switch kind {
        case "filmstock": return "Film length"   // fixed, not user-editable
        case "timeofday": return "Time of day"
        default:
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Custom" : label
        }
    }

    /// The value shown in exports (the computed film-stock summary, or the text).
    var exportValue: String {
        guard kind == "filmstock" else { return value }
        let input = filmMode == "time"
            ? Self.filmDurationString(filmAmount)
            : Self.filmMetresString(filmAmount)
        return "\(Self.filmGaugeLabel(filmGauge)) · \(filmFPSString)fps · \(input) / \(filmComputedText)"
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
    /// Active sensor width (mm) of the format the shot was framed on, when known —
    /// imported from CineStager, which exports it per capture. Drives the exact
    /// scene-map FOV wedge; nil → the Super-35 default is used.
    var sensorWidthMM: Double?
    var extraInfo: String = ""

    // On-set execution state (On-Set Mode): whether the setup is in the can, how
    // many takes were shot, and whether the director circled one. Defaulted so
    // adding them migrates existing projects cleanly (and syncs via CloudKit).
    var isShot: Bool = false
    var takeCount: Int = 0
    var circledTake: Bool = false

    // Auto-filled from metadata. `camera` is the single combined camera value
    // ("Arri Alexa 35 · 4.6K 16:9"); `format` is legacy — its old contents were
    // folded into `camera` by a one-time migration and it's no longer written or
    // shown. Kept so the migration can read it and old archives still decode.
    var camera: String = ""
    var format: String = ""
    var framelines: String = ""
    var lensPreset: String = ""

    /// Joins a camera name and a recording format into the single combined camera
    /// value ("Arri Alexa 35 · 4.6K 16:9"). Either part may be empty.
    static func combinedCamera(_ camera: String, _ format: String) -> String {
        [camera, format]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
    
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

    /// User-added custom info fields (labelled text boxes), shown in Shot Setup.
    @Relationship(deleteRule: .cascade, inverse: \ShotCustomInfo.shot)
    var customInfoStore: [ShotCustomInfo]?
    var customInfo: [ShotCustomInfo] {
        get { customInfoStore ?? [] }
        set { customInfoStore = newValue }
    }
    var orderedCustomInfo: [ShotCustomInfo] {
        customInfo.sorted { $0.sortOrder < $1.sortOrder }
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
    
    var displayNumber: String { formattedNumber(style: numberingStyle) }

    /// A compact "WS · Single · 50mm" line (size · type · focal) for glanceable
    /// lists like On-Set Mode. Empty parts are dropped.
    var shortSpec: String {
        var parts: [String] = []
        if hasSize { parts.append(sizeShort) }
        if hasType { parts.append(typeShort) }
        if lensfocal > 0 { parts.append(lensIsPrime ? "\(lensfocal)mm" : "\(lensfocal)–\(lensfocalEnd)mm") }
        return parts.joined(separator: " · ")
    }

    /// This shot's number rendered in a given style — used both for `displayNumber`
    /// and to preview the other styles in the Edit Shot sheet.
    func formattedNumber(style: ShotNumberingStyle) -> String {
        let sceneNumber = scene?.sceneNumber ?? 0
        let sceneSuffix = scene?.suffix ?? ""

        switch style {
        case .numbers:
            return "\(sceneNumber)\(sceneSuffix).\(shotNumber)\(suffix)"
        case .letters:
            return "\(sceneNumber)\(sceneSuffix).\(numberToLetter(shotNumber))\(suffix)"
        case .continuous:
            return String(format: "%03d", continuousIndex) + suffix
        }
    }

    /// This shot's position (1-based) among all non-archived shots of its script
    /// version, in scene order then shot order. Gives every shot a unique running
    /// number for the `.continuous` numbering style.
    private var continuousIndex: Int {
        let scenes = (scene?.scriptVersion?.scenes ?? scene?.project?.scenes ?? [])
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
        var count = 0
        for s in scenes {
            for sh in s.shots.sorted(by: { $0.shotNumber < $1.shotNumber }) {
                count += 1
                if sh.uid == uid { return count }
            }
        }
        return shotNumber
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
        copy.sensorWidthMM = sensorWidthMM
        copy.extraInfo = extraInfo
        copy.camera = camera
        copy.format = format
        copy.framelines = framelines
        copy.lensPreset = lensPreset

        for reference in orderedReferences {
            let copied = reference.duplicate()
            copied.shot = copy
        }
        for info in orderedCustomInfo {
            let copied = ShotCustomInfo(sortOrder: info.sortOrder, kind: info.kind,
                                        label: info.label, value: info.value)
            copied.filmGauge = info.filmGauge
            copied.filmMode = info.filmMode
            copied.filmAmount = info.filmAmount
            copied.filmFPS = info.filmFPS
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

// MARK: - Scene map ↔ shot links

extension Scene {
    /// Removes any scene-map camera markers linked to the given shot uid.
    /// Called when a shot is deleted so its camera doesn't linger on the map.
    func removeSceneMapMarkers(forShotUID uid: String) {
        var doc = SceneMapDoc.load(from: sceneMapJSON)
        let before = doc.elements.count
        doc.elements.removeAll { $0.shotUID == uid }
        guard doc.elements.count != before else { return }
        let ids = Set(doc.elements.map(\.id))
        doc.arrows.removeAll { !ids.contains($0.fromID) || !ids.contains($0.toID) }
        sceneMapJSON = doc.jsonString
    }

    /// Wipes the whole scene map — markers, arrows, drawn floor plan, and the
    /// background image (and its location tag). Mirrors the map editor's "Clear
    /// Map", but works directly on the model so callers outside the editor (e.g.
    /// "Clear Scene") can use it.
    func clearSceneMap() {
        sceneMapJSON = nil
        sceneFloorPlanJSON = nil
        sceneMapBackgroundData = nil
        sceneMapBackgroundIsSatellite = false
        sceneMapMetersWide = nil
        sceneMapCameraSizeMeters = nil
        sceneMapLocation = nil
    }
}

// MARK: - Shooting schedule

/// One shooting day in a version's schedule. Holds an ordered list of scene
/// "strips" (`ScheduleEntry`). A scene can appear on more than one day (splitting
/// a scene across days) — that's just multiple entries referencing it.
@Model
final class ShootingDay {
    var uid: String = UUID().uuidString
    /// Day order in the schedule (Day 1, 2, 3 …).
    var sortOrder: Int = 0
    /// Optional shoot date assigned to this day.
    var date: Date?
    var notes: String = ""

    var scriptVersion: ScriptVersion?

    @Relationship(deleteRule: .cascade, inverse: \ScheduleEntry.day)
    var entriesStore: [ScheduleEntry]?
    var entries: [ScheduleEntry] {
        get { entriesStore ?? [] }
        set { entriesStore = newValue }
    }

    init(sortOrder: Int, date: Date? = nil) {
        self.sortOrder = sortOrder
        self.date = date
    }

    /// Entries in shoot order, skipping any whose scene was deleted underneath us.
    var orderedEntries: [ScheduleEntry] {
        entries.filter { $0.scene != nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// "Day N", with the assigned date appended when set.
    var displayTitle: String {
        let base = "Day \(sortOrder + 1)"
        guard let date else { return base }
        let df = DateFormatter(); df.dateStyle = .medium
        return "\(base) · \(df.string(from: date))"
    }
}

/// One occurrence of a scene on a shooting day — a schedule "strip". Splitting a
/// scene across days means the scene has several of these on different days; the
/// `note` labels each part ("pt. 1 of 2", "MOS", "pickups", …).
@Model
final class ScheduleEntry {
    var uid: String = UUID().uuidString
    /// Order within the day.
    var sortOrder: Int = 0
    /// Optional label for this strip (e.g. which part of a split scene).
    var note: String = ""
    /// Which of the scene's shots are shot on this day, by Shot.uid. Empty means the
    /// whole scene (all shots) — the default, so existing strips keep meaning "all".
    var selectedShotUIDs: [String] = []
    /// The order the day's shots are filmed in, by Shot.uid — a per-day shoot order
    /// that's separate from the scene's shot-list order and numbering. Empty means the
    /// scene's own order; shots not listed here (e.g. added later) keep scene order.
    var shotShootOrderUIDs: [String] = []

    var scene: Scene?
    var day: ShootingDay?

    init(scene: Scene, sortOrder: Int, note: String = "") {
        self.scene = scene
        self.sortOrder = sortOrder
        self.note = note
    }

    /// The shots this strip covers, in this day's shoot order. `selectedShotUIDs`
    /// chooses which shots (empty = the whole scene); `shotShootOrderUIDs` then sets
    /// the film order (empty = scene order). Neither touches shot numbering. Shots
    /// added after an order was set keep scene order at the end. Deleted shots drop.
    var resolvedShots: [Shot] {
        guard let scene else { return [] }
        let ordered = scene.orderedShots
        let onDay: [Shot]
        if selectedShotUIDs.isEmpty {
            onDay = ordered
        } else {
            let set = Set(selectedShotUIDs)
            onDay = ordered.filter { set.contains($0.uid) }
        }
        guard !shotShootOrderUIDs.isEmpty else { return onDay }
        let rank = Dictionary(uniqueKeysWithValues: shotShootOrderUIDs.enumerated().map { ($0.element, $0.offset) })
        return onDay.enumerated()
            .sorted { (rank[$0.element.uid] ?? Int.max, $0.offset) < (rank[$1.element.uid] ?? Int.max, $1.offset) }
            .map { $0.element }
    }

    /// True when this strip is a subset (not the whole scene).
    var isPartialScene: Bool {
        guard let scene else { return false }
        return !selectedShotUIDs.isEmpty && selectedShotUIDs.count < scene.shots.count
    }
}

/// Derived read-outs for a shooting day: load totals and daylight times. Shared by
/// the in-app board and the web export so both show the same numbers.
enum ScheduleSummary {
    /// Setups (scenes) and shots planned on the day.
    static func totals(for day: ShootingDay) -> (setups: Int, shots: Int) {
        let entries = day.orderedEntries
        return (entries.count, entries.reduce(0) { $0 + $1.resolvedShots.count })
    }

    /// The first scheduled scene on the day that carries a sun location, used as the
    /// day's representative location for daylight times.
    static func representativeSun(for day: ShootingDay) -> SunSettings? {
        for entry in day.orderedEntries {
            if let s = entry.scene?.sunSettings, s.hasLocation { return s }
        }
        return nil
    }

    /// Daylight for the day at its representative location, or nil when the day has
    /// no date or no located scene (or the sun never rises/sets there that day).
    static func daylight(for day: ShootingDay) -> (light: SolarPosition.DayLight, timeZone: TimeZone, date: Date)? {
        guard let date = day.date, let sun = representativeSun(for: day),
              let lat = sun.latitude, let lon = sun.longitude,
              let dl = SolarPosition.dayLight(date: date, latitude: lat, longitude: lon, timeZone: sun.timeZone)
        else { return nil }
        return (dl, sun.timeZone, date)
    }

    /// "H:mm" for `minutes` since local midnight, in `timeZone`.
    static func clock(_ minutes: Int, on date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let instant = cal.startOfDay(for: date).addingTimeInterval(Double(minutes) * 60)
        let f = DateFormatter(); f.timeZone = timeZone; f.dateFormat = "H:mm"
        return f.string(from: instant)
    }

    /// Formatted daylight times for a day, ready to show as tags.
    struct DaylightTimes {
        let sunrise: String       // "6:12"
        let sunset: String        // "20:39"
        let goldenMorning: String // "6:12–6:48"
        let goldenEvening: String // "20:03–20:39"
    }

    /// Daylight times for a day, or nil when unavailable.
    static func daylightTimes(for day: ShootingDay) -> DaylightTimes? {
        guard let (dl, tz, date) = daylight(for: day) else { return nil }
        func t(_ m: Int) -> String { clock(m, on: date, timeZone: tz) }
        return DaylightTimes(
            sunrise: t(dl.sunrise),
            sunset: t(dl.sunset),
            goldenMorning: "\(t(dl.sunrise))–\(t(dl.goldenMorningEnd))",
            goldenEvening: "\(t(dl.goldenEveningStart))–\(t(dl.sunset))")
    }
}
