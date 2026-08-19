import Foundation
import Testing

@testable import Notchling

/// A counter the watch queue and the test thread both touch.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Polls rather than sleeps a fixed amount: a vnode event normally lands in single-digit
/// milliseconds, and the timeout is only here so a failure fails instead of hanging.
private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

@Suite("DirectoryWatcher")
struct DirectoryWatcherTests {
    private func touch(_ name: String, in directory: URL) {
        try! Data("{}".utf8).write(to: directory.appendingPathComponent(name))
    }

    @Test("a file appearing in the directory reaches the handler")
    func firesOnWrite() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let signal = Signal()
        let watcher = DirectoryWatcher(
            url: directory,
            queue: DispatchQueue(label: "test.watch")
        ) { signal.increment() }
        watcher.start()
        defer { watcher.stop() }

        touch("001.json", in: directory)
        #expect(eventually { signal.count > 0 })
    }

    @Test("the watch survives start and stop arriving together from many threads")
    func concurrentStartStop() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let signal = Signal()
        let watcher = DirectoryWatcher(
            url: directory,
            queue: DispatchQueue(label: "test.watch")
        ) { signal.increment() }

        // The shape the app produces at quit: the MainActor tearing the watch down while the watch
        // queue restarts it. Racing them unsynchronised could leave a source cancelled and never
        // replaced — a widget that stays running and stops seeing anything.
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            if iteration.isMultiple(of: 2) { watcher.start() } else { watcher.stop() }
        }

        watcher.start()
        defer { watcher.stop() }

        touch("002.json", in: directory)
        #expect(eventually { signal.count > 0 }, "the watch must still be live after the race")
    }

    @Test("nothing arrives after stop")
    func silentAfterStop() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let signal = Signal()
        let watcher = DirectoryWatcher(
            url: directory,
            queue: DispatchQueue(label: "test.watch")
        ) { signal.increment() }
        watcher.start()

        touch("003.json", in: directory)
        #expect(eventually { signal.count > 0 })

        watcher.stop()
        let afterStop = signal.count
        touch("004.json", in: directory)
        // No polling here: this is an absence, and the only honest way to check one is to give it
        // long enough that an event would have arrived.
        usleep(200_000)
        #expect(signal.count == afterStop)
    }
}
