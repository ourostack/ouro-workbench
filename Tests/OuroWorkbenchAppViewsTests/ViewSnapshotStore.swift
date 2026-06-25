#if os(macOS)
import Foundation

/// Record-or-compare store for committed `__Snapshots__/<name>.txt` reference
/// trees (D-U1-2/3/4). References live next to the test source and are read BY
/// PATH (derived from `#filePath`), never bundled (hence the `exclude:` in
/// Package.swift, F-1). On a missing reference (or `recording: true`) it WRITES
/// the reference; otherwise it COMPARES and, on mismatch, writes the actual tree
/// as a `.actual.txt` artifact and returns a `.mismatch` carrying a readable diff
/// message that names both files. All paths are injectable so the store's own
/// tests use a temp dir.
struct ViewSnapshotStore {
    /// Where committed references live (`…/__Snapshots__`).
    let snapshotsDirectory: URL
    /// Where mismatch artifacts are written (`./U1-ax-snapshot-harness/` in CI/local).
    let artifactsDirectory: URL

    init(snapshotsDirectory: URL, artifactsDirectory: URL) {
        self.snapshotsDirectory = snapshotsDirectory
        self.artifactsDirectory = artifactsDirectory
    }

    /// The default store: `__Snapshots__/` is resolved RELATIVE to the test file's
    /// directory (the pointfreeco SnapshotTesting pattern), so no machine-specific
    /// absolute path is baked into any committed reference (L4). Artifacts go to the
    /// unit's artifacts dir.
    static func `default`(
        testFilePath: String,
        artifactsDirectory: URL = defaultArtifactsDirectory()
    ) -> ViewSnapshotStore {
        let testDir = URL(fileURLWithPath: testFilePath).deletingLastPathComponent()
        return ViewSnapshotStore(
            snapshotsDirectory: testDir.appendingPathComponent("__Snapshots__", isDirectory: true),
            artifactsDirectory: artifactsDirectory
        )
    }

    /// `<repo>/worker/tasks/2026-06-24-anneal-visual-testing/U1-ax-snapshot-harness/`,
    /// derived from this source file's location (D-U1-4). Falls back to the temp dir
    /// if the repo layout can't be resolved.
    static func defaultArtifactsDirectory(storeFilePath: String = #filePath) -> URL {
        // …/Tests/OuroWorkbenchAppViewsTests/ViewSnapshotStore.swift → repo root is 2 up from Tests.
        let testsDir = URL(fileURLWithPath: storeFilePath)
            .deletingLastPathComponent()            // OuroWorkbenchAppViewsTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // repo root
        return testsDir
            .appendingPathComponent("worker/tasks/2026-06-24-anneal-visual-testing/U1-ax-snapshot-harness", isDirectory: true)
    }

    /// The reference file URL for a snapshot name.
    func referenceURL(named name: String) -> URL {
        snapshotsDirectory.appendingPathComponent("\(name).txt")
    }

    /// The `.actual.txt` artifact URL for a snapshot name.
    func actualArtifactURL(named name: String) -> URL {
        artifactsDirectory.appendingPathComponent("\(name).actual.txt")
    }

    /// Compare `actual` against the committed reference, or record it.
    ///
    /// - `recording == true` OR no reference on disk → write the reference, return
    ///   `.recorded`.
    /// - reference matches → `.matched`.
    /// - reference differs → write the `.actual.txt` artifact and return
    ///   `.mismatch` with a readable, two-file diff message.
    /// Throws if the reference exists but can't be read as UTF-8 (e.g. it's a
    /// directory) — surfaced as a clear failure, never a crash.
    func compareOrRecord(actual: String, named name: String, recording: Bool) throws -> Outcome {
        let reference = referenceURL(named: name)
        let exists = FileManager.default.fileExists(atPath: reference.path)

        if recording || !exists {
            try write(actual, to: reference)
            return .recorded
        }

        let expected = try readReference(reference)
        if expected == actual {
            return .matched
        }

        let artifactURL = actualArtifactURL(named: name)
        try write(actual, to: artifactURL)
        return .mismatch(Mismatch(
            name: name,
            expected: expected,
            actual: actual,
            referenceURL: reference,
            actualArtifactURL: artifactURL,
            message: diffMessage(name: name, reference: reference, artifact: artifactURL)
        ))
    }

    // MARK: - Internals

    private func readReference(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func diffMessage(name: String, reference: URL, artifact: URL) -> String {
        """
        View snapshot "\(name)" did not match its committed reference.
          reference: \(reference.path)
          actual:    \(artifact.path)
        Re-record intentionally with OURO_SNAPSHOT_RECORD=1 after verifying the change.
        """
    }

    /// The outcome of a compare-or-record.
    enum Outcome: Equatable {
        case recorded
        case matched
        case mismatch(Mismatch)
    }

    /// A failed comparison: both trees + both file URLs + a readable message.
    struct Mismatch: Equatable {
        let name: String
        let expected: String
        let actual: String
        let referenceURL: URL
        let actualArtifactURL: URL
        let message: String
    }
}
#endif
