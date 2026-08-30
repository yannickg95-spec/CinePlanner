//
//  OnSetActivityAttributes.swift
//  Shared between the app and the On-Set widget extension.
//
//  Describes the Live Activity for On-Set Mode: the shooting day's setups and
//  their done state travel in the ContentState, so the widget renders entirely
//  from this (no store access in the extension). The app is the source of truth
//  and pushes updates as shots are checked off.
//

#if os(iOS)
import ActivityKit
import Foundation

/// One setup (shot) on the day, in shoot order.
struct OnSetSetup: Codable, Hashable {
    var num: String     // display number, e.g. "1.2"
    var scene: String   // "Scene 1"
    var name: String    // nickname, or "" when unset
    var spec: String    // "MS · Single · 100mm · Handheld", or ""
    var done: Bool
}

struct OnSetActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var projectName: String
        var dayLabel: String        // "Day 1"
        var dayUID: String          // which day, so the step buttons can resolve it
        var setups: [OnSetSetup]    // the day's shots, in shoot order
        var totalScenes: Int
    }

    /// Identifies which version/day this activity is for (the app holds the truth).
    var versionUID: String
}

// MARK: - Derived values (shared by the widget UI and the app)

extension OnSetActivityAttributes.ContentState {
    var doneCount: Int { setups.filter { $0.done }.count }
    var total: Int { setups.count }

    /// Index of the setup being shot now — the first not-yet-done one.
    var currentIndex: Int? { setups.firstIndex { !$0.done } }
    var current: OnSetSetup? { currentIndex.map { setups[$0] } }
    var wrapped: Bool { currentIndex == nil && !setups.isEmpty }

    /// The next up-to-two undone setups after the current one, in order.
    var upcoming: [OnSetSetup] {
        guard let i = currentIndex, i + 1 < setups.count else { return [] }
        return Array(setups[(i + 1)...].prefix(2))
    }

    var progress: Double { total == 0 ? 0 : Double(doneCount) / Double(total) }

    /// Scenes whose every setup on the day is done.
    var scenesCleared: Int {
        var byScene: [String: [Bool]] = [:]
        for s in setups { byScene[s.scene, default: []].append(s.done) }
        return byScene.values.filter { $0.allSatisfy { $0 } }.count
    }
}
#endif
