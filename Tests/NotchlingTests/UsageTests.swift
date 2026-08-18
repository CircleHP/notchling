import Foundation
import Testing

@testable import Notchling

@Suite("UsageWindow")
struct UsageWindowTests {
    @Test("remaining is the complement of used, floored at zero")
    func remaining() {
        #expect(UsageWindow(usedPercentage: 0).remainingPercentage == 100)
        #expect(UsageWindow(usedPercentage: 81).remainingPercentage == 19)
        #expect(UsageWindow(usedPercentage: 100).remainingPercentage == 0)
        #expect(UsageWindow(usedPercentage: 140).remainingPercentage == 0, "never negative")
    }

    @Test("hasReset means the numbers describe a window that no longer exists")
    func hasReset() {
        #expect(UsageWindow(usedPercentage: 50, resetsAt: nil).hasReset == false)
        #expect(UsageWindow(usedPercentage: 50, resetsAt: .now.addingTimeInterval(600)).hasReset == false)
        #expect(UsageWindow(usedPercentage: 50, resetsAt: .now.addingTimeInterval(-1)).hasReset == true)
    }

    @Test("resetLabel formats minutes, hours and days")
    func resetLabel() {
        func label(inSeconds: TimeInterval) -> String? {
            UsageWindow(usedPercentage: 0, resetsAt: .now.addingTimeInterval(inSeconds)).resetLabel
        }
        #expect(UsageWindow(usedPercentage: 0, resetsAt: nil).resetLabel == nil)
        #expect(label(inSeconds: -5) == "now")
        #expect(label(inSeconds: 14 * 60 + 30) == "14m")
        #expect(label(inSeconds: 2 * 3600 + 10 * 60 + 30) == "2h10m")
        #expect(label(inSeconds: 5 * 86400 + 22 * 3600 + 30) == "5d22h")
    }
}

@Suite("UsageSnapshot")
struct UsageSnapshotTests {
    @Test("staleness is measured from when the status line last ran")
    func staleness() {
        let window = UsageWindow(usedPercentage: 10)
        let fresh = UsageSnapshot(fiveHour: window, sevenDay: nil, updatedAt: .now)
        #expect(!fresh.isStale)

        let old = UsageSnapshot(fiveHour: window, sevenDay: nil,
                                updatedAt: .now.addingTimeInterval(-(UsageSnapshot.stalenessThreshold + 60)))
        #expect(old.isStale)
    }

    @Test("hasAnything is false only when both windows are missing")
    func hasAnything() {
        let w = UsageWindow(usedPercentage: 1)
        #expect(UsageSnapshot(fiveHour: nil, sevenDay: nil, updatedAt: .now).hasAnything == false)
        #expect(UsageSnapshot(fiveHour: w, sevenDay: nil, updatedAt: .now).hasAnything == true)
        #expect(UsageSnapshot(fiveHour: nil, sevenDay: w, updatedAt: .now).hasAnything == true)
    }
}

@Suite("UsageReader")
@MainActor
struct UsageReaderTests {
    private func write(_ json: String, to directory: URL) -> URL {
        let url = directory.appendingPathComponent("usage.json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("reads what statusline-usage.sh writes")
    func readsRealShape() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resets = Date(timeIntervalSince1970: 1_800_000_000)
        let url = write("""
        {"v":1,"ts":1700000000,"fiveHourUsedPercent":38.5,"fiveHourResetsAt":\(resets.timeIntervalSince1970),
         "sevenDayUsedPercent":4,"sevenDayResetsAt":null}
        """, to: dir)

        let snapshot = try! #require(UsageReader.read(from: url))
        #expect(snapshot.fiveHour?.usedPercentage == 38.5)
        #expect(snapshot.fiveHour?.resetsAt == resets)
        #expect(snapshot.sevenDay?.usedPercentage == 4)
        #expect(snapshot.sevenDay?.resetsAt == nil)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("percentages are clamped into 0…100")
    func clamping() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = write(#"{"v":1,"ts":1,"fiveHourUsedPercent":-5,"sevenDayUsedPercent":150}"#, to: dir)
        let snapshot = try! #require(UsageReader.read(from: url))
        #expect(snapshot.fiveHour?.usedPercentage == 0)
        #expect(snapshot.sevenDay?.usedPercentage == 100)
    }

    @Test("a payload carrying no rate limits reads as nothing at all")
    func allNullIsNil() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // `claude -p` reports null rate limits. The script now refuses to write this, but a file left
        // by an older version must still read as absent rather than as "0% used".
        let url = write(#"{"v":1,"ts":1,"fiveHourUsedPercent":null,"sevenDayUsedPercent":null}"#, to: dir)
        #expect(UsageReader.read(from: url) == nil)
    }

    @Test("missing, unparseable and wrong-version files all read as nothing")
    func degradesQuietly() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(UsageReader.read(from: dir.appendingPathComponent("absent.json")) == nil)
        #expect(UsageReader.read(from: write("not json", to: dir)) == nil)
        #expect(UsageReader.read(from: write(#"{"v":99,"ts":1,"fiveHourUsedPercent":10}"#, to: dir)) == nil,
                "a future schema is ignored rather than misread")
    }
}
