import AppKit
import CryptoKit
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
    case installable(version: String)
    case upToDate(version: String)
    case failed(detail: String)

    var message: String {
        switch self {
        case let .installable(version):
            return "Ouro Workbench \(version) is available. Install it now and relaunch? Your running terminals keep running across the update."
        case let .upToDate(version):
            return "You're on the latest version (\(version))."
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

    struct Staged: Sendable {
        var appURL: URL
        var stagingRoot: URL
        var version: String
    }

    enum InstallError: LocalizedError, Equatable {
        case download(String)
        case manifestDecode(String)
        case verification(WorkbenchUpdateVerification.Failure)
        case unzipFailed(String)
        case missingStagedApp
        case stagedIdentityMismatch(String)
        case codesignFailed(String)

        var errorDescription: String? {
            switch self {
            case let .download(message):
                return "Download failed: \(message)"
            case let .manifestDecode(message):
                return "Could not read the release manifest: \(message)"
            case let .verification(failure):
                return failure.errorDescription
            case let .unzipFailed(message):
                return "Could not expand the downloaded archive: \(message)"
            case .missingStagedApp:
                return "The downloaded archive did not contain Ouro Workbench.app."
            case let .stagedIdentityMismatch(message):
                return "The downloaded app failed its identity check: \(message)"
            case let .codesignFailed(message):
                return "The downloaded app failed its code-signature check: \(message)"
            }
        }
    }

    /// Download + verify + expand + codesign-check. Throws on any failure;
    /// nothing on disk outside a fresh temp dir is touched here.
    func stage(
        plan: WorkbenchUpdatePlan,
        progress: @Sendable (String) async -> Void
    ) async throws -> Staged {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ouro-workbench-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        await progress("Downloading release manifest…")
        let manifestData = try await data(from: plan.manifestURL)
        let manifest: WorkbenchUpdateManifest
        do {
            manifest = try JSONDecoder().decode(WorkbenchUpdateManifest.self, from: manifestData)
        } catch {
            throw InstallError.manifestDecode(error.localizedDescription)
        }

        await progress("Downloading \(plan.archiveName)…")
        let archiveData = try await data(from: plan.archiveURL)
        let archiveURL = root.appendingPathComponent(plan.archiveName)
        try archiveData.write(to: archiveURL)

        await progress("Verifying download…")
        let digest = SHA256.hash(data: archiveData)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        if let failure = WorkbenchUpdateVerification.verify(
            manifest: manifest,
            downloadedArchiveName: plan.archiveName,
            downloadedSHA256: sha,
            downloadedBytes: archiveData.count,
            expectedBundleIdentifier: bundleIdentifier,
            currentVersion: currentVersion
        ) {
            throw InstallError.verification(failure)
        }

        await progress("Expanding update…")
        let extractRoot = root.appendingPathComponent("extract")
        let unzip = try await runProcess("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractRoot.path])
        guard unzip.status == 0 else {
            throw InstallError.unzipFailed(unzip.stderr.isEmpty ? "ditto exited \(unzip.status)" : unzip.stderr)
        }
        let appURL = extractRoot.appendingPathComponent("Ouro Workbench.app")
        guard fileManager.fileExists(atPath: appURL.path) else {
            throw InstallError.missingStagedApp
        }

        // The extracted bundle must itself match the manifest it came with.
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        let stagedBundleID = info?["CFBundleIdentifier"] as? String
        let stagedVersion = info?["CFBundleShortVersionString"] as? String
        guard stagedBundleID == manifest.bundleIdentifier else {
            throw InstallError.stagedIdentityMismatch(
                "bundle id \(stagedBundleID ?? "nil") != manifest \(manifest.bundleIdentifier)"
            )
        }
        guard stagedVersion == manifest.version else {
            throw InstallError.stagedIdentityMismatch(
                "version \(stagedVersion ?? "nil") != manifest \(manifest.version)"
            )
        }

        await progress("Checking signature…")
        let codesign = try await runProcess(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", appURL.path]
        )
        guard codesign.status == 0 else {
            throw InstallError.codesignFailed(codesign.stderr.isEmpty ? "codesign exited \(codesign.status)" : codesign.stderr)
        }

        return Staged(appURL: appURL, stagingRoot: root, version: manifest.version)
    }

    /// Spawn a detached helper that waits for this process to exit, swaps the
    /// staged bundle over the running install (keeping a rollback copy until the
    /// move succeeds), refreshes Launch Services, and reopens the app. The
    /// caller terminates immediately after.
    static func applyAndRelaunch(staged: Staged, destinationBundle: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = destinationBundle.path
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        DEST=\(shellQuoted(dest))
        STAGED=\(shellQuoted(staged.appURL.path))
        STAGING_ROOT=\(shellQuoted(staged.stagingRoot.path))
        /bin/rm -rf "$DEST.update-new" "$DEST.update-bak"
        if ! /usr/bin/ditto "$STAGED" "$DEST.update-new"; then
          /usr/bin/open "$DEST"
          exit 1
        fi
        /bin/mv "$DEST" "$DEST.update-bak" 2>/dev/null
        if /bin/mv "$DEST.update-new" "$DEST"; then
          /bin/rm -rf "$DEST.update-bak"
        else
          /bin/mv "$DEST.update-bak" "$DEST" 2>/dev/null
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        \(shellQuoted(lsregister)) -f "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        /bin/rm -rf "$STAGING_ROOT" 2>/dev/null
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    // MARK: - IO helpers

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("OuroWorkbench/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw InstallError.download("\(url.lastPathComponent) returned HTTP \(http.statusCode)")
            }
            return data
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.download("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) async throws -> (status: Int32, stderr: String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, stderr: String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let stderr = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (process.terminationStatus, stderr))
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
