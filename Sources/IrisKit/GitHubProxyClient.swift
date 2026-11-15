import Foundation

/// Talks to GitHub as Iris's own `iris-main` identity (#966): opens PRs, comments, and approves
/// *routine* (docs/assets) PRs, through three host-side proxy tools. The token lives in the
/// Keychain and is read only here — it never enters a prompt, tool arg, tool result, or error
/// string (spec §3, "spend, never possess"). Task 1 is the token lookup `ToolExecutor`'s
/// credential gate reads, Task 3 the create-PR and comment calls; the approve gate follows.
///
/// Every call checks the repo against the user's allowlist first and builds no request, reads no
/// token and touches no network for one that is not on it (spec §3.2). Everything returned to the
/// model goes through `sanitize`, which removes the token and bounds what GitHub said.
struct GitHubProxyClient {
    let keychain: KeychainManager
    let isRepoAllowed: @Sendable (String) -> Bool
    let transport: GitHubTransport

    init(keychain: KeychainManager = .shared,
         isRepoAllowed: @escaping @Sendable (String) -> Bool = { ConfigManager.shared.isGitHubRepoAllowed($0) },
         transport: GitHubTransport = URLSessionGitHubTransport()) {
        self.keychain = keychain
        self.isRepoAllowed = isRepoAllowed
        self.transport = transport
    }

    /// Whether the `iris-main` PAT is present. The credential gate for the three `github_*` tool
    /// declarations (Invariant 6): absent, the tools are not offered at all.
    static func hasToken(keychain: KeychainManager) -> Bool {
        token(keychain: keychain) != nil
    }

    /// The `iris-main` PAT, or nil if none is stored.
    static func token(keychain: KeychainManager) -> String? {
        let trimmed = keychain.secrets(service: KeychainManager.githubService)["token"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Calls

extension GitHubProxyClient {
    private static let apiBase = "https://api.github.com"
    /// Most of what GitHub says back that the model is shown, after cleaning.
    private static let maxShown = 300

    /// `POST /repos/{repo}/pulls`: opens a PR authored by the token's identity (`iris-main`).
    func createPR(repo: String, head: String, base: String, title: String, body: String, draft: Bool) async -> String {
        let payload: [String: Any] = ["title": title, "body": body, "head": head, "base": base, "draft": draft]
        switch await post(repo: repo, path: "pulls", payload: payload) {
        case .refused(let message): return message
        case .done(let json):
            let number = json["number"] as? Int
            let url = Self.githubURL(json["html_url"])
            var result = number.map { "Opened pull request #\($0)" } ?? "Opened pull request"
            if draft { result += " (draft)" }
            if let url { result += ": \(url)" }
            return sanitize(result, token: Self.token(keychain: keychain))
        }
    }

    /// `POST /repos/{repo}/issues/{pr}/comments`: a PR conversation comment.
    func comment(repo: String, pr: Int, body: String) async -> String {
        guard pr > 0 else { return "Refused: a pull request number must be positive." }
        switch await post(repo: repo, path: "issues/\(pr)/comments", payload: ["body": body]) {
        case .refused(let message): return message
        case .done(let json):
            let url = Self.githubURL(json["html_url"])
            return sanitize(url.map { "Posted comment: \($0)" } ?? "Posted comment.",
                            token: Self.token(keychain: keychain))
        }
    }

    private enum Outcome {
        case refused(String)
        case done([String: Any])
    }

    /// The one request path. Order matters: allowlist, repo shape, then the token, and only then a
    /// request, so a refused call has read nothing and sent nothing.
    private func post(repo: String, path: String, payload: [String: Any]) async -> Outcome {
        guard isRepoAllowed(repo) else {
            return .refused("Refused: repository \"\(Self.shown(repo))\" is not allowed for the GitHub tools. "
                            + "The user adds repositories to the allowed list; it is empty until they do.")
        }
        guard Self.isOwnerName(repo) else {
            return .refused("Refused: \"\(Self.shown(repo))\" is not an owner/name repository.")
        }
        guard let token = Self.token(keychain: keychain) else {
            return .refused("GitHub is not configured: no iris-main token is set.")
        }
        guard let url = URL(string: "\(Self.apiBase)/repos/\(repo)/\(path)"),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .refused("Refused: the request could not be built.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iris", forHTTPHeaderField: "User-Agent")

        do {
            let (responseData, response) = try await transport.send(request, bearer: token)
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
            guard (200..<300).contains(response.statusCode) else {
                let message = (json["message"] as? String).map { ": \($0)" } ?? ""
                return .refused(sanitize("GitHub returned HTTP \(response.statusCode)\(message)", token: token))
            }
            return .done(json)
        } catch is CancellationError {
            return .refused("The GitHub request was cancelled.")
        } catch {
            return .refused(sanitize("The GitHub request failed: \(error.localizedDescription)", token: token))
        }
    }

    /// Text for the model: the token and any bearer value removed, control characters and line
    /// breaks flattened, and the length bounded. GitHub's own words are untrusted text, so only a
    /// short, plain line of them is ever shown.
    func sanitize(_ text: String, token: String?) -> String {
        var cleaned = SecretScrub.scrub(text, token.map { [$0] } ?? [])
        cleaned = cleaned.replacingOccurrences(of: #"(?i)\bbearer\s+\S+"#, with: "Bearer [redacted]",
                                               options: .regularExpression)
        let flat = String(String.UnicodeScalarView(cleaned.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        return flat.count > Self.maxShown ? String(flat.prefix(Self.maxShown)) + "..." : flat
    }

    /// A model-supplied repo string as shown back in a refusal: short and on one line.
    private static func shown(_ repo: String) -> String {
        String(String.UnicodeScalarView(repo.unicodeScalars.prefix(100).map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }

    /// Exactly `owner/name`, each part letters, digits, `.`, `_` or `-`, never `.`/`..`: nothing
    /// that could change the path or add a query when spliced into the API URL.
    static func isOwnerName(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// A GitHub-hosted url from a response, or nil: the model is not handed an arbitrary link.
    private static func githubURL(_ value: Any?) -> String? {
        guard let text = value as? String, text.hasPrefix("https://github.com/") else { return nil }
        return text
    }
}

// MARK: - Transport

/// What `GitHubProxyClient` sends through. A seam so no test reaches the network, and so the one
/// place that puts the bearer on a request is small and separate.
protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse)
}

/// The real transport. It uses the session that refuses redirects: a redirect would replay the
/// `Authorization` header to wherever it points, and the API has no reason to send one.
struct URLSessionGitHubTransport: GitHubTransport {
    let session: URLSession

    init(session: URLSession = NoRedirectSessionDelegate.session) { self.session = session }

    func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
