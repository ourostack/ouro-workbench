#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// AN-R2-01 — energy-0 round-2 close for `TerminalAgentRow`'s SECONDARY decoration
/// guards. Round 1 swept the elapsed-pill leaf (`TerminalAgentRowRunningLeafTests`)
/// and the chip-on-row gates (`SessionChipOnRowTests`); the round-2 serial mutation
/// sweep found FOUR reachable secondary guards whose mutation left the suite GREEN —
/// residual P2 energy — because no committed fixture ever decorated the row:
///
///   - `if isPinned` (`:3756`)                        → the `pin.fill` glyph
///   - `if let cliName` (`:3776`)                     → the cli-name caption `Text`
///   - `if let badge = entry.owner.sidebarBadge` (`:3762`) → the owner `Label`
///     (`cpu` symbol + agent name) AND the `accessibilityLabel` "owned by …" piece
///   - `if let health, health.status != .available` (`:3797`) → the orange
///     `exclamationmark.triangle.fill` warning AND the a11y `health.detail` piece
///
/// Mutating each (suppressing the body arm) left every existing TerminalAgentRow
/// test GREEN — the arm executes but its distinguishing output is never asserted.
///
/// **Provenance (P2).** `TerminalAgentRow` is a `View`; constructing it directly with
/// its own inputs IS the legitimate seam (exactly as `TerminalAgentRowRunningLeafTests`
/// does for the elapsed pill — P2 forbids hand-assembling serializer OUTPUT / model
/// STATE, not instantiating a `View`). `ProcessEntry` / `SessionOwner` / `ExecutableHealth`
/// are `public` Core value types; `.agent(name:)` is the real producer of
/// `sidebarBadge == ("cpu", name)`, and a `.missing` `ExecutableHealth` is the real
/// degraded state the live `ExecutableHealthChecker` emits. `isPinned` / `cliName` are
/// the row's own declared inputs (the sidebar/tab-strip pass them).
///
/// **Determinism (P3).** No injected clock is needed (no `runningSince`), so no
/// elapsed/live-`Date()` read occurs; the tree is a pure function of the fixed inputs.
/// Asserted byte-identical twice + no machine-path leak below.
@MainActor
final class TerminalAgentRowDecoratedLeafTests: XCTestCase {

    /// The base entry — owned by a named AGENT so `owner.sidebarBadge` is live
    /// (`("cpu", "scout")`). Plain `.idle` attention, NOT archived (so the archived
    /// `rowIcon` arm — separately pinned by `RecoverySurfaceStateSetTests` — is off).
    private func agentEntry() -> ProcessEntry {
        ProcessEntry(
            id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-0000000000DE")!,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!,
            name: "scout-session",
            kind: .terminalAgent,
            executable: "/bin/claude",
            workingDirectory: "/tmp/anr2",
            owner: .agent(name: "scout")
        )
    }

    /// A genuinely-degraded health (`.missing`) — the real state the
    /// `ExecutableHealthChecker` reports when the executable can't be resolved.
    private func degradedHealth() -> ExecutableHealth {
        ExecutableHealth(executable: "claude", status: .missing, detail: "claude not found on PATH")
    }

    /// The fully-decorated row: pinned + a cli-name caption + an agent owner badge +
    /// a degraded-health warning. One view exercises all four secondary guards.
    private func decoratedRow() -> TerminalAgentRow {
        TerminalAgentRow(
            entry: agentEntry(),
            isSelected: false,
            cliName: "claude-code",
            health: degradedHealth(),
            isPinned: true
        )
    }

    // MARK: - The committed reference (all four decoration guards live at once)

    func testRow_decorated_pinsAllFourSecondaryGuards() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: decoratedRow())

        // 1. isPinned → the pin glyph.
        XCTAssertTrue(tree.contains(#"image="pin.fill""#), "pinned: the pin glyph:\n\(tree)")
        // 2. cliName → the caption Text.
        XCTAssertTrue(tree.contains(#"text="claude-code""#), "cliName: the caption text:\n\(tree)")
        // 3. owner.sidebarBadge → the owner Label (cpu symbol + agent name) AND the a11y piece.
        XCTAssertTrue(tree.contains(#"image="cpu""#), "owner badge: the cpu glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="scout""#), "owner badge: the agent name:\n\(tree)")
        XCTAssertTrue(tree.contains("owned by scout"), "owner badge: the a11y 'owned by' piece:\n\(tree)")
        // 4. degraded health → the orange warning glyph AND the a11y detail piece.
        XCTAssertTrue(tree.contains(#"image="exclamationmark.triangle.fill""#),
                      "health: the degraded warning glyph:\n\(tree)")
        XCTAssertTrue(tree.contains("claude not found on PATH"),
                      "health: the a11y detail piece:\n\(tree)")

        try assertViewSnapshot(of: decoratedRow(), named: "TerminalAgentRow.decorated")
    }

    // MARK: - Negative controls (P2) — each guard's input flips its output

    /// Dropping each decoration input removes EXACTLY its node(s) — proving every
    /// guard is load-bearing (its input governs the captured output, not incidental).
    func testRow_negativeControl_eachGuardInputFlipsTree() throws {
        let decorated = try ViewSnapshotHost.snapshotText(of: decoratedRow())

        // Unpin → no pin glyph (everything else unchanged).
        let unpinned = try ViewSnapshotHost.snapshotText(of: TerminalAgentRow(
            entry: agentEntry(), isSelected: false, cliName: "claude-code",
            health: degradedHealth(), isPinned: false))
        XCTAssertFalse(unpinned.contains(#"image="pin.fill""#), "unpinned: no pin glyph:\n\(unpinned)")
        XCTAssertNotEqual(decorated, unpinned, "isPinned must flip the pin glyph")

        // No cliName → no caption.
        let noCli = try ViewSnapshotHost.snapshotText(of: TerminalAgentRow(
            entry: agentEntry(), isSelected: false, cliName: nil,
            health: degradedHealth(), isPinned: true))
        XCTAssertFalse(noCli.contains(#"text="claude-code""#), "no cliName: no caption:\n\(noCli)")
        XCTAssertNotEqual(decorated, noCli, "cliName must flip the caption text")

        // Human owner → no owner badge (and no "owned by" a11y piece).
        let humanEntry = ProcessEntry(
            id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-0000000000DE")!,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!,
            name: "scout-session", kind: .terminalAgent, executable: "/bin/claude",
            workingDirectory: "/tmp/anr2", owner: .human)
        let humanOwned = try ViewSnapshotHost.snapshotText(of: TerminalAgentRow(
            entry: humanEntry, isSelected: false, cliName: "claude-code",
            health: degradedHealth(), isPinned: true))
        XCTAssertFalse(humanOwned.contains(#"image="cpu""#), "human owner: no cpu badge:\n\(humanOwned)")
        XCTAssertFalse(humanOwned.contains("owned by"), "human owner: no 'owned by' a11y:\n\(humanOwned)")
        XCTAssertNotEqual(decorated, humanOwned, "owner must flip the badge + a11y piece")

        // Available health → no warning glyph (and no detail a11y piece).
        let okHealth = try ViewSnapshotHost.snapshotText(of: TerminalAgentRow(
            entry: agentEntry(), isSelected: false, cliName: "claude-code",
            health: ExecutableHealth(executable: "claude", status: .available, detail: "claude resolved"),
            isPinned: true))
        XCTAssertFalse(okHealth.contains(#"image="exclamationmark.triangle.fill""#),
                       "available health: no warning glyph:\n\(okHealth)")
        XCTAssertFalse(okHealth.contains("claude resolved"),
                       "available health: detail not surfaced when available:\n\(okHealth)")
        XCTAssertNotEqual(decorated, okHealth, "health.status must flip the warning + a11y detail")

        // nil health → also no warning.
        let nilHealth = try ViewSnapshotHost.snapshotText(of: TerminalAgentRow(
            entry: agentEntry(), isSelected: false, cliName: "claude-code",
            health: nil, isPinned: true))
        XCTAssertFalse(nilHealth.contains(#"image="exclamationmark.triangle.fill""#),
                       "nil health: no warning glyph:\n\(nilHealth)")
    }

    // MARK: - Determinism (P3)

    func testRow_decorated_twiceRunByteIdentical_noLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: decoratedRow())
        let b = try ViewSnapshotHost.snapshotText(of: decoratedRow())
        XCTAssertEqual(a, b, "the decorated leaf must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
