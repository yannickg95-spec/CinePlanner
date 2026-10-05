//
//  OnSetLiveActivityController.swift
//  App-side driver for the On-Set Live Activity (iPhone). Started/stopped from a
//  control in On-Set Mode, for a specific shooting day. Everything is resolved
//  from the SwiftData store by UID (via the shared container's main context), so
//  the ‹ › buttons — which run in-app via OnSetStepIntent, and can wake the app in
//  the background — work regardless of what's in memory.
//
//  iOS only — ActivityKit isn't available on macOS, so the whole file compiles
//  away there.
//

#if os(iOS)
import ActivityKit
import SwiftData
import Foundation

@MainActor
@Observable
final class OnSetLiveActivityController {
    static let shared = OnSetLiveActivityController()
    private init() {}

    private var activity: Activity<OnSetActivityAttributes>?
    private var container: ModelContainer?

    /// True while a Live Activity is showing — drives the Start/Stop control.
    var isRunning: Bool { activity != nil }
    /// Whether Live Activities are available/enabled (false on iPad and when the
    /// user has turned them off for the app) — used to hide the control.
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Wire up the store + the button handler. Call once, early, at app launch —
    /// not from a view, so it's set even when iOS wakes the app in the background
    /// to run a step intent.
    func configure(container: ModelContainer) {
        self.container = container
        OnSetActivityBridge.shared.handler = { forward in
            Task { @MainActor in OnSetLiveActivityController.shared.step(forward: forward) }
        }
    }

    // MARK: - Lifecycle

    /// Adopts an already-running activity (e.g. after the app relaunched) so the
    /// control reflects reality, without starting a new one.
    func reconnect(versionUID: String) {
        guard activity == nil else { return }
        activity = Activity<OnSetActivityAttributes>.activities
            .first { $0.attributes.versionUID == versionUID }
    }

    /// Starts (or restarts) the Live Activity for a specific shooting day.
    func start(version: ScriptVersion, day: ShootingDay) {
        guard isAvailable,
              let state = makeState(versionUID: version.uid, dayUID: day.uid) else { return }
        endExisting()
        do {
            activity = try Activity.request(
                attributes: OnSetActivityAttributes(versionUID: version.uid),
                content: .init(state: state, staleDate: nil))
        } catch {
            activity = nil
        }
    }

    /// Points a running activity at a different day (follows the On-Set selection).
    func setDay(_ day: ShootingDay) {
        guard let activity else { return }
        push(versionUID: activity.attributes.versionUID, dayUID: day.uid)
    }

    /// Rebuilds and pushes the state for the day the activity is currently on —
    /// called after in-app changes.
    func update() {
        guard let activity else { return }
        push(versionUID: activity.attributes.versionUID,
             dayUID: activity.content.state.dayUID)
    }

    func end() {
        endExisting()
    }

    private func endExisting() {
        guard let activity else { return }
        self.activity = nil
        // ActivityKit's Activity is safe to drive from any thread.
        nonisolated(unsafe) let ending = activity
        Task { await ending.end(nil, dismissalPolicy: .immediate) }
    }

    private func push(versionUID: String, dayUID: String) {
        guard let activity, let state = makeState(versionUID: versionUID, dayUID: dayUID) else { return }
        nonisolated(unsafe) let running = activity
        Task { await running.update(.init(state: state, staleDate: nil)) }
    }

    // MARK: - Step (from the Live Activity buttons)

    private func step(forward: Bool) {
        guard let activity else { return }
        let versionUID = activity.attributes.versionUID
        let dayUID = activity.content.state.dayUID
        guard let day = day(versionUID: versionUID, dayUID: dayUID), let ctx = day.modelContext else { return }
        let shots = day.orderedEntries.flatMap { $0.resolvedShots }
        guard !shots.isEmpty else { return }
        if forward {
            if let next = shots.first(where: { !$0.isShot }) { next.isShot = true }
        } else {
            if let last = shots.last(where: { $0.isShot }) { last.isShot = false }
        }
        ctx.saveReporting()
        push(versionUID: versionUID, dayUID: dayUID)
    }

    // MARK: - Building state

    /// The version in whichever store holds it: the regular one, or the shared one
    /// for a shared project.
    private func version(uid: String) -> ScriptVersion? {
        let descriptor = FetchDescriptor<ScriptVersion>(predicate: #Predicate { $0.uid == uid })
        for ctx in [container?.mainContext, SharedProjectStore.openContext].compactMap({ $0 }) {
            if let version = try? ctx.fetch(descriptor).first { return version }
        }
        return nil
    }

    private func day(versionUID: String, dayUID: String) -> ShootingDay? {
        version(uid: versionUID)?.shootingDays.first { $0.uid == dayUID }
    }

    private func makeState(versionUID: String, dayUID: String) -> OnSetActivityAttributes.ContentState? {
        guard let version = version(uid: versionUID),
              let day = version.shootingDays.first(where: { $0.uid == dayUID }) else { return nil }
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
        return OnSetActivityAttributes.ContentState(
            projectName: version.episode?.project?.filmName ?? "Shot List",
            dayLabel: "Day \(day.sortOrder + 1)",
            dayUID: dayUID,
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
