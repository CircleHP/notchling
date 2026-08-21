//
//  Decides when to look for a release, and owns the one click that installs it.
//
//  Nothing here runs until somebody has answered the question in the panel. `UpdatePreference.unset`
//  means no network at all, which is the state every existing install upgrades into — the choice is
//  keyed on never having been made rather than on install-versus-upgrade, so somebody who has been
//  running this for months gets asked exactly as a fresh install does.
//

import Foundation

/// What the install button is doing. `running` is the only one the panel can be in for long.
enum UpdateInstall: Equatable {
    case idle
    case running
    case failed(String)
}

/// Everything the panel needs to know about updating.
struct UpdateStatus: Equatable {
    /// False when Homebrew is not what installed this app, which withdraws the whole feature —
    /// including the question, since there would be nothing to do with a yes.
    var isSupported = false
    /// A newer release the tap is offering. nil whenever checks are off or were never allowed.
    var available: String?
    var install: UpdateInstall = .idle
}

@MainActor
final class UpdateCoordinator {
    private let store: SessionStore
    private let now: () -> Date
    /// nil when Homebrew is not what installed this app, which disables the whole feature — see
    /// `HomebrewInstall`. Resolved once: an app does not move while it is running.
    private let homebrew: HomebrewInstall?

    /// One check at a time. The sweep is every two seconds and a fetch takes rather longer than that.
    private var isChecking = false

    init(
        store: SessionStore,
        now: @escaping () -> Date = { Date.now },
        homebrew: HomebrewInstall? = HomebrewInstall.current()
    ) {
        self.store = store
        self.now = now
        self.homebrew = homebrew
        store.updates.isSupported = homebrew != nil
    }

    /// Whether the panel should offer any of this. A `make install` copy cannot be upgraded by
    /// Homebrew, so it is never offered the question either.
    var isSupported: Bool { homebrew != nil }

    // MARK: - Checking

    /// Called from the sweep. Cheap on every call but the one a day that is actually due.
    func tick() {
        guard homebrew != nil, !isChecking else { return }
        guard UpdatePreference.isDue(
            now: now(),
            lastCheckedDay: UpdatePreference.lastCheckedDay,
            choice: UpdatePreference.current
        ) else { return }

        // Recorded before the work rather than after: a check that fails should wait like any other,
        // not retry every two seconds against a network that is not there.
        UpdatePreference.lastCheckedDay = UpdatePreference.day(of: now())
        Task { _ = await check() }
    }

    /// A check somebody asked for, from the settings window. Runs whatever the schedule says and
    /// whatever the preference says: an explicit click is its own consent, for that one request.
    ///
    /// Returns the line the window shows, which is the only place the answer appears — the panel's row
    /// is captured when it opens and will not have noticed yet.
    func checkNow() async -> String {
        guard homebrew != nil else { return "Not a Homebrew install" }
        guard !isChecking else { return "Already checking" }
        UpdatePreference.lastCheckedDay = UpdatePreference.day(of: now())

        switch await check() {
        case .none: return "Could not reach the tap"
        case .some(.none): return "Up to date"
        case let .some(.some(version)): return "Version \(version) available"
        }
    }

    /// The check itself. The outer optional is "could we tell?" and the inner one is "is there
    /// anything?" — collapsing them is what let a failed check quietly erase a release it had already
    /// found and shown.
    private func check() async -> String??  {
        guard let homebrew else { return nil }
        guard let installed = InstalledBuild.version(
            ofBundleAt: InstalledBuild.installedBundle(forRunningBundleAt: Bundle.main.bundleURL)
        ) else { return nil }

        isChecking = true
        defer { isChecking = false }

        let outcome = await Task.detached { () -> Result<String?, Error> in
            do {
                return .success(try Updates.available(in: homebrew, installedVersion: installed))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case let .failure(error):
            // Left alone on purpose. A release found yesterday is still a release; going offline is
            // not evidence that it went away.
            Log.updates.error("could not check the tap: \(String(describing: error), privacy: .public)")
            return nil

        case let .success(found):
            store.updates.available = found
            // A stale failure must not outlive the attempt it belonged to, or the row keeps showing it
            // in place of a version that is newly on offer.
            store.updates.install = .idle
            if let found { Log.updates.info("\(found, privacy: .public) is available") }
            return .some(found)
        }
    }

    /// Answering the question in the panel. "No" is recorded as firmly as "yes" — an unanswered
    /// question is the only state that keeps asking.
    func setChecksEnabled(_ enabled: Bool) {
        UpdatePreference.set(enabled)
        if !enabled { store.updates.available = nil }
    }

    // MARK: - Installing

    /// Runs the upgrade and, if it worked, hands over to `onInstalled` — which restarts into it.
    ///
    /// Consent is not asked again here. The question in the panel is about *checking*, which is the
    /// only thing that touches the network without being told to; installing is an explicit click on a
    /// named version every time.
    func installAvailable(onInstalled: @escaping () -> Void) {
        guard let homebrew, store.updates.available != nil, store.updates.install != .running else { return }
        store.updates.install = .running

        Task { [weak self] in
            let thrown = await Task.detached { () -> (any Error)? in
                do {
                    try Updates.upgrade(in: homebrew)
                    return nil
                } catch {
                    return error
                }
            }.value

            guard let self else { return }
            guard let thrown else {
                self.store.updates.install = .idle
                self.store.updates.available = nil
                onInstalled()
                return
            }

            // The error itself, not a stand-in for it. Anything that is not an `Updates.Failure` —
            // `brew` missing, a permission denial on `run()` — used to be flattened into a synthetic
            // code before it reached here, and the log is the only evidence a failure leaves.
            Log.updates.error("upgrade failed: \(String(describing: thrown), privacy: .public)")
            let failure = thrown as? Updates.Failure ?? .commandFailed("brew upgrade", -1)
            self.store.updates.install = .failed(Self.message(for: failure))
        }
    }

    /// One line, because that is what the row has. The log has the rest, and every message says so
    /// except the one where waiting really is the whole answer.
    static func message(for failure: Updates.Failure) -> String {
        switch failure {
        case .homebrewBusy:
            "Homebrew is busy — try again shortly"
        case .tapNotFastForward:
            "Run brew upgrade notchling yourself"
        case .timedOut:
            "Timed out — see ~/.notchling/upgrade.log"
        case .commandFailed:
            "Failed — see ~/.notchling/upgrade.log"
        }
    }
}
