import CryptoKit
import Foundation

public struct WorkbenchUpdateStager: Sendable {
    public struct ProcessResult: Equatable, Sendable {
        public var status: Int32
        public var stderr: String

        public init(status: Int32, stderr: String = "") {
            self.status = status
            self.stderr = stderr
        }
    }

    public struct Staged: Sendable {
        public var appURL: URL
        public var stagingRoot: URL
        public var version: String
        public var build: String

        public var releaseLabel: String {
            "\(version) (build \(build))"
        }

        public init(appURL: URL, stagingRoot: URL, version: String, build: String) {
            self.appURL = appURL
            self.stagingRoot = stagingRoot
            self.version = version
            self.build = build
        }
    }

    public enum StageError: LocalizedError, Equatable {
        case download(String)
        case manifestDecode(String)
        case verification(WorkbenchUpdateVerification.Failure)
        case unzipFailed(String)
        case missingStagedApp
        case stagedIdentityMismatch(String)
        case codesignFailed(String)

        public var errorDescription: String? {
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
                return "The downloaded archive did not contain \(WorkbenchRelease.appName).app."
            case let .stagedIdentityMismatch(message):
                return "The downloaded app failed its identity check: \(message)"
            case let .codesignFailed(message):
                return "The downloaded app failed its code-signature check: \(message)"
            }
        }
    }

    public var bundleIdentifier: String
    public var currentVersion: String
    public var currentBuild: String?
    public var appName: String
    public var userAgent: String
    private let dataLoader: @Sendable (URL, String) async throws -> Data
    private let processRunner: @Sendable (String, [String]) async throws -> ProcessResult
    private let temporaryRoot: @Sendable () throws -> URL

    public init(
        bundleIdentifier: String = WorkbenchRelease.bundleIdentifier,
        currentVersion: String = WorkbenchRelease.version,
        currentBuild: String? = nil,
        appName: String = WorkbenchRelease.appName,
        userAgent: String? = nil,
        dataLoader: @escaping @Sendable (URL, String) async throws -> Data = Self.defaultDataLoader(url:userAgent:),
        processRunner: @escaping @Sendable (String, [String]) async throws -> ProcessResult = Self.defaultProcessRunner(launchPath:arguments:),
        temporaryRoot: @escaping @Sendable () throws -> URL = Self.defaultTemporaryRoot
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.appName = appName
        self.userAgent = userAgent ?? WorkbenchRelease.userAgent(version: currentVersion)
        self.dataLoader = dataLoader
        self.processRunner = processRunner
        self.temporaryRoot = temporaryRoot
    }

    public func stage(
        plan: WorkbenchUpdatePlan,
        progress: @Sendable (String) async -> Void
    ) async throws -> Staged {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        await progress("Downloading release manifest…")
        let manifestData = try await dataLoader(plan.manifestURL, userAgent)
        let manifest: WorkbenchUpdateManifest
        do {
            manifest = try JSONDecoder().decode(WorkbenchUpdateManifest.self, from: manifestData)
        } catch {
            throw StageError.manifestDecode(error.localizedDescription)
        }

        await progress("Downloading \(plan.archiveName)…")
        let archiveData = try await dataLoader(plan.archiveURL, userAgent)
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
            currentVersion: currentVersion,
            currentBuild: currentBuild
        ) {
            throw StageError.verification(failure)
        }

        await progress("Expanding update…")
        let extractRoot = root.appendingPathComponent("extract")
        let unzip = try await processRunner("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractRoot.path])
        guard unzip.status == 0 else {
            throw StageError.unzipFailed(unzip.stderr.isEmpty ? "ditto exited \(unzip.status)" : unzip.stderr)
        }
        let appURL = extractRoot.appendingPathComponent("\(appName).app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw StageError.missingStagedApp
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        let stagedBundleID = info?["CFBundleIdentifier"] as? String
        let stagedVersion = info?["CFBundleShortVersionString"] as? String
        guard stagedBundleID == manifest.bundleIdentifier else {
            throw StageError.stagedIdentityMismatch(
                "bundle id \(stagedBundleID ?? "nil") != manifest \(manifest.bundleIdentifier)"
            )
        }
        guard stagedVersion == manifest.version else {
            throw StageError.stagedIdentityMismatch(
                "version \(stagedVersion ?? "nil") != manifest \(manifest.version)"
            )
        }

        await progress("Checking signature…")
        let codesign = try await processRunner(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", appURL.path]
        )
        guard codesign.status == 0 else {
            throw StageError.codesignFailed(codesign.stderr.isEmpty ? "codesign exited \(codesign.status)" : codesign.stderr)
        }

        return Staged(appURL: appURL, stagingRoot: root, version: manifest.version, build: manifest.build)
    }

    public static func defaultDataLoader(url: URL, userAgent: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StageError.download("\(url.lastPathComponent) returned HTTP \(http.statusCode)")
            }
            return data
        } catch let error as StageError {
            throw error
        } catch {
            throw StageError.download("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func defaultProcessRunner(launchPath: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
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
                continuation.resume(returning: ProcessResult(status: process.terminationStatus, stderr: stderr))
            }
        }
    }

    public static func defaultTemporaryRoot() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ouro-workbench-update-\(UUID().uuidString)")
    }
}
