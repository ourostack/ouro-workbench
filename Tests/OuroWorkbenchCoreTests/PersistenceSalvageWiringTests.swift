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

    // MARK: - Helpers (mirror SessionIdBackfillWiringTests)

    /// The whole `load()` catch arm — from the catch through the end of `load()`.
    private func loadCatchArm() throws -> String {
        let source = try appSource()
        return try sourceSlice(
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
        return try sourceSlice(in: arm, from: ".moveFailed", to: "} else {")
    }

    /// The success block: from the load through the re-save, before the catch.
    private func loadSuccessBlock() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "let loaded = try store.load()",
            to: "} catch {"
        )
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
