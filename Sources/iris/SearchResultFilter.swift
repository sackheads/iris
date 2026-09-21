import Foundation

/// Splits a `search_web` payload into its individual results so the injection guard scores each
/// one as its own prompt (#235).
///
/// `ToolExecutor.searchWeb` prints a JSON array of up to ten `{"title","url","snippet"}` objects.
/// Handing that whole blob to the tier-2 classifier scored ten concatenated marketing snippets,
/// ten URLs and the JSON scaffolding as a single prompt — it came back 0.94-0.999 malicious and
/// every result was replaced by one blocked marker, which sent research subagents into a loop of
/// rephrased searches. One result at a time is a shape the classifier was actually trained on.
enum SearchResultFilter {
    struct Outcome: Equatable, Sendable {
        let json: String
        let kept: Int
        let withheld: Int
    }

    /// What the classifier sees for one result: the title, a newline, the snippet, tier-1
    /// normalized. The URL is never scored — a query string full of tracking parameters looks
    /// like an injection to a token classifier and carries no prose to judge.
    ///
    /// `PromptInjectionGuard.sanitizeUntrustedInput` runs here, on the joined text, for the same
    /// reason the whole-output path runs it before scoring: without the NFKC fold and the
    /// control-character strip, a zero-width character or a homoglyph in a snippet is enough to
    /// walk a real injection past the classifier. Joined rather than per-field so a pattern
    /// straddling the newline is caught too. The stored result keeps its original title, url and
    /// snippet — normalization is what gets *scored*, not what gets returned.
    static func scoringText(title: String, snippet: String) -> String {
        PromptInjectionGuard.sanitizeUntrustedInput("\(title)\n\(snippet)")
    }

    /// Scores each result and re-serializes the survivors.
    ///
    /// Returns nil when `raw` is not a JSON array of objects — the script's `{"error": "..."}`
    /// object, an empty string, or anything else unparseable. The caller then falls back to
    /// sanitizing the whole output, so a shape we do not understand is never let through unscored.
    ///
    /// `allowed` is called once per result with `scoringText`; returning false withholds it.
    /// Results are scored sequentially, in order: the guard's verdict cache and its latency
    /// metrics both assume serialized calls, so this must not become a task group.
    static func filter(_ raw: String, allowed: @Sendable (String) async -> Bool) async -> Outcome? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let array = parsed as? [Any] else { return nil }

        var objects: [[String: Any]] = []
        for element in array {
            guard let object = element as? [String: Any] else { return nil }
            objects.append(object)
        }

        var survivors: [[String: String]] = []
        var withheld = 0
        for object in objects {
            // A missing field is an empty string, never a reason to drop the result: the parser
            // only emits complete objects today, and a future one that does not should still
            // return what it has.
            let title = object["title"] as? String ?? ""
            let url = object["url"] as? String ?? ""
            let snippet = object["snippet"] as? String ?? ""
            if await allowed(scoringText(title: title, snippet: snippet)) {
                survivors.append(["title": title, "url": url, "snippet": snippet])
            } else {
                withheld += 1
            }
        }

        guard let json = serialize(survivors) else { return nil }
        let note = withheld > 0
            ? "\n[\(withheld) of \(objects.count) search results withheld by the injection guard]"
            : ""
        return Outcome(json: json + note, kept: survivors.count, withheld: withheld)
    }

    /// Deterministic pretty-printed JSON with sorted keys and unescaped slashes, carrying the same
    /// three fields the scraper emits. Not byte-identical to the script's `json.dumps(indent=2)`
    /// — key order is alphabetical here, and non-ASCII stays raw UTF-8 where Python escapes it.
    /// `JSONSerialization` pretty-prints an empty array as `[\n\n]`, which is noise; emit the
    /// literal instead.
    private static func serialize(_ results: [[String: String]]) -> String? {
        guard !results.isEmpty else { return "[]" }
        guard let data = try? JSONSerialization.data(withJSONObject: results,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
