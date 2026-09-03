//
//  StoreBackup.swift
//  CinePlanner
//
//  Automatic, timestamped snapshots of the SwiftData store, so a corrupt write,
//  a fat-finger, or a bad migration is never a total loss. A snapshot copies the
//  store file and everything beside it (the -wal/-shm sidecars and the
//  external-storage _SUPPORT folder that holds script PDFs).
//
//  Snapshots are taken *before* the store is opened, so they capture the last
//  good state ahead of any migration this launch might run. Restore is likewise
//  applied before the store is opened — the only safe moment to overwrite it.
//

import Foundation
import SwiftData
import os

enum StoreBackup {
    static let maxBackups = 12

    /// Whether a snapshot has already been taken this launch. `backupBeforeOpening`
    /// is the normal path; the post-open pass exists only to cover the very first
    /// launch, and must not add a second copy of the same moment.
    private static var snapshotTakenThisLaunch = false

    private static let restorePendingKey = "pendingRestoreBackupPath"
    private static let storeURLKey = "recordedStoreURL"

    /// Millisecond resolution so two snapshots in one launch never collide.
    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    struct Backup: Identifiable {
        let url: URL
        let date: Date
        let sizeBytes: Int64
        var id: String { url.lastPathComponent }
    }

    // MARK: - Locations

    /// The files that make up the store: the store file, its sidecars, and the
    /// external-storage support folder — everything in the store's directory
    /// whose name shares the store's base name.
    private static func storeItems(for storeURL: URL) -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent   // e.g. "default.store"
        // Core Data keeps externally-stored blobs (script PDFs, reference photos)
        // in a sibling ".<name>_SUPPORT" folder. Its name shares no substring with
        // the store's own, so it has to be matched separately — leaving it out
        // makes a snapshot incomplete, and a restore then resurrects a database
        // whose file references point at blobs that may no longer exist.
        let support = "." + storeURL.deletingPathExtension().lastPathComponent + "_SUPPORT"
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])) ?? []
        return contents.filter { item in
            let name = item.lastPathComponent
            guard !name.contains(".corrupt-") else { return false }
            return name.contains(base) || name == support
        }
    }

    /// Copies a file or folder, preferring an APFS clone. A clone shares the
    /// underlying bytes until one side is written to, so snapshotting the
    /// external-data folder costs almost nothing on disk and stays independent
    /// (copy-on-write) if either copy changes later. Falls back to a real copy
    /// when cloning isn't possible — another filesystem, or a cross-volume path.
    private static func cloneOrCopy(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static var backupsRoot: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return support.appending(path: "Backups")
    }

    /// The store location, recorded after a successful open so later launches
    /// (which run before the container exists) know where the store lives.
    static var recordedStoreURL: URL? {
        UserDefaults.standard.string(forKey: storeURLKey).map { URL(fileURLWithPath: $0) }
    }

    static func recordStoreURL(_ container: ModelContainer) {
        if let url = container.configurations.first?.url {
            UserDefaults.standard.set(url.path, forKey: storeURLKey)
        }
    }

    // MARK: - Snapshot

    /// Snapshots the on-disk store before it's opened — capturing the last good
    /// state ahead of any migration. No-op on the first ever launch (no store
    /// location recorded yet) and when nothing changed since the last snapshot.
    static func backupBeforeOpening() {
        guard let url = recordedStoreURL else { return }
        snapshot(storeURL: url)
    }

    /// Snapshots the current store after a successful open — covers the very
    /// first launch, when there was no recorded location to snapshot beforehand.
    /// On every other launch `backupBeforeOpening` has already run, so this is a
    /// no-op: opening the store writes to it, which would otherwise defeat the
    /// "did anything change?" check in `snapshot` and duplicate that snapshot.
    static func backupIfNeeded(container: ModelContainer) {
        guard !snapshotTakenThisLaunch else { return }
        guard let url = container.configurations.first?.url else { return }
        snapshot(storeURL: url)
    }

    private static func snapshot(storeURL: URL) {
        guard let root = backupsRoot else { return }
        let items = storeItems(for: storeURL)
        guard !items.isEmpty else { return }

        let existing = listBackups()
        let storeChanged = existing.first.map { newestChange(items) > $0.date } ?? true
        guard storeChanged else { return }

        let dest = root.appending(path: folderFormatter.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for item in items {
                try cloneOrCopy(from: item, to: dest.appending(path: item.lastPathComponent))
            }
        } catch {
            Log.backup.error("Snapshot failed, discarding the partial copy: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: dest)   // don't leave a partial snapshot
            return
        }
        snapshotTakenThisLaunch = true
        prune()
    }

    private static func newestChange(_ items: [URL]) -> Date {
        items.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
    }

    private static func prune() {
        let all = listBackups()   // newest first
        guard all.count > maxBackups else { return }
        for backup in all.dropFirst(maxBackups) {
            do { try FileManager.default.removeItem(at: backup.url) }
            // Not fatal, but it means the backup folder keeps growing unnoticed.
            catch { Log.backup.notice("Could not prune an old snapshot: \(error.localizedDescription)") }
        }
    }

    // MARK: - Listing

    static func listBackups() -> [Backup] {
        guard let root = backupsRoot,
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return dirs.compactMap { url -> Backup? in
            guard let date = folderFormatter.date(from: url.lastPathComponent) else { return nil }
            return Backup(url: url, date: date, sizeBytes: directorySize(url))
        }
        .sorted { $0.date > $1.date }
    }

    /// Total bytes of every file in the backup, the external-data folder included
    /// — a shallow sum would report a snapshot as far smaller than it is.
    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Restore

    /// Queues a user-chosen restore, applied on the next launch before the store
    /// opens (see performPendingRestoreIfNeeded).
    static func requestRestore(_ backup: Backup) {
        UserDefaults.standard.set(backup.url.path, forKey: restorePendingKey)
    }

    static func performPendingRestoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard let backupPath = defaults.string(forKey: restorePendingKey),
              let storePath = defaults.string(forKey: storeURLKey) else { return }
        defer { defaults.removeObject(forKey: restorePendingKey) }
        _ = copyBackup(URL(fileURLWithPath: backupPath), toStoreURL: URL(fileURLWithPath: storePath))
    }

    /// Immediate restore during recovery — the store must not be open. Returns
    /// whether the copy succeeded.
    @discardableResult
    static func restoreNow(_ backup: Backup) -> Bool {
        guard let storeURL = recordedStoreURL else { return false }
        return copyBackup(backup.url, toStoreURL: storeURL)
    }

    /// Moves an unreadable store aside (…​.corrupt-<timestamp>) so a fresh one can
    /// be created and the app can open. The bad files stay for manual recovery.
    static func quarantineUnreadableStore() {
        guard let storeURL = recordedStoreURL else { return }
        let stamp = folderFormatter.string(from: Date())
        for item in storeItems(for: storeURL) {
            let aside = item.deletingLastPathComponent()
                .appending(path: item.lastPathComponent + ".corrupt-\(stamp)")
            do { try FileManager.default.moveItem(at: item, to: aside) }
            // The last rung of the recovery ladder: if the bad store cannot be
            // moved aside, the fresh one is about to be created on top of it.
            catch { Log.backup.error("Could not quarantine an unreadable store file: \(error.localizedDescription)") }
        }
    }

    private static func copyBackup(_ backupDir: URL, toStoreURL storeURL: URL) -> Bool {
        let storeDir = storeURL.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil, options: []) else { return false }
        // Clear only what this backup can actually put back. Snapshots taken before
        // the external-data folder was included don't carry one, and wiping the live
        // folder for them would delete every externally-stored photo and PDF with
        // nothing to restore in its place. The store file and its sidecars always go,
        // since a stale -wal against a restored store is worse than none.
        let restorable = Set(items.map(\.lastPathComponent))
        let base = storeURL.lastPathComponent
        for item in storeItems(for: storeURL) {
            let name = item.lastPathComponent
            guard name.contains(base) || restorable.contains(name) else { continue }
            do { try FileManager.default.removeItem(at: item) }
            // A leftover file here can shadow what we are about to restore.
            catch { Log.backup.error("Could not clear \(name, privacy: .public) before restoring: \(error.localizedDescription)") }
        }
        var ok = true
        for item in items {
            let dest = storeDir.appending(path: item.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do { try cloneOrCopy(from: item, to: dest) } catch { ok = false }
        }
        return ok
    }
}
