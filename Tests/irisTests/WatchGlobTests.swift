import Testing
import Foundation
@testable import iris

/// #187 deliverable 4, spec §0.4 — the ignore matcher. Two things are load-bearing and neither is
/// obvious from the pattern strings: the built-in set has to catch the names editors and VCSs
/// actually produce (a `4913` from Vim, a `.#f` from Emacs, Foundation's `f.sb-9f`), and `*` has
/// to stop at a `/` so a watch's own glob cannot silently swallow a whole subtree it never named.
@Suite("Watch globs (#187)")
struct WatchGlobTests {

    @Test("the built-in set catches editor and VCS noise and leaves real files alone")
    func builtInSetMatchesTheExpectedNames() {
        let ignored = WatchGlob.matcher(WatchCoordinator.builtInIgnore)
        for name in [".git/HEAD", "a/.DS_Store", "node_modules/x/y.js", "f~", ".f.swp", ".#f",
                     "4913", "x.tmp", ".notes.md.sb-9f",
                     // Measured on macOS 26 (Darwin 25.6): `Data.write(options: .atomic)` stages
                     // as `<name>.sb-<hex>-<rand>` beside the file, with no leading dot. Seen on
                     // screen as a "changed file" handed to a run before the pattern was widened.
                     "agent.txt.sb-f1f3bd48-yAcDX5",
                     "(A Document Being Saved By TextEdit)"] {
            #expect(ignored(name), "the built-in set should absorb \(name)")
        }
        for name in ["notes.md", "src/main.swift"] {
            #expect(!ignored(name), "the built-in set should not absorb \(name)")
        }
    }

    @Test("a star stops at a slash")
    func starDoesNotCrossSlash() {
        #expect(WatchGlob("src/*").matches(relativePath: "src/a.swift"))
        #expect(!WatchGlob("src/*").matches(relativePath: "src/deep/a.swift"))
        #expect(WatchGlob("src/*.swift").matches(relativePath: "src/a.swift"))
        #expect(!WatchGlob("src/*.swift").matches(relativePath: "src/deep/a.swift"))
        // `?` is exactly one character, and not the separator either.
        #expect(WatchGlob("a/?.txt").matches(relativePath: "a/b.txt"))
        #expect(!WatchGlob("a/?.txt").matches(relativePath: "a/bb.txt"))
        #expect(!WatchGlob("a/?").matches(relativePath: "a/b/c"))
        // A pattern with no slash is a component pattern, so it does match the leaf of a nested
        // path — that is the rule that makes `.DS_Store` catch `a/.DS_Store`, not a leak.
        #expect(WatchGlob("?.txt").matches(relativePath: "a/b.txt"))
    }

    @Test("a double star spans components, including none at all")
    func doubleStarDoes() {
        #expect(WatchGlob("src/**/*.md").matches(relativePath: "src/deep/down/notes.md"))
        #expect(WatchGlob("src/**/*.md").matches(relativePath: "src/notes.md"),
                "`**` spans zero components as well as many")
        #expect(!WatchGlob("src/**/*.md").matches(relativePath: "docs/notes.md"))
        #expect(WatchGlob("**/build").matches(relativePath: "a/b/build"))
    }

    @Test("a trailing slash is the directory and everything under it")
    func trailingSlashIsASubtree() {
        #expect(WatchGlob("build/").matches(relativePath: "build"))
        #expect(WatchGlob("build/").matches(relativePath: "build/x/y.o"))
        #expect(!WatchGlob("build/").matches(relativePath: "builder/x"))
        // Anchored, because it has an inner slash: only this subtree, not one of the same name
        // somewhere else.
        #expect(WatchGlob("src/gen/").matches(relativePath: "src/gen/a.swift"))
        #expect(!WatchGlob("src/gen/").matches(relativePath: "lib/src/gen/a.swift"))
    }

    /// Task 6's refusal is decided here rather than by reading the pattern text: a list that
    /// absorbs every probe absorbs everything the watch could ever fire on, which is a watch that
    /// silently never runs. The two near-misses matter as much as the hits — `*.*` looks
    /// all-consuming and is not, because a file with no dot in its name still fires.
    @Test("a glob list that absorbs every probe is refusable, and near-misses are not")
    func probeRefusal() {
        #expect(WatchGlob.ignoresEveryProbe(["*"]))
        #expect(WatchGlob.ignoresEveryProbe(["**/*"]))
        #expect(WatchGlob.ignoresEveryProbe(["?*"]))
        #expect(!WatchGlob.ignoresEveryProbe(["*.*"]), "`sub/dir/c` has no dot in any component")
        #expect(!WatchGlob.ignoresEveryProbe(["*.md"]))
        #expect(!WatchGlob.ignoresEveryProbe([]), "no globs absorb nothing")
        #expect(!WatchGlob.ignoresEveryProbe(WatchCoordinator.builtInIgnore),
                "the built-in set is not a refusal")
    }
}
