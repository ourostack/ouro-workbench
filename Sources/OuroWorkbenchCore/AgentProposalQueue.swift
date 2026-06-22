import Foundation
import CryptoKit

/// File-backed transport for the boss's `workbench_propose` CAPABILITY (never a
/// gate). The boss enqueues an `AgentProposal`; the App's native card picks it up
/// from `pending/`, lets the operator tick/edit/approve, then writes the
/// operator's `AgentProposalResult` to `results/` for the boss to read back.
///
/// Mirrors `WorkbenchActionRequestQueue`'s posture — injected `WorkbenchPaths`
/// (a temp dir in tests), atomic writes, deterministic ordering, and malformed
/// files skipped rather than crashing the long-lived read loop. It is its own
/// queue (distinct directory) so the two transports never share files.
///
/// One file per proposal id keyed by id, so a re-enqueue of the same id replaces
/// the prior pending proposal and a result write replaces the prior result —
/// idempotent by id, the way the boss correlates a proposal to its answer.
public final class AgentProposalQueue {
    /// The proposals root (`…/proposals`). `pending/` and `results/` hang off it.
    public let directoryURL: URL
    /// Pending proposals the App card has not yet resolved.
    public let pendingDirectoryURL: URL
    /// Operator-written results the boss reads back.
    public let resultsDirectoryURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.pendingDirectoryURL = directoryURL.appendingPathComponent("pending", isDirectory: true)
        self.resultsDirectoryURL = directoryURL.appendingPathComponent("results", isDirectory: true)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public convenience init(paths: WorkbenchPaths = .defaultPaths()) {
        self.init(directoryURL: paths.proposalsURL)
    }

    // MARK: - Pending proposals (boss → operator)

    /// Write a proposal into `pending/`, keyed by its id. A second enqueue of the
    /// same id replaces the prior file (the boss re-proposed the same plan), so
    /// the pending set never carries stale duplicates of one id.
    public func enqueue(_ proposal: AgentProposal) throws {
        try FileManager.default.createDirectory(at: pendingDirectoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(proposal)
        try data.write(to: pendingFileURL(for: proposal.id), options: [.atomic])
    }

    /// Decode every pending proposal, skipping any file that doesn't decode, and
    /// return them sorted by id for a deterministic order. A missing directory
    /// (nothing proposed yet) is simply an empty list.
    public func pendingProposals() -> [AgentProposal] {
        decodeAll(in: pendingDirectoryURL, as: AgentProposal.self)
            .sorted { $0.id < $1.id }
    }

    /// Drop a pending proposal once the App has resolved it (operator approved or
    /// dismissed). Idempotent: an unknown id, or a missing directory, is a no-op.
    public func removePending(id: String) {
        try? FileManager.default.removeItem(at: pendingFileURL(for: id))
    }

    // MARK: - Results (operator → boss)

    /// Write the operator's approved decision into `results/`, keyed by the
    /// proposal id. Replaces any prior result for that id (re-approval wins).
    public func writeResult(_ result: AgentProposalResult) throws {
        try FileManager.default.createDirectory(at: resultsDirectoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(result)
        try data.write(to: resultFileURL(for: result.id), options: [.atomic])
    }

    /// Read back the operator's decision for a proposal id. Returns nil when no
    /// result has been written yet, or the file is missing/malformed (the boss
    /// polls until a well-formed result appears).
    public func readResult(id: String) -> AgentProposalResult? {
        guard
            let data = try? Data(contentsOf: resultFileURL(for: id)),
            let result = try? decoder.decode(AgentProposalResult.self, from: data)
        else {
            return nil
        }
        return result
    }

    // MARK: - Internals

    /// One JSON file per id. The id is mapped to a filesystem-safe basename so an
    /// id carrying path separators or other unsafe characters can't escape the
    /// directory or collide on the filesystem.
    private func pendingFileURL(for id: String) -> URL {
        pendingDirectoryURL.appendingPathComponent("\(fileSafe(id)).json")
    }

    private func resultFileURL(for id: String) -> URL {
        resultsDirectoryURL.appendingPathComponent("\(fileSafe(id)).json")
    }

    /// Map an id to a filesystem-safe basename that is total, deterministic, AND
    /// injective (distinct ids → distinct basenames).
    ///
    /// A readable prefix alone is NOT injective: mapping every non-alphanumeric
    /// scalar to `_` collapses `recover-1`, `recover.1`, and `recover/1` to the same
    /// `recover_1`, so the boss (which correlates a proposal to its answer by the
    /// ORIGINAL id) could read back another proposal's result, or a colliding
    /// re-enqueue could silently overwrite a different pending proposal. We restore
    /// injectivity by appending a stable content hash of the FULL id: a SHA-256 hex
    /// prefix. Same id → same hash → same basename (so a re-enqueue/re-result still
    /// replaces the prior file for that id), and distinct ids → distinct hashes (so
    /// they can't collide). The hash is over the full id, so the readable prefix's
    /// 40-scalar cap never causes a collision.
    private func fileSafe(_ id: String) -> String {
        let readable = String(
            id.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
            }
        ).prefix(40)
        let digest = SHA256.hash(data: Data(id.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(readable)-\(digest)"
    }

    /// Decode every `.json` file in `directory` as `T`, skipping undecodable files
    /// and non-`.json` entries. A missing directory yields an empty array.
    private func decodeAll<T: Decodable>(in directory: URL, as type: T.Type) -> [T] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return []
        }
        var decoded: [T] = []
        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let value = try? decoder.decode(T.self, from: data)
            else {
                continue
            }
            decoded.append(value)
        }
        return decoded
    }
}
