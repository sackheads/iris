import Testing
import Foundation
@testable import iris

/// #187 §9 — the five job limits are steppers in Settings → Advanced, so every number the
/// unattended system is bounded by is tweakable without editing a database (§0.1's first
/// condition). The stepper's model is a value type rather than a closure in the view, so the
/// clamp, the label and the round trip through `ConfigManager` are testable without SwiftUI.
///
/// Every test reads and writes a `ConfigManager` of its own (invariant 7): these are exactly the
/// keys the user's own settings hold, and a test that moved them would move them for good.
@Suite("job limit steppers (#187)")
struct JobLimitSettingsTests {

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-job-limits-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    @Test("the five steppers are the five keys the runner resolves its limits from")
    func coversEveryKey() {
        #expect(Set(JobLimitSetting.allCases.map(\.configKey)) == [
            "JOB_PER_RUN_TOKEN_BUDGET", "JOB_DAILY_TOKEN_BUDGET", "JOB_GLOBAL_DAILY_TOKEN_BUDGET",
            "JOB_MAX_RUNS_PER_HOUR", "JOB_RUN_TIMEOUT_SECONDS",
        ])
        #expect(JobLimitSetting.allCases.count == 5)
    }

    @Test("each stepper starts at its documented default and writes through to the config")
    func roundTrips() {
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        for limit in JobLimitSetting.allCases {
            #expect(limit.value(in: config) == limit.defaultValue,
                    "\(limit.configKey) should start at its default")
            limit.set(limit.defaultValue + limit.step, in: config)
            #expect(limit.value(in: config) == limit.defaultValue + limit.step)
            #expect(config.store.integer(forKey: limit.configKey) == limit.defaultValue + limit.step)
        }
    }

    @Test("a negative figure clamps to zero rather than taking a job's ceiling off")
    func negativesClamp() {
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        for limit in JobLimitSetting.allCases {
            limit.set(-5, in: config)
            #expect(limit.value(in: config) == 0, "\(limit.configKey) should clamp")
        }
        // And zero is what "use the built-in default" looks like: `JobLimits.resolve` reads every
        // one of these back as the spec's figure.
        let job = Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
        let limits = JobLimits.resolve(job: job, config: config)
        #expect(limits.perRunTokens == ConfigManager.JobDefaults.perRunTokenBudget)
        #expect(limits.dailyTokens == ConfigManager.JobDefaults.dailyTokenBudget)
        #expect(limits.globalDailyTokens == ConfigManager.JobDefaults.globalDailyTokenBudget)
        #expect(limits.maxRunsPerHour == ConfigManager.JobDefaults.maxRunsPerHour)
        #expect(limits.runTimeoutSeconds == ConfigManager.JobDefaults.runTimeoutSeconds)
    }

    @Test("a zero on the stepper reads as the default it will actually use")
    func labelsSayWhatZeroMeans() {
        for limit in JobLimitSetting.allCases {
            #expect(limit.label(0).contains("default"), "\(limit.configKey): \(limit.label(0))")
            #expect(!limit.label(limit.defaultValue + limit.step).contains("default"))
            #expect(limit.label(0).hasPrefix(limit.title))
            // No milestone or pull-request names in anything a person reads (invariant 9).
            #expect(!limit.label(0).lowercased().contains("deliverable"))
            #expect(!limit.help.lowercased().contains("deliverable"))
        }
    }
}
