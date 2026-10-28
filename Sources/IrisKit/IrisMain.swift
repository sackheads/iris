import Foundation

/// The process entry point, shared by the SwiftPM `iris` binary and the Xcode `Iris.app`.
/// Headless modes (--perf, --bench, --run-job, --guard-probe, --seed-dev-home) run before any
/// SwiftUI window is created and exit.
public enum IrisMain {
    @MainActor
    public static func run() async throws {
        // Before anything reads a setting, even in a headless mode: the first launch of this
        // process's domain (release, or the dev domain the bare binary and Iris Dev.app share)
        // inherits the legacy `iris` settings once. No-op under tests (`shouldImport`).
        AppDefaultsImport.runIfNeeded()
        // `run` is @MainActor, so the @MainActor entry points can execute directly.
        if let perf = PerfCLI.parse(CommandLine.arguments) {
            ProcessRole.set(.perf)
            switch perf {
            case .success(let cmd):
                exit(await PerfCLI.execute(cmd, environment: .process))
            case .failure(let err):
                FileHandle.standardError.write(Data("iris --perf: \(err.localizedDescription)\n\(PerfCLI.usage)\n".utf8))
                exit(64)
            }
        } else if let benchOptions = BenchCLI.parse(CommandLine.arguments) {
            ProcessRole.set(.bench)
            await BenchCLI.run(benchOptions)
            exit(0)
        } else if let invocation = RunJobCLI.parse(arguments: CommandLine.arguments) {
            ProcessRole.set(.runJob)
            // The real store and the real model client (#187 §8): a `--run-job` measurement is only
            // worth anything if it is the run the scheduler would have done. No volatile defaults and
            // no `HeadlessMode`: approvals fail closed exactly as unattended. `store:` is an
            // autoclosure that `run` calls only once it holds the store lock (#463), so a refused
            // run never opens, migrates or repairs it.
            // #463 decision 16: SIGINT, SIGTERM and SIGHUP stop the run cleanly; a second one exits
            // at once. Installed before the claim, so a signal there still exits 2 with no row.
            let lockPath = IrisPaths.default.storeLockFile
            let stop = CLIStop(vacate: { StoreLock.vacate(at: lockPath) })
            let signals = CLISignals.install { stop.receive($0) }
            let code = await RunJobCLI.run(invocation,
                                           store: try ConversationStore.onDisk(at: IrisPaths.default.conversationsDB),
                                           client: LLMClient(), lockPath: lockPath, stop: stop,
                                           startSweep: { Task { await SandboxSessionManager.shared.runJobSweep() } })
            withExtendedLifetime(signals) {}
            // `_exit`, the way `AppDelegate` leaves at terminate: a blocked tool call asks Vibecop for a
            // verdict, which on the embedded engine loads ggml, and `exit`'s static destructors then trip
            // llama.cpp's `GGML_ASSERT` — so a script would read 134 for a run whose row says "blocked on
            // approval" and whose documented code is 2. This command's contract *is* its exit code.
            // Nothing is lost by skipping the atexit handlers: the run's save was flushed inside `run`,
            // and `stop.exit` flushes the two streams, then empties the payload last (decision 5).
            // Through the stop's single-shot exit, so a second signal landing now cannot race this
            // to a different code: whichever gets there first exits.
            stop.exit(code: code)
            // Lost to a second signal's exit, which is under way on the signal queue and ends the
            // process: returning would run `exit`'s destructors, so wait for it here.
            while true { pause() }
        } else if let probe = GuardProbeCLI.parse(CommandLine.arguments) {
            // #778: times tier 2 and tier 3 on one benign text, read-only, dev builds only.
            ProcessRole.set(.probe)
            switch probe {
            case .success(let options):
                exit(await GuardProbeCLI.run(options))
            case .failure(let err):
                FileHandle.standardError.write(Data("iris --guard-probe: \(err.localizedDescription)\n\(GuardProbeCLI.usage)\n".utf8))
                exit(64)
            }
        } else if CommandLine.arguments.contains("--seed-dev-home") {
            ProcessRole.set(.seed)
            let code = DevHomeSeeder.runCLI()
            // Last (P6): until now the source lock's payload names this seeder, so an app launched
            // mid-seed waits. A no-op when the claim was refused.
            StoreLock.vacate(at: IrisPaths.release.storeLockFile)
            exit(code)
        } else {
            ProcessRole.set(.app)
            IrisApp.main()
        }
    }
}
