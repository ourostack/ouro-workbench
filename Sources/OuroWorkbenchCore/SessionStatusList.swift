import Foundation

/// The boss-forward status buckets. A session is classified into exactly one of
/// these from its attention state + the status of its most-recent run, so the
/// operator can read "what's running / what's waiting on me / what's settled"
/// at a glance instead of scanning raw terminals.
public enum SessionStatusBucket: String, Codable, Sendable, CaseIterable {
    /// The session is actively working and is not asking for the operator.
    case running
    /// The session needs the operator: it's parked at a prompt, the boss flagged
    /// it for review, it's blocked, or its run died and needs a recovery call.
    case waitingOnYou
    /// The session is settled — it exited, or it's configured/idle and has no
    /// live or waiting work. Nothing for the operator to do right now.
    case done
}

/// One row in the boss-forward status list. A flat, render-ready view of a
/// single non-archived session: which bucket it's in plus the salient fields a
/// status row shows. Pure value type; the App view binds straight to it.
public struct SessionStatusRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String?
    public var owner: SessionOwner
    public var bucket: SessionStatusBucket
    /// Raw status of the most-recent run, or `.configured` when the session has
    /// never run.
    public var status: ProcessStatus
    /// The session's attention state (drives `needsHuman`).
    public var attention: AttentionState
    /// Whether this session needs the operator — mirrors `AttentionState.needsHuman`.
    public var needsHuman: Bool
    public var workingDirectory: String
    public var pid: Int?
    public var exitCode: Int?
    public var startedAt: Date?
    public var lastOutputAt: Date?

    public init(
        id: UUID,
        name: String,
        group: String?,
        owner: SessionOwner,
        bucket: SessionStatusBucket,
        status: ProcessStatus,
        attention: AttentionState,
        needsHuman: Bool,
        workingDirectory: String,
        pid: Int? = nil,
        exitCode: Int? = nil,
        startedAt: Date? = nil,
        lastOutputAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.owner = owner
        self.bucket = bucket
        self.status = status
        self.attention = attention
        self.needsHuman = needsHuman
        self.workingDirectory = workingDirectory
        self.pid = pid
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.lastOutputAt = lastOutputAt
    }
}

/// A pure projection of a `WorkspaceState` into the three boss-forward buckets.
///
/// Classification (precedence top-down, total — every non-archived session lands
/// in exactly one bucket):
/// 1. **waitingOnYou** when the entry's `AttentionState.needsHuman` is true
///    (`waitingOnHuman` / `needsBossReview` / `blocked`), OR the most-recent run
///    is parked at a prompt (`.waitingForInput`) or died needing a human call
///    (`.needsRecovery` / `.manualActionNeeded`). The operator's turn always
///    wins over "running" so an asking session is never buried.
/// 2. **running** when the most-recent run is `.running` (and it's not waiting).
/// 3. **done** otherwise — the run `.exited`, or the session is `.configured` /
///    has never run. Settled; nothing for the operator to do right now.
///
/// Within each bucket, rows are sorted freshest-first by `lastOutputAt` then
/// `startedAt`, falling back to a case-insensitive name compare (id-tiebroken)
/// so the list order is deterministic between renders. No I/O — unit-testable
/// and reusable by the App's status list. `AttentionState.needsHuman` and
/// `ProcessRun.isMoreRecent` are reused so the buckets agree with the rest of
/// the workbench.
public struct SessionStatusList: Equatable, Sendable {
    public var running: [SessionStatusRow]
    public var waitingOnYou: [SessionStatusRow]
    public var done: [SessionStatusRow]

    public init(
        running: [SessionStatusRow] = [],
        waitingOnYou: [SessionStatusRow] = [],
        done: [SessionStatusRow] = []
    ) {
        self.running = running
        self.waitingOnYou = waitingOnYou
        self.done = done
    }

    /// All rows, attention-ordered: waiting-on-you first (the operator's queue),
    /// then running, then done. Each bucket keeps its own freshest-first order.
    public var all: [SessionStatusRow] {
        waitingOnYou + running + done
    }

    public var runningCount: Int { running.count }
    public var waitingOnYouCount: Int { waitingOnYou.count }
    public var doneCount: Int { done.count }
    public var isEmpty: Bool {
        running.isEmpty && waitingOnYou.isEmpty && done.isEmpty
    }

    /// Project a workspace state into the three buckets.
    ///
    /// - Parameters:
    ///   - state: the workspace state to classify.
    ///   - includeArchived: when false (default) archived sessions are omitted,
    ///     matching the sidebar/snapshot default.
    public static func make(
        from state: WorkspaceState,
        includeArchived: Bool = false
    ) -> SessionStatusList {
        let runsByEntry = Dictionary(grouping: state.processRuns, by: { $0.entryId })
        let groupNamesById = Dictionary(
            state.projects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var running: [SessionStatusRow] = []
        var waitingOnYou: [SessionStatusRow] = []
        var done: [SessionStatusRow] = []

        for entry in state.processEntries {
            if !includeArchived, entry.isArchived { continue }

            let latest = runsByEntry[entry.id]?.sorted(by: ProcessRun.isMoreRecent).first
            let status = latest?.status ?? .configured
            let bucket = classify(attention: entry.attention, runStatus: status)

            let row = SessionStatusRow(
                id: entry.id,
                name: entry.name,
                group: groupNamesById[entry.projectId],
                owner: entry.owner,
                bucket: bucket,
                status: status,
                attention: entry.attention,
                needsHuman: entry.attention.needsHuman,
                workingDirectory: entry.workingDirectory,
                pid: latest?.pid.map { Int($0) },
                exitCode: latest?.exitCode.map { Int($0) },
                startedAt: latest?.startedAt,
                lastOutputAt: latest?.lastOutputAt
            )

            switch bucket {
            case .running:
                running.append(row)
            case .waitingOnYou:
                waitingOnYou.append(row)
            case .done:
                done.append(row)
            }
        }

        return SessionStatusList(
            running: running.sorted(by: isFresher),
            waitingOnYou: waitingOnYou.sorted(by: isFresher),
            done: done.sorted(by: isFresher)
        )
    }

    /// Pure classification of one session from its attention + latest run status.
    static func classify(attention: AttentionState, runStatus: ProcessStatus) -> SessionStatusBucket {
        if attention.needsHuman { return .waitingOnYou }
        switch runStatus {
        case .waitingForInput, .needsRecovery, .manualActionNeeded:
            return .waitingOnYou
        case .running:
            return .running
        case .exited, .configured:
            return .done
        }
    }

    /// Freshest-first within a bucket: newer `lastOutputAt` wins, then newer
    /// `startedAt`, then case-insensitive name, then id — fully deterministic.
    /// A row with a timestamp always sorts ahead of one without.
    ///
    /// Implemented as a lexicographic compare over a per-row sort key so the
    /// ordering is one expression with no awkward early-return branches:
    /// `(−lastOutput, −startedAt, lowercased-name, id)`, where a missing date
    /// becomes the oldest-possible sentinel (so present-and-newer floats up).
    static func isFresher(_ lhs: SessionStatusRow, _ rhs: SessionStatusRow) -> Bool {
        sortKey(for: lhs) < sortKey(for: rhs)
    }

    /// The freshest-first sort key for a row. Negating the timestamps makes a
    /// LARGER (newer) date sort FIRST under ascending `<`; a missing timestamp
    /// maps to `.greatestFiniteMagnitude` so it sorts LAST (after every real
    /// timestamp), matching "a row with a timestamp always sorts ahead of one
    /// without". Name is lowercased for case-insensitive ordering; id is the
    /// total-order tiebreak.
    static func sortKey(for row: SessionStatusRow) -> SortKey {
        SortKey(
            negatedLastOutput: negatedSince1970(row.lastOutputAt),
            negatedStarted: negatedSince1970(row.startedAt),
            lowercasedName: row.name.lowercased(),
            id: row.id.uuidString
        )
    }

    /// `-date.timeIntervalSince1970` for a present date (newer → more negative →
    /// sorts first); `.greatestFiniteMagnitude` for a missing date (sorts last).
    static func negatedSince1970(_ date: Date?) -> Double {
        guard let date else { return .greatestFiniteMagnitude }
        return -date.timeIntervalSince1970
    }

    /// Lexicographic sort key for `isFresher`. Conforms to `Comparable` via the
    /// synthesized tuple-style member-wise compare.
    struct SortKey: Comparable {
        var negatedLastOutput: Double
        var negatedStarted: Double
        var lowercasedName: String
        var id: String

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            (lhs.negatedLastOutput, lhs.negatedStarted, lhs.lowercasedName, lhs.id)
                < (rhs.negatedLastOutput, rhs.negatedStarted, rhs.lowercasedName, rhs.id)
        }
    }
}
