import XCTest
@testable import OuroWorkbenchCore

/// U23(c): the "Needs Me" / "Coding" columns used to render `prefix(3)` as
/// single-line plain Text, silently dropping items 4+. These pure helpers decide
/// how many to show vs. when to offer a "View all N" control, and derive the
/// navigation key each clickable item jumps by from the ref it already carries.
final class BossPaneListPresentationTests: XCTestCase {

    private func needsMe(label: String, ref: MailboxNavigationRef?) -> MailboxNeedsMeItem {
        MailboxNeedsMeItem(urgency: "u", label: label, detail: "d", ref: ref, ageMs: nil)
    }

    // MARK: - Visible-vs-overflow decision

    func testThreeOrFewerShowsAllWithNoOverflow() {
        let items = (0..<3).map { needsMe(label: "i\($0)", ref: nil) }
        let p = BossPaneListPresentation.make(count: items.count, visibleLimit: 3)
        XCTAssertEqual(p.visibleCount, 3)
        XCTAssertFalse(p.hasOverflow)
        XCTAssertNil(p.viewAllLabel)
    }

    func testMoreThanLimitShowsViewAllWithTotal() {
        let p = BossPaneListPresentation.make(count: 7, visibleLimit: 3)
        XCTAssertEqual(p.visibleCount, 3)
        XCTAssertTrue(p.hasOverflow)
        XCTAssertEqual(p.viewAllLabel, "View all 7")
    }

    func testExactlyAtLimitHasNoOverflow() {
        let p = BossPaneListPresentation.make(count: 3, visibleLimit: 3)
        XCTAssertFalse(p.hasOverflow)
        XCTAssertNil(p.viewAllLabel)
    }

    func testZeroCountHasNothingVisible() {
        let p = BossPaneListPresentation.make(count: 0, visibleLimit: 3)
        XCTAssertEqual(p.visibleCount, 0)
        XCTAssertFalse(p.hasOverflow)
    }

    // MARK: - Navigation key from the ref the item already carries

    func testNavigationKeyPrefersRefFocus() {
        let item = needsMe(label: "Ari is waiting", ref: MailboxNavigationRef(tab: "work", focus: "obl_1"))
        XCTAssertEqual(BossPaneListPresentation.navigationKey(for: item), "obl_1")
    }

    func testNavigationKeyFallsBackToLabelWhenNoFocus() {
        let item = needsMe(label: "deploy-bot", ref: MailboxNavigationRef(tab: "work", focus: nil))
        XCTAssertEqual(BossPaneListPresentation.navigationKey(for: item), "deploy-bot")
    }

    func testNavigationKeyFallsBackToLabelWhenNoRef() {
        let item = needsMe(label: "deploy-bot", ref: nil)
        XCTAssertEqual(BossPaneListPresentation.navigationKey(for: item), "deploy-bot")
    }

    func testNavigationKeyIgnoresBlankFocus() {
        let item = needsMe(label: "deploy-bot", ref: MailboxNavigationRef(tab: "work", focus: "   "))
        XCTAssertEqual(BossPaneListPresentation.navigationKey(for: item), "deploy-bot")
    }
}
