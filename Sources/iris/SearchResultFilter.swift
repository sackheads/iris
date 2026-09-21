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

    /// What the classifier sees for one result: the title, a newline, the snippet. The URL is
    /// never scored — a query string full of tracking parameters looks like an injection to a
    /// token classifier and carries no prose to judge.
    static func scoringText(title: String, snippet: String) -> String {
        "\(title)\n\(snippet)"
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
    ///
    /// `isolation` is the caller's actor (defaulted, never passed explicitly): scoring runs on the
    /// engine actor that owns the tool call, so `allowed` may capture actor state without being
    /// `@Sendable` and nothing here hops off that actor.
    static func filter(_ raw: String, isolation: isolated (any Actor)? = #isolation,
                       allowed: (String) async -> Bool) async -> Outcome? {
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

    /// Matches the script's own `json.dumps(..., indent=2)` shape so the model sees the same
    /// formatting whether or not anything was withheld. `JSONSerialization` pretty-prints an
    /// empty array as `[\n\n]`, which is noise; emit the literal instead.
    private static func serialize(_ results: [[String: String]]) -> String? {
        guard !results.isEmpty else { return "[]" }
        guard let data = try? JSONSerialization.data(withJSONObject: results,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
