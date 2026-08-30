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
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func push(versionUID: String, dayUID: String) {
        guard let activity, let state = makeState(versionUID: versionUID, dayUID: dayUID) else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    // MARK: - Step (from the Live Activity buttons)

    private func step(forward: Bool) {
        guard let activity, let ctx = container?.mainContext else { return }
        let versionUID = activity.attributes.versionUID
        let dayUID = activity.content.state.dayUID
        guard let day = day(versionUID: versionUID, dayUID: dayUID, in: ctx) else { return }
        let shots = day.orderedEntries.flatMap { $0.resolvedShots }
        guard !shots.isEmpty else { return }
        if forward {
            if let next = shots.first(where: { !$0.isShot }) { next.isShot = true }
        } else {
            if let last = shots.last(where: { $0.isShot }) { last.isShot = false }
        }
        try? ctx.save()
        push(versionUID: versionUID, dayUID: dayUID)
    }

    // MARK: - Building state

    private func version(uid: String, in ctx: ModelContext) -> ScriptVersion? {
        let descriptor = FetchDescriptor<ScriptVersion>(predicate: #Predicate { $0.uid == uid })
        return try? ctx.fetch(descriptor).first
    }

    private func day(versionUID: String, dayUID: String, in ctx: ModelContext) -> ShootingDay? {
        version(uid: versionUID, in: ctx)?.shootingDays.first { $0.uid == dayUID }
    }

    private func makeState(versionUID: String, dayUID: String) -> OnSetActivityAttributes.ContentState? {
        guard let ctx = container?.mainContext,
              let version = version(uid: versionUID, in: ctx),
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
