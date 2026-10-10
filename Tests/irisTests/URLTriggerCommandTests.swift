import AppKit
import Testing
import Foundation
import GRDB
@testable import IrisKit

/// D6 decisions 9 and 10, and plan note 17 (coordinator ruling): `/jobs url <job> on` mints a
/// 128-bit token and keeps only its digest. The link is shown once, in a transient sheet; the
/// conversation keeps a redacted line. So the token is never in the store, on disk or in any
/// message, and never reaches a model: not through a tool, a card, a line, the model's
/// history, search, `read_conversation` or the rotation summary.
@MainActor
@Suite("/jobs url (D6)", .timeLimit(.minutes(1)))
struct URLTriggerCommandTests {
    // MARK: The token

    @Test("a token is 22 base64url characters from 16 random bytes")
    func tokenShape() throws {
        let token = try #require(URLTriggerToken.generate())
        #expect(token.count == 22)
        #expect(URLTriggerToken.isWellFormed(token))
        #expect(URLTriggerToken.generate() != token)
        #expect(URLTriggerToken.base64url([0xfb, 0xff]) == "-_8", "no +, / or = padding")
        #expect(URLTriggerToken.generate(fill: { _ in false }) == nil, "a random source that fails mints nothing")
    }

    @Test("the digest is SHA-256, in lowercase hex")
    func digestVector() {
        #expect(URLTriggerToken.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("only a 22-character base64url string is well formed")
    func wellFormed() {
        #expect(!URLTriggerToken.isWellFormed(UUID().uuidString))
        #expect(!URLTriggerToken.isWellFormed("pr-sweep"))
        #expect(!URLTriggerToken.isWellFormed(String(repeating: "a", count: 21)))
        #expect(!URLTriggerToken.isWellFormed(String(repeating: "a", count: 23)))
        #expect(!URLTriggerToken.isWellFormed(String(repeating: "a", count: 20) + "%4"))
        #expect(URLTriggerToken.isWellFormed(String(repeating: "a", count: 20) + "-_"))
    }

    // MARK: Parsing

    @Test("/jobs url reads from the right: the last word is on or off, the rest is the name")
    func parse() {
        #expect(JobsCommand.parse("/jobs url pr-sweep") == .url(name: "pr-sweep", setting: nil))
        #expect(JobsCommand.parse("/jobs url pr-sweep on") == .url(name: "pr-sweep", setting: true))
        #expect(JobsCommand.parse("/jobs url pr-sweep OFF") == .url(name: "pr-sweep", setting: false))
        #expect(JobsCommand.parse("/jobs url Daily digest on") == .url(name: "Daily digest", setting: true))
        #expect(JobsCommand.parse("/jobs url lights-on") == .url(name: "lights-on", setting: nil),
                "a name that ends in 'on' is a name")
        #expect(JobsCommand.parse("/jobs url turn on") == .url(name: "turn", setting: true))
        #expect(JobsCommand.parse(#"/jobs url "turn on""#) == .url(name: "turn on", setting: nil))
        #expect(JobsCommand.parse(#"/jobs url "turn on" off"#) == .url(name: "turn on", setting: false))
        #expect(JobsCommand.parse("/jobs url on") == .url(name: "on", setting: nil))
        #expect(JobsCommand.parse("/jobs url") == .usage)
        #expect(JobsCommand.usageText.contains("/jobs url <name> [on|off]"))
    }

    // MARK: The handler

    private func makeApp(with jobs: [Job]) throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation()
        app.selectedConversationId = id
        for job in jobs { try store.ledger.upsert(job) }
        return (store, app, id)
    }

    private func output(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.messages ?? [])
            .filter { $0.role == .command }.map(\.content).joined(separator: "\n")
    }

    /// The token the most recent `on` revealed, read from the transient sheet's state: the only
    /// place it exists.
    private func token(_ app: AppState) throws -> String {
        let link = try #require(app.revealedURLTrigger, "on must reveal the link")
        let marker = "\(BuildIdentity.current.urlScheme)://\(RunJobURL.host)/"
        #expect(link.url.hasPrefix(marker))
        return String(link.url.dropFirst(marker.count))
    }

    /// The raw column: `job(urlTokenHash:)` also requires the flag, so it cannot tell a deleted
    /// digest from one left behind under a cleared flag.
    private func storedDigest(_ store: ConversationStore, _ job: Job) throws -> String? {
        try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT urlTokenHash FROM jobs WHERE id = ?", arguments: [job.id.uuidString])
        }
    }

    private func sweep() -> Job { Job(name: "pr-sweep", prompt: "sweep", trigger: .schedule(.interval(seconds: 60))) }

    @Test("on reveals a link whose token hashes to the stored digest; on again rotates; off clears")
    func onRotateOff() throws {
        let job = sweep()
        let (store, app, id) = try makeApp(with: [job])

        app.sendMessage("/jobs url pr-sweep on")
        let first = try token(app)
        #expect(URLTriggerToken.isWellFormed(first))
        #expect(output(app, id).contains(JobsCommand.urlOnText(job)), "the conversation keeps the redacted line")
        #expect(!output(app, id).contains(first))
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(first))?.id == job.id)

        app.sendMessage("/jobs url pr-sweep on")
        let second = try token(app)
        #expect(second != first)
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(first)) == nil, "the old link is dead")
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(second))?.id == job.id)
        #expect(try storedDigest(store, job) == URLTriggerToken.digest(second), "the column holds the new digest")

        app.sendMessage("/jobs url pr-sweep off")
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(second)) == nil)
        #expect(try storedDigest(store, job) == nil, "off deletes the digest, not only the flag")
        #expect(app.revealedURLTrigger == nil, "off withdraws a link still on screen")
    }

    @Test("after on, the token is nowhere in the store's files, and the redacted line is")
    func tokenNeverStored() throws {
        let dir = try tempDirectory(prefix: "iris-urlstore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConversationStore.onDisk(at: dir.appendingPathComponent("conversations.sqlite"))
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        let job = sweep()
        try store.ledger.upsert(job)

        app.sendMessage("/jobs url pr-sweep on")
        let minted = try token(app)
        app.flushSave()

        // Every file the store wrote: the database, its WAL and its shared-memory index.
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(minted.utf8)) == nil, "\(file.lastPathComponent) holds the token")
        }
        let saved = try store.loadAll().conversations.flatMap(\.messages).map(\.content)
        #expect(saved.contains { $0.contains(JobsCommand.urlOnText(job)) })
    }

    @Test("off and delete both withdraw a link still on screen, matched by the job's id")
    func withdrawals() throws {
        let job = sweep()
        let other = Job(name: "other", prompt: "other", trigger: .schedule(.interval(seconds: 60)))
        let (store, app, _) = try makeApp(with: [job, other])

        app.sendMessage("/jobs url other on")
        #expect(app.revealedURLTrigger?.jobId == other.id)
        app.sendMessage("/jobs url pr-sweep off")
        #expect(app.revealedURLTrigger?.jobId == other.id, "another job's off leaves the sheet alone")

        // A rename keeps the trigger on (upsert never writes it), so only the id still matches.
        var renamed = try #require(try store.ledger.job(id: other.id))
        renamed.name = "renamed"
        try store.ledger.upsert(renamed)
        app.sendMessage("/jobs url renamed off")
        #expect(app.revealedURLTrigger == nil, "off withdraws its own job's link, renamed or not")

        app.sendMessage("/jobs url pr-sweep on")
        #expect(app.revealedURLTrigger?.jobId == job.id)
        app.sendMessage("/jobs delete renamed")
        #expect(app.revealedURLTrigger?.jobId == job.id, "deleting another job leaves the sheet alone")
        app.sendMessage("/jobs delete pr-sweep")
        #expect(try store.ledger.job(id: job.id) == nil)
        #expect(app.revealedURLTrigger == nil, "delete withdraws the deleted job's link")
    }

    @Test("Copy marks the link concealed and transient, so clipboard history skips it")
    func copyIsConcealed() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("iris-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let link = "iris-dev://run-job/" + String(repeating: "a", count: URLTriggerToken.encodedLength)
        URLTriggerLinkSheet.copy(link, to: board)
        let types = board.types ?? []
        #expect(board.string(forType: .string) == link)
        #expect(types.contains(URLTriggerLinkSheet.concealedType))
        #expect(types.contains(URLTriggerLinkSheet.transientType))
    }

    @Test("the sheet text is plain words: Text(String) shows markdown literally")
    func sheetTextIsPlain() {
        #expect(!JobsCommand.urlSheetText("pr-sweep").contains("`"))
        #expect(!JobsCommand.urlSheetText("pr-sweep").contains("**"))
    }

    @Test("a digest another job holds is retried once with a fresh token")
    func collisionRetries() throws {
        let job = sweep()
        let other = Job(name: "other", prompt: "other", trigger: .schedule(.interval(seconds: 60)))
        let (store, app, id) = try makeApp(with: [job, other])
        let held = String(repeating: "A", count: URLTriggerToken.encodedLength)
        try store.ledger.setURLTrigger(jobId: other.id, tokenHash: URLTriggerToken.digest(held))
        let fresh = String(repeating: "B", count: URLTriggerToken.encodedLength)
        var queue = [held, fresh]
        app.urlTriggerTokenSource = { queue.isEmpty ? nil : queue.removeFirst() }

        app.sendMessage("/jobs url pr-sweep on")
        #expect(try token(app) == fresh)
        #expect(output(app, id).hasSuffix(JobsCommand.urlOnText(job)))
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(fresh))?.id == job.id)
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(held))?.id == other.id)
    }

    @Test("a second collision or a failed random source prints a plain line and changes nothing")
    func failuresArePlain() throws {
        let job = sweep()
        let other = Job(name: "other", prompt: "other", trigger: .schedule(.interval(seconds: 60)))
        let (store, app, id) = try makeApp(with: [job, other])
        let held = String(repeating: "A", count: URLTriggerToken.encodedLength)
        try store.ledger.setURLTrigger(jobId: other.id, tokenHash: URLTriggerToken.digest(held))
        var calls = 0
        app.urlTriggerTokenSource = { calls += 1; return held }

        app.sendMessage("/jobs url pr-sweep on")
        #expect(calls == 2, "one retry, no more")
        let said = output(app, id)
        #expect(said.hasSuffix(JobsCommand.urlChangeFailedText(job)))
        for raw in ["SQLite", "SQLITE", "UNIQUE", "constraint", "urlTokenHash"] {
            #expect(!said.contains(raw), "a raw database error reached the conversation: \(raw)")
        }
        #expect(app.revealedURLTrigger == nil)
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)

        app.urlTriggerTokenSource = { nil }
        app.sendMessage("/jobs url pr-sweep on")
        #expect(output(app, id).hasSuffix("the system's random source failed. Nothing changed."))
        #expect(app.revealedURLTrigger == nil)
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
    }

    @Test("asking shows on or off and never a token, and an unknown name is refused")
    func status() throws {
        let (_, app, id) = try makeApp(with: [sweep()])
        app.sendMessage("/jobs url pr-sweep")
        #expect(output(app, id).contains("is off"))
        app.sendMessage("/jobs url pr-sweep on")
        let minted = try token(app)
        app.sendMessage("/jobs url pr-sweep")
        let lines = output(app, id).components(separatedBy: "\n")
        #expect(lines.last?.contains("is on") == true)
        #expect(lines.last?.contains(minted) == false)
        app.sendMessage("/jobs url nope on")
        #expect(output(app, id).hasSuffix("No job named 'nope'."))
    }

    @Test("the token never reaches the model, by any surface")
    func tokenNeverReachesTheModel() async throws {
        let job = sweep()
        let (store, app, id) = try makeApp(with: [job])
        app.sendMessage("/jobs url pr-sweep on")
        let minted = try token(app)

        // list_jobs and get_job_run: the flag, never the token.
        let jobs = try store.ledger.jobs()
        let listing = IrisEngine.jobsListJSON(jobs, lastStatuses: [:], usage: .empty, unreadableJobs: 0)
        #expect(!listing.contains(minted))
        #expect(listing.contains(#""urlTrigger":true"#))
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "url", startedAt: Date())
        #expect(!IrisEngine.jobRunJSON(run, outcome: nil, failureReason: nil, gateSignal: nil,
                                       lastAgentMessage: nil).contains(minted))

        // /jobs, cards and every message of every role: the conversation keeps only the
        // redacted line.
        app.sendMessage("/jobs")
        if let listingTask = app.jobsListingTask { try await value(of: listingTask) }
        for conversation in app.conversations {
            for message in conversation.messages {
                #expect(!message.content.contains(minted), "a \(message.role) message carried the token")
            }
        }

        // The model's history, search, read_conversation.
        let conversation = try #require(app.conversations.first { $0.id == id })
        let history = conversation.history.flatMap(\.parts).compactMap(\.text).joined()
        #expect(!history.contains(minted))
        app.flushSave()
        // `sanitizeFTSQuery` keeps only letters, digits and spaces, so the token is searched by
        // its longest alphanumeric run, which the index tokenizes the same way.
        let alnumRun = String(minted.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .max(by: { $0.count < $1.count }) ?? Substring(minted))
        #expect(try store.searchConversations(query: alnumRun).isEmpty)
        #expect(try store.searchConversations(query: "run job").isEmpty)
        #expect(!ConversationReader.page(conversation.messages, from: 0, count: 50).text.contains(minted))

        // The rotation summary: the one path that sends UI messages to a model (plan note 12).
        // An owner and an agent line make sure the call is actually made.
        app.appendMessage(role: .user, content: "what is scheduled?", to: id)
        app.appendMessage(role: .agent, content: "pr-sweep, every minute", to: id)
        let messages = try #require(app.conversations.first { $0.id == id }).messages
        let client = CapturingLLMClient(reply: "summary")
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        _ = await engine.summarizeForRotation(messages: messages)
        #expect(!client.requests.isEmpty, "the summary call was made")
        for request in client.requests {
            #expect(!String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains(minted))
        }
    }
}
