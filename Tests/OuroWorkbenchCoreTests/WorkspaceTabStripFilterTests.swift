import XCTest
@testable import OuroWorkbenchCore

/// Slice ②b — FIX PASS (FP4 + FP5).
///
/// The independent review flagged MODERATE: the sidebar's filter empty-state was
/// tested against the UNFILTERED tab list, so "No sessions match…" never appeared
/// when a filter hid all of a workspace's tabs. In the LEAN-CMUX layout the filter
/// is relocated to the top strip, which renders the active workspace's tabs with the
/// filter APPLIED and shows the empty-state in the strip. This pins the pure Core
/// decision for the filtered-strip empty-state (tested against the FILTERED count).
final class WorkspaceTabStripFilterTests: XCTestCase {

    // The strip shows the "No sessions match…" empty-state ONLY when a filter is
    // active AND it hid EVERY tab that the (unfiltered) workspace actually has. A
    // genuinely-empty workspace (no tabs before filtering) is a DIFFERENT state
    // (the "no tabs yet" marker), not a filter miss.

    func testFilterEmptyStateWhenFilterHidesEveryExistingTab() {
        // 3 tabs exist, the filter matched none → strip shows the filter-empty state.
        XCTAssertTrue(
            WorkspaceSidebarPresentation.stripFilterHidAllTabs(
                tabsBeforeFilter: 3, tabsAfterFilter: 0, filterActive: true
            )
        )
    }

    func testNoFilterEmptyStateWhenFilterMatchesSomeTabs() {
        XCTAssertFalse(
            WorkspaceSidebarPresentation.stripFilterHidAllTabs(
                tabsBeforeFilter: 3, tabsAfterFilter: 1, filterActive: true
            )
        )
    }

    func testNoFilterEmptyStateWhenNoFilterActive() {
        // No filter active → an empty filtered list is just "no tabs yet", not a miss.
        XCTAssertFalse(
            WorkspaceSidebarPresentation.stripFilterHidAllTabs(
                tabsBeforeFilter: 3, tabsAfterFilter: 3, filterActive: false
            )
        )
        XCTAssertFalse(
            WorkspaceSidebarPresentation.stripFilterHidAllTabs(
                tabsBeforeFilter: 0, tabsAfterFilter: 0, filterActive: false
            )
        )
    }

    func testNoFilterEmptyStateWhenWorkspaceGenuinelyHasNoTabs() {
        // A genuinely-empty workspace (0 tabs before filtering) is the "no tabs yet"
        // state even with a filter active — the filter didn't hide anything.
        XCTAssertFalse(
            WorkspaceSidebarPresentation.stripFilterHidAllTabs(
                tabsBeforeFilter: 0, tabsAfterFilter: 0, filterActive: true
            )
        )
    }
}
