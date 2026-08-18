import AppKit
import Testing

@testable import Notchling

@Suite("WidgetController — presentation policy")
struct WidgetPresentationPolicyTests {
    private let builtInID: CGDirectDisplayID = 1
    private let externalID: CGDirectDisplayID = 3

    /// The first thing reported once a second display was attached: one session needing attention is
    /// one event, and opening the panel on every screen reads as several.
    @Test("a peek opens on exactly one screen")
    func peekIsSingleScreen() {
        #expect(WidgetController.presentation(
            for: externalID, hoveredDisplayID: nil, peekDisplayID: externalID) == .expanded)
        #expect(WidgetController.presentation(
            for: builtInID, hoveredDisplayID: nil, peekDisplayID: externalID) == .compact)
    }

    @Test("hover beats a peek, even a peek aimed somewhere else")
    func hoverWins() {
        #expect(WidgetController.presentation(
            for: builtInID, hoveredDisplayID: builtInID, peekDisplayID: externalID) == .expanded)
        #expect(WidgetController.presentation(
            for: externalID, hoveredDisplayID: builtInID, peekDisplayID: externalID) == .compact,
            "the peek's screen must close, or both are open at once again")
    }

    /// Compact, never hidden. A hidden widget has no window, so there is nothing to hover, and the
    /// panel becomes unsummonable — which is how the notchless path was broken to begin with.
    @Test("with nothing happening every screen is compact, not hidden")
    func restingState() {
        for id in [builtInID, externalID] {
            #expect(WidgetController.presentation(
                for: id, hoveredDisplayID: nil, peekDisplayID: nil) == .compact)
        }
    }
}

@Suite("WidgetWindowGeometry")
struct WidgetWindowGeometryTests {
    /// A window is opaque to mouse events across its whole rect, whatever it painted there, so the
    /// window has to be the size of the drawn shape. Sizes are measured from the content and cached,
    /// and the cache key is the subtle part: `hidden` and `compact` lay out identically, because hiding
    /// is done with opacity and an offset rather than by changing size.
    ///
    /// Keying on the presentation directly filed the first measurement under `hidden` — where nothing
    /// ever read it — and because the size then never changed again, no second event arrived to correct
    /// it. The window stayed at its generous fallback: a 540x60 dead zone hanging 27pt below the menu
    /// bar, swallowing clicks on whatever was underneath.
    @Test("hidden and compact share one measurement, expanded has its own")
    func sizeKeyGroupsHiddenWithCompact() {
        #expect(WidgetWindowGeometry.sizeKey(.hidden) == .compact)
        #expect(WidgetWindowGeometry.sizeKey(.compact) == .compact)
        #expect(WidgetWindowGeometry.sizeKey(.expanded) == .expanded)
    }
}

@Suite("WidgetTiming")
struct WidgetTimingTests {
    /// Opening and closing are not mirror images. A little overshoot on the way out reads as the panel
    /// dropping from the notch; the same overshoot on the way back in has nothing to drop into, so the
    /// shape shrinks past the compact strip and springs back out to it, which reads as the widget bouncing
    /// on its way closed. So closing has to be monotonic.
    @Test("opening springs, closing does not")
    func closingIsMonotonic() {
        let opening = WidgetTiming.curve(to: .expanded, hasPanel: true)
        let closing = WidgetTiming.curve(to: .compact, hasPanel: true)

        // Compared against `duration(to:hasPanel:)` rather than against literals, so shortening the
        // animation for CPU reasons does not require editing this test to keep saying the same thing.
        let openFor = WidgetTiming.duration(to: .expanded, hasPanel: true)
        let closeFor = WidgetTiming.duration(to: .compact, hasPanel: true)

        #expect(opening == .bouncy(duration: openFor, extraBounce: 0.05), "opening overshoots")
        #expect(closing == .smooth(duration: closeFor), "closing does not")
        #expect(opening != closing, "one curve for both directions is what produced the wobble")
        #expect(closeFor <= openFor, "closing should not linger longer than opening")
    }

    /// There is no previous size to travel from, so a spring has nothing to say — and this is the path a
    /// display being plugged in takes, where a bounce would look like a glitch rather than a flourish.
    @Test("the first appearance on a screen does not spring")
    func firstAppearanceIsSmooth() {
        for presentation in [WidgetPresentation.compact, .expanded] {
            #expect(
                WidgetTiming.curve(to: presentation, hasPanel: false)
                    == .smooth(duration: WidgetTiming.duration(to: presentation, hasPanel: false)),
                "\(presentation)"
            )
        }
    }
}

@Suite("WidgetWindowGeometry.frame")
struct WidgetWindowGeometryFrameTests {
    private let builtIn = WidgetMetrics(
        screenScale: 2,
        notchSize: CGSize(width: 185, height: 32),
        menubarHeight: 33,
        scale: .normal
    )
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// What has to line up is the *gap* in the strip, not the window on the screen. The strip's badge side
    /// grows with its contents, so a screen-centred window would drag the mascot sideways every time a
    /// state dot appeared.
    ///
    /// Solve for the window origin and the trailing width cancels out — which is the property that makes
    /// growing one side safe, and the reason the offset is carried with the measurement rather than being
    /// derived from a reservation.
    @Test("the mascot's position does not depend on how wide the badge side is")
    func mascotIsUnmovedByBadges() {
        // 15pt of chrome each side, then mascot, gap, badges.
        let chrome = CompactStrip.cornerInset + CompactStrip.outerPadding
        let gap = builtIn.anchorSize.width + CompactStrip.cutoutClearance

        func mascotLeftEdge(trailingWidth: CGFloat) -> CGFloat {
            let content = chrome * 2 + builtIn.mascotWidth + gap + trailingWidth
            let offset = (trailingWidth - builtIn.mascotWidth) / 2
            var geometry = WidgetWindowGeometry()
            _ = geometry.record(
                WidgetContentGeometry(size: CGSize(width: content, height: 32), gapOffset: offset),
                for: .compact
            )
            return geometry.frame(for: .compact, metrics: builtIn, screenFrame: screen).minX + chrome
        }

        // Resting (badge side floored to the mascot's width) through to three wide clusters.
        let resting = mascotLeftEdge(trailingWidth: builtIn.mascotWidth)
        for trailing in [builtIn.mascotWidth, 30, 56, 90] as [CGFloat] {
            #expect(abs(mascotLeftEdge(trailingWidth: trailing) - resting) <= 1.5,
                    "trailing \(trailing)pt moved the mascot")
        }

        // And with the sides equal, the window is simply centred.
        var geometry = WidgetWindowGeometry()
        let symmetric = chrome * 2 + builtIn.mascotWidth * 2 + gap
        _ = geometry.record(
            WidgetContentGeometry(size: CGSize(width: symmetric, height: 32), gapOffset: 0),
            for: .compact
        )
        let frame = geometry.frame(for: .compact, metrics: builtIn, screenFrame: screen)
        #expect(frame.midX == screen.midX, "a widget with nothing to report is centred")
        #expect(frame.maxY == screen.maxY)
    }

    /// Without a cutout there is nothing to line up with, so no offset is ever reported.
    @Test("a notchless screen keeps its window centred")
    func notchlessStaysCentred() {
        let pill = WidgetMetrics(screenScale: 1, notchSize: nil, menubarHeight: 24, scale: .normal)
        var geometry = WidgetWindowGeometry()
        _ = geometry.record(
            WidgetContentGeometry(size: CGSize(width: 80, height: 30), gapOffset: 0),
            for: .compact
        )
        let frame = geometry.frame(for: .compact, metrics: pill, screenFrame: screen)
        #expect(frame.midX == screen.midX)
    }

    /// The panel is centred whatever the strip does, so a compact offset must not leak into the open state.
    @Test("the expanded panel is centred, offset or not")
    func expandedIgnoresTheOffset() {
        var geometry = WidgetWindowGeometry()
        _ = geometry.record(
            WidgetContentGeometry(size: CGSize(width: 440, height: 300), gapOffset: 40),
            for: .expanded
        )
        let frame = geometry.frame(for: .expanded, metrics: builtIn, screenFrame: screen)
        #expect(frame.midX == screen.midX)
    }

    /// Until a state has been measured the window is generous, so the content can lay out at its natural
    /// size and be measured at all. It costs at most one frame of clipping, once per state.
    @Test("an unmeasured state falls back to a generous window, then tightens")
    func fallbackThenTighten() {
        var geometry = WidgetWindowGeometry()
        #expect(!geometry.has(.expanded))
        let generous = geometry.frame(for: .expanded, metrics: builtIn, screenFrame: screen)

        _ = geometry.record(WidgetContentGeometry(size: CGSize(width: 434, height: 250)), for: .expanded)
        #expect(geometry.has(.expanded))
        let tight = geometry.frame(for: .expanded, metrics: builtIn, screenFrame: screen)

        #expect(tight.height < generous.height, "the measured window should be smaller")
        #expect(tight.height == 250)
    }

    @Test("hidden reuses the compact measurement rather than falling back")
    func hiddenSharesCompact() {
        var geometry = WidgetWindowGeometry()
        _ = geometry.record(WidgetContentGeometry(size: CGSize(width: 293, height: 32)), for: .compact)
        #expect(geometry.has(.hidden))
        #expect(geometry.frame(for: .hidden, metrics: builtIn, screenFrame: screen)
                == geometry.frame(for: .compact, metrics: builtIn, screenFrame: screen))
    }

    @Test("a repeated measurement is not new information")
    func recordIsIdempotent() {
        var geometry = WidgetWindowGeometry()
        let size = WidgetContentGeometry(size: CGSize(width: 293, height: 32))
        let first = geometry.record(size, for: .compact)
        let second = geometry.record(size, for: .compact)
        let degenerate = geometry.record(WidgetContentGeometry(size: CGSize(width: 0, height: 0)), for: .compact)
        #expect(first)
        #expect(!second)
        #expect(!degenerate, "degenerate sizes are ignored")
    }

    @Test("forgetting drops back to the fallback")
    func forget() {
        var geometry = WidgetWindowGeometry()
        _ = geometry.record(WidgetContentGeometry(size: CGSize(width: 293, height: 32)), for: .compact)
        geometry.forget()
        #expect(!geometry.has(.compact))
    }

    /// The fallback must never exceed the screen it is on, whatever the scale preference asks for.
    @Test("the fallback is bounded by the screen")
    func fallbackFitsTheScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 320, height: 240)
        let large = WidgetMetrics(screenScale: 1, notchSize: nil, menubarHeight: 24, scale: .large)
        let geometry = WidgetWindowGeometry()
        for presentation in [WidgetPresentation.compact, .expanded] {
            let frame = geometry.frame(for: presentation, metrics: large, screenFrame: tiny)
            #expect(frame.width <= tiny.width, "\(presentation) wider than the screen")
            #expect(frame.height <= tiny.height, "\(presentation) taller than the screen")
        }
    }
}

@Suite("WidgetWindowGeometry — screen bounds")
struct WidgetWindowGeometryBoundsTests {
    /// A measured size is whatever the content asked for. With enough sessions the panel asks for more
    /// than the screen has, and an oversized window does not merely get cut off — it extends past the
    /// display edge, so those rows cannot be reached at all, and in a stacked arrangement it can bleed
    /// onto the neighbouring screen.
    @Test("a window never exceeds its screen, however large the content")
    func measuredSizeIsClamped() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let metrics = WidgetMetrics(screenScale: 2, notchSize: nil, menubarHeight: 24, scale: .normal)
        var geometry = WidgetWindowGeometry()
        _ = geometry.record(WidgetContentGeometry(size: CGSize(width: 4000, height: 3000)), for: .expanded)

        let frame = geometry.frame(for: .expanded, metrics: metrics, screenFrame: screen)
        #expect(frame.width <= screen.width)
        #expect(frame.height <= screen.height)
        #expect(frame.minY >= screen.minY, "the window must not hang below the display")
        #expect(frame.maxY == screen.maxY, "and still hangs from the top edge")
    }

    /// Rounding the width up to an even number must not be able to push it past the edge.
    @Test("rounding cannot breach the clamp")
    func roundingRespectsTheClamp() {
        let screen = CGRect(x: 0, y: 0, width: 401, height: 300)
        let metrics = WidgetMetrics(screenScale: 2, notchSize: nil, menubarHeight: 24, scale: .normal)
        var geometry = WidgetWindowGeometry()
        _ = geometry.record(WidgetContentGeometry(size: CGSize(width: 401, height: 299)), for: .expanded)
        let frame = geometry.frame(for: .expanded, metrics: metrics, screenFrame: screen)
        #expect(frame.width <= screen.width)
    }
}
