import XCTest
@testable import OuroWorkbenchCore

/// U30(a): the per-report durable filed-status that survives relaunch. Today the filed
/// GitHub-issue URL lives only in a transient @Published var and is never written into the
/// bundle, so once the sheet closes neither the operator nor the boss can tell which report
/// was filed or where. `BugReportStatusStore` persists a `status.json` next to `report.md`
/// in each bundle dir, and enumerates recent reports + their status for a boss read.
final class BugReportStatusStoreTests: XCTestCase {
    private var tempRoot: URL!
    private let store = BugReportStatusStore()

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bugstatus-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func bundleDir(_ name: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Default unfiled status

    func testUnfiledStatusFactory() {
        let status = BugReportFiledStatus.unfiled(note: "It broke", warnings: ["no screenshot"])
        XCTAssertFalse(status.filed)
        XCTAssertNil(status.issueURL)
        XCTAssertNil(status.filedAt)
        XCTAssertEqual(status.note, "It broke")
        XCTAssertEqual(status.collectionWarnings, ["no screenshot"])
    }

    func testFiledStatusFactory() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let status = BugReportFiledStatus.unfiled(note: "x", warnings: [])
            .markedFiled(issueURL: "https://github.com/o/r/issues/7", at: when)
        XCTAssertTrue(status.filed)
        XCTAssertEqual(status.issueURL, "https://github.com/o/r/issues/7")
        XCTAssertEqual(status.filedAt, when)
        XCTAssertEqual(status.note, "x")
    }

    // MARK: - Persistence round-trip (survives relaunch)

    func testWriteThenReadRoundTrip() throws {
        let dir = try bundleDir("20260101-000000-it-broke")
        let written = BugReportFiledStatus.unfiled(note: "It broke", warnings: ["partial"])
        try store.write(written, into: dir)

        // A fresh store instance (mimics a relaunch) reads the same status back.
        let read = BugReportStatusStore().read(from: dir)
        XCTAssertEqual(read, written)
        // Status lives as a file in the bundle, so it survives the sheet/app closing.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("status.json").path))
    }

    func testReadReturnsNilWhenNoStatusFile() throws {
        let dir = try bundleDir("no-status")
        XCTAssertNil(store.read(from: dir))
    }

    func testWriteFiledStatusSurvives() throws {
        let dir = try bundleDir("20260101-000000-filed")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let filed = BugReportFiledStatus.unfiled(note: "n", warnings: [])
            .markedFiled(issueURL: "https://example.com/1", at: when)
        try store.write(filed, into: dir)

        let read = BugReportStatusStore().read(from: dir)
        XCTAssertEqual(read?.filed, true)
        XCTAssertEqual(read?.issueURL, "https://example.com/1")
        XCTAssertEqual(read?.filedAt, when)
    }

    // MARK: - Recent-reports enumeration (the boss read)

    func testRecentReportsEnumeratesBundlesNewestFirst() throws {
        // Three bundles whose timestamp-prefixed names sort chronologically.
        let older = try bundleDir("20260101-090000-older")
        let newer = try bundleDir("20260102-090000-newer")
        let newest = try bundleDir("20260103-090000-newest")
        try store.write(.unfiled(note: "older", warnings: []), into: older)
        try store.write(
            .unfiled(note: "newer", warnings: []).markedFiled(issueURL: "https://x/2", at: Date()),
            into: newer
        )
        try store.write(.unfiled(note: "newest", warnings: ["w"]), into: newest)

        let reports = store.recentReports(inFolder: tempRoot)
        // Newest-first by directory name (the names are sortable timestamps).
        XCTAssertEqual(reports.map(\.directoryName), [
            "20260103-090000-newest",
            "20260102-090000-newer",
            "20260101-090000-older"
        ])
        XCTAssertEqual(reports[0].status.note, "newest")
        XCTAssertEqual(reports[1].status.filed, true)
        XCTAssertEqual(reports[1].status.issueURL, "https://x/2")
        // Compare resolved paths — the enumerated URL resolves /var → /private/var.
        XCTAssertEqual(
            reports[0].directoryURL.standardizedFileURL.resolvingSymlinksInPath().path,
            newest.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testRecentReportsSkipsBundlesWithoutStatus() throws {
        let withStatus = try bundleDir("20260101-000000-has")
        _ = try bundleDir("20260102-000000-missing") // no status.json
        try store.write(.unfiled(note: "has", warnings: []), into: withStatus)

        let reports = store.recentReports(inFolder: tempRoot)
        XCTAssertEqual(reports.map(\.directoryName), ["20260101-000000-has"])
    }

    func testRecentReportsRespectsLimit() throws {
        for index in 0..<5 {
            let dir = try bundleDir(String(format: "202601%02d-000000-r", index + 1))
            try store.write(.unfiled(note: "r\(index)", warnings: []), into: dir)
        }
        let reports = store.recentReports(inFolder: tempRoot, limit: 2)
        XCTAssertEqual(reports.count, 2)
        // The two newest by name.
        XCTAssertEqual(reports.map(\.directoryName), ["20260105-000000-r", "20260104-000000-r"])
    }

    func testRecentReportsEmptyWhenFolderMissing() {
        let ghost = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertTrue(store.recentReports(inFolder: ghost).isEmpty)
    }
}
