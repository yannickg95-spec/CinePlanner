//
//  GitHubPublisher.swift
//  CinePlanner
//
//  Publishes a built website folder to GitHub Pages and returns a public link,
//  using the user's own GitHub account. Authentication is a personal access
//  token the user pastes once, kept in the Keychain.
//
//  Each project gets its own public repo (URL: <login>.github.io/<repo>/). A
//  publish is an atomic commit via the Git Data API — blobs for each file, one
//  tree (no base, so old media is dropped), one commit, then move the branch.
//  Pages is enabled on first publish; GitHub then *builds* the site, which is
//  the slow part (tens of seconds), so callers should warn the user.
//

import Foundation

enum GitHubError: LocalizedError {
    case notAuthenticated
    case http(Int, String)
    case badResponse
    case pagesBuildFailed
    case fileTooLarge(name: String, bytes: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "No GitHub token. Add one to publish."
        case .http(let code, let message):
            // GitHub packs a human message into the JSON body — surface it.
            let detail = Self.messageField(from: message)
            return "GitHub returned an error (\(code))." + (detail.map { " \($0)" } ?? "")
        case .badResponse: return "Unexpected response from GitHub."
        case .pagesBuildFailed: return "GitHub couldn't build the page. Check the repository's Pages settings."
        case .fileTooLarge(let name, let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "“%@” is %.0f MB, over GitHub's 100 MB limit even after compression. Trim or shorten that video, then publish again.", name, mb)
        }
    }

    private static func messageField(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["message"] as? String
    }
}

/// Coarse progress through a publish, used to drive the sheet's progress bar.
enum GitHubPublishPhase: Equatable {
    case preparing
    case compressing(done: Int, total: Int)
    case uploading(done: Int, total: Int)
    case enablingPages
    case building(seconds: Int)

    /// 0…1 for a determinate bar. The build phase eases toward — but never
    /// reaches — full, so the bar only completes once the link is really live.
    var fraction: Double {
        switch self {
        case .preparing: return 0.03
        case .compressing(let done, let total):
            let p = total > 0 ? Double(done) / Double(total) : 0
            return 0.04 + 0.05 * p                    // 0.04 → 0.09
        case .uploading(let done, let total):
            let p = total > 0 ? Double(done) / Double(total) : 0
            return 0.10 + 0.45 * p                    // 0.10 → 0.55
        case .enablingPages: return 0.58
        case .building(let seconds):
            let t = min(Double(seconds) / 35.0, 1.0)  // ~35s typical build
            return 0.60 + 0.37 * t                    // 0.60 → 0.97
        }
    }

    var label: String {
        switch self {
        case .preparing: return "Preparing files…"
        case .compressing(let done, let total):
            return total > 1 ? "Compressing video (\(done)/\(total))…" : "Compressing video…"
        case .uploading(let done, let total):
            return total > 1 ? "Uploading files (\(done)/\(total))…" : "Uploading…"
        case .enablingPages: return "Turning on GitHub Pages…"
        case .building(let seconds): return "GitHub is building the page… (\(seconds)s)"
        }
    }
}

/// Progress callback. May be invoked off the main thread, so the receiver is
/// responsible for hopping to the main actor before touching UI state.
typealias GitHubProgress = (GitHubPublishPhase) -> Void

enum GitHubPublisher {

    // MARK: - Token (Keychain)

    private static let tokenService = "com.cineplanner.github"
    private static let tokenAccount = "personal-access-token"

    static var hasToken: Bool { token != nil }

    static var token: String? {
        get { GHKeychain.read(service: tokenService, account: tokenAccount) }
        set {
            if let value = newValue, !value.isEmpty {
                GHKeychain.set(value, service: tokenService, account: tokenAccount)
            } else {
                GHKeychain.delete(service: tokenService, account: tokenAccount)
            }
        }
    }

    // MARK: - Per-project repo (so re-publishing keeps the same link)

    /// Stored as "owner/repo".
    static func savedRepo(forProjectUID uid: String) -> String? {
        UserDefaults.standard.string(forKey: "githubRepo-\(uid)")
    }
    private static func saveRepo(_ fullName: String, forProjectUID uid: String) {
        UserDefaults.standard.set(fullName, forKey: "githubRepo-\(uid)")
    }
    /// Forget the repo tied to a project, so the next publish creates a new one.
    static func forgetRepo(forProjectUID uid: String) {
        UserDefaults.standard.removeObject(forKey: "githubRepo-\(uid)")
    }

    // MARK: - Comments (Giscus / GitHub Discussions)

    static func commentsEnabled(forProjectUID uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: "githubComments-\(uid)")
    }
    static func setCommentsEnabled(_ on: Bool, forProjectUID uid: String) {
        UserDefaults.standard.set(on, forKey: "githubComments-\(uid)")
    }

    // MARK: - Publish

    struct Result {
        let url: String          // public Pages URL
        let repoFullName: String // "owner/repo"
        let repoURL: String      // github.com/owner/repo
        /// True when the Pages build finished within our wait; false means it's
        /// still building and the link will go live shortly.
        let isLive: Bool
    }

    /// Builds files from `siteDirectory`, commits them to the project's repo
    /// (creating it the first time), enables Pages, and waits for the build.
    static func publish(siteDirectory: URL, existingRepo: String?,
                        projectName: String, projectUID: String, enableComments: Bool = false,
                        onProgress: @escaping GitHubProgress = { _ in }) async throws -> Result {
        guard let token = token else { throw GitHubError.notAuthenticated }

        let login = try await fetchLogin(token: token)

        // 1. Resolve the repo (owner, name), creating it if this is the first publish.
        let owner: String
        let repo: String
        if let existingRepo, let slash = existingRepo.firstIndex(of: "/") {
            owner = String(existingRepo[..<slash])
            repo = String(existingRepo[existingRepo.index(after: slash)...])
            try await ensureRepoExists(owner: owner, repo: repo, token: token)
        } else {
            owner = login
            repo = try await createRepo(desiredName: repoName(for: projectName), token: token)
            saveRepo("\(owner)/\(repo)", forProjectUID: projectUID)
        }

        // 1b. Optionally wire up Giscus comments (GitHub Discussions). Best effort:
        //     the page still publishes if this can't be set up. Comments render once
        //     the giscus GitHub App is installed on the repo (a one-time user step).
        if enableComments {
            try? await enableDiscussions(owner: owner, repo: repo, token: token)
            if let cfg = try? await giscusConfig(owner: owner, repo: repo, token: token) {
                injectGiscus(into: siteDirectory, owner: owner, repo: repo, config: cfg)
            }
        }

        // 2. Gather files (relative paths, no leading slash) plus a .nojekyll marker
        //    so Pages serves the folder verbatim instead of running it through Jekyll.
        var files = try collectFiles(in: siteDirectory)
        files[".nojekyll"] = Data()

        // Backstop: an oversized video that even the smallest transcode couldn't
        // shrink (a very long clip) would make GitHub reject the whole push. Catch
        // it here with a clear, per-file message instead.
        let hardLimit = 100 * 1_024 * 1_024
        if let big = files.max(by: { $0.value.count < $1.value.count }), big.value.count > hardLimit {
            let name = big.key.split(separator: "/").last.map(String.init) ?? big.key
            throw GitHubError.fileTooLarge(name: name, bytes: big.value.count)
        }

        // 3. Atomic commit via the Git Data API.
        try await commitFiles(owner: owner, repo: repo, files: files, token: token, onProgress: onProgress)

        // 4. Enable Pages if it isn't already, and learn the public URL.
        onProgress(.enablingPages)
        let pagesURL = try await ensurePages(owner: owner, repo: repo, token: token)
            ?? "https://\(owner.lowercased()).github.io/\(repo)/"

        // 5. Wait for the build so we only hand back a link that's actually live.
        let isLive = await waitForPagesBuild(owner: owner, repo: repo, token: token, onProgress: onProgress)

        return Result(url: pagesURL,
                      repoFullName: "\(owner)/\(repo)",
                      repoURL: "https://github.com/\(owner)/\(repo)",
                      isLive: isLive)
    }

    // MARK: - Repo

    private static func fetchLogin(token: String) async throws -> String {
        let json = try await sendJSON(get("user", token: token))
        guard let login = json["login"] as? String else { throw GitHubError.badResponse }
        return login
    }

    /// A URL-safe, unique-ish repo name from the project title.
    private static func repoName(for projectName: String) -> String {
        let slug = projectName.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && (acc.isEmpty || acc.hasSuffix("-")) { return }
                acc.append(ch)
            }
        let base = slug.isEmpty ? "shotlist" : String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return "\(base.isEmpty ? "shotlist" : base)-\(suffix)"
    }

    private static func ensureRepoExists(owner: String, repo: String, token: String) async throws {
        let (_, http) = try await rawSend(get("repos/\(owner)/\(repo)", token: token))
        if http.statusCode == 200 { return }
        // The saved repo is gone (deleted on GitHub) — make a fresh one under the caller's account.
        _ = try await createRepo(desiredName: repo, token: token)
    }

    /// Creates a public, auto-initialised repo. Retries once with a new suffix on
    /// a name collision. Returns the actual repo name used.
    private static func createRepo(desiredName: String, token: String) async throws -> String {
        var lastBody = ""
        var lastStatus = 0
        for attempt in 0..<2 {
            let name = attempt == 0 ? desiredName : desiredName + "-" + String(UUID().uuidString.prefix(4)).lowercased()
            var request = post("user/repos", token: token)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "name": name,
                "private": false,
                "auto_init": true,
                "description": "Published from CinePlanner",
            ])
            let (data, http) = try await rawSend(request)
            if (200..<300).contains(http.statusCode) { return name }
            lastStatus = http.statusCode
            lastBody = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 422 { continue }   // name taken — retry with a suffix
            break
        }
        throw GitHubError.http(lastStatus, lastBody)
    }

    // MARK: - Commit (Git Data API)

    private static func commitFiles(owner: String, repo: String, files: [String: Data],
                                    token: String, onProgress: @escaping GitHubProgress) async throws {
        let repoPath = "repos/\(owner)/\(repo)"

        // Current tip of the default branch (auto_init leaves "main" with one commit).
        let refJSON = try await sendJSON(get("\(repoPath)/git/ref/heads/main", token: token))
        guard let headSHA = ((refJSON["object"] as? [String: Any])?["sha"]) as? String else {
            throw GitHubError.badResponse
        }

        // A blob per file, uploaded concurrently — a big win when there are videos.
        // Blobs are content-addressed, so order doesn't matter; we collect
        // (path, sha) as each finishes and report progress.
        let total = files.count
        onProgress(.uploading(done: 0, total: total))
        var tree: [[String: Any]] = []
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for (path, data) in files {
                group.addTask {
                    (path, try await uploadBlob(repoPath: repoPath, data: data, token: token))
                }
            }
            var done = 0
            for try await (path, sha) in group {
                done += 1
                onProgress(.uploading(done: done, total: total))
                tree.append(["path": path, "mode": "100644", "type": "blob", "sha": sha])
            }
        }

        // A tree with no base — it contains exactly these files, dropping anything
        // left from a previous publish (old videos, renamed pages).
        var treeReq = post("\(repoPath)/git/trees", token: token)
        treeReq.httpBody = try JSONSerialization.data(withJSONObject: ["tree": tree])
        let treeJSON = try await sendJSON(treeReq)
        guard let treeSHA = treeJSON["sha"] as? String else { throw GitHubError.badResponse }

        // Commit on top of the current tip, then move the branch to it.
        var commitReq = post("\(repoPath)/git/commits", token: token)
        commitReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": "Publish shot list from CinePlanner",
            "tree": treeSHA,
            "parents": [headSHA],
        ])
        let commitJSON = try await sendJSON(commitReq)
        guard let commitSHA = commitJSON["sha"] as? String else { throw GitHubError.badResponse }

        var refReq = patch("\(repoPath)/git/refs/heads/main", token: token)
        refReq.httpBody = try JSONSerialization.data(withJSONObject: ["sha": commitSHA, "force": true])
        _ = try await sendRaw(refReq)
    }

    /// Uploads one file's bytes as a base64 blob, returning its SHA.
    private static func uploadBlob(repoPath: String, data: Data, token: String) async throws -> String {
        var request = post("\(repoPath)/git/blobs", token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content": data.base64EncodedString(),
            "encoding": "base64",
        ])
        let blob = try await sendJSON(request)
        guard let sha = blob["sha"] as? String else { throw GitHubError.badResponse }
        return sha
    }

    // MARK: - Pages

    /// Enables Pages (branch main, root) if needed. Returns the public URL GitHub
    /// reports, when available.
    private static func ensurePages(owner: String, repo: String, token: String) async throws -> String? {
        let repoPath = "repos/\(owner)/\(repo)"
        if let (data, http) = try? await sendRaw(get("\(repoPath)/pages", token: token)), http.statusCode == 200 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return json?["html_url"] as? String
        }
        // Not enabled yet — turn it on.
        var request = post("\(repoPath)/pages", token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "source": ["branch": "main", "path": "/"],
        ])
        let (data, _) = try await sendRaw(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["html_url"] as? String
    }

    // MARK: - Comments (Giscus / GitHub Discussions)

    struct GiscusConfig { let repoID: String; let categoryID: String; let categoryName: String }

    /// Turns on the repo's Discussions feature (giscus stores comments there).
    private static func enableDiscussions(owner: String, repo: String, token: String) async throws {
        var request = patch("repos/\(owner)/\(repo)", token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["has_discussions": true])
        _ = try await sendRaw(request)
    }

    /// Fetches the repo's node id and a discussion category (via GraphQL) — the ids
    /// giscus needs. Prefers "Announcements" so visitors comment but can't open new
    /// top-level threads; falls back to "General" or the first category.
    private static func giscusConfig(owner: String, repo: String, token: String) async throws -> GiscusConfig {
        let query = """
        query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id \
        discussionCategories(first:25){nodes{id name}}}}
        """
        var request = URLRequest(url: base.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("CinePlanner", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": ["owner": owner, "name": repo],
        ])
        let (data, _) = try await sendRaw(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (json["data"] as? [String: Any])?["repository"] as? [String: Any],
              let repoID = repository["id"] as? String,
              let nodes = (repository["discussionCategories"] as? [String: Any])?["nodes"] as? [[String: Any]]
        else { throw GitHubError.badResponse }

        func category(_ name: String) -> [String: Any]? {
            nodes.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let chosen = category("Announcements") ?? category("General") ?? nodes.first,
              let categoryID = chosen["id"] as? String,
              let categoryName = chosen["name"] as? String
        else { throw GitHubError.badResponse }
        return GiscusConfig(repoID: repoID, categoryID: categoryID, categoryName: categoryName)
    }

    /// Injects the giscus widget before </body> in the site's index.html.
    private static func injectGiscus(into siteDirectory: URL, owner: String, repo: String, config: GiscusConfig) {
        let indexURL = siteDirectory.appendingPathComponent("index.html")
        guard var html = try? String(contentsOf: indexURL, encoding: .utf8) else { return }
        let snippet = """
        <section style="max-width:900px;margin:48px auto 24px;padding:0 20px;">
          <h2 style="font:600 20px system-ui,-apple-system,sans-serif;margin:0 0 12px;">Comments</h2>
          <script src="https://giscus.app/client.js"
            data-repo="\(owner)/\(repo)"
            data-repo-id="\(config.repoID)"
            data-category="\(config.categoryName)"
            data-category-id="\(config.categoryID)"
            data-mapping="pathname"
            data-strict="0"
            data-reactions-enabled="1"
            data-emit-metadata="0"
            data-input-position="top"
            data-theme="preferred_color_scheme"
            data-lang="en"
            crossorigin="anonymous"
            async>
          </script>
        </section>
        """
        if let range = html.range(of: "</body>", options: .backwards) {
            html.replaceSubrange(range, with: snippet + "\n</body>")
        } else {
            html += snippet
        }
        try? html.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    /// Polls the latest Pages build until it reports "built". Returns false if it
    /// errors or we time out (the link is still valid; the build just isn't done).
    private static func waitForPagesBuild(owner: String, repo: String, token: String,
                                          onProgress: @escaping GitHubProgress) async -> Bool {
        let path = "repos/\(owner)/\(repo)/pages/builds/latest"
        let start = Date()
        for _ in 0..<60 {   // ~2 min at 2s
            onProgress(.building(seconds: Int(Date().timeIntervalSince(start))))
            if let (data, http) = try? await rawSend(get(path, token: token)), http.statusCode == 200 {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                switch json?["status"] as? String {
                case "built": return true
                case "errored": return false
                default: break   // "building"/"queued"/null — keep waiting
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    // MARK: - Files

    private static func collectFiles(in root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let rootCount = root.resolvingSymlinksInPath().pathComponents.count
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let comps = url.resolvingSymlinksInPath().pathComponents.dropFirst(rootCount)
            result[comps.joined(separator: "/")] = try Data(contentsOf: url)   // "index.html", "media/…"
        }
        return result
    }

    // MARK: - Transport

    private static let base = URL(string: "https://api.github.com")!
    private static let session = URLSession(configuration: .default)

    private static func request(_ path: String, method: String, token: String) -> URLRequest {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("CinePlanner", forHTTPHeaderField: "User-Agent")   // GitHub rejects requests without one
        return req
    }
    private static func get(_ p: String, token: String) -> URLRequest { request(p, method: "GET", token: token) }
    private static func post(_ p: String, token: String) -> URLRequest {
        var r = request(p, method: "POST", token: token)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }
    private static func patch(_ p: String, token: String) -> URLRequest {
        var r = request(p, method: "PATCH", token: token)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// Sends a request and returns the response without judging the status code —
    /// existence checks and creation need to read 404/422 without throwing.
    private static func rawSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.badResponse }
        return (data, http)
    }

    /// Like `rawSend`, but throws on any non-2xx status.
    @discardableResult
    private static func sendRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await rawSend(request)
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    private static func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await sendRaw(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.badResponse
        }
        return json
    }
}

// MARK: - Minimal Keychain string store

private enum GHKeychain {
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
