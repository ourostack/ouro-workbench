import XCTest
import OuroAppShellConsumerTesting
import OuroAppShellUI
@testable import OuroWorkbenchCore
@testable import OuroWorkbenchShellAdapter

final class WorkbenchShellPresentationTests: XCTestCase {
    func testShellContractIsValidAndDeclaresSharedSurfaces() {
        let contract = WorkbenchShellContract.contract

        OuroAppShellContractAssertions.assertValid(contract)
        OuroAppShellContractAssertions.assertRequiresShellFirstSurfaces(
            contract,
            WorkbenchShellContract.requiredSurfaces
        )
        OuroAppShellContractAssertions.assertCommandManifestMatchesReference(contract)
    }

    func testShellContractMatchesRuntimeIdentityReleaseAndShortcutSurfaces() {
        let contract = WorkbenchShellContract.contract

        XCTAssertEqual(contract.identity.appName, WorkbenchRelease.appName)
        XCTAssertEqual(contract.identity.bundleIdentifier, WorkbenchRelease.bundleIdentifier)
        XCTAssertEqual(contract.identity.repository, WorkbenchRelease.repository)
        XCTAssertEqual(contract.identity.version, WorkbenchRelease.version)
        XCTAssertEqual(contract.identity.userAgent, WorkbenchRelease.userAgent())
        XCTAssertEqual(contract.identity.distributionChannel, .directDownload)
        XCTAssertEqual(contract.identity.releasePageURL.absoluteString, "https://github.com/ourostack/ouro-workbench/releases/latest")

        XCTAssertEqual(contract.releaseUpdates?.policy, WorkbenchReleasePolicy.releaseUpdatePolicy)
        XCTAssertEqual(contract.releaseUpdates?.supportsInstallAndRelaunch, true)
        XCTAssertEqual(contract.releaseUpdates?.supportsReleasePage, true)

        XCTAssertEqual(contract.about?.subtitle, WorkbenchShellAboutPresentation.subtitle)
        XCTAssertEqual(contract.about?.repositoryURL?.absoluteString, "https://github.com/ourostack/ouro-workbench")

        XCTAssertEqual(contract.commandReference?.title, WorkbenchShellCommandReference.title)
        XCTAssertEqual(contract.commandReference?.commandCount, WorkbenchShellCommandReference.items.count)
        XCTAssertEqual(contract.commandReference?.sections, WorkbenchShellCommandReference.sectionOrder)
        XCTAssertEqual(contract.commandReference?.entryPoint, "Ouro Workbench > Keyboard Shortcuts")
        OuroAppShellContractAssertions.assertCommandManifest(
            contract,
            matches: WorkbenchShellCommandReference.manifest.commands
        )
    }

    func testShellCommandManifestPinsShortcutSurfaceRows() {
        let manifest = WorkbenchShellCommandReference.manifest

        XCTAssertEqual(manifest.count, WorkbenchShellCommandReference.items.count)
        XCTAssertEqual(manifest.sections, WorkbenchShellCommandReference.sectionOrder)
        XCTAssertTrue(manifest.commands.contains { command in
            command.title == "Show the keyboard shortcut help"
                && command.shortcut == "⌘/"
                && command.section == "App"
        })
    }

    func testShellContractDocumentsUtilityWindowsAndSettingsEntryPoint() {
        let contract = WorkbenchShellContract.contract

        XCTAssertEqual(contract.utilityWindows.map(\.id), [
            "about",
            "keyboard-shortcuts",
            "settings"
        ])
        XCTAssertEqual(contract.utilityWindows.map(\.title), [
            "About Ouro Workbench",
            WorkbenchShellCommandReference.title,
            "Settings"
        ])
        XCTAssertEqual(contract.utilityWindows.map(\.surface), [
            .about,
            .keyboardShortcuts,
            .settings
        ])
        XCTAssertEqual(contract.settings?.entryPoint, "Ouro Workbench > Settings (Command ,)")
        XCTAssertEqual(contract.settings?.appOwnedSections, [
            "Terminal",
            "Appearance",
            "Workbench Chrome",
            "Startup",
            "Software Updates",
            "Boss",
            "Advanced"
        ])
    }

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

    @MainActor
    func testShellAboutViewConstructsSharedAboutBody() {
        let view = WorkbenchShellAboutView(
            presentation: WorkbenchShellAboutPresentation(buildHash: "abc1234"),
            updateState: ReleaseUpdateViewState(kind: .current, statusLine: "up to date"),
            updateActions: ReleaseUpdateActions(checkForUpdates: {}),
            aboutActions: AppShellAboutActions()
        )

        let body = view.body

        XCTAssertTrue(String(describing: type(of: body)).contains("AppShellAboutView"))
    }

    @MainActor
    func testShellUpdatePanelViewConstructsSharedReleaseBody() {
        let view = WorkbenchShellUpdatePanelView(
            state: ReleaseUpdateViewState(kind: .notChecked, statusLine: "not checked"),
            actions: ReleaseUpdateActions(checkForUpdates: {}),
            showTitle: true
        )

        let body = view.body

        XCTAssertFalse(String(describing: type(of: body)).isEmpty)
    }

    func testCommandReferenceMapsGuideIntoShellItems() {
        let items = WorkbenchShellCommandReference.items
        let guideRows = WorkbenchGuide.shortcutCategories.flatMap(\.shortcuts)

        XCTAssertEqual(WorkbenchShellCommandReference.title, "Keyboard Shortcuts")
        XCTAssertEqual(WorkbenchShellCommandReference.subtitle, "Press ⌘/ from anywhere to bring this back")
        XCTAssertEqual(WorkbenchShellCommandReference.sectionOrder, WorkbenchGuide.shortcutCategories.map(\.title))
        XCTAssertEqual(items.count, guideRows.count)
        XCTAssertTrue(items.contains {
            $0.title == "Open the command palette"
                && $0.shortcut == "⌘K"
                && $0.section == "Boss + Agents"
        })
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
            assetNamingPolicy: WorkbenchReleasePolicy.assetNamingPolicy,
            detail: "\(latestVersion ?? "no release") \(status.rawValue)"
        )
    }
}
