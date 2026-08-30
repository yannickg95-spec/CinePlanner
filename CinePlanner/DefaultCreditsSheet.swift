//
//  DefaultCreditsSheet.swift
//  CinePlanner
//
//  App-level default credits. A user who shoots most projects with the same
//  director / cinematographer can set them once here (from the projects page);
//  new projects and new episodes are then pre-filled with these names, still
//  overridable per project in the export credits.
//

import SwiftUI

/// The app-wide default credit names. Synced across the user's devices via
/// iCloud's key-value store, and mirrored into UserDefaults so the app's
/// `@AppStorage`-backed UI and reads stay reactive/local-fast. Read at
/// project/episode creation to pre-fill.
enum CreditDefaults {
    static let directorKey = "defaultDirector"
    static let cinematographerKey = "defaultCinematographer"
    private static var allKeys: [String] { [directorKey, cinematographerKey] }
    private static var cloud: NSUbiquitousKeyValueStore { .default }

    static var director: String {
        UserDefaults.standard.string(forKey: directorKey) ?? ""
    }
    static var cinematographer: String {
        UserDefaults.standard.string(forKey: cinematographerKey) ?? ""
    }

    /// True when at least one default is set — used to badge the projects-page
    /// button so it reads as "configured".
    static var hasAny: Bool {
        !director.trimmingCharacters(in: .whitespaces).isEmpty
        || !cinematographer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Push a locally-edited value up to iCloud. (It's already in UserDefaults via
    /// the editing @AppStorage binding; this mirrors it to the cloud store.)
    static func push(_ value: String, forKey key: String) {
        cloud.set(value, forKey: key)
        cloud.synchronize()
    }

    /// Copy the iCloud values down into UserDefaults, so @AppStorage-backed views
    /// reflect them. Only overwrites when the cloud actually holds a value.
    static func pullFromCloud() {
        for key in allKeys {
            if let remote = cloud.string(forKey: key),
               UserDefaults.standard.string(forKey: key) != remote {
                UserDefaults.standard.set(remote, forKey: key)
            }
        }
    }
}

/// Keeps `CreditDefaults` in sync with iCloud. Started once at launch: seeds the
/// cloud from any pre-iCloud local values, pulls the latest down, and listens for
/// changes made on other devices.
final class CreditDefaultsSync {
    static let shared = CreditDefaultsSync()
    private init() {}
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let cloud = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChangedExternally),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud)

        // First run: if the cloud has no value yet but this device has one from
        // before iCloud sync existed, seed the cloud so it isn't lost.
        for key in [CreditDefaults.directorKey, CreditDefaults.cinematographerKey] {
            let local = UserDefaults.standard.string(forKey: key) ?? ""
            if cloud.string(forKey: key) == nil && !local.isEmpty {
                cloud.set(local, forKey: key)
            }
        }
        cloud.synchronize()
        CreditDefaults.pullFromCloud()
    }

    @objc private func cloudChangedExternally() {
        CreditDefaults.pullFromCloud()
    }
}

/// A small sheet to set the default Director and Cinematographer.
struct DefaultCreditsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CreditDefaults.directorKey) private var director = ""
    @AppStorage(CreditDefaults.cinematographerKey) private var cinematographer = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Default Credits",
                subtitle: "Pre-fills Director and Cinematographer on new projects and episodes. Leave a field blank to skip it — you can always change credits per project in the export.")
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                field("Director", text: $director, prompt: "Name to pre-fill for new projects")
                field("Cinematographer", text: $cinematographer, prompt: "Name to pre-fill for new projects")
            }
            .padding(20)

            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 460, height: 320)
        // Mirror edits up to iCloud (the @AppStorage bindings already saved them
        // locally to UserDefaults).
        .onChange(of: director) { _, value in
            CreditDefaults.push(value, forKey: CreditDefaults.directorKey)
        }
        .onChange(of: cinematographer) { _, value in
            CreditDefaults.push(value, forKey: CreditDefaults.cinematographerKey)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
