//
//  SceneMapMerge.swift
//  CinePlanner
//
//  A scene map is stored as one JSON field, so when two devices change the same map
//  before they've synced, iCloud keeps one whole copy and the other device's changes
//  vanish. This merges them item by item instead:
//  • every save stamps the items that changed and records the ones removed
//    (`Scene.storeSceneMap`);
//  • each device keeps a local copy of every map as it last wrote or saw it
//    (`SceneMapShadow`) — the one place its own changes survive an import that
//    overwrote them;
//  • after an import changed a scene, its map is merged with that copy: per item the
//    later change wins, a removal beats older edits, and the result is written back so
//    the other device gets the merge too (`SceneMapSync`).
//
//  Maps saved by older versions carry no item stamps; their items count as changed
//  when their map was, so two such copies still resolve as before — the newer wins.
//

import Foundation
import SwiftData

/// The parts of a map that merge item by item.
nonisolated protocol MergeableMapItem: Identifiable, Codable, Equatable where ID == UUID {
    var editedAt: Double? { get set }
}

extension MapElement: MergeableMapItem {}
extension MapArrow: MergeableMapItem {}
extension Furniture: MergeableMapItem {}
extension MapText: MergeableMapItem {}

nonisolated enum SceneMapMerge {
    /// How long removals are remembered. A copy older than this can't be merged
    /// safely (its removed items would come back), so a shadow that old is ignored.
    static let retention: TimeInterval = 60 * 24 * 3600

    // MARK: Stamping

    /// `doc` as saved over `previous`: items that changed (or are new) are stamped
    /// `now`, items gone since `previous` are recorded as removed. An item that
    /// already carries a later stamp than `previous` came in through a merge and
    /// keeps it — only this device's own edits are stamped.
    static func stamped(_ doc: SceneMapDoc, against previous: SceneMapDoc, now: Double) -> SceneMapDoc {
        var out = doc
        var removed = previous.removed.merging(doc.removed, uniquingKeysWith: max)
        var changed = false

        func stamp<T: MergeableMapItem>(_ items: inout [T], was old: [T]) {
            let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in items.indices {
                let id = items[index].id
                removed[id.uuidString] = nil
                guard let prior = before[id] else {
                    items[index].editedAt = now; changed = true; continue
                }
                if sameIgnoringStamp(prior, items[index]) {
                    items[index].editedAt = prior.editedAt
                } else {
                    changed = true
                    if (items[index].editedAt ?? 0) <= (prior.editedAt ?? 0) { items[index].editedAt = now }
                }
            }
            let kept = Set(items.map(\.id))
            for item in old where !kept.contains(item.id) {
                changed = true
                if removed[item.id.uuidString] == nil { removed[item.id.uuidString] = now }
            }
        }
        stamp(&out.elements, was: previous.elements)
        stamp(&out.arrows, was: previous.arrows)
        stamp(&out.furniture, was: previous.furniture)
        stamp(&out.texts, was: previous.texts)

        if layers(of: doc) != layers(of: previous) {
            out.layersEditedAt = now; changed = true
        } else {
            out.layersEditedAt = previous.layersEditedAt
        }
        out.removed = removed.filter { now - $0.value < retention }
        out.editedAt = changed ? now : max(previous.editedAt, doc.editedAt)
        return out
    }

    // MARK: Merging

    /// Two copies of the same map as one. For an item in both, the later change wins;
    /// an item in only one is kept unless the other copy removed it. The newer copy
    /// decides the stacking order; items only in the other follow on top.
    static func merge(_ a: SceneMapDoc, _ b: SceneMapDoc) -> SceneMapDoc {
        let lead = a.editedAt >= b.editedAt ? a : b
        let other = a.editedAt >= b.editedAt ? b : a
        let removed = a.removed.merging(b.removed, uniquingKeysWith: max)

        func merge<T: MergeableMapItem>(_ leadItems: [T], _ otherItems: [T]) -> [T] {
            let othersByID = Dictionary(otherItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let leadIDs = Set(leadItems.map(\.id))
            var result: [T] = []
            for item in leadItems {
                if let theirs = othersByID[item.id] {
                    let pick = later(item, in: lead, theirs, in: other)
                    if notRemoved(pick, removed) { result.append(pick) }
                } else if survives(item, from: lead, against: other, removed) {
                    result.append(item)
                }
            }
            for item in otherItems where !leadIDs.contains(item.id) && survives(item, from: other, against: lead, removed) {
                result.append(item)
            }
            return result
        }

        var out = lead
        out.elements = merge(lead.elements, other.elements)
        out.furniture = merge(lead.furniture, other.furniture)
        out.texts = merge(lead.texts, other.texts)
        let elementIDs = Set(out.elements.map(\.id))
        out.arrows = merge(lead.arrows, other.arrows)
            .filter { elementIDs.contains($0.fromID) && elementIDs.contains($0.toID) }

        if (other.layersEditedAt ?? other.editedAt) > (lead.layersEditedAt ?? lead.editedAt) {
            out.showCharacters = other.showCharacters
            out.showCameras = other.showCameras
            out.showBackground = other.showBackground
            out.showFurniture = other.showFurniture
            out.showLights = other.showLights
            out.layersEditedAt = other.layersEditedAt
        }
        out.removed = removed
        out.editedAt = max(a.editedAt, b.editedAt)
        return out
    }

    /// Of one item's two versions, the later change. An unstamped item (saved by an
    /// older version) counts as changed when its whole map was.
    private static func later<T: MergeableMapItem>(_ x: T, in xDoc: SceneMapDoc,
                                                   _ y: T, in yDoc: SceneMapDoc) -> T {
        let tx = x.editedAt ?? xDoc.editedAt, ty = y.editedAt ?? yDoc.editedAt
        if tx != ty { return tx > ty ? x : y }
        if x == y { return x }
        // Same moment, different content: pick the same one on every device.
        return tiebreakKey(x) >= tiebreakKey(y) ? x : y
    }

    /// Whether an item that only `doc` has belongs in the merge. A recorded removal
    /// wins over any edit older than it. Without one, a stamped item is new (the other
    /// copy hasn't seen it yet); an unstamped one comes from an older version's save
    /// and, as before item stamps, stays only if its map is the newer of the two.
    private static func survives<T: MergeableMapItem>(_ item: T, from doc: SceneMapDoc,
                                                      against other: SceneMapDoc,
                                                      _ removed: [String: Double]) -> Bool {
        guard removed[item.id.uuidString] == nil else { return notRemoved(item, removed) }
        return item.editedAt != nil || doc.editedAt >= other.editedAt
    }

    /// False when the item was removed after its last change (an unstamped item has
    /// never been changed since removals were recorded, so any removal is later).
    private static func notRemoved<T: MergeableMapItem>(_ item: T, _ removed: [String: Double]) -> Bool {
        guard let at = removed[item.id.uuidString] else { return true }
        return (item.editedAt ?? 0) > at
    }

    /// Whether `merged` holds anything `stored` lacks — content, or a removal that
    /// should reach the other devices — and so needs storing.
    static func addsTo(_ stored: SceneMapDoc, _ merged: SceneMapDoc) -> Bool {
        !merged.sameContent(as: stored) || !Set(merged.removed.keys).isSubset(of: stored.removed.keys)
    }

    private static func sameIgnoringStamp<T: MergeableMapItem>(_ a: T, _ b: T) -> Bool {
        var a = a, b = b
        a.editedAt = nil; b.editedAt = nil
        return a == b
    }

    private static func tiebreakKey<T: MergeableMapItem>(_ item: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func layers(of doc: SceneMapDoc) -> [Bool] {
        [doc.showCharacters, doc.showCameras, doc.showBackground, doc.showFurniture, doc.showLights]
    }
}

// MARK: - This device's copy

/// Each map as this device last wrote or saw it, one small file per scene, kept
/// locally (never synced). It's what a merge restores this device's changes from
/// after an import overwrote them in the store.
nonisolated enum SceneMapShadow {
    // Set once at launch (tests point it at a temporary folder); read-only after.
    nonisolated(unsafe) static var directory: URL = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appending(path: "SceneMapShadows-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "SceneMapShadows", directoryHint: .isDirectory)
    }()

    /// The copy for a scene, unless there's none or it's too old to merge with.
    static func load(for sceneUID: String, now: Date = Date()) -> SceneMapDoc? {
        let url = file(for: sceneUID)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(modified) < SceneMapMerge.retention,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SceneMapDoc.self, from: data)
    }

    static func save(_ doc: SceneMapDoc, for sceneUID: String) {
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: sceneUID), options: .atomic)
    }

    /// Removes copies too old to merge with — which includes those of deleted scenes.
    static func pruneExpired(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) >= SceneMapMerge.retention { try? fm.removeItem(at: url) }
        }
    }

    private static func file(for sceneUID: String) -> URL {
        let name = sceneUID.replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}

// MARK: - Saving and syncing

extension Scene {
    /// Saves the scene map. Every change made to an existing map on this device goes
    /// through here: it stamps what changed — against this device's last copy, so only
    /// its own edits count as new — and keeps that copy current. Returns the map as
    /// stored, stamps included.
    @discardableResult
    func storeSceneMap(_ doc: SceneMapDoc, now: Date = Date()) -> SceneMapDoc {
        let previous = SceneMapShadow.load(for: uid, now: now) ?? SceneMapDoc.load(from: sceneMapJSON)
        let stored = SceneMapMerge.stamped(doc, against: previous, now: now.timeIntervalSince1970)
        sceneMapJSON = stored.jsonString
        SceneMapShadow.save(stored, for: uid)
        return stored
    }
}

/// Merges this device's map changes back in after an import overwrote them.
@MainActor
enum SceneMapSync {
    /// For each scene an import changed: compare the store's map with this device's
    /// copy, and where the copy holds changes the store lacks, store the merge (which
    /// then syncs to the other device). Reads the store through a fresh context —
    /// the main context's object can still hold this device's old value.
    static func reconcile(sceneIDs: Set<PersistentIdentifier>, in context: ModelContext, now: Date = Date()) {
        guard !sceneIDs.isEmpty else { return }
        let fresh = ModelContext(context.container)
        let stored = (try? fresh.fetch(FetchDescriptor<Scene>(predicate: #Predicate { sceneIDs.contains($0.persistentModelID) }))) ?? []
        var merges: [(uid: String, doc: SceneMapDoc)] = []
        for storeScene in stored {
            let remote = SceneMapDoc.load(from: storeScene.sceneMapJSON)
            guard let local = SceneMapShadow.load(for: storeScene.uid, now: now), local != remote else {
                SceneMapShadow.save(remote, for: storeScene.uid)
                continue
            }
            let merged = SceneMapMerge.merge(local, remote)
            if SceneMapMerge.addsTo(remote, merged) {
                merges.append((storeScene.uid, merged))
            } else {
                SceneMapShadow.save(remote, for: storeScene.uid)
            }
        }
        guard !merges.isEmpty else { return }

        // A merge isn't an edit of the user's: keep it out of ⌘Z.
        let undo = context.undoManager
        context.undoManager = nil
        defer { context.undoManager = undo }
        for (uid, merged) in merges {
            guard let scene = (try? context.fetch(FetchDescriptor<Scene>(predicate: #Predicate { $0.uid == uid })))?.first else { continue }
            scene.sceneMapJSON = merged.jsonString
            SceneMapShadow.save(merged, for: uid)
        }
        context.saveReporting()
    }
}
