//
//  Which launchd job, if any, is keeping this process alive.
//
//  Both ways of installing the widget register a job with `KeepAlive` set, which is why quitting it
//  has never worked: `NSApp.terminate` ends the process and launchd starts another within the second.
//  Stopping it for real means telling launchd to let go, and that needs the job's label — of which
//  there are two, plus the case of no job at all.
//
//  The process issuing the bootout is inside the job being torn down, so it does not outlive the
//  request. That is fine and is the point: launchd acts on the request once it has it, and what it
//  does is kill us.
//

import Foundation

enum LaunchAgent {
    struct Job: Equatable, Sendable {
        let label: String
        /// What a person has to run to get the widget back, which is not the same command for both.
        let restartCommand: String
        /// And what to run by hand if this app fails to stop it, which is the only thing left to say
        /// when the button did not work.
        let stopCommand: String
    }

    /// `brew services` writes the first, `make autostart` the second. Nothing else starts this app
    /// under launchd — anywhere else it was launched by hand and can simply be terminated.
    static let known: [Job] = [
        Job(
            label: "homebrew.mxcl.notchling",
            restartCommand: "brew services start notchling",
            stopCommand: "brew services stop notchling"
        ),
        // `make autostart` rather than the `launchctl bootstrap` it wraps: anyone running under this
        // label installed from source has the checkout, and the raw command is three lines of wrapped
        // path in an alert that has room for one.
        Job(
            label: "local.notchling",
            restartCommand: "make autostart",
            stopCommand: "make no-autostart"
        ),
    ]

    nonisolated static func serviceTarget(uid: uid_t, label: String) -> String {
        "gui/\(uid)/\(label)"
    }

    /// The `pid = N` line of `launchctl print`. Nested sections repeat the key at deeper indentation,
    /// so this takes the first one — the job's own, which launchd prints before any of them.
    nonisolated static func pid(inPrintOutput output: String) -> pid_t? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid ") || trimmed.hasPrefix("pid=") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let parsed = pid_t(value) { return parsed }
        }
        return nil
    }

    /// The job running *this* process, or nil when launchd is not what started it.
    ///
    /// Matched by pid rather than by the label existing: a leftover job for the other install method,
    /// or one pointing at a copy that is not this one, must not be the thing a stop button boots out.
    nonisolated static func owner(
        ofPID pid: pid_t,
        uid: uid_t = getuid(),
        describe: (String) -> String? = { launchctl(["print", $0]) }
    ) -> Job? {
        for job in known {
            guard let output = describe(serviceTarget(uid: uid, label: job.label)) else { continue }
            if LaunchAgent.pid(inPrintOutput: output) == pid { return job }
        }
        return nil
    }

    /// Asks launchd to unload the job. The plist stays where it is, so this stops the widget now and
    /// leaves it to come back at the next login — which is why the button that calls this says so
    /// rather than promising it is gone.
    ///
    /// Ordinarily does not return: launchd tears the job down, and the caller is inside it.
    @discardableResult
    nonisolated static func bootout(_ job: Job, uid: uid_t = getuid()) -> Bool {
        launchctl(["bootout", serviceTarget(uid: uid, label: job.label)]) != nil
    }

    /// Exit codes that mean the job is going away.
    ///
    /// Measured as 0 against a live job. `EINPROGRESS` is accepted alongside it because launchd
    /// reports it for a job that is still winding down, and treating "in progress" as failure would
    /// tell somebody the stop did not work while it was working.
    nonisolated static func isSuccess(exitCode: Int32) -> Bool {
        exitCode == 0 || exitCode == EINPROGRESS
    }

    /// How long launchd is given to answer before the widget stops waiting on it. Generous: these
    /// calls are milliseconds in practice, and the only thing this bound exists for is a launchd that
    /// never answers at all.
    private static let timeout: TimeInterval = 3

    /// nil when `launchctl` could not be run, did not answer, or exited for a reason that is not the
    /// job going away — 113 is the one that matters, and it means the label is not registered.
    ///
    /// Waiting before reading is safe here only because the output is small: the largest `launchctl
    /// print` on this machine was 10KB against a 64KB pipe buffer, so the process cannot block writing
    /// and is always gone by the time the pipe is drained.
    nonisolated private static func launchctl(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Set before `run()`: a process that has already exited never calls a handler attached after.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            Log.diagnostics.error("could not run launchctl: \((error as NSError).code, privacy: .public)")
            return nil
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            Log.diagnostics.error("launchctl did not answer within \(Int(timeout), privacy: .public)s")
            return nil
        }

        guard isSuccess(exitCode: process.terminationStatus) else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
