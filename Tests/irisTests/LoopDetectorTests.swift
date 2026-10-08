import Testing
import Foundation
@testable import IrisKit

@Suite("LoopDetector")
struct LoopDetectorTests {
    @Test("signature is deterministic regardless of arg insertion order")
    func deterministicSignature() {
        let a: [String: JSONValue] = ["path": .string("/x"), "mode": .string("r")]
        let b: [String: JSONValue] = ["mode": .string("r"), "path": .string("/x")]
        #expect(LoopDetector.signature(toolName: "read_file", args: a)
                == LoopDetector.signature(toolName: "read_file", args: b))
    }

    @Test("different tool or args produce different signatures")
    func distinctSignatures() {
        let s1 = LoopDetector.signature(toolName: "run_command", args: ["command": .string("ls")])
        let s2 = LoopDetector.signature(toolName: "run_command", args: ["command": .string("pwd")])
        let s3 = LoopDetector.signature(toolName: "read_file", args: ["command": .string("ls")])
        #expect(s1 != s2)
        #expect(s1 != s3)
    }

    @Test("record trips only after threshold identical signatures")
    func tripsAtThreshold() {
        var d = LoopDetector(threshold: 3)
        #expect(d.record("a") == false)
        #expect(d.record("a") == false)
        #expect(d.record("a") == true)   // 3rd identical → loop
    }

    @Test("a differing signature resets the run")
    func resets() {
        var d = LoopDetector(threshold: 3)
        _ = d.record("a"); _ = d.record("a")
        #expect(d.record("b") == false)  // reset
        #expect(d.record("b") == false)
        #expect(d.record("b") == true)
    }

    @Test("reset() clears history")
    func explicitReset() {
        var d = LoopDetector(threshold: 2)
        _ = d.record("a")
        d.reset()
        #expect(d.record("a") == false)
    }
}
