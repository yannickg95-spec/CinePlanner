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

/// Small pill showing the current iCloud sync state.
struct CloudSyncBadge: View {
    @ObservedObject var monitor: CloudSyncMonitor

    var body: some View {
        HStack(spacing: 5) {
            if monitor.status == .syncing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
                Image(systemName: symbol)
            }
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(helpText)
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
