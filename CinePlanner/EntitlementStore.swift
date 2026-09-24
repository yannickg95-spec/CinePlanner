//
//  EntitlementStore.swift
//  CinePlanner
//
//  StoreKit 2 wrapper for the one-time "CinePlanner Pro" unlock and the free
//  "7-day Trial" product: loads both, runs the purchase/restore flows, reports
//  whether the app is unlocked and when the trial started, and exposes the App
//  Store data used for grandfathering and trusted time.
//

import Foundation
import Combine
import StoreKit
import SwiftUI   // PurchaseAction (StoreKit's SwiftUI purchase action)

@MainActor
final class EntitlementStore: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var trialProduct: Product?
    @Published private(set) var isPurchased = false
    /// When the account started the trial (the trial purchase's date), if it has.
    @Published private(set) var trialStartDate: Date?
    @Published private(set) var isLoadingProduct = false
    @Published var lastError: String?

    /// Localised price string for the UI ("€ 14,99"), or nil until the product loads.
    var displayPrice: String? { product?.displayPrice }

    // MARK: - Loading

    func loadProduct() async {
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            let products = try await Product.products(for: [Purchases.proProductID, Purchases.trialProductID])
            product = products.first { $0.id == Purchases.proProductID }
            trialProduct = products.first { $0.id == Purchases.trialProductID }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reads the account's valid, un-revoked entitlements: the unlock, and the
    /// trial's start.
    func refreshPurchased() async {
        var purchased = false
        var trialStart: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case Purchases.proProductID: purchased = true
            case Purchases.trialProductID: trialStart = transaction.originalPurchaseDate
            default: break
            }
        }
        isPurchased = purchased
        // Keep a start we already know (from `startTrial`) when the entitlements
        // don't list the trial yet — the sandbox can lag right after the purchase,
        // which would bounce the user straight back to the trial offer.
        trialStartDate = trialStart ?? trialStartDate
    }

    // MARK: - Buying / restoring

    /// Returns true if the purchase completed and the app is now unlocked.
    /// `purchase` is the view's `@Environment(\.purchase)` action, which shows the
    /// App Store confirmation in that view's window (iPad and Mac need that).
    @discardableResult
    func purchase(using purchase: PurchaseAction) async -> Bool {
        guard let product else {
            lastError = "The purchase isn't available right now. Please try again later."
            return false
        }
        guard await buy(product, using: purchase) != nil else { return false }
        isPurchased = true
        return true
    }

    /// Starts the free trial by "buying" the free trial product. Returns true once
    /// the trial is running.
    @discardableResult
    func startTrial(using purchase: PurchaseAction) async -> Bool {
        guard let trialProduct else {
            lastError = "The free trial can't be started right now. Please check your connection and try again."
            return false
        }
        guard let transaction = await buy(trialProduct, using: purchase) else { return false }
        trialStartDate = transaction.originalPurchaseDate
        return true
    }

    /// Runs a purchase and returns its verified, finished transaction — nil when it
    /// was cancelled, is pending, or failed (with `lastError` set as needed).
    private func buy(_ product: Product, using purchase: PurchaseAction) async -> StoreKit.Transaction? {
        do {
            let result = try await purchase(product)
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "The purchase couldn't be verified."
                    return nil
                }
                await transaction.finish()
                return transaction
            case .userCancelled:
                return nil
            case .pending:
                lastError = "Your purchase is awaiting approval."
                return nil
            @unknown default:
                return nil
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshPurchased()
    }

    // MARK: - App Store account data (grandfathering + trusted time)

    /// People who first downloaded the app before it went free (i.e. paid up front)
    /// keep full access for free.
    ///
    /// Only for App Store downloads: in the sandbox (TestFlight, App Review) and in
    /// Xcode, `originalAppVersion` is always "1.0", which would read as a pre-free
    /// download and unlock everything — hiding the trial and the purchase from
    /// testers and from the reviewers who have to find it.
    static func isGrandfathered() async -> Bool {
        guard let result = try? await AppTransaction.shared,
              case .verified(let appTransaction) = result,
              appTransaction.environment == .production else { return false }
        let original = appTransaction.originalAppVersion
        if let build = Int(original) {
            // iOS: originalAppVersion is the build number.
            return build < Purchases.firstFreeBuild
        }
        // macOS: originalAppVersion is the short version string ("1.5").
        return isOlderVersion(original, than: Purchases.firstFreeShortVersion)
    }

    /// Apple's signed server time, used as a trusted reference for the trial clock.
    static func trustedNow() async -> Date? {
        guard let result = try? await AppTransaction.shared,
              case .verified(let appTransaction) = result else { return nil }
        return appTransaction.signedDate
    }

    /// Numeric dotted-version compare ("1.5" < "1.6").
    private static func isOlderVersion(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
