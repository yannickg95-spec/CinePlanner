//
//  AppAccess.swift
//  CinePlanner
//
//  Combines the purchase entitlement, grandfathering, and the trial clock into a
//  single access state that the UI gates on. Injected into the scene as an
//  EnvironmentObject; `RootGateView` shows the trial offer before the trial is
//  started. Once it has expired the app is read-only: projects open in a viewer
//  (view and export), and `ReadOnlyGate` keeps anything from being saved.
//

import Foundation
import Combine
import StoreKit
import SwiftData

/// After the trial, nothing may be written to the store. The main context stops
/// autosaving and every `saveReporting()` rolls back instead of saving — a backstop
/// under the read-only UI, so an edit that slips through is simply not kept. A
/// purchase lifts it, and everything saved before the trial ended is untouched.
@MainActor
enum ReadOnlyGate {
    static weak var mainContext: ModelContext?
    static var isActive = false {
        didSet { mainContext?.autosaveEnabled = !isActive }
    }
}

@MainActor
final class AppAccess: ObservableObject {
    enum State: Equatable {
        case loading
        case full                       // purchased or grandfathered
        case trialNotStarted            // new user: offer the trial (or the unlock)
        case trial(daysRemaining: Int)
        case expired
    }

    @Published private(set) var state: State = .loading {
        didSet { ReadOnlyGate.isActive = isReadOnly }
    }
    let store = EntitlementStore()

    private var updatesTask: Task<Void, Never>?

    /// True while the app should be blocked behind the trial offer.
    var isLocked: Bool { state == .trialNotStarted }

    /// True once the trial has ended without a purchase: projects can be viewed and
    /// exported, not edited.
    var isReadOnly: Bool { state == .expired }

    /// Kick off transaction listening and compute the initial state.
    func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    await self?.refresh()
                }
            }
        }
        await refresh()
    }

    /// Recompute access from scratch: purchase → grandfather → trial.
    func refresh() async {
        #if DEBUG
        // Testing aid, debug builds only: launch with `-CPDebugForceExpired YES`
        // (scheme ▸ Run ▸ Arguments) to see the app as it is after the trial.
        if UserDefaults.standard.bool(forKey: "CPDebugForceExpired") {
            state = .expired
            return
        }
        #endif
        await store.loadProduct()
        await store.refreshPurchased()

        if store.isPurchased {
            state = .full
            return
        }
        if await EntitlementStore.isGrandfathered() {
            state = .full
            return
        }
        guard let start = store.trialStartDate else {
            state = .trialNotStarted
            return
        }
        let trusted = await EntitlementStore.trustedNow()
        let trial = TrialClock.evaluate(start: start, trustedNow: trusted)
        state = trial.isActive ? .trial(daysRemaining: trial.daysRemaining) : .expired
    }

    /// Called from the paywall after a successful buy/restore.
    func unlockedAfterPurchase() {
        state = .full
    }

    deinit { updatesTask?.cancel() }
}
