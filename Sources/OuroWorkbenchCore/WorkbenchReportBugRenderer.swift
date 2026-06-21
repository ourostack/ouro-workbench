import Foundation

/// U30(b) — the `workbench_report_bug` MCP seam. Lets the boss capture a Workbench/session
/// defect into the SAME anonymized bug-report bundle a human would create, so a defect the
/// boss notices ("this session is wedged", "a recovery drill failed", "an MCP action didn't
/// apply") becomes an auditable, operator-visible artifact instead of vanishing into chat.
///
/// The bundle needs live app state (sessions, decisions, action log, screenshot), so the
/// tool ENQUEUES a `.reportBug` action the running app drains — the app builds the bundle
/// through `BugReportWriter` + `WorkbenchBugReportRedactor`, the exact redaction path the
/// in-app reporter uses (never a bypass). Filing-to-GitHub stays human-gated: this only
/// writes the local bundle; the operator files it from the existing card.
///
/// This seam single-sources the tool name + description (which states honestly what is and
/// isn't anonymized — text yes, screenshot no) and the enqueue acknowledgement shape, so
/// the MCP dispatch, the tool definition, and the boss-tools catalog can't drift.
public enum WorkbenchReportBugRenderer {
    /// The MCP tool name — single-sourced so dispatch + the tool definition can't drift.
    public static let toolName = "workbench_report_bug"

    /// The tool description the boss reads in `tools/list`. States the honest privacy note
    /// so the boss can relay it rather than implying the whole bundle is scrubbed.
    public static let toolDescription = """
        Capture a Workbench/session defect into the same anonymized bug-report bundle a human would create (#U30). Use this when YOU notice a defect — a session is wedged, a recovery drill failed, an MCP action didn't apply — so it becomes an auditable, operator-visible artifact instead of staying in chat. Pass `note` (the defect description). The bundle is built when the running app drains the request (it needs live state: sessions, decisions, the action log, a window screenshot), so this returns an enqueue ack — read the report back via the operator's Report a Bug card or a recent-reports read, not from this ack. PRIVACY (relay this honestly): the report TEXT is anonymized — usernames, home paths, agent names, and tokens are stripped before it's written. The window SCREENSHOT and the diagnostics zip are NOT anonymized (verbatim) and the diagnostics zip may include local paths; everything stays in a local bundle on the operator's Mac and nothing is uploaded automatically. The created bundle appears to the operator exactly like a human-created one (revealable in Finder, File-as-Issue available). Filing to GitHub stays human-gated.
        """

    /// The enqueue acknowledgement the boss reads back from `workbench_report_bug`.
    public struct Ack: Encodable, Equatable, Sendable {
        public let queued: Bool
        public let requestId: String
        public let message: String

        public init(queued: Bool, requestId: String, message: String) {
            self.queued = queued
            self.requestId = requestId
            self.message = message
        }
    }

    /// Build the ack for a queued report. The message tells the boss the bundle is built on
    /// the app's drain (not produced here) and how to read it back.
    public static func ack(requestId: String, note: String, source: String) -> Ack {
        let preview = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Ack(
            queued: true,
            requestId: requestId,
            message: "Queued bug report \"\(preview)\" as \(requestId). The running app builds the anonymized bundle when it drains the request; read it back from the operator's Report a Bug card or a recent-reports read."
        )
    }
}
