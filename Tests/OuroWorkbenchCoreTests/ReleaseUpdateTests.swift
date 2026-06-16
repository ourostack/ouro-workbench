import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class ReleaseUpdateTests: XCTestCase {
    func testSnapshotReportsUpdateAvailableFromLatestPublishedRelease() throws {
        let data = Data("""
        [
          {
            "tag_name": "v0.2.0",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.2.0",
            "draft": false,
            "prerelease": true,
            "assets": [
              {"name": "OuroWorkbench-0.2.0-build.120-abcdef0.zip", "browser_download_url": "https://example.test/app.zip", "size": 100},
              {"name": "OuroWorkbench-0.2.0-build.120-abcdef0.manifest.json", "browser_download_url": "https://example.test/manifest.json", "size": 50}
            ]
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.0")

        XCTAssertEqual(snapshot.status, .updateAvailable)
        XCTAssertEqual(snapshot.latestVersion, "0.2.0")
        XCTAssertEqual(snapshot.tagName, "v0.2.0")
        XCTAssertTrue(snapshot.hasInstallableAssets)
    }

    func testSnapshotReportsCurrentWhenLatestIsNotNewer() throws {
        let data = Data("""
        [
          {
            "tag_name": "v0.1.0",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.1.0",
            "draft": false,
            "prerelease": true,
            "assets": []
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.0")

        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.detail, "Version 0.1.0 is current.")
    }

    func testSnapshotReportsUpdateAvailableWhenSameVersionHasNewerBuild() throws {
        let data = Data("""
        [
          {
            "tag_name": "v0.1.155",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.1.155",
            "draft": false,
            "prerelease": true,
            "assets": [
              {"name": "OuroWorkbench-0.1.155-build.340-cdf1190.zip", "browser_download_url": "https://example.test/app.zip", "size": 100},
              {"name": "OuroWorkbench-0.1.155-build.340-cdf1190.manifest.json", "browser_download_url": "https://example.test/manifest.json", "size": 50}
            ]
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.155", currentBuild: "238")

        XCTAssertEqual(snapshot.status, .updateAvailable)
        XCTAssertEqual(snapshot.latestVersion, "0.1.155")
        XCTAssertEqual(snapshot.latestBuild, "340")
        XCTAssertEqual(snapshot.detail, "Version 0.1.155 (build 340) is available.")
        XCTAssertEqual(snapshot.latestReleaseLabelForPrompt, "0.1.155 (build 340)")
    }

    func testSnapshotReportsCurrentWhenSameVersionBuildIsNotNewer() throws {
        let data = Data("""
        [
          {
            "tag_name": "v0.1.155",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.1.155",
            "draft": false,
            "prerelease": true,
            "assets": [
              {"name": "OuroWorkbench-0.1.155-build.238-8488f1c.zip", "browser_download_url": "https://example.test/app.zip", "size": 100},
              {"name": "OuroWorkbench-0.1.155-build.238-8488f1c.manifest.json", "browser_download_url": "https://example.test/manifest.json", "size": 50}
            ]
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.155", currentBuild: "238")

        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.latestBuild, "238")
        XCTAssertEqual(snapshot.detail, "Version 0.1.155 (build 238) is current.")
    }

    func testSnapshotIgnoresBuildsFromAssetsForOtherVersions() throws {
        let data = Data("""
        [
          {
            "tag_name": "v0.1.155",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.1.155",
            "draft": false,
            "prerelease": true,
            "assets": [
              {"name": "OuroWorkbench-0.1.154-build.999-deadbee.zip", "browser_download_url": "https://example.test/old.zip", "size": 100},
              {"name": "OuroWorkbench-0.1.155-build.238-8488f1c.zip", "browser_download_url": "https://example.test/app.zip", "size": 100},
              {"name": "OuroWorkbench-0.1.155-build.238-8488f1c.manifest.json", "browser_download_url": "https://example.test/manifest.json", "size": 50}
            ]
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.155", currentBuild: "238")

        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.latestBuild, "238")
    }

    func testSnapshotIgnoresDraftsAndReportsNoPublishedRelease() throws {
        let data = Data("""
        [
          {
            "tag_name": "v1.0.0",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v1.0.0",
            "draft": true,
            "prerelease": false,
            "assets": []
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.0")

        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertNil(snapshot.latestVersion)
        XCTAssertEqual(snapshot.detail, "No published release found.")
    }

    func testAsyncCheckReturnsUnavailableSnapshotOnNetworkFailure() async {
        let checker = ReleaseUpdateChecker { _ in
            throw ReleaseUpdateError.badResponse
        }

        let snapshot = await checker.check()

        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertEqual(snapshot.currentVersion, WorkbenchRelease.version)
        XCTAssertTrue(snapshot.detail.contains("Release update check failed"))
    }
}
