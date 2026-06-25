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

        // Slice ②b — the migrated-workspace render smoke: seed a state that has gone
        // through ②a's migration (one "Restored workspace" + a pinned single-tab + an
        // empty workspace) and assert the workspace sidebar + cmux tab-strip resolve and
        // render/fit without crash. This is the App-side "renders correctly" proof for
        // the migrated "Restored workspace".
        let workspaceSmokeOK = runMigratedWorkspaceSmoke()

        print(String(format: "about fitting size: %.1fx%.1f %@", aboutSize.width, aboutSize.height, sizeOK ? "ok" : "FAIL"))
        print(String(format: "settings update fitting size: %.1fx%.1f", settingsUpdateSize.width, settingsUpdateSize.height))
        print(String(format: "dashboard update fitting size: %.1fx%.1f", dashboardUpdateSize.width, dashboardUpdateSize.height))
        print("current update state: \(currentStateOK ? "ok" : "FAIL")")
        print("available update state: \(availableStateOK ? "ok" : "FAIL")")
        print("failed update state: \(failedStateOK ? "ok" : "FAIL")")
        print("failed then checking state: \(failedThenCheckingOK ? "ok" : "FAIL")")
        print("about shared semantics: \(labelsOK ? "ok" : "FAIL")")
        print("migrated workspace render: \(workspaceSmokeOK ? "ok" : "FAIL")")

        Darwin.exit(
            sizeOK && labelsOK && currentStateOK && availableStateOK
                && failedStateOK && failedThenCheckingOK && workspaceSmokeOK ? 0 : 1
        )
    }

    /// Seed a migrated `WorkspaceState` into a fresh root, build a view-model from it,
    /// and assert the workspace sidebar + cmux tab-strip resolve the migrated structure
    /// and render/fit without crash. Returns true on success.
    private func runMigratedWorkspaceSmoke() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouro-workbench-ws-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a migrated state (schema v2) to the model's state file so load() picks
        // it up. Mirrors the Unit-0 fixture: pinned single-tab workspace, "Restored
        // workspace" with several tabs (one renamed via tabNameOverride, one archived),
        // and an empty workspace.
        let projectId = UUID()
        let active = ProcessEntry(
            projectId: projectId, name: "ouro-workbench", kind: .terminalAgent,
            executable: "claude", workingDirectory: "/tmp/a", attention: .active
        )
        let renamed = ProcessEntry(
            projectId: projectId, name: "ms-desk (auto)", kind: .terminalAgent,
            executable: "claude", workingDirectory: "/tmp/b", attention: .waitingOnHuman,
            tabNameOverride: "Agent Substrate"
        )
        let shell = ProcessEntry(
            projectId: projectId, name: "deploy shell", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/c", attention: .idle
        )
        let archived = ProcessEntry(
            projectId: projectId, name: "archived run", kind: .terminalAgent,
            executable: "claude", workingDirectory: "/tmp/d", isArchived: true, attention: .idle
        )
        let pinnedTab = ProcessEntry(
            projectId: projectId, name: "pinned single tab", kind: .terminalAgent,
            executable: "codex", workingDirectory: "/tmp/e", attention: .needsBossReview
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [WorkbenchProject(id: projectId, name: "Home", rootPath: "/tmp")],
            processEntries: [active, renamed, shell, archived, pinnedTab],
            workspaces: [
                Workspace(autoName: "Pinned workspace", isPinned: true, tabIds: [pinnedTab.id]),
                Workspace(
                    autoName: WorkspaceState.migratedWorkspaceSeedName,
                    tabIds: [active.id, renamed.id, shell.id, archived.id]
                ),
                Workspace(autoName: "Empty workspace", tabIds: []),
            ]
        )
        do {
            try WorkbenchStore(stateURL: root.appendingPathComponent("workspace-state.json")).save(state)
        } catch {
            print("migrated workspace smoke: save failed \(error)")
            return false
        }

        let model = WorkbenchViewModel(paths: WorkbenchPaths(rootURL: root))

        // The seam resolved the migrated structure: pinned-first ordering, the
        // "Restored workspace" carries all its tabs (the renamed one shows its
        // override), and the empty workspace renders (not hidden).
        let rows = model.workspaceSidebarModel.rows
        let names = rows.map(\.effectiveName)
        guard names == ["Pinned workspace", WorkspaceState.migratedWorkspaceSeedName, "Empty workspace"] else {
            print("migrated workspace smoke: unexpected row order \(names)")
            return false
        }
        guard let restored = rows.first(where: { $0.effectiveName == WorkspaceState.migratedWorkspaceSeedName }),
              restored.tabs.count == 3,
              restored.archivedTabs.count == 1,
              restored.tabs.contains(where: { $0.effectiveTabName == "Agent Substrate" }) else {
            print("migrated workspace smoke: Restored workspace did not resolve as expected")
            return false
        }
        guard rows.first(where: { $0.effectiveName == "Empty workspace" })?.isEmpty == true else {
            print("migrated workspace smoke: empty workspace not marked empty")
            return false
        }
        // Exactly one workspace is active, and it coheres with the restored selection:
        // load() restores a selected entry, whose workspace becomes active (the
        // click-to-activate rule). With no entry selected the seam falls back to the
        // first pinned workspace (DB2).
        guard rows.filter(\.isActive).count == 1, let activeRow = model.activeWorkspaceRow else {
            print("migrated workspace smoke: no single active workspace")
            return false
        }
        if let selected = model.selectedEntryID {
            guard activeRow.tabs.contains(where: { $0.id == selected }) else {
                print("migrated workspace smoke: active workspace does not contain the selected tab")
                return false
            }
        }
        // Pure nil-fallback: clearing both selections lands on the first pinned workspace.
        model.selectedWorkspaceID = nil
        let fallbackRows = WorkspaceSidebarPresentation.resolve(
            workspaces: model.state.workspaces, entries: model.workspaceTabEntries, selectedWorkspaceId: nil
        ).rows
        guard fallbackRows.first(where: { $0.isActive })?.effectiveName == "Pinned workspace" else {
            print("migrated workspace smoke: nil-selection fallback is not the pinned workspace")
            return false
        }

        // The sidebar + tab-strip render/fit without crash.
        let sidebarSize = fittingSize(
            WorkbenchSidebarView(model: model), constrainedTo: NSSize(width: 260, height: 700)
        )
        let stripSize = fittingSize(
            WorkspaceTabStrip(model: model), constrainedTo: NSSize(width: 760, height: 80)
        )
        guard sidebarSize.width > 0, sidebarSize.height > 0, stripSize.height > 0 else {
            print("migrated workspace smoke: sidebar/strip failed to render a positive size")
            return false
        }
        print(String(
            format: "migrated workspace sizes: sidebar %.0fx%.0f, strip %.0fx%.0f",
            sidebarSize.width, sidebarSize.height, stripSize.width, stripSize.height
        ))
        return true
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
