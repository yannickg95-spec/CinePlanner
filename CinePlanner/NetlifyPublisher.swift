//
//  NetlifyPublisher.swift
//  CinePlanner
//
//  Publishes a built website folder to Netlify and returns a public link, using
//  the user's own Netlify account (their storage, not ours). Authentication is a
//  personal access token the user pastes once, kept in the Keychain.
//
//  Deploy uses Netlify's file-digest API: POST a manifest of path → SHA1, upload
//  the files Netlify asks for, then poll until live. (POSTing a raw zip is NOT a
//  Netlify feature — it just stores the zip as one file at "/".)
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
    /// Forget the site tied to a project, so the next publish creates a new one.
    static func forgetSite(forProjectUID uid: String) {
        UserDefaults.standard.removeObject(forKey: "netlifySite-\(uid)")
    }

    // MARK: - Publish

    struct Result { let url: String; let siteID: String; let adminURL: String? }

    /// Walks `siteDirectory`, hashes each file, and deploys via the digest API.
    /// Creates a Netlify site the first time; reuses `existingSiteID` afterwards so
    /// the link is stable.
    static func publish(siteDirectory: URL, existingSiteID: String?, projectUID: String) async throws -> Result {
        guard let token = token else { throw NetlifyError.notAuthenticated }

        // 1. Gather files ("/path" → bytes) and their SHA1 digests.
        let files = try collectFiles(in: siteDirectory)              // ["/index.html": Data, …]
        let digests = files.mapValues { sha1Hex($0) }

        // 2. Ensure a site exists; keep its stable URL.
        let siteID: String
        let siteURL: String
        var adminURL: String?
        if let existingSiteID {
            siteID = existingSiteID
            siteURL = try await fetchSiteURL(siteID: existingSiteID, token: token)
        } else {
            let site = try await createSite(token: token)
            siteID = site.id; siteURL = site.url; adminURL = site.adminURL
            saveSiteID(siteID, forProjectUID: projectUID)
        }

        // 3. Create the deploy from the manifest; upload the files Netlify needs
        //    (it dedupes ones it already has).
        let (deployID, required) = try await createDeployDigest(siteID: siteID, files: digests, token: token)
        let needed = Set(required)
        for (path, data) in files where needed.contains(digests[path] ?? "") {
            try await uploadFile(deployID: deployID, path: path, data: data, token: token)
        }

        // 4. Wait until the deploy is live.
        await waitForDeploy(deployID: deployID, token: token)
        return Result(url: siteURL, siteID: siteID, adminURL: adminURL)
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

    private static func createSite(token: String) async throws -> (id: String, url: String, adminURL: String?) {
        var request = URLRequest(url: base.appending(path: "sites"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = "{}".data(using: .utf8)
        let json = try await sendJSON(request)
        guard let id = json["id"] as? String,
              let url = (json["ssl_url"] ?? json["url"]) as? String else { throw NetlifyError.badResponse }
        return (id, url, json["admin_url"] as? String)
    }

    private static func fetchSiteURL(siteID: String, token: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "sites/\(siteID)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await sendJSON(request)
        guard let url = (json["ssl_url"] ?? json["url"]) as? String else { throw NetlifyError.badResponse }
        return url
    }

    /// Creates a deploy from a path→SHA1 manifest, returning the deploy id and the
    /// SHA1s Netlify still needs uploaded.
    private static func createDeployDigest(siteID: String, files: [String: String], token: String)
        async throws -> (id: String, required: [String]) {
        var request = URLRequest(url: base.appending(path: "sites/\(siteID)/deploys"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["files": files])
        let json = try await sendJSON(request)
        guard let id = json["id"] as? String else { throw NetlifyError.badResponse }
        return (id, (json["required"] as? [String]) ?? [])
    }

    /// Uploads one file's bytes to a deploy. Manifest keys carry a leading slash;
    /// the upload URL appends it after /files.
    private static func uploadFile(deployID: String, path: String, data: Data, token: String) async throws {
        var request = URLRequest(url: base.appending(path: "deploys/\(deployID)/files\(path)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        _ = try await sendRaw(request)
    }

    /// Polls the deploy until Netlify reports it live ("ready"). Never throws — the
    /// site URL is valid regardless; the deploy just finishes uploading shortly after.
    private static func waitForDeploy(deployID: String, token: String) async {
        for _ in 0..<60 {   // ~60s
            var request = URLRequest(url: base.appending(path: "deploys/\(deployID)"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let json = try? await sendJSON(request) else { return }
            if (json["state"] as? String) == "ready" { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Transport

    /// URLSession drops the method and body on a 301/302/303 redirect (POST → GET,
    /// no body) — which silently produced empty deploys. NetlifyRedirectPreserver
    /// re-attaches the original method, body and headers so a redirect can't strip
    /// them.
    private static let session = URLSession(configuration: .default,
                                            delegate: NetlifyRedirectPreserver(), delegateQueue: nil)

    @discardableResult
    private static func sendRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetlifyError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NetlifyError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        try await sendRaw(request).0
    }

    private static func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetlifyError.badResponse
        }
        return json
    }
}

// MARK: - Redirect-preserving delegate

private final class NetlifyRedirectPreserver: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest else { completionHandler(request); return }
        var req = request
        req.httpMethod = original.httpMethod
        req.httpBody = original.httpBody
        original.allHTTPHeaderFields?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        completionHandler(req)
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
