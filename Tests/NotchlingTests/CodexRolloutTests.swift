import Foundation
import Testing

@testable import Notchling

/// Record shapes taken from a `codex-cli` 0.153.4 rollout rather than written from a schema, so a drift
/// fails a test instead of putting a stale number on a row. The conversation records are here too, at
/// the size they really reach, because refusing them is the point.
@Suite("CodexRolloutReader")
struct CodexRolloutTests {
    private static let tokenCount = """
    {"timestamp":"2026-09-07T13:38:32.093Z","type":"event_msg","payload":{"type":"token_count",\
    "info":{"total_token_usage":{"input_tokens":16491,"total_tokens":16902},\
    "last_token_usage":{"input_tokens":16491,"total_tokens":16902},"model_context_window":258400},\
    "rate_limits":{"primary":{"used_percent":77.0,"window_minutes":300,"resets_at":1788793140},\
    "secondary":{"used_percent":24.0,"window_minutes":10080,"resets_at":1789323920}}}}
    """

    private static let turnContext = """
    {"timestamp":"2026-09-07T13:38:15.797Z","type":"turn_context",\
    "payload":{"model":"gpt-5.6-sol","effort":"high"}}
    """

    /// What a rollout is mostly made of, and what must never be parsed: one `event_msg` carrying
    /// content, at the size those really reach.
    private static func conversation(_ bytes: Int = 200_000) -> String {
        let text = String(repeating: "x", count: bytes)
        return #"{"timestamp":"2026-09-07T13:38:20.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"text":"\#(text)"}}}"#
    }

    private func rollout(_ lines: [String]) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchling-rollout-\(UUID().uuidString).jsonl")
        try! lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func scan(_ lines: [String]) -> CodexRollout {
        let path = rollout(lines)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return CodexRolloutReader.scan(fileAt: path, after: nil).rollout
    }

    /// Codex's own calculation, ported so the row and `/status` agree rather than nearly agree. With a
    /// 258,400 window and 16,902 tokens: 246,400 effective, 4,902 used, 98% left — so 2% used.
    @Test("the context percentage is the one Codex would show")
    func contextMatchesCodex() {
        let metrics = scan([Self.tokenCount]).metrics
        #expect(metrics?.contextUsedPercent == 2)
        #expect(metrics?.contextWindowSize == 258_400)
        #expect(metrics?.contextWindowLabel == "258k")
    }

    /// The baseline is the context a session starts with before anyone has spoken. Without subtracting
    /// it from both sides, a fresh session reads as several per cent used — true of the window, and not
    /// of the person.
    @Test("a session that has said nothing reads as empty, not as the baseline")
    func baselineIsNotChargedToTheUser() {
        #expect(CodexRolloutReader.contextUsedPercent(tokens: 12_000, window: 258_400) == 0)
        #expect(CodexRolloutReader.contextUsedPercent(tokens: 200, window: 258_400) == 0)
        // And a window smaller than the baseline yields nothing rather than a divide by zero.
        #expect(CodexRolloutReader.contextUsedPercent(tokens: 500, window: 8_000) == nil)
        #expect(CodexRolloutReader.contextUsedPercent(tokens: nil, window: 258_400) == nil)
    }

    /// 300 and 10080 minutes are the same two windows Claude Code reports, which is what lets one set
    /// of rules arbitrate both.
    @Test("the rate limits are the five-hour and seven-day windows")
    func usageWindows() throws {
        let usage = try #require(scan([Self.tokenCount]).usage)
        #expect(usage.fiveHour?.usedPercentage == 77)
        #expect(usage.sevenDay?.usedPercentage == 24)
        #expect(usage.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_788_793_140))
        // The rollout's own timestamp, not the moment it was read: this line was written when the
        // reading was taken, unlike a status line that writes whenever it renders.
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-07T13:38:32Z"))
        #expect(abs(usage.writtenAt.timeIntervalSince(expected)) < 1)
    }

    /// Effort comes from the turn's context; the model does not, because every hook payload carries it
    /// and a rollout that has grown past what this looks through would not.
    @Test("the effort comes from the turn's own context, and combines with the token count")
    func effortCombinesWithContext() {
        let metrics = scan([Self.turnContext, Self.tokenCount]).metrics
        #expect(metrics?.effort == "high")
        #expect(metrics?.contextUsedPercent == 2)
        #expect(metrics?.model == nil, "the hook says which model, not this")
    }

    /// The load-bearing test. A conversation record is refused on its length before anything looks at
    /// it, so the text cannot reach a parser however the file is shaped.
    @Test("a conversation record is never read")
    func conversationIsRefused() {
        let long = Self.conversation()
        #expect(long.utf8.count > CodexRolloutReader.maxLineLength)

        let found = scan([Self.turnContext, long, Self.tokenCount, long])
        #expect(found.metrics?.contextUsedPercent == 2, "the records wanted are still found past it")
        #expect(found.usage?.fiveHour?.usedPercentage == 77)
    }

    /// Read backwards, so the newest reading wins without reading a rollout that has grown all day.
    @Test("the newest reading is the one taken")
    func newestWins() throws {
        let older = Self.tokenCount.replacingOccurrences(of: "\"used_percent\":77.0", with: "\"used_percent\":10.0")
        let usage = try #require(scan([older, Self.conversation(50_000), Self.tokenCount]).usage)
        #expect(usage.fiveHour?.usedPercentage == 77)
    }

    /// A turn's context is written before the token count that closes the turn, so reading backwards
    /// during a turn in progress finds it first. Gated on the whole reading rather than on the field
    /// wanted, that made the numbers unreadable for the entire duration of the turn somebody is
    /// watching — and the row's meter was wiped rather than left stale.
    @Test("a turn's context newer than the token count does not hide the numbers")
    func turnContextDoesNotMaskTheTokenCount() {
        let found = scan([Self.tokenCount, Self.turnContext])
        #expect(found.metrics?.contextUsedPercent == 2)
        #expect(found.metrics?.contextWindowSize == 258_400)
        #expect(found.metrics?.effort == "high", "and the effort is still picked up")
    }

    /// Only a length cap and a substring got the line this far. A short record of another kind carrying
    /// the same word and an `info` object would have been read as a reading.
    @Test("a record that merely mentions the word is not read as one")
    func decoyIsRefused() {
        let decoy = #"{"timestamp":"2026-09-07T13:38:00.000Z","type":"event_msg","payload":{"type":"item_completed","note":"token_count","info":{"model_context_window":999,"last_token_usage":{"total_tokens":900}}}}"#
        let found = scan([decoy])
        #expect(found.isEmpty, "its type is not one of the two")
    }

    @Test("a rollout with nothing in it yields nothing rather than zeroes")
    func emptyRollout() {
        #expect(scan([Self.conversation(20_000)]).isEmpty)
        #expect(scan([]).isEmpty)
    }

    /// A record straddling a chunk boundary would otherwise parse as two broken halves and be lost.
    @Test("a record split across chunks is still found")
    func recordAcrossChunkBoundary() {
        var lines: [String] = []
        // Enough padding to push the records well past one chunk from the end.
        while lines.reduce(0) { $0 + $1.utf8.count + 1 } < CodexRolloutReader.chunkSize * 2 {
            lines.append(Self.conversation(4_000))
        }
        let found = scan([Self.turnContext, Self.tokenCount] + lines)
        #expect(found.metrics?.contextUsedPercent == 2)
        #expect(found.usage?.fiveHour?.usedPercentage == 77)
    }

    /// A rollout is read again on every event, and a scan is handed what the last one found. What the
    /// row must not do is lose a percentage because the newest records happen not to carry one.
    @Test("a scan that finds no percentage keeps the one before it")
    func carriesThePercentageForward() throws {
        let previous = CodexRolloutScan(rollout: scan([Self.tokenCount]), readTo: 0)
        #expect(previous.rollout.metrics?.contextUsedPercent == 2)

        // A turn in progress, with the token count that closes it out of reach: this record alone
        // makes `metrics` non-nil carrying nothing but the effort, which is what a carry keyed on the
        // reading rather than on the field then took for an answer.
        let path = rollout([Self.turnContext])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let found = CodexRolloutReader.scan(fileAt: path, after: previous).rollout

        #expect(found.metrics?.contextUsedPercent == 2, "still the last figure known, not nil")
        #expect(found.metrics?.contextWindowSize == 258_400)
        #expect(found.metrics?.effort == "high")
        #expect(found.usage?.fiveHour?.usedPercentage == 77, "and the limits carry the same way")
    }

    /// A rollout grows on every message and is read again on every event. Everything below where the
    /// last scan reached was already read, so only the appended bytes are looked at again.
    @Test("only what has arrived since the last scan is read again")
    func onlyNewBytesAreScanned() throws {
        let path = rollout([Self.turnContext, Self.tokenCount])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        )

        // A scan told the whole file was already read finds nothing new in it, and answers with what
        // it was handed rather than walking it again.
        let previous = CodexRolloutScan(rollout: CodexRollout(), readTo: UInt64(size))
        #expect(CodexRolloutReader.scan(fileAt: path, after: previous).rollout.isEmpty)

        // Told the file was shorter, it reads from there — and a chunk is taken back from the end, so
        // a record straddling that point is still read whole.
        let partial = CodexRolloutScan(rollout: CodexRollout(), readTo: UInt64(size - 20))
        let found = CodexRolloutReader.scan(fileAt: path, after: partial).rollout
        #expect(found.metrics?.contextUsedPercent == 2)
        #expect(found.usage?.fiveHour?.usedPercentage == 77)
    }

    /// A rollout that shrank was replaced rather than appended to, and nothing known about it holds —
    /// including a percentage that would otherwise be shown for a session it no longer describes.
    @Test("a replaced rollout carries nothing forward")
    func truncationDiscardsTheCarry() {
        let previous = CodexRolloutScan(rollout: scan([Self.tokenCount]), readTo: 10_000_000)
        let path = rollout([Self.turnContext])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let found = CodexRolloutReader.scan(fileAt: path, after: previous).rollout
        #expect(found.metrics?.contextUsedPercent == nil)
        #expect(found.usage == nil)
    }

    /// The carry is a fallback, never a preference: a fresh reading replaces it outright.
    @Test("a newer percentage wins over the carried one")
    func aFreshPercentageReplacesTheCarry() throws {
        let previous = CodexRolloutScan(rollout: scan([Self.tokenCount]), readTo: 0)

        let fuller = Self.tokenCount
            .replacingOccurrences(of: "\"last_token_usage\":{\"input_tokens\":16491,\"total_tokens\":16902}",
                                  with: "\"last_token_usage\":{\"input_tokens\":16491,\"total_tokens\":135102}")
        let next = rollout([fuller])
        defer { try? FileManager.default.removeItem(atPath: next) }

        let found = CodexRolloutReader.scan(fileAt: next, after: previous).rollout
        #expect(found.metrics?.contextUsedPercent == 50, "246,400 effective, 123,102 used")
    }

    /// Reading a megabyte to put a stale percentage on a row is not a trade worth making.
    @Test("it stops looking rather than reading a whole rollout")
    func scanIsBounded() {
        var lines: [String] = [Self.turnContext, Self.tokenCount]
        var size = 0
        while size < CodexRolloutReader.maxBytesScanned + 200_000 {
            let line = Self.conversation(20_000)
            size += line.utf8.count + 1
            lines.append(line)
        }
        #expect(scan(lines).isEmpty, "past the limit it is absent rather than expensive")
    }
}

/// The name Codex derives, which is what `/status` shows and what a row falls back to a directory
/// without. Entry shapes taken from a real `session_index.jsonl`.
@Suite("CodexNameReader")
@MainActor
struct CodexNameTests {
    private func index(_ lines: [String]) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchling-index-\(UUID().uuidString).jsonl")
        try! lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The entry a session writes first is the prompt; the derived name replaces it seconds later. Read
    /// forwards, every row would be named after whatever was typed at it.
    @Test("the newest name for an id is the one taken")
    func newestNameWins() {
        let path = index([
            #"{"id":"a","thread_name":"Whats the weather in Krakow today?","updated_at":"2026-09-07T13:47:08.601518Z"}"#,
            #"{"id":"b","thread_name":"Create pixel art logos","updated_at":"2026-09-07T13:38:20.658338Z"}"#,
            #"{"id":"a","thread_name":"Check Krakow weather","updated_at":"2026-09-07T13:47:12.680574Z"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = CodexNameReader.scan(fileAt: path)
        #expect(names["a"] == "Check Krakow weather")
        #expect(names["b"] == "Create pixel art logos")
    }

    @Test("a line it cannot read costs only that line")
    func malformedLinesAreSkipped() {
        let path = index([
            "{{{ not json",
            #"{"id":"a","updated_at":"2026-09-07T13:47:08Z"}"#,
            #"{"thread_name":"no id here"}"#,
            #"{"id":"b","thread_name":""}"#,
            #"{"id":"c","thread_name":"Check Krakow weather","updated_at":"2026-09-07T13:47:12Z"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = CodexNameReader.scan(fileAt: path)
        #expect(names == ["c": "Check Krakow weather"], "an empty name is no name")
    }

    /// Derived from the rollout the hook reports rather than from `CODEX_HOME`: that variable belongs to
    /// a terminal, and a widget launched at login inherits nothing from one.
    @Test("the index is found beside the sessions directory the rollout sits under")
    func indexPathIsDerived() {
        #expect(
            CodexNameReader.indexPath(forRollout: "/h/.codex/sessions/2026/09/07/rollout-2026-09-07T15-12-44-abc.jsonl")
                == "/h/.codex/session_index.jsonl"
        )
        // A relocated home is followed without being told about it.
        #expect(
            CodexNameReader.indexPath(forRollout: "/somewhere/else/sessions/2026/09/07/rollout-abc.jsonl")
                == "/somewhere/else/session_index.jsonl"
        )
        #expect(CodexNameReader.indexPath(forRollout: "/rollout.jsonl") == nil)
    }

    @Test("a missing index is nothing rather than a failure")
    func missingIndex() {
        #expect(CodexNameReader.scan(fileAt: "/nowhere/session_index.jsonl").isEmpty)
    }
}
