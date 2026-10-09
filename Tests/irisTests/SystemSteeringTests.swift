import Testing
import Foundation
@testable import iris

@Suite("SystemSteering Tests")
struct SystemSteeringTests {

    @Test("shipped() loads the bundled SYSTEM.md with its key sections")
    func testShippedLoadsBundledSystemMd() {
        let steering = SystemSteering.shipped()
        #expect(!steering.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(steering.contains("Operating Context"))
        #expect(steering.contains("Workspace Conventions"))
        #expect(steering.contains("untrusted_context"))
        #expect(steering.contains("OKF"))
    }

    @Test("fallback still carries the security posture")
    func testFallbackCarriesSecurityPosture() {
        #expect(SystemSteering.fallback.contains("Operating Context"))
        #expect(SystemSteering.fallback.contains("untrusted_context"))
        #expect(SystemSteering.fallback.contains("authorization"))
    }

    @Test("shipped() never leaves the bare ~/.iris spelling in test, where the identity is dev")
    func testShippedRewritesHomeUnderTest() {
        #expect(!SystemSteering.shipped().contains("~/.iris/"))
    }

    @Test("fallback has no leading indentation from the multi-line literal")
    func testFallbackHasNoLeadingIndentation() {
        // The `"""` literal is indented to sit inside the enum; Swift strips the indentation
        // that matches the closing delimiter, so the emitted string must start flush-left
        // (no stray 4-space indent that would read as a code block in the prompt).
        #expect(SystemSteering.fallback.hasPrefix("# System Directives"))
        for line in SystemSteering.fallback.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(!line.hasPrefix(" "), "fallback line unexpectedly indented: \(line)")
        }
    }
}
