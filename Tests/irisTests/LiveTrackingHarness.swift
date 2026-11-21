import AppKit
import SwiftUI

/// #1277: hosts a SwiftUI view offscreen, mutates the `@Observable` state it reads, and reports
/// whether the rendered pixels changed. That is the #223/#224/#988 bug class: a view that reads
/// its data inside `body` re-renders when the data changes, and one that took it as a captured
/// value freezes and never does. Nothing here touches the product: the signal is the bitmap, not
/// an instrumented body.
///
/// Nothing is shown or made key (as `HostedTextAppearanceTests`). A view that paints nothing
/// cannot be told apart before and after, so the host asserts its first render is not blank.
@MainActor
final class ViewHost<Content: View> {
    private let window: NSWindow
    private let hosting: NSHostingView<Content>

    /// The part of the view the digest covers, in unit coordinates (origin top-left). A view with
    /// its own ticking clock narrows this to the part that clock does not touch, or a freeze would
    /// still repaint and pass.
    private let region: CGRect

    init(size: CGSize = CGSize(width: 320, height: 60), region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
         @ViewBuilder _ content: () -> Content) {
        self.region = region
        hosting = NSHostingView(rootView: content())
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        render()
    }

    deinit { MainActor.assumeIsolated { window.close() } }

    /// A digest of what the view paints now.
    func snapshot() -> Int {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let whole = rep.cgImage else { return 0 }
        let crop = CGRect(x: region.minX * CGFloat(whole.width), y: region.minY * CGFloat(whole.height),
                          width: region.width * CGFloat(whole.width), height: region.height * CGFloat(whole.height))
        guard let part = whole.cropping(to: crop) else { return 0 }
        return NSBitmapImageRep(cgImage: part).representation(using: .tiff, properties: [:])?.hashValue ?? 0
    }

    /// One turn of the main run loop, then a layout and display pass, so SwiftUI applies the
    /// invalidation an observed change queued.
    private func render() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    /// Runs `mutation`, then lets the view settle. True if the pixels changed within `within`
    /// seconds. A view that must NOT change waits out the whole bound, so keep it small there.
    @discardableResult
    func repaints(within seconds: Double = 1.0, after mutation: () -> Void) -> Bool {
        let before = snapshot()
        mutation()
        let deadline = TestClock.deadline(seconds)
        while TestClock.now() < deadline {
            render()
            if snapshot() != before { return true }
        }
        return false
    }
}
