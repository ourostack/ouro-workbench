import Foundation
import OuroWorkbenchCore

/// The real, executable-target process lister the MCP server injects into
/// `AgentSessionScanner.scan(processLister:)`. It is the ONLY un-testable half of
/// the discovery path — a thin `Process` shell around `ps` whose stdout is handed
/// straight to the pure, 100%-covered `RunningProcessLine.parsePS` in Core.
///
/// GENERAL by design: it lists every running process (no agency / repo / agent-map
/// filter here) and lets Core's `AgentHarness.classify` decide which lines are
/// agent harnesses. Core owns all classification; this owns only the syscall.
///
/// `cwd` is left nil on every line — `ps` cannot report a process's working
/// directory, and the scanner already treats a nil cwd as "unresolved". Resolving
/// it would mean per-pid `lsof`/`proc_pidinfo` calls, which are expensive and
/// fragile; the boss gets the harness + pid and can resolve cwd itself if it ever
/// needs to. Keeping this narrow is the point.
struct RunningProcessLister: Sendable {
    /// `ps` path. The system binary at a fixed absolute path — no PATH lookup, so
    /// nothing the environment can shadow.
    private let psPath: String

    /// Seconds before the watchdog force-terminates a wedged `ps`. `ps` is a
    /// fast read of the process table; a generous bound still protects the
    /// long-lived MCP read loop from a pathological hang.
    private let timeoutSeconds: Double

    init(psPath: String = "/bin/ps", timeoutSeconds: Double = 10) {
        self.psPath = psPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// A `@Sendable` closure suitable for `scan(processLister:)`. Runs `ps` once
    /// per call and returns the parsed lines; on any failure (spawn error,
    /// non-zero exit, decode failure) it returns an empty list so discovery
    /// degrades to recent-only rather than throwing into the read loop.
    func callAsFunction() -> [RunningProcessLine] {
        guard let output = runPS() else { return [] }
        return RunningProcessLine.parsePS(output)
    }

    /// Run `ps -axww -o pid=,command=` and capture stdout. `-ax` = every process
    /// (all users, no controlling terminal required); `-ww` = do not truncate the
    /// command column; `-o pid=,command=` = pid then full command, no header. nil
    /// on spawn failure, timeout, or non-zero exit.
    private func runPS() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: psPath)
        process.arguments = ["-axww", "-o", "pid=,command="]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain the pipe BEFORE waiting: a large process table can fill the pipe
        // buffer and deadlock `ps` if we wait first (the standard drain-then-wait
        // idiom used elsewhere in the codebase).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: timeoutSeconds)
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
