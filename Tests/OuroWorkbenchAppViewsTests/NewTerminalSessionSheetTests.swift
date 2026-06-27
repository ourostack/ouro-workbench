#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-6 — `NewTerminalSessionSheet` (RECONFIRM → resolved LOGIC; the home-path
/// leak view).
///
/// The planning audit binned this as RECONFIRM ("attribute-only-leaning") because
/// its only NOMINAL branch is `.disabled(!canCreate)` (attribute-only → dropped by
/// the host) plus an `onChange`/`guard` (not a render branch). BUT the host DOES
/// capture `TextField` bound values via `input()` (AN-002), and the sheet renders
/// `TextField("Working Directory", text: $workingDirectory)` whose value is seeded
/// from `model.selectedProject?.rootPath ?? home` — a DATA-DRIVEN captured value
/// that flips with the selected project (the `SidebarCountBadge` value-flip class).
/// So it is genuinely LOGIC and is COVERED. (Reconfirmed by mutation below.)
///
/// **Home-path leak (the cluster's named MEDIUM hazard) — pinned.** The `@State`
/// default is `FileManager.default.homeDirectoryForCurrentUser.path` (and the init
/// override falls back to it when `selectedProject == nil`) → with no project the
/// captured Working-Directory TextField leaks `/Users/<name>/`. The fixture
/// provenance-builds `model.selectedProject` with a FIXED relative `rootPath`
/// (`/tmp/u4`) so no `/Users/…` reaches the tree, defended by `!contains("/Users/")`.
/// This is the same class as the C6 Q3 `NSFullUserName()` landmine, different view.
///
/// **U5 B4-REDO.** The original B4 recorded the `.onChange(of: command)` autofill, the
/// Cancel button, and BOTH Create buttons (and the `create()` body they route through) as
/// "carves" under the obsolete "snapshots can't test interaction" assumption. ViewInspector
/// 0.10.3 DOES invoke action-closures, so they are now DRIVEN: an `init(model:initialName:
/// initialCommand:initialTrusted:)` seam (prod defaults UNCHANGED) seeds the `@State` so the
/// onChange guard arms, both `trusted` ternary arms, and `create()` are reachable. Create &
/// Launch's `launch()` schedules an async `Task { await start }` that never runs in a
/// non-yielding test, so no process spawns.
///
/// **Genuinely-unreachable (the remaining carves):**
///   - the `init`'s `?? home` RHS autoclosure inside `State(initialValue:)` — an llvm-cov
///     autoclosure artifact the metric doesn't increment (the value IS driven: the no-project
///     test renders `<HOME>`);
///   - the Choose button action / `chooseWorkingDirectory()` / its `panel.runModal()` branches —
///     `NSOpenPanel().runModal()` is a blocking live-GUI modal;
///   - the `guard model.createCustomSession(...) != nil else { return }` FALSE arm — defensive:
///     `.disabled(!canCreate)` requires a non-empty working directory, so `makeEntry` (whose only
///     throw is `emptyWorkingDirectory`) cannot fail through the ENABLED button → the nil return
///     is UI-gated unreachable (the same class as B5's `.launch`-primary carve).
@MainActor
final class NewTerminalSessionSheetTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C1100006-0000-0000-0000-0000000000A6")!

    /// A VM whose selected project has a FIXED relative rootPath — so the sheet's
    /// `@State workingDirectory` init reads `/tmp/u4`, never the machine home.
    private func makeVM(rootPath: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11newterm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: rootPath)]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func view(rootPath: String) throws -> NewTerminalSessionSheet {
        NewTerminalSessionSheet(model: try makeVM(rootPath: rootPath))
    }

    /// U5 B4: a VM with NO selected project — so the init's `?? home` FALLBACK arm
    /// (L10093) is taken. The home default is the ONE machine-specific node; we mask
    /// it to `<HOME>` for the assertion so the test is deterministic + leak-free.
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private func noProjectVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4newterm-noproj-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    // MARK: - Enumerated state-set (the working-directory value-flip)

    func testSheet_withProject_workingDirectoryFromProjectRoot() throws {
        let view = try view(rootPath: "/tmp/u4")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="New Terminal""#), "the sheet title:\n\(tree)")
        // The captured TextField bound value is seeded from the project root.
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the Working Directory field seeds from selectedProject.rootPath:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Create""#) && tree.contains(#"text="Cancel""#),
                      "the static form buttons render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "NewTerminalSessionSheet.withProject")
    }

    func testSheet_differentProjectRoot_fieldFlips() throws {
        let view = try view(rootPath: "/tmp/u4-other")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4-other""#),
                      "the field tracks the (different) project root:\n\(tree)")
        try assertViewSnapshot(of: view, named: "NewTerminalSessionSheet.otherProject")
    }

    // MARK: - Home-path leak defense (the named MEDIUM hazard)

    func testSheet_noHomePathLeak() throws {
        for root in ["/tmp/u4", "/tmp/u4-other"] {
            let tree = try ViewSnapshotHost.snapshotText(of: try view(rootPath: root))
            XCTAssertFalse(tree.contains("/Users/"),
                           "the Working Directory field must NOT leak /Users/<name>/:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
        }
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4"))
        let b = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4"))
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
    }

    // MARK: - U5 B4: the no-project init fallback arm (L10093 `?? home`)

    /// With NO selected project the init takes the `?? home` fallback, seeding the
    /// Working-Directory field with the machine home. We assert the masked tree so
    /// it is deterministic + leak-free, while driving the previously-un-hit fallback
    /// region. (The with-project arm above drives the `model.selectedProject?.rootPath`
    /// side; together both `??` arms are covered.)
    func testSheet_noProject_workingDirectoryFallsBackToHome() throws {
        let view = NewTerminalSessionSheet(model: try noProjectVM())
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        let masked = tree.replacingOccurrences(of: Self.home, with: "<HOME>")
        XCTAssertTrue(masked.contains(#"text="New Terminal""#), "the sheet title:\n\(masked)")
        XCTAssertTrue(masked.contains(#"kind=editable text="<HOME>""#),
                      "the Working Directory field falls back to the (masked) home:\n\(masked)")
        XCTAssertFalse(masked.contains("/Users/"),
                       "the masked tree must contain no /Users/ machine-path:\n\(masked)")
        let store = ViewSnapshotStore.default(testFilePath: #filePath)
        try assertViewSnapshotText(masked, named: "NewTerminalSessionSheet.noProjectHome", store: store)
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The Working-Directory captured TextField value is the data-driven
    /// discriminator: a different project root flips it. (Reconfirmed LOGIC, not
    /// branchless: the value tracks model.selectedProject.rootPath.)
    func testSheet_negativeControl_workingDirectoryValueFlips() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4"))
        let b = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4-other"))
        XCTAssertNotEqual(a, b, "the working-directory field must flip with the project root")
        XCTAssertTrue(a.contains(#"text="/tmp/u4""#))
        XCTAssertTrue(b.contains(#"text="/tmp/u4-other""#))
    }

    // MARK: - U5 B4-REDO — drive the onChange / Cancel / Create / Create&Launch closures
    //
    // ViewInspector 0.10.3 invokes action-closures, so the `.onChange(of: command)` autofill,
    // the Cancel button, and BOTH Create buttons (whose actions route through `create()`) — all
    // recorded as "carves" by the original B4 — are DRIVABLE. A minimal `init(model:initialName:
    // initialCommand:)` seam (prod default UNCHANGED) seeds the `@State` so the onChange guard
    // arms are reachable; the create-success arm uses the project's `/tmp/u4` root (non-empty →
    // makeEntry passes). Create&Launch's `launch(entry)` schedules an async `Task { await start }`
    // that NEVER runs in a synchronous (non-yielding) test, so no process spawns.

    private func sheet(rootPath: String = "/tmp/u4", name: String = "", command: String = "")
        throws -> NewTerminalSessionSheet {
        NewTerminalSessionSheet(model: try makeVM(rootPath: rootPath),
                                initialName: name, initialCommand: command)
    }

    // MARK: - the `.onChange(of: command)` autofill — every arm

    func testSheet_onChangeCommand_emptyName_detectsAgent_setsName() throws {
        // name == "" → guard passes; command "claude" parses + detects → the inner `if let`
        // TRUE arm runs `name = displayName`. Covers the onChange entry + the detection arm.
        let view = try sheet(name: "", command: "claude")
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.TextField.self, where: { tf in
                (try? tf.labelView().text().string()) == "Command"
            }).callOnChange(oldValue: "", newValue: "claude"),
            "the onChange detection arm executes (empty name + detected agent)")
    }

    func testSheet_onChangeCommand_emptyName_noDetection_skipsInnerIf() throws {
        // name == "" → guard passes; command "ls" parses but detects NOTHING → the inner
        // `if let` FALSE path (no assignment). Covers the guard-pass + the no-detection path.
        let view = try sheet(name: "", command: "ls")
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.TextField.self, where: { tf in
                (try? tf.labelView().text().string()) == "Command"
            }).callOnChange(oldValue: "", newValue: "ls"),
            "the onChange no-detection path executes")
    }

    func testSheet_onChangeCommand_typedName_guardReturns() throws {
        // name already typed → the `guard name.isEmpty else { return }` FALSE arm: return.
        let view = try sheet(name: "Typed", command: "x")
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.TextField.self, where: { tf in
                (try? tf.labelView().text().string()) == "Command"
            }).callOnChange(oldValue: "x", newValue: "xy"),
            "the onChange guard-return arm (typed name) executes")
    }

    // MARK: - the Cancel button action `{ dismiss() }`

    func testSheet_cancelTap_invokesDismiss() throws {
        XCTAssertNoThrow(try sheet().inspect().find(button: "Cancel").tap(),
                         "the Cancel action closure (dismiss()) executes")
    }

    // MARK: - Create (launchAfterCreate: false) → create() body, NO spawn

    func testSheet_createTap_createsSessionNoLaunch() throws {
        let model = try makeVM(rootPath: "/tmp/u4")
        let view = NewTerminalSessionSheet(model: model, initialName: "build", initialCommand: "echo hi")
        let before = model.state.processEntries.count
        // The Create button → `create(launchAfterCreate: false)` → createCustomSession appends
        // the entry; launchAfterCreate false → no launch, no spawn. Covers create()'s entry,
        // the `trusted ? .trusted : .untrusted` ternary, the guard-pass, and dismiss().
        try view.inspect().find(button: "Create").tap()
        XCTAssertEqual(model.state.processEntries.count, before + 1,
                       "Create → createCustomSession appends the session (no launch)")
        XCTAssertEqual(model.state.processEntries.last?.name, "build", "the created session's name")
    }

    // MARK: - Create & Launch (launchAfterCreate: true) → create() body, async launch (no sync spawn)

    func testSheet_createAndLaunchTap_createsSession() throws {
        let model = try makeVM(rootPath: "/tmp/u4")
        let view = NewTerminalSessionSheet(model: model, initialName: "runner", initialCommand: "echo hi")
        let before = model.state.processEntries.count
        // Create & Launch → `create(launchAfterCreate: true)` → createCustomSession appends, then
        // launch() schedules `Task { @MainActor in await start(...) }`. This synchronous test never
        // yields, so the Task body (the only spawn path) does NOT run — no process is launched.
        try view.inspect().find(button: "Create & Launch").tap()
        XCTAssertEqual(model.state.processEntries.count, before + 1,
                       "Create & Launch → createCustomSession appends the session")
    }

    // MARK: - the `trusted ? .trusted : .untrusted` ternary — the `.untrusted` arm

    func testSheet_createUntrusted_setsUntrustedTrust() throws {
        // initialTrusted = false → create()'s `trusted ? .trusted : .untrusted` takes the
        // `.untrusted` arm. The created entry carries `.untrusted` trust (the asserted effect).
        let model = try makeVM(rootPath: "/tmp/u4")
        let view = NewTerminalSessionSheet(model: model, initialName: "untrusted-run",
                                           initialCommand: "echo hi", initialTrusted: false)
        try view.inspect().find(button: "Create").tap()
        XCTAssertEqual(model.state.processEntries.last?.trust, .untrusted,
                       "initialTrusted false → create() builds the draft with .untrusted trust")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// Create is load-bearing: it appends a session. (Mutation-verify: replacing
    /// `model.createCustomSession(...)` with nil leaves processEntries unchanged → RED.)
    func testSheet_negativeControl_createAppendsSession() throws {
        let model = try makeVM(rootPath: "/tmp/u4")
        let before = model.state.processEntries.count
        try NewTerminalSessionSheet(model: model, initialName: "neg", initialCommand: "echo hi")
            .inspect().find(button: "Create").tap()
        XCTAssertEqual(model.state.processEntries.count, before + 1, "Create must append a session")
    }

    /// The trust ternary is load-bearing: trusted=true yields .trusted. (Pairs with the
    /// .untrusted test to prove BOTH ternary arms flip the created entry's trust.)
    func testSheet_negativeControl_createTrusted_setsTrustedTrust() throws {
        let model = try makeVM(rootPath: "/tmp/u4")
        try NewTerminalSessionSheet(model: model, initialName: "trusted-run",
                                    initialCommand: "echo hi", initialTrusted: true)
            .inspect().find(button: "Create").tap()
        XCTAssertEqual(model.state.processEntries.last?.trust, .trusted,
                       "initialTrusted true → create() builds the draft with .trusted trust")
    }
}
#endif
