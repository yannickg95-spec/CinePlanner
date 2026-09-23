//
//  AppAccess.swift
//  CinePlanner
//
//  Combines the purchase entitlement, grandfathering, and the trial clock into a
//  single access state that the UI gates on. Injected into the scene as an
//  EnvironmentObject; `RootGateView` shows the trial offer before the trial is
//  started and the paywall once it has expired.
//

import Foundation
import Combine
import StoreKit

@MainActor
final class AppAccess: ObservableObject {
    enum State: Equatable {
        case loading
        case full                       // purchased or grandfathered
        case trialNotStarted            // new user: offer the trial (or the unlock)
        case trial(daysRemaining: Int)
        case expired
    }

    @Published private(set) var state: State = .loading
    let store = EntitlementStore()

    private var updatesTask: Task<Void, Never>?

    /// True while the app should be blocked behind the trial offer or the paywall.
    var isLocked: Bool { state == .expired || state == .trialNotStarted }

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
