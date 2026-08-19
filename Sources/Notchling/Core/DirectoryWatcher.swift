//
//  A vnode watch on a directory. Always pair it with a slow polling sweep: an in-place rewrite of an
//  existing file does not reliably produce a directory-level event, and Claude Code rewrites
//  `~/.claude/sessions/<pid>.json` in place when a session changes status.
//

import Foundation

/// Thread safety: `start()` and `stop()` may be called from any thread, and are. The MainActor sets
/// the watch up and tears it down at quit; the watch queue calls `start()` again when the directory
/// it was watching is replaced; `deinit` can run on either. The one piece of mutable state is behind
/// `lock`, and the source is swapped and cancelled as a single step so that two of those callers
/// arriving together cannot leave a source running with nothing holding it.
///
/// `@unchecked Sendable` states that: the synchronisation is the lock rather than anything the
/// compiler can see. `handler` is called on `queue`, so what a caller passes has to be safe there —
/// both of ours only hop straight back to the MainActor.
final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let handler: () -> Void

    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, queue: DispatchQueue, handler: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Local, not a property: the cancel handler below captures it by value, and nothing else
        // ever needs it. Keeping it as state would mean a second thing for the lock to protect and
        // a second way for a stale value to close a descriptor that has been reopened since.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The directory itself moved or was removed: re-open so we keep watching the path
            // rather than a now-orphaned inode.
            let flags = self.currentSource?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.start() }
            }
            self.handler()
        }

        source.setCancelHandler { close(descriptor) }

        lock.lock()
        let previous = self.source
        self.source = source
        lock.unlock()

        // Outside the lock, and after the swap: cancelling runs the previous source's cancel handler,
        // and a watcher that took the lock to do it would be holding it while another thread's
        // `start()` waited to publish the replacement.
        previous?.cancel()
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        lock.unlock()

        source?.cancel()
    }

    /// The live source, or nil if it has been stopped since the event was queued.
    private var currentSource: DispatchSourceFileSystemObject? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }
}
