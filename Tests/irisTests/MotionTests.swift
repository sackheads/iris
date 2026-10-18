import Testing
import SwiftUI
import Foundation
@testable import IrisKit

/// #562: the app's SwiftUI transitions honour Reduce Motion, through one helper.
@MainActor
@Suite("SwiftUI transitions under Reduce Motion (#562)")
struct MotionTests {
    @Test("under Reduce Motion a slide becomes a dissolve, and an animation becomes none; off, nothing changes")
    func rule() {
        let on = MotionSwitch(true).motion, off = MotionSwitch(false).motion
        #expect(!Motion.slides(on))
        #expect(Motion.slides(off))
        #expect(Motion.animation(.default, on) == nil)
        #expect(Motion.animation(.default, off) == .default)
        let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
        #expect(Motion.animation(spring, on) == nil)
        #expect(Motion.animation(spring, off) == spring)
    }

    /// Every SwiftUI animation and transition goes through `Motion`, so a new one that does not
    /// fails here until it is routed, or allowlisted on purpose with a reason.
    @Test("no withAnimation, .animation or .transition outside Motion.swift")
    func everySiteGoesThroughMotion() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        let raw = [
            try NSRegularExpression(pattern: #"(?<![\w.])withAnimation\s*[({]"#),
            try NSRegularExpression(pattern: #"(?<!Motion)\.animation\((?!Motion\.|forKey|startingAt)"#),
            try NSRegularExpression(pattern: #"\.transition\((?!Motion\.)"#),
        ]
        /// file: count of sites deliberately left raw, each with a reason. None today.
        let allowed: [String: Int] = [:]
        var found: [String: [String]] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path)
        where file.hasSuffix(".swift") && file != "Motion.swift" {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                let range = NSRange(code.startIndex..., in: code)
                if raw.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
                    found[file, default: []].append(line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(found.mapValues(\.count) == allowed, "raw SwiftUI motion outside Motion: \(found)")
    }
}
