import Foundation
import Darwin

/// F8b — spawn a child process into its OWN process group so the child AND all of its
/// (node) grandchildren can be reaped as a unit with `killpg(childPid, SIGKILL)`.
///
/// ## Why posix_spawn + SETPGROUP (not setpgid-from-parent, not setsid)
/// `posix_spawn` with `POSIX_SPAWN_SETPGROUP` + `posix_spawnattr_setpgroup(&attr, 0)` makes
/// the KERNEL set the new group (pgid == child pid) BEFORE the child runs, so every
/// grandchild the child forks is born in that group. `killpg(childPid, SIGKILL)` then reaps
/// the whole tree, provably never Workbench (childPid != Workbench's pgid).
///
/// - setpgid from the parent is racy: it can lose to the child's exec (EACCES) and a
///   grandchild may fork into Workbench's group before it lands.
/// - `setsid` via a wrapper is unavailable: macOS ships no `/usr/bin/setsid`, and a full
///   session detach is more than the own-group reap needs (own-group keeps the controlling
///   terminal, which the mcp-serve pipe wiring relies on).
///
/// ## Fidelity (the correctness linchpin for the live mcp-serve path)
/// The marshalling is byte-faithful: callers pass the SAME `/usr/bin/env` executable, the
/// SAME argv (`["env", "ouro", …]`), and the SAME environment (`TerminalEnvironment()
/// .valuesWithResolvedPath()`) the prior `Process()` used, so PATH-resolution of `ouro` is
/// unchanged. The argv/envp C-string marshalling is factored into the pure `cStrings`
/// helper (100%-tested by value); only the raw `posix_spawn` call + its `guard rc == 0`
/// are impure (proven by the real-spawn integration tests).
public enum SpawnInOwnGroup {
    /// A spawned child in its own process group. `pid` is also its pgid (SETPGROUP), so
    /// `killpg(pid, SIGKILL)` reaps the child + every grandchild.
    public struct Spawned: Equatable, Sendable {
        public let pid: pid_t
        public init(pid: pid_t) {
            self.pid = pid
        }
    }

    /// The three child stdio file descriptors to dup2 into the child (already opened by the
    /// caller — pipe ends for mcp-serve, `/dev/null` for the detached daemon).
    public struct StdioFDs: Equatable, Sendable {
        public let stdin: Int32
        public let stdout: Int32
        public let stderr: Int32
        public init(stdin: Int32, stdout: Int32, stderr: Int32) {
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// The single failure mode: `posix_spawn` itself returned non-zero (e.g. ENOENT for an
    /// absent executable). Carries the raw errno so the caller can audit/classify.
    public enum SpawnError: Error, Equatable, Sendable {
        case posixSpawnFailed(errno: Int32)
    }

    /// An owned NULL-terminated C-string array (argv or envp). Holds the duplicated C
    /// strings AND the pointer buffer; `deallocate()` frees both. Pure + value-testable:
    /// `cStrings` builds it with no syscalls, so coverage is by assertion, not by spawn.
    public struct CStringArray {
        /// NULL-terminated pointer buffer suitable for `posix_spawn`'s argv/envp parameter.
        public let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        private let count: Int

        init(pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
            self.pointers = pointers
            self.count = count
        }

        /// Free every duplicated C string and the pointer buffer.
        public func deallocate() {
            for index in 0..<count {
                free(pointers[index])
            }
            pointers.deallocate()
        }
    }

    /// Marshal `strings` into an owned NULL-terminated C-string array. Pure — no syscalls,
    /// no spawn — so it is fully coverable by value. The returned `CStringArray` must be
    /// `deallocate()`d by the caller.
    public static func cStrings(_ strings: [String]) -> CStringArray {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            buffer[index] = strdup(string)
        }
        buffer[strings.count] = nil
        return CStringArray(pointers: buffer, count: strings.count)
    }

    /// Marshal an environment dict into a sorted `KEY=VALUE` array (deterministic order so
    /// the spawn is reproducible and the source-pin can reason about it). Pure.
    public static func environmentStrings(_ environment: [String: String]) -> [String] {
        environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    /// Spawn `executablePath` with `arguments` (full argv incl. argv[0]) and `environment`,
    /// dup2-ing `stdio` onto the child's fds 0/1/2, in a FRESH process group (pgid == child
    /// pid). Returns the child pid; throws `.posixSpawnFailed` iff `posix_spawn` failed.
    public static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdio: StdioFDs
    ) throws -> Spawned {
        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own group: kernel sets pgid == child pid BEFORE exec, so grandchildren are born
        // in the same group and killpg(childPid, …) reaps the whole tree.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdio.stdin, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdio.stdout, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stdio.stderr, 2)

        let argv = cStrings(arguments)
        defer { argv.deallocate() }
        let envp = cStrings(environmentStrings(environment))
        defer { envp.deallocate() }

        var pid = pid_t()
        let rc = posix_spawn(&pid, executablePath, &fileActions, &attributes, argv.pointers, envp.pointers)
        guard rc == 0 else {
            throw SpawnError.posixSpawnFailed(errno: rc)
        }
        return Spawned(pid: pid)
    }
}
