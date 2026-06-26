#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-1 — `HarnessActionResultBanner` (the harness control-action receipt leaf).
///
/// The transient banner the `HarnessStatusSheet` shows after a Repair-daemon /
/// register-MCP action fires. A pure presentational LEAF: it takes a
/// `HarnessActionResult` value directly (no model), so the snapshot seam is just
/// the value type — `HarnessActionResult(kind:succeeded:message:)`, the SAME value
/// the live `repairHarnessDaemon()` / `registerHarnessWorkbenchMCP()` flows set on
/// `model.harnessActionResult`. Direct value construction IS the production seam.
///
/// **Reclassification (reconfirm-by-mutation):** the planning audit binned this as
/// LOGIC because `Image(systemName: result.succeeded ? "checkmark.circle.fill" :
/// "exclamationmark.triangle.fill")` flips the CAPTURED SF-symbol name (the host's
/// `image().actualImage().name()` whitelist) — confirmed here: the success/failure
/// icon name flips the serialized tree (the negative control proves it), so it
/// STAYS LOGIC and is COVERED. (The green/orange tint is attribute-only → dropped
/// by the whitelist; the FLIP is the symbol name + the message Text.)
///
/// **Enumerated state-set:**
///   - `succeeded` — `succeeded == true`  → `checkmark.circle.fill` + the message.
///   - `failed`    — `succeeded == false` → `exclamationmark.triangle.fill` + msg.
///
/// **Determinism (P3):** the message is a fixed fixture string; no clock / path /
/// machine-name / UUID renders on this leaf → no cross-TZ proof needed (asserted:
/// no `/Users/`, no `/var/folders/`, byte-identical twice). The dismiss button's
/// `.help("Dismiss")` tooltip is dropped by the host (AN-004).
@MainActor
final class HarnessActionResultBannerTests: XCTestCase {

    private func view(succeeded: Bool, message: String, kind: HarnessControlAction = .repairDaemon)
        -> HarnessActionResultBanner {
        HarnessActionResultBanner(
            result: HarnessActionResult(kind: kind, succeeded: succeeded, message: message),
            onDismiss: {}
        )
    }

    // MARK: - Enumerated state-set

    func testBanner_succeeded_checkmarkSymbolAndMessage() throws {
        let view = view(succeeded: true, message: "Brought your agent back online.")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("checkmark.circle.fill"),
                      "succeeded: the success SF-symbol renders:\n\(tree)")
        XCTAssertFalse(tree.contains("exclamationmark.triangle.fill"),
                       "succeeded: the failure symbol must NOT render:\n\(tree)")
        XCTAssertTrue(tree.contains("Brought your agent back online."),
                      "succeeded: the message Text renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessActionResultBanner.succeeded")
    }

    func testBanner_failed_warningSymbolAndMessage() throws {
        let view = view(succeeded: false, message: "Couldn't reach the daemon — try again.")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("exclamationmark.triangle.fill"),
                      "failed: the failure SF-symbol renders:\n\(tree)")
        XCTAssertFalse(tree.contains("checkmark.circle.fill"),
                       "failed: the success symbol must NOT render:\n\(tree)")
        XCTAssertTrue(tree.contains("Couldn't reach the daemon — try again."),
                      "failed: the message Text renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessActionResultBanner.failed")
    }

    // MARK: - Determinism (P3)

    func testBanner_deterministic_byteIdenticalTwiceAndNoLeak() throws {
        for (succeeded, message) in [(true, "ok"), (false, "boom")] {
            let a = try ViewSnapshotHost.snapshotText(of: view(succeeded: succeeded, message: message))
            let b = try ViewSnapshotHost.snapshotText(of: view(succeeded: succeeded, message: message))
            XCTAssertEqual(a, b, "succeeded=\(succeeded) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "no temp-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `result.succeeded` ternary drives the captured SF-symbol name. Breaking
    /// the gate (forcing one symbol) collapses the two trees → the snapshot would go
    /// RED. This asserts the symbol-name FLIP is the real, captured discriminator.
    func testBanner_negativeControl_succeededFlipsCapturedSymbol() throws {
        let success = try ViewSnapshotHost.snapshotText(of: view(succeeded: true, message: "m"))
        let failure = try ViewSnapshotHost.snapshotText(of: view(succeeded: false, message: "m"))
        XCTAssertNotEqual(success, failure,
                          "the succeeded ternary must flip the captured SF-symbol name")
        XCTAssertTrue(success.contains("checkmark.circle.fill"))
        XCTAssertTrue(failure.contains("exclamationmark.triangle.fill"))
    }
}
#endif
