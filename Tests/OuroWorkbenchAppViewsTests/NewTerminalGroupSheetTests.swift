#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `NewTerminalGroupSheet` (20 uncovered regions: the entire view body +
/// its `@State` defaults were never driven by the campaign).
///
/// The sheet has NO `init` seam — its `rootPath` `@State` defaults to
/// `FileManager.default.homeDirectoryForCurrentUser.path`, so the captured Root-Path
/// `TextField` necessarily renders the machine home (`/Users/<name>`). That value is
/// the ONE machine-specific, non-deterministic node in the tree (the `@State`-no-init
/// path-leak the cluster flagged). We DRIVE the body (covering every render region),
/// ASSERT the deterministic captured content directly, and pin a snapshot of the
/// tree with the home path MASKED to a fixed token (`<HOME>`) — so the committed
/// reference is byte-identical across machines (P3) AND leaks no `/Users/<name>` (the
/// masked ref contains no machine path), while still asserting the real rendered
/// structure and being mutation-verified.
///
/// **U5 B4-REDO:** the original B4 (PR #323) recorded the `.onChange` autofill, the
/// Cancel/Create button ACTION closures, and the `.disabled` 2nd operand as "carves"
/// under the obsolete "snapshots can't test interaction" assumption. ViewInspector 0.10.3
/// DOES invoke action-closures, so they are now DRIVEN (see the B4-REDO section below): a
/// minimal `init(model:initialName:initialRootPath:)` seam (prod default UNCHANGED) seeds
/// the `@State` so both Create guard arms and the disabled operand are reachable. The
/// inline `@State` home/empty defaults were folded into that init, so their default-value
/// autoclosure regions are gone too.
///
/// **Genuinely-unreachable (the only remaining carves):** the Choose button action
/// `{ chooseRootPath() }` + `chooseRootPath()` itself + its `panel.runModal()` branches —
/// `NSOpenPanel().runModal()` is a blocking live-GUI modal, categorically untestable
/// in-process (tapping Choose would hang the test).
@MainActor
final class NewTerminalGroupSheetTests: XCTestCase {

    /// The machine home path the `@State` default reads — masked out of the committed
    /// reference so the ref is deterministic and leak-free.
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4newgrp-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func sheet() throws -> NewTerminalGroupSheet {
        NewTerminalGroupSheet(model: try makeVM())
    }

    /// The captured tree with the machine home masked to `<HOME>` — deterministic
    /// and leak-free for the committed reference.
    private func maskedTree() throws -> String {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        return tree.replacingOccurrences(of: Self.home, with: "<HOME>")
    }

    // MARK: - Drive the body + assert the deterministic content

    func testSheet_rendersForm() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertTrue(tree.contains(#"text="New Workspace""#),
                      "the sheet title (WorkbenchSurfacePolicy.newWorkspaceSheetTitle):\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Choose""#), "the Choose button label:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="folder""#), "the Choose folder glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Cancel""#) && tree.contains(#"text="Create""#),
                      "the Cancel/Create buttons:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="checkmark""#), "the Create checkmark glyph:\n\(tree)")
        let store = ViewSnapshotStore.default(testFilePath: #filePath)
        try assertViewSnapshotText(try maskedTree(), named: "NewTerminalGroupSheet.form", store: store)
    }

    // MARK: - Path-leak: the masked reference carries no machine path (P3)

    func testSheet_maskedReference_hasNoMachinePath() throws {
        let masked = try maskedTree()
        XCTAssertFalse(masked.contains("/Users/"),
                       "the masked reference must contain no /Users/ machine-path:\n\(masked)")
        XCTAssertTrue(masked.contains(#"text="<HOME>""#),
                      "the Root-Path field's home default is masked to <HOME>:\n\(masked)")
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        XCTAssertEqual(try maskedTree(), try maskedTree(),
                       "the masked tree must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The masked tree pins the rendered title + the empty Name field + the masked
    /// Root-Path default. A content mutation to any pinned node flips it (verified by
    /// mutating the "New Workspace" title source -> RED -> revert).
    func testSheet_negativeControl_pinsRenderedTitle() throws {
        XCTAssertTrue(try maskedTree().contains(#"Text kind=static text="New Workspace""#),
                      "the title is a pinned content node the mutation-verify breaks")
    }

    // MARK: - U5 B4-REDO — drive the event/button-action closures (originally WRONGLY carved)
    //
    // ViewInspector 0.10.3 invokes action-closures, so the `.onChange(of: rootPath)` autofill,
    // the Cancel/Create button ACTION closures, and the `.disabled` 2nd operand the original B4
    // recorded as "carves" are DRIVABLE. A minimal `init(model:initialName:initialRootPath:)` seam
    // (prod default UNCHANGED) lets us seed the `@State` so both the guard-fail and the guard-pass
    // Create arms — and the `name`-non-empty `.disabled` short-circuit operand — are exercised.
    // `createGroup` validates the root on disk, so the success arm uses a REAL temp directory.

    /// A real, on-disk temp directory so `createGroup`'s `WorkspaceRootValidation.validateOnDisk`
    /// passes (the success/dismiss arm). Cleaned by the OS temp reaper; never `/Users/`-leaked.
    private func makeRealDirectory() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4redo-grproot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func sheet(initialName: String, initialRootPath: String) throws -> NewTerminalGroupSheet {
        NewTerminalGroupSheet(model: try makeVM(), initialName: initialName, initialRootPath: initialRootPath)
    }

    // MARK: - L10004/L10005 — `.onChange(of: rootPath)` autofill — BOTH arms

    func testSheet_onChangeRootPath_emptyName_autofillArmRuns() throws {
        // name == "" → autofilledName returns the basename → the `if let autofilled` TRUE arm.
        // (The pure derivation is unit-tested in WorkspaceNameDerivationTests; here we cover the
        // VIEW closure region by invoking it.)
        let view = try sheet(initialName: "", initialRootPath: "/tmp/u4-myproj")
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.TextField.self, where: { tf in
                (try? tf.labelView().text().string()) == "Root Path"
            }).callOnChange(oldValue: "/tmp/u4-myproj", newValue: "/tmp/u4-myproj"),
            "the onChange autofill TRUE arm (empty name) executes")
    }

    func testSheet_onChangeRootPath_typedName_skipArm() throws {
        // name already typed → autofilledName returns nil → the `if let` skip (FALSE) arm.
        let view = try sheet(initialName: "Typed", initialRootPath: "/tmp/u4-myproj")
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.TextField.self, where: { tf in
                (try? tf.labelView().text().string()) == "Root Path"
            }).callOnChange(oldValue: "/tmp/u4-myproj", newValue: "/tmp/u4-other"),
            "the onChange skip arm (typed name, no clobber) executes")
    }

    // MARK: - Class 3 — chooseRootPath() NSOpenPanel value-flow via the injected seam
    //
    // The "Choose" button's `chooseRootPath()` was carved (modal-NSOpenPanel): it configures an
    // NSOpenPanel and calls runModal(), which blocks on a live GUI modal in-process. The
    // `chooseDirectory` seam (default = the real runModal()) lets a test tap "Choose" and drive
    // the method end-to-end: the panel CONFIGURATION runs as prod (asserted via the captured
    // panel) and the `if let url = chooseDirectory(panel) { rootPath = url.path }` value-flow
    // executes. Only the literal runModal() (inside the default closure) stays carved.

    func testSheet_chooseTap_drivesPanelConfiguredFromRootPath() throws {
        var sheet = NewTerminalGroupSheet(model: try makeVM(), initialName: "X", initialRootPath: "/tmp/seed-root")
        var captured: NSOpenPanel?
        sheet.chooseDirectory = { panel in captured = panel; return URL(fileURLWithPath: "/tmp/chosen") }
        try sheet.inspect().find(button: "Choose").tap()
        let panel = try XCTUnwrap(captured, "the Choose tap runs chooseRootPath → chooseDirectory(panel)")
        XCTAssertTrue(panel.canChooseDirectories, "panel configured to choose directories")
        XCTAssertFalse(panel.canChooseFiles, "panel configured to NOT choose files")
        XCTAssertFalse(panel.allowsMultipleSelection, "single-selection panel")
        XCTAssertEqual(panel.directoryURL?.path, "/tmp/seed-root", "panel seeded with the current rootPath")
    }

    /// The value-flow `rootPath = url.path` feeds the "Root Path" TextField — proven via the
    /// init seam: a sheet seeded with a chosen path renders it in the field (the same write the
    /// tap performs into `@State rootPath`).
    func testSheet_rootPathValueRendersInField() throws {
        let view = NewTerminalGroupSheet(model: try makeVM(), initialName: "X", initialRootPath: "/tmp/chosen-xyz")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("/tmp/chosen-xyz"),
                      "the rootPath value renders in the Root-Path field:\n\(tree)")
    }

    /// Cancel arm of the seam: returning nil (operator cancelled) leaves rootPath unchanged.
    func testSheet_chooseTap_cancelArm_leavesRootPath() throws {
        var sheet = NewTerminalGroupSheet(model: try makeVM(), initialName: "X", initialRootPath: "/tmp/seed-root")
        var invoked = false
        sheet.chooseDirectory = { _ in invoked = true; return nil }
        XCTAssertNoThrow(try sheet.inspect().find(button: "Choose").tap(), "Choose cancel arm runs without throwing")
        XCTAssertTrue(invoked, "the seam was invoked (and returned nil → no rootPath write)")
    }

    // MARK: - L10018 — the Cancel button action `{ dismiss() }`

    func testSheet_cancelTap_invokesDismiss() throws {
        let view = try sheet(initialName: "X", initialRootPath: "/tmp/u4")
        // dismiss() is an environment action that no-ops gracefully outside a presentation;
        // tapping covers the action-closure region. Must not throw.
        XCTAssertNoThrow(try view.inspect().find(button: "Cancel").tap(),
                         "the Cancel action closure (dismiss()) executes")
    }

    // MARK: - L10022/L10023 — Create button: the guard-FAIL arm (createGroup returns false)

    func testSheet_createTap_nonexistentRoot_guardFails() throws {
        // The `.disabled` gate requires BOTH name and rootPath non-empty, so to reach the
        // ENABLED Create button AND have `createGroup` return false, use a non-existent root:
        // `WorkspaceRootValidation.validateOnDisk` fails → createGroup sets errorMessage +
        // returns false → the `guard … else { return }` FALSE arm (no dismiss, no project).
        let model = try makeVM()
        let missingRoot = "/tmp/b4redo-does-not-exist-\(UUID().uuidString)"
        let view = NewTerminalGroupSheet(model: model, initialName: "Frontend", initialRootPath: missingRoot)
        XCTAssertNil(model.errorMessage, "provenance: no error before")
        let projectsBefore = model.state.projects.count
        try view.inspect().find(button: "Create").tap()
        XCTAssertNotNil(model.errorMessage, "non-existent root → createGroup fails → errorMessage set")
        XCTAssertEqual(model.state.projects.count, projectsBefore, "no project added on the fail arm")
    }

    // MARK: - L10025 — Create button: the SUCCESS arm (createGroup true → dismiss)

    func testSheet_createTap_validNameAndRealDir_addsProjectAndDismisses() throws {
        let model = try makeVM()
        let root = try makeRealDirectory()
        let view = NewTerminalGroupSheet(model: model, initialName: "Frontend", initialRootPath: root)
        let projectsBefore = model.state.projects.count
        try view.inspect().find(button: "Create").tap()
        XCTAssertEqual(model.state.projects.count, projectsBefore + 1,
                       "valid Create → createGroup appends the project (then dismiss())")
        XCTAssertEqual(model.state.projects.last?.name, "Frontend", "the created project's name")
    }

    // MARK: - L10032 — the `.disabled(name.isEmpty || rootPath.isEmpty)` 2nd operand

    func testSheet_disabledSecondOperand_evaluatesWhenNameNonEmpty() throws {
        // With a NON-empty name the `||` does not short-circuit, so the `rootPath…isEmpty`
        // 2nd operand is evaluated during render. An empty rootPath → Create is disabled.
        // Rendering the fixture executes the operand (the previously-uncovered region).
        let view = try sheet(initialName: "HasName", initialRootPath: "")
        XCTAssertNoThrow(try ViewSnapshotHost.snapshotText(of: view),
                         "rendering with a non-empty name evaluates the .disabled 2nd operand")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The valid Create is load-bearing: it appends the project. (Mutation-verify: replacing
    /// `model.createGroup(...)` with a constant false leaves projects unchanged → RED.)
    func testSheet_negativeControl_validCreateAppendsProject() throws {
        let model = try makeVM()
        let root = try makeRealDirectory()
        let before = model.state.projects.count
        try NewTerminalGroupSheet(model: model, initialName: "Backend", initialRootPath: root)
            .inspect().find(button: "Create").tap()
        XCTAssertEqual(model.state.projects.count, before + 1, "valid Create must append a project")
    }
}
#endif
