#if os(macOS)
import XCTest

/// Unit 3a — the store (record/compare/missing/mismatch/artifact) + the
/// `assertViewSnapshot` one-liner. All file IO goes to an INJECTED temp base dir
/// so tests never touch the real `__Snapshots__/`.
final class ViewSnapshotStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: ViewSnapshotStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u1-store-\(UUID().uuidString)", isDirectory: true)
        let artifactsDir = tempDir.appendingPathComponent("artifacts", isDirectory: true)
        store = ViewSnapshotStore(
            snapshotsDirectory: tempDir.appendingPathComponent("__Snapshots__", isDirectory: true),
            artifactsDirectory: artifactsDir
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - (i) missing reference → records it (first run)

    func testMissingReference_recordsAndPasses() throws {
        let result = try store.compareOrRecord(actual: "TREE-A", named: "alpha", recording: false)
        XCTAssertEqual(result, .recorded)
        // The reference file now exists with the actual content.
        let ref = tempDir.appendingPathComponent("__Snapshots__/alpha.txt")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "TREE-A")
    }

    // MARK: - (ii) matching reference → passes

    func testMatchingReference_passes() throws {
        _ = try store.compareOrRecord(actual: "TREE-A", named: "beta", recording: false)  // record
        let result = try store.compareOrRecord(actual: "TREE-A", named: "beta", recording: false)
        XCTAssertEqual(result, .matched)
    }

    // MARK: - (iii) mismatch → fails AND writes a .actual.txt artifact

    func testMismatch_failsAndWritesActualArtifact() throws {
        _ = try store.compareOrRecord(actual: "TREE-A", named: "gamma", recording: false)  // record A
        let result = try store.compareOrRecord(actual: "TREE-B", named: "gamma", recording: false)
        guard case .mismatch(let mismatch) = result else {
            return XCTFail("expected .mismatch, got \(result)")
        }
        XCTAssertEqual(mismatch.expected, "TREE-A")
        XCTAssertEqual(mismatch.actual, "TREE-B")
        // The artifact carries the ACTUAL tree.
        XCTAssertEqual(try String(contentsOf: mismatch.actualArtifactURL, encoding: .utf8), "TREE-B")
        // (v) the diff message names BOTH files.
        XCTAssertTrue(mismatch.message.contains("gamma.txt"), mismatch.message)
        XCTAssertTrue(mismatch.message.contains(mismatch.actualArtifactURL.lastPathComponent), mismatch.message)
    }

    // MARK: - (iv) OURO_SNAPSHOT_RECORD / recording flag overwrites

    func testRecordingTrue_overwritesEvenWhenReferenceExistsAndDiffers() throws {
        _ = try store.compareOrRecord(actual: "OLD", named: "delta", recording: false)  // record OLD
        let result = try store.compareOrRecord(actual: "NEW", named: "delta", recording: true)
        XCTAssertEqual(result, .recorded)
        let ref = tempDir.appendingPathComponent("__Snapshots__/delta.txt")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "NEW")
    }

    // MARK: - referencePath derivation

    func testReferenceURL_isUnderSnapshotsDirectory_namedDotTxt() {
        let url = store.referenceURL(named: "epsilon")
        XCTAssertEqual(url.lastPathComponent, "epsilon.txt")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "__Snapshots__")
    }

    // MARK: - The `#filePath`-relative default store resolves into the in-tree dir

    func testDefaultStore_resolvesSnapshotsRelativeToTestFile() {
        // The default store derives `__Snapshots__/` from the test file's `#filePath`
        // directory (the pointfreeco pattern) — NOT an absolute machine path baked in.
        let defaultStore = ViewSnapshotStore.default(testFilePath: "/repo/Tests/OuroWorkbenchAppViewsTests/Foo.swift")
        let ref = defaultStore.referenceURL(named: "x")
        XCTAssertEqual(ref.path, "/repo/Tests/OuroWorkbenchAppViewsTests/__Snapshots__/x.txt")
    }

    // MARK: - error path: reference unreadable

    func testUnreadableReference_throws() throws {
        // Create a "reference" that is a DIRECTORY at the .txt path → reading it as a
        // string fails → the store surfaces a throwing error, not a crash.
        let snapshots = tempDir.appendingPathComponent("__Snapshots__", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let bogus = snapshots.appendingPathComponent("zeta.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.compareOrRecord(actual: "X", named: "zeta", recording: false))
    }

    // MARK: - assertViewSnapshot one-liner (record-then-match round trip)

    @MainActor
    func testAssertViewSnapshot_recordsThenMatches() throws {
        // First call records (missing reference), second call matches — no failure.
        try assertViewSnapshotText("HELLO-TREE", named: "eta", store: store)
        try assertViewSnapshotText("HELLO-TREE", named: "eta", store: store)
    }

    // MARK: - Unit 3c: assertion branches (silent re-record + mismatch reporting)

    @MainActor
    func testAssertViewSnapshot_recordTrue_overwritesSilently() throws {
        try assertViewSnapshotText("V1", named: "theta", store: store)            // record V1
        try assertViewSnapshotText("V2", named: "theta", store: store, record: true)  // silent re-record V2
        // The reference is now V2 and a normal compare passes.
        try assertViewSnapshotText("V2", named: "theta", store: store)
        let ref = tempDir.appendingPathComponent("__Snapshots__/theta.txt")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "V2")
    }

    @MainActor
    func testAssertViewSnapshot_mismatch_reportsFailureAndAttaches() throws {
        try assertViewSnapshotText("EXPECTED", named: "iota", store: store)  // record EXPECTED
        var failures: [(message: String, file: StaticString, line: UInt)] = []
        try assertViewSnapshotText("DIFFERENT", named: "iota", store: store) { message, file, line in
            failures.append((message: message, file: file, line: line))
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].message.contains("iota.txt"), failures[0].message)
        XCTAssertTrue(failures[0].message.contains("iota.actual.txt"), failures[0].message)
        // The .actual.txt artifact was written with the actual tree.
        let artifact = tempDir.appendingPathComponent("artifacts/iota.actual.txt")
        XCTAssertEqual(try String(contentsOf: artifact, encoding: .utf8), "DIFFERENT")
    }

    @MainActor
    func testAssertViewSnapshot_missingReference_recordsAndAttachesWithoutFailing() throws {
        // Normal-run missing reference → records + attaches the recorded tree (the
        // attach(text, "recorded") branch), no failure.
        try assertViewSnapshotText("FIRST-RECORD", named: "kappa", store: store)
        let ref = tempDir.appendingPathComponent("__Snapshots__/kappa.txt")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "FIRST-RECORD")
    }

    func testIsRecordingFromEnvironment_reflectsEnvVar() {
        // The default record knob reads OURO_SNAPSHOT_RECORD (D-U1-3). We can't mutate
        // the test process env safely, so assert the function returns the env's truth.
        let expected = ProcessInfo.processInfo.environment["OURO_SNAPSHOT_RECORD"] == "1"
        XCTAssertEqual(isRecordingFromEnvironment(), expected)
    }
}
#endif
