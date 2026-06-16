import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchUpdateTests: XCTestCase {
    private func snapshot(
        status: ReleaseUpdateStatus,
        latest: String?,
        assets: [ReleaseUpdateAsset]
    ) -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: status,
            currentVersion: "0.1.120",
            currentBuild: "198",
            latestVersion: latest,
            latestBuild: "199",
            tagName: latest.map { "v\($0)" },
            htmlURL: "https://github.com/ourostack/ouro-workbench/releases/latest",
            assets: assets,
            detail: ""
        )
    }

    private var installableAssets: [ReleaseUpdateAsset] {
        [
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
                downloadURL: "https://example.com/OuroWorkbench-0.1.122-build.199-779ed85.zip",
                size: 3_600_000
            ),
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.199-779ed85.manifest.json",
                downloadURL: "https://example.com/OuroWorkbench-0.1.122-build.199-779ed85.manifest.json",
                size: 320
            ),
        ]
    }

    // MARK: - Planner

    func testPlanPicksZipAndManifestAssets() throws {
        let plan = try WorkbenchUpdatePlanner.plan(
            from: snapshot(status: .updateAvailable, latest: "0.1.122", assets: installableAssets)
        ).get()
        XCTAssertEqual(plan.version, "0.1.122")
        XCTAssertEqual(plan.build, "199")
        XCTAssertEqual(plan.archiveName, "OuroWorkbench-0.1.122-build.199-779ed85.zip")
        XCTAssertEqual(plan.archiveURL.lastPathComponent, "OuroWorkbench-0.1.122-build.199-779ed85.zip")
        XCTAssertEqual(plan.manifestURL.lastPathComponent, "OuroWorkbench-0.1.122-build.199-779ed85.manifest.json")
    }

    func testPlanIgnoresAssetsFromOtherVersionsAndBuilds() throws {
        let assets = [
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.121-build.999-deadbee.zip",
                downloadURL: "https://example.com/wrong-version.zip",
                size: 3_600_000
            ),
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.198-deadbee.zip",
                downloadURL: "https://example.com/wrong-build.zip",
                size: 3_600_000
            ),
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
                downloadURL: "https://example.com/right.zip",
                size: 3_600_000
            ),
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.199-779ed85.manifest.json",
                downloadURL: "https://example.com/right.manifest.json",
                size: 320
            )
        ]

        let plan = try WorkbenchUpdatePlanner.plan(
            from: snapshot(status: .updateAvailable, latest: "0.1.122", assets: assets)
        ).get()

        XCTAssertEqual(plan.archiveURL.absoluteString, "https://example.com/right.zip")
        XCTAssertEqual(plan.manifestURL.absoluteString, "https://example.com/right.manifest.json")
    }

    func testPlanFailsWhenNotAnUpdate() {
        let result = WorkbenchUpdatePlanner.plan(
            from: snapshot(status: .current, latest: "0.1.120", assets: installableAssets)
        )
        XCTAssertEqual(result, .failure(.notAnUpdate))
    }

    func testPlanFailsWhenArchiveMissing() {
        let onlyManifest = [installableAssets[1]]
        let result = WorkbenchUpdatePlanner.plan(
            from: snapshot(status: .updateAvailable, latest: "0.1.122", assets: onlyManifest)
        )
        XCTAssertEqual(result, .failure(.missingArchiveAsset))
    }

    func testPlanFailsWhenManifestMissing() {
        let onlyZip = [installableAssets[0]]
        let result = WorkbenchUpdatePlanner.plan(
            from: snapshot(status: .updateAvailable, latest: "0.1.122", assets: onlyZip)
        )
        XCTAssertEqual(result, .failure(.missingManifestAsset))
    }

    // MARK: - Verification

    private func manifest(
        sha: String = "abc123",
        bytes: Int = 3_600_000,
        bundleID: String = "com.ourostack.workbench",
        version: String = "0.1.122",
        archive: String = "OuroWorkbench-0.1.122-build.199-779ed85.zip"
    ) -> WorkbenchUpdateManifest {
        WorkbenchUpdateManifest(
            appName: "Ouro Workbench",
            bundleIdentifier: bundleID,
            version: version,
            build: "199",
            archive: archive,
            sha256: sha,
            bytes: bytes
        )
    }

    func testVerifyPassesWhenEverythingMatches() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(sha: "ABC123"),
            downloadedArchiveName: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
            downloadedSHA256: "abc123", // case-insensitive
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120"
        )
        XCTAssertNil(failure)
    }

    func testVerifyPassesWhenSameVersionHasNewerBuild() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(version: "0.1.120"),
            downloadedArchiveName: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
            downloadedSHA256: "abc123",
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120",
            currentBuild: "198"
        )
        XCTAssertNil(failure)
    }

    func testVerifyFailsOnSHAMismatch() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(sha: "abc123"),
            downloadedArchiveName: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
            downloadedSHA256: "deadbeef",
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120"
        )
        XCTAssertEqual(failure, .sha256Mismatch(expected: "abc123", got: "deadbeef"))
    }

    func testVerifyFailsOnByteCountMismatch() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(bytes: 3_600_000),
            downloadedArchiveName: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
            downloadedSHA256: "abc123",
            downloadedBytes: 42,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120"
        )
        XCTAssertEqual(failure, .byteCountMismatch(expected: 3_600_000, got: 42))
    }

    func testVerifyFailsOnBundleIdentifierMismatch() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(bundleID: "com.evil.app"),
            downloadedArchiveName: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
            downloadedSHA256: "abc123",
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120"
        )
        XCTAssertEqual(failure, .bundleIdentifierMismatch(expected: "com.ourostack.workbench", got: "com.evil.app"))
    }

    func testVerifyFailsWhenArchiveNameDiffersFromManifest() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(archive: "OuroWorkbench-0.1.122-build.199-779ed85.zip"),
            downloadedArchiveName: "something-else.zip",
            downloadedSHA256: "abc123",
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120"
        )
        XCTAssertEqual(
            failure,
            .archiveNameMismatch(expected: "OuroWorkbench-0.1.122-build.199-779ed85.zip", got: "something-else.zip")
        )
    }

    func testVerifyFailsWhenNotNewerThanCurrent() {
        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest(version: "0.1.120"),
            downloadedArchiveName: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
            downloadedSHA256: "abc123",
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120",
            currentBuild: "199"
        )
        XCTAssertEqual(
            failure,
            .notNewerThanCurrent(
                current: "Version 0.1.120 (build 199)",
                candidate: "Version 0.1.120 (build 199)"
            )
        )
    }

    // MARK: - Auto-update policy

    func testAutoUpdatePolicyChecksWhenNeverCheckedBefore() {
        XCTAssertTrue(
            WorkbenchAutoUpdatePolicy.shouldCheck(
                now: Date(timeIntervalSince1970: 1000),
                lastCheck: nil,
                minimumInterval: 3600,
                enabled: true
            )
        )
    }

    func testAutoUpdatePolicySkipsWhenDisabled() {
        XCTAssertFalse(
            WorkbenchAutoUpdatePolicy.shouldCheck(
                now: Date(timeIntervalSince1970: 100_000),
                lastCheck: nil,
                minimumInterval: 3600,
                enabled: false
            )
        )
    }

    func testAutoUpdatePolicyThrottlesWithinInterval() {
        let last = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(
            WorkbenchAutoUpdatePolicy.shouldCheck(
                now: last.addingTimeInterval(1800), // 30 min < 1h
                lastCheck: last,
                minimumInterval: 3600,
                enabled: true
            )
        )
    }

    func testAutoUpdatePolicyChecksAfterInterval() {
        let last = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(
            WorkbenchAutoUpdatePolicy.shouldCheck(
                now: last.addingTimeInterval(3600), // exactly 1h
                lastCheck: last,
                minimumInterval: 3600,
                enabled: true
            )
        )
    }

    func testManifestDecodesFromReleaseJSON() throws {
        let json = """
        {
          "appName": "Ouro Workbench",
          "bundleIdentifier": "com.ourostack.workbench",
          "version": "0.1.10",
          "build": "88",
          "gitSha": "33b780b",
          "gitDirty": false,
          "archive": "OuroWorkbench-0.1.10-build.88-33b780b.zip",
          "sha256": "05abb1975c8cb04afc0b5988428e6e0e9af5b46217ab519873c66f885a4d2050",
          "bytes": 3598501,
          "createdAt": "2026-05-26T06:27:25Z"
        }
        """
        let manifest = try JSONDecoder().decode(WorkbenchUpdateManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, "0.1.10")
        XCTAssertEqual(manifest.build, "88")
        XCTAssertEqual(manifest.bytes, 3_598_501)
        XCTAssertEqual(manifest.sha256, "05abb1975c8cb04afc0b5988428e6e0e9af5b46217ab519873c66f885a4d2050")
    }
}
