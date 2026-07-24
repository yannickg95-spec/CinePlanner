//
//  NetlifyPublisher.swift
//  CinePlanner
//
//  Publishes a built website folder to Netlify and returns a public link, using
//  the user's own Netlify account (their storage, not ours). Authentication is a
//  personal access token the user pastes once, kept in the Keychain.
//
//  Deploy uses Netlify's file-digest API: send a manifest of path → SHA1, upload
//  only the files Netlify asks for, then poll until the deploy is live. No zip,
//  so file paths (index.html, media/…) are explicit.
//

import Foundation
import CryptoKit

enum NetlifyError: LocalizedError {
    case notAuthenticated
    case http(Int, String)
    case badResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "No Netlify token. Add one to publish."
        case .http(let code, let message):
            return "Netlify returned an error (\(code)). \(message)"
        case .badResponse: return "Unexpected response from Netlify."
        case .timedOut: return "The deploy took too long to go live."
        }
    }
}

enum NetlifyPublisher {

    // MARK: - Token (Keychain)

    private static let tokenService = "com.cineplanner.netlify"
    private static let tokenAccount = "personal-access-token"

    static var hasToken: Bool { token != nil }

    static var token: String? {
        get { Keychain.read(service: tokenService, account: tokenAccount) }
        set {
            if let value = newValue, !value.isEmpty {
                Keychain.set(value, service: tokenService, account: tokenAccount)
            } else {
                Keychain.delete(service: tokenService, account: tokenAccount)
            }
        }
    }

    // MARK: - Per-project site id (so re-publishing keeps the same link)

    static func savedSiteID(forProjectUID uid: String) -> String? {
        UserDefaults.standard.string(forKey: "netlifySite-\(uid)")
    }
    private static func saveSiteID(_ id: String, forProjectUID uid: String) {
        UserDefaults.standard.set(id, forKey: "netlifySite-\(uid)")
    }

    // MARK: - Publish

    struct Result { let url: String; let siteID: String }

    /// Zips nothing — walks `siteDirectory`, hashes each file, and deploys via the
    /// digest API. Creates a Netlify site the first time; reuses `existingSiteID`
    /// afterwards so the link is stable.
    static func publish(siteDirectory: URL, existingSiteID: String?, projectUID: String) async throws -> Result {
        guard let token = token else { throw NetlifyError.notAuthenticated }

        // 1. Gather files as "/path" → bytes, and their SHA1 digests.
        let files = try collectFiles(in: siteDirectory)              // ["/index.html": Data, …]
        let digests = files.mapValues { sha1Hex($0) }                // ["/index.html": "<sha1>", …]

        // 2. Ensure a site exists; keep its stable URL.
        let siteID: String
        let siteURL: String
        if let existingSiteID {
            siteID = existingSiteID
            siteURL = try await fetchSiteURL(siteID: existingSiteID, token: token)
        } else {
            (siteID, siteURL) = try await createSite(token: token)
            saveSiteID(siteID, forProjectUID: projectUID)
        }

        // 3. Create a deploy with the manifest; Netlify replies with the digests it needs.
        let deploy = try await createDeploy(siteID: siteID, files: digests, token: token)

        // 4. Upload the files Netlify asked for (matched by digest).
        let required = Set(deploy.required)
        for (path, data) in files where required.contains(digests[path] ?? "") {
            try await uploadFile(deployID: deploy.id, path: path, data: data, token: token)
        }

        // 5. Wait until the deploy is live, then hand back the site's stable URL.
        try await waitForDeploy(deployID: deploy.id, token: token)
        return Result(url: siteURL, siteID: siteID)
    }

    // MARK: - Files

    private static func collectFiles(in root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        // Compute the relative path from resolved components, not string-replacing
        // root.path: on macOS temporaryDirectory can be /var/… while the walker
        // yields /private/var/… (the /var symlink), so a plain replace fails.
        let rootCount = root.resolvingSymlinksInPath().pathComponents.count
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return result
        }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let comps = url.resolvingSymlinksInPath().pathComponents.dropFirst(rootCount)
            let path = "/" + comps.joined(separator: "/")
            result[path] = try Data(contentsOf: url)
        }
        return result
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - API

    private static let base = URL(string: "https://api.netlify.com/api/v1")!

    private static func createSite(token: String) async throws -> (id: String, url: String) {
        var request = URLRequest(url: base.appending(path: "sites"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = "{}".data(using: .utf8)
        let json = try await sendJSON(request)
        guard let id = json["id"] as? String else { throw NetlifyError.badResponse }
        let url = (json["ssl_url"] ?? json["url"]) as? String ?? "https://\(id).netlify.app"
        return (id, url)
    }

    private static func fetchSiteURL(siteID: String, token: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "sites/\(siteID)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await sendJSON(request)
        guard let url = (json["ssl_url"] ?? json["url"]) as? String else { throw NetlifyError.badResponse }
        return url
    }

    private struct DeployInfo { let id: String; let required: [String] }

    private static func createDeploy(siteID: String, files: [String: String], token: String) async throws -> DeployInfo {
        var request = URLRequest(url: base.appending(path: "sites/\(siteID)/deploys"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["files": files])
        let json = try await sendJSON(request)
        guard let id = json["id"] as? String else { throw NetlifyError.badResponse }
        let required = (json["required"] as? [String]) ?? []
        return DeployInfo(id: id, required: required)
    }

    private static func uploadFile(deployID: String, path: String, data: Data, token: String) async throws {
        // path already begins with "/"; the API wants it appended after /files.
        var request = URLRequest(url: base.appending(path: "deploys/\(deployID)/files\(path)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        _ = try await send(request)
    }

    /// Polls the deploy until Netlify reports it live ("ready"). Doesn't throw on
    /// timeout — the site URL is valid regardless; the deploy just finishes soon.
    private static func waitForDeploy(deployID: String, token: String) async throws {
        for _ in 0..<60 {   // ~60s
            var request = URLRequest(url: base.appending(path: "deploys/\(deployID)"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let json = try await sendJSON(request)
            if (json["state"] as? String) == "ready" { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Transport

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetlifyError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetlifyError.http(http.statusCode, body)
        }
        return data
    }

    private static func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetlifyError.badResponse
        }
        return json
    }
}

// MARK: - Minimal Keychain string store

private enum Keychain {
    static func set(_ value: String, service: String, account: String) {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
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
        ]
        SecItemDelete(query as CFDictionary)
    }
}
