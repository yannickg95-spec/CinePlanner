//
//  PaywallView.swift
//  CinePlanner
//
//  The unlock screen and the gate that wraps the app. A new user first sees the
//  free-trial offer; during the trial a slim banner offers to unlock early; once
//  the trial has expired the paywall covers the app and can't be dismissed until
//  the one-time purchase is made or restored.
//

import SwiftUI
import StoreKit

// MARK: - Gate

/// Wraps the app's content: the trial offer until the trial is started, a trial
/// banner while it runs, and a blocking paywall once access has expired.
struct RootGateView<Content: View>: View {
    @EnvironmentObject private var access: AppAccess
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            // Block the app behind the paywall. This must come BEFORE the overlay:
            // applied after it, it also disabled the paywall's own buttons, so the
            // trial and unlock buttons did nothing.
            .allowsHitTesting(!access.isLocked)
            .accessibilityHidden(access.isLocked)
            .overlay { if access.isLocked { PaywallView(dismissable: false) } }
            .task { await access.start() }
            .animation(.easeInOut, value: access.state)
    }
}

/// A tappable capsule shown on the projects page while the trial runs.
struct TrialBanner: View {
    @EnvironmentObject private var access: AppAccess
    @State private var showPaywall = false

    var body: some View {
        Group {
            if case .trial(let days) = access.state {
                Button { showPaywall = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(days == 1 ? "Last day of your free trial" : "\(days) days left in your free trial")
                            .fontWeight(.medium)
                        Text("· Unlock")
                            .fontWeight(.semibold)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.tint.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .sheet(isPresented: $showPaywall) { PaywallView(dismissable: true) }
            }
        }
        .animation(.easeInOut, value: access.state)
    }
}

// MARK: - Paywall

/// The unlock screen, in one of three situations:
/// • a new user (trial not started): offers the free trial — stating its length,
///   what happens when it ends and the unlock price, as App Review requires before
///   a trial starts — or the unlock straight away;
/// • during the trial (`dismissable`): unlock early;
/// • after the trial: the blocking paywall.
struct PaywallView: View {
    /// When false (trial offer / trial expired) there is no close control and it
    /// can't be dismissed.
    let dismissable: Bool

    @EnvironmentObject private var access: AppAccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @State private var working = false

    private var store: EntitlementStore { access.store }
    private var isTrialOffer: Bool { !dismissable && access.state == .trialNotStarted }
    private var trialDays: Int { Int(Purchases.trialDuration / 86_400) }

    var body: some View {
        ZStack {
            Rectangle().fill(.background).opacity(0.98).ignoresSafeArea()

            // Scrolls only when the window is too short (the trial offer's text is
            // longer); otherwise the content sits centred.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 52, weight: .regular))
                            .foregroundStyle(.tint)

                        VStack(spacing: 8) {
                            Text(title)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                            Text(headline)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 420)

                        featureList

                        actions

                        if let error = store.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)
                        } else if storeUnavailable {
                            VStack(spacing: 8) {
                                Text("The App Store can't be reached right now. Please check your connection and try again.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Try Again", action: retry)
                                    .font(.footnote)
                                    .disabled(working)
                            }
                            .frame(maxWidth: 360)
                        }

                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if dismissable {
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding()
                    }
                    Spacer()
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .task { if store.product == nil { await store.loadProduct() } }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if isTrialOffer {
                Button(action: startTrial) {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text("Start \(trialDays)-Day Free Trial").fontWeight(.semibold)
                    }
                    .frame(maxWidth: 360)
                    .frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working || store.trialProduct == nil)

                Button(action: buy) {
                    Text(buyTitle(now: true))
                        .frame(maxWidth: 360)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(working || store.product == nil)
            } else {
                Button(action: buy) {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text(buyTitle(now: false)).fontWeight(.semibold)
                    }
                    .frame(maxWidth: 360)
                    .frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working || store.product == nil)
            }

            Button("Restore Purchase", action: restore)
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.tint)
                .disabled(working)
        }
    }

    private var storeUnavailable: Bool {
        guard !store.isLoadingProduct else { return false }
        return isTrialOffer ? (store.trialProduct == nil && store.product == nil) : store.product == nil
    }

    private var title: String {
        isTrialOffer ? "Try CinePlanner Free for \(trialDays) Days" : "CinePlanner — Full Version"
    }

    /// The unlock price as a phrase, e.g. "a one-time purchase of € 14,99".
    private var pricePhrase: String {
        if let price = store.displayPrice { return "a one-time purchase of \(price)" }
        return "a one-time purchase"
    }

    private var headline: String {
        if isTrialOffer {
            return "Use every feature free for \(trialDays) days. When the trial ends, opening and editing your projects requires the full version — \(pricePhrase). Your projects stay safely in iCloud either way."
        }
        if dismissable {
            return "Unlock the full version now and keep planning without limits."
        }
        return "Your free trial has ended. Unlock the full version to keep working on your projects."
    }

    private var footnote: String {
        if isTrialOffer {
            return "The trial is free and ends by itself — you're never charged automatically."
        }
        return "One-time purchase — no subscription."
    }

    private func buyTitle(now: Bool) -> String {
        let verb = now ? "Unlock Now" : "Unlock"
        if let price = store.displayPrice { return "\(verb) for \(price)" }
        return verb
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Unlimited projects, scenes and shot lists")
            row("Scene maps, camera and lighting planning")
            row("PDF and web export")
            row("iCloud sync across your devices")
        }
        .font(.callout)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func row(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text(text)
            Spacer(minLength: 0)
        }
    }

    private func startTrial() {
        working = true
        Task {
            store.lastError = nil
            if await store.startTrial(using: purchase) { await access.refresh() }
            working = false
        }
    }

    private func buy() {
        working = true
        Task {
            store.lastError = nil
            let ok = await store.purchase(using: purchase)
            working = false
            if ok {
                access.unlockedAfterPurchase()
                if dismissable { dismiss() }
            }
        }
    }

    private func restore() {
        working = true
        Task {
            store.lastError = nil
            await store.restore()
            if store.isPurchased {
                working = false
                access.unlockedAfterPurchase()
                if dismissable { dismiss() }
                return
            }
            // No unlock, but a trial started on another device (or before a
            // reinstall) comes back too.
            let wasLocked = access.isLocked
            await access.refresh()
            working = false
            if wasLocked, !access.isLocked { return }
            if store.lastError == nil {
                store.lastError = "No previous purchase found on this account."
            }
        }
    }

    private func retry() {
        working = true
        Task {
            store.lastError = nil
            await access.refresh()
            working = false
        }
    }
}
