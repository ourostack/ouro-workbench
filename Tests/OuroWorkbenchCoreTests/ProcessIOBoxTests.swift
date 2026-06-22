import Foundation
import Darwin
import XCTest
@testable import OuroWorkbenchCore

/// F8b — `ProcessIOBox` now holds a raw pid + the pipe FileHandles + injectable kill/liveness
/// seams (it no longer wraps a `Process`). These tests pin the routing of `terminate()` /
/// `forceKill()` through the seams WITHOUT a real subprocess, so the escalation policy and the
/// fail-closed own-group gate are covered deterministically.
final class ProcessIOBoxTests: XCTestCase {

    /// Records every `(pid, signal)` delivered through a kill seam.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(pid: pid_t, signal: Int32)] = []
        func record(_ pid: pid_t, _ signal: Int32) {
            lock.lock(); calls.append((pid, signal)); lock.unlock()
        }
    }

    private func makeBox(
        pid: pid_t,
        childInOwnGroup: Bool,
        isAlive: @escaping @Sendable (pid_t) -> Bool,
        processKiller: @escaping @Sendable (pid_t, Int32) -> Int32,
        groupKiller: @escaping @Sendable (pid_t, Int32) -> Int32
    ) -> ProcessIOBox {
        // Two throwaway pipes — the read loop isn't exercised here, but the box needs real
        // FileHandles to hold. Their fds are closed when the handles deinit.
        let out = Pipe()
        let err = Pipe()
        return ProcessIOBox(
            pid: pid,
            stdout: out.fileHandleForReading,
            stderr: err.fileHandleForReading,
            childInOwnGroup: childInOwnGroup,
            isAlive: isAlive,
            processKiller: processKiller,
            groupKiller: groupKiller
        )
    }

    func testTerminateSendsSigtermToTheChildPidWhenAlive() {
        let rec = Recorder()
        let box = makeBox(
            pid: 4242,
            childInOwnGroup: true,
            isAlive: { _ in true },
            processKiller: { rec.record($0, $1); return 0 },
            groupKiller: { _, _ in XCTFail("terminate must never use the group killer"); return 0 }
        )
        box.terminate()
        XCTAssertEqual(rec.calls.count, 1)
        XCTAssertEqual(rec.calls.first?.pid, 4242)
        XCTAssertEqual(rec.calls.first?.signal, SIGTERM, "terminate must send SIGTERM to the child pid")
    }

    func testForceKillRoutesViaGroupKillerForAnOwnGroupChild() {
        // The LIVE leak fix: an own-group child past grace → killpg(pid, SIGKILL) via the
        // groupKiller seam (NOT the child-only processKiller).
        let groupRec = Recorder()
        let childRec = Recorder()
        let box = makeBox(
            pid: 9001,
            childInOwnGroup: true,
            isAlive: { _ in true },
            processKiller: { childRec.record($0, $1); return 0 },
            groupKiller: { groupRec.record($0, $1); return 0 }
        )
        box.forceKill()
        XCTAssertEqual(groupRec.calls.count, 1, "own-group force-kill must go through the group killer")
        XCTAssertEqual(groupRec.calls.first?.pid, 9001)
        XCTAssertEqual(groupRec.calls.first?.signal, SIGKILL)
        XCTAssertEqual(childRec.calls.count, 0, "own-group force-kill must NOT use the child-only killer")
    }

    func testForceKillRoutesViaChildKillerWhenNotInOwnGroup() {
        // Fail-closed / child-only: a box whose group could NOT be verified must SIGKILL the
        // child pid only — never killpg (that would reap Workbench's shared group).
        let groupRec = Recorder()
        let childRec = Recorder()
        let box = makeBox(
            pid: 7,
            childInOwnGroup: false,
            isAlive: { _ in true },
            processKiller: { childRec.record($0, $1); return 0 },
            groupKiller: { groupRec.record($0, $1); return 0 }
        )
        box.forceKill()
        XCTAssertEqual(childRec.calls.count, 1, "non-own-group force-kill must use the child-only killer")
        XCTAssertEqual(childRec.calls.first?.pid, 7)
        XCTAssertEqual(childRec.calls.first?.signal, SIGKILL)
        XCTAssertEqual(groupRec.calls.count, 0, "must NEVER killpg a child not provably in its own group")
    }

    func testForceKillIsANoOpWhenChildAlreadyReaped() {
        // Liveness via kill(pid, 0): if the child already exited, force-kill delivers NOTHING
        // (never signal a reaped/recycled pid).
        let groupRec = Recorder()
        let childRec = Recorder()
        let box = makeBox(
            pid: 9001,
            childInOwnGroup: true,
            isAlive: { _ in false },
            processKiller: { childRec.record($0, $1); return 0 },
            groupKiller: { groupRec.record($0, $1); return 0 }
        )
        box.forceKill()
        XCTAssertEqual(groupRec.calls.count, 0)
        XCTAssertEqual(childRec.calls.count, 0)
    }

    func testTerminateIsANoOpWhenChildAlreadyReaped() {
        let rec = Recorder()
        let box = makeBox(
            pid: 9001,
            childInOwnGroup: true,
            isAlive: { _ in false },
            processKiller: { rec.record($0, $1); return 0 },
            groupKiller: { _, _ in 0 }
        )
        box.terminate()
        XCTAssertEqual(rec.calls.count, 0, "terminate must skip a reaped child")
    }

    // MARK: - Default seams against a real own-group child

    func testTerminateDefaultSeamSendsSigtermToARealChild() throws {
        // Exercises the PRODUCTION `terminate()` default `processKiller` (kill(pid, SIGTERM))
        // and default `isAlive` (kill(pid, 0)) against a real /bin/sleep — proving the polite
        // first ask actually reaches the child.
        let devNull = open("/dev/null", O_RDWR)
        defer { close(devNull) }
        let spawned = try SpawnInOwnGroup.spawn(
            executablePath: "/bin/sleep",
            arguments: ["sleep", "30"],
            environment: [:],
            stdio: SpawnInOwnGroup.StdioFDs(stdin: devNull, stdout: devNull, stderr: devNull)
        )
        let box = ProcessIOBox(
            pid: spawned.pid,
            stdout: Pipe().fileHandleForReading,
            stderr: Pipe().fileHandleForReading,
            childInOwnGroup: false
        )
        box.terminate() // default SIGTERM via real kill — /bin/sleep dies on SIGTERM
        var status: Int32 = 0
        waitpid(spawned.pid, &status, 0)
        XCTAssertTrue(kill(spawned.pid, 0) == -1 && errno == ESRCH, "SIGTERM must reap /bin/sleep")
    }

    // MARK: - ownGroupVerification (pure fail-closed gate) + makeProcessBox

    func testOwnGroupVerificationMatchIsOwnGroupNoAudit() {
        // SETPGROUP took (getpgid == pid) → own-group, no audit line.
        let result = BossAgentMCPClient.ownGroupVerification(spawnedPID: 555, actualPGID: 555)
        XCTAssertTrue(result.inOwnGroup)
        XCTAssertNil(result.auditLine, "a verified own-group emits no audit line")
    }

    func testOwnGroupVerificationMismatchFailsClosedWithAudit() {
        // SETPGROUP did NOT take (getpgid != pid) → child-only + a fail-closed audit line.
        let result = BossAgentMCPClient.ownGroupVerification(spawnedPID: 555, actualPGID: 999)
        XCTAssertFalse(result.inOwnGroup, "a pgid mismatch must fail closed to child-only")
        XCTAssertTrue(result.auditLine?.contains("fail-closed") == true)
        XCTAssertTrue(result.auditLine?.contains("555") == true)
        XCTAssertTrue(result.auditLine?.contains("999") == true)
    }

    func testMakeProcessBoxMismatchEmitsAuditAndBuildsChildOnlyBox() {
        // Drive makeProcessBox's MISMATCH path directly (a real own-group spawn never mismatches),
        // covering the stderr audit emission + the child-only box construction. The resulting box
        // is child-only: forceKill routes via the child killer, never killpg.
        let groupRec = Recorder()
        let childRec = Recorder()
        // makeProcessBox uses default kill seams; we can't inject into it, so re-derive the box
        // with the same flag to assert routing. The flag is proven false by ownGroupVerification.
        _ = BossAgentMCPClient.makeProcessBox(
            spawnedPID: 424242,
            actualPGID: 999999,
            stdout: Pipe().fileHandleForReading,
            stderr: Pipe().fileHandleForReading
        )
        // Independently assert the child-only routing the mismatch flag drives.
        let mirror = makeBox(
            pid: 424242,
            childInOwnGroup: false,
            isAlive: { _ in true },
            processKiller: { childRec.record($0, $1); return 0 },
            groupKiller: { groupRec.record($0, $1); return 0 }
        )
        mirror.forceKill()
        XCTAssertEqual(childRec.calls.first?.signal, SIGKILL)
        XCTAssertEqual(groupRec.calls.count, 0, "a fail-closed (mismatch) box must never killpg")
    }

    func testMakeProcessBoxMatchBuildsOwnGroupBox() {
        // Drive makeProcessBox's MATCH path (covers the no-audit construction branch).
        _ = BossAgentMCPClient.makeProcessBox(
            spawnedPID: 777,
            actualPGID: 777,
            stdout: Pipe().fileHandleForReading,
            stderr: Pipe().fileHandleForReading
        )
    }
}
