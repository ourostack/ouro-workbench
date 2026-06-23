import XCTest
import OuroAppShellUI
@testable import OuroWorkbenchCore
@testable import OuroWorkbenchShellAdapter

final class WorkbenchShellPresentationTests: XCTestCase {
    func testAboutPresentationBuildsShellModelFromWorkbenchReleaseIdentity() {
        let presentation = WorkbenchShellAboutPresentation(buildHash: "abc1234")
        let model = presentation.model

        XCTAssertEqual(presentation.versionLine, "Version \(WorkbenchRelease.version) - Build abc1234")
        XCTAssertEqual(presentation.repositoryURL.absoluteString, "https://github.com/\(WorkbenchRelease.repository)")
        XCTAssertEqual(model.appName, WorkbenchRelease.appName)
        XCTAssertEqual(model.versionLine, presentation.versionLine)
        XCTAssertEqual(model.subtitle, WorkbenchShellAboutPresentation.subtitle)
        XCTAssertEqual(model.repositoryURL, presentation.repositoryURL)
        XCTAssertEqual(model.iconSystemName, WorkbenchShellAboutPresentation.iconSystemName)
        XCTAssertEqual(model.accessibilityLabel, "About Ouro Workbench")
    }

    func testUpdatePresentationBeforeCheckKeepsOnlyChannelMetadata() {
        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: nil,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .notChecked)
        XCTAssertEqual(presentation.state.statusLine, "not checked")
        XCTAssertEqual(presentation.state.metadata, [
            ReleaseUpdateMetadataItem(id: "channel", label: "Channel", value: "Direct download")
        ])
        XCTAssertNil(presentation.badgeText)
        XCTAssertNil(presentation.promptRelease)
        XCTAssertNil(presentation.releaseURL)
        XCTAssertFalse(presentation.state.canReviewUpdate)
        XCTAssertFalse(presentation.state.canInstallUpdate)
        XCTAssertFalse(presentation.state.canOpenReleasePage)
    }

    func testUpdatePresentationForCurrentReleaseExposesCurrentAndChannel() {
        let snapshot = releaseSnapshot(status: .current, latestVersion: WorkbenchRelease.version, latestBuild: "274")

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .current)
        XCTAssertEqual(presentation.state.statusLine, snapshot.detail)
        XCTAssertEqual(presentation.state.metadata.map(\.label), ["Latest", "Current", "Channel"])
        XCTAssertEqual(presentation.state.metadata.first?.value, snapshot.latestReleaseLabelForPrompt)
        XCTAssertEqual(presentation.state.metadata[1].value, snapshot.currentReleaseLabelForPrompt)
        XCTAssertNil(presentation.badgeText)
        XCTAssertNil(presentation.promptRelease)
        XCTAssertFalse(presentation.state.canInstallUpdate)
        XCTAssertFalse(presentation.state.canOpenReleasePage)
    }

    func testUpdatePresentationForInstallableReleaseEnablesReviewInstallAndReleasePage() {
        let snapshot = releaseSnapshot(status: .updateAvailable)

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .updateAvailable)
        XCTAssertEqual(presentation.badgeText, "Update \(snapshot.latestReleaseLabelForPrompt!)")
        XCTAssertEqual(presentation.promptRelease, snapshot.latestReleaseLabelForPrompt)
        XCTAssertEqual(presentation.releaseURL?.absoluteString, snapshot.htmlURL)
        XCTAssertTrue(presentation.state.canReviewUpdate)
        XCTAssertTrue(presentation.state.canInstallUpdate)
        XCTAssertTrue(presentation.state.canOpenReleasePage)
        XCTAssertTrue(presentation.state.detail?.contains("running terminals keep running") == true)
        XCTAssertNil(presentation.state.warning)
    }

    func testUpdatePresentationForReleaseWithoutInstallableAssetsWarnsWithoutInstall() {
        let snapshot = releaseSnapshot(status: .updateAvailable, assets: [])

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .updateAvailable)
        XCTAssertNil(presentation.badgeText)
        XCTAssertNil(presentation.promptRelease)
        XCTAssertFalse(presentation.state.canReviewUpdate)
        XCTAssertFalse(presentation.state.canInstallUpdate)
        XCTAssertTrue(presentation.state.canOpenReleasePage)
        XCTAssertEqual(presentation.state.warning, "Release is published, but installable app assets were not found.")
    }

    func testUnavailablePresentationPreservesSnapshotDetailWithoutActions() {
        let snapshot = releaseSnapshot(status: .unavailable, latestVersion: nil, latestBuild: nil, htmlURL: nil, assets: [])

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .unavailable)
        XCTAssertEqual(presentation.state.statusLine, snapshot.detail)
        XCTAssertEqual(presentation.state.metadata.map(\.label), ["Current", "Channel"])
        XCTAssertNil(presentation.badgeText)
        XCTAssertNil(presentation.promptRelease)
        XCTAssertNil(presentation.releaseURL)
        XCTAssertFalse(presentation.state.canReviewUpdate)
        XCTAssertFalse(presentation.state.canInstallUpdate)
        XCTAssertFalse(presentation.state.canOpenReleasePage)
    }

    func testCheckingPresentationSuppressesStaleActionsAndWarnings() {
        let snapshot = releaseSnapshot(status: .updateAvailable)

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: true,
            isInstalling: false,
            installStatus: nil,
            installError: "codesign failed",
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .checking)
        XCTAssertEqual(presentation.state.statusLine, "Checking for updates…")
        XCTAssertNil(presentation.state.detail)
        XCTAssertNil(presentation.state.warning)
        XCTAssertFalse(presentation.state.canReviewUpdate)
        XCTAssertFalse(presentation.state.canInstallUpdate)
        XCTAssertFalse(presentation.state.canOpenReleasePage)
    }

    func testInstallingPresentationUsesProgressLineAndDisablesInstall() {
        let snapshot = releaseSnapshot(status: .updateAvailable)

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: true,
            installStatus: "Installing 0.1.999 and relaunching…",
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .installing)
        XCTAssertEqual(presentation.state.statusLine, "Installing update…")
        XCTAssertEqual(presentation.state.detail, "Installing 0.1.999 and relaunching…")
        XCTAssertTrue(presentation.state.canReviewUpdate)
        XCTAssertFalse(presentation.state.canInstallUpdate)
        XCTAssertTrue(presentation.state.canOpenReleasePage)
    }

    func testFailedPresentationPrefersInstallErrorWarning() {
        let snapshot = releaseSnapshot(status: .updateAvailable)

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: "codesign failed",
            stagedUpdateVersion: nil
        )

        XCTAssertEqual(presentation.state.kind, .failed)
        XCTAssertEqual(presentation.state.warning, "codesign failed")
        XCTAssertTrue(presentation.state.canInstallUpdate)
    }

    func testStagedPresentationIsReadyToRelaunchAndPrefersStagedReleaseLabel() {
        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: nil,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: "0.1.999 (build 275)"
        )

        XCTAssertEqual(presentation.state.kind, .readyToRelaunch)
        XCTAssertEqual(presentation.badgeText, "Update 0.1.999 (build 275)")
        XCTAssertEqual(presentation.promptRelease, "0.1.999 (build 275)")
        XCTAssertEqual(presentation.state.metadata.first, ReleaseUpdateMetadataItem(id: "latest", label: "Latest", value: "0.1.999 (build 275)"))
        XCTAssertTrue(presentation.state.canReviewUpdate)
        XCTAssertTrue(presentation.state.canInstallUpdate)
    }

    func testMissingReleaseURLDisablesOpenReleasePage() {
        let snapshot = releaseSnapshot(status: .updateAvailable, htmlURL: nil)

        let presentation = WorkbenchShellUpdatePresenter.presentation(
            snapshot: snapshot,
            isChecking: false,
            isInstalling: false,
            installStatus: nil,
            installError: nil,
            stagedUpdateVersion: nil
        )

        XCTAssertNil(presentation.releaseURL)
        XCTAssertFalse(presentation.state.canOpenReleasePage)
    }

    private func releaseSnapshot(
        status: ReleaseUpdateStatus,
        latestVersion: String? = "0.1.999",
        latestBuild: String? = "275",
        htmlURL: String? = "https://github.com/\(WorkbenchRelease.repository)/releases/tag/v0.1.999",
        assets: [ReleaseUpdateAsset]? = nil
    ) -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: status,
            currentVersion: WorkbenchRelease.version,
            currentBuild: "274",
            latestVersion: latestVersion,
            latestBuild: latestBuild,
            tagName: latestVersion.map { "v\($0)" },
            htmlURL: htmlURL,
            assets: assets ?? [
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)\(latestVersion ?? "0.0.0")-build.\(latestBuild ?? "0")-abcdef0.zip",
                    downloadURL: "https://example.test/app.zip",
                    size: 1_000
                ),
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)\(latestVersion ?? "0.0.0")-build.\(latestBuild ?? "0")-abcdef0.manifest.json",
                    downloadURL: "https://example.test/manifest.json",
                    size: 500
                )
            ],
            assetNamingPolicy: .workbench(namePrefix: WorkbenchRelease.artifactNamePrefix),
            detail: "\(latestVersion ?? "no release") \(status.rawValue)"
        )
    }
}
