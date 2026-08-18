//
//  Presents the widget on exactly one screen: window lifecycle and transition choreography.
//
//  Sizing lives in `WidgetWindowGeometry` and curves in `WidgetTiming`; what is left here is *when*
//  things happen, which is the part with the timing hazards.
//

import AppKit
import SwiftUI

@MainActor
final class WidgetPresenter {
    /// Screens are identified by display id, not by `NSScreen`: those objects are replaced wholesale on
    /// reconfiguration, so a stored reference goes stale the moment someone plugs in a monitor.
    let displayID: CGDirectDisplayID

    private(set) var isHovering = false

    private let store: SessionStore
    private let onHoverChange: () -> Void
    private let onFocus: (Session) -> Void
    private let onQuit: () -> Void

    private var panel: WidgetPanel?
    private var state: WidgetViewState
    private var geometry = WidgetWindowGeometry()

    private var collapse: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    private var transition: Task<Void, Never>?

    init(
        screen: NSScreen,
        store: SessionStore,
        onHoverChange: @escaping () -> Void,
        onFocus: @escaping (Session) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.displayID = screen.displayID
        self.store = store
        self.onHoverChange = onHoverChange
        self.onFocus = onFocus
        self.onQuit = onQuit
        self.state = WidgetViewState(metrics: WidgetMetrics(screen: screen))
    }

    var isPhysicalNotch: Bool { state.metrics.isPhysicalNotch }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    // MARK: - Presentation

    func apply(_ presentation: WidgetPresentation) {
        guard presentation != state.presentation else { return }
        collapse?.cancel()

        if presentation == .hidden {
            hide()
            return
        }

        let hadPanel = panel != nil
        ensurePanel()
        // Before the content moves, not during. Once a state has been measured this is its final size, so
        // the whole transition runs inside a window that does not change.
        settle?.cancel()
        resizeWindow(for: presentation)

        // Set outside the animation: it drives the layout box, and must change in one step rather than
        // being interpolated.
        state.isTransitioning = true
        withAnimation(WidgetTiming.curve(to: presentation, hasPanel: hadPanel)) {
            state.presentation = presentation
        }
        scheduleTransitionEnd(to: presentation, hasPanel: hadPanel)
    }

    /// Re-measure after a display change: resolution, scale factor and menu bar height can all move under
    /// a screen that kept its id.
    func refreshMetrics() {
        guard let screen else { return }
        let fresh = WidgetMetrics(screen: screen)
        guard fresh != state.metrics else { return }
        state.metrics = fresh
        resizeWindow(for: state.presentation)
    }

    func teardown() {
        for task in [collapse, settle, transition] { task?.cancel() }
        collapse = nil
        settle = nil
        transition = nil

        geometry.forget()
        state.isTransitioning = false
        state.presentation = .hidden
        isHovering = false

        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func hide() {
        withAnimation(.smooth(duration: WidgetTiming.seconds(0.3))) { state.presentation = .hidden }
        isHovering = false
        collapse = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(WidgetTiming.milliseconds(320)))
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    /// Clearing `isTransitioning` is what brings the panel into the view tree, so it is animated and it
    /// waits for the shape to have finished moving.
    private func scheduleTransitionEnd(to presentation: WidgetPresentation, hasPanel: Bool) {
        transition?.cancel()
        let after = WidgetTiming.milliseconds(
            Int(WidgetTiming.duration(to: presentation, hasPanel: hasPanel) * 1000) + 40
        )
        transition = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(after))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: WidgetTiming.seconds(0.14))) {
                self.state.isTransitioning = false
            }
        }
    }

    // MARK: - Window

    private func ensurePanel() {
        // No screen with this id any more means the display was unplugged mid-flight.
        guard panel == nil, screen != nil else { return }

        let root = WidgetRoot(
            store: store,
            state: state,
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) },
            onContentGeometry: { [weak self] presentation, geometry in
                self?.contentGeometryChanged(presentation, geometry)
            },
            onFocus: onFocus,
            onQuit: onQuit
        )

        let panel = WidgetPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel

        resizeWindow(for: .compact)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Fade the window rather than the content: a hosting view's first composited frame occasionally
        // lands before layout, and a fade hides it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// The presentation comes from the view, not from `state`. A layout pass runs *after* the state flips,
    /// so reading `state.presentation` here filed the still-compact size under `expanded`, and the window
    /// then opened 95pt wide and clipped the panel for the whole transition.
    private func contentGeometryChanged(
        _ presentation: WidgetPresentation,
        _ content: WidgetContentGeometry
    ) {
        guard geometry.record(content, for: presentation) else { return }

        // Only ever *tighten* the window while compact. Shrinking it while the panel is open moves the
        // window out from under a stationary pointer, AppKit recomputes hover, and SwiftUI reports a
        // spurious hover-off — which collapses the panel, which re-expands on the hover that is still
        // there, which schedules another resize — an oscillation that continues for as long as the pointer
        // stays put. The size is still cached, so the next open sizes its window correctly before anything
        // moves.
        guard WidgetWindowGeometry.sizeKey(presentation) == .compact else {
            growPanelIfClipped(presentation)
            return
        }

        // Debounced, and longer than the transition: a spring keeps reporting sizes as it rings, and
        // every one of those is a size we must not resize to.
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(WidgetTiming.milliseconds(600)))
            guard !Task.isCancelled, let self,
                  WidgetWindowGeometry.sizeKey(self.state.presentation) == .compact else { return }
            self.resizeWindow(for: self.state.presentation)
        }
    }

    /// Grow the open panel's window when its content no longer fits, and never shrink it.
    ///
    /// The hover-loss loop described above is a property of *shrinking*: the window's top edge is pinned to
    /// the top of the screen and its width is computed rather than measured, so a taller frame strictly
    /// contains the one before it. A pointer inside the old rect is still inside the new one, so no hover
    /// can be lost and the loop cannot start.
    ///
    /// This exists because a panel opened while a fan-out is already running has more rows than the cached
    /// size was measured for. Without it those rows are simply clipped until the next open, which for
    /// subagents — the rows that appear and vanish fastest — would be most of the time.
    private func growPanelIfClipped(_ presentation: WidgetPresentation) {
        guard presentation == .expanded, !state.isTransitioning,
              let panel, let screen
        else { return }

        let target = geometry.frame(
            for: presentation,
            metrics: state.metrics,
            screenFrame: screen.frame
        )
        guard target.height > panel.frame.height else { return }
        resizeWindow(for: presentation)
    }

    private func resizeWindow(for presentation: WidgetPresentation) {
        guard let panel, let screen else { return }
        let frame = geometry.frame(
            for: presentation,
            metrics: state.metrics,
            screenFrame: screen.frame
        )
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
        // Lay out synchronously, before the caller starts animating. SwiftUI centres content in the width
        // it has been offered, and without this the first frames are laid out against the *old* width, so
        // the shape starts anchored to one edge and slides across. Measured once at 166pt off centre.
        panel.layoutIfNeeded()
    }

    private func hoverChanged(_ hovering: Bool) {
        guard hovering != isHovering, state.presentation != .hidden else { return }
        isHovering = hovering
        onHoverChange()
    }
}
