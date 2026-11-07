import Foundation

/// The composer's Cmd-S prompt stash (#933, "steal a new feature from Claude Code"): Cmd-S stashes
/// the composer's current text and clears the input; the next send refills it. One slot,
/// in-memory — a restart losing it is acceptable, same as the rest of the composer's draft state
/// (`ChatView`'s `inputText`/`draftAttachments`), which is never persisted either. Pure, so
/// `ChatView`'s handlers are thin dispatchers onto it rather than untestable `@State` mutation.
enum PromptStash {
    /// What Cmd-S does to the composer's current state. Whitespace-only input is treated as
    /// nothing to stash: a stray Cmd-S with an empty field must not silently clear a stash the
    /// user is still waiting to send (no-op, existing stash passes through unchanged). Otherwise
    /// the single slot is overwritten — last stash wins, there is no stack — and the input clears.
    static func stashing(input: String, existingStash: String?) -> (newInput: String, newStash: String?) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (input, existingStash)
        }
        return ("", input)
    }

    /// What sending a message does to a pending stash: refills the input with it and consumes the
    /// slot — a stash is used once. No stash pending is a no-op (`newInput: nil` means "don't
    /// touch the input", distinct from refilling it with an empty string).
    static func refilling(stash: String?) -> (newInput: String?, newStash: String?) {
        guard let stash else { return (nil, nil) }
        return (stash, nil)
    }
}
