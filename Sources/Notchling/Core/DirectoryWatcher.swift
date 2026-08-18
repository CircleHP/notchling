//
//  A vnode watch on a directory. Always pair it with a slow polling sweep: an in-place rewrite of an
//  existing file does not reliably produce a directory-level event, and Claude Code rewrites
//  `~/.claude/sessions/<pid>.json` in place when a session changes status.
//

import Foundation

final class DirectoryWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let handler: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(url: URL, queue: DispatchQueue, handler: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        stop()

        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        descriptor = open(url.path, O_EVTONLY)
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
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.start() }
            }
            self.handler()
        }

        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }

        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
