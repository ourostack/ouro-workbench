import XCTest
@testable import OuroWorkbenchCore

/// Accessibility wiring pins for `OnboardingBossChoiceRow` — the boss-picker row in
/// the "Choose Boss" onboarding step (the gateway to the whole autonomy feature).
///
/// The row WAS a bare `HStack` + `.contentShape(...)` + `.onTapGesture { guard
/// choice.isUsable else { return }; model.registerWorkbenchForBossChoice(...) }` with
/// ZERO accessibility modifiers. SwiftUI does NOT auto-expose an `onTapGesture` as an
/// accessibility action, so that form was NOT keyboard-focusable and NOT VoiceOver-
/// actionable — a user could not select a boss without a mouse. Every OTHER selectable
/// row in the app correctly uses `Button` (e.g. `WorkspaceSidebarRow`), so this
/// was a miss, not a deliberate choice.
///
/// The App target isn't coverage-gated and can't be click-tested in CI, so we source-
/// pin the row's structural accessibility the same way `TerminalLeakReaperWiringTests`
/// (F11a) source-pins its wiring.
///
/// The risks these pins defend (reverting to the bare-gesture form must trip them):
///   - the row must be a real `Button` (keyboard-focusable via Tab + VoiceOver-
///     actionable), not a bare `.onTapGesture` (mouse-only);
///   - the action must still be `registerWorkbenchForBossChoice(choice.name)`;
///   - the "only usable choices select" behaviour must be preserved by `.disabled(
///     !choice.isUsable)` (which ALSO announces the control disabled to VoiceOver),
///     NOT by a `guard choice.isUsable else { return }` swallowed inside the action;
///   - the selected state must be announced via `.accessibilityAddTraits(.isSelected)`
///     (it's a single-select radio group).
final class OnboardingBossChoiceRowAccessibilityWiringTests: XCTestCase {
    func testRowIsAButtonNotABareTapGesture() throws {
        let body = try rowBody()
        XCTAssertTrue(
            body.contains("Button {") || body.contains("Button(action:"),
            "OnboardingBossChoiceRow must wrap its visual in a Button so the row is keyboard-focusable (Tab) and VoiceOver-actionable, not a mouse-only control"
        )
        XCTAssertTrue(
            body.contains(".buttonStyle(.plain)"),
            "the Button must use .buttonStyle(.plain) so the custom radio/name/pills/detail visual is unchanged"
        )
        // Regression guard: re-introducing the bare-gesture form must trip this. A
        // selectable onboarding row driven by onTapGesture is mouse-only — SwiftUI does
        // not surface an onTapGesture as an accessibility action.
        XCTAssertFalse(
            body.contains(".onTapGesture"),
            "OnboardingBossChoiceRow must NOT use a bare .onTapGesture for selection — that is mouse-only (not keyboard-focusable, not VoiceOver-actionable)"
        )
    }

    func testActionRemainsRegisterWorkbenchForBossChoice() throws {
        let body = try rowBody()
        XCTAssertTrue(
            body.contains("model.registerWorkbenchForBossChoice(choice.name)"),
            "selecting the row must still register the Workbench for the chosen boss (select + install + refresh)"
        )
    }

    func testUsabilityGateIsDisabledModifierNotAGuardInsideTheAction() throws {
        let body = try rowBody()
        XCTAssertTrue(
            body.contains(".disabled(!choice.isUsable)"),
            "the isUsable gate must be expressed as .disabled(!choice.isUsable) on the Button so an unusable choice is non-actionable AND announced disabled to VoiceOver"
        )
        // Regression guard: the old form swallowed the gate inside the action body with
        // `guard choice.isUsable else { return }`, which leaves the control actionable +
        // focusable but silently does nothing — VoiceOver never learns it is disabled.
        XCTAssertFalse(
            body.contains("guard choice.isUsable else"),
            "the isUsable gate must NOT be a guard swallowed inside the action (that hides the disabled state from VoiceOver); use .disabled(!choice.isUsable)"
        )
    }

    func testSelectedStateIsAnnouncedToVoiceOver() throws {
        let body = try rowBody()
        XCTAssertTrue(
            body.contains(".accessibilityAddTraits(") && body.contains(".isSelected"),
            "the row must add the .isSelected accessibility trait so VoiceOver announces the selected state (single-select radio group)"
        )
        // The trait must be CONDITIONAL on choice.isSelected — adding .isSelected
        // unconditionally would announce every row selected. Pin the gate so the
        // single-select radio semantics survive.
        XCTAssertTrue(
            body.contains("choice.isSelected ? [.isSelected]")
                || body.contains("choice.isSelected ? .isSelected"),
            "the .isSelected trait must be gated on choice.isSelected (the picked boss), not added unconditionally"
        )
        // Reads the row as one element ("<name>, selected, ready") instead of fragmented
        // static text.
        XCTAssertTrue(
            body.contains(".accessibilityElement(children: .combine)"),
            "the row should combine its children so VoiceOver reads it as a single element"
        )
    }

    // MARK: - Helpers

    private func rowBody() throws -> String {
        // Slice exactly the row struct's declaration through the start of the NEXT
        // top-level view (FirstRunBootstrapView) so nothing downstream bleeds in.
        try sourceSlice(
            in: try appSource(),
            from: "private struct OnboardingBossChoiceRow: View {",
            to: "\n/// R4b — the first-run cold-start bootstrap surface."
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
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound, "missing end marker: \(endMarker)")
        return String(source[start..<end])
    }
}
