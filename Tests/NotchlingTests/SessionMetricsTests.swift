import Foundation
import Testing

@testable import Notchling

@Suite("SessionMetrics")
struct SessionMetricsValueTests {
    @Test("context window is labelled in millions or thousands")
    func contextWindowLabel() {
        func label(_ size: Int?) -> String? {
            SessionMetrics(contextWindowSize: size, updatedAt: .now).contextWindowLabel
        }
        #expect(label(1_000_000) == "1M")
        #expect(label(2_000_000) == "2M")
        #expect(label(200_000) == "200k")
        #expect(label(0) == nil)
        #expect(label(nil) == nil)
    }

    @Test("metrics older than the threshold are treated as unknown")
    func staleness() {
        #expect(!SessionMetrics(updatedAt: .now).isStale)
        let old = SessionMetrics(updatedAt: .now.addingTimeInterval(-(SessionMetrics.stalenessThreshold + 30)))
        #expect(old.isStale, "a status line only runs while its session is on screen")
    }
}

@Suite("SessionMetricsReader")
@MainActor
struct SessionMetricsReaderTests {
    private func write(_ name: String, _ json: String, in dir: URL) {
        try! json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("reads the per-session files the status line writes, keyed by session id")
    func readsPerSession() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        write("aaa.json", """
        {"v":1,"ts":1700000000,"sessionId":"aaa","contextUsedPercent":59,
         "contextWindowSize":1000000,"model":"Opus 5 (1M context)","effort":"high",
         "linesAdded":12,"linesRemoved":3}
        """, in: dir)
        write("bbb.json", #"{"v":1,"ts":1700000001,"sessionId":"bbb","contextUsedPercent":16}"#, in: dir)

        let all = SessionMetricsReader.readAll(in: dir)
        #expect(all.count == 2)
        let a = try! #require(all["aaa"])
        #expect(a.contextUsedPercent == 59)
        #expect(a.model == "Opus 5 (1M context)")
        #expect(a.effort == "high")
        #expect(a.linesAdded == 12)
        #expect(a.contextWindowLabel == "1M")
        #expect(all["bbb"]?.contextUsedPercent == 16)
    }

    @Test("the id inside the file wins over the filename")
    func idInsideFileWins() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("filename-id.json", #"{"v":1,"ts":1,"sessionId":"real-id","contextUsedPercent":5}"#, in: dir)
        let all = SessionMetricsReader.readAll(in: dir)
        #expect(all["real-id"] != nil)
        #expect(all["filename-id"] == nil)
    }

    @Test("falls back to the filename when the file carries no id")
    func filenameFallback() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("from-name.json", #"{"v":1,"ts":1,"contextUsedPercent":5}"#, in: dir)
        #expect(SessionMetricsReader.readAll(in: dir)["from-name"] != nil)
    }

    @Test("junk, hidden files and wrong versions are skipped, not fatal")
    func skipsJunk() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("good.json", #"{"v":1,"ts":1,"sessionId":"good"}"#, in: dir)
        write("bad.json", "{{{", in: dir)
        write("future.json", #"{"v":7,"ts":1,"sessionId":"future"}"#, in: dir)
        write(".hidden.json", #"{"v":1,"ts":1,"sessionId":"hidden"}"#, in: dir)
        write("notjson.txt", #"{"v":1,"ts":1,"sessionId":"txt"}"#, in: dir)

        let all = SessionMetricsReader.readAll(in: dir)
        #expect(Set(all.keys) == ["good"])
    }

    @Test("a missing directory reads as empty")
    func missingDirectory() {
        let dir = makeTempDirectory()
        try? FileManager.default.removeItem(at: dir)
        #expect(SessionMetricsReader.readAll(in: dir).isEmpty)
    }

    @Test("pruning removes files older than the cutoff and keeps the rest")
    func prune() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("old.json", #"{"v":1,"ts":1,"sessionId":"old"}"#, in: dir)
        write("new.json", #"{"v":1,"ts":1,"sessionId":"new"}"#, in: dir)

        let old = dir.appendingPathComponent("old.json")
        try! FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-10 * 86400)], ofItemAtPath: old.path
        )

        SessionMetricsReader.pruneStaleFiles(in: dir, olderThan: 3 * 86400)
        let left = try! FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["new.json"])
    }
}
