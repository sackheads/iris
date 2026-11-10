import AppKit
import SwiftUI

/// Remembers where a person dragged a two-pane `HSplitView`'s divider (#1027). SwiftUI keeps the
/// divider only in the `NSSplitView` it bridges to, which is rebuilt whenever the pane is
/// re-created (switching away and back, or a submit that re-renders the list), so it snapped
/// back to its default each time. The first pane's width is kept in `IrisDefaults.store` under
/// `key`, applied when the split view first appears, and rewritten as it is dragged.
/// Removes its notification observer when released, which a main-actor class's own `deinit`
/// cannot do (the token is not `Sendable`).
private final class ObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class SplitDividerPersister {
    private let store: UserDefaults
    private let key: String
    private let minimum: CGFloat
    private weak var splitView: NSSplitView?
    private var observer: ObserverToken?
    /// True while `apply` moves the divider, so that move is not saved back as if dragged.
    private var applying = false

    init(store: UserDefaults, key: String, minimum: CGFloat) {
        self.store = store
        self.key = key
        self.minimum = minimum
    }

    /// The saved first-pane width, or nil when none was saved or it is not a usable number.
    var savedWidth: CGFloat? {
        guard let width = store.object(forKey: key) as? Double, width.isFinite, width >= minimum else { return nil }
        return CGFloat(width)
    }

    /// Takes over `splitView`: restores the saved width and starts saving drags. Idempotent for
    /// the same split view.
    func attach(to splitView: NSSplitView) {
        guard self.splitView !== splitView else { return }
        self.splitView = splitView
        apply(to: splitView)
        observer = ObserverToken(NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        })
    }

    private func apply(to splitView: NSSplitView) {
        guard let width = savedWidth, splitView.arrangedSubviews.count >= 2 else { return }
        // Leave room for the other pane: never ask for a first pane wider than the split view
        // can give while the second keeps its own minimum (the panes' minWidths bound the rest).
        let limit = splitView.bounds.width - splitView.dividerThickness
        guard limit > 0 else { return }
        applying = true
        splitView.setPosition(min(width, limit), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        applying = false
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

    func makeCoordinator() -> SplitDividerPersister {
        SplitDividerPersister(store: IrisDefaults.store, key: key, minimum: minimum)
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
            DispatchQueue.main.async { [weak self] in
                guard let self, let split = sequence(first: self.superview, next: { $0?.superview })
                    .compactMap({ $0 as? NSSplitView }).first else { return }
                MainActor.assumeIsolated { self.persister.attach(to: split) }
            }
        }
    }
}
