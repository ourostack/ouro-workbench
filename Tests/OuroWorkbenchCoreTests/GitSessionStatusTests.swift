import XCTest
@testable import OuroWorkbenchCore

final class GitSessionStatusTests: XCTestCase {
    func testCleanBranchInSyncWithUpstream() {
        let out = """
        # branch.oid 0b0ac03aa1
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """
        let s = GitSessionStatus.parse(porcelainV2: out)
        XCTAssertTrue(s.isRepo)
        XCTAssertEqual(s.branch, "main")
        XCTAssertFalse(s.detached)
        XCTAssertFalse(s.dirty)
        XCTAssertEqual(s.ahead, 0)
        XCTAssertEqual(s.behind, 0)
        XCTAssertEqual(s.branchLabel, "main")
        XCTAssertNil(s.aheadBehindLabel)
    }

    func testAheadAndBehindCounts() {
        let out = """
        # branch.head feature/foo
        # branch.upstream origin/feature/foo
        # branch.ab +3 -2
        """
        let s = GitSessionStatus.parse(porcelainV2: out)
        XCTAssertEqual(s.branch, "feature/foo")
        XCTAssertEqual(s.ahead, 3)
        XCTAssertEqual(s.behind, 2)
        XCTAssertEqual(s.aheadBehindLabel, "↑3↓2")
    }

    func testDirtyFromTrackedStagedUnmergedAndUntracked() {
        // 1 = changed, 2 = renamed, u = unmerged, ? = untracked
        for changeLine in [
            "1 .M N... 100644 100644 100644 abc abc src/file.swift",
            "2 R. N... 100644 100644 100644 abc abc R100 new\told",
            "u UU N... 100644 100644 100644 100644 abc abc abc conflict.swift",
            "? untracked.txt"
        ] {
            let out = "# branch.head main\n\(changeLine)"
            XCTAssertTrue(GitSessionStatus.parse(porcelainV2: out).dirty, "expected dirty for: \(changeLine)")
        }
    }

    func testIgnoredFilesDoNotMarkDirty() {
        let out = """
        # branch.head main
        ! build/output.o
        """
        XCTAssertFalse(GitSessionStatus.parse(porcelainV2: out).dirty)
    }

    func testDetachedHead() {
        let out = """
        # branch.oid 499d0b92
        # branch.head (detached)
        """
        let s = GitSessionStatus.parse(porcelainV2: out)
        XCTAssertTrue(s.detached)
        XCTAssertNil(s.branch)
        XCTAssertEqual(s.branchLabel, "(detached)")
    }

    func testNoUpstreamMeansZeroAheadBehind() {
        let out = """
        # branch.head local-only
        ? new.txt
        """
        let s = GitSessionStatus.parse(porcelainV2: out)
        XCTAssertEqual(s.branch, "local-only")
        XCTAssertEqual(s.ahead, 0)
        XCTAssertEqual(s.behind, 0)
        XCTAssertTrue(s.dirty)
    }

    func testNotARepoSentinel() {
        XCTAssertFalse(GitSessionStatus.notARepo.isRepo)
        XCTAssertNil(GitSessionStatus.notARepo.branchLabel)
    }

    func testReaderReturnsRepoStatusForThisCheckout() throws {
        // Integration smoke: the package's own working tree is a git repo, so
        // the reader should resolve git and report a branch. Skip gracefully if
        // git isn't installed in the test environment.
        let reader = GitStatusReader(timeout: 5)
        try XCTSkipIf(reader.resolvedGitPath == nil, "git not available")
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let s = reader.status(forDirectory: here)
        XCTAssertTrue(s.isRepo, "expected the package checkout to be a git repo")
        XCTAssertNotNil(s.branchLabel)
    }
}
