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
    private let preferences = PreferencesWindowController()
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
        // Never drawn — an accessory app does not get the menu bar — but it is what gives the settings
        // window its key equivalents. See `AppMenu`.
        AppMenu.install()
        pruneStaleFiles()

        let widget = WidgetController(
            store: store,
            onStop: { [weak self] in self?.stopWidget(nil) },
            onRestart: { [weak self] in self?.restartIntoInstalledBuild() },
            onSettings: { [weak self] in self?.preferences.show() }
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

    /// Reached from the Settings… menu item, which has no target and finds this down the responder
    /// chain — the app delegate is on it, the panel's own views are not.
    @objc func showPreferences(_ sender: Any?) {
        preferences.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sweep?.invalidate()
        spool?.stop()
        registry?.stop()
        widget?.stop()
    }

    /// Stops the widget for real.
    ///
    /// `NSApp.terminate` alone is a restart: both install methods register a launchd job with
    /// `KeepAlive` set, and launchd starts another copy within the second. So the job has to be booted
    /// out, and only the job that owns *this* process — a leftover job for the other install method is
    /// not ours to unload.
    ///
    /// `@objc` and reachable down the responder chain, because Command-Q has to mean this too.
    /// Wired to `NSApplication.terminate` it would be the same fake quit the power button used to be.
    @objc func stopWidget(_ sender: Any?) {
        Task { await self.confirmAndStop() }
    }

    /// Confirmed first, in an alert rather than on the row: there is no way back to a widget that is
    /// not running except a command, that command differs by how it was installed, and the panel has
    /// one line and cannot say it.
    private func confirmAndStop() async {
        // Off the main actor. Probing launchd is two subprocesses, and a launchd that is slow to
        // answer must not freeze a widget whose whole job is to be glanced at.
        let pid = ProcessInfo.processInfo.processIdentifier
        let job = await Task.detached { LaunchAgent.owner(ofPID: pid) }.value

        let alert = NSAlert()
        alert.messageText = "Stop Notchling?"
        alert.informativeText = if let job {
            "It will stop until you run \(job.restartCommand), and starts again when you next log in."
        } else {
            "The widget will stop until you open it again."
        }
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")

        // The panel sits at `.screenSaver` so it can be seen from a full-screen window, which puts it
        // above an alert's own level. During a modal session it also stops receiving the mouse-moved
        // events that would collapse it, so a panel tall enough to reach the alert would cover it and
        // swallow the clicks. One above the panel rather than collapsing it: this is the app's own
        // question about itself, and it should outrank the app's own chrome.
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

        // An accessory app's alert opens behind whatever is frontmost otherwise, and the click that
        // asked for it looks like it did nothing. Only undone if it was not already frontmost —
        // deactivating an app that was active sends the settings window behind everything.
        let wasActive = NSApp.isActive
        NSApp.activate()

        guard alert.runModal() == .alertFirstButtonReturn else {
            if !wasActive { NSApp.deactivate() }
            return
        }

        guard let job else {
            NSApp.terminate(nil)
            return
        }

        // Does not return in the ordinary case: launchd tears the job down, and this process is in it.
        guard !LaunchAgent.bootout(job) else { return }

        Log.diagnostics.error("could not boot out \(job.label, privacy: .public), staying up")
        let failure = NSAlert()
        failure.messageText = "Notchling could not be stopped"
        failure.informativeText = "launchd would not let go of it. Run \(job.stopCommand) instead."
        failure.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        failure.runModal()
        if !wasActive { NSApp.deactivate() }
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
