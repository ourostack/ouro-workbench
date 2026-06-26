#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-3 — `BossAgentNamePopover` (`:4442`) STANDALONE enumerated state-set.
///
/// `BossSelectorView` presents this via `.popover(isPresented:)`, and ViewInspector does
/// NOT descend `.popover{}` content (edge-case playbook #5) — so the popover is snapshotted
/// STANDALONE, the proven recipe. Its data-driven branch is
/// `if !trimmedAgentName.isEmpty && !canApply` (`:4465`) — the invalid-name error `Text`,
/// where `canApply = BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmedAgentName)`.
/// The captured nodes: the "Boss Agent" headline `Text`, the bound `TextField` VALUE (read
/// via AN-002 `input()` → the `$agentName` wrapped value, NOT the placeholder), the
/// conditional error `Text`, and the "Cancel"/"Use" button `Text`s.
///
/// **Provenance (P2).** The `@Binding`s are driven by `.constant(...)` — for a snapshot the
/// bound value IS the rendered state, and `.constant` is the cleanest deterministic seam for
/// a standalone binding-driven view (the SU-C `InlineRenameEditor` precedent renders a bound
/// draft the same way). `canApply` is decided by the REAL pure Core validator
/// `BossWorkbenchMCPRegistrar.isValidAgentBundleName`, asserted directly. `model` is the
/// hermetic `makeVM` (AN-001) — it's only touched by the non-rendered `apply()` action.
///
/// **Enumerated state-set (the validity branch):**
///   - `empty`   — `agentName == ""` → the `!isEmpty` short-circuits → NO error row.
///   - `valid`   — a valid name → `canApply == true` → NO error row, the name in the field.
///   - `invalid` — a name with a slash → `canApply == false` → the error row renders.
@MainActor
final class BossAgentNamePopoverStandaloneTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-banp-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// The popover bound to a fixed draft name (`.constant` — the rendered value IS the state).
    private func popover(agentName: String) throws -> BossAgentNamePopover {
        BossAgentNamePopover(
            agentName: .constant(agentName),
            isPresented: .constant(true),
            model: try makeVM()
        )
    }

    // MARK: - Enumerated state-set

    func testPopover_empty() throws {
        // Empty draft → the `!isEmpty` guard short-circuits → no error row.
        let view = try popover(agentName: "")
        XCTAssertTrue("".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "provenance: empty draft short-circuits the error gate")
        try assertViewSnapshot(of: view, named: "BossAgentNamePopover.empty")
    }

    func testPopover_valid() throws {
        // A valid bundle name → `canApply == true` → no error row, the name in the field.
        let name = "claude-boss"
        XCTAssertTrue(BossWorkbenchMCPRegistrar.isValidAgentBundleName(name),
                      "provenance: a valid bundle name")
        try assertViewSnapshot(of: try popover(agentName: name), named: "BossAgentNamePopover.valid")
    }

    func testPopover_invalid() throws {
        // A name with a slash → `canApply == false` AND non-empty → the error row renders.
        let name = "bad/name"
        XCTAssertFalse(BossWorkbenchMCPRegistrar.isValidAgentBundleName(name),
                       "provenance: a slash makes the name invalid")
        try assertViewSnapshot(of: try popover(agentName: name), named: "BossAgentNamePopover.invalid")
    }

    // MARK: - Determinism (P3)

    func testPopover_determinism_byteIdenticalTwiceAndNoLeak() throws {
        for (name, draft) in [("empty", ""), ("valid", "claude-boss"), ("invalid", "bad/name")] {
            let a = try ViewSnapshotHost.snapshotText(of: try popover(agentName: draft))
            let b = try ViewSnapshotHost.snapshotText(of: try popover(agentName: draft))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `!trimmedAgentName.isEmpty && !canApply` gate flips the captured tree: an invalid
    /// non-empty draft renders the error `Text` that an empty or valid draft omits, and the
    /// bound draft value itself is captured (a value-flip).
    func testPopover_negativeControl_invalidGateAndBoundValueFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: try popover(agentName: ""))
        let valid = try ViewSnapshotHost.snapshotText(of: try popover(agentName: "claude-boss"))
        let invalid = try ViewSnapshotHost.snapshotText(of: try popover(agentName: "bad/name"))

        let errorCopy = "That name can't be used"
        // The error row is present iff invalid-and-non-empty.
        XCTAssertFalse(empty.contains(errorCopy), "empty: no error row:\n\(empty)")
        XCTAssertFalse(valid.contains(errorCopy), "valid: no error row:\n\(valid)")
        XCTAssertTrue(invalid.contains(errorCopy), "invalid: the error row:\n\(invalid)")
        XCTAssertNotEqual(valid, invalid, "the validity gate must drive the tree")

        // The bound draft value is captured (AN-002 input()).
        XCTAssertTrue(valid.contains("claude-boss"), "valid: the bound draft value:\n\(valid)")
        XCTAssertNotEqual(empty, valid, "the bound value must flip the tree")
    }
}
#endif
