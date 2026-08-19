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

    /// Written once above, before `run()`, and never read. `nonisolated(unsafe)` because that is
    /// what it is: one assignment on the main thread during launch, kept alive only because
    /// `NSApplication` holds its delegate weakly.
    nonisolated(unsafe) private static var delegate: AppDelegate?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Covers the two things the vnode watches cannot see: an in-place rewrite of a registry file,
    /// and a session whose process died without a `SessionEnd`.
    private static let sweepInterval: TimeInterval = 2

    /// How often the leftovers of ended sessions are cleared out. Doing it only at launch left a
    /// widget that runs for weeks — which is the intended way to run it — accumulating a file per
    /// session for ever.
    private static let pruneInterval: TimeInterval = 6 * 60 * 60

    private let store = SessionStore()
    private let cues = SoundCues()
    private var spool: HookSpoolWatcher?
    private var registry: SessionRegistryReader?
    private var widget: WidgetController?
    private var sweep: Timer?
    private var lastPrune = Date.now

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAlreadyRunning() else {
            NSApp.terminate(nil)
            return
        }

        loadApplicationIcon()
        pruneStaleFiles()

        let widget = WidgetController(
            store: store,
            onQuit: { NSApp.terminate(nil) },
            onRestart: { [weak self] in self?.restartIntoInstalledBuild() }
        )
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

        // Otherwise every session the widget has ever seen keeps an entry, and a recycled session id
        // would inherit the previous one's dedupe state.
        store.onRemoved = { [weak self] session in
            self?.cues.clearDedupe(for: session.sessionID)
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

                if Date.now.timeIntervalSince(self.lastPrune) > Self.pruneInterval {
                    self.pruneStaleFiles()
                }
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

    /// Relaunches from whichever copy is on disk now, which after an upgrade is not the one this
    /// process started from.
    ///
    /// The relaunch is handed to a detached shell that waits: `open` on a bundle whose app is still
    /// running activates the running copy rather than starting the new binary, so the new one can
    /// only be started once this one is gone. Under `brew services` launchd will have restarted it
    /// already by then, and `open` finds it running and does nothing — which is why a second copy
    /// cannot result, on top of the guard in `isAlreadyRunning`.
    private func restartIntoInstalledBuild() {
        let target = InstalledBuild.installedBundle(forRunningBundleAt: Bundle.main.bundleURL)
        let quoted = "'" + target.path.replacingOccurrences(of: "'", with: "'\\''") + "'"

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \(quoted)"]

        // Quitting before knowing the replacement is on its way would leave the user with no widget
        // and nothing to bring it back — their own click having removed it.
        do {
            try relaunch.run()
        } catch {
            Log.focus.error("could not start the replacement, staying up: \(error.localizedDescription, privacy: .public)")
            return
        }

        NSApp.terminate(nil)
    }

    /// The per-session files the status line leaves behind. Both readers only remove what is days
    /// old, so a live session's files are never in scope.
    private func pruneStaleFiles() {
        lastPrune = .now
        SessionMetricsReader.pruneStaleFiles()
        UsageReader.pruneStaleFiles()
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
