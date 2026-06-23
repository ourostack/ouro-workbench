import AppKit
import Foundation
import OuroWorkbenchCore

/// Downloads, verifies, and stages a release update, then swaps it into place
/// and relaunches. The download URLs come from the project's own GitHub release
/// (HTTPS), and every staged archive is checked against the release manifest's
/// SHA-256 + byte count, the running bundle identifier, and `codesign` before
/// anything is moved — the same trust chain the `curl | bash` installer uses.
/// What "Check for Updates…" should tell the user, driving a single
/// confirmation dialog from the More menu / ⌘K.
enum WorkbenchUpdatePrompt: Equatable {
    case installable(release: String)
    case upToDate(release: String)
    case failed(detail: String)

    var message: String {
        switch self {
        case let .installable(release):
            return "\(WorkbenchRelease.appName) \(release) is available. Install it now and relaunch? Your running terminals keep running across the update."
        case let .upToDate(release):
            return "You're on the latest release (\(release))."
        case let .failed(detail):
            return detail
        }
    }

    var isInstallable: Bool {
        if case .installable = self { return true }
        return false
    }
}

struct WorkbenchUpdateInstaller: Sendable {
    var bundleIdentifier: String
    var currentVersion: String
    var currentBuild: String?

    typealias Staged = WorkbenchUpdateStager.Staged
    typealias InstallError = WorkbenchUpdateStager.StageError

    /// Download + verify + expand + codesign-check. Throws on any failure;
    /// nothing on disk outside a fresh temp dir is touched here.
    func stage(
        plan: WorkbenchUpdatePlan,
        progress: @Sendable (String) async -> Void
    ) async throws -> Staged {
        let stager = WorkbenchUpdateStager(
            bundleIdentifier: bundleIdentifier,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            appName: WorkbenchRelease.appName,
            userAgent: WorkbenchRelease.userAgent(version: currentVersion)
        )
        return try await stager.stage(plan: plan, progress: progress)
    }

    /// Spawn a detached helper that waits for this process to exit, swaps the
    /// staged bundle over the running install (keeping a rollback copy until the
    /// move succeeds), refreshes Launch Services, and — when `relaunch` is true —
    /// reopens the app. The caller terminates immediately after.
    ///
    /// `relaunch: true` is the explicit "Install & Relaunch now" path.
    /// `relaunch: false` is the quiet "install on quit" path: the user already
    /// chose to quit, so the swap just lands and the *next* launch is the new
    /// version — no surprise reopen.
    static func applyAndRelaunch(staged: Staged, destinationBundle: URL, relaunch: Bool = true) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = destinationBundle.path
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        // On the relaunch path, a failed swap should still reopen the (unchanged)
        // app so the user isn't left with nothing; on the quit path, do nothing.
        let reopenOnFailure = relaunch ? "/usr/bin/open \"$DEST\"\n" : ""
        let reopenOnSuccess = relaunch ? "/usr/bin/open \"$DEST\"\n" : ""
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        DEST=\(shellQuoted(dest))
        STAGED=\(shellQuoted(staged.appURL.path))
        STAGING_ROOT=\(shellQuoted(staged.stagingRoot.path))
        /bin/rm -rf "$DEST.update-new" "$DEST.update-bak"
        if ! /usr/bin/ditto "$STAGED" "$DEST.update-new"; then
          \(reopenOnFailure)exit 1
        fi
        /bin/mv "$DEST" "$DEST.update-bak" 2>/dev/null
        if /bin/mv "$DEST.update-new" "$DEST"; then
          /bin/rm -rf "$DEST.update-bak"
        else
          /bin/mv "$DEST.update-bak" "$DEST" 2>/dev/null
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        \(shellQuoted(lsregister)) -f "$DEST" 2>/dev/null
        \(reopenOnSuccess)/bin/rm -rf "$STAGING_ROOT" 2>/dev/null
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    /// Quiet "install on quit": swap the staged bundle into place after this
    /// process exits, without reopening. The next launch is the new version.
    static func applyOnQuit(staged: Staged, destinationBundle: URL) {
        applyAndRelaunch(staged: staged, destinationBundle: destinationBundle, relaunch: false)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
