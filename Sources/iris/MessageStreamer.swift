import Foundation

/// Grows one agent message in place as text deltas arrive, coalescing UI writes to at most one
/// per `flushIntervalMs` (spec §5.2). One instance per model round; it mints the message id,
/// opens the row on the first delta, and writes the final text exactly once.
actor MessageStreamer {
    typealias Open = @Sendable (UUID, String) async -> Void
    /// (message id, whole text so far, isFinal). `isFinal` is the caller's cue to persist.
    typealias Update = @Sendable (UUID, String, Bool) async -> Void
    typealias Sleep = @Sendable (UInt64) async -> Void

    /// 20 writes per second: well under what MarkdownUI re-parses comfortably for a few-KB
    /// message, above the rate at which any provider produces visually distinct chunks.
    static let flushIntervalMs: UInt64 = 50

    let messageId = UUID()
    private(set) var text = ""
    private(set) var opened = false
    private var lastSent = ""
    private var finished = false
    private var flushTask: Task<Void, Never>?
    private let open: Open
    private let update: Update
    private let sleep: Sleep

    init(open: @escaping Open, update: @escaping Update,
         sleep: @escaping Sleep = { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) }) {
        self.open = open
        self.update = update
        self.sleep = sleep
    }

    func append(_ delta: String) async {
        guard !finished, !delta.isEmpty else { return }
        text += delta
        if !opened {
            opened = true
            lastSent = text
            await open(messageId, text)
            return
        }
        if flushTask == nil {
            flushTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(Self.flushIntervalMs)
                await self.flush()
            }
        }
    }

    private func flush() async {
        flushTask = nil
        guard text != lastSent else { return }
        lastSent = text
        await update(messageId, text, false)
    }

    /// Writes the final content once and asks for it to be persisted. Opens the row first when
    /// nothing streamed (a replayed call delivers its whole text here).
    func finish(_ finalText: String) async {
        finished = true
        flushTask?.cancel()
        flushTask = nil
        text = finalText
        if !opened {
            guard !finalText.isEmpty else { return }
            opened = true
            await open(messageId, finalText)
        }
        lastSent = finalText
        await update(messageId, finalText, true)
    }

    /// Ends the stream with whatever has been shown (error, hook block, Stop) and returns it.
    func settle() async -> String {
        let shown = text
        if opened {
            await finish(shown)
        } else {
            finished = true
        }
        return shown
    }
}
