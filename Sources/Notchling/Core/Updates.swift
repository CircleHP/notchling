//
//  Finding out that a newer release exists, and installing it.
//
//  Two rules shape all of this.
//
//  The tap is the only honest source. `brew livecheck` reads the *app* repository's latest GitHub
//  release, and a release here is two buttons — the app first, the tap second. Between them livecheck
//  reports a version Homebrew cannot install, so a widget driven by it would prompt, `brew upgrade`
//  would do nothing, and it would prompt again tomorrow until the second button was pressed. What the
//  tap's formula says is what is installable now.
//
//  And no bare `brew` command may run. Measured: `brew outdated notchling` under a clean environment
//  auto-updated Homebrew and refreshed homebrew/core, which would then make the user's next plain
//  `brew upgrade` upgrade everything on the machine. One click here must mean one formula.
//

import Foundation

enum Updates {
    /// Long enough for a slow network, short enough that a hung fetch does not sit there all day.
    static let checkTimeout: TimeInterval = 30
    /// A bottle download and install. Generous because the alternative — killing a half-finished
    /// upgrade — is worse than waiting.
    static let upgradeTimeout: TimeInterval = 600

    enum Failure: Error, Equatable {
        /// Homebrew is busy. Not an error worth alarming anyone with — the answer is to try later.
        case homebrewBusy
        /// The tap could not be fast-forwarded, so `brew` would install the old formula.
        case tapNotFastForward
        case commandFailed(String, Int32)
        case timedOut(String)
    }

    // MARK: - Reading a version out of the formula

    /// The formula carries no `version` field; Homebrew infers it from the release URL. Parsed rather
    /// than asked of `brew`, because asking `brew` is the thing that drags in an auto-update.
    ///
    /// Returns nil rather than guessing when the line does not match. A check that cannot read the
    /// formula must go quiet, never prompt — a wrong version here is a prompt that cannot be satisfied.
    static func version(inFormula source: String) -> String? {
        let pattern = #"releases/download/v(\d+\.\d+\.\d+)/"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[captured])
    }

    /// Whether `candidate` is a later release than `installed`.
    ///
    /// Deliberately an ordering, unlike `InstalledBuild.pendingVersion`, which only asks whether two
    /// versions differ. That one is reporting a build already on the disk either way; this one is
    /// offering to *replace* what is installed, and offering a downgrade to somebody running a build
    /// they made themselves would be wrong.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ value: String) -> [Int] { value.split(separator: ".").map { Int($0) ?? 0 } }
        let new = parts(candidate)
        let old = parts(installed)
        for index in 0 ..< max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Checking

    /// The version the tap is offering, if it is newer than what is installed. Blocking; never call it
    /// on the main actor.
    ///
    /// Fetches into remote-tracking refs and reads the formula from there. Nothing in the working tree
    /// moves, so Homebrew's view of the world is exactly what it was — this is a read, and the machine
    /// is left able to do anything it could do before.
    nonisolated static func available(in install: HomebrewInstall, installedVersion: String) throws -> String? {
        _ = try git(["fetch", "--quiet", "origin"], in: install, timeout: checkTimeout)
        let formula = try git(["show", "origin/main:Formula/notchling.rb"], in: install, timeout: checkTimeout)

        guard let offered = version(inFormula: formula) else {
            Log.updates.error("could not read a version out of the tap's formula")
            return nil
        }
        return isNewer(offered, than: installedVersion) ? offered : nil
    }

    // MARK: - Installing

    /// Fast-forwards the tap and upgrades the formula, appending everything to `~/.notchling/upgrade.log`.
    ///
    /// The fast-forward is not optional. The check deliberately leaves the working tree alone, so at
    /// this point Homebrew still has the old formula — and with auto-update off, which it must be, it
    /// would happily reinstall the version already present and report success.
    nonisolated static func upgrade(in install: HomebrewInstall) throws {
        let log = logURL
        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        append("=== upgrade attempt ===\n", to: log)

        // Every exit from here writes to the log first, because the row that reports a failure sends
        // people to read it. Two of these used to fail before anything had been written, so the file
        // said nothing — or on a first attempt did not exist at all.
        do {
            append(try git(["fetch", "origin"], in: install, timeout: checkTimeout), to: log)
        } catch {
            append("git fetch failed: \(error)\n", to: log)
            throw error
        }

        do {
            append(try git(["merge", "--ff-only", "origin/main"], in: install, timeout: checkTimeout), to: log)
        } catch {
            append("the tap could not be fast-forwarded: \(error)\n", to: log)
            throw Failure.tapNotFastForward
        }

        let result: Result
        do {
            result = try run(
                install.brew,
                ["upgrade", "notchling"],
                environment: brewEnvironment,
                timeout: upgradeTimeout
            )
        } catch {
            append("brew upgrade did not finish: \(error)\n", to: log)
            throw error
        }
        append(result.output, to: log)

        guard result.status == 0 else {
            if result.output.contains("Another active Homebrew process") {
                throw Failure.homebrewBusy
            }
            throw Failure.commandFailed("brew upgrade", result.status)
        }
    }

    static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".notchling")
            .appendingPathComponent("upgrade.log")
    }

    /// `NO_AUTO_UPDATE` keeps the click to one formula instead of refreshing every tap on the machine.
    /// `NO_INSTALL_CLEANUP` stops Homebrew removing the Cellar directory this process is executing out
    /// of while it is still running; the user's own `brew` will clean it up later.
    static let brewEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
    ]

    // MARK: - Running things

    private nonisolated static func git(
        _ arguments: [String],
        in install: HomebrewInstall,
        timeout: TimeInterval
    ) throws -> String {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/git"),
            ["-C", install.tap.path] + arguments,
            environment: [:],
            timeout: timeout
        )
        guard result.status == 0 else {
            throw Failure.commandFailed("git \(arguments.first ?? "")", result.status)
        }
        return result.output
    }

    private struct Result {
        let status: Int32
        let output: String
    }

    /// Waits for the *reader* as well as the process, which is the whole trick.
    ///
    /// `terminationHandler` and `readDataToEndOfFile` both unblock on the same event — the child
    /// exiting and closing the pipe's write end — so waiting only on termination and then taking the
    /// output orders nothing, and the output can legitimately come back empty. A lock makes that
    /// memory-safe without making it correct. The read has its own semaphore for that reason.
    private nonisolated static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
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

    private nonisolated static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Somewhere for a background thread to put a subprocess's output where the thread that started it can
/// read it afterwards. The lock keeps the two accesses safe; what *orders* them is the caller waiting
/// on the drain's own semaphore — see `run(_:_:environment:timeout:)`.
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
