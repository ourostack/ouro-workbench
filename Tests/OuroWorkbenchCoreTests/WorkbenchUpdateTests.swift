import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchUpdateTests: XCTestCase {
    private func snapshot(
        status: ReleaseUpdateStatus,
        latest: String?,
        latestBuild: String? = "199",
        assets: [ReleaseUpdateAsset]
    ) -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: status,
            currentVersion: "0.1.120",
            currentBuild: "198",
            latestVersion: latest,
            latestBuild: latestBuild,
            tagName: latest.map { "v\($0)" },
            htmlURL: "https://github.com/ourostack/ouro-workbench/releases/latest",
            assets: assets,
            detail: ""
        )
    }

    private var workbenchAssets: [ReleaseUpdateAsset] {
        [
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.198-deadbee.zip",
                downloadURL: "https://example.com/wrong-build.zip",
                size: 1
            ),
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.199-779ed85.zip",
                downloadURL: "https://example.com/OuroWorkbench-0.1.122-build.199-779ed85.zip",
                size: 3_600_000
            ),
            ReleaseUpdateAsset(
                name: "OuroWorkbench-0.1.122-build.199-779ed85.manifest.json",
                downloadURL: "https://example.com/OuroWorkbench-0.1.122-build.199-779ed85.manifest.json",
                size: 320
            )
        ]
    }

    func testPlanInjectsWorkbenchAssetPolicyBeforeDelegatingToShellPlanner() throws {
        let plan = try WorkbenchUpdatePlanner.plan(
            from: snapshot(status: .updateAvailable, latest: "0.1.122", assets: workbenchAssets)
        ).get()

        XCTAssertEqual(plan.version, "0.1.122")
        XCTAssertEqual(plan.build, "199")
        XCTAssertEqual(plan.archiveName, "OuroWorkbench-0.1.122-build.199-779ed85.zip")
        XCTAssertEqual(plan.archiveURL.absoluteString, "https://example.com/OuroWorkbench-0.1.122-build.199-779ed85.zip")
        XCTAssertEqual(plan.manifestURL.absoluteString, "https://example.com/OuroWorkbench-0.1.122-build.199-779ed85.manifest.json")
    }

    func testVerificationUsesBuildAwareComparisonWhenDelegatingToShellVerifier() {
        let manifest = WorkbenchUpdateManifest(
            appName: "Ouro Workbench",
            bundleIdentifier: "com.ourostack.workbench",
            version: "0.1.120",
            build: "199",
            archive: "OuroWorkbench-0.1.120-build.199-779ed85.zip",
            sha256: "abc123",
            bytes: 3_600_000
        )

        let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest,
            downloadedArchiveName: "OuroWorkbench-0.1.120-build.199-779ed85.zip",
            downloadedSHA256: "ABC123",
            downloadedBytes: 3_600_000,
            expectedBundleIdentifier: "com.ourostack.workbench",
            currentVersion: "0.1.120",
            currentBuild: "198"
        )

        XCTAssertNil(failure)
    }
}
