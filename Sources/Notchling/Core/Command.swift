//
//  Running something and waiting for everything it had to say.
//
//  Extracted from `Updates`, which had it first and paid for getting it wrong: a subprocess is not
//  finished when it exits. `terminationHandler` and `readDataToEndOfFile` both unblock on the same
//  event — the child exiting and closing the pipe's write end — so waiting only on termination and
//  then taking the output orders nothing, and the output can legitimately come back empty. A lock
//  makes that memory-safe without making it correct. The read has its own semaphore for that reason.
//
//  Everything that runs a command goes through here: `git` and `brew` behind the update path, and
//  `install-hooks.sh` behind the settings window.
//

import Foundation

enum Command {
    enum Failure: Error, Equatable {
        case timedOut(String)
    }

    struct Result {
        let status: Int32
        let output: String
    }

    /// Blocking. Never call it on the main actor.
    ///
    /// `environment` is merged into this process's own rather than replacing it: a command resolved
    /// from `PATH` — which is most of what anyone configures — stops resolving in a sanitised one.
    nonisolated static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Nothing here is interactive, and a command that stops to ask would otherwise wait for an
        // answer that cannot arrive.
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Drained on another thread so a command that outruns the pipe buffer cannot deadlock against
        // a wait that will never come.
        let collector = OutputCollector()
        let handle = pipe.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collector.drain(handle)
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            reap(process, exited: exited)
            throw Failure.timedOut(executable.lastPathComponent)
        }

        // EOF follows the exit, so this is already signalled or about to be. Bounded anyway: a reader
        // that never finishes must not become a caller that never returns.
        _ = drained.wait(timeout: .now() + 5)
        return Result(status: process.terminationStatus, output: collector.take())
    }

    /// SIGTERM, then SIGKILL if it is ignored, then reap. Without this a timed-out `brew` keeps
    /// running — holding Homebrew's lock — while the panel offers the button again.
    private nonisolated static func reap(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + 5) != .success else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 5)
    }
}

/// Somewhere for a background thread to put a subprocess's output where the thread that started it
/// can read it afterwards. The lock keeps the two accesses safe; what *orders* them is the caller
/// waiting on the drain's own semaphore — see `run(_:_:environment:timeout:)`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func drain(_ handle: FileHandle) {
        let data = handle.readDataToEndOfFile()
        let decoded = String(data: data, encoding: .utf8) ?? ""
        lock.lock()
        text += decoded
        lock.unlock()
    }

    func take() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
