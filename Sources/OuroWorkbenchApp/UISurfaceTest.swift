#if os(macOS)
import AppKit
import Darwin
import OuroAppShellUI
import OuroWorkbenchCore
import SwiftUI

@MainActor
final class WorkbenchUISurfaceTester {
    func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouro-workbench-ui-surface-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WorkbenchViewModel(paths: WorkbenchPaths(rootURL: root))
        model.releaseUpdateSnapshot = currentSnapshot()

        let aboutSize = fittingSize(AboutSheet(model: model), constrainedTo: NSSize(width: 520, height: 500))
        let settingsUpdateSize = fittingSize(
            WorkbenchReleaseUpdateControls(model: model, showTitle: false),
            constrainedTo: NSSize(width: 520, height: 180)
        )
        let dashboardUpdateSize = fittingSize(
            ReleaseUpdateView(model: model),
            constrainedTo: NSSize(width: 720, height: 180)
        )
        let aboutSemanticsOK = AppShellAboutModel(
            appName: WorkbenchRelease.appName,
            versionLine: "Version \(WorkbenchRelease.version) - Build test",
            subtitle: "Terminal-first orchestrator for autonomous Ouro agents.",
            iconSystemName: "infinity"
        ).accessibilityLabel == "About Ouro Workbench"

        let currentStateOK = model.appShellUpdateState.kind == .current
            && model.appShellUpdateState.metadata.contains { $0.label == "Channel" && $0.value == "Direct download" }
            && !model.appShellUpdateState.canInstallUpdate

        model.releaseUpdateSnapshot = updateAvailableSnapshot()
        let availableState = model.appShellUpdateState
        let availableStateOK = availableState.kind == .updateAvailable
            && availableState.canReviewUpdate
            && availableState.canInstallUpdate
            && availableState.canOpenReleasePage
            && availableState.detail?.contains("running terminals keep running") == true

        model.releaseUpdateInstallError = "codesign failed"
        let failedState = model.appShellUpdateState
        let failedStateOK = failedState.kind == .failed
            && failedState.warning == "codesign failed"
        model.releaseUpdateIsChecking = true
        let failedThenCheckingState = model.appShellUpdateState
        let failedThenCheckingOK = failedThenCheckingState.kind == .checking
            && failedThenCheckingState.warning == nil
            && !failedThenCheckingState.canReviewUpdate
            && !failedThenCheckingState.canInstallUpdate
        model.releaseUpdateIsChecking = false

        let sizeOK = aboutSize.width <= 540
            && aboutSize.height <= 540
            && settingsUpdateSize.width <= 540
            && settingsUpdateSize.height <= 220
            && dashboardUpdateSize.width <= 760
            && dashboardUpdateSize.height <= 220
        let labelsOK = aboutSemanticsOK

        print(String(format: "about fitting size: %.1fx%.1f %@", aboutSize.width, aboutSize.height, sizeOK ? "ok" : "FAIL"))
        print(String(format: "settings update fitting size: %.1fx%.1f", settingsUpdateSize.width, settingsUpdateSize.height))
        print(String(format: "dashboard update fitting size: %.1fx%.1f", dashboardUpdateSize.width, dashboardUpdateSize.height))
        print("current update state: \(currentStateOK ? "ok" : "FAIL")")
        print("available update state: \(availableStateOK ? "ok" : "FAIL")")
        print("failed update state: \(failedStateOK ? "ok" : "FAIL")")
        print("failed then checking state: \(failedThenCheckingOK ? "ok" : "FAIL")")
        print("about shared semantics: \(labelsOK ? "ok" : "FAIL")")

        Darwin.exit(sizeOK && labelsOK && currentStateOK && availableStateOK && failedStateOK && failedThenCheckingOK ? 0 : 1)
    }

    private func currentSnapshot() -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: .current,
            currentVersion: WorkbenchRelease.version,
            currentBuild: "266",
            latestVersion: WorkbenchRelease.version,
            latestBuild: "266",
            tagName: "v\(WorkbenchRelease.version)",
            htmlURL: "https://github.com/\(WorkbenchRelease.repository)/releases/latest",
            assets: [],
            assetNamingPolicy: .workbench(namePrefix: WorkbenchRelease.artifactNamePrefix),
            detail: "Ouro Workbench is current."
        )
    }

    private func updateAvailableSnapshot() -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: .updateAvailable,
            currentVersion: WorkbenchRelease.version,
            currentBuild: "266",
            latestVersion: "0.1.999",
            latestBuild: "267",
            tagName: "v0.1.999",
            htmlURL: "https://github.com/\(WorkbenchRelease.repository)/releases/latest",
            assets: [
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)0.1.999-build.267-abcdef0.zip",
                    downloadURL: "https://example.test/\(WorkbenchRelease.artifactNamePrefix)0.1.999-build.267-abcdef0.zip",
                    size: 1_000
                ),
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)0.1.999-build.267-abcdef0.manifest.json",
                    downloadURL: "https://example.test/\(WorkbenchRelease.artifactNamePrefix)0.1.999-build.267-abcdef0.manifest.json",
                    size: 500
                )
            ],
            assetNamingPolicy: .workbench(namePrefix: WorkbenchRelease.artifactNamePrefix),
            detail: "Ouro Workbench 0.1.999 is available."
        )
    }

    private func fittingSize<Content: View>(_ view: Content, constrainedTo size: NSSize) -> NSSize {
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        return host.view.fittingSize
    }

}
#endif
