//
//  Collecting what the widget has said about itself, for somebody about to report a bug.
//
//  A healthy app logs nothing at all — see `Log.swift` — so anything this produces is a finding. That
//  is the whole reason it is a button rather than a documented incantation: the incantation needs
//  `--info`, `Logger` does not persist that level without it, and the version people reach for first
//  therefore comes back empty and reads as "nothing was wrong".
//

import Foundation

enum LogCollection {
    /// Far enough back to cover "it did the thing earlier this morning", short enough that the scan
    /// stays quick — `log show` walks the whole store, so the window is the only cost control there is.
    static let window = "6h"

    /// How many collections are kept. Someone diagnosing something clicks this repeatedly, and each
    /// file is the same six hours read again.
    static let keep = 5

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".notchling")
            .appendingPathComponent("logs")
    }

    /// `--info` is not optional. Everything this app logs below `.error` is `.info`, which the store
    /// keeps only when asked — without the flag the output is empty whatever went wrong.
    static func arguments(last: String = window) -> [String] {
        [
            "show",
            "--predicate", "subsystem == \"\(Log.subsystem)\"",
            "--info",
            "--last", last,
            "--style", "compact",
        ]
    }

    /// Sorts chronologically as text, so pruning is a plain sort and the newest file is obvious in a
    /// Finder window that has been opened straight onto it.
    static func filename(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "notchling-\(formatter.string(from: date)).log"
    }

    enum Failure: Error {
        /// `log` exited non-zero. Its own complaint is on stderr, which is captured into the file.
        case logFailed(Int32)
    }

    /// Runs `log show` and returns the file it wrote. Blocking, so never on the main actor: the scan
    /// takes seconds on a machine that has been up for a while.
    nonisolated static func collect(now: Date = .now) throws -> URL {
        let directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let destination = directory.appendingPathComponent(filename(at: now))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments()
        // Both streams into the file: when `log` refuses, its reason is the only useful thing in there.
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.logFailed(process.terminationStatus)
        }

        prune(in: directory)
        return destination
    }

    /// Oldest first by name, which is chronological by construction — see `filename(at:)`.
    nonisolated static func prune(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let files = names.filter { $0.hasPrefix("notchling-") && $0.hasSuffix(".log") }.sorted()
        guard files.count > keep else { return }
        for name in files.prefix(files.count - keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
