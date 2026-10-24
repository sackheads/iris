import Foundation
import os
import CoreML

public protocol CoreMLModelProtocol: Sendable {
    func evaluate(text: String) async throws -> Double
    /// How many tokens `text` is, without the tokenizer's own markers (#722): what decides how
    /// many lines fit one window.
    func tokenCount(_ text: String) -> Int
}

extension CoreMLModelProtocol {
    /// A character a token: never fewer tokens than a real tokenizer gives for dense text, so a
    /// model that can't count (a test's stand-in) is given windows that surely fit.
    public func tokenCount(_ text: String) -> Int { text.count }
}

public final class CoreMLEvaluator: @unchecked Sendable {
    public static let shared = CoreMLEvaluator()
    
    private var model: CoreMLModelProtocol?
    private let lock = NSLock()

    /// A model scoped to the current task tree, taking precedence over the installed one.
    ///
    /// `setModel` writes process-global state, and `swift test` runs suites in parallel, so a
    /// suite that installed a malicious-probability mock decided the verdict for every other
    /// suite sanitising at the same moment — assertions failed against content that was never
    /// the problem (#237). A task-local is visible only inside the `withValue` body and the
    /// tasks it spawns, so two suites can hold different models at once without racing.
    /// Production never sets it.
    ///
    /// Wrapped rather than a bare optional so a scope can say "explicitly no model" — which is a
    /// different thing from "no scope set", and is what the fail-open tests need.
    public struct ScopedModel: Sendable {
        let model: CoreMLModelProtocol?
        public init(_ model: CoreMLModelProtocol?) { self.model = model }
    }
    @TaskLocal public static var scopedModel: ScopedModel?

    /// The task-scoped model when a scope is active — including when that scope says none —
    /// otherwise the installed one.
    private var effectiveModel: CoreMLModelProtocol? {
        if let scoped = Self.scopedModel { return scoped.model }
        return lock.withLock { model }
    }

    /// Internal, not private, so a test can hold an evaluator of its own: the one test that needs
    /// an installed model writing that model into `shared` made every unscoped tier-2 call in the
    /// process see it appear and vanish mid-check, which fails closed (#375). Production uses only
    /// `shared`.
    init() {}
    
    /// `nil` clears the loaded model (#210 fix round 1) — the test seam for forcing
    /// `hasModelLoaded` back to `false` regardless of what an earlier test in the process
    /// installed. Source-compatible with every existing non-nil caller.
    public func setModel(_ newModel: CoreMLModelProtocol?) {
        lock.withLock {
            model = newModel
        }
    }
    
    public var hasModelLoaded: Bool {
        effectiveModel != nil
    }
    
    public func loadModelIfNeeded() async throws {
        // A scope answers for itself: one holding a model needs no load, and one holding `nil`
        // means "explicitly no model" and must not acquire one. Without this, a scoped-nil body
        // makes `hasModelLoaded` false, falls through to the disk load below, and — on a machine
        // where the bundle is present — ends at `setModel(liveModel)`, writing a live classifier
        // into the PROCESS-GLOBAL slot that every unscoped path then reads. That is the leak this
        // seam exists to close, so the check belongs ahead of the config read, not after it.
        if Self.scopedModel != nil { return }
        if hasModelLoaded { return }
        let coreMLPathStr = ConfigManager.shared.promptGuardCoreMLModel
        if coreMLPathStr.isEmpty { return }
        
        // #210: resolved via the shared helper so this can never disagree with
        // `InjectionGuard.tier2Provisioning` or `ModelLEDBar.tier2State` about what "downloaded"
        // means.
        let modelDirName = ModelDownloader.resolvedCoreMLDirectoryName(for: coreMLPathStr)

        let basePath = IrisPaths.default.modelsDir.path
        let fullPath = URL(fileURLWithPath: basePath).appendingPathComponent(modelDirName)
        
        if FileManager.default.fileExists(atPath: fullPath.path) {
            #if canImport(Tokenizers)
            do {
                // An ONNX bundle unzips to a directory containing `model.onnx` alongside the
                // tokenizer files; a CoreML bundle is the `.mlmodelc` directory itself.
                let onnxURL = fullPath.appendingPathComponent("model.onnx")
                if FileManager.default.fileExists(atPath: onnxURL.path) {
                    #if canImport(OnnxRuntimeBindings)
                    let liveModel = try await LiveONNXModel(modelURL: onnxURL, tokenizerConfigURL: fullPath)
                    setModel(liveModel)
                    #else
                    throw NSError(domain: "CoreMLEvaluator", code: -1, userInfo: [NSLocalizedDescriptionKey: "ONNX model found but ONNX Runtime is not available in this build."])
                    #endif
                } else {
                    let liveModel = try await LiveCoreMLModel(modelURL: fullPath, tokenizerConfigURL: fullPath)
                    setModel(liveModel)
                }
            } catch {
                print("[CoreMLEvaluator] Failed to load model: \(error)")
                throw error
            }
            #else
            print("[CoreMLEvaluator] Tokenizers framework not available. Cannot load model.")
            throw NSError(domain: "CoreMLEvaluator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tokenizers framework not available."])
            #endif
        } else {
            throw NSError(domain: "CoreMLEvaluator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model directory does not exist at \(fullPath.path)"])
        }
    }
    
    public func evaluate(text: String) async throws -> Double {
        let currentModel = effectiveModel
        guard let m = currentModel else {
            // If no model is loaded (e.g. BYOM not yet downloaded), we fail open (assume safe) 
            // so we don't break the user's workflow just because they haven't set up Tier 2 yet.
            print("[CoreMLEvaluator] No model loaded. Defaulting to 0.0 (safe).")
            return 0.0
        }
        
        // #722: the model judges the whole text, in overlapping token windows (`TokenWindows`);
        // here it is only held to a character bound, so tokenizing it stays cheap.
        return try await m.evaluate(text: Self.bounded(Self.collapsingRepeatedLines(text)))
    }

    /// Runs of identical lines, collapsed to one line marked with its count (#725). Repetitive
    /// output (build and test logs, `yes`) is ordinary, and the model scored 36 copies of one plain
    /// sentence at 0.999; with windows judged by their maximum (#722) that would block such output
    /// whole. A different line ends a run, so nothing can hide inside a collapse, and a repeated
    /// injection line is still judged, once.
    static func collapsingRepeatedLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return text }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var index = 0
        while index < lines.count {
            var end = index + 1
            while end < lines.count, lines[end] == lines[index] { end += 1 }
            let run = end - index
            out.append(run > 1 ? "\(lines[index]) \u{00D7}\(run)" : String(lines[index]))
            index = end
        }
        return out.count == lines.count ? text : out.joined(separator: "\n")
    }

    /// What tier 2 decided about one text, line by line (#722, #725 ruling (d)).
    struct Judgement: Equatable, Sendable {
        /// The highest probability any window scored.
        var highest: Double
        /// The text's lines (0-based) that a flagged window held, merged into ranges.
        var withheld: [ClosedRange<Int>]
        var lineCount: Int
        /// Withheld ranges the inference budget left at a whole window, unnarrowed.
        var unnarrowed: [ClosedRange<Int>] = []
        /// Withheld ranges past the bounds on the whole-text pass: never judged at all.
        var unjudged: [ClosedRange<Int>] = []

        /// What a range withheld unjudged says in its marker.
        static let notJudgedNote = "; too long to judge whole, so not judged"

        /// The ranges withheld unjudged, 1-based ("a-b", or "a"), as their markers name them. Carried
        /// out of the guard as data (#728): reparsing the marker from the guarded text let a file
        /// that quoted one raise a notice for lines that were sent.
        var unjudgedRanges: [String] {
            unjudged.map { $0.count == 1 ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)-\($0.upperBound + 1)" }
        }

        var allWithheld: Bool { lineCount > 0 && withheld.reduce(0) { $0 + $1.count } >= lineCount }

        /// `text` with each withheld range replaced by one marker naming its lines, 1-based and
        /// counted in the text the guard was given, which is the output as shown (agreed with
        /// #709, whose cap line names file lines for what it hid, since only those can be re-read).
        func redacting(_ text: String) -> String {
            guard !withheld.isEmpty else { return text }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var out: [String] = []
            var index = 0
            for range in withheld {
                out += lines[index..<range.lowerBound].map(String.init)
                let coarse = unjudged.contains { $0.overlaps(range) } ? Judgement.notJudgedNote
                    : unnarrowed.contains { $0.overlaps(range) } ? "; not narrowed further, to bound the guard's work" : ""
                out.append(range.count == 1 ? "[line \(range.lowerBound + 1) of this output withheld by the injection guard\(coarse)]"
                                            : "[lines \(range.lowerBound + 1)-\(range.upperBound + 1) of this output withheld by the injection guard\(coarse)]")
                index = range.upperBound + 1
            }
            out += lines[index...].map(String.init)
            return out.joined(separator: "\n")
        }
    }

    /// The probability over which a window is withheld; `InjectionGuard`'s tier-2 threshold.
    static let flagThreshold = 0.9
    /// The probability over which a window is narrowed (#726): below the threshold, because benign
    /// lines dilute an injection's window. Narrowing withholds only what flags on its own.
    static let narrowTrigger = 0.5

    /// "system prompt" counts only in an instruction's shape (a verb, then your/the): a bare mention
    /// was 96 of 127 matches in Iris's own docs, nearly all descriptive (planner, #730).
    /// Phrases that mark a line as a likely injection, judged alone whatever its window scored
    /// (#726), so benign padding can't dilute it. Matched on the tier-1 text, which has already
    /// stripped role delimiters like `system:`; `judge(text:delimiterLines:)` scores those lines alone (#727).
    static let injectionMarkers = try! NSRegularExpression(pattern:
        #"ignore\s+(all\s+)?(the\s+)?(previous|prior|above)|disregard\s+(all\s+)?(previous|prior|your|the)|you\s+are\s+now|new\s+instructions|(reveal|print|show|repeat|output|ignore|override|disregard|leak|dump)\s+(\w+\s+)?(your|the)\s+(\w+\s+)?system\s+prompt|<\|im_(start|end)\|>|\[/?INST\]|\[TOOL_CALL\]|developer\s+mode"#,
        options: [.caseInsensitive])
    /// The most marked lines judged alone in one text (#730 review).
    static let maxMarkedLines = 64

    static func hasInjectionMarker(_ text: String) -> Bool {
        injectionMarkers.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    /// Tokens a window may hold. 128, not the models' full 512 (planner, #723): on typical test
    /// output, a 500-token window scored ~0.95 though no part of it flagged alone, and the whole
    /// window was withheld (398 of 471 lines); at 128 none was, and it ran faster.
    static let windowTokens = 128
    /// Tokens of trailing lines a window repeats from the one before, so an instruction across a
    /// line break is judged whole once: a quarter of the window.
    static let overlapTokens = 32

    /// Judges `text` in windows of whole lines and reports which lines a flagged window held
    /// (#725 ruling (d)): only those are withheld, not the whole text. Runs of identical lines are
    /// judged once, as one counted line, and withheld whole when flagged. A line longer than a
    /// window is judged alone, in the model's own token windows.
    /// `delimiterLines` (#727): lines a role delimiter was stripped from, keyed by 0-based line,
    /// with the line as it read before the strip. Each is scored alone, as it read, whatever its
    /// window scored, like a phrase-marked line.
    func judge(text: String, delimiterLines: [Int: String] = [:]) async throws -> Judgement {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let m = effectiveModel else {
            print("[CoreMLEvaluator] No model loaded. Defaulting to 0.0 (safe).")
            return Judgement(highest: 0, withheld: [], lineCount: lines.count)
        }
        var highest = 0.0
        var flagged: [ClosedRange<Int>] = []
        var unnarrowed: [ClosedRange<Int>] = []
        var unjudged: [ClosedRange<Int>] = []
        // Past `maxCharacters` of collapsed text (#723 review), the head and the tail are judged and
        // the lines between are withheld unjudged, which fails closed: only a caller past #709's
        // cap gets here. Measured after collapsing, so 1 MB of one repeated line is judged whole.
        var runs = Self.lineRuns(lines)
        if runs.reduce(0, { $0 + $1.text.count + 1 }) > Self.maxCharacters, runs.count > 2 {
            var head = 0, headChars = 0
            while head < runs.count - 1, headChars + runs[head].text.count + 1 <= Self.maxCharacters / 2 { headChars += runs[head].text.count + 1; head += 1 }
            var tail = runs.count, tailChars = 0
            while tail - 1 > head, tailChars + runs[tail - 1].text.count + 1 <= Self.maxCharacters / 2 { tail -= 1; tailChars += runs[tail].text.count + 1 }
            if tail > head {
                let middle = runs[head].lines.lowerBound...runs[tail - 1].lines.upperBound
                flagged.append(middle)
                unjudged.append(middle)
                runs.removeSubrange(head..<tail)
            }
        }
        let costs = runs.map { m.tokenCount($0.text) + 1 }
        // The whole-text windows always run, uncounted, so every line is judged; narrowing spends
        // the budget, and a flagged window past it is withheld whole (planner, #723). At 128-token
        // windows the whole-text pass is itself ~100 calls on 32 KB (#723 review), so it can't share.
        var calls = 0
        func score(_ text: String) async throws -> Double {
            calls += 1
            return try await m.evaluate(text: text)
        }
        // #726 ruling (B): a window, or a small window, that flags while nothing smaller in it does is
        // withheld only if it still flags with a line of context either side. Two real warnings
        // scored 0.98 together at an unlucky window edge though neither flagged alone, and widening
        // dissolves such pairings. One call each, under the budget; past it, fails closed.
        func confirmed(_ range: ClosedRange<Int>) async throws -> Bool {
            // A single line that flagged is a line flagging alone: nothing to confirm.
            guard range.count > 1, calls < Self.inferenceBudget else { return true }
            let wider = max(0, range.lowerBound - 1)...min(runs.count - 1, range.upperBound + 1)
            guard wider != range else { return true }
            // Against the narrowing trigger, not the threshold (#730 review): the extra lines dilute
            // a real split injection too. The benign pair fell to 0.011 widened, far under either.
            return try await score(runs[wider].map(\.text).joined(separator: "\n")) > Self.narrowTrigger
        }
        var windows = runs.isEmpty ? [] : Self.windows(costs, in: 0...(runs.count - 1), size: Self.windowTokens, overlap: Self.overlapTokens)
        // The whole-text pass is bounded too (planner, #723): a caller in front of no output cap (a
        // 5 MB tool result on main, an event, memory) would otherwise cost thousands of calls. Past
        // `maxWindows`, the first and last halves are judged and the lines between are withheld,
        // unjudged: shown unjudged, they'd be exactly the gap this exists to close.
        if windows.count > Self.maxWindows {
            let keep = Self.maxWindows / 2
            let firstSkipped = windows[keep - 1].upperBound + 1, lastSkipped = windows[windows.count - keep].lowerBound - 1
            if firstSkipped <= lastSkipped {
                let middle = runs[firstSkipped].lines.lowerBound...runs[lastSkipped].lines.upperBound
                flagged.append(middle)
                unjudged.append(middle)
                print("[CoreMLEvaluator] Tier 2: \(windows.count) windows is over \(Self.maxWindows); lines \(middle.lowerBound + 1)-\(middle.upperBound + 1) withheld unjudged (#723).")
            }
            windows = Array(windows.prefix(keep)) + Array(windows.suffix(keep))
        }
        for window in windows {
            let windowScore = try await m.evaluate(text: runs[window].map(\.text).joined(separator: "\n"))
            highest = max(highest, windowScore)
            // #726: a window between the trigger and the threshold is narrowed too, since benign
            // lines around an injection dilute its window's score; only what then flags on its own
            // is withheld. A window over the threshold whose parts don't flag is withheld whole.
            guard windowScore > Self.narrowTrigger else { continue }
            let overThreshold = windowScore > Self.flagThreshold
            let span = runs[window.lowerBound].lines.lowerBound...runs[window.upperBound].lines.upperBound
            guard calls < Self.inferenceBudget else {
                if overThreshold {
                    flagged.append(span)
                    unnarrowed.append(span)
                }
                continue
            }
            // Narrowed to the small windows that flag on their own, so a warning costs its own
            // lines and not the 60 around it. When none does, the signal needed the whole window,
            // and the whole window is withheld.
            var narrowed: [ClosedRange<Int>] = []
            if window.count > 1 {
                for small in Self.windows(costs, in: window, size: Self.narrowTokens, overlap: Self.narrowOverlapTokens) {
                    guard calls < Self.inferenceBudget else { narrowed += [small]; continue }
                    guard try await score(runs[small].map(\.text).joined(separator: "\n")) > Self.flagThreshold else { continue }
                    // And to the single lines that flag on their own, if any; else the small window.
                    // A small window of one line that flags is that line flagging alone.
                    var single: [ClosedRange<Int>] = small.count == 1 ? [small] : []
                    if small.count > 1, calls + small.count <= Self.inferenceBudget {
                        // With its neighbour either side (#723 review): an injection's other lines
                        // may not flag alone, and they are the payload around the one that does.
                        for run in small where try await score(runs[run].text) > Self.flagThreshold {
                            single.append(run...run)
                        }
                    }
                    // A small window that flags with no line in it flagging alone is withheld only
                    // when its window was itself over the threshold: under the narrowing trigger
                    // alone, two benign warnings together scored 0.98 on the real model (#726).
                    if !single.isEmpty {
                        narrowed += single
                    } else if overThreshold, try await confirmed(small) {
                        narrowed.append(small)
                    }
                }
            }
            if narrowed.isEmpty {
                guard overThreshold, try await confirmed(window) else { continue }
            }
            for runRange in narrowed.isEmpty ? [window] : narrowed {
                let span = runs[runRange.lowerBound].lines.lowerBound...runs[runRange.upperBound].lines.upperBound
                // With one original line either side (#723 review): an injection's other lines may
                // not flag alone, and they are the payload around the one that does.
                flagged.append(max(0, span.lowerBound - 1)...min(lines.count - 1, span.upperBound + 1))
            }
        }
        // #726: a line carrying an injection marker is judged alone, whatever its window scored. It
        // runs outside the budget: such lines are few in ordinary output, and this is the check that
        // must not be skipped.
        let covered = Self.merged(flagged)
        let marked = runs.indices.filter { run in Self.hasInjectionMarker(runs[run].text)
            && !covered.contains(where: { $0.contains(runs[run].lines.lowerBound) }) }
        // Capped (#730 review): a text about prompts can mark thousands of lines. Past the cap the
        // rest are withheld unjudged, which fails closed and, for the person's own files, says so.
        for run in marked.dropFirst(Self.maxMarkedLines) {
            flagged.append(runs[run].lines)
            unjudged.append(runs[run].lines)
        }
        for run in marked.prefix(Self.maxMarkedLines) {
            let alone = try await m.evaluate(text: runs[run].text)
            highest = max(highest, alone)
            if alone > Self.flagThreshold {
                let span = runs[run].lines
                flagged.append(max(0, span.lowerBound - 1)...min(lines.count - 1, span.upperBound + 1))
            }
        }
        // #727: a line a role delimiter was stripped from is scored alone as it read, delimiter
        // and all, since the strip removed the strongest signal there is. Past the cap the rest
        // are left to their windows, as before #727: `user:` is an everyday YAML key, so failing
        // closed here would withhold ordinary config files.
        let phraseMarked = Set(marked)
        let coveredNow = Self.merged(flagged)
        let stripped = runs.indices.compactMap { run -> (Int, String)? in
            guard !phraseMarked.contains(run),
                  !coveredNow.contains(where: { $0.contains(runs[run].lines.lowerBound) }),
                  let line = runs[run].lines.lazy.compactMap({ delimiterLines[$0] }).first else { return nil }
            return (run, line)
        }
        // Strongest first, then in file order (planner, #735): padding with weak `user:` lines can't
        // push a `system:` or chat-template line past the cap.
        let byStrength = stripped.enumerated()
            .sorted { (PromptInjectionGuard.delimiterStrength($0.element.1), $0.offset)
                    < (PromptInjectionGuard.delimiterStrength($1.element.1), $1.offset) }
            .map(\.element)
        for (run, line) in byStrength.prefix(Self.maxMarkedLines) {
            let alone = try await m.evaluate(text: line)
            highest = max(highest, alone)
            if alone > Self.flagThreshold {
                let span = runs[run].lines
                flagged.append(max(0, span.lowerBound - 1)...min(lines.count - 1, span.upperBound + 1))
            }
        }
        if calls >= Self.inferenceBudget {
            print("[CoreMLEvaluator] Tier 2 reached its budget of \(Self.inferenceBudget) model calls on one text; flagged windows past it are withheld whole (#723).")
        }
        return Judgement(highest: highest, withheld: Self.merged(flagged), lineCount: lines.count,
                         unnarrowed: Self.merged(unnarrowed), unjudged: Self.merged(unjudged))
    }

    /// The most whole-text windows one text is judged in (planner, #723): 256, about 24k tokens of
    /// distinct lines, or roughly 5 s on the local model.
    static let maxWindows = 256

    /// The most model calls narrowing may spend on one text (planner, #723). The whole-text windows
    /// always run and aren't counted: a 32 KB tool result is about 100 of them at 128 tokens.
    static let inferenceBudget = 128

    /// The small windows a flagged window is narrowed to.
    static let narrowTokens = 64
    static let narrowOverlapTokens = 16

    /// Windows over `range` of runs, each at most `size` tokens (a run alone may be more) and
    /// repeating up to `overlap` tokens of the one before, always moving on.
    static func windows(_ costs: [Int], in range: ClosedRange<Int>, size: Int, overlap: Int) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start = range.lowerBound
        while start <= range.upperBound {
            var end = start
            var tokens = costs[start]
            while end + 1 <= range.upperBound, tokens + costs[end + 1] <= size {
                end += 1
                tokens += costs[end]
            }
            out.append(start...end)
            guard end < range.upperBound else { break }
            var next = end + 1
            var carried = 0
            while next - 1 > start, carried + costs[next - 1] <= overlap {
                next -= 1
                carried += costs[next]
            }
            start = next
        }
        return out
    }

    /// Consecutive identical lines as one counted line, with the original lines it stands for.
    static func lineRuns(_ lines: [Substring]) -> [(text: String, lines: ClosedRange<Int>)] {
        var runs: [(text: String, lines: ClosedRange<Int>)] = []
        var index = 0
        while index < lines.count {
            var end = index + 1
            while end < lines.count, lines[end] == lines[index] { end += 1 }
            let count = end - index
            runs.append((count > 1 ? "\(lines[index]) \u{00D7}\(count)" : String(lines[index]), index...(end - 1)))
            index = end
        }
        return runs
    }

    static func merged(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// The most characters handed to a model. Guarded text is bounded upstream far below this
    /// (#709's 32 KB at the tool-result choke point, #724 for artifacts); past it, the head and the
    /// tail are kept and that is logged once.
    static let maxCharacters = 200_000
    private static let loggedBound = OSAllocatedUnfairLock(initialState: false)

    static func bounded(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        if loggedBound.withLock({ let first = !$0; $0 = true; return first }) {
            print("[CoreMLEvaluator] A text of \(text.count) characters is over \(maxCharacters); tier 2 judges its first and last \(maxCharacters / 2) (#722).")
        }
        return String(text.prefix(maxCharacters / 2)) + "\n" + String(text.suffix(maxCharacters / 2))
    }
}

/// The token windows a tier-2 model judges one text in (#722). The models read 512 tokens; a
/// window counted in characters still loses most of itself in CJK, base64 or minified code, where
/// a character is about a token, so the text is encoded once and cut in tokens. Each window keeps
/// the encoding's first and last tokens (the tokenizer's [CLS] and [SEP]) around its slice.
enum TokenWindows {
    static let overlap = 128
    static let maxWindows = 64
    private static let loggedSpread = OSAllocatedUnfairLock(initialState: false)

    static func windows(_ tokens: [Int], sequenceLength: Int, overlap: Int = overlap,
                        maxWindows: Int = maxWindows) -> [[Int]] {
        guard tokens.count > sequenceLength, tokens.count >= 2, sequenceLength > 2 else { return [tokens] }
        let first = tokens[0], last = tokens[tokens.count - 1]
        let body = Array(tokens[1..<(tokens.count - 1)])
        let size = sequenceLength - 2
        let stride = max(1, size - overlap)
        let lastStart = body.count - size
        var starts = Array(Swift.stride(from: 0, to: lastStart, by: stride)) + [lastStart]
        if starts.count > maxWindows {
            // Evenly across the whole text, the first and last windows always included.
            starts = (0..<maxWindows).map { lastStart * $0 / (maxWindows - 1) }
            if loggedSpread.withLock({ let was = !$0; $0 = true; return was }) {
                print("[TokenWindows] \(body.count) tokens need more than \(maxWindows) overlapping windows; sampled in \(maxWindows) evenly spread ones (#722).")
            }
        }
        return starts.map { [first] + body[$0..<($0 + size)] + [last] }
    }
}

#if canImport(Tokenizers)
import Tokenizers

public final class LiveCoreMLModel: CoreMLModelProtocol, @unchecked Sendable {
    private let mlModel: MLModel
    private let tokenizer: any Tokenizer
    private let sequenceLength: Int
    private let injectionIndex: Int
    
    public init(modelURL: URL, tokenizerConfigURL: URL, sequenceLength: Int = 512) async throws {
        self.mlModel = try MLModel(contentsOf: modelURL)
        self.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerConfigURL)
        self.sequenceLength = sequenceLength
        
        var foundIndex = 1
        let configURL = tokenizerConfigURL.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id2label = json["id2label"] as? [String: String] {
            for (key, value) in id2label {
                let lower = value.lowercased()
                if lower.contains("inject") || lower.contains("malicious") {
                    if let idx = Int(key) { foundIndex = idx }
                }
            }
        }
        self.injectionIndex = foundIndex
    }
    
    public func evaluate(text: String) async throws -> Double {
        // Empty/whitespace-only input is trivially safe. This also sidesteps a benign
        // tokenizer divergence: swift-transformers' UnigramTokenizer (used for DeBERTa-v3
        // via the XLMRobertaTokenizer relabel) emits a stray metaspace token for empty
        // input where Python emits none. See DebertaV3TokenizerParityTests.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0.0
        }

        // #722: encoded whole (the evaluator bounds its length) and judged in overlapping
        // windows of the model's sequence length; the highest probability is the verdict, and
        // a window past the guard's threshold ends it early.
        var highest = 0.0
        for window in TokenWindows.windows(tokenizer.encode(text: text), sequenceLength: sequenceLength) {
            highest = max(highest, try await evaluate(window: window))
            if highest > 0.9 { break }
        }
        return highest
    }

    public func tokenCount(_ text: String) -> Int { max(0, tokenizer.encode(text: text).count - 2) }

    private func evaluate(window tokens: [Int]) async throws -> Double {
        var inputIds = tokens.map { Int32($0) }
        var attentionMask = [Int32](repeating: 1, count: inputIds.count)
        
        // Pad or truncate
        if inputIds.count > sequenceLength {
            inputIds = Array(inputIds.prefix(sequenceLength))
            attentionMask = Array(attentionMask.prefix(sequenceLength))
        } else if inputIds.count < sequenceLength {
            let padCount = sequenceLength - inputIds.count
            inputIds.append(contentsOf: [Int32](repeating: 0, count: padCount))
            attentionMask.append(contentsOf: [Int32](repeating: 0, count: padCount))
        }
        
        guard let inputIdsArray = try? MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32),
              let attentionMaskArray = try? MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32) else {
            throw NSError(domain: "LiveCoreMLModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create MLMultiArray"])
        }
        
        for i in 0..<sequenceLength {
            inputIdsArray[i] = NSNumber(value: inputIds[i])
            attentionMaskArray[i] = NSNumber(value: attentionMask[i])
        }
        
        let featureProvider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIdsArray,
            "attention_mask": attentionMaskArray
        ])
        
        let prediction = try await mlModel.prediction(from: featureProvider)
        
        // DeBERTa typically outputs "logits". We need to extract the injection probability.
        // Applies a generalized N-class softmax for robustness.
        if let logitsFeature = prediction.featureValue(for: "logits"),
           let logitsArray = logitsFeature.multiArrayValue, logitsArray.count > injectionIndex {
            
            var maxLogit = -Double.greatestFiniteMagnitude
            
            for i in 0..<logitsArray.count {
                let val = logitsArray[i].doubleValue
                if val > maxLogit { maxLogit = val }
            }
            
            var sumExps = 0.0
            var targetExp = 0.0
            
            for i in 0..<logitsArray.count {
                let e = exp(logitsArray[i].doubleValue - maxLogit)
                sumExps += e
                if i == injectionIndex { targetExp = e }
            }
            
            return sumExps > 0 ? (targetExp / sumExps) : 0.0
        }
        
        return 0.0
    }
}
#endif
