import Foundation

/// Append-only transcript writer for a terminal session.
///
/// SwiftTerm delivers PTY output on `DispatchQueue.main`, so the append path
/// runs on the main actor for every output chunk — a chatty agent TUI (a
/// full-screen Claude Code / Codex repaint) can fire it hundreds of times a
/// second. We must never block the main actor on disk I/O, or a slow transcript
/// volume janks the whole UI.
///
/// So all disk work happens on a private serial queue. `append(_:)` copies the
/// bytes (`Data` is `Sendable`) and hands them to the queue *asynchronously*,
/// returning immediately; the queue performs the actual `write(contentsOf:)`.
/// The queue is serial/FIFO, so writes land in the order they were appended.
/// `close()` drains the queue with a `sync` barrier before returning, so a quit
/// flushes any outstanding bytes rather than dropping them.
public final class TranscriptRecorder {
    /// Holds the mutable `FileHandle`. Every access happens on the recorder's
    /// serial queue, which is the sole synchronization — hence `@unchecked
    /// Sendable`. We capture the box (not `self`) into the queue closures so
    /// they're clean under `-strict-concurrency=complete`; capturing the
    /// non-`Sendable` recorder itself would be rejected.
    private final class HandleBox: @unchecked Sendable {
        var handle: FileHandle?
        init(_ handle: FileHandle?) { self.handle = handle }
    }

    public let url: URL
    /// Serial queue that owns `box.handle`: every read/write of it happens here,
    /// so the queue itself is the synchronization (no separate lock needed) and
    /// the FIFO ordering guarantees appends are written in order.
    private let queue: DispatchQueue
    private let box: HandleBox

    public init(url: URL) throws {
        self.url = url
        self.queue = DispatchQueue(label: "com.ourostack.workbench.transcript-recorder")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.box = HandleBox(handle)
    }

    /// Test seam: wrap an already-open (or deliberately closed) handle without
    /// touching the filesystem, so the non-fatal write-failure path — a write
    /// onto a dead descriptor — can be exercised. Once constructed it behaves
    /// exactly like the `url` init.
    init(unsafeHandle handle: FileHandle?, url: URL) {
        self.url = url
        self.queue = DispatchQueue(label: "com.ourostack.workbench.transcript-recorder.test")
        self.box = HandleBox(handle)
    }

    deinit {
        close()
    }

    /// Enqueue `bytes` to be written off the main thread and return immediately.
    /// The serial queue preserves append order. Called on the main actor from
    /// the PTY output hot-path, so it must not touch the disk synchronously.
    public func append(_ bytes: ArraySlice<UInt8>) {
        let data = Data(bytes)
        let box = self.box
        queue.async {
            guard let handle = box.handle else {
                return
            }
            // Use the throwing `write(contentsOf:)` rather than the deprecated
            // `write(_:)`, which raises an *uncatchable* Objective-C NSException
            // on disk-full or a bad descriptor and would crash the whole app.
            // A failed transcript append is non-fatal: drop it and keep running.
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Disk full / handle closed underneath us — transcript loses this
                // slice but the session keeps going.
            }
        }
    }

    /// Drain any pending writes and close the file. Synchronous: the `queue.sync`
    /// barrier blocks until every previously-enqueued `append` has been written,
    /// so a quit/finalize flushes outstanding bytes instead of losing them.
    /// Idempotent — a second call after the handle is nil is a no-op.
    public func close() {
        let box = self.box
        queue.sync {
            try? box.handle?.close()
            box.handle = nil
        }
    }
}
