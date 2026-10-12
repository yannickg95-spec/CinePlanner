//
//  SharedProjectStatusViews.swift
//  CinePlanner
//
//  How a shared project stands with iCloud, shown where people work on it: a small
//  badge on the editor's sharing button (up to date, sending, receiving, offline, a
//  problem), the same in words in the sharing window, and — for a few seconds —
//  who just changed what.
//

import SwiftUI

extension SharedProjectStatus {
    var title: String {
        switch self {
        case .receiving(let count): "Receiving… \(count) item\(count == 1 ? "" : "s")"
        case .offline(let waiting): waiting == 0 ? "Offline" : "Offline · \(waiting) change\(waiting == 1 ? "" : "s") waiting"
        case .problem: "Not syncing"
        case .sending(let count): "Sending \(count) change\(count == 1 ? "" : "s")…"
        case .upToDate: "Up to date"
        }
    }

    var detail: String {
        switch self {
        case .receiving: "The project is coming in from iCloud."
        case .offline(let waiting):
            waiting == 0
                ? "Changes from others come in when you're back online."
                : "Your changes go out, and others' come in, when you're back online."
        case .problem(let problem): problem
        case .sending: "Your latest changes are on their way to the others."
        case .upToDate: "Everyone has your changes."
        }
    }

    var systemImage: String {
        switch self {
        case .receiving: "arrow.down"
        case .offline: "wifi.slash"
        case .problem: "exclamationmark"
        case .sending: "arrow.up"
        case .upToDate: "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .receiving, .sending: .blue
        case .offline: .orange
        case .problem: .red
        case .upToDate: .green
        }
    }

    /// The badge's symbol in a full-size label (the sharing window's status row).
    var labelImage: String {
        switch self {
        case .receiving: "icloud.and.arrow.down"
        case .offline: "icloud.slash"
        case .problem: "exclamationmark.icloud"
        case .sending: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        }
    }
}

/// A small round badge for the corner of a 36pt toolbar circle.
struct SyncStatusBadge: View {
    let status: SharedProjectStatus

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(status.tint))
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// "Anna changed shot 3.2", along the bottom of the open project for a few seconds
/// — or sync's own notes ("Anna joined “Defrost”"), which the project list shows
/// otherwise.
struct SyncActivityToast: View {
    let project: Project
    private var sync: ProjectSync { ProjectSync.shared }

    var body: some View {
        Group {
            if let latest = sync.latestActivity, latest.zoneName == "Project-\(project.uid)" {
                toast(latest.sentence, systemImage: "person.fill").id(latest.id)
            } else if let notice = sync.notice {
                toast(notice, systemImage: "person.2").id(notice)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: sync.latestActivity)
        .animation(.easeInOut(duration: 0.25), value: sync.notice)
        .allowsHitTesting(false)
    }

    private func toast(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
