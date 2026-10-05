//
//  SharingLab.swift
//  CinePlanner
//
//  Debug builds only: a test bench for project sharing (phase 0 of the plan). It
//  checks, with throwaway records and nothing from the user's projects, the parts
//  that can only be tried with real iCloud accounts:
//  • a zone of our own in the private database, shared as a whole (CKShare),
//  • a second Apple ID accepting the share from a link,
//  • CKSyncEngine sending and receiving edits both ways — offline, conflicts —
//    on the owner's devices (private database) and the participant's (shared).
//  Lab zones are named "CPLab-…" and can be deleted from the lab.
//

#if DEBUG
import SwiftUI
import CloudKit

@MainActor @Observable
final class SharingLab {
    static let shared = SharingLab()

    struct Note: Identifiable, Equatable {
        let id: CKRecord.ID
        var text: String
        var modified: Date?
        var isShared: Bool          // seen through the shared database (we're a participant)
    }

    private(set) var accountStatus = "Checking…"
    private(set) var notes: [Note] = []
    private(set) var log: [String] = []
    private(set) var shareURL: URL?

    @ObservationIgnored private let container = CKContainer(identifier: "iCloud.YannickGiraud.CinePlanner")
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    /// Records as last seen from the server (for their change tags) or made here.
    @ObservationIgnored private var records: [CKRecord.ID: CKRecord] = [:]
    /// Text edited here and not yet confirmed saved, re-applied after a conflict.
    @ObservationIgnored private var unsent: [CKRecord.ID: String] = [:]
    /// A pending send per database, so a burst of edits goes out as one.
    @ObservationIgnored private var sendTasks: [Bool: Task<Void, Never>] = [:]

    private static let noteType = "LabNote"
    private static let zonePrefix = "CPLab-"

    private init() {}

    // MARK: Engines

    func start() {
        guard privateEngine == nil else { return }
        privateEngine = CKSyncEngine(.init(database: container.privateCloudDatabase,
                                           stateSerialization: Self.loadState("private"), delegate: self))
        sharedEngine = CKSyncEngine(.init(database: container.sharedCloudDatabase,
                                          stateSerialization: Self.loadState("shared"), delegate: self))
        note("Engines started")
        Task {
            do {
                let status = try await container.accountStatus()
                accountStatus = switch status {
                case .available: "iCloud available"
                case .noAccount: "Not signed in to iCloud"
                case .restricted: "iCloud restricted"
                case .temporarilyUnavailable: "iCloud temporarily unavailable"
                default: "iCloud status unknown"
                }
                let me = try await container.userRecordID()
                note("Signed in as \(me.recordName.prefix(12))…")
            } catch {
                accountStatus = "iCloud error: \(error.localizedDescription)"
            }
            await fetchNow()
        }
    }

    func fetchNow(quietly: Bool = false) async {
        do {
            try await privateEngine?.fetchChanges()
            try await sharedEngine?.fetchChanges()
            if !quietly { note("Fetched") }
        } catch {
            note("Fetch failed: \(error.localizedDescription)")
        }
    }

    /// The engine schedules its own syncs "when conditions are good" — too slow for
    /// working together — so an edit is sent a moment after the last keystroke…
    private func sendSoon(shared: Bool) {
        sendTasks[shared]?.cancel()
        sendTasks[shared] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do { try await engine(shared: shared)?.sendChanges() }
            catch { note("Send failed: \(error.localizedDescription)") }
        }
    }

    /// …and a push from iCloud fetches right away instead of waiting for the
    /// engine's scheduler.
    func receivedPush(scope: CKDatabase.Scope?) {
        let name = switch scope {
        case .private: "private"
        case .shared: "shared"
        default: "other"
        }
        note("Push received (\(name))")
        Task {
            do {
                if scope == .shared { try await sharedEngine?.fetchChanges() }
                else if scope == .private { try await privateEngine?.fetchChanges() }
                else { await fetchNow(quietly: true) }
            } catch {
                note("Fetch after push failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Owner: share a zone

    /// A new lab zone with one note, shared as a whole; anyone with the link (and an
    /// iCloud account) can join and edit — fine for a test, the real feature invites.
    func createSharedZone() async {
        let zone = CKRecordZone(zoneName: Self.zonePrefix + UUID().uuidString.prefix(8))
        let db = container.privateCloudDatabase
        do {
            _ = try await db.modifyRecordZones(saving: [zone], deleting: [])
            let record = CKRecord(recordType: Self.noteType,
                                  recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone.zoneID))
            record["text"] = "Hello from \(Self.deviceName)" as CKRecordValue
            let share = CKShare(recordZoneID: zone.zoneID)
            share[CKShare.SystemFieldKey.title] = "CinePlanner Sharing Lab" as CKRecordValue
            share.publicPermission = .readWrite
            let result = try await db.modifyRecords(saving: [record, share], deleting: [])
            for (_, saved) in result.saveResults {
                if case .success(let r) = saved, let s = r as? CKShare {
                    shareURL = s.url
                } else if case .success(let r) = saved {
                    records[r.recordID] = r
                }
            }
            refreshNotes()
            note("Created and shared \(zone.zoneID.zoneName)")
        } catch {
            note("Sharing failed: \(error.localizedDescription)")
        }
    }

    // MARK: Participant: accept

    func accept(_ metadata: CKShare.Metadata) async {
        do {
            _ = try await container.accept(metadata)
            note("Accepted share \(metadata.share.recordID.zoneID.zoneName)")
            await fetchNow()
        } catch {
            note("Accepting failed: \(error.localizedDescription)")
        }
    }

    // MARK: Editing

    func addNote(in zoneID: CKRecordZone.ID, shared: Bool) {
        let id = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        records[id] = CKRecord(recordType: Self.noteType, recordID: id)
        edit(id, text: "New note from \(Self.deviceName)", shared: shared)
    }

    func edit(_ id: CKRecord.ID, text: String, shared: Bool) {
        unsent[id] = text
        records[id]?["text"] = text as CKRecordValue
        refreshNotes()
        engine(shared: shared)?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        sendSoon(shared: shared)
    }

    func delete(_ id: CKRecord.ID, shared: Bool) {
        records[id] = nil
        unsent[id] = nil
        refreshNotes()
        engine(shared: shared)?.state.add(pendingRecordZoneChanges: [.deleteRecord(id)])
        sendSoon(shared: shared)
    }

    /// Removes this account's own lab zones (and so their shares).
    func deleteMyLabZones() async {
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
                .filter { $0.zoneID.zoneName.hasPrefix(Self.zonePrefix) }
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: zones.map(\.zoneID))
            for id in records.keys where zones.contains(where: { $0.zoneID == id.zoneID }) { records[id] = nil }
            shareURL = nil
            refreshNotes()
            note("Deleted \(zones.count) lab zone(s)")
        } catch {
            note("Deleting failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private func engine(shared: Bool) -> CKSyncEngine? { shared ? sharedEngine : privateEngine }

    private func refreshNotes() {
        let sharedZones = Set(records.keys.filter { $0.zoneID.ownerName != CKCurrentUserDefaultName }.map(\.zoneID))
        notes = records.values
            .filter { $0.recordType == Self.noteType }
            .map { Note(id: $0.recordID, text: $0["text"] as? String ?? "", modified: $0.modificationDate,
                        isShared: sharedZones.contains($0.recordID.zoneID)) }
            .sorted { ($0.id.zoneID.zoneName, $0.id.recordName) < ($1.id.zoneID.zoneName, $1.id.recordName) }
    }

    private func note(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(line)", at: 0)
        if log.count > 80 { log.removeLast() }
    }

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    private static func loadState(_ key: String) -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: "SharingLab.state.\(key)") else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func saveState(_ state: CKSyncEngine.State.Serialization, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "SharingLab.state.\(key)")
    }

    // MARK: Engine events (on the main actor)

    fileprivate func handle(_ event: CKSyncEngine.Event, shared: Bool) {
        let scope = shared ? "shared" : "private"
        switch event {
        case .stateUpdate(let update):
            Self.saveState(update.stateSerialization, scope)
        case .accountChange(let change):
            note("Account change (\(scope)): \(change.changeType)")
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions {
                for id in records.keys where id.zoneID == deletion.zoneID { records[id] = nil }
                note("Zone gone (\(scope)): \(deletion.zoneID.zoneName)")
            }
            refreshNotes()
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications where modification.record.recordType == Self.noteType {
                let record = modification.record
                records[record.recordID] = record
                unsent[record.recordID] = nil
            }
            for deletion in changes.deletions { records[deletion.recordID] = nil }
            if !changes.modifications.isEmpty || !changes.deletions.isEmpty {
                note("Received \(changes.modifications.count) change(s), \(changes.deletions.count) deletion(s) (\(scope))")
            }
            refreshNotes()
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                records[record.recordID] = record
                unsent[record.recordID] = nil
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                    // Someone saved first: take theirs and put our edit back on top
                    // (field by field — here there's only the one field).
                    if let mine = unsent[id] { server["text"] = mine as CKRecordValue }
                    records[id] = server
                    engine(shared: shared)?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    sendSoon(shared: shared)
                    note("Conflict on a note — merged and resending (\(scope))")
                } else {
                    note("Save failed (\(scope)): \(failure.error.localizedDescription)")
                }
            }
            if !sent.savedRecords.isEmpty { note("Sent \(sent.savedRecords.count) change(s) (\(scope))") }
            refreshNotes()
        default:
            break
        }
    }

    fileprivate func batch(for context: CKSyncEngine.SendChangesContext,
                           engine syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        let snapshot = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in snapshot[id] }
    }
}

extension SharingLab: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let shared = syncEngine.database.databaseScope == .shared
        await handle(event, shared: shared)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await batch(for: context, engine: syncEngine)
    }

    /// Leave SwiftData's zone (every regular project and its media) alone.
    nonisolated func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                             syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        guard syncEngine.database.databaseScope == .private else { return context.options }
        var options = context.options
        options.scope = .allExcluding([CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")])
        return options
    }
}

// MARK: - The lab screen

struct SharingLabView: View {
    @State private var lab = SharingLab.shared
    @State private var drafts: [CKRecord.ID: String] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud") {
                    Text(lab.accountStatus)
                    Button("Fetch Now") { Task { await lab.fetchNow() } }
                }
                Section {
                    Button("Create Shared Test Zone") { Task { await lab.createSharedZone() } }
                    if let url = lab.shareURL {
                        Text(url.absoluteString).font(.caption).textSelection(.enabled)
                        ShareLink(item: url) { Label("Send Link…", systemImage: "square.and.arrow.up") }
                    }
                    Button("Delete My Lab Zones", role: .destructive) { Task { await lab.deleteMyLabZones() } }
                } header: {
                    Text("Owner")
                } footer: {
                    Text("Send the link to a device signed in with another Apple ID and open it there.")
                }
                Section("Notes") {
                    if lab.notes.isEmpty { Text("No lab notes yet.").foregroundStyle(.secondary) }
                    ForEach(lab.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(note.isShared ? "Shared with me" : "Mine") · \(note.id.zoneID.zoneName)")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("Text", text: Binding(
                                    get: { drafts[note.id] ?? note.text },
                                    set: { drafts[note.id] = $0 }))
                                    .onSubmit { commit(note) }
                                Button("Save") { commit(note) }
                                Button(role: .destructive) { lab.delete(note.id, shared: note.isShared) } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Delete note")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if let zone = lab.notes.first?.id.zoneID {
                        Button("Add Note to \(zone.zoneName)") {
                            lab.addNote(in: zone, shared: zone.ownerName != CKCurrentUserDefaultName)
                        }
                    }
                }
                Section("Log") {
                    ForEach(Array(lab.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sharing Lab")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { lab.start() }
            // Safety nets for pushes that don't arrive: on coming back to the app,
            // and every 20 seconds while the lab is open.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await lab.fetchNow(quietly: true) } }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    await lab.fetchNow(quietly: true)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    private func commit(_ note: SharingLab.Note) {
        guard let text = drafts[note.id], text != note.text else { return }
        lab.edit(note.id, text: text, shared: note.isShared)
        drafts[note.id] = nil
    }
}

// MARK: - Accepting a share link

/// A share link opened: the lab's test zones go to the lab, projects to ProjectSync.
@MainActor
func acceptShare(_ metadata: CKShare.Metadata) {
    if metadata.share.recordID.zoneID.zoneName.hasPrefix("CPLab-") {
        Task { await SharingLab.shared.accept(metadata) }
    } else {
        Task { await ProjectSync.shared.accept(metadata) }
    }
}

#if os(macOS)
final class SharingLabAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        acceptShare(metadata)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return }
        let scope = (notification as? CKDatabaseNotification)?.databaseScope
        SharingLab.shared.receivedPush(scope: scope)
        ProjectSync.shared.receivedPush(scope: scope)
    }
}
#else
final class SharingLabAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SharingLabSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return .noData }
        let scope = (notification as? CKDatabaseNotification)?.databaseScope
        SharingLab.shared.receivedPush(scope: scope)
        ProjectSync.shared.receivedPush(scope: scope)
        return .newData
    }
}

final class SharingLabSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { acceptShare(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        acceptShare(metadata)
    }
}
#endif
#endif
