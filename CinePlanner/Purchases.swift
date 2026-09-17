//
//  Purchases.swift
//  CinePlanner
//
//  Option 2 monetisation: the app ships free, a one-time non-consumable in-app
//  purchase unlocks it permanently, and a 7-day trial precedes the paywall.
//  This file holds the shared constants, a synced-Keychain store, and the trial
//  clock (which resists reinstalls, a new install on another device of the same
//  iCloud account, and setting the system clock backwards).
//

import Foundation

enum Purchases {
    /// Non-consumable IAP that unlocks the full app. Create this exact product id
    /// in App Store Connect (matches the app's bundle id prefix).
    static let proProductID = "com.YannickGiraud.CinePlanner.pro"

    /// Length of the free trial before the paywall appears.
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Grandfathering for people who bought the app while it was still paid-up-front.
    /// `AppTransaction.originalAppVersion` is the version the account FIRST obtained:
    /// on iOS that is the build number (CFBundleVersion), on macOS the short version
    /// (CFBundleShortVersionString). A download from before the free switch unlocks
    /// the app for free forever.
    ///
    /// ⚠️ Set BOTH of these to the first release that ships free-with-IAP, before
    /// submitting that build — otherwise grandfathering will be wrong.
    static let firstFreeBuild = 6              // iOS: CFBundleVersion of the first free build
    static let firstFreeShortVersion = "1.6"  // macOS: CFBundleShortVersionString of it
}

// MARK: - Synced Keychain (same pattern as GHKeychain, shared across the user's devices)

/// A tiny generic-password store that syncs via iCloud Keychain, so the trial
/// state survives app deletion/reinstall and is shared across the account's devices.
enum SyncedKeychain {
    static func set(_ value: String, service: String, account: String) {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Trial clock

/// Tracks the free trial. The start is recorded once (preferring Apple's signed
/// server time so a clock set forward at first launch can't push it into the
/// future), and a "high-water" timestamp only ever moves forward, so setting the
/// clock back can't extend the trial.
enum TrialClock {
    private static let service = "com.YannickGiraud.CinePlanner.trial"
    private static let startAccount = "start"
    private static let highWaterAccount = "highwater"

    struct Status {
        var isActive: Bool
        var daysRemaining: Int   // whole days, at least 1 while active
    }

    private static func date(_ account: String) -> Date? {
        guard let s = SyncedKeychain.read(service: service, account: account),
              let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private static func store(_ d: Date, _ account: String) {
        SyncedKeychain.set(String(d.timeIntervalSince1970), service: service, account: account)
    }

    /// Evaluate the trial. `trustedNow` is Apple's signed server time when available.
    @discardableResult
    static func evaluate(trustedNow: Date?) -> Status {
        let deviceNow = Date()

        // Record the start once. Prefer trusted server time so a forward-set clock
        // can't create a future start (which would lengthen the trial).
        let start: Date
        if let existing = date(startAccount) {
            start = existing
        } else {
            start = trustedNow ?? deviceNow
            store(start, startAccount)
        }

        // Effective "now" never moves backwards.
        let previousHigh = date(highWaterAccount) ?? start
        var effectiveNow = max(deviceNow, previousHigh)
        if let trustedNow { effectiveNow = max(effectiveNow, trustedNow) }
        store(effectiveNow, highWaterAccount)

        let remaining = Purchases.trialDuration - effectiveNow.timeIntervalSince(start)
        let active = remaining > 0
        let days = active ? max(1, Int(ceil(remaining / 86_400))) : 0
        return Status(isActive: active, daysRemaining: days)
    }

    /// Wipes the stored trial (debug only).
    static func reset() {
        SyncedKeychain.delete(service: service, account: startAccount)
        SyncedKeychain.delete(service: service, account: highWaterAccount)
    }
}
