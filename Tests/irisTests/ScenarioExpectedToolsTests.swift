import Testing
import Foundation
@testable import iris

@Suite("Scenario.expectedTools")
struct ScenarioExpectedToolsTests {
    @Test("absent means unscored, present empty means no tool is warranted")
    func decode() throws {
        let absent = try Scenario.decode(from: Data(#"{"name":"a","turns":[{"prompt":"p"}]}"#.utf8))
        #expect(absent.expectedTools == nil)
        let none = try Scenario.decode(from: Data(#"{"name":"a","expectedTools":[],"turns":[{"prompt":"p"}]}"#.utf8))
        #expect(none.expectedTools == [])
        let one = try Scenario.decode(from: Data(#"{"name":"a","expectedTools":["set_workspace"],"turns":[{"prompt":"p"}]}"#.utf8))
        #expect(one.expectedTools == ["set_workspace"])
    }

    @Test("every prompt in both eagerness suites declares expectedTools", arguments: ["tool-eagerness", "tool-eagerness-2"])
    func eagernessSuitesDeclare(name: String) throws {
        let root = PerfPaths.repoRoot()
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/\(name).json").path)
        for url in suite.scenarioURLs(relativeTo: root) {
            let scenario = try Scenario.load(at: url.path)
            #expect(scenario.expectedTools != nil, Comment(rawValue: url.lastPathComponent))
            let category = PerfRunner.category(forScenarioAt: url)
            if category.hasPrefix("model-only") { #expect(scenario.expectedTools == [], Comment(rawValue: url.lastPathComponent)) }
            if category == "tool-use" { #expect(scenario.expectedTools?.isEmpty == false, Comment(rawValue: url.lastPathComponent)) }
        }
    }
}
