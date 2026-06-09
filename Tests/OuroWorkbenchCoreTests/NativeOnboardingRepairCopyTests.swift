import XCTest
@testable import OuroWorkbenchCore

/// R4b — the seam-free in-progress / completion copy the Setup Assistant shows when an
/// onboarding repair step runs APP-EXECUTED (headless through a recovery-truth runner), instead
/// of handing the human a raw CLI pane. The copy is pure Core so the seam-free contract is
/// asserted here, not buried in the SwiftUI view layer (which has no test target).
final class NativeOnboardingRepairCopyTests: XCTestCase {

    // MARK: - In-progress acknowledgement copy (seam-free)

    func testRepairAgentInProgressLineIsSeamFree() {
        let line = NativeOnboardingRepairCopy.inProgressLine(forStepID: "repair-agent-config")
        XCTAssertNotNil(line)
        assertNoCliSeam(line!)
        XCTAssertFalse(line!.isEmpty)
    }

    func testCheckOutwardInProgressLineIsSeamFree() {
        let line = NativeOnboardingRepairCopy.inProgressLine(forStepID: "check-outward")
        XCTAssertNotNil(line)
        assertNoCliSeam(line!)
        XCTAssertFalse(line!.isEmpty)
    }

    func testCheckInnerInProgressLineIsSeamFree() {
        let line = NativeOnboardingRepairCopy.inProgressLine(forStepID: "check-inner")
        XCTAssertNotNil(line)
        assertNoCliSeam(line!)
        XCTAssertFalse(line!.isEmpty)
    }

    /// Both provider-check lanes read the SAME seam-free copy — the human never sees a lane verb.
    func testBothCheckLanesShareTheSameInProgressLine() {
        XCTAssertEqual(
            NativeOnboardingRepairCopy.inProgressLine(forStepID: "check-outward"),
            NativeOnboardingRepairCopy.inProgressLine(forStepID: "check-inner")
        )
    }

    /// A step the native-repair router does not handle returns `nil` (the caller falls through to
    /// its non-app-executed branch) — never a fabricated line.
    func testUnknownStepHasNoInProgressLine() {
        XCTAssertNil(NativeOnboardingRepairCopy.inProgressLine(forStepID: "workbench-mcp"))
        XCTAssertNil(NativeOnboardingRepairCopy.inProgressLine(forStepID: "request-provider-config"))
        XCTAssertNil(NativeOnboardingRepairCopy.inProgressLine(forStepID: ""))
    }

    /// Every handled step's in-progress line is seam-free (exhaustive over the app-executed set).
    func testEveryHandledStepInProgressLineIsSeamFree() {
        for stepID in NativeOnboardingRepairCopy.appExecutedStepIDs {
            guard let line = NativeOnboardingRepairCopy.inProgressLine(forStepID: stepID) else {
                XCTFail("app-executed step \(stepID) must have an in-progress line")
                continue
            }
            assertNoCliSeam(line)
            XCTAssertFalse(line.isEmpty)
        }
    }

    /// The app-executed set is exactly the last human-as-hands repair steps R4b removed: the agent
    /// config repair + both provider-check lanes. (Provider-setup steps open the native form;
    /// `workbench-mcp` has its own register button; daemon/hatch/clone live in other readiness
    /// states.) Guards against the set silently drifting.
    func testAppExecutedStepIDsAreExactlyTheRemovedPanes() {
        XCTAssertEqual(
            Set(NativeOnboardingRepairCopy.appExecutedStepIDs),
            ["repair-agent-config", "check-outward", "check-inner"]
        )
    }

    // MARK: - Assertions

    private func assertNoCliSeam(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = value.lowercased()
        XCTAssertFalse(lowered.contains("ouro"), "human copy leaks 'ouro': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("daemon"), "human copy leaks 'daemon': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("hatch"), "human copy leaks 'hatch': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("vault"), "human copy leaks 'vault': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("mcp"), "human copy leaks 'mcp': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("--"), "human copy leaks a CLI flag: \(value)", file: file, line: line)
    }
}
