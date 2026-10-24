import Foundation
import Testing

/// #674: Security and Advanced both showed `lock.shield`, so the tab bar had the same icon twice.
@Suite("Settings tab icons")
struct SettingsTabIconTests {
    @Test("every Settings tab has its own icon")
    func distinct() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit/SettingsView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // The tab items: `.tabItem { Label("<tab>", systemImage: "<symbol>") }`.
        let regex = try NSRegularExpression(pattern: #"\.tabItem\s*\{\s*Label\("([^"]+)",\s*systemImage:\s*"([^"]+)"\)"#)
        let tabs = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> (String, String)? in
            guard let name = Range(m.range(at: 1), in: text), let icon = Range(m.range(at: 2), in: text) else { return nil }
            return (String(text[name]), String(text[icon]))
        }
        #expect(tabs.count >= 8, "precondition: the scan found the tabs: \(tabs)")
        let icons = tabs.map(\.1)
        #expect(Set(icons).count == icons.count, "a repeated tab icon: \(tabs)")
    }
}
