import Foundation

/// The single shared derivation of "what is recoverable right now" (U8b).
///
/// Before this type, the post-reboot recovery count was computed three
/// different ways: `oneLineStatus` counted `.autoResume`/`.respawn`/
/// `.manualActionNeeded` (excluding `.reattach`), `recoverableEntries` counted
/// `.reattach`/`.autoResume`/`.respawn` (excluding `.manualActionNeeded`), and
/// the row help re-counted yet again. So a workspace of only live reattaches
/// could read "0 recovery actions" next to a tooltip "N waiting" over a sheet
/// listing N rows.
///
/// `RecoveryDigest` projects the planner's `[RecoveryPlan]` ONCE. The sidebar
/// row text, its hover help, the sheet header, the sheet row count, and
/// `shouldShow` all read from this one value, so they can never disagree. It
/// also splits the actionable set into the three buckets the surfaces render
/// distinctly: lossless reattaches (no loss), auto-recoverable (resume/respawn),
/// and "needs you" (manual action). A lossless reattach is counted but framed
/// as a reconnect, never as an alarming "recovery action."
public struct RecoveryDigest: Equatable, Sendable {
    /// Every plan the surfaces treat as an actionable recovery row, in input
    /// order. Includes `.reattach` (counted, but lossless) and
    /// `.manualActionNeeded` (counted, surfaced under "Needs you"). Excludes the
    /// inert `.noAction`.
    public let actionablePlans: [RecoveryPlan]

    public init(plans: [RecoveryPlan]) {
        self.actionablePlans = plans.filter { plan in
            switch plan.action {
            case .reattach, .autoResume, .respawn, .manualActionNeeded:
                return true
            case .noAction:
                return false
            }
        }
    }

    public var actionableCount: Int { actionablePlans.count }
    public var shouldShow: Bool { actionableCount > 0 }

    public var actionableEntryIDs: [UUID] { actionablePlans.map(\.entryId) }

    /// Lossless reconnects — the success case of reboot recovery. Counted, but
    /// labelled distinctly so a reconnect is never an alarming "recovery action."
    public var reattachPlans: [RecoveryPlan] { actionablePlans.filter { $0.action == .reattach } }
    public var losslessReattachCount: Int { reattachPlans.count }
    public var reattachEntryIDs: [UUID] { reattachPlans.map(\.entryId) }

    /// Sessions Workbench can recover on its own (resume / respawn).
    public var autoRecoverablePlans: [RecoveryPlan] {
        actionablePlans.filter { $0.action == .autoResume || $0.action == .respawn }
    }
    public var autoRecoverableCount: Int { autoRecoverablePlans.count }
    public var autoRecoverableEntryIDs: [UUID] { autoRecoverablePlans.map(\.entryId) }

    /// Sessions that can't be auto-resumed and need the operator (manual action).
    public var needsYouPlans: [RecoveryPlan] { actionablePlans.filter { $0.action == .manualActionNeeded } }
    public var needsYouCount: Int { needsYouPlans.count }
    public var needsYouEntryIDs: [UUID] { needsYouPlans.map(\.entryId) }

    /// The plans that actually NEED action after a restart — auto-recoverable
    /// (resume / respawn) plus needs-you (manual), EXCLUDING the lossless
    /// `.reattach` survivors. A pure reconnect needs nothing done, so it doesn't
    /// belong in a "needs action" count. This is the single derivation the recovery
    /// drill's headline count (U39) and the boss-watch wake gate (U42) both read,
    /// so neither can drift from the rest of the surfaces.
    public var needsActionPlans: [RecoveryPlan] { autoRecoverablePlans + needsYouPlans }
    public var needsActionCount: Int { needsActionPlans.count }
    public var hasNeedsAction: Bool { needsActionCount > 0 }

    private func sessionWord(_ count: Int) -> String {
        "\(count) session\(count == 1 ? "" : "s")"
    }

    /// The one status sentence shown in the sidebar row and (as the subtitle)
    /// the sheet header. Counts EVERY actionable row, so it can never read "0"
    /// over a non-empty list. Frames lossless reattaches as reconnects and calls
    /// out "needs you" sessions when present.
    public var statusLine: String {
        guard actionableCount > 0 else {
            return "Nothing to recover"
        }
        var clauses: [String] = []
        if losslessReattachCount > 0 {
            clauses.append("\(sessionWord(losslessReattachCount)) to reconnect — no loss")
        }
        if autoRecoverableCount > 0 {
            clauses.append("\(sessionWord(autoRecoverableCount)) to recover")
        }
        if needsYouCount > 0 {
            clauses.append("\(sessionWord(needsYouCount)) need\(needsYouCount == 1 ? "s" : "") you")
        }
        return clauses.joined(separator: ", ")
    }

    /// Hover help for the sidebar row. Same count as the status line and the
    /// sheet, by construction.
    public var helpText: String {
        guard actionableCount > 0 else {
            return "Nothing is waiting on recovery."
        }
        return "\(sessionWord(actionableCount)) after restart. Click to inspect."
    }

    /// The sheet header subtitle. Same single count as everything else.
    public var sheetHeader: String { statusLine }
}

/// The boss-actionable recovery breakdown (#U28): the same `[RecoveryPlan]`
/// source the operator surfaces and `RecoveryDigest` read, split by HOW the boss
/// may act on each session after a restart — `reattach` (lossless reconnect,
/// always safe for the boss to self-trigger), `resume` (auto-resume, safe),
/// `respawn` (re-runs a command — side-effectful, but still a boss self-trigger),
/// and `needsHuman` (manual action the boss literally cannot perform — escalate).
///
/// This replaces the two boss-facing text scalars that didn't reflect the
/// classification the product already computes: `workbench_visibility`'s raw
/// `recoverable=N` (counted `.needsRecovery` BEFORE the plan, lumping all three
/// classes together and inflating what the boss thinks it can act on) and the
/// `workbench_sense` pulse. Both now read this, so a bare "recoverable=3" becomes
/// "reattach=1 auto_resume=1 respawn=0 needs_human=1" — the boss knows what it may
/// self-execute vs surface to the operator. The four buckets sum to the digest's
/// actionable total (the inert `.noAction` is excluded), and a reattach-only set
/// never reads as needs-human.
public struct RecoveryBreakdown: Equatable, Sendable {
    /// Lossless reconnects — always safe for the boss to self-trigger.
    public let reattach: Int
    /// Auto-resume — safe boss self-trigger.
    public let resume: Int
    /// Respawn — re-runs a command (side-effectful), but still a boss self-trigger.
    public let respawn: Int
    /// Manual action the boss cannot perform — must be surfaced to the operator.
    public let needsHuman: Int

    public init(plans: [RecoveryPlan]) {
        var reattach = 0, resume = 0, respawn = 0, needsHuman = 0
        for plan in plans {
            switch plan.action {
            case .reattach: reattach += 1
            case .autoResume: resume += 1
            case .respawn: respawn += 1
            case .manualActionNeeded: needsHuman += 1
            case .noAction: break
            }
        }
        self.reattach = reattach
        self.resume = resume
        self.respawn = respawn
        self.needsHuman = needsHuman
    }

    /// Every actionable plan (matches `RecoveryDigest.actionableCount`).
    public var total: Int { reattach + resume + respawn + needsHuman }

    /// What the boss may self-execute via `request_action` — everything except the
    /// human-only manual recoveries.
    public var bossActionable: Int { reattach + resume + respawn }

    /// The boss-facing text scalar: `reattach=N auto_resume=N respawn=N needs_human=N`,
    /// so the boss knows which class it may trigger and which it must escalate —
    /// replacing the old single `recoverable=N`.
    public var scalarText: String {
        "reattach=\(reattach) auto_resume=\(resume) respawn=\(respawn) needs_human=\(needsHuman)"
    }

    /// The boss-relayable class string for one `RecoveryAction` — the same
    /// vocabulary the breakdown uses — so a logged boss recover action records
    /// which class it acted on (the operator's audit, #U28). `nil` for the inert
    /// `.noAction` (nothing to record).
    public static func bossActionClass(for action: RecoveryAction) -> String? {
        switch action {
        case .reattach: return "reattach"
        case .autoResume: return "auto_resume"
        case .respawn: return "respawn"
        case .manualActionNeeded: return "needs_human"
        case .noAction: return nil
        }
    }
}
