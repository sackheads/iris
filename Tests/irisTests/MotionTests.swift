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
        // An appearance (the banner coming in) dissolves rather than cutting; off, its spring.
        #expect(Motion.appearance(spring, on) == Motion.dissolve)
        #expect(Motion.appearance(spring, off) == spring)
    }

    /// Every SwiftUI animation and transition goes through `Motion`, so a new one that does not
    /// fails here until it is routed, or allowlisted on purpose with a reason.
    @Test("no withAnimation, .animation or .transition outside Motion.swift")
    nonisolated func everySiteGoesThroughMotion() throws {
        // Off the main actor: a scan of the sources held it for seconds in a parallel run (#637).
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        let raw = [
            try NSRegularExpression(pattern: #"(?<!Motion\.)\bwithAnimation\s*[({]"#),
            try NSRegularExpression(pattern: #"\bwithTransaction\s*[({]"#),
            try NSRegularExpression(pattern: #"\.transaction\s*[({]"#),
            try NSRegularExpression(pattern: #"(?<!Motion)\.animation\((?!Motion\.|forKey|startingAt)"#),
            try NSRegularExpression(pattern: #"\.transition\((?!Motion\.)"#),
        ]
        /// file: count of sites deliberately left raw, each with a reason. None today.
        let allowed: [String: Int] = [:]
        var found: [String: [String]] = [:]
        // Recursive, so a future subfolder of Sources is scanned too.
        let files = (FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Motion.swift") }
        #expect(files.count > 50, "precondition: the scan found the sources")
        for file in files {
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

@MainActor
@Suite("Composer popups and the session strip slide in (#598)")
struct RevealTests {
    @Test("a popup appearing or going is animated; new suggestions while it shows aren't; Reduce Motion animates nothing")
    func revealing() {
        let on = MotionSwitch(true).motion, off = MotionSwitch(false).motion
        var ran = 0
        #expect(Motion.revealing(from: false, to: true, off) { ran += 1 })
        #expect(Motion.revealing(from: true, to: false, off) { ran += 1 })
        #expect(!Motion.revealing(from: true, to: true, off) { ran += 1 })
        #expect(!Motion.revealing(from: false, to: true, on) { ran += 1 })
        #expect(ran == 4, "the change is always made")
    }

    @Test("the slash popup's model shows and clears through the reveal, keeping its state right")
    func slashModel() {
        let model = SlashCommandModel()
        model.update(text: "/")
        #expect(model.isShowing)
        model.clear()
        #expect(!model.isShowing && model.selectedIndex == 0)
    }
}
