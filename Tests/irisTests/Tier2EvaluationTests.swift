import Testing
import Foundation
import Darwin
@testable import IrisKit

// #770: tier 2's accuracy and cost on realistic tool output, measured through the product's own
// path, not the raw model alone. The fixtures (`Fixtures/tier2-eval/`, made by
// `scripts/gen_tier2_eval_fixtures.py`; sources in its README) are checked on every run; the model
// runs are opt-in, since the bundle is 704 MB:
//
//   IRIS_ONNX_TEST_BUNDLE=~/.iris/models/deberta-v3-base-prompt-injection-v2.onnx \
//     scripts/test-filter.sh Tier2EvaluationTests
//
// prints the accuracy table (and writes it to IRIS_TIER2_REPORT, if set). The performance probe
// also needs IRIS_TIER2_PERF=1 and must run alone, in a fresh process each time, since it reads
// the process's footprint before the model loads:
//
//   IRIS_TIER2_PERF=1 IRIS_ONNX_TEST_BUNDLE=... scripts/test-filter.sh Tier2PerformanceProbe
//
// Neither asserts a bar: the numbers are a record for the owner's decision (docs/prompt_guard_coreml.md).

struct Tier2Sample: Decodable {
    let id: String
    let category: String
    let source: String
    let text: String
    let payload: String?

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tier2-eval")

    static func load(_ name: String) throws -> [Tier2Sample] {
        let data = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return try data.split(separator: "\n").map { try JSONDecoder().decode(Tier2Sample.self, from: Data($0.utf8)) }
    }
}

/// What the product did with one text.
enum Tier2ProductVerdict: String {
    case passed, withheld, blocked
}

@Suite("Tier 2 evaluation fixtures (#770)")
struct Tier2EvaluationFixtureTests {
    @Test("the fixtures meet the issue's minimums, and every attack's payload is in its text")
    func fixtures() throws {
        let benign = try Tier2Sample.load("benign.jsonl"), attacks = try Tier2Sample.load("attacks.jsonl")
        #expect(benign.count >= 200)
        #expect(attacks.count >= 60)
        #expect(Set((benign + attacks).map(\.id)).count == benign.count + attacks.count, "ids are unique")
        #expect(benign.allSatisfy { $0.payload == nil })
        for attack in attacks {
            let payload = try #require(attack.payload, "\(attack.id) names its payload")
            #expect(attack.text.contains(payload), "\(attack.id)")
            // Recall is judged by the payload's absence from what the guard passes on, so tier 1
            // must leave it intact: no role delimiter it strips, nothing NFKC changes.
            #expect(PromptInjectionGuard.sanitizeUntrustedInput(payload) == payload, "\(attack.id)")
        }
        #expect(attacks.contains { $0.category == "known_miss" })
    }
}

#if canImport(OnnxRuntimeBindings) && canImport(Tokenizers)
enum Tier2Bundle {
    static var url: URL? {
        guard let path = ProcessInfo.processInfo.environment["IRIS_ONNX_TEST_BUNDLE"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("model.onnx").path) ? url : nil
    }

    static func load() async throws -> LiveONNXModel {
        let url = try #require(url)
        return try await LiveONNXModel(modelURL: url.appendingPathComponent("model.onnx"), tokenizerConfigURL: url)
    }

    /// A tool result as `IrisEngine` guards it: capped, then `sanitizeUntrusted`'s path (tier 1's
    /// normalization and delimiter strip, then tier 2's windows, narrowing, phrase and delimiter
    /// lines), stopping at tier 2. The model is task-scoped, so nothing global changes.
    static func product(_ text: String, model: LiveONNXModel) async -> (verdict: Tier2ProductVerdict, shown: String) {
        let outcome = await CoreMLEvaluator.$scopedModel.withValue(.init(model)) {
            await InjectionGuard.classifyUntrusted(OutputCap.cap(text), contextTag: "tool_output_run_command",
                                                   maxTier: .tier2_coreML, protectionEnabled: true)
        }
        switch outcome {
        case .blocked(let marker): return (.blocked, marker)
        case .passed(let clean):
            return (clean.contains("withheld by the injection guard") ? .withheld : .passed, clean)
        }
    }

    /// The 1-based line ranges named by the withheld markers in `shown`.
    static func withheldRanges(_ shown: String) -> [ClosedRange<Int>] {
        let pattern = try! NSRegularExpression(pattern: #"\[lines? (\d+)(?:-(\d+))? of this output withheld"#)
        return pattern.matches(in: shown, range: NSRange(shown.startIndex..., in: shown)).map { m in
            let a = Int((shown as NSString).substring(with: m.range(at: 1)))!
            let b = m.range(at: 2).location == NSNotFound ? a : Int((shown as NSString).substring(with: m.range(at: 2)))!
            return a...b
        }
    }

    static func withheldLines(_ shown: String) -> Int { withheldRanges(shown).reduce(0) { $0 + $1.count } }
}

@Suite("Tier 2 evaluation on the real model (#770, opt-in)", .timeLimit(.minutes(30)))
struct Tier2EvaluationTests {
    struct Row {
        var n = 0, rawFlagged = 0, passed = 0, withheld = 0, blocked = 0, caught = 0
        var raw: [Double] = []
        var linesWithheld = 0, lines = 0
        var misses: [String] = []
    }

    @Test("accuracy: raw score and product verdict per category", .enabled(if: Tier2Bundle.url != nil))
    func accuracy() async throws {
        let model = try await Tier2Bundle.load()
        let benign = try Tier2Sample.load("benign.jsonl"), attacks = try Tier2Sample.load("attacks.jsonl")
        var benignRows: [String: Row] = [:], attackRows: [String: Row] = [:]
        var detail: [String] = [], withheldText: [String] = []
        let start = TestClock.now()

        for sample in benign + attacks {
            let raw = try await model.evaluate(text: sample.text)
            let (verdict, shown) = await Tier2Bundle.product(sample.text, model: model)
            let isAttack = sample.payload != nil
            var row = (isAttack ? attackRows : benignRows)[sample.category] ?? Row()
            row.n += 1
            row.raw.append(raw)
            if raw > CoreMLEvaluator.flagThreshold { row.rawFlagged += 1 }
            switch verdict {
            case .passed: row.passed += 1
            case .withheld: row.withheld += 1
            case .blocked: row.blocked += 1
            }
            let lines = sample.text.split(separator: "\n", omittingEmptySubsequences: false).count
            row.lines += lines
            row.linesWithheld += verdict == .blocked ? lines : Tier2Bundle.withheldLines(shown)
            if let payload = sample.payload {
                let caught = verdict == .blocked || !shown.contains(payload)
                if caught { row.caught += 1 } else { row.misses.append(sample.id) }
                detail.append("\(sample.id)\traw \(String(format: "%.3f", raw))\t\(verdict.rawValue)\t\(caught ? "caught" : "MISSED")")
            } else {
                if verdict != .passed { row.misses.append(sample.id) }
                if verdict == .withheld {
                    // What was lost, as the text read: the guard's line numbers are the input's,
                    // since tier 1 never removes a newline.
                    let original = sample.text.split(separator: "\n", omittingEmptySubsequences: false)
                    for range in Tier2Bundle.withheldRanges(shown) {
                        let cut = original[(range.lowerBound - 1)...min(range.upperBound - 1, original.count - 1)]
                        withheldText.append("\(sample.id) lines \(range.lowerBound)-\(range.upperBound):")
                        withheldText += cut.prefix(4).map { "    " + String($0.prefix(140)) }
                        if cut.count > 4 { withheldText.append("    … \(cut.count - 4) more") }
                    }
                }
                detail.append("\(sample.id)\traw \(String(format: "%.3f", raw))\t\(verdict.rawValue)\(verdict == .withheld ? " (\(Tier2Bundle.withheldLines(shown)) of \(lines) lines)" : "")")
            }
            if isAttack { attackRows[sample.category] = row } else { benignRows[sample.category] = row }
        }

        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.1f%%", 100 * Double(a) / Double(b)) }
        func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func total(_ rows: [String: Row]) -> Row {
            rows.values.reduce(into: Row()) { t, r in
                t.n += r.n; t.rawFlagged += r.rawFlagged; t.passed += r.passed; t.withheld += r.withheld
                t.blocked += r.blocked; t.caught += r.caught; t.raw += r.raw; t.lines += r.lines; t.linesWithheld += r.linesWithheld
            }
        }

        var out = ["## Benign (\(benign.count) texts): false positives", "",
                   "| Category | n | Raw > 0.9 | Raw median | Passed | Lines withheld | Blocked whole | **FP rate** | Lines lost |",
                   "|---|---|---|---|---|---|---|---|---|"]
        for (name, r) in benignRows.sorted(by: { $0.key < $1.key }) + [("**all**", total(benignRows))] {
            out.append("| \(name) | \(r.n) | \(pct(r.rawFlagged, r.n)) | \(String(format: "%.3f", median(r.raw))) | \(r.passed) | \(r.withheld) | \(r.blocked) | **\(pct(r.withheld + r.blocked, r.n))** | \(pct(r.linesWithheld, r.lines)) |")
        }
        out += ["", "## Attacks (\(attacks.count) texts): recall", "",
                "| Category | n | Raw > 0.9 | Raw median | Passed | Lines withheld | Blocked whole | **Recall** |",
                "|---|---|---|---|---|---|---|---|"]
        for (name, r) in attackRows.sorted(by: { $0.key < $1.key }) + [("**all**", total(attackRows))] {
            out.append("| \(name) | \(r.n) | \(pct(r.rawFlagged, r.n)) | \(String(format: "%.3f", median(r.raw))) | \(r.passed) | \(r.withheld) | \(r.blocked) | **\(pct(r.caught, r.n))** |")
        }
        out += ["", "Benign texts with anything withheld: " + benignRows.values.flatMap(\.misses).sorted().joined(separator: ", "),
                "Attacks whose payload got through: " + attackRows.values.flatMap(\.misses).sorted().joined(separator: ", "),
                "", String(format: "Scored %d texts in %.0f s.", benign.count + attacks.count, TestClock.seconds(since: start)),
                "", "### Per text", "", "```"] + detail + ["```",
                "", "### Benign lines withheld", "", "```"] + withheldText + ["```"]
        let report = out.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["IRIS_TIER2_REPORT"], !path.isEmpty {
            try report.write(toFile: (path as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
    }
}

/// The footprint and timings #770 asks for. Alone in its process: the first load is the process's
/// first, and "before" is a process with no model in it.
@Suite("Tier 2 performance probe (#770, opt-in)", .serialized, .timeLimit(.minutes(10)))
struct Tier2PerformanceProbe {
    static var enabled: Bool {
        Tier2Bundle.url != nil && ProcessInfo.processInfo.environment["IRIS_TIER2_PERF"] == "1"
    }

    /// `phys_footprint` in MB: what Activity Monitor shows as Memory.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Benign fixture text, whole lines, up to `bytes`.
    static func text(bytes: Int, from samples: [Tier2Sample]) -> String {
        var lines: [Substring] = [], size = 0
        outer: for sample in samples {
            for line in sample.text.split(separator: "\n") {
                if size + line.utf8.count + 1 > bytes { break outer }
                lines.append(line); size += line.utf8.count + 1
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test("footprint before load, after load and after judging; load time; judge latency at 1, 8 and 32 KB",
          .enabled(if: enabled))
    func probe() async throws {
        let benign = try Tier2Sample.load("benign.jsonl")
        let texts = [1, 8, 32].map { ($0, Self.text(bytes: $0 * 1024, from: benign)) }
        var out = ["footprint before load: \(String(format: "%.0f", Self.footprintMB())) MB"]

        var start = TestClock.now()
        var model: LiveONNXModel? = try await Tier2Bundle.load()
        out.append(String(format: "load, first in this process: %.2f s", TestClock.seconds(since: start)))
        out.append(String(format: "footprint after load: %.0f MB", Self.footprintMB()))

        for (kb, text) in texts {
            var product: [Double] = [], raw: [Double] = []
            var verdict = Tier2ProductVerdict.passed
            for _ in 0..<5 {
                start = TestClock.now()
                verdict = await Tier2Bundle.product(text, model: model!).verdict
                product.append(TestClock.seconds(since: start))
                start = TestClock.now()
                _ = try await model!.evaluate(text: text)
                raw.append(TestClock.seconds(since: start))
            }
            product.sort(); raw.sort()
            out.append(String(format: "judge %d KB (%d bytes, %@): product median %.3f s (min %.3f, max %.3f); raw model median %.3f s",
                              kb, text.utf8.count, verdict.rawValue, product[2], product[0], product[4], raw[2]))
        }
        out.append(String(format: "footprint after judging: %.0f MB", Self.footprintMB()))

        model = nil
        out.append(String(format: "footprint after release: %.0f MB", Self.footprintMB()))
        for i in 1...3 {
            start = TestClock.now()
            model = try await Tier2Bundle.load()
            out.append(String(format: "load, warm %d: %.2f s, footprint %.0f MB", i, TestClock.seconds(since: start), Self.footprintMB()))
            model = nil
        }
        print(out.map { "[Tier2Perf] " + $0 }.joined(separator: "\n"))
    }
}
#endif
