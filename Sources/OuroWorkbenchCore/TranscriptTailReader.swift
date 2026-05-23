import Foundation

public struct TranscriptTail: Equatable, Sendable {
    public var path: String
    public var text: String
    public var truncated: Bool

    public init(path: String, text: String, truncated: Bool) {
        self.path = path
        self.text = text
        self.truncated = truncated
    }
}

public struct TranscriptTailReader: Sendable {
    public var maxBytes: UInt64

    public init(maxBytes: UInt64 = TranscriptTailLimit.defaultBytes) {
        self.maxBytes = maxBytes
    }

    public func read(path: String?) -> TranscriptTail? {
        guard let path, !path.isEmpty, maxBytes > 0 else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            let size = try handle.seekToEnd()
            let offset = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return TranscriptTail(
                path: path,
                text: String(decoding: data, as: UTF8.self),
                truncated: offset > 0
            )
        } catch {
            return nil
        }
    }
}

public enum TranscriptTailLimit {
    public static let defaultBytes: UInt64 = 12_000
    public static let maximumBytes: UInt64 = 64_000

    public static func clamped(_ requested: UInt64?) -> UInt64 {
        min(requested ?? defaultBytes, maximumBytes)
    }
}
