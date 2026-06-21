import XCTest
@testable import OuroWorkbenchCore

/// The Choose Boss page must not claim connection-readiness before the connection is actually
/// checked. At that point all that's truly known is that the agent's bundle is installed /
/// enabled — the live `ouro check` runs on the very next (Connect) page. So the `.ready` case
/// reads "installed", not "ready", and its detail promises the check rather than asserting the
/// boss is good to go. The other statuses are unchanged. The copy lives in Core so it's pinned by
/// tests; the App `OnboardingBossChoice` / `onboardingBossChoices` render it verbatim.
final class OnboardingBossChoiceCopyTests: XCTestCase {
    func testReadyStatusLabelSaysInstalledNotReady() {
        XCTAssertEqual(OnboardingBossChoiceCopy.statusLabel(for: .ready), "installed")
    }

    func testReadyDetailPromisesTheConnectionCheckNext() {
        XCTAssertEqual(
            OnboardingBossChoiceCopy.detail(for: .ready),
            "Installed on this Mac. We'll check its connection next."
        )
    }

    func testNonReadyStatusLabelsAreUnchanged() {
        XCTAssertEqual(OnboardingBossChoiceCopy.statusLabel(for: .disabled), "turned off")
        XCTAssertEqual(OnboardingBossChoiceCopy.statusLabel(for: .missingConfig), "needs setup")
        XCTAssertEqual(OnboardingBossChoiceCopy.statusLabel(for: .invalidConfig), "needs setup")
    }

    func testNonReadyDetailsAreUnchanged() {
        XCTAssertEqual(OnboardingBossChoiceCopy.detail(for: .disabled), "Turned off right now.")
        XCTAssertEqual(OnboardingBossChoiceCopy.detail(for: .missingConfig), "Needs a little setup first.")
        XCTAssertEqual(OnboardingBossChoiceCopy.detail(for: .invalidConfig), "Needs a little setup first.")
    }
}
