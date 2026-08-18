import AppKit
import Testing

@testable import Notchling

/// The two display configurations that matter, measured off real hardware:
/// the built-in panel, and a 2560x1440 external monitor that reports scale 1.0.
private let builtIn = (scale: CGFloat(2), notch: CGSize(width: 185, height: 32), menubar: CGFloat(33))
private let external1x = (scale: CGFloat(1), notch: CGSize?.none, menubar: CGFloat(24))

private func metrics(
    scale screenScale: CGFloat,
    notch: CGSize?,
    menubar: CGFloat,
    _ preference: Scale
) -> WidgetMetrics {
    WidgetMetrics(screenScale: screenScale, notchSize: notch, menubarHeight: menubar, scale: preference)
}

@Suite("WidgetMetrics — pixel-art crispness")
struct WidgetMetricsCrispnessTests {
    /// The whole reason this type exists. A 1-bit bitmap only looks right when one grid pixel covers a
    /// whole number of device pixels; at 1.5 it goes soft and the walk bob jitters instead of stepping.
    @Test(
        "one grid pixel is always a whole number of device pixels",
        arguments: [CGFloat(1), 1.5, 2, 3] as [CGFloat],
        [Scale.normal, .large]
    )
    func integerPixelScaling(screenScale: CGFloat, preference: Scale) {
        for notch in [nil, CGSize(width: 185, height: 32)] as [CGSize?] {
            let m = metrics(scale: screenScale, notch: notch, menubar: 24, preference)
            let perGridPixel = m.compactDevicePixelsPerGridPixel(screenScale: screenScale)
            #expect(
                perGridPixel == perGridPixel.rounded(),
                "scale \(screenScale), notch \(notch != nil), \(preference): \(perGridPixel) device px per grid px"
            )
            #expect(perGridPixel >= 1, "a grid pixel smaller than a device pixel cannot be drawn")
        }
    }

    @Test("the built-in display reproduces the original 15pt mascot exactly")
    func builtInMatchesOriginal() {
        let m = metrics(scale: builtIn.scale, notch: builtIn.notch, menubar: builtIn.menubar, .normal)
        #expect(m.mascotHeight == 15)
        #expect(m.compactDevicePixelsPerGridPixel(screenScale: 2) == 3)
    }

    /// 15pt would be 1.5 device pixels per grid pixel here, so it rounds up to a 20pt mascot. Bigger
    /// than the built-in, which is the right trade: crisp and slightly large beats correct and blurry.
    @Test("a 1x display rounds up to the nearest crisp size")
    func nonRetinaRoundsUp() {
        let m = metrics(scale: 1, notch: nil, menubar: external1x.menubar, .normal)
        #expect(m.mascotHeight == 20)
        #expect(m.compactDevicePixelsPerGridPixel(screenScale: 1) == 2)
    }
}

@Suite("WidgetMetrics — scale preference")
struct WidgetMetricsScaleTests {
    /// Reported by the first person to try it: scaling the compact strip "hurts a lot", because the
    /// strip lives in the menu bar and there is nothing in it that wants more room. Only the panel
    /// scales.
    @Test("the compact mascot ignores the scale preference", arguments: [CGFloat(1), 2])
    func compactIsScaleIndependent(screenScale: CGFloat) {
        let normal = metrics(scale: screenScale, notch: nil, menubar: 24, .normal)
        let large = metrics(scale: screenScale, notch: nil, menubar: 24, .large)
        #expect(normal.mascotHeight == large.mascotHeight)
        #expect(normal.anchorSize == large.anchorSize)
    }

    @Test("the panel grows with the preference", arguments: [CGFloat(1), 2])
    func panelScales(screenScale: CGFloat) {
        let normal = metrics(scale: screenScale, notch: nil, menubar: 24, .normal)
        let large = metrics(scale: screenScale, notch: nil, menubar: 24, .large)
        #expect(normal.multiplier == 1)
        #expect(large.multiplier > normal.multiplier)
        #expect(large.size(100) > normal.size(100))
    }

    /// The preference is for external monitors. A notched display is a fixed, small, high-density panel
    /// whose widget is already the right size, and the request was explicit: leave it alone.
    @Test("a notched screen ignores the preference entirely")
    func notchedIgnoresPreference() {
        let normal = metrics(scale: builtIn.scale, notch: builtIn.notch, menubar: builtIn.menubar, .normal)
        let large = metrics(scale: builtIn.scale, notch: builtIn.notch, menubar: builtIn.menubar, .large)
        #expect(normal.mascotHeight == large.mascotHeight)
        #expect(normal.multiplier == large.multiplier)
        #expect(large.multiplier == 1, "the built-in display never scales")
        #expect(large.size(380) == 380)
    }

    @Test("a notchless screen honours it")
    func notchlessHonoursPreference() {
        let normal = metrics(scale: 1, notch: nil, menubar: 24, .normal)
        let large = metrics(scale: 1, notch: nil, menubar: 24, .large)
        #expect(large.multiplier > normal.multiplier)
    }

    @Test("unknown and missing preferences fall back to normal rather than failing")
    func parsing() {
        #expect(Scale(rawValue: "large") == .large)
        #expect(Scale(rawValue: "huge") == nil, "huge was removed as redundant")
        #expect(Scale.defaultsKey == "externalScale", "the key names what it applies to")
        #expect(Scale(rawValue: "enormous") == nil)
        #expect(DisplayMode(rawValue: "builtin") == .builtin)
        #expect(DisplayMode(rawValue: "everywhere") == nil)
    }
}

@Suite("WidgetMetrics — geometry")
struct WidgetMetricsGeometryTests {
    /// The notch is a hole in the display: anything drawn taller than it either hangs a black bar
    /// below the cutout or gets squeezed onto fractional pixels. Neither is acceptable, so cap.
    @Test("the mascot is capped to fit inside a physical cutout")
    func cappedByCutout() {
        // A deliberately short cutout, to prove the cap engages rather than trusting real hardware.
        let m = metrics(scale: 2, notch: CGSize(width: 185, height: 12), menubar: 33, .large)
        #expect(m.mascotHeight <= 12)
        #expect(m.compactDevicePixelsPerGridPixel(screenScale: 2) == 2)
    }


    @Test("a notched screen anchors on the cutout, a notchless one on the menu bar")
    func anchor() {
        let notched = metrics(scale: 2, notch: builtIn.notch, menubar: builtIn.menubar, .normal)
        #expect(notched.isPhysicalNotch)
        #expect(notched.anchorSize == builtIn.notch)

        let pill = metrics(scale: 1, notch: nil, menubar: 24, .normal)
        #expect(!pill.isPhysicalNotch)
        // Zero width is what makes the compact content sit together instead of being pushed apart.
        #expect(pill.anchorSize == CGSize(width: 0, height: 24))
    }

    /// A secondary display reports `visibleFrame == frame`, so the naive menu bar height is zero and
    /// the pill would collapse to nothing.
    @Test("a screen claiming no menu bar still gets a usable strip height")
    func menubarFloor() {
        let m = metrics(scale: 1, notch: nil, menubar: 0, .normal)
        #expect(m.menubarHeight == 24)
        #expect(m.anchorSize.height == 24)
    }

    @Test("a broken scale factor does not produce a zero-sized widget")
    func zeroScaleFactor() {
        let m = WidgetMetrics(screenScale: 0, notchSize: nil, menubarHeight: 24, scale: .normal)
        #expect(m.mascotHeight > 0)
        #expect(m.multiplier > 0)
    }
}

@Suite("WidgetMetrics — snapped()")
struct WidgetMetricsSnappedTests {
    /// `size(_:)` is for fonts and padding, where a fractional point is fine. Pixel art is not fine at a
    /// fractional device pixel, and the panel's header mark was drawn with `size(12)` — 1.2 device pixels
    /// per grid row on a 1x display, which is visibly soft.
    @Test(
        "snapped heights land on whole device pixels per grid pixel",
        arguments: [CGFloat(1), 1.5, 2, 3] as [CGFloat], [Scale.normal, .large]
    )
    func snappedIsCrisp(screenScale: CGFloat, preference: Scale) {
        let m = WidgetMetrics(screenScale: screenScale, notchSize: nil, menubarHeight: 24, scale: preference)
        for points in [CGFloat(8), 12, 16, 24] {
            let perGridPixel = m.snapped(points) * screenScale / MascotArt.frameHeight
            #expect(
                abs(perGridPixel - perGridPixel.rounded()) < 0.0001,
                "\(points)pt at \(screenScale)x/\(preference): \(perGridPixel) device px per grid px"
            )
            #expect(perGridPixel >= 1)
        }
    }

    @Test("snapped stays close to the size it was asked for")
    func snappedIsCloseToRequested() {
        let m = WidgetMetrics(screenScale: 2, notchSize: nil, menubarHeight: 24, scale: .normal)
        // One grid pixel is 1.2pt at 12pt, so the worst rounding is half of that.
        #expect(abs(m.snapped(12) - 12) <= 2.5)
    }
}
