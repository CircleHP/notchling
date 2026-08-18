//
//  The chrome around the content: a black shape hanging from the top edge of the screen, holding the
//  compact mascot at rest and the session panel on hover.
//
//  On a notched display the compact content is pushed either side of the physical cutout, because
//  that cutout is opaque and anything drawn behind it is simply gone. On every other display there is
//  no cutout, so the same content sits together in a small pill.
//
//  The transition obeys four rules, and breaking any one of them is visible on screen. In short: the
//  layout box changes twice per transition rather than per frame, the mask animates as numbers into a
//  `Path`, the content moves with its own transitions, and the panel is absent from the tree throughout.
//
//

import SwiftUI

enum WidgetPresentation: Equatable {
    case hidden
    case compact
    case expanded
}

struct WidgetView: View {
    let store: SessionStore
    let metrics: WidgetMetrics
    let presentation: WidgetPresentation
    let isTransitioning: Bool
    let onHover: (Bool) -> Void
    let onContentGeometry: (WidgetPresentation, WidgetContentGeometry) -> Void
    let onFocus: (Session) -> Void
    let onQuit: () -> Void

    /// Measured from each layout itself. The container animates between these two numbers — animating a
    /// frame to `nil` resolves to the final size immediately and renders as a slide, not a growth.
    @State private var compactNatural: CGSize = .zero
    @State private var expandedNatural: CGSize = .zero
    /// The badge cluster's own width, which is the only part of the strip that changes size.
    @State private var trailingWidth: CGFloat = 0

    private var isExpanded: Bool { presentation == .expanded }

    // Compact radii are unscaled: the strip is a fixed size in the menu bar, so its corners are too.
    private var topRadius: CGFloat { isExpanded ? metrics.size(13) : CompactStrip.cornerInset }
    private var bottomRadius: CGFloat { isExpanded ? metrics.size(20) : 12 }

    /// How much room each side of a physical cutout gets, and it is deliberately **fixed**.
    ///
    /// Sizing it to the content meant the strip grew and shrank as state dots came and went, which is
    /// distracting in something you are not looking at directly. Worse, the row is centred while the
    /// *gap* in it has to line up with the cutout, so an asymmetric row slid sideways and pushed the
    /// mascot behind the camera. Reserving equal space on both sides fixes the width and makes the row
    /// symmetric by construction, so there is nothing left to correct.
    ///
    /// How far right of the screen centre the window's centre has to sit so the gap lands on the cutout.
    ///
    /// Zero while the two sides are the same width, which is the resting state — so a widget with nothing
    /// to report is simply centred, and only starts shifting as badges widen the right-hand side.
    private var gapOffset: CGFloat {
        guard metrics.isPhysicalNotch else { return 0 }
        return (max(trailingWidth, metrics.mascotWidth) - metrics.mascotWidth) / 2
    }

    /// With nothing to report there is no trailing content, and on a pill the gap that would have
    /// separated them leaves the mascot sitting off-centre.
    private var hasBadges: Bool {
        store.needsYouCount + store.errorCount + store.workingCount + store.doneCount > 0
    }

    var body: some View {
        content
            .fixedSize()
            .background {
                // Overdrawn, because the growth animation overshoots and a gap at the edge of the
                // shape reads as a rendering glitch rather than as a bounce.
                Rectangle()
                    .fill(Theme.chrome)
                    .padding(-60)
            }
            .mask {
                AnimatedWidgetShape(
                    width: target.width,
                    height: max(target.height, metrics.anchorSize.height),
                    topRadius: topRadius,
                    bottomRadius: bottomRadius
                )
            }
            // The whole shape is the hover target, including the dead space over a physical notch —
            // that is the part of it people actually aim at.
            .onHover(perform: onHover)
            // The window is sized from this. A window is opaque to clicks across its whole rect, even
            // where it draws nothing, so any slack is a dead zone over whatever is underneath.
            .onGeometryChange(for: CGSize.self, of: \.size) {
                onContentGeometry(presentation, WidgetContentGeometry(size: $0, gapOffset: gapOffset))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(presentation == .hidden ? 0 : 1)
            .offset(y: presentation == .hidden ? -metrics.anchorSize.height : 0)
            .environment(\.widgetMetrics, metrics)
    }

    /// Computed rather than measured: `ExpandedView` is a fixed width plus known padding. The first open
    /// has no measurement yet, and falling back to natural size there is what grows out of one side.
    private var expandedWidth: CGFloat {
        metrics.size(ExpandedView.panelWidth + 28) + topRadius * 2
    }

    /// The size the *mask* should be right now. Animated, per frame, as four numbers.
    private var target: CGSize {
        if isExpanded {
            // Height is the one value that genuinely depends on how many sessions there are, so it is
            // measured; the expanded natural height until then.
            return CGSize(width: expandedWidth, height: max(expandedNatural.height, 1))
        }
        return compactNatural
    }

    /// Changes twice per transition and never in between. Everything the animation does happens inside
    /// this box without disturbing it, which is what keeps SwiftUI from re-laying-out the panel per frame.
    private var layoutSize: CGSize {
        guard isExpanded || isTransitioning else { return compactNatural }
        return CGSize(width: expandedWidth, height: max(expandedNatural.height, 1))
    }

    private var content: some View {
        ZStack(alignment: .top) {
            // Each layout measures itself at its natural size. `fixedSize` is what makes that stable:
            // the container's frame below constrains this subtree, and without it the measurement would
            // chase the constraint it is supposed to be producing.
            compact
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: \.size) { size in
                    if size.width > 1 { compactNatural = size }
                }

            expanded
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: \.size) { size in
                    if size.width > 1 { expandedNatural = size }
                }
        }
        .frame(
            width: layoutSize.width > 1 ? layoutSize.width : nil,
            height: layoutSize.height > 1 ? max(layoutSize.height, metrics.anchorSize.height) : nil,
            alignment: .top
        )
    }

    // MARK: - Compact

    /// Present in `hidden` as well as `compact`: hiding is done with opacity and an offset on the whole
    /// shape, so the two states must lay out identically — `WidgetPresenter` caches one size for both.
    private var compact: some View {
        HStack(spacing: 0) {
            if metrics.isPhysicalNotch {
                if !isExpanded {
                    // No reservation: the left of the cutout only ever holds the mascot, so it is exactly
                    // as wide as the mascot. Scales towards the cutout edge it sits against, so it reads
                    // as sliding back behind the notch rather than shrinking in place.
                    CompactLeadingView(store: store)
                        .transition(.widgetReveal(scaleX: 0, anchor: .trailing))
                }

                // Not padding: the cutout is a fixed physical width and the content has to clear it, or
                // the badges drift under the camera.
                Spacer().frame(width: metrics.anchorSize.width + CompactStrip.cutoutClearance)

                if !isExpanded {
                    // Sized by its contents, with the mascot's width as a floor so the resting strip is
                    // symmetric. Growing this side cannot move the mascot — see `gapOffset`.
                    CompactTrailingView(store: store)
                        .onGeometryChange(for: CGFloat.self, of: \.size.width) { trailingWidth = $0 }
                        .frame(minWidth: metrics.mascotWidth, alignment: .leading)
                        .transition(.widgetReveal(scaleX: 0, anchor: .leading))
                }
            } else {
                // No cutout to clear, so the pill is sized to its content and the mascot is centred in
                // it — which means no gap at all when there is nothing to put on the other side.
                if !isExpanded {
                    CompactLeadingView(store: store)
                        .transition(.widgetReveal(scaleX: 0, anchor: .trailing))

                    if hasBadges {
                        Spacer().frame(width: CompactStrip.pillGap)
                        CompactTrailingView(store: store)
                            .transition(.widgetReveal(scaleX: 0, anchor: .leading))
                    }
                }
            }
        }
        .padding(.horizontal, CompactStrip.outerPadding)
        .frame(height: metrics.anchorSize.height)
        .padding(.horizontal, topRadius)
    }

    // MARK: - Expanded

    /// Built only while open. It holds a per-second `TimelineView` for every working session, and
    /// leaving those in the tree at rest would undo the reason idle cost is near zero.
    /// Absent while the shape animates, which is what keeps the transition cheap.
    ///
    /// The exception is the first open of a session: the mask needs a height to grow to, and only the
    /// panel can supply it. Every subsequent open uses the cached value.
    private var showsPanel: Bool {
        guard isExpanded else { return false }
        return !isTransitioning || expandedNatural.height <= 1
    }

    @ViewBuilder
    private var expanded: some View {
        if showsPanel {
            ExpandedView(store: store, onFocus: onFocus, onQuit: onQuit)
                // Only reachable on the first-open path above, where the panel *is* present during a
                // transition. Rows carry buttons, `.onHover` and `.help` tooltips, and a geometry change
                // makes SwiftUI re-hit-test every one of them — a fifth of the animation's cost, for
                // hover states nobody can act on until it has stopped moving.
                .allowsHitTesting(!isTransitioning)
                // The panel hangs *below* the anchor, so on a notched screen it clears the cutout and
                // on any other screen it clears the menu bar.
                .padding(.top, metrics.anchorSize.height + metrics.size(6))
                .padding(.bottom, metrics.size(14))
                .padding(.horizontal, metrics.size(14) + topRadius)
                // Anchored at the top, because that is where it comes from: the panel unfolds out of
                // the notch instead of being uncovered in place.
                .transition(.widgetReveal(scaleY: 0.55, anchor: .top))
        }
    }
}

// MARK: - Transition

/// Scale on one axis, fade, and blur. The blur is what hides the fact that the content sits at its final
/// layout the whole time — without it the first frame is a sharp, full-size panel at low opacity.
private struct WidgetRevealModifier: ViewModifier, Animatable {
    /// 0 = fully collapsed and blurred, 1 = identity.
    var progress: CGFloat
    let scaleX: CGFloat
    let scaleY: CGFloat
    let anchor: UnitPoint

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                x: scaleX + (1 - scaleX) * progress,
                y: scaleY + (1 - scaleY) * progress,
                anchor: anchor
            )
            .blur(radius: (1 - progress) * 8)
            .opacity(Double(progress))
    }
}

extension AnyTransition {
    static func widgetReveal(
        scaleX: CGFloat = 1,
        scaleY: CGFloat = 1,
        anchor: UnitPoint
    ) -> AnyTransition {
        .modifier(
            active: WidgetRevealModifier(progress: 0, scaleX: scaleX, scaleY: scaleY, anchor: anchor),
            identity: WidgetRevealModifier(progress: 1, scaleX: scaleX, scaleY: scaleY, anchor: anchor)
        )
    }
}
