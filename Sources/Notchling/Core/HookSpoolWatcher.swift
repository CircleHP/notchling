//
//  Consumes the event files written by `notchling-hook`.
//

import Foundation

@MainActor
final class HookSpoolWatcher {
    nonisolated static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notchling")
        .appendingPathComponent("events")

    private let queue = DispatchQueue(label: "local.notchling.spool", qos: .utility)
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

    /// Read, decode and delete every event file, oldest first.
    ///
    /// Filenames are millisecond-prefixed, so a lexicographic sort is chronological. That matters:
    /// these events drive a state machine, and applying them out of order leaves a session showing
    /// the wrong thing.
    func drain() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }

        let files = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()

        guard !files.isEmpty else { return }

        var events: [HookEvent] = []
        let decoder = JSONDecoder()

        for name in files {
            let url = directory.appendingPathComponent(name)
            defer { try? fileManager.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let event = try? decoder.decode(HookEvent.self, from: data) else { continue }
            guard event.v == 1 else { continue }
            events.append(event)
        }

        guard !events.isEmpty else { return }
        onEvents(events.sorted { $0.ts < $1.ts })
    }
}
