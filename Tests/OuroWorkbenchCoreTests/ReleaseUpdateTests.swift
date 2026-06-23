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
        XCTAssertEqual(snapshot.currentReleaseLabel, "Version 0.1.155 (build 238)")
        XCTAssertEqual(snapshot.currentReleaseLabelForPrompt, "0.1.155 (build 238)")
        XCTAssertEqual(snapshot.latestReleaseLabel, "Version 0.1.155 (build 340)")
        XCTAssertEqual(snapshot.latestReleaseLabelForPrompt, "0.1.155 (build 340)")
    }

    func testSnapshotLabelsAndAssetsWhenNoLatestReleaseExists() {
        let snapshot = ReleaseUpdateSnapshot(
            status: .unavailable,
            currentVersion: "0.1.155",
            currentBuild: nil,
            latestVersion: nil,
            latestBuild: nil,
            tagName: nil,
            htmlURL: nil,
            assets: [
                ReleaseUpdateAsset(name: "OuroWorkbench-0.1.155-build.238-app.zip", downloadURL: "https://example.test/app.zip", size: 10)
            ],
            detail: "No release"
        )

        XCTAssertEqual(snapshot.installableAssets, [])
        XCTAssertFalse(snapshot.hasInstallableAssets)
        XCTAssertEqual(snapshot.currentReleaseLabel, "Version 0.1.155")
        XCTAssertEqual(snapshot.currentReleaseLabelForPrompt, "0.1.155")
        XCTAssertNil(snapshot.latestReleaseLabel)
        XCTAssertNil(snapshot.latestReleaseLabelForPrompt)
    }

    func testLatestBuildIgnoresNonBuildReleaseAssets() throws {
        let data = Data("""
        [
          {
            "tag_name": "v0.1.155",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.1.155",
            "draft": false,
            "prerelease": true,
            "assets": [
              {"name": "README.txt", "browser_download_url": "https://example.test/readme.txt", "size": 1},
              {"name": "OtherWorkbench-0.1.155-build.999.zip", "browser_download_url": "https://example.test/other.zip", "size": 1},
              {"name": "OuroWorkbench-0.1.155-build.-bad.zip", "browser_download_url": "https://example.test/bad.zip", "size": 1}
            ]
          }
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.154")

        XCTAssertEqual(snapshot.status, .updateAvailable)
        XCTAssertNil(snapshot.latestBuild)
        XCTAssertFalse(snapshot.hasInstallableAssets)
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

    func testAsyncCheckUsesConfiguredVersionAndLoadedReleaseData() async throws {
        let defaultChecker = ReleaseUpdateChecker()
        XCTAssertEqual(defaultChecker.configuration.currentVersion, WorkbenchRelease.version)
        let releasesURL = URL(string: "https://coverage-batch-2.test/releases")!
        let configuredDefaultLoader = ReleaseUpdateChecker(
            configuration: ReleaseUpdateConfiguration(
                repository: "example/repo",
                currentVersion: "0.1.0",
                releasesURL: releasesURL
            )
        )
        XCTAssertEqual(configuredDefaultLoader.configuration.releasesURL, releasesURL)
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }
        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.url, releasesURL)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                [
                  {
                    "tag_name": "v0.2.0",
                    "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.2.0",
                    "draft": false,
                    "prerelease": false,
                    "assets": []
                  }
                ]
                """.utf8)
            )
        }
        let configuredDefaultSnapshot = await configuredDefaultLoader.check()
        XCTAssertEqual(configuredDefaultSnapshot.status, .updateAvailable)

        let checker = ReleaseUpdateChecker(
            configuration: ReleaseUpdateConfiguration(
                repository: "example/repo",
                currentVersion: "0.1.0",
                releasesURL: releasesURL
            ),
            dataLoader: { url in
                XCTAssertEqual(url, releasesURL)
                return Data("""
                [
                  {"tag_name":"v0.1.1","html_url":"https://example.test/v0.1.1","draft":false,"prerelease":false,"assets":[]}
                ]
                """.utf8)
            }
        )

        let snapshot = await checker.check()

        XCTAssertEqual(snapshot.status, .updateAvailable)
        XCTAssertEqual(snapshot.currentVersion, "0.1.0")
        XCTAssertEqual(snapshot.latestVersion, "0.1.1")
    }

    func testDefaultConfigurationBuildsShellIdentityFromWorkbenchRelease() {
        let configuration = ReleaseUpdateConfiguration(currentBuild: "123")
        let identity = configuration.appShellIdentity

        XCTAssertEqual(identity.appName, WorkbenchRelease.appName)
        XCTAssertEqual(identity.bundleIdentifier, WorkbenchRelease.bundleIdentifier)
        XCTAssertEqual(identity.repository, WorkbenchRelease.repository)
        XCTAssertEqual(identity.version, WorkbenchRelease.version)
        XCTAssertEqual(identity.build, "123")
        XCTAssertEqual(identity.userAgent, WorkbenchRelease.userAgent(version: WorkbenchRelease.version))
        XCTAssertEqual(configuration.appShellConfiguration.releasePolicy, .workbench(namePrefix: WorkbenchRelease.artifactNamePrefix))
        XCTAssertEqual(configuration.releasesURL, identity.releasesAPIURL)
    }

    func testConfiguredVersionFlowsIntoShellIdentityUserAgent() {
        let configuration = ReleaseUpdateConfiguration(currentVersion: "9.8.7")

        XCTAssertEqual(configuration.appShellIdentity.version, "9.8.7")
        XCTAssertEqual(configuration.appShellIdentity.userAgent, "OuroWorkbench/9.8.7")
    }

    func testSnapshotReportsUnavailableWhenVersionCannotBeCompared() throws {
        let data = Data("""
        [
          {"tag_name":"release-candidate","html_url":"https://example.test/rc","draft":false,"prerelease":true,"assets":[]}
        ]
        """.utf8)

        let snapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.0")

        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertEqual(snapshot.latestVersion, "release-candidate")
        XCTAssertEqual(snapshot.detail, "Latest release release-candidate could not be compared to 0.1.0.")
    }

    func testSemanticVersionComparisonCoversMajorMinorAndPatch() {
        XCTAssertLessThan(SemanticVersion("2.0.0")!, SemanticVersion("3.0.0")!)
        XCTAssertLessThan(SemanticVersion("2.1.0")!, SemanticVersion("2.2.0")!)
        XCTAssertLessThan(SemanticVersion("2.1.0-build.1")!, SemanticVersion("2.1.1")!)
        XCTAssertNil(SemanticVersion("not-semver"))
        XCTAssertNil(SemanticVersion(""))
    }

    func testDefaultDataLoaderReturnsDataAndMapsBadStatus() async throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }

        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OuroWorkbench/\(WorkbenchRelease.version)")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        let data = try await ReleaseUpdateChecker.defaultDataLoader(url: URL(string: "https://coverage-batch-2.test/releases")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[]")

        CoverageBatch2URLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        await XCTAssertThrowsErrorAsync(try await ReleaseUpdateChecker.defaultDataLoader(url: URL(string: "https://coverage-batch-2.test/releases")!)) { error in
            XCTAssertEqual(error as? ReleaseUpdateError, .badResponse)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {
        handler(error)
    }
}
