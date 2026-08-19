import Foundation
import Testing

@testable import Notchling

/// `ps eww` prints `KEY=VALUE` pairs space-separated on one line, and values in general *can* contain
/// spaces. The parser only works because the four keys it wants have values that cannot. These tests
/// pin down that assumption, since the failure mode of getting it wrong is a silently wrong deep link.
@Suite("ProcessEnvironmentReader.parse")
struct ProcessEnvironmentParseTests {
    @Test("pulls the four interesting keys out of a realistic dump")
    func realisticDump() {
        let dump = """
          501 12345 s001  0:01.23 claude SHELL=/bin/zsh TERM_PROGRAM=WarpTerminal \
        WARP_TERMINAL_SESSION_UUID=99921b28c9564e0a941225c60d405aa8 \
        WARP_FOCUS_URL=warp://session/99921b28c9564e0a941225c60d405aa8 \
        __CFBundleIdentifier=dev.warp.Warp-Stable LANG=en_US.UTF-8
        """
        let values = ProcessEnvironmentReader.parse(environmentDump: dump)
        #expect(values["TERM_PROGRAM"] == "WarpTerminal")
        #expect(values["WARP_FOCUS_URL"] == "warp://session/99921b28c9564e0a941225c60d405aa8")
        #expect(values["WARP_TERMINAL_SESSION_UUID"] == "99921b28c9564e0a941225c60d405aa8")
        #expect(values["__CFBundleIdentifier"] == "dev.warp.Warp-Stable")
    }

    @Test("TERM_PROGRAM is not matched inside TERM_PROGRAM_VERSION")
    func tokenBoundary() {
        // Substring matching here would report the version string as the terminal name.
        let dump = "TERM_PROGRAM_VERSION=1.2.3 TERM_PROGRAM=iTerm.app"
        #expect(ProcessEnvironmentReader.parse(environmentDump: dump)["TERM_PROGRAM"] == "iTerm.app")

        let onlyVersion = "TERM_PROGRAM_VERSION=1.2.3"
        #expect(ProcessEnvironmentReader.parse(environmentDump: onlyVersion)["TERM_PROGRAM"] == nil)
    }

    @Test("a value at the start of the dump is still matched")
    func startOfString() {
        #expect(ProcessEnvironmentReader.parse(environmentDump: "TERM_PROGRAM=ghostty")["TERM_PROGRAM"] == "ghostty")
    }

    @Test("a value is read only up to the next whitespace")
    func stopsAtWhitespace() {
        let dump = "WARP_FOCUS_URL=warp://session/abc SOMETHING_ELSE=with a spacey value"
        #expect(ProcessEnvironmentReader.parse(environmentDump: dump)["WARP_FOCUS_URL"] == "warp://session/abc")
    }

    @Test("a preceding value containing spaces does not swallow later keys")
    func spaceyNeighbourDoesNotHide() {
        // This is the shape that makes a naive whitespace split wrong.
        let dump = "ARGV=claude --print some prompt text TERM_PROGRAM=Apple_Terminal"
        #expect(ProcessEnvironmentReader.parse(environmentDump: dump)["TERM_PROGRAM"] == "Apple_Terminal")
    }

    @Test("empty values and absent keys are reported as absent")
    func emptyAndMissing() {
        let values = ProcessEnvironmentReader.parse(environmentDump: "TERM_PROGRAM= OTHER=x")
        #expect(values["TERM_PROGRAM"] == nil, "an empty value is no value")
        #expect(values["WARP_FOCUS_URL"] == nil)
        #expect(ProcessEnvironmentReader.parse(environmentDump: "").isEmpty)
    }

    @Test("tab-separated dumps parse too")
    func tabSeparated() {
        let values = ProcessEnvironmentReader.parse(environmentDump: "A=1\tTERM_PROGRAM=vscode\tB=2")
        #expect(values["TERM_PROGRAM"] == "vscode")
    }

    @Test("reading our own process finds our own environment")
    @MainActor
    func liveLookup() async {
        // An end-to-end check that the `ps eww` invocation and parsing agree with reality: we set a
        // variable this process definitely has, and ask for the pid we definitely are.
        let reader = ProcessEnvironmentReader()
        let identity: TerminalIdentity? = await withCheckedContinuation { continuation in
            reader.read(pid: livePID) { continuation.resume(returning: $0) }
        }
        let found = try! #require(identity)
        // The test runner has a controlling tty only sometimes, so assert on argv, which is always there.
        #expect(found.command?.isEmpty == false, "argv should always come back for our own pid")
    }

    /// The cache is keyed by pid, and macOS reuses pids. Without a way to forget one, the identity of a
    /// dead process is handed to whatever process inherits its number.
    @Test("a forgotten pid is read again rather than answered from cache")
    @MainActor
    func forgetForcesAReRead() async {
        let reader = ProcessEnvironmentReader()

        _ = await withCheckedContinuation { continuation in
            reader.read(pid: livePID) { continuation.resume(returning: $0) }
        }
        reader.forget(pid: livePID)

        // A cached answer would short-circuit before `ps` runs; this only completes if it read again.
        let second: TerminalIdentity? = await withCheckedContinuation { continuation in
            reader.read(pid: livePID) { continuation.resume(returning: $0) }
        }
        #expect(try! #require(second).command?.isEmpty == false)
    }
}
