//
//  EntitlementStore.swift
//  CinePlanner
//
//  StoreKit 2 wrapper for the one-time "CinePlanner Pro" unlock: loads the
//  product, runs the purchase/restore flows, reports whether the app is unlocked,
//  and exposes the App Store data used for grandfathering and trusted time.
//

import Foundation
import Combine
import StoreKit

@MainActor
final class EntitlementStore: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var isPurchased = false
    @Published private(set) var isLoadingProduct = false
    @Published var lastError: String?

    /// Localised price string for the UI ("€ 14,99"), or nil until the product loads.
    var displayPrice: String? { product?.displayPrice }

    // MARK: - Loading

    func loadProduct() async {
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            let products = try await Product.products(for: [Purchases.proProductID])
            product = products.first
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// True if a valid, un-revoked entitlement for the unlock exists.
    func refreshPurchased() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Purchases.proProductID,
               transaction.revocationDate == nil {
                isPurchased = true
                return
            }
        }
        isPurchased = false
    }

    // MARK: - Buying / restoring

    /// Returns true if the purchase completed and the app is now unlocked.
    @discardableResult
    func purchase() async -> Bool {
        guard let product else {
            lastError = "The purchase isn't available right now. Please try again later."
            return false
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "The purchase couldn't be verified."
                    return false
                }
                await transaction.finish()
                isPurchased = true
                return true
            case .userCancelled:
                return false
            case .pending:
                lastError = "Your purchase is awaiting approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
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
    static func isGrandfathered() async -> Bool {
        guard let result = try? await AppTransaction.shared,
              case .verified(let appTransaction) = result else { return false }
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
