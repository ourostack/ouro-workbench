import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the import-save-honesty fix. The App target
/// isn't coverage-gated and can't be click-tested in CI, so we pin the
/// structural wiring the same way `ColdStartHonestWiringTests` does for F1:
/// the workspace-import + onboarding-apply paths must capture the view-model
/// `save()`'s Bool, thread it into `WorkbenchImportApplyResult.persisted`, gate
/// the action log on `succeeded: persisted`, and the banner must route its
/// green-vs-warning decision through the pure `WorkbenchImportSummaryPresentation`
/// seam (not an unconditional green).
///
/// The bug: importing a workspace showed a GREEN "Imported N terminals" banner +
/// logged `succeeded:true` EVEN WHEN the durable `store.save(state)` failed — a
/// false success over an in-memory-only import lost on quit.
final class ImportPersistenceHonestyWiringTests: XCTestCase {

    // MARK: - save() is @discardableResult -> Bool

    func testSaveIsDiscardableResultReturningBool() throws {
        let source = try WorkbenchAppSource.appSource()
        // The view-model persistence save() — the one whose body calls
        // `try store.save(state)` — must be `@discardableResult ... func save() -> Bool`.
        let slice = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "@discardableResult\n    private func save() -> Bool {",
            to: "private func fetchResult"
        )
        XCTAssertTrue(
            slice.contains("try store.save(state)"),
            "the @discardableResult save() -> Bool must be the persistence save (calls store.save(state))"
        )
        XCTAssertTrue(
            slice.contains("return true"),
            "save() must return true on a successful write"
        )
        XCTAssertTrue(
            slice.contains("return false"),
            "save() must return false in the catch (durable write failed)"
        )
        // The catch still records the failure into errorMessage (unchanged behavior).
        XCTAssertTrue(
            slice.contains("errorMessage = String(describing: error)"),
            "the catch must still set errorMessage as before"
        )
    }

    // MARK: - WorkbenchImportApplyResult carries persisted

    func testApplyResultHasPersistedField() throws {
        let source = try WorkbenchAppSource.appSource()
        let slice = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct WorkbenchImportApplyResult: Equatable {",
            to: "var hasImports: Bool"
        )
        XCTAssertTrue(
            slice.contains("var persisted: Bool"),
            "WorkbenchImportApplyResult must carry a persisted flag for the honest banner"
        )
    }

    // MARK: - Workspace-config apply path gates on save()'s Bool

    func testWorkspaceImportCapturesSaveResultAndGatesActionLog() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "let persisted = save()\n        refreshExecutableHealth()\n        // Auto-resume",
            to: "return result"
        )
        // The result is constructed with the captured persisted flag.
        XCTAssertTrue(
            body.contains("persisted: persisted"),
            "the workspace import result must thread the captured save() Bool into persisted:"
        )
        // The action log's succeeded is gated on persisted — NOT an unconditional true.
        XCTAssertTrue(
            body.contains("succeeded: persisted"),
            "the workspace import action log must use succeeded: persisted, not succeeded: true"
        )
        XCTAssertFalse(
            body.contains("succeeded: true"),
            "the workspace import action log must NOT log an unconditional succeeded: true"
        )
        // When the write failed, the result text says so.
        XCTAssertTrue(
            body.contains("not saved to disk"),
            "a failed write must annotate the action-log result text honestly"
        )
    }

    // MARK: - Onboarding apply path gates on save()'s Bool

    func testOnboardingApplyCapturesSaveResultAndGatesActionLog() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func applyOnboardingProposal() -> WorkbenchImportApplyResult? {",
            to: "func openOnboardingRepair"
        )
        XCTAssertTrue(
            body.contains("let persisted = save()"),
            "applyOnboardingProposal must capture save()'s Bool"
        )
        XCTAssertTrue(
            body.contains("persisted: persisted"),
            "the onboarding result must thread the captured save() Bool into persisted:"
        )
        XCTAssertTrue(
            body.contains("succeeded: persisted"),
            "the onboarding action log must use succeeded: persisted, not succeeded: true"
        )
        XCTAssertFalse(
            body.contains("succeeded: true"),
            "the onboarding action log must NOT log an unconditional succeeded: true"
        )
        XCTAssertTrue(
            body.contains("not saved to disk"),
            "a failed onboarding write must annotate the action-log result text honestly"
        )
    }

    // MARK: - ImportSummaryBanner routes through the presentation seam

    func testBannerRoutesThroughPresentationSeamNotUnconditionalGreen() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct ImportSummaryBanner: View {",
            to: "private func scheduleDismiss()"
        )
        // The banner resolves its tone through the pure Core seam.
        XCTAssertTrue(
            body.contains("WorkbenchImportSummaryPresentation.tone("),
            "the banner must resolve its tone via WorkbenchImportSummaryPresentation.tone(...)"
        )
        XCTAssertTrue(
            body.contains("WorkbenchImportSummaryPresentation.iconSystemName(for:"),
            "the banner icon must come from the seam, not a hand-wired green check"
        )
        XCTAssertTrue(
            body.contains("WorkbenchImportSummaryPresentation.color(for:"),
            "the banner color must come from the seam"
        )
        // The tone is keyed off the import's persisted flag (the honesty source).
        XCTAssertTrue(
            body.contains("persisted: summary.persisted"),
            "the banner tone must key off summary.persisted"
        )
        // The honest not-persisted note is surfaced.
        XCTAssertTrue(
            body.contains("WorkbenchImportSummaryPresentation.notPersistedNote"),
            "the banner must surface the honest not-persisted note when the write failed"
        )
        // The old unconditional icon must be gone (it keyed green off hasImports,
        // ignoring whether the import persisted).
        XCTAssertFalse(
            body.contains("summary.hasImports ? \"checkmark.seal.fill\""),
            "the banner must no longer pick the green check off hasImports (ignored persistence)"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)
}
