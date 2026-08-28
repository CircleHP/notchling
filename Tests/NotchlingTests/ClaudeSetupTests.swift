import Foundation
import Testing

@testable import Notchling

/// The environment the settings window hands to `notchling-hooks`.
///
/// Worth its own tests because getting it wrong is invisible in a terminal and total in the app: the
/// script resolves the hook binary with `command -v` and Homebrew's prefix by running `brew`, and a
/// launchd job has neither on its `PATH`. The rows then report "Not wired" and hide the button that
/// would wire it — which shipped in 1.2.2.
@Suite("ClaudeSetup — the search path")
struct ClaudeSetupSearchPathTests {
    private let minimal = "/usr/bin:/bin:/usr/sbin:/sbin"

    @Test("the prefix this bundle came from is searched first")
    func prefixLeads() {
        let path = ClaudeSetup.searchPath(
            prefix: URL(fileURLWithPath: "/opt/homebrew"),
            loginPath: nil,
            inherited: minimal
        )
        #expect(path.hasPrefix("/opt/homebrew/bin:"))
        #expect(path.hasSuffix(minimal), "what we were given is still there, just last")
    }

    /// `claude` is often somewhere only a login shell knows about — an nvm shim, typically — and
    /// without it the script cannot tell whether the hooks come from the plugin.
    @Test("a login shell's path is kept, after the prefix")
    func loginPathFollows() {
        let path = ClaudeSetup.searchPath(
            prefix: URL(fileURLWithPath: "/opt/homebrew"),
            loginPath: "/Users/x/.nvm/versions/node/v22.12.0/bin:\(minimal)",
            inherited: minimal
        )
        let parts = path.split(separator: ":").map(String.init)
        let prefix = try! #require(parts.firstIndex(of: "/opt/homebrew/bin"))
        let nvm = try! #require(parts.firstIndex(of: "/Users/x/.nvm/versions/node/v22.12.0/bin"))
        #expect(prefix < nvm)
    }

    @Test("an install Homebrew did not make still gets a usable path")
    func withoutAPrefix() {
        #expect(ClaudeSetup.searchPath(prefix: nil, loginPath: nil, inherited: minimal) == minimal)
    }

    /// Both of these are what a launchd job actually hands over.
    @Test("nothing to inherit falls back to somewhere the standard tools live")
    func withoutAnything() {
        for inherited in [nil, ""] {
            let path = ClaudeSetup.searchPath(prefix: nil, loginPath: nil, inherited: inherited)
            #expect(path == minimal)
        }
    }
}
