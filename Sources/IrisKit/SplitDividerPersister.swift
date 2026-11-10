import AppKit
import SwiftUI

/// Removes its notification observer when released, which a main-actor class's own `deinit`
/// cannot do (the token is not `Sendable`).
private final class ObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Remembers where a person dragged a two-pane `HSplitView`'s divider (#1027). SwiftUI keeps the
/// divider only in the `NSSplitView` it bridges to, which is rebuilt whenever the pane is
/// re-created (switching away and back, or a submit that re-renders the list), so it snapped
/// back to its default each time. The first pane's width is kept in `IrisDefaults.store` under
/// `key`, applied when the split view first appears, and rewritten as it is dragged.
@MainActor
final class SplitDividerPersister {
    private let store: UserDefaults
    private let key: String
    private let minimum: CGFloat
    private let secondPaneMinimum: CGFloat
    private weak var splitView: NSSplitView?
    private var observer: ObserverToken?
    /// True while `apply` moves the divider, so that move is not saved back as if dragged.
    private var applying = false
    private var restored = false

    /// Whether a resize of `splitView` right now is the person dragging its divider: the primary
    /// button is down and the window is not being resized by hand (a resize also moves the panes,
    /// and `NSSplitViewDividerIndex` in the notification is present then too, so it cannot tell
    /// them apart). Injectable so a test can stand in for the mouse.
    private let isUserDrag: (NSSplitView) -> Bool

    init(store: UserDefaults, key: String, minimum: CGFloat, secondPaneMinimum: CGFloat = 0,
         isUserDrag: @escaping (NSSplitView) -> Bool = { split in
             NSEvent.pressedMouseButtons & 1 != 0 && split.window?.inLiveResize != true
         }) {
        self.isUserDrag = isUserDrag
        self.store = store
        self.key = key
        self.minimum = minimum
        self.secondPaneMinimum = secondPaneMinimum
    }

    /// The saved first-pane width, or nil when none was saved or it is not a usable number.
    var savedWidth: CGFloat? {
        guard let width = store.object(forKey: key) as? Double, width.isFinite, width >= minimum else { return nil }
        return CGFloat(width)
    }

    /// Takes over `splitView`: restores the saved width and starts saving drags. Idempotent for
    /// the same split view once it has been restored; a split view that was not ready (no width
    /// yet, or fewer than two panes) is tried again on the next call.
    func attach(to splitView: NSSplitView) {
        if self.splitView !== splitView {
            self.splitView = splitView
            restored = false
            observer = ObserverToken(NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { if let self, self.isUserDrag(splitView) { self.save() } }
            })
        }
        guard !restored else { return }
        restored = apply(to: splitView)
    }

    /// True once there is nothing left to restore: a width was applied, or none was saved.
    private func apply(to splitView: NSSplitView) -> Bool {
        guard splitView.arrangedSubviews.count >= 2, splitView.bounds.width > 0 else { return false }
        guard let width = savedWidth else { return true }
        // Leave the second pane its own minimum, so a window narrower than when the width was saved
        // does not squeeze the detail to nothing.
        let limit = splitView.bounds.width - splitView.dividerThickness - secondPaneMinimum
        guard limit >= minimum else { return true }
        applying = true
        splitView.setPosition(min(width, limit), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        applying = false
        return true
    }

    private func save() {
        guard !applying, let first = splitView?.arrangedSubviews.first else { return }
        let width = first.frame.width
        guard width.isFinite, width >= minimum else { return }
        store.set(Double(width), forKey: key)
    }
}

/// Finds the `NSSplitView` an `HSplitView` bridges to and hands it to a `SplitDividerPersister`.
/// Put it in a pane's `.background`: that view is hosted inside the split view, so walking up its
/// superviews reaches it.
struct SplitDividerPersistence: NSViewRepresentable {
    let key: String
    let minimum: CGFloat
    let secondPaneMinimum: CGFloat

    func makeCoordinator() -> SplitDividerPersister {
        SplitDividerPersister(store: IrisDefaults.store, key: key, minimum: minimum, secondPaneMinimum: secondPaneMinimum)
    }

    func makeNSView(context: Context) -> NSView { Probe(persister: context.coordinator) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let persister: SplitDividerPersister
        init(persister: SplitDividerPersister) {
            self.persister = persister
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After this layout pass, so the split view has its real size to restore into.
            DispatchQueue.main.async { [weak self] in self?.attachIfReady() }
        }

        /// A split view that had no width when first found is tried again on the next layout.
        override func layout() {
            super.layout()
            attachIfReady()
        }

        private func attachIfReady() {
            guard window != nil, let split = sequence(first: superview, next: { $0?.superview })
                .compactMap({ $0 as? NSSplitView }).first else { return }
            MainActor.assumeIsolated { persister.attach(to: split) }
        }
    }
}
