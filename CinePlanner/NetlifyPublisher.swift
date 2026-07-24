//
//  NetlifyPublisher.swift
//  CinePlanner
//
//  Publishes a built website folder to Netlify and returns a public link, using
//  the user's own Netlify account (their storage, not ours). Authentication is a
//  personal access token the user pastes once, kept in the Keychain.
//
//  Deploy uses Netlify's zip API: POST a zip of the site (files at the archive
//  root) and Netlify unzips and serves it. Simpler and more robust than the
//  file-digest API, which was finicky about path format.
//

import Foundation

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

    struct Result { let url: String; let siteID: String; let adminURL: String?; let diagnostics: String }

    /// Zips nothing — walks `siteDirectory`, hashes each file, and deploys via the
    /// digest API. Creates a Netlify site the first time; reuses `existingSiteID`
    /// afterwards so the link is stable.
    static func publish(siteDirectory: URL, existingSiteID: String?, projectUID: String) async throws -> Result {
        guard let token = token else { throw NetlifyError.notAuthenticated }
        var log: [String] = []

        // 1. Zip the site with files at the archive root (index.html at "/").
        let files = try collectFiles(in: siteDirectory)              // ["/index.html": Data, …]
        var zip = ZipArchive()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            zip.add(path: String(path.drop(while: { $0 == "/" })), contents: data)
        }
        let zipData = zip.finalize()
        log.append("Files (\(files.count)): \(files.keys.sorted().joined(separator: ", "))")
        log.append("Zip: \(zipData.count) bytes")

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
        log.append("Site: \(siteURL) (id \(siteID))")

        // 3. Deploy the zip — Netlify unzips and serves it.
        let (deployID, deployDiag) = try await deployZip(siteID: siteID, zip: zipData, token: token)
        log.append("Deploy \(deployID) created")
        log.append(deployDiag)

        // 4. Wait until the deploy is live, capturing its own URL and state.
        let deploy = await waitForDeploy(deployID: deployID, token: token)
        log.append("Final deploy state: \(deploy.state)")
        if let deployURL = deploy.deployURL { log.append("Deploy URL: \(deployURL)") }
        if let published = try? await publishedDeployID(siteID: siteID, token: token) {
            log.append("Site's published deploy: \(published) (this deploy: \(deployID))")
        }

        // Prefer the deploy-specific URL if the production URL isn't reflecting it.
        let link = deploy.deployURL ?? siteURL
        return Result(url: link, siteID: siteID, adminURL: adminURL, diagnostics: log.joined(separator: "\n"))
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

    private static func deployZip(siteID: String, zip: Data, token: String) async throws -> (id: String, diag: String) {
        var request = URLRequest(url: base.appending(path: "sites/\(siteID)/deploys"))
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = zip
        let (data, http) = try await sendRaw(request)
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard let id = json["id"] as? String else { throw NetlifyError.badResponse }
        var diag = ["Deploy POST: HTTP \(http.statusCode), landed on \(http.url?.absoluteString ?? "?")"]
        if let req = json["required"] as? [String] { diag.append("Deploy 'required' at create: \(req.count)") }
        if let state = json["state"] as? String { diag.append("Deploy state at create: \(state)") }
        return (id, diag.joined(separator: "\n"))
    }

    private struct DeployStatus { let state: String; let deployURL: String? }

    /// Polls the deploy until Netlify reports it live ("ready"), returning the
    /// last state and the deploy's own URL. Never throws.
    private static func waitForDeploy(deployID: String, token: String) async -> DeployStatus {
        var last = "unknown"
        var deployURL: String?
        for _ in 0..<60 {   // ~60s
            var request = URLRequest(url: base.appending(path: "deploys/\(deployID)"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let json = try? await sendJSON(request) else { break }
            last = (json["state"] as? String) ?? last
            deployURL = (json["deploy_ssl_url"] ?? json["deploy_url"] ?? json["ssl_url"]) as? String ?? deployURL
            if last == "ready" { return DeployStatus(state: last, deployURL: deployURL) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return DeployStatus(state: last, deployURL: deployURL)
    }

    private static func publishedDeployID(siteID: String, token: String) async throws -> String? {
        var request = URLRequest(url: base.appending(path: "sites/\(siteID)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await sendJSON(request)
        return (json["published_deploy"] as? [String: Any])?["id"] as? String
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
