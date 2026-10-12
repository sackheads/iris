import AppKit
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Kept for the life of the app: `NSAppleEventManager` is not documented to retain a handler.
    private var runJobURLEvents: RunJobURLEvents?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Here, not in did-finish: a link that launches Iris arrives between the two (Task 24).
        // Never `application(_:open:)` or `.handlesExternalEvents`: SwiftUI opened a window per
        // link with either (owner ruling C2).
        runJobURLEvents = RunJobURLEvents.installForApp()
        // The same moment for a notification click that launches Iris: the delegate exists before
        // the store may be open, and the gate holds the click until it is (#463).
        SurfaceInstall.installNotificationDelegate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Sparkle wants its scheduled checks started after launch, not at construction.
            UpdaterController.shared?.start()
            // #463 decision 11: `finishLaunch` (startOnce, then the held links) runs once both this
            // and `openStore()` have happened, whichever is later. The gate also activates Iris,
            // except for a link launch while it waits (decision 13), and alerts a refused launch.
            LaunchGate.shared.didFinishLaunching()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush BEFORE _exit: it runs no atexit handlers, so it would kill the pending debounced
        // save and skip the cfprefsd flush, losing every unwritten change (#62). Only an open app
        // has an `AppState` to flush; a waiting or refused one must not build one now (#463).
        MainActor.assumeIsolated {
            LaunchGate.shared.willTerminate {
                AppState.shared.flushURLRefusalLines()
                AppState.shared.flushSave()
            }
        }
        // Conversations live in their own database now (#163), but settings and other state
        // still ride on UserDefaults, and `_exit` skips the cfprefsd flush for those too.
        IrisDefaults.store.synchronize()
        // Last, just before `_exit`: an empty payload under a held lock reads as an unnamed holder
        // (decision 5), so it must not sit there while anything else runs. A no-op in a process
        // that never held the lock, so a refused second GUI leaves the holder's payload alone.
        StoreLock.vacate(at: IrisPaths.default.storeLockFile)
        // Bypass static destructors in llama.cpp ggml-metal to prevent GGML_ASSERT crash on exit
        _exit(0)
    }
}

struct IrisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        // AppDefaultsImport.runIfNeeded() already ran in IrisMain.run(), before this initializer —
        // that is the earliest call site (also covers --run-job/--perf/--bench from a bundle
        // executable) and importOnce is idempotent, so it is not repeated here.
        //
        // #463: the store lock decides, before anything touches `conversations.sqlite`. Free, and
        // `openStore()` runs right here, as this initializer always did. Held by a `--run-job` or
        // the seeder, and the app waits behind `WaitingView` until it is free. Held by a GUI, and
        // the app alerts and quits at did-finish.
        //
        // `assumeIsolated` is safe *here* specifically: `App.init` is documented to run on the
        // main thread, and this is a synchronous call in it. It is not a general escape hatch —
        // the same construct trapped in #187's D3 PR B when it was reached from a non-isolated
        // closure. The gate's poll reaches `openStore()` from a main-queue timer, which is the
        // main thread too.
        MainActor.assumeIsolated {
            LaunchGate.shared.begin()
        }
        NSApplication.shared.setActivationPolicy(.regular)
        // No `activate` here any more: did-finish activates through the gate, which knows whether
        // a link launched Iris while it waits (plan note 13).

        if let imagePath = Bundle.module.path(forResource: "iris-icon", ofType: "png"),
           let image = NSImage(contentsOfFile: imagePath) {
            NSApplication.shared.applicationIconImage = image
        }

        // D6 decision 4: the raise goes through `showMainWindow`, like every other surface's.
        // The gate is asked when the key is pressed, not here (#463 decision 10). A hotkey is the
        // owner asking for Iris, so it activates even while waiting.
        KeyboardShortcuts.onKeyUp(for: .toggleIris) {
            if LaunchGate.shared.isOpen {
                MainWindow.tracking.toggleFromHotkey(state: AppState.shared)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                LaunchGate.shared.showNoticeNow()
            }
        }
    }

    /// #463 decision 11's first half: everything that needs the store, once, with the lock held.
    @MainActor
    static func openStore() {
        IrisMigrator.migrate(.default)
        ShippedSkills.seedIfNeeded(.default)
        // Once, in the app, on the one `AppState` that exists here — never from `AppState.init`,
        // which a test suite runs hundreds of times (#218).
        AppState.shared.installGuardHealthSink()
        // D6 decision 16: the snapshot at launch. Here and not in `AppState.init`, which a test
        // suite runs hundreds of times.
        AppState.shared.refreshLedgerAttention()
        AppState.shared.raiseMainWindow = { MainWindow.raise() }
        AppState.shared.openRunLogWindow = { RunLogWindow.open() }
        // D6 decision 8: only here, and only in a real `.app` bundle. The sink and will-finish share
        // one delegate, whichever builds it first (on a free lock, this runs before will-finish);
        // clicks still pass through the gate, which keeps their order.
        SurfaceInstall.installNotifications(on: AppState.shared)
        Task {
            // Only the lock's holder runs this, so every `iris-` container on this home it does
            // not know about belongs to a process that has ended (#463 decision 11).
            await SandboxSessionManager.shared.reapOrphans()
            while true {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // every 5 min
                let minutes = await MainActor.run { ConfigManager.shared.sandboxIdleTimeoutMinutes }
                await SandboxSessionManager.shared.reapIdle(olderThan: TimeInterval(minutes * 60))
            }
        }
    }

    /// A view, not inline, so the menu item re-reads the gate when it opens.
    private struct RerunSetupWizardButton: View {
        let gate: LaunchGate
        var body: some View {
            Button("Rerun Setup Wizard...") {
                NotificationCenter.default.post(name: NSNotification.Name("RerunSetupWizard"), object: nil)
            }
            .disabled(!gate.isOpen)   // the wizard needs `AppState`, which waiting must not build
        }
    }

    var body: some Scene {
        WindowGroup("Iris", id: MainWindow.sceneId) {
            GatedContent(gate: LaunchGate.shared) {
                ChatView()
                    .tint(.irisIndigo)
            }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                if let updater = UpdaterController.shared {
                    CheckForUpdatesButton(updater: updater)
                }
                Divider()
                RerunSetupWizardButton(gate: LaunchGate.shared)
            }
        }

        // Touches no store (MetricsManager and PerformanceProfiler only), so it is not gated.
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }

        Window("Run Log", id: RunLogWindow.sceneId) {
            GatedContent(gate: LaunchGate.shared) {
                RunLogView(state: AppState.shared)
            }
        }
        .defaultSize(width: RunLogView.defaultWidth, height: RunLogView.defaultHeight)

        MenuBarExtra {
            GatedStatusMenu(gate: LaunchGate.shared)
        } label: {
            GatedStatusLabel(gate: LaunchGate.shared)
        }

        Settings {
            GatedContent(gate: LaunchGate.shared) {
                SettingsView()
            }
        }
    }
}
