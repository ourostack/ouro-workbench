import Foundation

/// The release manifest published next to each app archive (`…manifest.json`).
/// The in-app updater fetches this to learn the archive's expected SHA-256,
/// byte count, and bundle identity before swapping anything into place.
public struct WorkbenchUpdateManifest: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var archive: String
    public var sha256: String
    public var bytes: Int

    public init(
        appName: String,
        bundleIdentifier: String,
        version: String,
        build: String,
        archive: String,
        sha256: String,
        bytes: Int
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.archive = archive
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// A concrete plan for installing an available update: which two assets to
/// fetch (the app `.zip` and its `.manifest.json`) and the version they carry.
public struct WorkbenchUpdatePlan: Equatable, Sendable {
    public var version: String
    public var archiveURL: URL
    public var archiveName: String
    public var manifestURL: URL

    public init(version: String, archiveURL: URL, archiveName: String, manifestURL: URL) {
        self.version = version
        self.archiveURL = archiveURL
        self.archiveName = archiveName
        self.manifestURL = manifestURL
    }
}

public enum WorkbenchUpdatePlanError: Error, Equatable, LocalizedError, Sendable {
    case notAnUpdate
    case missingArchiveAsset
    case missingManifestAsset
    case badAssetURL

    public var errorDescription: String? {
        switch self {
        case .notAnUpdate:
            return "No newer release is available to install."
        case .missingArchiveAsset:
            return "The release is missing a downloadable app archive (.zip)."
        case .missingManifestAsset:
            return "The release is missing its artifact manifest (.manifest.json)."
        case .badAssetURL:
            return "The release asset download URL was not valid."
        }
    }
}

/// Turns a `ReleaseUpdateSnapshot` (from `ReleaseUpdateChecker`) into an
/// installable plan. Pure + unit-tested.
public enum WorkbenchUpdatePlanner {
    public static func plan(from snapshot: ReleaseUpdateSnapshot) -> Result<WorkbenchUpdatePlan, WorkbenchUpdatePlanError> {
        guard snapshot.status == .updateAvailable, let version = snapshot.latestVersion else {
            return .failure(.notAnUpdate)
        }
        guard let archive = snapshot.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            return .failure(.missingArchiveAsset)
        }
        guard let manifest = snapshot.assets.first(where: { $0.name.hasSuffix(".manifest.json") }) else {
            return .failure(.missingManifestAsset)
        }
        guard let archiveURL = URL(string: archive.downloadURL),
              let manifestURL = URL(string: manifest.downloadURL) else {
            return .failure(.badAssetURL)
        }
        return .success(
            WorkbenchUpdatePlan(
                version: version,
                archiveURL: archiveURL,
                archiveName: archive.name,
                manifestURL: manifestURL
            )
        )
    }
}

/// When the background auto-updater should hit the network. Pure + testable so
/// the throttle (don't re-check on every rapid relaunch) is deterministic.
public enum WorkbenchAutoUpdatePolicy {
    public static func shouldCheck(
        now: Date,
        lastCheck: Date?,
        minimumInterval: TimeInterval,
        enabled: Bool
    ) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= minimumInterval
    }
}

/// Pure verification of a *downloaded* archive against its manifest and the
/// running install — no IO. The caller computes the archive's SHA-256 + byte
/// count and reads the running bundle identity; this decides go/no-go so the
/// decision is deterministic and unit-tested. The swap never happens unless
/// every check here passes.
public enum WorkbenchUpdateVerification {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case archiveNameMismatch(expected: String, got: String)
        case sha256Mismatch(expected: String, got: String)
        case byteCountMismatch(expected: Int, got: Int)
        case bundleIdentifierMismatch(expected: String, got: String)
        case unreadableVersion(manifest: String, current: String)
        case notNewerThanCurrent(current: String, candidate: String)

        public var errorDescription: String? {
            switch self {
            case let .archiveNameMismatch(expected, got):
                return "Downloaded archive name \(got) did not match the manifest (\(expected))."
            case .sha256Mismatch:
                return "Downloaded archive failed its SHA-256 integrity check."
            case let .byteCountMismatch(expected, got):
                return "Downloaded archive size (\(got) bytes) did not match the manifest (\(expected) bytes)."
            case let .bundleIdentifierMismatch(expected, got):
                return "Update bundle identifier \(got) did not match this app (\(expected))."
            case let .unreadableVersion(manifest, current):
                return "Could not compare the update version (\(manifest)) to the current version (\(current))."
            case let .notNewerThanCurrent(current, candidate):
                return "Update version \(candidate) is not newer than the installed \(current)."
            }
        }
    }

    /// Returns `nil` when the download is safe to install, or the specific
    /// `Failure` that blocks it. (Returning an optional rather than
    /// `Result<Void, _>` keeps it `Equatable`-testable, and reads cleanly at
    /// the call site: `if let failure = verify(...) { throw failure }`.)
    public static func verify(
        manifest: WorkbenchUpdateManifest,
        downloadedArchiveName: String,
        downloadedSHA256: String,
        downloadedBytes: Int,
        expectedBundleIdentifier: String,
        currentVersion: String
    ) -> Failure? {
        guard downloadedArchiveName == manifest.archive else {
            return .archiveNameMismatch(expected: manifest.archive, got: downloadedArchiveName)
        }
        let expectedSHA = manifest.sha256.lowercased()
        let actualSHA = downloadedSHA256.lowercased()
        guard actualSHA == expectedSHA else {
            return .sha256Mismatch(expected: expectedSHA, got: actualSHA)
        }
        guard downloadedBytes == manifest.bytes else {
            return .byteCountMismatch(expected: manifest.bytes, got: downloadedBytes)
        }
        guard manifest.bundleIdentifier == expectedBundleIdentifier else {
            return .bundleIdentifierMismatch(expected: expectedBundleIdentifier, got: manifest.bundleIdentifier)
        }
        guard let candidate = SemanticVersion(manifest.version),
              let current = SemanticVersion(currentVersion) else {
            return .unreadableVersion(manifest: manifest.version, current: currentVersion)
        }
        guard candidate > current else {
            return .notNewerThanCurrent(current: currentVersion, candidate: manifest.version)
        }
        return nil
    }
}
