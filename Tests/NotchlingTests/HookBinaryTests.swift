import Foundation
import Testing

@testable import Notchling

/// The built `notchling-hook`, if it exists. Tests that need it are skipped rather than failed when it
/// has not been built, so `swift test` on a clean checkout is not a wall of red.
let hookBinary: URL? = {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = ["debug", "release"].map {
        repoRoot.appendingPathComponent(".build/\($0)/notchling-hook")
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

/// An environment that redirects the hook's spool into a scratch directory.
///
/// The spool path comes from `NSHomeDirectory()`, and Foundation on Darwin does **not** honour `HOME`
/// for that — it needs `CFFIXED_USER_HOME`. Setting only `HOME` silently writes to the real spool,
/// which is a confusing way to lose an afternoon.
func hookEnvironment(home: URL, extra: [String: String] = [:]) -> [String: String] {
    var environment = [
        "HOME": home.path,
        "CFFIXED_USER_HOME": home.path,
        "CLAUDE_PID": String(livePID),
    ]
    environment.merge(extra) { _, new in new }
    return environment
}

/// Run the hook with a payload on stdin and an isolated home, and return what it did.
@discardableResult
func runHook(_ payload: [String: Any], home: URL) throws -> (stdout: String, stderr: String, status: Int32) {
    let process = Process()
    process.executableURL = try #require(hookBinary)
    process.environment = hookEnvironment(home: home)

    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    inPipe.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
    try inPipe.fileHandleForWriting.close()

    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), process.terminationStatus)
}

func spooledEvents(home: URL) -> [[String: Any]] {
    let dir = home.appendingPathComponent(".notchling/events")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().compactMap { name in
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

@Suite("notchling-hook", .enabled(if: hookBinary != nil, "notchling-hook has not been built"))
struct HookBinaryTests {
    @Test("never writes to stdout, because Claude Code acts on hook stdout")
    func silentOnStdout() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let result = try runHook([
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "hello",
        ], home: home)

        #expect(result.stdout.isEmpty, "anything on stdout can alter session behaviour")
        #expect(result.stderr.isEmpty)
        #expect(result.status == 0)
    }

    @Test("a SubagentStop payload keeps the fields that identify the agent")
    func subagentStopIsForwarded() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        try runHook([
            "hook_event_name": "SubagentStop",
            "session_id": "s1",
            "agent_id": "a1",
            "agent_type": "Explore",
            "agent_transcript_path": "/tmp/agent-a1.jsonl",
            "last_assistant_message": "found 2 races",
            "stop_hook_active": false,
        ], home: home)

        let event = try #require(spooledEvents(home: home).first)
        #expect(event["event"] as? String == "SubagentStop")
        #expect(event["agentId"] as? String == "a1")
        #expect(event["agentType"] as? String == "Explore")
        #expect(event["agentTranscriptPath"] as? String == "/tmp/agent-a1.jsonl")
        #expect(event["lastMessage"] as? String == "found 2 races")
    }

    @Test("exits zero even for garbage, because a broken widget must not break a session")
    func neverFails() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        // Valid JSON, but nothing the hook understands.
        let noEvent = try runHook(["unrelated": true], home: home)
        #expect(noEvent.status == 0)
        #expect(noEvent.stdout.isEmpty)
        #expect(spooledEvents(home: home).isEmpty, "an unusable payload writes nothing")

        // Not JSON at all.
        let process = Process()
        process.executableURL = try #require(hookBinary)
        process.environment = hookEnvironment(home: home)
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(Data("this is not json".utf8))
        try inPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("maps the real UserPromptSubmit payload, whose prompt field is `prompt`")
    func capturesThePrompt() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        // This is the field name the CLI actually sends. Reading `user_input` instead meant the task
        // text was silently always nil, which is the regression this test locks down.
        try runHook([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "cwd": "/work",
            "prompt": "split the auth middleware out",
            "prompt_id": "p1",
            "permission_mode": "default",
            "transcript_path": "/t.jsonl",
        ], home: home)

        let event = try #require(spooledEvents(home: home).first)
        #expect(event["event"] as? String == "UserPromptSubmit")
        #expect(event["sessionId"] as? String == "s1")
        #expect(event["userInput"] as? String == "split the auth middleware out")
        #expect(event["promptId"] as? String == "p1")
        #expect(event["cwd"] as? String == "/work")
        #expect(event["v"] as? Int == 1)
    }

    @Test("tool summaries pick each tool's most identifying field")
    func toolSummaries() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let cases: [(tool: String, input: [String: Any], expected: String)] = [
            ("Bash", ["description": "Run the tests", "command": "npm test"], "Run the tests"),
            ("Bash", ["command": "npm test"], "npm test"),
            ("Read", ["file_path": "/a/b/Session.swift"], "Session.swift"),
            ("Edit", ["file_path": "/a/b/Theme.swift"], "Theme.swift"),
            ("Grep", ["pattern": "needsYou"], "needsYou"),
            ("WebFetch", ["url": "https://example.com/a/b"], "example.com"),
            ("Skill", ["skill": "artifact-design"], "artifact-design"),
            ("Task", ["description": "Explore the repo"], "Explore the repo"),
        ]

        for (index, testCase) in cases.enumerated() {
            try runHook([
                "hook_event_name": "PreToolUse",
                "session_id": "tool-\(index)",
                "tool_name": testCase.tool,
                "tool_input": testCase.input,
            ], home: home)
        }

        let summaries = spooledEvents(home: home).compactMap { $0["toolSummary"] as? String }
        #expect(summaries.count == cases.count)
        #expect(Set(summaries) == Set(cases.map(\.expected)))
    }

    @Test("long text is truncated so the spool cannot balloon")
    func truncatesLongText() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        try runHook([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "last_assistant_message": String(repeating: "x", count: 5000),
        ], home: home)

        let message = try #require(spooledEvents(home: home).first?["lastMessage"] as? String)
        #expect(message.count < 500)
        #expect(message.hasSuffix("…"))
    }

    /// Captured from a real `PostToolUseFailure`, which carries `error` and no `error_message` — the
    /// same class of bug as the `prompt` mapping above, and just as silent: the row says `failed` and
    /// never says why. `error_message` stays supported because `StopFailure` is an API-error event we
    /// cannot trigger on demand to capture.
    @Test("the failure reason is read from the key Claude actually sends",
          arguments: ["error", "error_message"])
    func failureReason(key: String) throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        try runHook([
            "hook_event_name": "PostToolUseFailure",
            "session_id": "s1",
            "tool_name": "Bash",
            key: "Exit code 3",
        ], home: home)

        let event = try #require(spooledEvents(home: home).first)
        #expect(event["errorMessage"] as? String == "Exit code 3")
    }

    @Test("newlines are flattened, so a row stays one line")
    func flattensNewlines() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        try runHook([
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "first\nsecond\nthird",
        ], home: home)

        let text = try #require(spooledEvents(home: home).first?["userInput"] as? String)
        #expect(!text.contains("\n"))
        #expect(text == "first second third")
    }

    @Test("terminal identity is taken from the environment, not the payload")
    func readsTerminalIdentityFromEnvironment() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = try #require(hookBinary)
        process.environment = hookEnvironment(home: home, extra: [
            "WARP_FOCUS_URL": "warp://session/deadbeef",
            "TERM_PROGRAM": "WarpTerminal",
            "__CFBundleIdentifier": "dev.warp.Warp-Stable",
        ])
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(try JSONSerialization.data(
            withJSONObject: ["hook_event_name": "SessionStart", "session_id": "s1"]
        ))
        try inPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let event = try #require(spooledEvents(home: home).first)
        #expect(event["focusURL"] as? String == "warp://session/deadbeef")
        #expect(event["termProgram"] as? String == "WarpTerminal")
        #expect(event["hostBundleId"] as? String == "dev.warp.Warp-Stable")
        #expect(event["pid"] as? Int == Int(livePID), "CLAUDE_PID identifies the owning session")
    }

    @Test("filenames are millisecond-prefixed so a plain sort is chronological")
    func filenamesSortChronologically() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        for index in 0 ..< 3 {
            try runHook(["hook_event_name": "PreToolUse", "session_id": "s\(index)",
                         "tool_name": "Read"], home: home)
        }

        let dir = home.appendingPathComponent(".notchling/events")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names.count == 3)
        let stamps = names.compactMap { Int($0.prefix(15)) }
        #expect(stamps.count == 3)
        #expect(stamps == stamps.sorted(), "sorted filenames must be in time order")
    }

    @Test("the spool directory is created private to the user")
    func spoolPermissions() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        try runHook(["hook_event_name": "SessionStart", "session_id": "s1"], home: home)

        let dir = home.appendingPathComponent(".notchling/events")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o700, "hook payloads can quote prompts, so keep them private")
    }

    @Test("the spool is capped even when every event is newer than the age cutoff")
    func prunesToTheCapWhenNothingIsOldEnough() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let fileManager = FileManager.default
        let dir = home.appendingPathComponent(".notchling/events")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        // Over the cap, and all written just now — a busy session produces one of these per tool
        // call, so ten minutes of work is well past 500 without a single file old enough to expire.
        for index in 0 ..< 600 {
            let name = String(format: "%015d-%@.json", index, UUID().uuidString)
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }

        // Neither of these is an event file, and both are older than the cutoff: the prune must
        // leave them alone. `failed/` is the app's, and deleting it would take the directory and
        // everything set aside in it; the `.tmp` belongs to a hook that is still writing, and
        // removing it makes that hook lose its event at the rename.
        let failed = dir.appendingPathComponent("failed")
        try fileManager.createDirectory(at: failed, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: failed.appendingPathComponent("001-kept.json"))
        let temporary = dir.appendingPathComponent(".in-flight.json.tmp")
        try Data("{}".utf8).write(to: temporary)
        let ancient = Date(timeIntervalSince1970: 1)
        for url in [failed, temporary] {
            try fileManager.setAttributes([.modificationDate: ancient], ofItemAtPath: url.path)
        }

        // The prune is sampled one run in 32, so this drives the hook until it fires. Expected to
        // take ~32 runs; the bound is only here so a prune that never happens fails the test
        // instead of hanging.
        var remaining = 600
        for _ in 0 ..< 400 {
            try runHook(["hook_event_name": "Stop", "session_id": "s1"], home: home)
            remaining = try fileManager.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count
            if remaining < 600 { break }
        }

        // 600 seeded, pruned to one under the cap, plus the event the pruning run then wrote.
        #expect(remaining == 500, "a spool of fresh events must still be capped")
        #expect(fileManager.fileExists(atPath: failed.appendingPathComponent("001-kept.json").path),
                "the prune must not reach into failed/")
        #expect(fileManager.fileExists(atPath: temporary.path),
                "a half-written file belongs to another hook")
    }

    @Test("no partial files are left behind")
    func noTempFilesLeft() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        try runHook(["hook_event_name": "Stop", "session_id": "s1"], home: home)

        let dir = home.appendingPathComponent(".notchling/events")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.allSatisfy { !$0.hasPrefix(".") && $0.hasSuffix(".json") },
                "the write is tmp-then-rename, so nothing half-written should survive")
    }
}
