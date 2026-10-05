//
//  ProjectRecords.swift
//  CinePlanner
//
//  How a project travels as CloudKit records, for project sharing: one record per
//  object, named by its uid, holding its fields, its parents by uid, and its media
//  as assets. A shared project syncs this way (the shared projects' own engine),
//  and moving a project between the regular store and the shared one goes through
//  it too, so there's one description of a project's data, not two.
//
//  Every stored attribute of every model is either carried here or listed as not
//  synced, with the reason — RecordSchemaTests checks that against the live schema,
//  so a field added to a model can't silently stay behind.
//

import Foundation
import CloudKit
import SwiftData

/// A model that travels as a record: it has a stable uid, its record name.
protocol SyncedModel: PersistentModel {
    var uid: String { get set }
}

extension Project: SyncedModel {}
extension Episode: SyncedModel {}
extension ScriptVersion: SyncedModel {}
extension Scene: SyncedModel {}
extension Shot: SyncedModel {}
extension ShotReference: SyncedModel {}
extension ShotCustomInfo: SyncedModel {}
extension ShootingDay: SyncedModel {}
extension ScheduleEntry: SyncedModel {}

// MARK: - Fields

/// One attribute of a model in a record: how to write it in, and read it back.
/// Reading only assigns a value that differs, so applying a record leaves unchanged
/// fields alone (and out of the store's history).
struct RecordField<Model: SyncedModel> {
    let key: String
    let write: (Model, CKRecord) -> Void
    let read: (CKRecord, Model) -> Void

    /// A plain value: text, number, true/false, date, list of strings.
    static func value<V: CKRecordValueProtocol & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Model, V>) -> Self {
        Self(key: key,
             write: { model, record in record[key] = model[keyPath: path] },
             read: { record, model in
                 guard let value = record[key] as? V, model[keyPath: path] != value else { return }
                 model[keyPath: path] = value
             })
    }

    /// An optional plain value; a missing field means nil.
    static func value<V: CKRecordValueProtocol & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Model, V?>) -> Self {
        Self(key: key,
             write: { model, record in record[key] = model[keyPath: path] },
             read: { record, model in
                 let value = record[key] as? V
                 if model[keyPath: path] != value { model[keyPath: path] = value }
             })
    }

    /// Media and PDFs, as an asset (records themselves are limited to 1 MB).
    static func asset(_ key: String, _ path: ReferenceWritableKeyPath<Model, Data?>) -> Self {
        Self(key: key,
             write: { model, record in
                 record[key] = model[keyPath: path].flatMap { RecordAssets.asset(for: $0) }
             },
             read: { record, model in
                 let data = (record[key] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
                 if model[keyPath: path] != data { model[keyPath: path] = data }
             })
    }

    /// A structured value, as JSON text.
    static func json<V: Codable>(_ key: String, _ path: ReferenceWritableKeyPath<Model, V?>) -> Self {
        Self(key: key,
             write: { model, record in record[key] = jsonText(model[keyPath: path]) },
             read: { record, model in
                 let text = record[key] as? String
                 let current = jsonText(model[keyPath: path])
                 guard text != current else { return }
                 model[keyPath: path] = text.flatMap { $0.data(using: .utf8) }
                     .flatMap { try? JSONDecoder().decode(V.self, from: $0) }
             })
    }
}

/// JSON with its keys in a fixed order, so the same value always gives the same
/// text (and an unchanged value is recognised as unchanged).
private func jsonText<V: Encodable>(_ value: V?) -> String? {
    guard let value else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
}

/// A to-one relationship, as the parent's uid.
struct ParentLink<Model: SyncedModel> {
    let key: String
    let write: (Model, CKRecord) -> Void
    let read: (CKRecord, Model, RecordResolver) -> Void

    static func parent<P: SyncedModel>(_ key: String, _ path: ReferenceWritableKeyPath<Model, P?>) -> Self {
        Self(key: key,
             write: { model, record in record[key] = model[keyPath: path]?.uid },
             read: { record, model, resolver in
                 let uid = record[key] as? String
                 guard model[keyPath: path]?.uid != uid else { return }
                 guard let uid else { model[keyPath: path] = nil; return }
                 // A parent that hasn't arrived yet stays unlinked until it does.
                 if let parent = resolver.object(P.self, uid: uid) { model[keyPath: path] = parent }
                 else { resolver.unresolved += 1 }
             })
    }
}

// MARK: - Schemas

/// How one model type travels: its record type, fields and parents, and the
/// attributes deliberately left out.
struct RecordSchema<Model: SyncedModel> {
    let recordType: String
    let make: () -> Model
    let fetch: (ModelContext, String) -> Model?
    let fields: [RecordField<Model>]
    let parents: [ParentLink<Model>]
    let notSynced: [String: String]
}

/// A record schema without its model type, for the registry.
protocol AnyRecordSchema {
    var recordType: String { get }
    var modelType: any SyncedModel.Type { get }
    var syncedKeys: Set<String> { get }
    var parentKeys: Set<String> { get }
    var notSyncedKeys: Set<String> { get }
    func fill(_ record: CKRecord, from object: any SyncedModel, only keys: Set<String>?)
    func upsert(_ record: CKRecord, resolver: RecordResolver, skipping: Set<String>) -> any SyncedModel
    func link(_ record: CKRecord, resolver: RecordResolver, skipping: Set<String>)
    func delete(uid: String, in context: ModelContext)
    func find(uid: String, in context: ModelContext) -> (any SyncedModel)?
}

extension RecordSchema: AnyRecordSchema {
    var modelType: any SyncedModel.Type { Model.self }
    var syncedKeys: Set<String> { Set(fields.map(\.key)) }
    var parentKeys: Set<String> { Set(parents.map(\.key)) }
    var notSyncedKeys: Set<String> { Set(notSynced.keys) }

    func fill(_ record: CKRecord, from object: any SyncedModel, only keys: Set<String>?) {
        guard let model = object as? Model else { return }
        for field in fields where keys?.contains(field.key) ?? true { field.write(model, record) }
        for parent in parents where keys?.contains(parent.key) ?? true { parent.write(model, record) }
    }

    func upsert(_ record: CKRecord, resolver: RecordResolver, skipping: Set<String>) -> any SyncedModel {
        let uid = record.recordID.recordName
        let model: Model
        if let existing = resolver.object(Model.self, uid: uid) {
            model = existing
        } else {
            model = make()
            model.uid = uid
            resolver.context.insert(model)
            resolver.remember(model)
        }
        for field in fields where !skipping.contains(field.key) { field.read(record, model) }
        return model
    }

    func link(_ record: CKRecord, resolver: RecordResolver, skipping: Set<String>) {
        guard let model = resolver.object(Model.self, uid: record.recordID.recordName) else { return }
        for parent in parents where !skipping.contains(parent.key) { parent.read(record, model, resolver) }
    }

    func delete(uid: String, in context: ModelContext) {
        guard let model = fetch(context, uid) else { return }
        if let project = model as? Project { context.deleteProjectGraph(project) }
        else { context.delete(model) }
    }

    func find(uid: String, in context: ModelContext) -> (any SyncedModel)? { fetch(context, uid) }
}

/// Finds objects by uid while records are applied — the ones made in this batch
/// first, then the store.
final class RecordResolver {
    let context: ModelContext
    /// Parent links that pointed at an object not (yet) in the store.
    var unresolved = 0
    private var cache: [String: any SyncedModel] = [:]

    init(context: ModelContext) { self.context = context }

    func remember(_ object: any SyncedModel) {
        cache[Self.key(type(of: object), object.uid)] = object
    }

    func object<T: SyncedModel>(_ type: T.Type, uid: String) -> T? {
        let key = Self.key(type, uid)
        if let hit = cache[key] as? T { return hit }
        guard let found = RecordSchemas.schema(for: type)?.find(uid: uid, in: context) as? T else { return nil }
        cache[key] = found
        return found
    }

    private static func key(_ type: any SyncedModel.Type, _ uid: String) -> String { "\(type):\(uid)" }
}

/// Media files handed to CloudKit as assets. They live in Caches until CloudKit
/// has uploaded them; anything older than a day is cleared.
enum RecordAssets {
    static let directory = URL.cachesDirectory.appending(path: "RecordAssets", directoryHint: .isDirectory)

    static func asset(for data: Data) -> CKAsset? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        guard (try? data.write(to: url)) != nil else { return nil }
        return CKAsset(fileURL: url)
    }

    static func pruneOld(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > 24 * 3600 { try? fm.removeItem(at: url) }
        }
    }
}

// MARK: - The schemas

enum RecordSchemas {
    static let all: [any AnyRecordSchema] = [project, episode, version, scene, shot, reference, customInfo, day, entry]

    static func schema(recordType: String) -> (any AnyRecordSchema)? {
        all.first { $0.recordType == recordType }
    }

    static func schema(for type: any SyncedModel.Type) -> (any AnyRecordSchema)? {
        all.first { ObjectIdentifier($0.modelType) == ObjectIdentifier(type) }
    }

    private static let perDevice = "this device's layout, not the project's"
    private static let legacy = "pre-reference shot media, converted before a project can be shared"

    static let project = RecordSchema<Project>(
        recordType: "CP_Project",
        make: { Project(filmName: "") },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("filmName", \.filmName),
            .value("productionCompany", \.productionCompany),
            .value("director", \.director),
            .value("cinematographer", \.cinematographer),
            .value("createdDate", \.createdDate),
            .value("isSeries", \.isSeries),
            .value("autoAddFilmTool", \.autoAddFilmTool),
            .value("coveragePaletteRaw", \.coveragePaletteRaw),
            .value("coverageColorModeRaw", \.coverageColorModeRaw),
            .value("shotSetupFieldOrderRaw", \.shotSetupFieldOrderRaw),
            .value("hiddenShotSetupFieldsRaw", \.hiddenShotSetupFieldsRaw),
            .value("defaultCamera", \.defaultCamera),
            .value("defaultFramelines", \.defaultFramelines),
            .value("defaultLens", \.defaultLens),
            .asset("scriptPDFData", \.scriptPDFData),
            .value("scriptPDFPageOffset", \.scriptPDFPageOffset),
            .value("scriptCharactersJSON", \.scriptCharactersJSON),
            .value("publishedRepoFullName", \.publishedRepoFullName),
        ],
        parents: [],
        notSynced: [
            "lastOpenedDate": "when this device last opened it",
            "sceneColumnWidth": perDevice, "shotColumnWidth": perDevice, "detailColumnWidth": perDevice,
            "scriptColumnWidth": perDevice, "scriptSplitFraction": perDevice,
        ])

    static let episode = RecordSchema<Episode>(
        recordType: "CP_Episode",
        make: { Episode(episodeNumber: 0) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("episodeNumber", \.episodeNumber),
            .value("title", \.title),
            .value("createdDate", \.createdDate),
            .value("director", \.director),
            .value("cinematographer", \.cinematographer),
        ],
        parents: [.parent("project", \.project)],
        notSynced: [:])

    static let version = RecordSchema<ScriptVersion>(
        recordType: "CP_ScriptVersion",
        make: { ScriptVersion(versionNumber: 1) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<ScriptVersion>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("versionNumber", \.versionNumber),
            .value("name", \.name),
            .value("createdDate", \.createdDate),
            .asset("pdfData", \.pdfData),
            .value("pdfPageOffset", \.pdfPageOffset),
            .value("coverageLineMargin", \.coverageLineMargin),
            .value("coverageLinesOnRight", \.coverageLinesOnRight),
        ],
        parents: [.parent("episode", \.episode), .parent("project", \.project)],
        notSynced: [:])

    static let scene = RecordSchema<Scene>(
        recordType: "CP_Scene",
        make: { Scene(sceneNumber: 0) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<Scene>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("sceneNumber", \.sceneNumber),
            .value("sortOrder", \.sortOrder),
            .value("isDay", \.isDay),
            .value("isInterior", \.isInterior),
            .value("nickname", \.nickname),
            .value("suffix", \.suffix),
            .value("sceneMapJSON", \.sceneMapJSON),
            .asset("sceneMapBackgroundData", \.sceneMapBackgroundData),
            .value("sceneMapBackgroundIsSatellite", \.sceneMapBackgroundIsSatellite),
            .value("sceneMapSatelliteLat", \.sceneMapSatelliteLat),
            .value("sceneMapSatelliteLon", \.sceneMapSatelliteLon),
            .value("sceneMapSatelliteMeters", \.sceneMapSatelliteMeters),
            .value("sceneMapSatelliteHeading", \.sceneMapSatelliteHeading),
            .value("sceneMapSatelliteCalibrated", \.sceneMapSatelliteCalibrated),
            .value("sceneMapMetersWide", \.sceneMapMetersWide),
            .value("sceneMapImportedMetersWide", \.sceneMapImportedMetersWide),
            .value("sceneMapCameraSizeMeters", \.sceneMapCameraSizeMeters),
            .value("sceneMapBackgroundScale", \.sceneMapBackgroundScale),
            .value("sceneMapBackgroundOffsetX", \.sceneMapBackgroundOffsetX),
            .value("sceneMapBackgroundOffsetY", \.sceneMapBackgroundOffsetY),
            .value("sceneMapBackgroundRotation", \.sceneMapBackgroundRotation),
            .value("sceneMapShowCameraFOV", \.sceneMapShowCameraFOV),
            .value("sceneMapViewableMarkerSize", \.sceneMapViewableMarkerSize),
            .value("sceneMapLocation", \.sceneMapLocation),
            .value("sceneFilmToolEnabled", \.sceneFilmToolEnabled),
            .value("sceneFilmGauge", \.sceneFilmGauge),
            .value("sceneFilmFPS", \.sceneFilmFPS),
            .value("sceneFilmMode", \.sceneFilmMode),
            .value("sceneFloorPlanJSON", \.sceneFloorPlanJSON),
            .value("isArchived", \.isArchived),
            .value("isExpandedInExport", \.isExpandedInExport),
            .value("scriptPageNumber", \.scriptPageNumber),
            .value("scriptLineNumber", \.scriptLineNumber),
            .value("sceneCharactersJSON", \.sceneCharactersJSON),
            .value("sunSettingsJSON", \.sunSettingsJSON),
            .value("scriptTimeOfDay", \.scriptTimeOfDay),
            .value("manualAnnotationY", \.manualAnnotationY),
            .value("pdfPageOffset", \.pdfPageOffset),
        ],
        parents: [.parent("project", \.project), .parent("scriptVersion", \.scriptVersion)],
        notSynced: [:])

    static let shot = RecordSchema<Shot>(
        recordType: "CP_Shot",
        make: { Shot(shotNumber: 0) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<Shot>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("shotNumber", \.shotNumber),
            .value("shotInformation", \.shotInformation),
            .value("numberingStyleRaw", \.numberingStyleRaw),
            .value("sizeRaw", \.sizeRaw),
            .value("secondSizeRaw", \.secondSizeRaw),
            .value("typeCategoryRaw", \.typeCategoryRaw),
            .value("secondTypeCategoryRaw", \.secondTypeCategoryRaw),
            .value("thirdTypeCategoryRaw", \.thirdTypeCategoryRaw),
            .value("typeRaw", \.typeRaw),
            .value("suffix", \.suffix),
            .value("nickname", \.nickname),
            .value("lensIsPrime", \.lensIsPrime),
            .value("lensfocal", \.lensfocal),
            .value("lensfocalEnd", \.lensfocalEnd),
            .value("sensorWidthMM", \.sensorWidthMM),
            .value("extraInfo", \.extraInfo),
            .value("isShot", \.isShot),
            .value("takeCount", \.takeCount),
            .value("circledTake", \.circledTake),
            .value("camera", \.camera),
            .value("framelines", \.framelines),
            .value("lensPreset", \.lensPreset),
            .json("scriptCoverageSelections", \.scriptCoverageSelections),
            .value("coverageSceneUIDs", \.coverageSceneUIDs),
        ],
        parents: [.parent("scene", \.scene)],
        notSynced: [
            "format": "folded into camera at launch",
            "photo1Data": legacy, "photo2Data": legacy, "videoDataLegacy": legacy, "referenceVideoExtension": legacy,
            "photo1CameraFamily": legacy, "photo1CameraFormat": legacy, "photo1FocalLength": legacy,
            "photo1LensPreset": legacy, "photo1Horizon": legacy, "photo1Tilt": legacy, "photo1Height": legacy,
            "photo1CaptureID": legacy, "photo1CaptureType": legacy, "photo1DateTimeOriginal": legacy,
            "photo1Keywords": legacy, "photo1Caption": legacy, "photo1Framelines": legacy, "photo1Software": legacy,
            "photo2CameraFamily": legacy, "photo2CameraFormat": legacy, "photo2FocalLength": legacy,
            "photo2LensPreset": legacy, "photo2Horizon": legacy, "photo2Tilt": legacy, "photo2Height": legacy,
            "photo2CaptureID": legacy, "photo2CaptureType": legacy, "photo2DateTimeOriginal": legacy,
            "photo2Keywords": legacy, "photo2Caption": legacy, "photo2Framelines": legacy, "photo2Software": legacy,
            "photo2CameraPhysicalWidth": legacy, "photo2CameraPhysicalLength": legacy, "photo2LocationModel": legacy,
            "photo2LocationWidth": legacy, "photo2LocationLength": legacy, "photo2LocationHeight": legacy,
        ])

    static let reference = RecordSchema<ShotReference>(
        recordType: "CP_ShotReference",
        make: { ShotReference(sortOrder: 0) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<ShotReference>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("sortOrder", \.sortOrder),
            .asset("imageData", \.imageData),
            .asset("videoData", \.videoData),
            .value("videoExtension", \.videoExtension),
            .asset("mapData", \.mapData),
            .asset("mapVideoData", \.mapVideoData),
            .value("mapVideoExtension", \.mapVideoExtension),
            .asset("mapCleanData", \.mapCleanData),
            .value("note", \.note),
            .value("cameraFamily", \.cameraFamily),
            .value("cameraFormat", \.cameraFormat),
            .value("focalLength", \.focalLength),
            .value("lensPreset", \.lensPreset),
            .value("horizon", \.horizon),
            .value("tilt", \.tilt),
            .value("height", \.height),
            .value("captureID", \.captureID),
            .value("captureType", \.captureType),
            .value("dateTimeOriginal", \.dateTimeOriginal),
            .value("keywords", \.keywords),
            .value("caption", \.caption),
            .value("framelines", \.framelines),
            .value("software", \.software),
            .value("mapCaptureID", \.mapCaptureID),
            .value("mapCameraPhysicalWidth", \.mapCameraPhysicalWidth),
            .value("mapCameraPhysicalLength", \.mapCameraPhysicalLength),
            .value("mapLocationModel", \.mapLocationModel),
            .value("mapLocationWidth", \.mapLocationWidth),
            .value("mapLocationLength", \.mapLocationLength),
            .value("mapLocationHeight", \.mapLocationHeight),
        ],
        parents: [.parent("shot", \.shot)],
        notSynced: [:])

    static let customInfo = RecordSchema<ShotCustomInfo>(
        recordType: "CP_ShotCustomInfo",
        make: { ShotCustomInfo() },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<ShotCustomInfo>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("sortOrder", \.sortOrder),
            .value("kind", \.kind),
            .value("label", \.label),
            .value("value", \.value),
            .value("filmGauge", \.filmGauge),
            .value("filmMode", \.filmMode),
            .value("filmAmount", \.filmAmount),
            .value("filmFPS", \.filmFPS),
        ],
        parents: [.parent("shot", \.shot)],
        notSynced: [:])

    static let day = RecordSchema<ShootingDay>(
        recordType: "CP_ShootingDay",
        make: { ShootingDay(sortOrder: 0) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<ShootingDay>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("sortOrder", \.sortOrder),
            .value("date", \.date),
            .value("notes", \.notes),
        ],
        parents: [.parent("scriptVersion", \.scriptVersion)],
        notSynced: [:])

    static let entry = RecordSchema<ScheduleEntry>(
        recordType: "CP_ScheduleEntry",
        make: { ScheduleEntry(sortOrder: 0) },
        fetch: { ctx, uid in try? ctx.fetch(FetchDescriptor<ScheduleEntry>(predicate: #Predicate { $0.uid == uid })).first },
        fields: [
            .value("uid", \.uid),
            .value("sortOrder", \.sortOrder),
            .value("note", \.note),
            .value("selectedShotUIDs", \.selectedShotUIDs),
            .value("shotShootOrderUIDs", \.shotShootOrderUIDs),
        ],
        parents: [.parent("scene", \.scene), .parent("day", \.day)],
        notSynced: [:])
}

// MARK: - A project's records

enum ProjectRecords {
    /// The zone a shared project lives in.
    static func zoneID(for project: Project, ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Project-\(project.uid)", ownerName: ownerName)
    }

    /// Every object of the project, each once: the project, its episodes and
    /// versions, their scenes with shots, references and custom info, and the
    /// shooting schedule.
    static func objects(in project: Project) -> [any SyncedModel] {
        var seen = Set<PersistentIdentifier>()
        var out: [any SyncedModel] = []
        func add(_ object: any SyncedModel) {
            if seen.insert(object.persistentModelID).inserted { out.append(object) }
        }
        add(project)
        let versions = project.episodes.flatMap(\.scriptVersions) + project.scriptVersions
        project.episodes.forEach(add)
        versions.forEach(add)
        for scene in versions.flatMap(\.scenes) + project.scenes {
            add(scene)
            for shot in scene.shots {
                add(shot)
                shot.references.forEach(add)
                shot.customInfo.forEach(add)
            }
        }
        for day in versions.flatMap(\.shootingDays) {
            add(day)
            day.entries.forEach(add)
        }
        return out
    }

    /// The record for one object. `base` is the record as last seen from the
    /// server, when there is one, so the save carries its change tag; `keys` limits
    /// the fields written to those that changed (so unchanged media isn't uploaded
    /// again). A record new to the server always gets every field.
    static func record(for object: any SyncedModel, zoneID: CKRecordZone.ID,
                       base: CKRecord? = nil, keys: Set<String>? = nil) -> CKRecord? {
        guard let schema = RecordSchemas.schema(for: type(of: object)) else { return nil }
        let record = base ?? CKRecord(recordType: schema.recordType,
                                      recordID: CKRecord.ID(recordName: object.uid, zoneID: zoneID))
        schema.fill(record, from: object, only: base == nil ? nil : keys)
        return record
    }

    static func records(for project: Project, zoneID: CKRecordZone.ID) -> [CKRecord] {
        objects(in: project).compactMap { record(for: $0, zoneID: zoneID) }
    }

    /// Applies records in any order: creates or updates each object by uid, then
    /// links every object to its parents. `keeping` names, per record, fields left
    /// as they are here (this device's changes not yet sent). Returns how many
    /// parent links pointed at objects that aren't there (yet).
    @discardableResult
    static func apply(_ records: [CKRecord], in context: ModelContext,
                      keeping: [String: Set<String>] = [:]) -> Int {
        let resolver = RecordResolver(context: context)
        let known = records.compactMap { record in RecordSchemas.schema(recordType: record.recordType).map { (record, $0) } }
        for (record, schema) in known {
            let kept = keeping[record.recordID.recordName] ?? []
            resolver.remember(schema.upsert(record, resolver: resolver, skipping: kept))
        }
        for (record, schema) in known {
            schema.link(record, resolver: resolver, skipping: keeping[record.recordID.recordName] ?? [])
        }
        return resolver.unresolved
    }

    /// Deletes the objects behind deleted records.
    static func delete(_ deletions: [(recordType: String, uid: String)], in context: ModelContext) {
        for deletion in deletions {
            RecordSchemas.schema(recordType: deletion.recordType)?.delete(uid: deletion.uid, in: context)
        }
    }

    /// The project an object belongs to — which decides its zone.
    static func project(of object: any SyncedModel) -> Project? {
        switch object {
        case let project as Project: project
        case let episode as Episode: episode.project
        case let version as ScriptVersion: version.episode?.project ?? version.project
        case let scene as Scene: scene.scriptVersion.flatMap { project(of: $0) } ?? scene.project
        case let shot as Shot: shot.scene.flatMap { project(of: $0) }
        case let reference as ShotReference: reference.shot.flatMap { project(of: $0) }
        case let info as ShotCustomInfo: info.shot.flatMap { project(of: $0) }
        case let day as ShootingDay: day.scriptVersion.flatMap { project(of: $0) }
        case let entry as ScheduleEntry: entry.day.flatMap { project(of: $0) } ?? entry.scene.flatMap { project(of: $0) }
        default: nil
        }
    }
}
