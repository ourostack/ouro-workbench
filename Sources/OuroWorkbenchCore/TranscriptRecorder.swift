import Foundation

public final class TranscriptRecorder {
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle?.seekToEnd()
    }

    deinit {
        close()
    }

    public func append(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        defer {
            lock.unlock()
        }
        handle?.write(Data(bytes))
    }

    public func close() {
        lock.lock()
        defer {
            lock.unlock()
        }
        try? handle?.close()
        handle = nil
    }
}
