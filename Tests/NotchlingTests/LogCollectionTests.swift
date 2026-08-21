import Foundation
import Testing

@testable import Notchling

@Suite("LogCollection")
struct LogCollectionTests {
    /// The reason the button exists. `Logger` does not persist `.info`, which is every line this app
    /// writes short of an error, so the obvious `log show` invocation comes back empty and reads as
    /// "nothing went wrong" — which is the one answer a collected log must never give by accident.
    @Test("the scan asks for info level, or it collects nothing")
    func infoLevelIsRequested() {
        #expect(LogCollection.arguments().contains("--info"))
    }

    @Test("the predicate names this app's subsystem and nothing else")
    func predicateIsScoped() {
        let arguments = LogCollection.arguments()
        let index = try! #require(arguments.firstIndex(of: "--predicate"))
        #expect(arguments[index + 1] == "subsystem == \"local.notchling\"")
        #expect(arguments[index + 1].contains(Log.subsystem))
    }

    @Test("the window is passed through rather than baked in")
    func windowIsPassedThrough() {
        let arguments = LogCollection.arguments(last: "30m")
        let index = try! #require(arguments.firstIndex(of: "--last"))
        #expect(arguments[index + 1] == "30m")
    }

    /// Pruning sorts by name, so the name has to sort chronologically. A locale-dependent or
    /// day-first format would compile, look right, and delete the wrong file.
    @Test("names sort chronologically as plain text")
    func namesSortByTime() {
        let earlier = LogCollection.filename(at: Date(timeIntervalSince1970: 1_000_000))
        let later = LogCollection.filename(at: Date(timeIntervalSince1970: 1_000_000 + 86_400))
        #expect(earlier < later)
        #expect(earlier.hasPrefix("notchling-"))
        #expect(earlier.hasSuffix(".log"))
    }

    @Test("two collections in the same second do not collide")
    func namesAreSecondResolution() {
        let first = LogCollection.filename(at: Date(timeIntervalSince1970: 1_000_000))
        let second = LogCollection.filename(at: Date(timeIntervalSince1970: 1_000_001))
        #expect(first != second)
    }

    @Test("pruning keeps the newest and drops the rest")
    func pruneKeepsTheNewest() throws {
        let directory = makeTempDirectory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let names = (0 ..< LogCollection.keep + 3).map {
            LogCollection.filename(at: start.addingTimeInterval(Double($0) * 60))
        }
        for name in names {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }

        LogCollection.prune(in: directory)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(left.count == LogCollection.keep)
        #expect(left == Set(names.suffix(LogCollection.keep)))
    }

    /// This runs against a directory inside the user's home. Anything it did not put there is not its
    /// to remove.
    @Test("pruning leaves files it did not write alone")
    func pruneIgnoresStrangers() throws {
        let directory = makeTempDirectory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for offset in 0 ..< LogCollection.keep + 2 {
            let name = LogCollection.filename(at: start.addingTimeInterval(Double(offset) * 60))
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("notes.txt").path, contents: nil)

        LogCollection.prune(in: directory)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(left.contains("notes.txt"))
        #expect(left.count == LogCollection.keep + 1)
    }

    @Test("a directory that does not exist is not an error")
    func pruneMissingDirectory() {
        LogCollection.prune(in: makeTempDirectory().appendingPathComponent("nope"))
    }
}
