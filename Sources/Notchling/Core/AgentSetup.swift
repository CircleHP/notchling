//
//  What `notchling-hooks` has wired for each agent, and the buttons that change it.
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

struct AgentWiring: Equatable, Sendable, Decodable {
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

    /// Codex, whose only surface is its hooks: no registry to discover sessions from, and no status
    /// line slot to put anything in.
    ///
    /// Optional because absent is a real answer rather than a gap to fill in — a script that does not
    /// report it is one that does not know about Codex, and the window has to show the rest anyway.
    var codex: CodexWiring?
}

struct CodexWiring: Equatable, Sendable, Decodable {
    /// Whether this machine looks like it has Codex — the binary on `PATH`, or its home directory.
    /// Neither is proof, and it is only ever used to decide whether asking is worth it.
    var available: Bool = false
    /// The hooks file, wherever `CODEX_HOME` puts it.
    var home: String = ""
    var hooks: AgentWiring.Hooks = .none
    var hookCommand: String = ""
    /// Always `unknown`, and a field rather than an omission so the limitation is visible.
    ///
    /// Codex will not run a hook whose definition has not been reviewed, and records that decision as
    /// a hash keyed by the hook's position in its file. A hash at a position is not proof it matches
    /// what is there now, and writing one would forge an answer meant for the person — so this asks
    /// them to settle it instead of claiming to know.
    var trust: String = "unknown"
}

enum AgentSetup {
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

    nonisolated static func read() throws -> AgentWiring {
        let output = try run(["status", "--json"])
        guard let data = output.data(using: .utf8),
              let wiring = try? JSONDecoder().decode(AgentWiring.self, from: data)
        else {
            throw Failure.failed("could not read what is wired")
        }
        return wiring
    }

    // MARK: - Changing

    nonisolated static func wireHooks(provider: Provider = .claude) throws {
        _ = try run(["install"] + Self.flag(provider))
    }
    /// `at` names the copy to remove, for the case where it is not the one that would be resolved
    /// now: a stale install, or a settings.json entry sitting alongside the plugin's own hooks.
    nonisolated static func unwireHooks(at command: String? = nil, provider: Provider = .claude) throws {
        // The installer appends the agent's own argument, so it is handed the binary rather than the
        // command that was found in the file.
        let binary = command.map { $0.replacingOccurrences(of: " --provider \(provider.rawValue)", with: "") }
        _ = try run((binary.map { ["uninstall", $0] } ?? ["uninstall"]) + Self.flag(provider))
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
    nonisolated static func repointHooks(from stale: String, provider: Provider = .claude) throws {
        _ = try run(["install"] + Self.flag(provider))
        try unwireHooks(at: stale, provider: provider)
    }

    /// Claude is the default in the script too, so its argument is left off rather than spelled out —
    /// which keeps every command this runs identical to the one it ran before Codex existed.
    private nonisolated static func flag(_ provider: Provider) -> [String] {
        provider == .claude ? [] : ["--provider", provider.rawValue]
    }

    /// `occupied` is consulted only when something else holds the slot, and the script refuses
    /// without it — which is what keeps a click from quietly rewriting somebody's configuration.
    nonisolated static func addStatusLine(occupied: Occupied = .chain) throws {
        _ = try run(["statusline", occupied == .replace ? "--force" : "--chain"])
    }

    // MARK: - The environment the script expects

    /// A `PATH` the script's own resolution can work with.
    ///
    /// This is the whole reason the buttons need anything but the script. `notchling-hooks` finds the
    /// hook binary with `command -v`, and Homebrew's prefix by running `brew` — both of which assume
    /// the environment a terminal has. A launchd job has none of it: `PATH` is `/usr/bin:/bin` and
    /// four more, so nothing resolves, and rows that hide a button they cannot honour hide all of
    /// them. The window then reports "Not wired" and offers no way to wire it, which is worse than
    /// the refusal this whole feature exists to replace.
    ///
    /// Two sources, because neither is enough. The prefix is derived from the running bundle, the
    /// same way the update path finds it — deterministic, correct for this install, and never a
    /// literal in this binary. The login shell's `PATH` is asked for as well because `claude` itself
    /// is often somewhere only that knows about — an nvm shim, typically — and without it
    /// `plugin_provides_hooks` answers no for a machine whose hooks come from the plugin, which is
    /// the one machine where wiring `settings.json` too would report every event twice.
    private nonisolated static var environment: [String: String] {
        ["PATH": searchPath(
            prefix: HomebrewInstall.current()?.prefix,
            loginPath: loginPath,
            inherited: ProcessInfo.processInfo.environment["PATH"]
        )]
    }

    /// Ordered by how much each source can be trusted for *this* install: the prefix this bundle was
    /// launched from first, then what a terminal here would have, then whatever we were given — which
    /// under launchd is the bare minimum and under `make run` is everything.
    nonisolated static func searchPath(prefix: URL?, loginPath: String?, inherited: String?) -> String {
        var parts: [String] = []
        if let prefix { parts.append(prefix.appendingPathComponent("bin").path) }
        if let loginPath, !loginPath.isEmpty { parts.append(loginPath) }
        parts.append(inherited.flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return parts.joined(separator: ":")
    }

    /// What a terminal on this machine would have. Asked once — a login shell sources everything the
    /// person has configured, which is not free — and never fatal: without it the prefix above still
    /// resolves everything this project ships.
    private nonisolated static let loginPath: String? = {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty else { return nil }
        guard let result = try? Command.run(
            URL(fileURLWithPath: shell),
            ["-lc", "printf %s \"$PATH\""],
            timeout: 10
        ), result.status == 0 else { return nil }

        // The last line, not the whole output: `Command` folds stderr in with stdout, and a login
        // shell that greets you would otherwise become part of the `PATH`.
        let last = result.output.split(separator: "\n").last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    // MARK: - Running it

    private nonisolated static func run(_ arguments: [String]) throws -> String {
        guard let script else { throw Failure.unavailable }
        let result = try Command.run(script, arguments, environment: environment, timeout: timeout)
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
