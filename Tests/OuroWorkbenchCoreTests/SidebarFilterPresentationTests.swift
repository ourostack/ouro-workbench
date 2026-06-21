import XCTest
@testable import OuroWorkbenchCore

/// U19(b)/(c): the pure copy behind the sidebar filter's scope indicator and its
/// zero-match empty state. Pinned in Core so the wording is tested rather than buried
/// as view literals.
final class SidebarFilterPresentationTests: XCTestCase {
    func testScopeIndicatorReadsCurrentWorkspaceWhenScoped() {
        XCTAssertEqual(
            SidebarFilterPresentation.scopeIndicator(isGlobal: false, workspaceName: "Spoonjoy"),
            "Searching Spoonjoy"
        )
    }

    func testScopeIndicatorReadsAllWorkspacesWhenGlobal() {
        // A structured owner:/status: query searches everywhere — say so explicitly so
        // the operator never wonders whether other workspaces were scanned.
        XCTAssertEqual(
            SidebarFilterPresentation.scopeIndicator(isGlobal: true, workspaceName: "Spoonjoy"),
            "Searching all workspaces"
        )
    }

    func testScopeIndicatorFallsBackWhenNoWorkspaceName() {
        XCTAssertEqual(
            SidebarFilterPresentation.scopeIndicator(isGlobal: false, workspaceName: nil),
            "Searching this workspace"
        )
        XCTAssertEqual(
            SidebarFilterPresentation.scopeIndicator(isGlobal: false, workspaceName: "  "),
            "Searching this workspace"
        )
    }

    func testEmptyStateMessageQuotesTheQuery() {
        XCTAssertEqual(
            SidebarFilterPresentation.emptyStateTitle(query: "status:waiting"),
            #"No sessions match "status:waiting""#
        )
    }

    func testEmptyStateMessageTrimsTheQuery() {
        XCTAssertEqual(
            SidebarFilterPresentation.emptyStateTitle(query: "  owner:agent  "),
            #"No sessions match "owner:agent""#
        )
    }

    func testGlobalEmptyStateDescriptionIsTrustworthy() {
        // When a GLOBAL search finds nothing, the operator can trust "nothing is waiting"
        // anywhere — say that, plus how to clear.
        XCTAssertEqual(
            SidebarFilterPresentation.emptyStateDescription(isGlobal: true),
            "Searched every workspace and found nothing. Clear the filter to see all sessions."
        )
    }

    func testScopedEmptyStateDescriptionMentionsOtherWorkspaces() {
        XCTAssertEqual(
            SidebarFilterPresentation.emptyStateDescription(isGlobal: false),
            "Clear the filter to see all sessions in this workspace."
        )
    }
}
