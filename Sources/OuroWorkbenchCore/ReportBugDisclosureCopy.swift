import Foundation

/// U16 — the in-app Report a Bug sheet's disclosure copy, told truthfully.
///
/// The OLD line listed the whole bundle ("Includes a window screenshot, a support diagnostics
/// zip…") then said "The report text is anonymized — usernames, home paths, agent names, and
/// tokens are stripped before it's saved or filed." But only `report.md` is redacted: the
/// screenshot is captured as raw window pixels (it can show home paths in titlebars/terminals,
/// real agent names, branch names, on-screen output) and the diagnostics zip is copied verbatim
/// with raw $HOME paths in its manifest. The bundle-scope framing invited the operator to assume
/// the WHOLE bundle was scrubbed — so the careful operator who read the disclosure was the one
/// most misled.
///
/// This corrected copy is precise about scope: the report TEXT is anonymized; the screenshot is a
/// literal picture of your window and is NOT; the diagnostics zip holds app logs/versions/
/// environment and may include local paths. It also states what's already true in code but was
/// invisible in the sheet — the screenshot and zip stay on your Mac and are never uploaded to the
/// GitHub issue (only `report.md` is the issue body). No claim implies the screenshot or zip is
/// scrubbed. Kept in pure Core so the truthful contract is unit-asserted and the SwiftUI sheet is
/// thin wiring over it.
public enum ReportBugDisclosureCopy {
    /// The single inline disclosure line shown under the note field in the Report a Bug sheet.
    public static let disclosure =
        "The report text (your note + the issue title) is anonymized — usernames, home paths, "
        + "agent names, and tokens are stripped before it's written. The window screenshot and the "
        + "diagnostics zip (app logs, versions, and environment, which may include local paths) are "
        + "included verbatim and are NOT anonymized — review the screenshot before sharing it. "
        + "Everything is written to a local folder on your Mac; nothing is sent anywhere "
        + "automatically, and the screenshot and zip are not uploaded when you file the report as a "
        + "GitHub issue (only the anonymized report text is)."
}
