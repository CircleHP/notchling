//
//  Decides which screens the widget lives on and what state it is in on each of them.
//
//  Presentation policy is shared and presenters are dumb: a peek is a property of a session changing
//  state, not of a display, so it fires everywhere at once. Hover is the exception — that belongs to
//  the one screen the pointer is actually on.
//

import AppKit
import SwiftUI

@MainActor
final class WidgetController {
    private let store: SessionStore
    private let onQuit: () -> Void
    private let onRestart: () -> Void
    private let displayMode: DisplayMode

    private var presenters: [WidgetPresenter] = []
    private var peekUntil: Date = .distantPast
    /// Which screen the current peek is on. Captured when the peek starts rather than read live, so
    /// the panel does not hop displays halfway through because the pointer moved.
    private var peekDisplayID: CGDirectDisplayID?
    private var peekTask: Task<Void, Never>?
    /// The screen whose widget the pointer was last on, so the leave-grace lands there.
    private var lastHoveredDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

    init(
        store: SessionStore,
        displayMode: DisplayMode = .current,
        onQuit: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) {
        self.store = store
        self.displayMode = displayMode
        self.onQuit = onQuit
        self.onRestart = onRestart
    }

    func start() {
        // The set of screens, their scale factors and their menu bar heights are all mutable at
        // runtime — docking, undocking, closing the lid, or dragging the primary display around in
        // System Settings all land here. Nothing about the widget's geometry may be computed once.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }

        syncPresenters()
        reconcile()
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        peekTask?.cancel()
        for presenter in presenters { presenter.teardown() }
        presenters = []
    }

    /// Briefly show the full panel, so a state change is legible without going to hover for it.
    ///
    /// On one screen. Opening it everywhere at once was the first thing anyone complained about with a
    /// second display attached: one session needing attention is one event, and showing it twice reads
    /// as two.
    func peek(for duration: TimeInterval, on displayID: CGDirectDisplayID? = nil) {
        if peekUntil <= .now { peekDisplayID = nil }
        peekUntil = max(peekUntil, Date.now.addingTimeInterval(duration))
        if peekDisplayID == nil { peekDisplayID = displayID ?? peekTargetID() }
        reconcile()

        peekTask?.cancel()
        peekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let remaining = self.peekUntil.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            self.reconcile()
        }
    }

    func reconcile() {
        // `active` mode tracks the pointer, and the pointer moves without telling us. Re-resolving the
        // target set on every reconcile is cheap and keeps it roughly current; the sweep timer bounds
        // how stale it can get to a couple of seconds.
        if displayMode == .active {
            syncPresenters()
        }

        let peeking = peekUntil > .now
        let hovered = presenters.first { $0.isHovering }

        for presenter in presenters {
            presenter.apply(
                Self.presentation(
                    for: presenter.displayID,
                    hoveredDisplayID: hovered?.displayID,
                    peekDisplayID: peeking ? peekDisplayID : nil
                )
            )
        }
    }

    /// The whole policy, as a function of three facts. Pure so both of its rules can be asserted without a
    /// window: a peek opens on exactly one screen, and hover outranks a peek rather than competing with
    /// it.
    nonisolated static func presentation(
        for displayID: CGDirectDisplayID,
        hoveredDisplayID: CGDirectDisplayID?,
        peekDisplayID: CGDirectDisplayID?
    ) -> WidgetPresentation {
        if let hoveredDisplayID {
            // Hover wins over a peek: the pointer is a stronger statement about where someone is
            // looking than our guess was.
            return displayID == hoveredDisplayID ? .expanded : .compact
        }
        if let peekDisplayID, displayID == peekDisplayID {
            return .expanded
        }
        return .compact
    }

    /// Where to put a peek: the screen the pointer is on, because that is the best evidence available
    /// about which screen is being looked at. Falls back to the notched screen, then to any screen.
    private func peekTargetID() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        if let underPointer = presenters.first(where: { presenter in
            guard let screen = NSScreen.screens.first(where: { $0.displayID == presenter.displayID })
            else { return false }
            return NSMouseInRect(mouse, screen.frame, false)
        }) {
            return underPointer.displayID
        }
        return (presenters.first(where: \.isPhysicalNotch) ?? presenters.first)?.displayID
    }

    // MARK: - Screens

    private func screensChanged() {
        syncPresenters()
        for presenter in presenters { presenter.refreshMetrics() }
        reconcile()
    }

    private func syncPresenters() {
        let wanted = targetScreens()
        let wantedIDs = Set(wanted.map(\.displayID))

        for presenter in presenters where !wantedIDs.contains(presenter.displayID) {
            presenter.teardown()
        }
        presenters.removeAll { !wantedIDs.contains($0.displayID) }

        for screen in wanted where !presenters.contains(where: { $0.displayID == screen.displayID }) {
            presenters.append(
                WidgetPresenter(
                    screen: screen,
                    store: store,
                    onHoverChange: { [weak self] in self?.hoverChanged() },
                    onFocus: { TerminalFocus.focus($0) },
                    onQuit: onQuit,
                    onRestart: onRestart
                )
            )
        }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch displayMode {
        case .all:
            return screens
        case .builtin:
            // Deliberately empty rather than falling back to another screen: someone who asked for
            // built-in only and then closed the lid wants it gone, not relocated.
            return screens.filter(\.hasNotch)
        case .active:
            let mouse = NSEvent.mouseLocation
            let underPointer = screens.first { NSMouseInRect(mouse, $0.frame, false) }
            return [underPointer ?? NSScreen.main ?? screens.first].compactMap { $0 }
        }
    }

    private func hoverChanged() {
        // Leaving should not snap the panel shut mid-gesture; a short grace period makes moving between
        // rows and off the panel edge forgiving.
        if let hovered = presenters.first(where: { $0.isHovering }) {
            lastHoveredDisplayID = hovered.displayID
            reconcile()
        } else {
            // Explicitly on the screen being left. Without this the grace goes to whichever screen the
            // pointer has wandered onto, so moving off the widget on one display flashes the panel open
            // on the other one for a third of a second.
            peek(for: 0.35, on: lastHoveredDisplayID)
        }
    }
}
