import Testing
import AppKit
import SwiftUI
@testable import IrisKit

/// #1052: the composer's text came out dark on a dark window. The captured real runs show the
/// composer's `NSTextView` at `NSAppearanceNameVibrantDark` (SwiftUI's vibrant variant, from the
/// `.background(.regularMaterial)` the chat composer sits on) under a `DarkAqua` window. These
/// tests host the real `ComposerTextView` / `LiteralTextEditor` on that same material, offscreen
/// (nothing is shown or made key), and assert the text surface resolves the PLAIN appearance that
/// matches SwiftUI's color scheme, and that the glyphs a bitmap render paints have the matching
/// brightness. They pin the mechanism this fix changes; whether it is the whole of the live
/// symptom is settled only by a look at the running app (see the PR).
/// (window appearance, SwiftUI scheme) including the two mismatches: the text surface follows the
/// SwiftUI scheme, as the rest of the tree does. File-level so `@Test(arguments:)` can name it.
private enum Combo: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case darkWindowDarkScheme, lightWindowLightScheme, lightWindowDarkScheme, darkWindowLightScheme
    var window: NSAppearance.Name { self == .darkWindowDarkScheme || self == .darkWindowLightScheme ? .darkAqua : .aqua }
    var scheme: ColorScheme { self == .darkWindowDarkScheme || self == .lightWindowDarkScheme ? .dark : .light }
    var expected: NSAppearance.Name { scheme == .dark ? .darkAqua : .aqua }
    var testDescription: String { rawValue }
}

@MainActor
@Suite("Hosted text appearance (#1052)", .serialized)
struct HostedTextAppearanceTests {
    private static func allSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allSubviews) }

    /// Mean brightness of the glyph pixels of a bitmap render. The composer draws no background, so
    /// its glyphs are the fairly opaque pixels; the literal editor draws one, so there the glyphs
    /// are the pixels far from the background's brightness (read at a corner, which holds no text).
    private static func glyphBrightness(of tv: NSTextView) throws -> Double {
        tv.layoutSubtreeIfNeeded()
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: rep)
        func brightness(_ c: NSColor) -> Double { Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 }
        let background = tv.drawsBackground
            ? try #require(rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh - 2)?.usingColorSpace(.deviceRGB)).map(brightness)
            : nil
        var sum = 0.0, n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.6 else { continue }
                let b = brightness(c)
                if let background, abs(b - background) < 0.4 { continue }
                sum += b
                n += 1
            }
        }
        try #require(n > 0, "the render painted no glyph pixels at all")
        return sum / Double(n)
    }

    private static func textView<V: View>(in root: V, windowAppearance: NSAppearance.Name) throws -> (NSTextView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: windowAppearance)
        let host = NSHostingView(rootView: root)
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        // One turn of the run loop: SwiftUI applies its appearance choices to platform views on it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let tv = try #require(allSubviews(host).compactMap { $0 as? NSTextView }.first)
        return (tv, window)
    }

    private static func composer() -> ComposerTextView {
        ComposerTextView(text: .constant("hello composer text"), onSubmit: {}, emoji: EmojiTokenModel(), slash: SlashCommandModel())
    }

    private static func literal() -> LiteralTextEditor {
        LiteralTextEditor(text: .constant("{\"hello\": \"literal text\"}"))
    }

    @Test("the composer on a material resolves plain Aqua/DarkAqua matching the color scheme, never a vibrant variant",
          arguments: Combo.allCases)
    fileprivate func composerOnMaterialResolvesPlainAppearance(_ combo: Combo) throws {
        let (windowName, scheme) = (combo.window, combo.scheme)
        let root = Self.composer().padding(8).background(.regularMaterial).environment(\.colorScheme, scheme)
        let (tv, window) = try Self.textView(in: root, windowAppearance: windowName)
        _ = window
        #expect(tv.effectiveAppearance.name == combo.expected,
                "got \(tv.effectiveAppearance.name.rawValue), wanted \(combo.expected.rawValue)")
        let brightness = try Self.glyphBrightness(of: tv)
        if scheme == .dark { #expect(brightness > 0.8, "dark scheme must paint light glyphs, got \(brightness)") }
        else { #expect(brightness < 0.2, "light scheme must paint dark glyphs, got \(brightness)") }
    }

    @Test("the literal editor on a material resolves plain Aqua/DarkAqua matching the color scheme too",
          arguments: Combo.allCases)
    fileprivate func literalEditorOnMaterialResolvesPlainAppearance(_ combo: Combo) throws {
        let (windowName, scheme) = (combo.window, combo.scheme)
        let root = Self.literal().frame(width: 400, height: 100).background(.regularMaterial).environment(\.colorScheme, scheme)
        let (tv, window) = try Self.textView(in: root, windowAppearance: windowName)
        _ = window
        #expect(tv.effectiveAppearance.name == combo.expected,
                "got \(tv.effectiveAppearance.name.rawValue), wanted \(combo.expected.rawValue)")
        let brightness = try Self.glyphBrightness(of: tv)
        if scheme == .dark { #expect(brightness > 0.8, "dark scheme must paint light glyphs, got \(brightness)") }
        else { #expect(brightness < 0.2, "light scheme must paint dark glyphs, got \(brightness)") }
    }

    @Test("the material treatment stays: the views above the pinned scroll view still resolve the vibrant variant",
          arguments: [Combo.darkWindowDarkScheme, Combo.lightWindowLightScheme])
    fileprivate func materialTreatmentOfTheHostIsUntouched(_ combo: Combo) throws {
        let root = Self.composer().padding(8).background(.regularMaterial).environment(\.colorScheme, combo.scheme)
        let (tv, window) = try Self.textView(in: root, windowAppearance: combo.window)
        _ = window
        let scroll = try #require(tv.enclosingScrollView)
        #expect(scroll.appearance?.name == combo.expected, "the pin is on the scroll view only")
        var ancestors: [NSAppearance.Name] = []
        var v = scroll.superview
        while let cur = v { ancestors.append(cur.effectiveAppearance.name); v = cur.superview }
        let vibrant: [NSAppearance.Name] = [.vibrantDark, .vibrantLight]
        #expect(ancestors.contains { vibrant.contains($0) },
                "SwiftUI must still put the material's content in the vibrant variant above the pin; got \(ancestors.map(\.rawValue))")
        #expect(!vibrant.contains(tv.effectiveAppearance.name))
    }

    @Test("a scheme change after the surface exists re-pins it (updateNSView path)")
    func schemeChangeRePins() throws {
        struct Flip: View {
            @State var dark = true
            var body: some View {
                ComposerTextView(text: .constant("hello"), onSubmit: {}, emoji: EmojiTokenModel(), slash: SlashCommandModel())
                    .padding(8).background(.regularMaterial)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HostedTextAppearanceTests.flip"))) { _ in dark.toggle() }
            }
        }
        let (tv, window) = try Self.textView(in: Flip(), windowAppearance: .darkAqua)
        _ = window
        #expect(tv.effectiveAppearance.name == .darkAqua)
        NotificationCenter.default.post(name: Notification.Name("HostedTextAppearanceTests.flip"), object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(tv.effectiveAppearance.name == .aqua, "after the scheme flipped to light got \(tv.effectiveAppearance.name.rawValue)")
    }

    @Test("apply pins only on a change and maps schemes to plain appearances")
    func applyIsIdempotent() {
        let view = NSView()
        HostedTextAppearance.apply(to: view, scheme: .dark)
        #expect(view.appearance?.name == .darkAqua)
        let first = view.appearance
        HostedTextAppearance.apply(to: view, scheme: .dark)
        #expect(view.appearance === first, "an unchanged scheme must not reassign the appearance")
        HostedTextAppearance.apply(to: view, scheme: .light)
        #expect(view.appearance?.name == .aqua)
    }
}
