import Foundation
import Darwin

public enum BossAgentMCPClientError: Error, Equatable, LocalizedError, Sendable {
    case processNotAvailable(String)
    case timeout
    case closed
    case malformedResponse
    case rpcError(String)
    case toolError(String)
    /// The boss returned a well-formed but empty / non-answer reply. Treated as
    /// a failure (not a blank "success") so a misconfigured boss surfaces an
    /// actionable error instead of an empty pane.
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .processNotAvailable(let message):
            return message.isEmpty ? "Ouro MCP process is not available." : message
        case .timeout:
            return "Ouro MCP request timed out."
        case .closed:
            return "Ouro MCP process closed before returning a response."
        case .malformedResponse:
            return "Ouro MCP returned a malformed response."
        case .rpcError(let message):
            return message
        case .toolError(let message):
            return message
        case .emptyResult:
            return "Your agent didn't respond. Workbench will try again automatically — if this keeps happening, reopen Workbench."
        }
    }
}

public final class BossAgentMCPClient: @unchecked Sendable {
    public var timeoutNanoseconds: UInt64

    /// The installed Workbench MCP binary path passed to the boss's turn for RUNTIME INJECTION.
    ///
    /// When non-nil, every `mcp-serve` spawn appends `--workbench-mcp <path>` so the `ouro`
    /// runtime injects the Workbench MCP into THIS boss's turn at runtime — nothing is written to
    /// the synced agent bundle. A non-nil but EMPTY string passes the flag path-less so the
    /// `ouro` side self-discovers the binary. `nil` (the default) omits the flag.
    public var workbenchMCPPath: String?

    public init(
        timeoutNanoseconds: UInt64 = 120_000_000_000,
        workbenchMCPPath: String? = nil
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.workbenchMCPPath = workbenchMCPPath
    }

    /// `["mcp-serve", "--agent", <agentName>] (+ ["--workbench-mcp", <path>] | ["--workbench-mcp"])`.
    /// Pure + testable so the spawn site and the bridge plan agree on the exact arg shape.
    public static func mcpServeArguments(agentName: String, workbenchMCPPath: String?) -> [String] {
        ["mcp-serve", "--agent"] + BossAgentBridgePlanner.agentAndWorkbenchArguments(
            agentName: agentName,
            workbenchMCPPath: workbenchMCPPath
        )
    }

    /// The configured spawn args for this client (uses `workbenchMCPPath`).
    public func mcpServeArguments(agentName: String) -> [String] {
        Self.mcpServeArguments(agentName: agentName, workbenchMCPPath: workbenchMCPPath)
    }

    /// One spawned mcp-serve turn: the stdin write handle (the caller drives JSON-RPC into it)
    /// + the `ProcessIOBox` that owns the pid and the read side.
    struct SpawnedMCPServe {
        let stdinWrite: FileHandle
        let box: ProcessIOBox
    }

    /// Spawn `/usr/bin/env ouro <mcpServeArguments>` into its OWN process group via
    /// `SpawnInOwnGroup`, with the SAME executable / argv / environment / stdio the prior
    /// `Process()` path used (byte-identical → PATH-resolution of `ouro` is unchanged).
    ///
    /// FIDELITY: executable `/usr/bin/env`; argv `["env", "ouro"] + mcpServeArguments(...)`
    /// (note argv[0] is `"env"`, matching how `Process(executableURL: /usr/bin/env,
    /// arguments: ["ouro", …])` builds the child's argv); environment
    /// `TerminalEnvironment().valuesWithResolvedPath()`; stdio the three pipe ends. After the
    /// spawn the parent closes ITS copies of the child-side ends so the read loop sees EOF when
    /// the child exits (Foundation did this implicitly; with raw `posix_spawn` we do it).
    ///
    /// FAIL-CLOSED: `childInOwnGroup` is set from `getpgid(pid) == pid` via the pure
    /// `makeProcessBox` seam — a child whose group could not be verified is treated as child-only
    /// (never killpg).
    private func spawnMCPServe(agentName: String) throws -> SpawnedMCPServe {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let spawned = try SpawnInOwnGroup.spawn(
            executablePath: "/usr/bin/env",
            arguments: ["env", "ouro"] + mcpServeArguments(agentName: agentName),
            environment: TerminalEnvironment().valuesWithResolvedPath(),
            stdio: SpawnInOwnGroup.StdioFDs(
                stdin: stdinPipe.fileHandleForReading.fileDescriptor,
                stdout: stdoutPipe.fileHandleForWriting.fileDescriptor,
                stderr: stderrPipe.fileHandleForWriting.fileDescriptor
            )
        )

        // The child holds its own dup'd copies now; close the parent's copies of the child-side
        // ends so a closed child stdout/stderr reads EOF (and the child's stdin sees EOF on
        // our write-end close).
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Give the box its OWN read fds, distinct from the `Pipe`'s, so closing is unambiguous:
        // `dup` the pipe read fds into box-owned descriptors and close the originals. The box then
        // owns exactly two read fds and is their SOLE closer (once, via `closeReadHandles()` — FIX 1
        // for the leak, FIX 2 for the parked-read unblock). The box's handles are `closeOnDealloc:
        // false`, and the originals are closed here, so no fd is ever closed twice (which, after the
        // box's raw close, could clobber a recycled fd number). This only governs the PARENT's
        // read-side fd lifecycle — the child already holds its own dup'd stdio copies, so the
        // marshalling handed to the child is unchanged.
        let stdoutReadFD = dup(stdoutPipe.fileHandleForReading.fileDescriptor)
        let stderrReadFD = dup(stderrPipe.fileHandleForReading.fileDescriptor)
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        let box = Self.makeProcessBox(
            spawnedPID: spawned.pid,
            actualPGID: getpgid(spawned.pid),
            stdout: FileHandle(fileDescriptor: stdoutReadFD, closeOnDealloc: false),
            stderr: FileHandle(fileDescriptor: stderrReadFD, closeOnDealloc: false)
        )
        return SpawnedMCPServe(stdinWrite: stdinPipe.fileHandleForWriting, box: box)
    }

    /// THE single-flag invariant + fail-closed gate, PURE and value-tested: returns whether the
    /// child is provably in its own group (`actualPGID == spawnedPID`, i.e. SETPGROUP took) and,
    /// on a MISMATCH, a diagnostic audit line. A child that can't be verified is treated as
    /// child-only by the caller (forceKill → `kill`, never `killpg`) — the audit is informational;
    /// the fail-closed SAFETY does not depend on it.
    static func ownGroupVerification(spawnedPID: pid_t, actualPGID: pid_t) -> (inOwnGroup: Bool, auditLine: String?) {
        if actualPGID == spawnedPID {
            return (true, nil)
        }
        return (
            false,
            "F8b fail-closed: spawned pid \(spawnedPID) is NOT in its own group "
                + "(getpgid=\(actualPGID)); treating as child-only (no killpg)."
        )
    }

    /// Construct the `ProcessIOBox` from the spawned pid and the pgid the OS reports for it.
    /// Delegates the own-group decision to the pure `ownGroupVerification` seam; on a mismatch it
    /// emits the fail-closed audit line to stderr. A dedicated test drives the mismatch path
    /// directly (so the audit emission is covered) since a real own-group spawn never mismatches.
    static func makeProcessBox(
        spawnedPID: pid_t,
        actualPGID: pid_t,
        stdout: FileHandle,
        stderr: FileHandle
    ) -> ProcessIOBox {
        let verification = ownGroupVerification(spawnedPID: spawnedPID, actualPGID: actualPGID)
        if let auditLine = verification.auditLine {
            FileHandle.standardError.write(Data((auditLine + "\n").utf8))
        }
        return ProcessIOBox(
            pid: spawnedPID,
            stdout: stdout,
            stderr: stderr,
            childInOwnGroup: verification.inOwnGroup
        )
    }

    public func ask(agentName: String, question: String) async throws -> String {
        try await callTool(agentName: agentName, name: "ask", arguments: ["question": question])
    }

    public func status(agentName: String) async throws -> String {
        try await callTool(agentName: agentName, name: "status", arguments: [:])
    }

    /// Runs `body`, retrying it exactly once if it throws `.emptyResult` AND the
    /// optional `canRetry` guard permits it.
    ///
    /// Reasoning-model bosses intermittently spend their token budget on
    /// reasoning and emit empty final content; the `ouro` runtime then returns
    /// `(empty response)` and `ask` throws `.emptyResult`. A single fresh retry
    /// almost always yields a real answer, so a transient empty no longer fails
    /// the check-in (and trips backoff). ONLY `.emptyResult` is retried — real
    /// failures (process unavailable, RPC/tool error, timeout, malformed) fall
    /// straight through so a genuinely-down boss still surfaces and backs off.
    ///
    /// `canRetry` lets the caller veto the retry when the first (empty) turn had
    /// observable side effects — e.g. it already enqueued Workbench actions via
    /// the boss's MCP tools. Re-running `body` would queue those actions a second
    /// time, so on a side-effecting empty turn we surface the empty instead of
    /// retrying. Defaults to always-retry to preserve the original behaviour for
    /// callers with no side effects to protect.
    public static func retryingOnEmpty(
        canRetry: @Sendable () -> Bool = { true },
        _ body: sending () async throws -> String
    ) async throws -> String {
        do {
            return try await body()
        } catch BossAgentMCPClientError.emptyResult {
            guard canRetry() else {
                throw BossAgentMCPClientError.emptyResult
            }
            return try await body()
        }
    }

    /// Probe the live boss `mcp-serve` process for the tool names it actually advertises
    /// (#F9). Spawns `ouro` with the IDENTICAL `mcpServeArguments` as `callTool` (so
    /// `--workbench-mcp` is passed the same way), writes `initialize` (id 1) then
    /// `tools/list` (id 2), reads the id-2 line, and parses it via the pure
    /// `WorkbenchToolsInjectionProbe.toolNames` seam. An `alpha.660+` runtime injects the
    /// `workbench_*` catalog into that list; an old runtime returns only boss-native tools
    /// (the silent-strip). Errors/timeouts surface exactly like `callTool` so a hung or
    /// unstartable runtime is observable rather than read as a green empty list.
    public func listToolNames(agentName: String) async throws -> [String] {
        let spawned = try spawnMCPServe(agentName: agentName)
        let processBox = spawned.box
        let stdinWrite = spawned.stdinWrite

        do {
            try writeLine(initializeRequest(id: 1), to: stdinWrite)
            try writeLine(Self.toolsListRequest(id: 2), to: stdinWrite)
            let line = try await readResponseLine(processBox, id: 2, timeoutNanoseconds: timeoutNanoseconds)
            try? stdinWrite.close()
            await stop(processBox)
            return WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line)
        } catch {
            try? stdinWrite.close()
            await stop(processBox)
            throw error
        }
    }

    public func callTool(agentName: String, name: String, arguments: [String: String]) async throws -> String {
        let spawned = try spawnMCPServe(agentName: agentName)
        let processBox = spawned.box
        let stdinWrite = spawned.stdinWrite

        do {
            try writeLine(
                initializeRequest(id: 1),
                to: stdinWrite
            )
            try writeLine(
                toolCallRequest(id: 2, name: name, arguments: arguments),
                to: stdinWrite
            )
            let response = try await readResponse(processBox, id: 2, timeoutNanoseconds: timeoutNanoseconds)
            try? stdinWrite.close()
            await stop(processBox)
            return response
        } catch {
            try? stdinWrite.close()
            await stop(processBox)
            throw error
        }
    }

    public static func extractText(fromOutput output: String, id: Int) throws -> String {
        for line in output.split(separator: "\n").map(String.init) {
            if let text = try extractTextIfMatching(line: line, id: id) {
                return text
            }
        }
        throw BossAgentMCPClientError.malformedResponse
    }

    public static func extractText(fromJSONLine line: String) throws -> String {
        let data = Data(line.utf8)
        let response = try JSONDecoder().decode(MCPResponse.self, from: data)
        return try extractText(from: response)
    }

    private static func extractText(from response: MCPResponse) throws -> String {
        if let error = response.error {
            throw BossAgentMCPClientError.rpcError(error.message)
        }
        guard let result = response.result else {
            throw BossAgentMCPClientError.malformedResponse
        }
        let text = result.content.map(\.text).joined(separator: "\n")
        if result.isError {
            throw BossAgentMCPClientError.toolError(text)
        }
        if isEmptyOrNonAnswer(text) {
            throw BossAgentMCPClientError.emptyResult
        }
        return text
    }

    /// True for a blank reply or a known runtime "no answer" sentinel (the
    /// `ouro` runtime emits `(empty response)` when the agent produced nothing).
    static func isEmptyOrNonAnswer(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return true
        }
        return normalized == "(empty response)"
            || normalized == "(no response)"
            || normalized == "(no output)"
    }

    private func readResponse(_ processBox: ProcessIOBox, id: Int, timeoutNanoseconds: UInt64) async throws -> String {
        // FIX 2 (no-park): the read carries its OWN poll deadline so it can never park past the
        // timeout even when the SIGKILL fails to close stdout (a grandchild escaped the killpg'd
        // group still holds it). A small margin past the watchdog keeps the watchdog (which kills
        // the child → EOF → the read returns naturally) the normal winner; the read's deadline is
        // the backstop only for the genuinely-wedged case.
        let readDeadline = DispatchTime.now() + .nanoseconds(Int(min(timeoutNanoseconds + 250_000_000, UInt64(Int.max))))
        return try await withThrowingTaskGroup(of: String.self) { group in
            // Cancel the sibling on every exit path, including the timeout
            // rethrow. The timeout task force-kills the subprocess so the
            // *uncancellable* blocking read always unwinds (EOF on closed stdout)
            // — terminate() alone deadlocks the group when the child ignores SIGTERM.
            defer { group.cancelAll() }
            group.addTask {
                try processBox.readResponse(id: id, deadline: readDeadline)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                processBox.terminate()
                processBox.forceKill()
                throw BossAgentMCPClientError.timeout
            }
            return try await firstTaskResult(of: &group, orThrow: BossAgentMCPClientError.closed)
        }
    }

    /// Like `readResponse` but returns the matching id line VERBATIM (no tool-result
    /// decode), for `tools/list` — whose `result.tools` shape the private `MCPResponse`
    /// decoders don't model. The pure seam parses the raw line.
    private func readResponseLine(_ processBox: ProcessIOBox, id: Int, timeoutNanoseconds: UInt64) async throws -> String {
        // FIX 2 (no-park): same own-deadline backstop as `readResponse` (see there).
        let readDeadline = DispatchTime.now() + .nanoseconds(Int(min(timeoutNanoseconds + 250_000_000, UInt64(Int.max))))
        return try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try processBox.readRawLine(id: id, deadline: readDeadline)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                processBox.terminate()
                processBox.forceKill()
                throw BossAgentMCPClientError.timeout
            }
            return try await firstTaskResult(of: &group, orThrow: BossAgentMCPClientError.closed)
        }
    }

    private func stop(_ processBox: ProcessIOBox) async {
        processBox.terminate()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // forceKill (escalate past grace) THEN reap — `stop()` does both. Without the reap the
        // raw-`posix_spawn` mcp-serve child becomes a `<defunct>` zombie that persists for
        // Workbench's whole lifetime; every callTool/listToolNames turn would leak one.
        processBox.stop()
    }

    private func writeLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    private func initializeRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [:],
        ]
    }

    /// The `tools/list` JSON-RPC request — sibling of `toolCallRequest`. Takes no params.
    /// Static + public so the spawn site and the source-pin test agree on the exact body.
    public static func toolsListRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ]
    }

    private func toolCallRequest(id: Int, name: String, arguments: [String: String]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
    }

    static func extractTextIfMatching(line: String, id: Int) throws -> String? {
        let data = Data(line.utf8)
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            responseID(raw["id"], matches: id)
        else {
            return nil
        }
        return try extractText(fromJSONLine: line)
    }

    /// Returns the line verbatim iff it's a JSON object whose `id` matches — used by the
    /// `tools/list` probe, which keeps the raw line for the pure-seam parse rather than
    /// decoding tool-call content. Non-JSON / id-mismatch ⇒ `nil` (keep scanning).
    static func rawLineIfMatching(line: String, id: Int) -> String? {
        let data = Data(line.utf8)
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            responseID(raw["id"], matches: id)
        else {
            return nil
        }
        return line
    }

    private static func responseID(_ rawID: Any?, matches expectedID: Int) -> Bool {
        if let id = rawID as? Int {
            return id == expectedID
        }
        if let id = rawID as? String {
            return id == String(expectedID)
        }
        return false
    }
}

private struct MCPResponse: Decodable {
    var result: MCPToolResult?
    var error: MCPClientResponseError?
}

/// The `error` object a remote MCP server returns in a JSON-RPC response, as the
/// boss MCP *client* decodes it. Distinct from the server-side `MCPError`
/// protocol-error vocabulary (F10a) — this is purely a wire-decode shape.
private struct MCPClientResponseError: Decodable {
    var message: String
}

private struct MCPToolResult: Decodable {
    var content: [MCPTextContent]
    var isError: Bool
}

private struct MCPTextContent: Decodable {
    var text: String
}

/// Holds the live mcp-serve child for one `callTool` / `listToolNames` turn: the raw pid,
/// the stdout/stderr pipe read handles, and the kill/liveness seams. It no longer wraps a
/// `Process` — the child is spawned by `SpawnInOwnGroup` (own process group, pgid == pid), so
/// `forceKill()` can `killpg(pid, SIGKILL)` to reap the boss's `node` grandchildren as a unit
/// (the F8b leak fix) instead of orphaning them with a child-only `kill`.
///
/// `childInOwnGroup` is the load-bearing single-flag invariant: it is `true` ONLY when the
/// spawn site verified `getpgid(pid) == pid` after `SpawnInOwnGroup.spawn`. The escalation
/// policy (`WatchdogEscalation.nextSignal`) returns `.killGroup` IFF that flag is set, so
/// `killpg` can never fire for a child that isn't provably in its own group (fail-closed).
final class ProcessIOBox: @unchecked Sendable {
    private let pid: pid_t
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let childInOwnGroup: Bool
    /// Grace window fed to the escalation policy. `forceKill()` represents the post-grace
    /// decision (the caller already sent SIGTERM and waited), so it queries `nextSignal` at
    /// `elapsedSinceDeadline == graceSeconds` to land on the SIGKILL arm.
    private let graceSeconds: Double
    private let isAlive: @Sendable (pid_t) -> Bool
    private let processKiller: @Sendable (pid_t, Int32) -> Int32
    private let groupKiller: @Sendable (pid_t, Int32) -> Int32
    /// The child-reaping seam. F8b dropped Foundation's `Process` for raw `posix_spawn`, which
    /// also dropped the implicit per-pid child-reaping `Process` did (a `DISPATCH_SOURCE_TYPE_PROC`
    /// watcher that `waitpid`s on exit). Without it, a raw-`posix_spawn` mcp-serve child that exits
    /// becomes a `STAT Z <defunct>` zombie — and EVERY `callTool`/`listToolNames` turn leaks one,
    /// accumulating unbounded until `posix_spawn` fails `EAGAIN`. `stop()` reaps the child through
    /// this seam on every lifecycle end. Default is a blocking `waitpid`; a fake records the call.
    private let reaper: @Sendable (pid_t) -> Void

    init(
        pid: pid_t,
        stdout: FileHandle,
        stderr: FileHandle,
        childInOwnGroup: Bool,
        graceSeconds: Double = 2.0,
        isAlive: @escaping @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 },
        processKiller: @escaping @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) },
        groupKiller: @escaping @Sendable (pid_t, Int32) -> Int32 = { killpg($0, $1) },
        reaper: @escaping @Sendable (pid_t) -> Void = { var status: Int32 = 0; waitpid($0, &status, 0) }
    ) {
        self.pid = pid
        self.stdout = stdout
        self.stderr = stderr
        self.childInOwnGroup = childInOwnGroup
        self.graceSeconds = graceSeconds
        self.isAlive = isAlive
        self.processKiller = processKiller
        self.groupKiller = groupKiller
        self.reaper = reaper
    }

    /// Decode the tool-call text from the matching id line (`tools/call`). `deadline` is the wall
    /// clock past which the read abandons (FIX 2) instead of parking; `nil` reads with no deadline
    /// (the original blocking behaviour, kept for tests that drive the loop directly).
    func readResponse(id: Int, deadline: DispatchTime? = nil) throws -> String {
        try readMatchingLine(deadline: deadline) { line in
            try BossAgentMCPClient.extractTextIfMatching(line: line, id: id)
        }
    }

    /// Return the matching id line VERBATIM (for `tools/list`, whose `result.tools` shape the
    /// tool-call decoders don't model). Same EOF / stderr / closed semantics as `readResponse`.
    func readRawLine(id: Int, deadline: DispatchTime? = nil) throws -> String {
        try readMatchingLine(deadline: deadline) { line in
            BossAgentMCPClient.rawLineIfMatching(line: line, id: id)
        }
    }

    /// Shared line reader: pull stdout chunks, split on newlines, and return the first line for
    /// which `transform` yields non-nil. Handles a final line with no trailing newline at EOF,
    /// surfaces stderr as `.processNotAvailable`, and reports `.closed` on a clean EOF with no
    /// match. Both `readResponse` (decode tool text) and `readRawLine` (keep the line) flow
    /// through here so there's a single read loop.
    ///
    /// FIX 2 (no-park): each blocking `availableData` is gated by `waitReadable`, a `poll(2)` on the
    /// stdout fd with the time remaining until `deadline`. A WELL-BEHAVED child is readable
    /// immediately, so `poll` returns at once and `availableData` runs exactly as before (happy path
    /// byte-identical). A PATHOLOGICAL child that writes nothing and never closes its write end (e.g.
    /// a grandchild that escaped the watchdog's killpg'd group still holds stdout) would otherwise
    /// park `availableData` forever PAST the SIGKILL — `poll` instead returns `.timedOut` at the
    /// deadline and we throw `.timeout`, so the worker is never parked. We deliberately do NOT close
    /// the fd to unblock: `FileHandle.availableData` raises `NSFileHandleOperationException`
    /// (aborting the process) when its fd is closed mid-read, so a bounded `poll` deadline is the
    /// safe unblock. `availableData` is only ever called after `poll` reports the fd readable (real
    /// data or EOF), never on a closed fd.
    private func readMatchingLine(deadline: DispatchTime?, _ transform: (String) throws -> String?) throws -> String {
        var buffer = Data()
        while true {
            switch waitReadable(fd: stdout.fileDescriptor, deadline: deadline) {
            case .timedOut:
                throw BossAgentMCPClientError.timeout
            case .readable:
                break
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    if let matched = try transform(line) {
                        return matched
                    }
                }
                let stderrText = readStderrText()
                if !stderrText.isEmpty {
                    throw BossAgentMCPClientError.processNotAvailable(stderrText)
                }
                throw BossAgentMCPClientError.closed
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                let line = String(decoding: lineData, as: UTF8.self)
                if let matched = try transform(line) {
                    return matched
                }
            }
        }
    }

    enum ReadableWait: Equatable { case readable, timedOut }

    /// Block until `fd` is readable (data available OR EOF/error → `availableData` will then return
    /// promptly without parking) or `deadline` passes. A `nil` deadline blocks indefinitely (the
    /// original behaviour). `poll(2)` reports `POLLIN`/`POLLHUP`/`POLLERR`/`POLLNVAL` as readable so
    /// a closed or EOF'd pipe never parks here; only a child that is silent AND holds its write end
    /// open consumes the full deadline. `EINTR` retries with the recomputed remaining budget.
    func waitReadable(fd: Int32, deadline: DispatchTime?) -> ReadableWait {
        while true {
            let timeoutMillis: Int32
            if let deadline {
                let remainingNanos = Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                if remainingNanos <= 0 {
                    return .timedOut
                }
                // Round up to the next millisecond so a sub-ms remainder still gets one poll pass.
                timeoutMillis = Int32(min((remainingNanos + 999_999) / 1_000_000, Int64(Int32.max)))
            } else {
                timeoutMillis = -1 // block indefinitely
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pollFD, 1, timeoutMillis)
            if rc > 0 {
                return .readable // POLLIN or POLLHUP/POLLERR/POLLNVAL — availableData returns at once
            }
            if rc == 0 {
                return .timedOut
            }
            if errno == EINTR {
                continue // interrupted before the deadline — retry with the recomputed remaining budget
            }
            // Any other poll error (should not happen for a valid pipe fd): treat as readable so the
            // existing `availableData`/EOF path classifies it, rather than spinning here.
            return .readable
        }
    }

    /// SIGTERM the child (the polite first ask). Skipped if the child already exited, so a
    /// reaped/recycled pid is never signalled.
    func terminate() {
        guard isAlive(pid) else {
            return
        }
        _ = processKiller(pid, SIGTERM)
    }

    /// Escalate past grace. Routes through the pure escalation policy: an own-group child →
    /// `.killGroup` → `killpg(pid, SIGKILL)` (reaps the boss's `node` grandchild tree); a child
    /// NOT provably in its own group → `.killChild` → `kill(pid, SIGKILL)` (child-only, the
    /// fail-closed safe default — never killpg a shared group). Skipped if already reaped.
    func forceKill() {
        guard isAlive(pid) else {
            return
        }
        let signal = WatchdogEscalation.nextSignal(
            elapsedSinceDeadline: graceSeconds,
            graceSeconds: graceSeconds,
            childInOwnGroup: childInOwnGroup
        )
        switch signal {
        case .killGroup:
            _ = groupKiller(pid, SIGKILL)
        default:
            _ = processKiller(pid, SIGKILL)
        }
    }

    /// Single always-run cleanup for the spawned child — the F8b zombie-leak fix. Called on EVERY
    /// `ProcessIOBox` lifecycle end (normal completion, timeout, error), it (a) ensures the child is
    /// dead (`forceKill` SIGKILLs it if still alive — a no-op once the read loop's EOF means it
    /// already exited) and then (b) reaps it via the `reaper` seam so it can't linger as a
    /// `<defunct>` zombie.
    ///
    /// NO-HANG GUARANTEE: the `waitpid` inside the default reaper blocks only until the child has
    /// exited, and by the time we call it the child is provably already dead — either the read loop
    /// hit EOF (the child exited on its own → `waitpid` reaps immediately) or `forceKill` just
    /// SIGKILLed it (the kernel tears it down promptly → `waitpid` returns at once). We deliberately
    /// do NOT use `WNOHANG`: a non-blocking poll could miss the child before the kernel has
    /// finished the teardown and skip the reap, re-leaking the zombie. The blocking wait is safe
    /// precisely because the child is guaranteed dead before it runs.
    func stop() {
        forceKill()
        reaper(pid)
        // FIX 1 (fd-leak): close the stdout/stderr READ pipe handles. The parent kept these read
        // ends for the whole turn (the read loop drains stdout; the EOF path drains stderr); nothing
        // closed them, so each callTool/listToolNames turn leaked two fds — over hours of
        // boss-watch polling that exhausts RLIMIT_NOFILE and the app can no longer spawn or open
        // pipes. Closed here, AFTER the read has completed (stop() runs once the read loop has
        // returned/thrown) and after the reap, on EVERY lifecycle end (success, timeout, error).
        closeReadHandles()
    }

    /// Whether `closeReadHandles()` has already run (so it fires AT MOST once — both the watchdog
    /// and `stop()` may call it for one turn). Guarded by `readCloseLock`.
    private let readCloseLock = NSLock()
    private var didCloseReadHandles = false

    /// Close the stdout/stderr READ pipe handles this box owns, exactly once.
    ///
    /// Two callers, two reasons:
    ///   - `stop()` (FIX 1, fd-leak): on every normal lifecycle end, release the two read fds the
    ///     box held for the whole turn so they don't accumulate to RLIMIT_NOFILE.
    ///   - the watchdog (FIX 2, no-park): when the response read is PARKED on `availableData` and the
    ///     SIGKILL can't close the write end (a grandchild escaped the killpg'd group still holds it),
    ///     closing the parent's READ fd is the only thing that unblocks the read so the worker isn't
    ///     parked past the watchdog deadline.
    ///
    /// IMPLEMENTATION: the unblock uses a RAW `Darwin.close(fileDescriptor)` — NOT `FileHandle.close()`.
    /// `FileHandle.close()` raises `NSFileHandleOperationException` (aborting the process) when called
    /// on a handle whose `availableData` is parked mid-read; the raw `close(2)` makes the in-flight
    /// `read(2)` return EOF cleanly with no exception (verified). The box's read handles are
    /// `closeOnDealloc: false` and own these exact fds (dup'd from the pipes at spawn), so this single
    /// raw close is the one-and-only close — no deinit double-close, no recycled-fd clobber. The
    /// idempotent flag makes repeated calls a no-op, so `stop()` after the watchdog already closed
    /// (or vice versa) is harmless.
    func closeReadHandles() {
        readCloseLock.lock()
        if didCloseReadHandles {
            readCloseLock.unlock()
            return
        }
        didCloseReadHandles = true
        readCloseLock.unlock()

        _ = Darwin.close(stdout.fileDescriptor)
        _ = Darwin.close(stderr.fileDescriptor)
    }

    private func readStderrText() -> String {
        let data = stderr.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
