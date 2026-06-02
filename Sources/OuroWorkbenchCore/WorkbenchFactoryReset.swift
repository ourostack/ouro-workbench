import Foundation

/// The *data* half of "Reset to Factory Defaults", split out from the app's
/// view model so it can be unit-tested against a real temp directory + a real
/// `UserDefaults` suite — no process teardown, no UI, no `NSApp.terminate`.
///
/// The view model still owns the process-level steps (stop running terminals,
/// quit their `screen` sessions, relaunch + terminate); those aren't this
/// type's concern. Crucially, neither half touches an agent's *session
/// history* — that lives with the agent's own harness (Claude / Codex / cmux),
/// never inside Workbench — so a factory reset is non-destructive to your work.
public enum WorkbenchFactoryReset {
    /// Back up the workspace state file to a timestamped sibling and remove it,
    /// then clear **all** Workbench preferences by removing the whole
    /// preference domain.
    ///
    /// - Returns: the backup URL when a state file was present and moved aside;
    ///   `nil` when there was no state file to back up (preferences are still
    ///   cleared either way).
    @discardableResult
    public static func wipeData(
        stateURL: URL,
        defaults: UserDefaults,
        defaultsDomain: String,
        timestamp: Date,
        fileManager: FileManager = .default
    ) -> URL? {
        var backupURL: URL?
        if fileManager.fileExists(atPath: stateURL.path) {
            let suffix = String(Int(timestamp.timeIntervalSince1970))
            let candidate = stateURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state.\(suffix).bak.json")
            // Defensive: a same-second double-reset shouldn't fail the move.
            try? fileManager.removeItem(at: candidate)
            do {
                try fileManager.moveItem(at: stateURL, to: candidate)
                backupURL = candidate
            } catch {
                // Couldn't move it aside — fall back to removing it so the next
                // launch still bootstraps fresh (the whole point of the reset).
                try? fileManager.removeItem(at: stateURL)
            }
        }
        // A true factory state: font, theme, menubar, recents, onboarding +
        // one-time migration flags — everything — falls back to the registered
        // defaults on next launch.
        defaults.removePersistentDomain(forName: defaultsDomain)
        return backupURL
    }
}
