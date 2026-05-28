import Foundation

/// Wraps a `Decodable` so a single element that fails to decode yields `nil`
/// instead of throwing. Decoding `[FailableDecodable<T>]` therefore never
/// fails on a per-element problem — bad elements just come back `nil`.
///
/// Used for persisted workspace collections (projects, process entries,
/// runs) so one corrupt or schema-drifted row can't sink the entire
/// workspace state on load. The init itself never throws.
public struct FailableDecodable<Base: Decodable>: Decodable {
    public let base: Base?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.base = try? container.decode(Base.self)
    }
}

public extension KeyedDecodingContainer {
    /// Decode the array at `key` leniently — present-or-empty, with any
    /// element that fails to decode skipped rather than throwing. The number
    /// of skipped elements is reported via `skipped` for telemetry/logging.
    func decodeLenientArray<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        skipped: inout Int
    ) throws -> [T] {
        guard let wrappers = try decodeIfPresent([FailableDecodable<T>].self, forKey: key) else {
            return []
        }
        let survivors = wrappers.compactMap(\.base)
        skipped += wrappers.count - survivors.count
        return survivors
    }
}
