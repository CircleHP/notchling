//
//  Everything here is a discrete frame swap at a low rate, never an interpolated animation. The notch
//  panel is a large borderless transparent window, so cost is per composited frame and barely depends
//  on what is drawn: continuous 60fps measures 5–6% CPU whatever it draws, while these two-frame
//  swaps at 2fps measure 0.2–0.4%. Drawing something simpler does not help; drawing it less often is
//  the only thing that does.
//

import SwiftUI

enum MascotTiming {
    /// One step every half second — a two-frame cycle a second long. Slow enough to be nearly free,
    /// fast enough to read as walking rather than as a glitch.
    static let walkStep: Duration = .milliseconds(500)
    static let blink: Duration = .milliseconds(500)

    /// `NOTCHLING_FPS=n` overrides the frame rate, for trying other values without a rebuild.
    static func interval(_ base: Duration) -> Duration {
        guard let raw = ProcessInfo.processInfo.environment["NOTCHLING_FPS"],
              let fps = Double(raw), fps > 0, fps <= 60
        else { return base }
        return .milliseconds(Int((1000 / fps).rounded()))
    }
}

/// The critter standing still — an identity mark rather than a status readout.
///
/// The panel header uses this instead of `MascotView` so it stays put: a header showing the live state
/// would change face and colour while you are reading the rows underneath it, which is exactly where
/// the eye should not be drawn.
struct BrandMarkView: View {
    var height: CGFloat = 12

    var body: some View {
        PixelBitmapView(bitmap: MascotArt.standing, color: Theme.clay)
            .frame(width: height * (MascotArt.frameWidth / MascotArt.frameHeight), height: height)
    }
}

struct MascotView: View {
    let state: SessionState
    /// Height in points. Width follows the 13:10 frame aspect.
    var height: CGFloat = 16

    @State private var frame = 0
    @State private var driver: Task<Void, Never>?

    /// `NOTCHLING_STILL=1` freezes the mascot, for isolating its render cost.
    private static let motionEnabled = ProcessInfo.processInfo.environment["NOTCHLING_STILL"] != "1"

    /// How far each state dips on its off frame. These are animation amplitudes rather than colours, so
    /// they live here rather than in `Theme` — but they are named, because `0.32` and `0.72` sitting
    /// inline in a switch say nothing about why they differ.
    private static let alertDip = 0.32
    private static let doneDip = 0.72
    /// Resting is drawn once and left alone, at a fixed fraction of full ink.
    private static let idleOpacity = 0.45

    private var width: CGFloat {
        height * (MascotArt.frameWidth / MascotArt.frameHeight)
    }

    /// One grid pixel, in points. The walk's bob is exactly this — a sub-pixel bob reads as blur.
    private var onePixel: CGFloat {
        height / MascotArt.frameHeight
    }

    private var ink: Color {
        Theme.mascotColor(for: state)
    }

    var body: some View {
        content
            .frame(width: width, height: height)
            .animation(.smooth(duration: 0.3), value: state)
            .onAppear { retarget() }
            .onChange(of: state) { retarget() }
            .onDisappear { stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .working:
            PixelBitmapView(bitmap: MascotArt.walk[frame % MascotArt.walk.count], color: ink)
                .offset(y: frame % 2 == 1 ? -onePixel : 0)

        case .needsYou, .error:
            PixelBitmapView(bitmap: MascotArt.alert, color: ink)
                .opacity(frame % 2 == 1 ? Self.alertDip : 1)

        case .done:
            PixelBitmapView(bitmap: MascotArt.done, color: ink)
                .opacity(frame % 2 == 1 ? Self.doneDip : 1)

        case .idle:
            PixelBitmapView(bitmap: MascotArt.standing, color: ink)
                .opacity(Self.idleOpacity)
        }
    }

    // MARK: - Frame driver

    /// `idle` starts no driver at all: with nothing in flight the widget composites nothing, which is
    /// what makes an always-present notch mascot honest about its cost.
    private func retarget() {
        stop()
        guard Self.motionEnabled else { return }

        let interval: Duration
        switch state {
        case .working:
            interval = MascotTiming.interval(MascotTiming.walkStep)
        case .needsYou, .error, .done:
            interval = MascotTiming.interval(MascotTiming.blink)
        case .idle:
            return
        }

        driver = Task { @MainActor in await advance(every: interval) }
    }

    @MainActor
    private func advance(every interval: Duration) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            // Deliberately not inside `withAnimation`: a discrete swap is one composited frame, where
            // an interpolated one would be sixty.
            frame += 1
        }
    }

    private func stop() {
        driver?.cancel()
        driver = nil
        frame = 0
    }
}
