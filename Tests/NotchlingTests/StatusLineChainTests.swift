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
