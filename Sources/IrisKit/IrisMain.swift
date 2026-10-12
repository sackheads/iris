import Foundation

/// The process entry point, shared by the SwiftPM `iris` binary and the Xcode `Iris.app`.
/// Headless modes run before any SwiftUI window is created and exit.
public enum IrisMain {
    @MainActor
    public static func run() async throws {
        // Before anything reads a setting, even in a headless mode: the first launch of this
        // process's domain (release, or the dev domain the bare binary and Iris Dev.app share)
        // inherits the legacy `iris` settings once. No-op under tests (`shouldImport`).
        AppDefaultsImport.runIfNeeded()
        // `run` is @MainActor, so the @MainActor entry points can execute directly.
        if let perf = PerfCLI.parse(CommandLine.arguments) {
            switch perf {
            case .success(let cmd):
                exit(await PerfCLI.execute(cmd, environment: .process))
            case .failure(let err):
                FileHandle.standardError.write(Data("iris --perf: \(err.localizedDescription)\n\(PerfCLI.usage)\n".utf8))
                exit(64)
            }
        } else if let benchOptions = BenchCLI.parse(CommandLine.arguments) {
            await BenchCLI.run(benchOptions)
            exit(0)
        } else if let invocation = RunJobCLI.parse(arguments: CommandLine.arguments) {
            // The real store and the real model client (#187 §8): a `--run-job` measurement is only
            // worth anything if it is the run the scheduler would have done. No volatile defaults and
            // no `HeadlessMode`: approvals fail closed exactly as unattended. `store:` is an
            // autoclosure that `run` calls only once it holds the store lock (#463), so a refused
            // run never opens, migrates or repairs it.
            let code = await RunJobCLI.run(invocation,
                                           store: try ConversationStore.onDisk(at: IrisPaths.default.conversationsDB),
                                           client: LLMClient())
            // `_exit`, the way `AppDelegate` leaves at terminate: a blocked tool call asks Vibecop for a
            // verdict, which on the embedded engine loads ggml, and `exit`'s static destructors then trip
            // llama.cpp's `GGML_ASSERT` — so a script would read 134 for a run whose row says "blocked on
            // approval" and whose documented code is 2. This command's contract *is* its exit code.
            // Nothing is lost by skipping the atexit handlers: the run's save was flushed inside `run`,
            // and the two streams are flushed here.
            fflush(stdout)
            fflush(stderr)
            // Last: an empty payload under a held lock reads as an unnamed holder (decision 5).
            StoreLock.vacate(at: IrisPaths.default.storeLockFile)
            _exit(code)
        } else if CommandLine.arguments.contains("--seed-dev-home") {
            exit(DevHomeSeeder.runCLI())
        } else {
            IrisApp.main()
        }
    }
}
