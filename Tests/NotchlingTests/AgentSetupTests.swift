import Foundation
import Testing

@testable import Notchling

/// The environment the settings window hands to `notchling-hooks`.
///
/// Worth its own tests because getting it wrong is invisible in a terminal and total in the app: the
/// script resolves the hook binary with `command -v` and Homebrew's prefix by running `brew`, and a
/// launchd job has neither on its `PATH`. The rows then report "Not wired" and hide the button that
/// would wire it — which shipped in 1.2.2.
@Suite("AgentSetup — the search path")
struct AgentSetupSearchPathTests {
    private let minimal = "/usr/bin:/bin:/usr/sbin:/sbin"

    @Test("the prefix this bundle came from is searched first")
    func prefixLeads() {
        let path = AgentSetup.searchPath(
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
        let path = AgentSetup.searchPath(
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
        #expect(AgentSetup.searchPath(prefix: nil, loginPath: nil, inherited: minimal) == minimal)
    }

    /// Both of these are what a launchd job actually hands over.
    @Test("nothing to inherit falls back to somewhere the standard tools live")
    func withoutAnything() {
        for inherited in [nil, ""] {
            let path = AgentSetup.searchPath(prefix: nil, loginPath: nil, inherited: inherited)
            #expect(path == minimal)
        }
    }
}

/// The window decodes what the script prints. The two ship in one bundle, so they cannot really
/// disagree — which leaves the case worth pinning as the cheap one: a payload with no Codex answer
/// must still tell the window everything else it knows.
@Suite("AgentWiring decoding")
struct AgentWiringDecodingTests {
    private func decode(_ json: String) throws -> AgentWiring {
        try JSONDecoder().decode(AgentWiring.self, from: Data(json.utf8))
    }

    /// Absent is a real answer. Refusing the whole payload over it would blank every Claude row too.
    @Test("a payload with no Codex object still decodes")
    func codexIsOptional() throws {
        let wiring = try decode("""
        {"hooks":"wired","hookCommand":"/x/notchling-hook","hookResolved":"/x/notchling-hook",
         "statusLine":"ours","statusLineCommand":"/x/statusline.sh","wrapped":"",
         "statusLineResolved":"/x/statusline.sh"}
        """)

        #expect(wiring.hooks == .wired)
        #expect(wiring.codex == nil, "no answer, rather than an answer of no")
    }

    @Test("the Codex answer is read where the script gives one")
    func codexDecodes() throws {
        let wiring = try decode("""
        {"hooks":"none","hookCommand":"","hookResolved":"/x/notchling-hook",
         "statusLine":"none","statusLineCommand":"","wrapped":"","statusLineResolved":"",
         "codex":{"available":true,"home":"/h/.codex/hooks.json","hooks":"wired",
                  "hookCommand":"/x/notchling-hook --provider codex","trust":"unknown"}}
        """)

        let codex = try #require(wiring.codex)
        #expect(codex.available)
        #expect(codex.hooks == .wired)
        #expect(codex.home == "/h/.codex/hooks.json")
        #expect(codex.hookCommand == "/x/notchling-hook --provider codex")
        #expect(codex.trust == "unknown", "the honest answer, and a field so it is visible")
        #expect(wiring.hooks == .none, "the two agents are answered independently")
    }

}
