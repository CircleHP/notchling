import Foundation
import SwiftUI
import Testing

@testable import Notchling

@Suite("elapsedLabel")
struct ElapsedLabelTests {
    @Test("seconds, then minutes, then hours, with padded remainders")
    func formats() {
        #expect(TimeInterval(0).elapsedLabel == "0s")
        #expect(TimeInterval(4).elapsedLabel == "4s")
        #expect(TimeInterval(59).elapsedLabel == "59s")
        #expect(TimeInterval(60).elapsedLabel == "1m00s")
        #expect(TimeInterval(72).elapsedLabel == "1m12s")
        #expect(TimeInterval(3599).elapsedLabel == "59m59s")
        #expect(TimeInterval(3600).elapsedLabel == "1h00m")
        #expect(TimeInterval(2 * 3600 + 5 * 60).elapsedLabel == "2h05m")
        #expect(TimeInterval(25 * 3600).elapsedLabel == "25h00m")
    }

    @Test("negative intervals clamp to zero rather than printing nonsense")
    func negative() {
        #expect(TimeInterval(-5).elapsedLabel == "0s")
    }

    @Test("fractional seconds truncate")
    func fractional() {
        #expect(TimeInterval(1.9).elapsedLabel == "1s")
    }
}

@Suite("Theme")
struct ThemeTests {
    /// One palette, so the dot beside a row can never disagree with the face in the notch. They drifted
    /// once — clay in the notch, amber in the panel — which is why `mascotColor` delegates.
    @Test("the mascot and the row dots share one palette")
    func mascotMatchesRowDots() {
        for state in [SessionState.needsYou, .error, .done, .working] {
            #expect(Theme.mascotColor(for: state) == Theme.color(for: state), "\(state)")
        }
    }

    /// `needsYou` and `error` share the frown, so they share red. They are still separable in the
    /// panel — by the label on the row, and by the ring the dot draws for both of them — just not by
    /// hue, which the notch has no room to spend on the distinction anyway.
    @Test("both attention states are red")
    func attentionStatesShareRed() {
        #expect(Theme.color(for: .needsYou) == Theme.red)
        #expect(Theme.color(for: .error) == Theme.red)
        #expect(Theme.label(for: .needsYou) != Theme.label(for: .error))
    }

    @Test("idle is the one deliberate difference")
    func idleDiffers() {
        // The row dot dims to grey; the mascot stays clay and the view lowers its opacity, so the
        // critter reads as itself rather than as a grey blob.
        #expect(Theme.mascotColor(for: .idle) == Theme.clay)
        #expect(Theme.color(for: .idle) == Theme.dim)
    }

    /// Three hues, not four: red is shared by the two attention states deliberately. What must stay
    /// separable is "wants you" from "getting on with it" from "finished".
    @Test("the states that mean different things look different")
    func distinctColours() {
        let colours = [Theme.color(for: .working), Theme.color(for: .needsYou), Theme.color(for: .done)]
        #expect(Set(colours).count == 3)
        #expect(Theme.color(for: .idle) != Theme.color(for: .working))
    }

    /// The palette has exactly one home. This is a source-level check because it is the only kind that
    /// works: a colour inlined in a view compiles, renders, looks approximately right, and quietly drifts
    /// from the one it was supposed to match. Eight of them had.
    @Test("no view constructs its own colour")
    func coloursComeFromTheme() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Notchling/UI")

        let files = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Theme.swift" } ?? []
        #expect(!files.isEmpty, "found no UI sources to check")

        // Anything that names a colour rather than asking Theme for one. Matched on identifier
        // boundaries, so `Theme.mascotColor(...)` is not mistaken for `Color(...)`.
        let banned = ["Color(", "Color.", ".white", ".black", ".gray"]

        func mentions(_ token: String, in line: String) -> Bool {
            var searchRange = line.startIndex ..< line.endIndex
            while let found = line.range(of: token, range: searchRange) {
                let precededByIdentifier = found.lowerBound > line.startIndex
                    && (line[line.index(before: found.lowerBound)].isLetter
                        || line[line.index(before: found.lowerBound)].isNumber
                        || line[line.index(before: found.lowerBound)] == "_")
                if !precededByIdentifier { return true }
                searchRange = found.upperBound ..< line.endIndex
            }
            return false
        }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let code = text.range(of: "//").map { String(text[text.startIndex ..< $0.lowerBound]) } ?? text
                // `.whitespaces` and friends are character sets, not colours.
                guard !code.contains("whitespace") else { continue }
                for token in banned where mentions(token, in: code) {
                    Issue.record("\(file.lastPathComponent):\(number + 1) names a colour (\(token)) — use Theme")
                }
            }
        }
    }

    /// The neutral ramp only works if it stays ordered. Swapping two of these compiles and renders, and
    /// the result is a panel where the labels shout and the session names whisper.
    @Test("the neutral ramp descends")
    func neutralRampIsOrdered() {
        func alpha(_ colour: Color) -> Double {
            Double(colour.resolve(in: EnvironmentValues()).opacity)
        }
        let ramp = [Theme.ink, Theme.inkSecondary, Theme.dim, Theme.hairline, Theme.surface]
        let alphas = ramp.map(alpha)
        #expect(alphas == alphas.sorted(by: >), "ramp out of order: \(alphas)")
        #expect(alpha(Theme.chrome) == 1, "the chrome has to be opaque — it stands in for a hole in the screen")
    }

    /// Both meters — plan limits and per-session context — go through one rule. Separate copies of the
    /// thresholds, one phrased as *used* and one as *remaining*, would disagree in a way review does not
    /// catch.
    @Test("one fill rule, two resting tints")
    func fillTintIsShared() {
        for resting in [Theme.clay, Theme.dim] {
            #expect(Theme.fillTint(usedFraction: 0.95, resting: resting) == Theme.red)
            #expect(Theme.fillTint(usedFraction: 0.90, resting: resting) == Theme.red)
            #expect(Theme.fillTint(usedFraction: 0.80, resting: resting) == Theme.amber)
            #expect(Theme.fillTint(usedFraction: 0.75, resting: resting) == Theme.amber)
            #expect(Theme.fillTint(usedFraction: 0.10, resting: resting) == resting)
        }
        // The difference between the two call sites is the resting tint and nothing else.
        #expect(Theme.fillTint(usedFraction: 0, resting: Theme.clay) != Theme.fillTint(usedFraction: 0, resting: Theme.dim))
        #expect(Theme.fillTint(usedFraction: 1, resting: Theme.clay) == Theme.fillTint(usedFraction: 1, resting: Theme.dim))
    }

    @Test("every state has a label, and none is empty")
    func labels() {
        for state in [SessionState.working, .needsYou, .done, .error, .idle] {
            #expect(!Theme.label(for: state).isEmpty)
        }
        #expect(Theme.label(for: .needsYou) == "needs you")
        #expect(Theme.label(for: .error) == "failed", "the user-facing word is not 'error'")
    }
}

@Suite("TerminalFocus.canFocusPrecisely")
struct TerminalFocusTests {
    private func session(focusURL: String? = nil, tty: String? = nil, term: String? = nil) -> Session {
        var s = Session(sessionID: "s")
        s.focusURL = focusURL
        s.tty = tty
        s.termProgram = term
        return s
    }

    @Test("a Warp deep link counts as precise")
    func warp() {
        #expect(TerminalFocus.canFocusPrecisely(session(focusURL: "warp://session/abc")))
    }

    @Test("a scriptable terminal with a known tty counts as precise",
          arguments: ["iTerm.app", "Apple_Terminal"])
    func scriptable(term: String) {
        #expect(TerminalFocus.canFocusPrecisely(session(tty: "/dev/ttys004", term: term)))
    }

    @Test("a scriptable terminal without a tty cannot be matched")
    func scriptableWithoutTTY() {
        #expect(!TerminalFocus.canFocusPrecisely(session(term: "iTerm.app")))
    }

    @Test("terminals with no session identity are app-level only",
          arguments: ["ghostty", "WezTerm", "vscode", "unknown-terminal"])
    func appLevelOnly(term: String) {
        // The tooltip tells the user this before they click, so it must not overpromise.
        #expect(!TerminalFocus.canFocusPrecisely(session(tty: "/dev/ttys004", term: term)))
    }

    @Test("nothing known at all is not precise")
    func nothingKnown() {
        #expect(!TerminalFocus.canFocusPrecisely(session()))
    }
}
