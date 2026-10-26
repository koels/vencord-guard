import Foundation

/// A kqueue/`DispatchSource` vnode watch on a single path.
///
/// This is the whole reason the guard costs nothing at idle: the kernel holds one file
/// descriptor and wakes the process only when that specific inode changes. There is no timer,
/// no wakeup, and therefore nothing for the CPU or the power assertion machinery to do while
/// Discord sits still.
///
/// A vnode watch follows the *inode*, not the path, so when Discord's updater replaces the
/// whole app bundle the descriptor goes stale and we get `.delete`/`.revoke`. That is a
/// feature: it is precisely the event we care about. `onVanish` re-arms on a bounded backoff.
final class VnodeWatcher {
    private let url: URL
    private let mask: DispatchSource.FileSystemEvent
    private let handler: (DispatchSource.FileSystemEvent) -> Void
    private let queue: DispatchQueue

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var rearmDelays: [Double] = []

    /// Bounded re-arm schedule after the watched inode disappears. A bundle swap takes a few
    /// seconds; a Discord reinstall might take minutes. After this list is exhausted we stop
    /// and rely on the next app-launch notification instead of ticking forever.
    private static let defaultRearm: [Double] = [1, 3, 8, 20, 60, 180, 600]

    init(url: URL,
         mask: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .revoke, .attrib, .extend],
         queue: DispatchQueue,
         handler: @escaping (DispatchSource.FileSystemEvent) -> Void) {
        self.url = url
        self.mask = mask
        self.queue = queue
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        stop()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRearm()
            return false
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            let data = s.data
            self.handler(data)
            if !data.intersection([.delete, .revoke, .rename]).isEmpty {
                // The inode we were holding is gone. Drop it and start looking for its
                // replacement at the same path.
                self.rearmDelays = VnodeWatcher.defaultRearm
                self.stop()
                self.scheduleRearm()
            }
        }
        src.setCancelHandler { [fd = self.fd] in if fd >= 0 { close(fd) } }
        source = src
        src.resume()
        rearmDelays = []
        logDebug("watching \(url.path)")
        return true
    }

    private func scheduleRearm() {
        if rearmDelays.isEmpty { rearmDelays = VnodeWatcher.defaultRearm }
        let delay = rearmDelays.removeFirst()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.source == nil { _ = self.start() }
        }
    }

    /// Force an immediate re-arm attempt (used when some other signal tells us the bundle is back).
    func rearmNow() {
        queue.async { if self.source == nil { _ = self.start() } }
    }

    var isArmed: Bool { source != nil }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    deinit { stop() }
}

/// Reads new bytes appended to a log file and hands complete lines to a callback.
///
/// Strictly incremental: it remembers a byte offset and never re-reads what it has already
/// seen. It is driven by a vnode watch, so there is no polling interval at all. It is only
/// opened while Discord is actually running, and closed again when Discord exits.
final class LogTailer {
    private let url: URL
    private let queue: DispatchQueue
    private let onLine: (String) -> Void
    private var watcher: VnodeWatcher?
    private var offset: UInt64 = 0
    private var carry = ""

    init(url: URL, queue: DispatchQueue, onLine: @escaping (String) -> Void) {
        self.url = url
        self.queue = queue
        self.onLine = onLine
    }

    /// - Parameter fromEnd: start at EOF (normal) or at 0 (replay the whole file).
    func start(fromEnd: Bool = true) {
        stop()
        offset = fromEnd ? (fileSize(url).map(UInt64.init) ?? 0) : 0
        // Read once up front: the log may already have been written to between the process
        // launching and this watch being armed.
        drain()
        watcher = VnodeWatcher(url: url, mask: [.write, .extend, .delete, .rename, .revoke],
                               queue: queue) { [weak self] _ in self?.drain() }
        watcher?.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        carry = ""
    }

    private func drain() {
        guard let size = fileSize(url).map(UInt64.init) else { return }
        if size < offset {
            // Truncated or rotated (Discord recreates renderer_js.log on some launches).
            offset = 0
            carry = ""
        }
        guard size > offset else { return }
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            guard let data = try h.read(upToCount: Int(min(size - offset, 1 << 20))) else { return }
            offset += UInt64(data.count)
            let chunk = carry + (String(data: data, encoding: .utf8) ?? "")
            var lines = chunk.components(separatedBy: "\n")
            carry = lines.removeLast()          // possibly-incomplete trailing line
            if carry.utf8.count > 64_000 { carry = "" }   // pathological single line guard
            for line in lines where !line.isEmpty { onLine(line) }
        } catch {
            logDebug("tail \(url.lastPathComponent): \(error)")
        }
    }

    var isRunning: Bool { watcher != nil }
}
