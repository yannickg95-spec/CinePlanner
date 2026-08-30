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

/// The app-wide default credit names, stored in UserDefaults so they persist
/// across projects and launches. Read at project/episode creation to pre-fill.
enum CreditDefaults {
    static let directorKey = "defaultDirector"
    static let cinematographerKey = "defaultCinematographer"

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
