import XCTest
@testable import OuroWorkbenchCore

final class ProcessRunRecencyTests: XCTestCase {
    private func run(_ id: UUID, _ startedAt: Date) -> ProcessRun {
        ProcessRun(id: id, entryId: UUID(), status: .running, startedAt: startedAt)
    }

    func testNewerStartedAtIsMoreRecent() {
        let older = run(UUID(), Date(timeIntervalSince1970: 100))
        let newer = run(UUID(), Date(timeIntervalSince1970: 200))
        XCTAssertTrue(ProcessRun.isMoreRecent(newer, older))
        XCTAssertFalse(ProcessRun.isMoreRecent(older, newer))
    }

    func testEqualStartedAtBreaksOnIdDeterministically() {
        let when = Date(timeIntervalSince1970: 100)
        let a = run(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, when)
        let b = run(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, when)
        // Whatever the rule, it must be a strict, consistent total order: not
        // both directions true, and stable regardless of argument order.
        XCTAssertNotEqual(ProcessRun.isMoreRecent(a, b), ProcessRun.isMoreRecent(b, a))
        XCTAssertEqual(ProcessRun.isMoreRecent(a, b), ProcessRun.isMoreRecent(a, b))
    }

    func testSortingPicksSameLatestRegardlessOfInputOrder() {
        let when = Date(timeIntervalSince1970: 100)
        let a = run(UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!, when)
        let b = run(UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!, when)
        let c = run(UUID(uuidString: "00000000-0000-0000-0000-0000000000cc")!, when)
        let first = [a, b, c].sorted(by: ProcessRun.isMoreRecent).first
        let reversedFirst = [c, b, a].sorted(by: ProcessRun.isMoreRecent).first
        XCTAssertEqual(first?.id, reversedFirst?.id, "latest run must not depend on input order")
    }

    func testPruneProcessRunsKeepsNewestPerEntryAndDropsOlder() {
        let entryA = UUID()
        let entryB = UUID()
        func r(_ entry: UUID, _ t: TimeInterval) -> ProcessRun {
            ProcessRun(entryId: entry, status: .exited, startedAt: Date(timeIntervalSince1970: t))
        }
        var state = WorkspaceState(
            processRuns: (0..<30).map { r(entryA, Double($0)) } + (0..<5).map { r(entryB, Double($0)) }
        )

        state.pruneProcessRuns(perEntryCap: 10)

        XCTAssertEqual(state.processRuns.filter { $0.entryId == entryA }.count, 10)
        XCTAssertEqual(state.processRuns.filter { $0.entryId == entryB }.count, 5)
        // The newest A run (t=29) survives; the oldest (t=0) is dropped.
        let aStarts = Set(state.processRuns.filter { $0.entryId == entryA }.map { $0.startedAt.timeIntervalSince1970 })
        XCTAssertTrue(aStarts.contains(29))
        XCTAssertFalse(aStarts.contains(0))
    }

    func testPruneProcessRunsNoOpUnderCap() {
        let entry = UUID()
        let runs = (0..<3).map { ProcessRun(entryId: entry, status: .running, startedAt: Date(timeIntervalSince1970: Double($0))) }
        var state = WorkspaceState(processRuns: runs)
        state.pruneProcessRuns(perEntryCap: 25)
        XCTAssertEqual(state.processRuns.count, 3)
    }
}
