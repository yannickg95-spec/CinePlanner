//
//  PaywallView.swift
//  CinePlanner
//
//  The unlock screen and the gate that wraps the app. During the trial a slim
//  banner offers to unlock early; once the trial has expired the paywall covers
//  the app and can't be dismissed until the one-time purchase is made or restored.
//

import SwiftUI

// MARK: - Gate

/// Wraps the app's content: shows a trial banner while the trial runs, and a
/// blocking paywall once access has expired.
struct RootGateView<Content: View>: View {
    @EnvironmentObject private var access: AppAccess
    @State private var showTrialPaywall = false
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .overlay(alignment: .top) { trialBanner }
            .overlay { if access.isLocked { PaywallView(dismissable: false) } }
            .allowsHitTesting(!access.isLocked)   // block the app behind the paywall
            .task { await access.start() }
            .sheet(isPresented: $showTrialPaywall) { PaywallView(dismissable: true) }
            .animation(.easeInOut, value: access.state)
    }

    @ViewBuilder private var trialBanner: some View {
        if case .trial(let days) = access.state {
            Button { showTrialPaywall = true } label: {
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
        }
    }
}

// MARK: - Paywall

struct PaywallView: View {
    /// When false (trial expired) there is no close control and it can't be dismissed.
    let dismissable: Bool

    @EnvironmentObject private var access: AppAccess
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private var store: EntitlementStore { access.store }

    var body: some View {
        ZStack {
            Rectangle().fill(.background).opacity(0.98).ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer(minLength: 0)

                Image(systemName: "film.stack")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("CinePlanner — Full Version")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)

                featureList

                VStack(spacing: 10) {
                    Button(action: buy) {
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Text(buyTitle).fontWeight(.semibold)
                        }
                        .frame(maxWidth: 360)
                        .frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working || store.product == nil)

                    Button("Restore Purchase", action: restore)
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .disabled(working)
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Text("One-time purchase — no subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(28)

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

    private var headline: String {
        if dismissable {
            return "Unlock the full version now and keep planning without limits."
        }
        return "Your free trial has ended. Unlock the full version to keep working on your projects."
    }

    private var buyTitle: String {
        if let price = store.displayPrice { return "Unlock for \(price)" }
        return "Unlock"
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

    private func buy() {
        working = true
        Task {
            store.lastError = nil
            let ok = await store.purchase()
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
            working = false
            if store.isPurchased {
                access.unlockedAfterPurchase()
                if dismissable { dismiss() }
            } else if store.lastError == nil {
                store.lastError = "No previous purchase found on this account."
            }
        }
    }
}
