#if os(macOS)
import AppKit
import Darwin
import OuroAppShellUI
import OuroWorkbenchAppViews
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

        // Slice ②d — the in-app editing affordances smoke: rename/pin/remove-custom-name
        // mutators react through the existing seam, the inline editors render without
        // crash for both a workspace and a tab, and an empty/whitespace commit is a no-op.
        let editingSmokeOK = runEditingAffordancesSmoke()

        print(String(format: "about fitting size: %.1fx%.1f %@", aboutSize.width, aboutSize.height, sizeOK ? "ok" : "FAIL"))
        print(String(format: "settings update fitting size: %.1fx%.1f", settingsUpdateSize.width, settingsUpdateSize.height))
        print(String(format: "dashboard update fitting size: %.1fx%.1f", dashboardUpdateSize.width, dashboardUpdateSize.height))
        print("current update state: \(currentStateOK ? "ok" : "FAIL")")
        print("available update state: \(availableStateOK ? "ok" : "FAIL")")
        print("failed update state: \(failedStateOK ? "ok" : "FAIL")")
        print("failed then checking state: \(failedThenCheckingOK ? "ok" : "FAIL")")
        print("about shared semantics: \(labelsOK ? "ok" : "FAIL")")
        print("migrated workspace render: \(workspaceSmokeOK ? "ok" : "FAIL")")
        print("②d editing affordances: \(editingSmokeOK ? "ok" : "FAIL")")

        Darwin.exit(
            sizeOK && labelsOK && currentStateOK && availableStateOK
                && failedStateOK && failedThenCheckingOK && workspaceSmokeOK
                && editingSmokeOK ? 0 : 1
        )
    }

    /// Slice ②d — drive the in-app editing affordances end-to-end against a seeded
    /// view-model: the pure mutators react through the existing `WorkspaceSidebarPresentation`
    /// seam (pin re-sort D2d-4, override → revert, tab override), the inline editors render
    /// without crash for a workspace AND a tab, and an empty/whitespace commit is a no-op
    /// (D2d-1 — no override written). Returns true on success.
    private func runEditingAffordancesSmoke() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouro-workbench-2d-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectId = UUID()
        // One tab the workspace will own; one extra entry so the state is realistic.
        let tab = ProcessEntry(
            projectId: projectId, name: "auto tab name", kind: .terminalAgent,
            executable: "claude", workingDirectory: "/tmp/a", attention: .active
        )
        // Two workspaces: one already custom-named (so "Remove Custom Name" is live), one
        // on its autoName (so a rename + pin can be exercised). The unpinned/auto one is
        // FIRST so a pin toggle visibly re-sorts it ahead of the custom one.
        let autoWS = Workspace(autoName: "Auto Workspace", isPinned: false, tabIds: [tab.id])
        let customWS = Workspace(autoName: "auto", nameOverride: "Custom Workspace", isPinned: false)
        let state = WorkspaceState(
            projects: [WorkbenchProject(id: projectId, name: "Home", rootPath: "/tmp")],
            processEntries: [tab],
            workspaces: [autoWS, customWS]
        )
        do {
            try WorkbenchStore(stateURL: root.appendingPathComponent("workspace-state.json")).save(state)
        } catch {
            print("②d smoke: seed save failed \(error)")
            return false
        }
        let model = WorkbenchViewModel(paths: WorkbenchPaths(rootURL: root))

        // Pin re-sort (D2d-4): toggling the unpinned auto workspace must move it pinned-first.
        model.toggleWorkspacePin(autoWS.id)
        let afterPin = model.workspaceSidebarModel.rows
        guard afterPin.first?.id == autoWS.id, afterPin.first?.isPinned == true else {
            print("②d smoke: pin toggle did not re-sort the workspace pinned-first")
            return false
        }

        // Rename a workspace: effectiveName changes to the trimmed override.
        model.renameWorkspace(autoWS.id, to: "  Renamed WS  ")
        guard model.state.workspaces.first(where: { $0.id == autoWS.id })?.effectiveName == "Renamed WS" else {
            print("②d smoke: rename did not set the trimmed override")
            return false
        }

        // Remove the custom name: revert to autoName.
        model.removeCustomWorkspaceName(customWS.id)
        guard let revertedWS = model.state.workspaces.first(where: { $0.id == customWS.id }),
              revertedWS.nameOverride == nil, revertedWS.effectiveName == "auto" else {
            print("②d smoke: remove-custom-name did not revert to autoName")
            return false
        }

        // Tab rename: effectiveTabName changes.
        model.renameTab(tab.id, to: "Renamed Tab")
        guard model.state.processEntries.first(where: { $0.id == tab.id })?.effectiveTabName == "Renamed Tab" else {
            print("②d smoke: tab rename did not set the tab override")
            return false
        }

        // D2d-1 — an empty/whitespace commit through the editor is a NO-OP: no override is
        // written and the existing name persists. Begin a rename, blank the draft, commit.
        model.beginRename(.workspace(autoWS.id), prefill: "Renamed WS")
        model.inlineRename.draft = "   "
        model.commitRename()
        guard model.state.workspaces.first(where: { $0.id == autoWS.id })?.effectiveName == "Renamed WS",
              !model.inlineRename.isEditing(.workspace(autoWS.id)) else {
            print("②d smoke: empty commit was not a no-op (override changed or editor stayed open)")
            return false
        }

        // The inline editors render without crash for BOTH a workspace and a tab.
        model.beginRename(.workspace(autoWS.id), prefill: "Renamed WS")
        let sidebarEditingSize = fittingSize(
            WorkbenchSidebarView(model: model), constrainedTo: NSSize(width: 260, height: 700)
        )
        model.cancelRename()
        guard let firstTab = model.activeWorkspaceRow?.tabs.first else {
            print("②d smoke: no tab to render the tab editor for")
            return false
        }
        model.selectedEntryID = firstTab.id
        model.beginRename(.tab(firstTab.id), prefill: "Renamed Tab")
        let stripEditingSize = fittingSize(
            WorkspaceTabStrip(model: model), constrainedTo: NSSize(width: 760, height: 80)
        )
        model.cancelRename()
        guard sidebarEditingSize.width > 0, sidebarEditingSize.height > 0, stripEditingSize.height > 0 else {
            print("②d smoke: inline editors failed to render a positive size")
            return false
        }
        print(String(
            format: "②d editing sizes: sidebar(edit) %.0fx%.0f, strip(edit) %.0fx%.0f",
            sidebarEditingSize.width, sidebarEditingSize.height, stripEditingSize.width, stripEditingSize.height
        ))
        return true
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
        // it up. FIX PASS (FP2): the migrated state is produced by driving the REAL
        // `migrateToWorkspaceStructure()` — NOT by hand-building tabIds. The previous
        // smoke hand-injected the archived id into the "Restored workspace" tabIds, a
        // state the real migration NEVER produces (it folds ONLY non-archived entries),
        // which masked the CRITICAL (archived terminals orphaned after upgrade). Here
        // the archived entry is left for the migration to EXCLUDE, and we assert the
        // GLOBAL Archived resolution still surfaces it (DB10).
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
        // Pre-existing structure BEFORE migration: a pinned single-tab workspace and an
        // empty workspace. The migration folds the UNMAPPED, NON-ARCHIVED entries
        // (active/renamed/shell) into a fresh "Restored workspace"; the archived entry
        // is excluded (left out of every tabIds), and the already-mapped pinnedTab stays.
        var state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [WorkbenchProject(id: projectId, name: "Home", rootPath: "/tmp")],
            processEntries: [active, renamed, shell, archived, pinnedTab],
            workspaces: [
                Workspace(autoName: "Pinned workspace", isPinned: true, tabIds: [pinnedTab.id]),
                Workspace(autoName: "Empty workspace", tabIds: []),
            ]
        )
        state.migrateToWorkspaceStructure()
        // Honesty check: the real migration produced a "Restored workspace" that does
        // NOT contain the archived id (the structural cause of the CRITICAL).
        guard let migratedRestored = state.workspaces.first(where: {
            $0.autoName == WorkspaceState.migratedWorkspaceSeedName
        }) else {
            print("migrated workspace smoke: real migration did not create a Restored workspace")
            return false
        }
        guard !migratedRestored.tabIds.contains(archived.id) else {
            print("migrated workspace smoke: archived id leaked into Restored workspace tabIds")
            return false
        }
        do {
            try WorkbenchStore(stateURL: root.appendingPathComponent("workspace-state.json")).save(state)
        } catch {
            print("migrated workspace smoke: save failed \(error)")
            return false
        }

        let model = WorkbenchViewModel(paths: WorkbenchPaths(rootURL: root))

        // The seam resolved the migrated structure: pinned-first ordering, the
        // "Restored workspace" carries its active tabs (the renamed one shows its
        // override), and the empty workspace renders (not hidden). FP2: the real
        // migration APPENDS the "Restored workspace" after the pre-existing
        // workspaces, so the unpinned order is [Empty (pre-existing), Restored
        // (appended)] — pinned-first puts "Pinned workspace" at the head.
        let rows = model.workspaceSidebarModel.rows
        let names = rows.map(\.effectiveName)
        guard names == ["Pinned workspace", "Empty workspace", WorkspaceState.migratedWorkspaceSeedName] else {
            print("migrated workspace smoke: unexpected row order \(names)")
            return false
        }
        guard let restored = rows.first(where: { $0.effectiveName == WorkspaceState.migratedWorkspaceSeedName }),
              restored.tabs.count == 3,
              // FP2: the real migration left the archived id OUT of tabIds, so the
              // per-workspace partition is EMPTY (proving the previous smoke's
              // hand-injected `archivedTabs.count == 1` was dishonest).
              restored.archivedTabs.isEmpty,
              restored.tabs.contains(where: { $0.effectiveTabName == "Agent Substrate" }) else {
            print("migrated workspace smoke: Restored workspace did not resolve as expected")
            return false
        }
        // FP1/DB10 — the CRITICAL regression: even though the archived entry is in NO
        // workspace's tabIds (real migration), it MUST still be globally visible +
        // restorable. The App's Archived section reads this global resolution.
        let globallyArchived = model.archivedSessionEntries
        guard globallyArchived.contains(where: { $0.id == archived.id }) else {
            print("migrated workspace smoke: archived entry orphaned — not in the global Archived section")
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
