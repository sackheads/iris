import Testing
import Foundation
@testable import IrisKit

/// #258 — Return on a slash command that already equals a complete command (with no completion
/// left to add) must send instead of re-accepting the popup's highlighted item. A true prefix
/// (`/jo` of `/jobs`) must keep completing as before.
@MainActor
@Suite("SlashCommandModel Return-vs-complete (#258)")
struct SlashCommandModelTests {

    // MARK: shouldAcceptCompletion (pure)

    @Test("a strict prefix still accepts the completion")
    func strictPrefixAccepts() {
        #expect(SlashCommandModel.shouldAcceptCompletion(text: "/jo", completion: "/jobs"))
        #expect(SlashCommandModel.shouldAcceptCompletion(text: "/vibecop", completion: "/vibecop init"))
    }

    @Test("text already equal to the completion has nothing left to accept")
    func exactMatchDoesNotAccept() {
        #expect(!SlashCommandModel.shouldAcceptCompletion(text: "/jobs", completion: "/jobs"))
        #expect(!SlashCommandModel.shouldAcceptCompletion(text: "/vibecop init", completion: "/vibecop init"))
    }

    @Test("equality is case-insensitive")
    func exactMatchIsCaseInsensitive() {
        #expect(!SlashCommandModel.shouldAcceptCompletion(text: "/JOBS", completion: "/jobs"))
    }

    @Test("text longer than the completion has nothing to accept")
    func longerTextDoesNotAccept() {
        #expect(!SlashCommandModel.shouldAcceptCompletion(text: "/jobs ack", completion: "/jobs"))
    }

    // MARK: shouldAcceptOnReturn (model-state integration)

    @Test("the model reports no accept-on-return once the text equals the highlighted command")
    func modelReportsNoAcceptOnExactText() {
        let model = SlashCommandModel()
        model.update(text: "/jobs")
        #expect(model.isShowing)
        #expect(!model.shouldAcceptOnReturn)
    }

    @Test("the model still reports accept-on-return for a strict prefix")
    func modelReportsAcceptOnPrefix() {
        let model = SlashCommandModel()
        model.update(text: "/jo")
        #expect(model.isShowing)
        #expect(model.shouldAcceptOnReturn)
    }

    @Test("commitSelected still inserts the command when invoked directly, as a Tab or click would")
    func commitSelectedStillCommitsOnExactText() {
        let model = SlashCommandModel()
        var committed: SlashCommandItem?
        model.onCommit = { committed = $0 }
        model.update(text: "/jobs")
        model.commitSelected()
        #expect(committed?.command == "/jobs")
        #expect(!model.isShowing)
    }
}
