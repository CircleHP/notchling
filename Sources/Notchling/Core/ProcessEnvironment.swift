//
//  Recovers terminal identity for a session we received no hook event from — one already running
//  before the app launched, or whose hooks are not installed. `ps eww -p <pid>` prints a process's
//  full environment for processes owned by the same user.
//

import Foundation

struct TerminalIdentity {
    var focusURL: String?
    var warpSessionID: String?
    var termProgram: String?
    var hostBundleID: String?
    var tty: String?
    /// argv, used to tell a real background agent from a pooled spare. See `Session.isPooledSpare`.
    var command: String?
}

@MainActor
final class ProcessEnvironmentReader {
    private let queue = DispatchQueue(label: "local.notchling.psenv", qos: .utility)
    private var cache: [Int32: TerminalIdentity] = [:]
    private var inFlight: Set<Int32> = []
    /// Bumped by `forget`, so a read still running for the *previous* owner of a pid cannot write its
    /// answer into the cache after the pid has been reused.
    private var generation: [Int32: Int] = [:]

    /// A process's environment is fixed at exec time, so one read per pid is enough — for as long as
    /// that pid means the same process. It stops meaning it when the process dies, which is what
    /// `forget` is for.
    /// The callback is `@MainActor` because that is where it runs, and `@Sendable` because it
    /// travels through the queue to get there — the two together are what say "handed over, then
    /// called at home" rather than "called wherever it lands".
    func read(pid: Int32, completion: @escaping @MainActor @Sendable (TerminalIdentity) -> Void) {
        if let cached = cache[pid] {
            completion(cached)
            return
        }
        guard !inFlight.contains(pid) else { return }
        inFlight.insert(pid)
        let readGeneration = generation[pid, default: 0]

        queue.async {
            let identity = Self.readSynchronously(pid: pid)
            // Weak, like every other task in the app: `ps` can take a moment, and a reader that has been
            // torn down in the meantime has no cache left worth filling.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(pid)
                guard self.generation[pid, default: 0] == readGeneration else { return }
                self.cache[pid] = identity
                completion(identity)
            }
        }
    }

    /// Drop what is known about a pid, because the process behind it is gone. macOS reuses pids, and a
    /// cached answer from the previous owner is worse than no answer: it names the wrong terminal.
    func forget(pid: Int32) {
        cache.removeValue(forKey: pid)
        inFlight.remove(pid)
        generation[pid, default: 0] += 1
    }

    // MARK: - Parsing

    /// All four have values that cannot contain spaces, which is what makes parsing `ps eww` output
    /// tractable: it prints `KEY=VALUE` pairs space-separated on one line, and values in general
    /// *can* contain spaces, so a whitespace split would be wrong. Anchoring on ` KEY=` and reading
    /// to the next space is correct for these specific keys only.
    nonisolated private static let interestingKeys = [
        "WARP_FOCUS_URL",
        "WARP_TERMINAL_SESSION_UUID",
        "TERM_PROGRAM",
        "__CFBundleIdentifier",
    ]

    nonisolated private static func readSynchronously(pid: Int32) -> TerminalIdentity {
        var identity = TerminalIdentity()

        if let output = run("/bin/ps", ["eww", "-p", String(pid)]) {
            let values = parse(environmentDump: output)
            identity.focusURL = values["WARP_FOCUS_URL"]
            identity.warpSessionID = values["WARP_TERMINAL_SESSION_UUID"]
            identity.termProgram = values["TERM_PROGRAM"]
            identity.hostBundleID = values["__CFBundleIdentifier"]
        }

        // tty and argv in one call. Output is `<tty> <command...>`, tty `??` when there is none.
        if let line = run("/bin/ps", ["-o", "tty=,command=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
        {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let tty = parts.first, tty != "??" {
                identity.tty = "/dev/\(tty)"
            }
            if parts.count > 1 {
                identity.command = String(parts[1])
            }
        }

        // A Warp session that lacks the focus URL can still be reconstructed from the uuid.
        if identity.focusURL == nil, let uuid = identity.warpSessionID {
            identity.focusURL = "warp://session/\(uuid)"
        }

        return identity
    }

    nonisolated static func parse(environmentDump output: String) -> [String: String] {
        var result: [String: String] = [:]

        for key in interestingKeys {
            // Match at a token boundary, so `TERM_PROGRAM` cannot match inside
            // `TERM_PROGRAM_VERSION`, and read to the next whitespace.
            let pattern = "(?:^|[ \\t])\(NSRegularExpression.escapedPattern(for: key))=([^ \\t\\n]*)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex ..< output.endIndex, in: output)
            guard let match = regex.firstMatch(in: output, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: output)
            else { continue }
            let value = String(output[valueRange])
            if !value.isEmpty { result[key] = value }
        }

        return result
    }

    nonisolated private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
