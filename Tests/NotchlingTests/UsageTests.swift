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

@Suite("UsageReader — arbitration across sessions")
@MainActor
struct UsageArbitrationTests {
    private func reading(
        five: Double? = nil,
        fiveResets: Date? = nil,
        seven: Double? = nil,
        sevenResets: Date? = nil,
        writtenAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> UsageReading {
        UsageReading(
            fiveHour: five.map { UsageWindow(usedPercentage: $0, resetsAt: fiveResets) },
            sevenDay: seven.map { UsageWindow(usedPercentage: $0, resetsAt: sevenResets) },
            writtenAt: writtenAt
        )
    }

    private func write(_ json: String, named name: String, in dir: URL) {
        try! json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("the newest write does not win — the highest reading within the window does")
    func highestWithinAWindowWins() {
        let resets = Date(timeIntervalSince1970: 90_000)

        // The busy session measured 62% and wrote it first; the idle one rendered later carrying the
        // rate limits from its own last response, which are older however new its timestamp is.
        let busy = reading(five: 62, fiveResets: resets, writtenAt: Date(timeIntervalSince1970: 1_000))
        let idle = reading(five: 41, fiveResets: resets, writtenAt: Date(timeIntervalSince1970: 2_000))

        let snapshot = try! #require(UsageReader.arbitrate([busy, idle]))
        #expect(snapshot.fiveHour?.usedPercentage == 62, "usage only accumulates inside a window")
    }

    @Test("a window that rolled over wins even though its number is smaller")
    func laterResetWins() {
        let old = reading(
            five: 88,
            fiveResets: Date(timeIntervalSince1970: 90_000),
            writtenAt: Date(timeIntervalSince1970: 1_000)
        )
        let rolled = reading(
            five: 3,
            fiveResets: Date(timeIntervalSince1970: 108_000),
            writtenAt: Date(timeIntervalSince1970: 2_000)
        )

        let snapshot = try! #require(UsageReader.arbitrate([rolled, old]))
        #expect(snapshot.fiveHour?.usedPercentage == 3, "a later reset is the only thing that lets a smaller number win")
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 108_000))
    }

    @Test("each window is decided on its own")
    func windowsAreIndependent() {
        let resets = Date(timeIntervalSince1970: 90_000)
        let a = reading(five: 70, fiveResets: resets, seven: 12, sevenResets: resets)
        let b = reading(five: 20, fiveResets: resets, seven: 40, sevenResets: resets)

        let snapshot = try! #require(UsageReader.arbitrate([a, b]))
        #expect(snapshot.fiveHour?.usedPercentage == 70)
        #expect(snapshot.sevenDay?.usedPercentage == 40)
    }

    @Test("the stamp is the most recent write from any session, whichever reading won")
    func stampIsTheLatestWrite() {
        let resets = Date(timeIntervalSince1970: 90_000)
        let winner = reading(five: 62, fiveResets: resets, writtenAt: Date(timeIntervalSince1970: 1_000))
        let newest = reading(five: 41, fiveResets: resets, writtenAt: Date(timeIntervalSince1970: 5_000))

        let snapshot = try! #require(UsageReader.arbitrate([winner, newest]))
        // Staleness asks whether anything is still reporting, not which reading was adopted.
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 5_000))
    }

    @Test("a reading with no reset time loses to one that has it")
    func datedWindowsBeatUndatedOnes() {
        let dated = reading(five: 10, fiveResets: Date(timeIntervalSince1970: 90_000))
        let undated = reading(five: 95, fiveResets: nil)

        let snapshot = try! #require(UsageReader.arbitrate([undated, dated]))
        #expect(snapshot.fiveHour?.usedPercentage == 10, "a window with no reset cannot be placed in time")
    }

    @Test("nothing to arbitrate reads as nothing")
    func emptyReadsAsNil() {
        #expect(UsageReader.arbitrate([]) == nil)
    }

    @Test("every session's file is read, and only well-formed ones count")
    func readsTheDirectory() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        write(#"{"v":1,"ts":1000,"fiveHourUsedPercent":62,"fiveHourResetsAt":90000}"#, named: "a.json", in: dir)
        write(#"{"v":1,"ts":2000,"fiveHourUsedPercent":41,"fiveHourResetsAt":90000}"#, named: "b.json", in: dir)
        write(#"{"v":99,"ts":3000,"fiveHourUsedPercent":99}"#, named: "wrong-version.json", in: dir)
        write("not json", named: "broken.json", in: dir)
        write(#"{"v":1,"ts":4000,"fiveHourUsedPercent":99}"#, named: ".partial.json.tmp", in: dir)

        let snapshot = try! #require(UsageReader.read(in: dir, legacy: dir.appendingPathComponent("nope.json")))
        #expect(snapshot.fiveHour?.usedPercentage == 62)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test("an empty directory falls back to the shared file, so an upgrade does not blank the bars")
    func fallsBackToTheSharedFile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = dir.appendingPathComponent("usage.json")
        try! #"{"v":1,"ts":1000,"fiveHourUsedPercent":33}"#
            .write(to: legacy, atomically: true, encoding: .utf8)

        let empty = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        let snapshot = try! #require(UsageReader.read(in: empty, legacy: legacy))
        #expect(snapshot.fiveHour?.usedPercentage == 33)
    }
}
