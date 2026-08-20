import Foundation
import Testing

@testable import Notchling

@Suite("TranscriptReader")
struct TranscriptReaderTests {
    private func writeTranscript(_ lines: [String]) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchling-transcript-\(UUID().uuidString).jsonl")
        try! lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("takes the newest title and colour, because both are rewritten as they change")
    func newestWins() {
        let path = writeTranscript([
            #"{"type":"ai-title","aiTitle":"first guess","sessionId":"s"}"#,
            #"{"type":"agent-color","agentColor":"red","sessionId":"s"}"#,
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"ai-title","aiTitle":"Ship app via Homebrew","sessionId":"s"}"#,
            #"{"type":"agent-color","agentColor":"green","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let marks = TranscriptReader.scan(fileAt: path, after: nil).marks
        #expect(marks.title == "Ship app via Homebrew")
        #expect(marks.colorName == "green")
    }

    /// A colour is absent unless someone ran `/color`, so 'no marks' has to be an ordinary answer
    /// rather than something the reader has to be told about.
    @Test("a transcript with neither mark yields neither")
    func noMarks() {
        let path = writeTranscript([
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let marks = TranscriptReader.scan(fileAt: path, after: nil).marks
        #expect(marks.isEmpty)
    }

    @Test("a missing transcript is not an error")
    func missingFile() {
        #expect(TranscriptReader.scan(fileAt: "/nope/does-not-exist.jsonl", after: nil).marks.isEmpty)
    }

    /// The reader works backwards in chunks, so a line landing across a chunk boundary is the case
    /// that breaks first: half of it parses as garbage and the mark is silently lost.
    @Test("a mark survives being split across a chunk boundary")
    func acrossChunkBoundary() {
        let filler = String(repeating: "x", count: 4_000)
        var lines = [#"{"type":"ai-title","aiTitle":"early title","sessionId":"s"}"#]
        for index in 0 ..< 120 {
            lines.append(#"{"type":"assistant","pad":"\#(filler)","n":\#(index)}"#)
        }
        let path = writeTranscript(lines)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let size = (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
        #expect(size > TranscriptReader.chunkSize, "the test file must be bigger than one chunk")
        #expect(TranscriptReader.scan(fileAt: path, after: nil).marks.title == "early title")
    }

    /// The reason the scan is incremental: the loop only stops early when *both* marks are found, so
    /// a session that never set a colour never finds one and runs to the byte limit — on every change
    /// to a file that changes with every message.
    @Test("a second scan starts where the first one stopped")
    func onlyReadsWhatIsNew() {
        let filler = String(repeating: "x", count: 4_000)
        var lines = [#"{"type":"ai-title","aiTitle":"first","sessionId":"s"}"#]
        for index in 0 ..< 120 {
            lines.append(#"{"type":"assistant","pad":"\#(filler)","n":\#(index)}"#)
        }
        let path = writeTranscript(lines)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // No colour in the file, so this one runs all the way to the start.
        let first = TranscriptReader.scan(fileAt: path, after: nil)
        #expect(first.marks.title == "first")
        #expect(first.marks.colorName == nil)
        #expect(first.searchedFrom == 0, "having reached the start, there is nothing left below")

        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.seekToEnd()
        handle.write(Data(#"{"type":"agent-color","agentColor":"green","sessionId":"s"}\#n"#.utf8))
        try! handle.close()

        let second = TranscriptReader.scan(fileAt: path, after: first)
        #expect(second.marks.colorName == "green", "the appended mark is picked up")
        #expect(second.marks.title == "first", "and what was already known is kept")
    }

    /// The one a live session actually hits: both marks are known, then the user runs `/color` again.
    /// A scan that stops early because it already has both never looks at what was appended, and the
    /// row keeps the colour it was first given for the rest of the session.
    @Test("a colour changed after both marks are known is still picked up")
    func changedColourIsPickedUp() {
        let path = writeTranscript([
            #"{"type":"ai-title","aiTitle":"Ship it","sessionId":"s"}"#,
            #"{"type":"agent-color","agentColor":"cyan","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = TranscriptReader.scan(fileAt: path, after: nil)
        #expect(first.marks.colorName == "cyan")
        #expect(first.marks.title == "Ship it")

        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.seekToEnd()
        handle.write(Data(#"{"type":"agent-color","agentColor":"green","sessionId":"s"}\#n"#.utf8))
        try! handle.close()

        let second = TranscriptReader.scan(fileAt: path, after: first)
        #expect(second.marks.colorName == "green", "the newer entry wins")
        #expect(second.marks.title == "Ship it", "and the title it did not repeat is kept")
    }

    @Test("a title rewritten later replaces the earlier one")
    func changedTitleIsPickedUp() {
        let path = writeTranscript([
            #"{"type":"ai-title","aiTitle":"First guess","sessionId":"s"}"#,
            #"{"type":"agent-color","agentColor":"blue","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = TranscriptReader.scan(fileAt: path, after: nil)
        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.seekToEnd()
        handle.write(Data(#"{"type":"ai-title","aiTitle":"What it turned out to be","sessionId":"s"}\#n"#.utf8))
        try! handle.close()

        let second = TranscriptReader.scan(fileAt: path, after: first)
        #expect(second.marks.title == "What it turned out to be")
        #expect(second.marks.colorName == "blue")
    }

    @Test("a transcript replaced with a shorter one is read again from scratch")
    func shrunkFileIsRescanned() {
        let path = writeTranscript([#"{"type":"ai-title","aiTitle":"old","sessionId":"s"}"#])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = TranscriptReader.scan(fileAt: path, after: nil)
        #expect(first.marks.title == "old")

        // Same path, different file. Anything remembered about the previous one is meaningless.
        try! #"{"type":"ai-title","aiTitle":"new","sessionId":"s"}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let stale = TranscriptScan(marks: first.marks, searchedFrom: 10_000)
        #expect(TranscriptReader.scan(fileAt: path, after: stale).marks.title == "new")
    }

    /// Carrying a partial line between chunks is what makes a single enormous line cost more than
    /// the scan around it, so lines past the cap are dropped rather than carried.
    @Test("an enormous line does not hide the marks around it")
    func hugeLineIsSkipped() {
        let huge = String(repeating: "y", count: TranscriptReader.maxLineLength + 5_000)
        let path = writeTranscript([
            #"{"type":"ai-title","aiTitle":"kept","sessionId":"s"}"#,
            #"{"type":"assistant","pad":"\#(huge)"}"#,
            #"{"type":"agent-color","agentColor":"blue","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let marks = TranscriptReader.scan(fileAt: path, after: nil).marks
        #expect(marks.colorName == "blue")
        #expect(marks.title == "kept")
    }

    @Test("a transcript path is derived from cwd when the hook did not name one")
    func derivedPath() {
        let path = try! #require(TranscriptReader.path(forSession: "abc", cwd: "/Users/me/Desktop/proj"))
        #expect(path.hasSuffix(".claude/projects/-Users-me-Desktop-proj/abc.jsonl"))
        #expect(TranscriptReader.path(forSession: "abc", cwd: "") == nil)
    }
}
