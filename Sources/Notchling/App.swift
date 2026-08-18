//
//  Plain AppKit rather than a SwiftUI `App`: every SwiftUI scene type wants to create a window, and
//  this app's entire interface lives in borderless panels it owns itself (see `WidgetPanel`).
//

import AppKit

@main
enum NotchlingMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        // NSApplication holds its delegate weakly.
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static var delegate: AppDelegate?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Covers the two things the vnode watches cannot see: an in-place rewrite of a registry file,
    /// and a session whose process died without a `SessionEnd`.
    private static let sweepInterval: TimeInterval = 2

    private let store = SessionStore()
    private let cues = SoundCues()
    private var spool: HookSpoolWatcher?
    private var registry: SessionRegistryReader?
    private var widget: WidgetController?
    private var sweep: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAlreadyRunning() else {
            NSApp.terminate(nil)
            return
        }

        loadApplicationIcon()
        SessionMetricsReader.pruneStaleFiles()

        let widget = WidgetController(store: store, onQuit: { NSApp.terminate(nil) })
        self.widget = widget

        store.onChange = { [weak widget] in
            widget?.reconcile()
        }

        store.onTransition = { [weak self] session, previous, newState in
            guard let self else { return }

            if !newState.isNotifiable {
                self.cues.clearDedupe(for: session.sessionID)
            }
            self.cues.play(for: session, newState: newState)

            // The peek is the visual half of an alert, and the only half that says *which* session.
            switch newState {
            case .needsYou, .error:
                self.widget?.peek(for: 5)
            case .done:
                // Only surface a finish the user did not just watch happen.
                if previous == .working { self.widget?.peek(for: 3.5) }
            case .working, .idle:
                break
            }
        }

        store.onStalled = { [weak self] session in
            guard let self else { return }
            self.cues.playStalled(for: session)
            self.widget?.peek(for: 4)
        }

        let spool = HookSpoolWatcher { [weak store] events in
            guard let store else { return }
            for event in events { store.apply(event) }
        }
        self.spool = spool
        spool.start()

        let registry = SessionRegistryReader { [weak store] entries in
            store?.apply(registry: entries)
        }
        self.registry = registry
        registry.start()

        sweep = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.store.tick()
                self.registry?.scan()
            }
        }

        widget.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sweep?.invalidate()
        spool?.stop()
        registry?.stop()
        widget?.stop()
    }

    /// An accessory app has no Dock tile, so AppKit never loads its icon, and system UI that asks
    /// the *process* for its icon rather than LaunchServices gets a placeholder.
    private func loadApplicationIcon() {
        guard let url = Bundle.main.url(forResource: "Notchling", withExtension: "icns"),
              let image = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = image
    }

    /// A second copy would double every cue and fight over the spool directory.
    private func isAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return !others.isEmpty
    }
}
