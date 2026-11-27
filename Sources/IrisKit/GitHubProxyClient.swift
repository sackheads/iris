import Foundation

/// Talks to GitHub as Iris's own account (#966; the login is the user's setting, #1184): opens PRs,
/// comments, and approves *routine* (docs/assets) PRs, through three host-side tools. The account is
/// Iris's own contributor credential (spec §3-§4): the goal is identity separation from `@bnaylor`, not
/// hiding the credential. The token is stored under its own Keychain service and this client
/// still keeps it out of every tool result and error string, as defence in depth. Approval is
/// the one locked-down axis: `CODEOWNERS` makes her approval count only for docs and assets, and
/// `approve` refuses anything else before it submits (spec §3.3).
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

    /// Whether the account's PAT is present. The credential gate for the three `github_*` tool
    /// declarations (Invariant 6): absent, the tools are not offered at all.
    static func hasToken(keychain: KeychainManager) -> Bool {
        token(keychain: keychain) != nil
    }

    /// The most repositories the allowed list holds: more than a person lists by hand, and a bound on
    /// what a stored list costs every call.
    static let maxAllowedRepos = 50

    enum RepoListCheck: Equatable {
        case ok([String])
        case invalid(String)
        case tooMany
    }

    /// The list a set of names would be saved as: each trimmed, `isOwnerName`, repeats dropped (first
    /// kept), at most `maxAllowedRepos`. The one definition the headless setter and the Settings pane
    /// share, so what can be stored does not depend on which of them stored it.
    static func checkRepoList(_ names: [String]) -> RepoListCheck {
        var list: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isOwnerName(name) else { return .invalid(name) }
            if !list.contains(name) { list.append(name) }
        }
        return list.count > maxAllowedRepos ? .tooMany : .ok(list)
    }

    enum LoginCheck: Equatable {
        case ok(String)
        case empty
        case invalid
    }

    /// GitHub's rule for a username: 1 to 39 letters, digits and single hyphens, not starting or
    /// ending with one. The login goes into `git config`, a credential line and a file's contents, so
    /// the set is held strictly: nothing else can reach any of them. The one definition the pane,
    /// the headless setter and the stored value's reader share.
    static func checkLogin(_ raw: String) -> LoginCheck {
        let login = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { return .empty }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        guard login.count <= 39, !login.hasPrefix("-"), !login.hasSuffix("-"), !login.contains("--"),
              login.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return .invalid }
        return .ok(login)
    }

    /// The stored form of a login: a one-key JSON object, so the guarded item's blob rules apply.
    static func loginBlob(_ login: String) -> String {
        (try? JSONSerialization.data(withJSONObject: ["login": login], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The login in a stored blob, or nil when it is empty, not that object, or not a valid login.
    static func parseLogin(_ blob: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any],
              object.count == 1, let raw = object["login"] as? String,
              case .ok(let login) = checkLogin(raw), login == raw else { return nil }
        return login
    }

    /// The commit author name and email for a login: GitHub's noreply address, which attributes a
    /// commit to the account without exposing a real address. The form depends on `accountId`
    /// (#1188): GitHub only recognizes the bare `<login>@...` form for an account that enabled
    /// "Keep my email address private" before July 18, 2017 (docs.github.com/en/account-and-profile
    /// /reference/email-addresses-reference); every account created after that date -- which any
    /// account set up for this feature now is -- gets only the `<id>+<login>@...` form, so a commit
    /// using the bare form is not attributed at all. `accountId` comes from the same `GET /user`
    /// call `verifyIdentity` already makes (`verifyIdentityWithAccountId`); nil whenever there is no
    /// verified match with a readable id, in which case the bare form is used as a value that is at
    /// least well-formed. `GitIdentityEnvironment.shouldApply` gates specifically on `accountId !=
    /// nil` (#1194 review, dev-2's finding), not a separate match flag, so this fallback is never
    /// actually written to a commit: the one caller that writes a commit identity never calls this
    /// with a nil id in the first place.
    static func commitIdentity(login: String, accountId: Int?) -> (name: String, email: String) {
        let email = accountId.map { "\($0)+\(login)@users.noreply.github.com" } ?? "\(login)@users.noreply.github.com"
        return (login, email)
    }

    /// What a typed or piped token is worth saving as. The one definition the headless setter and the
    /// Settings pane share, so they cannot disagree about what a token may hold.
    enum TokenCheck: Equatable {
        case ok(String)
        case empty
        /// Interior whitespace or a control character: two pasted lines would otherwise be stored as
        /// one token with an embedded newline.
        case malformed
    }

    static func checkToken(_ raw: String) -> TokenCheck {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .empty }
        let bad = token.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
        return bad ? .malformed : .ok(token)
    }

    /// The account's PAT, or nil if none is stored.
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

    /// `POST /repos/{repo}/pulls`: opens a PR authored by the token's identity.
    func createPR(repo: String, head: String, base: String, title: String, body: String, draft: Bool) async -> String {
        let payload: [String: Any] = ["title": title, "body": body, "head": head, "base": base, "draft": draft]
        switch await post(repo: repo, path: "pulls", payload: payload) {
        case .refused(let message): return message
        case .done(let json, _):
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
        case .done(let json, _):
            let url = Self.githubURL(json["html_url"])
            return sanitize(url.map { "Posted comment: \($0)" } ?? "Posted comment.",
                            token: Self.token(keychain: keychain))
        }
    }

    /// #1435: whether `repo` passes the allowlist and the owner/name shape, as every call here checks first. `vcs`'s
    /// fetch and push ask before the mirror's git touches the network.
    func allows(_ repo: String) -> Bool { isRepoAllowed(repo) && Self.isOwnerName(repo) }

    /// #1435: the files `head` changes against `base` (`GET /compare/{base}...{head}`), every rename's source
    /// included, or why they couldn't all be listed. Branch names reach the path only after `VCSTool.isBranchName`.
    func changedFiles(repo: String, base: String, head: String) async -> Result<[String], CompareRefusal> {
        guard VCSTool.isBranchName(base), VCSTool.isBranchName(head) else { return .failure(.init("Refused: not a branch name vcs accepts.")) }
        switch await perform(method: "GET", repo: repo, path: "compare/\(base)...\(head)", query: "per_page=\(Self.filePageSize)") {
        case .refused(let message): return .failure(.init(message))
        case .done(let json, let link):
            guard let files = json["files"] as? [[String: Any]] else {
                return .failure(.init("Refused: GitHub did not list the branch's changed files, so none were checked."))
            }
            guard files.count < Self.filePageSize, !Self.hasNextPage(link) else {
                return .failure(.init("Refused: the branch changes too many files for me to check them all."))
            }
            return .success(files.flatMap { file in [file["filename"], file["previous_filename"]].compactMap { $0 as? String } })
        }
    }

    struct CompareRefusal: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// #1435 F4 (Brian): marks a draft PR ready for review, which arms its auto-merge, so only one `mayReady` accepts:
    /// the head branch decides (every agent's PR is the same account's, so its author can't). REST has no endpoint
    /// for this; it is the GraphQL `markPullRequestReadyForReview` on the PR's node id from `GET /pulls/{pr}`.
    func ready(repo: String, pr: Int, mayReady: (_ head: String) -> String?) async -> String {
        guard pr > 0 else { return "Refused: a pull request number must be positive." }
        let nodeId: String
        switch await perform(method: "GET", repo: repo, path: "pulls/\(pr)") {
        case .refused(let message): return message
        case .done(let json, _):
            guard (json["state"] as? String) == "open" else { return "Refused: pull request #\(pr) is not open." }
            guard json["draft"] as? Bool == true else { return "Pull request #\(pr) is already ready for review." }
            let head = ((json["head"] as? [String: Any])?["ref"] as? String) ?? ""
            if let refusal = mayReady(head) { return refusal }
            guard let id = json["node_id"] as? String, !id.isEmpty, id.utf8.count <= 100,
                  id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else {
                return "Refused: GitHub did not report the pull request's id in a form I can use."
            }
            nodeId = id
        }
        let query = "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"
        switch await graphQL(repo: repo, query: query, variables: ["id": nodeId]) {
        case .refused(let message): return message
        case .done(let json, _):
            if let errors = json["errors"] as? [[String: Any]], let first = errors.first?["message"] as? String {
                return sanitize("Refused: GitHub said: \(first)", token: Self.token(keychain: keychain))
            }
            return "Marked pull request #\(pr) ready for review."
        }
    }

    /// `POST /graphql`, behind the same allowlist, shape and token checks as every other call: `repo` is the one the
    /// query acts on, checked first.
    private func graphQL(repo: String, query: String, variables: [String: Any]) async -> Outcome {
        guard isRepoAllowed(repo) else {
            return .refused("Refused: repository \"\(Self.shown(repo))\" is not allowed for the GitHub tools.")
        }
        guard Self.isOwnerName(repo) else { return .refused("Refused: \"\(Self.shown(repo))\" is not an owner/name repository.") }
        guard let token = Self.token(keychain: keychain) else { return .refused("GitHub is not configured: no token is set.") }
        guard let url = URL(string: "\(Self.apiBase)/graphql"),
              let data = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: [.sortedKeys]) else {
            return .refused("Refused: the request could not be built.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iris", forHTTPHeaderField: "User-Agent")
        do {
            let (responseData, response) = try await transport.send(request, bearer: token)
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
            guard (200..<300).contains(response.statusCode) else {
                return .refused(sanitize("GitHub returned HTTP \(response.statusCode)", token: token))
            }
            return .done(json, link: nil)
        } catch is CancellationError {
            return .refused("The GitHub request was cancelled.")
        } catch {
            return .refused(sanitize("The GitHub request failed: \(error.localizedDescription)", token: token))
        }
    }

    static let maxPRBodyShown = 4_000

    /// #1435: `GET /pulls/{pr}`: number, state, branches, title and the description (others' words: the caller
    /// taints the conversation with it). Only the description keeps its line breaks.
    func viewPR(repo: String, pr: Int) async -> String {
        guard pr > 0 else { return "Refused: a pull request number must be positive." }
        switch await perform(method: "GET", repo: repo, path: "pulls/\(pr)") {
        case .refused(let message): return message
        case .done(let json, _):
            let token = Self.token(keychain: keychain)
            let head = ((json["head"] as? [String: Any])?["ref"] as? String) ?? "?"
            let base = ((json["base"] as? [String: Any])?["ref"] as? String) ?? "?"
            let state = (json["draft"] as? Bool == true ? "draft, " : "") + ((json["merged"] as? Bool == true) ? "merged" : (json["state"] as? String ?? "?"))
            var lines = ["#\(pr) \(json["title"] as? String ?? "") [\(state)] \(head) -> \(base)"]
            if let url = Self.githubURL(json["html_url"]) { lines.append(url) }
            let header = sanitize(lines.joined(separator: " "), token: token)
            let body = SecretScrub.scrub(json["body"] as? String ?? "", token.map { [$0] } ?? [])
            let capped = body.count > Self.maxPRBodyShown ? String(body.prefix(Self.maxPRBodyShown)) + "\n[description cut]" : body
            return body.isEmpty ? header : header + "\n\n" + capped
        }
    }

    /// #1435: the check runs on a PR's head commit (`GET /commits/{sha}/check-runs`), one line each.
    func checks(repo: String, pr: Int) async -> String {
        guard pr > 0 else { return "Refused: a pull request number must be positive." }
        let head: String
        switch await perform(method: "GET", repo: repo, path: "pulls/\(pr)") {
        case .refused(let message): return message
        case .done(let json, _):
            guard let sha = Self.commitSHA(json, side: "head") else { return "Refused: GitHub did not report the pull request's head commit." }
            head = sha
        }
        switch await perform(method: "GET", repo: repo, path: "commits/\(head)/check-runs", query: "per_page=100") {
        case .refused(let message): return message
        case .done(let json, _):
            let runs = json["check-runs"] as? [[String: Any]] ?? []
            guard !runs.isEmpty else { return "#\(pr) at \(head.prefix(7)): no checks have reported." }
            let token = Self.token(keychain: keychain)
            let lines = runs.prefix(50).map { run in
                sanitize("\(run["name"] as? String ?? "?"): \(run["conclusion"] as? String ?? (run["status"] as? String ?? "?"))", token: token)
            }
            return "#\(pr) at \(head.prefix(7)):\n" + lines.joined(separator: "\n")
        }
    }

    enum IdentityCheck: Equatable, Sendable {
        /// The token belongs to the configured login.
        case match
        /// The token belongs to another account, named here (a login is public, not a secret).
        case mismatch(actual: String)
        /// GitHub could not say: no token, a refusal, or the network. Not a match, not a mismatch.
        case unverified(String)
    }

    /// `GET /user`: whose token this is, compared with the login the user configured (case-blind, as
    /// GitHub is). A mismatch keeps the tools off (`GitHubIdentityMonitor`): commits would be signed as one
    /// account while the token acts as another. A failure to ask is `.unverified`, never a mismatch. Sends nothing without a token and reads nothing else.
    ///
    /// Thin wrapper over `verifyIdentityWithAccountId`, dropping the id, for every caller that only
    /// needs the check itself.
    func verifyIdentity(expectedLogin: String) async -> IdentityCheck {
        await verifyIdentityWithAccountId(expectedLogin: expectedLogin).check
    }

    /// `verifyIdentity`, plus the account's numeric id on a match (#1188): `commitIdentity` needs it
    /// for the noreply address GitHub actually attributes to an account created after July 18, 2017.
    /// The id comes from the same `GET /user` response already fetched for the login comparison --
    /// no second request.
    func verifyIdentityWithAccountId(expectedLogin: String) async -> (check: IdentityCheck, accountId: Int?) {
        guard let token = Self.token(keychain: keychain) else { return (.unverified("no token is set"), nil) }
        guard let url = URL(string: "\(Self.apiBase)/user") else { return (.unverified("the request could not be built"), nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("iris", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await transport.send(request, bearer: token)
            guard (200..<300).contains(response.statusCode) else {
                return (.unverified("GitHub returned HTTP \(response.statusCode)"), nil)
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let actual = json?["login"] as? String, case .ok = Self.checkLogin(actual) else {
                return (.unverified("GitHub did not name the account"), nil)
            }
            guard actual.lowercased() == expectedLogin.lowercased() else { return (.mismatch(actual: actual), nil) }
            // A match with no readable id is a GitHub response shape surprise, not a reason to call
            // it unverified or a mismatch: the login matched, so the check itself stands; git
            // identity is simply left off until a real id is seen (`shouldApply`'s own gate on
            // `accountId != nil`, #1194 review). The `!(idValue is Bool)` check comes first because
            // `as? Int` on a JSON boolean bridges it through `NSNumber` to `1`/`0` (dev-2's finding)
            // -- checked before the cast, not after, since a bridged `true` is already `1` and
            // would pass a bare `> 0` check. `id > 0` on top of that is cheap insurance against a
            // zero or negative value being mistaken for a real GitHub user id.
            let idValue = json?["id"]
            let rawId = (idValue is Bool) ? nil : idValue as? Int
            return (.match, (rawId.map { $0 > 0 } ?? false) ? rawId : nil)
        } catch is CancellationError {
            return (.unverified("the check was cancelled"), nil)
        } catch {
            return (.unverified(sanitize("the request failed: \(error.localizedDescription)", token: token)), nil)
        }
    }

    private enum Outcome {
        case refused(String)
        /// The decoded JSON object, and the response's `Link` header (pagination).
        case done([String: Any], link: String?)
    }

    /// The one request path. Order matters: allowlist, repo shape, then the token, and only then a
    /// request, so a refused call has read nothing and sent nothing.
    private func post(repo: String, path: String, payload: [String: Any]) async -> Outcome {
        await perform(method: "POST", repo: repo, path: path, payload: payload)
    }

    private func perform(method: String, repo: String, path: String, query: String? = nil,
                         payload: [String: Any]? = nil) async -> Outcome {
        guard isRepoAllowed(repo) else {
            return .refused("Refused: repository \"\(Self.shown(repo))\" is not allowed for the GitHub tools. "
                            + "The user adds repositories to the allowed list; it is empty until they do.")
        }
        guard Self.isOwnerName(repo) else {
            return .refused("Refused: \"\(Self.shown(repo))\" is not an owner/name repository.")
        }
        guard let token = Self.token(keychain: keychain) else {
            return .refused("GitHub is not configured: no token is set.")
        }
        let suffix = query.map { "?\($0)" } ?? ""
        let data = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        guard let url = URL(string: "\(Self.apiBase)/repos/\(repo)/\(path)\(suffix)"),
              payload == nil || data != nil else {
            return .refused("Refused: the request could not be built.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("iris", forHTTPHeaderField: "User-Agent")

        do {
            let (responseData, response) = try await transport.send(request, bearer: token)
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
            guard (200..<300).contains(response.statusCode) else {
                let message = (json["message"] as? String).map { ": \($0)" } ?? ""
                return .refused(sanitize("GitHub returned HTTP \(response.statusCode)\(message)", token: token))
            }
            return .done(json, link: response.value(forHTTPHeaderField: "Link"))
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

// MARK: - Approve (the routine-file gate, spec section 3.3)

extension GitHubProxyClient {
    /// The most changed files one approval will look at. GitHub pages a file list at this size;
    /// a PR that fills a page may have more on the next, so it is refused rather than guessed at.
    static let filePageSize = 100
    /// The only top-level folders whose changes `github_approve` will approve.
    static let routineRoots: Set<String> = ["docs", "assets"]
    /// Folders under `docs/`, at any depth, that agents read as instructions and execute (plans and
    /// specs: `docs/plans`, `docs/specs`, `docs/superpowers/plans`). A change there is not routine:
    /// a poisoned one would merge with no human and no CI run (a docs-only PR skips the build), then
    /// steer the next session that reads it. They stay `@bnaylor`'s to approve (the `/docs/**/plans/` and
    /// `/docs/**/specs/` CODEOWNERS lines, spec section 2), and this refuses them too.
    static let agentInstructionFolders: Set<String> = ["plans", "specs"]

    /// `POST /repos/{repo}/pulls/{pr}/reviews` with `APPROVE`, only for an open PR whose every
    /// changed file is routine, and bound to the exact commit that was checked.
    ///
    /// 1. Resolve `head.sha` and `base.sha` from `GET /pulls/{pr}`.
    /// 2. Fetch the changed files keyed to those two SHAs (`GET /compare/{base}...{head}`), not
    ///    `GET /pulls/{pr}/files`, which follows whatever the head is when it is asked.
    /// 3. Refuse unless every file, and every rename source, is routine; refuse a full page or a
    ///    `rel="next"` link; refuse an empty list (nothing was verified).
    /// 4. Re-read the head: refuse if it moved during the check.
    /// 5. Submit the review with `commit_id = head`, so a push after step 4 cannot ride it.
    /// 6. Read the head once more: a push that landed before the review existed is reported, not
    ///    called an approval.
    ///
    /// `base.sha` can lag the base branch. The three-dot compare starts at the merge base of that
    /// SHA and the head, which can only add files to the list (never hide one), so a stale base
    /// refuses more, not less.
    func approve(repo: String, pr: Int) async -> String {
        guard pr > 0 else { return "Refused: a pull request number must be positive." }
        let first = await perform(method: "GET", repo: repo, path: "pulls/\(pr)")
        let head: String, base: String
        switch first {
        case .refused(let message): return message
        case .done(let json, _):
            guard (json["state"] as? String) == "open" else {
                return "Refused: pull request #\(pr) is not open."
            }
            guard let headSHA = Self.commitSHA(json, side: "head"), let baseSHA = Self.commitSHA(json, side: "base") else {
                return "Refused: GitHub did not report the pull request's commits in a form I can check."
            }
            head = headSHA
            base = baseSHA
        }

        switch await perform(method: "GET", repo: repo, path: "compare/\(base)...\(head)",
                             query: "per_page=\(Self.filePageSize)") {
        case .refused(let message): return message
        case .done(let json, let link):
            guard let files = json["files"] as? [[String: Any]] else {
                return "Refused: GitHub did not list the changed files, so none were checked."
            }
            guard !files.isEmpty else { return "Refused: the pull request lists no changed files, so there is nothing to check." }
            guard files.count < Self.filePageSize, !Self.hasNextPage(link) else {
                return "Refused: the pull request changes too many files for me to check them all."
            }
            if let offending = files.first(where: { !Self.isRoutineChange($0) }) {
                let name = (offending["filename"] as? String).map(Self.shown) ?? "(unnamed)"
                return "Refused: \(name) is not a routine docs/assets change, so I will not approve this pull request."
            }
        }

        switch await perform(method: "GET", repo: repo, path: "pulls/\(pr)") {
        case .refused(let message): return message
        case .done(let json, _):
            guard Self.commitSHA(json, side: "head") == head else {
                return "Refused: the pull request was updated while I checked it. Ask me to look again."
            }
        }

        switch await post(repo: repo, path: "pulls/\(pr)/reviews", payload: ["event": "APPROVE", "commit_id": head]) {
        case .refused(let message): return message
        case .done: break
        }

        // A push can land between the head re-read above and this review. `commit_id` keeps the
        // review on the checked commit, but a stale-approval rule fires at push time, before the
        // review exists, so that approval can still count. Read the head once more and say so.
        let short = head.prefix(7)
        switch await perform(method: "GET", repo: repo, path: "pulls/\(pr)") {
        case .refused:
            return sanitize("Submitted an approval of pull request #\(pr) at \(short), but could not confirm the head did not move afterwards. Treat it as unconfirmed and check the pull request.",
                            token: Self.token(keychain: keychain))
        case .done(let json, _):
            guard Self.commitSHA(json, side: "head") == head else {
                return sanitize("Submitted an approval of pull request #\(pr) at \(short), but the pull request moved while I did it. Treat it as NOT approved: the new commits were not checked, and the approval may need dismissing.",
                                token: Self.token(keychain: keychain))
            }
        }
        return sanitize("Approved pull request #\(pr) at \(short).", token: Self.token(keychain: keychain))
    }

    /// `side`'s commit SHA from a pull request object, only if it is 40 lowercase hex digits: it is
    /// spliced into a URL path, and nothing else may go there.
    private static func commitSHA(_ pull: [String: Any], side: String) -> String? {
        guard let sha = (pull[side] as? [String: Any])?["sha"] as? String,
              sha.utf8.count == 40, sha.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return sha
    }

    /// Whether a `Link` header advertises a further page.
    private static func hasNextPage(_ link: String?) -> Bool {
        link?.range(of: #"rel\s*=\s*"?next"?"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A changed file is routine only if its path, and its previous path when it was renamed or
    /// copied, are both routine. A `previous_filename` that is present but not a string fails.
    static func isRoutineChange(_ file: [String: Any]) -> Bool {
        guard let name = file["filename"] as? String, isRoutinePath(name) else { return false }
        guard let previous = file["previous_filename"], !(previous is NSNull) else { return true }
        guard let previousName = previous as? String else { return false }
        return isRoutinePath(previousName)
    }

    /// A repo-relative path inside `docs/` or `assets/`: at least one segment below the folder, no
    /// empty, `.` or `..` segment, no backslash or control character. A leading slash is refused
    /// by the same rules: it makes the first segment empty, which is neither root. Under `docs/`, a
    /// directory named `plans` or `specs` at any depth is refused, compared case-insensitively
    /// because the Mac checkout agents read from is (`docs/Plans` is `docs/plans` there).
    static func isRoutinePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0 == "\\" || CharacterSet.controlCharacters.contains($0) }) else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, routineRoots.contains(String(segments[0])) else { return false }
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if segments[0] == "docs",
           segments.dropFirst().dropLast().contains(where: { agentInstructionFolders.contains($0.lowercased()) }) {
            return false
        }
        return true
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
