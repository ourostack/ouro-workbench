import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class ReleaseUpdateTests: XCTestCase {
    func testDefaultConfigurationBuildsWorkbenchShellConfiguration() {
        let defaultChecker = ReleaseUpdateChecker()
        let configuration = ReleaseUpdateConfiguration(currentBuild: "123")
        let identity = configuration.appShellIdentity
        let shellConfiguration = configuration.appShellConfiguration

        XCTAssertEqual(defaultChecker.configuration.currentVersion, WorkbenchRelease.version)
        XCTAssertEqual(identity.appName, WorkbenchRelease.appName)
        XCTAssertEqual(identity.bundleIdentifier, WorkbenchRelease.bundleIdentifier)
        XCTAssertEqual(identity.repository, WorkbenchRelease.repository)
        XCTAssertEqual(identity.version, WorkbenchRelease.version)
        XCTAssertEqual(identity.build, "123")
        XCTAssertEqual(identity.userAgent, WorkbenchRelease.userAgent(version: WorkbenchRelease.version))
        XCTAssertEqual(configuration.releasesURL, identity.releasesAPIURL)
        XCTAssertEqual(shellConfiguration.identity, identity)
        XCTAssertEqual(shellConfiguration.releasePolicy, .workbench(namePrefix: WorkbenchRelease.artifactNamePrefix))
        XCTAssertEqual(shellConfiguration.releasesURL, identity.releasesAPIURL)
        XCTAssertTrue(shellConfiguration.includePrereleases)
    }

    func testCustomConfigurationFlowsIntoWorkbenchIdentityAndReleaseURL() {
        let releasesURL = URL(string: "https://updates.example.test/workbench/releases")!
        let configuration = ReleaseUpdateConfiguration(
            repository: "example/workbench",
            currentVersion: "9.8.7",
            currentBuild: "456",
            releasesURL: releasesURL
        )

        XCTAssertEqual(configuration.appShellIdentity.repository, "example/workbench")
        XCTAssertEqual(configuration.appShellIdentity.version, "9.8.7")
        XCTAssertEqual(configuration.appShellIdentity.build, "456")
        XCTAssertEqual(configuration.appShellIdentity.userAgent, "OuroWorkbench/9.8.7")
        XCTAssertEqual(configuration.appShellConfiguration.repository, "example/workbench")
        XCTAssertEqual(configuration.appShellConfiguration.currentVersion, "9.8.7")
        XCTAssertEqual(configuration.appShellConfiguration.currentBuild, "456")
        XCTAssertEqual(configuration.appShellConfiguration.releasesURL, releasesURL)
        XCTAssertEqual(ReleaseUpdateChecker(configuration: configuration).configuration, configuration)
    }

    func testSnapshotHelpersUseWorkbenchPolicyIncludingPrereleasesAndBuildAssets() throws {
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
          },
          {
            "tag_name": "v0.1.9",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.1.9",
            "draft": false,
            "prerelease": false,
            "assets": []
          }
        ]
        """.utf8)
        let configuration = ReleaseUpdateConfiguration(currentVersion: "0.1.0", currentBuild: "1")

        let configuredSnapshot = try ReleaseUpdateChecker.snapshot(from: data, configuration: configuration)
        let convenienceSnapshot = try ReleaseUpdateChecker.snapshot(from: data, currentVersion: "0.1.0", currentBuild: "1")

        for snapshot in [configuredSnapshot, convenienceSnapshot] {
            XCTAssertEqual(snapshot.tagName, "v0.2.0")
            XCTAssertEqual(snapshot.latestBuild, "120")
            XCTAssertTrue(snapshot.hasInstallableAssets)
            XCTAssertEqual(snapshot.installableAssets.map(\.name), [
                "OuroWorkbench-0.2.0-build.120-abcdef0.zip",
                "OuroWorkbench-0.2.0-build.120-abcdef0.manifest.json"
            ])
        }
    }

    func testCheckUsesConfiguredReleaseURLAndFailureKeepsWorkbenchPolicy() async {
        let releasesURL = URL(string: "https://updates.example.test/workbench/releases")!
        let configuration = ReleaseUpdateConfiguration(
            repository: "example/workbench",
            currentVersion: "0.1.0",
            currentBuild: "5",
            releasesURL: releasesURL
        )
        let checker = ReleaseUpdateChecker(configuration: configuration) { url in
            XCTAssertEqual(url, releasesURL)
            return Data("""
            [
              {
                "tag_name": "v0.2.0",
                "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v0.2.0",
                "draft": false,
                "prerelease": true,
                "assets": []
              }
            ]
            """.utf8)
        }

        let snapshot = await checker.check()

        XCTAssertEqual(snapshot.currentVersion, "0.1.0")
        XCTAssertEqual(snapshot.latestVersion, "0.2.0")

        let failureChecker = ReleaseUpdateChecker(configuration: configuration) { _ in
            throw ReleaseUpdateError.badResponse
        }
        let failure = await failureChecker.check()

        XCTAssertEqual(failure.status, .unavailable)
        XCTAssertEqual(failure.currentVersion, "0.1.0")
        XCTAssertEqual(failure.currentBuild, "5")
        XCTAssertTrue(failure.detail.contains("Release update check failed"))
        XCTAssertEqual(
            failure.assetNamingPolicy.isInstallableAssetName(
                "OuroWorkbench-0.2.0-build.120-abcdef0.zip",
                version: "0.2.0",
                build: "120"
            ),
            true
        )
    }

    func testDefaultDataLoaderAddsWorkbenchHeadersAndMapsBadStatus() async throws {
        URLProtocol.registerClass(CoverageBatch2URLProtocol.self)
        defer {
            CoverageBatch2URLProtocol.reset()
            URLProtocol.unregisterClass(CoverageBatch2URLProtocol.self)
        }
        let releaseData = Data("""
        [
          {
            "tag_name": "v9.9.9",
            "html_url": "https://github.com/ourostack/ouro-workbench/releases/tag/v9.9.9",
            "draft": false,
            "prerelease": true,
            "assets": []
          }
        ]
        """.utf8)

        CoverageBatch2URLProtocol.handler = { request in
            XCTAssertEqual(request.url, URL(string: "https://coverage-batch-2.test/releases")!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OuroWorkbench/\(WorkbenchRelease.version)")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                releaseData
            )
        }

        let checker = ReleaseUpdateChecker(
            configuration: ReleaseUpdateConfiguration(releasesURL: URL(string: "https://coverage-batch-2.test/releases")!)
        )
        let snapshot = await checker.check()
        XCTAssertEqual(snapshot.status, .updateAvailable)
        XCTAssertEqual(snapshot.latestVersion, "9.9.9")

        let data = try await ReleaseUpdateChecker.defaultDataLoader(url: URL(string: "https://coverage-batch-2.test/releases")!)
        XCTAssertEqual(data, releaseData)

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
