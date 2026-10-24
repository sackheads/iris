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

}

/// #642: a source scan, in a suite of its own that isn't `@MainActor`. In the suite above,
/// `nonisolated` didn't move it: Swift Testing ran the case on the main thread, and a scan held
/// main for a quarter second of a parallel run's start, where every `@MainActor` suite waits on it.
@Suite("SwiftUI transitions under Reduce Motion (#562): source scan")
struct MotionSourceScanTests {
    /// Every SwiftUI animation and transition goes through `Motion`, so a new one that does not
    /// fails here until it is routed, or allowlisted on purpose with a reason.
    @Test("no withAnimation, .animation or .transition outside Motion.swift")
    func everySiteGoesThroughMotion() throws {
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
    private nonisolated static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The models change from NSTextView's edit and key callbacks; a `withAnimation` there crashed
    /// the app in #757's GUI check (Observation's access list, then a typesetter out-of-bounds).
    @Test("the popup models never open an animation themselves")
    nonisolated func modelsDoNotAnimate() throws {
        for file in ["EmojiTokenModel.swift", "SlashCommandModel.swift"] {
            let code = try Self.source(file).components(separatedBy: "\n")
                .map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
            #expect(code.contains("suggestions = hits"), "precondition: the scan read \(file)")
            #expect(!code.contains("withAnimation") && !code.contains("withTransaction"), "\(file) animates")
        }
    }

    @Test("ChatView slides each popup in and out with the reveal animation, keyed to its visibility")
    nonisolated func viewAnimatesPopups() throws {
        let chat = try Self.source("ChatView.swift")
        for model in ["emojiModel", "slashModel"] {
            #expect(chat.contains(".animation(Motion.animation(Motion.reveal), value: \(model).isShowing)"), "\(model)")
        }
    }

    @Test("the slash popup's model shows and clears, keeping its state right")
    func slashModel() {
        let model = SlashCommandModel()
        model.update(text: "/")
        #expect(model.isShowing)
        model.clear()
        #expect(!model.isShowing && model.selectedIndex == 0)
    }
}
