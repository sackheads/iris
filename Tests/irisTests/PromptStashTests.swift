import Testing
@testable import IrisKit

/// #933: Cmd-S stashes the composer's current text and clears the input; the next send refills
/// it. One slot, in-memory (matches the Claude Code behavior the issue describes) — pure logic
/// so `ChatView`'s handlers are thin dispatchers onto it.
@Suite("Prompt stash (#933)")
struct PromptStashTests {
    @Test("stashing non-empty input clears the field and fills the slot")
    func stashesNonEmptyInput() {
        let result = PromptStash.stashing(input: "finish the refactor", existingStash: nil)
        #expect(result.newInput == "")
        #expect(result.newStash == "finish the refactor")
    }

    @Test("stashing empty (or whitespace-only) input is a no-op: nothing to stash, nothing cleared")
    func emptyInputIsNoOp() {
        let result = PromptStash.stashing(input: "   \n  ", existingStash: "already stashed")
        #expect(result.newInput == "   \n  ", "unchanged: no-op leaves the input exactly as it was")
        #expect(result.newStash == "already stashed", "the existing stash is untouched, never cleared by an empty press")
    }

    @Test("stashing while a stash already exists overwrites it: single slot, last one wins")
    func overwritesExistingStash() {
        let result = PromptStash.stashing(input: "a second thing", existingStash: "the first thing")
        #expect(result.newInput == "")
        #expect(result.newStash == "a second thing")
    }

    @Test("refilling a pending stash fills the input and consumes the slot")
    func refillsPendingStash() {
        let result = PromptStash.refilling(stash: "finish the refactor")
        #expect(result.newInput == "finish the refactor")
        #expect(result.newStash == nil, "a stash is used once")
    }

    @Test("refilling with no stash pending is a no-op: no input is produced")
    func noStashIsNoOp() {
        let result = PromptStash.refilling(stash: nil)
        #expect(result.newInput == nil)
        #expect(result.newStash == nil)
    }
}
