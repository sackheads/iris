import Testing
import Foundation
import AppKit
@testable import IrisKit

/// D6 decisions 2-4: one derived value answers "does Iris need me?" for every surface. Plain
/// failures and the owner's own pauses never light the icon.
@MainActor
@Suite("Surface attention (D6)", .timeLimit(.minutes(1)))
struct SurfaceAttentionTests {
    private let jobId = UUID()

    private func blocked(_ name: String = "pr-sweep", job: UUID? = nil,
                         tool: String = "run_command") -> LedgerAttention.Blocked {
        LedgerAttention.Blocked(runId: UUID(), jobId: job ?? jobId, jobName: name, tool: tool)
    }

    private func paused(_ reason: String, _ name: String = "pr-sweep") -> LedgerAttention.Paused {
        LedgerAttention.Paused(jobId: UUID(), name: name, reason: reason)
    }

    private func ask(root: UUID?, at offset: TimeInterval = 0) -> SurfaceAttention.Ask {
        SurfaceAttention.Ask(id: UUID(), root: root, requestedAt: Date(timeIntervalSince1970: 1_000 + offset))
    }

    @Test("each input on its own, and the precedence between them")
    func table() {
        let root = UUID(), running = [jobId: RunningJob(name: "pr-sweep", activities: 1),
                                      UUID(): RunningJob(name: "digest", activities: 1)]
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: .empty) == .idle)
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: running, ledger: .empty) == .running(2))

        let asks = SurfaceAttention.derive(asks: [ask(root: root, at: 5), ask(root: UUID(), at: 1)],
                                           waits: [], runningJobs: running, ledger: .empty)
        guard case .actionRequired(let reasons) = asks else { Issue.record("\(asks)"); return }
        if case .approvals(let n, _) = reasons.first { #expect(n == 2) } else { Issue.record("\(reasons)") }
        #expect(asks.actionCount == 2, "an ask outranks running jobs")

        let wait = SurfaceAttention.Wait(conversationId: root, title: "Ship it", phrase: "checkpoint review")
        #expect(SurfaceAttention.derive(asks: [], waits: [wait], runningJobs: [:], ledger: .empty)
                == .actionRequired([.goalWait(conversationId: root, title: "Ship it", phrase: "checkpoint review")]))

        let b = blocked()
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: LedgerAttention(blocked: [b]))
                == .actionRequired([.blocked(b)]))
    }

    @Test("plain failures and the owner's own pauses never produce action required")
    func failuresAndOwnerPausesStayQuiet() {
        let quiet = LedgerAttention(failedCount: 3, ownerPausedCount: 2)
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: quiet) == .idle)
        #expect(SurfaceAttention.derive(asks: [], waits: [],
                                        runningJobs: [jobId: RunningJob(name: "x", activities: 1)],
                                        ledger: quiet) == .running(1))
    }

    @Test("attention pauses are grouped by label, and each paused job counts")
    func pausesGroup() {
        let ledger = LedgerAttention(attentionPaused: [
            paused(JobRunner.budgetReason(scope: "job", used: 9, limit: 5), "a"),
            paused(JobRunner.budgetReason(scope: "global", used: 9, limit: 5), "b"),
            paused(JobRunner.breakerReason(count: 6), "c"),
        ])
        let attention = SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: ledger)
        guard case .actionRequired(let reasons) = attention else { Issue.record("\(attention)"); return }
        let labels = reasons.compactMap { r -> String? in
            if case .paused(let label, let jobs) = r { return "\(label):\(jobs.count)" }
            return nil
        }
        #expect(labels == ["breaker:1", "budget:2"])
        #expect(attention.actionCount == 3)
    }

    @Test("every pause reason the runner writes has its label")
    func pauseLabels() {
        #expect(SurfaceAttention.pauseLabel(JobRunner.breakerReason(count: 6)) == "breaker")
        #expect(SurfaceAttention.pauseLabel(JobRunner.budgetReason(scope: "job", used: 1, limit: 1)) == "budget")
        #expect(SurfaceAttention.pauseLabel(JobRunner.legacyBudgetReasonPrefix + " (job)") == "budget")
        #expect(SurfaceAttention.pauseLabel(JobRunner.retriesExhaustedReason) == "retries used up")
        #expect(SurfaceAttention.pauseLabel(JobRunner.gateFailingReason) == "gate failing")
        #expect(SurfaceAttention.pauseLabel(JobRunner.unknownBuiltinReason("x")) == "unknown built-in")
        #expect(SurfaceAttention.pauseLabel(JobScheduler.unmatchableReason) == "schedule never matches")
        #expect(SurfaceAttention.pauseLabel("watched folder is gone: /tmp/x") == "needs /jobs resume")
    }

    @Test("the three states differ in shape, and dev and release differ in symbol")
    func glyphs() {
        let idle = StatusGlyph.make(.idle, identity: .dev)
        let running = StatusGlyph.make(.running(2), identity: .dev)
        let action = StatusGlyph.make(.actionRequired([.blocked(blocked()), .blocked(blocked())]), identity: .dev)
        #expect(idle.text == nil)
        #expect(running.text == "2")
        #expect(action.text == "!2")
        #expect(Set([idle.symbol, running.symbol, action.symbol]) == ["hammer"])
        #expect(StatusGlyph.make(.idle, identity: .release).symbol == "sparkles")
        #expect(BuildIdentity.release.statusSymbol != BuildIdentity.dev.statusSymbol)
    }

    /// R10: one row per job however many of its runs are blocked, so a job blocking every
    /// minute cannot grow the menu without bound. The row opens the oldest run's card.
    @Test("an approvals row with no root conversation still opens the window, on Iris")
    func rootlessApprovalsRowIsClickable() {
        let attention = SurfaceAttention.derive(asks: [ask(root: nil)], waits: [], runningJobs: [:], ledger: .empty)
        let rows = SurfaceAttention.menuRows(attention, ledger: .empty, runningCount: 0)
        #expect(rows.first?.id == "approvals")
        // The overlay shows the first ask whatever is selected, so raising the window answers it.
        #expect(rows.first?.target == .iris)
    }

    @Test("the menu says what is waiting, one row per blocked job, with secondary counts below")
    func menuRows() {
        let root = UUID(), digestJob = UUID()
        let b = blocked("pr\nsweep"), again = blocked("pr\nsweep")
        let digest = blocked("digest", job: digestJob, tool: "write_file")
        let ledger = LedgerAttention(blocked: [b, digest, again], failedCount: 3,
                                     attentionPaused: [paused(JobRunner.budgetReason(scope: "job", used: 9, limit: 5))],
                                     ownerPausedCount: 1)
        let attention = SurfaceAttention.derive(asks: [ask(root: root), ask(root: root)], waits: [],
                                                runningJobs: [:], ledger: ledger)
        #expect(attention.actionCount == 6, "the icon still counts every blocked run")
        let rows = SurfaceAttention.menuRows(attention, ledger: ledger, runningCount: 1)
        #expect(rows.map(\.text) == ["2 approvals waiting", "pr sweep blocked: run_command (×2)",
                                     "digest blocked: write_file",
                                     "1 job paused (budget)", "1 job running", "3 failed runs",
                                     "1 job paused by you"])
        #expect(rows[0].target == .conversation(root))
        #expect(rows[1].target == .card(runId: b.runId, jobId: b.jobId))
        #expect(rows[2].target == .card(runId: digest.runId, jobId: digestJob))
        #expect(rows[4].target == .nowhere)
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids are unique")

        let mixed = LedgerAttention(blocked: [blocked(), blocked(tool: "write_file")])
        let mixedRows = SurfaceAttention.menuRows(
            SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: mixed),
            ledger: mixed, runningCount: 0)
        #expect(mixedRows.map(\.text) == ["pr-sweep blocked: run_command and others (×2)"],
                "a row never names one tool for runs blocked on several")
    }

    // MARK: Wiring

    private func makeApp() throws -> AppState {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        return app
    }

    @Test("a delegate's ask is charged to the conversation it works for")
    func delegateAskChargedToRoot() async throws {
        let app = try makeApp()
        let parent = app.createNewConversation(), child = app.createNewConversation(isSubagent: true)
        app.linkDelegate(child, of: parent)
        let ask = Task { @MainActor in
            await app.enqueueUserApproval(toolName: "run_command", details: "make test", workspace: nil,
                                          conversationId: child, origin: "test")
        }
        var spins = 0
        while app.pendingApprovals.isEmpty, spins < 10_000 { await Task.yield(); spins += 1 }

        guard case .actionRequired(let reasons) = app.surfaceAttention else {
            Issue.record("\(app.surfaceAttention)"); return
        }
        #expect(reasons.first == .approvals(count: 1, conversationId: parent))

        app.resolveApproval(id: try #require(app.pendingApprovals.first).id, .deny)
        #expect(try await value(of: ask) == false)
        #expect(app.surfaceAttention == .idle)
    }

    @Test("a goal draft lights the icon only in a user-facing, unarchived conversation")
    func draftScope() throws {
        let app = try makeApp()
        let id = app.createNewConversation(title: "Ship it")
        app.setDraftContract(for: id, GoalContract(objective: "ship it",
                                                  criteria: [Criterion(text: "tests pass", kind: .qualitative)]))
        #expect(app.surfaceAttention == .actionRequired([
            .goalWait(conversationId: id, title: "Ship it", phrase: "goal contract to review")]))

        let idx = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[idx].isArchived = true
        #expect(app.surfaceAttention == .idle, "an archived conversation's draft never lights the icon")

        app.conversations[idx].isArchived = false
        app.conversations[idx].isBackground = true
        #expect(app.surfaceAttention == .idle, "nor does a background run's")
    }
}

/// The menu bar keeps one element of a `MenuBarExtra` label, so a counted glyph must arrive as one
/// image holding both the symbol and the count (the GUI pass on #473).
@MainActor
@Suite("Status item image (D6)")
struct StatusItemImageTests {
    @Test("idle is the bare symbol; a count is one template image wider than the symbol alone")
    func countedGlyphIsOneImage() throws {
        #expect(StatusItemImage.make(StatusGlyph.make(.idle, identity: .dev)) == nil)

        let symbol = try #require(NSImage(systemSymbolName: "hammer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)))
        for attention in [SurfaceAttention.running(1), .actionRequired([.approvals(count: 2, conversationId: nil)])] {
            let glyph = StatusGlyph.make(attention, identity: .dev)
            let image = try #require(StatusItemImage.make(glyph))
            #expect(image.isTemplate)
            #expect(image.size.width > symbol.size.width + StatusItemImage.spacing, "the count is drawn beside the symbol")
            #expect(image.accessibilityDescription == glyph.accessibilityLabel)
        }
    }

    @Test("the image draws both the symbol and the count, neither half blank")
    func symbolIsDrawn() throws {
        let glyph = StatusGlyph.make(.running(1), identity: .release)
        let image = try #require(StatusItemImage.make(glyph))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * 2,
                                                pixelsHigh: Int(image.size.height) * 2, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        func inked(_ columns: Range<Int>) -> Bool {
            for x in columns { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { return true } }
            return false
        }
        let symbolWidth = Int(NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular))?
            .size.width ?? 0) * 2
        #expect(symbolWidth > 0)
        #expect(inked(0..<symbolWidth), "the symbol is in the image")
        #expect(inked(symbolWidth..<rep.pixelsWide), "and so is the count")
    }
}
