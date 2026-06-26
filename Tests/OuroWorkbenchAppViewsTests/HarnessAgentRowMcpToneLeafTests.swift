#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// AN-R3-02 — energy-0 round-3 close for two reachable arms of `HarnessAgentRow`'s
/// `harnessShortLabel(for:)` mcp-pill switch (`:1517`).
///
/// The `if let mcpStatus` pill renders `"mcp \(harnessShortLabel(for: mcpTone))"`, where `mcpTone`
/// is folded from `(mcpStatus, toolsInjection)` by the pure Core producer
/// `BossMCPPillPresentation.tone(status:injection:)`. The six-arm label switch was only PARTLY
/// controlled by the committed suite:
///
///   - `.verified`      → "on"        — pinned (`HarnessAgentRow.readyVerifiedBoss`: "mcp on")
///   - `.notRegistered` → "off"       — pinned (`HarnessAgentRow.badConfig`: "mcp off")
///   - `.needsAttention`→ "stale"     — pinned (`HarnessStatusSheet.bossNeedsUpdate`: "mcp stale")
///   - `.error`         → "error"     — pinned (`HarnessStatusSheet.daemonDown/…`: "mcp error")
///   - `.unverified`    → "unverified" ← UNCONTROLLED (residual P2 energy)
///   - `.notInjected`   → "old ouro"   ← UNCONTROLLED (residual P2 energy)
///
/// The round-3 single-actor serial mutation sweep proved both: mutating the `.unverified` arm
/// (alone) and the `.notInjected` arm (alone) each left the FULL 565-test app-views suite GREEN —
/// no committed fixture ever rendered an `.unverified` ("config-registered, not yet probed-present")
/// or `.notInjected` ("old ouro that ignored --workbench-mcp") mcp pill, even though both are
/// everyday live states. The other four arms went RED under the same sweep (caught in
/// HarnessAgentRow / HarnessStatusSheet snapshots), so this leaf closes exactly the two live gaps.
///
/// **Provenance (P2).** Both tones are producer-derived, not hand-set: each test asserts the tone
/// the REAL `BossMCPPillPresentation.tone(status:injection:)` folds from the `(status, injection)`
/// inputs, THEN that the row renders the corresponding label. `HarnessAgentEntry` is the same public
/// value `HarnessStatusBuilder.build` emits, and `HarnessAgentRow(entry:)` is the production render
/// seam (P2 forbids hand-assembling serializer output, not constructing a `View` / a `public` value).
///
/// **Determinism (P3).** Fixed agent name; no clock / path / UUID renders. Byte-identical twice +
/// no machine-path leak below.
@MainActor
final class HarnessAgentRowMcpToneLeafTests: XCTestCase {

    private func entry(
        name: String,
        mcpStatus: BossWorkbenchMCPRegistrationStatus,
        toolsInjection: WorkbenchToolsInjectionProbeOutcome? = nil
    ) -> HarnessAgentEntry {
        HarnessAgentEntry(
            name: name,
            status: .ready,
            detail: "configured",
            isSelectedBoss: false,
            mcpStatus: mcpStatus,
            toolsInjection: toolsInjection,
            verdict: nil
        )
    }

    private func view(_ e: HarnessAgentEntry) -> HarnessAgentRow { HarnessAgentRow(entry: e) }

    // MARK: - .unverified — a config-registered pill the live probe has NOT confirmed present

    func testRow_mcpUnverified_rendersUnverifiedPill() throws {
        // Provenance: `.registered` + a CONFIRMED-ABSENT injection folds to `.unverified` (the
        // honest "registered on disk, but the runtime probe did not find the tools" state).
        let e = entry(name: "unv-agent", mcpStatus: .registered, toolsInjection: .confirmed(.absent))
        XCTAssertEqual(
            BossMCPPillPresentation.tone(status: .registered, injection: .confirmed(.absent)),
            .unverified,
            "provenance: registered + confirmed-absent → .unverified through the real tone() seam"
        )
        let tree = try ViewSnapshotHost.snapshotText(of: view(e))
        XCTAssertTrue(tree.contains(#"text="mcp unverified""#), "the .unverified mcp pill:\n\(tree)")
        try assertViewSnapshot(of: view(e), named: "HarnessAgentRow.mcpUnverified")
    }

    // MARK: - .notInjected — an old ouro that silently ignored --workbench-mcp

    func testRow_mcpNotInjected_rendersOldOuroPill() throws {
        // Provenance: `.toolsNotInjected` folds to `.notInjected` regardless of injection input.
        let e = entry(name: "old-agent", mcpStatus: .toolsNotInjected)
        XCTAssertEqual(
            BossMCPPillPresentation.tone(status: .toolsNotInjected, injection: nil),
            .notInjected,
            "provenance: toolsNotInjected → .notInjected through the real tone() seam"
        )
        let tree = try ViewSnapshotHost.snapshotText(of: view(e))
        XCTAssertTrue(tree.contains(#"text="mcp old ouro""#), "the .notInjected mcp pill:\n\(tree)")
        try assertViewSnapshot(of: view(e), named: "HarnessAgentRow.mcpNotInjected")
    }

    // MARK: - Negative control (P2) — each tone renders its OWN distinct label

    /// The two newly-pinned tones, plus the already-pinned `.verified`/`.notRegistered`, each
    /// render a DIFFERENT "mcp …" label — proving `harnessShortLabel` maps tone→label injectively
    /// (mutating either new arm flips its captured pill text, never another's).
    func testRow_negativeControl_eachToneRendersDistinctLabel() throws {
        let unverified = try ViewSnapshotHost.snapshotText(
            of: view(entry(name: "x", mcpStatus: .registered, toolsInjection: .confirmed(.absent))))
        let notInjected = try ViewSnapshotHost.snapshotText(
            of: view(entry(name: "x", mcpStatus: .toolsNotInjected)))
        let verified = try ViewSnapshotHost.snapshotText(
            of: view(entry(name: "x", mcpStatus: .registered, toolsInjection: .confirmed(.present))))
        let notRegistered = try ViewSnapshotHost.snapshotText(
            of: view(entry(name: "x", mcpStatus: .notRegistered)))

        // Each new arm renders its OWN label and NOT a neighbour's.
        XCTAssertTrue(unverified.contains(#"text="mcp unverified""#), "unverified pill:\n\(unverified)")
        XCTAssertFalse(unverified.contains(#"text="mcp old ouro""#), "unverified is not old-ouro:\n\(unverified)")
        XCTAssertFalse(unverified.contains(#"text="mcp on""#), "unverified is not on:\n\(unverified)")

        XCTAssertTrue(notInjected.contains(#"text="mcp old ouro""#), "old-ouro pill:\n\(notInjected)")
        XCTAssertFalse(notInjected.contains(#"text="mcp unverified""#), "old-ouro is not unverified:\n\(notInjected)")

        // The four pills are mutually distinct trees (tone→label is injective).
        let labels = Set([unverified, notInjected, verified, notRegistered])
        XCTAssertEqual(labels.count, 4, "all four mcp-pill tones render distinct trees")
    }

    // MARK: - Determinism (P3)

    func testRow_mcpTones_twiceRunByteIdentical_noLeak() throws {
        for e in [entry(name: "d", mcpStatus: .registered, toolsInjection: .confirmed(.absent)),
                  entry(name: "d", mcpStatus: .toolsNotInjected)] {
            let a = try ViewSnapshotHost.snapshotText(of: view(e))
            let b = try ViewSnapshotHost.snapshotText(of: view(e))
            XCTAssertEqual(a, b, "the mcp-pill leaf must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        }
    }
}
#endif
