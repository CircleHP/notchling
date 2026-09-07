//
//  The mark at the head of a session row, one per agent, drawn in the same idiom as the mascot: `#` is
//  a lit pixel, one flat colour, no shading.
//
//  Drawn rather than borrowed. Neither agent's own mark survives at this size — the rule that makes the
//  mascot legible, that no inked feature may be thinner than the diagonal of one pixel, is one no logo
//  obeys — and putting two companies' marks in a third-party widget is a question better not answered
//  here. So these evoke rather than imitate: a radiating spark, and the chevron of a shell prompt.
//
//  The constraint that decides both: at seven pixels across, a mark can carry a silhouette and nothing
//  more. Every solid shape read as the status dot it replaced, which is why both of these are open —
//  ink around empty space, not a blob. Each must stay recognisable with the colour removed, because the
//  colour is already saying something else: what the session is doing.
//

enum ProviderArt {
    /// Claude Code: four arms and a core, radiating.
    static let spark = PixelBitmap(rows: [
        "#..#..#",
        "##.#.##",
        ".#####.",
        "#######",
        ".#####.",
        "##.#.##",
        "#..#..#",
    ])

    /// Codex: the chevron a shell prompts with.
    static let chevron = PixelBitmap(rows: [
        "##.....",
        ".##....",
        "..##...",
        "...##..",
        "..##...",
        ".##....",
        "##.....",
    ])

    static func mark(for provider: Provider) -> PixelBitmap {
        switch provider {
        case .claude: spark
        case .codex: chevron
        }
    }
}
