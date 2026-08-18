//
//  CloudSyncMonitor.swift
//  CinePlanner
//
//  Tracks iCloud (CloudKit) sync activity for a small status badge. SwiftData
//  mirrors the store through NSPersistentCloudKitContainer, which posts
//  eventChangedNotification for each setup/import/export — we fold those into a
//  simple status, plus an iCloud-account check so a signed-out user sees why
//  nothing is syncing.
//

import Foundation
import CoreData
import Combine
import SwiftUI
import SwiftData

@MainActor
final class CloudSyncMonitor: ObservableObject {
    enum Status { case connected, syncing, synced, error, signedOut }

    @Published private(set) var status: Status = .connected
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastErrorMessage: String?

    private var active: Set<UUID> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshAccount()

        let event = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note) }
        }
        observers.append(event)

        let identity = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        }
        observers.append(identity)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Best-effort manual sync, triggered by tapping the badge. Re-checks the
    /// iCloud account, clears a stale error so the status re-evaluates, and
    /// flushes any pending local changes so CloudKit exports them. SwiftData
    /// exposes no public API to force a fetch, so incoming changes still arrive
    /// on CloudKit's own schedule — this mainly retries after an error and
    /// pushes unsaved work.
    func requestSync(context: ModelContext) {
        refreshAccount()
        guard status != .signedOut else { return }
        lastErrorMessage = nil
        if status == .error {
            status = active.isEmpty ? (lastSynced == nil ? .connected : .synced) : .syncing
        }
        if context.hasChanges { try? context.save() }
    }

    private func refreshAccount() {
        if FileManager.default.ubiquityIdentityToken == nil {
            status = .signedOut
        } else if status == .signedOut {
            status = active.isEmpty ? (lastSynced == nil ? .connected : .synced) : .syncing
        }
    }

    private func handle(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }

        if event.endDate == nil {
            active.insert(event.identifier)
            status = .syncing
            return
        }

        active.remove(event.identifier)
        if let error = event.error {
            lastErrorMessage = error.localizedDescription
            status = .error
        } else {
            lastSynced = event.endDate
            if active.isEmpty && status != .error { status = .synced }
        }
        if active.isEmpty && status == .syncing { status = lastSynced == nil ? .connected : .synced }
    }
}

/// Small pill showing the current iCloud sync state. Tapping it opens a detail
/// popover that can force a sync and, on error, shows the full CloudKit message
/// (on iPad the `.help` tooltip never appears, so the popover is the only way to
/// read it).
struct CloudSyncBadge: View {
    @ObservedObject var monitor: CloudSyncMonitor
    /// Called when the user taps "Sync Now" / "Retry" — the host passes its
    /// ModelContext through so the monitor can flush pending changes.
    var onSync: () -> Void
    @State private var showingDetail = false
    // iPhone: show just the status icon to fit the header row.
    private var isCompact: Bool { DeviceLayout.isPhone }

    var body: some View {
        Button { showingDetail = true } label: { pill }
            .buttonStyle(.plain)
            .help(helpText)
            .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                detail
                    .presentationCompactAdaptation(.popover)
            }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            if monitor.status == .syncing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
                Image(systemName: symbol)
            }
            if !isCompact { Text(label) }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(label).font(.headline)
            }

            if monitor.status == .error, let message = monitor.lastErrorMessage {
                Text("iCloud reported an error:")
                    .font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    Text(message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } else if monitor.status == .signedOut {
                Text("Sign in to iCloud in Settings to sync your projects across devices.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let date = monitor.lastSynced {
                Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Connected to iCloud. Your projects sync across your devices.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if monitor.status != .signedOut {
                Button {
                    onSync()
                    showingDetail = false
                } label: {
                    Label(monitor.status == .error ? "Retry Sync" : "Sync Now",
                          systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var symbol: String {
        switch monitor.status {
        case .connected: return "icloud"
        case .syncing:   return "arrow.triangle.2.circlepath"
        case .synced:    return "checkmark.icloud"
        case .error:     return "exclamationmark.icloud"
        case .signedOut: return "icloud.slash"
        }
    }

    private var label: String {
        switch monitor.status {
        case .connected: return "iCloud"
        case .syncing:   return "Syncing…"
        case .synced:    return "Synced"
        case .error:     return "Sync issue"
        case .signedOut: return "iCloud off"
        }
    }

    private var tint: Color {
        switch monitor.status {
        case .synced:    return .green
        case .error:     return .orange
        default:         return .secondary
        }
    }

    private var helpText: String {
        switch monitor.status {
        case .connected: return "Connected to iCloud. Your projects sync across your Macs."
        case .syncing:   return "Syncing with iCloud…"
        case .synced:
            if let date = monitor.lastSynced {
                return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Synced with iCloud."
        case .error:     return "iCloud sync issue: \(monitor.lastErrorMessage ?? "unknown error")"
        case .signedOut: return "Sign in to iCloud in System Settings to sync your projects across Macs."
        }
    }
}
