import Testing
import Foundation
@testable import iris

/// The self-write filter's memory (#187 deliverable 4, spec §4, ruling R-D4-1).
///
/// Every test builds its own `RecentWrites` over a clock it moves by hand (invariant 7): the
/// registry is the one place in this deliverable where the *instant* of a write decides an
/// outcome, and a suite that slept for it would be both slow and flaky. `RecentWrites.shared` is
/// never touched here.
@Suite("RecentWrites — what an unattended run just wrote")
struct RecentWritesTests {

    /// A clock the test advances. `@unchecked Sendable` over a lock rather than an actor because
    /// `RecentWrites.init(now:)` takes a synchronous closure — the registry asks the time from
    /// inside its own isolation and cannot await an answer.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { t = start }
        var now: Date { lock.withLock { t } }
        func advance(_ seconds: TimeInterval) { lock.withLock { t = t.addingTimeInterval(seconds) } }
        var closure: @Sendable () -> Date { { [self] in now } }
    }

    private func registry(_ clock: FakeClock) -> RecentWrites {
        RecentWrites(now: clock.closure)
    }

    private func tempDirectory(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: matching

    @Test("one recorded write owns the file, its directory, and the temp files an atomic write leaves")
    func exactParentAndSiblingMatch() async {
        let clock = FakeClock()
        let r = registry(clock)
        await r.record("/w/notes.md")

        #expect(await r.isOwn("/w/notes.md", within: 5), "the file itself")
        #expect(await r.isOwn("/w", within: 5), "the directory-modified event the write produces")
        #expect(await r.isOwn("/w/.notes.md.sb-1a2b", within: 5), "Foundation's atomic staging file")
        #expect(await r.isOwn("/w/notes.md.sb-f1f3bd48-yAcDX5", within: 5),
                "the spelling `Data.write(options: .atomic)` actually uses on macOS 26: no leading dot")
        #expect(await r.isOwn("/w/notes.md.tmp", within: 5), "the other atomic temp spelling")
        #expect(await r.isOwn("/w/(A Document Being Saved By Iris)", within: 5), "and the third")
        #expect(!(await r.isOwn("/w/other.md", within: 5)),
                "a sibling that is not a temp form of this write is somebody else's file")
    }

    @Test("a match does not consume the entry — one write produces several events")
    func noConsumptionOnMatch() async {
        let clock = FakeClock()
        let r = registry(clock)
        await r.record("/w/notes.md")

        // The create, the rename and the directory modification of a single atomic write.
        #expect(await r.isOwn("/w/.notes.md.sb-9f", within: 5))
        #expect(await r.isOwn("/w/notes.md", within: 5))
        #expect(await r.isOwn("/w", within: 5))
        #expect(await r.count == 1, "expiry ends an entry's effect, matching never does")
    }

    // MARK: time

    @Test("expiry is the quiet window capped at 30, plus two, and the boundary is exclusive")
    func expiryIsExactlyWindowPlusTwo() async {
        #expect(RecentWrites.expiry(quietWindowSeconds: 3) == 5)
        #expect(RecentWrites.expiry(quietWindowSeconds: 300) == 32)

        let clock = FakeClock()
        let r = registry(clock)
        await r.record("/w/notes.md")

        clock.advance(4.999)
        #expect(await r.isOwn("/w/notes.md", within: 5), "still inside the window")
        clock.advance(0.001)
        #expect(!(await r.isOwn("/w/notes.md", within: 5)),
                "at the expiry exactly, a hand edit is nobody's but the hand's")
    }

    @Test("a record sweeps entries older than the longest live expiry")
    func timeSweepRemovesOldEntries() async {
        let clock = FakeClock()
        let r = registry(clock)
        await r.record("/w/first.md")
        clock.advance(33)
        await r.record("/w/second.md")

        #expect(await r.count == 1, "32 s is the longest window anything can ask about")
        #expect(await r.isOwn("/w/second.md", within: 32))
        #expect(!(await r.isOwn("/w/first.md", within: 32)))
    }

    // MARK: the recorded spelling

    @Test("the recorded path is symlink-resolved and standardised, so FSEvents' spelling matches")
    func recordedPathIsSymlinkResolved() async throws {
        let dir = try tempDirectory("recentwrites-real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.deletingLastPathComponent()
            .appendingPathComponent("iris-recentwrites-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }

        let clock = FakeClock()
        let r = registry(clock)
        let throughTheLink = link.appendingPathComponent("notes.md").path
        // Written first, because that is the order the hook runs in.
        try "notes".write(toFile: throughTheLink, atomically: true, encoding: .utf8)
        await r.record(throughTheLink)

        // The exact form, spelled out rather than recomputed: `standardizedFileURL` strips a
        // leading `/private` on macOS, so a write under the temp directory is remembered as
        // `/var/folders/…` — which is the spelling FSEvents reports and the coordinator will
        // normalise event paths into.
        let resolved = "\(dir.path)/notes.md"
        #expect(resolved.hasPrefix("/var/folders/"), "precondition: the temp directory is under /var")
        #expect(await r.isOwn(resolved, within: 5))
        #expect(await r.isOwn(dir.path, within: 5), "and its parent, in the resolved spelling")
        #expect(!(await r.isOwn("/private\(resolved)", within: 5)),
                "the `/private` spelling is not what was stored")
        #expect(!(await r.isOwn(throughTheLink, within: 5)),
                "matching is lexical: the link's own spelling was never recorded")

        // A path whose leaf is already gone — what `delete_skill` records, a folder it has just
        // removed. `resolvingSymlinksInPath` alone returns such a path unchanged, symlinked
        // parents and all; `IrisPaths.canonicalPath` resolves the deepest ancestor that does
        // exist, so both spellings still agree.
        let removed = link.appendingPathComponent("gone").path
        await r.record(removed)
        #expect(await r.isOwn("\(dir.path)/gone", within: 5),
                "a deleted leaf records its parent-resolved form")
        #expect(!(await r.isOwn(removed, within: 5)))
    }

    // MARK: bounds

    @Test("the ten-thousand valve holds, and the oldest entry is the one that goes")
    func theValveHoldsTenThousand() async {
        let clock = FakeClock()
        let r = registry(clock)
        // All inside one second, so nothing here is swept by time — the valve is the only thing
        // that can be removing anything.
        for i in 0...RecentWrites.maxEntries {
            await r.record("/w/file-\(i).md")
            clock.advance(1.0 / Double(RecentWrites.maxEntries))
        }

        #expect(await r.count == RecentWrites.maxEntries)
        // The documented failure direction: over the valve, the earliest write's own events look
        // like somebody else's. Nobody should be relying on this; the test says which way it goes.
        #expect(!(await r.isOwn("/w/file-0.md", within: 32)))
        #expect(await r.isOwn("/w/file-\(RecentWrites.maxEntries).md", within: 32))
    }
}
