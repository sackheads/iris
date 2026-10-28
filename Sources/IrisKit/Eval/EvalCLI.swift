import Foundation

/// `iris --eval run | compare | table` (docs/specs/2026-10-28-model-eval-framework.md, #788).
/// Dev builds only and read-only, like `--guard-probe`: no store, conversation, job or home lock.
/// The model is always explicit config; the home's settings are never read for it.
enum EvalCLI {
    enum Command: Equatable {
        case run(task: String, model: EvalModelSpec, split: String, sample: Int?, datasetDir: String?, outDir: String?)
        case compare(a: String, b: String, vary: Set<String>)
        case table(resultsDir: String?, out: String?)
    }

    static let usage = """
    usage: iris --eval run <task> --model <runtime:name> [--sample N | --full] [--split test|dev|all] [--dataset DIR] [--out DIR]
           iris --eval compare <a.json> <b.json> [--vary model|runtime|dataset|split|sample]
           iris --eval table [--results DIR] [--out FILE]
    tasks: injection.classifier (onnx:, coreml:)
    """

    static let defaultSample = 60

    static func parse(_ args: [String]) -> Result<Command, EvalError>? {
        guard let start = args.firstIndex(of: "--eval") else { return nil }
        var rest = Array(args[(start + 1)...])
        guard !rest.isEmpty else { return .failure(.usage("--eval needs run, compare or table")) }
        let verb = rest.removeFirst()
        var positional: [String] = []
        var flags: [String: String] = [:]
        var full = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--full" { full = true; i += 1; continue }
            if a.hasPrefix("--") {
                guard i + 1 < rest.count else { return .failure(.usage("\(a) needs a value")) }
                flags[a] = rest[i + 1]; i += 2; continue
            }
            positional.append(a); i += 1
        }
        switch verb {
        case "run":
            guard positional.count == 1 else { return .failure(.usage("run takes one task")) }
            guard let m = flags["--model"], let model = EvalModelSpec.parse(m) else {
                return .failure(.usage("--model runtime:name is required (runtimes: \(EvalModelSpec.Runtime.allCases.map(\.rawValue).joined(separator: ", ")))"))
            }
            let split = flags["--split"] ?? "test"
            guard ["test", "dev", "all"].contains(split) else { return .failure(.usage("--split is test, dev or all")) }
            var sample: Int? = defaultSample
            if full { sample = nil }
            if let s = flags["--sample"] {
                guard !full, let n = Int(s), n > 0 else { return .failure(.usage("--sample takes a positive count, and not with --full")) }
                sample = n
            }
            return .success(.run(task: positional[0], model: model, split: split, sample: sample,
                                 datasetDir: flags["--dataset"], outDir: flags["--out"]))
        case "compare":
            guard positional.count == 2 else { return .failure(.usage("compare takes two result files")) }
            let vary = Set((flags["--vary"] ?? "").split(separator: ",").map(String.init))
            let known: Set<String> = ["model", "runtime", "dataset", "split", "sample"]
            guard vary.isSubset(of: known) else { return .failure(.usage("--vary takes \(known.sorted().joined(separator: ","))")) }
            return .success(.compare(a: positional[0], b: positional[1], vary: vary))
        case "table":
            return .success(.table(resultsDir: flags["--results"], out: flags["--out"]))
        default:
            return .failure(.usage("unknown --eval command \(verb)"))
        }
    }

    static func execute(_ command: Command, build: BuildIdentity = .current, repoRoot: URL = PerfPaths.repoRoot()) async -> Int32 {
        guard build == .dev else {
            FileHandle.standardError.write(Data("iris --eval: dev builds only\n".utf8))
            return 1
        }
        do {
            switch command {
            case .run(let task, let model, let split, let sample, let datasetDir, let outDir):
                let url = try await EvalRunner.run(task: task, model: model, split: split, sample: sample,
                                                    datasetDir: datasetDir.map { resolve($0, repoRoot) },
                                                    outDir: outDir.map { resolve($0, repoRoot) }, repoRoot: repoRoot)
                print("eval: wrote \(url.path)")
            case .compare(let a, let b, let vary):
                let ra = try EvalResult.decode(Data(contentsOf: resolve(a, repoRoot)))
                let rb = try EvalResult.decode(Data(contentsOf: resolve(b, repoRoot)))
                print(try EvalCompare.render(ra, rb, vary: vary))
            case .table(let resultsDir, let out):
                let dir = resultsDir.map { resolve($0, repoRoot) } ?? EvalRunner.resultsRoot(repoRoot)
                let target = out.map { resolve($0, repoRoot) } ?? repoRoot.appendingPathComponent("docs/evals.md")
                let text = try EvalTable.render(EvalTable.load(dir))
                try text.write(to: target, atomically: true, encoding: .utf8)
                print("eval: wrote \(target.path)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("iris --eval: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func resolve(_ path: String, _ root: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
    }
}

enum EvalRunner {
    static func resultsRoot(_ repoRoot: URL) -> URL { repoRoot.appendingPathComponent("eval/results") }
    static func defaultDataset(_ repoRoot: URL) -> URL { repoRoot.appendingPathComponent("eval/datasets/injection/v1") }

    static func run(task: String, model spec: EvalModelSpec, split: String, sample: Int?,
                    datasetDir: URL?, outDir: URL?, repoRoot: URL, now: Date = Date(),
                    loadModel: (EvalModelSpec) async throws -> CoreMLModelProtocol = { try await EvalClassifierTask.loadModel($0) }) async throws -> URL {
        guard task == EvalClassifierTask.name else {
            throw EvalError.unsupported(task == "injection.verdict" ? "injection.verdict comes in slice 1b (#788)" : "unknown task \(task)")
        }
        let dataset = try EvalDataset.load(from: datasetDir ?? defaultDataset(repoRoot))
        let texts = dataset.select(split: split, sample: sample)
        guard let modelURL = spec.url else { throw EvalError.unsupported("\(spec.runtime.rawValue) has no local files") }
        let files = try EvalFingerprint.files(at: modelURL)
        let fingerprint = EvalFingerprint.digest(files)
        let taskDir = (outDir ?? resultsRoot(repoRoot)).appendingPathComponent(task)

        let previous = try? EvalTable.load(taskDir.deletingLastPathComponent())
            .filter { $0.result.key.task == task && $0.result.key.model == spec.displayName }
            .max { $0.result.date < $1.result.date }
        var changed: Bool?
        if let previous, previous.result.key.modelFingerprint != fingerprint {
            print("MODEL CHANGED: \(previous.result.key.modelFingerprint) → \(fingerprint) (last result \(previous.file))")
            changed = true
        }

        print("eval: \(task) \(spec.description), dataset \(dataset.manifest.family) v\(dataset.manifest.version) \(split)"
              + (sample.map { ", sample \($0)" } ?? ", full") + ": \(texts.count) texts")
        let before = EvalEnvironment.footprintMB()
        let loadStart = MonotonicClock.nowMs()
        let model = try await ModelLoadTracker.shared.track(.guardTier2, name: spec.displayName) {
            try await loadModel(spec)
        }
        let loadSeconds = (MonotonicClock.nowMs() - loadStart) / 1000
        let afterLoad = EvalEnvironment.footprintMB()
        var scored: [EvalMetrics.Scored] = []
        for (n, sample) in texts.enumerated() {
            scored.append(await EvalClassifierTask.score(sample, model: model))
            if (n + 1) % 25 == 0 { print("eval: \(n + 1)/\(texts.count)") }
        }
        var metrics = EvalMetrics.metrics(scored, fullTestSplit: split == "test" && sample == nil)
        metrics.loadSeconds = loadSeconds
        if let before, let afterLoad { metrics.footprintAfterLoadMb = afterLoad - before }
        if let before, let after = EvalEnvironment.footprintMB() { metrics.footprintAfterJudgingMb = after - before }
        metrics.costPerThousandUsd = 0   // local: measured as free; energy isn't measured

        let day = Self.day(now)
        let result = EvalResult(
            key: .init(task: task, configuration: EvalClassifierTask.configuration,
                       datasetFamily: dataset.manifest.family, datasetVersion: dataset.manifest.version,
                       datasetSha256: dataset.sha256s, split: split, sample: sample,
                       runtime: spec.runtime.rawValue, runtimeVersion: EvalClassifierTask.runtimeVersion(spec.runtime),
                       model: spec.displayName, modelFingerprint: fingerprint,
                       scoringVersion: EvalClassifierTask.scoringVersion),
            date: day,
            model: .init(spec: spec.description, files: files, bytesOnDisk: files.reduce(0) { $0 + $1.bytes }),
            environment: await EvalEnvironment.capture(repoRoot: repoRoot),
            settings: EvalClassifierTask.settings,
            contaminated: dataset.manifest.family == "injection" && dataset.manifest.version == 1 ? "pre-split" : nil,
            modelChanged: changed, previousFingerprint: changed == true ? previous?.result.key.modelFingerprint : nil,
            metrics: metrics,
            verdicts: scored.map { .init(id: $0.sample.id, outcome: $0.outcome.rawValue, caught: $0.caught,
                                         rawScore: $0.rawScore, seconds: $0.seconds) })
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let url = Self.freshFile(in: taskDir, base: "\(day)-\(spec.slug)-v\(dataset.manifest.version)-\(split)" + (sample.map { "-s\($0)" } ?? "-full"))
        try result.encoded().write(to: url, options: .withoutOverwriting)
        print(EvalCompare.summary(result))
        return url
    }

    /// Append-only: a second run the same day gets `-2`, `-3`, and never replaces a file.
    static func freshFile(in dir: URL, base: String) -> URL {
        var candidate = dir.appendingPathComponent("\(base).json")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).json"); n += 1
        }
        return candidate
    }

    static func day(_ date: Date) -> String {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(date)
    }
}
