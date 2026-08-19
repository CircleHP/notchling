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

        let marks = TranscriptReader.marks(inFileAt: path)
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

        let marks = TranscriptReader.marks(inFileAt: path)
        #expect(marks.isEmpty)
    }

    @Test("a missing transcript is not an error")
    func missingFile() {
        #expect(TranscriptReader.marks(inFileAt: "/nope/does-not-exist.jsonl").isEmpty)
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
        #expect(TranscriptReader.marks(inFileAt: path).title == "early title")
    }

    @Test("a transcript path is derived from cwd when the hook did not name one")
    func derivedPath() {
        let path = try! #require(TranscriptReader.path(forSession: "abc", cwd: "/Users/me/Desktop/proj"))
        #expect(path.hasSuffix(".claude/projects/-Users-me-Desktop-proj/abc.jsonl"))
        #expect(TranscriptReader.path(forSession: "abc", cwd: "") == nil)
    }
}
