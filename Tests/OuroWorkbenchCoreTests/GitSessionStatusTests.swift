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

        let invalidCounts = GitSessionStatus.parse(porcelainV2: "# branch.head feature\n# branch.ab +bad -bad")
        XCTAssertEqual(invalidCounts.ahead, 0)
        XCTAssertEqual(invalidCounts.behind, 0)
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
        XCTAssertEqual(GitSessionStatus(isRepo: true).branchLabel, "(unknown)")
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

    func testResolveGitFallsBackToPathWhenKnownLocationsAreNotExecutable() throws {
        let fm = CoverageBatch2FileManager()
        fm.executablePaths = ["/custom/bin/git"]
        let environment = TerminalEnvironment(values: ["PATH": "/custom/bin", "HOME": "/home/test"])

        let reader = GitStatusReader(environment: environment, fileManager: fm)

        XCTAssertEqual(reader.resolvedGitPath, "/custom/bin/git")

        let missing = GitStatusReader(
            environment: TerminalEnvironment(values: ["PATH": "/missing/bin", "HOME": "/home/test"]),
            fileManager: fm
        )
        XCTAssertNil(missing.resolvedGitPath)
    }

    func testReaderReturnsNotARepoWhenDirectoryIsEmptyOrGitFails() throws {
        let root = try coverageBatch2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("git")
        try "#!/bin/sh\nexit 128\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        var reader = GitStatusReader(timeout: 1)
        reader.resolvedGitPath = git.path

        XCTAssertEqual(reader.status(forDirectory: ""), .notARepo)
        XCTAssertEqual(reader.status(forDirectory: root.path), .notARepo)
    }

    func testReaderParsesSuccessfulGitOutputFromResolvedGitPath() throws {
        let root = try coverageBatch2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        printf '%s\\n' '# branch.head feature/pinned-runner' '# branch.ab +4 -1' '? generated.txt'
        """.write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        // GENEROUS timeout (was 1s): the success path (GitSessionStatus.swift:161) is reached
        // only when the guard `Date().timeIntervalSince(start) < timeout` passes. A loaded CI
        // runner can occasionally take >1s to launch + reap the (trivial) stub subprocess —
        // which made the `< timeout` arm flakily false, skipping :161 and intermittently RED-ing
        // the exact-100% gate (same flake the campaign saw recur on this file). 60s removes the
        // timing race entirely while asserting the SAME parsed result (no weakening): the stub
        // exits in milliseconds, so the deterministic success path now reliably colours :161.
        var reader = GitStatusReader(timeout: 60)
        reader.resolvedGitPath = git.path

        let status = reader.status(forDirectory: root.path)
        XCTAssertEqual(
            status,
            GitSessionStatus(isRepo: true, branch: "feature/pinned-runner", dirty: true, ahead: 4, behind: 1)
        )
    }

    func testReaderReturnsNotARepoWhenGitCannotLaunchOrTimesOut() throws {
        let root = try coverageBatch2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var missing = GitStatusReader(timeout: 1)
        missing.resolvedGitPath = root.appendingPathComponent("missing-git").path
        XCTAssertEqual(missing.status(forDirectory: root.path), .notARepo)

        let hangingGit = root.appendingPathComponent("git")
        try "#!/bin/sh\nwhile true; do :; done\n".write(to: hangingGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hangingGit.path)
        var hanging = GitStatusReader(timeout: 0.05)
        hanging.resolvedGitPath = hangingGit.path

        XCTAssertEqual(hanging.status(forDirectory: root.path), .notARepo)
    }
}
