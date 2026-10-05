//
//  SettingsView.swift
//  CinePlanner
//
//  The Mac Settings window (CinePlanner ▸ Settings…, ⌘,): the app-wide settings that
//  were scattered over sheets and popovers, in one place. Everything here is stored
//  where it already lived — the same UserDefaults keys (synced by SettingsSync), the
//  same purchase state and GitHub token — so the sheets elsewhere stay in step.
//

#if os(macOS)
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShotOptionsSettingsTab()
                .tabItem { Label("Shot Options", systemImage: "list.bullet.rectangle") }
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage(CreditDefaults.directorKey) private var director = ""
    @AppStorage(CreditDefaults.cinematographerKey) private var cinematographer = ""
    @State private var showingRestore = false

    var body: some View {
        Form {
            Section {
                TextField("Director", text: $director, prompt: Text("Name to pre-fill for new projects"))
                TextField("Cinematographer", text: $cinematographer, prompt: Text("Name to pre-fill for new projects"))
            } header: {
                Text("Default Credits")
            } footer: {
                Text("Pre-filled on new projects and episodes; each project can still change them in the export.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Backups") {
                    Button("Restore from Backup…") { showingRestore = true }
                }
            } footer: {
                Text("CinePlanner keeps automatic snapshots of your data. Restoring one replaces everything with that snapshot.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingRestore) { RestoreBackupSheet() }
    }
}

// MARK: - Shot options

/// The user's own Size / Type / Grip options — the "Custom" entries the shot pickers
/// offer next to the built-in ones. Same storage as the pickers (one newline-joined
/// string per field), so adding or removing here shows up there and vice versa.
private struct ShotOptionsSettingsTab: View {
    @AppStorage("customSizes") private var sizes = ""
    @AppStorage("customTypes") private var types = ""
    @AppStorage("customGrips") private var grips = ""

    var body: some View {
        Form {
            CustomOptionsSection(title: "Sizes", noun: "size", raw: $sizes)
            CustomOptionsSection(title: "Types", noun: "type", raw: $types)
            CustomOptionsSection(title: "Grips", noun: "grip", raw: $grips)
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
    }
}

private struct CustomOptionsSection: View {
    let title: String
    let noun: String
    @Binding var raw: String
    @State private var newName = ""

    private var options: [String] { raw.split(separator: "\n").map(String.init) }

    var body: some View {
        Section(title) {
            if options.isEmpty {
                Text("No custom \(noun)s yet.").foregroundStyle(.secondary)
            }
            ForEach(options, id: \.self) { option in
                HStack {
                    Text(option)
                    Spacer()
                    Button(role: .destructive) { remove(option) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove “\(option)”")
                    .accessibilityLabel("Remove \(option)")
                }
            }
            HStack {
                TextField("New \(noun)", text: $newName)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !options.contains(name) else { newName = ""; return }
        raw = (options + [name]).joined(separator: "\n")
        newName = ""
    }

    private func remove(_ option: String) {
        raw = options.filter { $0 != option }.joined(separator: "\n")
    }
}

// MARK: - Account

private struct AccountSettingsTab: View {
    @EnvironmentObject private var access: AppAccess
    @State private var showingUnlock = false
    @State private var restoring = false
    @State private var restoreMessage: String?
    @State private var gitHubConnected = GitHubPublisher.hasToken
    @State private var gitHubUser: String?
    #if DEBUG
    @State private var schemaStatus: String?
    @State private var recoveryStatus: String?
    #endif

    private var status: String {
        switch access.state {
        case .loading: return "Checking…"
        case .full: return "Full version — thank you!"
        case .trialNotStarted: return "Free trial not started"
        case .trial(let days): return days == 1 ? "Free trial — last day" : "Free trial — \(days) days left"
        case .expired: return "Free trial ended — projects are read-only"
        }
    }

    var body: some View {
        Form {
            Section("CinePlanner") {
                LabeledContent("Status", value: status)
                if access.state != .full {
                    HStack {
                        Button("Unlock Full Version…") { showingUnlock = true }
                        Button("Restore Purchase", action: restore).disabled(restoring)
                        if restoring { ProgressView().controlSize(.small) }
                    }
                    if let restoreMessage {
                        Text(restoreMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if gitHubConnected {
                    LabeledContent("Account", value: gitHubUser.map { "@\($0)" } ?? "Connected")
                    Button("Disconnect GitHub", role: .destructive) {
                        GitHubPublisher.token = nil
                        gitHubConnected = false
                        gitHubUser = nil
                    }
                } else {
                    LabeledContent("Account", value: "Not connected")
                }
            } header: {
                Text("GitHub (Publish to Web)")
            } footer: {
                Text(gitHubConnected
                     ? "Disconnecting removes the sign-in from this Mac and your other devices (iCloud Keychain). Published pages stay online."
                     : "Connect from Publish to Web in an open project.")
                    .foregroundStyle(.secondary)
            }
            #if DEBUG
            Section {
                Button("Prepare iCloud Schema for Sharing") {
                    schemaStatus = "Working…"
                    Task {
                        do {
                            let count = try await ProjectSync.shared.prepareSchema()
                            schemaStatus = "Done: \(count) record types with every field are in the Development schema. Deploy it to Production in the CloudKit Console."
                        } catch {
                            schemaStatus = "Failed: \(error.localizedDescription)"
                        }
                    }
                }
                if let schemaStatus {
                    Text(schemaStatus).font(.caption).foregroundStyle(.secondary)
                }
                Button("Recover Shared Projects from the Old Container") {
                    recoveryStatus = "Working…"
                    Task {
                        do {
                            let names = try await ProjectSync.shared.recoverFromOldContainer()
                            recoveryStatus = names.isEmpty ? "Nothing to recover." : "Recovered: \(names.joined(separator: ", "))"
                        } catch {
                            recoveryStatus = "Failed: \(error.localizedDescription)"
                        }
                    }
                }
                if let recoveryStatus {
                    Text(recoveryStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Developer (debug builds)")
            } footer: {
                Text("Before a build that shares projects goes to TestFlight or the App Store: run this, then deploy the Development schema to Production.")
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingUnlock) { PaywallView(dismissable: true) }
        .task {
            gitHubConnected = GitHubPublisher.hasToken
            if gitHubConnected { gitHubUser = await GitHubPublisher.currentUsername() }
        }
    }

    private func restore() {
        restoring = true
        restoreMessage = nil
        Task {
            await access.store.restore()
            await access.refresh()
            restoring = false
            restoreMessage = access.state == .full
                ? "Your purchase has been restored."
                : (access.store.lastError ?? "No previous purchase found on this account.")
        }
    }
}
#endif
