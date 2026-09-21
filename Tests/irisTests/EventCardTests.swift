import Testing
import Foundation
@testable import iris

/// The `.event` message payload (#187 deliverable 2): a job run's outcome, encoded into a
/// `ChatMessage.content` and rendered as a one-line card. No SwiftUI here by design (AGENTS.md:
/// no SwiftUI unit tests) — the card view is pure presentation over these pure helpers.
@Suite("EventCard")
struct EventCardTests {
    /// Whole seconds on purpose: the wire format is ISO-8601, which carries no sub-second
    /// component, so a round trip is only exact for a date that has none.
    private static let started = Date(timeIntervalSince1970: 1_700_000_000)
    private static let finished = Date(timeIntervalSince1970: 1_700_000_075)

    private func card(status: JobRun.Status = .completed,
                      outcome: String? = "swept 3 PRs",
                      blockedTool: String? = nil,
                      totalTokens: Int = 4_200,
                      runId: UUID = UUID(),
                      transcript: UUID? = nil) -> EventCard {
        EventCard(runId: runId,
                  jobId: UUID(),
                  jobName: "pr-sweep",
                  status: status,
                  outcome: outcome,
                  blockedTool: blockedTool,
                  startedAt: Self.started,
                  finishedAt: Self.finished,
                  totalTokens: totalTokens,
                  transcriptConversationId: transcript)
    }

    @Test("encode/decode is a round trip")
    func roundTrip() {
        let original = card(transcript: UUID())
        let decoded = EventCard.decode(original.encodedContent())
        #expect(decoded == original)
    }

    @Test("encoded content is stable JSON with a kind discriminator")
    func encodedShape() {
        let subject = card()
        let encoded = subject.encodedContent()
        #expect(encoded.contains("\"kind\":\"job_run\""))
        #expect(encoded.contains("\"startedAt\":\"2023-11-14T22:13:20Z\""))
        // .sortedKeys: finishedAt before jobId before jobName before kind — a stable byte
        // sequence, so an unchanged card never shows up as a changed message row.
        #expect(subject.encodedContent() == encoded)
        #expect(encoded.range(of: "\"jobId\"")!.lowerBound < encoded.range(of: "\"kind\"")!.lowerBound)
    }

    @Test("decode returns nil for content that is not a card")
    func decodeNonCard() {
        #expect(EventCard.decode("Here is a plain agent reply.") == nil)
        #expect(EventCard.decode("") == nil)
        #expect(EventCard.decode("{\"headline\":\"something else\"}") == nil)
    }

    @Test("decode is lenient about a missing kind, status and outcome")
    func lenientDecode() {
        let runId = UUID()
        let json = """
        {"runId":"\(runId.uuidString)","jobId":"\(UUID().uuidString)","jobName":"pr-sweep",\
        "startedAt":"2023-11-14T22:13:20Z","finishedAt":"2023-11-14T22:14:35Z","totalTokens":4200}
        """
        let decoded = EventCard.decode(json)
        #expect(decoded?.kind == "job_run")
        #expect(decoded?.status == .completed)
        #expect(decoded?.outcome == nil)
        #expect(decoded?.blockedTool == nil)
        #expect(decoded?.transcriptConversationId == nil)
        #expect(decoded?.runId == runId)
        #expect(decoded?.totalTokens == 4_200)
    }

    /// Fix round 1: an unrecognised status is NOT the same as an absent one. A value this build
    /// does not know about came from a newer build and may well be a failure mode — degrading it
    /// to `.completed` would paint it green and assert success the card cannot back up. It
    /// degrades to `.interrupted` instead; only a wholly absent key means `.completed`.
    @Test("an unknown status decodes as interrupted, never as completed")
    func unknownStatus() {
        let json = """
        {"kind":"job_run","runId":"\(UUID().uuidString)","jobId":"\(UUID().uuidString)",\
        "jobName":"pr-sweep","status":"vaporized","startedAt":"2023-11-14T22:13:20Z",\
        "finishedAt":"2023-11-14T22:14:35Z","totalTokens":0}
        """
        #expect(EventCard.decode(json)?.status == .interrupted)
    }

    @Test("transcriptLine is the copy/export one-liner")
    func transcriptLine() {
        #expect(card().transcriptLine == "[job pr-sweep · completed · 4.2k tokens] swept 3 PRs")
    }

    @Test("transcriptLine drops the outcome when there is none")
    func transcriptLineNoOutcome() {
        #expect(card(status: .failed, outcome: nil, totalTokens: 900).transcriptLine
                == "[job pr-sweep · failed · 900 tokens]")
    }

    @Test("historyLine names the run by its first eight characters")
    func historyLine() {
        let runId = UUID(uuidString: "1A2B3C4D-1111-2222-3333-444455556666")!
        #expect(card(runId: runId).historyLine
                == "[Event] job pr-sweep completed: swept 3 PRs (run 1a2b3c4d)")
    }

    @Test("historyLine drops the outcome when there is none")
    func historyLineNoOutcome() {
        let runId = UUID(uuidString: "1A2B3C4D-1111-2222-3333-444455556666")!
        #expect(card(status: .interrupted, outcome: nil, runId: runId).historyLine
                == "[Event] job pr-sweep interrupted (run 1a2b3c4d)")
    }

    @Test("headline reads job · status, naming the blocked tool")
    func headline() {
        #expect(card().headline == "pr-sweep · completed")
        #expect(card(status: .failed).headline == "pr-sweep · failed")
        #expect(card(status: .blockedOnApproval, blockedTool: "run_command").headline
                == "pr-sweep · blocked on approval: run_command")
        #expect(card(status: .blockedOnApproval).headline == "pr-sweep · blocked on approval")
    }

    @Test("elapsedText is the run's wall time in the session strip's format")
    func elapsed() {
        #expect(card().elapsedText == "1m 15s")
    }

    /// "View run" is enabled only when the transcript the card names still exists — a run that
    /// recorded none, or one retention has since pruned, leaves the card inert. The predicate is
    /// resolved by whoever owns the message list and handed to the row, so an event row does not
    /// read `AppState.conversations` in its own body and re-render on unrelated mutations.
    @Test("transcriptAvailable is true only for an event card whose transcript still exists")
    func transcriptAvailability() {
        let live = UUID()
        let pruned = UUID()
        let conversations = [Conversation(id: live, title: "pr-sweep run")]

        let withTranscript = ChatMessage(role: .event, content: card(transcript: live).encodedContent())
        let goneTranscript = ChatMessage(role: .event, content: card(transcript: pruned).encodedContent())
        let noTranscript = ChatMessage(role: .event, content: card(transcript: nil).encodedContent())
        let notACard = ChatMessage(role: .event, content: "not json")
        let notAnEvent = ChatMessage(role: .agent, content: card(transcript: live).encodedContent())

        #expect(EventCard.transcriptAvailable(for: withTranscript, in: conversations))
        #expect(!EventCard.transcriptAvailable(for: goneTranscript, in: conversations))
        #expect(!EventCard.transcriptAvailable(for: noTranscript, in: conversations))
        #expect(!EventCard.transcriptAvailable(for: notACard, in: conversations))
        #expect(!EventCard.transcriptAvailable(for: notAnEvent, in: conversations))
    }

    @Test("ChatRole.event round-trips as \"event\"")
    func chatRoleRawValue() {
        #expect(ChatRole.event.rawValue == "event")
        #expect(ChatRole(rawValue: "event") == .event)
    }

    @Test("a ChatMessage with role event decodes")
    func chatMessageDecodes() throws {
        let json = #"{"role":"event","content":"{\"kind\":\"job_run\"}"}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(message.role == .event)
    }

    @Test("copy/export renders an event message as its transcript line")
    func exportText() {
        let c = card()
        let message = ChatMessage(role: .event, content: c.encodedContent())
        #expect(message.exportRoleName == "Event")
        #expect(message.exportText == c.transcriptLine)
    }

    @Test("copy/export falls back to raw content when an event does not decode")
    func exportTextUndecodable() {
        let message = ChatMessage(role: .event, content: "not a card")
        #expect(message.exportText == "not a card")
    }

    /// Fix round 1: the export paths shared only the role *name*, and each still interpolated
    /// `content`, so an event row exported as raw JSON under an "Event" heading. These pin the
    /// whole block the four paths now share.
    @Test("an event message's export line is its transcript line, in both formats")
    func exportLineEvent() {
        let c = card()
        let message = ChatMessage(role: .event, content: c.encodedContent())
        #expect(message.exportLine(format: .plainText) == "Event:\n\(c.transcriptLine)")
        #expect(message.exportLine(format: .markdown) == "### Event\n`\(c.transcriptLine)`")
        #expect(!message.exportLine(format: .markdown).contains("\"runId\""))
    }

    @Test("a user message's export line is unchanged")
    func exportLineUser() {
        let message = ChatMessage(role: .user, content: "ship it")
        #expect(message.exportLine(format: .plainText) == "You:\nship it")
        #expect(message.exportLine(format: .markdown) == "### You\nship it")
    }

    @Test("an agent message's export line is unchanged")
    func exportLineAgent() {
        let message = ChatMessage(role: .agent, content: "Done.")
        #expect(message.exportLine(format: .plainText) == "Iris:\nDone.")
        #expect(message.exportLine(format: .markdown) == "### Iris\nDone.")
    }

    @Test("a system message's export line is inline code, with an LLM error shown as its headline")
    func exportLineSystem() {
        let plain = ChatMessage(role: .system, content: "$ ls")
        #expect(plain.exportLine(format: .markdown) == "### System\n`$ ls`")
        #expect(plain.exportLine(format: .plainText) == "System:\n$ ls")

        let error = ChatMessage(role: .system, content: LLMErrorMessage.encode(
            LLMErrorDisplay(headline: "The model call failed (429)", detail: "rate limited")))
        #expect(error.exportText == "The model call failed (429)")
        #expect(error.exportLine(format: .plainText) == "System:\nThe model call failed (429)")
    }

    @Test("copy/export role names are unchanged for the other four roles")
    func exportRoleNames() {
        #expect(ChatMessage(role: .user, content: "").exportRoleName == "You")
        #expect(ChatMessage(role: .system, content: "").exportRoleName == "System")
        #expect(ChatMessage(role: .agent, content: "").exportRoleName == "Iris")
        #expect(ChatMessage(role: .command, content: "").exportRoleName == "Iris")
        #expect(ChatMessage(role: .agent, content: "body").exportText == "body")
    }
}
