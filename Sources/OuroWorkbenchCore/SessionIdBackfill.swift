import Foundation

/// The F4 back-fill seam. `ProcessRun.terminalSessionId` has readers
/// (`WorkbenchCommandPlanner.nativeResumePlan`, `RecoveryPlanner`) but no writer:
/// `markStarted` builds the run the instant the PTY child reports its shell pid,
/// BEFORE the agent has written its native session file
/// (`~/.claude/projects/<dir>/<id>.jsonl`, `~/.copilot/session-state/<id>/`), so
/// the id provably doesn't exist yet. This seam back-fills it later: given the
/// live runs, their entries, and the latest `AgentSessionScanner` scan, it returns
/// the `runId → sessionId` writes to apply — matching a still-id-less RUNNING run
/// to a scanned recent record by harness + cwd, pinned to its own live process by
/// pid.
///
/// PURE and GENERAL: no FS, no `Process`, no agency/repo knowledge — the App layer
/// owns the scan + the guarded `if terminalSessionId == nil` assignment + `save()`.
///
/// Two hard invariants:
///   - never overwrite a non-empty id (a run that already has one is absent from
///     the returned map);
///   - never hand two distinct runs the same id. After `AgentSessionScanner.merge`
///     collapses two same-cwd recents into one record, a pure cwd match cannot
///     separate two live same-cwd sessions, so when more than one still-id-less
///     RUNNING run competes for the same `(harness, cwd)` the seam leaves them ALL
///     nil — the honest fallback to today's `--continue` / `resume --last`.
public enum SessionIdBackfill {
    /// Given live runs + their entries + the latest agent-session scan, return the
    /// `(runId → sessionId)` back-fills to apply.
    ///
    /// A run is a candidate only when ALL hold:
    ///   - `status == .running` (an archived / exited / needs-recovery run is not a
    ///     live thing to pin);
    ///   - `terminalSessionId` is nil/empty (no-clobber);
    ///   - it has a matching `ProcessEntry`;
    ///   - `TerminalAgentDetector.detect(entry:)` yields a known, non-`.custom`
    ///     harness (a custom harness has no native resume id);
    ///   - it has a `pid` that appears as a `running:true` record keyed
    ///     `"pid-<pid>"` with the same harness — this pins the run to its OWN live
    ///     process (the disambiguator the spec locked).
    ///
    /// A candidate back-fills only when it is the SOLE candidate for its
    /// `(harness, cwd)` and a `running:false` recent record with that harness + cwd
    /// carries a non-empty native sessionId.
    public static func sessionIdBackfills(
        runs: [ProcessRun],
        entries: [ProcessEntry],
        records: [AgentSessionRecord]
    ) -> [UUID: String] {
        var entriesById: [UUID: ProcessEntry] = [:]
        for entry in entries where entriesById[entry.id] == nil {
            entriesById[entry.id] = entry
        }

        // pid → harness raw values that have a live (running:true) record for that
        // pid. A run pins only when its (pid, harness) appears here.
        var liveHarnessByPid: [Int32: Set<String>] = [:]
        for record in records where record.running {
            guard let pid = pidValue(from: record.sessionId) else { continue }
            liveHarnessByPid[pid, default: []].insert(record.harness.rawValue)
        }

        // The candidate runs, each carried with its resolved harness raw + cwd.
        struct Candidate {
            let runId: UUID
            let harnessRaw: String
            let cwd: String
        }
        var candidates: [Candidate] = []
        for run in runs {
            guard run.status == .running else { continue }
            guard (run.terminalSessionId ?? "").isEmpty else { continue }
            guard let entry = entriesById[run.entryId] else { continue }
            guard let kind = TerminalAgentDetector.detect(entry: entry), kind != .custom else { continue }
            guard let pid = run.pid else { continue }
            guard liveHarnessByPid[pid]?.contains(kind.rawValue) == true else { continue }
            candidates.append(
                Candidate(runId: run.id, harnessRaw: kind.rawValue, cwd: entry.workingDirectory)
            )
        }

        // How many candidates compete for each (harness, cwd). More than one →
        // ambiguous → none of them back-fills (the same-cwd safety invariant).
        var countByKey: [String: Int] = [:]
        for candidate in candidates {
            countByKey[key(harness: candidate.harnessRaw, cwd: candidate.cwd), default: 0] += 1
        }

        // The native id available per (harness, cwd) from the recent records.
        var nativeIdByKey: [String: String] = [:]
        for record in records where !record.running && !record.sessionId.isEmpty {
            nativeIdByKey[key(harness: record.harness.rawValue, cwd: record.cwd)] = record.sessionId
        }

        var result: [UUID: String] = [:]
        for candidate in candidates {
            let k = key(harness: candidate.harnessRaw, cwd: candidate.cwd)
            guard countByKey[k] == 1, let nativeId = nativeIdByKey[k] else { continue }
            result[candidate.runId] = nativeId
        }
        return result
    }

    /// Extract the integer pid from a `discoverRunning` record's `"pid-<pid>"`
    /// sessionId. Returns nil for any other shape (a recent record's real id), so
    /// only true live-process records feed the pin set.
    private static func pidValue(from sessionId: String) -> Int32? {
        let prefix = "pid-"
        guard sessionId.hasPrefix(prefix) else { return nil }
        return Int32(sessionId.dropFirst(prefix.count))
    }

    /// Stable `(harness, cwd)` key. cwd is matched verbatim — the recent record's
    /// cwd is the agent's own reported cwd and the run's cwd is the entry's
    /// `workingDirectory`; both are absolute paths the producers write as-is.
    private static func key(harness: String, cwd: String) -> String {
        "\(harness)|\(cwd)"
    }
}
