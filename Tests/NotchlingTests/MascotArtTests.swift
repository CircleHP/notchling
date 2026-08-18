import Foundation
import SwiftUI
import Testing

@testable import Notchling

@Suite("PixelBitmap")
struct PixelBitmapTests {
    @Test("decodes ASCII rows, treating anything that is not # as empty")
    func decode() {
        let bitmap = PixelBitmap(rows: [
            "#.#",
            ".#.",
        ])
        #expect(bitmap.width == 3)
        #expect(bitmap.height == 2)
        #expect(bitmap.pixels == [true, false, true, false, true, false])
    }

    @Test("width is the widest row, so ragged art cannot corrupt the grid")
    func raggedRows() {
        let bitmap = PixelBitmap(rows: ["#", "###"])
        #expect(bitmap.width == 3)
        #expect(bitmap.height == 2)
        #expect(bitmap.pixels.count == 6)
        #expect(bitmap.pixels[0] == true)
        #expect(bitmap.pixels[1] == false, "the short row is padded, not wrapped")
    }

    @Test("an empty bitmap is harmless")
    func empty() {
        let bitmap = PixelBitmap(rows: [])
        #expect(bitmap.width == 0)
        #expect(bitmap.height == 0)
        #expect(bitmap.pixels.isEmpty)
    }
}

@Suite("MascotArt")
struct MascotArtTests {
    private var everyFrame: [(String, PixelBitmap)] {
        [("standing", MascotArt.standing), ("walk0", MascotArt.walk[0]), ("walk1", MascotArt.walk[1]),
         ("alert", MascotArt.alert), ("done", MascotArt.done)]
    }

    @Test("every state is drawn on the same grid, so the notch layout never shifts")
    func uniformGrid() {
        for (name, bitmap) in everyFrame {
            #expect(bitmap.width == Int(MascotArt.frameWidth), "\(name) width")
            #expect(bitmap.height == Int(MascotArt.frameHeight), "\(name) height")
        }
    }

    @Test("no state is blank, and none is entirely filled")
    func plausibleInk() {
        for (name, bitmap) in everyFrame {
            let lit = bitmap.pixels.filter { $0 }.count
            #expect(lit > 20, "\(name) has almost no ink")
            #expect(lit < bitmap.pixels.count, "\(name) has no negative space, so no face")
        }
    }

    @Test("the walk frames differ only in their last row")
    func walkDiffersOnlyInTheFeet() {
        let a = MascotArt.walk[0], b = MascotArt.walk[1]
        let width = a.width
        let bodyRows = a.height - 1

        for y in 0 ..< bodyRows {
            let rowA = Array(a.pixels[(y * width) ..< ((y + 1) * width)])
            let rowB = Array(b.pixels[(y * width) ..< ((y + 1) * width)])
            #expect(rowA == rowB, "row \(y) should be shared body")
        }
        let lastA = Array(a.pixels[(bodyRows * width)...])
        let lastB = Array(b.pixels[(bodyRows * width)...])
        #expect(lastA != lastB, "the feet have to actually move")
    }

    /// The face is the state, so two states that look the same are a bug even if their colours differ:
    /// colour is the second channel, and it is the one that peripheral vision and colour blindness lose.
    @Test("every expression is distinguishable with the colour removed")
    func expressionsAreDistinct() {
        let faces = [
            ("straight", MascotArt.standing),
            ("sad", MascotArt.alert),
            ("smile", MascotArt.done),
        ]
        for (indexA, a) in faces.enumerated() {
            for b in faces[(indexA + 1)...] {
                #expect(a.1.pixels != b.1.pixels, "\(a.0) and \(b.0) draw the same pixels")
            }
        }
    }

    /// Idle and working wear the same face on purpose — the difference between them is that one of them
    /// moves, which is the cue peripheral vision picks up best anyway.
    @Test("resting and walking share a face, and differ only in the feet")
    func restingSharesTheWalkingFace() {
        // That the two walk frames differ is asserted by `walkDiffersOnlyInTheFeet`.
        #expect(MascotArt.standing.pixels == MascotArt.walk[0].pixels)
    }

    /// Row 5 is a blank cheek and row 8 is the body's bottom edge. Both were learned the hard way: with
    /// the eyes a row lower the mouth touches them and every expression becomes one blob, and with the
    /// mouth a row lower it breaks the outline and the critter grows two extra legs.
    @Test("the cheek row stays blank and the bottom edge stays whole")
    func structuralRowsAreIntact() {
        for (name, bitmap) in [("straight", MascotArt.standing), ("sad", MascotArt.alert),
                               ("smile", MascotArt.done)] {
            let width = bitmap.width
            let cheek = Array(bitmap.pixels[(5 * width) ..< (6 * width)])
            #expect(cheek.allSatisfy { $0 }, "\(name) punched a hole in the cheek row")

            let edge = Array(bitmap.pixels[(8 * width) ..< (9 * width)])
            let lit = edge.enumerated().filter(\.element).map(\.offset)
            #expect(lit == Array(2 ... 10), "\(name) broke the bottom edge: lit columns \(lit)")
        }
    }

    /// All three mouths are one 5-wide bar plus two end pixels, and the sad and smiling ones are exact
    /// vertical mirrors. Editing one without the other stops the pair reading as a matched set.
    @Test("the smile is the frown mirrored vertically")
    func smileMirrorsFrown() {
        // A mouthless critter, to tell mouth holes apart from the body's own outline.
        let plain = PixelBitmap(rows: [
            "...##...##...", "..#########..", ".###########.",
            "###..###..###", "###..###..###", "#############",
            "#############", ".###########.", "..#########..", "..##.....##..",
        ])

        func mouth(_ bitmap: PixelBitmap) -> Set<[Int]> {
            let width = bitmap.width
            var holes: Set<[Int]> = []
            for y in 6 ... 7 {
                for x in 0 ..< width {
                    let index = y * width + x
                    if plain.pixels[index], !bitmap.pixels[index] { holes.insert([y, x]) }
                }
            }
            return holes
        }

        let bar = Set((4 ... 8).map { [7, $0] })
        #expect(mouth(MascotArt.standing) == bar, "straight is the bar and nothing else")

        let sad = mouth(MascotArt.alert)
        let smile = mouth(MascotArt.done)
        #expect(sad.count == 7 && smile.count == 7, "a 5-wide bar plus two ends")
        #expect(Set(sad.map { [13 - $0[0], $0[1]] }) == smile, "the frown flipped is the smile")
    }

    @Test("both walk frames keep both feet on the ground")
    func bothFeetAlwaysPresent() {
        // Alternating a single foot also reads as walking, but leaves every other frame one-legged.
        for (name, bitmap) in [("walk0", MascotArt.walk[0]), ("walk1", MascotArt.walk[1])] {
            let width = bitmap.width
            let lastRow = Array(bitmap.pixels[((bitmap.height - 1) * width)...])
            let left = lastRow[0 ..< (width / 2)].filter { $0 }.count
            let right = lastRow[(width / 2 + 1)...].filter { $0 }.count
            #expect(left > 0, "\(name) lost its left foot")
            #expect(right > 0, "\(name) lost its right foot")
        }
    }




    @Test("make-icon.py draws the same critter as the app")
    func iconGeneratorMatchesTheApp() throws {
        // The icon and the notch must not drift. The generator keeps its own copy of the art, so this
        // compares the two character-for-character.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repoRoot.appendingPathComponent("make-icon.py"), encoding: .utf8)

        let rows = script
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""), trimmed.contains("#") || trimmed.contains(".") else { return nil }
                let body = trimmed.drop { $0 != "\"" }.dropFirst()
                guard let end = body.firstIndex(of: "\"") else { return nil }
                let candidate = String(body[body.startIndex ..< end])
                guard candidate.count == Int(MascotArt.frameWidth),
                      candidate.allSatisfy({ $0 == "#" || $0 == "." }) else { return nil }
                return candidate
            }

        #expect(rows.count == Int(MascotArt.frameHeight),
                "expected the standing critter in make-icon.py, found \(rows.count) rows")
        #expect(PixelBitmap(rows: rows).pixels == MascotArt.standing.pixels,
                "make-icon.py has drifted from MascotArt.standing")

        // The generator also keeps its own copy of the ink colour, in a different language, so that has
        // to be checked too — the art matching while the hue drifts would be a strange kind of correct.
        let clay = Theme.clay.resolve(in: EnvironmentValues())
        let expected = [clay.red, clay.green, clay.blue].map { Int(($0 * 255).rounded()) }
        #expect(script.contains("CLAY = (\(expected[0]), \(expected[1]), \(expected[2]), 255)"),
                "make-icon.py's CLAY has drifted from Theme.clay \(expected)")
    }
}
