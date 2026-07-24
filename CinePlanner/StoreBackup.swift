//
//  StoreBackup.swift
//  CinePlanner
//
//  Automatic, timestamped snapshots of the SwiftData store, so a corrupt write
//  or a fat-finger is never a total loss. A snapshot copies the store file and
//  everything beside it (the -wal/-shm sidecars and the external-storage
//  _SUPPORT folder that holds script PDFs).
//
//  Restore is applied on the *next* launch, before the store is opened — the
//  only safe moment to overwrite it — so we never swap the store out from under
//  a live container.
//

import Foundation
import SwiftData

enum StoreBackup {
    static let maxBackups = 12

    private static let restorePendingKey = "pendingRestoreBackupPath"
    private static let storeURLKey = "recordedStoreURL"

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
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

    /// The set of files that make up the store: the store file itself, its
    /// sidecars, and the external-storage support folder — everything in the
    /// store's directory whose name shares the store's base name.
    private static func storeItems(for storeURL: URL) -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent   // e.g. "default.store"
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])) ?? []
        return contents.filter { $0.lastPathComponent.contains(base) }
    }

    private static var backupsRoot: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return support.appending(path: "Backups")
    }

    // MARK: - Snapshot (on launch)

    /// Snapshots the store if it has changed since the most recent backup.
    static func backupIfNeeded(container: ModelContainer) {
        guard let storeURL = container.configurations.first?.url else { return }
        // Record the real store location so a restore next launch knows where to
        // put the files back, before the container exists.
        UserDefaults.standard.set(storeURL.path, forKey: storeURLKey)

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
                try FileManager.default.copyItem(at: item, to: dest.appending(path: item.lastPathComponent))
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)   // don't leave a partial snapshot
            return
        }
        prune()
    }

    /// The most recent modification time across the store's files.
    private static func newestChange(_ items: [URL]) -> Date {
        items.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
    }

    private static func prune() {
        let all = listBackups()   // newest first
        guard all.count > maxBackups else { return }
        for backup in all.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    // MARK: - Listing

    /// Existing snapshots, newest first.
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

    private static func directorySize(_ url: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: []) else { return 0 }
        return items.reduce(0) { total, item in
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - Restore (queued now, applied on next launch)

    static func requestRestore(_ backup: Backup) {
        UserDefaults.standard.set(backup.url.path, forKey: restorePendingKey)
    }

    static var restoreIsPending: Bool {
        UserDefaults.standard.string(forKey: restorePendingKey) != nil
    }

    /// Applied at launch, *before* the ModelContainer opens the store — the only
    /// safe moment to overwrite the store files. Copies a queued backup over the
    /// live store location, then clears the flag.
    static func performPendingRestoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard let backupPath = defaults.string(forKey: restorePendingKey),
              let storePath = defaults.string(forKey: storeURLKey) else { return }
        defer { defaults.removeObject(forKey: restorePendingKey) }

        let backupDir = URL(fileURLWithPath: backupPath)
        let storeURL = URL(fileURLWithPath: storePath)
        let storeDir = storeURL.deletingLastPathComponent()

        guard let backupItems = try? FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil, options: []) else { return }

        // Remove the current store files, then lay the backup's copies down.
        for item in storeItems(for: storeURL) {
            try? FileManager.default.removeItem(at: item)
        }
        for item in backupItems {
            let dest = storeDir.appending(path: item.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: item, to: dest)
        }
    }
}
