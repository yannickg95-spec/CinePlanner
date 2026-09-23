//
//  SettingsSync.swift
//  CinePlanner
//
//  Syncs the app-wide settings (the ones in UserDefaults rather than in a project)
//  across the user's devices through iCloud's key-value store.
//
//  UserDefaults stays the source the app reads and writes — `@AppStorage` views and
//  plain reads keep working unchanged. This class mirrors the listed keys:
//  • every local change to one of them is pushed to iCloud (by watching
//    UserDefaults, so no view has to remember to push);
//  • changes from another device are copied down into UserDefaults, which updates
//    any `@AppStorage` view showing them.
//  Per-key last-writer-wins, except the custom option lists, which are merged the
//  first time a device syncs so neither device's existing entries are lost.
//
//  Device-specific state (the walkthrough flag, backup bookkeeping, one-off
//  migration flags) deliberately stays local.
//

import Foundation

@MainActor
final class SettingsSync {
    static let shared = SettingsSync()
    private init() {}

    /// The app-wide settings kept in step across devices.
    static let syncedKeys: [String] = [
        CreditDefaults.directorKey,
        CreditDefaults.cinematographerKey,
        "customSizes", "customTypes", "customGrips",   // OptionPickerView's own options
        PDFExportOptions.storeKey,
        "projectSort",
    ]
    /// Newline-joined lists that are unioned (not replaced) on a device's first sync.
    private static let listKeys: Set<String> = ["customSizes", "customTypes", "customGrips"]
    /// Set once this device has done its first sync, per key.
    private static func seededFlag(_ key: String) -> String { "settingsSyncSeeded_\(key)" }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private var started = false
    /// True while copying iCloud values down, so those writes aren't pushed back up.
    private var isPulling = false

    func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }

        cloud.synchronize()
        seed()
        pull()
    }

    /// First sync of each key on this device: bring what this device already had up
    /// to iCloud instead of letting iCloud's value silently replace it.
    private func seed() {
        for key in Self.syncedKeys where !defaults.bool(forKey: Self.seededFlag(key)) {
            let local = defaults.object(forKey: key)
            let remote = cloud.object(forKey: key)
            if let local {
                if remote == nil {
                    cloud.set(local, forKey: key)
                } else if Self.listKeys.contains(key),
                          let l = local as? String, let r = remote as? String {
                    let merged = Self.union(r, l)
                    if merged != r { cloud.set(merged, forKey: key) }
                }
            }
            defaults.set(true, forKey: Self.seededFlag(key))
        }
        cloud.synchronize()
    }

    /// Copies iCloud's values into UserDefaults where they differ.
    private func pull() {
        isPulling = true
        defer { isPulling = false }
        for key in Self.syncedKeys {
            guard let remote = cloud.object(forKey: key) else { continue }
            if !Self.same(defaults.object(forKey: key), remote) {
                defaults.set(remote, forKey: key)
            }
        }
    }

    /// Sends local values that differ from iCloud's up. Removals aren't propagated:
    /// none of these settings is ever removed, and a missing local value only means
    /// this device never set it.
    private func push() {
        guard !isPulling else { return }
        var changed = false
        for key in Self.syncedKeys {
            guard let local = defaults.object(forKey: key) else { continue }
            if !Self.same(local, cloud.object(forKey: key)) {
                cloud.set(local, forKey: key)
                changed = true
            }
        }
        if changed { cloud.synchronize() }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    /// `base`'s lines followed by any of `extra`'s it doesn't already have.
    private static func union(_ base: String, _ extra: String) -> String {
        var lines = base.split(separator: "\n").map(String.init)
        for line in extra.split(separator: "\n").map(String.init) where !lines.contains(line) {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
