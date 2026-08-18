//
//  How big the widget is, and where it goes.
//
//  Two problems live here, and conflating them is how you get a blurry mascot. *Size* is a taste
//  preference (`Scale`, panel only — the compact strip lives in a menu bar and wants no more room).
//  *Crispness* is arithmetic: the mascot is a 1-bit bitmap on a 13x10 grid, so one grid pixel has to land
//  on a whole number of device pixels. 15pt is exactly 3 of them at 2x and 1.5 at 1x, and half a device
//  pixel is where pixel art dies. So the preference is snapped to what the screen can actually draw.
//

import AppKit
import SwiftUI

/// The user-facing size preference, for screens without a physical notch.
///
/// `defaults write local.notchling externalScale -string large`
///
/// A notched display is always `normal`: it is a small, high-density panel whose menu bar is a fixed
/// 32pt, and the widget there is already the right size. External monitors are the ones with space
/// going spare, and they are the only ones this applies to.
enum Scale: String, CaseIterable {
    case normal
    case large

    static let defaultsKey = "externalScale"

    /// Read once at launch. Changing it needs a relaunch, which is why it is not observable.
    static let current: Scale = {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)?.lowercased() ?? ""
        return Scale(rawValue: raw) ?? .normal
    }()

    /// How many grid pixels tall the mascot is drawn, in device pixels, given a screen's scale.
    ///
    /// `normal` is defined as "as close to 15pt as the screen can render crisply", which reproduces
    /// the built-in appearance exactly (2x, 15pt, 3 device pixels per grid pixel). `large` is derived
    /// from that integer rather than from 1.5x of the point size, because 1.5 x 3 is 4.5 and there is
    /// no such thing as four and a half pixels.
    func devicePixelsPerGridPixel(screenScale: CGFloat) -> Int {
        let normal = max(1, Int((Self.baseMascotHeight * screenScale / MascotArt.frameHeight).rounded()))
        switch self {
        case .normal:
            return normal
        // `max(normal + 1, ...)` keeps the two steps distinct. Without it a 1x screen reports 2 for
        // both and the preference silently does nothing.
        case .large:
            return max(normal + 1, Int((Double(normal) * 1.5).rounded(.down)))
        }
    }

    /// The reference height, in points, of the compact mascot at `normal` on a 2x display.
    static let baseMascotHeight: CGFloat = 15

}

/// The compact strip's horizontal layout.
///
/// On a notched display the left of the cutout only ever holds the mascot, so it is fixed at the mascot's
/// width. The right starts at the same width — symmetric, and that is how it looks with nothing to report —
/// and grows with its badges from there.
///
/// Growing one side would normally drag the mascot sideways, which is what made an earlier fixed-width
/// version necessary. It does not here, because the window is positioned by the strip's *gap* rather than
/// centred on the screen: solve for the window origin and the trailing width cancels out, leaving the
/// mascot's position a function of its own width and the cutout's alone. So the strip is as narrow as its
/// contents allow, only the badge side ever moves, and nothing has to be reserved against a worst case.
enum CompactStrip {
    static let outerPadding: CGFloat = 9
    static let cornerInset: CGFloat = 6

    /// Measured: without it the mascot ends half a point from the cutout edge, which is luck, not margin.
    static let cutoutClearance: CGFloat = 8

    /// The gap between mascot and badges on a screen with no cutout to clear.
    static let pillGap: CGFloat = 7
}

/// Which screens the widget appears on.
///
/// `defaults write local.notchling displayMode -string builtin`
enum DisplayMode: String {
    /// Only the screen with a physical notch. If there is none, nowhere.
    case builtin
    /// The screen the mouse is on.
    case active
    /// Every screen. The default, because a widget you cannot see is not doing its job.
    case all

    static let defaultsKey = "displayMode"

    static let current: DisplayMode = {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)?.lowercased() ?? ""
        return DisplayMode(rawValue: raw) ?? .all
    }()
}

/// Everything the widget needs to know about the one screen it is drawing on.
struct WidgetMetrics: Equatable {
    /// The physical notch on a built-in display, or the faux notch we invent for everything else.
    let anchorSize: CGSize
    /// True when `anchorSize` describes a real hole in the display.
    let isPhysicalNotch: Bool
    /// Height of the menu bar, which is how tall the compact widget is allowed to be.
    let menubarHeight: CGFloat
    /// The compact mascot, at the largest crisp size this screen can draw it. Never affected by the
    /// `scale` preference — see the note at the top of this file.
    let mascotHeight: CGFloat
    /// Applies to the expanded panel only.
    let multiplier: CGFloat
    /// Kept so any other pixel art in the panel can be snapped too — see `snapped(_:)`.
    let screenScale: CGFloat

    init(screen: NSScreen, scale: Scale = .current) {
        self.init(
            screenScale: screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2,
            notchSize: Self.forcePill ? nil : screen.notchSize,
            menubarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            scale: scale
        )
    }

    /// The arithmetic, separated from `NSScreen` so it can be tested against display configurations
    /// this machine does not have. Every value here has been wrong at least once.
    init(
        screenScale: CGFloat,
        notchSize: CGSize?,
        menubarHeight rawMenubarHeight: CGFloat,
        scale requestedScale: Scale
    ) {
        // A non-primary screen reports `visibleFrame == frame`, so it claims no menu bar at all. It
        // still draws one when it is the active screen, and a strip of height zero is not a widget.
        let menubarHeight = max(rawMenubarHeight, 24)
        // The preference is for external screens only — see `Scale`. Resolving it here rather than at
        // the call site means there is exactly one place the rule can be got wrong.
        let scale: Scale = notchSize == nil ? requestedScale : .normal

        // A physical cutout is a hard ceiling. Cap rather than letting layout squeeze the bitmap: a
        // squeezed one lands on fractional device pixels, measured once at 2.7 per grid row.
        func fit(_ perGridPixel: Int) -> Int {
            guard let notchSize else { return perGridPixel }
            let ceiling = max(1, Int(notchSize.height * screenScale / MascotArt.frameHeight))
            return min(perGridPixel, ceiling)
        }

        let compactPerGridPixel = fit(Scale.normal.devicePixelsPerGridPixel(screenScale: screenScale))
        self.mascotHeight = CGFloat(compactPerGridPixel) * MascotArt.frameHeight / screenScale
        self.menubarHeight = menubarHeight
        self.screenScale = screenScale
        self.multiplier = CGFloat(fit(scale.devicePixelsPerGridPixel(screenScale: screenScale)))
            / CGFloat(compactPerGridPixel)

        if let notchSize {
            self.anchorSize = notchSize
            self.isPhysicalNotch = true
        } else {
            // Zero width: with no cutout to clear, the compact content sits together as one pill
            // instead of being pushed apart. Height still matters — it is what the panel hangs below.
            self.anchorSize = CGSize(width: 0, height: menubarHeight)
            self.isPhysicalNotch = false
        }
    }

    /// How many device pixels one grid pixel of the compact mascot occupies. Must be a whole number,
    /// or the bitmap blurs.
    func compactDevicePixelsPerGridPixel(screenScale: CGFloat) -> CGFloat {
        mascotHeight * screenScale / MascotArt.frameHeight
    }

    /// `NOTCHLING_FORCE_PILL=1` makes every screen report as notchless.
    ///
    /// This exists because the notchless path is the one that cannot be tested on the machine that
    /// has a notch, and shipping a layout nobody has looked at is how the external-display support
    /// would have been broken on arrival.
    static let forcePill = ProcessInfo.processInfo.environment["NOTCHLING_FORCE_PILL"] == "1"

    var mascotWidth: CGFloat {
        mascotHeight * (MascotArt.frameWidth / MascotArt.frameHeight)
    }

    /// Scale a design constant. Every hard-coded point value in the widget goes through this.
    func size(_ points: CGFloat) -> CGFloat {
        points * multiplier
    }

    /// `size(_:)` for pixel art: rounded so one grid pixel covers a whole number of device pixels. The
    /// panel's header mark skipped this and came out soft at 1.2 device pixels per row.
    func snapped(_ points: CGFloat) -> CGFloat {
        let perGridPixel = max(1, (size(points) * screenScale / MascotArt.frameHeight).rounded())
        return perGridPixel * MascotArt.frameHeight / screenScale
    }

    func font(_ points: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size(points), weight: weight, design: design)
    }
}

// MARK: - Screen geometry

extension NSScreen {
    /// The cutout, or nil on a screen that does not have one.
    ///
    /// `auxiliaryTopLeftArea` is only non-nil on a notched display, which makes it a more honest test
    /// than `safeAreaInsets.top` — that is also non-zero on some external displays under
    /// "Show menu bar in full screen".
    var notchSize: CGSize? {
        guard let leftWidth = auxiliaryTopLeftArea?.width,
              let rightWidth = auxiliaryTopRightArea?.width,
              safeAreaInsets.top > 0
        else { return nil }
        return CGSize(width: frame.width - leftWidth - rightWidth, height: safeAreaInsets.top)
    }

    var hasNotch: Bool { notchSize != nil }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// Passed down rather than threaded through initialisers: nearly every view in the widget needs a
    /// size, including the ones four levels deep, and a per-screen value cannot be a global constant.
    @Entry var widgetMetrics: WidgetMetrics = .fallback
}

extension WidgetMetrics {
    /// Only used by SwiftUI previews and by any view rendered outside a presenter. Matches a 2x
    /// notchless screen at `normal`.
    static let fallback = WidgetMetrics(
        anchorSize: CGSize(width: 0, height: 24),
        isPhysicalNotch: false,
        menubarHeight: 24,
        mascotHeight: Scale.baseMascotHeight,
        multiplier: 1,
        screenScale: 2
    )

    private init(
        anchorSize: CGSize,
        isPhysicalNotch: Bool,
        menubarHeight: CGFloat,
        mascotHeight: CGFloat,
        multiplier: CGFloat,
        screenScale: CGFloat
    ) {
        self.anchorSize = anchorSize
        self.isPhysicalNotch = isPhysicalNotch
        self.menubarHeight = menubarHeight
        self.mascotHeight = mascotHeight
        self.multiplier = multiplier
        self.screenScale = screenScale
    }
}
