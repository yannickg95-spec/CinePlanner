//
//  ProjectArchive.swift
//  CinePlanner
//
//  Exports a single project — its whole graph plus its media — to one portable
//  `.cineplan` file, and imports one back. The archive is JSON: Data blobs are
//  base64-encoded by JSONEncoder, so the media travels inside the file and the
//  result opens on any machine. Import rebuilds the object graph with fresh uids.
//

import Foundation
import SwiftData

enum ProjectArchive {

    static let fileExtension = "cineplan"
    private static let currentFormat = 1

    // MARK: - Codable snapshot (canonical, post-migration shape)

    private struct Doc: Codable {
        var format: Int
        var exportedAt: Date
        var appVersion: String?
        var project: ProjectDTO
    }

    private struct ProjectDTO: Codable {
        var filmName: String
        var createdDate: Date
        var isSeries: Bool
        var scriptPDFPageOffset: Int
        var scriptSplitFraction: Double
        var episodes: [EpisodeDTO]
        var autoAddFilmTool: Bool?
        var scriptCharactersJSON: String?
        // Optional so archives written before they were carried still decode.
        var productionCompany: String?
        var director: String?
        var cinematographer: String?
        var coveragePalette: String?
        var coverageColorMode: String?
        var shotSetupFieldOrder: String?
        var hiddenShotSetupFields: String?
        var defaultCamera: String?
        var defaultFramelines: String?
        var defaultLens: String?
    }

    private struct EpisodeDTO: Codable {
        var episodeNumber: Int
        var title: String
        var createdDate: Date
        var versions: [VersionDTO]
        var director: String?
        var cinematographer: String?
    }

    private struct VersionDTO: Codable {
        var versionNumber: Int
        var name: String
        var createdDate: Date
        var pdfData: Data?
        var pdfPageOffset: Int
        var coverageLineMargin: Double?
        var scenes: [SceneDTO]
        var coverageLinesOnRight: Bool?
        var shootingDays: [DayDTO]?
    }

    /// A shooting day. Its strips point at scenes and shots by their uid in the
    /// archive, which import maps onto the freshly created objects.
    private struct DayDTO: Codable {
        var sortOrder: Int
        var date: Date?
        var notes: String
        var entries: [EntryDTO]
    }

    private struct EntryDTO: Codable {
        var sortOrder: Int
        var note: String
        var sceneUID: String?
        var selectedShotUIDs: [String]
        var shotShootOrderUIDs: [String]
    }

    private struct SceneDTO: Codable {
        var sceneNumber: Int
        var sortOrder: Int
        var isDay: Bool
        var isInterior: Bool
        var nickname: String
        var suffix: String
        var isArchived: Bool
        var scriptPageNumber: Int
        var scriptLineNumber: Int
        var scriptTimeOfDay: String
        var manualAnnotationY: Double
        var pdfPageOffset: Int
        var sceneMapJSON: String?
        var sceneMapBackgroundData: Data?
        var sceneMapLocation: String?
        var sceneMapBackgroundIsSatellite: Bool?
        var sceneMapSatelliteLat: Double?
        var sceneMapSatelliteLon: Double?
        var sceneMapSatelliteMeters: Double?
        /// Optional so archives written before the map could be turned still decode;
        /// absent means north-up, which is what those maps were.
        var sceneMapSatelliteHeading: Double?
        var sceneMapSatelliteCalibrated: Bool?
        var sceneMapMetersWide: Double?
        var sceneMapCameraSizeMeters: Double?
        // Optional so archives written before background alignment existed still
        // decode; missing → identity placement on import.
        var sceneMapBackgroundScale: Double?
        var sceneMapBackgroundOffsetX: Double?
        var sceneMapBackgroundOffsetY: Double?
        var sceneMapBackgroundRotation: Double?
        var sceneMapShowCameraFOV: Bool?
        var sceneMapViewableMarkerSize: Bool?
        var sceneFloorPlanJSON: String?
        var sceneCharactersJSON: String?
        var sunSettingsJSON: String?
        var shots: [ShotDTO]
        /// The scene's uid at export — only to resolve references (schedule strips,
        /// coverage aliases); import gives the scene a fresh one.
        var uid: String?
        var sceneMapImportedMetersWide: Double?
        var sceneFilmToolEnabled: Bool?
        var sceneFilmGauge: String?
        var sceneFilmFPS: Double?
        var sceneFilmMode: String?
    }

    private struct ShotDTO: Codable {
        var shotNumber: Int
        var shotInformation: String
        var numberingStyle: String
        var sizeName: String
        var secondSizeName: String
        var typeName: String
        var secondTypeName: String
        var thirdTypeName: String
        var gripName: String
        var suffix: String
        var nickname: String
        var lensIsPrime: Bool
        var lensfocal: Int
        var lensfocalEnd: Int
        var sensorWidthMM: Double?
        var extraInfo: String
        var camera: String
        var format: String
        var framelines: String
        var lensPreset: String
        var scriptCoverageSelections: [ScriptTextSelection]?
        var references: [ReferenceDTO]
        var customInfo: [CustomInfoDTO]?
        /// The shot's uid at export — only to resolve schedule references.
        var uid: String?
        // On-set state.
        var isShot: Bool?
        var takeCount: Int?
        var circledTake: Bool?
        /// Archive uids of other scenes this shot's coverage runs into.
        var coverageSceneUIDs: [String]?
    }

    private struct CustomInfoDTO: Codable {
        var sortOrder: Int
        var kind: String
        var label: String
        var value: String
        var filmGauge: String?
        var filmMode: String?
        var filmAmount: Double?
        var filmFPS: Double?
    }

    private struct ReferenceDTO: Codable {
        var sortOrder: Int
        var imageData: Data?
        var videoData: Data?
        var videoExtension: String?
        var mapData: Data?
        var mapVideoData: Data?
        var mapVideoExtension: String?
        var note: String?
        // Image EXIF
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
        // Map metadata
        var mapCaptureID: String?
        var mapCameraPhysicalWidth: Double?
        var mapCameraPhysicalLength: Double?
        var mapLocationModel: String?
        var mapLocationWidth: Double?
        var mapLocationLength: Double?
        var mapLocationHeight: Double?
        /// The marker-free CineStager map, kept for re-adding markers later.
        var mapCleanData: Data?
    }

    // MARK: - Export

    /// The `.cineplan` bytes for a project. Migrates the project to its current
    /// shape first, so legacy photo/video slots are captured as references.
    @MainActor
    static func data(for project: Project) throws -> Data {
        project.migrateStructureIfNeeded()

        let episodes = project.orderedEpisodes.map { episode in
            EpisodeDTO(
                episodeNumber: episode.episodeNumber,
                title: episode.title,
                createdDate: episode.createdDate,
                versions: episode.orderedVersions.map(versionDTO),
                director: episode.director,
                cinematographer: episode.cinematographer
            )
        }
        let dto = ProjectDTO(
            filmName: project.filmName,
            createdDate: project.createdDate,
            isSeries: project.isSeries,
            scriptPDFPageOffset: project.scriptPDFPageOffset,
            scriptSplitFraction: project.scriptSplitFraction,
            episodes: episodes,
            autoAddFilmTool: project.autoAddFilmTool,
            scriptCharactersJSON: project.scriptCharactersJSON,
            productionCompany: project.productionCompany,
            director: project.director,
            cinematographer: project.cinematographer,
            coveragePalette: project.coveragePaletteRaw,
            coverageColorMode: project.coverageColorModeRaw,
            shotSetupFieldOrder: project.shotSetupFieldOrderRaw,
            hiddenShotSetupFields: project.hiddenShotSetupFieldsRaw,
            defaultCamera: project.defaultCamera,
            defaultFramelines: project.defaultFramelines,
            defaultLens: project.defaultLens
        )
        let doc = Doc(
            format: currentFormat,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            project: dto
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    private static func versionDTO(_ version: ScriptVersion) -> VersionDTO {
        VersionDTO(
            versionNumber: version.versionNumber,
            name: version.name,
            createdDate: version.createdDate,
            pdfData: version.pdfData,
            pdfPageOffset: version.pdfPageOffset,
            coverageLineMargin: version.coverageLineMargin,
            scenes: version.orderedScenes.map(sceneDTO),
            coverageLinesOnRight: version.coverageLinesOnRight,
            shootingDays: version.orderedShootingDays.map { day in
                DayDTO(sortOrder: day.sortOrder, date: day.date, notes: day.notes,
                       entries: day.orderedEntries.map { entry in
                           EntryDTO(sortOrder: entry.sortOrder, note: entry.note,
                                    sceneUID: entry.scene?.uid,
                                    selectedShotUIDs: entry.selectedShotUIDs,
                                    shotShootOrderUIDs: entry.shotShootOrderUIDs)
                       })
            }
        )
    }

    private static func sceneDTO(_ scene: Scene) -> SceneDTO {
        SceneDTO(
            sceneNumber: scene.sceneNumber,
            sortOrder: scene.sortOrder,
            isDay: scene.isDay,
            isInterior: scene.isInterior,
            nickname: scene.nickname,
            suffix: scene.suffix,
            isArchived: scene.isArchived,
            scriptPageNumber: scene.scriptPageNumber,
            scriptLineNumber: scene.scriptLineNumber,
            scriptTimeOfDay: scene.scriptTimeOfDay,
            manualAnnotationY: scene.manualAnnotationY,
            pdfPageOffset: scene.pdfPageOffset,
            sceneMapJSON: scene.sceneMapJSON,
            sceneMapBackgroundData: scene.sceneMapBackgroundData,
            sceneMapLocation: scene.sceneMapLocation,
            sceneMapBackgroundIsSatellite: scene.sceneMapBackgroundIsSatellite,
            sceneMapSatelliteLat: scene.sceneMapSatelliteLat,
            sceneMapSatelliteLon: scene.sceneMapSatelliteLon,
            sceneMapSatelliteMeters: scene.sceneMapSatelliteMeters,
            sceneMapSatelliteHeading: scene.sceneMapSatelliteHeading,
            sceneMapSatelliteCalibrated: scene.sceneMapSatelliteCalibrated,
            sceneMapMetersWide: scene.sceneMapMetersWide,
            sceneMapCameraSizeMeters: scene.sceneMapCameraSizeMeters,
            sceneMapBackgroundScale: scene.sceneMapBackgroundScale,
            sceneMapBackgroundOffsetX: scene.sceneMapBackgroundOffsetX,
            sceneMapBackgroundOffsetY: scene.sceneMapBackgroundOffsetY,
            sceneMapBackgroundRotation: scene.sceneMapBackgroundRotation,
            sceneMapShowCameraFOV: scene.sceneMapShowCameraFOV,
            sceneMapViewableMarkerSize: scene.sceneMapViewableMarkerSize,
            sceneFloorPlanJSON: scene.sceneFloorPlanJSON,
            sceneCharactersJSON: scene.sceneCharactersJSON,
            sunSettingsJSON: scene.sunSettingsJSON,
            shots: scene.shots.sorted { $0.shotNumber < $1.shotNumber }.map(shotDTO),
            uid: scene.uid,
            sceneMapImportedMetersWide: scene.sceneMapImportedMetersWide,
            sceneFilmToolEnabled: scene.sceneFilmToolEnabled,
            sceneFilmGauge: scene.sceneFilmGauge,
            sceneFilmFPS: scene.sceneFilmFPS,
            sceneFilmMode: scene.sceneFilmMode
        )
    }

    private static func shotDTO(_ shot: Shot) -> ShotDTO {
        shot.migrateReferencesIfNeeded()
        return ShotDTO(
            shotNumber: shot.shotNumber,
            shotInformation: shot.shotInformation,
            numberingStyle: shot.numberingStyle.rawValue,
            sizeName: shot.sizeName,
            secondSizeName: shot.secondSizeName,
            typeName: shot.typeName,
            secondTypeName: shot.secondTypeName,
            thirdTypeName: shot.thirdTypeName,
            gripName: shot.gripName,
            suffix: shot.suffix,
            nickname: shot.nickname,
            lensIsPrime: shot.lensIsPrime,
            lensfocal: shot.lensfocal,
            lensfocalEnd: shot.lensfocalEnd,
            sensorWidthMM: shot.sensorWidthMM,
            extraInfo: shot.extraInfo,
            camera: shot.camera,
            format: shot.format,
            framelines: shot.framelines,
            lensPreset: shot.lensPreset,
            scriptCoverageSelections: shot.scriptCoverageSelections,
            references: shot.orderedReferences.map(referenceDTO),
            customInfo: shot.orderedCustomInfo.map {
                CustomInfoDTO(sortOrder: $0.sortOrder, kind: $0.kind, label: $0.label, value: $0.value,
                              filmGauge: $0.filmGauge, filmMode: $0.filmMode, filmAmount: $0.filmAmount,
                              filmFPS: $0.filmFPS)
            },
            uid: shot.uid,
            isShot: shot.isShot,
            takeCount: shot.takeCount,
            circledTake: shot.circledTake,
            coverageSceneUIDs: shot.coverageSceneUIDs
        )
    }

    private static func referenceDTO(_ r: ShotReference) -> ReferenceDTO {
        ReferenceDTO(
            sortOrder: r.sortOrder,
            imageData: r.imageData, videoData: r.videoData, videoExtension: r.videoExtension, mapData: r.mapData,
            mapVideoData: r.mapVideoData, mapVideoExtension: r.mapVideoExtension,
            note: r.note,
            cameraFamily: r.cameraFamily, cameraFormat: r.cameraFormat, focalLength: r.focalLength,
            lensPreset: r.lensPreset, horizon: r.horizon, tilt: r.tilt, height: r.height,
            captureID: r.captureID, captureType: r.captureType, dateTimeOriginal: r.dateTimeOriginal,
            keywords: r.keywords, caption: r.caption, framelines: r.framelines, software: r.software,
            mapCaptureID: r.mapCaptureID, mapCameraPhysicalWidth: r.mapCameraPhysicalWidth,
            mapCameraPhysicalLength: r.mapCameraPhysicalLength, mapLocationModel: r.mapLocationModel,
            mapLocationWidth: r.mapLocationWidth, mapLocationLength: r.mapLocationLength,
            mapLocationHeight: r.mapLocationHeight,
            mapCleanData: r.mapCleanData
        )
    }

    /// A safe default filename for a project's archive.
    static func suggestedFileName(for project: Project) -> String {
        let base = project.filmName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = base.isEmpty ? "Project" : base
        return "\(safe).\(fileExtension)"
    }

    // MARK: - Import

    /// Rebuilds a project from archive bytes and inserts it into `context`.
    /// Every object gets a fresh uid (from its initializer), so an imported copy
    /// never collides with an existing one. The caller saves the context.
    @MainActor
    @discardableResult
    static func importProject(from data: Data, into context: ModelContext) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(Doc.self, from: data)
        let p = doc.project

        let project = Project(filmName: p.filmName, isSeries: p.isSeries, createdDate: p.createdDate)
        project.scriptPDFPageOffset = p.scriptPDFPageOffset
        project.scriptSplitFraction = p.scriptSplitFraction
        project.autoAddFilmTool = p.autoAddFilmTool ?? false
        project.scriptCharactersJSON = p.scriptCharactersJSON
        project.productionCompany = p.productionCompany ?? ""
        project.director = p.director ?? ""
        project.cinematographer = p.cinematographer ?? ""
        if let v = p.coveragePalette { project.coveragePaletteRaw = v }
        if let v = p.coverageColorMode { project.coverageColorModeRaw = v }
        project.shotSetupFieldOrderRaw = p.shotSetupFieldOrder ?? ""
        project.hiddenShotSetupFieldsRaw = p.hiddenShotSetupFields ?? ""
        project.defaultCamera = p.defaultCamera ?? ""
        project.defaultFramelines = p.defaultFramelines ?? ""
        project.defaultLens = p.defaultLens ?? ""
        context.insert(project)

        // Archive uid → the freshly created object's uid, to re-point references.
        var sceneUIDs: [String: String] = [:]
        var shotUIDs: [String: String] = [:]
        // Coverage aliases are resolved once every scene exists.
        var pendingCoverage: [(shot: Shot, archiveUIDs: [String])] = []

        for e in p.episodes {
            let episode = Episode(episodeNumber: e.episodeNumber, title: e.title, createdDate: e.createdDate)
            episode.project = project
            episode.director = e.director ?? ""
            episode.cinematographer = e.cinematographer ?? ""

            for v in e.versions {
                let version = ScriptVersion(versionNumber: v.versionNumber, name: v.name, createdDate: v.createdDate)
                version.episode = episode
                version.pdfData = v.pdfData
                version.pdfPageOffset = v.pdfPageOffset
                version.coverageLineMargin = v.coverageLineMargin ?? 0.15
                version.coverageLinesOnRight = v.coverageLinesOnRight ?? false
                var scenesByArchiveUID: [String: Scene] = [:]

                for s in v.scenes {
                    let scene = Scene(sceneNumber: s.sceneNumber)
                    // Set both, like normal scene creation: the version owns it for
                    // the editor, the project owns it for the project-card counts.
                    scene.scriptVersion = version
                    scene.project = project
                    scene.sortOrder = s.sortOrder
                    scene.isDay = s.isDay
                    scene.isInterior = s.isInterior
                    scene.nickname = s.nickname
                    scene.suffix = s.suffix
                    scene.isArchived = s.isArchived
                    scene.scriptPageNumber = s.scriptPageNumber
                    scene.scriptLineNumber = s.scriptLineNumber
                    scene.scriptTimeOfDay = s.scriptTimeOfDay
                    scene.manualAnnotationY = s.manualAnnotationY
                    scene.pdfPageOffset = s.pdfPageOffset
                    scene.sceneMapJSON = s.sceneMapJSON
                    scene.sceneMapBackgroundData = s.sceneMapBackgroundData
                    scene.sceneMapLocation = s.sceneMapLocation
                    scene.sceneMapBackgroundIsSatellite = s.sceneMapBackgroundIsSatellite ?? false
                    scene.sceneMapSatelliteLat = s.sceneMapSatelliteLat
                    scene.sceneMapSatelliteLon = s.sceneMapSatelliteLon
                    scene.sceneMapSatelliteMeters = s.sceneMapSatelliteMeters
                    scene.sceneMapSatelliteHeading = s.sceneMapSatelliteHeading ?? 0
                    scene.sceneMapSatelliteCalibrated = s.sceneMapSatelliteCalibrated ?? false
                    scene.sceneMapMetersWide = s.sceneMapMetersWide
                    scene.sceneMapCameraSizeMeters = s.sceneMapCameraSizeMeters
                    scene.sceneMapBackgroundScale = s.sceneMapBackgroundScale ?? 1
                    scene.sceneMapBackgroundOffsetX = s.sceneMapBackgroundOffsetX ?? 0
                    scene.sceneMapBackgroundOffsetY = s.sceneMapBackgroundOffsetY ?? 0
                    scene.sceneMapBackgroundRotation = s.sceneMapBackgroundRotation ?? 0
                    scene.sceneMapShowCameraFOV = s.sceneMapShowCameraFOV ?? false
                    scene.sceneMapViewableMarkerSize = s.sceneMapViewableMarkerSize ?? false
                    scene.sceneFloorPlanJSON = s.sceneFloorPlanJSON
                    scene.sceneCharactersJSON = s.sceneCharactersJSON
                    scene.sunSettingsJSON = s.sunSettingsJSON
                    scene.sceneMapImportedMetersWide = s.sceneMapImportedMetersWide
                    scene.sceneFilmToolEnabled = s.sceneFilmToolEnabled ?? false
                    if let v = s.sceneFilmGauge { scene.sceneFilmGauge = v }
                    if let v = s.sceneFilmFPS { scene.sceneFilmFPS = v }
                    if let v = s.sceneFilmMode { scene.sceneFilmMode = v }
                    if let old = s.uid {
                        sceneUIDs[old] = scene.uid
                        scenesByArchiveUID[old] = scene
                    }

                    for sh in s.shots {
                        let shot = Shot(shotNumber: sh.shotNumber, shotInformation: sh.shotInformation)
                        shot.scene = scene
                        shot.numberingStyle = ShotNumberingStyle(rawValue: sh.numberingStyle) ?? .numbers
                        shot.sizeName = sh.sizeName
                        shot.secondSizeName = sh.secondSizeName
                        shot.typeName = sh.typeName
                        shot.secondTypeName = sh.secondTypeName
                        shot.thirdTypeName = sh.thirdTypeName
                        shot.gripName = sh.gripName
                        shot.suffix = sh.suffix
                        shot.nickname = sh.nickname
                        shot.lensIsPrime = sh.lensIsPrime
                        shot.lensfocal = sh.lensfocal
                        shot.lensfocalEnd = sh.lensfocalEnd
                        shot.sensorWidthMM = sh.sensorWidthMM
                        shot.extraInfo = sh.extraInfo
                        // Camera + format are now one combined value; fold any
                        // legacy split format from older archives into it.
                        shot.camera = Shot.combinedCamera(sh.camera, sh.format)
                        shot.framelines = sh.framelines
                        shot.lensPreset = sh.lensPreset
                        shot.scriptCoverageSelections = sh.scriptCoverageSelections
                        shot.isShot = sh.isShot ?? false
                        shot.takeCount = sh.takeCount ?? 0
                        shot.circledTake = sh.circledTake ?? false
                        if let old = sh.uid { shotUIDs[old] = shot.uid }
                        if let aliases = sh.coverageSceneUIDs, !aliases.isEmpty {
                            pendingCoverage.append((shot, aliases))
                        }

                        for r in sh.references {
                            let ref = ShotReference(sortOrder: r.sortOrder)
                            ref.shot = shot
                            ref.imageData = r.imageData
                            ref.videoData = r.videoData
                            ref.videoExtension = r.videoExtension
                            ref.mapData = r.mapData
                            ref.mapVideoData = r.mapVideoData
                            ref.mapVideoExtension = r.mapVideoExtension
                            ref.note = r.note
                            ref.cameraFamily = r.cameraFamily
                            ref.cameraFormat = r.cameraFormat
                            ref.focalLength = r.focalLength
                            ref.lensPreset = r.lensPreset
                            ref.horizon = r.horizon
                            ref.tilt = r.tilt
                            ref.height = r.height
                            ref.captureID = r.captureID
                            ref.captureType = r.captureType
                            ref.dateTimeOriginal = r.dateTimeOriginal
                            ref.keywords = r.keywords
                            ref.caption = r.caption
                            ref.framelines = r.framelines
                            ref.software = r.software
                            ref.mapCaptureID = r.mapCaptureID
                            ref.mapCameraPhysicalWidth = r.mapCameraPhysicalWidth
                            ref.mapCameraPhysicalLength = r.mapCameraPhysicalLength
                            ref.mapLocationModel = r.mapLocationModel
                            ref.mapLocationWidth = r.mapLocationWidth
                            ref.mapLocationLength = r.mapLocationLength
                            ref.mapLocationHeight = r.mapLocationHeight
                            ref.mapCleanData = r.mapCleanData
                        }

                        for c in sh.customInfo ?? [] {
                            let info = ShotCustomInfo(sortOrder: c.sortOrder, kind: c.kind,
                                                      label: c.label, value: c.value)
                            info.filmGauge = c.filmGauge ?? "35"
                            info.filmMode = c.filmMode ?? "meters"
                            info.filmAmount = c.filmAmount ?? 0
                            info.filmFPS = c.filmFPS ?? 25
                            info.shot = shot
                        }
                    }

                    // Camera markers are tied to their shot by uid, and the shots just
                    // got new ones. Re-point them, or opening the map would treat them
                    // as orphans and remove them. An archive from before shots carried
                    // their uid can't be matched: those markers are kept as free
                    // cameras (label intact) rather than lost.
                    if let json = scene.sceneMapJSON {
                        var doc = SceneMapDoc.load(from: json)
                        var changed = false
                        for i in doc.elements.indices {
                            guard let old = doc.elements[i].shotUID else { continue }
                            doc.elements[i].shotUID = shotUIDs[old]
                            changed = true
                        }
                        if changed { scene.sceneMapJSON = doc.jsonString }
                    }
                }

                // The schedule, its strips re-pointed at the new scenes and shots.
                for d in v.shootingDays ?? [] {
                    let day = ShootingDay(sortOrder: d.sortOrder, date: d.date)
                    day.notes = d.notes
                    day.scriptVersion = version
                    for en in d.entries {
                        guard let old = en.sceneUID, let scene = scenesByArchiveUID[old] else { continue }
                        let entry = ScheduleEntry(scene: scene, sortOrder: en.sortOrder, note: en.note)
                        entry.selectedShotUIDs = en.selectedShotUIDs.compactMap { shotUIDs[$0] }
                        entry.shotShootOrderUIDs = en.shotShootOrderUIDs.compactMap { shotUIDs[$0] }
                        entry.day = day
                    }
                }
            }
        }

        for (shot, aliases) in pendingCoverage {
            let mapped = aliases.compactMap { sceneUIDs[$0] }
            shot.coverageSceneUIDs = mapped.isEmpty ? nil : mapped
        }

        return project
    }
}
