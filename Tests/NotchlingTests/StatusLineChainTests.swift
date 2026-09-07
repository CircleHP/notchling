import Foundation
import Testing

@testable import Notchling

/// `install-hooks.sh` and `statusline-usage.sh` from the repo, and the `jq` they need. Skipped
/// rather than failed when anything is missing, like the other script-driven suites.
private let scripts: (installer: URL, statusLine: URL)? = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let installer = root.appendingPathComponent("install-hooks.sh")
    let statusLine = root.appendingPathComponent("statusline-usage.sh")
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: installer.path),
          manager.isExecutableFile(atPath: statusLine.path),
          ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"]
              .contains(where: { manager.isExecutableFile(atPath: $0) })
    else { return nil }
    return (installer, statusLine)
}()

/// Claude Code has one status line slot, and the plan limits reach it and nothing else. So a machine
/// that already has a status line has to run both — which is what the chain does, and what these
/// tests are about.
///
/// The command being wrapped belongs to somebody else, and this is the only thing in the project
/// that runs a stranger's shell command. So the cases here are chosen to be awkward on purpose: a
/// command that ignores its stdin, one that fails, one that is a bare name resolved from PATH, one
/// carrying quotes a naive escaping scheme would eat.
@Suite(
    "install-hooks.sh — the status line chain",
    .enabled(if: scripts != nil, "install-hooks.sh, statusline-usage.sh or jq is not available")
)
struct StatusLineChainTests {
    // MARK: - Driving the scripts

    private struct Run {
        let status: Int32
        let output: String
    }

    @discardableResult
    private func installer(_ arguments: [String], home: URL, ownPath: Bool = false) throws -> Run {
        let process = Process()
        process.executableURL = try #require(scripts?.installer)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        // A `bin` of our own in front, so `resolve_hook` finds this scratch machine's hook rather
        // than the one installed on the machine running the tests, and `plugin_provides_hooks` asks
        // a `claude` that always says no.
        if ownPath {
            environment["PATH"] = "\(home.appendingPathComponent("bin").path):\(environment["PATH"] ?? "")"
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Not a terminal, so the interactive question cannot be asked — which is the state a scripted
        // install is in, and the one where refusing rather than assuming matters.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    /// The chain, fed the payload Claude Code would feed a status line.
    private func renderChain(home: URL, session: String = "s1") throws -> Run {
        let payload: [String: Any] = [
            "session_id": session,
            "model": ["display_name": "Opus"],
            "workspace": ["current_dir": "/tmp/project"],
            "context_window": ["used_percentage": 12, "context_window_size": 200_000],
            "rate_limits": [
                "five_hour": ["used_percentage": 42, "resets_at": 99_999_999],
                "seven_day": ["used_percentage": 7, "resets_at": 99_999_999],
            ],
        ]

        let process = Process()
        process.executableURL = home.appendingPathComponent(".notchling/statusline.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - A scratch machine

    private func withHome(
        statusLine: String?,
        directory: String = "notchling-chain",
        _ body: (URL) throws -> Void
    ) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(directory)-\(UUID().uuidString)")
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var settings: [String: Any] = [:]
        if let statusLine {
            // `padding` is not ours and not something we know about. It is here because ccstatusline
            // writes one, and an installer that replaced the whole object would eat it.
            settings["statusLine"] = ["type": "command", "command": statusLine, "padding": 3]
        }
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: claude.appendingPathComponent("settings.json"))

        try body(home)
    }

    private func settings(_ home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func statusLine(_ home: URL) throws -> [String: Any] {
        try #require(try settings(home)["statusLine"] as? [String: Any])
    }

    private func chainPath(_ home: URL) -> String {
        home.appendingPathComponent(".notchling/statusline.sh").path
    }

    private func wrapped(_ home: URL) throws -> String {
        try String(contentsOf: home.appendingPathComponent(".notchling/statusline-wrapped.sh"), encoding: .utf8)
    }

    // MARK: - What holds the slot

    @Test("an empty slot takes ours, with the refresh that keeps the countdown moving")
    func installsIntoAnEmptySlot() throws {
        try withHome(statusLine: nil) { home in
            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.status == 0)
            let line = try statusLine(home)
            #expect(line["command"] as? String == scripts!.statusLine.path)
            #expect(line["refreshInterval"] as? Int == 60)
        }
    }

    @Test("a status line we already installed is left exactly as it is")
    func ourOwnIsIdempotent() throws {
        try withHome(statusLine: scripts!.statusLine.path) { home in
            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.status == 0)
            #expect(run.output.contains("already configured"))
        }
    }

    @Test("somebody else's is refused, and both ways out are named")
    func foreignIsRefusedWithAWayForward() throws {
        try withHome(statusLine: "ccstatusline") { home in
            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.status == 1)
            #expect(run.output.contains("--chain"), "refusing without naming the alternative is the bug")
            #expect(run.output.contains("--force"))
            #expect(try statusLine(home)["command"] as? String == "ccstatusline", "nothing was touched")
        }
    }

    /// The refusal above used to take a backup and a `mktemp` before deciding, so a run that changed
    /// nothing still left two files in `~/.claude` — the one directory this treads carefully in.
    @Test("a refusal leaves nothing behind in ~/.claude")
    func refusalWritesNothing() throws {
        try withHome(statusLine: "ccstatusline") { home in
            let claude = home.appendingPathComponent(".claude")
            try installer(["statusline", scripts!.statusLine.path], home: home)
            let files = try FileManager.default.contentsOfDirectory(atPath: claude.path)
            #expect(files == ["settings.json"], "left behind: \(files)")
        }
    }

    @Test("--force replaces it, keeping the keys that were not ours to touch")
    func forceReplaces() throws {
        try withHome(statusLine: "ccstatusline") { home in
            try installer(["statusline", scripts!.statusLine.path, "--force"], home: home)
            let line = try statusLine(home)
            #expect(line["command"] as? String == scripts!.statusLine.path)
            #expect(line["padding"] as? Int == 3)
        }
    }

    @Test("--chain keeps theirs and puts ours in front, touching only the command")
    func chainInstalls() throws {
        try withHome(statusLine: "ccstatusline") { home in
            let run = try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            #expect(run.status == 0)

            let line = try statusLine(home)
            #expect(line["command"] as? String == chainPath(home))
            #expect(line["padding"] as? Int == 3, "somebody else's key, left alone")
            #expect(line["refreshInterval"] == nil, "how often their status line runs is not ours to set")
            #expect(try wrapped(home) == "ccstatusline")
        }
    }

    @Test("a chain is recognised as ours and rewritten, not refused as a stranger")
    func chainIsRecognised() throws {
        try withHome(statusLine: "ccstatusline") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.status == 0)
            #expect(run.output.contains("refreshed"))
            #expect(try wrapped(home) == "ccstatusline", "the wrapped command survives a refresh")
        }
    }

    // MARK: - Giving it back

    /// The same invariant the hook uninstaller holds: remove only what we installed. A chain is the
    /// first case where honouring it means *restoring* something rather than deleting it.
    @Test(
        "any command survives being chained and given back, byte for byte",
        arguments: [
            "ccstatusline",
            "sh -c 'echo it'\\''s here'",
            #"printf "%s\n" "hi there""#,
            "echo $HOME `date +%s` ${FOO:-x}",
            "echo one\necho two",
        ]
    )
    func roundTripsVerbatim(command: String) throws {
        try withHome(statusLine: command) { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            #expect(try wrapped(home) == command)

            let run = try installer(["no-statusline"], home: home)
            #expect(run.status == 0)
            let line = try statusLine(home)
            #expect(line["command"] as? String == command)
            #expect(line["padding"] as? Int == 3)
            #expect(!FileManager.default.fileExists(atPath: chainPath(home)), "the wrapper goes with it")
        }
    }

    @Test("a status line we did not install is still left alone")
    func foreignIsNotRemoved() throws {
        try withHome(statusLine: "ccstatusline") { home in
            let run = try installer(["no-statusline"], home: home)
            #expect(run.status == 0)
            #expect(try statusLine(home)["command"] as? String == "ccstatusline")
        }
    }

    // MARK: - What the chain does when it runs

    @Test("both halves get the same payload, and only theirs reaches the terminal")
    func feedsBothFromOneStdin() throws {
        try withHome(statusLine: "cat >/dev/null; echo THEIRS") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)

            let render = try renderChain(home: home)
            #expect(render.output == "THEIRS\n", "our half must print nothing at all")

            let usage = home.appendingPathComponent(".notchling/usage/s1.json")
            let file = try #require(try JSONSerialization.jsonObject(
                with: Data(contentsOf: usage)
            ) as? [String: Any])
            #expect(file["fiveHourUsedPercent"] as? Double == 42)
        }
    }

    /// The reason the wrapper is not `pipefail`. A status line under no obligation to read its stdin
    /// makes our write fail with `SIGPIPE`, and Notchling must not turn a working status line into a
    /// failing one over input it never asked for.
    @Test("a status line that ignores its stdin still succeeds")
    func ignoringStdinIsNotAFailure() throws {
        try withHome(statusLine: "echo IGNORES-STDIN") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            let render = try renderChain(home: home)
            #expect(render.status == 0)
            #expect(render.output == "IGNORES-STDIN\n")
        }
    }

    @Test("their failure stays theirs")
    func exitStatusIsTheirs() throws {
        try withHome(statusLine: "cat >/dev/null; exit 3") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            #expect(try renderChain(home: home).status == 3)
        }
    }

    @Test("their bytes pass through untouched, colours and all")
    func outputIsNotReshaped() throws {
        try withHome(statusLine: #"cat >/dev/null; printf '\033[31mred\033[0m'"#) { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            #expect(try renderChain(home: home).output == "\u{1B}[31mred\u{1B}[0m")
        }
    }

    /// The property that makes chaining safe to offer at all: uninstalling Notchling costs the
    /// status line nothing but the bars. `brew uninstall` never runs `no-statusline` — the formula
    /// may not touch `~/.claude` — so the wrapper has to survive the app disappearing under it.
    @Test("with Notchling gone, the chain still prints their status line")
    func survivesUninstall() throws {
        try withHome(statusLine: "cat >/dev/null; echo SURVIVES") { home in
            // A copy of the script, so removing it stands in for an uninstalled app.
            let copy = home.appendingPathComponent("statusline-usage.sh")
            try FileManager.default.copyItem(at: scripts!.statusLine, to: copy)
            try installer(["statusline", copy.path, "--chain"], home: home)
            try FileManager.default.removeItem(at: copy)

            let render = try renderChain(home: home)
            #expect(render.status == 0)
            #expect(render.output == "SURVIVES\n")
        }
    }

    // MARK: - Ways the slot lies about itself

    /// The worst thing this can do, and it took a review to find it.
    ///
    /// `settings.json` still names the chain, but the files are gone — `rm -rf ~/.notchling` is in
    /// SETUP.md as a thing to do. Classified by path shape alone, the chain then reads as a stranger,
    /// and chaining wraps the chain path in itself: the wrapped command is lost, and every render
    /// forks a copy that forks a copy until the machine runs out of processes.
    @Test("a chain whose files are gone is never wrapped in itself")
    func doesNotWrapItself() throws {
        try withHome(statusLine: "ccstatusline") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            try FileManager.default.removeItem(at: home.appendingPathComponent(".notchling"))

            let run = try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            #expect(run.status == 1)
            #expect(run.output.contains("notchling-backup"), "the lost command is in a backup; say so")
            #expect(try statusLine(home)["command"] as? String == chainPath(home), "nothing was touched")
            #expect(
                !FileManager.default.fileExists(
                    atPath: home.appendingPathComponent(".notchling/statusline-wrapped.sh").path
                ),
                "wrapping the chain in itself is the failure this test exists for"
            )
        }
    }

    /// `${current%% *}` splits the recorded path at the space, so the marker is never read and our own
    /// chain reads as somebody else's — which lands straight in the case above.
    @Test("a chain under a $HOME with a space is still recognised as ours")
    func classifiesUnderAHomeWithASpace() throws {
        try withHome(statusLine: "ccstatusline", directory: "notchling chain") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)

            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.output.contains("refreshed"), "read as a stranger: \(run.output)")
            #expect(try wrapped(home) == "ccstatusline")
        }
    }

    /// The advertised way back out of chaining, and it used to be swallowed: the chain case answered
    /// first and reported a refresh.
    @Test("--force replaces a chain of ours, and takes the wrapper with it")
    func forceReplacesAChain() throws {
        try withHome(statusLine: "ccstatusline") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            try installer(["statusline", scripts!.statusLine.path, "--force"], home: home)

            #expect(try statusLine(home)["command"] as? String == scripts!.statusLine.path)
            #expect(!FileManager.default.fileExists(atPath: chainPath(home)))
        }
    }

    /// Moving between a clone, `~/Applications` and Homebrew leaves settings.json naming a script that
    /// is no longer there. Answering "already configured" to that leaves the bars dead with nothing on
    /// screen to explain it — and the recorded path surviving an install move is a repo invariant.
    @Test("our own status line is re-pointed when the recorded path has moved")
    func repointsOurOwnStalePath() throws {
        try withHome(statusLine: "/nowhere/Notchling.app/Contents/Resources/statusline-usage.sh") { home in
            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.output.contains("re-pointing"))
            #expect(try statusLine(home)["command"] as? String == scripts!.statusLine.path)
        }
    }

    @Test("a chain that has been moved is still restored from wherever it is")
    func restoresARelocatedChain() throws {
        try withHome(statusLine: "ccstatusline") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)

            // The wrapper finds its partner beside itself, so a moved pair keeps working — and the
            // installer has to look where it is rather than where it was written.
            let elsewhere = home.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            for name in ["statusline.sh", "statusline-wrapped.sh"] {
                try FileManager.default.moveItem(
                    at: home.appendingPathComponent(".notchling/\(name)"),
                    to: elsewhere.appendingPathComponent(name)
                )
            }
            var moved = try settings(home)
            var line = try statusLine(home)
            line["command"] = elsewhere.appendingPathComponent("statusline.sh").path
            moved["statusLine"] = line
            try JSONSerialization.data(withJSONObject: moved)
                .write(to: home.appendingPathComponent(".claude/settings.json"))

            let run = try installer(["no-statusline"], home: home)
            #expect(run.status == 0)
            #expect(try statusLine(home)["command"] as? String == "ccstatusline")
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }

    @Test("removing somebody else's status line leaves no files behind either")
    func removalOfForeignWritesNothing() throws {
        try withHome(statusLine: "ccstatusline") { home in
            try installer(["no-statusline"], home: home)
            let files = try FileManager.default
                .contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path)
            #expect(files == ["settings.json"], "left behind: \(files)")
        }
    }

    /// Valid JSON is not the same as a settings file this can reason about. Merging into a
    /// hand-edited string leaves `jq` to fail with an error naming neither this script nor the file.
    @Test("a .statusLine that is not an object fails as ours, not as jq's")
    func rejectsANonObjectStatusLine() throws {
        try withHome(statusLine: nil) { home in
            let file = home.appendingPathComponent(".claude/settings.json")
            try Data(#"{"statusLine": "ccstatusline"}"#.utf8).write(to: file)

            let run = try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(run.status == 1)
            #expect(run.output.contains("install-hooks:"))
            #expect(!run.output.contains("jq: error"))
        }
    }

    @Test("the status-line flags are rejected where they mean nothing")
    func flagsAreScopedToTheirMode() throws {
        try withHome(statusLine: nil) { home in
            let run = try installer(["install", scripts!.statusLine.path, "--force"], home: home)
            #expect(run.status == 1)
            #expect(run.output.contains("statusline"))
        }
    }

    // MARK: - Reporting what is wired

    /// The settings window asks this question through the same script, so what it can be told is
    /// worth pinning: a second implementation of "what holds the slot" in Swift would drift, and the
    /// drift would show up as a button that lies about what it is about to do.
    private func scratchBin(_ home: URL) throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("notchling-hook", "#!/bin/sh\nexit 0\n"), ("claude", "#!/bin/sh\nexit 1\n")] {
            let file = bin.appendingPathComponent(name)
            try Data(body.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    private func status(_ home: URL) throws -> [String: String] {
        let run = try installer(["status", "--json"], home: home, ownPath: true)
        #expect(run.status == 0)
        let data = try #require(run.output.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test("status reports an unwired machine as unwired")
    func statusOnAFreshMachine() throws {
        try withHome(statusLine: nil) { home in
            try scratchBin(home)
            let reported = try status(home)
            #expect(reported["hooks"] == "none")
            #expect(reported["statusLine"] == "none")
        }
    }

    @Test("status names each of the four things that can hold the status line slot")
    func statusClassifiesTheSlot() throws {
        try withHome(statusLine: nil) { home in
            try scratchBin(home)
            #expect(try status(home)["statusLine"] == "none")

            try installer(["statusline", scripts!.statusLine.path], home: home)
            #expect(try status(home)["statusLine"] == "ours")

            try installer(["no-statusline"], home: home)
            var settings = try settings(home)
            settings["statusLine"] = ["type": "command", "command": "ccstatusline"]
            try JSONSerialization.data(withJSONObject: settings)
                .write(to: home.appendingPathComponent(".claude/settings.json"))
            var reported = try status(home)
            #expect(reported["statusLine"] == "foreign")
            #expect(reported["statusLineCommand"] == "ccstatusline")

            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            reported = try status(home)
            #expect(reported["statusLine"] == "chain")
            #expect(reported["wrapped"] == "ccstatusline", "the window says what it runs in front of")
        }
    }

    @Test("status tells a hook wired elsewhere from one wired here")
    func statusClassifiesTheHooks() throws {
        try withHome(statusLine: nil) { home in
            try scratchBin(home)
            let hook = home.appendingPathComponent("bin/notchling-hook").path

            try installer(["install", hook], home: home, ownPath: true)
            #expect(try status(home)["hooks"] == "wired")

            // The same file under a different path is a different install, which is the case the
            // window offers to re-point rather than wire a second copy of.
            let moved = home.appendingPathComponent("elsewhere/notchling-hook")
            try FileManager.default.createDirectory(
                at: moved.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try installer(["uninstall", hook], home: home, ownPath: true)
            try FileManager.default.copyItem(at: home.appendingPathComponent("bin/notchling-hook"), to: moved)
            try installer(["install", moved.path], home: home, ownPath: true)

            let reported = try status(home)
            #expect(reported["hooks"] == "elsewhere")
            #expect(reported["hookCommand"] == moved.path)
        }
    }

    @Test("status reads a machine that has no ~/.claude at all, and leaves it that way")
    func statusCreatesNothing() throws {
        try withHome(statusLine: nil) { home in
            try scratchBin(home)
            // The settings window calls this every time it opens, so it has to be a question rather
            // than a change — and on a machine where Claude Code has never run there is nothing here.
            try FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))

            let reported = try status(home)
            #expect(reported["hooks"] == "none")
            #expect(reported["statusLine"] == "none")
            #expect(
                !FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path),
                "reporting on a file is not a reason to create it"
            )
        }
    }

    /// `rm -f` on a path nobody looked at. With a `$HOME` containing a space and the chain's files
    /// deleted, deriving the pair by splitting the recorded command at the first space produced two
    /// paths outside the home directory — and then removed them.
    @Test("a $HOME with a space never has files deleted out from under it")
    func neverDeletesAGuessedPath() throws {
        try withHome(statusLine: "ccstatusline", directory: "my home") { home in
            try installer(["statusline", scripts!.statusLine.path, "--chain"], home: home)
            // settings.json still names the chain; its files no longer exist.
            try FileManager.default.removeItem(at: home.appendingPathComponent(".notchling"))

            // Exactly what the word-split named, and what it deleted.
            let outside = home.deletingLastPathComponent()
            let bystanders = [
                outside.appendingPathComponent(home.lastPathComponent.split(separator: " ")[0].description),
                outside.appendingPathComponent("statusline-wrapped.sh"),
            ]
            for file in bystanders { try Data("keep me".utf8).write(to: file) }
            defer { for file in bystanders { try? FileManager.default.removeItem(at: file) } }

            try installer(["statusline", scripts!.statusLine.path, "--force"], home: home)

            for file in bystanders {
                #expect(
                    FileManager.default.fileExists(atPath: file.path),
                    "deleted a bystander: \(file.path)"
                )
            }
            #expect(try statusLine(home)["command"] as? String == scripts!.statusLine.path)
        }
    }

    @Test("--chain and --force together is refused rather than silently resolved")
    func contradictoryFlagsAreRefused() throws {
        try withHome(statusLine: "ccstatusline") { home in
            let run = try installer(
                ["statusline", scripts!.statusLine.path, "--chain", "--force"], home: home
            )
            #expect(run.status == 1)
            #expect(try statusLine(home)["command"] as? String == "ccstatusline", "nothing was touched")
        }
    }

    /// What "Re-point" in the settings window is built on, and the reason it installs before it
    /// uninstalls: with the order reversed, an `install` that cannot resolve a hook binary dies after
    /// the old entries are gone, leaving the machine wired to nothing.
    @Test("wiring a second copy and then removing the first leaves only the new one")
    func repointingKeepsTheMachineWired() throws {
        try withHome(statusLine: nil) { home in
            try scratchBin(home)
            let first = home.appendingPathComponent("bin/notchling-hook").path
            let second = home.appendingPathComponent("elsewhere/notchling-hook")
            try FileManager.default.createDirectory(
                at: second.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(atPath: first, toPath: second.path)

            try installer(["install", first], home: home, ownPath: true)
            try installer(["install", second.path], home: home, ownPath: true)
            // Both wired at once is the moment the order protects: every event reported twice is
            // recoverable, nothing wired at all is what the user cannot see or fix from here.
            try installer(["uninstall", first], home: home, ownPath: true)

            let reported = try status(home)
            #expect(reported["hookCommand"] == second.path)
            let settings = try settings(home)
            let commands = ((settings["hooks"] as? [String: Any]) ?? [:]).values
                .compactMap { $0 as? [[String: Any]] }
                .flatMap { $0 }
                .compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap { $0 }
                .compactMap { $0["command"] as? String }
            #expect(!commands.isEmpty, "the events are still wired")
            #expect(!commands.contains(first), "the stale copy is gone")
        }
    }
}

/// Codex keeps its hooks in a file of the same shape as Claude Code's, and keys each hook's trust
/// decision by its position in that file. So the case that matters here is not the empty one: it is a
/// file that already belongs to other tools, which must come out of this exactly as it went in.
@Suite(
    "install-hooks.sh — wiring Codex",
    .enabled(if: scripts != nil, "install-hooks.sh or jq is not available")
)
struct CodexWiringTests {
    private struct Run {
        let status: Int32
        let output: String
    }

    @discardableResult
    private func installer(_ arguments: [String], home: URL) throws -> Run {
        let process = Process()
        process.executableURL = try #require(scripts?.installer)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "CODEX_HOME")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    /// A machine that already has hooks of its own. Two groups on one event, the second with a matcher
    /// and a timeout of its own, because that is what a real `hooks.json` looks like.
    private static var occupied: [String: Any] { [
        "hooks": [
            "PreToolUse": [
                ["hooks": [["type": "command", "command": "/other/tool.sh"]]],
                [
                    "matcher": "^Bash$",
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/bin/python3 /x/git.py",
                        "timeout": 90,
                        "statusMessage": "Checking",
                    ]],
                ],
            ],
            "Stop": [["hooks": [["type": "command", "command": "/other/tool.sh"]]]],
        ],
    ] }

    private func withHome(
        hooks: [String: Any]? = nil,
        _ body: (URL, URL) throws -> Void
    ) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchling-codex-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let hook = bin.appendingPathComponent("notchling-hook")
        try "#!/bin/sh\nexit 0\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        if let hooks {
            try JSONSerialization.data(withJSONObject: hooks)
                .write(to: codex.appendingPathComponent("hooks.json"))
        }

        try body(home, hook)
    }

    private func hooksFile(_ home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".codex/hooks.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func groups(_ home: URL, _ event: String) throws -> [[String: Any]] {
        let hooks = try #require(try hooksFile(home)["hooks"] as? [String: Any])
        return (hooks[event] as? [[String: Any]]) ?? []
    }

    private func command(_ group: [String: Any]) -> String? {
        ((group["hooks"] as? [[String: Any]])?.first)?["command"] as? String
    }

    /// Codex records trust as `hooks.json:<event>:<group>:<hook>`, so an entry inserted anywhere but
    /// the end renumbers the groups after it — and every hook that moves stops matching the hash it
    /// was trusted under, which Codex reports as a definition that has changed.
    @Test("our entry goes last, leaving every other tool's position alone")
    func appendsWithoutRenumbering() throws {
        try withHome(hooks: Self.occupied) { home, hook in
            try installer(["install", hook.path, "--provider", "codex"], home: home)

            let pre = try groups(home, "PreToolUse")
            #expect(pre.count == 3)
            #expect(command(pre[0]) == "/other/tool.sh", "still group 0")
            #expect(command(pre[1]) == "/usr/bin/python3 /x/git.py", "still group 1")
            #expect(command(pre[2])?.hasSuffix("notchling-hook --provider codex") == true)

            // Their group is not just in place, it is untouched: matcher, timeout and all.
            #expect(pre[1]["matcher"] as? String == "^Bash$")
            let theirs = try #require((pre[1]["hooks"] as? [[String: Any]])?.first)
            #expect(theirs["timeout"] as? Int == 90)
            #expect(theirs["statusMessage"] as? String == "Checking")
        }
    }

    /// The hook is told which agent it is serving because nothing in a payload says: Codex names every
    /// shared event exactly as Claude Code does, and its field names match too.
    @Test("the command written names the agent")
    func commandCarriesTheProvider() throws {
        try withHome { home, hook in
            try installer(["install", hook.path, "--provider", "codex"], home: home)
            let start = try groups(home, "SessionStart")
            #expect(command(start.first ?? [:]) == "\(hook.path) --provider codex")
        }
    }

    /// Codex caps `SessionEnd` and `Interrupt` at three seconds and warns on every session start if a
    /// hook asks for more, while every other event defaults to six hundred — long enough for a wedged
    /// hook to hold a tool call for ten minutes.
    @Test("every event is given a timeout inside Codex's own limits", arguments: [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "SubagentStart", "SubagentStop", "Stop", "Interrupt", "PreCompact", "PostCompact", "SessionEnd",
    ])
    func timeoutsAreBounded(event: String) throws {
        try withHome { home, hook in
            try installer(["install", hook.path, "--provider", "codex"], home: home)
            let entry = try #require((try groups(home, event).first?["hooks"] as? [[String: Any]])?.first)
            let timeout = try #require(entry["timeout"] as? Int)
            #expect(timeout >= 1)
            #expect(timeout <= 3, "\(event) must fit the strictest cap, which is SessionEnd's")
        }
    }

    @Test("installing twice wires nothing twice")
    func installIsIdempotent() throws {
        try withHome(hooks: Self.occupied) { home, hook in
            try installer(["install", hook.path, "--provider", "codex"], home: home)
            try installer(["install", hook.path, "--provider", "codex"], home: home)

            #expect(try groups(home, "PreToolUse").count == 3)
            #expect(try groups(home, "SessionStart").count == 1)
        }
    }

    /// The whole point of the additive rule: someone who tries Notchling and removes it should not be
    /// able to tell it was ever there.
    @Test("uninstalling puts the file back exactly as it was")
    func uninstallRestoresTheFile() throws {
        try withHome(hooks: Self.occupied) { home, hook in
            let before = try hooksFile(home)
            try installer(["install", hook.path, "--provider", "codex"], home: home)
            try installer(["uninstall", hook.path, "--provider", "codex"], home: home)

            let after = try hooksFile(home)
            #expect(
                try JSONSerialization.data(withJSONObject: after, options: .sortedKeys)
                    == JSONSerialization.data(withJSONObject: before, options: .sortedKeys)
            )
        }
    }

    /// Writing the file is not enough and cannot be. Codex will not run a hook whose definition has
    /// not been reviewed, and the record of that review is a hash it keeps itself — writing one here
    /// would forge an answer to a question meant for the person.
    @Test("installing says what the person still has to do")
    func installAsksForTrust() throws {
        try withHome { home, hook in
            let run = try installer(["install", hook.path, "--provider", "codex"], home: home)
            #expect(run.status == 0)
            #expect(run.output.contains("/hooks"))
            #expect(!run.output.lowercased().contains("restart any running claude"))
        }
    }

    /// A file Notchling cannot parse belongs to somebody else and is left alone. Replacing it with our
    /// idea of it would cost them every hook they have.
    @Test("a hooks file that does not parse is refused, not rewritten")
    func malformedFileIsRefused() throws {
        try withHome { home, hook in
            let path = home.appendingPathComponent(".codex/hooks.json")
            try "{{{ not json".write(to: path, atomically: true, encoding: .utf8)

            let run = try installer(["install", hook.path, "--provider", "codex"], home: home)
            #expect(run.status != 0)
            #expect(try String(contentsOf: path, encoding: .utf8) == "{{{ not json")
        }
    }

    /// `CODEX_HOME` relocates the whole directory, and a widget launched at login inherits no terminal
    /// environment — so the resolved path has to be written down rather than assumed again later.
    @Test("a relocated Codex home is honoured")
    func codexHomeIsHonoured() throws {
        try withHome { home, hook in
            let elsewhere = home.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = try #require(scripts?.installer)
            process.arguments = ["install", hook.path, "--provider", "codex"]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["CODEX_HOME"] = elsewhere.path
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("hooks.json").path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path))
        }
    }

    /// Claude Code's own wiring must not move. The two are installed separately, and someone who has
    /// only ever run Claude should see no difference at all.
    @Test("the Claude path is unchanged, and writes no timeout")
    func claudeWiringIsUnchanged() throws {
        try withHome { home, hook in
            let claude = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            try "{}".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

            try installer(["install", hook.path], home: home)

            let data = try Data(contentsOf: claude.appendingPathComponent("settings.json"))
            let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = try #require(settings["hooks"] as? [String: Any])
            let group = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
            let entry = try #require((group["hooks"] as? [[String: Any]])?.first)

            #expect(entry["command"] as? String == hook.path, "no provider argument")
            #expect(entry["timeout"] == nil, "Claude Code's entries are as they always were")
            #expect(hooks["PostToolUse"] == nil, "still refused: its payload carries the tool's output")
        }
    }

    @Test("the status line stays Claude Code's")
    func statusLineRefusesAProvider() throws {
        try withHome { home, _ in
            let run = try installer(["statusline", "--provider", "codex"], home: home)
            #expect(run.status != 0)
            #expect(run.output.contains("status line"))
        }
    }
}
