#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `OnboardingBossChoice` (`:4536`) direct logic test.
///
/// `OnboardingBossChoice` is an `Identifiable` value type (NOT a View — it renders no captured node),
/// so per D8 its residual is closed by a DIRECT `XCTAssert` logic test, not a snapshot. Its one
/// uncovered region is the `id` computed property `{ name }` (`:4537`) — never read because the
/// campaign's `ForEach(choices)` over it used the synthesized id elsewhere. This asserts `id == name`
/// plus the derived `isUsable` / `statusLabel` / `statusColor` arms for full-arm coverage.
final class OnboardingBossChoiceLogicTests: XCTestCase {

    private func choice(name: String, status: OuroAgentBundleStatus?) -> OnboardingBossChoice {
        OnboardingBossChoice(name: name, detail: "d", status: status, isSelected: false)
    }

    /// The `id` getter returns `name` (the previously-uncovered region).
    func testID_isName() {
        XCTAssertEqual(choice(name: "alpha", status: .ready).id, "alpha",
                       "id is the name")
    }

    /// `isUsable` is true only for a `.ready` status with a valid bundle name.
    func testIsUsable_readyAndValidName() {
        XCTAssertTrue(choice(name: "alpha", status: .ready).isUsable, "ready + valid name → usable")
        XCTAssertFalse(choice(name: "alpha", status: .disabled).isUsable, "disabled → not usable")
        XCTAssertFalse(choice(name: "alpha", status: nil).isUsable, "no status → not usable")
        XCTAssertFalse(choice(name: "bad/name", status: .ready).isUsable, "invalid name → not usable")
    }

    /// `statusLabel`: nil status → "needs setup"; otherwise the Core copy.
    func testStatusLabel_arms() {
        XCTAssertEqual(choice(name: "a", status: nil).statusLabel, "needs setup", "nil → needs setup")
        XCTAssertEqual(choice(name: "a", status: .ready).statusLabel,
                       OnboardingBossChoiceCopy.statusLabel(for: .ready), "ready → Core copy")
    }

    /// `statusColor`: `.ready` → green; every other status (incl nil) → orange.
    func testStatusColor_arms() {
        XCTAssertEqual(choice(name: "a", status: .ready).statusColor, .green, "ready → green")
        XCTAssertEqual(choice(name: "a", status: .disabled).statusColor, .orange, "disabled → orange")
        XCTAssertEqual(choice(name: "a", status: .missingConfig).statusColor, .orange, "missingConfig → orange")
        XCTAssertEqual(choice(name: "a", status: .invalidConfig).statusColor, .orange, "invalidConfig → orange")
        XCTAssertEqual(choice(name: "a", status: nil).statusColor, .orange, "nil → orange")
    }
}
#endif
