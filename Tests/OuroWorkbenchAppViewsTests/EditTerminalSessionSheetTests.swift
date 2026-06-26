#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `EditTerminalSessionSheet` (22 uncovered regions: the whole view body
/// + the two `init` arms were never driven by the campaign).
///
/// The sheet's `init` seeds its `@State` from `model.customSessionDraft(for:)`
/// when the entry IS a custom session (`.shell`/`.terminalAgent`), else it falls
/// back to a hand-built `CustomTerminalSessionDraft` from the entry's own fields
/// (`.command`/`.ouroBoss` — non-custom kinds). BOTH arms are reachable through
/// the real seam by varying the entry's `kind`, so both are DRIVEN here, each
/// asserting the captured `TextField` bound values (Name/Command/Working-Directory)
/// that the seeded draft flows into.
///
/// **Path-leak (the cluster's MEDIUM hazard) — pinned.** `workingDirectory` is
/// seeded from `entry.workingDirectory`; a FIXED relative `/tmp/u4` keeps `/Users/`
/// out of the captured tree, defended by `!contains("/Users/")`.
///
/// **U5 B4-REDO:** the original B4 recorded `save()` + the Cancel/Save button ACTION
/// closures as "carves" under the obsolete "snapshots can't test interaction" assumption.
/// ViewInspector 0.10.3 DOES invoke action-closures, so they are now DRIVEN (see the B4-REDO
/// section): the init seeds the form from the entry (Save enabled), and a VM that CONTAINS
/// the entry lets `updateCustomSession` observably replace it. Both Save guard arms (success
/// + the active-session "Stop … before editing" fail) and both `trusted` ternary arms are
/// driven.
///
/// **Genuinely-unreachable (the only remaining carves):** the Choose button action
/// `{ chooseWorkingDirectory() }` + `chooseWorkingDirectory()` itself + its `panel.runModal()`
/// branches — `NSOpenPanel().runModal()` is a blocking live-GUI modal, categorically
/// untestable in-process.
@MainActor
final class EditTerminalSessionSheetTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B4ED7E51-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B4ED7E51-0000-0000-0000-0000000000A1")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4editterm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A FIXED entry whose kind decides which `init` arm seeds the draft.
    private func entry(
        kind: ProcessKind,
        name: String = "build",
        executable: String = "/bin/zsh",
        arguments: [String] = ["-lc", "make all"],
        notes: String? = "ship it"
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name,
            kind: kind, executable: executable, arguments: arguments,
            workingDirectory: "/tmp/u4", trust: .trusted, autoResume: true,
            notes: notes)
    }

    private func sheet(for entry: ProcessEntry) throws -> EditTerminalSessionSheet {
        EditTerminalSessionSheet(model: try makeVM(), entry: entry)
    }

    // MARK: - init arm A: custom-session entry → seeded from customSessionDraft

    func testSheet_customSessionEntry_seedsFromDraft() throws {
        // A `.shell` entry IS a custom session, so the init reads
        // `model.customSessionDraft(for: entry)` (the non-fallback arm). The
        // `/bin/zsh -lc make all` form round-trips to command "make all".
        let view = try sheet(for: entry(kind: .shell))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Edit Terminal""#), "the sheet title:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="build""#),
                      "the Name field seeds from the draft:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="make all""#),
                      "the Command field round-trips `-lc <cmd>`:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the Working Directory field seeds from entry.workingDirectory:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Save""#) && tree.contains(#"text="Cancel""#),
                      "the static form buttons render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "EditTerminalSessionSheet.customDraft")
    }

    // MARK: - init arm B: non-custom entry → hand-built fallback draft

    func testSheet_nonCustomEntry_usesFallbackDraft() throws {
        // A `.command` entry is NOT a custom session, so `customSessionDraft(for:)`
        // returns nil and the init takes the `?? CustomTerminalSessionDraft(...)`
        // fallback arm (command defaults to "" there).
        let view = try sheet(for: entry(kind: .command, name: "runner", notes: nil))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"kind=editable text="runner""#),
                      "the fallback draft seeds Name from entry.name:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the fallback seeds Working Directory from entry.workingDirectory:\n\(tree)")
        try assertViewSnapshot(of: view, named: "EditTerminalSessionSheet.fallbackDraft")
    }

    // MARK: - Path-leak defense (P3)

    func testSheet_noMachinePathLeak() throws {
        for kind in [ProcessKind.shell, .command] {
            let tree = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: kind)))
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
        }
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell)))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell)))
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The draft-seeded Name/Command fields are the data-driven discriminators: a
    /// different entry name flips the captured Name TextField value.
    func testSheet_negativeControl_nameFieldFlipsWithEntry() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell, name: "build")))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(for: entry(kind: .shell, name: "deploy")))
        XCTAssertNotEqual(a, b, "the Name field must flip with the entry name")
        XCTAssertTrue(a.contains(#"kind=editable text="build""#))
        XCTAssertTrue(b.contains(#"kind=editable text="deploy""#))
    }

    // MARK: - U5 B4-REDO — drive the Cancel/Save button-action closures (originally WRONGLY carved)
    //
    // ViewInspector 0.10.3 invokes action-closures, so the Cancel + Save button ACTION closures
    // (`dismiss()`, `save()` → the `trusted ? .trusted : .untrusted` ternary, the
    // `model.updateCustomSession` guard, `dismiss()`) the original B4 recorded as "carves" are
    // DRIVABLE. The init already seeds the form from the entry (non-empty workingDirectory →
    // Save enabled). Both Save guard arms: a custom entry NOT in activeSessions → update succeeds
    // (guard-pass → dismiss); the SAME entry registered in activeSessions → update returns false
    // ("Stop … before editing") → guard-fail → return. The entry's trust drives both ternary arms.
    // The only remaining carves are the Choose / `chooseWorkingDirectory()` / `runModal()` modal path.

    private func customTrustEntry(trust: ProcessTrust) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: .shell, executable: "/bin/zsh", arguments: ["-lc", "make all"],
            workingDirectory: "/tmp/u4", trust: trust, autoResume: true, notes: "ship it")
    }

    /// A VM whose state CONTAINS the entry, so `updateCustomSession`'s `replaceEntry`
    /// observably rewrites it (and the entry is a real `.shell` custom session).
    private func vmContaining(_ entry: ProcessEntry) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4redo-editsess-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")],
            processEntries: [entry]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func session(for entry: ProcessEntry) throws -> TerminalSessionController {
        let plan = TerminalCommandPlan(entryId: entry.id, executable: "/bin/zsh", arguments: [],
                                       workingDirectory: "/tmp/u4", reason: "test")
        return try TerminalSessionController(plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    // MARK: - the Cancel button action `{ dismiss() }`

    func testSheet_cancelTap_invokesDismiss() throws {
        let view = try sheet(for: entry(kind: .shell))
        XCTAssertNoThrow(try view.inspect().find(button: "Cancel").tap(),
                         "the Cancel action closure (dismiss()) executes")
    }

    // MARK: - Save (guard-PASS) → save() body + updateCustomSession + dismiss; the .trusted ternary

    func testSheet_saveTap_trustedEntry_updatesAndDismisses() throws {
        let e = customTrustEntry(trust: .trusted)
        let model = try vmContaining(e)
        let view = EditTerminalSessionSheet(model: model, entry: e)
        XCTAssertTrue(model.state.actionLog.isEmpty, "provenance: no edit yet")
        try view.inspect().find(button: "Save").tap()
        // updateCustomSession success → records an "editSession" action log (then dismiss()).
        XCTAssertEqual(model.state.actionLog.first?.action, "editSession",
                       "Save → updateCustomSession succeeds (the .trusted ternary arm)")
    }

    // MARK: - the `.untrusted` ternary arm

    func testSheet_saveTap_untrustedEntry_savesUntrusted() throws {
        let e = customTrustEntry(trust: .untrusted)
        let model = try vmContaining(e)
        let view = EditTerminalSessionSheet(model: model, entry: e)
        try view.inspect().find(button: "Save").tap()
        // The init seeded `trusted=false` from the entry → save()'s ternary takes `.untrusted`;
        // the replaced entry carries `.untrusted` trust.
        XCTAssertEqual(model.state.processEntries.first?.trust, .untrusted,
                       "untrusted entry → save() builds the draft with the .untrusted ternary arm")
    }

    // MARK: - Save (guard-FAIL) → updateCustomSession returns false → return

    func testSheet_saveTap_activeSession_guardFails() throws {
        let e = customTrustEntry(trust: .trusted)
        let model = try vmContaining(e)
        // Register the session → updateCustomSession's `guard activeSessions[id] == nil else`
        // fails ("Stop … before editing") → returns false → the save() `guard … else { return }`.
        model.activeSessions[e.id] = try session(for: e)
        let view = EditTerminalSessionSheet(model: model, entry: e)
        XCTAssertNil(model.errorMessage, "provenance: no error before")
        try view.inspect().find(button: "Save").tap()
        XCTAssertNotNil(model.errorMessage,
                        "an active session → updateCustomSession fails → errorMessage set (no edit log)")
        XCTAssertTrue(model.state.actionLog.isEmpty, "the guard-fail arm records no edit")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// Save is load-bearing: a valid edit records the editSession log. (Mutation-verify: replacing
    /// `model.updateCustomSession(...)` with a constant false leaves the log empty → RED.)
    func testSheet_negativeControl_validSaveRecordsEdit() throws {
        let e = customTrustEntry(trust: .trusted)
        let model = try vmContaining(e)
        try EditTerminalSessionSheet(model: model, entry: e).inspect().find(button: "Save").tap()
        XCTAssertEqual(model.state.actionLog.first?.action, "editSession", "valid Save must record the edit")
    }
}
#endif
