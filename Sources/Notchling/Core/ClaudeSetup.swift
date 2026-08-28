//
//  What `notchling-hooks` has wired, and the four buttons that change it.
//
//  The script is the authority, not this file. Whether the hooks are ours, and what holds the single
//  status line slot, are questions with fiddly answers — a bare name resolved from `PATH` is as
//  likely a status line as a path is, and a chain of ours can have been moved — and `install-hooks.sh
//  status --json` already answers them for the command line. A second implementation in Swift would
//  drift from it, and the drift would show up as a button that lies about what it is about to do.
//
//  So this runs the script that ships in the same bundle. No `PATH` lookup: the copy beside this
//  binary is the copy whose paths match this build.
//

import Foundation

struct ClaudeWiring: Equatable, Sendable, Decodable {
    /// Where the hook entries come from, if anywhere.
    enum Hooks: String, Codable, Sendable {
        case none
        case wired
        /// Wired to a copy of the hook binary that is not this one — an install that moved.
        case elsewhere
        /// The plugin provides them, and wiring settings.json too would report every event twice.
        case plugin
    }

    enum StatusLine: String, Codable, Sendable {
        case none
        case ours
        /// Ours, running in front of the one that was already there.
        case chain
        /// Somebody else's, with nothing feeding the bars.
        case foreign
    }

    var hooks: Hooks = .none
    var hookCommand: String = ""
    /// Empty where no hook binary could be found. Nothing can be wired or re-pointed from there, and
    /// offering it anyway is how `uninstall` runs against an `install` that was never going to work.
    var hookResolved: String = ""
    var statusLine: StatusLine = .none
    var statusLineCommand: String = ""
    /// What a chain runs in front of. Empty unless `statusLine` is `.chain`.
    var wrapped: String = ""
    /// Empty where no status line script could be found, which is a build nothing can offer it from.
    var statusLineResolved: String = ""
}

enum ClaudeSetup {
    enum Failure: Error, Equatable {
        /// No `install-hooks.sh` beside this binary — a `swift run` build rather than a bundle.
        case unavailable
        case failed(String)
    }

    /// How a status line that is already there should be treated.
    enum Occupied: Sendable {
        /// Run in front of it, leaving it to print exactly what it printed before.
        case chain
        /// Replace it. Only ever from an explicit second choice in the dialog.
        case replace
    }

    /// `status` shells out to `claude plugin list`, which is the slow part; the rest is `jq`.
    private static let timeout: TimeInterval = 30

    /// The copy in this bundle, or nil when there is no bundle to speak of.
    static var script: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("install-hooks.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }

    static var isSupported: Bool { script != nil }

    // MARK: - Reading

    nonisolated static func read() throws -> ClaudeWiring {
        let output = try run(["status", "--json"])
        guard let data = output.data(using: .utf8),
              let wiring = try? JSONDecoder().decode(ClaudeWiring.self, from: data)
        else {
            throw Failure.failed("could not read what is wired")
        }
        return wiring
    }

    // MARK: - Changing

    nonisolated static func wireHooks() throws { _ = try run(["install"]) }
    /// `at` names the copy to remove, for the case where it is not the one that would be resolved
    /// now: a stale install, or a settings.json entry sitting alongside the plugin's own hooks.
    nonisolated static func unwireHooks(at command: String? = nil) throws {
        _ = try run(command.map { ["uninstall", $0] } ?? ["uninstall"])
    }
    nonisolated static func removeStatusLine() throws { _ = try run(["no-statusline"]) }

    /// Two steps, because `install` appends. Wiring the new copy without removing the old one leaves
    /// both registered and every event reported twice — and `uninstall` on its own resolves the copy
    /// found *now*, which is not the stale one to be removed, so the path has to be handed to it.
    /// Two steps, because `install` appends. Wiring the new copy without removing the old one leaves
    /// both registered and every event reported twice — and `uninstall` on its own resolves the copy
    /// found *now*, which is not the stale one to be removed, so the path has to be handed to it.
    ///
    /// In this order, deliberately. The other way round, an `install` that cannot resolve a hook
    /// binary dies *after* the old entries are gone, and the machine is left wired to nothing at all.
    nonisolated static func repointHooks(from stale: String) throws {
        _ = try run(["install"])
        _ = try run(["uninstall", stale])
    }

    /// `occupied` is consulted only when something else holds the slot, and the script refuses
    /// without it — which is what keeps a click from quietly rewriting somebody's configuration.
    nonisolated static func addStatusLine(occupied: Occupied = .chain) throws {
        _ = try run(["statusline", occupied == .replace ? "--force" : "--chain"])
    }

    // MARK: - Running it

    private nonisolated static func run(_ arguments: [String]) throws -> String {
        guard let script else { throw Failure.unavailable }
        let result = try Command.run(script, arguments, timeout: timeout)
        guard result.status == 0 else { throw Failure.failed(reason(from: result.output)) }
        return result.output
    }

    /// The whole of the last thing the script said, not its final line.
    ///
    /// `die` prints one message, prefixed once with the script's own name, and the useful refusals run
    /// to three lines — the one naming where a lost command can be recovered from among them. Keeping
    /// only the last line reduced that to a fragment naming a flag nobody in a window can type.
    ///
    /// The prefix itself is for a terminal; a window has already said whose message this is.
    private nonisolated static func reason(from output: String) -> String {
        let prefix = "install-hooks: "
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let start = lines.lastIndex(where: { $0.hasPrefix(prefix) }) else {
            return lines.last ?? "it did not say why"
        }
        return lines[start...]
            .joined(separator: " ")
            .replacingOccurrences(of: prefix, with: "")
    }
}
