//
//  The mascot, drawn as ASCII: `#` is a lit pixel, anything else is empty. One flat colour per state,
//  no shading — at notch size the silhouette is the whole design, and anything subtler than a solid
//  block just muddies it.
//
//  The critter is present in every state, and the state changes its *expression*: a level mouth while
//  it works, a frown when it needs you, a squint and a smile when it is done. The face is negative
//  space — holes punched in the body.
//
//  Row budget, which is the whole design:
//
//      0 ears · 1-2 dome · 3-4 eyes · 5 cheek (blank) · 6-7 mouth · 8 bottom edge · 9 feet
//
//  Row 5 must stay blank and row 8 must stay whole. With the eyes a row lower the mouth touches them and
//  every expression becomes one blob; with the mouth a row lower it breaks the outline and the critter
//  reads as having four legs. All three mouths are one 5-wide bar plus two end pixels: straight is the bar
//  on row 7, smile raises the ends into row 6, sad raises the bar and drops the ends.
//
//  Nothing inked may be narrower than two pixels, and every state must stay distinguishable with the
//  colour removed.
//

import SwiftUI

/// A decoded frame: `pixels[y * width + x]`.
struct PixelBitmap {
    let width: Int
    let height: Int
    let pixels: [Bool]

    init(rows: [String]) {
        width = rows.map(\.count).max() ?? 0
        height = rows.count

        var pixels = [Bool](repeating: false, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, character) in row.enumerated() where character == "#" {
                pixels[y * width + x] = true
            }
        }
        self.pixels = pixels
    }
}

// MARK: - The art

enum MascotArt {
    static let frameWidth: CGFloat = 13
    static let frameHeight: CGFloat = 10

    /// Ears and dome. Shared by every frame.
    private static let crown = [
        "...##...##...",
        "..#########..",
        ".###########.",
    ]

    /// Eyes, then the blank cheek row that keeps them off the mouth.
    private static let eyesOpen = [
        "###..###..###",
        "###..###..###",
        "#############",
    ]

    /// Half-height eyes. Squinting rather than shut, so the critter still reads as facing you.
    private static let eyesSquint = [
        "#############",
        "###..###..###",
        "#############",
    ]

    /// The mouth, rows 6 and 7. One bar and two end pixels; where they sit is the whole expression.
    private static let barRow = ".###.....###."
    private static let blankRow = "#############"

    private static let mouthStraight = [blankRow, barRow]
    /// Ends lifted into the row above the bar.
    private static let mouthSmile = ["###.#####.###", barRow]
    /// The mirror: bar lifted, ends dropped below it.
    private static let mouthSad = ["####.....####", ".##.#####.##."]

    /// The body's bottom edge. Structural — see the note at the top of this file.
    private static let bottomEdge = "..#########.."

    /// Feet are one row, not legs. Three rows of leg made the critter look like it was on stilts, and
    /// took a third of the grid away from the body.
    private static let feetWide = "..##.....##.."
    private static let feetNarrow = "...##...##..."

    private static func face(
        eyes: [String],
        mouth: [String],
        feet: String = feetWide
    ) -> PixelBitmap {
        PixelBitmap(rows: crown + eyes + mouth + [bottomEdge, feet])
    }

    /// Level mouth, eyes open. Used at rest, in the panel header, and as the app icon — `make-icon.py`
    /// renders this exact grid and `MascotArtTests` cross-checks the two.
    static let standing = face(eyes: eyesOpen, mouth: mouthStraight)

    /// The feet swing wide/narrow and `MascotView` lifts the second frame a pixel so the critter bobs.
    /// Both frames keep both feet: alternating a single foot leaves every other frame one-legged.
    static let walk = [
        face(eyes: eyesOpen, mouth: mouthStraight, feet: feetWide),
        face(eyes: eyesOpen, mouth: mouthStraight, feet: feetNarrow),
    ]

    /// Needs you, or failed. A frown reads at notch size where an exclamation mark did not — every `!`
    /// that fitted degraded into a slot cut through the critter.
    static let alert = face(eyes: eyesOpen, mouth: mouthSad)

    /// Finished. Squint plus a smile, so it is still the happy one with the colour taken away. Not a tick:
    /// a tick is a corner-to-corner diagonal, and punching one out severs the body into two lumps.
    static let done = face(eyes: eyesSquint, mouth: mouthSmile)
}

// MARK: - Rendering

/// Draws a `PixelBitmap` as one filled rect per lit pixel.
///
/// A `Canvas` rather than a view per pixel, and the pixels accumulate into a single `Path` so the
/// whole critter is one fill.
struct PixelBitmapView: View {
    let bitmap: PixelBitmap
    let color: Color

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard bitmap.width > 0, bitmap.height > 0 else { return }

            let unit = min(size.width / CGFloat(bitmap.width), size.height / CGFloat(bitmap.height))
            let originX = (size.width - unit * CGFloat(bitmap.width)) / 2
            let originY = (size.height - unit * CGFloat(bitmap.height)) / 2

            var path = Path()
            for y in 0 ..< bitmap.height {
                for x in 0 ..< bitmap.width where bitmap.pixels[y * bitmap.width + x] {
                    path.addRect(CGRect(
                        x: originX + CGFloat(x) * unit,
                        y: originY + CGFloat(y) * unit,
                        // A hair of overlap so neighbouring pixels never show a seam from
                        // fractional-point rounding.
                        width: unit + 0.25,
                        height: unit + 0.25
                    ))
                }
            }
            context.fill(path, with: .color(color))
        }
    }
}
