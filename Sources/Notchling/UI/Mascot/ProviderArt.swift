//
//  The mark at the head of a session row, one per agent, drawn in the same idiom as the mascot: `#` is
//  a lit pixel, one flat colour, no shading.
//
//  Drawn rather than borrowed. Neither agent's own mark survives at this size — the rule that makes the
//  mascot legible, that no inked feature may be thinner than the diagonal of one pixel, is one no logo
//  obeys — and putting two companies' marks in a third-party widget is a question better not answered
//  here. So these evoke rather than imitate: a radiating spark, and the chevron of a shell prompt.
//
//  Fourteen pixels across, both of them, and that number is the design. Both are open — ink around
//  empty space rather than a blob — because a solid shape at this size reads as a dot, which is what
//  the row's state fill already is. Fourteen is the width a spoke needs before a burst reads as
//  radiating rather than as an insect, and it is what lets the two marks weigh the same: a bold seven
//  beside a fine fourteen does not. Each has to stay recognisable with the colour removed, because the
//  colour is already saying something else — what the session is doing.
//

enum ProviderArt {
    /// Claude Code: eight spokes and a dense core, radiating.
    static let spark = PixelBitmap(rows: [
        "......#.......",
        ".#....#....#..",
        "..#...#...#...",
        "...#..#..#....",
        "#...#.#.#...#.",
        ".##..####..##.",
        "##############",
        "..##########..",
        ".##..####..##.",
        "#...#.#.#...#.",
        "...#..#..#....",
        "..#...#...#...",
        ".#....#....#..",
        "......#.......",
    ])

    /// Codex: the chevron a shell prompts with.
    ///
    /// Three cells thick, which is what carries the same weight as the spokes opposite — any finer and
    /// it reads as the thinner of two marks rather than as one of a pair.
    ///
    /// Its ink fills all fourteen rows and is centred across them, because the renderer centres the
    /// *grid* and not what is drawn in it: ink that stopped a row short, or sat to one side, would put
    /// this mark at a different height and a different offset from the one beside it, down a column
    /// where nothing else moves. Narrower than the burst it pairs with, which is what a chevron is —
    /// but no shorter, and on the same centre.
    static let chevron = PixelBitmap(rows: [
        "...###........",
        "....###.......",
        ".....###......",
        "......###.....",
        ".......###....",
        "........###...",
        ".........###..",
        ".........###..",
        "........###...",
        ".......###....",
        "......###.....",
        ".....###......",
        "....###.......",
        "...###........",
    ])

    static func mark(for provider: Provider) -> PixelBitmap {
        switch provider {
        case .claude: spark
        case .codex: chevron
        }
    }
}
