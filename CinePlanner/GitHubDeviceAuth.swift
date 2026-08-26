//
//  GitHubDeviceAuth.swift
//  CinePlanner
//
//  GitHub OAuth "device flow": the user authorizes CinePlanner by entering a short
//  code at github.com/login/device — no personal-access-token to create or paste.
//  Needs a GitHub OAuth App (with "Enable Device Flow" ticked); paste its public
//  Client ID into `clientID` below. Everything else here is server-less: the whole
//  handshake runs from the app against github.com.
//

import Foundation

enum GitHubDeviceAuth {
    /// The OAuth App's public Client ID. Create an OAuth App on GitHub
    /// (Settings → Developer settings → OAuth Apps → New), tick "Enable Device
    /// Flow", and paste its Client ID here. Until then, the publish sheet falls
    /// back to manual token entry.
    static let clientID = "Ov23liY7IkQ1Yu74sdtw"

    /// Scopes the published-page workflow needs: create/push the repo and, for
    /// "Delete Published Page", remove it.
    static let scope = "public_repo delete_repo"

    static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "REPLACE_WITH_OAUTH_APP_CLIENT_ID"
    }

    struct DeviceCode {
        let deviceCode: String
        let userCode: String        // e.g. "WDJB-MJHT" — what the user types on GitHub
        let verificationURI: String // usually https://github.com/login/device
        let interval: Int           // seconds to wait between polls
        let expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case notConfigured, denied, expired, network, badResponse, message(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "GitHub sign-in isn't configured in this build."
            case .denied:        return "Authorization was declined on GitHub."
            case .expired:       return "The code expired before it was entered. Try connecting again."
            case .network:       return "Couldn't reach GitHub. Check your connection and try again."
            case .badResponse:   return "GitHub returned an unexpected response."
            case .message(let m): return m
            }
        }
    }

    private static let session = URLSession(configuration: .default)

    /// Step 1: ask GitHub for a device + user code.
    static func requestDeviceCode() async throws -> DeviceCode {
        guard isConfigured else { throw AuthError.notConfigured }
        let json = try await postForm(
            "https://github.com/login/device/code",
            ["client_id": clientID, "scope": scope])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else { throw AuthError.badResponse }
        let interval = (json["interval"] as? Int) ?? 5
        let expiresIn = (json["expires_in"] as? Int) ?? 900
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURI: uri,
                          interval: max(1, interval), expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)))
    }

    /// Step 2: poll until the user authorizes on GitHub, then return the token.
    /// Honours task cancellation (so dismissing the sheet stops polling).
    static func pollForToken(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Date() >= code.expiresAt { throw AuthError.expired }
            let json = try await postForm(
                "https://github.com/login/oauth/access_token",
                ["client_id": clientID,
                 "device_code": code.deviceCode,
                 "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            if let token = json["access_token"] as? String, !token.isEmpty { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue          // not entered yet
            case "slow_down":             interval += 5      // GitHub asked us to back off
            case "expired_token":         throw AuthError.expired
            case "access_denied":         throw AuthError.denied
            case let other?:              throw AuthError.message((json["error_description"] as? String) ?? other)
            case nil:                     throw AuthError.badResponse
            }
        }
    }

    // MARK: - HTTP

    private static func postForm(_ urlString: String, _ params: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw AuthError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AuthError.network
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.badResponse
        }
        return json
    }
}
