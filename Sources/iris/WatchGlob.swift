import Foundation

/// One ignore pattern, relative to a watch root (#187 deliverable 4, spec §0.4).
///
/// Written here rather than reached for through `fnmatch(3)` because the two rules that matter are
/// rules `fnmatch` does not have in the shape this needs: `**` has to span components, and a
/// pattern with no `/` in it has to match *any* component so `.DS_Store` catches `a/.DS_Store`
/// without anybody writing `**/.DS_Store`. It is also the difference between a refusal Task 6 can
/// compute (`ignoresEveryProbe`) and one it has to guess at by reading pattern text.
///
/// Leading dots are not special. A shell glob's `*` deliberately skips dotfiles; here the whole
/// point of `*.swp` is to catch Vim's `.notes.md.swp`, so it does.
///
/// Matching is case-insensitive (R-D4-7), for the same reason root coverage is: the default macOS
/// volume is case-insensitive, `realpath` keeps whatever casing its caller used, and an ignore list
/// that absorbs `.DS_Store` but not `.ds_store` — or `*.TMP` but not `*.tmp` — is a filter that
/// works until the day something writes the other spelling. Patterns are lower-cased once at
/// construction and candidates once per component, so the fold costs nothing per pattern. On a
/// case-sensitive volume this absorbs a little more than it was asked to, which is the direction
/// an ignore list should fail in.
struct WatchGlob: Sendable {
    /// One component's pattern, or the `**` that stands for any number of components.
    private enum Segment: Sendable, Equatable {
        case anyComponents          // `**`
        case pattern([Character])   // `*`, `?` and literals, none of which cross a `/`
    }

    private let segments: [Segment]
    /// Whether the pattern named a directory (`build/`) and therefore also everything under it.
    private let subtree: Bool
    /// Whether the pattern had no `/` at all, and so matches any single component at any depth.
    private let componentOnly: Bool

    init(_ pattern: String) {
        var text = pattern
        var trailingSlash = false
        while text.hasSuffix("/") {
            trailingSlash = true
            text.removeLast()
        }
        while text.hasPrefix("/") { text.removeFirst() }   // a leading `/` is the root; it already is
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        subtree = trailingSlash
        componentOnly = parts.count <= 1
        // Folded once, here: `matches` then folds only the candidate's components.
        segments = parts.map { $0 == "**" ? .anyComponents : .pattern(Array($0.lowercased())) }
    }

    /// Whether `relativePath` — a path relative to the watch root, with no leading slash — is
    /// absorbed by this pattern.
    func matches(relativePath: String) -> Bool {
        let components = relativePath.lowercased()
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, let first = segments.first else { return false }
        if componentOnly {
            // A bare name is a name, wherever it appears: `.DS_Store` catches `a/b/.DS_Store`, and
            // `node_modules/` catches everything below the first one it finds.
            if case .anyComponents = first { return true }
            guard case .pattern(let p) = first else { return false }
            return components.contains { Self.matches(pattern: p, component: Array($0)) }
        }
        return Self.match(segments[...], components[...], allowTrailing: subtree)
    }

    /// Anchored, component by component. `allowTrailing` is the trailing-slash case: the pattern
    /// has to account for a *prefix* of the path rather than all of it.
    private static func match(_ pattern: ArraySlice<Segment>, _ components: ArraySlice<String>,
                              allowTrailing: Bool) -> Bool {
        guard let head = pattern.first else { return allowTrailing || components.isEmpty }
        if case .anyComponents = head {
            // Zero components first, so `src/**/*.md` catches `src/notes.md`.
            var index = components.startIndex
            while true {
                if match(pattern.dropFirst(), components[index...], allowTrailing: allowTrailing) { return true }
                if index == components.endIndex { return false }
                index = components.index(after: index)
            }
        }
        guard case .pattern(let p) = head, let component = components.first,
              matches(pattern: p, component: Array(component)) else { return false }
        return match(pattern.dropFirst(), components.dropFirst(), allowTrailing: allowTrailing)
    }

    /// `*` and `?` within one component. Iterative with a single backtrack point rather than
    /// recursive: a pattern like `*a*a*a*` over a long filename is the classic way to make a
    /// recursive matcher take exponential time, and these run on every event of every batch.
    private static func matches(pattern: [Character], component: [Character]) -> Bool {
        var p = 0, c = 0
        var starAt = -1, matchedTo = 0
        while c < component.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == component[c] {
                p += 1; c += 1
            } else if p < pattern.count, pattern[p] == "*" {
                starAt = p
                matchedTo = c
                p += 1
            } else if starAt >= 0 {
                p = starAt + 1
                matchedTo += 1
                c = matchedTo
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// The compiled form: patterns are parsed once and the closure is what the hot path calls, so
    /// a batch of a thousand events does not re-parse eleven built-in patterns a thousand times.
    static func matcher(_ patterns: [String]) -> @Sendable (String) -> Bool {
        let globs = patterns.map(WatchGlob.init)
        return { path in globs.contains { $0.matches(relativePath: path) } }
    }

    /// The names a watch must still be able to fire on. Deliberately ordinary and deliberately
    /// varied: a dotfile, a file with no extension, a nested path.
    static let probes = ["a.txt", "dir/b.md", ".hidden", "x.swift", "sub/dir/c"]

    /// Whether `patterns` absorbs every probe — a watch that could never fire on anything, which
    /// Task 6 refuses at the tool rather than creating in silence. Decided by the compiled matcher
    /// and not by reading the pattern text, because the patterns that do this are not the ones
    /// that look like it: `*.*` reads as all-consuming and is not (`sub/dir/c` has no dot).
    static func ignoresEveryProbe(_ patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let ignored = matcher(patterns)
        return probes.allSatisfy(ignored)
    }
}
