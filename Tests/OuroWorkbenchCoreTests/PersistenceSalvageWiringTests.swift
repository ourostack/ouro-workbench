import XCTest
@testable import OuroWorkbenchCore

/// F5 — durable wiring assertions for the App's `load()` path. The pure Core seams
/// (`QuarantineOutcome` / `quarantineMove`, `DecodeReport` / `postLoadDecision` /
/// `writeSalvageCopy`) are unit-tested + 100% covered in Core; the App that invokes
/// them isn't coverage-gated and can't be click-tested in CI, so we pin its
/// structural wiring the same way `SessionIdBackfillWiringTests` (F4) and
/// `ColdStartHonestWiringTests` (F1) do.
///
/// The ORDERING is load-bearing and the bug is data LOSS, so these pins guard the
/// two ways the original could still be clobbered:
///
///   1. A FAILED quarantine move (`.moveFailed`) must NOT reset-to-empty + save —
///      the original is still at `stateURL` and an atomic save would overwrite it.
///   2. A lossy decode must `writeSalvageCopy()` (copying the ORIGINAL pre-drop
///      bytes) BEFORE the survivors-only `store.save(state)`, and BEFORE any
///      `recordActionLog` (whose internal `save()` would otherwise overwrite the
///      original first).
final class PersistenceSalvageWiringTests: XCTestCase {
    // MARK: - Move-failure arm

    func testLoadCatchSwitchesOnQuarantineOutcome() throws {
        let arm = try loadCatchArm()
        XCTAssertTrue(
            arm.contains("QuarantineOutcome") || arm.contains(".moved") && arm.contains(".moveFailed"),
            "the catch arm must switch on the QuarantineOutcome (both .moved and .moveFailed)"
        )
        XCTAssertTrue(arm.contains(".moved"), "the success arm must handle .moved")
        XCTAssertTrue(arm.contains(".moveFailed"), "the failure arm must handle .moveFailed")
    }

    func testMoveFailedArmDoesNotResetOrSave() throws {
        let failedArm = try moveFailedArm()
        // The whole point: when the move FAILED the original is still at
        // stateURL, so this arm must NOT reset to empty state and must NOT save.
        XCTAssertFalse(
            failedArm.contains("bootstrappedState(from: WorkspaceState())"),
            ".moveFailed must NOT reset to an empty workspace (the original is still live)"
        )
        XCTAssertFalse(
            failedArm.contains("store.save("),
            ".moveFailed must NOT call store.save() — that atomic write would clobber the still-present original"
        )
        XCTAssertFalse(
            failedArm.contains(" save()"),
            ".moveFailed must NOT trigger any save of the empty/in-memory state"
        )
    }

    func testMoveFailedArmNamesTheLiveStateURLNotAPhantomQuarantine() throws {
        let failedArm = try moveFailedArm()
        // The message must point at the file that actually still has the data —
        // store.stateURL — and must NOT claim the data is "preserved" at a
        // quarantine location that doesn't exist (the move failed).
        XCTAssertTrue(
            failedArm.contains("store.stateURL.path") || failedArm.contains("stateURL.path"),
            ".moveFailed must name the live stateURL where the original actually remains"
        )
    }

    // MARK: - Salvage-before-resave (lossy decode) arm

    func testSuccessArmBranchesOnPostLoadDecision() throws {
        let success = try loadSuccessBlock()
        XCTAssertTrue(
            success.contains("postLoadDecision(for:") || success.contains("postLoadDecision("),
            "the success arm must consult postLoadDecision for the loaded decodeReport"
        )
        XCTAssertTrue(
            success.contains("decodeReport"),
            "the decision must be driven by the loaded state's decodeReport"
        )
    }

    func testWriteSalvageCopyPrecedesTheResaveOnLossyLoad() throws {
        let success = try loadSuccessBlock()
        let salvageIdx = try XCTUnwrap(
            success.range(of: "writeSalvageCopy")?.lowerBound,
            "the success arm must call writeSalvageCopy on a lossy load"
        )
        let saveIdx = try XCTUnwrap(
            success.range(of: "store.save(state)")?.lowerBound,
            "the success arm must re-save the loaded state"
        )
        XCTAssertTrue(
            salvageIdx < saveIdx,
            "writeSalvageCopy() must run BEFORE store.save(state) — it copies the ORIGINAL pre-drop bytes, and save() overwrites them"
        )
    }

    func testRecordActionLogForDropDoesNotPrecedeSalvage() throws {
        let success = try loadSuccessBlock()
        guard let salvageIdx = success.range(of: "writeSalvageCopy")?.lowerBound else {
            return XCTFail("expected writeSalvageCopy in the success arm")
        }
        // recordActionLog calls save() INTERNALLY; if it fires before salvage,
        // the internal save overwrites the original first. So any recordActionLog
        // in the salvage path must come AFTER writeSalvageCopy.
        if let logIdx = success.range(of: "recordActionLog")?.lowerBound {
            XCTAssertTrue(
                salvageIdx < logIdx,
                "writeSalvageCopy() must precede recordActionLog (whose internal save() would clobber the original)"
            )
        }
        // And when present, the salvage-drop log must be the loadSalvage action.
        if success.contains("recordActionLog") {
            XCTAssertTrue(
                success.contains("loadSalvage"),
                "the drop must be audited via a loadSalvage action entry"
            )
        }
    }

    // MARK: - Implicit-save suppression arm (the clobber the grep-pin is BLIND to)
    //
    // The ordering pins above only see the EXPLICIT `writeSalvageCopy` /
    // `store.save(state)` calls in load()'s source. They are structurally blind
    // to the IMPLICIT saves: load() restores `selectedProjectID` /
    // `selectedEntryID` / the detail layout, and EACH of those `@Published`
    // assignments fires a `didSet` → `save()` → `store.save(state)`. Because
    // `bootstrappedState` guarantees non-empty `projects`, `selectedProjectID`
    // always transitions nil→non-nil, so that implicit save ALWAYS fires — and
    // it fires ~20 lines BEFORE `writeSalvageCopy()`. On a lossy load it
    // atomically overwrites `stateURL` with the survivors-only state, so the
    // salvage then copies the ALREADY-clobbered file and the dropped rows are
    // gone. The fix is a load-time save-suppression guard (`isLoadingState`).
    // These pins fail on the pre-fix code (no guard) and pass once it exists.

    func testSaveEarlyReturnsWhileLoadingState() throws {
        let save = try viewModelSaveBody()
        // The mechanism: save() must short-circuit while a load is in progress,
        // so the selection/layout `didSet` observers can't persist mid-load.
        XCTAssertTrue(
            save.contains("isLoadingState"),
            "save() must consult isLoadingState so observer-triggered saves are suppressed during load()"
        )
        XCTAssertTrue(
            save.contains("guard !isLoadingState") || save.contains("guard isLoadingState == false"),
            "save() must early-return (guard) while isLoadingState is true — otherwise an implicit didSet save clobbers the original before the salvage"
        )
    }

    func testLoadSuccessBlockSetsLoadingGuardBeforeSelectionAndSalvage() throws {
        let success = try loadSuccessBlock()
        let guardIdx = try XCTUnwrap(
            success.range(of: "isLoadingState = true")?.lowerBound,
            "load()'s success block must set isLoadingState = true to suppress the implicit saves its assignments trigger"
        )
        XCTAssertTrue(
            success.contains("defer { isLoadingState = false }")
                || success.contains("defer { self.isLoadingState = false }"),
            "the guard must be cleared via defer so it's reset no matter how load() exits"
        )
        // The guard MUST be raised before the selection assignment whose didSet
        // would otherwise persist the survivors-only state…
        let selectionIdx = try XCTUnwrap(
            success.range(of: "selectedProjectID =")?.lowerBound,
            "load() must restore selectedProjectID (whose didSet fires the implicit save)"
        )
        XCTAssertTrue(
            guardIdx < selectionIdx,
            "isLoadingState must be raised BEFORE selectedProjectID is assigned — otherwise that assignment's didSet save fires unguarded and clobbers the original"
        )
        // …and, transitively, before the salvage CALL itself (match the call
        // `store.writeSalvageCopy`, not the prose mentions of writeSalvageCopy()
        // in the surrounding comments).
        let salvageIdx = try XCTUnwrap(
            success.range(of: "store.writeSalvageCopy")?.lowerBound,
            "load() must call store.writeSalvageCopy() on a lossy load"
        )
        XCTAssertTrue(
            guardIdx < salvageIdx,
            "the suppression window must already be open by the time the salvage runs"
        )
    }

    func testTrailingDeliberateSaveBypassesTheLoadingGuard() throws {
        let success = try loadSuccessBlock()
        // The guard suppresses save(); the deliberate persistence at the end of
        // load() must therefore call the STORE directly (store.save(state)) so
        // the final survivors-only state is still written — AFTER the salvage.
        XCTAssertTrue(
            success.contains("store.save(state)"),
            "the trailing deliberate save must call store.save(state) directly (bypassing the guarded save()) so the survivors-only state is persisted after the salvage"
        )
    }

    func testSelectionAssignmentsRouteThroughGuardedSave() throws {
        // Confirms the implicit-save vector the ordering grep is blind to is
        // real: the selectedProjectID / selectedEntryID didSet observers call
        // save() (now guarded). If a refactor moved these off save(), the guard
        // would silently stop protecting them — so pin the wiring.
        let projectObserver = try selectedProjectIDDidSet()
        XCTAssertTrue(
            projectObserver.contains("save()"),
            "selectedProjectID.didSet must route through save() — this is the implicit save the load-time guard suppresses"
        )
        let entryObserver = try selectedEntryIDDidSet()
        XCTAssertTrue(
            entryObserver.contains("save()"),
            "selectedEntryID.didSet must route through save() — this is the implicit save the load-time guard suppresses"
        )
    }

    // MARK: - Helpers (mirror SessionIdBackfillWiringTests)

    /// The `WorkbenchViewModel.save()` body — NOT the unrelated sheet `save()`
    /// earlier in the file. Anchored on the reset-suppression comment that is
    /// unique to the view-model save.
    private func viewModelSaveBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "// While resetting to first run we've deliberately removed the state",
            to: "private func fetchResult"
        )
    }

    /// The `selectedProjectID` `didSet` observer body.
    private func selectedProjectIDDidSet() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "@Published var selectedProjectID:",
            // `selectedEntryID` was widened to `public` in U0 Unit 3′ (it is read by the in-exe
            // UISurfaceTest across the new module boundary); the marker tracks that access-control
            // change. Slice semantics are unchanged — this still bounds the `selectedProjectID`
            // didSet body at the next `@Published` property.
            to: "@Published public var selectedEntryID:"
        )
    }

    /// The `selectedEntryID` `didSet` observer body.
    private func selectedEntryIDDidSet() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            // `public` added by the U0 Unit 3′ view-layer move (see above) — marker only.
            from: "@Published public var selectedEntryID:",
            to: "@Published var selectedAgentName:"
        )
    }

    /// The whole `load()` catch arm — from the catch through the end of `load()`.
    private func loadCatchArm() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "let loaded = try store.load()",
            to: "private func restoreDetailLayout"
        )
    }

    /// The `.moveFailed` case only — from its `case` label to the close of the
    /// `unreadableState` switch (the `} else {` that handles non-quarantine
    /// errors). Excludes the SHARED reset-to-empty code that the `.moved` /
    /// non-quarantine paths fall through to, so the no-reset/no-save assertions
    /// scope to the failure branch alone.
    private func moveFailedArm() throws -> String {
        let arm = try loadCatchArm()
        return try WorkbenchAppSource.sourceSlice(in: arm, from: ".moveFailed", to: "} else {")
    }

    /// The success block: from the load through the re-save, before the catch.
    private func loadSuccessBlock() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "let loaded = try store.load()",
            to: "} catch {"
        )
    }
}
