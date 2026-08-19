import Foundation
import Testing

@testable import Notchling

@Suite("HookEvent decoding")
struct HookEventTests {
    @Test("decodes the spool format the hook writes")
    func decodesSpoolShape() {
        let event = hookEvent("PreToolUse", session: "abc", [
            "cwd": "/w", "toolName": "Bash", "toolSummary": "npm test",
            "promptId": "p1", "pid": 4242, "termProgram": "WarpTerminal",
        ])
        #expect(event.v == 1)
        #expect(event.event == "PreToolUse")
        #expect(event.sessionId == "abc")
        #expect(event.toolName == "Bash")
        #expect(event.toolSummary == "npm test")
        #expect(event.pid == 4242)
        #expect(event.date == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("absent optional fields decode to nil rather than failing")
    func minimalPayload() throws {
        let json = #"{"v":1,"ts":123,"event":"Stop","sessionId":"s"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.cwd == nil)
        #expect(event.lastMessage == nil)
        #expect(event.notificationType == nil)
    }

    @Test("unknown fields are ignored, so a newer hook helper cannot break an older app")
    func unknownFieldsIgnored() throws {
        let json = #"{"v":1,"ts":1,"event":"Stop","sessionId":"s","somethingNew":{"a":1}}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.sessionId == "s")
    }

    @Test("a payload missing a required field fails to decode")
    func requiredFields() {
        let json = #"{"v":1,"ts":1,"event":"Stop"}"#  // no sessionId
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        }
    }

    @Test("isSubagent is driven by the presence of an agent id")
    func isSubagent() {
        #expect(!hookEvent("PreToolUse").isSubagent)
        #expect(hookEvent("PreToolUse", ["agentId": "a1"]).isSubagent)
    }
}

@Suite("HookSpoolWatcher")
@MainActor
struct HookSpoolWatcherTests {
    private func writeEvent(_ name: String, _ json: String, in dir: URL) {
        try! json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("drains the spool oldest first, by filename")
    func drainsInOrder() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Filenames are millisecond-prefixed precisely so a lexicographic sort is chronological.
        // Applying these out of order would leave a session showing the wrong state.
        writeEvent("001786965912285-c.json", #"{"v":1,"ts":3,"event":"Stop","sessionId":"s"}"#, in: dir)
        writeEvent("001786965906883-a.json", #"{"v":1,"ts":1,"event":"SessionStart","sessionId":"s"}"#, in: dir)
        writeEvent("001786965908959-b.json", #"{"v":1,"ts":2,"event":"UserPromptSubmit","sessionId":"s"}"#, in: dir)

        var received: [String] = []
        let watcher = HookSpoolWatcher(directory: dir) { events in
            received = events.map(\.event)
        }
        watcher.drain()

        #expect(received == ["SessionStart", "UserPromptSubmit", "Stop"])
    }

    @Test("a file that cannot be read leaves the spool, but is set aside rather than deleted")
    func setsAsideWhatItCannotRead() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeEvent("001-good.json", #"{"v":1,"ts":1,"event":"Stop","sessionId":"s"}"#, in: dir)
        writeEvent("002-broken.json", "{{{", in: dir)
        // What an upgrade produces: the new hook is already writing a schema this build predates.
        writeEvent("003-newer.json", #"{"v":2,"ts":2,"event":"Stop","sessionId":"s"}"#, in: dir)

        var received: [String] = []
        let watcher = HookSpoolWatcher(directory: dir) { received = $0.map(\.event) }
        watcher.drain()

        #expect(received == ["Stop"], "only the event this build understands is applied")

        let left = Set(try! FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["failed"], "nothing readable stays in the spool, or it is applied twice")

        let failed = dir.appendingPathComponent("failed")
        let setAside = Set(try! FileManager.default.contentsOfDirectory(atPath: failed.path))
        #expect(setAside == ["002-broken.json", "003-newer.json"],
                "deleting these would take the widget silent with nothing left to explain why")
    }

    @Test("draining again does not re-read what was set aside")
    func setAsideIsNotDrainedAgain() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeEvent("001-newer.json", #"{"v":2,"ts":1,"event":"Stop","sessionId":"s"}"#, in: dir)

        var calls = 0
        let watcher = HookSpoolWatcher(directory: dir) { _ in calls += 1 }
        watcher.drain()
        watcher.drain()

        #expect(calls == 0)
        let failed = dir.appendingPathComponent("failed")
        #expect(try! FileManager.default.contentsOfDirectory(atPath: failed.path) == ["001-newer.json"])
    }

    @Test("the set-aside directory is bounded, so a build that understands nothing cannot fill the disk")
    func setAsideIsBounded() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let failed = dir.appendingPathComponent("failed")
        try! FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        for index in 0 ..< HookSpoolWatcher.failedCap {
            writeEvent(String(format: "%04d-old.json", index), "{}", in: failed)
        }

        writeEvent("999-newer.json", #"{"v":2,"ts":1,"event":"Stop","sessionId":"s"}"#, in: dir)

        let watcher = HookSpoolWatcher(directory: dir) { _ in }
        watcher.drain()

        let left = Set(try! FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["failed"], "past the cap it is dropped rather than left to be retried forever")
        let held = try! FileManager.default.contentsOfDirectory(atPath: failed.path)
        #expect(held.count == HookSpoolWatcher.failedCap)
    }

    @Test("partial and non-event files are left alone")
    func ignoresOtherFiles() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeEvent(".002.json.tmp", #"{"v":1,"ts":1,"event":"Stop","sessionId":"s"}"#, in: dir)
        writeEvent("003.txt", #"{"v":1,"ts":1,"event":"Stop","sessionId":"s"}"#, in: dir)

        var called = false
        let watcher = HookSpoolWatcher(directory: dir) { _ in called = true }
        watcher.drain()
        #expect(!called, "nothing here is an event file the drain should touch")

        // The in-progress temp file and the non-json file must survive.
        let left = Set(try! FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left.contains(".002.json.tmp"), "a half-written file must not be eaten")
        #expect(left.contains("003.txt"))
    }

    @Test("an empty or missing directory does nothing")
    func emptyDirectory() {
        let dir = makeTempDirectory()
        var called = false
        let watcher = HookSpoolWatcher(directory: dir) { _ in called = true }
        watcher.drain()
        #expect(!called)

        try? FileManager.default.removeItem(at: dir)
        watcher.drain()
        #expect(!called)
    }
}

@Suite("SoundCues")
@MainActor
struct SoundCuesTests {
    private func session(_ id: String = "s", prompt: String? = nil) -> Session {
        var s = Session(sessionID: id)
        s.currentPromptID = prompt
        return s
    }

    @Test("each notifiable state has its own sound")
    func soundPerState() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }

        cues.play(for: session("a"), newState: .needsYou)
        cues.play(for: session("b"), newState: .done)
        cues.play(for: session("c"), newState: .error)
        #expect(played == ["Submarine", "Glass", "Basso"])
    }

    @Test("working and idle are silent")
    func silentStates() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }
        cues.play(for: session(), newState: .working)
        cues.play(for: session(), newState: .idle)
        #expect(played.isEmpty)
    }

    @Test("re-entering a state without leaving it stays quiet")
    func dedupePerEdge() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }

        cues.play(for: session(), newState: .needsYou)
        cues.play(for: session(), newState: .needsYou)
        cues.play(for: session(), newState: .needsYou)
        #expect(played == ["Submarine"], "a second permission prompt in one turn is not news")
    }

    @Test("leaving and re-entering sounds again")
    func rearmsAfterLeaving() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }

        cues.play(for: session(), newState: .needsYou)
        cues.clearDedupe(for: "s")
        cues.play(for: session(), newState: .needsYou)
        #expect(played == ["Submarine", "Submarine"])
    }

    @Test("dedupe is per session, not global")
    func dedupeIsPerSession() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }
        cues.play(for: session("a"), newState: .needsYou)
        cues.play(for: session("b"), newState: .needsYou)
        #expect(played.count == 2)
    }

    @Test("a stalled turn sounds once, and the next turn is new information")
    func stallKeyedByTurn() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }

        cues.playStalled(for: session("a", prompt: "turn-1"))
        cues.playStalled(for: session("a", prompt: "turn-1"))
        #expect(played == ["Tink"])

        cues.playStalled(for: session("a", prompt: "turn-2"))
        #expect(played == ["Tink", "Tink"])
    }
}
