import Testing
import AppKit
import SwiftUI
@testable import IrisKit

/// (window appearance, SwiftUI scheme) including the two mismatches: the text surface follows the
/// SwiftUI scheme, as the rest of the tree does. File-level so `@Test(arguments:)` can name it.
private enum Combo: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case darkWindowDarkScheme, lightWindowLightScheme, lightWindowDarkScheme, darkWindowLightScheme
    var window: NSAppearance.Name { self == .darkWindowDarkScheme || self == .darkWindowLightScheme ? .darkAqua : .aqua }
    var scheme: ColorScheme { self == .darkWindowDarkScheme || self == .lightWindowDarkScheme ? .dark : .light }
    var testDescription: String { rawValue }
}

/// What the pin should produce here: the plain appearance for the scheme. Whether the window agrees
/// (its own appearance, a plain Aqua/DarkAqua in these tests) or disagrees (the plain one is forced),
/// the result has this name.
private func expectedName(_ combo: Combo) -> NSAppearance.Name { HostedTextAppearance.plainName(for: combo.scheme) }

/// #1052: the composer's text came out dark on a dark window. The captured real runs show the
/// composer's `NSTextView` at `NSAppearanceNameVibrantDark` (SwiftUI's vibrant variant, from the
/// `.background(.regularMaterial)` the chat composer sits on) under a `DarkAqua` window. These
/// tests host the real `ComposerTextView` / `LiteralTextEditor` on that same material, offscreen
/// (nothing is shown or made key). **The appearance-name assertions are the ones that pin the
/// change**: they fail without the pin (`VibrantDark` instead of `DarkAqua`). The glyph-brightness
/// assertions are only a smoke check that nothing regressed the paint: an offscreen render paints
/// correct glyphs in the vibrant variant too, so they pass with and without the pin and are NOT
/// evidence that the live dark-text symptom is gone; only a look at the running app settles that.
@MainActor
@Suite("Hosted text appearance (#1052)", .serialized)
struct HostedTextAppearanceTests {
    private static func allSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allSubviews) }

    /// Mean brightness of the glyph pixels of a bitmap render. The composer draws no background, so
    /// its glyphs are the fairly opaque pixels; the literal editor draws one, so there the glyphs
    /// are the pixels far from the background's brightness (read at a corner, which holds no text).
    /// Thresholds below are a midpoint, not a tight bound: a CI runner's glyph anti-aliasing is
    /// greyer than a desktop Mac's (a light-scheme render read 0.33 there against under 0.2 here).
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
        host.layoutSubtreeIfNeeded()
        let tv = try #require(allSubviews(host).compactMap { $0 as? NSTextView }.first)
        return (tv, window)
    }

    /// SwiftUI applies its appearance choices to platform views on a later turn of the main queue:
    /// poll for the condition, bounded, instead of waiting a fixed time a loaded run could miss.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = TestClock.deadline(5)
        while TestClock.now() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func composer() -> ComposerTextView {
        ComposerTextView(text: .constant("hello composer text"), onSubmit: {}, emoji: EmojiTokenModel(), slash: SlashCommandModel())
    }

    private static func literal() -> LiteralTextEditor {
        LiteralTextEditor(text: .constant("{\"hello\": \"literal text\"}"))
    }

    @Test("the composer on a material resolves plain Aqua/DarkAqua matching the color scheme, never a vibrant variant",
          arguments: Combo.allCases)
    fileprivate func composerOnMaterialResolvesPlainAppearance(_ combo: Combo) async throws {
        let (windowName, scheme) = (combo.window, combo.scheme)
        let root = Self.composer().padding(8).background(.regularMaterial).environment(\.colorScheme, scheme)
        let (tv, window) = try Self.textView(in: root, windowAppearance: windowName)
        _ = window
        _ = await Self.eventually { tv.effectiveAppearance.name == expectedName(combo) }
        #expect(tv.effectiveAppearance.name == expectedName(combo),
                "got \(tv.effectiveAppearance.name.rawValue), wanted \(expectedName(combo).rawValue)")
        let brightness = try Self.glyphBrightness(of: tv)
        if scheme == .dark { #expect(brightness > 0.5, "dark scheme must paint light glyphs, got \(brightness)") }
        else { #expect(brightness < 0.5, "light scheme must paint dark glyphs, got \(brightness)") }
    }

    @Test("the literal editor on a material resolves plain Aqua/DarkAqua matching the color scheme too",
          arguments: Combo.allCases)
    fileprivate func literalEditorOnMaterialResolvesPlainAppearance(_ combo: Combo) async throws {
        let (windowName, scheme) = (combo.window, combo.scheme)
        let root = Self.literal().frame(width: 400, height: 100).background(.regularMaterial).environment(\.colorScheme, scheme)
        let (tv, window) = try Self.textView(in: root, windowAppearance: windowName)
        _ = window
        _ = await Self.eventually { tv.effectiveAppearance.name == expectedName(combo) }
        #expect(tv.effectiveAppearance.name == expectedName(combo),
                "got \(tv.effectiveAppearance.name.rawValue), wanted \(expectedName(combo).rawValue)")
        let brightness = try Self.glyphBrightness(of: tv)
        if scheme == .dark { #expect(brightness > 0.5, "dark scheme must paint light glyphs, got \(brightness)") }
        else { #expect(brightness < 0.5, "light scheme must paint dark glyphs, got \(brightness)") }
    }

    @Test("the material treatment stays: the views above the pinned scroll view still resolve the vibrant variant",
          arguments: [Combo.darkWindowDarkScheme, Combo.lightWindowLightScheme])
    fileprivate func materialTreatmentOfTheHostIsUntouched(_ combo: Combo) async throws {
        let root = Self.composer().padding(8).background(.regularMaterial).environment(\.colorScheme, combo.scheme)
        let (tv, window) = try Self.textView(in: root, windowAppearance: combo.window)
        _ = window
        _ = await Self.eventually { tv.effectiveAppearance.name == expectedName(combo) }
        let scroll = try #require(tv.enclosingScrollView)
        #expect(scroll.appearance?.name == expectedName(combo), "the pin is on the scroll view only")
        var ancestors: [NSAppearance.Name] = []
        var v = scroll.superview
        while let cur = v { ancestors.append(cur.effectiveAppearance.name); v = cur.superview }
        let vibrant: [NSAppearance.Name] = [.vibrantDark, .vibrantLight]
        #expect(ancestors.contains { vibrant.contains($0) },
                "SwiftUI must still put the material's content in the vibrant variant above the pin; got \(ancestors.map(\.rawValue))")
        #expect(!vibrant.contains(tv.effectiveAppearance.name))
    }

    @Test("a scheme change after the surface exists re-pins it (updateNSView path)")
    func schemeChangeRePins() async throws {
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
        let dark = HostedTextAppearance.plainName(for: .dark)
        let light = HostedTextAppearance.plainName(for: .light)
        _ = await Self.eventually { tv.effectiveAppearance.name == dark }
        #expect(tv.effectiveAppearance.name == dark)
        NotificationCenter.default.post(name: Notification.Name("HostedTextAppearanceTests.flip"), object: nil)
        _ = await Self.eventually { tv.effectiveAppearance.name == light }
        #expect(tv.effectiveAppearance.name == light, "after the scheme flipped to light got \(tv.effectiveAppearance.name.rawValue)")
    }

    @Test("the plain name per scheme, and which names count as dark (plain, vibrant, Increase Contrast)")
    func nameTables() {
        #expect(HostedTextAppearance.plainName(for: .dark) == .darkAqua)
        #expect(HostedTextAppearance.plainName(for: .light) == .aqua)
        let dark: [NSAppearance.Name] = [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]
        let light: [NSAppearance.Name] = [.aqua, .vibrantLight, .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight]
        for name in dark { #expect(HostedTextAppearance.isDark(name), "\(name.rawValue)") }
        for name in light { #expect(!HostedTextAppearance.isDark(name), "\(name.rawValue)") }
    }

    @Test("a window that agrees with the scheme lends its own appearance; one that disagrees, or none, gets the plain one")
    func pinnedChoice() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        // No window yet: nothing to agree with.
        #expect(HostedTextAppearance.pinned(for: view, scheme: .dark)?.name == .darkAqua)
        window.contentView?.addSubview(view)
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(HostedTextAppearance.pinned(for: view, scheme: .dark)?.name == .darkAqua, "agreeing window")
        #expect(HostedTextAppearance.pinned(for: view, scheme: .light)?.name == .aqua, "disagreeing window is overridden")
        window.appearance = NSAppearance(named: .aqua)
        #expect(HostedTextAppearance.pinned(for: view, scheme: .light)?.name == .aqua)
        #expect(HostedTextAppearance.pinned(for: view, scheme: .dark)?.name == .darkAqua)
        // The window's own appearance object is what is lent when it agrees.
        #expect(HostedTextAppearance.pinned(for: view, scheme: .light) === window.effectiveAppearance)
    }

    @Test("a window whose own appearance is a vibrant variant (a HUD, say) is not lent: the plain one is pinned")
    func vibrantWindowAppearanceIsNotLent() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(view)
        window.appearance = NSAppearance(named: .vibrantDark)
        #expect(HostedTextAppearance.pinned(for: view, scheme: .dark)?.name == .darkAqua)
        window.appearance = NSAppearance(named: .vibrantLight)
        #expect(HostedTextAppearance.pinned(for: view, scheme: .light)?.name == .aqua)
        for name in [NSAppearance.Name.vibrantDark, .vibrantLight, .accessibilityHighContrastVibrantDark, .accessibilityHighContrastVibrantLight] {
            #expect(HostedTextAppearance.isVibrant(name), "\(name.rawValue)")
        }
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            #expect(!HostedTextAppearance.isVibrant(name), "\(name.rawValue)")
        }
    }

    @Test("asking for an Increase Contrast name by hand returns a plain appearance: why the pin lends the window's own instead")
    func highContrastNamesCollapse() throws {
        // Documents the platform behaviour the design rests on (probed on this macOS): these names
        // do not produce a distinct pinned appearance, so a pin built from a name could not keep
        // Increase Contrast; the window's own appearance object is the only thing that carries it.
        #expect(NSAppearance(named: .accessibilityHighContrastDarkAqua)?.name == .darkAqua)
        #expect(NSAppearance(named: .accessibilityHighContrastAqua)?.name == .aqua)
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

    @Test("composer and literal editor stamp a concrete non-dynamic sRGB text color in both dark and light schemes that survives an opposing ambient drawing appearance (#1127)",
          arguments: [ColorScheme.dark, .light])
    func concreteTextColorSurvivesOpposingAmbientDrawingAppearance(_ scheme: ColorScheme) async throws {
        let winAppearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        let opposingAppearanceName: NSAppearance.Name = scheme == .dark ? .aqua : .darkAqua
        let opposingAppearance = try #require(NSAppearance(named: opposingAppearanceName))

        let composerRoot = Self.composer().padding(8).background(.regularMaterial).environment(\.colorScheme, scheme)
        let (composerTV, composerWin) = try Self.textView(in: composerRoot, windowAppearance: winAppearance)
        _ = composerWin
        _ = await Self.eventually { composerTV.effectiveAppearance.name == winAppearance }

        let literalRoot = Self.literal().frame(width: 400, height: 100).background(.regularMaterial).environment(\.colorScheme, scheme)
        let (literalTV, literalWin) = try Self.textView(in: literalRoot, windowAppearance: winAppearance)
        _ = literalWin
        _ = await Self.eventually { literalTV.effectiveAppearance.name == winAppearance }

        for tv in [composerTV, literalTV] {
            #expect(tv.textColor?.type != .catalog)
            #expect(tv.insertionPointColor.type != .catalog)
            #expect((tv.typingAttributes[.foregroundColor] as? NSColor)?.type != .catalog)
            let storedColor = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(storedColor?.type != .catalog)

            var textRed: CGFloat = 0
            var caretRed: CGFloat = 0
            var typingRed: CGFloat = 0
            var storageRed: CGFloat = 0
            var brightnessResult: Result<Double, Error>?
            opposingAppearance.performAsCurrentDrawingAppearance {
                textRed = tv.textColor?.usingColorSpace(.deviceRGB)?.redComponent ?? -1
                caretRed = tv.insertionPointColor.usingColorSpace(.deviceRGB)?.redComponent ?? -1
                typingRed = (tv.typingAttributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)?.redComponent ?? -1
                storageRed = (tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                    .usingColorSpace(.deviceRGB)?.redComponent ?? -1
                brightnessResult = Result { try Self.glyphBrightness(of: tv) }
            }
            let renderedBrightness = try #require(brightnessResult).get()
            if scheme == .dark {
                #expect(textRed > 0.8, "dark tv.textColor resolved to \(textRed) under ambient Aqua")
                #expect(caretRed > 0.8, "dark tv.insertionPointColor resolved to \(caretRed) under ambient Aqua")
                #expect(typingRed > 0.8, "dark tv.typingAttributes resolved to \(typingRed) under ambient Aqua")
                #expect(storageRed > 0.8, "dark tv.textStorage resolved to \(storageRed) under ambient Aqua")
                #expect(renderedBrightness > 0.5, "dark glyph brightness under ambient Aqua was \(renderedBrightness)")
            } else {
                #expect(textRed < 0.2, "light tv.textColor resolved to \(textRed) under ambient DarkAqua")
                #expect(caretRed < 0.2, "light tv.insertionPointColor resolved to \(caretRed) under ambient DarkAqua")
                #expect(typingRed < 0.2, "light tv.typingAttributes resolved to \(typingRed) under ambient DarkAqua")
                #expect(storageRed < 0.2, "light tv.textStorage resolved to \(storageRed) under ambient DarkAqua")
                #expect(renderedBrightness < 0.5, "light glyph brightness under ambient DarkAqua was \(renderedBrightness)")
            }
        }
    }

    @Test("empty composer pins tv.textColor property directly, and typing/didChangeText re-stamps concrete color over dynamic catalog attributes (#1127)")
    func emptyComposerTextColorAndTypingPathArePinned() async throws {
        // 1. Empty composer: `textStorage.length == 0`, so `tv.textColor` reads the property set on
        // the NSTextView itself rather than reading back from `textStorage`'s first run.
        let emptyComposer = ComposerTextView(text: .constant(""), onSubmit: {}, emoji: EmojiTokenModel(), slash: SlashCommandModel())
            .padding(8).background(.regularMaterial).environment(\.colorScheme, .dark)
        let (tv, window) = try Self.textView(in: emptyComposer, windowAppearance: .darkAqua)
        _ = window
        _ = await Self.eventually { tv.effectiveAppearance.name == .darkAqua }

        #expect(tv.textStorage?.length == 0)
        #expect(tv.textColor?.type != .catalog, "empty composer tv.textColor must be concrete, not a catalog color")
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        var emptyTextRed: CGFloat = 0
        lightAppearance.performAsCurrentDrawingAppearance {
            emptyTextRed = tv.textColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        }
        #expect(emptyTextRed > 0.8, "empty composer tv.textColor resolved to \(emptyTextRed) under ambient Aqua")

        // 2. Typing path (`insertText` -> `didChangeText`): poison `typingAttributes` and `textColor`
        // with dynamic `NSColor.labelColor`, then drive `insertText` as keyboard input does.
        tv.textColor = .labelColor
        tv.typingAttributes[.foregroundColor] = NSColor.labelColor
        tv.insertText("typed in dark mode", replacementRange: NSRange(location: 0, length: 0))

        #expect(tv.textColor?.type != .catalog, "didChangeText must restore concrete tv.textColor")
        #expect((tv.typingAttributes[.foregroundColor] as? NSColor)?.type != .catalog,
                "didChangeText must restore concrete typingAttributes[.foregroundColor]")
        let typedStorageColor = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(typedStorageColor?.type != .catalog,
                "didChangeText must re-stamp concrete foregroundColor on newly typed textStorage run")
        var typedStorageRed: CGFloat = 0
        lightAppearance.performAsCurrentDrawingAppearance {
            typedStorageRed = typedStorageColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        }
        #expect(typedStorageRed > 0.8, "typed textStorage run resolved to \(typedStorageRed) under ambient Aqua")
    }

    @Test("LiteralTextEditor updateNSView re-stamps concrete color after programmatic text replacement (#1127)")
    func literalEditorUpdateReStampsAfterTextChange() async throws {
        struct Harness: View {
            @State var text = "initial"
            var body: some View {
                LiteralTextEditor(text: $text)
                    .frame(width: 400, height: 100)
                    .background(.regularMaterial)
                    .environment(\.colorScheme, .dark)
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HostedTextAppearanceTests.replaceText"))) { _ in
                        text = "replaced programmatically"
                    }
            }
        }
        let (tv, window) = try Self.textView(in: Harness(), windowAppearance: .darkAqua)
        _ = window
        _ = await Self.eventually { tv.effectiveAppearance.name == .darkAqua }
        // Poison typingAttributes before the programmatic `tv.string = text` assignment in updateNSView
        // so that if `HostedTextAppearance.apply` ran BEFORE `tv.string = text`, the new string would
        // inherit the poisoned catalog color.
        tv.typingAttributes[.foregroundColor] = NSColor.labelColor
        NotificationCenter.default.post(name: Notification.Name("HostedTextAppearanceTests.replaceText"), object: nil)
        _ = await Self.eventually { tv.string == "replaced programmatically" }

        let storedColor = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(storedColor?.type != .catalog, "updateNSView must apply concrete color after replacing tv.string")
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        var storageRed: CGFloat = 0
        lightAppearance.performAsCurrentDrawingAppearance {
            storageRed = storedColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        }
        #expect(storageRed > 0.8)
    }

    @Test("ComposerFocusKeeper.paint reports storageFG and dynamic= flag honestly under ambient appearance (#1127)")
    func focusKeeperPaintDiagnosticReportsStorageAndDynamicFlag() async throws {
        let root = Self.composer().padding(8).background(.regularMaterial).environment(\.colorScheme, .dark)
        let (tv, window) = try Self.textView(in: root, windowAppearance: .darkAqua)
        _ = window
        _ = await Self.eventually { tv.effectiveAppearance.name == .darkAqua }

        let lightAppearance = try #require(NSAppearance(named: .aqua))
        var healthyReport = ""
        lightAppearance.performAsCurrentDrawingAppearance {
            healthyReport = ComposerFocusKeeper.paint(of: tv)
        }
        #expect(healthyReport.contains("dynamic=false"), "got \(healthyReport)")
        #expect(!healthyReport.contains("storageFG=0.00,0.00,0.00"), "got \(healthyReport)")

        // Simulate a regression to dynamic `NSColor.labelColor` in storage:
        tv.textStorage?.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                     range: NSRange(location: 0, length: tv.textStorage?.length ?? 0))
        var regressedReport = ""
        lightAppearance.performAsCurrentDrawingAppearance {
            regressedReport = ComposerFocusKeeper.paint(of: tv)
        }
        #expect(regressedReport.contains("dynamic=true"), "got \(regressedReport)")
        #expect(regressedReport.contains("storageFG=0.00,0.00,0.00"), "got \(regressedReport)")
    }

    @Test("composer and literal editor initialize TextKit 1 in makeNSView before layout so neither downgrades mid-flight (#1127)")
    func composerAndLiteralStartOnTextKit1UpFront() throws {
        for host in [NSHostingView(rootView: AnyView(Self.composer())),
                     NSHostingView(rootView: AnyView(Self.literal()))] {
            host.layoutSubtreeIfNeeded()
            let tv = try #require(Self.allSubviews(host).compactMap { $0 as? NSTextView }.first)
            #expect(tv.textLayoutManager == nil, "text view must not remain on TextKit 2 waiting to downgrade mid-flight")
            #expect(tv.layoutManager != nil)
        }
    }
}
