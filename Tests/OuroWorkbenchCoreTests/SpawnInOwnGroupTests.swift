import Foundation
import Darwin
import XCTest
@testable import OuroWorkbenchCore

/// F8b — the own-process-group spawn primitive. `posix_spawn` + `POSIX_SPAWN_SETPGROUP`
/// (pgid == child pid) places the child + ALL of its (node) grandchildren in a fresh
/// process group BEFORE the child runs, so `killpg(childPid, SIGKILL)` reaps the entire
/// tree — provably never Workbench (its pid != Workbench's pgid).
///
/// The argv/envp C-string marshalling is factored into a PURE helper (`cStrings`) so it is
/// 100%-coverable by value; only the raw `posix_spawn` call + its `guard rc == 0` are impure,
/// and those are exercised by the real-spawn integration tests below.
final class SpawnInOwnGroupTests: XCTestCase {

    // MARK: - Pure marshalling (cStrings)

    func testCStringsRoundTripsArgvNullTerminated() {
        let result = SpawnInOwnGroup.cStrings(["env", "ouro", "mcp-serve"])
        defer { result.deallocate() }
        // Each non-null slot decodes back to the original string, in order.
        XCTAssertEqual(stringValue(result.pointers[0]), "env")
        XCTAssertEqual(stringValue(result.pointers[1]), "ouro")
        XCTAssertEqual(stringValue(result.pointers[2]), "mcp-serve")
        // NULL-terminated: the slot after the last string is nil.
        XCTAssertNil(result.pointers[3])
    }

    func testCStringsHandlesEmptyArray() {
        // An empty input still yields a single NULL terminator (a valid empty argv/envp).
        let result = SpawnInOwnGroup.cStrings([])
        defer { result.deallocate() }
        XCTAssertNil(result.pointers[0])
    }

    func testCStringsPreservesUTF8AndSpaces() {
        // PATH-resolved env values + a --workbench-mcp path can contain spaces and UTF-8;
        // marshalling must preserve them byte-for-byte (the fidelity linchpin).
        let input = ["KEY=/Applications/Ouro Workbench.app/Contents/MacOS/x", "EMOJI=café→ok"]
        let result = SpawnInOwnGroup.cStrings(input)
        defer { result.deallocate() }
        XCTAssertEqual(stringValue(result.pointers[0]), input[0])
        XCTAssertEqual(stringValue(result.pointers[1]), input[1])
        XCTAssertNil(result.pointers[2])
    }

    func testEnvironmentStringsAreKeyEqualsValue() {
        // The env dict marshalls to a stable, sorted "KEY=VALUE" array (deterministic order
        // so the spawn is reproducible and the source-pin can reason about it).
        let strings = SpawnInOwnGroup.environmentStrings(["B": "2", "A": "1"])
        XCTAssertEqual(strings, ["A=1", "B=2"])
    }

    // MARK: - Integration: SETPGROUP took (getpgid(pid) == pid)

    func testSpawnPlacesChildInItsOwnGroup() throws {
        // Spawn a trivial, fast child in its own group; the kernel must have set the group
        // BEFORE exec, so getpgid(childPid) == childPid. This is the SETPGROUP proof.
        let devNull = try openDevNull()
        defer { close(devNull) }
        let spawned = try SpawnInOwnGroup.spawn(
            executablePath: "/usr/bin/env",
            arguments: ["env", "true"],
            environment: [:],
            stdio: SpawnInOwnGroup.StdioFDs(stdin: devNull, stdout: devNull, stderr: devNull)
        )
        XCTAssertEqual(
            getpgid(spawned.pid), spawned.pid,
            "POSIX_SPAWN_SETPGROUP must place the child in its own group (pgid == pid)"
        )
        // Reap so we don't leak a zombie.
        var status: Int32 = 0
        waitpid(spawned.pid, &status, 0)
    }

    // MARK: - Integration: THE grandchild-reap proof

    func testKillpgReapsTheChildAndItsGrandchild() throws {
        // Spawn `/bin/sh -c 'sleep 30 & echo $! 1>&fd; wait'` in its OWN group: the shell is
        // the child, the `sleep 30` is a GRANDCHILD forked by the shell. Because the shell was
        // born in its own group, the sleep inherits that group. killpg(childPid, SIGKILL) must
        // reap BOTH — proving the node-grandchild tree dies as a unit. A plain child-only
        // kill(childPid) would leave the sleep orphaned (the leak F8b fixes).
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading
        let writeFD = pipe.fileHandleForWriting
        let devNull = try openDevNull()
        defer { close(devNull) }

        // The grandchild prints its own pid to stdout so the test can observe it.
        let spawned = try SpawnInOwnGroup.spawn(
            executablePath: "/bin/sh",
            arguments: ["sh", "-c", "sleep 30 & echo $! ; wait"],
            environment: [:],
            stdio: SpawnInOwnGroup.StdioFDs(
                stdin: devNull,
                stdout: writeFD.fileDescriptor,
                stderr: devNull
            )
        )
        // Close our copy of the write end so the read sees EOF once the shell's stdout closes.
        try? writeFD.close()

        // Read the grandchild's pid (the shell echoes it before `wait`).
        let grandchildPID = try readGrandchildPID(from: readFD)
        XCTAssertGreaterThan(grandchildPID, 0, "expected a real grandchild pid")

        // Both alive right now.
        XCTAssertEqual(kill(spawned.pid, 0), 0, "shell (child) should be alive before the reap")
        XCTAssertEqual(kill(grandchildPID, 0), 0, "sleep (grandchild) should be alive before the reap")

        // THE reap: killpg the child's group (== child pid). Reaps child AND grandchild.
        XCTAssertEqual(killpg(spawned.pid, SIGKILL), 0, "killpg of the own-group must succeed")

        // Reap the shell zombie and give the grandchild a moment to be torn down.
        var status: Int32 = 0
        waitpid(spawned.pid, &status, 0)
        try? readFD.close()

        // The grandchild must be GONE: kill(pid, 0) returns -1 (ESRCH) once it's reaped.
        XCTAssertTrue(
            waitForProcessGone(grandchildPID),
            "killpg must reap the grandchild (sleep) too — kill(gcPid, 0) should fail with ESRCH"
        )
    }

    // MARK: - Error arm

    func testSpawnOfNonexistentAbsolutePathThrows() {
        // posix_spawn of an absolute path that does not exist fails synchronously with ENOENT;
        // the impure `guard rc == 0` must throw `.posixSpawnFailed`.
        let devNull = (try? openDevNull()) ?? -1
        defer { if devNull >= 0 { close(devNull) } }
        XCTAssertThrowsError(
            try SpawnInOwnGroup.spawn(
                executablePath: "/nonexistent/definitely/not/here/binary",
                arguments: ["binary"],
                environment: [:],
                stdio: SpawnInOwnGroup.StdioFDs(stdin: devNull, stdout: devNull, stderr: devNull)
            )
        ) { error in
            guard case SpawnInOwnGroup.SpawnError.posixSpawnFailed(let errno) = error else {
                return XCTFail("expected .posixSpawnFailed, got \(error)")
            }
            XCTAssertEqual(errno, ENOENT, "an absent absolute path must surface ENOENT")
        }
    }

    // MARK: - helpers

    private func stringValue(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    private func openDevNull() throws -> Int32 {
        let fd = open("/dev/null", O_RDWR)
        if fd < 0 { throw NSError(domain: "test", code: Int(errno)) }
        return fd
    }

    private func readGrandchildPID(from handle: FileHandle) throws -> pid_t {
        // The shell echoes the background pid on its own line before `wait`.
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(line) { return pid }
            }
        }
        let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = pid_t(text) { return pid }
        throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "no grandchild pid: \(text)"])
    }

    private func waitForProcessGone(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(20_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}
