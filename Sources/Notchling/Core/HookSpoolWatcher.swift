//
//  Consumes the event files written by `notchling-hook`.
//

import Foundation

@MainActor
final class HookSpoolWatcher {
    nonisolated static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notchling")
        .appendingPathComponent("events")

    /// Where unreadable events are kept. A subdirectory of the spool, so it travels with it and is
    /// found by anyone looking at why the widget went quiet. Safe to keep in there because both the
    /// drain and the hook's prune act on `.json` files alone.
    nonisolated static let failedDirectoryName = "failed"

    /// How many unreadable events are kept. Reached only when the app cannot read *anything*, and by
    /// then the ones already on disk say everything the next one would.
    nonisolated static let failedCap = 500

    /// How often the set-aside line may repeat. See `setAside(_:)`.
    nonisolated static let setAsideLogInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "local.notchling.spool", qos: .utility)
    private var lastSetAsideLog: Date?

    /// Files that could not be moved into `failed/`. Skipped on later drains rather than read and
    /// re-read for the life of the process: the move only fails for a reason that will not clear by
    /// itself, and the hook's own prune removes them by age.
    private var unmovable: Set<String> = []
    private var watcher: DirectoryWatcher?
    private let onEvents: ([HookEvent]) -> Void
    private let directory: URL

    init(directory: URL = HookSpoolWatcher.directory, onEvents: @escaping ([HookEvent]) -> Void) {
        self.directory = directory
        self.onEvents = onEvents
    }

    func start() {
        watcher = DirectoryWatcher(url: directory, queue: queue) { [weak self] in
            Task { @MainActor in self?.drain() }
        }
        watcher?.start()
        // Also on launch, so events produced while the app was not running are not lost.
        drain()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Read, decode and delete every event file, oldest first, setting aside any this build cannot
    /// read.
    ///
    /// Filenames are millisecond-prefixed, so a lexicographic sort is chronological. That matters:
    /// these events drive a state machine, and applying them out of order leaves a session showing
    /// the wrong thing.
    func drain() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }

        let files = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") && !unmovable.contains($0) }
            .sorted()

        // Anything gone from the directory can stop being remembered.
        unmovable.formIntersection(names)

        guard !files.isEmpty else { return }

        var events: [HookEvent] = []
        var unreadable: [URL] = []
        let decoder = JSONDecoder()

        for name in files {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let event = try? decoder.decode(HookEvent.self, from: data),
                  event.v == HookEvent.schemaVersion
            else {
                unreadable.append(url)
                continue
            }
            try? fileManager.removeItem(at: url)
            events.append(event)
        }

        if !unreadable.isEmpty { setAside(unreadable) }

        guard !events.isEmpty else { return }
        onEvents(events.sorted { $0.ts < $1.ts })
    }

    /// Moves events the app could not read out of the spool instead of deleting them.
    ///
    /// The case that matters is an upgrade: replacing the files leaves the old app running, so a new
    /// hook writing a newer schema feeds a build that predates it. Deleting those would take the
    /// widget silent and destroy the only evidence of why, so they are kept where they can be found.
    /// Nothing reads them back — the events themselves are gone either way, and replaying them into a
    /// running app would drive its state machine backwards.
    private func setAside(_ urls: [URL]) {
        let fileManager = FileManager.default
        let failed = directory.appendingPathComponent(Self.failedDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: failed, withIntermediateDirectories: true)

        var held = (try? fileManager.contentsOfDirectory(atPath: failed.path))?.count ?? 0

        // Throttled, because the case that produces these produces them continuously: a hook writing
        // a schema this build does not know sets aside every event it sends. One line a minute is
        // enough to find out, and enough to stop the log filling with the same sentence.
        let now = Date.now
        if lastSetAsideLog.map({ now.timeIntervalSince($0) > Self.setAsideLogInterval }) ?? true {
            lastSetAsideLog = now
            Log.spool.error(
                """
                \(urls.count, privacy: .public) event(s) could not be read, and were set aside in \
                \(Self.failedDirectoryName, privacy: .public)/ — a hook writing a schema this \
                build does not know, or a corrupt file
                """
            )
        }

        var reportedFull = false

        for url in urls {
            guard held < Self.failedCap else {
                if !reportedFull {
                    reportedFull = true
                    Log.spool.error("the set-aside directory is full; the rest are being dropped")
                }
                try? fileManager.removeItem(at: url)
                continue
            }
            do {
                try fileManager.moveItem(at: url, to: failed.appendingPathComponent(url.lastPathComponent))
                held += 1
            } catch {
                // Left in the spool rather than deleted, and not looked at again. The hook prunes it
                // by age eventually, which is the right outcome if the move never works.
                unmovable.insert(url.lastPathComponent)
            }
        }
    }
}
