import SwiftUI
import Testing
@testable import IrisKit

/// #277: what reads on a dark window is not what reads on a light one.
@Suite("Iris palette across appearances")
struct IrisPaletteTests {
    @Test func darkLooksAreTheOnesThatShippedBefore() {
        #expect(IrisPalette.ledWell(.dark) == Color.black.opacity(0.30))
        #expect(IrisPalette.ledEdge(.dark) == Color.white.opacity(0.10))
        #expect(IrisPalette.bubbleFaintOpacity(.dark) == 0.55)
        #expect(IrisPalette.spectrumOpacity(.dark) == 0.7)
        #expect(IrisPalette.buttonFill(enabled: false, .dark) == Color.irisIndigo.opacity(0.4))
    }

    @Test func lightWindowGetsALighterWellAndADarkEdge() {
        #expect(IrisPalette.ledWell(.light) == Color.black.opacity(0.07))
        #expect(IrisPalette.ledEdge(.light) == Color.black.opacity(0.12))
    }

    @Test func lightWindowKeepsWhiteTextReadable() {
        // White text sits on the bubble and on a disabled fill: a paler fill than the dark one
        // would lose it.
        #expect(IrisPalette.bubbleFaintOpacity(.light) == 0.9)
        #expect(IrisPalette.buttonFill(enabled: false, .light) == Color.irisIndigo.opacity(0.6))
        #expect(IrisPalette.buttonFill(enabled: true, .light) == Color.irisIndigo)
        #expect(IrisPalette.spectrumOpacity(.light) == 1)
    }

    @Test func unlitLEDIsMoreOpaqueOnALightAppearance() throws {
        let off = NSColor(IrisPalette.ledOff)
        func alpha(_ name: NSAppearance.Name) throws -> CGFloat {
            let appearance = try #require(NSAppearance(named: name))
            var a: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance { a = off.usingColorSpace(.sRGB)?.alphaComponent ?? 0 }
            return a
        }
        #expect(try alpha(.aqua) > alpha(.darkAqua))
    }

    // MARK: Pros and cons (#1023)

    /// WCAG relative luminance and contrast ratio.
    private func luminance(_ c: NSColor) -> Double {
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let rgb = c.usingColorSpace(.sRGB)!
        return 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    @Test("pro and con text pass 4.5:1 on a light window and on a dark one")
    func proAndConAreReadable() {
        let light = NSColor.white
        let dark = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)   // darker than the window's own dark grey
        #expect(contrast(IrisPalette.proLight, light) >= 4.5)
        #expect(contrast(IrisPalette.conLight, light) >= 4.5)
        #expect(contrast(IrisPalette.proDark, dark) >= 4.5)
        #expect(contrast(IrisPalette.conDark, dark) >= 4.5)
    }

    @Test("pro is blue and con is orange: apart on the blue-yellow axis, so red-green colour blindness keeps them apart")
    func proAndConAreNotRedAndGreen() {
        for (pro, con) in [(IrisPalette.proLight, IrisPalette.conLight), (IrisPalette.proDark, IrisPalette.conDark)] {
            let p = pro.usingColorSpace(.sRGB)!, c = con.usingColorSpace(.sRGB)!
            #expect(p.blueComponent > p.redComponent && p.blueComponent > p.greenComponent, "pro leans blue")
            #expect(c.redComponent > c.blueComponent && c.redComponent > c.greenComponent, "con leans warm")
            // Blue minus yellow (the axis red-green colour blindness leaves alone) must differ clearly.
            func blueYellow(_ k: NSColor) -> Double { Double(k.blueComponent) - Double(k.redComponent + k.greenComponent) / 2 }
            #expect(blueYellow(p) - blueYellow(c) > 0.5, "pro and con sit far apart on the blue-yellow axis")
        }
    }

    @Test("the dynamic colours resolve to the light pair on an aqua appearance and the dark pair on darkAqua")
    func proAndConFollowTheAppearance() {
        func resolved(_ color: Color, _ appearance: NSAppearance.Name) -> NSColor {
            var out = NSColor.clear
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { out = NSColor(color).usingColorSpace(.sRGB)! }
            return out
        }
        #expect(resolved(IrisPalette.pro, .aqua) == IrisPalette.proLight.usingColorSpace(.sRGB))
        #expect(resolved(IrisPalette.con, .darkAqua) == IrisPalette.conDark.usingColorSpace(.sRGB))
    }
}

