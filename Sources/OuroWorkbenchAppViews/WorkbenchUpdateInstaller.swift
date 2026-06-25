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
    typealias HelperLauncher = @Sendable (_ executableURL: URL, _ arguments: [String]) throws -> Void

    enum ApplyLaunchResult: Equatable, Sendable {
        case launched
        case failedToLaunch(String)

        var errorMessage: String? {
            if case let .failedToLaunch(message) = self { return message }
            return nil
        }
    }

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
    @discardableResult
    static func applyAndRelaunch(
        staged: Staged,
        destinationBundle: URL,
        relaunch: Bool = true,
        helperLauncher: HelperLauncher = Self.launchHelper
    ) -> ApplyLaunchResult {
        let script = installScript(
            staged: staged,
            destinationBundle: destinationBundle,
            relaunch: relaunch
        )
        do {
            try helperLauncher(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
            return .launched
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failedToLaunch(message)
        }
    }

    static func installScript(
        staged: Staged,
        destinationBundle: URL,
        relaunch: Bool,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        statusURL: URL = Self.defaultInstallStatusURL(),
        dittoPath: String = "/usr/bin/ditto",
        movePath: String = "/bin/mv",
        launchServicesRegisterPath: String = Self.defaultLaunchServicesRegisterPath
    ) -> String {
        let dest = destinationBundle.path
        // On the relaunch path, a failed swap should still reopen the (unchanged)
        // app so the user isn't left with nothing; on the quit path, do nothing.
        let reopenOnFailure = relaunch ? "/usr/bin/open \"$DEST\"\n" : ""
        let reopenOnSuccess = relaunch ? "/usr/bin/open \"$DEST\"\n" : ""
        return """
        DEST=\(shellQuoted(dest))
        STAGED=\(shellQuoted(staged.appURL.path))
        STAGING_ROOT=\(shellQuoted(staged.stagingRoot.path))
        RELEASE=\(shellQuoted(staged.releaseLabel))
        STATUS=\(shellQuoted(statusURL.path))
        DITTO=\(shellQuoted(dittoPath))
        MOVE=\(shellQuoted(movePath))
        LSREGISTER=\(shellQuoted(launchServicesRegisterPath))
        write_status() {
          /bin/mkdir -p "$(/usr/bin/dirname "$STATUS")"
          {
            printf 'state=%s\\n' "$1"
            printf 'release=%s\\n' "$RELEASE"
            printf 'destination=%s\\n' "$DEST"
            printf 'detail=%s\\n' "$2"
            printf 'updatedAt=%s\\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
          } > "$STATUS"
        }
        write_status waiting "waiting for current app to exit"
        while kill -0 \(processIdentifier) 2>/dev/null; do sleep 0.2; done
        write_status copying "copying staged app"
        /bin/rm -rf "$DEST.update-new" "$DEST.update-bak"
        if ! "$DITTO" "$STAGED" "$DEST.update-new"; then
          write_status failed "ditto failed"
          \(reopenOnFailure)exit 1
        fi
        write_status swapping "moving staged app into place"
        if ! "$MOVE" "$DEST" "$DEST.update-bak" 2>/dev/null; then
          /bin/rm -rf "$DEST.update-new" 2>/dev/null
          write_status failed "could not move existing app aside"
          \(reopenOnFailure)exit 1
        fi
        if [ -e "$DEST" ]; then
          /bin/rm -rf "$DEST.update-new" 2>/dev/null
          write_status failed "existing app still present after backup move"
          \(reopenOnFailure)exit 1
        fi
        if "$MOVE" "$DEST.update-new" "$DEST"; then
          /bin/rm -rf "$DEST.update-bak"
        else
          "$MOVE" "$DEST.update-bak" "$DEST" 2>/dev/null
          /bin/rm -rf "$DEST.update-new" 2>/dev/null
          write_status failed "swap failed; rollback attempted"
          \(reopenOnFailure)exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        "$LSREGISTER" -f "$DEST" 2>/dev/null
        write_status succeeded "installed"
        \(reopenOnSuccess)/bin/rm -rf "$STAGING_ROOT" 2>/dev/null
        """
    }

    private static func launchHelper(executableURL: URL, arguments: [String]) throws {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        try task.run()
    }

    /// Quiet "install on quit": swap the staged bundle into place after this
    /// process exits, without reopening. The next launch is the new version.
    @discardableResult
    static func applyOnQuit(staged: Staged, destinationBundle: URL) -> ApplyLaunchResult {
        applyAndRelaunch(staged: staged, destinationBundle: destinationBundle, relaunch: false)
    }

    private static func defaultInstallStatusURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Ouro Workbench", isDirectory: true)
            .appendingPathComponent("LastUpdateInstall.status")
    }

    private static let defaultLaunchServicesRegisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
