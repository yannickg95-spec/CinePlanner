//
//  OnSetLiveActivityController.swift
//  App-side driver for the On-Set Live Activity (iPhone). Builds the Activity's
//  ContentState from the live SwiftData store, starts it when On-Set Mode opens,
//  updates it as setups are checked off, and ends it on close. Also services the
//  Live Activity's ‹ › buttons (which run in-app via OnSetStepIntent) by marking
//  shots in the same store the in-app checklist uses.
//
//  iOS only — ActivityKit isn't available on macOS, so the whole file compiles
//  away there.
//

#if os(iOS)
import ActivityKit
import SwiftData
import Foundation

@MainActor
final class OnSetLiveActivityController {
    static let shared = OnSetLiveActivityController()
    private init() {}

    private var activity: Activity<OnSetActivityAttributes>?
    private weak var version: ScriptVersion?

    /// Registers the handler the Live Activity buttons call. Do this once at launch.
    func registerBridge() {
        OnSetActivityBridge.shared.handler = { forward in
            MainActor.assumeIsolated { OnSetLiveActivityController.shared.step(forward: forward) }
        }
    }

    // MARK: - Lifecycle

    func start(version: ScriptVersion) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Only one On-Set activity at a time.
        endExisting()
        guard let state = makeState(for: version) else { return }
        do {
            activity = try Activity.request(
                attributes: OnSetActivityAttributes(versionUID: version.uid),
                content: .init(state: state, staleDate: nil))
            self.version = version
        } catch {
            // Requesting can fail (disabled, too many activities); nothing to show.
            activity = nil
        }
    }

    func update() {
        guard let activity, let version, let state = makeState(for: version) else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        endExisting()
    }

    private func endExisting() {
        guard let activity else { return }
        self.activity = nil
        self.version = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Step (from the Live Activity buttons)

    private func step(forward: Bool) {
        guard let version else { return }
        let shots = orderedShots(for: version)
        if forward {
            if let next = shots.first(where: { !$0.isShot }) { next.isShot = true }
        } else {
            if let last = shots.last(where: { $0.isShot }) { last.isShot = false }
        }
        try? version.modelContext?.save()
        update()
    }

    // MARK: - Building state

    private func orderedShots(for version: ScriptVersion) -> [Shot] {
        selectedDay(for: version)?.orderedEntries.flatMap { $0.resolvedShots } ?? []
    }

    /// The day being shot: today's if scheduled, else the first.
    private func selectedDay(for version: ScriptVersion) -> ShootingDay? {
        let days = version.shootingDays.sorted { $0.sortOrder < $1.sortOrder }
        let cal = Calendar.current
        if let today = days.first(where: { d in d.date.map { cal.isDateInToday($0) } ?? false }) {
            return today
        }
        return days.first
    }

    private func makeState(for version: ScriptVersion) -> OnSetActivityAttributes.ContentState? {
        guard let day = selectedDay(for: version) else { return nil }
        let shots = day.orderedEntries.flatMap { $0.resolvedShots }
        let setups = shots.map { shot in
            OnSetSetup(
                num: shot.displayNumber,
                scene: "Scene \(shot.scene?.sceneNumber ?? 0)\(shot.scene?.suffix ?? "")",
                name: shot.nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                spec: combinedSpec(shot),
                done: shot.isShot)
        }
        let totalScenes = Set(shots.compactMap { $0.scene?.uid }).count
        let project = version.episode?.project
        return OnSetActivityAttributes.ContentState(
            projectName: project?.filmName ?? "Shot List",
            dayLabel: "Day \(day.sortOrder + 1)",
            setups: setups,
            totalScenes: totalScenes)
    }

    /// Size · type · lens · grip, like the On-Set row.
    private func combinedSpec(_ shot: Shot) -> String {
        [shot.shortSpec, shot.hasGrip ? shot.gripName : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
#endif
